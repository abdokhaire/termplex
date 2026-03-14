// src/termplex/core/workspace.zig
// Data models for workspaces, tabs, surfaces, and notifications.
//
// Key types:
//   WorkspaceState  — a named workspace with tabs, git info, ports
//   TabState        — a terminal tab with a recursive split layout
//   SplitLayout     — binary tree: leaf (surface) or split (two children)
//   SurfaceState    — a single terminal surface (one shell process)
//   Notification    — ephemeral notification from OSC or CLI

const std = @import("std");
const uuid_mod = @import("uuid");
const Uuid = uuid_mod.Uuid;
const uuid_util = uuid_mod;

// ---------------------------------------------------------------------------
// SplitLayout
// ---------------------------------------------------------------------------

/// Source of a notification.
pub const NotificationSource = enum {
    osc,
    cli,
};

/// Direction for a split pane.
pub const SplitDirection = enum {
    horizontal,
    vertical,
};

/// A recursive binary tree describing how a tab's area is divided.
///
/// Memory: split nodes own their children via pointers allocated with an
/// Allocator. Call `SplitLayout.deinit` to free all descendants.
pub const SplitLayout = union(enum) {
    leaf: Leaf,
    split: Split,

    pub const Leaf = struct {
        surface_id: Uuid,
    };

    pub const Split = struct {
        direction: SplitDirection,
        ratio: f64,
        first: *SplitLayout,
        second: *SplitLayout,
    };

    /// Recursively free all split nodes. The root itself is not freed because
    /// it may be stack-allocated; only heap-allocated children are freed.
    pub fn deinit(self: *SplitLayout, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .leaf => {},
            .split => |s| {
                s.first.deinit(allocator);
                allocator.destroy(s.first);
                s.second.deinit(allocator);
                allocator.destroy(s.second);
            },
        }
    }

    /// Deep-clone this layout. The caller owns all returned heap-allocated
    /// nodes and must call `deinit` on the result.
    pub fn clone(self: SplitLayout, allocator: std.mem.Allocator) !SplitLayout {
        switch (self) {
            .leaf => return self,
            .split => |s| {
                const first = try allocator.create(SplitLayout);
                errdefer allocator.destroy(first);
                first.* = try s.first.clone(allocator);

                const second = try allocator.create(SplitLayout);
                errdefer {
                    first.deinit(allocator);
                    allocator.destroy(second);
                }
                second.* = try s.second.clone(allocator);

                return SplitLayout{ .split = .{
                    .direction = s.direction,
                    .ratio = s.ratio,
                    .first = first,
                    .second = second,
                } };
            },
        }
    }

    // -----------------------------------------------------------------------
    // JSON serialization
    //
    // Format:
    //   Leaf:  {"type":"leaf","surface_id":"<uuid>"}
    //   Split: {"type":"split","direction":"horizontal"|"vertical","ratio":<f64>,"first":<SplitLayout>,"second":<SplitLayout>}
    // -----------------------------------------------------------------------

    /// Custom JSON serialization. Called by std.json.stringify.
    pub fn jsonStringify(self: SplitLayout, jw: anytype) !void {
        try jw.beginObject();
        switch (self) {
            .leaf => |l| {
                try jw.objectField("type");
                try jw.write("leaf");
                try jw.objectField("surface_id");
                var buf: [36]u8 = undefined;
                uuid_util.format(l.surface_id, &buf);
                try jw.write(buf[0..]);
            },
            .split => |s| {
                try jw.objectField("type");
                try jw.write("split");
                try jw.objectField("direction");
                try jw.write(@tagName(s.direction));
                try jw.objectField("ratio");
                try jw.write(s.ratio);
                try jw.objectField("first");
                try s.first.jsonStringify(jw);
                try jw.objectField("second");
                try s.second.jsonStringify(jw);
            },
        }
        try jw.endObject();
    }

    /// Deserialize from a std.json.Value. The caller must later call deinit
    /// on the returned SplitLayout to free any heap-allocated split nodes.
    pub fn fromJsonValue(
        allocator: std.mem.Allocator,
        value: std.json.Value,
    ) !SplitLayout {
        if (value != .object) return error.InvalidSplitLayout;
        const obj = value.object;

        const type_val = obj.get("type") orelse return error.InvalidSplitLayout;
        if (type_val != .string) return error.InvalidSplitLayout;
        const type_str = type_val.string;

        if (std.mem.eql(u8, type_str, "leaf")) {
            const sid_val = obj.get("surface_id") orelse return error.InvalidSplitLayout;
            if (sid_val != .string) return error.InvalidSplitLayout;
            const sid = uuid_util.parse(sid_val.string) catch return error.InvalidSplitLayout;
            return SplitLayout{ .leaf = .{ .surface_id = sid } };
        } else if (std.mem.eql(u8, type_str, "split")) {
            const dir_val = obj.get("direction") orelse return error.InvalidSplitLayout;
            if (dir_val != .string) return error.InvalidSplitLayout;
            const direction = if (std.mem.eql(u8, dir_val.string, "horizontal"))
                SplitDirection.horizontal
            else if (std.mem.eql(u8, dir_val.string, "vertical"))
                SplitDirection.vertical
            else
                return error.InvalidSplitLayout;

            const ratio_val = obj.get("ratio") orelse return error.InvalidSplitLayout;
            const ratio: f64 = switch (ratio_val) {
                .float => |f| f,
                .integer => |i| @floatFromInt(i),
                else => return error.InvalidSplitLayout,
            };

            const first_val = obj.get("first") orelse return error.InvalidSplitLayout;
            const first = try allocator.create(SplitLayout);
            errdefer allocator.destroy(first);
            first.* = try fromJsonValue(allocator, first_val);
            errdefer {
                first.deinit(allocator);
            }

            const second_val = obj.get("second") orelse return error.InvalidSplitLayout;
            const second = try allocator.create(SplitLayout);
            errdefer {
                first.deinit(allocator);
                allocator.destroy(first);
                allocator.destroy(second);
            }
            second.* = try fromJsonValue(allocator, second_val);

            return SplitLayout{ .split = .{
                .direction = direction,
                .ratio = ratio,
                .first = first,
                .second = second,
            } };
        } else {
            return error.InvalidSplitLayout;
        }
    }

    /// Serialize this SplitLayout to a JSON string. Caller owns the result.
    pub fn toJson(self: SplitLayout, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, self, .{});
    }

    /// Deserialize a SplitLayout from a JSON string. The returned layout may
    /// contain heap-allocated split nodes; call deinit when done.
    pub fn fromJson(allocator: std.mem.Allocator, json_str: []const u8) !SplitLayout {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
        defer parsed.deinit();
        return fromJsonValue(allocator, parsed.value);
    }
};

