# Transcript Viewer And Replay UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Use `superpowers:test-driven-development` before production code changes.

**Goal:** Add a dedicated local transcript viewer for persisted terminal history so developers can inspect historical output, search inside it, and jump from command history to related output without restoring that output into a live terminal.

**Architecture:** Reuse the existing plain transcript files as the source of terminal output and SQLite command metadata as the source of command markers. Move transcript display sanitization into a small core helper, expose a read/search IPC surface through `tools/termplex-ctl`, and add a libadwaita dialog that renders sanitized transcript text in a selectable monospace view with search and command-marker navigation.

**Tech Stack:** Zig 0.15.2, GTK4/libadwaita Blueprint templates, SQLite via dynamic `libsqlite3`, JSON IPC over Unix sockets, Python stdlib E2E runner.

---

## Scope

Phase 2 first slice includes:

- Open the active terminal transcript from the main menu.
- Open a transcript from a selected command-history result.
- Read transcript bodies from the existing `.ansi` files.
- Render transcript content outside the terminal emulator only after replay-safe sanitization.
- Search within the sanitized transcript text.
- Jump between command markers for the same `history_id` using command-history metadata.
- Copy selected transcript text through normal GTK selection behavior.
- Expose CLI/IPC support for transcript read/search so E2E can verify the feature without visual-only assertions.

Phase 2 first slice defers:

- ANSI color rendering in the transcript viewer.
- Byte-accurate command output ranges.
- Export/share transcript workflows.
- Full transcript body indexing in SQLite.
- Cross-workspace transcript browser beyond opening from active terminal or command history.
- Hunk-like output folding or rich command analytics.

## Design Decisions

- The viewer should render plain sanitized text in phase 1 of this feature. This is safer and simpler than rendering ANSI escapes in a GTK label, and it avoids escape-sequence injection when output is displayed outside the terminal emulator.
- Command marker navigation should be metadata-backed first. Use `command_history` rows for the selected `history_id`; selecting a command can scroll to the first visible occurrence of the command text in the sanitized transcript when present. Exact output span mapping can be added later if transcript writes store marker offsets.
- Transcript search should operate on the sanitized text held by the dialog, not by rescanning SQLite. This keeps the first UI responsive for capped transcript files and avoids adding a premature full-text index.
- The existing `surface.read` transcript fallback sanitizer should be moved to a reusable core helper so IPC and UI share one tested replay-safe path.
- The command-history dialog should gain an "Open Transcript" action, but rerun/copy behavior should remain unchanged.

## File Map

- Create `src/termplex/core/transcript_view.zig`: reusable transcript view helpers.
- Modify `src/main.zig`: import `transcript_view.zig` for tests.
- Modify `src/apprt/gtk/class/application.zig`: move existing plain transcript sanitization to the core helper, add transcript IPC handlers, and expose app methods for the GTK dialog.
- Modify `src/termplex/core/terminal_history_db.zig`: add a surface lookup and a `history_id` command-marker query if existing `listRecentCommands` is not enough for the UI.
- Modify `tools/termplex-ctl`: add `history transcript` and `history transcript-search` commands.
- Modify `src/apprt/gtk/class/command_history_dialog.zig`: add an "Open Transcript" signal/action for the selected command row.
- Create `src/apprt/gtk/class/transcript_viewer_dialog.zig`: transcript viewer object and command marker row object.
- Create `src/apprt/gtk/ui/1.5/transcript-viewer-dialog.blp`: compact viewer with search entry, command marker list, and transcript text pane.
- Modify `src/apprt/gtk/build/gresource.zig`: include the new Blueprint.
- Modify `src/apprt/gtk/class/window.zig`: wire `win.termplex-transcript-viewer`, menu entry, command-history open signal, and one dialog instance per window through a weak ref.
- Modify `src/apprt/gtk/ui/1.5/window.blp`: add "Transcript Viewer..." near Command History.
- Modify `test/e2e/termplex_e2e.py`: verify CLI transcript read/search and UI dialog presentation.

## Tasks

### Task 1: Core Transcript View Helpers

- [x] Add failing unit tests in `transcript_view.zig` for CSI/OSC stripping, carriage-return normalization, C0 control dropping, last-line extraction, and case-insensitive line search.
- [x] Implement `stripControlSequences`, `extractLastLines`, and a small `SearchResult`/`searchLines` helper over plain text.
- [x] Move the existing private `Application.stripControlSequencesForIpc` logic to `transcript_view.stripControlSequences`.
- [x] Update the existing application-level sanitizer test to call the core helper or replace it with a core test.
- [x] Run `/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell -Dtest-filter="transcript view"`.

