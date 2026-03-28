const std = @import("std");

const assert = @import("../../../quirks.zig").inlineAssert;

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;

/// Parse OSC 7337 — orchestrator command tracking for the memory system.
/// Payload contains "cmd_start;<pid>;<command>" or "cmd_end;<pid>;<exit_code>"
pub fn parse(parser: *Parser, _: ?u8) ?*Command {
    assert(parser.state == .@"7337");
    const writer = parser.writer orelse {
        parser.state = .invalid;
        return null;
    };
    writer.writeByte(0) catch {
        parser.state = .invalid;
        return null;
    };
    const data = writer.buffered();
    parser.command = .{
        .orchestrator_cmd = data[0 .. data.len - 1 :0],
    };
    return &parser.command;
}

test "OSC 7337: cmd_start" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "7337;cmd_start;1234;ls -la";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .orchestrator_cmd);
    try testing.expectEqualStrings("cmd_start;1234;ls -la", cmd.orchestrator_cmd);
}

test "OSC 7337: cmd_end" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "7337;cmd_end;1234;0";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .orchestrator_cmd);
    try testing.expectEqualStrings("cmd_end;1234;0", cmd.orchestrator_cmd);
}

test "OSC 7337: empty payload" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "7337;";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .orchestrator_cmd);
    try testing.expectEqualStrings("", cmd.orchestrator_cmd);
}

test "OSC 7337: incomplete sequence returns null" {
    const testing = std.testing;

    var p: Parser = .init(null);

    // Only "733" without the final "7" — should be incomplete
    const input = "733";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null);
    try testing.expect(cmd == null);
}
