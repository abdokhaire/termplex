const std = @import("std");

pub const Options = struct {
    enabled: bool = true,
    restore_mode: RestoreMode = .transcript,
    max_lines_per_surface: usize = 5000,
    max_bytes_per_surface: usize = 10 * 1024 * 1024,
    persist_alternate_screen: bool = false,
    replay_notice: bool = true,
    retention_days: u32 = 90,
};

pub const RestoreMode = enum {
    off,
    layout_only,
    transcript,
};

pub const SanitizerState = struct {
    pending: std.ArrayListUnmanaged(u8) = .empty,

    pub fn deinit(self: *SanitizerState, allocator: std.mem.Allocator) void {
        self.pending.deinit(allocator);
    }
};

pub const LifecycleReason = enum {
    explicit_clear,
    restart,
    cwd_changed,
    env_changed,
    exited_reopen,
    error_reopen,
    workspace_deleted,
    normal_close,
};

pub const TranscriptWriter = struct {
    const default_flush_interval_ns: i128 = 40 * std.time.ns_per_ms;
    const default_max_pending_bytes: usize = 64 * 1024;

    allocator: std.mem.Allocator,
    path: []const u8,
    options: Options,
    flush_interval_ns: i128 = default_flush_interval_ns,
    max_pending_bytes: usize = default_max_pending_bytes,
    last_flush_ns: i128 = 0,
    pending: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, options: Options) TranscriptWriter {
        return .{
            .allocator = allocator,
            .path = path,
            .options = options,
            .last_flush_ns = std.time.nanoTimestamp(),
        };
    }

    pub fn deinit(self: *TranscriptWriter) void {
        self.pending.deinit(self.allocator);
    }

    pub fn queue(self: *TranscriptWriter, chunk: []const u8) !void {
        try self.pending.appendSlice(self.allocator, chunk);
    }

    pub fn shouldFlush(self: *const TranscriptWriter, now_ns: i128) bool {
        return self.pending.items.len >= self.max_pending_bytes or
            now_ns - self.last_flush_ns >= self.flush_interval_ns;
    }

    pub fn flush(self: *TranscriptWriter) !void {
        if (self.pending.items.len == 0) return;
        try appendTranscript(self.allocator, self.path, self.pending.items, self.options);
        self.pending.clearRetainingCapacity();
        self.last_flush_ns = std.time.nanoTimestamp();
    }
};

pub fn safeId(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    for (input) |c| {
        const safe = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '.' or c == '-' or c == '_';
        try out.append(allocator, if (safe) c else '_');
    }

    if (out.items.len == 0) try out.appendSlice(allocator, "default");
    return out.toOwnedSlice(allocator);
}

pub fn isValidUuidLike(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return false;
            continue;
        }
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

pub fn getBaseDir(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_STATE_HOME")) |state_home| {
        defer allocator.free(state_home);
        return std.fs.path.join(allocator, &.{ state_home, "termplex", "terminal-history" });
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".local", "state", "termplex", "terminal-history" });
    } else |_| {}

    return error.NoHomeDir;
}

pub fn transcriptPath(
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
    history_id: []const u8,
) ![]u8 {
    const base = try getBaseDir(allocator);
    defer allocator.free(base);
    const safe_workspace = try safeId(allocator, workspace_id);
    defer allocator.free(safe_workspace);
    const safe_history = try safeId(allocator, history_id);
    defer allocator.free(safe_history);
    const file_name = try std.fmt.allocPrint(allocator, "{s}.ansi", .{safe_history});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ base, safe_workspace, file_name });
}

pub fn databasePath(allocator: std.mem.Allocator) ![]u8 {
    const base = try getBaseDir(allocator);
    defer allocator.free(base);
    return std.fs.path.join(allocator, &.{ base, "history.sqlite3" });
}

