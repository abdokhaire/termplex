# Per-Workspace Task Shortcuts

Status: implemented as the Phase 1 slice.

## Goal

Add a developer-facing task shortcut surface so each workspace can keep a small set of named commands and run them into the selected terminal without requiring a separate task runner UI.

## Phase 1 Scope

- Store manual task definitions in the existing SQLite backbone.
- Scope each task to a workspace ID.
- Support add, list, run, and delete over IPC.
- Expose the same actions through `termplex-ctl task`.
- Run a task by writing the saved command plus Enter into the selected terminal.
- Track `run_count` and `last_run_at` for future ranking and search.
- Include task counts in storage/dashboard status.
- Include workspace task rows in dashboard status JSON for a later visual panel.
- Delete workspace task rows when project storage is deleted.

## Deferred

- Visual task panel inside the dashboard.
- Promotion from repeated command history into a saved task.
- Auto-detection from `package.json`, `Makefile`, `justfile`, `Taskfile.yml`, or project-specific config.
- Task groups, tags, pinned tasks, and ranking by recency/frequency.
- Per-task shell or environment overrides.
- Background task execution outside a terminal.

## Behavior

CLI examples:

```bash
termplex-ctl task add --workspace app --name test --command "zig build test"
termplex-ctl task list --workspace app
termplex-ctl task run --workspace app --tab 0 --name test
termplex-ctl task delete --workspace app --name test
```

IPC methods:

- `task.add`
- `task.list`
- `task.run`
- `task.delete`

Storage:

- Table: `workspace_tasks`
- Unique key: `(workspace_id, name)`
- Stored fields: `name`, `command`, optional `working_directory`, `created_at`, `updated_at`, `last_run_at`, `run_count`

## Verification

- Unit coverage in `terminal_history_db.zig` exercises task create/list/get/run/delete and project cleanup.
- E2E coverage in `test/e2e/termplex_e2e.py` exercises `termplex-ctl task add/list/run/delete`, verifies terminal output, checks SQLite run metadata, checks dashboard task JSON, and verifies project deletion removes task rows.
