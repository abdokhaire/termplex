const std = @import("std");

const SQLITE_OK = 0;
const SQLITE_ROW = 100;
const SQLITE_DONE = 101;
const SQLITE_NULL = 5;
const SQLITE_OPEN_READWRITE = 0x00000002;
const SQLITE_OPEN_CREATE = 0x00000004;
const SQLITE_OPEN_FULLMUTEX = 0x00010000;

const sqlite3 = opaque {};
const sqlite3_stmt = opaque {};
const sqlite3_destructor_type = ?*const fn (?*anyopaque) callconv(.c) void;

const Sqlite = struct {
    lib: std.DynLib,

    open_v2: *const fn ([*:0]const u8, *?*sqlite3, c_int, ?[*:0]const u8) callconv(.c) c_int,
    close: *const fn (*sqlite3) callconv(.c) c_int,
    exec: *const fn (*sqlite3, [*:0]const u8, ?*anyopaque, ?*anyopaque, *?[*:0]u8) callconv(.c) c_int,
    free: *const fn (?*anyopaque) callconv(.c) void,
    prepare_v2: *const fn (*sqlite3, [*:0]const u8, c_int, *?*sqlite3_stmt, ?*anyopaque) callconv(.c) c_int,
    finalize: *const fn (*sqlite3_stmt) callconv(.c) c_int,
    bind_text: *const fn (*sqlite3_stmt, c_int, [*]const u8, c_int, sqlite3_destructor_type) callconv(.c) c_int,
    bind_null: *const fn (*sqlite3_stmt, c_int) callconv(.c) c_int,
    bind_int64: *const fn (*sqlite3_stmt, c_int, i64) callconv(.c) c_int,
    step: *const fn (*sqlite3_stmt) callconv(.c) c_int,
    column_text: *const fn (*sqlite3_stmt, c_int) callconv(.c) ?[*]const u8,
    column_bytes: *const fn (*sqlite3_stmt, c_int) callconv(.c) c_int,
    column_type: *const fn (*sqlite3_stmt, c_int) callconv(.c) c_int,
    column_int64: *const fn (*sqlite3_stmt, c_int) callconv(.c) i64,
    last_insert_rowid: *const fn (*sqlite3) callconv(.c) i64,
    get_autocommit: *const fn (*sqlite3) callconv(.c) c_int,

    fn load() !Sqlite {
        var lib = std.DynLib.open("libsqlite3.so.0") catch |primary_err| blk: {
            break :blk std.DynLib.open("libsqlite3.so") catch return primary_err;
        };
        errdefer lib.close();

        return .{
            .lib = lib,
            .open_v2 = lib.lookup(@TypeOf(@as(Sqlite, undefined).open_v2), "sqlite3_open_v2") orelse return error.SqliteSymbolMissing,
            .close = lib.lookup(@TypeOf(@as(Sqlite, undefined).close), "sqlite3_close") orelse return error.SqliteSymbolMissing,
            .exec = lib.lookup(@TypeOf(@as(Sqlite, undefined).exec), "sqlite3_exec") orelse return error.SqliteSymbolMissing,
            .free = lib.lookup(@TypeOf(@as(Sqlite, undefined).free), "sqlite3_free") orelse return error.SqliteSymbolMissing,
            .prepare_v2 = lib.lookup(@TypeOf(@as(Sqlite, undefined).prepare_v2), "sqlite3_prepare_v2") orelse return error.SqliteSymbolMissing,
            .finalize = lib.lookup(@TypeOf(@as(Sqlite, undefined).finalize), "sqlite3_finalize") orelse return error.SqliteSymbolMissing,
            .bind_text = lib.lookup(@TypeOf(@as(Sqlite, undefined).bind_text), "sqlite3_bind_text") orelse return error.SqliteSymbolMissing,
            .bind_null = lib.lookup(@TypeOf(@as(Sqlite, undefined).bind_null), "sqlite3_bind_null") orelse return error.SqliteSymbolMissing,
            .bind_int64 = lib.lookup(@TypeOf(@as(Sqlite, undefined).bind_int64), "sqlite3_bind_int64") orelse return error.SqliteSymbolMissing,
            .step = lib.lookup(@TypeOf(@as(Sqlite, undefined).step), "sqlite3_step") orelse return error.SqliteSymbolMissing,
            .column_text = lib.lookup(@TypeOf(@as(Sqlite, undefined).column_text), "sqlite3_column_text") orelse return error.SqliteSymbolMissing,
            .column_bytes = lib.lookup(@TypeOf(@as(Sqlite, undefined).column_bytes), "sqlite3_column_bytes") orelse return error.SqliteSymbolMissing,
            .column_type = lib.lookup(@TypeOf(@as(Sqlite, undefined).column_type), "sqlite3_column_type") orelse return error.SqliteSymbolMissing,
            .column_int64 = lib.lookup(@TypeOf(@as(Sqlite, undefined).column_int64), "sqlite3_column_int64") orelse return error.SqliteSymbolMissing,
            .last_insert_rowid = lib.lookup(@TypeOf(@as(Sqlite, undefined).last_insert_rowid), "sqlite3_last_insert_rowid") orelse return error.SqliteSymbolMissing,
            .get_autocommit = lib.lookup(@TypeOf(@as(Sqlite, undefined).get_autocommit), "sqlite3_get_autocommit") orelse return error.SqliteSymbolMissing,
        };
    }

    fn deinit(self: *Sqlite) void {
        self.lib.close();
    }
};

pub const ProjectUpsert = struct {
    workspace_id: []const u8,
    workspace_name: []const u8,
    workspace_dir: []const u8,
    git_remote_url: ?[]const u8 = null,
    git_branch: ?[]const u8 = null,
    git_dirty: bool = false,
    timestamp: []const u8,
};

pub const ProjectRecord = struct {
    workspace_id: []const u8,
    workspace_name: []const u8,
    workspace_dir: []const u8,
    git_remote_url: ?[]const u8,
    git_branch: ?[]const u8,
    git_dirty: bool,
    updated_at: []const u8,

    pub fn deinit(self: *ProjectRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_id);
        allocator.free(self.workspace_name);
        allocator.free(self.workspace_dir);
        if (self.git_remote_url) |v| allocator.free(v);
        if (self.git_branch) |v| allocator.free(v);
        allocator.free(self.updated_at);
    }
};

pub const SurfaceUpsert = struct {
    history_id: []const u8,
    workspace_id: []const u8,
    workspace_name: []const u8,
    workspace_dir: []const u8,
    working_directory: []const u8,
    env_fingerprint: ?[]const u8 = null,
    transcript_path: []const u8,
    status: []const u8 = "active",
    last_exit_code: ?i32 = null,
    process_pid: ?i64 = null,
    process_alive: bool = false,
    detection_method: ?[]const u8 = null,
    ports_json: ?[]const u8 = null,
    command_started_at: ?[]const u8 = null,
    last_command: ?[]const u8 = null,
    timestamp: []const u8,
};

pub const SurfaceRecord = struct {
    history_id: []const u8,
    workspace_id: []const u8,
    workspace_name: []const u8,
    workspace_dir: []const u8,
    working_directory: []const u8,
    env_fingerprint: ?[]const u8,
    transcript_path: []const u8,
    status: []const u8,
    last_exit_code: ?i32,
    process_pid: ?i64,
    process_alive: bool,
    detection_method: ?[]const u8,
    ports_json: ?[]const u8,
    command_started_at: ?[]const u8,
    last_command: ?[]const u8,
    updated_at: []const u8,

    pub fn deinit(self: *SurfaceRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.history_id);
        allocator.free(self.workspace_id);
        allocator.free(self.workspace_name);
        allocator.free(self.workspace_dir);
        allocator.free(self.working_directory);
        if (self.env_fingerprint) |v| allocator.free(v);
        allocator.free(self.transcript_path);
        allocator.free(self.status);
        if (self.detection_method) |v| allocator.free(v);
        if (self.ports_json) |v| allocator.free(v);
        if (self.command_started_at) |v| allocator.free(v);
        if (self.last_command) |v| allocator.free(v);
        allocator.free(self.updated_at);
    }
};

pub const ResumeCandidateQuery = struct {
    limit: u32 = 20,
    workspace_id: ?[]const u8 = null,
};

pub const ResumeCandidate = struct {
    history_id: []const u8,
    workspace_id: []const u8,
    workspace_name: []const u8,
    workspace_dir: []const u8,
    working_directory: []const u8,
    status: []const u8,
    process_pid: ?i64,
    detection_method: ?[]const u8,
    ports_json: ?[]const u8,
    command_started_at: ?[]const u8,
    last_command: ?[]const u8,
    updated_at: []const u8,

    pub fn deinit(self: *ResumeCandidate, allocator: std.mem.Allocator) void {
        allocator.free(self.history_id);
        allocator.free(self.workspace_id);
        allocator.free(self.workspace_name);
        allocator.free(self.workspace_dir);
        allocator.free(self.working_directory);
        allocator.free(self.status);
        if (self.detection_method) |v| allocator.free(v);
        if (self.ports_json) |v| allocator.free(v);
        if (self.command_started_at) |v| allocator.free(v);
        if (self.last_command) |v| allocator.free(v);
        allocator.free(self.updated_at);
    }
};

