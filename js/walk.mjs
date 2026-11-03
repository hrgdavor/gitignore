// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//
// A recursive directory walk that respects `.gitignore` files: it lists a tree, reads each directory's
// `.gitignore`, and yields only the files git would consider "ours". A directory that is ignored is not
// entered, which is both git's rule and where the speed comes from — a `node_modules/` with 40,000 files
// costs one directory read and one decision, not 40,000.
//
// This is the utility a project that does not want to depend on `fs-meta` can use to get fast,
// gitignore-aware traversal: pass a callback, get the file paths.
//
//   import { walk } from './walk.mjs';
//   const files = [];
//   walk('src', (relativePath) => files.push(relativePath));
//
// `relativePath` is `/`-separated, relative to the root, no leading slash. Sibling order is the file
// system's; sort if you need a stable order.

import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

import { parseGitignore, GitIgnoreRules, GITIGNORE_FILE_NAME } from './gitignore.mjs';

/** A name that is a repository's own metadata, never project content. */
const DOT_GIT = '.git';

/**
 * Recursively walks `root`, respecting `.gitignore` files in every directory.
 *
 * @param {string} root the directory to walk (absolute or relative).
 * @param {function(string): void} onFile called for every file that is not ignored.
 *   The argument is the file's path relative to `root`, `/`-separated.
 * @param {object} [options]
 * @param {function(string): void} [options.onDir] called for every directory that is not ignored
 *   (before its contents are walked). The argument is the directory's path relative to `root`.
 * @param {boolean} [options.followSymlinks] enter symlinked directories (default `false`). Files that
 *   are symlinks are reported either way, because git tracks a symlink as a file.
 * @param {boolean} [options.skipDotGit] skip a `.git` directory wherever one appears (default `true`).
 */
export function walk(root, onFile, options = {}) {
  const onDir = options.onDir ?? null;
  const followSymlinks = options.followSymlinks ?? false;
  const skipDotGit = options.skipDotGit ?? true;

  const rules = new GitIgnoreRules();
  // The root's rules apply to everything below it. readIgnore returns "" when the directory has none,
  // so the push/pop pairs stay balanced.
  rules.push(parseGitignore('', readIgnore(root)));

  walkDir(root, '', rules, onFile, onDir, followSymlinks, skipDotGit);
}

function walkDir(absDir, relDir, rules, onFile, onDir, followSymlinks, skipDotGit) {
  let entries;
  try {
    entries = readdirSync(absDir, { withFileTypes: true });
  } catch {
    return; // unreadable directory: skip
  }

  for (const entry of entries) {
    if (skipDotGit && entry.name === DOT_GIT) {
      continue;
    }
    const relPath = relDir === '' ? entry.name : `${relDir}/${entry.name}`;

    let isDirectory = entry.isDirectory();
    let isFile = entry.isFile();
    if (entry.isSymbolicLink()) {
      if (followSymlinks) {
        // A symlinked directory is entered only when asked, and the target's kind is what decides.
        try {
          const stat = statSync(join(absDir, entry.name));
          isDirectory = stat.isDirectory();
          isFile = stat.isFile();
        } catch {
          continue; // a dangling link names nothing
        }
      } else {
        // Otherwise the link is reported as a file, which is what git tracks.
        isDirectory = false;
        isFile = true;
      }
    }

    if (isDirectory) {
      // A directory that is ignored is not entered — git's rule, and the prune.
      if (rules.isIgnored(relPath, true)) {
        continue;
      }
      if (onDir !== null) {
        onDir(relPath);
      }
      rules.push(parseGitignore(relPath, readIgnore(join(absDir, entry.name))));
      walkDir(join(absDir, entry.name), relPath, rules, onFile, onDir, followSymlinks, skipDotGit);
      rules.pop();
    } else if (isFile) {
      if (!rules.isIgnored(relPath, false)) {
        onFile(relPath);
      }
    }
  }
}

function readIgnore(directory) {
  try {
    return readFileSync(join(directory, GITIGNORE_FILE_NAME), 'utf8');
  } catch {
    return '';
  }
}
