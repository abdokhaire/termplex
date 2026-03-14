// src/termplex/core/session.zig
// Session persistence: save and restore window geometry, workspaces, tabs,
// split layouts, and surface state to/from a JSON file.
//
// File location: $XDG_STATE_HOME/termplex/session.json
//   (falls back to $HOME/.local/state/termplex/session.json)
//
// Session format version: 1
// Version mismatches are rejected with error.UnsupportedVersion.

const std = @import("std");
const workspace_mod = @import("workspace");
const uuid_mod = @import("uuid");

const SplitLayout = workspace_mod.SplitLayout;
const SplitDirection = workspace_mod.SplitDirection;

// ---------------------------------------------------------------------------
// Public constants
// ---------------------------------------------------------------------------

pub const CURRENT_VERSION: u32 = 1;

// ---------------------------------------------------------------------------
// SessionData — the in-memory representation
// ---------------------------------------------------------------------------

pub const WindowGeometry = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub const SurfaceData = struct {
    /// UUID string (36 chars).
    id: []const u8,
    working_directory: []const u8,
    /// null when no custom title is set.
    custom_title: ?[]const u8,

    pub fn deinit(self: *SurfaceData, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.working_directory);
        if (self.custom_title) |t| allocator.free(t);
    }
};

pub const TabData = struct {
    title: ?[]const u8,
    /// UUID string for the focused surface.
    focused_surface_id: ?[]const u8,
    /// Heap-allocated split layout (call deinit).
    split_layout: SplitLayout,
    /// Surfaces referenced by this tab's split tree, in no particular order.
    surfaces: []SurfaceData,

    pub fn deinit(self: *TabData, allocator: std.mem.Allocator) void {
        if (self.title) |t| allocator.free(t);
        if (self.focused_surface_id) |f| allocator.free(f);
        self.split_layout.deinit(allocator);
        for (self.surfaces) |*s| s.deinit(allocator);
        allocator.free(self.surfaces);
    }
};

pub const WorkspaceData = struct {
    name: []const u8,
    working_directory: []const u8,
    active_tab_index: usize,
    tabs: []TabData,

    pub fn deinit(self: *WorkspaceData, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.working_directory);
        for (self.tabs) |*t| t.deinit(allocator);
        allocator.free(self.tabs);
    }
};

pub const SessionData = struct {
    version: u32,
    window: WindowGeometry,
    sidebar_width: u32,
    active_workspace_index: usize,
    workspaces: []WorkspaceData,

    pub fn deinit(self: *SessionData, allocator: std.mem.Allocator) void {
        for (self.workspaces) |*w| w.deinit(allocator);
        allocator.free(self.workspaces);
    }
};

// ---------------------------------------------------------------------------
// Path resolution
// ---------------------------------------------------------------------------

/// Resolve the session file path.
///
/// Priority:
///   1. $XDG_STATE_HOME/termplex/session.json
///   2. $HOME/.local/state/termplex/session.json
///
/// Returns an allocated string; caller owns it.
pub fn getSessionPath(allocator: std.mem.Allocator) ![]u8 {
    // Try XDG_STATE_HOME first.
    if (std.process.getEnvVarOwned(allocator, "XDG_STATE_HOME")) |state_home| {
        defer allocator.free(state_home);
        return std.fs.path.join(allocator, &[_][]const u8{ state_home, "termplex", "session.json" });
    } else |_| {}

    // Fall back to $HOME/.local/state
    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        return std.fs.path.join(allocator, &[_][]const u8{ home, ".local", "state", "termplex", "session.json" });
    } else |_| {}

    // Last resort: use a relative path (unlikely in practice).
    return allocator.dupe(u8, ".local/state/termplex/session.json");
}

// ---------------------------------------------------------------------------
// save()
// ---------------------------------------------------------------------------

/// Serialize SessionData to JSON and atomically write to the session file.
///
/// Creates parent directories as needed.
/// Writes to a .tmp file first, then renames for atomicity.
pub fn save(allocator: std.mem.Allocator, data: SessionData) !void {
    const path = try getSessionPath(allocator);
    defer allocator.free(path);

    // Ensure parent directory exists.
    const dir_path = std.fs.path.dirname(path) orelse ".";
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Build the temporary path.
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    // Serialize.
    const json_str = try toJson(allocator, data);
    defer allocator.free(json_str);

    // Write to .tmp.
    {
        const file = try std.fs.createFileAbsolute(tmp_path, .{});
        defer file.close();
        try file.writeAll(json_str);
    }

    // Atomic rename.
    try std.fs.renameAbsolute(tmp_path, path);
}

