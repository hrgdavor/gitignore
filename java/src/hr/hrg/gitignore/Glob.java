// The segment dynamic program, ported from the Zig reference (and from the JS port, which learned the allocation lesson
// first).
//
// A pattern translated into one regular expression is correct and catastrophically slow: `**` becomes `(?:.*/)?`, and on
// a long path with several of them the regex engine tries exponentially many splits. On the `backtrack` workload that is
// 17.6 s for this port against 66 ms for the Zig implementation.
//
// The DP: `reach[j]` means "the pattern so far matches the first j text segments". An ordinary segment advances one row;
// `**` is an OR over the row, or over the row before it when it is the last pattern segment (one-or-more, because
// `build/**` is everything inside `build`). Each ordinary segment keeps a small regex — that is where character classes
// and escapes are understood — but against one segment it cannot backtrack across `/`.
package hr.hrg.gitignore;

import java.util.ArrayList;
import java.util.List;
import java.util.regex.Pattern;

final class Glob {
    private Glob() {
    }

    /**
     * One pattern segment: the `**` wildcard, a literal string, or a regular expression for a segment with wildcards.
     *
     * <p>A literal segment is the common case — most rules are a name, not a pattern — and comparing two strings is both
     * cheaper than compiling and running a Matcher, and the reason this class does not allocate one per test.
     */
    record Segment(boolean doubleStar, Pattern regex, String literal) {
        static Segment wildcard() {
            return new Segment(true, null, null);
        }

        static Segment of(String segment, java.util.function.Function<String, String> translate) {
            // A segment with no wildcard character can only match itself; escaping a wildcard makes it literal too, and
            // that case is rare enough to take the regex path.
            boolean plain = segment.indexOf('*') < 0 && segment.indexOf('?') < 0 && segment.indexOf('[') < 0 && segment.indexOf('\\') < 0;
            return plain ? new Segment(false, null, segment) : new Segment(false, Pattern.compile(translate.apply(segment)), null);
        }
    }

    /**
     * Compiles a pattern into segments. An unanchored pattern applies at any depth, which is a leading `**` and nothing
     * else.
     *
     * @param glob the pattern, with any leading `/` already removed
     * @param anchored whether the pattern is anchored to the walk root
     * @param translate the port's own translator from one segment to a regex body
     */
    static Segment[] compile(String glob, boolean anchored, java.util.function.Function<String, String> translate) {
        String[] parts = glob.split("/", -1);
        List<Segment> segments = new ArrayList<>(parts.length + 1);
        if (!anchored) {
            segments.add(Segment.wildcard());
        }
        for (String part : parts) {
            segments.add(part.equals("**") ? Segment.wildcard() : Segment.of(part, translate));
        }
        return segments.toArray(new Segment[0]);
    }

    // Two scratch rows per thread, reused across calls: the DP needs a previous and a next row and nothing else.
    private static final ThreadLocal<boolean[][]> SCRATCH = ThreadLocal.withInitial(() -> new boolean[2][]);

    /**
     * Does the compiled pattern match the whole path?
     *
     * @param segments the compiled pattern
     * @param path a `/`-separated path, no leading slash
     */
    static boolean matches(Segment[] segments, String path) {
        return matches(segments, path.split("/", -1), -1);
    }

    /**
     * Does the compiled pattern match the first {@code count} segments of the path? {@code -1} means all of them; a
     * smaller count is how a directory-only rule asks about an ancestor without building a new string.
     */
    static boolean matches(Segment[] segments, String[] text, int count) {
        int limit = count < 0 ? text.length : count;
        boolean[][] scratch = SCRATCH.get();
        if (scratch[0] == null || scratch[0].length < limit + 1) {
            scratch[0] = new boolean[limit + 1];
            scratch[1] = new boolean[limit + 1];
        }
        boolean[] reach = scratch[0];
        boolean[] next = scratch[1];
        for (int position = 0; position <= limit; position++) {
            reach[position] = position == 0;
        }

        for (int index = 0; index < segments.length; index++) {
            Segment segment = segments[index];
            for (int position = 0; position <= limit; position++) {
                next[position] = false;
            }

            if (segment.doubleStar()) {
                boolean last = index == segments.length - 1;
                boolean any = false;
                for (int position = 0; position <= limit; position++) {
                    // A trailing `**` is one-or-more, a middle one is zero-or-more.
                    if (last) {
                        next[position] = any;
                    }
                    if (reach[position]) {
                        any = true;
                    }
                    if (!last) {
                        next[position] = any;
                    }
                }
            } else if (segment.literal() != null) {
                // The literal fast path: no Matcher allocation for the segment that is just a name.
                String literal = segment.literal();
                for (int position = 0; position < limit; position++) {
                    if (reach[position] && literal.equals(text[position])) {
                        next[position + 1] = true;
                    }
                }
            } else {
                Pattern regex = segment.regex();
                for (int position = 0; position < limit; position++) {
                    if (reach[position] && regex.matcher(text[position]).matches()) {
                        next[position + 1] = true;
                    }
                }
            }

            boolean[] swap = reach;
            reach = next;
            next = swap;
        }

        return reach[limit];
    }
}