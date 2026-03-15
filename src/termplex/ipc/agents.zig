// src/termplex/ipc/agents.zig
// Agent registry: tracks AI agents running in terminal workspaces.
// Agents register via IPC and are discovered on-demand.

const std = @import("std");
const log = std.log.scoped(.agents);

pub const AgentType = enum {
    claude,
    codex,
    custom,

    pub fn fromString(s: []const u8) ?AgentType {
        return std.meta.stringToEnum(AgentType, s);
    }

    pub fn toString(self: AgentType) []const u8 {
        return @tagName(self);
    }
};

pub const Agent = struct {
    agent_id: [6]u8, // hex string
    workspace: []const u8, // workspace name (owned)
    tab: u32,
    agent_type: AgentType,
    pid: i32,
};

pub const AgentRegistry = struct {
    allocator: std.mem.Allocator,
    agents: std.ArrayListUnmanaged(Agent),
    next_id: u32,

    pub fn init(allocator: std.mem.Allocator) AgentRegistry {
        return .{
            .allocator = allocator,
            .agents = .empty,
            .next_id = 1,
        };
    }

    pub fn deinit(self: *AgentRegistry) void {
        for (self.agents.items) |agent| {
            self.allocator.free(agent.workspace);
        }
        self.agents.deinit(self.allocator);
    }

    /// Register a new agent. Returns the agent_id hex string.
    pub fn register(self: *AgentRegistry, workspace: []const u8, tab: u32, agent_type: AgentType, pid: i32) ![6]u8 {
        // Generate agent_id from counter
        var id_buf: [6]u8 = undefined;
        _ = std.fmt.bufPrint(&id_buf, "{x:0>6}", .{self.next_id}) catch return error.OutOfMemory;
        self.next_id += 1;

        const ws_owned = try self.allocator.dupe(u8, workspace);
        errdefer self.allocator.free(ws_owned);

        try self.agents.append(self.allocator, .{
            .agent_id = id_buf,
            .workspace = ws_owned,
            .tab = tab,
            .agent_type = agent_type,
            .pid = pid,
        });

        return id_buf;
    }

    /// Unregister an agent by PID.
    pub fn unregister(self: *AgentRegistry, pid: i32) bool {
        for (self.agents.items, 0..) |agent, idx| {
            if (agent.pid == pid) {
                self.allocator.free(agent.workspace);
                _ = self.agents.orderedRemove(idx);
                return true;
            }
        }
        return false;
    }

    /// Check if a PID is still alive using kill(pid, 0).
    pub fn isAlive(pid: i32) bool {
        std.posix.kill(@intCast(pid), 0) catch |err| {
            return switch (err) {
                error.ProcessNotFound => false,
                error.PermissionDenied => true, // process exists but no permission
                else => false,
            };
        };
        return true; // kill(pid, 0) succeeded — process exists
    }

    /// Remove all dead agents (PIDs that no longer exist).
    pub fn cleanupDead(self: *AgentRegistry) void {
        var i: usize = 0;
        while (i < self.agents.items.len) {
            if (!isAlive(self.agents.items[i].pid)) {
                self.allocator.free(self.agents.items[i].workspace);
                _ = self.agents.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Persist registry to JSON file.
    pub fn save(self: *AgentRegistry, path: []const u8) void {
        const alloc = self.allocator;

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);

        buf.appendSlice(alloc, "{\"agents\":[") catch return;
        for (self.agents.items, 0..) |agent, idx| {
            if (idx > 0) buf.appendSlice(alloc, ",") catch return;
            buf.appendSlice(alloc, "{\"agent_id\":\"") catch return;
            buf.appendSlice(alloc, &agent.agent_id) catch return;
            buf.appendSlice(alloc, "\",\"workspace\":\"") catch return;
            // JSON-escape workspace name
            for (agent.workspace) |c| {
                if (c == '"' or c == '\\') buf.append(alloc, '\\') catch return;
                buf.append(alloc, c) catch return;
            }
            buf.appendSlice(alloc, "\",\"tab\":") catch return;
            var num_buf: [16]u8 = undefined;
            const tab_str = std.fmt.bufPrint(&num_buf, "{d}", .{agent.tab}) catch return;
            buf.appendSlice(alloc, tab_str) catch return;
            buf.appendSlice(alloc, ",\"type\":\"") catch return;
            buf.appendSlice(alloc, agent.agent_type.toString()) catch return;
            buf.appendSlice(alloc, "\",\"pid\":") catch return;
            const pid_str = std.fmt.bufPrint(&num_buf, "{d}", .{agent.pid}) catch return;
            buf.appendSlice(alloc, pid_str) catch return;
            buf.appendSlice(alloc, "}") catch return;
        }
        buf.appendSlice(alloc, "]}") catch return;

        // Atomic write: write to .tmp then rename
        const tmp_path = std.fmt.allocPrint(alloc, "{s}.tmp", .{path}) catch return;
        defer alloc.free(tmp_path);

        const file = std.fs.createFileAbsolute(tmp_path, .{}) catch return;
        file.writeAll(buf.items) catch {
            file.close();
            std.fs.deleteFileAbsolute(tmp_path) catch {};
            return;
        };
        file.close();

        std.fs.renameAbsolute(tmp_path, path) catch {};
    }
};

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

test "agent registry register and unregister" {
    const alloc = std.testing.allocator;
    var registry = AgentRegistry.init(alloc);
    defer registry.deinit();

    const id = try registry.register("backend", 0, .claude, 12345);
    try std.testing.expectEqual(@as(usize, 1), registry.agents.items.len);
    try std.testing.expectEqualStrings("000001", &id);

    const found = registry.unregister(12345);
    try std.testing.expect(found);
    try std.testing.expectEqual(@as(usize, 0), registry.agents.items.len);
}

test "agent registry unregister nonexistent returns false" {
    const alloc = std.testing.allocator;
    var registry = AgentRegistry.init(alloc);
    defer registry.deinit();

    try std.testing.expect(!registry.unregister(99999));
}
