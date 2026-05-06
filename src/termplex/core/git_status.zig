// src/termplex/core/git_status.zig
// Source-control service for Termplex workspaces.

const std = @import("std");

const log = std.log.scoped(.git_status);

const status_output_limit: usize = 512 * 1024;
const diff_output_limit: usize = 768 * 1024;
const small_output_limit: usize = 64 * 1024;

pub const ChangeKind = enum {
    added,
    modified,
    deleted,
    renamed,
    copied,
    untracked,
    type_changed,
    unmerged,
    unknown,
};

pub const Change = struct {
    path: []const u8,
    status: ChangeKind,

    pub fn deinit(self: *Change, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.path = "";
    }
};

pub const Status = struct {
    is_repo: bool,
    root: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    remote_url: ?[]const u8 = null,
    dirty: bool = false,
    staged: []Change = &.{},
    unstaged: []Change = &.{},

    pub fn deinit(self: *Status, allocator: std.mem.Allocator) void {
        if (self.root) |value| allocator.free(value);
        if (self.branch) |value| allocator.free(value);
        if (self.remote_url) |value| allocator.free(value);
        for (self.staged) |*change| change.deinit(allocator);
        for (self.unstaged) |*change| change.deinit(allocator);
        allocator.free(self.staged);
        allocator.free(self.unstaged);
        self.* = .{ .is_repo = false };
    }
};

pub const DiffResult = struct {
    path: []const u8,
    staged: bool,
    diff: []const u8,

    pub fn deinit(self: *DiffResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.diff);
    }
};

pub const CommitResult = struct {
    committed: bool,
    commit: ?[]const u8,
    status: Status,

    pub fn deinit(self: *CommitResult, allocator: std.mem.Allocator) void {
        if (self.commit) |value| allocator.free(value);
        self.status.deinit(allocator);
    }
};

pub const ParsedStatus = struct {
    staged: []Change,
    unstaged: []Change,

    pub fn deinit(self: *ParsedStatus, allocator: std.mem.Allocator) void {
        for (self.staged) |*change| change.deinit(allocator);
        for (self.unstaged) |*change| change.deinit(allocator);
        allocator.free(self.staged);
        allocator.free(self.unstaged);
        self.staged = &.{};
        self.unstaged = &.{};
    }
};

pub const FileArgv = struct {
    argv: [4][]const u8,

    pub fn slice(self: *const FileArgv) []const []const u8 {
        return self.argv[0..];
    }
};

pub const BulkAction = enum {
    stage_all,
    unstage_all,
};

pub const BulkArgv = struct {
    argv: [3][]const u8,
    len: usize,

    pub fn slice(self: *const BulkArgv) []const []const u8 {
        return self.argv[0..self.len];
    }
};

pub fn query(allocator: std.mem.Allocator, directory: []const u8) !Status {
    const root = try repoRoot(allocator, directory) orelse {
        return .{ .is_repo = false };
    };
    errdefer allocator.free(root);

    const branch = try optionalTrimmedGitOutput(
        allocator,
        root,
        &.{ "git", "branch", "--show-current" },
        small_output_limit,
    );
    errdefer if (branch) |value| allocator.free(value);

    const remote_url = try optionalTrimmedGitOutput(
        allocator,
        root,
        &.{ "git", "config", "--get", "remote.origin.url" },
        small_output_limit,
    );
    errdefer if (remote_url) |value| allocator.free(value);

    const status_run = try runGit(
        allocator,
        root,
        &.{ "git", "status", "--porcelain=v1", "-z", "--untracked-files=all" },
        status_output_limit,
    );
    defer status_run.deinit(allocator);

    if (!exited(status_run.term, 0)) return error.GitCommandFailed;

    var parsed = try parseStatusZ(allocator, status_run.stdout);
    errdefer parsed.deinit(allocator);

    return .{
        .is_repo = true,
        .root = root,
        .branch = branch,
        .remote_url = remote_url,
        .dirty = parsed.staged.len > 0 or parsed.unstaged.len > 0,
        .staged = parsed.staged,
        .unstaged = parsed.unstaged,
    };
}

