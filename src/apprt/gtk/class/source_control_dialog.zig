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
const git_status = @import("../../../termplex/core/git_status.zig");

const log = std.log.scoped(.gtk_termplex_source_control);

pub const SourceControlDialog = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "TermplexSourceControlDialog",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        dialog: *adw.Dialog,
        status_label: *gtk.Label,
        staged_view: *gtk.ListView,
        unstaged_view: *gtk.ListView,
        staged_model: *gtk.SingleSelection,
        unstaged_model: *gtk.SingleSelection,
        staged_source: *gio.ListStore,
        unstaged_source: *gio.ListStore,
        diff_label: *gtk.Label,
        commit_entry: *gtk.Entry,

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
        const priv = self.private();
        priv.staged_source.removeAll();
        priv.unstaged_source.removeAll();

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

    fn setStatus(self: *Self, text: []const u8) void {
        const alloc = std.heap.c_allocator;
        const label = alloc.dupeZ(u8, text) catch return;
        defer alloc.free(label);
        self.private().status_label.setLabel(label);
    }

    fn setDiff(self: *Self, text: []const u8) void {
        const alloc = std.heap.c_allocator;
        const label = alloc.dupeZ(u8, if (text.len > 0) text else "(no diff)") catch return;
        defer alloc.free(label);
        self.private().diff_label.setLabel(label);
    }

    fn refresh(self: *Self) void {
        const priv = self.private();
        const alloc = std.heap.c_allocator;

        var status = Application.default().queryActiveGitStatus() catch |err| {
            log.warn("failed to refresh source control: {}", .{err});
            self.setStatus("Unable to read git status");
            priv.staged_source.removeAll();
            priv.unstaged_source.removeAll();
            self.setDiff("");
            return;
        };
        defer status.deinit(alloc);

        priv.staged_source.removeAll();
        priv.unstaged_source.removeAll();
        self.setDiff("");

        if (!status.is_repo) {
            self.setStatus("No git repository detected for the active workspace");
            return;
        }

        const branch = status.branch orelse "detached";
        const state = if (status.dirty) "dirty" else "clean";
        const remote = status.remote_url orelse "no origin remote";
        const root = status.root orelse "";
        const summary = std.fmt.allocPrint(
            alloc,
            "{s} - {s} - {s} - {s}",
            .{ branch, state, root, remote },
        ) catch null;
        if (summary) |text| {
            defer alloc.free(text);
            self.setStatus(text);
        }

        for (status.staged) |change| {
            const item = GitChange.new(change) catch |err| {
                log.warn("failed to create staged git row: {}", .{err});
                continue;
            };
            priv.staged_source.append(item.as(gobject.Object));
            item.unref();
        }

        for (status.unstaged) |change| {
            const item = GitChange.new(change) catch |err| {
                log.warn("failed to create unstaged git row: {}", .{err});
                continue;
            };
            priv.unstaged_source.append(item.as(gobject.Object));
            item.unref();
        }
    }

    fn selectedChange(model: *gtk.SingleSelection) ?*GitChange {
        const object = model.as(gio.ListModel).getObject(model.getSelected()) orelse return null;
        return gobject.ext.cast(GitChange, object) orelse {
            object.unref();
            return null;
        };
    }

    fn showDiffAt(self: *Self, staged: bool, pos: c_uint) void {
        const priv = self.private();
        const model = if (staged) priv.staged_model else priv.unstaged_model;
        const object = model.as(gio.ListModel).getObject(pos) orelse return;
        const item = gobject.ext.cast(GitChange, object) orelse {
            object.unref();
            return;
        };
        defer item.unref();

        const path = item.path() orelse return;
        var result = Application.default().diffActiveGitFile(path, staged) catch |err| {
            log.warn("failed to read git diff for {s}: {}", .{ path, err });
            self.setDiff("Unable to read diff");
            return;
        };
        defer result.deinit(std.heap.c_allocator);

        self.setDiff(result.diff);
    }

    fn dialogClosed(_: *adw.Dialog, self: *SourceControlDialog) callconv(.c) void {
        self.unref();
    }

    fn refreshClicked(_: *gtk.Button, self: *SourceControlDialog) callconv(.c) void {
        self.refresh();
    }

    fn stagedRowActivated(_: *gtk.ListView, pos: c_uint, self: *SourceControlDialog) callconv(.c) void {
        self.showDiffAt(true, pos);
    }

    fn unstagedRowActivated(_: *gtk.ListView, pos: c_uint, self: *SourceControlDialog) callconv(.c) void {
        self.showDiffAt(false, pos);
    }

    fn stageClicked(_: *gtk.Button, self: *SourceControlDialog) callconv(.c) void {
        const item = selectedChange(self.private().unstaged_model) orelse return;
        defer item.unref();
        const path = item.path() orelse return;

        var status = Application.default().stageActiveGitFile(path) catch |err| {
            log.warn("failed to stage {s}: {}", .{ path, err });
            self.setStatus("Unable to stage file");
            return;
        };
        status.deinit(std.heap.c_allocator);
        self.refresh();
    }

    fn stageAllClicked(_: *gtk.Button, self: *SourceControlDialog) callconv(.c) void {
        var status = Application.default().stageAllActiveGitFiles() catch |err| {
            log.warn("failed to stage all files: {}", .{err});
            self.setStatus("Unable to stage all files");
            return;
        };
        status.deinit(std.heap.c_allocator);
        self.refresh();
    }

    fn unstageClicked(_: *gtk.Button, self: *SourceControlDialog) callconv(.c) void {
        const item = selectedChange(self.private().staged_model) orelse return;
        defer item.unref();
        const path = item.path() orelse return;

        var status = Application.default().unstageActiveGitFile(path) catch |err| {
            log.warn("failed to unstage {s}: {}", .{ path, err });
            self.setStatus("Unable to unstage file");
            return;
        };
        status.deinit(std.heap.c_allocator);
        self.refresh();
    }

    fn unstageAllClicked(_: *gtk.Button, self: *SourceControlDialog) callconv(.c) void {
        var status = Application.default().unstageAllActiveGitFiles() catch |err| {
            log.warn("failed to unstage all files: {}", .{err});
            self.setStatus("Unable to unstage all files");
            return;
        };
        status.deinit(std.heap.c_allocator);
        self.refresh();
    }

    fn commitClicked(_: *gtk.Button, self: *SourceControlDialog) callconv(.c) void {
        const priv = self.private();
        const message = std.mem.span(priv.commit_entry.as(gtk.Editable).getText());
        var result = Application.default().commitActiveGitStaged(message) catch |err| {
            log.warn("failed to commit staged files: {}", .{err});
            self.setStatus("Unable to commit staged files");
            return;
        };
        result.deinit(std.heap.c_allocator);
        priv.commit_entry.as(gtk.Editable).setText("");
        self.refresh();
    }

    pub fn toggle(self: *SourceControlDialog, window: *Window) void {
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
            gobject.ext.ensureType(GitChange);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "source-control-dialog",
                }),
            );

            class.bindTemplateChildPrivate("dialog", .{});
            class.bindTemplateChildPrivate("status_label", .{});
            class.bindTemplateChildPrivate("staged_view", .{});
            class.bindTemplateChildPrivate("unstaged_view", .{});
            class.bindTemplateChildPrivate("staged_model", .{});
            class.bindTemplateChildPrivate("unstaged_model", .{});
            class.bindTemplateChildPrivate("staged_source", .{});
            class.bindTemplateChildPrivate("unstaged_source", .{});
            class.bindTemplateChildPrivate("diff_label", .{});
            class.bindTemplateChildPrivate("commit_entry", .{});

            class.bindTemplateCallback("closed", &dialogClosed);
            class.bindTemplateCallback("refresh_clicked", &refreshClicked);
            class.bindTemplateCallback("staged_row_activated", &stagedRowActivated);
            class.bindTemplateCallback("unstaged_row_activated", &unstagedRowActivated);
            class.bindTemplateCallback("stage_clicked", &stageClicked);
            class.bindTemplateCallback("unstage_clicked", &unstageClicked);
            class.bindTemplateCallback("stage_all_clicked", &stageAllClicked);
            class.bindTemplateCallback("unstage_all_clicked", &unstageAllClicked);
            class.bindTemplateCallback("commit_clicked", &commitClicked);

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};

