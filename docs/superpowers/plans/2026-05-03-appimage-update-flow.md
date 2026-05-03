# AppImage Update Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an explicit Linux AppImage update flow that checks for newer Termplex releases, notifies the user in-app, downloads the AppImage inside Termplex, verifies it, and exposes the downloaded file without silently replacing the running binary.

**Architecture:** Implement updater behavior in three core modules: manifest parsing/version selection, persisted updater state, and AppImage download/checksum handling. Wire the core through the existing GTK application action `.check_for_updates`, a small in-window update affordance, and test-only IPC/status hooks so the E2E harness can verify the flow without depending on public network availability.

**Tech Stack:** Zig 0.15.2, GTK4/libadwaita, `std.json`, `std.SemanticVersion`, `std.http.Client`, `std.crypto.hash.sha2.Sha256`, XDG state directories, AppImage runtime environment variables, existing `tools/termplex-ctl`, and the real-app Python E2E harness.

---

## Current Context

Related roadmap/spec input:

- `docs/superpowers/plans/2026-05-03-termplex-roadmap-implementation-sequence.md`
- `docs/superpowers/plans/2026-05-03-termplex-future-enhancements.md`
- `docs/superpowers/plans/2026-05-01-terminal-transcript-persistence.md`, section "Follow-Up Plan: Versioning And T3Code-Style AppImage Update UX"

Existing repo facts:

- `build.zig.zon` is the canonical release version source.
- `src/build/Config.zig` derives `build_config.version`, `build_config.version_string`, and `build_config.release_channel`.
- `src/cli/version.zig` already prints current version and release channel.
- `src/config/Config.zig` already has `auto-update` and `auto-update-channel`, but its comments still describe inherited macOS/Sparkle behavior.
- `src/apprt/action.zig` already includes `.check_for_updates`.
- `src/apprt/gtk/class/command_palette.zig` already exposes `.check_for_updates`.
- `src/apprt/gtk/class/application.zig` currently routes `.check_for_updates` through the unimplemented-action path.
- `src/apprt/gtk/class/window.zig` has existing toast helpers and access to `Adw.ToastOverlay`.
- `test/e2e/termplex_e2e.py` can launch the real GTK app with disposable XDG state and drive IPC.

Primary-source constraints:

- AppImage runtimes expose `APPIMAGE`; the official AppImage docs define it as the absolute resolved path to the running AppImage. Use `APPIMAGE` for detecting AppImage mode and for diagnostics about the current AppImage path. Source: https://docs.appimage.org/packaging-guide/environment-variables.html
- GitHub release responses include release assets with `browser_download_url` and, in the current REST docs, asset `digest` fields such as `sha256:<hex>`. Termplex phase 1 should still prefer its own manifest shape for deterministic channel/platform selection, but release tooling may populate that manifest from GitHub asset metadata. Source: https://docs.github.com/en/rest/releases/releases

## Phase 1 Behavior

User-visible behavior:

- Show the current version in About as it does today; do not bump `build.zig.zon` in this feature branch.
- Manual "Check for Updates" triggers a network check and reports one of:
  - Termplex is up to date.
  - A newer version is available.
  - A newer version is available, but this install is not an AppImage, so the release page should be opened manually.
  - The check failed with a concise recoverable error.
- When running from an AppImage and a newer AppImage asset is available, show a primary `Download` action.
- Download only after an explicit user action.
- Write downloads under `$XDG_STATE_HOME/termplex/updates/`, falling back to `$HOME/.local/state/termplex/updates/`.
- Download to `*.part`, verify SHA-256, set executable bits, then atomically rename to the final `.AppImage`.
- After verification, show `Open Download` to reveal the containing directory or file through the existing OS opener.
- Do not auto-run, auto-install, or overwrite the running AppImage in phase 1.
- Do not self-update Flatpak, Snap, deb, rpm, source, or unknown installs.

Security/privacy requirements:

- Use HTTPS-only manifest and download URLs.
- Do not send workspace names, workspace paths, git remotes, command history, transcript paths, transcript bytes, environment variables, or install paths during update checks.
- Reject manifests with missing/invalid semantic versions, unsupported channels, unsupported platforms, unsupported architectures, missing SHA-256 values, invalid SHA-256 hex, non-HTTPS URLs, filenames with path separators, and download URLs whose filename is not an AppImage for the selected AppImage asset.
- Treat network metadata such as IP address and User-Agent as unavoidable; do not add any extra identifying headers.
- Never execute downloaded content automatically.
- Persist only lightweight updater state: timestamps, versions, dismissed version, download path, install kind, checksum status, last error, and progress.

## Files

- Create: `src/termplex/core/update_manifest.zig`
- Create: `src/termplex/core/update_state.zig`
- Create: `src/termplex/core/update_checker.zig`
- Modify: `src/termplex/core/memory/paths.zig`
- Modify: `src/config/Config.zig`
- Modify: `src/apprt/gtk/class/application.zig`
- Modify: `src/apprt/gtk/class/window.zig`
- Modify: `src/apprt/gtk/ui/1.5/window.blp`
- Modify: `src/apprt/gtk/css/style.css`
- Modify: `src/apprt/gtk/css/style-dark.css`
- Modify: `src/main.zig`
- Modify: `tools/termplex-ctl`
- Modify: `test/e2e/termplex_e2e.py`
- Modify: `test/e2e/README.md`
- Modify: `tools/package/build-linux-packages.sh`
- Create: `tools/package/write-update-manifest.py`

## Manifest Shape

Use this release manifest in phase 1:

```json
{
  "version": "1.6.0",
  "channel": "stable",
  "released_at": "2026-05-03T00:00:00Z",
  "notes_url": "https://github.com/termplex-org/termplex/releases/tag/v1.6.0",
  "downloads": {
    "linux-x86_64-appimage": {
      "url": "https://github.com/termplex-org/termplex/releases/download/v1.6.0/Termplex-1.6.0-x86_64.AppImage",
      "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    },
    "linux-x86_64-deb": {
      "url": "https://github.com/termplex-org/termplex/releases/download/v1.6.0/termplex_1.6.0_amd64.deb",
      "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    }
  }
}
```

Selected platform keys for phase 1:

- `linux-x86_64-appimage`
- `linux-aarch64-appimage`
- `linux-x86_64-deb`
- `linux-aarch64-deb`

Phase 1 only downloads AppImage assets. Other asset kinds can be shown as "update available, open release page".

## Test Matrix

Unit tests must cover:

