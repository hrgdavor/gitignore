# Measuring the ports

## Why this document exists

Twice in one afternoon the measurement said one thing and the truth was another: a change that improved the **total** had
made five workloads out of six slower, and a change that looked like a regression was inside the run-to-run noise of a
cold process. This records how the numbers in `README.md` are produced and what they can and cannot settle.

## The two modes

| mode              | how                                      | measures                                                             | cannot settle                                         |
| ----------------- | ---------------------------------------- | -------------------------------------------------------------------- | ----------------------------------------------------- |
| cold, per process | `bun bench/perf.mjs --repeat N --port …` | what a tool pays when it is invoked once: loader, JIT, then the work | differences below the process's own variance          |
| steady state      | `… --rounds 12`                          | the matcher, with warm code; divide by 12 for one round              | start-up, which is reported separately and subtracted |

The cold mode is the honest end-to-end number for a CLI. It is also why the same Java build reported `backtrack` at
3205 ms and 5129 ms on consecutive runs, and why the small workloads (a few ms, obtained by subtracting a ~110 ms start-up)
should not be compared to one decimal place.

## Steady state, 12 rounds, one process each

All three CLIs accept `--rounds N`: they repeat the decision loop inside one process and print one verdict per path, so the
number below is 12 rounds together and steady state is a twelfth of it. Processing only; start-up is measured separately
and subtracted, as always.

| workload      | Zig           | JS                     | Java                   |
| --------      | --:           | -:                     | ---:                   |
| flat          | 10.0 ms       | 44.9 ms                | 77.5 ms                |
| deep          | 112.3 ms      | 1225.5 ms              | 1504.1 ms              |
| doublestar    | 149.3 ms      | 1067.1 ms              | 2328.0 ms              |
| anchored      | 29.4 ms       | 247.1 ms               | 562.2 ms               |
| dirs          | 9.3 ms        | 64.2 ms                | 65.4 ms                |
| **backtrack** | **796.9 ms**  | **16360.8 ms**         | **7867.8 ms**          |
| total         | **1107.1 ms** | **19009.7 ms (17.2x)** | **12405.0 ms (11.2x)** |

Per round: Zig **92 ms**, Java **1034 ms**, JS **1584 ms**.

Two things this table settles that the cold one could not:

- **Java is the faster port**, and it wins the workload that dominates the total (`backtrack`: 656 ms per round against JS's
  1363). That reverses the cold-process ordering, which is how much JIT warm-up was in the earlier numbers.
- The regex translation is not a JS-only problem: with Java on the DP for every pattern, its `doublestar` (194 ms per
  round) is **twice** the regex-shaped JS one, which is evidence for the criterion below.

## What was tried on the Java port, and what each one did

Measured at 12 rounds, total processing:

| change                                              | total         | verdict                                                                                       |
| --------------------------------------------------- | ------------: | --------------------------------------------------------------------------------------------- |
| regex only                                          | 212486        | 4.25x slower than full DP — `backtrack` alone is 203 s                                        |
| full DP                                             | 50010         | baseline for the comparisons below                                                            |
| hybrid, DP when a pattern has any `**`              | 71355         | **worse**: a single `**` saves nothing in the DP, and the directory-only rules paid a substring + Matcher per ancestor |
| hybrid, DP when two or more `**`, or directory-only | not completed | the two-line edit was reverted after it broke `decide`; the criterion is sound but unmeasured |
| full DP + literal segment fast path                 | **18217**     | **3.03x better** — most DP segment tests were comparing a name through `Pattern.matcher(…).matches()`, which allocates a Matcher per segment per path |
| full DP + literal path + reused rows + `--rounds`   | 17723         | the same code, measured with the harness's own improvement                                    |

The lesson is the same one the JS port learned, twice: **allocation, not comparison**. The DP's arithmetic was never the
cost; allocating a `Matcher` (Java) or two arrays (JS) per decision was.

## The criterion that failed

