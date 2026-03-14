// src/termplex/util/uuid.zig
// UUID v4 generation, formatting, parsing, and comparison.
//
// UUIDs are used throughout termplex for workspace IDs, surface IDs,
// tab IDs, and notification IDs.

const std = @import("std");

/// A 128-bit UUID represented as 16 bytes.
pub const Uuid = [16]u8;

/// Generate a new random UUID v4.
///
/// Sets the version bits (4) and variant bits (RFC 4122) as required by
/// the UUID v4 specification.
pub fn generate() Uuid {
    var uuid: Uuid = undefined;
    std.crypto.random.bytes(&uuid);

    // Set version to 4: bits 12-15 of octet 6
    uuid[6] = (uuid[6] & 0x0F) | 0x40;

    // Set variant to RFC 4122: bits 6-7 of octet 8
    uuid[8] = (uuid[8] & 0x3F) | 0x80;

    return uuid;
}

/// Format a UUID as the standard 36-character string:
/// "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
///
/// The output buffer must be at least 36 bytes.
pub fn format(uuid: Uuid, buf: []u8) void {
    std.debug.assert(buf.len >= 36);

    const hex = "0123456789abcdef";

    var i: usize = 0;
    var out: usize = 0;

    // Groups: 4-2-2-2-6 bytes
    const groups = [_]usize{ 4, 2, 2, 2, 6 };

    for (groups, 0..) |group_len, g| {
        if (g > 0) {
            buf[out] = '-';
            out += 1;
        }
        for (0..group_len) |_| {
            buf[out] = hex[(uuid[i] >> 4) & 0xF];
            buf[out + 1] = hex[uuid[i] & 0xF];
            out += 2;
            i += 1;
        }
    }
}

/// Format a UUID as an owned string using the provided allocator.
/// Caller is responsible for freeing the returned slice.
pub fn toString(uuid: Uuid, allocator: std.mem.Allocator) ![]u8 {
    const buf = try allocator.alloc(u8, 36);
    format(uuid, buf);
    return buf;
}

/// Parse a UUID from a 36-character string.
/// Returns error.InvalidUuid if the string is malformed.
pub fn parse(s: []const u8) !Uuid {
    if (s.len != 36) return error.InvalidUuid;

    // Verify dash positions
    if (s[8] != '-' or s[13] != '-' or s[18] != '-' or s[23] != '-') {
        return error.InvalidUuid;
    }

    var uuid: Uuid = undefined;
    var i: usize = 0; // byte index into uuid
    var src: usize = 0; // position in s

    // Groups: 4-2-2-2-6 bytes, separated by dashes
    const groups = [_]usize{ 4, 2, 2, 2, 6 };

    for (groups, 0..) |group_len, g| {
        if (g > 0) {
            src += 1; // skip dash
        }
        for (0..group_len) |_| {
            const hi = hexDigit(s[src]) catch return error.InvalidUuid;
            const lo = hexDigit(s[src + 1]) catch return error.InvalidUuid;
            uuid[i] = (hi << 4) | lo;
            i += 1;
            src += 2;
        }
    }

    return uuid;
}

/// Compare two UUIDs for equality.
pub fn eql(a: Uuid, b: Uuid) bool {
    return std.mem.eql(u8, &a, &b);
}

/// Parse a single hex digit. Returns error.InvalidHex for non-hex chars.
fn hexDigit(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHex,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "generate produces valid v4 UUID" {
    const uuid = generate();

    // Version must be 4 (upper nibble of byte 6)
    try std.testing.expectEqual(@as(u8, 4), (uuid[6] >> 4) & 0xF);

    // Variant must be 0b10xx (upper 2 bits of byte 8)
    try std.testing.expectEqual(@as(u8, 0b10), (uuid[8] >> 6) & 0b11);
}

test "format produces correct length and structure" {
    const uuid = generate();
    var buf: [36]u8 = undefined;
    format(uuid, &buf);

    const s = buf[0..36];
    try std.testing.expectEqual(@as(usize, 36), s.len);
    try std.testing.expectEqual('-', s[8]);
    try std.testing.expectEqual('-', s[13]);
    try std.testing.expectEqual('-', s[18]);
    try std.testing.expectEqual('-', s[23]);
}

test "format version digit is '4'" {
    const uuid = generate();
    var buf: [36]u8 = undefined;
    format(uuid, &buf);
    // The version digit is at position 14 (after "xxxxxxxx-xxxx-")
    try std.testing.expectEqual('4', buf[14]);
}

test "parse round-trips with format" {
    const original = generate();
    var buf: [36]u8 = undefined;
    format(original, &buf);

    const parsed = try parse(buf[0..]);
    try std.testing.expect(eql(original, parsed));
}

test "parse accepts uppercase hex" {
    const s = "550E8400-E29B-41D4-A716-446655440000";
    const uuid = try parse(s);
    _ = uuid; // just check it doesn't error
}

test "parse rejects wrong length" {
    try std.testing.expectError(error.InvalidUuid, parse("too-short"));
    try std.testing.expectError(error.InvalidUuid, parse("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx-extra"));
}

test "parse rejects missing dashes" {
    try std.testing.expectError(error.InvalidUuid, parse("550e8400xe29b-41d4-a716-446655440000"));
}

test "parse rejects invalid hex chars" {
    try std.testing.expectError(error.InvalidUuid, parse("550e8400-e29b-41d4-a716-44665544000z"));
}

test "eql returns true for same UUID" {
    const a = generate();
    const b = a;
    try std.testing.expect(eql(a, b));
}

test "eql returns false for different UUIDs" {
    const a = generate();
    const b = generate();
    // Astronomically unlikely to collide; treat collision as pass anyway
    if (!std.mem.eql(u8, &a, &b)) {
        try std.testing.expect(!eql(a, b));
    }
}

test "toString allocates correct string" {
    const uuid = generate();
    const s = try toString(uuid, std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqual(@as(usize, 36), s.len);

    const reparsed = try parse(s);
    try std.testing.expect(eql(uuid, reparsed));
}
