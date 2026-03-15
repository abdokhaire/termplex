# Workspace-Based Terminal Management

## Problem

Termplex workspaces are currently metadata-only — switching workspaces updates the sidebar but the terminal content stays the same. Each workspace needs its own set of tabs and terminals so that switching workspaces swaps the displayed terminal content.

## Goals

1. Each workspace owns an independent set of tabs/splits/terminals
2. Switching workspaces swaps the visible terminal content; background terminals stay alive
3. Workspaces are directory-bound — new terminals in a workspace default to that directory
4. Workspace management UI: rename and delete via right-click context menu
5. CLI command `termplex open [dir]` to create/switch workspaces by directory
6. Session persistence saves per-workspace split layouts
7. UI refinements: compact tab bar, slim header, workspace name in title

## Non-Goals

- Cross-workspace tab movement (tabs belong to their workspace)
- Saving terminal scroll buffers or running process state across app restarts
- Per-workspace theming or color schemes
- Multi-window support — Termplex operates as a single-window application. The Application manages one Window. Termplex's multi-window code remains but is not exercised by Termplex's workspace model.
- Workspace switching by index (Ctrl+1..9) — can be added later

---

## Design

### 1. Data Model

#### Application-Level State (`application.zig` Private)

Replace the current workspace name list with three parallel lists:

```
workspace_names:     ArrayListUnmanaged([:0]const u8)   // existing
workspace_dirs:      ArrayListUnmanaged([:0]const u8)   // NEW — absolute directory path
workspace_tab_views: ArrayListUnmanaged(*adw.TabView)   // NEW — one TabView per workspace
active_workspace_idx: u32                                // existing
```

Each index `i` across all three lists represents a single workspace.

#### Window-Level State (`window.zig` Private)

The Window no longer owns a `tab_view`. Instead it holds:

```
active_tab_view:    *adw.TabView         // points into Application's workspace_tab_views
tab_view_handlers:  [7]c_ulong           // signal handler IDs for disconnect/reconnect
```

The Blueprint template still declares a `tab_view` widget (needed for template compilation), but on `Window.init()` we immediately replace it with the Application's active workspace TabView.

#### GObject Reference Counting for Background TabViews

When a TabView is unparented via `toast_overlay.setChild(null)`, GTK drops its reference. To keep background TabViews alive, `g_object_ref()` must be called before unparenting, and `g_object_unref()` when the workspace is destroyed. The Application holds these refs via `workspace_tab_views`.

Concretely: when creating a TabView in `addWorkspace()`, call `ref()` to take an Application-owned reference. When `toast_overlay.setChild(null)` unparents it, the Application ref keeps it alive. On `removeWorkspace()`, call `unref()` after destroying tabs.

#### Initial Workspace Directory

The first workspace created at app startup (when no session restore occurs) uses `$HOME` as its directory. When creating subsequent workspaces without an explicit directory, the current workspace's directory is used as the default.

### 2. Workspace Lifecycle

#### Creating a Workspace

`Application.addWorkspace(name, dir)`:

1. Allocate and store name and directory (dir defaults to current workspace's dir, or `$HOME` if no current workspace)
2. Create a new `adw.TabView`, take an Application-owned GObject ref
3. Append to all three lists
4. Tell the active window to switch to the new workspace
5. Create one initial tab in the new TabView, with shell starting in `dir`

The existing `addWorkspace()` callers (sidebar button, IPC `workspace.create`, keyboard shortcut) must be updated to pass the `dir` parameter.

#### Removing a Workspace

`Application.removeWorkspace(index)`:

1. If it's the last workspace, refuse (show toast)
2. Close all tabs in the workspace's TabView (this kills terminal processes)
3. Remove from all three lists
4. `unref()` the TabView (releases Application-owned ref, allows finalization)
5. Clamp `active_workspace_idx`
6. Switch to the adjacent workspace

#### Renaming a Workspace

`Application.renameWorkspace(index, new_name)`:

1. Free old name, store new name
2. Update sidebar display
3. Update header title if this is the active workspace

### 3. TabView Switching

`Window.switchToTabView(new_tab_view)` — the core of the feature. Called on every workspace switch.

#### Widget Tree Context

The TabView sits inside the following hierarchy (from `window.blp`):

```
Adw.ApplicationWindow
  └─ Adw.TabOverview (tab_overview)  [view: tab_view]
      └─ Adw.ToolbarView (toolbar)
          ├─ Adw.HeaderBar
          ├─ Adw.TabBar (tab_bar)  [view: tab_view]
          └─ Box (vertical)
              └─ Adw.ToastOverlay (toast_overlay)
                  └─ Adw.TabView (tab_view)  ← THIS is what gets swapped
```

The swap target is `toast_overlay`'s child. Background (non-displayed) TabViews are unparented — kept alive by the Application's GObject ref.

#### Swap Procedure

**Disconnect phase:**
1. Disconnect surface signal handlers for every tab page in the old TabView (iterate pages, call `disconnectSurfaceHandlers()` on each tab's split tree)
2. Unbind `tab_bindings` — `setSource(null)`. Also remove the title binding from `tab_bindings` (see Section 8 — title now shows workspace name, not tab title)
3. Disconnect all 7 signal handlers from old TabView using stored handler IDs
4. Set `tab_bar.view = null` and `tab_overview.view = null` (programmatic override of template bindings)

**Swap phase:**
5. `toast_overlay.setChild(null)` — unparents old TabView (Application ref keeps it alive)
6. `toast_overlay.setChild(new_tab_view.as(gtk.Widget))` — inserts new TabView

**Reconnect phase:**
7. Connect all 7 signal handlers to new TabView, store new handler IDs
8. Set `tab_bar.view = new_tab_view` and `tab_overview.view = new_tab_view`
9. Reconnect surface signal handlers for every tab page in the new TabView
10. Rebind `tab_bindings` to the new TabView's selected page (for tooltip and other non-title properties only)
11. Focus the active surface in the new TabView
12. Update `active_tab_view` reference
13. Update header title to new workspace name, subtitle to workspace directory

#### Signal Handler Parameter Usage

All 7 signal handler callbacks receive the originating TabView as their first parameter. **Handlers must use this signal parameter** (not `priv.active_tab_view`) to reference the TabView. This is critical because:
- During mid-switch state, `priv.active_tab_view` may not match the TabView that emitted the signal
- Using the signal parameter is correct by construction

Specific handlers that currently reference `priv.tab_view` directly (e.g., `tabViewClosePage` calling `tab_view.closePageFinish()`, `tabViewNPages` checking page count) must be updated to use the TabView parameter instead. All ~12 call sites in window.zig that reference `priv.tab_view` must be audited and changed to either:
- The signal parameter (inside signal handlers)
- `priv.active_tab_view` (outside signal handlers, e.g., in `newTabPage()`)

#### Signal Handlers to Manage (7 total)

- `notify::n-pages` → `tabViewNPages`
- `notify::selected-page` → `tabViewSelectedPage`
- `close-page` → `tabViewClosePage`
- `page-attached` → `tabViewPageAttached`
- `page-detached` → `tabViewPageDetached`
- `create-window` → `tabViewCreateWindow`
- `setup-menu` → `setupTabMenu`

#### `tabViewCreateWindow` — Disabled for Single-Window

Since Termplex is single-window, the `create-window` handler (which creates a new Window when a tab is dragged out) is replaced with a no-op that returns null. This prevents tab drag-out from creating orphaned windows with no workspace context. The handler is still connected/disconnected as part of the 7-handler set for consistency.

#### Blueprint Changes

These 7 signal handlers are currently declared in `window.blp`. They must be removed from the template and connected programmatically in `Window.init()` so they can be disconnected/reconnected on workspace switch.

The `tab_overview.view` and `tab_bar.view` template bindings must also be removed from the Blueprint and set programmatically, since they need to change on each workspace switch.

The `computed_subtitle` binding in the Blueprint that references `tab_view.selected-page.child...pwd` must be removed. The subtitle is replaced by the workspace directory (Section 8).

The `tab_bindings` title binding (`bind "title"`) must be removed so it no longer overwrites the window title. The workspace name is set programmatically.

#### Last-Tab-Closed Behavior

When `tabViewNPages` fires with 0 pages:
- If other workspaces exist: remove the empty workspace, switch to adjacent
- If it's the last workspace: close the window (original Termplex behavior)

#### Autosave Safety

The autosave timer iterates `workspace_tab_views` at the Application level (not the Window's `active_tab_view`), so it is safe to run during a workspace switch. Each TabView in the list is always valid — either parented in the Window or unparented but alive (held by Application ref). The GLib main loop is single-threaded, so the swap procedure completes atomically from the autosave timer's perspective.

### 4. New Terminal Directory

When creating a new tab or split within a workspace, the shell's working directory must default to `workspace_dirs[active_workspace_idx]`.

**Integration point:** The single integration point is `newTabPage()` in `window.zig`. This function already accepts an `overrides` struct with an optional `working_directory` field. When `overrides.working_directory` is null, `newTabPage()` looks up the workspace directory from `Application.default().workspaceDir(active_workspace_idx)` and passes it as the working directory. This covers all call sites (there are at least 3) without duplicating logic.

This applies to:
- `newTabPage()` — new tab creation (all call sites inherit the behavior)
- Split creation via SplitTree — splits inherit the parent surface's directory by default (existing Termplex behavior), which is correct
- The initial tab created when a workspace is first made — goes through `newTabPage()`

### 5. Workspace UI Management

#### Right-Click Context Menu on Sidebar Workspace Tabs

When user right-clicks a workspace tab row in the sidebar `ListBox`:

Display a `gtk.PopoverMenu` with:
- **Rename** — triggers inline rename
- **Delete** — triggers delete with confirmation

**Implementation:** Add a `GtkGestureClick` controller to the sidebar's `ListBox` (not per-row). On right-click (button 3), hit-test to find which row was clicked using `list_box.getRowAtY()`, then show the popover positioned at the click location. This avoids needing to update gesture controllers when workspaces are added/removed.

#### Rename Flow

1. User selects "Rename" from context menu
2. The `WorkspaceTab` name label is replaced with a `gtk.Entry` pre-filled with the current name
3. Enter → confirms: calls `Application.renameWorkspace(index, new_text)`, entry reverts to label
4. Escape → cancels: entry reverts to label, no change

#### Delete Flow

1. User selects "Delete" from context menu
2. If workspace has running terminals: show `adw.AlertDialog` — "Workspace 'X' has N running terminals. Delete anyway?" with Cancel/Delete buttons
3. If it's the last workspace: show toast "Cannot delete the last workspace"
4. On confirm: call `Application.removeWorkspace(index)`

### 6. CLI: `termplex open [directory]`

**Command:** `termplex open [path]`

**Behavior:**
1. Resolve `path` to absolute (default: `$PWD`)
2. Send IPC request `workspace.find_by_dir {"dir": "/abs/path"}` to running instance
3. If no matches: create new workspace with `workspace.create {"name": "<basename>", "dir": "/abs/path"}`, focus window
4. If matches exist: print numbered list of matching workspaces plus "Create new" option, prompt user to choose interactively (if stdin is a TTY; otherwise auto-create)
5. On selection: send `workspace.select {"index": N}` or `workspace.create`, focus window

**IPC Protocol Additions:**

All new IPC methods are added to the inline dispatcher in `application.zig` (the authoritative IPC path). The standalone `protocol.zig` dispatcher is not used at runtime and does not need updating.

`workspace.find_by_dir` — request:
```json
{"method": "workspace.find_by_dir", "params": {"dir": "/abs/path"}}
```
Response:
```json
{"ok": true, "result": {"workspaces": [{"index": 0, "name": "myapp", "dir": "/home/user/myapp", "tab_count": 3}]}}
```

`workspace.create` — extended request (backward compatible: `dir` is optional, defaults to current workspace dir):
```json
{"method": "workspace.create", "params": {"name": "myapp", "dir": "/home/user/myapp"}}
```

`workspace.select` — request. Accepts both `"index"` (numeric) and `"ref"` (string name) for backward compatibility with the existing CLI which uses `{"ref": "..."}`:
```json
{"method": "workspace.select", "params": {"index": 1}}
```
or:
```json
{"method": "workspace.select", "params": {"ref": "myapp"}}
```
When `"ref"` is provided, the dispatcher looks up the workspace by name. When `"index"` is provided, it selects by position. If both are provided, `"index"` takes precedence.

### 7. Session Persistence

The existing simplified autosave format in `application.zig` is extended in place. The `session.zig` core module exists but is not used by the GTK runtime due to the module import constraint (uuid dependency). We continue with the inline JSON approach.

#### Autosave Format (v2)

```json
{
  "version": 2,
  "workspaces": [
    {
      "name": "myapp",
      "dir": "/home/ahmed/projects/myapp",
      "tabs": [
        {"splits": "single"},
        {"splits": {"direction": "horizontal", "ratio": 0.5, "first": "single", "second": "single"}},
        {"splits": {"direction": "vertical", "ratio": 0.6, "first": "single", "second": {"direction": "horizontal", "ratio": 0.5, "first": "single", "second": "single"}}}
      ]
    }
  ],
  "active_workspace": 0,
  "window_width": 1200,
  "window_height": 800,
  "sidebar_width": 180
}
```

A `"version"` field is added. On load, if the version is missing or is 1, the old format is migrated: workspace names are preserved, dirs default to the saved `pwd` field (if present) or `$HOME`, one tab each.

#### Saving

On the 5-second autosave timer:
1. For each workspace in `workspace_tab_views`: record name, dir, and for each tab walk the SplitTree to build the splits structure (direction + ratio for splits, "single" for leaves)
2. Write atomically via .tmp + rename

#### Restoring — Sequencing

Restore happens in two phases because TabViews are created by the Application but tabs require a Window (surfaces need a realized GL context).

**Phase 1: Application startup (`restoreSession()` in `activate`):**
1. Read `session.json`
2. For each workspace entry: create workspace with name, dir, and TabView (but NO tabs yet)
3. Store the parsed tab/split structures temporarily in a restore buffer
4. Set `active_workspace_idx` and window size/sidebar width targets

**Phase 2: Window init (`Window.init()`):**
1. After the Window is realized and the initial TabView swap is done
2. For each workspace's stored tab/split data: create tabs and replay split structures
3. If no restore data exists: create one default tab in the active workspace
4. Clear the restore buffer

This two-phase approach is necessary because `newTabPage()` requires a realized Window with a GL context to create terminal surfaces.

**Not saved:** scroll buffers, running processes, environment variables. Shells start fresh in the workspace directory.

### 8. UI Refinements

#### Compact Tab Bar

CSS overrides to reduce `adw.TabBar` height:

```css
.tab-bar {
  min-height: 28px;
}

.tab-bar tab {
  padding-top: 2px;
  padding-bottom: 2px;
  min-height: 24px;
}
```

#### Slim Header Bar

CSS overrides to reduce `adw.HeaderBar` padding:

```css
headerbar {
  min-height: 32px;
  padding-top: 0;
  padding-bottom: 0;
}
```

#### Header Title Shows Workspace Name

Currently the header title is bound to the active tab's title via `tab_bindings` (specifically `priv.tab_bindings.bind("title", self.as(gobject.Object), "title", .{})`), and the `computed_subtitle` binding in the Blueprint references `tab_view.selected-page.child...pwd`. Both are removed.

Changes:
1. Remove the `"title"` binding from `tab_bindings` so tab titles no longer overwrite the window title. Other bindings in `tab_bindings` (tooltip, etc.) remain.
2. Remove the `computed_subtitle` expression from `window.blp`.
3. Set `Adw.WindowTitle.title` to the active workspace name, and `subtitle` to the workspace directory (abbreviated with `~`). Update programmatically in:
   - `switchToTabView()` — when workspace changes
   - `renameWorkspace()` — when name changes

---

## Files Affected

### Modified
- `src/apprt/gtk/class/application.zig` — workspace data model (dirs, tab_views, GObject refs), TabView creation/destruction, IPC handlers (find_by_dir, create with dir, select with index+ref), autosave v2 format, restore phase 1, directory management
- `src/apprt/gtk/class/window.zig` — `switchToTabView()`, programmatic signal wiring (7 handlers), signal handler parameter audit (~12 `priv.tab_view` sites), header title/subtitle binding, `newTabPage()` directory override, last-tab-closed behavior, restore phase 2, `tabViewCreateWindow` disabled
- `src/apprt/gtk/class/sidebar.zig` — right-click context menu (GtkGestureClick on ListBox, PopoverMenu), rename/delete callbacks
- `src/apprt/gtk/class/workspace_tab.zig` — inline rename entry support (label ↔ entry swap)
- `src/apprt/gtk/ui/1.5/window.blp` — remove 7 TabView signal handler declarations, remove tab_bar.view and tab_overview.view template bindings, remove computed_subtitle expression
- `src/apprt/gtk/css/style.css` — compact tab bar, slim header bar CSS
- `src/apprt/gtk/css/style-dark.css` — matching dark mode overrides
- `src/termplex/cli_main.zig` — `termplex open` subcommand with IPC calls and interactive prompting
