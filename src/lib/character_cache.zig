const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const accounts = @import("accounts.zig");
const oauth = @import("auth/oauth.zig");

pub const CACHE_VERSION: i64 = 1;

/// Maximum accepted cache file size. Untrusted-input safety bound.
pub const MAX_CACHE_BYTES: usize = 1 * 1024 * 1024;

pub const Character = oauth.Character;

/// The cached character list for one account, plus when it was fetched.
pub const Entry = struct {
    characters: []const Character,
    /// Unix seconds of the fetch that produced this entry. 0 when unknown.
    fetched_at: i64,
};

/// Local, non-sensitive cache of the character list per account, backed by a
/// JSON file. Characters are public game data, so unlike credentials this file
/// carries no secrets; it exists so `characters list` and `launch` do not need
/// a network round trip on every invocation.
///
/// All string and slice data is owned by `arena`; entries must never be freed
/// independently. Replacing an entry leaks its old strings into the arena,
/// which is acceptable for the small, short-lived character set.
pub const CharacterCache = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    /// Keyed by account subject; keys are arena-owned.
    entries: std.StringHashMap(Entry),

    pub fn init(allocator: Allocator) CharacterCache {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .entries = std.StringHashMap(Entry).init(allocator),
        };
    }

    pub fn deinit(self: *CharacterCache) void {
        self.entries.deinit();
        self.arena.deinit();
    }

    /// The cached entry for an account subject, if any.
    pub fn get(self: *const CharacterCache, sub: []const u8) ?Entry {
        return self.entries.get(sub);
    }

    /// Replace the cached characters for an account subject.
    pub fn put(
        self: *CharacterCache,
        sub: []const u8,
        characters: []const Character,
        fetched_at: i64,
    ) !void {
        if (sub.len == 0) return error.InvalidAccount;
        const a = self.arena.allocator();

        const items = try a.alloc(Character, characters.len);
        for (characters, 0..) |c, i| {
            items[i] = .{
                .account_id = try a.dupe(u8, c.account_id),
                .display_name = try a.dupe(u8, c.display_name),
            };
        }

        const key = try a.dupe(u8, sub);
        const gop = try self.entries.getOrPut(key);
        if (!gop.found_existing) gop.key_ptr.* = key;
        gop.value_ptr.* = .{ .characters = items, .fetched_at = fetched_at };
    }

    /// Forget the cached characters for an account subject, e.g. on logout.
    pub fn remove(self: *CharacterCache, sub: []const u8) void {
        _ = self.entries.remove(sub);
    }

    /// Drop every cached entry. The arena is reset so stale strings are freed.
    pub fn clear(self: *CharacterCache) void {
        self.entries.clearRetainingCapacity();
        _ = self.arena.reset(.free_all);
    }

    /// Load the cache from `path`. A missing file is not an error; the cache is
    /// simply empty. Malformed records are rejected so a corrupt cache can be
    /// discarded and rebuilt rather than silently half-applied.
    pub fn load(self: *CharacterCache, io: Io, path: []const u8) !void {
        var file = Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close(io);

        var buf: [4096]u8 = undefined;
        var file_reader = file.reader(io, &buf);
        const content = try file_reader.interface.allocRemaining(self.allocator, .limited(MAX_CACHE_BYTES));
        defer self.allocator.free(content);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.MalformedCache;
        const root = parsed.value.object;

        if (root.get("version")) |v| {
            if (v != .integer or v.integer != CACHE_VERSION) return error.UnsupportedCacheVersion;
        }

        const accounts_val = root.get("accounts") orelse return;
        if (accounts_val != .object) return error.MalformedCache;

        var it = accounts_val.object.iterator();
        while (it.next()) |kv| {
            const sub = kv.key_ptr.*;
            if (sub.len == 0) return error.MalformedCache;
            if (kv.value_ptr.* != .object) return error.MalformedCache;
            const entry_obj = kv.value_ptr.object;

            const fetched_at: i64 = blk: {
                const v = entry_obj.get("fetched_at") orelse break :blk 0;
                if (v != .integer) break :blk 0;
                break :blk v.integer;
            };

            const chars_val = entry_obj.get("characters") orelse return error.MalformedCache;
            if (chars_val != .array) return error.MalformedCache;

            var list = std.ArrayList(Character).empty;
            defer list.deinit(self.allocator);
            for (chars_val.array.items) |item| {
                if (item != .object) return error.MalformedCache;
                const account_id = item.object.get("account_id") orelse return error.MalformedCache;
                if (account_id != .string or account_id.string.len == 0) return error.MalformedCache;

                // Mirrors the accounts endpoint: characters with no display
                // name fall back to their id rather than failing the load.
                const display_name: []const u8 = blk: {
                    const dn = item.object.get("display_name") orelse break :blk account_id.string;
                    if (dn != .string or dn.string.len == 0) break :blk account_id.string;
                    break :blk dn.string;
                };

                try list.append(self.allocator, .{
                    .account_id = account_id.string,
                    .display_name = display_name,
                });
            }

            try self.put(sub, list.items, fetched_at);
        }
    }

    /// Serialize the cache to JSON.
    pub fn toJson(self: *const CharacterCache, allocator: Allocator) ![]u8 {
        var aw: Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        const w = &aw.writer;

        try w.print("{{\n  \"version\": {d},\n  \"accounts\": {{", .{CACHE_VERSION});

        var it = self.entries.iterator();
        var first = true;
        while (it.next()) |kv| {
            if (!first) try w.writeAll(",");
            first = false;
            try w.writeAll("\n    \"");
            try writeJsonEscaped(w, kv.key_ptr.*);
            try w.writeAll("\": {\n      \"fetched_at\": ");
            try w.print("{d}", .{kv.value_ptr.fetched_at});
            try w.writeAll(",\n      \"characters\": [");
            for (kv.value_ptr.characters, 0..) |c, i| {
                if (i != 0) try w.writeAll(",");
                try w.writeAll("\n        {\"account_id\": \"");
                try writeJsonEscaped(w, c.account_id);
                try w.writeAll("\", \"display_name\": \"");
                try writeJsonEscaped(w, c.display_name);
                try w.writeAll("\"}");
            }
            if (kv.value_ptr.characters.len > 0) try w.writeAll("\n      ");
            try w.writeAll("]\n    }");
        }

        if (!first) try w.writeAll("\n  ");
        try w.writeAll("}\n}\n");
        return aw.toOwnedSlice();
    }

    /// Atomically persist the cache to `path`.
    pub fn save(self: *const CharacterCache, io: Io, path: []const u8) !void {
        const json = try self.toJson(self.allocator);
        defer self.allocator.free(json);
        try accounts.atomicWriteFile(io, self.allocator, path, json);
    }
};

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

