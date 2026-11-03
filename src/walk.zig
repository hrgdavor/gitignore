// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! A recursive directory walk that respects `.gitignore` files.
//!
//! It lists a tree, reads each directory's `.gitignore`, and visits only the files git would consider
//! "ours". A directory that is ignored is **not entered** — git's rule, and where the speed comes from:
//! a `node_modules/` with 40,000 files costs one directory read and one decision, not 40,000.
//!
//! This is the utility a project that does not want to depend on `fs-meta` can use to get fast,
//! gitignore-aware traversal. The visitor receives `/`-separated paths relative to the root, with no
//! leading slash:
//!
//! ```zig
//! var list = walk.List.init(allocator);
//! defer list.deinit();
//! try walk.walk(io, allocator, "src", .{}, &list);
//! for (list.items.items) |name| std.debug.print("{s}\n", .{name});
//! ```
//!
//! ## What this module owns, and what it does not
//!
//! It owns the *stack*: the `.gitignore` of the directory being entered is pushed, its files are decided
//! against the whole stack (deepest file first, so a nested `!keep.tmp` re-includes what an outer
//! `*.tmp` excluded), and it is popped on the way out. `gitignore.zig` owns one file's patterns.
//!
//! It does not follow symlinks unless asked: a link can point anywhere, including a parent directory,
//! and a walk that follows one can loop or escape the tree it was asked about.

const std = @import("std");
const gitignore = @import("gitignore.zig");

/// A name that is a repository's own metadata, never project content.
const dot_git = ".git";

pub const Options = struct {
    /// Enter symlinked directories (default off). Files that are symlinks are still reported, because
    /// git tracks a symlink as a file.
    follow_symlinks: bool = false,
    /// Skip a `.git` directory wherever one appears (default on). It is a repository's own metadata,
    /// and no project wants it in a list of its files.
    skip_dot_git: bool = true,
};

/// The visitor contract. `walk` calls `dir` for every directory it enters (before that directory's
/// entries) and `file` for every file git would keep; both receive a `/`-separated path relative to the
/// root. Return an error to abort the walk.
pub fn walk(io: std.Io, allocator: std.mem.Allocator, root: []const u8, options: Options, visitor: anytype) anyerror!void {
    var top = if (std.fs.path.isAbsolute(root))
        try std.Io.Dir.openDirAbsolute(io, root, .{ .iterate = true })
    else
        try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer top.close(io);

    var path: std.ArrayListUnmanaged(u8) = .empty;
    defer path.deinit(allocator);
    var stack: std.ArrayListUnmanaged(Frame) = .empty;
    defer stack.deinit(allocator);

    try walkDir(io, allocator, top, options, visitor, &path, &stack);
}

/// One directory's `.gitignore` and the prefix of the path buffer that names that directory.
const Frame = struct {
    dir_len: usize,
    rules: gitignore.Rules,
};

