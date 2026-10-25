# JS: the JavaScript port

`js/gitignore.mjs` (parsing, precedence) and `js/glob.mjs` (the segment DP) are the port with the most measured history:
it was the first to adopt the DP, the first to be re-measured at steady state, and the first to reach the reference's
order of magnitude — **1584.1 ms per round initially, 151.7 ms per round at its last measurement (10.4x)**. It is also the
port whose fast paths are worth least, and the reason is structural rather than disappointing.

Run it with `bun js/decide.mjs --rules <file> --paths <file> [--dirs <file>] [--rounds N]`; its vectors are
`bun js/conformance.mjs` (34/34); its correctness gate is `bun scripts/check-verdicts.mjs`.

## 1. Allocation discipline: the first DP was slower than the regex

**What the split said.** Nothing, at first — and that is the entry's point. The DP was adopted because of the *shape* of
the problem (`**` makes a regex engine explore exponentially many splits) and the first version was a **regression**:
**6558 ms** on `backtrack` against **3056 ms** for the regex it replaced, whose six-workload total was **3286 ms**. It
split the path inside every rule and allocated two arrays per pattern segment (commit `98477ff`, 2026-10-23). The
measurement existed only because the change was timed before it was believed.

**The change.** Two lines of structure, in `js/glob.mjs`:

- the **caller** splits the path once per decision and passes the array down (`segmentsMatch(segments, text, count)`), so
  a rule no longer splits;
- **two scratch rows** (`scratchA`, `scratchB`) are module-level and reused across calls, growing to the longest path seen
  and never freed. The DP needs a previous row and a next row and nothing else, so two arrays are the entire working set.

**Measured effect.** `backtrack` **6558 → 1489 ms (4.4x)**, which is **2.1x slower than the regex → 2.05x faster than
it**, and the six-workload total from the regex's 3286 ms to the tuned DP's **2407 ms** (commit `98477ff`, 2026-10-23).
The comment at the top of `js/glob.mjs` states the conclusion the JS port learned twice
and Java learned once: **in JS the allocation was the cost, not the comparison.**

**The risk.** The scratch rows are shared mutable state at module scope. That is safe here because JS is single-threaded
and `segmentsMatch` never yields, and it becomes wrong the moment someone calls it from a worker with a shared module
instance or re-enters it from a callback inside the loop. The rows are also never shrunk, so the high-water mark of the
longest path is retained for the process's life — a bounded leak, and the price of the win.

## 2. The DP adoption

The mechanism, because a port will write it: pattern → an array of segments, each `{ doubleStar }`, `{ literal }` or
`{ regex }` (`compileSegments`), with an unanchored pattern getting a leading `**`. Then `reach[j]` = "the pattern so far
matches the first `j` text segments"; an ordinary segment advances one row, a `**` folds an OR across the row, and a
*trailing* `**` is one-or-more (`build/**` is everything **inside** `build`). Per-segment regexes stay for wildcards —
that is where `[` classes and escapes live — but against a single segment they cannot backtrack across `/`.

**Measured effect** against the regex port, same vectors, same process shape (commit `23f812a`, 2026-10-23):

| workload   | regex      | full DP    | hybrid        |
| ---------- | ---------: | ---------: | ------------: |
| flat       | 0.8 ms     | 8.1 ms     | 5.2 ms        |
| deep       | 111.6 ms   | 241.9 ms   | 115.8 ms      |
| doublestar | 75.3 ms    | 494.8 ms   | 120.5 ms      |
| anchored   | 32.0 ms    | 126.9 ms   | 35.3 ms       |
| dirs       | 6.1 ms     | 26.4 ms    | 13.7 ms       |
| backtrack  | 2902.4 ms  | 1462.6 ms  | 1370.6 ms     |
| total      | 3128.2 ms  | 2360.7 ms  | **1661.2 ms** |

The full DP improved the total **only because `backtrack` dominates it**, while being **1.6x-6x slower on the other five
rows** — the first version of the README table hid that by printing only the total. That is the reason the JS port keeps a
regex for most rules (§3) and the reason every table in this directory is per workload.

## 3. The hybrid: the regex everywhere except patterns with a double star

**What the split said.** The table above: the DP's cost is a row loop per pattern segment, and a pattern with no `**` has
nothing for it to fold. Measured on the rules the regex is *worse* at (`backtrack`), the DP wins 2.1x; measured on five
other workloads it loses by up to 6.6x (`doublestar`: 494.8 against 75.3).

**The change.** `parseRule` keeps a compiled `RegExp` unless the pattern contains a `**` segment, in which case it
compiles `segments` and leaves `pattern` null. `matches()` branches on which one exists. A file whose patterns are all
single-segment regexes therefore never splits a path and never enters the DP.

