const TermplexXCFramework = @This();

const std = @import("std");
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");
const TermplexLib = @import("TermplexLib.zig");
const XCFrameworkStep = @import("XCFrameworkStep.zig");
const Target = @import("xcframework.zig").Target;

xcframework: *XCFrameworkStep,
target: Target,

pub fn init(
    b: *std.Build,
    deps: *const SharedDeps,
    target: Target,
) !TermplexXCFramework {
    // Universal macOS build
    const macos_universal = try TermplexLib.initMacOSUniversal(b, deps);

    // Native macOS build
    const macos_native = try TermplexLib.initStatic(b, &try deps.retarget(
        b,
        Config.genericMacOSTarget(b, null),
    ));

    // iOS
    const ios = try TermplexLib.initStatic(b, &try deps.retarget(
        b,
        b.resolveTargetQuery(.{
            .cpu_arch = .aarch64,
            .os_tag = .ios,
            .os_version_min = Config.osVersionMin(.ios),
            .abi = null,
        }),
    ));

    // iOS Simulator
    const ios_sim = try TermplexLib.initStatic(b, &try deps.retarget(
        b,
        b.resolveTargetQuery(.{
            .cpu_arch = .aarch64,
            .os_tag = .ios,
            .os_version_min = Config.osVersionMin(.ios),
            .abi = .simulator,

            // We force the Apple CPU model because the simulator
            // doesn't support the generic CPU model as of Zig 0.14 due
            // to missing "altnzcv" instructions, which is false. This
            // surely can't be right but we can fix this if/when we get
            // back to running simulator builds.
            .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.apple_a17 },
        }),
    ));

    // The xcframework wraps our termplex library so that we can link
    // it to the final app built with Swift.
    const xcframework = XCFrameworkStep.create(b, .{
        .name = "TermplexKit",
        .out_path = "macos/TermplexKit.xcframework",
        .libraries = switch (target) {
            .universal => &.{
                .{
                    .library = macos_universal.output,
                    .headers = b.path("include"),
                    .dsym = macos_universal.dsym,
                },
                .{
                    .library = ios.output,
                    .headers = b.path("include"),
                    .dsym = ios.dsym,
                },
                .{
                    .library = ios_sim.output,
                    .headers = b.path("include"),
                    .dsym = ios_sim.dsym,
                },
            },

            .native => &.{.{
                .library = macos_native.output,
                .headers = b.path("include"),
                .dsym = macos_native.dsym,
            }},
        },
    });

    return .{
        .xcframework = xcframework,
        .target = target,
    };
}

pub fn install(self: *const TermplexXCFramework) void {
    const b = self.xcframework.step.owner;
    self.addStepDependencies(b.getInstallStep());
}

pub fn addStepDependencies(
    self: *const TermplexXCFramework,
    other_step: *std.Build.Step,
) void {
    other_step.dependOn(self.xcframework.step);
}
