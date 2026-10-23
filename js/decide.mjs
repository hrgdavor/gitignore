#!/usr/bin/env bun
// The JS port's bench CLI: the same contract every port implements, so the runner can time them on identical bytes.
//
//   bun js/decide.mjs --rules <file.gitignore> --paths <file.paths> [--dirs <file>]
//
// One verdict per line on stdout (`include`, `exclude`, `no-opinion`), in input order, and nothing else. The stack is
// built once, which is the part that matters: a port that re-parses the rules per path measures its own mistake.
import { readFileSync } from 'node:fs';

import { parseGitignore, GitIgnoreRules } from './gitignore.mjs';

function usage(message) {
  if (message) console.error(message);
  console.error('usage: decide.mjs --rules <file.gitignore> --paths <file.paths> [--dirs <file>] [--rounds N]');
  process.exit(1);
}

const args = process.argv.slice(2);
let rulesPath = null;
let pathsPath = null;
let dirsPath = null;
let rounds = 1;
for (let index = 0; index < args.length; index += 1) {
  const flag = args[index];
  if (flag === '--rules') rulesPath = args[++index] ?? usage('--rules needs a file');
  else if (flag === '--paths') pathsPath = args[++index] ?? usage('--paths needs a file');
  else if (flag === '--dirs') dirsPath = args[++index] ?? usage('--dirs needs a file');
  else if (flag === '--rounds') rounds = Number(args[++index] ?? '1');
  else usage(`unexpected argument: ${flag}`);
}
if (rulesPath === null || pathsPath === null) usage('--rules and --paths are both required');

const rules = readFileSync(rulesPath, 'utf8');
const paths = readFileSync(pathsPath, 'utf8').split('\n').filter((line) => line.length > 0);
// A directory file may repeat one 0/1 per path, or hold a single flag that applies to all of them.
const flags = dirsPath === null ? null : readFileSync(dirsPath, 'utf8').replace(/\s+/g, '');

const stack = new GitIgnoreRules();
stack.push(parseGitignore('', rules));

// The flags are per path and do not change between rounds, so they are computed once.
const isDirectory = paths.map((_, index) => (flags === null ? false : flags.length === 1 ? flags === '1' : flags[index] === '1'));
const out = [];
for (let round = 0; round < rounds; round += 1) {
  if (round === 0) out.length = 0;
  for (let index = 0; index < paths.length; index += 1) {
    const decision = stack.decide(paths[index], isDirectory[index]);
    if (round === 0) {
      out.push(decision === true ? 'exclude' : decision === false ? 'include' : 'no-opinion');
    }
  }
}
// One write, like a buffered writer: the runner times a process, and a per-line syscall would be the thing it measures.
process.stdout.write(out.join('\n') + '\n');