**Measured effect.** Hybrid total **1661.2 ms** against regex **3128.2** and full DP **2360.7** — the best of the three,
`backtrack` down 2.1x from the regex, every other row within ~1.2x of the regex **except `doublestar` (120.5 against
75.3)** (commit `23f812a`). `doublestar` is a `**` pattern where the regex happened to be fast, and it is recorded as the
open tuning question rather than a settled result.

**The risk.** The criterion is a **guess about which construct is expensive**, and on Java the same guess was refuted twice
with numbers (`71 355 ms against 50 010` for "any `**`"; `15 641 against 12 405` for "two or more `**`"). It survives in JS
because it was measured *against the alternative within one afternoon*, on this corpus — not because "one `**` is cheap".
The real rule the data supports is weaker and more useful: **the DP is never slower than the regex on these workloads**;
the hybrid exists because that was not yet true in JS when it was chosen.

## 4. The literal fast path

**What the split said.** Java gained 3.03x from comparing literal pattern segments with `String.equals` instead of
`Pattern.matcher(…).matches()`. The JS port has no `Matcher` allocation, so the expected gain was "much less, and the
structure predicts how much".

**The change.** `compileSegments` emits `{ literal }` for any segment with no `*`, `?`, `[` or escape
(`const hasWildcard = /[*?[\\]/`), and `segmentsMatch` compares with `===`. A segment holding a backslash stays on the
regex path deliberately: `a\*b` is not the literal `a*B`, and treating it as one is a quiet wrong answer.

**Measured effect** (commit `3f319f4`, 2026-10-23; `doc/measurement.md`, "The literal fast path, ported to JS"):

- **`doublestar` ~2-3%**: faster in **22 of 26** paired processes; one session had all 10 new values below all 10 old.
- **`backtrack` ~4-8%**: faster in **19 of 26** pairs, means **-8.1%, -6.3%, -4.4%** across three sessions.
- **the other four workloads: 0 DP segments**, so they never reach the change; their variation is the ~±4% noise floor.

**Why it is not Java's 3.03x.** Only patterns containing `**` use the DP, so four of six workloads never enter the fast
path; on the two that do, the ancestor slice/join loop dominated at the time. **A change is worth the share of the time
its code owns** — the same edit is 3.03x in a port that routes every pattern through the DP and 2-3% in one that routes
two of six workloads through it. Neither number is a contradiction of the other.

**The risk.** The literal classification is the same one Java has, with the same failure mode: a wrong "this segment is
literal" is a silent non-match, not an error. And the method is the risk here, not the code: the gain is **below the
harness's own noise**, which is why it was decided on alternating paired fresh processes with the loop timed directly,
three sessions, trusting only the paired difference. The official harness at `--repeat 1 --rounds 12` put the totals
inside its own noise (21.9 s vs 22.8 s), and between-session drift moved the old build from 16.7 s to 19.8 s — an unpaired
comparison would have said whatever the drift said.

## 5. The ancestor memoisation

**What the split said.** A phase split of the JS loop (per round, medians, the halves summing to the total) put **95% of
the cost in re-deciding ancestors**: `backtrack` asked about **84,000 ancestor directories when only 42 were distinct**,
`deep` **26,000 over 286**. Parsing and chain building were noise, because the bench chain is a single root file
(`doc/measurement.md`, 2026-10-24).

**The change.** `GitIgnoreRules` gains `#excluded`, a `Map` from a directory's root-relative path to "is it excluded",
cleared by `push` and `pop` — the only operations that change which files govern a directory, so a cached answer cannot
outlive its stack. Ancestors come from walking separators backwards with `lastIndexOf('/')`, one substring per level and
no split+join; the substring is also the memo key. `decide` asks `decideDirect` first and falls back to the ancestor walk
only when the direct answer is not `true`.

**Measured effect.** Paired alternating A/B, 8 fresh processes × 12 rounds, verdicts byte-identical: total
**19 384.5 → 1819.8 ms (10.6x)**, `backtrack` **16 765.2 → 887.9 ms (18.9x)**, `deep` **1191.3 → 239.9 ms**; standing
against Zig *at the time of that run*, **17.2x → 1.61x** behind (`doc/measurement.md`, 2026-10-24). The smallest
per-workload gain was **-18.2% (`dirs`)**, above the ~13% noise floor, and every comparison was paired.

**The risk.** Staleness is silent, and the bench does not exercise it: the workload pushes one file once, so a memo that
never invalidated would still pass `bun scripts/check-verdicts.mjs`. The invalidation was therefore tested by a
differential fuzz — **54,000 randomised decisions over 300 random multi-file stacks × 5 seeds, identical between old and
new JS** — which is what actually exercises `push`/`pop`. A port that skips that fuzz has an untested cache.

## 6. The current residual