// ---------------------------------------------------------------------------
// SurfaceState
// ---------------------------------------------------------------------------

/// Represents a single terminal surface (one shell process / pty).
///
/// Strings are owned by this struct; create with `init`, free with `deinit`.
pub const SurfaceState = struct {
    id: Uuid,
    working_directory: []const u8,
    custom_title: ?[]const u8,

    /// Create a SurfaceState, copying all string fields.
    pub fn init(
        allocator: std.mem.Allocator,
        id: Uuid,
        working_directory: []const u8,
        custom_title: ?[]const u8,
    ) !SurfaceState {
        const wd = try allocator.dupe(u8, working_directory);
        errdefer allocator.free(wd);

        const ct = if (custom_title) |t| try allocator.dupe(u8, t) else null;

        return SurfaceState{
            .id = id,
            .working_directory = wd,
            .custom_title = ct,
        };
    }

    /// Free all owned memory.
    pub fn deinit(self: *SurfaceState, allocator: std.mem.Allocator) void {
        allocator.free(self.working_directory);
        if (self.custom_title) |t| allocator.free(t);
    }
};

// ---------------------------------------------------------------------------
// TabState
// ---------------------------------------------------------------------------

/// Represents a terminal tab containing a split layout tree.
///
/// Strings are owned; the SplitLayout's split nodes are also owned.
pub const TabState = struct {
    id: Uuid,
    title: ?[]const u8,
    split_layout: SplitLayout,

    /// Create a TabState, copying the title string. The split_layout is
    /// transferred (ownership of any heap-allocated nodes moves to TabState).
    pub fn init(
        allocator: std.mem.Allocator,
        id: Uuid,
        title: ?[]const u8,
        split_layout: SplitLayout,
    ) !TabState {
        const t = if (title) |tt| try allocator.dupe(u8, tt) else null;
        return TabState{
            .id = id,
            .title = t,
            .split_layout = split_layout,
        };
    }

    /// Free all owned memory including the split layout tree.
    pub fn deinit(self: *TabState, allocator: std.mem.Allocator) void {
        if (self.title) |t| allocator.free(t);
        self.split_layout.deinit(allocator);
    }
};

