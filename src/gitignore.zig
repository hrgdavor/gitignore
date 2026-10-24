// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! One `.gitignore` file's patterns, matched the way `git` matches them.
//!
//! This is deliberately not "a glob library". A trio describes the files a project considers ours, and the
//! definition of "not ours" is a `.gitignore` file read per directory (`FORMAT.md` § 16). The semantics below
//! are git's, and `conformance/fsmeta-vectors.json`'s `gitignoreCases` pin them across the Java, Bun and Zig
//! walks.
//!
//! ## What this module owns, and what it does not
//!
//! A `Rules` value is **one** file's patterns. Every path handed to `decide`/`matches` is relative to the
//! directory holding that file, `/`-separated, with no leading or trailing slash (the walker does the
//! rebasing). Within one file the **last matching pattern wins**, so `*.log` followed by `!keep.log`
//! re-includes `keep.log` — and the reverse order excludes it again, because a negation is not special.
//!
//! Precedence **across** directories — a deeper file beats a shallower one — is the walker's job, not this
//! module's. The walker keeps a stack of files, asks the deepest first, and stops at the first file that has
//! an opinion (`decide` returns `null` when no pattern matches, which is *not* the same as "included": a
//! shallower file may still exclude the path).
//!
//! Likewise the walker's pruning rule is not implemented here: a directory excluded by a pattern is **not
//! entered**, so a `!` pattern below it never gets a chance to re-include anything — git's documented
//! "it is not possible to re-include a file if a parent directory of that file is excluded". The walker gets
//! that for free by never calling this module on a path below an excluded directory.
//!
//! ## The rules that are easy to get wrong
//!
//! * **Scope.** A path outside this file's directory can never match, so a directory's own file cannot
//!   exclude the directory itself. The walker rebases the path; this module never sees a `..` segment.
//! * **Anchoring.** A pattern with a `/` at the start or in the middle is relative to this file's directory;
//!   otherwise it matches the final path segment at any depth.
//! * **A trailing `/`** means directories only. Like git (and the Java and Bun ports), a file inside such an
//!   excluded directory also answers "excluded", which is what makes pruning equivalent to ignoring the
//!   whole subtree.
//! * **Two consecutive asterisks (`**`)** follow git's three cases: a leading `**/` covers any depth, a
//!   trailing `/**` covers everything
//!   *inside* a directory (not the directory itself), and `a/**/b` covers zero or more directories between
//!   two segments. Any other run of asterisks is just a run of asterisks.
//! * **A character class** is `[...]`, `[!...]` or `[^...]`. A `]` immediately after the opener is a member,
//!   not the terminator (`[]]` is a class holding `]`), and a class that is never closed matches **nothing**:
//!   git's `wildmatch` aborts the whole pattern, so `[abc` does not even match the literal name `[abc`.
//! * **Matching is case-sensitive on every platform**, deliberately: a trio is written on one machine and
//!   read on another, so the ports must agree with each other before they agree with a file system.

const std = @import("std");

/// The file name a walk reads in every directory.
pub const file_name = ".gitignore";

/// One parsed pattern. `glob` points into the backing text owned by the enclosing `Rules`.
/// How a pattern is answered. Classified once at parse time, because the class decides the cost of every
/// later lookup: a literal is a string compare, a suffix rule is `endsWith`, only a general glob reaches the
/// recursive matcher.
const Kind = enum { literal, suffix, glob };

pub const Rule = struct {
    /// The pattern with the leading `/` and the trailing `/` removed; backslash escapes are still present
    /// and are interpreted by the matcher.
    glob: []const u8,
    /// `!pat`: this pattern re-includes when it is the last match.
    negated: bool,
    /// A trailing `/`: only directories (and, by the ancestor rule, their contents) match.
    directory_only: bool,
    /// A `/` at the start or in the middle: match against the whole path, not the final segment.
    anchored: bool,
    kind: Kind,
    /// For `kind == .suffix`, the part after the leading `*` (e.g. `.log`); empty otherwise.
    suffix: []const u8,
    /// For an anchored rule whose first segment is literal, that segment: a path starting with anything else
    /// cannot match, so the expensive match is skipped. `null` when the first segment holds a wildcard.
    first_segment: ?[]const u8,
    /// For a rule whose *last* segment is literal (`**/target`, `x/**/y`), that segment. A path whose base is
    /// something else cannot match, which rejects most entries with one comparison instead of a prefix walk.
    last_segment: ?[]const u8,
};

