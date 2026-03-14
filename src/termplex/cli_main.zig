// src/termplex/cli_main.zig
// Termplex CLI binary - communicates with termplex-app via Unix socket.
//
// Usage:
//   termplex <command> [subcommand] [flags/args]
//
// Commands:
//   ping
//   tree
//   workspace list|new [--name NAME]|select REF|rename REF NAME|close [REF]
//   surface   list|new|split [--direction horizontal|vertical]|close [REF]|focus REF
//   notify    --title "..." [--body "..."]
//   notification list|clear [--workspace REF]
//   report    git|ports|pwd PATH
//
// Socket path resolution (same as server):
//   1. $TERMPLEX_SOCKET
//   2. $XDG_RUNTIME_DIR/termplex.sock
//   3. /tmp/termplex-{uid}.sock

const std = @import("std");
const posix = std.posix;

// ---------------------------------------------------------------------------
// I/O buffer sizes
// ---------------------------------------------------------------------------

const io_buf_size = 4096;

// ---------------------------------------------------------------------------
// writeAll: write all bytes to a file descriptor
// ---------------------------------------------------------------------------

fn fdWriteAll(fd: posix.fd_t, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const n = try posix.write(fd, data[written..]);
        written += n;
    }
}

// ---------------------------------------------------------------------------
// Socket path resolution
// ---------------------------------------------------------------------------

fn getSocketPath(allocator: std.mem.Allocator) ![]u8 {
    // 1. Explicit override.
    if (std.process.getEnvVarOwned(allocator, "TERMPLEX_SOCKET")) |p| {
        if (p.len > 0) return p;
        allocator.free(p);
    } else |_| {}

    // 2. $XDG_RUNTIME_DIR/termplex.sock
    if (std.process.getEnvVarOwned(allocator, "XDG_RUNTIME_DIR")) |dir| {
        defer allocator.free(dir);
        if (dir.len > 0) {
            return std.fs.path.join(allocator, &[_][]const u8{ dir, "termplex.sock" });
        }
    } else |_| {}

    // 3. /tmp/termplex-{uid}.sock
    const uid = posix.getuid();
    return std.fmt.allocPrint(allocator, "/tmp/termplex-{d}.sock", .{uid});
}

// ---------------------------------------------------------------------------
// Socket client: connect, send request, receive response
// ---------------------------------------------------------------------------

fn sendRequest(allocator: std.mem.Allocator, socket_path: []const u8, request_json: []const u8) ![]u8 {
    const fd = try posix.socket(
        posix.AF.UNIX,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
        0,
    );
    defer posix.close(fd);

    var addr: posix.sockaddr.un = .{
        .family = posix.AF.UNIX,
        .path = undefined,
    };
    @memset(&addr.path, 0);

    if (socket_path.len >= addr.path.len) {
        return error.SocketPathTooLong;
    }
    @memcpy(addr.path[0..socket_path.len], socket_path);

    try posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

    // Send request followed by newline
    try fdWriteAll(fd, request_json);
    try fdWriteAll(fd, "\n");

    // Read response (newline-delimited) using an allocating writer for buffering
    var aw: std.io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    var read_buf: [4096]u8 = undefined;
    while (true) {
        const n = try posix.read(fd, &read_buf);
        if (n == 0) break; // EOF
        try aw.writer.writeAll(read_buf[0..n]);
        // Check if we got a newline (end of response)
        if (std.mem.indexOfScalar(u8, aw.written(), '\n') != null) break;
    }

    var result = try aw.toOwnedSlice();
    // Trim trailing newline
    if (result.len > 0 and result[result.len - 1] == '\n') {
        result = try allocator.realloc(result, result.len - 1);
    }
    return result;
}

// ---------------------------------------------------------------------------
// Pretty-print JSON response
// ---------------------------------------------------------------------------

