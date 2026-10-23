#!/usr/bin/env bun
// The JS port against the conformance vectors.
//
//   bun js/conformance.mjs
//
// Each case is materialised in a temporary directory (one `.gitignore` per `ruleFiles` entry, at its directory) and
// answered by the JS port's own stack, shallow file first so a deeper file is consulted first — the order the vectors
// state as behaviour. The three-valued result is mapped to include / exclude / no-opinion, and a mismatch prints the
// case name, the path and both answers.
//
// Exit code 1 when anything disagrees, so this is a gate and not a report.
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';

import { parseGitignore, GitIgnoreRules } from './gitignore.mjs';

const vectors = JSON.parse(readFileSync(new URL('../conformance/gitignore-vectors.json', import.meta.url), 'utf8'));

const results = [];
for (const testCase of vectors.cases) {
  const root = mkdtempSync(join(tmpdir(), 'gitignore-'));
  try {
    // The shallowest rule file first: GitIgnoreRules walks its stack from the top, so the deepest file answers first.
    const files = [...testCase.ruleFiles].sort((left, right) => left.dir.split('/').length - right.dir.split('/').length);
    const rules = new GitIgnoreRules();
    for (const file of files) {
      if (file.dir !== '') mkdirSync(join(root, file.dir), { recursive: true });
      writeFileSync(join(root, file.dir, '.gitignore'), file.rules);
      rules.push(parseGitignore(file.dir, file.rules));
    }

    const decision = rules.decide(testCase.path, testCase.isDir);
    const observed = decision === true ? 'exclude' : decision === false ? 'include' : 'no-opinion';
    results.push({ name: testCase.name, path: testCase.path, expect: testCase.expect, observed, pass: observed === testCase.expect });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

console.log(`\n## JS port vs ${vectors.cases.length} conformance vectors\n`);
console.log('| case | expected | observed | |');
console.log('| ---- | -------- | -------- |-|');
for (const row of results) {
  console.log(`| ${row.name} | ${row.expect} | ${row.observed} | ${row.pass ? 'pass' : '**fail**'} |`);
}

const passed = results.filter((row) => row.pass).length;
console.log(`\n${passed}/${results.length} cases agree`);
if (passed !== results.length) process.exit(1);