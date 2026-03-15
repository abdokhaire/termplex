# Termplex Development Guide

## Project Overview

Termplex is a workspace-centric terminal multiplexer for Linux, forked from [Ghostty](https://github.com/ghostty-org/ghostty). It adds workspace management (sidebar, session persistence, tab overview integration) on top of Ghostty's terminal emulation core.

**Tech stack:** Zig 0.15.2 · GTK4 + libadwaita · OpenGL · Linux (X11/Wayland)

## Commands

- **Build:** `/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell`
- **Release build:** `/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell -Doptimize=ReleaseFast`
- **Test:** `/opt/zig-x86_64-linux-0.15.2/zig build test`
- **Test (filtered):** `/opt/zig-x86_64-linux-0.15.2/zig build test -Dtest-filter=<test name>`
- **Format:** `/opt/zig-x86_64-linux-0.15.2/zig fmt .`
- **Run:** `./zig-out/bin/termplex-app`
- **Clean build:** `rm -rf .zig-cache zig-out`

## Directory Structure

- `src/` — Shared Zig core (terminal emulation, config, rendering)
- `src/apprt/gtk/` — GTK4 app runtime (windows, tabs, sidebar, surfaces)
- `src/apprt/gtk/class/` — GTK widget classes (application, window, sidebar, workspace_tab)
- `src/apprt/gtk/css/` — CSS styles (style.css, style-dark.css) — compiled into binary via GResource
- `src/config/` — Configuration loading and parsing
- `src/termplex/` — Termplex-specific code (workspace config, session persistence)
- `src/build/` — Build system modules (TermplexLib, TermplexExe, TermplexResources, etc.)
- `src/shell-integration/` — Shell integration scripts (bash, zsh, fish, elvish, nushell)
- `dist/linux/` — Desktop files, D-Bus/systemd services, file manager integrations
- `flatpak/` — Flatpak packaging configs
- `snap/` — Snap packaging config
- `macos/` — macOS app (inherited from Ghostty, not actively used)

## Key Architecture

- **App ID:** `com.termplex.app`
- **Binary:** `termplex-app`
- **Config path:** `~/.config/termplex/config.termplex`
- **State path:** `~/.local/state/termplex/`
- **Cache path:** `~/.cache/termplex/`
- **Env var prefix:** `TERMPLEX_`

### Workspace System

- Workspaces are managed in `src/apprt/gtk/class/application.zig` (app-level state) and `src/apprt/gtk/class/window.zig` (window-level UI)
- Sidebar widget: `src/apprt/gtk/class/sidebar.zig`
- Session persistence: saves/restores as JSON v3 format in `autosaveSession`/`restoreSession`
- Tab overview (AdwTabOverview) requires 400ms animation delay when switching workspaces

### CSS / Theming

- CSS files in `src/apprt/gtk/css/` are compiled into the binary via GResource (`src/apprt/gtk/build/gresource.zig`)
- Changes to CSS require `rm -rf .zig-cache` to take effect
- Brand: Electric Cyan — primary `#00d4ff`, backgrounds `#0f1923`→`#131d2b`→`#1a2736`→`#243447`
- Dark mode is forced via `style.setColorScheme(.force_dark)`

## Coding Conventions

- Follow existing Zig patterns in the codebase
- Use `std.log.scoped` for logging with appropriate scopes
- GTK callbacks use `callconv(.c)` for C-compatible function signatures
- GLib memory: use `glib.timeoutAdd` for deferred operations, not sleep
- Error handling: use Zig error unions, log errors with context
- Keep changes minimal and focused — don't refactor unrelated code

## Release Process

1. Build release: `zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell -Doptimize=ReleaseFast`
2. Create packages: tarball, AppImage, .deb
3. Tag: `git tag vX.Y.Z && git push origin vX.Y.Z`
4. Release: `gh release create vX.Y.Z <assets> --title "Termplex vX.Y.Z"`
