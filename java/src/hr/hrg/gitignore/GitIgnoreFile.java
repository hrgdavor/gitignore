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
import java.util.regex.Pattern;

/**
 * One {@code .gitignore} file's patterns, parsed once and matched the way {@code git} matches them.
 *
 * <p>This is deliberately not "a glob library". A trio describes the files a project considers ours, and
 * the definition of "not ours" in this repository — and in every project that would use {@code fs-meta} —
 * is a {@code .gitignore} file, read per directory (the reasoning is DEC-044's: a hand-written skip list is
 * a promise somebody has to remember to keep). So the semantics below are git's, and the shared vectors in
 * {@code conformance/gitignore-vectors.json} pin them so that the Java, Bun and (later) Zig walks agree
 * file for file.</p>
 *
 * <h3>The rules that are easy to get wrong, and are the reason this class is tested</h3>
 * <ul>
 *   <li><strong>Scope.</strong> A file's patterns apply only to paths <em>below</em> the directory that
 *       holds it; a path that is not under {@link #relativeDirectory()} can never match. That is also why a
 *       directory's own {@code .gitignore} cannot exclude the directory itself.</li>
 *   <li><strong>Anchoring.</strong> A pattern with a separator at the start or in the middle is relative to
 *       the {@code .gitignore}'s own directory; otherwise it matches at any depth (a basename match).</li>
 *   <li><strong>The last matching pattern wins</strong>, so {@code !keep.log} after {@code *.log}
 *       re-includes. Deeper files beat shallower ones — that is {@link GitIgnoreRules}' job, not this
 *       class's.</li>
 *   <li><strong>A trailing slash means directories only</strong>, and git also reports a file inside such a
 *       directory as ignored — which is what makes pruning a directory equivalent to ignoring everything
 *       below it.</li>
 *   <li><strong>Negation cannot resurrect a file inside an ignored directory</strong>, because the walk never
 *       enters it. {@link GitIgnoreRules} and the scanner state that as a rule rather than leaving it to be
 *       discovered.</li>
 * </ul>
 *
 * <p>Matching is <strong>case-sensitive</strong> on every platform, which is a deliberate choice over git's
 * {@code core.ignorecase} behaviour: a trio is written on one machine and read on another, and the ports
 * must agree with each other before they agree with a particular file system. The vectors pin it.</p>
 */
public final class GitIgnoreFile {

    /** The file name a walk reads per directory. */
    public static final String FILE_NAME = ".gitignore";

    private final String relativeDirectory;
    private final List<Rule> rules;
    /**
     * Directory-only literal rules, indexed instead of scanned — they are the class a per-path decision asks about
     * most, and the one whose scan costs a prefix walk per rule.
     *
     * <p>Two forms, because the question differs: an anchored literal is a whole path prefix
     * ({@code module0/src/main/java/}), so it is keyed by that path and looked up once per depth the path has; an
     * unanchored one is a single name ({@code build/}), so it is keyed by the name and looked up once per segment. A
     * literal can only match a prefix of exactly its own depth, which is what {@link #anchoredDepths} preserves:
     * {@code java/fory-0/...} is rejected against a {@code java/fory-1/...} rule by the lookup itself, the case a
     * first-segment prune cannot see. The reference has a {@code u256} mask; a plain array is the Java equivalent and
     * a pattern deeper than {@link #MAX_INDEXED_DEPTH} stays on the scanned path, where the answer is still correct.
     *
     * <p>Keys are the highest rule position for that literal, so a later rule overrides an earlier one, exactly as
     * the scanned list's reverse iteration would.
     */
    private final Map<String, Integer> anchoredLiterals;
    private final Map<String, Integer> unanchoredLiterals;
    /** The unanchored literals as parallel arrays, so a small set is scanned without a map lookup per segment. */
    private final String[] unanchoredNames;
    private final int[] unanchoredRules;
    private final boolean[] anchoredDepths;
    private final int deepestAnchoredDepth;
    /**
     * Non-directory-only rules whose last segment is exactly literal ({@code build.gradle}, {@code src/**}{@code /target}),
     * keyed by that segment. Each value is every rule position with that tail, ascending — the caller walks it
     * downwards, so the first match is the last matching pattern of that bucket, and a later general rule still wins
     * because the scan above {@code best} is what decides.
     *
     * <p>This is the file-side counterpart of {@link #anchoredLiterals}: that index is keyed by a whole directory
     * prefix, so it cannot help a rule that names a file. A path whose base name differs cannot match one of these
     * rules at all, which is one lookup instead of a whole-path comparison per rule.</p>
     */
    private final Map<String, int[]> baseLiterals;
    /**
     * The same, for rules whose last segment is {@code *.ext}-shaped, keyed by the tail's last-dot extension
     * ({@code *.class} → {@code .class}, {@code *.class.txt} → {@code .txt}). A base name ending in a different
     * extension cannot match; one that ends in the bucket's extension still verifies the whole rule.
     */
    private final Map<String, int[]> baseSuffixes;

