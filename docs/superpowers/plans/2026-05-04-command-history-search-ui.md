# Command History Search UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a compact, local-first command history search surface backed by SQLite, with copy and rerun actions.

**Architecture:** Extend `terminal_history_db.zig` with a filtered search query that returns command metadata from `command_history`. Expose the same query through GTK application IPC and `tools/termplex-ctl`, then use a small libadwaita dialog in the main window to search the active workspace and perform copy/rerun actions against the active terminal.

**Tech Stack:** Zig 0.15.2, GTK4/libadwaita Blueprint templates, SQLite via dynamic `libsqlite3`, JSON IPC over Unix sockets, Python stdlib E2E runner.

---

## Scope

Phase 1 includes:

- Search command text in the current workspace by default.
- Optional CLI filters for workspace, cwd/project dir, exit code/status, source, and time range.
- Return structured metadata: command, workspace, cwd/project dir, timestamps, exit code, source, and row ID.
- Copy command text from the UI to the standard clipboard.
- Rerun command text in the active terminal by writing `command + "\n"` to the active PTY.
- E2E coverage proving a persisted command can be searched through IPC/CLI and rerun.

Phase 1 defers:

- Full transcript body search.
- Saved searches and analytics.
- Cross-workspace browsing UI beyond CLI/API filters.
- Secret redaction workflows; Termplex remains a local developer tool and shows local persisted history.

## File Map

- Modify `src/termplex/core/terminal_history_db.zig`: add `SearchQuery`, filtered SQL query, cwd/project dir output, and unit tests.
- Modify `src/apprt/gtk/class/application.zig`: add `history.search` IPC handler and JSON serialization.
- Modify `tools/termplex-ctl`: add `history search` CLI command and filters.
- Create `src/apprt/gtk/class/command_history_dialog.zig`: GTK dialog object for command history search, row object, copy/rerun signals.
- Create `src/apprt/gtk/ui/1.5/command-history-dialog.blp`: compact dialog template with search field and rich list rows.
- Modify `src/apprt/gtk/build/gresource.zig`: include the new Blueprint.
- Modify `src/apprt/gtk/class/window.zig`: add `win.termplex-command-history`, menu entry, dialog presentation, copy/rerun handlers.
- Modify `src/apprt/gtk/ui/1.5/window.blp`: add "Command History..." to the main menu.
- Modify `test/e2e/termplex_e2e.py`: assert history search and rerun behavior.
- Modify `src/main.zig` only if the new GTK class needs a test/import anchor; keep module discovery local if possible.

## Tasks

### Task 1: Add SQLite Search API

- [x] Add a failing unit test in `terminal_history_db.zig` that inserts multiple commands across workspaces/sources/exit codes and verifies search text, workspace, source, exit code, and limit filters.
- [x] Implement `SearchQuery` with fields: `text`, `workspace_id`, `workspace_name`, `workspace_dir`, `source`, `exit_code`, `started_after`, `started_before`, `limit`.
- [x] Add `searchCommands` using parameterized SQL only. Match command text with `LIKE '%' || ? || '%'`; keep ordering by `started_at DESC, id DESC`.
- [x] Include `workspace_dir` as the cwd/project-dir field for phase 1 because command rows currently persist workspace directory but not per-command cwd.
- [x] Run filtered unit test and then full `zig build test`.

### Task 2: Add IPC/CLI Search Surface

- [x] Add a failing E2E assertion that `tools/termplex-ctl history search --query <command>` returns the command created by OSC markers.
- [x] Add `history search` CLI flags: `--query`, `--workspace`, `--dir`, `--source`, `--exit-code`, `--started-after`, `--started-before`, `--limit`.
- [x] Add `history.search` dispatch in `application.zig`, validate params, clamp limit to `1..200`, and serialize rows with correct JSON escaping.
- [x] Prefer current active workspace when the request does not explicitly provide workspace filters. CLI users can pass filters for broader queries later.
- [x] Run the new E2E path until it fails for the missing handler, then implement and verify green.

### Task 3: Add GTK History Dialog

- [x] Create `CommandHistoryDialog` and `HistoryCommand` row object.
- [x] Load recent active-workspace commands on open with an empty query.
- [x] Refresh rows when the search entry changes, with a small result cap of 50.
- [x] Activate a row to rerun the command in the active terminal.
- [x] Add selected-row copy support that copies only the command text and shows a toast through the owning window.
- [x] Keep command rows dense: command text primary, workspace/source/status/timestamp secondary.

### Task 4: Wire Window Action And Menu

- [x] Add `win.termplex-command-history` to the window action map.
- [x] Add "Command History..." to the main menu near Command Palette.
- [x] In the window, present one dialog instance per window through a weak ref.
- [x] On rerun, write `command + "\n"` to the active terminal PTY using the same safe path as `surface.send`.
- [x] On copy, use the window clipboard with `setText`.

### Task 5: Verification And Commit

- [x] Run `/opt/zig-x86_64-linux-0.15.2/zig fmt .`.
- [x] Run `python3 -m py_compile test/e2e/termplex_e2e.py tools/termplex-ctl`.
- [x] Run `/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell`.
- [x] Run `/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell`.
- [x] Run `/opt/zig-x86_64-linux-0.15.2/zig build e2e -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell`.
- [x] Commit with a focused message such as `feat: add command history search`.

## Security And Privacy Requirements

- Keep all command history local. Do not upload command text, workspace paths, transcript paths, or project metadata.
- Do not redact local command text in this phase; this is a developer productivity tool and users asked for useful local history.
- Use parameterized SQLite bindings for every filter to avoid SQL injection and malformed-query bugs.
- Do not replay transcript output through this feature. Rerun only writes the selected command text as intentional user input.
- Keep diagnostics and logs free of command text unless logging is explicitly added for a failing local debug path.

## Self-Review

- Spec coverage: The plan covers SQLite search, IPC/CLI, compact GTK UI, copy, rerun, and E2E verification.
- Placeholder scan: No deferred implementation placeholders remain inside phase 1 scope.
- Type consistency: Query and row fields match the existing `CommandRecord` shape plus existing `workspace_dir`.
