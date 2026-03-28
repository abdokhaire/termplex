# Orchestrator Memory System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Termplex orchestrator persistent memory — structured process state (JSON) + accumulated knowledge (Markdown) — so it can resume services on startup and learn over time.

**Architecture:** Two-layer memory: (1) `state.json` files track running processes per workspace, updated by shell hooks + proc inspection; (2) `MEMORY.md`/`memory.md` files store accumulated knowledge written by the orchestrator agent. On startup, a resume manifest is built from state + memory and injected into the orchestrator's context.

**Tech Stack:** Zig 0.15.2, GTK4 + libadwaita, bash/zsh/fish shell integration, JSON serialization

**Spec:** `docs/superpowers/specs/2026-03-28-orchestrator-memory-design.md`

**Build:** `/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell`
**Test:** `/opt/zig-x86_64-linux-0.15.2/zig build test -Dtest-filter=<name>`
**Format:** `/opt/zig-x86_64-linux-0.15.2/zig fmt .`

---

## File Structure

### New Files

| File | Responsibility |
|------|---------------|
| `src/termplex/core/memory/state.zig` | State data types (`ProcessState`, `SurfaceState`, `WorkspaceState`, `MemoryState`) + JSON serialization/deserialization |
| `src/termplex/core/memory/state_manager.zig` | State manager: event handling, debounced writes, periodic snapshots, shutdown persistence |
| `src/termplex/core/memory/process_inspector.zig` | `/proc`-based fallback process detection via periodic timer |
| `src/termplex/core/memory/resume_manifest.zig` | Builds the text manifest string injected into orchestrator context on startup |
| `src/termplex/core/memory/paths.zig` | Path resolution for global state.json, per-workspace .termplex/state.json, MEMORY.md, memory.md |

### Existing Files to Modify

| File | Change |
|------|--------|
| `src/termplex/core/config.zig` | Add `Memory` struct + `[memory]` section parsing |
| `src/shell-integration/bash/termplex.bash` | Extend `__termplex_preexec`/`__termplex_precmd` with OSC 7337 |
| `src/shell-integration/zsh/termplex-integration` | Extend precmd/preexec hooks with OSC 7337 |
| `src/shell-integration/fish/vendor_conf.d/termplex-shell-integration.fish` | Extend fish hooks with OSC 7337 |
| `src/terminal/osc.zig` (or equivalent OSC parser) | Register OSC 7337 as a recognized sequence, parse cmd_start/cmd_end payloads |
| `src/apprt/gtk/class/surface.zig` | Handle parsed OSC 7337 events, forward command start/end to state manager |
| `src/apprt/gtk/class/application.zig` | Wire state manager: init, OSC event routing, debounce/periodic timers, shutdown flush + memory flush prompt, resume manifest injection |

---

## Task 1: Memory Configuration

Add the `Memory` config struct and `[memory]` section parsing to the existing config system.

**Files:**
- Modify: `src/termplex/core/config.zig`

- [ ] **Step 1: Write test for memory config defaults**

Add after the existing `test "default config values"` block (line 544) in `src/termplex/core/config.zig`:

```zig
test "memory config defaults" {
    const allocator = std.testing.allocator;
    var cfg = TermplexConfig.default(allocator);
    defer cfg.deinit();

    try std.testing.expectEqual(true, cfg.memory.enabled);
    try std.testing.expectEqual(true, cfg.memory.auto_resume);
    try std.testing.expectEqual(true, cfg.memory.flush_on_shutdown);
    try std.testing.expectEqual(@as(u32, 30), cfg.memory.proc_inspect_interval);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/opt/zig-x86_64-linux-0.15.2/zig build test -Dtest-filter="memory config defaults"`
Expected: FAIL — `cfg.memory` does not exist

- [ ] **Step 3: Add Memory struct and wire into TermplexConfig**

In `src/termplex/core/config.zig`, add after the `Orchestration` struct (after line 101):

```zig
/// Memory persistence configuration.
pub const Memory = struct {
    /// Whether the memory system is active.
    enabled: bool,
    /// Show resume prompt on startup.
    auto_resume: bool,
    /// Prompt orchestrator to save knowledge before shutdown.
    flush_on_shutdown: bool,
    /// Seconds between /proc fallback scans (0 = disabled).
    proc_inspect_interval: u32,
};
```

In the `TermplexConfig` struct, add after `orchestration: Orchestration,` (after line 126):

```zig
    // [memory]
    memory: Memory,
```

In `TermplexConfig.default()`, add after the orchestration defaults (after line 177):

```zig
            .memory = .{
                .enabled = true,
                .auto_resume = true,
                .flush_on_shutdown = true,
                .proc_inspect_interval = 30,
            },
```

- [ ] **Step 4: Run test to verify defaults pass**

Run: `/opt/zig-x86_64-linux-0.15.2/zig build test -Dtest-filter="memory config defaults"`
Expected: PASS

- [ ] **Step 5: Write test for memory config parsing**

Add after the new defaults test:

```zig
test "memory config parse" {
    const allocator = std.testing.allocator;
    const toml =
        \\[memory]
        \\enabled = false
        \\auto_resume = false
        \\flush_on_shutdown = false
        \\proc_inspect_interval = 60
    ;
    var cfg = try parseConfig(allocator, toml);
    defer cfg.deinit();

    try std.testing.expectEqual(false, cfg.memory.enabled);
    try std.testing.expectEqual(false, cfg.memory.auto_resume);
    try std.testing.expectEqual(false, cfg.memory.flush_on_shutdown);
    try std.testing.expectEqual(@as(u32, 60), cfg.memory.proc_inspect_interval);
}
```

- [ ] **Step 6: Run test to verify it fails**

Run: `/opt/zig-x86_64-linux-0.15.2/zig build test -Dtest-filter="memory config parse"`
Expected: FAIL — `[memory]` section not handled

- [ ] **Step 7: Add [memory] section parsing**

In `parseConfig()`, after the `[orchestration]` section handler block (after line 436), add:

```zig
        } else if (std.mem.eql(u8, current_section, "memory")) {
            if (std.mem.eql(u8, key, "enabled")) {
                cfg.memory.enabled = parseBool(value) orelse cfg.memory.enabled;
            } else if (std.mem.eql(u8, key, "auto_resume")) {
                cfg.memory.auto_resume = parseBool(value) orelse cfg.memory.auto_resume;
            } else if (std.mem.eql(u8, key, "flush_on_shutdown")) {
                cfg.memory.flush_on_shutdown = parseBool(value) orelse cfg.memory.flush_on_shutdown;
            } else if (std.mem.eql(u8, key, "proc_inspect_interval")) {
                cfg.memory.proc_inspect_interval = std.fmt.parseInt(u32, value, 10) catch continue;
            }
```

Note: The `Memory` struct has no heap-allocated string fields, so no changes to `deinit()` or `parseConfig()` variable setup are needed.

- [ ] **Step 8: Run all config tests**

Run: `/opt/zig-x86_64-linux-0.15.2/zig build test -Dtest-filter="config"`
Expected: ALL PASS (including existing tests + new memory tests)

- [ ] **Step 9: Format and commit**

```bash
/opt/zig-x86_64-linux-0.15.2/zig fmt src/termplex/core/config.zig
git add src/termplex/core/config.zig
git commit -m "feat(memory): add Memory config struct with [memory] section parsing"
```

---

## Task 2: Memory Path Resolution

Create the module that resolves all memory-related file paths.

**Files:**
- Create: `src/termplex/core/memory/paths.zig`

- [ ] **Step 1: Write tests for path resolution**

Create `src/termplex/core/memory/paths.zig` with tests first:

