<h1>
<p align="center">
  ⚡ Termplex
</h1>
  <p align="center">
    Workspace-centric terminal multiplexer for Linux.
    <br />
    <a href="#features">Features</a>
    ·
    <a href="#installation">Installation</a>
    ·
    <a href="#building-from-source">Build</a>
    ·
    <a href="#configuration">Configuration</a>
  </p>
</p>

## About

Termplex is a workspace-centric terminal multiplexer built on GTK4 and libadwaita. It lets you organize terminal sessions into named workspaces — each with its own tabs, splits, and working directory — and switch between them instantly from a persistent sidebar.

Built on the [Ghostty](https://github.com/ghostty-org/ghostty) terminal core, Termplex inherits a fast, standards-compliant terminal emulator with GPU-accelerated rendering and full modern terminal feature support, then adds workspace management on top.

## Features

- **Workspaces** — Create, name, and switch between independent workspace groups. Each workspace maintains its own set of tabs and splits.
- **Persistent sidebar** — Always-visible workspace list with active/unread indicators, toggle with a keyboard shortcut.
- **Session persistence** — Workspaces, tabs, and tab names are saved and restored across restarts.
- **Tab overview** — Grid view of all tabs in the current workspace. Stays open across workspace switches.
- **Electric Cyan brand** — Dark-native UI theme with `#00d4ff` accent, designed for focused terminal work.
- **Splits** — Horizontal and vertical pane splitting within any tab.
- **GPU rendering** — OpenGL-based renderer for smooth, high-performance output.
- **Full terminal compatibility** — Standards-compliant VT emulation, works with all shells and TUI applications.
- **Configurable** — Extensive configuration options for fonts, colors, keybindings, and behavior.

## Screenshots

<!-- TODO: Add screenshots -->

## Installation

### Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/abdokhaire/termplex/main/install.sh | bash
```

### AppImage (no install needed)

Download `Termplex-x86_64.AppImage` from [Releases](https://github.com/abdokhaire/termplex/releases), then:

```bash
chmod +x Termplex-x86_64.AppImage
./Termplex-x86_64.AppImage
```

### Debian / Ubuntu (.deb)

```bash
# Install dependencies
sudo apt install libgtk-4-1 libadwaita-1-0

# Download and install
wget https://github.com/abdokhaire/termplex/releases/download/v0.1.0/termplex_0.1.0_amd64.deb
sudo dpkg -i termplex_0.1.0_amd64.deb

# Run
termplex-app
```

### Tarball

```bash
wget https://github.com/abdokhaire/termplex/releases/download/v0.1.0/termplex-0.1.0-linux-x86_64.tar.gz
tar xzf termplex-0.1.0-linux-x86_64.tar.gz
cd termplex-0.1.0-linux-x86_64
./bin/termplex-app
```

### Building from Source

**Requirements:**
- [Zig 0.15.2](https://ziglang.org/download/) (exact version required)
- GTK4 4.14+
- libadwaita 1.5+

**Install build dependencies:**

```bash
# Ubuntu/Debian
sudo apt install libgtk-4-dev libadwaita-1-dev

# Fedora
sudo dnf install gtk4-devel libadwaita-devel

# Arch Linux
sudo pacman -S gtk4 libadwaita
```

**Build and run:**

```bash
# Release build (optimized)
zig build -Dapp-runtime=gtk -Doptimize=ReleaseFast

# Run
./zig-out/bin/termplex-app
```

> **Note:** If `gtk4-layer-shell` is not installed, add `-fno-sys=gtk4-layer-shell` to the build command.

## Configuration

Configuration is read from `~/.config/termplex/config.termplex`.

### Key Defaults

| Setting | Default | Description |
|---------|---------|-------------|
| `background` | `#0f1923` | Dark navy terminal background |
| `foreground` | `#e2e8f0` | Light gray text |
| `window-theme` | `dark` | Forces dark mode for brand consistency |

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Ctrl+Shift+T` | New tab |
| `Ctrl+Shift+N` | New window |
| `Ctrl+Shift+W` | Close tab |

> Full keybinding configuration is available through the config file.

## Architecture

Termplex is a fork of [Ghostty](https://github.com/ghostty-org/ghostty) with a workspace management layer. The core terminal emulation (VT parsing, rendering, IO) comes from Ghostty's battle-tested implementation. Termplex adds:

- Workspace data model and lifecycle management
- Sidebar UI with workspace list and indicators
- Session persistence (save/restore workspaces, tabs, titles)
- Deferred workspace switching for smooth tab overview transitions
- Electric Cyan dark theme

**Tech stack:**
- **Language:** Zig 0.15.2
- **UI toolkit:** GTK4 + libadwaita
- **Renderer:** OpenGL
- **Platform:** Linux (X11 and Wayland)

## Contributing

Contributions are welcome. Please open an issue first to discuss what you'd like to change.

## Acknowledgments

Termplex is built on top of [Ghostty](https://github.com/ghostty-org/ghostty) by Mitchell Hashimoto. The terminal emulation core, rendering engine, and configuration system are inherited from Ghostty's excellent work.

## License

[MIT](LICENSE)
