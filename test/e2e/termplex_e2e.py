#!/usr/bin/env python3
import argparse
import hashlib
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


def prepend_env_path(env, key, path):
    path = pathlib.Path(path).resolve()
    if not path.exists():
        return
    old = env.get(key)
    env[key] = str(path) if not old else "{}:{}".format(path, old)


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
    mkdir(profile / "workspace-delete")
    mkdir(profile / "workspace-storage")
    mkdir(profile / "workspace-lazy")
    mkdir(profile / "artifacts")
    write_config(profile)
    return profile


def write_update_fixture(profile):
    appimage = profile / "artifacts" / "Termplex-9.9.9-x86_64.AppImage"
    appimage.write_bytes(b"termplex test appimage\n")
    sha = hashlib.sha256(appimage.read_bytes()).hexdigest()

    manifest = profile / "artifacts" / "termplex-update.json"
    manifest.write_text(
        json.dumps(
            {
                "version": "9.9.9",
                "channel": "tip",
                "released_at": "2026-05-03T00:00:00Z",
                "notes_url": "https://github.com/termplex-org/termplex/releases/tag/v9.9.9",
                "downloads": {
                    "linux-x86_64-appimage": {
                        "url": "https://github.com/termplex-org/termplex/releases/download/v9.9.9/Termplex-9.9.9-x86_64.AppImage",
                        "sha256": sha,
                    }
                },
            }
        )
    )
    return manifest, appimage


def profile_env(args, profile):
    env = os.environ.copy()
    manifest, appimage = write_update_fixture(profile)
    env["HOME"] = str(profile / "home")
    env["XDG_CONFIG_HOME"] = str(profile / "config")
    env["XDG_STATE_HOME"] = str(profile / "state")
    env["XDG_CACHE_HOME"] = str(profile / "cache")
    env["XDG_RUNTIME_DIR"] = str(profile / "runtime")
    env["TERMPLEX_SOCKET"] = str(profile / "runtime" / "termplex.sock")
    env["GSETTINGS_BACKEND"] = "memory"
    env["TERMPLEX_E2E"] = "1"
    env["TERMPLEX_E2E_OPEN_WORKSPACE_LOG"] = str(profile / "artifacts" / "workspace-open.jsonl")
    env["APPIMAGE"] = str(appimage)
    env["TERMPLEX_UPDATE_MANIFEST_URL"] = "file://" + str(manifest)
    env["TERMPLEX_UPDATE_DOWNLOAD_OVERRIDE"] = str(appimage)
    if args.resources_dir:
        resources_dir = pathlib.Path(args.resources_dir).resolve()
        env["TERMPLEX_RESOURCES_DIR"] = str(resources_dir)
        prepend_env_path(env, "LD_LIBRARY_PATH", resources_dir.parent.parent / "lib")
    else:
        app_path = pathlib.Path(args.app).resolve()
        prepend_env_path(env, "LD_LIBRARY_PATH", app_path.parent.parent / "lib")
    return env


def require_display():
    if os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"):
        return
    raise E2EError("no DISPLAY or WAYLAND_DISPLAY; run with xvfb-run -a or from a graphical session")