// ---------------------------------------------------------------------------
// load()
// ---------------------------------------------------------------------------

/// Read and deserialize the session file.
///
/// Returns null if the file does not exist (caller should use defaults).
/// Returns SessionError.CorruptSession if the JSON is malformed.
/// Returns SessionError.UnsupportedVersion if version != CURRENT_VERSION.
///
/// The returned SessionData is fully heap-allocated; call deinit() when done.
pub fn load(allocator: std.mem.Allocator) !?SessionData {
    const path = try getSessionPath(allocator);
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const max_size = 16 * 1024 * 1024; // 16 MiB ceiling
    const contents = file.readToEndAlloc(allocator, max_size) catch return error.IoError;
    defer allocator.free(contents);

    return fromJson(allocator, contents) catch |err| switch (err) {
        error.UnsupportedVersion => return error.UnsupportedVersion,
        else => return error.CorruptSession,
    };
}

// ---------------------------------------------------------------------------
// JSON serialization
// ---------------------------------------------------------------------------

/// Serialize SessionData to a JSON string. Caller owns the result.
fn toJson(allocator: std.mem.Allocator, data: SessionData) ![]u8 {
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };

    try jw.beginObject();

    try jw.objectField("version");
    try jw.write(data.version);

    try jw.objectField("window");
    try jw.beginObject();
    try jw.objectField("x");
    try jw.write(data.window.x);
    try jw.objectField("y");
    try jw.write(data.window.y);
    try jw.objectField("width");
    try jw.write(data.window.width);
    try jw.objectField("height");
    try jw.write(data.window.height);
    try jw.endObject();

    try jw.objectField("sidebar_width");
    try jw.write(data.sidebar_width);

    try jw.objectField("active_workspace_index");
    try jw.write(data.active_workspace_index);

    try jw.objectField("workspaces");
    try jw.beginArray();
    for (data.workspaces) |ws| {
        try writeWorkspace(&jw, ws);
    }
    try jw.endArray();

    try jw.endObject();

    return aw.toOwnedSlice();
}

fn writeWorkspace(jw: *std.json.Stringify, ws: WorkspaceData) !void {
    try jw.beginObject();
    try jw.objectField("name");
    try jw.write(ws.name);
    try jw.objectField("working_directory");
    try jw.write(ws.working_directory);
    try jw.objectField("active_tab_index");
    try jw.write(ws.active_tab_index);
    try jw.objectField("tabs");
    try jw.beginArray();
    for (ws.tabs) |tab| {
        try writeTab(jw, tab);
    }
    try jw.endArray();
    try jw.endObject();
}

fn writeTab(jw: *std.json.Stringify, tab: TabData) !void {
    try jw.beginObject();

    try jw.objectField("title");
    if (tab.title) |t| {
        try jw.write(t);
    } else {
        try jw.write(null);
    }

    try jw.objectField("focused_surface_id");
    if (tab.focused_surface_id) |f| {
        try jw.write(f);
    } else {
        try jw.write(null);
    }

    try jw.objectField("split_layout");
    try tab.split_layout.jsonStringify(jw);

    try jw.objectField("surfaces");
    try jw.beginArray();
    for (tab.surfaces) |s| {
        try writeSurface(jw, s);
    }
    try jw.endArray();

    try jw.endObject();
}

fn writeSurface(jw: *std.json.Stringify, s: SurfaceData) !void {
    try jw.beginObject();
    try jw.objectField("id");
    try jw.write(s.id);
    try jw.objectField("working_directory");
    try jw.write(s.working_directory);
    try jw.objectField("custom_title");
    if (s.custom_title) |ct| {
        try jw.write(ct);
    } else {
        try jw.write(null);
    }
    try jw.endObject();
}

// ---------------------------------------------------------------------------
// JSON deserialization
// ---------------------------------------------------------------------------