const GitChange = extern struct {
    const Self = @This();
    pub const Parent = gobject.Object;
    parent: Parent,

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "TermplexGitChange",
        .instanceInit = &init,
        .classInit = Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const properties = struct {
        pub const path = struct {
            pub const name = "path";
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
                            .getter = propGetPath,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };

        pub const status = struct {
            pub const name = "status";
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
                            .getter = propGetStatus,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };
    };

    const Private = struct {
        arena: ArenaAllocator,
        path_text: ?[:0]const u8 = null,
        status_text: ?[:0]const u8 = null,

        pub var offset: c_int = 0;
    };

    pub fn new(change: git_status.Change) Allocator.Error!*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();

        const priv = self.private();
        const alloc = priv.arena.allocator();
        priv.path_text = try alloc.dupeZ(u8, change.path);
        priv.status_text = try alloc.dupeZ(u8, @tagName(change.status));

        return self;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        self.private().arena = .init(Application.default().allocator());
    }

    fn dispose(self: *Self) callconv(.c) void {
        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        self.private().arena.deinit();
        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn propGetPath(self: *Self) ?[:0]const u8 {
        return self.private().path_text;
    }

    fn propGetStatus(self: *Self) ?[:0]const u8 {
        return self.private().status_text;
    }

    fn path(self: *Self) ?[:0]const u8 {
        return self.private().path_text;
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
                properties.path.impl,
                properties.status.impl,
            });

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
    };
};
