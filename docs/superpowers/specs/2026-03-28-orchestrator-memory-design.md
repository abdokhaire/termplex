# Orchestrator Memory System — Design Spec

**Date:** 2026-03-28
**Status:** Approved
**Approach:** Structured State (JSON) + Markdown Knowledge (Approach B)

## Overview

Add persistent memory to the Termplex orchestrator so it remembers what was running in each workspace across restarts and accumulates knowledge over time. On startup, the orchestrator proposes a resume plan with a single confirmation prompt, then restarts services.

Inspired by OpenClaw's memory architecture (file-based knowledge persistence, agent-driven knowledge writes, pre-shutdown memory flush) adapted for a terminal multiplexer context.

## Goals

1. **Running process tracking** — Know what commands were active in each workspace terminal at shutdown
2. **Workspace context** — Know what project each workspace is for, tech stack, ports, common commands
3. **Long-term knowledge** — Accumulate learned facts over time (user preferences, project quirks, patterns)
4. **Auto-resume with confirmation** — On startup, propose resuming previous services with a single Y/n prompt

## Non-Goals (v1)

- Session history / decision logs (future: daily logs like OpenClaw's memory/YYYY-MM-DD.md)
- Heartbeat / health monitoring (future: periodic check-ins while running)
- Semantic search / embeddings (future: can be layered on top of Markdown files)
- Cross-machine sync

## Architecture: Two-Layer Memory

### Layer 1: Structured State (JSON) — "What was happening"

Machine-readable snapshots of workspace runtime state. Updated automatically by shell hooks and process inspection.

**Files:**
- ~/.termplex/orchestration/state.json — Global process state (all workspaces)
- <workspace_dir>/.termplex/state.json — Per-workspace process state (travels with project)

**Global state.json schema (v1):**

```json
{
  "version": 1,
  "last_updated": "<ISO 8601 timestamp>",
  "last_shutdown": "<ISO 8601 timestamp | null>",
  "workspaces": {
    "<workspace_name>": {
      "dir": "<absolute path>",
      "surfaces": {
        "<surface_uuid>": {
          "working_directory": "<absolute path>",
          "last_command": "<full command string>",
          "command_started_at": "<ISO 8601 timestamp>",
          "process_pid": "<int>",
          "process_alive": "<bool>",
          "detection_method": "shell_hook | proc_inspection",
          "ports": ["<int>"]
        }
      }
    }
  }
}
```

**Per-workspace .termplex/state.json** mirrors the surfaces portion for that workspace only:

```json
{
  "version": 1,
  "workspace_name": "<string>",
  "last_updated": "<ISO 8601 timestamp>",
  "last_shutdown": "<ISO 8601 timestamp | null>",
  "surfaces": {
    "<surface_uuid>": {
      "working_directory": "<absolute path>",
      "last_command": "<full command string>",
      "command_started_at": "<ISO 8601 timestamp>",
      "process_pid": "<int>",
      "process_alive": "<bool>",
      "detection_method": "shell_hook | proc_inspection",
      "ports": ["<int>"]
    }
  }
}
```

### Layer 2: Knowledge Memory (Markdown) — "What I've learned"

Human-readable and AI-readable knowledge that the orchestrator accumulates over time. Written by the orchestrator agent itself.

**Files:**
- ~/.termplex/orchestration/MEMORY.md — Global knowledge (cross-workspace facts, user preferences, patterns)
- <workspace_dir>/.termplex/memory.md — Per-workspace knowledge (tech stack, common commands, known issues)

**Global MEMORY.md example:**

```markdown
# Orchestrator Knowledge

## Workspace Patterns
- "backend" and "frontend" usually run together — start backend first
- Port 3000 conflicts between "frontend" and "docs" — never run both simultaneously

## User Preferences
- Ahmed prefers to see build output, not have it silenced
- Always run tests before committing in the backend workspace
```

**Per-workspace memory.md example:**

```markdown
# Backend Project

## Stack
- Python 3.11, Django 4.2, PostgreSQL
- Virtual env at .venv/, activate with source .venv/bin/activate

## Common Commands
- Dev server: python manage.py runserver 0.0.0.0:8000
- Tests: pytest -v --tb=short

## Known Issues
- Port 8000 sometimes stays bound after crash — use fuser -k 8000/tcp
```

## Data Flow: How State Gets Captured

### Mechanism 1: Shell Integration Hooks (Primary)

Extend the existing shell integration hooks to emit additional OSC escape sequences for command tracking. The `__termplex_preexec` and `__termplex_precmd` functions already exist in `src/shell-integration/bash/termplex.bash` (and equivalents for other shells) for semantic prompt marking (OSC 133). We add OSC 7337 emissions to these existing functions — not new functions.

**OSC 7337 protocol** (private-use range, no known conflicts with iTerm2/Kitty/WezTerm/Ghostty OSC sequences):

```
Command start:  ESC ] 7337 ; cmd_start ; <shell_pid> ; <command_string> BEL
Command end:    ESC ] 7337 ; cmd_end ; <shell_pid> ; <exit_code> BEL
```

**Bash implementation (extend existing hooks in src/shell-integration/bash/termplex.bash):**

```bash
# Added to the existing __termplex_preexec function (do NOT create a new function)
__termplex_preexec() {
    # ... existing OSC 133 prompt marking code ...
    # NEW: report command to state manager
    printf '\e]7337;cmd_start;%s;%s\a' "$$" "$1"
}

# Added to the existing __termplex_precmd function (do NOT create a new function)
__termplex_precmd() {
    local exit_code=$?
    # ... existing OSC 133 prompt marking code ...
    # NEW: report command completion to state manager
    printf '\e]7337;cmd_end;%s;%d\a' "$$" "$exit_code"
}
```

Similar extensions for zsh (preexec/precmd), fish (fish_preexec/fish_postexec), elvish, and nushell — all extend existing hook functions.

The terminal surface receives these OSC sequences, parses them, and forwards command start/end events to the state manager.

**Shell PID to surface mapping:** Each terminal surface owns a PTY with a known child shell PID (the surface spawns the shell process and tracks its PID). When an OSC 7337 sequence arrives on a surface's PTY, the surface already knows its own identity — it forwards the event to the state manager tagged with the surface's UUID (from `getOrCreateSurfaceUuid()`, the same UUID system used by session persistence). No PID-to-surface lookup table is needed; the surface receiving the OSC sequence IS the surface.

**Data captured via shell hooks:**
- Exact command string
- Start/end timing
- Exit code
- Surface identity (implicit from which surface received the OSC sequence)

### Mechanism 2: Process Tree Inspection (Fallback)

For terminals without shell integration, a periodic scan (configurable, default 30s) checks child processes under each surface's PTY by reading /proc/<pid>/cmdline.

```
Surface PTY (e.g., /dev/pts/3)
  -> bash (PID 1234)
       -> python manage.py runserver (PID 1235)  <- captured
```

The detection_method field in state.json records which method captured each entry ("shell_hook" vs "proc_inspection").

**Limitations vs shell hooks:**
- No command timing or exit codes
- Only sees currently running processes
- Command strings may be truncated (procfs limitation)

### Mechanism 3: State Persistence

The state manager writes to disk:
- **On every command start/end** — incremental update (debounced, max once per second)
- **Every 30 seconds** — full state snapshot (aligned with proc inspection cycle)
- **On graceful shutdown** — final snapshot with last_shutdown timestamp, all processes marked process_alive: false
- **Atomic writes** — .tmp then rename pattern (same as existing session.json)

Per-workspace .termplex/state.json is synced whenever the global state updates for that workspace.

### Data Flow Diagram

```
Terminal Surface (bash/zsh/fish)
    |
    |-- [shell hook] --OSC 7337--> Surface widget
    |                                   |
    |                              parses OSC seq
    |                                   |
    +-- [no shell hook] ---------> Proc Inspector (30s timer)
                                        |
                                   reads /proc
                                        |
                            +-----------+-----------+
                            v                       v
                    State Manager            State Manager
                    (cmd_start/end)         (process snapshot)
                            |                       |
                            +-------+---------------+
                                    v
                        +--- Debounced Write ---+
                        v                       v
              global state.json      per-workspace state.json
```

## Startup Resume Flow

### Step 1: State Loading

On application startup, before the orchestrator agent process starts, the Zig application:
1. Loads ~/.termplex/orchestration/state.json
2. Checks for last_shutdown timestamp (graceful vs crash)
3. Identifies workspaces with previously running processes
4. Builds a resume manifest — structured text for injection into orchestrator context

### Step 2: Resume Manifest Injection

The orchestrator agent's initial context is augmented with:

```
=== TERMPLEX ORCHESTRATOR CONTEXT ===

## Previous Session State
Last session ended: 2026-03-28T14:30:00Z (graceful shutdown)

### Workspace: backend (/home/ahmed/projects/backend)
Surfaces with active processes at shutdown:
- Surface a1b2c3d4: python manage.py runserver 0.0.0.0:8000 (running 2h30m, ports: 8000)
- Surface b2c3d4e5: idle (last command: pytest -v, exited 0)

### Workspace: frontend (/home/ahmed/projects/frontend)
Surfaces with active processes at shutdown:
- Surface e5f6g7h8: npm run dev (running 2h25m, ports: 3000, 3001)

## Global Knowledge
<contents of ~/.termplex/orchestration/MEMORY.md>

## Workspace Knowledge
### backend
<contents of ~/projects/backend/.termplex/memory.md>
### frontend
<contents of ~/projects/frontend/.termplex/memory.md>
```

### Step 3: Orchestrator Resume Proposal

The orchestrator's system prompt includes:

> "You have memory of the previous session. Review the state and propose a resume plan. List the services that were running and ask the user for confirmation before restarting them. Use a single confirmation prompt."

Example output:

```
Welcome back! Your last session ended at 2:30 PM today.

I found 2 services that were running:
  1. backend -> python manage.py runserver 0.0.0.0:8000 (port 8000)
  2. frontend -> npm run dev (ports 3000, 3001)

Resume all? [Y/n]
```

### Step 4: Execution

On confirmation, the orchestrator uses existing workspace command capabilities to re-run commands in the correct surfaces, update state.json with new PIDs, and report completion.

### Crash Recovery

If no last_shutdown timestamp exists:
- The orchestrator notes the unexpected termination
- Still proposes resume, but warns state may be stale
- All previous PIDs are assumed dead

## Knowledge Memory: How MEMORY.md Gets Written

### Write Triggers

1. **Explicit user request** — "Remember that the backend needs Redis running first"
2. **Pre-shutdown memory flush** — Before terminating the orchestrator on app close, send prompt: "Session ending. Write any durable knowledge to memory files. If nothing new, do nothing."
3. **Orchestrator judgment** — During normal conversation, the orchestrator independently writes reusable facts it discovers

### Writing Rules

- Append new facts, don't rewrite entire file
- Deduplicate — check if fact already exists
- Keep entries concise (1-2 lines per fact)
- Use Markdown headers to organize by category
- Per-workspace .termplex/ directory created on first write
- .termplex/ added to .gitignore (orchestrator suggests this)

### File Size Management

- No automatic truncation — files expected to stay small with concise entries
- If a file exceeds ~500 lines, orchestrator is prompted to consolidate

### What Is NOT Written to Memory

- Transient state (belongs in state.json)
- Full command history (shell history handles this)
- Terminal scrollback content
- Anything the user asks to forget

## Integration Points

### New Files

```
src/termplex/core/memory/
  state_manager.zig       — state.json reads/writes, debouncing, atomic persistence
  process_inspector.zig   — /proc-based fallback process detection (30s timer)
  resume_manifest.zig     — Builds resume context string for orchestrator injection
  memory_paths.zig        — Resolves paths for global + per-workspace memory/state files
```

### Shell Integration Extensions (modify existing hook functions)

```
src/shell-integration/
  bash/termplex.bash      — Extend existing __termplex_preexec / __termplex_precmd with OSC 7337
  zsh/termplex.zsh        — Extend existing preexec / precmd hooks with OSC 7337
  fish/termplex.fish      — Extend existing fish_preexec / fish_postexec with OSC 7337
  elvish/                 — Extend if feasible
  nushell/                — Extend if feasible
```

### Existing Files to Modify

| File | Change |
|------|--------|
| src/apprt/gtk/class/surface.zig | Parse OSC 7337 sequences, forward command events to state manager |
| src/apprt/gtk/class/application.zig | Initialize state manager on startup; trigger pre-shutdown memory flush; load resume manifest before orchestrator workspace creation |
| src/termplex/core/config.zig | Add memory config section |
| src/apprt/gtk/class/application.zig (restoreSession) | Inject resume manifest into orchestrator's initial context |
| src/apprt/gtk/class/application.zig (onShutdown) | Send memory flush prompt before terminating orchestrator; write final state.json |

### OSC Sequence Registration

Register OSC 7337 handler in terminal escape sequence parser. Routes parsed events to state manager.

### Configuration

New `Memory` struct in `src/termplex/core/config.zig` (following the existing pattern of `Session`, `Orchestration` structs), exposed as `[memory]` section in `~/.config/termplex/config.toml`:

```toml
[memory]
enabled = true
auto_resume = true
flush_on_shutdown = true
proc_inspect_interval = 30
```

The global state.json path respects the configured `orchestration.dir` — it is stored at `<orchestration.dir>/state.json` (default: `~/.termplex/orchestration/state.json`).

### Relationship to Existing Session Persistence

The memory system is separate from session.json:

| System | Purpose | Managed by |
|--------|---------|------------|
| session.json | Layout, tabs, splits, working directories | GTK app (Zig) |
| state.json | Running processes, commands, ports | State manager (Zig) |
| MEMORY.md / memory.md | Accumulated knowledge | Orchestrator agent (AI) |

Session restore happens first (workspaces and tabs recreated), then the orchestrator starts with its memory context loaded.

## Future Extensions (Not in v1)

- **Session history logs** — Daily memory/YYYY-MM-DD.md logs of orchestrator actions
- **Heartbeat monitoring** — Periodic health checks on running services
- **Semantic search** — Embeddings-based retrieval over memory files (layer on top of Markdown)
- **Memory consolidation prompts** — Scheduled prompts asking orchestrator to review and summarize old knowledge
- **Cross-machine sync** — Sync global MEMORY.md across machines
