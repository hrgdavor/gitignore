# Porting guide

A port starts from one document and three commands: the rules in [`rules.md`](rules.md), the cases in
[`conformance/gitignore-vectors.json`](../conformance/gitignore-vectors.json) (shape:
[`conformance/README.md`](../conformance/README.md)), and the measurement in [`bench/perf.mjs`](../bench/perf.mjs).
This page orders the work: each invariant depends on the one before it, and implementing a later one without the
earlier ones will behave plausibly and wrongly.

## The invariants, in required order

### 1. Parse one file at a time

One file yields patterns **in file order**. Per line: strip a trailing `\r` (CRLF), trim trailing **unescaped**
spaces, skip blank and `#` lines, record a leading `!` as a negation, a trailing `/` as directory-only, a `/` at
the start or in the middle as anchored, and a leading `**/` as stripped. Escapes belong to the matcher.

Vectors: `a comment line is not a pattern`, `an escaped hash is a literal name`, `an escaped bang is a literal
name`, `a trailing space is trimmed`, `an escaped trailing space is kept`, `a CRLF rule file parses like an LF one`.

### 2. Resolve the governing chain

A `.gitignore` in `d/` governs names **below** `d`; every path given to it is relative to `d`, with no leading
slash, so a directory's own file cannot exclude the directory itself. Keep the files from the root down to the
path's directory, in that order.

Vectors: `literal file at any depth`, `leading slash anchors to the file's directory`.

### 3. The deepest file with an opinion wins

Ask the deepest file first, fall through to the next shallower one when it has no opinion, and stop at the first
file that has one. A deeper file that does not match must not blank the shallower file's answer.

Vectors: `deeper file wins over shallower`, `deeper file without an opinion leaves the shallower one`.

### 4. Return three values, not a boolean

`exclude`, `include` (a negation matched last), or `no-opinion` (nothing matched). Do not turn `no-opinion` into
`include` here: a caller that wants a boolean can do that itself, and one that does not is why the value exists.
The conformance runner is such a caller: [`src/conformance_test.zig`](../src/conformance_test.zig) compares the
third value as its own answer.

Vectors: `deeper file without an opinion leaves the shallower one`, `literal does not match a different name`,
`suffix does not match a longer extension`, `trailing slash does not match a file`.

### 5. An excluded directory is not entered

If a pattern excludes a **directory**, nothing below it can be re-included, not even by a `!pattern` in a file
inside it, because git never enters it and so never reads that file. A walker gets this by pruning; a
decide-one-path API must check the ancestors, each against the chain of *its own* parent.

Vectors: `a negation cannot re-include inside an excluded directory`, `a directory rule applies to the directory
itself only`.

### 6. The last matching pattern wins

Within one file the answer comes from the **last** pattern that matches; a negation is not special. `*.log` then
`!keep.log` re-includes `keep.log`; the reverse order excludes it again.

Vectors: `last matching pattern wins`.

### 7. `**` has exactly three forms

A leading `**/` matches zero or more directories (`**/*.class` matches `Foo.class` and `a/b/Foo.class`). A
trailing `/**` matches everything **inside** the directory, not the directory itself (`build/**` does not match
`build`). A middle `a/**/b` matches zero or more directories (`a/b` and `a/x/y/b`). Other runs are just asterisks
(`a**b` matches `axxb`, never `a/b`), and a single `*` never crosses `/`.

Vectors: `doublestar prefix applies at any depth`, `doublestar prefix also matches at the top`, `trailing
doublestar needs a segment`, `trailing doublestar matches inside`, `doublestar in the middle spans segments`,
`doublestar in the middle matches zero segments`, `a star does not cross a slash`.

### 8. Escapes, whitespace and character classes

A backslash makes the next byte literal (`\#`, `\!`, `\*`), and a trailing escaped space survives trimming. A
`[...]` class follows git: `]` as the first member is literal, `[!…]` and `[^…]` negate, `a-z` is an inclusive
range, and an **unterminated** class matches nothing (git aborts the pattern; it is not a literal `[`). That last
one is where this project's first version and the earliest ports were wrong: check git before trusting either side.

