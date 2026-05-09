const std = @import("std");
const terminal_history = @import("terminal_history.zig");

pub const default_chunk_bytes: usize = 4096;
pub const replay_max_bytes: usize = 128 * 1024;

pub const Context = struct {
    workspace_active: bool = false,
    surface_focused: bool = false,
    workspace_recently_visible: bool = false,
};

pub fn priority(ctx: Context) u8 {
    if (ctx.workspace_active and ctx.surface_focused) return 100;
    if (ctx.workspace_active) return 50;
    if (ctx.workspace_recently_visible) return 20;
    return 5;
}

pub fn scheduleDelayMs(ctx: Context) u32 {
    if (ctx.workspace_active and ctx.surface_focused) return 0;
    if (ctx.workspace_active) return 100;
    if (ctx.workspace_recently_visible) return 500;
    return 1500;
}

pub fn nextChunkLen(remaining: usize, chunk_size: usize) usize {
    if (chunk_size == 0) return 0;
    return @min(remaining, chunk_size);
}

pub fn backgroundOptions(options: terminal_history.Options) terminal_history.Options {
    var result = options;
    result.max_bytes_per_surface = @min(result.max_bytes_per_surface, replay_max_bytes);
    return result;
}

test "terminal replay prioritizes active focused surfaces" {
    const active_focused = priority(.{
        .workspace_active = true,
        .surface_focused = true,
        .workspace_recently_visible = true,
    });
    const active_background = priority(.{
        .workspace_active = true,
        .surface_focused = false,
        .workspace_recently_visible = true,
    });
    const inactive = priority(.{
        .workspace_active = false,
        .surface_focused = false,
        .workspace_recently_visible = false,
    });

    try std.testing.expect(active_focused > active_background);
    try std.testing.expect(active_background > inactive);
}

test "terminal replay delays inactive workspace jobs" {
    try std.testing.expectEqual(@as(u32, 0), scheduleDelayMs(.{
        .workspace_active = true,
        .surface_focused = true,
        .workspace_recently_visible = true,
    }));
    try std.testing.expect(scheduleDelayMs(.{
        .workspace_active = false,
        .surface_focused = false,
        .workspace_recently_visible = false,
    }) > 0);
}

test "terminal replay chunks are capped for idle delivery" {
    try std.testing.expectEqual(@as(usize, 4096), nextChunkLen(9000, 4096));
    try std.testing.expectEqual(@as(usize, 3000), nextChunkLen(3000, 4096));
    try std.testing.expectEqual(@as(usize, 0), nextChunkLen(3000, 0));
}

test "terminal replay caps background transcript bytes without changing persistence defaults" {
    const options = backgroundOptions(.{
        .max_bytes_per_surface = 10 * 1024 * 1024,
        .max_lines_per_surface = 5000,
    });

    try std.testing.expectEqual(@as(usize, replay_max_bytes), options.max_bytes_per_surface);
    try std.testing.expectEqual(@as(usize, 5000), options.max_lines_per_surface);
}
