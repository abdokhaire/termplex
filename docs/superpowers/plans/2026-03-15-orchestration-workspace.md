# Orchestration Workspace Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an orchestration workspace to Termplex that lets AI agents (Claude Code, Codex) manage all workspaces, tabs, and terminals via a CLI tool and Unix socket IPC.

**Architecture:** New IPC methods are added to the existing `ipcDispatch` function in `application.zig`. A Python CLI (`termplex-ctl`) connects to the Unix socket and sends JSON commands. The orchestration workspace is a special pinned workspace in the sidebar that auto-launches an AI agent CLI. Agent registration uses an in-memory registry persisted to JSON.

**Tech Stack:** Zig 0.15.2, GTK4/libadwaita, Python 3 (stdlib only), Unix domain sockets, JSON IPC

**Spec:** `docs/superpowers/specs/2026-03-15-orchestration-workspace-design.md`

---

## File Structure

### New Files

| File | Responsibility |
|------|---------------|
| `tools/termplex-ctl` | Python 3 CLI for all IPC commands (single file, no deps) |
| `src/termplex/ipc/agents.zig` | Agent registry: in-memory list + JSON persistence |
| `tools/skill/termplex.md` | Claude Code skill file teaching agents how to use termplex-ctl |
| `tools/skill/AGENTS.md` | Codex-compatible version of the skill file |

### Modified Files

| File | Changes |
|------|---------|
| `src/apprt/gtk/class/application.zig` | IPC dispatch: `tab.*`, `surface.send/read`, `agent.*` handlers; orchestration workspace lifecycle; first-run dialog |
| `src/termplex/core/config.zig` | Add `[orchestration]` config section with `?bool` enabled field |
| `src/apprt/gtk/class/sidebar.zig` | Orchestrator workspace rendering: pinned first, styled, no context menu |
| `src/apprt/gtk/class/window.zig` | Skip orchestrator in workspace callbacks; tab creation helper for IPC |
| `src/apprt/gtk/css/style.css` | Orchestrator sidebar styles (divider, icon, label) |
| `src/build/TermplexResources.zig` | Install `termplex-ctl` to `bin/` and skill files to `share/termplex/` |

---

## Chunk 1: IPC Protocol Extensions + termplex-ctl CLI

### Task 1: Add workspace resolution helper + `tab.list` IPC handler

**Files:**
- Modify: `src/apprt/gtk/class/application.zig` (add to `ipcDispatch` at ~line 1089, add handler after line 1411)

- [ ] **Step 1: Add a shared workspace resolution helper**

Add after `ipcNotificationCreate` (around line 1411). This helper is used by `tab.list`, `tab.create`, `surface.send`, `surface.read`, and `agent.register` — avoids duplicating the name/index resolution logic:

```zig
/// Resolve a workspace reference (name string or integer index) from IPC params.
/// Returns the workspace index, or null if not found.
fn resolveWorkspaceIdx(self: *Self, params: std.json.ObjectMap) ?u32 {
    const priv = self.private();
    const ws_val = params.get("workspace") orelse return priv.active_workspace_idx;
    switch (ws_val) {
        .integer => |n| {
            if (n >= 0 and n < @as(i64, @intCast(priv.workspace_names.items.len)))
                return @intCast(n);
            return null;
        },
        .string => |name| {
            for (priv.workspace_names.items, 0..) |ws_name, idx| {
                if (std.mem.eql(u8, ws_name, name))
                    return @intCast(idx);
            }
            return null;
        },
        else => return priv.active_workspace_idx,
    }
}
```

- [ ] **Step 2: Add the `ipcTabList` handler function**

Follow the exact pattern of `ipcWorkspaceList` — build JSON manually using `ArrayListUnmanaged(u8)`:

```zig
/// Handle tab.list — returns tabs in a workspace.
fn ipcTabList(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
    const priv = self.private();
    const params_val = obj.get("params") orelse .null;
    const params = if (params_val == .object) params_val.object else std.json.ObjectMap{};

    const ws_idx = self.resolveWorkspaceIdx(params) orelse {
        return std.fmt.allocPrint(alloc,
            "{{\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"workspace not found\"}},\"id\":{d}}}",
            .{id},
        ) catch null;
    };

    const tab_view = priv.workspace_tab_views.items[ws_idx];
    const n_pages = tab_view.getNPages();

    var arr_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer arr_buf.deinit(alloc);

    arr_buf.appendSlice(alloc, "[") catch return null;
    var i: c_int = 0;
    while (i < n_pages) : (i += 1) {
        if (i > 0) arr_buf.appendSlice(alloc, ",") catch return null;
        const page = tab_view.getNthPage(i);
        const title = page.getTitle();

        arr_buf.appendSlice(alloc, "{\"index\":") catch return null;
        var idx_buf: [16]u8 = undefined;
        const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{i}) catch return null;
        arr_buf.appendSlice(alloc, idx_str) catch return null;
        arr_buf.appendSlice(alloc, ",\"title\":\"") catch return null;
        // JSON-escape the title
        if (title) |t| {
            for (std.mem.span(t)) |c| {
                if (c == '"' or c == '\\') arr_buf.append(alloc, '\\') catch return null;
                arr_buf.append(alloc, c) catch return null;
            }
        }
        arr_buf.appendSlice(alloc, "\",\"surface_count\":1}") catch return null;
    }
    arr_buf.appendSlice(alloc, "]") catch return null;

    return std.fmt.allocPrint(alloc,
        "{{\"ok\":true,\"result\":{{\"tabs\":{s}}},\"id\":{d}}}",
        .{ arr_buf.items, id },
    ) catch null;
}
```

- [ ] **Step 3: Wire into `ipcDispatch`**

Add before the `known_stubs` array (around line 1119), after the `status.report_pwd` block:

```zig
if (std.mem.eql(u8, method, "tab.list")) {
    return ipcTabList(self, alloc, id, root.object);
}
```

- [ ] **Step 4: Build to verify compilation**

Run: `/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell`
Expected: successful compilation

- [ ] **Step 5: Commit**

```bash
git add src/apprt/gtk/class/application.zig
git commit -m "feat(ipc): add workspace resolver helper and tab.list handler"
```

---

### Task 2: Add `tab.create` IPC handler

**Files:**
- Modify: `src/apprt/gtk/class/application.zig`

- [ ] **Step 1: Add the `ipcTabCreate` handler function**

Add after `ipcTabList`. This uses `window.createTabInView()` to create a tab in the target workspace's TabView. For the optional `command`, schedule a GLib timeout to write to the PTY after the shell initializes:

```zig
/// Handle tab.create — creates a new tab in a workspace.
fn ipcTabCreate(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
    const params_val = obj.get("params") orelse .null;
    if (params_val != .object) {
        return std.fmt.allocPrint(alloc,
            "{{\"ok\":false,\"error\":{{\"code\":\"invalid_params\",\"message\":\"params object required\"}},\"id\":{d}}}",
            .{id},
        ) catch null;
    }
    const params = params_val.object;

    // Resolve workspace using shared helper
    const ws_idx = self.resolveWorkspaceIdx(params) orelse {
        return std.fmt.allocPrint(alloc,
            "{{\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"workspace not found\"}},\"id\":{d}}}",
            .{id},
        ) catch null;
    };

    // Extract optional dir
    const dir: ?[:0]const u8 = blk: {
        const dv = params.get("dir") orelse break :blk null;
        switch (dv) {
            .string => |s| {
                if (s.len > 0)
                    break :blk alloc.dupeZ(u8, s) catch break :blk null;
                break :blk null;
            },
            else => break :blk null,
        }
    };
    defer if (dir) |d| alloc.free(d);

    // Get the workspace's TabView
    const tab_view = priv.workspace_tab_views.items[ws_idx];

    // Use the workspace dir as fallback
    const working_dir = dir orelse self.workspaceDir(ws_idx);

    // Create the tab via the active window
    if (self.as(gtk.Application).getActiveWindow()) |active_win| {
        if (gobject.ext.cast(Window, active_win)) |win| {
            win.createTabInView(tab_view, working_dir);

            // Set title on the newly created tab page (last page)
            const n_pages = tab_view.getNPages();
            if (n_pages > 0) {
                const page = tab_view.getNthPage(n_pages - 1);

                // Set custom title if provided
                if (params.get("title")) |tv| {
                    switch (tv) {
                        .string => |s| {
                            if (s.len > 0) {
                                const title_z = alloc.dupeZ(u8, s) catch null;
                                if (title_z) |tz| {
                                    page.setTitle(tz);
                                    alloc.free(tz);
                                }
                            }
                        },
                        else => {},
                    }
                }

                // If command provided, schedule PTY write after shell init
                if (params.get("command")) |cv| {
                    switch (cv) {
                        .string => |cmd| {
                            if (cmd.len > 0) {
                                // Use c_allocator for data that outlives the IPC call
                                const c_alloc = std.heap.c_allocator;
                                const cmd_with_newline = c_alloc.alloc(u8, cmd.len + 1) catch null;
                                if (cmd_with_newline) |cwn| {
                                    @memcpy(cwn[0..cmd.len], cmd);
                                    cwn[cmd.len] = '\n';
                                    // Schedule deferred write via 500ms GLib timer
                                    self.scheduleTabCommand(tab_view, n_pages - 1, cwn);
                                }
                            }
                        },
                        else => {},
                    }
                }

                const new_idx = n_pages - 1;
                return std.fmt.allocPrint(alloc,
                    "{{\"ok\":true,\"result\":{{\"index\":{d}}},\"id\":{d}}}",
                    .{ new_idx, id },
                ) catch null;
            }
        }
    }

    return std.fmt.allocPrint(alloc,
        "{{\"ok\":false,\"error\":{{\"code\":\"no_window\",\"message\":\"no active window\"}},\"id\":{d}}}",
        .{id},
    ) catch null;
}
```

