# Workspace Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a local-first workspace dashboard that summarizes the active workspace and links into recent commands, transcript viewing, source control, and storage/history management.

**Architecture:** Compose existing app state, SQLite command metadata, git status, and storage accounting through an application-level dashboard status API. Expose the same summary through IPC/`termplex-ctl` for E2E coverage, then add a compact libadwaita dialog that displays workspace context, recent commands, git/storage summaries, and action buttons into the existing dialogs.

**Tech Stack:** Zig 0.15.2, GTK4/libadwaita Blueprint templates, existing JSON IPC over Unix sockets, existing SQLite terminal history database, existing `git_status` and `storage_status` helpers, Python stdlib E2E runner.

---

## Scope

Phase 1 includes:

- Show active or specified workspace identity: index, ID, name, directory, current working directory, tab count, active tab index, and active terminal `history_id` when available.
- Show recent commands for the workspace from SQLite, newest first, capped to a small limit.
- Provide recent-command actions in the dashboard UI: copy command, rerun command, and open related transcript.
- Show git summary for the workspace: repository detected, branch, dirty state, remote URL, staged count, and unstaged count.
- Show storage/history summary: total history bytes, transcript bytes, database bytes, transcript file count, project count, surface count, and command count.
- Show quick actions to open Command History, Transcript Viewer, Source Control, and Storage And History.
- Add `termplex-ctl dashboard status` and `termplex-ctl dashboard show`.
- Add E2E coverage for dashboard status and dialog presentation.

Phase 1 defers:

- Customizable dashboard cards or layout.
- Cross-workspace dashboard browsing.
- Charts or analytics.
- Transcript body previews inside the dashboard.
- Source-control diffs inside the dashboard.
- Background auto-refresh beyond refresh-on-open and an explicit refresh button.
- Agent/task timeline cards unless a separate agent state API is planned separately.

## Design Decisions

- Keep the dashboard as a composition surface, not a new data store. It should query existing live app state and existing services at refresh time.
- Put dashboard aggregation in `src/apprt/gtk/class/application.zig` because the summary spans window/workspace state, SQLite, storage accounting, and git status.
- Do not add a new core module in phase 1. Existing core modules already own git, storage, transcript, and command-history behavior.
- Keep the UI compact and operational. The dashboard should be a work surface with summaries and actions, not a landing page.
- Use existing dialog/action boundaries instead of duplicating behavior. The dashboard opens Command History, Transcript Viewer, Source Control, and Storage And History rather than embedding those full tools.
- Keep all summary output bounded. Recent commands default to 8 and IPC caps at 25.

## Data Contract

`dashboard.status` returns:

```json
{
  "workspace": {
    "index": 0,
    "id": "workspace-id",
    "name": "Project",
    "dir": "/path/to/project",
    "current_pwd": "/path/to/project",
    "tab_count": 1,
    "active_tab": 0,
    "active_history_id": "history-id"
  },
  "recent_commands": [
    {
      "id": 1,
      "history_id": "history-id",
      "workspace_id": "workspace-id",
      "workspace_name": "Project",
      "workspace_dir": "/path/to/project",
      "command": "zig build test",
      "started_at": "2026-05-05T10:00:00Z",
      "ended_at": "2026-05-05T10:00:01Z",
      "exit_code": 0,
      "source": "osc_7337"
    }
  ],
  "git": {
    "is_repo": true,
    "root": "/path/to/project",
    "branch": "main",
    "remote_url": "git@example.com:org/repo.git",
    "dirty": true,
    "staged_count": 1,
    "unstaged_count": 2
  },
  "storage": {
    "history_enabled": true,
    "restore_mode": "transcript",
    "total_bytes": 12345,
    "transcript_bytes": 10000,
    "db_bytes": 2345,
    "transcript_file_count": 2,
    "project_count": 1,
    "surface_count": 2,
    "command_count": 5
  }
}
```

## File Map

- Modify `test/e2e/termplex_e2e.py`: add dashboard status and dialog presentation assertions.
- Modify `tools/termplex-ctl`: add `dashboard status` and `dashboard show`.
- Modify `src/apprt/gtk/class/application.zig`: add dashboard status aggregation, JSON append helpers, and IPC handlers.
- Create `src/apprt/gtk/class/workspace_dashboard_dialog.zig`: dashboard dialog and recent-command row object.
- Create `src/apprt/gtk/ui/1.5/workspace-dashboard-dialog.blp`: dashboard UI.
- Modify `src/apprt/gtk/build/gresource.zig`: include the new Blueprint.
- Modify `src/apprt/gtk/class/window.zig`: add dialog weak ref, window action, signal handlers, and menu wiring.
- Modify `src/apprt/gtk/ui/1.5/window.blp`: add `Workspace Dashboard...` near existing Termplex productivity tools.
- Modify `test/e2e/README.md`: mention dashboard coverage if the README already lists covered workflows.
- Modify `docs/superpowers/plans/2026-05-03-termplex-roadmap-implementation-sequence.md`: mark transcript viewer complete and dashboard as the active next phase.

## Tasks

### Task 1: E2E Contract For Dashboard Status

**Files:**

- Modify: `test/e2e/termplex_e2e.py`

- [ ] **Step 1: Add a failing dashboard status assertion**

Add this helper near the existing history/source-control/storage assertion helpers:

```python
def assert_dashboard_status(args, env, workspace_name, command_marker, timeout):
    def dashboard_has_context():
        status = ctl(args, env, "dashboard", "status", "--workspace", workspace_name)
        workspace = status.get("workspace", {})
        commands = status.get("recent_commands", [])
        git = status.get("git", {})
        storage = status.get("storage", {})
        if workspace.get("name") != workspace_name:
            return None
        if not any(command_marker in item.get("command", "") for item in commands):
            return None
        if not git.get("is_repo"):
            return None
        if storage.get("command_count", 0) <= 0:
            return None
        return status

    status = wait_until("workspace dashboard status", timeout, dashboard_has_context)
    workspace = status["workspace"]
    if workspace.get("tab_count", 0) <= 0:
        raise E2EError("dashboard status did not report tabs: {}".format(status))
    if not workspace.get("active_history_id"):
        raise E2EError("dashboard status did not report active history id: {}".format(status))

    git = status["git"]
    if git.get("staged_count", 0) < 0 or git.get("unstaged_count", 0) < 0:
        raise E2EError("dashboard git counts were invalid: {}".format(status))

    storage = status["storage"]
    if storage.get("transcript_file_count", 0) <= 0:
        raise E2EError("dashboard storage did not report transcript files: {}".format(status))

    shown = ctl(args, env, "dashboard", "show")
    if not shown.get("shown"):
        raise E2EError("dashboard dialog did not report shown: {}".format(shown))
```

