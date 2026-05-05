# Termplex Roadmap Implementation Sequence

Date: 2026-05-03

Related roadmap: `docs/superpowers/plans/2026-05-03-termplex-future-enhancements.md`

## Goal

Sequence the future enhancement roadmap into implementation-sized plans, starting with the work that gives Termplex the highest practical value before more product surface area is added.

## Recommendation

Start with the automated E2E harness.

Reasoning:

- It protects the terminal transcript, SQLite, IPC, session restore, and orchestration behavior that was just merged.
- It turns the manual smoke test into a repeatable release check.
- It lowers the risk of every later UI feature.
- It catches integration bugs that Zig unit tests cannot see because those bugs require the real GTK app, shell process, IPC socket, terminal output, SQLite state, and transcript files to run together.

## Implementation Order

### 1. Automated E2E Test Harness

Detailed plan:

- `docs/superpowers/plans/2026-05-03-automated-e2e-harness.md`

Status:

- Completed and committed.

Value:

- Highest.
- Gives shipping confidence immediately.
- Should be built before the updater, history UI, source control UI, or storage UI.

Scope:

- Add a real GTK app E2E runner.
- Use disposable XDG config/state/cache/runtime directories.
- Launch `termplex-app`.
- Drive it with `tools/termplex-ctl`.
- Verify IPC, workspace creation, tab creation, terminal I/O, SQLite rows, transcript files, session restore, transcript restore, and agent register/list/unregister.
- Capture logs and artifacts on failure.
- Expose the harness as `zig build e2e`.

### 2. In-App AppImage Update Flow

Detailed plan:

- `docs/superpowers/plans/2026-05-03-appimage-update-flow.md`

Status:

- Completed and committed.

Value:

- High.
- Improves distribution and upgrade experience for AppImage users.
- Reduces friction after releases.

Dependencies:

- App version source is already available through build metadata.
- Packaging scripts already create AppImage artifacts.
- Needs update metadata strategy before implementation.

Recommended phase 1 scope:

- Add current version display.
- Add latest-release check.
- Add update notification.
- Add AppImage download action inside Termplex.
- Save the downloaded AppImage to a predictable local path.
- Verify checksum/signature when release metadata provides one.
- Mark the downloaded AppImage executable.
- Let the user open the containing folder or run the new AppImage explicitly.

Defer:

- Auto-replacing the running binary.
- Background auto-update.
- Delta updates.
- Multi-channel update policy beyond stable/latest.

### 3. Command History Search UI

Detailed plan:

- `docs/superpowers/plans/2026-05-04-command-history-search-ui.md`

Status:

- Completed and committed.

Value:

- High.
- Turns the SQLite command history backbone into an obvious user-facing productivity feature.

Dependencies:

- E2E harness should already cover command row creation.
- Command history schema exists.
- Search/query API needs to be added before UI.

Recommended phase 1 scope:

- Add a query API over `command_history`.
- Search current workspace by command text.
- Filter by workspace, cwd, status/exit code, shell/source, and time range where metadata exists.
- Add a compact UI surface reachable from sidebar or command palette.
- Support copy command.
- Support rerun command in the active terminal.

Defer:

- Analytics.
- Saved search.
- Cross-workspace browsing UI beyond basic filters.
- Transcript body full-text search unless the schema is ready.

### 4. Basic Source Control Panel

Detailed plan:

- `docs/superpowers/plans/2026-05-04-basic-source-control-panel.md`

Status:

- Completed and committed.

Value:

- High.
- Makes Termplex feel like a workspace productivity app instead of only a terminal multiplexer.
- Builds on existing git probe and workspace metadata.

Dependencies:

- E2E harness.
- Basic git probe and project metadata already exist.
- Needs a small git service boundary before UI.

Recommended phase 1 scope:

- Show repository detected/not detected.
- Show branch and dirty state.
- Show staged and unstaged files.
- Show file-level diff.
- Stage/unstage whole files.
- Commit staged files.
- Show remote URL/repo identity.

Defer:

- Hunk-level staging.
- Push/pull/fetch.
- Conflict resolution.
- Branch management.
- File discard until confirmation UX is designed.

### 5. Storage And History Management UI

Detailed plan:

- `docs/superpowers/plans/2026-05-04-storage-history-management-ui.md`

Status:

- Completed and committed.

Value:

- Medium-high.
- Important trust feature now that Termplex persists local history by default.

Dependencies:

- E2E harness.
- SQLite/transcript cleanup behavior already exists in core paths.
- Needs a UI surface and a small storage accounting API.

Recommended phase 1 scope:

- Show approximate storage usage.
- Show transcript and command-history retention settings.
- Clear one terminal history.
- Clear one workspace history.
- Delete a project and ensure SQLite rows plus transcript files are cleaned up.
- Explain local persistence plainly in settings/help text.

Defer:

- Per-command deletion.
- Secret scanning.
- Cloud backup/sync controls.
- Complicated retention policy editors.

### 6. Transcript Viewer And Replay UI

Detailed plan:

- `docs/superpowers/plans/2026-05-04-transcript-viewer-replay-ui.md`

