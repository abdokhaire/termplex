const std = @import("std");

pub const DiskUsage = struct {
    base_path: []const u8,
    db_path: []const u8,
    total_bytes: u64 = 0,
    transcript_bytes: u64 = 0,
    db_bytes: u64 = 0,
    transcript_file_count: u64 = 0,

    pub fn deinit(self: *DiskUsage, allocator: std.mem.Allocator) void {
        allocator.free(self.base_path);
        allocator.free(self.db_path);
    }
};

pub fn scanBasePath(allocator: std.mem.Allocator, base_path: []const u8, db_path: []const u8) !DiskUsage {
    var usage = DiskUsage{
        .base_path = try allocator.dupe(u8, base_path),
        .db_path = try allocator.dupe(u8, db_path),
    };
    errdefer usage.deinit(allocator);

    var base_dir = std.fs.openDirAbsolute(base_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return usage,
        else => return err,
    };
    defer base_dir.close();

    try scanDir(&usage, base_dir);
    usage.db_bytes += fileSize(db_path);

    const wal_path = try std.fmt.allocPrint(allocator, "{s}-wal", .{db_path});
    defer allocator.free(wal_path);
    usage.db_bytes += fileSize(wal_path);

    const shm_path = try std.fmt.allocPrint(allocator, "{s}-shm", .{db_path});
    defer allocator.free(shm_path);
    usage.db_bytes += fileSize(shm_path);

    return usage;
}

pub fn formatBytes(allocator: std.mem.Allocator, bytes: u64) ![]u8 {
    if (bytes < 1024) return std.fmt.allocPrint(allocator, "{d} B", .{bytes});

    const units = [_][]const u8{ "KiB", "MiB", "GiB", "TiB" };
    var value: f64 = @as(f64, @floatFromInt(bytes)) / 1024.0;
    var unit_index: usize = 0;
    while (value >= 1024.0 and unit_index + 1 < units.len) : (unit_index += 1) {
        value /= 1024.0;
    }
    return std.fmt.allocPrint(allocator, "{d:.1} {s}", .{ value, units[unit_index] });
}

fn scanDir(usage: *DiskUsage, dir: std.fs.Dir) !void {
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        switch (entry.kind) {
            .file => {
                const stat = dir.statFile(entry.name) catch continue;
                usage.total_bytes += stat.size;
                if (std.mem.endsWith(u8, entry.name, ".ansi")) {
                    usage.transcript_bytes += stat.size;
                    usage.transcript_file_count += 1;
                }
            },
            .directory => {
                var child = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
                defer child.close();
                try scanDir(usage, child);
            },
            else => {},
        }
    }
}

fn fileSize(path: []const u8) u64 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return 0;
    defer file.close();
    const stat = file.stat() catch return 0;
    return stat.size;
}

test "storage status scan separates transcripts and sqlite bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);

    try tmp.dir.makePath("workspace-1");
    try tmp.dir.writeFile(.{ .sub_path = "workspace-1/hist-1.ansi", .data = "ansi" });
    try tmp.dir.writeFile(.{ .sub_path = "workspace-1/notes.txt", .data = "xx" });
    try tmp.dir.writeFile(.{ .sub_path = "history.sqlite3", .data = "db!" });

    const db_path = try std.fs.path.join(allocator, &.{ base, "history.sqlite3" });
    defer allocator.free(db_path);

    var usage = try scanBasePath(allocator, base, db_path);
    defer usage.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 9), usage.total_bytes);
    try std.testing.expectEqual(@as(u64, 4), usage.transcript_bytes);
    try std.testing.expectEqual(@as(u64, 3), usage.db_bytes);
    try std.testing.expectEqual(@as(u64, 1), usage.transcript_file_count);
}

test "storage status byte formatting uses readable units" {
    const allocator = std.testing.allocator;

    const small = try formatBytes(allocator, 512);
    defer allocator.free(small);
    try std.testing.expectEqualStrings("512 B", small);

    const kib = try formatBytes(allocator, 1536);
    defer allocator.free(kib);
    try std.testing.expectEqualStrings("1.5 KiB", kib);
}