- [ ] **Step 2: Call the assertion from `main()` after command and git fixtures exist**

In the main test flow, call the helper after `assert_history_search(...)`, `assert_history_transcript_cli(...)`, `assert_storage_status_has_history(...)`, and `assert_source_control_flow(...)` have created enough state:

```python
        assert_dashboard_status(args, env, workspace_name, command_name, args.timeout)
```

If source-control assertions currently commit all dirty changes before this point, move the dashboard assertion before the final commit or create a small new unstaged file before calling it:

```python
        pathlib.Path(workspace_dir, "dashboard-dirty.txt").write_text("dashboard dirty state\n")
        assert_dashboard_status(args, env, workspace_name, command_name, args.timeout)
```

- [ ] **Step 3: Run E2E and verify the expected failure**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build e2e -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

Expected: FAIL because `termplex-ctl` does not know the `dashboard` resource.

### Task 2: CLI Surface For Dashboard

**Files:**

- Modify: `tools/termplex-ctl`

- [ ] **Step 1: Add the parser entries**

Add after the storage parser block:

```python
    # --- dashboard ---
    dashboard = subparsers.add_parser("dashboard", help="Workspace dashboard operations")
    dashboard_sub = dashboard.add_subparsers(dest="action")
    dashboard_status = dashboard_sub.add_parser("status", help="Show workspace dashboard status")
    dashboard_status.add_argument("--workspace", help="Workspace name or index")
    dashboard_status.add_argument("--limit", type=int, default=8, help="Maximum recent commands to return")
    dashboard_sub.add_parser("show", help="Show the workspace dashboard dialog")
```

- [ ] **Step 2: Add request mapping**

Add before the `workspace` resource mapping in `build_request(args)`:

```python
    if resource == "dashboard":
        if action == "status":
            p = {"limit": args.limit}
            if args.workspace:
                p["workspace"] = parse_workspace_ref(args.workspace)
            return "dashboard.status", p
        if action == "show":
            return "dashboard.show", {}
        return None, None
```

- [ ] **Step 3: Compile-check the CLI**

Run:

```bash
python3 -m py_compile tools/termplex-ctl test/e2e/termplex_e2e.py
```

Expected: PASS.

- [ ] **Step 4: Run E2E and verify the next expected failure**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build e2e -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

Expected: FAIL with an IPC unknown-method error for `dashboard.status`.

### Task 3: Application Dashboard Status API And IPC

**Files:**

- Modify: `src/apprt/gtk/class/application.zig`

- [ ] **Step 1: Add dashboard data structs near existing public app helper structs**

Add near `TerminalTranscript` or the storage/git public helper methods:

```zig
    pub const DashboardWorkspace = struct {
        index: u32,
        id: []u8,
        name: []u8,
        dir: []u8,
        current_pwd: []u8,
        tab_count: u32,
        active_tab: ?u32,
        active_history_id: ?[]u8,

        pub fn deinit(self: DashboardWorkspace, alloc: std.mem.Allocator) void {
            alloc.free(self.id);
            alloc.free(self.name);
            alloc.free(self.dir);
            alloc.free(self.current_pwd);
            if (self.active_history_id) |value| alloc.free(value);
        }
    };

    pub const DashboardStorage = struct {
        history_enabled: bool,
        restore_mode: []u8,
        total_bytes: u64,
        transcript_bytes: u64,
        db_bytes: u64,
        transcript_file_count: u64,
        project_count: u64,
        surface_count: u64,
        command_count: u64,

        pub fn deinit(self: DashboardStorage, alloc: std.mem.Allocator) void {
            alloc.free(self.restore_mode);
        }
    };

    pub const DashboardGit = struct {
        status: git_status.Status,
        staged_count: u64,
        unstaged_count: u64,

        pub fn deinit(self: DashboardGit, alloc: std.mem.Allocator) void {
            var status = self.status;
            status.deinit(alloc);
        }
    };

    pub const DashboardStatus = struct {
        workspace: DashboardWorkspace,
        recent_commands: terminal_history_db.CommandList,
        git: DashboardGit,
        storage: DashboardStorage,

        pub fn deinit(self: DashboardStatus, alloc: std.mem.Allocator) void {
            self.workspace.deinit(alloc);
            self.recent_commands.deinit(std.heap.c_allocator);
            self.git.deinit(alloc);
            self.storage.deinit(alloc);
        }
    };
```

- [ ] **Step 2: Add workspace summary helper**

Add below `storageRowCounts`:

