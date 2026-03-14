// src/termplex/util/json.zig
// JSON helpers for the termplex IPC protocol.
//
// The protocol is a JSON-RPC-like request/response scheme:
//
//   Request:  {"method": "workspace.list", "params": {}, "id": 1}
//   Success:  {"ok": true, "result": [...], "id": 1}
//   Error:    {"ok": false, "error": {"code": "not_found", "message": "..."}, "id": 1}

const std = @import("std");

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// A parsed incoming request.
/// The caller owns the memory allocated for .method; free it with the same
/// allocator passed to parseRequest.
pub const Request = struct {
    /// The method name (e.g. "workspace.list"). Caller owns this slice.
    method: []const u8,

    /// The params value. Backed by an internal arena; free via params_arena.
    params: std.json.Value,

    /// Arena that owns the memory for params. Call params_arena.deinit() to
    /// free params memory, or just use a parent arena allocator.
    params_arena: std.heap.ArenaAllocator,

    /// The request ID used to correlate responses.
    id: i64,

    /// Release all owned memory. After calling this the Request is invalid.
    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
        self.params_arena.deinit();
    }
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Parse a JSON request string into a Request struct.
///
/// The returned Request owns a copy of the method string and an arena for
/// the params value. Call request.deinit(allocator) when done.
///
/// Errors:
///   error.InvalidRequest  — JSON is malformed or missing required fields.
pub fn parseRequest(allocator: std.mem.Allocator, json_string: []const u8) !Request {
    // Use a temporary arena for the initial parse.
    var tmp_arena = std.heap.ArenaAllocator.init(allocator);
    defer tmp_arena.deinit();

    const parsed = std.json.parseFromSlice(
        std.json.Value,
        tmp_arena.allocator(),
        json_string,
        .{},
    ) catch return error.InvalidRequest;
    // parsed memory is managed by tmp_arena; we copy what we need.

    const root = parsed.value;
    if (root != .object) return error.InvalidRequest;

    const method_val = root.object.get("method") orelse return error.InvalidRequest;
    if (method_val != .string) return error.InvalidRequest;

    const id_val = root.object.get("id") orelse return error.InvalidRequest;
    const id: i64 = switch (id_val) {
        .integer => |n| n,
        .float => |f| @as(i64, @intFromFloat(f)),
        else => return error.InvalidRequest,
    };

    // Copy the method string so the caller owns it independently.
    const method_copy = try allocator.dupe(u8, method_val.string);
    errdefer allocator.free(method_copy);

    // Re-serialize and re-parse params into its own arena so the caller
    // can hold onto it after tmp_arena is freed.
    const params_val = root.object.get("params") orelse std.json.Value{ .null = {} };

    var params_arena = std.heap.ArenaAllocator.init(allocator);
    errdefer params_arena.deinit();

    // Serialize params to a temporary string.
    const params_json = try std.json.Stringify.valueAlloc(
        tmp_arena.allocator(),
        params_val,
        .{},
    );

    // Re-parse into the params arena so the value's memory lives there.
    const params_parsed = std.json.parseFromSlice(
        std.json.Value,
        params_arena.allocator(),
        params_json,
        .{},
    ) catch return error.InvalidRequest;
    // params_parsed.arena is separate; since we used params_arena.allocator()
    // the allocation is inside params_arena. The Parsed wrapper adds another
    // ArenaAllocator internally — we ignore it and rely on params_arena for cleanup.

    return Request{
        .method = method_copy,
        .params = params_parsed.value,
        .params_arena = params_arena,
        .id = id,
    };
}

/// Format a success response JSON string.
///
/// result_json must be a valid JSON fragment (e.g. "[]", "{}", "null", "42").
/// The caller is responsible for freeing the returned slice.
pub fn okResponse(
    allocator: std.mem.Allocator,
    id: i64,
    result_json: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"ok\":true,\"result\":{s},\"id\":{d}}}",
        .{ result_json, id },
    );
}