pub fn diff(allocator: std.mem.Allocator, directory: []const u8, path: []const u8, staged: bool) !DiffResult {
    try validatePath(path);

    const root = try repoRoot(allocator, directory) orelse return error.NotRepository;
    defer allocator.free(root);

    const argv: []const []const u8 = if (staged)
        &.{ "git", "diff", "--cached", "--no-ext-diff", "--", path }
    else if (try isUntracked(allocator, root, path))
        &.{ "git", "diff", "--no-ext-diff", "--no-index", "--", "/dev/null", path }
    else
        &.{ "git", "diff", "--no-ext-diff", "--", path };

    const result = try runGit(allocator, root, argv, diff_output_limit);
    defer result.deinit(allocator);

    if (!exited(result.term, 0) and !(!staged and exited(result.term, 1))) {
        return error.GitCommandFailed;
    }

    return .{
        .path = try allocator.dupe(u8, path),
        .staged = staged,
        .diff = try allocator.dupe(u8, result.stdout),
    };
}

pub fn stage(allocator: std.mem.Allocator, directory: []const u8, path: []const u8) !Status {
    try validatePath(path);
    const root = try repoRoot(allocator, directory) orelse return error.NotRepository;
    defer allocator.free(root);

    const file_argv = buildFileArgvForTest("add", path);
    const result = try runGit(allocator, root, file_argv.slice(), small_output_limit);
    defer result.deinit(allocator);
    if (!exited(result.term, 0)) return error.GitCommandFailed;

    return try query(allocator, root);
}

pub fn stageAll(allocator: std.mem.Allocator, directory: []const u8) !Status {
    const root = try repoRoot(allocator, directory) orelse return error.NotRepository;
    defer allocator.free(root);

    const argv = buildBulkArgvForTest(.stage_all);
    const result = try runGit(allocator, root, argv.slice(), small_output_limit);
    defer result.deinit(allocator);
    if (!exited(result.term, 0)) return error.GitCommandFailed;

    return try query(allocator, root);
}

pub fn unstage(allocator: std.mem.Allocator, directory: []const u8, path: []const u8) !Status {
    try validatePath(path);
    const root = try repoRoot(allocator, directory) orelse return error.NotRepository;
    defer allocator.free(root);

    const result = try runGit(
        allocator,
        root,
        &.{ "git", "reset", "--", path },
        small_output_limit,
    );
    defer result.deinit(allocator);
    if (!exited(result.term, 0)) return error.GitCommandFailed;

    return try query(allocator, root);
}

pub fn unstageAll(allocator: std.mem.Allocator, directory: []const u8) !Status {
    const root = try repoRoot(allocator, directory) orelse return error.NotRepository;
    defer allocator.free(root);

    const argv = buildBulkArgvForTest(.unstage_all);
    const result = try runGit(allocator, root, argv.slice(), small_output_limit);
    defer result.deinit(allocator);
    if (!exited(result.term, 0)) return error.GitCommandFailed;

    return try query(allocator, root);
}

pub fn commit(allocator: std.mem.Allocator, directory: []const u8, message: []const u8) !CommitResult {
    if (std.mem.trim(u8, message, " \t\r\n").len == 0) return error.EmptyCommitMessage;
    if (std.mem.indexOfScalar(u8, message, 0) != null) return error.InvalidCommitMessage;

    const root = try repoRoot(allocator, directory) orelse return error.NotRepository;
    defer allocator.free(root);

    const result = try runGit(
        allocator,
        root,
        &.{ "git", "commit", "-m", message },
        diff_output_limit,
    );
    defer result.deinit(allocator);
    if (!exited(result.term, 0)) return error.GitCommandFailed;

    const commit_id = try optionalTrimmedGitOutput(
        allocator,
        root,
        &.{ "git", "rev-parse", "--short", "HEAD" },
        small_output_limit,
    );
    errdefer if (commit_id) |value| allocator.free(value);

    return .{
        .committed = true,
        .commit = commit_id,
        .status = try query(allocator, root),
    };
}

