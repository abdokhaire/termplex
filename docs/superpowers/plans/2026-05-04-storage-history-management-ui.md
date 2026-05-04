# Storage And History Management UI

**Goal:** Add a local-first storage and history management surface that shows what Termplex stores and provides focused cleanup actions for terminal, workspace, and project history.

**Architecture:** Add a small storage accounting service that scans Termplex terminal-history state on disk and combines it with SQLite row counts. Reuse the existing transcript and SQLite cleanup primitives for clear/delete actions, expose them through IPC and `termplex-ctl`, then add a compact libadwaita dialog reachable from the main menu and IPC.

**Tech Stack:** Zig 0.15.2, GTK4/libadwaita, existing Termplex IPC socket, SQLite metadata in `terminal_history_db.zig`, transcript files in `$XDG_STATE_HOME/termplex/terminal-history`, Python E2E harness.

## Scope

Phase 1 includes:

- Show approximate storage usage for the terminal-history directory.
- Show SQLite database size and transcript file size separately.
- Show command/surface/project row counts from SQLite.
- Show effective terminal-history settings: enabled, restore mode, retention days, max lines, max bytes, alternate-screen persistence, replay notice.
- Clear the active or specified terminal history.
- Clear the active or specified workspace history while keeping the workspace available.
- Delete the active or specified project/workspace through the existing workspace close path, so SQLite rows plus transcript files are removed.
- Add local-persistence text in the dialog.
- Add CLI/E2E coverage for status, clear terminal, clear workspace, delete project, and dialog presentation.

Phase 1 explicitly defers:

- Per-command deletion.
- Secret scanning.
- Cloud backup or sync controls.
- Editing retention settings from this dialog.
- Complex retention policy editors.
- Destructive confirmation redesign beyond existing workspace close safeguards.

## Files

- Add `src/termplex/core/storage_status.zig`: recursive size accounting, byte formatting, unit tests.
- Modify `src/termplex/main.zig` and `src/main.zig`: export/import the new core module for builds and tests.
- Modify `src/termplex/core/terminal_history_db.zig`: add row-count helpers.
- Modify `src/apprt/gtk/class/application.zig`: add storage summary and cleanup APIs plus IPC handlers.
- Add `src/apprt/gtk/class/storage_management_dialog.zig`: compact storage/history dialog.
- Add `src/apprt/gtk/ui/1.5/storage-management-dialog.blp`: dialog UI.
- Modify `src/apprt/gtk/build/gresource.zig`: include new blueprint.
- Modify `src/apprt/gtk/class/window.zig`: action, dialog weak ref, menu wiring.
- Modify `src/apprt/gtk/ui/1.5/window.blp`: add "Storage And History..." menu item.
- Modify `tools/termplex-ctl`: add `storage status`, `storage show`, `storage clear-terminal`, `storage clear-workspace`, and `storage delete-project`.
- Modify `test/e2e/termplex_e2e.py`: exercise storage status and cleanup workflows in disposable workspaces.
- Modify `test/e2e/README.md`: mention storage/history management coverage.

## API Shape

IPC methods:

- `storage.status` returns `{ history_enabled, restore_mode, retention_days, max_lines_per_surface, max_bytes_per_surface, persist_alternate_screen, replay_notice, base_path, db_path, total_bytes, transcript_bytes, db_bytes, transcript_file_count, project_count, surface_count, command_count }`.
- `storage.clear_terminal` with optional `{ "workspace": <name|index>, "tab": <index> }` clears that terminal transcript and SQLite surface/command rows.
- `storage.clear_workspace` with optional `{ "workspace": <name|index> }` clears that workspace transcript directory and SQLite surface/command rows, then re-upserts the live project row.
- `storage.delete_project` with optional `{ "workspace": <name|index> }` closes/deletes the workspace when allowed, reusing the existing project deletion path.
- `storage.show` presents the storage dialog and returns `{ shown: true }`.

CLI commands mirror IPC:

- `termplex-ctl storage status`
- `termplex-ctl storage show`
- `termplex-ctl storage clear-terminal [--workspace <name|index>] [--tab <index>]`
- `termplex-ctl storage clear-workspace [--workspace <name|index>]`
- `termplex-ctl storage delete-project [--workspace <name|index>]`

## Implementation Steps

- [x] Add failing unit tests for recursive storage accounting and byte formatting.
- [x] Add failing unit tests for SQLite row-count helpers.
- [x] Add failing E2E assertions for `termplex-ctl storage status` after history rows and transcript files exist.
- [x] Add failing E2E assertions for clear-terminal, clear-workspace, delete-project, and storage dialog presentation.
- [x] Implement `storage_status.zig`.
- [x] Export and import the storage module.
- [x] Implement SQLite row-count helpers.
- [x] Add application storage summary and cleanup methods.
- [x] Add `storage.*` IPC handlers.
- [x] Add `tools/termplex-ctl storage ...` commands.
- [x] Add the storage management dialog and menu action.
- [x] Run formatting, unit tests, GTK build, and E2E.
- [x] Commit with a focused message such as `feat: add storage history management`.

## Security And Privacy Requirements

- Keep all storage/accounting data local.
- Do not upload transcript paths, command history, workspace paths, git data, file names, or storage stats.
- The UI may show local paths and approximate sizes because Termplex is a developer productivity tool.
- Clear/delete actions must reuse central transcript and SQLite deletion paths so lifecycle behavior stays consistent.
- Do not add hidden retention changes; this phase shows settings and explicit cleanup actions only.

## Verification

- `python3 -m py_compile test/e2e/termplex_e2e.py tools/termplex-ctl`
- `/opt/zig-x86_64-linux-0.15.2/zig fmt .`
- `/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell`
- `/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell`
- `/opt/zig-x86_64-linux-0.15.2/zig build e2e -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell`
