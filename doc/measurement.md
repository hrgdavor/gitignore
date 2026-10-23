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