- [ ] **Step 2: Add `scheduleTabCommand` helper for deferred PTY writes**

This schedules a GLib timeout to write a command string to a tab's terminal after 500ms, giving the shell time to initialize:

```zig
/// Context for deferred tab command execution.
const TabCommandContext = struct {
    tab_view: *adw.TabView,
    page_idx: c_int,
    command: []u8,
    alloc: std.mem.Allocator,
};

fn scheduleTabCommand(self: *Self, tab_view: *adw.TabView, page_idx: c_int, command: []u8) void {
    _ = self;
    const alloc = std.heap.c_allocator;
    const ctx = alloc.create(TabCommandContext) catch return;
    ctx.* = .{
        .tab_view = tab_view,
        .page_idx = page_idx,
        .command = command,
        .alloc = alloc,
    };
    _ = glib.timeoutAdd(500, &tabCommandCallback, ctx);
}

fn tabCommandCallback(ud: ?*anyopaque) callconv(.c) c_int {
    const ctx: *TabCommandContext = @ptrCast(@alignCast(ud orelse return glib.SOURCE_REMOVE));
    defer {
        ctx.alloc.free(ctx.command);
        ctx.alloc.destroy(ctx);
    }

    const n_pages = ctx.tab_view.getNPages();
    if (ctx.page_idx >= n_pages) return glib.SOURCE_REMOVE;

    const page = ctx.tab_view.getNthPage(ctx.page_idx);
    const child = page.getChild();

    // The child is a Tab widget. Get its active surface and write to PTY.
    // The actual write path is: Tab -> getActiveSurface() -> GTK Surface -> .core() -> CoreSurface -> IO write
    if (gobject.ext.cast(Tab, child)) |tab| {
        if (tab.getActiveSurface()) |surface| {
            if (surface.core()) |core_surface| {
                // Use the core surface's IO to write to PTY
                // The exact method depends on the Ghostty IO interface — look for
                // queueWrite, ptyWrite, or messageWriter in the CoreSurface/Termio code
                core_surface.io.queueWrite(ctx.command) catch {};
            }
        }
    }

    return glib.SOURCE_REMOVE; // One-shot timer
}
```

**Implementation note:** The PTY write chain is: `Tab.getActiveSurface()` → GTK `Surface` → `.core()` → `CoreSurface` → IO write. The implementer should verify the exact method by searching for how keyboard input reaches the PTY in `src/apprt/gtk/class/surface.zig` (look for `queueWrite`, `ptyWrite`, or `messageWriter`).

- [ ] **Step 3: Wire into `ipcDispatch`**

Add after the `tab.list` dispatch entry:

```zig
if (std.mem.eql(u8, method, "tab.create")) {
    return ipcTabCreate(self, alloc, id, root.object);
}
```

- [ ] **Step 4: Build to verify compilation**

Run: `/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell`
Expected: successful compilation. If `Tab.getFocusedSurface()` or `surface.io.queueWrite()` don't exist with those exact names, find the equivalent by reading `src/apprt/gtk/class/tab.zig` and the Surface class.

- [ ] **Step 5: Commit**

```bash
git add src/apprt/gtk/class/application.zig
git commit -m "feat(ipc): add tab.create handler with deferred command execution"
```

---

### Task 3: Create `termplex-ctl` Python CLI

**Files:**
- Create: `tools/termplex-ctl`

- [ ] **Step 1: Write the complete CLI script**

Create `tools/termplex-ctl` — a single-file Python 3 CLI with no external dependencies. The script connects to the Unix socket, sends a JSON request, reads the JSON response, and prints it.