```zig
    fn dashboardWorkspace(self: *Self, alloc: std.mem.Allocator, workspace_idx: u32) !DashboardWorkspace {
        const priv = self.private();
        const id = try self.workspaceIdString(alloc, workspace_idx);
        errdefer alloc.free(id);
        const workspace_usize: usize = @intCast(workspace_idx);
        const name = try alloc.dupe(u8, priv.workspace_names.items[workspace_usize]);
        errdefer alloc.free(name);
        const dir_value = self.workspaceDir(workspace_idx) orelse "";
        const dir = try alloc.dupe(u8, dir_value);
        errdefer alloc.free(dir);
        const current_pwd_value = if (workspace_idx == priv.active_workspace_idx)
            (priv.current_pwd orelse dir_value)
        else
            dir_value;
        const current_pwd = try alloc.dupe(u8, current_pwd_value);
        errdefer alloc.free(current_pwd);

        const tab_view = self.workspaceTabView(workspace_idx);
        const tab_count: u32 = if (tab_view) |view| @intCast(@max(view.getNPages(), 0)) else 0;
        const active_tab = self.activeTabIndexForWorkspace(workspace_idx);

        var active_history_id: ?[]u8 = null;
        errdefer if (active_history_id) |value| alloc.free(value);
        if (workspace_idx == priv.active_workspace_idx) {
            if (self.as(gtk.Application).getActiveWindow()) |active_win| {
                if (gobject.ext.cast(Window, active_win)) |win| {
                    if (win.getActiveSurface()) |surface| {
                        if (surface.getHistoryId()) |history_id| {
                            active_history_id = try alloc.dupe(u8, history_id);
                        }
                    }
                }
            }
        }

        return .{
            .index = workspace_idx,
            .id = id,
            .name = name,
            .dir = dir,
            .current_pwd = current_pwd,
            .tab_count = tab_count,
            .active_tab = active_tab,
            .active_history_id = active_history_id,
        };
    }
```

- [ ] **Step 3: Add storage and git summary helpers**

Add below `dashboardWorkspace`:

```zig
    fn dashboardStorage(self: *Self, alloc: std.mem.Allocator) !DashboardStorage {
        const cfg = self.private().termplex_cfg.terminal_history;
        var usage = try self.storageDiskUsage(alloc);
        defer usage.deinit(alloc);
        const counts = self.storageRowCounts();
        return .{
            .history_enabled = cfg.enabled,
            .restore_mode = try alloc.dupe(u8, cfg.restore_mode),
            .total_bytes = usage.total_bytes,
            .transcript_bytes = usage.transcript_bytes,
            .db_bytes = usage.db_bytes,
            .transcript_file_count = usage.transcript_file_count,
            .project_count = counts.project_count,
            .surface_count = counts.surface_count,
            .command_count = counts.command_count,
        };
    }

    fn dashboardGit(self: *Self, alloc: std.mem.Allocator, workspace_idx: u32) !DashboardGit {
        const dir = self.workspaceDir(workspace_idx) orelse ".";
        var status = try git_status.query(alloc, dir);
        errdefer status.deinit(alloc);
        self.syncGitStatusToWorkspace(workspace_idx, &status);
        return .{
            .status = status,
            .staged_count = @intCast(status.staged.len),
            .unstaged_count = @intCast(status.unstaged.len),
        };
    }
```

- [ ] **Step 4: Add public dashboard status method**

Add below the helpers:

```zig
    pub fn workspaceDashboardStatus(
        self: *Self,
        alloc: std.mem.Allocator,
        workspace_idx: u32,
        limit: u32,
    ) !DashboardStatus {
        var workspace = try self.dashboardWorkspace(alloc, workspace_idx);
        errdefer workspace.deinit(alloc);

        const recent_limit = @min(@max(limit, 1), 25);
        var recent_commands = try self.searchTerminalCommands(.{
            .workspace_id = workspace.id,
            .limit = recent_limit,
        });
        errdefer recent_commands.deinit(std.heap.c_allocator);

        var git = try self.dashboardGit(alloc, workspace_idx);
        errdefer git.deinit(alloc);

        var storage = try self.dashboardStorage(alloc);
        errdefer storage.deinit(alloc);

        return .{
            .workspace = workspace,
            .recent_commands = recent_commands,
            .git = git,
            .storage = storage,
        };
    }

    pub fn activeWorkspaceDashboardStatus(
        self: *Self,
        alloc: std.mem.Allocator,
        limit: u32,
    ) !DashboardStatus {
        return self.workspaceDashboardStatus(alloc, self.private().active_workspace_idx, limit);
    }
```

- [ ] **Step 5: Add JSON append helpers**

Add near the existing IPC JSON helpers:

```zig
    fn appendDashboardWorkspaceJson(
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        workspace: DashboardWorkspace,
    ) !void {
        try buf.appendSlice(alloc, "{\"index\":");
        try appendJsonInt(buf, alloc, workspace.index);
        try buf.appendSlice(alloc, ",\"id\":");
        try appendJsonString(buf, alloc, workspace.id);
        try buf.appendSlice(alloc, ",\"name\":");
        try appendJsonString(buf, alloc, workspace.name);
        try buf.appendSlice(alloc, ",\"dir\":");
        try appendJsonString(buf, alloc, workspace.dir);
        try buf.appendSlice(alloc, ",\"current_pwd\":");
        try appendJsonString(buf, alloc, workspace.current_pwd);
        try buf.appendSlice(alloc, ",\"tab_count\":");
        try appendJsonInt(buf, alloc, workspace.tab_count);
        try buf.appendSlice(alloc, ",\"active_tab\":");
        if (workspace.active_tab) |idx| {
            try appendJsonInt(buf, alloc, idx);
        } else {
            try buf.appendSlice(alloc, "null");
        }
        try buf.appendSlice(alloc, ",\"active_history_id\":");
        try appendOptionalJsonString(buf, alloc, workspace.active_history_id);
        try buf.append(alloc, '}');
    }

    fn appendDashboardGitJson(
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        git: DashboardGit,
    ) !void {
        try buf.appendSlice(alloc, "{\"is_repo\":");
        try buf.appendSlice(alloc, if (git.status.is_repo) "true" else "false");
        try buf.appendSlice(alloc, ",\"root\":");
        try appendOptionalJsonString(buf, alloc, git.status.root);
        try buf.appendSlice(alloc, ",\"branch\":");
        try appendOptionalJsonString(buf, alloc, git.status.branch);
        try buf.appendSlice(alloc, ",\"remote_url\":");
        try appendOptionalJsonString(buf, alloc, git.status.remote_url);
        try buf.appendSlice(alloc, ",\"dirty\":");
        try buf.appendSlice(alloc, if (git.status.dirty) "true" else "false");
        try buf.appendSlice(alloc, ",\"staged_count\":");
        try appendJsonInt(buf, alloc, git.staged_count);
        try buf.appendSlice(alloc, ",\"unstaged_count\":");
        try appendJsonInt(buf, alloc, git.unstaged_count);
        try buf.append(alloc, '}');
    }

    fn appendDashboardStorageJson(
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        storage: DashboardStorage,
    ) !void {
        try buf.appendSlice(alloc, "{\"history_enabled\":");
        try buf.appendSlice(alloc, if (storage.history_enabled) "true" else "false");
        try buf.appendSlice(alloc, ",\"restore_mode\":");
        try appendJsonString(buf, alloc, storage.restore_mode);
        try buf.appendSlice(alloc, ",\"total_bytes\":");
        try appendJsonInt(buf, alloc, storage.total_bytes);
        try buf.appendSlice(alloc, ",\"transcript_bytes\":");
        try appendJsonInt(buf, alloc, storage.transcript_bytes);
        try buf.appendSlice(alloc, ",\"db_bytes\":");
        try appendJsonInt(buf, alloc, storage.db_bytes);
        try buf.appendSlice(alloc, ",\"transcript_file_count\":");
        try appendJsonInt(buf, alloc, storage.transcript_file_count);
        try buf.appendSlice(alloc, ",\"project_count\":");
        try appendJsonInt(buf, alloc, storage.project_count);
        try buf.appendSlice(alloc, ",\"surface_count\":");
        try appendJsonInt(buf, alloc, storage.surface_count);
        try buf.appendSlice(alloc, ",\"command_count\":");
        try appendJsonInt(buf, alloc, storage.command_count);
        try buf.append(alloc, '}');
    }

    fn appendDashboardStatusJson(
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        status: DashboardStatus,
    ) !void {
        try buf.appendSlice(alloc, "{\"workspace\":");
        try appendDashboardWorkspaceJson(buf, alloc, status.workspace);
        try buf.appendSlice(alloc, ",\"recent_commands\":[");
        for (status.recent_commands.items, 0..) |item, index| {
            if (index > 0) try buf.append(alloc, ',');
            try appendCommandRecordJson(buf, alloc, item);
        }
        try buf.appendSlice(alloc, "],\"git\":");
        try appendDashboardGitJson(buf, alloc, status.git);
        try buf.appendSlice(alloc, ",\"storage\":");
        try appendDashboardStorageJson(buf, alloc, status.storage);
        try buf.append(alloc, '}');
    }
```

