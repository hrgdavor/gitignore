const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library, as another project consumes it: one module named `gitignore`.
    _ = b.addModule("gitignore", .{
        .root_source_file = b.path("src/gitignore.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests: every module, so the chain, the vectors and the matcher are all covered.
    const test_step = b.step("test", "Run the matcher, chain and conformance tests");
    const modules = [_][]const u8{ "gitignore", "ignore", "conformance_test" };
    // `-Dvectors=<file>` runs any vectors file in the same schema, which is how a corpus generated from a
    // checkout (conformance/from-git-check-ignore.mjs) is verified without editing the hand-authored file.
    const vectors_path = b.option(
        []const u8,
        "vectors",
        "The conformance vectors to run (default: conformance/gitignore-vectors.json)",
    ) orelse "conformance/gitignore-vectors.json";
    for (modules) |name| {
        const module = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
        });
        // The vectors are embedded, not read at run time: the build system already tracks this file as an
        // input, so changing a vector rebuilds the test and no test process depends on a working directory.
        if (std.mem.eql(u8, name, "conformance_test")) {
            module.addAnonymousImport("vectors.json", .{
                .root_source_file = b.path(vectors_path),
            });
        }
        const tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    // The bench CLI. `-Dnaive=true` selects the historical designs and a distinct file name, so the two
    // builds can sit side by side in zig-out/bin and be timed against each other with one runner.
    const naive = b.option(bool, "naive", "Build ignore-decide with the historical naive matcher (bench only)") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "naive", naive);
    const decide = b.addExecutable(.{
        .name = if (naive) "ignore-decide-naive" else "ignore-decide",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/decide_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });
    b.installArtifact(decide);

    const run_step = b.step("run", "Run ignore-decide: zig build run -- --rules <file> --paths <file>");
    run_step.dependOn(&b.addRunArtifact(decide).step);
}