pub fn parseStatusZ(allocator: std.mem.Allocator, data: []const u8) !ParsedStatus {
    var staged: std.ArrayListUnmanaged(Change) = .empty;
    var unstaged: std.ArrayListUnmanaged(Change) = .empty;
    errdefer {
        for (staged.items) |*change| change.deinit(allocator);
        for (unstaged.items) |*change| change.deinit(allocator);
        staged.deinit(allocator);
        unstaged.deinit(allocator);
    }

    var index: usize = 0;
    while (index < data.len) {
        const record_start = index;
        const record_end = std.mem.indexOfScalarPos(u8, data, record_start, 0) orelse data.len;
        index = if (record_end < data.len) record_end + 1 else data.len;
        const record = data[record_start..record_end];
        if (record.len == 0) continue;
        if (record.len < 4) continue;

        const x = record[0];
        const y = record[1];
        const path = record[3..];
        if (path.len == 0) continue;

        if (x == 'R' or x == 'C' or y == 'R' or y == 'C') {
            const old_end = std.mem.indexOfScalarPos(u8, data, index, 0) orelse data.len;
            index = if (old_end < data.len) old_end + 1 else data.len;
        }

        if (x == '?' and y == '?') {
            try appendChange(allocator, &unstaged, path, .untracked);
            continue;
        }

        if (x != ' ' and x != '!' and x != '?') {
            try appendChange(allocator, &staged, path, kindForStatusByte(x));
        }

        if (y != ' ' and y != '!' and y != '?') {
            try appendChange(allocator, &unstaged, path, kindForStatusByte(y));
        }
    }

    return .{
        .staged = try staged.toOwnedSlice(allocator),
        .unstaged = try unstaged.toOwnedSlice(allocator),
    };
}

pub fn buildFileArgvForTest(verb: []const u8, path: []const u8) FileArgv {
    return .{ .argv = .{ "git", verb, "--", path } };
}

pub fn buildBulkArgvForTest(action: BulkAction) BulkArgv {
    return switch (action) {
        .stage_all => .{ .argv = .{ "git", "add", "--all" }, .len = 3 },
        .unstage_all => .{ .argv = .{ "git", "reset", "" }, .len = 2 },
    };
}

fn appendChange(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(Change),
    path: []const u8,
    status: ChangeKind,
) !void {
    try list.append(allocator, .{
        .path = try allocator.dupe(u8, path),
        .status = status,
    });
}

fn kindForStatusByte(byte: u8) ChangeKind {
    return switch (byte) {
        'A' => .added,
        'M' => .modified,
        'D' => .deleted,
        'R' => .renamed,
        'C' => .copied,
        'T' => .type_changed,
        'U' => .unmerged,
        else => .unknown,
    };
}

fn validatePath(path: []const u8) !void {
    if (path.len == 0) return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
}

fn exited(term: std.process.Child.Term, code: u8) bool {
    return term == .Exited and term.Exited == code;
}

