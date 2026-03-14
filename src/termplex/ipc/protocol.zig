// src/termplex/ipc/protocol.zig
// IPC protocol dispatcher for termplex.
//
// Routes incoming JSON requests to handler stubs.  Each handler will be
// replaced with a real implementation in Task 18 when the protocol is wired to
// WorkspaceManager and other services.
//
// Protocol (newline-delimited JSON, one request per connection):
//   Request:  {"method": "workspace.list", "params": {}, "id": 1}
//   Success:  {"ok": true, "result": ..., "id": 1}
//   Error:    {"ok": false, "error": {"code": "...", "message": "..."}, "id": 1}
//
// Supported methods:
//   system.*        : ping, tree
//   workspace.*     : list, create, select, close, rename
//   surface.*       : list, create, split, close, focus
//   notification.*  : create, list, clear
//   status.*        : report_git, report_ports, report_pwd
//
// Dispatch function signature matches SocketServer.Handler so the Protocol
// can be passed directly to SocketServer.poll.

const std = @import("std");
const json_util = @import("json");
const uuid_mod = @import("uuid");
const HandleMap = @import("handle").HandleMap;

const log = std.log.scoped(.protocol);

// ---------------------------------------------------------------------------
// Protocol
// ---------------------------------------------------------------------------

pub const Protocol = struct {
    allocator: std.mem.Allocator,
    handle_map: HandleMap,

    // Context pointers — set when wiring to real services in Task 18.
    // Currently unused (null); handlers return stubs.

    // -----------------------------------------------------------------------
    // init / deinit
    // -----------------------------------------------------------------------

    pub fn init(allocator: std.mem.Allocator) Protocol {
        return Protocol{
            .allocator = allocator,
            .handle_map = HandleMap.init(allocator),
        };
    }

    pub fn deinit(self: *Protocol) void {
        self.handle_map.deinit();
    }

    // -----------------------------------------------------------------------
    // dispatch — matches SocketServer.Handler signature
    // -----------------------------------------------------------------------

    /// Parse a JSON request, route to the appropriate handler, and return
    /// an allocated JSON response string.  The caller (SocketServer) frees it.
    ///
    /// Returns null only if the request is so malformed that we cannot extract
    /// an id — in that case we cannot form a valid response.
    pub fn dispatch(self: *Protocol, allocator: std.mem.Allocator, request_json: []const u8) ?[]const u8 {
        var req = json_util.parseRequest(allocator, request_json) catch |err| {
            log.warn("failed to parse request: {}", .{err});
            // We don't know the id; return a fixed error with id 0.
            return json_util.errResponse(allocator, 0, "invalid_request", "malformed JSON request") catch null;
        };
        defer req.deinit(allocator);

        const id = req.id;
        const method = req.method;

        log.debug("dispatch method={s} id={d}", .{ method, id });

        const result = self.route(allocator, method, req.params, id) catch |err| {
            log.warn("handler error for method {s}: {}", .{ method, err });
            return json_util.errResponse(allocator, id, "internal_error", "handler error") catch null;
        };

        return result;
    }

    // -----------------------------------------------------------------------
    // Routing
    // -----------------------------------------------------------------------

    fn route(
        self: *Protocol,
        allocator: std.mem.Allocator,
        method: []const u8,
        params: std.json.Value,
        id: i64,
    ) !?[]const u8 {
        // system.*
        if (std.mem.eql(u8, method, "system.ping")) return self.handleSystemPing(allocator, id);
        if (std.mem.eql(u8, method, "system.tree")) return self.handleSystemTree(allocator, id);

        // workspace.*
        if (std.mem.eql(u8, method, "workspace.list")) return self.handleWorkspaceList(allocator, id);
        if (std.mem.eql(u8, method, "workspace.create")) return self.handleWorkspaceCreate(allocator, params, id);
        if (std.mem.eql(u8, method, "workspace.select")) return self.handleWorkspaceSelect(allocator, params, id);
        if (std.mem.eql(u8, method, "workspace.close")) return self.handleWorkspaceClose(allocator, params, id);
        if (std.mem.eql(u8, method, "workspace.rename")) return self.handleWorkspaceRename(allocator, params, id);

        // surface.*
        if (std.mem.eql(u8, method, "surface.list")) return self.handleSurfaceList(allocator, id);
        if (std.mem.eql(u8, method, "surface.create")) return self.handleSurfaceCreate(allocator, params, id);
        if (std.mem.eql(u8, method, "surface.split")) return self.handleSurfaceSplit(allocator, params, id);
        if (std.mem.eql(u8, method, "surface.close")) return self.handleSurfaceClose(allocator, params, id);
        if (std.mem.eql(u8, method, "surface.focus")) return self.handleSurfaceFocus(allocator, params, id);

        // notification.*
        if (std.mem.eql(u8, method, "notification.create")) return self.handleNotificationCreate(allocator, params, id);
        if (std.mem.eql(u8, method, "notification.list")) return self.handleNotificationList(allocator, id);
        if (std.mem.eql(u8, method, "notification.clear")) return self.handleNotificationClear(allocator, params, id);

        // status.*
        if (std.mem.eql(u8, method, "status.report_git")) return self.handleStatusReportGit(allocator, params, id);
        if (std.mem.eql(u8, method, "status.report_ports")) return self.handleStatusReportPorts(allocator, params, id);
        if (std.mem.eql(u8, method, "status.report_pwd")) return self.handleStatusReportPwd(allocator, params, id);

        // Unknown method.
        return try json_util.errResponse(allocator, id, "method_not_found", "unknown method");
    }

    // -----------------------------------------------------------------------
    // system handlers
    // -----------------------------------------------------------------------

    fn handleSystemPing(_: *Protocol, allocator: std.mem.Allocator, id: i64) !?[]const u8 {
        return try json_util.okResponse(allocator, id, "\"pong\"");
    }

    fn handleSystemTree(_: *Protocol, allocator: std.mem.Allocator, id: i64) !?[]const u8 {
        return try json_util.okResponse(allocator, id, "{}");
    }

    // -----------------------------------------------------------------------
    // workspace handlers (stubs)
    // -----------------------------------------------------------------------

    fn handleWorkspaceList(_: *Protocol, allocator: std.mem.Allocator, id: i64) !?[]const u8 {
        return try json_util.okResponse(allocator, id, "[]");
    }

    fn handleWorkspaceCreate(_: *Protocol, allocator: std.mem.Allocator, _: std.json.Value, id: i64) !?[]const u8 {
        return try json_util.okResponse(allocator, id, "null");
    }

    fn handleWorkspaceSelect(_: *Protocol, allocator: std.mem.Allocator, _: std.json.Value, id: i64) !?[]const u8 {
        return try json_util.okResponse(allocator, id, "null");
    }

    fn handleWorkspaceClose(_: *Protocol, allocator: std.mem.Allocator, _: std.json.Value, id: i64) !?[]const u8 {
        return try json_util.okResponse(allocator, id, "null");
    }

    fn handleWorkspaceRename(_: *Protocol, allocator: std.mem.Allocator, _: std.json.Value, id: i64) !?[]const u8 {
        return try json_util.okResponse(allocator, id, "null");
    }

    // -----------------------------------------------------------------------
    // surface handlers (stubs)
    // -----------------------------------------------------------------------

    fn handleSurfaceList(_: *Protocol, allocator: std.mem.Allocator, id: i64) !?[]const u8 {
        return try json_util.okResponse(allocator, id, "[]");
    }

    fn handleSurfaceCreate(_: *Protocol, allocator: std.mem.Allocator, _: std.json.Value, id: i64) !?[]const u8 {
        return try json_util.okResponse(allocator, id, "null");
    }

    fn handleSurfaceSplit(_: *Protocol, allocator: std.mem.Allocator, _: std.json.Value, id: i64) !?[]const u8 {
        return try json_util.okResponse(allocator, id, "null");
    }

    fn handleSurfaceClose(_: *Protocol, allocator: std.mem.Allocator, _: std.json.Value, id: i64) !?[]const u8 {
        return try json_util.okResponse(allocator, id, "null");
    }

    fn handleSurfaceFocus(_: *Protocol, allocator: std.mem.Allocator, _: std.json.Value, id: i64) !?[]const u8 {
        return try json_util.okResponse(allocator, id, "null");
    }

    // -----------------------------------------------------------------------
    // notification handlers (stubs)
    // -----------------------------------------------------------------------

    fn handleNotificationCreate(_: *Protocol, allocator: std.mem.Allocator, _: std.json.Value, id: i64) !?[]const u8 {
        return try json_util.okResponse(allocator, id, "null");
    }

    fn handleNotificationList(_: *Protocol, allocator: std.mem.Allocator, id: i64) !?[]const u8 {
        return try json_util.okResponse(allocator, id, "[]");
    }

    fn handleNotificationClear(_: *Protocol, allocator: std.mem.Allocator, _: std.json.Value, id: i64) !?[]const u8 {
        return try json_util.okResponse(allocator, id, "null");
    }

    // -----------------------------------------------------------------------
    // status handlers (stubs)
    // -----------------------------------------------------------------------

    fn handleStatusReportGit(_: *Protocol, allocator: std.mem.Allocator, _: std.json.Value, id: i64) !?[]const u8 {
        return try json_util.okResponse(allocator, id, "null");
    }

    fn handleStatusReportPorts(_: *Protocol, allocator: std.mem.Allocator, _: std.json.Value, id: i64) !?[]const u8 {
        return try json_util.okResponse(allocator, id, "null");
    }

    fn handleStatusReportPwd(_: *Protocol, allocator: std.mem.Allocator, _: std.json.Value, id: i64) !?[]const u8 {
        return try json_util.okResponse(allocator, id, "null");
    }
};

