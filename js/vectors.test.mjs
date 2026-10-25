#!/usr/bin/env bun
// The conformance and ordering vectors as a Bun test, so `bun test` is a real check rather than "No tests found!".
//
// `gitignore-vectors.json` is the definition of the matcher: every case was checked against git 2.54, and the Zig
// reference, the JS port and the Java port all answer them. `ordering-vectors.json` is the second, separate
// document: it pins git's last-matching-pattern order against the last-segment buckets' candidate classes, and its
// deciding rule was checked with `git check-ignore -v` too. `bun js/conformance.mjs` prints the first table; this
// runs the same assertions in the test runner a developer types first.
import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { parseGitignore, GitIgnoreRules } from './gitignore.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const documents = [
  ['the conformance vectors', 'gitignore-vectors.json'],
  ['the ordering vectors', 'ordering-vectors.json'],
];

/** The three-value answer of one case, through a fresh stack of its rule files. */
function answer(testCase) {
  // Shallowest file first: the stack is consulted from the top, so the deepest file answers first.
  const files = [...testCase.ruleFiles].sort((left, right) => left.dir.split('/').length - right.dir.split('/').length);
  const rules = new GitIgnoreRules();
  for (const file of files) rules.push(parseGitignore(file.dir, file.rules));
  const decision = rules.decide(testCase.path, testCase.isDir);
  return decision === true ? 'exclude' : decision === false ? 'include' : 'no-opinion';
}

for (const [description, name] of documents) {
  const vectors = JSON.parse(readFileSync(join(here, '..', 'conformance', name), 'utf8'));
  describe(description, () => {
    for (const testCase of vectors.cases) {
      test(testCase.name, () => {
        expect(answer(testCase)).toBe(testCase.expect);
      });
    }
  });
}
