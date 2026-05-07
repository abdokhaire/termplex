const std = @import("std");

const log = std.log.scoped(.termplex_workspace_open);

pub const Target = enum {
    folder,
    vscode,
};

pub fn targetName(target: Target) []const u8 {
    return switch (target) {
        .folder => "folder",
        .vscode => "vscode",
    };
}

fn appendJsonString(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, value: []const u8) !void {
    try buf.append(alloc, '"');
    for (value) |ch| {
        switch (ch) {
            '"' => try buf.appendSlice(alloc, "\\\""),
            '\\' => try buf.appendSlice(alloc, "\\\\"),
            '\n' => try buf.appendSlice(alloc, "\\n"),
            '\r' => try buf.appendSlice(alloc, "\\r"),
            '\t' => try buf.appendSlice(alloc, "\\t"),
            else => try buf.append(alloc, ch),
        }
    }
    try buf.append(alloc, '"');
}

fn dryRunLine(alloc: std.mem.Allocator, target: Target, workspace_dir: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);

    try buf.appendSlice(alloc, "{\"target\":");
    try appendJsonString(&buf, alloc, targetName(target));
    try buf.appendSlice(alloc, ",\"dir\":");
    try appendJsonString(&buf, alloc, workspace_dir);
    try buf.appendSlice(alloc, "}\n");

    return try buf.toOwnedSlice(alloc);
}

pub fn recordDryRun(alloc: std.mem.Allocator, dir: std.fs.Dir, target: Target, workspace_dir: []const u8) !void {
    const line = try dryRunLine(alloc, target, workspace_dir);
    defer alloc.free(line);

    var file = dir.openFile("workspace-open.jsonl", .{ .mode = .write_only }) catch |err| switch (err) {
        error.FileNotFound => try dir.createFile("workspace-open.jsonl", .{}),
        else => return err,
    };
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(line);
}

pub fn recordDryRunPath(alloc: std.mem.Allocator, path: []const u8, target: Target, workspace_dir: []const u8) !void {
    const line = try dryRunLine(alloc, target, workspace_dir);
    defer alloc.free(line);

    var file = std.fs.openFileAbsolute(path, .{ .mode = .write_only }) catch |err| switch (err) {
        error.FileNotFound => try std.fs.createFileAbsolute(path, .{}),
        else => return err,
    };
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(line);
}

pub fn recordDryRunFromEnv(alloc: std.mem.Allocator, target: Target, workspace_dir: []const u8) !bool {
    const log_path = std.posix.getenv("TERMPLEX_E2E_OPEN_WORKSPACE_LOG") orelse return false;
    if (log_path.len == 0) return false;
    try recordDryRunPath(alloc, log_path, target, workspace_dir);
    return true;
}

pub fn openVSCode(alloc: std.mem.Allocator, workspace_dir: []const u8) !void {
    if (try recordDryRunFromEnv(alloc, .vscode, workspace_dir)) return;

    var child = std.process.Child.init(&.{ "code", workspace_dir }, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    const thread = try std.Thread.spawn(.{}, waitForEditor, .{ alloc, child });
    thread.detach();
}

fn waitForEditor(alloc: std.mem.Allocator, child_: std.process.Child) void {
    var child = child_;
    var stdout: std.ArrayListUnmanaged(u8) = .empty;
    var stderr: std.ArrayListUnmanaged(u8) = .empty;
    defer {
        stdout.deinit(alloc);
        stderr.deinit(alloc);
    }

    child.collectOutput(alloc, &stdout, &stderr, 50 * 1024) catch |err| {
        log.warn("failed to collect VS Code launcher output: {}", .{err});
    };
    _ = child.wait() catch |err| {
        log.warn("failed waiting for VS Code launcher: {}", .{err});
        return;
    };
    if (stderr.items.len > 0) {
        log.warn("VS Code launcher stderr={s}", .{stderr.items});
    }
}

test "workspace open dry-run records target and directory" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try recordDryRun(std.testing.allocator, dir.dir, .folder, "/tmp/termplex workspace");
    try recordDryRun(std.testing.allocator, dir.dir, .vscode, "/tmp/termplex workspace");

    const text = try dir.dir.readFileAlloc(std.testing.allocator, "workspace-open.jsonl", 4096);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings(
        "{\"target\":\"folder\",\"dir\":\"/tmp/termplex workspace\"}\n" ++
            "{\"target\":\"vscode\",\"dir\":\"/tmp/termplex workspace\"}\n",
        text,
    );
}