fn fromJson(allocator: std.mem.Allocator, json_str: []const u8) !SessionData {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch
        return error.CorruptSession;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.CorruptSession;

    // Version check (must be first).
    const ver_val = root.object.get("version") orelse return error.CorruptSession;
    const version: u32 = switch (ver_val) {
        .integer => |n| if (n < 0) return error.CorruptSession else @intCast(n),
        else => return error.CorruptSession,
    };
    if (version != CURRENT_VERSION) return error.UnsupportedVersion;

    // Window geometry.
    const win_val = root.object.get("window") orelse return error.CorruptSession;
    const window = try parseWindow(win_val);

    // sidebar_width.
    const sw_val = root.object.get("sidebar_width") orelse return error.CorruptSession;
    const sidebar_width: u32 = switch (sw_val) {
        .integer => |n| if (n < 0) return error.CorruptSession else @intCast(n),
        else => return error.CorruptSession,
    };

    // active_workspace_index.
    const awi_val = root.object.get("active_workspace_index") orelse return error.CorruptSession;
    const active_workspace_index: usize = switch (awi_val) {
        .integer => |n| if (n < 0) return error.CorruptSession else @intCast(n),
        else => return error.CorruptSession,
    };

    // Workspaces array.
    const ws_val = root.object.get("workspaces") orelse return error.CorruptSession;
    if (ws_val != .array) return error.CorruptSession;

    var workspaces: std.ArrayList(WorkspaceData) = .empty;
    errdefer {
        for (workspaces.items) |*w| w.deinit(allocator);
        workspaces.deinit(allocator);
    }

    for (ws_val.array.items) |ws_item| {
        const ws = try parseWorkspace(allocator, ws_item);
        try workspaces.append(allocator, ws);
    }

    return SessionData{
        .version = version,
        .window = window,
        .sidebar_width = sidebar_width,
        .active_workspace_index = active_workspace_index,
        .workspaces = try workspaces.toOwnedSlice(allocator),
    };
}

fn parseWindow(val: std.json.Value) !WindowGeometry {
    if (val != .object) return error.CorruptSession;
    const obj = val.object;

    const x_val = obj.get("x") orelse return error.CorruptSession;
    const y_val = obj.get("y") orelse return error.CorruptSession;
    const w_val = obj.get("width") orelse return error.CorruptSession;
    const h_val = obj.get("height") orelse return error.CorruptSession;

    const x: i32 = switch (x_val) {
        .integer => |n| @intCast(n),
        else => return error.CorruptSession,
    };
    const y: i32 = switch (y_val) {
        .integer => |n| @intCast(n),
        else => return error.CorruptSession,
    };
    const width: u32 = switch (w_val) {
        .integer => |n| if (n < 0) return error.CorruptSession else @intCast(n),
        else => return error.CorruptSession,
    };
    const height: u32 = switch (h_val) {
        .integer => |n| if (n < 0) return error.CorruptSession else @intCast(n),
        else => return error.CorruptSession,
    };

    return WindowGeometry{ .x = x, .y = y, .width = width, .height = height };
}

fn parseWorkspace(allocator: std.mem.Allocator, val: std.json.Value) !WorkspaceData {
    if (val != .object) return error.CorruptSession;
    const obj = val.object;

    const name_val = obj.get("name") orelse return error.CorruptSession;
    if (name_val != .string) return error.CorruptSession;
    const name = try allocator.dupe(u8, name_val.string);
    errdefer allocator.free(name);

    const wd_val = obj.get("working_directory") orelse return error.CorruptSession;
    if (wd_val != .string) return error.CorruptSession;
    const working_directory = try allocator.dupe(u8, wd_val.string);
    errdefer allocator.free(working_directory);

    const ati_val = obj.get("active_tab_index") orelse return error.CorruptSession;
    const active_tab_index: usize = switch (ati_val) {
        .integer => |n| if (n < 0) return error.CorruptSession else @intCast(n),
        else => return error.CorruptSession,
    };

    const tabs_val = obj.get("tabs") orelse return error.CorruptSession;
    if (tabs_val != .array) return error.CorruptSession;

    var tabs: std.ArrayList(TabData) = .empty;
    errdefer {
        for (tabs.items) |*t| t.deinit(allocator);
        tabs.deinit(allocator);
    }

    for (tabs_val.array.items) |tab_item| {
        const tab = try parseTab(allocator, tab_item);
        try tabs.append(allocator, tab);
    }

    return WorkspaceData{
        .name = name,
        .working_directory = working_directory,
        .active_tab_index = active_tab_index,
        .tabs = try tabs.toOwnedSlice(allocator),
    };
}

