# Background Tab Hydration Implementation Plan

Date: 2026-05-05

## Goal

Defer restored transcript replay for background workspaces until the restored surface initializes, while preserving session restore layout, history IDs, transcript search, and terminal-history cleanup behavior.

## Final Direction

Move restored transcript replay loading out of `Window.buildRestoredSurfaceTree()` and into `Surface.initSurface()`. Restored surfaces keep the original workspace ID and history ID at construction time, but transcript bytes are read only when the GTK surface initializes.

This phase keeps shell startup behavior unchanged. It does not introduce placeholder-only tabs or lazy process startup.

## Scope

Phase 1 includes:

- Preserve restored `history_id`, working directory, title, tab, split, and workspace identity.
- Avoid transcript file reads while rebuilding restored tab/split trees.
- Load restored transcript bytes lazily during surface initialization.
- Use the restored workspace ID for transcript path resolution.
- Prove with E2E coverage that a background workspace does not hydrate during startup and hydrates after selecting/focusing its restored tab.
- Keep transcript replay on the existing frontend-only replay path.
- Keep IPC-created active tabs usable even when GTK realizes a `GLArea` before allocating it.

Phase 1 defers:

- Lazy shell process startup.
- Placeholder-only background tabs.
- Hydration queues or progress UI.
- Configurable hydration policy.
- Background transcript prefetch.

## File Map

- `test/e2e/termplex_e2e.py`: add the lazy background workspace fixture and hydration assertions.
- `tools/termplex-ctl`: add `surface focus` so E2E can select a specific restored tab without relying on transcript-read fallback behavior.
- `src/apprt/gtk/class/surface.zig`: store restored workspace IDs, load deferred transcript replay at surface init, and initialize active IPC/focused surfaces from allocation/root fallback size when GTK has not emitted an initial resize.
- `src/apprt/gtk/class/window.zig`: stop eager transcript reads during restored surface-tree construction.
- `src/apprt/gtk/class/application.zig`: call the surface initialization fallback before IPC send, and make workspace-history clear recreate SQLite project state deterministically.
- `docs/superpowers/plans/2026-05-03-termplex-roadmap-implementation-sequence.md`: mark this phase complete.

## Tasks

- [x] Add E2E coverage for lazy background hydration.
- [x] Verify RED: E2E failed because no deferred replay hydration log existed before implementation.
- [x] Store restored workspace identity on `Surface`.
- [x] Free restored workspace identity in surface finalization.
- [x] Load deferred transcript replay inside `Surface.initSurface()`.
- [x] Remove eager transcript reads from `Window.buildRestoredSurfaceTree()`.
- [x] Pass restored workspace ID into restored surfaces.
- [x] Add `termplex-ctl surface focus`.
- [x] Focus the restored lazy tab before asserting hydration, so `surface.read` transcript fallback cannot mask hydration timing.
- [x] Fix the workspace-history clear path by committing deletion and reopening/relinking the terminal-history database before recreating project metadata.
- [x] Fix GTK no-initial-resize behavior for active IPC/focused surfaces by initializing from current allocation, estimated/default size, root-window size, or final 800x600 fallback.
- [x] Update roadmap status.

## Verification

Required commands:

```bash
python3 -m py_compile test/e2e/termplex_e2e.py tools/termplex-ctl
/opt/zig-x86_64-linux-0.15.2/zig fmt src/apprt/gtk/class/surface.zig src/apprt/gtk/class/window.zig src/apprt/gtk/class/application.zig
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
/opt/zig-x86_64-linux-0.15.2/zig build e2e -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell
git diff --check
git diff --cached --check
```

Expected: all commands exit 0. Existing warning/debug output from parser or terminal tests is acceptable only when the command exits 0.

Note: plain `/opt/zig-x86_64-linux-0.15.2/zig build test` requires a system `gtk4-layer-shell-0` library on this machine. Use `-fno-sys=gtk4-layer-shell` for the local vendored-library test path, matching the app and E2E build commands.