```zig
// src/termplex/core/memory/paths.zig
// Resolve file paths for the orchestrator memory system.
//
// Global files (under orchestration dir):
//   <orchestration_dir>/state.json   — global process state
//   <orchestration_dir>/MEMORY.md    — global knowledge
//
// Per-workspace files (under workspace project dir):
//   <workspace_dir>/.termplex/state.json   — per-workspace process state
//   <workspace_dir>/.termplex/memory.md    — per-workspace knowledge

const std = @import("std");

/// Paths for the global memory files (under orchestration directory).
pub const GlobalPaths = struct {
    state_json: []const u8,
    memory_md: []const u8,

    pub fn deinit(self: *GlobalPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.state_json);
        allocator.free(self.memory_md);
    }
};

/// Paths for per-workspace memory files.
pub const WorkspacePaths = struct {
    state_json: []const u8,
    memory_md: []const u8,
    dot_termplex_dir: []const u8,

    pub fn deinit(self: *WorkspacePaths, allocator: std.mem.Allocator) void {
        allocator.free(self.state_json);
        allocator.free(self.memory_md);
        allocator.free(self.dot_termplex_dir);
    }
};

/// Resolve global memory paths from the orchestration directory.
/// The orchestration_dir should already be expanded (no ~/ prefix).
/// Caller owns the returned paths; call deinit() to free.
pub fn resolveGlobalPaths(allocator: std.mem.Allocator, orchestration_dir: []const u8) !GlobalPaths {
    return .{
        .state_json = try std.fs.path.join(allocator, &.{ orchestration_dir, "state.json" }),
        .memory_md = try std.fs.path.join(allocator, &.{ orchestration_dir, "MEMORY.md" }),
    };
}

/// Resolve per-workspace memory paths from the workspace directory.
/// Caller owns the returned paths; call deinit() to free.
pub fn resolveWorkspacePaths(allocator: std.mem.Allocator, workspace_dir: []const u8) !WorkspacePaths {
    const dot_dir = try std.fs.path.join(allocator, &.{ workspace_dir, ".termplex" });
    errdefer allocator.free(dot_dir);
    return .{
        .state_json = try std.fs.path.join(allocator, &.{ dot_dir, "state.json" }),
        .memory_md = try std.fs.path.join(allocator, &.{ dot_dir, "memory.md" }),
        .dot_termplex_dir = dot_dir,
    };
}

/// Ensure a directory exists, creating it if necessary.
/// Handles PathAlreadyExists gracefully.
pub fn ensureDir(dir_path: []const u8) !void {
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "resolve global paths" {
    const allocator = std.testing.allocator;
    var paths = try resolveGlobalPaths(allocator, "/home/user/.termplex/orchestration");
    defer paths.deinit(allocator);

    try std.testing.expectEqualStrings("/home/user/.termplex/orchestration/state.json", paths.state_json);
    try std.testing.expectEqualStrings("/home/user/.termplex/orchestration/MEMORY.md", paths.memory_md);
}

test "resolve workspace paths" {
    const allocator = std.testing.allocator;
    var paths = try resolveWorkspacePaths(allocator, "/home/user/projects/backend");
    defer paths.deinit(allocator);

    try std.testing.expectEqualStrings("/home/user/projects/backend/.termplex/state.json", paths.state_json);
    try std.testing.expectEqualStrings("/home/user/projects/backend/.termplex/memory.md", paths.memory_md);
    try std.testing.expectEqualStrings("/home/user/projects/backend/.termplex", paths.dot_termplex_dir);
}
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `/opt/zig-x86_64-linux-0.15.2/zig build test -Dtest-filter="resolve"`
Expected: PASS (pure path joining, no I/O)

- [ ] **Step 3: Format and commit**

```bash
/opt/zig-x86_64-linux-0.15.2/zig fmt src/termplex/core/memory/paths.zig
git add src/termplex/core/memory/paths.zig
git commit -m "feat(memory): add memory path resolution module"
```

---

## Task 3: State Data Types + JSON Serialization

Create the data structures for process state and their JSON read/write logic. Follows the same patterns as `src/termplex/core/session.zig`.

**Files:**
- Create: `src/termplex/core/memory/state.zig`

- [ ] **Step 1: Write test for state JSON round-trip**

Create `src/termplex/core/memory/state.zig` with types and a round-trip test:

```zig
// src/termplex/core/memory/state.zig
// Data types for the orchestrator memory state (state.json).
//
// Tracks running processes per workspace surface. Updated by shell hooks
// (OSC 7337) and process tree inspection (/proc fallback).

const std = @import("std");

pub const CURRENT_VERSION: u32 = 1;

/// How a process was detected.
pub const DetectionMethod = enum {
    shell_hook,
    proc_inspection,

    pub fn toString(self: DetectionMethod) []const u8 {
        return switch (self) {
            .shell_hook => "shell_hook",
            .proc_inspection => "proc_inspection",
        };
    }

    pub fn fromString(s: []const u8) ?DetectionMethod {
        if (std.mem.eql(u8, s, "shell_hook")) return .shell_hook;
        if (std.mem.eql(u8, s, "proc_inspection")) return .proc_inspection;
        return null;
    }
};

/// State of a single terminal surface.
pub const SurfaceState = struct {
    working_directory: []const u8,
    last_command: ?[]const u8,
    command_started_at: ?[]const u8, // ISO 8601 string
    process_pid: ?u32,
    process_alive: bool,
    detection_method: ?DetectionMethod,
    ports: []u16,

    pub fn deinit(self: *SurfaceState, allocator: std.mem.Allocator) void {
        allocator.free(self.working_directory);
        if (self.last_command) |c| allocator.free(c);
        if (self.command_started_at) |t| allocator.free(t);
        allocator.free(self.ports);
    }
};

/// State of a workspace.
pub const WorkspaceState = struct {
    dir: []const u8,
    /// Map of surface UUID string -> SurfaceState.
    surface_ids: [][]const u8,
    surfaces: []SurfaceState,

    pub fn deinit(self: *WorkspaceState, allocator: std.mem.Allocator) void {
        allocator.free(self.dir);
        for (self.surface_ids) |id| allocator.free(id);
        allocator.free(self.surface_ids);
        for (self.surfaces) |*s| s.deinit(allocator);
        allocator.free(self.surfaces);
    }
};

/// Top-level memory state.
pub const MemoryState = struct {
    version: u32,
    last_updated: []const u8, // ISO 8601
    last_shutdown: ?[]const u8, // ISO 8601 or null
    /// Parallel arrays: workspace_names[i] corresponds to workspaces[i].
    workspace_names: [][]const u8,
    workspaces: []WorkspaceState,

    pub fn deinit(self: *MemoryState, allocator: std.mem.Allocator) void {
        allocator.free(self.last_updated);
        if (self.last_shutdown) |s| allocator.free(s);
        for (self.workspace_names) |n| allocator.free(n);
        allocator.free(self.workspace_names);
        for (self.workspaces) |*w| w.deinit(allocator);
        allocator.free(self.workspaces);
    }
};

// ---------------------------------------------------------------------------
// JSON serialization
// ---------------------------------------------------------------------------

/// Serialize MemoryState to a JSON string. Caller owns the result.
pub fn toJson(allocator: std.mem.Allocator, data: MemoryState) ![]u8 {
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };

    try jw.beginObject();

    try jw.objectField("version");
    try jw.write(data.version);
    try jw.objectField("last_updated");
    try jw.write(data.last_updated);
    try jw.objectField("last_shutdown");
    if (data.last_shutdown) |s| try jw.write(s) else try jw.write(null);

    try jw.objectField("workspaces");
    try jw.beginObject();
    for (data.workspace_names, data.workspaces) |name, ws| {
        try jw.objectField(name);
        try writeWorkspace(&jw, ws);
    }
    try jw.endObject();

    try jw.endObject();

    return aw.toOwnedSlice();
}

fn writeWorkspace(jw: *std.json.Stringify, ws: WorkspaceState) !void {
    try jw.beginObject();
    try jw.objectField("dir");
    try jw.write(ws.dir);
    try jw.objectField("surfaces");
    try jw.beginObject();
    for (ws.surface_ids, ws.surfaces) |id, surface| {
        try jw.objectField(id);
        try writeSurface(jw, surface);
    }
    try jw.endObject();
    try jw.endObject();
}

pub fn writeSurface(jw: *std.json.Stringify, s: SurfaceState) !void {
    try jw.beginObject();

    try jw.objectField("working_directory");
    try jw.write(s.working_directory);

    try jw.objectField("last_command");
    if (s.last_command) |c| try jw.write(c) else try jw.write(null);

    try jw.objectField("command_started_at");
    if (s.command_started_at) |t| try jw.write(t) else try jw.write(null);

    try jw.objectField("process_pid");
    if (s.process_pid) |p| try jw.write(p) else try jw.write(null);

    try jw.objectField("process_alive");
    try jw.write(s.process_alive);

    try jw.objectField("detection_method");
    if (s.detection_method) |m| try jw.write(m.toString()) else try jw.write(null);

    try jw.objectField("ports");
    try jw.beginArray();
    for (s.ports) |p| try jw.write(p);
    try jw.endArray();

    try jw.endObject();
}

// ---------------------------------------------------------------------------
// JSON deserialization
// ---------------------------------------------------------------------------

/// Deserialize a JSON string into MemoryState. Caller owns the result.
/// Returns null if JSON is empty or malformed.
pub fn fromJson(allocator: std.mem.Allocator, json_str: []const u8) !?MemoryState {
    if (json_str.len == 0) return null;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch return null;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return null;

    const obj = root.object;

    // Version check
    const version_val = obj.get("version") orelse return null;
    const version = switch (version_val) {
        .integer => |i| @as(u32, @intCast(i)),
        else => return null,
    };
    if (version != CURRENT_VERSION) return error.UnsupportedVersion;

    // last_updated
    const lu_val = obj.get("last_updated") orelse return null;
    const last_updated = switch (lu_val) {
        .string => |s| try allocator.dupe(u8, s),
        else => return null,
    };
    errdefer allocator.free(last_updated);

    // last_shutdown (nullable)
    const last_shutdown: ?[]const u8 = blk: {
        const ls_val = obj.get("last_shutdown") orelse break :blk null;
        switch (ls_val) {
            .string => |s| break :blk try allocator.dupe(u8, s),
            .null => break :blk null,
            else => break :blk null,
        }
    };
    errdefer if (last_shutdown) |s| allocator.free(s);

    // workspaces object
    const ws_val = obj.get("workspaces") orelse return null;
    if (ws_val != .object) return null;
    const ws_obj = ws_val.object;

    var ws_names = std.ArrayList([]const u8).init(allocator);
    defer ws_names.deinit();
    var ws_states = std.ArrayList(WorkspaceState).init(allocator);
    defer {
        for (ws_states.items) |*w| w.deinit(allocator);
        ws_states.deinit();
    }

    var ws_iter = ws_obj.iterator();
    while (ws_iter.next()) |entry| {
        const name = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(name);
        const ws = try parseWorkspace(allocator, entry.value_ptr.*);
        try ws_names.append(name);
        try ws_states.append(ws);
    }

    return .{
        .version = version,
        .last_updated = last_updated,
        .last_shutdown = last_shutdown,
        .workspace_names = try ws_names.toOwnedSlice(),
        .workspaces = try ws_states.toOwnedSlice(),
    };
}