/// The patterns of one `.gitignore` file, parsed once and owned by the caller.
pub const Rules = struct {
    allocator: std.mem.Allocator,
    /// The parsed file's text; every `Rule.glob` points into it.
    backing: []u8,
    items: []Rule,
    /// Unanchored literal patterns, by the segment they name, each mapped to its **last** rule index.
    literals: std.StringHashMapUnmanaged(usize) = .{},
    /// The same, for `pat/` — a directory-only literal, which matches a file named that only when the file is
    /// a directory, so the final segment counts only for a directory.
    literals_dir_only: std.StringHashMapUnmanaged(usize) = .{},

    /// Parses the text of one `.gitignore`. The bytes are copied, so the caller may free its buffer
    /// immediately. Call `deinit` when the rules are no longer needed.
    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Rules {
        const backing = try allocator.dupe(u8, bytes);
        errdefer allocator.free(backing);

        var list: std.ArrayList(Rule) = .empty;
        errdefer list.deinit(allocator);

        // git strips a CR before the LF, so a CRLF checkout parses like an LF one; the trailing-space trim
        // below does not touch a CR, so it is done here.
        var lines = std.mem.splitScalar(u8, backing, '\n');
        while (lines.next()) |raw_line| {
            const without_cr = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
                raw_line[0 .. raw_line.len - 1]
            else
                raw_line;
            var line = trimTrailingUnescapedSpaces(without_cr);

            if (line.len == 0 or line[0] == '#') continue;

            var negated = false;
            if (line[0] == '!') {
                negated = true;
                line = line[1..];
                // A lone `!` is a pattern with no bytes; git treats it as matching nothing. Skipping it
                // keeps it out of `ruleCount`.
                if (line.len == 0) continue;
            }

            const directory_only = line.len > 0 and line[line.len - 1] == '/' and
                !isEscaped(line, line.len - 1);
            if (directory_only) line = line[0 .. line.len - 1];

            // A separator at the start or anywhere in the middle anchors the pattern to this file's
            // directory. The leading slash is not part of the pattern itself.
            var anchored = (line.len > 0 and line[0] == '/') or
                std.mem.indexOfScalar(u8, line, '/') != null;
            if (line.len > 0 and line[0] == '/') line = line[1..];

            // `**/pat` applies at any depth, which is what an unanchored pattern already means. Normalising the
            // prefix here is what keeps those rules in the indexed classes instead of the general glob: without
            // it, every entry pays an ancestor-prefix walk for each of them (fifty-odd in a real Java tree).
{//doublestar-normalise
            if (anchored and std.mem.startsWith(u8, line, "**/")) {
                line = line[3..];
                anchored = false;
            }
}

            if (line.len == 0) continue;

            var kind: Kind = .glob;
            var suffix: []const u8 = "";
            var first_segment: ?[]const u8 = null;
            var last_segment: ?[]const u8 = null;
            {
                const slash = std.mem.lastIndexOfScalar(u8, line, '/') orelse 0;
                const tail = if (slash == 0) line else line[slash + 1 ..];
                if (tail.len > 0 and !hasWildcard(tail)) last_segment = tail;
            }
            if (anchored) {
                const slash = std.mem.indexOfScalar(u8, line, '/') orelse line.len;
                const head = line[0..slash];
                if (head.len > 0 and !hasWildcard(head)) first_segment = head;
            }
            if (!hasWildcard(line)) {
                kind = .literal;
            } else if (line.len >= 3 and line[0] == '*' and line[1] == '.' and !hasWildcard(line[1..])) {
                kind = .suffix;
                suffix = line[1..];
            }

            try list.append(allocator, .{
                .glob = line,
                .negated = negated,
                .directory_only = directory_only,
                .anchored = anchored,
                .kind = kind,
                .suffix = suffix,
                .first_segment = first_segment,
                .last_segment = last_segment,
            });
        }

        const items = try list.toOwnedSlice(allocator);
        var rules: Rules = .{ .allocator = allocator, .backing = backing, .items = items };
        // Later entries overwrite earlier ones, so each map holds the last rule index for its key — which is
        // exactly the precedence `decide` needs.
        for (items, 0..) |rule, index| {
            if (rule.kind != .literal or rule.anchored) continue;
            const map = if (rule.directory_only) &rules.literals_dir_only else &rules.literals;
            try map.put(allocator, rule.glob, index);
        }
        return rules;
    }

    pub fn deinit(self: *Rules) void {
        self.literals.deinit(self.allocator);
        self.literals_dir_only.deinit(self.allocator);
        self.allocator.free(self.items);
        self.allocator.free(self.backing);
        self.* = undefined;
    }

    /// How many patterns the file holds (comments and blank lines excluded).
    pub fn ruleCount(self: Rules) usize {
        return self.items.len;
    }

    /// What this file decides about `rel_path`, a path relative to this file's own directory and
    /// `/`-separated.
    ///
    /// Returns `true` to exclude, `false` when the **last matching pattern** is a negation, and `null` when
    /// no pattern matches. `null` is not "included": a shallower `.gitignore` may still have an opinion, and
    /// the walker consults deeper files first precisely so that stays a decision rather than an accident.
    pub fn decide(self: Rules, rel_path: []const u8, is_dir: bool) ?bool {
        // The highest rule index of an indexed literal that matches. Segment walking is O(depth) probes; the
        // ordered walk below then starts from that index, because nothing at or below it can be the last match.
        var best: ?usize = null;
        var start: usize = 0;
        while (start <= rel_path.len) {
            const slash = std.mem.indexOfScalarPos(u8, rel_path, start, '/') orelse rel_path.len;
            const segment = rel_path[start..slash];
            const last_segment = slash == rel_path.len;
            // An unanchored literal names one file or directory, so only the final segment can be that name.
            // A matching ancestor directory is the caller's ancestor walk, not this path's own match.
            if (last_segment) {
                if (self.literals.get(segment)) |literal| {
                    if (best == null or literal > best.?) best = literal;
                }
            }
            if (!last_segment or is_dir) {
                if (self.literals_dir_only.get(segment)) |literal| {
                    if (best == null or literal > best.?) best = literal;
                }
            }
            if (last_segment) break;
            start = slash + 1;
        }

        // Reverse order over what is left: the last matching pattern wins. A rule whose literal first segment
        // differs from the path's cannot match anything below that segment, so it costs one comparison.
        const path_first = rel_path[0..(std.mem.indexOfScalar(u8, rel_path, '/') orelse rel_path.len)];
        var scan = self.items.len;
        const floor = best orelse 0;
        while (scan > floor) {
            scan -= 1;
            const rule = self.items[scan];
            if (rule.kind == .literal and !rule.anchored) continue; // answered by `best`
            if (rule.first_segment) |head| {
                if (!std.mem.eql(u8, head, path_first)) continue;
            }
            if (ruleMatches(rule, rel_path, is_dir)) return !rule.negated;
        }
        if (best) |winner| return !self.items[winner].negated;
        return null;
    }

    /// Whether this file excludes `rel_path` — `decide` with "no opinion" read as "not excluded".
    ///
    /// This is the convenience form. A walk should call `decide` so it can fall back to a shallower file;
    /// a caller testing one path in isolation gets the same answer either way.
    pub fn matches(self: Rules, rel_path: []const u8, is_dir: bool) bool {
        return self.decide(rel_path, is_dir) orelse false;
    }
};

