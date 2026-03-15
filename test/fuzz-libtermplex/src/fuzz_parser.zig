const std = @import("std");
const termplex_vt = @import("termplex-vt");

pub export fn zig_fuzz_init() callconv(.c) void {
    // Nothing to do
}

pub export fn zig_fuzz_test(
    buf: [*]const u8,
    len: usize,
) callconv(.c) void {
    var p: termplex_vt.Parser = .init();
    defer p.deinit();
    for (buf[0..@intCast(len)]) |byte| _ = p.next(byte);
}