- Semantic version comparison with stable releases.
- Stable channel rejecting `tip` manifests.
- Tip channel accepting newer prerelease/build variants only when configured.
- Platform key generation for `x86_64` and `aarch64` Linux.
- Manifest parse success with AppImage and deb downloads.
- Manifest rejects invalid JSON, invalid version, missing downloads, missing SHA-256, invalid SHA-256, non-HTTPS URLs, and filenames containing `/` or `\`.
- AppImage detection from `APPIMAGE`.
- Non-AppImage detection for Flatpak/Snap/source/default installs.
- Update state JSON round-trip and dismissed-version behavior.
- Download finalization: `.part` file hash matches expected SHA-256, executable bit is set, final rename is atomic.
- Download finalization rejects checksum mismatch and removes stale `.part` files.

E2E must cover:

- Launching with update manifest URL overridden to a local loopback server or test file transport.
- Manual `check_for_updates` reports an update when current version is lower than the manifest version.
- AppImage mode can be simulated by setting `APPIMAGE` in the E2E environment.
- Download action writes the verified AppImage under the disposable XDG state update directory.
- `termplex-ctl update status` reports downloaded version and path.

## Task 1: Add Manifest Parser And Version Selection

**Files:**

- Create: `src/termplex/core/update_manifest.zig`
- Modify: `src/main.zig`

- [ ] **Step 1: Add module skeleton and public types**

Create `src/termplex/core/update_manifest.zig`:

```zig
const std = @import("std");

pub const Channel = enum {
    stable,
    tip,

    pub fn parse(value: []const u8) !Channel {
        if (std.mem.eql(u8, value, "stable")) return .stable;
        if (std.mem.eql(u8, value, "tip")) return .tip;
        return error.UnsupportedChannel;
    }
};

pub const AssetKind = enum {
    appimage,
    deb,
};

pub const Platform = struct {
    os: []const u8,
    arch: []const u8,
    kind: AssetKind,

    pub fn key(self: Platform, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}-{s}-{s}", .{
            self.os,
            self.arch,
            @tagName(self.kind),
        });
    }
};

pub const Download = struct {
    url: []const u8,
    sha256: [32]u8,
    filename: []const u8,
};

pub const Manifest = struct {
    version: std.SemanticVersion,
    channel: Channel,
    released_at: []const u8,
    notes_url: []const u8,
    downloads: std.StringHashMapUnmanaged(Download),

    pub fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
        allocator.free(self.released_at);
        allocator.free(self.notes_url);
        var it = self.downloads.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.url);
            allocator.free(entry.value_ptr.filename);
        }
        self.downloads.deinit(allocator);
    }
};
```

- [ ] **Step 2: Add validation helpers**

Add these helpers below the public types:

```zig
fn requireHttps(url: []const u8) !void {
    if (!std.mem.startsWith(u8, url, "https://")) return error.NonHttpsUrl;
}

fn filenameFromUrl(url: []const u8) ![]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, url, '/') orelse return error.InvalidUrl;
    const filename = url[slash + 1 ..];
    if (filename.len == 0) return error.InvalidUrl;
    if (std.mem.indexOfScalar(u8, filename, '/') != null) return error.InvalidFilename;
    if (std.mem.indexOfScalar(u8, filename, '\\') != null) return error.InvalidFilename;
    return filename;
}

fn parseSha256Hex(hex: []const u8) ![32]u8 {
    if (hex.len != 64) return error.InvalidSha256;
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch return error.InvalidSha256;
    return out;
}

fn parseSemanticVersion(raw: []const u8) !std.SemanticVersion {
    const without_v = if (raw.len > 0 and raw[0] == 'v') raw[1..] else raw;
    return std.SemanticVersion.parse(without_v) catch error.InvalidVersion;
}

