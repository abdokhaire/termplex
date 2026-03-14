// src/termplex/ipc/socket_server.zig
// Unix domain socket server for the termplex IPC protocol.
//
// Listens on a Unix socket for newline-delimited JSON requests from the CLI
// tool.  Designed to be polled periodically from the GTK main loop (e.g. via
// g_timeout_add) so that it never blocks the UI thread.
//
// Socket path resolution order:
//   1. $TERMPLEX_SOCKET  (explicit override)
//   2. $XDG_RUNTIME_DIR/termplex.sock
//   3. /tmp/termplex-{uid}.sock  (fallback)
//
// Protocol: newline-delimited JSON.  One request per connection (like HTTP/1.0).
//   Client → sends a JSON line (terminated with '\n')
//   Server → calls handler, writes response JSON line, closes connection.

const std = @import("std");
const posix = std.posix;

const log = std.log.scoped(.socket_server);

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Maximum number of simultaneously tracked client connections.
const max_clients = 64;

/// Per-connection read buffer size.  Requests must fit within this limit.
const read_buf_size = 64 * 1024; // 64 KiB

// ---------------------------------------------------------------------------
// Handler callback type
// ---------------------------------------------------------------------------

/// Called with the raw JSON request (without the trailing newline).
/// Returns an allocated JSON response string, or null for no response.
/// The server frees the returned slice after writing it.
pub const Handler = *const fn (allocator: std.mem.Allocator, request: []const u8) ?[]const u8;

// ---------------------------------------------------------------------------
// Client connection
// ---------------------------------------------------------------------------

const Client = struct {
    fd: posix.socket_t,
    /// Heap-allocated read buffer; owned by the Client.
    buf: []u8,
    /// Number of valid bytes in buf.
    len: usize,
};

// ---------------------------------------------------------------------------
// SocketServer
// ---------------------------------------------------------------------------

