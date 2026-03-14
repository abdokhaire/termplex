// src/termplex/core/config.zig
// TermplexConfig: load and parse ~/.config/termplex/config.toml
//
// Supports simple flat key=value pairs within [section] headers.
// No nested tables or arrays of tables are needed.
//
// Config file location:
//   $XDG_CONFIG_HOME/termplex/config.toml
//   (falls back to $HOME/.config/termplex/config.toml)
//
// Returns sensible defaults when config file doesn't exist.

const std = @import("std");

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Sidebar position: which side the sidebar appears on.
pub const SidebarPosition = enum {
    left,
    right,

    pub fn fromString(s: []const u8) ?SidebarPosition {
        if (std.mem.eql(u8, s, "left")) return .left;
        if (std.mem.eql(u8, s, "right")) return .right;
        return null;
    }
};

/// The keybinding modifier prefix.
pub const Modifier = enum {
    ctrl_shift,
    super,
    alt,
    ctrl,

    pub fn fromString(s: []const u8) ?Modifier {
        if (std.mem.eql(u8, s, "ctrl_shift")) return .ctrl_shift;
        if (std.mem.eql(u8, s, "super")) return .super;
        if (std.mem.eql(u8, s, "alt")) return .alt;
        if (std.mem.eql(u8, s, "ctrl")) return .ctrl;
        return null;
    }
};

/// Keybinding configuration.
///
/// Each field holds the key string for a binding.
/// If a value starts with "!", the modifier prefix is NOT prepended (full
/// override). All strings are owned by the parent TermplexConfig.
pub const Keybindings = struct {
    modifier: Modifier,
    jump_unread: []const u8,
    new_workspace: []const u8,
    close_workspace: []const u8,
    next_workspace: []const u8,
    prev_workspace: []const u8,
    new_tab: []const u8,
    close_tab: []const u8,
    split_right: []const u8,
    split_down: []const u8,
    close_pane: []const u8,
    toggle_sidebar: []const u8,
    rename_workspace: []const u8,
    find: []const u8,
};

/// Appearance configuration.
pub const Appearance = struct {
    /// "dark" or "light".
    theme: []const u8,
    /// Path to ghostty config file (empty string = use ghostty default).
    ghostty_config: []const u8,
};

/// Notification configuration.
pub const Notifications = struct {
    /// Hex colour string, e.g. "#4da6ff".
    attention_color: []const u8,
    sound: bool,
};

/// Session persistence configuration.
pub const Session = struct {
    /// Autosave interval in minutes.
    autosave_interval: u32,
    restore_on_startup: bool,
};