/// Discover the character cache path, alongside the credential file.
pub fn getCachePath(allocator: Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (env.get("XDG_DATA_HOME")) |xdg| {
        return std.fs.path.join(allocator, &.{ xdg, "zol", "characters.json" });
    }
    const home = env.get("HOME") orelse return error.CouldNotGetHomeDir;
    return std.fs.path.join(allocator, &.{ home, ".local", "share", "zol", "characters.json" });
}

test "put and get" {
    var cache = CharacterCache.init(std.testing.allocator);
    defer cache.deinit();

    try cache.put("sub-1", &.{
        .{ .account_id = "char-a", .display_name = "Alpha" },
        .{ .account_id = "char-b", .display_name = "Beta" },
    }, 1700000000);

    const entry = cache.get("sub-1").?;
    try std.testing.expectEqual(@as(usize, 2), entry.characters.len);
    try std.testing.expectEqualStrings("Alpha", entry.characters[0].display_name);
    try std.testing.expectEqual(@as(i64, 1700000000), entry.fetched_at);
    try std.testing.expectEqual(@as(?Entry, null), cache.get("sub-2"));
}

test "put replaces an existing entry" {
    var cache = CharacterCache.init(std.testing.allocator);
    defer cache.deinit();

    try cache.put("sub-1", &.{.{ .account_id = "char-a", .display_name = "Alpha" }}, 1);
    try cache.put("sub-1", &.{
        .{ .account_id = "char-a", .display_name = "Alpha" },
        .{ .account_id = "char-c", .display_name = "Gamma" },
    }, 2);

    try std.testing.expectEqual(@as(u32, 1), cache.entries.count());
    const entry = cache.get("sub-1").?;
    try std.testing.expectEqual(@as(usize, 2), entry.characters.len);
    try std.testing.expectEqual(@as(i64, 2), entry.fetched_at);
}

