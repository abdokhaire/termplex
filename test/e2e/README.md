# Termplex E2E Tests

This directory contains real GTK application E2E smoke tests.

The harness launches `termplex-app` with disposable XDG directories, drives it through `termplex-ctl`, and verifies IPC, workspace/tab behavior, terminal I/O, SQLite history rows, transcript files, session restore, transcript restore, workspace cleanup, and agent registry flows.

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
