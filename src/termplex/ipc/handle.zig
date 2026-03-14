// src/termplex/ipc/handle.zig
// Handle map for the termplex IPC protocol.
//
// CLI users reference workspaces and surfaces with sequential ordinal handles
// like "workspace:1", "workspace:2", "surface:1", etc.  The server maps these
// short references to internal UUIDs.
//
// HandleMap tracks the bidirectional mapping between UUIDs and ordinal indices
// for both workspaces and surfaces.  Ordinals are assigned in registration
// order starting at 1 and are never reused within a session.

const std = @import("std");
const uuid_mod = @import("uuid");
const Uuid = uuid_mod.Uuid;

// ---------------------------------------------------------------------------
// HandleMap
// ---------------------------------------------------------------------------

pub const HandleMap = struct {
    allocator: std.mem.Allocator,

    /// workspace UUID → ordinal (1-based)
    workspace_by_uuid: std.AutoHashMap(Uuid, u32),
    /// ordinal → workspace UUID
    workspace_by_ord: std.AutoHashMap(u32, Uuid),
    /// next ordinal to assign for workspaces
    workspace_next: u32,

    /// surface UUID → ordinal (1-based)
    surface_by_uuid: std.AutoHashMap(Uuid, u32),
    /// ordinal → surface UUID
    surface_by_ord: std.AutoHashMap(u32, Uuid),
    /// next ordinal to assign for surfaces
    surface_next: u32,

    // -----------------------------------------------------------------------
    // init / deinit
    // -----------------------------------------------------------------------

    pub fn init(allocator: std.mem.Allocator) HandleMap {
        return HandleMap{
            .allocator = allocator,
            .workspace_by_uuid = std.AutoHashMap(Uuid, u32).init(allocator),
            .workspace_by_ord = std.AutoHashMap(u32, Uuid).init(allocator),
            .workspace_next = 1,
            .surface_by_uuid = std.AutoHashMap(Uuid, u32).init(allocator),
            .surface_by_ord = std.AutoHashMap(u32, Uuid).init(allocator),
            .surface_next = 1,
        };
    }

    pub fn deinit(self: *HandleMap) void {
        self.workspace_by_uuid.deinit();
        self.workspace_by_ord.deinit();
        self.surface_by_uuid.deinit();
        self.surface_by_ord.deinit();
    }

    // -----------------------------------------------------------------------
    // Registration
    // -----------------------------------------------------------------------

    /// Register a workspace UUID and assign the next available ordinal.
    /// Returns the assigned ordinal.
    pub fn registerWorkspace(self: *HandleMap, uuid: Uuid) !u32 {
        const ord = self.workspace_next;
        try self.workspace_by_uuid.put(uuid, ord);
        try self.workspace_by_ord.put(ord, uuid);
        self.workspace_next += 1;
        return ord;
    }

    /// Register a surface UUID and assign the next available ordinal.
    /// Returns the assigned ordinal.
    pub fn registerSurface(self: *HandleMap, uuid: Uuid) !u32 {
        const ord = self.surface_next;
        try self.surface_by_uuid.put(uuid, ord);
        try self.surface_by_ord.put(ord, uuid);
        self.surface_next += 1;
        return ord;
    }

    // -----------------------------------------------------------------------
    // Unregistration
    // -----------------------------------------------------------------------

    /// Remove a workspace UUID from the map.  The ordinal is not reused.
    pub fn unregisterWorkspace(self: *HandleMap, uuid: Uuid) void {
        if (self.workspace_by_uuid.fetchRemove(uuid)) |entry| {
            _ = self.workspace_by_ord.remove(entry.value);
        }
    }

    /// Remove a surface UUID from the map.  The ordinal is not reused.
    pub fn unregisterSurface(self: *HandleMap, uuid: Uuid) void {
        if (self.surface_by_uuid.fetchRemove(uuid)) |entry| {
            _ = self.surface_by_ord.remove(entry.value);
        }
    }

    // -----------------------------------------------------------------------
    // Resolution
    // -----------------------------------------------------------------------

    /// Parse a "workspace:N" reference string and return the associated UUID.
    /// Returns error.NotFound if the ordinal is not registered.
    /// Returns error.InvalidRef if the string does not match the expected format.
    pub fn resolveWorkspace(self: *HandleMap, ref: []const u8) !Uuid {
        const ord = parseRef("workspace", ref) catch return error.InvalidRef;
        return self.workspace_by_ord.get(ord) orelse error.NotFound;
    }

    /// Parse a "surface:N" reference string and return the associated UUID.
    /// Returns error.NotFound if the ordinal is not registered.
    /// Returns error.InvalidRef if the string does not match the expected format.
    pub fn resolveSurface(self: *HandleMap, ref: []const u8) !Uuid {
        const ord = parseRef("surface", ref) catch return error.InvalidRef;
        return self.surface_by_ord.get(ord) orelse error.NotFound;
    }

    // -----------------------------------------------------------------------
    // Ref string helpers
    // -----------------------------------------------------------------------

    /// Return the "workspace:N" reference string for a registered UUID.
    /// The caller owns the returned slice; free with self.allocator.
    /// Returns error.NotFound if the UUID is not registered.
    pub fn getWorkspaceRef(self: *HandleMap, uuid: Uuid) ![]u8 {
        const ord = self.workspace_by_uuid.get(uuid) orelse return error.NotFound;
        return std.fmt.allocPrint(self.allocator, "workspace:{d}", .{ord});
    }

    /// Return the "surface:N" reference string for a registered UUID.
    /// The caller owns the returned slice; free with self.allocator.
    /// Returns error.NotFound if the UUID is not registered.
    pub fn getSurfaceRef(self: *HandleMap, uuid: Uuid) ![]u8 {
        const ord = self.surface_by_uuid.get(uuid) orelse return error.NotFound;
        return std.fmt.allocPrint(self.allocator, "surface:{d}", .{ord});
    }
};

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/// Parse a "<prefix>:N" reference string and return the ordinal N.
/// Returns error.InvalidRef if the string does not match.
fn parseRef(comptime prefix: []const u8, ref: []const u8) !u32 {
    const tag = prefix ++ ":";
    if (!std.mem.startsWith(u8, ref, tag)) return error.InvalidRef;
    const num_str = ref[tag.len..];
    if (num_str.len == 0) return error.InvalidRef;
    return std.fmt.parseInt(u32, num_str, 10) catch error.InvalidRef;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseRef workspace" {
    try std.testing.expectEqual(@as(u32, 1), try parseRef("workspace", "workspace:1"));
    try std.testing.expectEqual(@as(u32, 42), try parseRef("workspace", "workspace:42"));
}