pub fn isNewer(candidate: std.SemanticVersion, current: std.SemanticVersion) bool {
    return candidate.order(current) == .gt;
}
```

- [ ] **Step 3: Add manifest parser**

Add `parse`:

```zig
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Manifest {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidManifest;
    const obj = parsed.value.object;

    const version_raw = obj.get("version") orelse return error.MissingVersion;
    if (version_raw != .string) return error.InvalidVersion;
    const version = try parseSemanticVersion(version_raw.string);

    const channel_raw = obj.get("channel") orelse return error.MissingChannel;
    if (channel_raw != .string) return error.UnsupportedChannel;
    const channel = try Channel.parse(channel_raw.string);

    const released_raw = obj.get("released_at") orelse return error.MissingReleasedAt;
    if (released_raw != .string or released_raw.string.len == 0) return error.InvalidReleasedAt;

    const notes_raw = obj.get("notes_url") orelse return error.MissingNotesUrl;
    if (notes_raw != .string) return error.InvalidNotesUrl;
    try requireHttps(notes_raw.string);

    const downloads_raw = obj.get("downloads") orelse return error.MissingDownloads;
    if (downloads_raw != .object) return error.InvalidDownloads;

    var manifest = Manifest{
        .version = version,
        .channel = channel,
        .released_at = try allocator.dupe(u8, released_raw.string),
        .notes_url = try allocator.dupe(u8, notes_raw.string),
        .downloads = .empty,
    };
    errdefer manifest.deinit(allocator);

    var it = downloads_raw.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .object) return error.InvalidDownload;
        const dl = entry.value_ptr.object;

        const url_raw = dl.get("url") orelse return error.MissingUrl;
        if (url_raw != .string) return error.InvalidUrl;
        try requireHttps(url_raw.string);

        const sha_raw = dl.get("sha256") orelse return error.MissingSha256;
        if (sha_raw != .string) return error.InvalidSha256;

        const filename = try filenameFromUrl(url_raw.string);
        try manifest.downloads.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), .{
            .url = try allocator.dupe(u8, url_raw.string),
            .sha256 = try parseSha256Hex(sha_raw.string),
            .filename = try allocator.dupe(u8, filename),
        });
    }

    if (manifest.downloads.count() == 0) return error.MissingDownloads;
    return manifest;
}
```

- [ ] **Step 4: Add selection helper**

Add:

```zig
pub fn selectDownload(
    manifest: *const Manifest,
    platform: Platform,
    current_version: std.SemanticVersion,
    desired_channel: Channel,
) !?Download {
    if (manifest.channel != desired_channel) return null;
    if (!isNewer(manifest.version, current_version)) return null;

    var key_buf: [64]u8 = undefined;
    const platform_key = try platform.key(&key_buf);
    return manifest.downloads.get(platform_key);
}
```

- [ ] **Step 5: Add unit tests**

Add tests in the same file:

```zig
test "update_manifest parses and selects newer AppImage" {
    const alloc = std.testing.allocator;
    const json =
        \\{
        \\  "version": "1.6.0",
        \\  "channel": "stable",
        \\  "released_at": "2026-05-03T00:00:00Z",
        \\  "notes_url": "https://github.com/termplex-org/termplex/releases/tag/v1.6.0",
        \\  "downloads": {
        \\    "linux-x86_64-appimage": {
        \\      "url": "https://github.com/termplex-org/termplex/releases/download/v1.6.0/Termplex-1.6.0-x86_64.AppImage",
        \\      "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        \\    }
        \\  }
        \\}
    ;
    var manifest = try parse(alloc, json);
    defer manifest.deinit(alloc);
    try std.testing.expectEqual(std.SemanticVersion{ .major = 1, .minor = 6, .patch = 0 }, manifest.version);
    const selected = try selectDownload(&manifest, .{ .os = "linux", .arch = "x86_64", .kind = .appimage }, .{ .major = 1, .minor = 5, .patch = 0 }, .stable);
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("Termplex-1.6.0-x86_64.AppImage", selected.?.filename);
}

test "update_manifest rejects non-https URLs" {
    const alloc = std.testing.allocator;
    const json =
        \\{
        \\  "version": "1.6.0",
        \\  "channel": "stable",
        \\  "released_at": "2026-05-03T00:00:00Z",
        \\  "notes_url": "http://example.com/release",
        \\  "downloads": {}
        \\}
    ;
    try std.testing.expectError(error.NonHttpsUrl, parse(alloc, json));
}

test "update_manifest rejects invalid sha256" {
    const alloc = std.testing.allocator;
    const json =
        \\{
        \\  "version": "1.6.0",
        \\  "channel": "stable",
        \\  "released_at": "2026-05-03T00:00:00Z",
        \\  "notes_url": "https://example.com/release",
        \\  "downloads": {
        \\    "linux-x86_64-appimage": {
        \\      "url": "https://example.com/Termplex.AppImage",
        \\      "sha256": "bad"
        \\    }
        \\  }
        \\}
    ;
    try std.testing.expectError(error.InvalidSha256, parse(alloc, json));
}
```

- [ ] **Step 6: Run focused tests**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build test -Dtest-filter=update_manifest -fno-sys=gtk4-layer-shell
```

Expected:

- Tests fail until the module is imported into the test build, if needed.
- Add `_ = @import("termplex/core/update_manifest.zig");` to the existing `test` block in `src/main.zig`, then rerun. This keeps the new module discoverable by the repo's existing `zig build test` target.

- [ ] **Step 7: Commit manifest parser**

```bash
git add src/termplex/core/update_manifest.zig src/main.zig
git commit -m "feat: add update manifest parser"
```

## Task 2: Add Update Paths And Persisted State

**Files:**

- Create: `src/termplex/core/update_state.zig`
- Modify: `src/termplex/core/memory/paths.zig`

- [ ] **Step 1: Add update path helper**

In `src/termplex/core/memory/paths.zig`, add a function beside existing XDG/global state helpers:

```zig
pub const UpdatePaths = struct {
    dir: []u8,
    state_json: []u8,

    pub fn deinit(self: *UpdatePaths, allocator: std.mem.Allocator) void {
        allocator.free(self.dir);
        allocator.free(self.state_json);
    }
};

pub fn resolveUpdatePaths(allocator: std.mem.Allocator) !UpdatePaths {
    const base = std.posix.getenv("XDG_STATE_HOME") orelse blk: {
        const home = std.posix.getenv("HOME") orelse return error.MissingHome;
        break :blk try std.fmt.allocPrint(allocator, "{s}/.local/state", .{home});
    };
    const dir = try std.fmt.allocPrint(allocator, "{s}/termplex/updates", .{base});
    errdefer allocator.free(dir);
    const state_json = try std.fmt.allocPrint(allocator, "{s}/update-state.json", .{dir});
    return .{ .dir = dir, .state_json = state_json };
}
```

- [ ] **Step 2: Create state model**

Create `src/termplex/core/update_state.zig`:

```zig
const std = @import("std");

pub const InstallKind = enum { appimage, flatpak, snap, deb, rpm, source, unknown };
pub const ChecksumStatus = enum { none, verified, mismatch };

pub const State = struct {
    last_checked_at: ?[]const u8 = null,
    last_available_version: ?[]const u8 = null,
    dismissed_version: ?[]const u8 = null,
    downloaded_version: ?[]const u8 = null,
    download_path: ?[]const u8 = null,
    checksum_status: ChecksumStatus = .none,
    install_kind: InstallKind = .unknown,
    last_error: ?[]const u8 = null,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.last_checked_at) |v| allocator.free(v);
        if (self.last_available_version) |v| allocator.free(v);
        if (self.dismissed_version) |v| allocator.free(v);
        if (self.downloaded_version) |v| allocator.free(v);
        if (self.download_path) |v| allocator.free(v);
        if (self.last_error) |v| allocator.free(v);
    }

    pub fn shouldNotify(self: State, version: []const u8) bool {
        if (self.dismissed_version) |dismissed| {
            if (std.mem.eql(u8, dismissed, version)) return false;
        }
        return true;
    }
};
```

- [ ] **Step 3: Add load/save helpers**

Add:

```zig
pub fn load(allocator: std.mem.Allocator, path: []const u8) !State {
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidState;
    const obj = parsed.value.object;

    var state: State = .{};
    errdefer state.deinit(allocator);
    inline for (.{ "last_checked_at", "last_available_version", "dismissed_version", "downloaded_version", "download_path", "last_error" }) |field| {
        if (obj.get(field)) |value| {
            if (value == .string) {
                @field(state, field) = try allocator.dupe(u8, value.string);
            }
        }
    }
    if (obj.get("checksum_status")) |value| if (value == .string) {
        state.checksum_status = std.meta.stringToEnum(ChecksumStatus, value.string) orelse .none;
    };
    if (obj.get("install_kind")) |value| if (value == .string) {
        state.install_kind = std.meta.stringToEnum(InstallKind, value.string) orelse .unknown;
    };
    return state;
}

pub fn save(allocator: std.mem.Allocator, path: []const u8, state: State) !void {
    const dir = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try std.fs.cwd().makePath(dir);
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp);

    var file = try std.fs.createFileAbsolute(tmp, .{ .truncate = true });
    defer file.close();
    var buf: [4096]u8 = undefined;
    var writer = file.writer(&buf);
    const out = &writer.interface;

    try out.writeAll("{\n");
    try writeOptString(out, "last_checked_at", state.last_checked_at, true);
    try writeOptString(out, "last_available_version", state.last_available_version, true);
    try writeOptString(out, "dismissed_version", state.dismissed_version, true);
    try writeOptString(out, "downloaded_version", state.downloaded_version, true);
    try writeOptString(out, "download_path", state.download_path, true);
    try out.print("  \"checksum_status\": \"{s}\",\n", .{@tagName(state.checksum_status)});
    try out.print("  \"install_kind\": \"{s}\",\n", .{@tagName(state.install_kind)});
    try writeOptString(out, "last_error", state.last_error, false);
    try out.writeAll("}\n");
    try out.flush();
    try std.fs.renameAbsolute(tmp, path);
}

fn writeOptString(out: anytype, key: []const u8, value: ?[]const u8, comma: bool) !void {
    try out.print("  \"{s}\": ", .{key});
    if (value) |v| {
        try std.json.stringify(v, .{}, out);
    } else {
        try out.writeAll("null");
    }
    try out.writeAll(if (comma) ",\n" else "\n");
}
```

- [ ] **Step 4: Add state tests**

Add tests to `update_state.zig`:

```zig
test "update_state round trips dismissed version and install kind" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(alloc, "update-state.json");
    defer alloc.free(path);

    var state = State{
        .last_available_version = try alloc.dupe(u8, "1.6.0"),
        .dismissed_version = try alloc.dupe(u8, "1.6.0"),
        .install_kind = .appimage,
        .checksum_status = .verified,
    };
    defer state.deinit(alloc);

    try save(alloc, path, state);
    var restored = try load(alloc, path);
    defer restored.deinit(alloc);
    try std.testing.expect(!restored.shouldNotify("1.6.0"));
    try std.testing.expect(restored.shouldNotify("1.6.1"));
    try std.testing.expectEqual(InstallKind.appimage, restored.install_kind);
    try std.testing.expectEqual(ChecksumStatus.verified, restored.checksum_status);
}
```

- [ ] **Step 5: Run focused tests**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build test -Dtest-filter=update_state
```

Expected: update-state tests pass.

- [ ] **Step 6: Commit update state**

```bash
git add src/termplex/core/update_state.zig src/termplex/core/memory/paths.zig
git commit -m "feat: persist updater state"
```

## Task 3: Add AppImage Detection And Download Finalization

**Files:**

- Create: `src/termplex/core/update_checker.zig`

- [ ] **Step 1: Create install detection**

Create `src/termplex/core/update_checker.zig`:

```zig
const std = @import("std");
const update_manifest = @import("update_manifest.zig");
const update_state = @import("update_state.zig");

pub const CheckResult = union(enum) {
    up_to_date,
    available: Available,
    unavailable_for_install: Available,
};

pub const Available = struct {
    version: std.SemanticVersion,
    version_string: []const u8,
    notes_url: []const u8,
    download: ?update_manifest.Download,
    install_kind: update_state.InstallKind,
};

pub fn detectInstallKind(env: std.process.EnvMap) update_state.InstallKind {
    if (env.get("APPIMAGE")) |value| {
        if (value.len > 0) return .appimage;
    }
    if (env.get("FLATPAK_ID")) |_| return .flatpak;
    if (env.get("SNAP")) |_| return .snap;
    return .unknown;
}
```

- [ ] **Step 2: Add local manifest evaluation**

Add:

```zig
pub fn evaluateManifest(
    allocator: std.mem.Allocator,
    manifest_bytes: []const u8,
    current_version: std.SemanticVersion,
    desired_channel: update_manifest.Channel,
    install_kind: update_state.InstallKind,
    platform_arch: []const u8,
) !CheckResult {
    var manifest = try update_manifest.parse(allocator, manifest_bytes);
    defer manifest.deinit(allocator);

    if (!update_manifest.isNewer(manifest.version, current_version)) return .up_to_date;

    const version_string = try std.fmt.allocPrint(allocator, "{f}", .{manifest.version});
    errdefer allocator.free(version_string);
    const notes_url = try allocator.dupe(u8, manifest.notes_url);
    errdefer allocator.free(notes_url);

    if (install_kind != .appimage) {
        return .{ .unavailable_for_install = .{
            .version = manifest.version,
            .version_string = version_string,
            .notes_url = notes_url,
            .download = null,
            .install_kind = install_kind,
        } };
    }

    const dl = try update_manifest.selectDownload(&manifest, .{ .os = "linux", .arch = platform_arch, .kind = .appimage }, current_version, desired_channel);
    if (dl == null) return error.NoCompatibleDownload;

    return .{ .available = .{
        .version = manifest.version,
        .version_string = version_string,
        .notes_url = notes_url,
        .download = dl,
        .install_kind = install_kind,
    } };
}
```

- [ ] **Step 3: Add checksum/finalization helper**

Add:

```zig
pub fn finalizeDownloadedPart(
    allocator: std.mem.Allocator,
    part_path: []const u8,
    final_path: []const u8,
    expected_sha256: [32]u8,
) !void {
    var file = try std.fs.openFileAbsolute(part_path, .{ .mode = .read_only });
    defer file.close();

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    var actual: [32]u8 = undefined;
    hasher.final(&actual);
    if (!std.mem.eql(u8, &actual, &expected_sha256)) {
        std.fs.deleteFileAbsolute(part_path) catch {};
        return error.ChecksumMismatch;
    }

    if (@import("builtin").os.tag != .windows) {
        try std.posix.chmod(part_path, 0o755);
    }
    std.fs.deleteFileAbsolute(final_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try std.fs.renameAbsolute(part_path, final_path);
}
```

- [ ] **Step 4: Add finalization tests**

Add:

```zig
test "update_checker detects AppImage from env" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("APPIMAGE", "/tmp/Termplex.AppImage");
    try std.testing.expectEqual(update_state.InstallKind.appimage, detectInstallKind(env));
}

test "update_checker finalizes matching part file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "Termplex.AppImage.part", .data = "payload" });
    const part_path = try tmp.dir.realpathAlloc(alloc, "Termplex.AppImage.part");
    defer alloc.free(part_path);
    const final_path = try tmp.dir.realpathAlloc(alloc, "Termplex.AppImage");
    defer alloc.free(final_path);

    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("payload", &expected, .{});

    try finalizeDownloadedPart(alloc, part_path, final_path, expected);
    try std.testing.expect((try tmp.dir.statFile("Termplex.AppImage")).kind == .file);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile("Termplex.AppImage.part"));
}

