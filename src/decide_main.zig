// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! `ignore-decide` — the bench contract as a program, so any port (Java, JS, Zig) can be timed on the same bytes.
//!
//! ```text
//! ignore-decide --rules <file.gitignore> --paths <file> [--dirs <file>] [--root <dir>]
//!     one line per path, in input order: include | exclude | no-opinion
//! ```
//!
//! `bench/perf.mjs` spawns this once per workload with `{rules}` and `{paths}` substituted. The rules are written
//! into the root as that root's `.gitignore`, because the chain reads files rather than text: measuring a matcher
//! through the same file-reading path every port must implement is the point of the contract, and it keeps this
//! CLI honest about the one thing a port cannot skip.
//!
//! Exactly one line per input path reaches stdout and nothing else does, so the runner's verdict-count check is
//! meaningful. The stack is built once for the whole list; no rule is re-parsed per path.
//!
//! ## Inputs
//!
//! `--paths` holds one root-relative, `/`-separated path per line. A trailing CR is transport rather than part
//! of a path, and a blank line is skipped instead of read as the empty path. The file may be empty, which prints
//! nothing at all.
//!
//! `--dirs` holds one flag per path, in input order: `1` = the path is a directory, `0` = a file. That is the
//! contract's "one character per path". Line breaks are transport, so one flag per line and a single line of
//! flags are the same input; a file holding a single flag applies it to every path, which is how "a line of `1`
//! for every path" is accepted. Without `--dirs` every path is a file, as the contract's default says.
//!
//! ## Root
//!
//! `--root <dir>` uses that directory as the root: it is created if missing, its `.gitignore` is overwritten, and
//! it is left in place, because it belongs to the caller. Without `--root` a fresh unique directory is created
//! under the system temporary directory (`TMPDIR`, `TEMP`, then `TMP`) and removed on the way out. A sandbox that
//! grants a spawned process only the workspace can deny that directory (`AccessDenied`), so the working directory
//! is the fallback: a bench that cannot start would otherwise look like a slow port rather than a denied one.
//!
//! A usage error prints one short line plus the usage on stderr and exits 1, so it can never be mistaken for a
//! short but valid answer list; every input is read before the root is created, so a usage error leaves no
//! directory behind. Nothing is read from stdin. The answers are buffered in memory and written in one call,
//! because a syscall per line would be measured as part of the matcher.
//!
//! ## The historical matcher
//!
//! `-Dnaive=true` in `build.zig` installs this same program as `ignore-decide-naive`, so the historical design
//! (every rule scanned, `**` matched by the recursive backtracker) can be timed beside the indexed one. This file
//! cannot import `build_options` without making `zig run src/decide_main.zig` impossible, so the artifact name is
//! the switch, and `--naive` states the choice explicitly when the binary has been copied under another name.

const std = @import("std");
const ignore = @import("ignore.zig");

const usage =
    \\ignore-decide — answer the .gitignore bench contract
    \\
    \\usage:
    \\  ignore-decide --rules <file.gitignore> --paths <file> [--dirs <file>] [--root <dir>]
    \\
    \\output:
    \\  one line per path, in input order: include | exclude | no-opinion
    \\
    \\options:
    \\  --rules <file>   the .gitignore to apply (written as <root>/.gitignore)
    \\  --paths <file>   one root-relative, /-separated path per line
    \\  --dirs <file>    one 0/1 per path (0 = file, 1 = directory); default: all files
    \\  --root <dir>     use this directory as the root instead of a temporary one
    \\  --naive          the historical matcher (the bench aid `-Dnaive=true` builds)
    \\
;

