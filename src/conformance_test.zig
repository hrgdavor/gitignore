// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! The conformance vectors as a test.
//!
//! `conformance/gitignore-vectors.json` is the contract a port is measured against, and this file is what
//! makes a vector a check instead of prose. Each case is materialised as a real temporary tree — its
//! `ruleFiles` become `.gitignore` files under a root — and answered by the **chain**
//! (`ignore.Stack.decide`), because precedence, an excluded ancestor and the third value (`no-opinion`) are
//! chain behaviour rather than one file's matcher.
//!
//! The JSON is read at run time. A compile-time `@embedFile("../conformance/gitignore-vectors.json")` is
//! rejected: the module root is `src/`, so the vectors are outside the package path (verified against Zig
//! 0.17). The absolute path keeps the test independent of the working directory it is invoked from.

const std = @import("std");
const gitignore = @import("gitignore.zig");
const ignore = @import("ignore.zig");

const testing = std.testing;

/// The vectors, which live beside `src/` in the project this test belongs to.
const vectors_path = "D:/wrk/java/jcodebuddy/gitignore/conformance/gitignore-vectors.json";

/// One field of a JSON object, with the two failure modes named instead of panicking.
fn field(value: std.json.Value, name: []const u8) !std.json.Value {
    return switch (value) {
        .object => |object| object.get(name) orelse error.MissingField,
        else => error.NotAnObject,
    };
}

/// The three answers a vector may carry, and the implementation's mapping onto them.
fn verdictName(verdict: ?bool) []const u8 {
    if (verdict) |excluded| return if (excluded) "exclude" else "include";
    return "no-opinion";
}

test "every conformance vector answers as it expects" {
    const io = testing.io;

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, vectors_path, testing.allocator, std.Io.Limit.limited(1 << 20));
    defer testing.allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bytes, .{});
    defer parsed.deinit();

    const cases = (try field(parsed.value, "cases")).array.items;
    try testing.expect(cases.len > 0);

    var failures: usize = 0;
    for (cases, 0..) |case, case_index| {
        const name = (try field(case, "name")).string;
        const expect = (try field(case, "expect")).string;
        const path = (try field(case, "path")).string;
        const is_dir = (try field(case, "isDir")).bool;

        // A fresh root per case: a rule file from an earlier case must not be able to reach this one, and the
        // stack's caches are a snapshot of the tree that owns them.
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        for ((try field(case, "ruleFiles")).array.items) |rule_file| {
            const dir = (try field(rule_file, "dir")).string;
            const rules = (try field(rule_file, "rules")).string;
            var sub_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const sub_path = if (dir.len == 0)
                gitignore.file_name
            else blk: {
                try tmp.dir.createDirPath(io, dir);
                break :blk try std.fmt.bufPrint(&sub_path_buffer, "{s}/{s}", .{ dir, gitignore.file_name });
            };
            try tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = rules });
        }

        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root_count = try tmp.dir.realPath(io, &root_buffer);
        const root = root_buffer[0..root_count];

        var arena_alloc = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_alloc.deinit();
        var stack = ignore.Stack.init(arena_alloc.allocator(), io, root, true);
        defer stack.deinit();

        const got = verdictName(try stack.decide(path, is_dir));
        if (!std.mem.eql(u8, got, expect)) {
            // Printed before the final assert so a disagreement names its vector even though only one
            // failure is reported at the end.
            std.debug.print(
                "conformance case {d} '{s}' (path '{s}', isDir={}): expected {s}, got {s}\n",
                .{ case_index, name, path, is_dir, expect, got },
            );
            failures += 1;
        }
    }

    if (failures > 0) {
        std.debug.print("conformance: {d} of {d} vectors failed\n", .{ failures, cases.len });
    }
    try testing.expectEqual(@as(usize, 0), failures);
}