/// Whether `rule`, which belongs to the `.gitignore` in the path's own directory, matches `path`.
fn ruleMatches(rule: Rule, path: []const u8, is_dir: bool) bool {
    if (!rule.directory_only) return pathMatches(rule, path);

    // A trailing slash means directories only: the path itself counts when it is a directory ...
    if (is_dir and pathMatches(rule, path)) return true;
    // ... and any file inside such an excluded directory counts as excluded too, which is git's rule and
    // the reason pruning a directory is equivalent to ignoring its whole subtree. Every proper prefix that
    // ends at a `/` is a directory by construction.
    var index: usize = 0;
    while (index < path.len) : (index += 1) {
        if (path[index] == '/') {
            if (pathMatches(rule, path[0..index])) return true;
        }
    }
    return false;
}

/// Whether `line` holds an unescaped wildcard byte (`*`, `?`, `[`).
fn hasWildcard(line: []const u8) bool {
    var index: usize = 0;
    while (index < line.len) : (index += 1) {
        switch (line[index]) {
            '\\' => return true, // an escape needs the matcher
            '*', '?', '[' => return true,
            else => {},
        }
    }
    return false;
}

/// Matches the pattern against the whole path, or — for an unanchored pattern — against its final segment.
/// Literal and suffix rules never reach `globMatch`.
fn pathMatches(rule: Rule, path: []const u8) bool {
    // A literal last segment rejects the path with one comparison, before any prefix or glob work.
    if (rule.anchored) {
        if (rule.last_segment) |tail| {
            const base = path[(std.mem.lastIndexOfScalar(u8, path, '/') orelse 0)..];
            const name = if (base.len > 0 and base[0] == '/') base[1..] else base;
            if (!std.mem.eql(u8, name, tail)) return false;
        }
    }
    const text = if (rule.anchored) path else blk: {
        const slash = std.mem.lastIndexOfScalar(u8, path, '/');
        break :blk if (slash) |index| path[index + 1 ..] else path;
    };
    return switch (rule.kind) {
        .literal => std.mem.eql(u8, rule.glob, text),
        .suffix => text.len >= rule.suffix.len and std.mem.endsWith(u8, text, rule.suffix),
        .glob => globMatch(rule.glob, text),
    };
}

