# Sidebar Workspace Info Enhancement — Design Spec

## Goal

Show workspace directory, git branch, and port information for **all** workspaces in the sidebar (not just the active one), and allow changing a workspace's directory via the right-click context menu.

## Current State

- `WorkspaceTab` widget has: name label (row 1), port label (row 1 right), branch label (row 2)
- Git probing and port scanning only run for the **active** workspace
- Workspace directory (`workspace_dirs`) is stored internally but never shown in the UI
- No way to change a workspace's directory from the sidebar
- Port scanning uses the app's own PID — there is no per-workspace PID tracking yet (see TODO in `application.zig` `runPortScan`)

## Design

### Layout

Each workspace tab in the sidebar displays up to three rows:

```
Row 1:  [Name (bold)]                    [:port +N]
Row 2:  [~/path/to/dir (dim gray)]
Row 3:  [⎇ branch* (cyan)]
```

**GTK widget tree change:** The current `WorkspaceTab.init` creates `row1` (name + port) and `row2` (branch). This changes to:
- `row1` — `gtk.Box` horizontal: `name_label` (left, hexpand) + port area (right)
- `row2` — `gtk.Box` horizontal: `dir_label` (new, left, hexpand) — **inserted between current row1 and row2**
- `row3` — `gtk.Box` horizontal: `branch_label` (left) — **the current row2 becomes row3**
- `port_detail_box` — `gtk.Box` vertical: appended after row3, hidden by default

**Rules:**
- **Row 1** always visible — workspace name left, port info right
- **Row 2** always visible — directory path in dim gray (`#94a3b8`). Call `dir_label.setEllipsize(.end)` and `dir_label.setMaxWidthChars(25)` in `init` to handle long paths (GTK CSS does not support `text-overflow: ellipsis`)
- **Row 3** only visible when a git branch is detected — hidden otherwise
- ORCHESTRATOR workspace always at index 0 (top of sidebar) — shows only name + directory, no git/ports
- Path display: replace `$HOME` prefix with `~`, show as-is otherwise

### Port Display

**Row 1 right-side structure change:** The current single `port_label` is replaced by a `gtk.Box` (horizontal) containing:
- `port_primary_label` — `gtk.Label` showing the first port (e.g., `:3000`), green, CSS class `termplex-tab-port`
- `port_badge_button` — `gtk.Label` inside a `gtk.GestureClick`, showing `+N`, styled with `background: #1a3a2a`, `border-radius: 3px`, hidden when 0-1 ports

Both replace the current `port_label` field in `Private`.

**Behavior:**
- **0 ports**: entire port box hidden
- **1 port**: `port_primary_label` shown, `port_badge_button` hidden
- **2+ ports**: both shown — first port + "+N" badge
- **Click "+N" badge**: toggles `port_detail_box` visibility below row 3
- `port_detail_box`: `background: #131d2b`, `border-radius: 4px`, `padding: 4px 6px`, each port on its own line in green

**State:** `ports_expanded: bool = false` in `WorkspaceTab` Private.

### Git Info for All Workspaces

Currently git probing only runs for the active workspace via `updateWorkspacePwd` → `triggerGitProbe`. This must be extended to probe all workspaces.

**Per-workspace state to add to `application.zig` Private:**
- `workspace_git_branches: ArrayListUnmanaged(?[:0]const u8)` — branch name per workspace, null if not a git repo
- `workspace_git_dirty: ArrayListUnmanaged(bool)` — dirty flag per workspace

These parallel arrays are managed alongside `workspace_names`/`workspace_dirs`/`workspace_tab_views` — appended in `addWorkspaceWithDir`, removed in `removeWorkspace`.

**Probing all workspaces:**
- Add a 10-second GLib repeating timer (`allWorkspaceProbeCallback`) that iterates all workspaces, runs `git_probe.probe()` for each workspace's directory, updates per-workspace arrays, and refreshes the sidebar
- The probe loop **skips the orchestration workspace** (`orchestration_workspace_idx`)
- The existing active-workspace 2-second debounce probe (`triggerGitProbe`) still runs on pwd change for responsiveness
- The periodic probe catches changes in non-active workspaces (e.g., a background `git commit` in another workspace tab)

### Port Scanning — Active Workspace Only (for now)

Port scanning currently uses the app's own PID to discover listening ports — there is no per-workspace PID tracking. Extending this to per-workspace port scanning requires wiring surface child-process PIDs into workspace state, which is a separate future effort.

