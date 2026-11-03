// SPDX-License-Identifier: LicenseRef-GPL-3.0-with-Commons-Clause
// Copyright (c) 2026 Davor Hrg
//! `gitignore-walk` — the example `walk.zig` is written for: list the files git would keep.
//!
//! ```text
//! gitignore-walk [root]
//! ```
//!
//! One `/`-separated path per line on stdout, relative to `root` (the current directory without an
//! argument), and the count on stderr so the list stays pipeable.

const std = @import("std");
const walk = @import("walk.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next(); // the program itself
    const root = args.next() orelse ".";

    var list = walk.List.init(gpa);
    defer list.deinit();
    try walk.walk(io, gpa, root, .{}, &list);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    for (list.items.items) |name| {
        try out.appendSlice(gpa, name);
        try out.append(gpa, '\n');
    }
    // One write, like every other program in this repository: a syscall per line would be measured.
    try std.Io.File.stdout().writeStreamingAll(io, out.items);
    std.debug.print("{d} files\n", .{list.items.items.len});
}
