const std = @import("std");

pub const Channel = enum {
    stable,
    tip,

    pub fn parse(value: []const u8) !Channel {
        if (std.mem.eql(u8, value, "stable")) return .stable;
        if (std.mem.eql(u8, value, "tip")) return .tip;
        return error.UnsupportedChannel;
    }
};

pub const AssetKind = enum {
    appimage,
    deb,
};

pub const Platform = struct {
    os: []const u8,
    arch: []const u8,
    kind: AssetKind,

    pub fn key(self: Platform, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}-{s}-{s}", .{
            self.os,
            self.arch,
            @tagName(self.kind),
        });
    }
};

pub const Download = struct {
    url: []const u8,
    sha256: [32]u8,
    filename: []const u8,
};

pub const Manifest = struct {
    version: std.SemanticVersion,
    channel: Channel,
    released_at: []const u8,
    notes_url: []const u8,
    downloads: std.StringHashMapUnmanaged(Download) = .{},

    pub fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
        allocator.free(self.released_at);
        allocator.free(self.notes_url);

        var it = self.downloads.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.url);
            allocator.free(entry.value_ptr.filename);
        }
        self.downloads.deinit(allocator);
    }
};

fn requireHttps(url: []const u8) !void {
    if (!std.mem.startsWith(u8, url, "https://")) return error.NonHttpsUrl;
}

fn filenameFromUrl(url: []const u8) ![]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, url, '/') orelse return error.InvalidUrl;
    const filename = url[slash + 1 ..];
    if (filename.len == 0) return error.InvalidUrl;
    if (std.mem.indexOfScalar(u8, filename, '/') != null) return error.InvalidFilename;
    if (std.mem.indexOfScalar(u8, filename, '\\') != null) return error.InvalidFilename;
    return filename;
}

fn parseSha256Hex(hex: []const u8) ![32]u8 {
    if (hex.len != 64) return error.InvalidSha256;

    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch return error.InvalidSha256;
    return out;
}

fn parseSemanticVersion(raw: []const u8) !std.SemanticVersion {
    const without_v = if (raw.len > 0 and raw[0] == 'v') raw[1..] else raw;
    return std.SemanticVersion.parse(without_v) catch error.InvalidVersion;
}

fn putDownload(
    manifest: *Manifest,
    allocator: std.mem.Allocator,
    key: []const u8,
    url: []const u8,
    sha256: [32]u8,
    filename: []const u8,
) !void {
    const key_owned = try allocator.dupe(u8, key);
    errdefer allocator.free(key_owned);

    const url_owned = try allocator.dupe(u8, url);
    errdefer allocator.free(url_owned);

    const filename_owned = try allocator.dupe(u8, filename);
    errdefer allocator.free(filename_owned);

    try manifest.downloads.put(allocator, key_owned, .{
        .url = url_owned,
        .sha256 = sha256,
        .filename = filename_owned,
    });
}

pub fn isNewer(candidate: std.SemanticVersion, current: std.SemanticVersion) bool {
    return candidate.order(current) == .gt;
}

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Manifest {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidManifest;
    const obj = parsed.value.object;

    const version_raw = obj.get("version") orelse return error.MissingVersion;
    if (version_raw != .string) return error.InvalidVersion;
    const version = try parseSemanticVersion(version_raw.string);

    const channel_raw = obj.get("channel") orelse return error.MissingChannel;
    if (channel_raw != .string) return error.UnsupportedChannel;
    const channel = try Channel.parse(channel_raw.string);

    const released_raw = obj.get("released_at") orelse return error.MissingReleasedAt;
    if (released_raw != .string or released_raw.string.len == 0) return error.InvalidReleasedAt;

    const notes_raw = obj.get("notes_url") orelse return error.MissingNotesUrl;
    if (notes_raw != .string) return error.InvalidNotesUrl;
    try requireHttps(notes_raw.string);

    const downloads_raw = obj.get("downloads") orelse return error.MissingDownloads;
    if (downloads_raw != .object) return error.InvalidDownloads;

    var manifest = Manifest{
        .version = version,
        .channel = channel,
        .released_at = try allocator.dupe(u8, released_raw.string),
        .notes_url = try allocator.dupe(u8, notes_raw.string),
    };
    errdefer manifest.deinit(allocator);

    var it = downloads_raw.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .object) return error.InvalidDownload;
        const dl = entry.value_ptr.object;

        const url_raw = dl.get("url") orelse return error.MissingUrl;
        if (url_raw != .string) return error.InvalidUrl;
        try requireHttps(url_raw.string);

        const sha_raw = dl.get("sha256") orelse return error.MissingSha256;
        if (sha_raw != .string) return error.InvalidSha256;

        const filename = try filenameFromUrl(url_raw.string);
        const sha256 = try parseSha256Hex(sha_raw.string);
        try putDownload(&manifest, allocator, entry.key_ptr.*, url_raw.string, sha256, filename);
    }

    if (manifest.downloads.count() == 0) return error.MissingDownloads;
    return manifest;
}

pub fn selectDownload(
    manifest: *const Manifest,
    platform: Platform,
    current_version: std.SemanticVersion,
    desired_channel: Channel,
) !?Download {
    if (manifest.channel != desired_channel) return null;
    if (!isNewer(manifest.version, current_version)) return null;

    var key_buf: [64]u8 = undefined;
    const platform_key = try platform.key(&key_buf);
    return manifest.downloads.get(platform_key);
}

test "update_manifest parses and selects newer AppImage" {
    const alloc = std.testing.allocator;
    const json =
        \\{
        \\  "version": "1.6.0",
        \\  "channel": "stable",
        \\  "released_at": "2026-05-03T00:00:00Z",
        \\  "notes_url": "https://github.com/termplex-org/termplex/releases/tag/v1.6.0",
        \\  "downloads": {
        \\    "linux-x86_64-appimage": {
        \\      "url": "https://github.com/termplex-org/termplex/releases/download/v1.6.0/Termplex-1.6.0-x86_64.AppImage",
        \\      "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        \\    }
        \\  }
        \\}
    ;
    var manifest = try parse(alloc, json);
    defer manifest.deinit(alloc);

    try std.testing.expectEqual(std.SemanticVersion{ .major = 1, .minor = 6, .patch = 0 }, manifest.version);
    const selected = try selectDownload(
        &manifest,
        .{ .os = "linux", .arch = "x86_64", .kind = .appimage },
        .{ .major = 1, .minor = 5, .patch = 0 },
        .stable,
    );
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("Termplex-1.6.0-x86_64.AppImage", selected.?.filename);
}

test "update_manifest rejects non-https URLs" {
    const alloc = std.testing.allocator;
    const json =
        \\{
        \\  "version": "1.6.0",
        \\  "channel": "stable",
        \\  "released_at": "2026-05-03T00:00:00Z",
        \\  "notes_url": "http://example.com/release",
        \\  "downloads": {}
        \\}
    ;
    try std.testing.expectError(error.NonHttpsUrl, parse(alloc, json));
}

test "update_manifest rejects invalid sha256" {
    const alloc = std.testing.allocator;
    const json =
        \\{
        \\  "version": "1.6.0",
        \\  "channel": "stable",
        \\  "released_at": "2026-05-03T00:00:00Z",
        \\  "notes_url": "https://example.com/release",
        \\  "downloads": {
        \\    "linux-x86_64-appimage": {
        \\      "url": "https://example.com/Termplex.AppImage",
        \\      "sha256": "bad"
        \\    }
        \\  }
        \\}
    ;
    try std.testing.expectError(error.InvalidSha256, parse(alloc, json));
}