**For this feature:** Port display continues to show ports for the **active workspace only**, using the existing scanning infrastructure. The per-workspace `workspace_ports` / `workspace_port_counts` arrays are NOT added. The existing `listening_ports_str` field drives the port display for the active workspace tab; all other workspace tabs show no ports.

This means the "+N" badge and expand/collapse only appear on the active workspace's sidebar entry. Per-workspace port tracking is a follow-up.

### Directory Label

- Add `dir_label: *gtk.Label` to `WorkspaceTab` Private
- CSS class: `termplex-tab-dir`
- Style in `style.css`: `color: #94a3b8; font-size: 10px;`
- In `init`: call `dir_label.setEllipsize(.end)` and `dir_label.setMaxWidthChars(25)`

### Change Directory Action

- Add "Change Directory..." to the existing right-click context menu in `sidebar.zig` `onRightClick`
- Not shown for the ORCHESTRATOR workspace (same as rename/delete exclusion)
- Clicking it triggers an inline text entry (same pattern as the existing rename feature)

**Callback:** Add a new callback to the sidebar's callback model, matching the existing `on_rename`/`on_delete` pattern:
```
on_change_dir: ?*const fn (index: u32, new_dir: [:0]const u8, userdata: ?*anyopaque) void
```
Registered via a new field in `setManagementCallbacks` (or a dedicated `setChangeDirCallback` setter, following whatever pattern is simpler given the existing code).

**WorkspaceTab inline editing:**
- Add `startChangeDir(index, on_complete, userdata)` and `finishChangeDir(confirm)` methods, mirroring `startRename` / `finishRename`
- Entry is **prepended into the dir row box** (row2), hiding `dir_label`, following the same pattern as `startRename` prepends into row1
- Entry is pre-populated with the current directory path
- On confirm (Enter): fire `on_change_dir` callback → application updates `workspace_dirs[index]`, triggers git probe for that workspace, updates sidebar
- On cancel (Escape): discard, restore dir label

### Sidebar Update Flow

The current `updateSidebarForAllWindows` only updates a single workspace index. A new function is needed:

**Add `refreshAllWorkspaceSidebars(self: *Self)`** in `application.zig` that:
1. Iterates all workspace indices
2. For each, gathers name, dir, git branch/dirty, port text (active only), and is_active flag
3. Iterates all open windows
4. Calls `sidebar.updateWorkspace(idx, ...)` for each workspace in each window

This function is called by the 10-second periodic timer after probing all workspaces. The existing `updateSidebarForAllWindows` (single-workspace) is kept for the active-workspace debounce path.

**`WorkspaceTab.update` signature change:** Add `dir_text: ?[:0]const u8` parameter. Callers pass the directory path (with `~` shorthand applied). The `update` method sets `dir_label` text and visibility.

**`sidebar.updateWorkspace` signature change:** Add `dir_text: ?[:0]const u8` parameter, forwarded to `WorkspaceTab.update`.

### Timer Consolidation

The existing 30-second port scan timer (`port_scan_timer` / `portScanCallback`) is **replaced** by the new 10-second combined timer that handles both git probing (all workspaces) and port scanning (active workspace). The burst port scan on pwd change (`triggerBurstPortScan`) is kept for responsiveness.

### Files to Modify

| File | Changes |
|------|---------|
| `src/apprt/gtk/class/workspace_tab.zig` | Add `dir_label` (row 2), restructure port area (primary + badge), add `port_detail_box`, `ports_expanded`, expand/collapse click handler, `startChangeDir`/`finishChangeDir` |
| `src/apprt/gtk/class/sidebar.zig` | Add "Change Directory..." to right-click menu, `on_change_dir` callback, wire to `WorkspaceTab.startChangeDir` |
| `src/apprt/gtk/class/application.zig` | Add per-workspace git arrays, 10s combined probe timer replacing 30s port timer, `refreshAllWorkspaceSidebars`, update `WorkspaceTab.update`/`sidebar.updateWorkspace` call sites for new `dir_text` param |
| `src/apprt/gtk/css/style.css` | Add `.termplex-tab-dir`, `.termplex-port-badge`, `.termplex-port-detail` styles |

### What This Does NOT Include

- No per-workspace port scanning (requires PID tracking — future work)
- No IPC handler for changing directory (can be added later)
- No drag-and-drop directory change
- No file chooser dialog — text entry only
- No per-port process name display (just port numbers)
