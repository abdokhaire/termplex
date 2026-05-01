const std = @import("std");

pub const SurfaceContext = struct {
    core_surface_ptr: usize,
    workspace_name: []const u8,
    workspace_dir: []const u8,
};

pub const ResolvedSurfaceContext = struct {
    workspace_name: []const u8,
    workspace_dir: []const u8,
};

pub fn selectSurfaceContext(
    fallback_workspace_name: []const u8,
    fallback_workspace_dir: []const u8,
    contexts: []const SurfaceContext,
    target_core_surface_ptr: usize,
) ResolvedSurfaceContext {
    for (contexts) |context| {
        if (context.core_surface_ptr != target_core_surface_ptr) continue;
        return .{
            .workspace_name = context.workspace_name,
            .workspace_dir = context.workspace_dir,
        };
    }

    return .{
        .workspace_name = fallback_workspace_name,
        .workspace_dir = fallback_workspace_dir,
    };
}

test "selectSurfaceContext prefers the emitting surface workspace" {
    const contexts = [_]SurfaceContext{
        .{
            .core_surface_ptr = 0x1111,
            .workspace_name = "active",
            .workspace_dir = "/work/active",
        },
        .{
            .core_surface_ptr = 0x2222,
            .workspace_name = "backend",
            .workspace_dir = "/work/backend",
        },
    };

    const resolved = selectSurfaceContext(
        "active",
        "/work/active",
        &contexts,
        0x2222,
    );

    try std.testing.expectEqualStrings("backend", resolved.workspace_name);
    try std.testing.expectEqualStrings("/work/backend", resolved.workspace_dir);
}

test "selectSurfaceContext falls back to the active workspace" {
    const contexts = [_]SurfaceContext{
        .{
            .core_surface_ptr = 0x1111,
            .workspace_name = "backend",
            .workspace_dir = "/work/backend",
        },
    };

    const resolved = selectSurfaceContext(
        "active",
        "/work/active",
        &contexts,
        0x9999,
    );

    try std.testing.expectEqualStrings("active", resolved.workspace_name);
    try std.testing.expectEqualStrings("/work/active", resolved.workspace_dir);
}
