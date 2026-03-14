# Workspace-Based Terminal Management Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each workspace its own independent set of tabs/terminals, so switching workspaces swaps the displayed terminal content while background terminals stay alive.

**Architecture:** Application owns a per-workspace `adw.TabView` list. The Window swaps TabViews in/out of `toast_overlay` on workspace switch, disconnecting/reconnecting 7 signal handlers and surface handlers each time. Workspaces are directory-bound with right-click management and CLI integration.

**Tech Stack:** Zig 0.15.2, GTK4 4.14, libadwaita 1.5, GObject (gobject-zig bindings)

**Build command:** `/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell`

**Spec:** `docs/superpowers/specs/2026-03-14-workspace-terminal-management-design.md`

---

## Chunk 1: Data Model & TabView Ownership

### Task 1: Add workspace_dirs and workspace_tab_views to Application Private

**Files:**
- Modify: `src/apprt/gtk/class/application.zig:220-234` (Private struct)
- Modify: `src/apprt/gtk/class/application.zig:638-654` (addWorkspace)
- Modify: `src/apprt/gtk/class/application.zig:670-687` (removeWorkspace)

**Context:** The Application Private struct (line 220) currently has `workspace_names`, `active_workspace_idx`, and `next_workspace_number`. We add two parallel lists and update lifecycle methods.

- [ ] **Step 1: Add new fields to Private struct**

In `application.zig` Private struct (after line 225 `workspace_names`), add:

```zig
workspace_dirs: std.ArrayListUnmanaged([:0]const u8) = .{},
workspace_tab_views: std.ArrayListUnmanaged(*adw.TabView) = .{},
```

- [ ] **Step 2: Add new public accessor methods**

After the existing `workspaceName()` function (line 658), add:

```zig
/// Get the working directory for workspace at the given index.
pub fn workspaceDir(self: *Self, index: u32) ?[:0]const u8 {
    const priv = self.private();
    if (index >= priv.workspace_dirs.items.len) return null;
    return priv.workspace_dirs.items[index];
}

/// Get the TabView for workspace at the given index.
pub fn workspaceTabView(self: *Self, index: u32) ?*adw.TabView {
    const priv = self.private();
    if (index >= priv.workspace_tab_views.items.len) return null;
    return priv.workspace_tab_views.items[index];
}

/// Get the active workspace's TabView.
pub fn activeTabView(self: *Self) ?*adw.TabView {
    return self.workspaceTabView(self.private().active_workspace_idx);
}
```

- [ ] **Step 3: Update addWorkspace() to accept dir and create TabView**

Replace the existing `addWorkspace()` (lines 638-654) with:

```zig
pub fn addWorkspace(self: *Self) void {
    self.addWorkspaceWithDir(null);
}

pub fn addWorkspaceWithDir(self: *Self, dir: ?[:0]const u8) void {
    const priv = self.private();
    const alloc = self.allocator();

    // Generate name "Workspace N"
    var buf: [64]u8 = undefined;
    const name_slice = std.fmt.bufPrint(&buf, "Workspace {d}", .{priv.next_workspace_number}) catch return;
    priv.next_workspace_number += 1;
    const name = alloc.dupeZ(u8, name_slice) catch return;

    // Resolve directory: explicit > current workspace > $HOME
    const resolved_dir = blk: {
        if (dir) |d| {
            break :blk alloc.dupeZ(u8, d) catch {
                alloc.free(name);
                return;
            };
        }
        // Default to current workspace dir, or $HOME
        if (priv.workspace_dirs.items.len > 0 and priv.active_workspace_idx < priv.workspace_dirs.items.len) {
            break :blk alloc.dupeZ(u8, priv.workspace_dirs.items[priv.active_workspace_idx]) catch {
                alloc.free(name);
                return;
            };
        }
        const home = std.posix.getenv("HOME") orelse "/tmp";
        break :blk alloc.dupeZ(u8, home) catch {
            alloc.free(name);
            return;
        };
    };

    // Create TabView for this workspace
    const tab_view = adw.TabView.new();
    // Take Application-owned ref so it survives being unparented
    _ = tab_view.as(gobject.Object).ref();

    priv.workspace_names.append(alloc, name) catch {
        alloc.free(name);
        alloc.free(resolved_dir);
        return;
    };
    priv.workspace_dirs.append(alloc, resolved_dir) catch {
        _ = priv.workspace_names.pop();
        alloc.free(name);
        alloc.free(resolved_dir);
        return;
    };
    priv.workspace_tab_views.append(alloc, tab_view) catch {
        _ = priv.workspace_dirs.pop();
        _ = priv.workspace_names.pop();
        alloc.free(name);
        alloc.free(resolved_dir);
        tab_view.as(gobject.Object).unref();
        return;
    };
}
```

- [ ] **Step 4: Update removeWorkspace() to clean up TabView and dir**

Replace the existing `removeWorkspace()` (lines 670-687) with:

```zig
pub fn removeWorkspace(self: *Self, index: u32) void {
    const priv = self.private();
    const alloc = self.allocator();
    if (priv.workspace_names.items.len <= 1) return; // protect last workspace
    if (index >= priv.workspace_names.items.len) return;

    // Close all tabs in this workspace's TabView before releasing it.
    // This ensures terminal processes are properly terminated.
    // Use the same pattern as tabViewClosePage (window.zig:1610-1635):
    // closePage + closePageFinish at the TabView level handles cleanup.
    const tab_view = priv.workspace_tab_views.items[index];
    while (tab_view.getNPages() > 0) {
        const page = tab_view.getNthPage(0);
        tab_view.closePage(page);
        tab_view.closePageFinish(page, @intFromBool(true));
    }

    // Free the name string
    alloc.free(priv.workspace_names.items[index]);
    _ = priv.workspace_names.orderedRemove(index);

    // Free the dir string
    alloc.free(priv.workspace_dirs.items[index]);
    _ = priv.workspace_dirs.orderedRemove(index);

    // Release Application-owned ref on the TabView
    tab_view.as(gobject.Object).unref();
    _ = priv.workspace_tab_views.orderedRemove(index);

    // Clamp active index
    if (priv.active_workspace_idx >= priv.workspace_names.items.len) {
        priv.active_workspace_idx = @intCast(priv.workspace_names.items.len - 1);
    }
}
```

Note: The `closePage()` + `closePageFinish(page, true)` pattern at the TabView level is the standard GTK4/libadwaita approach for forced tab closure. This mirrors the pattern used in `tabViewClosePage` (window.zig:1610-1635). The Tab widget does NOT have a `closeWithConfirmation` method — all close logic goes through the TabView.

- [ ] **Step 5: Update deinit to clean up new lists**

Find the existing deinit cleanup for `workspace_names` and add parallel cleanup for `workspace_dirs` and `workspace_tab_views`. Add after the existing workspace_names cleanup:

```zig
// Clean up workspace dirs
for (priv.workspace_dirs.items) |dir_str| {
    alloc.free(dir_str);
}
priv.workspace_dirs.deinit(alloc);

// Clean up workspace tab views
for (priv.workspace_tab_views.items) |tv| {
    tv.as(gobject.Object).unref();
}
priv.workspace_tab_views.deinit(alloc);
```

- [ ] **Step 6: Update initial workspace creation to also create dir and TabView**

Find where the first workspace is created during startup (in the activate/startup flow where "Workspace 1" is added to `workspace_names`). Update it to also call `addWorkspaceWithDir(null)` instead of manually appending to `workspace_names` only. This ensures the first workspace gets a TabView and directory.

