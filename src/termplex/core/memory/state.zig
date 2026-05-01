// src/termplex/core/memory/state.zig
// Data types for the orchestrator memory state (state.json).
//
// Tracks running processes per workspace surface. Updated by shell hooks
// (OSC 7337) and process tree inspection (/proc fallback).

const std = @import("std");

pub const CURRENT_VERSION: u32 = 1;

/// How a process was detected.
pub const DetectionMethod = enum {
    shell_hook,
    proc_inspection,

    pub fn toString(self: DetectionMethod) []const u8 {
        return switch (self) {
            .shell_hook => "shell_hook",
            .proc_inspection => "proc_inspection",
        };
    }

    pub fn fromString(s: []const u8) ?DetectionMethod {
        if (std.mem.eql(u8, s, "shell_hook")) return .shell_hook;
        if (std.mem.eql(u8, s, "proc_inspection")) return .proc_inspection;
        return null;
    }
};

/// State of a single terminal surface.
pub const SurfaceState = struct {
    working_directory: []const u8,
    last_command: ?[]const u8,
    command_started_at: ?[]const u8, // ISO 8601 string
    process_pid: ?u32,
    process_alive: bool,
    detection_method: ?DetectionMethod,
    ports: []u16,

    pub fn deinit(self: *SurfaceState, allocator: std.mem.Allocator) void {
        allocator.free(self.working_directory);
        if (self.last_command) |c| allocator.free(c);
        if (self.command_started_at) |t| allocator.free(t);
        allocator.free(self.ports);
    }
};

/// State of a workspace.
pub const WorkspaceState = struct {
    dir: []const u8,
    /// Map of surface UUID string -> SurfaceState.
    surface_ids: [][]const u8,
    surfaces: []SurfaceState,

    pub fn deinit(self: *WorkspaceState, allocator: std.mem.Allocator) void {
        allocator.free(self.dir);
        for (self.surface_ids) |id| allocator.free(id);
        allocator.free(self.surface_ids);
        for (self.surfaces) |*s| s.deinit(allocator);
        allocator.free(self.surfaces);
    }
};

/// Top-level memory state.
pub const MemoryState = struct {
    version: u32,
    last_updated: []const u8, // ISO 8601
    last_shutdown: ?[]const u8, // ISO 8601 or null
    /// Parallel arrays: workspace_names[i] corresponds to workspaces[i].
    workspace_names: [][]const u8,
    workspaces: []WorkspaceState,

    pub fn deinit(self: *MemoryState, allocator: std.mem.Allocator) void {
        allocator.free(self.last_updated);
        if (self.last_shutdown) |s| allocator.free(s);
        for (self.workspace_names) |n| allocator.free(n);
        allocator.free(self.workspace_names);
        for (self.workspaces) |*w| w.deinit(allocator);
        allocator.free(self.workspaces);
    }
};

// ---------------------------------------------------------------------------
// JSON serialization
// ---------------------------------------------------------------------------

/// Serialize MemoryState to a JSON string. Caller owns the result.
pub fn toJson(allocator: std.mem.Allocator, data: MemoryState) ![]u8 {
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };

    try jw.beginObject();

    try jw.objectField("version");
    try jw.write(data.version);
    try jw.objectField("last_updated");
    try jw.write(data.last_updated);
    try jw.objectField("last_shutdown");
    if (data.last_shutdown) |s| try jw.write(s) else try jw.write(null);

    try jw.objectField("workspaces");
    try jw.beginObject();
    for (data.workspace_names, data.workspaces) |name, ws| {
        try jw.objectField(name);
        try writeWorkspace(&jw, ws);
    }
    try jw.endObject();

    try jw.endObject();

    return aw.toOwnedSlice();
}

fn writeWorkspace(jw: *std.json.Stringify, ws: WorkspaceState) !void {
    try jw.beginObject();
    try jw.objectField("dir");
    try jw.write(ws.dir);
    try jw.objectField("surfaces");
    try jw.beginObject();
    for (ws.surface_ids, ws.surfaces) |id, surface| {
        try jw.objectField(id);
        try writeSurface(jw, surface);
    }
    try jw.endObject();
    try jw.endObject();
}

pub fn writeSurface(jw: *std.json.Stringify, s: SurfaceState) !void {
    try jw.beginObject();

    try jw.objectField("working_directory");
    try jw.write(s.working_directory);

    try jw.objectField("last_command");
    if (s.last_command) |c| try jw.write(c) else try jw.write(null);

    try jw.objectField("command_started_at");
    if (s.command_started_at) |t| try jw.write(t) else try jw.write(null);

    try jw.objectField("process_pid");
    if (s.process_pid) |p| try jw.write(p) else try jw.write(null);

    try jw.objectField("process_alive");
    try jw.write(s.process_alive);

    try jw.objectField("detection_method");
    if (s.detection_method) |m| try jw.write(m.toString()) else try jw.write(null);

    try jw.objectField("ports");
    try jw.beginArray();
    for (s.ports) |p| try jw.write(p);
    try jw.endArray();

    try jw.endObject();
}