fn parseWorkspace(allocator: std.mem.Allocator, val: std.json.Value) !WorkspaceState {
    if (val != .object) return error.InvalidFormat;
    const obj = val.object;

    const dir_val = obj.get("dir") orelse return error.InvalidFormat;
    const dir = switch (dir_val) {
        .string => |s| try allocator.dupe(u8, s),
        else => return error.InvalidFormat,
    };
    errdefer allocator.free(dir);

    const surfaces_val = obj.get("surfaces") orelse return error.InvalidFormat;
    if (surfaces_val != .object) return error.InvalidFormat;
    const surfaces_obj = surfaces_val.object;

    var ids = std.ArrayList([]const u8).init(allocator);
    defer ids.deinit();
    var states = std.ArrayList(SurfaceState).init(allocator);
    defer {
        for (states.items) |*s| s.deinit(allocator);
        states.deinit();
    }

    var surf_iter = surfaces_obj.iterator();
    while (surf_iter.next()) |entry| {
        const id = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(id);
        const surface = try parseSurface(allocator, entry.value_ptr.*);
        try ids.append(id);
        try states.append(surface);
    }

    return .{
        .dir = dir,
        .surface_ids = try ids.toOwnedSlice(),
        .surfaces = try states.toOwnedSlice(),
    };
}

fn parseSurface(allocator: std.mem.Allocator, val: std.json.Value) !SurfaceState {
    if (val != .object) return error.InvalidFormat;
    const obj = val.object;

    const wd_val = obj.get("working_directory") orelse return error.InvalidFormat;
    const working_directory = switch (wd_val) {
        .string => |s| try allocator.dupe(u8, s),
        else => return error.InvalidFormat,
    };
    errdefer allocator.free(working_directory);

    const last_command = try getOptionalString(allocator, obj, "last_command");
    errdefer if (last_command) |c| allocator.free(c);

    const command_started_at = try getOptionalString(allocator, obj, "command_started_at");
    errdefer if (command_started_at) |t| allocator.free(t);

    const process_pid: ?u32 = blk: {
        const pid_val = obj.get("process_pid") orelse break :blk null;
        switch (pid_val) {
            .integer => |i| break :blk @as(u32, @intCast(i)),
            .null => break :blk null,
            else => break :blk null,
        }
    };

    const process_alive = blk: {
        const pa_val = obj.get("process_alive") orelse break :blk false;
        switch (pa_val) {
            .bool => |b| break :blk b,
            else => break :blk false,
        }
    };

    const detection_method: ?DetectionMethod = blk: {
        const dm_val = obj.get("detection_method") orelse break :blk null;
        switch (dm_val) {
            .string => |s| break :blk DetectionMethod.fromString(s),
            .null => break :blk null,
            else => break :blk null,
        }
    };

    // Parse ports array
    var ports_list = std.ArrayList(u16).init(allocator);
    defer ports_list.deinit();
    if (obj.get("ports")) |ports_val| {
        if (ports_val == .array) {
            for (ports_val.array.items) |p| {
                switch (p) {
                    .integer => |i| try ports_list.append(@as(u16, @intCast(i))),
                    else => {},
                }
            }
        }
    }

    return .{
        .working_directory = working_directory,
        .last_command = last_command,
        .command_started_at = command_started_at,
        .process_pid = process_pid,
        .process_alive = process_alive,
        .detection_method = detection_method,
        .ports = try ports_list.toOwnedSlice(),
    };
}

fn getOptionalString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| try allocator.dupe(u8, s),
        .null => null,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "state json round-trip" {
    const allocator = std.testing.allocator;

    const ports = try allocator.alloc(u16, 2);
    ports[0] = 8000;
    ports[1] = 8001;

    const surface_ids = try allocator.alloc([]const u8, 1);
    surface_ids[0] = try allocator.dupe(u8, "a1b2c3d4-e5f6-7890-abcd-ef1234567890");

    var surface = SurfaceState{
        .working_directory = try allocator.dupe(u8, "/home/user/project"),
        .last_command = try allocator.dupe(u8, "python manage.py runserver"),
        .command_started_at = try allocator.dupe(u8, "2026-03-28T12:00:00Z"),
        .process_pid = 12345,
        .process_alive = true,
        .detection_method = .shell_hook,
        .ports = ports,
    };

    const surfaces = try allocator.alloc(SurfaceState, 1);
    surfaces[0] = surface;

    const ws_names = try allocator.alloc([]const u8, 1);
    ws_names[0] = try allocator.dupe(u8, "backend");

    const workspaces = try allocator.alloc(WorkspaceState, 1);
    workspaces[0] = .{
        .dir = try allocator.dupe(u8, "/home/user/project"),
        .surface_ids = surface_ids,
        .surfaces = surfaces,
    };

    var state = MemoryState{
        .version = CURRENT_VERSION,
        .last_updated = try allocator.dupe(u8, "2026-03-28T14:00:00Z"),
        .last_shutdown = try allocator.dupe(u8, "2026-03-28T14:00:00Z"),
        .workspace_names = ws_names,
        .workspaces = workspaces,
    };
    defer state.deinit(allocator);

    // Serialize
    const json = try toJson(allocator, state);
    defer allocator.free(json);

    // Deserialize
    var parsed = (try fromJson(allocator, json)).?;
    defer parsed.deinit(allocator);

    // Verify
    try std.testing.expectEqual(CURRENT_VERSION, parsed.version);
    try std.testing.expectEqualStrings("2026-03-28T14:00:00Z", parsed.last_updated);
    try std.testing.expectEqualStrings("2026-03-28T14:00:00Z", parsed.last_shutdown.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.workspaces.len);
    try std.testing.expectEqualStrings("backend", parsed.workspace_names[0]);
    try std.testing.expectEqualStrings("/home/user/project", parsed.workspaces[0].dir);
    try std.testing.expectEqual(@as(usize, 1), parsed.workspaces[0].surfaces.len);
    try std.testing.expectEqualStrings("python manage.py runserver", parsed.workspaces[0].surfaces[0].last_command.?);
    try std.testing.expectEqual(@as(u32, 12345), parsed.workspaces[0].surfaces[0].process_pid.?);
    try std.testing.expectEqual(true, parsed.workspaces[0].surfaces[0].process_alive);
    try std.testing.expectEqual(DetectionMethod.shell_hook, parsed.workspaces[0].surfaces[0].detection_method.?);
    try std.testing.expectEqual(@as(usize, 2), parsed.workspaces[0].surfaces[0].ports.len);
    try std.testing.expectEqual(@as(u16, 8000), parsed.workspaces[0].surfaces[0].ports[0]);
}

test "state json null last_shutdown" {
    const allocator = std.testing.allocator;

    const ws_names = try allocator.alloc([]const u8, 0);
    const workspaces = try allocator.alloc(WorkspaceState, 0);

    var state = MemoryState{
        .version = CURRENT_VERSION,
        .last_updated = try allocator.dupe(u8, "2026-03-28T14:00:00Z"),
        .last_shutdown = null,
        .workspace_names = ws_names,
        .workspaces = workspaces,
    };
    defer state.deinit(allocator);

    const json = try toJson(allocator, state);
    defer allocator.free(json);

    var parsed = (try fromJson(allocator, json)).?;
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(@as(?[]const u8, null), parsed.last_shutdown);
}

test "state json empty input returns null" {
    const allocator = std.testing.allocator;
    const result = try fromJson(allocator, "");
    try std.testing.expectEqual(@as(?MemoryState, null), result);
}
```

- [ ] **Step 2: Run tests**

Run: `/opt/zig-x86_64-linux-0.15.2/zig build test -Dtest-filter="state json"`
Expected: PASS

- [ ] **Step 3: Format and commit**

```bash
/opt/zig-x86_64-linux-0.15.2/zig fmt src/termplex/core/memory/state.zig
git add src/termplex/core/memory/state.zig
git commit -m "feat(memory): add state data types with JSON serialization"
```

---

## Task 4: Resume Manifest Builder

Builds the text string injected into the orchestrator's initial context on startup.

**Files:**
- Create: `src/termplex/core/memory/resume_manifest.zig`

- [ ] **Step 1: Write test for manifest generation**

Create `src/termplex/core/memory/resume_manifest.zig`:

```zig
// src/termplex/core/memory/resume_manifest.zig
// Builds the resume manifest — a structured text block injected into the
// orchestrator agent's initial context on startup.
//
// The manifest includes:
//   - Previous session state (workspaces, running processes)
//   - Global knowledge (MEMORY.md contents)
//   - Per-workspace knowledge (memory.md contents)

