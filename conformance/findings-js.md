# Findings from the JS port

The JS matcher (`js/gitignore.mjs`, moved unchanged from `fs-meta/js/`) was run against the 34 conformance vectors for
the first time. It agrees on **31**. The three disagreements are recorded here because each one is the kind of edge the
project exists to catch, and two of them are still open.

| case                                                    | expected   | JS port    | cause                                                                           | state                                               |
| ------------------------------------------------------- | ---------- | ---------- | ------------------------------------------------------------------------------- | --------------------------------------------------- |
| a CRLF rule file parses like an LF one                  | exclude    | no-opinion | `text.split('\n')` left the `\r` on every pattern, so `*.log\r` matched nothing | **fixed** — the line is normalised before splitting |
| a character class with a closing bracket first (`[]]x`) | exclude    | no-opinion | the class parser took the first `]` after the opener as the terminator, so `[]]x` was read as an empty class | **open**               |
| an unterminated class (`[abc`)                          | no-opinion | exclude    | the parser deliberately treated it as a literal `[`, and its comment said "like git" — git's `wildmatch` aborts the whole pattern | **open** |

Both open cases are small edits in `translateCharacterClass`/`translateGlob`, and both were easier to get wrong than to
fix: the first attempt at fixing them spliced three lines by index and left the file unbalanced, which is why the
CRLF fix landed alone and this note exists.

## What the port is for

It is a second implementation, and a second implementation is only useful if it is measured. It is measured by
`bun js/conformance.mjs`, which materialises each case and exits non-zero on a disagreement — so the two open cases are
a red gate today, deliberately, rather than a comment nobody runs.

When this port reaches 34/34, `fs-meta`'s copy (`fs-meta/js/gitignore.mjs`, which its walker still imports) should
follow it or be replaced by a dependency, so that the ecosystem has one JS matcher rather than two.
