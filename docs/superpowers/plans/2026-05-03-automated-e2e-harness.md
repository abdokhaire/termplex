# Automated E2E Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a repeatable real-app E2E harness that launches Termplex, drives it through IPC, verifies terminal/runtime persistence, and exposes the check as `zig build e2e`.

**Architecture:** Use a Python 3 stdlib runner under `test/e2e/` to launch the real GTK binary with disposable XDG directories, talk to Termplex through `tools/termplex-ctl`, inspect SQLite with Python's `sqlite3`, and retain logs/artifacts on failure. Add a small `system.quit` IPC command so the harness can trigger normal shutdown and session autosave instead of killing the process.

**Tech Stack:** Zig 0.15.2 build step, GTK4/libadwaita runtime, Python 3 stdlib, Unix socket IPC, SQLite, XDG config/state/cache/runtime directories, optional `xvfb-run` for headless environments.

---

## Current Context

Relevant existing files:

- `build.zig` already defines `test`, `run`, packaging steps, and installs the app/resources.
- `tools/termplex-ctl` already speaks JSON over the Termplex Unix socket.
- `src/apprt/gtk/class/application.zig` owns the real GTK app IPC dispatcher, workspace/tab/surface actions, session autosave/restore, terminal-history DB lifecycle, and transcript fallback reads.
- `src/termplex/core/terminal_history.zig` owns transcript paths, append/read/clear, capping, retention cleanup, and sanitizer behavior.
- `src/termplex/core/terminal_history_db.zig` owns SQLite tables:
  - `terminal_projects`
  - `terminal_surfaces`
  - `command_history`
- `src/termplex/core/config.zig` defaults terminal history to enabled and supports `[terminal_history]`, `[memory]`, `[session]`, and `[orchestration]` config sections.

Important constraints:

- This is a real app test. It needs a display server: X11, Wayland, or `xvfb-run`.
- The harness must not use the user's real Termplex config/state/cache.
- The harness must not rely on network access.
- The harness should keep artifacts on failure and delete them on success unless `--keep-artifacts` is passed.
- The first E2E version should stay focused on runtime confidence, not screenshot/UI visual testing.

## Files

- Create: `test/e2e/termplex_e2e.py`
- Create: `test/e2e/README.md`
- Modify: `tools/termplex-ctl`
- Modify: `src/apprt/gtk/class/application.zig`
- Modify: `build.zig`

## Test Matrix

The first harness must verify:

- App launches with disposable XDG directories.
- IPC socket becomes available.
- `termplex-ctl ping` returns `pong`.
- `termplex-ctl status` returns a workspace tree.
- Workspace can be created with a specific name and cwd.
- Tab can be created with a specific title and cwd.
- Text can be sent to a terminal and read back.
- OSC 7337 command markers create `command_history` rows.
- SQLite contains project, surface, and command rows for the E2E workspace.
- Transcript files exist and contain expected terminal output.
- Agent register/list/unregister works.
- Normal app quit writes `session.json`.
- Relaunch restores the workspace.
- Relaunch restores transcript output enough for `surface read` to see the previous marker.
- Closing a workspace deletes related project metadata and transcript files.

## Task 1: Add Deterministic Quit IPC

**Files:**

- Modify: `src/apprt/gtk/class/application.zig`
- Modify: `tools/termplex-ctl`

- [ ] **Step 1: Add `system.quit` to the GTK IPC dispatcher**

In `src/apprt/gtk/class/application.zig`, add this helper inside the `Application` struct, near the other IPC helpers:

```zig
    fn quitApplicationCallback(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return @intFromBool(glib.SOURCE_REMOVE)));
        self.quit();
        return @intFromBool(glib.SOURCE_REMOVE);
    }
```

In `ipcDispatch()`, add this branch immediately after the existing `system.ping` branch:

```zig
        if (std.mem.eql(u8, method, "system.quit")) {
            _ = glib.timeoutAdd(50, quitApplicationCallback, self);
            return std.fmt.allocPrint(
                alloc,
                "{{\"ok\":true,\"result\":{{\"quitting\":true}},\"id\":{d}}}",
                .{id},
            ) catch null;
        }
```

