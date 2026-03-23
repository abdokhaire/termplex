const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("../cli.zig").termplex.Action;
const apprt = @import("../apprt.zig");
const args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");

pub const Options = struct {
    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    /// If set, open up a new split in a custom instance of Termplex.
    class: ?[:0]const u8 = null,

    /// The split direction: right, left, up, down, horizontal, vertical.
    /// Default: right.
    direction: [:0]const u8 = "right",

    /// Enable arg parsing diagnostics.
    _diagnostics: diagnostics.DiagnosticList = .{},

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `new-split` command will use native platform IPC to create a new split
/// in the active window of a running instance of Termplex.
///
/// The split is created in the currently focused surface of the active window.
/// If no direction is specified, the default is "right" (horizontal split).
///
/// Flags:
///
///   * `--class=<class>`: If set, target a custom instance of Termplex.
///
///   * `--direction=<direction>`: The direction for the new split pane.
///     Valid values: right (default), left, up, down, horizontal, vertical.
///     "horizontal" is an alias for "right", "vertical" is an alias for "down".
///
/// Available since: 1.3.0
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();

    var buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buffer);
    const stderr = &stderr_writer.interface;

    const result = runArgs(alloc, &iter, stderr);
    stderr.flush() catch {};
    return result;
}

fn runArgs(
    alloc_gpa: Allocator,
    argsIter: anytype,
    stderr: *std.Io.Writer,
) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    args.parse(Options, alloc_gpa, &opts, argsIter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        else => {
            try stderr.print("Error parsing args: {}\n", .{err});
            return 1;
        },
    };

    // Validate direction.
    const valid_directions = [_][]const u8{ "right", "left", "up", "down", "horizontal", "vertical" };
    var valid = false;
    for (valid_directions) |d| {
        if (std.mem.eql(u8, opts.direction, d)) {
            valid = true;
            break;
        }
    }
    if (!valid) {
        try stderr.print("Error: invalid direction '{s}'. Must be one of: right, left, up, down, horizontal, vertical\n", .{opts.direction});
        return 1;
    }

    if (apprt.App.performIpc(
        alloc_gpa,
        if (opts.class) |class| .{ .class = class } else .detect,
        .new_split,
        .{
            .direction = opts.direction,
        },
    ) catch |err| switch (err) {
        error.IPCFailed => {
            return 1;
        },
        else => {
            try stderr.print("Sending the IPC failed: {}", .{err});
            return 1;
        },
    }) return 0;

    try stderr.print("+new-split is not supported on this platform.\n", .{});
    return 1;
}
