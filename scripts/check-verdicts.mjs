#!/usr/bin/env bun
/**
 * The three implementations must print the same bytes, on the real workloads.
 *
 *   bun scripts/check-verdicts.mjs          one line per workload, then a summary
 *   bun scripts/check-verdicts.mjs --json   one JSON object per workload (NDJSON), no prose
 *
 * The 34 conformance vectors are the contract for *cases*; they are not the workload. Several times a
 * change here was verified by "the vectors still pass" while the verdict stream on `bench/perf.mjs`'s
 * six workloads had silently changed. The comparison that would have caught it was made by hand in
 * `.tmp/` and never committed. This file is that comparison, committed and repeatable.
 *
 * What it does:
 *
 *   1. Generates the six workloads with `bun bench/perf.mjs --emit` (the generators are not copied
 *      here; the runner's own contract is the source of the inputs).
 *   2. Runs the Zig reference (`zig build` output), the JS port (`bun js/decide.mjs`) and the Java port
 *      (`java -cp java/out hr.hrg.gitignore.Decide`) over every workload.
 *   3. Compares the stdout bytes pairwise. A verdict count is printed per workload; the first differing
 *      line names the workload, the path and the two values.
 *
 * The Java port is the slow starter, and there is no sleep or retry here: every port is a plain child
 * process whose exit is the readiness signal, exactly as `bench/perf.mjs` and `java/run.mjs` treat it.
 * Capturing stdout through pipes also keeps JVM start-up chatter off the comparison.
 *
 * A missing port is a failure, never a skip: the message says which artifact is missing and how to
 * build it (`zig build`, `bun java/run.mjs`). Java is compiled with `javac` into `.tmp/check-verdicts/`
 * when `java/out` is absent or older than `java/src`, using the same JDK resolution and source walk as
 * `java/run.mjs`; `java/out` itself is never written to. A stream that agrees with the other two but
 * has fewer lines than the workload has paths is a failure too: agreement on a truncated answer list is
 * not agreement on the answers.
 *
 * Exit codes: 0 all workloads agree; 1 a port failed or the streams differ; 2 a prerequisite (workload
 * generation, Zig binary, JDK) is missing. `--json` consumers should trust the exit code for the
 * overall result and read `counts`, `verdicts` and `agree` from each object.
 */
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync } from 'node:fs';
import { join, relative, resolve, sep } from 'node:path';
import { spawnSync } from 'node:child_process';

const root = resolve(import.meta.dir, '..');
const workDir = join(root, '.tmp', 'check-verdicts');

const argv = process.argv.slice(2);
if (argv.includes('--help') || argv.includes('-h')) {
  console.log('usage: bun scripts/check-verdicts.mjs [--json]');
  process.exit(0);
}
const unknown = argv.filter((argument) => argument !== '--json');
if (unknown.length > 0) {
  console.error(`check-verdicts: unexpected argument: ${unknown[0]}`);
  console.error('usage: bun scripts/check-verdicts.mjs [--json]');
  process.exit(2);
}
const jsonMode = argv.includes('--json');

/** A path relative to the repository root, with `/` separators in messages on every platform. */
function shown(path) {
  const relativePath = relative(root, path);
  return (relativePath === '' ? '.' : relativePath).split(sep).join('/');
}

/** A prerequisite is missing: say which and how to build it, then exit 2. Never a skip. */
function prerequisite(lines) {
  for (const line of lines) console.error(line);
  process.exit(2);
}

/** Progress/context in human mode; stderr in --json mode so stdout stays pure NDJSON. */
function note(message) {
  if (jsonMode) console.error(message);
  else console.log(message);
}

const win = process.platform === 'win32';
const exeSuffix = win ? '.exe' : '';

// --- the ports -----------------------------------------------------------------------------------

const ports = [];