// ---------------------------------------------------------------------------
// Notification
// ---------------------------------------------------------------------------

/// An ephemeral notification from an OSC sequence or CLI command.
///
/// Notifications are not persisted. WorkspaceState caps them at 100 per
/// workspace (oldest evicted when full).
pub const Notification = struct {
    /// Monotonic counter — not a UUID.
    id: u64,
    workspace_id: Uuid,
    /// Optional: nil means the notification is not tied to a specific surface.
    surface_id: ?Uuid,
    title: []const u8,
    body: []const u8,
    /// Unix timestamp (seconds since epoch).
    timestamp: i64,
    read: bool,
    source: NotificationSource,

    /// Create a Notification, copying all string fields.
    pub fn init(
        allocator: std.mem.Allocator,
        id: u64,
        workspace_id: Uuid,
        surface_id: ?Uuid,
        title: []const u8,
        body: []const u8,
        timestamp: i64,
        read: bool,
        source: NotificationSource,
    ) !Notification {
        const t = try allocator.dupe(u8, title);
        errdefer allocator.free(t);
        const b = try allocator.dupe(u8, body);

        return Notification{
            .id = id,
            .workspace_id = workspace_id,
            .surface_id = surface_id,
            .title = t,
            .body = b,
            .timestamp = timestamp,
            .read = read,
            .source = source,
        };
    }

    /// Free all owned memory.
    pub fn deinit(self: *Notification, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.body);
    }
};

// ---------------------------------------------------------------------------
// WorkspaceState
// ---------------------------------------------------------------------------

/// Represents a named workspace with tabs, git info, and listening ports.
///
/// All strings and slices are owned. Use `init`/`deinit` for lifecycle.
pub const WorkspaceState = struct {
    id: Uuid,
    name: []const u8,
    working_directory: []const u8,
    /// null when the directory is not inside a git repository.
    git_branch: ?[]const u8,
    git_dirty: bool,
    /// Slice of TCP port numbers the workspace's processes are listening on.
    listening_ports: []u16,
    unread_count: u32,
    tabs: []TabState,

    /// Create a WorkspaceState, copying name and working_directory.
    /// `tabs` and `listening_ports` are transferred (ownership moves here).
    /// `git_branch` is copied if non-null.
    pub fn init(
        allocator: std.mem.Allocator,
        id: Uuid,
        name: []const u8,
        working_directory: []const u8,
        git_branch: ?[]const u8,
        git_dirty: bool,
        listening_ports: []u16,
        unread_count: u32,
        tabs: []TabState,
    ) !WorkspaceState {
        const n = try allocator.dupe(u8, name);
        errdefer allocator.free(n);

        const wd = try allocator.dupe(u8, working_directory);
        errdefer allocator.free(wd);

        const gb = if (git_branch) |b| try allocator.dupe(u8, b) else null;

        return WorkspaceState{
            .id = id,
            .name = n,
            .working_directory = wd,
            .git_branch = gb,
            .git_dirty = git_dirty,
            .listening_ports = listening_ports,
            .unread_count = unread_count,
            .tabs = tabs,
        };
    }

    /// Free all owned memory, including all tabs (which in turn free their
    /// split layouts) and the listening_ports slice.
    pub fn deinit(self: *WorkspaceState, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.working_directory);
        if (self.git_branch) |b| allocator.free(b);
        allocator.free(self.listening_ports);
        for (self.tabs) |*tab| {
            tab.deinit(allocator);
        }
        allocator.free(self.tabs);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "SurfaceState init and deinit" {
    const allocator = std.testing.allocator;

    const id = uuid_util.generate();
    var surface = try SurfaceState.init(allocator, id, "/home/user/project", "my shell");
    defer surface.deinit(allocator);

    try std.testing.expect(uuid_util.eql(surface.id, id));
    try std.testing.expectEqualStrings("/home/user/project", surface.working_directory);
    try std.testing.expectEqualStrings("my shell", surface.custom_title.?);
}

test "SurfaceState init with null custom_title" {
    const allocator = std.testing.allocator;

    const id = uuid_util.generate();
    var surface = try SurfaceState.init(allocator, id, "/tmp", null);
    defer surface.deinit(allocator);

    try std.testing.expect(surface.custom_title == null);
}

test "TabState init and deinit with leaf layout" {
    const allocator = std.testing.allocator;

    const tab_id = uuid_util.generate();
    const surf_id = uuid_util.generate();
    const layout = SplitLayout{ .leaf = .{ .surface_id = surf_id } };

    var tab = try TabState.init(allocator, tab_id, "Terminal 1", layout);
    defer tab.deinit(allocator);

    try std.testing.expect(uuid_util.eql(tab.id, tab_id));
    try std.testing.expectEqualStrings("Terminal 1", tab.title.?);
    try std.testing.expect(tab.split_layout == .leaf);
    try std.testing.expect(uuid_util.eql(tab.split_layout.leaf.surface_id, surf_id));
}

test "TabState init and deinit with split layout" {
    const allocator = std.testing.allocator;

    const tab_id = uuid_util.generate();
    const left_id = uuid_util.generate();
    const right_id = uuid_util.generate();

    const left = try allocator.create(SplitLayout);
    left.* = SplitLayout{ .leaf = .{ .surface_id = left_id } };
    const right = try allocator.create(SplitLayout);
    right.* = SplitLayout{ .leaf = .{ .surface_id = right_id } };

    const layout = SplitLayout{ .split = .{
        .direction = .horizontal,
        .ratio = 0.5,
        .first = left,
        .second = right,
    } };

    var tab = try TabState.init(allocator, tab_id, "Split Tab", layout);
    defer tab.deinit(allocator);

    try std.testing.expect(tab.split_layout == .split);
    try std.testing.expectEqual(SplitDirection.horizontal, tab.split_layout.split.direction);
    try std.testing.expectEqual(@as(f64, 0.5), tab.split_layout.split.ratio);
}

test "Notification init and deinit" {
    const allocator = std.testing.allocator;

    const ws_id = uuid_util.generate();
    const surf_id = uuid_util.generate();

    var notif = try Notification.init(
        allocator,
        42,
        ws_id,
        surf_id,
        "Build finished",
        "cargo build succeeded",
        1700000000,
        false,
        .cli,
    );
    defer notif.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 42), notif.id);
    try std.testing.expect(uuid_util.eql(notif.workspace_id, ws_id));
    try std.testing.expect(uuid_util.eql(notif.surface_id.?, surf_id));
    try std.testing.expectEqualStrings("Build finished", notif.title);
    try std.testing.expectEqualStrings("cargo build succeeded", notif.body);
    try std.testing.expectEqual(@as(i64, 1700000000), notif.timestamp);
    try std.testing.expectEqual(false, notif.read);
    try std.testing.expectEqual(NotificationSource.cli, notif.source);
}

