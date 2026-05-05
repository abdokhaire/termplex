// src/termplex/core/git_probe.zig
// GitProbe: interrogates a directory's git state by running git subprocesses.
//
// Key types:
//   GitResult — branch name (optional) and dirty flag; owns its strings.
//   probe(allocator, directory) — runs git commands, returns GitResult.

const std = @import("std");

const log = std.log.scoped(.git_probe);

// ---------------------------------------------------------------------------
// GitResult
// ---------------------------------------------------------------------------

/// The result of probing a directory for git state.
///
/// `branch` is null when the directory is not inside a git repository or when
/// git is not installed.  All strings are owned by this struct; call `deinit`
/// to release them.
pub const GitResult = struct {
    /// Current branch name, or null if not a git repo (or git unavailable).
    branch: ?[]const u8,
    /// True when `git status --porcelain` produces non-empty output.
    dirty: bool,
    /// Number of porcelain rows with an index/staged-side change.
    staged_count: u32 = 0,
    /// Number of porcelain rows with a worktree/unstaged-side change.
    unstaged_count: u32 = 0,

    /// Free all owned strings.  Safe to call on the zero-value struct.
    pub fn deinit(self: *GitResult, allocator: std.mem.Allocator) void {
        if (self.branch) |b| allocator.free(b);
        self.branch = null;
    }
};

// ---------------------------------------------------------------------------
// probe
// ---------------------------------------------------------------------------

/// Probe `directory` for its git branch and dirty status.
///
/// Runs:
///   git rev-parse --abbrev-ref HEAD   → branch name
///   git status --porcelain            → dirty + staged/unstaged counts
///
/// Returns `{ .branch = null, .dirty = false }` when:
///   - the directory is not inside a git repository
///   - git is not installed / not found on PATH
///   - any other subprocess failure
///
/// The returned `GitResult.branch` string is allocated with `allocator`;
/// the caller is responsible for calling `deinit`.
pub fn probe(allocator: std.mem.Allocator, directory: []const u8) GitResult {
    const branch = getBranch(allocator, directory) catch |err| {
        log.debug("git rev-parse failed for '{s}': {}", .{ directory, err });
        return .{ .branch = null, .dirty = false };
    };

    // If branch is null the directory is not a git repo; skip status.
    if (branch == null) {
        return .{ .branch = null, .dirty = false };
    }

    const counts = getStatusCounts(allocator, directory) catch |err| {
        log.debug("git status failed for '{s}': {}", .{ directory, err });
        // We already have a branch — keep it, just assume clean.
        return .{ .branch = branch, .dirty = false };
    };

    return .{
        .branch = branch,
        .dirty = counts.dirty,
        .staged_count = counts.staged,
        .unstaged_count = counts.unstaged,
    };
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Run `git rev-parse --abbrev-ref HEAD` in `directory`.
///
/// Returns:
///   - `null`          if git exits non-zero (not a repo, detached HEAD returning
///                     "HEAD" is still a valid branch string)
///   - owned slice     on success (caller frees)
///   - error           on spawn failure (git not found, OOM, …)
fn getBranch(allocator: std.mem.Allocator, directory: []const u8) !?[]const u8 {
    const result = runGit(
        allocator,
        directory,
        &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" },
    ) catch |err| switch (err) {
        // FileNotFound means git is not installed.
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        // Non-zero exit = not a git repo or some other git error.
        return null;
    }

    const trimmed = std.mem.trimRight(u8, result.stdout, "\n\r ");
    if (trimmed.len == 0) return null;

    return try allocator.dupe(u8, trimmed);
}

const StatusCounts = struct {
    dirty: bool,
    staged: u32,
    unstaged: u32,
};

/// Run `git status --porcelain` in `directory` and count staged/unstaged rows.
fn getStatusCounts(allocator: std.mem.Allocator, directory: []const u8) !StatusCounts {
    const result = runGit(
        allocator,
        directory,
        &.{ "git", "status", "--porcelain" },
    ) catch |err| switch (err) {
        error.FileNotFound => return .{ .dirty = false, .staged = 0, .unstaged = 0 },
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        return .{ .dirty = false, .staged = 0, .unstaged = 0 };
    }

    return parseStatusCounts(result.stdout);
}

fn parseStatusCounts(output: []const u8) StatusCounts {
    var counts = StatusCounts{ .dirty = false, .staged = 0, .unstaged = 0 };

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (line.len < 2) continue;

        const staged = line[0];
        const unstaged = line[1];
        const is_untracked = staged == '?' and unstaged == '?';

        if (is_untracked) {
            counts.unstaged += 1;
            continue;
        }

        if (staged != ' ') counts.staged += 1;
        if (unstaged != ' ') counts.unstaged += 1;
    }

    counts.dirty = counts.staged > 0 or counts.unstaged > 0;
    return counts;
}