pub fn capLines(allocator: std.mem.Allocator, input: []const u8, max_lines: usize) ![]u8 {
    if (max_lines == 0 or input.len == 0) return allocator.dupe(u8, "");

    var count: usize = 0;
    var start: usize = input.len;
    var idx = input.len;
    while (idx > 0) {
        idx -= 1;
        if (input[idx] != '\n') continue;
        if (idx + 1 == input.len) continue;

        count += 1;
        if (count == max_lines) {
            start = idx + 1;
            break;
        }
    }

    if (count < max_lines) start = 0;
    return allocator.dupe(u8, input[start..]);
}

fn isCsiFinalByte(c: u8) bool {
    return c >= 0x40 and c <= 0x7e;
}

fn shouldStripCsi(body: []const u8, final: u8) bool {
    if (final == 'n' or final == 'c') return true;
    if (final == 'R') {
        for (body) |c| {
            if (!std.ascii.isDigit(c) and c != ';' and c != '?') return false;
        }
        return true;
    }
    return false;
}

fn shouldStripOsc(content: []const u8) bool {
    return std.mem.startsWith(u8, content, "10;?") or
        std.mem.startsWith(u8, content, "10;rgb:") or
        std.mem.startsWith(u8, content, "11;?") or
        std.mem.startsWith(u8, content, "11;rgb:") or
        std.mem.startsWith(u8, content, "12;?") or
        std.mem.startsWith(u8, content, "12;rgb:");
}

pub fn sanitizeChunk(
    allocator: std.mem.Allocator,
    state: *SanitizerState,
    chunk: []const u8,
    out: *std.ArrayListUnmanaged(u8),
) !void {
    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(allocator);
    try input.appendSlice(allocator, state.pending.items);
    try input.appendSlice(allocator, chunk);
    state.pending.clearRetainingCapacity();

    var i: usize = 0;
    while (i < input.items.len) {
        if (input.items[i] != 0x1b) {
            try out.append(allocator, input.items[i]);
            i += 1;
            continue;
        }

        if (i + 1 >= input.items.len) {
            try state.pending.appendSlice(allocator, input.items[i..]);
            return;
        }

        const next = input.items[i + 1];
        if (next == '[') {
            var j = i + 2;
            while (j < input.items.len and !isCsiFinalByte(input.items[j])) : (j += 1) {}
            if (j >= input.items.len) {
                try state.pending.appendSlice(allocator, input.items[i..]);
                return;
            }

            const body = input.items[i + 2 .. j];
            const final = input.items[j];
            if (!shouldStripCsi(body, final)) {
                try out.appendSlice(allocator, input.items[i .. j + 1]);
            }
            i = j + 1;
            continue;
        }

        if (next == ']') {
            var j = i + 2;
            while (j < input.items.len) : (j += 1) {
                if (input.items[j] == 0x07) break;
                if (input.items[j] == 0x1b and j + 1 < input.items.len and input.items[j + 1] == '\\') break;
            }
            if (j >= input.items.len) {
                try state.pending.appendSlice(allocator, input.items[i..]);
                return;
            }

            const terminator_len: usize = if (input.items[j] == 0x1b) 2 else 1;
            const content = input.items[i + 2 .. j];
            if (!shouldStripOsc(content)) {
                try out.appendSlice(allocator, input.items[i .. j + terminator_len]);
            }
            i = j + terminator_len;
            continue;
        }

        try out.appendSlice(allocator, input.items[i..@min(i + 2, input.items.len)]);
        i += 2;
    }
}

pub fn appendTranscript(
    allocator: std.mem.Allocator,
    path: []const u8,
    chunk: []const u8,
    options: Options,
) !void {
    if (!options.enabled or chunk.len == 0) return;
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    std.fs.makeDirAbsolute(parent) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const existing = readFileMax(allocator, path, options.max_bytes_per_surface) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(existing);

    var combined: std.ArrayListUnmanaged(u8) = .empty;
    defer combined.deinit(allocator);
    try combined.appendSlice(allocator, existing);
    try combined.appendSlice(allocator, chunk);

    const capped_lines = try capLines(allocator, combined.items, options.max_lines_per_surface);
    defer allocator.free(capped_lines);

    const start = if (capped_lines.len > options.max_bytes_per_surface)
        capped_lines.len - options.max_bytes_per_surface
    else
        0;

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(capped_lines[start..]);
}