// ---------------------------------------------------------------------------
// JSON deserialization
// ---------------------------------------------------------------------------

/// Deserialize a JSON string into MemoryState. Caller owns the result.
/// Returns null if JSON is empty or malformed.
pub fn fromJson(allocator: std.mem.Allocator, json_str: []const u8) !?MemoryState {
    if (json_str.len == 0) return null;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    const obj = root.object;

    // Version check
    const version_val = obj.get("version") orelse return null;
    const version = switch (version_val) {
        .integer => |i| if (i < 0 or i > std.math.maxInt(u32)) return null else @as(u32, @intCast(i)),
        else => return null,
    };
    if (version != CURRENT_VERSION) return error.UnsupportedVersion;

    // last_updated
    const lu_val = obj.get("last_updated") orelse return null;
    const last_updated = switch (lu_val) {
        .string => |s| try allocator.dupe(u8, s),
        else => return null,
    };
    errdefer allocator.free(last_updated);

    // last_shutdown (nullable)
    const last_shutdown: ?[]const u8 = blk: {
        const ls_val = obj.get("last_shutdown") orelse break :blk null;
        switch (ls_val) {
            .string => |s| break :blk try allocator.dupe(u8, s),
            .null => break :blk null,
            else => break :blk null,
        }
    };
    errdefer if (last_shutdown) |s| allocator.free(s);

    // workspaces object
    const ws_val = obj.get("workspaces") orelse return null;
    if (ws_val != .object) return null;
    const ws_obj = ws_val.object;

    var ws_names: std.ArrayList([]const u8) = .empty;
    defer {
        for (ws_names.items) |n| allocator.free(n);
        ws_names.deinit(allocator);
    }
    var ws_states: std.ArrayList(WorkspaceState) = .empty;
    defer {
        for (ws_states.items) |*w| w.deinit(allocator);
        ws_states.deinit(allocator);
    }

    var ws_iter = ws_obj.iterator();
    while (ws_iter.next()) |entry| {
        const name = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(name);
        const ws = try parseWorkspace(allocator, entry.value_ptr.*);
        try ws_names.append(allocator, name);
        try ws_states.append(allocator, ws);
    }

    return .{
        .version = version,
        .last_updated = last_updated,
        .last_shutdown = last_shutdown,
        .workspace_names = try ws_names.toOwnedSlice(allocator),
        .workspaces = try ws_states.toOwnedSlice(allocator),
    };
}

fn parseWorkspace(allocator: std.mem.Allocator, val: std.json.Value) !WorkspaceState {
    if (val != .object) return error.InvalidFormat;
    const obj = val.object;

    const dir_val = obj.get("dir") orelse return error.InvalidFormat;
    const dir = switch (dir_val) {
        .string => |s| try allocator.dupe(u8, s),
        else => return error.InvalidFormat,
    };
    errdefer allocator.free(dir);

    const surfaces_val = obj.get("surfaces") orelse return error.InvalidFormat;
    if (surfaces_val != .object) return error.InvalidFormat;
    const surfaces_obj = surfaces_val.object;

    var ids: std.ArrayList([]const u8) = .empty;
    defer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit(allocator);
    }
    var states: std.ArrayList(SurfaceState) = .empty;
    defer {
        for (states.items) |*s| s.deinit(allocator);
        states.deinit(allocator);
    }

    var surf_iter = surfaces_obj.iterator();
    while (surf_iter.next()) |entry| {
        const id = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(id);
        const surface = try parseSurface(allocator, entry.value_ptr.*);
        try ids.append(allocator, id);
        try states.append(allocator, surface);
    }

    return .{
        .dir = dir,
        .surface_ids = try ids.toOwnedSlice(allocator),
        .surfaces = try states.toOwnedSlice(allocator),
    };
}

fn parseSurface(allocator: std.mem.Allocator, val: std.json.Value) !SurfaceState {
    if (val != .object) return error.InvalidFormat;
    const obj = val.object;

    const wd_val = obj.get("working_directory") orelse return error.InvalidFormat;
    const working_directory = switch (wd_val) {
        .string => |s| try allocator.dupe(u8, s),
        else => return error.InvalidFormat,
    };
    errdefer allocator.free(working_directory);

    const last_command = try getOptionalString(allocator, obj, "last_command");
    errdefer if (last_command) |c| allocator.free(c);

    const command_started_at = try getOptionalString(allocator, obj, "command_started_at");
    errdefer if (command_started_at) |t| allocator.free(t);

    const process_pid: ?u32 = blk: {
        const pid_val = obj.get("process_pid") orelse break :blk null;
        switch (pid_val) {
            .integer => |i| break :blk if (i < 0 or i > std.math.maxInt(u32)) null else @as(u32, @intCast(i)),
            .null => break :blk null,
            else => break :blk null,
        }
    };

    const process_alive = blk: {
        const pa_val = obj.get("process_alive") orelse break :blk false;
        switch (pa_val) {
            .bool => |b| break :blk b,
            else => break :blk false,
        }
    };

    const detection_method: ?DetectionMethod = blk: {
        const dm_val = obj.get("detection_method") orelse break :blk null;
        switch (dm_val) {
            .string => |s| break :blk DetectionMethod.fromString(s),
            .null => break :blk null,
            else => break :blk null,
        }
    };

    // Parse ports array
    var ports_list: std.ArrayList(u16) = .empty;
    defer ports_list.deinit(allocator);
    if (obj.get("ports")) |ports_val| {
        if (ports_val == .array) {
            for (ports_val.array.items) |p| {
                switch (p) {
                    .integer => |i| {
                        if (i >= 0 and i <= std.math.maxInt(u16)) {
                            try ports_list.append(allocator, @as(u16, @intCast(i)));
                        }
                    },
                    else => {},
                }
            }
        }
    }

    return .{
        .working_directory = working_directory,
        .last_command = last_command,
        .command_started_at = command_started_at,
        .process_pid = process_pid,
        .process_alive = process_alive,
        .detection_method = detection_method,
        .ports = try ports_list.toOwnedSlice(allocator),
    };
}

