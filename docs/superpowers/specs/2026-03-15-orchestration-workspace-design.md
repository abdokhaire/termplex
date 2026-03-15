# Orchestration Workspace Design Spec

## Overview

The Orchestration Workspace is a special, always-pinned workspace in Termplex that runs an AI agent (Claude Code, Codex, or a custom CLI) capable of managing all other workspaces, tabs, and terminals. It communicates with Termplex via a CLI tool (`termplex-ctl`) that talks to the existing Unix socket IPC. AI agents learn to use the CLI through a skill file installed in a configurable orchestration directory.

## Goals

- Let an AI agent create, manage, and interact with all Termplex workspaces and terminals
- Support multiple AI CLI backends (Claude Code, Codex, custom) via config
- Provide agent discovery so the orchestration agent can find and communicate with agents in other workspaces
- Keep architecture simple: CLI tool + Unix socket + skill file, no embedded agent runtime

## Non-Goals

- MCP server integration (future work, can layer on top)
- Custom chat UI for the orchestration workspace (it's a regular terminal running the agent CLI)
- Background agent monitoring daemon (discovery is on-demand)
- Windows support (Termplex is Linux-only)

---

## Sub-Project Decomposition

This feature decomposes into 5 independent sub-projects, built in order:

1. **IPC protocol extensions + `termplex-ctl` CLI** — foundation layer
2. **Orchestration workspace in sidebar + config** — UI and persistence
3. **First-run GTK dialog** — onboarding
4. **Skill file + agent registration** — AI agent integration
5. **Terminal interaction (`surface.send` / `surface.read`)** — PTY injection and screen reading

Each sub-project produces working, testable software independently.

### Dependencies

```
1. IPC + CLI ──┬──→ 2. Workspace + Config ──→ 3. First-run Dialog
               │
               ├──→ 4. Skill file + Agent registration
               │
               └──→ 5. surface.send / surface.read
```

Sub-projects 2, 4, and 5 depend on 1 (IPC foundation) but are independent of each other. Sub-project 3 depends on 2 (needs config infrastructure).

---

## 1. IPC Protocol Extensions

### Existing Protocol

The Unix socket server at `$XDG_RUNTIME_DIR/termplex.sock` accepts newline-delimited JSON:

```json
Request:  {"method": "workspace.list", "params": {}, "id": 1}
Success:  {"ok": true, "result": ..., "id": 1}
Error:    {"ok": false, "error": {"code": "...", "message": "..."}, "id": 1}
```

Existing methods (non-exhaustive): `system.ping`, `system.tree`, `workspace.list`, `workspace.create`, `workspace.select`, `workspace.close`, `workspace.rename`, `workspace.find_by_dir`, `surface.list`, `surface.create`, `surface.split`, `surface.close`, `surface.focus`, `notification.*`, `status.*`. Note: some methods (e.g., `workspace.rename`, `workspace.close`) are currently stubs in `ipcDispatch` and may need full implementation.

### New Methods

#### Tab Operations

**`tab.list`** — List tabs in a workspace.

```json
Request:  {"method": "tab.list", "params": {"workspace": "backend"}, "id": 1}
Response: {"ok": true, "result": {"tabs": [
  {"index": 0, "title": "editor", "surface_count": 1},
  {"index": 1, "title": "server", "surface_count": 2}
]}, "id": 1}
```

`workspace` accepts a name (string) or index (integer).

**`tab.create`** — Create a new tab in a workspace.

```json
Request:  {"method": "tab.create", "params": {
  "workspace": "backend",
  "title": "tests",
  "dir": "/home/user/projects/backend",
  "command": "npm test"
}, "id": 2}
Response: {"ok": true, "result": {"index": 2, "title": "tests"}, "id": 2}
```

All params except `workspace` are optional. `command` is executed in the new tab's shell. `dir` sets the working directory. `title` sets the tab title.

#### Terminal Interaction

**`surface.send`** — Send text to a terminal's PTY (keystroke injection).

```json
Request:  {"method": "surface.send", "params": {
  "workspace": "backend",
  "tab": 0,
  "text": "npm test\n"
}, "id": 3}
Response: {"ok": true, "result": {}, "id": 3}
```

The `text` field is written directly to the PTY. Include `\n` to simulate pressing Enter. `tab` is the tab index (0-based). An optional `surface` parameter (0-based index within the tab) can target a specific split pane. If omitted and the tab has multiple surfaces, sends to the last-focused surface in that tab (tracked per-tab, not dependent on the workspace being active).

**`surface.read`** — Read recent terminal output.

```json
Request:  {"method": "surface.read", "params": {
  "workspace": "backend",
  "tab": 0,
  "lines": 50
}, "id": 4}
Response: {"ok": true, "result": {"output": "...(last 50 lines)..."}, "id": 4}
```

Reads from the terminal's screen buffer. Default is 50 lines if `lines` is omitted. Maximum 1000 lines. ANSI escape sequences are stripped from the output — only plain text is returned. Non-UTF-8 bytes are replaced with the Unicode replacement character (U+FFFD). Lines are separated by `\n` in the returned string.

#### Agent Tracking

**`agent.register`** — Register an AI agent running in a terminal.

```json
Request:  {"method": "agent.register", "params": {
  "workspace": "backend",
  "tab": 0,
  "type": "claude",
  "pid": 12345
}, "id": 5}
Response: {"ok": true, "result": {"agent_id": "a1b2c3"}, "id": 5}
```

`type` is one of: `"claude"`, `"codex"`, `"custom"`. `pid` is the agent process PID for lifecycle tracking.

**`agent.list`** — List all registered agents.

```json
Request:  {"method": "agent.list", "params": {}, "id": 6}
Response: {"ok": true, "result": {"agents": [
  {"agent_id": "a1b2c3", "workspace": "backend", "tab": 0, "type": "claude", "pid": 12345, "alive": true},
  {"agent_id": "d4e5f6", "workspace": "frontend", "tab": 1, "type": "codex", "pid": 12346, "alive": false}
]}, "id": 6}
```

The `alive` field is checked by testing if the PID is still running. Stale entries (where `alive` is false) are cleaned up automatically.

**`agent.unregister`** — Remove an agent from the registry.

```json
Request:  {"method": "agent.unregister", "params": {"pid": 12345}, "id": 7}
Response: {"ok": true, "result": {}, "id": 7}
```

**`agent.terminate`** — Terminate an agent process.

```json
Request:  {"method": "agent.terminate", "params": {"pid": 12345}, "id": 8}
Response: {"ok": true, "result": {}, "id": 8}
```

Sends SIGTERM to the process. An optional `policy` parameter (`"keep"` or `"terminate"`) overrides the global `agent_terminate_policy` config for this call. If omitted, falls back to the config value. `"terminate"` closes the tab after killing the process; `"keep"` leaves the tab open.

### Implementation Notes

- New methods are added to the `ipcDispatch` function in `src/apprt/gtk/class/application.zig` (the live IPC dispatch — note: `src/termplex/ipc/protocol.zig` contains stubs and is not wired into the live application)
- Tab operations require access to the Application's workspace state (TabView, tab pages)
- `surface.send` uses `Termio.queueWrite()` to write to the PTY
- `surface.read` reads from the terminal's screen buffer (page/pagelist)
- Tab indices are positional (0-based) within the `AdwTabView` — they shift when tabs are closed. The skill file should instruct agents to re-query `tab.list` after closing tabs to get updated indices.
- Agent registry is an in-memory `std.ArrayListUnmanaged` in Application, persisted to `<orchestration_dir>/state/agents.json`

### Agent Registry Persistence Format (`agents.json`)

```json
{
  "agents": [
    {
      "agent_id": "a1b2c3",
      "workspace": "backend",
      "tab": 0,
      "type": "claude",
      "pid": 12345,
      "registered_at": "2026-03-15T10:30:00Z"
    }
  ]
}
```

On startup, stale entries (where the PID is no longer running) are removed before loading. Writes use atomic rename (`write to .tmp`, then `rename`) to prevent corruption.

---

## 2. `termplex-ctl` CLI Tool

A Python 3 script installed at `zig-out/bin/termplex-ctl` (and `<prefix>/bin/termplex-ctl` on install). It connects to the Unix socket, sends JSON requests, and prints responses.

### Socket Discovery

Resolution order:
1. `$TERMPLEX_SOCKET` environment variable
2. `$XDG_RUNTIME_DIR/termplex.sock`
3. `/tmp/termplex-$(id -u).sock`

### Commands

```
termplex-ctl workspace list
termplex-ctl workspace create [--name NAME] [--dir DIR]
termplex-ctl workspace select (--name NAME | --index N)
termplex-ctl workspace close (--name NAME | --index N)
termplex-ctl workspace rename --name NAME --new-name NEWNAME

termplex-ctl tab list --workspace WORKSPACE
termplex-ctl tab create --workspace WORKSPACE [--title TITLE] [--dir DIR] [--command CMD]

termplex-ctl surface send --workspace WORKSPACE --tab N TEXT
termplex-ctl surface read --workspace WORKSPACE --tab N [--lines N]

termplex-ctl agent register --workspace WORKSPACE --tab N --type TYPE --pid PID
termplex-ctl agent list
termplex-ctl agent unregister --pid PID
termplex-ctl agent terminate --pid PID

termplex-ctl ping
termplex-ctl status
```

### Output

- Default: JSON (for machine consumption by AI agents)
- `--human` flag: formatted, human-readable output
- Exit code 0 on success, 1 on error

### Implementation

- Single Python 3 file, no external dependencies (uses `socket`, `json`, `argparse` from stdlib)
- ~300-400 lines of code
- Installed by the Zig build system as a data file copied to bin/

---

## 3. Orchestration Workspace

### Sidebar Behavior

- Always the **first item** in the sidebar workspace list
- Visually separated from user workspaces by a horizontal divider line below it
- Label: **"ORCHESTRATOR"** styled with the brand accent color (`#00d4ff`)
- Cannot be reordered, renamed, or deleted (context menu actions disabled for this workspace)
- Shows a distinct indicator (gear/settings icon or similar) to the left of the label

### Terminal Behavior

- When switched to for the first time in a session, auto-launches the configured agent CLI command
- Working directory: the orchestration directory (e.g., `~/.termplex/orchestration/`)
- The agent command is read from config: `orchestration.agent_command` (default: `"claude"`)
- If the agent process exits:
  - `agent_terminate_policy = "keep"` (default): terminal stays open, user can restart manually
  - `agent_terminate_policy = "terminate"`: tab is closed

### Persistence

- The orchestration workspace is **not** saved in the regular session JSON (`session.json`)
- It is recreated on every app launch when `orchestration.enabled = true`
- Orchestration-specific state (e.g., was it the active workspace when the app closed) is saved to `<orchestration_dir>/state/orchestrator.json`

### Implementation Notes

- In `application.zig`, the orchestration workspace is created before restoring user workspaces
- It uses the same `AdwTabView` mechanism as regular workspaces
- The sidebar widget (`sidebar.zig`) checks if index 0 is the orchestrator and renders it differently
- The orchestrator workspace index is stored in Application private state: `orchestration_workspace_idx: ?u32`

---

## 4. Configuration

### New Config Options

Added to `src/termplex/core/config.zig` and written to the Termplex-specific config at `~/.config/termplex/config.toml` (not the Ghostty-inherited `config.termplex`):

```toml
[orchestration]
enabled = false                              # Enable orchestration workspace
dir = "~/.termplex/orchestration"            # Orchestration data directory
agent_command = "claude"                     # CLI command to launch in orchestration workspace
agent_terminate_policy = "keep"              # "keep" or "terminate"
```

The `enabled` field uses `?bool` (optional bool) in the config struct so the parser can distinguish "key absent" (show first-run dialog) from "explicitly set to `false`" (don't show dialog). When the key is absent, `enabled` is `null`; the first-run dialog checks for `null`, not `false`.

### Orchestration Directory Structure

```
~/.termplex/orchestration/
├── AGENTS.md                # Codex-compatible instructions (root for auto-discovery)
├── skill/
│   └── termplex.md          # Claude Code skill file
├── logs/
│   └── orchestration.log    # Log of orchestration actions
└── state/
    ├── orchestrator.json    # Orchestration workspace state
    └── agents.json          # Registered agent registry
```

---

## 5. First-Run GTK Dialog

### Trigger

On application startup, if `orchestration.enabled` is `null` in the parsed config (key absent from `config.toml`), show the dialog. If the user has explicitly set `orchestration.enabled = false`, do not show it again.

### Dialog Design

- **Title:** "Enable Orchestration?"
- **Body:** "Termplex can run an AI agent that manages your workspaces, tabs, and terminal sessions. Choose a directory to store orchestration data, or skip to set this up later."
- **Directory picker:** File chooser button, default `~/.termplex/orchestration/`
- **Agent CLI dropdown:** "Claude Code" / "Codex" / "Custom..." (text entry for custom command)
  - "Claude Code" maps to command `claude`
  - "Codex" maps to command `codex`
  - "Custom..." reveals a text entry for arbitrary command
- **Buttons:** "Enable" (primary action) and "Skip" (secondary)

### On Enable

1. Create the orchestration directory structure (subdirs: `skill/`, `logs/`, `state/`)
2. Write the `termplex.md` skill file to `skill/` and `AGENTS.md` to the orchestration directory root (for Codex auto-discovery)
3. Write `orchestration.enabled = true`, `orchestration.dir`, and `orchestration.agent_command` to `~/.config/termplex/config.toml`
4. Show a follow-up info dialog: "Orchestration enabled. Add the skill file at `<path>/skill/termplex.md` to your AI agent's configuration."
5. Create the orchestration workspace in the sidebar

### On Skip

1. Write `orchestration.enabled = false` to `~/.config/termplex/config.toml`
2. Dismiss the dialog, continue with normal startup

---

## 6. Claude Code Skill File (`termplex.md`)

A markdown file that teaches AI agents how to control Termplex. Installed at `<orchestration_dir>/skill/termplex.md`.

### Content Structure

```markdown
# Termplex Orchestration Skill

## What is Termplex?
Brief description of Termplex and the orchestration model.

## Setup
On startup, register yourself (use your own PID, not the shell's $$):
  termplex-ctl agent register --workspace "orchestrator" --tab 0 --type claude --pid <your_pid>

## Commands Reference
Full termplex-ctl command list with examples.

## Workflow Patterns

### Create a development workspace
  termplex-ctl workspace create --name "backend" --dir ~/projects/backend
  termplex-ctl tab create --workspace "backend" --title "editor" --command "nvim"
  termplex-ctl tab create --workspace "backend" --title "server" --command "npm run dev"
  termplex-ctl tab create --workspace "backend" --title "tests"

### Run a command and check output
  termplex-ctl surface send --workspace "backend" --tab 2 "npm test"
  sleep 5
  termplex-ctl surface read --workspace "backend" --tab 2 --lines 30

### Check all running agents
  termplex-ctl agent list

### Launch a new agent in a workspace
  termplex-ctl tab create --workspace "backend" --title "code-review" --command "claude"
  termplex-ctl agent register --workspace "backend" --tab 3 --type claude --pid $(...)

## Guidelines
- Always register yourself as an agent on startup
- Always unregister on exit
- Use --workspace and --tab flags explicitly (don't rely on defaults)
- Parse JSON output for reliable results
- Check agent.list for stale entries before spawning duplicates
```

### Codex Compatibility (`AGENTS.md`)

Same content adapted for Codex's conventions — placed in the orchestration directory root as `AGENTS.md` so Codex auto-discovers it.

---

## 7. Agent Discovery & Management

### Registration

- AI agents register themselves via `termplex-ctl agent register` (instructed by the skill file)
- Registration stored in Application memory and persisted to `<orchestration_dir>/state/agents.json`
- Each registration records: `agent_id` (generated UUID), `workspace`, `tab`, `type`, `pid`, `registered_at`

### Discovery

- On-demand only — the orchestration agent calls `termplex-ctl agent list` when it needs to know what's running
- The response includes an `alive` field: Termplex checks `kill(pid, 0)` to verify the process exists
- Dead agents are automatically removed from the registry on list queries

### Communication

- The orchestration agent communicates with workspace agents via PTY injection: `termplex-ctl surface send --workspace X --tab Y "message"`
- It reads responses via `termplex-ctl surface read --workspace X --tab Y --lines N`
- This is intentionally simple — it types into the terminal and reads the screen, exactly as a user would

### Termination

- `termplex-ctl agent terminate --pid PID` sends SIGTERM
- `agent_terminate_policy` config controls whether the tab is also closed:
  - `"keep"` (default): terminal stays open, shows agent exit
  - `"terminate"`: tab is closed automatically

---

## Data Flow

```
User ↔ Orchestration Workspace (terminal running Claude Code)
         │
         │ runs shell commands
         ▼
    termplex-ctl (Python CLI)
         │
         │ JSON over Unix socket
         ▼
    Termplex IPC Socket Server
         │
         ├── workspace.create/select/close/...
         ├── tab.list/create
         ├── surface.send/read
         └── agent.register/list/unregister/terminate
         │
         ▼
    Application State (workspaces, tabs, surfaces, agent registry)
         │
         ├── GTK UI updates (sidebar, tabs)
         ├── PTY writes (surface.send)
         ├── Screen buffer reads (surface.read)
         └── Persistence (session.json, agents.json)
```

---

## File Changes Summary

| Area | Files |
|------|-------|
| IPC dispatch | `src/apprt/gtk/class/application.zig` (add to `ipcDispatch`: tab.*, surface.send/read, agent.*) |
| Tab IPC handlers | `src/apprt/gtk/class/application.zig` (add ipcTabList, ipcTabCreate) |
| Surface IPC handlers | `src/apprt/gtk/class/application.zig` (add ipcSurfaceSend, ipcSurfaceRead) |
| Agent registry | `src/termplex/ipc/agents.zig` (new file) |
| Config | `src/termplex/core/config.zig` (add orchestration section) |
| Orchestration workspace | `src/apprt/gtk/class/application.zig` (create on startup) |
| Sidebar rendering | `src/apprt/gtk/class/sidebar.zig` (orchestrator styling) |
| First-run dialog | `src/apprt/gtk/class/application.zig` (add dialog on activate) |
| CLI tool | `tools/termplex-ctl` (new Python script) |
| Skill file | `tools/skill/termplex.md` (new, copied to orchestration dir) |
| Codex compat | `tools/skill/AGENTS.md` (new, copied to orchestration dir) |
| Build system | `build.zig` or `src/build/TermplexResources.zig` (install CLI + skill) |
