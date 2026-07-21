const std = @import("std");
const Io = std.Io;

const version_string = "0.1.0";
const Writer = *Io.Writer;

pub const Command = union(enum) {
    help,
    version,
};

pub fn parseCommand(args: []const []const u8) !Command {
    if (args.len < 2) return .help;

    const subcmd = args[1];

    if (std.mem.eql(u8, subcmd, "help") or std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        return .help;
    }
    if (std.mem.eql(u8, subcmd, "version") or std.mem.eql(u8, subcmd, "--version")) {
        return .version;
    }

    return error.UsageError;
}