/// A `.gitignore` this CLI will apply is small; a workload's path list is not, but 64 MiB is far past any
/// workload and still a bound, so a wrong argument fails loudly instead of exhausting memory.
const rules_limit = 1 << 20;
const dirs_limit = 1 << 20;
const paths_limit = 1 << 26;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next(); // the program itself

    var rules_path: ?[]const u8 = null;
    var paths_path: ?[]const u8 = null;
    var dirs_path: ?[]const u8 = null;
    var root_path: ?[]const u8 = null;
    var naive_flag = false;
    var rounds: u32 = 1;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--rules")) {
            rules_path = args.next() orelse fail(io, gpa, "--rules needs a file");
        } else if (std.mem.eql(u8, arg, "--paths")) {
            paths_path = args.next() orelse fail(io, gpa, "--paths needs a file");
        } else if (std.mem.eql(u8, arg, "--dirs")) {
            dirs_path = args.next() orelse fail(io, gpa, "--dirs needs a file");
        } else if (std.mem.eql(u8, arg, "--root")) {
            root_path = args.next() orelse fail(io, gpa, "--root needs a directory");
        } else if (std.mem.eql(u8, arg, "--naive")) {
            naive_flag = true;
        } else if (std.mem.eql(u8, arg, "--rounds")) {
            const given = args.next() orelse fail(io, gpa, "--rounds needs a count");
            rounds = std.fmt.parseInt(u32, given, 10) catch fail(io, gpa, "--rounds needs a count");
            if (rounds == 0) rounds = 1;
        } else {
            fail(io, gpa, "unknown option (only --rules, --paths, --dirs, --root and --naive are accepted)");
        }
    }

    const rules_file = rules_path orelse fail(io, gpa, "--rules is required");
    const paths_file = paths_path orelse fail(io, gpa, "--paths is required");

    // Every input is read and checked before the root exists, so a usage error leaves no directory behind.
    const rules_text = readInput(io, gpa, rules_file, rules_limit) catch |err| failFile(io, gpa, rules_file, err);
    defer gpa.free(rules_text);

    const paths_text = readInput(io, gpa, paths_file, paths_limit) catch |err| failFile(io, gpa, paths_file, err);
    defer gpa.free(paths_text);

    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(gpa);
    var lines = std.mem.splitScalar(u8, paths_text, '\n');
    while (lines.next()) |raw| {
        const path = trimCr(raw);
        if (path.len == 0) continue;
        try paths.append(gpa, path);
    }

    var dir_flags: std.ArrayList(u8) = .empty;
    defer dir_flags.deinit(gpa);
    if (dirs_path) |dirs_file| {
        const dirs_text = readInput(io, gpa, dirs_file, dirs_limit) catch |err| failFile(io, gpa, dirs_file, err);
        defer gpa.free(dirs_text);
        for (dirs_text) |flag| switch (flag) {
            '0', '1' => try dir_flags.append(gpa, flag),
            '\n', '\r' => {},
            else => fail(io, gpa, "--dirs must hold only 0 and 1, one flag per path"),
        };
        if (dir_flags.items.len != 1 and dir_flags.items.len != paths.items.len) {
            fail(io, gpa, "--dirs must hold one 0/1 per --paths line (or one flag for every path)");
        }
    }

    // The root: the caller's directory, or a fresh unique one under the system temporary directory, with the
    // working directory as the fallback when that directory cannot be created.
    const root_owned = root_path == null;
    const root = if (root_path) |given| blk: {
        std.Io.Dir.cwd().createDirPath(io, given) catch |err| failFile(io, gpa, given, err);
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const count = std.Io.Dir.cwd().realPathFile(io, given, &buffer) catch |err| failFile(io, gpa, given, err);
        break :blk try gpa.dupe(u8, buffer[0..count]);
    } else blk: {
        const created = makeTempRoot(io, gpa, tempBase(init)) catch
            makeTempRoot(io, gpa, ".") catch |err| failFile(io, gpa, "a temporary root", err);
        break :blk created;
    };
    defer {
        if (root_owned) std.Io.Dir.cwd().deleteTree(io, root) catch {};
        gpa.free(root);
    }

    const rules_target = try std.fs.path.join(gpa, &.{ root, ".gitignore" });
    defer gpa.free(rules_target);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = rules_target, .data = rules_text }) catch |err|
        failFile(io, gpa, rules_target, err);

    var arena_alloc = std.heap.ArenaAllocator.init(gpa);
    defer arena_alloc.deinit();
    var stack = ignore.Stack.init(arena_alloc.allocator(), io, root, true);
    defer stack.deinit();

    const naive = naive_flag or builtAsNaive(io, gpa);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, paths.items.len * 12); // "no-opinion\n" is the longest verdict

    for (paths.items, 0..) |path, index| {
        const is_dir = if (dir_flags.items.len == 0)
            false
        else if (dir_flags.items.len == 1)
            dir_flags.items[0] == '1'
        else
            dir_flags.items[index] == '1';
        // `--rounds N` repeats the decision N times and prints one verdict, so a measurement can be steady state.
        var verdict: ?bool = null;
        var repeat: u32 = 0;
        while (repeat < rounds) : (repeat += 1) {
            verdict = if (naive)
                try stack.decideNaive(path, is_dir)
            else
                try stack.decide(path, is_dir);
        }
        try out.appendSlice(gpa, verdictName(verdict));
        try out.append(gpa, '\n');
    }

    // One write for the whole answer list: the bench times this process, so a syscall per line would be
    // measured as part of the matcher.
    try std.Io.File.stdout().writeStreamingAll(io, out.items);
}

