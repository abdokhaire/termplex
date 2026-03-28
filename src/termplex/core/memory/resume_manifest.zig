// src/termplex/core/memory/resume_manifest.zig
// Builds the resume manifest — a structured text block injected into the
// orchestrator agent's initial context on startup.
//
// The manifest includes:
//   - Previous session state (workspaces, running processes)
//   - Global knowledge (MEMORY.md contents)
//   - Per-workspace knowledge (memory.md contents)

const std = @import("std");
const state_mod = @import("state.zig");

const MemoryState = state_mod.MemoryState;

/// Build the resume manifest text from state and knowledge files.
///
/// Parameters:
///   state: The loaded MemoryState (or null if no previous state)
///   global_memory: Contents of MEMORY.md (empty string if not found)
///   workspace_memories: Parallel array of (workspace_name, memory.md contents)
///
/// Returns an allocated string. Caller owns the result.
pub fn buildManifest(
    allocator: std.mem.Allocator,
    state: ?MemoryState,
    global_memory: []const u8,
    workspace_memory_names: []const []const u8,
    workspace_memory_contents: []const []const u8,
) ![]u8 {
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("=== TERMPLEX ORCHESTRATOR CONTEXT ===\n\n");

    // Previous session state
    if (state) |s| {
        try w.writeAll("## Previous Session State\n");

        if (s.last_shutdown) |shutdown| {
            try w.print("Last session ended: {s} (graceful shutdown)\n\n", .{shutdown});
        } else {
            try w.writeAll("Last session ended unexpectedly (no graceful shutdown detected)\n\n");
        }

        for (s.workspace_names, s.workspaces) |ws_name, ws| {
            try w.print("### Workspace: {s} ({s})\n", .{ ws_name, ws.dir });

            var has_active = false;
            for (ws.surfaces, ws.surface_ids) |surface, surf_id| {
                if (surface.last_command) |cmd| {
                    if (surface.process_alive) {
                        has_active = true;
                        try w.print("- Surface {s}: `{s}`", .{ surf_id[0..@min(8, surf_id.len)], cmd });
                        if (surface.ports.len > 0) {
                            try w.writeAll(" (ports:");
                            for (surface.ports, 0..) |port, i| {
                                if (i > 0) try w.writeAll(",");
                                try w.print(" {d}", .{port});
                            }
                            try w.writeAll(")");
                        }
                        try w.writeAll("\n");
                    }
                }
            }
            if (!has_active) {
                try w.writeAll("- No active processes at shutdown\n");
            }
            try w.writeAll("\n");
        }
    } else {
        try w.writeAll("## Previous Session State\nNo previous session state found.\n\n");
    }

    // Global knowledge
    try w.writeAll("## Global Knowledge\n");
    if (global_memory.len > 0) {
        try w.writeAll(global_memory);
        if (global_memory[global_memory.len - 1] != '\n') try w.writeAll("\n");
    } else {
        try w.writeAll("No global knowledge file found.\n");
    }
    try w.writeAll("\n");

    // Per-workspace knowledge
    if (workspace_memory_names.len > 0) {
        try w.writeAll("## Workspace Knowledge\n");
        for (workspace_memory_names, workspace_memory_contents) |name, content| {
            try w.print("### {s}\n", .{name});
            if (content.len > 0) {
                try w.writeAll(content);
                if (content[content.len - 1] != '\n') try w.writeAll("\n");
            } else {
                try w.writeAll("No workspace knowledge file found.\n");
            }
            try w.writeAll("\n");
        }
    }

    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "manifest with state and knowledge" {
    const allocator = std.testing.allocator;

    // Build minimal state
    const ports = try allocator.alloc(u16, 1);
    ports[0] = 8000;
    const surf_ids = try allocator.alloc([]const u8, 1);
    surf_ids[0] = try allocator.dupe(u8, "a1b2c3d4-e5f6-7890-abcd-ef1234567890");
    const surfs = try allocator.alloc(state_mod.SurfaceState, 1);
    surfs[0] = .{
        .working_directory = try allocator.dupe(u8, "/home/user/backend"),
        .last_command = try allocator.dupe(u8, "python manage.py runserver"),
        .command_started_at = null,
        .process_pid = 1234,
        .process_alive = true,
        .detection_method = .shell_hook,
        .ports = ports,
    };
    const ws_names = try allocator.alloc([]const u8, 1);
    ws_names[0] = try allocator.dupe(u8, "backend");
    const wss = try allocator.alloc(state_mod.WorkspaceState, 1);
    wss[0] = .{ .dir = try allocator.dupe(u8, "/home/user/backend"), .surface_ids = surf_ids, .surfaces = surfs };

    var ms = MemoryState{
        .version = 1,
        .last_updated = try allocator.dupe(u8, "2026-03-28T14:00:00Z"),
        .last_shutdown = try allocator.dupe(u8, "2026-03-28T14:00:00Z"),
        .workspace_names = ws_names,
        .workspaces = wss,
    };
    defer ms.deinit(allocator);

    const wm_names = [_][]const u8{"backend"};
    const wm_contents = [_][]const u8{"## Stack\n- Python 3.11\n"};

    const manifest = try buildManifest(
        allocator,
        ms,
        "## Preferences\n- Start backend first\n",
        &wm_names,
        &wm_contents,
    );
    defer allocator.free(manifest);

    // Verify key sections exist
    try std.testing.expect(std.mem.indexOf(u8, manifest, "=== TERMPLEX ORCHESTRATOR CONTEXT ===") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "graceful shutdown") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "python manage.py runserver") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "ports: 8000") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "Start backend first") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "Python 3.11") != null);
}

test "manifest with no state" {
    const allocator = std.testing.allocator;

    const manifest = try buildManifest(allocator, null, "", &.{}, &.{});
    defer allocator.free(manifest);

    try std.testing.expect(std.mem.indexOf(u8, manifest, "No previous session state found") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "No global knowledge file found") != null);
}

test "manifest crash recovery" {
    const allocator = std.testing.allocator;

    const ws_names = try allocator.alloc([]const u8, 0);
    const wss = try allocator.alloc(state_mod.WorkspaceState, 0);

    var ms = MemoryState{
        .version = 1,
        .last_updated = try allocator.dupe(u8, "2026-03-28T14:00:00Z"),
        .last_shutdown = null, // crash — no graceful shutdown
        .workspace_names = ws_names,
        .workspaces = wss,
    };
    defer ms.deinit(allocator);

    const manifest = try buildManifest(allocator, ms, "", &.{}, &.{});
    defer allocator.free(manifest);

    try std.testing.expect(std.mem.indexOf(u8, manifest, "unexpectedly") != null);
}