```python
#!/usr/bin/env python3
"""termplex-ctl — CLI for controlling Termplex via IPC socket."""

import argparse
import json
import os
import socket
import sys

def get_socket_path():
    """Resolve socket path: $TERMPLEX_SOCKET > $XDG_RUNTIME_DIR/termplex.sock > /tmp/termplex-{uid}.sock"""
    env = os.environ.get("TERMPLEX_SOCKET")
    if env:
        return env
    xdg = os.environ.get("XDG_RUNTIME_DIR")
    if xdg:
        return os.path.join(xdg, "termplex.sock")
    return f"/tmp/termplex-{os.getuid()}.sock"

def send_request(method, params=None, socket_path=None):
    """Send a JSON-RPC request to the Termplex IPC socket and return the parsed response."""
    if socket_path is None:
        socket_path = get_socket_path()

    request = {"method": method, "params": params or {}, "id": 1}
    request_json = json.dumps(request) + "\n"

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(socket_path)
        sock.sendall(request_json.encode("utf-8"))

        # Read response (up to 64KB)
        data = b""
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            data += chunk
            if b"\n" in data:
                break

        response_str = data.decode("utf-8").strip()
        if not response_str:
            return {"ok": False, "error": {"code": "empty_response", "message": "empty response from server"}}
        return json.loads(response_str)
    except FileNotFoundError:
        print(f"Error: Socket not found at {socket_path}", file=sys.stderr)
        print("Is Termplex running?", file=sys.stderr)
        sys.exit(1)
    except ConnectionRefusedError:
        print(f"Error: Connection refused at {socket_path}", file=sys.stderr)
        sys.exit(1)
    finally:
        sock.close()

def format_human(response):
    """Format a response for human-readable output."""
    if not response.get("ok"):
        err = response.get("error", {})
        return f"Error [{err.get('code', 'unknown')}]: {err.get('message', 'unknown error')}"
    result = response.get("result")
    if result is None:
        return "OK"
    if isinstance(result, str):
        return result
    return json.dumps(result, indent=2)

def main():
    parser = argparse.ArgumentParser(prog="termplex-ctl", description="Control Termplex via IPC")
    parser.add_argument("--human", action="store_true", help="Human-readable output (default: JSON)")
    parser.add_argument("--socket", help="Override socket path")
    subparsers = parser.add_subparsers(dest="resource")

    # --- ping ---
    subparsers.add_parser("ping", help="Ping the server")

    # --- status ---
    subparsers.add_parser("status", help="Get server status")

    # --- workspace ---
    ws = subparsers.add_parser("workspace", help="Workspace operations")
    ws_sub = ws.add_subparsers(dest="action")

    ws_sub.add_parser("list", help="List workspaces")

    ws_create = ws_sub.add_parser("create", help="Create workspace")
    ws_create.add_argument("--name", help="Workspace name")
    ws_create.add_argument("--dir", help="Working directory")

    ws_select = ws_sub.add_parser("select", help="Select workspace")
    ws_select.add_argument("--name", help="Workspace name")
    ws_select.add_argument("--index", type=int, help="Workspace index")

    ws_close = ws_sub.add_parser("close", help="Close workspace")
    ws_close.add_argument("--name", help="Workspace name")
    ws_close.add_argument("--index", type=int, help="Workspace index")

    ws_rename = ws_sub.add_parser("rename", help="Rename workspace")
    ws_rename.add_argument("--name", required=True, help="Current name")
    ws_rename.add_argument("--new-name", required=True, help="New name")

    # --- tab ---
    tab = subparsers.add_parser("tab", help="Tab operations")
    tab_sub = tab.add_subparsers(dest="action")

    tab_list = tab_sub.add_parser("list", help="List tabs")
    tab_list.add_argument("--workspace", required=True, help="Workspace name or index")

    tab_create = tab_sub.add_parser("create", help="Create tab")
    tab_create.add_argument("--workspace", required=True, help="Workspace name or index")
    tab_create.add_argument("--title", help="Tab title")
    tab_create.add_argument("--dir", help="Working directory")
    tab_create.add_argument("--command", help="Command to run")

    # --- surface ---
    surface = subparsers.add_parser("surface", help="Surface/terminal operations")
    surface_sub = surface.add_subparsers(dest="action")

    surface_send = surface_sub.add_parser("send", help="Send text to terminal")
    surface_send.add_argument("--workspace", required=True, help="Workspace name or index")
    surface_send.add_argument("--tab", required=True, type=int, help="Tab index")
    surface_send.add_argument("text", help="Text to send (use \\n for Enter)")

    surface_read = surface_sub.add_parser("read", help="Read terminal output")
    surface_read.add_argument("--workspace", required=True, help="Workspace name or index")
    surface_read.add_argument("--tab", required=True, type=int, help="Tab index")
    surface_read.add_argument("--lines", type=int, default=50, help="Number of lines (default: 50)")

    # --- agent ---
    agent = subparsers.add_parser("agent", help="Agent operations")
    agent_sub = agent.add_subparsers(dest="action")

    agent_sub.add_parser("list", help="List registered agents")

    agent_reg = agent_sub.add_parser("register", help="Register agent")
    agent_reg.add_argument("--workspace", required=True, help="Workspace name or index")
    agent_reg.add_argument("--tab", required=True, type=int, help="Tab index")
    agent_reg.add_argument("--type", required=True, choices=["claude", "codex", "custom"], help="Agent type")
    agent_reg.add_argument("--pid", required=True, type=int, help="Agent PID")

    agent_unreg = agent_sub.add_parser("unregister", help="Unregister agent")
    agent_unreg.add_argument("--pid", required=True, type=int, help="Agent PID")

    agent_term = agent_sub.add_parser("terminate", help="Terminate agent")
    agent_term.add_argument("--pid", required=True, type=int, help="Agent PID")
    agent_term.add_argument("--policy", choices=["keep", "terminate"], help="Override tab policy")

    args = parser.parse_args()

    if not args.resource:
        parser.print_help()
        sys.exit(1)

    # Build IPC method and params
    method, params = build_request(args)
    if method is None:
        parser.print_help()
        sys.exit(1)

    response = send_request(method, params, socket_path=args.socket)

    if args.human:
        print(format_human(response))
    else:
        print(json.dumps(response))

    sys.exit(0 if response.get("ok") else 1)

def parse_workspace_ref(value):
    """Parse workspace argument: try integer first, fall back to string name."""
    try:
        return int(value)
    except (ValueError, TypeError):
        return value

def build_request(args):
    """Map parsed args to (method, params) tuple."""
    resource = args.resource
    action = getattr(args, "action", None)

    if resource == "ping":
        return "system.ping", {}

    if resource == "status":
        return "system.tree", {}

    if resource == "workspace":
        if action == "list":
            return "workspace.list", {}
        if action == "create":
            p = {}
            if args.name:
                p["name"] = args.name
            if args.dir:
                p["dir"] = args.dir
            return "workspace.create", p
        if action == "select":
            p = {}
            if args.name:
                p["ref"] = args.name
            if args.index is not None:
                p["index"] = args.index
            return "workspace.select", p
        if action == "close":
            p = {}
            if args.name:
                p["ref"] = args.name
            if args.index is not None:
                p["index"] = args.index
            return "workspace.close", p
        if action == "rename":
            return "workspace.rename", {"name": args.name, "new_name": args.new_name}
        return None, None

    if resource == "tab":
        if action == "list":
            return "tab.list", {"workspace": parse_workspace_ref(args.workspace)}
        if action == "create":
            p = {"workspace": parse_workspace_ref(args.workspace)}
            if args.title:
                p["title"] = args.title
            if args.dir:
                p["dir"] = args.dir
            if args.command:
                p["command"] = args.command
            return "tab.create", p
        return None, None

    if resource == "surface":
        if action == "send":
            return "surface.send", {
                "workspace": parse_workspace_ref(args.workspace),
                "tab": args.tab,
                "text": args.text.replace("\\n", "\n"),
            }
        if action == "read":
            return "surface.read", {
                "workspace": parse_workspace_ref(args.workspace),
                "tab": args.tab,
                "lines": args.lines,
            }
        return None, None

    if resource == "agent":
        if action == "list":
            return "agent.list", {}
        if action == "register":
            return "agent.register", {
                "workspace": parse_workspace_ref(args.workspace),
                "tab": args.tab,
                "type": args.type,
                "pid": args.pid,
            }
        if action == "unregister":
            return "agent.unregister", {"pid": args.pid}
        if action == "terminate":
            p = {"pid": args.pid}
            if args.policy:
                p["policy"] = args.policy
            return "agent.terminate", p
        return None, None

    return None, None

if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Make the script executable**

```bash
chmod +x tools/termplex-ctl
```

- [ ] **Step 3: Commit**

```bash
git add tools/termplex-ctl
git commit -m "feat: add termplex-ctl CLI tool for IPC control"
```

---

### Task 4: Install `termplex-ctl` in build system

**Files:**
- Modify: `src/build/TermplexResources.zig`

- [ ] **Step 1: Add termplex-ctl installation**

In `TermplexResources.zig`, inside the `init` function where other files are installed via `b.addInstallFile()`, add:

```zig
// Install termplex-ctl CLI tool
try steps.append(b.allocator, &b.addInstallFile(
    b.path("tools/termplex-ctl"),
    "bin/termplex-ctl",
).step);
```

Add this near the other `addInstallFile` calls (around line 370-430 area, after the desktop file installations).

- [ ] **Step 2: Build and verify**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
ls -la zig-out/bin/termplex-ctl
```

Expected: `termplex-ctl` appears in `zig-out/bin/`

- [ ] **Step 3: Commit**

```bash
git add src/build/TermplexResources.zig
git commit -m "build: install termplex-ctl to bin/"
```

---

### Task 5: Integration test — IPC + CLI

- [ ] **Step 1: Manual integration test**

Start Termplex and test the IPC commands:

```bash
# In one terminal, start Termplex
./zig-out/bin/termplex-app &

# Test ping
./zig-out/bin/termplex-ctl ping
# Expected: {"ok": true, "result": "pong", "id": 1}

# Test workspace list
./zig-out/bin/termplex-ctl workspace list
# Expected: {"ok": true, "result": {"workspaces": [...], "active": 0}, "id": 1}

# Test tab list
./zig-out/bin/termplex-ctl tab list --workspace 0
# Expected: {"ok": true, "result": {"tabs": [{"index": 0, "title": "...", "surface_count": 1}]}, "id": 1}

# Test workspace create
./zig-out/bin/termplex-ctl workspace create --dir /tmp
# Expected: {"ok": true, "result": {"index": 1}, "id": 1}

# Test tab create
./zig-out/bin/termplex-ctl tab create --workspace 0 --title "test-tab"
# Expected: {"ok": true, "result": {"index": 1}, "id": 1}

# Test human-readable output
./zig-out/bin/termplex-ctl --human workspace list
```

- [ ] **Step 2: Verify error handling**

```bash
# Test unknown method
./zig-out/bin/termplex-ctl surface send --workspace 0 --tab 0 "test"
# Expected: error (surface.send not implemented yet — this is expected until Chunk 5)

# Test invalid workspace
./zig-out/bin/termplex-ctl tab list --workspace "nonexistent"
# Expected: {"ok": false, "error": {"code": "not_found", ...}}
```

---

## Chunk 2: Configuration + Orchestration Workspace

### Task 6: Wire TermplexConfig into Application

**Files:**
- Modify: `src/apprt/gtk/class/application.zig`

**Context:** The `TermplexConfig` module (`src/termplex/core/config.zig`) exists but is NOT currently imported or used in the GTK application code. The orchestration workspace, first-run dialog, and agent management all depend on reading config values. This task wires the config into Application.

- [ ] **Step 1: Import config module**

At the top of `application.zig`, add (follow the existing pattern for `git_probe.zig` import):

```zig
const termplex_config = @import("../../../termplex/core/config.zig");
```

- [ ] **Step 2: Add TermplexConfig to Private struct**

In the Private struct, add:

```zig
termplex_cfg: termplex_config.TermplexConfig,
```

- [ ] **Step 3: Load config at startup**

In the Application initialization (look for where `priv` fields are first set), add:

```zig
priv.termplex_cfg = termplex_config.TermplexConfig.load(std.heap.c_allocator) catch
    termplex_config.TermplexConfig.default(std.heap.c_allocator);
```

- [ ] **Step 4: Free config in deinit**

In the Application dispose/deinit function, add:

```zig
priv.termplex_cfg.deinit();
```

- [ ] **Step 5: Build and verify**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

- [ ] **Step 6: Commit**

```bash
git add src/apprt/gtk/class/application.zig
git commit -m "feat: wire TermplexConfig into Application for config access"
```

---

### Task 7: Add `[orchestration]` config section (was Task 6)

**Files:**
- Modify: `src/termplex/core/config.zig`

- [ ] **Step 1: Add the Orchestration struct and fields**

After the `Session` struct definition (around line 89), add:

```zig
/// Orchestration workspace configuration.
pub const Orchestration = struct {
    /// null = not set (show first-run dialog), true = enabled, false = disabled
    enabled: ?bool,
    /// Path to orchestration data directory.
    dir: []const u8,
    /// CLI command to launch in orchestration workspace.
    agent_command: []const u8,
    /// "keep" = leave tab open after agent exits, "terminate" = close tab.
    agent_terminate_policy: []const u8,
};
```

- [ ] **Step 2: Add orchestration field to TermplexConfig**

In the `TermplexConfig` struct, after the `session` field (line 111), add:

```zig
// [orchestration]
orchestration: Orchestration,
```

- [ ] **Step 3: Add defaults**

