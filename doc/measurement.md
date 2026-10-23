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

## Steady state, 12 rounds, one process each (processing only)

Per round, divided by 12:

| workload      | JS            | Java         |
| --------      | -:            | ---:         |
| flat          | 2.0 ms        | 8.7 ms       |
| deep          | 99.6 ms       | 177.0 ms     |
| doublestar    | 91.9 ms       | 307.7 ms     |
| anchored      | 22.1 ms       | 78.0 ms      |
| dirs          | 5.8 ms        | 12.9 ms      |
| **backtrack** | **1546.0 ms** | **892.6 ms** |
| total         | 1767.3 ms     | 1476.9 ms    |

JS is faster on five workloads; Java wins the one that dominates the total. That is the same shape as the JS port's own
history: a regex translation is faster everywhere until a pattern with several `**` segments makes it explore
exponentially many splits.

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

- The unmeasured criterion above: two-or-more `**` wins on paper (the `backtrack` workload's worst pattern has three, and a
  single `**` is what `doublestar` has), but the edit that would have shown it was broken and reverted rather than guessed
  at.
- The Zig reference has no `--rounds` mode, so the three-way table mixes a cold Zig with steady-state ports. A fair
  three-way comparison needs the same mode on all three.
- Neither port has the Zig implementation's per-chain indexing, which is the next idea worth copying — and the first one
  that would show up in the small workloads rather than in `backtrack`.
