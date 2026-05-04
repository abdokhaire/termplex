const std = @import("std");
const build_config = @import("build_config.zig");

/// See build_config.ExeEntrypoint for why we do this.
const entrypoint = switch (build_config.exe_entrypoint) {
    .termplex => @import("main_termplex.zig"),
    .helpgen => @import("helpgen.zig"),
    .mdgen_termplex_1 => @import("build/mdgen/main_termplex_1.zig"),
    .mdgen_termplex_5 => @import("build/mdgen/main_termplex_5.zig"),
    .webgen_config => @import("build/webgen/main_config.zig"),
    .webgen_actions => @import("build/webgen/main_actions.zig"),
    .webgen_commands => @import("build/webgen/main_commands.zig"),
};

/// The main entrypoint for the program.
pub const main = entrypoint.main;

/// Standard options such as logger overrides.
pub const std_options: std.Options = if (@hasDecl(entrypoint, "std_options"))
    entrypoint.std_options
else
    .{};

test {
    _ = entrypoint;
    _ = @import("termplex/core/config.zig");
    _ = @import("termplex/core/session.zig");
    _ = @import("termplex/core/storage_status.zig");
    _ = @import("termplex/core/terminal_history.zig");
    _ = @import("termplex/core/terminal_history_db.zig");
    _ = @import("termplex/core/update_checker.zig");
    _ = @import("termplex/core/update_manifest.zig");
    _ = @import("termplex/core/update_state.zig");
    _ = @import("termplex/core/memory/state_manager.zig");
}