In `TermplexConfig.default()`, after `.session = .{...}`, add:

```zig
.orchestration = .{
    .enabled = null,
    .dir = "~/.termplex/orchestration",
    .agent_command = "claude",
    .agent_terminate_policy = "keep",
},
```

- [ ] **Step 4: Add deinit for orchestration strings**

In `TermplexConfig.deinit()`, after the existing string frees (around line 190), add:

```zig
self.allocator.free(self.orchestration.dir);
self.allocator.free(self.orchestration.agent_command);
self.allocator.free(self.orchestration.agent_terminate_policy);
```

- [ ] **Step 5: Add parsing for [orchestration] section**

In `parseConfig()`, add heap-owned copies after the other string initializations (around line 291):

```zig
var orch_dir = try allocator.dupe(u8, cfg.orchestration.dir);
errdefer allocator.free(orch_dir);
var orch_agent_command = try allocator.dupe(u8, cfg.orchestration.agent_command);
errdefer allocator.free(orch_agent_command);
var orch_agent_terminate_policy = try allocator.dupe(u8, cfg.orchestration.agent_terminate_policy);
errdefer allocator.free(orch_agent_terminate_policy);
```

In the section dispatch (around line 393, before the comment about unknown sections), add:

```zig
} else if (std.mem.eql(u8, current_section, "orchestration")) {
    if (std.mem.eql(u8, key, "enabled")) {
        cfg.orchestration.enabled = parseBool(value);
    } else if (std.mem.eql(u8, key, "dir")) {
        allocator.free(orch_dir);
        orch_dir = try allocator.dupe(u8, unquote(value));
    } else if (std.mem.eql(u8, key, "agent_command")) {
        allocator.free(orch_agent_command);
        orch_agent_command = try allocator.dupe(u8, unquote(value));
    } else if (std.mem.eql(u8, key, "agent_terminate_policy")) {
        allocator.free(orch_agent_terminate_policy);
        orch_agent_terminate_policy = try allocator.dupe(u8, unquote(value));
    }
}
```

In the "commit all heap-owned strings" section (around line 413), add:

```zig
cfg.orchestration.dir = orch_dir;
cfg.orchestration.agent_command = orch_agent_command;
cfg.orchestration.agent_terminate_policy = orch_agent_terminate_policy;
```

- [ ] **Step 6: Add tests**

At the bottom of `config.zig`, in the test section, add:

```zig
test "orchestration config defaults" {
    const alloc = std.testing.allocator;
    const cfg = TermplexConfig.default(alloc);
    // default() doesn't allocate, so no deinit needed
    try std.testing.expect(cfg.orchestration.enabled == null);
    try std.testing.expectEqualStrings("~/.termplex/orchestration", cfg.orchestration.dir);
    try std.testing.expectEqualStrings("claude", cfg.orchestration.agent_command);
    try std.testing.expectEqualStrings("keep", cfg.orchestration.agent_terminate_policy);
}

test "orchestration config parse" {
    const alloc = std.testing.allocator;
    const toml =
        \\[orchestration]
        \\enabled = true
        \\dir = "/custom/path"
        \\agent_command = "codex"
        \\agent_terminate_policy = "terminate"
    ;
    var cfg = try parseConfig(alloc, toml);
    defer cfg.deinit();
    try std.testing.expect(cfg.orchestration.enabled.? == true);
    try std.testing.expectEqualStrings("/custom/path", cfg.orchestration.dir);
    try std.testing.expectEqualStrings("codex", cfg.orchestration.agent_command);
    try std.testing.expectEqualStrings("terminate", cfg.orchestration.agent_terminate_policy);
}

test "orchestration enabled null when absent" {
    const alloc = std.testing.allocator;
    const toml =
        \\[session]
        \\restore_on_startup = true
    ;
    var cfg = try parseConfig(alloc, toml);
    defer cfg.deinit();
    try std.testing.expect(cfg.orchestration.enabled == null);
}
```

- [ ] **Step 7: Run tests**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build test -Dtest-filter="orchestration"
```

Expected: All 3 orchestration tests pass.

- [ ] **Step 8: Commit**

```bash
git add src/termplex/core/config.zig
git commit -m "feat(config): add [orchestration] section with ?bool enabled"
```

---

### Task 7: Create orchestration workspace on startup

**Files:**
- Modify: `src/apprt/gtk/class/application.zig`

- [ ] **Step 1: Add orchestration workspace state to Private struct**

In the Application Private struct (around line 238, after `active_workspace_idx`), add:

```zig
/// Index of the orchestration workspace (null if orchestration disabled).
orchestration_workspace_idx: ?u32 = null,
/// Whether the orchestration agent has been launched in this session.
orchestration_launched: bool = false,
```

- [ ] **Step 2: Create orchestration workspace in `activate`**

In the `activate` callback (the GTK Application activate signal handler), before restoring user workspaces / creating the first window, add logic to create the orchestration workspace if enabled:

```zig
// Create orchestration workspace if enabled (termplex_cfg was loaded in Task 6)
const termplex_cfg = priv.termplex_cfg;
if (termplex_cfg.orchestration.enabled orelse false) {
    // Create workspace named "ORCHESTRATOR" with the orchestration dir
    const orch_dir_z = alloc.dupeZ(u8, termplex_cfg.orchestration.dir) catch null;
    defer if (orch_dir_z) |d| alloc.free(d);
    const orch_idx = self.addWorkspaceWithDir(orch_dir_z);
    if (orch_idx) |idx| {
        self.renameWorkspace(idx, "ORCHESTRATOR");
        priv.orchestration_workspace_idx = idx;
    }
}
```

**Note:** The implementer must find where `activate` is (search for the GApplication activate signal connection) and where the TermplexConfig is accessible from Application. The orchestration workspace must be created BEFORE restoring user workspaces so it's always at index 0.

- [ ] **Step 3: Exclude orchestration workspace from session save**

In `autosaveSession()` (around line 1462), when iterating workspaces to build the JSON, skip the orchestration workspace:

```zig
for (priv.workspace_names.items, 0..) |name, idx| {
    // Skip orchestration workspace — it's recreated on startup
    if (priv.orchestration_workspace_idx) |orch_idx| {
        if (idx == orch_idx) continue;
    }
    // ... existing serialization code
}
```

- [ ] **Step 4: Build and verify**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

- [ ] **Step 5: Commit**

```bash
git add src/apprt/gtk/class/application.zig
git commit -m "feat: create orchestration workspace on startup when enabled"
```

---

### Task 8: Orchestrator sidebar rendering

**Files:**
- Modify: `src/apprt/gtk/class/sidebar.zig`
- Modify: `src/apprt/gtk/css/style.css`

- [ ] **Step 1: Add orchestrator index tracking to sidebar**

In the Sidebar Private struct, add:

```zig
/// Index of the orchestration workspace (null if none). Set by Application.
orchestration_idx: ?u32 = null,
```

Add a public setter:

```zig
pub fn setOrchestrationIndex(self: *Self, idx: ?u32) void {
    self.private().orchestration_idx = idx;
}
```

- [ ] **Step 2: Disable context menu for orchestrator**

In `onRightClick` (around line 180), at the top of the function, add:

```zig
const priv = self.private();
if (priv.orchestration_idx) |orch_idx| {
    if (row_idx == orch_idx) return; // No context menu for orchestrator
}
```

- [ ] **Step 3: Add separator after orchestrator in sidebar**

When the orchestration workspace is added to the sidebar (in Application's workspace creation flow or sidebar initialization), a CSS separator should be inserted after the orchestrator row.

In `sidebar.zig`, add a method to insert a visual separator:

```zig
pub fn addOrchestrationSeparator(self: *Self) void {
    const sep = gtk.Separator.new(.horizontal);
    sep.as(gtk.Widget).addCssClass("termplex-orchestration-separator");
    self.private().workspace_list.as(gtk.ListBox).prepend(sep.as(gtk.Widget));
    // The separator is inserted after index 0 (the orchestrator row)
}
```

Alternatively, add a CSS bottom border on the orchestrator row. The simpler approach:

In the `addWorkspace` method or via `updateWorkspace`, when the workspace is the orchestrator, add a CSS class:

```zig
// In the method that creates workspace rows, check if it's the orchestrator
if (priv.orchestration_idx) |orch_idx| {
    if (idx == orch_idx) {
        row.as(gtk.Widget).addCssClass("termplex-orchestrator-row");
    }
}
```

- [ ] **Step 4: Add CSS styles for orchestrator**

In `src/apprt/gtk/css/style.css`, add:

```css
/* Orchestrator workspace row */
.termplex-orchestrator-row {
    border-bottom: 1px solid #243447;
    margin-bottom: 4px;
    padding-bottom: 4px;
}

/* Orchestrator label styling — overrides normal tab name */
.termplex-orchestrator-label {
    color: #00d4ff;
    font-weight: 800;
    font-size: 10px;
    letter-spacing: 1.5px;
}
```

- [ ] **Step 5: Build, clean cache, verify**

```bash
rm -rf .zig-cache
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

(Clean cache needed because CSS is compiled into binary via GResource)

