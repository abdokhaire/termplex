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
const terminal_history_db = @import("../../../termplex/core/terminal_history_db.zig");

const log = std.log.scoped(.gtk_termplex_command_history);

pub const CommandHistoryDialog = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "TermplexCommandHistoryDialog",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const signals = struct {
        pub const copy = struct {
            pub const name = "copy";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{[*:0]const u8},
                void,
            );
        };

        pub const rerun = struct {
            pub const name = "rerun";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{[*:0]const u8},
                void,
            );
        };

        pub const @"open-transcript" = struct {
            pub const name = "open-transcript";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{[*:0]const u8},
                void,
            );
        };
    };

    const Private = struct {
        dialog: *adw.Dialog,
        search: *gtk.SearchEntry,
        view: *gtk.ListView,
        model: *gtk.SingleSelection,
        source: *gio.ListStore,

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
        priv.source.removeAll();

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn refresh(self: *Self) void {
        const priv = self.private();
        const query_text = std.mem.span(priv.search.as(gtk.Editable).getText());

        const list = Application.default().searchTerminalCommands(.{
            .text = query_text,
            .limit = 50,
        }) catch |err| {
            log.warn("failed to refresh command history: {}", .{err});
            priv.source.removeAll();
            return;
        };
        defer list.deinit(std.heap.c_allocator);

        priv.source.removeAll();
        for (list.items) |record| {
            const item = HistoryCommand.new(record) catch |err| {
                log.warn("failed to create command history row: {}", .{err});
                continue;
            };
            priv.source.append(item.as(gobject.Object));
            item.unref();
        }
    }

    fn close(self: *Self) void {
        const priv = self.private();
        _ = priv.dialog.close();
    }

    fn selectedCommand(self: *Self) ?*HistoryCommand {
        const priv = self.private();
        const object = priv.model.as(gio.ListModel).getObject(priv.model.getSelected()) orelse return null;
        return gobject.ext.cast(HistoryCommand, object) orelse {
            object.unref();
            return null;
        };
    }

    fn emitSelected(self: *Self, comptime signal: enum { copy, rerun }, close_after: bool) void {
        const item = self.selectedCommand() orelse return;
        defer item.unref();

        const command = item.command() orelse return;
        switch (signal) {
            .copy => signals.copy.impl.emit(
                self,
                null,
                .{command.ptr},
                null,
            ),
            .rerun => signals.rerun.impl.emit(
                self,
                null,
                .{command.ptr},
                null,
            ),
        }
        if (close_after) self.close();
    }

    fn dialogClosed(_: *adw.Dialog, self: *CommandHistoryDialog) callconv(.c) void {
        self.unref();
    }

    fn searchChanged(_: *gtk.SearchEntry, self: *CommandHistoryDialog) callconv(.c) void {
        self.refresh();
    }

    fn searchStopped(_: *gtk.SearchEntry, self: *CommandHistoryDialog) callconv(.c) void {
        self.close();
    }

    fn searchActivated(_: *gtk.SearchEntry, self: *CommandHistoryDialog) callconv(.c) void {
        self.emitSelected(.rerun, true);
    }

    fn rowActivated(_: *gtk.ListView, pos: c_uint, self: *CommandHistoryDialog) callconv(.c) void {
        const object = self.private().model.as(gio.ListModel).getObject(pos) orelse return;
        const item = gobject.ext.cast(HistoryCommand, object) orelse {
            object.unref();
            return;
        };
        defer item.unref();

        const command = item.command() orelse return;
        signals.rerun.impl.emit(
            self,
            null,
            .{command.ptr},
            null,
        );
        self.close();
    }

    fn copyClicked(_: *gtk.Button, self: *CommandHistoryDialog) callconv(.c) void {
        self.emitSelected(.copy, false);
    }

    fn rerunClicked(_: *gtk.Button, self: *CommandHistoryDialog) callconv(.c) void {
        self.emitSelected(.rerun, true);
    }

    fn transcriptClicked(_: *gtk.Button, self: *CommandHistoryDialog) callconv(.c) void {
        const item = self.selectedCommand() orelse return;
        defer item.unref();

        const history_id = item.historyId() orelse return;
        signals.@"open-transcript".impl.emit(
            self,
            null,
            .{history_id.ptr},
            null,
        );
        self.close();
    }

    pub fn toggle(self: *CommandHistoryDialog, window: *Window) void {
        const priv = self.private();

        if (priv.dialog.as(gtk.Widget).getRealized() != 0) {
            self.close();
            return;
        }

        self.refresh();
        priv.dialog.present(window.as(gtk.Widget));
        _ = priv.search.as(gtk.Widget).grabFocus();
        priv.search.as(gtk.Editable).selectRegion(0, -1);
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
            gobject.ext.ensureType(HistoryCommand);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "command-history-dialog",
                }),
            );

            class.bindTemplateChildPrivate("dialog", .{});
            class.bindTemplateChildPrivate("search", .{});
            class.bindTemplateChildPrivate("view", .{});
            class.bindTemplateChildPrivate("model", .{});
            class.bindTemplateChildPrivate("source", .{});

            class.bindTemplateCallback("closed", &dialogClosed);
            class.bindTemplateCallback("search_changed", &searchChanged);
            class.bindTemplateCallback("search_stopped", &searchStopped);
            class.bindTemplateCallback("search_activated", &searchActivated);
            class.bindTemplateCallback("row_activated", &rowActivated);
            class.bindTemplateCallback("copy_clicked", &copyClicked);
            class.bindTemplateCallback("rerun_clicked", &rerunClicked);
            class.bindTemplateCallback("transcript_clicked", &transcriptClicked);

            signals.copy.impl.register(.{});
            signals.rerun.impl.register(.{});
            signals.@"open-transcript".impl.register(.{});

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};