test "update_checker removes mismatched part file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "bad.part", .data = "payload" });
    const part_path = try tmp.dir.realpathAlloc(alloc, "bad.part");
    defer alloc.free(part_path);
    const final_path = try tmp.dir.realpathAlloc(alloc, "bad.AppImage");
    defer alloc.free(final_path);
    var wrong: [32]u8 = [_]u8{0} ** 32;
    try std.testing.expectError(error.ChecksumMismatch, finalizeDownloadedPart(alloc, part_path, final_path, wrong));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile("bad.part"));
}
```

- [ ] **Step 5: Run focused tests**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build test -Dtest-filter=update_checker
```

Expected: update checker unit tests pass.

- [ ] **Step 6: Commit detection/finalization**

```bash
git add src/termplex/core/update_checker.zig
git commit -m "feat: add appimage update finalization"
```

## Task 4: Add Manifest Fetch And AppImage Download

**Files:**

- Modify: `src/termplex/core/update_checker.zig`

- [ ] **Step 1: Add HTTPS fetch helper**

Add to `update_checker.zig`:

```zig
pub const FetchOptions = struct {
    max_bytes: usize = 2 * 1024 * 1024,
};

pub fn fetchHttps(allocator: std.mem.Allocator, url: []const u8, options: FetchOptions) ![]u8 {
    if (!std.mem.startsWith(u8, url, "https://")) return error.NonHttpsUrl;
    const uri = try std.Uri.parse(url);
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var header_buf: [16 * 1024]u8 = undefined;
    var req = try client.open(.GET, uri, .{ .server_header_buffer = &header_buf });
    defer req.deinit();
    req.headers.user_agent = .{ .override = "Termplex-Updater" };
    try req.send();
    try req.finish();
    try req.wait();
    if (req.response.status != .ok) return error.HttpStatusNotOk;
    return try req.reader().readAllAlloc(allocator, options.max_bytes);
}
```