pub const ResumeCandidateList = struct {
    items: []ResumeCandidate,

    pub fn deinit(self: ResumeCandidateList, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const CommandStart = struct {
    history_id: []const u8,
    workspace_id: []const u8,
    workspace_name: []const u8,
    workspace_dir: []const u8,
    command: []const u8,
    started_at: []const u8,
    source: []const u8,
};

pub const CommandFinish = struct {
    history_id: []const u8,
    ended_at: []const u8,
    exit_code: ?i32,
};

pub const CommandRecord = struct {
    id: i64,
    history_id: []const u8,
    workspace_id: []const u8,
    workspace_name: []const u8,
    workspace_dir: []const u8,
    command: []const u8,
    started_at: []const u8,
    ended_at: ?[]const u8,
    exit_code: ?i32,
    source: []const u8,

    pub fn deinit(self: *CommandRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.history_id);
        allocator.free(self.workspace_id);
        allocator.free(self.workspace_name);
        allocator.free(self.workspace_dir);
        allocator.free(self.command);
        allocator.free(self.started_at);
        if (self.ended_at) |v| allocator.free(v);
        allocator.free(self.source);
    }
};

pub const CommandList = struct {
    items: []CommandRecord,

    pub fn deinit(self: CommandList, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const TaskUpsert = struct {
    workspace_id: []const u8,
    name: []const u8,
    command: []const u8,
    working_directory: ?[]const u8 = null,
    timestamp: []const u8,
};

pub const TaskRecord = struct {
    id: i64,
    workspace_id: []const u8,
    name: []const u8,
    command: []const u8,
    working_directory: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,
    last_run_at: ?[]const u8,
    run_count: u64,

    pub fn deinit(self: *TaskRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace_id);
        allocator.free(self.name);
        allocator.free(self.command);
        if (self.working_directory) |value| allocator.free(value);
        allocator.free(self.created_at);
        allocator.free(self.updated_at);
        if (self.last_run_at) |value| allocator.free(value);
    }
};

pub const TaskList = struct {
    items: []TaskRecord,

    pub fn deinit(self: TaskList, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const RowCounts = struct {
    project_count: u64,
    surface_count: u64,
    command_count: u64,
    task_count: u64,
};

pub const RecentQuery = struct {
    limit: u32 = 20,
    workspace_id: ?[]const u8 = null,
    history_id: ?[]const u8 = null,
};

pub const SearchQuery = struct {
    text: ?[]const u8 = null,
    workspace_id: ?[]const u8 = null,
    workspace_name: ?[]const u8 = null,
    workspace_dir: ?[]const u8 = null,
    source: ?[]const u8 = null,
    exit_code: ?i32 = null,
    started_after: ?[]const u8 = null,
    started_before: ?[]const u8 = null,
    limit: u32 = 50,
};

pub const Database = struct {
    allocator: std.mem.Allocator,
    sqlite: Sqlite,
    handle: *sqlite3,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Database {
        const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
        try std.fs.cwd().makePath(parent);

        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        var sqlite = try Sqlite.load();
        errdefer sqlite.deinit();

        var handle: ?*sqlite3 = null;
        const flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX;
        if (sqlite.open_v2(path_z.ptr, &handle, flags, null) != SQLITE_OK) {
            if (handle) |h| _ = sqlite.close(h);
            return error.OpenFailed;
        }

        return .{
            .allocator = allocator,
            .sqlite = sqlite,
            .handle = handle.?,
        };
    }

    pub fn deinit(self: *Database) void {
        _ = self.sqlite.close(self.handle);
        self.sqlite.deinit();
    }

    fn exec(self: *Database, sql: [:0]const u8) !void {
        var err_msg: ?[*:0]u8 = null;
        defer if (err_msg) |msg| self.sqlite.free(@ptrCast(msg));
        if (self.sqlite.exec(self.handle, sql.ptr, null, null, &err_msg) != SQLITE_OK) {
            return error.SqlExecFailed;
        }
    }

    pub fn commitIfNeeded(self: *Database) !void {
        if (self.sqlite.get_autocommit(self.handle) != 0) return;
        try self.exec("COMMIT");
    }

    fn prepare(self: *Database, sql: [:0]const u8) !Statement {
        var stmt: ?*sqlite3_stmt = null;
        if (self.sqlite.prepare_v2(self.handle, sql.ptr, -1, &stmt, null) != SQLITE_OK) {
            return error.SqlPrepareFailed;
        }
        return .{
            .allocator = self.allocator,
            .sqlite = &self.sqlite,
            .stmt = stmt.?,
        };
    }

    pub fn migrate(self: *Database) !void {
        try self.exec(
            \\PRAGMA journal_mode = WAL;
            \\PRAGMA foreign_keys = ON;
            \\PRAGMA busy_timeout = 250;
            \\CREATE TABLE IF NOT EXISTS schema_migrations (
            \\  version INTEGER PRIMARY KEY,
            \\  applied_at TEXT NOT NULL
            \\);
            \\CREATE TABLE IF NOT EXISTS terminal_projects (
            \\  workspace_id TEXT PRIMARY KEY,
            \\  workspace_name TEXT NOT NULL,
            \\  workspace_dir TEXT NOT NULL,
            \\  git_remote_url TEXT,
            \\  git_branch TEXT,
            \\  git_dirty INTEGER NOT NULL DEFAULT 0,
            \\  created_at TEXT NOT NULL,
            \\  updated_at TEXT NOT NULL,
            \\  deleted_at TEXT
            \\);
            \\CREATE TABLE IF NOT EXISTS terminal_surfaces (
            \\  history_id TEXT PRIMARY KEY,
            \\  workspace_id TEXT NOT NULL,
            \\  workspace_name TEXT NOT NULL,
            \\  workspace_dir TEXT NOT NULL,
            \\  working_directory TEXT NOT NULL,
            \\  env_fingerprint TEXT,
            \\  transcript_path TEXT NOT NULL,
            \\  status TEXT NOT NULL DEFAULT 'active',
            \\  last_exit_code INTEGER,
            \\  process_pid INTEGER,
            \\  process_alive INTEGER NOT NULL DEFAULT 0,
            \\  detection_method TEXT,
            \\  ports_json TEXT,
            \\  command_started_at TEXT,
            \\  last_command TEXT,
            \\  created_at TEXT NOT NULL,
            \\  updated_at TEXT NOT NULL,
            \\  deleted_at TEXT,
            \\  FOREIGN KEY(workspace_id) REFERENCES terminal_projects(workspace_id)
            \\);
            \\CREATE TABLE IF NOT EXISTS command_history (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  history_id TEXT NOT NULL,
            \\  workspace_id TEXT NOT NULL,
            \\  workspace_name TEXT NOT NULL,
            \\  workspace_dir TEXT NOT NULL,
            \\  command TEXT NOT NULL,
            \\  started_at TEXT NOT NULL,
            \\  ended_at TEXT,
            \\  exit_code INTEGER,
            \\  source TEXT NOT NULL,
            \\  created_at TEXT NOT NULL,
            \\  updated_at TEXT NOT NULL
            \\);
            \\CREATE TABLE IF NOT EXISTS workspace_tasks (
            \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  workspace_id TEXT NOT NULL,
            \\  name TEXT NOT NULL,
            \\  command TEXT NOT NULL,
            \\  working_directory TEXT,
            \\  created_at TEXT NOT NULL,
            \\  updated_at TEXT NOT NULL,
            \\  last_run_at TEXT,
            \\  run_count INTEGER NOT NULL DEFAULT 0,
            \\  UNIQUE(workspace_id, name),
            \\  FOREIGN KEY(workspace_id) REFERENCES terminal_projects(workspace_id)
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_command_history_started_at
            \\  ON command_history(started_at DESC);
            \\CREATE INDEX IF NOT EXISTS idx_command_history_workspace_started
            \\  ON command_history(workspace_id, started_at DESC);
            \\CREATE INDEX IF NOT EXISTS idx_command_history_surface_started
            \\  ON command_history(history_id, started_at DESC);
            \\CREATE INDEX IF NOT EXISTS idx_terminal_projects_dir
            \\  ON terminal_projects(workspace_dir);
            \\CREATE INDEX IF NOT EXISTS idx_terminal_surfaces_workspace
            \\  ON terminal_surfaces(workspace_id, updated_at DESC);
            \\CREATE INDEX IF NOT EXISTS idx_workspace_tasks_workspace_updated
            \\  ON workspace_tasks(workspace_id, updated_at DESC);
            \\INSERT OR IGNORE INTO schema_migrations(version, applied_at)
            \\VALUES (1, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
            \\INSERT OR IGNORE INTO schema_migrations(version, applied_at)
            \\VALUES (2, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
        );
        try self.ensureColumn("terminal_surfaces", "process_pid", "process_pid INTEGER");
        try self.ensureColumn("terminal_surfaces", "process_alive", "process_alive INTEGER NOT NULL DEFAULT 0");
        try self.ensureColumn("terminal_surfaces", "detection_method", "detection_method TEXT");
        try self.ensureColumn("terminal_surfaces", "ports_json", "ports_json TEXT");
        try self.ensureColumn("terminal_surfaces", "command_started_at", "command_started_at TEXT");
        try self.ensureColumn("terminal_surfaces", "last_command", "last_command TEXT");
        try self.exec(
            \\CREATE INDEX IF NOT EXISTS idx_terminal_surfaces_process_alive
            \\  ON terminal_surfaces(process_alive, updated_at DESC);
            \\INSERT OR IGNORE INTO schema_migrations(version, applied_at)
            \\VALUES (3, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
        );
    }

    fn ensureColumn(self: *Database, table_name: []const u8, column_name: []const u8, column_def: []const u8) !void {
        if (try self.columnExists(table_name, column_name)) return;
        const sql_buf = try std.fmt.allocPrint(self.allocator, "ALTER TABLE {s} ADD COLUMN {s}\x00", .{ table_name, column_def });
        defer self.allocator.free(sql_buf);
        const sql: [:0]const u8 = sql_buf[0 .. sql_buf.len - 1 :0];
        try self.exec(sql);
    }

    fn columnExists(self: *Database, table_name: []const u8, column_name: []const u8) !bool {
        const sql_buf = try std.fmt.allocPrint(self.allocator, "PRAGMA table_info({s})\x00", .{table_name});
        defer self.allocator.free(sql_buf);
        const sql: [:0]const u8 = sql_buf[0 .. sql_buf.len - 1 :0];
        var stmt = try self.prepare(sql);
        defer stmt.deinit();
        while (try stmt.stepRow()) {
            const name = try stmt.readTextAlloc(1);
            defer self.allocator.free(name);
            if (std.mem.eql(u8, name, column_name)) return true;
        }
        return false;
    }

    pub fn upsertProject(self: *Database, input: ProjectUpsert) !void {
        var stmt = try self.prepare(
            \\INSERT INTO terminal_projects (
            \\  workspace_id, workspace_name, workspace_dir, git_remote_url, git_branch,
            \\  git_dirty, created_at, updated_at, deleted_at
            \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)
            \\ON CONFLICT(workspace_id) DO UPDATE SET
            \\  workspace_name = excluded.workspace_name,
            \\  workspace_dir = excluded.workspace_dir,
            \\  git_remote_url = excluded.git_remote_url,
            \\  git_branch = excluded.git_branch,
            \\  git_dirty = excluded.git_dirty,
            \\  updated_at = excluded.updated_at,
            \\  deleted_at = NULL
        );
        defer stmt.deinit();
        try stmt.bindText(1, input.workspace_id);
        try stmt.bindText(2, input.workspace_name);
        try stmt.bindText(3, input.workspace_dir);
        try stmt.bindOptionalText(4, input.git_remote_url);
        try stmt.bindOptionalText(5, input.git_branch);
        try stmt.bindInt64(6, @as(i64, if (input.git_dirty) 1 else 0));
        try stmt.bindText(7, input.timestamp);
        try stmt.bindText(8, input.timestamp);
        try stmt.stepDone();
    }

    pub fn ensureProject(self: *Database, input: ProjectUpsert) !void {
        var stmt = try self.prepare(
            \\INSERT OR IGNORE INTO terminal_projects (
            \\  workspace_id, workspace_name, workspace_dir, git_remote_url, git_branch,
            \\  git_dirty, created_at, updated_at, deleted_at
            \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)
        );
        defer stmt.deinit();
        try stmt.bindText(1, input.workspace_id);
        try stmt.bindText(2, input.workspace_name);
        try stmt.bindText(3, input.workspace_dir);
        try stmt.bindOptionalText(4, input.git_remote_url);
        try stmt.bindOptionalText(5, input.git_branch);
        try stmt.bindInt64(6, @as(i64, if (input.git_dirty) 1 else 0));
        try stmt.bindText(7, input.timestamp);
        try stmt.bindText(8, input.timestamp);
        try stmt.stepDone();
    }

    pub fn getProject(self: *Database, workspace_id: []const u8) !ProjectRecord {
        var stmt = try self.prepare(
            \\SELECT workspace_id, workspace_name, workspace_dir, git_remote_url,
            \\       git_branch, git_dirty, updated_at
            \\FROM terminal_projects
            \\WHERE workspace_id = ? AND deleted_at IS NULL
        );
        defer stmt.deinit();
        try stmt.bindText(1, workspace_id);
        if (!try stmt.stepRow()) return error.NotFound;
        return try stmt.readProjectRecord();
    }

    pub fn upsertSurface(self: *Database, input: SurfaceUpsert) !void {
        var stmt = try self.prepare(
            \\INSERT INTO terminal_surfaces (
            \\  history_id, workspace_id, workspace_name, workspace_dir, working_directory,
            \\  env_fingerprint, transcript_path, status, last_exit_code, process_pid,
            \\  process_alive, detection_method, ports_json, command_started_at,
            \\  last_command, created_at, updated_at, deleted_at
            \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
            \\ON CONFLICT(history_id) DO UPDATE SET
            \\  workspace_id = excluded.workspace_id,
            \\  workspace_name = excluded.workspace_name,
            \\  workspace_dir = excluded.workspace_dir,
            \\  working_directory = excluded.working_directory,
            \\  env_fingerprint = excluded.env_fingerprint,
            \\  transcript_path = excluded.transcript_path,
            \\  status = excluded.status,
            \\  last_exit_code = excluded.last_exit_code,
            \\  process_pid = excluded.process_pid,
            \\  process_alive = excluded.process_alive,
            \\  detection_method = excluded.detection_method,
            \\  ports_json = excluded.ports_json,
            \\  command_started_at = excluded.command_started_at,
            \\  last_command = excluded.last_command,
            \\  updated_at = excluded.updated_at,
            \\  deleted_at = NULL
        );
        defer stmt.deinit();
        try stmt.bindText(1, input.history_id);
        try stmt.bindText(2, input.workspace_id);
        try stmt.bindText(3, input.workspace_name);
        try stmt.bindText(4, input.workspace_dir);
        try stmt.bindText(5, input.working_directory);
        try stmt.bindOptionalText(6, input.env_fingerprint);
        try stmt.bindText(7, input.transcript_path);
        try stmt.bindText(8, input.status);
        try stmt.bindOptionalInt(9, input.last_exit_code);
        try stmt.bindOptionalInt64(10, input.process_pid);
        try stmt.bindInt64(11, @as(i64, if (input.process_alive) 1 else 0));
        try stmt.bindOptionalText(12, input.detection_method);
        try stmt.bindOptionalText(13, input.ports_json);
        try stmt.bindOptionalText(14, input.command_started_at);
        try stmt.bindOptionalText(15, input.last_command);
        try stmt.bindText(16, input.timestamp);
        try stmt.bindText(17, input.timestamp);
        try stmt.stepDone();
    }

    pub fn getSurface(self: *Database, history_id: []const u8) !SurfaceRecord {
        var stmt = try self.prepare(
            \\SELECT history_id, workspace_id, workspace_name, workspace_dir,
            \\       working_directory, env_fingerprint, transcript_path,
            \\       status, last_exit_code, process_pid, process_alive,
            \\       detection_method, ports_json, command_started_at,
            \\       last_command, updated_at
            \\FROM terminal_surfaces
            \\WHERE history_id = ? AND deleted_at IS NULL
        );
        defer stmt.deinit();
        try stmt.bindText(1, history_id);
        if (!try stmt.stepRow()) return error.NotFound;
        return try stmt.readSurfaceRecord();
    }

    pub fn updateSurfaceRuntimeState(
        self: *Database,
        history_id: []const u8,
        process_alive: bool,
        process_pid: ?i64,
        last_exit_code: ?i32,
        timestamp: []const u8,
    ) !void {
        var stmt = try self.prepare(
            \\UPDATE terminal_surfaces
            \\SET process_alive = ?1,
            \\    process_pid = coalesce(?2, process_pid),
            \\    last_exit_code = coalesce(?3, last_exit_code),
            \\    updated_at = ?4
            \\WHERE history_id = ?5 AND deleted_at IS NULL
        );
        defer stmt.deinit();
        try stmt.bindInt64(1, @as(i64, if (process_alive) 1 else 0));
        try stmt.bindOptionalInt64(2, process_pid);
        try stmt.bindOptionalInt(3, last_exit_code);
        try stmt.bindText(4, timestamp);
        try stmt.bindText(5, history_id);
        try stmt.stepDone();
    }

    pub fn listResumeCandidates(self: *Database, query: ResumeCandidateQuery) !ResumeCandidateList {
        var stmt = try self.prepare(
            \\SELECT history_id, workspace_id, workspace_name, workspace_dir,
            \\       working_directory, status, process_pid, detection_method,
            \\       ports_json, command_started_at, last_command, updated_at
            \\FROM terminal_surfaces
            \\WHERE deleted_at IS NULL
            \\  AND process_alive != 0
            \\  AND (?1 IS NULL OR workspace_id = ?1)
            \\ORDER BY coalesce(command_started_at, updated_at) DESC, updated_at DESC
            \\LIMIT ?2
        );
        defer stmt.deinit();
        try stmt.bindOptionalText(1, nonEmptyOptional(query.workspace_id));
        try stmt.bindInt64(2, @max(query.limit, 1));

        var items: std.ArrayListUnmanaged(ResumeCandidate) = .empty;
        errdefer {
            for (items.items) |*item| item.deinit(self.allocator);
            items.deinit(self.allocator);
        }
        while (try stmt.stepRow()) {
            try items.append(self.allocator, try stmt.readResumeCandidate());
        }
        return .{ .items = try items.toOwnedSlice(self.allocator) };
    }

    pub fn startCommand(self: *Database, input: CommandStart) !i64 {
        var stmt = try self.prepare(
            \\INSERT INTO command_history (
            \\  history_id, workspace_id, workspace_name, workspace_dir, command, started_at, source, created_at, updated_at
            \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        );
        defer stmt.deinit();
        try stmt.bindText(1, input.history_id);
        try stmt.bindText(2, input.workspace_id);
        try stmt.bindText(3, input.workspace_name);
        try stmt.bindText(4, input.workspace_dir);
        try stmt.bindText(5, input.command);
        try stmt.bindText(6, input.started_at);
        try stmt.bindText(7, input.source);
        try stmt.bindText(8, input.started_at);
        try stmt.bindText(9, input.started_at);
        try stmt.stepDone();
        return self.sqlite.last_insert_rowid(self.handle);
    }

    pub fn finishLatestCommand(self: *Database, input: CommandFinish) !void {
        var stmt = try self.prepare(
            \\UPDATE command_history
            \\SET ended_at = ?, exit_code = ?, updated_at = ?
            \\WHERE id = (
            \\  SELECT id FROM command_history
            \\  WHERE history_id = ? AND ended_at IS NULL
            \\  ORDER BY started_at DESC, id DESC
            \\  LIMIT 1
            \\)
        );
        defer stmt.deinit();
        try stmt.bindText(1, input.ended_at);
        try stmt.bindOptionalInt(2, input.exit_code);
        try stmt.bindText(3, input.ended_at);
        try stmt.bindText(4, input.history_id);
        try stmt.stepDone();
    }

    pub fn listRecentCommands(self: *Database, query: RecentQuery) !CommandList {
        var stmt = try self.prepare(
            \\SELECT id, history_id, workspace_id, workspace_name, workspace_dir,
            \\       command, started_at, ended_at, exit_code, source
            \\FROM command_history
            \\WHERE (?1 IS NULL OR workspace_id = ?1)
            \\  AND (?2 IS NULL OR history_id = ?2)
            \\ORDER BY started_at DESC, id DESC
            \\LIMIT ?3
        );
        defer stmt.deinit();
        try stmt.bindOptionalText(1, query.workspace_id);
        try stmt.bindOptionalText(2, query.history_id);
        try stmt.bindInt64(3, query.limit);

        var items: std.ArrayListUnmanaged(CommandRecord) = .empty;
        errdefer {
            for (items.items) |*item| item.deinit(self.allocator);
            items.deinit(self.allocator);
        }
        while (try stmt.stepRow()) {
            try items.append(self.allocator, try stmt.readCommandRecord());
        }
        return .{ .items = try items.toOwnedSlice(self.allocator) };
    }

    pub fn listSurfaceCommands(self: *Database, history_id: []const u8, limit: u32) !CommandList {
        var stmt = try self.prepare(
            \\SELECT id, history_id, workspace_id, workspace_name, workspace_dir,
            \\       command, started_at, ended_at, exit_code, source
            \\FROM command_history
            \\WHERE history_id = ?
            \\ORDER BY started_at ASC, id ASC
            \\LIMIT ?2
        );
        defer stmt.deinit();
        try stmt.bindText(1, history_id);
        try stmt.bindInt64(2, @max(limit, 1));

        var items: std.ArrayListUnmanaged(CommandRecord) = .empty;
        errdefer {
            for (items.items) |*item| item.deinit(self.allocator);
            items.deinit(self.allocator);
        }
        while (try stmt.stepRow()) {
            try items.append(self.allocator, try stmt.readCommandRecord());
        }
        return .{ .items = try items.toOwnedSlice(self.allocator) };
    }

    pub fn getCommand(self: *Database, command_id: i64) !CommandRecord {
        var stmt = try self.prepare(
            \\SELECT id, history_id, workspace_id, workspace_name, workspace_dir,
            \\       command, started_at, ended_at, exit_code, source
            \\FROM command_history
            \\WHERE id = ?
        );
        defer stmt.deinit();
        try stmt.bindInt64(1, command_id);
        if (!try stmt.stepRow()) return error.NotFound;
        return try stmt.readCommandRecord();
    }

    pub fn searchCommands(self: *Database, query: SearchQuery) !CommandList {
        var stmt = try self.prepare(
            \\SELECT id, history_id, workspace_id, workspace_name, workspace_dir,
            \\       command, started_at, ended_at, exit_code, source
            \\FROM command_history
            \\WHERE (?1 IS NULL OR command LIKE '%' || ?1 || '%')
            \\  AND (?2 IS NULL OR workspace_id = ?2)
            \\  AND (?3 IS NULL OR workspace_name = ?3)
            \\  AND (?4 IS NULL OR workspace_dir = ?4)
            \\  AND (?5 IS NULL OR source = ?5)
            \\  AND (?6 IS NULL OR exit_code = ?6)
            \\  AND (?7 IS NULL OR started_at >= ?7)
            \\  AND (?8 IS NULL OR started_at <= ?8)
            \\ORDER BY started_at DESC, id DESC
            \\LIMIT ?9
        );
        defer stmt.deinit();

        const text = nonEmptyOptional(query.text);
        try stmt.bindOptionalText(1, text);
        try stmt.bindOptionalText(2, nonEmptyOptional(query.workspace_id));
        try stmt.bindOptionalText(3, nonEmptyOptional(query.workspace_name));
        try stmt.bindOptionalText(4, nonEmptyOptional(query.workspace_dir));
        try stmt.bindOptionalText(5, nonEmptyOptional(query.source));
        try stmt.bindOptionalInt(6, query.exit_code);
        try stmt.bindOptionalText(7, nonEmptyOptional(query.started_after));
        try stmt.bindOptionalText(8, nonEmptyOptional(query.started_before));
        try stmt.bindInt64(9, @max(query.limit, 1));

        var items: std.ArrayListUnmanaged(CommandRecord) = .empty;
        errdefer {
            for (items.items) |*item| item.deinit(self.allocator);
            items.deinit(self.allocator);
        }
        while (try stmt.stepRow()) {
            try items.append(self.allocator, try stmt.readCommandRecord());
        }
        return .{ .items = try items.toOwnedSlice(self.allocator) };
    }

    pub fn pruneCommandsOlderThan(self: *Database, cutoff_iso: []const u8) !void {
        var stmt = try self.prepare(
            \\DELETE FROM command_history
            \\WHERE started_at < ?
        );
        defer stmt.deinit();
        try stmt.bindText(1, cutoff_iso);
        try stmt.stepDone();
    }

    pub fn upsertTask(self: *Database, input: TaskUpsert) !void {
        var stmt = try self.prepare(
            \\INSERT INTO workspace_tasks (
            \\  workspace_id, name, command, working_directory, created_at, updated_at
            \\) VALUES (?, ?, ?, ?, ?, ?)
            \\ON CONFLICT(workspace_id, name) DO UPDATE SET
            \\  command = excluded.command,
            \\  working_directory = excluded.working_directory,
            \\  updated_at = excluded.updated_at
        );
        defer stmt.deinit();
        try stmt.bindText(1, input.workspace_id);
        try stmt.bindText(2, input.name);
        try stmt.bindText(3, input.command);
        try stmt.bindOptionalText(4, input.working_directory);
        try stmt.bindText(5, input.timestamp);
        try stmt.bindText(6, input.timestamp);
        try stmt.stepDone();
    }

    pub fn listTasks(self: *Database, workspace_id: []const u8, limit: u32) !TaskList {
        var stmt = try self.prepare(
            \\SELECT id, workspace_id, name, command, working_directory,
            \\       created_at, updated_at, last_run_at, run_count
            \\FROM workspace_tasks
            \\WHERE workspace_id = ?
            \\ORDER BY updated_at DESC, id DESC
            \\LIMIT ?2
        );
        defer stmt.deinit();
        try stmt.bindText(1, workspace_id);
        try stmt.bindInt64(2, @max(limit, 1));

        var items: std.ArrayListUnmanaged(TaskRecord) = .empty;
        errdefer {
            for (items.items) |*item| item.deinit(self.allocator);
            items.deinit(self.allocator);
        }
        while (try stmt.stepRow()) {
            try items.append(self.allocator, try stmt.readTaskRecord());
        }
        return .{ .items = try items.toOwnedSlice(self.allocator) };
    }

    pub fn getTask(self: *Database, workspace_id: []const u8, name: []const u8) !TaskRecord {
        var stmt = try self.prepare(
            \\SELECT id, workspace_id, name, command, working_directory,
            \\       created_at, updated_at, last_run_at, run_count
            \\FROM workspace_tasks
            \\WHERE workspace_id = ? AND name = ?
        );
        defer stmt.deinit();
        try stmt.bindText(1, workspace_id);
        try stmt.bindText(2, name);
        if (!try stmt.stepRow()) return error.NotFound;
        return try stmt.readTaskRecord();
    }

    pub fn markTaskRun(self: *Database, workspace_id: []const u8, name: []const u8, timestamp: []const u8) !void {
        var stmt = try self.prepare(
            \\UPDATE workspace_tasks
            \\SET last_run_at = ?, run_count = run_count + 1, updated_at = ?
            \\WHERE workspace_id = ? AND name = ?
        );
        defer stmt.deinit();
        try stmt.bindText(1, timestamp);
        try stmt.bindText(2, timestamp);
        try stmt.bindText(3, workspace_id);
        try stmt.bindText(4, name);
        try stmt.stepDone();
    }

    pub fn renameTask(
        self: *Database,
        workspace_id: []const u8,
        old_name: []const u8,
        new_name: []const u8,
        timestamp: []const u8,
    ) !void {
        var existing = try self.getTask(workspace_id, old_name);
        existing.deinit(self.allocator);

        var stmt = try self.prepare(
            \\UPDATE workspace_tasks
            \\SET name = ?, updated_at = ?
            \\WHERE workspace_id = ? AND name = ?
        );
        defer stmt.deinit();
        try stmt.bindText(1, new_name);
        try stmt.bindText(2, timestamp);
        try stmt.bindText(3, workspace_id);
        try stmt.bindText(4, old_name);
        try stmt.stepDone();
    }

    pub fn deleteTask(self: *Database, workspace_id: []const u8, name: []const u8) !void {
        var stmt = try self.prepare(
            \\DELETE FROM workspace_tasks
            \\WHERE workspace_id = ? AND name = ?
        );
        defer stmt.deinit();
        try stmt.bindText(1, workspace_id);
        try stmt.bindText(2, name);
        try stmt.stepDone();
    }

    pub fn deleteSurface(self: *Database, history_id: []const u8) !void {
        var delete_commands = try self.prepare(
            \\DELETE FROM command_history
            \\WHERE history_id = ?
        );
        defer delete_commands.deinit();
        try delete_commands.bindText(1, history_id);
        try delete_commands.stepDone();

        var delete_surface = try self.prepare(
            \\DELETE FROM terminal_surfaces
            \\WHERE history_id = ?
        );
        defer delete_surface.deinit();
        try delete_surface.bindText(1, history_id);
        try delete_surface.stepDone();
    }

    pub fn clearWorkspaceHistoryRows(self: *Database, workspace_id: []const u8) !void {
        try self.clearWorkspaceCommandRows(workspace_id);

        var delete_surfaces = try self.prepare(
            \\DELETE FROM terminal_surfaces
            \\WHERE workspace_id = ?
        );
        defer delete_surfaces.deinit();
        try delete_surfaces.bindText(1, workspace_id);
        try delete_surfaces.stepDone();

        var delete_tasks = try self.prepare(
            \\DELETE FROM workspace_tasks
            \\WHERE workspace_id = ?
        );
        defer delete_tasks.deinit();
        try delete_tasks.bindText(1, workspace_id);
        try delete_tasks.stepDone();
    }

    pub fn clearWorkspaceCommandRows(self: *Database, workspace_id: []const u8) !void {
        var delete_commands = try self.prepare(
            \\DELETE FROM command_history
            \\WHERE workspace_id = ?
        );
        defer delete_commands.deinit();
        try delete_commands.bindText(1, workspace_id);
        try delete_commands.stepDone();
    }

    pub fn clearWorkspaceCommandRowsBeforeOrAt(self: *Database, workspace_id: []const u8, started_before: []const u8) !void {
        var delete_commands = try self.prepare(
            \\DELETE FROM command_history
            \\WHERE workspace_id = ?
            \\  AND started_at <= ?
        );
        defer delete_commands.deinit();
        try delete_commands.bindText(1, workspace_id);
        try delete_commands.bindText(2, started_before);
        try delete_commands.stepDone();
    }

    pub fn deleteProject(self: *Database, workspace_id: []const u8, timestamp: []const u8) !void {
        try self.clearWorkspaceHistoryRows(workspace_id);
        var mark_project = try self.prepare(
            \\UPDATE terminal_projects
            \\SET deleted_at = ?, updated_at = ?
            \\WHERE workspace_id = ?
        );
        defer mark_project.deinit();
        try mark_project.bindText(1, timestamp);
        try mark_project.bindText(2, timestamp);
        try mark_project.bindText(3, workspace_id);
        try mark_project.stepDone();
    }

    fn countScalar(self: *Database, sql: [:0]const u8) !u64 {
        var stmt = try self.prepare(sql);
        defer stmt.deinit();
        if (!try stmt.stepRow()) return 0;
        return @intCast(stmt.sqlite.column_int64(stmt.stmt, 0));
    }

    pub fn rowCounts(self: *Database) !RowCounts {
        return .{
            .project_count = try self.countScalar(
                \\SELECT count(*) FROM terminal_projects
                \\WHERE deleted_at IS NULL
            ),
            .surface_count = try self.countScalar(
                \\SELECT count(*) FROM terminal_surfaces
                \\WHERE deleted_at IS NULL
            ),
            .command_count = try self.countScalar(
                \\SELECT count(*) FROM command_history
            ),
            .task_count = try self.countScalar(
                \\SELECT count(*) FROM workspace_tasks
            ),
        };
    }
};

fn nonEmptyOptional(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    if (text.len == 0) return null;
    return text;
}

const Statement = struct {
    allocator: std.mem.Allocator,
    sqlite: *const Sqlite,
    stmt: *sqlite3_stmt,

    fn deinit(self: *Statement) void {
        _ = self.sqlite.finalize(self.stmt);
    }

    fn bindText(self: *Statement, index: c_int, value: []const u8) !void {
        if (self.sqlite.bind_text(self.stmt, index, value.ptr, @intCast(value.len), null) != SQLITE_OK) {
            return error.SqlBindFailed;
        }
    }

    fn bindOptionalText(self: *Statement, index: c_int, value: ?[]const u8) !void {
        if (value) |text| return self.bindText(index, text);
        if (self.sqlite.bind_null(self.stmt, index) != SQLITE_OK) return error.SqlBindFailed;
    }

    fn bindInt64(self: *Statement, index: c_int, value: anytype) !void {
        if (self.sqlite.bind_int64(self.stmt, index, @intCast(value)) != SQLITE_OK) {
            return error.SqlBindFailed;
        }
    }

    fn bindOptionalInt(self: *Statement, index: c_int, value: ?i32) !void {
        if (value) |int_value| return self.bindInt64(index, int_value);
        if (self.sqlite.bind_null(self.stmt, index) != SQLITE_OK) return error.SqlBindFailed;
    }

    fn bindOptionalInt64(self: *Statement, index: c_int, value: ?i64) !void {
        if (value) |int_value| return self.bindInt64(index, int_value);
        if (self.sqlite.bind_null(self.stmt, index) != SQLITE_OK) return error.SqlBindFailed;
    }

    fn stepDone(self: *Statement) !void {
        const rc = self.sqlite.step(self.stmt);
        if (rc != SQLITE_DONE) return error.SqlStepFailed;
    }

    fn stepRow(self: *Statement) !bool {
        const rc = self.sqlite.step(self.stmt);
        return switch (rc) {
            SQLITE_ROW => true,
            SQLITE_DONE => false,
            else => error.SqlStepFailed,
        };
    }

    fn readTextAlloc(self: *Statement, index: c_int) ![]const u8 {
        const raw = self.sqlite.column_text(self.stmt, index) orelse return self.allocator.dupe(u8, "");
        const len: usize = @intCast(self.sqlite.column_bytes(self.stmt, index));
        return self.allocator.dupe(u8, raw[0..len]);
    }

    fn readOptionalTextAlloc(self: *Statement, index: c_int) !?[]const u8 {
        if (self.sqlite.column_type(self.stmt, index) == SQLITE_NULL) return null;
        return try self.readTextAlloc(index);
    }

    fn readOptionalInt(self: *Statement, index: c_int) ?i32 {
        if (self.sqlite.column_type(self.stmt, index) == SQLITE_NULL) return null;
        return @intCast(self.sqlite.column_int64(self.stmt, index));
    }

    fn readOptionalInt64(self: *Statement, index: c_int) ?i64 {
        if (self.sqlite.column_type(self.stmt, index) == SQLITE_NULL) return null;
        return self.sqlite.column_int64(self.stmt, index);
    }

    fn readProjectRecord(self: *Statement) !ProjectRecord {
        return .{
            .workspace_id = try self.readTextAlloc(0),
            .workspace_name = try self.readTextAlloc(1),
            .workspace_dir = try self.readTextAlloc(2),
            .git_remote_url = try self.readOptionalTextAlloc(3),
            .git_branch = try self.readOptionalTextAlloc(4),
            .git_dirty = self.sqlite.column_int64(self.stmt, 5) != 0,
            .updated_at = try self.readTextAlloc(6),
        };
    }

    fn readSurfaceRecord(self: *Statement) !SurfaceRecord {
        return .{
            .history_id = try self.readTextAlloc(0),
            .workspace_id = try self.readTextAlloc(1),
            .workspace_name = try self.readTextAlloc(2),
            .workspace_dir = try self.readTextAlloc(3),
            .working_directory = try self.readTextAlloc(4),
            .env_fingerprint = try self.readOptionalTextAlloc(5),
            .transcript_path = try self.readTextAlloc(6),
            .status = try self.readTextAlloc(7),
            .last_exit_code = self.readOptionalInt(8),
            .process_pid = self.readOptionalInt64(9),
            .process_alive = self.sqlite.column_int64(self.stmt, 10) != 0,
            .detection_method = try self.readOptionalTextAlloc(11),
            .ports_json = try self.readOptionalTextAlloc(12),
            .command_started_at = try self.readOptionalTextAlloc(13),
            .last_command = try self.readOptionalTextAlloc(14),
            .updated_at = try self.readTextAlloc(15),
        };
    }

    fn readResumeCandidate(self: *Statement) !ResumeCandidate {
        return .{
            .history_id = try self.readTextAlloc(0),
            .workspace_id = try self.readTextAlloc(1),
            .workspace_name = try self.readTextAlloc(2),
            .workspace_dir = try self.readTextAlloc(3),
            .working_directory = try self.readTextAlloc(4),
            .status = try self.readTextAlloc(5),
            .process_pid = self.readOptionalInt64(6),
            .detection_method = try self.readOptionalTextAlloc(7),
            .ports_json = try self.readOptionalTextAlloc(8),
            .command_started_at = try self.readOptionalTextAlloc(9),
            .last_command = try self.readOptionalTextAlloc(10),
            .updated_at = try self.readTextAlloc(11),
        };
    }

    fn readCommandRecord(self: *Statement) !CommandRecord {
        return .{
            .id = self.sqlite.column_int64(self.stmt, 0),
            .history_id = try self.readTextAlloc(1),
            .workspace_id = try self.readTextAlloc(2),
            .workspace_name = try self.readTextAlloc(3),
            .workspace_dir = try self.readTextAlloc(4),
            .command = try self.readTextAlloc(5),
            .started_at = try self.readTextAlloc(6),
            .ended_at = try self.readOptionalTextAlloc(7),
            .exit_code = self.readOptionalInt(8),
            .source = try self.readTextAlloc(9),
        };
    }

    fn readTaskRecord(self: *Statement) !TaskRecord {
        return .{
            .id = self.sqlite.column_int64(self.stmt, 0),
            .workspace_id = try self.readTextAlloc(1),
            .name = try self.readTextAlloc(2),
            .command = try self.readTextAlloc(3),
            .working_directory = try self.readOptionalTextAlloc(4),
            .created_at = try self.readTextAlloc(5),
            .updated_at = try self.readTextAlloc(6),
            .last_run_at = try self.readOptionalTextAlloc(7),
            .run_count = @intCast(self.sqlite.column_int64(self.stmt, 8)),
        };
    }
};

test "terminal history db migrates and records command lifecycle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const db_path = try std.fs.path.join(allocator, &.{ base, "history.sqlite3" });
    defer allocator.free(db_path);

    var db = try Database.open(allocator, db_path);
    defer db.deinit();
    try db.migrate();

    try db.upsertProject(.{
        .workspace_id = "workspace-1",
        .workspace_name = "backend",
        .workspace_dir = "/home/user/backend",
        .git_remote_url = "git@github.com:example/backend.git",
        .git_branch = "main",
        .git_dirty = true,
        .timestamp = "2026-05-01T10:00:00Z",
    });

    try db.upsertSurface(.{
        .history_id = "hist-1",
        .workspace_id = "workspace-1",
        .workspace_name = "backend",
        .workspace_dir = "/home/user/backend",
        .working_directory = "/home/user/backend",
        .env_fingerprint = "env-1",
        .transcript_path = "/tmp/hist-1.ansi",
        .status = "active",
        .last_exit_code = null,
        .timestamp = "2026-05-01T10:00:00Z",
    });

    _ = try db.startCommand(.{
        .history_id = "hist-1",
        .workspace_id = "workspace-1",
        .workspace_name = "backend",
        .workspace_dir = "/home/user/backend",
        .command = "npm test",
        .started_at = "2026-05-01T10:00:01Z",
        .source = "osc_7337",
    });
    try db.finishLatestCommand(.{
        .history_id = "hist-1",
        .ended_at = "2026-05-01T10:00:05Z",
        .exit_code = 0,
    });

    try db.ensureProject(.{
        .workspace_id = "workspace-1",
        .workspace_name = "backend",
        .workspace_dir = "/home/user/backend",
        .timestamp = "2026-05-01T10:00:06Z",
    });

    const recent = try db.listRecentCommands(.{ .limit = 10 });
    defer recent.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), recent.items.len);
    try std.testing.expectEqualStrings("npm test", recent.items[0].command);
    try std.testing.expectEqual(@as(?i32, 0), recent.items[0].exit_code);

    var project = try db.getProject("workspace-1");
    defer project.deinit(allocator);
    try std.testing.expectEqualStrings("backend", project.workspace_name);
    try std.testing.expectEqual(true, project.git_dirty);
}

test "surface runtime snapshot fields round trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const db_path = try std.fs.path.join(allocator, &.{ base, "history.sqlite3" });
    defer allocator.free(db_path);

    var db = try Database.open(allocator, db_path);
    defer db.deinit();
    try db.migrate();

    try db.upsertProject(.{
        .workspace_id = "workspace-runtime",
        .workspace_name = "Runtime",
        .workspace_dir = "/repo/runtime",
        .timestamp = "2026-05-09T08:00:00Z",
    });
    try db.upsertSurface(.{
        .history_id = "surface-runtime",
        .workspace_id = "workspace-runtime",
        .workspace_name = "Runtime",
        .workspace_dir = "/repo/runtime",
        .working_directory = "/repo/runtime",
        .transcript_path = "/tmp/runtime.ansi",
        .process_pid = 12345,
        .process_alive = true,
        .detection_method = "shell_hook",
        .ports_json = "[3000,5173]",
        .command_started_at = "2026-05-09T08:00:01Z",
        .last_command = "npm run dev",
        .timestamp = "2026-05-09T08:00:01Z",
    });

    var surface = try db.getSurface("surface-runtime");
    defer surface.deinit(allocator);
    try std.testing.expectEqual(@as(?i64, 12345), surface.process_pid);
    try std.testing.expectEqual(true, surface.process_alive);
    try std.testing.expectEqualStrings("shell_hook", surface.detection_method.?);
    try std.testing.expectEqualStrings("[3000,5173]", surface.ports_json.?);
    try std.testing.expectEqualStrings("2026-05-09T08:00:01Z", surface.command_started_at.?);
    try std.testing.expectEqualStrings("npm run dev", surface.last_command.?);
}

test "resume candidates include only alive surfaces" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const db_path = try std.fs.path.join(allocator, &.{ base, "history.sqlite3" });
    defer allocator.free(db_path);

    var db = try Database.open(allocator, db_path);
    defer db.deinit();
    try db.migrate();

    try db.upsertProject(.{
        .workspace_id = "workspace-live",
        .workspace_name = "Live",
        .workspace_dir = "/repo/live",
        .timestamp = "2026-05-09T08:00:00Z",
    });
    try db.upsertSurface(.{
        .history_id = "surface-live",
        .workspace_id = "workspace-live",
        .workspace_name = "Live",
        .workspace_dir = "/repo/live",
        .working_directory = "/repo/live",
        .transcript_path = "/tmp/live.ansi",
        .process_alive = true,
        .detection_method = "shell_hook",
        .command_started_at = "2026-05-09T08:00:01Z",
        .last_command = "python app.py",
        .timestamp = "2026-05-09T08:00:01Z",
    });
    try db.upsertProject(.{
        .workspace_id = "workspace-dead",
        .workspace_name = "Dead",
        .workspace_dir = "/repo/dead",
        .timestamp = "2026-05-09T08:00:00Z",
    });
    try db.upsertSurface(.{
        .history_id = "surface-dead",
        .workspace_id = "workspace-dead",
        .workspace_name = "Dead",
        .workspace_dir = "/repo/dead",
        .working_directory = "/repo/dead",
        .transcript_path = "/tmp/dead.ansi",
        .process_alive = false,
        .detection_method = "shell_hook",
        .command_started_at = "2026-05-09T08:00:01Z",
        .last_command = "python old.py",
        .timestamp = "2026-05-09T08:00:01Z",
    });

    const candidates = try db.listResumeCandidates(.{ .limit = 10 });
    defer candidates.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), candidates.items.len);
    try std.testing.expectEqualStrings("surface-live", candidates.items[0].history_id);
    try std.testing.expectEqualStrings("Live", candidates.items[0].workspace_name);
    try std.testing.expectEqualStrings("python app.py", candidates.items[0].last_command.?);
}

test "terminal history db creates nested parent directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const db_path = try std.fs.path.join(allocator, &.{ base, "state", "termplex", "terminal-history", "history.sqlite3" });
    defer allocator.free(db_path);

    var db = try Database.open(allocator, db_path);
    defer db.deinit();
    try db.migrate();

    try std.testing.expect(std.fs.path.isAbsolute(db_path));
    const parent = std.fs.path.dirname(db_path) orelse return error.InvalidPath;
    var dir = try std.fs.openDirAbsolute(parent, .{});
    dir.close();
}

test "terminal history db searches commands with filters" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const db_path = try std.fs.path.join(allocator, &.{ base, "history.sqlite3" });
    defer allocator.free(db_path);

    var db = try Database.open(allocator, db_path);
    defer db.deinit();
    try db.migrate();

    try db.upsertProject(.{
        .workspace_id = "workspace-1",
        .workspace_name = "backend",
        .workspace_dir = "/repo/backend",
        .timestamp = "2026-05-04T10:00:00Z",
    });
    try db.upsertProject(.{
        .workspace_id = "workspace-2",
        .workspace_name = "frontend",
        .workspace_dir = "/repo/frontend",
        .timestamp = "2026-05-04T10:00:00Z",
    });

    _ = try db.startCommand(.{
        .history_id = "hist-1",
        .workspace_id = "workspace-1",
        .workspace_name = "backend",
        .workspace_dir = "/repo/backend",
        .command = "npm test -- --watch",
        .started_at = "2026-05-04T10:00:01Z",
        .source = "osc_7337",
    });
    try db.finishLatestCommand(.{
        .history_id = "hist-1",
        .ended_at = "2026-05-04T10:00:02Z",
        .exit_code = 0,
    });

    _ = try db.startCommand(.{
        .history_id = "hist-2",
        .workspace_id = "workspace-1",
        .workspace_name = "backend",
        .workspace_dir = "/repo/backend",
        .command = "zig build test",
        .started_at = "2026-05-04T10:00:03Z",
        .source = "manual",
    });
    try db.finishLatestCommand(.{
        .history_id = "hist-2",
        .ended_at = "2026-05-04T10:00:04Z",
        .exit_code = 1,
    });

    _ = try db.startCommand(.{
        .history_id = "hist-3",
        .workspace_id = "workspace-2",
        .workspace_name = "frontend",
        .workspace_dir = "/repo/frontend",
        .command = "npm test frontend",
        .started_at = "2026-05-04T10:00:05Z",
        .source = "osc_7337",
    });

    const backend_npm = try db.searchCommands(.{
        .text = "npm",
        .workspace_id = "workspace-1",
        .source = "osc_7337",
        .exit_code = 0,
        .limit = 10,
    });
    defer backend_npm.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), backend_npm.items.len);
    try std.testing.expectEqualStrings("npm test -- --watch", backend_npm.items[0].command);
    try std.testing.expectEqualStrings("/repo/backend", backend_npm.items[0].workspace_dir);

    const failed_zig = try db.searchCommands(.{
        .text = "zig",
        .workspace_name = "backend",
        .exit_code = 1,
        .started_after = "2026-05-04T10:00:02Z",
        .started_before = "2026-05-04T10:00:05Z",
        .limit = 10,
    });
    defer failed_zig.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), failed_zig.items.len);
    try std.testing.expectEqualStrings("zig build test", failed_zig.items[0].command);

    const limited = try db.searchCommands(.{
        .text = "test",
        .limit = 2,
    });
    defer limited.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), limited.items.len);
    try std.testing.expectEqualStrings("npm test frontend", limited.items[0].command);
    try std.testing.expectEqualStrings("zig build test", limited.items[1].command);
}

