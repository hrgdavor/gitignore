# The rules, as implemented

This is the rules table the conformance vectors cite. A rule is git's; the implementation is
[`src/gitignore.zig`](../src/gitignore.zig), the three-valued answer (`include`, `exclude`, `no-opinion`) is
[`src/ignore.zig`](../src/ignore.zig), and every row names the vectors in
[`conformance/gitignore-vectors.json`](../conformance/gitignore-vectors.json) that fail if the rule is broken.
A row with no vector names the test in `src/gitignore.zig` that pins it, because not every rule has a case yet.
The runner is [`src/conformance_test.zig`](../src/conformance_test.zig). For the order in which a port must
apply these, and how to measure one, see [`porting.md`](porting.md).

The **basis** is this implementation, not the authority: when a vector and the code disagree, git decides. The
one genuine disagreement so far, an unterminated `[`, was checked against `git check-ignore` (git 2.54).

## One path, three answers

A matcher answers about **one path against one file's rules**. The chain turns that into the answer a caller
needs, and there are three possible answers:

- **exclude**: the deepest `.gitignore` with an opinion excludes the path.
- **include**: the deepest `.gitignore` with an opinion re-includes it (a negation matched last).
- **no-opinion**: no rule file has an opinion. This is **not** "included"; a walker, indexer or caller may
  have a default of its own, and collapsing the third value loses that.

## Matching inside one segment