fn walkDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    options: Options,
    visitor: anytype,
    path: *std.ArrayListUnmanaged(u8),
    stack: *std.ArrayListUnmanaged(Frame),
) anyerror!void {
    // This directory's rules govern its entries and, through the stack, everything below them.
    // `readRules` returns an empty rule set when the directory has no `.gitignore`, so the push/pop
    // pairs stay balanced and a decision costs one call per file.
    var frame_rules = try readRules(io, allocator, dir);
    errdefer frame_rules.deinit();
    try stack.append(allocator, .{ .dir_len = path.items.len, .rules = frame_rules });
    defer {
        var popped = stack.pop().?;
        popped.rules.deinit();
    }

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (options.skip_dot_git and std.mem.eql(u8, entry.name, dot_git)) continue;

        const dir_len = path.items.len;
        if (dir_len > 0) try path.append(allocator, '/');
        try path.appendSlice(allocator, entry.name);
        // The candidate is the tail of `path`; restoring the length is the whole cleanup.
        defer path.shrinkRetainingCapacity(dir_len);

        switch (entry.kind) {
            .directory => {
                if (ignored(stack.items, path.items, true)) continue;
                try visitor.dir(path.items);
                try enterDir(io, allocator, dir, entry.name, options, visitor, path, stack);
            },
            .file => {
                if (!ignored(stack.items, path.items, false)) try visitor.file(path.items);
            },
            .sym_link => {
                if (!options.follow_symlinks) {
                    // git tracks a symlink as a file: it has content (the target name) and it is not
                    // descended. Reporting it keeps the list faithful to what `git ls-files` shows.
                    if (!ignored(stack.items, path.items, false)) try visitor.file(path.items);
                    continue;
                }
                const stat = dir.statFile(io, entry.name, .{ .follow_symlinks = true }) catch continue;
                switch (stat.kind) {
                    .directory => {
                        if (ignored(stack.items, path.items, true)) continue;
                        try visitor.dir(path.items);
                        try enterDir(io, allocator, dir, entry.name, options, visitor, path, stack);
                    },
                    .file => {
                        if (!ignored(stack.items, path.items, false)) try visitor.file(path.items);
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
}

fn enterDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    parent: std.Io.Dir,
    name: []const u8,
    options: Options,
    visitor: anytype,
    path: *std.ArrayListUnmanaged(u8),
    stack: *std.ArrayListUnmanaged(Frame),
) anyerror!void {
    var child = parent.openDir(io, name, .{ .iterate = true, .follow_symlinks = options.follow_symlinks }) catch |err| switch (err) {
        // A directory that cannot be listed cannot say what is in it. Failing the whole traversal for
        // one permission bit is worse than an incomplete answer, so it is skipped like an ignored one.
        error.FileNotFound, error.NotDir, error.AccessDenied => return,
        else => return err,
    };
    defer child.close(io);
    try walkDir(io, allocator, child, options, visitor, path, stack);
}

/// The directory's `.gitignore`, parsed; an empty rule set when it has none.
fn readRules(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir) !gitignore.Rules {
    const text: []const u8 = dir.readFileAlloc(io, gitignore.file_name, allocator, std.Io.Limit.limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound, error.IsDir, error.NotDir => return gitignore.Rules.parse(allocator, ""),
        else => return err,
    };
    defer allocator.free(text);
    return gitignore.Rules.parse(allocator, text);
}

/// Whether the deepest `.gitignore` that governs the path excludes it. `path.items` is the candidate
/// and each frame's `dir_len` slices out that frame's directory, so no path is rebuilt per decision.
fn ignored(stack: []const Frame, candidate: []const u8, is_dir: bool) bool {
    var index = stack.len;
    while (index > 0) {
        index -= 1;
        const frame = stack[index];
        // The path relative to the frame's directory; the frame governs the candidate only when the
        // candidate is at or below it, which the `dir_len` prefix and the separator check establish.
        const scoped: []const u8 = if (frame.dir_len == 0)
            candidate
        else if (candidate.len > frame.dir_len and candidate[frame.dir_len] == '/')
            candidate[frame.dir_len + 1 ..]
        else
            continue;
        if (frame.rules.decide(scoped, is_dir)) |excluded| return excluded;
    }
    return false;
}

/// A visitor that keeps every reported file in a list, in walk order. The second half of the visitor
/// contract (`dir`) is a no-op here.
pub const List = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) List {
        return .{ .allocator = allocator };
    }

    pub fn file(self: *List, rel_path: []const u8) !void {
        try self.items.append(self.allocator, try self.allocator.dupe(u8, rel_path));
    }

    pub fn dir(self: *List, rel_path: []const u8) !void {
        _ = self;
        _ = rel_path;
    }

    pub fn deinit(self: *List) void {
        for (self.items.items) |item| self.allocator.free(item);
        self.items.deinit(self.allocator);
    }
};

test "the walk lists the files git would keep and prunes an ignored directory" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "*.log\nbuild/\n" });
    try tmp.dir.createDirPath(io, "build");
    try tmp.dir.writeFile(io, .{ .sub_path = "build/x.txt", .data = "x\n" });
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "z\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "x.log", .data = "l\n" });

    var list = List.init(testing.allocator);
    defer list.deinit();

    // `walk` needs an iterator, and `tmpDir`'s handle is not opened with that ability.
    var root_dir = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer root_dir.close(io);

    // The handle is the root; walking it directly means the root path never enters a stored name.
    var path: std.ArrayListUnmanaged(u8) = .empty;
    defer path.deinit(testing.allocator);
    var stack: std.ArrayListUnmanaged(Frame) = .empty;
    defer stack.deinit(testing.allocator);
    try walkDir(io, testing.allocator, root_dir, .{}, &list, &path, &stack);

    try testing.expectEqual(@as(usize, 2), list.items.items.len);
    try testing.expect(contains(list.items.items, ".gitignore"));
    try testing.expect(contains(list.items.items, "src/main.zig"));
}

test "a nested .gitignore can re-include what the root excluded" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "*.log\n" });
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/.gitignore", .data = "!keep.log\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/keep.log", .data = "k\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/other.log", .data = "o\n" });

    var list = List.init(testing.allocator);
    defer list.deinit();

    var root_dir = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer root_dir.close(io);

    var path: std.ArrayListUnmanaged(u8) = .empty;
    defer path.deinit(testing.allocator);
    var stack: std.ArrayListUnmanaged(Frame) = .empty;
    defer stack.deinit(testing.allocator);
    try walkDir(io, testing.allocator, root_dir, .{}, &list, &path, &stack);

    try testing.expect(contains(list.items.items, "src/keep.log"));
    try testing.expect(!contains(list.items.items, "src/other.log"));
    try testing.expect(!contains(list.items.items, "x.log"));
}

fn contains(items: []const []const u8, needle: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, needle)) return true;
    return false;
}

test "a .git directory is skipped by default and reported when asked" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/main\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "z\n" });

    var root_dir = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer root_dir.close(io);

    var path: std.ArrayListUnmanaged(u8) = .empty;
    defer path.deinit(testing.allocator);
    var stack: std.ArrayListUnmanaged(Frame) = .empty;
    defer stack.deinit(testing.allocator);

    var kept = List.init(testing.allocator);
    defer kept.deinit();
    try walkDir(io, testing.allocator, root_dir, .{}, &kept, &path, &stack);
    try testing.expectEqual(@as(usize, 1), kept.items.items.len);
    try testing.expect(contains(kept.items.items, "main.zig"));

    var everything = List.init(testing.allocator);
    defer everything.deinit();
    try walkDir(io, testing.allocator, root_dir, .{ .skip_dot_git = false }, &everything, &path, &stack);
    try testing.expectEqual(@as(usize, 2), everything.items.items.len);
    try testing.expect(contains(everything.items.items, ".git/HEAD"));
}