test "terminal history db looks up active surface metadata by history id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const db_path = try std.fs.path.join(allocator, &.{ base, "history.sqlite3" });
    defer allocator.free(db_path);

    var db = try Database.open(allocator, db_path);
    defer db.deinit();
    try db.migrate();

    try db.upsertProject(.{
        .workspace_id = "workspace-surface",
        .workspace_name = "surface",
        .workspace_dir = "/repo/surface",
        .timestamp = "2026-05-04T11:00:00Z",
    });
    try db.upsertSurface(.{
        .history_id = "hist-surface",
        .workspace_id = "workspace-surface",
        .workspace_name = "surface",
        .workspace_dir = "/repo/surface",
        .working_directory = "/repo/surface/subdir",
        .env_fingerprint = "env-surface",
        .transcript_path = "/tmp/hist-surface.ansi",
        .status = "exited",
        .last_exit_code = 7,
        .timestamp = "2026-05-04T11:00:01Z",
    });

    var surface = try db.getSurface("hist-surface");
    defer surface.deinit(allocator);
    try std.testing.expectEqualStrings("hist-surface", surface.history_id);
    try std.testing.expectEqualStrings("workspace-surface", surface.workspace_id);
    try std.testing.expectEqualStrings("surface", surface.workspace_name);
    try std.testing.expectEqualStrings("/repo/surface", surface.workspace_dir);
    try std.testing.expectEqualStrings("/repo/surface/subdir", surface.working_directory);
    try std.testing.expectEqualStrings("/tmp/hist-surface.ansi", surface.transcript_path);
    try std.testing.expectEqualStrings("exited", surface.status);
    try std.testing.expectEqual(@as(?i32, 7), surface.last_exit_code);

    try db.deleteSurface("hist-surface");
    try std.testing.expectError(error.NotFound, db.getSurface("hist-surface"));
}

