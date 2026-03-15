# Termplex Orchestration Skill

## What is Termplex?

Termplex is a workspace-centric terminal multiplexer. You are running inside the Orchestration Workspace — a special workspace that lets you manage all other workspaces, tabs, and terminals.

You control Termplex using the `termplex-ctl` CLI tool, which communicates with Termplex over a Unix socket.

## Setup

On startup, register yourself as an agent:

```bash
termplex-ctl agent register --workspace "ORCHESTRATOR" --tab 0 --type claude --pid <your_pid>
```

On exit, unregister:

```bash
termplex-ctl agent unregister --pid <your_pid>
```

## Commands Reference

### Workspace Management

```bash
termplex-ctl workspace list                                    # List all workspaces
termplex-ctl workspace create --name "backend" --dir ~/proj    # Create workspace
termplex-ctl workspace select --name "backend"                 # Switch to workspace
termplex-ctl workspace select --index 1                        # Switch by index
termplex-ctl workspace close --name "backend"                  # Close workspace
termplex-ctl workspace rename --name "old" --new-name "new"    # Rename workspace
```

### Tab Management

```bash
termplex-ctl tab list --workspace "backend"                                    # List tabs
termplex-ctl tab create --workspace "backend" --title "editor" --command vim   # Create tab with command
termplex-ctl tab create --workspace "backend" --dir ~/proj/tests               # Create tab with dir
```

### Terminal Interaction

```bash
termplex-ctl surface send --workspace "backend" --tab 0 "npm test\n"   # Send text (\n = Enter)
termplex-ctl surface read --workspace "backend" --tab 0 --lines 30     # Read terminal output
```

### Agent Management

```bash
termplex-ctl agent list                                                        # List all agents
termplex-ctl agent register --workspace "backend" --tab 0 --type claude --pid 1234   # Register
termplex-ctl agent unregister --pid 1234                                       # Unregister
termplex-ctl agent terminate --pid 1234                                        # Kill agent
```

### Utility

```bash
termplex-ctl ping       # Check if Termplex is running
termplex-ctl status     # Get system status
```

## Workflow Patterns

### Create a development workspace

```bash
termplex-ctl workspace create --name "backend" --dir ~/projects/backend
termplex-ctl tab create --workspace "backend" --title "editor" --command "nvim"
termplex-ctl tab create --workspace "backend" --title "server" --command "npm run dev"
termplex-ctl tab create --workspace "backend" --title "tests"
```

### Run a command and check output

```bash
termplex-ctl surface send --workspace "backend" --tab 2 "npm test\n"
sleep 5
termplex-ctl surface read --workspace "backend" --tab 2 --lines 30
```

### Launch a sub-agent in a workspace

```bash
termplex-ctl tab create --workspace "backend" --title "code-review" --command "claude"
termplex-ctl agent list  # Check it registered
```

### Check all running agents

```bash
termplex-ctl agent list
```

## Output Format

All commands return JSON by default:

```json
{"ok": true, "result": {...}, "id": 1}
{"ok": false, "error": {"code": "...", "message": "..."}, "id": 1}
```

Add `--human` for readable output: `termplex-ctl --human workspace list`

## Guidelines

- Always register yourself as an agent on startup
- Always unregister on exit
- Use `--workspace` and `--tab` flags explicitly
- Parse JSON output for reliable automation
- Tab indices shift when tabs are closed — re-query `tab list` after closing tabs
- Check `agent list` before spawning duplicate agents
- Use `surface send` with `\n` to simulate pressing Enter
- `surface read` returns plain text (ANSI escapes stripped)
