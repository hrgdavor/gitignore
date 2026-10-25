// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! The `.gitignore` stack a **cold-start listing** needs, so that the incremental path and the full walk agree
//! about which names exist at all.
//!
//! `gitignore.zig` decides one path against one file's rules and answers `null` when that file has no opinion.
//! Turning that into git's behaviour takes two more facts, and they are the whole of this file:
//!
//! 1. **Scope.** A `.gitignore` in `d/` governs the paths below `d`, so a decision needs the path of the candidate
//!    *relative to `d`* — not relative to the scan root. (The walker keeps that as a byte offset, `dir_len`; here
//!    it is computed by stripping the base.)
//! 2. **Precedence.** The deepest file with an opinion wins, and a negation in a deeper file re-includes what a
//!    shallower one excluded. So the decision walks from the candidate's own directory up to the root and takes
//!    the first non-`null`.
//!
//! Excluded directories are not listed and not entered — that is git's rule, and it is what makes the stack safe:
//! because the engine never enters one, no rule inside it can ever re-include anything.

const std = @import("std");
const gitignore = @import("gitignore.zig");

/// A rule chain position, kept beside the part of it that the lookup needs.
const SuffixEntry = struct { suffix: []const u8, at: usize };
const RuleEntry = struct { rule: gitignore.Rule, at: usize };

/// The directory cache's key equality. A path list repeats the same directory string for a whole run, and on
/// this toolchain `std.mem.eql` costs ~550 ns for a 207-byte key where this word-at-a-time XOR costs ~32 ns
/// (measured: `backtrack`'s 28.9 ms was 13.9 ms of directory lookups, of which the hash itself was 0.7 ms and
/// almost all the rest was that compare). It is exact — a hash collision still compares every byte — and the
/// word loop does not depend on the vector lowering whose byte-vector reduce is slow here.
const DirKeyContext = struct {
    pub fn hash(_: DirKeyContext, key: []const u8) u64 {
        return std.hash.Wyhash.hash(0, key);
    }
    pub fn eql(_: DirKeyContext, a: []const u8, b: []const u8) bool {
        return equalBytes(a, b);
    }
};

/// Byte equality, eight at a time. Endianness cannot matter: this is equality, not a value.
fn equalBytes(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var differing: u64 = 0;
    var index: usize = 0;
    while (index + 8 <= a.len) : (index += 8) {
        differing |= std.mem.readInt(u64, a[index..][0..8], .little) ^
            std.mem.readInt(u64, b[index..][0..8], .little);
    }
    while (index < a.len) : (index += 1) differing |= @as(u64, a[index] ^ b[index]);
    return differing == 0;
}

/// The two facts a path's decision needs about the path's **directory**, both fixed while this stack's rules
/// are loaded: the flattened matcher that governs it, and whether it (or one of its ancestors) is excluded.
///
/// They are answered together because finding either one means walking up the directory tree — the chain
/// through the `.gitignore` lookups, the ancestor answer through the chain of every level — and a path list
/// asks about the same directories over and over. One cached answer replaces both walks for every entry.
const DirState = struct {
    /// `null` when no `.gitignore` from the root down to this directory has a rule.
    chain: ?*Chain,
    /// Whether this directory or one of its ancestors, each decided through the chain of *its own* parent, is
    /// excluded. git never enters such a directory, so everything below it is excluded before its own rules
    /// are consulted — and a negation below it can never re-include anything.
    ancestor_excluded: bool,
};