/// The pattern against one text, by class: a compare, a suffix test, or the general glob.
fn matchText(rule: Rule, text: []const u8) bool {
    return switch (rule.kind) {
        .literal => std.mem.eql(u8, rule.glob, text),
        .suffix => text.len >= rule.suffix.len and std.mem.endsWith(u8, text, rule.suffix),
        .glob => globMatch(rule.glob, text),
    };
}

/// `ruleMatches`, with the final segment supplied and directory-only rules matched segment by segment.
fn ruleMatchesBase(rule: Rule, path: []const u8, base: []const u8, is_dir: bool) bool {
    if (!rule.directory_only) return matchText(rule, if (rule.anchored) path else base);

    if (rule.anchored) {
        if (is_dir and matchText(rule, path)) return true;
        var index: usize = 0;
        while (index < path.len) : (index += 1) {
            if (path[index] == '/') {
                if (matchText(rule, path[0..index])) return true;
            }
        }
        return false;
    }

    // Unanchored and directory-only: the path itself when it is a directory, and every ancestor prefix (each one
    // is a directory by construction).
    if (is_dir and matchText(rule, path)) return true;
    var index: usize = 0;
    while (index < path.len) : (index += 1) {
        if (path[index] == '/') {
            if (matchText(rule, path[0..index])) return true;
        }
    }
    return false;
}

/// The segments of a `/`-separated path, with a hard bound. Snapshots are shallow (the deepest tree measured is
/// 14 levels), and refusing a deeper path is better than an unbounded stack.
const max_segments = 256;

fn splitSegments(input: []const u8, out: *[max_segments][]const u8) usize {
    var count: usize = 0;
    if (input.len == 0) return 0;
    var start: usize = 0;
    while (start <= input.len) {
        const slash = std.mem.indexOfScalarPos(u8, input, start, '/') orelse input.len;
        if (count == max_segments) return max_segments + 1; // signals "too deep"
        out[count] = input[start..slash];
        count += 1;
        if (slash == input.len) break;
        start = slash + 1;
    }
    return count;
}

/// The final `/`-separated segment of `text` — `text` itself when it holds no `/`.
fn lastSegment(text: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, text, '/') orelse return text;
    return text[slash + 1 ..];
}

