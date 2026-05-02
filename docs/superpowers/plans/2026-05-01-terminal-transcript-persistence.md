# Terminal Transcript Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore previous terminal output across Termplex restarts, T3Code-style, without preserving or resurrecting running processes.

**Architecture:** Add stable workspace IDs and per-surface history IDs, persist T3Code-style sanitized replayable PTY output into bounded per-terminal log files, and replay those logs into newly created terminal emulators during session restore before the new shell starts. Add a SQLite metadata and command-history store in phase 1 so future indexed command search, retention queries, cross-workspace history browsing, and richer joins have a stable backbone from the beginning. Keep process lifecycle unchanged: closing Termplex still stops the PTY process, and reopening starts a fresh shell with prior output visible above a restore marker.

**Tech Stack:** Zig 0.15.2, GTK4/libadwaita, existing Ghostty terminal core, XDG state files, SQLite/libsqlite3, JSON session restore, shell integration OSC 133/7337.

---

## Scope

This plan implements transcript continuity only. It intentionally excludes process continuity, daemon mode, tmux integration, background PTY ownership, and shell reattachment.

T3Code behaviors included:

- Per-logical-terminal persisted transcript files.
- Safe terminal/thread identifiers for filenames.
- Bounded history by line count and bytes.
- T3Code-parity sanitization: strip terminal replies and color query/reply sequences, track pending control sequences across chunks, and otherwise preserve normal terminal formatting/control bytes instead of adding a stricter allowlist.
- Coalesced disk writes with forced flush on shutdown.
- Snapshot-style restore: read transcript first, create fresh terminal, replay transcript into the terminal emulator only.
- Clear/delete history controls.
- Tests for history cap, sanitizer, migration, and restore.

Termplex-specific enhancements included:

- Stable workspace IDs and surface history IDs in session JSON.
- User-visible restore marker so old output is not confused with a live process.
- Developer-default transcript visibility: history restore is enabled by default, including sensitive terminal output, with clear/delete controls and local-only storage.
- Configurable restore modes for users who want layout-only or disabled transcript restore.
- SQLite-backed command-history metadata from existing OSC 133/7337 shell integration in phase 1.
- SQLite-backed project/workspace metadata in phase 1 so future global history, indexed search, retention queries, and source-control views have durable join keys.
- Retention cleanup for old transcript files.
- Lifecycle cleanup matching the T3Code behavior copied here: explicit terminal clear, terminal restart/fresh-shell reopen, cwd/env mismatch, exited/error reopen, and project deletion remove the affected persisted history. Normal tab close does not delete history.

T3Code practices intentionally adopted:

- Use a hybrid store: SQLite for durable app/orchestration metadata and searchable command records, plain capped transcript files for replayable terminal bytes.
- Keep terminal transcript replay simple: read a snapshot and write it into the terminal frontend/emulator before the new shell begins, never into the PTY.
- Preserve normal terminal formatting/control bytes and only strip the same terminal reply/color-query sequences T3Code strips. Termplex should not introduce a stricter sanitizer for this developer-productivity feature.
- Treat project/workspace deletion as an ownership boundary: deleting a project removes its transcript files and SQLite project/surface/command rows.
- Keep source-control and checkpoint diff UX as a separate follow-up plan, using the SQLite project metadata introduced here as its durable backbone.
- Keep T3Code-style version/update notification as a separate follow-up plan: in-app update state, explicit user-triggered download, no silent install, and AppImage-only self-download support in phase 1.

## File Structure

- Modify: `src/build/SharedDeps.zig`
  - Links `sqlite3` for GTK/runtime builds that include the terminal-history database module.
- Create: `src/termplex/core/terminal_history.zig`
  - Owns transcript paths, safe IDs, append/read/clear operations, caps, sanitization, pending escape-sequence handling, and retention cleanup.
- Create: `src/termplex/core/terminal_history_db.zig`
  - Owns SQLite open/close, schema migrations, project metadata upserts, surface metadata upserts, command start/end inserts, lifecycle deletion, retention queries, and recent-command reads.
- Modify: `src/termplex/core/config.zig`
  - Adds `[terminal_history]` config with defaults and parser tests.
- Modify: `src/termplex/core/session.zig`
  - Adds `workspace_id` to workspace data and `history_id` to `SurfaceData` so the core schema matches GTK session format.
- Modify: `src/apprt/gtk/class/surface.zig`
  - Adds stable `history_id`, replay payload storage, and accessors.
- Modify: `src/apprt/gtk/class/split_tree.zig`
  - Passes restored history ID and replay payload when creating restored split surfaces.
- Modify: `src/apprt/gtk/class/tab.zig`
  - Passes restored history ID and replay payload for the initial surface when needed.
- Modify: `src/apprt/gtk/class/window.zig`
  - Reads transcript logs for restored surfaces and passes replay data into `Surface.new`.
- Modify: `src/apprt/gtk/class/application.zig`
  - Upgrades session JSON to v6, saves stable `history_id`, restores v5 files by generating missing IDs, exposes clear-history actions, and starts retention cleanup.
- Modify: `src/termio/Options.zig`
  - Adds optional terminal history sink metadata and optional initial replay bytes.
- Modify: `src/termio/Termio.zig`
  - Replays transcript bytes into the emulator before backend startup, captures PTY output chunks, sanitizes/caps/persists, and flushes on deinit.
- Modify: `src/termio/Exec.zig`
  - Ensures final history flush happens after read-thread shutdown and before terminal teardown.
- Modify: `src/termplex/core/memory/state_manager.zig`
  - Keeps live surface/process state in JSON and forwards command start/end events to the SQLite command-history store.
- Modify: `src/termplex/core/memory/paths.zig`
  - Adds a global SQLite path helper for `$XDG_STATE_HOME/termplex/terminal-history/history.sqlite3`.
- Modify: `src/termplex/core/memory/resume_manifest.zig`
  - Reads recent commands from SQLite when generating the resume manifest.

## Data Model

Session JSON v6 adds a stable `workspace_id` to each workspace and a stable `history_id` to each surface:

```json
{
  "version": 6,
  "workspaces": [{
    "workspace_id": "4c6d7e45-e9b8-42d8-9a65-0ee8cd2d84ab",
    "name": "backend",
    "working_directory": "/home/user/project",
    "tabs": [{
      "surfaces": [{
        "id": "1bd69a49-a78d-4a3c-a3a8-8898dbd260a1",
        "history_id": "1bd69a49-a78d-4a3c-a3a8-8898dbd260a1",
        "working_directory": "/home/user/project",
        "custom_title": null
      }]
    }]
  }]
}
```

Transcript files live under XDG state by default:

```text
$XDG_STATE_HOME/termplex/terminal-history/<safe-workspace-id>/<safe-history-id>.ansi
```

Fallback when `XDG_STATE_HOME` is unset:

```text
$HOME/.local/state/termplex/terminal-history/<safe-workspace-id>/<safe-history-id>.ansi
```

SQLite metadata lives beside transcript files:

```text
$XDG_STATE_HOME/termplex/terminal-history/history.sqlite3
```

The SQLite store is phase-1 infrastructure. Transcript bytes stay in `.ansi` files for simple bounded replay, while SQLite stores searchable metadata and command records:

```sql
CREATE TABLE terminal_projects (
  workspace_id TEXT PRIMARY KEY,
  workspace_name TEXT NOT NULL,
  workspace_dir TEXT NOT NULL,
  git_remote_url TEXT,
  git_branch TEXT,
  git_dirty INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT
);

CREATE TABLE terminal_surfaces (
  history_id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL,
  workspace_name TEXT NOT NULL,
  workspace_dir TEXT NOT NULL,
  working_directory TEXT NOT NULL,
  env_fingerprint TEXT,
  transcript_path TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active',
  last_exit_code INTEGER,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT,
  FOREIGN KEY(workspace_id) REFERENCES terminal_projects(workspace_id)
);

CREATE TABLE command_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  history_id TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  workspace_name TEXT NOT NULL,
  workspace_dir TEXT NOT NULL,
  command TEXT NOT NULL,
  started_at TEXT NOT NULL,
  ended_at TEXT,
  exit_code INTEGER,
  source TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX idx_command_history_started_at
  ON command_history(started_at DESC);
CREATE INDEX idx_command_history_workspace_started
  ON command_history(workspace_id, started_at DESC);
CREATE INDEX idx_command_history_surface_started
  ON command_history(history_id, started_at DESC);
CREATE INDEX idx_terminal_projects_dir
  ON terminal_projects(workspace_dir);
CREATE INDEX idx_terminal_surfaces_workspace
  ON terminal_surfaces(workspace_id, updated_at DESC);
```

Project records are the durable app/orchestration rows. They are updated when a workspace is created/opened, when its working directory changes, and when the lightweight git probe refreshes branch/dirty/remote metadata. Deleting a workspace sets `deleted_at` and removes owned transcript files and terminal-surface/command rows.

Command records use this shape in Zig and SQLite:

```json
{
  "history_id": "1bd69a49-a78d-4a3c-a3a8-8898dbd260a1",
  "workspace_id": "4c6d7e45-e9b8-42d8-9a65-0ee8cd2d84ab",
  "workspace_name": "backend",
  "workspace_dir": "/home/user/backend",
  "command": "npm run dev",
  "started_at": "2026-05-01T10:20:30Z",
  "ended_at": "2026-05-01T10:21:04Z",
  "exit_code": 0,
  "source": "osc_7337"
}
```

## Task 1: Terminal History Core Module

**Files:**
- Create: `src/termplex/core/terminal_history.zig`
- Test: `src/termplex/core/terminal_history.zig`

- [ ] **Step 1: Write failing tests for safe IDs, path resolution, caps, sanitizer, and pending control sequences**

Add tests at the bottom of `src/termplex/core/terminal_history.zig` when creating the file:

```zig
test "terminal history safeId preserves safe chars and encodes unsafe chars" {
    const allocator = std.testing.allocator;
    const safe = try safeId(allocator, "workspace/main:default terminal");
    defer allocator.free(safe);
    try std.testing.expectEqualStrings("workspace_main_default_terminal", safe);
}

test "terminal history capLines keeps newest complete lines" {
    const allocator = std.testing.allocator;
    const capped = try capLines(allocator, "one\ntwo\nthree\nfour\n", 3);
    defer allocator.free(capped);
    try std.testing.expectEqualStrings("two\nthree\nfour\n", capped);
}

test "terminal history sanitizer mirrors T3Code terminal reply stripping" {
    var state = SanitizerState{};
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);

    try sanitizeChunk(
        std.testing.allocator,
        &state,
        "prompt \x1b[32mok\x1b[0m \x1b]11;rgb:ffff/ffff/ffff\x07\x1b[1;1Rdone\n",
        &out,
    );

    try std.testing.expectEqualStrings("prompt \x1b[32mok\x1b[0m done\n", out.items);
    try std.testing.expectEqual(@as(usize, 0), state.pending.items.len);
}

test "terminal history sanitizer carries incomplete control sequence" {
    var state = SanitizerState{};
    defer state.deinit(std.testing.allocator);
    var first: std.ArrayListUnmanaged(u8) = .empty;
    defer first.deinit(std.testing.allocator);
    var second: std.ArrayListUnmanaged(u8) = .empty;
    defer second.deinit(std.testing.allocator);

    try sanitizeChunk(std.testing.allocator, &state, "hello \x1b[", &first);
    try std.testing.expectEqualStrings("hello ", first.items);
    try std.testing.expect(state.pending.items.len > 0);

    try sanitizeChunk(std.testing.allocator, &state, "32mgreen\x1b[0m\n", &second);
    try std.testing.expectEqualStrings("\x1b[32mgreen\x1b[0m\n", second.items);
    try std.testing.expectEqual(@as(usize, 0), state.pending.items.len);
}
```

- [ ] **Step 2: Run tests and verify they fail because the module does not exist**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell -Dtest-filter="terminal history"
```

Expected: fail with unresolved file/symbol errors until implementation is added.

- [ ] **Step 3: Create the module with path, cap, and sanitizer functions**

Add `src/termplex/core/terminal_history.zig`:

```zig
const std = @import("std");