fn printResponse(allocator: std.mem.Allocator, response_json: []const u8) !void {
    var out_buf: [io_buf_size]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&out_buf);
    const stdout = &stdout_writer.interface;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response_json, .{}) catch {
        // Not valid JSON — just print raw
        try stdout.writeAll(response_json);
        try stdout.writeAll("\n");
        try stdout.flush();
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        try stdout.writeAll(response_json);
        try stdout.writeAll("\n");
        try stdout.flush();
        return;
    }

    const ok_val = root.object.get("ok") orelse {
        try stdout.writeAll(response_json);
        try stdout.writeAll("\n");
        try stdout.flush();
        return;
    };

    if (ok_val == .bool and !ok_val.bool) {
        // Error response — print to stderr
        var err_buf: [io_buf_size]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&err_buf);
        const stderr = &stderr_writer.interface;
        if (root.object.get("error")) |err_val| {
            if (err_val == .object) {
                const code = if (err_val.object.get("code")) |c| c.string else "unknown";
                const message = if (err_val.object.get("message")) |m| m.string else "unknown error";
                try stderr.print("error: {s}: {s}\n", .{ code, message });
                try stderr.flush();
                return;
            }
        }
        try stderr.writeAll("error: unknown error\n");
        try stderr.flush();
        return;
    }

    // Success — pretty-print the result using an allocating writer
    if (root.object.get("result")) |result| {
        var aw: std.io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var stringify: std.json.Stringify = .{
            .writer = &aw.writer,
            .options = .{ .whitespace = .indent_2 },
        };
        try stringify.write(result);
        const pretty = aw.written();
        try stdout.writeAll(pretty);
        try stdout.writeAll("\n");
    }
    try stdout.flush();
}

// ---------------------------------------------------------------------------
// Build JSON request
// ---------------------------------------------------------------------------

fn buildRequest(allocator: std.mem.Allocator, method: []const u8, params_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"method\":\"{s}\",\"params\":{s},\"id\":1}}",
        .{ method, params_json },
    );
}

// ---------------------------------------------------------------------------
// Run a request against the server
// ---------------------------------------------------------------------------

fn runRequest(allocator: std.mem.Allocator, method: []const u8, params_json: []const u8) !void {
    const socket_path = try getSocketPath(allocator);
    defer allocator.free(socket_path);

    const request = try buildRequest(allocator, method, params_json);
    defer allocator.free(request);

    const response = sendRequest(allocator, socket_path, request) catch |err| {
        var err_buf: [io_buf_size]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&err_buf);
        const stderr = &stderr_writer.interface;
        switch (err) {
            error.ConnectionRefused, error.FileNotFound => {
                try stderr.print(
                    "error: cannot connect to termplex-app on {s}\n" ++
                        "  Is termplex-app running?\n",
                    .{socket_path},
                );
            },
            else => {
                try stderr.print("error: {}\n", .{err});
            },
        }
        try stderr.flush();
        posix.exit(1);
    };
    defer allocator.free(response);

    try printResponse(allocator, response);
}

// ---------------------------------------------------------------------------
// Usage / help
// ---------------------------------------------------------------------------

const usage_text =
    \\Usage: termplex <command> [args]
    \\
    \\Commands:
    \\  ping
    \\      Check that termplex-app is running.
    \\
    \\  tree
    \\      Print workspace/surface tree.
    \\
    \\  workspace list
    \\  workspace new [--name NAME]
    \\  workspace select REF
    \\  workspace rename REF NAME
    \\  workspace close [REF]
    \\
    \\  surface list
    \\  surface new
    \\  surface split [--direction horizontal|vertical]
    \\  surface close [REF]
    \\  surface focus REF
    \\
    \\  open [DIR]
    \\      Find or create a workspace for the given directory (default: $PWD).
    \\
    \\  notify --title "TITLE" [--body "BODY"]
    \\
    \\  notification list
    \\  notification clear [--workspace REF]
    \\
    \\  report git
    \\  report ports
    \\  report pwd PATH
    \\
    \\  --help, -h      Show this help message.
    \\
;

fn printUsageTo(w: *std.io.Writer) !void {
    try w.writeAll(usage_text);
    try w.flush();
}

// ---------------------------------------------------------------------------
// Argument parsing helpers
// ---------------------------------------------------------------------------

/// Find a flag value in args: --flag VALUE → returns VALUE
fn flagValue(args: []const []const u8, flag: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag)) {
            if (i + 1 < args.len) return args[i + 1];
        }
    }
    return null;
}

