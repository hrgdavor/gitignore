# gitignore — one matcher, one set of vectors, many ports

The `.gitignore` matcher and the directory-chain lookup that `fs-meta` used, lifted out so that **ports can share
the format, the vectors and the measurements** instead of each re-deriving them.

**These basis projects are vibe coded.** That is said plainly because it is true: the Zig implementation here was
written with an AI agent, in one long session, against a real tree (Apache Fory) whose `.gitignore` defeated three
earlier designs. Every hand-crafted improvement is welcome — a faster matcher, a clearer API, a different data
structure — and so is using this as the **basis for another port or a reimplementation**. The vectors and the
benchmark exist so that a rewrite can prove it is both faster and still correct; they are not here to protect this
implementation.

## What moves here

| from `fs-meta/src` | what it is                                                                             |
| ------------------ | -------------------------------------------------------------------------------------- |
| `gitignore.zig`    | pattern parsing, the `Rules` matcher, the segment-DP `globMatch`                       |
| `ignore.zig`       | the directory chain: which `.gitignore` files govern a directory, flattened and cached |

`fs-meta` will depend on this project rather than carry the code. The batch diff, the trio, the engine and the
watcher stay in `fs-meta`; nothing about a trio belongs here.

## Why it is its own project

Three problems are the same for every port, and each one is cheaper to solve once:

1. **Correctness.** Git's precedence is subtle — last match wins, a deeper file wins, an excluded directory is not
   entered, `**` has three forms, `!` re-includes, a trailing `/` means directories only. A port that gets one wrong
   behaves plausibly and wrongly.
2. **Performance.** The failures were not mysterious once measured, and every one of them was a shape a synthetic tree
   can reproduce:
   - a **naive recursive** matcher, exponential on `**` with a deep path: ~4,700 ms for a 3,900-entry pass;
   - a **superlinear `decide`** — 20 rules already cost 1,466 ms, because every entry scanned every rule;
   - **anchored `**` rules** left in the general-glob class, each walking ancestor prefixes: 2.97× the no-matcher
     pass;
   - the same rules **with their literal first segment pruned**: 1.6–1.8×, inside budget.
3. **Comparability.** A Java or JS port cannot know whether its 4 ms is good or 40× worse than it should be. One
   workload, one output format, one number.

## Shape

```text
gitignore/
  src/gitignore.zig        the matcher (moved from fs-meta)
  src/ignore.zig           the chain (moved from fs-meta)
  src/conformance_test.zig the vectors as a test
  src/decide_main.zig      the bench contract as a CLI (`ignore-decide`)
  conformance/             vectors every port must pass, the runner's file, and the corpus generator
  bench/                   the workloads and the runner
  doc/                     the rules as implemented, the porting guide, and where the corpus comes from
```