/// Matches a `/`-separated glob against a `/`-separated path, in full, with git's `**` rules.
///
/// A `**` that is a whole segment matches zero or more path segments; a *trailing* `**` requires at least one,
/// because `foo/**` means everything *inside* `foo`, not `foo` itself. Anything else is one segment, matched
/// without crossing a `/`.
///
/// Implemented as a segment dynamic program — `ok[j]` says "the pattern so far matches the first `j` path
/// segments" — because the recursive form re-tested `**` at every boundary and went exponential on deep paths.
/// Each pattern segment advances one row, so the work is O(pattern segments × path segments) and never backtracks.
///
/// A last pattern segment that is not `**` has to match the path's last segment in any successful match, so
/// that one comparison runs first. It rejects `.../*.g4` against `.../File.java` before either input is split,
/// and a rule that cannot match therefore costs one segment test rather than a whole DP — the shape the
/// `backtrack` workload measures.
pub fn globMatch(pattern: []const u8, path: []const u8) bool {
    if (pattern.len != 0) {
        const tail = lastSegment(pattern);
        if (!std.mem.eql(u8, tail, "**")) {
            if (path.len == 0) return false;
            if (!wildMatchSegment(tail, lastSegment(path))) return false;
        }
    }
    var pattern_segments: [max_segments][]const u8 = undefined;
    var path_segments: [max_segments][]const u8 = undefined;
    const pattern_count = splitSegments(pattern, &pattern_segments);
    const path_count = splitSegments(path, &path_segments);
    if (pattern_count > max_segments or path_count > max_segments) return false;
    if (pattern_count == 0) return path_count == 0;

    // `ok[j]`: the pattern segments seen so far match the first `j` path segments.
    var ok: [max_segments + 1]bool = undefined;
    var next: [max_segments + 1]bool = undefined;
    for (0..path_count + 1) |j| ok[j] = j == 0;

    for (pattern_segments[0..pattern_count], 0..) |segment, index| {
        const trailing = index + 1 == pattern_count;
        if (std.mem.eql(u8, segment, "**")) {
            if (trailing) {
                // One or more segments below the previous match.
                var reachable = false;
                for (0..path_count + 1) |j| {
                    next[j] = reachable;
                    reachable = reachable or ok[j];
                }
            } else {
                // Zero or more.
                var reachable = false;
                for (0..path_count + 1) |j| {
                    reachable = reachable or ok[j];
                    next[j] = reachable;
                }
            }
        } else {
            next[0] = false;
            for (1..path_count + 1) |j| {
                next[j] = ok[j - 1] and wildMatchSegment(segment, path_segments[j - 1]);
            }
        }
        @memcpy(ok[0 .. path_count + 1], next[0 .. path_count + 1]);
    }
    return ok[path_count];
}

/// The same match, written the way the first implementation did it: a recursion that retries the rest of the
/// pattern at every position after a `**`.
///
/// This is deliberately **exponential** on a path with several `**` segments — it is the historical design
/// kept as a benchmark mode, not an alternative implementation. `-Dnaive=true` builds a CLI that calls this
/// (through `ignore.decideNaive`); the default executable never references it, so Zig does not analyse it
/// there (the tests do call it, so the historical path is tested rather than only remembered).
pub fn globMatchNaive(pattern: []const u8, path: []const u8) bool {
    var pattern_segments: [max_segments][]const u8 = undefined;
    var path_segments: [max_segments][]const u8 = undefined;
    const pattern_count = splitSegments(pattern, &pattern_segments);
    const path_count = splitSegments(path, &path_segments);
    if (pattern_count > max_segments or path_count > max_segments) return false;
    return naiveSegments(pattern_segments[0..pattern_count], path_segments[0..path_count]);
}

fn naiveSegments(pattern: []const []const u8, path: []const []const u8) bool {
    if (pattern.len == 0) return path.len == 0;
    const first = pattern[0];
    if (std.mem.eql(u8, first, "**")) {
        // A trailing `**` needs at least one segment (it means "inside"); a middle one matches zero or more.
        if (pattern.len == 1) return path.len > 0;
        if (naiveSegments(pattern[1..], path)) return true;
        var index: usize = 0;
        while (index < path.len) : (index += 1) {
            if (naiveSegments(pattern[1..], path[index + 1 ..])) return true;
        }
        return false;
    }
    if (path.len == 0) return false;
    if (!wildMatchSegment(first, path[0])) return false;
    return naiveSegments(pattern[1..], path[1..]);
}

