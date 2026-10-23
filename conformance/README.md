# Conformance vectors

> **Status: runner-verified.** [`src/conformance_test.zig`](../src/conformance_test.zig) materialises every case as a
> temporary tree and answers it through the chain; the gate fails if a case disagrees. The hand-authored file has 34
> cases. One of them was corrected by the runner: an unterminated `[` matches **nothing** (git's `wildmatch` aborts
> the pattern), not the literal name. That was checked against `git check-ignore` 2.54 before the vector changed.

`gitignore-vectors.json` is the contract a port is measured against. The Zig implementation is the **basis**, not the
authority: a case here was written by hand from the rules in [`../doc/rules.md`](../doc/rules.md), and a port that
disagrees is either wrong or has found something this project should learn.

## Shape

```json
{
  "name": "last matching pattern wins",
  "ruleFiles": [{ "dir": "", "rules": "*.log\n!keep.log\n" }],
  "path": "keep.log",
  "isDir": false,
  "expect": "include"
}
```

- `name` — the case's vocabulary. The runner prints it when the case fails, and `doc/rules.md` names it in the row of
  the rule it pins.
- `ruleFiles` — one entry per `.gitignore`, with the directory it governs (`""` is the root). A file governs names
  **below** its directory; a deeper file beats a shallower one.
- `path` — the name to decide, relative to the root, `/`-separated. Not a filesystem path: no case contains a real
  tree, so a port needs no checkout of any repository.
- `isDir` — whether the name is a directory. Directory-only rules (`build/`) turn on it, and an excluded directory is
  never entered, so its contents are excluded because their ancestor is.
- `expect` — `include`, `exclude`, or `no-opinion`. **The third value is the one ports get wrong**: when no rule file
  has an opinion the answer is *no opinion*, not "include", because a caller (an indexer, a walker) may have a default
  of its own.
- `source` — optional, and present only in a generated corpus: the `.gitignore` file and line that decided the case.
  It is provenance, not part of the matcher contract; a port may ignore it.

## The Zig runner

```text
cd gitignore
D:\wrk\zig\17\zig.exe build test --cache-dir .zig-cache\local --summary all
```

The runner is the `conformance_test` module. The JSON is embedded through a build-system anonymous import
(`vectors.json`), so the test binary reads no working-directory-relative path and the file is still tracked as a
build input. `-Dvectors=<file>` embeds a different file in the same schema — which is how a generated corpus is run:

```text
bun conformance/from-git-check-ignore.mjs .. --limit 200 --out .tmp/corpus.json
D:\wrk\zig\17\zig.exe build test -Dvectors=.tmp/corpus.json --cache-dir .zig-cache\local
```

A `.tmp/` file is ignored and disposable; nothing generated from a checkout is committed.

## How a port runs them

The runner is deliberately language-neutral:

```text
# given a case, materialise ruleFiles under a temporary root, then ask the matcher
for each case:
    write each ruleFile to <root>/<dir>/.gitignore
    verdict = matcher.decide(<root>, case.path, case.isDir)
    assert verdict == case.expect, failing with the case name
```

A port that resolves chained files differently should still pass: the vectors state precedence as *behaviour* (a
deeper file wins, an excluded directory is not entered), not as an algorithm.

## Generating a corpus

[`from-git-check-ignore.mjs`](from-git-check-ignore.mjs) takes **a checkout path** (never a bundled tree), asks git
which names it ignores and which `.gitignore` line decided each one, and emits a case per name with the rule files
that govern it:

```text
bun conformance/from-git-check-ignore.mjs ../some-checkout --limit 1000 --out .tmp/corpus.json
```

- It uses `git ls-files --others --ignored --exclude-standard` for the candidates and one batched
  `git check-ignore -v -z --stdin` for the verdict and the deciding rule.
- Cases whose answer comes from `.git/info/exclude` or a global `core.excludesFile` are **skipped**, because this
  project deliberately does not read those files. A generated corpus therefore stays inside the implemented contract.
- Every case's `expect` is `exclude`, with `isDir: false`: those are the answers git states unambiguously. A
  non-ignored path is not a `no-opinion` case, because git does not distinguish "no rule matched" from "a negation
  matched".
- It is a **separate step** from `bench`, because it needs a checkout that CI will not have. `--limit` caps the
  candidates sent to `check-ignore` (default 1,000), but `git ls-files` still enumerates the checkout's ignored set
  first; run it on a small checkout rather than on one with a million ignored files.

## Licence and provenance

- Cases carry **names and rules** (`.gitignore` text), never the contents of ignored files. The ignored file is only a
  path name in the case.
- Cases taken from git's own test suite carry git's licence and must be attributed as such. The generator does not
  read git's tests.
- A generated corpus from a checkout carries that checkout's `.gitignore` files; write it under `.tmp/` and do not
  commit it.

## Adding a case

1. Find the rule it pins in [`../doc/rules.md`](../doc/rules.md); if the rule is not there, the document is incomplete
   and that is the first change.
2. Add the smallest case that fails when the rule is broken, and name it in the vocabulary of the rule.
3. Run the Zig implementation. If it disagrees, decide which is wrong **before** changing the vector — check git in a
   scratch repository (`git check-ignore -v --no-index -- <path>`). A vector that follows an implementation teaches
   nothing.
4. If the case came from git's own tests or from a real checkout, note the source in the commit message; cases carry
   git's licence when they come from git, and generated cases may carry names but never file contents.

## What is not covered yet

- Case sensitivity per platform: the matcher is case-sensitive everywhere, which is git's behaviour on Linux and a
  stated decision here (see [`../doc/rules.md`](../doc/rules.md#case-sensitivity-a-stated-decision)); a case would
  need to say which platform it assumes, which is why there is none.
- `.git/info/exclude` and a global `core.excludesFile`: deliberately not read (see the README), so no cases; the
  corpus generator skips the cases that would need them.
- `.gitignore` files that git itself treats as unreadable (binary content, NUL bytes): a robustness question rather
  than a rule.
- Symlinks, `core.ignorecase`, and the platform-specific case folding of a filesystem: out of scope for the matcher,
  and a port that needs them is a different matcher with its own vectors.