- [ ] **Step 6: Commit**

```bash
git add src/apprt/gtk/class/sidebar.zig src/apprt/gtk/css/style.css
git commit -m "feat: orchestrator sidebar rendering with visual separation"
```

---

## Chunk 3: First-Run GTK Dialog

### Task 9: First-run orchestration dialog

**Files:**
- Modify: `src/apprt/gtk/class/application.zig`

- [ ] **Step 1: Add orchestration dialog function**

The dialog uses `adw.MessageDialog` (following the pattern from existing dialogs like `close_confirmation_dialog.zig`). Add a function to Application:

```zig
/// Show the first-run orchestration dialog if orchestration.enabled is null.
fn showOrchestrationDialog(self: *Self) void {
    const priv = self.private();

    // Only show if enabled is null (never configured)
    if (priv.termplex_cfg.orchestration.enabled != null) return;

    const active_win = self.as(gtk.Application).getActiveWindow() orelse return;

    const dialog = adw.MessageDialog.new(
        active_win,
        "Enable Orchestration?",
        "Termplex can run an AI agent that manages your workspaces, tabs, and terminal sessions. Enable orchestration to get started, or skip to set this up later.",
    );

    dialog.addResponse("skip", "Skip");
    dialog.addResponse("enable", "Enable");
    dialog.setResponseAppearance("enable", .suggested);
    dialog.setDefaultResponse("enable");

    _ = dialog.connectResponse(struct {
        fn callback(d: *adw.MessageDialog, response: [*:0]const u8, ud: ?*anyopaque) callconv(.c) void {
            const app: *Self = @ptrCast(@alignCast(ud orelse return));
            if (std.mem.eql(u8, std.mem.span(response), "enable")) {
                app.enableOrchestration();
            } else {
                app.disableOrchestration();
            }
            d.as(gtk.Window).destroy();
        }
    }.callback, self);

    dialog.as(gtk.Window).present();
}
```

- [ ] **Step 2: Add `enableOrchestration` helper**

```zig
fn enableOrchestration(self: *Self) void {
    const alloc = std.heap.c_allocator;

    // 1. Create orchestration directory structure (recursive)
    const home = std.posix.getenv("HOME") orelse return;
    const orch_path = std.fmt.allocPrint(alloc, "{s}/.termplex/orchestration", .{home}) catch return;
    defer alloc.free(orch_path);

    // Create parent + subdirectories using makePath (creates parents recursively)
    const dirs = [_][]const u8{ "skill", "logs", "state" };
    for (dirs) |subdir| {
        const full = std.fmt.allocPrint(alloc, "{s}/{s}", .{ orch_path, subdir }) catch continue;
        defer alloc.free(full);
        // makePath creates all missing parent directories
        std.fs.makePath(std.fs.cwd(), full) catch continue;
    }

    // 2. Copy skill files to orchestration directory
    // termplex.md goes to skill/
    self.copyResourceFile("share/termplex/skill/termplex.md", orch_path, "skill/termplex.md");
    // AGENTS.md goes to orchestration root (for Codex auto-discovery)
    self.copyResourceFile("share/termplex/skill/AGENTS.md", orch_path, "AGENTS.md");

    // 3. Write orchestration.enabled = true to config.toml
    self.writeOrchestrationConfig(true, orch_path, "claude");

    // 3. Create the orchestration workspace
    const orch_dir_z = alloc.dupeZ(u8, orch_path) catch return;
    defer alloc.free(orch_dir_z);
    const priv = self.private();
    const orch_idx = self.addWorkspaceWithDir(orch_dir_z);
    if (orch_idx) |idx| {
        self.renameWorkspace(idx, "ORCHESTRATOR");
        priv.orchestration_workspace_idx = idx;
    }
}

fn disableOrchestration(self: *Self) void {
    self.writeOrchestrationConfig(false, null, null);
}
```

- [ ] **Step 3: Add config file writer and resource copy helper**

```zig
fn writeOrchestrationConfig(self: *Self, enabled: bool, dir: ?[]const u8, agent_command: ?[]const u8) void {
    _ = self;
    const alloc = std.heap.c_allocator;
    const home = std.posix.getenv("HOME") orelse return;
    const config_path = std.fmt.allocPrint(alloc, "{s}/.config/termplex/config.toml", .{home}) catch return;
    defer alloc.free(config_path);

    // Read existing config
    var existing: []u8 = &.{};
    const existing_owned = blk: {
        const file = std.fs.openFileAbsolute(config_path, .{}) catch break :blk false;
        defer file.close();
        existing = file.readToEndAlloc(alloc, 1024 * 1024) catch break :blk false;
        break :blk true;
    };
    defer if (existing_owned) alloc.free(existing);

    // Strip any existing [orchestration] section to avoid duplicates
    var cleaned = std.ArrayList(u8).init(alloc);
    defer cleaned.deinit();
    var in_orch_section = false;
    var line_iter = std.mem.splitScalar(u8, existing, '\n');
    while (line_iter.next()) |line| {
        if (line.len > 0 and line[0] == '[') {
            in_orch_section = std.mem.startsWith(u8, line, "[orchestration]");
        }
        if (!in_orch_section) {
            cleaned.appendSlice(line) catch continue;
            cleaned.append('\n') catch continue;
        }
    }

    // Build the new orchestration section
    var buf: [512]u8 = undefined;
    const section = if (enabled)
        std.fmt.bufPrint(&buf, "\n[orchestration]\nenabled = true\ndir = \"{s}\"\nagent_command = \"{s}\"\nagent_terminate_policy = \"keep\"\n", .{
            dir orelse "~/.termplex/orchestration",
            agent_command orelse "claude",
        }) catch return
    else
        std.fmt.bufPrint(&buf, "\n[orchestration]\nenabled = false\n", .{}) catch return;

    cleaned.appendSlice(section) catch return;

    // Ensure config directory exists
    const config_dir = std.fmt.allocPrint(alloc, "{s}/.config/termplex", .{home}) catch return;
    defer alloc.free(config_dir);
    std.fs.makePath(std.fs.cwd(), config_dir) catch {};

    const file = std.fs.createFileAbsolute(config_path, .{}) catch return;
    defer file.close();
    file.writeAll(cleaned.items) catch {};
}

/// Copy a resource file from the install prefix to the orchestration directory.
fn copyResourceFile(self: *Self, relative_src: []const u8, orch_dir: []const u8, relative_dst: []const u8) void {
    _ = self;
    const alloc = std.heap.c_allocator;
    // Try common install prefixes
    const prefixes = [_][]const u8{ "/usr/local", "/usr", "zig-out" };
    for (prefixes) |prefix| {
        const src = std.fmt.allocPrint(alloc, "{s}/{s}", .{ prefix, relative_src }) catch continue;
        defer alloc.free(src);
        const dst = std.fmt.allocPrint(alloc, "{s}/{s}", .{ orch_dir, relative_dst }) catch continue;
        defer alloc.free(dst);
        std.fs.copyFileAbsolute(src, dst, .{}) catch continue;
        return; // Success
    }
}
```

- [ ] **Step 4: Wire dialog to app startup**

In the `activate` callback, after window creation but before showing, call:

```zig
self.showOrchestrationDialog();
```

- [ ] **Step 5: Build and verify**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

- [ ] **Step 6: Manual test**

1. Remove any `[orchestration]` section from `~/.config/termplex/config.toml`
2. Start `./zig-out/bin/termplex-app`
3. Verify dialog appears
4. Click "Enable" → verify directory created at `~/.termplex/orchestration/` and config updated
5. Restart app → verify dialog does NOT appear again
6. Verify ORCHESTRATOR workspace is in sidebar

- [ ] **Step 7: Commit**

```bash
git add src/apprt/gtk/class/application.zig
git commit -m "feat: add first-run orchestration dialog with config persistence"
```

---

## Chunk 4: Agent Registration + Skill Files

### Task 10: Agent registry module

**Files:**
- Create: `src/termplex/ipc/agents.zig`

- [ ] **Step 1: Create the agent registry**