const HistoryCommand = extern struct {
    const Self = @This();
    pub const Parent = gobject.Object;
    parent: Parent,

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "TermplexHistoryCommand",
        .instanceInit = &init,
        .classInit = Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const properties = struct {
        pub const command = struct {
            pub const name = "command";
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
                            .getter = propGetCommand,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };

        pub const metadata = struct {
            pub const name = "metadata";
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
                            .getter = propGetMetadata,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };

        pub const @"history-id" = struct {
            pub const name = "history-id";
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
                            .getter = propGetHistoryId,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };
    };

    const Private = struct {
        arena: ArenaAllocator,
        history_id: ?[:0]const u8 = null,
        command_text: ?[:0]const u8 = null,
        metadata_text: ?[:0]const u8 = null,

        pub var offset: c_int = 0;
    };

    pub fn new(record: terminal_history_db.CommandRecord) Allocator.Error!*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();

        const priv = self.private();
        const alloc = priv.arena.allocator();
        priv.history_id = try alloc.dupeZ(u8, record.history_id);
        priv.command_text = try alloc.dupeZ(u8, record.command);
        priv.metadata_text = try formatMetadata(alloc, record);

        return self;
    }

    fn formatMetadata(alloc: Allocator, record: terminal_history_db.CommandRecord) Allocator.Error![:0]const u8 {
        const status = if (record.exit_code) |code|
            try std.fmt.allocPrint(alloc, "exit {d}", .{code})
        else
            try alloc.dupe(u8, "running");
        defer alloc.free(status);

        const metadata = try std.fmt.allocPrint(
            alloc,
            "{s} - {s} - {s} - {s}",
            .{ record.workspace_name, record.source, status, record.started_at },
        );
        defer alloc.free(metadata);
        return try alloc.dupeZ(u8, metadata);
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

    fn propGetCommand(self: *Self) ?[:0]const u8 {
        return self.private().command_text;
    }

    fn propGetHistoryId(self: *Self) ?[:0]const u8 {
        return self.private().history_id;
    }

    fn propGetMetadata(self: *Self) ?[:0]const u8 {
        return self.private().metadata_text;
    }

    fn command(self: *Self) ?[:0]const u8 {
        return self.private().command_text;
    }

    fn historyId(self: *Self) ?[:0]const u8 {
        return self.private().history_id;
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
                properties.command.impl,
                properties.metadata.impl,
                properties.@"history-id".impl,
            });

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
    };
};