// ---------------------------------------------------------------------------
// dispatchFn — adapter to SocketServer.Handler signature
// ---------------------------------------------------------------------------

/// Returns a SocketServer.Handler function pointer that dispatches through the
/// given Protocol instance.
///
/// Usage:
///   var proto = Protocol.init(allocator);
///   server.poll(proto.handlerFn());
///
/// Note: the Protocol must outlive any server.poll() calls.
pub fn makeHandler(proto: *Protocol) @import("socket_server").Handler {
    const S = struct {
        var instance: *Protocol = undefined;
        fn handle(allocator: std.mem.Allocator, request: []const u8) ?[]const u8 {
            return instance.dispatch(allocator, request);
        }
    };
    S.instance = proto;
    return S.handle;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "dispatch system.ping returns pong" {
    const allocator = std.testing.allocator;
    var proto = Protocol.init(allocator);
    defer proto.deinit();

    const req = "{\"method\":\"system.ping\",\"params\":{},\"id\":1}";
    const resp = proto.dispatch(allocator, req) orelse return error.NoResponse;
    defer allocator.free(resp);

    // Parse the response and verify fields.
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp, .{});
    defer parsed.deinit();

    const root = parsed.value;
    try std.testing.expect(root == .object);
    try std.testing.expectEqual(true, root.object.get("ok").?.bool);
    try std.testing.expectEqualStrings("pong", root.object.get("result").?.string);
    try std.testing.expectEqual(@as(i64, 1), root.object.get("id").?.integer);
}