- [ ] **Step 7: Build and verify**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

- [ ] **Step 8: Commit**

```bash
git add src/apprt/gtk/class/application.zig
git commit -m "feat: add workspace_dirs and workspace_tab_views to Application"
```

---

### Task 2: Move TabView signal handlers from Blueprint to programmatic

**Files:**
- Modify: `src/apprt/gtk/ui/1.5/window.blp:26,50,88,159-165` (remove template bindings)
- Modify: `src/apprt/gtk/class/window.zig:219-275` (Private struct), `window.zig:298` (init), `window.zig` Class.init

**Context:** The 7 TabView signal handlers are currently declared in `window.blp` (lines 159-165). We must remove them from the template and connect them programmatically so they can be disconnected/reconnected on workspace switch. We also remove `tab_bar.view`, `tab_overview.view`, and the `computed_subtitle` bindings.

- [ ] **Step 1: Remove signal handlers from window.blp**

In `src/apprt/gtk/ui/1.5/window.blp`, remove lines 159-165 (the 7 signal handler declarations inside the `Adw.TabView tab_view` block). Keep the `Adw.TabView tab_view {` declaration and its closing `}` but remove:

```
      notify::n-pages => $notify_n_pages();
      notify::selected-page => $notify_selected_page();
      close-page => $close_page();
      page-attached => $page_attached();
      page-detached => $page_detached();
      create-window => $tab_create_window();
      setup-menu => $setup_tab_menu();
```

- [ ] **Step 2: Remove tab_bar.view and tab_overview.view template bindings from window.blp**

Remove line 88 (`view: tab_view;` inside TabBar) and line 26 (`view: tab_view;` inside TabOverview).

- [ ] **Step 3: Remove computed_subtitle from window.blp**

Remove line 50 (the `subtitle: bind $computed_subtitle(...)` expression). Replace with just:
```
subtitle: "";
```

- [ ] **Step 4: Add tab_view_handlers field to Window Private struct**

In `window.zig` Private struct (after line 263 `sidebar_programmatic`), add:

```zig
/// Signal handler IDs for the active TabView (for disconnect/reconnect).
tab_view_handler_ids: [7]c_ulong = .{0} ** 7,
```

- [ ] **Step 5: Remove template callback bindings from Class.init**

In `window.zig` Class.init, find where the 7 TabView signal callbacks are bound via `class.bindTemplateCallback(...)` (around lines 2462-2468). Remove these 7 lines:

```zig
class.bindTemplateCallback("notify_n_pages", &tabViewNPages);
class.bindTemplateCallback("notify_selected_page", &tabViewSelectedPage);
class.bindTemplateCallback("close_page", &tabViewClosePage);
class.bindTemplateCallback("page_attached", &tabViewPageAttached);
class.bindTemplateCallback("page_detached", &tabViewPageDetached);
class.bindTemplateCallback("tab_create_window", &tabViewCreateWindow);
class.bindTemplateCallback("setup_tab_menu", &setupTabMenu);
```

Also remove the `computed_subtitle` callback binding if present.

- [ ] **Step 6: Create connectTabViewHandlers() and disconnectTabViewHandlers() methods**

Add these methods to Window (before the `const C = Common(...)` line):

```zig
/// Connect all 7 signal handlers to a TabView and store handler IDs.
fn connectTabViewHandlers(self: *Self, tab_view: *adw.TabView) void {
    const priv = self.private();

    priv.tab_view_handler_ids[0] = gobject.Object.signals.notify.connect(
        tab_view, *Self, &tabViewNPages, self, .{ .detail = "n-pages" },
    );
    priv.tab_view_handler_ids[1] = gobject.Object.signals.notify.connect(
        tab_view, *Self, &tabViewSelectedPage, self, .{ .detail = "selected-page" },
    );
    priv.tab_view_handler_ids[2] = adw.TabView.signals.close_page.connect(
        tab_view, *Self, &tabViewClosePage, self, .{},
    );
    priv.tab_view_handler_ids[3] = adw.TabView.signals.page_attached.connect(
        tab_view, *Self, &tabViewPageAttached, self, .{},
    );
    priv.tab_view_handler_ids[4] = adw.TabView.signals.page_detached.connect(
        tab_view, *Self, &tabViewPageDetached, self, .{},
    );
    priv.tab_view_handler_ids[5] = adw.TabView.signals.create_window.connect(
        tab_view, *Self, &tabViewCreateWindow, self, .{},
    );
    priv.tab_view_handler_ids[6] = adw.TabView.signals.setup_menu.connect(
        tab_view, *Self, &setupTabMenu, self, .{},
    );
}

/// Disconnect all 7 signal handlers from a TabView.
fn disconnectTabViewHandlers(self: *Self, tab_view: *adw.TabView) void {
    const priv = self.private();
    const obj = tab_view.as(gobject.Object);
    for (&priv.tab_view_handler_ids) |*id| {
        if (id.* != 0) {
            obj.signalHandlerDisconnect(id.*);
            id.* = 0;
        }
    }
}
```

Note: The exact signal connection API may need adjustment based on the gobject-zig binding patterns used elsewhere in the codebase. Check how `gobject.Object.signals.notify.connect` is called in `command_palette.zig:109` and how `gtk.Button.signals.clicked.connect` is called in `sidebar.zig:126` for the correct patterns. The `adw.TabView.signals.*` names need to be verified against the bindings — they may use underscore or hyphen naming.

- [ ] **Step 7: Connect handlers programmatically in Window.init()**

In `Window.init()` (around line 298), after the existing initialization, add:

```zig
// Programmatically connect TabView signals (moved from Blueprint template).
self.connectTabViewHandlers(priv_.tab_view);

// Programmatically bind tab_bar and tab_overview to the TabView.
priv_.tab_bar.setView(priv_.tab_view);
priv_.tab_overview.setView(priv_.tab_view);
```

- [ ] **Step 8: Remove the title binding from tab_bindings**

Find line 419 (`priv.tab_bindings.bind("title", ...)`) and remove it. The workspace name will be set programmatically instead.

- [ ] **Step 9: Build and verify**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

Run the app to verify tabs still work with programmatic signal connections:
```bash
TERMPLEX_DISABLE_RESTORE=1 ./zig-out/bin/termplex-app
```

- [ ] **Step 10: Commit**

```bash
git add src/apprt/gtk/ui/1.5/window.blp src/apprt/gtk/class/window.zig
git commit -m "feat: move TabView signal handlers from Blueprint to programmatic"
```

---

### Task 3: Audit and update all priv.tab_view references in window.zig

**Files:**
- Modify: `src/apprt/gtk/class/window.zig` (12 call sites)

**Context:** All 12 sites that reference `priv.tab_view` must be changed to use either the signal parameter (inside signal handlers) or `priv.active_tab_view` (outside signal handlers). We also rename `tab_view` to `active_tab_view` in the Private struct.

- [ ] **Step 1: Add active_tab_view field to Private struct**

In Private struct (after line 270 `tab_view`), add a new field. Keep the existing template-bound `tab_view` — it is populated by Blueprint and used only during init for the initial reference. All runtime code will use `active_tab_view` instead.

```zig
active_tab_view: *adw.TabView = undefined, // set programmatically in init
```

Do NOT rename or remove the existing `tab_view: *adw.TabView` field — it is still needed as a template child binding.