The **vectors** are JSON: a case is `{ name, ruleFiles, path, isDir, expect }` where each rule file is a `{ dir,
rules }` pair and `expect` is `include`, `exclude` or `no-opinion` (the chain's three-valued answer). They were
hand-authored from [`doc/rules.md`](doc/rules.md) and are run by
[`src/conformance_test.zig`](src/conformance_test.zig), which materialises each case as a real temporary tree and
answers it through the chain. The file is **not** generated from the Zig implementation: it is written from the
rules, so a disagreement is a port bug or a finding to report back — the unterminated-class case was the latter, and
[`conformance/README.md`](conformance/README.md) records the correction.

The **bench contract** is one CLI:

```text
<port> --rules <file.gitignore> --paths <file.txt> [--dirs <file>]   → one line per path: include|exclude|no-opinion
```

so a port is measured on identical input, and the runner does not need to know the language. `--dirs` takes one
`0`/`1` per path, so directory-only rules are measured without a second format. The reference is
[`src/decide_main.zig`](src/decide_main.zig); the workloads are generated, never checked into a repository, and the
runner verifies the **verdict count equals the path count** before it reports a time.

### Building and running it

```text
cd gitignore
D:\wrk\zig\17\zig.exe build -Doptimize=ReleaseFast                        # zig-out/bin/ignore-decide
D:\wrk\zig\17\zig.exe build -Dnaive=true -Doptimize=ReleaseFast            # zig-out/bin/ignore-decide-naive
bun bench/perf.mjs --emit
bun bench/perf.mjs --port "zig-out/bin/ignore-decide.exe --rules {rules} --paths {paths}" --repeat 5 --label indexed
bun bench/perf.mjs --port "zig-out/bin/ignore-decide-naive.exe --rules {rules} --paths {paths}" --repeat 5 --label naive
```

`--naive` is the historical design kept as a benchmark mode: every rule of the chain is scanned instead of using the
per-kind index, and `**` is matched by a recursion that retries the rest of the pattern at every position instead of
the segment dynamic program. The naive code is **not in the default executable** — nothing it runs references either
function, so Zig never analyses them there; the tests do call both, which is how they are kept honest — and the naive
build installs under a distinct name so both can sit in `zig-out/bin`.

### Measured

ReleaseFast, best of 5, Windows 11, Zig 0.17.0 (2026-10-21). One process per workload, so the fixed cost of process
start-up, reading the inputs and creating/removing the temporary root (about 12 ms) is included in every row; compare
within a row, not across rows.

| workload   | verdicts | indexed ms | naive ms |
| ---------- | -------: | ---------: | -------: |
| flat       | 1000     | 13.0       | 13.4     |
| deep       | 2000     | 34.8       | 37.3     |
| doublestar | 2000     | 37.9       | 38.1     |
| anchored   | 2000     | 22.0       | 24.1     |
| dirs       | 1000     | 13.8       | 15.9     |
| backtrack  | 2000     | 89.2       | 558.1    |

`backtrack` is the row that makes the recursive matcher's shape visible: a rule with three `**` segments and a path
that repeats their literal neighbours, so every split is tried and the final `*.g4` never matches. It is 6.3× slower
in the naive build, and its size is chosen so the row fits in a normal bench run. The other rows are close because
`**/x` normalises to an indexed class (`**/*.cpp` becomes a suffix rule) and the process start-up dominates 1–2k
paths at these times.

The historical figures in this README — the ~4,700 ms recursive pass, the 1,466 ms superlinear `decide`, the 2.97×
anchored-`**` pass — were measured on a real 3,900-entry tree against the designs that preceded this one. The table
above reproduces the **shapes** at a size a gate can afford; it does not reproduce those magnitudes, and a port should
quote its own numbers with the tree, build and date rather than these.

## Status

Steps 1–6 of [`plans/next-steps.md`](plans/next-steps.md) are implemented:

- the vectors are a gate: [`src/conformance_test.zig`](src/conformance_test.zig) materialises all 34 cases, and a
  generated corpus can be run with `-Dvectors=<file>`;
- the rules table is [`doc/rules.md`](doc/rules.md), with every vector name in a row and every row linked to a test;
- the bench contract is a CLI ([`src/decide_main.zig`](src/decide_main.zig)), with `--dirs` for directory-only rules;
- the historical designs are `-Dnaive=true`, measured against the current one in the table above;
- the porting guide is [`doc/porting.md`](doc/porting.md);
- the corpus generator is [`conformance/from-git-check-ignore.mjs`](conformance/from-git-check-ignore.mjs), a
  separate step because it needs a checkout CI will not have.

What remains is **publishing** (step 7): once this project has a version, `fs-meta`'s path dependency
(`../gitignore` in its `build.zig.zon`) becomes a version range, the way `hr.hrg:wyhash` is consumed. The Java and JS
ports still consume the vectors and the bench rather than re-deriving them, and a `bench/compare.mjs` that runs
several ports in one table is a convenience, not a contract.

## Research: where correctness cases come from

The matcher's rules are documented, but *cases* are what a port is judged on, and a hand-written dozen is not a
catalog. The sources are described in [`conformance/README.md`](conformance/README.md), and the one that is automated
is the checkout:

- **git's own tests** — `t/t0008-ignore.sh` and `t/t7063-status-untracked-cache.sh` in git's tree are the
  authoritative behaviour, written as shell with `.gitignore` fixtures; they can be read as cases, not executed.
- **`.gitignore` files in the wild, with their trees** — a rule set alone does not say whether a path is ignored, but
  a real repository plus `git check-ignore` does. Any checkout with `git` available is a generator: enumerate paths
  with `git ls-files --others --ignored`, pair them with the rules, and keep only cases where git and this matcher
  agree *or* where the disagreement is understood. This is the highest-value source and the one to automate first.
- **specification-shaped cases** — for every row of the rules table, one case that exercises it and one that
  exercises its boundary (`**/foo`, `foo/**`, `a/**/b`, `!` after a match, a dir-only rule on a file, an escaped `#`,
  a trailing space, a character class with `]` first).
- **issue trackers** — git's and other tools' ignore bugs are cases already distilled by someone else.
- **licence and provenance**: cases extracted from git's tests carry git's licence and must be attributed as such;
  generated cases from a checkout must not carry the repository's file contents, only names and rules.

The catalog is a *plan*, not a promise: the first version of this project ships the rules table's cases and the
[`git check-ignore` generator](conformance/from-git-check-ignore.mjs), and a port that finds a disagreement is
expected to send the case back here.

## Using it from Zig

```zig
// The import name is the consumer's choice; `fs-meta` mounts the two source files as `gitignore.zig` and
// `ignore.zig`, which is why these look like file names.
const ignore = @import("ignore.zig");

var stack = ignore.Stack.init(arena, io, root, true); // no error union; `arena` must outlive the stack
defer stack.deinit();

const verdict = try stack.decide("src/main/java/Foo.java", false);
// verdict: ?bool — true = excluded, false = re-included, null = no-opinion
```

The library does no file walking of its own: it reads the `.gitignore` files under the root you give it, answers about
a path, and caches the chains it built. That is what lets a port's own walker use it without adopting its I/O. The
walker-shaped entry point is `ignored(dir_path, name, is_dir)`; `decide(rel_path, is_dir)` is the three-valued form
the vectors and the bench CLI need, and it also honours an excluded ancestor (which is why it exists next to the
per-entry one).

## Licence

Same as `fs-meta`: `LicenseRef-GPL-3.0-with-Commons-Clause`, `Copyright (c) 2026 Davor Hrg`.

## Ports: measured, and what the numbers say

Three implementations, the same 34 vectors, the same bytes from `bench/perf.mjs`:

| workload      | Zig        | JS                  | Java               |
| --------      | --:        | -:                  | ---:               |
| flat          | 11 ms      | 50 ms               | 190 ms             |
| deep          | 27 ms      | 155 ms              | 620 ms             |
| doublestar    | 33 ms      | 129 ms              | 700 ms             |
| anchored      | 19 ms      | 82 ms               | 330 ms             |
| dirs          | 12 ms      | 56 ms               | 146 ms             |
| **backtrack** | **78 ms**  | **2942 ms**         | **16615 ms**       |
| total         | **182 ms** | **3407 ms (18.7x)** | **18099 ms (99x)** |

Correctness first: Zig and Java are **34/34**, the JS port is **34/34**. The differences are not small and they are not
noise, and the `backtrack` row is the reason this project exists: both ports translate a pattern into a regular
expression, and a `**` with a long path makes the regex engine backtrack exponentially — 38x for JS, 213x for Java, on
one workload. The Zig implementation replaced that translation with a segment dynamic program precisely because this was
observed on a real tree, and the workload reproduces it without that tree.

Two honest caveats about the table:

- **It measures a process**, so ~11 ms of JVM/Node/Bun start-up is in every row. That flatters none of the ports on the
  small workloads and it does not explain a 16-second row.
- **The ports are young.** The JS port lost three of its four vector failures this afternoon and the Java port lost the
  same four; both were carrying the same bugs because they share a lineage. Their slowness is a design difference, not a
  lack of tuning — but a port that adopts the segment DP has every reason to close most of the gap, and that is exactly
  the kind of finding this bench is for.

## Running the three

```text
bun js/conformance.mjs                                  # JS port: 34/34
$env:JAVA_HOME='C:\Program Files\Java\jdk-25'; bun java/run.mjs   # Java port: 34/34, compiles and runs it
bun bench/perf.mjs --repeat 3 \
  --port "zig=zig-out/bin/ignore-decide.exe --rules {rules} --paths {paths}" \
  --port "js=bun js/decide.mjs --rules {rules} --paths {paths}" \
  --port "java=\"…\bin\java.exe\" -cp java/out hr.hrg.gitignore.Decide --rules {rules} --paths {paths}"
```
