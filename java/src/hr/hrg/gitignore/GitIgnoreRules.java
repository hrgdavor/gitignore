// The Java port of the .gitignore matcher.
//
// Moved here from `fs-meta/src/main/java/hr/hrg/fsmeta` because the matcher is this project's subject and it was
// living inside its consumer. `Runner` decides its correctness against `conformance/gitignore-vectors.json`, where the
// Zig implementation is the reference.
//// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
package hr.hrg.gitignore;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/**
 * The {@code .gitignore} files that apply at one point of a walk — git's precedence, in a stack.
 *
 * <p>A walk pushes a directory's {@code .gitignore} when it enters the directory and pops it when it
 * leaves, so the stack at any moment is exactly the set of files that govern the path being visited. The
 * decision rule is git's: the <strong>deepest</strong> file that has an opinion wins, and within one file
 * the <strong>last</strong> matching pattern wins — which is what makes a nested {@code !keep.tmp} able to
 * re-include a file that an outer {@code *.tmp} excluded.</p>
 *
 * <p>{@link #isIgnored} answers "would git call this not ours?", and it is the question the scanner asks
 * before it descends into a directory. A directory that is ignored is <strong>not entered</strong>, which is
 * both git's rule — a file inside an excluded directory cannot be re-included — and where the speed of a
 * real {@code .gitignore}-driven walk comes from.</p>
 */
public final class GitIgnoreRules {

    private final List<GitIgnoreFile> stack = new ArrayList<>();
    /**
     * A directory's state, keyed by its path relative to the walk root.
     *
     * <p>A path list asks the same directory over and over — the {@code backtrack} workload asks about 84,000 ancestor
     * directories that are 42 distinct ones, and each ask used to re-run the whole matcher against a 43-segment path.
     * The state is the two facts a decision needs about the path's directory: whether it (or an ancestor) is excluded,
     * and — implicit here — the chain of files that governs it. The chain half is already free in this port because
     * the walk hands the stack to the decider instead of making it walk up the file system, so the cache pays for the
     * ancestor half: one map lookup and one {@code dirname} per decision instead of a lookup and a substring per
     * level.</p>
     *
     * <p>The rules are a snapshot, so the state cannot change while the stack is unchanged; {@link #push} and
     * {@link #pop} clear it because they are the only things that change which files govern a directory, and a cached
     * answer must never outlive them.</p>
     */
    private final Map<String, DirState> dirStates = new HashMap<>();
    /** The pre-index walk, used only for a path the index does not key on. */
    private final Map<String, Boolean> excludedDirectories = new HashMap<>();

    /** What a decision needs to know about a directory: whether it or an ancestor is excluded. */
    private record DirState(boolean ancestorExcluded) {
    }

    /** Enters a directory: its rules (an empty file when it has none) apply from here on. */
    public void push(GitIgnoreFile file) {
        stack.add(file);
        dirStates.clear();
        excludedDirectories.clear();
    }

    /** Leaves the directory most recently pushed. */
    public void pop() {
        if (!stack.isEmpty()) {
            stack.remove(stack.size() - 1);
        }
        dirStates.clear();
        excludedDirectories.clear();
    }

    /** How many {@code .gitignore} files currently apply — the walk's depth, for a test or a diagnostic. */
    public int depth() {
        return stack.size();
    }

    /**
     * The decision the deepest applicable {@code .gitignore} makes about a path relative to the walk root.
     *
     * @return empty when no file has an opinion, which is not the same as "included": an outer file may
     *         still exclude it — the stack is consulted deepest first precisely so that is a decision and
     *         not an accident
     */
    public Optional<Boolean> decide(String relativePath, boolean isDirectory) {
        Optional<Boolean> direct = decideDirect(relativePath, isDirectory);
        if (direct.isPresent() && direct.get()) {
            // A directly excluded path needs no ancestor fact at all — the common case on a rule set with a literal hit.
            return direct;
        }
        int slash = relativePath.lastIndexOf('/');
        // The index keys on the directory, and the directory is the substring before the last separator for every path
        // in the contract (`/`-separated, no leading or trailing separator). A path outside it keeps the historical
        // answer rather than being answered from an index built on a different key.
        if (slash == 0 || slash == relativePath.length() - 1) {
            return walkAncestors(relativePath, direct);
        }
        String directory = slash < 0 ? "" : relativePath.substring(0, slash);
        if (stateFor(directory).ancestorExcluded()) {
            return Optional.of(true);
        }
        return direct;
    }

    /**
     * The ancestor-excluded fact for a directory, inherited: a directory is excluded when its parent is, or when its
     * own decision through the stack excludes it — exactly the prefix set the per-path walk asked, computed once per
     * directory instead of once per path per level.
     */
    private DirState stateFor(String directory) {
        DirState state = dirStates.get(directory);
        if (state != null) {
            return state;
        }
        boolean ancestorExcluded = false;
        if (!directory.isEmpty()) {
            int slash = directory.lastIndexOf('/');
            DirState parent = stateFor(slash < 0 ? "" : directory.substring(0, slash));
            Optional<Boolean> decision = decideDirect(directory, true);
            ancestorExcluded = parent.ancestorExcluded() || (decision.isPresent() && decision.get());
        }
        state = new DirState(ancestorExcluded);
        dirStates.put(directory, state);
        return state;
    }

    /** The pre-index ancestor walk, used only for a path the index does not key on. */
    private Optional<Boolean> walkAncestors(String relativePath, Optional<Boolean> direct) {
        int slash = relativePath.lastIndexOf('/');
        while (slash > 0) {
            String ancestor = relativePath.substring(0, slash);
            Boolean excluded = excludedDirectories.get(ancestor);
            if (excluded == null) {
                Optional<Boolean> decision = decideDirect(ancestor, true);
                excluded = decision.isPresent() && decision.get();
                excludedDirectories.put(ancestor, excluded);
            }
            if (excluded) {
                return Optional.of(true);
            }
            slash = relativePath.lastIndexOf('/', slash - 1);
        }
        return direct;
    }

    /** What the rules say about this exact path, ignoring its ancestors. */
    private Optional<Boolean> decideDirect(String relativePath, boolean isDirectory) {
        for (int index = stack.size() - 1; index >= 0; index--) {
            Optional<Boolean> decision = stack.get(index).decide(relativePath, isDirectory);
            if (decision.isPresent()) {
                return decision;
            }
        }
        return Optional.empty();
    }

    /** Whether the deepest applicable {@code .gitignore} excludes the path. */
    public boolean isIgnored(String relativePath, boolean isDirectory) {
        return decide(relativePath, isDirectory).orElse(false);
    }
}
