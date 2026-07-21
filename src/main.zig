const std = @import("std");
const Io = std.Io;

const build_options = @import("build_options");

const zosrs_launcher = @import("zosrs_launcher");

const parser = @import("cli/parser.zig");

const usage: []const u8 =
    \\ZOSRS Launcher - Old School RuneScape launcher
    \\
    \\Usage: zosrs-launcher <command> [options]
    \\
    \\Commands:
    \\  help        Show this help message
    \\  version     Show version
;

const version = "0.0.0";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const command = parser.parseCommand(args) catch |err| {
        stderr.print("error: {s}\n", .{@errorName(err)}) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    };

    switch (command) {
        .help => {
            try stdout.writeAll(usage);
            try stdout.flush();
            std.process.exit(0);
        },
        .version => {
            try stdout.print("zosrs-launcher {s}", .{version});
            try stdout.flush();
            std.process.exit(0);
        },
    }

    stdout.flush() catch {};
    stderr.flush() catch {};
}
