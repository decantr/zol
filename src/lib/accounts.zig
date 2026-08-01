const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const CREDENTIALS_VERSION: i64 = 1;

/// Maximum accepted credential file size. Untrusted-input safety bound.
pub const MAX_CREDENTIALS_BYTES: usize = 1 * 1024 * 1024;

pub const Account = struct {
    sub: []const u8,
    display_name: []const u8,
    suffix: []const u8,
    session_id: []const u8,

    pub const empty: Account = .{
        .sub = "",
        .display_name = "",
        .suffix = "",
        .session_id = "",
    };
};

/// In-memory store of saved Jagex accounts, backed by a JSON credential file.
/// All string data is owned by `arena`; individual accounts must never be
/// freed independently.
pub const AccountStore = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    accounts: std.ArrayList(Account),

    pub fn init(allocator: Allocator) AccountStore {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .accounts = std.ArrayList(Account).empty,
        };
    }

    pub fn deinit(self: *AccountStore) void {
        self.accounts.deinit(self.allocator);
        self.arena.deinit();
    }

    fn dupe(self: *AccountStore, s: []const u8) ![]const u8 {
        return self.arena.allocator().dupe(u8, s);
    }

    /// Find an account by its provider subject. Returns its index.
    pub fn indexBySub(self: *const AccountStore, sub: []const u8) ?usize {
        for (self.accounts.items, 0..) |a, i| {
            if (std.mem.eql(u8, a.sub, sub)) return i;
        }
        return null;
    }

    /// Find an account by its display name (without suffix).
    pub fn indexByName(self: *const AccountStore, name: []const u8) ?usize {
        for (self.accounts.items, 0..) |a, i| {
            if (std.mem.eql(u8, a.display_name, name)) return i;
        }
        return null;
    }

    /// Resolve a user-provided selector into an account index. The selector may
    /// be a numeric 0-based index, a provider subject, or a display name.
    pub fn resolve(self: *const AccountStore, selector: []const u8) ?usize {
        if (std.fmt.parseInt(usize, selector, 10)) |idx| {
            if (idx < self.accounts.items.len) return idx;
        } else |_| {}
        if (self.indexBySub(selector)) |i| return i;
        if (self.indexByName(selector)) |i| return i;
        return null;
    }

    /// Add a new account or update the session for an existing subject.
    /// Duplicate subjects update in place rather than creating a duplicate.
    pub fn upsert(self: *AccountStore, account: Account) !void {
        if (account.sub.len == 0) return error.InvalidAccount;
        const sub = try self.dupe(account.sub);
        const display_name = try self.dupe(account.display_name);
        const suffix = try self.dupe(account.suffix);
        const session_id = try self.dupe(account.session_id);
        const new_account = Account{
            .sub = sub,
            .display_name = display_name,
            .suffix = suffix,
            .session_id = session_id,
        };
        if (self.indexBySub(account.sub)) |i| {
            self.accounts.items[i] = new_account;
        } else {
            try self.accounts.append(self.allocator, new_account);
        }
    }

    /// Remove the account at `index`. The backing arena memory is not reclaimed
    /// until deinit, which is acceptable for the small credential set.
    pub fn removeIndex(self: *AccountStore, index: usize) void {
        if (index >= self.accounts.items.len) return;
        _ = self.accounts.orderedRemove(index);
    }

    /// Load accounts from the credential file at `path`. A missing file is not
    /// an error; the store is simply empty. Malformed records are rejected.
    pub fn load(self: *AccountStore, io: Io, path: []const u8) !void {
        var file = Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close(io);

        var buf: [4096]u8 = undefined;
        var file_reader = file.reader(io, &buf);
        const content = try file_reader.interface.allocRemaining(self.allocator, .limited(MAX_CREDENTIALS_BYTES));
        defer self.allocator.free(content);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.MalformedCredentials;
        const root = parsed.value.object;

        if (root.get("version")) |v| {
            if (v != .integer or v.integer != CREDENTIALS_VERSION) return error.UnsupportedCredentialsVersion;
        }

        const accounts_val = root.get("accounts") orelse return;
        if (accounts_val != .array) return error.MalformedCredentials;

        for (accounts_val.array.items) |item| {
            if (item != .object) return error.MalformedCredentials;
            const obj = item.object;
            const account = Account{
                .sub = try requireString(obj, "sub"),
                .display_name = try requireString(obj, "display_name"),
                .suffix = optionalString(obj, "suffix"),
                .session_id = try requireString(obj, "session_id"),
            };
            if (self.indexBySub(account.sub) != null) return error.DuplicateSubject;
            try self.upsert(account);
        }
    }

    /// Serialize the store to JSON.
    pub fn toJson(self: *const AccountStore, allocator: Allocator) ![]u8 {
        var aw: Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        const w = &aw.writer;
        try w.print("{{\n  \"version\": {d},\n  \"accounts\": [\n", .{CREDENTIALS_VERSION});
        for (self.accounts.items, 0..) |a, i| {
            try w.writeAll("    {\n");
            try writeJsonField(w, "sub", a.sub, true);
            try writeJsonField(w, "display_name", a.display_name, true);
            try writeJsonField(w, "suffix", a.suffix, true);
            try writeJsonField(w, "session_id", a.session_id, false);
            if (i + 1 < self.accounts.items.len) {
                try w.writeAll("    },\n");
            } else {
                try w.writeAll("    }\n");
            }
        }
        try w.writeAll("  ]\n}\n");
        return aw.toOwnedSlice();
    }

    /// Atomically persist the store to `path` with user-only (0600)
    /// permissions, creating the parent directory (0700) if needed.
    pub fn save(self: *const AccountStore, io: Io, path: []const u8) !void {
        const json = try self.toJson(self.allocator);
        defer self.allocator.free(json);
        try atomicWriteFile(io, self.allocator, path, json);
    }
};