pub const Options = struct {
    enabled: bool = true,
    restore_mode: RestoreMode = .transcript,
    max_lines_per_surface: usize = 5000,
    max_bytes_per_surface: usize = 10 * 1024 * 1024,
    persist_alternate_screen: bool = false,
    replay_notice: bool = true,
    retention_days: u32 = 90,
};

pub const RestoreMode = enum {
    off,
    layout_only,
    transcript,
};

pub const SanitizerState = struct {
    pending: std.ArrayListUnmanaged(u8) = .empty,

    pub fn deinit(self: *SanitizerState, allocator: std.mem.Allocator) void {
        self.pending.deinit(allocator);
    }
};

pub fn safeId(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (input) |c| {
        const safe = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '.' or c == '-' or c == '_';
        try out.append(allocator, if (safe) c else '_');
    }
    if (out.items.len == 0) try out.appendSlice(allocator, "default");
    return out.toOwnedSlice(allocator);
}

pub fn getBaseDir(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_STATE_HOME")) |state_home| {
        defer allocator.free(state_home);
        return std.fs.path.join(allocator, &.{ state_home, "termplex", "terminal-history" });
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".local", "state", "termplex", "terminal-history" });
    } else |_| {}

    return error.NoHomeDir;
}

pub fn transcriptPath(
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
    history_id: []const u8,
) ![]u8 {
    const base = try getBaseDir(allocator);
    defer allocator.free(base);
    const safe_workspace = try safeId(allocator, workspace_id);
    defer allocator.free(safe_workspace);
    const safe_history = try safeId(allocator, history_id);
    defer allocator.free(safe_history);
    const file_name = try std.fmt.allocPrint(allocator, "{s}.ansi", .{safe_history});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ base, safe_workspace, file_name });
}

pub fn capLines(allocator: std.mem.Allocator, input: []const u8, max_lines: usize) ![]u8 {
    if (max_lines == 0 or input.len == 0) return allocator.dupe(u8, "");
    var count: usize = 0;
    var start: usize = input.len;
    var idx = input.len;
    while (idx > 0) {
        idx -= 1;
        if (input[idx] == '\n') {
            if (idx + 1 == input.len) continue;
            count += 1;
            if (count == max_lines) {
                start = idx + 1;
                break;
            }
        }
    }
    if (count < max_lines) start = 0;
    return allocator.dupe(u8, input[start..]);
}

fn isCsiFinalByte(c: u8) bool {
    return c >= 0x40 and c <= 0x7e;
}

fn shouldStripCsi(body: []const u8, final: u8) bool {
    if (final == 'n') return true;
    if (final == 'R') {
        for (body) |c| if (!std.ascii.isDigit(c) and c != ';' and c != '?') return false;
        return true;
    }
    if (final == 'c') return true;
    return false;
}

fn shouldStripOsc(content: []const u8) bool {
    return std.mem.startsWith(u8, content, "10;?") or
        std.mem.startsWith(u8, content, "10;rgb:") or
        std.mem.startsWith(u8, content, "11;?") or
        std.mem.startsWith(u8, content, "11;rgb:") or
        std.mem.startsWith(u8, content, "12;?") or
        std.mem.startsWith(u8, content, "12;rgb:");
}

pub fn sanitizeChunk(
    allocator: std.mem.Allocator,
    state: *SanitizerState,
    chunk: []const u8,
    out: *std.ArrayListUnmanaged(u8),
) !void {
    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(allocator);
    try input.appendSlice(allocator, state.pending.items);
    try input.appendSlice(allocator, chunk);
    state.pending.clearRetainingCapacity();

    var i: usize = 0;
    while (i < input.items.len) {
        if (input.items[i] != 0x1b) {
            try out.append(allocator, input.items[i]);
            i += 1;
            continue;
        }
        if (i + 1 >= input.items.len) {
            try state.pending.appendSlice(allocator, input.items[i..]);
            return;
        }

        const next = input.items[i + 1];
        if (next == '[') {
            var j = i + 2;
            while (j < input.items.len and !isCsiFinalByte(input.items[j])) : (j += 1) {}
            if (j >= input.items.len) {
                try state.pending.appendSlice(allocator, input.items[i..]);
                return;
            }
            const body = input.items[i + 2 .. j];
            const final = input.items[j];
            if (!shouldStripCsi(body, final)) try out.appendSlice(allocator, input.items[i .. j + 1]);
            i = j + 1;
            continue;
        }

        if (next == ']') {
            var j = i + 2;
            while (j < input.items.len and input.items[j] != 0x07) : (j += 1) {}
            if (j >= input.items.len) {
                try state.pending.appendSlice(allocator, input.items[i..]);
                return;
            }
            const content = input.items[i + 2 .. j];
            if (!shouldStripOsc(content)) try out.appendSlice(allocator, input.items[i .. j + 1]);
            i = j + 1;
            continue;
        }

        try out.appendSlice(allocator, input.items[i .. @min(i + 2, input.items.len)]);
        i += 2;
    }
}
```

- [ ] **Step 4: Run terminal history tests and verify they pass**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell -Dtest-filter="terminal history"
```

Expected: tests for `terminal_history.zig` pass.

- [ ] **Step 5: Commit**

```bash
git add src/termplex/core/terminal_history.zig
git commit -m "feat: add terminal transcript history core"
```

## Task 2: Terminal History Configuration

**Files:**
- Modify: `src/termplex/core/config.zig`
- Test: `src/termplex/core/config.zig`

- [ ] **Step 1: Write failing config parser tests**

Add tests near the existing memory/session config tests:

```zig
test "terminal history config defaults" {
    var cfg = TermplexConfig.default(std.testing.allocator);
    defer cfg.deinit();

    try std.testing.expectEqual(true, cfg.terminal_history.enabled);
    try std.testing.expectEqualStrings("transcript", cfg.terminal_history.restore_mode);
    try std.testing.expectEqual(@as(u32, 5000), cfg.terminal_history.max_lines_per_surface);
    try std.testing.expectEqual(@as(u64, 10 * 1024 * 1024), cfg.terminal_history.max_bytes_per_surface);
    try std.testing.expectEqual(false, cfg.terminal_history.persist_alternate_screen);
    try std.testing.expectEqual(true, cfg.terminal_history.replay_notice);
    try std.testing.expectEqual(@as(u32, 90), cfg.terminal_history.retention_days);
}

test "terminal history config parse" {
    const toml =
        \\[terminal_history]
        \\enabled = false
        \\restore_mode = "layout_only"
        \\max_lines_per_surface = 200
        \\max_bytes_per_surface = 1048576
        \\persist_alternate_screen = true
        \\replay_notice = false
        \\retention_days = 14
    ;
    var cfg = try parse(std.testing.allocator, toml);
    defer cfg.deinit();

    try std.testing.expectEqual(false, cfg.terminal_history.enabled);
    try std.testing.expectEqualStrings("layout_only", cfg.terminal_history.restore_mode);
    try std.testing.expectEqual(@as(u32, 200), cfg.terminal_history.max_lines_per_surface);
    try std.testing.expectEqual(@as(u64, 1048576), cfg.terminal_history.max_bytes_per_surface);
    try std.testing.expectEqual(true, cfg.terminal_history.persist_alternate_screen);
    try std.testing.expectEqual(false, cfg.terminal_history.replay_notice);
    try std.testing.expectEqual(@as(u32, 14), cfg.terminal_history.retention_days);
}
```

- [ ] **Step 2: Run config tests and verify failure**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell -Dtest-filter="terminal history config"
```

Expected: fail because `terminal_history` does not exist on `TermplexConfig`.

- [ ] **Step 3: Add config struct, defaults, deinit, clone, parser branch**

Add the struct next to `Memory`:

```zig
pub const TerminalHistory = struct {
    enabled: bool,
    restore_mode: []const u8,
    max_lines_per_surface: u32,
    max_bytes_per_surface: u64,
    persist_alternate_screen: bool,
    replay_notice: bool,
    retention_days: u32,
};
```

Add to `TermplexConfig`:

```zig
terminal_history: TerminalHistory,
```

Add defaults:

```zig
.terminal_history = .{
    .enabled = true,
    .restore_mode = "transcript",
    .max_lines_per_surface = 5000,
    .max_bytes_per_surface = 10 * 1024 * 1024,
    .persist_alternate_screen = false,
    .replay_notice = true,
    .retention_days = 90,
},
```

In owned config deinit, free `restore_mode` only when `_owned` is true:

```zig
self.allocator.free(self.terminal_history.restore_mode);
```

In parse setup, duplicate default string:

```zig
var th_restore_mode = try allocator.dupe(u8, cfg.terminal_history.restore_mode);
errdefer allocator.free(th_restore_mode);
```

Add parser branch:

```zig
} else if (std.mem.eql(u8, current_section, "terminal_history")) {
    if (std.mem.eql(u8, key, "enabled")) {
        cfg.terminal_history.enabled = parseBool(value) orelse cfg.terminal_history.enabled;
    } else if (std.mem.eql(u8, key, "restore_mode")) {
        const mode = unquote(value);
        if (std.mem.eql(u8, mode, "off") or
            std.mem.eql(u8, mode, "layout_only") or
            std.mem.eql(u8, mode, "transcript"))
        {
            allocator.free(th_restore_mode);
            th_restore_mode = try allocator.dupe(u8, mode);
        }
    } else if (std.mem.eql(u8, key, "max_lines_per_surface")) {
        cfg.terminal_history.max_lines_per_surface = std.fmt.parseInt(u32, value, 10) catch continue;
    } else if (std.mem.eql(u8, key, "max_bytes_per_surface")) {
        cfg.terminal_history.max_bytes_per_surface = std.fmt.parseInt(u64, value, 10) catch continue;
    } else if (std.mem.eql(u8, key, "persist_alternate_screen")) {
        cfg.terminal_history.persist_alternate_screen = parseBool(value) orelse cfg.terminal_history.persist_alternate_screen;
    } else if (std.mem.eql(u8, key, "replay_notice")) {
        cfg.terminal_history.replay_notice = parseBool(value) orelse cfg.terminal_history.replay_notice;
    } else if (std.mem.eql(u8, key, "retention_days")) {
        cfg.terminal_history.retention_days = std.fmt.parseInt(u32, value, 10) catch continue;
    }
```

Before returning parsed config:

```zig
cfg.terminal_history.restore_mode = th_restore_mode;
```

- [ ] **Step 4: Run config tests**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell -Dtest-filter="terminal history config"
```

Expected: config tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/termplex/core/config.zig
git commit -m "feat: add terminal history configuration"
```

## Task 3: Stable Surface History IDs

**Files:**
- Modify: `src/apprt/gtk/class/surface.zig`
- Modify: `src/apprt/gtk/class/split_tree.zig`
- Modify: `src/apprt/gtk/class/tab.zig`
- Modify: `src/apprt/gtk/class/window.zig`

- [ ] **Step 1: Add a focused test by building a small unit helper if direct GTK testing is not practical**

Create helper functions in `src/termplex/core/terminal_history.zig` if they do not exist yet:

```zig
pub fn isValidUuidLike(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return false;
            continue;
        }
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}
```

Add a test:

```zig
test "terminal history validates uuid-like ids" {
    try std.testing.expect(isValidUuidLike("1bd69a49-a78d-4a3c-a3a8-8898dbd260a1"));
    try std.testing.expect(!isValidUuidLike("shell-1234"));
}
```

- [ ] **Step 2: Add `history_id` and replay fields to `Surface.Private`**

In `src/apprt/gtk/class/surface.zig`, add imports:

```zig
const termplex_uuid = @import("../../../termplex/util/uuid.zig");
```

Add private fields:

```zig
history_id: ?[:0]const u8 = null,
initial_replay: ?[]const u8 = null,
```

Extend `overrides` in `Private` and `Surface.new`:

```zig
history_id: ?[:0]const u8 = null,
initial_replay: ?[]const u8 = null,
```

- [ ] **Step 3: Generate stable ID for new surfaces**

In `Surface.new`, after copying command and working directory:

```zig
if (overrides.history_id) |id| {
    priv.history_id = alloc.dupeZ(u8, id) catch null;
} else {
    var id_buf: [36]u8 = undefined;
    termplex_uuid.format(termplex_uuid.generate(), &id_buf);
    priv.history_id = alloc.dupeZ(u8, id_buf[0..]) catch null;
}
if (overrides.initial_replay) |bytes| {
    priv.initial_replay = alloc.dupe(u8, bytes) catch null;
}
```

Add accessors:

```zig
pub fn getHistoryId(self: *Self) ?[:0]const u8 {
    return self.private().history_id;
}

