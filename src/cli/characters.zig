const std = @import("std");
const Io = std.Io;

const Context = @import("context.zig");
const oauth = @import("../lib/auth/oauth.zig");
const HttpClient = @import("../lib/http_client.zig").HttpClient;

pub const characters_usage: []const u8 =
    \\zol - Zig OSRS Launcher
    \\
    \\USAGE:
    \\    zol characters [list] [--account <sel>] [--refresh]
    \\    zol characters refresh [--account <sel>]
    \\    zol characters set-default <index|name|id> [--account <sel>]
    \\
    \\OPTIONS:
    \\    list [--account <sel>] [--refresh]         List characters
    \\    refresh [--account <sel>]                  Re-fetch characters from Jagex
    \\    set-default <index|name|id> [--account <sel>]  Set the default character
    \\
    \\Characters are read from a local cache and only fetched over the network on
    \\a cache miss or an explicit --refresh. Without --account, listing and
    \\refreshing cover every saved account; with --account they cover just that
    \\one.
    \\
;

const Flags = struct {
    account: ?[]const u8 = null,
    refresh: bool = false,
};

pub fn parseCommand(ctx: *Context.Context, args: []const []const u8) !void {
    if (args.len < 1) {
        return run(ctx, args, false);
    }

    if (std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "--help")) {
        Context.print("{s}", .{characters_usage});
        return;
    }

    if (std.mem.eql(u8, args[0], "list")) {
        return run(ctx, args[1..], false);
    }

    if (std.mem.eql(u8, args[0], "refresh")) {
        return run(ctx, args[1..], true);
    }

    if (std.mem.eql(u8, args[0], "set-default")) {
        return setDefault(ctx, args[1..]);
    }

    // Bare flags (`zol characters --refresh`) are treated as `list` options.
    if (std.mem.startsWith(u8, args[0], "-")) {
        return run(ctx, args, false);
    }

    Context.printErr("unknown characters command: {s}\n", .{args[0]});
    Context.print("{s}", .{characters_usage});
    return error.UsageError;
}

/// Extract `--account <sel>` and `--refresh` flags, collecting anything else
/// into `positionals`. Unrecognized flags are rejected rather than silently
/// treated as positional arguments.
fn takeFlags(args: []const []const u8, positionals: *std.ArrayList([]const u8), allocator: std.mem.Allocator) !Flags {
    var flags = Flags{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--account")) {
            if (i + 1 >= args.len) return error.MissingFlagValue;
            flags.account = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--refresh")) {
            flags.refresh = true;
        } else if (std.mem.startsWith(u8, args[i], "-")) {
            Context.printErr("unknown characters argument: {s}\n", .{args[i]});
            return error.UsageError;
        } else {
            try positionals.append(allocator, args[i]);
        }
    }
    return flags;
}

/// Resolve which account to operate on: explicit selector, else default, else
/// the sole account, else fail (never guess when ambiguous).
pub fn resolveAccount(ctx: *Context.Context, account_sel: ?[]const u8) !usize {
    if (account_sel) |sel| {
        return ctx.store.resolve(sel) orelse {
            Context.printErr("no account matches '{s}'\n", .{sel});
            return error.AccountNotFound;
        };
    }
    if (ctx.config.default_account) |def| {
        if (ctx.store.resolve(def)) |idx| return idx;
    }
    if (ctx.store.accounts.items.len == 1) return 0;
    if (ctx.store.accounts.items.len == 0) {
        Context.printErr("no saved accounts; run `zol auth login`.\n", .{});
        return error.NoAccounts;
    }
    Context.printErr("multiple accounts saved; specify --account <index|name|sub>.\n", .{});
    return error.AmbiguousAccount;
}

/// Fetch characters for the account at `index`, handling status classification.
/// This always performs a network request; prefer `charactersForAccount`.
pub fn fetchForAccount(ctx: *Context.Context, index: usize) !oauth.CharacterList {
    const account = ctx.store.accounts.items[index];

    var client = HttpClient.init(ctx.allocator, ctx.io);
    defer client.deinit();

    var lookup = try oauth.fetchCharacters(ctx.allocator, &client, account.session_id);
    switch (lookup.status) {
        .ok => return lookup.characters.?,
        .expired => {
            lookup.deinit();
            Context.printErr(
                "session for {s}#{s} has expired. Run `zol auth login` to renew,\n",
                .{ account.display_name, account.suffix },
            );
            Context.printErr("or `zol auth logout {s}` to forget it.\n", .{account.display_name});
            return error.SessionExpired;
        },
        .rate_limited => {
            lookup.deinit();
            Context.printErr("rate limited; try again later.\n", .{});
            return error.RateLimited;
        },
        .client_error => {
            lookup.deinit();
            Context.printErr("server rejected the request (client error).\n", .{});
            return error.ClientError;
        },
        .service_error => {
            lookup.deinit();
            Context.printErr("temporary service error; credentials kept.\n", .{});
            return error.ServiceError;
        },
    }
}

/// Characters for the account at `index`, served from the local cache when
/// present and fetched (then cached) on a miss. The returned slice is owned by
/// the cache and stays valid for the lifetime of `ctx`.
pub fn charactersForAccount(ctx: *Context.Context, index: usize) ![]const oauth.Character {
    const account = ctx.store.accounts.items[index];
    if (ctx.characters.get(account.sub)) |entry| return entry.characters;
    return refreshAccount(ctx, index);
}

