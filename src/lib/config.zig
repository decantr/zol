const std = @import("std");
const Io = std.Io;

pub const Config = struct {
    allocator: std.mem.Allocator,
    string_arena: std.heap.ArenaAllocator,

    default_account: ?[]const u8 = null,
    default_account_character: std.StringHashMap([]const u8),
    default_client: ?[]const u8 = null,
    clients: std.StringHashMap(ClientEntry),

    pub const ClientEntry = struct {
        executable: ?[]const u8 = null,
        jar: ?[]const u8 = null,
        java: ?[]const u8 = null,
        config_uri: ?[]const u8 = null,
        runner: ?[]const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator) Config {
        return Config{
            .allocator = allocator,
            .string_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Config) void {
        self.allocator.deinit();
        self.string_arena.deinit();

        if (self.selected_account) |sa| self.allocator.free(sa);
        if (self.default_client) |dc| self.allocator.free(dc);

        var sca_it = self.selected_character_by_account.iterator();
        while (sca_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.selected_character_by_account.deinit();

        var clients_it = self.clients.iterator();
        while (clients_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            const client = entry.value_ptr.*;
            if (client.executable) |e| self.allocator.free(e);
            if (client.jar) |j| self.allocator.free(j);
            if (client.java) |j| self.allocator.free(j);
            if (client.config_uri) |c| self.allocator.free(c);
            if (client.runner) |r| self.allocator.free(r);
        }

        self.clients.deinit();
    }
};

fn getConfigPath(allocator: std.mem.Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (env.get("XDG_CONFIG_HOME")) |xdg| {
        return std.fs.path.join(allocator, &.{ xdg, "zol", "config.json" });
    }
    const home = env.get("HOME") orelse return error.CouldNotGetHomeDir;
    return std.fs.path.join(allocator, &.{ home, ".config", "zol", "config.json" });
}

pub fn loadConfig(allocator: std.mem.Allocator, io: Io, path: []const u8) !Config {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return Config.init(allocator);
        }
        return err;
    };
    defer file.close(io);

    var buf: [1024 * 1024]u8 = undefined;
    const n = file.readPositionalAll(io, &buf, 0) catch return error.ConfigError;
    const bytes = buf[0..n];

    return parseConfig(allocator, bytes);
}

pub fn parseConfig(allocator: std.mem.Allocator, json_bytes: []const u8) !Config {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.ConfigError;

    const obj = root.object;

    const version_val = obj.get("version") orelse return error.ConfigError;
    if (version_val != .integer or version_val.integer != 1) return error.ConfigError;

    var config = Config.init(allocator);
    errdefer config.deinit(allocator);
    config.version = 1;

    if (obj.get("selected_account")) |sa| {
        if (sa != .string) return error.ConfigError;
        config.selected_account = try allocator.dupe(u8, sa.string);
    }

    if (obj.get("selected_character_by_account")) |sca| {
        if (sca != .object) return error.ConfigError;
        var it = sca.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string) return error.ConfigError;
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            const val = try allocator.dupe(u8, entry.value_ptr.string);
            try config.selected_character_by_account.put(key, val);
        }
    }

    if (obj.get("default_client")) |dc| {
        if (dc != .string) return error.ConfigError;
        config.default_client = try allocator.dupe(u8, dc.string);
    }

    if (obj.get("clients")) |clients| {
        if (clients != .object) return error.ConfigError;
        var it = clients.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .object) return error.ConfigError;
            const client_obj = entry.value_ptr.object;
            var client_entry = Config.ClientEntry{};
            if (client_obj.get("executable")) |e| {
                if (e != .string) return error.ConfigError;
                client_entry.executable = try allocator.dupe(u8, e.string);
            }
            if (client_obj.get("jar")) |j| {
                if (j != .string) return error.ConfigError;
                client_entry.jar = try allocator.dupe(u8, j.string);
            }
            if (client_obj.get("java")) |j| {
                if (j != .string) return error.ConfigError;
                client_entry.java = try allocator.dupe(u8, j.string);
            }
            if (client_obj.get("config_uri")) |c| {
                if (c != .string) return error.ConfigError;
                client_entry.config_uri = try allocator.dupe(u8, c.string);
            }
            if (client_obj.get("runner")) |r| {
                if (r != .string) return error.ConfigError;
                client_entry.runner = try allocator.dupe(u8, r.string);
            }
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            try config.clients.put(key, client_entry);
        }
    }

    return config;
}

