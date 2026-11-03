#!/usr/bin/env bun
// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//
// `js/walk.mjs` as a Bun test: the utility that turns the matcher into a recursive, gitignore-respecting
// traversal. The cases are the three rules a walk can get wrong — a file is excluded by a suffix rule, an
// ignored directory is not entered (so nothing below it can be re-included), and a nested file re-includes
// what the root excluded.
import { describe, expect, test } from 'bun:test';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { walk } from './walk.mjs';

/** Runs the walk over a materialised tree and returns its files, sorted so the assertions are order-free. */
function filesOf(tree) {
  const root = mkdtempSync(join(tmpdir(), 'gitignore-walk-'));
  try {
    for (const [path, contents] of Object.entries(tree)) {
      const full = join(root, path);
      if (contents === null) {
        mkdirSync(full, { recursive: true });
      } else {
        mkdirSync(join(full, '..'), { recursive: true });
        writeFileSync(full, contents);
      }
    }
    const files = [];
    walk(root, (relativePath) => files.push(relativePath));
    return files.sort();
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

describe('walk', () => {
  test('a suffix rule excludes the matching files', () => {
    expect(filesOf({ '.gitignore': '*.log\n', 'keep.txt': '', 'x.log': '' })).toEqual(['.gitignore', 'keep.txt']);
  });

  test('an ignored directory is not entered, so nothing below it is re-included', () => {
    expect(filesOf({ '.gitignore': 'build/\n', 'build/x.txt': '', 'src/main.zig': '' })).toEqual([
      '.gitignore',
      'src/main.zig',
    ]);
  });

  test('a nested .gitignore re-includes what the root excluded', () => {
    expect(
      filesOf({
        '.gitignore': '*.log\n',
        'src/.gitignore': '!keep.log\n',
        'src/keep.log': '',
        'src/other.log': '',
      }),
    ).toEqual(['.gitignore', 'src/.gitignore', 'src/keep.log']);
  });

  test('a .git directory is skipped by default and reported when asked', () => {
    const tree = { '.gitignore': '', '.git/HEAD': '', 'src/main.zig': '' };
    expect(filesOf(tree)).toEqual(['.gitignore', 'src/main.zig']);

    const root = mkdtempSync(join(tmpdir(), 'gitignore-walk-'));
    try {
      for (const [path, contents] of Object.entries(tree)) {
        const full = join(root, path);
        mkdirSync(join(full, '..'), { recursive: true });
        writeFileSync(full, contents);
      }
      const files = [];
      walk(root, (relativePath) => files.push(relativePath), { skipDotGit: false });
      expect(files.sort()).toEqual(['.git/HEAD', '.gitignore', 'src/main.zig']);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  test('directories are reported before their contents', () => {
    const root = mkdtempSync(join(tmpdir(), 'gitignore-walk-'));
    try {
      mkdirSync(join(root, 'src', 'deep'), { recursive: true });
      writeFileSync(join(root, 'src', 'deep', 'main.zig'), '');
      const seen = [];
      walk(root, (file) => seen.push(`file:${file}`), { onDir: (directory) => seen.push(`dir:${directory}`) });
      expect(seen).toEqual(['dir:src', 'dir:src/deep', 'file:src/deep/main.zig']);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
});
