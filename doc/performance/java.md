# Java: the Java port

`java/src/hr/hrg/gitignore/` holds three library classes (`GitIgnoreFile`, `GitIgnoreRules`, and the package-private
`Glob` that is the segment DP) and three harness classes (`Runner`, `Decide`, `Json`). The port went from
**12405.0 ms total / 1034.0 ms per round in the initial measurement** to **2489.7 ms total / 207.5 ms per round at its
last measurement — 5.0x** — and it got there by being refuted twice, which is the most useful thing about its history.

Run it with `bun java/run.mjs` (the vectors, 34/34) or `java -cp java/out hr.hrg.gitignore.Decide --rules … --paths …
[--rounds N]`; the correctness gate is `bun scripts/check-verdicts.mjs`.

## 1. Background: the layout, and the invariant the port had to satisfy

Two facts about how this port is *arranged* explain several of its measurements, so they come first.

**The sources are a plain package tree, not a Maven layout.** `java/src/hr/hrg/gitignore/*.java` is compiled by bare
`javac` (`bun java/run.mjs`, and `bun scripts/check-verdicts.mjs` when `java/out` is stale), and the POM points
`<sourceDirectory>` at it. The reason is in the POM's own comment: saying "**34/34**" must not require Maven and JUnit, so
the vector runner needs no build system. The consequence for performance work is the one that matters here: the benchmark
CLI `Decide` — including `--rounds`, which is what makes a steady-state number possible at all — is **harness code in the
same directory as the library**, and the POM deliberately excludes `Runner`, `Decide` and `Json` from the jar. A port that
puts its bench CLI inside its published artifact ships its measurement scaffolding.

**The invariant at §5 of the porting guide is the one that shaped `GitIgnoreRules`.** [`doc/porting.md`](../porting.md)
orders a port's invariants, and its **§5** is "an excluded directory is not entered": a `!pattern` below an excluded
directory can never re-include anything, because git never enters it. A walker gets that by pruning; a `decide`-one-path
API has to ask each ancestor **through the chain of its own parent** — which is exactly the loop in
`GitIgnoreRules.decide`, and exactly the loop that §5 of this page (the ancestor memo) later made cheap. §4 of the same
guide ("return three values, not a boolean") is why the API returns `Optional<Boolean>` and not `boolean`: `no-opinion` is
not `include`, and collapsing it at the boundary turns "no rule matched" into "a negation matched".

(If you are reading this because a note called it "the §5 layout fix": the repository has no document numbered §5 that is
about *layout*. The two readings above are each documented — the layout in [`pom.xml`](../../pom.xml)'s comment, the
invariant in [`doc/porting.md`](../porting.md) §5 — and both are load-bearing for the measurements, so both are here.)

## 2. The regex era: 212 486 ms, and 203 s on one workload

**What the split said.** Nothing yet: the first Java port translated each glob into one `Pattern` and asked
`matcher.matches()`. That is correct, and on `**` it lets the engine explore exponentially many splits.

**Measured effect.** **212 486 ms** total for 12 rounds, of which **`backtrack` alone was 203 s** — **4.25x** worse than
the full DP's 50 010 ms (`doc/measurement.md`, 2026-10-23). This is the number that made the DP non-negotiable for Java
and is the same shape as JS's 2902 ms, 70x larger because Java's regex engine and this corpus meet `**` differently.

**The risk.** None to the verdicts — 34/34 either way. The risk is a benchmark corpus that never contains a `**` rule
with a failing final segment, in which case the design looks fine and a real tree takes minutes.

## 3. The DP, and the `Matcher` allocation it was paying for

**What the split said.** The full DP alone measured **50 010 ms** — a 4.25x win, and still far from the reference's order
of magnitude. The question "what inside the DP costs" was answered by reading the hot loop rather than by a profiler, and
the answer was one line: `regex.matcher(text[position]).matches()` — **one `Matcher` allocation per pattern segment per
path**.

