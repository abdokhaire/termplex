# Termplex Future Enhancement Roadmap

Date: 2026-05-03

## Context

This roadmap captures follow-up product and engineering enhancements identified after merging and testing the terminal transcript persistence work on `main`.

Current baseline:

- Termplex has durable SQLite-backed app/orchestration state.
- Terminal transcript history is stored as plain files.
- Terminal history is capped and coalesced.
- Restored transcript history is replayed into the frontend terminal.
- Terminal history is cleared in specific lifecycle cases:
  - explicit terminal clear
  - terminal restart
  - reopen with a different cwd or env
  - reopen after exited/error state
  - project deletion
- Project metadata is stored in SQLite.
- Runtime smoke testing covered workspace creation, terminal I/O, command persistence, agent registration, session restore, transcript restore, and clean shutdown.

Product assumption:

Termplex is a local-first developer productivity tool. It is acceptable to show local history that may contain sensitive developer data, as long as the app is clear about what is persisted and provides explicit controls to clear or delete it. Avoid over-engineering privacy restrictions that would reduce the usefulness of the product for its intended developer audience.

## Direction

Termplex should keep leaning into three strengths:

- Workspace-native terminal workflows.
- Durable, searchable local history.
- Practical orchestration around terminals, agents, projects, and source control.

The next enhancements should improve shipping confidence first, then add high-value developer workflows that build directly on the new SQLite and transcript persistence foundation.

## Guiding Principles

- Keep the app local-first. Do not upload workspace, command, transcript, git, or agent data unless a future feature explicitly asks for sync or sharing.
- Use SQLite for durable app metadata, orchestration state, command indexes, project metadata, joins, and queryable history.
- Use plain files for terminal transcript bodies where append/read behavior and storage size make that simpler.
- Keep transcript history useful and developer-friendly. Match the pragmatic behavior seen in tools like T3: retain useful local history, expose clear deletion controls, and avoid complicated secret-redaction workflows in phase 1.
- Sanitize terminal escape sequences when rendering persisted output outside the real terminal emulator.
- Treat AppImage updates as part of the product experience, not only as a release artifact.
- Add automated E2E coverage before expanding the surface area further.

## Phase 1

Phase 1 should focus on shipping confidence and the highest-value workflows unlocked by the persistence foundation.

### 1. Automated E2E Test Harness

Build a repeatable test harness for the real GTK app.

Goals:

- Launch Termplex with a disposable config/state/cache profile.
- Exercise workspace creation.
- Create tabs/surfaces.
- Send terminal input and read terminal output.
- Verify SQLite rows for projects, surfaces, and commands.
- Verify transcript files are created, capped, coalesced, restored, and cleared.
- Verify session restore after shutdown.
- Verify agent registration/list/unregistration flows.
- Save logs and artifacts when a test fails.

Rationale:

The current manual E2E smoke test proved the merged branch works, but this must become a repeatable pre-release check. It should be the first Phase 1 item because it reduces regression risk for every later feature.

### 2. In-App AppImage Update Flow

Add update awareness and AppImage download support inside Termplex.

Goals:

- Expose the current app version in the UI.
- Check the latest release from the configured update source.
- Notify the user when a newer version is available.
- Show a clear action to download the AppImage immediately inside Termplex.
- Download to a predictable local location.
- Verify the downloaded artifact using available release metadata, such as checksum or signature.
- Make the downloaded AppImage executable.
- Provide a clear next action after download, such as opening the file location or launching the new AppImage when that is technically safe.

Notes:

- The app should not auto-replace a running binary in phase 1.
- The update UX should be simple and explicit: notify, download, verify, then let the user decide when to run the new version.

### 3. Command History Search UI

Add a first UI surface for the indexed command history.

Goals:

- Search command text across the current workspace.
- Filter by project, cwd, status, exit code, shell, and time range where metadata exists.
- Open the related terminal/session when available.
- Copy a command.
- Rerun a command in the active terminal or a selected workspace terminal.
- Keep the first version focused on usefulness, not analytics.

Storage:

- Use SQLite as the source of truth for command metadata and search indexes.
- Keep transcript bodies in plain files, linked by IDs/paths from SQLite.

### 4. Basic Source Control Panel

Add a simple source control view inspired by VS Code and T3-style diff panels.

Goals:

- Show whether the current workspace/project is a git repository.
- Show branch name and dirty status.
- Show changed files grouped into staged and unstaged sections.
- Show file-level diffs.
- Stage and unstage whole files.
- Commit staged files with a message.
- Show project git remote URL or repository identity.

Potential implementation detail:

- Hidden git refs or locally stored metadata can be used to display project git URLs or related repository information when useful, but the first version should prefer direct git discovery where possible.

Out of scope for Phase 1:

- Hunk-level staging.
- Conflict resolution.
- Advanced branch management.
- Push/pull orchestration.

### 5. Storage And History Management UI

Give users visible controls for the persistence features.

Goals:

- Show approximate storage usage for Termplex state.
- Show transcript/history retention settings.
- Clear history for a terminal.
- Clear history for a workspace.
- Delete a project and ensure related SQLite rows and transcript files are removed.
- Explain locally what is persisted without making this a blocking privacy flow.

Rationale:

The app is allowed to show sensitive local developer history, but it must give developers direct control over stored history.

## Phase 2

Phase 2 should deepen the workspace experience after the Phase 1 foundation is covered by automated tests.

### 1. Transcript Viewer And Replay UI

Add a dedicated transcript viewer for persisted terminal history.

Goals:

- View historical terminal output without needing to restore it into a live terminal.
- Search within a transcript.
- Jump between command markers when available.
- Show command status, duration, cwd, and exit code where shell integration provides it.
- Render replay safely by sanitizing control sequences outside the terminal emulator.

### 2. Workspace Dashboard

Add a compact workspace dashboard that summarizes active developer context.

Goals:

- Active terminals and status.
- Recent commands.
- Running or recently completed agent tasks.
- Git dirty state.
- Recent workspace files or directories if available.
- Quick actions for common flows.

### 3. Background Tab Hydration

Improve perceived restore performance and resource use.

Goals:

- Restore visible terminal state quickly.
- Hydrate background tabs lazily.
- Avoid heavy terminal replay for tabs the user has not opened.
- Keep transcript restore behavior predictable.

### 4. Per-Workspace Task Shortcuts

Add project-level saved commands.

Goals:

- Define common commands per workspace, such as build, test, lint, run, dev server, and release.
- Start commands in a selected terminal.
- Store metadata in SQLite.
- Optionally detect common project commands from files like `package.json`, `Makefile`, Zig build files, or project config.

### 5. Diagnostics And Support Bundle

Add a local diagnostics exporter.

Goals:

- Export app version, platform details, config summary, logs, storage metadata, and recent error traces.
- Exclude transcript bodies by default.
- Let the user explicitly include selected history when needed.
- Keep the bundle local unless the user manually shares it.

## Phase 3

Phase 3 should add richer workflows after the core surfaces prove useful.

### 1. Advanced Command Analytics

Potential features:

- Frequently used commands.
- Failed command trends.
- Duration trends.
- Workspace-specific command patterns.
- Suggested saved tasks based on repeated commands.

### 2. Advanced Git Workflows

Potential features:

- Hunk-level staging.
- File discard with confirmation.
- Branch switch/create.
- Pull/push/fetch.
- Commit amend.
- Compare with previous revisions.

### 3. History-Aware Rerun Workflows

Potential features:

- Rerun failed commands.
- Rerun commands with edited cwd/env.
- Rerun command groups.
- Promote a command to a saved workspace task.

### 4. Deeper Orchestration And Memory UX

Potential features:

- Better visibility into orchestrator memory state.
- Agent task timelines.
- Resume manifests as first-class UI.
- Cross-workspace agent activity views.

### 5. Multi-Window And Workspace Coordination

Potential features:

- Better behavior when the same project is open in multiple windows.
- Workspace locking or conflict indicators.
- Shared recent history across windows.
- More predictable restore behavior for multi-window sessions.

## Security And Privacy Requirements

The product should be pragmatic for developers, but these requirements should be explicit before implementation:

- Persisted history remains local by default.
- No transcript, command, project, git, or agent data is uploaded unless a future sync/sharing feature explicitly asks the user.
- State and transcript files should be created with user-only permissions where feasible.
- Users must have visible controls to clear terminal, workspace, and project history.
- Project deletion must delete related project metadata and transcript files.
- Terminal escape sequences must be sanitized when persisted output is displayed outside the terminal emulator.
- Replaying transcript history into the terminal widget should avoid executing pasted commands or interpreting stored output as user input.
- AppImage downloads must be verified when checksums or signatures are available.
- Failed or partial AppImage downloads must not replace an existing working binary.
- Logs and diagnostics should avoid including transcript bodies unless the user explicitly requests that.

## Data Model Direction

Use SQLite for:

- projects
- workspaces
- surfaces/tabs
- sessions
- command metadata
- command indexes
- transcript references
- git metadata snapshots
- agent registrations and task metadata
- update check metadata

Use plain files for:

- terminal transcript bodies
- larger replay/history payloads
- optional diagnostic bundles

Keep SQLite rows and transcript files linked by stable IDs. Project/workspace deletion must clean both sides.

## Planning Notes

Each major item in this roadmap should become its own detailed implementation plan before code changes begin.

Recommended order:

1. Build the automated E2E harness.
2. Add the in-app AppImage update flow.
3. Add the command history search UI.
4. Add the basic source control panel.
5. Add storage and history management controls.

Open questions for future plans:

- Which release source should the AppImage updater use first: GitHub releases, a project-owned manifest, or both?
- Where should command history search live: sidebar panel, command palette, dedicated page, or all of these over time?
- What should the default transcript retention cap be by size, age, command count, or all three?
- Should the first git panel support only file-level staging, or should hunk-level staging be moved earlier if the diff infrastructure makes it cheap?
- Should workspace task shortcuts be manually configured first, auto-detected first, or both?