const std = @import("std");
const state_mod = @import("state.zig");

const MemoryState = state_mod.MemoryState;

/// Build the resume manifest text from state and knowledge files.
///
/// Parameters:
///   state: The loaded MemoryState (or null if no previous state)
///   global_memory: Contents of MEMORY.md (empty string if not found)
///   workspace_memories: Parallel array of (workspace_name, memory.md contents)
///
/// Returns an allocated string. Caller owns the result.
pub fn buildManifest(
    allocator: std.mem.Allocator,
    state: ?MemoryState,
    global_memory: []const u8,
    workspace_memory_names: []const []const u8,
    workspace_memory_contents: []const []const u8,
) ![]u8 {
    var aw: std.io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("=== TERMPLEX ORCHESTRATOR CONTEXT ===\n\n");

    // Previous session state
    if (state) |s| {
        try w.writeAll("## Previous Session State\n");

        if (s.last_shutdown) |shutdown| {
            try w.print("Last session ended: {s} (graceful shutdown)\n\n", .{shutdown});
        } else {
            try w.writeAll("Last session ended unexpectedly (no graceful shutdown detected)\n\n");
        }

        for (s.workspace_names, s.workspaces) |ws_name, ws| {
            try w.print("### Workspace: {s} ({s})\n", .{ ws_name, ws.dir });

            var has_active = false;
            for (ws.surfaces, ws.surface_ids) |surface, surf_id| {
                if (surface.last_command) |cmd| {
                    if (surface.process_alive) {
                        has_active = true;
                        try w.print("- Surface {s}: `{s}`", .{ surf_id[0..@min(8, surf_id.len)], cmd });
                        if (surface.ports.len > 0) {
                            try w.writeAll(" (ports:");
                            for (surface.ports, 0..) |port, i| {
                                if (i > 0) try w.writeAll(",");
                                try w.print(" {d}", .{port});
                            }
                            try w.writeAll(")");
                        }
                        try w.writeAll("\n");
                    }
                }
            }
            if (!has_active) {
                try w.writeAll("- No active processes at shutdown\n");
            }
            try w.writeAll("\n");
        }
    } else {
        try w.writeAll("## Previous Session State\nNo previous session state found.\n\n");
    }

    // Global knowledge
    try w.writeAll("## Global Knowledge\n");
    if (global_memory.len > 0) {
        try w.writeAll(global_memory);
        if (global_memory[global_memory.len - 1] != '\n') try w.writeAll("\n");
    } else {
        try w.writeAll("No global knowledge file found.\n");
    }
    try w.writeAll("\n");

    // Per-workspace knowledge
    if (workspace_memory_names.len > 0) {
        try w.writeAll("## Workspace Knowledge\n");
        for (workspace_memory_names, workspace_memory_contents) |name, content| {
            try w.print("### {s}\n", .{name});
            if (content.len > 0) {
                try w.writeAll(content);
                if (content[content.len - 1] != '\n') try w.writeAll("\n");
            } else {
                try w.writeAll("No workspace knowledge file found.\n");
            }
            try w.writeAll("\n");
        }
    }

    return aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "manifest with state and knowledge" {
    const allocator = std.testing.allocator;

    // Build minimal state
    const ports = try allocator.alloc(u16, 1);
    ports[0] = 8000;
    const surf_ids = try allocator.alloc([]const u8, 1);
    surf_ids[0] = try allocator.dupe(u8, "a1b2c3d4-e5f6-7890-abcd-ef1234567890");
    const surfs = try allocator.alloc(state_mod.SurfaceState, 1);
    surfs[0] = .{
        .working_directory = try allocator.dupe(u8, "/home/user/backend"),
        .last_command = try allocator.dupe(u8, "python manage.py runserver"),
        .command_started_at = null,
        .process_pid = 1234,
        .process_alive = true,
        .detection_method = .shell_hook,
        .ports = ports,
    };
    const ws_names = try allocator.alloc([]const u8, 1);
    ws_names[0] = try allocator.dupe(u8, "backend");
    const wss = try allocator.alloc(state_mod.WorkspaceState, 1);
    wss[0] = .{ .dir = try allocator.dupe(u8, "/home/user/backend"), .surface_ids = surf_ids, .surfaces = surfs };

    var ms = MemoryState{
        .version = 1,
        .last_updated = try allocator.dupe(u8, "2026-03-28T14:00:00Z"),
        .last_shutdown = try allocator.dupe(u8, "2026-03-28T14:00:00Z"),
        .workspace_names = ws_names,
        .workspaces = wss,
    };
    defer ms.deinit(allocator);

    const wm_names = [_][]const u8{"backend"};
    const wm_contents = [_][]const u8{"## Stack\n- Python 3.11\n"};

    const manifest = try buildManifest(
        allocator,
        ms,
        "## Preferences\n- Start backend first\n",
        &wm_names,
        &wm_contents,
    );
    defer allocator.free(manifest);

    // Verify key sections exist
    try std.testing.expect(std.mem.indexOf(u8, manifest, "=== TERMPLEX ORCHESTRATOR CONTEXT ===") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "graceful shutdown") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "python manage.py runserver") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "ports: 8000") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "Start backend first") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "Python 3.11") != null);
}

test "manifest with no state" {
    const allocator = std.testing.allocator;

    const manifest = try buildManifest(allocator, null, "", &.{}, &.{});
    defer allocator.free(manifest);

    try std.testing.expect(std.mem.indexOf(u8, manifest, "No previous session state found") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "No global knowledge file found") != null);
}

test "manifest crash recovery" {
    const allocator = std.testing.allocator;

    const ws_names = try allocator.alloc([]const u8, 0);
    const wss = try allocator.alloc(state_mod.WorkspaceState, 0);

    var ms = MemoryState{
        .version = 1,
        .last_updated = try allocator.dupe(u8, "2026-03-28T14:00:00Z"),
        .last_shutdown = null, // crash — no graceful shutdown
        .workspace_names = ws_names,
        .workspaces = wss,
    };
    defer ms.deinit(allocator);

    const manifest = try buildManifest(allocator, ms, "", &.{}, &.{});
    defer allocator.free(manifest);

    try std.testing.expect(std.mem.indexOf(u8, manifest, "unexpectedly") != null);
}
```

- [ ] **Step 2: Run tests**

Run: `/opt/zig-x86_64-linux-0.15.2/zig build test -Dtest-filter="manifest"`
Expected: PASS

- [ ] **Step 3: Format and commit**

```bash
/opt/zig-x86_64-linux-0.15.2/zig fmt src/termplex/core/memory/resume_manifest.zig
git add src/termplex/core/memory/resume_manifest.zig
git commit -m "feat(memory): add resume manifest builder"
```

---

## Task 5: Process Inspector (Proc Fallback)

Reads `/proc/<pid>/cmdline` to detect running processes when shell hooks are unavailable.

**Files:**
- Create: `src/termplex/core/memory/process_inspector.zig`

- [ ] **Step 1: Write the process inspector module**

Create `src/termplex/core/memory/process_inspector.zig`:

```zig
// src/termplex/core/memory/process_inspector.zig
// Fallback process detection via /proc filesystem.
//
// For surfaces without shell integration hooks, this module inspects
// child processes under each surface's shell PID by reading
// /proc/<pid>/cmdline and /proc/<pid>/children.

const std = @import("std");

const log = std.log.scoped(.memory_proc);

/// Result of inspecting a single PID's child processes.
pub const ProcessInfo = struct {
    pid: u32,
    cmdline: []const u8, // Owned by caller

    pub fn deinit(self: *ProcessInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.cmdline);
    }
};

/// Read the command line of a process from /proc/<pid>/cmdline.
/// Returns null if the process doesn't exist or cmdline is empty.
/// Replaces NUL separators with spaces for readability.
/// Caller owns the returned string.
pub fn readCmdline(allocator: std.mem.Allocator, pid: u32) !?[]u8 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/cmdline", .{pid}) catch return null;

    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    const raw = file.readToEndAlloc(allocator, 4096) catch return null;
    defer allocator.free(raw);

    if (raw.len == 0) return null;

    // Replace NUL bytes with spaces, trim trailing
    const result = try allocator.alloc(u8, raw.len);
    @memcpy(result, raw);
    for (result) |*c| {
        if (c.* == 0) c.* = ' ';
    }

    // Trim trailing spaces
    const trimmed_len = std.mem.trimRight(u8, result, " ").len;
    if (trimmed_len == 0) {
        allocator.free(result);
        return null;
    }

    // Resize to trimmed length
    if (trimmed_len < result.len) {
        const shrunk = allocator.realloc(result, trimmed_len) catch result;
        return shrunk[0..trimmed_len];
    }
    return result;
}