test "parseRef surface" {
    try std.testing.expectEqual(@as(u32, 3), try parseRef("surface", "surface:3"));
}

test "parseRef invalid" {
    try std.testing.expectError(error.InvalidRef, parseRef("workspace", "surface:1"));
    try std.testing.expectError(error.InvalidRef, parseRef("workspace", "workspace:"));
    try std.testing.expectError(error.InvalidRef, parseRef("workspace", "workspace:abc"));
    try std.testing.expectError(error.InvalidRef, parseRef("workspace", "totally-wrong"));
}

test "HandleMap register and resolve workspace" {
    const allocator = std.testing.allocator;
    var map = HandleMap.init(allocator);
    defer map.deinit();

    const uuid1 = uuid_mod.generate();
    const uuid2 = uuid_mod.generate();

    const ord1 = try map.registerWorkspace(uuid1);
    const ord2 = try map.registerWorkspace(uuid2);

    try std.testing.expectEqual(@as(u32, 1), ord1);
    try std.testing.expectEqual(@as(u32, 2), ord2);

    const resolved1 = try map.resolveWorkspace("workspace:1");
    try std.testing.expect(uuid_mod.eql(uuid1, resolved1));

    const resolved2 = try map.resolveWorkspace("workspace:2");
    try std.testing.expect(uuid_mod.eql(uuid2, resolved2));
}

