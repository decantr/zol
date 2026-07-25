const std = @import("std");

const Config = @import("../lib/config.zig");

pub const config_usage: []const u8 =
    \\zol - Zig OSRS Launcher
    \\
    \\USAGE:
    \\    zol config <command>
    \\
    \\OPTIONS:
    \\    show       Print config json
    \\
;

pub fn parseCommand(config: *Config.Config, args: []const []const u8) !void {
    // for (args) |arg| {
    //     std.debug.print("{s}\n", .{arg});
    // }

    if (args.len < 1) {
        std.debug.print(config_usage, .{});

        std.process.exit(0);
    }

    if (std.mem.eql(u8, args[0], "show")) {
        return show(config);
    }

    if (args.len < 2) {
        std.debug.print(config_usage, .{});

        return error.UsageError;
    }
}

pub fn show(config: *Config.Config) void {
    config.print();
}