/// Matches one segment with `*`, `?`, `[...]` and `\` escapes. The text never contains a `/`.
fn wildMatchSegment(pattern: []const u8, text: []const u8) bool {
    if (pattern.len == 0) return text.len == 0;

    switch (pattern[0]) {
        '*' => {
            // Consecutive asterisks inside a segment are all just asterisks.
            var after = @as(usize, 1);
            while (after < pattern.len and pattern[after] == '*') after += 1;
            const rest = pattern[after..];
            var index: usize = 0;
            while (true) {
                if (wildMatchSegment(rest, text[index..])) return true;
                if (index == text.len) return false;
                index += 1;
            }
        },
        '?' => return text.len > 0 and wildMatchSegment(pattern[1..], text[1..]),
        '\\' => {
            if (pattern.len >= 2) {
                return text.len > 0 and pattern[1] == text[0] and
                    wildMatchSegment(pattern[2..], text[1..]);
            }
            // A trailing backslash is a literal backslash (git's wildmatch does the same).
            return text.len > 0 and text[0] == '\\' and wildMatchSegment(pattern[1..], text[1..]);
        },
        '[' => {
            if (text.len == 0) return false;
            const class = matchClass(pattern, text[0]);
            if (!class.matched) return false;
            return wildMatchSegment(pattern[class.next..], text[1..]);
        },
        else => return text.len > 0 and pattern[0] == text[0] and
            wildMatchSegment(pattern[1..], text[1..]),
    }
}

const ClassMatch = struct {
    matched: bool,
    /// Index just past the closing `]` (or past the literal `[` when the class is unterminated).
    next: usize,
};

/// Matches one `[...]` class against `ch`. `pattern[0]` is the opening `[`.
///
/// A `]` as the **first** member (after `[`, `[!` or `[^`) is a literal member, not the terminator, which is
/// what makes `[]]` a class containing `]`. That is git's behaviour and POSIX's, and a port that scans for
/// the first `]` without this rule reads `[]]` as an empty class and matches nothing.
///
/// A class that is never closed matches **nothing** and consumes the rest of the pattern. It is *not* a
/// literal `[`: git's `wildmatch` reports `ABORT_ALL` for an unterminated bracket expression, so the whole
/// pattern fails. `[abc` therefore does not match the name `[abc`.
fn matchClass(pattern: []const u8, ch: u8) ClassMatch {
    // Where the body may start, and the first position that can hold the closing `]`.
    var index: usize = 1;
    if (index < pattern.len and (pattern[index] == '!' or pattern[index] == '^')) index += 1;
    var search = index;
    if (search < pattern.len and pattern[search] == ']') search += 1;

    const close_rel = std.mem.indexOfScalar(u8, pattern[search..], ']');
    if (close_rel == null) {
        // Unterminated (or `[]`, which the same rule leaves without a terminator): no text can match.
        return .{ .matched = false, .next = pattern.len };
    }
    const close = search + close_rel.?;
    const body = pattern[1..close];
    return .{ .matched = classBodyMatches(body, ch), .next = close + 1 };
}

/// Whether `ch` is in the body of a `[...]` class: `!` or `^` negates, `a-z` is a range, `\` escapes.
fn classBodyMatches(body: []const u8, ch: u8) bool {
    var index: usize = 0;
    var negated = false;
    if (body.len > 0 and (body[0] == '!' or body[0] == '^')) {
        negated = true;
        index = 1;
    }
    // An empty set matches nothing; git (and the ports) never make `[]` or `[!]` match every character.
    if (index == body.len) return false;

    var found = false;
    while (index < body.len) {
        const low = readClassChar(body, &index);
        if (index + 1 < body.len and body[index] == '-') {
            index += 1; // the '-'
            const high = readClassChar(body, &index);
            if (low <= ch and ch <= high) found = true;
        } else if (low == ch) {
            found = true;
        }
    }
    return found != negated;
}

/// Reads one character of a class body, consuming a backslash escape if present.
fn readClassChar(body: []const u8, index: *usize) u8 {
    var c = body[index.*];
    index.* += 1;
    if (c == '\\' and index.* < body.len) {
        c = body[index.*];
        index.* += 1;
    }
    return c;
}

/// Trailing spaces are ignored unless escaped with a backslash (`keep-me ` is `keep-me`; `a\ ` keeps the
/// space). Only spaces are trimmed — a tab is part of the pattern, as in git.
fn trimTrailingUnescapedSpaces(line: []const u8) []const u8 {
    var end = line.len;
    while (end > 0 and line[end - 1] == ' ' and !isEscaped(line, end - 1)) end -= 1;
    return line[0..end];
}

