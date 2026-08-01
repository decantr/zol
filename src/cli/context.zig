const std = @import("std");
const Io = std.Io;

const Config = @import("../lib/config.zig");
const accounts = @import("../lib/accounts.zig");
const character_cache = @import("../lib/character_cache.zig");

/// Shared state and dependencies passed to every CLI subcommand. Keeps I/O and
/// path discovery in one place so command handlers stay focused on behavior.
pub const Context = struct {
    allocator: std.mem.Allocator,
    io: Io,
    env: *std.process.Environ.Map,

    config: *Config.Config,
    config_path: []const u8,

    store: accounts.AccountStore,
    credentials_path: []const u8,

    characters: character_cache.CharacterCache,
    character_cache_path: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        io: Io,
        env: *std.process.Environ.Map,
        config: *Config.Config,
        config_path: []const u8,
    ) !Context {
        const credentials_path = try accounts.getCredentialsPath(allocator, env);
        errdefer allocator.free(credentials_path);
        var store = accounts.AccountStore.init(allocator);
        errdefer store.deinit();
        store.load(io, credentials_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => {
                printErr("warning: could not load credentials: {s}\n", .{@errorName(err)});
            },
        };
        const cache_path = try character_cache.getCachePath(allocator, env);
        var characters = character_cache.CharacterCache.init(allocator);
        characters.load(io, cache_path) catch |err| {
            // A damaged cache is never fatal: it holds only public character
            // data and is rebuilt on the next refresh.
            printErr("warning: discarding unreadable character cache: {s}\n", .{@errorName(err)});
            characters.clear();
        };

        return .{
            .allocator = allocator,
            .io = io,
            .env = env,
            .config = config,
            .config_path = config_path,
            .store = store,
            .credentials_path = credentials_path,
            .characters = characters,
            .character_cache_path = cache_path,
        };
    }

    pub fn deinit(self: *Context) void {
        self.store.deinit();
        self.allocator.free(self.credentials_path);
        self.characters.deinit();
        self.allocator.free(self.character_cache_path);
    }

    pub fn saveCredentials(self: *Context) !void {
        try self.store.save(self.io, self.credentials_path);
    }

    pub fn saveCharacters(self: *Context) !void {
        try self.characters.save(self.io, self.character_cache_path);
    }

    pub fn saveConfig(self: *Context) !void {
        try self.config.save(self.io, self.config_path);
    }
};

/// Print to stdout (normal program output).
pub fn print(comptime fmt: []const u8, args: anytype) void {
    const file = Io.File.stdout();
    var buf: [2048]u8 = undefined;
    var w = file.writer(getStdIo(), &buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}

/// Print to stderr (diagnostics).
pub fn printErr(comptime fmt: []const u8, args: anytype) void {
    const file = Io.File.stderr();
    var buf: [2048]u8 = undefined;
    var w = file.writer(getStdIo(), &buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}

// The convenience print helpers above need an Io; they are only used with the
// process default Io, captured here at first use. Set by main before use.
var g_io: ?Io = null;

pub fn setStdIo(io: Io) void {
    g_io = io;
}

fn getStdIo() Io {
    return g_io.?;
}

/// Read a single trimmed line from stdin. Returns an allocated slice the caller
/// owns. Used to capture pasted callback URLs and interactive selections.
pub fn readLine(allocator: std.mem.Allocator, io: Io) ![]u8 {
    const file = Io.File.stdin();
    var buf: [8192]u8 = undefined;
    var reader = file.reader(io, &buf);
    const line = reader.interface.takeDelimiterExclusive('\n') catch |err| switch (err) {
        error.EndOfStream => return error.NoInput,
        else => return err,
    };
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    return allocator.dupe(u8, trimmed);
}
