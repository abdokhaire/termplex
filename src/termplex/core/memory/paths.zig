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
    dir: []const u8,
    state_json: []const u8,
    memory_md: []const u8,

    pub fn deinit(self: *GlobalPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.dir);
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

/// Paths for persisted updater state and downloaded update assets.
pub const UpdatePaths = struct {
    dir: []const u8,
    state_json: []const u8,

    pub fn deinit(self: *UpdatePaths, allocator: std.mem.Allocator) void {
        allocator.free(self.dir);
        allocator.free(self.state_json);
    }
};

fn expandHome(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.mem.eql(u8, path, "~")) {
        const home = try std.process.getEnvVarOwned(allocator, "HOME");
        return home;
    }

    if (std.mem.startsWith(u8, path, "~/")) {
        const home = try std.process.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, path[2..] });
    }

    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);

    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    return std.fs.path.join(allocator, &.{ cwd, path });
}

/// Resolve global memory paths from the orchestration directory.
/// Resolves `~` and relative paths so defaults can be passed directly to APIs
/// that require absolute file paths.
/// Caller owns the returned paths; call deinit() to free.
pub fn resolveGlobalPaths(allocator: std.mem.Allocator, orchestration_dir: []const u8) !GlobalPaths {
    const dir = try expandHome(allocator, orchestration_dir);
    errdefer allocator.free(dir);

    return .{
        .dir = dir,
        .state_json = try std.fs.path.join(allocator, &.{ dir, "state.json" }),
        .memory_md = try std.fs.path.join(allocator, &.{ dir, "MEMORY.md" }),
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
    try std.fs.cwd().makePath(dir_path);
}

pub fn resolveTerminalHistoryDatabasePath(allocator: std.mem.Allocator) ![]const u8 {
    const terminal_history = @import("../terminal_history.zig");
    return terminal_history.databasePath(allocator);
}

/// Resolve updater paths under the XDG state directory.
pub fn resolveUpdatePaths(allocator: std.mem.Allocator) !UpdatePaths {
    var fallback_base: ?[]u8 = null;
    defer if (fallback_base) |base| allocator.free(base);

    const base = std.posix.getenv("XDG_STATE_HOME") orelse blk: {
        const home = std.posix.getenv("HOME") orelse return error.MissingHome;
        fallback_base = try std.fs.path.join(allocator, &.{ home, ".local", "state" });
        break :blk fallback_base.?;
    };

    const dir = try std.fs.path.join(allocator, &.{ base, "termplex", "updates" });
    errdefer allocator.free(dir);

    return .{
        .dir = dir,
        .state_json = try std.fs.path.join(allocator, &.{ dir, "update-state.json" }),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "resolve global paths" {
    const allocator = std.testing.allocator;
    var paths = try resolveGlobalPaths(allocator, "/home/user/.termplex/orchestration");
    defer paths.deinit(allocator);

    try std.testing.expectEqualStrings("/home/user/.termplex/orchestration", paths.dir);
    try std.testing.expectEqualStrings("/home/user/.termplex/orchestration/state.json", paths.state_json);
    try std.testing.expectEqualStrings("/home/user/.termplex/orchestration/MEMORY.md", paths.memory_md);
}

test "resolve global paths expands home directory" {
    const allocator = std.testing.allocator;
    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        var paths = try resolveGlobalPaths(allocator, "~/.termplex/orchestration");
        defer paths.deinit(allocator);

        const expected_dir = try std.fs.path.join(allocator, &.{ home, ".termplex", "orchestration" });
        defer allocator.free(expected_dir);
        const expected_state = try std.fs.path.join(allocator, &.{ expected_dir, "state.json" });
        defer allocator.free(expected_state);

        try std.testing.expectEqualStrings(expected_dir, paths.dir);
        try std.testing.expectEqualStrings(expected_state, paths.state_json);
        try std.testing.expect(std.fs.path.isAbsolute(paths.state_json));
    } else |_| {
        return error.SkipZigTest;
    }
}

test "resolve global paths makes relative directories absolute" {
    const allocator = std.testing.allocator;
    var paths = try resolveGlobalPaths(allocator, ".termplex/orchestration");
    defer paths.deinit(allocator);

    try std.testing.expect(std.fs.path.isAbsolute(paths.dir));
    try std.testing.expect(std.fs.path.isAbsolute(paths.state_json));
    try std.testing.expect(std.mem.endsWith(u8, paths.state_json, ".termplex/orchestration/state.json"));
}

test "resolve workspace paths" {
    const allocator = std.testing.allocator;
    var paths = try resolveWorkspacePaths(allocator, "/home/user/projects/backend");
    defer paths.deinit(allocator);

    try std.testing.expectEqualStrings("/home/user/projects/backend/.termplex/state.json", paths.state_json);
    try std.testing.expectEqualStrings("/home/user/projects/backend/.termplex/memory.md", paths.memory_md);
    try std.testing.expectEqualStrings("/home/user/projects/backend/.termplex", paths.dot_termplex_dir);
}

test "ensure dir creates nested absolute directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);

    const nested = try std.fs.path.join(allocator, &.{ base, "a", "b", "c" });
    defer allocator.free(nested);

    try ensureDir(nested);

    var dir = try std.fs.openDirAbsolute(nested, .{});
    dir.close();
}

test "resolve update paths uses XDG state layout" {
    const allocator = std.testing.allocator;
    var paths = try resolveUpdatePaths(allocator);
    defer paths.deinit(allocator);

    try std.testing.expect(std.fs.path.isAbsolute(paths.dir));
    try std.testing.expect(std.fs.path.isAbsolute(paths.state_json));
    try std.testing.expect(std.mem.endsWith(u8, paths.dir, "termplex/updates"));
    try std.testing.expect(std.mem.endsWith(u8, paths.state_json, "termplex/updates/update-state.json"));
}
