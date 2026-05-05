const std = @import("std");
const gobject = @import("gobject");
const gtk = @import("gtk");

const Common = @import("../class.zig").Common;
const WorkspaceTab = @import("workspace_tab.zig").WorkspaceTab;

const log = std.log.scoped(.gtk_termplex_sidebar);

/// The sidebar widget displayed on the left edge of the Termplex window.
///
/// It provides workspace navigation: a list of workspace tabs, a header
/// with the application name, and a button to create new workspaces.
///
/// Layout:
///   Gtk.Box (vertical, the Sidebar itself)
///   +-- Gtk.Box (header)
///   |   +-- Gtk.Box (title stack)
///   |   +-- Gtk.Button (new workspace)
///   +-- Gtk.Separator (horizontal)
///   +-- Gtk.Label ("WORKSPACES")
///   +-- Gtk.ScrolledWindow (vexpand, scrolls when many workspaces)
///   |   +-- Gtk.ListBox (workspace_list)
///   |       +-- [WorkspaceTab widgets as rows]
///   +-- Gtk.Separator (horizontal)
///   +-- Gtk.Button ("+ New Workspace")
///
/// The sidebar communicates user interactions to its owner via callback
/// function pointers set with `setCallbacks`.
///
/// Hovering a workspace row reveals action icons (rename, change-dir,
/// delete) on the right side. Drag-to-reorder is not yet implemented.
pub const Sidebar = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "TermplexSidebar",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        /// The ListBox containing WorkspaceTab rows.
        workspace_list: *gtk.ListBox = undefined,

        /// Tracks the currently active workspace index for highlighting.
        active_index: i32 = -1,

        /// Callback invoked when the user selects a workspace row.
        on_workspace_selected: ?*const fn (index: u32, userdata: ?*anyopaque) void = null,

        /// Callback invoked when the user clicks the "+ New Workspace" button.
        on_new_workspace: ?*const fn (userdata: ?*anyopaque) void = null,

        /// Opaque pointer passed to all callbacks.
        userdata: ?*anyopaque = null,

        /// Callback invoked when the user selects "Rename" from the context menu.
        on_rename: ?*const fn (index: u32, userdata: ?*anyopaque) void = null,

        /// Callback invoked when the user selects "Delete" from the context menu.
        on_delete: ?*const fn (index: u32, userdata: ?*anyopaque) void = null,

        /// Callback invoked when the user selects "Change Directory..." from the context menu.
        on_change_dir: ?*const fn (index: u32, userdata: ?*anyopaque) void = null,

        /// Index of the orchestration workspace (null if none). Set by Application.
        orchestration_idx: ?u32 = null,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const priv = self.private();
        const outer = self.as(gtk.Box);

        // Configure the outer box (vertical, this widget's parent instance).
        gobject.ext.as(gtk.Orientable, outer).setOrientation(.vertical);
        outer.setSpacing(0);
        self.as(gtk.Widget).addCssClass("termplex-sidebar");

        // -- Header box --
        const header = gtk.Box.new(.horizontal, 8);
        header.as(gtk.Widget).addCssClass("termplex-sidebar-header");

        const title_stack = gtk.Box.new(.vertical, 1);
        title_stack.as(gtk.Widget).setHexpand(1);

        const header_label = gtk.Label.new("Termplex");
        header_label.as(gtk.Widget).addCssClass("termplex-header");
        header_label.as(gtk.Widget).setHexpand(1);
        header_label.setXalign(0.0);
        title_stack.append(header_label.as(gtk.Widget));

        const header_subtitle = gtk.Label.new("Workspace terminal");
        header_subtitle.as(gtk.Widget).addCssClass("termplex-header-subtitle");
        header_subtitle.as(gtk.Widget).setHexpand(1);
        header_subtitle.setXalign(0.0);
        title_stack.append(header_subtitle.as(gtk.Widget));

        header.append(title_stack.as(gtk.Widget));

        const header_new_button = gtk.Button.newFromIconName("list-add-symbolic");
        header_new_button.as(gtk.Widget).addCssClass("termplex-sidebar-header-button");
        header_new_button.as(gtk.Widget).addCssClass("flat");
        header_new_button.as(gtk.Widget).setTooltipText("New workspace");
        _ = gtk.Button.signals.clicked.connect(
            header_new_button,
            *Self,
            &onNewWorkspaceClicked,
            self,
            .{},
        );
        header.append(header_new_button.as(gtk.Widget));

        outer.append(header.as(gtk.Widget));

        // -- Separator --
        const sep1 = gtk.Separator.new(.horizontal);
        outer.append(sep1.as(gtk.Widget));

        const section_label = gtk.Label.new("WORKSPACES");
        section_label.as(gtk.Widget).addCssClass("termplex-sidebar-section-label");
        section_label.setXalign(0.0);
        outer.append(section_label.as(gtk.Widget));

        // -- Scrolled window containing the workspace list --
        const scrolled = gtk.ScrolledWindow.new();
        scrolled.as(gtk.Widget).setVexpand(1);
        scrolled.setPolicy(.never, .automatic);

        const workspace_list = gtk.ListBox.new();
        workspace_list.setSelectionMode(.single);
        workspace_list.setActivateOnSingleClick(1);
        workspace_list.as(gtk.Widget).addCssClass("termplex-workspace-list");
        priv.workspace_list = workspace_list;

        // Connect row-activated signal to handle workspace selection.
        _ = gtk.ListBox.signals.row_activated.connect(
            workspace_list,
            *Self,
            &onRowActivated,
            self,
            .{},
        );

        scrolled.setChild(workspace_list.as(gtk.Widget));
        outer.append(scrolled.as(gtk.Widget));

        // -- Separator --
        const sep2 = gtk.Separator.new(.horizontal);
        outer.append(sep2.as(gtk.Widget));

        // -- New Workspace button --
        const new_button = gtk.Button.newWithLabel("New Workspace");
        new_button.as(gtk.Widget).addCssClass("termplex-new-workspace-button");
        new_button.as(gtk.Widget).setMarginTop(4);
        new_button.as(gtk.Widget).setMarginBottom(4);
        new_button.as(gtk.Widget).setMarginStart(8);
        new_button.as(gtk.Widget).setMarginEnd(8);

        // Connect clicked signal to handle new-workspace request.
        _ = gtk.Button.signals.clicked.connect(
            new_button,
            *Self,
            &onNewWorkspaceClicked,
            self,
            .{},
        );

        outer.append(new_button.as(gtk.Widget));
    }

    // ---------------------------------------------------------------
    // Signal handlers

    fn onRowActivated(_: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        const priv = self.private();
        const idx = row.getIndex();
        if (idx < 0) return;
        if (priv.on_workspace_selected) |cb| {
            cb(@intCast(idx), priv.userdata);
        }
    }

    fn onNewWorkspaceClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.on_new_workspace) |cb| {
            cb(priv.userdata);
        }
    }

    // ---------------------------------------------------------------
    // Public API

    /// Create a new Sidebar widget.
    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    /// Set callback functions for sidebar events.
    ///
    /// - `on_selected`: called when the user clicks a workspace tab; receives
    ///   the 0-based index of the selected workspace.
    /// - `on_new`: called when the user clicks "+ New Workspace".
    /// - `userdata`: opaque pointer forwarded to both callbacks.
    pub fn setCallbacks(
        self: *Self,
        on_selected: ?*const fn (index: u32, userdata: ?*anyopaque) void,
        on_new: ?*const fn (userdata: ?*anyopaque) void,
        userdata: ?*anyopaque,
    ) void {
        const priv = self.private();
        priv.on_workspace_selected = on_selected;
        priv.on_new_workspace = on_new;
        priv.userdata = userdata;
    }

    /// Set callback functions for context menu actions (rename/delete/change-dir).
    ///
    /// - `on_rename`: called when the user picks "Rename" from the right-click
    ///   menu; receives the 0-based workspace index.
    /// - `on_delete`: called when the user picks "Delete" from the right-click
    ///   menu; receives the 0-based workspace index.
    /// - `on_change_dir`: called when the user picks "Change Directory..." from
    ///   the right-click menu; receives the 0-based workspace index.
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

    /// Add a new workspace tab at the end of the list.
    pub fn addWorkspace(
        self: *Self,
        name: ?[:0]const u8,
        port_text: ?[:0]const u8,
        branch_text: ?[:0]const u8,
        dir_text: ?[:0]const u8,
    ) void {
        const priv = self.private();

        const tab = WorkspaceTab.new();
        tab.update(name, port_text, branch_text, dir_text, false, false);

        // Wire hover action callbacks (rename/delete/change-dir).
        // Skip for orchestrator workspace — callbacks stay null so icons won't appear.
        const is_orchestrator = if (priv.orchestration_idx) |orch_idx| blk: {
            // The new row will be appended at the end; compute its index.
            var last_idx: c_int = 0;
            while (priv.workspace_list.getRowAtIndex(last_idx) != null) {
                last_idx += 1;
            }
            break :blk @as(u32, @intCast(last_idx)) == orch_idx;
        } else false;

        if (!is_orchestrator) {
            tab.setActionCallbacks(
                priv.on_rename,
                priv.on_delete,
                priv.on_change_dir,
                priv.userdata,
            );
        }

        priv.workspace_list.append(tab.as(gtk.Widget));

        // If this is the orchestration workspace, add a special CSS class to
        // the ListBoxRow that GTK created for it.
        if (priv.orchestration_idx) |orch_idx| {
            // The new row's index is the last row in the list.
            var last_idx: c_int = 0;
            while (priv.workspace_list.getRowAtIndex(last_idx + 1) != null) {
                last_idx += 1;
            }
            const new_idx: u32 = @intCast(last_idx);
            if (new_idx == orch_idx) {
                if (priv.workspace_list.getRowAtIndex(last_idx)) |new_row| {
                    new_row.as(gtk.Widget).addCssClass("termplex-orchestrator-row");
                }
            }
        }
    }

    /// Return the ListBoxRow for the workspace at the given index, or null
    /// if the index is out of range.
    pub fn getWorkspaceRow(self: *Self, index: u32) ?*gtk.ListBoxRow {
        return self.private().workspace_list.getRowAtIndex(@intCast(index));
    }

    /// Remove the workspace tab at the given index.
    ///
    /// Does nothing if the index is out of range.
    pub fn removeWorkspace(self: *Self, index: u32) void {
        const priv = self.private();
        const row = priv.workspace_list.getRowAtIndex(@intCast(index)) orelse return;
        priv.workspace_list.remove(row.as(gtk.Widget));

        // If we removed the active workspace, reset active_index.
        if (priv.active_index == @as(i32, @intCast(index))) {
            priv.active_index = -1;
        } else if (priv.active_index > @as(i32, @intCast(index))) {
            // Shift active index down since a row before it was removed.
            priv.active_index -= 1;
        }

        // Adjust orchestration index after removal so it stays in sync with
        // the remaining row indices.
        if (priv.orchestration_idx) |orch_idx| {
            if (index == orch_idx) {
                priv.orchestration_idx = null;
            } else if (index < orch_idx) {
                priv.orchestration_idx = orch_idx - 1;
            }
        }
    }

    /// Update an existing workspace tab at the given index.
    ///
    /// Does nothing if the index is out of range or the row has no child.
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
        const priv = self.private();
        const row = priv.workspace_list.getRowAtIndex(@intCast(index)) orelse return;
        const child_widget = row.getChild() orelse return;

        // The child of the ListBoxRow is the WorkspaceTab (a Gtk.Box).
        // We need to cast the generic Widget pointer to a WorkspaceTab pointer.
        const tab: *WorkspaceTab = @ptrCast(@alignCast(child_widget));
        tab.update(name, port_text, branch_text, dir_text, is_active, has_unread);

        // Apply or remove orchestrator styling so the CSS descendant
        // selector `.termplex-orchestrator-label .termplex-tab-name` can reach
        // the inner name label.  We always toggle both add/remove so the class
        // is cleaned up when the orchestration index changes.
        if (priv.orchestration_idx) |orch_idx| {
            if (index == orch_idx) {
                tab.as(gtk.Widget).addCssClass("termplex-orchestrator-label");
            } else {
                tab.as(gtk.Widget).removeCssClass("termplex-orchestrator-label");
            }
        } else {
            tab.as(gtk.Widget).removeCssClass("termplex-orchestrator-label");
        }
    }

    /// Set which workspace tab is visually highlighted as active.
    ///
    /// This selects the corresponding ListBox row. The caller is responsible
    /// for calling `updateWorkspace` on both the old and new active indices
    /// with the correct `is_active` flag to update the WorkspaceTab's visual
    /// accent strip.
    pub fn setActiveIndex(self: *Self, index: u32) void {
        const priv = self.private();
        const new_index: i32 = @intCast(index);

        // Select the new row in the ListBox.
        if (priv.workspace_list.getRowAtIndex(new_index)) |new_row| {
            priv.workspace_list.selectRow(new_row);
        }

        priv.active_index = new_index;
    }

    /// Set the index of the orchestration workspace for special rendering.
    ///
    /// Pass `null` to clear the orchestration index (no workspace is treated
    /// as the orchestrator). Call this after creating the orchestration
    /// workspace so the sidebar can apply visual separation.
    pub fn setOrchestrationIndex(self: *Self, idx: ?u32) void {
        self.private().orchestration_idx = idx;
    }

    /// Return the number of workspace tabs currently in the list.
    pub fn getWorkspaceCount(self: *Self) u32 {
        const priv = self.private();
        var count: u32 = 0;
        var idx: c_int = 0;
        while (priv.workspace_list.getRowAtIndex(idx) != null) {
            count += 1;
            idx += 1;
        }
        return count;
    }

    // ---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        // Unparent all direct children so GTK can finalize them.
        const widget = self.as(gtk.Widget);
        while (widget.getFirstChild()) |child| {
            child.unparent();
        }

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    // ---------------------------------------------------------------
    // Common helpers

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            // No template -- UI is built programmatically in instance init.

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
    };
};
