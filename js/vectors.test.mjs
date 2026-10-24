#!/usr/bin/env bun
// The 34 conformance vectors as a Bun test, so `bun test` is a real check rather than "No tests found!".
//
// The vectors are the definition of the matcher: every case was checked against git 2.54, and the Zig reference, the JS port
// and the Java port all answer them. `bun js/conformance.mjs` prints the table; this runs the same assertions in the test
// runner a developer types first.
import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { parseGitignore, GitIgnoreRules } from './gitignore.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const vectors = JSON.parse(readFileSync(join(here, '..', 'conformance', 'gitignore-vectors.json'), 'utf8'));

describe('the conformance vectors', () => {
  for (const testCase of vectors.cases) {
    test(testCase.name, () => {
      // Shallowest file first: the stack is consulted from the top, so the deepest file answers first.
      const files = [...testCase.ruleFiles].sort((left, right) => left.dir.split('/').length - right.dir.split('/').length);
      const rules = new GitIgnoreRules();
      for (const file of files) rules.push(parseGitignore(file.dir, file.rules));
      const decision = rules.decide(testCase.path, testCase.isDir);
      const observed = decision === true ? 'exclude' : decision === false ? 'include' : 'no-opinion';
      expect(observed).toBe(testCase.expect);
    });
  }
});
