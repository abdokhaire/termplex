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


def send_manual_command_marker(args, env, workspace, tab, marker, command_name, timeout):
    shell_cmd = (
        "printf '\\033]7337;cmd_start;%s;" + command_name + "\\007' $$; "
        "printf '" + marker + "\\n'; "
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
    delete_workspace_dir = str(profile / "workspace-delete")
    marker = "TPX_E2E_MARKER_001"
    second_marker = "TPX_E2E_SECOND_TAB_001"
    delete_marker = "TPX_E2E_DELETE_001"
    boot_marker = "TPX_E2E_BOOT_READY_001"
    command_name = "termplex-e2e-manual"
    delete_command_name = "termplex-e2e-delete"

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
        transcript_path = assert_transcript_contains(profile, workspace_name, marker, args.timeout)

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
        wait_for_ipc(args, env, proc, args.timeout)
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
