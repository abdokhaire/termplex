# Basic Source Control Panel

**Goal:** Add a local-first source control surface for the active workspace, with repository identity, branch/dirty state, staged and unstaged file lists, file diffs, file-level stage/unstage, and commit.

**Architecture:** Add a small `git_status` service in `src/termplex/core` that shells out to `git` with explicit argument vectors and a bounded output cap. Reuse the existing GTK application IPC socket as the automation boundary, extend `tools/termplex-ctl` for source-control commands, then add a compact libadwaita dialog reachable from the main window menu and IPC.

**Tech Stack:** Zig 0.15.2, GTK4/libadwaita, existing Termplex IPC socket, Python E2E harness, system `git`.

## Scope

Phase 1 includes:

- Detect whether the active workspace directory is inside a git repository.
- Show repository root, branch, dirty state, and `origin` remote URL when available.
- Show changed files grouped into staged and unstaged sections.
- Show file-level diffs for staged and unstaged files.
- Stage and unstage whole files.
- Commit staged files with a message.
- Add CLI/E2E coverage for status, diff, stage, unstage, commit, and panel presentation.

Phase 1 explicitly defers:

- Hunk-level staging.
- Push, pull, fetch, and sync status.
- Branch switching, branch creation, and merge/rebase flows.
- Conflict resolution.
- Discard/revert file changes until confirmation UX is designed.
- SQLite snapshots of git metadata. The live source-control panel should read git directly; SQLite remains the durable project metadata backbone.

## Files

- Add `src/termplex/core/git_status.zig`: service types, git command runner, status parsing, diff/stage/unstage/commit operations, unit tests.
- Modify `src/termplex/main.zig`: export `core.git_status`.
- Modify `src/apprt/gtk/class/application.zig`: add source-control IPC handlers.
- Add `src/apprt/gtk/class/source_control_dialog.zig`: compact source-control dialog.
- Add `src/apprt/gtk/ui/1.5/source-control-dialog.blp`: dialog UI.
- Modify `src/apprt/gtk/build/gresource.zig`: include new blueprint.
- Modify `src/apprt/gtk/class/window.zig`: action, dialog weak ref, signal handlers, menu wiring.
- Modify `src/apprt/gtk/ui/1.5/window.blp`: add "Source Control..." menu item near command history.
- Modify `tools/termplex-ctl`: add `git status`, `git diff`, `git stage`, `git unstage`, `git commit`, and `git show`.
- Modify `test/e2e/termplex_e2e.py`: exercise git workflows in a disposable repository.
- Modify `test/e2e/README.md`: mention source-control coverage.

## API Shape

IPC methods:

- `git.status` with optional `{ "workspace": <name|index> }` returns `{ is_repo, root, branch, dirty, remote_url, staged, unstaged }`.
- `git.diff` with optional `{ "workspace": <name|index>, "path": "...", "staged": false }` returns `{ path, staged, diff }`.
- `git.stage` with `{ "path": "..." }` returns refreshed status.
- `git.unstage` with `{ "path": "..." }` returns refreshed status.
- `git.commit` with `{ "message": "..." }` returns `{ committed, commit }` plus refreshed status.
- `git.show` presents the source-control dialog and returns `{ shown: true }`.

CLI commands mirror IPC:

- `termplex-ctl git status`
- `termplex-ctl git diff --path <path> [--staged]`
- `termplex-ctl git stage --path <path>`
- `termplex-ctl git unstage --path <path>`
- `termplex-ctl git commit --message <message>`
- `termplex-ctl git show`

## Implementation Steps

- [x] Add failing unit tests for parsing `git status --porcelain=v1 -z` entries into staged and unstaged file lists.
- [x] Add failing unit tests for command argument construction invariants: file paths are passed as arguments after `--`, not interpolated into shell strings.
- [x] Add failing E2E assertions for `termplex-ctl git status` in a disposable repository.
- [x] Add failing E2E assertions for diff, stage, unstage, commit, and `git show`.
- [x] Implement `git_status.zig` with bounded subprocess output and owned result types.
- [x] Export the service through `src/termplex/main.zig`.
- [x] Add `git.*` IPC handlers in the GTK application using the active or requested workspace directory.
- [x] Add `tools/termplex-ctl git ...` commands.
- [x] Add the source-control dialog and menu action.
- [x] Refresh the dialog after stage/unstage/commit and show errors inline in the dialog.
- [x] Run formatting, unit tests, GTK build, and E2E.
- [x] Commit with a focused message such as `feat: add source control panel`.

## Security And Privacy Requirements

- Do not upload workspace paths, git remotes, file names, diffs, commit messages, or repository metadata.
- Do not invoke a shell for git operations. Use explicit argv arrays only.
- Pass file paths after `--` for file-scoped git operations.
- Keep diff output bounded for IPC and UI responses.
- Treat diffs and commit messages as sensitive local developer data. They may be displayed locally because Termplex is a developer productivity tool, but they must not be included in update checks, crash reports, telemetry, or external requests.
- Do not add discard/revert actions in Phase 1; destructive source-control actions need a dedicated confirmation design.

## Verification

- `python3 -m py_compile test/e2e/termplex_e2e.py tools/termplex-ctl`
- `/opt/zig-x86_64-linux-0.15.2/zig fmt .`
- `/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell`
- `/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell`
- `/opt/zig-x86_64-linux-0.15.2/zig build e2e -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell`
