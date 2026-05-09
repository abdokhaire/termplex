const std = @import("std");
const Allocator = std.mem.Allocator;

const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Tab = @import("tab.zig").Tab;
const Window = @import("window.zig").Window;

const log = std.log.scoped(.gtk_termplex_global_tabs);

const PreviewLineCount = 7;
const PreviewLineColumns = 72;
const PreviewJobsPerIdle = 2;

pub fn globalTabMatchesFilter(title: []const u8, workspace: []const u8, filter: []const u8) bool {
    const trimmed = std.mem.trim(u8, filter, " \t\r\n");
    if (trimmed.len == 0) return true;
    return std.ascii.indexOfIgnoreCase(title, trimmed) != null or
        std.ascii.indexOfIgnoreCase(workspace, trimmed) != null;
}

pub fn terminalPreviewFromText(alloc: Allocator, text: []const u8) Allocator.Error![:0]const u8 {
    var lines: [PreviewLineCount][]const u8 = undefined;
    var count: usize = 0;

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        if (count < lines.len) {
            lines[count] = line;
            count += 1;
        } else {
            std.mem.copyForwards([]const u8, lines[0 .. lines.len - 1], lines[1..]);
            lines[lines.len - 1] = line;
        }
    }

    if (count == 0) return alloc.dupeZ(u8, "No visible terminal output");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);

    for (lines[0..count], 0..) |line, idx| {
        if (idx > 0) try buf.append(alloc, '\n');
        const clipped = if (line.len > PreviewLineColumns) line[0..PreviewLineColumns] else line;
        try buf.appendSlice(alloc, clipped);
    }

    return try alloc.dupeZ(u8, buf.items);
}

pub fn previewKey(workspace_idx: u32, tab_idx: u32) u64 {
    return (@as(u64, workspace_idx) << 32) | @as(u64, tab_idx);
}