/// Whether the byte at `index` is escaped by an odd number of immediately preceding backslashes.
fn isEscaped(line: []const u8, index: usize) bool {
    var backslashes: usize = 0;
    var cursor = index;
    while (cursor > 0 and line[cursor - 1] == '\\') {
        backslashes += 1;
        cursor -= 1;
    }
    return (backslashes & 1) == 1;
}

// ---------------------------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------------------------

const testing = std.testing;

fn parseForTest(text: []const u8) !Rules {
    return Rules.parse(testing.allocator, text);
}

/// Emulates the walker's pruning rule for one file: a path is listed only when no ancestor directory is
/// excluded. This is the test's stand-in for the real walk, which never enters an excluded directory.
fn walkLists(rules: Rules, path: []const u8) bool {
    var index: usize = 0;
    while (index < path.len) : (index += 1) {
        if (path[index] == '/') {
            if (rules.matches(path[0..index], true)) return false;
        }
    }
    return !rules.matches(path, false);
}

test "a name-only pattern matches a basename at any depth" {
    var rules = try parseForTest("*.log\n");
    defer rules.deinit();

    try testing.expect(rules.matches("debug.log", false));
    try testing.expect(rules.matches("src/deep/debug.log", false));
    try testing.expect(!rules.matches("debug.txt", false));
}

test "a leading slash anchors a pattern to the file's own directory" {
    {
        var rules = try parseForTest("/root-only.txt\n");
        defer rules.deinit();
        try testing.expect(rules.matches("root-only.txt", false));
        try testing.expect(!rules.matches("sub/root-only.txt", false));
    }
    {
        // A separator anywhere also anchors, not just a leading one.
        var rules = try parseForTest("doc/*.txt\n");
        defer rules.deinit();
        try testing.expect(rules.matches("doc/a.txt", false));
        try testing.expect(!rules.matches("other/doc/a.txt", false));
    }
}

test "a trailing slash matches directories only" {
    var rules = try parseForTest("out/\n");
    defer rules.deinit();

    try testing.expect(rules.matches("out", true));
    try testing.expect(!rules.matches("out", false));
    // A file inside an excluded directory is excluded too, which is what makes pruning sound.
    try testing.expect(rules.matches("out/x.txt", false));
}

test "the last matching pattern wins, so a trailing negation re-includes" {
    {
        var rules = try parseForTest("*.log\n!keep.log\n");
        defer rules.deinit();
        try testing.expect(!rules.matches("keep.log", false));
        try testing.expect(rules.matches("other.log", false));
        try testing.expect(!rules.matches("sub/keep.log", false));
    }
    {
        // A negation is not special: putting it first lets the exclusion match last.
        var rules = try parseForTest("!keep.log\n*.log\n");
        defer rules.deinit();
        try testing.expect(rules.matches("keep.log", false));
    }
}

test "a negated child inside an excluded directory stays ignored" {
    // The file alone answers "the last matching pattern is this negation", and the walker's rule is why it
    // does not matter: a directory the matcher excludes is never entered, so the `!` is never consulted.
    var rules = try parseForTest("node_modules/\n!node_modules/keep.txt\n");
    defer rules.deinit();

    try testing.expect(rules.matches("node_modules", true));
    try testing.expect(!rules.matches("node_modules/keep.txt", false)); // the per-file answer
    try testing.expect(!walkLists(rules, "node_modules/keep.txt")); // what a walk actually lists
}

