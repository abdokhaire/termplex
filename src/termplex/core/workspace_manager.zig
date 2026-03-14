// src/termplex/core/workspace_manager.zig
// Manages an ordered list of WorkspaceState objects with CRUD operations.
//
// WorkspaceManager owns all WorkspaceState objects. Use `init`/`deinit` for
// lifecycle management. The manager allocates storage dynamically via the
// provided allocator.

const std = @import("std");
const workspace_mod = @import("workspace.zig");
const uuid_mod = @import("uuid");

const Uuid = uuid_mod.Uuid;
const WorkspaceState = workspace_mod.WorkspaceState;
const TabState = workspace_mod.TabState;
const SplitLayout = workspace_mod.SplitLayout;

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

pub const WorkspaceError = error{
    NotFound,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// WorkspaceManager
// ---------------------------------------------------------------------------

/// Manages an ordered collection of WorkspaceState objects.
///
/// Owns all workspaces. Call `deinit` to free all memory.
pub const WorkspaceManager = struct {
    allocator: std.mem.Allocator,
    /// Ordered list of workspaces. WorkspaceManager owns each element.
    items: std.ArrayListUnmanaged(WorkspaceState),
    /// UUID of the currently active workspace, or null if no workspaces exist.
    active_id: ?Uuid,

    /// Create an empty WorkspaceManager.
    pub fn init(allocator: std.mem.Allocator) WorkspaceManager {
        return .{
            .allocator = allocator,
            .items = .{},
            .active_id = null,
        };
    }

    /// Free all owned memory, including all WorkspaceState objects.
    pub fn deinit(self: *WorkspaceManager) void {
        for (self.items.items) |*ws| {
            ws.deinit(self.allocator);
        }
        self.items.deinit(self.allocator);
    }

    // -----------------------------------------------------------------------
    // CRUD Operations
    // -----------------------------------------------------------------------

    /// Create a new workspace with the given name and working_directory.
    ///
    /// Generates a new UUID for the workspace and creates one default tab
    /// with a single leaf surface. The new workspace is appended to the end
    /// of the list. If this is the first workspace, it becomes active.
    ///
    /// Returns a pointer to the newly created WorkspaceState (valid until
    /// the next structural modification of the manager's list).
    pub fn create(
        self: *WorkspaceManager,
        name: []const u8,
        working_directory: []const u8,
    ) WorkspaceError!*WorkspaceState {
        const ws_id = uuid_mod.generate();
        const tab_id = uuid_mod.generate();
        const surface_id = uuid_mod.generate();

        // Build default tab with a single leaf surface
        const layout = SplitLayout{ .leaf = .{ .surface_id = surface_id } };
        const tab = TabState.init(self.allocator, tab_id, null, layout) catch return error.OutOfMemory;

        // Allocate the tabs slice (ownership transferred to WorkspaceState)
        const tabs = self.allocator.alloc(TabState, 1) catch return error.OutOfMemory;
        tabs[0] = tab;
        errdefer {
            // tabs[0] already initialized; deinit it if WorkspaceState.init fails
            tabs[0].deinit(self.allocator);
            self.allocator.free(tabs);
        }

        // Empty listening_ports slice
        const ports = self.allocator.alloc(u16, 0) catch {
            tabs[0].deinit(self.allocator);
            self.allocator.free(tabs);
            return error.OutOfMemory;
        };
        errdefer self.allocator.free(ports);

        const ws = WorkspaceState.init(
            self.allocator,
            ws_id,
            name,
            working_directory,
            null, // git_branch
            false, // git_dirty
            ports,
            0, // unread_count
            tabs,
        ) catch return error.OutOfMemory;

        self.items.append(self.allocator, ws) catch {
            // ws.deinit frees name, wd, ports, tabs
            var ws_mut = ws;
            ws_mut.deinit(self.allocator);
            return error.OutOfMemory;
        };

        // If this is the first workspace, make it active
        if (self.active_id == null) {
            self.active_id = ws_id;
        }

        return &self.items.items[self.items.items.len - 1];
    }

    /// Set the active workspace by UUID.
    ///
    /// Returns error.NotFound if no workspace with the given ID exists.
    pub fn select(self: *WorkspaceManager, id: Uuid) WorkspaceError!void {
        if (self.findByUUID(id) == null) return error.NotFound;
        self.active_id = id;
    }

    /// Remove the workspace with the given UUID.
    ///
    /// If the removed workspace was the active one, selects the workspace
    /// immediately preceding it (or the next one if it was first). If the
    /// list becomes empty, active_id is set to null.
    ///
    /// Returns error.NotFound if no workspace with the given ID exists.
    pub fn remove(self: *WorkspaceManager, id: Uuid) WorkspaceError!void {
        const idx = self.indexOfUUID(id) orelse return error.NotFound;

        const was_active = if (self.active_id) |aid| uuid_mod.eql(aid, id) else false;

        // Deinit and remove from list
        self.items.items[idx].deinit(self.allocator);
        _ = self.items.orderedRemove(idx);

        if (self.items.items.len == 0) {
            self.active_id = null;
            return;
        }

        if (was_active) {
            // Select the previous item, or the new first item if idx was 0
            const new_idx = if (idx > 0) idx - 1 else 0;
            self.active_id = self.items.items[new_idx].id;
        }
    }

    /// Rename the workspace with the given UUID.
    ///
    /// Returns error.NotFound if no workspace with the given ID exists.
    pub fn rename(self: *WorkspaceManager, id: Uuid, new_name: []const u8) WorkspaceError!void {
        const ws = self.findByUUID(id) orelse return error.NotFound;

        const new_name_owned = self.allocator.dupe(u8, new_name) catch return error.OutOfMemory;
        self.allocator.free(ws.name);
        ws.name = new_name_owned;
    }

    // -----------------------------------------------------------------------
    // Queries
    // -----------------------------------------------------------------------

    /// Return a pointer to the workspace with the given UUID, or null.
    ///
    /// The pointer is valid until the next structural modification
    /// (create/remove) of the manager's list.
    pub fn findByUUID(self: *WorkspaceManager, id: Uuid) ?*WorkspaceState {
        for (self.items.items) |*ws| {
            if (uuid_mod.eql(ws.id, id)) return ws;
        }
        return null;
    }

    /// Return a pointer to the workspace at the given ordinal index, or null.
    ///
    /// The pointer is valid until the next structural modification.
    pub fn findByIndex(self: *WorkspaceManager, index: usize) ?*WorkspaceState {
        if (index >= self.items.items.len) return null;
        return &self.items.items[index];
    }

    /// Return a pointer to the currently active workspace, or null if there
    /// are no workspaces.
    pub fn activeWorkspace(self: *WorkspaceManager) ?*WorkspaceState {
        const aid = self.active_id orelse return null;
        return self.findByUUID(aid);
    }

    /// Return the number of workspaces.
    pub fn count(self: *const WorkspaceManager) usize {
        return self.items.items.len;
    }

    /// Return a slice of all workspaces. Valid until the next structural
    /// modification.
    pub fn workspaces(self: *WorkspaceManager) []WorkspaceState {
        return self.items.items;
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    fn indexOfUUID(self: *WorkspaceManager, id: Uuid) ?usize {
        for (self.items.items, 0..) |*ws, i| {
            if (uuid_mod.eql(ws.id, id)) return i;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "WorkspaceManager init and deinit (empty)" {
    const allocator = std.testing.allocator;
    var mgr = WorkspaceManager.init(allocator);
    defer mgr.deinit();

    try std.testing.expectEqual(@as(usize, 0), mgr.count());
    try std.testing.expect(mgr.activeWorkspace() == null);
}

test "WorkspaceManager create adds workspace and sets active" {
    const allocator = std.testing.allocator;
    var mgr = WorkspaceManager.init(allocator);
    defer mgr.deinit();

    const ws = try mgr.create("alpha", "/home/user/alpha");

    try std.testing.expectEqual(@as(usize, 1), mgr.count());
    try std.testing.expectEqualStrings("alpha", ws.name);
    try std.testing.expectEqualStrings("/home/user/alpha", ws.working_directory);

    // Should have exactly one default tab
    try std.testing.expectEqual(@as(usize, 1), ws.tabs.len);
    // Default tab has a leaf layout
    try std.testing.expect(ws.tabs[0].split_layout == .leaf);

    // First workspace becomes active
    const active = mgr.activeWorkspace();
    try std.testing.expect(active != null);
    try std.testing.expect(uuid_mod.eql(active.?.id, ws.id));
}

test "WorkspaceManager create multiple workspaces preserves order" {
    const allocator = std.testing.allocator;
    var mgr = WorkspaceManager.init(allocator);
    defer mgr.deinit();

    _ = try mgr.create("first", "/tmp/first");
    _ = try mgr.create("second", "/tmp/second");
    _ = try mgr.create("third", "/tmp/third");

    try std.testing.expectEqual(@as(usize, 3), mgr.count());
    const all = mgr.workspaces();
    try std.testing.expectEqualStrings("first", all[0].name);
    try std.testing.expectEqualStrings("second", all[1].name);
    try std.testing.expectEqualStrings("third", all[2].name);
}

test "WorkspaceManager create second workspace does not change active" {
    const allocator = std.testing.allocator;
    var mgr = WorkspaceManager.init(allocator);
    defer mgr.deinit();

    const ws1 = try mgr.create("one", "/tmp/one");
    const ws1_id = ws1.id;
    _ = try mgr.create("two", "/tmp/two");

    // Active should still be the first workspace
    const active = mgr.activeWorkspace();
    try std.testing.expect(active != null);
    try std.testing.expect(uuid_mod.eql(active.?.id, ws1_id));
}

test "WorkspaceManager select changes active workspace" {
    const allocator = std.testing.allocator;
    var mgr = WorkspaceManager.init(allocator);
    defer mgr.deinit();

    _ = try mgr.create("one", "/tmp/one");
    const ws2 = try mgr.create("two", "/tmp/two");
    const ws2_id = ws2.id;

    try mgr.select(ws2_id);

    const active = mgr.activeWorkspace();
    try std.testing.expect(active != null);
    try std.testing.expect(uuid_mod.eql(active.?.id, ws2_id));
}

test "WorkspaceManager select returns NotFound for unknown ID" {
    const allocator = std.testing.allocator;
    var mgr = WorkspaceManager.init(allocator);
    defer mgr.deinit();

    _ = try mgr.create("one", "/tmp/one");
    const unknown = uuid_mod.generate();

    try std.testing.expectError(error.NotFound, mgr.select(unknown));
}

test "WorkspaceManager remove only workspace sets active to null" {
    const allocator = std.testing.allocator;
    var mgr = WorkspaceManager.init(allocator);
    defer mgr.deinit();

    const ws = try mgr.create("solo", "/tmp/solo");
    const ws_id = ws.id;

    try mgr.remove(ws_id);

    try std.testing.expectEqual(@as(usize, 0), mgr.count());
    try std.testing.expect(mgr.activeWorkspace() == null);
}

test "WorkspaceManager remove active workspace selects previous" {
    const allocator = std.testing.allocator;
    var mgr = WorkspaceManager.init(allocator);
    defer mgr.deinit();

    const ws1 = try mgr.create("one", "/tmp/one");
    const ws1_id = ws1.id;
    const ws2 = try mgr.create("two", "/tmp/two");
    const ws2_id = ws2.id;
    const ws3 = try mgr.create("three", "/tmp/three");
    const ws3_id = ws3.id;

    // Select ws3 as active, then remove it
    try mgr.select(ws3_id);
    try mgr.remove(ws3_id);

    try std.testing.expectEqual(@as(usize, 2), mgr.count());
    // Should have fallen back to ws2 (index 1, the previous one)
    const active = mgr.activeWorkspace();
    try std.testing.expect(active != null);
    try std.testing.expect(uuid_mod.eql(active.?.id, ws2_id));
    _ = ws1_id;
}

test "WorkspaceManager remove first active workspace selects next" {
    const allocator = std.testing.allocator;
    var mgr = WorkspaceManager.init(allocator);
    defer mgr.deinit();

    const ws1 = try mgr.create("one", "/tmp/one");
    const ws1_id = ws1.id;
    const ws2 = try mgr.create("two", "/tmp/two");
    const ws2_id = ws2.id;

    // ws1 is active (first created); remove it
    try mgr.remove(ws1_id);

    try std.testing.expectEqual(@as(usize, 1), mgr.count());
    const active = mgr.activeWorkspace();
    try std.testing.expect(active != null);
    try std.testing.expect(uuid_mod.eql(active.?.id, ws2_id));
}

test "WorkspaceManager remove non-active workspace preserves active" {
    const allocator = std.testing.allocator;
    var mgr = WorkspaceManager.init(allocator);
    defer mgr.deinit();

    const ws1 = try mgr.create("one", "/tmp/one");
    const ws1_id = ws1.id;
    const ws2 = try mgr.create("two", "/tmp/two");
    const ws2_id = ws2.id;

    // ws1 is active; remove ws2
    try mgr.remove(ws2_id);

    try std.testing.expectEqual(@as(usize, 1), mgr.count());
    const active = mgr.activeWorkspace();
    try std.testing.expect(active != null);
    try std.testing.expect(uuid_mod.eql(active.?.id, ws1_id));
}

test "WorkspaceManager remove returns NotFound for unknown ID" {
    const allocator = std.testing.allocator;
    var mgr = WorkspaceManager.init(allocator);
    defer mgr.deinit();

    _ = try mgr.create("one", "/tmp/one");
    const unknown = uuid_mod.generate();

    try std.testing.expectError(error.NotFound, mgr.remove(unknown));
}

test "WorkspaceManager rename updates name" {
    const allocator = std.testing.allocator;
    var mgr = WorkspaceManager.init(allocator);
    defer mgr.deinit();

    const ws = try mgr.create("original", "/tmp/ws");
    const ws_id = ws.id;

    try mgr.rename(ws_id, "renamed");

    const found = mgr.findByUUID(ws_id);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("renamed", found.?.name);
}

test "WorkspaceManager rename returns NotFound for unknown ID" {
    const allocator = std.testing.allocator;
    var mgr = WorkspaceManager.init(allocator);
    defer mgr.deinit();

    _ = try mgr.create("ws", "/tmp/ws");
    const unknown = uuid_mod.generate();

    try std.testing.expectError(error.NotFound, mgr.rename(unknown, "new-name"));
}

test "WorkspaceManager findByUUID returns null for unknown ID" {
    const allocator = std.testing.allocator;
    var mgr = WorkspaceManager.init(allocator);
    defer mgr.deinit();

    _ = try mgr.create("ws", "/tmp/ws");
    const unknown = uuid_mod.generate();

    try std.testing.expect(mgr.findByUUID(unknown) == null);
}

test "WorkspaceManager findByIndex returns correct workspace" {
    const allocator = std.testing.allocator;
    var mgr = WorkspaceManager.init(allocator);
    defer mgr.deinit();

    _ = try mgr.create("alpha", "/tmp/alpha");
    _ = try mgr.create("beta", "/tmp/beta");

    const at0 = mgr.findByIndex(0);
    const at1 = mgr.findByIndex(1);
    const at2 = mgr.findByIndex(2);

    try std.testing.expect(at0 != null);
    try std.testing.expectEqualStrings("alpha", at0.?.name);
    try std.testing.expect(at1 != null);
    try std.testing.expectEqualStrings("beta", at1.?.name);
    try std.testing.expect(at2 == null);
}

test "WorkspaceManager workspaces returns full slice" {
    const allocator = std.testing.allocator;
    var mgr = WorkspaceManager.init(allocator);
    defer mgr.deinit();

    _ = try mgr.create("a", "/tmp/a");
    _ = try mgr.create("b", "/tmp/b");
    _ = try mgr.create("c", "/tmp/c");

    const all = mgr.workspaces();
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expectEqualStrings("a", all[0].name);
    try std.testing.expectEqualStrings("b", all[1].name);
    try std.testing.expectEqualStrings("c", all[2].name);
}

test "WorkspaceManager generated UUIDs are unique" {
    const allocator = std.testing.allocator;
    var mgr = WorkspaceManager.init(allocator);
    defer mgr.deinit();

    const ws1 = try mgr.create("one", "/tmp/one");
    const id1 = ws1.id;
    const ws2 = try mgr.create("two", "/tmp/two");
    const id2 = ws2.id;

    try std.testing.expect(!uuid_mod.eql(id1, id2));
}

test "WorkspaceManager remove does not affect remaining workspace data" {
    const allocator = std.testing.allocator;
    var mgr = WorkspaceManager.init(allocator);
    defer mgr.deinit();

    _ = try mgr.create("keep", "/tmp/keep");
    const ws2 = try mgr.create("remove-me", "/tmp/remove");
    const ws2_id = ws2.id;
    _ = try mgr.create("also-keep", "/tmp/also-keep");

    try mgr.remove(ws2_id);

    const all = mgr.workspaces();
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqualStrings("keep", all[0].name);
    try std.testing.expectEqualStrings("also-keep", all[1].name);
}