/// One flattened matcher for a directory: every `.gitignore` that governs it, in precedence order.
const Chain = struct {
    /// Deepest file first, each file reversed. An anchored rule `glob` is already scoped to the root.
    items: []gitignore.Rule,
    literals: std.StringHashMapUnmanaged(usize) = .{},
    literals_dir_only: std.StringHashMapUnmanaged(usize) = .{},
    /// `*.ext` rules: only the final segment can match, and only its ending matters.
    suffixes: []SuffixEntry = &.{},
    /// Unanchored general globs: matched against the final segment (or any segment, for directory-only).
    wilds: []RuleEntry = &.{},
    /// Rules that carry a path (`x/**`, `a/**/b`): matched against the whole path and its prefixes.
    /// Anchored literal rules are not here; `literal_dirs` answers the directory-only ones, and the rest are
    /// a plain `pat` whose one path comparison is cheaper than an index walk.
    anchored: []RuleEntry = &.{},
    /// Directory-only anchored literal rules, keyed by their literal path. A `foo/bar/` rule can only match a
    /// path whose first two segments are exactly `foo/bar`, so the decision asks each prefix it might match
    /// instead of testing every rule. This is what removes the "all 100 rules share the first segment `java`"
    /// case: the prune cannot reject them, and a `(depth, literal)` lookup rejects them with one comparison.
    literal_dirs: std.StringHashMapUnmanaged(usize) = .{},
    /// Bit `d` is set when some directory-only anchored literal rule has `d` segments. A path of fewer
    /// segments than a rule's depth can never match it, so those depths cost no lookup at all.
    literal_dir_mask: u256 = 0,

    fn decide(self: Chain, path: []const u8, base: []const u8, is_dir: bool) ?bool {
        var best: ?usize = null;
        // An unanchored literal names one file or directory, and a directory-only one names a directory, so
        // only the path's own final segment can be that name. A matching *ancestor* directory is already an
        // `ancestor_excluded` fact — `Stack.dirState` asks each ancestor through its own parent's chain — and
        // asking about the earlier segments here was wrong twice over: it matched a negation like `!a`
        // against `d/a/build`, and, because this chain carries the candidate directory's own file, it let
        // that file's `a/` match the `a` segment above it, which git scopes away.
        if (self.literals.get(base)) |at| best = at;
        if (is_dir) {
            if (self.literals_dir_only.get(base)) |at| {
                if (best == null or at < best.?) best = at;
            }
        }

        // The directory-only anchored literal rules, by the depth they are anchored at. A literal pattern can
        // only match the path prefix of exactly its own depth, so a chain with 100 such rules costs one map
        // lookup per depth that holds a rule — not 100 rule tests — and a depth the path cannot reach costs
        // nothing. The same lookup also rejects a rule whose literal is not a prefix, which is the case the
        // first-segment prune cannot see (`java/fory-0/...` and `java/fory-1/...` share their first segment).
        if (self.literal_dir_mask != 0) {
            var depth: usize = 0;
            var cursor: usize = 0;
            while (cursor <= path.len) {
                const slash = nextSeparator(path, cursor);
                depth += 1;
                const last_segment = slash == path.len;
                if (last_segment and !is_dir) break;
                if (depth < 256 and
                    (self.literal_dir_mask & (@as(u256, 1) << @intCast(depth))) != 0)
                {
                    if (self.literal_dirs.get(path[0..slash])) |at| {
                        if (best == null or at < best.?) best = at;
                    }
                }
                if (last_segment) break;
                cursor = slash + 1;
            }
        }

        for (self.suffixes) |entry| {
            if (best) |limit| if (entry.at > limit) break;
            if (base.len >= entry.suffix.len and std.mem.endsWith(u8, base, entry.suffix)) {
                best = entry.at;
                break;
            }
        }
        for (self.wilds) |entry| {
            if (best) |limit| if (entry.at > limit) break;
            if (chainRuleMatches(entry.rule, path, base, is_dir)) {
                best = entry.at;
                break;
            }
        }
        for (self.anchored) |entry| {
            if (best) |limit| if (entry.at > limit) break;
            if (chainRuleMatches(entry.rule, path, base, is_dir)) {
                best = entry.at;
                break;
            }
        }

        if (best) |at| return !self.items[at].negated;
        return null;
    }
};
fn chainRuleMatches(rule: gitignore.Rule, path: []const u8, base: []const u8, is_dir: bool) bool {
{//chain-anchored-prune
    if (rule.first_segment) |head| {
        const path_first = path[0..(std.mem.indexOfScalar(u8, path, '/') orelse path.len)];
        if (!std.mem.eql(u8, head, path_first)) return false;
    }
    if (!rule.directory_only) return chainMatchText(rule, if (rule.anchored) path else base);
    // An unanchored `pat/` names a directory at any level *below its own file*, so the path's own base name
    // is the only thing it can be tested against here; a matching ancestor is `dirState`'s inherited fact.
    // Testing whole path prefixes is how the indexed matcher missed a nested `out/` and could match a
    // segment above the rule file's scope (`a/.gitignore` holding `a/` does not exclude `a/x`).
    if (!rule.anchored) return is_dir and chainMatchText(rule, base);
    if (is_dir and chainMatchText(rule, path)) return true;
    var index: usize = 0;
    while (index < path.len) : (index += 1) {
        if (path[index] == '/') {
            if (chainMatchText(rule, path[0..index])) return true;
        }
    }
    return false;
}
}