```zig
// src/termplex/ipc/agents.zig
// Agent registry: tracks AI agents running in terminal workspaces.
// Agents register via IPC and are discovered on-demand.

const std = @import("std");
const log = std.log.scoped(.agents);

pub const AgentType = enum {
    claude,
    codex,
    custom,

    pub fn fromString(s: []const u8) ?AgentType {
        if (std.mem.eql(u8, s, "claude")) return .claude;
        if (std.mem.eql(u8, s, "codex")) return .codex;
        if (std.mem.eql(u8, s, "custom")) return .custom;
        return null;
    }

    pub fn toString(self: AgentType) []const u8 {
        return switch (self) {
            .claude => "claude",
            .codex => "codex",
            .custom => "custom",
        };
    }
};

pub const Agent = struct {
    agent_id: [6]u8, // hex string
    workspace: []const u8, // workspace name (owned)
    tab: u32,
    agent_type: AgentType,
    pid: i32,
};

pub const AgentRegistry = struct {
    allocator: std.mem.Allocator,
    agents: std.ArrayListUnmanaged(Agent),
    next_id: u32,

    pub fn init(allocator: std.mem.Allocator) AgentRegistry {
        return .{
            .allocator = allocator,
            .agents = .empty,
            .next_id = 1,
        };
    }

    pub fn deinit(self: *AgentRegistry) void {
        for (self.agents.items) |agent| {
            self.allocator.free(agent.workspace);
        }
        self.agents.deinit(self.allocator);
    }

    /// Register a new agent. Returns the agent_id hex string.
    pub fn register(self: *AgentRegistry, workspace: []const u8, tab: u32, agent_type: AgentType, pid: i32) ![6]u8 {
        // Generate agent_id from counter
        var id_buf: [6]u8 = undefined;
        _ = std.fmt.bufPrint(&id_buf, "{x:0>6}", .{self.next_id}) catch return error.OutOfMemory;
        self.next_id += 1;

        const ws_owned = try self.allocator.dupe(u8, workspace);
        errdefer self.allocator.free(ws_owned);

        try self.agents.append(self.allocator, .{
            .agent_id = id_buf,
            .workspace = ws_owned,
            .tab = tab,
            .agent_type = agent_type,
            .pid = pid,
        });

        return id_buf;
    }

    /// Unregister an agent by PID.
    pub fn unregister(self: *AgentRegistry, pid: i32) bool {
        for (self.agents.items, 0..) |agent, idx| {
            if (agent.pid == pid) {
                self.allocator.free(agent.workspace);
                _ = self.agents.orderedRemove(idx);
                return true;
            }
        }
        return false;
    }

    /// Check if a PID is still alive using kill(pid, 0).
    pub fn isAlive(pid: i32) bool {
        std.posix.kill(@intCast(pid), 0) catch |err| {
            return switch (err) {
                error.ProcessNotFound => false,
                error.PermissionDenied => true, // process exists but no permission
                else => false,
            };
        };
        return true; // kill(pid, 0) succeeded — process exists
    }

    /// Remove all dead agents (PIDs that no longer exist).
    pub fn cleanupDead(self: *AgentRegistry) void {
        var i: usize = 0;
        while (i < self.agents.items.len) {
            if (!isAlive(self.agents.items[i].pid)) {
                self.allocator.free(self.agents.items[i].workspace);
                _ = self.agents.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Persist registry to JSON file.
    pub fn save(self: *AgentRegistry, path: []const u8) void {
        const alloc = self.allocator;

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(alloc);

        buf.appendSlice(alloc, "{\"agents\":[") catch return;
        for (self.agents.items, 0..) |agent, idx| {
            if (idx > 0) buf.appendSlice(alloc, ",") catch return;
            buf.appendSlice(alloc, "{\"agent_id\":\"") catch return;
            buf.appendSlice(alloc, &agent.agent_id) catch return;
            buf.appendSlice(alloc, "\",\"workspace\":\"") catch return;
            buf.appendSlice(alloc, agent.workspace) catch return;
            buf.appendSlice(alloc, "\",\"tab\":") catch return;
            var num_buf: [16]u8 = undefined;
            const tab_str = std.fmt.bufPrint(&num_buf, "{d}", .{agent.tab}) catch return;
            buf.appendSlice(alloc, tab_str) catch return;
            buf.appendSlice(alloc, ",\"type\":\"") catch return;
            buf.appendSlice(alloc, agent.agent_type.toString()) catch return;
            buf.appendSlice(alloc, "\",\"pid\":") catch return;
            const pid_str = std.fmt.bufPrint(&num_buf, "{d}", .{agent.pid}) catch return;
            buf.appendSlice(alloc, pid_str) catch return;
            buf.appendSlice(alloc, "}") catch return;
        }
        buf.appendSlice(alloc, "]}") catch return;

        // Atomic write: write to .tmp then rename
        const tmp_path = std.fmt.allocPrint(alloc, "{s}.tmp", .{path}) catch return;
        defer alloc.free(tmp_path);

        const file = std.fs.createFileAbsolute(tmp_path, .{}) catch return;
        file.writeAll(buf.items) catch {
            file.close();
            return;
        };
        file.close();

        std.fs.renameAbsolute(tmp_path, path) catch {};
    }
};

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

test "agent registry register and unregister" {
    const alloc = std.testing.allocator;
    var registry = AgentRegistry.init(alloc);
    defer registry.deinit();

    const id = try registry.register("backend", 0, .claude, 12345);
    try std.testing.expectEqual(@as(usize, 1), registry.agents.items.len);
    try std.testing.expectEqualStrings("000001", &id);

    const found = registry.unregister(12345);
    try std.testing.expect(found);
    try std.testing.expectEqual(@as(usize, 0), registry.agents.items.len);
}

test "agent registry unregister nonexistent returns false" {
    const alloc = std.testing.allocator;
    var registry = AgentRegistry.init(alloc);
    defer registry.deinit();

    try std.testing.expect(!registry.unregister(99999));
}
```

- [ ] **Step 2: Build and run tests**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build test -Dtest-filter="agent registry"
```

Expected: Both tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/termplex/ipc/agents.zig
git commit -m "feat: add agent registry module with tests"
```

---

### Task 11: Agent IPC handlers

**Files:**
- Modify: `src/apprt/gtk/class/application.zig`

- [ ] **Step 1: Import agents module and add registry to Private struct**

At the top of `application.zig`, add the import:

```zig
const agents = @import("../../../termplex/ipc/agents.zig");
```

In Private struct, add:

```zig
agent_registry: agents.AgentRegistry,
```

Initialize in the appropriate init function:

```zig
priv.agent_registry = agents.AgentRegistry.init(std.heap.c_allocator);
```

And deinit:

```zig
priv.agent_registry.deinit();
```

- [ ] **Step 2: Add `ipcAgentRegister` handler**

```zig
fn ipcAgentRegister(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
    const priv = self.private();
    const params_val = obj.get("params") orelse .null;
    if (params_val != .object) {
        return std.fmt.allocPrint(alloc,
            "{{\"ok\":false,\"error\":{{\"code\":\"invalid_params\",\"message\":\"params required\"}},\"id\":{d}}}",
            .{id},
        ) catch null;
    }
    const params = params_val.object;

    // Extract required fields
    const workspace = blk: {
        const v = params.get("workspace") orelse break :blk "";
        break :blk switch (v) { .string => |s| s, else => "" };
    };
    const tab: u32 = blk: {
        const v = params.get("tab") orelse break :blk 0;
        break :blk switch (v) { .integer => |n| @intCast(@max(0, n)), else => 0 };
    };
    const agent_type = blk: {
        const v = params.get("type") orelse break :blk agents.AgentType.custom;
        break :blk switch (v) {
            .string => |s| agents.AgentType.fromString(s) orelse .custom,
            else => .custom,
        };
    };
    const pid: i32 = blk: {
        const v = params.get("pid") orelse break :blk 0;
        break :blk switch (v) { .integer => |n| @intCast(n), else => 0 };
    };

    const agent_id = priv.agent_registry.register(workspace, tab, agent_type, pid) catch {
        return std.fmt.allocPrint(alloc,
            "{{\"ok\":false,\"error\":{{\"code\":\"oom\",\"message\":\"out of memory\"}},\"id\":{d}}}",
            .{id},
        ) catch null;
    };

    return std.fmt.allocPrint(alloc,
        "{{\"ok\":true,\"result\":{{\"agent_id\":\"{s}\"}},\"id\":{d}}}",
        .{ &agent_id, id },
    ) catch null;
}
```

- [ ] **Step 3: Add `ipcAgentList` handler**

```zig
fn ipcAgentList(self: *Self, alloc: std.mem.Allocator, id: i64) ?[]u8 {
    const priv = self.private();

    // Clean up dead agents first
    priv.agent_registry.cleanupDead();

    var arr_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer arr_buf.deinit(alloc);

    arr_buf.appendSlice(alloc, "[") catch return null;
    for (priv.agent_registry.agents.items, 0..) |agent, idx| {
        if (idx > 0) arr_buf.appendSlice(alloc, ",") catch return null;
        var num_buf: [16]u8 = undefined;

        arr_buf.appendSlice(alloc, "{\"agent_id\":\"") catch return null;
        arr_buf.appendSlice(alloc, &agent.agent_id) catch return null;
        arr_buf.appendSlice(alloc, "\",\"workspace\":\"") catch return null;
        for (agent.workspace) |c| {
            if (c == '"' or c == '\\') arr_buf.append(alloc, '\\') catch return null;
            arr_buf.append(alloc, c) catch return null;
        }
        arr_buf.appendSlice(alloc, "\",\"tab\":") catch return null;
        const tab_str = std.fmt.bufPrint(&num_buf, "{d}", .{agent.tab}) catch return null;
        arr_buf.appendSlice(alloc, tab_str) catch return null;
        arr_buf.appendSlice(alloc, ",\"type\":\"") catch return null;
        arr_buf.appendSlice(alloc, agent.agent_type.toString()) catch return null;
        arr_buf.appendSlice(alloc, "\",\"pid\":") catch return null;
        const pid_str = std.fmt.bufPrint(&num_buf, "{d}", .{agent.pid}) catch return null;
        arr_buf.appendSlice(alloc, pid_str) catch return null;
        arr_buf.appendSlice(alloc, ",\"alive\":true}") catch return null;
    }
    arr_buf.appendSlice(alloc, "]") catch return null;

    return std.fmt.allocPrint(alloc,
        "{{\"ok\":true,\"result\":{{\"agents\":{s}}},\"id\":{d}}}",
        .{ arr_buf.items, id },
    ) catch null;
}
```

