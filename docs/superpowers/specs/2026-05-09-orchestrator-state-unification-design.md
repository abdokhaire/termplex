# Orchestrator State Unification Design

## Goal

Unify the state model used by the Termplex orchestrator so it no longer answers live workspace questions from `~/.termplex/orchestration/state.json`. The orchestrator must use a single supported command surface that combines live runtime state from IPC with durable SQLite history.

## Problem

Termplex currently exposes overlapping state surfaces:

- GTK `Application` runtime state knows which workspaces, tabs, and surfaces are open now.
- `terminal_history_db.zig` stores durable project, surface, command, task, transcript, and storage metadata in SQLite.
- `~/.termplex/orchestration/state.json` stores older orchestrator memory and process snapshots.
- Session JSON stores UI restore layout.

The stale workspace-count bug happened because the orchestrator treated `state.json` as live truth. That file can contain closed workspaces and dead surfaces, so it can disagree with the UI and `termplex-ctl workspace list`.

## Source Of Truth

Runtime workspace membership is owned by the GTK `Application` and reached through IPC. SQLite is the durable source for command history, task state, transcript surfaces, and runtime process snapshots. `state.json` is deprecated as an agent-facing source of truth.

Session JSON remains separate because it restores UI layout, not orchestrator intelligence.

## Design

Add a unified orchestrator command:

```bash
termplex-ctl orchestrator status
```

It maps to IPC method:

```json
{"method":"orchestrator.status","params":{},"id":1}
```

The method returns one JSON document composed from existing runtime and durable sources:

```json
{
  "live": {
    "workspace_count": 2,
    "active_workspace": 0,
    "workspaces": []
  },
  "agents": [],
  "history": {
    "recent_commands": [],
    "tasks": []
  },
  "resume": {
    "candidates": []
  },
  "storage": {}
}
```

The orchestrator skill will instruct agents to call this command first for global context. Agents may still use focused commands after that:

- `termplex-ctl workspace list` and `termplex-ctl status` for live navigation.
- `termplex-ctl dashboard status --workspace <name>` for per-workspace dashboard detail.
- `termplex-ctl history search` and `termplex-ctl history transcript` for durable command and transcript history.
- `termplex-ctl agent list`, `surface send`, and `surface read` for agent-to-agent coordination through existing surfaces.

## SQLite Runtime Snapshot

Extend `terminal_surfaces` with runtime process fields copied from the older memory snapshot:

```sql
ALTER TABLE terminal_surfaces ADD COLUMN process_pid INTEGER;
ALTER TABLE terminal_surfaces ADD COLUMN process_alive INTEGER NOT NULL DEFAULT 0;
ALTER TABLE terminal_surfaces ADD COLUMN detection_method TEXT;
ALTER TABLE terminal_surfaces ADD COLUMN ports_json TEXT;
ALTER TABLE terminal_surfaces ADD COLUMN command_started_at TEXT;
ALTER TABLE terminal_surfaces ADD COLUMN last_command TEXT;
```

`StateManager` remains the receiver for shell command events, but it writes the durable runtime snapshot into SQLite. The JSON state file becomes compatibility output only and is not used to answer live questions.

## Resume Manifest

Resume candidates must come from SQLite, not stale JSON workspace membership. A candidate is a surface row with `process_alive = 1`, or a command-history row that has started and not ended if the current schema can represent it. The manifest should say there are no active processes when SQLite has no candidates.

## Workspace Close And Rename

Closing a workspace must not make the orchestrator count stale JSON rows. Live workspace counts come from runtime IPC. SQLite may keep historical project and command rows for search and dashboard use; destructive history cleanup should stay tied to explicit storage-delete operations, not normal UI close.

Renaming a live workspace should update runtime state and durable project/surface labels where Termplex already updates project metadata.

## Error Handling

If SQLite is unavailable, `orchestrator.status` still returns live runtime state and an empty durable section with a warning field. If runtime IPC is unavailable, the CLI reports the IPC connection error normally because no live truth can be queried.

## Testing

Add focused tests for:

- SQLite runtime fields round-trip through `upsertSurface`.
- SQLite resume candidate query excludes dead surfaces and includes live surfaces.
- Resume manifest can be built from SQLite candidates and does not count dead-only workspaces.
- CLI maps `orchestrator status` to `orchestrator.status`.
- IPC dispatch accepts `orchestrator.status`.

Run focused tests for modified modules, then run the GTK build command from `AGENTS.md`.

