const std = @import("std");

const update_manifest = @import("update_manifest.zig");
const update_state = @import("update_state.zig");

pub const CheckResult = union(enum) {
    up_to_date,
    available: Available,
    unavailable_for_install: Available,

    pub fn deinit(self: *CheckResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .available => |*available| available.deinit(allocator),
            .unavailable_for_install => |*available| available.deinit(allocator),
            .up_to_date => {},
        }
    }
};

pub const Available = struct {
    version: std.SemanticVersion,
    version_string: []const u8,
    notes_url: []const u8,
    download: ?update_manifest.Download,
    install_kind: update_state.InstallKind,

    pub fn deinit(self: *Available, allocator: std.mem.Allocator) void {
        allocator.free(self.version_string);
        allocator.free(self.notes_url);
        if (self.download) |download| {
            allocator.free(download.url);
            allocator.free(download.filename);
        }
        self.* = undefined;
    }
};

pub fn detectInstallKind(env: std.process.EnvMap) update_state.InstallKind {
    if (env.get("APPIMAGE")) |value| {
        if (value.len > 0) return .appimage;
    }
    if (env.get("FLATPAK_ID")) |_| return .flatpak;
    if (env.get("SNAP")) |_| return .snap;
    return .unknown;
}

fn copyDownload(allocator: std.mem.Allocator, download: update_manifest.Download) !update_manifest.Download {
    const url = try allocator.dupe(u8, download.url);
    errdefer allocator.free(url);

    const filename = try allocator.dupe(u8, download.filename);
    errdefer allocator.free(filename);

    return .{
        .url = url,
        .sha256 = download.sha256,
        .filename = filename,
    };
}

pub fn evaluateManifest(
    allocator: std.mem.Allocator,
    manifest_bytes: []const u8,
    current_version: std.SemanticVersion,
    desired_channel: update_manifest.Channel,
    install_kind: update_state.InstallKind,
    platform_arch: []const u8,
) !CheckResult {
    var manifest = try update_manifest.parse(allocator, manifest_bytes);
    defer manifest.deinit(allocator);

    if (!update_manifest.isNewer(manifest.version, current_version)) return .up_to_date;

    var available = Available{
        .version = manifest.version,
        .version_string = try std.fmt.allocPrint(allocator, "{f}", .{manifest.version}),
        .notes_url = try allocator.dupe(u8, manifest.notes_url),
        .download = null,
        .install_kind = install_kind,
    };
    errdefer available.deinit(allocator);

    if (install_kind != .appimage) {
        return .{ .unavailable_for_install = available };
    }

    const selected = try update_manifest.selectDownload(
        &manifest,
        .{ .os = "linux", .arch = platform_arch, .kind = .appimage },
        current_version,
        desired_channel,
    ) orelse return error.NoCompatibleDownload;

    available.download = try copyDownload(allocator, selected);
    return .{ .available = available };
}

pub fn finalizeDownloadedPart(
    allocator: std.mem.Allocator,
    part_path: []const u8,
    final_path: []const u8,
    expected_sha256: [32]u8,
) !void {
    _ = allocator;

    var file = try std.fs.openFileAbsolute(part_path, .{ .mode = .read_only });
    defer file.close();

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }

    var actual: [32]u8 = undefined;
    hasher.final(&actual);
    if (!std.mem.eql(u8, &actual, &expected_sha256)) {
        std.fs.deleteFileAbsolute(part_path) catch {};
        return error.ChecksumMismatch;
    }

    if (comptime std.fs.has_executable_bit) {
        try file.chmod(0o755);
    }

    std.fs.deleteFileAbsolute(final_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try std.fs.renameAbsolute(part_path, final_path);
}

pub const FetchOptions = struct {
    max_bytes: usize = 2 * 1024 * 1024,
};