test "terminal history db lists surface commands oldest first for transcript markers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const db_path = try std.fs.path.join(allocator, &.{ base, "history.sqlite3" });
    defer allocator.free(db_path);

    var db = try Database.open(allocator, db_path);
    defer db.deinit();
    try db.migrate();

    _ = try db.startCommand(.{
        .history_id = "hist-marker",
        .workspace_id = "workspace-marker",
        .workspace_name = "markers",
        .workspace_dir = "/repo/markers",
        .command = "first command",
        .started_at = "2026-05-04T11:00:01Z",
        .source = "osc_7337",
    });
    _ = try db.startCommand(.{
        .history_id = "hist-marker",
        .workspace_id = "workspace-marker",
        .workspace_name = "markers",
        .workspace_dir = "/repo/markers",
        .command = "second command",
        .started_at = "2026-05-04T11:00:02Z",
        .source = "osc_7337",
    });
    _ = try db.startCommand(.{
        .history_id = "other-marker",
        .workspace_id = "workspace-marker",
        .workspace_name = "markers",
        .workspace_dir = "/repo/markers",
        .command = "other command",
        .started_at = "2026-05-04T11:00:03Z",
        .source = "osc_7337",
    });

    const markers = try db.listSurfaceCommands("hist-marker", 10);
    defer markers.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), markers.items.len);
    try std.testing.expectEqualStrings("first command", markers.items[0].command);
    try std.testing.expectEqualStrings("second command", markers.items[1].command);
}

