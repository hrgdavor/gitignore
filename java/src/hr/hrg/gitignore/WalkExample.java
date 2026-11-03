// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//
// Example: walk a directory tree, print only the files git would consider "ours".
//
// Usage: java -cp <classes> hr.hrg.gitignore.WalkExample [root]
//
// Without an argument it walks the current directory. Output is one relative path per line,
// `/`-separated; the count goes to stderr so the file list stays pipeable.
package hr.hrg.gitignore;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

public final class WalkExample {

    private WalkExample() {
    }

    public static void main(String[] args) {
        Path root = Path.of(args.length > 0 ? args[0] : ".");
        List<String> files = new ArrayList<>();
        Walk.walk(root, files::add);
        StringBuilder out = new StringBuilder();
        for (String file : files) {
            out.append(file).append('\n');
        }
        System.out.print(out);
        System.err.println(files.size() + " files");
    }
}
