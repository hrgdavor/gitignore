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
  js/                      the JavaScript port, exported by package.json as `@hrg/gitignore`
  java/src/                the Java port, packaged by pom.xml as `hr.hrg:gitignore`
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

**0.3.0** is released — the same version on npm (`@hrg/gitignore`) and Maven Central (`hr.hrg:gitignore`):
[Publishing](#publishing) records the release commands. `fs-meta`'s path dependency (`../gitignore` in its
`build.zig.zon`, `file:` in its `package.json`) can therefore become a version range, the way `hr.hrg:wyhash` is
consumed. The Java and JS
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

## Using it from JavaScript and Java

The matcher is packaged for both languages, so a consumer depends on it instead of copying the files.

```js
// JavaScript: package.json exports `.` and `./glob`.
import { GitIgnoreRules, parseGitignore, readGitignore } from '@hrg/gitignore';
import { compileSegments, segmentsMatch } from '@hrg/gitignore/glob';
```

The package is `package.json` here (`"type": "module"`, `"sideEffects": false`, `.` → `js/gitignore.mjs`,
`./glob` → `js/glob.mjs`, `./package.json` → `package.json`); `bun pm pack` ships exactly those two modules plus
`package.json` and the README, nothing else.

```xml
<!-- Java: hr.hrg:gitignore, resolved the way hr.hrg:wyhash is. -->
<dependency>
    <groupId>hr.hrg</groupId>
    <artifactId>gitignore</artifactId>
    <version>0.3.0</version>
</dependency>
```

`pom.xml` builds the three matcher classes — `GitIgnoreFile`, `GitIgnoreRules` and the package-private `Glob` —
with JDK 25. `bun java/run.mjs` remains the zero-build gate for the port. A checkout can also be installed into the
local repository once:

```text
cd gitignore
mvn -q install
```

## Publishing

`@hrg/gitignore` is published under the `hrg` npm scope; `publishConfig` sets `access` to `public`, so a plain
`npm publish` publishes it publicly. This release is **0.3.0** — the same version as `build.zig.zon` and
`pom.xml`. The JavaScript package is plain ESM with no Bun API and no dependencies, so it installs and runs under
Node as well as Bun (`engines.node` is `>=18`).

```bash
cd gitignore
bun js/conformance.mjs        # 34/34
bun pm pack --dry-run         # package.json, README.md, js/gitignore.mjs, js/glob.mjs — nothing else
npm publish                   # from the repository root; publishConfig supplies --access public
```

After it is on the registry, [`fs-meta`](https://github.com/hrgdavor/fs-meta)'s `package.json` should switch its
`@hrg/gitignore` dependency from the local `file:` link to the published version range (`^0.3.0`), exactly as the
Java port moves from a local `mvn install` to the released `hr.hrg:gitignore:0.3.0`.

## Licence

Same as `fs-meta`: `LicenseRef-GPL-3.0-with-Commons-Clause`, `Copyright (c) 2026 Davor Hrg`.

## Ports: measured, and what the numbers say

Three implementations, the same 34 vectors, the same bytes from `bench/perf.mjs`. Start-up is measured separately (a run
with an empty path list) and **subtracted**, so the table is the matcher, not the loader:

| workload      | Zig         | JS (hybrid)           | JS (regex)            | JS (full DP)          |
| --------      | --:         | ----------:           | ---------:            | -----------:          |
| flat          | 0.7 ms      | 5.2 ms                | 0.8 ms                | 8.1 ms                |
| deep          | 17.6 ms     | 115.8 ms              | 111.6 ms              | 241.9 ms              |
| doublestar    | 23.5 ms     | 120.5 ms              | 75.3 ms               | 494.8 ms              |
| anchored      | 9.0 ms      | 35.3 ms               | 32.0 ms               | 126.9 ms              |
| dirs          | 1.9 ms      | 13.7 ms               | 6.1 ms                | 26.4 ms               |
| **backtrack** | **68.3 ms** | **1370.6 ms**         | **2902.4 ms**         | **1462.6 ms**         |
| total         | **121 ms**  | **1661.2 ms (13.9x)** | **3128.2 ms (26.1x)** | **2360.7 ms (19.5x)** |

Start-up, for completeness: Zig ~11 ms, JS ~48 ms, Java ~110 ms.

The three JS columns are **the same vectors, the same port, three matching strategies**, measured on this machine with
`--repeat 3` and processing only:

- **regex** — one compiled regex per rule. Fast on five workloads, and catastrophic on `backtrack` (2902 ms), where the
  engine explores exponentially many `**` splits.
- **full DP** — the segment dynamic program for every rule. The total looks good only because `backtrack` dominates: it is
  **1.6x-6x slower on the other five rows**, which the first version of this table hid by reporting only the total.
- **hybrid** — the DP only for patterns containing a `**` segment, the compiled regex for everything else. Best total
  (1661 ms), `backtrack` down 2.1x, and every other row within ~1.2x of the regex — except `doublestar` (120 vs 75 ms),
  which is a pattern with `**` where the regex happened to be fast. That row is the open tuning question, not a settled
  result.

The Java port still runs the full DP (4397 ms total, `backtrack` 3205 ms, `anchored` and `doublestar` regressed against its
regex version). The same hybrid applies to it and is the next step; the numbers above are why it should be measured per
workload rather than by the total.

### How these numbers are produced

Cold-process runs, with start-up measured separately and subtracted. That is the honest number for a CLI and it is
also noisy: the same Java build has reported `backtrack` at 3205 ms and 5129 ms. [+doc/measurement.md](doc/measurement.md)](doc/measurement.md) records the two measurement modes, the steady-state table (12 rounds inside one process) and every
strategy tried on the Java port with what it cost. The Java column above predates the literal-segment fast path.

