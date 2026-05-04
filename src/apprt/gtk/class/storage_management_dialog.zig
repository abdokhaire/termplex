const std = @import("std");

const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Window = @import("window.zig").Window;

const log = std.log.scoped(.gtk_termplex_storage_management);

pub const StorageManagementDialog = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "TermplexStorageManagementDialog",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        dialog: *adw.Dialog,
        summary_label: *gtk.Label,
        settings_label: *gtk.Label,
        action_label: *gtk.Label,

        pub var offset: c_int = 0;
    };

    pub fn new() *Self {
        const self = gobject.ext.newInstance(Self, .{});
        _ = self.refSink();
        return self.ref();
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    fn dispose(self: *Self) callconv(.c) void {
        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn close(self: *Self) void {
        _ = self.private().dialog.close();
    }

    fn setLabel(label: *gtk.Label, text: []const u8) void {
        const alloc = std.heap.c_allocator;
        const z = alloc.dupeZ(u8, text) catch return;
        defer alloc.free(z);
        label.setLabel(z);
    }

    fn setAction(self: *Self, text: []const u8) void {
        setLabel(self.private().action_label, text);
    }

    fn refresh(self: *Self) void {
        const alloc = std.heap.c_allocator;
        const app = Application.default();

        const summary = app.storageSummaryText(alloc) catch |err| {
            log.warn("failed to build storage summary: {}", .{err});
            self.setAction("Unable to read storage status");
            return;
        };
        defer alloc.free(summary);

        const settings = app.storageSettingsText(alloc) catch |err| {
            log.warn("failed to build storage settings: {}", .{err});
            self.setAction("Unable to read storage settings");
            return;
        };
        defer alloc.free(settings);

        const priv = self.private();
        setLabel(priv.summary_label, summary);
        setLabel(priv.settings_label, settings);
        self.setAction("Ready");
    }

    fn dialogClosed(_: *adw.Dialog, self: *StorageManagementDialog) callconv(.c) void {
        self.unref();
    }

    fn refreshClicked(_: *gtk.Button, self: *StorageManagementDialog) callconv(.c) void {
        self.refresh();
    }

    fn clearTerminalClicked(_: *gtk.Button, self: *StorageManagementDialog) callconv(.c) void {
        Application.default().clearActiveTerminalStorage() catch |err| {
            log.warn("failed to clear active terminal storage: {}", .{err});
            self.setAction("Unable to clear terminal history");
            return;
        };
        self.refresh();
        self.setAction("Terminal history cleared");
    }

    fn clearWorkspaceClicked(_: *gtk.Button, self: *StorageManagementDialog) callconv(.c) void {
        Application.default().clearActiveWorkspaceStorage() catch |err| {
            log.warn("failed to clear active workspace storage: {}", .{err});
            self.setAction("Unable to clear workspace history");
            return;
        };
        self.refresh();
        self.setAction("Workspace history cleared");
    }

    fn deleteProjectClicked(_: *gtk.Button, self: *StorageManagementDialog) callconv(.c) void {
        Application.default().deleteActiveProjectStorage() catch |err| {
            log.warn("failed to delete active project storage: {}", .{err});
            self.setAction("Unable to delete the active project");
            return;
        };
        self.close();
    }

    pub fn toggle(self: *StorageManagementDialog, window: *Window) void {
        const priv = self.private();

        if (priv.dialog.as(gtk.Widget).getRealized() != 0) {
            self.close();
            return;
        }

        self.refresh();
        priv.dialog.present(window.as(gtk.Widget));
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const refSink = C.refSink;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "storage-management-dialog",
                }),
            );

            class.bindTemplateChildPrivate("dialog", .{});
            class.bindTemplateChildPrivate("summary_label", .{});
            class.bindTemplateChildPrivate("settings_label", .{});
            class.bindTemplateChildPrivate("action_label", .{});

            class.bindTemplateCallback("closed", &dialogClosed);
            class.bindTemplateCallback("refresh_clicked", &refreshClicked);
            class.bindTemplateCallback("clear_terminal_clicked", &clearTerminalClicked);
            class.bindTemplateCallback("clear_workspace_clicked", &clearWorkspaceClicked);
            class.bindTemplateCallback("delete_project_clicked", &deleteProjectClicked);

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