/// Get a positional argument (non-flag) at index `pos` among non-flag args.
/// Flag pairs (--key value) are skipped.
fn positional(args: []const []const u8, pos: usize) ?[]const u8 {
    var count: usize = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        // Skip flag pairs --key value
        if (args[i].len > 1 and args[i][0] == '-') {
            // Check if next arg is a value (not a flag)
            if (i + 1 < args.len and (args[i + 1].len == 0 or args[i + 1][0] != '-')) {
                i += 1;
            }
            continue;
        }
        if (count == pos) return args[i];
        count += 1;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Command handlers
// ---------------------------------------------------------------------------

fn cmdPing(allocator: std.mem.Allocator) !void {
    try runRequest(allocator, "system.ping", "{}");
}

fn cmdTree(allocator: std.mem.Allocator) !void {
    try runRequest(allocator, "system.tree", "{}");
}

fn cmdWorkspace(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var err_buf: [io_buf_size]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&err_buf);
    const stderr = &stderr_writer.interface;

    if (args.len == 0) {
        try stderr.writeAll("error: workspace requires a subcommand: list|new|select|rename|close\n");
        try stderr.flush();
        posix.exit(1);
    }

    const sub = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, sub, "list")) {
        try runRequest(allocator, "workspace.list", "{}");
        return;
    }

    if (std.mem.eql(u8, sub, "new")) {
        const name = flagValue(rest, "--name");
        const params = if (name) |n|
            try std.fmt.allocPrint(allocator, "{{\"name\":\"{s}\"}}", .{n})
        else
            try allocator.dupe(u8, "{}");
        defer allocator.free(params);
        try runRequest(allocator, "workspace.create", params);
        return;
    }

    if (std.mem.eql(u8, sub, "select")) {
        const ref = positional(rest, 0) orelse {
            try stderr.writeAll("error: workspace select requires a REF argument\n");
            try stderr.flush();
            posix.exit(1);
        };
        const params = try std.fmt.allocPrint(allocator, "{{\"ref\":\"{s}\"}}", .{ref});
        defer allocator.free(params);
        try runRequest(allocator, "workspace.select", params);
        return;
    }

    if (std.mem.eql(u8, sub, "rename")) {
        const ref = positional(rest, 0) orelse {
            try stderr.writeAll("error: workspace rename requires REF and NAME arguments\n");
            try stderr.flush();
            posix.exit(1);
        };
        const name = positional(rest, 1) orelse {
            try stderr.writeAll("error: workspace rename requires NAME argument\n");
            try stderr.flush();
            posix.exit(1);
        };
        const params = try std.fmt.allocPrint(
            allocator,
            "{{\"ref\":\"{s}\",\"name\":\"{s}\"}}",
            .{ ref, name },
        );
        defer allocator.free(params);
        try runRequest(allocator, "workspace.rename", params);
        return;
    }

    if (std.mem.eql(u8, sub, "close")) {
        const ref = positional(rest, 0);
        const params = if (ref) |r|
            try std.fmt.allocPrint(allocator, "{{\"ref\":\"{s}\"}}", .{r})
        else
            try allocator.dupe(u8, "{}");
        defer allocator.free(params);
        try runRequest(allocator, "workspace.close", params);
        return;
    }

    try stderr.print("error: unknown workspace subcommand: {s}\n", .{sub});
    try stderr.flush();
    posix.exit(1);
}

fn cmdSurface(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var err_buf: [io_buf_size]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&err_buf);
    const stderr = &stderr_writer.interface;

    if (args.len == 0) {
        try stderr.writeAll("error: surface requires a subcommand: list|new|split|close|focus\n");
        try stderr.flush();
        posix.exit(1);
    }

    const sub = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, sub, "list")) {
        try runRequest(allocator, "surface.list", "{}");
        return;
    }

    if (std.mem.eql(u8, sub, "new")) {
        try runRequest(allocator, "surface.create", "{}");
        return;
    }

    if (std.mem.eql(u8, sub, "split")) {
        const direction = flagValue(rest, "--direction");
        const params = if (direction) |d|
            try std.fmt.allocPrint(allocator, "{{\"direction\":\"{s}\"}}", .{d})
        else
            try allocator.dupe(u8, "{}");
        defer allocator.free(params);
        try runRequest(allocator, "surface.split", params);
        return;
    }

    if (std.mem.eql(u8, sub, "close")) {
        const ref = positional(rest, 0);
        const params = if (ref) |r|
            try std.fmt.allocPrint(allocator, "{{\"ref\":\"{s}\"}}", .{r})
        else
            try allocator.dupe(u8, "{}");
        defer allocator.free(params);
        try runRequest(allocator, "surface.close", params);
        return;
    }

    if (std.mem.eql(u8, sub, "focus")) {
        const ref = positional(rest, 0) orelse {
            try stderr.writeAll("error: surface focus requires a REF argument\n");
            try stderr.flush();
            posix.exit(1);
        };
        const params = try std.fmt.allocPrint(allocator, "{{\"ref\":\"{s}\"}}", .{ref});
        defer allocator.free(params);
        try runRequest(allocator, "surface.focus", params);
        return;
    }

    try stderr.print("error: unknown surface subcommand: {s}\n", .{sub});
    try stderr.flush();
    posix.exit(1);
}