### Task 2: SQLite Metadata For Transcript Opening

- [x] Add a failing unit test in `terminal_history_db.zig` that upserts surfaces and commands, then looks up a non-deleted surface by `history_id`.
- [x] Add `SurfaceRecord`, `SurfaceList` if needed, and `getSurface(history_id)` with `transcript_path`, workspace metadata, status, and last exit code.
- [x] Add or reuse a `listRecentCommands(.{ .history_id = id })` query for command markers, ordered oldest-to-newest for viewer navigation.
- [x] Keep all queries parameterized.
- [x] Run the filtered database tests.

### Task 3: IPC And CLI Transcript Surface

- [x] Add failing E2E assertions that `tools/termplex-ctl history transcript --history-id <id>` returns sanitized output from the transcript file.
- [x] Add failing E2E assertions that `tools/termplex-ctl history transcript-search --history-id <id> --query <text>` returns line numbers and snippets.
- [x] Add IPC method `history.transcript` with params: `history_id`, optional `workspace`, optional `lines`, optional `plain`.
- [x] Add IPC method `history.transcript_search` with params: `history_id`, `query`, optional `workspace`, optional `limit`.
- [x] Clamp transcript read line count and search result count to bounded values.
- [x] Return structured metadata: `history_id`, `workspace_id`, `workspace_name`, `workspace_dir`, `transcript_path`, `output`, and `commands`.
- [x] Keep IPC responses sanitized and JSON-escaped.

### Task 4: GTK Transcript Viewer Dialog

- [x] Create `TranscriptViewerDialog` and a marker row object.
- [x] Load active terminal transcript on open from the main menu.
- [x] Load a specific `history_id` when opened from command history.
- [x] Show sanitized transcript text in a selectable monospace text view or label inside a scrolled window.
- [x] Add a search entry that highlights or scrolls to matching lines and displays match count.
- [x] Add previous/next match actions.
- [x] Add a command marker list using `command_history` metadata for the selected `history_id`.
- [x] Selecting a marker should scroll to the first matching command text when present and update a status label when no textual anchor is found.

### Task 5: Wire Window And Command History Actions

- [x] Add `win.termplex-transcript-viewer` to the window action map.
- [x] Add "Transcript Viewer..." to the main menu near "Command History...".
- [x] Add an `open-transcript` signal/action to `CommandHistoryDialog` rows.
- [x] In `Window`, present one transcript dialog instance per window with a weak ref.
- [x] From command history, open the viewer with the selected command row's `history_id`.
- [x] Keep existing command copy and rerun behavior unchanged.

### Task 6: Verification And Commit

- [x] Run `/opt/zig-x86_64-linux-0.15.2/zig fmt .`.
- [x] Run `python3 -m py_compile test/e2e/termplex_e2e.py tools/termplex-ctl`.
- [x] Run `/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell`.
- [x] Run `/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell`.
- [x] Run `/opt/zig-x86_64-linux-0.15.2/zig build e2e -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell`.
- [x] Run `git diff --check`.
- [x] Commit with a focused message such as `feat: add transcript viewer`.

## Security And Privacy Requirements

- Keep transcript viewing entirely local.
- Do not upload transcript, command, workspace, git, path, or agent data.
- Do not log transcript bodies or command text from viewer search failures.
- Use replay-safe sanitization before rendering persisted output outside the terminal emulator.
- Strip OSC, CSI, DCS/APC/PM/SOS, bare ESC two-byte sequences, and non-printing C0 controls from viewer output.
- Normalize carriage returns so progress bars and carriage-return updates do not create misleading control behavior in GTK text.
- Do not write transcript text into the active terminal from the viewer. Rerun remains an explicit command-history action only.
- Keep transcript file paths behind IPC output for developer/debug visibility, but never treat paths received over IPC as trusted input for arbitrary file reads; resolve by `history_id` and workspace metadata.
- Respect existing retention and deletion behavior. Deleted project/workspace/terminal history must not be resurrected by the viewer.

## Self-Review

- Spec coverage: The plan covers active-terminal transcript viewing, command-history entry points, search, command marker navigation, IPC/CLI coverage, and replay-safe rendering.
- Placeholder scan: Phase 2 first-slice scope has concrete files and tests. Deferred features are explicitly out of scope.
- Type consistency: Viewer state is keyed by existing `history_id`; transcript bodies remain plain files; command markers come from existing `command_history` rows.