    private static final int MAX_INDEXED_DEPTH = 256;
    /** Below this many unanchored directory literals, a direct literal scan replaces the name index. */
    private static final int UNANCHORED_INDEX_MIN = 4;
    /**
     * Below this many last-segment-bucket rules, the bucket is not built and those rules stay on the scanned path.
     * Four is the measured line for this port ({@code doc/performance/java.md}): {@code deep}'s five bucket rules are
     * 41.5% and 46.1% faster with the bucket (its {@code *.ext} tail checks each allocated a {@link java.util.regex.Matcher})
     * and {@code doublestar}'s 28 are 35.5-37.1%, while {@code flat} (three) and {@code backtrack} (two) stay on
     * the scan, where their 1.8-3.8% movement is the change's noise control.
     */
    private static final int BUCKET_MIN_RULES = 4;

    private GitIgnoreFile(String relativeDirectory, List<Rule> rules) {
        this.relativeDirectory = relativeDirectory;
        Map<String, Integer> anchored = new HashMap<>();
        Map<String, Integer> unanchored = new HashMap<>();
        boolean[] depths = new boolean[MAX_INDEXED_DEPTH + 1];
        int deepest = 0;
        for (int index = 0; index < rules.size(); index++) {
            Rule rule = rules.get(index);
            if (!rule.directoryOnly() || rule.literal() == null) {
                continue;
            }
            if (rule.anchored()) {
                int depth = 1;
                for (int at = rule.literal().indexOf('/'); at >= 0; at = rule.literal().indexOf('/', at + 1)) {
                    depth++;
                }
                if (depth > MAX_INDEXED_DEPTH) {
                    continue;
                }
                anchored.put(rule.literal(), index);
                depths[depth] = true;
                if (depth > deepest) {
                    deepest = depth;
                }
            } else {
                unanchored.put(rule.literal(), index);
            }
            rules.set(index, rule.indexedCopy());
        }
        this.anchoredLiterals = anchored;
        this.unanchoredLiterals = unanchored;
        this.unanchoredNames = unanchored.keySet().toArray(new String[0]);
        this.unanchoredRules = new int[this.unanchoredNames.length];
        for (int at = 0; at < this.unanchoredNames.length; at++) {
            this.unanchoredRules[at] = unanchored.get(this.unanchoredNames[at]);
        }
        this.anchoredDepths = depths;
        this.deepestAnchoredDepth = deepest;

        // The last-segment buckets. A rule whose last segment is exactly a base name is keyed by that name; one
        // whose last segment is `*.ext`-shaped by the tail's last-dot extension. Both are necessary conditions, not
        // answers: the rule is still verified against the whole path, and the reverse scan above `best` still
        // decides a later rule. The positions are ascending, so a bucket's last matching pattern is found by
        // walking the bucket downwards.
        int bucketable = 0;
        for (Rule rule : rules) {
            if (bucketKind(rule) != 0) {
                bucketable++;
            }
        }
        Map<String, int[]> bucketLiterals = Map.of();
        Map<String, int[]> bucketSuffixes = Map.of();
        if (bucketable >= BUCKET_MIN_RULES) {
            Map<String, List<Integer>> literalLists = new HashMap<>();
            Map<String, List<Integer>> suffixLists = new HashMap<>();
            for (int index = 0; index < rules.size(); index++) {
                Rule rule = rules.get(index);
                int kind = bucketKind(rule);
                if (kind == 0) {
                    continue;
                }
                String tail = rule.lastSegment();
                if (kind == 1) {
                    literalLists.computeIfAbsent(tail, key -> new ArrayList<>()).add(index);
                } else {
                    String afterStar = tail.substring(1);
                    String key = afterStar.substring(afterStar.lastIndexOf('.'));
                    suffixLists.computeIfAbsent(key, unused -> new ArrayList<>()).add(index);
                }
                rules.set(index, rule.indexedCopy());
            }
            bucketLiterals = positions(literalLists);
            bucketSuffixes = positions(suffixLists);
        }
        this.baseLiterals = bucketLiterals;
        this.baseSuffixes = bucketSuffixes;
        // After the indexes have marked their rules: the list is the immutable one the decision iterates.
        this.rules = List.copyOf(rules);
    }

