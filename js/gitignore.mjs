// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//
// `.gitignore` semantics, for the walk `fsmeta scan` performs. The Java port (`GitIgnoreFile`,
// `GitIgnoreRules`) implements the same rules, and conformance/fsmeta-vectors.json's `gitignoreCases`
// materialise the same trees in both ports and compare the file lists — so this file may be read as the
// statement of the rules for either language.
//
// What a trio describes is "the files a project considers ours", and the definition of "not ours" is a
// .gitignore file read per directory. That is this repository's own answer (DEC-044: a hand-written skip
// list is a promise somebody has to remember to keep, and its failure is a silently incomplete index). So
// the rules below are git's:
//
//   * a file's patterns apply only to paths BELOW the directory holding it (which is also why a directory's
//     own .gitignore cannot exclude the directory itself);
//   * a pattern with a separator at the start or in the middle is anchored to that directory; otherwise it
//     matches at any depth;
//   * the LAST matching pattern wins, so `!keep.log` after `*.log` re-includes;
//   * a deeper file beats a shallower one;
//   * a trailing slash means directories only, and a file inside an excluded directory counts as excluded —
//     which is what makes pruning a directory equivalent to ignoring everything below it;
//   * matching is case-SENSITIVE on every platform, deliberately: a trio is written on one machine and read
//     on another, so the ports must agree with each other before they agree with a file system.

import { readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

/** The file name a walk reads per directory. */
import { compileSegments, segmentsMatch } from './glob.mjs';

export const GITIGNORE_FILE_NAME = '.gitignore';

/**
 * Translates one glob into a regular expression source, git's `**` rules included.
 *
 * Exported because it is the part worth testing on its own: everything else is precedence.
 */
export function translateGlob(glob) {
  let regex = '';
  for (let index = 0; index < glob.length; index++) {
    const c = glob[index];
    if (c === '\\') {
      if (index + 1 < glob.length) {
        regex += escapeRegExp(glob[++index]);
      } else {
        regex += '\\\\';
      }
      continue;
    }
    if (c === '*') {
      const doubleStar = index + 1 < glob.length && glob[index + 1] === '*';
      if (!doubleStar) {
        regex += '[^/]*';
        continue;
      }
      const first = index;
      const second = index + 1;
      const atSegmentStart = first === 0 || glob[first - 1] === '/';
      const followedBySlash = second + 1 < glob.length && glob[second + 1] === '/';
      const atEnd = second + 1 === glob.length;
      if (atSegmentStart && followedBySlash) {
        regex += '(?:.*/)?';          // "**/" — zero or more directories
        index = second + 1;           // consume the '/'
      } else if (atSegmentStart && atEnd) {
        regex += '.*';                // a trailing "/**" matches everything inside
        index = second;
      } else {
        regex += '[^/]*';             // any other consecutive asterisks are just asterisks
        index = second;
      }
      continue;
    }
    if (c === '?') {
      regex += '[^/]';
      continue;
    }
    if (c === '[') {
      const translated = translateCharacterClass(glob, index);
      regex += translated.regex;
      index = translated.close;
      continue;
    }
    regex += escapeRegExp(c);
  }
  return regex;
}

function escapeRegExp(character) {
  return /[.*+?^${}()|[\]\\/]/.test(character) ? `\\${character}` : character;
}

function translateCharacterClass(glob, open) {
    // A `]` immediately after the opener is a member, not the terminator: `[]]x` holds `]` then `x`.
    const from = glob[open + 1] === ']' ? open + 2 : open + 1;
    const close = glob.indexOf(']', from);
  if (close < 0) {
      // git's wildmatch aborts the whole pattern, so the class matches nothing and the rest is not read.
      return { regex: '(?!)', close: glob.length - 1 };
  }
  const body = glob.slice(open + 1, close);
  let translated = '[';
  let start = 0;
  if (body.length > 0 && (body[0] === '!' || body[0] === '^')) {
    translated += '^';
    start = 1;
  }
  for (let i = start; i < body.length; i++) {
    const c = body[i];
    if (c === '\\' && i + 1 < body.length) {
      translated += `\\${body[++i]}`;
    } else if (c === '[' || c === ']' || c === '^') {
      translated += `\\${c}`;
    } else {
      translated += c;
    }
  }
  if (translated === '[' || translated === '[^') {
    return { regex: '(?!)', close };          // an empty class matches nothing, as in git
  }
  return { regex: `${translated}]`, close };
}

/** A pattern segment with none of these bytes is a plain name, so a directory-only rule can be indexed by it. */
const hasWildcardByte = /[*?[\\]/;

/**
 * Below this many last-segment-bucket rules in a file, the bucket is not built and those rules are scanned. Four is
 * the measured line for this port (`doc/performance/js.md`): `doublestar`'s 28 bucket rules are 33-35% faster
 * with the bucket and `deep`'s five are 1.7-11.4% — below the ~13% noise floor, so not evidence — while `flat`
 * (three) and `backtrack` (two) stay on the scan, where they act as this change's noise controls. It is the same
 * shape as the unanchored-name index's gate: a map lookup has to replace more than one cheap test to pay.
 */
const BUCKET_MIN_RULES = 4;

/**
 * Classify a rule by its **last segment**, the file-side counterpart of the reference's `Chain.literal_dirs`.
 *
 * Directory-only rules are never bucketed: their match can be an ancestor directory, whose base name is not the
 * path's, so a base-name key would reject a path the rule really excludes. A plain unanchored name also stays on the
 * scan: it is one compiled segment test and it already has no prefix to verify. The bucket is for rules whose scan
 * costs a whole-path verification.
 */
function bucketKeyOf(rule) {
  if (rule.directoryOnly) {
    return null;
  }
  if (!rule.anchored && rule.literal !== null) {
    return null;
  }
  const tail = rule.lastSegment;
  if (tail.length === 0) {
    return null;
  }
  if (!hasWildcardByte.test(tail)) {
    return { kind: 'literal', value: tail };
  }
  if (tail.length >= 3 && tail[0] === '*' && tail[1] === '.' && !hasWildcardByte.test(tail.slice(1))) {
    // Key by the tail's own last-dot extension, so `*.class.txt` is reached by `Foo.class.txt` as well as by
    // `*.txt`'s names; the rule itself is still verified, so this is a superset filter, not the answer.
    const afterStar = tail.slice(1);
    return { kind: 'suffix', value: afterStar.slice(afterStar.lastIndexOf('.')) };
  }
  return null;
}

/** One parsed pattern. */
function parseRule(rawLine) {
  let line = stripTrailingUnescapedSpaces(rawLine);
  if (line.length === 0 || line[0] === '#') {
    return null;
  }
  let negated = false;
  if (line[0] === '!') {
    negated = true;
    line = line.slice(1);
    if (line.length === 0) {
      return null;
    }
  }
  const directoryOnly = line.endsWith('/') && !line.endsWith('\\/');
  if (directoryOnly) {
    line = line.slice(0, -1);
  }
  const anchored = line.startsWith('/') || line.includes('/');
  if (line.startsWith('/')) {
    line = line.slice(1);
  }
  if (line.length === 0) {
    return null;
  }
  // The last segment, for the last-segment precheck: in any successful whole-path match a final pattern segment
  // that is not `**` must match the path's last segment. A literal tail compares with no slice and a wildcard tail
  // keeps one small anchored regex. The regex rules use it before the whole-path regex; the DP rules use it on the
  // raw path, before the split — so it is recorded for a `**` rule too, not only for the regex ones.
  const doubleStar = line.split('/').includes('**');
  const lastSegment = line.slice(line.lastIndexOf('/') + 1);
  const lastIsDoubleStar = lastSegment === '**';
  const lastIsLiteral = !hasWildcardByte.test(lastSegment);
  return {
    negated,
    directoryOnly,
    anchored,
    // The raw last segment, kept for the last-segment buckets: the bucket needs the *string* (a literal tail, or
    // the `*.ext` shape to key by), not only the compiled test.
    lastSegment,
    // A plain name (no wildcard, no escape) is indexed rather than scanned: the directory-only ones are what a
    // per-path prefix walk asks about most, and a name is the whole question for the unanchored form.
    literal: hasWildcardByte.test(line) ? null : line,
    lastLiteral: !lastIsDoubleStar && lastIsLiteral ? lastSegment : null,
    lastPattern: !lastIsDoubleStar && !lastIsLiteral ? new RegExp(`^${translateGlob(lastSegment)}$`) : null,
    indexed: false,
    // Both anchors are required: Java's `Matcher.matches()` anchors the whole pattern, while JavaScript's
    // `RegExp.test` searches — and a missing `^` lets an anchored pattern match a path *suffix*. That one
    // difference is what the ignore vector `anchored-pattern` caught between the two ports.
    //
    // Only a pattern with a `**` segment needs the DP: that is the construct that makes a regex back-track
    // exponentially. Everything else is faster as one compiled regex, so it keeps one.
    pattern: doubleStar ? null : new RegExp(`^${anchored ? '' : '(?:.*/)?'}${translateGlob(line)}$`),
    segments: doubleStar ? compileSegments(line, anchored, translateGlob) : null,
  };
}

/** Trailing spaces are ignored unless they are escaped with a backslash. */
function stripTrailingUnescapedSpaces(line) {
  let end = line.length;
  const isEscaped = (index) => {
    let backslashes = 0;
    for (let i = index - 1; i >= 0 && line[i] === '\\'; i--) {
      backslashes++;
    }
    return (backslashes & 1) === 1;
  };
  while (end > 0 && line[end - 1] === ' ' && !isEscaped(end - 1)) {
    end--;
  }
  return line.slice(0, end);
}

/**
 * One `.gitignore` file: the directory it governs (relative to the walk root, `''` at the root) and its
 * patterns.
 *
 * @param {string} relativeDirectory the directory holding the file, `/`-separated
 * @param {string} text the file's text
 */
export function parseGitignore(relativeDirectory, text) {
  let directory = relativeDirectory ?? '';
  while (directory.endsWith('/')) {
    directory = directory.slice(0, -1);
  }
  const rules = [];
  // A CRLF checkout must parse like an LF one: the carriage return is not part of the pattern.
  for (const line of text.replace(/\r\n/g, '\n').split('\n')) {
    const rule = parseRule(line);
    if (rule !== null) {
      rules.push(rule);
    }
  }
  // The directory-only literal rules are indexed rather than scanned, because they are the class a per-path
  // decision asks about most and the one whose scan costs a prefix walk per rule. Two forms, because the
  // question differs: an anchored literal is a whole path prefix (`module0/src/main/java/`), so it is keyed
  // by that path and looked up once per depth the path has; an unanchored one is a single name (`build/`),
  // so it is keyed by the name and looked up once per segment. A literal can only match a prefix of exactly
  // its own depth, which is what the per-depth flag preserves: `java/fory-0/...` is rejected against a
  // `java/fory-1/...` rule by the lookup itself, the case a first-segment prune cannot see. The flags are a
  // plain array here rather than the reference's `u256`, and a pattern deeper than the array stays on the
  // scanned path, where the answer is still the correct one.
  const anchoredLiterals = new Map();
  const unanchoredLiterals = new Map();
  const anchoredDepths = [];
  let deepestAnchoredDepth = 0;
  for (let index = 0; index < rules.length; index++) {
    const rule = rules[index];
    if (!rule.directoryOnly || rule.literal === null) {
      continue;
    }
    if (rule.anchored) {
      let depth = 1;
      for (let at = rule.literal.indexOf('/'); at >= 0; at = rule.literal.indexOf('/', at + 1)) {
        depth += 1;
      }
      if (depth > 256) {
        continue;
      }
      anchoredLiterals.set(rule.literal, index);
      anchoredDepths[depth] = true;
      if (depth > deepestAnchoredDepth) {
        deepestAnchoredDepth = depth;
      }
    } else {
      unanchoredLiterals.set(rule.literal, index);
    }
    rule.indexed = true;
  }
  // The unanchored literals as parallel arrays, so a small set is scanned without a map lookup per segment.
  const unanchoredNames = [...unanchoredLiterals.keys()];
  const unanchoredRules = unanchoredNames.map((name) => unanchoredLiterals.get(name));

  // The last-segment buckets: a file-side counterpart of the anchored-directory index above. A rule whose last
  // segment is a literal base name (`src/**/target`) is keyed by that name; one whose last segment is `*.ext`-shaped
  // (`src/**/*.g4`) is keyed by the tail's last-dot extension. Both are necessary conditions, not answers: the rule
  // is verified against the whole path before it can set `best`, and the scan above it still decides a later rule.
  // Directory-only rules are excluded because an ancestor can match, and its base name is not the path's.
  const baseLiterals = new Map();
  const baseSuffixes = new Map();
  const bucketable = [];
  for (let index = 0; index < rules.length; index++) {
    const key = bucketKeyOf(rules[index]);
    if (key !== null) {
      bucketable.push({ index, kind: key.kind, value: key.value });
    }
  }
  if (bucketable.length >= BUCKET_MIN_RULES) {
    for (const { index, kind, value } of bucketable) {
      const map = kind === 'literal' ? baseLiterals : baseSuffixes;
      let positions = map.get(value);
      if (positions === undefined) {
        positions = [];
        map.set(value, positions);
      }
      positions.push(index);
      rules[index].indexed = true;
    }
  }
  return {
    relativeDirectory: directory,
    ruleCount: rules.length,

    /**
     * What this file decides about a path relative to the walk root.
     *
     * @returns {boolean|undefined} true to exclude, false to re-include, and `undefined` when no pattern
     *   matches — which is not "included", because a shallower file may still have an opinion
     */
    decide(relativePath, isDirectory) {
      let scoped = relativePath;
      if (directory !== '') {
        const prefix = `${directory}/`;
        if (!relativePath.startsWith(prefix)) {
          return undefined;
        }
        scoped = relativePath.slice(prefix.length);
      }

      // Ask the index first. `best` is the highest rule position any indexed rule can reach for this path, so
      // only rules after it can override the answer — usually none. That is also why a hit needs no split:
      // a path the index decides is answered before the matcher is reached.
      //
      // An unanchored directory-only rule names one directory, so it is a question about a directory's own base
      // name, never about an interior segment of a path below it: a matching ancestor is `#stateFor`'s inherited
      // fact. Testing interior segments here made a later `!out/` re-include `out/x` — git excludes it from `out/`
      // or decides the file by its own name.
      let best = -1;
      if (isDirectory && unanchoredNames.length > 0 && unanchoredNames.length < 4) {
        // Few names: a direct base-name comparison beats a map get and builds no substring. The threshold is
        // measured: backtrack 4960 -> 245 ns/decision and deep 1204 -> 169, while flat (4 names) goes 114 -> 181
        // and dirs (40 names) 133 -> 1937, so the scan is used only below it.
        for (let at = 0; at < unanchoredNames.length; at += 1) {
          if (unanchoredRules[at] > best && endsWithSegment(scoped, unanchoredNames[at])) {
            best = unanchoredRules[at];
          }
        }
      }
      if (isDirectory && unanchoredNames.length >= 4) {
        const at = unanchoredLiterals.get(lastSegmentOf(scoped));
        if (at !== undefined) {
          best = at;
        }
      }
      if (deepestAnchoredDepth > 0) {
        // One lookup per depth that actually holds a rule, not one per rule: a path shorter than a rule's depth
        // costs nothing at all.
        let depth = 0;
        let start = 0;
        for (;;) {
          const slash = scoped.indexOf('/', start);
          depth += 1;
          const last = slash < 0;
          if (last && !isDirectory) break;
          if (anchoredDepths[depth] === true) {
            const prefix = last ? scoped : scoped.slice(0, slash);
            const at = anchoredLiterals.get(prefix);
            if (at !== undefined && at > best) {
              best = at;
            }
          }
          if (last) break;
          start = slash + 1;
        }
      }

      // The last-segment buckets are candidate sources, not answers. A hit's last segment is only a necessary
      // condition, so the rule is verified against the whole path; the positions are ascending, so the highest
      // matching index in a bucket is its winner, and `best` is then compared with any general rule above it by
      // the scan below (`index > best`), which is exactly git's later-pattern-wins order. The whole lookup is a
      // separate function so a file without buckets (the `flat` rule set) keeps this method small.
      if (baseLiterals.size > 0 || baseSuffixes.size > 0) {
        best = bucketBest(rules, baseLiterals, baseSuffixes, scoped, isDirectory, best);
      }

      // Split once for every rule of this file that needs segments, and only when one of them is actually reached
      // *and* survives the last-segment precheck on the raw path: a file whose patterns all compile to a regex pays
      // no split at all (the `*.log`-shaped rule sets of the small workloads), and a DP rule whose final segment
      // cannot match this path is rejected before the split exists (the `backtrack` workload, where both DP rules
      // end `*.class` / `*.g4` and every path is a `.java`).
      let segments = null;
      let tail = null;
      for (let index = rules.length - 1; index > best; index--) {
        const rule = rules[index];
        if (rule.indexed) {
          continue;
        }
        if (rule.segments !== null) {
          if (segments === null) {
            // A directory-only rule is not prechecked: its ancestor branch asks about interior segments, whose last
            // segment is not the path's, so the path's own tail cannot reject it. Its split is paid as before.
            if (!rule.directoryOnly && !tailMatches(rule, scoped)) {
              continue;
            }
            segments = scoped.split('/');
          }
        } else if (rule.lastPattern !== null && tail === null) {
          tail = lastSegmentOf(scoped);
        }
        if (matches(rule, scoped, isDirectory, segments, tail)) {
          return !rule.negated;
        }
      }
      if (best >= 0) {
        return !rules[best].negated;
      }
      return undefined;
    },
  };
}

/** Whether `path`'s last `/`-separated segment is exactly `literal`, without building a segment string. */
function endsWithSegment(path, literal) {
  const start = path.length - literal.length;
  if (start < 0) {
    return false;
  }
  if (start > 0 && path.charCodeAt(start - 1) !== 47) {
    return false;
  }
  return path.endsWith(literal);
}

/** The last `/`-separated segment of a path. */
function lastSegmentOf(path) {
  const slash = path.lastIndexOf('/');
  return slash < 0 ? path : path.slice(slash + 1);
}

/**
 * The best rule index reachable through the last-segment buckets for `path`, or `best` unchanged.
 *
 * The base name is looked up in the literal bucket; its last-dot extension in the suffix bucket. Both lookups are
 * superset filters — a hit still goes through `bucketCandidate`, which verifies the whole rule.
 */
function bucketBest(rules, baseLiterals, baseSuffixes, path, isDirectory, best) {
  const base = lastSegmentOf(path);
  const literalPositions = baseLiterals.get(base);
  if (literalPositions !== undefined) {
    best = bucketCandidate(rules, literalPositions, best, path, isDirectory);
  }
  const dot = base.lastIndexOf('.');
  if (dot >= 0) {
    const suffixPositions = baseSuffixes.get(base.slice(dot));
    if (suffixPositions !== undefined) {
      best = bucketCandidate(rules, suffixPositions, best, path, isDirectory);
    }
  }
  return best;
}

/**
 * The highest rule index in one last-segment bucket that actually matches, or `best` unchanged.
 *
 * The positions are ascending, so walking them downwards finds the last matching pattern of the bucket first: the
 * first verified index at or above `best` is that class's winner, and a rule that fails its whole-path verification
 * falls through to the next position rather than to "no match". Kept as a module-level function, not a closure
 * created inside `decide`, because one allocation per decision was measurable on `backtrack`.
 */
function bucketCandidate(rules, positions, best, path, isDirectory) {
  for (let at = positions.length - 1; at >= 0; at -= 1) {
    const index = positions[at];
    if (index <= best) {
      break;
    }
    const rule = rules[index];
    let segments = null;
    if (rule.segments !== null) {
      if (!tailMatches(rule, path)) {
        continue;
      }
      segments = path.split('/');
    }
    if (matches(rule, path, isDirectory, segments, null)) {
      return index;
    }
  }
  return best;
}

/**
 * Whether the path can still match by its final segment: the same necessary condition `segmentsMatch` applies,
 * asked of the raw path so the caller can decide whether the split is worth paying at all. Only valid for a
 * whole-path match — a directory-only rule also asks about ancestor prefixes, and their last segment is not the
 * path's — and `true` when the final pattern segment is `**`, which has no such condition.
 */
function tailMatches(rule, path) {
  if (rule.lastLiteral !== null) {
    return endsWithSegment(path, rule.lastLiteral);
  }
  if (rule.lastPattern !== null) {
    return rule.lastPattern.test(lastSegmentOf(path));
  }
  return true;
}

function matches(rule, path, isDirectory, segments, tail) {
  if (rule.segments === null) {
    // No `**`: the compiled regex is both correct and faster (see the A/B in conformance/findings-js.md).
    if (!rule.directoryOnly) {
      // Last-segment precheck: a non-`**` final pattern segment has to match the path's last segment in any
      // successful match, so the whole-path regex is worth running only when that necessary condition holds.
      // A directory-only rule is not prechecked here: it asks about ancestor prefixes, whose last segment differs
      // from the path's, and those rules are almost always the indexed literal form.
      if (rule.lastLiteral !== null) {
        if (!endsWithSegment(path, rule.lastLiteral)) {
          return false;
        }
      } else if (!rule.lastPattern.test(tail ?? lastSegmentOf(path))) {
        return false;
      }
      return rule.pattern.test(path);
    }
    if (!rule.anchored) {
      // An unanchored `pat/` names a directory at any level below its file, so only the path's own base name can
      // be tested here; a matching ancestor is the directory state's inherited fact, not this rule's answer for
      // the path below it. Git's own file decision asks only the final component, which is why `!out/` after
      // `*.log` must not re-include `out/x`.
      return isDirectory && matchesName(rule, lastSegmentOf(path));
    }
    if (isDirectory && rule.pattern.test(path)) {
      return true;
    }
    for (let slash = path.indexOf('/'); slash >= 0; slash = path.indexOf('/', slash + 1)) {
      if (rule.pattern.test(path.slice(0, slash))) {
        return true;
      }
    }
    return false;
  }

  // Split once per decision, not once per rule: `segments` arrives from the caller that already has it (and that
  // only built it after `tailMatches` accepted the raw path).
  if (!rule.directoryOnly) {
    return segmentsMatch(rule.segments, segments);
  }
  if (!rule.anchored) {
    return isDirectory && matchesName(rule, segments[segments.length - 1]);
  }
  if (isDirectory && segmentsMatch(rule.segments, segments)) {
    return true;
  }
  // A file inside an excluded directory counts as excluded, so a directory-only pattern matches any ancestor too.
  // The walk prunes before it gets here; a caller testing a path on its own gets the same answer either way.
  for (let count = segments.length - 1; count >= 1; count -= 1) {
    if (segmentsMatch(rule.segments, segments, count)) {
      return true;
    }
  }
  return false;
}

/**
 * Whether an unanchored directory-only rule names this one directory segment.
 *
 * The rule's pattern has no separator (a separator makes it anchored), so its last segment is the whole name and
 * `lastLiteral` / `lastPattern` answer without a split or a whole-path regex. A lone `**` names every directory.
 */
function matchesName(rule, name) {
  if (rule.lastLiteral !== null) {
    return rule.lastLiteral === name;
  }
  if (rule.lastPattern !== null) {
    return rule.lastPattern.test(name);
  }
  return true;
}

/**
 * The rules of one directory, read from disk: an empty file object when the directory has none, so a walk's
 * push/pop pairs stay balanced.
 */
export function readGitignore(directoryPath, relativeDirectory) {
  const file = join(directoryPath, GITIGNORE_FILE_NAME);
  try {
    if (!statSync(file).isFile()) {
      return parseGitignore(relativeDirectory, '');
    }
  } catch {
    return parseGitignore(relativeDirectory, '');
  }
  return parseGitignore(relativeDirectory, readFileSync(file, 'utf8'));
}

/**
 * The `.gitignore` files that apply at one point of a walk — git's precedence in a stack.
 *
 * A walk pushes a directory's file when it enters and pops it when it leaves, so the stack is exactly the
 * set of files governing the path being visited. The deepest file with an opinion decides; within a file the
 * last matching pattern does.
 */
export class GitIgnoreRules {
  #stack = [];
  // A directory's state, keyed by its path relative to the walk root. A path list visits the same directories over
  // and over (`backtrack` asks about 84,000 ancestor directories that are 42 distinct ones), and the rules are a
  // snapshot, so the state cannot change while the stack is unchanged. `push`/`pop` clear it: they are the only
  // things that change which files govern a directory, and a cached answer must never outlive them.
  //
  // The state is the two facts a decision needs about the path's directory: whether it (or an ancestor) is excluded,
  // and — implicit here — the chain of files that governs it. The chain half is already free in this port because the
  // walk hands the stack to the decider instead of making it walk up the file system, so the cache pays for the
  // ancestor half: one map lookup and one `dirname` per decision instead of a lookup and a substring per level.
  #states = new Map();
  // The historical walk, kept for a path outside the contract (a leading or trailing separator), where the index key
  // would be a different one than the walk would ask about. Same shape as the memo it replaced.
  #excluded = new Map();

  push(file) {
    this.#stack.push(file);
    this.#states.clear();
    this.#excluded.clear();
  }

  pop() {
    this.#stack.pop();
    this.#states.clear();
    this.#excluded.clear();
  }

  get depth() {
    return this.#stack.length;
  }

  decide(relativePath, isDirectory) {
    const direct = this.decideDirect(relativePath, isDirectory);
    if (direct === true) {
      // A directly excluded path needs no ancestor fact at all — the common case on a rule set with a literal hit.
      return true;
    }
    const slash = relativePath.lastIndexOf('/');
    // The index keys on the directory, and `dirOf` is the substring before the last separator for every path in the
    // contract (`/`-separated, no leading or trailing slash). A path outside it keeps the historical answer rather
    // than being answered from an index built on a different key.
    if (slash === 0 || slash === relativePath.length - 1) {
      return this.#walkAncestors(relativePath, direct);
    }
    if (this.#stateFor(slash < 0 ? '' : relativePath.slice(0, slash)).ancestorExcluded) {
      return true;
    }
    return direct;
  }

  /**
   * The ancestor-excluded fact for a directory, inherited: a directory is excluded when its parent is, or when its
   * own decision through the stack excludes it — exactly the prefix set the per-path walk asked, computed once per
   * directory instead of once per path per level.
   */
  #stateFor(directory) {
    let state = this.#states.get(directory);
    if (state !== undefined) {
      return state;
    }
    let ancestorExcluded = false;
    if (directory !== '') {
      const slash = directory.lastIndexOf('/');
      const parent = this.#stateFor(slash < 0 ? '' : directory.slice(0, slash));
      ancestorExcluded = parent.ancestorExcluded || this.decideDirect(directory, true) === true;
    }
    state = { ancestorExcluded };
    this.#states.set(directory, state);
    return state;
  }

  /** The pre-index ancestor walk, used only for a path the index does not key on. */
  #walkAncestors(relativePath, direct) {
    for (let slash = relativePath.lastIndexOf('/'); slash >= 0; slash = relativePath.lastIndexOf('/', slash - 1)) {
      const ancestor = relativePath.slice(0, slash);
      let excluded = this.#excluded.get(ancestor);
      if (excluded === undefined) {
        excluded = this.decideDirect(ancestor, true) === true;
        this.#excluded.set(ancestor, excluded);
      }
      if (excluded) {
        return true;
      }
    }
    return direct;
  }

  /** What the rules say about this exact path, ignoring its ancestors. */
  decideDirect(relativePath, isDirectory) {
    for (let index = this.#stack.length - 1; index >= 0; index--) {
      const decision = this.#stack[index].decide(relativePath, isDirectory);
      if (decision !== undefined) {
        return decision;
      }
    }
    return undefined;
  }

  isIgnored(relativePath, isDirectory) {
    return this.decide(relativePath, isDirectory) === true;
  }
}