/// Get child PIDs of a process by reading /proc/<pid>/task/<pid>/children.
/// Returns an empty slice if the file doesn't exist.
/// Caller owns the returned slice.
pub fn getChildPids(allocator: std.mem.Allocator, parent_pid: u32) ![]u32 {
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/task/{d}/children", .{ parent_pid, parent_pid }) catch return &.{};

    const file = std.fs.openFileAbsolute(path, .{}) catch return allocator.alloc(u32, 0) catch &.{};
    defer file.close();

    const raw = file.readToEndAlloc(allocator, 4096) catch return allocator.alloc(u32, 0) catch &.{};
    defer allocator.free(raw);

    if (raw.len == 0) return try allocator.alloc(u32, 0);

    var pids = std.ArrayList(u32).init(allocator);
    defer pids.deinit();

    var iter = std.mem.tokenizeScalar(u8, raw, ' ');
    while (iter.next()) |tok| {
        const trimmed = std.mem.trim(u8, tok, " \t\n\r");
        if (trimmed.len == 0) continue;
        const pid = std.fmt.parseInt(u32, trimmed, 10) catch continue;
        try pids.append(pid);
    }

    return pids.toOwnedSlice();
}

/// Check if a PID is alive by sending signal 0.
/// Returns true if the process exists and we have permission to signal it.
pub fn isAlive(pid: u32) bool {
    const pid_i32: i32 = @intCast(pid);
    // std.posix.kill returns an error union. Signal 0 doesn't kill,
    // just checks if the process exists.
    std.posix.kill(pid_i32, 0) catch return false;
    return true;
}