pub fn readTranscript(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: Options,
) ![]u8 {
    if (!options.enabled or options.restore_mode != .transcript) return allocator.dupe(u8, "");
    return readFileMax(allocator, path, options.max_bytes_per_surface) catch |err| switch (err) {
        error.FileNotFound => allocator.dupe(u8, ""),
        else => return err,
    };
}

pub fn clearTranscript(path: []const u8) !void {
    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub fn shouldDeleteForLifecycle(reason: LifecycleReason) bool {
    return switch (reason) {
        .explicit_clear,
        .restart,
        .cwd_changed,
        .env_changed,
        .exited_reopen,
        .error_reopen,
        .workspace_deleted,
        => true,
        .normal_close => false,
    };
}

pub fn clearSurfaceHistory(
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
    history_id: []const u8,
) !void {
    const path = try transcriptPath(allocator, workspace_id, history_id);
    defer allocator.free(path);
    try clearTranscript(path);
}

pub fn clearWorkspaceHistory(
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
) !void {
    const base = try getBaseDir(allocator);
    defer allocator.free(base);
    const safe_workspace = try safeId(allocator, workspace_id);
    defer allocator.free(safe_workspace);
    const dir_path = try std.fs.path.join(allocator, &.{ base, safe_workspace });
    defer allocator.free(dir_path);
    std.fs.deleteTreeAbsolute(dir_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub fn shouldDeleteForRetention(file_mtime_seconds: i128, now_seconds: i128, retention_days: u32) bool {
    if (retention_days == 0) return false;
    const retention_seconds: i128 = @as(i128, @intCast(retention_days)) * 24 * 60 * 60;
    return now_seconds - file_mtime_seconds > retention_seconds;
}

pub fn retentionCutoffIso(allocator: std.mem.Allocator, retention_days: u32) ![]const u8 {
    const now = std.time.timestamp();
    const retention_seconds: i64 = @as(i64, @intCast(retention_days)) * 24 * 60 * 60;
    const cutoff = now - retention_seconds;
    const secs: u64 = @intCast(if (cutoff < 0) 0 else cutoff);
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const epoch_day = es.getEpochDay();
    const day_seconds = es.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

pub fn cleanupRetention(allocator: std.mem.Allocator, options: Options) !void {
    if (options.retention_days == 0) return;

    const base = try getBaseDir(allocator);
    defer allocator.free(base);

    var base_dir = std.fs.openDirAbsolute(base, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer base_dir.close();

    const now_seconds: i128 = std.time.timestamp();
    var workspace_it = base_dir.iterate();
    while (try workspace_it.next()) |workspace_entry| {
        if (workspace_entry.kind != .directory) continue;
        var workspace_dir = base_dir.openDir(workspace_entry.name, .{ .iterate = true }) catch continue;
        defer workspace_dir.close();

        var file_it = workspace_dir.iterate();
        while (try file_it.next()) |file_entry| {
            if (file_entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, file_entry.name, ".ansi")) continue;
            const stat = workspace_dir.statFile(file_entry.name) catch continue;
            const mtime_seconds = @divTrunc(stat.mtime, std.time.ns_per_s);
            if (!shouldDeleteForRetention(mtime_seconds, now_seconds, options.retention_days)) continue;
            workspace_dir.deleteFile(file_entry.name) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
    }
}

fn readFileMax(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    const stat = try file.stat();
    const file_size: usize = @intCast(@min(stat.size, std.math.maxInt(usize)));
    if (file_size > max_bytes) {
        try file.seekTo(file_size - max_bytes);
    }
    return file.readToEndAlloc(allocator, max_bytes);
}

test "terminal history safeId preserves safe chars and encodes unsafe chars" {
    const allocator = std.testing.allocator;
    const safe = try safeId(allocator, "workspace/main:default terminal");
    defer allocator.free(safe);
    try std.testing.expectEqualStrings("workspace_main_default_terminal", safe);
}

test "terminal history capLines keeps newest complete lines" {
    const allocator = std.testing.allocator;
    const capped = try capLines(allocator, "one\ntwo\nthree\nfour\n", 3);
    defer allocator.free(capped);
    try std.testing.expectEqualStrings("two\nthree\nfour\n", capped);
}

test "terminal history validates uuid-like ids" {
    try std.testing.expect(isValidUuidLike("1bd69a49-a78d-4a3c-a3a8-8898dbd260a1"));
    try std.testing.expect(!isValidUuidLike("shell-1234"));
}

test "terminal history sanitizer mirrors T3Code terminal reply stripping" {
    var state = SanitizerState{};
    defer state.deinit(std.testing.allocator);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try sanitizeChunk(
        std.testing.allocator,
        &state,
        "prompt \x1b[32mok\x1b[0m \x1b]11;rgb:ffff/ffff/ffff\x07\x1b[1;1Rdone\n",
        &out,
    );

    try std.testing.expectEqualStrings("prompt \x1b[32mok\x1b[0m done\n", out.items);
    try std.testing.expectEqual(@as(usize, 0), state.pending.items.len);
}

test "terminal history sanitizer carries incomplete control sequence" {
    var state = SanitizerState{};
    defer state.deinit(std.testing.allocator);
    var first: std.ArrayListUnmanaged(u8) = .empty;
    defer first.deinit(std.testing.allocator);
    var second: std.ArrayListUnmanaged(u8) = .empty;
    defer second.deinit(std.testing.allocator);

    try sanitizeChunk(std.testing.allocator, &state, "hello \x1b[", &first);
    try std.testing.expectEqualStrings("hello ", first.items);
    try std.testing.expect(state.pending.items.len > 0);

    try sanitizeChunk(std.testing.allocator, &state, "32mgreen\x1b[0m\n", &second);
    try std.testing.expectEqualStrings("\x1b[32mgreen\x1b[0m\n", second.items);
    try std.testing.expectEqual(@as(usize, 0), state.pending.items.len);
}

test "terminal history append read and clear transcript" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);

    const path = try std.fs.path.join(allocator, &.{ base, "history.ansi" });
    defer allocator.free(path);

    try appendTranscript(allocator, path, "one\n", .{ .max_lines_per_surface = 5000 });
    try appendTranscript(allocator, path, "two\n", .{ .max_lines_per_surface = 5000 });

    const read = try readTranscript(allocator, path, .{ .max_lines_per_surface = 5000 });
    defer allocator.free(read);
    try std.testing.expectEqualStrings("one\ntwo\n", read);

    try clearTranscript(path);
    const cleared = try readTranscript(allocator, path, .{ .max_lines_per_surface = 5000 });
    defer allocator.free(cleared);
    try std.testing.expectEqualStrings("", cleared);
}

test "terminal transcript writer coalesces pending chunks" {
    var writer = TranscriptWriter.init(std.testing.allocator, "/tmp/termplex-test.ansi", .{});
    defer writer.deinit();

    try writer.queue("one\n");
    try writer.queue("two\n");
    try std.testing.expectEqualStrings("one\ntwo\n", writer.pending.items);
}

test "terminal history lifecycle deletion policy" {
    try std.testing.expect(shouldDeleteForLifecycle(.explicit_clear));
    try std.testing.expect(shouldDeleteForLifecycle(.restart));
    try std.testing.expect(shouldDeleteForLifecycle(.cwd_changed));
    try std.testing.expect(shouldDeleteForLifecycle(.env_changed));
    try std.testing.expect(shouldDeleteForLifecycle(.exited_reopen));
    try std.testing.expect(shouldDeleteForLifecycle(.error_reopen));
    try std.testing.expect(shouldDeleteForLifecycle(.workspace_deleted));
    try std.testing.expect(!shouldDeleteForLifecycle(.normal_close));
}

test "terminal history retention keeps current files when retention disabled" {
    try std.testing.expectEqual(@as(bool, false), shouldDeleteForRetention(0, 100, 0));
}

test "terminal history retention deletes older files" {
    const day: i128 = 24 * 60 * 60;
    try std.testing.expect(shouldDeleteForRetention(0, 100 * day, 90));
    try std.testing.expect(!shouldDeleteForRetention(0, 10 * day, 90));
}