- [ ] **Step 6: Add IPC handlers**

Add near existing IPC handlers:

```zig
    fn dashboardParams(obj: std.json.ObjectMap) std.json.ObjectMap {
        const params_val = obj.get("params") orelse .null;
        return if (params_val == .object) params_val.object else obj;
    }

    fn dashboardWorkspaceIndex(self: *Self, params: std.json.ObjectMap) ?u32 {
        const explicit_workspace =
            params.get("workspace") != null or
            params.get("ref") != null or
            params.get("index") != null;
        if (!explicit_workspace) return self.private().active_workspace_idx;
        return self.resolveWorkspaceIdx(params);
    }

    fn ipcDashboardError(alloc: std.mem.Allocator, id: i64, code: []const u8, message: []const u8) ?[]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);
        buf.appendSlice(alloc, "{\"ok\":false,\"error\":{\"code\":") catch return null;
        appendJsonString(&buf, alloc, code) catch return null;
        buf.appendSlice(alloc, ",\"message\":") catch return null;
        appendJsonString(&buf, alloc, message) catch return null;
        buf.appendSlice(alloc, "},\"id\":") catch return null;
        appendJsonInt(&buf, alloc, id) catch return null;
        buf.appendSlice(alloc, "}") catch return null;
        return buf.toOwnedSlice(alloc) catch null;
    }

    fn ipcDashboardStatus(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params = dashboardParams(obj);
        const workspace_idx = self.dashboardWorkspaceIndex(params) orelse {
            return ipcDashboardError(alloc, id, "not_found", "workspace not found");
        };
        const limit = jsonLimitParam(params, "limit", 8, 25);

        const status = self.workspaceDashboardStatus(alloc, workspace_idx, limit) catch |err| {
            log.warn("failed to build dashboard status: {}", .{err});
            return ipcDashboardError(alloc, id, "dashboard_status_failed", "failed to read dashboard status");
        };
        defer status.deinit(alloc);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);
        appendDashboardStatusJson(&buf, alloc, status) catch return null;
        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{s},\"id\":{d}}}",
            .{ buf.items, id },
        ) catch null;
    }

    fn ipcDashboardShow(self: *Self, alloc: std.mem.Allocator, id: i64) ?[]u8 {
        if (self.as(gtk.Application).getActiveWindow()) |active_win| {
            if (gobject.ext.cast(Window, active_win)) |win| {
                win.toggleWorkspaceDashboard();
                return std.fmt.allocPrint(
                    alloc,
                    "{{\"ok\":true,\"result\":{{\"shown\":true}},\"id\":{d}}}",
                    .{id},
                ) catch null;
            }
        }
        return ipcDashboardError(alloc, id, "no_window", "no active window");
    }
```

- [ ] **Step 7: Add IPC dispatch**

In the dispatch section, add before `history.search`:

```zig
        if (std.mem.eql(u8, method, "dashboard.status")) {
            return self.ipcDashboardStatus(alloc, id, root.object);
        }

        if (std.mem.eql(u8, method, "dashboard.show")) {
            return self.ipcDashboardShow(alloc, id);
        }
```

- [ ] **Step 8: Build and verify status IPC**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig fmt src/apprt/gtk/class/application.zig tools/termplex-ctl test/e2e/termplex_e2e.py
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

Expected: PASS.

Run E2E again:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build e2e -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

Expected: FAIL at `dashboard.show` until the window/dialog wiring exists.

### Task 4: Dashboard Dialog UI

**Files:**

- Create: `src/apprt/gtk/class/workspace_dashboard_dialog.zig`
- Create: `src/apprt/gtk/ui/1.5/workspace-dashboard-dialog.blp`
- Modify: `src/apprt/gtk/build/gresource.zig`

- [ ] **Step 1: Add Blueprint resource entry**