pub const GlobalTabsDialog = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "TermplexGlobalTabsDialog",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Target = struct {
        workspace_idx: u32,
        tab_idx: u32,
    };

    const PreviewJob = struct {
        key: u64,
        workspace_idx: u32,
        tab_idx: u32,
        label: *gtk.Label,
    };

    const TabCard = struct {
        widget: *gtk.Widget,
        preview: *gtk.Label,
    };

    const Private = struct {
        dialog: *adw.Dialog,
        search: *gtk.SearchEntry,
        content_box: *gtk.Box,
        empty_label: *gtk.Label,
        window: ?*Window = null,
        targets: std.ArrayListUnmanaged(Target) = .empty,
        preview_jobs: std.ArrayListUnmanaged(PreviewJob) = .empty,
        preview_source: ?c_uint = null,
        preview_cache: std.AutoHashMapUnmanaged(u64, [:0]const u8) = .empty,

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
        clearContent(self);
        priv.targets.deinit(Application.default().allocator());
        priv.preview_jobs.deinit(Application.default().allocator());
        clearPreviewCache(self);
        priv.preview_cache.deinit(Application.default().allocator());
        priv.window = null;

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn clearContent(self: *Self) void {
        const priv = self.private();
        cancelPreviewJobs(self);
        var child = priv.content_box.as(gtk.Widget).getFirstChild();
        while (child) |widget| {
            const next = widget.getNextSibling();
            if (widget != priv.empty_label.as(gtk.Widget)) {
                priv.content_box.remove(widget);
            }
            child = next;
        }
        priv.targets.clearRetainingCapacity();
    }

    fn cancelPreviewJobs(self: *Self) void {
        const priv = self.private();
        if (priv.preview_source) |source| {
            _ = glib.Source.remove(source);
            priv.preview_source = null;
        }

        for (priv.preview_jobs.items) |job| {
            job.label.as(gobject.Object).unref();
        }
        priv.preview_jobs.clearRetainingCapacity();
    }

    fn clearPreviewCache(self: *Self) void {
        const priv = self.private();
        const alloc = Application.default().allocator();
        var values = priv.preview_cache.valueIterator();
        while (values.next()) |preview| alloc.free(preview.*);
        priv.preview_cache.clearRetainingCapacity();
    }

    fn refresh(self: *Self) void {
        const priv = self.private();
        const app = Application.default();
        const filter = std.mem.span(priv.search.as(gtk.Editable).getText());
        const alloc = app.allocator();

        clearContent(self);

        var total_tabs: u32 = 0;
        var workspace_idx: u32 = 0;
        while (workspace_idx < app.workspaceCount()) : (workspace_idx += 1) {
            const workspace_name = app.workspaceName(workspace_idx) orelse "Workspace";
            const tab_view = app.workspaceTabView(workspace_idx) orelse continue;
            const matching_count = countMatchingTabs(tab_view, workspace_name, filter);
            if (matching_count == 0) continue;

            const section = gtk.Box.new(.vertical, 10);
            section.as(gtk.Widget).addCssClass("global-tabs-workspace-section");

            const header = createWorkspaceHeader(alloc, workspace_name, matching_count, workspace_idx == app.activeWorkspaceIndex()) catch |err| {
                log.warn("failed to create global tabs workspace header: {}", .{err});
                continue;
            };
            section.append(header.as(gtk.Widget));

            const flow = gtk.FlowBox.new();
            flow.setSelectionMode(.single);
            flow.setActivateOnSingleClick(1);
            flow.setMinChildrenPerLine(1);
            flow.setMaxChildrenPerLine(4);
            flow.setColumnSpacing(12);
            flow.setRowSpacing(12);
            flow.as(gtk.Widget).addCssClass("global-tabs-flow");
            _ = gtk.FlowBox.signals.child_activated.connect(
                flow,
                *Self,
                &flowChildActivated,
                self,
                .{},
            );

            var tab_idx: c_int = 0;
            while (tab_idx < tab_view.getNPages()) : (tab_idx += 1) {
                const page = tab_view.getNthPage(tab_idx);
                const title = std.mem.span(page.getTitle());
                if (!globalTabMatchesFilter(title, workspace_name, filter)) continue;

                const active = workspace_idx == app.activeWorkspaceIndex() and tab_view.getSelectedPage() == page;
                const target_idx = priv.targets.items.len;
                priv.targets.append(alloc, .{
                    .workspace_idx = workspace_idx,
                    .tab_idx = @intCast(tab_idx),
                }) catch |err| {
                    log.warn("failed to append global tab target: {}", .{err});
                    continue;
                };

                const card = createTabCard(alloc, title, @intCast(tab_idx), active, target_idx) catch |err| {
                    log.warn("failed to create global tab card: {}", .{err});
                    _ = priv.targets.pop();
                    continue;
                };
                flow.append(card.widget);
                self.queuePreview(
                    card.preview,
                    previewKey(workspace_idx, @intCast(tab_idx)),
                    workspace_idx,
                    @intCast(tab_idx),
                );
                total_tabs += 1;
            }

            if (flow.getChildAtIndex(0)) |first| flow.selectChild(first);
            section.append(flow.as(gtk.Widget));
            priv.content_box.append(section.as(gtk.Widget));
        }

        const has_tabs = total_tabs > 0;
        priv.empty_label.as(gtk.Widget).setVisible(@intFromBool(!has_tabs));
        if (has_tabs) {
            if (firstFlowBox(self)) |flow| {
                _ = flow.as(gtk.Widget).grabFocus();
            }
        }
    }

    fn countMatchingTabs(tab_view: *adw.TabView, workspace_name: []const u8, filter: []const u8) u32 {
        var count: u32 = 0;
        var tab_idx: c_int = 0;
        while (tab_idx < tab_view.getNPages()) : (tab_idx += 1) {
            const page = tab_view.getNthPage(tab_idx);
            if (globalTabMatchesFilter(std.mem.span(page.getTitle()), workspace_name, filter)) {
                count += 1;
            }
        }
        return count;
    }

    fn createWorkspaceHeader(
        alloc: Allocator,
        workspace_name: []const u8,
        tab_count: u32,
        active: bool,
    ) Allocator.Error!*gtk.Box {
        const header = gtk.Box.new(.horizontal, 8);
        header.as(gtk.Widget).addCssClass("global-tabs-workspace-header");

        const title_z = try alloc.dupeZ(u8, workspace_name);
        defer alloc.free(title_z);
        const title = gtk.Label.new(title_z.ptr);
        title.as(gtk.Widget).addCssClass("global-tabs-workspace-title");
        title.as(gtk.Widget).setHexpand(1);
        title.setXalign(0.0);
        header.append(title.as(gtk.Widget));

        const suffix = if (active) " - current" else "";
        var count_buf: [64]u8 = undefined;
        const count_z = std.fmt.bufPrintZ(
            &count_buf,
            "{d} {s}{s}",
            .{ tab_count, if (tab_count == 1) "tab" else "tabs", suffix },
        ) catch "tabs";
        const count = gtk.Label.new(count_z.ptr);
        count.as(gtk.Widget).addCssClass("global-tabs-workspace-count");
        header.append(count.as(gtk.Widget));

        return header;
    }

    fn createTabCard(
        alloc: Allocator,
        title: []const u8,
        tab_idx: u32,
        active: bool,
        target_idx: usize,
    ) Allocator.Error!TabCard {
        const card = gtk.Box.new(.vertical, 8);
        card.as(gtk.Widget).addCssClass("global-tab-card");
        card.as(gtk.Widget).setSizeRequest(220, 150);
        card.as(gtk.Widget).setHexpand(1);
        card.as(gtk.Widget).setVexpand(0);

        const title_z = try alloc.dupeZ(u8, if (title.len > 0) title else "Untitled Tab");
        defer alloc.free(title_z);
        const title_label = gtk.Label.new(title_z.ptr);
        title_label.as(gtk.Widget).addCssClass("global-tab-title");
        title_label.setXalign(0.0);
        title_label.setEllipsize(.end);
        card.append(title_label.as(gtk.Widget));

        const preview = gtk.Label.new("Loading preview...");
        preview.as(gtk.Widget).addCssClass("global-tab-preview");
        preview.as(gtk.Widget).setVexpand(1);
        preview.setXalign(0.0);
        preview.setWrap(0);
        preview.setLines(PreviewLineCount);
        card.append(preview.as(gtk.Widget));

        var meta_buf: [64]u8 = undefined;
        const meta_z = std.fmt.bufPrintZ(
            &meta_buf,
            "Tab {d}{s}",
            .{ tab_idx + 1, if (active) " - active" else "" },
        ) catch "Tab";
        const meta = gtk.Label.new(meta_z.ptr);
        meta.as(gtk.Widget).addCssClass("global-tab-meta");
        meta.setXalign(0.0);
        card.append(meta.as(gtk.Widget));

        var target_buf: [32]u8 = undefined;
        const target_class = std.fmt.bufPrintZ(&target_buf, "global-tab-target-{d}", .{target_idx}) catch "global-tab-target";
        card.as(gtk.Widget).addCssClass(target_class);

        return .{
            .widget = card.as(gtk.Widget),
            .preview = preview,
        };
    }

    fn queuePreview(self: *Self, label: *gtk.Label, key: u64, workspace_idx: u32, tab_idx: u32) void {
        const priv = self.private();
        if (priv.preview_cache.get(key)) |cached| {
            label.setLabel(cached.ptr);
            return;
        }

        const alloc = Application.default().allocator();
        _ = label.as(gobject.Object).ref();
        priv.preview_jobs.append(alloc, .{
            .key = key,
            .workspace_idx = workspace_idx,
            .tab_idx = tab_idx,
            .label = label,
        }) catch |err| {
            label.as(gobject.Object).unref();
            log.warn("failed to queue global tab preview: {}", .{err});
            label.setLabel("Unable to queue preview");
            return;
        };

        if (priv.preview_source == null) {
            priv.preview_source = glib.idleAdd(processPreviewJobs, self);
        }
    }

    fn popPreviewJob(priv: *Private) ?PreviewJob {
        if (priv.preview_jobs.items.len == 0) return null;
        const job = priv.preview_jobs.items[0];
        std.mem.copyForwards(
            PreviewJob,
            priv.preview_jobs.items[0 .. priv.preview_jobs.items.len - 1],
            priv.preview_jobs.items[1..],
        );
        priv.preview_jobs.items.len -= 1;
        return job;
    }

    fn processPreviewJobs(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return @intFromBool(glib.SOURCE_REMOVE)));
        const priv = self.private();
        priv.preview_source = null;

        const alloc = Application.default().allocator();
        var processed: usize = 0;
        while (processed < PreviewJobsPerIdle) : (processed += 1) {
            const job = popPreviewJob(priv) orelse break;
            defer job.label.as(gobject.Object).unref();

            const preview = self.tabPreviewByTarget(job.workspace_idx, job.tab_idx) catch |err| preview: {
                log.warn("failed to load global tab preview: {}", .{err});
                break :preview alloc.dupeZ(u8, "Unable to read terminal preview") catch continue;
            };

            priv.preview_cache.put(alloc, job.key, preview) catch |err| {
                log.warn("failed to cache global tab preview: {}", .{err});
                job.label.setLabel(preview.ptr);
                alloc.free(preview);
                continue;
            };
            job.label.setLabel(preview.ptr);
        }

        if (priv.preview_jobs.items.len == 0) return @intFromBool(glib.SOURCE_REMOVE);
        priv.preview_source = glib.idleAdd(processPreviewJobs, self);
        return @intFromBool(glib.SOURCE_REMOVE);
    }

    fn tabPreviewByTarget(self: *Self, workspace_idx: u32, tab_idx: u32) Allocator.Error![:0]const u8 {
        _ = self;
        const app = Application.default();
        const alloc = app.allocator();
        const tab_view = app.workspaceTabView(workspace_idx) orelse {
            return alloc.dupeZ(u8, "Workspace is no longer open");
        };
        if (tab_idx >= @as(u32, @intCast(tab_view.getNPages()))) {
            return alloc.dupeZ(u8, "Tab is no longer open");
        }

        const page = tab_view.getNthPage(@intCast(tab_idx));
        const tab = gobject.ext.cast(Tab, page.getChild());
        return tabPreview(alloc, tab);
    }

    fn tabPreview(alloc: Allocator, tab: ?*Tab) Allocator.Error![:0]const u8 {
        const gtk_surface = if (tab) |tab_widget| tab_widget.getActiveSurface() else null;
        const core_surface = if (gtk_surface) |surface| surface.core() else null;
        const core = core_surface orelse return alloc.dupeZ(u8, "Terminal is starting...");

        core.renderer_state.mutex.lock();
        defer core.renderer_state.mutex.unlock();

        const text = core.renderer_state.terminal.plainString(alloc) catch {
            return alloc.dupeZ(u8, "Unable to read terminal preview");
        };
        defer alloc.free(text);

        return terminalPreviewFromText(alloc, text);
    }

    fn firstFlowBox(self: *Self) ?*gtk.FlowBox {
        const priv = self.private();
        var child = priv.content_box.as(gtk.Widget).getFirstChild();
        while (child) |section_widget| {
            child = section_widget.getNextSibling();
            const section = gobject.ext.cast(gtk.Box, section_widget) orelse continue;
            var section_child = section.as(gtk.Widget).getFirstChild();
            while (section_child) |candidate| {
                section_child = candidate.getNextSibling();
                if (gobject.ext.cast(gtk.FlowBox, candidate)) |flow| return flow;
            }
        }
        return null;
    }

    fn flowTargetOffset(self: *Self, target_flow: *gtk.FlowBox) usize {
        const priv = self.private();
        var offset: usize = 0;
        var child = priv.content_box.as(gtk.Widget).getFirstChild();
        while (child) |section_widget| {
            child = section_widget.getNextSibling();
            const section = gobject.ext.cast(gtk.Box, section_widget) orelse continue;
            var section_child = section.as(gtk.Widget).getFirstChild();
            while (section_child) |candidate| {
                section_child = candidate.getNextSibling();
                const flow = gobject.ext.cast(gtk.FlowBox, candidate) orelse continue;
                if (flow == target_flow) return offset;
                var idx: c_int = 0;
                while (flow.getChildAtIndex(idx) != null) : (idx += 1) {
                    offset += 1;
                }
            }
        }
        return offset;
    }

    fn activateTarget(self: *Self, target_idx: usize) void {
        const priv = self.private();
        if (target_idx >= priv.targets.items.len) return;
        const window = priv.window orelse return;
        const target = priv.targets.items[target_idx];
        if (!window.activateGlobalTab(target.workspace_idx, target.tab_idx)) {
            self.refresh();
            return;
        }
        self.close();
    }

    fn close(self: *Self) void {
        _ = self.private().dialog.close();
    }

    fn dialogClosed(_: *adw.Dialog, self: *GlobalTabsDialog) callconv(.c) void {
        clearContent(self);
        clearPreviewCache(self);
        self.private().window = null;
        self.unref();
    }

    fn searchChanged(_: *gtk.SearchEntry, self: *GlobalTabsDialog) callconv(.c) void {
        self.refresh();
    }

    fn searchStopped(_: *gtk.SearchEntry, self: *GlobalTabsDialog) callconv(.c) void {
        self.close();
    }

    fn searchActivated(_: *gtk.SearchEntry, self: *GlobalTabsDialog) callconv(.c) void {
        self.activateTarget(0);
    }

    fn refreshClicked(_: *gtk.Button, self: *GlobalTabsDialog) callconv(.c) void {
        clearPreviewCache(self);
        self.refresh();
    }

    fn flowChildActivated(flow: *gtk.FlowBox, child: *gtk.FlowBoxChild, self: *GlobalTabsDialog) callconv(.c) void {
        const index = child.getIndex();
        if (index < 0) return;
        self.activateTarget(self.flowTargetOffset(flow) + @as(usize, @intCast(index)));
    }

    pub fn toggle(self: *GlobalTabsDialog, window: *Window) void {
        const priv = self.private();

        if (priv.dialog.as(gtk.Widget).getRealized() != 0) {
            self.close();
            return;
        }

        priv.window = window;
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
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "global-tabs-dialog",
                }),
            );

            class.bindTemplateChildPrivate("dialog", .{});
            class.bindTemplateChildPrivate("search", .{});
            class.bindTemplateChildPrivate("content_box", .{});
            class.bindTemplateChildPrivate("empty_label", .{});

            class.bindTemplateCallback("closed", &dialogClosed);
            class.bindTemplateCallback("search_changed", &searchChanged);
            class.bindTemplateCallback("search_stopped", &searchStopped);
            class.bindTemplateCallback("search_activated", &searchActivated);
            class.bindTemplateCallback("refresh_clicked", &refreshClicked);

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};

test "global tab filter matches title and workspace case-insensitively" {
    try std.testing.expect(globalTabMatchesFilter("Shell", "Frontend", ""));
    try std.testing.expect(globalTabMatchesFilter("Shell", "Frontend", "shell"));
    try std.testing.expect(globalTabMatchesFilter("Shell", "Frontend", "front"));
    try std.testing.expect(!globalTabMatchesFilter("Shell", "Frontend", "backend"));
}

test "terminal preview keeps the latest visible non-empty lines" {
    const preview = try terminalPreviewFromText(
        std.testing.allocator,
        "one\n\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n",
    );
    defer std.testing.allocator.free(preview);
    try std.testing.expect(std.mem.startsWith(u8, preview, "two\nthree"));
    try std.testing.expect(std.mem.endsWith(u8, preview, "eight"));
}

test "preview cache keys include workspace and tab indexes" {
    try std.testing.expectEqual(@as(u64, 0), previewKey(0, 0));
    try std.testing.expectEqual(@as(u64, 1), previewKey(0, 1));
    try std.testing.expectEqual(@as(u64, 0x00000001_00000000), previewKey(1, 0));
    try std.testing.expect(previewKey(1, 2) != previewKey(2, 1));
}
