// src/termplex/core/memory/state_manager.zig
// Central state manager for the orchestrator memory system.
//
// Responsibilities:
//   - Receive command start/end events from shell hooks (OSC 7337)
//   - Trigger periodic process inspection (fallback for no-hook shells)
//   - Debounce writes to state.json (max once per second)
//   - Persist final state on shutdown
//   - Load state on startup

const std = @import("std");
const state_mod = @import("state.zig");
const paths_mod = @import("paths.zig");

const log = std.log.scoped(.memory_state);

const MemoryState = state_mod.MemoryState;
const SurfaceState = state_mod.SurfaceState;
const WorkspaceState = state_mod.WorkspaceState;
const DetectionMethod = state_mod.DetectionMethod;

/// A command event received from a shell hook (OSC 7337).
pub const CommandEvent = struct {
    pub const Kind = enum { start, end };

    kind: Kind,
    surface_uuid: []const u8,
    workspace_name: []const u8,
    workspace_dir: []const u8,
    command: ?[]const u8, // Set for start events
    shell_pid: ?u32,
    exit_code: ?i32, // Set for end events
};

/// The state manager tracks live process state and persists it to disk.
pub const StateManager = struct {
    allocator: std.mem.Allocator,
    orchestration_dir: []const u8,
    dirty: bool,

    /// Loaded or built state. null until first event or load.
    state: ?MemoryState,

    pub fn init(allocator: std.mem.Allocator, orchestration_dir: []const u8) StateManager {
        return .{
            .allocator = allocator,
            .orchestration_dir = orchestration_dir,
            .dirty = false,
            .state = null,
        };
    }

    pub fn deinit(self: *StateManager) void {
        if (self.state) |*s| s.deinit(self.allocator);
        self.state = null;
    }

    /// Load state from disk. Returns true if state was loaded.
    pub fn loadFromDisk(self: *StateManager) !bool {
        var global_paths = try paths_mod.resolveGlobalPaths(self.allocator, self.orchestration_dir);
        defer global_paths.deinit(self.allocator);

        const file = std.fs.openFileAbsolute(global_paths.state_json, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer file.close();

        const max_size = 16 * 1024 * 1024;
        const contents = file.readToEndAlloc(self.allocator, max_size) catch return false;
        defer self.allocator.free(contents);

        if (try state_mod.fromJson(self.allocator, contents)) |loaded| {
            if (self.state) |*old| old.deinit(self.allocator);
            self.state = loaded;
            return true;
        }
        return false;
    }

    /// Persist current state to disk (global state.json).
    /// Called on debounce timer, periodic snapshot, and shutdown.
    pub fn saveToDisk(self: *StateManager) !void {
        const s = self.state orelse return;

        var global_paths = try paths_mod.resolveGlobalPaths(self.allocator, self.orchestration_dir);
        defer global_paths.deinit(self.allocator);

        // Ensure orchestration directory exists
        try paths_mod.ensureDir(self.orchestration_dir);

        const json = try state_mod.toJson(self.allocator, s);
        defer self.allocator.free(json);

        // Atomic write: .tmp -> rename
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{global_paths.state_json});
        defer self.allocator.free(tmp_path);

        {
            const file = try std.fs.createFileAbsolute(tmp_path, .{});
            defer file.close();
            try file.writeAll(json);
        }

        try std.fs.renameAbsolute(tmp_path, global_paths.state_json);
        self.dirty = false;

        log.info("saved memory state to {s}", .{global_paths.state_json});
    }

    /// Mark shutdown: set last_shutdown timestamp and mark all processes dead.
    pub fn markShutdown(self: *StateManager) void {
        const s = &(self.state orelse return);

        // Update last_shutdown with current timestamp.
        const now = std.time.timestamp();
        const ts = std.fmt.allocPrint(self.allocator, "{d}", .{now}) catch return;

        if (s.last_shutdown) |old| self.allocator.free(old);
        s.last_shutdown = ts;

        // Update last_updated
        const lu = self.allocator.dupe(u8, ts) catch return;
        self.allocator.free(s.last_updated);
        s.last_updated = lu;

        // Mark all processes as dead
        for (s.workspaces) |*ws| {
            for (ws.surfaces) |*surface| {
                surface.process_alive = false;
            }
        }

        self.dirty = true;
    }

    /// Handle an incoming command event (from OSC 7337 parsed by surface).
    /// Creates workspace/surface entries if they don't exist yet.
    /// Marks state as dirty for debounced write.
    pub fn handleCommandEvent(self: *StateManager, event: CommandEvent) void {
        // Ensure we have a state object
        if (self.state == null) {
            const ws_names = self.allocator.alloc([]const u8, 0) catch return;
            const wss = self.allocator.alloc(WorkspaceState, 0) catch return;
            const now_ts = std.fmt.allocPrint(self.allocator, "{d}", .{std.time.timestamp()}) catch return;
            self.state = .{
                .version = state_mod.CURRENT_VERSION,
                .last_updated = now_ts,
                .last_shutdown = null,
                .workspace_names = ws_names,
                .workspaces = wss,
            };
        }

        const s = &(self.state.?);

        // Find or create workspace
        const ws_idx = blk: {
            for (s.workspace_names, 0..) |name, i| {
                if (std.mem.eql(u8, name, event.workspace_name)) break :blk i;
            }
            // Create new workspace entry — grow the parallel arrays
            self.growWorkspaceArrays(s, event) catch return;
            break :blk s.workspace_names.len - 1;
        };

        const ws = &s.workspaces[ws_idx];

        // Find or create surface
        const surf_idx = blk: {
            for (ws.surface_ids, 0..) |id, i| {
                if (std.mem.eql(u8, id, event.surface_uuid)) break :blk i;
            }
            // Create new surface entry — grow the parallel arrays
            self.growSurfaceArrays(ws, event) catch return;
            break :blk ws.surface_ids.len - 1;
        };

        const surface = &ws.surfaces[surf_idx];

        switch (event.kind) {
            .start => {
                // Update command info
                if (surface.last_command) |old| self.allocator.free(old);
                surface.last_command = if (event.command) |c| self.allocator.dupe(u8, c) catch null else null;

                const now_str = std.fmt.allocPrint(self.allocator, "{d}", .{std.time.timestamp()}) catch null;
                if (surface.command_started_at) |old| self.allocator.free(old);
                surface.command_started_at = now_str;

                surface.process_pid = event.shell_pid;
                surface.process_alive = true;
                surface.detection_method = .shell_hook;
            },
            .end => {
                surface.process_alive = false;
            },
        }

        self.dirty = true;
    }

    /// Grow workspace_names and workspaces arrays by one entry.
    fn growWorkspaceArrays(self: *StateManager, s: *MemoryState, event: CommandEvent) !void {
        const new_name = try self.allocator.dupe(u8, event.workspace_name);
        errdefer self.allocator.free(new_name);
        const new_dir = try self.allocator.dupe(u8, event.workspace_dir);
        errdefer self.allocator.free(new_dir);
        const empty_ids = try self.allocator.alloc([]const u8, 0);
        const empty_surfs = try self.allocator.alloc(SurfaceState, 0);

        const new_ws = WorkspaceState{
            .dir = new_dir,
            .surface_ids = empty_ids,
            .surfaces = empty_surfs,
        };

        // Grow names array
        const old_names = s.workspace_names;
        const new_names = try self.allocator.alloc([]const u8, old_names.len + 1);
        @memcpy(new_names[0..old_names.len], old_names);
        new_names[old_names.len] = new_name;
        self.allocator.free(old_names);
        s.workspace_names = new_names;

        // Grow workspaces array
        const old_wss = s.workspaces;
        const new_wss = try self.allocator.alloc(WorkspaceState, old_wss.len + 1);
        @memcpy(new_wss[0..old_wss.len], old_wss);
        new_wss[old_wss.len] = new_ws;
        self.allocator.free(old_wss);
        s.workspaces = new_wss;
    }

    /// Grow surface_ids and surfaces arrays by one entry.
    fn growSurfaceArrays(self: *StateManager, ws: *WorkspaceState, event: CommandEvent) !void {
        const new_id = try self.allocator.dupe(u8, event.surface_uuid);
        errdefer self.allocator.free(new_id);
        const empty_ports = try self.allocator.alloc(u16, 0);
        const new_surf = SurfaceState{
            .working_directory = try self.allocator.dupe(u8, event.workspace_dir),
            .last_command = null,
            .command_started_at = null,
            .process_pid = null,
            .process_alive = false,
            .detection_method = null,
            .ports = empty_ports,
        };

        // Grow ids array
        const old_ids = ws.surface_ids;
        const new_ids = try self.allocator.alloc([]const u8, old_ids.len + 1);
        @memcpy(new_ids[0..old_ids.len], old_ids);
        new_ids[old_ids.len] = new_id;
        self.allocator.free(old_ids);
        ws.surface_ids = new_ids;

        // Grow surfaces array
        const old_surfs = ws.surfaces;
        const new_surfs = try self.allocator.alloc(SurfaceState, old_surfs.len + 1);
        @memcpy(new_surfs[0..old_surfs.len], old_surfs);
        new_surfs[old_surfs.len] = new_surf;
        self.allocator.free(old_surfs);
        ws.surfaces = new_surfs;
    }

    /// Debounced save: only writes if dirty. Call this from a GLib timer (1s interval).
    pub fn debouncedSave(self: *StateManager) void {
        if (!self.dirty) return;
        self.saveToDisk() catch |err| {
            log.warn("debounced save failed: {}", .{err});
        };
    }

    /// Save per-workspace state.json for a specific workspace.
    /// Creates .termplex/ directory if needed.
    pub fn saveWorkspaceState(self: *StateManager, workspace_name: []const u8) !void {
        const s = self.state orelse return;

        for (s.workspace_names, s.workspaces) |name, ws| {
            if (!std.mem.eql(u8, name, workspace_name)) continue;

            var wp = try paths_mod.resolveWorkspacePaths(self.allocator, ws.dir);
            defer wp.deinit(self.allocator);

            // Ensure .termplex/ directory exists
            try paths_mod.ensureDir(wp.dot_termplex_dir);

            // Build per-workspace JSON (surfaces only, plus workspace_name)
            var aw: std.io.Writer.Allocating = .init(self.allocator);
            defer aw.deinit();
            var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };

            try jw.beginObject();
            try jw.objectField("version");
            try jw.write(state_mod.CURRENT_VERSION);
            try jw.objectField("workspace_name");
            try jw.write(name);
            try jw.objectField("last_updated");
            try jw.write(s.last_updated);
            try jw.objectField("last_shutdown");
            if (s.last_shutdown) |ls| try jw.write(ls) else try jw.write(null);
            try jw.objectField("surfaces");
            try jw.beginObject();
            for (ws.surface_ids, ws.surfaces) |id, surface| {
                try jw.objectField(id);
                try state_mod.writeSurface(&jw, surface);
            }
            try jw.endObject();
            try jw.endObject();

            const json = try aw.toOwnedSlice();
            defer self.allocator.free(json);

            // Atomic write
            const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{wp.state_json});
            defer self.allocator.free(tmp_path);
            {
                const file = try std.fs.createFileAbsolute(tmp_path, .{});
                defer file.close();
                try file.writeAll(json);
            }
            try std.fs.renameAbsolute(tmp_path, wp.state_json);
            return;
        }
    }

    /// Get the loaded state (read-only). Returns null if not loaded.
    pub fn getState(self: *const StateManager) ?MemoryState {
        return self.state;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "state manager init and deinit" {
    const allocator = std.testing.allocator;
    var mgr = StateManager.init(allocator, "/tmp/test-orch");
    defer mgr.deinit();

    try std.testing.expectEqual(@as(?MemoryState, null), mgr.getState());
    try std.testing.expectEqual(false, mgr.dirty);
}

test "state manager load nonexistent file" {
    const allocator = std.testing.allocator;
    var mgr = StateManager.init(allocator, "/tmp/nonexistent-orch-dir-12345");
    defer mgr.deinit();

    const loaded = try mgr.loadFromDisk();
    try std.testing.expectEqual(false, loaded);
}

test "state manager handle command event creates state" {
    const allocator = std.testing.allocator;
    var mgr = StateManager.init(allocator, "/tmp/test-orch");
    defer mgr.deinit();

    mgr.handleCommandEvent(.{
        .kind = .start,
        .surface_uuid = "test-uuid-1234",
        .workspace_name = "backend",
        .workspace_dir = "/home/user/backend",
        .command = "python manage.py runserver",
        .shell_pid = 1234,
        .exit_code = null,
    });

    try std.testing.expect(mgr.getState() != null);
    try std.testing.expect(mgr.dirty);
    const s = mgr.getState().?;
    try std.testing.expectEqual(@as(usize, 1), s.workspace_names.len);
    try std.testing.expectEqualStrings("backend", s.workspace_names[0]);
    try std.testing.expectEqual(@as(usize, 1), s.workspaces[0].surfaces.len);
    try std.testing.expectEqualStrings("python manage.py runserver", s.workspaces[0].surfaces[0].last_command.?);
    try std.testing.expectEqual(true, s.workspaces[0].surfaces[0].process_alive);
}

test "state manager handle command end marks process dead" {
    const allocator = std.testing.allocator;
    var mgr = StateManager.init(allocator, "/tmp/test-orch");
    defer mgr.deinit();

    // Start a command
    mgr.handleCommandEvent(.{
        .kind = .start,
        .surface_uuid = "test-uuid-1234",
        .workspace_name = "backend",
        .workspace_dir = "/home/user/backend",
        .command = "pytest",
        .shell_pid = 1234,
        .exit_code = null,
    });

    // End the command
    mgr.handleCommandEvent(.{
        .kind = .end,
        .surface_uuid = "test-uuid-1234",
        .workspace_name = "backend",
        .workspace_dir = "/home/user/backend",
        .command = null,
        .shell_pid = 1234,
        .exit_code = 0,
    });

    const s = mgr.getState().?;
    try std.testing.expectEqual(false, s.workspaces[0].surfaces[0].process_alive);
}

test "state manager markShutdown marks all dead" {
    const allocator = std.testing.allocator;
    var mgr = StateManager.init(allocator, "/tmp/test-orch");
    defer mgr.deinit();

    // Start a command
    mgr.handleCommandEvent(.{
        .kind = .start,
        .surface_uuid = "test-uuid-1234",
        .workspace_name = "backend",
        .workspace_dir = "/home/user/backend",
        .command = "python manage.py runserver",
        .shell_pid = 1234,
        .exit_code = null,
    });

    mgr.markShutdown();

    const s = mgr.getState().?;
    try std.testing.expectEqual(false, s.workspaces[0].surfaces[0].process_alive);
    try std.testing.expect(s.last_shutdown != null);
}
