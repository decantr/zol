const std = @import("std");

const Parser = @import("cli/parser.zig");

pub const usage: []const u8 =
    \\zol - Zig OSRS Launcher
    \\
    \\USAGE:
    \\    zol <command>
    \\
    \\OPTIONS:
    \\    help               Show this message
    \\    version            Show zol version
    \\
    \\    config <command>   Interact with config
    \\           show        Print the current config
    \\
    \\    auth <command>     Interact with auth
    \\           list        List active sessions
    \\
    \\CONFIG:
    \\    Location: ~/.config/zol/config.json
    \\
;

const Config = @import("lib/config.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    const env = init.environ_map;

    const config_path = Config.getConfigPath(allocator, env) catch |err| {
        std.debug.print("error: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    defer allocator.free(config_path);

    var config = Config.Config.init(allocator);
    defer config.deinit();

    config.load(init.io, config_path) catch |err| {
        std.debug.print("error loading config: {s}\n", .{@errorName(err)});
    };

    Parser.parseCommand(&config, args) catch |err| {
        std.debug.print("error: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}
