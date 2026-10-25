# Shared: the improvements that apply to any port

Everything on this page was measured on at least one implementation of this matcher and is worth copying into a new one.
Each entry has the same four parts — **what the split said** (the evidence that made it worth doing), **the change**,
**the measured effect**, and **the risk** — because the risk is what a new port has to decide about, and it is the part
that a bare number hides.

Read the entries in the order the sections are in. That is also the order of the payoff: §1 and §2 are worth an order of
magnitude between them, §5 is worth 3.58x on one workload shape, and the rest are single-digit percentages that are only
visible on a quiet machine with paired runs.

Numbers come from [`doc/measurement.md`](../measurement.md) unless the provenance line says otherwise. `commit <hash>`
means the figure is recorded in that commit's message and nowhere else; **this session's track** means the work that wrote
this page measured it and has not written it into `doc/measurement.md`.

## 1. Replace the regex translation with a segment DP

**What the split said.** A glob translated into one regular expression is correct and, on `**`, catastrophic. `**`
becomes `(?:.*/)?`, and on a long path with several of them the engine explores exponentially many splits before it
answers. The `backtrack` workload exists to be that path: 43 segments, a rule with three `**` segments, and a final
`*.g4` that never matches. Measured on the JS port before either form was tuned: **2902.4 ms regex, 1462.6 ms DP**, on
the same 2,000 paths (`doc/measurement.md`, 2026-10-23; the same table is in the README). The Zig reference's recursive
matcher — the one that retries the rest of the pattern at every position after a `**` — is the same problem in another
shape, and is kept behind `-Dnaive=true` so the difference stays demonstrable.

