const std = @import("std");
const gobject = @import("gobject");
const gtk = @import("gtk");
const gdk = @import("gdk");

const Common = @import("../class.zig").Common;

const log = std.log.scoped(.gtk_termplex_workspace_tab);

const BranchStatus = struct {
    branch: []const u8,
    dirty: bool,
};

fn parseBranchStatus(text: []const u8) BranchStatus {
    if (text.len > 0 and text[text.len - 1] == '*') {
        return .{
            .branch = text[0 .. text.len - 1],
            .dirty = true,
        };
    }

    return .{
        .branch = text,
        .dirty = false,
    };
}

const WorkspaceActionCallback = *const fn (index: u32, userdata: ?*anyopaque) void;

const WorkspaceActionCallbacks = struct {
    on_rename: ?WorkspaceActionCallback = null,
    on_delete: ?WorkspaceActionCallback = null,
    on_change_dir: ?WorkspaceActionCallback = null,
    on_source_control: ?WorkspaceActionCallback = null,
    on_open_folder: ?WorkspaceActionCallback = null,
    on_open_vscode: ?WorkspaceActionCallback = null,
    on_pin: ?WorkspaceActionCallback = null,

    fn hasVisibleActions(self: WorkspaceActionCallbacks) bool {
        return self.visibleActionCount() > 0;
    }

    fn visibleActionCount(self: WorkspaceActionCallbacks) u8 {
        var count: u8 = 0;
        if (self.on_rename != null) count += 1;
        if (self.on_delete != null) count += 1;
        if (self.on_change_dir != null) count += 1;
        if (self.on_source_control != null) count += 1;
        if (self.on_open_folder != null) count += 1;
        if (self.on_open_vscode != null) count += 1;
        if (self.on_pin != null) count += 1;
        return count;
    }
};