The steady-state table above suggested a rule: use the DP only where a pattern has **two or more** `**` segments, and the
compiled regex everywhere else. `backtrack`'s worst rule is `src/**/test/**/impl/**/*.g4` (three), `doublestar`'s rules have
at most one, and the DP was visibly costing Java on `doublestar`.

Implemented and measured: **refuted**.

| configuration                                 | total (12 rounds) | backtrack | doublestar |
| --------------------------------------------- | ----------------: | --------: | ---------: |
| full DP + literal segments + split once       | 12 405 ms         | 7 868 ms  | 2 328 ms   |
| the same, with the two-or-more-`**` criterion | 15 641 ms         | 9 722 ms  | 3 259 ms   |

The cause is one rule in the workload: `**/*.class`. It has a single `**`, so the criterion sends it to the regex, whose
`(?:.*/)?[^/]*\.class$` is slower on these paths than the DP's row scan. "One `**`" is not "cheap": it depends on the
pattern and on the path depth, and a criterion that ignores that is a guess wearing a measurement's clothes.

Both numbers moved in the same direction, in the run that produced each, so the direction is not in doubt. The **size** is:
this bench has ~13% run-to-run variance at 12 rounds (the restored build measured 12 405 ms and 14 018 ms an hour apart), and
nothing below that margin should be read as a result. The next comparison should interleave the two configurations in one
run rather than compare two runs.

## What is still open

- A criterion that survives measurement. "Two or more `**`" does not (see above); what the data supports is "the DP is
  never slower than the regex on these workloads", which argues for keeping the DP everywhere and optimising inside it —
  the literal fast path and the split were worth 4.4x between them.

- Per-rule `Matcher` reuse for the regex branch: `pattern.matcher(path)` allocates, and a rule answers once per path.
- Neither port has the Zig implementation's per-chain indexing, which is the next idea worth copying — and the first one
  that would show up in the small workloads rather than in `backtrack`.
## The literal fast path, ported to JS

The Java port gained 3.03x from comparing plain pattern segments with `equals` instead of `Pattern.matcher(…).matches()`. The
same change in `js/glob.mjs` is worth much less, and the reason is instructive:

- **doublestar**: ~2-3% (faster in 22 of 26 paired processes; one session had all 10 new values below all 10 old).
- **backtrack**: ~4-8% (faster in 19 of 26 pairs; means -8.1%, -6.3%, -4.4% across three sessions).
- **the other four workloads**: 0 DP segments, so they never reach the change; their variation is the ~±4% noise floor.

The Java port gained more because it routes **every** pattern through the DP; the JS port routes only patterns containing
`**`, so four of six workloads never touch the fast path, and on the two that do the ancestor slice/join loop dominates. A
change being worth 8% in one port and 300% in another is not a contradiction: it is a measurement of how much of the time
the changed code actually owns.

Method note: the official harness at `--repeat 1 --rounds 12` put the totals inside its own noise (21.9 s vs 22.8 s with
start-up subtraction differing 83 vs 50 ms), so the decision was made on **alternating paired fresh processes** with the loop
timed directly, three sessions, and only the paired result trusted - between-session drift moved the old build from 16.7 s to
19.8 s, which would have made any unpaired comparison say whatever the drift said.
## Closing the port gap: 17.2x -> 1.61x, by memoising ancestors

The ports were 17.2x (JS) and 11.2x (Java) behind Zig, and the obvious suspect — the matcher — was wrong. A phase split of the
JS loop (per round, medians, the halves summing to the total) put **95% of the cost in re-deciding ancestors**: `backtrack`
asked about 84,000 ancestor directories when only **42** were distinct, `deep` 26,000 over 286. Parsing and chain building were
noise, because the bench chain is a single root file.

So `GitIgnoreRules` memoises each directory's excluded answer, cleared by `push`/`pop` — the only stack changes, so a cached
answer cannot outlive its stack — ancestors come from walking separators backwards (one substring, no split+join), and
`GitIgnoreFile.decide` splits the path once per decision rather than once per `**` rule.

Paired alternating A/B, 8 fresh processes x 12 rounds, verdicts byte-identical:

| workload      | JS before   | JS after   | Java before | Java after |
| ------------- | ----------: | ---------: | ----------: | ---------: |
| flat          | 15.1        | 11.8       | 59.5        | 48.0       |
| deep          | 1191.3      | 239.9      | 1553.7      | 343.6      |
| doublestar    | 1098.3      | 442.2      | 2468.9      | 1101.4     |
| anchored      | 255.9       | 190.1      | 586.4       | 292.2      |
| dirs          | 58.6        | 47.9       | 56.0        | 45.8       |
| **backtrack** | **16765.2** | **887.9**  | **8522.2**  | **658.6**  |
| total         | 19384.5     | **1819.8** | 13246.7     | **2489.7** |

Standing against Zig, per round: **JS 1.61x, Java 2.20x** — an independent re-run here measured Zig 1073.9 ms against JS
1822.5 ms, i.e. 1.70x, the same claim inside the harness's noise. The smallest per-workload gain is -18.2% (`dirs`), above the
~13% floor, and every comparison is paired, so nothing rests on between-session drift.

Correctness beyond the 34 vectors: JS, Java and Zig verdicts byte-identical across all six workloads (10,000 paths) before and
after, and 54,000 randomised decisions over 300 random multi-file stacks x 5 seeds identical between old and new JS — which is
what exercises the memo's invalidation rather than assuming it.

**What is left**: 87% of the residual is the direct rule scan, and the remaining lever is Zig's rule-chain index
(`**/x` -> basename suffix, literal/suffix/anchored classes, first-segment prune). It is unstarted, and it now owns a much
smaller absolute number than it would have before this change.
## The Zig reference gets the same treatment: 3.81x

After the ports were fixed by memoising ancestors, the reference was measured for the first time. The split of `ignore.Stack.decide`
across the six workloads (1,123 ms total): **chain resolution — the upward walk that finds the deepest `.gitignore` — 548 ms
(49%)**, ancestor memo walk 295 ms (26%), per-rule matching 237 ms (21%), ancestor re-decisions 26 ms (2%). Rules per path were
already indexed (5 flat, 19 deep, 98 doublestar, 17 anchored, 45 backtrack), so a rule index could only reach the 21%.

The index: a per-directory `DirState` (directory -> resolved chain, plus the inherited ancestor-excluded flag). One hash per path
replaces both upward walks; misses keep the old semantics, and a `dirname` guard preserves the historical answer for
out-of-contract paths.

| workload      | before ms | after ms  | speed-up            |
| ------------- | --------: | --------: | ------------------: |
| flat          | 4.3       | 1.4       | ~3x (process floor) |
| deep          | 111.8     | 24.7      | 4.5x                |
| doublestar    | 142.0     | 136.1     | 1.04x (noise)       |
| anchored      | 18.7      | 15.0      | 1.25x               |
| dirs          | 5.1       | 3.2       | 1.6x                |
| **backtrack** | **799.4** | **103.2** | **7.7x**            |
| total         | **1,081** | **284**   | **3.81x**           |

Paired alternating runs, min of 9, `--rounds 12`; three sessions reproduced 3.73-3.87x. An independent re-run here measured
backtrack 110.6 ms and deep 29.7 ms, matching. Verdicts are byte-identical on all six workloads, and a differential fuzz of
`decide` against the untouched `decideNaive` found 0 disagreements over 6,000 decisions on 300 random multi-file stacks.

**What is left**: doublestar is now 48% of the remaining total, and its 100 anchored literal rules share the first segment
`java`, so a first-segment prune rejects none of them; an anchored-literal bucket keyed by depth is the next lever. Backtrack's
13.8 ms directory-key hash would fall to a last-directory memo.

The parity claim above is not a one-off measurement: `bun scripts/check-verdicts.mjs` is the committed gate that runs all three implementations over the six workloads and compares 10,000 verdicts byte for byte, naming the first differing line and exiting non-zero. It treats a missing binary as a failure, not a skip.
