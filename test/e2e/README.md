# Termplex E2E Tests

This directory contains real GTK application E2E smoke tests.

The harness launches `termplex-app` with disposable XDG directories, drives it through `termplex-ctl`, and verifies IPC, workspace/tab behavior, terminal I/O, SQLite history rows, transcript files, session restore, transcript restore, workspace dashboard status/presentation, diagnostics bundle export, storage/history management cleanup, workspace cleanup, agent registry flows, source-control status/diff/stage/unstage/commit flows, and the AppImage update check/download flow.

The update scenario uses local fixture files only. It points `TERMPLEX_UPDATE_MANIFEST_URL` at a generated `file://` manifest, simulates AppImage mode with `APPIMAGE`, and gates `TERMPLEX_UPDATE_DOWNLOAD_OVERRIDE` behind `TERMPLEX_E2E=1`, so E2E update coverage does not require public network access.

## Run From A Graphical Session

```bash
/opt/zig-x86_64-linux-0.15.2/zig build e2e -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

## Run Headlessly

```bash
xvfb-run -a /opt/zig-x86_64-linux-0.15.2/zig build e2e -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

## Keep Artifacts

```bash
/opt/zig-x86_64-linux-0.15.2/zig build e2e -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell -- --keep-artifacts
```

Artifacts include the disposable profile, app log, config, state, SQLite database, session file, memory state, and transcript files.

The harness never uses the user's real `~/.config/termplex`, `~/.local/state/termplex`, or `~/.cache/termplex`.
