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

const log = std.log.scoped(.gtk_termplex_workspace_dashboard);

pub const WorkspaceDashboardDialog = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "TermplexWorkspaceDashboardDialog",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const signals = struct {
        pub const @"open-command-history" = struct {
            pub const name = "open-command-history";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{}, void);
        };

        pub const @"open-source-control" = struct {
            pub const name = "open-source-control";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{}, void);
        };

        pub const @"open-storage" = struct {
            pub const name = "open-storage";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{}, void);
        };

        pub const @"export-diagnostics" = struct {
            pub const name = "export-diagnostics";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{}, void);
        };

        pub const @"open-transcript" = struct {
            pub const name = "open-transcript";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{[*:0]const u8}, void);
        };

        pub const copy = struct {
            pub const name = "copy";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{[*:0]const u8}, void);
        };

        pub const rerun = struct {
            pub const name = "rerun";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(name, Self, &.{[*:0]const u8}, void);
        };

        pub const @"save-task" = struct {
            pub const name = "save-task";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{ [*:0]const u8, [*:0]const u8 },
                void,
            );
        };
    };

    const Private = struct {
        dialog: *adw.Dialog,
        workspace_label: *gtk.Label,
        summary_label: *gtk.Label,
        command_view: *gtk.ListView,
        command_model: *gtk.SingleSelection,
        command_source: *gio.ListStore,
        details_view: *gtk.TextView,
        details_buffer: *gtk.TextBuffer = undefined,
        active_history_id: ?[:0]u8 = null,

        pub var offset: c_int = 0;
    };

    pub fn new() *Self {
        const self = gobject.ext.newInstance(Self, .{});
        _ = self.refSink();
        return self.ref();
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        const priv = self.private();
        priv.details_buffer = gtk.TextBuffer.new(null);
        priv.details_view.setBuffer(priv.details_buffer);
    }

    fn clearState(self: *Self) void {
        const priv = self.private();
        const alloc = Application.default().allocator();
        if (priv.active_history_id) |value| {
            alloc.free(value);
            priv.active_history_id = null;
        }
        priv.command_source.removeAll();
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        self.clearState();
        const details_buffer = priv.details_buffer;

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );
        details_buffer.unref();

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

    fn setDetails(self: *Self, text: []const u8) void {
        const alloc = std.heap.c_allocator;
        const z = alloc.dupeZ(u8, text) catch return;
        defer alloc.free(z);
        self.private().details_buffer.setText(z.ptr, @intCast(text.len));
    }

    fn updateCommandDetails(self: *Self, item: *DashboardCommand) void {
        const alloc = std.heap.c_allocator;
        const command = item.command() orelse "";
        const metadata = item.metadata() orelse "";
        const command_id = item.commandId() orelse "";
        const history_id = item.historyId() orelse "";
        const text = std.fmt.allocPrint(
            alloc,
            "Command:\n{s}\n\nMetadata:\n{s}\n\nCommand ID:\n{s}\nHistory ID:\n{s}",
            .{ command, metadata, command_id, history_id },
        ) catch return;
        defer alloc.free(text);
        self.setDetails(text);
    }

    fn refresh(self: *Self) void {
        const priv = self.private();
        const alloc = std.heap.c_allocator;
        self.clearState();

        const status = Application.default().activeWorkspaceDashboardStatus(alloc, 8) catch |err| {
            log.warn("failed to refresh dashboard: {}", .{err});
            setLabel(priv.workspace_label, "Unable to read workspace dashboard");
            setLabel(priv.summary_label, "");
            self.setDetails("");
            return;
        };
        defer status.deinit(alloc);

        if (status.workspace.active_history_id) |history_id| {
            priv.active_history_id = Application.default().allocator().dupeZ(u8, history_id) catch null;
        }

        var tab_buf: [32]u8 = undefined;
        const active_tab_text = if (status.workspace.active_tab) |idx|
            std.fmt.bufPrint(&tab_buf, "{d}", .{idx}) catch "unknown"
        else
            "unknown";

        const workspace_text = std.fmt.allocPrint(
            alloc,
            "{s}\n{s}\nTabs: {d}  Active tab: {s}",
            .{
                status.workspace.name,
                status.workspace.current_pwd,
                status.workspace.tab_count,
                active_tab_text,
            },
        ) catch return;
        defer alloc.free(workspace_text);
        setLabel(priv.workspace_label, workspace_text);

        const branch = status.git.status.branch orelse "no branch";
        const repo_state = if (status.git.status.is_repo)
            if (status.git.status.dirty) "dirty" else "clean"
        else
            "not a git repository";
        const summary_text = std.fmt.allocPrint(
            alloc,
            "Git: {s} - {s} - staged {d}, unstaged {d}\nHistory: commands {d}, transcripts {d}, bytes {d}",
            .{
                branch,
                repo_state,
                status.git.staged_count,
                status.git.unstaged_count,
                status.storage.command_count,
                status.storage.transcript_file_count,
                status.storage.total_bytes,
            },
        ) catch return;
        defer alloc.free(summary_text);
        setLabel(priv.summary_label, summary_text);

        for (status.recent_commands.items) |record| {
            const item = DashboardCommand.new(record) catch |err| {
                log.warn("failed to create dashboard command row: {}", .{err});
                continue;
            };
            priv.command_source.append(item.as(gobject.Object));
            item.unref();
        }

        self.setDetails("Select a recent command to inspect its metadata.");
    }

    fn selectedCommand(self: *Self) ?*DashboardCommand {
        const priv = self.private();
        const object = priv.command_model.as(gio.ListModel).getObject(priv.command_model.getSelected()) orelse return null;
        return gobject.ext.cast(DashboardCommand, object) orelse {
            object.unref();
            return null;
        };
    }

    fn dialogClosed(_: *adw.Dialog, self: *WorkspaceDashboardDialog) callconv(.c) void {
        self.unref();
    }

    fn refreshClicked(_: *gtk.Button, self: *WorkspaceDashboardDialog) callconv(.c) void {
        self.refresh();
    }

    fn commandActivated(_: *gtk.ListView, pos: c_uint, self: *WorkspaceDashboardDialog) callconv(.c) void {
        const object = self.private().command_model.as(gio.ListModel).getObject(pos) orelse return;
        const item = gobject.ext.cast(DashboardCommand, object) orelse {
            object.unref();
            return;
        };
        defer item.unref();
        self.updateCommandDetails(item);
    }

    fn commandHistoryClicked(_: *gtk.Button, self: *WorkspaceDashboardDialog) callconv(.c) void {
        signals.@"open-command-history".impl.emit(self, null, .{}, null);
    }

    fn sourceControlClicked(_: *gtk.Button, self: *WorkspaceDashboardDialog) callconv(.c) void {
        signals.@"open-source-control".impl.emit(self, null, .{}, null);
    }

    fn storageClicked(_: *gtk.Button, self: *WorkspaceDashboardDialog) callconv(.c) void {
        signals.@"open-storage".impl.emit(self, null, .{}, null);
    }

    fn diagnosticsClicked(_: *gtk.Button, self: *WorkspaceDashboardDialog) callconv(.c) void {
        signals.@"export-diagnostics".impl.emit(self, null, .{}, null);
    }

    fn transcriptClicked(_: *gtk.Button, self: *WorkspaceDashboardDialog) callconv(.c) void {
        const history_id = self.private().active_history_id orelse return;
        signals.@"open-transcript".impl.emit(self, null, .{history_id.ptr}, null);
    }

    fn commandTranscriptClicked(_: *gtk.Button, self: *WorkspaceDashboardDialog) callconv(.c) void {
        const item = self.selectedCommand() orelse return;
        defer item.unref();
        const history_id = item.historyId() orelse return;
        signals.@"open-transcript".impl.emit(self, null, .{history_id.ptr}, null);
    }

    fn copyCommandClicked(_: *gtk.Button, self: *WorkspaceDashboardDialog) callconv(.c) void {
        const item = self.selectedCommand() orelse return;
        defer item.unref();
        const command = item.command() orelse return;
        signals.copy.impl.emit(self, null, .{command.ptr}, null);
    }

    fn rerunCommandClicked(_: *gtk.Button, self: *WorkspaceDashboardDialog) callconv(.c) void {
        const item = self.selectedCommand() orelse return;
        defer item.unref();
        const command = item.command() orelse return;
        signals.rerun.impl.emit(self, null, .{command.ptr}, null);
    }

    fn saveTaskClicked(_: *gtk.Button, self: *WorkspaceDashboardDialog) callconv(.c) void {
        const item = self.selectedCommand() orelse return;
        defer item.unref();
        const command_id = item.commandId() orelse return;
        const command = item.command() orelse return;
        signals.@"save-task".impl.emit(self, null, .{ command_id.ptr, command.ptr }, null);
    }

    pub fn toggle(self: *Self, window: *Window) void {
        const priv = self.private();

        if (priv.dialog.as(gtk.Widget).getRealized() != 0) {
            self.close();
            return;
        }

        self.refresh();
        priv.dialog.present(window.as(gtk.Widget));
    }

    pub fn refreshVisible(self: *Self) void {
        if (self.private().dialog.as(gtk.Widget).getRealized() != 0) {
            self.refresh();
        }
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
            gobject.ext.ensureType(DashboardCommand);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "workspace-dashboard-dialog",
                }),
            );

            class.bindTemplateChildPrivate("dialog", .{});
            class.bindTemplateChildPrivate("workspace_label", .{});
            class.bindTemplateChildPrivate("summary_label", .{});
            class.bindTemplateChildPrivate("command_view", .{});
            class.bindTemplateChildPrivate("command_model", .{});
            class.bindTemplateChildPrivate("command_source", .{});
            class.bindTemplateChildPrivate("details_view", .{});

            class.bindTemplateCallback("closed", &dialogClosed);
            class.bindTemplateCallback("refresh_clicked", &refreshClicked);
            class.bindTemplateCallback("command_history_clicked", &commandHistoryClicked);
            class.bindTemplateCallback("transcript_clicked", &transcriptClicked);
            class.bindTemplateCallback("source_control_clicked", &sourceControlClicked);
            class.bindTemplateCallback("storage_clicked", &storageClicked);
            class.bindTemplateCallback("diagnostics_clicked", &diagnosticsClicked);
            class.bindTemplateCallback("copy_command_clicked", &copyCommandClicked);
            class.bindTemplateCallback("rerun_command_clicked", &rerunCommandClicked);
            class.bindTemplateCallback("command_transcript_clicked", &commandTranscriptClicked);
            class.bindTemplateCallback("save_task_clicked", &saveTaskClicked);
            class.bindTemplateCallback("command_activated", &commandActivated);

            signals.@"open-command-history".impl.register(.{});
            signals.@"open-source-control".impl.register(.{});
            signals.@"open-storage".impl.register(.{});
            signals.@"export-diagnostics".impl.register(.{});
            signals.@"open-transcript".impl.register(.{});
            signals.copy.impl.register(.{});
            signals.rerun.impl.register(.{});
            signals.@"save-task".impl.register(.{});

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};