test "dispatch unknown method returns method_not_found error" {
    const allocator = std.testing.allocator;
    var proto = Protocol.init(allocator);
    defer proto.deinit();

    const req = "{\"method\":\"no.such.method\",\"params\":{},\"id\":7}";
    const resp = proto.dispatch(allocator, req) orelse return error.NoResponse;
    defer allocator.free(resp);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp, .{});
    defer parsed.deinit();

    const root = parsed.value;
    try std.testing.expect(root == .object);
    try std.testing.expectEqual(false, root.object.get("ok").?.bool);
    try std.testing.expectEqual(@as(i64, 7), root.object.get("id").?.integer);

    const err_obj = root.object.get("error").?.object;
    try std.testing.expectEqualStrings("method_not_found", err_obj.get("code").?.string);
}

test "dispatch malformed JSON returns invalid_request error with id 0" {
    const allocator = std.testing.allocator;
    var proto = Protocol.init(allocator);
    defer proto.deinit();

    const resp = proto.dispatch(allocator, "not json at all") orelse return error.NoResponse;
    defer allocator.free(resp);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp, .{});
    defer parsed.deinit();

    const root = parsed.value;
    try std.testing.expectEqual(false, root.object.get("ok").?.bool);
    try std.testing.expectEqual(@as(i64, 0), root.object.get("id").?.integer);

    const err_obj = root.object.get("error").?.object;
    try std.testing.expectEqualStrings("invalid_request", err_obj.get("code").?.string);
}

