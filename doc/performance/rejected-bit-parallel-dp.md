# Rejected: bit-parallel DP for `**`

**Status:** measured on 2026-10-25 and **not implemented**. This document exists so the next person can decide in minutes
instead of re-running the experiment, and so a *variation* that could actually pay is not thrown out with the idea.

---

## 1. What the idea is, and why it is the standard answer

A `**` segment matches zero or more path segments. The naive way to implement that is to try every split point, which
multiplies with each additional `**`: the historical `backtrack` rule `src/**/test/**/impl/**/*.g4` has three of them.

The dynamic-programming fix keeps, per pattern segment, the set of *path positions* the pattern can be sitting at. The
**bit-parallel** version packs that set into a machine word — one bit per position, so a 12-segment path is one `u64` — and
each pattern segment costs one word operation instead of a loop over positions:

| pattern segment                       | current shape                      | bit-parallel shape                                                               |
| ------------------------------------- | ---------------------------------- | -------------------------------------------------------------------------------- |
| literal                               | loop over positions, compare each  | mask of positions whose segment equals the literal, then `<< 1`                  |
| single-segment glob (`*.g4`, `[ab]x`) | loop, call the per-segment matcher | mask from the per-segment matcher, then `<< 1`                                   |
| `**`                                  | loop over positions, propagate     | prefix closure in `log2(n)` steps: `x \|= x << 1; x \|= x << 2; x \|= x << 4; …` |

That is the textbook technique — the same one `ripgrep`/RE2-style engines use for `.*` — and it is genuinely faster per
match when the DP is a large share of the work. **It is the right answer to a question this project no longer asks.**

## 2. Why it looked promising here

It was promising *before* this phase, not after it. Measured on `backtrack` when the matcher was still the hot spot:

```
DP rows / init / copies      42.6 ms   (41.7% of the workload)
pattern + path splitting     22.6 ms   (22.1%)
chain literal scan           22.2 ms   (21.8%)
chain lookup                 14.6 ms   (14.3%)
```

A 40%+ share is exactly when a DP rewrite pays. What happened instead is that the calls disappeared: a **last-segment
precheck** rejects non-matching rules before anything is split, **suffix buckets** answer tail-shaped rules with one hash
lookup, and the reference **normalises `**/x` at parse time** into an unanchored literal or suffix rule. The DP did not get
faster; it stopped being entered.

## 3. What was actually measured

Method: instrumented clean copies of all three implementations (`src/`, `js/`, `java/` at the then-current commit), 12-round
in-process loop totals with the timer pairs subtracted; DP share is the matcher body (pattern/path split plus rows) over the
loop. A prototype was written in Java (the largest absolute DP cost) as a standalone harness, reusing the compiled segments
so only the row algorithm differed. An oracle compared **both** matchers against real `git check-ignore -q --no-index`.

**Where the DP still runs** (calls / cells per decision):

| workload                        | Zig      | JS                    | Java                   |
| ------------------------------- | -------- | --------------------- | ---------------------- |
| flat                            | 0 / 0    | 0 / 0                 | 0.14 / 0.7 (6.8%)      |
| doublestar                      | 0 / 0    | 0.27 / 2.9 (**8.1%**) | 0.27 / 2.9 (**11.1%**) |
| deep, anchored, dirs, backtrack | 0 / 0    | 0 / 0                 | 0 / 0                  |
| **total share**                 | **0.0%** | **2.2%**              | **4.9%**               |

Zig never enters the matcher at all — zero calls, with the counters verified on a synthetic `a/**/b`.

**The ceiling** — if DP cost were exactly zero:

| port | loop-only total | DP free | absolute maximum gain |
| ---- | --------------: | ------: | --------------------: |
| Zig  | 6.2 ms          | 6.2 ms  | **0.0%**              |
| JS   | 62.2 ms         | 60.8 ms | **2.2%**              |
| Java | 95.9 ms         | 91.2 ms | **4.9%**              |

**The prototype** (Java): real workload pairs whose precheck passes (810) **564 → 464 ns/match (1.21×)**; adversarial pairs —
many `**`, trailing `**`, `**` beside a literal, 71-segment paths — **1333 → 883 ns (1.51×)**; all 74 000 workload pairs,
which are precheck-dominated, 1.00×.

**The arithmetic that settles it:** 4.9 % share × 1.21× = **0.9 % of Java's total** (1.7 % if every call were
adversarial-shaped). JS: 2.2 % × similar ≈ 0.4 %. Zig: zero.

## 4. Why it was rejected

The project's rule is that a change must earn its complexity, and this one asked for a lot of it:

- a **second matcher shape** next to the segment DP, so two implementations of the same semantics to keep in step;
- a **word-array path** past 63 segments, which is the branch that would never be exercised by any workload here;
- a **closure invariant** (`**` must also span *zero* segments, and the shift has to be applied before the following literal
  test) that is invisible on ordinary paths and wrong on exactly the corner case;
- and a **carry bug class** the oracle proved is real: the prototype's first version wrote a trailing `**`'s closure into the
  wrong word. The 34 conformance vectors cannot see that; only a git oracle can.

Against that: under one percent on the slowest port, and nothing at all on the reference.

**Verdict: not implemented.** `doc/performance/shared.md` keeps the one-paragraph record; this file keeps the reasoning.

## 5. When to revisit — the checklist

Do not re-open this because the technique is elegant. Re-open it when a measurement says the DP is large again:

1. **DP share of a port's total ≥ 25 %** on a real workload (not a synthetic one). Below 10 %, stop reading.
2. **Cells per decision** reported alongside the share, so a big share from a few expensive calls can be told apart from a
   small share over many cheap ones.
3. **`**`-shaped rules are still entering the matcher** — if `**/x` is normalised at parse time and tail rules are bucketed,
   the DP is mostly unreachable, which is the state today.
4. **A cheap alternative has been ruled out first**, in this order: normalisation at parse time, a suffix/literal bucket, a
   last-segment precheck. Each of those deletes calls; the DP rewrite only makes retained calls cheaper. Deleting beats
   accelerating, and it has no semantics to get wrong.

## 6. Variations that could still bring performance

The rejection is of *this* shape, not of parallelism as a tool. These are the variants that could pay, in the order I would
try them:

| variation                                                                         | why it could pay | how to judge it                                             |
| --------------------------------------------------------------------------------- | ---------------- | ----------------------------------------------------------- |
| **Normalise patterns so the DP is never entered** (Zig does it; JS did not yet) — **done 2026-10-25, § 8** | removes the calls instead of accelerating them; measured at `doublestar` 17.0 → 15.9 ms in JS with 0 DP calls and identical verdicts | DP calls per decision → 0 is the win; the timing is a bonus |
| **Give Java the literal/suffix rule classes** it lacks — **done 2026-10-25, § 8** | Java's residual DP cost is its *universal* DP — every pattern goes through it — which no `**` rewrite reaches. This is the one with a real ceiling behind it | measure the DP share after the classes exist; if it is still ≥ 10 %, then revisit bit-parallelism *on top* |
| **Bit-parallelism applied to the rule scan rather than the DP**                   | the scan is rule-set matching: candidate rules could be masked by depth and segment count, so a path tests a handful instead of a chain. That is a different workload from the DP and was never measured | cells-equivalent: rules tested per decision |
| **Wide paths (> 63 segments)**                                                    | the only case where the word-array path is intrinsic, not accidental; the bench has none, so it cannot be judged from these workloads | add a workload first, then measure |

The first two were done the same day; § 8 has the numbers. Both made DP calls per decision **zero on every workload**, so
the precondition for revisiting bit-parallelism — a DP share that is still large *after* the calls have been deleted — is
not met.

What would **not** change the verdict: a faster `memcmp`, a narrower mask type, or a different hash — those were measured and
reverted elsewhere, and they move the plumbing, not the DP.

## 7. How to re-run the experiment

The harnesses were scratch (`.tmp/dp/build.mjs`, `measure.mjs`, `proto/`, `oracle-dp.mjs`, `norm.mjs`) and are not committed,
because nothing in `.tmp/` is. Rebuild them from this description:

1. copy `src/`, `js/`, `java/` to a scratch tree and add counters at the matcher entry (calls, and row-loop iterations);
2. run the six bench workloads for 12 rounds in one process, subtract the timer pairs, report share = matcher body / total;
3. compute the ceiling by setting the matcher body to zero — this is the number that decides the question and it costs one
   run;
4. only if the ceiling clears the threshold, prototype in the language with the largest absolute cost, and verify **both**
   matchers against real `git check-ignore -q --no-index` on randomised `**`-heavy cases before quoting a speedup.

## 8. The two follow-ups, done (2026-10-25)

§ 6 listed two variations that could still pay and named the order: delete the calls first. Both were implemented,
gated and measured the same day. Each entry below is the four-part shape `shared.md` uses, in brief; the full entries are
[`js.md`](js.md) § 8 and [`java.md`](java.md) § 9.

### JS: parse-time normalisation of a leading `**/`