In `src/apprt/gtk/build/gresource.zig`, add near the other Termplex dialogs:

```zig
    .{ .major = 1, .minor = 5, .name = "workspace-dashboard-dialog" },
```

- [ ] **Step 2: Create the Blueprint**

Create `src/apprt/gtk/ui/1.5/workspace-dashboard-dialog.blp`:

```blueprint
using Gtk 4.0;
using Gio 2.0;
using Adw 1;

template $TermplexWorkspaceDashboardDialog: Adw.Bin {
  Adw.Dialog dialog {
    closed => $closed();
    title: _("Workspace Dashboard");
    content-width: 920;
    content-height: 680;

    Adw.ToolbarView {
      [top]
      Adw.HeaderBar {
        [start]
        Button {
          icon-name: "view-refresh-symbolic";
          tooltip-text: _("Refresh");
          clicked => $refresh_clicked();
        }
      }

      Box {
        orientation: vertical;
        spacing: 12;
        margin-top: 12;
        margin-bottom: 12;
        margin-start: 12;
        margin-end: 12;

        Box {
          orientation: horizontal;
          spacing: 8;

          Button {
            label: _("Command History");
            clicked => $command_history_clicked();
          }

          Button {
            label: _("Transcript Viewer");
            clicked => $transcript_clicked();
          }

          Button {
            label: _("Source Control");
            clicked => $source_control_clicked();
          }

          Button {
            label: _("Storage And History");
            clicked => $storage_clicked();
          }
        }

        Label workspace_label {
          xalign: 0;
          wrap: true;
          selectable: true;
        }

        Label summary_label {
          xalign: 0;
          wrap: true;
          selectable: true;
        }

        Paned {
          orientation: horizontal;
          hexpand: true;
          vexpand: true;

          ScrolledWindow {
            min-content-width: 360;
            ListView command_view {
              show-separators: true;
              single-click-activate: true;
              activate => $command_activated();

              model: SingleSelection command_model {
                model: Gio.ListStore command_source {
                  item-type: typeof<$TermplexDashboardCommand>;
                };
              };

              styles [
                "rich-list",
              ]

              factory: BuilderListItemFactory {
                template ListItem {
                  child: Box {
                    orientation: vertical;
                    spacing: 3;
                    tooltip-text: bind template.item as <$TermplexDashboardCommand>.command;

                    Label {
                      ellipsize: end;
                      halign: start;
                      wrap: false;
                      single-line-mode: true;

                      styles [
                        "title",
                        "monospace",
                      ]

                      label: bind template.item as <$TermplexDashboardCommand>.command;
                    }

                    Label {
                      ellipsize: end;
                      halign: start;
                      wrap: false;
                      single-line-mode: true;

                      styles [
                        "subtitle",
                      ]

                      label: bind template.item as <$TermplexDashboardCommand>.metadata;
                    }
                  };
                }
              };
            }
          }

          ScrolledWindow {
            TextView details_view {
              editable: false;
              cursor-visible: false;
              monospace: true;
              wrap-mode: word-char;
            }
          }
        }

        Box {
          orientation: horizontal;
          spacing: 8;

          Button {
            icon-name: "edit-copy-symbolic";
            tooltip-text: _("Copy Command");
            clicked => $copy_command_clicked();
          }

          Button {
            icon-name: "media-playback-start-symbolic";
            tooltip-text: _("Rerun Command");
            clicked => $rerun_command_clicked();
          }

          Button {
            icon-name: "text-x-generic-symbolic";
            tooltip-text: _("Open Command Transcript");
            clicked => $command_transcript_clicked();
          }
        }
      }
    }
  }
}
```

- [ ] **Step 3: Create dialog class skeleton**

Create `src/apprt/gtk/class/workspace_dashboard_dialog.zig` with:

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const adw = @import("adw");
const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Window = @import("window.zig").Window;
const terminal_history_db = @import("../../../termplex/core/terminal_history_db.zig");

const log = std.log.scoped(.gtk_termplex_workspace_dashboard);

