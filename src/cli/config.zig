const std = @import("std");

pub const auth_usage: []const u8 =
    \\zol - Zig OSRS Launcher
    \\
    \\USAGE:
    \\    zol config <command>
    \\
    \\OPTIONS:
    \\    config       Print config json
    \\
;

pub fn parseCommand(args: []const []const u8) !void {
    // for (args) |arg| {
    //     std.debug.print("{s}\n", .{arg});
    // }

    if (args.len < 1) {
        std.debug.print(auth_usage, .{});

        return error.UsageError;
    }

    if (std.mem.eql(u8, args[0], "list")) {
        return list() catch |err| {
            std.debug.print("Failed listing logins: {s}\n", .{@errorName(err)});

            std.process.exit(1);
        };
    }

    if (args.len < 2) {
        std.debug.print(auth_usage, .{});

        return error.UsageError;
    }
}

pub fn list() !void {
    std.debug.print("list", .{});
}