- **151.7 ms per round** (1819.8 ms for 12 rounds), the port's last measurement on 2026-10-24. It has **not** been re-run
  after the reference's `7053629`, `ecff1ff` and `9fb0d30`, which touched Zig only. Against the reference's closing
  9.0 ms/round that is **16.9x**; against the reference as it measured when the ports were last compared (~94 ms/round) it
  is **1.61x**. The first number is not a like-for-like result and the second is, which is why both are here.
- **87% of the residual is the direct rule scan** (`doc/measurement.md`, 2026-10-24). The port has **no per-chain index**:
  every decision walks the stack and every file walks its rules in reverse. That is the next lever, and the reference's
  `DirState` and `literal_dirs` ([`zig.md`](zig.md) §2-§3) are the shape to copy.
- **Per-workload residual**: `doublestar` 442.2 ms and `backtrack` 887.9 ms are **73%** of the 1819.8 ms total; `dirs`
  47.9 ms and `flat` 11.8 ms are at the process floor, where start-up subtraction dominates and a further change will not
  be measurable without a different method.
- **What the port still pays that the reference does not**: a split guard per decision rather than a per-directory state,
  a `Map` lookup for the ancestor memo (the reference's is a directory-key hash at 52% of its time — so the same cost,
  smaller), and reverse iteration over every rule of every file on the stack.

## What the split said

- **The DP was right and its first implementation was wrong**, and only a measurement could tell those apart: 6558 ms
  (allocating) against 3286 ms (regex) is the same design as 2407 ms (reusing rows). Copy the design, not the first
  version of it.
- **A total is not a result.** The full DP "won" on the total by 25% while losing on five of six rows by up to 6.6x, and
  the hybrid won the total by another 30% without changing the DP at all. Per-workload rows are the only honest unit.
- **Small wins need a different method.** The literal fast path is 2-8% — below the ~13% noise floor quoted for this
  bench — and was established with 26 paired fresh processes over three sessions, not with the official harness, whose
  own totals moved 21.9 ↔ 22.8 s.
- **The ancestor walk was 95% of the cost and invisible in the totals** until the loop was split into phases. That is the
  single most valuable measurement this port has produced.

## What is left

- **A per-chain index** (87% of the residual). Nothing about it is started in this port; the reference's design is
  described and measured in [`zig.md`](zig.md).
- **A re-run against the current reference.** The 1.61x figure is from 2026-10-24; the reference has gained three changes
  since and no port row has been re-measured.
- **A Java-grade literal fast path is not reachable from here** without routing every pattern through the DP, which this
  port measured as a loss on five rows. Leave the hybrid alone unless a criterion that survives measurement appears.
- **A push/pop fuzz in the port's own gate.** The 54,000-decision differential fuzz lives in the session that made the
  change, not in `js/`'s tests; `bun js/conformance.mjs` and the verdict gate both pass without exercising invalidation.
  That is a hole in the *gate*, not in the code.

## 7. The 2026-10-25 residuals: the unanchored scan and the regex precheck

Two of the four measured residuals were in this port, and they are the two that moved it: **342.0 → 165.0 ms per 12
rounds (2.07x)** in one paired session and **350.8 → 179.4 ms (1.96x)** in a re-run, with `deep` **86.1 → 19.3 ms (4.46x;
re-run 87.6 → 19.6)** and `backtrack` **154.7 → 61.6 ms (2.51x; re-run 164.9 → 60.1)**. The measurements and the method
are in [shared](shared.md#the-four-residuals-of-2026-10-25-measured-in-both-ports); this page records what is particular
to JS.

- **The unanchored scan was 92% of `backtrack`.** A whole-path `indexOf` per name replaced 42 map gets for that workload,
  so the port now uses the name index only at **four or more** unanchored directory literals and the scan below it
  (`backtrack` 4,960 → 245 ns/decision; `deep` 1,204 → 169; `flat` at four names keeps the map, `dirs` at 40 keeps it).
  The gate reads the chain sizes measured on the six workloads: 0, 0, 2, 3, 4, 40 — and the map produced a hit only on
  `dirs`.
- **The regex rules were tested against impossible paths.** `deep` paid 5 whole-path regex tests per decision with a tail
  that rejected all 5; a last-segment precheck before the regex — `endsWithSegment` for a literal tail, one small anchored
  regex for a wildcard tail — took `deep` **49.6 → 22.9 ms (2.17x)**.
- **Interning the directory key was measured and reverted.** The 207-byte key's map get is 315 ns of the 398 ns
  per-decision key cost, and a `Map<string,id>` still hashes the key: the intern form saved 64 ns (16% of the key cost),
  which was **+1.9% of the total and −0.2% on `backtrack`** — inside the noise, so it was not kept.

**What is left, measured on the same harness:** `path.split('/')` is 2.19 µs per decision on `backtrack` (4.4 ms/round),
and it runs *before* the DP's last-segment precheck, which then rejects both DP rules at the tail. Splitting only after a
tail precheck is the next lever, and it is bigger than anything else left in this port.