test "Notification init and deinit with null surface_id" {
    const allocator = std.testing.allocator;

    const ws_id = uuid_util.generate();

    var notif = try Notification.init(
        allocator,
        1,
        ws_id,
        null,
        "Hello",
        "World",
        0,
        true,
        .osc,
    );
    defer notif.deinit(allocator);

    try std.testing.expect(notif.surface_id == null);
    try std.testing.expectEqual(NotificationSource.osc, notif.source);
}

test "WorkspaceState init and deinit with no tabs" {
    const allocator = std.testing.allocator;

    const ws_id = uuid_util.generate();
    const ports = try allocator.dupe(u16, &[_]u16{ 3000, 8080 });
    const tabs = try allocator.alloc(TabState, 0);

    var ws = try WorkspaceState.init(
        allocator,
        ws_id,
        "my-workspace",
        "/home/user",
        "main",
        false,
        ports,
        0,
        tabs,
    );
    defer ws.deinit(allocator);

    try std.testing.expect(uuid_util.eql(ws.id, ws_id));
    try std.testing.expectEqualStrings("my-workspace", ws.name);
    try std.testing.expectEqualStrings("/home/user", ws.working_directory);
    try std.testing.expectEqualStrings("main", ws.git_branch.?);
    try std.testing.expectEqual(false, ws.git_dirty);
    try std.testing.expectEqual(@as(usize, 2), ws.listening_ports.len);
    try std.testing.expectEqual(@as(u16, 3000), ws.listening_ports[0]);
    try std.testing.expectEqual(@as(u16, 8080), ws.listening_ports[1]);
    try std.testing.expectEqual(@as(u32, 0), ws.unread_count);
    try std.testing.expectEqual(@as(usize, 0), ws.tabs.len);
}