    /**
     * Which last-segment bucket a rule belongs in: {@code 0} for none, {@code 1} for an exact literal tail,
     * {@code 2} for a {@code *.ext}-shaped tail.
     *
     * <p>Directory-only rules are never bucketed: their match can be an ancestor directory, whose base name is not
     * the path's, so a base-name key would reject a path the rule really excludes. A plain unanchored name stays on
     * the scan too — it is one compiled segment test and has no prefix to verify — and it is already answered by the
     * unanchored-literal index.</p>
     */
    private static int bucketKind(Rule rule) {
        if (rule.directoryOnly()) {
            return 0;
        }
        if (!rule.anchored() && rule.literal() != null) {
            return 0;
        }
        String tail = rule.lastSegment();
        if (tail.isEmpty()) {
            return 0;
        }
        if (isPlain(tail)) {
            return 1;
        }
        if (tail.length() >= 3 && tail.charAt(0) == '*' && tail.charAt(1) == '.'
                && isPlain(tail.substring(1))) {
            return 2;
        }
        return 0;
    }

    /** Whether {@code text} holds no byte that needs the matcher: no wildcard and no escape. */
    private static boolean isPlain(String text) {
        return text.indexOf('*') < 0 && text.indexOf('?') < 0 && text.indexOf('[') < 0
                && text.indexOf('\\') < 0;
    }

    /**
     * The highest rule position in one last-segment bucket that actually matches, or {@code best} unchanged.
     *
     * <p>The positions are ascending, so walking them downwards finds the last matching pattern of the bucket
     * first: the first verified position above {@code best} is that bucket's winner, and a rule that fails its
     * whole-path verification falls through to the next position rather than to "no match". The whole-path check
     * is what makes the bucket a candidate source rather than an answer — the last segment is necessary, not
     * sufficient — and {@code tailRejects} rejects a wrong tail before the path is split.</p>
     */
    private int bucketCandidate(String path, int[] positions, int best, boolean isDirectory) {
        String[] parts = null;
        for (int at = positions.length - 1; at >= 0; at--) {
            int index = positions[at];
            if (index <= best) {
                break;
            }
            Rule rule = rules.get(index);
            if (parts == null) {
                if (rule.tailRejects(path)) {
                    continue;
                }
                parts = path.split("/", -1);
            }
            if (rule.matches(path, parts, isDirectory)) {
                return index;
            }
        }
        return best;
    }

    /** A {@code List<Integer>} map as the immutable {@code int[]} positions the decision walks. */
    private static Map<String, int[]> positions(Map<String, List<Integer>> lists) {
        Map<String, int[]> converted = new HashMap<>(lists.size());
        for (Map.Entry<String, List<Integer>> entry : lists.entrySet()) {
            int[] positions = new int[entry.getValue().size()];
            for (int index = 0; index < positions.length; index++) {
                positions[index] = entry.getValue().get(index);
            }
            converted.put(entry.getKey(), positions);
        }
        return converted;
    }

