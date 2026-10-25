# Performance: what was tried, what worked, what did not, and where the time goes now

This directory is the record of every performance change this project has made to the `.gitignore` matcher, in the
order they were made, with the number that justified each one. It exists for three readers:

- **someone writing a new port** — [`shared.md`](shared.md) holds the changes that are worth copying into any language,
  each with the measurement that says how much it was worth and the risk it carries;
- **a future maintainer** — the per-language pages say what the code does now and, just as importantly, what was
  **tried and refuted**, so a rejected idea is not re-tried in two months from intuition;
- **anyone about to measure this project** — "How to read these numbers" below says what the numbers can and cannot
  settle, because twice in one afternoon the measurement said one thing and the truth was another
  ([`../measurement.md`](../measurement.md), why that document exists).

The authoritative source for measurements is [`doc/measurement.md`](../measurement.md). Where a number below is not in
that file, its provenance says so explicitly: `commit 9fb0d30, 2026-10-25` for a figure recorded in a commit message, or
**measured by this session's track** for a figure produced by the work that wrote these pages and not yet recorded in
`doc/measurement.md`. A number with no provenance does not appear here.

## The headline table

Both tables are **12 rounds in one process, processing only, start-up subtracted**; a round is one pass over the
workload's path list, so a per-round figure is a total divided by 12.

### The initial implementation — kept permanently, because a relative gap only means something against a fixed baseline

| workload   | Zig        | JS                      | Java                    |
| ---------- | ---------: | ----------------------: | ----------------------: |
| flat       | 10.0 ms    | 44.9 ms                 | 77.5 ms                 |
| deep       | 112.3 ms   | 1225.5 ms               | 1504.1 ms               |
| doublestar | 149.3 ms   | 1067.1 ms               | 2328.0 ms               |
| anchored   | 29.4 ms    | 247.1 ms                | 562.2 ms                |
| dirs       | 9.3 ms     | 64.2 ms                 | 65.4 ms                 |
| backtrack  | 796.9 ms   | 16360.8 ms              | 7867.8 ms               |
| **total**  | **1107.1** | **19009.7 (17.2x Zig)** | **12405.0 (11.2x Zig)** |

Per round: Zig **92.3 ms**, JS **1584.1 ms**, Java **1034.0 ms**.
Provenance: [`doc/measurement.md`](../measurement.md), "Steady state, 12 rounds, one process each" (committed
2026-10-23, `86f9efd`).

### Today

| workload   | Zig           | Zig speed-up | JS (last run) | JS speed-up | Java (last run) | Java speed-up |
| ---------- | ------------: | -----------: | ------------: | ----------: | --------------: | ------------: |
| flat       | 5.9 ms        | 1.7x         | 11.8 ms       | 3.8x        | 48.0 ms         | 1.6x          |
| deep       | 26.1 ms       | 4.3x         | 239.9 ms      | 5.1x        | 343.6 ms        | 4.4x          |
| doublestar | 19.1 ms       | 7.8x         | 442.2 ms      | 2.4x        | 1101.4 ms       | 2.1x          |
| anchored   | 14.0 ms       | 2.1x         | 190.1 ms      | 1.3x        | 292.2 ms        | 1.9x          |
| dirs       | 7.1 ms        | 1.3x         | 47.9 ms       | 1.3x        | 45.8 ms         | 1.4x          |
| backtrack  | 35.9 ms       | 22.2x        | 887.9 ms      | 18.4x       | 658.6 ms        | 11.9x         |
| **total**  | **108.1 ms**  | **10.2x**    | **1819.8 ms** | **10.4x**   | **2489.7 ms**   | **5.0x**      |
| per round  | **9.0 ms**    |              | **151.7 ms**  |             | **207.5 ms**    |               |