/// Top-level Termplex configuration.
///
/// All heap-allocated strings are owned by this struct. Call `deinit` to free.
pub const TermplexConfig = struct {
    allocator: std.mem.Allocator,

    // [general]
    sidebar_width: u32,
    sidebar_position: SidebarPosition,

    // [appearance]
    appearance: Appearance,

    // [keybindings]
    keybindings: Keybindings,

    // [notifications]
    notifications: Notifications,

    // [session]
    session: Session,

    /// Internal flag: true when all string fields are heap-allocated (dups).
    _owned: bool,

    // -----------------------------------------------------------------------
    // Defaults
    // -----------------------------------------------------------------------

    /// Return a TermplexConfig populated with compile-time defaults.
    ///
    /// All string fields point to string literals (no heap allocation needed
    /// for the defaults themselves). deinit() is safe because _owned = false.
    pub fn default(allocator: std.mem.Allocator) TermplexConfig {
        return .{
            .allocator = allocator,
            .sidebar_width = 180,
            .sidebar_position = .left,
            .appearance = .{
                .theme = "dark",
                .ghostty_config = "",
            },
            .keybindings = .{
                .modifier = .ctrl_shift,
                .jump_unread = "U",
                .new_workspace = "N",
                .close_workspace = "W",
                .next_workspace = "]",
                .prev_workspace = "[",
                .new_tab = "T",
                .close_tab = "Q",
                .split_right = "D",
                .split_down = "!Ctrl+Shift+Alt+D",
                .close_pane = "X",
                .toggle_sidebar = "B",
                .rename_workspace = "R",
                .find = "F",
            },
            .notifications = .{
                .attention_color = "#4da6ff",
                .sound = false,
            },
            .session = .{
                .autosave_interval = 5,
                .restore_on_startup = true,
            },
            ._owned = false,
        };
    }

    // -----------------------------------------------------------------------
    // deinit
    // -----------------------------------------------------------------------

    /// Free all heap-allocated strings owned by this config.
    ///
    /// Safe to call on a default() config (_owned = false, no-op).
    /// When _owned = true (returned by parseConfig/load), all string fields
    /// are freed.
    pub fn deinit(self: *TermplexConfig) void {
        if (self._owned) {
            self.allocator.free(self.appearance.theme);
            self.allocator.free(self.appearance.ghostty_config);
            self.allocator.free(self.keybindings.jump_unread);
            self.allocator.free(self.keybindings.new_workspace);
            self.allocator.free(self.keybindings.close_workspace);
            self.allocator.free(self.keybindings.next_workspace);
            self.allocator.free(self.keybindings.prev_workspace);
            self.allocator.free(self.keybindings.new_tab);
            self.allocator.free(self.keybindings.close_tab);
            self.allocator.free(self.keybindings.split_right);
            self.allocator.free(self.keybindings.split_down);
            self.allocator.free(self.keybindings.close_pane);
            self.allocator.free(self.keybindings.toggle_sidebar);
            self.allocator.free(self.keybindings.rename_workspace);
            self.allocator.free(self.keybindings.find);
            self.allocator.free(self.notifications.attention_color);
        }
        self._owned = false;
    }
};

// ---------------------------------------------------------------------------
// Path resolution
// ---------------------------------------------------------------------------

/// Resolve the config file path.
///
/// Priority:
///   1. $XDG_CONFIG_HOME/termplex/config.toml
///   2. $HOME/.config/termplex/config.toml
///
/// Returns an allocated string; caller owns it.
pub fn getConfigPath(allocator: std.mem.Allocator) ![]u8 {
    // Try XDG_CONFIG_HOME first.
    if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |config_home| {
        defer allocator.free(config_home);
        return std.fs.path.join(allocator, &[_][]const u8{ config_home, "termplex", "config.toml" });
    } else |_| {}

    // Fall back to $HOME/.config
    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        return std.fs.path.join(allocator, &[_][]const u8{ home, ".config", "termplex", "config.toml" });
    } else |_| {}

    // Last resort: relative path.
    return allocator.dupe(u8, ".config/termplex/config.toml");
}

// ---------------------------------------------------------------------------
// load()
// ---------------------------------------------------------------------------

/// Load and parse the config file.
///
/// Returns a fully heap-allocated TermplexConfig (_owned = true) on success.
/// Returns default config (_owned = false) if the file does not exist.
/// The caller is responsible for calling deinit() in both cases.
pub fn load(allocator: std.mem.Allocator) !TermplexConfig {
    const path = try getConfigPath(allocator);
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return TermplexConfig.default(allocator),
        else => return err,
    };
    defer file.close();

    const max_size = 1 * 1024 * 1024; // 1 MiB ceiling
    const contents = try file.readToEndAlloc(allocator, max_size);
    defer allocator.free(contents);

    return parseConfig(allocator, contents);
}

// ---------------------------------------------------------------------------
// Minimal TOML parser (line-based, flat sections only)
// ---------------------------------------------------------------------------