test "the three ** forms follow git's rules" {
    {
        var rules = try parseForTest("docs/**/*.md\n");
        defer rules.deinit();
        try testing.expect(rules.matches("docs/a.md", false)); // zero directories
        try testing.expect(rules.matches("docs/x/b.md", false));
        try testing.expect(rules.matches("docs/x/y/b.md", false));
        try testing.expect(!rules.matches("docs/x/y/b.txt", false));
    }
    {
        var rules = try parseForTest("logs/**\n");
        defer rules.deinit();
        try testing.expect(rules.matches("logs/x/y.txt", false));
        try testing.expect(!rules.matches("logs", true)); // not the directory itself
        try testing.expect(!rules.matches("logs.txt", false)); // and not a name that merely starts the same
    }
    {
        var rules = try parseForTest("**/generated\n");
        defer rules.deinit();
        try testing.expect(rules.matches("generated", true));
        try testing.expect(rules.matches("a/b/generated", true));
        try testing.expect(!rules.matches("a/b/generated.txt", true));
    }
    {
        // Consecutive asterisks that are not a segment of their own are just asterisks.
        var rules = try parseForTest("a**b\n");
        defer rules.deinit();
        try testing.expect(rules.matches("axxb", false));
        try testing.expect(!rules.matches("a/b", false));
    }
}

test "character classes, a closing bracket first, and an unterminated one" {
    var rules = try parseForTest("file[0-9].txt\n[!a].txt\n[]]x\nno[class\n");
    defer rules.deinit();

    try testing.expect(rules.matches("file7.txt", false));
    try testing.expect(!rules.matches("filex.txt", false));
    try testing.expect(rules.matches("b.txt", false));
    try testing.expect(!rules.matches("a.txt", false));
    // `]` immediately after the opener is a member, not the terminator (git's wildmatch, and POSIX).
    try testing.expect(rules.matches("]x", false));
    try testing.expect(!rules.matches("x", false));
    // An unterminated `[` makes the whole pattern unmatchable — git's wildmatch aborts it, so not even the
    // literal name matches. This is a correction of what the first version and the ports assumed.
    try testing.expect(!rules.matches("no[class", false));
    try testing.expect(!rules.matches("noXclass", false));
}

test "a backslash makes a leading # or ! literal" {
    var rules = try parseForTest("\\#literal\n\\!literal\na\\*b\n");
    defer rules.deinit();

    try testing.expectEqual(@as(usize, 3), rules.ruleCount());
    try testing.expect(rules.matches("#literal", false));
    try testing.expect(rules.matches("!literal", false));
    try testing.expect(rules.matches("a*b", false));
    try testing.expect(!rules.matches("ab", false));
}

test "comments, blank lines, trailing spaces and CRLF are handled" {
    var rules = try parseForTest("# a comment\r\n\r\n   \r\nkeep-me \r\nafter\r\n");
    defer rules.deinit();

    try testing.expectEqual(@as(usize, 2), rules.ruleCount());
    try testing.expect(rules.matches("keep-me", false)); // the trailing space is not part of the pattern
    try testing.expect(rules.matches("after", false));
    try testing.expect(rules.decide("# a comment", false) == null);
}

test "a pattern without a slash matches at any depth, and a decision can be absent" {
    var rules = try parseForTest("build\n");
    defer rules.deinit();

    try testing.expect(rules.matches("build", true));
    try testing.expect(rules.matches("a/b/build", true));
    // A non-directory-only pattern excludes the directory; the walker prunes it and never asks about the
    // files below it, which is why walking is the thing to assert here.
    try testing.expect(!walkLists(rules, "a/build/x.txt"));
    try testing.expect(rules.decide("other", false) == null);
    try testing.expect(!rules.matches("other", false));
}

test "a pattern with a single star never crosses a separator" {
    var rules = try parseForTest("sub/*.tmp\n");
    defer rules.deinit();

    try testing.expect(rules.matches("sub/a.tmp", false));
    try testing.expect(!rules.matches("sub/deep/a.tmp", false));
}

test "an empty file has no rules and still deinitializes" {
    var rules = try parseForTest("");
    defer rules.deinit();
    try testing.expectEqual(@as(usize, 0), rules.ruleCount());
    try testing.expect(rules.decide("anything", false) == null);
}

test "the parse owns its bytes and deinit releases them" {
    // `testing.allocator` fails the test on a leak, so this pins the ownership the walker relies on.
    var rules = try Rules.parse(testing.allocator, "*.tmp\n!keep.tmp\n");
    rules.deinit();
}

test "a question mark matches exactly one byte" {
    var rules = try parseForTest("a?c\n");
    defer rules.deinit();

    try testing.expect(rules.matches("abc", false));
    try testing.expect(!rules.matches("abbc", false));
    try testing.expect(!rules.matches("ac", false));
}