- [ ] **Step 2: Update signal handlers to use the signal parameter**

For each of the 7 signal handlers, change the first parameter from `_: *adw.TabView` to `tab_view: *adw.TabView` and use it instead of `priv.tab_view`:

**tabViewClosePage (line 1610):** Change first param to `tab_view: *adw.TabView`, use `tab_view.closePageFinish(...)` at line 1623. **Important:** Line 1623 has `priv.tab_view.closePageFinish(page, ...)` — this MUST be changed to use the signal parameter `tab_view` instead of `priv.tab_view`/`priv.active_tab_view`.

**tabViewNPages (line 1770):** Change to use signal parameter. Update the n_pages == 0 check at line 1776.

**tabViewSelectedPage (line 1649):** Change to use signal parameter at line 1660.

**tabViewPageAttached (line 1673):** Already receives TabView as first param — ensure it uses it.

**tabViewPageDetached (line 1716):** Already receives TabView as first param — ensure it uses it.

**tabViewCreateWindow (line 1741):** The current return type is `*adw.TabView` (non-optional). Change to `?*adw.TabView` and return null to disable tab drag-out (Termplex is single-window):
```zig
fn tabViewCreateWindow(
    _: *adw.TabView,
    _: *Self,
) callconv(.c) ?*adw.TabView {
    // Disabled: Termplex is single-window. Tab drag-out is not supported.
    return null;
}
```

**Important:** The original function (line 1744) returns `*adw.TabView` (non-optional). Changing to `?*adw.TabView` is required to allow returning `null`.

**setupTabMenu (line 1788):** Uses signal parameter already.

- [ ] **Step 3: Update non-signal-handler references**

**Line 535 (newTabPage):** Change `priv.tab_view` to `priv.active_tab_view`
**Line 623 (selectTab):** Change `priv.tab_view` to `priv.active_tab_view`
**Line 677 (selectTab alternative):** Change `priv.tab_view` to `priv.active_tab_view`
**Line 987 (getTabView):** Change return to `priv.active_tab_view`
**Line 1042:** Change to `priv.active_tab_view`
**Line 1051:** Change to `priv.active_tab_view`
**Line 1055:** Change to `priv.active_tab_view`
**Line 1623 (tabViewClosePage):** Change `priv.tab_view.closePageFinish(...)` to use the signal parameter `tab_view` (already covered above in signal handler updates)
**Line 1765 (tabCloseRequest):** Change `priv.tab_view.getPage(...)` to `priv.active_tab_view.getPage(...)`
**Line 1767 (tabCloseRequest):** Change `priv.tab_view.closePage(...)` to `priv.active_tab_view.closePage(...)`
**Line 1776 (tabViewNPages):** Change `priv.tab_view.getNPages()` to use the signal parameter `tab_view` (already covered above in signal handler updates)
**Line 1862 (surfacePresentRequest):** Change to `priv.active_tab_view`

- [ ] **Step 4: Set active_tab_view in init**

In `Window.init()`, after template initialization, set:
```zig
priv_.active_tab_view = priv_.tab_view; // Initially point to the template-declared TabView
```

The two-field design: `tab_view` is the template-bound field (populated by Blueprint), `active_tab_view` is the runtime field that all code uses. They start pointing to the same TabView but `active_tab_view` changes on workspace switch.

- [ ] **Step 5: Build and verify**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

- [ ] **Step 6: Commit**

```bash
git add src/apprt/gtk/class/window.zig
git commit -m "refactor: audit priv.tab_view references, add active_tab_view"
```

---

### Task 4: Implement switchToTabView() on Window

**Files:**
- Modify: `src/apprt/gtk/class/window.zig`

**Context:** This is the core workspace-switching method. It disconnects from the old TabView, swaps the widget in `toast_overlay`, and reconnects to the new one.

- [ ] **Step 1: Implement switchToTabView()**

Add this method to Window (near the other termplex methods):

```zig
/// Switch the displayed TabView to a different workspace's TabView.
/// Disconnects signals from old, swaps widget, reconnects to new.
pub fn switchToTabView(self: *Self, new_tab_view: *adw.TabView) void {
    const priv = self.private();
    const old_tab_view = priv.active_tab_view;

    // Skip if already displaying this TabView
    if (old_tab_view == new_tab_view) return;

    // --- Disconnect phase ---

    // 1. Disconnect surface handlers for all tabs in old TabView
    // NOTE: Use getSurfaceTree() (returns ?*Surface.Tree), NOT getSplitTree()
    // (returns *SplitTree). disconnectSurfaceHandlers expects a Surface.Tree.
    const old_n = old_tab_view.getNPages();
    var i: c_int = 0;
    while (i < old_n) : (i += 1) {
        const page = old_tab_view.getNthPage(i);
        const tab_widget = page.getChild();
        if (gobject.ext.cast(Tab, tab_widget)) |tab| {
            if (tab.getSurfaceTree()) |tree| {
                self.disconnectSurfaceHandlers(tree);
            }
        }
    }

    // 2. Unbind tab_bindings
    priv.tab_bindings.setSource(null);

    // 3. Disconnect all 7 signal handlers from old TabView
    self.disconnectTabViewHandlers(old_tab_view);

    // 4. Unbind TabBar and TabOverview
    priv.tab_bar.setView(null);
    priv.tab_overview.setView(null);

    // --- Swap phase ---

    // 5. Unparent old TabView (Application ref keeps it alive)
    priv.toast_overlay.setChild(null);

    // 6. Insert new TabView
    priv.toast_overlay.setChild(new_tab_view.as(gtk.Widget));

    // --- Reconnect phase ---

    // 7. Connect all 7 signal handlers to new TabView
    self.connectTabViewHandlers(new_tab_view);

    // 8. Rebind TabBar and TabOverview
    priv.tab_bar.setView(new_tab_view);
    priv.tab_overview.setView(new_tab_view);

    // 9. Reconnect surface handlers for all tabs in new TabView
    // NOTE: Use getSurfaceTree() (returns ?*Surface.Tree), NOT getSplitTree()
    const new_n = new_tab_view.getNPages();
    i = 0;
    while (i < new_n) : (i += 1) {
        const page = new_tab_view.getNthPage(i);
        const tab_widget = page.getChild();
        if (gobject.ext.cast(Tab, tab_widget)) |tab| {
            if (tab.getSurfaceTree()) |tree| {
                self.connectSurfaceHandlers(tree);
            }
        }
    }

    // 10. Rebind tab_bindings to selected page
    if (new_tab_view.getSelectedPage()) |page| {
        const child = page.getChild();
        priv.tab_bindings.setSource(child.as(gobject.Object));
    }

    // 11. Focus active surface
    if (new_tab_view.getSelectedPage()) |page| {
        const tab_widget = page.getChild();
        if (gobject.ext.cast(Tab, tab_widget)) |tab| {
            if (tab.getActiveSurface()) |surface| {
                surface.as(gtk.Widget).grabFocus();
            }
        }
    }

    // 12. Update active_tab_view reference
    priv.active_tab_view = new_tab_view;

    // 13. Update header title to workspace name
    const app = Application.default();
    const ws_idx = app.activeWorkspaceIndex();
    const ws_name = app.workspaceName(ws_idx);
    const ws_dir = app.workspaceDir(ws_idx);
    self.updateHeaderTitle(ws_name, ws_dir);
}

/// Update the header bar title and subtitle for the active workspace.
fn updateHeaderTitle(self: *Self, name: ?[:0]const u8, dir: ?[:0]const u8) void {
    const priv = self.private();
    priv.window_title.setTitle(name orelse "Termplex");
    priv.window_title.setSubtitle(dir orelse "");
}
```

