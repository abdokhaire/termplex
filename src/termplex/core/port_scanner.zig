// src/termplex/core/port_scanner.zig
// PortScanner: maps shell PIDs to TCP ports their descendant processes listen on.
//
// Algorithm:
//   1. Walk /proc/{pid}/task/{tid}/children recursively to collect descendants.
//   2. Read /proc/net/tcp and /proc/net/tcp6 for LISTEN sockets (state=0A).
//      Extract: local port (hex), inode number.
//   3. For each descendant PID, read /proc/{pid}/fd/ symlinks for "socket:[inode]".
//   4. Match socket inodes to listening entries → port → shell PID.
//
// Key types:
//   PortResult — a shell PID and the sorted list of ports its descendants listen on.
//   scan(allocator, shell_pids) -> []PortResult

const std = @import("std");
const posix = std.posix;

const log = std.log.scoped(.port_scanner);

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// A shell PID mapped to the TCP ports its process subtree is listening on.
pub const PortResult = struct {
    /// The shell PID that was passed to `scan`.
    pid: posix.pid_t,
    /// Sorted slice of unique port numbers. Owned by this struct.
    ports: []u16,

    /// Free the ports slice.
    pub fn deinit(self: *PortResult, allocator: std.mem.Allocator) void {
        allocator.free(self.ports);
        self.ports = &.{};
    }
};

/// Scan the process subtrees rooted at each shell PID and return the TCP ports
/// their descendant processes are listening on.
///
/// Missing /proc entries are silently skipped (process may have exited).
/// The returned slice, and every `PortResult.ports` slice, are owned by the
/// caller; call `deinit` on each result then free the outer slice, or use the
/// helper `deinitResults`.
pub fn scan(
    allocator: std.mem.Allocator,
    shell_pids: []const posix.pid_t,
) ![]PortResult {
    // Step 1 — build set of all PIDs to examine, keyed by shell PID.
    //   pid_to_shell[descendant_pid] = shell_pid
    var pid_to_shell = std.AutoHashMap(posix.pid_t, posix.pid_t).init(allocator);
    defer pid_to_shell.deinit();

    for (shell_pids) |shell_pid| {
        try collectDescendants(allocator, shell_pid, shell_pid, &pid_to_shell);
    }

    // Step 2 — parse /proc/net/tcp and /proc/net/tcp6 for LISTEN entries.
    //   inode_to_port[inode] = port
    var inode_to_port = std.AutoHashMap(u64, u16).init(allocator);
    defer inode_to_port.deinit();

    parseProcNetTcp(allocator, "/proc/net/tcp", &inode_to_port) catch |err| {
        log.debug("failed to parse /proc/net/tcp: {}", .{err});
    };
    parseProcNetTcp(allocator, "/proc/net/tcp6", &inode_to_port) catch |err| {
        log.debug("failed to parse /proc/net/tcp6: {}", .{err});
    };

    // Step 3+4 — for each known PID, match fd socket inodes to listening ports.
    //   shell_to_ports[shell_pid] = list of ports (unmanaged ArrayList, freed with allocator)
    var shell_to_ports = std.AutoHashMap(posix.pid_t, std.ArrayList(u16)).init(allocator);
    defer {
        var it = shell_to_ports.valueIterator();
        while (it.next()) |v| v.deinit(allocator);
        shell_to_ports.deinit();
    }

    var pid_iter = pid_to_shell.iterator();
    while (pid_iter.next()) |entry| {
        const pid = entry.key_ptr.*;
        const shell_pid = entry.value_ptr.*;

        // Read /proc/{pid}/fd/ directory for socket inodes.
        const ports_for_pid = findPidPorts(allocator, pid, &inode_to_port) catch |err| {
            log.debug("findPidPorts({}) failed: {}", .{ pid, err });
            continue;
        };
        defer allocator.free(ports_for_pid);

        for (ports_for_pid) |port| {
            const gop = try shell_to_ports.getOrPut(shell_pid);
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
            }
            // Deduplicate: only append if not already present.
            var already = false;
            for (gop.value_ptr.items) |p| {
                if (p == port) {
                    already = true;
                    break;
                }
            }
            if (!already) try gop.value_ptr.append(allocator, port);
        }
    }

    // Build output slice — one PortResult per requested shell PID.
    const results = try allocator.alloc(PortResult, shell_pids.len);
    errdefer allocator.free(results);

    for (shell_pids, 0..) |shell_pid, i| {
        if (shell_to_ports.getPtr(shell_pid)) |list| {
            // Sort for deterministic output.
            std.mem.sort(u16, list.items, {}, std.sort.asc(u16));
            const owned = try list.toOwnedSlice(allocator);
            results[i] = .{ .pid = shell_pid, .ports = owned };
        } else {
            results[i] = .{ .pid = shell_pid, .ports = try allocator.alloc(u16, 0) };
        }
    }

    return results;
}