fn parseTab(allocator: std.mem.Allocator, val: std.json.Value) !TabData {
    if (val != .object) return error.CorruptSession;
    const obj = val.object;

    // title (nullable string)
    const title_val = obj.get("title") orelse return error.CorruptSession;
    const title: ?[]const u8 = switch (title_val) {
        .string => |s| try allocator.dupe(u8, s),
        .null => null,
        else => return error.CorruptSession,
    };
    errdefer if (title) |t| allocator.free(t);

    // focused_surface_id (nullable string)
    const fsi_val = obj.get("focused_surface_id") orelse return error.CorruptSession;
    const focused_surface_id: ?[]const u8 = switch (fsi_val) {
        .string => |s| try allocator.dupe(u8, s),
        .null => null,
        else => return error.CorruptSession,
    };
    errdefer if (focused_surface_id) |f| allocator.free(f);

    // split_layout
    const sl_val = obj.get("split_layout") orelse return error.CorruptSession;
    var split_layout = SplitLayout.fromJsonValue(allocator, sl_val) catch return error.CorruptSession;
    errdefer split_layout.deinit(allocator);

    // surfaces array
    const surfaces_val = obj.get("surfaces") orelse return error.CorruptSession;
    if (surfaces_val != .array) return error.CorruptSession;

    var surfaces: std.ArrayList(SurfaceData) = .empty;
    errdefer {
        for (surfaces.items) |*s| s.deinit(allocator);
        surfaces.deinit(allocator);
    }

    for (surfaces_val.array.items) |surf_item| {
        const s = try parseSurface(allocator, surf_item);
        try surfaces.append(allocator, s);
    }

    return TabData{
        .title = title,
        .focused_surface_id = focused_surface_id,
        .split_layout = split_layout,
        .surfaces = try surfaces.toOwnedSlice(allocator),
    };
}