const zigBinary = join(root, 'zig-out', 'bin', `ignore-decide${exeSuffix}`);
if (!existsSync(zigBinary)) {
  prerequisite([
    `check-verdicts: missing Zig reference binary: ${shown(zigBinary)}`,
    '  build it with: zig build',
  ]);
}
ports.push({ name: 'zig', command: zigBinary, args: [] });

const jsEntry = join(root, 'js', 'decide.mjs');
if (!existsSync(jsEntry)) {
  prerequisite([
    `check-verdicts: missing JS port CLI: ${shown(jsEntry)}`,
    '  js/decide.mjs is committed source; restore it (the JS port needs no build step)',
  ]);
}
// The Bun that is running this check, not whatever `bun` a shell happens to resolve first.
ports.push({ name: 'js', command: process.execPath, args: [jsEntry] });

const javaHome = process.env.JAVA_HOME;
const javaCommand = javaHome ? join(javaHome, 'bin', `java${exeSuffix}`) : 'java';
const javacCommand = javaHome ? join(javaHome, 'bin', `javac${exeSuffix}`) : 'javac';
if (javaHome && !existsSync(javaCommand)) {
  prerequisite([
    `check-verdicts: JAVA_HOME is set but ${javaCommand} does not exist`,
    '  point JAVA_HOME at JDK 25 (java/run.mjs resolves the JDK the same way)',
    '  or build the Java port with: bun java/run.mjs',
  ]);
}

/** Every `*.java` below a directory, as `java/run.mjs` collects them. */
function javaFiles(directory) {
  if (!existsSync(directory)) return [];
  const found = [];
  for (const entry of readdirSync(directory).sort()) {
    const full = join(directory, entry);
    if (statSync(full).isDirectory()) found.push(...javaFiles(full));
    else if (entry.endsWith('.java')) found.push(full);
  }
  return found;
}

const javaSources = javaFiles(join(root, 'java', 'src'));
const prebuiltClasses = join(root, 'java', 'out');
const prebuiltDecide = join(prebuiltClasses, 'hr', 'hrg', 'gitignore', 'Decide.class');
let javaClasses = null;
if (existsSync(prebuiltDecide)) {
  const newestSource = javaSources.reduce((newest, source) => Math.max(newest, statSync(source).mtimeMs), 0);
  if (newestSource <= statSync(prebuiltDecide).mtimeMs) {
    javaClasses = prebuiltClasses;
  }
}
if (javaClasses === null) {
  if (javaSources.length === 0) {
    prerequisite([
      `check-verdicts: missing Java port classes: ${shown(prebuiltDecide)}`,
      '  build the Java port with: bun java/run.mjs',
    ]);
  }
  const scratchClasses = join(workDir, 'java-classes');
  rmSync(scratchClasses, { recursive: true, force: true });
  mkdirSync(scratchClasses, { recursive: true });
  const compile = spawnSync(javacCommand, ['-d', scratchClasses, ...javaSources], { cwd: root, encoding: 'utf8' });
  if (compile.error?.code === 'ENOENT') {
    prerequisite([
      `check-verdicts: javac not found (${javacCommand}); cannot compile the Java port from ${shown(join(root, 'java', 'src'))}`,
      '  set JAVA_HOME to JDK 25, or build the Java port with: bun java/run.mjs',
    ]);
  }
  if (compile.status !== 0) {
    const lines = String(compile.stderr ?? '').trim().split('\n').filter(Boolean).slice(0, 8);
    prerequisite([
      `check-verdicts: javac failed on ${javaSources.length} Java source(s)`,
      ...lines.map((line) => `  ${line}`),
      '  build the Java port with: bun java/run.mjs',
    ]);
  }
  javaClasses = scratchClasses;
  note(
    `java: ${shown(prebuiltDecide)} is missing or older than java/src; compiled java/src into ${shown(scratchClasses)}` +
      ' (bun java/run.mjs builds java/out)',
  );
}
/** The major release from `java -version` output, or null when the vendor's wording is unrecognised. */
function javaMajorVersion(output) {
  const match = /version "(\d+)(?:\.(\d+))?/.exec(output);
  if (match === null) return null;
  return match[1] === '1' ? Number(match[2] ?? 0) : Number(match[1]);
}