pub fn saveConfig(allocator: std.mem.Allocator, io: Io, cfg: *const Config, path: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const writer = &aw.writer;

    try writer.print("{{\"version\":{d}", .{cfg.version});
    if (cfg.selected_account) |sa| {
        const sa_json = try std.json.Stringify.valueAlloc(allocator, sa, .{});
        defer allocator.free(sa_json);
        try writer.print(",\"selected_account\":{s}", .{sa_json});
    }
    try writer.writeAll(",\"selected_character_by_account\":{");
    var first = true;
    var it = cfg.selected_character_by_account.iterator();
    while (it.next()) |entry| {
        if (!first) try writer.writeAll(",");
        first = false;
        const key_json = try std.json.Stringify.valueAlloc(allocator, entry.key_ptr.*, .{});
        defer allocator.free(key_json);
        const val_json = try std.json.Stringify.valueAlloc(allocator, entry.value_ptr.*, .{});
        defer allocator.free(val_json);
        try writer.print("{s}:{s}", .{ key_json, val_json });
    }
    try writer.writeAll("}");
    if (cfg.default_client) |dc| {
        const dc_json = try std.json.Stringify.valueAlloc(allocator, dc, .{});
        defer allocator.free(dc_json);
        try writer.print(",\"default_client\":{s}", .{dc_json});
    }
    try writer.writeAll(",\"clients\":{");
    first = true;
    var cit = cfg.clients.iterator();
    while (cit.next()) |entry| {
        if (!first) try writer.writeAll(",");
        first = false;
        const key_json = try std.json.Stringify.valueAlloc(allocator, entry.key_ptr.*, .{});
        defer allocator.free(key_json);
        try writer.print("{s}:{{", .{key_json});
        var cfirst = true;
        if (entry.value_ptr.executable) |e| {
            const e_json = try std.json.Stringify.valueAlloc(allocator, e, .{});
            defer allocator.free(e_json);
            try writer.print("{s}\"executable\":{s}", .{ if (cfirst) "" else ",", e_json });
            cfirst = false;
        }
        if (entry.value_ptr.jar) |j| {
            const j_json = try std.json.Stringify.valueAlloc(allocator, j, .{});
            defer allocator.free(j_json);
            try writer.print("{s}\"jar\":{s}", .{ if (cfirst) "" else ",", j_json });
            cfirst = false;
        }
        if (entry.value_ptr.java) |j| {
            const j_json = try std.json.Stringify.valueAlloc(allocator, j, .{});
            defer allocator.free(j_json);
            try writer.print("{s}\"java\":{s}", .{ if (cfirst) "" else ",", j_json });
            cfirst = false;
        }
        if (entry.value_ptr.config_uri) |c| {
            const c_json = try std.json.Stringify.valueAlloc(allocator, c, .{});
            defer allocator.free(c_json);
            try writer.print("{s}\"config_uri\":{s}", .{ if (cfirst) "" else ",", c_json });
            cfirst = false;
        }
        if (entry.value_ptr.runner) |r| {
            const r_json = try std.json.Stringify.valueAlloc(allocator, r, .{});
            defer allocator.free(r_json);
            try writer.print("{s}\"runner\":{s}", .{ if (cfirst) "" else ",", r_json });
            cfirst = false;
        }
        try writer.writeAll("}");
    }
    try writer.writeAll("}}");

    const json_str = try aw.toOwnedSlice();
    defer allocator.free(json_str);

    const dir = std.fs.path.dirname(path) orelse return error.ConfigError;
    std.Io.Dir.createDirAbsolute(io, dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    try @import("atomic_file.zig").atomicWrite(
        io,
        dir,
        std.fs.path.basename(path),
        json_str,
    );
}