pub const WorkspaceDashboardDialog = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "TermplexWorkspaceDashboardDialog",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const signals = struct {
        pub const @"open-command-history" = struct {
            pub const name = "open-command-history";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{}, void);
        };

        pub const @"open-source-control" = struct {
            pub const name = "open-source-control";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{}, void);
        };

        pub const @"open-storage" = struct {
            pub const name = "open-storage";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{}, void);
        };

        pub const @"open-transcript" = struct {
            pub const name = "open-transcript";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{[*:0]const u8}, void);
        };

        pub const copy = struct {
            pub const name = "copy";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{[*:0]const u8}, void);
        };

        pub const rerun = struct {
            pub const name = "rerun";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{[*:0]const u8}, void);
        };
    };

    const Private = struct {
        dialog: *adw.Dialog,
        workspace_label: *gtk.Label,
        summary_label: *gtk.Label,
        command_view: *gtk.ListView,
        command_model: *gtk.SingleSelection,
        command_source: *gio.ListStore,
        details_view: *gtk.TextView,
        details_buffer: *gtk.TextBuffer = undefined,
        active_history_id: ?[:0]u8 = null,

        pub var offset: c_int = 0;
    };

    pub fn new() *Self {
        const self = gobject.ext.newInstance(Self, .{});
        _ = self.refSink();
        return self.ref();
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        const priv = self.private();
        priv.details_buffer = gtk.TextBuffer.new(null);
        priv.details_view.setBuffer(priv.details_buffer);
    }

    fn clearState(self: *Self) void {
        const priv = self.private();
        const alloc = Application.default().allocator();
        if (priv.active_history_id) |value| {
            alloc.free(value);
            priv.active_history_id = null;
        }
        priv.command_source.removeAll();
    }

    fn dispose(self: *Self) callconv(.c) void {
        self.clearState();
        const priv = self.private();
        priv.details_view.setBuffer(null);
        priv.details_buffer.unref();
        gtk.Widget.disposeTemplate(self.as(gtk.Widget), getGObjectType());
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const refSink = C.refSink;
    pub const unref = C.unref;
    const private = C.private;
};
```

The skeleton is completed by the following steps in this task: refresh/label helpers, recent-command row object, row binding, action callbacks, presentation, and `Class.init` template registration. Do not run a build with only the skeleton in place.

- [ ] **Step 4: Implement refresh and labels**

In `WorkspaceDashboardDialog`, add:

```zig
    fn setLabel(label: *gtk.Label, text: []const u8) void {
        const alloc = std.heap.c_allocator;
        const z = alloc.dupeZ(u8, text) catch return;
        defer alloc.free(z);
        label.setLabel(z);
    }

    fn setDetails(self: *Self, text: []const u8) void {
        const alloc = std.heap.c_allocator;
        const z = alloc.dupeZ(u8, text) catch return;
        defer alloc.free(z);
        self.private().details_buffer.setText(z.ptr, @intCast(text.len));
    }

    fn refresh(self: *Self) void {
        const priv = self.private();
        const alloc = std.heap.c_allocator;
        self.clearState();

        const status = Application.default().activeWorkspaceDashboardStatus(
            alloc,
            8,
        ) catch |err| {
            log.warn("failed to refresh dashboard: {}", .{err});
            setLabel(priv.workspace_label, "Unable to read workspace dashboard");
            setLabel(priv.summary_label, "");
            self.setDetails("");
            return;
        };
        defer status.deinit(alloc);

        if (status.workspace.active_history_id) |history_id| {
            priv.active_history_id = Application.default().allocator().dupeZ(u8, history_id) catch null;
        }

        var tab_buf: [32]u8 = undefined;
        const active_tab_text = if (status.workspace.active_tab) |idx|
            std.fmt.bufPrint(&tab_buf, "{d}", .{idx}) catch "unknown"
        else
            "unknown";

        const workspace_text = std.fmt.allocPrint(
            alloc,
            "{s}\n{s}\nTabs: {d}  Active tab: {s}",
            .{
                status.workspace.name,
                status.workspace.current_pwd,
                status.workspace.tab_count,
                active_tab_text,
            },
        ) catch return;
        defer alloc.free(workspace_text);
        setLabel(priv.workspace_label, workspace_text);

        const branch = status.git.status.branch orelse "no branch";
        const repo_state = if (status.git.status.is_repo)
            if (status.git.status.dirty) "dirty" else "clean"
        else
            "not a git repository";
        const summary_text = std.fmt.allocPrint(
            alloc,
            "Git: {s} - {s} - staged {d}, unstaged {d}\nHistory: commands {d}, transcripts {d}, bytes {d}",
            .{
                branch,
                repo_state,
                status.git.staged_count,
                status.git.unstaged_count,
                status.storage.command_count,
                status.storage.transcript_file_count,
                status.storage.total_bytes,
            },
        ) catch return;
        defer alloc.free(summary_text);
        setLabel(priv.summary_label, summary_text);

        for (status.recent_commands.items) |record| {
            const item = DashboardCommand.new(record) catch |err| {
                log.warn("failed to create dashboard command row: {}", .{err});
                continue;
            };
            priv.command_source.append(item.as(gobject.Object));
            item.unref();
        }

        self.setDetails("Select a recent command to inspect its metadata.");
    }
```

- [ ] **Step 5: Add row object and row binding**

Use the same arena-backed property pattern as `HistoryCommand`:

```zig
const DashboardCommand = extern struct {
    const Self = @This();
    pub const Parent = gobject.Object;
    parent: Parent,

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "TermplexDashboardCommand",
        .instanceInit = &init,
        .classInit = Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const properties = struct {
        pub const command = struct {
            pub const name = "command";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = propGetCommand,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };

        pub const metadata = struct {
            pub const name = "metadata";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = propGetMetadata,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };

        pub const @"history-id" = struct {
            pub const name = "history-id";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = propGetHistoryId,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };
    };

    const Private = struct {
        arena: ArenaAllocator,
        command_text: ?[:0]const u8 = null,
        metadata_text: ?[:0]const u8 = null,
        history_id_text: ?[:0]const u8 = null,
        pub var offset: c_int = 0;
    };

    pub fn new(record: terminal_history_db.CommandRecord) Allocator.Error!*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();
        const priv = self.private();
        const alloc = priv.arena.allocator();
        priv.command_text = try alloc.dupeZ(u8, record.command);
        priv.history_id_text = try alloc.dupeZ(u8, record.history_id);
        priv.metadata_text = try std.fmt.allocPrintZ(
            alloc,
            "{s} - {s} - {s}",
            .{ record.workspace_name, record.source, record.started_at },
        );
        return self;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        self.private().arena = .init(Application.default().allocator());
    }

    fn finalize(self: *Self) callconv(.c) void {
        self.private().arena.deinit();
        gobject.Object.virtual_methods.finalize.call(Class.parent, self.as(Parent));
    }

    fn propGetCommand(self: *Self) ?[:0]const u8 {
        return self.private().command_text;
    }

    fn propGetMetadata(self: *Self) ?[:0]const u8 {
        return self.private().metadata_text;
    }

    fn propGetHistoryId(self: *Self) ?[:0]const u8 {
        return self.private().history_id_text;
    }

    fn command(self: *Self) ?[:0]const u8 {
        return self.private().command_text;
    }

    fn historyId(self: *Self) ?[:0]const u8 {
        return self.private().history_id_text;
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.registerProperties(class, &.{
                properties.command.impl,
                properties.metadata.impl,
                properties.@"history-id".impl,
            });
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
    };
};
```

- [ ] **Step 6: Add action callbacks and presentation**

Implement callbacks:

```zig
    fn selectedCommand(self: *Self) ?*DashboardCommand {
        const object = self.private().command_model.as(gio.ListModel).getObject(
            self.private().command_model.getSelected(),
        ) orelse return null;
        return gobject.ext.cast(DashboardCommand, object) orelse {
            object.unref();
            return null;
        };
    }

    fn dialogClosed(_: *adw.Dialog, self: *WorkspaceDashboardDialog) callconv(.c) void {
        self.unref();
    }

    fn refreshClicked(_: *gtk.Button, self: *WorkspaceDashboardDialog) callconv(.c) void {
        self.refresh();
    }

    fn commandActivated(_: *gtk.ListView, pos: c_uint, self: *WorkspaceDashboardDialog) callconv(.c) void {
        const object = self.private().command_model.as(gio.ListModel).getObject(pos) orelse return;
        const item = gobject.ext.cast(DashboardCommand, object) orelse {
            object.unref();
            return;
        };
        defer item.unref();

        const command = item.command() orelse return;
        signals.rerun.impl.emit(self, null, .{command.ptr}, null);
    }

    fn commandHistoryClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        signals.@"open-command-history".impl.emit(self, null, .{}, null);
    }

    fn sourceControlClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        signals.@"open-source-control".impl.emit(self, null, .{}, null);
    }

    fn storageClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        signals.@"open-storage".impl.emit(self, null, .{}, null);
    }

    fn transcriptClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const history_id = self.private().active_history_id orelse return;
        signals.@"open-transcript".impl.emit(self, null, .{history_id.ptr}, null);
    }

    fn commandTranscriptClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const item = self.selectedCommand() orelse return;
        defer item.unref();
        const history_id = item.historyId() orelse return;
        signals.@"open-transcript".impl.emit(self, null, .{history_id.ptr}, null);
    }

    fn copyCommandClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const item = self.selectedCommand() orelse return;
        defer item.unref();
        const command = item.command() orelse return;
        signals.copy.impl.emit(self, null, .{command.ptr}, null);
    }

    fn rerunCommandClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const item = self.selectedCommand() orelse return;
        defer item.unref();
        const command = item.command() orelse return;
        signals.rerun.impl.emit(self, null, .{command.ptr}, null);
    }