    /**
     * Parses the text of a {@code .gitignore} that lives in {@code relativeDirectory} (empty for the walk
     * root, otherwise a {@code /}-separated path with no trailing slash).
     */
    public static GitIgnoreFile parse(String relativeDirectory, String text) {
        String directory = relativeDirectory == null ? "" : relativeDirectory;
        while (directory.endsWith("/")) {
            directory = directory.substring(0, directory.length() - 1);
        }
        List<Rule> rules = new ArrayList<>();
        // A CRLF checkout must parse like an LF one: the carriage return is not part of the pattern.
            for (String line : text.replace("\r\n", "\n").split("\n", -1)) {
            Rule rule = Rule.parse(line);
            if (rule != null) {
                rules.add(rule);
            }
        }
        return new GitIgnoreFile(directory, rules);
    }

    /** Reads {@code directory/.gitignore} when it exists; empty when the directory has none. */
    public static Optional<GitIgnoreFile> read(java.nio.file.Path directory, String relativeDirectory)
            throws java.io.IOException {
        java.nio.file.Path file = directory.resolve(FILE_NAME);
        if (!java.nio.file.Files.isRegularFile(file)) {
            return Optional.empty();
        }
        return Optional.of(parse(relativeDirectory,
                new String(java.nio.file.Files.readAllBytes(file), java.nio.charset.StandardCharsets.UTF_8)));
    }

    /**
     * {@link #read} with the empty file substituted for "none" — what a walk pushes for every directory, so
     * its push/pop pairs stay balanced whether or not a directory has a {@code .gitignore}.
     */
    public static GitIgnoreFile readOrEmpty(java.nio.file.Path directory, String relativeDirectory)
            throws java.io.IOException {
        return read(directory, relativeDirectory).orElseGet(() -> parse(relativeDirectory, ""));
    }

    /** The directory this file governs, relative to the walk root ({@code ""} at the root). */
    public String relativeDirectory() {
        return relativeDirectory;
    }

    /** How many patterns the file holds, comments and blank lines excluded. */
    public int ruleCount() {
        return rules.size();
    }

