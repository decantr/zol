const std = @import("std");
const Io = std.Io;
const accounts = @import("accounts.zig");

pub const CONFIG_VERSION: i64 = 1;

/// Maximum accepted config file size. Untrusted-input safety bound.
pub const MAX_CONFIG_BYTES: usize = 1 * 1024 * 1024;

pub const Config = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    default_account: ?[]const u8 = null,
    default_account_character: std.StringHashMap([]const u8),

    arguments: ?[]const u8 = null,
    executable: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) Config {
        return Config{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .default_account_character = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Config) void {
        self.default_account_character.deinit();
        self.arena.deinit();
    }

    fn dupe(self: *Config, s: []const u8) ![]const u8 {
        return self.arena.allocator().dupe(u8, s);
    }

    pub fn print(self: *Config) void {
        std.debug.print("Config:\n", .{});
        std.debug.print("  default_account: {?s}\n", .{self.default_account});

        std.debug.print("  default_account_character:\n", .{});
        var iter = self.default_account_character.iterator();
        while (iter.next()) |entry| {
            std.debug.print("    {s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        std.debug.print("  arguments: {?s}\n", .{self.arguments});
        std.debug.print("  executable: {?s}\n", .{self.executable});
    }

    /// Set the default account subject/name.
    pub fn setDefaultAccount(self: *Config, value: []const u8) !void {
        self.default_account = try self.dupe(value);
    }

    /// Set the default character for a given account key.
    pub fn setDefaultCharacter(self: *Config, account_key: []const u8, character: []const u8) !void {
        const key = try self.dupe(account_key);
        const val = try self.dupe(character);
        try self.default_account_character.put(key, val);
    }

    pub fn setExecutable(self: *Config, value: []const u8) !void {
        self.executable = try self.dupe(value);
    }

    pub fn setArguments(self: *Config, value: []const u8) !void {
        self.arguments = try self.dupe(value);
    }

    /// Apply a `config set <key> <value>` operation. Returns error.UnknownKey
    /// for unrecognized keys.
    pub fn set(self: *Config, key: []const u8, value: []const u8) !void {
        if (std.mem.eql(u8, key, "default_account")) {
            try self.setDefaultAccount(value);
        } else if (std.mem.eql(u8, key, "executable")) {
            try self.setExecutable(value);
        } else if (std.mem.eql(u8, key, "arguments")) {
            try self.setArguments(value);
        } else {
            return error.UnknownKey;
        }
    }

    pub fn load(self: *Config, io: Io, config_path: []const u8) !void {
        var file = Io.Dir.cwd().openFile(io, config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close(io);

        var buf: [4096]u8 = undefined;
        var file_reader = file.reader(io, &buf);
        const content = try file_reader.interface.allocRemaining(self.allocator, .limited(MAX_CONFIG_BYTES));
        defer self.allocator.free(content);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        defer parsed.deinit();

        const root = parsed.value;

        if (root == .object) {
            if (root.object.get("default_account")) |val| {
                if (val == .string) {
                    self.default_account = try self.dupe(val.string);
                }
            }

            if (root.object.get("default_account_character")) |val| {
                if (val == .object) {
                    var iter = val.object.iterator();
                    while (iter.next()) |entry| {
                        if (entry.value_ptr.* == .string) {
                            const key = try self.dupe(entry.key_ptr.*);
                            const value = try self.dupe(entry.value_ptr.string);
                            try self.default_account_character.put(key, value);
                        }
                    }
                }
            }

            if (root.object.get("arguments")) |val| {
                if (val == .string) {
                    self.arguments = try self.dupe(val.string);
                }
            }

            if (root.object.get("executable")) |val| {
                if (val == .string) {
                    self.executable = try self.dupe(val.string);
                }
            }
        }
    }

    pub fn toJson(self: *Config, allocator: std.mem.Allocator) ![]u8 {
        var aw: Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        const w = &aw.writer;

        try w.print("{{\n  \"version\": {d}", .{CONFIG_VERSION});

        if (self.default_account) |da| {
            try w.writeAll(",\n  \"default_account\": \"");
            try writeJsonEscaped(w, da);
            try w.writeAll("\"");
        }

        if (self.default_account_character.count() > 0) {
            try w.writeAll(",\n  \"default_account_character\": {");
            var iter = self.default_account_character.iterator();
            var first = true;
            while (iter.next()) |entry| {
                if (!first) try w.writeAll(",");
                first = false;
                try w.writeAll("\n    \"");
                try writeJsonEscaped(w, entry.key_ptr.*);
                try w.writeAll("\": \"");
                try writeJsonEscaped(w, entry.value_ptr.*);
                try w.writeAll("\"");
            }
            try w.writeAll("\n  }");
        }

        if (self.executable) |exe| {
            try w.writeAll(",\n  \"executable\": \"");
            try writeJsonEscaped(w, exe);
            try w.writeAll("\"");
        }

        if (self.arguments) |args| {
            try w.writeAll(",\n  \"arguments\": \"");
            try writeJsonEscaped(w, args);
            try w.writeAll("\"");
        }

        try w.writeAll("\n}\n");
        return aw.toOwnedSlice();
    }

    /// Atomically persist the config to `config_path`.
    pub fn save(self: *Config, io: Io, config_path: []const u8) !void {
        const json = try self.toJson(self.allocator);
        defer self.allocator.free(json);
        try accounts.atomicWriteFile(io, self.allocator, config_path, json);
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

pub fn getConfigPath(allocator: std.mem.Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (env.get("XDG_CONFIG_HOME")) |xdg| {
        return std.fs.path.join(allocator, &.{ xdg, "zol", "config.json" });
    }

    const home = env.get("HOME") orelse return error.CouldNotGetHomeDir;
    return std.fs.path.join(allocator, &.{ home, ".config", "zol", "config.json" });
}

test "config set known keys" {
    var config = Config.init(std.testing.allocator);
    defer config.deinit();

    try config.set("default_account", "Alice");
    try config.set("executable", "/usr/bin/runelite");
    try config.set("arguments", "--debug");

    try std.testing.expectEqualStrings("Alice", config.default_account.?);
    try std.testing.expectEqualStrings("/usr/bin/runelite", config.executable.?);
    try std.testing.expectEqualStrings("--debug", config.arguments.?);
}

test "config set unknown key" {
    var config = Config.init(std.testing.allocator);
    defer config.deinit();
    try std.testing.expectError(error.UnknownKey, config.set("bogus", "x"));
}

test "config default character" {
    var config = Config.init(std.testing.allocator);
    defer config.deinit();
    try config.setDefaultCharacter("Alice", "MainChar");
    try std.testing.expectEqualStrings("MainChar", config.default_account_character.get("Alice").?);
}

test "config json round trip" {
    var config = Config.init(std.testing.allocator);
    defer config.deinit();
    try config.set("default_account", "Alice");
    try config.setDefaultCharacter("Alice", "MainChar");
    try config.set("executable", "/usr/bin/rl");

    const json = try config.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expectEqualStrings("Alice", parsed.value.object.get("default_account").?.string);
    try std.testing.expectEqualStrings(
        "MainChar",
        parsed.value.object.get("default_account_character").?.object.get("Alice").?.string,
    );
}