```

Add `toggle(self: *Self, window: *Window)` like the other dialogs:

```zig
    pub fn toggle(self: *Self, window: *Window) void {
        const priv = self.private();
        if (priv.dialog.as(gtk.Widget).getRealized() != 0) {
            _ = priv.dialog.close();
            return;
        }
        self.refresh();
        priv.dialog.present(window.as(gtk.Widget));
    }
```

- [ ] **Step 7: Register template children and callbacks**

In `Class.init`, ensure:

```zig
            gobject.ext.ensureType(DashboardCommand);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "workspace-dashboard-dialog",
                }),
            );

            class.bindTemplateChildPrivate("dialog", .{});
            class.bindTemplateChildPrivate("workspace_label", .{});
            class.bindTemplateChildPrivate("summary_label", .{});
            class.bindTemplateChildPrivate("command_view", .{});
            class.bindTemplateChildPrivate("command_model", .{});
            class.bindTemplateChildPrivate("command_source", .{});
            class.bindTemplateChildPrivate("details_view", .{});

            class.bindTemplateCallback("closed", &dialogClosed);
            class.bindTemplateCallback("refresh_clicked", &refreshClicked);
            class.bindTemplateCallback("command_history_clicked", &commandHistoryClicked);
            class.bindTemplateCallback("transcript_clicked", &transcriptClicked);
            class.bindTemplateCallback("source_control_clicked", &sourceControlClicked);
            class.bindTemplateCallback("storage_clicked", &storageClicked);
            class.bindTemplateCallback("copy_command_clicked", &copyCommandClicked);
            class.bindTemplateCallback("rerun_command_clicked", &rerunCommandClicked);
            class.bindTemplateCallback("command_transcript_clicked", &commandTranscriptClicked);
            class.bindTemplateCallback("command_activated", &commandActivated);

            signals.@"open-command-history".impl.register(.{});
            signals.@"open-source-control".impl.register(.{});
            signals.@"open-storage".impl.register(.{});
            signals.@"open-transcript".impl.register(.{});
            signals.copy.impl.register(.{});
            signals.rerun.impl.register(.{});

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
```

- [ ] **Step 8: Build to catch Blueprint/class errors**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig fmt src/apprt/gtk/class/workspace_dashboard_dialog.zig src/apprt/gtk/build/gresource.zig
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

Expected: PASS after fixing any compile issues caused by GTK binding names.

### Task 5: Window Wiring And Menu Action

**Files:**

- Modify: `src/apprt/gtk/class/window.zig`
- Modify: `src/apprt/gtk/ui/1.5/window.blp`

- [ ] **Step 1: Import and store the dialog**

Add with the other Termplex dialogs:

```zig
const WorkspaceDashboardDialog = @import("workspace_dashboard_dialog.zig").WorkspaceDashboardDialog;
```

In `Private`, add:

```zig
        workspace_dashboard_dialog: WeakRef(WorkspaceDashboardDialog) = .empty,
```

- [ ] **Step 2: Add the window action**

In the actions list, add near the other Termplex actions:

```zig
            .init("termplex-workspace-dashboard", actionTermplexWorkspaceDashboard, null),
```

Add the action handler:

```zig
    fn actionTermplexWorkspaceDashboard(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.toggleWorkspaceDashboard();
    }
```

- [ ] **Step 3: Add dialog creation and signal wiring**

Add near the other dialog helpers:

```zig
    pub fn toggleWorkspaceDashboard(self: *Window) void {
        const priv = self.private();

        const dialog = priv.workspace_dashboard_dialog.get() orelse dialog: {
            const dialog = WorkspaceDashboardDialog.new();
            _ = WorkspaceDashboardDialog.signals.@"open-command-history".connect(
                dialog,
                *Window,
                signalDashboardOpenCommandHistory,
                self,
                .{},
            );
            _ = WorkspaceDashboardDialog.signals.@"open-source-control".connect(
                dialog,
                *Window,
                signalDashboardOpenSourceControl,
                self,
                .{},
            );
            _ = WorkspaceDashboardDialog.signals.@"open-storage".connect(
                dialog,
                *Window,
                signalDashboardOpenStorage,
                self,
                .{},
            );
            _ = WorkspaceDashboardDialog.signals.@"open-transcript".connect(
                dialog,
                *Window,
                signalDashboardOpenTranscript,
                self,
                .{},
            );
            _ = WorkspaceDashboardDialog.signals.copy.connect(
                dialog,
                *Window,
                signalDashboardCopyCommand,
                self,
                .{},
            );
            _ = WorkspaceDashboardDialog.signals.rerun.connect(
                dialog,
                *Window,
                signalDashboardRerunCommand,
                self,
                .{},
            );
            priv.workspace_dashboard_dialog.set(dialog);
            break :dialog dialog;
        };
        defer dialog.unref();

        dialog.toggle(self);
    }