/// Format an error response JSON string.
///
/// code should be a short snake_case string (e.g. "not_found").
/// message is a human-readable explanation.
/// The caller is responsible for freeing the returned slice.
pub fn errResponse(
    allocator: std.mem.Allocator,
    id: i64,
    code: []const u8,
    message: []const u8,
) ![]u8 {
    // Escape code and message for safe embedding in JSON.
    const escaped_code = try jsonEscapeString(allocator, code);
    defer allocator.free(escaped_code);
    const escaped_message = try jsonEscapeString(allocator, message);
    defer allocator.free(escaped_message);

    return std.fmt.allocPrint(
        allocator,
        "{{\"ok\":false,\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\"}},\"id\":{d}}}",
        .{ escaped_code, escaped_message, id },
    );
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Escape a UTF-8 string for embedding inside a JSON string literal.
/// Only escapes characters required by the JSON spec.
fn jsonEscapeString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);

    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x00...0x08, 0x0B...0x0C, 0x0E...0x1F => {
                // Other control characters (excluding \n=0x0A, \r=0x0D, \t=0x09):
                // use \uXXXX encoding.
                var tmp_buf: [7]u8 = undefined;
                const encoded = try std.fmt.bufPrint(&tmp_buf, "\\u{X:0>4}", .{c});
                try out.appendSlice(allocator, encoded);
            },
            else => try out.append(allocator, c),
        }
    }

    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseRequest basic" {
    const allocator = std.testing.allocator;
    const json = "{\"method\":\"workspace.list\",\"params\":{},\"id\":1}";
    var req = try parseRequest(allocator, json);
    defer req.deinit(allocator);

    try std.testing.expectEqualStrings("workspace.list", req.method);
    try std.testing.expectEqual(@as(i64, 1), req.id);
}

test "parseRequest with integer id" {
    const allocator = std.testing.allocator;
    const json = "{\"method\":\"workspace.get\",\"params\":{\"id\":\"abc\"},\"id\":42}";
    var req = try parseRequest(allocator, json);
    defer req.deinit(allocator);

    try std.testing.expectEqualStrings("workspace.get", req.method);
    try std.testing.expectEqual(@as(i64, 42), req.id);
}

test "parseRequest missing method returns error" {
    const allocator = std.testing.allocator;
    const json = "{\"params\":{},\"id\":1}";
    try std.testing.expectError(error.InvalidRequest, parseRequest(allocator, json));
}

test "parseRequest missing id returns error" {
    const allocator = std.testing.allocator;
    const json = "{\"method\":\"foo\",\"params\":{}}";
    try std.testing.expectError(error.InvalidRequest, parseRequest(allocator, json));
}

test "parseRequest malformed JSON returns error" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidRequest, parseRequest(allocator, "not json"));
}

test "okResponse formats correctly" {
    const allocator = std.testing.allocator;
    const resp = try okResponse(allocator, 1, "[]");
    defer allocator.free(resp);

    try std.testing.expectEqualStrings("{\"ok\":true,\"result\":[],\"id\":1}", resp);
}

test "okResponse with null result" {
    const allocator = std.testing.allocator;
    const resp = try okResponse(allocator, 99, "null");
    defer allocator.free(resp);

    try std.testing.expectEqualStrings("{\"ok\":true,\"result\":null,\"id\":99}", resp);
}

test "errResponse formats correctly" {
    const allocator = std.testing.allocator;
    const resp = try errResponse(allocator, 2, "not_found", "Workspace not found");
    defer allocator.free(resp);

    try std.testing.expectEqualStrings(
        "{\"ok\":false,\"error\":{\"code\":\"not_found\",\"message\":\"Workspace not found\"},\"id\":2}",
        resp,
    );
}

test "errResponse escapes special chars in message" {
    const allocator = std.testing.allocator;
    const resp = try errResponse(allocator, 3, "bad_input", "contains \"quotes\" and \\backslash");
    defer allocator.free(resp);

    // Verify it is valid JSON by parsing it
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
    const ok_val = parsed.value.object.get("ok").?;
    try std.testing.expectEqual(false, ok_val.bool);
}

test "okResponse result is valid JSON" {
    const allocator = std.testing.allocator;
    const result_json = "{\"workspaces\":[{\"id\":\"abc\",\"name\":\"main\"}]}";
    const resp = try okResponse(allocator, 7, result_json);
    defer allocator.free(resp);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp, .{});
    defer parsed.deinit();

    const ok_val = parsed.value.object.get("ok").?;
    try std.testing.expectEqual(true, ok_val.bool);
    const id_val = parsed.value.object.get("id").?;
    try std.testing.expectEqual(@as(i64, 7), id_val.integer);
}
