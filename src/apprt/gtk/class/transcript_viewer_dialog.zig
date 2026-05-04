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

const log = std.log.scoped(.gtk_termplex_transcript_viewer);

pub const TranscriptViewerDialog = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "TermplexTranscriptViewerDialog",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        dialog: *adw.Dialog,
        search: *gtk.SearchEntry,
        status_label: *gtk.Label,
        text_view: *gtk.TextView,
        marker_view: *gtk.ListView,
        marker_model: *gtk.SingleSelection,
        marker_source: *gio.ListStore,
        text_buffer: *gtk.TextBuffer = undefined,
        history_id: ?[:0]u8 = null,
        match_lines: []usize = &.{},
        match_index: usize = 0,

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
        priv.text_buffer = gtk.TextBuffer.new(null);
        priv.text_view.setBuffer(priv.text_buffer);
    }

    fn clearState(self: *Self) void {
        const priv = self.private();
        const alloc = Application.default().allocator();
        if (priv.history_id) |history_id| {
            alloc.free(history_id);
            priv.history_id = null;
        }
        if (priv.match_lines.len > 0) {
            alloc.free(priv.match_lines);
            priv.match_lines = &.{};
        }
        priv.match_index = 0;
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        self.clearState();
        priv.marker_source.removeAll();
        const text_buffer = priv.text_buffer;

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );
        text_buffer.unref();

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

    fn setTranscriptText(self: *Self, text: []const u8) void {
        const alloc = std.heap.c_allocator;
        const text_z = alloc.dupeZ(u8, text) catch return;
        defer alloc.free(text_z);
        self.private().text_buffer.setText(text_z.ptr, @intCast(text.len));
    }

    fn activeHistoryId(window: *Window) ?[:0]const u8 {
        const surface = window.getActiveSurface() orelse return null;
        return surface.getHistoryId();
    }

    pub fn presentForHistory(self: *Self, window: *Window, history_id: ?[]const u8) bool {
        const target = history_id orelse activeHistoryId(window) orelse {
            self.setStatus("No active terminal history");
            return false;
        };

        self.loadHistory(target) catch |err| {
            log.warn("failed to load transcript viewer for {s}: {}", .{ target, err });
            self.setStatus("Unable to load transcript");
            return false;
        };

        self.private().dialog.present(window.as(gtk.Widget));
        return true;
    }

    pub fn toggle(self: *Self, window: *Window) void {
        if (self.private().dialog.as(gtk.Widget).getRealized() != 0) {
            self.close();
            return;
        }
        _ = self.presentForHistory(window, null);
    }

    fn loadHistory(self: *Self, history_id: []const u8) !void {
        const priv = self.private();
        const alloc = Application.default().allocator();
        self.clearState();
        priv.marker_source.removeAll();
        priv.search.as(gtk.Editable).setText("");

        const data = try Application.default().readTerminalTranscript(history_id, 5000);
        defer data.deinit();

        priv.history_id = try alloc.dupeZ(u8, data.surface.history_id);
        self.setTranscriptText(data.output);

        for (data.commands.items) |record| {
            const item = TranscriptMarker.new(record) catch |err| {
                log.warn("failed to create transcript marker row: {}", .{err});
                continue;
            };
            priv.marker_source.append(item.as(gobject.Object));
            item.unref();
        }

        const status = try std.fmt.allocPrint(
            std.heap.c_allocator,
            "{s} - {d} command marker(s)",
            .{ data.surface.workspace_name, data.commands.items.len },
        );
        defer std.heap.c_allocator.free(status);
        self.setStatus(status);
    }

    fn selectedMarker(self: *Self) ?*TranscriptMarker {
        const priv = self.private();
        const object = priv.marker_model.as(gio.ListModel).getObject(priv.marker_model.getSelected()) orelse return null;
        return gobject.ext.cast(TranscriptMarker, object) orelse {
            object.unref();
            return null;
        };
    }

    fn scrollToLine(self: *Self, line_number: usize) void {
        if (line_number == 0) return;
        const priv = self.private();
        var iter: gtk.TextIter = undefined;
        _ = priv.text_buffer.getIterAtLine(&iter, @intCast(line_number - 1));
        priv.text_buffer.placeCursor(&iter);
        _ = priv.text_view.scrollToIter(&iter, 0.15, 1, 0.0, 0.1);
    }

    fn updateSearchMatches(self: *Self) void {
        const priv = self.private();
        const alloc = Application.default().allocator();
        if (priv.match_lines.len > 0) {
            alloc.free(priv.match_lines);
            priv.match_lines = &.{};
        }
        priv.match_index = 0;

        const history_id = priv.history_id orelse return;
        const query = std.mem.span(priv.search.as(gtk.Editable).getText());
        if (query.len == 0) {
            self.setStatus("Ready");
            return;
        }

        const results = Application.default().searchTerminalTranscript(history_id, query, 200) catch |err| {
            log.warn("failed to search transcript viewer: {}", .{err});
            self.setStatus("Unable to search transcript");
            return;
        };
        defer results.deinit(std.heap.c_allocator);

        if (results.items.len == 0) {
            self.setStatus("0 match(es)");
            return;
        }

        var lines = alloc.alloc(usize, results.items.len) catch return;
        for (results.items, 0..) |item, index| {
            lines[index] = item.line_number;
        }
        priv.match_lines = lines;

        const status = std.fmt.allocPrint(
            std.heap.c_allocator,
            "{d} match(es)",
            .{results.items.len},
        ) catch return;
        defer std.heap.c_allocator.free(status);
        self.setStatus(status);

        if (priv.match_lines.len > 0) self.scrollToLine(priv.match_lines[0]);
    }

    fn searchAndScrollCommand(self: *Self, command: []const u8) void {
        const priv = self.private();
        const history_id = priv.history_id orelse return;
        const results = Application.default().searchTerminalTranscript(history_id, command, 1) catch |err| {
            log.warn("failed to search transcript command marker: {}", .{err});
            self.setStatus("Unable to find command marker");
            return;
        };
        defer results.deinit(std.heap.c_allocator);
        if (results.items.len == 0) {
            self.setStatus("Command marker text not found in transcript");
            return;
        }
        self.scrollToLine(results.items[0].line_number);
        self.setStatus("Command marker selected");
    }

    fn dialogClosed(_: *adw.Dialog, self: *TranscriptViewerDialog) callconv(.c) void {
        self.unref();
    }

    fn searchChanged(_: *gtk.SearchEntry, self: *TranscriptViewerDialog) callconv(.c) void {
        self.updateSearchMatches();
    }

    fn searchStopped(_: *gtk.SearchEntry, self: *TranscriptViewerDialog) callconv(.c) void {
        self.close();
    }

    fn previousClicked(_: *gtk.Button, self: *TranscriptViewerDialog) callconv(.c) void {
        const priv = self.private();
        if (priv.match_lines.len == 0) return;
        priv.match_index = if (priv.match_index == 0) priv.match_lines.len - 1 else priv.match_index - 1;
        self.scrollToLine(priv.match_lines[priv.match_index]);
    }

    fn nextClicked(_: *gtk.Button, self: *TranscriptViewerDialog) callconv(.c) void {
        const priv = self.private();
        if (priv.match_lines.len == 0) return;
        priv.match_index = (priv.match_index + 1) % priv.match_lines.len;
        self.scrollToLine(priv.match_lines[priv.match_index]);
    }

    fn markerActivated(_: *gtk.ListView, pos: c_uint, self: *TranscriptViewerDialog) callconv(.c) void {
        const object = self.private().marker_model.as(gio.ListModel).getObject(pos) orelse return;
        const marker = gobject.ext.cast(TranscriptMarker, object) orelse {
            object.unref();
            return;
        };
        defer marker.unref();
        const command = marker.command() orelse return;
        self.searchAndScrollCommand(command);
    }

    fn markerOpenClicked(_: *gtk.Button, self: *TranscriptViewerDialog) callconv(.c) void {
        const marker = self.selectedMarker() orelse return;
        defer marker.unref();
        const command = marker.command() orelse return;
        self.searchAndScrollCommand(command);
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
            gobject.ext.ensureType(TranscriptMarker);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "transcript-viewer-dialog",
                }),
            );

            class.bindTemplateChildPrivate("dialog", .{});
            class.bindTemplateChildPrivate("search", .{});
            class.bindTemplateChildPrivate("status_label", .{});
            class.bindTemplateChildPrivate("text_view", .{});
            class.bindTemplateChildPrivate("marker_view", .{});
            class.bindTemplateChildPrivate("marker_model", .{});
            class.bindTemplateChildPrivate("marker_source", .{});

            class.bindTemplateCallback("closed", &dialogClosed);
            class.bindTemplateCallback("search_changed", &searchChanged);
            class.bindTemplateCallback("search_stopped", &searchStopped);
            class.bindTemplateCallback("previous_clicked", &previousClicked);
            class.bindTemplateCallback("next_clicked", &nextClicked);
            class.bindTemplateCallback("marker_activated", &markerActivated);
            class.bindTemplateCallback("marker_open_clicked", &markerOpenClicked);

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};

const TranscriptMarker = extern struct {
    const Self = @This();
    pub const Parent = gobject.Object;
    parent: Parent,

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "TermplexTranscriptMarker",
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
    };

    const Private = struct {
        arena: ArenaAllocator,
        command_text: ?[:0]const u8 = null,
        metadata_text: ?[:0]const u8 = null,

        pub var offset: c_int = 0;
    };

    pub fn new(record: terminal_history_db.CommandRecord) Allocator.Error!*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();

        const priv = self.private();
        const alloc = priv.arena.allocator();
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
            "{s} - {s} - {s}",
            .{ record.source, status, record.started_at },
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

    fn propGetMetadata(self: *Self) ?[:0]const u8 {
        return self.private().metadata_text;
    }

    fn command(self: *Self) ?[:0]const u8 {
        return self.private().command_text;
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
            });
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
    };
};