### Two caveats

- The runner measures a process; the start-up column is a subtraction, and on a loaded machine it is a noisy one. The
  large rows are far outside that noise; the small ones are not.
- The ports are young. Their remaining distance to Zig is a design difference, not tuning: Java has not adopted the DP, and
  neither port has the Zig implementation's per-chain indexing.

## Running the three

```text
bun js/conformance.mjs                                  # JS port: 34/34
$env:JAVA_HOME='C:\Program Files\Java\jdk-25'; bun java/run.mjs   # Java port: 34/34, compiles and runs it
bun bench/perf.mjs --repeat 3 \
  --port "zig=zig-out/bin/ignore-decide.exe --rules {rules} --paths {paths}" \
  --port "js=bun js/decide.mjs --rules {rules} --paths {paths}" \
  --port "java=\"…\bin\java.exe\" -cp java/out hr.hrg.gitignore.Decide --rules {rules} --paths {paths}"
```
## Publishing to npm

```text
cd <this checkout>
bun js/conformance.mjs          # 34/34, the vectors are the gate
bun pm pack --dry-run           # 4 files: package.json, README.md, js/gitignore.mjs, js/glob.mjs
npm publish                     # publishConfig supplies --access public
```

**It needs a live token.** Measured on 2026-10-24: `npm whoami` answered `401 Unauthorized` with the token in
`~/.npmrc`, and `npm publish` reported `404 Not Found - @hrg/gitignore@0.3.1`. npm answers 404 rather than 403 when a
token cannot publish to a scope, so the 404 is the *symptom* of an expired/revoked token, not of a missing package
(`npm owner ls @hrg/gitignore` works and names `hrgdavor`, and 0.3.0 is on the registry). Fix with `npm login`, then
publish; no change to this repository is needed.

`fs-meta` pins `"@hrg/gitignore": "0.3.0"` exactly, which is the published version. Bump that one line to `"0.3.1"` when
npm has it.
## Publishing the Maven artifact

The release is **0.3.0**, the same version as `build.zig.zon` and `package.json`. Publishing is deliberate now:
the Central publisher lives only in [`pom-release.xml`](pom-release.xml), and `pom.xml` has no publisher at all.

### Why the publisher is not in `pom.xml`, and never in a profile

Maven reads `<extensions>true</extensions>` only from a POM's **top-level `<build>`**, never from a profile. The
publisher was once declared in the `publish` profile; it silently never loaded, so `deploy` staged a bundle and
stopped — no upload, and not a word about "central" in the log. That is the failure this layout prevents.

Declaring it in `pom.xml`'s top-level `<build>` does load it, but then *every* build loads it and a bare
`mvn deploy` publishes to Central whether or not `-Ppublish` was passed. So the publisher is kept out of `pom.xml`
entirely and exists only in `pom-release.xml`, in that POM's top-level `<build>`.

The guard has two halves:

- `pom.xml` sets `maven.deploy.skip=true`. `mvn deploy` on it reaches `maven-deploy-plugin` and logs
  `Skipping artifact deployment`; it uploads nothing, and the publisher is not on the build's classpath at all.
- `pom-release.xml` is a copy of `pom.xml` plus the publisher. It keeps `maven.deploy.skip=true` too: that property
  disables `maven-deploy-plugin`, **not** the Central publisher, which is a separate goal at the same phase. If the
  extension ever failed to load, the release would do nothing rather than fall back to a direct deploy. Verified with
  the plugin: with `maven.deploy.skip=true`, `central-publishing:0.6.0:publish` still runs and logs
  `Skipping Central Publishing at user's request.` when `-DskipPublishing=true` is passed.

`pom-release.xml` is a **copy**, not a child: Maven 3.9.9 rejects a jar-packaged POM as a parent
(`Invalid packaging for parent POM ... must be "pom" but is "jar"`), and Maven has no POM include. Everything is
duplicated; only the comment block and the publisher plugin are meant to differ. [`scripts/check-poms.mjs`](scripts/check-poms.mjs)
strips comments, removes the publisher, and fails if anything else differs; it also asserts that both POMs declare the
same version. Run `bun scripts/check-poms.mjs` after editing either POM, and copy `pom.xml` again in the same commit.

### The release command

**On this machine `mvn` is `mvnd` (native mode), not the real Maven, and it refuses `-Dmvnd.noDaemon`.** Releasing uses
the unpacked real Maven in `.tmp/maven/` (Maven 3.9.9), with JDK 25:

```text
$env:JAVA_HOME = 'C:\Program Files\Java\jdk-25'
$env:MAVEN_GPG_PASSPHRASE = '<your passphrase>'
.tmp\maven\apache-maven-3.9.9\bin\mvn.cmd -f pom-release.xml -Ppublish -DskipTests package
.tmp\maven\apache-maven-3.9.9\bin\mvn.cmd -f pom-release.xml -Ppublish -Dgpg.skip=false -DskipTests deploy
```

The first command checks that the binary, sources and javadoc jars all appear in `target/`; the second is the release.
`-Ppublish` adds `maven-source-plugin`, `maven-javadoc-plugin` and `maven-gpg-plugin` (the profile is in both POMs).
`gpg.skip` defaults to `true`, so nothing signs unless `-Dgpg.skip=false` is passed.

To exercise the release path **without uploading**, pass the publisher's own switch:

```text
.tmp\maven\apache-maven-3.9.9\bin\mvn.cmd -f pom-release.xml -DskipTests -DskipPublishing=true deploy
```

That runs `central-publishing:0.6.0:publish`, stages and bundles locally, logs
`Skipping Central Publishing at user's request.`, and stops before the upload. **Do not** prove the release path with a
bare `deploy`.

Requirements, learned from a project of this author's that publishes this way (`dia-log`):

- `~/.m2/settings.xml` has a server with id **`central`** carrying the Sonatype token.
- **The signing passphrase comes from `MAVEN_GPG_PASSPHRASE`**, not from `settings.xml`: the plugin deprecates
  `passphraseServerId` (it warns that a passphrase in a file can leak), and the profile passes
  `--pinentry-mode loopback` so gpg reads the environment instead of trying to open a prompt that a batch build cannot
  answer. Measured on this machine: with the variable set, a wrong value produces `gpg: signing failed: Bad passphrase`
  (proving the passphrase reaches the key); with it unset the agent answers `Operation cancelled`, which is what a GUI-less
  run looks like. A passphrase stored in `settings.xml` under the old id is ignored now.
- `gpg.skip` defaults to `true`, so a local build never signs; the release passes `-Dgpg.skip=false`.
- The Central publisher takes over the `deploy` phase and suppresses `maven-deploy-plugin`, so the
  `distributionManagement` in both POMs (Sonatype's `maven-releases` endpoint) is not a second upload path. The
  publisher uses `skipPublishing` to stop before the upload and the `central` server for credentials; it does **not**
  use `altDeploymentRepository`.
- The version comes from the POM (`0.3.0`), and `build.zig.zon`/`package.json` must agree — they do.

Afterwards, `fs-meta` resolves `hr.hrg:gitignore` from the repository like any other artifact; it no longer needs the local
`mvn install`.