def start_app(args, profile, env):
    log_path = profile / "artifacts" / "termplex-app.log"
    log_file = log_path.open("a")
    proc = subprocess.Popen(
        [
            str(pathlib.Path(args.app).resolve()),
            "--gtk-single-instance=false",
            "--class=com.termplex.e2e",
        ],
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


def wait_for_ipc(args, env, proc, timeout):
    def socket_exists():
        if proc.poll() is not None:
            raise E2EError("termplex-app exited with {}".format(proc.returncode))
        return pathlib.Path(env["TERMPLEX_SOCKET"]).exists()

    wait_until("IPC socket", timeout, socket_exists)
    return wait_until("IPC ping", timeout, lambda: ctl(args, env, "ping") == "pong")


def wait_for_output(args, env, workspace, tab, marker, timeout):
    def probe():
        result = ctl(args, env, "surface", "read", "--workspace", workspace, "--tab", str(tab), "--lines", "120")
        output = result.get("output", "")
        return output if marker in output else None

    return wait_until("terminal output {!r}".format(marker), timeout, probe)


def select_workspace(args, env, workspace, timeout):
    ctl(args, env, "workspace", "select", "--name", workspace)

    def probe():
        items = ctl(args, env, "workspace", "list")["items"]
        return any(item["name"] == workspace and item["active"] for item in items)

    wait_until("active workspace {!r}".format(workspace), timeout, probe)


def focus_surface(args, env, workspace, tab):
    return ctl(args, env, "surface", "focus", "--workspace", workspace, "--tab", str(tab))


def send_text(args, env, workspace, tab, text, timeout):
    def probe():
        ctl(args, env, "surface", "send", "--workspace", workspace, "--tab", str(tab), text)
        return True

    return wait_until("send to surface {}:{}".format(workspace, tab), timeout, probe)


def tab_index(result, fallback):
    return int(result.get("tab", result.get("index", fallback)))


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


def run_cmd(cmd, cwd, timeout=10.0):
    proc = subprocess.run(
        cmd,
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
    return proc


def setup_git_fixture(workspace_path):
    run_cmd(["git", "init"], workspace_path)
    run_cmd(["git", "config", "user.email", "termplex-e2e@example.invalid"], workspace_path)
    run_cmd(["git", "config", "user.name", "Termplex E2E"], workspace_path)
    run_cmd(["git", "remote", "add", "origin", "https://example.invalid/termplex-e2e.git"], workspace_path)
    (workspace_path / "tracked.txt").write_text("base\n")
    run_cmd(["git", "add", "tracked.txt"], workspace_path)
    run_cmd(["git", "commit", "-m", "initial"], workspace_path)
    (workspace_path / "tracked.txt").write_text("base\nmodified\n")
    (workspace_path / "staged.txt").write_text("staged\n")
    run_cmd(["git", "add", "staged.txt"], workspace_path)


def send_manual_command_marker(args, env, workspace, tab, marker, command_name, timeout):
    shell_cmd = (
        "printf '\\033]7337;cmd_start;%s;" + command_name + "\\007' $$; "
        "printf '" + marker + "\\n'; "
        "sleep 0.1; "
        "printf '\\033]7337;cmd_end;%s;0\\007' $$\\n"
    )
    send_text(args, env, workspace, tab, shell_cmd, timeout)


def assert_update_flow(args, env, profile, timeout):
    def update_available():
        status = ctl(args, env, "update", "status")
        return status if status.get("available_version") == "9.9.9" else None

    def update_downloaded():
        status = ctl(args, env, "update", "status")
        return status if status.get("download_path") else None

    ctl(args, env, "update", "check")
    status = wait_until(
        "update available",
        timeout,
        update_available,
    )
    if status.get("install_kind") != "appimage":
        raise E2EError("update status did not detect AppImage install: {}".format(status))

    ctl(args, env, "update", "download")
    status = wait_until(
        "update downloaded",
        timeout,
        update_downloaded,
    )
    download_path = pathlib.Path(status["download_path"])
    expected_dir = profile / "state" / "termplex" / "updates"
    if not download_path.exists():
        raise E2EError("downloaded AppImage missing: {}".format(download_path))
    if expected_dir not in download_path.parents:
        raise E2EError("downloaded AppImage is outside update dir: {}".format(download_path))
    if not os.access(download_path, os.X_OK):
        raise E2EError("downloaded AppImage is not executable: {}".format(download_path))


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


def assert_history_search(args, env, workspace_name, marker_command, timeout):
    def probe():
        result = ctl(
            args,
            env,
            "history",
            "search",
            "--query",
            marker_command,
            "--workspace",
            workspace_name,
        )
        items = result.get("items", [])
        for item in items:
            if item.get("command") == marker_command and item.get("workspace_name") == workspace_name:
                return item
        return None

    item = wait_until("history search result for {}".format(marker_command), timeout, probe)
    if item.get("exit_code") != 0:
        raise E2EError("history search returned wrong exit code: {}".format(item))
    if item.get("source") != "osc_7337":
        raise E2EError("history search returned wrong source: {}".format(item))
    return item


def assert_history_transcript_cli(args, env, history_item, marker, timeout):
    history_id = history_item.get("history_id")
    if not history_id:
        raise E2EError("history search result missing history_id: {}".format(history_item))

    def transcript_has_marker():
        result = ctl(
            args,
            env,
            "history",
            "transcript",
            "--history-id",
            history_id,
            "--lines",
            "200",
        )
        if marker in result.get("output", ""):
            return result
        return None

    transcript = wait_until("history transcript output for {}".format(marker), timeout, transcript_has_marker)
    if transcript.get("history_id") != history_id:
        raise E2EError("history transcript returned wrong history_id: {}".format(transcript))
    if not transcript.get("commands"):
        raise E2EError("history transcript did not include command markers: {}".format(transcript))

    search = ctl(
        args,
        env,
        "history",
        "transcript-search",
        "--history-id",
        history_id,
        "--query",
        marker,
    )
    items = search.get("items", [])
    if not any(marker in item.get("line", "") for item in items):
        raise E2EError("history transcript search missing marker: {}".format(search))

    shown = ctl(args, env, "history", "transcript-show", "--history-id", history_id)
    if not shown.get("shown"):
        raise E2EError("history transcript viewer did not report shown: {}".format(shown))
    if shown.get("history_id") != history_id:
        raise E2EError("history transcript viewer returned wrong history_id: {}".format(shown))


def assert_history_promote_to_task(args, env, profile, workspace_name, history_item, timeout):
    command_id = history_item.get("id")
    command = history_item.get("command")
    if command_id is None or not command:
        raise E2EError("history search result missing command id or command: {}".format(history_item))

    task_name = "promoted-history-task"
    promoted = ctl(
        args,
        env,
        "task",
        "promote",
        "--workspace",
        workspace_name,
        "--command-id",
        str(command_id),
        "--name",
        task_name,
    )
    if promoted.get("name") != task_name or promoted.get("command") != command:
        raise E2EError("task promote returned wrong task: {}".format(promoted))
    if not promoted.get("working_directory"):
        raise E2EError("task promote did not persist working directory metadata: {}".format(promoted))

    wait_until(
        "promoted command history task persisted",
        timeout,
        lambda: query_one(
            profile,
            "SELECT command FROM workspace_tasks WHERE name = ?",
            (task_name,),
        )
        == command,
    )


def assert_dashboard_status(args, env, workspace_name, command_marker, timeout):
    def dashboard_has_context():
        status = ctl(args, env, "dashboard", "status", "--workspace", workspace_name)
        workspace = status.get("workspace", {})
        commands = status.get("recent_commands", [])
        git = status.get("git", {})
        storage = status.get("storage", {})
        if workspace.get("name") != workspace_name:
            return None
        if not any(command_marker in item.get("command", "") for item in commands):
            return None
        if not git.get("is_repo"):
            return None
        if storage.get("command_count", 0) <= 0:
            return None
        return status

    status = wait_until("workspace dashboard status", timeout, dashboard_has_context)
    workspace = status["workspace"]
    if workspace.get("tab_count", 0) <= 0:
        raise E2EError("dashboard status did not report tabs: {}".format(status))
    if not workspace.get("active_history_id"):
        raise E2EError("dashboard status did not report active history id: {}".format(status))

    git = status["git"]
    if git.get("staged_count", 0) < 0 or git.get("unstaged_count", 0) < 0:
        raise E2EError("dashboard git counts were invalid: {}".format(status))

    storage = status["storage"]
    if storage.get("transcript_file_count", 0) <= 0:
        raise E2EError("dashboard storage did not report transcript files: {}".format(status))

    shown = ctl(args, env, "dashboard", "show")
    if not shown.get("shown"):
        raise E2EError("dashboard dialog did not report shown: {}".format(shown))
    ctl(args, env, "dashboard", "show")


def assert_workspace_open_actions(args, env, profile, workspace_name, workspace_dir):
    log_path = profile / "artifacts" / "workspace-open.jsonl"
    if log_path.exists():
        log_path.unlink()

    folder = ctl(args, env, "workspace", "open-folder", "--name", workspace_name)
    if folder.get("target") != "folder" or folder.get("dir") != workspace_dir:
        raise E2EError("workspace open-folder returned wrong result: {}".format(folder))

    vscode = ctl(args, env, "workspace", "open-vscode", "--name", workspace_name)
    if vscode.get("target") != "vscode" or vscode.get("dir") != workspace_dir:
        raise E2EError("workspace open-vscode returned wrong result: {}".format(vscode))

    entries = []
    if log_path.exists():
        for line in log_path.read_text().splitlines():
            if line.strip():
                entries.append(json.loads(line))
    expected = [
        {"target": "folder", "dir": workspace_dir},
        {"target": "vscode", "dir": workspace_dir},
    ]
    if entries != expected:
        raise E2EError("workspace open actions did not write expected dry-run log: {}".format(entries))


def assert_task_shortcuts_flow(args, env, profile, workspace_name, workspace_dir, tab, timeout):
    marker = "TPX_E2E_TASK_SHORTCUT_001"
    task_name = "echo-task"
    command = "printf '" + marker + "\\n'"

    created = ctl(
        args,
        env,
        "task",
        "add",
        "--workspace",
        workspace_name,
        "--name",
        task_name,
        "--command",
        command,
        "--dir",
        workspace_dir,
    )
    if created.get("name") != task_name or created.get("command") != command:
        raise E2EError("task add returned wrong task: {}".format(created))
    if created.get("working_directory") != workspace_dir:
        raise E2EError("task add did not persist working directory: {}".format(created))

    tasks = ctl(args, env, "task", "list", "--workspace", workspace_name)
    if not any(item.get("name") == task_name and item.get("command") == command for item in tasks.get("items", [])):
        raise E2EError("task list missing created task: {}".format(tasks))

    dashboard = ctl(args, env, "dashboard", "status", "--workspace", workspace_name)
    if not any(item.get("name") == task_name for item in dashboard.get("tasks", [])):
        raise E2EError("dashboard status missing task shortcut: {}".format(dashboard))

    ran = ctl(args, env, "task", "run", "--workspace", workspace_name, "--tab", str(tab), "--name", task_name)
    if not ran.get("ran"):
        raise E2EError("task run did not report ran: {}".format(ran))
    if ran.get("task", {}).get("run_count", 0) < 1:
        raise E2EError("task run did not update run count: {}".format(ran))
    wait_for_output(args, env, workspace_name, tab, marker, timeout)
    wait_until(
        "workspace task run persisted",
        timeout,
        lambda: query_one(
            profile,
            "SELECT run_count FROM workspace_tasks WHERE name = ?",
            (task_name,),
        )
        == 1,
    )
    last_run_at = query_one(
        profile,
        "SELECT last_run_at FROM workspace_tasks WHERE name = ?",
        (task_name,),
    )
    if not last_run_at:
        raise E2EError("workspace task did not persist last_run_at")

    deleted = ctl(args, env, "task", "delete", "--workspace", workspace_name, "--name", task_name)
    if not deleted.get("deleted"):
        raise E2EError("task delete did not report deleted: {}".format(deleted))
    wait_until(
        "workspace task deleted",
        timeout,
        lambda: query_one(
            profile,
            "SELECT count(*) FROM workspace_tasks WHERE name = ?",
            (task_name,),
        )
        == 0,
    )


def change_paths(status, section):
    return {item.get("path") for item in status.get(section, [])}


def assert_source_control_flow(args, env, workspace_name, timeout):
    def status_has_fixture_changes():
        status = ctl(args, env, "git", "status", "--workspace", workspace_name)
        if not status.get("is_repo"):
            return None
        staged = change_paths(status, "staged")
        unstaged = change_paths(status, "unstaged")
        if "staged.txt" in staged and "tracked.txt" in unstaged:
            return status
        return None

    status = wait_until("source control status fixture changes", timeout, status_has_fixture_changes)
    if status.get("remote_url") != "https://example.invalid/termplex-e2e.git":
        raise E2EError("source control status missing remote URL: {}".format(status))
    if not status.get("branch"):
        raise E2EError("source control status missing branch: {}".format(status))
    if not status.get("dirty"):
        raise E2EError("source control status did not report dirty repo: {}".format(status))

    diff = ctl(args, env, "git", "diff", "--workspace", workspace_name, "--path", "tracked.txt")
    if "+modified" not in diff.get("diff", ""):
        raise E2EError("source control diff missing modified line: {}".format(diff))

    status = ctl(args, env, "git", "unstage", "--workspace", workspace_name, "--path", "staged.txt")
    if "staged.txt" in change_paths(status, "staged"):
        raise E2EError("source control unstage did not remove staged file: {}".format(status))
    if "staged.txt" not in change_paths(status, "unstaged"):
        raise E2EError("source control unstage did not show file as unstaged: {}".format(status))

    status = ctl(args, env, "git", "stage", "--workspace", workspace_name, "--path", "staged.txt")
    if "staged.txt" not in change_paths(status, "staged"):
        raise E2EError("source control stage did not stage new file: {}".format(status))

    status = ctl(args, env, "git", "unstage-all", "--workspace", workspace_name)
    if change_paths(status, "staged"):
        raise E2EError("source control unstage-all left staged files: {}".format(status))
    unstaged = change_paths(status, "unstaged")
    if not {"staged.txt", "tracked.txt"}.issubset(unstaged):
        raise E2EError("source control unstage-all did not move all files to changes: {}".format(status))

    status = ctl(args, env, "git", "stage-all", "--workspace", workspace_name)
    staged = change_paths(status, "staged")
    if not {"staged.txt", "tracked.txt"}.issubset(staged):
        raise E2EError("source control stage-all did not stage all changes: {}".format(status))
    if change_paths(status, "unstaged"):
        raise E2EError("source control stage-all left unstaged files: {}".format(status))

    commit = ctl(args, env, "git", "commit", "--workspace", workspace_name, "--message", "e2e source control commit")
    if not commit.get("committed") or not commit.get("commit"):
        raise E2EError("source control commit did not return commit id: {}".format(commit))
    if commit.get("status", {}).get("dirty"):
        raise E2EError("source control commit did not leave repo clean: {}".format(commit))

    status = ctl(args, env, "git", "status", "--workspace", workspace_name)
    if status.get("dirty"):
        raise E2EError("source control final status is dirty: {}".format(status))

    shown = ctl(args, env, "git", "show")
    if not shown.get("shown"):
        raise E2EError("source control dialog did not report shown: {}".format(shown))


def assert_storage_status_has_history(args, env, timeout):
    def probe():
        status = ctl(args, env, "storage", "status")
        if status.get("command_count", 0) > 0 and status.get("transcript_file_count", 0) > 0:
            return status
        return None

    status = wait_until("storage status with history rows", timeout, probe)
    if not status.get("history_enabled"):
        raise E2EError("storage status did not report enabled history: {}".format(status))
    if status.get("restore_mode") != "transcript":
        raise E2EError("storage status returned wrong restore mode: {}".format(status))
    if status.get("retention_days") != 90:
        raise E2EError("storage status returned wrong retention days: {}".format(status))
    if status.get("total_bytes", 0) <= 0:
        raise E2EError("storage status returned no storage usage: {}".format(status))


def assert_storage_management_flow(args, env, profile, workspace_name, workspace_dir, timeout):
    marker_one = "TPX_E2E_STORAGE_ONE_001"
    marker_two = "TPX_E2E_STORAGE_TWO_001"
    marker_three = "TPX_E2E_STORAGE_THREE_001"
    command_one = "termplex-e2e-storage-one"
    command_two = "termplex-e2e-storage-two"
    command_three = "termplex-e2e-storage-three"

    ctl(args, env, "workspace", "create", "--name", workspace_name, "--dir", workspace_dir)
    select_workspace(args, env, workspace_name, timeout)
    tab_result = ctl(
        args,
        env,
        "tab",
        "create",
        "--workspace",
        workspace_name,
        "--title",
        "storage",
        "--dir",
        workspace_dir,
    )
    tab = tab_index(tab_result, 0)

    send_manual_command_marker(args, env, workspace_name, tab, marker_one, command_one, timeout)
    wait_for_output(args, env, workspace_name, tab, marker_one, timeout)
    assert_sqlite_rows(profile, workspace_name, command_one, timeout)
    transcript_one = assert_transcript_contains(profile, workspace_name, marker_one, timeout)

    assert_storage_status_has_history(args, env, timeout)
    shown = ctl(args, env, "storage", "show")
    if not shown.get("shown"):
        raise E2EError("storage dialog did not report shown: {}".format(shown))

    ctl(args, env, "storage", "clear-terminal", "--workspace", workspace_name, "--tab", str(tab))
    wait_until(
        "storage clear-terminal removes command rows",
        timeout,
        lambda: query_one(
            profile,
            "SELECT count(*) FROM command_history WHERE workspace_name = ?",
            (workspace_name,),
        )
        == 0,
    )
    if pathlib.Path(transcript_one).exists():
        raise E2EError("terminal transcript still exists after storage clear-terminal: {}".format(transcript_one))

    send_manual_command_marker(args, env, workspace_name, tab, marker_two, command_two, timeout)
    wait_for_output(args, env, workspace_name, tab, marker_two, timeout)
    assert_sqlite_rows(profile, workspace_name, command_two, timeout)
    transcript_two = assert_transcript_contains(profile, workspace_name, marker_two, timeout)

    ctl(args, env, "storage", "clear-workspace", "--workspace", workspace_name)
    wait_until(
        "storage clear-workspace removes command rows",
        timeout,
        lambda: query_one(
            profile,
            "SELECT count(*) FROM command_history WHERE workspace_name = ?",
            (workspace_name,),
        )
        == 0,
    )
    time.sleep(0.35)
    wait_until(
        "storage clear-workspace remains clear after deferred cleanup",
        timeout,
        lambda: query_one(
            profile,
            "SELECT count(*) FROM command_history WHERE workspace_name = ?",
            (workspace_name,),
        )
        == 0,
    )
    if pathlib.Path(transcript_two).exists():
        raise E2EError("workspace transcript still exists after storage clear-workspace: {}".format(transcript_two))
    active_projects = query_one(
        profile,
        "SELECT count(*) FROM terminal_projects WHERE workspace_name = ? AND deleted_at IS NULL",
        (workspace_name,),
    )
    if active_projects != 1:
        raise E2EError("clear-workspace did not keep live project metadata")

    send_manual_command_marker(args, env, workspace_name, tab, marker_three, command_three, timeout)
    wait_for_output(args, env, workspace_name, tab, marker_three, timeout)
    assert_sqlite_rows(profile, workspace_name, command_three, timeout)
    transcript_three = assert_transcript_contains(profile, workspace_name, marker_three, timeout)

    ctl(
        args,
        env,
        "task",
        "add",
        "--workspace",
        workspace_name,
        "--name",
        "cleanup-task",
        "--command",
        "printf cleanup\\n",
    )
    wait_until(
        "storage task shortcut row exists before project delete",
        timeout,
        lambda: query_one(
            profile,
            "SELECT count(*) FROM workspace_tasks WHERE name = ?",
            ("cleanup-task",),
        )
        == 1,
    )

    ctl(args, env, "storage", "delete-project", "--workspace", workspace_name)
    wait_until(
        "storage delete-project removes workspace",
        timeout,
        lambda: workspace_name not in [item["name"] for item in ctl(args, env, "workspace", "list")["items"]],
    )
    wait_until(
        "storage delete-project removes active project metadata",
        timeout,
        lambda: query_one(
            profile,
            "SELECT count(*) FROM terminal_projects WHERE workspace_name = ? AND deleted_at IS NULL",
            (workspace_name,),
        )
        == 0,
    )
    transcript_three_path = pathlib.Path(transcript_three)
    wait_until(
        "storage delete-project removes transcript file",
        timeout,
        lambda: not transcript_three_path.exists(),
    )
    wait_until(
        "storage delete-project removes task shortcuts",
        timeout,
        lambda: query_one(
            profile,
            "SELECT count(*) FROM workspace_tasks WHERE name = ?",
            ("cleanup-task",),
        )
        == 0,
    )


def assert_diagnostics_export(args, env, profile, workspace_name, command_marker, command_name):
    result = ctl(args, env, "diagnostics", "export")
    bundle_path = pathlib.Path(result.get("path", ""))
    if not bundle_path.exists():
        raise E2EError("diagnostics export did not create bundle file: {}".format(result))
    if not str(bundle_path).startswith(str(profile / "state" / "termplex" / "diagnostics")):
        raise E2EError("diagnostics export wrote outside diagnostics state dir: {}".format(bundle_path))

    text = bundle_path.read_text(errors="replace")
    try:
        bundle = json.loads(text)
    except json.JSONDecodeError as exc:
        raise E2EError("diagnostics bundle is not valid JSON: {}\n{}".format(exc, text))

    if bundle.get("schema_version") != 1:
        raise E2EError("diagnostics bundle missing schema_version=1: {}".format(bundle))
    if bundle.get("bundle_kind") != "termplex_diagnostics":
        raise E2EError("diagnostics bundle has wrong kind: {}".format(bundle))

    required_sections = ["app", "paths", "privacy", "workspaces", "storage", "update", "session"]
    for section in required_sections:
        if section not in bundle:
            raise E2EError("diagnostics bundle missing section {}: {}".format(section, bundle))

    privacy = bundle["privacy"]
    if privacy.get("includes_transcript_bodies") or privacy.get("includes_command_bodies"):
        raise E2EError("diagnostics bundle privacy defaults include bodies: {}".format(privacy))

    workspaces = bundle["workspaces"]
    if not any(item.get("name") == workspace_name for item in workspaces):
        raise E2EError("diagnostics bundle missing E2E workspace: {}".format(workspaces))
    if bundle["storage"].get("command_count", 0) <= 0:
        raise E2EError("diagnostics bundle missing command count: {}".format(bundle["storage"]))
    if bundle["session"].get("workspace_count", 0) <= 0:
        raise E2EError("diagnostics bundle missing session workspace count: {}".format(bundle["session"]))

    if command_marker in text or command_name in text:
        raise E2EError("diagnostics bundle leaked command/transcript body text")


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


def log_contains(log_path, needle):
    return needle in pathlib.Path(log_path).read_text(errors="replace")


def assert_background_workspace_hydrates_on_select(args, env, log_path, workspace_name, tab, marker, history_id, timeout):
    needle = "loaded deferred terminal replay history_id={}".format(history_id)
    if log_contains(log_path, needle):
        raise E2EError("background workspace hydrated before it was selected")

    select_workspace(args, env, workspace_name, timeout)
    focus_surface(args, env, workspace_name, tab)
    wait_until(
        "deferred replay hydration log for {}".format(history_id),
        timeout,
        lambda: log_contains(log_path, needle),
    )
    wait_for_output(args, env, workspace_name, tab, marker, timeout)


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
    storage_workspace_name = "E2E Storage"
    lazy_workspace_name = "E2E Lazy Hydrate"
    workspace_dir = str(profile / "workspace")
    delete_workspace_dir = str(profile / "workspace-delete")
    storage_workspace_dir = str(profile / "workspace-storage")
    lazy_workspace_dir = str(profile / "workspace-lazy")
    marker = "TPX_E2E_MARKER_001"
    second_marker = "TPX_E2E_SECOND_TAB_001"
    delete_marker = "TPX_E2E_DELETE_001"
    lazy_marker = "TPX_E2E_LAZY_HYDRATE_001"
    boot_marker = "TPX_E2E_BOOT_READY_001"
    command_name = "termplex-e2e-manual"
    delete_command_name = "termplex-e2e-delete"
    lazy_tab = None
    lazy_history_id = None

    setup_git_fixture(profile / "workspace")

    proc, log_file, log_path = start_app(args, profile, env)
    try:
        wait_for_ipc(args, env, proc, args.timeout)
        status = ctl(args, env, "status")
        if "workspaces" not in status:
            raise E2EError("status missing workspaces: {}".format(status))
        send_text(args, env, "0", 0, "printf '" + boot_marker + "\\n'\\n", args.timeout)
        wait_for_output(args, env, "0", 0, boot_marker, args.timeout)
        assert_update_flow(args, env, profile, args.timeout)

        ctl(args, env, "workspace", "create", "--name", workspace_name, "--dir", workspace_dir)
        wait_until(
            "workspace list contains E2E workspace",
            args.timeout,
            lambda: workspace_name in [item["name"] for item in ctl(args, env, "workspace", "list")["items"]],
        )
        select_workspace(args, env, workspace_name, args.timeout)
        main_tab_result = ctl(
            args,
            env,
            "tab",
            "create",
            "--workspace",
            workspace_name,
            "--title",
            "main",
            "--dir",
            workspace_dir,
        )
        main_tab = tab_index(main_tab_result, 0)

        send_text(args, env, workspace_name, main_tab, "pwd\\n", args.timeout)
        wait_for_output(args, env, workspace_name, main_tab, workspace_dir, args.timeout)
        assert_source_control_flow(args, env, workspace_name, args.timeout)

        send_manual_command_marker(args, env, workspace_name, main_tab, marker, command_name, args.timeout)
        wait_for_output(args, env, workspace_name, main_tab, marker, args.timeout)

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
        second_tab = tab_index(tab_result, 1)
        send_text(
            args,
            env,
            workspace_name,
            second_tab,
            "printf '" + second_marker + "\\n'\\n",
            args.timeout,
        )
        wait_for_output(args, env, workspace_name, second_tab, second_marker, args.timeout)

        ctl(args, env, "agent", "register", "--workspace", workspace_name, "--tab", str(main_tab), "--type", "codex", "--pid", str(os.getpid()))
        agents = ctl(args, env, "agent", "list")["agents"]
        if not any(agent["pid"] == os.getpid() for agent in agents):
            raise E2EError("registered agent not found in list: {}".format(agents))
        ctl(args, env, "agent", "unregister", "--pid", str(os.getpid()))

        assert_sqlite_rows(profile, workspace_name, command_name, args.timeout)
        history_item = assert_history_search(args, env, workspace_name, command_name, args.timeout)
        assert_history_transcript_cli(args, env, history_item, marker, args.timeout)
        assert_history_promote_to_task(args, env, profile, workspace_name, history_item, args.timeout)
        ctl(args, env, "history", "show")
        transcript_path = assert_transcript_contains(profile, workspace_name, marker, args.timeout)
        assert_storage_status_has_history(args, env, args.timeout)
        assert_task_shortcuts_flow(args, env, profile, workspace_name, workspace_dir, main_tab, args.timeout)
        assert_dashboard_status(args, env, workspace_name, command_name, args.timeout)
        assert_workspace_open_actions(args, env, profile, workspace_name, workspace_dir)
        assert_diagnostics_export(args, env, profile, workspace_name, marker, command_name)
        assert_storage_management_flow(args, env, profile, storage_workspace_name, storage_workspace_dir, args.timeout)

        ctl(args, env, "workspace", "create", "--name", delete_workspace_name, "--dir", delete_workspace_dir)
        select_workspace(args, env, delete_workspace_name, args.timeout)
        delete_tab_result = ctl(
            args,
            env,
            "tab",
            "create",
            "--workspace",
            delete_workspace_name,
            "--title",
            "delete",
            "--dir",
            delete_workspace_dir,
        )
        delete_tab = tab_index(delete_tab_result, 0)
        send_manual_command_marker(args, env, delete_workspace_name, delete_tab, delete_marker, delete_command_name, args.timeout)
        wait_for_output(args, env, delete_workspace_name, delete_tab, delete_marker, args.timeout)
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
        delete_transcript = pathlib.Path(delete_transcript_path)
        wait_until(
            "workspace close removes transcript file",
            args.timeout,
            lambda: not delete_transcript.exists(),
        )

        ctl(args, env, "workspace", "create", "--name", lazy_workspace_name, "--dir", lazy_workspace_dir)
        select_workspace(args, env, lazy_workspace_name, args.timeout)
        lazy_tab_result = ctl(
            args,
            env,
            "tab",
            "create",
            "--workspace",
            lazy_workspace_name,
            "--title",
            "lazy",
            "--dir",
            lazy_workspace_dir,
        )
        lazy_tab = tab_index(lazy_tab_result, 0)
        send_text(args, env, lazy_workspace_name, lazy_tab, "printf '" + lazy_marker + "\\n'\\n", args.timeout)
        wait_for_output(args, env, lazy_workspace_name, lazy_tab, lazy_marker, args.timeout)
        lazy_history_id = query_one(
            profile,
            "SELECT history_id FROM terminal_surfaces WHERE workspace_name = ? ORDER BY updated_at DESC LIMIT 1",
            (lazy_workspace_name,),
        )
        if not lazy_history_id:
            raise E2EError("lazy workspace did not persist a history id")
        select_workspace(args, env, workspace_name, args.timeout)

        quit_app(args, env, proc, args.timeout)
        log_file.close()
        session_path = profile / "state" / "termplex" / "session.json"
        if not session_path.exists():
            raise E2EError("session.json was not written")
        session_text = session_path.read_text(errors="replace")
        if workspace_name not in session_text:
            raise E2EError("session.json does not contain restored workspace name")

        proc, log_file, log_path = start_app(args, profile, env)
        wait_for_ipc(args, env, proc, args.timeout)
        wait_until(
            "restored workspace list contains E2E workspace",
            args.timeout,
            lambda: workspace_name in [item["name"] for item in ctl(args, env, "workspace", "list")["items"]],
        )
        if lazy_tab is None or not lazy_history_id:
            raise E2EError("lazy workspace fixture was not initialized before restore")
        assert_background_workspace_hydrates_on_select(
            args,
            env,
            log_path,
            lazy_workspace_name,
            lazy_tab,
            lazy_marker,
            lazy_history_id,
            args.timeout,
        )
        select_workspace(args, env, workspace_name, args.timeout)
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