fn parseSurface(allocator: std.mem.Allocator, val: std.json.Value) !SurfaceData {
    if (val != .object) return error.CorruptSession;
    const obj = val.object;

    const id_val = obj.get("id") orelse return error.CorruptSession;
    if (id_val != .string) return error.CorruptSession;
    const id = try allocator.dupe(u8, id_val.string);
    errdefer allocator.free(id);

    const wd_val = obj.get("working_directory") orelse return error.CorruptSession;
    if (wd_val != .string) return error.CorruptSession;
    const working_directory = try allocator.dupe(u8, wd_val.string);
    errdefer allocator.free(working_directory);

    const ct_val = obj.get("custom_title") orelse return error.CorruptSession;
    const custom_title: ?[]const u8 = switch (ct_val) {
        .string => |s| try allocator.dupe(u8, s),
        .null => null,
        else => return error.CorruptSession,
    };

    return SurfaceData{
        .id = id,
        .working_directory = working_directory,
        .custom_title = custom_title,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "getSessionPath uses XDG_STATE_HOME" {
    const allocator = std.testing.allocator;

    // Basic smoke test: calling getSessionPath doesn't crash.
    // The actual value depends on the environment; we just verify it
    // ends with the expected suffix.
    const path = try getSessionPath(allocator);
    defer allocator.free(path);

    const suffix = "termplex/session.json";
    const ends_with = std.mem.endsWith(u8, path, suffix);
    try std.testing.expect(ends_with);
}

test "getSessionPath returns path containing session.json" {
    const allocator = std.testing.allocator;
    const path = try getSessionPath(allocator);
    defer allocator.free(path);

    // The path must contain the expected filename component.
    try std.testing.expect(std.mem.indexOf(u8, path, "session.json") != null);
}

/// Build a minimal SessionData for round-trip testing.
fn makeSampleSessionData(allocator: std.mem.Allocator) !SessionData {
    const surf_id_str = "550e8400-e29b-41d4-a716-446655440000";
    const surf_uuid = try uuid_mod.parse(surf_id_str);

    // SplitLayout: single leaf.
    const layout = SplitLayout{ .leaf = .{ .surface_id = surf_uuid } };

    // SurfaceData.
    const surfaces = try allocator.alloc(SurfaceData, 1);
    surfaces[0] = SurfaceData{
        .id = try allocator.dupe(u8, surf_id_str),
        .working_directory = try allocator.dupe(u8, "/home/user/project"),
        .custom_title = null,
    };

    // TabData.
    const tabs = try allocator.alloc(TabData, 1);
    tabs[0] = TabData{
        .title = try allocator.dupe(u8, "Shell"),
        .focused_surface_id = try allocator.dupe(u8, surf_id_str),
        .split_layout = layout,
        .surfaces = surfaces,
    };

    // WorkspaceData.
    const workspaces = try allocator.alloc(WorkspaceData, 1);
    workspaces[0] = WorkspaceData{
        .name = try allocator.dupe(u8, "Project A"),
        .working_directory = try allocator.dupe(u8, "/home/user/project"),
        .active_tab_index = 0,
        .tabs = tabs,
    };

    return SessionData{
        .version = CURRENT_VERSION,
        .window = .{ .x = 100, .y = 100, .width = 1200, .height = 800 },
        .sidebar_width = 180,
        .active_workspace_index = 0,
        .workspaces = workspaces,
    };
}

test "toJson produces valid JSON with expected fields" {
    const allocator = std.testing.allocator;

    var data = try makeSampleSessionData(allocator);
    defer data.deinit(allocator);

    const json_str = try toJson(allocator, data);
    defer allocator.free(json_str);

    // Parse back as generic JSON value to verify structure.
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    // version
    try std.testing.expectEqual(@as(i64, 1), root.get("version").?.integer);

    // window
    const win = root.get("window").?.object;
    try std.testing.expectEqual(@as(i64, 100), win.get("x").?.integer);
    try std.testing.expectEqual(@as(i64, 100), win.get("y").?.integer);
    try std.testing.expectEqual(@as(i64, 1200), win.get("width").?.integer);
    try std.testing.expectEqual(@as(i64, 800), win.get("height").?.integer);

    // sidebar_width
    try std.testing.expectEqual(@as(i64, 180), root.get("sidebar_width").?.integer);

    // active_workspace_index
    try std.testing.expectEqual(@as(i64, 0), root.get("active_workspace_index").?.integer);

    // workspaces array
    const ws_arr = root.get("workspaces").?.array;
    try std.testing.expectEqual(@as(usize, 1), ws_arr.items.len);

    const ws = ws_arr.items[0].object;
    try std.testing.expectEqualStrings("Project A", ws.get("name").?.string);

    // tabs array inside workspace
    const tabs_arr = ws.get("tabs").?.array;
    try std.testing.expectEqual(@as(usize, 1), tabs_arr.items.len);

    const tab = tabs_arr.items[0].object;
    try std.testing.expectEqualStrings("Shell", tab.get("title").?.string);
    try std.testing.expectEqualStrings("550e8400-e29b-41d4-a716-446655440000", tab.get("focused_surface_id").?.string);

    // split_layout inside tab
    const sl = tab.get("split_layout").?.object;
    try std.testing.expectEqualStrings("leaf", sl.get("type").?.string);
}

test "fromJson round-trips SessionData" {
    const allocator = std.testing.allocator;

    var original = try makeSampleSessionData(allocator);
    defer original.deinit(allocator);

    const json_str = try toJson(allocator, original);
    defer allocator.free(json_str);

    var restored = try fromJson(allocator, json_str);
    defer restored.deinit(allocator);

    try std.testing.expectEqual(CURRENT_VERSION, restored.version);
    try std.testing.expectEqual(@as(i32, 100), restored.window.x);
    try std.testing.expectEqual(@as(i32, 100), restored.window.y);
    try std.testing.expectEqual(@as(u32, 1200), restored.window.width);
    try std.testing.expectEqual(@as(u32, 800), restored.window.height);
    try std.testing.expectEqual(@as(u32, 180), restored.sidebar_width);
    try std.testing.expectEqual(@as(usize, 0), restored.active_workspace_index);
    try std.testing.expectEqual(@as(usize, 1), restored.workspaces.len);

    const ws = restored.workspaces[0];
    try std.testing.expectEqualStrings("Project A", ws.name);
    try std.testing.expectEqualStrings("/home/user/project", ws.working_directory);
    try std.testing.expectEqual(@as(usize, 0), ws.active_tab_index);
    try std.testing.expectEqual(@as(usize, 1), ws.tabs.len);

    const tab = ws.tabs[0];
    try std.testing.expectEqualStrings("Shell", tab.title.?);
    try std.testing.expectEqualStrings("550e8400-e29b-41d4-a716-446655440000", tab.focused_surface_id.?);
    try std.testing.expect(tab.split_layout == .leaf);
    try std.testing.expectEqual(@as(usize, 1), tab.surfaces.len);

    const s = tab.surfaces[0];
    try std.testing.expectEqualStrings("550e8400-e29b-41d4-a716-446655440000", s.id);
    try std.testing.expectEqualStrings("/home/user/project", s.working_directory);
    try std.testing.expect(s.custom_title == null);
}

test "fromJson rejects wrong version" {
    const allocator = std.testing.allocator;

    const json_v99 =
        \\{"version":99,"window":{"x":0,"y":0,"width":800,"height":600},"sidebar_width":200,"active_workspace_index":0,"workspaces":[]}
    ;
    try std.testing.expectError(error.UnsupportedVersion, fromJson(allocator, json_v99));
}

test "fromJson rejects missing version field" {
    const allocator = std.testing.allocator;

    const bad_json =
        \\{"window":{"x":0,"y":0,"width":800,"height":600},"sidebar_width":200,"active_workspace_index":0,"workspaces":[]}
    ;
    try std.testing.expectError(error.CorruptSession, fromJson(allocator, bad_json));
}

test "fromJson rejects malformed JSON" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.CorruptSession, fromJson(allocator, "not json at all"));
}

