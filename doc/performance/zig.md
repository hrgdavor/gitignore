# Zig: the reference implementation

`src/gitignore.zig` (one `.gitignore` file's patterns) and `src/ignore.zig` (the stack of them, and the decision) are the
reference: the ports must agree with them byte for byte (`bun scripts/check-verdicts.mjs`), and their performance is the
number the ports are quoted against. They reached **92.3 ms per round in the initial measurement** and **9.0 ms per round
today** — **10.2x**, from five changes, one of which was a correctness bug the profiling fuzz found on the way.

Two things are deliberately still in the tree:

- **`decideNaive`** / **`globMatchNaive`** — the historical recursive `**` matcher and the unindexed rule scan. They are
  what the differential fuzz compares against, and `-Dnaive=true` builds a CLI from them, so the design that was too slow
  stays demonstrable instead of remembered. The default executable does not reference them.
- **`-Dnaive` and `ignore-decide-naive` in `zig-out/bin`** — see the README's "Building and running it".

## 1. The baseline in place before any of this

The 3.81x section below starts from a matcher that is **already indexed**, and a port that copies only §2-§4 and skips
this gets a smaller win. Three things are in place before the first number on this page:

- **Rule classes at parse time** (`Kind = {literal, suffix, glob}`): a rule with no wildcard byte is a string comparison,
  a `*.ext` rule is `endsWith`, and only a general glob reaches the matcher. `Rule.last_segment` and `Rule.first_segment`
  carry the literal head/tail a rule can be rejected by. Cost: one pass over the rule file.
- **Per-chain indexes**, built once per deepest rules file (`Chain`, `src/ignore.zig`): `literals` (unanchored literals,
  by the segment they name), `literals_dir_only`, `suffixes`, `wilds`, `anchored`. Rules tested per path after this:
  **5 (`flat`), 19 (`deep`), 98 (`doublestar`), 17 (`anchored`), 45 (`backtrack`)** (`doc/measurement.md`, 2026-10-24) —
  i.e. below the rule count of the file, which is what the index is for.
- **`**/pat` normalised at parse time** to the unanchored form (`//doublestar-normalise` in `gitignore.zig`), so those
  rules stay in the indexed classes instead of paying an ancestor-prefix walk each. Without it, fifty-odd rules in a real
  Java tree each cost a prefix walk.

None of these three has been measured on its own; they are the baseline the 3.81x section calls "before". A port should
still do them first — they are what makes §2-§4 worth anything — and should not expect to see them in a table here.

## 2. A directory chain in one hash: `DirState`

**What the split said.** The first phase split of `ignore.Stack.decide` over all six workloads (1,123 ms total) found
that the matcher was not the cost (commit `7053629`, 2026-10-24):

| phase                                                           | ms    | share   |
| --------------------------------------------------------------- | ----: | ------: |
| chain resolution — the upward walk for the deepest `.gitignore` | 548   | **49%** |
| ancestor memo walk                                              | 295   | 26%     |
| per-rule matching                                               | 237   | 21%     |
| ancestor re-decisions                                           | 26    | 2%      |

So **75% of the reference's time was two upward walks**, and a rule index — the obvious next lever — could only reach the
21%. Rules per path were already 5/19/98/17/45.

**The change.** A per-directory `DirState` in `Stack.dir_states`:

```zig
const DirState = struct {
    chain: ?*Chain,          // flattened matcher governing this directory, null when none has rules
    ancestor_excluded: bool, // this directory or one of its ancestors is excluded
};
```

One hash per path replaces both walks. The ancestor flag is **inherited**: a directory is excluded when its parent is, or
when its own decision through the parent's chain excludes it — exactly the prefix set the old walk asked, computed once
per directory instead of once per path per level. An excluded directory's chain is not resolved at all, because nothing
below it can matter. Misses (`chain == null`) keep the old semantics, and a `dirname` guard preserves the historical
answer for paths outside the contract: `dirOf` is `dirname` for every path in the contract, and when it is not, the code
falls back to `decideOne` rather than answering from an index built on a different key.

**Measured effect** (paired alternating runs, min of 9, `--rounds 12`, `doc/measurement.md`, 2026-10-24):

| workload   | before ms | after ms  | speed-up            |
| ---------- | --------: | --------: | ------------------: |
| flat       | 4.3       | 1.4       | ~3x (process floor) |
| deep       | 111.8     | 24.7      | 4.5x                |
| doublestar | 142.0     | 136.1     | 1.04x (noise)       |
| anchored   | 18.7      | 15.0      | 1.25x               |
| dirs       | 5.1       | 3.2       | 1.6x                |
| backtrack  | 799.4     | 103.2     | **7.7x**            |
| total      | 1,081     | **284**   | **3.81x**           |

Three sessions reproduced 3.73-3.87x; verdicts byte-identical on all six workloads; a differential fuzz of `decide`
against the untouched `decideNaive` found 0 disagreements over 6,000 decisions on 300 random multi-file stacks.
`doublestar` not moving is the point of the next section: its rules are the cost there, not its chain.

**The risk.** The key must be the path **relative to the root**, and every caller must agree on the spelling — the stack
has two scratch buffers (`scratch`, `path_scratch`) whose contents are *not* stable keys, which is why `dir_states.put`
dupes the key. And because an excluded directory's chain is never resolved, a decision asked about a directory *below* an
excluded one returns `true` from the inherited flag without ever consulting a rule: that is git's rule, but it means the
index cannot be reused by a caller that wants the rule rather than the verdict.

## 3. Anchored-literal bucket: `Chain.literal_dirs`

**What the split said.** With the chains cached, `doublestar` was 48% of the remaining total, and its 100 anchored literal
rules share the first segment `java` — so the first-segment prune rejected none of them. Measured: **120.3 rule tests per
decision, of which 101 are anchored literals**, 100 of them anchored at depth 6, costing **398.5 memcmps and 0 glob
calls**, while every path that reaches the chain is **depth 5** (the 400 paths under an excluded `generated/` are
answered by the ancestor cache before a rule is tested). The work was real and entirely avoidable
(commit `ecff1ff`, 2026-10-25).

**The change.** Anchored **directory-only** literals (`java/fory-0/src/main/resources/generated/`) move out of the scanned
`anchored` list into `Chain.literal_dirs`, keyed by their full literal path, plus `literal_dir_mask` — a `u256` whose bit
`d` is set when some such rule has `d` segments. `Chain.decide` walks its own path prefixes once, skips any depth the mask
does not mention (**one map lookup per depth that holds a rule**, not one per rule), and looks the prefix up. A literal
pattern can only match a prefix of exactly its own depth, so the lookup also rejects
`java/fory-0/...` against a `java/fory-1/...` rule — the case a first-segment prune structurally cannot see.

Two indexes were considered and **not** built, both for a measured reason: exact anchored literals stay in the scanned
list (indexing them regressed `deep`; a chain holds one or two, and one comparison beats an index walk), and there is no
suffix bucket (`doublestar` has zero anchored-general tests, and `backtrack`'s only anchored glob ends `*.g4`, which is not
a literal suffix). A rule with 256 or more segments also stays in the scanned list: the mask cannot address it, and
correctness comes first for a shape no real `.gitignore` has.

**Measured effect** (commit `ecff1ff`, 2026-10-25):

| workload                       | before ms                | after ms                                |
| ------------------------------ | -----------------------: | --------------------------------------: |
| **doublestar**                 | **135.4**                | **15.1** (8.99x)                        |
| anchored                       | 15.3                     | 9.3                                     |
| flat / deep / dirs / backtrack | 1.7 / 21.3 / 3.0 / 104.9 | 1.9 / 23.1 / 1.7 / 107.2 (within noise) |
| total                          | 281.6                    | **158.2 (1.78x)**                       |

Repeats put `doublestar` at 8.2-9.0x and the total at 1.78-1.85x. A **100-round control** confirmed `deep` 0.98x and
`backtrack` 0.99x, i.e. the small movers really are noise — that control is the method worth copying: run the
configuration that should *not* change for long enough that a change would show.

**The risk.** `literal_dir_mask` is a `u256`, so the mechanism silently has a depth limit (256 segments); the code keeps
deeper rules on the slow path rather than mis-indexing them, and a port must do the same or document the bound. The mask
is also per chain and must be rebuilt when the chain is: it is built in `chainFor` alongside the map, so a chain that is
cached from an earlier pass carries both.

## 4. The last-segment precheck and a manual `nextSeparator`

**What the split said.** `backtrack` before this change was 102.1 ms, of which **DP rows 42.6 ms (41.7%)**, pattern+path
splitting 22.6 ms (22.1%), chain literal scan 22.2 ms (21.8%), chain lookup 14.6 ms (14.3%) — DP plus splitting was
**65%** of the workload, spent on a rule whose final segment `*.g4` cannot match a `.java` path (commit `9fb0d30`,
2026-10-25). And the separator scan itself was measured in the same pass: `std.mem.indexOfScalarPos` cost **20.4 ms**
where a byte loop cost **3.66 ms** over the same paths.

**The change.** Two edits, both in the hot path:

1. `globMatch` tests the pattern's last segment (when it is not `**`) against the path's last segment **first**, before
   either input is split. A non-matching rule then costs one `wildMatchSegment` instead of a whole DP.
2. `Chain.decide` uses a hand-written `nextSeparator` instead of `std.mem.indexOfScalarPos`: the segments here are a
   handful of bytes, and the vectorised search is written for the long searches it was designed for. The comment in
   `src/ignore.zig` records both numbers next to the function.

**Measured effect.** `backtrack` **101.6 → 28.4 ms (3.58x)**, total **128.7 → 50.8 ms (2.53x)**, **no workload
regressed**; the separator scan 20.4 → 3.66 ms, which also helps `deep` and `doublestar` (commit `9fb0d30`, 2026-10-25).
After this, the same split shows **0% of `backtrack` in DP cells**.

**The risk.** The precheck is valid only when the pattern is matched against a **whole** path. A directory-only rule that
asks about the first `n` segments of a path would need the last *considered* segment, not the path's last, and Zig avoids
the question by keeping the precheck inside `globMatch` (which always matches whole texts) while
`Chain.decide`/`chainRuleMatches` slice prefixes for their own directory-only walk. A port that copies the precheck into a
prefix-aware matcher will get wrong verdicts on ancestor questions — which the vectors cover only indirectly.

## 5. The bug the fuzz found

The differential fuzz — `decide` against the untouched `decideNaive` — is what makes the index trustworthy, and it earned
its keep at `9fb0d30`: **an unanchored literal matched non-final segments**, so `!a` re-included `d/a/build`, which git
does not (commit `9fb0d30`, 2026-10-25). Both ports were right and the reference was wrong; the vectors did not cover it.

The fix is the comment now sitting in `Chain.decide`: an unanchored literal names one file or directory, so **only the
final segment can be that name**. A matching *ancestor* directory is already an `ancestor_excluded` fact, and asking the
earlier segments again is how a negation like `!a` reached a file two levels below an `a` directory.

Three numbers belong to this, because they are the argument that the bug class is closed rather than the instance:

- **14,933 randomised decisions over 1,000 random multi-file stacks, zero disagreements** at the commit that fixed it;
- **80,000 decisions over 2,000 stacks** at the bucket change immediately before it — the same fuzz, a different random
  draw, which is why the bug survived one commit and was caught by the next; a fuzz is a sample, not a proof;
- one **pre-existing** `decideNaive` gap (a nested unanchored `out/`) is documented in that commit and reproduces on the
  previous build — i.e. the fuzz has found a case where the *naive* reference disagrees with git, and it is left visible
  rather than "fixed" by making the two agree.

The lesson for a port: **an index changes which questions are asked**, and the questions that stop being asked are exactly
the ones a vector set was written against. Compare against a slow implementation, not against the expectations, or the
optimisation's own assumptions become the oracle.

## 6. Where the time goes now

Measured by this session's track, 2026-10-25, after the 3.58x change:

| phase                                   | share   |
| --------------------------------------- | ------: |
| the directory-key hash (`dir_states`)   | **52%** |
| chain scan                              | **37%** |
| the last-segment precheck               | 10.5%   |
| DP cells                                | **0%**  |

Read it as the shape of what is left, not as a promise: **89% is still hash lookups and rule scanning**, the DP has been
eliminated as a cost on this corpus, and the next lever is a cheaper per-directory state (a smaller key, an integer id
instead of a path string, or a per-directory index into the parent's state) rather than anything in the matcher.

Caveat on absolute totals, because this page quotes three of them for the same committed build: **50.8 ms** (commit
`9fb0d30`), **83.8-86.1 ms** (a re-run while writing this page, min of 5, `--rounds 12`) and **108.1 ms** (the closing
table in the [README](README.md)). Per-row ordering agrees across all three, and `doublestar` agrees to 5%; the totals do
not, because start-up subtraction on six small numbers is where the error lives. See the README's "How to read these
numbers", item 5.

## What the split said

- **The matcher was never the bottleneck until the walks were gone.** Chain resolution 49%, ancestor walks 26%, rules 21%
  — and the two largest wins on this page (3.81x and 8.99x) both replaced a traversal, not a comparison.
- **A prune that rejects nothing is not a prune.** The first-segment prune could not separate 100 rules that all begin
  `java`; the depth-keyed literal bucket could, and it was worth 8.99x on the workload those rules define.
- **Reject with one comparison before you compute.** After the precheck, `backtrack` spends **0%** in DP cells: the
  expensive correct answer was being computed for rules that a single `endsWith`-style test could refuse.
- **Large constants are cheaper than they look.** 20.4 → 3.66 ms from replacing a library separator search with a byte
  loop, on paths whose segments are a few bytes long.
- **An index changes the questions, so it needs a fuzz.** The one correctness bug in this directory came from an index
  that answered a question the vectors never asked.

## What is left

- **The per-directory state is 52% of the time** and is keyed by a path string. That is the next lever, and it is a data
  structure question (interned directory ids, or a state hanging off the walker's own directory node), not a matcher
  question.
- **The chain scan is 37%**, still doing a `literal`/`suffix`/`wild`/`anchored` scan per decision. The reference has no
  equivalent of a "one rule index, consulted once" structure; the ports have none at all.
- **`doublestar`'s remaining ~15 ms is directory-state and chain lookup**, not rules — the same lever as the two above.
- **A prefix-aware precheck.** §4's precheck cannot be used by a directory-only ancestor walk, which is why that walk
  still slices prefixes and tests each. A safe form (pass the last considered segment in) would extend the 3.58x to
  directory-only rules, and needs a vector set that exercises it before it is believed.
- **`decideNaive` has one known disagreement with git** (nested unanchored `out/`), documented at `9fb0d30`. Until it is
  settled, the differential fuzz's oracle has a hole, and any disagreement the fuzz reports in that shape is the oracle's
  fault rather than the matcher's.


## "Last-segment buckets (backtrack −27/−31%, total −4 to −11%)"

**Measured effect.** Same protocol (start-up 4.68 → 4.65 ms), session 1:

| workload   | before | after | delta      | before ns/dec | after ns/dec | bucket built |
| ---------- | -----: | ----: | ---------: | ------------: | -----------: | ------------ |
| flat       | 0.74   | 0.79  | +7.4%      | 62            | 66           | yes (3)      |
| deep       | 5.72   | 5.55  | −3.0%      | 239           | 231          | yes (5)      |
| doublestar | 6.14   | 6.15  | +0.3%      | 256           | 256          | yes (17)     |
| anchored   | 4.30   | 4.69  | +8.9%      | 179           | 195          | no (0)       |
| dirs       | 1.65   | 1.57  | −4.7%      | 138           | 131          | no (0)       |
| backtrack  | 3.99   | 2.93  | **−26.5%** | 166           | 122          | yes (2)      |
| total      | 22.54  | 21.69 | −3.8%      |               |              |              |

Session 2: `backtrack` 4.10 → 2.82 ms (**−31.2%**), total 24.55 → 21.81 (−11.1%), controls `anchored` −6.1% / `dirs`
−4.0% (and `flat` −27.1% on a ~1 ms workload, which is why it is not quoted as a win). `doublestar` moved +0.3% /
−11.3%: the bucket is built there but does not pay, because this port's suffix list is already a bare `endsWith` and
its tail precheck is `wildMatchSegment`, not a DP entry. `deep` is neutral. `bucket_min_rules = 2` is what makes the
`backtrack` case build a bucket at all; it is the only Zig win above the floor, and its cause is specific: the
`src/**/.../*.g4` rule was verified by the glob matcher for every path, and the bucket's `.g4` miss replaces that with
one hash lookup.

**Risk.** As shared.md. Above-the-floor evidence exists for `backtrack` only; `flat`/`deep`/`doublestar` are neutral
within noise, so nothing was reverted and nothing is claimed for them. **Left:** the JS/Java dir-only-negation
divergence is not a Zig problem; Zig agrees with git on all three fuzz cases.

---