pub const SocketServer = struct {
    allocator: std.mem.Allocator,
    /// The listening socket fd.
    listen_fd: posix.socket_t,
    /// Owned copy of the socket filesystem path (for removal on deinit).
    socket_path: []u8,
    /// Active client connections.
    clients: [max_clients]?Client,

    // -----------------------------------------------------------------------
    // init
    // -----------------------------------------------------------------------

    /// Create and bind the Unix socket, then set it to listening.
    ///
    /// The socket fd is set to non-blocking so that accept() and read()
    /// never stall the GTK main loop.
    pub fn init(allocator: std.mem.Allocator) !SocketServer {
        const path = try getSocketPath(allocator);
        errdefer allocator.free(path);

        return initWithPath(allocator, path);
    }

    /// Like init but with an explicit socket path.  Useful for testing.
    /// Takes ownership of path (caller must not free it).
    pub fn initWithPath(allocator: std.mem.Allocator, path: []u8) !SocketServer {
        errdefer allocator.free(path);

        // Remove any leftover socket file from a previous run.
        posix.unlink(path) catch |err| switch (err) {
            error.FileNotFound => {}, // expected — no stale file
            else => return err,
        };

        // Create non-blocking, close-on-exec socket.
        const fd = try posix.socket(
            posix.AF.UNIX,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
            0,
        );
        errdefer posix.close(fd);

        // Build sockaddr_un.
        var addr: posix.sockaddr.un = .{
            .family = posix.AF.UNIX,
            .path = undefined,
        };
        @memset(&addr.path, 0);

        if (path.len >= addr.path.len) {
            return error.SocketPathTooLong;
        }
        @memcpy(addr.path[0..path.len], path);

        try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
        try posix.listen(fd, 16);

        log.debug("listening on {s}", .{path});

        return SocketServer{
            .allocator = allocator,
            .listen_fd = fd,
            .socket_path = path,
            .clients = [_]?Client{null} ** max_clients,
        };
    }

    // -----------------------------------------------------------------------
    // deinit
    // -----------------------------------------------------------------------

    /// Close the listening socket, close all client connections, and remove
    /// the socket file.
    pub fn deinit(self: *SocketServer) void {
        for (&self.clients) |*slot| {
            if (slot.*) |*c| {
                posix.close(c.fd);
                self.allocator.free(c.buf);
                slot.* = null;
            }
        }

        posix.close(self.listen_fd);

        posix.unlink(self.socket_path) catch {};
        self.allocator.free(self.socket_path);
    }

    // -----------------------------------------------------------------------
    // poll
    // -----------------------------------------------------------------------

    /// Non-blocking poll: accept new connections and service readable clients.
    ///
    /// Must return quickly; safe to call from a GTK idle or timeout handler.
    /// The handler is called synchronously for each complete request received.
    pub fn poll(self: *SocketServer, handler: Handler) void {
        self.acceptConnections();

        for (&self.clients) |*slot| {
            if (slot.* == null) continue;
            const done = self.serviceClient(slot, handler);
            if (done) {
                if (slot.*) |*c| {
                    posix.close(c.fd);
                    self.allocator.free(c.buf);
                    slot.* = null;
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // getSocketPath
    // -----------------------------------------------------------------------

    /// Resolve the socket path from environment variables.
    ///
    /// Resolution order:
    ///   1. $TERMPLEX_SOCKET  (explicit override)
    ///   2. $XDG_RUNTIME_DIR/termplex.sock
    ///   3. /tmp/termplex-{uid}.sock  (fallback)
    ///
    /// Caller owns the returned slice.
    pub fn getSocketPath(allocator: std.mem.Allocator) ![]u8 {
        // 1. Explicit override.
        if (std.process.getEnvVarOwned(allocator, "TERMPLEX_SOCKET")) |p| {
            if (p.len > 0) return p;
            allocator.free(p);
        } else |_| {}

        // 2. $XDG_RUNTIME_DIR/termplex.sock
        if (std.process.getEnvVarOwned(allocator, "XDG_RUNTIME_DIR")) |dir| {
            defer allocator.free(dir);
            if (dir.len > 0) {
                return std.fs.path.join(allocator, &[_][]const u8{ dir, "termplex.sock" });
            }
        } else |_| {}

        // 3. /tmp/termplex-{uid}.sock
        const uid = posix.getuid();
        return std.fmt.allocPrint(allocator, "/tmp/termplex-{d}.sock", .{uid});
    }

    // -----------------------------------------------------------------------
    // Private helpers
    // -----------------------------------------------------------------------

    fn acceptConnections(self: *SocketServer) void {
        while (true) {
            const client_fd = posix.accept(
                self.listen_fd,
                null,
                null,
                posix.SOCK.CLOEXEC,
            ) catch |err| switch (err) {
                error.WouldBlock => return, // no more pending connections
                error.ConnectionAborted => continue,
                else => {
                    log.warn("accept error: {}", .{err});
                    return;
                },
            };

            // The listening socket is NONBLOCK; accepted fd inherits that on
            // Linux when we pass SOCK.NONBLOCK to accept4.  But we used CLOEXEC
            // only (to keep it simple), so set NONBLOCK explicitly.
            setNonBlocking(client_fd) catch |err| {
                log.warn("setNonBlocking failed for client: {}", .{err});
                posix.close(client_fd);
                continue;
            };

            const slot = self.findFreeSlot() orelse {
                log.warn("max_clients ({d}) reached, dropping connection", .{max_clients});
                posix.close(client_fd);
                continue;
            };

            const buf = self.allocator.alloc(u8, read_buf_size) catch |err| {
                log.warn("alloc failed for client buffer: {}", .{err});
                posix.close(client_fd);
                continue;
            };

            slot.* = Client{
                .fd = client_fd,
                .buf = buf,
                .len = 0,
            };
        }
    }

    /// Service one client slot.  Returns true if the slot should be freed.
    fn serviceClient(self: *SocketServer, slot: *?Client, handler: Handler) bool {
        const c = &(slot.* orelse return true);

        // Try to read more data.
        const space = c.buf.len - c.len;
        if (space == 0) {
            log.warn("client buffer full without newline, closing", .{});
            return true;
        }

        const n = posix.read(c.fd, c.buf[c.len..]) catch |err| switch (err) {
            error.WouldBlock => return false, // nothing available yet
            else => {
                log.debug("client read error (disconnect?): {}", .{err});
                return true;
            },
        };

        if (n == 0) {
            // EOF — client disconnected before sending a complete line.
            return true;
        }

        c.len += n;

        // Look for a complete newline-terminated message.
        if (std.mem.indexOfScalar(u8, c.buf[0..c.len], '\n')) |nl| {
            const request = c.buf[0..nl];

            const response_opt = handler(self.allocator, request);
            if (response_opt) |response| {
                defer self.allocator.free(response);
                writeAll(c.fd, response) catch {};
                writeAll(c.fd, "\n") catch {};
            }

            // One request per connection; close after serving.
            return true;
        }

        return false;
    }

    fn findFreeSlot(self: *SocketServer) ?*?Client {
        for (&self.clients) |*slot| {
            if (slot.* == null) return slot;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Set a file descriptor to non-blocking mode.
fn setNonBlocking(fd: posix.fd_t) !void {
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    const new_flags = flags | @as(usize, 1 << @bitOffsetOf(posix.O, "NONBLOCK"));
    _ = try posix.fcntl(fd, posix.F.SETFL, new_flags);
}

/// Write all bytes to fd, ignoring WouldBlock (best-effort on non-blocking fd).
fn writeAll(fd: posix.fd_t, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const n = posix.write(fd, data[written..]) catch |err| switch (err) {
            error.WouldBlock => return, // best-effort; caller already non-blocking
            else => return err,
        };
        written += n;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// Path-resolution tests use a testable helper so we don't need to mutate the
// live environment (which would require libc's setenv).  The real getSocketPath
// is tested indirectly via init/deinit.

/// Resolve a socket path given explicit optional values for the three
/// environment variables.  Mirrors the logic of getSocketPath.
fn resolveSocketPath(
    allocator: std.mem.Allocator,
    termplex_socket: ?[]const u8,
    xdg_runtime_dir: ?[]const u8,
    uid: u32,
) ![]u8 {
    if (termplex_socket) |p| {
        if (p.len > 0) return allocator.dupe(u8, p);
    }
    if (xdg_runtime_dir) |dir| {
        if (dir.len > 0) {
            return std.fs.path.join(allocator, &[_][]const u8{ dir, "termplex.sock" });
        }
    }
    return std.fmt.allocPrint(allocator, "/tmp/termplex-{d}.sock", .{uid});
}

test "resolveSocketPath uses TERMPLEX_SOCKET override" {
    const allocator = std.testing.allocator;
    const path = try resolveSocketPath(allocator, "/run/custom/termplex.sock", "/run/user/1000", 1000);
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/run/custom/termplex.sock", path);
}

test "resolveSocketPath uses XDG_RUNTIME_DIR when no override" {
    const allocator = std.testing.allocator;
    const path = try resolveSocketPath(allocator, null, "/run/user/1000", 1000);
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/run/user/1000/termplex.sock", path);
}

test "resolveSocketPath falls back to /tmp/termplex-{uid}.sock" {
    const allocator = std.testing.allocator;
    const path = try resolveSocketPath(allocator, null, null, 42);
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/termplex-42.sock", path);
}

test "resolveSocketPath ignores empty TERMPLEX_SOCKET" {
    const allocator = std.testing.allocator;
    const path = try resolveSocketPath(allocator, "", "/run/user/1000", 1000);
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/run/user/1000/termplex.sock", path);
}

test "resolveSocketPath ignores empty XDG_RUNTIME_DIR" {
    const allocator = std.testing.allocator;
    const path = try resolveSocketPath(allocator, null, "", 7);
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/termplex-7.sock", path);
}

test "getSocketPath returns a non-empty path" {
    const allocator = std.testing.allocator;
    const path = try SocketServer.getSocketPath(allocator);
    defer allocator.free(path);
    try std.testing.expect(path.len > 0);
    try std.testing.expect(std.mem.endsWith(u8, path, ".sock"));
}

test "init creates socket file and deinit removes it" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    // Build an owned path for the server.  initWithPath takes ownership —
    // do NOT free it ourselves.
    const sock_path = try std.fs.path.join(allocator, &[_][]const u8{ tmp_path, "test.sock" });

    // Keep a copy for post-deinit verification (the server will free the
    // original after deinit).
    const sock_path_copy = try allocator.dupe(u8, sock_path);
    defer allocator.free(sock_path_copy);

    var server = try SocketServer.initWithPath(allocator, sock_path);

    // Socket file must exist while server is alive.
    try std.fs.accessAbsolute(sock_path_copy, .{});

    server.deinit();

    // Socket file must be gone after deinit.
    const result = std.fs.accessAbsolute(sock_path_copy, .{});
    try std.testing.expectError(error.FileNotFound, result);
}

test "basic connect-send-receive round-trip" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const sock_path = try std.fs.path.join(allocator, &[_][]const u8{ tmp_path, "roundtrip.sock" });
    var server = try SocketServer.initWithPath(allocator, sock_path);
    defer server.deinit();

    // Thread context.
    const Ctx = struct {
        path: []const u8,
        received: []u8 = &[_]u8{},
        alloc: std.mem.Allocator,
        err: ?anyerror = null,

        fn run(ctx: *@This()) void {
            ctx.runInner() catch |e| {
                ctx.err = e;
            };
        }

        fn runInner(ctx: *@This()) !void {
            const cfd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
            defer posix.close(cfd);

            var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
            @memset(&addr.path, 0);
            @memcpy(addr.path[0..ctx.path.len], ctx.path);
            try posix.connect(cfd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

            const req = "{\"method\":\"ping\",\"id\":1}\n";
            _ = try posix.write(cfd, req);

            var rbuf: [1024]u8 = undefined;
            var total: usize = 0;
            while (total < rbuf.len) {
                const n = posix.read(cfd, rbuf[total..]) catch break;
                if (n == 0) break;
                total += n;
                if (std.mem.indexOfScalar(u8, rbuf[0..total], '\n') != null) break;
            }

            ctx.received = try ctx.alloc.dupe(u8, rbuf[0..total]);
        }
    };

    var ctx = Ctx{ .path = sock_path, .alloc = allocator };

    // Echo handler: returns a copy of the request.
    const handler: Handler = struct {
        fn h(alloc: std.mem.Allocator, req: []const u8) ?[]const u8 {
            return alloc.dupe(u8, req) catch null;
        }
    }.h;

    const t = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});

    // Poll for up to 2 seconds.
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        server.poll(handler);
        if (ctx.received.len > 0) break;
        std.Thread.sleep(10_000_000); // 10 ms
    }

    t.join();

    if (ctx.err) |e| return e;
    defer allocator.free(ctx.received);

    const expected = "{\"method\":\"ping\",\"id\":1}\n";
    try std.testing.expectEqualStrings(expected, ctx.received);
}

test "handler returning null sends no response" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const sock_path = try std.fs.path.join(allocator, &[_][]const u8{ tmp_path, "null-resp.sock" });
    var server = try SocketServer.initWithPath(allocator, sock_path);
    defer server.deinit();

    const Ctx = struct {
        path: []const u8,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        err: ?anyerror = null,

        fn run(ctx: *@This()) void {
            ctx.runInner() catch |e| {
                ctx.err = e;
            };
        }

        fn runInner(ctx: *@This()) !void {
            const cfd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
            defer posix.close(cfd);

            var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
            @memset(&addr.path, 0);
            @memcpy(addr.path[0..ctx.path.len], ctx.path);
            try posix.connect(cfd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

            _ = try posix.write(cfd, "hello\n");

            // Server closes connection without sending any data.
            var rbuf: [64]u8 = undefined;
            _ = posix.read(cfd, &rbuf) catch {};

            ctx.done.store(true, .release);
        }
    };

    var ctx = Ctx{ .path = sock_path };

    const null_handler: Handler = struct {
        fn h(_: std.mem.Allocator, _: []const u8) ?[]const u8 {
            return null;
        }
    }.h;

    const t = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        server.poll(null_handler);
        if (ctx.done.load(.acquire)) break;
        std.Thread.sleep(10_000_000);
    }

    t.join();

    if (ctx.err) |e| return e;
    try std.testing.expect(ctx.done.load(.acquire));
}

test "multiple sequential requests on separate connections" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    const sock_path = try std.fs.path.join(allocator, &[_][]const u8{ tmp_path, "multi.sock" });
    var server = try SocketServer.initWithPath(allocator, sock_path);
    defer server.deinit();

    const echo_handler: Handler = struct {
        fn h(alloc: std.mem.Allocator, req: []const u8) ?[]const u8 {
            return alloc.dupe(u8, req) catch null;
        }
    }.h;

    // Send 3 separate connections sequentially.
    for (0..3) |idx| {
        const Req = struct {
            path: []const u8,
            idx: usize,
            received: []u8 = &[_]u8{},
            alloc: std.mem.Allocator,
            err: ?anyerror = null,

            fn run(ctx: *@This()) void {
                ctx.runInner() catch |e| {
                    ctx.err = e;
                };
            }

            fn runInner(ctx: *@This()) !void {
                const cfd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
                defer posix.close(cfd);

                var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
                @memset(&addr.path, 0);
                @memcpy(addr.path[0..ctx.path.len], ctx.path);
                try posix.connect(cfd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

                const msg = try std.fmt.allocPrint(ctx.alloc, "{{\"id\":{d}}}\n", .{ctx.idx});
                defer ctx.alloc.free(msg);
                _ = try posix.write(cfd, msg);

                var rbuf: [256]u8 = undefined;
                var total: usize = 0;
                while (total < rbuf.len) {
                    const n = posix.read(cfd, rbuf[total..]) catch break;
                    if (n == 0) break;
                    total += n;
                    if (std.mem.indexOfScalar(u8, rbuf[0..total], '\n') != null) break;
                }
                ctx.received = try ctx.alloc.dupe(u8, rbuf[0..total]);
            }
        };

        var req_ctx = Req{ .path = sock_path, .idx = idx, .alloc = allocator };
        const t = try std.Thread.spawn(.{}, Req.run, .{&req_ctx});

        var i: usize = 0;
        while (i < 200) : (i += 1) {
            server.poll(echo_handler);
            if (req_ctx.received.len > 0) break;
            std.Thread.sleep(10_000_000);
        }
        t.join();

        if (req_ctx.err) |e| return e;
        defer allocator.free(req_ctx.received);

        const expected = try std.fmt.allocPrint(allocator, "{{\"id\":{d}}}\n", .{idx});
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, req_ctx.received);
    }
}