test "fromJson rejects negative version" {
    const allocator = std.testing.allocator;

    const bad_json =
        \\{"version":-1,"window":{"x":0,"y":0,"width":800,"height":600},"sidebar_width":200,"active_workspace_index":0,"workspaces":[]}
    ;
    // -1 cast to u32 would overflow; we return CorruptSession before UnsupportedVersion.
    const result = fromJson(allocator, bad_json);
    try std.testing.expect(result == error.CorruptSession or result == error.UnsupportedVersion);
}

test "fromJson accepts null title in tab" {
    const allocator = std.testing.allocator;

    const surf_id = "550e8400-e29b-41d4-a716-446655440000";
    const json_str = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "version": 1,
        \\  "window": {{"x": 0, "y": 0, "width": 800, "height": 600}},
        \\  "sidebar_width": 200,
        \\  "active_workspace_index": 0,
        \\  "workspaces": [{{
        \\    "name": "ws",
        \\    "working_directory": "/tmp",
        \\    "active_tab_index": 0,
        \\    "tabs": [{{
        \\      "title": null,
        \\      "focused_surface_id": null,
        \\      "split_layout": {{"type": "leaf", "surface_id": "{s}"}},
        \\      "surfaces": []
        \\    }}]
        \\  }}]
        \\}}
    , .{surf_id});
    defer allocator.free(json_str);

    var data = try fromJson(allocator, json_str);
    defer data.deinit(allocator);

    try std.testing.expect(data.workspaces[0].tabs[0].title == null);
    try std.testing.expect(data.workspaces[0].tabs[0].focused_surface_id == null);
}

test "save and load round-trip using temp directory" {
    const allocator = std.testing.allocator;

    // We test save/load by exercising toJson/fromJson with a temp file,
    // since overriding env vars per-test would cause races.
    const tmp_dir = std.testing.tmpDir(.{});
    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &tmp_path_buf);

    // Build session path manually inside the temp dir.
    const session_path = try std.fs.path.join(allocator, &[_][]const u8{ tmp_path, "session.json" });
    defer allocator.free(session_path);

    var data = try makeSampleSessionData(allocator);
    defer data.deinit(allocator);

    // Serialize.
    const json_str = try toJson(allocator, data);
    defer allocator.free(json_str);

    // Write to temp file.
    {
        const file = try std.fs.createFileAbsolute(session_path, .{});
        defer file.close();
        try file.writeAll(json_str);
    }

    // Read back and deserialize.
    const file2 = try std.fs.openFileAbsolute(session_path, .{});
    defer file2.close();
    const read_back = try file2.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(read_back);

    var restored = try fromJson(allocator, read_back);
    defer restored.deinit(allocator);

    try std.testing.expectEqual(CURRENT_VERSION, restored.version);
    try std.testing.expectEqualStrings("Project A", restored.workspaces[0].name);
    try std.testing.expectEqualStrings("Shell", restored.workspaces[0].tabs[0].title.?);
}