This schedules quit after the response is sent, which avoids dropping the IPC response while still exercising normal application shutdown.

- [ ] **Step 2: Add `quit` to `termplex-ctl`**

In `tools/termplex-ctl`, add the parser next to the existing `ping` and `status` parsers:

```python
    # --- quit ---
    subparsers.add_parser("quit", help="Ask the running Termplex app to quit")
```

In `build_request(args)`, add this branch next to `ping` and `status`:

```python
    if resource == "quit":
        return "system.quit", {}
```

- [ ] **Step 3: Build to catch syntax/type errors**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

Expected:

- Build succeeds.
- `zig-out/bin/termplex-app` exists.
- `zig-out/bin/termplex-ctl` exists after install resources run, or `tools/termplex-ctl` remains directly runnable.

- [ ] **Step 4: Commit quit IPC**

```bash
git add src/apprt/gtk/class/application.zig tools/termplex-ctl
git commit -m "test: add deterministic app quit ipc"
```

## Task 2: Create The Python E2E Runner

**Files:**

- Create: `test/e2e/termplex_e2e.py`

- [ ] **Step 1: Create the runner with disposable profile, app launch, IPC helpers, SQLite helpers, and assertions**

Create `test/e2e/termplex_e2e.py` with this structure:

```python
#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time


class E2EError(RuntimeError):
    pass


def parse_args():
    parser = argparse.ArgumentParser(description="Run Termplex real-app E2E smoke tests")
    parser.add_argument("--app", required=True, help="Path to termplex-app")
    parser.add_argument("--ctl", required=True, help="Path to termplex-ctl")
    parser.add_argument("--resources-dir", help="Path to share/termplex resources")
    parser.add_argument("--profile-dir", help="Use an existing disposable profile directory")
    parser.add_argument("--keep-artifacts", action="store_true", help="Keep profile/log artifacts after success")
    parser.add_argument("--timeout", type=float, default=30.0, help="Default wait timeout in seconds")
    return parser.parse_args()


def run_json(cmd, env=None, cwd=None, timeout=10.0):
    proc = subprocess.run(
        cmd,
        env=env,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
    )
    if proc.returncode != 0:
        raise E2EError(
            "command failed: {}\nstdout:\n{}\nstderr:\n{}".format(
                " ".join(cmd), proc.stdout, proc.stderr
            )
        )
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise E2EError("invalid JSON from {}: {}\n{}".format(" ".join(cmd), exc, proc.stdout))
    if not payload.get("ok"):
        raise E2EError("IPC command returned error: {}\n{}".format(" ".join(cmd), payload))
    return payload.get("result")


def wait_until(label, timeout, fn, interval=0.25):
    deadline = time.monotonic() + timeout
    last_error = None
    while time.monotonic() < deadline:
        try:
            result = fn()
            if result:
                return result
        except Exception as exc:
            last_error = exc
        time.sleep(interval)
    if last_error is not None:
        raise E2EError("timed out waiting for {}: {}".format(label, last_error))
    raise E2EError("timed out waiting for {}".format(label))


def mkdir(path, mode=None):
    path.mkdir(parents=True, exist_ok=True)
    if mode is not None:
        path.chmod(mode)


def write_config(profile):
    config_dir = profile / "config" / "termplex"
    mkdir(config_dir)
    (config_dir / "config.toml").write_text(
        """
[session]
autosave_interval = 1
restore_on_startup = true

[orchestration]
enabled = false

[memory]
enabled = true
auto_resume = true
flush_on_shutdown = true
proc_inspect_interval = 0

[terminal_history]
enabled = true
restore_mode = "transcript"
max_lines_per_surface = 2000
max_bytes_per_surface = 1048576
persist_alternate_screen = false
replay_notice = true
retention_days = 90
""".lstrip()
    )


def make_profile(args):
    if args.profile_dir:
        profile = pathlib.Path(args.profile_dir).resolve()
        mkdir(profile)
    else:
        profile = pathlib.Path(tempfile.mkdtemp(prefix="termplex-e2e."))
    mkdir(profile / "config")
    mkdir(profile / "state")
    mkdir(profile / "cache")
    mkdir(profile / "runtime", 0o700)
    mkdir(profile / "home")
    mkdir(profile / "workspace")
    mkdir(profile / "artifacts")
    write_config(profile)
    return profile


def profile_env(args, profile):
    env = os.environ.copy()
    env["HOME"] = str(profile / "home")
    env["XDG_CONFIG_HOME"] = str(profile / "config")
    env["XDG_STATE_HOME"] = str(profile / "state")
    env["XDG_CACHE_HOME"] = str(profile / "cache")
    env["XDG_RUNTIME_DIR"] = str(profile / "runtime")
    env["TERMPLEX_SOCKET"] = str(profile / "runtime" / "termplex.sock")
    env["GSETTINGS_BACKEND"] = "memory"
    if args.resources_dir:
        env["TERMPLEX_RESOURCES_DIR"] = str(pathlib.Path(args.resources_dir).resolve())
    return env


def require_display():
    if os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"):
        return
    raise E2EError("no DISPLAY or WAYLAND_DISPLAY; run with xvfb-run -a or from a graphical session")


def start_app(args, profile, env):
    log_path = profile / "artifacts" / "termplex-app.log"
    log_file = log_path.open("w")
    proc = subprocess.Popen(
        [str(pathlib.Path(args.app).resolve())],
        cwd=str(profile / "workspace"),
        env=env,
        stdout=log_file,
        stderr=subprocess.STDOUT,
        text=True,
    )
    return proc, log_file, log_path


def ctl(args, env, *parts):
    cmd = [sys.executable, str(pathlib.Path(args.ctl).resolve()), "--socket", env["TERMPLEX_SOCKET"]]
    cmd.extend(parts)
    return run_json(cmd, env=env)


def wait_for_ipc(args, env, timeout):
    wait_until("IPC socket", timeout, lambda: pathlib.Path(env["TERMPLEX_SOCKET"]).exists())
    return wait_until("IPC ping", timeout, lambda: ctl(args, env, "ping") == "pong")


def wait_for_output(args, env, workspace, tab, marker, timeout):
    def probe():
        result = ctl(args, env, "surface", "read", "--workspace", workspace, "--tab", str(tab), "--lines", "120")
        output = result.get("output", "")
        return output if marker in output else None

    return wait_until("terminal output {!r}".format(marker), timeout, probe)


def db_path(profile):
    return profile / "state" / "termplex" / "terminal-history" / "history.sqlite3"


def query_one(profile, sql, params=()):
    path = db_path(profile)
    if not path.exists():
        raise E2EError("SQLite database does not exist at {}".format(path))
    with sqlite3.connect(path) as conn:
        row = conn.execute(sql, params).fetchone()
    return row[0] if row else None


def query_all(profile, sql, params=()):
    path = db_path(profile)
    if not path.exists():
        raise E2EError("SQLite database does not exist at {}".format(path))
    with sqlite3.connect(path) as conn:
        return conn.execute(sql, params).fetchall()


def send_manual_command_marker(args, env, workspace, tab, marker, command_name):
    shell_cmd = (
        "printf '\\033]7337;cmd_start;%s;" + command_name + "\\007' $$; "
        "printf '" + marker + "\\n'; "
        "printf '\\033]7337;cmd_end;%s;0\\007' $$\\n"
    )
    ctl(args, env, "surface", "send", "--workspace", workspace, "--tab", str(tab), shell_cmd)


def assert_sqlite_rows(profile, workspace_name, marker_command, timeout):
    wait_until(
        "terminal_projects row",
        timeout,
        lambda: query_one(
            profile,
            "SELECT count(*) FROM terminal_projects WHERE workspace_name = ? AND deleted_at IS NULL",
            (workspace_name,),
        )
        and True,
    )
    wait_until(
        "terminal_surfaces row",
        timeout,
        lambda: query_one(
            profile,
            "SELECT count(*) FROM terminal_surfaces WHERE workspace_name = ?",
            (workspace_name,),
        )
        and True,
    )
    wait_until(
        "command_history row",
        timeout,
        lambda: query_one(
            profile,
            "SELECT count(*) FROM command_history WHERE workspace_name = ? AND command = ? AND exit_code = 0",
            (workspace_name, marker_command),
        )
        and True,
    )


def assert_transcript_contains(profile, workspace_name, marker, timeout):
    def probe():
        rows = query_all(
            profile,
            "SELECT transcript_path FROM terminal_surfaces WHERE workspace_name = ?",
            (workspace_name,),
        )
        for (raw_path,) in rows:
            path = pathlib.Path(raw_path)
            if path.exists() and marker in path.read_text(errors="replace"):
                return str(path)
        return None

    return wait_until("transcript containing {}".format(marker), timeout, probe)


def quit_app(args, env, proc, timeout):
    try:
        ctl(args, env, "quit")
    except Exception:
        proc.terminate()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            return
        time.sleep(0.2)
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)


def run_scenario(args, profile, env):
    workspace_name = "E2E Workspace"
    delete_workspace_name = "E2E DeleteMe"
    workspace_dir = str(profile / "workspace")
    marker = "TPX_E2E_MARKER_001"
    second_marker = "TPX_E2E_SECOND_TAB_001"
    delete_marker = "TPX_E2E_DELETE_001"
    command_name = "termplex-e2e-manual"
    delete_command_name = "termplex-e2e-delete"

    proc, log_file, log_path = start_app(args, profile, env)
    try:
        wait_for_ipc(args, env, args.timeout)
        status = ctl(args, env, "status")
        if "workspaces" not in status:
            raise E2EError("status missing workspaces: {}".format(status))

        ctl(args, env, "workspace", "create", "--name", workspace_name, "--dir", workspace_dir)
        wait_until(
            "workspace list contains E2E workspace",
            args.timeout,
            lambda: workspace_name in [item["name"] for item in ctl(args, env, "workspace", "list")["items"]],
        )

        ctl(args, env, "surface", "send", "--workspace", workspace_name, "--tab", "0", "pwd\\n")
        wait_for_output(args, env, workspace_name, 0, workspace_dir, args.timeout)

        send_manual_command_marker(args, env, workspace_name, 0, marker, command_name)
        wait_for_output(args, env, workspace_name, 0, marker, args.timeout)

        tab_result = ctl(
            args,
            env,
            "tab",
            "create",
            "--workspace",
            workspace_name,
            "--title",
            "second",
            "--dir",
            workspace_dir,
        )
        second_tab = int(tab_result.get("tab", 1))
        ctl(args, env, "surface", "send", "--workspace", workspace_name, "--tab", str(second_tab), "printf '" + second_marker + "\\n'\\n")
        wait_for_output(args, env, workspace_name, second_tab, second_marker, args.timeout)

        ctl(args, env, "agent", "register", "--workspace", workspace_name, "--tab", "0", "--type", "codex", "--pid", str(os.getpid()))
        agents = ctl(args, env, "agent", "list")["agents"]
        if not any(agent["pid"] == os.getpid() for agent in agents):
            raise E2EError("registered agent not found in list: {}".format(agents))
        ctl(args, env, "agent", "unregister", "--pid", str(os.getpid()))

        assert_sqlite_rows(profile, workspace_name, command_name, args.timeout)
        transcript_path = assert_transcript_contains(profile, workspace_name, marker, args.timeout)

        ctl(args, env, "workspace", "create", "--name", delete_workspace_name, "--dir", workspace_dir)
        send_manual_command_marker(args, env, delete_workspace_name, 0, delete_marker, delete_command_name)
        wait_for_output(args, env, delete_workspace_name, 0, delete_marker, args.timeout)
        assert_sqlite_rows(profile, delete_workspace_name, delete_command_name, args.timeout)
        delete_transcript_path = assert_transcript_contains(profile, delete_workspace_name, delete_marker, args.timeout)
        ctl(args, env, "workspace", "close", "--name", delete_workspace_name)
        wait_until(
            "deleted workspace metadata removed",
            args.timeout,
            lambda: query_one(
                profile,
                "SELECT count(*) FROM terminal_projects WHERE workspace_name = ? AND deleted_at IS NULL",
                (delete_workspace_name,),
            )
            == 0,
        )
        if pathlib.Path(delete_transcript_path).exists():
            raise E2EError("transcript still exists after workspace close: {}".format(delete_transcript_path))

        quit_app(args, env, proc, args.timeout)
        log_file.close()
        session_path = profile / "state" / "termplex" / "session.json"
        if not session_path.exists():
            raise E2EError("session.json was not written")
        session_text = session_path.read_text(errors="replace")
        if workspace_name not in session_text:
            raise E2EError("session.json does not contain restored workspace name")

        proc, log_file, log_path = start_app(args, profile, env)
        wait_for_ipc(args, env, args.timeout)
        wait_until(
            "restored workspace list contains E2E workspace",
            args.timeout,
            lambda: workspace_name in [item["name"] for item in ctl(args, env, "workspace", "list")["items"]],
        )
        wait_for_output(args, env, workspace_name, 0, marker, args.timeout)
        if not pathlib.Path(transcript_path).exists():
            raise E2EError("primary transcript disappeared after restore: {}".format(transcript_path))
    finally:
        if proc.poll() is None:
            quit_app(args, env, proc, 5.0)
        log_file.close()


def main():
    args = parse_args()
    require_display()
    profile = make_profile(args)
    env = profile_env(args, profile)
    try:
        run_scenario(args, profile, env)
    except Exception:
        print("E2E artifacts kept at {}".format(profile), file=sys.stderr)
        raise
    else:
        if args.keep_artifacts:
            print("E2E artifacts kept at {}".format(profile))
        elif not args.profile_dir:
            shutil.rmtree(profile)


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Make the runner executable**

Run:

```bash
chmod +x test/e2e/termplex_e2e.py
```

- [ ] **Step 3: Run the runner directly from a graphical session**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
python3 test/e2e/termplex_e2e.py \
  --app ./zig-out/bin/termplex-app \
  --ctl ./tools/termplex-ctl \
  --resources-dir ./zig-out/share/termplex \
  --keep-artifacts
```

