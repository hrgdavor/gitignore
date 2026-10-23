#!/usr/bin/env bun
// Generate conformance cases from a real git checkout, using git's own answers.
//
//   bun conformance/from-git-check-ignore.mjs <checkout> [--limit 200] [--out conformance/corpus-<name>.json]
//
// Candidates come from two queries, so both verdicts appear:
//
//   git -C <checkout> ls-files --others --ignored --exclude-standard   ignored, untracked -> exclude
//   git -C <checkout> ls-files                                        tracked, never ignored -> include
//
// Each candidate is then answered by `git -C <checkout> check-ignore -v -n -- <path>`, so the
// verdict and the deciding `.gitignore` file, line and pattern come from git rather than from a
// reimplementation here. `-n` makes git print a line for every path; a path no pattern matched
// is the `::<TAB><path>` line and exit status 1.
//
// PROVENANCE: an emitted case carries a path name and the TEXT of the `.gitignore` files that
// govern it -- file names and rule text only, never the contents of an ignored file. A corpus
// derived from a checkout still carries that checkout's path names and rule text, so it must not
// be committed when those paths identify a private repository: write it under `.tmp/` (or pass an
// `--out` outside the tracked tree), not into this project's committed conformance directory.
//
// A per-case `source` field names the deciding `.gitignore` file and line. It is provenance, not
// part of the matcher contract, and is present only when a pattern matched (an `include` case has
// no deciding rule).
//
// Skipped, and reported on stdout rather than guessed at:
//   - a path whose check-ignore verdict disagrees with the enumeration it came from;
//   - an ignored path decided by `.git/info/exclude` or a global `core.excludesFile`, whose rule
//     is not one of the checkout's `.gitignore` files (this project does not read those files);
//   - a tracked path whose `include` is git's index answer while a `.gitignore` pattern still
//     matches it. The emitted rule text would decide the path the other way, so the case cannot
//     be reproduced by a matcher that only sees files and a path.