pub fn fetchHttps(allocator: std.mem.Allocator, url: []const u8, options: FetchOptions) ![]u8 {
    if (!std.mem.startsWith(u8, url, "https://")) return error.NonHttpsUrl;

    const uri = try std.Uri.parse(url);
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var req = try client.request(.GET, uri, .{
        .headers = .{
            .user_agent = .{ .override = "Termplex-Updater" },
            .accept_encoding = .{ .override = "identity" },
        },
    });
    defer req.deinit();

    try req.sendBodiless();

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);
    if (response.head.status != .ok) return error.HttpStatusNotOk;

    var transfer_buffer: [64 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    return readAllAllocLimited(allocator, reader, options.max_bytes) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr() orelse err,
        else => |e| return e,
    };
}

fn readAllAllocLimited(allocator: std.mem.Allocator, reader: *std.Io.Reader, max_bytes: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        if (out.items.len > max_bytes) return error.StreamTooLong;

        const remaining_plus_probe = (max_bytes + 1) - out.items.len;
        const read_len = @min(buf.len, remaining_plus_probe);
        if (read_len == 0) return error.StreamTooLong;

        const n = try reader.readSliceShort(buf[0..read_len]);
        if (n == 0) break;
        try out.appendSlice(allocator, buf[0..n]);
    }

    if (out.items.len > max_bytes) return error.StreamTooLong;
    return out.toOwnedSlice(allocator);
}

fn validateAppImageFilename(filename: []const u8) !void {
    if (std.mem.indexOfScalar(u8, filename, '/') != null) return error.InvalidFilename;
    if (std.mem.indexOfScalar(u8, filename, '\\') != null) return error.InvalidFilename;
    if (!std.mem.endsWith(u8, filename, ".AppImage")) return error.InvalidFilename;
}

fn e2eDownloadOverride() ?[]const u8 {
    const e2e = std.posix.getenv("TERMPLEX_E2E") orelse return null;
    if (!std.mem.eql(u8, e2e, "1")) return null;

    const path = std.posix.getenv("TERMPLEX_UPDATE_DOWNLOAD_OVERRIDE") orelse return null;
    if (path.len == 0) return null;
    return path;
}

fn fetchDownloadBytes(allocator: std.mem.Allocator, url: []const u8, max_bytes: usize) ![]u8 {
    if (e2eDownloadOverride()) |path| {
        return std.fs.cwd().readFileAlloc(allocator, path, max_bytes);
    }

    return fetchHttps(allocator, url, .{ .max_bytes = max_bytes });
}

pub fn downloadAppImage(
    allocator: std.mem.Allocator,
    url: []const u8,
    update_dir: []const u8,
    filename: []const u8,
    expected_sha256: [32]u8,
) ![]u8 {
    try validateAppImageFilename(filename);
    if (!std.mem.startsWith(u8, url, "https://")) return error.NonHttpsUrl;
    try std.fs.cwd().makePath(update_dir);

    const final_path = try std.fs.path.join(allocator, &.{ update_dir, filename });
    errdefer allocator.free(final_path);

    const part_path = try std.fmt.allocPrint(allocator, "{s}.part", .{final_path});
    defer allocator.free(part_path);

    const bytes = try fetchDownloadBytes(allocator, url, 512 * 1024 * 1024);
    defer allocator.free(bytes);

    {
        const file = try std.fs.createFileAbsolute(part_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(bytes);
    }

    try finalizeDownloadedPart(allocator, part_path, final_path, expected_sha256);
    return final_path;
}

test "update_checker detects AppImage from env" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();

    try env.put("APPIMAGE", "/tmp/Termplex.AppImage");
    try std.testing.expectEqual(update_state.InstallKind.appimage, detectInstallKind(env));
}

test "update_checker evaluates available AppImage update" {
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

    var result = try evaluateManifest(
        alloc,
        json,
        .{ .major = 1, .minor = 5, .patch = 0 },
        .stable,
        .appimage,
        "x86_64",
    );
    defer result.deinit(alloc);

    try std.testing.expect(result == .available);
    try std.testing.expectEqualStrings("1.6.0", result.available.version_string);
    try std.testing.expect(result.available.download != null);
    try std.testing.expectEqualStrings("Termplex-1.6.0-x86_64.AppImage", result.available.download.?.filename);
}

