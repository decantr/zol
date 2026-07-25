const std = @import("std");

const Parser = @import("cli/parser.zig");

pub const usage: []const u8 =
    \\zol - Zig OSRS Launcher
    \\
    \\USAGE:
    \\    zol <command>
    \\
    \\OPTIONS:
    \\    help       Show this message
    \\    version    Show zol version
    \\
    \\CONFIG:
    \\    Location: ~/.config/zol/config.json
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    Parser.parseCommand(args) catch |err| {
        std.debug.print("error: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}
