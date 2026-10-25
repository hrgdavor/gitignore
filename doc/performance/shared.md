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