fn getOptionalString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| try allocator.dupe(u8, s),
        .null => null,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "state json round-trip" {
    const allocator = std.testing.allocator;

    const ports = try allocator.alloc(u16, 2);
    ports[0] = 8000;
    ports[1] = 8001;

    const surface_ids = try allocator.alloc([]const u8, 1);
    surface_ids[0] = try allocator.dupe(u8, "a1b2c3d4-e5f6-7890-abcd-ef1234567890");

    const surface = SurfaceState{
        .working_directory = try allocator.dupe(u8, "/home/user/project"),
        .last_command = try allocator.dupe(u8, "python manage.py runserver"),
        .command_started_at = try allocator.dupe(u8, "2026-03-28T12:00:00Z"),
        .process_pid = 12345,
        .process_alive = true,
        .detection_method = .shell_hook,
        .ports = ports,
    };

    const surfaces = try allocator.alloc(SurfaceState, 1);
    surfaces[0] = surface;

    const ws_names = try allocator.alloc([]const u8, 1);
    ws_names[0] = try allocator.dupe(u8, "backend");

    const workspaces = try allocator.alloc(WorkspaceState, 1);
    workspaces[0] = .{
        .dir = try allocator.dupe(u8, "/home/user/project"),
        .surface_ids = surface_ids,
        .surfaces = surfaces,
    };

    var state = MemoryState{
        .version = CURRENT_VERSION,
        .last_updated = try allocator.dupe(u8, "2026-03-28T14:00:00Z"),
        .last_shutdown = try allocator.dupe(u8, "2026-03-28T14:00:00Z"),
        .workspace_names = ws_names,
        .workspaces = workspaces,
    };
    defer state.deinit(allocator);

    // Serialize
    const json = try toJson(allocator, state);
    defer allocator.free(json);

    // Deserialize
    var parsed = (try fromJson(allocator, json)).?;
    defer parsed.deinit(allocator);

    // Verify
    try std.testing.expectEqual(CURRENT_VERSION, parsed.version);
    try std.testing.expectEqualStrings("2026-03-28T14:00:00Z", parsed.last_updated);
    try std.testing.expectEqualStrings("2026-03-28T14:00:00Z", parsed.last_shutdown.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.workspaces.len);
    try std.testing.expectEqualStrings("backend", parsed.workspace_names[0]);
    try std.testing.expectEqualStrings("/home/user/project", parsed.workspaces[0].dir);
    try std.testing.expectEqual(@as(usize, 1), parsed.workspaces[0].surfaces.len);
    try std.testing.expectEqualStrings("python manage.py runserver", parsed.workspaces[0].surfaces[0].last_command.?);
    try std.testing.expectEqual(@as(u32, 12345), parsed.workspaces[0].surfaces[0].process_pid.?);
    try std.testing.expectEqual(true, parsed.workspaces[0].surfaces[0].process_alive);
    try std.testing.expectEqual(DetectionMethod.shell_hook, parsed.workspaces[0].surfaces[0].detection_method.?);
    try std.testing.expectEqual(@as(usize, 2), parsed.workspaces[0].surfaces[0].ports.len);
    try std.testing.expectEqual(@as(u16, 8000), parsed.workspaces[0].surfaces[0].ports[0]);
}

test "state json null last_shutdown" {
    const allocator = std.testing.allocator;

    const ws_names = try allocator.alloc([]const u8, 0);
    const workspaces = try allocator.alloc(WorkspaceState, 0);

    var state = MemoryState{
        .version = CURRENT_VERSION,
        .last_updated = try allocator.dupe(u8, "2026-03-28T14:00:00Z"),
        .last_shutdown = null,
        .workspace_names = ws_names,
        .workspaces = workspaces,
    };
    defer state.deinit(allocator);

    const json = try toJson(allocator, state);
    defer allocator.free(json);

    var parsed = (try fromJson(allocator, json)).?;
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(@as(?[]const u8, null), parsed.last_shutdown);
}

test "state json empty input returns null" {
    const allocator = std.testing.allocator;
    const result = try fromJson(allocator, "");
    try std.testing.expectEqual(@as(?MemoryState, null), result);
}