test "WorkspaceState init and deinit with null git_branch" {
    const allocator = std.testing.allocator;

    const ws_id = uuid_util.generate();
    const ports = try allocator.alloc(u16, 0);
    const tabs = try allocator.alloc(TabState, 0);

    var ws = try WorkspaceState.init(
        allocator,
        ws_id,
        "detached",
        "/tmp",
        null,
        false,
        ports,
        0,
        tabs,
    );
    defer ws.deinit(allocator);

    try std.testing.expect(ws.git_branch == null);
}

test "WorkspaceState init and deinit with tabs" {
    const allocator = std.testing.allocator;

    // Build two tabs
    const surf_a = uuid_util.generate();
    const surf_b = uuid_util.generate();

    var tabs = try allocator.alloc(TabState, 2);
    tabs[0] = try TabState.init(
        allocator,
        uuid_util.generate(),
        "Tab A",
        SplitLayout{ .leaf = .{ .surface_id = surf_a } },
    );
    tabs[1] = try TabState.init(
        allocator,
        uuid_util.generate(),
        "Tab B",
        SplitLayout{ .leaf = .{ .surface_id = surf_b } },
    );

    const ports = try allocator.alloc(u16, 0);
    const ws_id = uuid_util.generate();

    var ws = try WorkspaceState.init(
        allocator,
        ws_id,
        "workspace-with-tabs",
        "/projects",
        null,
        true,
        ports,
        2,
        tabs,
    );
    defer ws.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), ws.tabs.len);
    try std.testing.expectEqualStrings("Tab A", ws.tabs[0].title.?);
    try std.testing.expectEqualStrings("Tab B", ws.tabs[1].title.?);
    try std.testing.expectEqual(@as(u32, 2), ws.unread_count);
    try std.testing.expectEqual(true, ws.git_dirty);
}

test "SplitLayout leaf JSON round-trip" {
    const allocator = std.testing.allocator;

    const surf_id = uuid_util.generate();
    const layout = SplitLayout{ .leaf = .{ .surface_id = surf_id } };

    const json = try layout.toJson(allocator);
    defer allocator.free(json);

    var parsed = try SplitLayout.fromJson(allocator, json);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed == .leaf);
    try std.testing.expect(uuid_util.eql(parsed.leaf.surface_id, surf_id));
}

test "SplitLayout split JSON round-trip" {
    const allocator = std.testing.allocator;

    const left_id = uuid_util.generate();
    const right_id = uuid_util.generate();

    const left = try allocator.create(SplitLayout);
    left.* = SplitLayout{ .leaf = .{ .surface_id = left_id } };
    const right = try allocator.create(SplitLayout);
    right.* = SplitLayout{ .leaf = .{ .surface_id = right_id } };

    var layout = SplitLayout{ .split = .{
        .direction = .vertical,
        .ratio = 0.3,
        .first = left,
        .second = right,
    } };
    defer layout.deinit(allocator);

    const json = try layout.toJson(allocator);
    defer allocator.free(json);

    var parsed = try SplitLayout.fromJson(allocator, json);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed == .split);
    try std.testing.expectEqual(SplitDirection.vertical, parsed.split.direction);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), parsed.split.ratio, 1e-9);
    try std.testing.expect(parsed.split.first.* == .leaf);
    try std.testing.expect(parsed.split.second.* == .leaf);
    try std.testing.expect(uuid_util.eql(parsed.split.first.leaf.surface_id, left_id));
    try std.testing.expect(uuid_util.eql(parsed.split.second.leaf.surface_id, right_id));
}

test "SplitLayout nested split JSON round-trip" {
    const allocator = std.testing.allocator;

    // Build:  (A | (B / C))   horizontal split at top level
    const id_a = uuid_util.generate();
    const id_b = uuid_util.generate();
    const id_c = uuid_util.generate();

    const leaf_a = try allocator.create(SplitLayout);
    leaf_a.* = SplitLayout{ .leaf = .{ .surface_id = id_a } };

    const leaf_b = try allocator.create(SplitLayout);
    leaf_b.* = SplitLayout{ .leaf = .{ .surface_id = id_b } };
    const leaf_c = try allocator.create(SplitLayout);
    leaf_c.* = SplitLayout{ .leaf = .{ .surface_id = id_c } };

    const inner = try allocator.create(SplitLayout);
    inner.* = SplitLayout{ .split = .{
        .direction = .vertical,
        .ratio = 0.5,
        .first = leaf_b,
        .second = leaf_c,
    } };

    var root = SplitLayout{ .split = .{
        .direction = .horizontal,
        .ratio = 0.4,
        .first = leaf_a,
        .second = inner,
    } };
    defer root.deinit(allocator);

    const json = try root.toJson(allocator);
    defer allocator.free(json);

    var parsed = try SplitLayout.fromJson(allocator, json);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed == .split);
    try std.testing.expectEqual(SplitDirection.horizontal, parsed.split.direction);
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), parsed.split.ratio, 1e-9);

    const parsed_first = parsed.split.first.*;
    try std.testing.expect(parsed_first == .leaf);
    try std.testing.expect(uuid_util.eql(parsed_first.leaf.surface_id, id_a));

    const parsed_second = parsed.split.second.*;
    try std.testing.expect(parsed_second == .split);
    try std.testing.expectEqual(SplitDirection.vertical, parsed_second.split.direction);
    try std.testing.expect(parsed_second.split.first.* == .leaf);
    try std.testing.expect(uuid_util.eql(parsed_second.split.first.leaf.surface_id, id_b));
    try std.testing.expect(parsed_second.split.second.* == .leaf);
    try std.testing.expect(uuid_util.eql(parsed_second.split.second.leaf.surface_id, id_c));
}