**The change.** Split the pattern and the path into segments and run a dynamic program: `reach[j]` means "the pattern
segments seen so far match the first `j` path segments". An ordinary segment advances one row (`next[j+1] = reach[j] and
segmentMatches(pattern[i], text[j])`); a `**` segment is an OR-fold over the row. A *trailing* `**` is one-or-more
(`build/**` is everything **inside** `build`), a middle one is zero-or-more. Work becomes
O(pattern segments × path segments) and nothing ever backtracks. The reference is `globMatch` in
[`src/gitignore.zig`](../../src/gitignore.zig); the ports are [`js/glob.mjs`](../../js/glob.mjs) and
[`java/.../Glob.java`](../../java/src/hr/hrg/gitignore/Glob.java).

**Measured effect.** JS `backtrack` 2902.4 → 1462.6 ms (2.0x) on the first, untuned form; the tuned form (see §3-§4)
reaches 887.9 ms. Java's regex era was **212 486 ms total, with `backtrack` alone at 203 s**, against **50 010 ms** for
the full DP — **4.25x on the total**, and the difference is all in one workload (`doc/measurement.md`, 2026-10-23).

**The risk.** The DP is not a straight win, and adopting it everywhere was a mistake on five of six workloads
(§ "The DP only for patterns with any `**`" below). It buys nothing where there is no `**` to split — the regex is then
a single compiled pattern and beats a row loop. It also has a shape requirement: the DP needs the path as segments, so
either the caller splits once (§4) or every rule pays a split.

## 2. Memoise a directory's decided answer

**What the split said.** A phase split of the JS loop put **95% of the cost in re-deciding ancestors**: `backtrack`
asked about **84,000 ancestor directories that were 42 distinct ones**, `deep` **26,000 over 286**. Parsing and chain
building were noise. This is the single largest win in the project and it was invisible in the totals until it was
measured per phase (`doc/measurement.md`, 2026-10-24).

**The change.** `GitIgnoreRules` keeps a map from a directory's path (relative to the walk root) to "is this directory
excluded", and clears it in `push` and `pop`. Those are the only operations that change which `.gitignore` files govern a
path, so a cached answer cannot outlive its stack — that is the whole invalidation argument, and it is why the map is
safe without a generation counter. Ancestors are found by walking the separators backwards (`lastIndexOf('/')`), one
substring per level, and the substring is also the memo key, so no ancestor costs a split and a join.
[`js/gitignore.mjs`](../../js/gitignore.mjs) `#excluded`; [`java/.../GitIgnoreRules.java`](../../java/src/hr/hrg/gitignore/GitIgnoreRules.java)
`excludedDirectories`.

**Measured effect.** Paired alternating A/B, 8 fresh processes × 12 rounds, verdicts byte-identical
(`doc/measurement.md`, 2026-10-24):

| workload   | JS before | JS after   | Java before | Java after |
| ---------- | --------: | ---------: | ----------: | ---------: |
| deep       | 1191.3    | 239.9      | 1553.7      | 343.6      |
| backtrack  | 16765.2   | 887.9      | 8522.2      | 658.6      |
| total      | 19384.5   | **1819.8** | 13246.7     | **2489.7** |

JS **10.6x**, Java **5.3x** on their own totals. Standing against Zig's total *at the time of that run*: JS moved from
**17.2x** behind to **1.61x**, Java from **11.2x** to **2.20x**. The smallest per-workload gain was `dirs` at 18.2%,
above the ~13% noise floor.

**The risk.** Two real ones. First, **the key must be the path relative to the walk root**, not an index: two different
directories can otherwise share a key across `push`/`pop` boundaries and the memo will answer for the wrong one.
Second, **a stale answer is silent** — it returns a plausible verdict, not a crash. The invalidation was therefore tested
by a differential fuzz (54,000 randomised decisions over 300 random multi-file stacks × 5 seeds, identical between old
and new JS) rather than by assuming it; `bun scripts/check-verdicts.mjs` alone would not have exercised push/pop, because
the bench pushes one file once.

## 3. Compare literal segments with equality

**What the split said.** In the Java port, most DP segment tests were comparing a name through
`Pattern.matcher(…).matches()` — which **allocates a `Matcher` per segment per path**. The DP's arithmetic was never the
cost. `doc/measurement.md` states the lesson directly: "allocation, not comparison", learned twice, once in each port.

**The change.** Classify each pattern segment once, at parse time: `**`, a literal (no `*`, `?`, `[` or escape), or a
per-segment regex. A literal is compared with `String.equals` / `===` / `std.mem.eql`. A segment that contains an escape
stays on the regex path deliberately — treating `a\*b` as a literal would be a guess. Where? Zig's
`Rule.kind {literal, suffix, glob}` plus `matchText`, [`java/.../Glob.java`](../../java/src/hr/hrg/gitignore/Glob.java)'s
`Segment`, [`js/glob.mjs`](../../js/glob.mjs)'s `compileSegments`.

**Measured effect.**

| port | before          | after         | gain                                  | provenance                          |
| ---- | --------------: | ------------: | ------------------------------------: | ----------------------------------- |
| Java | 50 010 ms       | **18 217 ms** | **3.03x** (the two totals give 2.75x) | `doc/measurement.md`, 2026-10-23    |
| JS   | —               | —             | 2-3% `doublestar`, 4-8% `backtrack`   | `doc/measurement.md`, 2026-10-23    |
| Zig  | by construction | —             | not measured on its own               | in place before the 3.81x baseline  |

A note on that 3.03x, because it is the one number in this directory whose stated size does not follow from its own rows:
`50 010 / 18 217` is **2.75x**, and the "3.03x" is what `doc/measurement.md` records for the change. The two are the same
claim inside the session-to-session drift this bench has (see the [README](README.md), item 5), and the raw totals are
printed next to the ratio so the arithmetic is checkable rather than asserted.

The JS number is small and the reason is structural, not a disappointment: **only patterns containing `**` use the DP** in
the JS port, so four of six workloads never reach the fast path, and on the two that do, the ancestor slice/join loop
dominated at the time. Java gained 3.03x because **every** pattern goes through its DP. A change worth 8% in one port and
300% in another is a measurement of how much of the time the changed code owns — both numbers are correct.

**The risk.** Low in behaviour, non-zero in correctness: the literal test must be exactly the set of segments for which
the compiled regex would be an anchored, fully escaped literal. A segment holding a backslash, a `[` or a `?` is not one.
Getting this wrong is quiet — `a\*b` compared as a literal simply never matches.

## 4. Split the path once per decision

**What the split said.** The first JS DP was **slower than the regex it replaced on `backtrack`: 6558 ms against
3056 ms** — the regex's six-workload total was 3286 ms — because it
split the path inside every rule and allocated two arrays per pattern segment (commit `98477ff`, 2026-10-23). Java's
`GitIgnoreFile.decide` had the same shape — "a file with 8 rules used to split 8 times" — and its per-rule `Matcher`
created the same per-segment cost as §3.

**The change.** Split once, at the top of the decision, and pass the segment array down. JS splits only if a rule with a
`**` is actually reached, so a file whose patterns are all single-segment regexes pays no split at all. The Java port
uses one `String[]` per `decide`, and a directory-only rule asks about a **prefix count** (`Glob.matches(segments, text,
count)`) instead of building a substring per ancestor. Zig passes `count` similarly and avoids the split entirely
(`Chain.decide` walks separators, `globMatch` splits into fixed 256-entry stack arrays).

**Measured effect.**

| port | change                                        | measured effect                                                                    | provenance                       |
| ---- | --------------------------------------------- | ---------------------------------------------------------------------------------: | -------------------------------- |
| JS   | split once + two reused scratch rows          | `backtrack` 6558 → **1489 ms** (4.4x); total 3286 → **2407 ms** (regex → tuned DP) | `98477ff`, 2026-10-23            |
| Java | one split + reused rows + the new harness     | 18 217 → **17 723 ms** (2.8%)                                                      | `doc/measurement.md`, 2026-10-23 |

The Java percentage is small *because* §3 had already removed the allocation that dominated. The JS 4.4x is the case
where the split and the allocation were the whole cost, and it is the reason the DP is worth anything at all in JS: the
DP went from **2.1x slower than the regex** (`backtrack` 6558 against 3056) to **2.05x faster** (1489), which no amount
of tuning the comparison could have bought.

**The risk.** A prefix-count API is easy to get subtly wrong: `count` must be "the first `count` segments", and a
**trailing** `**` must be one-or-more rather than zero-or-more (`build/**` must not match `build`). Both ports have that
special case written out, and it is pinned by the vectors `trailing doublestar needs a segment` and
`trailing doublestar matches inside`.

## 5. A last-segment precheck

**What the split said.** On `backtrack` before this change: DP rows 42.6 ms (**41.7%**), pattern+path splitting 22.6 ms
(22.1%), chain literal scan 22.2 ms (21.8%), chain lookup 14.6 ms (14.3%) — so **DP plus splitting was 65% of the
workload** on a rule whose final segment `*.g4` never matches a `.java` file (commit `9fb0d30`, 2026-10-25).

**The change.** In `globMatch`, if the pattern's last segment is not `**`, it must match the path's last segment in any
successful match — so test that one comparison **first**, before either input is split. `src/gitignore.zig`:

```zig
const tail = lastSegment(pattern);
if (!std.mem.eql(u8, tail, "**")) {
    if (!wildMatchSegment(tail, lastSegment(path))) return false;
}
```

**Measured effect.** `backtrack` **101.6 → 28.4 ms (3.58x)**, total **128.7 → 50.8 ms (2.53x)**, and no workload
regressed (commit `9fb0d30`). The same commit replaced `std.mem.indexOfScalarPos` with a hand-written `nextSeparator` in
`Chain.decide`: **3.66 ms against 20.4 ms** over the same paths — see [`zig.md`](zig.md) §4.

**The risk.** The precheck is only valid when the match is against the **whole** path. A directory-only rule asking
about a prefix count (§4) must not apply it to a different segment, or an ancestor of a matching path stops matching. The
Zig form lives inside `globMatch`, which always matches whole texts, so it is safe there; a port that reuses it for
"match the first `n` segments" has to pass the *last considered* segment in, not the path's last.

## The refuted ideas

Four were measured and reverted, and one was measured and *not built*. They are here because they are the most likely
things for a future port to try from first principles.

### The DP only for patterns with two or more `**` — refuted, 26% worse

The steady-state table suggested it: `backtrack`'s worst rule has three `**`, `doublestar`'s rules have at most one, and
the full DP was visibly costing Java on `doublestar`. Implemented and measured: **full DP + literal segments + split once
= 12 405 ms** against **the same with the two-or-more-`**` criterion = 15 641 ms** — worse, with `backtrack` 7868 → 9722
and `doublestar` 2328 → 3259 (`doc/measurement.md`, 2026-10-23). The cause is one rule, `**/*.class`: a single `**`, so
the criterion sends it to the regex, whose `(?:.*/)?[^/]*\.class$` is slower on these paths than a DP row scan.
**"One `**`" is not "cheap"** — it depends on the pattern and the depth of the path, and a criterion that ignores that is
a guess wearing a measurement's clothes. Both numbers moved in the same direction in the run that produced each, so the
*direction* is not in doubt; the *size* is, because this bench has ~13% run-to-run variance and the comparison was two
runs rather than an interleaved pair.

### The DP only for patterns with any `**` — refuted on Java, kept on JS

Same idea, coarser criterion: keep the compiled regex unless the pattern contains `**`. On Java this measured **71 355 ms
against 50 010 ms for the full DP — 43% worse**: a single `**` saves nothing in the DP, and the directory-only rules paid
a substring plus a `Matcher` per ancestor (`doc/measurement.md`, 2026-10-23). On JS the same criterion is the port's
actual design, because there it was measured against the alternative on the same afternoon and won: regex 3128.2, full DP
2360.7, hybrid **1661.2 ms**, with the full DP **1.6x-6x slower on the other five rows** (`23f812a`). The lesson is not
"the criterion is wrong" but "the criterion is worth what the corpus says it is worth, and the two ports have different
corpora": Java routes every pattern through its DP, so its DP is well exercised and worth keeping everywhere.

### A DP memo per (pattern, path) — it can never fire

The idea: the same rule is asked about the same path more than once, so cache `(pattern, path) → answer`. Counted, and
**no (pattern, path) pair is recomputed within a decision** — each rule is tested against each path once, and the repeated
work is the *directory-level* question that §2 addresses. A memo on the pair would add a hash lookup per test and never
return a hit. (This session's track, 2026-10-24; recorded in `9fb0d30`'s message.) The general form of the lesson: **cache
the question that repeats, not the question that is expensive** — here, "is this directory excluded" repeats 84,000 times
for 42 answers, while "does this rule match this path" repeats never.

### A first-byte bitmap — 0.9 ms

Rejecting a rule by its pattern's first byte before any comparison, as a 256-bit map per chain. Gained **0.9 ms**, and
was removed rather than kept as complexity (this session's track, 2026-10-25; recorded in `9fb0d30`). The first byte was
never the cost: after the chain index and the precheck, what is left is a hash lookup and a handful of comparisons, and a
bitmap test is one of those comparisons.

### A last-directory memo — no gain, and it regressed `deep`

`doc/measurement.md` proposed it: "Backtrack's 13.8 ms directory-key hash would fall to a last-directory memo" (2026-10-24).
Measured: **13.2 ms of comparison against 13.7 ms of map-get** — no gain at all — and `deep` regressed, so it was reverted
(this session's track, 2026-10-25; recorded in `9fb0d30`). A one-element cache in front of a hash map is a hash-comparison
and a branch to avoid a hash lookup and a branch.

### Not built: an exact-anchored-literal index, and a suffix bucket

Two indexes were considered and deliberately not built. Indexing **exact** anchored literals regressed `deep` — a chain
holds one or two of them, and one comparison beats an index walk. A **suffix bucket** had no customer: `doublestar` has zero
anchored-general tests and `backtrack`'s only anchored glob ends `*.g4`, which is not a literal suffix
(commit `ecff1ff`, 2026-10-25). Both are worth knowing *before* measuring, because "add an index" is the reflex answer to
every slow scan and here it is wrong twice.

## What the split said

- **The cost is a walk, not a comparison.** Two of the four large wins replace a *repeated traversal* (up to the root for
  a chain; over every ancestor for an exclusion decision) with one lookup. A port that optimises the matcher before it
  measures the walk will spend its effort on the 21% and leave the 49%.
- **Allocation is the comparison's tax.** `Matcher` per segment (Java), two arrays per pattern segment and a split per
  rule (JS): in both ports the arithmetic was never the problem, and removing the allocation was worth 3.03x and 4.4x.
- **Reject before you compute.** The last-segment precheck is one comparison standing in front of a DP that was 65% of a
  workload. A cheap necessary condition is worth more than a fast expensive test.
- **Profile the workload you are about to change.** Every refuted idea above came from the shape of the code or from a
  total; every kept one came from a per-phase number.

## What is left

- **A per-chain rule index for the ports.** 87% of the JS residual is the direct rule scan (`doc/measurement.md`,
  2026-10-24) and neither port has the reference's indexing. [`zig.md`](zig.md) §2-§3 is the design: a per-directory state
  cache, and an anchored-literal bucket keyed by segment depth.
- **A criterion that survives measurement, if one exists.** Two were refuted; the data supports only "the DP is never
  slower than the regex on these workloads", which argues for keeping the DP and optimising inside it — the literal fast
  path and the split were worth 4.4x between them on Java.
- **An honest noise floor.** The two-or-more-`**` comparison was two runs, and the sizes may be wrong even though the
  direction is not. Nothing in this directory has been decided on an interleaved *multi-configuration* run, which is what
  § "How to read these numbers" in the [README](README.md) asks for.
- **A port that does not need these pages.** The four largest wins are all "do not repeat work": one lookup instead of a
  walk, one split instead of one per rule, one comparison instead of a DP. A new port that starts with those gets the
  1.61x result without the six intermediate measurements.

## The four residuals of 2026-10-25, measured in both ports

The ports had just been levelled with the reference's three indexes. Four residuals were left. Every number below is a
paired alternating run, min of 9, `--rounds 12`, unless it says it is a per-decision cost — those come from
`.tmp/ports/micro-js.mjs` and `.tmp/ports/Micro.java`, which time the primitive on the workload's own data.
**This session's track**, 2026-10-25.

### 1. Interning the directory key — measured and reverted in both ports

**What the split said.** The reference's string key cost `std.mem.eql` 14.16 of 14.88 ms on a 207-byte key. In the ports
the key is a `Map`/`HashMap` lookup, and on `backtrack`'s 207-byte key it is: JS `slice` 83 ns + map get **315 ns** = 398
ns per decision (7% of the 5,405 ns decision); deep 168 ns (5.5%); Java 277 ns (slice 196 + get 81), deep 273, flat 284.

**The change, and the numbers.** Interning (`Map<string,id>` + an array indexed by id, so the state comparison is an
integer) was implemented and measured as a paired A/B. **JS: 334 vs 398 ns per decision — 16% of the key cost, but only
1.9% of the total (backtrack -0.2%); reverted.** **Java: 328 vs 277 ns — 51 ns *slower*; total -1.4%, backtrack +2.0%;
reverted.** The reason is in the numbers above: a `Map<string,id>` keys on the same string, so the hash is paid either way,
and Java's fresh-substring hash is already the cheap part of its get (81 ns of 277). The reference's win was a word-at-a-time
`eql`, a primitive the ports' hash maps already have; there was no equality cost left to remove.

### 2. Java's `Optional<Boolean>` — no measurable win, reverted

**What the split said.** 4,000 `Optional` allocations per 2,000 decisions (**2 per decision**), counted by an instrumented
copy. The microbenchmark prices `Optional.of` + `isPresent`/`get` at 185 ns against 88 ns for an `int` tri-state — ~97 ns
each, ~3% of the 5.8 µs decision.

**The change, and the numbers.** An `int` tri-state (`NO_OPINION`/`INCLUDE`/`EXCLUDE`) was threaded through
`decideDirect`, `stateFor`, `walkAncestors` and `GitIgnoreFile.decideState`, with the public `Optional<Boolean>` methods
kept as thin wrappers. Paired A/B: **total 505.8 → 571.1 ms (-11.4%), and in the reversed order 539.3 vs 529.9 (-1.8%);
backtrack +0.7%/+0.3%, deep -2.8%/-7.9%. Reverted** — never a gain, most likely because the JIT was already
scalar-replacing the `Optional` across the inlined calls, and the extra tri-state layer only moved work around.

### 3. The unanchored directory-name index — gated by chain size, kept in both ports

**What the split said.** The index walks every segment of the path and does one name lookup per segment in order to answer a
question about a *directory* name. Per decision: JS `backtrack` **4,960 ns of its 5,405 ns decision (92%)**, deep 1,204
(39%), flat 114 (23%), dirs 133; a whole-path `indexOf` per name costs 245 / 169 / 181 / **1,937** instead. Java: 1,661 /
612 / 266 / 293 against 294 / 273 / 338 / 714.

**The change.** The name index is used only when a file has **four or more** unanchored directory literals; below that, the
name is found with `indexOf` plus a `/` boundary check, which builds no segment string. The six workloads' chain sizes are
0, 0, 2, 3, 4, 40, and the hit rate is "every decision" only for `dirs` (40 names); on flat/deep/backtrack the map produced
no hit at all. That is why the threshold sits at four: below it the scan is cheaper, above it the map wins.

**Measured effect.** **JS `backtrack` 159.3 → 61.0 ms (2.61x), deep 82.4 → 48.8 (1.69x), total 340.2 → 197.5 (1.72x).**
**Java `backtrack` +12.7% and +17.5% in two sessions, deep +6.4% in both, total +4.4% / +9.3%** (flat +11.9% then -9.7%,
i.e. inside the noise; the gate cannot affect `doublestar`/`anchored`/`dirs`, which have 0 or 40 names).

### 4. The last-segment precheck for the JS regex rules — kept

**What the split said.** The JS regex rules were tested against paths that could not match them: `flat` 4 regex tests per
decision with a tail that rejects 3.86 of them, `deep` 5 with 5 rejects, `doublestar` 3.2 with 4 of 4. A non-`**` final
pattern segment must match the path's last segment in any successful match, so nearly every one was a whole-path regex test
that a single comparison could have rejected.

**The change.** `parseRule` records the last segment; `matches` checks it before the whole-path regex — `endsWithSegment`
(no slice) for a literal tail, one small anchored regex on the last segment for a wildcard tail. The DP path already had it.

**Measured effect.** On top of item 3: **`deep` 49.6 → 22.9 ms (2.17x) and 51.0 → 23.1 (2.21x)**, total 1.09x / 1.29x;
`doublestar` 6.6% then -21.1% and `flat` ±22% are this bench's noise on the small rows.

### The final rows

Two paired base→final sessions. The small workloads (`flat`, `dirs`) sit at the process floor where the start-up
subtraction dominates — `flat` read 14.5 → 9.8 in one session and 5.9 → 12.2 in the other — so their rows are not a
result. The rows that are stable are shown with both sessions.

| workload   | JS before     | JS after           | Java before | Java after        |
| ---------- | ------------: | -----------------: | ----------: | ----------------: |
| flat       | floor         | —                  | 34.5        | 30.6              |
| deep       | 86.1 / 87.6   | **19.3 / 19.6**    | 124.1       | 121.2             |
| doublestar | 63.7 / 67.8   | 57.8 / 63.9        | 154.9       | 172.0             |
| anchored   | 16.7 / 14.8   | 11.6 / 12.2        | 40.9        | 42.4              |
| dirs       | floor         | —                  | 22.0        | 20.9              |
| backtrack  | 154.7 / 164.9 | **61.6 / 60.1**    | 149.5       | **130.9**         |
| total      | 342.0 / 350.8 | **165.0 / 179.4**  | 525.8       | **517.8 (1.02x)** |

The JS total is **1.96-2.07x**; the Java total is **1.02x**. Java's total is the honest one: only backtrack moves (four
paired runs: +12.7%, +17.5%, +14.2%, +17.0%); a second final session measured backtrack +17.0%, deep +18.3% and total
+7.3%, and the doublestar/anchored rows cannot be affected by a gate that their chains do not enter. Correctness after
every step: `bun scripts/check-verdicts.mjs` **6/6 workloads, 10,000 byte-identical verdicts**; ports 34/34 each; `bun
test` 34.

**What is left, from the same harness.** Java's `String.split("/", -1)` is now the largest single cost in both ports:
**2.5 µs per decision on `backtrack` = 5.0 ms/round (43% of 11.6), 1.99 ms deep, 1.15 doublestar, 1.08 anchored** (JS:
2.19 µs, 4.4 ms/round on backtrack). And both ports split the path *before* the DP's last-segment precheck runs, so on
`backtrack` every split is spent on two DP rules that the precheck then rejects. Neither was in this session's brief.


## "Last-segment buckets: candidate sources, never answers"

**The split.** The decision loop classifies every rule once, at parse/build time, by its **last segment**:
directory-only rules and plain unanchored names stay on the scanned path; a rule whose last segment is a literal
(`build.gradle`, `src/**/target`, `/target`) or exactly `*.ext`-shaped (`*.class`, `**/*.class`, `*.class.txt`) is
moved into a position map and removed from the scan. A rule's last segment is a **necessary** condition for a
non-directory-only match, so a path whose base name/last-dot extension does not appear in a bucket cannot match one
of its rules — one hash lookup replaces a scan over every such rule. Directory-only rules are never bucketed: their
match can be an ancestor directory whose base name is not the path's.

**The change.** `Chain.base_literals` / `Chain.base_suffixes` (Zig) and `baseLiterals` / `baseSuffixes` (JS, Java)
map the key to every rule position with that tail, ascending. A decision asks the base name in the literal bucket and
the base's last-dot extension in the suffix bucket, then walks the positions **from the best end downwards**, verifies
each candidate against the whole path, and keeps the first that matches. Suffix keys are the tail's own last-dot
extension, so `*.class.txt` and `*.txt` share the `.txt` bucket; a candidate that fails whole-path verification falls
through to the next position, not to "no match". The keys are superset filters; the rule is always re-verified.

**Ordering, the invariant this must not break.** `best` is the best (highest-precedence) position any indexed source
could reach for this path. The general scan then only considers rules after it: JS/Java walk rule indices downwards
while `index > best` and return the first match; Zig's chain positions ascend in precedence order, so its lists are
walked while `at < best`. Because the bucket has already supplied the best *matching* bucketed position, no indexed
rule after `best` can exist; every general rule after `best` still wins — that is git's last-matching-pattern rule,
including a later negation and a later bucket rule in another bucket. `conformance/ordering-vectors.json` (11 cases,
each verified with `git check-ignore -v --no-index` under git 2.54) pins exactly this; the pre-existing 34-case
`gitignore-vectors.json` is untouched.

**Thresholds differ per port, and that is measured, not guessed:**
- Zig `bucket_min_rules = 2` (chain-wide): `backtrack`'s two bucket rules are the win here (26.5% / 31.2% in two
  sessions) because its tail check entered the `**` matcher; `doublestar`'s seventeen are a wash (its suffix scan is
  already a bare `endsWith` list).
- JS `BUCKET_MIN_RULES = 4` (per file): `doublestar`'s 28 bucket rules pay (33-35%); `deep`'s five are below the
  floor; `flat` (3) and `backtrack` (2) stay scanned and act as noise controls.
- Java `BUCKET_MIN_RULES = 4` (per file): `deep`'s five and `doublestar`'s 28 both pay hugely (41-46%, 36-37%)
  because each `*.ext` tail rejection allocated a `Matcher`; the same two rule sets are below the JS/Zig line.

**Risk.** The bucket changes which questions are asked, never the answer, and that is what the ordering vectors, the
git-verified fuzz (1,286 decisions over 400 random multi-file stacks) and 12,000 in-process differential decisions
(library + dirs) are for. The residual risks are (a) a rule class that is necessary-but-not-sufficient in a way the
last segment does not capture — none is known: `**` tails, escapes, character classes and multi-wildcard tails are
left on the scan; (b) thresholds: a rule set between the measured points gets a bucket that was not measured to pay,
which costs a hash lookup or two and showed no regression above noise in either session; (c) the buckets are built
per chain/file at parse time, so a pathological rule set with thousands of same-tail rules pays an extra list build.

**What is left.** The git oracle found a pre-existing divergence that this change does not touch and this session did
not fix: JS and Java apply a **directory-only negation** (`!out/`) to a path *below* `out`, because their per-file
decision still matches a directory-only rule against ancestor prefixes in both polarities; git re-includes the
directory only. Zig agrees with git (its unanchored directory-only index is consulted only when `is_dir`). Three of
the 1,286 fuzz cases are exactly this, identical in the pre-change builds. Fixing it means deleting that ancestor
branch and leaving descendant exclusion to `GitIgnoreRules` / `Stack.dirState` pruning (which already implements the
positive case); it changes public matcher answers, so it wants its own vectors and its own measurement, not a ride on
this change.

---
## Rejected: bit-parallel DP for `**` (measured 2026-10-25)

The full record — mechanism, prototype numbers, the git-oracle results, the arithmetic that settled it, and the checklist for revisiting it or a variation — is in [rejected-bit-parallel-dp.md](rejected-bit-parallel-dp.md). What follows is the summary.

The idea: represent the reachable path positions as a `u64` bitmask, one mask per pattern segment, with `**` advancing by a
`log2(n)`-step prefix closure (`x |= x << 1; x |= x << 2; ...`) instead of looping over positions. It is the standard way to make
`**` cheap, and it was measured before anything was written.

**The ceiling first, because it decides the question.** If the DP cost were exactly zero:

| port | loop-only total | with DP cost 0 | maximum buy |
| ---- | --------------: | -------------: | ----------: |
| Zig  | 6.2 ms          | 6.2 ms         | **0.0 %**   |
| JS   | 62.2 ms         | 60.8 ms        | **2.2 %**   |
| Java | 95.9 ms         | 91.2 ms        | **4.9 %**   |

Zig never enters the DP at all (0 calls, 0 cells, counters verified against a synthetic `a/**/b`): `**/x` is normalised at parse
time into an unanchored literal or suffix rule, and `backtrack`'s `src/**/test/**/impl/**/*.g4` is a suffix-bucket candidate its
tail precheck rejects. Five of six workloads now reach the DP zero times in every port. The buckets and the precheck did to the
matcher what they were supposed to do.

**A prototype in isolation** (Java, the largest absolute DP share, 4.7 ms): same compiled segments, only the row algorithm
differs. Real workload pairs whose precheck passes (810): 564 -> 464 ns/match, **1.21x**. Adversarial pairs (many `**`, a
trailing `**`, `**` beside a literal, 71-segment paths): 1333 -> 883 ns, **1.51x**. Multiply by the share: **0.9 % of Java's
total**, 1.7 % if every call were adversarial.

**The oracle, because a rewrite needs one.** 1,200 randomised `**`-heavy cases over three seeds plus the named corners; 836
compared, 364 excluded because an ignored ancestor directory makes git's answer a chain answer rather than a pattern answer.
Disagreements: current matcher **0/836**, bit-parallel prototype **0/836** - and the oracle still caught a real prototype bug
(a trailing `**` shifted the closure into the wrong word), which is precisely the class of error the vectors cannot see. The
residual risk is the >63-segment word carry, not the closure.

**Verdict: not worth implementing.** Every ceiling is under this project's 10 % rule, and the measured per-call ratio turns
Java's 4.9 % into 0.9 %. The complexity it would add - a second matcher shape, a word-array path, a closure invariant - cannot
be earned by one percent.

**What the same measurement did argue for**: port Zig's parse-time `**/x` normalisation to the JS port (a five-line variant
measured here gives 0 DP calls per decision and `doublestar` 17.0 -> 15.9 ms with all 10,000 verdicts identical), and give
Java the literal/suffix rule classes that Zig and JS already have. Java's 4.9 % is its *universal* DP - every pattern goes
through it - and no `**` rewrite touches that. **Both were done later the same day** (JS: `doublestar` 17.33 -> 14.58 ms,
DP calls 0.27 -> 0; Java: `flat` 2.14x, `doublestar` 1.50x, DP calls 0.143/0.27 -> 0); see [`js.md`](js.md) §8,
[`java.md`](java.md) §9 and § "The two follow-ups, done" below.

---

## The two follow-ups, done (2026-10-25)

The rejection of the bit-parallel DP named two variations worth trying instead, in the order "delete the calls before
accelerating them". Both were implemented and gated; the point in each was **DP calls per decision -> 0**, and the
timing is the bonus.

- **JS: a leading `**/` is normalised at parse time** into the unanchored rule it means. `**/x` becomes a base-name
  literal, `**/*.ext` a suffix rule, `**/x/y` a path-suffix rule; `**/**/x`, `a/**/b`, `**/x/**/y` and any trailing
  `**` keep the DP. The rule keeps its position, so ordering is untouched, and the last-segment bucket was extended to
  plain unanchored names so the normalised rules stay lookups. Paired alternating A/B, `--rounds 12`, min of 9, two
  sessions: **`doublestar` 17.33 -> 14.58 and 17.44 -> 14.87 ms (+15.9 %, +14.7 %), total +3.8 % / +3.1 %, DP calls
  0.267 -> 0** on `doublestar` and 0 everywhere else; the other five workloads moved ±4 %, inside the noise. Full entry:
  [`js.md`](js.md) §8.
- **Java: the literal/suffix rule classes, and the same normalisation.** `Rule` is classified at parse time as
  `LITERAL`, `SUFFIX` or `GLOB`; a literal is a `String.equals` (whole path, base name, or `/`-boundary path suffix) and a
  suffix is `path.endsWith`, so neither reaches `Glob.matches`, splits the path, or allocates a `Matcher` in
  `tailRejects`. The indexes are consulted first exactly as before. Paired A/B, two sessions: **`flat` 14.01 -> 6.71
  and 13.30 -> 6.22 ms (2.09x / 2.14x), `doublestar` 34.02 -> 25.43 and 34.57 -> 24.08 (1.34x / 1.44x), `backtrack`
  19.40 -> 16.66 and 19.41 -> 16.95 (1.16x / 1.15x), total 1.21x / 1.23x; DP calls 0.143 (flat) and 0.267
  (doublestar) -> 0, zero everywhere.** `deep`, `anchored` and `dirs` moved 2.4-8.1% slower in both sessions, inside
  the noise floor and on code paths the change does not reach. Full entry:
  [`java.md`](java.md) §9.

Neither result fits the 4.9 % / 2.2 % DP-share ceiling, and that is not a contradiction: the share counted the DP body
only, while the same rules also paid a `Matcher` (Java) or a `RegExp.test` tail check and a scan entry (JS) per decision.
The same lesson as §3 — **allocation and reach, not comparison**. Both ports also gained an answer that now matches git:
a normalised `**/x/` behaves like the unanchored `x/` it means, which fixes the recorded directory-only-negation
divergence for that form (`conformance/ancestor-vectors.json` pins it).

**What is left after them.** The DP is now reached only by a rule that still contains `**` or a multi-segment wildcard —
which is the state the checklist in [`rejected-bit-parallel-dp.md`](rejected-bit-parallel-dp.md) §5 asked for — so the
remaining DP calls are zero on every measured workload. The next measurement, if one is ever needed, is the "rules tested
per decision" counter that §6 of that file names as the variation never measured, not a faster DP.