/// Inspect a shell PID and find its deepest child process.
/// Returns the "most interesting" child (deepest in tree).
/// Returns null if no children found.
pub fn inspectShellChildren(allocator: std.mem.Allocator, shell_pid: u32) !?ProcessInfo {
    const children = try getChildPids(allocator, shell_pid);
    defer allocator.free(children);

    if (children.len == 0) return null;

    // Use the first child's deepest descendant
    var current_pid = children[0];

    // Walk up to 10 levels deep to find the leaf process
    var depth: u32 = 0;
    while (depth < 10) : (depth += 1) {
        const grandchildren = try getChildPids(allocator, current_pid);
        defer allocator.free(grandchildren);
        if (grandchildren.len == 0) break;
        current_pid = grandchildren[0];
    }

    const cmdline = try readCmdline(allocator, current_pid) orelse return null;
    return ProcessInfo{
        .pid = current_pid,
        .cmdline = cmdline,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "readCmdline returns null for nonexistent pid" {
    const allocator = std.testing.allocator;
    // PID 999999999 almost certainly doesn't exist
    const result = try readCmdline(allocator, 999999999);
    try std.testing.expectEqual(@as(?[]u8, null), result);
}

test "getChildPids returns empty for nonexistent pid" {
    const allocator = std.testing.allocator;
    const result = try getChildPids(allocator, 999999999);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}
```

- [ ] **Step 2: Run tests**

Run: `/opt/zig-x86_64-linux-0.15.2/zig build test -Dtest-filter="readCmdline"`
Expected: PASS

- [ ] **Step 3: Format and commit**

```bash
/opt/zig-x86_64-linux-0.15.2/zig fmt src/termplex/core/memory/process_inspector.zig
git add src/termplex/core/memory/process_inspector.zig
git commit -m "feat(memory): add /proc-based process inspector fallback"
```

---

## Task 6: State Manager

The central coordination module: handles events from shell hooks, triggers proc inspection, manages debounced writes, and performs shutdown persistence.

**Files:**
- Create: `src/termplex/core/memory/state_manager.zig`

- [ ] **Step 1: Write the state manager module**

Create `src/termplex/core/memory/state_manager.zig`:

```zig
// src/termplex/core/memory/state_manager.zig
// Central state manager for the orchestrator memory system.
//
// Responsibilities:
//   - Receive command start/end events from shell hooks (OSC 7337)
//   - Trigger periodic process inspection (fallback for no-hook shells)
//   - Debounce writes to state.json (max once per second)
//   - Persist final state on shutdown
//   - Load state on startup

const std = @import("std");
const state_mod = @import("state.zig");
const paths_mod = @import("paths.zig");

const log = std.log.scoped(.memory_state);

const MemoryState = state_mod.MemoryState;
const SurfaceState = state_mod.SurfaceState;
const WorkspaceState = state_mod.WorkspaceState;
const DetectionMethod = state_mod.DetectionMethod;

/// A command event received from a shell hook (OSC 7337).
pub const CommandEvent = struct {
    pub const Kind = enum { start, end };

    kind: Kind,
    surface_uuid: []const u8,
    workspace_name: []const u8,
    workspace_dir: []const u8,
    command: ?[]const u8, // Set for start events
    shell_pid: ?u32,
    exit_code: ?i32, // Set for end events
};

/// In-memory state for a single surface (not heap-managed, borrows strings).
const LiveSurface = struct {
    working_directory: []const u8,
    last_command: ?[]const u8,
    command_started_at: ?i64, // Unix timestamp (millis)
    process_pid: ?u32,
    process_alive: bool,
    detection_method: DetectionMethod,
    ports: []u16,
};

/// The state manager tracks live process state and persists it to disk.
pub const StateManager = struct {
    allocator: std.mem.Allocator,
    orchestration_dir: []const u8,
    dirty: bool,

    /// Loaded or built state. null until first event or load.
    state: ?MemoryState,

    pub fn init(allocator: std.mem.Allocator, orchestration_dir: []const u8) StateManager {
        return .{
            .allocator = allocator,
            .orchestration_dir = orchestration_dir,
            .dirty = false,
            .state = null,
        };
    }

    pub fn deinit(self: *StateManager) void {
        if (self.state) |*s| s.deinit(self.allocator);
        self.state = null;
    }

    /// Load state from disk. Returns true if state was loaded.
    pub fn loadFromDisk(self: *StateManager) !bool {
        var global_paths = try paths_mod.resolveGlobalPaths(self.allocator, self.orchestration_dir);
        defer global_paths.deinit(self.allocator);

        const file = std.fs.openFileAbsolute(global_paths.state_json, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer file.close();

        const max_size = 16 * 1024 * 1024;
        const contents = file.readToEndAlloc(self.allocator, max_size) catch return false;
        defer self.allocator.free(contents);

        if (try state_mod.fromJson(self.allocator, contents)) |loaded| {
            if (self.state) |*old| old.deinit(self.allocator);
            self.state = loaded;
            return true;
        }
        return false;
    }

    /// Persist current state to disk (global state.json).
    /// Called on debounce timer, periodic snapshot, and shutdown.
    pub fn saveToDisk(self: *StateManager) !void {
        const s = self.state orelse return;

        var global_paths = try paths_mod.resolveGlobalPaths(self.allocator, self.orchestration_dir);
        defer global_paths.deinit(self.allocator);

        // Ensure orchestration directory exists
        try paths_mod.ensureDir(self.orchestration_dir);

        const json = try state_mod.toJson(self.allocator, s);
        defer self.allocator.free(json);

        // Atomic write: .tmp -> rename
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{global_paths.state_json});
        defer self.allocator.free(tmp_path);

        {
            const file = try std.fs.createFileAbsolute(tmp_path, .{});
            defer file.close();
            try file.writeAll(json);
        }

        try std.fs.renameAbsolute(tmp_path, global_paths.state_json);
        self.dirty = false;

        log.info("saved memory state to {s}", .{global_paths.state_json});
    }

    /// Mark shutdown: set last_shutdown timestamp and mark all processes dead.
    pub fn markShutdown(self: *StateManager) void {
        var s = &(self.state orelse return);

        // Update last_shutdown with current timestamp.
        // Use epoch seconds as string; the resume manifest builder
        // can format it for human display.
        const now = std.time.timestamp();
        const ts = std.fmt.allocPrint(self.allocator, "{d}", .{now}) catch return;

        if (s.last_shutdown) |old| self.allocator.free(old);
        s.last_shutdown = ts;

        // Update last_updated
        const lu = self.allocator.dupe(u8, ts) catch return;
        self.allocator.free(s.last_updated);
        s.last_updated = lu;

        // Mark all processes as dead
        for (s.workspaces) |*ws| {
            for (ws.surfaces) |*surface| {
                surface.process_alive = false;
            }
        }

        self.dirty = true;
    }

    /// Handle an incoming command event (from OSC 7337 parsed by surface).
    /// Creates workspace/surface entries if they don't exist yet.
    /// Marks state as dirty for debounced write.
    pub fn handleCommandEvent(self: *StateManager, event: CommandEvent) void {
        // Ensure we have a state object
        if (self.state == null) {
            const ws_names = self.allocator.alloc([]const u8, 0) catch return;
            const wss = self.allocator.alloc(WorkspaceState, 0) catch return;
            const now_ts = std.fmt.allocPrint(self.allocator, "{d}", .{std.time.timestamp()}) catch return;
            self.state = .{
                .version = state_mod.CURRENT_VERSION,
                .last_updated = now_ts,
                .last_shutdown = null,
                .workspace_names = ws_names,
                .workspaces = wss,
            };
        }

        var s = &(self.state.?);

        // Find or create workspace
        const ws_idx = blk: {
            for (s.workspace_names, 0..) |name, i| {
                if (std.mem.eql(u8, name, event.workspace_name)) break :blk i;
            }
            // Create new workspace entry
            var names = std.ArrayList([]const u8).fromOwnedSlice(self.allocator, s.workspace_names);
            names.append(self.allocator.dupe(u8, event.workspace_name) catch return) catch return;
            s.workspace_names = names.toOwnedSlice() catch return;

            var wss = std.ArrayList(WorkspaceState).fromOwnedSlice(self.allocator, s.workspaces);
            const empty_ids = self.allocator.alloc([]const u8, 0) catch return;
            const empty_surfs = self.allocator.alloc(SurfaceState, 0) catch return;
            wss.append(.{
                .dir = self.allocator.dupe(u8, event.workspace_dir) catch return,
                .surface_ids = empty_ids,
                .surfaces = empty_surfs,
            }) catch return;
            s.workspaces = wss.toOwnedSlice() catch return;
            break :blk s.workspace_names.len - 1;
        };

        var ws = &s.workspaces[ws_idx];

        // Find or create surface
        const surf_idx = blk: {
            for (ws.surface_ids, 0..) |id, i| {
                if (std.mem.eql(u8, id, event.surface_uuid)) break :blk i;
            }
            // Create new surface entry
            var ids = std.ArrayList([]const u8).fromOwnedSlice(self.allocator, ws.surface_ids);
            ids.append(self.allocator.dupe(u8, event.surface_uuid) catch return) catch return;
            ws.surface_ids = ids.toOwnedSlice() catch return;

            const empty_ports = self.allocator.alloc(u16, 0) catch return;
            var surfs = std.ArrayList(SurfaceState).fromOwnedSlice(self.allocator, ws.surfaces);
            surfs.append(.{
                .working_directory = self.allocator.dupe(u8, event.workspace_dir) catch return,
                .last_command = null,
                .command_started_at = null,
                .process_pid = null,
                .process_alive = false,
                .detection_method = null,
                .ports = empty_ports,
            }) catch return;
            ws.surfaces = surfs.toOwnedSlice() catch return;
            break :blk ws.surface_ids.len - 1;
        };

        var surface = &ws.surfaces[surf_idx];

        switch (event.kind) {
            .start => {
                // Update command info
                if (surface.last_command) |old| self.allocator.free(old);
                surface.last_command = if (event.command) |c| self.allocator.dupe(u8, c) catch null else null;

                const now_str = std.fmt.allocPrint(self.allocator, "{d}", .{std.time.timestamp()}) catch null;
                if (surface.command_started_at) |old| self.allocator.free(old);
                surface.command_started_at = now_str;

                surface.process_pid = event.shell_pid;
                surface.process_alive = true;
                surface.detection_method = .shell_hook;
            },
            .end => {
                surface.process_alive = false;
            },
        }

        self.dirty = true;
    }

    /// Debounced save: only writes if dirty. Call this from a GLib timer (1s interval).
    pub fn debouncedSave(self: *StateManager) void {
        if (!self.dirty) return;
        self.saveToDisk() catch |err| {
            log.warn("debounced save failed: {}", .{err});
        };
    }

    /// Save per-workspace state.json for a specific workspace.
    /// Creates .termplex/ directory if needed.
    pub fn saveWorkspaceState(self: *StateManager, workspace_name: []const u8) !void {
        const s = self.state orelse return;

        for (s.workspace_names, s.workspaces) |name, ws| {
            if (!std.mem.eql(u8, name, workspace_name)) continue;

            var wp = try paths_mod.resolveWorkspacePaths(self.allocator, ws.dir);
            defer wp.deinit(self.allocator);

            // Ensure .termplex/ directory exists
            try paths_mod.ensureDir(wp.dot_termplex_dir);

            // Build per-workspace JSON (surfaces only, plus workspace_name)
            var aw: std.io.Writer.Allocating = .init(self.allocator);
            defer aw.deinit();
            var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };

            try jw.beginObject();
            try jw.objectField("version");
            try jw.write(state_mod.CURRENT_VERSION);
            try jw.objectField("workspace_name");
            try jw.write(name);
            try jw.objectField("last_updated");
            try jw.write(s.last_updated);
            try jw.objectField("last_shutdown");
            if (s.last_shutdown) |ls| try jw.write(ls) else try jw.write(null);
            try jw.objectField("surfaces");
            try jw.beginObject();
            for (ws.surface_ids, ws.surfaces) |id, surface| {
                try jw.objectField(id);
                try state_mod.writeSurface(&jw, surface);
            }
            try jw.endObject();
            try jw.endObject();

            const json = try aw.toOwnedSlice();
            defer self.allocator.free(json);

            // Atomic write
            const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{wp.state_json});
            defer self.allocator.free(tmp_path);
            {
                const file = try std.fs.createFileAbsolute(tmp_path, .{});
                defer file.close();
                try file.writeAll(json);
            }
            try std.fs.renameAbsolute(tmp_path, wp.state_json);
            return;
        }
    }

    /// Get the loaded state (read-only). Returns null if not loaded.
    pub fn getState(self: *const StateManager) ?MemoryState {
        return self.state;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "state manager init and deinit" {
    const allocator = std.testing.allocator;
    var mgr = StateManager.init(allocator, "/tmp/test-orch");
    defer mgr.deinit();

    try std.testing.expectEqual(@as(?MemoryState, null), mgr.getState());
    try std.testing.expectEqual(false, mgr.dirty);
}

test "state manager load nonexistent file" {
    const allocator = std.testing.allocator;
    var mgr = StateManager.init(allocator, "/tmp/nonexistent-orch-dir-12345");
    defer mgr.deinit();

    const loaded = try mgr.loadFromDisk();
    try std.testing.expectEqual(false, loaded);
}
```

- [ ] **Step 2: Run tests**

Run: `/opt/zig-x86_64-linux-0.15.2/zig build test -Dtest-filter="state manager"`
Expected: PASS

- [ ] **Step 3: Format and commit**

```bash
/opt/zig-x86_64-linux-0.15.2/zig fmt src/termplex/core/memory/state_manager.zig
git add src/termplex/core/memory/state_manager.zig
git commit -m "feat(memory): add state manager with load/save/shutdown"
```

---

## Task 7: Shell Integration — Bash OSC 7337

Extend the existing bash shell hooks to emit OSC 7337 command tracking sequences.

**Files:**
- Modify: `src/shell-integration/bash/termplex.bash`

- [ ] **Step 1: Add OSC 7337 to __termplex_preexec**

In `src/shell-integration/bash/termplex.bash`, add after line 262 (`builtin printf "\e]133;C;\a"`) and before `_termplex_executing=1`:

```bash
  # Report command to orchestrator memory (OSC 7337)
  builtin printf "\e]7337;cmd_start;%s;%s\a" "$$" "${cmd//[[:cntrl:]]/}"
```

- [ ] **Step 2: Add OSC 7337 to __termplex_precmd**

In `src/shell-integration/bash/termplex.bash`, add after line 244 (`builtin printf "\e]7;kitty-shell-cwd://%s%s\a" "$HOSTNAME" "$PWD"`) and before the closing `fi` on line 245:

```bash
    # Report command completion to orchestrator memory (OSC 7337)
    builtin printf "\e]7337;cmd_end;%s;%d\a" "$$" "$ret"
```

- [ ] **Step 3: Commit**

```bash
git add src/shell-integration/bash/termplex.bash
git commit -m "feat(memory): add OSC 7337 command tracking to bash shell integration"
```

---

## Task 8: Shell Integration — Zsh OSC 7337

Extend the existing zsh shell hooks to emit OSC 7337 command tracking sequences.

**Files:**
- Modify: `src/shell-integration/zsh/termplex-integration`

- [ ] **Step 1: Add OSC 7337 to zsh precmd**

In `src/shell-integration/zsh/termplex-integration`, add inside `_termplex_precmd()` near the end (before the closing `}`), after the CWD reporting:

```zsh
  # Report command completion to orchestrator memory (OSC 7337)
  builtin print -nu $_termplex_fd '\e]7337;cmd_end;'$$';'$cmd_status'\a'
```

- [ ] **Step 2: Add OSC 7337 to zsh preexec**

Find the preexec hook function and add before the return:

```zsh
  # Report command to orchestrator memory (OSC 7337)
  builtin print -nu $_termplex_fd '\e]7337;cmd_start;'$$';'${1//[[:cntrl:]]/}'\a'
```

- [ ] **Step 3: Commit**

```bash
git add src/shell-integration/zsh/termplex-integration
git commit -m "feat(memory): add OSC 7337 command tracking to zsh shell integration"
```

---

## Task 9: Shell Integration — Fish OSC 7337

Extend the existing fish shell hooks to emit OSC 7337 command tracking sequences.

**Files:**
- Modify: `src/shell-integration/fish/vendor_conf.d/termplex-shell-integration.fish`

- [ ] **Step 1: Add OSC 7337 to fish preexec**

In `termplex-shell-integration.fish`, add to the `__termplex_mark_output_start` function (the `fish_preexec` handler), before the end:

```fish
    # Report command to orchestrator memory (OSC 7337)
    echo -en "\e]7337;cmd_start;$fish_pid;$argv\a"
```

- [ ] **Step 2: Add OSC 7337 to fish postexec**

Add to the `__termplex_mark_output_end` function (the `fish_postexec` handler):

```fish
    # Report command completion to orchestrator memory (OSC 7337)
    echo -en "\e]7337;cmd_end;$fish_pid;$status\a"
```

- [ ] **Step 3: Commit**

```bash
git add src/shell-integration/fish/vendor_conf.d/termplex-shell-integration.fish
git commit -m "feat(memory): add OSC 7337 command tracking to fish shell integration"
```

---

## Task 10: OSC 7337 Parser Registration

Register OSC 7337 in the terminal's escape sequence parser so cmd_start/cmd_end payloads are recognized and routed.

**Important context:** The OSC parser in `src/terminal/osc.zig` uses a **character-by-character state machine**, NOT string matching. Each digit of the OSC number is a separate state transition. You must follow this pattern exactly.

**Files:**
- Modify: `src/terminal/osc.zig` (state machine, Command union, end() function)

- [ ] **Step 1: Explore the OSC parser state machine**

Read `src/terminal/osc.zig` fully. Map out:
1. The `Parser.State` enum (around lines 313-365) — find existing multi-digit states like `@"7"` (for OSC 7), `@"13"`, `@"133"` (for OSC 133)
2. The state transitions in the state machine `switch` (around lines 600-700) — see how `@"7"` transitions on seeing `'3'` etc.
3. The `end()` function — see how completed states dispatch to parsing functions
4. The `Command` union (around line 25) — see how parsed results are stored

Document exact line numbers for each.

- [ ] **Step 2: Add intermediate states for 7337**

In the `Parser.State` enum, add new states for the 4-digit OSC number. The state machine processes one digit at a time:

```zig
// Add to State enum alongside existing states like @"7", @"13", @"133"
@"73",    // Seen "73" — could become 733 or 7337
@"733",   // Seen "733" — could become 7337
@"7337",  // Seen "7337" — complete OSC number, now collecting payload
```

- [ ] **Step 3: Add state transitions**

In the state machine's switch statement, add transitions. Find the existing `@"7"` state (which handles OSC 7 for CWD). It currently has a `';' =>` branch for "7;". Add a `'3' =>` branch:

```zig
// In the @"7" state handler:
'3' => {
    self.state = .@"73";
},

// New state handlers:
.@"73" => switch (c) {
    '3' => self.state = .@"733",
    ';' => { /* handle OSC 73; if needed, otherwise reset */ },
    else => self.state = .ground,
},
.@"733" => switch (c) {
    '7' => self.state = .@"7337",
    else => self.state = .ground,
},
.@"7337" => switch (c) {
    ';' => {
        // OSC number complete. Start collecting payload data.
        // Transition to a state that accumulates the rest into the data buffer.
        self.state = .string_data; // or equivalent payload collection state
        self.osc_type = .orchestrator_cmd;
    },
    else => self.state = .ground,
},
```

**Note:** The exact state names, transition patterns, and payload collection mechanism depend on how the existing parser handles multi-digit OSC numbers (e.g., OSC 133). The implementer MUST study how OSC 133 is implemented and follow the identical pattern for 7337.

- [ ] **Step 4: Add Command union variant**

Add to the `Command` union:

```zig
/// Orchestrator memory command tracking (OSC 7337).
orchestrator_cmd: struct {
    kind: enum { cmd_start, cmd_end },
    pid: u32,
    payload: [:0]const u8,
},
```

- [ ] **Step 5: Add payload parser in end() function**

In the `end()` function, add a case for the `@"7337"` state that parses the collected payload string. The payload format is `cmd_start;<pid>;<command>` or `cmd_end;<pid>;<exit_code>`:

```zig
.@"7337" => {
    const data = self.getPayloadData(); // however the parser exposes collected data
    // Parse "cmd_start;<pid>;<command>" or "cmd_end;<pid>;<exit_code>"
    if (std.mem.startsWith(u8, data, "cmd_start;")) {
        const rest = data["cmd_start;".len..];
        const semi = std.mem.indexOfScalar(u8, rest, ';') orelse return null;
        const pid = std.fmt.parseInt(u32, rest[0..semi], 10) catch return null;
        return .{ .orchestrator_cmd = .{
            .kind = .cmd_start,
            .pid = pid,
            .payload = rest[semi + 1 ..],
        } };
    } else if (std.mem.startsWith(u8, data, "cmd_end;")) {
        const rest = data["cmd_end;".len..];
        const semi = std.mem.indexOfScalar(u8, rest, ';') orelse return null;
        const pid = std.fmt.parseInt(u32, rest[0..semi], 10) catch return null;
        return .{ .orchestrator_cmd = .{
            .kind = .cmd_end,
            .pid = pid,
            .payload = rest[semi + 1 ..],
        } };
    }
    return null;
},
```

**Note:** The exact API for accessing collected payload data and returning the command varies by how the existing parser works. Study the OSC 133 handler in `end()` for the exact pattern.

- [ ] **Step 6: Build to verify compilation**

Run: `/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell`
Expected: BUILD SUCCESS

- [ ] **Step 7: Commit**

```bash
git add src/terminal/osc.zig
git commit -m "feat(memory): register OSC 7337 state machine + parser for command tracking"
```

---

## Task 11: Surface OSC 7337 Event Handling

Handle parsed OSC 7337 events in the surface widget and forward them to the state manager.

**Files:**
- Modify: `src/apprt/gtk/class/surface.zig`
- Modify: `src/apprt/gtk/class/application.zig` (add forwarding method)

- [ ] **Step 1: Explore the surface OSC handler**

Read `src/apprt/gtk/class/surface.zig` and find where OSC commands are handled. Look for the callback that processes parsed OSC commands from the terminal core (e.g., `oscCallback`, `handleOsc`, or similar). Document the exact function name and how it accesses the application instance.

- [ ] **Step 2: Add OSC 7337 handler in surface**

In the surface's OSC handler, add a case for the new `orchestrator_cmd` variant:

```zig
.orchestrator_cmd => |cmd| {
    // Forward to application's state manager.
    // The surface knows its own UUID and workspace.
    const app = self.getApplication();
    if (app) |a| {
        a.handleMemoryCommandEvent(self, cmd);
    }
},
```

- [ ] **Step 3: Add forwarding method in application**

In `application.zig`, add a public method that the surface calls:

```zig
/// Handle a memory command event from a surface (triggered by OSC 7337).
pub fn handleMemoryCommandEvent(self: *Self, surface: *Surface, cmd: OrchestratorCmd) void {
    const priv = self.private();
    var mgr = &(priv.memory_manager orelse return);

    // Determine workspace name and dir for this surface
    const ws_info = self.getWorkspaceForSurface(surface) orelse return;

    const event = memory_state_mgr.CommandEvent{
        .kind = switch (cmd.kind) {
            .cmd_start => .start,
            .cmd_end => .end,
        },
        .surface_uuid = self.getSurfaceUuidString(surface) orelse return,
        .workspace_name = ws_info.name,
        .workspace_dir = ws_info.dir,
        .command = if (cmd.kind == .cmd_start) cmd.payload else null,
        .shell_pid = cmd.pid,
        .exit_code = if (cmd.kind == .cmd_end) std.fmt.parseInt(i32, cmd.payload, 10) catch null else null,
    };

    mgr.handleCommandEvent(event);
}
```

Note: The exact method to find which workspace a surface belongs to depends on the codebase. The implementer should trace how the existing session serialization finds the workspace for a surface (in `autosaveSession`/`appendSessionTabJson`).

- [ ] **Step 4: Build to verify compilation**

Run: `/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell`
Expected: BUILD SUCCESS

- [ ] **Step 5: Commit**

```bash
git add src/apprt/gtk/class/surface.zig src/apprt/gtk/class/application.zig
git commit -m "feat(memory): handle OSC 7337 events in surface, forward to state manager"
```

---

## Task 12: Application Integration — State Manager Initialization + Timers

Wire the state manager into the application lifecycle. This is the largest integration task — it connects everything.

**Files:**
- Modify: `src/apprt/gtk/class/application.zig`

- [ ] **Step 1: Add state manager import and field**

Near the top of `application.zig` where other termplex imports live, add:

```zig
const memory_state_mgr = @import("../../../termplex/core/memory/state_manager.zig");
const memory_paths = @import("../../../termplex/core/memory/paths.zig");
const memory_resume = @import("../../../termplex/core/memory/resume_manifest.zig");
const memory_state = @import("../../../termplex/core/memory/state.zig");
```

In the application's private data struct (search for `orchestration_workspace_idx` and `orchestration_launched`), add:

```zig
    /// Memory state manager for process tracking.
    memory_manager: ?memory_state_mgr.StateManager = null,
    /// GLib timer ID for debounced state saves (1s interval).
    memory_debounce_timer: c_uint = 0,
    /// GLib timer ID for periodic proc inspection.
    memory_proc_timer: c_uint = 0,
```

- [ ] **Step 2: Initialize state manager during startup**

In the application init function (search for where `termplex_cfg` is first used after loading), after orchestration config is available, add initialization:

```zig
// Initialize memory state manager if memory is enabled
if (priv.termplex_cfg.memory.enabled) {
    priv.memory_manager = memory_state_mgr.StateManager.init(
        alloc,
        priv.termplex_cfg.orchestration.dir,
    );
    // Try to load previous state
    _ = priv.memory_manager.?.loadFromDisk() catch |err| {
        log.warn("failed to load memory state: {}", .{err});
    };

    // Start debounce timer (1 second interval) for state persistence
    priv.memory_debounce_timer = glib.timeoutAdd(1000, &memoryDebounceSaveCallback, self);

    // Start proc inspection timer if configured
    const interval = priv.termplex_cfg.memory.proc_inspect_interval;
    if (interval > 0) {
        priv.memory_proc_timer = glib.timeoutAdd(interval * 1000, &memoryProcInspectCallback, self);
    }
}
```

Also add the GLib timer callback functions. These follow the existing pattern used by `autosaveCallback` (around line 3923 in application.zig). Add as private functions in the application class:

```zig
/// GLib timer callback: debounced save of memory state (fires every 1s).
/// Follows same pattern as autosaveCallback.
fn memoryDebounceSaveCallback(ud: ?*anyopaque) callconv(.c) c_int {
    const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
    const priv = self.private();
    if (priv.memory_manager) |*mgr| {
        mgr.debouncedSave();
    }
    return 1; // Return 1 to keep the timer running
}

/// GLib timer callback: periodic process inspection via /proc (fires every N seconds).
fn memoryProcInspectCallback(ud: ?*anyopaque) callconv(.c) c_int {
    const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
    const priv = self.private();
    var mgr = &(priv.memory_manager orelse return 1);

    // Iterate all surfaces, inspect shell children for those without recent shell hook events
    // This is the fallback detection — it fills in state for surfaces that don't have
    // shell integration loaded.
    // Implementation note: iterate workspace_tab_views to find surfaces,
    // get their shell PIDs, call process_inspector.inspectShellChildren(),
    // and update state via mgr.handleCommandEvent() with detection_method = .proc_inspection
    _ = mgr;

    return 1; // Return 1 to keep the timer running
}
```

- [ ] **Step 3: Add shutdown persistence to deinit**

In the application's `deinit()` function, before `priv.termplex_cfg.deinit()` (around line 760), add:

```zig
// Pre-shutdown memory flush: prompt orchestrator to save knowledge
if (priv.termplex_cfg.memory.flush_on_shutdown) {
    if (priv.orchestration_workspace_idx) |orch_idx| {
        // Write flush prompt to a file the orchestrator can detect,
        // or send it as input to the orchestrator terminal surface.
        // The orchestrator's system prompt tells it to check for this signal.
        const flush_prompt = "Session ending. Review what happened this session and write any durable knowledge to memory files. If nothing new was learned, do nothing.";
        const flush_path = std.fmt.allocPrint(alloc, "{s}/flush_prompt.txt", .{priv.termplex_cfg.orchestration.dir}) catch null;
        defer if (flush_path) |p| alloc.free(p);
        if (flush_path) |path| {
            const f = std.fs.createFileAbsolute(path, .{}) catch null;
            if (f) |file| {
                defer file.close();
                file.writeAll(flush_prompt) catch {};
            }
        }
        _ = orch_idx; // Used to identify which workspace is orchestrator
        // Note: For v1, the flush prompt is written as a file. In future,
        // this could be injected as terminal input to the orchestrator surface.
    }
}

// Persist memory state on shutdown
if (priv.memory_manager) |*mgr| {
    mgr.markShutdown();
    // Save per-workspace state.json files
    if (mgr.getState()) |state| {
        for (state.workspace_names) |ws_name| {
            mgr.saveWorkspaceState(ws_name) catch |err| {
                log.warn("failed to save workspace state for {s}: {}", .{ ws_name, err });
            };
        }
    }
    // Save global state.json
    mgr.saveToDisk() catch |err| {
        log.warn("failed to save memory state on shutdown: {}", .{err});
    };
    mgr.deinit();
    priv.memory_manager = null;
}
```

- [ ] **Step 4: Build to verify compilation**

Run: `/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell`
Expected: BUILD SUCCESS

- [ ] **Step 5: Commit**

```bash
git add src/apprt/gtk/class/application.zig
git commit -m "feat(memory): wire state manager into application lifecycle"
```

---

## Task 13: Application Integration — Resume Manifest Injection

Inject the resume manifest into the orchestrator workspace on startup.

**Files:**
- Modify: `src/apprt/gtk/class/application.zig`

- [ ] **Step 1: Build and inject resume manifest during restoreSession**

In `restoreSession()`, after the orchestration workspace is created (after `priv.orchestration_workspace_idx = idx;` around line 4216), add manifest building:

```zig
// Build resume manifest if memory is enabled and state exists
if (priv.memory_manager) |*mgr| {
    if (mgr.getState()) |mem_state| {
        // Read MEMORY.md
        var global_paths = memory_paths.resolveGlobalPaths(alloc, priv.termplex_cfg.orchestration.dir) catch null;
        defer if (global_paths) |*gp| gp.deinit(alloc);

        const global_memory = blk: {
            if (global_paths) |gp| {
                const f = std.fs.openFileAbsolute(gp.memory_md, .{}) catch break :blk "";
                defer f.close();
                break :blk f.readToEndAlloc(alloc, 1024 * 1024) catch "";
            }
            break :blk "";
        };
        defer if (global_memory.len > 0) alloc.free(global_memory);

        // Build workspace memory arrays
        var wm_names = std.ArrayList([]const u8).init(alloc);
        defer wm_names.deinit();
        var wm_contents = std.ArrayList([]const u8).init(alloc);
        defer {
            for (wm_contents.items) |c| if (c.len > 0) alloc.free(c);
            wm_contents.deinit();
        }

        for (mem_state.workspace_names, mem_state.workspaces) |ws_name, ws| {
            wm_names.append(ws_name) catch continue;
            const content = blk: {
                var wp = memory_paths.resolveWorkspacePaths(alloc, ws.dir) catch break :blk "";
                defer wp.deinit(alloc);
                const f = std.fs.openFileAbsolute(wp.memory_md, .{}) catch break :blk "";
                defer f.close();
                break :blk f.readToEndAlloc(alloc, 1024 * 1024) catch "";
            };
            wm_contents.append(content) catch continue;
        }

        const manifest = memory_resume.buildManifest(
            alloc,
            mem_state,
            global_memory,
            wm_names.items,
            wm_contents.items,
        ) catch null;
        defer if (manifest) |m| alloc.free(m);

        if (manifest) |m| {
            log.info("resume manifest built ({d} bytes)", .{m.len});
            // Write manifest to orchestration directory as resume_manifest.txt.
            // The orchestrator agent's system prompt instructs it to read this
            // file on startup from <orchestration_dir>/resume_manifest.txt.
            // This file is passed to the agent via the TERMPLEX_RESUME_MANIFEST
            // environment variable when launching the agent command.
            const manifest_path = std.fmt.allocPrint(alloc, "{s}/resume_manifest.txt", .{priv.termplex_cfg.orchestration.dir}) catch null;
            defer if (manifest_path) |p| alloc.free(p);
            if (manifest_path) |path| {
                try memory_paths.ensureDir(priv.termplex_cfg.orchestration.dir);
                const mf = std.fs.createFileAbsolute(path, .{}) catch null;
                if (mf) |f| {
                    defer f.close();
                    f.writeAll(m) catch {};
                    log.info("resume manifest written to {s}", .{path});
                }
                // Set environment variable so the orchestrator agent can find it.
                // Use POSIX setenv (std.process.setEnvVar does not exist in Zig 0.15.2).
                // The agent command is launched as a child process of the terminal,
                // which inherits this env var.
                const path_z = alloc.dupeZ(u8, path) catch null;
                defer if (path_z) |p| alloc.free(p);
                if (path_z) |pz| {
                    _ = std.c.setenv("TERMPLEX_RESUME_MANIFEST", pz.ptr, 1);
                }
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell`
Expected: BUILD SUCCESS

- [ ] **Step 3: Commit**

```bash
git add src/apprt/gtk/class/application.zig
git commit -m "feat(memory): inject resume manifest on orchestrator startup"
```

---

## Task 14: Integration Test — Full Build and Manual Verification

**Files:**
- All files from Tasks 1-13

- [ ] **Step 1: Run all unit tests**

Run: `/opt/zig-x86_64-linux-0.15.2/zig build test`
Expected: ALL PASS

- [ ] **Step 2: Run memory-specific tests**

Run: `/opt/zig-x86_64-linux-0.15.2/zig build test -Dtest-filter="memory"`
Expected: ALL PASS

Run: `/opt/zig-x86_64-linux-0.15.2/zig build test -Dtest-filter="state"`
Expected: ALL PASS

Run: `/opt/zig-x86_64-linux-0.15.2/zig build test -Dtest-filter="manifest"`
Expected: ALL PASS

Run: `/opt/zig-x86_64-linux-0.15.2/zig build test -Dtest-filter="resolve"`
Expected: ALL PASS

- [ ] **Step 3: Full build**

Run: `/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell`
Expected: BUILD SUCCESS

- [ ] **Step 4: Format entire project**

Run: `/opt/zig-x86_64-linux-0.15.2/zig fmt src/termplex/core/memory/`
Expected: No formatting changes (already formatted per-task)

- [ ] **Step 5: Final commit if any formatting changes**

```bash
git add -A
git status  # Verify only expected files
git commit -m "chore: format orchestrator memory modules"
```
