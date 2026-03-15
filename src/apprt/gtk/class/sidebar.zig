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
///   |   +-- Gtk.Label ("TERMPLEX", bold, termplex-header CSS class)
///   +-- Gtk.Separator (horizontal)
///   +-- Gtk.ScrolledWindow (vexpand, scrolls when many workspaces)
///   |   +-- Gtk.ListBox (workspace_list)
///   |       +-- [WorkspaceTab widgets as rows]
///   +-- Gtk.Separator (horizontal)
///   +-- Gtk.Button ("+ New Workspace")
///
/// The sidebar communicates user interactions to its owner via callback
/// function pointers set with `setCallbacks`.
///
/// Right-clicking a workspace row shows a context menu with Rename and
/// Delete options. Drag-to-reorder is not yet implemented.
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

        /// The index of the workspace currently targeted by the context menu.
        context_menu_index: u32 = 0,

        /// Popover widget for the context menu (reused/cleaned up across invocations).
        context_popover: ?*gtk.Popover = null,

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
        const header = gtk.Box.new(.horizontal, 0);
        header.as(gtk.Widget).setMarginTop(12);
        header.as(gtk.Widget).setMarginBottom(8);
        header.as(gtk.Widget).setMarginStart(12);
        header.as(gtk.Widget).setMarginEnd(12);

        const header_label = gtk.Label.new("TERMPLEX");
        header_label.as(gtk.Widget).addCssClass("termplex-header");
        header_label.as(gtk.Widget).setHexpand(1);
        header_label.setXalign(0.0);
        header.append(header_label.as(gtk.Widget));

        outer.append(header.as(gtk.Widget));

        // -- Separator --
        const sep1 = gtk.Separator.new(.horizontal);
        outer.append(sep1.as(gtk.Widget));

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

        // Right-click gesture for context menu.
        const gesture = gtk.GestureClick.new();
        gesture.as(gtk.GestureSingle).setButton(3); // right-click
        _ = gtk.GestureClick.signals.pressed.connect(
            gesture,
            *Self,
            &onRightClick,
            self,
            .{},
        );
        workspace_list.as(gtk.Widget).addController(gesture.as(gtk.EventController));

        scrolled.setChild(workspace_list.as(gtk.Widget));
        outer.append(scrolled.as(gtk.Widget));

        // -- Separator --
        const sep2 = gtk.Separator.new(.horizontal);
        outer.append(sep2.as(gtk.Widget));

        // -- New Workspace button --
        const new_button = gtk.Button.newWithLabel("+ New Workspace");
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

    fn onRightClick(
        _: *gtk.GestureClick,
        _: c_int, // n_press
        _: f64, // x
        y: f64, // y
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();

        // Dismiss and clean up any existing popover.
        if (priv.context_popover) |old| {
            old.popdown();
            old.as(gtk.Widget).unparent();
            priv.context_popover = null;
        }

        const row = priv.workspace_list.getRowAtY(@as(c_int, @intFromFloat(y))) orelse return;
        const index: u32 = @intCast(row.getIndex());
        priv.context_menu_index = index;

        log.debug("context menu: showing for workspace index={d}", .{index});

        // Build a vertical box with Rename and Delete buttons.
        const box = gtk.Box.new(.vertical, 4);
        box.as(gtk.Widget).setMarginTop(8);
        box.as(gtk.Widget).setMarginBottom(8);
        box.as(gtk.Widget).setMarginStart(8);
        box.as(gtk.Widget).setMarginEnd(8);

        const rename_btn = gtk.Button.newWithLabel("Rename");
        rename_btn.as(gtk.Widget).addCssClass("flat");
        _ = gtk.Button.signals.clicked.connect(
            rename_btn,
            *Self,
            &onContextRename,
            self,
            .{},
        );
        box.append(rename_btn.as(gtk.Widget));

        const delete_btn = gtk.Button.newWithLabel("Delete");
        delete_btn.as(gtk.Widget).addCssClass("destructive-action");
        _ = gtk.Button.signals.clicked.connect(
            delete_btn,
            *Self,
            &onContextDelete,
            self,
            .{},
        );
        box.append(delete_btn.as(gtk.Widget));

        // Ensure all children are visible.
        rename_btn.as(gtk.Widget).setVisible(1);
        delete_btn.as(gtk.Widget).setVisible(1);
        box.as(gtk.Widget).setVisible(1);

        // Create a popover, parent it to the clicked row, and show it.
        const popover = gtk.Popover.new();
        popover.setChild(box.as(gtk.Widget));
        popover.as(gtk.Widget).setParent(row.as(gtk.Widget));
        popover.setAutohide(1);
        popover.popup();

        priv.context_popover = popover;
    }

    fn onContextRename(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        // Dismiss the popover first.
        if (priv.context_popover) |p| {
            p.popdown();
        }
        if (priv.on_rename) |cb| {
            cb(priv.context_menu_index, priv.userdata);
        }
    }

    fn onContextDelete(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        // Dismiss the popover first.
        if (priv.context_popover) |p| {
            p.popdown();
        }
        if (priv.on_delete) |cb| {
            cb(priv.context_menu_index, priv.userdata);
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

    /// Set callback functions for context menu actions (rename/delete).
    ///
    /// - `on_rename`: called when the user picks "Rename" from the right-click
    ///   menu; receives the 0-based workspace index.
    /// - `on_delete`: called when the user picks "Delete" from the right-click
    ///   menu; receives the 0-based workspace index.
    pub fn setManagementCallbacks(
        self: *Self,
        on_rename: ?*const fn (index: u32, userdata: ?*anyopaque) void,
        on_delete: ?*const fn (index: u32, userdata: ?*anyopaque) void,
    ) void {
        const priv = self.private();
        priv.on_rename = on_rename;
        priv.on_delete = on_delete;
    }

    /// Add a new workspace tab at the end of the list.
    pub fn addWorkspace(
        self: *Self,
        name: ?[:0]const u8,
        port_text: ?[:0]const u8,
        branch_text: ?[:0]const u8,
    ) void {
        const priv = self.private();

        const tab = WorkspaceTab.new();
        tab.update(name, port_text, branch_text, false, false);

        priv.workspace_list.append(tab.as(gtk.Widget));
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
        is_active: bool,
        has_unread: bool,
    ) void {
        const priv = self.private();
        const row = priv.workspace_list.getRowAtIndex(@intCast(index)) orelse return;
        const child_widget = row.getChild() orelse return;

        // The child of the ListBoxRow is the WorkspaceTab (a Gtk.Box).
        // We need to cast the generic Widget pointer to a WorkspaceTab pointer.
        const tab: *WorkspaceTab = @ptrCast(@alignCast(child_widget));
        tab.update(name, port_text, branch_text, is_active, has_unread);
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
        // Clean up the context popover if it's still parented.
        const priv = self.private();
        if (priv.context_popover) |popover| {
            popover.as(gtk.Widget).unparent();
            priv.context_popover = null;
        }

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