const DashboardCommand = extern struct {
    const Self = @This();
    pub const Parent = gobject.Object;
    parent: Parent,

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "TermplexDashboardCommand",
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

        pub const @"command-id" = struct {
            pub const name = "command-id";
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
                            .getter = propGetCommandId,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };
    };

    const Private = struct {
        arena: ArenaAllocator,
        command_text: ?[:0]const u8 = null,
        metadata_text: ?[:0]const u8 = null,
        history_id_text: ?[:0]const u8 = null,
        command_id_text: ?[:0]const u8 = null,

        pub var offset: c_int = 0;
    };

    pub fn new(record: terminal_history_db.CommandRecord) Allocator.Error!*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();

        const priv = self.private();
        const alloc = priv.arena.allocator();
        priv.command_text = try alloc.dupeZ(u8, record.command);
        priv.history_id_text = try alloc.dupeZ(u8, record.history_id);
        const command_id_text = try std.fmt.allocPrint(alloc, "{d}", .{record.id});
        priv.command_id_text = try alloc.dupeZ(u8, command_id_text);
        priv.metadata_text = try formatMetadata(alloc, record);
        return self;
    }

    fn formatMetadata(alloc: Allocator, record: terminal_history_db.CommandRecord) Allocator.Error![:0]const u8 {
        const status = if (record.exit_code) |code|
            try std.fmt.allocPrint(alloc, "exit {d}", .{code})
        else
            try alloc.dupe(u8, "running");
        defer alloc.free(status);

        const metadata_text = try std.fmt.allocPrint(
            alloc,
            "{s} - {s} - {s}",
            .{ record.source, status, record.started_at },
        );
        defer alloc.free(metadata_text);
        return try alloc.dupeZ(u8, metadata_text);
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

    fn propGetMetadata(self: *Self) ?[:0]const u8 {
        return self.private().metadata_text;
    }

    fn propGetHistoryId(self: *Self) ?[:0]const u8 {
        return self.private().history_id_text;
    }

    fn propGetCommandId(self: *Self) ?[:0]const u8 {
        return self.private().command_id_text;
    }

    fn command(self: *Self) ?[:0]const u8 {
        return self.private().command_text;
    }

    fn metadata(self: *Self) ?[:0]const u8 {
        return self.private().metadata_text;
    }

    fn historyId(self: *Self) ?[:0]const u8 {
        return self.private().history_id_text;
    }

    fn commandId(self: *Self) ?[:0]const u8 {
        return self.private().command_id_text;
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
                properties.@"command-id".impl,
            });
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
    };
};