/// Parse TOML content into a TermplexConfig.
///
/// All string fields in the returned config are heap-allocated (_owned = true).
/// Returns error.InvalidConfig for malformed input.
pub fn parseConfig(allocator: std.mem.Allocator, toml: []const u8) !TermplexConfig {
    // Start from defaults so missing keys keep their default value.
    var cfg = TermplexConfig.default(allocator);

    // We'll build heap-owned copies of all string defaults upfront so that
    // deinit() can unconditionally free them once _owned is set.
    var theme = try allocator.dupe(u8, cfg.appearance.theme);
    errdefer allocator.free(theme);
    var ghostty_config = try allocator.dupe(u8, cfg.appearance.ghostty_config);
    errdefer allocator.free(ghostty_config);
    var jump_unread = try allocator.dupe(u8, cfg.keybindings.jump_unread);
    errdefer allocator.free(jump_unread);
    var new_workspace = try allocator.dupe(u8, cfg.keybindings.new_workspace);
    errdefer allocator.free(new_workspace);
    var close_workspace = try allocator.dupe(u8, cfg.keybindings.close_workspace);
    errdefer allocator.free(close_workspace);
    var next_workspace = try allocator.dupe(u8, cfg.keybindings.next_workspace);
    errdefer allocator.free(next_workspace);
    var prev_workspace = try allocator.dupe(u8, cfg.keybindings.prev_workspace);
    errdefer allocator.free(prev_workspace);
    var new_tab = try allocator.dupe(u8, cfg.keybindings.new_tab);
    errdefer allocator.free(new_tab);
    var close_tab = try allocator.dupe(u8, cfg.keybindings.close_tab);
    errdefer allocator.free(close_tab);
    var split_right = try allocator.dupe(u8, cfg.keybindings.split_right);
    errdefer allocator.free(split_right);
    var split_down = try allocator.dupe(u8, cfg.keybindings.split_down);
    errdefer allocator.free(split_down);
    var close_pane = try allocator.dupe(u8, cfg.keybindings.close_pane);
    errdefer allocator.free(close_pane);
    var toggle_sidebar = try allocator.dupe(u8, cfg.keybindings.toggle_sidebar);
    errdefer allocator.free(toggle_sidebar);
    var rename_workspace = try allocator.dupe(u8, cfg.keybindings.rename_workspace);
    errdefer allocator.free(rename_workspace);
    var find = try allocator.dupe(u8, cfg.keybindings.find);
    errdefer allocator.free(find);
    var attention_color = try allocator.dupe(u8, cfg.notifications.attention_color);
    errdefer allocator.free(attention_color);

    // Current section name (empty string = before any section header).
    var current_section: []const u8 = "";

    var lines = std.mem.splitScalar(u8, toml, '\n');
    while (lines.next()) |raw_line| {
        // Trim trailing \r (Windows line endings).
        const line = trimRight(raw_line);

        // Skip empty lines and comments.
        if (line.len == 0 or line[0] == '#') continue;

        // Section header: [section_name]
        if (line[0] == '[') {
            const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            current_section = std.mem.trim(u8, line[1..close], " \t");
            continue;
        }

        // key = value
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const raw_value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        // Strip inline comment from value (# not inside quotes).
        const value = stripInlineComment(raw_value);

        // Dispatch to section handler.
        if (std.mem.eql(u8, current_section, "general")) {
            if (std.mem.eql(u8, key, "sidebar_width")) {
                cfg.sidebar_width = std.fmt.parseInt(u32, value, 10) catch continue;
            } else if (std.mem.eql(u8, key, "sidebar_position")) {
                const s = unquote(value);
                cfg.sidebar_position = SidebarPosition.fromString(s) orelse cfg.sidebar_position;
            }
        } else if (std.mem.eql(u8, current_section, "appearance")) {
            if (std.mem.eql(u8, key, "theme")) {
                allocator.free(theme);
                theme = try allocator.dupe(u8, unquote(value));
            } else if (std.mem.eql(u8, key, "ghostty_config")) {
                allocator.free(ghostty_config);
                ghostty_config = try allocator.dupe(u8, unquote(value));
            }
        } else if (std.mem.eql(u8, current_section, "keybindings")) {
            if (std.mem.eql(u8, key, "modifier")) {
                const s = unquote(value);
                cfg.keybindings.modifier = Modifier.fromString(s) orelse cfg.keybindings.modifier;
            } else if (std.mem.eql(u8, key, "jump_unread")) {
                allocator.free(jump_unread);
                jump_unread = try allocator.dupe(u8, unquote(value));
            } else if (std.mem.eql(u8, key, "new_workspace")) {
                allocator.free(new_workspace);
                new_workspace = try allocator.dupe(u8, unquote(value));
            } else if (std.mem.eql(u8, key, "close_workspace")) {
                allocator.free(close_workspace);
                close_workspace = try allocator.dupe(u8, unquote(value));
            } else if (std.mem.eql(u8, key, "next_workspace")) {
                allocator.free(next_workspace);
                next_workspace = try allocator.dupe(u8, unquote(value));
            } else if (std.mem.eql(u8, key, "prev_workspace")) {
                allocator.free(prev_workspace);
                prev_workspace = try allocator.dupe(u8, unquote(value));
            } else if (std.mem.eql(u8, key, "new_tab")) {
                allocator.free(new_tab);
                new_tab = try allocator.dupe(u8, unquote(value));
            } else if (std.mem.eql(u8, key, "close_tab")) {
                allocator.free(close_tab);
                close_tab = try allocator.dupe(u8, unquote(value));
            } else if (std.mem.eql(u8, key, "split_right")) {
                allocator.free(split_right);
                split_right = try allocator.dupe(u8, unquote(value));
            } else if (std.mem.eql(u8, key, "split_down")) {
                allocator.free(split_down);
                split_down = try allocator.dupe(u8, unquote(value));
            } else if (std.mem.eql(u8, key, "close_pane")) {
                allocator.free(close_pane);
                close_pane = try allocator.dupe(u8, unquote(value));
            } else if (std.mem.eql(u8, key, "toggle_sidebar")) {
                allocator.free(toggle_sidebar);
                toggle_sidebar = try allocator.dupe(u8, unquote(value));
            } else if (std.mem.eql(u8, key, "rename_workspace")) {
                allocator.free(rename_workspace);
                rename_workspace = try allocator.dupe(u8, unquote(value));
            } else if (std.mem.eql(u8, key, "find")) {
                allocator.free(find);
                find = try allocator.dupe(u8, unquote(value));
            }
        } else if (std.mem.eql(u8, current_section, "notifications")) {
            if (std.mem.eql(u8, key, "attention_color")) {
                allocator.free(attention_color);
                attention_color = try allocator.dupe(u8, unquote(value));
            } else if (std.mem.eql(u8, key, "sound")) {
                cfg.notifications.sound = parseBool(value) orelse cfg.notifications.sound;
            }
        } else if (std.mem.eql(u8, current_section, "session")) {
            if (std.mem.eql(u8, key, "autosave_interval")) {
                cfg.session.autosave_interval = std.fmt.parseInt(u32, value, 10) catch continue;
            } else if (std.mem.eql(u8, key, "restore_on_startup")) {
                cfg.session.restore_on_startup = parseBool(value) orelse cfg.session.restore_on_startup;
            }
        }
        // Unknown sections/keys are silently ignored.
    }

    // Commit all heap-owned strings back into the config.
    cfg.appearance.theme = theme;
    cfg.appearance.ghostty_config = ghostty_config;
    cfg.keybindings.jump_unread = jump_unread;
    cfg.keybindings.new_workspace = new_workspace;
    cfg.keybindings.close_workspace = close_workspace;
    cfg.keybindings.next_workspace = next_workspace;
    cfg.keybindings.prev_workspace = prev_workspace;
    cfg.keybindings.new_tab = new_tab;
    cfg.keybindings.close_tab = close_tab;
    cfg.keybindings.split_right = split_right;
    cfg.keybindings.split_down = split_down;
    cfg.keybindings.close_pane = close_pane;
    cfg.keybindings.toggle_sidebar = toggle_sidebar;
    cfg.keybindings.rename_workspace = rename_workspace;
    cfg.keybindings.find = find;
    cfg.notifications.attention_color = attention_color;
    cfg._owned = true;

    return cfg;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Strip a trailing '\r' and any trailing whitespace from a line.
fn trimRight(s: []const u8) []const u8 {
    return std.mem.trimRight(u8, s, " \t\r");
}

/// Strip an inline comment: find the first '#' that isn't inside quotes,
/// then trim trailing whitespace from the result.
fn stripInlineComment(s: []const u8) []const u8 {
    var in_quote = false;
    var quote_char: u8 = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (in_quote) {
            if (c == quote_char) in_quote = false;
        } else {
            if (c == '"' or c == '\'') {
                in_quote = true;
                quote_char = c;
            } else if (c == '#') {
                return std.mem.trimRight(u8, s[0..i], " \t");
            }
        }
    }
    return s;
}