test "terminal history db reports active project surface and command counts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const db_path = try std.fs.path.join(allocator, &.{ base, "history.sqlite3" });
    defer allocator.free(db_path);

    var db = try Database.open(allocator, db_path);
    defer db.deinit();
    try db.migrate();

    try db.upsertProject(.{
        .workspace_id = "workspace-counts",
        .workspace_name = "counts",
        .workspace_dir = "/repo/counts",
        .timestamp = "2026-05-04T11:00:00Z",
    });
    try db.upsertSurface(.{
        .history_id = "hist-counts",
        .workspace_id = "workspace-counts",
        .workspace_name = "counts",
        .workspace_dir = "/repo/counts",
        .working_directory = "/repo/counts",
        .transcript_path = "/tmp/hist-counts.ansi",
        .timestamp = "2026-05-04T11:00:00Z",
    });
    _ = try db.startCommand(.{
        .history_id = "hist-counts",
        .workspace_id = "workspace-counts",
        .workspace_name = "counts",
        .workspace_dir = "/repo/counts",
        .command = "zig build test",
        .started_at = "2026-05-04T11:00:01Z",
        .source = "osc_7337",
    });

    const counts = try db.rowCounts();
    try std.testing.expectEqual(@as(u64, 1), counts.project_count);
    try std.testing.expectEqual(@as(u64, 1), counts.surface_count);
    try std.testing.expectEqual(@as(u64, 1), counts.command_count);
    try std.testing.expectEqual(@as(u64, 0), counts.task_count);
}