/// Free all memory returned by `scan`.
pub fn deinitResults(allocator: std.mem.Allocator, results: []PortResult) void {
    for (results) |*r| r.deinit(allocator);
    allocator.free(results);
}

// ---------------------------------------------------------------------------
// Internal: process tree walking
// ---------------------------------------------------------------------------

/// Recursively collect all descendant PIDs of `pid` (including `pid` itself)
/// into `pid_to_shell`, mapping each to `shell_pid`.
///
/// Uses /proc/{pid}/task/{tid}/children. Missing entries are silently skipped.
fn collectDescendants(
    allocator: std.mem.Allocator,
    pid: posix.pid_t,
    shell_pid: posix.pid_t,
    pid_to_shell: *std.AutoHashMap(posix.pid_t, posix.pid_t),
) !void {
    // Avoid revisiting already-seen PIDs (cycle guard & efficiency).
    if (pid_to_shell.contains(pid)) return;
    try pid_to_shell.put(pid, shell_pid);

    // List tasks (threads) for this PID via /proc/{pid}/task/.
    var task_path_buf: [64]u8 = undefined;
    const task_path = std.fmt.bufPrint(&task_path_buf, "/proc/{d}/task", .{pid}) catch return;

    var task_dir = std.fs.openDirAbsolute(task_path, .{ .iterate = true }) catch return;
    defer task_dir.close();

    var task_iter = task_dir.iterate();
    while (task_iter.next() catch null) |tid_entry| {
        if (tid_entry.kind != .directory) continue;

        // Read /proc/{pid}/task/{tid}/children
        var children_path_buf: [96]u8 = undefined;
        const children_path = std.fmt.bufPrint(
            &children_path_buf,
            "/proc/{d}/task/{s}/children",
            .{ pid, tid_entry.name },
        ) catch continue;

        const children_content = readFileAlloc(allocator, children_path) catch continue;
        defer allocator.free(children_content);

        // Children are space-separated PIDs.
        var tok = std.mem.tokenizeScalar(u8, children_content, ' ');
        while (tok.next()) |token| {
            const trimmed = std.mem.trim(u8, token, " \n\r\t");
            if (trimmed.len == 0) continue;
            const child_pid = std.fmt.parseInt(posix.pid_t, trimmed, 10) catch continue;
            // Recurse; ignore errors (process may have exited by now).
            collectDescendants(allocator, child_pid, shell_pid, pid_to_shell) catch {};
        }
    }
}

// ---------------------------------------------------------------------------
// Internal: /proc/net/tcp parsing
// ---------------------------------------------------------------------------

/// Parse a /proc/net/tcp or /proc/net/tcp6 file and populate `inode_to_port`
/// with entries where state == 0A (LISTEN).
///
/// File format (abbreviated):
///   sl  local_address rem_address   st tx_queue rx_queue ...  inode
///    0: 00000000:1F90 00000000:0000 0A ...                    12345 ...
pub fn parseProcNetTcp(
    allocator: std.mem.Allocator,
    path: []const u8,
    inode_to_port: *std.AutoHashMap(u64, u16),
) !void {
    const content = try readFileAlloc(allocator, path);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    // Skip header line.
    _ = lines.next();

    while (lines.next()) |line| {
        parseProcNetTcpLine(line, inode_to_port) catch |err| {
            log.debug("skipping tcp line: {}", .{err});
        };
    }
}