fn chainMatchText(rule: gitignore.Rule, text: []const u8) bool {
    return switch (rule.kind) {
        .literal => std.mem.eql(u8, rule.glob, text),
        .suffix => text.len >= rule.suffix.len and std.mem.endsWith(u8, text, rule.suffix),
        .glob => gitignore.globMatch(rule.glob, text),
    };
}

/// `chainRuleMatches` with the historical recursive `**` matcher instead of the segment DP. Only
/// `decideNaive` calls this.
fn chainRuleMatchesNaive(rule: gitignore.Rule, path: []const u8, base: []const u8, is_dir: bool) bool {
    if (!rule.directory_only) return chainMatchTextNaive(rule, if (rule.anchored) path else base);
    // The historical branch tested the whole path and its prefixes, so an unanchored `out/` never saw the
    // base name of a nested directory (`b/d/out`) — git excludes it. An unanchored `pat/` names a directory
    // at any level below its file, so its own base name is what it is tested against; an excluded ancestor
    // is `decideNaive`'s walk, not this check.
    if (!rule.anchored) return is_dir and chainMatchTextNaive(rule, base);
    if (is_dir and chainMatchTextNaive(rule, path)) return true;
    var index: usize = 0;
    while (index < path.len) : (index += 1) {
        if (path[index] == '/') {
            if (chainMatchTextNaive(rule, path[0..index])) return true;
        }
    }
    return false;
}

fn chainMatchTextNaive(rule: gitignore.Rule, text: []const u8) bool {
    return switch (rule.kind) {
        .literal => std.mem.eql(u8, rule.glob, text),
        .suffix => text.len >= rule.suffix.len and std.mem.endsWith(u8, text, rule.suffix),
        .glob => gitignore.globMatchNaive(rule.glob, text),
    };
}

/// The final segment of a `/`-separated path.
fn baseName(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

/// The directory part of a `/`-separated path: everything before its last slash, `""` at the root. For a path
/// in the contract — `/`-separated, no leading or trailing slash — this is exactly `std.fs.path.dirname`, and
/// it is the string the old ancestor walk's largest prefix ended at.
fn dirOf(rel_path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, rel_path, '/') orelse return "";
    return rel_path[0..slash];
}