Status:

- Completed and committed.

Value:

- Medium-high.
- Useful after command history search exists, because search results need a better place to open output.

Dependencies:

- Command history search UI.
- Sanitization path for rendering persisted output outside the terminal emulator.

Recommended first scope:

- Open transcript from command history or terminal history list.
- Search within a transcript.
- Jump between command markers when metadata exists.
- Render output with safe control-sequence handling.

### 7. Workspace Dashboard

Detailed plan:

- `docs/superpowers/plans/2026-05-05-workspace-dashboard.md`

Status:

- Completed and committed.

Value:

- Medium.
- Useful once command history, git state, and agent/task data have reliable surfaces.

Dependencies:

- Command history search API.
- Basic source control panel.
- Storage/history management UI.
- Transcript viewer.

Recommended first scope:

- Workspace identity and active terminal/session summary.
- Recent commands with copy, rerun, and open-transcript actions.
- Git repository, branch, dirty state, and staged/unstaged counts.
- Storage/history summary.
- Quick actions into Command History, Transcript Viewer, Source Control, and Storage And History.

### 8. Background Tab Hydration

Detailed plan:

- `docs/superpowers/plans/2026-05-05-background-tab-hydration.md`

Status:

- Completed and committed.

Value:

- Medium.
- Improves restore responsiveness and resource use now that Termplex persists transcript-heavy sessions.

Dependencies:

- Session restore v6 with stable workspace, tab, split, surface, and history IDs.
- Terminal transcript persistence.
- E2E restore coverage.

Recommended first scope:

- Preserve restored tab/split layout and history IDs immediately.
- Defer restored transcript file reads until restored surfaces initialize.
- Ensure background workspace transcripts hydrate when selected.
- Keep replay on the existing frontend-only replay path.

Defer:

- Lazy shell process startup.
- Placeholder-only background tab widgets.
- Hydration progress UI.
- Background prefetch.

### 9. Per-Workspace Task Shortcuts

Value:

- Medium.
- Strong developer productivity feature, but more valuable after history search can promote repeated commands.

Dependencies:

- Command history search.
- Terminal rerun action.

Recommended first scope:

- Manual workspace task definitions.
- Run task in selected terminal.
- Store task metadata in SQLite.
- Optionally detect basic commands from project files later.

Status:

- Phase 1 implemented.
- Added SQLite-backed workspace task definitions, `termplex-ctl task` add/list/run/delete, dashboard/storage task metadata, run counters, and E2E coverage.
- Plan: `docs/superpowers/plans/2026-05-05-per-workspace-task-shortcuts.md`.

### 10. Diagnostics And Support Bundle

Value:

- Medium.
- Useful for shipping, but less urgent than E2E and update flow.

Dependencies:

- Stable logs/artifacts from E2E harness.
- Storage accounting primitives.

Recommended first scope:

- Export version, config summary, platform details, recent logs, storage metadata, and recent errors.
- Exclude transcript bodies by default.
- Let the user explicitly include selected history.

### 11. Advanced Command Analytics

Value:

- Later.
- Depends on enough command history data and a useful search UI.

Recommended later scope:

- Frequently used commands.
- Failure trends.
- Duration trends.
- Suggested saved tasks.

### 12. Advanced Git Workflows

Value:

- Later.
- Should follow the basic source control panel.

Recommended later scope:

- Hunk-level staging.
- Discard with confirmation.
- Branch switching.
- Fetch/pull/push.
- Amend commit.
- Compare revisions.

### 13. History-Aware Rerun Workflows

Value:

- Later.
- Should follow command history search and workspace tasks.

Recommended later scope:

- Rerun failed commands.
- Edit cwd/env before rerun.
- Rerun command groups.
- Promote repeated commands to tasks.

### 14. Deeper Orchestration And Memory UX

Value:

- Later.
- Should follow E2E, command history, and dashboard basics.

Recommended later scope:

- Agent task timeline.
- Memory state visibility.
- Resume manifests as first-class UI.
- Cross-workspace agent activity.

### 15. Multi-Window And Workspace Coordination

Value:

- Later.
- Should be planned after core single-window workflows are stable.

Recommended later scope:

- Same-project-open indicators.
- Workspace lock/conflict states.
- Shared recent history across windows.
- More predictable restore for multi-window sessions.

## Plan Creation Queue

Create detailed implementation plans in this order:

1. `2026-05-03-automated-e2e-harness.md`
2. `2026-05-03-appimage-update-flow.md`
3. `2026-05-04-command-history-search-ui.md`
4. `2026-05-04-basic-source-control-panel.md`
5. `2026-05-04-storage-history-management-ui.md`
6. `2026-05-04-transcript-viewer-replay-ui.md`
7. `2026-05-05-workspace-dashboard.md`
8. `YYYY-MM-DD-background-tab-hydration.md`
9. `YYYY-MM-DD-workspace-task-shortcuts.md`
10. `YYYY-MM-DD-diagnostics-support-bundle.md`

The remaining Phase 3 items should not be planned in detail until the Phase 1 and Phase 2 surfaces reveal real usage patterns.