fn readInput(io: std.Io, gpa: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, std.Io.Limit.limited(limit));
}

/// Where a temporary root may live. The system temporary directory is the normal home; a sandbox that grants
/// only the workspace can deny it to a spawned process, so the working directory is the fallback.
fn tempBase(init: std.process.Init) []const u8 {
    return init.environ_map.get("TMPDIR") orelse
        init.environ_map.get("TEMP") orelse
        init.environ_map.get("TMP") orelse ".";
}

/// Creates `<base>/.gitignore-decide-<id>-<token>` and returns its path, owned by the caller.
///
/// The token is random per process, so two ports timed in parallel never share a root, and the thread id keeps
/// the name distinct even if the random source were to repeat.
fn makeTempRoot(io: std.Io, gpa: std.mem.Allocator, base: []const u8) ![]u8 {
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    var token: [std.base64.url_safe_no_pad.Encoder.calcSize(random_bytes.len)]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&token, &random_bytes);
    const name = try std.fmt.allocPrint(gpa, ".gitignore-decide-{d}-{s}", .{ std.Thread.getCurrentId(), token });
    defer gpa.free(name);
    const path = try std.fs.path.join(gpa, &.{ base, name });
    errdefer gpa.free(path);
    try std.Io.Dir.cwd().createDirPath(io, path);
    return path;
}

/// Whether this binary is the historical-matcher build. `build.zig` names that artifact `ignore-decide-naive`,
/// which is the only switch available without importing `build_options` (which `zig run` cannot supply).
fn builtAsNaive(io: std.Io, gpa: std.mem.Allocator) bool {
    const path = std.process.executablePathAlloc(io, gpa) catch return false;
    defer gpa.free(path);
    const name = std.fs.path.stem(std.fs.path.basename(path));
    return std.mem.eql(u8, name, "ignore-decide-naive");
}

fn verdictName(verdict: ?bool) []const u8 {
    if (verdict) |excluded| return if (excluded) "exclude" else "include";
    return "no-opinion";
}

/// A CRLF line ending is part of the transport, not part of a path or a flag.
fn trimCr(line: []const u8) []const u8 {
    return if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
}

fn fail(io: std.Io, allocator: std.mem.Allocator, message: []const u8) noreturn {
    const text = std.fmt.allocPrint(allocator, "ignore-decide: {s}\n{s}", .{ message, usage }) catch null;
    std.Io.File.stderr().writeStreamingAll(io, text orelse "ignore-decide: usage error\n") catch {};
    std.process.exit(1);
}

fn failFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, err: anyerror) noreturn {
    const message = std.fmt.allocPrint(allocator, "cannot use {s}: {s}", .{ path, @errorName(err) }) catch null;
    fail(io, allocator, message orelse "cannot use its input files");
}