- [ ] **Step 4: Add `ipcAgentUnregister` and `ipcAgentTerminate` handlers**

```zig
fn ipcAgentUnregister(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
    const priv = self.private();
    const params_val = obj.get("params") orelse .null;
    if (params_val != .object) {
        return std.fmt.allocPrint(alloc,
            "{{\"ok\":false,\"error\":{{\"code\":\"invalid_params\",\"message\":\"params required\"}},\"id\":{d}}}",
            .{id},
        ) catch null;
    }
    const pid: i32 = blk: {
        const v = params_val.object.get("pid") orelse break :blk 0;
        break :blk switch (v) { .integer => |n| @intCast(n), else => 0 };
    };

    _ = priv.agent_registry.unregister(pid);

    return std.fmt.allocPrint(alloc,
        "{{\"ok\":true,\"result\":{{}},\"id\":{d}}}",
        .{id},
    ) catch null;
}

fn ipcAgentTerminate(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
    const priv = self.private();
    const params_val = obj.get("params") orelse .null;
    if (params_val != .object) {
        return std.fmt.allocPrint(alloc,
            "{{\"ok\":false,\"error\":{{\"code\":\"invalid_params\",\"message\":\"params required\"}},\"id\":{d}}}",
            .{id},
        ) catch null;
    }
    const pid: i32 = blk: {
        const v = params_val.object.get("pid") orelse break :blk 0;
        break :blk switch (v) { .integer => |n| @intCast(n), else => 0 };
    };

    // Determine policy: per-call override > global config
    const policy: []const u8 = blk: {
        if (params_val.object.get("policy")) |pv| {
            switch (pv) {
                .string => |s| break :blk s,
                else => {},
            }
        }
        break :blk priv.termplex_cfg.orchestration.agent_terminate_policy;
    };

    // Send SIGTERM
    std.posix.kill(@intCast(pid), std.posix.SIG.TERM) catch {};

    // Unregister
    _ = priv.agent_registry.unregister(pid);

    // If policy is "terminate", close the tab
    // (Tab closing requires finding which workspace/tab the agent was in —
    //  the implementer should look up the agent's workspace/tab before unregistering
    //  and close the tab page if policy == "terminate")
    if (std.mem.eql(u8, policy, "terminate")) {
        log.info("IPC: agent terminate policy=terminate, tab close not yet implemented", .{});
        // TODO: Close the agent's tab using the workspace/tab info from the registry
    }

    return std.fmt.allocPrint(alloc,
        "{{\"ok\":true,\"result\":{{}},\"id\":{d}}}",
        .{id},
    ) catch null;
}
```

- [ ] **Step 5: Wire agent methods into `ipcDispatch`**

Add before the `known_stubs` array:

```zig
if (std.mem.eql(u8, method, "agent.register")) {
    return ipcAgentRegister(self, alloc, id, root.object);
}
if (std.mem.eql(u8, method, "agent.list")) {
    return ipcAgentList(self, alloc, id);
}
if (std.mem.eql(u8, method, "agent.unregister")) {
    return ipcAgentUnregister(self, alloc, id, root.object);
}
if (std.mem.eql(u8, method, "agent.terminate")) {
    return ipcAgentTerminate(self, alloc, id, root.object);
}
```

- [ ] **Step 6: Build and verify**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

- [ ] **Step 7: Commit**

```bash
git add src/apprt/gtk/class/application.zig
git commit -m "feat(ipc): add agent.register/list/unregister/terminate handlers"
```

---

### Task 12: Skill files

**Files:**
- Create: `tools/skill/termplex.md`
- Create: `tools/skill/AGENTS.md`

- [ ] **Step 1: Write the Claude Code skill file**

Create `tools/skill/termplex.md`:

```markdown
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
termplex-ctl surface send --workspace "backend" --tab 0 "npm test\n"   # Send text (\\n = Enter)
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
```

- [ ] **Step 2: Write the Codex-compatible AGENTS.md**

Create `tools/skill/AGENTS.md` with the same content but adapted for Codex conventions (the content is identical — Codex reads AGENTS.md from the working directory):

```markdown
# Termplex Orchestration

(Same content as termplex.md above)
```

- [ ] **Step 3: Add skill files to build system**

In `src/build/TermplexResources.zig`, add:

```zig
// Install orchestration skill files
try steps.append(b.allocator, &b.addInstallFile(
    b.path("tools/skill/termplex.md"),
    "share/termplex/skill/termplex.md",
).step);
try steps.append(b.allocator, &b.addInstallFile(
    b.path("tools/skill/AGENTS.md"),
    "share/termplex/skill/AGENTS.md",
).step);
```