test "terminal history db persists workspace task shortcuts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const db_path = try std.fs.path.join(allocator, &.{ base, "history.sqlite3" });
    defer allocator.free(db_path);

    var db = try Database.open(allocator, db_path);
    defer db.deinit();
    try db.migrate();

    try db.upsertProject(.{
        .workspace_id = "workspace-tasks",
        .workspace_name = "tasks",
        .workspace_dir = "/repo/tasks",
        .timestamp = "2026-05-05T10:00:00Z",
    });
    try db.upsertTask(.{
        .workspace_id = "workspace-tasks",
        .name = "test",
        .command = "zig build test",
        .working_directory = "/repo/tasks",
        .timestamp = "2026-05-05T10:00:01Z",
    });
    try db.upsertTask(.{
        .workspace_id = "workspace-tasks",
        .name = "lint",
        .command = "zig fmt --check .",
        .working_directory = null,
        .timestamp = "2026-05-05T10:00:02Z",
    });

    const tasks = try db.listTasks("workspace-tasks", 10);
    defer tasks.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), tasks.items.len);
    try std.testing.expectEqualStrings("lint", tasks.items[0].name);
    try std.testing.expectEqualStrings("test", tasks.items[1].name);

    var task = try db.getTask("workspace-tasks", "test");
    defer task.deinit(allocator);
    try std.testing.expectEqualStrings("zig build test", task.command);
    try std.testing.expectEqualStrings("/repo/tasks", task.working_directory.?);
    try std.testing.expectEqual(@as(u64, 0), task.run_count);
    try std.testing.expectEqual(@as(?[]const u8, null), task.last_run_at);

    try db.markTaskRun("workspace-tasks", "test", "2026-05-05T10:00:03Z");

    var run_task = try db.getTask("workspace-tasks", "test");
    defer run_task.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 1), run_task.run_count);
    try std.testing.expectEqualStrings("2026-05-05T10:00:03Z", run_task.last_run_at.?);

    try db.renameTask("workspace-tasks", "test", "unit tests", "2026-05-05T10:00:04Z");
    try std.testing.expectError(error.NotFound, db.getTask("workspace-tasks", "test"));

    var renamed_task = try db.getTask("workspace-tasks", "unit tests");
    defer renamed_task.deinit(allocator);
    try std.testing.expectEqualStrings("zig build test", renamed_task.command);
    try std.testing.expectEqualStrings("/repo/tasks", renamed_task.working_directory.?);
    try std.testing.expectEqual(@as(u64, 1), renamed_task.run_count);
    try std.testing.expectEqualStrings("2026-05-05T10:00:03Z", renamed_task.last_run_at.?);
    try std.testing.expectEqualStrings("2026-05-05T10:00:04Z", renamed_task.updated_at);

    try db.deleteTask("workspace-tasks", "lint");
    const remaining = try db.listTasks("workspace-tasks", 10);
    defer remaining.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), remaining.items.len);
    try std.testing.expectEqualStrings("unit tests", remaining.items[0].name);

    const counts = try db.rowCounts();
    try std.testing.expectEqual(@as(u64, 1), counts.task_count);
}

