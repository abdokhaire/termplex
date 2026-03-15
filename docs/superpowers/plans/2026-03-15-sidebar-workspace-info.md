# Sidebar Workspace Info Enhancement — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show workspace directory, git branch, and port information for all workspaces in the sidebar, with a right-click "Change Directory" action.

**Architecture:** Extend `WorkspaceTab` with a directory label row and restructured port display (primary port + "+N" badge with expand/collapse). Add per-workspace git state arrays to `application.zig` with a 10-second combined probe timer replacing the 30-second port-only timer. Wire a "Change Directory" context menu item through sidebar callbacks to application state.

**Tech Stack:** Zig 0.15.2, GTK4 (gtk.Box, gtk.Label, gtk.GestureClick, gtk.Popover), GLib timers, git_probe module

---

## File Structure

| File | Responsibility |
|------|---------------|
| `src/apprt/gtk/class/workspace_tab.zig` | Widget layout: add dir_label (row2), restructure port area (primary + badge + detail box), expand/collapse click handler, startChangeDir/finishChangeDir |
| `src/apprt/gtk/class/sidebar.zig` | Context menu: add "Change Directory..." item, on_change_dir callback, wire to WorkspaceTab.startChangeDir |
| `src/apprt/gtk/class/window.zig` | Call sites: update 17+ calls to sidebar.addWorkspace/updateWorkspace with dir_text param, add termplexOnChangeDirWorkspace/termplexOnChangeDirComplete handlers, update setManagementCallbacks call |
| `src/apprt/gtk/class/application.zig` | State: per-workspace git arrays, 10s combined timer, refreshAllWorkspaceSidebars, formatDirDisplay helper, workspaceDir accessor |
| `src/apprt/gtk/css/style.css` | Styles: .termplex-tab-dir, .termplex-port-badge, .termplex-port-detail |

---

## Chunk 1: WorkspaceTab Widget Restructuring

### Task 1: Add Directory Label to WorkspaceTab

**Files:**
- Modify: `src/apprt/gtk/class/workspace_tab.zig:36-57` (Private struct)
- Modify: `src/apprt/gtk/class/workspace_tab.zig:59-108` (init function)
- Modify: `src/apprt/gtk/class/workspace_tab.zig:120-162` (update function)

- [ ] **Step 1: Add dir_label field to Private struct**

In `workspace_tab.zig`, add the `dir_label` field after `port_label` in the Private struct:

```zig
// In Private struct, after port_label field (line ~44):

/// Label showing the workspace directory path (dim gray, ellipsized).
dir_label: *gtk.Label = undefined,
```

- [ ] **Step 2: Add row2 (dir_label) to init, shift branch to row3**

In `init`, after the row1 block (line ~98), insert a new row2 for the directory label. The current row2 (branch) becomes row3:

```zig
        // -- Row 2: directory label (new) --
        const row2 = gtk.Box.new(.horizontal, 0);
        content.append(row2.as(gtk.Widget));

        const dir_label = gtk.Label.new(null);
        dir_label.setXalign(0.0);
        dir_label.as(gtk.Widget).addCssClass("termplex-tab-dir");
        dir_label.as(gtk.Widget).setHexpand(1);
        dir_label.setEllipsize(@intFromEnum(std.meta.stringToEnum(pango.EllipsizeMode, "end") orelse .end));
        dir_label.setMaxWidthChars(25);
        priv.dir_label = dir_label;
        row2.append(dir_label.as(gtk.Widget));

        // -- Row 3: branch label (was row2) --
        const row3 = gtk.Box.new(.horizontal, 0);
        content.append(row3.as(gtk.Widget));
```

**Important:** We need to check how `pango.EllipsizeMode` is available. The GTK Zig bindings expose `setEllipsize` on `gtk.Label` but we need to verify the enum. Let the implementer check the actual binding — if `pango` isn't directly importable, use the raw integer value for `PANGO_ELLIPSIZE_END` which is `3`:

```zig
        dir_label.setEllipsize(3); // PANGO_ELLIPSIZE_END
```

Update the branch label to use `row3` instead of `row2`:

```zig
        // The existing branch_label code stays the same, but appended to row3:
        const branch_label = gtk.Label.new(null);
        branch_label.setXalign(0.0);
        branch_label.as(gtk.Widget).addCssClass("termplex-tab-branch");
        priv.branch_label = branch_label;
        row3.append(branch_label.as(gtk.Widget));
```

- [ ] **Step 3: Add dir_text parameter to update method**

Change the `update` method signature to accept `dir_text`:

```zig
    pub fn update(
        self: *Self,
        name: ?[:0]const u8,
        port_text: ?[:0]const u8,
        branch_text: ?[:0]const u8,
        dir_text: ?[:0]const u8,
        is_active: bool,
        has_unread: bool,
    ) void {
```

Add directory label update logic after the port label update block and before the branch label block:

```zig
        // Update directory label. Unlike port/branch, preserve existing
        // text when null — directory doesn't change during workspace switching
        // and callers pass null to mean "no change".
        if (dir_text) |d| {
            priv.dir_label.setLabel(d);
            priv.dir_label.as(gtk.Widget).setVisible(1);
        }
        // When dir_text is null, keep current label text visible (no else branch).
```

- [ ] **Step 4: Add CSS style for directory label**

In `src/apprt/gtk/css/style.css`, add after the `.termplex-tab-branch` block (line ~227):

```css
.termplex-tab-dir {
  color: #94a3b8;
  font-size: 10px;
}
```

- [ ] **Step 5: Update sidebar.zig signatures**

Two methods in `sidebar.zig` need the new `dir_text` parameter:

**6a. `addWorkspace`** (line 320) — add `dir_text` parameter and pass through:

```zig
    pub fn addWorkspace(
        self: *Self,
        name: ?[:0]const u8,
        port_text: ?[:0]const u8,
        branch_text: ?[:0]const u8,
        dir_text: ?[:0]const u8,
    ) void {
        // ...
        tab.update(name, port_text, branch_text, dir_text, false, false);
        // ...
    }
```

**6b. `updateWorkspace`** (line 386) — add `dir_text` parameter and pass through:

```zig
    pub fn updateWorkspace(
        self: *Self,
        index: u32,
        name: ?[:0]const u8,
        port_text: ?[:0]const u8,
        branch_text: ?[:0]const u8,
        dir_text: ?[:0]const u8,
        is_active: bool,
        has_unread: bool,
    ) void {
        // ...
        tab.update(name, port_text, branch_text, dir_text, is_active, has_unread);
        // ...
    }
```

- [ ] **Step 7: Add formatDirDisplay helper to application.zig**

Add a public helper method and a `workspaceDir` accessor to `application.zig`:

```zig
    /// Return the directory string for a workspace, or null if out of range.
    pub fn workspaceDir(self: *Self, idx: u32) ?[:0]const u8 {
        const priv = self.private();
        if (idx >= priv.workspace_dirs.items.len) return null;
        return priv.workspace_dirs.items[idx];
    }

    /// Format a workspace directory for display, replacing $HOME with ~.
    /// Returns null if the index is out of range.
    pub fn formatDirDisplay(self: *Self, idx: u32, buf: *[512]u8) ?[:0]const u8 {
        const priv = self.private();
        if (idx >= priv.workspace_dirs.items.len) return null;
        const dir = priv.workspace_dirs.items[idx];
        const home = std.posix.getenv("HOME") orelse "";

        if (home.len > 0 and std.mem.startsWith(u8, dir, home)) {
            return std.fmt.bufPrintZ(buf, "~{s}", .{dir[home.len..]}) catch null;
        }
        return dir; // Already a [:0]const u8, return as-is
    }
```

- [ ] **Step 8: Update all call sites in window.zig (17 locations)**

`window.zig` contains the majority of `sidebar.addWorkspace` and `sidebar.updateWorkspace` calls. Each needs the new `dir_text` parameter.

**Pattern for updating calls:** Use `app.formatDirDisplay(idx, &dir_buf)` where a `var dir_buf: [512]u8 = undefined;` is declared in the function scope, or pass `null` for quick workspace-switching updates where the dir doesn't change.