/// Fetch characters for the account at `index` from the network, replace its
/// cache entry, and persist the cache.
pub fn refreshAccount(ctx: *Context.Context, index: usize) ![]const oauth.Character {
    const account = ctx.store.accounts.items[index];

    var fetched = try fetchForAccount(ctx, index);
    defer fetched.deinit();

    const now = Io.Timestamp.now(ctx.io, .real).toSeconds();
    try ctx.characters.put(account.sub, fetched.items, now);
    ctx.saveCharacters() catch |err| {
        // The lookup succeeded; a cache that could not be written just means
        // the next command fetches again.
        Context.printErr("warning: could not save character cache: {s}\n", .{@errorName(err)});
    };

    return (ctx.characters.get(account.sub) orelse unreachable).characters;
}

/// Drop the cached characters for an account, e.g. after logout.
pub fn forgetAccount(ctx: *Context.Context, sub: []const u8) void {
    if (ctx.characters.get(sub) == null) return;
    ctx.characters.remove(sub);
    ctx.saveCharacters() catch |err| {
        Context.printErr("warning: could not save character cache: {s}\n", .{@errorName(err)});
    };
}

/// `zol characters [list|refresh] [--account <sel>] [--refresh]`.
fn run(ctx: *Context.Context, args: []const []const u8, force_refresh: bool) !void {
    var positionals = std.ArrayList([]const u8).empty;
    defer positionals.deinit(ctx.allocator);
    const flags = try takeFlags(args, &positionals, ctx.allocator);

    if (positionals.items.len > 0) {
        Context.printErr("unexpected argument: {s}\n", .{positionals.items[0]});
        Context.print("{s}", .{characters_usage});
        return error.UsageError;
    }

    const refresh = force_refresh or flags.refresh;

    // Without an explicit account, list (or refresh) every saved account rather
    // than making the user disambiguate.
    if (flags.account == null) return listAll(ctx, refresh);

    const index = try resolveAccount(ctx, flags.account);
    const chars = if (refresh)
        try refreshAccount(ctx, index)
    else
        try charactersForAccount(ctx, index);

    printCharacters(ctx, index, chars);
}

pub fn list(ctx: *Context.Context, args: []const []const u8) !void {
    return run(ctx, args, false);
}

/// List every saved account, re-fetching each one when `refresh` is set. One
/// failing account does not stop the others; the command still exits nonzero so
/// scripts can tell.
fn listAll(ctx: *Context.Context, refresh: bool) !void {
    if (ctx.store.accounts.items.len == 0) {
        Context.printErr("no saved accounts; run `zol auth login`.\n", .{});
        return error.NoAccounts;
    }

    var failed: usize = 0;
    var printed: usize = 0;
    for (0..ctx.store.accounts.items.len) |index| {
        const chars = (if (refresh)
            refreshAccount(ctx, index)
        else
            charactersForAccount(ctx, index)) catch {
            failed += 1;
            continue;
        };
        if (printed > 0) Context.print("\n", .{});
        printed += 1;
        printCharacters(ctx, index, chars);
    }

    if (failed > 0) {
        Context.printErr("{d} of {d} account(s) could not be listed.\n", .{
            failed,
            ctx.store.accounts.items.len,
        });
        return error.CharacterListFailed;
    }
}

fn printCharacters(ctx: *Context.Context, index: usize, chars: []const oauth.Character) void {
    const account = ctx.store.accounts.items[index];
    Context.print("Characters for {s}#{s}:\n", .{ account.display_name, account.suffix });
    if (chars.len == 0) {
        Context.print("  (none)\n", .{});
        return;
    }
    for (chars, 0..) |c, i| {
        Context.print("  [{d}] {s}\n", .{ i, c.display_name });
    }
}

pub fn setDefault(ctx: *Context.Context, args: []const []const u8) !void {
    var positionals = std.ArrayList([]const u8).empty;
    defer positionals.deinit(ctx.allocator);
    const flags = try takeFlags(args, &positionals, ctx.allocator);

    if (positionals.items.len < 1) {
        Context.printErr("usage: zol characters set-default <index|name|id> [--account <sel>]\n", .{});
        return error.UsageError;
    }
    const char_sel = positionals.items[0];

    const index = try resolveAccount(ctx, flags.account);
    const account = ctx.store.accounts.items[index];

    var chars = if (flags.refresh)
        try refreshAccount(ctx, index)
    else
        try charactersForAccount(ctx, index);

    var char = resolveCharacter(chars, char_sel);
    if (char == null and !flags.refresh) {
        // The cache may predate a new character; re-fetch once before failing.
        chars = try refreshAccount(ctx, index);
        char = resolveCharacter(chars, char_sel);
    }
    const selected = char orelse {
        Context.printErr("no character matches '{s}'\n", .{char_sel});
        return error.CharacterNotFound;
    };

    // Key the default character by the account subject for stability.
    try ctx.config.setDefaultCharacter(account.sub, selected.account_id);
    try ctx.saveConfig();

    Context.print(
        "Default character for {s}#{s} set to {s}.\n",
        .{ account.display_name, account.suffix, selected.display_name },
    );
}

/// Resolve a character selector (index, accountId, or displayName).
pub fn resolveCharacter(chars: []const oauth.Character, selector: []const u8) ?oauth.Character {
    if (std.fmt.parseInt(usize, selector, 10)) |idx| {
        if (idx < chars.len) return chars[idx];
    } else |_| {}
    for (chars) |c| {
        if (std.mem.eql(u8, c.account_id, selector)) return c;
        if (std.mem.eql(u8, c.display_name, selector)) return c;
    }
    return null;
}