/// Parse a single data line from /proc/net/tcp[6].
/// Returns error.SkipLine for empty or non-LISTEN lines.
pub fn parseProcNetTcpLine(
    line: []const u8,
    inode_to_port: *std.AutoHashMap(u64, u16),
) !void {
    // Tokenise by whitespace. Fields (0-indexed):
    //   0: sl           (e.g. "0:")
    //   1: local_addr   (hex IP:PORT)
    //   2: rem_addr     (hex IP:PORT)
    //   3: st           (hex state, "0A" = LISTEN)
    //   4: tx_queue:rx_queue
    //   5: tr:tm->when
    //   6: retrnsmt
    //   7: uid
    //   8: timeout
    //   9: inode

    var tokens: [10][]const u8 = undefined;
    var count: usize = 0;
    var tok = std.mem.tokenizeAny(u8, line, " \t");
    while (tok.next()) |t| {
        if (count >= tokens.len) break;
        tokens[count] = t;
        count += 1;
    }
    if (count < 10) return error.SkipLine;

    // Field 3: state must be "0A" (LISTEN).
    if (!std.mem.eql(u8, tokens[3], "0A")) return error.SkipLine;

    // Field 1: local_address — format "HHHHHHHH:PPPP" or IPv6 variant.
    // The port is the last 4 hex chars after the colon.
    const local_addr = tokens[1];
    const colon = std.mem.lastIndexOfScalar(u8, local_addr, ':') orelse return error.SkipLine;
    const port_hex = local_addr[colon + 1 ..];
    if (port_hex.len < 4) return error.SkipLine;
    const port = std.fmt.parseInt(u16, port_hex, 16) catch return error.SkipLine;

    // Field 9: inode.
    const inode = std.fmt.parseInt(u64, tokens[9], 10) catch return error.SkipLine;

    try inode_to_port.put(inode, port);
}

// ---------------------------------------------------------------------------
// Internal: fd directory scanning
// ---------------------------------------------------------------------------

/// Return the set of listening ports held by `pid` by matching its open file
/// descriptors (socket:[inode] symlinks) against `inode_to_port`.
///
/// Caller owns the returned slice.
fn findPidPorts(
    allocator: std.mem.Allocator,
    pid: posix.pid_t,
    inode_to_port: *const std.AutoHashMap(u64, u16),
) ![]u16 {
    var fd_path_buf: [64]u8 = undefined;
    const fd_path = std.fmt.bufPrint(&fd_path_buf, "/proc/{d}/fd", .{pid}) catch return &.{};

    var fd_dir = std.fs.openDirAbsolute(fd_path, .{ .iterate = true }) catch return &.{};
    defer fd_dir.close();

    var ports: std.ArrayList(u16) = .empty;
    errdefer ports.deinit(allocator);

    var link_buf: [256]u8 = undefined;
    var iter = fd_dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .sym_link) continue;

        const target = posix.readlinkat(
            fd_dir.fd,
            entry.name,
            &link_buf,
        ) catch continue;

        // Symlink target looks like "socket:[12345]".
        const inode = parseSocketInode(target) orelse continue;

        if (inode_to_port.get(inode)) |port| {
            try ports.append(allocator, port);
        }
    }

    return ports.toOwnedSlice(allocator);
}

/// Parse "socket:[<inode>]" and return the inode, or null if not a socket.
pub fn parseSocketInode(target: []const u8) ?u64 {
    const prefix = "socket:[";
    if (!std.mem.startsWith(u8, target, prefix)) return null;
    const rest = target[prefix.len..];
    const close = std.mem.indexOfScalar(u8, rest, ']') orelse return null;
    return std.fmt.parseInt(u64, rest[0..close], 10) catch null;
}

// ---------------------------------------------------------------------------
// Internal: file I/O helper
// ---------------------------------------------------------------------------

/// Read an entire file into a freshly allocated slice.  Caller frees.
fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    // /proc files don't report their size, so read up to 4 MiB.
    return file.readToEndAlloc(allocator, 4 * 1024 * 1024);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseSocketInode returns null for non-socket symlinks" {
    try std.testing.expect(parseSocketInode("/dev/null") == null);
    try std.testing.expect(parseSocketInode("pipe:[99]") == null);
    try std.testing.expect(parseSocketInode("anon_inode:[eventfd]") == null);
}

test "parseSocketInode parses valid socket symlink" {
    try std.testing.expectEqual(@as(?u64, 12345), parseSocketInode("socket:[12345]"));
    try std.testing.expectEqual(@as(?u64, 0), parseSocketInode("socket:[0]"));
    try std.testing.expectEqual(@as(?u64, 999999999), parseSocketInode("socket:[999999999]"));
}

test "parseSocketInode returns null for malformed entries" {
    try std.testing.expect(parseSocketInode("socket:[]") == null);
    try std.testing.expect(parseSocketInode("socket:[abc]") == null);
    try std.testing.expect(parseSocketInode("socket:[") == null);
}