- [ ] **Step 4: Build and verify**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
ls zig-out/share/termplex/skill/
```

Expected: `termplex.md` and `AGENTS.md` in the output directory.

- [ ] **Step 5: Commit**

```bash
git add tools/skill/termplex.md tools/skill/AGENTS.md src/build/TermplexResources.zig
git commit -m "feat: add orchestration skill files for Claude Code and Codex"
```

---

## Chunk 5: Terminal Interaction (surface.send / surface.read)

### Task 13: `surface.send` IPC handler

**Files:**
- Modify: `src/apprt/gtk/class/application.zig`

- [ ] **Step 1: Add workspace/tab resolution helper**

Since both `surface.send` and `surface.read` need to resolve workspace + tab to a surface, add a helper:

```zig
/// Resolve workspace name/index + tab index to the AdwTabPage.
fn resolveTabPage(self: *Self, params: std.json.ObjectMap) ?*adw.TabPage {
    const priv = self.private();

    // Resolve workspace
    const ws_idx: u32 = blk: {
        const ws_val = params.get("workspace") orelse break :blk priv.active_workspace_idx;
        switch (ws_val) {
            .integer => |n| {
                if (n >= 0 and n < @as(i64, @intCast(priv.workspace_names.items.len)))
                    break :blk @intCast(n);
                return null;
            },
            .string => |name| {
                for (priv.workspace_names.items, 0..) |ws_name, idx| {
                    if (std.mem.eql(u8, ws_name, name))
                        break :blk @intCast(idx);
                }
                return null;
            },
            else => break :blk priv.active_workspace_idx,
        }
    };

    // Get tab index
    const tab_idx: c_int = blk: {
        const v = params.get("tab") orelse break :blk 0;
        break :blk switch (v) { .integer => |n| @intCast(@max(0, n)), else => 0 };
    };

    const tab_view = priv.workspace_tab_views.items[ws_idx];
    if (tab_idx >= tab_view.getNPages()) return null;

    return tab_view.getNthPage(tab_idx);
}
```

- [ ] **Step 2: Add `ipcSurfaceSend` handler**

```zig
/// Handle surface.send — writes text to a terminal's PTY.
fn ipcSurfaceSend(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
    const params_val = obj.get("params") orelse .null;
    if (params_val != .object) {
        return std.fmt.allocPrint(alloc,
            "{{\"ok\":false,\"error\":{{\"code\":\"invalid_params\",\"message\":\"params required\"}},\"id\":{d}}}",
            .{id},
        ) catch null;
    }

    const page = self.resolveTabPage(params_val.object) orelse {
        return std.fmt.allocPrint(alloc,
            "{{\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"tab not found\"}},\"id\":{d}}}",
            .{id},
        ) catch null;
    };

    // Extract text to send
    const text = blk: {
        const v = params_val.object.get("text") orelse break :blk "";
        break :blk switch (v) { .string => |s| s, else => "" };
    };
    if (text.len == 0) {
        return std.fmt.allocPrint(alloc,
            "{{\"ok\":true,\"result\":{{}},\"id\":{d}}}",
            .{id},
        ) catch null;
    }

    // Get the Tab widget from the page and write to PTY
    // PTY write path: Tab -> getActiveSurface() -> GTK Surface -> .core() -> CoreSurface -> IO
    const child = page.getChild();
    if (gobject.ext.cast(Tab, child)) |tab| {
        if (tab.getActiveSurface()) |surface| {
            if (surface.core()) |core_surface| {
                // PSEUDO-CODE: The exact write method depends on the Ghostty IO interface.
                // Search for queueWrite/ptyWrite/messageWriter in CoreSurface/Termio code.
                core_surface.io.queueWrite(text) catch {};
            }
        }
    }

    return std.fmt.allocPrint(alloc,
        "{{\"ok\":true,\"result\":{{}},\"id\":{d}}}",
        .{id},
    ) catch null;
}
```

**Implementation note:** The exact method to write to the PTY depends on the Surface/Termio class chain inherited from Ghostty. The implementer should:
1. Find how keyboard input writes to the PTY (search for `queueWrite` or `ptyWrite` in the Surface/Termio code)
2. Use the same mechanism to inject text from the IPC handler
3. The text should be written as raw bytes to the PTY master fd

- [ ] **Step 3: Wire into `ipcDispatch`**

```zig
if (std.mem.eql(u8, method, "surface.send")) {
    return ipcSurfaceSend(self, alloc, id, root.object);
}
```

- [ ] **Step 4: Build and verify**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

- [ ] **Step 5: Commit**

```bash
git add src/apprt/gtk/class/application.zig
git commit -m "feat(ipc): add surface.send handler for PTY text injection"
```

---

### Task 14: `surface.read` IPC handler

**Files:**
- Modify: `src/apprt/gtk/class/application.zig`

- [ ] **Step 1: Add `ipcSurfaceRead` handler**

```zig
/// Handle surface.read — reads recent output from a terminal's screen buffer.
fn ipcSurfaceRead(self: *Self, alloc: std.mem.Allocator, id: i64, obj: std.json.ObjectMap) ?[]u8 {
    const params_val = obj.get("params") orelse .null;
    if (params_val != .object) {
        return std.fmt.allocPrint(alloc,
            "{{\"ok\":false,\"error\":{{\"code\":\"invalid_params\",\"message\":\"params required\"}},\"id\":{d}}}",
            .{id},
        ) catch null;
    }

    const page = self.resolveTabPage(params_val.object) orelse {
        return std.fmt.allocPrint(alloc,
            "{{\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"tab not found\"}},\"id\":{d}}}",
            .{id},
        ) catch null;
    };

    // Number of lines to read
    var lines: u32 = 50;
    if (params_val.object.get("lines")) |lv| {
        switch (lv) {
            .integer => |n| {
                lines = @intCast(@min(@max(1, n), 1000));
            },
            else => {},
        }
    }

    // Get the terminal screen buffer content
    // Screen read path: Tab -> getActiveSurface() -> GTK Surface -> .core() -> CoreSurface -> Screen
    const child = page.getChild();
    if (gobject.ext.cast(Tab, child)) |tab| {
        if (tab.getActiveSurface()) |surface| {
            const core_surface = surface.core() orelse {
                return std.fmt.allocPrint(alloc,
                    "{{\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"surface has no core\"}},\"id\":{d}}}",
                    .{id},
                ) catch null;
            };
            // PSEUDO-CODE: The exact screen reading approach depends on Ghostty internals.
            // The implementer must investigate the Terminal/Screen classes:
            //   - Look for dumpStringAlloc, plainText, selectionString in terminal/Screen.zig
            //   - Or iterate rows via screen.pages and extract cell text
            //   - Output must be plain text (ANSI stripped), non-UTF-8 bytes replaced with U+FFFD
            // Search for "dumpString", "plainText", "getRow", "getCell" in src/terminal/ code.
            const output = core_surface.dumpScreenText(alloc, lines) catch {
                return std.fmt.allocPrint(alloc,
                    "{{\"ok\":false,\"error\":{{\"code\":\"read_failed\",\"message\":\"failed to read screen buffer\"}},\"id\":{d}}}",
                    .{id},
                ) catch null;
            };
            defer alloc.free(output);

            // JSON-escape the output and build response
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            defer buf.deinit(alloc);

            buf.appendSlice(alloc, "\"") catch return null;
            for (output) |c| {
                switch (c) {
                    '"' => { buf.appendSlice(alloc, "\\\"") catch return null; },
                    '\\' => { buf.appendSlice(alloc, "\\\\") catch return null; },
                    '\n' => { buf.appendSlice(alloc, "\\n") catch return null; },
                    '\r' => { buf.appendSlice(alloc, "\\r") catch return null; },
                    '\t' => { buf.appendSlice(alloc, "\\t") catch return null; },
                    else => {
                        if (c < 0x20) {
                            // Control character — skip or replace
                            buf.appendSlice(alloc, "\\u00") catch return null;
                            const hex = "0123456789abcdef";
                            buf.append(alloc, hex[c >> 4]) catch return null;
                            buf.append(alloc, hex[c & 0xf]) catch return null;
                        } else {
                            buf.append(alloc, c) catch return null;
                        }
                    },
                }
            }
            buf.appendSlice(alloc, "\"") catch return null;

            return std.fmt.allocPrint(alloc,
                "{{\"ok\":true,\"result\":{{\"output\":{s}}},\"id\":{d}}}",
                .{ buf.items, id },
            ) catch null;
        }
    }

    return std.fmt.allocPrint(alloc,
        "{{\"ok\":false,\"error\":{{\"code\":\"not_found\",\"message\":\"surface not found\"}},\"id\":{d}}}",
        .{id},
    ) catch null;
}
```

**Implementation note:** The screen buffer reading is the most complex part. The implementer must:
1. Find the terminal's `Screen` or `Page` object in the Ghostty-inherited code
2. Look for methods like `dumpStringAlloc`, `getPlainText`, or row iteration
3. The implementation should strip ANSI escape sequences and return plain UTF-8 text
4. Replace non-UTF-8 bytes with U+FFFD as specified in the design spec
5. Read the last N lines (may need to read from scrollback + visible screen)

- [ ] **Step 2: Wire into `ipcDispatch`**

```zig
if (std.mem.eql(u8, method, "surface.read")) {
    return ipcSurfaceRead(self, alloc, id, root.object);
}
```

- [ ] **Step 3: Build and verify**

```bash
/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
```

- [ ] **Step 4: End-to-end integration test**

```bash
# Start Termplex
./zig-out/bin/termplex-app &

# Send a command to the default tab
./zig-out/bin/termplex-ctl surface send --workspace 0 --tab 0 "echo hello-from-ipc\n"

# Wait briefly for command to execute
sleep 1

# Read the output
./zig-out/bin/termplex-ctl surface read --workspace 0 --tab 0 --lines 10
# Expected: JSON with output containing "hello-from-ipc"

# Test agent registration round-trip
./zig-out/bin/termplex-ctl agent register --workspace "Workspace 1" --tab 0 --type claude --pid $$
./zig-out/bin/termplex-ctl agent list
./zig-out/bin/termplex-ctl agent unregister --pid $$
```

- [ ] **Step 5: Commit**

```bash
git add src/apprt/gtk/class/application.zig
git commit -m "feat(ipc): add surface.read handler for terminal screen buffer reading"
```

---

## Final Notes

### Build Command Reference

| Command | Purpose |
|---------|---------|
| `/opt/zig-x86_64-linux-0.15.2/zig build -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell` | Debug build |
| `/opt/zig-x86_64-linux-0.15.2/zig build test` | Run all tests |
| `/opt/zig-x86_64-linux-0.15.2/zig build test -Dtest-filter="<name>"` | Run filtered tests |
| `rm -rf .zig-cache zig-out` | Clean build (required after CSS changes) |

### Key Codebase Files

| File | Role |
|------|------|
| `src/apprt/gtk/class/application.zig` | IPC dispatch, workspace state, orchestration lifecycle |
| `src/apprt/gtk/class/window.zig` | Tab creation (`createTabInView`), workspace switching |
| `src/apprt/gtk/class/sidebar.zig` | Sidebar UI, workspace rows |
| `src/termplex/core/config.zig` | TOML config parser |
| `src/termplex/ipc/agents.zig` | Agent registry (new) |
| `tools/termplex-ctl` | Python CLI (new) |

### Implementation Guidance for PTY/Screen Access

The `surface.send` and `surface.read` handlers require accessing Ghostty-inherited terminal internals. Code marked as **PSEUDO-CODE** in Tasks 13 and 14 requires investigation. Key classes to investigate:

1. **Tab** (`src/apprt/gtk/class/tab.zig`) — has `getActiveSurface()` returning GTK Surface
2. **Surface** (`src/apprt/gtk/class/surface.zig`) — wraps a terminal emulator instance; has `.core()` → `?*CoreSurface`
3. **CoreSurface** — the Ghostty core surface with IO and renderer
4. **Termio** — handles PTY I/O; look for `queueWrite` or `messageWriter` for `surface.send`
5. **Screen** / **Terminal** — screen buffer; look for `dumpStringAlloc`, `selectionString`, or row iteration for `surface.read`

**Write path:** `Tab.getActiveSurface()` → `.core()` → CoreSurface IO → PTY write
**Read path:** `Tab.getActiveSurface()` → `.core()` → CoreSurface → Terminal/Screen → text extraction

Search for `queueWrite`, `pty`, `write`, `messageWriter` to find the write path.
Search for `dumpString`, `plainText`, `getRow`, `getCell`, `selectionString` for the read path.

### Note on agents.zig Tests

The `agents.zig` file must be imported by `application.zig` (Task 11) for its tests to be included in the compilation graph. Running `zig build test -Dtest-filter="agent registry"` before Task 11 is completed will find no tests. Run the tests after completing Task 11 (which adds the import).