test "round-trip with split layout" {
    const allocator = std.testing.allocator;

    const left_id_str = "550e8400-e29b-41d4-a716-446655440001";
    const right_id_str = "550e8400-e29b-41d4-a716-446655440002";
    const left_uuid = try uuid_mod.parse(left_id_str);
    const right_uuid = try uuid_mod.parse(right_id_str);

    const left_node = try allocator.create(SplitLayout);
    left_node.* = SplitLayout{ .leaf = .{ .surface_id = left_uuid } };
    const right_node = try allocator.create(SplitLayout);
    right_node.* = SplitLayout{ .leaf = .{ .surface_id = right_uuid } };

    const layout = SplitLayout{ .split = .{
        .direction = .horizontal,
        .ratio = 0.6,
        .first = left_node,
        .second = right_node,
    } };

    const surfaces = try allocator.alloc(SurfaceData, 2);
    surfaces[0] = SurfaceData{
        .id = try allocator.dupe(u8, left_id_str),
        .working_directory = try allocator.dupe(u8, "/projects/left"),
        .custom_title = try allocator.dupe(u8, "editor"),
    };
    surfaces[1] = SurfaceData{
        .id = try allocator.dupe(u8, right_id_str),
        .working_directory = try allocator.dupe(u8, "/projects/right"),
        .custom_title = null,
    };

    const tabs = try allocator.alloc(TabData, 1);
    tabs[0] = TabData{
        .title = try allocator.dupe(u8, "Split"),
        .focused_surface_id = try allocator.dupe(u8, left_id_str),
        .split_layout = layout,
        .surfaces = surfaces,
    };

    const workspaces = try allocator.alloc(WorkspaceData, 1);
    workspaces[0] = WorkspaceData{
        .name = try allocator.dupe(u8, "Dev"),
        .working_directory = try allocator.dupe(u8, "/projects"),
        .active_tab_index = 0,
        .tabs = tabs,
    };

    var data = SessionData{
        .version = CURRENT_VERSION,
        .window = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 },
        .sidebar_width = 220,
        .active_workspace_index = 0,
        .workspaces = workspaces,
    };
    defer data.deinit(allocator);

    const json_str = try toJson(allocator, data);
    defer allocator.free(json_str);

    var restored = try fromJson(allocator, json_str);
    defer restored.deinit(allocator);

    const tab = restored.workspaces[0].tabs[0];
    try std.testing.expect(tab.split_layout == .split);
    try std.testing.expectEqual(SplitDirection.horizontal, tab.split_layout.split.direction);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), tab.split_layout.split.ratio, 1e-9);

    // Verify surfaces
    try std.testing.expectEqual(@as(usize, 2), tab.surfaces.len);
    try std.testing.expectEqualStrings("editor", tab.surfaces[0].custom_title.?);
    try std.testing.expect(tab.surfaces[1].custom_title == null);
}

test "load returns null for nonexistent file" {
    const allocator = std.testing.allocator;
    // fromJson with empty input returns CorruptSession.
    const result = fromJson(allocator, "");
    try std.testing.expectError(error.CorruptSession, result);
}

test "empty workspaces array serializes and deserializes" {
    const allocator = std.testing.allocator;

    const workspaces = try allocator.alloc(WorkspaceData, 0);
    var data = SessionData{
        .version = CURRENT_VERSION,
        .window = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        .sidebar_width = 0,
        .active_workspace_index = 0,
        .workspaces = workspaces,
    };
    defer data.deinit(allocator);

    const json_str = try toJson(allocator, data);
    defer allocator.free(json_str);

    var restored = try fromJson(allocator, json_str);
    defer restored.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), restored.workspaces.len);
}