**What the split said.** `doublestar` entered the DP **0.27** times per decision (2.9 cells, 8.1 % of that workload) while
Zig entered it zero times, because Zig drops the prefix at parse time.

**The change.** `js/gitignore.mjs` drops a leading `**/` before classifying, and sets `anchored = false`. Converted:
`**/x` → base-name literal `x`, `**/*.ext` → suffix rule `*.ext`, `**/x/y` → path-suffix rule `x/y` (and `/**/x`, since
the leading slash is stripped first). Left on the DP: `**/**/x`, `**/x/**/y`, `a/**/b`, any trailing `**`, a `**` inside a
segment (`a**/b`), and `**/` followed by another `/`. The rule keeps its file position, so ordering is untouched, and the
last-segment bucket now also holds plain unanchored names, so the eleven `**/name` rules of `doublestar` stay bucket
candidates rather than scan entries.

**Measured effect.** Paired alternating A/B, `--rounds 12`, min of 9, in-process loop time, two sessions:
`doublestar` **17.33 → 14.58 ms** (+15.9 %) and, reversed, **17.44 → 14.87** (+14.7 %); total +3.8 % / +3.1 %; other five
workloads ±4 % (noise). **DP calls per decision: 0.267 → 0** on `doublestar`, 0 elsewhere. Verdicts identical on all six
workloads, and the git oracle's `**`-heavy random cases agree.

**The risk it carried, and answered.** A normalised directory rule `**/x/` now behaves like the unanchored `x/` it means,
so a later `!x/` re-includes the directory and a file below is decided by its own name — git's answer, and the pre-change
build disagreed with git there. That is the recorded directory-only-negation divergence, fixed as a consequence of the
equivalence; `conformance/ancestor-vectors.json` now pins it. Risk left: a form nobody thought of that is *not*
equivalent, which is why the conversion is restricted to the leading prefix with no remaining `**` segment and why the
proof is the git oracle.

### Java: the literal/suffix rule classes

**What the split said.** Java's DP share was **4.9 %** of its total, the largest of the three ports, because its matcher
was universal — every pattern, including a plain literal and a `*.ext` suffix, went through `Glob.matches`. Measured
calls: `flat` 0.143 per decision, `doublestar` 0.267, zero on the other four.

**The change.** `Rule` gains a `Kind` (`LITERAL`, `SUFFIX`, `GLOB`) and `singleSegment`, decided at parse time, plus the
same `**/` normalisation as JS. A literal is `String.equals` (whole path when anchored, base name when one component,
`/`-boundary path suffix otherwise); a suffix is `path.endsWith` for the unanchored `*.ext` shape only (`/*.log` stays a
glob — the reference's suffix test wrongly matches `a/b.log`); a glob keeps the DP, the tail precheck and the
directory-prefix branch. The last-segment bucket was extended to plain unanchored names. `needsSegments()` means a
literal or suffix decision pays no `path.split("/")` at all, and no `Matcher` in `tailRejects`.

**Measured effect.** Paired alternating A/B, `--rounds 12`, min of 9, in-process loop time, two sessions:
**`flat` 14.01 → 6.71 ms (2.09x)** and **13.30 → 6.22 (2.14x)**; **`doublestar` 34.02 → 25.43 (1.34x)** and
**34.57 → 24.08 (1.44x)**; **`backtrack` 19.40 → 16.66 (1.16x)** and **19.41 → 16.95 (1.15x)**; totals **96.81 → 79.84
(1.21x)** and **96.85 → 78.66 (1.23x)**. `deep`, `anchored` and `dirs` moved 2.4-8.1 % slower in both sessions, inside
the noise floor and on code paths this change does not reach. **DP calls per decision: 0.143 and 0.267 → 0, and zero on every workload.** The gain exceeds the 4.9 % ceiling
because the share counted the DP body only; the same rules also allocated a `Matcher` per tail comparison, outside the
counter.

**The risk.** Each class must accept exactly what the DP accepted. Proof: 54 hand-written corners plus 150-200 randomised
`**`-heavy cases per run over three seeds, JS and Java both against `git check-ignore -q --no-index`, **0 disagreements**,
on top of the 34 + 14 + 17 vectors and the 6/6 × 10,000-verdict parity gate.

### What this leaves

The checklist in § 5 asked for the DP surface to be measured before the technique is revisited. It is now zero calls per
decision on every workload, in both ports, and Zig was already there: **the bit-parallel DP's precondition is not met and
this file stays closed.** The variation worth measuring next, if anything is, is § 6's "rules tested per decision" — the
scan, not the DP.

