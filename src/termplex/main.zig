// src/termplex/main.zig
// Central import point for the termplex module.
// GTK apprt code imports termplex modules through this root.
//
// NOTE: The @import references below point to files that will be created
// in Tasks 3-12. Zig only resolves @imports when they are actually used,
// so this file is safe to compile as long as no code references the
// sub-namespaces before their source files exist.

pub const core = struct {
    pub const workspace = @import("core/workspace.zig");
    pub const workspace_manager = @import("core/workspace_manager.zig");
    pub const notification = @import("core/notification.zig");
    pub const config = @import("core/config.zig");
    pub const git_probe = @import("core/git_probe.zig");
    pub const git_status = @import("core/git_status.zig");
    pub const port_scanner = @import("core/port_scanner.zig");
    pub const session = @import("core/session.zig");
    pub const storage_status = @import("core/storage_status.zig");
    pub const terminal_history = @import("core/terminal_history.zig");
    pub const terminal_history_db = @import("core/terminal_history_db.zig");
    pub const update_checker = @import("core/update_checker.zig");
    pub const update_manifest = @import("core/update_manifest.zig");
    pub const update_state = @import("core/update_state.zig");
};
pub const ipc = struct {
    pub const socket_server = @import("ipc/socket_server.zig");
    pub const protocol = @import("ipc/protocol.zig");
    pub const handle = @import("ipc/handle.zig");
    pub const agents = @import("ipc/agents.zig");
};
pub const util = struct {
    pub const uuid = @import("util/uuid.zig");
    pub const json = @import("util/json.zig");
};