/** The class-file major version (Java 25 is 69), read from the `Decide.class` that will be run. */
function classFileMajor(path) {
  try {
    const header = readFileSync(path);
    return header.length >= 8 ? header.readUInt16BE(6) : null;
  } catch {
    return null;
  }
}

// `java/run.mjs` prints `java -version` before it does anything, and so does this check: an unset
// JAVA_HOME that resolves to an old `java` on PATH must be one actionable failure, not six
// UnsupportedClassVersionError stack traces. The class file being run says which release it needs.
const javaProbe = spawnSync(javaCommand, ['-version'], { encoding: 'utf8' });
if (javaProbe.error || javaProbe.status !== 0) {
  prerequisite([
    `check-verdicts: missing Java runtime: ${javaHome === undefined ? '"java"' : javaCommand} did not start` +
      ` (JAVA_HOME=${javaHome ?? '(unset)'})`,
    '  set JAVA_HOME to JDK 25 (java/run.mjs resolves the JDK the same way)',
    '  or build the Java port with: bun java/run.mjs',
  ]);
}
const runtimeMajor = javaMajorVersion(`${javaProbe.stderr ?? ''}\n${javaProbe.stdout ?? ''}`);
const requiredClassMajor = classFileMajor(join(javaClasses, 'hr', 'hrg', 'gitignore', 'Decide.class'));
if (runtimeMajor !== null && requiredClassMajor !== null && requiredClassMajor > runtimeMajor + 44) {
  prerequisite([
    `check-verdicts: ${shown(javaClasses)} was compiled for Java ${requiredClassMajor - 44}` +
      ` (class file ${requiredClassMajor}), but \`java\` is Java ${runtimeMajor}` +
      ` (JAVA_HOME=${javaHome ?? '(unset)'})`,
    '  set JAVA_HOME to JDK 25 (java/run.mjs resolves the JDK the same way)',
    '  or rebuild java/out with: bun java/run.mjs',
  ]);
}
ports.push({ name: 'java', command: javaCommand, args: ['-cp', javaClasses, 'hr.hrg.gitignore.Decide'] });

/** How a port is named in the human output. */
function describePort(port) {
  if (port.name === 'zig') return shown(port.command);
  if (port.name === 'js') return `bun ${shown(port.args[0])}`;
  return `java -cp ${shown(port.args[1])} ${port.args[2]}`;
}

// --- the workloads -------------------------------------------------------------------------------

mkdirSync(workDir, { recursive: true });
const emit = spawnSync(process.execPath, [join(root, 'bench', 'perf.mjs'), '--emit'], {
  cwd: root,
  encoding: 'utf8',
  maxBuffer: 64 * 1024 * 1024,
});
if (emit.error || emit.status !== 0) {
  prerequisite([
    `check-verdicts: could not generate the workloads with bun bench/perf.mjs --emit`,
    ...(emit.error ? [`  ${emit.error.message}`] : []),
    ...String(emit.stderr ?? '').trim().split('\n').filter(Boolean).slice(0, 8).map((line) => `  ${line}`),
  ]);
}

const workloads = [];
for (const line of String(emit.stdout ?? '').split('\n')) {
  const match = /^(\S+)\s+(\d+) rules\s+(\d+) paths$/.exec(line.trim());
  if (!match) continue;
  const name = match[1];
  const rulesPath = join(root, '.tmp', 'workloads', `${name}.gitignore`);
  const pathsPath = join(root, '.tmp', 'workloads', `${name}.paths`);
  if (!existsSync(rulesPath) || !existsSync(pathsPath)) {
    prerequisite([
      `check-verdicts: bench/perf.mjs reported workload "${name}" but did not write its inputs`,
      `  expected: ${shown(rulesPath)} and ${shown(pathsPath)}`,
    ]);
  }
  const pathCount = readFileSync(pathsPath, 'utf8').split('\n').filter((entry) => entry.length > 0).length;
  if (pathCount !== Number(match[3])) {
    prerequisite([
      `check-verdicts: workload "${name}" has ${pathCount} paths but bench/perf.mjs announced ${match[3]}`,
    ]);
  }
  workloads.push({ name, rulesPath, pathsPath, pathCount });
}
if (workloads.length === 0) {
  prerequisite(['check-verdicts: bench/perf.mjs --emit printed no workload lines']);
}

