const std = @import("std");
const gobject = @import("gobject");
const gtk = @import("gtk");
const gdk = @import("gdk");

const Common = @import("../class.zig").Common;

const log = std.log.scoped(.gtk_termplex_workspace_tab);

/// A compact two-line widget displayed in the workspace sidebar's ListBox.
///
/// Layout:
///   Gtk.Box (horizontal, the WorkspaceTab itself)
///   +-- Gtk.Box (left_border, 3px wide)  -- colored accent strip
///   +-- Gtk.Box (content, vertical, padding)
///       +-- Gtk.Box (row1, horizontal)
///       |   +-- Gtk.Label (name_label, bold, left-aligned, hexpand)
///       |   +-- Gtk.Label (port_label, green, right-aligned)
///       +-- Gtk.Box (row2, horizontal)
///           +-- Gtk.Label (branch_label, "⎇ main", cyan, smaller)
///
/// The widget exposes an `update` method that refreshes label text and
/// CSS classes based on workspace state values passed in by the caller.
pub const WorkspaceTab = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "TermplexWorkspaceTab",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        /// The 3px accent strip on the left edge.
        left_border: *gtk.Box = undefined,

        /// Label showing the workspace name (bold, left-aligned).
        name_label: *gtk.Label = undefined,

        /// Label showing the primary port (green, right-aligned).
        port_label: *gtk.Label = undefined,

        /// Label showing "⎇ <branch>" (cyan, smaller font).
        branch_label: *gtk.Label = undefined,

        /// Inline rename state.
        rename_entry: ?*gtk.Entry = null,
        is_renaming: bool = false,
        on_rename_complete: ?*const fn (index: u32, new_name: [:0]const u8, userdata: ?*anyopaque) void = null,
        rename_userdata: ?*anyopaque = null,
        rename_index: u32 = 0,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const priv = self.private();
        const outer = self.as(gtk.Box);

        // Configure the outer box (horizontal, this widget's parent instance).
        outer.setSpacing(0);
        self.as(gtk.Widget).addCssClass("termplex-workspace-tab");

        // -- Left border: 3px colored accent strip --
        const left_border = gtk.Box.new(.vertical, 0);
        left_border.as(gtk.Widget).setSizeRequest(3, -1);
        priv.left_border = left_border;
        outer.append(left_border.as(gtk.Widget));

        // -- Content area (vertical box with padding) --
        const content = gtk.Box.new(.vertical, 2);
        content.as(gtk.Widget).setMarginStart(6);
        content.as(gtk.Widget).setMarginEnd(6);
        content.as(gtk.Widget).setMarginTop(4);
        content.as(gtk.Widget).setMarginBottom(4);
        content.as(gtk.Widget).setHexpand(1);
        outer.append(content.as(gtk.Widget));

        // -- Row 1: name (bold, left) + port (green, right) --
        const row1 = gtk.Box.new(.horizontal, 4);
        content.append(row1.as(gtk.Widget));

        const name_label = gtk.Label.new(null);
        name_label.setXalign(0.0);
        name_label.as(gtk.Widget).setHexpand(1);
        name_label.as(gtk.Widget).addCssClass("termplex-tab-name");
        priv.name_label = name_label;
        row1.append(name_label.as(gtk.Widget));

        const port_label = gtk.Label.new(null);
        port_label.setXalign(1.0);
        port_label.as(gtk.Widget).addCssClass("termplex-tab-port");
        priv.port_label = port_label;
        row1.append(port_label.as(gtk.Widget));

        // -- Row 2: branch label --
        const row2 = gtk.Box.new(.horizontal, 0);
        content.append(row2.as(gtk.Widget));

        const branch_label = gtk.Label.new(null);
        branch_label.setXalign(0.0);
        branch_label.as(gtk.Widget).addCssClass("termplex-tab-branch");
        priv.branch_label = branch_label;
        row2.append(branch_label.as(gtk.Widget));
    }

    // ---------------------------------------------------------------
    // Public API

    /// Create a new WorkspaceTab widget.
    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    /// Refresh all displayed values. The caller maps from WorkspaceState
    /// (or any other source) to these individual parameters.
    pub fn update(
        self: *Self,
        name: ?[:0]const u8,
        port_text: ?[:0]const u8,
        branch_text: ?[:0]const u8,
        is_active: bool,
        has_unread: bool,
    ) void {
        const priv = self.private();

        // Update labels
        priv.name_label.setLabel(name orelse "workspace");

        if (port_text) |p| {
            priv.port_label.setLabel(p);
            priv.port_label.as(gtk.Widget).setVisible(1);
        } else {
            priv.port_label.setLabel("");
            priv.port_label.as(gtk.Widget).setVisible(0);
        }

        if (branch_text) |b| {
            priv.branch_label.setLabel(b);
            priv.branch_label.as(gtk.Widget).setVisible(1);
        } else {
            priv.branch_label.setLabel("");
            priv.branch_label.as(gtk.Widget).setVisible(0);
        }

        // Update left border CSS classes for active / unread state.
        const border_widget = priv.left_border.as(gtk.Widget);
        if (is_active) {
            border_widget.addCssClass("termplex-sidebar-active");
        } else {
            border_widget.removeCssClass("termplex-sidebar-active");
        }

        if (has_unread) {
            border_widget.addCssClass("termplex-sidebar-unread");
        } else {
            border_widget.removeCssClass("termplex-sidebar-unread");
        }
    }

    // ---------------------------------------------------------------
    // Inline rename

    /// Begin inline renaming: hide the name label, show a GtkEntry in its place.
    pub fn startRename(
        self: *Self,
        index: u32,
        on_complete: ?*const fn (u32, [:0]const u8, ?*anyopaque) void,
        userdata: ?*anyopaque,
    ) void {
        const priv = self.private();
        if (priv.is_renaming) return;

        priv.on_rename_complete = on_complete;
        priv.rename_userdata = userdata;
        priv.rename_index = index;

        const entry = gtk.Entry.new();
        const current_name = priv.name_label.getLabel();
        entry.as(gtk.Editable).setText(current_name);

        // Hide label, show entry in same position.
        priv.name_label.as(gtk.Widget).setVisible(0);

        // Insert entry into row1 (parent of name_label).
        const parent = priv.name_label.as(gtk.Widget).getParent();
        if (parent) |p| {
            const box: *gtk.Box = @ptrCast(@alignCast(p));
            // Prepend so the entry appears where the label was.
            box.prepend(entry.as(gtk.Widget));
        }

        _ = entry.as(gtk.Widget).grabFocus();
        priv.rename_entry = entry;
        priv.is_renaming = true;

        // Connect Enter (activate).
        _ = gtk.Entry.signals.activate.connect(entry, *Self, &onRenameActivate, self, .{});

        // Connect Escape via EventControllerKey.
        const key_controller = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(
            key_controller,
            *Self,
            &onRenameKeyPress,
            self,
            .{},
        );
        entry.as(gtk.Widget).addController(key_controller.as(gtk.EventController));
    }

    fn onRenameActivate(_: *gtk.Entry, self: *Self) callconv(.c) void {
        self.finishRename(true);
    }

    fn onRenameKeyPress(
        _: *gtk.EventControllerKey,
        keyval: c_uint,
        _: c_uint,
        _: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) c_int {
        if (keyval == gdk.KEY_Escape) {
            self.finishRename(false);
            return 1; // handled
        }
        return 0; // not handled
    }

    pub fn finishRename(self: *Self, confirm: bool) void {
        const priv = self.private();
        if (!priv.is_renaming) return;

        if (confirm) {
            if (priv.rename_entry) |entry| {
                const text = entry.as(gtk.Editable).getText();
                const name_slice = std.mem.span(text);
                if (name_slice.len > 0) {
                    priv.name_label.setLabel(text);
                    if (priv.on_rename_complete) |cb| {
                        cb(priv.rename_index, name_slice, priv.rename_userdata);
                    }
                }
            }
        }

        // Remove entry, show label.
        if (priv.rename_entry) |entry| {
            const parent = entry.as(gtk.Widget).getParent();
            if (parent) |p| {
                const box: *gtk.Box = @ptrCast(@alignCast(p));
                box.remove(entry.as(gtk.Widget));
            }
        }
        priv.name_label.as(gtk.Widget).setVisible(1);
        priv.rename_entry = null;
        priv.is_renaming = false;
    }

    // ---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        // Unparent the direct child created in init so GTK can finalize them.
        // gtk.Box stores children internally; iterating first-child / next-sibling
        // is the canonical way to remove programmatic children.
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