**The change.** `Glob.Segment` classifies a pattern segment once at compile time: `**`, a **literal** (no `*`, `?`, `[`
or `\`), or a `Pattern`. The DP compares literals with `String.equals` and only wildcard segments allocate a `Matcher`.

**Measured effect.** **50 010 → 18 217 ms — 3.03x** as `doc/measurement.md` records it (2026-10-23; commit `86f9efd`);
the two totals as printed divide to **2.75x**, and the difference is inside the between-session drift this bench has (see
the [README](README.md), item 5), so the raw totals are the claim and the ratio is a label. It is the
single largest Java win, and it is worth repeating what it was: **allocation, not comparison.** The DP's arithmetic did
not change at all.

**The risk.** The literal test must be exactly the segments whose compiled regex would be an anchored, fully escaped
literal; a segment with a backslash takes the regex path deliberately. And `Glob` is package-private for a reason worth
keeping: it is an implementation detail of this port, not a second public API to keep compatible.

## 4. One split per decision, reused rows, `ThreadLocal` scratch

**What the split said.** `GitIgnoreFile.decide` used to call `rule.matches(path, isDirectory)`, which did
`path.split("/")` — so a file with 8 rules split its path 8 times. And every DP call needed two `boolean[]` rows, which
were allocated per call.

**The change.** Three edits that are one idea:

- `decide` splits once (`String[] parts = scoped.split("/", -1)`) and hands the array to every rule;
- a directory-only rule asks about a **segment count** (`Glob.matches(segments, text, count)`), so an ancestor question
  builds no substring per level;
- the DP's two rows live in a `ThreadLocal<boolean[][]>` (`Glob.SCRATCH`), grown to the longest path seen and reused —
  the Java form of the JS port's two scratch arrays.

**Measured effect.** **18 217 → 17 723 ms (2.8%)** for split + rows + the harness's own `--rounds` improvement, together
(`doc/measurement.md`, 2026-10-23). The three are not separable from that row, and that is honest: after §3 removed the
allocation that dominated, what was left of "one split per rule" was a couple of percent. The 2.8% is also below the
bench's ~13% noise, so treat it as "did not hurt, and removed an obvious waste" rather than as a measured win.

**The risk.** A `ThreadLocal` row buffer is per-thread mutable state that is never shrunk: a thread that once saw a
10,000-segment path keeps that array for the thread's life. That is fine for a CLI and worth thinking about in a server
that decides on request threads. The `count` parameter is the other risk — `-1` means "all segments" and any other value
must be exactly "the first `count` segments", with a trailing `**` still one-or-more; the vectors
`trailing doublestar needs a segment` and `trailing doublestar matches inside` are what pin it.

## 5. The ancestor memoisation (and the port that beat Zig by it)

**What the split said.** Not a Java split — the JS phase split that put **95%** of the loop's cost in re-deciding
ancestors (`backtrack` asked about 84,000 ancestor directories that were 42 distinct ones). The same shape existed here:
**11.2x** behind the reference, with the matcher the obvious suspect and the wrong one.

**The change.** `GitIgnoreRules.excludedDirectories`, a `Map<String, Boolean>` from a root-relative directory to "is it
excluded", cleared in `push` and `pop` — the only operations that change which files govern a directory, so a cached
answer cannot outlive its stack. Ancestors come from walking `lastIndexOf('/')` backwards; the substring is both the key
and the ancestor, so no level costs a split and a join.

**Measured effect.** Paired alternating A/B, 8 fresh processes × 12 rounds, verdicts byte-identical
(`doc/measurement.md`, 2026-10-24):

| workload   | before ms | after ms   | speed-up   |
| ---------- | --------: | ---------: | ---------: |
| flat       | 59.5      | 48.0       | 1.24x      |
| deep       | 1553.7    | 343.6      | 4.52x      |
| doublestar | 2468.9    | 1101.4     | 2.24x      |
| anchored   | 586.4     | 292.2      | 2.01x      |
| dirs       | 56.0      | 45.8       | 1.22x      |
| backtrack  | 8522.2    | 658.6      | **12.94x** |
| total      | 13 246.7  | **2489.7** | **5.32x**  |

Standing against Zig *at the time of that run*: Java moved from **11.2x** behind to **2.20x**. The smallest gain was
`dirs` at 18.2%, above the noise floor, and every comparison was paired.

**The risk.** As in JS: a stale entry is a plausible wrong answer, not a crash, and the workload does not exercise
`push`/`pop` (the bench pushes one file once). Java's invalidation is not backed by a fuzz of its own — the 54,000-decision
randomised comparison was run on the JS port and the design was copied. That is a real gap in *evidence*, and it is
recorded as a gap rather than papered over.

## 6. The refuted criterion

The steady-state table suggested using the DP only where a pattern has **two or more** `**` segments, with the compiled
regex everywhere else: `backtrack`'s worst rule has three, `doublestar`'s rules have at most one, and the DP was visibly
costing Java on `doublestar`. Implemented and measured — **refuted**:

| configuration                                   | total (12 rounds) | backtrack | doublestar |
| ----------------------------------------------- | ----------------: | --------: | ---------: |
| full DP + literal segments + split once         | **12 405 ms**     | 7 868 ms  | 2 328 ms   |
| the same, with the two-or-more-`**` criterion   | **15 641 ms**     | 9 722 ms  | 3 259 ms   |

The cause is a single rule in the workload: `**/*.class` has one `**`, so the criterion sends it to the regex, whose
`(?:.*/)?[^/]*\.class$` is slower on these paths than a DP row scan. **"One `**`" is not "cheap"** — it depends on the
pattern and on the path's depth, and a criterion that ignores that is a guess wearing a measurement's clothes
(`doc/measurement.md`, 2026-10-23).

An earlier, coarser criterion — the DP for any pattern containing `**`, the regex for the rest — was **also worse on
Java: 71 355 ms against 50 010 ms for the full DP (43%)**; with a single `**` the DP saves nothing, and directory-only
rules paid a substring plus a `Matcher` per ancestor. A third variant (DP when two or more `**` **or** directory-only) is
recorded as **"not completed"**: the two-line edit was reverted after it broke `decide`, and the criterion is described as
sound but **unmeasured**. It is listed here as unmeasured rather than as a result.

**The risk this leaves.** Java's design is now "the DP for everything, with the matcher made cheap" — which the data
supports ("the DP is never slower than the regex on these workloads") but which is also the answer that the *other* port
measured as a loss on five of six rows. Both are correct for their own code: Java's DP is worth keeping everywhere
**because** §3 removed its per-segment allocation, and JS never had that allocation to remove.

## 7. The current residual

- **207.5 ms per round** (2489.7 ms for 12 rounds), measured 2026-10-24 and **not re-run** after the reference's
  `7053629`, `ecff1ff` and `9fb0d30`. Against the reference's closing 9.0 ms/round that is **23.1x**; against the
  reference as it measured when the ports were last compared (~94 ms/round) it is **2.20x**. The second is a like-for-like
  paired result and the first is not.
- **No phase split of the Java loop has been recorded** — not once, in the whole history of this port. Its two biggest
  wins (§3's 3.03x and §5's 5.32x) came from reading the code and from a split done on *another* port. Every "what is
  left" below is therefore an inference from the change history, not a profile, and it is labelled that way.
- **What is presumably left, by construction**: the direct rule scan (the port has no per-chain index — the reference's
  `DirState` and `literal_dirs` are unported), `Optional` boxing on every decision (`Optional<Boolean>` allocates; a
  three-valued `enum` or a sentinel `Boolean` would not, and **this has not been measured**), and the `Map<String,Boolean>`
  ancestor memo, whose keys are `String`s where the reference's directory state is a hash of a path too — the same shape,
  so the same 52%-of-time question is open here.
- **`doublestar` at 1101.4 ms is the largest row** and was already the largest before the memo. It is the rule scan, and
  the reference's 8.99x on that workload shows what a per-chain literal index is worth.

## What the split said

- **The matcher was the suspect and not the culprit.** Java was 11.2x behind a reference that was itself spending 75% of
  its time in upward walks; the memo that fixed both ports was found by splitting the **JS** loop and copying the shape.
- **Allocation is the comparison's tax, again.** `Pattern.matcher(…).matches()` per segment per path was 3.03x — the
  largest single Java win — and it was found by reading the DP's inner loop, not by profiling.
- **A criterion borrowed from the shape of the data is a guess.** Two versions of "use the DP only when…" were refuted
  with numbers (71 355 vs 50 010; 15 641 vs 12 405), and the surviving design is the one that needed no criterion at all.
- **The harness is part of the measurement.** `--rounds` lives in `Decide.java`, and without it the same build varied 60%
  between runs — wider than any change this project has made to the Java matcher.

## What is left

- **A phase split of the Java loop.** This is the first item because it is the cheapest: the two changes that would be
  justified by it (a per-chain index, and removing `Optional` from the hot path) are both guesses today.
- **Port the reference's per-chain index** (`DirState`, `literal_dirs`, depth mask). `doublestar` is 44% of the Java
  total and the reference's version of that workload is 15.1 ms against this port's 1101.4 ms.
- **Re-measure against the current reference**, and re-measure the ports against *each other* — the last three reference
  changes are unaccompanied by any port number.
- **A push/pop fuzz for this port**, which has never had one; the memo's invalidation is justified by the JS fuzz and by an
  argument, not by a Java measurement.
- **The unmeasured third criterion.** "DP when two or more `**`, or directory-only" is recorded as sound but unmeasured
  after the edit broke `decide`. If anyone reopens the criterion question, that is the variant with a reason to exist —
  and the one that has to survive an interleaved paired run, not two separate ones.