/// The number of `/`-separated segments in a rule's literal glob — the depth at which the literal can match a
/// path prefix. Only literal globs are indexed; a glob with a wildcard has no single depth to key on.
fn patternDepth(glob: []const u8) usize {
    var depth: usize = 1;
    for (glob) |byte| if (byte == '/') {
        depth += 1;
    };
    return depth;
}
/// The next `/` in `text` at or after `start`, or `text.len`. A plain byte scan, because the segments here are
/// a handful of bytes long and `std.mem.indexOfScalarPos` is vectorised for the long searches it was written
/// for: on the `backtrack` workload's 42-segment paths this one walk was 20 ms and the manual scan 3.6 ms.
fn nextSeparator(text: []const u8, start: usize) usize {
    var index = start;
    while (index < text.len and text[index] != '/') index += 1;
    return index;
}
pub const Stack = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    /// The tree's root as the engine received it; every `.gitignore` scope is measured against it.
    root: []const u8,
    respect: bool,
    /// Parsed rules by the absolute path of the directory that owns the file.
    rules: std.StringArrayHashMapUnmanaged(gitignore.Rules) = .empty,
    /// Directories whose `.gitignore` has been looked for, so a miss costs one `openFile` per pass.
    checked: std.StringArrayHashMapUnmanaged(void) = .empty,
    /// Flattened matchers, by the directory of their deepest rules file.
    chains: std.StringHashMapUnmanaged(*Chain) = .{},
    /// One reused buffer for the path handed to a chain: an entry lookup must not allocate.
    scratch: std.ArrayListUnmanaged(u8) = .empty,
    /// The same, for the absolute directory a root-relative `decide` asks a chain about. A three-valued
    /// decision walks the ancestors, so this is hit once per level per path and must not allocate.
    path_scratch: std.ArrayListUnmanaged(u8) = .empty,
    /// What a decision needs to know about its path's directory, keyed by that directory. A path list visits the
    /// same directories many times, and the rules are a snapshot, so both facts cannot change under this stack.
    dir_states: std.HashMapUnmanaged([]const u8, DirState, DirKeyContext, std.hash_map.default_max_load_percentage) = .{},
    /// The same cache for `decideNaive`, kept apart so the two implementations cannot hide a disagreement.
    excluded_dirs_naive: std.StringHashMapUnmanaged(bool) = .{},

    pub fn init(arena: std.mem.Allocator, io: std.Io, root: []const u8, respect: bool) Stack {
        return .{ .arena = arena, .io = io, .root = root, .respect = respect };
    }

    pub fn deinit(self: *Stack) void {
        for (self.rules.values()) |*parsed| parsed.deinit();
        self.rules.deinit(self.arena);
        self.checked.deinit(self.arena);
        self.scratch.deinit(self.arena);
        self.path_scratch.deinit(self.arena);
        self.dir_states.deinit(self.arena);
        self.excluded_dirs_naive.deinit(self.arena);
        var it = self.chains.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.literals.deinit(self.arena);
            entry.value_ptr.*.literals_dir_only.deinit(self.arena);
            entry.value_ptr.*.literal_dirs.deinit(self.arena);
            self.arena.free(entry.value_ptr.*.suffixes);
            self.arena.free(entry.value_ptr.*.wilds);
            self.arena.free(entry.value_ptr.*.anchored);
            self.arena.free(entry.value_ptr.*.items);
            self.arena.destroy(entry.value_ptr.*);
        }
        self.chains.deinit(self.arena);
    }

    /// Whether any `.gitignore` from the root down to `dir_path` has rules. Answered once per directory, so the
    /// per-entry path can skip the whole matcher when the answer is no — which is the common case.
    pub fn hasRules(self: *Stack, dir_path: []const u8) !bool {
        if (!self.respect) return false;
        var dir: []const u8 = dir_path;
        while (true) {
            if (try self.rulesFor(dir)) |parsed| {
                if (parsed.ruleCount() > 0) return true;
            }
            if (dir.len <= self.root.len) return false;
            const parent = std.fs.path.dirname(dir) orelse return false;
            if (parent.len >= dir.len) return false;
            dir = parent;
        }
    }

    /// Whether the child `name` of `dir_path` is visible to the engine under the `.gitignore` files that govern it.
    /// `dir_path` is an OS path (the root joined with the relative directory), as the lister receives it.
    pub fn ignored(self: *Stack, dir_path: []const u8, name: []const u8, is_dir: bool) !bool {
        if (!self.respect) return false;
        const chain = (try self.chainFor(dir_path)) orelse return false;
        if (chain.items.len == 0) return false;
        const rel_dir = self.relOf(dir_path);
        self.scratch.clearRetainingCapacity();
        if (rel_dir.len > 0) {
            try self.scratch.appendSlice(self.arena, rel_dir);
            try self.scratch.append(self.arena, '/');
        }
        try self.scratch.appendSlice(self.arena, name);
        return chain.decide(self.scratch.items, name, is_dir) orelse false;
    }

    /// What the chain decides about `rel_path`, a `/`-separated path relative to the stack's root and, as
    /// `Rules.decide` documents, with no leading or trailing slash.
    ///
    /// `true` means excluded, `false` means the deepest file with an opinion re-includes it, and `null` means
    /// no `.gitignore` has an opinion — which is **not** "included", because the caller may have a default.
    ///
    /// An excluded **ancestor directory** excludes the path below it, because git never enters the directory:
    /// no rule inside it can re-include anything. Both that question and the path's chain are properties of the
    /// path's directory, so they are answered once per directory by `dirState` and then cost one lookup — the
    /// ancestor walk and the upward rules-file walk used to be repeated for every path.
    pub fn decide(self: *Stack, rel_path: []const u8, is_dir: bool) !?bool {
        if (!self.respect) return null;
        const dir = dirOf(rel_path);
        const state = try self.dirState(dir);
        if (state.ancestor_excluded) return true;
        // `dirOf` is `dirname` for every path in the contract. A path outside it keeps the historical answer,
        // which looked the chain up by `dirname`, so the index cannot change a decision already being made.
        const dirname = std.fs.path.dirname(rel_path) orelse "";
        if (dirname.len != dir.len) return self.decideOne(rel_path, is_dir);
        const chain = state.chain orelse return null;
        if (chain.items.len == 0) return null;
        return chain.decide(rel_path, baseName(rel_path), is_dir);
    }

    /// The chain and ancestor answer for `rel_dir`, computed once per directory and answered from the map after
    /// that. The ancestor answer is inherited: a directory is excluded when its parent is, or when its own
    /// decision through the parent's chain excludes it — which is exactly the prefix set the old walk asked.
    fn dirState(self: *Stack, rel_dir: []const u8) !DirState {
        if (self.dir_states.get(rel_dir)) |state| return state;
        var state: DirState = .{ .chain = null, .ancestor_excluded = false };
        if (rel_dir.len > 0) {
            const parent_state = try self.dirState(dirOf(rel_dir));
            state.ancestor_excluded = parent_state.ancestor_excluded or
                ((try self.decideOne(rel_dir, true)) orelse false);
        }
        // An excluded directory is never entered, so no rule below it can matter and its chain is not resolved.
        if (!state.ancestor_excluded) state.chain = try self.chainForRel(rel_dir);
        try self.dir_states.put(self.arena, try self.arena.dupe(u8, rel_dir), state);
        return state;
    }

    fn ancestorExcludedNaive(self: *Stack, rel_dir: []const u8) !bool {
        if (self.excluded_dirs_naive.get(rel_dir)) |excluded| return excluded;
        const excluded = (try self.decideOneNaive(rel_dir, true)) orelse false;
        try self.excluded_dirs_naive.put(self.arena, try self.arena.dupe(u8, rel_dir), excluded);
        return excluded;
    }

    fn decideOne(self: *Stack, rel_path: []const u8, is_dir: bool) !?bool {
        const chain = (try self.chainForRel(std.fs.path.dirname(rel_path) orelse "")) orelse return null;
        if (chain.items.len == 0) return null;
        return chain.decide(rel_path, baseName(rel_path), is_dir);
    }

    /// The historical `decide`: test every rule of the chain, in precedence order, with the recursive `**`
    /// matcher. This is the design that was superlinear in a real tree; it exists for `-Dnaive=true` bench
    /// builds, and the default executable never calls it (the tests do, so it cannot rot).
    pub fn decideNaive(self: *Stack, rel_path: []const u8, is_dir: bool) !?bool {
        if (!self.respect) return null;
        var index: usize = 0;
        while (index < rel_path.len) : (index += 1) {
            if (rel_path[index] != '/') continue;
            if (try self.ancestorExcludedNaive(rel_path[0..index])) return true;
        }
        return self.decideOneNaive(rel_path, is_dir);
    }

    fn decideOneNaive(self: *Stack, rel_path: []const u8, is_dir: bool) !?bool {
        const chain = (try self.chainForRel(std.fs.path.dirname(rel_path) orelse "")) orelse return null;
        const name = baseName(rel_path);
        for (chain.items) |rule| {
            if (chainRuleMatchesNaive(rule, rel_path, name, is_dir)) return !rule.negated;
        }
        return null;
    }

    /// The chain governing a root-relative directory, with the absolute path the readers need.
    fn chainForRel(self: *Stack, rel_dir: []const u8) !?*Chain {
        if (rel_dir.len == 0) return self.chainFor(self.root);
        self.path_scratch.clearRetainingCapacity();
        try self.path_scratch.appendSlice(self.arena, self.root);
        const last = if (self.root.len > 0) self.root[self.root.len - 1] else '/';
        if (last != '/' and last != '\\') try self.path_scratch.append(self.arena, '/');
        try self.path_scratch.appendSlice(self.arena, rel_dir);
        return self.chainFor(self.path_scratch.items);
    }

    /// The flattened matcher for `dir_path`, built once per deepest rules file and cached there.
    fn chainFor(self: *Stack, dir_path: []const u8) !?*Chain {
        var deepest: ?[]const u8 = null;
        var dir: []const u8 = dir_path;
        while (true) {
            if (try self.rulesFor(dir)) |parsed| {
                if (parsed.ruleCount() > 0) {
                    deepest = dir;
                    break;
                }
            }
            if (dir.len <= self.root.len) break;
            const parent = std.fs.path.dirname(dir) orelse break;
            if (parent.len >= dir.len) break;
            dir = parent;
        }
        const key = deepest orelse return null;
        if (self.chains.get(key)) |chain| return chain;

        // Deepest first, each file reversed; anchored patterns scoped with their owner's path.
        var items: std.ArrayListUnmanaged(gitignore.Rule) = .empty;
        var suffixes: std.ArrayListUnmanaged(SuffixEntry) = .empty;
        var wilds: std.ArrayListUnmanaged(RuleEntry) = .empty;
        var anchored: std.ArrayListUnmanaged(RuleEntry) = .empty;
        var chain = try self.arena.create(Chain);
        chain.* = .{ .items = &.{} };
        var walk: []const u8 = key;
        while (true) {
            if (try self.rulesFor(walk)) |parsed| {
                const base_rel = self.relOf(walk);
                var index = parsed.items.len;
                while (index > 0) {
                    index -= 1;
                    var rule = parsed.items[index];
                    if (rule.anchored and base_rel.len > 0) {
                        rule.glob = try std.fmt.allocPrint(self.arena, "{s}/{s}", .{ base_rel, rule.glob });
                    }
                    if (rule.anchored) {
                        // The parse-time value described the pattern before this scope was prepended, so it is
                        // recomputed here: a literal first segment rejects a path outside that subtree with one
                        // comparison instead of a prefix walk.
                        const slash = std.mem.indexOfScalar(u8, rule.glob, '/') orelse rule.glob.len;
                        const head = rule.glob[0..slash];
                        const wild = head.len == 0 or head[0] == '*' or head[0] == '?' or head[0] == '[';
                        rule.first_segment = if (wild) null else head;
                    }
                    const position = items.items.len;
                    try items.append(self.arena, rule);
                    if (rule.kind == .literal and !rule.anchored) {
                        const map = if (rule.directory_only) &chain.literals_dir_only else &chain.literals;
                        if (!map.contains(rule.glob)) try map.put(self.arena, rule.glob, position);
                    } else if (rule.anchored) {
                        // A directory-only anchored literal is a whole prefix directory, so it is indexed by
                        // that literal instead of joining the scanned list. An exact anchored literal stays in
                        // the list: a chain holds one or two of them, and one comparison beats an index walk.
                        // A pattern with 256 or more segments also stays: the mask cannot address it, and
                        // correctness comes first for a shape no real `.gitignore` has.
                        const depth = if (rule.kind == .literal) patternDepth(rule.glob) else 0;
                        if (rule.kind == .literal and rule.directory_only and depth < 256) {
                            const entry = try chain.literal_dirs.getOrPut(self.arena, rule.glob);
                            if (!entry.found_existing) entry.value_ptr.* = position;
                            chain.literal_dir_mask |= @as(u256, 1) << @intCast(depth);
                        } else {
                            try anchored.append(self.arena, .{ .rule = rule, .at = position });
                        }
                    } else if (rule.kind == .suffix) {
                        try suffixes.append(self.arena, .{ .suffix = rule.suffix, .at = position });
                    } else {
                        try wilds.append(self.arena, .{ .rule = rule, .at = position });
                    }
                }
            }
            if (walk.len <= self.root.len) break;
            const parent = std.fs.path.dirname(walk) orelse break;
            if (parent.len >= walk.len) break;
            walk = parent;
        }
        chain.items = try items.toOwnedSlice(self.arena);
        chain.suffixes = try suffixes.toOwnedSlice(self.arena);
        chain.wilds = try wilds.toOwnedSlice(self.arena);
        chain.anchored = try anchored.toOwnedSlice(self.arena);
        // The key can point into the caller's scratch buffer, so the cache owns its own copy.
        try self.chains.put(self.arena, try self.arena.dupe(u8, key), chain);
        return chain;
    }

    /// The path of `path` relative to the root, `""` for the root itself.
    fn relOf(self: *Stack, path: []const u8) []const u8 {
        if (self.root.len == 0) return path;
        if (path.len <= self.root.len) return "";
        const last = self.root[self.root.len - 1];
        const skip: usize = if (last == '/' or last == '\\') 0 else 1;
        return path[self.root.len + skip ..];
    }


    /// The rules of `dir`'s own `.gitignore`, or `null` when it has none. Looked for once per directory.
    fn rulesFor(self: *Stack, dir: []const u8) !?gitignore.Rules {
        if (self.checked.contains(dir)) return self.rules.get(dir);
        try self.checked.put(self.arena, try self.arena.dupe(u8, dir), {});

        const file_path = if (dir.len == 0)
            gitignore.file_name
        else
            try std.fmt.allocPrint(self.arena, "{s}/{s}", .{ dir, gitignore.file_name });
        const text = std.Io.Dir.cwd().readFileAlloc(self.io, file_path, self.arena, std.Io.Limit.limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound, error.IsDir, error.NotDir => return null,
            else => return err,
        };
        const parsed = try gitignore.Rules.parse(self.arena, text);
        try self.rules.put(self.arena, try self.arena.dupe(u8, dir), parsed);
        return parsed;
    }
};