if (!jsonMode) {
  console.log('ports:');
  for (const port of ports) console.log(`  ${port.name.padEnd(4)} ${describePort(port)}`);
  const totalPaths = workloads.reduce((total, workload) => total + workload.pathCount, 0);
  console.log(`workloads: ${workloads.length} (${totalPaths} paths) from ${shown(join(root, '.tmp', 'workloads'))}`);
  console.log('');
}

// --- run, compare, report -----------------------------------------------------------------------

/** The number of verdict lines in a stream, counted as `bench/perf.mjs` counts them. */
function countVerdicts(buffer) {
  if (buffer.length === 0) return 0;
  return buffer.toString('utf8').split('\n').filter((line) => line.length > 0).length;
}

/** The 1-based line the byte at `offset` belongs to (or would start). */
function lineNumberAt(buffer, offset) {
  let line = 1;
  for (let index = 0; index < offset && index < buffer.length; index += 1) {
    if (buffer[index] === 0x0a) line += 1;
  }
  return line;
}

/** The text of the line containing (or starting at) `offset`; `<end of stream>` when short. */
function lineTextAt(buffer, offset) {
  if (offset >= buffer.length) return '<end of stream>';
  let start = offset;
  while (start > 0 && buffer[start - 1] !== 0x0a) start -= 1;
  let end = offset;
  while (end < buffer.length && buffer[end] !== 0x0a) end += 1;
  return buffer.subarray(start, end).toString('utf8').replace(/\r$/, '');
}

/**
 * The first byte two verdict streams do not share. Byte equality is the contract: a port that prints
 * `include` where another prints `exclude` has failed, and so has one that prints an extra newline.
 */
function firstDifference(left, right) {
  const limit = Math.min(left.length, right.length);
  let offset = 0;
  while (offset < limit && left[offset] === right[offset]) offset += 1;
  if (offset === left.length && offset === right.length) return null;
  return {
    offset,
    line: lineNumberAt(left, offset),
    left: lineTextAt(left, offset),
    right: lineTextAt(right, offset),
  };
}

/** The input path a differing line answers, for the failure message. */
function pathAtLine(workload, line) {
  const paths = readFileSync(workload.pathsPath, 'utf8').split('\n');
  const path = paths[line - 1];
  return path === undefined || path.length === 0 ? null : path.replace(/\r$/, '');
}

let disagreements = 0;
let agreedVerdicts = 0;