test "terminal history db deletes project metadata surfaces and commands" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const db_path = try std.fs.path.join(allocator, &.{ base, "history.sqlite3" });
    defer allocator.free(db_path);

    var db = try Database.open(allocator, db_path);
    defer db.deinit();
    try db.migrate();

    try db.upsertProject(.{
        .workspace_id = "workspace-delete",
        .workspace_name = "delete",
        .workspace_dir = "/repo/delete",
        .timestamp = "2026-05-04T11:00:00Z",
    });
    try db.upsertSurface(.{
        .history_id = "hist-delete",
        .workspace_id = "workspace-delete",
        .workspace_name = "delete",
        .workspace_dir = "/repo/delete",
        .working_directory = "/repo/delete",
        .transcript_path = "/tmp/hist-delete.ansi",
        .timestamp = "2026-05-04T11:00:01Z",
    });
    _ = try db.startCommand(.{
        .history_id = "hist-delete",
        .workspace_id = "workspace-delete",
        .workspace_name = "delete",
        .workspace_dir = "/repo/delete",
        .command = "zig build test",
        .started_at = "2026-05-04T11:00:02Z",
        .source = "osc_7337",
    });
    try db.upsertTask(.{
        .workspace_id = "workspace-delete",
        .name = "ship",
        .command = "zig build",
        .timestamp = "2026-05-04T11:00:02Z",
    });

    try db.deleteProject("workspace-delete", "2026-05-04T11:00:03Z");

    const counts = try db.rowCounts();
    try std.testing.expectEqual(@as(u64, 0), counts.project_count);
    try std.testing.expectEqual(@as(u64, 0), counts.surface_count);
    try std.testing.expectEqual(@as(u64, 0), counts.command_count);
    try std.testing.expectEqual(@as(u64, 0), counts.task_count);
}