If Zig 0.15.2's exact `std.http.Client` API differs during implementation, use `/opt/zig-x86_64-linux-0.15.2/lib/std/http/Client.zig` as the primary source and keep the public helper signature unchanged.

- [ ] **Step 2: Add download-to-part helper**

Add:

```zig
pub fn downloadAppImage(
    allocator: std.mem.Allocator,
    url: []const u8,
    update_dir: []const u8,
    filename: []const u8,
    expected_sha256: [32]u8,
) ![]u8 {
    if (std.mem.indexOfScalar(u8, filename, '/') != null or std.mem.indexOfScalar(u8, filename, '\\') != null) return error.InvalidFilename;
    if (!std.mem.endsWith(u8, filename, ".AppImage")) return error.InvalidFilename;
    try std.fs.cwd().makePath(update_dir);
    const final_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ update_dir, filename });
    errdefer allocator.free(final_path);
    const part_path = try std.fmt.allocPrint(allocator, "{s}.part", .{final_path});
    defer allocator.free(part_path);

    const bytes = try fetchHttps(allocator, url, .{ .max_bytes = 512 * 1024 * 1024 });
    defer allocator.free(bytes);
    {
        var file = try std.fs.createFileAbsolute(part_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(bytes);
    }
    try finalizeDownloadedPart(allocator, part_path, final_path, expected_sha256);
    return final_path;
}
```

- [ ] **Step 3: Add `.part` cleanup helper**

Add:

```zig
pub fn cleanupPartFiles(update_dir: []const u8) void {
    var dir = std.fs.cwd().openDir(update_dir, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".part")) {
            dir.deleteFile(entry.name) catch {};
        }
    }
}
```

- [ ] **Step 4: Add tests that avoid network**

For this task, unit-test URL rejection and `.part` cleanup only. Do not make public network calls in tests:

```zig
test "update_checker fetch rejects non-https before network" {
    try std.testing.expectError(error.NonHttpsUrl, fetchHttps(std.testing.allocator, "http://example.com/update.json", .{}));
}

test "update_checker cleans stale part files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.part", .data = "stale" });
    try tmp.dir.writeFile(.{ .sub_path = "keep.txt", .data = "keep" });
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);
    cleanupPartFiles(dir_path);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile("a.part"));
    try std.testing.expect((try tmp.dir.statFile("keep.txt")).kind == .file);
}
```

- [ ] **Step 5: Run focused tests and build**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build test -Dtest-filter=update_checker
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

Expected: tests and build pass.

- [ ] **Step 6: Commit fetch/download**

```bash
git add src/termplex/core/update_checker.zig
git commit -m "feat: add update download helpers"
```

## Task 5: Update Config Documentation And Release Manifest Tooling

**Files:**

- Modify: `src/config/Config.zig`
- Create: `tools/package/write-update-manifest.py`
- Modify: `tools/package/build-linux-packages.sh`

- [ ] **Step 1: Revise `auto-update` comments**

In `src/config/Config.zig`, replace the `auto-update` comment block with Linux-aware wording:

```zig
/// Control the auto-update notification behavior.
///
/// On Linux, Termplex checks a public release manifest client-side and compares
/// it with the current build version. Termplex does not upload workspace names,
/// project paths, command history, transcript data, environment variables, or
/// install paths as part of update checks. Standard network metadata such as
/// IP address and User-Agent is still visible to the update host.
///
/// Valid values are:
///
///  * `off` - Disable update checks.
///  * `check` - Check for updates and notify the user when an update is
///    available. Downloads only start after the user clicks Download.
///  * `download` - Same as `check` for Linux phase 1. This value is accepted
///    for compatibility, but Termplex still requires an explicit user click
///    before downloading an AppImage.
///
/// If unset, Linux defaults to checking only when the user explicitly invokes
/// Check for Updates. Future releases may add a startup check interval.
///
/// Changing this value at runtime works after a small delay.
```

Replace the `auto-update-channel` ending with:

```zig
/// On Linux, this selects the release manifest channel. Stable builds default
/// to `stable`; development builds may use `tip`.
```

- [ ] **Step 2: Add manifest writer script**

Create `tools/package/write-update-manifest.py`:

```python
#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib


def sha256(path):
    h = hashlib.sha256()
    with pathlib.Path(path).open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser(description="Write Termplex update manifest")
    parser.add_argument("--version", required=True)
    parser.add_argument("--channel", default="stable", choices=("stable", "tip"))
    parser.add_argument("--released-at", required=True)
    parser.add_argument("--notes-url", required=True)
    parser.add_argument("--asset", action="append", default=[], help="KEY=URL=PATH")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    downloads = {}
    for item in args.asset:
        key, url, path = item.split("=", 2)
        downloads[key] = {"url": url, "sha256": sha256(path)}

    payload = {
        "version": args.version,
        "channel": args.channel,
        "released_at": args.released_at,
        "notes_url": args.notes_url,
        "downloads": downloads,
    }
    pathlib.Path(args.output).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Make script executable and document package hook**

Run:

```bash
chmod +x tools/package/write-update-manifest.py
```

In `tools/package/build-linux-packages.sh`, after AppImage artifact creation, add a non-fatal manifest hint:

```bash
echo "==> Update manifest"
echo "Generate with tools/package/write-update-manifest.py after release URLs are known."
```

Do not guess release URLs inside the local packaging script.

- [ ] **Step 4: Run script smoke test**

```bash
tmpdir="$(mktemp -d)"
printf payload >"$tmpdir/Termplex-test-x86_64.AppImage"
tools/package/write-update-manifest.py \
  --version 1.6.0 \
  --channel stable \
  --released-at 2026-05-03T00:00:00Z \
  --notes-url https://github.com/termplex-org/termplex/releases/tag/v1.6.0 \
  --asset linux-x86_64-appimage=https://github.com/termplex-org/termplex/releases/download/v1.6.0/Termplex-test-x86_64.AppImage="$tmpdir/Termplex-test-x86_64.AppImage" \
  --output "$tmpdir/termplex-update.json"
