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

        try out.appendSlice(allocator, input.items[i .. @min(i + 2, input.items.len)]);
        i += 2;
    }
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
