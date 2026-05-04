const std = @import("std");

pub const SearchResult = struct {
    line_number: usize,
    line: []const u8,

    pub fn deinit(self: *SearchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.line);
    }
};

pub const SearchResults = struct {
    items: []SearchResult,

    pub fn deinit(self: SearchResults, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

fn isCsiFinalByte(c: u8) bool {
    return c >= 0x40 and c <= 0x7e;
}

fn isStringControlIntroducer(c: u8) bool {
    return c == 'P' or c == 'X' or c == '^' or c == '_';
}

fn skipUntilStringTerminator(bytes: []const u8, start: usize) usize {
    var j = start;
    while (j < bytes.len) : (j += 1) {
        if (bytes[j] == 0x07) return j + 1;
        if (bytes[j] == 0x1b and j + 1 < bytes.len and bytes[j + 1] == '\\') return j + 2;
    }
    return bytes.len;
}

pub fn stripControlSequences(alloc: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < bytes.len) {
        const c = bytes[i];
        if (c == 0x1b) {
            if (i + 1 >= bytes.len) break;
            const next = bytes[i + 1];
            if (next == '[') {
                var j = i + 2;
                while (j < bytes.len and !isCsiFinalByte(bytes[j])) : (j += 1) {}
                i = if (j < bytes.len) j + 1 else bytes.len;
                continue;
            }
            if (next == ']' or isStringControlIntroducer(next)) {
                i = skipUntilStringTerminator(bytes, i + 2);
                continue;
            }
            i += 2;
            continue;
        }

        if (c == '\r') {
            if (i + 1 < bytes.len and bytes[i + 1] == '\n') {
                try out.append(alloc, '\n');
                i += 2;
                continue;
            }
            try out.append(alloc, '\n');
            i += 1;
            continue;
        }

        if (c == '\n' or c == '\t' or c >= 0x20) {
            try out.append(alloc, c);
        }
        i += 1;
    }

    return out.toOwnedSlice(alloc);
}

pub fn extractLastLines(text: []const u8, n: usize) []const u8 {
    if (text.len == 0 or n == 0) return "";

    var end: usize = text.len;
    if (text[end - 1] == '\n') end -= 1;

    var count: usize = 0;
    var pos: usize = end;
    while (pos > 0) {
        pos -= 1;
        if (text[pos] == '\n') {
            count += 1;
            if (count >= n) return text[pos + 1 ..];
        }
    }

    return text;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var matched = true;
        for (needle, 0..) |needle_c, offset| {
            if (std.ascii.toLower(haystack[start + offset]) != std.ascii.toLower(needle_c)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

pub fn searchLines(
    allocator: std.mem.Allocator,
    text: []const u8,
    query: []const u8,
    limit: usize,
) !SearchResults {
    if (query.len == 0 or limit == 0) return .{ .items = try allocator.alloc(SearchResult, 0) };

    var items: std.ArrayListUnmanaged(SearchResult) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }

    var line_start: usize = 0;
    var line_number: usize = 1;
    while (line_start <= text.len) {
        const newline = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
        const line = text[line_start..newline];
        if (containsIgnoreCase(line, query)) {
            try items.append(allocator, .{
                .line_number = line_number,
                .line = try allocator.dupe(u8, line),
            });
            if (items.items.len >= limit) break;
        }
        if (newline == text.len) break;
        line_start = newline + 1;
        line_number += 1;
    }

    return .{ .items = try items.toOwnedSlice(allocator) };
}

test "transcript view strips terminal control sequences" {
    const bytes = "one\r\n\x1b]133;A;aid=1\x07two\x1b[31m red\x1b[0m\rthree\x01four";
    const out = try stripControlSequences(std.testing.allocator, bytes);
    defer std.testing.allocator.free(out);

    try std.testing.expectEqualStrings("one\ntwo red\nthreefour", out);
}

test "transcript view strips string control sequences" {
    const bytes = "safe\x1bPignored\x1b\\ text \x1b^pm\x1b\\ tail \x1b_sos\x1b\\";
    const out = try stripControlSequences(std.testing.allocator, bytes);
    defer std.testing.allocator.free(out);

    try std.testing.expectEqualStrings("safe text  tail ", out);
}

test "transcript view extracts last lines" {
    try std.testing.expectEqualStrings(
        "three\nfour\n",
        extractLastLines("one\ntwo\nthree\nfour\n", 2),
    );
    try std.testing.expectEqualStrings("one\n", extractLastLines("one\n", 10));
}

test "transcript view searches lines case insensitively" {
    const text = "Alpha\nbeta line\nGAMMA beta\n";
    const results = try searchLines(std.testing.allocator, text, "BeTa", 10);
    defer results.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    try std.testing.expectEqual(@as(usize, 2), results.items[0].line_number);
    try std.testing.expectEqualStrings("beta line", results.items[0].line);
    try std.testing.expectEqual(@as(usize, 3), results.items[1].line_number);
    try std.testing.expectEqualStrings("GAMMA beta", results.items[1].line);
}

test "transcript view search honors limit and ignores empty query" {
    const text = "match one\nnope\nmatch two\n";
    const limited = try searchLines(std.testing.allocator, text, "match", 1);
    defer limited.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), limited.items.len);

    const empty = try searchLines(std.testing.allocator, text, "", 10);
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.items.len);
}