    /**
     * What this file decides about {@code relativePath} (relative to the <em>walk root</em>, always
     * {@code /}-separated).
     *
     * @return {@code true} when the last matching pattern excludes it, {@code false} when the last matching
     *         pattern re-includes it, and empty when no pattern matches — which is not the same as
     *         "included", because a shallower {@code .gitignore} may still exclude it
     */
    public Optional<Boolean> decide(String relativePath, boolean isDirectory) {
        String scoped = scopedPath(relativePath);
        if (scoped == null) {
            return Optional.empty();
        }
        // Ask the index first. `best` is the highest rule position any indexed rule can reach for this path, so only
        // rules after it can override the answer — usually none, and then the path is answered without a split.
        //
        // An unanchored directory-only rule names one directory, so it is a question about a directory's own base
        // name, never about an interior segment of a path below it: a matching ancestor is `GitIgnoreRules`' inherited
        // directory state. Testing interior segments here made a later `!out/` re-include `out/x`; git excludes it
        // through `out/`, or decides the file by its own name.
        int best = -1;
        if (isDirectory && unanchoredNames.length > 0 && unanchoredNames.length < UNANCHORED_INDEX_MIN) {
            // Few names: a direct base-name comparison beats a map get and builds no substring. The threshold is
            // measured: backtrack 1661 -> 294 ns/decision and deep 612 -> 273, while flat (4 names) goes 266 -> 338
            // and dirs (40 names) 293 -> 714, so the scan is used only below it.
            for (int at = 0; at < unanchoredNames.length; at++) {
                if (unanchoredRules[at] > best && endsWithSegment(scoped, unanchoredNames[at])) {
                    best = unanchoredRules[at];
                }
            }
        }
        if (isDirectory && unanchoredNames.length >= UNANCHORED_INDEX_MIN) {
            Integer at = unanchoredLiterals.get(lastSegmentOf(scoped));
            if (at != null) {
                best = at;
            }
        }
        if (deepestAnchoredDepth > 0) {
            // One lookup per depth that actually holds a rule, not one per rule: a path shorter than a rule's depth
            // costs nothing at all.
            int depth = 0;
            int start = 0;
            while (true) {
                int slash = scoped.indexOf('/', start);
                depth++;
                boolean last = slash < 0;
                if (last && !isDirectory) {
                    break;
                }
                if (depth <= MAX_INDEXED_DEPTH && anchoredDepths[depth]) {
                    String prefix = last ? scoped : scoped.substring(0, slash);
                    Integer at = anchoredLiterals.get(prefix);
                    if (at != null && at > best) {
                        best = at;
                    }
                }
                if (last) {
                    break;
                }
                start = slash + 1;
            }
        }
        // The last-segment buckets are candidate sources, not answers: the last segment is necessary, the whole rule
        // is still verified, and the reverse scan below starts above `best`, so a later rule always overrides a
        // bucket hit exactly as it overrides an indexed literal.
        if (!baseLiterals.isEmpty() || !baseSuffixes.isEmpty()) {
            int slash = scoped.lastIndexOf('/');
            String base = slash < 0 ? scoped : scoped.substring(slash + 1);
            int[] literalPositions = baseLiterals.get(base);
            if (literalPositions != null) {
                best = bucketCandidate(scoped, literalPositions, best, isDirectory);
            }
            int dot = base.lastIndexOf('.');
            if (dot >= 0) {
                int[] suffixPositions = baseSuffixes.get(base.substring(dot));
                if (suffixPositions != null) {
                    best = bucketCandidate(scoped, suffixPositions, best, isDirectory);
                }
            }
        }
        // One split per decision, and only once a rule's last segment has accepted the raw path: on `backtrack`
        // both DP rules end `*.class` / `*.g4` against `.java` paths, so the split that used to run before the
        // precheck is never paid. A directory-only rule is the exception — its ancestor-prefix branch asks about a
        // different segment, so its split is still paid.
        String[] parts = null;
        for (int index = rules.size() - 1; index > best; index--) {
            Rule rule = rules.get(index);
            if (rule.indexed()) {
                continue;
            }
            if (parts == null) {
                if (rule.tailRejects(scoped)) {
                    continue;
                }
                parts = scoped.split("/", -1);
            }
            if (rule.matches(scoped, parts, isDirectory)) {
                return Optional.of(!rule.negated());
            }
        }
        if (best >= 0) {
            return Optional.of(!rules.get(best).negated());
        }
        return Optional.empty();
    }

    /** The path as this file sees it: {@code null} when the path is not below this file's directory. */
    private String scopedPath(String relativePath) {
        if (relativeDirectory.isEmpty()) {
            return relativePath;
        }
        String prefix = relativeDirectory + "/";
        return relativePath.startsWith(prefix) ? relativePath.substring(prefix.length()) : null;
    }

    /** The last {@code /}-separated segment of a path, without a split. */
    private static String lastSegmentOf(String path) {
        int slash = path.lastIndexOf('/');
        return slash < 0 ? path : path.substring(slash + 1);
    }

    /** Whether {@code path}'s last {@code /}-separated segment is exactly {@code literal}, without a split. */
    private static boolean endsWithSegment(String path, String literal) {
        int start = path.length() - literal.length();
        if (start < 0 || (start > 0 && path.charAt(start - 1) != '/')) {
            return false;
        }
        return path.endsWith(literal);
    }