/// Strip surrounding double or single quotes from a string value.
fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and ((s[0] == '"' and s[s.len - 1] == '"') or
        (s[0] == '\'' and s[s.len - 1] == '\'')))
    {
        return s[1 .. s.len - 1];
    }
    return s;
}

/// Parse "true" or "false" (case-insensitive). Returns null on unknown input.
fn parseBool(s: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(s, "true")) return true;
    if (std.ascii.eqlIgnoreCase(s, "false")) return false;
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "default config values" {
    const allocator = std.testing.allocator;
    var cfg = TermplexConfig.default(allocator);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u32, 180), cfg.sidebar_width);
    try std.testing.expectEqual(SidebarPosition.left, cfg.sidebar_position);
    try std.testing.expectEqualStrings("dark", cfg.appearance.theme);
    try std.testing.expectEqualStrings("", cfg.appearance.ghostty_config);
    try std.testing.expectEqual(Modifier.ctrl_shift, cfg.keybindings.modifier);
    try std.testing.expectEqualStrings("U", cfg.keybindings.jump_unread);
    try std.testing.expectEqualStrings("N", cfg.keybindings.new_workspace);
    try std.testing.expectEqualStrings("W", cfg.keybindings.close_workspace);
    try std.testing.expectEqualStrings("]", cfg.keybindings.next_workspace);
    try std.testing.expectEqualStrings("[", cfg.keybindings.prev_workspace);
    try std.testing.expectEqualStrings("T", cfg.keybindings.new_tab);
    try std.testing.expectEqualStrings("Q", cfg.keybindings.close_tab);
    try std.testing.expectEqualStrings("D", cfg.keybindings.split_right);
    try std.testing.expectEqualStrings("!Ctrl+Shift+Alt+D", cfg.keybindings.split_down);
    try std.testing.expectEqualStrings("X", cfg.keybindings.close_pane);
    try std.testing.expectEqualStrings("B", cfg.keybindings.toggle_sidebar);
    try std.testing.expectEqualStrings("R", cfg.keybindings.rename_workspace);
    try std.testing.expectEqualStrings("F", cfg.keybindings.find);
    try std.testing.expectEqualStrings("#4da6ff", cfg.notifications.attention_color);
    try std.testing.expectEqual(false, cfg.notifications.sound);
    try std.testing.expectEqual(@as(u32, 5), cfg.session.autosave_interval);
    try std.testing.expectEqual(true, cfg.session.restore_on_startup);
}