/// A compact two-line widget displayed in the workspace sidebar's ListBox.
///
/// Layout:
///   Gtk.Box (horizontal, the WorkspaceTab itself)
///   +-- Gtk.Box (left_border, 3px wide)  -- colored accent strip
///   +-- Gtk.Box (content, vertical, padding)
///       +-- Gtk.Box (row1, horizontal)
///       |   +-- Gtk.Label (name_label, bold, left-aligned, hexpand)
///       |   +-- Gtk.Box (port_box, horizontal)
///       |       +-- Gtk.Label (port_primary_label, green, right-aligned)
///       |       +-- Gtk.Label (port_badge_label, "+N" badge)
///       +-- Gtk.Box (row2, horizontal)
///       |   +-- Gtk.Label (dir_label, dim gray, ellipsized)
///       +-- Gtk.Box (row3, horizontal)
///       |   +-- Gtk.Label (branch_label, "⎇ main", cyan, smaller)
///       +-- Gtk.Box (port_detail_box, vertical, hidden by default)
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

        /// Label showing the workspace directory path (dim gray, ellipsized).
        dir_label: *gtk.Label = undefined,

        /// Label showing "⎇ <branch>" (cyan, smaller font).
        branch_label: *gtk.Label = undefined,

        /// Badge shown when the workspace has dirty git changes.
        git_dirty_badge: *gtk.Label = undefined,

        /// Badge showing staged git change count.
        git_staged_badge: *gtk.Label = undefined,

        /// Badge showing unstaged git change count.
        git_unstaged_badge: *gtk.Label = undefined,

        /// Badge shown when the workspace is pinned.
        pinned_badge: *gtk.Label = undefined,

        /// Stable application workspace index represented by this row.
        workspace_index: u32 = 0,

        /// Cached pinned state used by GtkListBox sorting.
        is_pinned: bool = false,

        /// Inline rename state.
        rename_entry: ?*gtk.Entry = null,
        is_renaming: bool = false,
        on_rename_complete: ?*const fn (index: u32, new_name: [:0]const u8, userdata: ?*anyopaque) void = null,
        rename_userdata: ?*anyopaque = null,
        rename_index: u32 = 0,

        /// Inline change-dir state.
        chdir_entry: ?*gtk.Entry = null,
        is_changing_dir: bool = false,
        on_chdir_complete: ?*const fn (index: u32, new_dir: [:0]const u8, userdata: ?*anyopaque) void = null,
        chdir_userdata: ?*anyopaque = null,
        chdir_index: u32 = 0,

        /// Horizontal box containing action icons (rename, dir, delete), shown on hover.
        action_box: *gtk.Box = undefined,

        /// Whether port_box should be visible (tracked for hover restore).
        has_ports: bool = false,

        /// Whether the pointer is currently hovering over this tab.
        is_hovered: bool = false,

        /// Callback invoked when the rename action icon is clicked.
        on_action_rename: ?*const fn (index: u32, userdata: ?*anyopaque) void = null,

        /// Callback invoked when the delete action icon is clicked.
        on_action_delete: ?*const fn (index: u32, userdata: ?*anyopaque) void = null,

        /// Callback invoked when the change-dir action icon is clicked.
        on_action_change_dir: ?*const fn (index: u32, userdata: ?*anyopaque) void = null,

        /// Callback invoked when the source-control action icon is clicked.
        on_action_source_control: ?*const fn (index: u32, userdata: ?*anyopaque) void = null,

        /// Callback invoked when the open-folder action icon is clicked.
        on_action_open_folder: ?*const fn (index: u32, userdata: ?*anyopaque) void = null,

        /// Callback invoked when the open-in-VS-Code action icon is clicked.
        on_action_open_vscode: ?*const fn (index: u32, userdata: ?*anyopaque) void = null,

        /// Callback invoked when the pin action icon is clicked.
        on_action_pin: ?*const fn (index: u32, userdata: ?*anyopaque) void = null,

        /// Opaque pointer passed to action callbacks.
        action_userdata: ?*anyopaque = null,

        pub var offset: c_int = 0;

        fn workspaceActionCallbacks(self: Private) WorkspaceActionCallbacks {
            return .{
                .on_rename = self.on_action_rename,
                .on_delete = self.on_action_delete,
                .on_change_dir = self.on_action_change_dir,
                .on_source_control = self.on_action_source_control,
                .on_open_folder = self.on_action_open_folder,
                .on_open_vscode = self.on_action_open_vscode,
                .on_pin = self.on_action_pin,
            };
        }
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const priv = self.private();
        const outer = self.as(gtk.Box);

        // Configure the outer box (horizontal, this widget's parent instance).
        outer.setSpacing(0);
        self.as(gtk.Widget).addCssClass("termplex-workspace-tab");

        // -- Left border: colored status rail --
        const left_border = gtk.Box.new(.vertical, 0);
        left_border.as(gtk.Widget).setSizeRequest(3, -1);
        priv.left_border = left_border;
        outer.append(left_border.as(gtk.Widget));

        // -- Content area (vertical box with padding) --
        const content = gtk.Box.new(.vertical, 2);
        content.as(gtk.Widget).addCssClass("termplex-workspace-content");
        content.as(gtk.Widget).setMarginStart(6);
        content.as(gtk.Widget).setMarginEnd(6);
        content.as(gtk.Widget).setMarginTop(4);
        content.as(gtk.Widget).setMarginBottom(4);
        content.as(gtk.Widget).setHexpand(1);
        outer.append(content.as(gtk.Widget));

        // -- Row 1: name (bold, left) + port (green, right) --
        const row1 = gtk.Box.new(.horizontal, 4);
        row1.as(gtk.Widget).addCssClass("termplex-workspace-title-row");
        content.append(row1.as(gtk.Widget));

        const name_label = gtk.Label.new(null);
        name_label.setXalign(0.0);
        name_label.as(gtk.Widget).setHexpand(1);
        name_label.setEllipsize(.end);
        name_label.setMaxWidthChars(18);
        name_label.as(gtk.Widget).addCssClass("termplex-tab-name");
        priv.name_label = name_label;
        row1.append(name_label.as(gtk.Widget));

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

        // -- Action icons box: shown on hover, hidden by default --
        const action_box = gtk.Box.new(.horizontal, 2);
        action_box.as(gtk.Widget).addCssClass("termplex-tab-actions");
        action_box.as(gtk.Widget).setOpacity(0.0);
        action_box.as(gtk.Widget).setSensitive(0);
        priv.action_box = action_box;
        row1.append(action_box.as(gtk.Widget));

        const source_control_btn = gtk.Button.newFromIconName("view-list-symbolic");
        source_control_btn.as(gtk.Widget).addCssClass("termplex-tab-action");
        source_control_btn.as(gtk.Widget).addCssClass("termplex-tab-action-source-control");
        source_control_btn.as(gtk.Widget).addCssClass("flat");
        source_control_btn.as(gtk.Widget).setTooltipText("Open Source Control");
        _ = gtk.Button.signals.clicked.connect(source_control_btn, *Self, &onActionSourceControl, self, .{});
        action_box.append(source_control_btn.as(gtk.Widget));

        const open_folder_btn = gtk.Button.newFromIconName("folder-open-symbolic");
        open_folder_btn.as(gtk.Widget).addCssClass("termplex-tab-action");
        open_folder_btn.as(gtk.Widget).addCssClass("termplex-tab-action-open-folder");
        open_folder_btn.as(gtk.Widget).addCssClass("flat");
        open_folder_btn.as(gtk.Widget).setTooltipText("Open workspace folder");
        _ = gtk.Button.signals.clicked.connect(open_folder_btn, *Self, &onActionOpenFolder, self, .{});
        action_box.append(open_folder_btn.as(gtk.Widget));

        const open_vscode_btn = gtk.Button.newFromIconName("applications-development-symbolic");
        open_vscode_btn.as(gtk.Widget).addCssClass("termplex-tab-action");
        open_vscode_btn.as(gtk.Widget).addCssClass("termplex-tab-action-open-vscode");
        open_vscode_btn.as(gtk.Widget).addCssClass("flat");
        open_vscode_btn.as(gtk.Widget).setTooltipText("Open workspace in VS Code");
        _ = gtk.Button.signals.clicked.connect(open_vscode_btn, *Self, &onActionOpenVSCode, self, .{});
        action_box.append(open_vscode_btn.as(gtk.Widget));

        const pin_btn = gtk.Button.newFromIconName("emblem-favorite-symbolic");
        pin_btn.as(gtk.Widget).addCssClass("termplex-tab-action");
        pin_btn.as(gtk.Widget).addCssClass("termplex-tab-action-pin");
        pin_btn.as(gtk.Widget).addCssClass("flat");
        pin_btn.as(gtk.Widget).setTooltipText("Pin or unpin workspace");
        _ = gtk.Button.signals.clicked.connect(pin_btn, *Self, &onActionPin, self, .{});
        action_box.append(pin_btn.as(gtk.Widget));

        const rename_btn = gtk.Button.newFromIconName("document-edit-symbolic");
        rename_btn.as(gtk.Widget).addCssClass("termplex-tab-action");
        rename_btn.as(gtk.Widget).addCssClass("flat");
        rename_btn.as(gtk.Widget).setTooltipText("Rename workspace");
        _ = gtk.Button.signals.clicked.connect(rename_btn, *Self, &onActionRename, self, .{});
        action_box.append(rename_btn.as(gtk.Widget));

        const dir_btn = gtk.Button.newFromIconName("folder-open-symbolic");
        dir_btn.as(gtk.Widget).addCssClass("termplex-tab-action");
        dir_btn.as(gtk.Widget).addCssClass("flat");
        dir_btn.as(gtk.Widget).setTooltipText("Change workspace directory");
        _ = gtk.Button.signals.clicked.connect(dir_btn, *Self, &onActionChangeDir, self, .{});
        action_box.append(dir_btn.as(gtk.Widget));

        const delete_btn = gtk.Button.newFromIconName("user-trash-symbolic");
        delete_btn.as(gtk.Widget).addCssClass("termplex-tab-action");
        delete_btn.as(gtk.Widget).addCssClass("termplex-tab-action-delete");
        delete_btn.as(gtk.Widget).addCssClass("flat");
        delete_btn.as(gtk.Widget).setTooltipText("Delete workspace");
        _ = gtk.Button.signals.clicked.connect(delete_btn, *Self, &onActionDelete, self, .{});
        action_box.append(delete_btn.as(gtk.Widget));

        // Hover detection: show/hide action icons.
        const motion = gtk.EventControllerMotion.new();
        _ = gtk.EventControllerMotion.signals.enter.connect(motion, *Self, &onHoverEnter, self, .{});
        _ = gtk.EventControllerMotion.signals.leave.connect(motion, *Self, &onHoverLeave, self, .{});
        self.as(gtk.Widget).addController(motion.as(gtk.EventController));

        // -- Row 2: directory label --
        const row2 = gtk.Box.new(.horizontal, 0);
        row2.as(gtk.Widget).addCssClass("termplex-workspace-meta-row");
        content.append(row2.as(gtk.Widget));

        const dir_label = gtk.Label.new(null);
        dir_label.setXalign(0.0);
        dir_label.as(gtk.Widget).setHexpand(1);
        dir_label.setEllipsize(.end);
        dir_label.setMaxWidthChars(25);
        dir_label.as(gtk.Widget).addCssClass("termplex-tab-dir");
        dir_label.as(gtk.Widget).setVisible(0); // hidden until dir_text is provided
        priv.dir_label = dir_label;
        row2.append(dir_label.as(gtk.Widget));

        // -- Row 3: branch label --
        const row3 = gtk.Box.new(.horizontal, 0);
        row3.as(gtk.Widget).addCssClass("termplex-workspace-branch-row");
        content.append(row3.as(gtk.Widget));

        const branch_label = gtk.Label.new(null);
        branch_label.setXalign(0.0);
        branch_label.as(gtk.Widget).addCssClass("termplex-tab-branch");
        branch_label.as(gtk.Widget).setHexpand(1);
        branch_label.setEllipsize(.end);
        branch_label.setMaxWidthChars(20);
        priv.branch_label = branch_label;
        row3.append(branch_label.as(gtk.Widget));

        const git_dirty_badge = gtk.Label.new("dirty");
        git_dirty_badge.as(gtk.Widget).addCssClass("termplex-git-dirty-badge");
        git_dirty_badge.as(gtk.Widget).setVisible(0);
        priv.git_dirty_badge = git_dirty_badge;
        row3.append(git_dirty_badge.as(gtk.Widget));

        const git_staged_badge = gtk.Label.new(null);
        git_staged_badge.as(gtk.Widget).addCssClass("termplex-git-count-badge");
        git_staged_badge.as(gtk.Widget).addCssClass("termplex-git-staged-badge");
        git_staged_badge.as(gtk.Widget).setVisible(0);
        priv.git_staged_badge = git_staged_badge;
        row3.append(git_staged_badge.as(gtk.Widget));

        const git_unstaged_badge = gtk.Label.new(null);
        git_unstaged_badge.as(gtk.Widget).addCssClass("termplex-git-count-badge");
        git_unstaged_badge.as(gtk.Widget).addCssClass("termplex-git-unstaged-badge");
        git_unstaged_badge.as(gtk.Widget).setVisible(0);
        priv.git_unstaged_badge = git_unstaged_badge;
        row3.append(git_unstaged_badge.as(gtk.Widget));

        const pinned_badge = gtk.Label.new("pinned");
        pinned_badge.as(gtk.Widget).addCssClass("termplex-pinned-badge");
        pinned_badge.as(gtk.Widget).setVisible(0);
        priv.pinned_badge = pinned_badge;
        row3.append(pinned_badge.as(gtk.Widget));

        // -- Port detail box (hidden by default, shown when "+N" badge clicked) --
        const port_detail_box = gtk.Box.new(.vertical, 1);
        port_detail_box.as(gtk.Widget).addCssClass("termplex-port-detail");
        port_detail_box.as(gtk.Widget).setVisible(0);
        priv.port_detail_box = port_detail_box;
        content.append(port_detail_box.as(gtk.Widget));
    }

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

    fn onHoverEnter(_: *gtk.EventControllerMotion, _: f64, _: f64, self: *Self) callconv(.c) void {
        const priv = self.private();
        // Only show actions if callbacks are wired (not orchestrator).
        if (!priv.workspaceActionCallbacks().hasVisibleActions()) return;
        priv.is_hovered = true;
        priv.action_box.as(gtk.Widget).setOpacity(1.0);
        priv.action_box.as(gtk.Widget).setSensitive(1);
        priv.port_box.as(gtk.Widget).setVisible(0);
    }

    fn onHoverLeave(_: *gtk.EventControllerMotion, self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.is_hovered = false;
        priv.action_box.as(gtk.Widget).setOpacity(0.0);
        priv.action_box.as(gtk.Widget).setSensitive(0);
        priv.port_box.as(gtk.Widget).setVisible(@intFromBool(priv.has_ports));
    }

    fn onActionRename(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const cb = priv.on_action_rename orelse return;
        cb(priv.workspace_index, priv.action_userdata);
    }

    fn onActionDelete(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const cb = priv.on_action_delete orelse return;
        cb(priv.workspace_index, priv.action_userdata);
    }

    fn onActionChangeDir(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const cb = priv.on_action_change_dir orelse return;
        cb(priv.workspace_index, priv.action_userdata);
    }

    fn onActionSourceControl(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const cb = priv.on_action_source_control orelse return;
        cb(priv.workspace_index, priv.action_userdata);
    }

    fn onActionOpenFolder(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const cb = priv.on_action_open_folder orelse return;
        cb(priv.workspace_index, priv.action_userdata);
    }

    fn onActionOpenVSCode(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const cb = priv.on_action_open_vscode orelse return;
        cb(priv.workspace_index, priv.action_userdata);
    }

    fn onActionPin(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        const cb = priv.on_action_pin orelse return;
        cb(priv.workspace_index, priv.action_userdata);
    }

    // ---------------------------------------------------------------
    // Public API

    /// Create a new WorkspaceTab widget.
    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    pub fn setWorkspaceIndex(self: *Self, index: u32) void {
        self.private().workspace_index = index;
    }

    pub fn workspaceIndex(self: *Self) u32 {
        return self.private().workspace_index;
    }

    pub fn isPinned(self: *Self) bool {
        return self.private().is_pinned;
    }

    pub fn shiftWorkspaceIndexAfterRemoval(self: *Self, removed_index: u32) void {
        const priv = self.private();
        if (priv.workspace_index > removed_index) {
            priv.workspace_index -= 1;
        }
        if (priv.rename_index > removed_index) {
            priv.rename_index -= 1;
        }
        if (priv.chdir_index > removed_index) {
            priv.chdir_index -= 1;
        }
    }

    /// Set callback functions for hover action icons (rename, delete, change-dir).
    pub fn setActionCallbacks(
        self: *Self,
        on_rename: ?*const fn (index: u32, userdata: ?*anyopaque) void,
        on_delete: ?*const fn (index: u32, userdata: ?*anyopaque) void,
        on_change_dir: ?*const fn (index: u32, userdata: ?*anyopaque) void,
        on_source_control: ?*const fn (index: u32, userdata: ?*anyopaque) void,
        on_open_folder: ?*const fn (index: u32, userdata: ?*anyopaque) void,
        on_open_vscode: ?*const fn (index: u32, userdata: ?*anyopaque) void,
        on_pin: ?*const fn (index: u32, userdata: ?*anyopaque) void,
        userdata: ?*anyopaque,
    ) void {
        const priv = self.private();
        priv.on_action_rename = on_rename;
        priv.on_action_delete = on_delete;
        priv.on_action_change_dir = on_change_dir;
        priv.on_action_source_control = on_source_control;
        priv.on_action_open_folder = on_open_folder;
        priv.on_action_open_vscode = on_open_vscode;
        priv.on_action_pin = on_pin;
        priv.action_userdata = userdata;
    }

    /// Refresh all displayed values. The caller maps from WorkspaceState
    /// (or any other source) to these individual parameters.
    pub fn update(
        self: *Self,
        name: ?[:0]const u8,
        port_text: ?[:0]const u8,
        branch_text: ?[:0]const u8,
        dir_text: ?[:0]const u8,
        is_active: bool,
        has_unread: bool,
        staged_count: u32,
        unstaged_count: u32,
        is_pinned: bool,
    ) void {
        const priv = self.private();

        // Update labels
        priv.name_label.setLabel(name orelse "workspace");

        // Track port visibility for hover restore.
        priv.has_ports = if (port_text) |p| p.len > 0 else false;

        // Update port display.
        if (port_text) |p| {
            if (p.len == 0) {
                if (!priv.is_hovered) priv.port_box.as(gtk.Widget).setVisible(0);
                priv.port_detail_box.as(gtk.Widget).setVisible(0);
                priv.ports_expanded = false;
            } else {
                if (!priv.is_hovered) priv.port_box.as(gtk.Widget).setVisible(1);

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
                    const first_end = std.mem.indexOfScalar(u8, p, ' ') orelse p.len;
                    var first_buf: [16]u8 = undefined;
                    const first_port = std.fmt.bufPrintZ(&first_buf, "{s}", .{p[0..first_end]}) catch p;
                    priv.port_primary_label.setLabel(first_port);

                    var badge_buf: [8]u8 = undefined;
                    const badge_text = std.fmt.bufPrintZ(&badge_buf, "+{d}", .{port_count - 1}) catch "+?";
                    priv.port_badge_label.setLabel(badge_text);
                    priv.port_badge_label.as(gtk.Widget).setVisible(1);

                    // Rebuild port detail box contents.
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
            if (!priv.is_hovered) priv.port_box.as(gtk.Widget).setVisible(0);
            priv.port_detail_box.as(gtk.Widget).setVisible(0);
            priv.ports_expanded = false;
        }

        if (branch_text) |b| {
            const status = parseBranchStatus(b);
            if (status.branch.len > 0) {
                var branch_buf: [256]u8 = undefined;
                const branch_label = std.fmt.bufPrintZ(&branch_buf, "{s}", .{status.branch}) catch b;
                priv.branch_label.setLabel(branch_label);
                priv.branch_label.as(gtk.Widget).setVisible(1);
                self.updateGitBadges(status.dirty, staged_count, unstaged_count);
            } else {
                priv.branch_label.setLabel("");
                priv.branch_label.as(gtk.Widget).setVisible(0);
                self.updateGitBadges(false, 0, 0);
            }
        } else {
            priv.branch_label.setLabel("");
            priv.branch_label.as(gtk.Widget).setVisible(0);
            self.updateGitBadges(false, 0, 0);
        }

        // Update directory label. Preserve existing text when null.
        // Skip if inline change-dir editing is active to avoid clobbering the entry.
        if (dir_text) |d| {
            if (!priv.is_changing_dir) {
                priv.dir_label.setLabel(d);
                priv.dir_label.as(gtk.Widget).setVisible(1);
            }
        }
        // When dir_text is null, keep current label text visible (no else branch).

        // Update name label CSS class for active state.
        const name_widget = priv.name_label.as(gtk.Widget);
        const tab_widget = self.as(gtk.Widget);
        if (is_active) {
            name_widget.addCssClass("termplex-tab-name-active");
        } else {
            name_widget.removeCssClass("termplex-tab-name-active");
        }

        priv.is_pinned = is_pinned;
        priv.pinned_badge.as(gtk.Widget).setVisible(@intFromBool(is_pinned));
        if (is_pinned) {
            tab_widget.addCssClass("termplex-workspace-pinned");
        } else {
            tab_widget.removeCssClass("termplex-workspace-pinned");
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

    fn updateGitBadges(self: *Self, dirty: bool, staged_count: u32, unstaged_count: u32) void {
        const priv = self.private();

        if (staged_count > 0) {
            var staged_buf: [16]u8 = undefined;
            const text = std.fmt.bufPrintZ(&staged_buf, "+{d}", .{staged_count}) catch "+?";
            priv.git_staged_badge.setLabel(text);
            priv.git_staged_badge.as(gtk.Widget).setVisible(1);
        } else {
            priv.git_staged_badge.as(gtk.Widget).setVisible(0);
        }

        if (unstaged_count > 0) {
            var unstaged_buf: [16]u8 = undefined;
            const text = std.fmt.bufPrintZ(&unstaged_buf, "~{d}", .{unstaged_count}) catch "~?";
            priv.git_unstaged_badge.setLabel(text);
            priv.git_unstaged_badge.as(gtk.Widget).setVisible(1);
        } else {
            priv.git_unstaged_badge.as(gtk.Widget).setVisible(0);
        }

        priv.git_dirty_badge.as(gtk.Widget).setVisible(@intFromBool(dirty and staged_count == 0 and unstaged_count == 0));
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
    // Inline change-dir

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

test "workspace tab parses sidebar branch dirty marker" {
    const clean = parseBranchStatus("main");
    try std.testing.expectEqualStrings("main", clean.branch);
    try std.testing.expectEqual(false, clean.dirty);

    const dirty = parseBranchStatus("feature/sidebar*");
    try std.testing.expectEqualStrings("feature/sidebar", dirty.branch);
    try std.testing.expectEqual(true, dirty.dirty);

    const empty = parseBranchStatus("");
    try std.testing.expectEqualStrings("", empty.branch);
    try std.testing.expectEqual(false, empty.dirty);
}

fn dummyWorkspaceAction(_: u32, _: ?*anyopaque) void {}

test "workspace tab action callbacks include external open actions" {
    const callbacks = WorkspaceActionCallbacks{
        .on_open_folder = dummyWorkspaceAction,
        .on_open_vscode = dummyWorkspaceAction,
    };

    try std.testing.expect(callbacks.hasVisibleActions());
    try std.testing.expectEqual(@as(u8, 2), callbacks.visibleActionCount());
}