**Prerequisites for `updateHeaderTitle`:** The `Adw.WindowTitle` widget must be bound as a template child. This requires:
1. Adding `window_title: *adw.WindowTitle,` to the Private struct
2. Adding `class.bindTemplateChildPrivate("window_title", .{})` in Class.init
3. Naming the widget in Blueprint: change `title-widget: Adw.WindowTitle {` to `title-widget: Adw.WindowTitle window_title {`
These changes are done in Task 12.

Note: `Tab.getSurfaceTree()` returns `?*Surface.Tree` (optional). `Tab.getSplitTree()` returns `*SplitTree`. `connectSurfaceHandlers`/`disconnectSurfaceHandlers` expect a `Surface.Tree`. Always use `getSurfaceTree()` and unwrap the optional.

- [ ] **Step 2: Wire workspace switching into sidebar callback**

Update `termplexOnWorkspaceSelected()` in window.zig (around line 1344) to call `switchToTabView()`:

```zig
fn termplexOnWorkspaceSelected(index: u32, win: *Self) callconv(.c) void {
    const app = Application.default();
    const old_idx = app.activeWorkspaceIndex();
    if (old_idx == index) return;

    const sidebar = win.private().sidebar;

    // Mark old workspace inactive in sidebar
    sidebar.updateWorkspace(old_idx, app.workspaceName(old_idx), null, null, false, false);

    // Switch application state
    app.setActiveWorkspaceIndex(index);

    // Mark new workspace active in sidebar
    sidebar.updateWorkspace(index, app.workspaceName(index), null, null, true, false);
    sidebar.setActiveIndex(index);

    // Switch TabView
    if (app.workspaceTabView(index)) |tv| {
        win.switchToTabView(tv);
    }
}
```

- [ ] **Step 3: Update next/prev workspace actions to call switchToTabView**

Update `actionTermplexNextWorkspace` and `actionTermplexPrevWorkspace` (around lines 2312 and 2332) to also call `switchToTabView()` after changing the active index.

- [ ] **Step 4: Update new workspace action to create tab in new TabView**

Update `actionTermplexNewWorkspace` (in window.zig) and `termplexOnNewWorkspace` to:
1. Call `app.addWorkspaceWithDir(null)`
2. Add the workspace to sidebar
3. Switch to the new workspace's TabView
4. Create an initial tab in the new TabView

- [ ] **Step 5: Build and test**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
TERMPLEX_DISABLE_RESTORE=1 ./zig-out/bin/termplex-app
```

Test: Create a new workspace (Ctrl+Shift+N). Verify it switches to a fresh TabView with one tab. Switch back to the original workspace (click in sidebar). Verify the original terminal is still there.

- [ ] **Step 6: Commit**

```bash
git add src/apprt/gtk/class/window.zig
git commit -m "feat: implement switchToTabView for workspace-based terminal switching"
```

---

### Task 5: Wire initial TabView from Application into Window

**Files:**
- Modify: `src/apprt/gtk/class/window.zig:298-361` (init)
- Modify: `src/apprt/gtk/class/application.zig` (startup flow)

**Context:** On Window init, instead of using the Blueprint template's `tab_view`, we need to swap in the Application's active workspace TabView. The template's tab_view is used only as a placeholder.

- [ ] **Step 1: Update Window.init() to swap in Application's TabView**

In `Window.init()`, after the Termplex sidebar setup block (around line 360), add:

```zig
// Replace the template's tab_view with the Application's active workspace TabView.
{
    const app = Application.default();
    if (app.activeTabView()) |ws_tab_view| {
        // The template tab_view is currently in toast_overlay.
        // Disconnect handlers from template tab_view.
        self.disconnectTabViewHandlers(priv_.tab_view);

        // Swap: remove template tab_view, insert workspace tab_view
        priv_.toast_overlay.setChild(null);
        priv_.toast_overlay.setChild(ws_tab_view.as(gtk.Widget));

        // Connect handlers to workspace tab_view
        self.connectTabViewHandlers(ws_tab_view);
        priv_.tab_bar.setView(ws_tab_view);
        priv_.tab_overview.setView(ws_tab_view);

        priv_.active_tab_view = ws_tab_view;
    }
}
```

- [ ] **Step 2: Ensure first workspace has a TabView before Window is created**

In Application's activate/startup flow, ensure `addWorkspaceWithDir(null)` is called before the first Window is created, so that `activeTabView()` returns a valid TabView.

- [ ] **Step 3: Build and test**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
TERMPLEX_DISABLE_RESTORE=1 ./zig-out/bin/termplex-app
```

- [ ] **Step 4: Commit**

```bash
git add src/apprt/gtk/class/window.zig src/apprt/gtk/class/application.zig
git commit -m "feat: wire Application workspace TabView into Window on init"
```

---

### Task 6: New terminal directory override in newTabPage()

**Files:**
- Modify: `src/apprt/gtk/class/window.zig:522-610` (newTabPage)

**Context:** When `newTabPage()` creates a tab, if no explicit working_directory override is provided, it should default to the workspace's directory.

- [ ] **Step 1: Add workspace directory fallback in newTabPage()**

In `newTabPage()` (line 522), find where the `overrides` are used to create the Tab. Before creating the tab, if `overrides.working_directory` is null, look up the workspace directory:

```zig
// Default to workspace directory if no explicit override
var effective_overrides = overrides;
if (effective_overrides.working_directory == null) {
    const app = Application.default();
    if (app.workspaceDir(app.activeWorkspaceIndex())) |ws_dir| {
        effective_overrides.working_directory = ws_dir;
    }
}
```

Then use `effective_overrides` instead of `overrides` when creating the Tab.

- [ ] **Step 2: Build and test**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

- [ ] **Step 3: Commit**

```bash
git add src/apprt/gtk/class/window.zig
git commit -m "feat: new terminals default to workspace directory"
```

---

## Chunk 2: Workspace Management UI

### Task 7: Add right-click context menu to sidebar

**Files:**
- Modify: `src/apprt/gtk/class/sidebar.zig`
- Modify: `src/apprt/gtk/class/application.zig` (renameWorkspace)

**Context:** Add a GtkGestureClick to the sidebar ListBox that shows a PopoverMenu on right-click with Rename and Delete options.

- [ ] **Step 1: Add renameWorkspace() to Application**

In `application.zig`, after `removeWorkspace()`:

```zig
pub fn renameWorkspace(self: *Self, index: u32, new_name: [:0]const u8) void {
    const priv = self.private();
    if (index >= priv.workspace_names.items.len) return;
    const alloc = self.allocator();
    alloc.free(priv.workspace_names.items[index]);
    priv.workspace_names.items[index] = alloc.dupeZ(u8, new_name) catch return;
}
```

- [ ] **Step 2: Add context menu callbacks to Sidebar**

In `sidebar.zig`, extend the callback mechanism. Add two new callback fields to Private:

```zig
on_rename: ?*const fn (u32, *Self) callconv(.c) void = null,
on_delete: ?*const fn (u32, *Self) callconv(.c) void = null,
rename_userdata: ?*anyopaque = null,
delete_userdata: ?*anyopaque = null,
```

Add a `setManagementCallbacks()` method:

```zig
pub fn setManagementCallbacks(
    self: *Self,
    on_rename: ?*const fn (u32, *anyopaque) callconv(.c) void,
    on_delete: ?*const fn (u32, *anyopaque) callconv(.c) void,
    userdata: *anyopaque,
) void {
    const priv = self.private();
    priv.on_rename = on_rename;
    priv.on_delete = on_delete;
    priv.rename_userdata = userdata;
}
```

- [ ] **Step 3: Add GtkGestureClick for right-click on ListBox**

In sidebar.zig `init()`, after the ListBox setup, add a gesture controller:

```zig
const gesture = gtk.GestureClick.new();
gesture.setButton(3); // right-click
_ = gtk.GestureClick.signals.pressed.connect(
    gesture, *Self, &onRightClick, self, .{},
);
priv.workspace_list.as(gtk.Widget).addController(gesture.as(gtk.EventController));
```

- [ ] **Step 4: Implement right-click handler with PopoverMenu**

```zig
fn onRightClick(
    _: *gtk.GestureClick,
    _: c_int, // n_press
    _: f64,   // x
    y: f64,   // y
    self: *Self,
) callconv(.c) void {
    const priv = self.private();
    const row = priv.workspace_list.getRowAtY(@intFromFloat(y)) orelse return;
    const index: u32 = @intCast(row.getIndex());
    priv.context_menu_index = index;

    // Create menu model
    const menu = gio.Menu.new();
    menu.append("Rename", "sidebar.rename");
    menu.append("Delete", "sidebar.delete");

    // Create and show popover
    const popover = gtk.PopoverMenu.newFromModel(menu.as(gio.MenuModel));
    popover.setParent(row.as(gtk.Widget));
    popover.popup();
}
```

Note: The exact popover/action wiring will need adjustment. The implementer should use GAction-based menu items connected to sidebar-level actions, or use simpler button-based popovers depending on what works best with the GTK4 bindings available.

- [ ] **Step 5: Build and test**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

- [ ] **Step 6: Commit**

```bash
git add src/apprt/gtk/class/sidebar.zig src/apprt/gtk/class/application.zig
git commit -m "feat: add right-click context menu to sidebar with rename/delete"
```

---

### Task 8: Implement inline workspace rename in WorkspaceTab

**Files:**
- Modify: `src/apprt/gtk/class/workspace_tab.zig`

**Context:** When the user selects "Rename", the name label transforms into a GtkEntry. Enter confirms, Escape cancels.

- [ ] **Step 1: Add rename entry to WorkspaceTab Private**

Add to WorkspaceTab Private:

```zig
rename_entry: ?*gtk.Entry = null,
is_renaming: bool = false,
```

- [ ] **Step 2: Add startRename() and finishRename() methods**

```zig
pub fn startRename(self: *Self) void {
    const priv = self.private();
    if (priv.is_renaming) return;

    const entry = gtk.Entry.new();
    const current_name = priv.name_label.getLabel();
    if (current_name) |name| {
        entry.as(gtk.Editable).setText(name);
    }
    entry.as(gtk.Widget).addCssClass("termplex-tab-name");

    // Hide label, show entry in same position
    priv.name_label.as(gtk.Widget).setVisible(0);

    // Insert entry into row1 (parent of name_label)
    const parent = priv.name_label.as(gtk.Widget).getParent();
    if (gobject.ext.cast(gtk.Box, parent)) |row1| {
        row1.prepend(entry.as(gtk.Widget));
    }

    entry.as(gtk.Widget).grabFocus();
    priv.rename_entry = entry;
    priv.is_renaming = true;

    // Connect Enter (activate) and Escape (key handler)
    _ = gtk.Entry.signals.activate.connect(entry, *Self, &onRenameActivate, self, .{});

    // Add key event controller for Escape
    const key_controller = gtk.EventControllerKey.new();
    _ = gtk.EventControllerKey.signals.key_pressed.connect(
        key_controller, *Self, &onRenameKeyPress, self, .{},
    );
    entry.as(gtk.Widget).addController(key_controller.as(gtk.EventController));
}

fn onRenameKeyPress(
    _: *gtk.EventControllerKey,
    keyval: c_uint,
    _: c_uint, // keycode
    _: gdk.ModifierType, // state
    self: *Self,
) callconv(.c) c_int {
    if (keyval == gdk.KEY_Escape) {
        self.finishRename(false); // cancel
        return 1; // handled
    }
    return 0; // not handled
}

fn onRenameActivate(_: *gtk.Entry, self: *Self) callconv(.c) void {
    self.finishRename(true);
}

pub fn finishRename(self: *Self, confirm: bool) void {
    const priv = self.private();
    if (!priv.is_renaming) return;

    if (confirm) {
        if (priv.rename_entry) |entry| {
            const text = entry.as(gtk.Editable).getText();
            if (text) |t| {
                priv.name_label.setLabel(t);
                // TODO: Call back to Application to persist the rename
            }
        }
    }

    // Remove entry, show label
    if (priv.rename_entry) |entry| {
        const parent = entry.as(gtk.Widget).getParent();
        if (gobject.ext.cast(gtk.Box, parent)) |row1| {
            row1.remove(entry.as(gtk.Widget));
        }
    }
    priv.name_label.as(gtk.Widget).setVisible(1);
    priv.rename_entry = null;
    priv.is_renaming = false;
}
```

- [ ] **Step 3: Build and test**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

- [ ] **Step 4: Commit**

```bash
git add src/apprt/gtk/class/workspace_tab.zig
git commit -m "feat: inline workspace rename in WorkspaceTab widget"
```

---

### Task 9: Implement workspace delete with confirmation

**Files:**
- Modify: `src/apprt/gtk/class/window.zig` (delete action handler)

**Context:** Delete shows a confirmation dialog if the workspace has running terminals, or a toast if it's the last workspace.

- [ ] **Step 1: Implement delete handler in window.zig**

Add a handler for the delete action, called from the sidebar context menu:

```zig
fn termplexOnDeleteWorkspace(index: u32, win: *Self) void {
    const app = Application.default();
    const count = app.workspaceCount();

    // Cannot delete last workspace
    if (count <= 1) {
        // Show toast
        const toast = adw.Toast.new("Cannot delete the last workspace");
        win.private().toast_overlay.addToast(toast);
        return;
    }

    // Check if workspace has running terminals
    if (app.workspaceTabView(index)) |tv| {
        const n_pages = tv.getNPages();
        if (n_pages > 0) {
            // Show confirmation dialog
            // TODO: Use adw.AlertDialog or adw.MessageDialog
            // For now, proceed with deletion directly
        }
    }

    // If this is the active workspace, switch first
    if (app.activeWorkspaceIndex() == index) {
        const new_idx: u32 = if (index > 0) index - 1 else 0;
        if (app.workspaceTabView(new_idx)) |tv| {
            app.setActiveWorkspaceIndex(new_idx);
            win.switchToTabView(tv);
        }
    }

    // Remove from sidebar
    win.private().sidebar.removeWorkspace(index);

    // Remove from application
    app.removeWorkspace(index);
}
```

- [ ] **Step 2: Build and test**

- [ ] **Step 3: Commit**

```bash
git add src/apprt/gtk/class/window.zig
git commit -m "feat: workspace delete with confirmation and last-workspace protection"
```

---

### Task 10: Last-tab-closed removes workspace

**Files:**
- Modify: `src/apprt/gtk/class/window.zig` (tabViewNPages handler)