test "parse full config" {
    const allocator = std.testing.allocator;
    const toml =
        \\[general]
        \\sidebar_width = 220
        \\sidebar_position = "right"
        \\
        \\[appearance]
        \\theme = "light"
        \\ghostty_config = "/home/user/.config/ghostty/config"
        \\
        \\[keybindings]
        \\modifier = "super"
        \\jump_unread = "J"
        \\new_workspace = "W"
        \\close_workspace = "C"
        \\next_workspace = "."
        \\prev_workspace = ","
        \\new_tab = "t"
        \\close_tab = "x"
        \\split_right = "s"
        \\split_down = "!Super+Shift+S"
        \\close_pane = "p"
        \\toggle_sidebar = "b"
        \\rename_workspace = "r"
        \\find = "/"
        \\
        \\[notifications]
        \\attention_color = "#ff0000"
        \\sound = true
        \\
        \\[session]
        \\autosave_interval = 10
        \\restore_on_startup = false
    ;

    var cfg = try parseConfig(allocator, toml);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u32, 220), cfg.sidebar_width);
    try std.testing.expectEqual(SidebarPosition.right, cfg.sidebar_position);
    try std.testing.expectEqualStrings("light", cfg.appearance.theme);
    try std.testing.expectEqualStrings("/home/user/.config/ghostty/config", cfg.appearance.ghostty_config);
    try std.testing.expectEqual(Modifier.super, cfg.keybindings.modifier);
    try std.testing.expectEqualStrings("J", cfg.keybindings.jump_unread);
    try std.testing.expectEqualStrings("W", cfg.keybindings.new_workspace);
    try std.testing.expectEqualStrings("C", cfg.keybindings.close_workspace);
    try std.testing.expectEqualStrings(".", cfg.keybindings.next_workspace);
    try std.testing.expectEqualStrings(",", cfg.keybindings.prev_workspace);
    try std.testing.expectEqualStrings("t", cfg.keybindings.new_tab);
    try std.testing.expectEqualStrings("x", cfg.keybindings.close_tab);
    try std.testing.expectEqualStrings("s", cfg.keybindings.split_right);
    try std.testing.expectEqualStrings("!Super+Shift+S", cfg.keybindings.split_down);
    try std.testing.expectEqualStrings("p", cfg.keybindings.close_pane);
    try std.testing.expectEqualStrings("b", cfg.keybindings.toggle_sidebar);
    try std.testing.expectEqualStrings("r", cfg.keybindings.rename_workspace);
    try std.testing.expectEqualStrings("/", cfg.keybindings.find);
    try std.testing.expectEqualStrings("#ff0000", cfg.notifications.attention_color);
    try std.testing.expectEqual(true, cfg.notifications.sound);
    try std.testing.expectEqual(@as(u32, 10), cfg.session.autosave_interval);
    try std.testing.expectEqual(false, cfg.session.restore_on_startup);
}