**All call sites to update (pass `null` for dir_text in workspace-switching calls since the text doesn't change):**

- Line 334: `sidebar.addWorkspace(name, null, null)` → `sidebar.addWorkspace(name, null, null, null)` (initial build, Task 10 will add real dir text)
- Line 339: `sidebar.updateWorkspace(activeIdx, name, null, null, true, false)` → add `null` for dir_text
- Line 1483: `sidebar.updateWorkspace(old_idx, ...)` → add `null` for dir_text
- Line 1494: `sidebar.updateWorkspace(index, ...)` → add `null` for dir_text
- Line 1525: `sidebar.addWorkspace(name, null, null)` → add `null` for dir_text
- Line 1529: `sidebar.updateWorkspace(old_idx, ...)` → add `null` for dir_text
- Line 1540: `sidebar.updateWorkspace(new_idx, ...)` → add `null` for dir_text
- Line 1589: `sidebar.updateWorkspace(index, ...)` → add `null` for dir_text
- Line 1590: `sidebar.updateWorkspace(new_idx, ...)` → add `null` for dir_text
- Line 2609: `sidebar.updateWorkspace(old_idx, ...)` → add `null` for dir_text
- Line 2619: `sidebar.addWorkspace(name, null, null)` → add `null` for dir_text
- Line 2621: `sidebar.updateWorkspace(new_idx, ...)` → add `null` for dir_text
- Line 2658: `sidebar.updateWorkspace(new_active, ...)` → add `null` for dir_text
- Line 2678: `sidebar.updateWorkspace(current, ...)` → add `null` for dir_text
- Line 2680: `sidebar.updateWorkspace(next, ...)` → add `null` for dir_text
- Line 2702: `sidebar.updateWorkspace(current, ...)` → add `null` for dir_text
- Line 2704: `sidebar.updateWorkspace(prev, ...)` → add `null` for dir_text

**Note:** Passing `null` for dir_text in these switching calls is correct — the `update` method preserves existing dir label text when dir_text is null (unlike port/branch which clear on null). The 10s timer's `refreshAllWorkspaceSidebars` will update real values periodically.

- [ ] **Step 9: Update call sites in application.zig**

Update `updateSidebarForAllWindows` to accept and forward `dir_text`:

```zig
    fn updateSidebarForAllWindows(
        self: *Self,
        active_idx: u32,
        name: ?[:0]const u8,
        port_text: ?[:0]const u8,
        branch_text: ?[:0]const u8,
        dir_text: ?[:0]const u8,
    ) void {
        const Ctx = struct {
            active_idx: u32,
            name: ?[:0]const u8,
            port_text: ?[:0]const u8,
            branch_text: ?[:0]const u8,
            dir_text: ?[:0]const u8,
        };
        var ctx = Ctx{
            .active_idx = active_idx,
            .name = name,
            .port_text = port_text,
            .branch_text = branch_text,
            .dir_text = dir_text,
        };
        const list = self.as(gtk.Application).getWindows();
        list.foreach(struct {
            fn cb(data: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) void {
                const c: *Ctx = @ptrCast(@alignCast(userdata orelse return));
                const ptr: *gtk.Window = @ptrCast(@alignCast(data orelse return));
                const win = gobject.ext.cast(Window, ptr) orelse return;
                win.getSidebar().updateWorkspace(c.active_idx, c.name, c.port_text, c.branch_text, c.dir_text, true, false);
            }
        }.cb, @ptrCast(&ctx));
    }
```

Update `updateSidebarGitState` to compute and pass dir text:

```zig
    fn updateSidebarGitState(self: *Self) void {
        const priv = self.private();
        const active_idx = priv.active_workspace_idx;
        const name = if (active_idx < priv.workspace_names.items.len)
            priv.workspace_names.items[active_idx]
        else
            return;

        var branch_buf: [256]u8 = undefined;
        const branch_z: ?[:0]const u8 = blk: {
            const b = priv.git_branch orelse break :blk null;
            const label = std.fmt.bufPrintZ(
                &branch_buf,
                "{s}{s}",
                .{ b, if (priv.git_dirty) "*" else "" },
            ) catch break :blk null;
            break :blk label;
        };

        var dir_buf: [512]u8 = undefined;
        const dir_z: ?[:0]const u8 = self.formatDirDisplay(active_idx, &dir_buf);

        updateSidebarForAllWindows(self, active_idx, name, priv.listening_ports_str, branch_z, dir_z);
    }
```

Apply the same `dir_buf`/`formatDirDisplay` pattern to `updateSidebarPortState` (needed for the burst port scan path which still calls this function directly).

Update `enableOrchestration` call sites:
- `sidebar.addWorkspace("ORCHESTRATOR", null, null)` → `sidebar.addWorkspace("ORCHESTRATOR", null, null, dir_text)` where `dir_text` is computed via `formatDirDisplay`
- `sidebar.updateWorkspace(idx, "ORCHESTRATOR", null, null, false, false)` → add dir_text param

- [ ] **Step 10: Build and verify**

Run: `rm -rf .zig-cache && /opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell 2>&1 | head -30`
Expected: Clean build (CSS changes require cache clear)

- [ ] **Step 11: Commit**

```bash
git add src/apprt/gtk/class/workspace_tab.zig src/apprt/gtk/class/sidebar.zig src/apprt/gtk/class/window.zig src/apprt/gtk/class/application.zig src/apprt/gtk/css/style.css
git commit -m "feat(sidebar): add directory label to workspace tabs

Add a new row showing the workspace directory path between the name
and git branch rows. Directory uses ~ shorthand for \$HOME and is
ellipsized for long paths. Update all call sites (sidebar, window,
application) with new dir_text parameter."
```

---

### Task 2: Restructure Port Display (Primary + Badge)

**Files:**
- Modify: `src/apprt/gtk/class/workspace_tab.zig:36-57` (Private struct)
- Modify: `src/apprt/gtk/class/workspace_tab.zig:59-108` (init function)
- Modify: `src/apprt/gtk/class/workspace_tab.zig:120-162` (update function)
- Modify: `src/apprt/gtk/css/style.css`

- [ ] **Step 1: Replace port_label with port area in Private struct**

Replace the single `port_label` field with the new port area fields:

```zig
        /// Box containing port_primary_label and port_badge_label (horizontal).
        port_box: *gtk.Box = undefined,

        /// Label showing the first port (e.g., ":3000"), green.
        port_primary_label: *gtk.Label = undefined,

        /// Label showing "+N" badge for additional ports.
        port_badge_label: *gtk.Label = undefined,

        /// Vertical box showing all ports, hidden by default.
        port_detail_box: *gtk.Box = undefined,

        /// Whether the port detail box is currently expanded.
        ports_expanded: bool = false,
```

Remove the old `port_label` field.

- [ ] **Step 2: Build port area widgets in init**

Replace the port_label creation in init (the block after `name_label` in row1) with:

```zig
        // -- Port area: primary port + "+N" badge --
        const port_box = gtk.Box.new(.horizontal, 2);
        priv.port_box = port_box;
        row1.append(port_box.as(gtk.Widget));

        const port_primary_label = gtk.Label.new(null);
        port_primary_label.setXalign(1.0);
        port_primary_label.as(gtk.Widget).addCssClass("termplex-tab-port");
        priv.port_primary_label = port_primary_label;
        port_box.append(port_primary_label.as(gtk.Widget));

        const port_badge_label = gtk.Label.new(null);
        port_badge_label.as(gtk.Widget).addCssClass("termplex-port-badge");
        priv.port_badge_label = port_badge_label;
        port_box.append(port_badge_label.as(gtk.Widget));

        // Click handler on badge to toggle port detail expansion.
        const badge_click = gtk.GestureClick.new();
        badge_click.as(gtk.GestureSingle).setButton(1); // left-click
        _ = gtk.GestureClick.signals.pressed.connect(
            badge_click,
            *Self,
            &onPortBadgeClick,
            self,
            .{},
        );
        port_badge_label.as(gtk.Widget).addController(badge_click.as(gtk.EventController));
```

After row3 (branch label), add the port detail box:

```zig
        // -- Port detail box (hidden by default, shown when "+N" badge clicked) --
        const port_detail_box = gtk.Box.new(.vertical, 1);
        port_detail_box.as(gtk.Widget).addCssClass("termplex-port-detail");
        port_detail_box.as(gtk.Widget).setVisible(0);
        priv.port_detail_box = port_detail_box;
        content.append(port_detail_box.as(gtk.Widget));
```

- [ ] **Step 3: Add badge click handler**

```zig
    fn onPortBadgeClick(
        _: *gtk.GestureClick,
        _: c_int,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.ports_expanded = !priv.ports_expanded;
        priv.port_detail_box.as(gtk.Widget).setVisible(@intFromBool(priv.ports_expanded));
    }
```

- [ ] **Step 4: Update port display logic in update method**

Replace the old port_label update block with port parsing and display logic:

```zig
        // Update port display.
        // port_text format: ":3000 :8080 :5432" (space-separated, from runPortScan)
        if (port_text) |p| {
            if (p.len == 0) {
                priv.port_box.as(gtk.Widget).setVisible(0);
                priv.port_detail_box.as(gtk.Widget).setVisible(0);
                priv.ports_expanded = false;
            } else {
                priv.port_box.as(gtk.Widget).setVisible(1);

                // Count ports by counting ':' characters.
                var port_count: u32 = 0;
                for (p) |ch| {
                    if (ch == ':') port_count += 1;
                }

                if (port_count <= 1) {
                    // Single port: show as-is, hide badge.
                    priv.port_primary_label.setLabel(p);
                    priv.port_badge_label.as(gtk.Widget).setVisible(0);
                    priv.port_detail_box.as(gtk.Widget).setVisible(0);
                    priv.ports_expanded = false;
                } else {
                    // Multiple ports: show first port + "+N" badge.
                    // Find end of first port (next space).
                    const first_end = std.mem.indexOfScalar(u8, p, ' ') orelse p.len;
                    var first_buf: [16]u8 = undefined;
                    const first_port = std.fmt.bufPrintZ(&first_buf, "{s}", .{p[0..first_end]}) catch p;
                    priv.port_primary_label.setLabel(first_port);

                    var badge_buf: [8]u8 = undefined;
                    const badge_text = std.fmt.bufPrintZ(&badge_buf, "+{d}", .{port_count - 1}) catch "+?";
                    priv.port_badge_label.setLabel(badge_text);
                    priv.port_badge_label.as(gtk.Widget).setVisible(1);

                    // Rebuild port detail box contents.
                    // Remove existing children.
                    const detail_widget = priv.port_detail_box.as(gtk.Widget);
                    while (detail_widget.getFirstChild()) |child| {
                        child.unparent();
                    }
                    // Add one label per port.
                    var iter = std.mem.splitScalar(u8, p, ' ');
                    while (iter.next()) |port_str| {
                        if (port_str.len == 0) continue;
                        var lbl_buf: [16]u8 = undefined;
                        const lbl_text = std.fmt.bufPrintZ(&lbl_buf, "{s}", .{port_str}) catch continue;
                        const lbl = gtk.Label.new(lbl_text);
                        lbl.setXalign(0.0);
                        lbl.as(gtk.Widget).addCssClass("termplex-tab-port");
                        priv.port_detail_box.append(lbl.as(gtk.Widget));
                    }

                    // Maintain current expansion state.
                    detail_widget.setVisible(@intFromBool(priv.ports_expanded));
                }
            }
        } else {
            priv.port_box.as(gtk.Widget).setVisible(0);
            priv.port_detail_box.as(gtk.Widget).setVisible(0);
            priv.ports_expanded = false;
        }
```

- [ ] **Step 5: Add CSS for port badge and detail box**

In `src/apprt/gtk/css/style.css`, add after `.termplex-tab-dir`:

```css
.termplex-port-badge {
  background-color: #1a3a2a;
  color: #4ade80;
  border-radius: 3px;
  padding: 0px 3px;
  font-size: 9px;
}

.termplex-port-detail {
  background-color: #131d2b;
  border-radius: 4px;
  padding: 4px 6px;
  margin-top: 2px;
}
```

- [ ] **Step 6: Build and verify**

Run: `rm -rf .zig-cache && /opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell 2>&1 | head -30`
Expected: Clean build

- [ ] **Step 7: Commit**

```bash
git add src/apprt/gtk/class/workspace_tab.zig src/apprt/gtk/css/style.css
git commit -m "feat(sidebar): restructure port display with primary port + badge

Replace single port label with primary port + '+N' badge. Left-clicking
the badge toggles an expandable detail box showing all ports. Badge and
detail box hidden when 0-1 ports."
```

---

## Chunk 2: Per-Workspace Git Probing & Combined Timer

### Task 3: Add Per-Workspace Git State Arrays

**Files:**
- Modify: `src/apprt/gtk/class/application.zig:225-246` (Private struct fields)
- Modify: `src/apprt/gtk/class/application.zig:569-584` (cleanup in deinit)
- Modify: `src/apprt/gtk/class/application.zig:740-800` (addWorkspaceWithDir)
- Modify: `src/apprt/gtk/class/application.zig:873-908` (removeWorkspace)

- [ ] **Step 1: Add per-workspace git arrays to Private**

After the `workspace_tab_views` field declaration, add:

```zig
        /// Per-workspace git branch name. Null if not a git repo.
        /// Parallel to workspace_names.
        workspace_git_branches: std.ArrayListUnmanaged(?[:0]const u8) = .empty,

        /// Per-workspace dirty flag. Parallel to workspace_names.
        workspace_git_dirty: std.ArrayListUnmanaged(bool) = .empty,
```

- [ ] **Step 2: Free git arrays in cleanup (deinit area)**

After the `workspace_tab_views.deinit(alloc)` block, add:

```zig
        // Termplex: free per-workspace git state.
        for (priv.workspace_git_branches.items) |branch_opt| {
            if (branch_opt) |b| alloc.free(b);
        }
        priv.workspace_git_branches.deinit(alloc);
        priv.workspace_git_dirty.deinit(alloc);
```

- [ ] **Step 3: Append to git arrays in addWorkspaceWithDir**

After `priv.workspace_tab_views.append(alloc, tab_view)` and before `priv.next_workspace_number += 1`, add:

```zig
        priv.workspace_git_branches.append(alloc, null) catch {
            _ = priv.workspace_tab_views.pop();
            _ = priv.workspace_dirs.pop();
            _ = priv.workspace_names.pop();
            alloc.free(name);
            alloc.free(resolved_dir);
            tab_view.as(gobject.Object).unref();
            return null;
        };
        priv.workspace_git_dirty.append(alloc, false) catch {
            _ = priv.workspace_git_branches.pop();
            _ = priv.workspace_tab_views.pop();
            _ = priv.workspace_dirs.pop();
            _ = priv.workspace_names.pop();
            alloc.free(name);
            alloc.free(resolved_dir);
            tab_view.as(gobject.Object).unref();
            return null;
        };
```

- [ ] **Step 4: Remove from git arrays in removeWorkspace**

After the `_ = priv.workspace_tab_views.orderedRemove(index);` line, add:

```zig
        // Free per-workspace git state.
        if (priv.workspace_git_branches.items[index]) |b| alloc.free(b);
        _ = priv.workspace_git_branches.orderedRemove(index);
        _ = priv.workspace_git_dirty.orderedRemove(index);
```

- [ ] **Step 5: Build and verify**

Run: `/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell 2>&1 | head -30`
Expected: Clean build

- [ ] **Step 6: Commit**

```bash
git add src/apprt/gtk/class/application.zig
git commit -m "feat(sidebar): add per-workspace git state arrays

Add workspace_git_branches and workspace_git_dirty parallel arrays
managed alongside workspace_names/dirs/tab_views."
```

---

### Task 4: Replace 30s Port Timer with 10s Combined Timer

**Files:**
- Modify: `src/apprt/gtk/class/application.zig` — timer init, callback, cleanup

- [ ] **Step 1: Replace timer initialization**

Change the timer setup (line ~994) from:

```zig
priv.port_scan_timer = glib.timeoutAdd(30000, portScanCallback, self);
```

to:

```zig
priv.port_scan_timer = glib.timeoutAdd(10000, combinedProbeCallback, self);
```

- [ ] **Step 2: Replace portScanCallback with combinedProbeCallback**

Replace the `portScanCallback` function with:

```zig
    /// GLib timer callback: runs git probing for all workspaces and port
    /// scanning for the active workspace every 10 seconds.
    fn combinedProbeCallback(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return @intFromBool(glib.SOURCE_REMOVE)));
        const priv = self.private();

        // If the timer has been cleared, stop recurring.
        if (priv.port_scan_timer == null) return @intFromBool(glib.SOURCE_REMOVE);

        const alloc = self.allocator();

        // 1. Probe git for all workspaces (skip orchestration).
        var any_git_changed = false;
        for (priv.workspace_dirs.items, 0..) |dir, i| {
            // Skip orchestration workspace.
            if (priv.orchestration_workspace_idx) |orch_idx| {
                if (i == orch_idx) continue;
            }

            var result = git_probe.probe(alloc, dir);
            defer result.deinit(alloc);

            // Check if branch or dirty state changed.
            const old_branch = priv.workspace_git_branches.items[i];
            const new_branch = result.branch;
            const old_dirty = priv.workspace_git_dirty.items[i];
            const new_dirty = result.dirty;

            const branch_changed = blk: {
                if (old_branch == null and new_branch == null) break :blk false;
                if (old_branch == null or new_branch == null) break :blk true;
                break :blk !std.mem.eql(u8, old_branch.?, new_branch.?);
            };

            if (branch_changed or old_dirty != new_dirty) {
                any_git_changed = true;

                // Update stored state.
                if (old_branch) |b| alloc.free(b);
                priv.workspace_git_branches.items[i] = if (new_branch) |b|
                    alloc.dupeZ(u8, b) catch null
                else
                    null;
                priv.workspace_git_dirty.items[i] = new_dirty;
            }
        }

        // 2. Run port scan (active workspace only, uses app PID).
        runPortScan(self);

        // 3. Refresh all workspace sidebars if git state changed.
        if (any_git_changed) {
            self.refreshAllWorkspaceSidebars();
        }

        return @intFromBool(glib.SOURCE_CONTINUE);
    }
```

- [ ] **Step 3: Update existing gitProbeCallback to also update per-workspace arrays**

In `gitProbeCallback`, after updating `priv.git_branch` and `priv.git_dirty`, also update the per-workspace arrays for the active workspace:

```zig
        // Also update per-workspace arrays for the active workspace.
        const active_idx = priv.active_workspace_idx;
        if (active_idx < priv.workspace_git_branches.items.len) {
            if (priv.workspace_git_branches.items[active_idx]) |old_b| alloc.free(old_b);
            priv.workspace_git_branches.items[active_idx] = if (result.branch) |b|
                alloc.dupeZ(u8, b) catch null
            else
                null;
            priv.workspace_git_dirty.items[active_idx] = result.dirty;
        }
```

- [ ] **Step 4: Build and verify**

Run: `/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell 2>&1 | head -30`
Expected: Clean build

- [ ] **Step 5: Commit**

```bash
git add src/apprt/gtk/class/application.zig
git commit -m "feat(sidebar): replace 30s port timer with 10s combined probe

The new timer probes git for all workspaces and runs port scan for
the active workspace. Also updates per-workspace git arrays in the
debounced git probe callback."
```

---

### Task 5: Add refreshAllWorkspaceSidebars

**Files:**
- Modify: `src/apprt/gtk/class/application.zig`

- [ ] **Step 1: Add refreshAllWorkspaceSidebars function**

Add after `updateSidebarForAllWindows`:

```zig
    /// Refresh all workspace tabs in the sidebar across all windows.
    ///
    /// Iterates every workspace, builds display text for each, and pushes
    /// updates to every open window's sidebar.
    fn refreshAllWorkspaceSidebars(self: *Self) void {
        const priv = self.private();
        const workspace_count = priv.workspace_names.items.len;

        const list = self.as(gtk.Application).getWindows();

        var i: u32 = 0;
        while (i < workspace_count) : (i += 1) {
            const name = priv.workspace_names.items[i];
            const is_active = (i == priv.active_workspace_idx);

            // ORCHESTRATOR: show only name + dir, suppress git/ports.
            const is_orchestrator = if (priv.orchestration_workspace_idx) |orch_idx| i == orch_idx else false;

            // Port text: only for active workspace, never for orchestrator.
            const port_text: ?[:0]const u8 = if (is_active and !is_orchestrator) priv.listening_ports_str else null;

            // Branch text from per-workspace arrays (suppressed for orchestrator).
            var branch_buf: [256]u8 = undefined;
            const branch_z: ?[:0]const u8 = blk: {
                if (is_orchestrator) break :blk null;
                if (i >= priv.workspace_git_branches.items.len) break :blk null;
                const b = priv.workspace_git_branches.items[i] orelse break :blk null;
                const dirty = if (i < priv.workspace_git_dirty.items.len) priv.workspace_git_dirty.items[i] else false;
                const label = std.fmt.bufPrintZ(
                    &branch_buf,
                    "{s}{s}",
                    .{ b, if (dirty) "*" else "" },
                ) catch break :blk null;
                break :blk label;
            };

            // Dir text with ~ shorthand.
            var dir_buf: [512]u8 = undefined;
            const dir_z: ?[:0]const u8 = self.formatDirDisplay(i, &dir_buf);

            // Capture values for the foreach closure.
            const Ctx = struct {
                idx: u32,
                name_val: ?[:0]const u8,
                port_val: ?[:0]const u8,
                branch_val: ?[:0]const u8,
                dir_val: ?[:0]const u8,
                active: bool,
            };
            var ctx = Ctx{
                .idx = i,
                .name_val = name,
                .port_val = port_text,
                .branch_val = branch_z,
                .dir_val = dir_z,
                .active = is_active,
            };
            list.foreach(struct {
                fn cb(data: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) void {
                    const c: *Ctx = @ptrCast(@alignCast(userdata orelse return));
                    const ptr: *gtk.Window = @ptrCast(@alignCast(data orelse return));
                    const win = gobject.ext.cast(Window, ptr) orelse return;
                    win.getSidebar().updateWorkspace(c.idx, c.name_val, c.port_val, c.branch_val, c.dir_val, c.active, false);
                }
            }.cb, @ptrCast(&ctx));
        }
    }
```

- [ ] **Step 2: Build and verify**

Run: `/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell 2>&1 | head -30`
Expected: Clean build

- [ ] **Step 3: Commit**

```bash
git add src/apprt/gtk/class/application.zig
git commit -m "feat(sidebar): add refreshAllWorkspaceSidebars

New function iterates all workspaces and pushes name, dir, git, and
port state to every open window's sidebar. Called by the 10s combined
probe timer after git state changes."
```

---

## Chunk 3: Change Directory Feature

### Task 6: Add Change Directory to Context Menu

**Files:**
- Modify: `src/apprt/gtk/class/sidebar.zig:43-75` (Private struct)
- Modify: `src/apprt/gtk/class/sidebar.zig:183-253` (onRightClick)
- Modify: `src/apprt/gtk/class/sidebar.zig:309-317` (setManagementCallbacks)

- [ ] **Step 1: Add on_change_dir callback to sidebar Private**

After `on_delete` field:

```zig
        /// Callback invoked when the user selects "Change Directory..." from the context menu.
        on_change_dir: ?*const fn (index: u32, userdata: ?*anyopaque) void = null,
```

- [ ] **Step 2: Add "Change Directory..." button to onRightClick**

In `onRightClick`, after the delete_btn block and before the popover creation, add:

```zig
        const chdir_btn = gtk.Button.newWithLabel("Change Directory...");
        chdir_btn.as(gtk.Widget).addCssClass("flat");
        _ = gtk.Button.signals.clicked.connect(
            chdir_btn,
            *Self,
            &onContextChangeDir,
            self,
            .{},
        );
        box.append(chdir_btn.as(gtk.Widget));
        chdir_btn.as(gtk.Widget).setVisible(1);
```

- [ ] **Step 3: Add onContextChangeDir handler**

After `onContextDelete`:

```zig
    fn onContextChangeDir(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.context_popover) |p| {
            p.popdown();
        }
        if (priv.on_change_dir) |cb| {
            cb(priv.context_menu_index, priv.userdata);
        }
    }
```

- [ ] **Step 4: Update setManagementCallbacks to include on_change_dir**

```zig
    pub fn setManagementCallbacks(
        self: *Self,
        on_rename: ?*const fn (index: u32, userdata: ?*anyopaque) void,
        on_delete: ?*const fn (index: u32, userdata: ?*anyopaque) void,
        on_change_dir: ?*const fn (index: u32, userdata: ?*anyopaque) void,
    ) void {
        const priv = self.private();
        priv.on_rename = on_rename;
        priv.on_delete = on_delete;
        priv.on_change_dir = on_change_dir;
    }
```

Update the call site in `window.zig` line 362 (NOT application.zig — that's where the reviewer caught a critical issue):

```zig
            sidebar.setManagementCallbacks(
                &termplexOnRenameWorkspace,
                &termplexOnDeleteWorkspace,
                &termplexOnChangeDirWorkspace,
            );
```

- [ ] **Step 5: Build and verify**

Run: `/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell 2>&1 | head -30`
Expected: May fail until Task 8 wires the callback in window.zig. Fix compile errors if any.

- [ ] **Step 6: Commit**

```bash
git add src/apprt/gtk/class/sidebar.zig src/apprt/gtk/class/window.zig
git commit -m "feat(sidebar): add 'Change Directory...' to context menu

Add on_change_dir callback to sidebar and a new menu item in the
right-click context menu, following existing rename/delete pattern.
Update setManagementCallbacks call in window.zig."
```

---

### Task 7: Add startChangeDir/finishChangeDir to WorkspaceTab

**Files:**
- Modify: `src/apprt/gtk/class/workspace_tab.zig:36-57` (Private struct)
- Modify: `src/apprt/gtk/class/workspace_tab.zig` (new methods after finishRename)

- [ ] **Step 1: Add change-dir state to Private struct**

After the rename state fields:

```zig
        /// Inline change-dir state.
        chdir_entry: ?*gtk.Entry = null,
        is_changing_dir: bool = false,
        on_chdir_complete: ?*const fn (index: u32, new_dir: [:0]const u8, userdata: ?*anyopaque) void = null,
        chdir_userdata: ?*anyopaque = null,
        chdir_index: u32 = 0,
```

- [ ] **Step 2: Add startChangeDir method**

After `finishRename`, following the same pattern:

```zig
    /// Begin inline directory change: hide the dir label, show a GtkEntry.
    pub fn startChangeDir(
        self: *Self,
        index: u32,
        on_complete: ?*const fn (u32, [:0]const u8, ?*anyopaque) void,
        userdata: ?*anyopaque,
    ) void {
        const priv = self.private();
        if (priv.is_changing_dir) return;

        priv.on_chdir_complete = on_complete;
        priv.chdir_userdata = userdata;
        priv.chdir_index = index;

        const entry = gtk.Entry.new();
        const current_dir = priv.dir_label.getLabel();
        entry.as(gtk.Editable).setText(current_dir);

        // Hide dir label, show entry in same position.
        priv.dir_label.as(gtk.Widget).setVisible(0);

        // Insert entry into row2 (parent of dir_label).
        const parent = priv.dir_label.as(gtk.Widget).getParent();
        if (parent) |p| {
            const box: *gtk.Box = @ptrCast(@alignCast(p));
            box.prepend(entry.as(gtk.Widget));
        }

        _ = entry.as(gtk.Widget).grabFocus();
        priv.chdir_entry = entry;
        priv.is_changing_dir = true;

        // Connect Enter (activate).
        _ = gtk.Entry.signals.activate.connect(entry, *Self, &onChdirActivate, self, .{});

        // Connect Escape via EventControllerKey.
        const key_controller = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(
            key_controller,
            *Self,
            &onChdirKeyPress,
            self,
            .{},
        );
        entry.as(gtk.Widget).addController(key_controller.as(gtk.EventController));
    }

    fn onChdirActivate(_: *gtk.Entry, self: *Self) callconv(.c) void {
        self.finishChangeDir(true);
    }

    fn onChdirKeyPress(
        _: *gtk.EventControllerKey,
        keyval: c_uint,
        _: c_uint,
        _: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) c_int {
        if (keyval == gdk.KEY_Escape) {
            self.finishChangeDir(false);
            return 1;
        }
        return 0;
    }

    pub fn finishChangeDir(self: *Self, confirm: bool) void {
        const priv = self.private();
        if (!priv.is_changing_dir) return;

        if (confirm) {
            if (priv.chdir_entry) |entry| {
                const text = entry.as(gtk.Editable).getText();
                const dir_slice = std.mem.span(text);
                if (dir_slice.len > 0) {
                    priv.dir_label.setLabel(text);
                    if (priv.on_chdir_complete) |cb| {
                        cb(priv.chdir_index, dir_slice, priv.chdir_userdata);
                    }
                }
            }
        }

        // Remove entry, show label.
        if (priv.chdir_entry) |entry| {
            const parent = entry.as(gtk.Widget).getParent();
            if (parent) |p| {
                const box: *gtk.Box = @ptrCast(@alignCast(p));
                box.remove(entry.as(gtk.Widget));
            }
        }
        priv.dir_label.as(gtk.Widget).setVisible(1);
        priv.chdir_entry = null;
        priv.is_changing_dir = false;
    }
```

- [ ] **Step 3: Build and verify**

Run: `/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell 2>&1 | head -30`

- [ ] **Step 4: Commit**

```bash
git add src/apprt/gtk/class/workspace_tab.zig
git commit -m "feat(sidebar): add inline directory editing to WorkspaceTab

Add startChangeDir/finishChangeDir methods mirroring the rename
pattern. Entry prepends into dir row, pre-populated with current
path. Enter confirms, Escape cancels."
```

---

### Task 8: Wire Change Directory in Window

**Files:**
- Modify: `src/apprt/gtk/class/window.zig` — add termplexOnChangeDirWorkspace/termplexOnChangeDirComplete handlers
- Modify: `src/apprt/gtk/class/application.zig` — add changeWorkspaceDir public method

- [ ] **Step 1: Add termplexOnChangeDirWorkspace handler in window.zig**

Add after `termplexOnDeleteWorkspace` (around line 1598), following the existing `termplexOnRenameWorkspace` pattern:

```zig
    /// Delegates inline directory change to the WorkspaceTab widget.
    fn termplexOnChangeDirWorkspace(index: u32, userdata: ?*anyopaque) void {
        const win: *Self = @ptrCast(@alignCast(userdata orelse return));
        const priv = win.private();
        const row = priv.sidebar.getWorkspaceRow(index) orelse return;
        const child_widget = row.getChild() orelse return;
        const tab: *WorkspaceTab = @ptrCast(@alignCast(child_widget));
        tab.startChangeDir(index, &termplexOnChangeDirComplete, userdata);
    }

    fn termplexOnChangeDirComplete(index: u32, new_dir: [:0]const u8, userdata: ?*anyopaque) void {
        _ = userdata;
        const app = Application.default();
        app.changeWorkspaceDir(index, new_dir);
    }
```

- [ ] **Step 2: Add changeWorkspaceDir public method to application.zig**

Add a public method to `application.zig` that handles the actual state change:

```zig
    /// Change the working directory for a workspace.
    ///
    /// Expands ~ to $HOME, updates workspace_dirs, probes git for
    /// the new path, and refreshes all sidebars.
    pub fn changeWorkspaceDir(self: *Self, index: u32, new_dir: [:0]const u8) void {
        const alloc = self.allocator();
        const priv = self.private();

        if (index >= priv.workspace_dirs.items.len) return;

        // Expand ~ to $HOME for storage.
        const resolved_dir: [:0]const u8 = blk: {
            if (std.mem.startsWith(u8, new_dir, "~")) {
                const home = std.posix.getenv("HOME") orelse break :blk alloc.dupeZ(u8, new_dir) catch return;
                break :blk std.fmt.allocPrintZ(alloc, "{s}{s}", .{ home, new_dir[1..] }) catch return;
            }
            break :blk alloc.dupeZ(u8, new_dir) catch return;
        };

        // Replace the old dir.
        alloc.free(priv.workspace_dirs.items[index]);
        priv.workspace_dirs.items[index] = resolved_dir;

        // Trigger git probe for this workspace.
        var result = git_probe.probe(alloc, resolved_dir);
        defer result.deinit(alloc);

        if (priv.workspace_git_branches.items[index]) |old_b| alloc.free(old_b);
        priv.workspace_git_branches.items[index] = if (result.branch) |b|
            alloc.dupeZ(u8, b) catch null
        else
            null;
        priv.workspace_git_dirty.items[index] = result.dirty;

        // Refresh sidebar to show new dir and git state.
        self.refreshAllWorkspaceSidebars();

        log.info("workspace {d} directory changed to: {s}", .{ index, resolved_dir });
    }
```

- [ ] **Step 3: Build and verify**

Run: `/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell 2>&1 | head -30`
Expected: Clean build

- [ ] **Step 4: Commit**

```bash
git add src/apprt/gtk/class/application.zig
git commit -m "feat(sidebar): wire change directory action to application state

Right-click 'Change Directory...' triggers inline entry in WorkspaceTab.
On confirm, updates workspace_dirs, probes git for the new path, and
refreshes all sidebars."
```

---

## Chunk 4: Integration & Polish

### Task 9: Refresh Sidebar After Workspace Switching and Port Scans

**Files:**
- Modify: `src/apprt/gtk/class/application.zig` — updateSidebarPortState, workspace switch handler

- [ ] **Step 1: Remove updateSidebarPortState call from runPortScan, always use refreshAllWorkspaceSidebars**

In `runPortScan` (application.zig line ~2960), remove the final `self.updateSidebarPortState()` call. The combined timer callback (`combinedProbeCallback` from Task 4) will handle sidebar updates instead.

In `combinedProbeCallback`, remove the `if (any_git_changed)` guard and always call `self.refreshAllWorkspaceSidebars()` at the end (after `runPortScan`). This ensures both git and port changes are reflected with correct dir_text in a single path.

The `updateSidebarPortState` function can be kept for the burst scan path (`triggerBurstPortScan`), or the burst callbacks can also call `refreshAllWorkspaceSidebars` instead. Keep it simple — update `updateSidebarPortState` to also pass dir_text (same pattern as `updateSidebarGitState` in Task 1 Step 9), so both paths work.

- [ ] **Step 2: Verify workspace switching works without extra refresh**

Workspace switching in `window.zig` (lines ~1475-1540) passes `null` for dir_text in `updateWorkspace` calls. Since `update` preserves existing dir label text when dir_text is null, the directory remains visible during switching. Port text will update on the next 10s timer tick when `refreshAllWorkspaceSidebars` runs.

Verify by testing — no code change needed if the behavior is acceptable.

- [ ] **Step 3: Build and verify**

Run: `/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell 2>&1 | head -30`
Expected: Clean build

- [ ] **Step 4: Test manually**

Run: `./zig-out/bin/termplex-app`

Verify:
- All workspace tabs show directory path in dim gray
- Git branch shows for workspaces in git repos
- Active workspace shows port info
- Right-click → "Change Directory..." opens inline entry
- Enter confirms and updates dir + git info
- Escape cancels
- ORCHESTRATOR workspace: name + dir only, no git/ports, no context menu
- "+N" badge appears with multiple ports, left-click expands
- Directory label persists during workspace switching (no flicker)

- [ ] **Step 5: Commit**

```bash
git add src/apprt/gtk/class/application.zig
git commit -m "feat(sidebar): consolidate sidebar refresh paths

Remove updateSidebarPortState from runPortScan, use
refreshAllWorkspaceSidebars in combined timer instead. Update
burst scan path with dir_text support."
```

---

### Task 10: Initial Sidebar Population with Dir Text

**Files:**
- Modify: `src/apprt/gtk/class/window.zig` — initial sidebar build loop
- Modify: `src/apprt/gtk/class/application.zig` — enableOrchestration, IPC workspace.create

- [ ] **Step 1: Update initial sidebar build in window.zig**

At `window.zig:330-346`, the initial sidebar build loop calls `sidebar.addWorkspace(name, null, null, null)`. Update to compute and pass dir text:

```zig
                while (i < count) : (i += 1) {
                    const name = app.workspaceName(i);
                    var dir_buf: [512]u8 = undefined;
                    const dir_text = app.formatDirDisplay(i, &dir_buf);
                    sidebar.addWorkspace(name, null, null, dir_text);
                }
```

And update the initial `updateWorkspace` call (line 339) to also pass dir text.

- [ ] **Step 2: Update IPC workspace.create in application.zig**

Search for `ipcWorkspaceCreate` and ensure its `sidebar.addWorkspace` call passes dir text.

- [ ] **Step 3: Verify enableOrchestration passes dir text**

The `enableOrchestration` function's sidebar calls should already have been updated in Task 1 Step 9. Verify.

- [ ] **Step 4: Trigger initial git probe on startup**

After the initial sidebar build, call `refreshAllWorkspaceSidebars()` (or schedule it via a short GLib timer like `glib.timeoutAdd(500, ...)`) so that git branch info appears shortly after startup rather than waiting for the first 10s timer tick.

- [ ] **Step 5: Build and verify**

Run: `rm -rf .zig-cache && /opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell 2>&1 | head -30`
Expected: Clean build

- [ ] **Step 6: Commit**

```bash
git add src/apprt/gtk/class/window.zig src/apprt/gtk/class/application.zig
git commit -m "feat(sidebar): populate dir text on initial sidebar creation

Ensure workspace directory is shown from first render, not just
after periodic probe. Schedule initial git probe shortly after
startup."
```