fn cmdNotify(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var err_buf: [io_buf_size]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&err_buf);
    const stderr = &stderr_writer.interface;

    const title = flagValue(args, "--title") orelse {
        try stderr.writeAll("error: notify requires --title \"TITLE\"\n");
        try stderr.flush();
        posix.exit(1);
    };
    const body = flagValue(args, "--body");

    const params = if (body) |b|
        try std.fmt.allocPrint(
            allocator,
            "{{\"title\":\"{s}\",\"body\":\"{s}\"}}",
            .{ title, b },
        )
    else
        try std.fmt.allocPrint(allocator, "{{\"title\":\"{s}\"}}", .{title});
    defer allocator.free(params);

    try runRequest(allocator, "notification.create", params);
}

fn cmdNotification(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var err_buf: [io_buf_size]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&err_buf);
    const stderr = &stderr_writer.interface;

    if (args.len == 0) {
        try stderr.writeAll("error: notification requires a subcommand: list|clear\n");
        try stderr.flush();
        posix.exit(1);
    }

    const sub = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, sub, "list")) {
        try runRequest(allocator, "notification.list", "{}");
        return;
    }

    if (std.mem.eql(u8, sub, "clear")) {
        const workspace = flagValue(rest, "--workspace");
        const params = if (workspace) |w|
            try std.fmt.allocPrint(allocator, "{{\"workspace\":\"{s}\"}}", .{w})
        else
            try allocator.dupe(u8, "{}");
        defer allocator.free(params);
        try runRequest(allocator, "notification.clear", params);
        return;
    }

    try stderr.print("error: unknown notification subcommand: {s}\n", .{sub});
    try stderr.flush();
    posix.exit(1);
}

