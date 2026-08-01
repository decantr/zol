const std = @import("std");
const Io = std.Io;

const Context = @import("context.zig");
const oauth = @import("../lib/auth/oauth.zig");
const CharactersCli = @import("characters.zig");

pub const launch_usage: []const u8 =
    \\zol - Zig OSRS Launcher
    \\
    \\USAGE:
    \\    zol launch [--account <sel>] [--character <sel>] [--refresh] [--wait]
    \\
    \\Launches the configured executable with the selected character. The game
    \\session values are passed via JX_SESSION_ID, JX_CHARACTER_ID, and
    \\JX_DISPLAY_NAME environment variables and never on the command line.
    \\
    \\Characters come from the local cache; --refresh re-fetches them first,
    \\which also revalidates the saved session before launching.
    \\
;

const LaunchArgs = struct {
    account: ?[]const u8 = null,
    character: ?[]const u8 = null,
    refresh: bool = false,
    wait: bool = false,
};

fn parseArgs(args: []const []const u8) !LaunchArgs {
    var out = LaunchArgs{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--account")) {
            if (i + 1 >= args.len) return error.MissingFlagValue;
            out.account = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--character")) {
            if (i + 1 >= args.len) return error.MissingFlagValue;
            out.character = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--refresh")) {
            out.refresh = true;
        } else if (std.mem.eql(u8, a, "--wait")) {
            out.wait = true;
        } else {
            Context.printErr("unknown launch argument: {s}\n", .{a});
            return error.UsageError;
        }
    }
    return out;
}

pub fn parseCommand(ctx: *Context.Context, args: []const []const u8) !void {
    if (args.len >= 1 and (std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "--help"))) {
        Context.print("{s}", .{launch_usage});
        return;
    }
    const parsed = try parseArgs(args);
    return run(ctx, parsed);
}

fn run(ctx: *Context.Context, args: LaunchArgs) !void {
    const allocator = ctx.allocator;
    const io = ctx.io;

    // 1. Resolve account.
    const account_index = try CharactersCli.resolveAccount(ctx, args.account);
    const account = ctx.store.accounts.items[account_index];

    // 2. Resolve character: explicit arg, saved default, sole character, else
    //    fail. Characters come from the local cache and are re-fetched (which
    //    also revalidates the session) on --refresh or a cache miss.
    const character = try resolveCharacter(ctx, account_index, args);

    // 3. Resolve the configured executable.
    const executable = ctx.config.executable orelse {
        Context.printErr("no executable configured. Set one with:\n", .{});
        Context.printErr("  zol config set executable /path/to/client\n", .{});
        return error.NoExecutable;
    };

    // 4. Validate the executable is an existing regular file.
    const stat = Io.Dir.cwd().statFile(io, executable, .{}) catch |err| {
        Context.printErr("cannot stat executable '{s}': {s}\n", .{ executable, @errorName(err) });
        return error.ExecutableNotFound;
    };
    if (stat.kind != .file) {
        Context.printErr("configured executable '{s}' is not a regular file.\n", .{executable});
        return error.ExecutableNotFile;
    }

    // 5. Build argv as an array (never through a shell).
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, executable);
    if (ctx.config.arguments) |arguments| {
        var it = std.mem.tokenizeScalar(u8, arguments, ' ');
        while (it.next()) |tok| {
            try argv.append(allocator, tok);
        }
    }

    // 6. Copy the parent environment and add the three JX_* values.
    var child_env = try ctx.env.clone(allocator);
    defer child_env.deinit();
    try child_env.put("JX_SESSION_ID", account.session_id);
    try child_env.put("JX_CHARACTER_ID", character.account_id);
    try child_env.put("JX_DISPLAY_NAME", character.display_name);

    // 7. Spawn the process. Do not echo secrets.
    Context.print(
        "Launching {s} as {s} ({s}#{s})...\n",
        .{ executable, character.display_name, account.display_name, account.suffix },
    );

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = &child_env,
    }) catch |err| {
        Context.printErr("failed to launch: {s}\n", .{@errorName(err)});
        return error.SpawnFailed;
    };

    if (args.wait) {
        const term = child.wait(io) catch |err| {
            Context.printErr("error waiting for client: {s}\n", .{@errorName(err)});
            return error.WaitFailed;
        };
        switch (term) {
            .exited => |code| {
                if (code != 0) {
                    Context.printErr("client exited with code {d}.\n", .{code});
                    return error.ClientExitedNonZero;
                }
                Context.print("client exited cleanly.\n", .{});
            },
            else => Context.printErr("client terminated abnormally.\n", .{}),
        }
    } else {
        Context.print("Client launched. Detaching.\n", .{});
    }
}

fn resolveCharacter(
    ctx: *Context.Context,
    account_index: usize,
    args: LaunchArgs,
) !oauth.Character {
    const account = ctx.store.accounts.items[account_index];

    var chars = if (args.refresh)
        try CharactersCli.refreshAccount(ctx, account_index)
    else
        try CharactersCli.charactersForAccount(ctx, account_index);
    // Whether the cache has already been re-fetched during this launch.
    var refreshed = args.refresh;

    // Explicit selector, else the saved default keyed by account subject.
    const wanted: ?[]const u8 = args.character orelse
        ctx.config.default_account_character.get(account.sub);

    if (wanted) |sel| {
        if (CharactersCli.resolveCharacter(chars, sel)) |c| return c;
        if (!refreshed) {
            // A character added since the last fetch would be missing from the
            // cache; re-fetch once before reporting it as unknown.
            chars = try CharactersCli.refreshAccount(ctx, account_index);
            refreshed = true;
            if (CharactersCli.resolveCharacter(chars, sel)) |c| return c;
        }
        if (args.character != null) {
            Context.printErr("no character matches '{s}'\n", .{sel});
        } else {
            Context.printErr("saved default character no longer exists; specify --character.\n", .{});
        }
        return error.CharacterNotFound;
    }

    if (chars.len == 0 and !refreshed) {
        chars = try CharactersCli.refreshAccount(ctx, account_index);
        refreshed = true;
    }
    if (chars.len == 1) return chars[0];
    if (chars.len == 0) {
        Context.printErr("account has no characters.\n", .{});
        return error.NoCharacters;
    }
    Context.printErr("multiple characters available; specify --character <index|name|id>.\n", .{});
    for (chars, 0..) |c, i| {
        Context.printErr("  [{d}] {s}\n", .{ i, c.display_name });
    }
    return error.AmbiguousCharacter;
}
