//! TermplexBench generates all the Termplex benchmark helper binaries.
const TermplexBench = @This();

const std = @import("std");
const SharedDeps = @import("SharedDeps.zig");

steps: []*std.Build.Step.Compile,

pub fn init(
    b: *std.Build,
    deps: *const SharedDeps,
) !TermplexBench {
    var steps: std.ArrayList(*std.Build.Step.Compile) = .empty;
    errdefer steps.deinit(b.allocator);

    // Our synthetic data generator
    {
        const exe = b.addExecutable(.{
            .name = "termplex-gen",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main_gen.zig"),
                .target = deps.config.target,
                // We always want our datagen to be fast because it
                // takes awhile to run.
                .optimize = .ReleaseFast,
            }),
        });
        exe.linkLibC();
        _ = try deps.add(exe);
        try steps.append(b.allocator, exe);
    }

    // Our benchmarking application.
    {
        const exe = b.addExecutable(.{
            .name = "termplex-bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main_bench.zig"),
                .target = deps.config.target,
                // We always want our benchmarks to be in release mode.
                .optimize = .ReleaseFast,
            }),
        });
        exe.linkLibC();
        _ = try deps.add(exe);
        try steps.append(b.allocator, exe);
    }

    return .{ .steps = steps.items };
}

pub fn install(self: *const TermplexBench) void {
    const b = self.steps[0].step.owner;
    for (self.steps) |step| b.installArtifact(step);
}
