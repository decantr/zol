const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const builtin = @import("builtin");

pub fn openBrowser(allocator: Allocator, io: Io, url: []const u8) !void {
    if (builtin.os.tag == .windows) {
        const result = std.process.run(allocator, io, .{
            .argv = &.{ "cmd", "/c", "start", "", url },
        }) catch {
            printUrlFallback(io, url);
            return;
        };

        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (result.term.exited != 0) {
            printUrlFallback(io, url);
        }

        return;
    }

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "xdg-open", url },
    }) catch {
        printUrlFallback(io, url);
        return;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.exited != 0) {
        printUrlFallback(io, url);
    }
}

fn printUrlFallback(io: Io, url: []const u8) void {
    const stderr_file = Io.File.stderr();
    var buf: [1024]u8 = undefined;
    var writer = stderr_file.writer(io, &buf);
    writer.interface.print("\nPlease open this URL in your browser:\n{s}\n\n", .{url}) catch {};
    writer.interface.flush() catch {};
}

test "browser open compiles" {
    _ = openBrowser;
}
