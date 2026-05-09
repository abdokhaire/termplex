# Orchestrator State Unification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a unified orchestrator status command backed by live IPC plus SQLite, and deprecate `state.json` as an agent-facing source of truth.

**Architecture:** Keep GTK `Application` runtime state authoritative for live workspace membership. Extend SQLite surface records with runtime process snapshot fields and expose a composed `orchestrator.status` IPC response through `termplex-ctl orchestrator status`.

**Tech Stack:** Zig 0.15.2, GTK application IPC, existing `terminal_history_db.zig` SQLite wrapper, Python `tools/termplex-ctl`.

---

## File Structure

- Modify `src/termplex/core/terminal_history_db.zig`: add runtime surface fields, schema migration, upsert/query support, and focused tests.
- Modify `src/termplex/core/memory/state_manager.zig`: write process runtime fields to SQLite when shell command events arrive.
- Modify `src/termplex/core/memory/resume_manifest.zig`: add SQLite resume-candidate input and tests.
- Modify `src/apprt/gtk/class/application.zig`: add `orchestrator.status` IPC handler that composes live, durable, agent, and storage sections.
- Modify `tools/termplex-ctl`: add `orchestrator status` CLI mapping.
- Modify `tools/skill/AGENTS.md` and `tools/skill/termplex.md`: document the new command and direct agents away from JSON state files.

## Task 1: SQLite Runtime Snapshot

- [ ] Add failing `terminal_history_db.zig` tests named `surface runtime snapshot fields round trip` and `resume candidates include only alive surfaces`.
- [ ] Run `/opt/zig-x86_64-linux-0.15.2/zig test src/termplex/core/terminal_history_db.zig --test-filter "surface runtime snapshot fields round trip"` and confirm it fails because fields/query are missing.
- [ ] Add optional runtime fields to `SurfaceUpsert` and `SurfaceRecord`.
- [ ] Extend schema creation/migration with nullable runtime columns.
- [ ] Update `upsertSurface`, `getSurface`, and any surface row mapping helpers.
- [ ] Add `ResumeCandidate`, `ResumeCandidateList`, and `listResumeCandidates`.
- [ ] Run the two focused SQLite tests and keep them passing.

## Task 2: State Manager Writes Runtime Fields To SQLite

- [ ] Add a failing state-manager test that sends a command start event, then reads the SQLite surface record and expects `process_alive = true`, `last_command`, `command_started_at`, and `detection_method = "shell_hook"`.
- [ ] Run the focused test and confirm it fails.
- [ ] Update `forwardCommandEventToDatabase` to pass runtime snapshot fields into `upsertSurface`.
- [ ] On command exit, update the same surface with `process_alive = false` while preserving the last command.
- [ ] Run the focused state-manager test and existing command-history forwarding tests.

## Task 3: Resume Manifest Uses SQLite Candidates

- [ ] Add a failing `resume_manifest.zig` test that builds a manifest from one alive SQLite candidate and one dead candidate source that was filtered out before the call.
- [ ] Run the focused test and confirm it fails.
- [ ] Add a manifest helper that accepts `[]terminal_history_db.ResumeCandidate` and writes only active process entries.
- [ ] Update GTK startup manifest creation to prefer SQLite candidates when the DB is available; keep the existing JSON path as compatibility fallback.
- [ ] Run focused resume-manifest tests.

## Task 4: Unified Orchestrator Status IPC

- [ ] Add a failing application IPC test or protocol-level dispatch test that `orchestrator.status` is recognized.
- [ ] Run the focused test and confirm it fails.
- [ ] Add `handleOrchestratorStatus` in `application.zig`.
- [ ] Reuse existing JSON append helpers for live workspace tree, agent list, recent commands, tasks, resume candidates, and storage counts.
- [ ] Return a warning section instead of failing the whole command when SQLite-backed sections are unavailable.
- [ ] Run the focused IPC test.

## Task 5: CLI And Skill Contract

- [ ] Add a failing `tools/termplex-ctl` parser test if available, or run `python3 -m py_compile tools/termplex-ctl` and manually confirm `orchestrator status` dispatches to `orchestrator.status`.
- [ ] Add the `orchestrator status` command branch to `tools/termplex-ctl`.
- [ ] Update `tools/skill/AGENTS.md` and `tools/skill/termplex.md` so the first global context command is `termplex-ctl orchestrator status`.
- [ ] Refresh installed copies under `/home/ahmed/.termplex/orchestration/`.

## Task 6: Verification

- [ ] Run focused Zig tests for `terminal_history_db.zig`, `state_manager.zig`, `resume_manifest.zig`, and any IPC dispatch tests touched.
- [ ] Run `python3 -m py_compile tools/termplex-ctl`.
- [ ] Run `/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell`.
- [ ] Run a live command when an app IPC socket is available: `./tools/termplex-ctl orchestrator status`.
- [ ] Record any full-suite limitation if `/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell` hangs or is killed.

## Self Review

- Spec coverage: the plan covers SQLite durable runtime state, live IPC, CLI, resume manifest, and orchestrator skill docs.
- Placeholder scan: no `TBD`, `TODO`, or undefined placeholder tasks remain.
- Type consistency: runtime fields are consistently named `process_pid`, `process_alive`, `detection_method`, `ports_json`, `command_started_at`, and `last_command`.