Expected:

- Script exits with status `0`.
- It prints the kept artifact directory.
- The artifact directory contains `artifacts/termplex-app.log`.
- SQLite database exists at `state/termplex/terminal-history/history.sqlite3`.

- [ ] **Step 4: Commit the runner**

```bash
git add test/e2e/termplex_e2e.py
git commit -m "test: add termplex real app e2e runner"
```

## Task 3: Add `zig build e2e`

**Files:**

- Modify: `build.zig`

- [ ] **Step 1: Add an `e2e` build step**

Near the existing build steps in `build.zig`, add:

```zig
    const e2e_step = b.step(
        "e2e",
        "Run Termplex real-app E2E tests",
    );
```

After the existing `run` step block and before the Zig unit test block, add:

```zig
    // Real GTK application E2E tests. This intentionally stays separate from
    // `zig build test` because it needs a graphical display or xvfb-run.
    if (config.app_runtime != .none) {
        const e2e_cmd = b.addSystemCommand(&.{"python3"});
        e2e_cmd.addFileArg(b.path("test/e2e/termplex_e2e.py"));
        e2e_cmd.addArg("--app");
        e2e_cmd.addArtifactArg(exe.exe);
        e2e_cmd.addArg("--ctl");
        e2e_cmd.addFileArg(b.path("tools/termplex-ctl"));
        e2e_cmd.addArg("--resources-dir");
        e2e_cmd.addArg(b.getInstallPath(.prefix, "share/termplex"));
        if (b.args) |args| e2e_cmd.addArgs(args);
        e2e_cmd.step.dependOn(b.getInstallStep());
        e2e_step.dependOn(&e2e_cmd.step);
    } else {
        try e2e_step.addError("e2e requires an app runtime; pass -Dapp-runtime=gtk", .{});
    }
```

