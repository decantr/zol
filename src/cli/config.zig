const std = @import("std");

const Context = @import("context.zig");

pub const config_usage: []const u8 =
    \\zol - Zig OSRS Launcher
    \\
    \\USAGE:
    \\    zol config <command>
    \\
    \\OPTIONS:
    \\    show                 Print config json
    \\    set <key> <value>    Set a config value (default_account, executable, arguments)
    \\
;

pub fn parseCommand(ctx: *Context.Context, args: []const []const u8) !void {
    if (args.len < 1) {
        Context.print("{s}", .{config_usage});
        return;
    }

    if (std.mem.eql(u8, args[0], "show")) {
        return show(ctx);
    }

    if (std.mem.eql(u8, args[0], "set")) {
        if (args.len < 3) {
            Context.printErr("usage: zol config set <key> <value>\n", .{});
            return error.UsageError;
        }
        return set(ctx, args[1], args[2]);
    }

    Context.printErr("unknown config command: {s}\n", .{args[0]});
    Context.print("{s}", .{config_usage});
    return error.UsageError;
}

pub fn show(ctx: *Context.Context) void {
    ctx.config.print();
}

pub fn set(ctx: *Context.Context, key: []const u8, value: []const u8) !void {
    ctx.config.set(key, value) catch |err| switch (err) {
        error.UnknownKey => {
            Context.printErr("unknown config key: {s}\n", .{key});
            return error.UsageError;
        },
        else => return err,
    };
    try ctx.saveConfig();
    Context.print("set {s} = {s}\n", .{ key, value });
}