pub fn takeInitialReplay(self: *Self) ?[]const u8 {
    const priv = self.private();
    const replay = priv.initial_replay;
    priv.initial_replay = null;
    return replay;
}
```

Free fields in finalizer:

```zig
if (priv.history_id) |v| {
    Application.default().allocator().free(v);
    priv.history_id = null;
}
if (priv.initial_replay) |v| {
    Application.default().allocator().free(v);
    priv.initial_replay = null;
}
```

- [ ] **Step 4: Pass history fields through split/tab/window constructors**

Extend the override structs in `split_tree.zig`, `tab.zig`, and `window.zig` with:

```zig
history_id: ?[:0]const u8 = null,
initial_replay: ?[]const u8 = null,
```

When calling `Surface.new`, pass:

```zig
.history_id = overrides.history_id,
.initial_replay = overrides.initial_replay,
```

- [ ] **Step 5: Run build test for compile coverage**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell
```

Expected: compile succeeds and tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/apprt/gtk/class/surface.zig src/apprt/gtk/class/split_tree.zig src/apprt/gtk/class/tab.zig src/apprt/gtk/class/window.zig src/termplex/core/terminal_history.zig
git commit -m "feat: assign stable terminal history ids"
```

## Task 4: Session JSON v6 With Workspace And History IDs

**Files:**
- Modify: `src/termplex/core/session.zig`
- Modify: `src/apprt/gtk/class/application.zig`
- Modify: `src/apprt/gtk/class/window.zig`

- [ ] **Step 1: Write failing session tests**

In `src/termplex/core/session.zig`, add `workspace_id` to workspace tests and `history_id` to `SurfaceData` tests:

```zig
test "session data preserves workspace id and surface history id" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "version": 6,
        \\  "window": {"x":0,"y":0,"width":800,"height":600},
        \\  "sidebar_width": 200,
        \\  "active_workspace_index": 0,
        \\  "workspaces": [{
        \\    "workspace_id": "4c6d7e45-e9b8-42d8-9a65-0ee8cd2d84ab",
        \\    "name": "Project A",
        \\    "working_directory": "/home/user/project",
        \\    "active_tab_index": 0,
        \\    "tabs": [{
        \\      "title": null,
        \\      "focused_surface_id": "1bd69a49-a78d-4a3c-a3a8-8898dbd260a1",
        \\      "split_layout": {"type":"leaf","surface_id":"1bd69a49-a78d-4a3c-a3a8-8898dbd260a1"},
        \\      "surfaces": [{
        \\        "id": "1bd69a49-a78d-4a3c-a3a8-8898dbd260a1",
        \\        "history_id": "1bd69a49-a78d-4a3c-a3a8-8898dbd260a1",
        \\        "working_directory": "/home/user/project",
        \\        "custom_title": null
        \\      }]
        \\    }]
        \\  }]
        \\}
    ;
    var restored = try fromJson(allocator, json);
    defer restored.deinit(allocator);
    try std.testing.expectEqualStrings(
        "4c6d7e45-e9b8-42d8-9a65-0ee8cd2d84ab",
        restored.workspaces[0].workspace_id,
    );
    try std.testing.expectEqualStrings(
        "1bd69a49-a78d-4a3c-a3a8-8898dbd260a1",
        restored.workspaces[0].tabs[0].surfaces[0].history_id,
    );
}
```

- [ ] **Step 2: Update core session schema**

Change `WorkspaceData`:

```zig
pub const WorkspaceData = struct {
    workspace_id: []const u8,
    name: []const u8,
    working_directory: []const u8,
    active_tab_index: u32,
    tabs: []TabData,

    pub fn deinit(self: *WorkspaceData, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_id);
        allocator.free(self.name);
        allocator.free(self.working_directory);
        for (self.tabs) |*tab| tab.deinit(allocator);
        allocator.free(self.tabs);
    }
};
```

Change `SurfaceData`:

```zig
pub const SurfaceData = struct {
    id: []const u8,
    history_id: []const u8,
    working_directory: []const u8,
    custom_title: ?[]const u8,

    pub fn deinit(self: *SurfaceData, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.history_id);
        allocator.free(self.working_directory);
        if (self.custom_title) |t| allocator.free(t);
    }
};
```

Write/read `workspace_id` in `writeWorkspace`/`parseWorkspace`, and write/read `history_id` in `writeSurface`/`parseSurface`. For v5 and older session JSON, generate a fresh workspace UUID once during restore and keep it in memory for that restored workspace.

- [ ] **Step 3: Update GTK autosave to write v6 and stable IDs**

In `application.zig`, change version:

```zig
\\  "version": 6,
```

When serializing each workspace in `appendSessionWorkspaceJson`, write its existing UUID:

```zig
var workspace_id_buf: [36]u8 = undefined;
uuid.format(priv.workspace_ids.items[workspace_idx], &workspace_id_buf);
try buf.appendSlice(alloc, "\"workspace_id\":");
try appendJsonString(buf, alloc, workspace_id_buf[0..]);
```

In `appendSessionTabJson`, replace generated-only ID behavior with surface-owned history IDs:

```zig
try buf.appendSlice(alloc, ",\"history_id\":");
try appendJsonString(
    buf,
    alloc,
    if (entry.surface.getHistoryId()) |history_id| history_id else id_buf[0..],
);
```

Keep `id` and `history_id` equal for new surfaces. Support v5 restore by generating a missing workspace ID and using surface `id` as fallback history ID when `history_id` is absent.

- [ ] **Step 4: Update restore parser**

In `parseSessionWorkspaceData`, read or generate `workspace_id`:

```zig
const workspace_id = if (obj.get("workspace_id")) |workspace_id_val| blk: {
    if (workspace_id_val != .string) return error.InvalidArgument;
    break :blk try alloc.dupe(u8, workspace_id_val.string);
} else blk: {
    var id_buf: [36]u8 = undefined;
    uuid.format(uuid.generate(), &id_buf);
    break :blk try alloc.dupe(u8, id_buf[0..]);
};
errdefer alloc.free(workspace_id);
```

In `parseSessionSurfaceData`, read `history_id`:

```zig
const history_id = if (obj.get("history_id")) |history_id_val| blk: {
    if (history_id_val != .string) return error.InvalidArgument;
    break :blk try alloc.dupe(u8, history_id_val.string);
} else try alloc.dupe(u8, id);
errdefer alloc.free(history_id);
```

Return `workspace_id` in `WorkspaceData` and `history_id` in `SurfaceData`.

- [ ] **Step 5: Restore workspace UUIDs and pass restored history ID to surfaces**

When restoring workspaces in `application.zig`, append the parsed `workspace_id` to `priv.workspace_ids` instead of generating a new UUID for v6 sessions. For v5 and older sessions, use the generated fallback from Step 4.

In `window.zig` `buildRestoredSurfaceTree`, pass `surface_data.history_id` to `Surface.new`:

```zig
const history_id_z = self.allocZString(surface_data.history_id) orelse return error.OutOfMemory;
defer Application.default().allocator().free(history_id_z);

const surface = Surface.new(.{
    .working_directory = wd_z,
    .title = title_z,
    .history_id = history_id_z,
});
```

- [ ] **Step 6: Run session tests**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell -Dtest-filter="session"
```

Expected: session tests pass.

- [ ] **Step 7: Commit**

```bash
git add src/termplex/core/session.zig src/apprt/gtk/class/application.zig src/apprt/gtk/class/window.zig
git commit -m "feat: persist workspace and terminal history ids"
```

## Task 5: Persist PTY Output Transcripts

**Files:**
- Modify: `src/termio/Options.zig`
- Modify: `src/termio/Termio.zig`
- Modify: `src/termio/Exec.zig`
- Modify: `src/apprt/gtk/class/surface.zig`
- Modify: `src/termplex/core/terminal_history.zig`

- [ ] **Step 1: Add file append/read/clear tests**

In `terminal_history.zig`, add tests using `std.testing.tmpDir`:

```zig
test "terminal history append read and clear transcript" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);

    const path = try std.fs.path.join(allocator, &.{ base, "history.ansi" });
    defer allocator.free(path);

    try appendTranscript(allocator, path, "one\n", .{ .max_lines_per_surface = 5000 });
    try appendTranscript(allocator, path, "two\n", .{ .max_lines_per_surface = 5000 });

    const read = try readTranscript(allocator, path, .{ .max_lines_per_surface = 5000 });
    defer allocator.free(read);
    try std.testing.expectEqualStrings("one\ntwo\n", read);

    try clearTranscript(path);
    const cleared = try readTranscript(allocator, path, .{ .max_lines_per_surface = 5000 });
    defer allocator.free(cleared);
    try std.testing.expectEqualStrings("", cleared);
}
```

- [ ] **Step 2: Implement append/read/clear**

Add functions:

```zig
pub fn appendTranscript(
    allocator: std.mem.Allocator,
    path: []const u8,
    chunk: []const u8,
    options: Options,
) !void {
    if (!options.enabled or chunk.len == 0) return;
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try std.fs.makeDirAbsolute(parent);

    var existing: []u8 = std.fs.cwd().readFileAlloc(allocator, path, options.max_bytes_per_surface) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(existing);

    var combined = std.ArrayListUnmanaged(u8){};
    defer combined.deinit(allocator);
    try combined.appendSlice(allocator, existing);
    try combined.appendSlice(allocator, chunk);

    const capped_lines = try capLines(allocator, combined.items, options.max_lines_per_surface);
    defer allocator.free(capped_lines);
    const start = if (capped_lines.len > options.max_bytes_per_surface)
        capped_lines.len - options.max_bytes_per_surface
    else
        0;

    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = capped_lines[start..] });
}

pub fn readTranscript(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: Options,
) ![]u8 {
    if (!options.enabled or options.restore_mode != .transcript) return allocator.dupe(u8, "");
    const raw = std.fs.cwd().readFileAlloc(allocator, path, options.max_bytes_per_surface) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, ""),
        else => return err,
    };
    errdefer allocator.free(raw);
    return raw;
}

pub fn clearTranscript(path: []const u8) !void {
    std.fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}
```

- [ ] **Step 3: Add optional history context to Termio options**

In `src/termio/Options.zig`:

```zig
pub const History = struct {
    workspace_id: []const u8,
    history_id: []const u8,
    initial_replay: []const u8 = "",
};

history: ?History = null,
```

- [ ] **Step 4: Add Termio history fields**

In `src/termio/Termio.zig`:

```zig
const terminal_history = @import("../termplex/core/terminal_history.zig");

history_path: ?[]const u8 = null,
history_options: terminal_history.Options = .{},
history_sanitizer: terminal_history.SanitizerState = .{},
```

In `Termio.init`, when `opts.history` is set, compute and store `history_path`.

- [ ] **Step 5: Capture output in `processOutputLocked`**

Before `self.terminal_stream.nextSlice(buf)`, sanitize and append:

```zig
if (self.history_path) |path| {
    var visible: std.ArrayListUnmanaged(u8) = .empty;
    defer visible.deinit(self.alloc);
    terminal_history.sanitizeChunk(self.alloc, &self.history_sanitizer, buf, &visible) catch |err| {
        log.warn("terminal history sanitize failed: {}", .{err});
    };
    if (visible.items.len > 0) {
        terminal_history.appendTranscript(
            self.alloc,
            path,
            visible.items,
            self.history_options,
        ) catch |err| {
            log.warn("terminal history persist failed: {}", .{err});
        };
    }
}
```

This first implementation writes synchronously so the capture path is easy to verify. Task 6 replaces the direct write with a coalescing writer before the feature is considered ready.

- [ ] **Step 6: Free history state**

In `Termio.deinit`:

```zig
if (self.history_path) |path| self.alloc.free(path);
self.history_sanitizer.deinit(self.alloc);
```

- [ ] **Step 7: Wire surface history context into CoreSurface creation**

In `surface.zig`, where the `CoreSurface`/Termio options are built, pass:

```zig
const workspace_id_owned = Application.default().currentWorkspaceIdString(alloc) catch null;
defer if (workspace_id_owned) |v| alloc.free(v);

.history = if (priv.history_id) |history_id| .{
    .workspace_id = workspace_id_owned orelse "default",
    .history_id = history_id,
    .initial_replay = priv.initial_replay orelse "",
} else null,
```

Add `currentWorkspaceIdString(allocator)` and `workspaceIdString(allocator, idx)` helpers to `application.zig`; both format the stored workspace UUID with `uuid.format`. Ensure the `Termio`/`CoreSurface` options path duplicates `workspace_id` before `workspace_id_owned` is freed.

- [ ] **Step 8: Run tests**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell -Dtest-filter="terminal history"
/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell
```

Expected: terminal history tests pass, full test build passes.

- [ ] **Step 9: Commit**

```bash
git add src/termplex/core/terminal_history.zig src/termio/Options.zig src/termio/Termio.zig src/termio/Exec.zig src/apprt/gtk/class/surface.zig src/apprt/gtk/class/application.zig
git commit -m "feat: persist terminal transcripts"
```

## Task 6: Coalesced Transcript Persistence

**Files:**
- Modify: `src/termplex/core/terminal_history.zig`
- Modify: `src/termio/Termio.zig`

- [ ] **Step 1: Add writer tests for coalescing**

Add a `TranscriptWriter` to `terminal_history.zig` and test:

```zig
test "terminal transcript writer coalesces pending chunks" {
    var writer = TranscriptWriter.init(std.testing.allocator, "/tmp/termplex-test.ansi", .{});
    defer writer.deinit();

    try writer.queue("one\n");
    try writer.queue("two\n");
    try std.testing.expectEqualStrings("one\ntwo\n", writer.pending.items);
}
```

- [ ] **Step 2: Implement a small in-process writer**

Add:

```zig
pub const TranscriptWriter = struct {
    const default_flush_interval_ns: i128 = 40 * std.time.ns_per_ms;
    const default_max_pending_bytes: usize = 64 * 1024;

    allocator: std.mem.Allocator,
    path: []const u8,
    options: Options,
    flush_interval_ns: i128 = default_flush_interval_ns,
    max_pending_bytes: usize = default_max_pending_bytes,
    last_flush_ns: i128 = 0,
    pending: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, options: Options) TranscriptWriter {
        return .{
            .allocator = allocator,
            .path = path,
            .options = options,
            .last_flush_ns = std.time.nanoTimestamp(),
        };
    }

    pub fn deinit(self: *TranscriptWriter) void {
        self.pending.deinit(self.allocator);
    }

    pub fn queue(self: *TranscriptWriter, chunk: []const u8) !void {
        try self.pending.appendSlice(self.allocator, chunk);
    }

    pub fn shouldFlush(self: *const TranscriptWriter, now_ns: i128) bool {
        return self.pending.items.len >= self.max_pending_bytes or
            now_ns - self.last_flush_ns >= self.flush_interval_ns;
    }

    pub fn flush(self: *TranscriptWriter) !void {
        if (self.pending.items.len == 0) return;
        try appendTranscript(self.allocator, self.path, self.pending.items, self.options);
        self.pending.clearRetainingCapacity();
        self.last_flush_ns = std.time.nanoTimestamp();
    }
};
```

- [ ] **Step 3: Replace synchronous writes with queued writes**

In `Termio`, store:

```zig
history_writer: ?terminal_history.TranscriptWriter = null,
```

Initialize it when `history_path` exists. Replace `appendTranscript` in `processOutputLocked` with:

```zig
if (self.history_writer) |*writer| {
    writer.queue(visible.items) catch |err| {
        log.warn("terminal history queue failed: {}", .{err});
    };
    if (writer.shouldFlush(std.time.nanoTimestamp())) {
        writer.flush() catch |err| {
            log.warn("terminal history coalesced flush failed: {}", .{err});
        };
    }
}
```

- [ ] **Step 4: Flush on deinit and command exit paths**

In `Termio.deinit`:

```zig
if (self.history_writer) |*writer| {
    writer.flush() catch |err| log.warn("terminal history final flush failed: {}", .{err});
    writer.deinit();
}
```

This version coalesces frequent output and caps disk-write frequency to roughly T3Code's 40ms persistence cadence while still guaranteeing the final transcript is written before teardown.

- [ ] **Step 5: Run tests**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell -Dtest-filter="terminal transcript writer"
/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell
```

Expected: tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/termplex/core/terminal_history.zig src/termio/Termio.zig
git commit -m "perf: coalesce terminal transcript writes"
```

## Task 7: Replay Transcript On Session Restore

**Files:**
- Modify: `src/apprt/gtk/class/window.zig`
- Modify: `src/apprt/gtk/class/application.zig`
- Modify: `src/apprt/gtk/class/surface.zig`
- Modify: `src/termio/Termio.zig`

- [ ] **Step 1: Add replay behavior in Termio**

In `Termio.init`, after `self.* = .{ ... }` and before backend thread starts, replay:

```zig
if (opts.history) |history| {
    if (history.initial_replay.len > 0) {
        self.processOutputLocked(history.initial_replay);
        if (self.history_options.replay_notice) {
            self.terminal.printString("\r\n[Termplex restored previous terminal output. New shell starts below.]\r\n") catch {};
        }
    }
}
```

Do not send `initial_replay` to `queueWrite`, `backend.queueWrite`, or any PTY write path.

- [ ] **Step 2: Read transcript in restore path**

In `window.zig` `buildRestoredSurfaceTree`, pass the workspace index into the restore helper if it is not already available. Before `Surface.new`, compute transcript path from the stable workspace UUID and read bytes:

```zig
const replay_bytes = blk: {
    const workspace_id = Application.default().workspaceIdString(alloc, workspace_idx) catch break :blk null;
    defer alloc.free(workspace_id);
    const path = terminal_history.transcriptPath(alloc, workspace_id, surface_data.history_id) catch break :blk null;
    defer alloc.free(path);
    break :blk terminal_history.readTranscript(alloc, path, Application.default().terminalHistoryOptions()) catch null;
};
defer if (replay_bytes) |bytes| alloc.free(bytes);
```

Pass:

```zig
.initial_replay = replay_bytes,
```

- [ ] **Step 3: Add Application helpers**

In `application.zig`, add:

```zig
pub fn terminalHistoryOptions(self: *Self) terminal_history.Options {
    const cfg = self.private().termplex_cfg.terminal_history;
    return .{
        .enabled = cfg.enabled,
        .restore_mode = if (std.mem.eql(u8, cfg.restore_mode, "off"))
            .off
        else if (std.mem.eql(u8, cfg.restore_mode, "layout_only"))
            .layout_only
        else
            .transcript,
        .max_lines_per_surface = cfg.max_lines_per_surface,
        .max_bytes_per_surface = @intCast(cfg.max_bytes_per_surface),
        .persist_alternate_screen = cfg.persist_alternate_screen,
        .replay_notice = cfg.replay_notice,
        .retention_days = cfg.retention_days,
    };
}
```

Add a workspace name helper:

```zig
pub fn workspaceName(self: *Self, idx: u32) ?[]const u8 {
    const priv = self.private();
    if (idx >= priv.workspace_names.items.len) return null;
    return priv.workspace_names.items[idx];
}
```

Add workspace ID string helpers:

```zig
pub fn workspaceIdString(self: *Self, allocator: std.mem.Allocator, idx: u32) ![]u8 {
    const workspace_id = self.workspaceUuid(idx) orelse return error.NotFound;
    var buf: [36]u8 = undefined;
    uuid.format(workspace_id, &buf);
    return allocator.dupe(u8, buf[0..]);
}

pub fn currentWorkspaceIdString(self: *Self, allocator: std.mem.Allocator) ![]u8 {
    return self.workspaceIdString(allocator, self.private().active_workspace_idx);
}
```

- [ ] **Step 4: Run tests and a manual app smoke test**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

Manual smoke:

```bash
./zig-out/bin/termplex-app
```

In the app:

1. Run `printf 'persist-one\npersist-two\n'`.
2. Close Termplex.
3. Reopen Termplex.
4. Confirm prior output is visible and a new shell prompt appears below the restore marker.

- [ ] **Step 5: Commit**

```bash
git add src/apprt/gtk/class/window.zig src/apprt/gtk/class/application.zig src/apprt/gtk/class/surface.zig src/termio/Termio.zig
git commit -m "feat: replay terminal transcripts on restore"
```

## Task 8: Clear History, Lifecycle Cleanup, And Restore Mode UX

**Files:**
- Modify: `src/apprt/gtk/class/application.zig`
- Modify: `src/apprt/gtk/class/window.zig`
- Modify: `src/apprt/gtk/class/surface.zig`
- Modify: `src/termplex/core/terminal_history.zig`
- Modify: `src/termio/Options.zig`
- Modify: `src/termio/Termio.zig`

- [ ] **Step 1: Add lifecycle policy tests and clear helpers**

In `terminal_history.zig`, add tests:

```zig
test "terminal history lifecycle deletion policy" {
    try std.testing.expect(shouldDeleteForLifecycle(.explicit_clear));
    try std.testing.expect(shouldDeleteForLifecycle(.restart));
    try std.testing.expect(shouldDeleteForLifecycle(.cwd_changed));
    try std.testing.expect(shouldDeleteForLifecycle(.env_changed));
    try std.testing.expect(shouldDeleteForLifecycle(.exited_reopen));
    try std.testing.expect(shouldDeleteForLifecycle(.error_reopen));
    try std.testing.expect(shouldDeleteForLifecycle(.workspace_deleted));
    try std.testing.expect(!shouldDeleteForLifecycle(.normal_close));
}
```

Add:

```zig
pub const LifecycleReason = enum {
    explicit_clear,
    restart,
    cwd_changed,
    env_changed,
    exited_reopen,
    error_reopen,
    workspace_deleted,
    normal_close,
};

pub fn shouldDeleteForLifecycle(reason: LifecycleReason) bool {
    return switch (reason) {
        .explicit_clear,
        .restart,
        .cwd_changed,
        .env_changed,
        .exited_reopen,
        .error_reopen,
        .workspace_deleted,
        => true,
        .normal_close => false,
    };
}

pub fn clearSurfaceHistory(
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
    history_id: []const u8,
) !void {
    const path = try transcriptPath(allocator, workspace_id, history_id);
    defer allocator.free(path);
    try clearTranscript(path);
}