python3 -m json.tool "$tmpdir/termplex-update.json" >/dev/null
rm -rf "$tmpdir"
```

Expected: command exits 0.

- [ ] **Step 5: Run config/build tests**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build test -Dtest-filter=auto-update
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

Expected: tests and build pass.

- [ ] **Step 6: Commit config/tooling**

```bash
git add src/config/Config.zig tools/package/write-update-manifest.py tools/package/build-linux-packages.sh
git commit -m "docs: update linux updater config guidance"
```

## Task 6: Wire GTK Application Action And Test IPC

**Files:**

- Modify: `src/apprt/gtk/class/application.zig`
- Modify: `tools/termplex-ctl`

- [ ] **Step 1: Add updater state fields to `Application.Private`**

In `src/apprt/gtk/class/application.zig`, add private fields:

```zig
        update_state: update_state.State = .{},
        update_paths: ?memory_paths.UpdatePaths = null,
        update_available_version: ?[:0]u8 = null,
        update_download_path: ?[:0]u8 = null,
        update_last_error: ?[:0]u8 = null,
```

Add imports near existing Termplex imports:

```zig
const update_manifest = @import("../../../termplex/core/update_manifest.zig");
const update_state = @import("../../../termplex/core/update_state.zig");
const update_checker = @import("../../../termplex/core/update_checker.zig");
const build_config = @import("../../../build_config.zig");
```

- [ ] **Step 2: Initialize and deinit updater state**

During application init, resolve paths and load state:

```zig
priv.update_paths = memory_paths.resolveUpdatePaths(std.heap.c_allocator) catch |err| paths: {
    log.warn("failed to resolve update paths: {}", .{err});
    break :paths null;
};
if (priv.update_paths) |paths| {
    priv.update_state = update_state.load(std.heap.c_allocator, paths.state_json) catch |err| state: {
        log.warn("failed to load update state: {}", .{err});
        break :state .{};
    };
}
```

During deinit, free updater fields:

```zig
priv.update_state.deinit(std.heap.c_allocator);
if (priv.update_paths) |*paths| paths.deinit(std.heap.c_allocator);
if (priv.update_available_version) |v| std.heap.c_allocator.free(v);
if (priv.update_download_path) |v| std.heap.c_allocator.free(v);
if (priv.update_last_error) |v| std.heap.c_allocator.free(v);
```

- [ ] **Step 3: Add testable update check helper**

Add helper methods inside `Application`:

```zig
fn updateManifestUrl(self: *Self) []const u8 {
    _ = self;
    return std.posix.getenv("TERMPLEX_UPDATE_MANIFEST_URL") orelse
        "https://github.com/termplex-org/termplex/releases/latest/download/termplex-update.json";
}

