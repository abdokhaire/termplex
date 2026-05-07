const std = @import("std");
const assert = @import("../../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const build_config = @import("../../../build_config.zig");
const state = &@import("../../../global.zig").state;
const i18n = @import("../../../os/main.zig").i18n;
const apprt = @import("../../../apprt.zig");
const CoreApp = @import("../../../App.zig");
const configpkg = @import("../../../config.zig");
const input = @import("../../../input.zig");
const internal_os = @import("../../../os/main.zig");
const systemd = @import("../../../os/systemd.zig");
const terminal = @import("../../../terminal/main.zig");
const termio = @import("../../../termio.zig");
const xev = @import("../../../global.zig").xev;
const Binding = @import("../../../input.zig").Binding;
const CoreConfig = configpkg.Config;
const CoreSurface = @import("../../../Surface.zig");
const lib = @import("../../../lib/main.zig");

const ext = @import("../ext.zig");
const key = @import("../key.zig");
const adw_version = @import("../adw_version.zig");
const gtk_version = @import("../gtk_version.zig");
const winprotopkg = @import("../winproto.zig");
const ApprtApp = @import("../App.zig");
const Common = @import("../class.zig").Common;
const WeakRef = @import("../weak_ref.zig").WeakRef;
const Config = @import("config.zig").Config;
const Surface = @import("surface.zig").Surface;
const SplitTree = @import("split_tree.zig").SplitTree;
const Window = @import("window.zig").Window;
const Tab = @import("tab.zig").Tab;
const CloseConfirmationDialog = @import("close_confirmation_dialog.zig").CloseConfirmationDialog;
const ConfigErrorsDialog = @import("config_errors_dialog.zig").ConfigErrorsDialog;
const GlobalShortcuts = @import("global_shortcuts.zig").GlobalShortcuts;

const git_probe = @import("../../../termplex/core/git_probe.zig");
const git_status = @import("../../../termplex/core/git_status.zig");
const notification_mod = @import("../../../termplex/core/notification.zig");
const port_scanner = @import("../../../termplex/core/port_scanner.zig");
const session_mod = @import("../../../termplex/core/session.zig");
const storage_status = @import("../../../termplex/core/storage_status.zig");
const terminal_history = @import("../../../termplex/core/terminal_history.zig");
const terminal_history_db = @import("../../../termplex/core/terminal_history_db.zig");
const transcript_view = @import("../../../termplex/core/transcript_view.zig");
const update_checker_mod = @import("../../../termplex/core/update_checker.zig");
const update_manifest_mod = @import("../../../termplex/core/update_manifest.zig");
const update_state_mod = @import("../../../termplex/core/update_state.zig");
const workspace_mod = @import("../../../termplex/core/workspace.zig");
const termplex_config = @import("../../../termplex/core/config.zig");
const agents = @import("../../../termplex/ipc/agents.zig");
const memory_paths = @import("../../../termplex/core/memory/paths.zig");
const memory_orchestrator_context = @import("../../../termplex/core/memory/orchestrator_context.zig");
const memory_resume = @import("../../../termplex/core/memory/resume_manifest.zig");
const memory_state = @import("../../../termplex/core/memory/state.zig");
const memory_state_mgr = @import("../../../termplex/core/memory/state_manager.zig");
const uuid = @import("../../../termplex/util/uuid.zig");

const Uuid = uuid.Uuid;

const log = std.log.scoped(.gtk_termplex_application);

/// C setenv (linked via libc; used to export TERMPLEX_RESUME_MANIFEST).
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

/// Function used to funnel GLib/GObject/GTK log messages into Zig's logging
/// system rather than just getting dumped directly to stderr.
fn glibLogWriterFunction(
    level: glib.LogLevelFlags,
    fields: [*]const glib.LogField,
    n_fields: usize,
    _: ?*anyopaque,
) callconv(.c) glib.LogWriterOutput {
    const glib_log = std.log.scoped(.glib);

    var message_: ?[]const u8 = null;
    var domain_: ?[]const u8 = null;
    for (0..n_fields) |i| {
        const field = fields[i];
        const k = std.mem.span(field.f_key orelse continue);
        const v: []const u8 = v: {
            if (field.f_length >= 0) {
                const v: [*]const u8 = @ptrCast(field.f_value orelse continue);
                break :v v[0..@intCast(field.f_length)];
            }
            const v: [*:0]const u8 = @ptrCast(field.f_value orelse continue);
            break :v std.mem.span(v);
        };
        if (std.mem.eql(u8, k, "MESSAGE")) {
            message_ = v;
            continue;
        }
        if (std.mem.eql(u8, k, "GLIB_DOMAIN")) {
            domain_ = v;
            continue;
        }
    }

    const message = message_ orelse return .unhandled;
    const domain = domain_ orelse "«unknown»";

    if (level.level_error) {
        glib_log.err("ERROR: {s}: {s}", .{ domain, message });
        return .handled;
    }
    if (level.level_critical) {
        glib_log.err("CRITICAL: {s}: {s}", .{ domain, message });
        return .handled;
    }
    if (level.level_warning) {
        glib_log.warn("WARNING: {s}: {s}", .{ domain, message });
        return .handled;
    }
    if (level.level_message) {
        glib_log.info("MESSAGE: {s}: {s}", .{ domain, message });
        return .handled;
    }
    if (level.level_info) {
        glib_log.info("INFO: {s}: {s}", .{ domain, message });
        return .handled;
    }
    if (level.level_debug) {
        glib_log.debug("DEBUG: {s}: {s}", .{ domain, message });
        return .handled;
    }
    glib_log.debug("UNKNOWN: {s}: {s}", .{ domain, message });
    return .handled;
}

/// The primary entrypoint for the Termplex GTK application.
///
/// This requires a `termplex.App` and `termplex.Config` and takes
/// care of the rest. Call `run` to run the application to completion.
pub const Application = extern struct {
    /// This type creates a new GObject class. Since the Application is
    /// the primary entrypoint I'm going to use this as a place to document
    /// how this all works and where you can find resources for it, but
    /// this applies to any other GObject class within this apprt.
    ///
    /// The various fields (parent_instance) and constants (Parent,
    /// getGObjectType, etc.) are mandatory "interfaces" for zig-gobject
    /// to create a GObject class.
    ///
    /// I found these to be the best resources:
    ///
    ///   * https://github.com/ianprime0509/zig-gobject/blob/d7f1edaf50193d49b56c60568dfaa9f23195565b/extensions/gobject2.zig
    ///   * https://github.com/ianprime0509/zig-gobject/blob/d7f1edaf50193d49b56c60568dfaa9f23195565b/example/src/custom_class.zig
    ///
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Application;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "TermplexApplication",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                "config",
                Self,
                ?*Config,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*Config,
                        .{
                            .getter = Self.getConfig,
                            .getter_transfer = .full,
                        },
                    ),
                },
            );
        };
    };

    const Private = struct {
        /// The apprt App. This is annoying that we need this it'd be
        /// nicer to just make THIS the apprt app but the current libtermplex
        /// API doesn't allow that.
        rt_app: *ApprtApp,

        /// The libtermplex App instance.
        core_app: *CoreApp,

        /// The configuration for the application.
        config: *Config,

        /// State and logic for the underlying windowing protocol.
        winproto: winprotopkg.App,

        /// The global shortcut logic.
        global_shortcuts: *GlobalShortcuts,

        /// This is set to true so long as we request a window exactly
        /// once. This prevents quitting the app before we've shown one
        /// window.
        requested_window: bool = false,

        /// This is set to false internally when the event loop
        /// should exit and the application should quit. This must
        /// only be set by the main loop thread.
        running: bool = false,

        /// The timer used to quit the application after the last window is
        /// closed. Even if there is no quit delay set, this is the state
        /// used to determine to close the app.
        quit_timer: union(enum) {
            off,
            active: c_uint,
            expired,
        } = .off,

        /// If non-null, we're currently showing a config errors dialog.
        /// This is a WeakRef because the dialog can close on its own
        /// outside of our own lifecycle and that's okay.
        config_errors_dialog: WeakRef(ConfigErrorsDialog) = .empty,

        /// glib source for our signal handler.
        signal_source: ?c_uint = null,

        /// CSS Provider for any styles based on Termplex configuration values.
        css_provider: *gtk.CssProvider,

        /// Providers for loading custom stylesheets defined by user
        custom_css_providers: std.ArrayListUnmanaged(*gtk.CssProvider) = .empty,

        /// A copy of the LANG environment variable that was provided to Termplex
        /// by the system. If this is null, the LANG environment variable did
        /// not exist in Termplex's environment variable.
        saved_language: ?[:0]const u8 = null,

        // ----- Termplex workspace state -----

        /// Ordered list of workspace display names. Each name is owned
        /// (allocated via the Application allocator). The Application
        /// is responsible for freeing them in `deinit`.
        workspace_names: std.ArrayListUnmanaged([:0]const u8) = .empty,

        /// Ordered list of working directories, one per workspace. Each
        /// string is owned (allocated via the Application allocator).
        workspace_dirs: std.ArrayListUnmanaged([:0]const u8) = .empty,

        /// Stable per-workspace IDs. Parallel to workspace_names.
        workspace_ids: std.ArrayListUnmanaged(Uuid) = .empty,

        /// Ordered list of AdwTabView instances, one per workspace. Each
        /// TabView has an Application-owned ref so it survives being
        /// unparented when workspace switching occurs.
        workspace_tab_views: std.ArrayListUnmanaged(*adw.TabView) = .empty,

        /// Per-workspace git branch name. Null if not a git repo.
        /// Parallel to workspace_names.
        workspace_git_branches: std.ArrayListUnmanaged(?[:0]const u8) = .empty,

        /// Per-workspace dirty flag. Parallel to workspace_names.
        workspace_git_dirty: std.ArrayListUnmanaged(bool) = .empty,

        /// Per-workspace staged git change count. Parallel to workspace_names.
        workspace_git_staged_counts: std.ArrayListUnmanaged(u32) = .empty,

        /// Per-workspace unstaged git change count. Parallel to workspace_names.
        workspace_git_unstaged_counts: std.ArrayListUnmanaged(u32) = .empty,

        /// Per-workspace pinned state. Parallel to workspace_names.
        workspace_pinned: std.ArrayListUnmanaged(bool) = .empty,

        /// Index of the currently active workspace (0-based). Only
        /// meaningful when workspace_names is non-empty.
        active_workspace_idx: u32 = 0,

        /// Auto-incrementing counter used to generate default workspace
        /// names ("Workspace 1", "Workspace 2", ...).  Starts at 1;
        /// incremented by addWorkspaceWithDir after each workspace is created.
        next_workspace_number: u32 = 1,

        /// Per-workspace tab counts from session restore, consumed during
        /// initAndShowWindow(). null when no restore is pending.
        restore_tab_counts: ?[]u32 = null,

        /// Per-workspace tab titles from session restore (v3+), consumed
        /// during initAndShowWindow(). Each inner slice contains the titles
        /// for one workspace's tabs. null when no restore is pending.
        restore_tab_titles: ?[][]const [:0]const u8 = null,

        /// Per-workspace full tab snapshots from session restore (v5+),
        /// consumed during initAndShowWindow().
        restore_tab_snapshots: ?[][]const session_mod.TabData = null,

        /// Per-workspace active tab indices from session restore (v4+),
        /// consumed during initAndShowWindow().
        restore_active_tab_indices: ?[]u32 = null,

        /// Per-workspace tab directories from session restore (v4+),
        /// consumed during initAndShowWindow(). Each inner slice contains
        /// per-tab working directories for one workspace.
        restore_tab_dirs: ?[][]const [:0]const u8 = null,

        /// Restored window width from session JSON, applied to new windows.
        restore_window_width: ?c_int = null,

        /// Restored window height from session JSON, applied to new windows.
        restore_window_height: ?c_int = null,

        /// Restored sidebar width from session JSON, applied to new windows.
        restore_sidebar_width: ?c_int = null,

        // ----- Termplex IPC socket state -----

        /// The listening Unix domain socket fd, or null if not yet started.
        socket_fd: ?std.posix.socket_t = null,

        /// Heap-allocated copy of the socket filesystem path (for unlink on
        /// cleanup).  Null when socket_fd is null.
        socket_path_buf: ?[]u8 = null,

        /// GLib source id returned by glib.timeoutAdd for the poll timer.
        /// Null when no timer is active.
        socket_poll_timer: ?c_uint = null,

        // ----- Termplex git state for the active workspace -----

        /// Current branch name (null-terminated, owned). Null if not in a git repo.
        git_branch: ?[:0]const u8 = null,

        /// True when `git status --porcelain` produces non-empty output.
        git_dirty: bool = false,

        /// GLib source id for the debounce timer before the next git probe.
        git_debounce_timer: ?c_uint = null,

        // ----- Termplex autosave state -----

        /// GLib source id for the 5-second recurring autosave timer.
        autosave_timer: ?c_uint = null,

        // ----- Termplex port scanner state -----

        /// GLib source id for the 30-second recurring port scan timer.
        port_scan_timer: ?c_uint = null,

        /// GLib source ids for the burst of 6 extra scans after a pwd change.
        port_scan_burst_timers: [6]?c_uint = .{null} ** 6,

        /// GLib source id for the one-shot initial git probe timer (500ms after startup).
        initial_probe_timer: ?c_uint = null,

        /// Formatted listening-ports string for display (null-terminated, owned).
        listening_ports_str: ?[:0]const u8 = null,

        // ----- Termplex pwd tracking -----

        /// Current working directory of the active workspace (for git probing).
        current_pwd: ?[:0]const u8 = null,

        // ----- Termplex config -----

        /// Loaded Termplex configuration. Populated during Application init
        /// by reading ~/.config/termplex/config.toml; falls back to defaults
        /// when the file does not exist. Must be freed in deinit().
        termplex_cfg: termplex_config.TermplexConfig = termplex_config.TermplexConfig.default(std.heap.c_allocator),

        // ----- Termplex orchestration state -----

        /// Index of the orchestration workspace (null if orchestration disabled).
        orchestration_workspace_idx: ?u32 = null,

        /// Whether the orchestration agent has been launched in this session.
        orchestration_launched: bool = false,

        // ----- Termplex memory state manager -----

        /// Memory state manager for process tracking.
        memory_manager: ?memory_state_mgr.StateManager = null,
        /// SQLite store for terminal history metadata and command records.
        terminal_history_db: ?terminal_history_db.Database = null,
        /// GLib timer ID for debounced state saves (1s interval).
        memory_debounce_timer: ?c_uint = null,
        /// GLib timer ID for periodic proc inspection.
        memory_proc_timer: ?c_uint = null,

        // ----- Termplex agent registry -----

        /// Registry of AI agents that have registered via IPC.
        agent_registry: agents.AgentRegistry,

        /// Ephemeral notifications stored per workspace.
        notifications: notification_mod.NotificationStore,

        // ----- Termplex update state -----

        update_state: update_state_mod.State = .{},
        update_paths: ?memory_paths.UpdatePaths = null,
        update_available_version: ?[:0]u8 = null,
        update_download_path: ?[:0]u8 = null,
        update_last_error: ?[:0]u8 = null,
        update_download_url: ?[]u8 = null,
        update_download_filename: ?[]u8 = null,
        update_download_sha256: ?[32]u8 = null,
        update_notes_url: ?[]u8 = null,

        pub var offset: c_int = 0;
    };

    /// Get this application as the default, allowing access to its
    /// properties globally.
    ///
    /// This asserts that there is a default application and that the
    /// default application is a TermplexApplication. The program would have
    /// to be in a very bad state for this to be violated.
    pub fn default() *Self {
        const app = gio.Application.getDefault().?;
        return gobject.ext.cast(Self, app).?;
    }

    /// Creates a new Application instance.
    ///
    /// This does a lot more work than a typical class instantiation,
    /// because we expect that this is the main program entrypoint.
    ///
    /// The only failure mode of initializing the application is early OOM.
    /// Early OOM can't be recovered from. Every other error is mapped to
    /// some degraded state where we can at least show a window with an error.
    pub fn new(
        rt_app: *ApprtApp,
        core_app: *CoreApp,
    ) Allocator.Error!*Self {
        const alloc = core_app.alloc;

        // Capture GLib/GObject/GTK log messages and funnel them through Zig's
        // logging system rather than just getting dumped directly to stderr.
        _ = glib.logSetWriterFunc(glibLogWriterFunction, null, null);

        // Log our GTK versions
        gtk_version.logVersion();
        adw_version.logVersion();

        // Load our configuration.
        var config = CoreConfig.load(alloc) catch |err| err: {
            // If we fail to load the configuration, then we should log
            // the error in the diagnostics so it can be shown to the user.
            // We can still load a default which only fails for OOM, allowing
            // us to startup.
            var def: CoreConfig = try .default(alloc);
            errdefer def.deinit();
            try def.addDiagnosticFmt(
                "error loading user configuration: {}",
                .{err},
            );

            break :err def;
        };
        defer config.deinit();

        const saved_language: ?[:0]const u8 = saved_language: {
            const old_language = old_language: {
                const result = (internal_os.getenv(alloc, "LANG") catch break :old_language null) orelse break :old_language null;
                defer result.deinit(alloc);
                break :old_language alloc.dupeZ(u8, result.value) catch break :old_language null;
            };

            if (config.language) |language| _ = internal_os.setenv("LANG", language);

            break :saved_language old_language;
        };

        // Set gettext global domain to be our app so that our unqualified
        // translations map to our translations.
        internal_os.i18n.initGlobalDomain() catch |err| {
            // Failures shuldn't stop application startup. Our app may
            // not translate correctly but it should still work. In the
            // future we may want to add this to the GUI to show.
            log.warn("i18n initialization failed error={}", .{err});
        };

        // Setup our GTK init env vars
        setGtkEnv(&config) catch |err| switch (err) {
            error.NoSpaceLeft => {
                // If we fail to set GTK environment variables then we still
                // try to start the application...
                log.warn(
                    "error setting GTK environment variables err={}",
                    .{err},
                );
            },
        };
        adw.init();

        const single_instance = switch (config.@"gtk-single-instance") {
            .true => true,
            .false => false,
            // This should have been resolved to true/false during config loading.
            .detect => unreachable,
        };

        // Setup the flags for our application.
        const app_flags: gio.ApplicationFlags = app_flags: {
            var flags: gio.ApplicationFlags = .flags_default_flags;
            if (!single_instance) flags.non_unique = true;
            break :app_flags flags;
        };

        // Our app ID determines uniqueness and maps to our desktop file.
        // We append "-debug" to the ID if we're in debug mode so that we
        // can develop Termplex in Termplex.
        const app_id: [:0]const u8 = app_id: {
            if (config.class) |class| {
                if (gio.Application.idIsValid(class) != 0) {
                    break :app_id class;
                } else {
                    log.warn("invalid 'class' in config, ignoring", .{});
                }
            }

            break :app_id ApprtApp.application_id;
        };

        const display: *gdk.Display = gdk.Display.getDefault() orelse {
            // I'm unsure of any scenario where this happens. Because we don't
            // want to litter null checks everywhere, we just exit here.
            log.warn("gdk display is null, exiting", .{});
            std.posix.exit(1);
        };

        // Setup our windowing protocol logic
        var wp: winprotopkg.App = winprotopkg.App.init(
            alloc,
            display,
            app_id,
            &config,
        ) catch |err| wp: {
            // If we fail to detect or setup the windowing protocol
            // specifies, we fallback to a noop implementation so we can
            // still launch.
            log.warn("error initializing windowing protocol err={}", .{err});
            break :wp .{ .none = .{} };
        };
        errdefer wp.deinit(alloc);
        log.debug("windowing protocol={s}", .{@tagName(wp)});

        // Create our GTK Application which encapsulates our process.
        log.debug("creating GTK application id={s} single-instance={}", .{
            app_id,
            single_instance,
        });

        // Wrap our configuration in a GObject.
        const config_obj: *Config = try .new(alloc, &config);
        errdefer config_obj.unref();

        // Internally, GTK ensures that only one instance of this provider
        // exists in the provider list for the display.
        const css_provider = gtk.CssProvider.new();
        gtk.StyleContext.addProviderForDisplay(
            display,
            css_provider.as(gtk.StyleProvider),
            gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 3,
        );
        errdefer css_provider.unref();

        // Initialize the app.
        const self = gobject.ext.newInstance(Self, .{
            .application_id = app_id.ptr,
            .flags = app_flags,

            // Force the resource path to a known value so it doesn't depend
            // on the app id (which changes between debug/release and can be
            // user-configured) and force it to load in compiled resources.
            .resource_base_path = "/com/mitchellh/termplex",
        });

        // Setup our private state. More setup is done in the init
        // callback that GObject calls, but we can't pass this data through
        // to there (and we don't need it there directly) so this is here.
        const priv: *Private = self.private();
        priv.* = .{
            .rt_app = rt_app,
            .core_app = core_app,
            .config = config_obj,
            .winproto = wp,
            .css_provider = css_provider,
            .custom_css_providers = .empty,
            .global_shortcuts = gobject.ext.newInstance(GlobalShortcuts, .{}),
            .saved_language = saved_language,
            .agent_registry = agents.AgentRegistry.init(std.heap.c_allocator),
            .notifications = notification_mod.NotificationStore.init(alloc),
        };

        // Termplex: load Termplex config (falls back to defaults on any error).
        priv.termplex_cfg = termplex_config.load(std.heap.c_allocator) catch
            termplex_config.TermplexConfig.default(std.heap.c_allocator);

        // Termplex: load persisted updater state.
        priv.update_paths = memory_paths.resolveUpdatePaths(std.heap.c_allocator) catch |err| paths: {
            log.warn("failed to resolve update paths: {}", .{err});
            break :paths null;
        };
        if (priv.update_paths) |paths| {
            priv.update_state = update_state_mod.load(std.heap.c_allocator, paths.state_json) catch |err| state: {
                log.warn("failed to load update state: {}", .{err});
                break :state .{};
            };
            if (priv.update_state.download_path) |path| {
                replaceCString(&priv.update_download_path, path) catch {};
                replaceCString(
                    &priv.update_available_version,
                    priv.update_state.downloaded_version orelse priv.update_state.last_available_version,
                ) catch {};
            }
        }

        // Termplex: create orchestration workspace first (index 0) if enabled.
        if (priv.termplex_cfg.orchestration.enabled orelse false) {
            const orch_dir_z: ?[:0]u8 = blk: {
                var global_paths = memory_paths.resolveGlobalPaths(std.heap.c_allocator, priv.termplex_cfg.orchestration.dir) catch |err| {
                    log.warn("failed to resolve orchestration directory: {}", .{err});
                    break :blk std.heap.c_allocator.dupeZ(u8, priv.termplex_cfg.orchestration.dir) catch null;
                };
                defer global_paths.deinit(std.heap.c_allocator);

                memory_paths.ensureDir(global_paths.dir) catch |err| {
                    log.warn("failed to create orchestration directory {s}: {}", .{ global_paths.dir, err });
                };

                break :blk std.heap.c_allocator.dupeZ(u8, global_paths.dir) catch null;
            };
            defer if (orch_dir_z) |d| std.heap.c_allocator.free(d);
            const orch_idx = self.addWorkspaceWithDir(orch_dir_z);
            if (orch_idx) |idx| {
                self.renameWorkspace(idx, "Orchestrator");
                priv.orchestration_workspace_idx = idx;
                log.info("created orchestration workspace at index {d}", .{idx});
            }
        }

        // Termplex: initialize memory state manager if memory is enabled.
        if (priv.termplex_cfg.memory.enabled) {
            priv.memory_manager = memory_state_mgr.StateManager.init(
                std.heap.c_allocator,
                priv.termplex_cfg.orchestration.dir,
            );
            // Try to load previous state
            _ = priv.memory_manager.?.loadFromDisk() catch |err| {
                log.warn("failed to load memory state: {}", .{err});
            };

            // Start debounce timer (1 second interval) for state persistence
            priv.memory_debounce_timer = glib.timeoutAdd(1000, memoryDebounceSaveCallback, self);

            // Proc inspection timer deferred to v2 — shell hooks are the
            // primary detection mechanism.  The memory_proc_timer field is
            // retained so the timer can be wired up in a future version
            // without changing the Private struct layout.
        }

        // Termplex: create the default "Workspace 1" (name, dir, and TabView).
        if (self.workspaceCount() == 0) {
            _ = self.addWorkspaceWithDir(null) orelse
                @panic("OOM: cannot create initial workspace");
        }

        // Termplex: start the IPC socket server.
        startIpcSocket(self) catch |err| {
            log.warn("failed to start IPC socket server: {}", .{err});
        };

        // Termplex: restore session from disk (best-effort).
        if (priv.termplex_cfg.session.restore_on_startup) {
            restoreSession(self);
        }

        // Termplex: initialize terminal history metadata after workspace restore
        // so startup-only placeholder workspaces are not recorded as projects.
        self.initTerminalHistoryDatabase();
        self.upsertAllTerminalHistoryProjects();

        // Signals
        _ = gobject.Object.signals.notify.connect(
            self,
            *Self,
            propConfig,
            self,
            .{ .detail = "config" },
        );

        _ = gtk.CssProvider.signals.parsing_error.connect(
            css_provider,
            *Self,
            signalCssParsingError,
            self,
            .{},
        );

        // Trigger initial config changes
        self.as(gobject.Object).notifyByPspec(properties.config.impl.param_spec);

        return self;
    }

    /// Force deinitialize the application.
    ///
    /// Normally in a GObject lifecycle, this would be called by the
    /// finalizer. But applications are never fully unreferenced so this
    /// ensures that our memory is cleaned up properly.
    pub fn deinit(self: *Self) void {
        const alloc = self.allocator();
        const priv: *Private = self.private();

        // Cancel autosave timer and persist one last snapshot before tearing
        // down any workspace state. Remote instances must never write session
        // state because they don't own the primary app lifecycle.
        if (priv.autosave_timer) |source| {
            _ = glib.Source.remove(source);
            priv.autosave_timer = null;
        }
        if (self.as(gio.Application).getIsRemote() == 0) {
            autosaveSession(self);
        } else {
            log.debug("skipping final autosave for remote GTK instance", .{});
        }

        // Termplex: free workspace names.
        for (priv.workspace_names.items) |name| {
            alloc.free(name);
        }
        priv.workspace_names.deinit(alloc);

        // Termplex: free workspace dirs.
        for (priv.workspace_dirs.items) |dir_str| {
            alloc.free(dir_str);
        }
        priv.workspace_dirs.deinit(alloc);

        // Termplex: free workspace IDs.
        priv.workspace_ids.deinit(alloc);

        // Termplex: release Application-owned refs on workspace TabViews.
        for (priv.workspace_tab_views.items) |tv| {
            tv.as(gobject.Object).unref();
        }
        priv.workspace_tab_views.deinit(alloc);

        // Termplex: free per-workspace git state.
        for (priv.workspace_git_branches.items) |branch_opt| {
            if (branch_opt) |b| alloc.free(b);
        }
        priv.workspace_git_branches.deinit(alloc);
        priv.workspace_git_dirty.deinit(alloc);
        priv.workspace_git_staged_counts.deinit(alloc);
        priv.workspace_git_unstaged_counts.deinit(alloc);
        priv.workspace_pinned.deinit(alloc);

        // Termplex: free any unconsumed restore tab counts.
        if (priv.restore_tab_counts) |counts| {
            alloc.free(counts);
            priv.restore_tab_counts = null;
        }

        // Termplex: free any unconsumed restore tab titles.
        if (priv.restore_tab_titles) |titles_per_ws| {
            for (titles_per_ws) |titles| {
                for (titles) |t| alloc.free(t);
                if (titles.len > 0) alloc.free(titles);
            }
            alloc.free(titles_per_ws);
            priv.restore_tab_titles = null;
        }

        if (priv.restore_tab_snapshots) |snapshots_per_ws| {
            for (snapshots_per_ws) |snapshots| {
                for (snapshots) |snapshot| {
                    var owned_snapshot = snapshot;
                    owned_snapshot.deinit(alloc);
                }
                if (snapshots.len > 0) alloc.free(snapshots);
            }
            alloc.free(snapshots_per_ws);
            priv.restore_tab_snapshots = null;
        }

        // Termplex: free any unconsumed restore active tab indices.
        if (priv.restore_active_tab_indices) |indices| {
            alloc.free(indices);
            priv.restore_active_tab_indices = null;
        }

        // Termplex: free any unconsumed restore tab directories.
        if (priv.restore_tab_dirs) |dirs_per_ws| {
            for (dirs_per_ws) |dirs| {
                for (dirs) |dir| alloc.free(dir);
                if (dirs.len > 0) alloc.free(dirs);
            }
            alloc.free(dirs_per_ws);
            priv.restore_tab_dirs = null;
        }

        // Termplex: shut down the IPC socket server.
        if (priv.socket_poll_timer) |source| {
            if (glib.Source.remove(source) == 0) {
                log.warn("unable to remove IPC socket poll timer source={d}", .{source});
            }
            priv.socket_poll_timer = null;
        }
        if (priv.socket_fd) |fd| {
            std.posix.close(fd);
            priv.socket_fd = null;
        }
        if (priv.socket_path_buf) |path| {
            std.posix.unlink(path) catch {};
            alloc.free(path);
            priv.socket_path_buf = null;
        }

        // Termplex: free update state.
        priv.update_state.deinit(std.heap.c_allocator);
        if (priv.update_paths) |*paths| {
            paths.deinit(std.heap.c_allocator);
            priv.update_paths = null;
        }
        if (priv.update_available_version) |value| {
            std.heap.c_allocator.free(value);
            priv.update_available_version = null;
        }
        if (priv.update_download_path) |value| {
            std.heap.c_allocator.free(value);
            priv.update_download_path = null;
        }
        if (priv.update_last_error) |value| {
            std.heap.c_allocator.free(value);
            priv.update_last_error = null;
        }
        if (priv.update_download_url) |value| {
            std.heap.c_allocator.free(value);
            priv.update_download_url = null;
        }
        if (priv.update_download_filename) |value| {
            std.heap.c_allocator.free(value);
            priv.update_download_filename = null;
        }
        if (priv.update_notes_url) |value| {
            std.heap.c_allocator.free(value);
            priv.update_notes_url = null;
        }
        priv.update_download_sha256 = null;

        // Termplex: cancel git debounce timer.
        if (priv.git_debounce_timer) |source| {
            _ = glib.Source.remove(source);
            priv.git_debounce_timer = null;
        }

        // Termplex: cancel port scan timer.
        if (priv.port_scan_timer) |source| {
            _ = glib.Source.remove(source);
            priv.port_scan_timer = null;
        }

        // Termplex: cancel all burst scan timers.
        for (&priv.port_scan_burst_timers) |*slot| {
            if (slot.*) |source| {
                _ = glib.Source.remove(source);
                slot.* = null;
            }
        }

        // Termplex: cancel initial probe timer if it hasn't fired yet.
        if (priv.initial_probe_timer) |source| {
            _ = glib.Source.remove(source);
            priv.initial_probe_timer = null;
        }

        // Termplex: free git/port/pwd strings.
        if (priv.git_branch) |b| {
            alloc.free(b);
            priv.git_branch = null;
        }
        if (priv.listening_ports_str) |s| {
            alloc.free(s);
            priv.listening_ports_str = null;
        }
        if (priv.current_pwd) |p| {
            alloc.free(p);
            priv.current_pwd = null;
        }

        // Termplex: cancel memory debounce timer.
        if (priv.memory_debounce_timer) |source| {
            _ = glib.Source.remove(source);
            priv.memory_debounce_timer = null;
        }

        // Termplex: cancel memory proc inspection timer.
        if (priv.memory_proc_timer) |source| {
            _ = glib.Source.remove(source);
            priv.memory_proc_timer = null;
        }

        // Termplex: persist memory state on shutdown.
        if (priv.memory_manager) |*mgr| {
            // Pre-shutdown memory flush: write a prompt file so the
            // orchestrator can save durable knowledge before exiting.
            if (priv.termplex_cfg.memory.flush_on_shutdown) {
                const flush_prompt = "Session ending. Review what happened this session and write any durable knowledge to memory files. If nothing new was learned, do nothing.";
                var global_paths = memory_paths.resolveGlobalPaths(alloc, priv.termplex_cfg.orchestration.dir) catch null;
                defer if (global_paths) |*gp| gp.deinit(alloc);
                if (global_paths) |gp| {
                    memory_paths.ensureDir(gp.dir) catch {};
                    const flush_path = std.fmt.allocPrint(alloc, "{s}/flush_prompt.txt", .{gp.dir}) catch null;
                    defer if (flush_path) |p| alloc.free(p);
                    if (flush_path) |path| {
                        if (std.fs.createFileAbsolute(path, .{}) catch null) |file| {
                            defer file.close();
                            file.writeAll(flush_prompt) catch {};
                        }
                    }
                }
            }

            mgr.markShutdown();

            // Save per-workspace state.json files.
            if (mgr.getState()) |s| {
                for (s.workspace_names) |ws_name| {
                    mgr.saveWorkspaceState(ws_name) catch |err| {
                        log.warn("failed to save workspace state for {s}: {}", .{ ws_name, err });
                    };
                }
            }

            // Save global state.json.
            mgr.saveToDisk() catch |err| {
                log.warn("failed to save memory state on shutdown: {}", .{err});
            };
            mgr.deinit();
            priv.memory_manager = null;
        }

        // Termplex: close the terminal history metadata database.
        if (priv.terminal_history_db) |*db| {
            db.deinit();
            priv.terminal_history_db = null;
        }

        // Termplex: free the loaded Termplex config.
        priv.termplex_cfg.deinit();

        // Termplex: free the agent registry.
        priv.agent_registry.deinit();

        // Termplex: free ephemeral notifications.
        priv.notifications.deinit();

        priv.config.unref();
        priv.winproto.deinit(alloc);
        priv.global_shortcuts.unref();
        if (priv.saved_language) |language| alloc.free(language);
        if (gdk.Display.getDefault()) |display| {
            gtk.StyleContext.removeProviderForDisplay(
                display,
                priv.css_provider.as(gtk.StyleProvider),
            );

            for (priv.custom_css_providers.items) |provider| {
                gtk.StyleContext.removeProviderForDisplay(
                    display,
                    provider.as(gtk.StyleProvider),
                );
            }
        }
        priv.css_provider.unref();
        for (priv.custom_css_providers.items) |provider| provider.unref();
        priv.custom_css_providers.deinit(alloc);
    }

    /// The global allocator that all other classes should use by
    /// calling `Application.default().allocator()`. Zig code should prefer
    /// this wherever possible so we get leak detection in debug/tests.
    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.private().core_app.alloc;
    }

    /// Get the original language that Termplex was launched with. This returns a
    /// pointer to internal memory so it must be copied by callers.
    pub fn savedLanguage(self: *Self) ?[:0]const u8 {
        return self.private().saved_language;
    }

    // -----------------------------------------------------------------
    // Termplex workspace helpers
    // -----------------------------------------------------------------

    /// Return the number of workspaces.
    pub fn workspaceCount(self: *Self) u32 {
        return @intCast(self.private().workspace_names.items.len);
    }

    /// Return the index of the currently active workspace.
    pub fn activeWorkspaceIndex(self: *Self) u32 {
        return self.private().active_workspace_idx;
    }

    /// Return the initial sidebar width for newly created windows.
    /// Session restore overrides the configured width.
    pub fn initialSidebarWidth(self: *Self) c_int {
        const priv = self.private();
        if (priv.restore_sidebar_width) |width| {
            return if (width > 10) width else 180;
        }

        const configured: c_int = @intCast(priv.termplex_cfg.sidebar_width);
        return if (configured > 10) configured else 180;
    }

    pub fn sidebarPosition(self: *Self) termplex_config.SidebarPosition {
        return self.private().termplex_cfg.sidebar_position;
    }

    /// Return the index of the orchestration workspace, or null if orchestration
    /// is disabled or the workspace has not been created yet.
    pub fn orchestrationWorkspaceIndex(self: *Self) ?u32 {
        return self.private().orchestration_workspace_idx;
    }

    /// Set the active workspace index. Caller is responsible for keeping
    /// the sidebar in sync after calling this.
    pub fn setActiveWorkspaceIndex(self: *Self, index: u32) void {
        const priv = self.private();
        if (index < priv.workspace_names.items.len) {
            priv.active_workspace_idx = index;
        }
    }

    fn workspaceUuid(self: *Self, index: u32) ?Uuid {
        const priv = self.private();
        if (index >= priv.workspace_ids.items.len) return null;
        return priv.workspace_ids.items[index];
    }

    pub fn workspaceIdString(self: *Self, alloc: std.mem.Allocator, index: u32) ![]u8 {
        const workspace_id = self.workspaceUuid(index) orelse return error.NotFound;
        var buf: [36]u8 = undefined;
        uuid.format(workspace_id, &buf);
        return alloc.dupe(u8, buf[0..]);
    }

    pub fn currentWorkspaceIdString(self: *Self, alloc: std.mem.Allocator) ![]u8 {
        return self.workspaceIdString(alloc, self.private().active_workspace_idx);
    }

    fn initTerminalHistoryDatabase(self: *Self) void {
        const alloc = std.heap.c_allocator;
        const priv = self.private();
        if (!priv.termplex_cfg.terminal_history.enabled) return;
        if (priv.terminal_history_db != null) return;

        const options = self.terminalHistoryOptions();
        terminal_history.cleanupRetention(alloc, options) catch |err| {
            log.warn("terminal history retention cleanup failed: {}", .{err});
        };

        const db_path = terminal_history.databasePath(alloc) catch |err| {
            log.warn("failed to resolve terminal history database path: {}", .{err});
            return;
        };
        defer alloc.free(db_path);

        priv.terminal_history_db = terminal_history_db.Database.open(alloc, db_path) catch |err| {
            log.warn("failed to open terminal history database: {}", .{err});
            return;
        };

        if (priv.terminal_history_db) |*db| {
            db.migrate() catch |err| {
                log.warn("failed to migrate terminal history database: {}", .{err});
                db.deinit();
                priv.terminal_history_db = null;
                return;
            };

            if (options.retention_days > 0) {
                if (terminal_history.retentionCutoffIso(alloc, options.retention_days)) |cutoff| {
                    defer alloc.free(cutoff);
                    db.pruneCommandsOlderThan(cutoff) catch |err| {
                        log.warn("failed to prune terminal command history: {}", .{err});
                    };
                } else |err| {
                    log.warn("failed to compute terminal history retention cutoff: {}", .{err});
                }
            }

            self.refreshTerminalHistoryDatabaseLink();
        }
    }

    fn refreshTerminalHistoryDatabaseLink(self: *Self) void {
        const priv = self.private();
        if (priv.memory_manager) |*mgr| {
            if (priv.terminal_history_db) |*db| {
                mgr.setCommandHistoryDatabase(db);
            } else {
                mgr.setCommandHistoryDatabase(null);
            }
        }
    }

    fn reopenTerminalHistoryDatabase(self: *Self) void {
        const priv = self.private();
        if (priv.terminal_history_db) |*db| {
            db.deinit();
            priv.terminal_history_db = null;
        }
        if (priv.memory_manager) |*mgr| {
            mgr.setCommandHistoryDatabase(null);
        }
        self.initTerminalHistoryDatabase();
    }

    fn terminalHistoryTimestamp(self: *Self, alloc: std.mem.Allocator) ?[]const u8 {
        _ = self;
        return terminal_history.retentionCutoffIso(alloc, 0) catch |err| {
            log.warn("failed to compute terminal history timestamp: {}", .{err});
            return null;
        };
    }

    fn upsertTerminalHistoryProject(self: *Self, index: u32) void {
        const alloc = self.allocator();
        const priv = self.private();
        var db = if (priv.terminal_history_db) |*database| database else return;
        if (index >= priv.workspace_names.items.len or
            index >= priv.workspace_dirs.items.len or
            index >= priv.workspace_ids.items.len) return;

        const workspace_id = self.workspaceIdString(alloc, index) catch |err| {
            log.warn("failed to format workspace id for terminal history: {}", .{err});
            return;
        };
        defer alloc.free(workspace_id);

        const timestamp = self.terminalHistoryTimestamp(alloc) orelse return;
        defer alloc.free(timestamp);

        const git_branch: ?[]const u8 = if (index < priv.workspace_git_branches.items.len)
            priv.workspace_git_branches.items[index]
        else
            null;
        const git_dirty = if (index < priv.workspace_git_dirty.items.len)
            priv.workspace_git_dirty.items[index]
        else
            false;

        db.upsertProject(.{
            .workspace_id = workspace_id,
            .workspace_name = priv.workspace_names.items[index],
            .workspace_dir = priv.workspace_dirs.items[index],
            .git_remote_url = null,
            .git_branch = git_branch,
            .git_dirty = git_dirty,
            .timestamp = timestamp,
        }) catch |err| {
            log.warn("failed to upsert terminal history project: {}", .{err});
        };
    }

    fn upsertAllTerminalHistoryProjects(self: *Self) void {
        const priv = self.private();
        if (priv.terminal_history_db == null) return;
        for (priv.workspace_names.items, 0..) |_, index| {
            self.upsertTerminalHistoryProject(@intCast(index));
        }
    }

    fn deleteTerminalHistoryProject(self: *Self, index: u32) void {
        const alloc = self.allocator();
        const priv = self.private();
        if (index >= priv.workspace_ids.items.len) return;

        const workspace_id = self.workspaceIdString(alloc, index) catch |err| {
            log.warn("failed to format workspace id for terminal history deletion: {}", .{err});
            return;
        };
        defer alloc.free(workspace_id);

        self.deleteTerminalHistoryProjectById(workspace_id);
    }

    fn deleteTerminalHistoryProjectById(self: *Self, workspace_id: []const u8) void {
        const alloc = self.allocator();
        const priv = self.private();

        terminal_history.clearWorkspaceHistory(alloc, workspace_id) catch |err| {
            log.warn("failed to clear terminal transcript history for workspace: {}", .{err});
        };

        if (priv.terminal_history_db) |*db| {
            const timestamp = self.terminalHistoryTimestamp(alloc) orelse return;
            defer alloc.free(timestamp);
            db.deleteProject(workspace_id, timestamp) catch |err| {
                log.warn("failed to delete terminal history project: {}", .{err});
            };
            db.commitIfNeeded() catch |err| {
                log.warn("failed to commit terminal history project deletion: {}", .{err});
            };
            self.reopenTerminalHistoryDatabase();
        }

        const db_path = terminal_history.databasePath(alloc) catch |err| {
            log.warn("failed to resolve terminal history database path for deletion: {}", .{err});
            return;
        };
        defer alloc.free(db_path);

        var db = terminal_history_db.Database.open(alloc, db_path) catch |err| {
            log.warn("failed to open terminal history database for deletion: {}", .{err});
            return;
        };
        defer db.deinit();

        db.migrate() catch |err| {
            log.warn("failed to migrate terminal history database for deletion: {}", .{err});
            return;
        };

        const timestamp = self.terminalHistoryTimestamp(alloc) orelse return;
        defer alloc.free(timestamp);
        db.deleteProject(workspace_id, timestamp) catch |err| {
            log.warn("failed to delete terminal history project from fallback database: {}", .{err});
            return;
        };
        self.refreshTerminalHistoryDatabaseLink();
    }

    const DeferredProjectHistoryDelete = struct {
        app: *Self,
        workspace_id: []u8,
        attempts_left: u8,
    };

    fn scheduleTerminalHistoryProjectDelete(self: *Self, workspace_id: []const u8) void {
        const alloc = std.heap.c_allocator;
        const ctx = alloc.create(DeferredProjectHistoryDelete) catch return;
        ctx.* = .{
            .app = self,
            .workspace_id = alloc.dupe(u8, workspace_id) catch {
                alloc.destroy(ctx);
                return;
            },
            .attempts_left = 20,
        };
        _ = glib.timeoutAdd(500, deferredTerminalHistoryProjectDelete, ctx);
    }

    fn deferredTerminalHistoryProjectDelete(ud: ?*anyopaque) callconv(.c) c_int {
        const ctx: *DeferredProjectHistoryDelete = @ptrCast(@alignCast(ud orelse return @intFromBool(glib.SOURCE_REMOVE)));
        ctx.app.deleteTerminalHistoryProjectById(ctx.workspace_id);

        if (ctx.attempts_left > 1) {
            ctx.attempts_left -= 1;
            return @intFromBool(glib.SOURCE_CONTINUE);
        }

        {
            std.heap.c_allocator.free(ctx.workspace_id);
            std.heap.c_allocator.destroy(ctx);
        }
        return @intFromBool(glib.SOURCE_REMOVE);
    }

    pub fn terminalHistoryOptions(self: *Self) terminal_history.Options {
        const cfg = self.private().termplex_cfg.terminal_history;
        return .{
            .enabled = cfg.enabled,
            .restore_mode = if (std.mem.eql(u8, cfg.restore_mode, "off"))
                .off
            else if (std.mem.eql(u8, cfg.restore_mode, "layout_only"))
                .layout_only
            else
                .transcript,
            .max_lines_per_surface = cfg.max_lines_per_surface,
            .max_bytes_per_surface = @intCast(cfg.max_bytes_per_surface),
            .persist_alternate_screen = cfg.persist_alternate_screen,
            .replay_notice = cfg.replay_notice,
            .retention_days = cfg.retention_days,
        };
    }

    pub fn storageSummaryText(self: *Self, alloc: std.mem.Allocator) ![]u8 {
        var usage = try self.storageDiskUsage(alloc);
        defer usage.deinit(alloc);
        const counts = self.storageRowCounts();

        const total = try storage_status.formatBytes(alloc, usage.total_bytes);
        defer alloc.free(total);
        const transcripts = try storage_status.formatBytes(alloc, usage.transcript_bytes);
        defer alloc.free(transcripts);
        const db_size = try storage_status.formatBytes(alloc, usage.db_bytes);
        defer alloc.free(db_size);

        return std.fmt.allocPrint(
            alloc,
            "Total: {s}\nTranscripts: {s} ({d} files)\nSQLite: {s}\nProjects: {d}  Surfaces: {d}  Commands: {d}  Tasks: {d}\nBase: {s}\nDatabase: {s}",
            .{
                total,
                transcripts,
                usage.transcript_file_count,
                db_size,
                counts.project_count,
                counts.surface_count,
                counts.command_count,
                counts.task_count,
                usage.base_path,
                usage.db_path,
            },
        );
    }

    pub fn storageSettingsText(self: *Self, alloc: std.mem.Allocator) ![]u8 {
        const cfg = self.private().termplex_cfg.terminal_history;
        return std.fmt.allocPrint(
            alloc,
            "History: {s}\nRestore mode: {s}\nRetention: {d} days\nMax lines per terminal: {d}\nMax bytes per terminal: {d}\nAlternate screen: {s}\nReplay notice: {s}\n\nTermplex stores terminal transcripts and command metadata locally under XDG state. These controls only affect local files and SQLite rows.",
            .{
                if (cfg.enabled) "enabled" else "disabled",
                cfg.restore_mode,
                cfg.retention_days,
                cfg.max_lines_per_surface,
                cfg.max_bytes_per_surface,
                if (cfg.persist_alternate_screen) "stored" else "not stored",
                if (cfg.replay_notice) "shown" else "hidden",
            },
        );
    }

    fn storageDiskUsage(self: *Self, alloc: std.mem.Allocator) !storage_status.DiskUsage {
        _ = self;
        const base = try terminal_history.getBaseDir(alloc);
        defer alloc.free(base);
        const db_path = try terminal_history.databasePath(alloc);
        defer alloc.free(db_path);
        return try storage_status.scanBasePath(alloc, base, db_path);
    }

    fn storageRowCounts(self: *Self) terminal_history_db.RowCounts {
        const priv = self.private();
        if (priv.terminal_history_db) |*db| {
            return db.rowCounts() catch |err| {
                log.warn("failed to count terminal history rows: {}", .{err});
                return .{ .project_count = 0, .surface_count = 0, .command_count = 0, .task_count = 0 };
            };
        }
        return .{ .project_count = 0, .surface_count = 0, .command_count = 0, .task_count = 0 };
    }

    pub const DashboardWorkspace = struct {
        index: u32,
        id: []u8,
        name: []u8,
        dir: []u8,
        current_pwd: []u8,
        tab_count: u32,
        active_tab: ?u32,
        active_history_id: ?[]u8,

        pub fn deinit(self: DashboardWorkspace, alloc: std.mem.Allocator) void {
            alloc.free(self.id);
            alloc.free(self.name);
            alloc.free(self.dir);
            alloc.free(self.current_pwd);
            if (self.active_history_id) |value| alloc.free(value);
        }
    };

    pub const DashboardStorage = struct {
        history_enabled: bool,
        restore_mode: []u8,
        total_bytes: u64,
        transcript_bytes: u64,
        db_bytes: u64,
        transcript_file_count: u64,
        project_count: u64,
        surface_count: u64,
        command_count: u64,
        task_count: u64,

        pub fn deinit(self: DashboardStorage, alloc: std.mem.Allocator) void {
            alloc.free(self.restore_mode);
        }
    };

    pub const DashboardGit = struct {
        status: git_status.Status,
        staged_count: u64,
        unstaged_count: u64,

        pub fn deinit(self: DashboardGit, alloc: std.mem.Allocator) void {
            var status = self.status;
            status.deinit(alloc);
        }
    };

    pub const DashboardStatus = struct {
        workspace: DashboardWorkspace,
        recent_commands: terminal_history_db.CommandList,
        tasks: terminal_history_db.TaskList,
        git: DashboardGit,
        storage: DashboardStorage,

        pub fn deinit(self: DashboardStatus, alloc: std.mem.Allocator) void {
            self.workspace.deinit(alloc);
            self.recent_commands.deinit(std.heap.c_allocator);
            self.tasks.deinit(std.heap.c_allocator);
            self.git.deinit(alloc);
            self.storage.deinit(alloc);
        }
    };

    fn dashboardWorkspace(self: *Self, alloc: std.mem.Allocator, workspace_idx: u32) !DashboardWorkspace {
        const priv = self.private();
        const id = try self.workspaceIdString(alloc, workspace_idx);
        errdefer alloc.free(id);

        const workspace_usize: usize = @intCast(workspace_idx);
        if (workspace_usize >= priv.workspace_names.items.len or
            workspace_usize >= priv.workspace_dirs.items.len)
        {
            return error.NotFound;
        }

        const name = try alloc.dupe(u8, priv.workspace_names.items[workspace_usize]);
        errdefer alloc.free(name);

        const dir_value = self.workspaceDir(workspace_idx) orelse return error.NotFound;
        const dir = try alloc.dupe(u8, dir_value);
        errdefer alloc.free(dir);

        const current_pwd_value = if (workspace_idx == priv.active_workspace_idx)
            (priv.current_pwd orelse dir_value)
        else
            dir_value;
        const current_pwd = try alloc.dupe(u8, current_pwd_value);
        errdefer alloc.free(current_pwd);

        const tab_view = self.workspaceTabView(workspace_idx);
        const tab_count: u32 = if (tab_view) |view| @intCast(@max(view.getNPages(), 0)) else 0;
        const active_tab = self.activeTabIndexForWorkspace(workspace_idx);

        var active_history_id: ?[]u8 = null;
        errdefer if (active_history_id) |value| alloc.free(value);
        if (workspace_idx == priv.active_workspace_idx) {
            if (self.as(gtk.Application).getActiveWindow()) |active_win| {
                if (gobject.ext.cast(Window, active_win)) |win| {
                    if (win.getActiveSurface()) |surface| {
                        if (surface.getHistoryId()) |history_id| {
                            active_history_id = try alloc.dupe(u8, history_id);
                        }
                    }
                }
            }
        }

        return .{
            .index = workspace_idx,
            .id = id,
            .name = name,
            .dir = dir,
            .current_pwd = current_pwd,
            .tab_count = tab_count,
            .active_tab = active_tab,
            .active_history_id = active_history_id,
        };
    }

    fn dashboardStorage(self: *Self, alloc: std.mem.Allocator) !DashboardStorage {
        const cfg = self.private().termplex_cfg.terminal_history;
        var usage = try self.storageDiskUsage(alloc);
        defer usage.deinit(alloc);
        const counts = self.storageRowCounts();
        return .{
            .history_enabled = cfg.enabled,
            .restore_mode = try alloc.dupe(u8, cfg.restore_mode),
            .total_bytes = usage.total_bytes,
            .transcript_bytes = usage.transcript_bytes,
            .db_bytes = usage.db_bytes,
            .transcript_file_count = usage.transcript_file_count,
            .project_count = counts.project_count,
            .surface_count = counts.surface_count,
            .command_count = counts.command_count,
            .task_count = counts.task_count,
        };
    }

    fn dashboardGit(self: *Self, alloc: std.mem.Allocator, workspace_idx: u32) !DashboardGit {
        const dir = self.workspaceDir(workspace_idx) orelse ".";
        var status = try git_status.query(alloc, dir);
        errdefer status.deinit(alloc);
        self.syncGitStatusToWorkspace(workspace_idx, &status);
        return .{
            .status = status,
            .staged_count = @intCast(status.staged.len),
            .unstaged_count = @intCast(status.unstaged.len),
        };
    }

    pub fn workspaceDashboardStatus(
        self: *Self,
        alloc: std.mem.Allocator,
        workspace_idx: u32,
        limit: u32,
    ) !DashboardStatus {
        var workspace = try self.dashboardWorkspace(alloc, workspace_idx);
        errdefer workspace.deinit(alloc);

        const recent_limit = @min(@max(limit, 1), 25);
        var recent_commands = try self.searchTerminalCommands(.{
            .workspace_id = workspace.id,
            .limit = recent_limit,
        });
        errdefer recent_commands.deinit(std.heap.c_allocator);

        const db = if (self.private().terminal_history_db) |*database| database else return error.HistoryUnavailable;
        const tasks = try db.listTasks(workspace.id, 25);
        errdefer tasks.deinit(std.heap.c_allocator);

        var git = try self.dashboardGit(alloc, workspace_idx);
        errdefer git.deinit(alloc);

        var storage = try self.dashboardStorage(alloc);
        errdefer storage.deinit(alloc);

        return .{
            .workspace = workspace,
            .recent_commands = recent_commands,
            .tasks = tasks,
            .git = git,
            .storage = storage,
        };
    }

    pub fn activeWorkspaceDashboardStatus(
        self: *Self,
        alloc: std.mem.Allocator,
        limit: u32,
    ) !DashboardStatus {
        return self.workspaceDashboardStatus(alloc, self.private().active_workspace_idx, limit);
    }

    fn clearTerminalHistoryForParams(self: *Self, alloc: std.mem.Allocator, params: std.json.ObjectMap) !void {
        const workspace_idx = self.resolveWorkspaceIdx(params) orelse self.private().active_workspace_idx;
        const tab_view = self.workspaceTabView(workspace_idx) orelse return error.NotFound;
        const tab_idx: c_int = blk: {
            const value = params.get("tab") orelse {
                if (self.activeTabIndexForWorkspace(workspace_idx)) |idx| break :blk @intCast(idx);
                break :blk 0;
            };
            break :blk switch (value) {
                .integer => |n| if (n >= 0 and n < tab_view.getNPages()) @intCast(n) else return error.NotFound,
                else => return error.InvalidParams,
            };
        };

        if (tab_idx < 0 or tab_idx >= tab_view.getNPages()) return error.NotFound;
        const page = tab_view.getNthPage(tab_idx);
        const tab_widget = gobject.ext.cast(Tab, page.getChild()) orelse return error.NotFound;
        const surface = tab_widget.getActiveSurface() orelse return error.NotFound;
        const history_id = surface.getHistoryId() orelse return error.NotFound;

        const workspace_id = try self.workspaceIdString(alloc, workspace_idx);
        defer alloc.free(workspace_id);
        try terminal_history.clearSurfaceHistory(alloc, workspace_id, history_id);

        if (self.private().terminal_history_db) |*db| {
            try db.deleteSurface(history_id);
        }
        self.refreshTerminalHistoryDatabaseLink();
    }

    pub fn clearActiveTerminalStorage(self: *Self) !void {
        var params = std.json.ObjectMap.init(std.heap.c_allocator);
        defer params.deinit();
        try self.clearTerminalHistoryForParams(std.heap.c_allocator, params);
    }

    fn clearWorkspaceHistoryForIndex(self: *Self, alloc: std.mem.Allocator, workspace_idx: u32) !void {
        const workspace_id = try self.workspaceIdString(alloc, workspace_idx);
        defer alloc.free(workspace_id);
        try terminal_history.clearWorkspaceHistory(alloc, workspace_id);

        if (self.private().terminal_history_db) |*db| {
            const timestamp = self.terminalHistoryTimestamp(alloc) orelse return error.TimestampUnavailable;
            defer alloc.free(timestamp);
            try db.deleteProject(workspace_id, timestamp);
            db.commitIfNeeded() catch |err| {
                log.warn("failed to commit workspace history clear: {}", .{err});
            };
        }

        self.reopenTerminalHistoryDatabase();
        self.upsertTerminalHistoryProject(workspace_idx);
        self.refreshTerminalHistoryDatabaseLink();
    }

    pub fn clearActiveWorkspaceStorage(self: *Self) !void {
        try self.clearWorkspaceHistoryForIndex(std.heap.c_allocator, self.private().active_workspace_idx);
    }

    pub fn deleteActiveProjectStorage(self: *Self) !void {
        const idx = self.private().active_workspace_idx;
        if (self.private().workspace_names.items.len <= 1) return error.InvalidOperation;
        const workspace_id = try self.workspaceIdString(self.allocator(), idx);
        defer self.allocator().free(workspace_id);
        if (self.as(gtk.Application).getActiveWindow()) |active_win| {
            if (gobject.ext.cast(Window, active_win)) |win| {
                win.closeWorkspace(idx);
                self.scheduleTerminalHistoryProjectDelete(workspace_id);
                return;
            }
        }
        self.removeWorkspaceFromAllWindows(idx);
        self.removeWorkspace(idx);
        self.refreshAllWorkspaceSidebars();
        self.syncActiveWorkspaceHeaders();
        self.scheduleTerminalHistoryProjectDelete(workspace_id);
    }

    pub fn searchTerminalCommands(self: *Self, query: terminal_history_db.SearchQuery) !terminal_history_db.CommandList {
        const priv = self.private();
        var db = if (priv.terminal_history_db) |*database| database else return error.HistoryUnavailable;

        const alloc = std.heap.c_allocator;
        var workspace_id: ?[]u8 = null;
        defer if (workspace_id) |value| alloc.free(value);

        var scoped_query = query;
        if (scoped_query.workspace_id == null and
            scoped_query.workspace_name == null and
            scoped_query.workspace_dir == null)
        {
            workspace_id = self.currentWorkspaceIdString(alloc) catch null;
            scoped_query.workspace_id = workspace_id;
        }

        return try db.searchCommands(scoped_query);
    }

    pub const TerminalTranscript = struct {
        surface: terminal_history_db.SurfaceRecord,
        output: []u8,
        commands: terminal_history_db.CommandList,

        pub fn deinit(self: TerminalTranscript) void {
            const alloc = std.heap.c_allocator;
            var surface = self.surface;
            surface.deinit(alloc);
            alloc.free(self.output);
            self.commands.deinit(alloc);
        }
    };

    pub fn readTerminalTranscript(self: *Self, history_id: []const u8, lines: u32) !TerminalTranscript {
        const alloc = std.heap.c_allocator;
        var surface = try self.transcriptSurfaceForHistoryId(history_id);
        errdefer surface.deinit(alloc);

        const plain_text = try self.readSanitizedTranscriptForSurface(alloc, surface);
        defer alloc.free(plain_text);
        const visible_text = transcript_view.extractLastLines(plain_text, lines);
        const output = try alloc.dupe(u8, visible_text);
        errdefer alloc.free(output);

        const priv = self.private();
        var db = if (priv.terminal_history_db) |*database| database else return error.HistoryUnavailable;
        const commands = try db.listSurfaceCommands(surface.history_id, 200);

        return .{
            .surface = surface,
            .output = output,
            .commands = commands,
        };
    }

    pub fn searchTerminalTranscript(
        self: *Self,
        history_id: []const u8,
        query: []const u8,
        limit: u32,
    ) !transcript_view.SearchResults {
        const alloc = std.heap.c_allocator;
        var surface = try self.transcriptSurfaceForHistoryId(history_id);
        defer surface.deinit(alloc);
        const plain_text = try self.readSanitizedTranscriptForSurface(alloc, surface);
        defer alloc.free(plain_text);
        return try transcript_view.searchLines(alloc, plain_text, query, limit);
    }

    pub fn queryActiveGitStatus(self: *Self) !git_status.Status {
        const alloc = std.heap.c_allocator;
        const priv = self.private();
        const dir = priv.current_pwd orelse self.workspaceDir(priv.active_workspace_idx) orelse ".";
        var status = try git_status.query(alloc, dir);
        errdefer status.deinit(alloc);
        self.syncGitStatusToWorkspace(priv.active_workspace_idx, &status);
        return status;
    }

    pub fn diffActiveGitFile(self: *Self, path: []const u8, staged: bool) !git_status.DiffResult {
        const priv = self.private();
        const dir = priv.current_pwd orelse self.workspaceDir(priv.active_workspace_idx) orelse ".";
        return try git_status.diff(std.heap.c_allocator, dir, path, staged);
    }

    pub fn stageActiveGitFile(self: *Self, path: []const u8) !git_status.Status {
        const alloc = std.heap.c_allocator;
        const priv = self.private();
        const dir = priv.current_pwd orelse self.workspaceDir(priv.active_workspace_idx) orelse ".";
        var status = try git_status.stage(alloc, dir, path);
        errdefer status.deinit(alloc);
        self.syncGitStatusToWorkspace(priv.active_workspace_idx, &status);
        return status;
    }

    pub fn stageAllActiveGitFiles(self: *Self) !git_status.Status {
        const alloc = std.heap.c_allocator;
        const priv = self.private();
        const dir = priv.current_pwd orelse self.workspaceDir(priv.active_workspace_idx) orelse ".";
        var status = try git_status.stageAll(alloc, dir);
        errdefer status.deinit(alloc);
        self.syncGitStatusToWorkspace(priv.active_workspace_idx, &status);
        return status;
    }

    pub fn unstageActiveGitFile(self: *Self, path: []const u8) !git_status.Status {
        const alloc = std.heap.c_allocator;
        const priv = self.private();
        const dir = priv.current_pwd orelse self.workspaceDir(priv.active_workspace_idx) orelse ".";
        var status = try git_status.unstage(alloc, dir, path);
        errdefer status.deinit(alloc);
        self.syncGitStatusToWorkspace(priv.active_workspace_idx, &status);
        return status;
    }

    pub fn unstageAllActiveGitFiles(self: *Self) !git_status.Status {
        const alloc = std.heap.c_allocator;
        const priv = self.private();
        const dir = priv.current_pwd orelse self.workspaceDir(priv.active_workspace_idx) orelse ".";
        var status = try git_status.unstageAll(alloc, dir);
        errdefer status.deinit(alloc);
        self.syncGitStatusToWorkspace(priv.active_workspace_idx, &status);
        return status;
    }

    pub fn commitActiveGitStaged(self: *Self, message: []const u8) !git_status.CommitResult {
        const alloc = std.heap.c_allocator;
        const priv = self.private();
        const dir = priv.current_pwd orelse self.workspaceDir(priv.active_workspace_idx) orelse ".";
        var result = try git_status.commit(alloc, dir, message);
        errdefer result.deinit(alloc);
        self.syncGitStatusToWorkspace(priv.active_workspace_idx, &result.status);
        return result;
    }

    fn syncGitStatusToWorkspace(self: *Self, workspace_idx: u32, status: *const git_status.Status) void {
        const alloc = self.allocator();
        const priv = self.private();

        if (priv.git_branch) |old| alloc.free(old);
        priv.git_branch = if (status.branch) |branch| alloc.dupeZ(u8, branch) catch null else null;
        priv.git_dirty = status.dirty;

        if (workspace_idx < priv.workspace_git_branches.items.len) {
            if (priv.workspace_git_branches.items[workspace_idx]) |old_branch| alloc.free(old_branch);
            priv.workspace_git_branches.items[workspace_idx] = if (status.branch) |branch| alloc.dupeZ(u8, branch) catch null else null;
            if (workspace_idx < priv.workspace_git_dirty.items.len) {
                priv.workspace_git_dirty.items[workspace_idx] = status.dirty;
            }
            if (workspace_idx < priv.workspace_git_staged_counts.items.len) {
                priv.workspace_git_staged_counts.items[workspace_idx] = @intCast(status.staged.len);
            }
            if (workspace_idx < priv.workspace_git_unstaged_counts.items.len) {
                priv.workspace_git_unstaged_counts.items[workspace_idx] = @intCast(status.unstaged.len);
            }
            self.upsertTerminalHistoryProject(workspace_idx);
        }

        self.updateSidebarGitState();
    }

    fn workspaceIndexForUuid(self: *Self, id: Uuid) ?u32 {
        const priv = self.private();
        for (priv.workspace_ids.items, 0..) |workspace_id, idx| {
            if (uuid.eql(workspace_id, id)) return @intCast(idx);
        }
        return null;
    }

    fn workspaceUnreadCount(self: *Self, index: u32) usize {
        const priv = self.private();
        const workspace_id = self.workspaceUuid(index) orelse return 0;
        return priv.notifications.unreadCountForWorkspace(workspace_id);
    }

    pub fn markWorkspaceNotificationsRead(self: *Self, index: u32) void {
        const priv = self.private();
        const workspace_id = self.workspaceUuid(index) orelse return;
        priv.notifications.markAllReadForWorkspace(workspace_id);
    }

    /// Create a new workspace with an auto-generated name.  Returns the
    /// 0-based index of the newly created workspace, or null on OOM.
    pub fn addWorkspace(self: *Self) ?u32 {
        return self.addWorkspaceWithDir(null);
    }

    const ChangeWorkspaceDirResult = enum {
        updated,
        duplicate,
        invalid_index,
        oom,
    };

    fn normalizeWorkspaceDir(self: *Self, dir: []const u8) ?[:0]const u8 {
        const alloc = self.allocator();

        const expanded: []const u8 = blk: {
            if (dir.len > 0 and dir[0] == '~') {
                const home = std.posix.getenv("HOME") orelse break :blk dir;
                break :blk std.fmt.allocPrint(alloc, "{s}{s}", .{ home, dir[1..] }) catch return null;
            }
            break :blk alloc.dupe(u8, dir) catch return null;
        };
        defer alloc.free(expanded);

        const realpath = std.fs.cwd().realpathAlloc(alloc, expanded) catch null;
        if (realpath) |path| {
            defer alloc.free(path);
            return alloc.dupeZ(u8, path) catch null;
        }

        return alloc.dupeZ(u8, expanded) catch null;
    }

    pub fn workspaceIndexByDir(self: *Self, dir: []const u8) ?u32 {
        const alloc = self.allocator();
        const priv = self.private();

        const normalized_dir = self.normalizeWorkspaceDir(dir) orelse return null;
        defer alloc.free(normalized_dir);

        for (priv.workspace_dirs.items, 0..) |ws_dir, idx| {
            if (std.mem.eql(u8, ws_dir, normalized_dir)) return @intCast(idx);
        }

        return null;
    }

    /// Create a new workspace with an auto-generated name and an optional
    /// explicit working directory.  When `dir` is null the new workspace
    /// inherits the active workspace's directory, or $HOME as a fallback.
    /// Returns the 0-based index of the newly created workspace, or null on OOM.
    pub fn addWorkspaceWithDir(self: *Self, dir: ?[:0]const u8) ?u32 {
        const alloc = self.allocator();
        const priv = self.private();
        const workspace_id = uuid.generate();

        // Generate name "Workspace N"
        var buf: [64]u8 = undefined;
        const name_slice = std.fmt.bufPrint(&buf, "Workspace {d}", .{priv.next_workspace_number}) catch return null;
        const name: [:0]const u8 = alloc.dupeZ(u8, name_slice) catch return null;

        // Resolve directory: explicit > current workspace > $HOME
        const resolved_dir: [:0]const u8 = blk: {
            if (dir) |d| {
                break :blk self.normalizeWorkspaceDir(d) orelse {
                    alloc.free(name);
                    return null;
                };
            }
            // Default to current workspace dir, or $HOME
            if (priv.workspace_dirs.items.len > 0 and priv.active_workspace_idx < priv.workspace_dirs.items.len) {
                break :blk self.normalizeWorkspaceDir(priv.workspace_dirs.items[priv.active_workspace_idx]) orelse {
                    alloc.free(name);
                    return null;
                };
            }
            const home = std.posix.getenv("HOME") orelse "/tmp";
            break :blk self.normalizeWorkspaceDir(home) orelse {
                alloc.free(name);
                return null;
            };
        };

        if (dir != null) {
            if (self.workspaceIndexByDir(resolved_dir)) |existing_idx| {
                alloc.free(name);
                alloc.free(resolved_dir);
                return existing_idx;
            }
        }

        // Create TabView for this workspace
        const tab_view = adw.TabView.new();
        tab_view.as(gtk.Widget).setHexpand(1);
        tab_view.as(gtk.Widget).setVexpand(1);
        // Take Application-owned ref so it survives being unparented
        _ = tab_view.as(gobject.Object).ref();

        priv.workspace_names.append(alloc, name) catch {
            alloc.free(name);
            alloc.free(resolved_dir);
            tab_view.as(gobject.Object).unref();
            return null;
        };
        priv.workspace_dirs.append(alloc, resolved_dir) catch {
            _ = priv.workspace_names.pop();
            alloc.free(name);
            alloc.free(resolved_dir);
            tab_view.as(gobject.Object).unref();
            return null;
        };
        priv.workspace_ids.append(alloc, workspace_id) catch {
            _ = priv.workspace_dirs.pop();
            _ = priv.workspace_names.pop();
            alloc.free(name);
            alloc.free(resolved_dir);
            tab_view.as(gobject.Object).unref();
            return null;
        };
        priv.workspace_tab_views.append(alloc, tab_view) catch {
            _ = priv.workspace_ids.pop();
            _ = priv.workspace_dirs.pop();
            _ = priv.workspace_names.pop();
            alloc.free(name);
            alloc.free(resolved_dir);
            tab_view.as(gobject.Object).unref();
            return null;
        };
        priv.workspace_git_branches.append(alloc, null) catch {
            _ = priv.workspace_tab_views.pop();
            _ = priv.workspace_ids.pop();
            _ = priv.workspace_dirs.pop();
            _ = priv.workspace_names.pop();
            alloc.free(name);
            alloc.free(resolved_dir);
            tab_view.as(gobject.Object).unref();
            return null;
        };
        priv.workspace_git_dirty.append(alloc, false) catch {
            _ = priv.workspace_git_branches.pop();
            _ = priv.workspace_tab_views.pop();
            _ = priv.workspace_ids.pop();
            _ = priv.workspace_dirs.pop();
            _ = priv.workspace_names.pop();
            alloc.free(name);
            alloc.free(resolved_dir);
            tab_view.as(gobject.Object).unref();
            return null;
        };
        priv.workspace_git_staged_counts.append(alloc, 0) catch {
            _ = priv.workspace_git_dirty.pop();
            _ = priv.workspace_git_branches.pop();
            _ = priv.workspace_tab_views.pop();
            _ = priv.workspace_ids.pop();
            _ = priv.workspace_dirs.pop();
            _ = priv.workspace_names.pop();
            alloc.free(name);
            alloc.free(resolved_dir);
            tab_view.as(gobject.Object).unref();
            return null;
        };
        priv.workspace_git_unstaged_counts.append(alloc, 0) catch {
            _ = priv.workspace_git_staged_counts.pop();
            _ = priv.workspace_git_dirty.pop();
            _ = priv.workspace_git_branches.pop();
            _ = priv.workspace_tab_views.pop();
            _ = priv.workspace_ids.pop();
            _ = priv.workspace_dirs.pop();
            _ = priv.workspace_names.pop();
            alloc.free(name);
            alloc.free(resolved_dir);
            tab_view.as(gobject.Object).unref();
            return null;
        };
        priv.workspace_pinned.append(alloc, false) catch {
            _ = priv.workspace_git_unstaged_counts.pop();
            _ = priv.workspace_git_staged_counts.pop();
            _ = priv.workspace_git_dirty.pop();
            _ = priv.workspace_git_branches.pop();
            _ = priv.workspace_tab_views.pop();
            _ = priv.workspace_ids.pop();
            _ = priv.workspace_dirs.pop();
            _ = priv.workspace_names.pop();
            alloc.free(name);
            alloc.free(resolved_dir);
            tab_view.as(gobject.Object).unref();
            return null;
        };

        priv.next_workspace_number += 1;
        const index: u32 = @intCast(priv.workspace_names.items.len - 1);
        self.upsertTerminalHistoryProject(index);
        return index;
    }

    /// Return the name of the workspace at the given index, or null if
    /// out of range.
    pub fn workspaceName(self: *Self, index: u32) ?[:0]const u8 {
        const priv = self.private();
        if (index >= priv.workspace_names.items.len) return null;
        return priv.workspace_names.items[index];
    }

    /// Get the working directory for the workspace at the given index,
    /// or null if the index is out of range.
    pub fn workspaceDir(self: *Self, index: u32) ?[:0]const u8 {
        const priv = self.private();
        if (index >= priv.workspace_dirs.items.len) return null;
        return priv.workspace_dirs.items[index];
    }

    /// Format a workspace directory for display, replacing $HOME with ~.
    pub fn formatDirDisplay(self: *Self, idx: u32, buf: *[512]u8) ?[:0]const u8 {
        const priv = self.private();
        if (idx >= priv.workspace_dirs.items.len) return null;
        const dir = priv.workspace_dirs.items[idx];
        const home = std.posix.getenv("HOME") orelse "";
        if (home.len > 0 and std.mem.startsWith(u8, dir, home)) {
            return std.fmt.bufPrintZ(buf, "~{s}", .{dir[home.len..]}) catch null;
        }
        return dir;
    }

    /// Get the AdwTabView for the workspace at the given index,
    /// or null if the index is out of range.
    pub fn workspaceTabView(self: *Self, index: u32) ?*adw.TabView {
        const priv = self.private();
        if (index >= priv.workspace_tab_views.items.len) return null;
        return priv.workspace_tab_views.items[index];
    }

    /// Get the active workspace's AdwTabView, or null if there are no workspaces.
    pub fn activeTabView(self: *Self) ?*adw.TabView {
        return self.workspaceTabView(self.private().active_workspace_idx);
    }

    /// Return the per-workspace tab counts stored during session restore,
    /// or null if no restore data is pending. The returned slice is valid
    /// until clearRestoreTabCounts() is called.
    pub fn getRestoreTabCounts(self: *Self) ?[]const u32 {
        return self.private().restore_tab_counts;
    }

    /// Free the restore_tab_counts slice and set it to null.
    /// Should be called by the window after consuming the restore data.
    pub fn clearRestoreTabCounts(self: *Self) void {
        const alloc = self.allocator();
        if (self.private().restore_tab_counts) |counts| {
            alloc.free(counts);
            self.private().restore_tab_counts = null;
        }
    }

    /// Return per-workspace tab titles from session restore (v3+), or null.
    pub fn getRestoreTabTitles(self: *Self) ?[]const []const [:0]const u8 {
        return self.private().restore_tab_titles;
    }

    /// Free the restore_tab_titles and set to null.
    pub fn clearRestoreTabTitles(self: *Self) void {
        const alloc = self.allocator();
        if (self.private().restore_tab_titles) |titles_per_ws| {
            for (titles_per_ws) |titles| {
                for (titles) |t| alloc.free(t);
                if (titles.len > 0) alloc.free(titles);
            }
            alloc.free(titles_per_ws);
            self.private().restore_tab_titles = null;
        }
    }

    /// Return per-workspace full tab snapshots from session restore (v5+), or null.
    pub fn getRestoreTabSnapshots(self: *Self) ?[]const []const session_mod.TabData {
        return self.private().restore_tab_snapshots;
    }

    /// Free the restore_tab_snapshots and set to null.
    pub fn clearRestoreTabSnapshots(self: *Self) void {
        const alloc = self.allocator();
        if (self.private().restore_tab_snapshots) |snapshots_per_ws| {
            for (snapshots_per_ws) |snapshots| {
                for (snapshots) |snapshot| {
                    var owned_snapshot = snapshot;
                    owned_snapshot.deinit(alloc);
                }
                if (snapshots.len > 0) alloc.free(snapshots);
            }
            alloc.free(snapshots_per_ws);
            self.private().restore_tab_snapshots = null;
        }
    }

    /// Return per-workspace active tab indices from session restore (v4+), or null.
    pub fn getRestoreActiveTabIndices(self: *Self) ?[]const u32 {
        return self.private().restore_active_tab_indices;
    }

    /// Free the restore_active_tab_indices slice and set to null.
    pub fn clearRestoreActiveTabIndices(self: *Self) void {
        const alloc = self.allocator();
        if (self.private().restore_active_tab_indices) |indices| {
            alloc.free(indices);
            self.private().restore_active_tab_indices = null;
        }
    }

    /// Return per-workspace tab directories from session restore (v4+), or null.
    pub fn getRestoreTabDirs(self: *Self) ?[]const []const [:0]const u8 {
        return self.private().restore_tab_dirs;
    }

    /// Free the restore_tab_dirs and set to null.
    pub fn clearRestoreTabDirs(self: *Self) void {
        const alloc = self.allocator();
        if (self.private().restore_tab_dirs) |dirs_per_ws| {
            for (dirs_per_ws) |dirs| {
                for (dirs) |dir| alloc.free(dir);
                if (dirs.len > 0) alloc.free(dirs);
            }
            alloc.free(dirs_per_ws);
            self.private().restore_tab_dirs = null;
        }
    }

    /// Remove the workspace at `index` from the application state.
    ///
    /// Frees the name string, dir string, and releases the TabView ref.
    /// Protects the last workspace (no-op if only one workspace remains).
    /// If the active workspace index is at or beyond the end of the new list
    /// it is clamped to the last valid index.  The caller is responsible for
    /// keeping the sidebar widget in sync after this call.
    pub fn removeWorkspace(self: *Self, index: u32) void {
        const alloc = self.allocator();
        const priv = self.private();
        if (priv.workspace_names.items.len <= 1) return; // protect last workspace
        if (index >= priv.workspace_names.items.len) return;
        // Cannot remove the orchestration workspace.
        if (priv.orchestration_workspace_idx) |orch_idx| {
            if (index == orch_idx) return;
        }

        const workspace_id = self.workspaceIdString(alloc, index) catch null;
        defer if (workspace_id) |id| alloc.free(id);
        if (workspace_id) |id| {
            self.deleteTerminalHistoryProjectById(id);
            self.scheduleTerminalHistoryProjectDelete(id);
        } else {
            self.deleteTerminalHistoryProject(index);
        }

        // Get the TabView before removing from the array.
        const tab_view = priv.workspace_tab_views.items[index];

        // Free the owned name string.
        alloc.free(priv.workspace_names.items[index]);
        _ = priv.workspace_names.orderedRemove(index);

        // Free the owned dir string.
        alloc.free(priv.workspace_dirs.items[index]);
        _ = priv.workspace_dirs.orderedRemove(index);

        // Clear notifications for the workspace before removing its ID.
        priv.notifications.clearWorkspace(priv.workspace_ids.items[index]);
        _ = priv.workspace_ids.orderedRemove(index);

        // Remove from tab_views array.
        _ = priv.workspace_tab_views.orderedRemove(index);

        // Defer the TabView unref to the GLib idle loop. Unreffing
        // synchronously triggers surface close callbacks that re-enter
        // application state while we are still modifying our arrays,
        // corrupting workspace_names and crashing in autosaveSession.
        _ = glib.idleAdd(deferredTabViewUnref, @ptrCast(tab_view));

        // Free per-workspace git state.
        if (priv.workspace_git_branches.items[index]) |b| alloc.free(b);
        _ = priv.workspace_git_branches.orderedRemove(index);
        _ = priv.workspace_git_dirty.orderedRemove(index);
        _ = priv.workspace_git_staged_counts.orderedRemove(index);
        _ = priv.workspace_git_unstaged_counts.orderedRemove(index);
        _ = priv.workspace_pinned.orderedRemove(index);

        // Adjust active_workspace_idx: shift down if removed index was before active,
        // clamp if it was the active (or last).
        if (index < priv.active_workspace_idx) {
            priv.active_workspace_idx -= 1;
        } else {
            const new_len = priv.workspace_names.items.len;
            if (new_len > 0 and priv.active_workspace_idx >= @as(u32, @intCast(new_len))) {
                priv.active_workspace_idx = @intCast(new_len - 1);
            }
        }

        // Adjust orchestration_workspace_idx if a workspace before it was removed.
        if (priv.orchestration_workspace_idx) |orch_idx| {
            if (index < orch_idx) {
                priv.orchestration_workspace_idx = orch_idx - 1;
            }
        }
    }

    /// Rename the workspace at the given index.
    ///
    /// Frees the old name string and replaces it with a duplicate of `new_name`.
    /// Does nothing if the index is out of range.
    pub fn renameWorkspace(self: *Self, index: u32, new_name: [:0]const u8) void {
        const alloc = self.allocator();
        const priv = self.private();
        if (index >= priv.workspace_names.items.len) return;
        alloc.free(priv.workspace_names.items[index]);
        priv.workspace_names.items[index] = alloc.dupeZ(u8, new_name) catch return;
        self.upsertTerminalHistoryProject(index);
    }

    pub fn workspacePinned(self: *Self, index: u32) bool {
        const priv = self.private();
        if (index >= priv.workspace_pinned.items.len) return false;
        return priv.workspace_pinned.items[index];
    }

    pub fn toggleWorkspacePinned(self: *Self, index: u32) bool {
        const priv = self.private();
        if (index >= priv.workspace_pinned.items.len) return false;
        priv.workspace_pinned.items[index] = !priv.workspace_pinned.items[index];
        self.refreshAllWorkspaceSidebars();
        autosaveSession(self);
        return priv.workspace_pinned.items[index];
    }

    /// Change the working directory for a workspace.
    ///
    /// Expands ~ to $HOME, updates workspace_dirs, probes git for
    /// the new path, and refreshes all sidebars.
    pub fn changeWorkspaceDir(self: *Self, index: u32, new_dir: [:0]const u8) ChangeWorkspaceDirResult {
        const alloc = self.allocator();
        const priv = self.private();

        if (index >= priv.workspace_dirs.items.len) return .invalid_index;

        const resolved_dir = self.normalizeWorkspaceDir(new_dir) orelse return .oom;

        if (std.mem.eql(u8, priv.workspace_dirs.items[index], resolved_dir)) {
            alloc.free(resolved_dir);
            return .updated;
        }

        if (self.workspaceIndexByDir(resolved_dir)) |existing_idx| {
            if (existing_idx != index) {
                alloc.free(resolved_dir);
                return .duplicate;
            }
        }

        // Replace the old dir.
        alloc.free(priv.workspace_dirs.items[index]);
        priv.workspace_dirs.items[index] = resolved_dir;

        // Trigger git probe for this workspace.
        var result = git_probe.probe(alloc, resolved_dir);
        defer result.deinit(alloc);

        if (priv.workspace_git_branches.items[index]) |old_b| alloc.free(old_b);
        priv.workspace_git_branches.items[index] = if (result.branch) |b|
            alloc.dupeZ(u8, b) catch null
        else
            null;
        priv.workspace_git_dirty.items[index] = result.dirty;
        priv.workspace_git_staged_counts.items[index] = result.staged_count;
        priv.workspace_git_unstaged_counts.items[index] = result.unstaged_count;

        self.deleteTerminalHistoryProject(index);
        self.upsertTerminalHistoryProject(index);

        // Refresh sidebar to show new dir and git state.
        self.refreshAllWorkspaceSidebars();
        if (index == priv.active_workspace_idx) {
            self.syncActiveWorkspaceHeaders();
        }

        log.info("workspace {d} directory changed to: {s}", .{ index, resolved_dir });
        return .updated;
    }

    /// Add a workspace row to every open Termplex window sidebar.
    pub fn addWorkspaceToAllWindows(self: *Self, index: u32) void {
        const list = self.as(gtk.Application).getWindows();
        list.foreach(struct {
            fn cb(data: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) void {
                const idx_ptr: *const u32 = @ptrCast(@alignCast(userdata orelse return));
                const ptr: *gtk.Window = @ptrCast(@alignCast(data orelse return));
                const win = gobject.ext.cast(Window, ptr) orelse return;
                const app = Application.default();
                var dir_buf: [512]u8 = undefined;
                win.getSidebar().addWorkspace(
                    idx_ptr.*,
                    app.workspaceName(idx_ptr.*),
                    null,
                    null,
                    app.formatDirDisplay(idx_ptr.*, &dir_buf),
                    app.workspacePinned(idx_ptr.*),
                );
            }
        }.cb, @ptrCast(@constCast(&index)));
    }

    /// Remove a workspace row from every open Termplex window sidebar.
    pub fn removeWorkspaceFromAllWindows(self: *Self, index: u32) void {
        const list = self.as(gtk.Application).getWindows();
        list.foreach(struct {
            fn cb(data: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) void {
                const idx_ptr: *const u32 = @ptrCast(@alignCast(userdata orelse return));
                const ptr: *gtk.Window = @ptrCast(@alignCast(data orelse return));
                const win = gobject.ext.cast(Window, ptr) orelse return;
                win.getSidebar().removeWorkspace(idx_ptr.*);
            }
        }.cb, @ptrCast(@constCast(&index)));
    }

    /// Update all window titlebars to match the current active workspace.
    pub fn syncActiveWorkspaceHeaders(self: *Self) void {
        const list = self.as(gtk.Application).getWindows();
        list.foreach(struct {
            fn cb(data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
                const ptr: *gtk.Window = @ptrCast(@alignCast(data orelse return));
                const win = gobject.ext.cast(Window, ptr) orelse return;
                win.syncHeaderFromApp();
            }
        }.cb, null);
    }

    // -----------------------------------------------------------------
    // Termplex IPC socket server (inline, no termplex module import)
    // -----------------------------------------------------------------

    /// Resolve the Unix socket path using the same priority as socket_server.zig:
    ///   1. $TERMPLEX_SOCKET
    ///   2. $XDG_RUNTIME_DIR/termplex.sock
    ///   3. /tmp/termplex-{uid}.sock
    ///
    /// Caller owns the returned slice.
    fn ipcSocketPath(alloc: std.mem.Allocator) ![]u8 {
        // 1. Explicit override.
        if (std.process.getEnvVarOwned(alloc, "TERMPLEX_SOCKET")) |p| {
            if (p.len > 0) return p;
            alloc.free(p);
        } else |_| {}

        // 2. $XDG_RUNTIME_DIR/termplex.sock
        if (std.process.getEnvVarOwned(alloc, "XDG_RUNTIME_DIR")) |dir| {
            defer alloc.free(dir);
            if (dir.len > 0) {
                return std.fs.path.join(alloc, &[_][]const u8{ dir, "termplex.sock" });
            }
        } else |_| {}

        // 3. /tmp/termplex-{uid}.sock
        const uid = std.posix.getuid();
        return std.fmt.allocPrint(alloc, "/tmp/termplex-{d}.sock", .{uid});
    }

    /// Create, bind, and listen on the Unix domain socket, then register
    /// a GLib timer to poll it every 100 ms.
    fn startIpcSocket(self: *Self) !void {
        const alloc = self.allocator();
        const priv = self.private();

        const path = try ipcSocketPath(alloc);
        errdefer alloc.free(path);

        // Remove any leftover socket file from a previous run.
        std.posix.unlink(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        // Create a non-blocking, close-on-exec Unix stream socket.
        const fd = try std.posix.socket(
            std.posix.AF.UNIX,
            std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC,
            0,
        );
        errdefer std.posix.close(fd);

        // Build sockaddr_un and bind.
        var addr: std.posix.sockaddr.un = .{
            .family = std.posix.AF.UNIX,
            .path = undefined,
        };
        @memset(&addr.path, 0);
        if (path.len >= addr.path.len) return error.SocketPathTooLong;
        @memcpy(addr.path[0..path.len], path);

        try std.posix.bind(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un));
        try std.posix.listen(fd, 16);

        log.debug("IPC socket listening on {s}", .{path});

        priv.socket_fd = fd;
        priv.socket_path_buf = path;
        priv.socket_poll_timer = glib.timeoutAdd(100, pollSocketCallback, self);

        // Termplex: start the 10-second combined git+port probe timer.
        priv.port_scan_timer = glib.timeoutAdd(10000, combinedProbeCallback, self);

        // Schedule initial combined probe shortly after startup (one-shot)
        // so branch info appears quickly without waiting for the 10s timer.
        priv.initial_probe_timer = glib.timeoutAdd(500, initialProbeCallback, self);

        // Termplex: start the autosave timer.
        const autosave_minutes: u64 = if (priv.termplex_cfg.session.autosave_interval == 0)
            5
        else
            priv.termplex_cfg.session.autosave_interval;
        const autosave_ms: c_uint = @intCast(@min(
            autosave_minutes * 60_000,
            @as(u64, std.math.maxInt(c_uint)),
        ));
        priv.autosave_timer = glib.timeoutAdd(autosave_ms, autosaveCallback, self);
    }

    /// GLib timer callback: called every 100 ms to accept and service IPC
    /// client connections in a non-blocking manner.
    fn pollSocketCallback(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return @intFromBool(glib.SOURCE_CONTINUE)));
        const priv = self.private();
        const listen_fd = priv.socket_fd orelse {
            priv.socket_poll_timer = null;
            return @intFromBool(glib.SOURCE_REMOVE);
        };

        // Accept all pending connections; each is served synchronously (one
        // request → one response → close), which is safe because the client
        // fd is also set to non-blocking.
        while (true) {
            const client_fd = std.posix.accept(
                listen_fd,
                null,
                null,
                std.posix.SOCK.CLOEXEC,
            ) catch |err| switch (err) {
                error.WouldBlock => break, // no more pending connections
                error.ConnectionAborted => continue,
                else => {
                    log.warn("IPC accept error: {}", .{err});
                    break;
                },
            };

            // Accepted fd is blocking by default (we pass CLOEXEC only,
            // not SOCK_NONBLOCK).  This is correct for the synchronous
            // serve pattern: read complete request → dispatch → write response.
            ipcServeClient(self, client_fd);
            std.posix.close(client_fd);
        }

        return @intFromBool(glib.SOURCE_CONTINUE);
    }

    fn quitApplicationCallback(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return @intFromBool(glib.SOURCE_REMOVE)));
        self.quit();
        return @intFromBool(glib.SOURCE_REMOVE);
    }

    /// Read a single newline-terminated JSON request from the client, dispatch
    /// it, and write the response.  The client fd is blocking, so reads will
    /// wait for data (appropriate for the one-request-per-connection pattern).
    fn ipcServeClient(self: *Self, client_fd: std.posix.socket_t) void {
        var buf: [65536]u8 = undefined;
        var len: usize = 0;

        // Read until we find a newline or exhaust the buffer.
        while (len < buf.len) {
            const n = std.posix.read(client_fd, buf[len..]) catch |err| switch (err) {
                error.WouldBlock => break,
                else => return,
            };
            if (n == 0) break; // EOF
            len += n;
            if (std.mem.indexOfScalar(u8, buf[0..len], '\n') != null) break;
        }

        const nl = std.mem.indexOfScalar(u8, buf[0..len], '\n') orelse return;
        const request = buf[0..nl];

        const alloc = self.allocator();
        const response = ipcDispatch(self, alloc, request) orelse return;
        defer alloc.free(response);

        ipcWriteAll(client_fd, response) catch {};
        ipcWriteAll(client_fd, "\n") catch {};
    }

    const UpdateDownloadResult = struct {
        app: *Self,
        path: ?[]const u8 = null,
        err: ?anyerror = null,
    };

    const UpdateDownloadJob = struct {
        app: *Self,
        result: *UpdateDownloadResult,
        url: []const u8,
        dest_dir: []const u8,
        filename: []const u8,
        sha256: [32]u8,

        fn deinit(self: *UpdateDownloadJob, alloc: std.mem.Allocator) void {
            alloc.free(self.url);
            alloc.free(self.dest_dir);
            alloc.free(self.filename);
        }
    };

    fn updateManifestUrl(self: *Self) []const u8 {
        _ = self;
        return std.posix.getenv("TERMPLEX_UPDATE_MANIFEST_URL") orelse
            "https://github.com/termplex-org/termplex/releases/latest/download/termplex-update.json";
    }

    fn currentUpdateChannel(self: *Self) update_manifest_mod.Channel {
        _ = self;
        return switch (build_config.release_channel) {
            .stable => .stable,
            .tip => .tip,
        };
    }

    fn currentPlatformArch() []const u8 {
        return switch (@import("builtin").target.cpu.arch) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
            else => "unsupported",
        };
    }

    fn replaceStateString(slot: *?[]const u8, value: ?[]const u8) !void {
        const alloc = std.heap.c_allocator;
        if (slot.*) |old| alloc.free(old);
        slot.* = null;
        if (value) |v| slot.* = try alloc.dupe(u8, v);
    }

    fn replaceOwnedString(slot: *?[]u8, value: ?[]const u8) !void {
        const alloc = std.heap.c_allocator;
        if (slot.*) |old| alloc.free(old);
        slot.* = null;
        if (value) |v| slot.* = try alloc.dupe(u8, v);
    }

    fn replaceCString(slot: *?[:0]u8, value: ?[]const u8) !void {
        const alloc = std.heap.c_allocator;
        if (slot.*) |old| alloc.free(old);
        slot.* = null;
        if (value) |v| slot.* = try alloc.dupeZ(u8, v);
    }

    fn clearUpdateDownloadMetadata(self: *Self) void {
        const priv = self.private();
        replaceOwnedString(&priv.update_download_url, null) catch {};
        replaceOwnedString(&priv.update_download_filename, null) catch {};
        replaceOwnedString(&priv.update_notes_url, null) catch {};
        priv.update_download_sha256 = null;
    }

    fn saveUpdateState(self: *Self) void {
        const priv = self.private();
        if (priv.update_paths) |paths| {
            update_state_mod.save(std.heap.c_allocator, paths.state_json, priv.update_state) catch |err| {
                log.warn("failed to save update state: {}", .{err});
            };
        }
    }

    fn setUpdateDownloadStarted(self: *Self) void {
        const priv = self.private();
        replaceStateString(&priv.update_state.downloaded_version, null) catch {};
        replaceStateString(&priv.update_state.download_path, null) catch {};
        replaceStateString(&priv.update_state.last_error, null) catch {};
        replaceStateString(&priv.update_state.progress, "downloading") catch {};
        replaceCString(&priv.update_download_path, null) catch {};
        replaceCString(&priv.update_last_error, null) catch {};
        priv.update_state.checksum_status = .none;
        self.saveUpdateState();
        self.refreshUpdateBars();
    }

    fn setUpdateDownloaded(self: *Self, path: []const u8) !void {
        const priv = self.private();
        try replaceStateString(&priv.update_state.download_path, path);
        if (priv.update_available_version) |version| {
            try replaceStateString(&priv.update_state.downloaded_version, version);
        } else {
            try replaceStateString(&priv.update_state.downloaded_version, priv.update_state.last_available_version);
        }
        try replaceStateString(&priv.update_state.last_error, null);
        try replaceStateString(&priv.update_state.progress, "downloaded");
        try replaceCString(&priv.update_download_path, path);
        try replaceCString(&priv.update_last_error, null);
        priv.update_state.checksum_status = .verified;
        self.saveUpdateState();
        self.refreshUpdateBars();
    }

    fn setUpdateError(self: *Self, err: anyerror) void {
        const message = @errorName(err);
        const priv = self.private();
        replaceStateString(&priv.update_state.last_error, message) catch {};
        replaceStateString(&priv.update_state.progress, "error") catch {};
        if (err == error.ChecksumMismatch) {
            priv.update_state.checksum_status = .mismatch;
        }
        replaceCString(&priv.update_last_error, message) catch {};
        self.saveUpdateState();
        self.refreshUpdateBars();
    }

    fn setUpdateAvailable(self: *Self, available: update_checker_mod.Available) void {
        const priv = self.private();
        replaceStateString(&priv.update_state.last_available_version, available.version_string) catch {};
        replaceStateString(&priv.update_state.downloaded_version, null) catch {};
        replaceStateString(&priv.update_state.download_path, null) catch {};
        replaceStateString(&priv.update_state.last_error, null) catch {};
        replaceStateString(&priv.update_state.progress, "available") catch {};
        replaceCString(&priv.update_available_version, available.version_string) catch {};
        replaceCString(&priv.update_download_path, null) catch {};
        replaceCString(&priv.update_last_error, null) catch {};
        replaceOwnedString(&priv.update_notes_url, available.notes_url) catch {};
        if (available.download) |download| {
            replaceOwnedString(&priv.update_download_url, download.url) catch {};
            replaceOwnedString(&priv.update_download_filename, download.filename) catch {};
            priv.update_download_sha256 = download.sha256;
        } else {
            replaceOwnedString(&priv.update_download_url, null) catch {};
            replaceOwnedString(&priv.update_download_filename, null) catch {};
            priv.update_download_sha256 = null;
        }
        priv.update_state.install_kind = available.install_kind;
        priv.update_state.checksum_status = .none;
        self.saveUpdateState();
        self.refreshUpdateBars();
    }

    fn setUpdateUnavailable(self: *Self, available: update_checker_mod.Available) void {
        const priv = self.private();
        replaceStateString(&priv.update_state.last_available_version, available.version_string) catch {};
        replaceStateString(&priv.update_state.downloaded_version, null) catch {};
        replaceStateString(&priv.update_state.download_path, null) catch {};
        replaceStateString(&priv.update_state.last_error, null) catch {};
        replaceStateString(&priv.update_state.progress, "unavailable_for_install") catch {};
        replaceCString(&priv.update_available_version, available.version_string) catch {};
        replaceCString(&priv.update_download_path, null) catch {};
        replaceCString(&priv.update_last_error, null) catch {};
        replaceOwnedString(&priv.update_notes_url, available.notes_url) catch {};
        replaceOwnedString(&priv.update_download_url, null) catch {};
        replaceOwnedString(&priv.update_download_filename, null) catch {};
        priv.update_download_sha256 = null;
        priv.update_state.install_kind = available.install_kind;
        priv.update_state.checksum_status = .none;
        self.saveUpdateState();
        self.refreshUpdateBars();
    }

    fn showUpdateToast(self: *Self, title: []const u8) void {
        log.info("update: {s}", .{title});
        const title_z = std.heap.c_allocator.dupeZ(u8, title) catch return;
        defer std.heap.c_allocator.free(title_z);

        const list = self.as(gtk.Application).getWindows();
        list.foreach(struct {
            fn cb(data: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) void {
                const title_ptr: [*:0]const u8 = @ptrCast(userdata orelse return);
                const ptr: *gtk.Window = @ptrCast(@alignCast(data orelse return));
                const win = gobject.ext.cast(Window, ptr) orelse return;
                win.addTermplexToast(title_ptr);
            }
        }.cb, @ptrCast(title_z.ptr));
    }

    fn refreshUpdateBars(self: *Self) void {
        const list = self.as(gtk.Application).getWindows();
        list.foreach(struct {
            fn cb(data: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) void {
                const app: *Application = @ptrCast(@alignCast(userdata orelse return));
                const p = app.private();
                const ptr: *gtk.Window = @ptrCast(@alignCast(data orelse return));
                const win = gobject.ext.cast(Window, ptr) orelse return;

                if (p.update_available_version) |version| {
                    if (p.update_state.isDismissed(version)) {
                        win.hideUpdateBar();
                        return;
                    }

                    if (p.update_state.progress) |progress| {
                        if (std.mem.eql(u8, progress, "downloading")) {
                            win.showUpdateDownloading(version);
                            return;
                        }
                    }

                    if (p.update_download_path != null) {
                        win.showUpdateDownloaded(version);
                    } else {
                        win.showUpdateAvailable(version, p.update_state.install_kind == .appimage);
                    }
                } else {
                    win.hideUpdateBar();
                }
            }
        }.cb, self);
    }

    pub fn handleUpdatePrimaryAction(self: *Self) void {
        const priv = self.private();
        if (priv.update_download_path) |path| {
            Action.openUrl(self, .{ .kind = .unknown, .url = path });
            return;
        }

        if (priv.update_state.install_kind != .appimage) {
            if (priv.update_notes_url) |url| {
                Action.openUrl(self, .{ .kind = .html, .url = url });
            } else {
                self.showUpdateToast("Release page is not available");
            }
            return;
        }

        self.downloadAvailableUpdate();
    }

    pub fn dismissCurrentUpdate(self: *Self) void {
        const priv = self.private();
        if (priv.update_available_version) |version| {
            replaceStateString(&priv.update_state.dismissed_version, version) catch {};
        }
        self.saveUpdateState();
        self.refreshUpdateBars();
    }

    fn makeUpdateDownloadJob(
        self: *Self,
        result: *UpdateDownloadResult,
        url: []const u8,
        dest_dir: []const u8,
        filename: []const u8,
        sha256: [32]u8,
    ) !*UpdateDownloadJob {
        const alloc = std.heap.c_allocator;
        const job = try alloc.create(UpdateDownloadJob);
        errdefer alloc.destroy(job);

        job.* = .{
            .app = self,
            .result = result,
            .url = "",
            .dest_dir = "",
            .filename = "",
            .sha256 = sha256,
        };

        job.url = try alloc.dupe(u8, url);
        errdefer alloc.free(job.url);
        job.dest_dir = try alloc.dupe(u8, dest_dir);
        errdefer alloc.free(job.dest_dir);
        job.filename = try alloc.dupe(u8, filename);

        return job;
    }

    fn downloadAvailableUpdate(self: *Self) void {
        const alloc = std.heap.c_allocator;
        const priv = self.private();

        if (priv.update_state.progress) |progress| {
            if (std.mem.eql(u8, progress, "downloading")) {
                self.showUpdateToast("Update download already running");
                return;
            }
        }

        const paths = priv.update_paths orelse {
            self.setUpdateError(error.MissingUpdatePaths);
            self.showUpdateToast("Update download failed");
            return;
        };
        const url = priv.update_download_url orelse {
            self.showUpdateToast("Check for updates again before downloading");
            return;
        };
        const filename = priv.update_download_filename orelse {
            self.setUpdateError(error.MissingUpdateMetadata);
            self.showUpdateToast("Update download failed");
            return;
        };
        const sha256 = priv.update_download_sha256 orelse {
            self.setUpdateError(error.MissingUpdateMetadata);
            self.showUpdateToast("Update download failed");
            return;
        };

        self.setUpdateDownloadStarted();

        const result = alloc.create(UpdateDownloadResult) catch |err| {
            self.setUpdateError(err);
            self.showUpdateToast("Update download failed");
            return;
        };
        result.* = .{ .app = self };

        const job = self.makeUpdateDownloadJob(result, url, paths.dir, filename, sha256) catch |err| {
            alloc.destroy(result);
            self.setUpdateError(err);
            self.showUpdateToast("Update download failed");
            return;
        };

        _ = self.as(gobject.Object).ref();
        const thread = std.Thread.spawn(.{}, updateDownloadThread, .{job}) catch |err| {
            self.as(gobject.Object).unref();
            job.deinit(alloc);
            alloc.destroy(job);
            alloc.destroy(result);
            self.setUpdateError(err);
            self.showUpdateToast("Update download failed");
            return;
        };
        thread.detach();
    }

    fn updateDownloadThread(job: *UpdateDownloadJob) void {
        const alloc = std.heap.c_allocator;
        const result = job.result;

        result.path = update_checker_mod.downloadAppImage(
            alloc,
            job.url,
            job.dest_dir,
            job.filename,
            job.sha256,
        ) catch |err| blk: {
            result.err = err;
            break :blk null;
        };

        job.deinit(alloc);
        alloc.destroy(job);

        _ = glib.idleAdd(updateDownloadComplete, result);
    }

    fn updateDownloadComplete(ud: ?*anyopaque) callconv(.c) c_int {
        const result: *UpdateDownloadResult = @ptrCast(@alignCast(ud orelse return @intFromBool(glib.SOURCE_REMOVE)));
        const alloc = std.heap.c_allocator;
        defer {
            if (result.path) |path| alloc.free(path);
            result.app.as(gobject.Object).unref();
            alloc.destroy(result);
        }

        if (result.err) |err| {
            result.app.setUpdateError(err);
            result.app.showUpdateToast("Update download failed");
            return @intFromBool(glib.SOURCE_REMOVE);
        }

        const path = result.path orelse {
            result.app.setUpdateError(error.MissingDownloadPath);
            result.app.showUpdateToast("Update download failed");
            return @intFromBool(glib.SOURCE_REMOVE);
        };

        result.app.setUpdateDownloaded(path) catch |err| {
            result.app.setUpdateError(err);
            result.app.showUpdateToast("Update download failed");
            return @intFromBool(glib.SOURCE_REMOVE);
        };
        result.app.showUpdateToast("Termplex update downloaded");
        return @intFromBool(glib.SOURCE_REMOVE);
    }

    fn runUpdateCheckFromBytes(self: *Self, manifest_bytes: []const u8) void {
        const alloc = std.heap.c_allocator;
        const install_kind = blk: {
            var env = std.process.getEnvMap(alloc) catch break :blk update_state_mod.InstallKind.unknown;
            defer env.deinit();
            break :blk update_checker_mod.detectInstallKind(env);
        };

        var result = update_checker_mod.evaluateManifest(
            alloc,
            manifest_bytes,
            build_config.version,
            self.currentUpdateChannel(),
            install_kind,
            currentPlatformArch(),
        ) catch |err| {
            self.setUpdateError(err);
            self.showUpdateToast("Update check failed");
            return;
        };
        defer result.deinit(alloc);

        switch (result) {
            .up_to_date => {
                replaceStateString(&self.private().update_state.progress, "up_to_date") catch {};
                replaceStateString(&self.private().update_state.last_error, null) catch {};
                replaceCString(&self.private().update_available_version, null) catch {};
                replaceCString(&self.private().update_download_path, null) catch {};
                replaceCString(&self.private().update_last_error, null) catch {};
                self.clearUpdateDownloadMetadata();
                self.saveUpdateState();
                self.refreshUpdateBars();
                self.showUpdateToast("Termplex is up to date");
            },
            .available => |available| {
                self.setUpdateAvailable(available);
                self.showUpdateToast("A Termplex update is available");
            },
            .unavailable_for_install => |available| {
                self.setUpdateUnavailable(available);
                self.showUpdateToast("A Termplex update is available");
            },
        }
    }

    fn checkForUpdates(self: *Self) void {
        const alloc = std.heap.c_allocator;
        const url = self.updateManifestUrl();

        if (std.mem.startsWith(u8, url, "file://")) {
            const path = url["file://".len..];
            const bytes = std.fs.cwd().readFileAlloc(alloc, path, 2 * 1024 * 1024) catch |err| {
                self.setUpdateError(err);
                self.showUpdateToast("Update check failed");
                return;
            };
            defer alloc.free(bytes);
            self.runUpdateCheckFromBytes(bytes);
            return;
        }

        const bytes = update_checker_mod.fetchHttps(alloc, url, .{}) catch |err| {
            self.setUpdateError(err);
            self.showUpdateToast("Update check failed");
            return;
        };
        defer alloc.free(bytes);
        self.runUpdateCheckFromBytes(bytes);
    }

    fn writeJsonOptionalString(jw: *std.json.Stringify, field: []const u8, value: ?[]const u8) !void {
        try jw.objectField(field);
        if (value) |v| try jw.write(v) else try jw.write(null);
    }

    fn ipcUpdateStatus(self: *Self, alloc: std.mem.Allocator, id: i64) ?[]u8 {
        const priv = self.private();
        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();

        var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
        jw.beginObject() catch return null;
        jw.objectField("ok") catch return null;
        jw.write(true) catch return null;
        jw.objectField("result") catch return null;
        jw.beginObject() catch return null;
        writeJsonOptionalString(&jw, "available_version", priv.update_state.last_available_version) catch return null;
        writeJsonOptionalString(&jw, "download_path", priv.update_state.download_path) catch return null;
        writeJsonOptionalString(&jw, "last_error", priv.update_state.last_error) catch return null;
        writeJsonOptionalString(&jw, "progress", priv.update_state.progress) catch return null;
        jw.objectField("install_kind") catch return null;
        jw.write(@tagName(priv.update_state.install_kind)) catch return null;
        jw.endObject() catch return null;
        jw.objectField("id") catch return null;
        jw.write(id) catch return null;
        jw.endObject() catch return null;

        return aw.toOwnedSlice() catch null;
    }

    /// Parse a minimal JSON-RPC request and dispatch to the right handler.
    /// Returns an allocated response string (caller frees), or null on error.
    fn ipcDispatch(self: *Self, alloc: std.mem.Allocator, request: []const u8) ?[]u8 {
        // We do a minimal parse: extract "method" and "id" from the JSON.
        // Using std.json for correctness.
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            alloc,
            request,
            .{},
        ) catch |err| {
            log.warn("IPC: failed to parse JSON request: {}", .{err});
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"invalid_request\",\"message\":\"malformed JSON\"}},\"id\":0}}",
                .{},
            ) catch null;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"invalid_request\",\"message\":\"expected object\"}},\"id\":0}}",
                .{},
            ) catch null;
        }

        // Extract id (integer, default 0).
        const id: i64 = blk: {
            if (root.object.get("id")) |v| {
                break :blk switch (v) {
                    .integer => |n| n,
                    else => 0,
                };
            }
            break :blk 0;
        };

        // Extract method string.
        const method: []const u8 = blk: {
            if (root.object.get("method")) |v| {
                break :blk switch (v) {
                    .string => |s| s,
                    else => "",
                };
            }
            break :blk "";
        };

        log.debug("IPC dispatch method={s} id={d}", .{ method, id });

        // --- Dispatch ---

        if (std.mem.eql(u8, method, "system.ping")) {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":true,\"result\":\"pong\",\"id\":{d}}}",
                .{id},
            ) catch null;
        }

        if (std.mem.eql(u8, method, "system.quit")) {
            _ = glib.timeoutAdd(50, quitApplicationCallback, self);
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":true,\"result\":{{\"quitting\":true}},\"id\":{d}}}",
                .{id},
            ) catch null;
        }

        if (std.mem.eql(u8, method, "update.status")) {
            return self.ipcUpdateStatus(alloc, id);
        }

        if (std.mem.eql(u8, method, "update.check")) {
            self.checkForUpdates();
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":true,\"result\":{{\"checking\":true}},\"id\":{d}}}",
                .{id},
            ) catch null;
        }

        if (std.mem.eql(u8, method, "update.download")) {
            self.downloadAvailableUpdate();
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":true,\"result\":{{\"downloading\":true}},\"id\":{d}}}",
                .{id},
            ) catch null;
        }

        if (std.mem.eql(u8, method, "dashboard.status")) {
            return self.ipcDashboardStatus(alloc, id, root.object);
        }

        if (std.mem.eql(u8, method, "dashboard.show")) {
            return self.ipcDashboardShow(alloc, id);
        }

        if (std.mem.eql(u8, method, "diagnostics.export")) {
            return self.ipcDiagnosticsExport(alloc, id, root.object);
        }

        if (std.mem.eql(u8, method, "task.list")) {
            return self.ipcTaskList(alloc, id, root.object);
        }

        if (std.mem.eql(u8, method, "task.add")) {
            return self.ipcTaskAdd(alloc, id, root.object);
        }

        if (std.mem.eql(u8, method, "task.promote")) {
            return self.ipcTaskPromote(alloc, id, root.object);
        }

        if (std.mem.eql(u8, method, "task.delete")) {
            return self.ipcTaskDelete(alloc, id, root.object);
        }

        if (std.mem.eql(u8, method, "task.run")) {
            return self.ipcTaskRun(alloc, id, root.object);
        }

        if (std.mem.eql(u8, method, "history.search")) {
            return self.ipcHistorySearch(alloc, id, root.object);
        }

        if (std.mem.eql(u8, method, "history.transcript")) {
            return self.ipcHistoryTranscript(alloc, id, root.object);
        }

        if (std.mem.eql(u8, method, "history.transcript_search")) {
            return self.ipcHistoryTranscriptSearch(alloc, id, root.object);
        }

        if (std.mem.eql(u8, method, "history.transcript_show")) {
            return self.ipcHistoryTranscriptShow(alloc, id, root.object);
        }

        if (std.mem.eql(u8, method, "history.show")) {
            return self.ipcHistoryShow(alloc, id);
        }

        if (std.mem.eql(u8, method, "storage.status")) {
            return self.ipcStorageStatus(alloc, id);
        }

        if (std.mem.eql(u8, method, "storage.clear_terminal")) {
            return self.ipcStorageClearTerminal(alloc, id, root.object);
        }

        if (std.mem.eql(u8, method, "storage.clear_workspace")) {
            return self.ipcStorageClearWorkspace(alloc, id, root.object);
        }

        if (std.mem.eql(u8, method, "storage.delete_project")) {
            return self.ipcStorageDeleteProject(alloc, id, root.object);
        }

        if (std.mem.eql(u8, method, "storage.show")) {
            return self.ipcStorageShow(alloc, id);
        }

        if (std.mem.eql(u8, method, "git.status")) {
            return self.ipcGitStatus(alloc, id, root.object);
        }

        if (std.mem.eql(u8, method, "git.diff")) {
            return self.ipcGitDiff(alloc, id, root.object);
        }

        if (std.mem.eql(u8, method, "git.stage")) {
            return self.ipcGitStage(alloc, id, root.object);
        }

        if (std.mem.eql(u8, method, "git.stage_all")) {
            return self.ipcGitStageAll(alloc, id, root.object);
        }

        if (std.mem.eql(u8, method, "git.unstage")) {
            return self.ipcGitUnstage(alloc, id, root.object);
        }

        if (std.mem.eql(u8, method, "git.unstage_all")) {
            return self.ipcGitUnstageAll(alloc, id, root.object);
        }

        if (std.mem.eql(u8, method, "git.commit")) {
            return self.ipcGitCommit(alloc, id, root.object);
        }

        if (std.mem.eql(u8, method, "git.show")) {
            return self.ipcGitShow(alloc, id);
        }

        if (std.mem.eql(u8, method, "workspace.list")) {
            return ipcWorkspaceList(self, alloc, id);
        }

        if (std.mem.eql(u8, method, "workspace.create")) {
            return ipcWorkspaceCreate(self, alloc, id, root.object);
        }

        if (std.mem.eql(u8, method, "workspace.find_by_dir")) {
            return ipcWorkspaceFindByDir(self, alloc, id, root.object);
        }

        if (std.mem.eql(u8, method, "workspace.select")) {
            return ipcWorkspaceSelect(self, alloc, id, root.object);
        }

        if (std.mem.eql(u8, method, "workspace.close")) {
            return ipcWorkspaceClose(self, alloc, id, root.object);
        }

        if (std.mem.eql(u8, method, "workspace.rename")) {
            return ipcWorkspaceRename(self, alloc, id, root.object);
        }

        if (std.mem.eql(u8, method, "notification.create")) {
            return ipcNotificationCreate(self, alloc, id, root.object);
        }
        if (std.mem.eql(u8, method, "notification.list")) {
            return ipcNotificationList(self, alloc, id, root.object);
        }
        if (std.mem.eql(u8, method, "notification.clear")) {
            return ipcNotificationClear(self, alloc, id, root.object);
        }

        if (std.mem.eql(u8, method, "status.report_pwd")) {
            // Extract pwd from params.
            const params_val = root.object.get("params") orelse .null;
            const pwd_slice: []const u8 = if (params_val == .object)
                if (params_val.object.get("pwd")) |pv| switch (pv) {
                    .string => |s| s,
                    else => "",
                } else ""
            else
                "";

            if (pwd_slice.len > 0) {
                const pwd_z = alloc.dupeZ(u8, pwd_slice) catch null;
                if (pwd_z) |pz| {
                    self.updateWorkspacePwd(pz);
                    alloc.free(pz);
                }
            }

            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":true,\"result\":null,\"id\":{d}}}",
                .{id},
            ) catch null;
        }

        if (std.mem.eql(u8, method, "tab.list")) {
            return ipcTabList(self, alloc, id, root.object);
        }

        if (std.mem.eql(u8, method, "tab.create")) {
            return ipcTabCreate(self, alloc, id, root.object);
        }

        if (std.mem.eql(u8, method, "agent.register")) {
            return ipcAgentRegister(self, alloc, id, root.object);
        }
        if (std.mem.eql(u8, method, "agent.list")) {
            return ipcAgentList(self, alloc, id);
        }
        if (std.mem.eql(u8, method, "agent.unregister")) {
            return ipcAgentUnregister(self, alloc, id, root.object);
        }
        if (std.mem.eql(u8, method, "agent.terminate")) {
            return ipcAgentTerminate(self, alloc, id, root.object);
        }

        if (std.mem.eql(u8, method, "surface.send")) {
            return ipcSurfaceSend(self, alloc, id, root.object);
        }
        if (std.mem.eql(u8, method, "surface.read")) {
            return ipcSurfaceRead(self, alloc, id, root.object);
        }
        if (std.mem.eql(u8, method, "surface.split")) {
            return ipcSurfaceSplit(self, alloc, id, root.object);
        }
        if (std.mem.eql(u8, method, "surface.list")) {
            return ipcSurfaceList(self, alloc, id, root.object);
        }
        if (std.mem.eql(u8, method, "surface.create")) {
            return ipcSurfaceCreate(self, alloc, id, root.object);
        }
        if (std.mem.eql(u8, method, "surface.close")) {
            return ipcSurfaceClose(self, alloc, id, root.object);
        }
        if (std.mem.eql(u8, method, "surface.focus")) {
            return ipcSurfaceFocus(self, alloc, id, root.object);
        }
        if (std.mem.eql(u8, method, "system.tree")) {
            return ipcSystemTree(self, alloc, id);
        }
        if (std.mem.eql(u8, method, "status.report_git")) {
            return ipcStatusReportGit(self, alloc, id);
        }
        if (std.mem.eql(u8, method, "status.report_ports")) {
            return ipcStatusReportPorts(self, alloc, id);
        }

        // Stubs for other known methods — return ok with null result.
        const known_stubs = [_][]const u8{};
        for (known_stubs) |stub| {
            if (std.mem.eql(u8, method, stub)) {
                return std.fmt.allocPrint(
                    alloc,
                    "{{\"ok\":true,\"result\":null,\"id\":{d}}}",
                    .{id},
                ) catch null;
            }
        }

        // Unknown method.
        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":false,\"error\":{{\"code\":\"method_not_found\",\"message\":\"unknown method\"}},\"id\":{d}}}",
            .{id},
        ) catch null;
    }

    /// Handle agent.register — registers a new AI agent and returns its agent_id.
    fn ipcAgentRegister(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const priv = self.private();
        const params_val = obj.get("params") orelse .null;
        if (params_val != .object) {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"invalid_params\",\"message\":\"params required\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        }
        const params = params_val.object;

        // Extract required fields
        const workspace = blk: {
            const v = params.get("workspace") orelse break :blk "";
            break :blk switch (v) {
                .string => |s| s,
                else => "",
            };
        };
        const tab: u32 = blk: {
            const v = params.get("tab") orelse break :blk 0;
            break :blk switch (v) {
                .integer => |n| @intCast(@max(0, n)),
                else => 0,
            };
        };
        const agent_type = blk: {
            const v = params.get("type") orelse break :blk agents.AgentType.custom;
            break :blk switch (v) {
                .string => |s| agents.AgentType.fromString(s) orelse .custom,
                else => .custom,
            };
        };
        const pid: i32 = blk: {
            const v = params.get("pid") orelse break :blk 0;
            break :blk switch (v) {
                .integer => |n| @intCast(n),
                else => 0,
            };
        };
        if (pid <= 0) {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"invalid_params\",\"message\":\"valid pid required\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        }

        const agent_id = priv.agent_registry.register(workspace, tab, agent_type, pid) catch {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"oom\",\"message\":\"out of memory\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{{\"agent_id\":\"{s}\"}},\"id\":{d}}}",
            .{ &agent_id, id },
        ) catch null;
    }

    /// Handle agent.list — returns all live registered agents.
    fn ipcAgentList(self: *Self, alloc: std.mem.Allocator, id: i64) ?[]u8 {
        const priv = self.private();

        // Clean up dead agents first
        priv.agent_registry.cleanupDead();

        var arr_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer arr_buf.deinit(alloc);

        arr_buf.appendSlice(alloc, "[") catch return null;
        for (priv.agent_registry.agents.items, 0..) |agent, idx| {
            if (idx > 0) arr_buf.appendSlice(alloc, ",") catch return null;
            var num_buf: [16]u8 = undefined;

            arr_buf.appendSlice(alloc, "{\"agent_id\":\"") catch return null;
            arr_buf.appendSlice(alloc, &agent.agent_id) catch return null;
            arr_buf.appendSlice(alloc, "\",\"workspace\":\"") catch return null;
            for (agent.workspace) |c| {
                if (c == '"' or c == '\\') arr_buf.append(alloc, '\\') catch return null;
                arr_buf.append(alloc, c) catch return null;
            }
            arr_buf.appendSlice(alloc, "\",\"tab\":") catch return null;
            const tab_str = std.fmt.bufPrint(&num_buf, "{d}", .{agent.tab}) catch return null;
            arr_buf.appendSlice(alloc, tab_str) catch return null;
            arr_buf.appendSlice(alloc, ",\"type\":\"") catch return null;
            arr_buf.appendSlice(alloc, agent.agent_type.toString()) catch return null;
            arr_buf.appendSlice(alloc, "\",\"pid\":") catch return null;
            const pid_str = std.fmt.bufPrint(&num_buf, "{d}", .{agent.pid}) catch return null;
            arr_buf.appendSlice(alloc, pid_str) catch return null;
            arr_buf.appendSlice(alloc, ",\"alive\":true}") catch return null;
        }
        arr_buf.appendSlice(alloc, "]") catch return null;

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{{\"agents\":{s}}},\"id\":{d}}}",
            .{ arr_buf.items, id },
        ) catch null;
    }

    /// Handle agent.unregister — removes an agent by PID.
    fn ipcAgentUnregister(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const priv = self.private();
        const params_val = obj.get("params") orelse .null;
        if (params_val != .object) {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"invalid_params\",\"message\":\"params required\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        }
        const pid: i32 = blk: {
            const v = params_val.object.get("pid") orelse break :blk 0;
            break :blk switch (v) {
                .integer => |n| @intCast(n),
                else => 0,
            };
        };
        if (pid <= 0) {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"invalid_params\",\"message\":\"valid pid required\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        }

        _ = priv.agent_registry.unregister(pid);

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{{}},\"id\":{d}}}",
            .{id},
        ) catch null;
    }

    /// Handle agent.terminate — sends SIGTERM to agent process and unregisters it.
    fn ipcAgentTerminate(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const priv = self.private();
        const params_val = obj.get("params") orelse .null;
        if (params_val != .object) {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"invalid_params\",\"message\":\"params required\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        }
        const pid: i32 = blk: {
            const v = params_val.object.get("pid") orelse break :blk 0;
            break :blk switch (v) {
                .integer => |n| @intCast(n),
                else => 0,
            };
        };
        if (pid <= 0) {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"invalid_params\",\"message\":\"valid pid required\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        }

        // Determine policy: per-call override > global config
        const policy: []const u8 = blk: {
            if (params_val.object.get("policy")) |pv| {
                switch (pv) {
                    .string => |s| break :blk s,
                    else => {},
                }
            }
            break :blk priv.termplex_cfg.orchestration.agent_terminate_policy;
        };

        // Send SIGTERM
        std.posix.kill(@intCast(pid), std.posix.SIG.TERM) catch {};

        // Unregister
        _ = priv.agent_registry.unregister(pid);

        // If policy is "terminate", log for now (tab closing requires workspace/tab lookup)
        if (std.mem.eql(u8, policy, "terminate")) {
            log.info("IPC: agent terminate policy=terminate, tab close not yet implemented", .{});
        }

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{{}},\"id\":{d}}}",
            .{id},
        ) catch null;
    }

    /// Handle workspace.list — returns workspace names plus explicit indices/refs.
    fn ipcWorkspaceList(self: *Self, alloc: std.mem.Allocator, id: i64) ?[]u8 {
        const priv = self.private();
        const names = priv.workspace_names.items;

        var names_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer names_buf.deinit(alloc);
        names_buf.appendSlice(alloc, "[") catch return null;

        var items_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer items_buf.deinit(alloc);
        items_buf.appendSlice(alloc, "[") catch return null;

        for (names, 0..) |name, i| {
            if (i > 0) {
                names_buf.appendSlice(alloc, ",") catch return null;
                items_buf.appendSlice(alloc, ",") catch return null;
            }

            names_buf.appendSlice(alloc, "\"") catch return null;
            for (name) |c| {
                if (c == '"' or c == '\\') {
                    names_buf.append(alloc, '\\') catch return null;
                }
                names_buf.append(alloc, c) catch return null;
            }
            names_buf.appendSlice(alloc, "\"") catch return null;

            items_buf.appendSlice(alloc, "{\"index\":") catch return null;
            var idx_buf: [16]u8 = undefined;
            const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{i}) catch return null;
            items_buf.appendSlice(alloc, idx_str) catch return null;
            items_buf.appendSlice(alloc, ",\"ref\":\"") catch return null;
            items_buf.appendSlice(alloc, idx_str) catch return null;
            items_buf.appendSlice(alloc, "\",\"name\":\"") catch return null;
            for (name) |c| {
                if (c == '"' or c == '\\') {
                    items_buf.append(alloc, '\\') catch return null;
                }
                items_buf.append(alloc, c) catch return null;
            }
            items_buf.appendSlice(alloc, "\",\"active\":") catch return null;
            items_buf.appendSlice(alloc, if (i == priv.active_workspace_idx) "true" else "false") catch return null;
            items_buf.appendSlice(alloc, "}") catch return null;
        }

        names_buf.appendSlice(alloc, "]") catch return null;
        items_buf.appendSlice(alloc, "]") catch return null;

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{{\"workspaces\":{s},\"items\":{s},\"active\":{d}}},\"id\":{d}}}",
            .{ names_buf.items, items_buf.items, priv.active_workspace_idx, id },
        ) catch null;
    }

    /// Handle workspace.create — calls addWorkspaceWithDir() and returns the workspace index.
    /// Accepts an optional "dir" field in "params". If a workspace already exists
    /// for the requested directory, that existing workspace index is returned.
    fn ipcWorkspaceCreate(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params_val = obj.get("params") orelse .null;

        // Extract optional "dir" from params
        const dir: ?[:0]const u8 = blk: {
            if (params_val != .object) break :blk null;
            const dv = params_val.object.get("dir") orelse break :blk null;
            switch (dv) {
                .string => |s| {
                    if (s.len > 0) {
                        break :blk alloc.dupeZ(u8, s) catch break :blk null;
                    }
                    break :blk null;
                },
                else => break :blk null,
            }
        };
        defer if (dir) |d| alloc.free(d);

        const new_idx = self.addWorkspaceWithDir(dir) orelse {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"oom\",\"message\":\"out of memory\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };

        // Extract optional "name" and rename if provided.
        if (params_val == .object) {
            if (params_val.object.get("name")) |nv| {
                switch (nv) {
                    .string => |s| {
                        if (s.len > 0) {
                            const name_z = alloc.dupeZ(u8, s) catch null;
                            if (name_z) |nz| {
                                defer alloc.free(nz);
                                self.renameWorkspace(new_idx, nz);
                            }
                        }
                    },
                    else => {},
                }
            }
        }

        self.addWorkspaceToAllWindows(new_idx);
        self.refreshAllWorkspaceSidebars();

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{{\"index\":{d}}},\"id\":{d}}}",
            .{ new_idx, id },
        ) catch null;
    }

    /// Handle workspace.close — removes a workspace and its tabs.
    fn ipcWorkspaceClose(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params_val = obj.get("params") orelse .null;
        if (params_val != .object) {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"invalid_params\",\"message\":\"params object required\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        }

        const ws_idx = self.resolveWorkspaceIdx(params_val.object) orelse {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"workspace not found\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };

        const priv = self.private();

        // Don't allow closing the last workspace.
        if (priv.workspace_names.items.len <= 1) {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"invalid_operation\",\"message\":\"cannot close last workspace\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        }

        // Don't allow closing the orchestration workspace.
        if (priv.orchestration_workspace_idx) |orch_idx| {
            if (ws_idx == orch_idx) {
                return std.fmt.allocPrint(
                    alloc,
                    "{{\"ok\":false,\"error\":{{\"code\":\"invalid_operation\",\"message\":\"cannot close orchestration workspace\"}},\"id\":{d}}}",
                    .{id},
                ) catch null;
            }
        }

        // Reuse the window-side close flow when a window exists so the active
        // TabView switches correctly before the workspace is removed.
        if (self.as(gtk.Application).getActiveWindow()) |active_win| {
            if (gobject.ext.cast(Window, active_win)) |win| {
                win.closeWorkspace(ws_idx);
                return std.fmt.allocPrint(
                    alloc,
                    "{{\"ok\":true,\"result\":{{}},\"id\":{d}}}",
                    .{id},
                ) catch null;
            }
        }

        // Headless fallback: remove from sidebars first, then internal state.
        self.removeWorkspaceFromAllWindows(ws_idx);
        self.removeWorkspace(ws_idx);
        self.refreshAllWorkspaceSidebars();
        self.syncActiveWorkspaceHeaders();

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{{}},\"id\":{d}}}",
            .{id},
        ) catch null;
    }

    /// Handle workspace.rename — renames an existing workspace.
    fn ipcWorkspaceRename(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params_val = obj.get("params") orelse .null;
        if (params_val != .object) {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"invalid_params\",\"message\":\"params object required\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        }

        const ws_idx = self.resolveWorkspaceIdx(params_val.object) orelse {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"workspace not found\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };

        // Extract new name.
        const new_name: [:0]const u8 = blk: {
            const nv = params_val.object.get("new_name") orelse params_val.object.get("name") orelse {
                return std.fmt.allocPrint(
                    alloc,
                    "{{\"ok\":false,\"error\":{{\"code\":\"invalid_params\",\"message\":\"new_name required\"}},\"id\":{d}}}",
                    .{id},
                ) catch null;
            };
            switch (nv) {
                .string => |s| {
                    if (s.len == 0) {
                        return std.fmt.allocPrint(
                            alloc,
                            "{{\"ok\":false,\"error\":{{\"code\":\"invalid_params\",\"message\":\"new_name cannot be empty\"}},\"id\":{d}}}",
                            .{id},
                        ) catch null;
                    }
                    break :blk alloc.dupeZ(u8, s) catch {
                        return std.fmt.allocPrint(
                            alloc,
                            "{{\"ok\":false,\"error\":{{\"code\":\"oom\",\"message\":\"out of memory\"}},\"id\":{d}}}",
                            .{id},
                        ) catch null;
                    };
                },
                else => {
                    return std.fmt.allocPrint(
                        alloc,
                        "{{\"ok\":false,\"error\":{{\"code\":\"invalid_params\",\"message\":\"new_name must be a string\"}},\"id\":{d}}}",
                        .{id},
                    ) catch null;
                },
            }
        };
        defer alloc.free(new_name);

        // Rename internal state.
        self.renameWorkspace(ws_idx, new_name);

        self.refreshAllWorkspaceSidebars();
        if (ws_idx == self.private().active_workspace_idx) {
            self.syncActiveWorkspaceHeaders();
        }

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{{}},\"id\":{d}}}",
            .{id},
        ) catch null;
    }

    /// Handle workspace.find_by_dir — returns all workspaces matching the given dir.
    fn ipcWorkspaceFindByDir(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const priv = self.private();

        // Extract "dir" from params or root
        const params_val = obj.get("params") orelse .null;
        const dir: []const u8 = blk: {
            if (params_val == .object) {
                if (params_val.object.get("dir")) |dv| {
                    switch (dv) {
                        .string => |s| break :blk s,
                        else => {},
                    }
                }
            }
            // Also try root-level "dir"
            if (obj.get("dir")) |dv| {
                switch (dv) {
                    .string => |s| break :blk s,
                    else => {},
                }
            }
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"missing_param\",\"message\":\"dir is required\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };

        var arr_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer arr_buf.deinit(alloc);

        arr_buf.appendSlice(alloc, "[") catch return null;
        var first = true;
        const resolved_dir = self.normalizeWorkspaceDir(dir) orelse {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"oom\",\"message\":\"out of memory\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };
        defer alloc.free(resolved_dir);

        for (priv.workspace_dirs.items, 0..) |ws_dir, idx| {
            if (std.mem.eql(u8, ws_dir, resolved_dir)) {
                if (!first) arr_buf.appendSlice(alloc, ",") catch return null;
                const name = priv.workspace_names.items[idx];
                const tab_count: c_int = if (idx < priv.workspace_tab_views.items.len)
                    priv.workspace_tab_views.items[idx].getNPages()
                else
                    0;
                // Build entry JSON manually
                arr_buf.appendSlice(alloc, "{\"index\":") catch return null;
                var idx_buf: [16]u8 = undefined;
                const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{idx}) catch return null;
                arr_buf.appendSlice(alloc, idx_str) catch return null;
                arr_buf.appendSlice(alloc, ",\"name\":\"") catch return null;
                for (name) |c| {
                    if (c == '"' or c == '\\') arr_buf.append(alloc, '\\') catch return null;
                    arr_buf.append(alloc, c) catch return null;
                }
                arr_buf.appendSlice(alloc, "\",\"dir\":\"") catch return null;
                for (ws_dir) |c| {
                    if (c == '"' or c == '\\') arr_buf.append(alloc, '\\') catch return null;
                    arr_buf.append(alloc, c) catch return null;
                }
                arr_buf.appendSlice(alloc, "\",\"tab_count\":") catch return null;
                var tc_buf: [16]u8 = undefined;
                const tc_str = std.fmt.bufPrint(&tc_buf, "{d}", .{tab_count}) catch return null;
                arr_buf.appendSlice(alloc, tc_str) catch return null;
                arr_buf.appendSlice(alloc, "}") catch return null;
                first = false;
            }
        }
        arr_buf.appendSlice(alloc, "]") catch return null;

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{{\"workspaces\":{s}}},\"id\":{d}}}",
            .{ arr_buf.items, id },
        ) catch null;
    }

    /// Handle workspace.select — switches the active workspace by index or name ref.
    fn ipcWorkspaceSelect(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const priv = self.private();
        const params_val = obj.get("params") orelse .null;

        var target_idx: ?u32 = null;

        if (params_val == .object) {
            // Try index first
            if (params_val.object.get("index")) |iv| {
                switch (iv) {
                    .integer => |n| {
                        if (n >= 0 and n < @as(i64, @intCast(priv.workspace_names.items.len))) {
                            target_idx = @intCast(n);
                        }
                    },
                    else => {},
                }
            }
            // Try ref (name lookup)
            if (target_idx == null) {
                if (params_val.object.get("ref")) |rv| {
                    switch (rv) {
                        .string => |name_ref| {
                            for (priv.workspace_names.items, 0..) |name, idx| {
                                if (std.mem.eql(u8, name, name_ref)) {
                                    target_idx = @intCast(idx);
                                    break;
                                }
                            }
                        },
                        else => {},
                    }
                }
            }
        }

        if (target_idx) |idx| {
            self.setActiveWorkspaceIndex(idx);
            self.markWorkspaceNotificationsRead(idx);
            self.refreshAllWorkspaceSidebars();
            self.syncActiveWorkspaceHeaders();

            // Get the active window, cast to our Window type, update sidebar and switch TabView.
            if (self.as(gtk.Application).getActiveWindow()) |active_win| {
                if (gobject.ext.cast(Window, active_win)) |win| {
                    // Switch the displayed TabView in the active window.
                    if (self.workspaceTabView(idx)) |tv| {
                        win.switchToTabView(tv);
                    }
                }
            }
        }

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":null,\"id\":{d}}}",
            .{id},
        ) catch null;
    }

    fn appendJsonEscaped(
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        text: []const u8,
    ) !void {
        for (text) |c| {
            switch (c) {
                '"' => try buf.appendSlice(alloc, "\\\""),
                '\\' => try buf.appendSlice(alloc, "\\\\"),
                '\n' => try buf.appendSlice(alloc, "\\n"),
                '\r' => try buf.appendSlice(alloc, "\\r"),
                '\t' => try buf.appendSlice(alloc, "\\t"),
                else => {
                    if (c < 0x20) {
                        const hex = "0123456789abcdef";
                        try buf.appendSlice(alloc, "\\u00");
                        try buf.append(alloc, hex[c >> 4]);
                        try buf.append(alloc, hex[c & 0xf]);
                    } else {
                        try buf.append(alloc, c);
                    }
                },
            }
        }
    }

    fn appendJsonString(
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        text: []const u8,
    ) !void {
        try buf.append(alloc, '"');
        try appendJsonEscaped(buf, alloc, text);
        try buf.append(alloc, '"');
    }

    fn appendOptionalJsonString(
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        text: ?[]const u8,
    ) !void {
        if (text) |value| {
            try appendJsonString(buf, alloc, value);
        } else {
            try buf.appendSlice(alloc, "null");
        }
    }

    fn appendJsonInt(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, value: anytype) !void {
        var num_buf: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&num_buf, "{d}", .{value});
        try buf.appendSlice(alloc, text);
    }

    fn appendOptionalJsonInt(
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        value: ?i32,
    ) !void {
        if (value) |int_value| {
            try appendJsonInt(buf, alloc, int_value);
        } else {
            try buf.appendSlice(alloc, "null");
        }
    }

    fn jsonStringParam(params: std.json.ObjectMap, name: []const u8) ?[]const u8 {
        const value = params.get(name) orelse return null;
        return switch (value) {
            .string => |text| if (text.len > 0) text else null,
            else => null,
        };
    }

    fn jsonI32Param(params: std.json.ObjectMap, name: []const u8) ?i32 {
        const value = params.get(name) orelse return null;
        return switch (value) {
            .integer => |n| @intCast(n),
            else => null,
        };
    }

    fn jsonI64Param(params: std.json.ObjectMap, name: []const u8) ?i64 {
        const value = params.get(name) orelse return null;
        return switch (value) {
            .integer => |n| n,
            else => null,
        };
    }

    fn jsonBoolParam(params: std.json.ObjectMap, name: []const u8, default_value: bool) bool {
        const value = params.get(name) orelse return default_value;
        return switch (value) {
            .bool => |flag| flag,
            else => default_value,
        };
    }

    fn jsonLimitParam(params: std.json.ObjectMap, name: []const u8, default_value: u32, max_value: u32) u32 {
        const value = params.get(name) orelse return default_value;
        const raw: u32 = switch (value) {
            .integer => |n| if (n > 0) @intCast(n) else 1,
            else => default_value,
        };
        return @min(raw, max_value);
    }

    fn appendDashboardWorkspaceJson(
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        workspace: DashboardWorkspace,
    ) !void {
        try buf.appendSlice(alloc, "{\"index\":");
        try appendJsonInt(buf, alloc, workspace.index);
        try buf.appendSlice(alloc, ",\"id\":");
        try appendJsonString(buf, alloc, workspace.id);
        try buf.appendSlice(alloc, ",\"name\":");
        try appendJsonString(buf, alloc, workspace.name);
        try buf.appendSlice(alloc, ",\"dir\":");
        try appendJsonString(buf, alloc, workspace.dir);
        try buf.appendSlice(alloc, ",\"current_pwd\":");
        try appendJsonString(buf, alloc, workspace.current_pwd);
        try buf.appendSlice(alloc, ",\"tab_count\":");
        try appendJsonInt(buf, alloc, workspace.tab_count);
        try buf.appendSlice(alloc, ",\"active_tab\":");
        if (workspace.active_tab) |idx| {
            try appendJsonInt(buf, alloc, idx);
        } else {
            try buf.appendSlice(alloc, "null");
        }
        try buf.appendSlice(alloc, ",\"active_history_id\":");
        try appendOptionalJsonString(buf, alloc, workspace.active_history_id);
        try buf.append(alloc, '}');
    }

    fn appendDashboardGitJson(
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        git: DashboardGit,
    ) !void {
        try buf.appendSlice(alloc, "{\"is_repo\":");
        try buf.appendSlice(alloc, if (git.status.is_repo) "true" else "false");
        try buf.appendSlice(alloc, ",\"root\":");
        try appendOptionalJsonString(buf, alloc, git.status.root);
        try buf.appendSlice(alloc, ",\"branch\":");
        try appendOptionalJsonString(buf, alloc, git.status.branch);
        try buf.appendSlice(alloc, ",\"remote_url\":");
        try appendOptionalJsonString(buf, alloc, git.status.remote_url);
        try buf.appendSlice(alloc, ",\"dirty\":");
        try buf.appendSlice(alloc, if (git.status.dirty) "true" else "false");
        try buf.appendSlice(alloc, ",\"staged_count\":");
        try appendJsonInt(buf, alloc, git.staged_count);
        try buf.appendSlice(alloc, ",\"unstaged_count\":");
        try appendJsonInt(buf, alloc, git.unstaged_count);
        try buf.append(alloc, '}');
    }

    fn appendDashboardStorageJson(
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        storage: DashboardStorage,
    ) !void {
        try buf.appendSlice(alloc, "{\"history_enabled\":");
        try buf.appendSlice(alloc, if (storage.history_enabled) "true" else "false");
        try buf.appendSlice(alloc, ",\"restore_mode\":");
        try appendJsonString(buf, alloc, storage.restore_mode);
        try buf.appendSlice(alloc, ",\"total_bytes\":");
        try appendJsonInt(buf, alloc, storage.total_bytes);
        try buf.appendSlice(alloc, ",\"transcript_bytes\":");
        try appendJsonInt(buf, alloc, storage.transcript_bytes);
        try buf.appendSlice(alloc, ",\"db_bytes\":");
        try appendJsonInt(buf, alloc, storage.db_bytes);
        try buf.appendSlice(alloc, ",\"transcript_file_count\":");
        try appendJsonInt(buf, alloc, storage.transcript_file_count);
        try buf.appendSlice(alloc, ",\"project_count\":");
        try appendJsonInt(buf, alloc, storage.project_count);
        try buf.appendSlice(alloc, ",\"surface_count\":");
        try appendJsonInt(buf, alloc, storage.surface_count);
        try buf.appendSlice(alloc, ",\"command_count\":");
        try appendJsonInt(buf, alloc, storage.command_count);
        try buf.appendSlice(alloc, ",\"task_count\":");
        try appendJsonInt(buf, alloc, storage.task_count);
        try buf.append(alloc, '}');
    }

    fn appendDashboardStatusJson(
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        status: DashboardStatus,
    ) !void {
        try buf.appendSlice(alloc, "{\"workspace\":");
        try appendDashboardWorkspaceJson(buf, alloc, status.workspace);
        try buf.appendSlice(alloc, ",\"recent_commands\":[");
        for (status.recent_commands.items, 0..) |item, index| {
            if (index > 0) try buf.append(alloc, ',');
            try appendCommandRecordJson(buf, alloc, item);
        }
        try buf.appendSlice(alloc, "],\"tasks\":[");
        for (status.tasks.items, 0..) |item, index| {
            if (index > 0) try buf.append(alloc, ',');
            try appendTaskRecordJson(buf, alloc, item);
        }
        try buf.appendSlice(alloc, "],\"git\":");
        try appendDashboardGitJson(buf, alloc, status.git);
        try buf.appendSlice(alloc, ",\"storage\":");
        try appendDashboardStorageJson(buf, alloc, status.storage);
        try buf.append(alloc, '}');
    }

    fn appendCommandRecordJson(
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        item: terminal_history_db.CommandRecord,
    ) !void {
        try buf.appendSlice(alloc, "{\"id\":");
        try appendJsonInt(buf, alloc, item.id);
        try buf.appendSlice(alloc, ",\"history_id\":");
        try appendJsonString(buf, alloc, item.history_id);
        try buf.appendSlice(alloc, ",\"workspace_id\":");
        try appendJsonString(buf, alloc, item.workspace_id);
        try buf.appendSlice(alloc, ",\"workspace_name\":");
        try appendJsonString(buf, alloc, item.workspace_name);
        try buf.appendSlice(alloc, ",\"workspace_dir\":");
        try appendJsonString(buf, alloc, item.workspace_dir);
        try buf.appendSlice(alloc, ",\"command\":");
        try appendJsonString(buf, alloc, item.command);
        try buf.appendSlice(alloc, ",\"started_at\":");
        try appendJsonString(buf, alloc, item.started_at);
        try buf.appendSlice(alloc, ",\"ended_at\":");
        try appendOptionalJsonString(buf, alloc, item.ended_at);
        try buf.appendSlice(alloc, ",\"exit_code\":");
        try appendOptionalJsonInt(buf, alloc, item.exit_code);
        try buf.appendSlice(alloc, ",\"source\":");
        try appendJsonString(buf, alloc, item.source);
        try buf.appendSlice(alloc, "}");
    }

    fn appendTaskRecordJson(
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        item: terminal_history_db.TaskRecord,
    ) !void {
        try buf.appendSlice(alloc, "{\"id\":");
        try appendJsonInt(buf, alloc, item.id);
        try buf.appendSlice(alloc, ",\"workspace_id\":");
        try appendJsonString(buf, alloc, item.workspace_id);
        try buf.appendSlice(alloc, ",\"name\":");
        try appendJsonString(buf, alloc, item.name);
        try buf.appendSlice(alloc, ",\"command\":");
        try appendJsonString(buf, alloc, item.command);
        try buf.appendSlice(alloc, ",\"working_directory\":");
        try appendOptionalJsonString(buf, alloc, item.working_directory);
        try buf.appendSlice(alloc, ",\"created_at\":");
        try appendJsonString(buf, alloc, item.created_at);
        try buf.appendSlice(alloc, ",\"updated_at\":");
        try appendJsonString(buf, alloc, item.updated_at);
        try buf.appendSlice(alloc, ",\"last_run_at\":");
        try appendOptionalJsonString(buf, alloc, item.last_run_at);
        try buf.appendSlice(alloc, ",\"run_count\":");
        try appendJsonInt(buf, alloc, item.run_count);
        try buf.append(alloc, '}');
    }

    fn dashboardParams(obj: std.json.ObjectMap) std.json.ObjectMap {
        const params_val = obj.get("params") orelse .null;
        return if (params_val == .object) params_val.object else obj;
    }

    fn dashboardWorkspaceIndex(self: *Self, params: std.json.ObjectMap) ?u32 {
        const explicit_workspace =
            params.get("workspace") != null or
            params.get("ref") != null or
            params.get("index") != null;
        if (!explicit_workspace) return self.private().active_workspace_idx;
        return self.resolveWorkspaceIdx(params);
    }

    fn ipcDashboardError(alloc: std.mem.Allocator, id: i64, code: []const u8, message: []const u8) ?[]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);
        buf.appendSlice(alloc, "{\"ok\":false,\"error\":{\"code\":") catch return null;
        appendJsonString(&buf, alloc, code) catch return null;
        buf.appendSlice(alloc, ",\"message\":") catch return null;
        appendJsonString(&buf, alloc, message) catch return null;
        buf.appendSlice(alloc, "},\"id\":") catch return null;
        appendJsonInt(&buf, alloc, id) catch return null;
        buf.appendSlice(alloc, "}") catch return null;
        return buf.toOwnedSlice(alloc) catch null;
    }

    fn ipcDashboardStatus(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params = dashboardParams(obj);
        const workspace_idx = self.dashboardWorkspaceIndex(params) orelse {
            return ipcDashboardError(alloc, id, "not_found", "workspace not found");
        };
        const limit = jsonLimitParam(params, "limit", 8, 25);

        const status = self.workspaceDashboardStatus(alloc, workspace_idx, limit) catch |err| {
            log.warn("failed to build dashboard status: {}", .{err});
            return ipcDashboardError(alloc, id, "dashboard_status_failed", "failed to read dashboard status");
        };
        defer status.deinit(alloc);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);
        appendDashboardStatusJson(&buf, alloc, status) catch return null;
        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{s},\"id\":{d}}}",
            .{ buf.items, id },
        ) catch null;
    }

    fn ipcDashboardShow(self: *Self, alloc: std.mem.Allocator, id: i64) ?[]u8 {
        if (self.as(gtk.Application).getActiveWindow()) |active_win| {
            if (gobject.ext.cast(Window, active_win)) |win| {
                win.toggleWorkspaceDashboard();
                return std.fmt.allocPrint(
                    alloc,
                    "{{\"ok\":true,\"result\":{{\"shown\":true}},\"id\":{d}}}",
                    .{id},
                ) catch null;
            }
        }
        return ipcDashboardError(alloc, id, "no_window", "no active window");
    }

    fn taskParams(obj: std.json.ObjectMap) std.json.ObjectMap {
        const params_val = obj.get("params") orelse .null;
        return if (params_val == .object) params_val.object else obj;
    }

    fn ipcTaskError(alloc: std.mem.Allocator, id: i64, code: []const u8, message: []const u8) ?[]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);
        buf.appendSlice(alloc, "{\"ok\":false,\"error\":{\"code\":") catch return null;
        appendJsonString(&buf, alloc, code) catch return null;
        buf.appendSlice(alloc, ",\"message\":") catch return null;
        appendJsonString(&buf, alloc, message) catch return null;
        buf.appendSlice(alloc, "},\"id\":") catch return null;
        appendJsonInt(&buf, alloc, id) catch return null;
        buf.append(alloc, '}') catch return null;
        return buf.toOwnedSlice(alloc) catch null;
    }

    fn taskWorkspaceId(self: *Self, alloc: std.mem.Allocator, params: std.json.ObjectMap) !struct {
        index: u32,
        id: []u8,
    } {
        const workspace_idx = self.resolveWorkspaceIdx(params) orelse return error.NotFound;
        return .{
            .index = workspace_idx,
            .id = try self.workspaceIdString(alloc, workspace_idx),
        };
    }

    fn taskDatabase(self: *Self) !*terminal_history_db.Database {
        const priv = self.private();
        if (priv.terminal_history_db) |*db| return db;
        return error.TaskUnavailable;
    }

    pub fn defaultTaskNameFromCommand(
        alloc: std.mem.Allocator,
        command: []const u8,
        command_id: i64,
    ) ![]u8 {
        var tokens = std.mem.tokenizeAny(u8, command, " \t\r\n");
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(alloc);

        var count: u8 = 0;
        while (tokens.next()) |token| {
            if (count >= 3) break;
            if (count > 0) try buf.append(alloc, ' ');
            try buf.appendSlice(alloc, token);
            count += 1;
        }

        if (buf.items.len == 0) {
            return std.fmt.allocPrint(alloc, "command {d}", .{command_id});
        }

        return try buf.toOwnedSlice(alloc);
    }

    pub fn promoteCommandHistoryTask(
        self: *Self,
        alloc: std.mem.Allocator,
        command_id: i64,
        workspace_idx: ?u32,
        name: []const u8,
    ) !terminal_history_db.TaskRecord {
        if (name.len == 0) return error.InvalidTaskName;
        if (command_id <= 0) return error.InvalidCommandId;

        const db = try self.taskDatabase();

        var command = try db.getCommand(command_id);
        defer command.deinit(std.heap.c_allocator);

        if (workspace_idx) |idx| {
            const workspace_id = try self.workspaceIdString(alloc, idx);
            defer alloc.free(workspace_id);
            if (!std.mem.eql(u8, workspace_id, command.workspace_id)) {
                return error.WorkspaceMismatch;
            }
        }

        var surface = db.getSurface(command.history_id) catch |err| switch (err) {
            error.NotFound => null,
            else => return err,
        };
        defer if (surface) |*record| record.deinit(std.heap.c_allocator);

        const working_directory = if (surface) |record|
            record.working_directory
        else
            command.workspace_dir;

        const timestamp = self.terminalHistoryTimestamp(alloc) orelse return error.TimestampFailed;
        defer alloc.free(timestamp);

        try db.upsertTask(.{
            .workspace_id = command.workspace_id,
            .name = name,
            .command = command.command,
            .working_directory = working_directory,
            .timestamp = timestamp,
        });
        try db.commitIfNeeded();

        return try db.getTask(command.workspace_id, name);
    }

    pub fn loadWorkspaceTask(
        self: *Self,
        alloc: std.mem.Allocator,
        workspace_idx: u32,
        name: []const u8,
    ) !terminal_history_db.TaskRecord {
        if (name.len == 0) return error.InvalidTaskName;

        const workspace_id = try self.workspaceIdString(alloc, workspace_idx);
        defer alloc.free(workspace_id);

        const db = try self.taskDatabase();
        return try db.getTask(workspace_id, name);
    }

    pub fn markWorkspaceTaskRun(
        self: *Self,
        alloc: std.mem.Allocator,
        workspace_idx: u32,
        name: []const u8,
    ) !terminal_history_db.TaskRecord {
        if (name.len == 0) return error.InvalidTaskName;

        const workspace_id = try self.workspaceIdString(alloc, workspace_idx);
        defer alloc.free(workspace_id);

        const db = try self.taskDatabase();
        const timestamp = self.terminalHistoryTimestamp(alloc) orelse return error.TimestampFailed;
        defer alloc.free(timestamp);

        try db.markTaskRun(workspace_id, name, timestamp);
        try db.commitIfNeeded();
        return try db.getTask(workspace_id, name);
    }

    pub fn deleteWorkspaceTask(
        self: *Self,
        alloc: std.mem.Allocator,
        workspace_idx: u32,
        name: []const u8,
    ) !void {
        if (name.len == 0) return error.InvalidTaskName;

        const workspace_id = try self.workspaceIdString(alloc, workspace_idx);
        defer alloc.free(workspace_id);

        const db = try self.taskDatabase();
        var task = try db.getTask(workspace_id, name);
        task.deinit(std.heap.c_allocator);

        try db.deleteTask(workspace_id, name);
        try db.commitIfNeeded();
    }

    fn ipcTaskList(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params = taskParams(obj);
        const workspace = self.taskWorkspaceId(alloc, params) catch |err| switch (err) {
            error.NotFound => return ipcTaskError(alloc, id, "not_found", "workspace not found"),
            else => return ipcTaskError(alloc, id, "task_failed", "failed to resolve workspace"),
        };
        defer alloc.free(workspace.id);

        const db = self.taskDatabase() catch {
            return ipcTaskError(alloc, id, "task_unavailable", "task storage is unavailable");
        };

        const limit = jsonLimitParam(params, "limit", 50, 200);
        const tasks = db.listTasks(workspace.id, limit) catch |err| {
            log.warn("failed to list workspace tasks: {}", .{err});
            return ipcTaskError(alloc, id, "task_list_failed", "failed to list tasks");
        };
        defer tasks.deinit(std.heap.c_allocator);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);
        buf.appendSlice(alloc, "{\"workspace\":") catch return null;
        appendJsonInt(&buf, alloc, workspace.index) catch return null;
        buf.appendSlice(alloc, ",\"workspace_id\":") catch return null;
        appendJsonString(&buf, alloc, workspace.id) catch return null;
        buf.appendSlice(alloc, ",\"items\":[") catch return null;
        for (tasks.items, 0..) |item, index| {
            if (index > 0) buf.append(alloc, ',') catch return null;
            appendTaskRecordJson(&buf, alloc, item) catch return null;
        }
        buf.appendSlice(alloc, "]}") catch return null;

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{s},\"id\":{d}}}",
            .{ buf.items, id },
        ) catch null;
    }

    fn ipcTaskAdd(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params = taskParams(obj);
        const name = jsonStringParam(params, "name") orelse {
            return ipcTaskError(alloc, id, "missing_param", "name is required");
        };
        const command = jsonStringParam(params, "command") orelse {
            return ipcTaskError(alloc, id, "missing_param", "command is required");
        };
        const workspace = self.taskWorkspaceId(alloc, params) catch |err| switch (err) {
            error.NotFound => return ipcTaskError(alloc, id, "not_found", "workspace not found"),
            else => return ipcTaskError(alloc, id, "task_failed", "failed to resolve workspace"),
        };
        defer alloc.free(workspace.id);

        const db = self.taskDatabase() catch {
            return ipcTaskError(alloc, id, "task_unavailable", "task storage is unavailable");
        };

        self.upsertTerminalHistoryProject(workspace.index);

        const timestamp = self.terminalHistoryTimestamp(alloc) orelse {
            return ipcTaskError(alloc, id, "task_failed", "failed to create task timestamp");
        };
        defer alloc.free(timestamp);

        db.upsertTask(.{
            .workspace_id = workspace.id,
            .name = name,
            .command = command,
            .working_directory = jsonStringParam(params, "dir") orelse jsonStringParam(params, "working_directory"),
            .timestamp = timestamp,
        }) catch |err| {
            log.warn("failed to upsert workspace task: {}", .{err});
            return ipcTaskError(alloc, id, "task_add_failed", "failed to save task");
        };
        db.commitIfNeeded() catch |err| {
            log.warn("failed to commit workspace task: {}", .{err});
        };

        var task = db.getTask(workspace.id, name) catch |err| {
            log.warn("failed to reload workspace task: {}", .{err});
            return ipcTaskError(alloc, id, "task_add_failed", "failed to load saved task");
        };
        defer task.deinit(std.heap.c_allocator);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);
        appendTaskRecordJson(&buf, alloc, task) catch return null;

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{s},\"id\":{d}}}",
            .{ buf.items, id },
        ) catch null;
    }

    fn ipcTaskPromote(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params = taskParams(obj);
        const name = jsonStringParam(params, "name") orelse {
            return ipcTaskError(alloc, id, "missing_param", "name is required");
        };
        const command_id = jsonI64Param(params, "command_id") orelse {
            return ipcTaskError(alloc, id, "missing_param", "command_id is required");
        };
        if (command_id <= 0) {
            return ipcTaskError(alloc, id, "invalid_params", "command_id must be positive");
        }

        var workspace_idx: ?u32 = null;
        if (params.get("workspace") != null or params.get("ref") != null or params.get("index") != null) {
            const workspace = self.taskWorkspaceId(alloc, params) catch |err| switch (err) {
                error.NotFound => return ipcTaskError(alloc, id, "not_found", "workspace not found"),
                else => return ipcTaskError(alloc, id, "task_failed", "failed to resolve workspace"),
            };
            defer alloc.free(workspace.id);
            workspace_idx = workspace.index;
        }

        var task = self.promoteCommandHistoryTask(alloc, command_id, workspace_idx, name) catch |err| {
            log.warn("failed to promote command history row to workspace task: {}", .{err});
            return switch (err) {
                error.NotFound => ipcTaskError(alloc, id, "not_found", "command history row not found"),
                error.TaskUnavailable => ipcTaskError(alloc, id, "task_unavailable", "task storage is unavailable"),
                error.WorkspaceMismatch => ipcTaskError(alloc, id, "invalid_params", "command does not belong to workspace"),
                error.InvalidTaskName => ipcTaskError(alloc, id, "missing_param", "name is required"),
                error.InvalidCommandId => ipcTaskError(alloc, id, "invalid_params", "command_id must be positive"),
                else => ipcTaskError(alloc, id, "task_promote_failed", "failed to save promoted task"),
            };
        };
        defer task.deinit(std.heap.c_allocator);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);
        appendTaskRecordJson(&buf, alloc, task) catch return null;

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{s},\"id\":{d}}}",
            .{ buf.items, id },
        ) catch null;
    }

    fn ipcTaskDelete(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params = taskParams(obj);
        const name = jsonStringParam(params, "name") orelse {
            return ipcTaskError(alloc, id, "missing_param", "name is required");
        };
        const workspace = self.taskWorkspaceId(alloc, params) catch |err| switch (err) {
            error.NotFound => return ipcTaskError(alloc, id, "not_found", "workspace not found"),
            else => return ipcTaskError(alloc, id, "task_failed", "failed to resolve workspace"),
        };
        defer alloc.free(workspace.id);

        const db = self.taskDatabase() catch {
            return ipcTaskError(alloc, id, "task_unavailable", "task storage is unavailable");
        };

        var task = db.getTask(workspace.id, name) catch |err| switch (err) {
            error.NotFound => return ipcTaskError(alloc, id, "not_found", "task not found"),
            else => {
                log.warn("failed to load workspace task for deletion: {}", .{err});
                return ipcTaskError(alloc, id, "task_delete_failed", "failed to load task");
            },
        };
        task.deinit(std.heap.c_allocator);

        db.deleteTask(workspace.id, name) catch |err| {
            log.warn("failed to delete workspace task: {}", .{err});
            return ipcTaskError(alloc, id, "task_delete_failed", "failed to delete task");
        };
        db.commitIfNeeded() catch |err| {
            log.warn("failed to commit workspace task deletion: {}", .{err});
        };

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);
        buf.appendSlice(alloc, "{\"deleted\":true,\"workspace\":") catch return null;
        appendJsonInt(&buf, alloc, workspace.index) catch return null;
        buf.appendSlice(alloc, ",\"name\":") catch return null;
        appendJsonString(&buf, alloc, name) catch return null;
        buf.append(alloc, '}') catch return null;

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{s},\"id\":{d}}}",
            .{ buf.items, id },
        ) catch null;
    }

    fn writeTaskCommandToSurface(
        self: *Self,
        alloc: std.mem.Allocator,
        surface_target: ResolvedSurfaceTarget,
        command: []const u8,
    ) !void {
        _ = self;
        const command_line = try std.fmt.allocPrint(alloc, "{s}\n", .{command});
        defer alloc.free(command_line);

        surface_target.surface.ensureInitializedFromAllocation("ipc-task-run");
        const core_surface = surface_target.surface.core() orelse return error.NotFound;
        const msg = try termio.Message.writeReq(core_surface.alloc, command_line);
        core_surface.io.queueMessage(msg, .unlocked);
    }

    fn focusTaskSurface(self: *Self, surface_target: ResolvedSurfaceTarget) !void {
        const active_win = self.as(gtk.Application).getActiveWindow() orelse return error.NoWindow;
        const win = gobject.ext.cast(Window, active_win) orelse return error.NoWindow;

        if (surface_target.workspace_idx != self.private().active_workspace_idx) {
            self.setActiveWorkspaceIndex(surface_target.workspace_idx);
            self.markWorkspaceNotificationsRead(surface_target.workspace_idx);
            self.refreshAllWorkspaceSidebars();
            self.syncActiveWorkspaceHeaders();
            if (self.workspaceTabView(surface_target.workspace_idx)) |target_view| {
                win.switchToTabView(target_view);
            }
        }

        const tab_view = self.workspaceTabView(surface_target.workspace_idx) orelse return error.NotFound;
        tab_view.setSelectedPage(surface_target.page);
        surface_target.tab.getSplitTree().setLastFocusedSurface(surface_target.surface);
        surface_target.surface.grabFocus();
    }

    fn ipcTaskRun(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params = taskParams(obj);
        const name = jsonStringParam(params, "name") orelse {
            return ipcTaskError(alloc, id, "missing_param", "name is required");
        };
        const workspace = self.taskWorkspaceId(alloc, params) catch |err| switch (err) {
            error.NotFound => return ipcTaskError(alloc, id, "not_found", "workspace not found"),
            else => return ipcTaskError(alloc, id, "task_failed", "failed to resolve workspace"),
        };
        defer alloc.free(workspace.id);

        const db = self.taskDatabase() catch {
            return ipcTaskError(alloc, id, "task_unavailable", "task storage is unavailable");
        };

        var task = db.getTask(workspace.id, name) catch |err| switch (err) {
            error.NotFound => return ipcTaskError(alloc, id, "not_found", "task not found"),
            else => {
                log.warn("failed to load workspace task for run: {}", .{err});
                return ipcTaskError(alloc, id, "task_run_failed", "failed to load task");
            },
        };
        defer task.deinit(std.heap.c_allocator);

        const surface_ref = self.resolveSurfaceRef(params, true) orelse {
            return ipcTaskError(alloc, id, "not_found", "surface not found");
        };
        if (surface_ref.workspace_idx != workspace.index) {
            return ipcTaskError(alloc, id, "invalid_params", "surface workspace does not match task workspace");
        }
        const surface_target = self.resolveSurfaceTarget(surface_ref) orelse {
            return ipcTaskError(alloc, id, "not_found", "surface not found");
        };

        self.focusTaskSurface(surface_target) catch |err| switch (err) {
            error.NoWindow => return ipcTaskError(alloc, id, "no_window", "no active window"),
            else => return ipcTaskError(alloc, id, "not_found", "surface not found"),
        };

        self.writeTaskCommandToSurface(alloc, surface_target, task.command) catch |err| {
            log.warn("failed to write workspace task command: {}", .{err});
            return ipcTaskError(alloc, id, "task_run_failed", "failed to send task command");
        };

        const timestamp = self.terminalHistoryTimestamp(alloc) orelse {
            return ipcTaskError(alloc, id, "task_run_failed", "failed to create task timestamp");
        };
        defer alloc.free(timestamp);
        db.markTaskRun(workspace.id, name, timestamp) catch |err| {
            log.warn("failed to mark workspace task run: {}", .{err});
        };
        db.commitIfNeeded() catch |err| {
            log.warn("failed to commit workspace task run: {}", .{err});
        };

        var updated_task = db.getTask(workspace.id, name) catch |err| {
            log.warn("failed to reload workspace task after run: {}", .{err});
            return ipcTaskError(alloc, id, "task_run_failed", "failed to load task after run");
        };
        defer updated_task.deinit(std.heap.c_allocator);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);
        buf.appendSlice(alloc, "{\"ran\":true,\"workspace\":") catch return null;
        appendJsonInt(&buf, alloc, surface_target.workspace_idx) catch return null;
        buf.appendSlice(alloc, ",\"tab\":") catch return null;
        appendJsonInt(&buf, alloc, surface_target.tab_idx) catch return null;
        buf.appendSlice(alloc, ",\"surface\":") catch return null;
        appendJsonInt(&buf, alloc, surface_target.surface_idx) catch return null;
        buf.appendSlice(alloc, ",\"task\":") catch return null;
        appendTaskRecordJson(&buf, alloc, updated_task) catch return null;
        buf.append(alloc, '}') catch return null;

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{s},\"id\":{d}}}",
            .{ buf.items, id },
        ) catch null;
    }

    fn ipcHistorySearch(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params_val = obj.get("params") orelse .null;
        const params = if (params_val == .object) params_val.object else obj;

        var workspace_id: ?[]u8 = null;
        defer if (workspace_id) |value| alloc.free(value);

        if (params.get("workspace") != null or params.get("ref") != null or params.get("index") != null) {
            const workspace_idx = self.resolveWorkspaceIdx(params) orelse {
                return std.fmt.allocPrint(
                    alloc,
                    "{{\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"workspace not found\"}},\"id\":{d}}}",
                    .{id},
                ) catch null;
            };
            workspace_id = self.workspaceIdString(alloc, workspace_idx) catch {
                return std.fmt.allocPrint(
                    alloc,
                    "{{\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"workspace not found\"}},\"id\":{d}}}",
                    .{id},
                ) catch null;
            };
        }

        const query = terminal_history_db.SearchQuery{
            .text = jsonStringParam(params, "query") orelse jsonStringParam(params, "text"),
            .workspace_id = workspace_id orelse jsonStringParam(params, "workspace_id"),
            .workspace_name = jsonStringParam(params, "workspace_name"),
            .workspace_dir = jsonStringParam(params, "dir") orelse jsonStringParam(params, "workspace_dir"),
            .source = jsonStringParam(params, "source"),
            .exit_code = jsonI32Param(params, "exit_code"),
            .started_after = jsonStringParam(params, "started_after"),
            .started_before = jsonStringParam(params, "started_before"),
            .limit = jsonLimitParam(params, "limit", 50, 200),
        };

        const list = self.searchTerminalCommands(query) catch |err| switch (err) {
            error.HistoryUnavailable => {
                return std.fmt.allocPrint(
                    alloc,
                    "{{\"ok\":true,\"result\":{{\"items\":[],\"history_enabled\":false}},\"id\":{d}}}",
                    .{id},
                ) catch null;
            },
            else => {
                log.warn("failed to search command history: {}", .{err});
                return std.fmt.allocPrint(
                    alloc,
                    "{{\"ok\":false,\"error\":{{\"code\":\"history_search_failed\",\"message\":\"failed to search command history\"}},\"id\":{d}}}",
                    .{id},
                ) catch null;
            },
        };
        defer list.deinit(std.heap.c_allocator);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);
        buf.appendSlice(alloc, "{\"items\":[") catch return null;
        for (list.items, 0..) |item, index| {
            if (index > 0) buf.appendSlice(alloc, ",") catch return null;
            appendCommandRecordJson(&buf, alloc, item) catch return null;
        }
        buf.appendSlice(alloc, "],\"history_enabled\":true}") catch return null;

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{s},\"id\":{d}}}",
            .{ buf.items, id },
        ) catch null;
    }

    fn ipcHistoryShow(self: *Self, alloc: std.mem.Allocator, id: i64) ?[]u8 {
        if (self.as(gtk.Application).getActiveWindow()) |active_win| {
            if (gobject.ext.cast(Window, active_win)) |win| {
                win.toggleCommandHistory();
                return std.fmt.allocPrint(
                    alloc,
                    "{{\"ok\":true,\"result\":{{\"shown\":true}},\"id\":{d}}}",
                    .{id},
                ) catch null;
            }
        }

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":false,\"error\":{{\"code\":\"no_window\",\"message\":\"no active window\"}},\"id\":{d}}}",
            .{id},
        ) catch null;
    }

    fn historyParams(obj: std.json.ObjectMap) std.json.ObjectMap {
        const params_val = obj.get("params") orelse .null;
        return if (params_val == .object) params_val.object else obj;
    }

    fn ipcHistoryError(alloc: std.mem.Allocator, id: i64, code: []const u8, message: []const u8) ?[]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);
        buf.appendSlice(alloc, "{\"ok\":false,\"error\":{\"code\":") catch return null;
        appendJsonString(&buf, alloc, code) catch return null;
        buf.appendSlice(alloc, ",\"message\":") catch return null;
        appendJsonString(&buf, alloc, message) catch return null;
        buf.appendSlice(alloc, "},\"id\":") catch return null;
        appendJsonInt(&buf, alloc, id) catch return null;
        buf.appendSlice(alloc, "}") catch return null;
        return buf.toOwnedSlice(alloc) catch null;
    }

    fn transcriptSurfaceForParams(
        self: *Self,
        alloc: std.mem.Allocator,
        params: std.json.ObjectMap,
    ) !terminal_history_db.SurfaceRecord {
        const history_id = jsonStringParam(params, "history_id") orelse return error.MissingHistoryId;
        var surface = try self.transcriptSurfaceForHistoryId(history_id);
        errdefer surface.deinit(std.heap.c_allocator);

        if (params.get("workspace") != null or params.get("ref") != null or params.get("index") != null) {
            const workspace_idx = self.resolveWorkspaceIdx(params) orelse return error.NotFound;
            const workspace_id = try self.workspaceIdString(alloc, workspace_idx);
            defer alloc.free(workspace_id);
            if (!std.mem.eql(u8, workspace_id, surface.workspace_id)) return error.NotFound;
        }

        return surface;
    }

    fn transcriptSurfaceForHistoryId(self: *Self, history_id: []const u8) !terminal_history_db.SurfaceRecord {
        const priv = self.private();
        var db = if (priv.terminal_history_db) |*database| database else return error.HistoryUnavailable;
        return try db.getSurface(history_id);
    }

    fn appendTranscriptCommandArrayJson(
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        commands: terminal_history_db.CommandList,
    ) !void {
        try buf.append(alloc, '[');
        for (commands.items, 0..) |command, index| {
            if (index > 0) try buf.append(alloc, ',');
            try appendCommandRecordJson(buf, alloc, command);
        }
        try buf.append(alloc, ']');
    }

    fn appendTranscriptSurfaceJson(
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        surface: terminal_history_db.SurfaceRecord,
        output: []const u8,
        commands: terminal_history_db.CommandList,
    ) !void {
        try buf.appendSlice(alloc, "{\"history_id\":");
        try appendJsonString(buf, alloc, surface.history_id);
        try buf.appendSlice(alloc, ",\"workspace_id\":");
        try appendJsonString(buf, alloc, surface.workspace_id);
        try buf.appendSlice(alloc, ",\"workspace_name\":");
        try appendJsonString(buf, alloc, surface.workspace_name);
        try buf.appendSlice(alloc, ",\"workspace_dir\":");
        try appendJsonString(buf, alloc, surface.workspace_dir);
        try buf.appendSlice(alloc, ",\"working_directory\":");
        try appendJsonString(buf, alloc, surface.working_directory);
        try buf.appendSlice(alloc, ",\"transcript_path\":");
        try appendJsonString(buf, alloc, surface.transcript_path);
        try buf.appendSlice(alloc, ",\"status\":");
        try appendJsonString(buf, alloc, surface.status);
        try buf.appendSlice(alloc, ",\"last_exit_code\":");
        try appendOptionalJsonInt(buf, alloc, surface.last_exit_code);
        try buf.appendSlice(alloc, ",\"output\":");
        try appendJsonString(buf, alloc, output);
        try buf.appendSlice(alloc, ",\"commands\":");
        try appendTranscriptCommandArrayJson(buf, alloc, commands);
        try buf.append(alloc, '}');
    }

    fn readSanitizedTranscriptForSurface(
        self: *Self,
        alloc: std.mem.Allocator,
        surface: terminal_history_db.SurfaceRecord,
    ) ![]u8 {
        const full_text = try terminal_history.readTranscript(alloc, surface.transcript_path, self.terminalHistoryOptions());
        defer alloc.free(full_text);
        return try transcript_view.stripControlSequences(alloc, full_text);
    }

    fn ipcHistoryTranscript(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params = historyParams(obj);
        var surface = self.transcriptSurfaceForParams(alloc, params) catch |err| switch (err) {
            error.MissingHistoryId => return ipcHistoryError(alloc, id, "missing_param", "history_id is required"),
            error.HistoryUnavailable => return ipcHistoryError(alloc, id, "history_unavailable", "history is unavailable"),
            error.NotFound => return ipcHistoryError(alloc, id, "not_found", "transcript not found"),
            else => {
                log.warn("failed to resolve transcript surface: {}", .{err});
                return ipcHistoryError(alloc, id, "transcript_failed", "failed to resolve transcript");
            },
        };
        defer surface.deinit(std.heap.c_allocator);

        const lines = jsonLimitParam(params, "lines", 1000, 5000);
        const plain_text = self.readSanitizedTranscriptForSurface(alloc, surface) catch |err| {
            log.warn("failed to read transcript: {}", .{err});
            return ipcHistoryError(alloc, id, "transcript_read_failed", "failed to read transcript");
        };
        defer alloc.free(plain_text);

        const output = transcript_view.extractLastLines(plain_text, lines);
        const priv = self.private();
        var db = if (priv.terminal_history_db) |*database| database else {
            return ipcHistoryError(alloc, id, "history_unavailable", "history is unavailable");
        };
        const commands = db.listSurfaceCommands(surface.history_id, 200) catch |err| {
            log.warn("failed to list transcript command markers: {}", .{err});
            return ipcHistoryError(alloc, id, "transcript_failed", "failed to read command markers");
        };
        defer commands.deinit(std.heap.c_allocator);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);
        appendTranscriptSurfaceJson(&buf, alloc, surface, output, commands) catch return null;
        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{s},\"id\":{d}}}",
            .{ buf.items, id },
        ) catch null;
    }

    fn appendTranscriptSearchResultsJson(
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        history_id: []const u8,
        query: []const u8,
        results: transcript_view.SearchResults,
    ) !void {
        try buf.appendSlice(alloc, "{\"history_id\":");
        try appendJsonString(buf, alloc, history_id);
        try buf.appendSlice(alloc, ",\"query\":");
        try appendJsonString(buf, alloc, query);
        try buf.appendSlice(alloc, ",\"items\":[");
        for (results.items, 0..) |item, index| {
            if (index > 0) try buf.append(alloc, ',');
            try buf.appendSlice(alloc, "{\"line_number\":");
            try appendJsonInt(buf, alloc, item.line_number);
            try buf.appendSlice(alloc, ",\"line\":");
            try appendJsonString(buf, alloc, item.line);
            try buf.append(alloc, '}');
        }
        try buf.appendSlice(alloc, "]}");
    }

    fn ipcHistoryTranscriptSearch(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params = historyParams(obj);
        const query = jsonStringParam(params, "query") orelse {
            return ipcHistoryError(alloc, id, "missing_param", "query is required");
        };
        var surface = self.transcriptSurfaceForParams(alloc, params) catch |err| switch (err) {
            error.MissingHistoryId => return ipcHistoryError(alloc, id, "missing_param", "history_id is required"),
            error.HistoryUnavailable => return ipcHistoryError(alloc, id, "history_unavailable", "history is unavailable"),
            error.NotFound => return ipcHistoryError(alloc, id, "not_found", "transcript not found"),
            else => {
                log.warn("failed to resolve transcript search surface: {}", .{err});
                return ipcHistoryError(alloc, id, "transcript_failed", "failed to resolve transcript");
            },
        };
        defer surface.deinit(std.heap.c_allocator);

        const plain_text = self.readSanitizedTranscriptForSurface(alloc, surface) catch |err| {
            log.warn("failed to read transcript for search: {}", .{err});
            return ipcHistoryError(alloc, id, "transcript_read_failed", "failed to read transcript");
        };
        defer alloc.free(plain_text);

        const limit = jsonLimitParam(params, "limit", 50, 200);
        const results = transcript_view.searchLines(alloc, plain_text, query, limit) catch |err| {
            log.warn("failed to search transcript: {}", .{err});
            return ipcHistoryError(alloc, id, "transcript_search_failed", "failed to search transcript");
        };
        defer results.deinit(alloc);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);
        appendTranscriptSearchResultsJson(&buf, alloc, surface.history_id, query, results) catch return null;
        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{s},\"id\":{d}}}",
            .{ buf.items, id },
        ) catch null;
    }

    fn ipcHistoryTranscriptShow(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params = historyParams(obj);
        const history_id = jsonStringParam(params, "history_id");

        if (self.as(gtk.Application).getActiveWindow()) |active_win| {
            if (gobject.ext.cast(Window, active_win)) |win| {
                if (!win.showTranscriptViewer(history_id)) {
                    return ipcHistoryError(alloc, id, "not_found", "transcript not found");
                }

                var buf: std.ArrayListUnmanaged(u8) = .empty;
                defer buf.deinit(alloc);
                buf.appendSlice(alloc, "{\"shown\":true") catch return null;
                if (history_id) |value| {
                    buf.appendSlice(alloc, ",\"history_id\":") catch return null;
                    appendJsonString(&buf, alloc, value) catch return null;
                }
                buf.append(alloc, '}') catch return null;
                return std.fmt.allocPrint(
                    alloc,
                    "{{\"ok\":true,\"result\":{s},\"id\":{d}}}",
                    .{ buf.items, id },
                ) catch null;
            }
        }

        return ipcHistoryError(alloc, id, "no_window", "no active window");
    }

    fn storageParams(obj: std.json.ObjectMap) std.json.ObjectMap {
        const params_val = obj.get("params") orelse .null;
        return if (params_val == .object) params_val.object else obj;
    }

    fn ipcStorageError(alloc: std.mem.Allocator, id: i64, code: []const u8, message: []const u8) ?[]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);
        buf.appendSlice(alloc, "{\"ok\":false,\"error\":{\"code\":") catch return null;
        appendJsonString(&buf, alloc, code) catch return null;
        buf.appendSlice(alloc, ",\"message\":") catch return null;
        appendJsonString(&buf, alloc, message) catch return null;
        buf.appendSlice(alloc, "},\"id\":") catch return null;
        appendJsonInt(&buf, alloc, id) catch return null;
        buf.appendSlice(alloc, "}") catch return null;
        return buf.toOwnedSlice(alloc) catch null;
    }

    fn appendStorageStatusJson(
        self: *Self,
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
    ) !void {
        const cfg = self.private().termplex_cfg.terminal_history;
        var usage = try self.storageDiskUsage(alloc);
        defer usage.deinit(alloc);
        const counts = self.storageRowCounts();

        try buf.appendSlice(alloc, "{\"history_enabled\":");
        try buf.appendSlice(alloc, if (cfg.enabled) "true" else "false");
        try buf.appendSlice(alloc, ",\"restore_mode\":");
        try appendJsonString(buf, alloc, cfg.restore_mode);
        try buf.appendSlice(alloc, ",\"retention_days\":");
        try appendJsonInt(buf, alloc, cfg.retention_days);
        try buf.appendSlice(alloc, ",\"max_lines_per_surface\":");
        try appendJsonInt(buf, alloc, cfg.max_lines_per_surface);
        try buf.appendSlice(alloc, ",\"max_bytes_per_surface\":");
        try appendJsonInt(buf, alloc, cfg.max_bytes_per_surface);
        try buf.appendSlice(alloc, ",\"persist_alternate_screen\":");
        try buf.appendSlice(alloc, if (cfg.persist_alternate_screen) "true" else "false");
        try buf.appendSlice(alloc, ",\"replay_notice\":");
        try buf.appendSlice(alloc, if (cfg.replay_notice) "true" else "false");
        try buf.appendSlice(alloc, ",\"base_path\":");
        try appendJsonString(buf, alloc, usage.base_path);
        try buf.appendSlice(alloc, ",\"db_path\":");
        try appendJsonString(buf, alloc, usage.db_path);
        try buf.appendSlice(alloc, ",\"total_bytes\":");
        try appendJsonInt(buf, alloc, usage.total_bytes);
        try buf.appendSlice(alloc, ",\"transcript_bytes\":");
        try appendJsonInt(buf, alloc, usage.transcript_bytes);
        try buf.appendSlice(alloc, ",\"db_bytes\":");
        try appendJsonInt(buf, alloc, usage.db_bytes);
        try buf.appendSlice(alloc, ",\"transcript_file_count\":");
        try appendJsonInt(buf, alloc, usage.transcript_file_count);
        try buf.appendSlice(alloc, ",\"project_count\":");
        try appendJsonInt(buf, alloc, counts.project_count);
        try buf.appendSlice(alloc, ",\"surface_count\":");
        try appendJsonInt(buf, alloc, counts.surface_count);
        try buf.appendSlice(alloc, ",\"command_count\":");
        try appendJsonInt(buf, alloc, counts.command_count);
        try buf.appendSlice(alloc, ",\"task_count\":");
        try appendJsonInt(buf, alloc, counts.task_count);
        try buf.append(alloc, '}');
    }

    fn ipcStorageStatus(self: *Self, alloc: std.mem.Allocator, id: i64) ?[]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);
        self.appendStorageStatusJson(&buf, alloc) catch |err| {
            log.warn("failed to build storage status: {}", .{err});
            return ipcStorageError(alloc, id, "storage_status_failed", "failed to read storage status");
        };
        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{s},\"id\":{d}}}",
            .{ buf.items, id },
        ) catch null;
    }

    pub const DiagnosticsExportResult = struct {
        path: []u8,
        bytes: usize,

        pub fn deinit(self: *DiagnosticsExportResult, alloc: std.mem.Allocator) void {
            alloc.free(self.path);
            self.* = undefined;
        }
    };

    fn diagnosticsParams(obj: std.json.ObjectMap) std.json.ObjectMap {
        const params_val = obj.get("params") orelse .null;
        return if (params_val == .object) params_val.object else obj;
    }

    fn diagnosticsStateDir(alloc: std.mem.Allocator) ![]u8 {
        if (std.process.getEnvVarOwned(alloc, "XDG_STATE_HOME")) |state_home| {
            defer alloc.free(state_home);
            return std.fs.path.join(alloc, &.{ state_home, "termplex", "diagnostics" });
        } else |_| {}

        if (std.process.getEnvVarOwned(alloc, "HOME")) |home| {
            defer alloc.free(home);
            return std.fs.path.join(alloc, &.{ home, ".local", "state", "termplex", "diagnostics" });
        } else |_| {}

        return error.NoHomeDir;
    }

    fn diagnosticsOutputPath(alloc: std.mem.Allocator, output: ?[]const u8) ![]u8 {
        if (output) |raw| {
            if (std.fs.path.isAbsolute(raw)) return try alloc.dupe(u8, raw);
            const cwd = try std.fs.cwd().realpathAlloc(alloc, ".");
            defer alloc.free(cwd);
            return try std.fs.path.join(alloc, &.{ cwd, raw });
        }

        const dir = try diagnosticsStateDir(alloc);
        defer alloc.free(dir);
        try std.fs.cwd().makePath(dir);
        const filename = try std.fmt.allocPrint(
            alloc,
            "termplex-diagnostics-{d}.json",
            .{std.time.milliTimestamp()},
        );
        defer alloc.free(filename);
        return try std.fs.path.join(alloc, &.{ dir, filename });
    }

    fn appendDiagnosticsAppJson(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) !void {
        try buf.appendSlice(alloc, "{\"version\":");
        try appendJsonString(buf, alloc, build_config.version_string);
        try buf.appendSlice(alloc, ",\"channel\":");
        try appendJsonString(buf, alloc, @tagName(build_config.release_channel));
        try buf.appendSlice(alloc, ",\"build_mode\":");
        try appendJsonString(buf, alloc, build_config.mode_string);
        try buf.appendSlice(alloc, ",\"app_runtime\":");
        try appendJsonString(buf, alloc, @tagName(build_config.app_runtime));
        try buf.appendSlice(alloc, ",\"font_backend\":");
        try appendJsonString(buf, alloc, @tagName(build_config.font_backend));
        try buf.appendSlice(alloc, ",\"renderer\":");
        try appendJsonString(buf, alloc, @tagName(build_config.renderer));
        try buf.appendSlice(alloc, ",\"bundle_id\":");
        try appendJsonString(buf, alloc, build_config.bundle_id);
        try buf.append(alloc, '}');
    }

    fn appendEnvJsonField(
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        field: []const u8,
        env_name: []const u8,
    ) !void {
        try buf.append(alloc, '"');
        try appendJsonEscaped(buf, alloc, field);
        try buf.appendSlice(alloc, "\":");
        try appendOptionalJsonString(buf, alloc, std.posix.getenv(env_name));
    }

    fn appendDiagnosticsPathsJson(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) !void {
        const history_base = terminal_history.getBaseDir(alloc) catch null;
        defer if (history_base) |value| alloc.free(value);
        const history_db = terminal_history.databasePath(alloc) catch null;
        defer if (history_db) |value| alloc.free(value);
        const diagnostics_dir = diagnosticsStateDir(alloc) catch null;
        defer if (diagnostics_dir) |value| alloc.free(value);

        try buf.append(alloc, '{');
        try appendEnvJsonField(buf, alloc, "xdg_config_home", "XDG_CONFIG_HOME");
        try buf.append(alloc, ',');
        try appendEnvJsonField(buf, alloc, "xdg_state_home", "XDG_STATE_HOME");
        try buf.append(alloc, ',');
        try appendEnvJsonField(buf, alloc, "xdg_cache_home", "XDG_CACHE_HOME");
        try buf.append(alloc, ',');
        try appendEnvJsonField(buf, alloc, "xdg_runtime_dir", "XDG_RUNTIME_DIR");
        try buf.appendSlice(alloc, ",\"terminal_history_base\":");
        try appendOptionalJsonString(buf, alloc, history_base);
        try buf.appendSlice(alloc, ",\"terminal_history_db\":");
        try appendOptionalJsonString(buf, alloc, history_db);
        try buf.appendSlice(alloc, ",\"diagnostics_dir\":");
        try appendOptionalJsonString(buf, alloc, diagnostics_dir);
        try buf.append(alloc, '}');
    }

    fn appendDiagnosticsPrivacyJson(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) !void {
        try buf.appendSlice(
            alloc,
            "{\"includes_transcript_bodies\":false,\"includes_command_bodies\":false,\"includes_environment\":false,\"includes_git_diffs\":false}",
        );
    }

    fn appendDiagnosticsWorkspacesJson(
        self: *Self,
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
    ) !void {
        const priv = self.private();
        try buf.append(alloc, '[');
        for (priv.workspace_names.items, 0..) |name, i| {
            if (i > 0) try buf.append(alloc, ',');
            const idx: u32 = @intCast(i);
            const dir = self.workspaceDir(idx) orelse "";
            const id_text = self.workspaceIdString(alloc, idx) catch null;
            defer if (id_text) |value| alloc.free(value);
            const tab_count: u32 = if (self.workspaceTabView(idx)) |view|
                @intCast(@max(view.getNPages(), 0))
            else
                0;

            var git = git_status.query(alloc, dir) catch null;
            defer if (git) |*status| status.deinit(alloc);

            try buf.appendSlice(alloc, "{\"index\":");
            try appendJsonInt(buf, alloc, i);
            try buf.appendSlice(alloc, ",\"id\":");
            try appendOptionalJsonString(buf, alloc, id_text);
            try buf.appendSlice(alloc, ",\"name\":");
            try appendJsonString(buf, alloc, name);
            try buf.appendSlice(alloc, ",\"dir\":");
            try appendJsonString(buf, alloc, dir);
            try buf.appendSlice(alloc, ",\"active\":");
            try buf.appendSlice(alloc, if (idx == priv.active_workspace_idx) "true" else "false");
            try buf.appendSlice(alloc, ",\"pinned\":");
            try buf.appendSlice(alloc, if (idx < priv.workspace_pinned.items.len and priv.workspace_pinned.items[idx]) "true" else "false");
            try buf.appendSlice(alloc, ",\"tab_count\":");
            try appendJsonInt(buf, alloc, tab_count);
            try buf.appendSlice(alloc, ",\"git\":");
            if (git) |status| {
                try buf.appendSlice(alloc, "{\"is_repo\":");
                try buf.appendSlice(alloc, if (status.is_repo) "true" else "false");
                try buf.appendSlice(alloc, ",\"root\":");
                try appendOptionalJsonString(buf, alloc, status.root);
                try buf.appendSlice(alloc, ",\"branch\":");
                try appendOptionalJsonString(buf, alloc, status.branch);
                try buf.appendSlice(alloc, ",\"remote_url\":");
                try appendOptionalJsonString(buf, alloc, status.remote_url);
                try buf.appendSlice(alloc, ",\"dirty\":");
                try buf.appendSlice(alloc, if (status.dirty) "true" else "false");
                try buf.appendSlice(alloc, ",\"staged_count\":");
                try appendJsonInt(buf, alloc, status.staged.len);
                try buf.appendSlice(alloc, ",\"unstaged_count\":");
                try appendJsonInt(buf, alloc, status.unstaged.len);
                try buf.append(alloc, '}');
            } else {
                try buf.appendSlice(alloc, "{\"is_repo\":false,\"root\":null,\"branch\":null,\"remote_url\":null,\"dirty\":false,\"staged_count\":0,\"unstaged_count\":0}");
            }
            try buf.append(alloc, '}');
        }
        try buf.append(alloc, ']');
    }

    fn appendDiagnosticsUpdateJson(self: *Self, buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) !void {
        const update_state = self.private().update_state;
        try buf.appendSlice(alloc, "{\"available_version\":");
        try appendOptionalJsonString(buf, alloc, update_state.last_available_version);
        try buf.appendSlice(alloc, ",\"downloaded_version\":");
        try appendOptionalJsonString(buf, alloc, update_state.downloaded_version);
        try buf.appendSlice(alloc, ",\"download_path\":");
        try appendOptionalJsonString(buf, alloc, update_state.download_path);
        try buf.appendSlice(alloc, ",\"progress\":");
        try appendOptionalJsonString(buf, alloc, update_state.progress);
        try buf.appendSlice(alloc, ",\"install_kind\":");
        try appendJsonString(buf, alloc, @tagName(update_state.install_kind));
        try buf.appendSlice(alloc, ",\"checksum_status\":");
        try appendJsonString(buf, alloc, @tagName(update_state.checksum_status));
        try buf.appendSlice(alloc, ",\"last_error\":");
        try appendOptionalJsonString(buf, alloc, update_state.last_error);
        try buf.append(alloc, '}');
    }

    fn appendDiagnosticsSessionJson(self: *Self, buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) !void {
        const priv = self.private();
        var tab_count: u32 = 0;
        for (priv.workspace_tab_views.items) |view| {
            tab_count += @intCast(@max(view.getNPages(), 0));
        }
        try buf.appendSlice(alloc, "{\"workspace_count\":");
        try appendJsonInt(buf, alloc, priv.workspace_names.items.len);
        try buf.appendSlice(alloc, ",\"active_workspace\":");
        try appendJsonInt(buf, alloc, priv.active_workspace_idx);
        try buf.appendSlice(alloc, ",\"tab_count\":");
        try appendJsonInt(buf, alloc, tab_count);
        try buf.appendSlice(alloc, ",\"session_format_version\":7}");
    }

    fn appendDiagnosticsBundleJson(
        self: *Self,
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
    ) !void {
        try buf.appendSlice(alloc, "{\"schema_version\":1,\"bundle_kind\":\"termplex_diagnostics\",\"created_at_unix_ms\":");
        try appendJsonInt(buf, alloc, std.time.milliTimestamp());
        try buf.appendSlice(alloc, ",\"app\":");
        try appendDiagnosticsAppJson(buf, alloc);
        try buf.appendSlice(alloc, ",\"paths\":");
        try appendDiagnosticsPathsJson(buf, alloc);
        try buf.appendSlice(alloc, ",\"privacy\":");
        try appendDiagnosticsPrivacyJson(buf, alloc);
        try buf.appendSlice(alloc, ",\"workspaces\":");
        try self.appendDiagnosticsWorkspacesJson(buf, alloc);
        try buf.appendSlice(alloc, ",\"storage\":");
        try self.appendStorageStatusJson(buf, alloc);
        try buf.appendSlice(alloc, ",\"update\":");
        try self.appendDiagnosticsUpdateJson(buf, alloc);
        try buf.appendSlice(alloc, ",\"session\":");
        try self.appendDiagnosticsSessionJson(buf, alloc);
        try buf.append(alloc, '}');
    }

    pub fn exportDiagnosticsBundle(
        self: *Self,
        alloc: std.mem.Allocator,
        output: ?[]const u8,
    ) !DiagnosticsExportResult {
        const path = try diagnosticsOutputPath(alloc, output);
        errdefer alloc.free(path);

        if (std.fs.path.dirname(path)) |parent| {
            try std.fs.cwd().makePath(parent);
        }

        var bundle: std.ArrayListUnmanaged(u8) = .empty;
        defer bundle.deinit(alloc);
        try self.appendDiagnosticsBundleJson(&bundle, alloc);

        const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(bundle.items);

        return .{
            .path = path,
            .bytes = bundle.items.len,
        };
    }

    fn ipcDiagnosticsError(alloc: std.mem.Allocator, id: i64, code: []const u8, message: []const u8) ?[]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);
        buf.appendSlice(alloc, "{\"ok\":false,\"error\":{\"code\":") catch return null;
        appendJsonString(&buf, alloc, code) catch return null;
        buf.appendSlice(alloc, ",\"message\":") catch return null;
        appendJsonString(&buf, alloc, message) catch return null;
        buf.appendSlice(alloc, "},\"id\":") catch return null;
        appendJsonInt(&buf, alloc, id) catch return null;
        buf.appendSlice(alloc, "}") catch return null;
        return buf.toOwnedSlice(alloc) catch null;
    }

    fn ipcDiagnosticsExport(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params = diagnosticsParams(obj);
        const output = jsonStringParam(params, "output");
        var result = self.exportDiagnosticsBundle(alloc, output) catch |err| {
            log.warn("failed to export diagnostics bundle: {}", .{err});
            return ipcDiagnosticsError(alloc, id, "diagnostics_write_failed", "failed to write diagnostics bundle");
        };
        defer result.deinit(alloc);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);
        buf.appendSlice(alloc, "{\"ok\":true,\"result\":{\"path\":") catch return null;
        appendJsonString(&buf, alloc, result.path) catch return null;
        buf.appendSlice(alloc, ",\"bytes\":") catch return null;
        appendJsonInt(&buf, alloc, result.bytes) catch return null;
        buf.appendSlice(alloc, "},\"id\":") catch return null;
        appendJsonInt(&buf, alloc, id) catch return null;
        buf.appendSlice(alloc, "}") catch return null;
        return buf.toOwnedSlice(alloc) catch null;
    }

    fn ipcStorageClearTerminal(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params = storageParams(obj);
        self.clearTerminalHistoryForParams(alloc, params) catch |err| {
            log.warn("failed to clear terminal storage: {}", .{err});
            return ipcStorageError(alloc, id, "storage_clear_terminal_failed", "failed to clear terminal history");
        };
        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{{\"cleared\":true}},\"id\":{d}}}",
            .{id},
        ) catch null;
    }

    fn ipcStorageClearWorkspace(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params = storageParams(obj);
        const workspace_idx = self.resolveWorkspaceIdx(params) orelse {
            return ipcStorageError(alloc, id, "not_found", "workspace not found");
        };
        self.clearWorkspaceHistoryForIndex(alloc, workspace_idx) catch |err| {
            log.warn("failed to clear workspace storage: {}", .{err});
            return ipcStorageError(alloc, id, "storage_clear_workspace_failed", "failed to clear workspace history");
        };
        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{{\"cleared\":true,\"workspace\":{d}}},\"id\":{d}}}",
            .{ workspace_idx, id },
        ) catch null;
    }

    fn ipcStorageDeleteProject(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params = storageParams(obj);
        const workspace_idx = self.resolveWorkspaceIdx(params) orelse {
            return ipcStorageError(alloc, id, "not_found", "workspace not found");
        };
        if (self.private().workspace_names.items.len <= 1) {
            return ipcStorageError(alloc, id, "invalid_operation", "cannot delete the last project");
        }

        const workspace_id = self.workspaceIdString(self.allocator(), workspace_idx) catch {
            return ipcStorageError(alloc, id, "not_found", "workspace not found");
        };
        defer self.allocator().free(workspace_id);

        if (self.as(gtk.Application).getActiveWindow()) |active_win| {
            if (gobject.ext.cast(Window, active_win)) |win| {
                win.closeWorkspace(workspace_idx);
                self.scheduleTerminalHistoryProjectDelete(workspace_id);
                return std.fmt.allocPrint(
                    alloc,
                    "{{\"ok\":true,\"result\":{{\"deleted\":true,\"workspace\":{d}}},\"id\":{d}}}",
                    .{ workspace_idx, id },
                ) catch null;
            }
        }

        self.removeWorkspaceFromAllWindows(workspace_idx);
        self.removeWorkspace(workspace_idx);
        self.refreshAllWorkspaceSidebars();
        self.syncActiveWorkspaceHeaders();
        self.scheduleTerminalHistoryProjectDelete(workspace_id);
        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{{\"deleted\":true,\"workspace\":{d}}},\"id\":{d}}}",
            .{ workspace_idx, id },
        ) catch null;
    }

    fn ipcStorageShow(self: *Self, alloc: std.mem.Allocator, id: i64) ?[]u8 {
        if (self.as(gtk.Application).getActiveWindow()) |active_win| {
            if (gobject.ext.cast(Window, active_win)) |win| {
                win.toggleStorageManagement();
                return std.fmt.allocPrint(
                    alloc,
                    "{{\"ok\":true,\"result\":{{\"shown\":true}},\"id\":{d}}}",
                    .{id},
                ) catch null;
            }
        }

        return ipcStorageError(alloc, id, "no_window", "no active window");
    }

    fn gitParams(obj: std.json.ObjectMap) std.json.ObjectMap {
        const params_val = obj.get("params") orelse .null;
        return if (params_val == .object) params_val.object else obj;
    }

    fn gitWorkspaceIndex(self: *Self, params: std.json.ObjectMap) ?u32 {
        return self.resolveWorkspaceIdx(params);
    }

    fn gitDirectoryForParams(self: *Self, params: std.json.ObjectMap) ?[]const u8 {
        const priv = self.private();
        const explicit_workspace =
            params.get("workspace") != null or
            params.get("ref") != null or
            params.get("index") != null;

        if (!explicit_workspace) {
            if (priv.current_pwd) |pwd| return pwd;
        }

        const ws_idx = self.gitWorkspaceIndex(params) orelse return null;
        return self.workspaceDir(ws_idx);
    }

    fn appendGitChangeJson(
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        change: git_status.Change,
    ) !void {
        try buf.appendSlice(alloc, "{\"path\":");
        try appendJsonString(buf, alloc, change.path);
        try buf.appendSlice(alloc, ",\"status\":");
        try appendJsonString(buf, alloc, @tagName(change.status));
        try buf.appendSlice(alloc, "}");
    }

    fn appendGitChangeArrayJson(
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        changes: []const git_status.Change,
    ) !void {
        try buf.append(alloc, '[');
        for (changes, 0..) |change, index| {
            if (index > 0) try buf.append(alloc, ',');
            try appendGitChangeJson(buf, alloc, change);
        }
        try buf.append(alloc, ']');
    }

    fn appendGitStatusJson(
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        status: git_status.Status,
    ) !void {
        try buf.appendSlice(alloc, "{\"is_repo\":");
        try buf.appendSlice(alloc, if (status.is_repo) "true" else "false");
        try buf.appendSlice(alloc, ",\"root\":");
        try appendOptionalJsonString(buf, alloc, status.root);
        try buf.appendSlice(alloc, ",\"branch\":");
        try appendOptionalJsonString(buf, alloc, status.branch);
        try buf.appendSlice(alloc, ",\"remote_url\":");
        try appendOptionalJsonString(buf, alloc, status.remote_url);
        try buf.appendSlice(alloc, ",\"dirty\":");
        try buf.appendSlice(alloc, if (status.dirty) "true" else "false");
        try buf.appendSlice(alloc, ",\"staged\":");
        try appendGitChangeArrayJson(buf, alloc, status.staged);
        try buf.appendSlice(alloc, ",\"unstaged\":");
        try appendGitChangeArrayJson(buf, alloc, status.unstaged);
        try buf.append(alloc, '}');
    }

    fn ipcGitError(alloc: std.mem.Allocator, id: i64, code: []const u8, message: []const u8) ?[]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);
        buf.appendSlice(alloc, "{\"ok\":false,\"error\":{\"code\":") catch return null;
        appendJsonString(&buf, alloc, code) catch return null;
        buf.appendSlice(alloc, ",\"message\":") catch return null;
        appendJsonString(&buf, alloc, message) catch return null;
        buf.appendSlice(alloc, "},\"id\":") catch return null;
        appendJsonInt(&buf, alloc, id) catch return null;
        buf.appendSlice(alloc, "}") catch return null;
        return buf.toOwnedSlice(alloc) catch null;
    }

    fn ipcGitStatus(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params = gitParams(obj);
        const ws_idx = self.gitWorkspaceIndex(params) orelse {
            return ipcGitError(alloc, id, "not_found", "workspace not found");
        };
        const dir = self.gitDirectoryForParams(params) orelse {
            return ipcGitError(alloc, id, "not_found", "workspace directory not found");
        };

        var status = git_status.query(alloc, dir) catch |err| {
            log.warn("failed to query git status: {}", .{err});
            return ipcGitError(alloc, id, "git_status_failed", "failed to query git status");
        };
        defer status.deinit(alloc);

        self.syncGitStatusToWorkspace(ws_idx, &status);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);
        appendGitStatusJson(&buf, alloc, status) catch return null;
        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{s},\"id\":{d}}}",
            .{ buf.items, id },
        ) catch null;
    }

    fn ipcGitDiff(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params = gitParams(obj);
        const dir = self.gitDirectoryForParams(params) orelse {
            return ipcGitError(alloc, id, "not_found", "workspace directory not found");
        };
        const path = jsonStringParam(params, "path") orelse {
            return ipcGitError(alloc, id, "missing_param", "path is required");
        };
        const staged = jsonBoolParam(params, "staged", false);

        var result = git_status.diff(alloc, dir, path, staged) catch |err| {
            log.warn("failed to query git diff: {}", .{err});
            return ipcGitError(alloc, id, "git_diff_failed", "failed to query git diff");
        };
        defer result.deinit(alloc);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);
        buf.appendSlice(alloc, "{\"path\":") catch return null;
        appendJsonString(&buf, alloc, result.path) catch return null;
        buf.appendSlice(alloc, ",\"staged\":") catch return null;
        buf.appendSlice(alloc, if (result.staged) "true" else "false") catch return null;
        buf.appendSlice(alloc, ",\"diff\":") catch return null;
        appendJsonString(&buf, alloc, result.diff) catch return null;
        buf.appendSlice(alloc, "}") catch return null;

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{s},\"id\":{d}}}",
            .{ buf.items, id },
        ) catch null;
    }

    fn ipcGitStage(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params = gitParams(obj);
        const ws_idx = self.gitWorkspaceIndex(params) orelse {
            return ipcGitError(alloc, id, "not_found", "workspace not found");
        };
        const dir = self.gitDirectoryForParams(params) orelse {
            return ipcGitError(alloc, id, "not_found", "workspace directory not found");
        };
        const path = jsonStringParam(params, "path") orelse {
            return ipcGitError(alloc, id, "missing_param", "path is required");
        };

        var status = git_status.stage(alloc, dir, path) catch |err| {
            log.warn("failed to stage git file: {}", .{err});
            return ipcGitError(alloc, id, "git_stage_failed", "failed to stage file");
        };
        defer status.deinit(alloc);
        self.syncGitStatusToWorkspace(ws_idx, &status);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);
        appendGitStatusJson(&buf, alloc, status) catch return null;
        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{s},\"id\":{d}}}",
            .{ buf.items, id },
        ) catch null;
    }

    fn ipcGitStageAll(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params = gitParams(obj);
        const ws_idx = self.gitWorkspaceIndex(params) orelse {
            return ipcGitError(alloc, id, "not_found", "workspace not found");
        };
        const dir = self.gitDirectoryForParams(params) orelse {
            return ipcGitError(alloc, id, "not_found", "workspace directory not found");
        };

        var status = git_status.stageAll(alloc, dir) catch |err| {
            log.warn("failed to stage all git files: {}", .{err});
            return ipcGitError(alloc, id, "git_stage_failed", "failed to stage all files");
        };
        defer status.deinit(alloc);
        self.syncGitStatusToWorkspace(ws_idx, &status);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);
        appendGitStatusJson(&buf, alloc, status) catch return null;
        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{s},\"id\":{d}}}",
            .{ buf.items, id },
        ) catch null;
    }

    fn ipcGitUnstage(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params = gitParams(obj);
        const ws_idx = self.gitWorkspaceIndex(params) orelse {
            return ipcGitError(alloc, id, "not_found", "workspace not found");
        };
        const dir = self.gitDirectoryForParams(params) orelse {
            return ipcGitError(alloc, id, "not_found", "workspace directory not found");
        };
        const path = jsonStringParam(params, "path") orelse {
            return ipcGitError(alloc, id, "missing_param", "path is required");
        };

        var status = git_status.unstage(alloc, dir, path) catch |err| {
            log.warn("failed to unstage git file: {}", .{err});
            return ipcGitError(alloc, id, "git_unstage_failed", "failed to unstage file");
        };
        defer status.deinit(alloc);
        self.syncGitStatusToWorkspace(ws_idx, &status);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);
        appendGitStatusJson(&buf, alloc, status) catch return null;
        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{s},\"id\":{d}}}",
            .{ buf.items, id },
        ) catch null;
    }

    fn ipcGitUnstageAll(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params = gitParams(obj);
        const ws_idx = self.gitWorkspaceIndex(params) orelse {
            return ipcGitError(alloc, id, "not_found", "workspace not found");
        };
        const dir = self.gitDirectoryForParams(params) orelse {
            return ipcGitError(alloc, id, "not_found", "workspace directory not found");
        };

        var status = git_status.unstageAll(alloc, dir) catch |err| {
            log.warn("failed to unstage all git files: {}", .{err});
            return ipcGitError(alloc, id, "git_unstage_failed", "failed to unstage all files");
        };
        defer status.deinit(alloc);
        self.syncGitStatusToWorkspace(ws_idx, &status);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);
        appendGitStatusJson(&buf, alloc, status) catch return null;
        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{s},\"id\":{d}}}",
            .{ buf.items, id },
        ) catch null;
    }

    fn ipcGitCommit(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params = gitParams(obj);
        const ws_idx = self.gitWorkspaceIndex(params) orelse {
            return ipcGitError(alloc, id, "not_found", "workspace not found");
        };
        const dir = self.gitDirectoryForParams(params) orelse {
            return ipcGitError(alloc, id, "not_found", "workspace directory not found");
        };
        const message = jsonStringParam(params, "message") orelse {
            return ipcGitError(alloc, id, "missing_param", "message is required");
        };

        var result = git_status.commit(alloc, dir, message) catch |err| {
            log.warn("failed to commit staged git files: {}", .{err});
            return ipcGitError(alloc, id, "git_commit_failed", "failed to commit staged files");
        };
        defer result.deinit(alloc);
        self.syncGitStatusToWorkspace(ws_idx, &result.status);

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);
        buf.appendSlice(alloc, "{\"committed\":") catch return null;
        buf.appendSlice(alloc, if (result.committed) "true" else "false") catch return null;
        buf.appendSlice(alloc, ",\"commit\":") catch return null;
        appendOptionalJsonString(&buf, alloc, result.commit) catch return null;
        buf.appendSlice(alloc, ",\"status\":") catch return null;
        appendGitStatusJson(&buf, alloc, result.status) catch return null;
        buf.appendSlice(alloc, "}") catch return null;

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{s},\"id\":{d}}}",
            .{ buf.items, id },
        ) catch null;
    }

    fn ipcGitShow(self: *Self, alloc: std.mem.Allocator, id: i64) ?[]u8 {
        if (self.as(gtk.Application).getActiveWindow()) |active_win| {
            if (gobject.ext.cast(Window, active_win)) |win| {
                win.toggleSourceControl();
                return std.fmt.allocPrint(
                    alloc,
                    "{{\"ok\":true,\"result\":{{\"shown\":true}},\"id\":{d}}}",
                    .{id},
                ) catch null;
            }
        }

        return ipcGitError(alloc, id, "no_window", "no active window");
    }

    const SurfaceUuidEntry = struct {
        surface: *Surface,
        id: Uuid,
    };

    fn surfaceUuidFor(entries: []const SurfaceUuidEntry, surface: *Surface) ?Uuid {
        for (entries) |entry| {
            if (entry.surface == surface) return entry.id;
        }
        return null;
    }

    fn getOrCreateSurfaceUuid(
        entries: *std.ArrayListUnmanaged(SurfaceUuidEntry),
        alloc: std.mem.Allocator,
        surface: *Surface,
    ) !Uuid {
        if (surfaceUuidFor(entries.items, surface)) |existing| return existing;

        const id = if (surface.getHistoryId()) |history_id|
            uuid.parse(history_id) catch uuid.generate()
        else
            uuid.generate();
        try entries.append(alloc, .{
            .surface = surface,
            .id = id,
        });
        return id;
    }

    fn sessionSplitLayoutFromTree(
        alloc: std.mem.Allocator,
        tree: *const Surface.Tree,
        handle: Surface.Tree.Node.Handle,
        surface_ids: *std.ArrayListUnmanaged(SurfaceUuidEntry),
    ) !workspace_mod.SplitLayout {
        return switch (tree.nodes[handle.idx()]) {
            .leaf => |surface| .{
                .leaf = .{
                    .surface_id = try getOrCreateSurfaceUuid(surface_ids, alloc, surface),
                },
            },
            .split => |split| blk: {
                const first = try alloc.create(workspace_mod.SplitLayout);
                errdefer alloc.destroy(first);
                first.* = try sessionSplitLayoutFromTree(alloc, tree, split.left, surface_ids);
                errdefer {
                    first.deinit(alloc);
                    alloc.destroy(first);
                }

                const second = try alloc.create(workspace_mod.SplitLayout);
                errdefer {
                    first.deinit(alloc);
                    alloc.destroy(first);
                    alloc.destroy(second);
                }
                second.* = try sessionSplitLayoutFromTree(alloc, tree, split.right, surface_ids);

                break :blk .{
                    .split = .{
                        .direction = switch (split.layout) {
                            .horizontal => .horizontal,
                            .vertical => .vertical,
                        },
                        .ratio = @floatCast(split.ratio),
                        .first = first,
                        .second = second,
                    },
                };
            },
        };
    }

    fn appendSessionTabJson(
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        tab: *Tab,
        page: *adw.TabPage,
        workspace_dir: []const u8,
    ) !void {
        const split_tree = tab.getSplitTree();
        const tree = split_tree.getTree() orelse return error.InvalidArgument;

        var surface_ids: std.ArrayListUnmanaged(SurfaceUuidEntry) = .empty;
        defer surface_ids.deinit(alloc);

        var layout = try sessionSplitLayoutFromTree(alloc, tree, .root, &surface_ids);
        defer layout.deinit(alloc);

        try buf.appendSlice(alloc, "{\"title\":");
        try appendOptionalJsonString(
            buf,
            alloc,
            if (tab.getTitleOverride()) |title| title else null,
        );
        try buf.appendSlice(alloc, ",\"focused_surface_id\":");
        try appendOptionalJsonString(
            buf,
            alloc,
            if (split_tree.getActiveSurface()) |surface|
                if (surfaceUuidFor(surface_ids.items, surface)) |id| blk: {
                    var id_buf: [36]u8 = undefined;
                    uuid.format(id, &id_buf);
                    break :blk id_buf[0..];
                } else null
            else
                null,
        );
        try buf.appendSlice(alloc, ",\"split_layout\":");
        const layout_json = try layout.toJson(alloc);
        defer alloc.free(layout_json);
        try buf.appendSlice(alloc, layout_json);
        try buf.appendSlice(alloc, ",\"surfaces\":[");

        for (surface_ids.items, 0..) |entry, idx| {
            if (idx > 0) try buf.appendSlice(alloc, ",");
            try buf.appendSlice(alloc, "{\"id\":");
            var id_buf: [36]u8 = undefined;
            uuid.format(entry.id, &id_buf);
            try appendJsonString(buf, alloc, id_buf[0..]);
            try buf.appendSlice(alloc, ",\"history_id\":");
            try appendJsonString(
                buf,
                alloc,
                if (entry.surface.getHistoryId()) |history_id| history_id else id_buf[0..],
            );
            try buf.appendSlice(alloc, ",\"working_directory\":");
            try appendJsonString(
                buf,
                alloc,
                if (entry.surface.getPwd()) |pwd| pwd else workspace_dir,
            );
            try buf.appendSlice(alloc, ",\"custom_title\":");
            try appendOptionalJsonString(
                buf,
                alloc,
                if (entry.surface.getTitleOverride()) |title| title else null,
            );
            try buf.appendSlice(alloc, "}");
        }

        _ = page;
        try buf.appendSlice(alloc, "]}");
    }

    fn resolveWorkspaceRefString(self: *Self, workspace_ref: []const u8) ?u32 {
        const priv = self.private();
        if (std.fmt.parseUnsigned(u32, workspace_ref, 10)) |idx| {
            if (idx < priv.workspace_names.items.len) return idx;
        } else |_| {}

        for (priv.workspace_names.items, 0..) |name, idx| {
            if (std.mem.eql(u8, name, workspace_ref)) return @intCast(idx);
        }

        return null;
    }

    fn resolveWorkspaceParam(self: *Self, params: std.json.ObjectMap, field_name: []const u8, fallback: ?u32) ?u32 {
        const ws_val = params.get(field_name) orelse return fallback;
        return switch (ws_val) {
            .integer => |n| if (n >= 0 and n < @as(i64, @intCast(self.private().workspace_names.items.len)))
                @as(u32, @intCast(n))
            else
                null,
            .string => |s| self.resolveWorkspaceRefString(s),
            else => fallback,
        };
    }

    fn activeTabIndexForWorkspace(self: *Self, workspace_idx: u32) ?u32 {
        const tab_view = self.workspaceTabView(workspace_idx) orelse return null;
        const selected = tab_view.getSelectedPage() orelse return 0;
        const position = tab_view.getPagePosition(selected);
        if (position < 0) return null;
        return @intCast(position);
    }

    const SurfaceRef = struct {
        workspace_idx: u32,
        tab_idx: u32,
        surface_idx: ?u32 = null,
    };

    fn resolveSurfaceRef(self: *Self, params: std.json.ObjectMap, default_to_selected: bool) ?SurfaceRef {
        var workspace_idx = self.resolveWorkspaceParam(params, "workspace", self.private().active_workspace_idx) orelse return null;
        var tab_idx_opt: ?u32 = null;
        var surface_idx_opt: ?u32 = null;

        if (params.get("tab")) |tv| switch (tv) {
            .integer => |n| {
                if (n >= 0) tab_idx_opt = @intCast(n);
            },
            .string => |s| tab_idx_opt = std.fmt.parseUnsigned(u32, s, 10) catch null,
            else => {},
        };

        if (params.get("surface")) |sv| switch (sv) {
            .integer => |n| {
                if (n >= 0) surface_idx_opt = @intCast(n);
            },
            .string => |s| surface_idx_opt = std.fmt.parseUnsigned(u32, s, 10) catch null,
            else => {},
        };

        if (params.get("ref")) |rv| switch (rv) {
            .integer => |n| {
                if (n >= 0) tab_idx_opt = @intCast(n);
            },
            .string => |s| {
                var ref_value = s;
                if (std.mem.lastIndexOfScalar(u8, ref_value, '/')) |slash| {
                    surface_idx_opt = std.fmt.parseUnsigned(u32, ref_value[slash + 1 ..], 10) catch null;
                    ref_value = ref_value[0..slash];
                }

                if (std.mem.lastIndexOfScalar(u8, ref_value, ':')) |sep| {
                    workspace_idx = self.resolveWorkspaceRefString(ref_value[0..sep]) orelse return null;
                    tab_idx_opt = std.fmt.parseUnsigned(u32, ref_value[sep + 1 ..], 10) catch null;
                } else {
                    tab_idx_opt = std.fmt.parseUnsigned(u32, ref_value, 10) catch null;
                }
            },
            else => {},
        };

        const tab_idx = tab_idx_opt orelse if (default_to_selected)
            (self.activeTabIndexForWorkspace(workspace_idx) orelse return null)
        else
            return null;

        const tab_view = self.workspaceTabView(workspace_idx) orelse return null;
        if (tab_idx >= @as(u32, @intCast(@max(tab_view.getNPages(), 0)))) return null;

        return .{
            .workspace_idx = workspace_idx,
            .tab_idx = tab_idx,
            .surface_idx = surface_idx_opt,
        };
    }

    const ResolvedSurfaceTarget = struct {
        workspace_idx: u32,
        tab_idx: u32,
        surface_idx: u32,
        surface_count: u32,
        page: *adw.TabPage,
        tab: *Tab,
        surface: *Surface,
    };

    const TabSurfaceSelection = struct {
        surface_idx: u32,
        surface_count: u32,
        surface: *Surface,
    };

    const TabSurfaceEntry = struct {
        handle: Surface.Tree.Node.Handle,
        surface: *Surface,
    };

    fn appendTabSurfaceEntries(
        entries: *std.ArrayListUnmanaged(TabSurfaceEntry),
        alloc: std.mem.Allocator,
        tree: *const Surface.Tree,
        handle: Surface.Tree.Node.Handle,
    ) !void {
        switch (tree.nodes[handle.idx()]) {
            .leaf => |surface| try entries.append(alloc, .{
                .handle = handle,
                .surface = surface,
            }),
            .split => |split| {
                try appendTabSurfaceEntries(entries, alloc, tree, split.left);
                try appendTabSurfaceEntries(entries, alloc, tree, split.right);
            },
        }
    }

    fn collectTabSurfaceEntries(tab: *Tab, alloc: std.mem.Allocator) ?[]TabSurfaceEntry {
        const tree = tab.getSurfaceTree() orelse return null;
        var entries: std.ArrayListUnmanaged(TabSurfaceEntry) = .empty;
        appendTabSurfaceEntries(&entries, alloc, tree, .root) catch {
            entries.deinit(alloc);
            return null;
        };
        return entries.toOwnedSlice(alloc) catch {
            entries.deinit(alloc);
            return null;
        };
    }

    fn selectTabSurface(tab: *Tab, requested_surface_idx: ?u32) ?TabSurfaceSelection {
        const alloc = Application.default().allocator();
        const entries = collectTabSurfaceEntries(tab, alloc) orelse return null;
        defer alloc.free(entries);

        const active_surface = tab.getActiveSurface();
        var active_surface_idx: ?u32 = null;
        for (entries, 0..) |entry, idx| {
            if (active_surface != null and active_surface.? == entry.surface) {
                active_surface_idx = @intCast(idx);
                break;
            }
        }

        const surface_count: u32 = @intCast(entries.len);
        if (surface_count == 0) return null;
        if (requested_surface_idx) |idx| {
            if (idx >= surface_count) return null;
            return .{
                .surface_idx = idx,
                .surface_count = surface_count,
                .surface = entries[idx].surface,
            };
        }

        if (active_surface) |surface| {
            return .{
                .surface_idx = active_surface_idx orelse 0,
                .surface_count = surface_count,
                .surface = surface,
            };
        }

        return .{
            .surface_idx = 0,
            .surface_count = surface_count,
            .surface = entries[0].surface,
        };
    }

    fn resolveSurfaceTarget(self: *Self, surface_ref: SurfaceRef) ?ResolvedSurfaceTarget {
        const tab_view = self.workspaceTabView(surface_ref.workspace_idx) orelse return null;
        if (surface_ref.tab_idx >= @as(u32, @intCast(@max(tab_view.getNPages(), 0)))) return null;

        const page = tab_view.getNthPage(@intCast(surface_ref.tab_idx));
        const tab = gobject.ext.cast(Tab, page.getChild()) orelse return null;
        const selection = selectTabSurface(tab, surface_ref.surface_idx) orelse return null;

        return .{
            .workspace_idx = surface_ref.workspace_idx,
            .tab_idx = surface_ref.tab_idx,
            .surface_idx = selection.surface_idx,
            .surface_count = selection.surface_count,
            .page = page,
            .tab = tab,
            .surface = selection.surface,
        };
    }

    fn countTabSurfaces(tab: *Tab) u32 {
        const alloc = Application.default().allocator();
        const entries = collectTabSurfaceEntries(tab, alloc) orelse return 0;
        defer alloc.free(entries);
        return @intCast(entries.len);
    }

    fn surfaceDisplayTitle(surface: *Surface, fallback: []const u8) []const u8 {
        return if (surface.getEffectiveTitle()) |title| title else fallback;
    }

    fn formatSurfaceRef(
        buf: *[32]u8,
        tab_idx: u32,
        surface_idx: u32,
        surface_count: u32,
    ) ![]const u8 {
        if (surface_count <= 1) return std.fmt.bufPrint(buf, "{d}", .{tab_idx});
        return std.fmt.bufPrint(buf, "{d}/{d}", .{ tab_idx, surface_idx });
    }

    fn recordWorkspaceNotification(
        self: *Self,
        workspace_idx: u32,
        title: []const u8,
        body: []const u8,
        source: notification_mod.NotificationSource,
    ) ?u64 {
        const priv = self.private();
        const workspace_id = self.workspaceUuid(workspace_idx) orelse return null;
        const notification_id = priv.notifications.add(workspace_id, null, title, body, source) catch return null;
        if (workspace_idx == priv.active_workspace_idx) {
            priv.notifications.markRead(notification_id);
        }
        self.refreshAllWorkspaceSidebars();
        return notification_id;
    }

    /// Handle notification.create — fires a desktop notification via GIO and
    /// records unread state for the target workspace.
    fn ipcNotificationCreate(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params_val = obj.get("params") orelse .null;
        const params = if (params_val == .object) params_val.object else obj;

        const title_slice: []const u8 = if (params.get("title")) |v| switch (v) {
            .string => |s| s,
            else => "Termplex Notification",
        } else "Termplex Notification";

        const body_slice: []const u8 = if (params.get("body")) |v| switch (v) {
            .string => |s| s,
            else => "",
        } else "";

        const workspace_idx = self.resolveWorkspaceIdx(params) orelse self.private().active_workspace_idx;
        const notification_id = self.recordWorkspaceNotification(workspace_idx, title_slice, body_slice, .cli);

        const title_z = alloc.dupeZ(u8, title_slice) catch return null;
        defer alloc.free(title_z);
        const body_z = alloc.dupeZ(u8, body_slice) catch return null;
        defer alloc.free(body_z);

        const notification = gio.Notification.new(title_z);
        defer notification.unref();
        if (body_slice.len > 0) {
            notification.setBody(body_z);
        }
        self.as(gio.Application).sendNotification(null, notification);

        if (workspace_idx == self.private().active_workspace_idx) {
            if (self.as(gtk.Application).getActiveWindow()) |active_win| {
                active_win.as(gtk.Widget).addCssClass("termplex-attention");
            }
        }

        log.info("IPC notification: workspace={d} title=\"{s}\" body=\"{s}\"", .{ workspace_idx, title_slice, body_slice });
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);
        buf.appendSlice(alloc, "{\"id\":") catch return null;
        if (notification_id) |value| {
            var notification_id_buf: [32]u8 = undefined;
            const notification_id_str = std.fmt.bufPrint(&notification_id_buf, "{d}", .{value}) catch return null;
            buf.appendSlice(alloc, notification_id_str) catch return null;
        } else {
            buf.appendSlice(alloc, "null") catch return null;
        }
        buf.appendSlice(alloc, ",\"workspace\":") catch return null;
        var workspace_buf: [16]u8 = undefined;
        const workspace_str = std.fmt.bufPrint(&workspace_buf, "{d}", .{workspace_idx}) catch return null;
        buf.appendSlice(alloc, workspace_str) catch return null;
        buf.appendSlice(alloc, ",\"notified\":true}") catch return null;

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{s},\"id\":{d}}}",
            .{ buf.items, id },
        ) catch null;
    }

    /// Resolve a workspace reference (name string or integer index) from IPC params.
    /// Returns the workspace index, or null if not found.
    fn resolveWorkspaceIdx(self: *Self, params: std.json.ObjectMap) ?u32 {
        const priv = self.private();
        const ws_val = params.get("workspace") orelse
            params.get("ref") orelse
            params.get("index") orelse
            return priv.active_workspace_idx;
        switch (ws_val) {
            .integer => |n| {
                if (n >= 0 and n < @as(i64, @intCast(priv.workspace_names.items.len)))
                    return @intCast(n);
                return null;
            },
            .string => |name| {
                return self.resolveWorkspaceRefString(name);
            },
            else => return priv.active_workspace_idx,
        }
    }

    /// Resolve workspace + tab index from IPC params to an AdwTabPage.
    /// Returns the tab page, or null if the workspace or tab index is invalid.
    fn resolveTabPage(self: *Self, params: std.json.ObjectMap) ?*adw.TabPage {
        const priv = self.private();

        const ws_idx = self.resolveWorkspaceIdx(params) orelse return null;
        if (ws_idx >= priv.workspace_tab_views.items.len) return null;

        const tab_view = priv.workspace_tab_views.items[ws_idx];

        const tab_idx: c_int = blk: {
            const tv = params.get("tab") orelse break :blk 0;
            switch (tv) {
                .integer => |n| {
                    if (n >= 0 and n < @as(i64, tab_view.getNPages()))
                        break :blk @intCast(n);
                    return null;
                },
                else => break :blk 0,
            }
        };

        if (tab_idx >= tab_view.getNPages()) return null;
        return tab_view.getNthPage(tab_idx);
    }

    fn ipcNotificationList(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const priv = self.private();
        const params_val = obj.get("params") orelse .null;
        const has_workspace_filter = params_val == .object and
            (params_val.object.get("workspace") != null or
                params_val.object.get("ref") != null or
                params_val.object.get("index") != null);

        const workspace_filter: ?u32 = blk: {
            if (!has_workspace_filter) break :blk null;
            if (params_val != .object) break :blk null;
            break :blk self.resolveWorkspaceIdx(params_val.object) orelse {
                return std.fmt.allocPrint(
                    alloc,
                    "{{\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"workspace not found\"}},\"id\":{d}}}",
                    .{id},
                ) catch null;
            };
        };

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);

        buf.appendSlice(alloc, "[") catch return null;
        var first = true;
        for (priv.notifications.notifications.items) |notification| {
            const ws_idx = self.workspaceIndexForUuid(notification.workspace_id) orelse continue;
            if (workspace_filter) |filter_idx| {
                if (ws_idx != filter_idx) continue;
            }

            if (!first) buf.appendSlice(alloc, ",") catch return null;
            first = false;

            buf.appendSlice(alloc, "{\"id\":") catch return null;
            var id_buf: [32]u8 = undefined;
            const notification_id = std.fmt.bufPrint(&id_buf, "{d}", .{notification.id}) catch return null;
            buf.appendSlice(alloc, notification_id) catch return null;
            buf.appendSlice(alloc, ",\"workspace\":") catch return null;
            var ws_buf: [16]u8 = undefined;
            const ws_str = std.fmt.bufPrint(&ws_buf, "{d}", .{ws_idx}) catch return null;
            buf.appendSlice(alloc, ws_str) catch return null;
            buf.appendSlice(alloc, ",\"workspace_name\":") catch return null;
            appendJsonString(&buf, alloc, self.workspaceName(ws_idx) orelse "") catch return null;
            buf.appendSlice(alloc, ",\"title\":") catch return null;
            appendJsonString(&buf, alloc, notification.title) catch return null;
            buf.appendSlice(alloc, ",\"body\":") catch return null;
            appendJsonString(&buf, alloc, notification.body) catch return null;
            buf.appendSlice(alloc, ",\"timestamp\":") catch return null;
            var ts_buf: [32]u8 = undefined;
            const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{notification.timestamp}) catch return null;
            buf.appendSlice(alloc, ts_str) catch return null;
            buf.appendSlice(alloc, ",\"read\":") catch return null;
            buf.appendSlice(alloc, if (notification.read) "true" else "false") catch return null;
            buf.appendSlice(alloc, ",\"source\":") catch return null;
            appendJsonString(&buf, alloc, @tagName(notification.source)) catch return null;
            buf.appendSlice(alloc, "}") catch return null;
        }
        buf.appendSlice(alloc, "]") catch return null;

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{{\"notifications\":{s}}},\"id\":{d}}}",
            .{ buf.items, id },
        ) catch null;
    }

    fn ipcNotificationClear(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const priv = self.private();
        const params_val = obj.get("params") orelse .null;
        const has_workspace_filter = params_val == .object and
            (params_val.object.get("workspace") != null or
                params_val.object.get("ref") != null or
                params_val.object.get("index") != null);

        if (has_workspace_filter) {
            const ws_idx = self.resolveWorkspaceIdx(params_val.object) orelse {
                return std.fmt.allocPrint(
                    alloc,
                    "{{\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"workspace not found\"}},\"id\":{d}}}",
                    .{id},
                ) catch null;
            };
            const workspace_id = self.workspaceUuid(ws_idx) orelse {
                return std.fmt.allocPrint(
                    alloc,
                    "{{\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"workspace not found\"}},\"id\":{d}}}",
                    .{id},
                ) catch null;
            };
            priv.notifications.clearWorkspace(workspace_id);
        } else {
            priv.notifications.clearAll();
        }

        self.refreshAllWorkspaceSidebars();

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{{\"cleared\":true}},\"id\":{d}}}",
            .{id},
        ) catch null;
    }

    fn ipcSystemTree(self: *Self, alloc: std.mem.Allocator, id: i64) ?[]u8 {
        const priv = self.private();
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);

        buf.appendSlice(alloc, "{\"active_workspace\":") catch return null;
        var active_buf: [16]u8 = undefined;
        const active_str = std.fmt.bufPrint(&active_buf, "{d}", .{priv.active_workspace_idx}) catch return null;
        buf.appendSlice(alloc, active_str) catch return null;
        buf.appendSlice(alloc, ",\"workspaces\":[") catch return null;

        for (priv.workspace_names.items, 0..) |name, ws_idx| {
            if (ws_idx > 0) buf.appendSlice(alloc, ",") catch return null;

            buf.appendSlice(alloc, "{\"index\":") catch return null;
            var idx_buf: [16]u8 = undefined;
            const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{ws_idx}) catch return null;
            buf.appendSlice(alloc, idx_str) catch return null;
            buf.appendSlice(alloc, ",\"name\":") catch return null;
            appendJsonString(&buf, alloc, name) catch return null;
            buf.appendSlice(alloc, ",\"dir\":") catch return null;
            appendJsonString(&buf, alloc, self.workspaceDir(@intCast(ws_idx)) orelse "") catch return null;
            buf.appendSlice(alloc, ",\"active\":") catch return null;
            buf.appendSlice(alloc, if (ws_idx == priv.active_workspace_idx) "true" else "false") catch return null;
            buf.appendSlice(alloc, ",\"unread_count\":") catch return null;
            var unread_buf: [16]u8 = undefined;
            const unread_str = std.fmt.bufPrint(&unread_buf, "{d}", .{self.workspaceUnreadCount(@intCast(ws_idx))}) catch return null;
            buf.appendSlice(alloc, unread_str) catch return null;
            buf.appendSlice(alloc, ",\"tabs\":[") catch return null;

            if (self.workspaceTabView(@intCast(ws_idx))) |tab_view| {
                const selected_idx = self.activeTabIndexForWorkspace(@intCast(ws_idx));
                var tab_idx: c_int = 0;
                while (tab_idx < tab_view.getNPages()) : (tab_idx += 1) {
                    if (tab_idx > 0) buf.appendSlice(alloc, ",") catch return null;
                    const page = tab_view.getNthPage(tab_idx);
                    const child = page.getChild();
                    const tab = gobject.ext.cast(Tab, child);
                    const active_surface = if (tab) |t| t.getActiveSurface() else null;
                    const title_slice = std.mem.span(page.getTitle());

                    buf.appendSlice(alloc, "{\"index\":") catch return null;
                    var tab_idx_buf: [16]u8 = undefined;
                    const tab_idx_str = std.fmt.bufPrint(&tab_idx_buf, "{d}", .{tab_idx}) catch return null;
                    buf.appendSlice(alloc, tab_idx_str) catch return null;
                    buf.appendSlice(alloc, ",\"title\":") catch return null;
                    appendJsonString(&buf, alloc, title_slice) catch return null;
                    buf.appendSlice(alloc, ",\"active\":") catch return null;
                    buf.appendSlice(alloc, if (selected_idx != null and selected_idx.? == @as(u32, @intCast(tab_idx))) "true" else "false") catch return null;
                    if (active_surface) |s| {
                        buf.appendSlice(alloc, ",\"pwd\":") catch return null;
                        appendJsonString(&buf, alloc, if (s.getPwd()) |pwd| pwd else "") catch return null;
                    }
                    buf.appendSlice(alloc, "}") catch return null;
                }
            }

            buf.appendSlice(alloc, "]}") catch return null;
        }

        buf.appendSlice(alloc, "]}") catch return null;

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{s},\"id\":{d}}}",
            .{ buf.items, id },
        ) catch null;
    }

    fn ipcStatusReportGit(self: *Self, alloc: std.mem.Allocator, id: i64) ?[]u8 {
        const priv = self.private();
        const ws_idx = priv.active_workspace_idx;
        const probe_dir = priv.current_pwd orelse self.workspaceDir(ws_idx) orelse "";

        var result = git_probe.probe(alloc, probe_dir);
        defer result.deinit(alloc);

        if (priv.git_branch) |old| alloc.free(old);
        priv.git_branch = if (result.branch) |branch| alloc.dupeZ(u8, branch) catch null else null;
        priv.git_dirty = result.dirty;

        if (ws_idx < priv.workspace_git_branches.items.len) {
            if (priv.workspace_git_branches.items[ws_idx]) |old_branch| alloc.free(old_branch);
            priv.workspace_git_branches.items[ws_idx] = if (result.branch) |branch| alloc.dupeZ(u8, branch) catch null else null;
            priv.workspace_git_dirty.items[ws_idx] = result.dirty;
            priv.workspace_git_staged_counts.items[ws_idx] = result.staged_count;
            priv.workspace_git_unstaged_counts.items[ws_idx] = result.unstaged_count;
            self.upsertTerminalHistoryProject(ws_idx);
        }

        self.updateSidebarGitState();

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);
        buf.appendSlice(alloc, "{\"workspace\":") catch return null;
        var ws_buf: [16]u8 = undefined;
        const ws_str = std.fmt.bufPrint(&ws_buf, "{d}", .{ws_idx}) catch return null;
        buf.appendSlice(alloc, ws_str) catch return null;
        buf.appendSlice(alloc, ",\"branch\":") catch return null;
        if (priv.git_branch) |branch| {
            appendJsonString(&buf, alloc, branch) catch return null;
        } else {
            buf.appendSlice(alloc, "null") catch return null;
        }
        buf.appendSlice(alloc, ",\"dirty\":") catch return null;
        buf.appendSlice(alloc, if (priv.git_dirty) "true" else "false") catch return null;
        buf.appendSlice(alloc, "}") catch return null;

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{s},\"id\":{d}}}",
            .{ buf.items, id },
        ) catch null;
    }

    fn ipcStatusReportPorts(self: *Self, alloc: std.mem.Allocator, id: i64) ?[]u8 {
        const priv = self.private();
        runPortScan(self);
        self.updateSidebarPortState();

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);
        buf.appendSlice(alloc, "{\"workspace\":") catch return null;
        var ws_buf: [16]u8 = undefined;
        const ws_str = std.fmt.bufPrint(&ws_buf, "{d}", .{priv.active_workspace_idx}) catch return null;
        buf.appendSlice(alloc, ws_str) catch return null;
        buf.appendSlice(alloc, ",\"ports\":") catch return null;
        if (priv.listening_ports_str) |ports| {
            appendJsonString(&buf, alloc, ports) catch return null;
        } else {
            buf.appendSlice(alloc, "null") catch return null;
        }
        buf.appendSlice(alloc, "}") catch return null;

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{s},\"id\":{d}}}",
            .{ buf.items, id },
        ) catch null;
    }

    fn ipcSurfaceList(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params_val = obj.get("params") orelse .null;
        const workspace_idx: u32 = blk: {
            if (params_val == .object and
                (params_val.object.get("workspace") != null or
                    params_val.object.get("ref") != null or
                    params_val.object.get("index") != null))
            {
                break :blk self.resolveWorkspaceIdx(params_val.object) orelse {
                    return std.fmt.allocPrint(
                        alloc,
                        "{{\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"workspace not found\"}},\"id\":{d}}}",
                        .{id},
                    ) catch null;
                };
            }
            break :blk self.private().active_workspace_idx;
        };

        const tab_view = self.workspaceTabView(workspace_idx) orelse {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"workspace not found\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);

        buf.appendSlice(alloc, "[") catch return null;
        const selected_idx = self.activeTabIndexForWorkspace(workspace_idx);
        var tab_idx: c_int = 0;
        while (tab_idx < tab_view.getNPages()) : (tab_idx += 1) {
            if (tab_idx > 0) buf.appendSlice(alloc, ",") catch return null;
            const page = tab_view.getNthPage(tab_idx);
            const child = page.getChild();
            const tab = gobject.ext.cast(Tab, child);

            if (tab) |tab_widget| {
                const entries = collectTabSurfaceEntries(tab_widget, alloc) orelse &[_]TabSurfaceEntry{};
                defer if (entries.len > 0) alloc.free(entries);
                const surface_count: u32 = @intCast(entries.len);
                const active_surface = tab_widget.getActiveSurface();
                if (surface_count > 0) {
                    for (entries, 0..) |entry, surface_idx_usize| {
                        const surface_idx: u32 = @intCast(surface_idx_usize);
                        if (buf.items.len > 1) buf.appendSlice(alloc, ",") catch return null;

                        buf.appendSlice(alloc, "{\"ref\":") catch return null;
                        var ref_buf: [32]u8 = undefined;
                        const ref_str = formatSurfaceRef(
                            &ref_buf,
                            @intCast(tab_idx),
                            surface_idx,
                            surface_count,
                        ) catch return null;
                        appendJsonString(&buf, alloc, ref_str) catch return null;

                        buf.appendSlice(alloc, ",\"tab\":") catch return null;
                        var tab_buf: [16]u8 = undefined;
                        const tab_str = std.fmt.bufPrint(&tab_buf, "{d}", .{tab_idx}) catch return null;
                        buf.appendSlice(alloc, tab_str) catch return null;

                        buf.appendSlice(alloc, ",\"surface\":") catch return null;
                        var surface_buf: [16]u8 = undefined;
                        const surface_str = std.fmt.bufPrint(&surface_buf, "{d}", .{surface_idx}) catch return null;
                        buf.appendSlice(alloc, surface_str) catch return null;

                        buf.appendSlice(alloc, ",\"tab_title\":") catch return null;
                        appendJsonString(&buf, alloc, std.mem.span(page.getTitle())) catch return null;

                        buf.appendSlice(alloc, ",\"title\":") catch return null;
                        appendJsonString(
                            &buf,
                            alloc,
                            surfaceDisplayTitle(entry.surface, std.mem.span(page.getTitle())),
                        ) catch return null;

                        buf.appendSlice(alloc, ",\"pwd\":") catch return null;
                        appendJsonString(&buf, alloc, entry.surface.getPwd() orelse "") catch return null;

                        buf.appendSlice(alloc, ",\"focused\":") catch return null;
                        const is_focused =
                            selected_idx != null and
                            selected_idx.? == @as(u32, @intCast(tab_idx)) and
                            workspace_idx == self.private().active_workspace_idx and
                            active_surface != null and
                            active_surface.? == entry.surface;
                        buf.appendSlice(alloc, if (is_focused) "true" else "false") catch return null;
                        buf.appendSlice(alloc, "}") catch return null;
                    }
                    continue;
                }
            }

            if (buf.items.len > 1) buf.appendSlice(alloc, ",") catch return null;
            buf.appendSlice(alloc, "{\"ref\":") catch return null;
            var ref_buf: [16]u8 = undefined;
            const ref_str = std.fmt.bufPrint(&ref_buf, "{d}", .{tab_idx}) catch return null;
            appendJsonString(&buf, alloc, ref_str) catch return null;
            buf.appendSlice(alloc, ",\"tab\":") catch return null;
            buf.appendSlice(alloc, ref_str) catch return null;
            buf.appendSlice(alloc, ",\"surface\":0,\"tab_title\":") catch return null;
            appendJsonString(&buf, alloc, std.mem.span(page.getTitle())) catch return null;
            buf.appendSlice(alloc, ",\"title\":") catch return null;
            appendJsonString(&buf, alloc, std.mem.span(page.getTitle())) catch return null;
            buf.appendSlice(alloc, ",\"pwd\":\"\",\"focused\":") catch return null;
            buf.appendSlice(alloc, if (selected_idx != null and selected_idx.? == @as(u32, @intCast(tab_idx)) and workspace_idx == self.private().active_workspace_idx) "true" else "false") catch return null;
            buf.appendSlice(alloc, "}") catch return null;
        }
        buf.appendSlice(alloc, "]") catch return null;

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{{\"workspace\":{d},\"surfaces\":{s}}},\"id\":{d}}}",
            .{ workspace_idx, buf.items, id },
        ) catch null;
    }

    fn ipcSurfaceCreate(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params_val = obj.get("params") orelse .null;
        const workspace_idx: u32 = blk: {
            if (params_val == .object and params_val.object.get("workspace") != null) {
                break :blk self.resolveWorkspaceParam(params_val.object, "workspace", self.private().active_workspace_idx) orelse {
                    return std.fmt.allocPrint(
                        alloc,
                        "{{\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"workspace not found\"}},\"id\":{d}}}",
                        .{id},
                    ) catch null;
                };
            }
            break :blk self.private().active_workspace_idx;
        };

        const active_win = self.as(gtk.Application).getActiveWindow() orelse {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"no_window\",\"message\":\"no active window\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };
        const win = gobject.ext.cast(Window, active_win) orelse {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"no_window\",\"message\":\"active window is not a termplex window\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };

        if (workspace_idx == self.private().active_workspace_idx) {
            win.newTab(null);
        } else {
            const tab_view = self.workspaceTabView(workspace_idx) orelse {
                return std.fmt.allocPrint(
                    alloc,
                    "{{\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"workspace not found\"}},\"id\":{d}}}",
                    .{id},
                ) catch null;
            };
            win.createTabInView(tab_view, self.workspaceDir(workspace_idx));
        }

        const tab_view = self.workspaceTabView(workspace_idx) orelse return null;
        const tab_idx: c_int = tab_view.getNPages() - 1;

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{{\"workspace\":{d},\"ref\":\"{d}\",\"tab\":{d}}},\"id\":{d}}}",
            .{ workspace_idx, tab_idx, tab_idx, id },
        ) catch null;
    }

    fn ipcSurfaceClose(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params_val = obj.get("params") orelse .null;
        const surface_ref = if (params_val == .object)
            self.resolveSurfaceRef(params_val.object, true)
        else blk: {
            const workspace_idx = self.private().active_workspace_idx;
            const tab_idx = self.activeTabIndexForWorkspace(workspace_idx) orelse break :blk null;
            break :blk SurfaceRef{
                .workspace_idx = workspace_idx,
                .tab_idx = tab_idx,
            };
        };
        const surface_target_ref = surface_ref orelse {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"surface not found\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };
        const surface_target = self.resolveSurfaceTarget(surface_target_ref) orelse {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"surface not found\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };

        const active_win = self.as(gtk.Application).getActiveWindow() orelse {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"no_window\",\"message\":\"no active window\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };
        const win = gobject.ext.cast(Window, active_win) orelse {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"no_window\",\"message\":\"active window is not a termplex window\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };

        if (surface_target.workspace_idx != self.private().active_workspace_idx) {
            self.setActiveWorkspaceIndex(surface_target.workspace_idx);
            self.markWorkspaceNotificationsRead(surface_target.workspace_idx);
            self.refreshAllWorkspaceSidebars();
            self.syncActiveWorkspaceHeaders();
            if (self.workspaceTabView(surface_target.workspace_idx)) |target_view| {
                win.switchToTabView(target_view);
            }
        }

        const tab_view = self.workspaceTabView(surface_target.workspace_idx) orelse return null;
        tab_view.setSelectedPage(surface_target.page);
        if (surface_target.surface_count <= 1) {
            tab_view.closePage(surface_target.page);
        } else {
            surface_target.tab.getSplitTree().setLastFocusedSurface(surface_target.surface);
            surface_target.surface.close();
        }

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{{\"closed\":true}},\"id\":{d}}}",
            .{id},
        ) catch null;
    }

    fn ipcSurfaceFocus(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params_val = obj.get("params") orelse .null;
        if (params_val != .object) {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"invalid_params\",\"message\":\"surface ref required\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        }

        const surface_target_ref = self.resolveSurfaceRef(params_val.object, false) orelse {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"surface not found\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };
        const surface_target = self.resolveSurfaceTarget(surface_target_ref) orelse {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"surface not found\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };

        const active_win = self.as(gtk.Application).getActiveWindow() orelse {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"no_window\",\"message\":\"no active window\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };
        const win = gobject.ext.cast(Window, active_win) orelse {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"no_window\",\"message\":\"active window is not a termplex window\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };

        if (surface_target.workspace_idx != self.private().active_workspace_idx) {
            self.setActiveWorkspaceIndex(surface_target.workspace_idx);
            self.markWorkspaceNotificationsRead(surface_target.workspace_idx);
            self.refreshAllWorkspaceSidebars();
            self.syncActiveWorkspaceHeaders();
            if (self.workspaceTabView(surface_target.workspace_idx)) |target_view| {
                win.switchToTabView(target_view);
            }
        }

        const tab_view = self.workspaceTabView(surface_target.workspace_idx) orelse return null;
        tab_view.setSelectedPage(surface_target.page);
        surface_target.tab.getSplitTree().setLastFocusedSurface(surface_target.surface);
        surface_target.surface.grabFocus();

        var ref_buf: [32]u8 = undefined;
        const ref_str = formatSurfaceRef(
            &ref_buf,
            surface_target.tab_idx,
            surface_target.surface_idx,
            surface_target.surface_count,
        ) catch return null;

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{{\"workspace\":{d},\"ref\":\"{s}\",\"focused\":true}},\"id\":{d}}}",
            .{ surface_target.workspace_idx, ref_str, id },
        ) catch null;
    }

    /// Handle surface.send — writes text to a terminal's PTY.
    fn ipcSurfaceSend(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params_val = obj.get("params") orelse .null;
        if (params_val != .object) {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"invalid_params\",\"message\":\"params object required\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        }
        const params = params_val.object;

        const page = self.resolveTabPage(params) orelse {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"workspace or tab not found\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };

        // Get the text to send.
        const text: []const u8 = blk: {
            const tv = params.get("text") orelse break :blk "";
            switch (tv) {
                .string => |s| break :blk s,
                else => break :blk "",
            }
        };

        // If text is empty, just return success — nothing to write.
        if (text.len == 0) {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":true,\"result\":{{}},\"id\":{d}}}",
                .{id},
            ) catch null;
        }

        // Write text to the terminal's PTY.
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"tab not found\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };
        const gtk_surface = tab.getActiveSurface() orelse {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"surface not found\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };
        gtk_surface.ensureInitializedFromAllocation("ipc-send");
        const core_surface = gtk_surface.core() orelse {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"core surface not found\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };

        const msg = termio.Message.writeReq(
            core_surface.alloc,
            text,
        ) catch {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"write_error\",\"message\":\"failed to create write request\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };
        core_surface.io.queueMessage(msg, .unlocked);

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{{}},\"id\":{d}}}",
            .{id},
        ) catch null;
    }

    /// Handle surface.read — reads terminal screen buffer text.
    fn ipcSurfaceRead(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params_val = obj.get("params") orelse .null;
        if (params_val != .object) {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"invalid_params\",\"message\":\"params object required\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        }
        const params = params_val.object;

        const page = self.resolveTabPage(params) orelse {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"workspace or tab not found\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };

        // Get lines count from params (default 50, min 1, max 1000).
        const lines: usize = blk: {
            const lv = params.get("lines") orelse break :blk 50;
            switch (lv) {
                .integer => |n| {
                    if (n < 1) break :blk 1;
                    if (n > 1000) break :blk 1000;
                    break :blk @intCast(n);
                },
                else => break :blk 50,
            }
        };

        // Navigate: page -> Tab -> Surface -> CoreSurface -> terminal text.
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"tab not found\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };
        const gtk_surface = tab.getActiveSurface() orelse {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"surface not found\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };
        const core_surface = gtk_surface.core() orelse {
            return self.ipcSurfaceReadTranscriptFallback(alloc, id, params, gtk_surface, lines);
        };

        // Lock the renderer mutex — required for thread safety.
        core_surface.renderer_state.mutex.lock();
        defer core_surface.renderer_state.mutex.unlock();

        const t = core_surface.renderer_state.terminal;

        // Get viewport text. Note: plainString reads only the visible viewport
        // (not scrollback). Future enhancement could use .screen to read history.
        const full_text = t.plainString(alloc) catch {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"read_error\",\"message\":\"failed to read terminal buffer\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };
        defer alloc.free(full_text);

        // Extract the last N lines from the text.
        const text = transcript_view.extractLastLines(full_text, lines);

        return allocSurfaceReadResponse(alloc, id, text);
    }

    fn ipcSurfaceReadTranscriptFallback(
        self: *Self,
        alloc: std.mem.Allocator,
        id: i64,
        params: std.json.ObjectMap,
        gtk_surface: *Surface,
        lines: usize,
    ) ?[]u8 {
        const history_id = gtk_surface.getHistoryId() orelse {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"core surface not found\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };
        const workspace_idx = self.resolveWorkspaceIdx(params) orelse self.private().active_workspace_idx;
        const workspace_id = self.workspaceIdString(alloc, workspace_idx) catch {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"read_error\",\"message\":\"failed to resolve workspace history id\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };
        defer alloc.free(workspace_id);

        const transcript_path = terminal_history.transcriptPath(alloc, workspace_id, history_id) catch {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"read_error\",\"message\":\"failed to resolve transcript path\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };
        defer alloc.free(transcript_path);

        const full_text = terminal_history.readTranscript(alloc, transcript_path, self.terminalHistoryOptions()) catch {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"read_error\",\"message\":\"failed to read transcript\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };
        defer alloc.free(full_text);

        const plain_text = transcript_view.stripControlSequences(alloc, full_text) catch {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"read_error\",\"message\":\"failed to sanitize transcript\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };
        defer alloc.free(plain_text);

        const text = transcript_view.extractLastLines(plain_text, lines);
        return allocSurfaceReadResponse(alloc, id, text);
    }

    fn allocSurfaceReadResponse(alloc: std.mem.Allocator, id: i64, text: []const u8) ?[]u8 {
        // Build JSON response with escaped text.
        var buf = std.ArrayListUnmanaged(u8){};
        defer buf.deinit(alloc);

        buf.appendSlice(alloc, "{\"ok\":true,\"result\":{\"output\":\"") catch {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"read_error\",\"message\":\"failed to build response\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };

        // JSON-escape the text.
        for (text) |c| {
            const slice: ?[]const u8 = switch (c) {
                '"' => "\\\"",
                '\\' => "\\\\",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                else => null,
            };
            if (slice) |s| {
                buf.appendSlice(alloc, s) catch return null;
            } else if (c < 0x20) {
                const hex = "0123456789abcdef";
                buf.appendSlice(alloc, "\\u00") catch return null;
                buf.append(alloc, hex[c >> 4]) catch return null;
                buf.append(alloc, hex[c & 0xf]) catch return null;
            } else {
                buf.append(alloc, c) catch return null;
            }
        }

        // Close the JSON: "},"id":N}
        const tail = std.fmt.allocPrint(alloc, "\"}},\"id\":{d}}}", .{id}) catch return null;
        defer alloc.free(tail);
        buf.appendSlice(alloc, tail) catch return null;

        return buf.toOwnedSlice(alloc) catch null;
    }

    /// Handle surface.split — creates a new split in the active surface.
    ///
    /// Params:
    ///   direction: "right" | "left" | "up" | "down" | "horizontal" | "vertical"
    ///             (default: "right")
    ///             "horizontal" maps to "right", "vertical" maps to "down"
    fn ipcSurfaceSplit(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params_val = obj.get("params") orelse .null;

        // Parse direction from params (default: "right").
        const direction: []const u8 = blk: {
            if (params_val == .object) {
                if (params_val.object.get("direction")) |dir_val| {
                    if (dir_val == .string) {
                        const d = dir_val.string;
                        // Map horizontal/vertical to right/down for convenience.
                        if (std.mem.eql(u8, d, "horizontal")) break :blk "right";
                        if (std.mem.eql(u8, d, "vertical")) break :blk "down";
                        // Validate direction name.
                        if (std.mem.eql(u8, d, "right") or
                            std.mem.eql(u8, d, "left") or
                            std.mem.eql(u8, d, "up") or
                            std.mem.eql(u8, d, "down"))
                        {
                            break :blk d;
                        }
                        return std.fmt.allocPrint(
                            alloc,
                            "{{\"ok\":false,\"error\":{{\"code\":\"invalid_params\",\"message\":\"direction must be right, left, up, down, horizontal, or vertical\"}},\"id\":{d}}}",
                            .{id},
                        ) catch null;
                    }
                }
            }
            break :blk "right";
        };

        // Get the active window.
        const active_win = self.as(gtk.Application).getActiveWindow() orelse {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"no_window\",\"message\":\"no active window\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };
        const win = gobject.ext.cast(Window, active_win) orelse {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"no_window\",\"message\":\"active window is not a termplex window\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };

        // Get the active surface and activate the split-tree action on it.
        const surface = win.getActiveSurface() orelse {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"no_surface\",\"message\":\"no active surface\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };

        const result = surface.as(gtk.Widget).activateAction(
            "split-tree.new-split",
            "&s",
            direction.ptr,
        );

        if (result == 0) {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"split_failed\",\"message\":\"failed to create split\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        }

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{{\"direction\":\"{s}\"}},\"id\":{d}}}",
            .{ direction, id },
        ) catch null;
    }

    /// Handle tab.list — returns tabs in a workspace.
    fn ipcTabList(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const priv = self.private();
        const params_val = obj.get("params") orelse .null;

        const ws_idx: u32 = blk: {
            if (params_val == .object) {
                if (self.resolveWorkspaceIdx(params_val.object)) |i| break :blk i;
                return std.fmt.allocPrint(
                    alloc,
                    "{{\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"workspace not found\"}},\"id\":{d}}}",
                    .{id},
                ) catch null;
            }
            break :blk priv.active_workspace_idx;
        };

        const tab_view = priv.workspace_tab_views.items[ws_idx];
        const n_pages = tab_view.getNPages();

        var arr_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer arr_buf.deinit(alloc);

        arr_buf.appendSlice(alloc, "[") catch return null;
        var i: c_int = 0;
        while (i < n_pages) : (i += 1) {
            if (i > 0) arr_buf.appendSlice(alloc, ",") catch return null;
            const page = tab_view.getNthPage(i);
            const title = page.getTitle();

            arr_buf.appendSlice(alloc, "{\"index\":") catch return null;
            var idx_buf: [16]u8 = undefined;
            const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{i}) catch return null;
            arr_buf.appendSlice(alloc, idx_str) catch return null;
            arr_buf.appendSlice(alloc, ",\"title\":\"") catch return null;
            // JSON-escape the title
            for (std.mem.span(title)) |c| {
                if (c == '"' or c == '\\') arr_buf.append(alloc, '\\') catch return null;
                arr_buf.append(alloc, c) catch return null;
            }
            const surface_count: u32 = if (gobject.ext.cast(Tab, page.getChild())) |tab|
                @max(countTabSurfaces(tab), 1)
            else
                1;
            arr_buf.appendSlice(alloc, "\",\"surface_count\":") catch return null;
            var surface_count_buf: [16]u8 = undefined;
            const surface_count_str = std.fmt.bufPrint(&surface_count_buf, "{d}", .{surface_count}) catch return null;
            arr_buf.appendSlice(alloc, surface_count_str) catch return null;
            arr_buf.appendSlice(alloc, "}") catch return null;
        }
        arr_buf.appendSlice(alloc, "]") catch return null;

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":true,\"result\":{{\"tabs\":{s}}},\"id\":{d}}}",
            .{ arr_buf.items, id },
        ) catch null;
    }

    /// Handle tab.create — creates a new tab in a workspace.
    fn ipcTabCreate(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
        const params_val = obj.get("params") orelse .null;
        if (params_val != .object) {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"invalid_params\",\"message\":\"params object required\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        }
        const params = params_val.object;

        // Resolve workspace using shared helper
        const ws_idx = self.resolveWorkspaceIdx(params) orelse {
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"workspace not found\"}},\"id\":{d}}}",
                .{id},
            ) catch null;
        };

        // Extract optional dir
        const dir: ?[:0]const u8 = blk: {
            const dv = params.get("dir") orelse break :blk null;
            switch (dv) {
                .string => |s| {
                    if (s.len > 0)
                        break :blk alloc.dupeZ(u8, s) catch break :blk null;
                    break :blk null;
                },
                else => break :blk null,
            }
        };
        defer if (dir) |d| alloc.free(d);

        const priv = self.private();

        // Get the workspace's TabView
        const tab_view = priv.workspace_tab_views.items[ws_idx];

        // Use the workspace dir as fallback
        const working_dir = dir orelse self.workspaceDir(ws_idx);

        const title_z: ?[:0]u8 = blk: {
            const tv = params.get("title") orelse break :blk null;
            switch (tv) {
                .string => |s| {
                    if (s.len > 0) break :blk alloc.dupeZ(u8, s) catch null;
                    break :blk null;
                },
                else => break :blk null,
            }
        };
        defer if (title_z) |title| alloc.free(title);

        const command_text: ?[]const u8 = blk: {
            const cv = params.get("command") orelse break :blk null;
            switch (cv) {
                .string => |cmd| {
                    if (cmd.len > 0) break :blk cmd;
                    break :blk null;
                },
                else => break :blk null,
            }
        };

        // Create the tab via the active window. If a non-active workspace was
        // requested, switch to it first so the new surface is mapped and usable
        // by follow-up IPC calls such as surface.send/read.
        if (self.as(gtk.Application).getActiveWindow()) |active_win| {
            if (gobject.ext.cast(Window, active_win)) |win| {
                if (ws_idx != priv.active_workspace_idx) {
                    self.setActiveWorkspaceIndex(ws_idx);
                    self.markWorkspaceNotificationsRead(ws_idx);
                    self.refreshAllWorkspaceSidebars();
                    self.syncActiveWorkspaceHeaders();
                    win.switchToTabView(tab_view);
                }

                win.newTabForWindow(null, .{
                    .working_directory = working_dir,
                    .title = title_z,
                });

                // Get the newly created tab page.
                const n_pages = tab_view.getNPages();
                if (n_pages > 0) {
                    const page = tab_view.getSelectedPage() orelse tab_view.getNthPage(n_pages - 1);

                    // Set custom title if provided.
                    if (title_z) |title| {
                        page.setTitle(title);
                    }

                    // If command provided, schedule PTY write after shell init
                    if (command_text) |cmd| {
                        // Use c_allocator for data that outlives the IPC call.
                        const c_alloc = std.heap.c_allocator;
                        const cmd_with_newline = c_alloc.alloc(u8, cmd.len + 1) catch null;
                        if (cmd_with_newline) |cwn| {
                            @memcpy(cwn[0..cmd.len], cmd);
                            cwn[cmd.len] = '\n';
                            // Schedule deferred write via GLib timer; pass the
                            // stable page pointer to avoid index-reorder races.
                            self.scheduleTabCommand(tab_view, page, cwn);
                        }
                    }

                    const new_idx = tab_view.getPagePosition(page);
                    log.info("IPC tab.create: workspace={d} new_tab_idx={d}", .{ ws_idx, new_idx });
                    return std.fmt.allocPrint(
                        alloc,
                        "{{\"ok\":true,\"result\":{{\"index\":{d}}},\"id\":{d}}}",
                        .{ new_idx, id },
                    ) catch null;
                }
            }
        }

        return std.fmt.allocPrint(
            alloc,
            "{{\"ok\":false,\"error\":{{\"code\":\"no_window\",\"message\":\"no active window\"}},\"id\":{d}}}",
            .{id},
        ) catch null;
    }

    /// Delay before writing the deferred command to a new tab's PTY, in
    /// milliseconds. Chosen to allow the shell to finish initializing.
    const tab_command_delay_ms: u32 = 500;

    /// Context for deferred tab command execution.
    const TabCommandContext = struct {
        tab_view: *adw.TabView,
        /// Stable page reference — unaffected by tab reordering or other tabs
        /// being created/closed between scheduling and callback execution.
        page: *adw.TabPage,
        command: []u8,
        alloc: std.mem.Allocator,
    };

    fn scheduleTabCommand(self: *Self, tab_view: *adw.TabView, page: *adw.TabPage, command: []u8) void {
        _ = self;
        const alloc = std.heap.c_allocator;
        const ctx = alloc.create(TabCommandContext) catch return;
        ctx.* = .{
            .tab_view = tab_view,
            .page = page,
            .command = command,
            .alloc = alloc,
        };
        _ = glib.timeoutAdd(tab_command_delay_ms, &tabCommandCallback, ctx);
    }

    fn tabCommandCallback(ud: ?*anyopaque) callconv(.c) c_int {
        const ctx: *TabCommandContext = @ptrCast(@alignCast(ud orelse return @intFromBool(glib.SOURCE_REMOVE)));
        defer {
            ctx.alloc.free(ctx.command);
            ctx.alloc.destroy(ctx);
        }

        // Verify the page is still attached to the tab view. getPagePosition
        // returns -1 when the page is not present.
        if (ctx.tab_view.getPagePosition(ctx.page) < 0) return @intFromBool(glib.SOURCE_REMOVE);

        const child = ctx.page.getChild();

        // The child is a Tab widget. Get its active surface and write to PTY.
        if (gobject.ext.cast(Tab, child)) |tab| {
            if (tab.getActiveSurface()) |gtk_surface| {
                if (gtk_surface.core()) |core_surface| {
                    const msg = termio.Message.writeReq(
                        core_surface.alloc,
                        ctx.command,
                    ) catch return @intFromBool(glib.SOURCE_REMOVE);
                    core_surface.io.queueMessage(msg, .unlocked);
                }
            }
        }

        return @intFromBool(glib.SOURCE_REMOVE); // One-shot timer
    }

    /// Set a socket fd to non-blocking mode.
    fn ipcSetNonBlocking(fd: std.posix.fd_t) !void {
        const flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
        const new_flags = flags | @as(usize, 1 << @bitOffsetOf(std.posix.O, "NONBLOCK"));
        _ = try std.posix.fcntl(fd, std.posix.F.SETFL, new_flags);
    }

    /// Write all bytes to a (possibly non-blocking) fd; best-effort.
    fn ipcWriteAll(fd: std.posix.fd_t, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            const n = std.posix.write(fd, data[written..]) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            written += n;
        }
    }

    // -----------------------------------------------------------------
    // Termplex: session autosave and restore
    // -----------------------------------------------------------------

    /// Resolve the path to the session JSON file.
    /// Priority: $XDG_STATE_HOME/termplex/session.json
    ///           $HOME/.local/state/termplex/session.json
    /// Caller owns the returned slice.
    fn getSessionPath(alloc: std.mem.Allocator) ?[]u8 {
        if (std.process.getEnvVarOwned(alloc, "XDG_STATE_HOME")) |state_home| {
            defer alloc.free(state_home);
            return std.fs.path.join(alloc, &.{ state_home, "termplex", "session.json" }) catch null;
        } else |_| {}

        if (std.process.getEnvVarOwned(alloc, "HOME")) |home| {
            defer alloc.free(home);
            return std.fs.path.join(alloc, &.{ home, ".local", "state", "termplex", "session.json" }) catch null;
        } else |_| {}

        return null;
    }

    /// GLib timer callback: called every 5 seconds to autosave the session.
    fn autosaveCallback(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return @intFromBool(glib.SOURCE_CONTINUE)));
        autosaveSession(self);
        return @intFromBool(glib.SOURCE_CONTINUE);
    }

    /// GLib timer callback: debounced save of memory state (fires every 1s).
    fn memoryDebounceSaveCallback(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return @intFromBool(glib.SOURCE_REMOVE)));
        const priv = self.private();
        if (priv.memory_manager) |*mgr| {
            mgr.debouncedSave();
        }
        return @intFromBool(glib.SOURCE_CONTINUE);
    }

    // memoryProcInspectCallback deferred to v2 — shell hooks are the
    // primary detection mechanism. Proc inspection requires iterating
    // all surfaces to get shell PIDs, which is complex.

    fn activeWorkspaceIndexForSession(active_idx: u32, orchestration_idx: ?u32) u32 {
        const orch_idx = orchestration_idx orelse return active_idx;
        if (active_idx == orch_idx) return 0;
        if (active_idx > orch_idx) return active_idx - 1;
        return active_idx;
    }

    fn activeWorkspaceIndexFromSession(saved_idx: u32, orchestration_idx: ?u32, workspace_count: usize) u32 {
        if (workspace_count == 0) return 0;

        var idx = saved_idx;
        if (orchestration_idx) |orch_idx| {
            if (idx >= orch_idx) idx += 1;
        }

        const last_idx: u32 = @intCast(workspace_count - 1);
        return @min(idx, last_idx);
    }

    fn sessionWorkspacePinned(value: std.json.Value) bool {
        if (value != .object) return false;
        const pinned = value.object.get("pinned") orelse return false;
        return pinned == .bool and pinned.bool;
    }

    /// Collect current state and atomically write it to the session JSON file.
    fn autosaveSession(self: *Self) void {
        const alloc = self.allocator();
        const priv = self.private();

        const session_path = getSessionPath(alloc) orelse return;
        defer alloc.free(session_path);

        // Get window geometry from the active GTK window.
        var window_width: c_int = 800;
        var window_height: c_int = 600;
        var sidebar_width: c_int = 180;
        if (self.as(gtk.Application).getActiveWindow()) |active_win| {
            active_win.getDefaultSize(&window_width, &window_height);
            // Try to read the sidebar paned position from the active termplex Window.
            if (gobject.ext.cast(Window, active_win)) |tp_win| {
                sidebar_width = tp_win.getSidebarWidth();
            }
        }

        // Build JSON workspaces array (v6: full tab snapshots plus stable
        // workspace and terminal history IDs).
        var ws_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer ws_buf.deinit(alloc);
        ws_buf.appendSlice(alloc, "[") catch return;
        var need_comma: bool = false;
        for (priv.workspace_names.items, 0..) |name, i| {
            // Skip orchestration workspace — it is recreated on startup.
            if (priv.orchestration_workspace_idx) |orch_idx| {
                if (i == orch_idx) continue;
            }
            if (need_comma) ws_buf.appendSlice(alloc, ",") catch return;
            need_comma = true;
            const dir = if (i < priv.workspace_dirs.items.len) priv.workspace_dirs.items[i] else "";
            ws_buf.appendSlice(alloc, "{\"workspace_id\":") catch return;
            var workspace_id_buf: [36]u8 = undefined;
            uuid.format(priv.workspace_ids.items[i], &workspace_id_buf);
            appendJsonString(&ws_buf, alloc, workspace_id_buf[0..]) catch return;
            ws_buf.appendSlice(alloc, ",\"name\":") catch return;
            appendJsonString(&ws_buf, alloc, name) catch return;
            ws_buf.appendSlice(alloc, ",\"dir\":") catch return;
            appendJsonString(&ws_buf, alloc, dir) catch return;
            ws_buf.appendSlice(alloc, ",\"pinned\":") catch return;
            ws_buf.appendSlice(alloc, if (i < priv.workspace_pinned.items.len and priv.workspace_pinned.items[i]) "true" else "false") catch return;
            ws_buf.appendSlice(alloc, ",\"active_tab_index\":") catch return;
            const active_tab_index: u32 = self.activeTabIndexForWorkspace(@intCast(i)) orelse 0;
            var active_tab_buf: [16]u8 = undefined;
            const active_tab_str = std.fmt.bufPrint(&active_tab_buf, "{d}", .{active_tab_index}) catch return;
            ws_buf.appendSlice(alloc, active_tab_str) catch return;
            ws_buf.appendSlice(alloc, ",\"tabs\":[") catch return;
            if (i < priv.workspace_tab_views.items.len) {
                const tv = priv.workspace_tab_views.items[i];
                const n_pages = tv.getNPages();
                var j: c_int = 0;
                while (j < n_pages) : (j += 1) {
                    if (j > 0) ws_buf.appendSlice(alloc, ",") catch return;
                    const page = tv.getNthPage(j);
                    const tab_widget = page.getChild();
                    if (gobject.ext.cast(Tab, tab_widget)) |tab| {
                        appendSessionTabJson(&ws_buf, alloc, tab, page, dir) catch return;
                    } else {
                        ws_buf.appendSlice(alloc, "{\"title\":null,\"focused_surface_id\":null,\"split_layout\":{\"type\":\"leaf\",\"surface_id\":\"00000000-0000-0000-0000-000000000000\"},\"surfaces\":[{\"id\":\"00000000-0000-0000-0000-000000000000\",\"history_id\":\"00000000-0000-0000-0000-000000000000\",\"working_directory\":") catch return;
                        appendJsonString(&ws_buf, alloc, dir) catch return;
                        ws_buf.appendSlice(alloc, ",\"custom_title\":null}]}") catch return;
                    }
                }
            }
            ws_buf.appendSlice(alloc, "]}") catch return;
        }
        ws_buf.appendSlice(alloc, "]") catch return;

        // Build JSON for pwd (may be null).
        const pwd_str: []const u8 = if (priv.current_pwd) |p| p else "";
        var pwd_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer pwd_buf.deinit(alloc);
        if (pwd_str.len > 0) {
            pwd_buf.append(alloc, '"') catch return;
            for (pwd_str) |c| {
                if (c == '"' or c == '\\') pwd_buf.append(alloc, '\\') catch return;
                pwd_buf.append(alloc, c) catch return;
            }
            pwd_buf.append(alloc, '"') catch return;
        } else {
            pwd_buf.appendSlice(alloc, "null") catch return;
        }

        const active_workspace_index = activeWorkspaceIndexForSession(
            priv.active_workspace_idx,
            priv.orchestration_workspace_idx,
        );

        const json = std.fmt.allocPrint(alloc,
            \\{{
            \\  "version": 7,
            \\  "window_width": {d},
            \\  "window_height": {d},
            \\  "sidebar_width": {d},
            \\  "active_workspace_index": {d},
            \\  "workspaces": {s},
            \\  "pwd": {s}
            \\}}
            \\
        , .{
            window_width,
            window_height,
            sidebar_width,
            active_workspace_index,
            ws_buf.items,
            pwd_buf.items,
        }) catch return;
        defer alloc.free(json);

        // Ensure parent directory exists.
        const parent_dir = std.fs.path.dirname(session_path) orelse return;
        std.fs.cwd().makePath(parent_dir) catch |err| {
            log.warn("autosave: failed to create session dir {s}: {}", .{ parent_dir, err });
            return;
        };

        // Write atomically: write to .tmp then rename.
        const tmp_path = std.fmt.allocPrint(alloc, "{s}.tmp", .{session_path}) catch return;
        defer alloc.free(tmp_path);

        std.fs.cwd().writeFile(.{
            .sub_path = tmp_path,
            .data = json,
        }) catch |err| {
            log.warn("autosave: failed to write tmp session file: {}", .{err});
            return;
        };

        std.fs.cwd().rename(tmp_path, session_path) catch |err| {
            log.warn("autosave: failed to rename session file: {}", .{err});
            std.fs.cwd().deleteFile(tmp_path) catch {};
            return;
        };

        log.debug("autosave: session written to {s}", .{session_path});
    }

    fn parseOwnedJsonString(alloc: std.mem.Allocator, value: std.json.Value) !?[]const u8 {
        return switch (value) {
            .string => |s| try alloc.dupe(u8, s),
            .null => null,
            else => error.InvalidArgument,
        };
    }

    fn parseSessionSurfaceData(alloc: std.mem.Allocator, value: std.json.Value) !session_mod.SurfaceData {
        if (value != .object) return error.InvalidArgument;
        const obj = value.object;

        const id_val = obj.get("id") orelse return error.InvalidArgument;
        if (id_val != .string) return error.InvalidArgument;
        const id = try alloc.dupe(u8, id_val.string);
        errdefer alloc.free(id);

        const history_id = if (obj.get("history_id")) |history_id_val| blk: {
            if (history_id_val != .string) return error.InvalidArgument;
            break :blk try alloc.dupe(u8, history_id_val.string);
        } else try alloc.dupe(u8, id);
        errdefer alloc.free(history_id);

        const wd_val = obj.get("working_directory") orelse return error.InvalidArgument;
        if (wd_val != .string) return error.InvalidArgument;
        const working_directory = try alloc.dupe(u8, wd_val.string);
        errdefer alloc.free(working_directory);

        const custom_title = if (obj.get("custom_title")) |custom_title_val|
            try parseOwnedJsonString(alloc, custom_title_val)
        else
            null;
        errdefer if (custom_title) |title| alloc.free(title);

        return .{
            .id = id,
            .history_id = history_id,
            .working_directory = working_directory,
            .custom_title = custom_title,
        };
    }

    fn parseSessionTabData(alloc: std.mem.Allocator, value: std.json.Value) !session_mod.TabData {
        if (value != .object) return error.InvalidArgument;
        const obj = value.object;

        const title = if (obj.get("title")) |title_val|
            try parseOwnedJsonString(alloc, title_val)
        else
            null;
        errdefer if (title) |owned| alloc.free(owned);

        const focused_surface_id = if (obj.get("focused_surface_id")) |focused_val|
            try parseOwnedJsonString(alloc, focused_val)
        else
            null;
        errdefer if (focused_surface_id) |owned| alloc.free(owned);

        const layout_val = obj.get("split_layout") orelse return error.InvalidArgument;
        var split_layout = try workspace_mod.SplitLayout.fromJsonValue(alloc, layout_val);
        errdefer split_layout.deinit(alloc);

        const surfaces_val = obj.get("surfaces") orelse return error.InvalidArgument;
        if (surfaces_val != .array) return error.InvalidArgument;
        var surfaces = std.ArrayListUnmanaged(session_mod.SurfaceData){};
        errdefer {
            for (surfaces.items) |*surface| surface.deinit(alloc);
            surfaces.deinit(alloc);
        }
        for (surfaces_val.array.items) |surface_val| {
            try surfaces.append(alloc, try parseSessionSurfaceData(alloc, surface_val));
        }

        return .{
            .title = title,
            .focused_surface_id = focused_surface_id,
            .split_layout = split_layout,
            .surfaces = try surfaces.toOwnedSlice(alloc),
        };
    }

    /// Restore workspace state from the session JSON file on startup.
    /// Skipped if TERMPLEX_DISABLE_RESTORE is set. Best-effort; any parse
    /// failure leaves defaults intact.
    fn restoreSession(self: *Self) void {
        // Honour the disable flag.
        const disable_var = std.process.getEnvVarOwned(self.allocator(), "TERMPLEX_DISABLE_RESTORE") catch null;
        if (disable_var) |v| {
            self.allocator().free(v);
            log.debug("session restore disabled via TERMPLEX_DISABLE_RESTORE", .{});
            return;
        }

        const alloc = self.allocator();
        const priv = self.private();

        const session_path = getSessionPath(alloc) orelse return;
        defer alloc.free(session_path);

        const contents = std.fs.cwd().readFileAlloc(alloc, session_path, 1024 * 1024) catch |err| {
            switch (err) {
                error.FileNotFound => log.debug("no session file found at {s}, using defaults", .{session_path}),
                else => log.warn("session restore: failed to read {s}: {}", .{ session_path, err }),
            }
            return;
        };
        defer alloc.free(contents);

        const parsed = std.json.parseFromSlice(std.json.Value, alloc, contents, .{}) catch |err| {
            log.warn("session restore: failed to parse JSON: {}", .{err});
            return;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            log.warn("session restore: expected JSON object at root", .{});
            return;
        }

        // Extract workspaces array.
        const ws_val = root.object.get("workspaces") orelse return;
        if (ws_val != .array) return;
        const ws_arr = ws_val.array.items;
        if (ws_arr.len == 0) return;

        // Detect format version. Absent or 1 → v1 (flat string array).
        // Explicit 2 → v2 (array of objects with name/dir/tab_count).
        // Explicit 3 → v3 (v2 + tabs[] array with per-tab title).
        // Explicit 4 → v4 (v3 + workspace active_tab_index + per-tab dir).
        // Explicit 5 → v5 (full split/session snapshots per tab).
        // Explicit 6 → v6 (v5 + stable workspace/history IDs).
        // Explicit 7 → v7 (v6 + pinned workspace state).
        const max_supported_version: i64 = 7;
        const format_version: u32 = if (root.object.get("version")) |vv|
            switch (vv) {
                .integer => |n| if (n < 1 or n > max_supported_version) {
                    log.warn("session restore: unsupported format version {d}, expected 1-{d}", .{ n, max_supported_version });
                    return;
                } else @as(u32, @intCast(n)),
                else => 1,
            }
        else
            1;

        // Clear the default "Workspace 1" (and any orchestration workspace) — free names, dirs, and TabViews.
        for (priv.workspace_names.items) |name| alloc.free(name);
        priv.workspace_names.clearRetainingCapacity();
        for (priv.workspace_dirs.items) |dir_str| alloc.free(dir_str);
        priv.workspace_dirs.clearRetainingCapacity();
        priv.workspace_ids.clearRetainingCapacity();
        for (priv.workspace_tab_views.items) |tv| tv.as(gobject.Object).unref();
        priv.workspace_tab_views.clearRetainingCapacity();
        for (priv.workspace_git_branches.items) |branch_opt| {
            if (branch_opt) |b| alloc.free(b);
        }
        priv.workspace_git_branches.clearRetainingCapacity();
        priv.workspace_git_dirty.clearRetainingCapacity();
        priv.workspace_git_staged_counts.clearRetainingCapacity();
        priv.workspace_git_unstaged_counts.clearRetainingCapacity();
        priv.workspace_pinned.clearRetainingCapacity();
        priv.notifications.clearAll();
        // Reset counter so addWorkspaceWithDir assigns correct numbers below.
        priv.next_workspace_number = 1;
        priv.orchestration_workspace_idx = null;

        // Recreate orchestration workspace first (index 0) if enabled.
        if (priv.termplex_cfg.orchestration.enabled orelse false) {
            const orch_dir_z = alloc.dupeZ(u8, priv.termplex_cfg.orchestration.dir) catch null;
            defer if (orch_dir_z) |d| alloc.free(d);
            const orch_idx = self.addWorkspaceWithDir(orch_dir_z);
            if (orch_idx) |idx| {
                self.renameWorkspace(idx, "Orchestrator");
                priv.orchestration_workspace_idx = idx;
            }
        }

        // Build resume manifest if memory is enabled and state exists.
        // This must happen BEFORE the orchestrator agent is launched so the
        // TERMPLEX_RESUME_MANIFEST env var is visible to the agent process.
        if (priv.memory_manager) |*mgr| {
            if (mgr.getState()) |mem_state| {
                // Read MEMORY.md
                var global_paths = memory_paths.resolveGlobalPaths(alloc, priv.termplex_cfg.orchestration.dir) catch null;
                defer if (global_paths) |*gp| gp.deinit(alloc);

                var global_memory_owned: bool = false;
                const global_memory: []const u8 = blk: {
                    if (global_paths) |gp| {
                        const f = std.fs.openFileAbsolute(gp.memory_md, .{}) catch break :blk "";
                        defer f.close();
                        const content = f.readToEndAlloc(alloc, 1024 * 1024) catch break :blk "";
                        global_memory_owned = true;
                        break :blk content;
                    }
                    break :blk "";
                };
                defer if (global_memory_owned) alloc.free(global_memory);

                // Read per-workspace memory.md files
                var ws_mem_names: std.ArrayListUnmanaged([]const u8) = .empty;
                var ws_mem_contents: std.ArrayListUnmanaged([]const u8) = .empty;
                // Track which contents were heap-allocated for cleanup
                var ws_mem_owned: std.ArrayListUnmanaged(bool) = .empty;
                defer {
                    for (ws_mem_contents.items, ws_mem_owned.items) |content, owned| {
                        if (owned) alloc.free(content);
                    }
                    ws_mem_names.deinit(alloc);
                    ws_mem_contents.deinit(alloc);
                    ws_mem_owned.deinit(alloc);
                }

                for (mem_state.workspace_names, mem_state.workspaces) |ws_name_m, ws| {
                    var wp = memory_paths.resolveWorkspacePaths(alloc, ws.dir) catch continue;
                    defer wp.deinit(alloc);

                    const ws_memory: []const u8 = blk: {
                        const f = std.fs.openFileAbsolute(wp.memory_md, .{}) catch break :blk "";
                        defer f.close();
                        break :blk f.readToEndAlloc(alloc, 1024 * 1024) catch break :blk "";
                    };
                    const owned = ws_memory.len > 0;

                    ws_mem_names.append(alloc, ws_name_m) catch continue;
                    ws_mem_contents.append(alloc, ws_memory) catch {
                        if (owned) alloc.free(ws_memory);
                        continue;
                    };
                    ws_mem_owned.append(alloc, owned) catch {
                        // Pop the content we just added since we can't track ownership
                        _ = ws_mem_contents.pop();
                        if (owned) alloc.free(ws_memory);
                        continue;
                    };
                }

                // Build manifest with per-workspace memories
                const manifest = memory_resume.buildManifest(
                    alloc,
                    mem_state,
                    global_memory,
                    ws_mem_names.items,
                    ws_mem_contents.items,
                ) catch null;
                defer if (manifest) |m| alloc.free(m);

                if (manifest) |m| {
                    log.info("resume manifest built ({d} bytes)", .{m.len});
                    // Write manifest to orchestration directory as resume_manifest.txt
                    if (global_paths) |gp| {
                        memory_paths.ensureDir(gp.dir) catch {};
                        const manifest_path = std.fmt.allocPrint(alloc, "{s}/resume_manifest.txt", .{gp.dir}) catch null;
                        defer if (manifest_path) |p| alloc.free(p);
                        const path = manifest_path orelse return;
                        const mf = std.fs.createFileAbsolute(path, .{}) catch null;
                        if (mf) |f| {
                            defer f.close();
                            f.writeAll(m) catch {};
                            log.info("resume manifest written to {s}", .{path});
                        }
                        // Set TERMPLEX_RESUME_MANIFEST env var
                        const path_z = alloc.dupeZ(u8, path) catch null;
                        defer if (path_z) |p| alloc.free(p);
                        if (path_z) |pz| {
                            _ = setenv("TERMPLEX_RESUME_MANIFEST", pz.ptr, 1);
                        }
                    }
                }
            }
        }

        // Accumulate tab counts and titles to pass to the window during
        // Phase 2 tab creation.
        var tab_counts = std.ArrayListUnmanaged(u32){};
        var tab_titles_per_ws = std.ArrayListUnmanaged([]const [:0]const u8){};
        var tab_snapshots_per_ws = std.ArrayListUnmanaged([]const session_mod.TabData){};
        var active_tab_indices = std.ArrayListUnmanaged(u32){};
        var tab_dirs_per_ws = std.ArrayListUnmanaged([]const [:0]const u8){};

        // If an orchestration workspace was created (index 0), seed its entry
        // in the parallel arrays so indices stay in sync with workspace indices.
        if (priv.orchestration_workspace_idx != null) {
            tab_counts.append(alloc, 1) catch {};
            tab_titles_per_ws.append(alloc, &[_][:0]const u8{}) catch {};
            tab_snapshots_per_ws.append(alloc, &[_]session_mod.TabData{}) catch {};
            active_tab_indices.append(alloc, 0) catch {};
            tab_dirs_per_ws.append(alloc, &[_][:0]const u8{}) catch {};
        }

        // Re-populate from saved data.
        for (ws_arr) |item| {
            // Extract name, dir, and tab info depending on format version.
            const name_str: []const u8 = blk: {
                if (format_version >= 2) {
                    switch (item) {
                        .object => |obj| {
                            const nv = obj.get("name") orelse continue;
                            switch (nv) {
                                .string => |s| break :blk s,
                                else => continue,
                            }
                        },
                        else => continue,
                    }
                } else {
                    switch (item) {
                        .string => |s| break :blk s,
                        else => continue,
                    }
                }
            };

            // Skip any Orchestrator entry that might have been saved by an
            // older build; it is recreated on startup unconditionally.
            if (std.mem.eql(u8, name_str, "ORCHESTRATOR") or std.mem.eql(u8, name_str, "Orchestrator")) continue;

            const home_fallback: []const u8 = std.posix.getenv("HOME") orelse "/tmp";

            const dir_str_raw: []const u8 = blk: {
                if (format_version >= 2) {
                    switch (item) {
                        .object => |obj| {
                            if (obj.get("dir")) |dv| {
                                switch (dv) {
                                    .string => |s| if (s.len > 0) break :blk s,
                                    else => {},
                                }
                            }
                        },
                        else => {},
                    }
                }
                break :blk home_fallback;
            };

            // v3: extract tab count and titles from "tabs" array.
            // v4: also restore workspace active tab index and per-tab dirs.
            // v5: restore full tab snapshots including split trees.
            // v2: extract tab_count from "tab_count" field.
            // v1: default to 1 tab.
            var tab_count: u32 = 1;
            const is_pinned = sessionWorkspacePinned(item);
            var active_tab_index: u32 = 0;
            var tab_title_list = std.ArrayListUnmanaged([:0]const u8){};
            var tab_snapshot_list = std.ArrayListUnmanaged(session_mod.TabData){};
            var tab_dir_list = std.ArrayListUnmanaged([:0]const u8){};
            if (format_version >= 4) {
                switch (item) {
                    .object => |obj| {
                        if (obj.get("active_tab_index")) |atv| {
                            switch (atv) {
                                .integer => |n| if (n >= 0 and n <= std.math.maxInt(u32)) {
                                    active_tab_index = @intCast(n);
                                },
                                else => {},
                            }
                        }
                    },
                    else => {},
                }
            }
            if (format_version >= 5) {
                switch (item) {
                    .object => |obj| {
                        if (obj.get("tabs")) |tabs_val| {
                            switch (tabs_val) {
                                .array => |tabs_arr| {
                                    tab_count = @intCast(tabs_arr.items.len);
                                    if (tab_count == 0) tab_count = 1;
                                    for (tabs_arr.items) |tab_item| {
                                        const snapshot = parseSessionTabData(alloc, tab_item) catch continue;
                                        tab_snapshot_list.append(alloc, snapshot) catch {
                                            var owned_snapshot = snapshot;
                                            owned_snapshot.deinit(alloc);
                                        };
                                    }
                                    if (tab_snapshot_list.items.len > 0) {
                                        tab_count = @intCast(tab_snapshot_list.items.len);
                                    }
                                },
                                else => {},
                            }
                        }
                    },
                    else => {},
                }
            } else if (format_version >= 3) {
                switch (item) {
                    .object => |obj| {
                        if (obj.get("tabs")) |tabs_val| {
                            switch (tabs_val) {
                                .array => |tabs_arr| {
                                    tab_count = @intCast(tabs_arr.items.len);
                                    if (tab_count == 0) tab_count = 1;
                                    for (tabs_arr.items) |tab_item| {
                                        switch (tab_item) {
                                            .object => |tab_obj| {
                                                if (tab_obj.get("title")) |tv| {
                                                    switch (tv) {
                                                        .string => |s| {
                                                            const t = alloc.dupeZ(u8, s) catch continue;
                                                            tab_title_list.append(alloc, t) catch {
                                                                alloc.free(t);
                                                            };
                                                        },
                                                        else => {},
                                                    }
                                                }
                                                if (format_version >= 4) {
                                                    if (tab_obj.get("dir")) |dv| {
                                                        switch (dv) {
                                                            .string => |s| {
                                                                const d = alloc.dupeZ(u8, s) catch continue;
                                                                tab_dir_list.append(alloc, d) catch {
                                                                    alloc.free(d);
                                                                };
                                                            },
                                                            else => {},
                                                        }
                                                    }
                                                }
                                            },
                                            else => {},
                                        }
                                    }
                                },
                                else => {},
                            }
                        }
                    },
                    else => {},
                }
            } else if (format_version == 2) {
                switch (item) {
                    .object => |obj| {
                        if (obj.get("tab_count")) |tcv| {
                            switch (tcv) {
                                .integer => |n| if (n > 0 and n <= std.math.maxInt(u32)) {
                                    tab_count = @as(u32, @intCast(n));
                                },
                                else => {},
                            }
                        }
                    },
                    else => {},
                }
            }

            const name: [:0]const u8 = alloc.dupeZ(u8, name_str) catch {
                log.warn("session restore: OOM allocating workspace name", .{});
                continue;
            };
            const dir: [:0]const u8 = self.normalizeWorkspaceDir(dir_str_raw) orelse {
                alloc.free(name);
                log.warn("session restore: OOM normalizing workspace dir", .{});
                continue;
            };

            if (self.workspaceIndexByDir(dir)) |_| {
                alloc.free(name);
                alloc.free(dir);
                log.info("session restore: skipping duplicate workspace dir '{s}'", .{dir_str_raw});
                continue;
            }
            const workspace_id: Uuid = blk: {
                if (format_version >= 6) {
                    switch (item) {
                        .object => |obj| {
                            if (obj.get("workspace_id")) |wv| switch (wv) {
                                .string => |s| break :blk uuid.parse(s) catch uuid.generate(),
                                else => {},
                            };
                        },
                        else => {},
                    }
                }
                break :blk uuid.generate();
            };
            const tab_view = adw.TabView.new();
            tab_view.as(gtk.Widget).setHexpand(1);
            tab_view.as(gtk.Widget).setVexpand(1);
            _ = tab_view.as(gobject.Object).ref();
            priv.workspace_names.append(alloc, name) catch {
                alloc.free(name);
                alloc.free(dir);
                tab_view.as(gobject.Object).unref();
                log.warn("session restore: OOM appending workspace name", .{});
                continue;
            };
            priv.workspace_dirs.append(alloc, dir) catch {
                _ = priv.workspace_names.pop();
                alloc.free(name);
                alloc.free(dir);
                tab_view.as(gobject.Object).unref();
                log.warn("session restore: OOM appending workspace dir", .{});
                continue;
            };
            priv.workspace_ids.append(alloc, workspace_id) catch {
                _ = priv.workspace_dirs.pop();
                _ = priv.workspace_names.pop();
                alloc.free(name);
                alloc.free(dir);
                tab_view.as(gobject.Object).unref();
                log.warn("session restore: OOM appending workspace id", .{});
                continue;
            };
            priv.workspace_tab_views.append(alloc, tab_view) catch {
                _ = priv.workspace_ids.pop();
                _ = priv.workspace_dirs.pop();
                _ = priv.workspace_names.pop();
                alloc.free(name);
                alloc.free(dir);
                tab_view.as(gobject.Object).unref();
                log.warn("session restore: OOM appending workspace tab_view", .{});
                continue;
            };
            priv.workspace_git_branches.append(alloc, null) catch {
                _ = priv.workspace_tab_views.pop();
                _ = priv.workspace_ids.pop();
                _ = priv.workspace_dirs.pop();
                _ = priv.workspace_names.pop();
                alloc.free(name);
                alloc.free(dir);
                tab_view.as(gobject.Object).unref();
                log.warn("session restore: OOM appending git_branches", .{});
                continue;
            };
            priv.workspace_git_dirty.append(alloc, false) catch {
                _ = priv.workspace_git_branches.pop();
                _ = priv.workspace_tab_views.pop();
                _ = priv.workspace_ids.pop();
                _ = priv.workspace_dirs.pop();
                _ = priv.workspace_names.pop();
                alloc.free(name);
                alloc.free(dir);
                tab_view.as(gobject.Object).unref();
                log.warn("session restore: OOM appending git_dirty", .{});
                continue;
            };
            priv.workspace_git_staged_counts.append(alloc, 0) catch {
                _ = priv.workspace_git_dirty.pop();
                _ = priv.workspace_git_branches.pop();
                _ = priv.workspace_tab_views.pop();
                _ = priv.workspace_ids.pop();
                _ = priv.workspace_dirs.pop();
                _ = priv.workspace_names.pop();
                alloc.free(name);
                alloc.free(dir);
                tab_view.as(gobject.Object).unref();
                log.warn("session restore: OOM appending git staged count", .{});
                continue;
            };
            priv.workspace_git_unstaged_counts.append(alloc, 0) catch {
                _ = priv.workspace_git_staged_counts.pop();
                _ = priv.workspace_git_dirty.pop();
                _ = priv.workspace_git_branches.pop();
                _ = priv.workspace_tab_views.pop();
                _ = priv.workspace_ids.pop();
                _ = priv.workspace_dirs.pop();
                _ = priv.workspace_names.pop();
                alloc.free(name);
                alloc.free(dir);
                tab_view.as(gobject.Object).unref();
                log.warn("session restore: OOM appending git unstaged count", .{});
                continue;
            };
            priv.workspace_pinned.append(alloc, is_pinned) catch {
                _ = priv.workspace_git_unstaged_counts.pop();
                _ = priv.workspace_git_staged_counts.pop();
                _ = priv.workspace_git_dirty.pop();
                _ = priv.workspace_git_branches.pop();
                _ = priv.workspace_tab_views.pop();
                _ = priv.workspace_ids.pop();
                _ = priv.workspace_dirs.pop();
                _ = priv.workspace_names.pop();
                alloc.free(name);
                alloc.free(dir);
                tab_view.as(gobject.Object).unref();
                log.warn("session restore: OOM appending workspace pinned state", .{});
                continue;
            };
            // Non-fatal if tab_count/title tracking fails; window will fall back to defaults.
            tab_counts.append(alloc, tab_count) catch {};
            active_tab_indices.append(alloc, @min(active_tab_index, tab_count - 1)) catch {};
            const owned_snapshots = if (tab_snapshot_list.items.len == 0)
                &[_]session_mod.TabData{}
            else
                tab_snapshot_list.toOwnedSlice(alloc) catch blk: {
                    for (tab_snapshot_list.items) |snapshot| {
                        var owned_snapshot = snapshot;
                        owned_snapshot.deinit(alloc);
                    }
                    tab_snapshot_list.deinit(alloc);
                    break :blk &[_]session_mod.TabData{};
                };
            tab_snapshots_per_ws.append(alloc, owned_snapshots) catch {
                if (owned_snapshots.len > 0) {
                    for (owned_snapshots) |snapshot| {
                        var owned_snapshot = snapshot;
                        owned_snapshot.deinit(alloc);
                    }
                    alloc.free(owned_snapshots);
                }
            };
            // Store the collected tab titles (may be empty for v1/v2).
            const owned_titles = if (tab_title_list.items.len == 0)
                &[_][:0]const u8{}
            else
                tab_title_list.toOwnedSlice(alloc) catch blk: {
                    for (tab_title_list.items) |t| alloc.free(t);
                    tab_title_list.deinit(alloc);
                    break :blk &[_][:0]const u8{};
                };
            tab_titles_per_ws.append(alloc, owned_titles) catch {
                if (owned_titles.len > 0) {
                    for (owned_titles) |t| alloc.free(t);
                    alloc.free(owned_titles);
                }
            };
            const owned_dirs = if (tab_dir_list.items.len == 0)
                &[_][:0]const u8{}
            else
                tab_dir_list.toOwnedSlice(alloc) catch blk: {
                    for (tab_dir_list.items) |tab_dir| alloc.free(tab_dir);
                    tab_dir_list.deinit(alloc);
                    break :blk &[_][:0]const u8{};
                };
            tab_dirs_per_ws.append(alloc, owned_dirs) catch {
                if (owned_dirs.len > 0) {
                    for (owned_dirs) |tab_dir| alloc.free(tab_dir);
                    alloc.free(owned_dirs);
                }
            };
            priv.next_workspace_number += 1;
        }

        // If we ended up with zero workspaces (e.g., all failed), add a default.
        if (priv.workspace_names.items.len == 0) {
            _ = self.addWorkspaceWithDir(null) orelse {
                log.warn("session restore: OOM creating fallback workspace", .{});
                return;
            };
        }

        // Update next_workspace_number to avoid collisions.
        priv.next_workspace_number = @as(u32, @intCast(priv.workspace_names.items.len)) + 1;

        // Store tab counts and titles for Phase 2 (consumed in initAndShowWindow).
        if (priv.restore_tab_counts) |old| alloc.free(old);
        priv.restore_tab_counts = tab_counts.toOwnedSlice(alloc) catch blk: {
            tab_counts.deinit(alloc);
            break :blk null;
        };

        // Store tab titles for Phase 2.
        if (priv.restore_tab_titles) |old| {
            for (old) |titles| {
                for (titles) |t| alloc.free(t);
                if (titles.len > 0) alloc.free(titles);
            }
            alloc.free(old);
        }
        priv.restore_tab_titles = tab_titles_per_ws.toOwnedSlice(alloc) catch blk: {
            for (tab_titles_per_ws.items) |titles| {
                for (titles) |t| alloc.free(t);
                if (titles.len > 0) alloc.free(titles);
            }
            tab_titles_per_ws.deinit(alloc);
            break :blk null;
        };

        if (priv.restore_tab_snapshots) |old| {
            for (old) |snapshots| {
                for (snapshots) |snapshot| {
                    var owned_snapshot = snapshot;
                    owned_snapshot.deinit(alloc);
                }
                if (snapshots.len > 0) alloc.free(snapshots);
            }
            alloc.free(old);
        }
        priv.restore_tab_snapshots = tab_snapshots_per_ws.toOwnedSlice(alloc) catch blk: {
            for (tab_snapshots_per_ws.items) |snapshots| {
                for (snapshots) |snapshot| {
                    var owned_snapshot = snapshot;
                    owned_snapshot.deinit(alloc);
                }
                if (snapshots.len > 0) alloc.free(snapshots);
            }
            tab_snapshots_per_ws.deinit(alloc);
            break :blk null;
        };

        if (priv.restore_active_tab_indices) |old| alloc.free(old);
        priv.restore_active_tab_indices = active_tab_indices.toOwnedSlice(alloc) catch blk: {
            active_tab_indices.deinit(alloc);
            break :blk null;
        };

        if (priv.restore_tab_dirs) |old| {
            for (old) |dirs| {
                for (dirs) |dir| alloc.free(dir);
                if (dirs.len > 0) alloc.free(dirs);
            }
            alloc.free(old);
        }
        priv.restore_tab_dirs = tab_dirs_per_ws.toOwnedSlice(alloc) catch blk: {
            for (tab_dirs_per_ws.items) |dirs| {
                for (dirs) |dir| alloc.free(dir);
                if (dirs.len > 0) alloc.free(dirs);
            }
            tab_dirs_per_ws.deinit(alloc);
            break :blk null;
        };

        // Restore active workspace index.
        if (root.object.get("active_workspace_index")) |av| {
            const saved_idx: u32 = switch (av) {
                .integer => |n| if (n >= 0 and n <= std.math.maxInt(u32))
                    @intCast(n)
                else
                    0,
                else => 0,
            };
            priv.active_workspace_idx = activeWorkspaceIndexFromSession(
                saved_idx,
                priv.orchestration_workspace_idx,
                priv.workspace_names.items.len,
            );
        }

        if (root.object.get("window_width")) |wv| {
            switch (wv) {
                .integer => |n| if (n > 0 and n <= std.math.maxInt(c_int)) {
                    priv.restore_window_width = @intCast(n);
                },
                else => {},
            }
        }

        if (root.object.get("window_height")) |hv| {
            switch (hv) {
                .integer => |n| if (n > 0 and n <= std.math.maxInt(c_int)) {
                    priv.restore_window_height = @intCast(n);
                },
                else => {},
            }
        }

        if (root.object.get("sidebar_width")) |sv| {
            switch (sv) {
                .integer => |n| if (n > 10 and n <= std.math.maxInt(c_int)) {
                    priv.restore_sidebar_width = @intCast(n);
                },
                else => {},
            }
        }

        // Restore pwd for git probing.
        if (root.object.get("pwd")) |pv| {
            if (pv == .string and pv.string.len > 0) {
                if (priv.current_pwd) |old| alloc.free(old);
                priv.current_pwd = alloc.dupeZ(u8, pv.string) catch null;
            }
        }

        log.info("session restore: loaded {d} workspace(s) (v{d}), active={d}", .{
            priv.workspace_names.items.len,
            format_version,
            priv.active_workspace_idx,
        });
    }

    // -----------------------------------------------------------------
    // Termplex: OSC 7337 orchestrator command handling
    // -----------------------------------------------------------------

    const OrchestratorSurfaceMatch = struct {
        surface: *Surface,
        workspace_idx: u32,
    };

    fn findGtkSurfaceByCore(self: *Self, core_surface: *CoreSurface) ?OrchestratorSurfaceMatch {
        const priv = self.private();
        const alloc = self.allocator();

        for (priv.workspace_tab_views.items, 0..) |tab_view, workspace_idx| {
            var tab_idx: c_int = 0;
            while (tab_idx < tab_view.getNPages()) : (tab_idx += 1) {
                const page = tab_view.getNthPage(tab_idx);
                const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
                const entries = collectTabSurfaceEntries(tab, alloc) orelse continue;
                defer alloc.free(entries);

                for (entries) |entry| {
                    const candidate_core_surface = entry.surface.core() orelse continue;
                    if (candidate_core_surface == core_surface) {
                        return .{
                            .surface = entry.surface,
                            .workspace_idx = @intCast(workspace_idx),
                        };
                    }
                }
            }
        }

        return null;
    }

    /// Handle an orchestrator command event from a surface (triggered by OSC 7337).
    /// The payload format is "cmd_start;<pid>;<command>" or "cmd_end;<pid>;<exit_code>".
    pub fn handleOrchestratorCmd(self: *Self, core_surface: *CoreSurface, payload: []const u8) void {
        const priv = self.private();
        var mgr = &(priv.memory_manager orelse return);

        // Determine event kind from payload prefix.
        var kind: memory_state_mgr.CommandEvent.Kind = undefined;
        var rest: []const u8 = undefined;

        if (std.mem.startsWith(u8, payload, "cmd_start;")) {
            kind = .start;
            rest = payload["cmd_start;".len..];
        } else if (std.mem.startsWith(u8, payload, "cmd_end;")) {
            kind = .end;
            rest = payload["cmd_end;".len..];
        } else {
            return; // Unknown format
        }

        // Parse PID from rest (format: "<pid>;<data>")
        const semi = std.mem.indexOfScalar(u8, rest, ';') orelse return;
        const pid = std.fmt.parseInt(u32, rest[0..semi], 10) catch return;
        const data = rest[semi + 1 ..];

        const resolved_context = self.resolveOrchestratorSurfaceContext(core_surface);
        const surface_match = self.findGtkSurfaceByCore(core_surface);
        const workspace_idx = if (surface_match) |match| match.workspace_idx else priv.active_workspace_idx;
        const workspace_id = self.workspaceIdString(self.allocator(), workspace_idx) catch null;
        defer if (workspace_id) |id| self.allocator().free(id);

        var surf_id_buf: [32]u8 = undefined;
        const fallback_surface_id = std.fmt.bufPrint(&surf_id_buf, "shell-{d}", .{pid}) catch "unknown";
        const surface_id: []const u8 = if (surface_match) |match|
            match.surface.getHistoryId() orelse fallback_surface_id
        else
            fallback_surface_id;

        const working_directory: ?[]const u8 = if (surface_match) |match|
            match.surface.getPwd()
        else
            null;

        const transcript_path = if (workspace_id) |id|
            terminal_history.transcriptPath(self.allocator(), id, surface_id) catch null
        else
            null;
        defer if (transcript_path) |path| self.allocator().free(path);

        const event = memory_state_mgr.CommandEvent{
            .kind = kind,
            .surface_uuid = surface_id,
            .workspace_id = workspace_id orelse "default",
            .workspace_name = resolved_context.workspace_name,
            .workspace_dir = resolved_context.workspace_dir,
            .working_directory = working_directory,
            .transcript_path = transcript_path,
            .command = if (kind == .start) data else null,
            .shell_pid = pid,
            .exit_code = if (kind == .end) std.fmt.parseInt(i32, data, 10) catch null else null,
            .source = "osc_7337",
        };

        mgr.handleCommandEvent(event);
        log.info("orchestrator cmd: {s}", .{payload});
    }

    fn resolveOrchestratorSurfaceContext(self: *Self, core_surface: *CoreSurface) memory_orchestrator_context.ResolvedSurfaceContext {
        const priv = self.private();
        const alloc = self.allocator();
        const ws_idx = priv.active_workspace_idx;
        const fallback_workspace_name: []const u8 = if (ws_idx < priv.workspace_names.items.len)
            priv.workspace_names.items[ws_idx]
        else
            "default";
        const fallback_workspace_dir: []const u8 = if (ws_idx < priv.workspace_dirs.items.len)
            priv.workspace_dirs.items[ws_idx]
        else
            "/tmp";

        var contexts: std.ArrayListUnmanaged(memory_orchestrator_context.SurfaceContext) = .empty;
        defer contexts.deinit(alloc);

        for (priv.workspace_tab_views.items, 0..) |tab_view, workspace_idx| {
            const workspace_name: []const u8 = if (workspace_idx < priv.workspace_names.items.len)
                priv.workspace_names.items[workspace_idx]
            else
                fallback_workspace_name;
            const workspace_dir: []const u8 = if (workspace_idx < priv.workspace_dirs.items.len)
                priv.workspace_dirs.items[workspace_idx]
            else
                fallback_workspace_dir;

            var tab_idx: c_int = 0;
            while (tab_idx < tab_view.getNPages()) : (tab_idx += 1) {
                const page = tab_view.getNthPage(tab_idx);
                const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;
                {
                    const entries = collectTabSurfaceEntries(tab, alloc) orelse continue;
                    defer alloc.free(entries);

                    for (entries) |entry| {
                        const candidate_core_surface = entry.surface.core() orelse continue;
                        contexts.append(alloc, .{
                            .core_surface_ptr = @intFromPtr(candidate_core_surface),
                            .workspace_name = workspace_name,
                            .workspace_dir = workspace_dir,
                        }) catch {
                            return .{
                                .workspace_name = fallback_workspace_name,
                                .workspace_dir = fallback_workspace_dir,
                            };
                        };
                    }
                }
            }
        }

        return memory_orchestrator_context.selectSurfaceContext(
            fallback_workspace_name,
            fallback_workspace_dir,
            contexts.items,
            @intFromPtr(core_surface),
        );
    }

    // -----------------------------------------------------------------
    // Termplex: git probe and port scanner
    // -----------------------------------------------------------------

    /// Update the current working directory for the active workspace.
    ///
    /// 1. Stores a copy of `pwd` in `current_pwd` (freeing any previous value).
    /// 2. Triggers a debounced git probe (2 s delay).
    /// 3. Triggers a burst port scan (6 additional scans at short intervals).
    ///
    /// The caller passes a temporary slice; this function duplicates it.
    pub fn updateWorkspacePwd(self: *Self, pwd: [:0]const u8) void {
        const alloc = self.allocator();
        const priv = self.private();

        // Update stored pwd.
        if (priv.current_pwd) |old| alloc.free(old);
        priv.current_pwd = alloc.dupeZ(u8, pwd) catch null;

        // Trigger debounced git probe.
        self.triggerGitProbe();

        // Trigger burst port scans.
        self.triggerBurstPortScan();
    }

    /// Schedule a git probe after a 2-second debounce.
    ///
    /// Cancels any in-flight debounce timer before scheduling a new one.
    fn triggerGitProbe(self: *Self) void {
        const priv = self.private();

        // Cancel previous debounce timer.
        if (priv.git_debounce_timer) |source| {
            _ = glib.Source.remove(source);
            priv.git_debounce_timer = null;
        }

        // Schedule new debounce timer (2 s).
        priv.git_debounce_timer = glib.timeoutAdd(2000, gitProbeCallback, self);
    }

    /// GLib timer callback: runs the git probe and updates the sidebar.
    ///
    /// This fires once (SOURCE_REMOVE) after the 2 s debounce.
    fn gitProbeCallback(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return @intFromBool(glib.SOURCE_REMOVE)));
        const alloc = self.allocator();
        const priv = self.private();

        // Clear the stored timer id.
        priv.git_debounce_timer = null;

        // Run the probe only if we have a pwd.
        const pwd = priv.current_pwd orelse return @intFromBool(glib.SOURCE_REMOVE);

        var result = git_probe.probe(alloc, pwd);
        defer result.deinit(alloc);

        // Update stored git state.
        if (priv.git_branch) |old| alloc.free(old);
        priv.git_branch = if (result.branch) |b|
            alloc.dupeZ(u8, b) catch null
        else
            null;
        priv.git_dirty = result.dirty;

        // Also update per-workspace arrays for the active workspace.
        const active_idx = priv.active_workspace_idx;
        if (active_idx < priv.workspace_git_branches.items.len) {
            if (priv.workspace_git_branches.items[active_idx]) |old_b| alloc.free(old_b);
            priv.workspace_git_branches.items[active_idx] = if (result.branch) |b|
                alloc.dupeZ(u8, b) catch null
            else
                null;
            priv.workspace_git_dirty.items[active_idx] = result.dirty;
            priv.workspace_git_staged_counts.items[active_idx] = result.staged_count;
            priv.workspace_git_unstaged_counts.items[active_idx] = result.unstaged_count;
            self.upsertTerminalHistoryProject(active_idx);
        }

        log.debug(
            "git probe: branch={s} dirty={}",
            .{ priv.git_branch orelse "<none>", priv.git_dirty },
        );

        // Update sidebar for the active workspace.
        self.updateSidebarGitState();

        return @intFromBool(glib.SOURCE_REMOVE);
    }

    /// Schedule a burst of 6 port scans at 500/1500/3000/5000/7500/10000 ms.
    ///
    /// Cancels any previously scheduled burst timers first.
    fn triggerBurstPortScan(self: *Self) void {
        const priv = self.private();
        const delays = [6]c_uint{ 500, 1500, 3000, 5000, 7500, 10000 };
        const callbacks = [_]glib.SourceFunc{
            burstPortScanCallback0,
            burstPortScanCallback1,
            burstPortScanCallback2,
            burstPortScanCallback3,
            burstPortScanCallback4,
            burstPortScanCallback5,
        };

        for (&priv.port_scan_burst_timers, delays, callbacks) |*slot, delay, callback| {
            if (slot.*) |source| {
                _ = glib.Source.remove(source);
                slot.* = null;
            }
            slot.* = glib.timeoutAdd(delay, callback, self);
        }
    }

    /// GLib timer callback: runs a single port scan (burst variant, fires once).
    fn burstPortScanCallbackIndex(ud: ?*anyopaque, index: usize) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return @intFromBool(glib.SOURCE_REMOVE)));

        if (index < self.private().port_scan_burst_timers.len) {
            self.private().port_scan_burst_timers[index] = null;
        }
        runPortScan(self);
        // Burst scans target the active workspace's pwd change — update
        // the sidebar immediately for the active workspace only.
        self.updateSidebarPortState();
        return @intFromBool(glib.SOURCE_REMOVE);
    }

    fn burstPortScanCallback0(ud: ?*anyopaque) callconv(.c) c_int {
        return burstPortScanCallbackIndex(ud, 0);
    }

    fn burstPortScanCallback1(ud: ?*anyopaque) callconv(.c) c_int {
        return burstPortScanCallbackIndex(ud, 1);
    }

    fn burstPortScanCallback2(ud: ?*anyopaque) callconv(.c) c_int {
        return burstPortScanCallbackIndex(ud, 2);
    }

    fn burstPortScanCallback3(ud: ?*anyopaque) callconv(.c) c_int {
        return burstPortScanCallbackIndex(ud, 3);
    }

    fn burstPortScanCallback4(ud: ?*anyopaque) callconv(.c) c_int {
        return burstPortScanCallbackIndex(ud, 4);
    }

    fn burstPortScanCallback5(ud: ?*anyopaque) callconv(.c) c_int {
        return burstPortScanCallbackIndex(ud, 5);
    }

    /// GLib timer callback: runs git probing for all workspaces and port
    /// scanning for the active workspace every 10 seconds.
    fn combinedProbeCallback(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return @intFromBool(glib.SOURCE_REMOVE)));
        const priv = self.private();

        if (priv.port_scan_timer == null) return @intFromBool(glib.SOURCE_REMOVE);

        const alloc = self.allocator();

        // 1. Probe git for all workspaces (skip orchestration).
        for (priv.workspace_dirs.items, 0..) |dir, i| {
            if (priv.orchestration_workspace_idx) |orch_idx| {
                if (i == orch_idx) continue;
            }

            var result = git_probe.probe(alloc, dir);
            defer result.deinit(alloc);

            const old_branch = priv.workspace_git_branches.items[i];
            const new_branch = result.branch;
            const old_dirty = priv.workspace_git_dirty.items[i];
            const new_dirty = result.dirty;
            const old_staged = priv.workspace_git_staged_counts.items[i];
            const old_unstaged = priv.workspace_git_unstaged_counts.items[i];

            const branch_changed = blk: {
                if (old_branch == null and new_branch == null) break :blk false;
                if (old_branch == null or new_branch == null) break :blk true;
                break :blk !std.mem.eql(u8, old_branch.?, new_branch.?);
            };

            if (branch_changed or
                old_dirty != new_dirty or
                old_staged != result.staged_count or
                old_unstaged != result.unstaged_count)
            {
                if (old_branch) |b| alloc.free(b);
                priv.workspace_git_branches.items[i] = if (new_branch) |b|
                    alloc.dupeZ(u8, b) catch null
                else
                    null;
                priv.workspace_git_dirty.items[i] = new_dirty;
                priv.workspace_git_staged_counts.items[i] = result.staged_count;
                priv.workspace_git_unstaged_counts.items[i] = result.unstaged_count;
                self.upsertTerminalHistoryProject(@intCast(i));
            }
        }

        // 2. Run port scan (active workspace only, uses app PID).
        runPortScan(self);

        // 3. Always refresh all workspace sidebars.
        self.refreshAllWorkspaceSidebars();

        return @intFromBool(glib.SOURCE_CONTINUE);
    }

    /// Idle callback to safely unref a TabView after workspace removal.
    /// Called from the GLib idle loop to avoid reentrancy during removeWorkspace.
    fn deferredTabViewUnref(ud: ?*anyopaque) callconv(.c) c_int {
        const tv: *adw.TabView = @ptrCast(@alignCast(ud orelse return @intFromBool(glib.SOURCE_REMOVE)));
        tv.as(gobject.Object).unref();
        return @intFromBool(glib.SOURCE_REMOVE);
    }

    /// One-shot callback to probe git for all workspaces at startup.
    /// Fires once ~500ms after launch so branch info appears quickly.
    fn initialProbeCallback(ud: ?*anyopaque) callconv(.c) c_int {
        const self_ptr: *Self = @ptrCast(@alignCast(ud orelse return @intFromBool(glib.SOURCE_REMOVE)));
        const alloc = self_ptr.allocator();
        const priv = self_ptr.private();

        // Mark as fired so the shutdown path doesn't try to cancel it.
        priv.initial_probe_timer = null;

        for (priv.workspace_dirs.items, 0..) |dir, i| {
            if (priv.orchestration_workspace_idx) |orch_idx| {
                if (i == orch_idx) continue;
            }
            var result = git_probe.probe(alloc, dir);
            defer result.deinit(alloc);

            if (priv.workspace_git_branches.items[i]) |old_b| alloc.free(old_b);
            priv.workspace_git_branches.items[i] = if (result.branch) |b|
                alloc.dupeZ(u8, b) catch null
            else
                null;
            priv.workspace_git_dirty.items[i] = result.dirty;
            priv.workspace_git_staged_counts.items[i] = result.staged_count;
            priv.workspace_git_unstaged_counts.items[i] = result.unstaged_count;
            self_ptr.upsertTerminalHistoryProject(@intCast(i));
        }

        self_ptr.refreshAllWorkspaceSidebars();
        return @intFromBool(glib.SOURCE_REMOVE);
    }

    /// Execute a port scan and update state + sidebar.
    ///
    /// Uses the current process PID as a placeholder since shell PIDs are not
    /// yet wired up.
    fn runPortScan(self: *Self) void {
        const alloc = self.allocator();
        const priv = self.private();

        // TODO: Scan shell PIDs from each workspace's surfaces instead of the
        // app's own PID.  Requires wiring surface child-process PIDs into
        // workspace state (blocked until per-surface PID tracking is added).
        const my_pid: std.posix.pid_t = @intCast(std.os.linux.getpid());
        const pids = [_]std.posix.pid_t{my_pid};

        const results = port_scanner.scan(alloc, &pids) catch |err| {
            log.debug("port scan failed: {}", .{err});
            return;
        };
        defer port_scanner.deinitResults(alloc, results);

        // Build a formatted string of ports (e.g. ":3000 :8080").
        var ports_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer ports_buf.deinit(alloc);

        for (results) |r| {
            for (r.ports) |port| {
                if (ports_buf.items.len > 0) {
                    ports_buf.appendSlice(alloc, " ") catch break;
                }
                var tmp: [8]u8 = undefined;
                const s = std.fmt.bufPrint(&tmp, ":{d}", .{port}) catch continue;
                ports_buf.appendSlice(alloc, s) catch break;
            }
        }

        // Replace listening_ports_str.
        if (priv.listening_ports_str) |old| alloc.free(old);
        if (ports_buf.items.len > 0) {
            priv.listening_ports_str = alloc.dupeZ(u8, ports_buf.items) catch null;
        } else {
            priv.listening_ports_str = null;
        }

        log.debug("port scan: ports={s}", .{priv.listening_ports_str orelse "<none>"});
    }

    /// Push the current git state to the active workspace tab in the sidebar.
    fn updateSidebarGitState(self: *Self) void {
        const priv = self.private();
        const active_idx = priv.active_workspace_idx;
        const name = if (active_idx < priv.workspace_names.items.len)
            priv.workspace_names.items[active_idx]
        else
            return;

        // Build branch label: "main*" if dirty, "main" if clean, null if no branch.
        var branch_buf: [256]u8 = undefined;
        const branch_z: ?[:0]const u8 = blk: {
            const b = priv.git_branch orelse break :blk null;
            const label = std.fmt.bufPrintZ(
                &branch_buf,
                "{s}",
                .{b},
            ) catch break :blk null;
            break :blk label;
        };

        var dir_buf: [512]u8 = undefined;
        const dir_z: ?[:0]const u8 = self.formatDirDisplay(active_idx, &dir_buf);
        const staged_count = if (active_idx < priv.workspace_git_staged_counts.items.len)
            priv.workspace_git_staged_counts.items[active_idx]
        else
            0;
        const unstaged_count = if (active_idx < priv.workspace_git_unstaged_counts.items.len)
            priv.workspace_git_unstaged_counts.items[active_idx]
        else
            0;

        // Update the sidebar in every open window.
        updateSidebarForAllWindows(self, active_idx, name, priv.listening_ports_str, branch_z, dir_z, staged_count, unstaged_count);
    }

    /// Push the current port state to the active workspace tab in the sidebar.
    fn updateSidebarPortState(self: *Self) void {
        const priv = self.private();
        const active_idx = priv.active_workspace_idx;
        const name = if (active_idx < priv.workspace_names.items.len)
            priv.workspace_names.items[active_idx]
        else
            return;

        // Read branch from per-workspace arrays (source of truth).
        var branch_buf: [256]u8 = undefined;
        const branch_z: ?[:0]const u8 = blk: {
            if (active_idx >= priv.workspace_git_branches.items.len) break :blk null;
            const b = priv.workspace_git_branches.items[active_idx] orelse break :blk null;
            const dirty = if (active_idx < priv.workspace_git_dirty.items.len) priv.workspace_git_dirty.items[active_idx] else false;
            const label = std.fmt.bufPrintZ(
                &branch_buf,
                "{s}{s}",
                .{ b, if (dirty and active_idx >= priv.workspace_git_staged_counts.items.len and active_idx >= priv.workspace_git_unstaged_counts.items.len) "*" else "" },
            ) catch break :blk null;
            break :blk label;
        };

        var dir_buf: [512]u8 = undefined;
        const dir_z: ?[:0]const u8 = self.formatDirDisplay(active_idx, &dir_buf);
        const staged_count = if (active_idx < priv.workspace_git_staged_counts.items.len)
            priv.workspace_git_staged_counts.items[active_idx]
        else
            0;
        const unstaged_count = if (active_idx < priv.workspace_git_unstaged_counts.items.len)
            priv.workspace_git_unstaged_counts.items[active_idx]
        else
            0;

        updateSidebarForAllWindows(self, active_idx, name, priv.listening_ports_str, branch_z, dir_z, staged_count, unstaged_count);
    }

    /// Update the active workspace tab in the sidebar of every open window.
    fn updateSidebarForAllWindows(
        self: *Self,
        active_idx: u32,
        name: ?[:0]const u8,
        port_text: ?[:0]const u8,
        branch_text: ?[:0]const u8,
        dir_text: ?[:0]const u8,
        staged_count: u32,
        unstaged_count: u32,
    ) void {
        const is_pinned = self.workspacePinned(active_idx);
        const Ctx = struct {
            active_idx: u32,
            name: ?[:0]const u8,
            port_text: ?[:0]const u8,
            branch_text: ?[:0]const u8,
            dir_text: ?[:0]const u8,
            staged_count: u32,
            unstaged_count: u32,
            is_pinned: bool,
            has_unread: bool,
        };
        var ctx = Ctx{
            .active_idx = active_idx,
            .name = name,
            .port_text = port_text,
            .branch_text = branch_text,
            .dir_text = dir_text,
            .staged_count = staged_count,
            .unstaged_count = unstaged_count,
            .is_pinned = is_pinned,
            .has_unread = self.workspaceUnreadCount(active_idx) > 0,
        };
        const list = self.as(gtk.Application).getWindows();
        list.foreach(struct {
            fn cb(data: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) void {
                const c: *Ctx = @ptrCast(@alignCast(userdata orelse return));
                const ptr: *gtk.Window = @ptrCast(@alignCast(data orelse return));
                const win = gobject.ext.cast(Window, ptr) orelse return;
                win.getSidebar().updateWorkspace(c.active_idx, c.name, c.port_text, c.branch_text, c.dir_text, true, c.has_unread, c.staged_count, c.unstaged_count, c.is_pinned);
            }
        }.cb, @ptrCast(&ctx));
    }

    /// Refresh all workspace tabs in the sidebar across all windows.
    pub fn refreshAllWorkspaceSidebars(self: *Self) void {
        const priv = self.private();
        const workspace_count = priv.workspace_names.items.len;
        const list = self.as(gtk.Application).getWindows();

        var i: u32 = 0;
        while (i < workspace_count) : (i += 1) {
            const name = priv.workspace_names.items[i];
            const is_active = (i == priv.active_workspace_idx);

            // ORCHESTRATOR: show only name + dir, suppress git/ports.
            const is_orchestrator = if (priv.orchestration_workspace_idx) |orch_idx| i == orch_idx else false;

            // Port text: only for active workspace, never for orchestrator.
            const port_text: ?[:0]const u8 = if (is_active and !is_orchestrator) priv.listening_ports_str else null;

            // Branch text from per-workspace arrays (suppressed for orchestrator).
            var branch_buf: [256]u8 = undefined;
            const branch_z: ?[:0]const u8 = blk: {
                if (is_orchestrator) break :blk null;
                if (i >= priv.workspace_git_branches.items.len) break :blk null;
                const b = priv.workspace_git_branches.items[i] orelse break :blk null;
                const dirty = if (i < priv.workspace_git_dirty.items.len) priv.workspace_git_dirty.items[i] else false;
                const label = std.fmt.bufPrintZ(
                    &branch_buf,
                    "{s}{s}",
                    .{ b, if (dirty and i >= priv.workspace_git_staged_counts.items.len and i >= priv.workspace_git_unstaged_counts.items.len) "*" else "" },
                ) catch break :blk null;
                break :blk label;
            };
            const staged_count: u32 = if (!is_orchestrator and i < priv.workspace_git_staged_counts.items.len)
                priv.workspace_git_staged_counts.items[i]
            else
                0;
            const unstaged_count: u32 = if (!is_orchestrator and i < priv.workspace_git_unstaged_counts.items.len)
                priv.workspace_git_unstaged_counts.items[i]
            else
                0;
            const is_pinned = self.workspacePinned(i);

            // Dir text with ~ shorthand.
            var dir_buf: [512]u8 = undefined;
            const dir_z: ?[:0]const u8 = self.formatDirDisplay(i, &dir_buf);

            // NOTE: branch_buf and dir_buf are stack-local but list.foreach
            // runs synchronously on the GLib main thread, so pointers into
            // these buffers are valid for the duration of the foreach call.
            const Ctx = struct {
                idx: u32,
                name_val: ?[:0]const u8,
                port_val: ?[:0]const u8,
                branch_val: ?[:0]const u8,
                dir_val: ?[:0]const u8,
                active: bool,
                has_unread: bool,
                staged_count: u32,
                unstaged_count: u32,
                is_pinned: bool,
            };
            var ctx = Ctx{
                .idx = i,
                .name_val = name,
                .port_val = port_text,
                .branch_val = branch_z,
                .dir_val = dir_z,
                .active = is_active,
                .has_unread = self.workspaceUnreadCount(i) > 0,
                .staged_count = staged_count,
                .unstaged_count = unstaged_count,
                .is_pinned = is_pinned,
            };
            list.foreach(struct {
                fn cb(data: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) void {
                    const c: *Ctx = @ptrCast(@alignCast(userdata orelse return));
                    const ptr: *gtk.Window = @ptrCast(@alignCast(data orelse return));
                    const win = gobject.ext.cast(Window, ptr) orelse return;
                    win.getSidebar().updateWorkspace(c.idx, c.name_val, c.port_val, c.branch_val, c.dir_val, c.active, c.has_unread, c.staged_count, c.unstaged_count, c.is_pinned);
                }
            }.cb, @ptrCast(&ctx));
        }

        const active_idx = priv.active_workspace_idx;
        list.foreach(struct {
            fn cb(data: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) void {
                const idx_ptr: *const u32 = @ptrCast(@alignCast(userdata orelse return));
                const ptr: *gtk.Window = @ptrCast(@alignCast(data orelse return));
                const win = gobject.ext.cast(Window, ptr) orelse return;
                win.getSidebar().setActiveIndex(idx_ptr.*);
            }
        }.cb, @ptrCast(@constCast(&active_idx)));
    }

    /// Run the application. This is a replacement for `gio.Application.run`
    /// because we want more tight control over our event loop so we can
    /// integrate it with libtermplex.
    pub fn run(self: *Self) !void {
        // Based on the actual `gio.Application.run` implementation:
        // https://github.com/GNOME/glib/blob/a8e8b742e7926e33eb635a8edceac74cf239d6ed/gio/gapplication.c#L2533

        // Acquire the default context for the application
        const ctx = glib.MainContext.default();
        if (glib.MainContext.acquire(ctx) == 0) return error.ContextAcquireFailed;

        // The final cleanup that is always required at the end of running.
        defer {
            // Ensure our timer source is removed
            self.stopQuitTimer();

            // Sync any remaining settings
            gio.Settings.sync();

            // Clear out the event loop, don't block.
            while (glib.MainContext.iteration(ctx, 0) != 0) {}

            // Release the context so something else can use it.
            defer glib.MainContext.release(ctx);
        }

        // Register the application
        var err_: ?*glib.Error = null;
        if (self.as(gio.Application).register(
            null,
            &err_,
        ) == 0) {
            if (err_) |err| {
                defer err.free();
                log.warn(
                    "error registering application: {s}",
                    .{err.f_message orelse "(unknown)"},
                );
            }

            return error.ApplicationRegisterFailed;
        }
        assert(err_ == null);

        // This just calls the `activate` signal but its part of the normal startup
        // routine so we just call it, but only if the config allows it (this allows
        // for launching Termplex in the "background" without immediately opening
        // a window).
        //
        // https://gitlab.gnome.org/GNOME/glib/-/blob/bd2ccc2f69ecfd78ca3f34ab59e42e2b462bad65/gio/gapplication.c#L2302
        const priv = self.private();
        {
            // We need to scope any config access because once we run our
            // event loop, this can change out from underneath us.
            const config = priv.config.get();
            if (config.@"initial-window") self.as(gio.Application).activate();
        }

        // If we are NOT the primary instance, then we never want to run.
        // This means that another instance of the GTK app is running.
        if (self.as(gio.Application).getIsRemote() != 0) {
            log.debug(
                "application is remote, exiting run loop after activation",
                .{},
            );
            return;
        }

        // Tell systemd that we are ready.
        systemd.notify.ready();

        log.debug("entering runloop", .{});
        defer log.debug("exiting runloop", .{});
        priv.running = true;
        while (priv.running) {
            _ = glib.MainContext.iteration(ctx, 1);

            // Tick the core Termplex terminal app
            try priv.core_app.tick(priv.rt_app);

            // Check if we must quit based on the current state.
            const must_quit = q: {
                // If we are configured to always stay running, don't quit.
                const config = priv.config.get();
                if (!config.@"quit-after-last-window-closed") break :q false;

                // If the quit timer has expired, quit.
                if (priv.quit_timer == .expired) {
                    log.debug("must_quit due to quit timer expired", .{});
                    break :q true;
                }

                // If we have no windows attached to our app, also quit.
                // We only do this if we don't have the closed delay set,
                // because with the closed delay set we'll exit eventually.
                if (config.@"quit-after-last-window-closed-delay" == null) {
                    if (priv.requested_window and @as(
                        ?*glib.List,
                        self.as(gtk.Application).getWindows(),
                    ) == null) {
                        log.debug("must_quit due to no app windows", .{});
                        break :q true;
                    }
                }

                // No quit conditions met
                break :q false;
            };

            if (must_quit) {
                // All must quit scenarios do not need confirmation.
                // Furthermore, must quit scenarios may result in a situation
                // where its unsafe to even access the app/surface memory
                // since its in the process of being freed. We must simply
                // begin our exit immediately.
                self.quitNow();
            }
        }
    }

    /// Quit the application. This will start the process to stop the
    /// run loop. It will not `posix.exit`.
    pub fn quit(self: *Self) void {
        const priv = self.private();

        // If our run loop has already exited then we are done.
        if (!priv.running) return;

        // If our core app doesn't need to confirm quit then we
        // can exit immediately.
        if (!priv.core_app.needsConfirmQuit()) {
            self.quitNow();
            return;
        }

        // Get the parent for our dialog
        const parent: ?*gtk.Widget = parent: {
            const list = gtk.Window.listToplevels();
            defer list.free();
            const focused = @as(?*glib.List, list.findCustom(
                null,
                findActiveWindow,
            )) orelse {
                // If we have an active surface then we should have
                // a window available but in the rare case we don't we
                // should exit so we don't crash.
                break :parent null;
            };
            break :parent @ptrCast(@alignCast(focused.f_data));
        };

        // Show a confirmation dialog
        const dialog: *CloseConfirmationDialog = .new(.app);
        _ = CloseConfirmationDialog.signals.@"close-request".connect(
            dialog,
            *Application,
            handleCloseConfirmation,
            self,
            .{},
        );

        // Show it
        dialog.present(parent);
    }

    fn quitNow(self: *Self) void {
        // Get all our windows and destroy them, forcing them to free.
        const list = gtk.Window.listToplevels();
        defer list.free();
        list.foreach(struct {
            fn callback(data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
                const ptr = data orelse return;
                const window: *gtk.Window = @ptrCast(@alignCast(ptr));

                // We only want to destroy our windows. These windows own
                // every other type of window that is possible so this will
                // trigger a proper shutdown sequence.
                //
                // We previously just destroyed ALL windows but this leads to
                // a double-free with the fcitx ime, because it has a nested
                // gtk.Window as a property that we don't own and it later
                // tries to free on its own. I think this is probably a bug in
                // the fcitx ime widget but still, we don't want a double free!
                if (gobject.ext.isA(window, Window)) {
                    window.destroy();
                }
            }
        }.callback, null);

        // Trigger our runloop exit.
        self.private().running = false;
    }

    /// apprt API to perform an action.
    pub fn performAction(
        self: *Self,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !bool {
        switch (action) {
            .close_tab => return Action.closeTab(target, value),
            .close_window => return Action.closeWindow(target),

            .copy_title_to_clipboard => return Action.copyTitleToClipboard(target),

            .config_change => try Action.configChange(
                self,
                target,
                value.config,
            ),

            .desktop_notification => Action.desktopNotification(self, target, value),

            .equalize_splits => return Action.equalizeSplits(target),

            .goto_split => return Action.gotoSplit(target, value),

            .goto_window => return Action.gotoWindow(value),

            .goto_tab => return Action.gotoTab(target, value),

            .initial_size => return Action.initialSize(target, value),

            .inspector => return Action.controlInspector(target, value),

            .key_sequence => return Action.keySequence(target, value),
            .key_table => return Action.keyTable(target, value),

            .mouse_over_link => Action.mouseOverLink(target, value),
            .mouse_shape => Action.mouseShape(target, value),
            .mouse_visibility => Action.mouseVisibility(target, value),

            .move_tab => return Action.moveTab(target, value),

            .new_split => return Action.newSplit(target, value),

            .new_tab => return Action.newTab(target),

            .new_window => try Action.newWindow(
                self,
                switch (target) {
                    .app => null,
                    .surface => |v| v,
                },
                .none,
            ),

            .open_config => return Action.openConfig(self),

            .open_url => Action.openUrl(self, value),

            .check_for_updates => {
                self.checkForUpdates();
                return true;
            },

            .pwd => {
                Action.pwd(target, value);
                // Termplex: trigger git probe and port scan on pwd change.
                self.updateWorkspacePwd(value.pwd);
            },

            .present_terminal => return Action.presentTerminal(target),

            .progress_report => return Action.progressReport(target, value),

            .prompt_title => return Action.promptTitle(target, value),

            .quit => self.quit(),

            .quit_timer => try Action.quitTimer(self, value),

            .reload_config => try Action.reloadConfig(self, target, value),

            .render => Action.render(target),

            .resize_split => return Action.resizeSplit(target, value),

            .ring_bell => Action.ringBell(target),

            .scrollbar => Action.scrollbar(target, value),

            .set_title => Action.setTitle(target, value),
            .set_tab_title => return Action.setTabTitle(target, value),

            .show_child_exited => return Action.showChildExited(target, value),

            .show_gtk_inspector => Action.showGtkInspector(),

            .size_limit => return Action.sizeLimit(target, value),

            .toggle_maximize => Action.toggleMaximize(target),
            .toggle_fullscreen => Action.toggleFullscreen(target),
            .toggle_quick_terminal => return Action.toggleQuickTerminal(self),
            .toggle_tab_overview => return Action.toggleTabOverview(target),
            .toggle_window_decorations => return Action.toggleWindowDecorations(target),
            .toggle_command_palette => return Action.toggleCommandPalette(target),
            .toggle_split_zoom => return Action.toggleSplitZoom(target),
            .show_on_screen_keyboard => return Action.showOnScreenKeyboard(target),
            .command_finished => return Action.commandFinished(target, value),
            .readonly => return Action.setReadonly(target, value),

            .start_search => Action.startSearch(target, value),
            .end_search => Action.endSearch(target),
            .search_total => Action.searchTotal(target, value),
            .search_selected => Action.searchSelected(target, value),

            // Unimplemented
            .secure_input,
            .close_all_windows,
            .float_window,
            .toggle_visibility,
            .toggle_background_opacity,
            .cell_size,
            .render_inspector,
            .renderer_health,
            .color_change,
            .reset_window_size,
            .undo,
            .redo,
            => {
                log.warn("unimplemented action={}", .{action});
                return false;
            },
        }

        // Assume it was handled. The unhandled case must be explicit
        // in the switch above.
        return true;
    }

    /// Returns the core app associated with this application. This is
    /// not a reference-counted type so you should not store this.
    pub fn core(self: *Self) *CoreApp {
        return self.private().core_app;
    }

    /// Returns the apprt application associated with this application.
    pub fn rt(self: *Self) *ApprtApp {
        return self.private().rt_app;
    }

    /// Returns the app winproto implementation.
    pub fn winproto(self: *Self) *winprotopkg.App {
        return &self.private().winproto;
    }

    /// This will get called when there are no more open surfaces.
    fn startQuitTimer(self: *Self) void {
        const priv = self.private();
        const config = priv.config.get();

        // Cancel any previous timer.
        self.stopQuitTimer();

        // This is a no-op unless we are configured to quit after last window is closed.
        if (!config.@"quit-after-last-window-closed") return;

        // If a delay is configured, set a timeout function to quit after the delay.
        if (config.@"quit-after-last-window-closed-delay") |v| {
            priv.quit_timer = .{
                .active = glib.timeoutAdd(
                    v.asMilliseconds(),
                    handleQuitTimerExpired,
                    self,
                ),
            };
        } else {
            // If no delay is configured, treat it as expired.
            priv.quit_timer = .expired;
        }
    }

    /// This will get called when a new surface gets opened.
    fn stopQuitTimer(self: *Self) void {
        const priv = self.private();
        switch (priv.quit_timer) {
            .off => {},
            .expired => priv.quit_timer = .off,
            .active => |source| {
                if (glib.Source.remove(source) == 0) {
                    log.warn(
                        "unable to remove quit timer source={d}",
                        .{source},
                    );
                }

                priv.quit_timer = .off;
            },
        }
    }

    fn loadRuntimeCss(self: *Self) (Allocator.Error || std.Io.Writer.Error)!void {
        const alloc = self.allocator();
        const priv: *Private = self.private();
        const config = priv.config.get();

        var buf: std.Io.Writer.Allocating = try .initCapacity(alloc, 2048);
        defer buf.deinit();

        const writer = &buf.writer;

        // Load standard css first as it can override some of the user configured styling.
        try loadRuntimeCss414(config, writer);
        try loadRuntimeCss416(config, writer);

        const unfocused_fill: CoreConfig.Color = config.@"unfocused-split-fill" orelse config.background;

        try writer.print(
            \\widget.unfocused-split {{
            \\ opacity: {d:.2};
            \\ background-color: rgb({d},{d},{d});
            \\}}
            \\
        , .{
            1.0 - config.@"unfocused-split-opacity",
            unfocused_fill.r,
            unfocused_fill.g,
            unfocused_fill.b,
        });

        if (config.@"split-divider-color") |color| {
            try writer.print(
                \\.window .split paned > separator {{
                \\  color: rgb({[r]d},{[g]d},{[b]d});
                \\  background: rgb({[r]d},{[g]d},{[b]d});
                \\}}
                \\
            , .{
                .r = color.r,
                .g = color.g,
                .b = color.b,
            });
        }

        if (config.@"window-title-font-family") |font_family| {
            try writer.print(
                \\.window headerbar {{
                \\  font-family: "{[font_family]s}";
                \\}}
                \\
            , .{ .font_family = font_family });
        }

        const contents = buf.written();

        log.debug("runtime CSS is {d} bytes", .{contents.len});

        const bytes = glib.Bytes.new(contents.ptr, contents.len);
        defer bytes.unref();

        // Clears any previously loaded CSS from this provider
        priv.css_provider.loadFromBytes(bytes);
    }

    /// Load runtime CSS for older than GTK 4.16
    fn loadRuntimeCss414(
        config: *const CoreConfig,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        if (gtk_version.runtimeAtLeast(4, 16, 0)) return;

        const window_theme = config.@"window-theme";
        const headerbar_background = config.@"window-titlebar-background" orelse config.background;
        const headerbar_foreground = config.@"window-titlebar-foreground" orelse config.foreground;

        switch (window_theme) {
            .termplex => try writer.print(
                \\windowhandle {{
                \\  background-color: rgb({d},{d},{d});
                \\  color: rgb({d},{d},{d});
                \\}}
                \\windowhandle:backdrop {{
                \\ background-color: oklab(from rgb({d},{d},{d}) calc(l * 0.9) a b / alpha);
                \\}}
                \\
            , .{
                headerbar_background.r,
                headerbar_background.g,
                headerbar_background.b,
                headerbar_foreground.r,
                headerbar_foreground.g,
                headerbar_foreground.b,
                headerbar_background.r,
                headerbar_background.g,
                headerbar_background.b,
            }),
            else => {},
        }
    }

    /// Load runtime for GTK 4.16 and newer
    fn loadRuntimeCss416(
        config: *const CoreConfig,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        if (gtk_version.runtimeUntil(4, 16, 0)) return;

        const window_theme = config.@"window-theme";
        const headerbar_background = config.@"window-titlebar-background" orelse config.background;
        const headerbar_foreground = config.@"window-titlebar-foreground" orelse config.foreground;

        try writer.writeAll(
            \\/*
            \\ * Child Exited Overlay
            \\ */
            \\
            \\.child-exited.normal revealer widget {
            \\  background-color: color-mix(
            \\    in srgb,
            \\    var(--success-bg-color),
            \\    transparent 50%
            \\  );
            \\}
            \\
            \\.child-exited.abnormal revealer widget {
            \\  background-color: color-mix(
            \\    in srgb,
            \\    var(--error-bg-color),
            \\    transparent 50%
            \\  );
            \\}
            \\
            \\/*
            \\ * Surface
            \\ */
            \\
            \\.surface progressbar.error trough progress {
            \\  background-color: color-mix(
            \\    in srgb,
            \\    var(--error-bg-color),
            \\    transparent 50%
            \\  );
            \\}
            \\
            \\.surface .bell-overlay {
            \\  border-color: color-mix(
            \\    in srgb,
            \\    var(--accent-color),
            \\    transparent 50%
            \\  );
            \\}
            \\
            \\/*
            \\ * Splits
            \\ */
            \\
            \\.window .split paned > separator {
            \\  background-color: color-mix(
            \\    in srgb,
            \\    var(--window-bg-color),
            \\    transparent 0%
            \\  );
            \\}
            \\
        );

        switch (window_theme) {
            .termplex => try writer.print(
                \\:root {{
                \\  --termplex-fg: rgb({d},{d},{d});
                \\  --termplex-bg: rgb({d},{d},{d});
                \\  --headerbar-fg-color: var(--termplex-fg);
                \\  --headerbar-bg-color: var(--termplex-bg);
                \\  --headerbar-backdrop-color: oklab(from var(--headerbar-bg-color) calc(l * 0.9) a b / alpha);
                \\  --overview-fg-color: var(--termplex-fg);
                \\  --overview-bg-color: var(--termplex-bg);
                \\  --popover-fg-color: var(--termplex-fg);
                \\  --popover-bg-color: var(--termplex-bg);
                \\  --window-fg-color: var(--termplex-fg);
                \\  --window-bg-color: var(--termplex-bg);
                \\}}
                \\windowhandle {{
                \\  background-color: var(--headerbar-bg-color);
                \\  color: var(--headerbar-fg-color);
                \\}}
                \\windowhandle:backdrop {{
                \\ background-color: var(--headerbar-backdrop-color);
                \\}}
            , .{
                headerbar_foreground.r,
                headerbar_foreground.g,
                headerbar_foreground.b,
                headerbar_background.r,
                headerbar_background.g,
                headerbar_background.b,
            }),
            else => {},
        }
    }

    fn loadCustomCss(self: *Self) (std.fs.File.ReadError || Allocator.Error)!void {
        const priv: *Private = self.private();
        const alloc = self.allocator();
        const display = gdk.Display.getDefault() orelse {
            log.warn("unable to get display", .{});
            return;
        };

        // unload the previously loaded style providers
        for (priv.custom_css_providers.items) |provider| {
            gtk.StyleContext.removeProviderForDisplay(
                display,
                provider.as(gtk.StyleProvider),
            );
            provider.unref();
        }
        priv.custom_css_providers.clearRetainingCapacity();

        const config = priv.config.get();
        for (config.@"gtk-custom-css".value.items) |p| {
            const path, const optional = switch (p) {
                .optional => |path| .{ path, true },
                .required => |path| .{ path, false },
            };
            const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
                if (err != error.FileNotFound or !optional) {
                    log.warn(
                        "error opening gtk-custom-css file {s}: {}",
                        .{ path, err },
                    );
                }
                continue;
            };
            defer file.close();

            const css_file_size_limit = 5 * 1024 * 1024; // 5MB

            log.info("loading gtk-custom-css path={s}", .{path});
            const contents = file.readToEndAlloc(
                alloc,
                css_file_size_limit,
            ) catch |err| switch (err) {
                error.FileTooBig => {
                    log.warn("gtk-custom-css file {s} was larger than {Bi}", .{ path, css_file_size_limit });
                    continue;
                },
                else => |e| return e,
            };
            defer alloc.free(contents);

            const bytes = glib.Bytes.new(contents.ptr, contents.len);
            defer bytes.unref();

            const css_provider = gtk.CssProvider.new();
            errdefer css_provider.unref();

            _ = gtk.CssProvider.signals.parsing_error.connect(
                css_provider,
                *Self,
                signalCssParsingError,
                self,
                .{},
            );

            try priv.custom_css_providers.append(alloc, css_provider);

            css_provider.loadFromBytes(bytes);

            gtk.StyleContext.addProviderForDisplay(
                display,
                css_provider.as(gtk.StyleProvider),
                gtk.STYLE_PROVIDER_PRIORITY_USER,
            );
        }
    }

    fn syncActionAccelerators(self: *Self) void {
        self.syncActionAccelerator("app.quit", .{ .quit = {} });
        self.syncActionAccelerator("app.open-config", .{ .open_config = {} });
        self.syncActionAccelerator("app.reload-config", .{ .reload_config = {} });
        self.syncActionAccelerator("win.toggle-inspector", .{ .inspector = .toggle });
        self.syncActionAccelerator("app.show-gtk-inspector", .show_gtk_inspector);
        self.syncActionAccelerator("win.toggle-command-palette", .toggle_command_palette);
        self.syncActionAccelerator("win.close", .{ .close_window = {} });
        self.syncActionAccelerator("win.new-window", .{ .new_window = {} });
        self.syncActionAccelerator("win.new-tab", .{ .new_tab = {} });
        self.syncActionAccelerator("win.close-tab::this", .{ .close_tab = .this });
        self.syncActionAccelerator("tab.close::this", .{ .close_tab = .this });
        self.syncActionAccelerator("win.split-right", .{ .new_split = .right });
        self.syncActionAccelerator("win.split-down", .{ .new_split = .down });
        self.syncActionAccelerator("win.split-left", .{ .new_split = .left });
        self.syncActionAccelerator("win.split-up", .{ .new_split = .up });
        self.syncActionAccelerator("win.copy", .{ .copy_to_clipboard = .mixed });
        self.syncActionAccelerator("win.paste", .{ .paste_from_clipboard = {} });
        self.syncActionAccelerator("win.reset", .{ .reset = {} });
        self.syncActionAccelerator("win.clear", .{ .clear_screen = {} });
        self.syncActionAccelerator("win.prompt-title", .{ .prompt_surface_title = {} });
        self.syncActionAccelerator("split-tree.new-split::left", .{ .new_split = .left });
        self.syncActionAccelerator("split-tree.new-split::right", .{ .new_split = .right });
        self.syncActionAccelerator("split-tree.new-split::up", .{ .new_split = .up });
        self.syncActionAccelerator("split-tree.new-split::down", .{ .new_split = .down });

        // Register Termplex-specific accelerators.
        self.setupTermplexAccels();
    }

    /// Register hardcoded Termplex keyboard shortcuts.
    ///
    /// These use Ctrl+Shift as the default modifier prefix.  In a future
    /// task the prefix will be made configurable via the Termplex config
    /// file, but for now the bindings are wired directly.
    fn setupTermplexAccels(self: *Self) void {
        const gtk_app = self.as(gtk.Application);

        // Ctrl+Q → quit (ensures the shortcut always works regardless of
        // whether it is also bound via the Termplex keybind system).
        const accels_quit = [_:null]?[*:0]const u8{"<Control>q"};
        gtk_app.setAccelsForAction("app.quit", &accels_quit);

        // Ctrl+Shift+N → new workspace
        const accels_new_ws = [_:null]?[*:0]const u8{"<Control><Shift>n"};
        gtk_app.setAccelsForAction("win.termplex-new-workspace", &accels_new_ws);

        // Ctrl+Shift+W → close workspace (stub, confirmation in Task 23)
        const accels_close = [_:null]?[*:0]const u8{"<Control><Shift>w"};
        gtk_app.setAccelsForAction("win.termplex-close-workspace", &accels_close);

        // Ctrl+Shift+] → next workspace
        const accels_next = [_:null]?[*:0]const u8{"<Control><Shift>bracketright"};
        gtk_app.setAccelsForAction("win.termplex-next-workspace", &accels_next);

        // Ctrl+Shift+[ → previous workspace
        const accels_prev = [_:null]?[*:0]const u8{"<Control><Shift>bracketleft"};
        gtk_app.setAccelsForAction("win.termplex-prev-workspace", &accels_prev);

        // Ctrl+Shift+B → toggle sidebar
        const accels_sidebar = [_:null]?[*:0]const u8{"<Control><Shift>b"};
        gtk_app.setAccelsForAction("win.termplex-toggle-sidebar", &accels_sidebar);
    }

    fn syncActionAccelerator(
        self: *Self,
        gtk_action: [:0]const u8,
        action: input.Binding.Action,
    ) void {
        const gtk_app = self.as(gtk.Application);

        // Reset it initially
        const zero = [_:null]?[*:0]const u8{};
        gtk_app.setAccelsForAction(gtk_action, &zero);

        const config = self.private().config.get();
        const trigger = config.keybind.set.getTrigger(action) orelse return;
        var buf: [1024]u8 = undefined;
        const accel = if (key.accelFromTrigger(
            &buf,
            trigger,
        )) |accel_|
            accel_ orelse return
        else |err| switch (err) {
            // This should really never, never happen. Its not critical enough
            // to actually crash, but this is a bug somewhere. An accelerator
            // for a trigger can't possibly be more than 1024 bytes.
            error.WriteFailed => {
                log.warn("accelerator somehow longer than 1024 bytes: {f}", .{trigger});
                return;
            },
        };
        const accels = [_:null]?[*:0]const u8{accel};

        gtk_app.setAccelsForAction(gtk_action, &accels);
    }

    //---------------------------------------------------------------
    // Properties

    /// Returns the configuration for this application.
    ///
    /// The reference count is increased.
    pub fn getConfig(self: *Self) *Config {
        return self.private().config.ref();
    }

    /// Set the configuration for this application. The reference count
    /// is increased on the new configuration and the old one is
    /// unreferenced.
    ///
    /// If the config has errors this may show the config errors dialog.
    fn setConfig(self: *Self, config: *Config) void {
        const priv = self.private();
        priv.config.unref();
        priv.config = config.ref();
        self.as(gobject.Object).notifyByPspec(properties.config.impl.param_spec);

        // Show our errors if we have any
        self.showConfigErrorsDialog();
    }

    fn propConfig(
        _: *Application,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // Sync our accelerators for menu items.
        self.syncActionAccelerators();

        // Load our runtime and custom CSS. If this fails then our window is
        // just stuck with the old CSS but we don't want to fail the entire
        // config change operation.
        self.loadRuntimeCss() catch |err| switch (err) {
            error.WriteFailed, error.OutOfMemory => log.warn(
                "out of memory loading runtime CSS, no runtime CSS applied",
                .{},
            ),
        };
        self.loadCustomCss() catch |err| {
            log.warn(
                "failed to load custom CSS, no custom CSS applied, err={}",
                .{err},
            );
        };
    }

    /// Log CSS parsing error
    fn signalCssParsingError(
        _: *gtk.CssProvider,
        css_section: *gtk.CssSection,
        err: *glib.Error,
        _: *Self,
    ) callconv(.c) void {
        const location = css_section.toString();
        defer glib.free(location);
        if (comptime gtk_version.atLeast(4, 16, 0)) bytes: {
            const bytes = css_section.getBytes() orelse break :bytes;
            var len: usize = undefined;
            const ptr = bytes.getData(&len) orelse break :bytes;
            const data = ptr[0..len];
            log.warn("css parsing failed at {s}: {s} {d} {s}\n{s}", .{
                location,
                glib.quarkToString(err.f_domain),
                err.f_code,
                err.f_message orelse "«unknown»",
                data,
            });
            return;
        }
        log.warn("css parsing failed at {s}: {s} {d} {s}", .{
            location,
            glib.quarkToString(err.f_domain),
            err.f_code,
            err.f_message orelse "«unknown»",
        });
    }

    //---------------------------------------------------------------
    // Libtermplex Callbacks

    pub fn wakeup(self: *Self) void {
        _ = self;
        glib.MainContext.wakeup(null);
    }

    //---------------------------------------------------------------
    // Virtual Methods

    fn startup(self: *Self) callconv(.c) void {
        log.debug("startup", .{});

        gio.Application.virtual_methods.startup.call(
            Class.parent,
            self.as(Parent),
        );

        // Set ourselves as the default application.
        gio.Application.setDefault(self.as(gio.Application));

        // Setup our event loop
        self.startupXev();

        // Setup our style manager (light/dark mode)
        self.startupStyleManager();

        // Setup some signal handlers
        self.startupSignals();

        // Setup our action map
        self.startupActionMap();

        // Setup our global shortcuts
        self.startupGlobalShortcuts();

        // If we have any config diagnostics from loading, then we
        // show the diagnostics dialog. We show this one as a general
        // modal (not to any specific window) because we don't even
        // know if the window will load.
        self.showConfigErrorsDialog();
    }

    /// Configure libxev to use a specific backend.
    ///
    /// This must be called before any other xev APIs are used.
    fn startupXev(self: *Self) void {
        const priv = self.private();
        const config = priv.config.get();

        // If our backend is auto then we have no setup to do.
        if (config.@"async-backend" == .auto) return;

        // Setup our event loop backend to the preferred method
        const result: bool = switch (config.@"async-backend") {
            .auto => unreachable,
            .epoll => if (comptime xev.dynamic) xev.prefer(.epoll) else false,
            .io_uring => if (comptime xev.dynamic) xev.prefer(.io_uring) else false,
        };

        if (result) {
            log.info(
                "libxev manual backend={s}",
                .{@tagName(xev.backend)},
            );
        } else {
            log.warn(
                "libxev manual backend failed, using default={s}",
                .{@tagName(xev.backend)},
            );
        }
    }

    /// Setup the style manager on startup. The primary task here is to
    /// setup our initial light/dark mode based on the configuration and
    /// setup listeners for changes to the style manager.
    fn startupStyleManager(self: *Self) void {
        const priv = self.private();
        const config = priv.config.get();

        // Setup our initial light/dark
        // Termplex brand is dark-native, so default to dark mode
        // unless the user explicitly requests light.
        const style = self.as(adw.Application).getStyleManager();
        style.setColorScheme(switch (config.@"window-theme") {
            .auto, .termplex, .system => .force_dark,
            .dark => .force_dark,
            .light => .force_light,
        });

        // Setup color change notifications
        _ = gobject.Object.signals.notify.connect(
            style,
            *Self,
            handleStyleManagerDark,
            self,
            .{ .detail = "dark" },
        );

        // Do an initial color scheme sync. This is idempotent and does nothing
        // if our current theme matches what libtermplex has so its safe to
        // call.
        handleStyleManagerDark(style, undefined, self);
    }

    /// Setup signal handlers
    fn startupSignals(self: *Self) void {
        const priv = self.private();
        assert(priv.signal_source == null);
        priv.signal_source = glib.unixSignalAdd(
            std.posix.SIG.USR2,
            handleSigusr2,
            self,
        );
    }

    /// Setup our action map.
    fn startupActionMap(self: *Self) void {
        const t_variant_type = glib.ext.VariantType.newFor(u64);
        defer t_variant_type.free();

        const as_variant_type = glib.VariantType.new("as");
        defer as_variant_type.free();

        const s_variant_type = glib.VariantType.new("s");
        defer s_variant_type.free();

        const actions = [_]ext.actions.Action(Self){
            .init("new-window", actionNewWindow, null),
            .init("new-window-command", actionNewWindow, as_variant_type),
            .init("new-split", actionNewSplit, s_variant_type),
            .init("open-config", actionOpenConfig, null),
            .init("present-surface", actionPresentSurface, t_variant_type),
            .init("quit", actionQuit, null),
            .init("reload-config", actionReloadConfig, null),
        };

        ext.actions.add(Self, self, &actions);
    }

    /// Setup our global shortcuts.
    fn startupGlobalShortcuts(self: *Self) void {
        const priv = self.private();

        // On startup, our dbus connection should be available.
        priv.global_shortcuts.setDbusConnection(
            self.as(gio.Application).getDbusConnection(),
        );

        // Setup a binding so that the shortcut config always matches the app.
        _ = gobject.Object.bindProperty(
            self.as(gobject.Object),
            "config",
            priv.global_shortcuts.as(gobject.Object),
            "config",
            .{ .sync_create = true },
        );

        // Setup the signal handler for global shortcut triggers
        _ = GlobalShortcuts.signals.trigger.connect(
            priv.global_shortcuts,
            *Application,
            globalShortcutTrigger,
            self,
            .{},
        );
    }

    fn activate(self: *Self) callconv(.c) void {
        log.debug("activate", .{});

        // Queue a new window
        const priv = self.private();
        _ = priv.core_app.mailbox.push(.{
            .new_window = .{},
        }, .{ .forever = {} });

        // Call the parent activate method.
        gio.Application.virtual_methods.activate.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.config_errors_dialog.get()) |diag| {
            diag.close();
            diag.unref(); // strong ref from get()
        }
        priv.config_errors_dialog.set(null);
        if (priv.signal_source) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove signal source", .{});
            }
            priv.signal_source = null;
        }

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        self.deinit();
        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Signal Handlers

    /// SIGUSR2 signal handler via g_unix_signal_add
    fn handleSigusr2(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse
            return @intFromBool(glib.SOURCE_CONTINUE)));

        log.info("received SIGUSR2, reloading configuration", .{});
        Action.reloadConfig(
            self,
            .app,
            .{},
        ) catch |err| {
            // If we fail to reload the configuration, then we want the
            // user to know it. For now we log but we should show another
            // GUI.
            log.warn("error reloading config: {}", .{err});
        };

        return @intFromBool(glib.SOURCE_CONTINUE);
    }

    fn handleCloseConfirmation(
        _: *CloseConfirmationDialog,
        self: *Self,
    ) callconv(.c) void {
        self.quitNow();
    }

    fn handleQuitTimerExpired(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud));
        const priv = self.private();
        priv.quit_timer = .expired;
        return 0;
    }

    fn handleStyleManagerDark(
        style: *adw.StyleManager,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const scheme: apprt.ColorScheme = if (style.getDark() == 0)
            .light
        else
            .dark;
        log.debug("style manager changed scheme={}", .{scheme});

        const priv: *Private = self.private();
        const core_app = priv.core_app;
        core_app.colorSchemeEvent(self.rt(), scheme) catch |err| {
            log.warn("error updating app color scheme err={}", .{err});
        };
        for (core_app.surfaces.items) |surface| {
            surface.core().colorSchemeCallback(scheme) catch |err| {
                log.warn(
                    "unable to tell surface about color scheme change err={}",
                    .{err},
                );
            };
        }

        if (gtk_version.atLeast(4, 20, 0)) {
            const gtk_scheme: gtk.InterfaceColorScheme = switch (scheme) {
                .light => gtk.InterfaceColorScheme.light,
                .dark => gtk.InterfaceColorScheme.dark,
            };
            var value = gobject.ext.Value.newFrom(gtk_scheme);
            gobject.Object.setProperty(
                priv.css_provider.as(gobject.Object),
                "prefers-color-scheme",
                &value,
            );
            for (priv.custom_css_providers.items) |css_provider| {
                gobject.Object.setProperty(
                    css_provider.as(gobject.Object),
                    "prefers-color-scheme",
                    &value,
                );
            }
        }
    }

    fn handleReloadConfig(
        _: *ConfigErrorsDialog,
        self: *Self,
    ) callconv(.c) void {
        // We clear our dialog reference because its going to close
        // after response handling and we don't want to reuse it.
        const priv = self.private();
        priv.config_errors_dialog.set(null);

        // Reload our config as if the app reloaded.
        Action.reloadConfig(
            self,
            .app,
            .{},
        ) catch |err| {
            // If we fail to reload the configuration, then we want the
            // user to know it. For now we log but we should show another
            // GUI.
            log.warn("error reloading config: {}", .{err});
        };
    }

    /// Show the config errors dialog if the config on our application
    /// has diagnostics.
    fn showConfigErrorsDialog(self: *Self) void {
        const priv = self.private();

        // If we already have a dialog, just update the config.
        if (priv.config_errors_dialog.get()) |diag| {
            defer diag.unref(); // get gets a strong ref

            var value = gobject.ext.Value.newFrom(priv.config);
            defer value.unset();
            gobject.Object.setProperty(
                diag.as(gobject.Object),
                "config",
                &value,
            );

            if (!priv.config.hasDiagnostics()) {
                diag.close();
            } else {
                diag.present(null);
            }

            return;
        }

        // No diagnostics, do nothing.
        if (!priv.config.hasDiagnostics()) return;

        // No dialog yet, initialize a new one. There's no need to unref
        // here because the widget that it becomes a part of takes ownership.
        const dialog: *ConfigErrorsDialog = .new(priv.config);
        priv.config_errors_dialog.set(dialog);

        // Connect to the reload signal so we know to reload our config.
        _ = ConfigErrorsDialog.signals.@"reload-config".connect(
            dialog,
            *Application,
            handleReloadConfig,
            self,
            .{},
        );

        // Show it
        dialog.present(null);
    }

    fn globalShortcutTrigger(
        _: *GlobalShortcuts,
        action: *const Binding.Action,
        self: *Self,
    ) callconv(.c) void {
        self.core().performAllAction(self.rt(), action.*) catch |err| {
            log.warn("failed to perform action={}", .{err});
        };
    }

    fn actionReloadConfig(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.core_app.performAction(self.rt(), .reload_config) catch |err| {
            log.warn("error reloading config err={}", .{err});
        };
    }

    fn actionQuit(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.core_app.performAction(self.rt(), .quit) catch |err| {
            log.warn("error quitting err={}", .{err});
        };
    }

    /// Handle `app.new-window` and `app.new-window-command` GTK actions
    pub fn actionNewWindow(
        _: *gio.SimpleAction,
        parameter_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        log.debug("received new window action", .{});

        var arena: std.heap.ArenaAllocator = .init(Application.default().allocator());
        defer arena.deinit();

        const alloc = arena.allocator();

        var working_directory: ?[:0]const u8 = null;
        var title: ?[:0]const u8 = null;
        var command: ?configpkg.Command = null;
        var args: std.ArrayList([:0]const u8) = .empty;

        overrides: {
            // were we given a parameter?
            const parameter = parameter_ orelse break :overrides;

            const as_variant_type = glib.VariantType.new("as");
            defer as_variant_type.free();

            // ensure that the supplied parameter is an array of strings
            if (glib.Variant.isOfType(parameter, as_variant_type) == 0) {
                log.warn("parameter is of type '{s}', not '{s}'", .{
                    parameter.getTypeString(),
                    as_variant_type.peekString()[0..as_variant_type.getStringLength()],
                });
                break :overrides;
            }

            const s_variant_type = glib.VariantType.new("s");
            defer s_variant_type.free();

            var it: glib.VariantIter = undefined;
            _ = it.init(parameter);

            var e_seen: bool = false;
            var i: usize = 0;

            while (it.nextValue()) |value| : (i += 1) {
                defer value.unref();

                // just to be sure
                if (value.isOfType(s_variant_type) == 0) continue;

                var len: usize = undefined;
                const buf = value.getString(&len);
                const str = buf[0..len];

                log.debug("new-window argument: {d} {s}", .{ i, str });

                if (e_seen) {
                    const cpy = alloc.dupeZ(u8, str) catch |err| {
                        log.warn("unable to duplicate argument {d} {s}: {t}", .{ i, str, err });
                        break :overrides;
                    };
                    args.append(alloc, cpy) catch |err| {
                        log.warn("unable to append argument {d} {s}: {t}", .{ i, str, err });
                        break :overrides;
                    };
                    continue;
                }

                if (std.mem.eql(u8, str, "-e")) {
                    e_seen = true;
                    continue;
                }

                if (lib.cutPrefix(u8, str, "--command=")) |v| {
                    var cmd: configpkg.Command = undefined;
                    cmd.parseCLI(alloc, v) catch |err| {
                        log.warn("unable to parse command: {t}", .{err});
                        continue;
                    };
                    command = cmd;
                    continue;
                }
                if (lib.cutPrefix(u8, str, "--working-directory=")) |v| {
                    working_directory = alloc.dupeZ(u8, std.mem.trim(u8, v, &std.ascii.whitespace)) catch |err| wd: {
                        log.warn("unable to duplicate working directory: {t}", .{err});
                        break :wd null;
                    };
                    continue;
                }
                if (lib.cutPrefix(u8, str, "--title=")) |v| {
                    title = alloc.dupeZ(u8, std.mem.trim(u8, v, &std.ascii.whitespace)) catch |err| t: {
                        log.warn("unable to duplicate title: {t}", .{err});
                        break :t null;
                    };
                    continue;
                }
            }
        }

        if (args.items.len > 0) {
            command = .{
                .direct = args.items,
            };
        }

        Action.newWindow(self, null, .{
            .command = command,
            .working_directory = working_directory,
            .title = title,
        }) catch |err| {
            log.warn("unable to create new window: {t}", .{err});
        };
    }

    /// Handle `app.new-split` GTK action — creates a split in the active
    /// window's focused surface. The parameter is a direction string:
    /// "right", "left", "up", "down" (or aliases "horizontal"→"right",
    /// "vertical"→"down").
    pub fn actionNewSplit(
        _: *gio.SimpleAction,
        parameter_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        log.debug("received new split action", .{});

        const direction: []const u8 = blk: {
            const parameter = parameter_ orelse break :blk "right";
            var len: usize = undefined;
            const buf = parameter.getString(&len);
            const dir = buf[0..len];
            if (std.mem.eql(u8, dir, "horizontal")) break :blk "right";
            if (std.mem.eql(u8, dir, "vertical")) break :blk "down";
            if (std.mem.eql(u8, dir, "right") or
                std.mem.eql(u8, dir, "left") or
                std.mem.eql(u8, dir, "up") or
                std.mem.eql(u8, dir, "down"))
            {
                break :blk dir;
            }
            log.warn("invalid split direction: {s}, defaulting to right", .{dir});
            break :blk "right";
        };

        const active_win = self.as(gtk.Application).getActiveWindow() orelse {
            log.warn("new-split: no active window", .{});
            return;
        };
        const win = gobject.ext.cast(Window, active_win) orelse {
            log.warn("new-split: active window is not a termplex window", .{});
            return;
        };
        const surface = win.getActiveSurface() orelse {
            log.warn("new-split: no active surface", .{});
            return;
        };

        _ = surface.as(gtk.Widget).activateAction(
            "split-tree.new-split",
            "&s",
            direction.ptr,
        );
    }

    pub fn actionOpenConfig(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        _ = self.core().mailbox.push(.open_config, .forever);
    }

    fn actionPresentSurface(
        _: *gio.SimpleAction,
        parameter_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const parameter = parameter_ orelse return;

        const t = glib.ext.VariantType.newFor(u64);
        defer glib.VariantType.free(t);

        // Make sure that we've receiived a u64 from the system.
        if (glib.Variant.isOfType(parameter, t) == 0) {
            return;
        }

        // Convert that u64 to pointer to a core surface. A value of zero
        // means that there was no target surface for the notification so
        // we don't focus any surface.
        //
        // This is admittedly SUPER SUS and we should instead do what we
        // do on macOS which is generate a UUID per surface and then pass
        // that around. But, we do validate the pointer below so at worst
        // this may result in focusing the wrong surface if the pointer was
        // reused for a surface.
        const ptr_int = parameter.getUint64();
        if (ptr_int == 0) return;
        const surface: *CoreSurface = @ptrFromInt(ptr_int);

        // Send a message through the core app mailbox rather than presenting the
        // surface directly so that it can validate that the surface pointer is
        // valid. We could get an invalid pointer if a desktop notification outlives
        // a Termplex instance and a new one starts up, or there are multiple Termplex
        // instances running.
        _ = self.core().mailbox.push(
            .{
                .surface_message = .{
                    .surface = surface,
                    .message = .present_surface,
                },
            },
            .forever,
        );
    }

    //----------------------------------------------------------------
    // Boilerplate/Noise

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
            // Register our compiled resources exactly once.
            {
                const c = @cImport({
                    // generated header files
                    @cInclude("termplex_resources.h");
                });
                if (c.termplex_get_resource()) |ptr| {
                    gio.resourcesRegister(@ptrCast(@alignCast(ptr)));
                } else {
                    // If we fail to load resources then things will
                    // probably look really bad but it shouldn't stop our
                    // app from loading.
                    log.warn("unable to load resources", .{});
                }
            }

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.config.impl,
            });

            // Virtual methods
            gio.Application.virtual_methods.activate.implement(class, &activate);
            gio.Application.virtual_methods.startup.implement(class, &startup);
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
    };
};

/// All apprt action handlers
const Action = struct {
    pub fn closeTab(target: apprt.Target, value: apprt.Action.Value(.close_tab)) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                return surface.as(gtk.Widget).activateAction(
                    "tab.close",
                    glib.ext.VariantType.stringFor([:0]const u8),
                    @as([*:0]const u8, @tagName(value)),
                ) != 0;
            },
        }
    }

    pub fn closeWindow(target: apprt.Target) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                return surface.as(gtk.Widget).activateAction("win.close", null) != 0;
            },
        }
    }

    pub fn copyTitleToClipboard(target: apprt.Target) bool {
        return switch (target) {
            .app => false,
            .surface => |v| v.rt_surface.gobj().copyTitleToClipboard(),
        };
    }

    pub fn configChange(
        self: *Application,
        target: apprt.Target,
        new_config: *const CoreConfig,
    ) !void {
        // Wrap our config in a GObject. This will clone it.
        const alloc = self.allocator();
        const config_obj: *Config = try .new(alloc, new_config);
        defer config_obj.unref();

        switch (target) {
            .surface => |core| core.rt_surface.surface.setConfig(config_obj),
            .app => self.setConfig(config_obj),
        }
    }

    pub fn desktopNotification(
        self: *Application,
        target: apprt.Target,
        n: apprt.action.DesktopNotification,
    ) void {
        switch (target) {
            .app => {},
            .surface => |v| {
                v.rt_surface.gobj().sendDesktopNotification(n.title, n.body);

                // Termplex: mark surface with attention class for visual ring
                v.rt_surface.gobj().as(gtk.Widget).addCssClass("termplex-attention");

                _ = self.recordWorkspaceNotification(
                    self.activeWorkspaceIndex(),
                    n.title,
                    n.body,
                    .osc,
                );

                return;
            },
        }

        // Set a default title if we don't already have one
        const t = switch (n.title.len) {
            0 => "Termplex",
            else => n.title,
        };

        const notification = gio.Notification.new(t);
        defer notification.unref();
        notification.setBody(n.body);

        const icon = gio.ThemedIcon.new("com.termplex.app");
        defer icon.unref();
        notification.setIcon(icon.as(gio.Icon));
        notification.setDefaultActionAndTargetValue(
            "app.present-surface",
            glib.Variant.newUint64(0),
        );

        // We set the notification ID to the body content. If the content is the
        // same, this notification may replace a previous notification
        const gio_app = self.as(gio.Application);
        gio_app.sendNotification(n.body, notification);
        _ = self.recordWorkspaceNotification(
            self.activeWorkspaceIndex(),
            n.title,
            n.body,
            .osc,
        );
    }

    pub fn equalizeSplits(target: apprt.Target) bool {
        switch (target) {
            .app => {
                log.warn("equalize splits to app is unexpected", .{});
                return false;
            },

            .surface => |core| {
                const surface = core.rt_surface.surface;
                return surface.as(gtk.Widget).activateAction("split-tree.equalize", null) != 0;
            },
        }
    }

    pub fn gotoSplit(
        target: apprt.Target,
        to: apprt.action.GotoSplit,
    ) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                // Design note: we can't use widget actions here because
                // we need to know whether there is a goto target for returning
                // the proper perform result (boolean).

                const surface = core.rt_surface.surface;
                const tree = ext.getAncestor(
                    SplitTree,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a split tree, ignoring goto_split", .{});
                    return false;
                };

                return tree.goto(switch (to) {
                    .previous => .previous_wrapped,
                    .next => .next_wrapped,
                    .up => .{ .spatial = .up },
                    .down => .{ .spatial = .down },
                    .left => .{ .spatial = .left },
                    .right => .{ .spatial = .right },
                });
            },
        }
    }

    pub fn gotoTab(
        target: apprt.Target,
        tab: apprt.action.GotoTab,
    ) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const window = ext.getAncestor(
                    Window,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a window, ignoring new_tab", .{});
                    return false;
                };

                return window.selectTab(switch (tab) {
                    .previous => .previous,
                    .next => .next,
                    .last => .last,
                    else => .{ .n = @intCast(@intFromEnum(tab)) },
                });
            },
        }
    }

    pub fn gotoWindow(direction: apprt.action.GotoWindow) bool {
        const glist = gtk.Window.listToplevels();
        defer glist.free();

        // The window we're starting from is typically our active window.
        const starting: *glib.List = @as(?*glib.List, glist.findCustom(
            null,
            findActiveWindow,
        )) orelse glist;

        // Go forward or backwards in the list until we find a valid
        // window that is visible.
        var current_: ?*glib.List = starting;
        while (current_) |node| : (current_ = switch (direction) {
            .next => node.f_next,
            .previous => node.f_prev,
        }) {
            const data = node.f_data orelse continue;
            const gtk_window: *gtk.Window = @ptrCast(@alignCast(data));
            if (gotoWindowMaybe(gtk_window)) return true;
        }

        // If we reached here, we didn't find a valid window to focus.
        // Wrap around.
        current_ = switch (direction) {
            .next => glist,
            .previous => last: {
                var end: *glib.List = glist;
                while (end.f_next) |next| end = next;
                break :last end;
            },
        };
        while (current_) |node| : (current_ = switch (direction) {
            .next => node.f_next,
            .previous => node.f_prev,
        }) {
            if (current_ == starting) break;
            const data = node.f_data orelse continue;
            const gtk_window: *gtk.Window = @ptrCast(@alignCast(data));
            if (gotoWindowMaybe(gtk_window)) return true;
        }

        return false;
    }

    fn gotoWindowMaybe(gtk_window: *gtk.Window) bool {
        // If it is already active skip it.
        if (gtk_window.isActive() != 0) return false;
        // If it is hidden, skip it.
        if (gtk_window.as(gtk.Widget).isVisible() == 0) return false;
        // If it isn't a Termplex window, skip it.
        const window = gobject.ext.cast(
            Window,
            gtk_window,
        ) orelse return false;

        // Focus our active surface
        const surface = window.getActiveSurface() orelse return false;
        gtk.Window.present(gtk_window);
        surface.grabFocus();
        return true;
    }

    pub fn initialSize(
        target: apprt.Target,
        value: apprt.action.InitialSize,
    ) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                surface.setDefaultSize(.{
                    .width = value.width,
                    .height = value.height,
                });
                return true;
            },
        }
    }

    pub fn mouseOverLink(
        target: apprt.Target,
        value: apprt.action.MouseOverLink,
    ) void {
        switch (target) {
            .app => log.warn("mouse over link to app is unexpected", .{}),
            .surface => |surface| surface.rt_surface.gobj().setMouseHoverUrl(
                if (value.url.len > 0) value.url else null,
            ),
        }
    }

    pub fn mouseShape(
        target: apprt.Target,
        shape: terminal.MouseShape,
    ) void {
        switch (target) {
            .app => log.warn("mouse shape to app is unexpected", .{}),
            .surface => |surface| surface.rt_surface.gobj().setMouseShape(shape),
        }
    }

    pub fn mouseVisibility(
        target: apprt.Target,
        visibility: apprt.action.MouseVisibility,
    ) void {
        switch (target) {
            .app => log.warn("mouse visibility to app is unexpected", .{}),
            .surface => |surface| surface.rt_surface.gobj().setMouseHidden(switch (visibility) {
                .visible => false,
                .hidden => true,
            }),
        }
    }

    pub fn moveTab(
        target: apprt.Target,
        value: apprt.action.MoveTab,
    ) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const window = ext.getAncestor(
                    Window,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a window, ignoring new_tab", .{});
                    return false;
                };

                return window.moveTab(
                    surface,
                    @intCast(value.amount),
                );
            },
        }
    }

    pub fn newSplit(
        target: apprt.Target,
        direction: apprt.action.SplitDirection,
    ) bool {
        switch (target) {
            .app => {
                log.warn("new split to app is unexpected", .{});
                return false;
            },

            .surface => |core| {
                const surface = core.rt_surface.surface;

                return surface.as(gtk.Widget).activateAction(
                    "split-tree.new-split",
                    "&s",
                    @tagName(direction).ptr,
                ) != 0;
            },
        }
    }

    pub fn newTab(target: apprt.Target) bool {
        switch (target) {
            .app => {
                log.warn("new tab to app is unexpected", .{});
                return false;
            },

            .surface => |core| {
                // Get the window ancestor of the surface. Surfaces shouldn't
                // be aware they might be in windows but at the app level we
                // can do this.
                const surface = core.rt_surface.surface;
                const window = ext.getAncestor(
                    Window,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a window, ignoring new_tab", .{});
                    return false;
                };
                window.newTab(core);
                return true;
            },
        }
    }

    pub fn newWindow(
        self: *Application,
        parent: ?*CoreSurface,
        overrides: struct {
            command: ?configpkg.Command = null,
            working_directory: ?[:0]const u8 = null,
            title: ?[:0]const u8 = null,

            pub const none: @This() = .{};
        },
    ) !void {
        // Note that we've requested a window at least once. This is used
        // to trigger quit on no windows. Note I'm not sure if this is REALLY
        // necessary, but I don't want to risk a bug where on a slow machine
        // or something we quit immediately after starting up because there
        // was a delay in the event loop before we created a Window.
        self.private().requested_window = true;

        const win = Window.new(self, .{
            .title = overrides.title,
        });
        initAndShowWindow(
            self,
            win,
            parent,
            .{
                .command = overrides.command,
                .working_directory = overrides.working_directory,
                .title = overrides.title,
            },
        );
    }

    fn initAndShowWindow(
        self: *Application,
        win: *Window,
        parent: ?*CoreSurface,
        overrides: struct {
            command: ?configpkg.Command = null,
            working_directory: ?[:0]const u8 = null,
            title: ?[:0]const u8 = null,

            pub const none: @This() = .{};
        },
    ) void {
        // Setup a binding so that whenever our config changes so does the
        // window. There's never a time when the window config should be out
        // of sync with the application config.
        _ = gobject.Object.bindProperty(
            self.as(gobject.Object),
            "config",
            win.as(gobject.Object),
            "config",
            .{},
        );

        // Phase 2 session restore: if full tab snapshots are pending, rebuild
        // tabs and split trees for all workspaces before showing the window.
        if (self.getRestoreTabSnapshots()) |tab_snapshots| {
            const active_tab_indices = self.getRestoreActiveTabIndices();
            for (tab_snapshots, 0..) |snapshots, ws_idx| {
                const ws_index: u32 = @intCast(ws_idx);
                const ws_dir = self.workspaceDir(ws_index);
                const saved_active_tab_idx: u32 = if (active_tab_indices) |indices|
                    (if (ws_idx < indices.len) indices[ws_idx] else 0)
                else
                    0;

                if (self.workspaceTabView(ws_index)) |tv| {
                    if (snapshots.len == 0) {
                        win.createTabInView(tv, ws_dir);
                    } else {
                        for (snapshots) |*snapshot| {
                            win.createRestoredTabInView(tv, ws_index, snapshot, ws_dir);
                        }
                    }

                    if (saved_active_tab_idx < @as(u32, @intCast(tv.getNPages()))) {
                        const selected_page = tv.getNthPage(@intCast(saved_active_tab_idx));
                        tv.setSelectedPage(selected_page);
                    }
                }
            }
            self.clearRestoreTabSnapshots();
            self.clearRestoreActiveTabIndices();
            self.clearRestoreTabCounts();
            self.clearRestoreTabTitles();
            self.clearRestoreTabDirs();
        } else if (self.getRestoreTabCounts()) |tab_counts| {
            // Legacy restore path for v1-v4 session files.
            const tab_titles = self.getRestoreTabTitles();
            const tab_dirs = self.getRestoreTabDirs();
            const active_tab_indices = self.getRestoreActiveTabIndices();
            const active_ws = self.activeWorkspaceIndex();
            for (tab_counts, 0..) |count, ws_idx| {
                const ws_index: u32 = @intCast(ws_idx);
                const ws_dir = self.workspaceDir(ws_index);
                const n: u32 = if (count > 0) count else 1;
                const titles: []const [:0]const u8 = if (tab_titles) |t|
                    (if (ws_idx < t.len) t[ws_idx] else &[_][:0]const u8{})
                else
                    &[_][:0]const u8{};
                const dirs: []const [:0]const u8 = if (tab_dirs) |d|
                    (if (ws_idx < d.len) d[ws_idx] else &[_][:0]const u8{})
                else
                    &[_][:0]const u8{};
                const saved_active_tab_idx: u32 = if (active_tab_indices) |indices|
                    (if (ws_idx < indices.len) indices[ws_idx] else 0)
                else
                    0;
                if (ws_idx == active_ws) {
                    // Active workspace: create tabs via the window's newTab path.
                    var i: u32 = 0;
                    while (i < n) : (i += 1) {
                        const title: ?[:0]const u8 = if (i < titles.len) titles[i] else null;
                        const tab_dir: ?[:0]const u8 = if (i < dirs.len) dirs[i] else ws_dir;
                        win.newTabForWindow(null, .{
                            .working_directory = tab_dir,
                            .title = title,
                        });
                    }
                    if (self.workspaceTabView(ws_index)) |tv| {
                        if (saved_active_tab_idx < @as(u32, @intCast(tv.getNPages()))) {
                            const selected_page = tv.getNthPage(@intCast(saved_active_tab_idx));
                            tv.setSelectedPage(selected_page);
                        }
                    }
                } else {
                    // Background workspace: create tabs directly in that TabView.
                    if (self.workspaceTabView(ws_index)) |tv| {
                        var i: u32 = 0;
                        while (i < n) : (i += 1) {
                            const tab_dir: ?[:0]const u8 = if (i < dirs.len) dirs[i] else ws_dir;
                            win.createTabInView(tv, tab_dir);
                        }
                        // Apply saved titles to the pages in this TabView.
                        var j: c_int = 0;
                        while (j < tv.getNPages()) : (j += 1) {
                            const idx: usize = @intCast(j);
                            if (idx < titles.len) {
                                tv.getNthPage(j).setTitle(titles[idx]);
                            }
                        }
                        if (saved_active_tab_idx < @as(u32, @intCast(tv.getNPages()))) {
                            const selected_page = tv.getNthPage(@intCast(saved_active_tab_idx));
                            tv.setSelectedPage(selected_page);
                        }
                    }
                }
            }
            self.clearRestoreTabCounts();
            self.clearRestoreTabTitles();
            self.clearRestoreActiveTabIndices();
            self.clearRestoreTabDirs();
        } else {
            // Normal startup: create a single initial tab.
            win.newTabForWindow(parent, .{
                .command = overrides.command,
                .working_directory = overrides.working_directory,
                .title = overrides.title,
            });
        }

        // Prefer restored window geometry when available; otherwise estimate
        // an initial size before presenting so the window manager can place it.
        const priv = self.private();
        if (priv.restore_window_width) |width| {
            if (priv.restore_window_height) |height| {
                win.as(gtk.Window).setDefaultSize(width, height);
            }
        } else if (win.getActiveSurface()) |surface| {
            surface.estimateInitialSize();
            if (surface.getDefaultSize()) |size| {
                win.as(gtk.Window).setDefaultSize(
                    @intCast(size.width),
                    @intCast(size.height),
                );
            }
        }

        // Show the window
        gtk.Window.present(win.as(gtk.Window));
        self.refreshUpdateBars();

        // Termplex: show first-run orchestration dialog if not yet configured.
        showOrchestrationDialog(self);
    }

    // -----------------------------------------------------------------
    // Termplex orchestration first-run dialog
    // -----------------------------------------------------------------

    /// Show the first-run orchestration dialog if orchestration.enabled is null.
    fn showOrchestrationDialog(self: *Application) void {
        const priv = self.private();

        // Only show if enabled is null (never configured).
        if (priv.termplex_cfg.orchestration.enabled != null) return;

        // Require an active window to parent the dialog.
        const active_win = self.as(gtk.Application).getActiveWindow() orelse return;

        const dialog = adw.AlertDialog.new(
            "Enable Orchestration?",
            "Termplex can run an AI agent that manages your workspaces, tabs, and terminal sessions. Enable orchestration to get started, or skip to set this up later.",
        );

        dialog.addResponse("skip", "Skip");
        dialog.addResponse("enable", "Enable");
        dialog.setResponseAppearance("enable", .suggested);
        dialog.setDefaultResponse("enable");

        dialog.choose(
            active_win.as(gtk.Widget),
            null,
            orchestrationDialogReady,
            self,
        );
    }

    fn orchestrationDialogReady(
        source: ?*gobject.Object,
        result: *gio.AsyncResult,
        ud: ?*anyopaque,
    ) callconv(.c) void {
        const dialog: *adw.AlertDialog = @ptrCast(@alignCast(source orelse return));
        const self: *Application = @ptrCast(@alignCast(ud orelse return));

        const response = dialog.chooseFinish(result);
        if (std.mem.orderZ(u8, response, "enable") == .eq) {
            enableOrchestration(self);
        } else {
            disableOrchestration(self);
        }
    }

    fn enableOrchestration(self: *Application) void {
        const alloc = std.heap.c_allocator;

        // 1. Create orchestration directory structure (recursive).
        const home = std.posix.getenv("HOME") orelse return;
        const orch_path = std.fmt.allocPrint(alloc, "{s}/.termplex/orchestration", .{home}) catch return;
        defer alloc.free(orch_path);

        // Create parent + subdirectories.
        const dirs = [_][]const u8{ "skill", "logs", "state" };
        for (dirs) |subdir| {
            const full = std.fmt.allocPrint(alloc, "{s}/{s}", .{ orch_path, subdir }) catch continue;
            defer alloc.free(full);
            std.fs.cwd().makePath(full) catch continue;
        }

        // 2. Copy skill files to orchestration directory.
        copyResourceFile("share/termplex/skill/termplex.md", orch_path, "skill/termplex.md");
        copyResourceFile("share/termplex/skill/AGENTS.md", orch_path, "AGENTS.md");

        // 3. Write orchestration.enabled = true to config.toml.
        writeOrchestrationConfig(true, orch_path, "claude");

        // Update in-memory config so the dialog guard doesn't re-fire.
        const priv = self.private();
        priv.termplex_cfg.orchestration.enabled = true;

        // 4. Create the orchestration workspace.
        const orch_dir_z = alloc.dupeZ(u8, orch_path) catch return;
        defer alloc.free(orch_dir_z);
        const orch_idx = self.addWorkspaceWithDir(orch_dir_z);
        if (orch_idx) |idx| {
            self.renameWorkspace(idx, "Orchestrator");
            priv.orchestration_workspace_idx = idx;
            log.info("orchestration enabled: workspace created at index {d}", .{idx});

            self.refreshAllWorkspaceSidebars();
            self.syncActiveWorkspaceHeaders();
        }
    }

    fn disableOrchestration(self: *Application) void {
        writeOrchestrationConfig(false, null, null);
        // Update in-memory config so the dialog guard doesn't re-fire.
        self.private().termplex_cfg.orchestration.enabled = false;
        log.info("orchestration disabled by user", .{});
    }

    fn writeOrchestrationConfig(enabled: bool, dir: ?[]const u8, agent_command: ?[]const u8) void {
        const alloc = std.heap.c_allocator;

        // Resolve config base dir: $XDG_CONFIG_HOME takes priority over $HOME/.config.
        // Always allocate so ownership is uniform and we can always free.
        const config_base: []u8 = blk: {
            if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg| {
                if (xdg.len > 0) break :blk alloc.dupe(u8, xdg) catch return;
            }
            const home = std.posix.getenv("HOME") orelse return;
            break :blk std.fmt.allocPrint(alloc, "{s}/.config", .{home}) catch return;
        };
        defer alloc.free(config_base);

        const config_path = std.fmt.allocPrint(alloc, "{s}/termplex/config.toml", .{config_base}) catch return;
        defer alloc.free(config_path);

        // Read existing config.
        var existing: []u8 = &.{};
        const existing_owned = blk: {
            const file = std.fs.openFileAbsolute(config_path, .{}) catch break :blk false;
            defer file.close();
            existing = file.readToEndAlloc(alloc, 1024 * 1024) catch break :blk false;
            break :blk true;
        };
        defer if (existing_owned) alloc.free(existing);

        // Strip any existing [orchestration] section to avoid duplicates.
        var cleaned: std.ArrayListUnmanaged(u8) = .empty;
        defer cleaned.deinit(alloc);
        var in_orch_section = false;
        var line_iter = std.mem.splitScalar(u8, existing, '\n');
        while (line_iter.next()) |line| {
            if (line.len > 0 and line[0] == '[') {
                in_orch_section = std.mem.startsWith(u8, line, "[orchestration]");
            }
            if (!in_orch_section) {
                cleaned.appendSlice(alloc, line) catch continue;
                cleaned.append(alloc, '\n') catch continue;
            }
        }

        // Build the new orchestration section.
        var buf: [512]u8 = undefined;
        const section = if (enabled)
            std.fmt.bufPrint(&buf, "\n[orchestration]\nenabled = true\ndir = \"{s}\"\nagent_command = \"{s}\"\nagent_terminate_policy = \"keep\"\n", .{
                dir orelse "~/.termplex/orchestration",
                agent_command orelse "claude",
            }) catch return
        else
            std.fmt.bufPrint(&buf, "\n[orchestration]\nenabled = false\n", .{}) catch return;

        cleaned.appendSlice(alloc, section) catch return;

        // Ensure config directory exists.
        const config_dir = std.fmt.allocPrint(alloc, "{s}/termplex", .{config_base}) catch return;
        defer alloc.free(config_dir);
        std.fs.cwd().makePath(config_dir) catch {};

        const file = std.fs.createFileAbsolute(config_path, .{}) catch return;
        defer file.close();
        file.writeAll(cleaned.items) catch {};
        log.info("wrote orchestration config (enabled={}) to {s}", .{ enabled, config_path });
    }

    /// Copy a resource file from the install prefix to the orchestration directory.
    fn copyResourceFile(relative_src: []const u8, orch_dir: []const u8, relative_dst: []const u8) void {
        const alloc = std.heap.c_allocator;
        const dst = std.fmt.allocPrint(alloc, "{s}/{s}", .{ orch_dir, relative_dst }) catch return;
        defer alloc.free(dst);

        // Try relative to the executable first (covers local zig-out builds),
        // then fall back to common system install prefixes.
        const exe_prefix: ?[]const u8 = blk: {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const exe_path = std.fs.selfExePath(&buf) catch break :blk null;
            // exe_path is e.g. ".../zig-out/bin/termplex-app" — go up two dirs to get prefix.
            const bin_dir = std.fs.path.dirname(exe_path) orelse break :blk null;
            const prefix_dir = std.fs.path.dirname(bin_dir) orelse break :blk null;
            break :blk prefix_dir;
        };

        // Build list of prefixes to try.
        const static_prefixes = [_][]const u8{ "/usr/local", "/usr" };
        const total = if (exe_prefix != null) static_prefixes.len + 1 else static_prefixes.len;

        for (0..total) |i| {
            const prefix: []const u8 = if (i == 0 and exe_prefix != null)
                exe_prefix.?
            else
                static_prefixes[i - @as(usize, if (exe_prefix != null) 1 else 0)];

            const src = std.fmt.allocPrint(alloc, "{s}/{s}", .{ prefix, relative_src }) catch continue;
            defer alloc.free(src);
            std.fs.copyFileAbsolute(src, dst, .{}) catch continue;
            log.debug("copied resource {s} -> {s}", .{ src, dst });
            return; // Success.
        }
        log.warn("resource file not found: {s} (tried exe prefix and system prefixes)", .{relative_src});
    }

    pub fn openConfig(self: *Application) bool {
        // Get the config file path
        const alloc = self.allocator();
        const path = configpkg.edit.openPath(alloc) catch |err| {
            log.warn("error getting config file path: {}", .{err});
            return false;
        };
        defer alloc.free(path);

        // Open it using openURL. "path" isn't actually a URL but
        // at the time of writing that works just fine for GTK.
        openUrl(self, .{ .kind = .text, .url = path });
        return true;
    }

    pub fn openUrl(
        self: *Application,
        value: apprt.action.OpenUrl,
    ) void {
        // TODO: use https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.OpenURI.html

        // Fallback to the minimal cross-platform way of opening a URL.
        // This is always a safe fallback and enables for example Windows
        // to open URLs (GTK on Windows via WSL is a thing).
        internal_os.open(
            self.allocator(),
            value.kind,
            value.url,
        ) catch |err| log.warn("unable to open url: {}", .{err});
    }

    pub fn pwd(
        target: apprt.Target,
        value: apprt.action.Pwd,
    ) void {
        switch (target) {
            .app => log.warn("pwd to app is unexpected", .{}),
            .surface => |surface| surface.rt_surface.gobj().setPwd(value.pwd),
        }
    }

    pub fn quitTimer(
        self: *Application,
        mode: apprt.action.QuitTimer,
    ) !void {
        switch (mode) {
            .start => self.startQuitTimer(),
            .stop => self.stopQuitTimer(),
        }
    }

    pub fn presentTerminal(
        target: apprt.Target,
    ) bool {
        return switch (target) {
            .app => false,
            .surface => |v| surface: {
                v.rt_surface.surface.present();
                break :surface true;
            },
        };
    }

    pub fn progressReport(
        target: apprt.Target,
        value: terminal.osc.Command.ProgressReport,
    ) bool {
        return switch (target) {
            .app => false,
            .surface => |v| surface: {
                v.rt_surface.surface.setProgressReport(value);
                break :surface true;
            },
        };
    }

    pub fn promptTitle(target: apprt.Target, value: apprt.action.PromptTitle) bool {
        switch (value) {
            .surface => switch (target) {
                .app => return false,
                .surface => |v| {
                    v.rt_surface.surface.promptTitle();
                    return true;
                },
            },
            .tab => {
                switch (target) {
                    .app => return false,
                    .surface => |v| {
                        const surface = v.rt_surface.surface;
                        const tab = ext.getAncestor(
                            Tab,
                            surface.as(gtk.Widget),
                        ) orelse {
                            log.warn("surface is not in a tab, ignoring prompt_tab_title", .{});
                            return false;
                        };
                        tab.promptTabTitle();
                        return true;
                    },
                }
            },
        }
    }

    /// Reload the configuration for the application and propagate it
    /// across the entire application and all terminals.
    pub fn reloadConfig(
        self: *Application,
        target: apprt.Target,
        opts: apprt.action.ReloadConfig,
    ) !void {
        // Tell systemd that reloading has started.
        systemd.notify.reloading();

        // When we exit this function tell systemd that reloading has finished.
        defer systemd.notify.ready();

        // Get our config object.
        const config: *Config = config: {
            // Soft-reloading applies conditional logic to the existing loaded
            // config so we return that as-is (but take a reference).
            if (opts.soft) {
                break :config self.private().config.ref();
            }

            // Hard reload, load a new config completely.
            const alloc = self.allocator();
            var config = try CoreConfig.load(alloc);
            defer config.deinit();
            break :config try .new(alloc, &config);
        };
        defer config.unref();

        // Update the proper target. This will trigger a `confige_change`
        // apprt action which will propagate the config properly to our
        // property system.
        switch (target) {
            .app => try self.core().updateConfig(
                self.rt(),
                config.get(),
            ),
            .surface => |core| try core.updateConfig(config.get()),
        }
    }

    pub fn render(target: apprt.Target) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.redraw(),
        }
    }

    pub fn resizeSplit(
        target: apprt.Target,
        value: apprt.action.ResizeSplit,
    ) bool {
        switch (target) {
            .app => {
                log.warn("resize_split to app is unexpected", .{});
                return false;
            },
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const tree = ext.getAncestor(
                    SplitTree,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a split tree, ignoring resize_split", .{});
                    return false;
                };

                // If the tree has no splits (only one leaf), this action is not performable.
                // This allows the key event to pass through to the terminal.
                if (!tree.getIsSplit()) return false;

                return tree.resize(
                    switch (value.direction) {
                        .up => .up,
                        .down => .down,
                        .left => .left,
                        .right => .right,
                    },
                    value.amount,
                ) catch |err| switch (err) {
                    error.OutOfMemory => {
                        log.warn("unable to resize split, out of memory", .{});
                        return false;
                    },
                };
            },
        }
    }

    pub fn ringBell(target: apprt.Target) void {
        switch (target) {
            .app => {},
            .surface => |v| {
                v.rt_surface.surface.setBellRinging(true);

                // Termplex: mark surface with attention class for visual ring
                v.rt_surface.surface.as(gtk.Widget).addCssClass("termplex-attention");
            },
        }
    }

    pub fn scrollbar(
        target: apprt.Target,
        value: apprt.Action.Value(.scrollbar),
    ) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.setScrollbar(value),
        }
    }

    pub fn startSearch(target: apprt.Target, value: apprt.action.StartSearch) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.setSearchActive(true, value.needle),
        }
    }

    pub fn endSearch(target: apprt.Target) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.setSearchActive(false, ""),
        }
    }

    pub fn searchTotal(target: apprt.Target, value: apprt.action.SearchTotal) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.setSearchTotal(value.total),
        }
    }

    pub fn searchSelected(target: apprt.Target, value: apprt.action.SearchSelected) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.setSearchSelected(value.selected),
        }
    }

    pub fn setTitle(
        target: apprt.Target,
        value: apprt.action.SetTitle,
    ) void {
        switch (target) {
            .app => log.warn("set_title to app is unexpected", .{}),
            .surface => |surface| surface.rt_surface.gobj().setTitle(value.title),
        }
    }

    pub fn setTabTitle(
        target: apprt.Target,
        value: apprt.action.SetTitle,
    ) bool {
        switch (target) {
            .app => {
                log.warn("set_tab_title to app is unexpected", .{});
                return false;
            },
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const tab = ext.getAncestor(
                    Tab,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a tab, ignoring set_tab_title", .{});
                    return false;
                };
                tab.setTitleOverride(if (value.title.len == 0) null else value.title);
                return true;
            },
        }
    }

    pub fn showChildExited(
        target: apprt.Target,
        value: apprt.surface.Message.ChildExited,
    ) bool {
        return switch (target) {
            .app => false,
            .surface => |v| v.rt_surface.surface.childExited(value),
        };
    }

    pub fn showGtkInspector() void {
        gtk.Window.setInteractiveDebugging(@intFromBool(true));
    }

    pub fn sizeLimit(
        target: apprt.Target,
        value: apprt.action.SizeLimit,
    ) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                // Note: we ignore the max size currently because we have
                // no mechanism to enforce it.
                const surface = core.rt_surface.surface;
                surface.setMinSize(.{
                    .width = value.min_width,
                    .height = value.min_height,
                });

                return true;
            },
        }
    }

    pub fn toggleFullscreen(target: apprt.Target) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.toggleFullscreen(),
        }
    }

    pub fn toggleQuickTerminal(self: *Application) bool {
        // If we already have a quick terminal window, we just toggle the
        // visibility of it.
        if (getQuickTerminalWindow()) |win| {
            win.toggleVisibility();
            return true;
        }

        // If we don't support quick terminals then we do nothing.
        const priv = self.private();
        if (!priv.winproto.supportsQuickTerminal()) return false;

        // Create our new window as a quick terminal
        const win = gobject.ext.newInstance(Window, .{
            .application = self,
            .@"quick-terminal" = true,
        });
        assert(win.isQuickTerminal());
        initAndShowWindow(self, win, null, .none);
        return true;
    }

    pub fn toggleSplitZoom(target: apprt.Target) bool {
        switch (target) {
            .app => {
                log.warn("toggle_split_zoom to app is unexpected", .{});
                return false;
            },

            .surface => |core| {
                // TODO: pass surface ID when we have that
                const surface = core.rt_surface.surface;
                const tree = ext.getAncestor(
                    SplitTree,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a split tree, ignoring toggle_split_zoom", .{});
                    return false;
                };

                // If the tree has no splits (only one leaf), this action is not performable.
                // This allows the key event to pass through to the terminal.
                if (!tree.getIsSplit()) return false;

                return surface.as(gtk.Widget).activateAction("split-tree.zoom", null) != 0;
            },
        }
    }

    pub fn showOnScreenKeyboard(target: apprt.Target) bool {
        switch (target) {
            .app => {
                log.warn("show_on_screen_keyboard to app is unexpected", .{});
                return false;
            },
            // NOTE: Even though `activateOsk` takes a gdk.Event, it's currently
            // unused by all implementations of `activateOsk` as of GTK 4.18.
            // The commit that introduced the method (ce6aa73c) clarifies that
            // the event *may* be used by other IM backends, but for Linux desktop
            // environments this doesn't matter.
            .surface => |v| return v.rt_surface.surface.showOnScreenKeyboard(null),
        }
    }

    fn getQuickTerminalWindow() ?*Window {
        // Find a quick terminal window.
        const list = gtk.Window.listToplevels();
        defer list.free();
        if (ext.listFind(gtk.Window, list, struct {
            fn find(gtk_win: *gtk.Window) bool {
                const win = gobject.ext.cast(
                    Window,
                    gtk_win,
                ) orelse return false;
                return win.isQuickTerminal();
            }
        }.find)) |w| return gobject.ext.cast(
            Window,
            w,
        ).?;

        return null;
    }

    pub fn toggleMaximize(target: apprt.Target) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.toggleMaximize(),
        }
    }

    pub fn toggleTabOverview(target: apprt.Target) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const window = ext.getAncestor(
                    Window,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a window, ignoring new_tab", .{});
                    return false;
                };

                window.toggleTabOverview();
                return true;
            },
        }
    }

    pub fn toggleWindowDecorations(target: apprt.Target) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const window = ext.getAncestor(
                    Window,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a window, ignoring toggle_window_decorations", .{});
                    return false;
                };

                window.toggleWindowDecorations();
                return true;
            },
        }
    }

    pub fn toggleCommandPalette(target: apprt.Target) bool {
        switch (target) {
            .app => return false,
            .surface => |surface| {
                return surface.rt_surface.gobj().toggleCommandPalette();
            },
        }
    }

    pub fn controlInspector(target: apprt.Target, value: apprt.Action.Value(.inspector)) bool {
        switch (target) {
            .app => return false,
            .surface => |surface| {
                return surface.rt_surface.gobj().controlInspector(value);
            },
        }
    }

    pub fn commandFinished(target: apprt.Target, value: apprt.Action.Value(.command_finished)) bool {
        switch (target) {
            .app => return false,
            .surface => |surface| {
                return surface.rt_surface.gobj().commandFinished(value);
            },
        }
    }

    pub fn setReadonly(target: apprt.Target, value: apprt.Action.Value(.readonly)) bool {
        switch (target) {
            .app => return false,
            .surface => |surface| {
                return surface.rt_surface.gobj().setReadonly(value);
            },
        }
    }

    pub fn keySequence(target: apprt.Target, value: apprt.Action.Value(.key_sequence)) bool {
        switch (target) {
            .app => {
                log.warn("key_sequence action to app is unexpected", .{});
                return false;
            },
            .surface => |core| {
                core.rt_surface.gobj().keySequenceAction(value) catch |err| {
                    log.warn("error handling key_sequence action: {}", .{err});
                };
                return true;
            },
        }
    }

    pub fn keyTable(target: apprt.Target, value: apprt.Action.Value(.key_table)) bool {
        switch (target) {
            .app => {
                log.warn("key_table action to app is unexpected", .{});
                return false;
            },
            .surface => |core| {
                core.rt_surface.gobj().keyTableAction(value) catch |err| {
                    log.warn("error handling key_table action: {}", .{err});
                };
                return true;
            },
        }
    }
};

/// This sets various GTK-related environment variables as necessary
/// given the runtime environment or configuration.
///
/// This must be called BEFORE GTK initialization.
fn setGtkEnv(config: *const CoreConfig) error{NoSpaceLeft}!void {
    assert(gtk.isInitialized() == 0);

    var gdk_debug: struct {
        /// output OpenGL debug information
        opengl: bool = false,
        /// disable GLES, Termplex can't use GLES
        @"gl-disable-gles": bool = false,
        // GTK's new renderer can cause blurry font when using fractional scaling.
        @"gl-no-fractional": bool = false,
        /// Disabling Vulkan can improve startup times by hundreds of
        /// milliseconds on some systems. We don't use Vulkan so we can just
        /// disable it.
        @"vulkan-disable": bool = false,
    } = .{
        // `gtk-opengl-debug` dumps logs directly to stderr so both must be true
        // to enable OpenGL debugging.
        .opengl = state.logging.stderr and config.@"gtk-opengl-debug",
    };

    var gdk_disable: struct {
        @"gles-api": bool = false,
        /// current gtk implementation for color management is not good enough.
        /// see: https://bugs.kde.org/show_bug.cgi?id=495647
        /// gtk issue: https://gitlab.gnome.org/GNOME/gtk/-/issues/6864
        @"color-mgmt": bool = true,
        /// Disabling Vulkan can improve startup times by hundreds of
        /// milliseconds on some systems. We don't use Vulkan so we can just
        /// disable it.
        vulkan: bool = false,
    } = .{};

    environment: {
        if (gtk_version.runtimeAtLeast(4, 18, 0)) {
            gdk_disable.@"color-mgmt" = false;
        }

        if (gtk_version.runtimeAtLeast(4, 16, 0)) {
            // From gtk 4.16, GDK_DEBUG is split into GDK_DEBUG and GDK_DISABLE.
            // For the remainder of "why" see the 4.14 comment below.
            gdk_disable.@"gles-api" = true;
            gdk_disable.vulkan = true;
            break :environment;
        }
        if (gtk_version.runtimeAtLeast(4, 14, 0)) {
            // We need to export GDK_DEBUG to run on Wayland after GTK 4.14.
            // Older versions of GTK do not support these values so it is safe
            // to always set this. Forwards versions are uncertain so we'll have
            // to reassess...
            //
            // Upstream issue: https://gitlab.gnome.org/GNOME/gtk/-/issues/6589
            gdk_debug.@"gl-disable-gles" = true;
            gdk_debug.@"vulkan-disable" = true;

            if (gtk_version.runtimeUntil(4, 17, 5)) {
                // Removed at GTK v4.17.5
                gdk_debug.@"gl-no-fractional" = true;
            }
            break :environment;
        }

        // Versions prior to 4.14 are a bit of an unknown for Termplex. It
        // is an environment that isn't tested well and we don't have a
        // good understanding of what we may need to do.
        gdk_debug.@"vulkan-disable" = true;
    }

    {
        var buf: [1024]u8 = undefined;
        var fmt = std.io.fixedBufferStream(&buf);
        const writer = fmt.writer();
        var first: bool = true;
        inline for (@typeInfo(@TypeOf(gdk_debug)).@"struct".fields) |field| {
            if (@field(gdk_debug, field.name)) {
                if (!first) try writer.writeAll(",");
                try writer.writeAll(field.name);
                first = false;
            }
        }
        try writer.writeByte(0);
        const value = fmt.getWritten();
        log.warn("setting GDK_DEBUG={s}", .{value[0 .. value.len - 1]});
        _ = internal_os.setenv("GDK_DEBUG", value[0 .. value.len - 1 :0]);
    }

    {
        var buf: [1024]u8 = undefined;
        var fmt = std.io.fixedBufferStream(&buf);
        const writer = fmt.writer();
        var first: bool = true;
        inline for (@typeInfo(@TypeOf(gdk_disable)).@"struct".fields) |field| {
            if (@field(gdk_disable, field.name)) {
                if (!first) try writer.writeAll(",");
                try writer.writeAll(field.name);
                first = false;
            }
        }
        try writer.writeByte(0);
        const value = fmt.getWritten();
        log.warn("setting GDK_DISABLE={s}", .{value[0 .. value.len - 1]});
        _ = internal_os.setenv("GDK_DISABLE", value[0 .. value.len - 1 :0]);
    }
}

fn findActiveWindow(data: ?*const anyopaque, _: ?*const anyopaque) callconv(.c) c_int {
    const window: *gtk.Window = @ptrCast(@alignCast(@constCast(data orelse return -1)));

    // Confusingly, `isActive` returns 1 when active,
    // but we want to return 0 to indicate equality.
    // Abusing integers to be enums and booleans is a terrible idea, C.
    return if (window.isActive() != 0) 0 else -1;
}

test "ipc transcript fallback strips terminal control sequences" {
    const bytes = "one\r\n\x1b]133;A;aid=1\x07two\x1b[31m red\x1b[0m\rthree\x01four";
    const out = try transcript_view.stripControlSequences(std.testing.allocator, bytes);
    defer std.testing.allocator.free(out);

    try std.testing.expectEqualStrings("one\ntwo red\nthreefour", out);
}

test "session workspace pinned parser defaults false and reads true" {
    const alloc = std.testing.allocator;

    const pinned = try std.json.parseFromSlice(std.json.Value, alloc, "{\"pinned\":true}", .{});
    defer pinned.deinit();
    try std.testing.expectEqual(true, Application.sessionWorkspacePinned(pinned.value));

    const missing = try std.json.parseFromSlice(std.json.Value, alloc, "{\"name\":\"api\"}", .{});
    defer missing.deinit();
    try std.testing.expectEqual(false, Application.sessionWorkspacePinned(missing.value));
}

test "task default name is derived from command text" {
    const alloc = std.testing.allocator;

    const first = try Application.defaultTaskNameFromCommand(alloc, "zig build test -Dtest-filter=history", 42);
    defer alloc.free(first);
    try std.testing.expectEqualStrings("zig build test", first);

    const empty = try Application.defaultTaskNameFromCommand(alloc, "", 7);
    defer alloc.free(empty);
    try std.testing.expectEqualStrings("command 7", empty);
}
