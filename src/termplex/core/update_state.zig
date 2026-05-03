const std = @import("std");

pub const InstallKind = enum {
    appimage,
    flatpak,
    snap,
    deb,
    rpm,
    source,
    unknown,
};

pub const ChecksumStatus = enum {
    none,
    verified,
    mismatch,
};

pub const State = struct {
    last_checked_at: ?[]const u8 = null,
    last_available_version: ?[]const u8 = null,
    dismissed_version: ?[]const u8 = null,
    downloaded_version: ?[]const u8 = null,
    download_path: ?[]const u8 = null,
    install_kind: InstallKind = .unknown,
    checksum_status: ChecksumStatus = .none,
    last_error: ?[]const u8 = null,
    progress: ?[]const u8 = null,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.last_checked_at) |value| allocator.free(value);
        if (self.last_available_version) |value| allocator.free(value);
        if (self.dismissed_version) |value| allocator.free(value);
        if (self.downloaded_version) |value| allocator.free(value);
        if (self.download_path) |value| allocator.free(value);
        if (self.last_error) |value| allocator.free(value);
        if (self.progress) |value| allocator.free(value);
        self.* = .{};
    }

    pub fn isDismissed(self: State, version: []const u8) bool {
        const dismissed = self.dismissed_version orelse return false;
        return std.mem.eql(u8, dismissed, version);
    }
};

fn writeOptionalString(jw: *std.json.Stringify, field: []const u8, value: ?[]const u8) !void {
    try jw.objectField(field);
    if (value) |str| try jw.write(str) else try jw.write(null);
}

fn toJson(allocator: std.mem.Allocator, state: State) ![]u8 {
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };

    try jw.beginObject();
    try writeOptionalString(&jw, "last_checked_at", state.last_checked_at);
    try writeOptionalString(&jw, "last_available_version", state.last_available_version);
    try writeOptionalString(&jw, "dismissed_version", state.dismissed_version);
    try writeOptionalString(&jw, "downloaded_version", state.downloaded_version);
    try writeOptionalString(&jw, "download_path", state.download_path);
    try jw.objectField("install_kind");
    try jw.write(@tagName(state.install_kind));
    try jw.objectField("checksum_status");
    try jw.write(@tagName(state.checksum_status));
    try writeOptionalString(&jw, "last_error", state.last_error);
    try writeOptionalString(&jw, "progress", state.progress);
    try jw.endObject();

    return aw.toOwnedSlice();
}

fn parseOptionalString(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    field: []const u8,
) !?[]const u8 {
    const value = obj.get(field) orelse return null;
    return switch (value) {
        .null => null,
        .string => |str| try allocator.dupe(u8, str),
        else => error.CorruptUpdateState,
    };
}

fn parseInstallKind(value: []const u8) !InstallKind {
    return std.meta.stringToEnum(InstallKind, value) orelse error.CorruptUpdateState;
}

fn parseChecksumStatus(value: []const u8) !ChecksumStatus {
    return std.meta.stringToEnum(ChecksumStatus, value) orelse error.CorruptUpdateState;
}

pub fn fromJson(allocator: std.mem.Allocator, bytes: []const u8) !State {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.CorruptUpdateState;
    const obj = parsed.value.object;

    var state = State{};
    errdefer state.deinit(allocator);

    state.last_checked_at = try parseOptionalString(allocator, obj, "last_checked_at");
    state.last_available_version = try parseOptionalString(allocator, obj, "last_available_version");
    state.dismissed_version = try parseOptionalString(allocator, obj, "dismissed_version");
    state.downloaded_version = try parseOptionalString(allocator, obj, "downloaded_version");
    state.download_path = try parseOptionalString(allocator, obj, "download_path");
    state.last_error = try parseOptionalString(allocator, obj, "last_error");
    state.progress = try parseOptionalString(allocator, obj, "progress");

    if (obj.get("install_kind")) |value| {
        if (value != .string) return error.CorruptUpdateState;
        state.install_kind = try parseInstallKind(value.string);
    }

    if (obj.get("checksum_status")) |value| {
        if (value != .string) return error.CorruptUpdateState;
        state.checksum_status = try parseChecksumStatus(value.string);
    }

    return state;
}

pub fn save(allocator: std.mem.Allocator, path: []const u8, state: State) !void {
    const dir_path = std.fs.path.dirname(path) orelse ".";
    try std.fs.cwd().makePath(dir_path);

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    const json = try toJson(allocator, state);
    defer allocator.free(json);

    {
        const file = try std.fs.createFileAbsolute(tmp_path, .{});
        defer file.close();
        try file.writeAll(json);
    }

    try std.fs.renameAbsolute(tmp_path, path);
}

pub fn load(allocator: std.mem.Allocator, path: []const u8) !State {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(contents);

    return fromJson(allocator, contents);
}

test "update_state saves, loads, and matches dismissed version" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const state_path = try std.fs.path.join(allocator, &.{ tmp_path, "updates", "update-state.json" });
    defer allocator.free(state_path);

    const state = State{
        .last_checked_at = "2026-05-03T00:00:00Z",
        .last_available_version = "1.6.0",
        .dismissed_version = "1.6.0",
        .downloaded_version = "1.6.0",
        .download_path = "/tmp/Termplex-1.6.0-x86_64.AppImage",
        .install_kind = .appimage,
        .checksum_status = .verified,
        .last_error = null,
        .progress = "downloaded",
    };

    try save(allocator, state_path, state);

    var loaded = try load(allocator, state_path);
    defer loaded.deinit(allocator);

    try std.testing.expectEqualStrings("2026-05-03T00:00:00Z", loaded.last_checked_at.?);
    try std.testing.expectEqualStrings("1.6.0", loaded.last_available_version.?);
    try std.testing.expect(loaded.isDismissed("1.6.0"));
    try std.testing.expect(!loaded.isDismissed("1.7.0"));
    try std.testing.expectEqual(InstallKind.appimage, loaded.install_kind);
    try std.testing.expectEqual(ChecksumStatus.verified, loaded.checksum_status);
}

test "update_state load missing returns defaults" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const state_path = try std.fs.path.join(allocator, &.{ tmp_path, "missing.json" });
    defer allocator.free(state_path);

    var loaded = try load(allocator, state_path);
    defer loaded.deinit(allocator);

    try std.testing.expect(loaded.last_checked_at == null);
    try std.testing.expect(loaded.last_available_version == null);
    try std.testing.expectEqual(InstallKind.unknown, loaded.install_kind);
    try std.testing.expectEqual(ChecksumStatus.none, loaded.checksum_status);
}