| Pattern form          | What it does                                                   | Vectors                                                                        | Test                                                                                               |
| --------------------- | -------------------------------------------------------------- | ------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------- |
| `name`                | Literal, matched against the final segment at any depth, so `api.txt` matches `docs/api.txt`. A pattern that itself holds a `/` is anchored instead. | `literal file at any depth`, `literal does not match a different name`, `a name with a slash cannot be matched by a bare name` | [`a name-only pattern matches a basename at any depth`](../src/gitignore.zig#L593) |
| `*`                   | Any run of bytes within one segment. It never crosses a `/`.   | `a star does not cross a slash`                                                | [`a pattern with a single star never crosses a separator`](../src/gitignore.zig#L738)              |
| `?`                   | Exactly one byte, not zero and not two.                        | `a question mark matches one byte`, `a question mark does not match two bytes` | [`a question mark matches exactly one byte`](../src/gitignore.zig#L759)                            |
| `[…]`, `[!…]`, `[^…]` | One byte from a class; `!` or `^` after the opener negates it. | `a character class matches one of its members`                                 | [`character classes, a closing bracket first, and an unterminated one`](../src/gitignore.zig#L687) |
| `[]]x`                | A `]` as the first member is literal, not the terminator, so this class holds `]` and the pattern matches `]x`. git's `wildmatch` and POSIX agree. | `a character class with a closing bracket first` | [`character classes, a closing bracket first, and an unterminated one`](../src/gitignore.zig#L687) |
| `[a-z]`               | A range: two members with a `-` between. The comparison is byte-wise and inclusive. No vector pins ranges yet. | none, so the test is the pin   | [`character classes, a closing bracket first, and an unterminated one`](../src/gitignore.zig#L687) |
| `[abc`                | **Unterminated: matches nothing.** git's `wildmatch` aborts the whole pattern, so the literal reading (`[abc` matching the name `[abc`) is the wrong guess, and that reading was this project's own first mistake. | `an unterminated class matches nothing` | [`character classes, a closing bracket first, and an unterminated one`](../src/gitignore.zig#L687) |
| `*.ext`               | The suffix form: an unanchored pattern whose only wildcard is the leading `*` and whose rest is literal. Matches when the final segment ends with `.ext`. | `suffix matches the final segment`, `suffix does not match a longer extension` | [`a name-only pattern matches a basename at any depth`](../src/gitignore.zig#L593) |
| `a**b`                | Consecutive asterisks that are not a segment of their own are just asterisks, still inside one segment: `a**b` matches `axxb`, never `a/b`. | `a star does not cross a slash` | [`the three ** forms follow git's rules`](../src/gitignore.zig#L655) |

## Anchoring

A pattern is **anchored** when it has a `/` at the start or in the middle; otherwise it matches the final
segment at any depth. A leading `/` is dropped, and a leading `**/` is stripped and leaves the rule unanchored.

| Pattern form | What it does                                                              | Vectors                                                                                   | Test                                                                                         |
| ------------ | ------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `/name`      | Anchored to the directory holding the `.gitignore`, not to the scan root. | `leading slash anchors to the file's directory`, `leading slash matches at its own level` | [`a leading slash anchors a pattern to the file's own directory`](../src/gitignore.zig#L602) |
| `dir/name`   | A separator anywhere also anchors; the whole relative path must match, so `docs/api.txt` does not match `src/docs/api.txt`. | `pattern with a slash is anchored`, `anchored pattern does not match deeper` | [`a leading slash anchors a pattern to the file's own directory`](../src/gitignore.zig#L602) |
| `**/name`    | A leading `**/` is normalised away, so the rule is unanchored and applies at any depth, top level included. A pattern containing `/` is therefore not automatically anchored. | `doublestar prefix applies at any depth`, `doublestar prefix also matches at the top` | [`the three ** forms follow git's rules`](../src/gitignore.zig#L655) |

## Directory-only

A trailing `/` means **directories only**. A file *inside* such a directory also answers "excluded", which is
what makes pruning a directory equivalent to ignoring the whole subtree.

| Pattern form                     | What it does                                                | Vectors                                                     | Test                                                                                      |
| -------------------------------- | ----------------------------------------------------------- | ----------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `name/`                          | Matches a directory called `name`, not a file of that name. | `trailing slash matches a directory`, `trailing slash does not match a file`, `a directory rule applies to the directory itself only` | [`a trailing slash matches directories only`](../src/gitignore.zig#L618) |
| `name/` and an excluded ancestor | An excluded directory is **not entered**, so everything below it is excluded by the ancestor rather than by a match of its own. A `!` below it never gets a chance to re-include anything. | `a negation cannot re-include inside an excluded directory` | [`a negated child inside an excluded directory stays ignored`](../src/gitignore.zig#L644) |

## The three `**` forms

`**` is special **only as a whole segment**. The three forms are git's:

| Pattern form | What it does                                                                                     | Vectors                                                                                     | Test                                                                 |
| ------------ | ------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| `**/name`    | Any depth, zero or more directories. A leading `**/` normalises to the unanchored `name`, which already means that. | `doublestar prefix applies at any depth`, `doublestar prefix also matches at the top` | [`the three ** forms follow git's rules`](../src/gitignore.zig#L655) |
| `name/**`    | Everything **inside** `name`, and not `name` itself: a trailing `**` needs at least one segment. | `trailing doublestar needs a segment`, `trailing doublestar matches inside`                 | [`the three ** forms follow git's rules`](../src/gitignore.zig#L655) |
| `a/**/b`     | Zero or more directories between two segments, so both `a/b` and `a/x/y/b` match.                | `doublestar in the middle spans segments`, `doublestar in the middle matches zero segments` | [`the three ** forms follow git's rules`](../src/gitignore.zig#L655) |

`a**b`, `***` and any other run that is not a segment of its own is a run of asterisks inside one segment.

## Negation and precedence

Within one file the **last matching pattern wins**, and a negation is not special: put `!keep.log` before
`*.log` and the exclusion wins. Across files, the **deepest file with an opinion** wins, and a file with no
matching pattern is skipped rather than treated as "include".

| Rule                           | What it means                                                                   | Vectors                                                     | Test                                                                                              |
| ------------------------------ | ------------------------------------------------------------------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Last match wins                | `*.log` then `!keep.log` re-includes; the reverse order excludes again.         | `last matching pattern wins`                                | [`the last matching pattern wins, so a trailing negation re-includes`](../src/gitignore.zig#L628) |
| Deeper file wins               | A `.gitignore` below another, with an opinion, overrides it. A file governs names below its own directory, never the directory itself. | `deeper file wins over shallower` | [`the deepest .gitignore wins, and a negation re-includes`](../src/ignore.zig#L393) |
| No opinion falls through       | A deeper file that matches nothing leaves the shallower file's answer standing. | `deeper file without an opinion leaves the shallower one`   | [`the deepest .gitignore wins, and a negation re-includes`](../src/ignore.zig#L393)               |
| Three values, not a boolean    | The chain answers `exclude`, `include` or `no-opinion`; the last one is a real answer and the caller decides what to do with it. | `deeper file without an opinion leaves the shallower one`, `literal does not match a different name`, `trailing slash does not match a file` | [`the deepest .gitignore wins, and a negation re-includes`](../src/ignore.zig#L393) |
| Excluded directory not entered | A `!` pattern below an excluded directory never re-includes anything.           | `a negation cannot re-include inside an excluded directory` | [`a negated child inside an excluded directory stays ignored`](../src/gitignore.zig#L644)         |

## Escapes and whitespace

| Pattern form       | What it does                                                                           | Vectors                                                                  | Test                                                                                       |
| ------------------ | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------ |
| `\#name`, `\!name` | A backslash makes a leading `#` or `!` literal; the backslash is not part of the name. | `an escaped hash is a literal name`, `an escaped bang is a literal name` | [`a backslash makes a leading # or ! literal`](../src/gitignore.zig#L704)                  |
| `# comment`        | A line whose first byte is `#` is a comment, not a pattern.                            | `a comment line is not a pattern`                                        | [`comments, blank lines, trailing spaces and CRLF are handled`](../src/gitignore.zig#L715) |
| `name` plus spaces | Trailing **spaces** are trimmed; only a trailing space escaped with `\` survives. A tab is part of the pattern. | `a trailing space is trimmed`, `an escaped trailing space is kept` | [`comments, blank lines, trailing spaces and CRLF are handled`](../src/gitignore.zig#L715) |
| CRLF               | A `\r` before the `\n` is stripped, so a CRLF checkout parses like an LF one.          | `a CRLF rule file parses like an LF one`                                 | [`comments, blank lines, trailing spaces and CRLF are handled`](../src/gitignore.zig#L715) |

Escapes are interpreted by the matcher, not the parser; the parser only asks whether a trailing space or `/`
is escaped, so `a\*b` matches the literal name `a*b` and not `ab`.

## Character classes

Two details are easy to get wrong and both are pinned. A `]` as the first member is literal, so `[]]x` is "the
class holding `]`, then `x`". An unterminated class matches nothing, because git's `wildmatch` reports
`ABORT_ALL` for an unclosed bracket expression, so `[abc` does not match a file literally named `[abc`.
[`matchClass`](../src/gitignore.zig#L499) now follows git; `[!]` (a negated empty class) and `[]` match
nothing, and a trailing `-` in a class is not treated as a range.

## What is read, and what is not

- **Read:** the `.gitignore` file in each directory, from the scan root down to the path's directory. One
  file's patterns are scoped to that directory: a path outside it can never match, so a directory's own file
  cannot exclude the directory itself.
- **Not read:** `$GIT_DIR/info/exclude`, a global `core.excludesFile` (usually `~/.config/git/ignore`),
  `.gitignore` files above the scan root, and the contents of an excluded directory (the walker does not enter
  it). The corpus generator [`conformance/from-git-check-ignore.mjs`](../conformance/from-git-check-ignore.mjs)
  skips every case whose verdict comes from one of those files, so a generated corpus stays inside this
  contract. [`conformance/README.md`](../conformance/README.md) records the same limit.
- **Not a `.gitignore` rule:** `.gitmodules`, `.gitattributes` and git's sparse-checkout files are outside the
  matcher; they have their own semantics.

## Case sensitivity (a stated decision)

Matching is **case-sensitive on every platform**, including Windows and macOS. This is deliberate, and it is
the one place a port may differ from a stock `git` on a case-insensitive filesystem, where `core.ignorecase`
can make git fold case: a trio is written on one machine and read on another, so the ports must agree with
**each other** before they agree with a particular filesystem. Keep it case-sensitive. A port that needs case
folding is a different matcher with its own vectors, not an exception inside this one.

## The parser's classes

The matcher classifies every pattern once, at parse time, because the class decides the cost of every later
lookup:

| Class     | When                                                  | Later lookup                                              |
| --------- | ----------------------------------------------------- | --------------------------------------------------------- |
| `literal` | No wildcard (`*`, `?`, `[` or `\`).                   | A string compare, or a map hit for an unanchored literal. |
| `suffix`  | `*.…` where the part after the `*` holds no wildcard. | `endsWith` on the final segment.                          |
| `glob`    | Everything else.                                      | The segment dynamic program in `globMatch`.               |

These classes are an **implementation detail, not extra rules**: moving a pattern between classes must not
change any answer, and the vectors are what prove it. The comment on [`Rule`](../src/gitignore.zig#L57) and the
classification in [`Rules.parse`](../src/gitignore.zig#L92) are the authoritative statement of the split.
