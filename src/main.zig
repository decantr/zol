const std = @import("std");

const Parser = @import("cli/parser.zig");
const Context = @import("cli/context.zig");

pub const usage: []const u8 =
    \\zol - Zig OSRS Launcher
    \\
    \\USAGE:
    \\    zol <command>
    \\
    \\OPTIONS:
    \\    help                                Show this message
    \\    version                             Show zol version
    \\
    \\    config <command>                    Interact with config
    \\           show                         Print the current config
    \\           set <key> <value>            Set a config value
    \\
    \\    auth <command>                      Interact with auth
    \\           list                         List active sessions
    \\           login                        Create a new session
    \\           logout <index|name|sub>      Forget a saved session (local only)
    \\
    \\    characters <command>                Interact with characters
    \\           list [--account <sel>]       List cached characters
    \\                [--refresh]             (all accounts unless --account;
    \\                                         --refresh re-fetches first)
    \\           refresh [--account <sel>]    Re-fetch characters from Jagex
    \\                                        (all accounts unless --account)
    \\           set-default <index|name|id>  Set a character as default
    \\                       [--account <sel>]
    \\
    \\    launch                              Launch the configured exe with the default character
    \\           [--account <index|name|sub>] Launch with the specified account
    \\           [--character <index|name|id>]Launch with the specified character
    \\           [--refresh]                  Re-fetch characters before launching
    \\           [--wait]                     Wait for the client to exit
    \\
    \\CONFIG:
    \\    Location: ~/.config/zol/config.json
    \\
    \\SESSION-CACHE:
    \\    Location: ~/.local/share/zol/sessions.json
    \\
    \\CHARACTER-CACHE:
    \\    Location: ~/.local/share/zol/characters.json
    \\
;

const Config = @import("lib/config.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    const env = init.environ_map;

    Context.setStdIo(io);

    const config_path = Config.getConfigPath(allocator, env) catch |err| {
        Context.printErr("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer allocator.free(config_path);

    var config = Config.Config.init(allocator);
    defer config.deinit();

    config.load(io, config_path) catch |err| {
        Context.printErr("error loading config: {s}\n", .{@errorName(err)});
    };

    var ctx = Context.Context.init(allocator, io, env, &config, config_path) catch |err| {
        Context.printErr("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer ctx.deinit();

    Parser.parseCommand(&ctx, args) catch |err| {
        Context.printErr("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}