    /** One pattern: its polarity, whether it is directory-only, and its compiled form. */
    private record Rule(boolean negated, boolean directoryOnly, boolean anchored, String literal, boolean indexed,
            String lastSegment, Glob.Segment[] segments) {

        /** The same rule, marked as answered by one of the file's indexes rather than scanned. */
        Rule indexedCopy() {
            return new Rule(negated, directoryOnly, anchored, literal, true, lastSegment, segments);
        }

        /**
         * Parses one line: {@code null} for a blank line or a comment.
         */
        static Rule parse(String rawLine) {
            String line = stripTrailingUnescapedSpaces(rawLine);
            if (line.isEmpty() || line.charAt(0) == '#') {
                return null;
            }
            boolean negated = false;
            if (line.charAt(0) == '!') {
                negated = true;
                line = line.substring(1);
                if (line.isEmpty()) {
                    return null;
                }
            }
            boolean directoryOnly = line.endsWith("/") && !line.endsWith("\\/");
            if (directoryOnly) {
                line = line.substring(0, line.length() - 1);
            }
            boolean anchored = line.startsWith("/") || line.contains("/");
            if (line.startsWith("/")) {
                line = line.substring(1);
            }
            if (line.isEmpty()) {
                return null;
            }
            // A plain name (no wildcard, no escape) is indexed rather than scanned; the directory-only ones are what
            // a per-path decision asks about most. The test is exactly the one Glob.Segment.of uses for "literal".
            boolean plain = line.indexOf('*') < 0 && line.indexOf('?') < 0 && line.indexOf('[') < 0
                    && line.indexOf('\\') < 0;
            // The path is matched by the segment DP; only the per-segment regexes are compiled here, which is also
            // where character classes and escapes are understood. The raw last segment is kept for the last-segment
            // buckets, which need the string (a literal tail, or the `*.ext` shape to key by).
            return new Rule(negated, directoryOnly, anchored, plain ? line : null, false,
                    line.substring(line.lastIndexOf('/') + 1),
                    Glob.compile(line, anchored, segment -> translate(segment)));
        }

        /**
         * Whether a whole-path match is impossible because the final pattern segment cannot match the path's final
         * segment — the same necessary condition {@link Glob#matches} applies, asked of the raw path so the caller can
         * decide whether the split is worth paying at all.
         *
         * <p>{@code false} for a directory-only rule: its ancestor-prefix branch asks about a different segment, whose
         * last segment is not the path's, so the path's own tail cannot reject it. {@code false} when the final segment
         * is {@code **}, which has no such condition.</p>
         */
        boolean tailRejects(String path) {
            if (directoryOnly) {
                return false;
            }
            Glob.Segment tail = segments[segments.length - 1];
            if (tail.doubleStar()) {
                return false;
            }
            int slash = path.lastIndexOf('/');
            String last = slash < 0 ? path : path.substring(slash + 1);
            if (tail.literal() != null) {
                return !tail.literal().equals(last);
            }
            return !tail.regex().matcher(last).matches();
        }

        /** The same question with the path already split, so a caller deciding many rules splits it once. */
        boolean matches(String path, String[] segments, boolean isDirectory) {
            if (!directoryOnly) {
                return Glob.matches(this.segments, segments, -1);
            }
            if (!anchored) {
                // An unanchored `pat/` names a directory at any level below its file, so only the path's own base name
                // can be tested here; a matching ancestor is the directory state's inherited fact, not this rule's
                // answer for the path below it. Git's own file decision asks only the final component, which is why
                // `!out/` after `*.log` must not re-include `out/x`.
                return isDirectory && matchesName(segments[segments.length - 1]);
            }
            if (isDirectory && Glob.matches(this.segments, segments, -1)) {
                return true;
            }
            // An anchored directory-only pattern is a whole prefix directory, so a file below it is its match; the
            // walk prunes, and a caller that tests a path on its own gets git's answer either way. A segment count is
            // enough: no substring is built per ancestor.
            for (int count = segments.length - 1; count >= 1; count--) {
                if (Glob.matches(this.segments, segments, count)) {
                    return true;
                }
            }
            return false;
        }

        /**
         * Whether an unanchored directory-only rule names this one directory segment.
         *
         * <p>The rule's pattern has no separator (a separator makes it anchored), so its last compiled segment is the
         * whole name; a lone {@code **} names every directory.</p>
         */
        boolean matchesName(String name) {
            Glob.Segment tail = segments[segments.length - 1];
            if (tail.doubleStar()) {
                return true;
            }
            if (tail.literal() != null) {
                return tail.literal().equals(name);
            }
            return tail.regex().matcher(name).matches();
        }

        /** Trailing spaces are ignored unless they are escaped with a backslash. */
        private static String stripTrailingUnescapedSpaces(String line) {
            int end = line.length();
            while (end > 0 && line.charAt(end - 1) == ' ' && !isEscaped(line, end - 1)) {
                end--;
            }
            return line.substring(0, end);
        }

        private static boolean isEscaped(String line, int index) {
            int backslashes = 0;
            for (int i = index - 1; i >= 0 && line.charAt(i) == '\\'; i--) {
                backslashes++;
            }
            return (backslashes & 1) == 1;
        }

        /**
         * The glob-to-regex translation, {@code **} included: a leading or slash-delimited {@code **} covers
         * any number of directories, a bare {@code *} stays inside one path segment.
         */
        static String translate(String glob) {
            StringBuilder regex = new StringBuilder();
            for (int index = 0; index < glob.length(); index++) {
                char c = glob.charAt(index);
                switch (c) {
                    case '\\' -> {
                        if (index + 1 < glob.length()) {
                            regex.append(Pattern.quote(String.valueOf(glob.charAt(++index))));
                        } else {
                            regex.append("\\\\");
                        }
                    }
                    case '*' -> {
                        boolean doubleStar = index + 1 < glob.length() && glob.charAt(index + 1) == '*';
                        if (!doubleStar) {
                            regex.append("[^/]*");
                            break;
                        }
                        int first = index;
                        int second = index + 1;
                        boolean atSegmentStart = first == 0 || glob.charAt(first - 1) == '/';
                        boolean followedBySlash = second + 1 < glob.length() && glob.charAt(second + 1) == '/';
                        boolean atEnd = second + 1 == glob.length();
                        if (atSegmentStart && followedBySlash) {
                            // "**/" — zero or more directories. In the "/**/" form the preceding '/'
                            // has already been emitted, so the group slots in right after it.
                            regex.append("(?:.*/)?");
                            index = second + 1;      // consume the '/'
                        } else if (atSegmentStart && atEnd) {
                            // A trailing "/**" matches everything inside, not the directory itself: the
                            // '/' before it is already in the regex, so the path has to continue.
                            regex.append(".*");
                            index = second;
                        } else {
                            // Any other consecutive asterisks are just asterisks, and an asterisk never
                            // crosses a path separator (git's wildmatch rule).
                            regex.append("[^/]*");
                            index = second;
                        }
                    }
                    case '?' -> regex.append("[^/]");
                    case '[' -> index = appendCharacterClass(regex, glob, index);
                    default -> regex.append(Pattern.quote(String.valueOf(c)));
                }
            }
            return regex.toString();
        }

        /**
         * Translates {@code [...]} into a regex character class, returning the index of its closing bracket
         * (or of the {@code [} itself when the class is unterminated, which git also treats as a literal).
         */
        private static int appendCharacterClass(StringBuilder regex, String glob, int open) {
            // A `]` immediately after the opener is a member, not the terminator: `[]]x` holds `]` then `x`.
            int from = open + 1 < glob.length() && glob.charAt(open + 1) == ']' ? open + 2 : open + 1;
            int close = glob.indexOf(']', from);
            if (close < 0) {
                // git's wildmatch aborts the whole pattern, so the class matches nothing and the rest is not read.
                regex.append("(?!)");
                return glob.length() - 1;
            }
            String body = glob.substring(open + 1, close);
            StringBuilder translated = new StringBuilder("[");
            int start = 0;
            if (!body.isEmpty() && (body.charAt(0) == '!' || body.charAt(0) == '^')) {
                translated.append('^');
                start = 1;
            }
            for (int i = start; i < body.length(); i++) {
                char c = body.charAt(i);
                if (c == '\\' && i + 1 < body.length()) {
                    translated.append('\\').append(body.charAt(++i));
                } else if (c == '[' || c == ']' || c == '^') {
                    translated.append('\\').append(c);
                } else {
                    translated.append(c);
                }
            }
            if (translated.length() == 1 || (translated.length() == 2 && translated.charAt(0) == '^')) {
                // An empty class matches nothing in git either; a group that never matches says that
                // without producing a regex Java would reject.
                regex.append("(?!)");
                return close;
            }
            translated.append(']');
            regex.append(translated);
            return close;
        }
    }
}
