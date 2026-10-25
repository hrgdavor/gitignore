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
  return {
    negated,
    directoryOnly,
    anchored,
    // A plain name (no wildcard, no escape) is indexed rather than scanned: the directory-only ones are what a
    // per-path prefix walk asks about most, and a name is the whole question for the unanchored form.
    literal: hasWildcardByte.test(line) ? null : line,
    indexed: false,
    // Both anchors are required: Java's `Matcher.matches()` anchors the whole pattern, while JavaScript's
    // `RegExp.test` searches — and a missing `^` lets an anchored pattern match a path *suffix*. That one
    // difference is what the ignore vector `anchored-pattern` caught between the two ports.
    //
    // Only a pattern with a `**` segment needs the DP: that is the construct that makes a regex back-track
    // exponentially. Everything else is faster as one compiled regex, so it keeps one.
    pattern: line.split('/').includes('**')
      ? null
      : new RegExp(`^${anchored ? '' : '(?:.*/)?'}${translateGlob(line)}$`),
    segments: line.split('/').includes('**') ? compileSegments(line, anchored, translateGlob) : null,
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
      let best = -1;
      if (unanchoredLiterals.size > 0) {
        // An unanchored directory rule names one segment, and for a file the last segment is the file itself.
        let start = 0;
        for (;;) {
          const slash = scoped.indexOf('/', start);
          const last = slash < 0;
          if (!last || isDirectory) {
            const name = last ? scoped.slice(start) : scoped.slice(start, slash);
            const at = unanchoredLiterals.get(name);
            if (at !== undefined && at > best) {
              best = at;
            }
          }
          if (last) break;
          start = slash + 1;
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

      // Split once for every `**` rule of this file, and only if one of them is reached: a file whose patterns all
      // compile to a regex pays no split at all (the `*.log`-shaped rule sets of the small workloads).
      let segments = null;
      for (let index = rules.length - 1; index > best; index--) {
        const rule = rules[index];
        if (rule.indexed) {
          continue;
        }
        if (rule.segments !== null && segments === null) {
          segments = scoped.split('/');
        }
        if (matches(rule, scoped, isDirectory, segments)) {
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

function matches(rule, path, isDirectory, text = null) {
  if (rule.segments === null) {
    // No `**`: the compiled regex is both correct and faster (see the A/B in conformance/findings-js.md).
    if (!rule.directoryOnly) {
      return rule.pattern.test(path);
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

  // Split once per decision, not once per rule: `text` arrives from the caller that already has it.
  const segments = text ?? path.split('/');
  if (!rule.directoryOnly) {
    return segmentsMatch(rule.segments, segments);
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
