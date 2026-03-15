# Developing Termplex

This document describes the technical details behind Termplex's development.
If you'd like to contribute, please read ["Contributing to Termplex"](CONTRIBUTING.md) first.

## Getting Started

Clone the repository and build:

```shell
git clone https://github.com/abdokhaire/termplex
cd termplex
```

### Requirements

- [Zig 0.15.2](https://ziglang.org/download/) (exact version required)
- GTK4 4.14+ development headers
- libadwaita 1.5+ development headers
- `blueprint-compiler` 0.16.0+ (when building from Git checkout)

**Install on Ubuntu/Debian:**

```bash
sudo apt install libgtk-4-dev libadwaita-1-dev blueprint-compiler
```

**Install on Fedora:**

```bash
sudo dnf install gtk4-devel libadwaita-devel blueprint-compiler
```

**Install on Arch:**

```bash
sudo pacman -S gtk4 libadwaita blueprint-compiler
```

### Build Commands

| Command | Description |
|---------|-------------|
| `zig build -Dapp-runtime=gtk` | Debug build (default) |
| `zig build -Dapp-runtime=gtk -Doptimize=ReleaseFast` | Release build (optimized) |
| `zig build run` | Build and run |
| `zig build test` | Run unit tests |
| `zig build test -Dtest-filter=<filter>` | Run filtered tests |

> **Note:** Add `-fno-sys=gtk4-layer-shell` if `gtk4-layer-shell` is not installed.

When developing, use a **debug build** (no `-Doptimize` flag) — it's the default and makes diagnosing issues much easier.

### Clean Build

CSS files and GResources are compiled into the binary. If you change CSS or resource files and don't see your changes, do a clean build:

```bash
rm -rf .zig-cache zig-out
zig build -Dapp-runtime=gtk
```

## Project Structure

```
src/
├── apprt/gtk/           # GTK4 app runtime
│   ├── class/           # Widget classes (application, window, sidebar, workspace_tab, surface)
│   ├── css/             # Stylesheets (compiled into binary via GResource)
│   ├── build/           # GResource compilation
│   └── ui/              # Blueprint UI templates
├── termplex/            # Termplex-specific code
│   └── core/            # Workspace config, session persistence
├── config/              # Configuration system
├── terminal/            # Terminal emulation (VT parser, screen, pages)
├── renderer/            # OpenGL renderer
├── font/                # Font loading and shaping
├── build/               # Build system modules
├── shell-integration/   # Shell scripts (bash, zsh, fish, elvish, nushell)
└── input/               # Keyboard/mouse input handling
```

### Key Files

| File | Purpose |
|------|---------|
| `src/apprt/gtk/class/application.zig` | App lifecycle, workspace management, session save/restore |
| `src/apprt/gtk/class/window.zig` | Window UI, tab overview, workspace switching |
| `src/apprt/gtk/class/sidebar.zig` | Sidebar widget with workspace list |
| `src/apprt/gtk/css/style.css` | Main CSS (Electric Cyan brand) |
| `src/config/Config.zig` | Configuration options and parsing |
| `src/termplex/core/config.zig` | Termplex workspace config |
| `build.zig` | Build system entry point |

## AI and Agents

Termplex provides a [CLAUDE.md](CLAUDE.md) file (also symlinked as `AGENTS.md`) for AI coding assistants with build commands, project structure, and conventions.

## Logging

Termplex writes logs to `stderr` by default. On Linux with systemd:

```bash
journalctl --user --unit app-com.termplex.app.service
```

Control logging with the `TERMPLEX_LOG` environment variable:

| Value | Effect |
|-------|--------|
| `true` | Enable all log destinations |
| `false` | Disable all logging |
| `stderr` | Log to stderr only |

Debug builds output debug-level logs automatically. Release builds only output warnings and errors.

## Linting

### Zig

```bash
zig fmt .
```

### Prettier (docs, configs)

```bash
prettier --write .
```

### ShellCheck (bash scripts)

```bash
shellcheck --check-sourced --severity=warning \
    $(find . \( -name "*.sh" -o -name "*.bash" \) -type f ! -path "./zig-out/*" ! -path "./.git/*" | sort)
```

## Checking for Memory Leaks

Termplex uses C libraries under the hood. Use Valgrind to check for leaks:

```bash
zig build run-valgrind
```

This builds with Valgrind support and runs with suppression rules for known false positives.

## Architecture Notes

### Workspace System

- **App-level state** (`application.zig`): manages workspace list, `AdwTabView` per workspace, session persistence (JSON v3 format)
- **Window-level UI** (`window.zig`): handles sidebar toggle, tab overview, deferred workspace switching (400ms timer for `AdwTabOverview` close animation)
- **Sidebar** (`sidebar.zig`): GTK `ListBox` with workspace rows, right-click context menu

### CSS / Theming

- CSS is compiled into the binary via GResource — not loaded from disk at runtime
- Brand palette: primary `#00d4ff`, backgrounds `#0f1923` → `#131d2b` → `#1a2736` → `#243447`
- Dark mode is forced in `startupStyleManager`
- Changes to CSS require cleaning `.zig-cache` before rebuild

### Session Persistence

Sessions are auto-saved to `~/.local/state/termplex/session.json` in v3 format:

```json
{
  "version": 3,
  "workspaces": [
    {
      "name": "dev",
      "dir": "/home/user/projects",
      "tabs": [{"title": "editor"}, {"title": "server"}]
    }
  ],
  "active_workspace": 0
}
```

## Release Process

1. Build release binary:
   ```bash
   zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell -Doptimize=ReleaseFast
   ```
2. Create packages (tarball, AppImage, .deb)
3. Tag and push: `git tag vX.Y.Z && git push origin vX.Y.Z`
4. Create GitHub release: `gh release create vX.Y.Z <assets>`

See the [README](README.md) for user-facing installation instructions.
