const std = @import("std");
const Io = std.Io;

pub const Config = struct {
    allocator: std.mem.Allocator,
    string_arena: std.heap.ArenaAllocator,

    default_account: ?[]const u8 = null,
    default_account_character: std.StringHashMap([]const u8),

    arguments: ?[]const u8 = null,
    executable: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) Config {
        return Config{
            .allocator = allocator,
            .string_arena = std.heap.ArenaAllocator.init(allocator),
            .default_account_character = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Config) void {
        self.default_account_character.deinit();
        self.string_arena.deinit();
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

    pub fn load(self: *Config, io: Io, config_path: []const u8) !void {
        var file = Io.Dir.cwd().openFile(io, config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close(io);

        var buf: [4096]u8 = undefined;
        var file_reader = file.reader(io, &buf);
        const content = try file_reader.interface.allocRemaining(self.allocator, .unlimited);
        defer self.allocator.free(content);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        defer parsed.deinit();

        const root = parsed.value;

        if (root == .object) {
            if (root.object.get("default_account")) |val| {
                if (val == .string) {
                    self.default_account = try self.allocator.dupe(u8, val.string);
                }
            }

            if (root.object.get("default_account_character")) |val| {
                if (val == .object) {
                    var iter = val.object.iterator();
                    while (iter.next()) |entry| {
                        if (entry.value_ptr.* == .string) {
                            const key = try self.allocator.dupe(u8, entry.key_ptr.*);
                            const value = try self.allocator.dupe(u8, entry.value_ptr.string);
                            try self.default_account_character.put(key, value);
                        }
                    }
                }
            }

            if (root.object.get("arguments")) |val| {
                if (val == .string) {
                    self.arguments = try self.allocator.dupe(u8, val.string);
                }
            }

            if (root.object.get("executable")) |val| {
                if (val == .string) {
                    self.executable = try self.allocator.dupe(u8, val.string);
                }
            }
        }
    }
};

pub fn getConfigPath(allocator: std.mem.Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (env.get("XDG_CONFIG_HOME")) |xdg| {
        return std.fs.path.join(allocator, &.{ xdg, "zol", "config.json" });
    }

    const home = env.get("HOME") orelse return error.CouldNotGetHomeDir;
    return std.fs.path.join(allocator, &.{ home, ".config", "zol", "config.json" });
}