pub fn clearWorkspaceHistory(
    allocator: std.mem.Allocator,
    workspace_id: []const u8,
) !void {
    const base = try getBaseDir(allocator);
    defer allocator.free(base);
    const safe_workspace = try safeId(allocator, workspace_id);
    defer allocator.free(safe_workspace);
    const dir_path = try std.fs.path.join(allocator, &.{ base, safe_workspace });
    defer allocator.free(dir_path);
    std.fs.deleteTreeAbsolute(dir_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}
```

- [ ] **Step 2: Add app action for active surface history**

In `application.zig`, add an action named `clear-terminal-history`:

```zig
fn actionClearTerminalHistory(self: *Self, _: *gio.SimpleAction, _: ?*glib.Variant) void {
    const active_surface = self.activeSurface() orelse return;
    const history_id = active_surface.getHistoryId() orelse return;
    const workspace_id = self.currentWorkspaceIdString(self.allocator()) catch null;
    defer if (workspace_id) |v| self.allocator().free(v);
    terminal_history.clearSurfaceHistory(self.allocator(), workspace_id orelse "default", history_id) catch |err| {
        log.warn("failed to clear terminal history: {}", .{err});
    };
    if (active_surface.core()) |core| {
        _ = core.performBindingAction(.{ .clear_screen = .{ .history = true } }) catch {};
    }
}
```

If `activeSurface()` does not exist, add it by reading the active workspace TabView, selected page, cast to `Tab`, and return `tab.getActiveSurface()`.

- [ ] **Step 3: Clear history on T3Code-parity fresh-shell lifecycle cases**

Add a small history context to `termio/Options.zig` so a surface can compare restored/opened context before it starts a new shell:

```zig
pub const History = struct {
    workspace_id: []const u8,
    history_id: []const u8,
    working_directory: []const u8,
    env_fingerprint: ?[]const u8 = null,
    initial_replay: []const u8 = "",
};
```

In `Surface.new`, compute `env_fingerprint` from the environment values Termplex passes into `Termio`. A deterministic hash string is enough in phase 1; it should not store the full environment because command/transcript visibility is accepted, but broad env snapshots add little value and make churn noisy.

Before starting a fresh backend in an existing logical surface, call a helper like:

```zig
fn maybeClearHistoryForFreshShell(
    self: *Self,
    reason: terminal_history.LifecycleReason,
) void {
    if (!terminal_history.shouldDeleteForLifecycle(reason)) return;
    const history_id = self.getHistoryId() orelse return;
    const allocator = Application.default().allocator();
    const workspace_id = Application.default().currentWorkspaceIdString(allocator) catch null;
    defer if (workspace_id) |v| allocator.free(v);
    terminal_history.clearSurfaceHistory(allocator, workspace_id orelse "default", history_id) catch |err| {
        log.warn("failed to clear terminal history for lifecycle {s}: {}", .{ @tagName(reason), err });
    };
}
```

Use that helper in these paths:

- Explicit terminal clear action: `.explicit_clear`.
- Any terminal restart or fresh-shell action that keeps the same surface identity: `.restart`.
- Reopen/restart with a different working directory than the stored `terminal_surfaces.working_directory`: `.cwd_changed`.
- Reopen/restart with a different `env_fingerprint`: `.env_changed`.
- Reopen a surface after normal process exit: `.exited_reopen`.
- Reopen a surface after failed process start or error state: `.error_reopen`.

Do not clear history on normal tab close. T3Code has explicit deletion/lifecycle deletion; Termplex should follow the same rule to avoid surprising data loss when a developer closes a tab and reopens the project later.

Task 10 adds the matching SQLite row deletion once `terminal_history_db.zig` exists.

- [ ] **Step 4: Delete project-owned history when a workspace/project is deleted**

In `application.zig` `removeWorkspace`, capture `workspace_id`, `workspace_name`, and `workspace_dir` before removing the workspace arrays. Then delete owned transcript files:

```zig
var workspace_id_buf: [36]u8 = undefined;
uuid.format(workspace_id, &workspace_id_buf);
const workspace_id_str = workspace_id_buf[0..];

terminal_history.clearWorkspaceHistory(self.allocator(), workspace_id_str) catch |err| {
    log.warn("failed to clear terminal history for deleted workspace {s}: {}", .{ workspace_name, err });
};
```

Use the same central `removeWorkspace` path for sidebar deletion, IPC workspace close/delete, and any future project-delete command so transcript cleanup is not duplicated across UI entry points.

- [ ] **Step 5: Run compile tests**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell
```

Expected: compile and tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/apprt/gtk/class/application.zig src/apprt/gtk/class/window.zig src/apprt/gtk/class/surface.zig src/termplex/core/terminal_history.zig src/termio/Options.zig src/termio/Termio.zig
git commit -m "feat: add terminal history lifecycle cleanup"
```

## Task 9: SQLite Command History Backbone

**Files:**
- Modify: `src/build/SharedDeps.zig`
- Modify: `src/termplex/core/terminal_history.zig`
- Create: `src/termplex/core/terminal_history_db.zig`
- Modify: `src/termplex/core/memory/paths.zig`
- Modify: `src/termplex/core/memory/state_manager.zig`
- Modify: `src/termplex/core/memory/resume_manifest.zig`
- Modify: `src/apprt/gtk/class/application.zig`

- [ ] **Step 1: Link SQLite**

In `src/build/SharedDeps.zig`, add the system SQLite dependency near the other runtime system libraries:

```zig
// SQLite backs terminal history metadata and command indexes.
step.linkSystemLibrary2("sqlite3", dynamic_link_opts);
```

- [ ] **Step 2: Add DB path helper**

In `terminal_history.zig`, add:

```zig
pub fn databasePath(allocator: std.mem.Allocator) ![]u8 {
    const base = try getBaseDir(allocator);
    defer allocator.free(base);
    return std.fs.path.join(allocator, &.{ base, "history.sqlite3" });
}
```

In `memory/paths.zig`, expose the same path for callers already working with memory paths:

```zig
pub fn resolveTerminalHistoryDatabasePath(allocator: std.mem.Allocator) ![]const u8 {
    const terminal_history = @import("../terminal_history.zig");
    return terminal_history.databasePath(allocator);
}
```

- [ ] **Step 3: Write failing SQLite tests**

At the bottom of `src/termplex/core/terminal_history_db.zig`, add:

```zig
test "terminal history db migrates and records command lifecycle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const db_path = try std.fs.path.join(allocator, &.{ base, "history.sqlite3" });
    defer allocator.free(db_path);

    var db = try Database.open(allocator, db_path);
    defer db.deinit();
    try db.migrate();

    try db.upsertProject(.{
        .workspace_id = "workspace-1",
        .workspace_name = "backend",
        .workspace_dir = "/home/user/backend",
        .git_remote_url = "git@github.com:example/backend.git",
        .git_branch = "main",
        .git_dirty = true,
        .timestamp = "2026-05-01T10:00:00Z",
    });

    try db.upsertSurface(.{
        .history_id = "hist-1",
        .workspace_id = "workspace-1",
        .workspace_name = "backend",
        .workspace_dir = "/home/user/backend",
        .working_directory = "/home/user/backend",
        .env_fingerprint = "env-1",
        .transcript_path = "/tmp/hist-1.ansi",
        .status = "active",
        .last_exit_code = null,
        .timestamp = "2026-05-01T10:00:00Z",
    });

    _ = try db.startCommand(.{
        .history_id = "hist-1",
        .workspace_id = "workspace-1",
        .workspace_name = "backend",
        .workspace_dir = "/home/user/backend",
        .command = "npm test",
        .started_at = "2026-05-01T10:00:01Z",
        .source = "osc_7337",
    });
    try db.finishLatestCommand(.{
        .history_id = "hist-1",
        .ended_at = "2026-05-01T10:00:05Z",
        .exit_code = 0,
    });

    const recent = try db.listRecentCommands(.{ .limit = 10 });
    defer recent.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), recent.items.len);
    try std.testing.expectEqualStrings("npm test", recent.items[0].command);
    try std.testing.expectEqual(@as(?i32, 0), recent.items[0].exit_code);

    var project = try db.getProject("workspace-1");
    defer project.deinit(allocator);
    try std.testing.expectEqualStrings("backend", project.workspace_name);
    try std.testing.expectEqual(true, project.git_dirty);
}
```

- [ ] **Step 4: Implement the SQLite wrapper and schema**

Create `src/termplex/core/terminal_history_db.zig`:

```zig
const std = @import("std");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const ProjectUpsert = struct {
    workspace_id: []const u8,
    workspace_name: []const u8,
    workspace_dir: []const u8,
    git_remote_url: ?[]const u8 = null,
    git_branch: ?[]const u8 = null,
    git_dirty: bool = false,
    timestamp: []const u8,
};

pub const ProjectRecord = struct {
    workspace_id: []const u8,
    workspace_name: []const u8,
    workspace_dir: []const u8,
    git_remote_url: ?[]const u8,
    git_branch: ?[]const u8,
    git_dirty: bool,
    updated_at: []const u8,

    pub fn deinit(self: *ProjectRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_id);
        allocator.free(self.workspace_name);
        allocator.free(self.workspace_dir);
        if (self.git_remote_url) |v| allocator.free(v);
        if (self.git_branch) |v| allocator.free(v);
        allocator.free(self.updated_at);
    }
};

pub const SurfaceUpsert = struct {
    history_id: []const u8,
    workspace_id: []const u8,
    workspace_name: []const u8,
    workspace_dir: []const u8,
    working_directory: []const u8,
    env_fingerprint: ?[]const u8 = null,
    transcript_path: []const u8,
    status: []const u8 = "active",
    last_exit_code: ?i32 = null,
    timestamp: []const u8,
};

pub const CommandStart = struct {
    history_id: []const u8,
    workspace_id: []const u8,
    workspace_name: []const u8,
    workspace_dir: []const u8,
    command: []const u8,
    started_at: []const u8,
    source: []const u8,
};

pub const CommandFinish = struct {
    history_id: []const u8,
    ended_at: []const u8,
    exit_code: ?i32,
};

pub const CommandRecord = struct {
    id: i64,
    history_id: []const u8,
    workspace_id: []const u8,
    workspace_name: []const u8,
    workspace_dir: []const u8,
    command: []const u8,
    started_at: []const u8,
    ended_at: ?[]const u8,
    exit_code: ?i32,
    source: []const u8,

    pub fn deinit(self: *CommandRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.history_id);
        allocator.free(self.workspace_id);
        allocator.free(self.workspace_name);
        allocator.free(self.workspace_dir);
        allocator.free(self.command);
        allocator.free(self.started_at);
        if (self.ended_at) |v| allocator.free(v);
        allocator.free(self.source);
    }
};