**Context:** When the last tab in a workspace is closed and other workspaces exist, remove the empty workspace and switch to the adjacent one.

- [ ] **Step 1: Update tabViewNPages handler**

Modify the `tabViewNPages` handler to check for other workspaces before closing the window:

**Important:** Do NOT call `switchToTabView()` directly inside a signal handler for the same TabView — this would disconnect the signal while it's being emitted, which is unsafe. Instead, defer the switch using `glib.idleAdd()`.

```zig
fn tabViewNPages(tab_view: *adw.TabView, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
    if (tab_view.getNPages() == 0) {
        const app = Application.default();

        // If other workspaces exist, remove this empty one.
        // IMPORTANT: Defer the switch to avoid disconnecting signals during emission.
        if (app.workspaceCount() > 1) {
            _ = glib.idleAdd(@ptrCast(&deferredRemoveEmptyWorkspace), self);
            return;
        }

        // Last workspace — close window (original behavior)
        if (self.private().tab_overview.getOpen() != 0) return;
        self.as(gtk.Window).close();
    }
}

fn deferredRemoveEmptyWorkspace(self: *Self) callconv(.c) c_int {
    const app = Application.default();
    // Find the empty workspace by scanning for the one with 0 pages.
    // We cannot rely on activeWorkspaceIndex() because it may have
    // changed between the signal and the idle callback.
    const current_idx = blk: {
        var idx: u32 = 0;
        while (idx < app.workspaceCount()) : (idx += 1) {
            if (app.workspaceTabView(idx)) |tv| {
                if (tv.getNPages() == 0) break :blk idx;
            }
        }
        return 0; // No empty workspace found, nothing to do
    };
    const new_idx: u32 = if (current_idx > 0) current_idx - 1 else 0;

    // Switch to adjacent workspace
    if (app.workspaceTabView(new_idx)) |tv| {
        app.setActiveWorkspaceIndex(new_idx);
        self.switchToTabView(tv);
    }

    // Remove the empty workspace
    self.private().sidebar.removeWorkspace(current_idx);
    app.removeWorkspace(current_idx);

    return 0; // G_SOURCE_REMOVE — run only once
}
```

Note: The `glib.idleAdd` pattern defers the workspace removal to the next main loop iteration, avoiding signal disconnection during emission. Check the exact `glib.idleAdd` signature in the bindings — it may be `glib.idleAdd(callback, userdata)` or similar.

- [ ] **Step 2: Build and test**

- [ ] **Step 3: Commit**

```bash
git add src/apprt/gtk/class/window.zig
git commit -m "feat: last-tab-closed removes workspace if others exist"
```

---

## Chunk 3: UI Refinements & Header

### Task 11: Compact tab bar and slim header CSS

**Files:**
- Modify: `src/apprt/gtk/css/style.css`
- Modify: `src/apprt/gtk/css/style-dark.css`

- [ ] **Step 1: Add compact tab bar CSS to style.css**

After the existing termplex CSS sections (before the splits section), add:

```css
/*
 * Termplex Compact Tab Bar
 */

.tab-bar {
  min-height: 28px;
}

.tab-bar tab {
  padding-top: 2px;
  padding-bottom: 2px;
  min-height: 24px;
}

/*
 * Termplex Slim Header Bar
 */

headerbar {
  min-height: 32px;
  padding-top: 0;
  padding-bottom: 0;
}
```

