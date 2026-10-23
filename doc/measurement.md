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

## What is still open

- The unmeasured criterion above is the biggest known win: DP for a pattern with two or more `**` segments, or for a
  directory-only rule, and the compiled regex otherwise. The workloads support it (`backtrack`'s worst pattern has three,
  `doublestar`'s have one at most), but the edit that would have measured it broke `decide` and was reverted rather than
  guessed at.
- Per-rule `Matcher` reuse for the regex branch: `pattern.matcher(path)` allocates, and a rule answers once per path.
- Neither port has the Zig implementation's per-chain indexing, which is the next idea worth copying — and the first one
  that would show up in the small workloads rather than in `backtrack`.