pub const CommandList = struct {
    items: []CommandRecord,

    pub fn deinit(self: CommandList, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const RecentQuery = struct {
    limit: u32 = 20,
    workspace_id: ?[]const u8 = null,
    history_id: ?[]const u8 = null,
};

pub const Database = struct {
    allocator: std.mem.Allocator,
    handle: *c.sqlite3,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Database {
        const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
        std.fs.makeDirAbsolute(parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        var handle: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;
        if (c.sqlite3_open_v2(path_z.ptr, &handle, flags, null) != c.SQLITE_OK) {
            if (handle) |h| _ = c.sqlite3_close(h);
            return error.OpenFailed;
        }
        return .{ .allocator = allocator, .handle = handle.? };
    }

    pub fn deinit(self: *Database) void {
        _ = c.sqlite3_close(self.handle);
    }

    fn exec(self: *Database, sql: [:0]const u8) !void {
        var err_msg: [*c]u8 = null;
        defer if (err_msg != null) c.sqlite3_free(err_msg);
        if (c.sqlite3_exec(self.handle, sql.ptr, null, null, &err_msg) != c.SQLITE_OK) {
            return error.SqlExecFailed;
        }
    }

    pub fn migrate(self: *Database) !void {
        try self.exec(
            \\PRAGMA journal_mode = WAL;
            \\PRAGMA foreign_keys = ON;
            \\PRAGMA busy_timeout = 250;
            \\CREATE TABLE IF NOT EXISTS schema_migrations (
            \\  version INTEGER PRIMARY KEY,
            \\  applied_at TEXT NOT NULL
            \\);
            \\CREATE TABLE IF NOT EXISTS terminal_projects (
            \\  workspace_id TEXT PRIMARY KEY,
            \\  workspace_name TEXT NOT NULL,
            \\  workspace_dir TEXT NOT NULL,
            \\  git_remote_url TEXT,
            \\  git_branch TEXT,
            \\  git_dirty INTEGER NOT NULL DEFAULT 0,
            \\  created_at TEXT NOT NULL,
            \\  updated_at TEXT NOT NULL,
            \\  deleted_at TEXT
            \\);
            \\CREATE TABLE IF NOT EXISTS terminal_surfaces (
            \\  history_id TEXT PRIMARY KEY,
            \\  workspace_id TEXT NOT NULL,
            \\  workspace_name TEXT NOT NULL,
            \\  workspace_dir TEXT NOT NULL,
            \\  working_directory TEXT NOT NULL,
            \\  env_fingerprint TEXT,
            \\  transcript_path TEXT NOT NULL,
            \\  status TEXT NOT NULL DEFAULT 'active',
            \\  last_exit_code INTEGER,
            \\  created_at TEXT NOT NULL,
            \\  updated_at TEXT NOT NULL,
            \\  deleted_at TEXT,
            \\  FOREIGN KEY(workspace_id) REFERENCES terminal_projects(workspace_id)
            \\);
            \\CREATE TABLE IF NOT EXISTS command_history (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  history_id TEXT NOT NULL,
            \\  workspace_id TEXT NOT NULL,
            \\  workspace_name TEXT NOT NULL,
            \\  workspace_dir TEXT NOT NULL,
            \\  command TEXT NOT NULL,
            \\  started_at TEXT NOT NULL,
            \\  ended_at TEXT,
            \\  exit_code INTEGER,
            \\  source TEXT NOT NULL,
            \\  created_at TEXT NOT NULL,
            \\  updated_at TEXT NOT NULL
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_command_history_started_at
            \\  ON command_history(started_at DESC);
            \\CREATE INDEX IF NOT EXISTS idx_command_history_workspace_started
            \\  ON command_history(workspace_id, started_at DESC);
            \\CREATE INDEX IF NOT EXISTS idx_command_history_surface_started
            \\  ON command_history(history_id, started_at DESC);
            \\CREATE INDEX IF NOT EXISTS idx_terminal_projects_dir
            \\  ON terminal_projects(workspace_dir);
            \\CREATE INDEX IF NOT EXISTS idx_terminal_surfaces_workspace
            \\  ON terminal_surfaces(workspace_id, updated_at DESC);
            \\INSERT OR IGNORE INTO schema_migrations(version, applied_at)
            \\VALUES (1, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
        );
    }

    pub fn upsertProject(self: *Database, input: ProjectUpsert) !void {
        var stmt = try self.prepare(
            \\INSERT INTO terminal_projects (
            \\  workspace_id, workspace_name, workspace_dir, git_remote_url, git_branch,
            \\  git_dirty, created_at, updated_at, deleted_at
            \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)
            \\ON CONFLICT(workspace_id) DO UPDATE SET
            \\  workspace_name = excluded.workspace_name,
            \\  workspace_dir = excluded.workspace_dir,
            \\  git_remote_url = excluded.git_remote_url,
            \\  git_branch = excluded.git_branch,
            \\  git_dirty = excluded.git_dirty,
            \\  updated_at = excluded.updated_at,
            \\  deleted_at = NULL
        );
        defer stmt.deinit();
        try stmt.bindText(1, input.workspace_id);
        try stmt.bindText(2, input.workspace_name);
        try stmt.bindText(3, input.workspace_dir);
        try stmt.bindOptionalText(4, input.git_remote_url);
        try stmt.bindOptionalText(5, input.git_branch);
        try stmt.bindInt64(6, if (input.git_dirty) 1 else 0);
        try stmt.bindText(7, input.timestamp);
        try stmt.bindText(8, input.timestamp);
        try stmt.stepDone();
    }

    pub fn getProject(self: *Database, workspace_id: []const u8) !ProjectRecord {
        var stmt = try self.prepare(
            \\SELECT workspace_id, workspace_name, workspace_dir, git_remote_url,
            \\       git_branch, git_dirty, updated_at
            \\FROM terminal_projects
            \\WHERE workspace_id = ? AND deleted_at IS NULL
        );
        defer stmt.deinit();
        try stmt.bindText(1, workspace_id);
        if (!try stmt.stepRow()) return error.NotFound;
        return try stmt.readProjectRecord();
    }

    pub fn upsertSurface(self: *Database, input: SurfaceUpsert) !void {
        var stmt = try self.prepare(
            \\INSERT INTO terminal_surfaces (
            \\  history_id, workspace_id, workspace_name, workspace_dir, working_directory,
            \\  env_fingerprint, transcript_path, status, last_exit_code, created_at, updated_at, deleted_at
            \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
            \\ON CONFLICT(history_id) DO UPDATE SET
            \\  workspace_id = excluded.workspace_id,
            \\  workspace_name = excluded.workspace_name,
            \\  workspace_dir = excluded.workspace_dir,
            \\  working_directory = excluded.working_directory,
            \\  env_fingerprint = excluded.env_fingerprint,
            \\  transcript_path = excluded.transcript_path,
            \\  status = excluded.status,
            \\  last_exit_code = excluded.last_exit_code,
            \\  updated_at = excluded.updated_at,
            \\  deleted_at = NULL
        );
        defer stmt.deinit();
        try stmt.bindText(1, input.history_id);
        try stmt.bindText(2, input.workspace_id);
        try stmt.bindText(3, input.workspace_name);
        try stmt.bindText(4, input.workspace_dir);
        try stmt.bindText(5, input.working_directory);
        try stmt.bindOptionalText(6, input.env_fingerprint);
        try stmt.bindText(7, input.transcript_path);
        try stmt.bindText(8, input.status);
        try stmt.bindOptionalInt(9, input.last_exit_code);
        try stmt.bindText(10, input.timestamp);
        try stmt.bindText(11, input.timestamp);
        try stmt.stepDone();
    }

    pub fn startCommand(self: *Database, input: CommandStart) !i64 {
        var stmt = try self.prepare(
            \\INSERT INTO command_history (
            \\  history_id, workspace_id, workspace_name, workspace_dir, command, started_at, source, created_at, updated_at
            \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        );
        defer stmt.deinit();
        try stmt.bindText(1, input.history_id);
        try stmt.bindText(2, input.workspace_id);
        try stmt.bindText(3, input.workspace_name);
        try stmt.bindText(4, input.workspace_dir);
        try stmt.bindText(5, input.command);
        try stmt.bindText(6, input.started_at);
        try stmt.bindText(7, input.source);
        try stmt.bindText(8, input.started_at);
        try stmt.bindText(9, input.started_at);
        try stmt.stepDone();
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    pub fn finishLatestCommand(self: *Database, input: CommandFinish) !void {
        var stmt = try self.prepare(
            \\UPDATE command_history
            \\SET ended_at = ?, exit_code = ?, updated_at = ?
            \\WHERE id = (
            \\  SELECT id FROM command_history
            \\  WHERE history_id = ? AND ended_at IS NULL
            \\  ORDER BY started_at DESC, id DESC
            \\  LIMIT 1
            \\)
        );
        defer stmt.deinit();
        try stmt.bindText(1, input.ended_at);
        try stmt.bindOptionalInt(2, input.exit_code);
        try stmt.bindText(3, input.ended_at);
        try stmt.bindText(4, input.history_id);
        try stmt.stepDone();
    }

    pub fn listRecentCommands(self: *Database, query: RecentQuery) !CommandList {
        const sql =
            \\SELECT id, history_id, workspace_id, workspace_name, workspace_dir,
            \\       command, started_at, ended_at, exit_code, source
            \\FROM command_history
            \\WHERE (?1 IS NULL OR workspace_id = ?1)
            \\  AND (?2 IS NULL OR history_id = ?2)
            \\ORDER BY started_at DESC, id DESC
            \\LIMIT ?3
        ;
        var stmt = try self.prepare(sql);
        defer stmt.deinit();
        try stmt.bindOptionalText(1, query.workspace_id);
        try stmt.bindOptionalText(2, query.history_id);
        try stmt.bindInt64(3, query.limit);

        var items: std.ArrayList(CommandRecord) = .empty;
        errdefer {
            for (items.items) |*item| item.deinit(self.allocator);
            items.deinit(self.allocator);
        }
        while (try stmt.stepRow()) {
            try items.append(self.allocator, try stmt.readCommandRecord());
        }
        return .{ .items = try items.toOwnedSlice(self.allocator) };
    }
};
```

Add a small `Statement` helper in the same file with `prepare`, `bindText`, `bindOptionalText`, `bindOptionalInt`, `bindInt64`, `stepDone`, `stepRow`, `readTextAlloc`, `readProjectRecord`, and `readCommandRecord`. Those helpers should wrap `sqlite3_prepare_v2`, `sqlite3_bind_text`, `sqlite3_bind_null`, `sqlite3_bind_int64`, `sqlite3_step`, `sqlite3_column_*`, and `sqlite3_finalize` directly.

- [ ] **Step 5: Run SQLite tests and verify they pass**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell -Dtest-filter="terminal history db"
```

Expected: SQLite test opens the temp DB, runs migrations, writes one command, finishes it, and reads it back.

- [ ] **Step 6: Initialize the database at application startup**

In `application.zig`, add a private field:

```zig
terminal_history_db: ?terminal_history_db.Database = null,
```

After config load:

```zig
if (priv.termplex_cfg.terminal_history.enabled) {
    const db_path = terminal_history.databasePath(self.allocator()) catch null;
    if (db_path) |path| {
        defer self.allocator().free(path);
        priv.terminal_history_db = terminal_history_db.Database.open(self.allocator(), path) catch |err| blk: {
            log.warn("failed to open terminal history database: {}", .{err});
            break :blk null;
        };
        if (priv.terminal_history_db) |*db| {
            db.migrate() catch |err| {
                log.warn("failed to migrate terminal history database: {}", .{err});
            };
            priv.memory_state_manager.setCommandHistoryDatabase(db);
        }
    }
}
```

In application finalization:

```zig
if (priv.terminal_history_db) |*db| {
    db.deinit();
    priv.terminal_history_db = null;
}
```

- [ ] **Step 7: Upsert project metadata into SQLite**

In `application.zig`, add `upsertTerminalHistoryProject(index: u32)` and call it from startup after the database opens, from workspace creation, from restored workspace creation, and after git metadata refresh:

```zig
fn upsertTerminalHistoryProject(self: *Self, index: u32) void {
    const priv = self.private();
    if (priv.terminal_history_db == null) return;
    if (index >= priv.workspace_ids.items.len) return;

    var workspace_id_buf: [36]u8 = undefined;
    uuid.format(priv.workspace_ids.items[index], &workspace_id_buf);
    const now = iso8601Now(self.allocator()) catch null;
    defer if (now) |v| self.allocator().free(v);
    const timestamp = now orelse "1970-01-01T00:00:00Z";

    if (priv.terminal_history_db) |*db| {
        db.upsertProject(.{
            .workspace_id = workspace_id_buf[0..],
            .workspace_name = priv.workspace_names.items[index],
            .workspace_dir = priv.workspace_dirs.items[index],
            .git_remote_url = self.gitRemoteUrlForWorkspace(index),
            .git_branch = if (index < priv.workspace_git_branches.items.len) priv.workspace_git_branches.items[index] else null,
            .git_dirty = index < priv.workspace_git_dirty.items.len and priv.workspace_git_dirty.items[index],
            .timestamp = timestamp,
        }) catch |err| {
            log.warn("terminal history project upsert failed: {}", .{err});
        };
    }
}
```

Implement `gitRemoteUrlForWorkspace(index)` with `git -C <workspace_dir> config --get remote.origin.url`, returning `null` on non-git workspaces or missing remotes. Keep this lightweight and aligned with the existing `src/termplex/core/git_probe.zig` branch/dirty probing.

- [ ] **Step 8: Forward OSC 7337 command lifecycle into SQLite**

In `state_manager.zig`, import the DB module:

```zig
const terminal_history_db = @import("../terminal_history_db.zig");
```

Rename `CommandEvent.surface_uuid` to `history_id` and add `source`:

```zig
pub const CommandEvent = struct {
    pub const Kind = enum { start, end };

    kind: Kind,
    history_id: []const u8,
    workspace_id: []const u8,
    workspace_name: []const u8,
    workspace_dir: []const u8,
    transcript_path: []const u8,
    command: ?[]const u8,
    shell_pid: ?u32,
    exit_code: ?i32,
    source: []const u8 = "osc_7337",
};
```

Add a DB pointer to `StateManager`:

```zig
command_history_db: ?*terminal_history_db.Database,

pub fn setCommandHistoryDatabase(self: *StateManager, db: *terminal_history_db.Database) void {
    self.command_history_db = db;
}
```

Initialize `.command_history_db = null` in `StateManager.init`.

In `handleCommandEvent`, continue updating live JSON state as today, but use `event.history_id` as the surface key. Then add:

```zig
if (self.command_history_db) |db| {
    const now = iso8601Now(self.allocator) catch null;
    defer if (now) |v| self.allocator.free(v);
    const timestamp = now orelse "1970-01-01T00:00:00Z";

    switch (event.kind) {
        .start => if (event.command) |command| {
            db.upsertSurface(.{
                .history_id = event.history_id,
                .workspace_id = event.workspace_id,
                .workspace_name = event.workspace_name,
                .workspace_dir = event.workspace_dir,
                .working_directory = event.workspace_dir,
                .env_fingerprint = null,
                .transcript_path = event.transcript_path,
                .status = "active",
                .last_exit_code = null,
                .timestamp = timestamp,
            }) catch |err| log.warn("terminal history surface upsert failed: {}", .{err});
            _ = db.startCommand(.{
                .history_id = event.history_id,
                .workspace_id = event.workspace_id,
                .workspace_name = event.workspace_name,
                .workspace_dir = event.workspace_dir,
                .command = command,
                .started_at = timestamp,
                .source = event.source,
            }) catch |err| log.warn("terminal command history start failed: {}", .{err});
        },
        .end => {
            db.finishLatestCommand(.{
                .history_id = event.history_id,
                .ended_at = timestamp,
                .exit_code = event.exit_code,
            }) catch |err| log.warn("terminal command history finish failed: {}", .{err});
        },
    }
}
```

Update existing `state_manager.zig` tests so every `CommandEvent` uses `.history_id = "test-history-id"`, `.workspace_id = "test-workspace-id"`, and `.transcript_path = "/tmp/test-history.ansi"` instead of `.surface_uuid`.

- [ ] **Step 9: Update `handleOrchestratorCmd` to use surface history ID**

In `application.zig`, replace PID-derived surface IDs with the real restored/stable history ID:

```zig
const history_id = blk: {
    const resolved_surface = self.findGtkSurfaceByCore(core_surface);
    if (resolved_surface) |surface| {
        if (surface.getHistoryId()) |id| break :blk id;
    }
    break :blk "unknown";
};
```

Compute the transcript path for metadata:

```zig
const workspace_name = resolved_context.workspace_name orelse "default";
const workspace_id = resolved_context.workspace_id orelse workspace_name;
const transcript_path = terminal_history.transcriptPath(self.allocator(), workspace_id, history_id) catch null;
defer if (transcript_path) |path| self.allocator().free(path);
```

When building `state_manager.CommandEvent`, pass:

```zig
.history_id = history_id,
.workspace_id = workspace_id,
.transcript_path = transcript_path orelse "",
.source = "osc_7337",
```

Extend `resolveOrchestratorSurfaceContext` to include the formatted workspace UUID as `workspace_id`. Add `findGtkSurfaceByCore` using the existing traversal from that resolver.

- [ ] **Step 10: Add recent command summary to resume manifest from SQLite**

In `resume_manifest.zig`, add a helper that accepts `[]terminal_history_db.CommandRecord` and writes:

```zig
try w.writeAll("## Recent Commands\n");
if (commands.len == 0) {
    try w.writeAll("No command records found.\n\n");
    return;
}
for (commands[0..@min(commands.len, 20)]) |cmd| {
    try w.print("- [{s}] `{s}`", .{ cmd.workspace_name, cmd.command });
    if (cmd.exit_code) |code| try w.print(" exit={d}", .{code});
    try w.writeAll("\n");
}
try w.writeAll("\n");
```

Where the resume manifest is generated, call `db.listRecentCommands(.{ .limit = 20 })` when the DB is available.

- [ ] **Step 11: Run command-history tests**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell -Dtest-filter="terminal history db"
/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell -Dtest-filter="memory state"
/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell -Dtest-filter="manifest"
```

Expected: SQLite, memory-state, and manifest tests pass.

- [ ] **Step 12: Commit**

```bash
git add src/build/SharedDeps.zig src/termplex/core/terminal_history.zig src/termplex/core/terminal_history_db.zig src/termplex/core/memory/paths.zig src/termplex/core/memory/state_manager.zig src/termplex/core/memory/resume_manifest.zig src/apprt/gtk/class/application.zig
git commit -m "feat: add sqlite terminal project and command history"
```

## Task 10: Retention Cleanup, SQLite Lifecycle Deletion, And Developer Controls

**Files:**
- Modify: `src/termplex/core/terminal_history.zig`
- Modify: `src/termplex/core/terminal_history_db.zig`
- Modify: `src/apprt/gtk/class/application.zig`
- Modify: `src/termplex/core/config.zig`

- [ ] **Step 1: Add retention cleanup tests**

In `terminal_history.zig`, add:

```zig
test "terminal history retention keeps current files when retention disabled" {
    try std.testing.expectEqual(@as(bool, false), shouldDeleteForRetention(0, 100, 0));
}

test "terminal history retention deletes older files" {
    const day: i128 = 24 * 60 * 60;
    try std.testing.expect(shouldDeleteForRetention(0, 100 * day, 90));
    try std.testing.expect(!shouldDeleteForRetention(0, 10 * day, 90));
}
```

- [ ] **Step 2: Add retention predicate**

```zig
pub fn shouldDeleteForRetention(file_mtime_seconds: i128, now_seconds: i128, retention_days: u32) bool {
    if (retention_days == 0) return false;
    const retention_seconds: i128 = @as(i128, @intCast(retention_days)) * 24 * 60 * 60;
    return now_seconds - file_mtime_seconds > retention_seconds;
}

pub fn retentionCutoffIso(allocator: std.mem.Allocator, retention_days: u32) ![]const u8 {
    const now = std.time.timestamp();
    const retention_seconds: i64 = @as(i64, @intCast(retention_days)) * 24 * 60 * 60;
    const cutoff = now - retention_seconds;
    const secs: u64 = @intCast(if (cutoff < 0) 0 else cutoff);
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const epoch_day = es.getEpochDay();
    const day_seconds = es.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}
```

- [ ] **Step 3: Add database retention pruning**

In `terminal_history_db.zig`, add:

```zig
pub fn pruneCommandsOlderThan(self: *Database, cutoff_iso: []const u8) !void {
    var stmt = try self.prepare(
        \\DELETE FROM command_history
        \\WHERE started_at < ?
    );
    defer stmt.deinit();
    try stmt.bindText(1, cutoff_iso);
    try stmt.stepDone();
}
```

Also add:

```zig
pub fn deleteSurface(self: *Database, history_id: []const u8) !void {
    var delete_commands = try self.prepare(
        \\DELETE FROM command_history
        \\WHERE history_id = ?
    );
    defer delete_commands.deinit();
    try delete_commands.bindText(1, history_id);
    try delete_commands.stepDone();

    var delete_surface = try self.prepare(
        \\DELETE FROM terminal_surfaces
        \\WHERE history_id = ?
    );
    defer delete_surface.deinit();
    try delete_surface.bindText(1, history_id);
    try delete_surface.stepDone();
}

pub fn deleteProject(self: *Database, workspace_id: []const u8, timestamp: []const u8) !void {
    var delete_commands = try self.prepare(
        \\DELETE FROM command_history
        \\WHERE workspace_id = ?
    );
    defer delete_commands.deinit();
    try delete_commands.bindText(1, workspace_id);
    try delete_commands.stepDone();

    var delete_surfaces = try self.prepare(
        \\DELETE FROM terminal_surfaces
        \\WHERE workspace_id = ?
    );
    defer delete_surfaces.deinit();
    try delete_surfaces.bindText(1, workspace_id);
    try delete_surfaces.stepDone();

    var mark_project = try self.prepare(
        \\UPDATE terminal_projects
        \\SET deleted_at = ?, updated_at = ?
        \\WHERE workspace_id = ?
    );
    defer mark_project.deinit();
    try mark_project.bindText(1, timestamp);
    try mark_project.bindText(2, timestamp);
    try mark_project.bindText(3, workspace_id);
    try mark_project.stepDone();
}
```

- [ ] **Step 4: Add startup cleanup**

In `application.zig` after config load:

```zig
if (priv.termplex_cfg.terminal_history.enabled and priv.termplex_cfg.terminal_history.retention_days > 0) {
    terminal_history.cleanupRetention(
        self.allocator(),
        self.terminalHistoryOptions(),
    ) catch |err| {
        log.warn("terminal history retention cleanup failed: {}", .{err});
    };
}
```

Implement `cleanupRetention` to walk the terminal-history base directory, delete `.ansi` files older than retention, and leave directories in place.

After file cleanup, prune command rows with `started_at` before the same cutoff:

```zig
if (priv.terminal_history_db) |*db| {
    if (terminal_history.retentionCutoffIso(self.allocator(), priv.termplex_cfg.terminal_history.retention_days)) |cutoff| {
        defer self.allocator().free(cutoff);
        db.pruneCommandsOlderThan(cutoff) catch |err| {
            log.warn("terminal command history retention cleanup failed: {}", .{err});
        };
    } else |err| {
        log.warn("terminal command history retention cutoff failed: {}", .{err});
    }
}
```

- [ ] **Step 5: Update lifecycle actions to remove SQLite metadata**

In `application.zig` `actionClearTerminalHistory`, after deleting the transcript file:

```zig
if (self.private().terminal_history_db) |*db| {
    db.deleteSurface(history_id) catch |err| {
        log.warn("failed to clear terminal history database rows: {}", .{err});
    };
}
```

In the fresh-shell lifecycle helper from Task 8, after deleting the transcript file, call the same `db.deleteSurface(history_id)` for `.restart`, `.cwd_changed`, `.env_changed`, `.exited_reopen`, and `.error_reopen`.

In `removeWorkspace`, after `terminal_history.clearWorkspaceHistory`, mark the project deleted and remove its surface/command rows:

```zig
if (priv.terminal_history_db) |*db| {
    const now = iso8601Now(self.allocator()) catch null;
    defer if (now) |v| self.allocator().free(v);
    db.deleteProject(workspace_id_str, now orelse "1970-01-01T00:00:00Z") catch |err| {
        log.warn("failed to delete terminal history db rows for deleted workspace {s}: {}", .{ workspace_name, err });
    };
}
```

- [ ] **Step 6: Add developer-facing config comment**

In `config.zig`, document:

```zig
/// Terminal transcript persistence is enabled by default for developer productivity.
/// It stores local command output and command metadata, which may include secrets.
/// Set enabled=false or restore_mode="layout_only" if a workspace should not replay output.
```

- [ ] **Step 7: Run tests**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell -Dtest-filter="terminal history retention"
/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell -Dtest-filter="terminal history db"
/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell
```

Expected: tests pass.

- [ ] **Step 8: Commit**

```bash
git add src/termplex/core/terminal_history.zig src/termplex/core/terminal_history_db.zig src/apprt/gtk/class/application.zig src/termplex/core/config.zig
git commit -m "feat: add terminal history retention controls"
```

## Follow-Up Plan: Git Source Control And Checkpoint Diff Panel

This is a separate feature plan, not part of transcript persistence implementation. The current repo already has lightweight branch/dirty probing in `src/termplex/core/git_probe.zig`; this plan only adds enough SQLite project metadata to support a future source-control panel cleanly.

T3Code practice to adapt later:

- Use hidden Git refs for saved checkpoints/baselines, for example under `refs/termplex/checkpoints/<workspace-id>/<checkpoint-id>`, so comparisons can use normal Git plumbing without polluting branches/tags.
- Store checkpoint/project metadata in SQLite, not in ad hoc JSON files: workspace ID, worktree path, remote URL, current branch, checkpoint ref, checkpoint label, created time, and related terminal/session IDs.
- Use plain Git commands for source-control state: `git status --porcelain=v2 --branch`, `git diff --name-status`, `git diff --cached --name-status`, `git diff -- <path>`, `git diff --cached -- <path>`, `git add`, `git restore --staged`, and `git commit`.
- Keep the UI simpler than VS Code but structurally similar: one source-control tab/panel with changed files, staged files, diff preview, stage/unstage file actions, commit message, commit button, branch/remote summary, and dirty indicator.
- Support comparing dirty workspace state against a checkpoint hidden ref and comparing checkpoint-to-checkpoint when checkpoint refs exist.

Recommended separate implementation plan:

- Create `docs/superpowers/plans/2026-05-01-git-source-control-panel.md` before coding this feature.
- Add `src/termplex/core/git_status.zig` for porcelain-v2 parsing, diff listing, stage/unstage, commit, remote URL, and hidden-ref helpers.
- Add SQLite tables such as `git_checkpoints`, `git_file_state_cache`, and optional `git_diff_cache` only if profiling shows repeated Git calls are too expensive.
- Add GTK UI as a distinct panel/class, for example `src/apprt/gtk/class/source_control_panel.zig`, connected to the active workspace rather than terminal surfaces.
- Add tests with temporary Git repositories covering dirty files, staged files, untracked files, hidden refs, diff reads, stage/unstage, and commit.

## Follow-Up Plan: Versioning And T3Code-Style AppImage Update UX

This is a separate feature plan, not part of transcript persistence implementation. It should be planned and implemented independently because it touches release policy, networking, package detection, GTK update UI, and filesystem download/install safety.

Current Termplex version/update facts:

- `build.zig.zon` is the canonical app version source.
- `src/build/Config.zig` derives `build_config.version`, `build_config.version_string`, and release channel metadata, and already supports release-time overrides through `-Dversion-string=...`.
- `src/cli/version.zig` and the GTK About dialog already display `build_config.version_string`.
- `src/config/Config.zig` already documents `auto-update` and `auto-update-channel`, but the comments are inherited macOS/Sparkle language and must be revised for Linux.
- The `.check_for_updates` action already exists in action enums and the command palette, but it is currently routed through the unimplemented-action path in `src/apprt/gtk/class/application.zig`.

Version policy to adopt:

- Keep `build.zig.zon` as the single source of truth for released app versions.
- Do not bump the app version inside normal feature branches.
- Bump during release preparation. If terminal transcript persistence ships after `1.5.0`, release it as `1.6.0` because it adds user-visible behavior, SQLite state, and migration surface.
- Use patch releases for bug fixes only.
- Use minor releases for backward-compatible user-facing features, new SQLite tables, or new session/config state.
- Reserve major releases for intentionally incompatible config, state, or session changes.
- Use `-Dversion-string=...` for CI, preview, nightly, and local test builds without editing `build.zig.zon`.

T3Code update practices to adopt:

- Keep update checks client-side: download a manifest, compare against the local `build_config.version`, and notify only when a newer version applies.
- Do not silently install updates.
- Do not automatically replace the running binary.
- Show a small in-app update affordance when an update is available, similar to T3Code's update pill.
- Make the primary action stateful:
  - `Check for Updates` when idle/manual.
  - `Download` when an update is available.
  - `Downloading N%` while downloading.
  - `Open Download` or `Restart to Update` after a verified AppImage download.
  - `Retry Download` after a recoverable download failure.
- Let users dismiss a specific available version so Termplex does not repeatedly nag for the same release.
- Persist lightweight updater state: last checked time, last available version, dismissed version, downloaded version, download path, checksum status, install kind, and last error.

Phase 1 update behavior:

- Implement Linux update checking and user notification.
- Implement user-triggered in-app AppImage download when Termplex is currently running as an AppImage.
- Detect AppImage mode through the standard AppImage environment, primarily `APPIMAGE`; fall back to executable-path heuristics only for diagnostics, not for privileged behavior.
- Store downloads under `$XDG_STATE_HOME/termplex/updates/`, falling back to `$HOME/.local/state/termplex/updates/`.
- Download to a `.part` file first.
- Verify the downloaded file's SHA-256 against the update manifest.
- Mark the verified AppImage executable.
- Atomically rename the verified file to its final filename.
- Show `Open Download` for the verified AppImage in phase 1.
- Add `Restart to Update` only if the implementation uses a small detached handoff process/script that runs after Termplex exits. Do not overwrite the running AppImage directly from the running process.
- For `.deb`, `.rpm`, Flatpak, Snap, distro package, source build, and unknown installs, do not self-update. Show the update notification and open the release/download page instead.

Recommended separate implementation plan:

- Create `docs/superpowers/plans/2026-05-02-version-update-notifications.md` before coding this feature.
- Add `src/termplex/core/update_manifest.zig` for manifest parsing, version comparison, platform/arch selection, URL validation, and checksum metadata.
- Add `src/termplex/core/update_state.zig` for updater state transitions and persistence serialization.
- Add `src/termplex/core/update_checker.zig` for HTTPS manifest fetch, AppImage detection, download-to-temp, checksum verification, executable bit update, atomic rename, and cleanup of stale `.part` files.
- Add an update-state path helper in `src/termplex/core/memory/paths.zig`, for example `$XDG_STATE_HOME/termplex/updates/update-state.json`.
- Update `src/config/Config.zig` so Linux phase 1 follows the T3Code behavior: `auto-update = check` and `auto-update = download` both check and notify, but downloads start only when the user clicks the in-app `Download` action. Revise the inherited macOS/Sparkle comments so this behavior is explicit.
- Implement `.check_for_updates` in `src/apprt/gtk/class/application.zig`.
- Add GTK UI in the existing sidebar/window surface rather than a landing page: an update pill/banner with icon, version label, progress, dismiss button, and primary action.
- Wire command-palette `check_for_updates` to the same update service.
- Add tests for manifest parsing, version comparison, channel filtering, platform/arch selection, AppImage detection, checksum mismatch, `.part` cleanup, and dismissed-version behavior.

Manifest shape:

```json
{
  "version": "1.6.0",
  "channel": "stable",
  "released_at": "2026-05-02T00:00:00Z",
  "notes_url": "https://github.com/termplex-org/termplex/releases/tag/v1.6.0",
  "downloads": {
    "linux-x86_64-appimage": {
      "url": "https://github.com/termplex-org/termplex/releases/download/v1.6.0/Termplex-1.6.0-x86_64.AppImage",
      "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    },
    "linux-x86_64-deb": {
      "url": "https://github.com/termplex-org/termplex/releases/download/v1.6.0/termplex_1.6.0_amd64.deb",
      "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    }
  }
}
```

Security and privacy requirements:

- Use HTTPS-only manifest and download URLs.
- Do not send workspace names, project paths, git remotes, command history, terminal transcript data, environment variables, or install paths during update checks.
- Treat normal HTTP metadata such as IP address and User-Agent as unavoidable network metadata and document that plainly in config/help text.
- Validate manifest versions with semantic-version parsing before comparing.
- Reject unsupported platforms, unsupported architectures, missing SHA-256 values, checksum mismatches, non-HTTPS URLs, and filenames containing path separators.
- Keep downloads local to Termplex's XDG state update directory.
- Never execute downloaded content automatically.
- Do not self-update Flatpak, Snap, deb, rpm, source, or package-manager installs.
- Do not overwrite the running AppImage from the running Termplex process.

## Task 11: End-To-End Verification

**Files:**
- Verify only

- [ ] **Step 1: Format**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig fmt src/build/SharedDeps.zig src/termplex/core/terminal_history.zig src/termplex/core/terminal_history_db.zig src/termplex/core/config.zig src/termplex/core/session.zig src/apprt/gtk/class/application.zig src/apprt/gtk/class/window.zig src/apprt/gtk/class/surface.zig src/apprt/gtk/class/split_tree.zig src/apprt/gtk/class/tab.zig src/termio/Options.zig src/termio/Termio.zig src/termio/Exec.zig src/termplex/core/memory/paths.zig src/termplex/core/memory/state_manager.zig src/termplex/core/memory/resume_manifest.zig
```

Expected: command exits 0.

- [ ] **Step 2: Run focused tests**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell -Dtest-filter="terminal history"
/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell -Dtest-filter="terminal history db"
/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell -Dtest-filter="session"
/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell -Dtest-filter="memory"
```

Expected: all focused tests pass.

- [ ] **Step 3: Run full tests**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell
```

Expected: full test suite passes.

- [ ] **Step 4: Build GTK app**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

Expected: build exits 0 and creates `zig-out/bin/termplex-app`.

- [ ] **Step 5: Manual smoke test transcript restore**

Run:

```bash
./zig-out/bin/termplex-app
```

Manual actions:

1. Open a project workspace.
2. Run `printf 'termplex-history-a\ntermplex-history-b\n'`.
3. Split the terminal and run `printf 'split-history-a\n'`.
4. Close Termplex.
5. Reopen Termplex.
6. Confirm both restored surfaces show their own previous output.
7. Confirm each surface also has a fresh live shell below the restore marker.
8. Run `echo live-after-restore` and confirm new output appends below restored output.

- [ ] **Step 6: Manual smoke test clear history**

Manual actions:

1. Trigger the clear history action for the active surface.
2. Close Termplex.
3. Reopen Termplex.
4. Confirm that surface no longer replays prior output.
5. Confirm other surfaces still replay their own output.

- [ ] **Step 7: Manual smoke test lifecycle cleanup**

Manual actions:

1. Run output in a terminal, restart that terminal/fresh shell, close and reopen, and confirm pre-restart output is not replayed.
2. Run output in a terminal, reopen the same logical surface with a different working directory, close and reopen, and confirm old-cwd output is not replayed.
3. Run output in a terminal, reopen the same logical surface with a changed environment fingerprint, close and reopen, and confirm old-env output is not replayed.
4. Run `exit`, reopen/start a fresh shell in that surface, close and reopen, and confirm exited-session output is not replayed.
5. Delete a non-last project/workspace, confirm its transcript directory is removed from `$XDG_STATE_HOME/termplex/terminal-history/`, and confirm command/project rows are deleted or marked deleted in SQLite.

- [ ] **Step 8: Manual layout-only mode check**

Edit `~/.config/termplex/config.toml`:

```toml
[terminal_history]
restore_mode = "layout_only"
```

Manual actions:

1. Run output in a terminal.
2. Close and reopen.
3. Confirm layout restores but previous output does not replay.

- [ ] **Step 9: Final commit**

```bash
git status --short
git log --oneline -n 12
```

Expected: only intended files are modified, and commits correspond to the tasks above.

## Risks And Mitigations

- **Risk: replayed bytes trigger terminal actions.** Mitigation: use T3Code-parity sanitizer behavior: strip terminal replies and color query/reply sequences, track incomplete sequences across chunks, and preserve normal terminal control bytes. This is a developer-productivity tradeoff, not a hardened replay boundary.
- **Risk: users confuse replayed output with live process state.** Mitigation: restore marker appears before the new shell prompt.
- **Risk: terminal output contains secrets.** Mitigation: developer users accept local history visibility by default; data remains local under XDG state, can be cleared, can be switched to layout-only/off, and is covered by retention cleanup.
- **Risk: SQLite adds dependency and migration surface early.** Mitigation: keep phase-1 schema small, use `schema_migrations`, WAL, direct prepared statements, and tests that open/migrate/write/query a temp DB.
- **Risk: lifecycle deletion removes useful history unexpectedly.** Mitigation: match the explicit T3Code-style lifecycle cases only: explicit clear, restart/fresh shell, cwd/env mismatch, exited/error reopen, and project deletion. Normal tab close keeps history.
- **Risk: source-control panel expands scope.** Mitigation: keep hidden refs, dirty-file diffing, staging, commit, and checkpoint comparison in a separate follow-up plan that builds on SQLite project metadata.
- **Risk: update UX expands transcript persistence scope.** Mitigation: keep versioning, manifest checks, AppImage download, and update UI in a separate follow-up plan; this plan only records the approved direction.
- **Risk: generated surface IDs break continuity.** Mitigation: stable `history_id` is stored on `Surface` and in session JSON v6.
- **Risk: synchronous disk writes hurt output throughput.** Mitigation: initial correctness task is followed by writer coalescing; a later timer-based flush can be added if profiling shows need.
- **Risk: session schema drift continues.** Mitigation: update both core `session.zig` and GTK v6 parser/writer in the same task.

## Self-Review

- Spec coverage: The plan covers T3Code-style persisted transcripts, safe IDs, bounded/coalesced logs, T3Code-parity sanitizer behavior, replay-on-open, lifecycle clear/delete controls, SQLite-backed project and command history, retention, and developer controls.
- Process continuity: Explicitly excluded in Scope and Architecture.
- T3Code enhancements: Included per-terminal logs, caps, sanitizer semantics, snapshot replay, lifecycle clear/delete behavior, SQLite project/session metadata, and tests modeled on T3Code behavior.
- Git/source-control request: Captured as a separate follow-up plan direction because hidden refs, dirty-file diffing, staging/unstaging, commits, and checkpoint comparison are a distinct source-control feature, not transcript persistence.
- Version/update request: Captured as a separate follow-up plan direction because app version policy, Linux update manifests, AppImage downloads, and update UI are distinct release/update features, not transcript persistence.
- Type consistency: `history_id`, `terminal_history.Options`, `SanitizerState`, `TranscriptWriter`, `terminal_history_db.Database`, `ProjectUpsert`, `ProjectRecord`, and `CommandRecord` names are consistent across tasks.
- Placeholder scan: No deferred implementation placeholders are required to execute the plan.
