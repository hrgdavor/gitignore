# Next steps — gitignore

## Status

Done: step 1 (the vectors are a test), step 2 (`doc/rules.md`), step 3 (the `ignore-decide` CLI), step 5
(`doc/porting.md`), step 6 (the corpus generator). Step 4 is done: `-Dnaive` builds a second binary, `bench/perf.mjs` takes repeated `--port` labels and prints a comparison table, and the README records the numbers (backtrack 7.0x, overall 3.53x). Step 7 (publish) is open.


Runnable plan for the project that now owns the matcher, the chain, the vectors and the benchmarks. Each step states
what it changes, the command that proves it, and how to commit it. Steps 1–3 are the ones that turn the contract from
written into enforced; do them in order.

Toolchain: `D:\wrk\zig\17\zig.exe` (0.17). Gate:

```text
cd gitignore
D:\wrk\zig\17\zig.exe build test --cache-dir .zig-cache\local --summary all
```

Status (2026-10-21): **steps 1–6 are implemented**; step 7 waits on a published version. The `test` step succeeds
with 17 distinct tests (14 matcher, 1 chain, 2 conformance); `zig build test` reports 14, 15 and 17 per binary
because `ignore.zig` imports the matcher's tests, so its binary counts them again.

## 1. The Zig vector runner

**Goal:** the 34 cases in `conformance/gitignore-vectors.json` become a test, and the vectors stop being hand-written
prose.

- Add `src/conformance_test.zig`; import `ignore.zig` (the chain is what answers, because precedence and `no-opinion`
  are chain behaviour).
- Read the JSON with `std.json.parseFromSlice(std.json.Value, …)`; iterate `cases`.
- Per case: `var tmp = std.testing.tmpDir(.{})`, then for each `ruleFiles` entry
  `tmp.dir.createDirPath(io, dir)` when `dir` is non-empty and write `<dir>/.gitignore` with the rules (the idiom is in
  `ignore.zig`'s own tests). Then

  ```zig
  var stack = try ignore.Stack.init(arena, io, root_path, true);
  const verdict = try stack.decide(case.path, case.isDir);
  ```

  `root_path` is the temporary directory's path (`tmp.sub_path` style — check what `tmpDir` exposes in 0.17 and use
  that; the existing tests already do).
- Map the result to `include` / `exclude` / `no-opinion` and `expectEqualStrings` against `case.expect`, with the case
  name in the failure message.
- Add `"conformance_test"` to `build.zig`'s `modules` list.

**Accept:** the gate reports the new test's cases; if a case disagrees, decide which side is wrong and record the
correction in the commit — the vector may have been written wrong from the rules.

**Commit:** `gitignore: the vectors are a test`.

## 2. `doc/rules.md`

**Goal:** the rules table the vectors cite.

- One row per rule: the pattern form, its meaning, the vector names that pin it (`conformance/gitignore-vectors.json`).
- Sections: matching within a segment, anchoring, directory-only, the three `**` forms, negation and precedence,
  escapes and whitespace, character classes, what is read (`.gitignore` files) and what is not
  (`.git/info/exclude`, `core.excludesFile`), and case sensitivity as a stated decision.
- Link each row to the tests that exercise it in `src/gitignore.zig`.

**Accept:** every vector name appears in at least one row, and the doc's rules list and the parser's classes agree.

**Commit:** `gitignore: the rules as implemented`.

## 3. The CLI behind the bench contract

**Goal:** `bench/perf.mjs --port "…"` can time Zig.

- `src/decide_main.zig`: reads `--rules <file.gitignore> --paths <file>`, writes `<file>` to a temporary root's
  `.gitignore`, builds one `Stack`, and prints `include|exclude|no-opinion` per path, one per line, in input order.
  Exit non-zero on a usage error, and nothing else on stdout.
- `build.zig`: an executable `ignore-decide` plus an install step; the bench reads it from `zig-out/bin/`.
- Also support `--dirs <file>` (one `0`/`1` per path) so directory-only rules can be measured without a second format.

**Accept:**

```text
bun bench/perf.mjs --emit
bun bench/perf.mjs --port "gitignore/zig-out/bin/ignore-decide --rules {rules} --paths {paths}"
```

prints one row per workload with a verdict count equal to the path count.

**Commit:** `gitignore: a decide CLI, so any port can be timed on the same bytes`.

## 4. `naive` and `unindexed` bench modes

**Goal:** the four historical failures are demonstrable, not folklore.

- Behind a build option (`-Dnaive=true`), `gitignore.zig` gets a `globMatch` that recurses over `**` instead of the
  segment DP, and `ignore.zig` a `decide` that scans every rule instead of the per-kind index.
- `bench/perf.mjs` grows `--label` so both builds can be reported side by side, and the README quotes the numbers the
  modes produce (they are the 4,700 ms / 1,466 ms / 2.97× figures).
- Keep the naive code **out of the default build**, so a correctness run cannot accidentally measure it.

**Accept:** with the flags the workloads are slow in the documented way, without them the numbers match the README's.

**Commit:** `gitignore: the old designs, kept as bench modes`.

## 5. The porting guide

**Goal:** a port can start from one document.

- `doc/porting.md`: the invariants **in required order** — parse per file, decide with the deepest file that has an
  opinion, three-valued result, excluded directory is not entered, last match wins, the three `**` forms, escapes and
  trailing-space rules, case sensitivity — each with the vector names that test it.
- A "measure yourself" section: build the CLI contract, run `bench/perf.mjs --port`, put the row in the project's
  README table, and say which workload is the one your port is worst at.
- A "report back" section: a port that is faster is a finding to be adopted; a port that fails a vector is either a bug
  or a vector to fix.

**Commit:** `gitignore: a porting guide`.

## 6. Corpus generation (research → work)

**Goal:** more than 34 cases, from sources that already exist.

- `conformance/from-git-check-ignore.mjs`: given a checkout (a path argument, never bundled), enumerate candidate names
  with `git ls-files --others --ignored --exclude-standard`, ask `git check-ignore -v` for the verdict and the rule,
  and emit a case per (rules, path, verdict).
- Keep the licence rule in `conformance/README.md`: cases carry names and rules, **never file contents**; cases taken
  from git's own tests carry git's licence and are attributed.
- Wire it into `bench`? No — into a separate `conformance:corpus` step, because it needs a checkout that CI will not
  have.

**Commit:** `gitignore: a corpus generator, from git's own answers`.

## 7. Consumers

- Publish a version once the runner is green; `fs-meta` switches from `.path = "../gitignore"` to a version range.
- `wyhash` is the precedent: standalone project, own repository, consumed as an artifact.
