#!/usr/bin/env bun
// The Java port's gate: compile it with the JDK, run it against the conformance vectors and the ordering vectors, and
// forward the exit code.
//
//   bun java/run.mjs
//
// No Maven and no JUnit: the vectors are JSON, and a runner that needed a build system to say "34/34" would be a second
// project inside this one. The JDK is taken from JAVA_HOME when set, otherwise from PATH, and the version is printed
// first so a failure is not misread as a code problem.
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync } from 'node:fs';
import { join } from 'node:path';

const here = import.meta.dir;
const root = join(here, '..');
const sourceRoot = join(here, 'src');
const out = join(here, 'out');
const vectors = join(root, 'conformance', 'gitignore-vectors.json');

const javac = process.env.JAVA_HOME ? join(process.env.JAVA_HOME, 'bin', process.platform === 'win32' ? 'javac.exe' : 'javac') : 'javac';
const java = process.env.JAVA_HOME ? join(process.env.JAVA_HOME, 'bin', process.platform === 'win32' ? 'java.exe' : 'java') : 'java';

const version = spawnSync(java, ['-version'], { encoding: 'utf8' });
console.log(`java: ${String(version.stderr ?? '').split('\n')[0] || String(version.stdout ?? '').split('\n')[0]}`);

function javaFiles(directory) {
  const found = [];
  for (const entry of readdirSync(directory)) {
    const full = join(directory, entry);
    if (statSync(full).isDirectory()) found.push(...javaFiles(full));
    else if (entry.endsWith('.java')) found.push(full);
  }
  return found;
}

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });

const sources = javaFiles(sourceRoot);
const compile = spawnSync(javac, ['-d', out, ...sources], { stdio: 'inherit' });
if (compile.status !== 0) {
  console.error(`javac failed on ${sources.length} source(s)`);
  process.exit(compile.status ?? 1);
}

if (!existsSync(vectors)) {
  console.error(`missing vectors: ${vectors}`);
  process.exit(1);
}
// Three documents, one runner: `ordering-vectors.json` has the same schema and pins git's last-matching-pattern order
// against the last-segment buckets' candidate classes, and `ancestor-vectors.json` pins the scope of a directory-only
// rule and the excluded-ancestor rule. All three must agree for the gate to pass.
const documents = [
  vectors,
  join(root, 'conformance', 'ordering-vectors.json'),
  join(root, 'conformance', 'ancestor-vectors.json'),
];
let status = 0;
for (const document of documents) {
  if (!existsSync(document)) {
    console.error(`missing vectors: ${document}`);
    process.exit(1);
  }
  console.log(`\n== ${document} ==`);
  const run = spawnSync(java, ['-cp', out, 'hr.hrg.gitignore.Runner', document], { stdio: 'inherit' });
  if (run.status !== 0) status = run.status ?? 1;
}
process.exit(status);
