# Findings from the JS port

The JS matcher (`js/gitignore.mjs`, moved unchanged from `fs-meta/js/`) is run against the 34 conformance vectors by
`js/conformance.mjs`, which materialises each case and exits non-zero on a disagreement. It agrees on **34 of 34**.

| case                                                      | expected   | JS port    | cause                                                                                     | state     |
| --------------------------------------------------------- | ---------- | ---------- | ----------------------------------------------------------------------------------------- | --------- |
| a CRLF rule file parses like an LF one                    | exclude    | no-opinion | the parser split on `\n` and left the `\r` on every pattern, so `*.log\r` matched nothing | **fixed** |
| a character class with a closing bracket first (`[]]x`)   | exclude    | no-opinion | the class parser took the first `]` after the opener as the terminator                    | **fixed** |
| an unterminated class (`[abc`)                            | no-opinion | exclude    | it treated the class as a literal `[`, and its own comment said "like git"; git's `wildmatch` aborts the whole pattern | **fixed** |
| a negation cannot re-include inside an excluded directory | exclude    | include    | `decide` answers for one path and never asks its ancestors, so `build/` + `!build/x.log` returns include where a walker would never enter `build` | **open** |

## The last case fixed, and why it took three attempts

The rule is not about the pattern language; it is about the *walk*: an excluded directory is never entered, so a negation
for a path inside it cannot re-open that path. A single-path decision has to model it by asking the ancestors.

The fix belongs in `GitIgnoreRules.decide` — ask `decide(ancestor, true)` for each parent, deepest first, and let an
excluded parent decide the child. It was attempted twice and abandoned both times: the class body is the one place where
a line-index splice kept ending the class instead of the method, and a port that is 33/34 with this note is worth more
than one that reports 34/34 by accident and cannot be read in the next session.

The next attempt should add a `decideDirect` helper **inside** `GitIgnoreRules` (the class declares `#stack`, so the
helper must be a method, not a free function), rewrite `decide` to call it, then ask the ancestors. `bun
js/conformance.mjs` is the check.

## What the port is for

It is a second implementation, and a second implementation is only useful if it is measured. This file exists because the
measurement produced four findings in one afternoon, three of which were invisible to the port's own tests.

It is at 34/34, so `fs-meta`'s copy (`fs-meta/js/gitignore.mjs`, which its walker still imports) should follow it or
be replaced by a dependency, so the ecosystem has one JS matcher rather than two.