- [ ] **Step 2: Run the build step from a graphical session**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build e2e -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell -- --keep-artifacts
```

Expected:

- The app builds.
- The E2E script launches the app.
- The script passes.
- The command prints the kept artifact directory.

- [ ] **Step 3: Run the build step headlessly if `xvfb-run` is installed**

Run:

```bash
xvfb-run -a /opt/zig-x86_64-linux-0.15.2/zig build e2e -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

Expected:

- The E2E script passes under Xvfb.
- No artifacts are kept after success.

- [ ] **Step 4: Commit the build step**

```bash
git add build.zig
git commit -m "test: wire real app e2e build step"
```

## Task 4: Document E2E Usage And Failure Artifacts

**Files:**

- Create: `test/e2e/README.md`

- [ ] **Step 1: Add E2E documentation**

Create `test/e2e/README.md`:

````markdown
# Termplex E2E Tests

This directory contains real GTK application E2E smoke tests.

The harness launches `termplex-app` with disposable XDG directories, drives it through `termplex-ctl`, and verifies IPC, workspace/tab behavior, terminal I/O, SQLite history rows, transcript files, session restore, transcript restore, and agent registry flows.

## Run From A Graphical Session

```bash
/opt/zig-x86_64-linux-0.15.2/zig build e2e -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

## Run Headlessly

```bash
xvfb-run -a /opt/zig-x86_64-linux-0.15.2/zig build e2e -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