fn currentUpdateChannel(self: *Self) update_manifest.Channel {
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
```

Add `runUpdateCheckFromBytes`:

```zig
fn runUpdateCheckFromBytes(self: *Self, manifest_bytes: []const u8) void {
    const alloc = std.heap.c_allocator;
    const install_kind = blk: {
        var env = std.process.getEnvMap(alloc) catch break :blk update_state.InstallKind.unknown;
        defer env.deinit();
        break :blk update_checker.detectInstallKind(env);
    };
    const result = update_checker.evaluateManifest(
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

    switch (result) {
        .up_to_date => self.showUpdateToast("Termplex is up to date"),
        .available => |available| self.setUpdateAvailable(available.version_string, available.notes_url),
        .unavailable_for_install => |available| self.setUpdateUnavailable(available.version_string, available.notes_url),
    }
}
```

Implement `setUpdateError`, `setUpdateAvailable`, `setUpdateUnavailable`, and `showUpdateToast` with allocator-owned copies and all-window toast notifications.

- [ ] **Step 4: Implement `.check_for_updates` action**

In `performAction`, handle `.check_for_updates` before the unimplemented block:

```zig
            .check_for_updates => {
                self.checkForUpdates();
                return true;
            },
```

Add `checkForUpdates`:

```zig
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
    const bytes = update_checker.fetchHttps(alloc, url, .{}) catch |err| {
        self.setUpdateError(err);
        self.showUpdateToast("Update check failed");
        return;
    };
    defer alloc.free(bytes);
    self.runUpdateCheckFromBytes(bytes);
}
```

The `file://` branch is only for local E2E and manual testing. Manifest and download URLs inside the manifest must still be HTTPS.

- [ ] **Step 5: Add IPC status and manual check commands**

In `ipcDispatch`, add:

```zig
        if (std.mem.eql(u8, method, "update.status")) {
            return self.ipcUpdateStatus(alloc, id);
        }
        if (std.mem.eql(u8, method, "update.check")) {
            self.checkForUpdates();
            return std.fmt.allocPrint(alloc, "{{\"ok\":true,\"result\":{{\"checking\":true}},\"id\":{d}}}", .{id}) catch null;
        }
```

Add `ipcUpdateStatus` that returns JSON fields:

```json
{
  "available_version": "...",
  "download_path": "...",
  "last_error": "...",
  "install_kind": "appimage"
}
```

In `tools/termplex-ctl`, add:

```python
    update = subparsers.add_parser("update", help="Update operations")
    update_sub = update.add_subparsers(dest="action")
    update_sub.add_parser("status", help="Show update state")
    update_sub.add_parser("check", help="Check for updates")
```

And in `build_request`:

```python
    if resource == "update":
        if args.action == "status":
            return "update.status", {}
        if args.action == "check":
            return "update.check", {}
```

- [ ] **Step 6: Build and run E2E smoke**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
/opt/zig-x86_64-linux-0.15.2/zig build e2e -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

Expected: build and existing E2E pass.

- [ ] **Step 7: Commit GTK action and IPC**

```bash
git add src/apprt/gtk/class/application.zig tools/termplex-ctl
git commit -m "feat: wire update check action"
```

## Task 7: Add In-Window Update Affordance

**Files:**

- Modify: `src/apprt/gtk/ui/1.5/window.blp`
- Modify: `src/apprt/gtk/class/window.zig`
- Modify: `src/apprt/gtk/css/style.css`
- Modify: `src/apprt/gtk/css/style-dark.css`

- [ ] **Step 1: Add update revealer to window blueprint**

In `src/apprt/gtk/ui/1.5/window.blp`, inside the vertical `Box` above `Adw.ToastOverlay toast_overlay`, add:

```blueprint
        Revealer update_revealer {
          reveal-child: false;
          transition-type: slide_down;

          Box update_bar {
            styles ["termplex-update-bar"]
            orientation: horizontal;
            spacing: 8;

            Image {
              icon-name: "software-update-available-symbolic";
            }

            Label update_label {
              label: _("Update available");
              ellipsize: end;
              hexpand: true;
              xalign: 0;
            }

            Button update_primary_button {
              label: _("Download");
              clicked => $update_primary_clicked();
            }

            Button update_dismiss_button {
              icon-name: "window-close-symbolic";
              tooltip-text: _("Dismiss");
              clicked => $update_dismiss_clicked();
            }
          }
        }
```

- [ ] **Step 2: Bind template children and callbacks**

In `window.zig` private fields add:

```zig
        update_revealer: *gtk.Revealer,
        update_label: *gtk.Label,
        update_primary_button: *gtk.Button,
        update_dismiss_button: *gtk.Button,
```

Bind them in class init:

```zig
            class.bindTemplateChildPrivate("update_revealer", .{});
            class.bindTemplateChildPrivate("update_label", .{});
            class.bindTemplateChildPrivate("update_primary_button", .{});
            class.bindTemplateChildPrivate("update_dismiss_button", .{});
            class.bindTemplateCallback("update_primary_clicked", &updatePrimaryClicked);
            class.bindTemplateCallback("update_dismiss_clicked", &updateDismissClicked);
```

- [ ] **Step 3: Add public window update methods**

Add:

```zig
pub fn showUpdateAvailable(self: *Self, version: [:0]const u8, can_download: bool) void {
    const priv = self.private();
    var buf: [128]u8 = undefined;
    const label = std.fmt.bufPrintZ(&buf, "Termplex {s} is available", .{version}) catch "Update available";
    priv.update_label.setLabel(label);
    priv.update_primary_button.setLabel(if (can_download) "Download" else "Open Release");
    priv.update_revealer.setRevealChild(1);
}

pub fn showUpdateDownloaded(self: *Self, version: [:0]const u8) void {
    const priv = self.private();
    var buf: [128]u8 = undefined;
    const label = std.fmt.bufPrintZ(&buf, "Termplex {s} downloaded", .{version}) catch "Update downloaded";
    priv.update_label.setLabel(label);
    priv.update_primary_button.setLabel("Open Download");
    priv.update_revealer.setRevealChild(1);
}

pub fn hideUpdateBar(self: *Self) void {
    self.private().update_revealer.setRevealChild(0);
}
```

- [ ] **Step 4: Add callbacks**

Add callbacks:

```zig
fn updatePrimaryClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
    Application.default().handleUpdatePrimaryAction();
}

fn updateDismissClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
    self.hideUpdateBar();
    Application.default().dismissCurrentUpdate();
}
```

- [ ] **Step 5: Add CSS**

In `style.css` and `style-dark.css`, add:

```css
.termplex-update-bar {
  padding: 6px 10px;
  border-bottom: 1px solid alpha(@accent_color, 0.35);
  background: alpha(@accent_color, 0.10);
}

.termplex-update-bar button {
  min-height: 26px;
}
```

- [ ] **Step 6: Wire app state to windows**

In `application.zig`, add helper:

```zig
fn refreshUpdateBars(self: *Self) void {
    const priv = self.private();
    const list = self.as(gtk.Application).getWindows();
    list.foreach(struct {
        fn cb(data: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) void {
            const app: *Application = @ptrCast(@alignCast(userdata orelse return));
            const p = app.private();
            const ptr: *gtk.Window = @ptrCast(@alignCast(data orelse return));
            const win = gobject.ext.cast(Window, ptr) orelse return;
            if (p.update_download_path != null and p.update_available_version != null) {
                win.showUpdateDownloaded(p.update_available_version.?);
            } else if (p.update_available_version) |version| {
                win.showUpdateAvailable(version, p.update_state.install_kind == .appimage);
            } else {
                win.hideUpdateBar();
            }
        }
    }.cb, self);
    _ = priv;
}
```

Call `refreshUpdateBars()` after check, download, dismiss, and new window creation.

- [ ] **Step 7: Build with CSS resource refresh**

Because CSS is compiled through GResource, run:

```bash
rm -rf .zig-cache
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

Expected: build passes and resources compile.

- [ ] **Step 8: Commit update UI**

```bash
git add src/apprt/gtk/ui/1.5/window.blp src/apprt/gtk/class/window.zig src/apprt/gtk/css/style.css src/apprt/gtk/css/style-dark.css src/apprt/gtk/class/application.zig
git commit -m "feat: add update notification bar"
```

## Task 8: Add User-Triggered Download Action

**Files:**

- Modify: `src/apprt/gtk/class/application.zig`
- Modify: `src/termplex/core/update_checker.zig`

- [ ] **Step 1: Store selected download metadata in app state**

Add fields to `Application.Private`:

```zig
        update_download_url: ?[]u8 = null,
        update_download_filename: ?[]u8 = null,
        update_download_sha256: ?[32]u8 = null,
        update_notes_url: ?[]u8 = null,
```

Free these in deinit.

- [ ] **Step 2: Persist available update metadata**

In `setUpdateAvailable`, store version, notes URL, selected download URL/filename/sha256, install kind, and save `update-state.json`.

- [ ] **Step 3: Implement primary action**

Add:

```zig
pub fn handleUpdatePrimaryAction(self: *Self) void {
    const priv = self.private();
    if (priv.update_download_path) |path| {
        Action.openUrl(self, .{ .kind = .unknown, .url = path });
        return;
    }
    if (priv.update_state.install_kind != .appimage) {
        if (priv.update_notes_url) |url| Action.openUrl(self, .{ .kind = .html, .url = url });
        return;
    }
    self.downloadAvailableUpdate();
}
```

- [ ] **Step 4: Implement download action**

Add a small worker payload and run the download outside the GTK main thread. The worker must own duplicated copies of URL, filename, destination directory, and expected checksum, then post completion back to the main loop through `glib.idleAdd`.

```zig
const UpdateDownloadJob = struct {
    app: *Self,
    url: []u8,
    dest_dir: []u8,
    filename: []u8,
    sha256: [32]u8,

    fn deinit(self: *UpdateDownloadJob, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.dest_dir);
        allocator.free(self.filename);
    }
};

const UpdateDownloadResult = struct {
    app: *Self,
    path: ?[]u8 = null,
    err: ?anyerror = null,
};

fn downloadAvailableUpdate(self: *Self) void {
    // Duplicate all input state before spawning so later UI/state changes cannot
    // invalidate worker-thread memory. Set an in-progress status in persisted
    // update state before spawning.
}
```

Threading rules:

- `downloadAppImage` runs only on the worker thread.
- GTK/libadwaita widgets are touched only from the `glib.idleAdd` completion callback.
- While the worker is active, persist progress as `"downloading"` and disable the download button.
- On completion, persist either the verified `download_path` or a concise `last_error`, then call `refreshUpdateBars()`.
- Detach the thread after successful spawn. If spawning fails, restore the previous idle UI state and show the failure toast immediately.

- [ ] **Step 5: Add `update.download` IPC**

Add `update.download` branch to `ipcDispatch` and `tools/termplex-ctl`:

```python
    update_sub.add_parser("download", help="Download available AppImage update")
