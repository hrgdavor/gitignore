// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.gitignore;

import java.io.IOException;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.function.Consumer;

/**
 * A recursive directory walk that respects {@code .gitignore} files: it lists a tree, reads each
 * directory's {@code .gitignore}, and yields only the files git would consider "ours". A directory that
 * is ignored is not entered, which is both git's rule and where the speed comes from — a
 * {@code node_modules/} with 40,000 files costs one directory read and one decision, not 40,000.
 *
 * <p>This is the utility a project that does not want to depend on {@code fs-meta} can use to get fast,
 * gitignore-aware traversal:</p>
 *
 * <pre>{@code
 * List<String> files = new ArrayList<>();
 * Walk.walk(Path.of("src"), files::add);
 * }</pre>
 *
 * <p>Each path handed to the callback is {@code /}-separated, relative to the root, and has no leading
 * slash. Sibling order is the file system's; sort if you need a stable order.</p>
 */
public final class Walk {

    /** How the walk treats symlinks and repository metadata. */
    public record Options(boolean followSymlinks, boolean skipDotGit) {
        /** Files that are symlinks are still reported (git tracks them as files); {@code .git} is skipped. */
        public static final Options DEFAULT = new Options(false, true);
    }

    private Walk() {
    }

    /**
     * Recursively walks {@code root}, respecting {@code .gitignore} files in every directory.
     *
     * @param root the directory to walk.
     * @param onFile called for every file that is not ignored; receives the file's path relative to
     *     {@code root}, {@code /}-separated.
     */
    public static void walk(Path root, Consumer<String> onFile) {
        walk(root, onFile, null, Options.DEFAULT);
    }

    /**
     * Recursively walks {@code root}, also reporting the directories it enters.
     *
     * @param root the directory to walk.
     * @param onFile called for every file that is not ignored.
     * @param onDir called for every directory that is not ignored, before its contents are walked;
     *     {@code null} to skip. The root itself is not reported.
     */
    public static void walk(Path root, Consumer<String> onFile, Consumer<String> onDir) {
        walk(root, onFile, onDir, Options.DEFAULT);
    }

    /**
     * Recursively walks {@code root} with explicit options.
     *
     * @param root the directory to walk.
     * @param onFile called for every file that is not ignored.
     * @param onDir called for every directory that is not ignored; {@code null} to skip.
     * @param options how symlinks and {@code .git} are treated.
     */
    public static void walk(Path root, Consumer<String> onFile, Consumer<String> onDir, Options options) {
        GitIgnoreRules rules = new GitIgnoreRules();
        // The root's rules apply to everything below it. readOrEmpty keeps the push/pop pairs balanced
        // whether or not a directory has a .gitignore.
        rules.push(readOrEmpty(root, ""));
        walkDir(root, "", rules, onFile, onDir, options);
    }

    private static void walkDir(Path absDir, String relDir, GitIgnoreRules rules,
                                Consumer<String> onFile, Consumer<String> onDir, Options options) {
        try (DirectoryStream<Path> stream = Files.newDirectoryStream(absDir)) {
            for (Path entry : stream) {
                String name = entry.getFileName().toString();
                if (options.skipDotGit() && name.equals(".git")) {
                    continue;
                }
                String relPath = relDir.isEmpty() ? name : relDir + "/" + name;

                boolean isDirectory = Files.isDirectory(entry);
                boolean isFile = Files.isRegularFile(entry);
                if (Files.isSymbolicLink(entry)) {
                    if (options.followSymlinks()) {
                        // The target's kind decides; a dangling link names nothing and is skipped.
                        isDirectory = Files.isDirectory(entry);
                        isFile = Files.isRegularFile(entry);
                    } else {
                        // The link is reported as a file, which is what git tracks.
                        isDirectory = false;
                        isFile = true;
                    }
                }

                if (isDirectory) {
                    // A directory that is ignored is not entered — git's rule, and the prune.
                    if (rules.isIgnored(relPath, true)) {
                        continue;
                    }
                    if (onDir != null) {
                        onDir.accept(relPath);
                    }
                    rules.push(readOrEmpty(entry, relPath));
                    walkDir(entry, relPath, rules, onFile, onDir, options);
                    rules.pop();
                } else if (isFile) {
                    if (!rules.isIgnored(relPath, false)) {
                        onFile.accept(relPath);
                    }
                }
            }
        } catch (IOException e) {
            // Unreadable directory: skip. A walk that cannot list a directory cannot say what is in it,
            // and failing the whole traversal for one permission bit is worse than an incomplete answer.
        }
    }

    private static GitIgnoreFile readOrEmpty(Path directory, String relativeDirectory) {
        try {
            return GitIgnoreFile.readOrEmpty(directory, relativeDirectory);
        } catch (IOException e) {
            return GitIgnoreFile.parse(relativeDirectory, "");
        }
    }
}