test "parseProcNetTcpLine ignores non-LISTEN entries" {
    const allocator = std.testing.allocator;
    var map = std.AutoHashMap(u64, u16).init(allocator);
    defer map.deinit();

    // State 01 = ESTABLISHED — should be ignored.
    const line = "   0: 0F02000A:0050 0202000A:C2F4 01 00000000:00000000 00:00000000 00000000     0        0 54321 1 0000000000000000 20 4 0 10 -1";
    try std.testing.expectError(error.SkipLine, parseProcNetTcpLine(line, &map));
    try std.testing.expectEqual(@as(usize, 0), map.count());
}

test "parseProcNetTcpLine parses LISTEN entry (state=0A)" {
    const allocator = std.testing.allocator;
    var map = std.AutoHashMap(u64, u16).init(allocator);
    defer map.deinit();

    // Port 0x1F90 = 8080, inode = 12345.
    const line = "   0: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 12345 1 0000000000000000 100 0 0 10 0";
    try parseProcNetTcpLine(line, &map);

    try std.testing.expectEqual(@as(usize, 1), map.count());
    try std.testing.expectEqual(@as(?u16, 8080), map.get(12345));
}

test "parseProcNetTcpLine parses port 80 (0x0050)" {
    const allocator = std.testing.allocator;
    var map = std.AutoHashMap(u64, u16).init(allocator);
    defer map.deinit();

    const line = "   1: 00000000:0050 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 99999 1 0000000000000000 100 0 0 10 0";
    try parseProcNetTcpLine(line, &map);

    try std.testing.expectEqual(@as(?u16, 80), map.get(99999));
}

test "parseProcNetTcpLine skips short lines" {
    const allocator = std.testing.allocator;
    var map = std.AutoHashMap(u64, u16).init(allocator);
    defer map.deinit();

    try std.testing.expectError(error.SkipLine, parseProcNetTcpLine("", &map));
    try std.testing.expectError(error.SkipLine, parseProcNetTcpLine("   0: 00000000:1F90", &map));
}

test "parseProcNetTcp from string content" {
    const allocator = std.testing.allocator;
    var map = std.AutoHashMap(u64, u16).init(allocator);
    defer map.deinit();

    // Build a fake /proc/net/tcp string and write to a temp file, then parse.
    const content =
        \\  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
        \\   0: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 12345 1 0000000000000000 100 0 0 10 0
        \\   1: 0202000A:C2F4 0F02000A:0050 01 00000000:00000000 00:00000000 00000000  1000        0 54321 1 0000000000000000 20 4 0 10 -1
        \\   2: 00000000:0050 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 99999 1 0000000000000000 100 0 0 10 0
        \\
    ;

    // Write to temp file.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("tcp", .{});
    try file.writeAll(content);
    file.close();

    // Build absolute path.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);
    var full_path_buf: [std.fs.max_path_bytes + 8]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/tcp", .{dir_path});

    try parseProcNetTcp(allocator, full_path, &map);

    // 12345 → 8080, 99999 → 80; 54321 should be absent (ESTABLISHED).
    try std.testing.expectEqual(@as(usize, 2), map.count());
    try std.testing.expectEqual(@as(?u16, 8080), map.get(12345));
    try std.testing.expectEqual(@as(?u16, 80), map.get(99999));
    try std.testing.expect(map.get(54321) == null);
}

test "scan with empty shell_pids returns empty slice" {
    const allocator = std.testing.allocator;
    const results = try scan(allocator, &.{});
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "scan with non-existent PID returns empty ports" {
    const allocator = std.testing.allocator;
    // PID 2147483647 is very unlikely to exist.
    const fake_pid: posix.pid_t = 2147483647;
    const results = try scan(allocator, &.{fake_pid});
    defer {
        for (results) |*r| {
            var rr = r;
            rr.deinit(allocator);
        }
        allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqual(fake_pid, results[0].pid);
    try std.testing.expectEqual(@as(usize, 0), results[0].ports.len);
}

test "PortResult deinit frees ports slice" {
    const allocator = std.testing.allocator;
    const ports = try allocator.dupe(u16, &[_]u16{ 80, 8080, 3000 });
    var result = PortResult{ .pid = 1234, .ports = ports };
    result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), result.ports.len);
}