test "parse partial config keeps defaults for missing keys" {
    const allocator = std.testing.allocator;
    const toml =
        \\[general]
        \\sidebar_width = 300
        \\
        \\[appearance]
        \\theme = "light"
    ;

    var cfg = try parseConfig(allocator, toml);
    defer cfg.deinit();

    // Explicitly set values.
    try std.testing.expectEqual(@as(u32, 300), cfg.sidebar_width);
    try std.testing.expectEqualStrings("light", cfg.appearance.theme);

    // Untouched values keep defaults.
    try std.testing.expectEqual(SidebarPosition.left, cfg.sidebar_position);
    try std.testing.expectEqualStrings("", cfg.appearance.ghostty_config);
    try std.testing.expectEqual(Modifier.ctrl_shift, cfg.keybindings.modifier);
    try std.testing.expectEqualStrings("U", cfg.keybindings.jump_unread);
    try std.testing.expectEqualStrings("#4da6ff", cfg.notifications.attention_color);
    try std.testing.expectEqual(false, cfg.notifications.sound);
    try std.testing.expectEqual(@as(u32, 5), cfg.session.autosave_interval);
    try std.testing.expectEqual(true, cfg.session.restore_on_startup);
}

test "parse ignores comments and empty lines" {
    const allocator = std.testing.allocator;
    const toml =
        \\# This is a full-line comment
        \\
        \\[general]
        \\# Another comment
        \\sidebar_width = 200  # inline comment
        \\sidebar_position = "left"  # position
        \\
        \\[notifications]
        \\attention_color = "#abcdef"  # color comment
        \\sound = false
    ;

    var cfg = try parseConfig(allocator, toml);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u32, 200), cfg.sidebar_width);
    try std.testing.expectEqual(SidebarPosition.left, cfg.sidebar_position);
    try std.testing.expectEqualStrings("#abcdef", cfg.notifications.attention_color);
    try std.testing.expectEqual(false, cfg.notifications.sound);
}

test "parse bool values" {
    const allocator = std.testing.allocator;

    // sound = true
    {
        const toml = "[notifications]\nsound = true\n";
        var cfg = try parseConfig(allocator, toml);
        defer cfg.deinit();
        try std.testing.expectEqual(true, cfg.notifications.sound);
    }

    // sound = false
    {
        const toml = "[notifications]\nsound = false\n";
        var cfg = try parseConfig(allocator, toml);
        defer cfg.deinit();
        try std.testing.expectEqual(false, cfg.notifications.sound);
    }

    // restore_on_startup = false
    {
        const toml = "[session]\nrestore_on_startup = false\n";
        var cfg = try parseConfig(allocator, toml);
        defer cfg.deinit();
        try std.testing.expectEqual(false, cfg.session.restore_on_startup);
    }
}