for (const workload of workloads) {
  const streams = new Map();
  const counts = new Map();
  const errors = new Map();

  for (const port of ports) {
    const run = spawnSync(port.command, [...port.args, '--rules', workload.rulesPath, '--paths', workload.pathsPath], {
      cwd: root,
      maxBuffer: 64 * 1024 * 1024,
    });
    if (run.error) {
      errors.set(port.name, `could not start (${run.error.code ?? run.error.message})`);
      counts.set(port.name, null);
      continue;
    }
    if (run.status !== 0) {
      const stderr = String(run.stderr ?? '').trim();
      const last = stderr === '' ? '' : stderr.split('\n').at(-1);
      errors.set(port.name, `exited ${run.status}${last === '' ? '' : `: ${last}`}`);
      counts.set(port.name, null);
      continue;
    }
    const stdout = Buffer.isBuffer(run.stdout) ? run.stdout : Buffer.from(run.stdout ?? '');
    streams.set(port.name, stdout);
    counts.set(port.name, countVerdicts(stdout));
  }

  // Pairwise, so the reported difference is the earliest byte any two ports disagree on, not merely
  // the first one this loop happened to reach.
  let difference = null;
  if (errors.size === 0) {
    for (let leftIndex = 0; leftIndex < ports.length; leftIndex += 1) {
      for (let rightIndex = leftIndex + 1; rightIndex < ports.length; rightIndex += 1) {
        const left = ports[leftIndex].name;
        const right = ports[rightIndex].name;
        const found = firstDifference(streams.get(left), streams.get(right));
        if (found === null) continue;
        if (difference === null || found.offset < difference.offset) {
          difference = { ...found, leftPort: left, rightPort: right };
        }
      }
    }
  }

  // The bench contract is one verdict per path. Three ports can agree byte-for-byte on a truncated
  // answer list, so the count is checked against the workload before agreement is reported.
  let countMismatch = null;
  if (errors.size === 0) {
    for (const port of ports) {
      const actual = counts.get(port.name);
      if (actual !== workload.pathCount) {
        countMismatch = { port: port.name, actual, expected: workload.pathCount };
        break;
      }
    }
  }

  const agree = errors.size === 0 && difference === null && countMismatch === null;
  if (!agree) disagreements += 1;
  else agreedVerdicts += workload.pathCount;

  const countsObject = Object.fromEntries(ports.map((port) => [port.name, counts.get(port.name) ?? null]));
  const countsText = ports.map((port) => `${port.name}=${counts.get(port.name) ?? 'failed'}`).join(' ');

  if (jsonMode) {
    const record = {
      workload: workload.name,
      expected: workload.pathCount,
      counts: countsObject,
      verdicts: agree ? workload.pathCount : null,
      agree,
    };
    if (errors.size > 0) {
      const [port, message] = errors.entries().next().value;
      record.error = `${port} ${message}`;
    } else if (countMismatch !== null) {
      record.error =
        `${countMismatch.port} printed ${countMismatch.actual} verdicts, expected ${countMismatch.expected}`;
    }
    if (difference !== null) {
      const path = pathAtLine(workload, difference.line);
      record.firstDifference = {
        line: difference.line,
        byte: difference.offset,
        path,
        ports: [difference.leftPort, difference.rightPort],
        [difference.leftPort]: difference.left,
        [difference.rightPort]: difference.right,
      };
    }
    console.log(JSON.stringify(record));
  } else if (agree) {
    console.log(
      `ok   ${workload.name.padEnd(11)} ${String(workload.pathCount).padStart(5)} verdicts  ` +
        `identical across ${ports.map((port) => port.name).join(', ')}`,
    );
  } else if (errors.size > 0) {
    const [port, message] = errors.entries().next().value;
    console.log(`FAIL ${workload.name}: ${port} ${message}; counts ${countsText}`);
  } else if (countMismatch !== null) {
    console.log(
      `FAIL ${workload.name}: ${countMismatch.port} printed ${countMismatch.actual} verdicts, ` +
        `expected ${countMismatch.expected}; counts ${countsText}`,
    );
  } else {
    const path = pathAtLine(workload, difference.line);
    console.log(
      `FAIL ${workload.name}: first difference at line ${difference.line}` +
        `${path === null ? '' : ` (path ${path})`}: ` +
        `${difference.leftPort}="${difference.left}" vs ${difference.rightPort}="${difference.right}" ` +
        `(byte ${difference.offset}; counts ${countsText})`,
    );
  }
}

const passed = workloads.length - disagreements;
if (disagreements === 0) {
  if (!jsonMode) {
    console.log(`summary: ${passed}/${workloads.length} workloads agree; ${agreedVerdicts} verdicts byte-identical across ${ports.length} ports`);
  }
} else {
  if (!jsonMode) {
    console.log(`summary: ${passed}/${workloads.length} workloads agree; ${disagreements} disagree`);
  }
  process.exitCode = 1;
}