fn cmdOpen(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Resolve directory: explicit arg or $PWD
    const dir_arg = if (args.len > 0) args[0] else (std.posix.getenv("PWD") orelse ".");

    // Make absolute
    const abs_dir = std.fs.cwd().realpathAlloc(allocator, dir_arg) catch |err| {
        var err_buf: [io_buf_size]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&err_buf);
        const stderr = &stderr_writer.interface;
        try stderr.print("error: cannot resolve path '{s}': {}\n", .{ dir_arg, err });
        try stderr.flush();
        posix.exit(1);
    };
    defer allocator.free(abs_dir);

    // Query for existing workspace with this directory
    const find_params = try std.fmt.allocPrint(allocator, "{{\"dir\":\"{s}\"}}", .{abs_dir});
    defer allocator.free(find_params);

    const socket_path = try getSocketPath(allocator);
    defer allocator.free(socket_path);

    const find_request = try buildRequest(allocator, "workspace.find_by_dir", find_params);
    defer allocator.free(find_request);

    const find_response = sendRequest(allocator, socket_path, find_request) catch |err| {
        var err_buf: [io_buf_size]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&err_buf);
        const stderr = &stderr_writer.interface;
        switch (err) {
            error.ConnectionRefused, error.FileNotFound => {
                try stderr.print(
                    "error: cannot connect to termplex-app on {s}\n" ++
                        "  Is termplex-app running?\n",
                    .{socket_path},
                );
            },
            else => {
                try stderr.print("error: {}\n", .{err});
            },
        }
        try stderr.flush();
        posix.exit(1);
    };
    defer allocator.free(find_response);

    // Parse response to check if any workspaces matched
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, find_response, .{}) catch {
        // Can't parse — fall through to create
        try createAndSelectWorkspace(allocator, socket_path, abs_dir);
        return;
    };
    defer parsed.deinit();

    if (parsed.value == .object) {
        if (parsed.value.object.get("result")) |result| {
            if (result == .object) {
                if (result.object.get("workspaces")) |ws_arr| {
                    if (ws_arr == .array and ws_arr.array.items.len > 0) {
                        // Workspace exists — select it
                        const first = ws_arr.array.items[0];
                        if (first == .object) {
                            if (first.object.get("index")) |idx_val| {
                                if (idx_val == .integer) {
                                    const select_params = try std.fmt.allocPrint(
                                        allocator,
                                        "{{\"index\":{d}}}",
                                        .{idx_val.integer},
                                    );
                                    defer allocator.free(select_params);
                                    const select_request = try buildRequest(allocator, "workspace.select", select_params);
                                    defer allocator.free(select_request);
                                    const select_response = sendRequest(allocator, socket_path, select_request) catch |err| {
                                        var err_buf: [io_buf_size]u8 = undefined;
                                        var stderr_writer = std.fs.File.stderr().writer(&err_buf);
                                        const stderr = &stderr_writer.interface;
                                        try stderr.print("error: {}\n", .{err});
                                        try stderr.flush();
                                        posix.exit(1);
                                    };
                                    defer allocator.free(select_response);
                                    try printResponse(allocator, select_response);
                                    return;
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // No matching workspace — create one
    try createAndSelectWorkspace(allocator, socket_path, abs_dir);
}

fn createAndSelectWorkspace(allocator: std.mem.Allocator, socket_path: []const u8, abs_dir: []const u8) !void {
    const create_params = try std.fmt.allocPrint(allocator, "{{\"dir\":\"{s}\"}}", .{abs_dir});
    defer allocator.free(create_params);

    const create_request = try buildRequest(allocator, "workspace.create", create_params);
    defer allocator.free(create_request);

    const create_response = sendRequest(allocator, socket_path, create_request) catch |err| {
        var err_buf: [io_buf_size]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&err_buf);
        const stderr = &stderr_writer.interface;
        try stderr.print("error: {}\n", .{err});
        try stderr.flush();
        posix.exit(1);
    };
    defer allocator.free(create_response);

    // Parse the create response to get the new workspace index, then select it.
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, create_response, .{}) catch {
        try printResponse(allocator, create_response);
        return;
    };
    defer parsed.deinit();

    if (parsed.value == .object) {
        if (parsed.value.object.get("result")) |result| {
            if (result == .object) {
                if (result.object.get("index")) |idx_val| {
                    if (idx_val == .integer) {
                        const select_params = try std.fmt.allocPrint(
                            allocator,
                            "{{\"index\":{d}}}",
                            .{idx_val.integer},
                        );
                        defer allocator.free(select_params);
                        const select_request = try buildRequest(allocator, "workspace.select", select_params);
                        defer allocator.free(select_request);
                        const select_response = sendRequest(allocator, socket_path, select_request) catch {
                            try printResponse(allocator, create_response);
                            return;
                        };
                        defer allocator.free(select_response);
                        try printResponse(allocator, create_response);
                        return;
                    }
                }
            }
        }
    }

    try printResponse(allocator, create_response);
}

fn cmdReport(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var err_buf: [io_buf_size]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&err_buf);
    const stderr = &stderr_writer.interface;

    if (args.len == 0) {
        try stderr.writeAll("error: report requires a subcommand: git|ports|pwd\n");
        try stderr.flush();
        posix.exit(1);
    }

    const sub = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, sub, "git")) {
        try runRequest(allocator, "status.report_git", "{}");
        return;
    }

    if (std.mem.eql(u8, sub, "ports")) {
        try runRequest(allocator, "status.report_ports", "{}");
        return;
    }

    if (std.mem.eql(u8, sub, "pwd")) {
        const path = positional(rest, 0) orelse {
            try stderr.writeAll("error: report pwd requires a PATH argument\n");
            try stderr.flush();
            posix.exit(1);
        };
        const params = try std.fmt.allocPrint(allocator, "{{\"pwd\":\"{s}\"}}", .{path});
        defer allocator.free(params);
        try runRequest(allocator, "status.report_pwd", params);
        return;
    }

    try stderr.print("error: unknown report subcommand: {s}\n", .{sub});
    try stderr.flush();
    posix.exit(1);
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var err_buf: [io_buf_size]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&err_buf);
    const stderr = &stderr_writer.interface;

    // args[0] is the program name; commands start at args[1]
    if (args.len < 2) {
        var out_buf: [io_buf_size]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&out_buf);
        try printUsageTo(&stdout_writer.interface);
        posix.exit(1);
    }

    const cmd = args[1];

    // Help flags
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        var out_buf: [io_buf_size]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&out_buf);
        try printUsageTo(&stdout_writer.interface);
        return;
    }

    if (std.mem.eql(u8, cmd, "ping")) {
        try cmdPing(allocator);
        return;
    }

    if (std.mem.eql(u8, cmd, "tree")) {
        try cmdTree(allocator);
        return;
    }

    if (std.mem.eql(u8, cmd, "workspace")) {
        try cmdWorkspace(allocator, args[2..]);
        return;
    }

    if (std.mem.eql(u8, cmd, "surface")) {
        try cmdSurface(allocator, args[2..]);
        return;
    }

    if (std.mem.eql(u8, cmd, "notify")) {
        try cmdNotify(allocator, args[2..]);
        return;
    }

    if (std.mem.eql(u8, cmd, "notification")) {
        try cmdNotification(allocator, args[2..]);
        return;
    }

    if (std.mem.eql(u8, cmd, "open")) {
        try cmdOpen(allocator, args[2..]);
        return;
    }

    if (std.mem.eql(u8, cmd, "report")) {
        try cmdReport(allocator, args[2..]);
        return;
    }

    try stderr.print("error: unknown command: {s}\n", .{cmd});
    try stderr.flush();
    var out_buf: [io_buf_size]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&out_buf);
    try printUsageTo(&stdout_writer.interface);
    posix.exit(1);
}