fn requireString(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const v = obj.get(key) orelse return error.MalformedCredentials;
    if (v != .string or v.string.len == 0) return error.MalformedCredentials;
    return v.string;
}

fn optionalString(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    if (obj.get(key)) |v| {
        if (v == .string) return v.string;
    }
    return "";
}

fn writeJsonField(w: *Io.Writer, key: []const u8, value: []const u8, comptime trailing_comma: bool) !void {
    try w.print("      \"{s}\": \"", .{key});
    try writeJsonEscaped(w, value);
    if (trailing_comma) {
        try w.writeAll("\",\n");
    } else {
        try w.writeAll("\"\n");
    }
}

fn writeJsonEscaped(w: *Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
}

/// Write `data` to `path` atomically: a same-directory temp file is written,
/// permissions are set to 0600, and it is renamed into place. The parent
/// directory is created with 0700 permissions if absent.
pub fn atomicWriteFile(io: Io, allocator: Allocator, path: []const u8, data: []const u8) !void {
    const dir_path = std.fs.path.dirname(path) orelse ".";
    _ = try Io.Dir.cwd().createDirPathStatus(io, dir_path, Io.File.Permissions.fromMode(0o700));

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    {
        var file = try Io.Dir.cwd().createFile(io, tmp_path, .{
            .truncate = true,
            .permissions = Io.File.Permissions.fromMode(0o600),
        });
        errdefer Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        defer file.close(io);

        var buf: [4096]u8 = undefined;
        var writer = file.writer(io, &buf);
        try writer.interface.writeAll(data);
        try writer.interface.flush();
        // Ensure permissions are 0600 even if umask altered creation.
        Io.Dir.cwd().setFilePermissions(io, tmp_path, Io.File.Permissions.fromMode(0o600), .{}) catch {};
    }

    Io.Dir.cwd().rename(tmp_path, Io.Dir.cwd(), path, io) catch |err| {
        Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        return err;
    };
}