fn repoRoot(allocator: std.mem.Allocator, directory: []const u8) !?[]u8 {
    const result = runGit(
        allocator,
        directory,
        &.{ "git", "rev-parse", "--show-toplevel" },
        small_output_limit,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer result.deinit(allocator);

    if (!exited(result.term, 0)) return null;
    return dupeTrimmedOrNull(allocator, result.stdout);
}

fn optionalTrimmedGitOutput(
    allocator: std.mem.Allocator,
    directory: []const u8,
    argv: []const []const u8,
    max_output: usize,
) !?[]u8 {
    const result = runGit(allocator, directory, argv, max_output) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer result.deinit(allocator);

    if (!exited(result.term, 0)) return null;
    return dupeTrimmedOrNull(allocator, result.stdout);
}

fn dupeTrimmedOrNull(allocator: std.mem.Allocator, text: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn isUntracked(allocator: std.mem.Allocator, root: []const u8, path: []const u8) !bool {
    const result = try runGit(
        allocator,
        root,
        &.{ "git", "ls-files", "--others", "--exclude-standard", "--", path },
        small_output_limit,
    );
    defer result.deinit(allocator);
    if (!exited(result.term, 0)) return false;
    return std.mem.trim(u8, result.stdout, " \t\r\n").len > 0;
}

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,

    fn deinit(self: *const RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

fn runGit(
    allocator: std.mem.Allocator,
    directory: []const u8,
    argv: []const []const u8,
    max_output: usize,
) !RunResult {
    var child = std.process.Child.init(argv, allocator);
    child.cwd = directory;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    var stdout_list: std.ArrayListUnmanaged(u8) = .empty;
    var stderr_list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer {
        stdout_list.deinit(allocator);
        stderr_list.deinit(allocator);
    }

    try child.collectOutput(allocator, &stdout_list, &stderr_list, max_output);
    const term = try child.wait();

    if (term != .Exited or term.Exited != 0) {
        log.debug("git command exited with {any}: {s}", .{ term, argv[1] });
    }

    return .{
        .stdout = try stdout_list.toOwnedSlice(allocator),
        .stderr = try stderr_list.toOwnedSlice(allocator),
        .term = term,
    };
}

test "parse porcelain z groups staged and unstaged files" {
    const allocator = std.testing.allocator;
    const parsed = try parseStatusZ(
        allocator,
        "M  staged-only.txt\x00 M unstaged-only.txt\x00MM both.txt\x00?? new.txt\x00",
    );
    defer {
        for (parsed.staged) |change| allocator.free(change.path);
        for (parsed.unstaged) |change| allocator.free(change.path);
        allocator.free(parsed.staged);
        allocator.free(parsed.unstaged);
    }

    try std.testing.expectEqual(@as(usize, 2), parsed.staged.len);
    try std.testing.expectEqualStrings("staged-only.txt", parsed.staged[0].path);
    try std.testing.expectEqual(ChangeKind.modified, parsed.staged[0].status);
    try std.testing.expectEqualStrings("both.txt", parsed.staged[1].path);

    try std.testing.expectEqual(@as(usize, 3), parsed.unstaged.len);
    try std.testing.expectEqualStrings("unstaged-only.txt", parsed.unstaged[0].path);
    try std.testing.expectEqual(ChangeKind.modified, parsed.unstaged[0].status);
    try std.testing.expectEqualStrings("both.txt", parsed.unstaged[1].path);
    try std.testing.expectEqualStrings("new.txt", parsed.unstaged[2].path);
    try std.testing.expectEqual(ChangeKind.untracked, parsed.unstaged[2].status);
}

test "file scoped git argv places paths after separator" {
    const argv = buildFileArgvForTest("add", "-looks-like-option");
    const args = argv.slice();
    try std.testing.expectEqual(@as(usize, 4), args.len);
    try std.testing.expectEqualStrings("git", args[0]);
    try std.testing.expectEqualStrings("add", args[1]);
    try std.testing.expectEqualStrings("--", args[2]);
    try std.testing.expectEqualStrings("-looks-like-option", args[3]);
}

test "bulk git argv stages all tracked and untracked changes" {
    const argv = buildBulkArgvForTest(.stage_all);
    const args = argv.slice();
    try std.testing.expectEqual(@as(usize, 3), args.len);
    try std.testing.expectEqualStrings("git", args[0]);
    try std.testing.expectEqualStrings("add", args[1]);
    try std.testing.expectEqualStrings("--all", args[2]);
}

test "bulk git argv unstages without a path argument" {
    const argv = buildBulkArgvForTest(.unstage_all);
    const args = argv.slice();
    try std.testing.expectEqual(@as(usize, 2), args.len);
    try std.testing.expectEqualStrings("git", args[0]);
    try std.testing.expectEqualStrings("reset", args[1]);
}