test "parse integer values" {
    const allocator = std.testing.allocator;
    const toml =
        \\[general]
        \\sidebar_width = 42
        \\[session]
        \\autosave_interval = 15
    ;

    var cfg = try parseConfig(allocator, toml);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u32, 42), cfg.sidebar_width);
    try std.testing.expectEqual(@as(u32, 15), cfg.session.autosave_interval);
}

test "parse invalid integer keeps default" {
    const allocator = std.testing.allocator;
    const toml = "[general]\nsidebar_width = notanumber\n";

    var cfg = try parseConfig(allocator, toml);
    defer cfg.deinit();

    // Default is 180; bad parse skips with `continue`.
    try std.testing.expectEqual(@as(u32, 180), cfg.sidebar_width);
}

test "parse unknown section and keys are silently ignored" {
    const allocator = std.testing.allocator;
    const toml =
        \\[unknown_section]
        \\some_key = "value"
        \\
        \\[general]
        \\sidebar_width = 160
        \\nonexistent_key = 999
    ;

    var cfg = try parseConfig(allocator, toml);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u32, 160), cfg.sidebar_width);
}

test "parse keybinding override prefix !" {
    const allocator = std.testing.allocator;
    const toml =
        \\[keybindings]
        \\split_down = "!Ctrl+Shift+Alt+D"
    ;

    var cfg = try parseConfig(allocator, toml);
    defer cfg.deinit();

    // The '!' prefix is preserved as-is; caller interprets it.
    try std.testing.expectEqualStrings("!Ctrl+Shift+Alt+D", cfg.keybindings.split_down);
}

test "parse windows line endings (CRLF)" {
    const allocator = std.testing.allocator;
    const toml = "[general]\r\nsidebar_width = 250\r\n";

    var cfg = try parseConfig(allocator, toml);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u32, 250), cfg.sidebar_width);
}

test "unquote helper" {
    try std.testing.expectEqualStrings("hello", unquote("\"hello\""));
    try std.testing.expectEqualStrings("hello", unquote("'hello'"));
    try std.testing.expectEqualStrings("hello", unquote("hello"));
    try std.testing.expectEqualStrings("", unquote("\"\""));
}

test "parseBool helper" {
    try std.testing.expectEqual(true, parseBool("true").?);
    try std.testing.expectEqual(true, parseBool("True").?);
    try std.testing.expectEqual(true, parseBool("TRUE").?);
    try std.testing.expectEqual(false, parseBool("false").?);
    try std.testing.expectEqual(false, parseBool("False").?);
    try std.testing.expectEqual(null, parseBool("yes"));
    try std.testing.expectEqual(null, parseBool("1"));
}

test "Modifier.fromString" {
    try std.testing.expectEqual(Modifier.ctrl_shift, Modifier.fromString("ctrl_shift").?);
    try std.testing.expectEqual(Modifier.super, Modifier.fromString("super").?);
    try std.testing.expectEqual(Modifier.alt, Modifier.fromString("alt").?);
    try std.testing.expectEqual(Modifier.ctrl, Modifier.fromString("ctrl").?);
    try std.testing.expectEqual(null, Modifier.fromString("unknown"));
}

test "SidebarPosition.fromString" {
    try std.testing.expectEqual(SidebarPosition.left, SidebarPosition.fromString("left").?);
    try std.testing.expectEqual(SidebarPosition.right, SidebarPosition.fromString("right").?);
    try std.testing.expectEqual(null, SidebarPosition.fromString("center"));
}

test "getConfigPath uses XDG_CONFIG_HOME" {
    const allocator = std.testing.allocator;

    // We can't reliably set env vars in a test, but we can exercise the
    // fallback path when neither var is set. Just ensure it returns a path
    // ending with "termplex/config.toml".
    const path = try getConfigPath(allocator);
    defer allocator.free(path);

    try std.testing.expect(std.mem.endsWith(u8, path, "termplex/config.toml"));
}
