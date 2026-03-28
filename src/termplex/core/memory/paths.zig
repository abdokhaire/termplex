// src/termplex/core/memory/paths.zig
// Resolve file paths for the orchestrator memory system.
//
// Global files (under orchestration dir):
//   <orchestration_dir>/state.json   — global process state
//   <orchestration_dir>/MEMORY.md    — global knowledge
//
// Per-workspace files (under workspace project dir):
//   <workspace_dir>/.termplex/state.json   — per-workspace process state
//   <workspace_dir>/.termplex/memory.md    — per-workspace knowledge

const std = @import("std");

/// Paths for the global memory files (under orchestration directory).
pub const GlobalPaths = struct {
    state_json: []const u8,
    memory_md: []const u8,

    pub fn deinit(self: *GlobalPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.state_json);
        allocator.free(self.memory_md);
    }
};

/// Paths for per-workspace memory files.
pub const WorkspacePaths = struct {
    state_json: []const u8,
    memory_md: []const u8,
    dot_termplex_dir: []const u8,

    pub fn deinit(self: *WorkspacePaths, allocator: std.mem.Allocator) void {
        allocator.free(self.state_json);
        allocator.free(self.memory_md);
        allocator.free(self.dot_termplex_dir);
    }
};

/// Resolve global memory paths from the orchestration directory.
/// The orchestration_dir should already be expanded (no ~/ prefix).
/// Caller owns the returned paths; call deinit() to free.
pub fn resolveGlobalPaths(allocator: std.mem.Allocator, orchestration_dir: []const u8) !GlobalPaths {
    return .{
        .state_json = try std.fs.path.join(allocator, &.{ orchestration_dir, "state.json" }),
        .memory_md = try std.fs.path.join(allocator, &.{ orchestration_dir, "MEMORY.md" }),
    };
}

/// Resolve per-workspace memory paths from the workspace directory.
/// Caller owns the returned paths; call deinit() to free.
pub fn resolveWorkspacePaths(allocator: std.mem.Allocator, workspace_dir: []const u8) !WorkspacePaths {
    const dot_dir = try std.fs.path.join(allocator, &.{ workspace_dir, ".termplex" });
    errdefer allocator.free(dot_dir);
    return .{
        .state_json = try std.fs.path.join(allocator, &.{ dot_dir, "state.json" }),
        .memory_md = try std.fs.path.join(allocator, &.{ dot_dir, "memory.md" }),
        .dot_termplex_dir = dot_dir,
    };
}

/// Ensure a directory exists, creating it if necessary.
/// Handles PathAlreadyExists gracefully.
pub fn ensureDir(dir_path: []const u8) !void {
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "resolve global paths" {
    const allocator = std.testing.allocator;
    var paths = try resolveGlobalPaths(allocator, "/home/user/.termplex/orchestration");
    defer paths.deinit(allocator);

    try std.testing.expectEqualStrings("/home/user/.termplex/orchestration/state.json", paths.state_json);
    try std.testing.expectEqualStrings("/home/user/.termplex/orchestration/MEMORY.md", paths.memory_md);
}

test "resolve workspace paths" {
    const allocator = std.testing.allocator;
    var paths = try resolveWorkspacePaths(allocator, "/home/user/projects/backend");
    defer paths.deinit(allocator);

    try std.testing.expectEqualStrings("/home/user/projects/backend/.termplex/state.json", paths.state_json);
    try std.testing.expectEqualStrings("/home/user/projects/backend/.termplex/memory.md", paths.memory_md);
    try std.testing.expectEqualStrings("/home/user/projects/backend/.termplex", paths.dot_termplex_dir);
}