test "update_checker finalizes matching part file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);
    const part_path = try std.fs.path.join(alloc, &.{ tmp_path, "Termplex.AppImage.part" });
    defer alloc.free(part_path);
    const final_path = try std.fs.path.join(alloc, &.{ tmp_path, "Termplex.AppImage" });
    defer alloc.free(final_path);

    try tmp.dir.writeFile(.{ .sub_path = "Termplex.AppImage.part", .data = "payload" });

    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("payload", &expected, .{});

    try finalizeDownloadedPart(alloc, part_path, final_path, expected);
    try std.testing.expect((try tmp.dir.statFile("Termplex.AppImage")).kind == .file);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile("Termplex.AppImage.part"));
}

test "update_checker removes mismatched part file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);
    const part_path = try std.fs.path.join(alloc, &.{ tmp_path, "bad.part" });
    defer alloc.free(part_path);
    const final_path = try std.fs.path.join(alloc, &.{ tmp_path, "bad.AppImage" });
    defer alloc.free(final_path);

    try tmp.dir.writeFile(.{ .sub_path = "bad.part", .data = "payload" });

    const wrong: [32]u8 = [_]u8{0} ** 32;
    try std.testing.expectError(error.ChecksumMismatch, finalizeDownloadedPart(alloc, part_path, final_path, wrong));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile("bad.part"));
}

test "update_checker fetch rejects non-https URLs" {
    try std.testing.expectError(
        error.NonHttpsUrl,
        fetchHttps(std.testing.allocator, "http://example.com/update.json", .{}),
    );
}

test "update_checker download rejects unsafe AppImage filenames before network" {
    const sha: [32]u8 = [_]u8{0} ** 32;
    try std.testing.expectError(
        error.InvalidFilename,
        downloadAppImage(std.testing.allocator, "https://example.com/Termplex.AppImage", "/tmp", "../Termplex.AppImage", sha),
    );
    try std.testing.expectError(
        error.InvalidFilename,
        downloadAppImage(std.testing.allocator, "https://example.com/termplex.tar.gz", "/tmp", "termplex.tar.gz", sha),
    );
}

test "update_checker download uses E2E local override" {
    const alloc = std.testing.allocator;
    const env_os = @import("../../os/env.zig");

    const old_e2e = if (std.posix.getenv("TERMPLEX_E2E")) |value| try alloc.dupeZ(u8, value) else null;
    defer {
        if (old_e2e) |value| {
            _ = env_os.setenv("TERMPLEX_E2E", value);
            alloc.free(value);
        } else {
            _ = env_os.unsetenv("TERMPLEX_E2E");
        }
    }

    const old_override = if (std.posix.getenv("TERMPLEX_UPDATE_DOWNLOAD_OVERRIDE")) |value| try alloc.dupeZ(u8, value) else null;
    defer {
        if (old_override) |value| {
            _ = env_os.setenv("TERMPLEX_UPDATE_DOWNLOAD_OVERRIDE", value);
            alloc.free(value);
        } else {
            _ = env_os.unsetenv("TERMPLEX_UPDATE_DOWNLOAD_OVERRIDE");
        }
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "fixture.AppImage", .data = "termplex test appimage\n" });

    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);
    const fixture_path = try std.fs.path.join(alloc, &.{ tmp_path, "fixture.AppImage" });
    defer alloc.free(fixture_path);
    const update_dir = try std.fs.path.join(alloc, &.{ tmp_path, "updates" });
    defer alloc.free(update_dir);

    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("termplex test appimage\n", &expected, .{});

    const fixture_path_z = try alloc.dupeZ(u8, fixture_path);
    defer alloc.free(fixture_path_z);
    _ = env_os.setenv("TERMPLEX_E2E", "1");
    _ = env_os.setenv("TERMPLEX_UPDATE_DOWNLOAD_OVERRIDE", fixture_path_z);

    const downloaded = try downloadAppImage(
        alloc,
        "https://127.0.0.1:9/Termplex-9.9.9-x86_64.AppImage",
        update_dir,
        "Termplex-9.9.9-x86_64.AppImage",
        expected,
    );
    defer alloc.free(downloaded);

    try std.testing.expect(std.mem.endsWith(u8, downloaded, "Termplex-9.9.9-x86_64.AppImage"));
    try std.testing.expect((try std.fs.cwd().statFile(downloaded)).kind == .file);
}