```

Map it to method `update.download`.

- [ ] **Step 6: Build and run E2E**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
/opt/zig-x86_64-linux-0.15.2/zig build e2e -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

Expected: build and existing E2E pass.

- [ ] **Step 7: Commit download action**

```bash
git add src/apprt/gtk/class/application.zig src/termplex/core/update_checker.zig tools/termplex-ctl
git commit -m "feat: download appimage updates"
```

## Task 9: Extend E2E Coverage For Update Flow

**Files:**

- Modify: `test/e2e/termplex_e2e.py`
- Modify: `test/e2e/README.md`

- [ ] **Step 1: Add local update fixture creation**

In `test/e2e/termplex_e2e.py`, add:

```python
def write_update_fixture(profile):
    appimage = profile / "artifacts" / "Termplex-9.9.9-x86_64.AppImage"
    appimage.write_bytes(b"termplex test appimage\n")
    import hashlib
    sha = hashlib.sha256(appimage.read_bytes()).hexdigest()
    manifest = profile / "artifacts" / "termplex-update.json"
    manifest.write_text(json.dumps({
        "version": "9.9.9",
        "channel": "stable",
        "released_at": "2026-05-03T00:00:00Z",
        "notes_url": "https://github.com/termplex-org/termplex/releases/tag/v9.9.9",
        "downloads": {
            "linux-x86_64-appimage": {
                "url": "https://github.com/termplex-org/termplex/releases/download/v9.9.9/Termplex-9.9.9-x86_64.AppImage",
                "sha256": sha,
            }
        },
    }))
    return manifest, appimage
```

- [ ] **Step 2: Add test transport override**

For E2E without network, add `TERMPLEX_UPDATE_MANIFEST_URL=file://...` and `TERMPLEX_UPDATE_DOWNLOAD_OVERRIDE=<fixture path>` to `profile_env`. Implement `TERMPLEX_UPDATE_DOWNLOAD_OVERRIDE` in `update_checker.downloadAppImage` so tests can copy bytes from a local file while still requiring the manifest URL to be HTTPS.

Implementation rule:

- Only accept `TERMPLEX_UPDATE_DOWNLOAD_OVERRIDE` when `TERMPLEX_E2E=1` is set.
- Production downloads always use the HTTPS URL.

- [ ] **Step 3: Add update scenario**

In `run_scenario`, after initial app readiness:

```python
ctl(args, env, "update", "check")
wait_until(
    "update available",
    args.timeout,
    lambda: ctl(args, env, "update", "status").get("available_version") == "9.9.9",
)
ctl(args, env, "update", "download")
status = wait_until(
    "update downloaded",
    args.timeout,
    lambda: ctl(args, env, "update", "status") if ctl(args, env, "update", "status").get("download_path") else None,
)
download_path = pathlib.Path(status["download_path"])
if not download_path.exists():
    raise E2EError("downloaded AppImage missing: {}".format(download_path))
if not os.access(download_path, os.X_OK):
    raise E2EError("downloaded AppImage is not executable: {}".format(download_path))
```

- [ ] **Step 4: Update README**

In `test/e2e/README.md`, document that the E2E update test uses local fixture overrides and does not require network access.

- [ ] **Step 5: Run E2E**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build e2e -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell -- --keep-artifacts
xvfb-run -a /opt/zig-x86_64-linux-0.15.2/zig build e2e -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

Expected: both E2E runs pass.

- [ ] **Step 6: Commit E2E update coverage**

```bash
git add test/e2e/termplex_e2e.py test/e2e/README.md src/termplex/core/update_checker.zig
git commit -m "test: cover appimage update flow e2e"
```

## Task 10: Final Verification

**Files:**

- All files touched by Tasks 1-9

- [ ] **Step 1: Run formatting**

```bash
/opt/zig-x86_64-linux-0.15.2/zig fmt src/termplex/core/update_manifest.zig src/termplex/core/update_state.zig src/termplex/core/update_checker.zig src/termplex/core/memory/paths.zig src/config/Config.zig src/apprt/gtk/class/application.zig src/apprt/gtk/class/window.zig
```

Expected: command exits 0.

- [ ] **Step 2: Run Python syntax checks**

```bash
python3 -m py_compile test/e2e/termplex_e2e.py tools/package/write-update-manifest.py
```

Expected: command exits 0.

- [ ] **Step 3: Run unit tests**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell
```

Expected:

- Command exits 0.
- Existing warning output from negative terminal/parser/config tests is acceptable.

- [ ] **Step 4: Run normal build**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

Expected: command exits 0.

- [ ] **Step 5: Run real-app E2E**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build e2e -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

Expected: command exits 0.

- [ ] **Step 6: Run headless E2E**

```bash
xvfb-run -a /opt/zig-x86_64-linux-0.15.2/zig build e2e -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

Expected: command exits 0.

- [ ] **Step 7: Run release build**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell -Doptimize=ReleaseFast
```

Expected: command exits 0.

- [ ] **Step 8: Commit any final cleanup**

If verification required cleanup changes:

```bash
git status --short
git add src/termplex/core/update_manifest.zig src/termplex/core/update_state.zig src/termplex/core/update_checker.zig src/termplex/core/memory/paths.zig src/config/Config.zig src/apprt/gtk/class/application.zig src/apprt/gtk/class/window.zig src/apprt/gtk/ui/1.5/window.blp src/apprt/gtk/css/style.css src/apprt/gtk/css/style-dark.css src/main.zig tools/termplex-ctl test/e2e/termplex_e2e.py test/e2e/README.md tools/package/build-linux-packages.sh tools/package/write-update-manifest.py
git commit -m "fix: harden appimage update flow"
```

Expected: final `git status --short` is clean.

## Self-Review

- Spec coverage: Covers version policy, client-side manifest check, AppImage detection through `APPIMAGE`, explicit user-triggered download, XDG update storage, `.part` downloads, SHA-256 verification, executable bit, atomic rename, no silent install, non-AppImage fallback, update UI, command-palette action, persisted state, and E2E coverage.
- Placeholder scan: No `TBD`, `TODO`, "implement later", or unconstrained "add tests" placeholders remain. Generic final commit handling is limited to an explicit `git status --short` review plus a concrete list of expected touched files.
- Type consistency: Core modules use `update_manifest.Manifest`, `update_state.State`, and `update_checker.CheckResult` consistently across tasks. App integration imports these modules before using their types.
- Scope check: The plan intentionally defers auto-restart, binary replacement, background auto-update, delta updates, package-manager self-update, hunk-level git work, and history UI. This keeps the phase focused on AppImage update awareness and explicit download.