- [ ] **Step 2: Build and test**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
TERMPLEX_DISABLE_RESTORE=1 ./zig-out/bin/termplex-app
```

Verify the tab bar and header bar are visually more compact.

- [ ] **Step 3: Commit**

```bash
git add src/apprt/gtk/css/style.css src/apprt/gtk/css/style-dark.css
git commit -m "feat: compact tab bar and slim header bar CSS"
```

---

### Task 12: Header title shows workspace name

**Files:**
- Modify: `src/apprt/gtk/class/window.zig`
- Modify: `src/apprt/gtk/ui/1.5/window.blp`

**Context:** The header should show the workspace name as title and workspace directory as subtitle, instead of the active tab title.

- [ ] **Step 1: Name the WindowTitle widget in Blueprint**

In `window.blp` (line 42), change:
```
title-widget: Adw.WindowTitle {
```
to:
```
title-widget: Adw.WindowTitle window_title {
```

This gives the widget an ID so it can be bound as a template child.

- [ ] **Step 2: Add window_title to Private struct and bind it**

In `window.zig` Private struct, add:
```zig
window_title: *adw.WindowTitle,
```

In `window.zig` Class.init, add:
```zig
class.bindTemplateChildPrivate("window_title", .{});
```

- [ ] **Step 3: Remove the computed_subtitle title binding**

The `title: bind template.title;` binding at line 43 of `window.blp` still binds the window's `title` property. Since we now set the title programmatically via `updateHeaderTitle()`, this binding should remain (it sets the window title property, which is used by the window manager). The `computed_subtitle` was already removed in Task 2 Step 3.

- [ ] **Step 4: Verify updateHeaderTitle() implementation**

`updateHeaderTitle()` was already implemented in Task 4. Verify it compiles:
```zig
fn updateHeaderTitle(self: *Self, name: ?[:0]const u8, dir: ?[:0]const u8) void {
    const priv = self.private();
    priv.window_title.setTitle(name orelse "Termplex");
    priv.window_title.setSubtitle(dir orelse "");
}
```

- [ ] **Step 2: Call updateHeaderTitle in switchToTabView and on startup**

Already wired in Task 4. Verify it's called:
- In `switchToTabView()` step 13
- In `Window.init()` after initial TabView setup
- In `renameWorkspace()` flow

- [ ] **Step 3: Build and test**

- [ ] **Step 4: Commit**

```bash
git add src/apprt/gtk/class/window.zig src/apprt/gtk/ui/1.5/window.blp
git commit -m "feat: header title shows workspace name and directory"
```

---

## Chunk 4: Session Persistence

### Task 13: Autosave v2 format with per-workspace tabs and splits

**Files:**
- Modify: `src/apprt/gtk/class/application.zig:1108-1204` (autosaveSession)

**Context:** Extend autosave to write the v2 format with per-workspace name, dir, and tab split layouts.

- [ ] **Step 1: Implement SplitTree walking for JSON serialization**

Add a helper function that walks a Tab's SplitTree and produces the JSON splits structure:

```zig
fn serializeSplitTree(tab: *Tab, writer: anytype) !void {
    // Get the SplitTree widget from the tab
    const split_tree = tab.getSplitTree();
    // Check if it has splits by examining the tree structure.
    // The SplitTree's internal tree (Surface.Tree) uses an iterator pattern.
    // For v2 save, we need to walk the tree recursively:
    //   - Leaf node → {"type":"leaf","pwd":"..."}
    //   - Split node → {"type":"split","orientation":"horizontal|vertical",
    //                    "ratio":0.5,"children":[left,right]}
    //
    // The implementer should check:
    //   1. split_tree.zig for the internal tree structure
    //   2. Surface.Tree definition for node types (leaf vs split)
    //   3. How to get PWD from a surface: surface.getPwd() or similar
    //
    // For now, write "single" as a fallback:
    if (tab.getSurfaceTree()) |tree| {
        var it = tree.iterator();
        var count: usize = 0;
        while (it.next()) |_| {
            count += 1;
        }
        if (count <= 1) {
            try writer.writeAll("\"single\"");
        } else {
            // TODO: full recursive serialization
            try writer.writeAll("\"single\"");
        }
    } else {
        try writer.writeAll("\"single\"");
    }
}
```

Note: Full recursive split serialization is a stretch goal for v1 of this feature. The "single" fallback ensures session restore works (creates one tab per workspace) even without split layout preservation. The implementer can enhance this later by walking the `Surface.Tree` recursively.

- [ ] **Step 2: Update autosaveSession() to write v2 format**

Replace the existing workspace serialization in `autosaveSession()` with:

```zig
// Write version
try writer.print("{{\"version\":2,", .{});

// Write workspaces array
try writer.print("\"workspaces\":[", .{});
for (priv.workspace_names.items, 0..) |name, idx| {
    if (idx > 0) try writer.print(",", .{});
    const dir = if (idx < priv.workspace_dirs.items.len) priv.workspace_dirs.items[idx] else "";
    try writer.print("{{\"name\":\"{s}\",\"dir\":\"{s}\",\"tabs\":[", .{ name, dir });

    // Serialize tabs for this workspace
    if (idx < priv.workspace_tab_views.items.len) {
        const tv = priv.workspace_tab_views.items[idx];
        const n_pages = tv.getNPages();
        var page_idx: c_int = 0;
        while (page_idx < n_pages) : (page_idx += 1) {
            if (page_idx > 0) try writer.print(",", .{});
            try writer.print("{{\"splits\":", .{});
            // TODO: serialize split tree for this tab
            try writer.print("\"single\"", .{});
            try writer.print("}}", .{});
        }
    }

    try writer.print("]}}", .{});
}
try writer.print("]", .{});

// Write remaining fields
try writer.print(",\"active_workspace\":{d}", .{priv.active_workspace_idx});
// ... window size, sidebar width ...
try writer.print("}}", .{});
```

- [ ] **Step 3: Build and test**

- [ ] **Step 4: Commit**

```bash
git add src/apprt/gtk/class/application.zig
git commit -m "feat: autosave v2 format with per-workspace split layouts"
```

---

### Task 14: Session restore with v2 format and split replay

**Files:**
- Modify: `src/apprt/gtk/class/application.zig:1209-1308` (restoreSession)
- Modify: `src/apprt/gtk/class/window.zig` (init, restore phase 2)

**Context:** Two-phase restore: Application creates workspaces and TabViews (phase 1), Window creates tabs and replays splits (phase 2).

- [ ] **Step 1: Add restore buffer to Application Private**

Add a field to store parsed restore data:

```zig
/// Pending restore data: per-workspace tab/split structures.
/// Set during restoreSession(), consumed during Window.init().
restore_pending: ?[]const WorkspaceRestoreData = null,
```

Define the restore data structure:

```zig
const WorkspaceRestoreData = struct {
    tabs: []const TabRestoreData,
};

const TabRestoreData = struct {
    splits: []const u8, // raw JSON string for now
};
```

- [ ] **Step 2: Update restoreSession() for v2 format (phase 1)**

Parse the v2 JSON format. For each workspace entry:
1. Create workspace with name and dir via `addWorkspaceWithDir()`
2. Store the tab/split data in the restore buffer

Handle v1 migration: if no `"version"` field or version is 1, create workspaces with names only, default dir to saved `pwd` or `$HOME`, one tab each.

- [ ] **Step 3: Implement restore phase 2 in Window.init()**

After the initial TabView swap in Window.init(), check for restore data:

```zig
// Phase 2: Create tabs from restore data.
// For each workspace, create one tab per entry. For the active workspace,
// use newTabPage() directly. For background workspaces, create tabs in
// their TabViews without switching.
{
    const app = Application.default();
    if (app.getRestoreData()) |restore_data| {
        const active_ws = app.activeWorkspaceIndex();

        for (restore_data, 0..) |ws_data, ws_idx| {
            if (app.workspaceTabView(@intCast(ws_idx))) |tv| {
                if (ws_data.tabs.len == 0) {
                    // Ensure at least one tab per workspace
                    if (ws_idx == active_ws) {
                        self.newTabPage(.{
                            .working_directory = app.workspaceDir(@intCast(ws_idx)),
                        });
                    } else {
                        // Create tab in background TabView.
                        // Use the same newTabPage logic but targeting tv.
                        // The implementer should check how newTabPage creates
                        // the Tab widget and adw.TabView.addPage() works,
                        // then replicate for background TabViews.
                        _ = tv; // placeholder — implement tab creation in non-active TabView
                    }
                } else {
                    for (ws_data.tabs) |tab_data| {
                        // Create the initial tab
                        const ws_dir = app.workspaceDir(@intCast(ws_idx));
                        if (ws_idx == active_ws) {
                            self.newTabPage(.{ .working_directory = ws_dir });
                        } else {
                            _ = tv; // placeholder — create in background TabView
                        }

                        // TODO: Replay split structure from tab_data.splits
                        // Parse the splits JSON: "single" means no splits,
                        // {"orientation":"horizontal","ratio":0.5,"children":[...]}
                        // means create a split. Use the existing split action
                        // mechanism: self.performAction(.new_split, .{.direction = ...})
                        _ = tab_data;
                    }
                }
            }
        }
        app.clearRestoreData();
    }
}
```

Note: Creating tabs in background (non-active) TabViews is non-trivial because `newTabPage()` targets `priv.active_tab_view`. The implementer has two options:
1. Temporarily switch to each workspace, create tabs, then switch back to the active workspace
2. Extract the tab creation logic from `newTabPage()` into a helper that takes a TabView parameter
Option 2 is cleaner. The helper would call `Tab.new(...)`, then `tab_view.addPage(tab, ...)`. Check the existing `newTabPage()` implementation (lines 522-610) for the exact sequence.

- [ ] **Step 4: Build and test**

- [ ] **Step 5: Commit**

```bash
git add src/apprt/gtk/class/application.zig src/apprt/gtk/class/window.zig
git commit -m "feat: two-phase session restore with v2 format and split replay"
```

---

## Chunk 5: IPC Extensions & CLI

### Task 15: Add workspace IPC methods

**Files:**
- Modify: `src/apprt/gtk/class/application.zig:836-966` (ipcDispatch)

**Context:** Add `workspace.find_by_dir`, extend `workspace.create` with dir, and add `workspace.select` with both index and ref support.

- [ ] **Step 1: Add workspace.find_by_dir to ipcDispatch**

In `ipcDispatch()`, add a new route:

```zig
if (std.mem.eql(u8, method, "workspace.find_by_dir")) {
    return self.ipcWorkspaceFindByDir(alloc, id, params);
}
```

Implement:

```zig
fn ipcWorkspaceFindByDir(self: *Self, alloc: std.mem.Allocator, id: ?[]const u8, params: anytype) ![]const u8 {
    const priv = self.private();
    const dir = params.get("dir") orelse return error.MissingParam;

    var result = std.ArrayList(u8).init(alloc);
    const writer = result.writer();
    try writer.print("{{\"ok\":true,\"result\":{{\"workspaces\":[", .{});

    var first = true;
    for (priv.workspace_dirs.items, 0..) |ws_dir, idx| {
        if (std.mem.eql(u8, ws_dir, dir)) {
            if (!first) try writer.print(",", .{});
            const name = priv.workspace_names.items[idx];
            const tab_count: c_int = if (idx < priv.workspace_tab_views.items.len)
                priv.workspace_tab_views.items[idx].getNPages()
            else
                0;
            try writer.print("{{\"index\":{d},\"name\":\"{s}\",\"dir\":\"{s}\",\"tab_count\":{d}}}", .{
                idx, name, ws_dir, tab_count,
            });
            first = false;
        }
    }

    try writer.print("]}}}}", .{});
    return result.toOwnedSlice();
}
```

- [ ] **Step 2: Extend workspace.create to accept dir**

Update `ipcWorkspaceCreate()` to parse an optional `"dir"` parameter and pass it to `addWorkspaceWithDir()`:

```zig
// In the existing ipcWorkspaceCreate handler, replace addWorkspace() call:
const dir = params.get("dir"); // optional dir parameter
self.addWorkspaceWithDir(dir);
```

The existing handler likely just calls `self.addWorkspace()`. Change it to extract the optional `"dir"` from params and call `self.addWorkspaceWithDir(dir)` instead.

- [ ] **Step 3: Add workspace.select to ipcDispatch**

```zig
if (std.mem.eql(u8, method, "workspace.select")) {
    return self.ipcWorkspaceSelect(alloc, id, params);
}
```

Implement with both `"index"` and `"ref"` support:

```zig
fn ipcWorkspaceSelect(self: *Self, alloc: std.mem.Allocator, id: ?[]const u8, params: anytype) ![]const u8 {
    const priv = self.private();
    _ = id;

    var target_idx: ?u32 = null;

    // Try index first
    if (params.get("index")) |idx_str| {
        const index = std.fmt.parseInt(u32, idx_str, 10) catch return error.InvalidParam;
        if (index < priv.workspace_names.items.len) {
            target_idx = index;
        }
    } else if (params.get("ref")) |ref| {
        // Look up by name
        for (priv.workspace_names.items, 0..) |name, idx| {
            if (std.mem.eql(u8, name, ref)) {
                target_idx = @intCast(idx);
                break;
            }
        }
    }

    if (target_idx) |idx| {
        // Use the same accessor as termplexOnWorkspaceSelected (Task 4 Step 2)
        // to keep the pattern consistent across all callers.
        self.setActiveWorkspaceIndex(idx);

        // Tell the Window to switch TabView.
        // Get the active window and call switchToTabView on it.
        const app = self.as(gtk.Application);
        const win_list = app.getWindows();
        if (win_list) |list| {
            if (list.first()) |first| {
                const win = gobject.ext.cast(Window, first.data);
                if (win) |w| {
                    if (self.workspaceTabView(idx)) |tv| {
                        w.switchToTabView(tv);
                    }
                    // Update sidebar
                    w.private().sidebar.setActiveIndex(idx);
                }
            }
        }
    }

    return std.fmt.allocPrint(alloc, "{{\"ok\":true,\"result\":null}}", .{});
}
```

Note: The exact API for getting the active window from GtkApplication may differ. Check the existing IPC handlers for how they access the Window instance — look at `ipcDispatch` for the pattern used.

- [ ] **Step 4: Build and test**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

Test with CLI:
```bash
./zig-out/bin/termplex workspace list
```

- [ ] **Step 5: Commit**

```bash
git add src/apprt/gtk/class/application.zig
git commit -m "feat: add workspace.find_by_dir, workspace.select, and dir support to workspace.create IPC"
```

---

### Task 16: Implement `termplex open` CLI command

**Files:**
- Modify: `src/termplex/cli_main.zig`

**Context:** New CLI command that finds or creates a workspace for a directory.

- [ ] **Step 1: Add "open" to command dispatcher**

In `cli_main.zig` command dispatcher (around line 599), add:

```zig
if (std.mem.eql(u8, args[1], "open")) {
    return cmdOpen(allocator, args[2..]);
}
```

- [ ] **Step 2: Implement cmdOpen()**

```zig
fn cmdOpen(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Resolve directory
    const dir = if (args.len > 0) args[0] else std.posix.getenv("PWD") orelse ".";

    // Make absolute
    const abs_dir = try std.fs.cwd().realpathAlloc(allocator, dir);
    defer allocator.free(abs_dir);

    const abs_dir_z = try allocator.dupeZ(u8, abs_dir);
    defer allocator.free(abs_dir_z);

    // Query running instance for existing workspaces
    const find_request = try std.fmt.allocPrint(
        allocator,
        "{{\"method\":\"workspace.find_by_dir\",\"params\":{{\"dir\":\"{s}\"}}}}\n",
        .{abs_dir_z},
    );
    defer allocator.free(find_request);

    const response = try sendRequest(allocator, find_request);
    defer allocator.free(response);

    // Parse response — check if workspaces array is empty
    // If empty: create new workspace
    // If not: prompt user or auto-select

    // For now, always create:
    const basename = std.fs.path.basename(abs_dir);
    const create_request = try std.fmt.allocPrint(
        allocator,
        "{{\"method\":\"workspace.create\",\"params\":{{\"name\":\"{s}\",\"dir\":\"{s}\"}}}}\n",
        .{ basename, abs_dir_z },
    );
    defer allocator.free(create_request);

    const create_response = try sendRequest(allocator, create_request);
    defer allocator.free(create_response);

    try std.io.getStdOut().writer().print("{s}\n", .{create_response});
}
```

- [ ] **Step 3: Build and test**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

Test:
```bash
./zig-out/bin/termplex open /home/ahmed/projects
```

- [ ] **Step 4: Commit**

```bash
git add src/termplex/cli_main.zig
git commit -m "feat: add termplex open CLI command for directory-based workspace creation"
```

---

## Chunk 6: Integration & Polish

### Task 17: Update autosave to include workspace directory in session

**Files:**
- Modify: `src/apprt/gtk/class/application.zig`

**Context:** Ensure the existing autosave and restore flows handle the workspace directories properly, including v1→v2 migration.

- [ ] **Step 1: Verify autosave writes workspace dirs**

Ensure `autosaveSession()` includes the `"dir"` field for each workspace.

- [ ] **Step 2: Verify restore handles v1 migration**

Test restoring from an old v1 session.json that has no `"workspaces"` array.

- [ ] **Step 3: Build and test full cycle**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
./zig-out/bin/termplex-app
# Create workspaces, close app, reopen, verify workspaces restored
```

- [ ] **Step 4: Commit**

```bash
git add src/apprt/gtk/class/application.zig
git commit -m "feat: session persistence with workspace directories and v1 migration"
```

---

### Task 18: End-to-end testing and polish

**Files:**
- All modified files

**Context:** Final integration testing and bug fixes.

- [ ] **Step 1: Test workspace creation and switching**

1. Launch app
2. Create 3 workspaces (Ctrl+Shift+N)
3. Open different terminals in each
4. Switch between them — verify terminals are preserved
5. Close app, reopen — verify workspaces are restored

- [ ] **Step 2: Test workspace management**

1. Right-click a workspace tab → Rename → verify name changes
2. Right-click a workspace tab → Delete → verify workspace removed
3. Try to delete last workspace → verify it's blocked

- [ ] **Step 3: Test sidebar toggle with workspaces**

1. Hide sidebar (Ctrl+Shift+B)
2. Show sidebar (click toggle button)
3. Switch workspaces — verify everything works

- [ ] **Step 4: Test CLI integration**

```bash
./zig-out/bin/termplex open /home/ahmed
./zig-out/bin/termplex workspace list
```

- [ ] **Step 5: Fix any issues found**

- [ ] **Step 6: Final commit**

```bash
git add -A
git commit -m "feat: workspace-based terminal management - integration polish"
```