test "terminal history db clears workspace history while preserving project metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const db_path = try std.fs.path.join(allocator, &.{ base, "history.sqlite3" });
    defer allocator.free(db_path);

    var db = try Database.open(allocator, db_path);
    defer db.deinit();
    try db.migrate();

    try db.upsertProject(.{
        .workspace_id = "workspace-clear",
        .workspace_name = "clear",
        .workspace_dir = "/repo/clear",
        .timestamp = "2026-05-07T10:00:00Z",
    });
    try db.upsertSurface(.{
        .history_id = "hist-clear",
        .workspace_id = "workspace-clear",
        .workspace_name = "clear",
        .workspace_dir = "/repo/clear",
        .working_directory = "/repo/clear",
        .transcript_path = "/tmp/hist-clear.ansi",
        .timestamp = "2026-05-07T10:00:00Z",
    });
    _ = try db.startCommand(.{
        .history_id = "hist-clear",
        .workspace_id = "workspace-clear",
        .workspace_name = "clear",
        .workspace_dir = "/repo/clear",
        .command = "zig build test",
        .started_at = "2026-05-07T10:00:01Z",
        .source = "osc_7337",
    });
    try db.upsertTask(.{
        .workspace_id = "workspace-clear",
        .name = "test",
        .command = "zig build test",
        .timestamp = "2026-05-07T10:00:02Z",
    });

    try db.clearWorkspaceHistoryRows("workspace-clear");

    const counts = try db.rowCounts();
    try std.testing.expectEqual(@as(u64, 1), counts.project_count);
    try std.testing.expectEqual(@as(u64, 0), counts.surface_count);
    try std.testing.expectEqual(@as(u64, 0), counts.command_count);
    try std.testing.expectEqual(@as(u64, 0), counts.task_count);

    var project = try db.getProject("workspace-clear");
    defer project.deinit(allocator);
    try std.testing.expectEqual(@as(?[]const u8, null), project.git_remote_url);
}

test "terminal history db clears commands at or before cutoff" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    const db_path = try std.fs.path.join(allocator, &.{ base, "history.sqlite3" });
    defer allocator.free(db_path);

    var db = try Database.open(allocator, db_path);
    defer db.deinit();
    try db.migrate();

    try db.ensureProject(.{
        .workspace_id = "workspace-cutoff",
        .workspace_name = "Cutoff",
        .workspace_dir = "/tmp/cutoff",
        .timestamp = "2026-05-07T08:00:00Z",
    });
    try db.upsertSurface(.{
        .history_id = "surface-cutoff",
        .workspace_id = "workspace-cutoff",
        .workspace_name = "Cutoff",
        .workspace_dir = "/tmp/cutoff",
        .working_directory = "/tmp/cutoff",
        .transcript_path = "/tmp/cutoff.ansi",
        .timestamp = "2026-05-07T08:00:00Z",
    });
    _ = try db.startCommand(.{
        .history_id = "surface-cutoff",
        .workspace_id = "workspace-cutoff",
        .workspace_name = "Cutoff",
        .workspace_dir = "/tmp/cutoff",
        .command = "old",
        .started_at = "2026-05-07T08:00:00Z",
        .source = "test",
    });
    _ = try db.startCommand(.{
        .history_id = "surface-cutoff",
        .workspace_id = "workspace-cutoff",
        .workspace_name = "Cutoff",
        .workspace_dir = "/tmp/cutoff",
        .command = "new",
        .started_at = "2026-05-07T08:00:02Z",
        .source = "test",
    });

    try db.clearWorkspaceCommandRowsBeforeOrAt("workspace-cutoff", "2026-05-07T08:00:01Z");

    var list = try db.searchCommands(.{
        .workspace_id = "workspace-cutoff",
        .limit = 10,
    });
    defer list.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("new", list.items[0].command);
}
