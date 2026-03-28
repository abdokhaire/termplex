// src/termplex/core/memory/process_inspector.zig
// Fallback process detection via /proc filesystem.
//
// For surfaces without shell integration hooks, this module inspects
// child processes under each surface's shell PID by reading
// /proc/<pid>/cmdline and /proc/<pid>/children.

const std = @import("std");

const log = std.log.scoped(.memory_proc);

/// Result of inspecting a single PID's child processes.
pub const ProcessInfo = struct {
    pid: u32,
    cmdline: []const u8, // Owned by caller

    pub fn deinit(self: *ProcessInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.cmdline);
    }
};

/// Read the command line of a process from /proc/<pid>/cmdline.
/// Returns null if the process doesn't exist or cmdline is empty.
/// Replaces NUL separators with spaces for readability.
/// Caller owns the returned string.
pub fn readCmdline(allocator: std.mem.Allocator, pid: u32) !?[]u8 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/cmdline", .{pid}) catch return null;

    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    const raw = file.readToEndAlloc(allocator, 4096) catch return null;
    defer allocator.free(raw);

    if (raw.len == 0) return null;

    // Replace NUL bytes with spaces, trim trailing
    const result = try allocator.alloc(u8, raw.len);
    @memcpy(result, raw);
    for (result) |*c| {
        if (c.* == 0) c.* = ' ';
    }

    // Trim trailing spaces
    const trimmed_len = std.mem.trimRight(u8, result, " ").len;
    if (trimmed_len == 0) {
        allocator.free(result);
        return null;
    }

    // Resize to trimmed length
    if (trimmed_len < result.len) {
        const shrunk = allocator.realloc(result, trimmed_len) catch result;
        return shrunk[0..trimmed_len];
    }
    return result;
}

/// Get child PIDs of a process by reading /proc/<pid>/task/<pid>/children.
/// Returns an empty slice if the file doesn't exist.
/// Caller owns the returned slice.
pub fn getChildPids(allocator: std.mem.Allocator, parent_pid: u32) ![]u32 {
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/task/{d}/children", .{ parent_pid, parent_pid }) catch return try allocator.alloc(u32, 0);

    const file = std.fs.openFileAbsolute(path, .{}) catch return try allocator.alloc(u32, 0);
    defer file.close();

    const raw = file.readToEndAlloc(allocator, 4096) catch return try allocator.alloc(u32, 0);
    defer allocator.free(raw);

    if (raw.len == 0) return try allocator.alloc(u32, 0);

    var pids: std.ArrayList(u32) = .empty;
    defer pids.deinit(allocator);

    var iter = std.mem.tokenizeScalar(u8, raw, ' ');
    while (iter.next()) |tok| {
        const trimmed = std.mem.trim(u8, tok, " \t\n\r");
        if (trimmed.len == 0) continue;
        const pid = std.fmt.parseInt(u32, trimmed, 10) catch continue;
        try pids.append(allocator, pid);
    }

    return try pids.toOwnedSlice(allocator);
}

/// Check if a PID is alive by sending signal 0.
/// Returns true if the process exists and we have permission to signal it.
pub fn isAlive(pid: u32) bool {
    const pid_i32: i32 = @intCast(pid);
    // std.posix.kill returns an error union. Signal 0 doesn't kill,
    // just checks if the process exists.
    std.posix.kill(pid_i32, 0) catch return false;
    return true;
}

/// Inspect a shell PID and find its deepest child process.
/// Returns the "most interesting" child (deepest in tree).
/// Returns null if no children found.
pub fn inspectShellChildren(allocator: std.mem.Allocator, shell_pid: u32) !?ProcessInfo {
    const children = try getChildPids(allocator, shell_pid);
    defer allocator.free(children);

    if (children.len == 0) return null;

    // Use the first child's deepest descendant
    var current_pid = children[0];

    // Walk up to 10 levels deep to find the leaf process
    var depth: u32 = 0;
    while (depth < 10) : (depth += 1) {
        const grandchildren = try getChildPids(allocator, current_pid);
        defer allocator.free(grandchildren);
        if (grandchildren.len == 0) break;
        current_pid = grandchildren[0];
    }

    const cmdline = try readCmdline(allocator, current_pid) orelse return null;
    return ProcessInfo{
        .pid = current_pid,
        .cmdline = cmdline,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "readCmdline returns null for nonexistent pid" {
    const allocator = std.testing.allocator;
    // PID 999999999 almost certainly doesn't exist
    const result = try readCmdline(allocator, 999999999);
    try std.testing.expectEqual(@as(?[]u8, null), result);
}

test "getChildPids returns empty for nonexistent pid" {
    const allocator = std.testing.allocator;
    const result = try getChildPids(allocator, 999999999);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}