test "SplitLayout fromJson rejects invalid type" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidSplitLayout,
        SplitLayout.fromJson(allocator, "{\"type\":\"unknown\"}"),
    );
}

test "SplitLayout fromJson rejects missing type field" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidSplitLayout,
        SplitLayout.fromJson(allocator, "{\"surface_id\":\"abc\"}"),
    );
}

test "SplitLayout fromJson rejects invalid surface_id" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidSplitLayout,
        SplitLayout.fromJson(allocator, "{\"type\":\"leaf\",\"surface_id\":\"not-a-uuid\"}"),
    );
}

test "SplitLayout clone" {
    const allocator = std.testing.allocator;

    const id_x = uuid_util.generate();
    const id_y = uuid_util.generate();

    const child_a = try allocator.create(SplitLayout);
    child_a.* = SplitLayout{ .leaf = .{ .surface_id = id_x } };
    const child_b = try allocator.create(SplitLayout);
    child_b.* = SplitLayout{ .leaf = .{ .surface_id = id_y } };

    var original = SplitLayout{ .split = .{
        .direction = .horizontal,
        .ratio = 0.6,
        .first = child_a,
        .second = child_b,
    } };
    defer original.deinit(allocator);

    var cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);

    // Mutate original to verify independence
    original.split.ratio = 0.9;

    try std.testing.expectApproxEqAbs(@as(f64, 0.6), cloned.split.ratio, 1e-9);
    try std.testing.expect(uuid_util.eql(cloned.split.first.leaf.surface_id, id_x));
    try std.testing.expect(uuid_util.eql(cloned.split.second.leaf.surface_id, id_y));
}

test "SplitLayout leaf JSON format" {
    const allocator = std.testing.allocator;

    // Use a known UUID to verify exact JSON output
    const surf_id = try uuid_util.parse("550e8400-e29b-41d4-a716-446655440000");
    const layout = SplitLayout{ .leaf = .{ .surface_id = surf_id } };

    const json = try layout.toJson(allocator);
    defer allocator.free(json);

    const parsed_val = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed_val.deinit();

    const obj = parsed_val.value.object;
    try std.testing.expectEqualStrings("leaf", obj.get("type").?.string);
    try std.testing.expectEqualStrings("550e8400-e29b-41d4-a716-446655440000", obj.get("surface_id").?.string);
}

test "SplitLayout split JSON format" {
    const allocator = std.testing.allocator;

    const left_id = try uuid_util.parse("550e8400-e29b-41d4-a716-446655440001");
    const right_id = try uuid_util.parse("550e8400-e29b-41d4-a716-446655440002");

    const left = try allocator.create(SplitLayout);
    left.* = SplitLayout{ .leaf = .{ .surface_id = left_id } };
    const right = try allocator.create(SplitLayout);
    right.* = SplitLayout{ .leaf = .{ .surface_id = right_id } };

    var layout = SplitLayout{ .split = .{
        .direction = .horizontal,
        .ratio = 0.5,
        .first = left,
        .second = right,
    } };
    defer layout.deinit(allocator);

    const json = try layout.toJson(allocator);
    defer allocator.free(json);

    const parsed_val = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed_val.deinit();

    const obj = parsed_val.value.object;
    try std.testing.expectEqualStrings("split", obj.get("type").?.string);
    try std.testing.expectEqualStrings("horizontal", obj.get("direction").?.string);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), obj.get("ratio").?.float, 1e-9);
}