test "the deepest .gitignore wins, and a negation re-includes" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "*.log\n!keep.log\nbuild/\n" });
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.createDirPath(io, "build");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/.gitignore", .data = "!keep.log\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "x.log", .data = "x\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "keep.log", .data = "k\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/keep.log", .data = "k\n" });

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const count = try tmp.dir.realPath(io, &path_buffer);
    const root = path_buffer[0..count];
    const src = try std.fmt.allocPrint(testing.allocator, "{s}/src", .{root});
    defer testing.allocator.free(src);

    var arena_alloc = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    var stack = Stack.init(arena, io, root, true);
    defer stack.deinit();

    try testing.expect(try stack.ignored(root, "x.log", false));
    try testing.expect(!try stack.ignored(root, "keep.log", false)); // the root's own negation
    try testing.expect(!try stack.ignored(src, "keep.log", false)); // re-included from below
    try testing.expect(try stack.ignored(root, "build", true));
    try testing.expect(!try stack.ignored(root, ".gitignore", false)); // the rule file itself is visible

    // The three-valued form: the same answers, plus the absence of an opinion, and an excluded ancestor
    // excludes what is below it even when a negation would re-include the file from inside.
    try testing.expectEqual(@as(?bool, true), try stack.decide("x.log", false));
    try testing.expectEqual(@as(?bool, false), try stack.decide("keep.log", false));
    try testing.expectEqual(@as(?bool, false), try stack.decide("src/keep.log", false));
    try testing.expectEqual(@as(?bool, true), try stack.decide("build/x.txt", false));
    try testing.expectEqual(@as(?bool, null), try stack.decide("other.txt", false));

    // The historical path to the same answers, kept for the bench build.
    try testing.expectEqual(@as(?bool, true), try stack.decideNaive("x.log", false));
    try testing.expectEqual(@as(?bool, false), try stack.decideNaive("src/keep.log", false));
    try testing.expectEqual(@as(?bool, true), try stack.decideNaive("build/x.txt", false));
    try testing.expectEqual(@as(?bool, null), try stack.decideNaive("other.txt", false));

    var off = Stack.init(arena, io, root, false);
    defer off.deinit();
    try testing.expect(!try off.ignored(root, "x.log", false)); // respect = false lists everything
    try testing.expectEqual(@as(?bool, null), try off.decide("x.log", false));
}

