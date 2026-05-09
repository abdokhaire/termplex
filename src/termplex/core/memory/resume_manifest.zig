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
const terminal_history_db = @import("../terminal_history_db.zig");

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

        var printed_active_workspace = false;
        for (s.workspace_names, s.workspaces) |ws_name, ws| {
            var has_active = false;
            for (ws.surfaces) |surface| {
                if (surface.process_alive) {
                    has_active = true;
                    break;
                }
            }
            if (!has_active) continue;

            printed_active_workspace = true;
            try w.print("### Workspace: {s} ({s})\n", .{ ws_name, ws.dir });

            for (ws.surfaces, ws.surface_ids) |surface, surf_id| {
                if (!surface.process_alive) continue;

                const cmd = surface.last_command orelse "unknown command";
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
            try w.writeAll("\n");
        }

        if (!printed_active_workspace) {
            try w.writeAll("No active processes recorded from the previous session.\n\n");
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

/// Build the resume manifest from SQLite runtime candidates.
///
/// This is the preferred path for process resume context because candidates
/// come from the durable terminal history database rather than stale JSON
/// workspace membership.
pub fn buildManifestFromResumeCandidates(
    allocator: std.mem.Allocator,
    candidates: []const terminal_history_db.ResumeCandidate,
    last_shutdown: ?[]const u8,
    global_memory: []const u8,
    workspace_memory_names: []const []const u8,
    workspace_memory_contents: []const []const u8,
) ![]u8 {
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("=== TERMPLEX ORCHESTRATOR CONTEXT ===\n\n");

    try w.writeAll("## Previous Session State\n");
    if (last_shutdown) |shutdown| {
        try w.print("Last session ended: {s} (graceful shutdown)\n\n", .{shutdown});
    } else {
        try w.writeAll("Last session ended unexpectedly (no graceful shutdown detected)\n\n");
    }

    if (candidates.len == 0) {
        try w.writeAll("No active processes recorded from the previous session.\n\n");
    } else {
        for (candidates, 0..) |candidate, i| {
            var already_printed = false;
            for (candidates[0..i]) |previous| {
                if (std.mem.eql(u8, previous.workspace_id, candidate.workspace_id)) {
                    already_printed = true;
                    break;
                }
            }
            if (already_printed) continue;

            try w.print("### Workspace: {s} ({s})\n", .{ candidate.workspace_name, candidate.workspace_dir });

            for (candidates) |surface| {
                if (!std.mem.eql(u8, surface.workspace_id, candidate.workspace_id)) continue;

                const cmd = surface.last_command orelse "unknown command";
                try w.print("- Surface {s}: `{s}`", .{ surface.history_id[0..@min(8, surface.history_id.len)], cmd });
                if (surface.process_pid) |pid| {
                    try w.print(" (pid: {d})", .{pid});
                }
                if (surface.ports_json) |ports| {
                    if (ports.len > 0) try w.print(" (ports: {s})", .{ports});
                }
                try w.writeAll("\n");
            }
            try w.writeAll("\n");
        }
    }

    try w.writeAll("## Global Knowledge\n");
    if (global_memory.len > 0) {
        try w.writeAll(global_memory);
        if (global_memory[global_memory.len - 1] != '\n') try w.writeAll("\n");
    } else {
        try w.writeAll("No global knowledge file found.\n");
    }
    try w.writeAll("\n");

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

test "manifest includes sqlite resume candidates" {
    const allocator = std.testing.allocator;

    var candidates = [_]terminal_history_db.ResumeCandidate{
        .{
            .history_id = try allocator.dupe(u8, "surface-live"),
            .workspace_id = try allocator.dupe(u8, "workspace-live"),
            .workspace_name = try allocator.dupe(u8, "Live"),
            .workspace_dir = try allocator.dupe(u8, "/repo/live"),
            .working_directory = try allocator.dupe(u8, "/repo/live"),
            .status = try allocator.dupe(u8, "active"),
            .process_pid = 4321,
            .detection_method = try allocator.dupe(u8, "shell_hook"),
            .ports_json = try allocator.dupe(u8, "[3000,5173]"),
            .command_started_at = try allocator.dupe(u8, "2026-05-09T08:00:01Z"),
            .last_command = try allocator.dupe(u8, "npm run dev"),
            .updated_at = try allocator.dupe(u8, "2026-05-09T08:00:01Z"),
        },
    };
    defer candidates[0].deinit(allocator);

    const manifest = try buildManifestFromResumeCandidates(
        allocator,
        &candidates,
        "2026-05-09T08:10:00Z",
        "## Preferences\n- Check live state first\n",
        &.{},
        &.{},
    );
    defer allocator.free(manifest);

    try std.testing.expect(std.mem.indexOf(u8, manifest, "Workspace: Live") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "npm run dev") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "surface-l") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "ports: [3000,5173]") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "Check live state first") != null);
}

test "manifest excludes workspaces without active processes" {
    const allocator = std.testing.allocator;

    const inactive_ids = try allocator.alloc([]const u8, 1);
    inactive_ids[0] = try allocator.dupe(u8, "inactive-surface");
    const inactive_surfaces = try allocator.alloc(state_mod.SurfaceState, 1);
    inactive_surfaces[0] = .{
        .working_directory = try allocator.dupe(u8, "/home/user/closed"),
        .last_command = try allocator.dupe(u8, "npm test"),
        .command_started_at = null,
        .process_pid = 1111,
        .process_alive = false,
        .detection_method = .shell_hook,
        .ports = try allocator.alloc(u16, 0),
    };

    const active_ids = try allocator.alloc([]const u8, 1);
    active_ids[0] = try allocator.dupe(u8, "active-surface");
    const active_surfaces = try allocator.alloc(state_mod.SurfaceState, 1);
    active_surfaces[0] = .{
        .working_directory = try allocator.dupe(u8, "/home/user/live"),
        .last_command = try allocator.dupe(u8, "npm run dev"),
        .command_started_at = null,
        .process_pid = 2222,
        .process_alive = true,
        .detection_method = .shell_hook,
        .ports = try allocator.alloc(u16, 0),
    };

    const ws_names = try allocator.alloc([]const u8, 2);
    ws_names[0] = try allocator.dupe(u8, "closed");
    ws_names[1] = try allocator.dupe(u8, "live");
    const wss = try allocator.alloc(state_mod.WorkspaceState, 2);
    wss[0] = .{ .dir = try allocator.dupe(u8, "/home/user/closed"), .surface_ids = inactive_ids, .surfaces = inactive_surfaces };
    wss[1] = .{ .dir = try allocator.dupe(u8, "/home/user/live"), .surface_ids = active_ids, .surfaces = active_surfaces };

    var ms = MemoryState{
        .version = 1,
        .last_updated = try allocator.dupe(u8, "2026-03-28T14:00:00Z"),
        .last_shutdown = try allocator.dupe(u8, "2026-03-28T14:00:00Z"),
        .workspace_names = ws_names,
        .workspaces = wss,
    };
    defer ms.deinit(allocator);

    const manifest = try buildManifest(allocator, ms, "", &.{}, &.{});
    defer allocator.free(manifest);

    try std.testing.expect(std.mem.indexOf(u8, manifest, "Workspace: live") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "npm run dev") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "Workspace: closed") == null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "npm test") == null);
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
