const std = @import("std");
const build_options = @import("build_options");

const main = @import("../main.zig");
const Context = @import("context.zig");
const AuthCli = @import("auth.zig");
const ConfigCli = @import("config.zig");
const CharactersCli = @import("characters.zig");
const LaunchCli = @import("launch.zig");

pub fn printHelp() void {
    Context.print("{s}", .{main.usage});
}

pub fn printVersion() void {
    Context.print("zol : {s}\n", .{build_options.version});
}

pub fn parseCommand(ctx: *Context.Context, args: []const []const u8) !void {
    if (args.len < 2) {
        printHelp();
        return;
    }

    const subcmd = args[1];

    if (std.mem.eql(u8, subcmd, "help") or std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        return printHelp();
    }
    if (std.mem.eql(u8, subcmd, "version") or std.mem.eql(u8, subcmd, "--version")) {
        return printVersion();
    }

    if (std.mem.eql(u8, subcmd, "auth")) {
        return AuthCli.parseCommand(ctx, args[2..]);
    }

    if (std.mem.eql(u8, subcmd, "config")) {
        return ConfigCli.parseCommand(ctx, args[2..]);
    }

    if (std.mem.eql(u8, subcmd, "characters")) {
        return CharactersCli.parseCommand(ctx, args[2..]);
    }

    if (std.mem.eql(u8, subcmd, "launch")) {
        return LaunchCli.parseCommand(ctx, args[2..]);
    }

    Context.printErr("unknown command: {s}\n", .{subcmd});
    printHelp();
    return error.UnknownCommand;
}