Vectors: `a character class matches one of its members`, `a character class with a closing bracket first`, `an
unterminated class matches nothing`, `a question mark matches one byte`, `a question mark does not match two
bytes`, `an escaped hash is a literal name`, `an escaped bang is a literal name`, `an escaped trailing space is
kept`.

### 9. Case sensitivity is a decision: this project chose sensitive

Match case-sensitively on every platform, including Windows and macOS. A trio is written on one machine and read
on another, so the ports must agree with **each other** before they agree with a filesystem whose
`core.ignorecase` folds case. There is no vector, because a case would have to state its platform; a port that must
fold case is a different matcher with its own vectors.

## Run the vectors

Read [`conformance/gitignore-vectors.json`](../conformance/gitignore-vectors.json) and assert one case at a time.
A case is `{ name, ruleFiles, path, isDir, expect }`, with `ruleFiles` a list of `{ dir, rules }` pairs (`""` is the root). Materialise it: write each `ruleFile` to `<root>/<dir>/.gitignore`,
ask `matcher.decide(<root>, case.path, case.isDir)`, and compare with `case.expect`.

The vectors are **hand-authored** from [`rules.md`](rules.md), not generated from the Zig implementation, and
the Zig implementation is the **basis, not the authority**. A disagreement is either your bug or a vector to
fix, and it is worth knowing which. Reproduce it in a scratch repository with `git init`, the same `.gitignore`
text and `git check-ignore -v --no-index -- <path>`; git decides. The unterminated-class case is the worked
example of a vector being corrected against git.

## Measure it

The bench exists so that a port's "fast" is a number on the same bytes as every other port's.

1. **Build the CLI contract.** `<port> --rules <file.gitignore> --paths <file.txt>` prints one line per path, in
   input order: `include`, `exclude` or `no-opinion`, nothing else on stdout. Support `--dirs <file>` (one `0`/`1`
   per path) for directory-only rules, and fail on a usage error. Reference: [`src/decide_main.zig`](../src/decide_main.zig).
2. **Build release.** A Debug build measures the runtime, not the design. Say which build a row used.
3. **Run the workloads.** From `gitignore/`:

   ```text
   bun bench/perf.mjs --emit
   bun bench/perf.mjs --port "<your command> --rules {rules} --paths {paths}" --repeat 5 --label <port>
   ```

   The runner splits `--port` on spaces and, for every workload, replaces `{rules}` and `{paths}` in each argument.
   Those two are the only placeholders; `--emit` writes the workloads to `.tmp/workloads/`. The best of `--repeat`
   runs is reported with its verdict count and ns per decision, and a count mismatch fails the row.
4. **Report every workload.** Five ordinary shapes (`flat`, `deep`, `doublestar`, `anchored`, `dirs`) plus
   `backtrack`, the recursive matcher's worst case: six rows. Name the workload a port is worst at, and why.
5. **Quote your own numbers** with the tree, the build and the date. The historical figures in this project's
   README (4,700 ms recursive, 1,466 ms superlinear, 2.97x anchored) came from a real tree; the synthetic shapes do not reproduce those magnitudes.

## Practical pitfalls

- **Treating `no-opinion` as `include`.** Collapse the third value at the boundary and "no rule matched" becomes "a negation matched".
- **Entering an excluded directory.** A `!` inside it then re-includes files git would never list; the decide-one-path form must ask the ancestors first, each through its own parent's chain.
- **Forgetting that a pattern with `/` is anchored.** `docs/api.txt` matches only at its own level; a bare `api.txt` matches at any depth, and only a leading `**/` is exempt.
- **Matching `*` across `/`.** `a*b` must not match `a/b`, or every `*.log` starts swallowing whole subtrees.

## Report back

- **A faster port is a finding to adopt.** Send the shape (data structure, pruning rule, representation), not a
  dependency on your project; a portable speed-up becomes a change here, and a local one is still a README row.
- **A failing vector is a bug or a vector to fix.** Do not vote: ask git in a scratch repo, and send the case back.
- **This project is explicitly vibe coded**, and says so in its [`README`](../README.md): the Zig implementation
  was written with an AI agent in one session against a real tree, and hand-crafted improvements and
  reimplementations are welcome. The vectors and bench exist to prove a rewrite, not to protect this implementation.
