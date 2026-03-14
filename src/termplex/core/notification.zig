// src/termplex/core/notification.zig
// NotificationStore: stores and manages notifications across all workspaces.
//
// Key behaviours:
//   - Max 100 notifications per workspace; oldest evicted when full.
//   - Monotonic u64 IDs starting at 1.
//   - Store owns all notification memory (strings are duped on add).

const std = @import("std");
const workspace_mod = @import("workspace.zig");
const uuid_mod = @import("uuid");

const Uuid = uuid_mod.Uuid;
pub const Notification = workspace_mod.Notification;
pub const NotificationSource = workspace_mod.NotificationSource;

/// Maximum notifications retained per workspace before eviction.
pub const max_per_workspace: usize = 100;

// ---------------------------------------------------------------------------
// NotificationStore
// ---------------------------------------------------------------------------

/// Stores notifications across all workspaces.
///
/// All Notification objects are owned by the store. Strings inside each
/// Notification are duplicated on `add` and freed on removal/eviction.
/// Call `deinit` to release all memory.
pub const NotificationStore = struct {
    allocator: std.mem.Allocator,
    /// All notifications, in insertion order (oldest first).
    notifications: std.ArrayListUnmanaged(Notification),
    /// Monotonic counter; incremented before each add.
    next_id: u64,

    /// Create an empty NotificationStore.
    pub fn init(allocator: std.mem.Allocator) NotificationStore {
        return .{
            .allocator = allocator,
            .notifications = .{},
            .next_id = 1,
        };
    }

    /// Free all owned memory.
    pub fn deinit(self: *NotificationStore) void {
        for (self.notifications.items) |*n| {
            n.deinit(self.allocator);
        }
        self.notifications.deinit(self.allocator);
    }

    // -----------------------------------------------------------------------
    // Mutation
    // -----------------------------------------------------------------------

    /// Add a notification for the given workspace.
    ///
    /// Assigns the next monotonic ID, records the current Unix timestamp, and
    /// marks the notification as unread. If the workspace already has
    /// `max_per_workspace` notifications the oldest one for that workspace is
    /// evicted first.
    ///
    /// Returns the new notification's ID.
    pub fn add(
        self: *NotificationStore,
        workspace_id: Uuid,
        surface_id: ?Uuid,
        title: []const u8,
        body: []const u8,
        source: NotificationSource,
    ) !u64 {
        // Evict the oldest notification for this workspace if at capacity.
        if (self.countForWorkspace(workspace_id) >= max_per_workspace) {
            self.evictOldestForWorkspace(workspace_id);
        }

        const id = self.next_id;
        self.next_id += 1;

        const timestamp = std.time.timestamp();

        const n = try Notification.init(
            self.allocator,
            id,
            workspace_id,
            surface_id,
            title,
            body,
            timestamp,
            false, // unread
            source,
        );

        try self.notifications.append(self.allocator, n);
        return id;
    }

    /// Mark the notification with the given ID as read.
    ///
    /// No-ops silently if the ID is not found.
    pub fn markRead(self: *NotificationStore, notification_id: u64) void {
        for (self.notifications.items) |*n| {
            if (n.id == notification_id) {
                n.read = true;
                return;
            }
        }
    }

    /// Mark every notification for the given workspace as read.
    pub fn markAllReadForWorkspace(self: *NotificationStore, workspace_id: Uuid) void {
        for (self.notifications.items) |*n| {
            if (uuid_mod.eql(n.workspace_id, workspace_id)) {
                n.read = true;
            }
        }
    }

    /// Remove all notifications for the given workspace.
    pub fn clearWorkspace(self: *NotificationStore, workspace_id: Uuid) void {
        var i: usize = 0;
        while (i < self.notifications.items.len) {
            if (uuid_mod.eql(self.notifications.items[i].workspace_id, workspace_id)) {
                self.notifications.items[i].deinit(self.allocator);
                _ = self.notifications.orderedRemove(i);
                // Do not advance i; the next element has shifted into position i.
            } else {
                i += 1;
            }
        }
    }

    /// Remove all notifications across all workspaces.
    pub fn clearAll(self: *NotificationStore) void {
        for (self.notifications.items) |*n| {
            n.deinit(self.allocator);
        }
        self.notifications.clearRetainingCapacity();
    }

    // -----------------------------------------------------------------------
    // Queries
    // -----------------------------------------------------------------------

    /// Return the most recent unread notification across all workspaces.
    ///
    /// "Most recent" is determined by insertion order (highest ID). Returns
    /// null when there are no unread notifications.
    ///
    /// The returned pointer is valid until the next structural modification
    /// of the store.
    pub fn mostRecentUnread(self: *NotificationStore) ?*Notification {
        // Iterate in reverse to find the last-inserted unread notification.
        var i = self.notifications.items.len;
        while (i > 0) {
            i -= 1;
            const n = &self.notifications.items[i];
            if (!n.read) return n;
        }
        return null;
    }

    /// Return the number of unread notifications for the given workspace.
    pub fn unreadCountForWorkspace(self: *const NotificationStore, workspace_id: Uuid) usize {
        var count: usize = 0;
        for (self.notifications.items) |n| {
            if (uuid_mod.eql(n.workspace_id, workspace_id) and !n.read) {
                count += 1;
            }
        }
        return count;
    }

    /// Return a slice of all notifications for the given workspace.
    ///
    /// The returned slice is allocated with the store's allocator; the caller
    /// owns the slice but NOT the Notification values — do not free the
    /// individual notifications.
    pub fn listForWorkspace(
        self: *const NotificationStore,
        workspace_id: Uuid,
    ) ![]Notification {
        var result = std.ArrayListUnmanaged(Notification){};
        errdefer result.deinit(self.allocator);

        for (self.notifications.items) |n| {
            if (uuid_mod.eql(n.workspace_id, workspace_id)) {
                try result.append(self.allocator, n);
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    /// Count notifications belonging to the given workspace.
    fn countForWorkspace(self: *const NotificationStore, workspace_id: Uuid) usize {
        var count: usize = 0;
        for (self.notifications.items) |n| {
            if (uuid_mod.eql(n.workspace_id, workspace_id)) count += 1;
        }
        return count;
    }

    /// Evict the oldest (earliest in the list) notification for a workspace.
    /// No-op if the workspace has no notifications.
    fn evictOldestForWorkspace(self: *NotificationStore, workspace_id: Uuid) void {
        for (self.notifications.items, 0..) |*n, i| {
            if (uuid_mod.eql(n.workspace_id, workspace_id)) {
                n.deinit(self.allocator);
                _ = self.notifications.orderedRemove(i);
                return;
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "NotificationStore init and deinit empty" {
    const allocator = std.testing.allocator;
    var store = NotificationStore.init(allocator);
    defer store.deinit();

    try std.testing.expectEqual(@as(usize, 0), store.notifications.items.len);
}

test "NotificationStore add returns incrementing IDs" {
    const allocator = std.testing.allocator;
    var store = NotificationStore.init(allocator);
    defer store.deinit();

    const ws = uuid_mod.generate();
    const id1 = try store.add(ws, null, "A", "body a", .osc);
    const id2 = try store.add(ws, null, "B", "body b", .cli);
    const id3 = try store.add(ws, null, "C", "body c", .osc);

    try std.testing.expectEqual(@as(u64, 1), id1);
    try std.testing.expectEqual(@as(u64, 2), id2);
    try std.testing.expectEqual(@as(u64, 3), id3);
}

test "NotificationStore add stores correct fields" {
    const allocator = std.testing.allocator;
    var store = NotificationStore.init(allocator);
    defer store.deinit();

    const ws = uuid_mod.generate();
    const surf = uuid_mod.generate();
    _ = try store.add(ws, surf, "hello", "world", .cli);

    const n = store.notifications.items[0];
    try std.testing.expectEqual(@as(u64, 1), n.id);
    try std.testing.expect(uuid_mod.eql(n.workspace_id, ws));
    try std.testing.expect(uuid_mod.eql(n.surface_id.?, surf));
    try std.testing.expectEqualStrings("hello", n.title);
    try std.testing.expectEqualStrings("world", n.body);
    try std.testing.expectEqual(false, n.read);
    try std.testing.expectEqual(NotificationSource.cli, n.source);
}

test "NotificationStore add with null surface_id" {
    const allocator = std.testing.allocator;
    var store = NotificationStore.init(allocator);
    defer store.deinit();

    const ws = uuid_mod.generate();
    _ = try store.add(ws, null, "title", "body", .osc);

    try std.testing.expect(store.notifications.items[0].surface_id == null);
}

test "NotificationStore evicts oldest when workspace reaches capacity" {
    const allocator = std.testing.allocator;
    var store = NotificationStore.init(allocator);
    defer store.deinit();

    const ws = uuid_mod.generate();

    // Fill to capacity.
    var i: usize = 0;
    while (i < max_per_workspace) : (i += 1) {
        _ = try store.add(ws, null, "t", "b", .osc);
    }
    try std.testing.expectEqual(max_per_workspace, store.notifications.items.len);

    // The oldest notification should have id == 1.
    try std.testing.expectEqual(@as(u64, 1), store.notifications.items[0].id);

    // Add one more — should evict id 1.
    const new_id = try store.add(ws, null, "new", "new body", .osc);
    try std.testing.expectEqual(@as(usize, max_per_workspace), store.notifications.items.len);
    // Oldest is now id 2.
    try std.testing.expectEqual(@as(u64, 2), store.notifications.items[0].id);
    try std.testing.expectEqual(@as(u64, max_per_workspace + 1), new_id);
}

test "NotificationStore eviction only affects the target workspace" {
    const allocator = std.testing.allocator;
    var store = NotificationStore.init(allocator);
    defer store.deinit();

    const ws_a = uuid_mod.generate();
    const ws_b = uuid_mod.generate();

    // Fill ws_a to capacity.
    var i: usize = 0;
    while (i < max_per_workspace) : (i += 1) {
        _ = try store.add(ws_a, null, "a", "body", .osc);
    }

    // Add one notification for ws_b.
    _ = try store.add(ws_b, null, "b", "body", .osc);

    // Now add one more to ws_a — should evict the oldest ws_a notification.
    _ = try store.add(ws_a, null, "a-overflow", "body", .osc);

    try std.testing.expectEqual(@as(usize, max_per_workspace + 1), store.notifications.items.len);
    // ws_b's notification should still be there.
    try std.testing.expectEqual(@as(usize, 1), store.countForWorkspace(ws_b));
    try std.testing.expectEqual(@as(usize, max_per_workspace), store.countForWorkspace(ws_a));
}

test "NotificationStore markRead marks a notification as read" {
    const allocator = std.testing.allocator;
    var store = NotificationStore.init(allocator);
    defer store.deinit();

    const ws = uuid_mod.generate();
    const id = try store.add(ws, null, "t", "b", .osc);

    try std.testing.expectEqual(false, store.notifications.items[0].read);
    store.markRead(id);
    try std.testing.expectEqual(true, store.notifications.items[0].read);
}

test "NotificationStore markRead is a no-op for unknown ID" {
    const allocator = std.testing.allocator;
    var store = NotificationStore.init(allocator);
    defer store.deinit();

    const ws = uuid_mod.generate();
    _ = try store.add(ws, null, "t", "b", .osc);

    // Should not crash.
    store.markRead(9999);
    try std.testing.expectEqual(false, store.notifications.items[0].read);
}

test "NotificationStore markAllReadForWorkspace marks only that workspace" {
    const allocator = std.testing.allocator;
    var store = NotificationStore.init(allocator);
    defer store.deinit();

    const ws_a = uuid_mod.generate();
    const ws_b = uuid_mod.generate();

    _ = try store.add(ws_a, null, "a1", "b", .osc);
    _ = try store.add(ws_a, null, "a2", "b", .osc);
    _ = try store.add(ws_b, null, "b1", "b", .osc);

    store.markAllReadForWorkspace(ws_a);

    // Both ws_a notifications should be read.
    try std.testing.expectEqual(true, store.notifications.items[0].read);
    try std.testing.expectEqual(true, store.notifications.items[1].read);
    // ws_b notification should still be unread.
    try std.testing.expectEqual(false, store.notifications.items[2].read);
}

test "NotificationStore mostRecentUnread returns null when all read" {
    const allocator = std.testing.allocator;
    var store = NotificationStore.init(allocator);
    defer store.deinit();

    try std.testing.expect(store.mostRecentUnread() == null);

    const ws = uuid_mod.generate();
    const id = try store.add(ws, null, "t", "b", .osc);
    store.markRead(id);

    try std.testing.expect(store.mostRecentUnread() == null);
}

test "NotificationStore mostRecentUnread returns the most recently added unread" {
    const allocator = std.testing.allocator;
    var store = NotificationStore.init(allocator);
    defer store.deinit();

    const ws = uuid_mod.generate();
    const id1 = try store.add(ws, null, "first", "b", .osc);
    const id2 = try store.add(ws, null, "second", "b", .osc);
    _ = id1;

    const unread = store.mostRecentUnread();
    try std.testing.expect(unread != null);
    try std.testing.expectEqual(id2, unread.?.id);
}

test "NotificationStore mostRecentUnread skips read notifications" {
    const allocator = std.testing.allocator;
    var store = NotificationStore.init(allocator);
    defer store.deinit();

    const ws = uuid_mod.generate();
    const id1 = try store.add(ws, null, "first", "b", .osc);
    const id2 = try store.add(ws, null, "second", "b", .osc);

    store.markRead(id2);

    const unread = store.mostRecentUnread();
    try std.testing.expect(unread != null);
    try std.testing.expectEqual(id1, unread.?.id);
}

test "NotificationStore unreadCountForWorkspace" {
    const allocator = std.testing.allocator;
    var store = NotificationStore.init(allocator);
    defer store.deinit();

    const ws_a = uuid_mod.generate();
    const ws_b = uuid_mod.generate();

    try std.testing.expectEqual(@as(usize, 0), store.unreadCountForWorkspace(ws_a));

    const id1 = try store.add(ws_a, null, "a1", "b", .osc);
    _ = try store.add(ws_a, null, "a2", "b", .osc);
    _ = try store.add(ws_b, null, "b1", "b", .osc);

    try std.testing.expectEqual(@as(usize, 2), store.unreadCountForWorkspace(ws_a));
    try std.testing.expectEqual(@as(usize, 1), store.unreadCountForWorkspace(ws_b));

    store.markRead(id1);
    try std.testing.expectEqual(@as(usize, 1), store.unreadCountForWorkspace(ws_a));
}

test "NotificationStore clearWorkspace removes only that workspace" {
    const allocator = std.testing.allocator;
    var store = NotificationStore.init(allocator);
    defer store.deinit();

    const ws_a = uuid_mod.generate();
    const ws_b = uuid_mod.generate();

    _ = try store.add(ws_a, null, "a1", "b", .osc);
    _ = try store.add(ws_a, null, "a2", "b", .osc);
    _ = try store.add(ws_b, null, "b1", "b", .osc);

    store.clearWorkspace(ws_a);

    try std.testing.expectEqual(@as(usize, 1), store.notifications.items.len);
    try std.testing.expect(uuid_mod.eql(store.notifications.items[0].workspace_id, ws_b));
}

test "NotificationStore clearWorkspace on empty workspace is a no-op" {
    const allocator = std.testing.allocator;
    var store = NotificationStore.init(allocator);
    defer store.deinit();

    const ws_a = uuid_mod.generate();
    const ws_b = uuid_mod.generate();
    _ = try store.add(ws_a, null, "a", "b", .osc);

    store.clearWorkspace(ws_b); // should not crash

    try std.testing.expectEqual(@as(usize, 1), store.notifications.items.len);
}

test "NotificationStore clearAll removes everything" {
    const allocator = std.testing.allocator;
    var store = NotificationStore.init(allocator);
    defer store.deinit();

    const ws_a = uuid_mod.generate();
    const ws_b = uuid_mod.generate();
    _ = try store.add(ws_a, null, "a", "b", .osc);
    _ = try store.add(ws_b, null, "b", "b", .cli);

    store.clearAll();
    try std.testing.expectEqual(@as(usize, 0), store.notifications.items.len);
}

test "NotificationStore clearAll then add still works" {
    const allocator = std.testing.allocator;
    var store = NotificationStore.init(allocator);
    defer store.deinit();

    const ws = uuid_mod.generate();
    _ = try store.add(ws, null, "first", "b", .osc);
    store.clearAll();

    const id = try store.add(ws, null, "after-clear", "b", .cli);
    try std.testing.expectEqual(@as(usize, 1), store.notifications.items.len);
    // IDs continue from where the counter left off.
    try std.testing.expectEqual(@as(u64, 2), id);
}

test "NotificationStore listForWorkspace returns correct subset" {
    const allocator = std.testing.allocator;
    var store = NotificationStore.init(allocator);
    defer store.deinit();

    const ws_a = uuid_mod.generate();
    const ws_b = uuid_mod.generate();

    _ = try store.add(ws_a, null, "a1", "ba1", .osc);
    _ = try store.add(ws_b, null, "b1", "bb1", .cli);
    _ = try store.add(ws_a, null, "a2", "ba2", .osc);

    const list = try store.listForWorkspace(ws_a);
    defer allocator.free(list);

    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("a1", list[0].title);
    try std.testing.expectEqualStrings("a2", list[1].title);
}

test "NotificationStore listForWorkspace returns empty slice for unknown workspace" {
    const allocator = std.testing.allocator;
    var store = NotificationStore.init(allocator);
    defer store.deinit();

    const ws = uuid_mod.generate();
    const unknown = uuid_mod.generate();
    _ = try store.add(ws, null, "a", "b", .osc);

    const list = try store.listForWorkspace(unknown);
    defer allocator.free(list);

    try std.testing.expectEqual(@as(usize, 0), list.len);
}

test "NotificationStore IDs are monotonically increasing across workspaces" {
    const allocator = std.testing.allocator;
    var store = NotificationStore.init(allocator);
    defer store.deinit();

    const ws_a = uuid_mod.generate();
    const ws_b = uuid_mod.generate();

    const id1 = try store.add(ws_a, null, "t", "b", .osc);
    const id2 = try store.add(ws_b, null, "t", "b", .cli);
    const id3 = try store.add(ws_a, null, "t", "b", .osc);

    try std.testing.expect(id1 < id2);
    try std.testing.expect(id2 < id3);
}

test "NotificationStore mostRecentUnread across workspaces" {
    const allocator = std.testing.allocator;
    var store = NotificationStore.init(allocator);
    defer store.deinit();

    const ws_a = uuid_mod.generate();
    const ws_b = uuid_mod.generate();

    _ = try store.add(ws_a, null, "a1", "b", .osc);
    const id_b1 = try store.add(ws_b, null, "b1", "b", .cli);

    const unread = store.mostRecentUnread();
    try std.testing.expect(unread != null);
    try std.testing.expectEqual(id_b1, unread.?.id);
}