test "dispatch workspace.list returns empty array" {
    const allocator = std.testing.allocator;
    var proto = Protocol.init(allocator);
    defer proto.deinit();

    const req = "{\"method\":\"workspace.list\",\"params\":{},\"id\":2}";
    const resp = proto.dispatch(allocator, req) orelse return error.NoResponse;
    defer allocator.free(resp);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp, .{});
    defer parsed.deinit();

    const root = parsed.value;
    try std.testing.expectEqual(true, root.object.get("ok").?.bool);
    try std.testing.expectEqual(@as(i64, 2), root.object.get("id").?.integer);
    // result should be an array (stub returns [])
    try std.testing.expect(root.object.get("result").? == .array);
}

test "dispatch surface.list returns empty array" {
    const allocator = std.testing.allocator;
    var proto = Protocol.init(allocator);
    defer proto.deinit();

    const req = "{\"method\":\"surface.list\",\"params\":{},\"id\":3}";
    const resp = proto.dispatch(allocator, req) orelse return error.NoResponse;
    defer allocator.free(resp);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(true, parsed.value.object.get("ok").?.bool);
    try std.testing.expect(parsed.value.object.get("result").? == .array);
}

test "dispatch notification.list returns empty array" {
    const allocator = std.testing.allocator;
    var proto = Protocol.init(allocator);
    defer proto.deinit();

    const req = "{\"method\":\"notification.list\",\"params\":{},\"id\":4}";
    const resp = proto.dispatch(allocator, req) orelse return error.NoResponse;
    defer allocator.free(resp);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(true, parsed.value.object.get("ok").?.bool);
    try std.testing.expect(parsed.value.object.get("result").? == .array);
}

test "dispatch system.tree returns ok" {
    const allocator = std.testing.allocator;
    var proto = Protocol.init(allocator);
    defer proto.deinit();

    const req = "{\"method\":\"system.tree\",\"params\":{},\"id\":5}";
    const resp = proto.dispatch(allocator, req) orelse return error.NoResponse;
    defer allocator.free(resp);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(true, parsed.value.object.get("ok").?.bool);
}

test "dispatch stub methods return ok with id" {
    const allocator = std.testing.allocator;
    var proto = Protocol.init(allocator);
    defer proto.deinit();

    const stub_methods = [_][]const u8{
        "workspace.create",
        "workspace.select",
        "workspace.close",
        "workspace.rename",
        "surface.create",
        "surface.split",
        "surface.close",
        "surface.focus",
        "notification.create",
        "notification.clear",
        "status.report_git",
        "status.report_ports",
        "status.report_pwd",
    };

    for (stub_methods, 0..) |method, idx| {
        const req_str = try std.fmt.allocPrint(
            allocator,
            "{{\"method\":\"{s}\",\"params\":{{}},\"id\":{d}}}",
            .{ method, idx + 10 },
        );
        defer allocator.free(req_str);

        const resp = proto.dispatch(allocator, req_str) orelse return error.NoResponse;
        defer allocator.free(resp);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp, .{});
        defer parsed.deinit();

        try std.testing.expectEqual(true, parsed.value.object.get("ok").?.bool);
        try std.testing.expectEqual(@as(i64, @intCast(idx + 10)), parsed.value.object.get("id").?.integer);
    }
}