test "HandleMap register and resolve surface" {
    const allocator = std.testing.allocator;
    var map = HandleMap.init(allocator);
    defer map.deinit();

    const uuid1 = uuid_mod.generate();
    const uuid2 = uuid_mod.generate();
    const uuid3 = uuid_mod.generate();

    _ = try map.registerSurface(uuid1);
    _ = try map.registerSurface(uuid2);
    _ = try map.registerSurface(uuid3);

    const resolved3 = try map.resolveSurface("surface:3");
    try std.testing.expect(uuid_mod.eql(uuid3, resolved3));
}

test "HandleMap resolve unknown ordinal returns NotFound" {
    const allocator = std.testing.allocator;
    var map = HandleMap.init(allocator);
    defer map.deinit();

    try std.testing.expectError(error.NotFound, map.resolveWorkspace("workspace:99"));
    try std.testing.expectError(error.NotFound, map.resolveSurface("surface:1"));
}

test "HandleMap resolve invalid ref returns InvalidRef" {
    const allocator = std.testing.allocator;
    var map = HandleMap.init(allocator);
    defer map.deinit();

    try std.testing.expectError(error.InvalidRef, map.resolveWorkspace("ws:1"));
    try std.testing.expectError(error.InvalidRef, map.resolveSurface("surface:"));
}

test "HandleMap unregisterWorkspace removes entry" {
    const allocator = std.testing.allocator;
    var map = HandleMap.init(allocator);
    defer map.deinit();

    const uuid = uuid_mod.generate();
    _ = try map.registerWorkspace(uuid);

    // Before unregister, should resolve fine.
    _ = try map.resolveWorkspace("workspace:1");

    map.unregisterWorkspace(uuid);

    // After unregister, should return NotFound.
    try std.testing.expectError(error.NotFound, map.resolveWorkspace("workspace:1"));
}

test "HandleMap unregisterSurface removes entry" {
    const allocator = std.testing.allocator;
    var map = HandleMap.init(allocator);
    defer map.deinit();

    const uuid = uuid_mod.generate();
    _ = try map.registerSurface(uuid);

    _ = try map.resolveSurface("surface:1");

    map.unregisterSurface(uuid);

    try std.testing.expectError(error.NotFound, map.resolveSurface("surface:1"));
}

test "HandleMap getWorkspaceRef" {
    const allocator = std.testing.allocator;
    var map = HandleMap.init(allocator);
    defer map.deinit();

    const uuid = uuid_mod.generate();
    _ = try map.registerWorkspace(uuid);

    const ref = try map.getWorkspaceRef(uuid);
    defer allocator.free(ref);

    try std.testing.expectEqualStrings("workspace:1", ref);
}

test "HandleMap getSurfaceRef" {
    const allocator = std.testing.allocator;
    var map = HandleMap.init(allocator);
    defer map.deinit();

    const uuid1 = uuid_mod.generate();
    const uuid2 = uuid_mod.generate();
    _ = try map.registerSurface(uuid1);
    _ = try map.registerSurface(uuid2);

    const ref = try map.getSurfaceRef(uuid2);
    defer allocator.free(ref);

    try std.testing.expectEqualStrings("surface:2", ref);
}

test "HandleMap getWorkspaceRef unknown returns NotFound" {
    const allocator = std.testing.allocator;
    var map = HandleMap.init(allocator);
    defer map.deinit();

    const uuid = uuid_mod.generate();
    try std.testing.expectError(error.NotFound, map.getWorkspaceRef(uuid));
}

test "HandleMap workspace and surface ordinals are independent" {
    const allocator = std.testing.allocator;
    var map = HandleMap.init(allocator);
    defer map.deinit();

    const w = uuid_mod.generate();
    const s = uuid_mod.generate();

    _ = try map.registerWorkspace(w);
    _ = try map.registerSurface(s);

    // Both should have ordinal 1 in their own namespace.
    const w_ref = try map.getWorkspaceRef(w);
    defer allocator.free(w_ref);
    try std.testing.expectEqualStrings("workspace:1", w_ref);

    const s_ref = try map.getSurfaceRef(s);
    defer allocator.free(s_ref);
    try std.testing.expectEqualStrings("surface:1", s_ref);
}
