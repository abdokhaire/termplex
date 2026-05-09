# Termplex Orchestration Skill

## Purpose

This skill teaches an agent how to operate Termplex from the special `Orchestrator` workspace using `termplex-ctl`.

Use it to:
- inspect workspaces and tabs
- send commands into terminals
- read terminal output
- track registered agents
- check high-level runtime status

`termplex-ctl` talks to Termplex over a Unix socket and returns JSON by default.

## Setup

When running inside the orchestrator tab, register on startup:

```bash
termplex-ctl agent register --workspace "Orchestrator" --tab 0 --type codex --pid <your_pid>
```

On exit, unregister:

```bash
termplex-ctl agent unregister --pid <your_pid>
```

## Core Commands

### Unified orchestrator context

```bash
termplex-ctl orchestrator status
```

Run this first when you need to understand Termplex. It combines the live runtime workspace tree, registered agents, recent SQLite command history, active resume candidates, and storage counts in one response.

### Workspace inspection

```bash
termplex-ctl workspace list
termplex-ctl status
```

Use `workspace list` to discover available workspaces and the active one.
Use `status` for top-level runtime state reported by the server.

### Source of truth

For live workspace counts, names, active workspace, tabs, and current terminal state, use `termplex-ctl`. For global context, prefer `termplex-ctl orchestrator status`; use narrower commands only when you need a focused follow-up.

Do not count workspaces from `~/.termplex/orchestration/state.json` or `<workspace>/.termplex/state.json`. Those files are deprecated compatibility snapshots for process history. They can contain previous-session entries, closed workspaces, and surfaces with `"process_alive": false`.

Authoritative live queries:

```bash
termplex-ctl orchestrator status  # unified live + SQLite orchestrator view
termplex-ctl workspace list   # live workspace list; count result.items
termplex-ctl status           # live workspace/tab tree
termplex-ctl tab list --workspace "backend"
termplex-ctl agent list       # registered AI agents only
```

### Workspace control

```bash
termplex-ctl workspace create --name "backend" --dir ~/projects/backend
termplex-ctl workspace select --name "backend"
termplex-ctl workspace select --index 1
termplex-ctl workspace rename --name "old" --new-name "new"
termplex-ctl workspace close --name "backend"
```

### Tab inspection

```bash
termplex-ctl tab list --workspace "backend"
```

Use `tab list` after selecting or creating a workspace to discover tab indices.

### Tab creation

```bash
termplex-ctl tab create --workspace "backend" --title "editor" --command "nvim"
termplex-ctl tab create --workspace "backend" --title "server" --command "npm run dev"
termplex-ctl tab create --workspace "backend" --title "tests" --dir ~/projects/backend
```

### Terminal interaction

```bash
termplex-ctl surface send --workspace "backend" --tab 1 "npm test\n"
termplex-ctl surface read --workspace "backend" --tab 1 --lines 50
```

Use `surface send` to type into a terminal.
Use `surface read` to inspect what is running or what command output was produced.

### Agent inspection

```bash
termplex-ctl agent list
termplex-ctl agent register --workspace "backend" --tab 0 --type claude --pid 1234
termplex-ctl agent terminate --pid 1234
```

`agent list` is the authoritative way to see which AI agents have registered with Termplex.

### Agent-to-agent communication

Termplex does not currently expose a separate A2A message bus. Communicate with another agent through its terminal:

```bash
termplex-ctl agent list
termplex-ctl surface send --workspace "backend" --tab 0 "Please inspect the failing test and report findings.\n"
termplex-ctl surface read --workspace "backend" --tab 0 --lines 80
```

Use `agent list` first to identify the target agent's workspace/tab. Then use `surface send` to deliver the request and `surface read` to inspect the response. If there is no registered target agent, create or select a tab first, then register or ask the agent to register.

### Utility

```bash
termplex-ctl ping
termplex-ctl status
```

## How To Inspect A Workspace

To learn what exists in a workspace:

```bash
termplex-ctl workspace list
termplex-ctl tab list --workspace "backend"
```

To learn what is running in a tab:

```bash
termplex-ctl surface read --workspace "backend" --tab 0 --lines 80
```

To interact and verify:

```bash
termplex-ctl surface send --workspace "backend" --tab 0 "pwd\n"
termplex-ctl surface send --workspace "backend" --tab 0 "ps\n"
termplex-ctl surface read --workspace "backend" --tab 0 --lines 80
```

To see AI-managed tabs and agents:

```bash
termplex-ctl agent list
```

## Important Limitation

Termplex does not currently expose a dedicated per-workspace process inventory API.

An agent should infer "what is running" from:
- `tab list` for workspace structure
- `surface read` for terminal output
- commands it sends with `surface send`
- `agent list` for registered AI agents
- `status` for server-level state

If you need process-level detail inside a workspace, send a shell command into the target terminal and then read the output back.

## Workflow Patterns

### Create and inspect a development workspace

```bash
termplex-ctl workspace create --name "backend" --dir ~/projects/backend
termplex-ctl tab create --workspace "backend" --title "server" --command "npm run dev"
termplex-ctl tab create --workspace "backend" --title "tests"
termplex-ctl tab list --workspace "backend"
termplex-ctl surface read --workspace "backend" --tab 0 --lines 50
```

### Run a command and check the result

```bash
termplex-ctl surface send --workspace "backend" --tab 1 "npm test\n"
sleep 3
termplex-ctl surface read --workspace "backend" --tab 1 --lines 80
```

### Probe the environment in a tab

```bash
termplex-ctl surface send --workspace "backend" --tab 0 "pwd\n"
termplex-ctl surface send --workspace "backend" --tab 0 "ls\n"
termplex-ctl surface read --workspace "backend" --tab 0 --lines 80
```

## Output

Commands return JSON by default:

```json
{"ok": true, "result": {...}, "id": 1}
{"ok": false, "error": {"code": "...", "message": "..."}, "id": 1}
```

Use human-readable output when needed:

```bash
termplex-ctl --human workspace list
```

## Guidelines

- Register on startup and unregister on exit.
- Prefer explicit `--workspace` and `--tab` flags.
- Use `orchestrator status` for global context; use `workspace list`/`status` for focused live navigation; do not read `state.json` for counts.
- Re-run `tab list` after creating or closing tabs because indices can shift.
- Use `surface read` as the main way to inspect live terminal state.
- Use `agent list` before creating another agent tab for the same task.
- Use `surface send` with `\n` to press Enter.
- Never close the `Orchestrator` workspace.
- Treat `Orchestrator` as the reserved orchestration workspace name.