test "put rejects empty subject" {
    var cache = CharacterCache.init(std.testing.allocator);
    defer cache.deinit();
    try std.testing.expectError(error.InvalidAccount, cache.put("", &.{}, 0));
}

test "remove and clear" {
    var cache = CharacterCache.init(std.testing.allocator);
    defer cache.deinit();

    try cache.put("sub-1", &.{.{ .account_id = "char-a", .display_name = "Alpha" }}, 0);
    try cache.put("sub-2", &.{.{ .account_id = "char-b", .display_name = "Beta" }}, 0);

    cache.remove("sub-1");
    try std.testing.expectEqual(@as(?Entry, null), cache.get("sub-1"));
    try std.testing.expect(cache.get("sub-2") != null);

    cache.clear();
    try std.testing.expectEqual(@as(u32, 0), cache.entries.count());
}

test "json round trips through loader" {
    var cache = CharacterCache.init(std.testing.allocator);
    defer cache.deinit();
    try cache.put("sub-1", &.{
        .{ .account_id = "char-a", .display_name = "Al\"pha" },
        .{ .account_id = "char-b", .display_name = "Beta" },
    }, 42);
    try cache.put("sub-2", &.{}, 7);

    const json = try cache.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const accounts_obj = parsed.value.object.get("accounts").?.object;
    try std.testing.expectEqual(@as(usize, 2), accounts_obj.count());
    const chars = accounts_obj.get("sub-1").?.object.get("characters").?.array;
    try std.testing.expectEqualStrings("Al\"pha", chars.items[0].object.get("display_name").?.string);
    try std.testing.expectEqual(@as(usize, 0), accounts_obj.get("sub-2").?.object.get("characters").?.array.items.len);
}

test "load rejects a malformed cache" {
    var cache = CharacterCache.init(std.testing.allocator);
    defer cache.deinit();

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(std.testing.allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "characters.json",
    });
    defer std.testing.allocator.free(path);

    try accounts.atomicWriteFile(io, std.testing.allocator, path,
        \\{"version": 1, "accounts": {"sub-1": {"characters": [{"display_name": "Alpha"}]}}}
    );
    try std.testing.expectError(error.MalformedCache, cache.load(io, path));
}

test "atomic write and load round trip" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(std.testing.allocator, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "sub", "characters.json",
    });
    defer std.testing.allocator.free(path);

    var cache = CharacterCache.init(std.testing.allocator);
    defer cache.deinit();
    try cache.put("sub-1", &.{
        .{ .account_id = "char-a", .display_name = "Alpha" },
        .{ .account_id = "char-b", .display_name = "Beta" },
    }, 99);
    try cache.save(io, path);

    var loaded = CharacterCache.init(std.testing.allocator);
    defer loaded.deinit();
    try loaded.load(io, path);

    const entry = loaded.get("sub-1").?;
    try std.testing.expectEqual(@as(i64, 99), entry.fetched_at);
    try std.testing.expectEqual(@as(usize, 2), entry.characters.len);
    try std.testing.expectEqualStrings("char-b", entry.characters[1].account_id);
    try std.testing.expectEqualStrings("Beta", entry.characters[1].display_name);
}

test "load tolerates a missing file" {
    var cache = CharacterCache.init(std.testing.allocator);
    defer cache.deinit();
    try cache.load(std.testing.io, "does/not/exist/characters.json");
    try std.testing.expectEqual(@as(u32, 0), cache.entries.count());
}