- **Zig**: measured by this session's track, 2026-10-25 (12 rounds, total 108 ms).
- **JS and Java**: their **last** measurement — [`doc/measurement.md`](../measurement.md), "Closing the port gap:
  17.2x -> 1.61x, by memoising ancestors" (2026-10-24, `a5331f6`). They have **not been re-run** after the reference's
  last three changes (`7053629`, `ecff1ff`, `9fb0d30`), all of which touched `src/ignore.zig` / `src/gitignore.zig`
  only. The port rows are therefore accurate for the port code and stale against the reference.
- **Speed-ups are against the initial table above**, per row, same column.
- **Later on 2026-10-25, the four-residual track re-measured both ports**: **JS 165.0 ms and Java 517.8 ms for 12 rounds**
  (paired, min of 9), after a size gate on the unanchored-name index in both ports and a last-segment precheck for the JS
  regex rules. The rows above predate those two changes *and* the three indexes, so do not mix them with the new totals —
  [`shared.md`](shared.md#the-four-residuals-of-2026-10-25-measured-in-both-ports) has the per-workload table.

What those speed-ups mean, stated per port rather than as one slogan:

| statement                                      | number                                | against                                                |
| ---------------------------------------------- | ------------------------------------: | ------------------------------------------------------ |
| the reference is faster than it was            | **10.2x** (92.3 → 9.0 ms/round)       | its own initial steady state                           |
| the reference is ~7x faster                    | **7.0x** (1107.1 → 158.2 ms)          | the last total `doc/measurement.md` records            |
| the JS port is faster than it was              | **10.4x** (1584.1 → 151.7 ms/round)   | its own initial steady state                           |
| the Java port is faster than it was            | **5.0x** (1034.0 → 207.5 ms/round)    | its own initial steady state                           |
| JS stood behind the reference by               | **17.2x → 1.61x**                     | Zig's total *at the time of that paired run*           |
| Java stood behind the reference by             | **11.2x → 2.20x**                     | Zig's total *at the time of that paired run*           |
| JS stands behind the reference **today** by    | **16.9x** (151.7 / 9.0)               | the reference's 2026-10-25 figure — *not a paired run* |
| Java stands behind the reference **today** by  | **23.1x** (207.5 / 9.0)               | the reference's 2026-10-25 figure — *not a paired run* |

The last two rows are the reason the two claims coexist without contradicting: the ports reached 1.61x and 2.20x of a
reference that measured ~94 ms/round (a total near 1130 ms), and the reference then got **another 10x faster** on its own.
The ports are ~10x and ~5x faster than their own starting points; the reference is 10x faster than its own. The
"everything is now within 2x" reading is true of one afternoon in October and of nothing after it, and the honest way to
write it down is the table above rather than the sentence.

## How to read these numbers

1. **`--rounds 12` is the only comparison worth making.** All three CLIs accept `--rounds N` and repeat the decision loop
   inside one process, printing one verdict per path ([`src/decide_main.zig`](../../src/decide_main.zig),
   [`js/decide.mjs`](../../js/decide.mjs), [`java/.../Decide.java`](../../java/src/hr/hrg/gitignore/Decide.java)). A
   cold, one-round process measures the loader and the JIT: `backtrack` reported 3205 ms and 5129 ms on consecutive runs
   of the same Java build ([`../measurement.md`](../measurement.md)), and Java's own CLI documents a 60% variation
   between runs on the small workloads.
2. **Start-up is measured separately and subtracted.** A run with an empty path list costs what a process costs before it
   decides anything (~10.8 ms for the Zig CLI on 2026-10-25, ~11 ms in the project README's start-up row). On the small
   workloads the subtraction is most of the number: `flat` at 12.5 ms raw against 10.8 ms start-up is **1.7 ms of
   matcher**, and a start-up estimate 1 ms off moves it by 60%.
3. **~13% run-to-run variance at 12 rounds**, recorded explicitly in [`../measurement.md`](../measurement.md): the
   restored Java build measured 12 405 ms and 14 018 ms an hour apart. Nothing smaller than that is a result. The JS
   literal fast path (2-3% on `doublestar`) is below it and was therefore decided on a different method — see next point.
4. **Anything near the noise floor needs paired alternating runs.** The JS literal fast path and the JS ancestor
   memoisation were both decided that way: alternate old and new builds in fresh processes, several sessions, trust only
   the paired difference. Between-session drift moved the old JS build's total from 16.7 s to 19.8 s, which would have
   let an unpaired comparison say anything at all.
5. **Absolute totals are not comparable across sessions.** This is stronger than the 13% above and worth knowing before
   quoting one. The *same* committed build (`9fb0d30`) has three totals in its own record: **50.8 ms** (commit
   `9fb0d30`), **83.8-86.1 ms** (re-run while writing this page, min of 5, 12 rounds) and **108.1 ms** (the closing
   table above). The three agree on ordering in every row, and `doublestar` is 15.1 / 15.3 / 19.1 ms across them (the
   first two agree to 5%, the third is 26% above them); the totals differ because six small subtracted numbers each carry
   the start-up error. **Quote a total with the session
   that produced it, and compare only within that session.**
6. **`bun scripts/check-verdicts.mjs` is the correctness gate, not an afterthought.** It runs the three implementations
   over all six workloads and compares **10,000 verdicts** byte for byte, naming the first differing line and exiting
   non-zero; a missing binary is a failure, never a skip. The gate was committed on 2026-10-25 (`f876506`); before it, a
   change was verified by the 34 vectors plus a hand comparison of the six workloads' verdict streams — and the reason the
   gate exists is that "the vectors still pass" had several times been true while the workload's answers had changed.
   Changes from `ecff1ff` onward carry the gate, and it was verified again while writing this page: `6/6 workloads agree;
   10000 verdicts byte-identical across 3 ports` (2026-10-25). The vectors are the contract for *cases*; this gate is the
   contract for the workload.

## The improvements, in one table

Every row links to the page that gives the split, the change, the measured effect and the risk.

| #   | change                                                         | port(s)       | measured effect                                                                                | detail                                                                                           |
| --  | -------------------------------------------------------------  | ----------    | --------------------------------------------------------------------------------------------   | -----------------------------------                                                              |
| 1   | replace regex translation with the segment DP                  | all three     | `backtrack` 2902.4 → 1462.6 ms (2.0x) on JS; Java 212 486 → 50 010 ms (4.25x)                  | [shared](shared.md#1-replace-the-regex-translation-with-a-segment-dp)                            |
| 2   | memoise a directory's decided answer, cleared on `push`/`pop`  | JS, Java      | JS 19 384.5 → 1819.8 ms (10.6x); Java 13 246.7 → 2489.7 ms (5.3x)                              | [shared](shared.md#2-memoise-a-directorys-decided-answer)                                        |
| 3   | compare a literal segment with equality, not a regex/`Matcher` | Java, JS, Zig | Java 50 010 → 18 217 ms (**3.03x**); JS 2-3% / 4-8%; Zig by construction                       | [shared](shared.md#3-compare-literal-segments-with-equality)                                     |
| 4   | split the path once per decision                               | JS, Java      | JS `backtrack` 6558 → 1489 ms with reused rows (4.4x); Java 18 217 → 17 723 ms (2.8%)          | [shared](shared.md#4-split-the-path-once-per-decision)                                           |
| 5   | a last-segment precheck for non-`**` patterns                  | Zig           | `backtrack` 101.6 → 28.4 ms (**3.58x**)                                                        | [shared](shared.md#5-a-last-segment-precheck)                                                    |
| 6   | per-directory `DirState` (chain + inherited ancestor flag)     | Zig           | total 1 081 → 284 ms (**3.81x**); `backtrack` 799.4 → 103.2 ms (7.7x)                          | [zig](zig.md#2-a-directory-chain-in-one-hash-dirstate)                                           |
| 7   | `Chain.literal_dirs`: anchored literals bucketed by depth      | Zig           | `doublestar` 135.4 → 15.1 ms (**8.99x**); total 281.6 → 158.2 ms (1.78x)                       | [zig](zig.md#3-anchored-literal-bucket-chainliteral_dirs)                                        |
| 8   | a manual `nextSeparator` instead of `indexOfScalarPos`         | Zig           | 20.4 → 3.66 ms of separator scanning over the same paths                                       | [zig](zig.md#4-the-last-segment-precheck-and-a-manual-nextseparator)                             |
| 9   | rule classes at parse time, and a per-chain index              | Zig           | in place before the 3.81x baseline; rules tested per path 5 / 19 / 98 / 17 / 45                | [zig](zig.md#1-the-baseline-in-place-before-any-of-this)                                         |
| 10  | keep the compiled regex unless the pattern has a `**`          | JS            | full DP was 1.6x-6x slower on five rows; hybrid 1661.2 vs regex 3128.2 and full DP 2360.7 ms   | [js](js.md#3-the-hybrid-the-regex-everywhere-except-patterns-with-a-double-star)                 |
| 11  | reused scratch rows, and `ThreadLocal` scratch in Java         | JS, Java      | inside row 4's 4.4x and 2.8%; the DP's arithmetic was never the cost                           | [js](js.md#1-allocation-discipline-the-first-dp-was-slower-than-the-regex)                       |
| 12  | gate the unanchored-name index by chain size                   | JS, Java      | JS `backtrack` 159.3 → 61.0 ms (**2.61x**), `deep` 82.4 → 48.8; Java `backtrack` +12.7%/+17.5% | [shared](shared.md#3-the-unanchored-directory-name-index-gated-by-chain-size-kept-in-both-ports) |
| 13  | last-segment precheck for the JS regex rules                   | JS            | `deep` 49.6 → 22.9 ms (**2.17x**); nearly every regex test was against an impossible path      | [shared](shared.md#4-the-last-segment-precheck-for-the-js-regex-rules-kept)                      |

## What did not work

The most valuable content here for a new port is this list, not the one above. Each was measured, each was reverted
rather than kept as complexity, and each is argued in full in the linked page.

| refuted idea                                                       | number                                                             | why it failed                                                                            |
| ------------------------------------------------------------------ | -----------------------------------------------------------------: | ---------------------------------------------------------------------------------------- |
| the DP only for patterns with **two or more** `**` segments        | 15 641 ms vs 12 405 ms (**26% worse**)                             | `**/*.class` has one `**` and the regex is slower on it                                  |
| the DP only for patterns with **any** `**` (Java)                  | 71 355 ms vs 50 010 ms (**43% worse**)                             | one `**` saves nothing in the DP, and directory-only rules paid a `Matcher` per ancestor |
| a DP memo per (pattern, path)                                      | never fired                                                        | no (pattern, path) pair is recomputed within a decision                                  |
| a first-byte bitmap                                                | **0.9 ms** gained                                                  | the first byte was never the cost                                                        |
| a last-directory memo                                              | no gain (13.2 ms compare vs 13.7 ms map-get), **regressed `deep`** | the directory key hash was already the cheap part                                        |
| indexing exact anchored literals (not only directory-only ones)    | regressed `deep`                                                   | a chain holds one or two of them; one comparison beats an index walk                     |
| interning the directory key (`Map<string,id>` + array)             | JS total **+1.9%**, `backtrack` −0.2%; Java total **−1.4%**        | the id map hashes the same string, so the hash is paid either way                        |
| `int` tri-state instead of `Optional<Boolean>` on the hot path     | total **11.4% worse** (1.8% in the reversed order)                 | the JIT already scalar-replaced the `Optional` across the inlined calls                  |

Provenance: rows 1 and 2, [`../measurement.md`](../measurement.md) (2026-10-23, `708366b`); rows 3-6, commit
`9fb0d30` and `ecff1ff` (2026-10-25), i.e. measured by this session's track.

## Where the time goes now

- **Zig** (1,123 ms of baseline work, re-split after the 3.58x change): **52% directory-key hash**, **37% chain scan**,
  **10.5% the last-segment precheck**, **0% DP cells** — the precheck now rejects `backtrack`'s failing rule before the
  dynamic program runs at all. Measured by this session's track, 2026-10-25. The immediately preceding split, on
  `backtrack` alone, was DP rows 42.6 ms (41.7%), pattern+path splitting 22.6 ms (22.1%), chain literal scan 22.2 ms
  (21.8%) and chain lookup 14.6 ms (14.3%) (commit `9fb0d30`), which is what the precheck attacked.
- **JS**: after the 2026-10-25 gate and precheck the direct rule scan is no longer 87%: the remaining large rows are
  **`path.split('/')` 4.4 ms/round on `backtrack`**, and the split runs before the DP precheck that then rejects both DP
  rules ([`js.md`](js.md#7-the-2026-10-25-residuals-the-unanchored-scan-and-the-regex-precheck)).
- **Java**: the first phase split of the loop was recorded on 2026-10-25, and it puts **`String.split("/", -1)` at 5.0
  ms/round on `backtrack` (43% of its 11.6), 1.99 ms on `deep`** — larger than every residual the four-item track
  attacked ([`java.md`](java.md#8-the-2026-10-25-residuals-the-unanchored-name-gate-and-two-rejections)).

## The files

| file                      | what it is                                                                                     |
| ------------------------- | ---------------------------------------------------------------------------------------------- |
| [`shared.md`](shared.md)  | improvements that apply to **any** port, and the refuted ideas, with numbers                   |
| [`zig.md`](zig.md)        | the reference implementation: `DirState`, `literal_dirs`, the precheck, the bug the fuzz found |
| [`js.md`](js.md)          | the JavaScript port: allocation discipline, the DP, the hybrid, the ancestor memo              |
| [`java.md`](java.md)      | the Java port: the layout, `String.equals`, `ThreadLocal` rows, the ancestor memo              |

## What the split said

The single most useful thing this directory records is methodological, and every page repeats it in its own shape:

- **Profile before changing.** Three of the four biggest wins were applied to code that a split had already shown to be
  the cost — chain resolution at 49% (`7053629`), ancestor re-decisions at 95% of the JS loop (`a5331f6`), DP rows plus
  splitting at 65% of `backtrack` (`9fb0d30`). The two changes that were made from the shape of the code instead of a
  split are the ones that had to be refuted afterwards: the two-or-more-`**` criterion and the hybrid that kept the
  regex for patterns without `**` (worse on Java's total, kept on JS because it was measured there first).
- **The cost is almost never the comparison.** It was `Matcher` allocation in Java (3.03x), two arrays and a split per
  rule in JS (`backtrack` 6558 → 1489 ms), and an upward directory walk on both — never the string comparison or the
  arithmetic.
- **A change is worth the share of the time its code owns.** The same literal fast path is 3.03x in Java (every pattern
  goes through the DP) and 2-3% in JS (only `**` patterns do). Neither number is wrong; they measure different things.

## What is left

- **Re-measure the ports against the current reference.** The JS and Java rows are from 2026-10-24 and the reference has
  since gained `7053629`, `ecff1ff` and `9fb0d30`. Until they are re-run, the honest comparison is the same-session one
  (1.61x / 2.20x), not the cross-session one (16.9x / 23.1x).
- **Give the ports the reference's per-chain index.** `doc/measurement.md` names it as the next lever for JS (87% of the
  residual is the direct rule scan) and it is unstarted. Everything in [`zig.md`](zig.md) §2-§3 is the shape to copy.
- **A phase split of the Java loop.** Every other optimisation here began with one; Java's first was recorded on
  2026-10-25, and what it found is the next lever: `String.split("/", -1)` (5.0 ms/round on `backtrack`) and the eager
  split before the DP precheck. Both ports have the same two problems, measured in
  [`shared.md`](shared.md#the-four-residuals-of-2026-10-25-measured-in-both-ports).
- **A stable measurement harness.** Item 5 of "How to read these numbers" is a defect in the method, not in the code: the
  same build has three totals. A harness that interleaves the configurations in one run and reports the paired
  difference would make every future entry in this directory cheaper to establish.