test "an unanchored directory-only literal matches a nested directory, and a negation re-includes it" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "exclude");
    try tmp.dir.createDirPath(io, "negate");
    try tmp.dir.writeFile(io, .{ .sub_path = "exclude/.gitignore", .data = "out/\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "negate/.gitignore", .data = "!out/\n" });

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const count = try tmp.dir.realPath(io, &path_buffer);
    const root = path_buffer[0..count];

    var arena_alloc = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    // The gap the differential fuzz found: the indexed chain saw the `out` segment, `decideNaive` did not.
    var exclude = Stack.init(arena, io, try std.fmt.allocPrint(arena, "{s}/exclude", .{root}), true);
    defer exclude.deinit();
    try testing.expectEqual(@as(?bool, true), try exclude.decide("b/d/out", true));
    try testing.expectEqual(@as(?bool, true), try exclude.decideNaive("b/d/out", true));
    // Directory-only still means a file named `out` is not the thing the pattern names.
    try testing.expectEqual(@as(?bool, null), try exclude.decide("b/d/out", false));
    try testing.expectEqual(@as(?bool, null), try exclude.decideNaive("b/d/out", false));

    // The same match with a negation in the file: the deepest file's last matching pattern re-includes it.
    var negate = Stack.init(arena, io, try std.fmt.allocPrint(arena, "{s}/negate", .{root}), true);
    defer negate.deinit();
    try testing.expectEqual(@as(?bool, false), try negate.decide("b/d/out", true));
    try testing.expectEqual(@as(?bool, false), try negate.decideNaive("b/d/out", true));
}

test "a nested file's rule cannot match a segment above that file" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "a");
    // In `a/.gitignore`, `a/` names a child directory `a/a`; it does not name the `a` the file lives in, so
    // it cannot exclude `a/x`. git agrees (`git check-ignore a/x` is silent, `a/a` is excluded).
    try tmp.dir.writeFile(io, .{ .sub_path = "a/.gitignore", .data = "a/\n" });

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const count = try tmp.dir.realPath(io, &path_buffer);
    const root = path_buffer[0..count];

    var arena_alloc = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_alloc.deinit();
    var stack = Stack.init(arena_alloc.allocator(), io, root, true);
    defer stack.deinit();

    try testing.expectEqual(@as(?bool, null), try stack.decide("a/x", false));
    try testing.expectEqual(@as(?bool, null), try stack.decideNaive("a/x", false));
    try testing.expectEqual(@as(?bool, true), try stack.decide("a/a", true));
    try testing.expectEqual(@as(?bool, true), try stack.decideNaive("a/a", true));
}
