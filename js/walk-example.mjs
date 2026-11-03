#!/usr/bin/env bun
// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//
// Example: walk a directory tree, print only the files git would consider "ours".
//
//   bun js/walk-example.mjs [root]
//
// Without an argument it walks the current directory. The output is one relative path per line,
// `/`-separated, in directory order.

import { walk } from './walk.mjs';

const root = process.argv[2] ?? '.';

const files = [];
walk(root, (relativePath) => {
  files.push(relativePath);
});

for (const file of files) {
  console.log(file);
}
console.error(`${files.length} files`);