/// Discover the credential file path following the XDG data dir convention.
pub fn getCredentialsPath(allocator: Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (env.get("XDG_DATA_HOME")) |xdg| {
        return std.fs.path.join(allocator, &.{ xdg, "zol", "sessions.json" });
    }
    const home = env.get("HOME") orelse return error.CouldNotGetHomeDir;
    return std.fs.path.join(allocator, &.{ home, ".local", "share", "zol", "sessions.json" });
}

test "upsert and resolve" {
    var store = AccountStore.init(std.testing.allocator);
    defer store.deinit();

    try store.upsert(.{ .sub = "sub-1", .display_name = "Alice", .suffix = "1111", .session_id = "sess-a" });
    try store.upsert(.{ .sub = "sub-2", .display_name = "Bob", .suffix = "2222", .session_id = "sess-b" });

    try std.testing.expectEqual(@as(usize, 2), store.accounts.items.len);
    try std.testing.expectEqual(@as(?usize, 0), store.resolve("0"));
    try std.testing.expectEqual(@as(?usize, 1), store.resolve("sub-2"));
    try std.testing.expectEqual(@as(?usize, 0), store.resolve("Alice"));
    try std.testing.expectEqual(@as(?usize, null), store.resolve("nope"));
}

test "upsert dedupes by subject" {
    var store = AccountStore.init(std.testing.allocator);
    defer store.deinit();

    try store.upsert(.{ .sub = "sub-1", .display_name = "Alice", .suffix = "1111", .session_id = "old" });
    try store.upsert(.{ .sub = "sub-1", .display_name = "Alice", .suffix = "1111", .session_id = "new" });

    try std.testing.expectEqual(@as(usize, 1), store.accounts.items.len);
    try std.testing.expectEqualStrings("new", store.accounts.items[0].session_id);
}

test "remove index" {
    var store = AccountStore.init(std.testing.allocator);
    defer store.deinit();
    try store.upsert(.{ .sub = "a", .display_name = "A", .suffix = "1", .session_id = "sa" });
    try store.upsert(.{ .sub = "b", .display_name = "B", .suffix = "2", .session_id = "sb" });
    store.removeIndex(0);
    try std.testing.expectEqual(@as(usize, 1), store.accounts.items.len);
    try std.testing.expectEqualStrings("b", store.accounts.items[0].sub);
}

test "to json round trips through loader" {
    var store = AccountStore.init(std.testing.allocator);
    defer store.deinit();
    try store.upsert(.{ .sub = "sub-1", .display_name = "Ali\"ce", .suffix = "1111", .session_id = "sess-a" });

    const json = try store.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const accounts = parsed.value.object.get("accounts").?;
    try std.testing.expectEqual(@as(usize, 1), accounts.array.items.len);
    try std.testing.expectEqualStrings("Ali\"ce", accounts.array.items[0].object.get("display_name").?.string);
}

test "upsert rejects empty sub" {
    var store = AccountStore.init(std.testing.allocator);
    defer store.deinit();
    try std.testing.expectError(error.InvalidAccount, store.upsert(Account.empty));
}

test "atomic write and load round trip" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // tmpDir lives at .zig-cache/tmp/<sub_path> relative to cwd; construct a
    // cwd-relative path so the cwd-based atomic writer can operate on it.
    const path = try std.fs.path.join(std.testing.allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "sub", "sessions.json",
    });
    defer std.testing.allocator.free(path);

    var store = AccountStore.init(std.testing.allocator);
    defer store.deinit();
    try store.upsert(.{ .sub = "sub-1", .display_name = "Alice", .suffix = "1111", .session_id = "sess-a" });
    try store.save(io, path);

    var loaded = AccountStore.init(std.testing.allocator);
    defer loaded.deinit();
    try loaded.load(io, path);
    try std.testing.expectEqual(@as(usize, 1), loaded.accounts.items.len);
    try std.testing.expectEqualStrings("Alice", loaded.accounts.items[0].display_name);
    try std.testing.expectEqualStrings("sess-a", loaded.accounts.items[0].session_id);
}