import { spawnSync } from 'node:child_process';
import {
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { basename, dirname, join, posix, resolve } from 'node:path';
import { reportDuration, stopwatch } from '../../scripts/lib/timing.js';

const USAGE = `from-git-check-ignore — conformance cases from a checkout's own git answers

usage:
  bun conformance/from-git-check-ignore.mjs <checkout> [--limit 200] [--out <file>]

options:
  --limit N    cap the number of emitted cases (default 200)
  --out FILE   write the corpus here (default conformance/corpus-<basename of checkout>.json)
  -h, --help   show this help
`;

function usageError(message) {
  console.error(`from-git-check-ignore: ${message}`);
  console.error(USAGE);
  process.exit(1);
}

function fail(message) {
  console.error(`from-git-check-ignore: ${message}`);
  process.exit(1);
}

const elapsed = stopwatch();

let checkoutArgument = null;
let limit = 200;
let out = null;
const argv = process.argv.slice(2);

for (let index = 0; index < argv.length; index += 1) {
  const argument = argv[index];
  if (argument === '--limit') {
    const raw = argv[++index];
    if (raw === undefined) usageError('--limit needs a number');
    limit = Number(raw);
    if (!Number.isInteger(limit) || limit <= 0) usageError('--limit needs a positive integer');
  } else if (argument === '--out') {
    const raw = argv[++index];
    if (raw === undefined || raw === '') usageError('--out needs a file path');
    out = raw;
  } else if (argument === '--help' || argument === '-h') {
    console.log(USAGE);
    process.exit(0);
  } else if (argument.startsWith('-')) {
    usageError(`unknown option: ${argument}`);
  } else if (checkoutArgument === null) {
    checkoutArgument = argument;
  } else {
    usageError(`unexpected argument: ${argument}`);
  }
}
if (checkoutArgument === null) usageError('a checkout path is required');

const checkout = resolve(checkoutArgument);
let checkoutStat;
try {
  checkoutStat = statSync(checkout);
} catch {
  fail(`${checkoutArgument} does not exist`);
}
if (!checkoutStat.isDirectory()) fail(`${checkoutArgument} is not a directory`);

// `.git` may be a directory (an ordinary checkout) or a file (a linked worktree); both are
// refusals to run only when it is absent, and everything after this asks `git -C` rather than
// assuming a directory.
if (!existsSync(join(checkout, '.git'))) {
  fail(
    `${checkoutArgument} has no .git; pass the root of a git checkout ` +
      `(a worktree's .git file is accepted)`,
  );
}

const topLevel = spawnSync('git', ['-C', checkout, 'rev-parse', '--show-toplevel'], {
  encoding: 'utf8',
});
if (topLevel.error) fail(`could not run git: ${topLevel.error.message}`);
if (topLevel.status !== 0) {
  fail(`${checkoutArgument} is not a usable git work tree: ${topLevel.stderr.trim()}`);
}
let root;
try {
  root = realpathSync(topLevel.stdout.trim());
} catch {
  root = topLevel.stdout.trim();
}

function git(args, input) {
  const result = spawnSync('git', ['-C', root, ...args], {
    input,
    encoding: 'utf8',
    maxBuffer: 1 << 30,
  });
  if (result.error) fail(`could not run git ${args.join(' ')}: ${result.error.message}`);
  return result;
}

function gitOrFail(args) {
  const result = git(args);
  if (result.status !== 0) {
    fail(`git ${args.join(' ')} failed (exit ${result.status}): ${result.stderr.trim()}`);
  }
  return result.stdout;
}

function nulSeparated(text) {
  return text.split('\0').filter((value) => value.length > 0);
}

const ignoredPaths = nulSeparated(
  gitOrFail(['ls-files', '--others', '--ignored', '--exclude-standard', '-z']),
);
const trackedPaths = nulSeparated(gitOrFail(['ls-files', '-z']));

// Interleave the two enumerations so a small --limit still emits both verdicts, and deduplicate
// defensively: a path is either tracked or ignored, never both.
const candidates = [];
const seen = new Set();
for (let index = 0; index < Math.max(ignoredPaths.length, trackedPaths.length); index += 1) {
  for (const [paths, expected] of [
    [ignoredPaths, 'exclude'],
    [trackedPaths, 'include'],
  ]) {
    if (index >= paths.length) continue;
    const path = paths[index];
    if (seen.has(path)) continue;
    seen.add(path);
    candidates.push({ path, expected });
  }
}

/**
 * Ask check-ignore about one path. `--no-index` asks what the rule files alone would decide,
 * ignoring git's "tracked paths are never ignored" answer.
 */
function checkIgnore(path, noIndex = false) {
  const args = ['check-ignore', '-v', '-n'];
  if (noIndex) args.push('--no-index');
  args.push('--', path);
  const result = git(args);

  if (result.status === 1) {
    // Non-matching path: git prints "::<TAB><path>" and exits 1.
    if (!result.stdout.startsWith('::')) {
      return { verdict: null, reason: 'unexpected check-ignore output' };
    }
    return { verdict: 'include' };
  }
  if (result.status !== 0) {
    fail(`git check-ignore failed for ${path} (exit ${result.status}): ${result.stderr.trim()}`);
  }

  const text = result.stdout.replace(/\r?\n$/, '');
  if (text.split(/\r?\n/).length !== 1) {
    return { verdict: null, reason: 'path name contains a newline' };
  }
  const tab = text.indexOf('\t');
  const left = tab === -1 ? text : text.slice(0, tab);
  if (left === '::') return { verdict: 'include' };

  const firstColon = left.indexOf(':');
  const secondColon = firstColon === -1 ? -1 : left.indexOf(':', firstColon + 1);
  if (secondColon === -1) {
    return { verdict: null, reason: 'unexpected check-ignore output' };
  }
  return {
    verdict: 'exclude',
    source: left.slice(0, firstColon),
    line: left.slice(firstColon + 1, secondColon),
    pattern: left.slice(secondColon + 1),
  };
}

/** The source of a matching rule, if it is a `.gitignore` inside this checkout. */
function checkoutGitignore(source) {
  if (source === '.gitignore') return '.gitignore';
  if (!source.endsWith('/.gitignore')) return null;
  if (source.startsWith('/') || /^[A-Za-z]:[\\/]/.test(source)) return null;
  const normalized = posix.normalize(source);
  if (normalized === '..' || normalized.startsWith('../')) return null;
  return normalized;
}

/**
 * Every `.gitignore` that governs `path`, root first: a file in a directory governs the names
 * directly under that directory, so the files from the root down to the path's own directory are
 * the ones a matcher must load.
 */
function governingRuleFiles(path) {
  const directory = posix.dirname(path);
  const parts = directory === '.' ? [] : directory.split('/');
  const ruleFiles = [];
  for (let depth = 0; depth <= parts.length; depth += 1) {
    const dir = parts.slice(0, depth).join('/');
    const source = dir === '' ? '.gitignore' : `${dir}/.gitignore`;
    const absolute = join(root, ...source.split('/'));
    // Git does not follow a symlink used as a .gitignore, and a case may copy rule text only from
    // an ordinary file; anything else is treated as not governing.
    try {
      if (!lstatSync(absolute).isFile()) continue;
    } catch {
      continue;
    }
    let rules;
    try {
      rules = readFileSync(absolute, 'utf8');
    } catch {
      return { error: `cannot read ${source}` };
    }
    ruleFiles.push({ dir, rules });
  }
  return { ruleFiles };
}

/** statSync follows symlinks, so a symlink to a directory is reported as a directory. */
function isDirectory(path) {
  try {
    return statSync(join(root, ...path.split('/'))).isDirectory();
  } catch {
    return false;
  }
}

function describeSkipList(list) {
  const shown = list.slice(0, 20);
  for (const line of shown) console.log(`  ${line}`);
  if (list.length > shown.length) console.log(`  ... and ${list.length - shown.length} more`);
}

const cases = [];
const disagreements = [];
const unrepresentable = [];

for (const candidate of candidates) {
  if (cases.length >= limit) break;
  const { path, expected } = candidate;

  // check-ignore -v prints one line per path, and a line break in the name would be indistinguishable
  // from a second answer. Such a name is not representable in this corpus.
  if (path.includes('\n') || path.includes('\r')) {
    unrepresentable.push(`${JSON.stringify(path)}: path name contains a line break`);
    continue;
  }

  const answer = checkIgnore(path);
  if (answer.verdict === null) {
    unrepresentable.push(`${path}: ${answer.reason}`);
    continue;
  }
  if (answer.verdict !== expected) {
    disagreements.push(`${path}: ls-files says ${expected}, check-ignore says ${answer.verdict}`);
    continue;
  }

  if (answer.verdict === 'exclude') {
    const source = checkoutGitignore(answer.source);
    if (source === null) {
      unrepresentable.push(
        `${path}: decided by ${answer.source}, not by one of the checkout's .gitignore files`,
      );
      continue;
    }
    const rules = governingRuleFiles(path);
    if (rules.error) {
      unrepresentable.push(`${path}: ${rules.error}`);
      continue;
    }
    const governs = rules.ruleFiles.some(
      (file) => (file.dir === '' ? '.gitignore' : `${file.dir}/.gitignore`) === source,
    );
    if (!governs) {
      unrepresentable.push(`${path}: the deciding rule ${source} does not govern it`);
      continue;
    }
    cases.push({
      name: `git check-ignore: ${path}`,
      ruleFiles: rules.ruleFiles,
      path,
      isDir: isDirectory(path),
      expect: 'exclude',
      source: `${answer.source}:${answer.line}`,
    });
    continue;
  }

  // include: git does not ignore it. A tracked path is included even when a pattern matches it;
  // ask the rule files directly, and skip the case when the index, not the rules, decided it.
  const rulesAnswer = checkIgnore(path, true);
  if (rulesAnswer.verdict === null) {
    unrepresentable.push(`${path}: ${rulesAnswer.reason}`);
    continue;
  }
  if (rulesAnswer.verdict === 'exclude') {
    unrepresentable.push(
      `${path}: tracked, but ${rulesAnswer.source}:${rulesAnswer.line} still matches, ` +
        `so only the index answers include`,
    );
    continue;
  }
  const rules = governingRuleFiles(path);
  if (rules.error) {
    unrepresentable.push(`${path}: ${rules.error}`);
    continue;
  }
  cases.push({
    name: `git tracked: ${path}`,
    ruleFiles: rules.ruleFiles,
    path,
    isDir: isDirectory(path),
    expect: 'include',
  });
}

const document = {
  format: 'gitignore-vectors',
  version: 1,
  generatedBy: 'conformance/from-git-check-ignore.mjs',
  note:
    'Each path was answered by git check-ignore in a real checkout: exclude means a pattern matched, ' +
    'include means git does not ignore it. ruleFiles are the checkout .gitignore files that govern ' +
    'the path. A case carries names and rule text only, never the contents of an ignored file.',
  cases,
};

const outputPath = out ?? join('conformance', `corpus-${basename(root)}.json`);
mkdirSync(dirname(resolve(outputPath)), { recursive: true });
writeFileSync(outputPath, `${JSON.stringify(document, null, 2)}\n`);

const includeCount = cases.filter((entry) => entry.expect === 'include').length;
const excludeCount = cases.length - includeCount;

console.log(
  `from-git-check-ignore: ${cases.length} cases (exclude ${excludeCount}, include ${includeCount})`,
);
console.log(
  `candidates: ${ignoredPaths.length} ignored + ${trackedPaths.length} tracked, limit ${limit}`,
);
console.log(`skipped (check-ignore disagreed with ls-files): ${disagreements.length}`);
describeSkipList(disagreements);
console.log(
  `skipped (not reproducible from the checkout's .gitignore files): ${unrepresentable.length}`,
);
describeSkipList(unrepresentable);
console.log(`wrote ${outputPath}`);
console.log(reportDuration(elapsed(), { what: 'cases generated', detail: `(${cases.length} cases)` }));