## Keep Artifacts

```bash
/opt/zig-x86_64-linux-0.15.2/zig build e2e -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell -- --keep-artifacts
```

Artifacts include the disposable profile, app log, config, state, SQLite database, session file, and transcript files.

The harness never uses the user's real `~/.config/termplex`, `~/.local/state/termplex`, or `~/.cache/termplex`.
````

- [ ] **Step 2: Verify documentation command**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build e2e -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell -- --keep-artifacts
```

Expected:

- Command matches the README.
- Script passes.

- [ ] **Step 3: Commit documentation**

```bash
git add test/e2e/README.md
git commit -m "docs: document termplex e2e tests"
```

## Task 5: Run Full Verification

**Files:**

- No new files.

- [ ] **Step 1: Run Zig unit tests**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build test -fno-sys=gtk4-layer-shell
```

Expected:

- All tests pass.
- Existing parser/negative-test warning noise is acceptable if the test process exits `0`.

- [ ] **Step 2: Run a debug app build**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

Expected:

- Build succeeds.

- [ ] **Step 3: Run E2E**

Run from a graphical session:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build e2e -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell -- --keep-artifacts
```

Expected:

- E2E passes.
- The kept artifact profile can be inspected manually.

- [ ] **Step 4: Run E2E artifact cleanup mode**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build e2e -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

Expected:

- E2E passes.
- No temporary profile remains after success.

- [ ] **Step 5: Run release build**

Run:

```bash
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell -Doptimize=ReleaseFast
```

Expected:

- Build succeeds.

- [ ] **Step 6: Commit final verification notes if the implementation changed docs**

Only run this if verification required documentation updates:

```bash
git add test/e2e/README.md docs/superpowers/plans/2026-05-03-automated-e2e-harness.md
git commit -m "docs: update e2e verification notes"
```

## CI Follow-Up

Do not add the E2E harness to the required GitHub Actions matrix in the first implementation unless the runner environment is confirmed to have GTK runtime dependencies and `xvfb-run`.

Recommended follow-up after local stability:

- Add a non-required workflow job or manual `workflow_dispatch` job.
- Run `xvfb-run -a zig build e2e -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell`.
- Upload the E2E profile artifacts on failure.
- Promote to required after repeated stable runs.

## Security And Privacy Notes

- The harness must use disposable XDG paths.
- It must never read or write the user's real Termplex state.
- Failure artifacts may contain command text and terminal output by design.
- Artifacts are local test output and should only be uploaded by CI on failure after the CI policy is explicit.
- The harness should use fixed marker strings, not real secrets.

## Self-Review Checklist

- The plan starts with the required implementation-plan header.
- Scope is a single subsystem: automated E2E harness.
- The sequence adds a deterministic shutdown path before relying on session restore.
- The runner uses the existing IPC tool instead of inventing a second client protocol.
- SQLite verification checks real database tables.
- Transcript verification checks real transcript files.
- Session restore is verified by relaunching the app with the same disposable profile.
- Cleanup behavior is verified by closing a disposable workspace.
- CI is intentionally a follow-up, not a fragile first implementation requirement.
