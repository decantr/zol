const std = @import("std");
const build_options = @import("build_options");

const main = @import("../main.zig");
const AuthCli = @import("auth.zig");
const ConfigCli = @import("config.zig");

pub fn printHelp() void {
    std.debug.print(main.usage, .{});
    std.process.exit(0);
}

pub fn printVersion() void {
    std.debug.print("zol : {s}\n", .{build_options.version});
    std.process.exit(0);
}

pub fn parseCommand(args: []const []const u8) !void {
    if (args.len < 2) printHelp();

    const subcmd = args[1];

    if (std.mem.eql(u8, subcmd, "help") or std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        return printHelp();
    }
    if (std.mem.eql(u8, subcmd, "version") or std.mem.eql(u8, subcmd, "--version")) {
        return printVersion();
    }

    // auth
    if (std.mem.eql(u8, subcmd, "auth")) {
        AuthCli.parseCommand(args[2..]) catch |err| {
            return err;
        };
    }

    if (std.mem.eql(u8, subcmd, "config")) {
        ConfigCli.parseCommand(args[2..]) catch |err| {
            return err;
        };
    }
}