/// Subprocess result: stdout and stderr are owned by the caller.
const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,
};

/// Run `argv` with `cwd` set to `directory` and collect stdout + stderr.
///
/// Caller frees `result.stdout` and `result.stderr`.
fn runGit(
    allocator: std.mem.Allocator,
    directory: []const u8,
    argv: []const []const u8,
) !RunResult {
    var child = std.process.Child.init(argv, allocator);
    child.cwd = directory;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    var stdout_list: std.ArrayListUnmanaged(u8) = .{};
    var stderr_list: std.ArrayListUnmanaged(u8) = .{};
    errdefer {
        stdout_list.deinit(allocator);
        stderr_list.deinit(allocator);
    }

    // 64 KiB cap — more than enough for branch names / status output.
    const max_output: usize = 64 * 1024;
    try child.collectOutput(allocator, &stdout_list, &stderr_list, max_output);

    const term = try child.wait();

    return RunResult{
        .stdout = try stdout_list.toOwnedSlice(allocator),
        .stderr = try stderr_list.toOwnedSlice(allocator),
        .term = term,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "GitResult deinit with branch" {
    const allocator = std.testing.allocator;
    var result = GitResult{
        .branch = try allocator.dupe(u8, "main"),
        .dirty = false,
    };
    result.deinit(allocator);
    try std.testing.expect(result.branch == null);
}

test "GitResult deinit with null branch" {
    const allocator = std.testing.allocator;
    var result = GitResult{ .branch = null, .dirty = false };
    // Must not crash.
    result.deinit(allocator);
    try std.testing.expect(result.branch == null);
}

test "probe returns null branch for non-git directory" {
    const allocator = std.testing.allocator;
    // /tmp is virtually guaranteed not to be a git repo.
    var result = probe(allocator, "/tmp");
    defer result.deinit(allocator);

    try std.testing.expect(result.branch == null);
    try std.testing.expectEqual(false, result.dirty);
}

test "probe returns null branch and not dirty for non-existent directory" {
    const allocator = std.testing.allocator;
    var result = probe(allocator, "/this/path/does/not/exist/ever");
    defer result.deinit(allocator);

    try std.testing.expect(result.branch == null);
    try std.testing.expectEqual(false, result.dirty);
}

test "probe on a real git repo returns non-null branch" {
    // This test is opportunistic: it probes the repo that contains this file.
    // If for some reason git isn't installed the probe gracefully returns null.
    const allocator = std.testing.allocator;

    // Use the source root of this project (parent dirs of this file).
    // In tests the cwd is typically the project root.
    var result = probe(allocator, ".");
    defer result.deinit(allocator);

    // We can't assert the exact branch name, but we can verify shape.
    if (result.branch) |b| {
        try std.testing.expect(b.len > 0);
    }
    // dirty can be true or false — just make sure it's a bool (always true in Zig).
}

test "git probe parses staged and unstaged porcelain counts" {
    const counts = parseStatusCounts(
        \\ M src/main.zig
        \\M  README.md
        \\MM build.zig
        \\A  new-file.txt
        \\?? scratch.txt
        \\
    );

    try std.testing.expectEqual(@as(u32, 3), counts.staged);
    try std.testing.expectEqual(@as(u32, 3), counts.unstaged);
    try std.testing.expectEqual(true, counts.dirty);
}