```

Add signal handlers:

```zig
    fn signalDashboardOpenCommandHistory(_: *WorkspaceDashboardDialog, self: *Self) callconv(.c) void {
        self.toggleCommandHistory();
    }

    fn signalDashboardOpenSourceControl(_: *WorkspaceDashboardDialog, self: *Self) callconv(.c) void {
        self.toggleSourceControl();
    }

    fn signalDashboardOpenStorage(_: *WorkspaceDashboardDialog, self: *Self) callconv(.c) void {
        self.toggleStorageManagement();
    }

    fn signalDashboardOpenTranscript(_: *WorkspaceDashboardDialog, history_id: [*:0]const u8, self: *Self) callconv(.c) void {
        if (!self.showTranscriptViewer(std.mem.span(history_id))) {
            self.addToast(i18n._("Unable to open transcript"));
        }
    }

    fn signalDashboardCopyCommand(_: *WorkspaceDashboardDialog, command: [*:0]const u8, self: *Self) callconv(.c) void {
        self.as(gtk.Widget).getClipboard().setText(command);
        self.addToast(i18n._("Copied command to clipboard"));
    }

    fn signalDashboardRerunCommand(_: *WorkspaceDashboardDialog, command: [*:0]const u8, self: *Self) callconv(.c) void {
        const command_text = std.mem.span(command);
        const alloc = Application.default().allocator();
        const text = std.fmt.allocPrint(alloc, "{s}\n", .{command_text}) catch return;
        defer alloc.free(text);
        if (self.writeTextToActiveSurface(text)) {
            self.addToast(i18n._("Command sent"));
        }
    }
```

- [ ] **Step 4: Add menu item**

In `src/apprt/gtk/ui/1.5/window.blp`, add before Command History:

```blueprint
    item {
      label: _("Workspace Dashboard...");
      action: "win.termplex-workspace-dashboard";
    }
```

- [ ] **Step 5: Build and run E2E**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig fmt src/apprt/gtk/class/window.zig src/apprt/gtk/ui/1.5/window.blp
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
/opt/zig-x86_64-linux-0.15.2/zig build e2e -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

Expected: PASS.

### Task 6: Documentation And Roadmap Update

**Files:**

- Modify: `docs/superpowers/plans/2026-05-03-termplex-roadmap-implementation-sequence.md`
- Modify: `test/e2e/README.md` if it lists covered flows.

- [ ] **Step 1: Update roadmap status**

In the roadmap sequence:

- Mark `Transcript Viewer And Replay UI` as completed and committed.
- Mark `Workspace Dashboard` as the active next implementation phase.
- Point the detailed plan to `docs/superpowers/plans/2026-05-05-workspace-dashboard.md`.

- [ ] **Step 2: Update E2E README**

In `test/e2e/README.md`, update the first paragraph so the coverage list includes dashboard status/presentation. The sentence should include:

```markdown
- Workspace dashboard status and presentation through `termplex-ctl dashboard status/show`
```

- [ ] **Step 3: Run docs diff check**

Run:

```bash
git diff --check
```

Expected: PASS.

### Task 7: Full Verification And Commit

**Files:**

- All changed files from Tasks 1-6.

- [ ] **Step 1: Format**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig fmt .
```

Expected: PASS.

- [ ] **Step 2: Python syntax check**

Run:

```bash
python3 -m py_compile test/e2e/termplex_e2e.py tools/termplex-ctl
```

Expected: PASS.

- [ ] **Step 3: Unit tests**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell
```

Expected: PASS. Existing terminal/parser warning output is acceptable only if the command exits 0.

- [ ] **Step 4: GTK build**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

Expected: PASS.

- [ ] **Step 5: E2E**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build e2e -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

Expected: PASS.

- [ ] **Step 6: Whitespace check**

Run:

```bash
git diff --check
```

Expected: PASS.

- [ ] **Step 7: Commit**

Run:

```bash
git add test/e2e/termplex_e2e.py tools/termplex-ctl src/apprt/gtk/class/application.zig src/apprt/gtk/class/workspace_dashboard_dialog.zig src/apprt/gtk/ui/1.5/workspace-dashboard-dialog.blp src/apprt/gtk/build/gresource.zig src/apprt/gtk/class/window.zig src/apprt/gtk/ui/1.5/window.blp docs/superpowers/plans/2026-05-03-termplex-roadmap-implementation-sequence.md test/e2e/README.md
git commit -m "feat: add workspace dashboard"
```


## Security And Privacy Requirements

- Keep dashboard data entirely local.
- Do not upload workspace names, paths, git remotes, command history, transcript metadata, storage paths, or storage counts.
- Do not display transcript bodies in the dashboard. Use the transcript viewer for output inspection.
- Do not display git diffs in the dashboard. Use the source-control panel for diff inspection.
- Do not log command text from dashboard refresh or action failures.
- Keep recent command lists bounded in IPC and UI.
- Reuse existing copy/rerun/transcript actions so dashboard behavior matches Command History.
- Reuse existing source-control and storage services so destructive actions remain outside the dashboard.

## Self-Review

- Spec coverage: The plan covers workspace identity, recent commands, quick actions, git summary, storage summary, CLI/IPC support, UI presentation, and E2E coverage.
- Placeholder scan: The plan uses concrete files, commands, API fields, and code shapes. Deferred features are explicitly out of scope.
- Type consistency: Dashboard data is keyed by existing workspace indexes/IDs and `history_id`; command rows reuse `terminal_history_db.CommandRecord`; git/storage summaries reuse existing core service result types.
