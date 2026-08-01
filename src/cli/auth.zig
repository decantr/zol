const std = @import("std");

const Context = @import("context.zig");
const oauth = @import("../lib/auth/oauth.zig");
const jwt = @import("../lib/auth/jwt.zig");
const url = @import("../lib/auth/zl_url.zig");
const browser = @import("../lib/auth/browser_open.zig");
const CharactersCli = @import("characters.zig");
const HttpClient = @import("../lib/http_client.zig").HttpClient;

pub const auth_usage: []const u8 =
    \\zol - Zig OSRS Launcher
    \\
    \\USAGE:
    \\    zol auth <command>
    \\
    \\OPTIONS:
    \\    list                    List all saved sessions
    \\    login                   Create a new session via external browser
    \\    logout <index|name|sub> Forget a saved session (local only)
    \\
;

pub fn parseCommand(ctx: *Context.Context, args: []const []const u8) !void {
    if (args.len < 1) {
        Context.print("{s}", .{auth_usage});
        return error.UsageError;
    }

    if (std.mem.eql(u8, args[0], "list")) {
        return list(ctx);
    }

    if (std.mem.eql(u8, args[0], "login")) {
        return login(ctx);
    }

    if (std.mem.eql(u8, args[0], "logout")) {
        if (args.len < 2) {
            Context.printErr("usage: zol auth logout <index|name|sub>\n", .{});
            return error.UsageError;
        }
        return logout(ctx, args[1]);
    }

    Context.printErr("unknown auth command: {s}\n", .{args[0]});
    Context.print("{s}", .{auth_usage});
    return error.UsageError;
}

pub fn list(ctx: *Context.Context) void {
    if (ctx.store.accounts.items.len == 0) {
        Context.print("No saved accounts. Run `zol auth login` to add one.\n", .{});
        return;
    }
    Context.print("Saved accounts:\n", .{});
    for (ctx.store.accounts.items, 0..) |a, i| {
        Context.print("  [{d}] {s}#{s}\n", .{ i, a.display_name, a.suffix });
    }
}

pub fn logout(ctx: *Context.Context, selector: []const u8) !void {
    const index = ctx.store.resolve(selector) orelse {
        Context.printErr("no account matches '{s}'\n", .{selector});
        return error.AccountNotFound;
    };
    const a = ctx.store.accounts.items[index];
    Context.print(
        "Forgetting local session for {s}#{s}.\n",
        .{ a.display_name, a.suffix },
    );
    Context.print(
        "Note: this only removes local credentials; the server-side session is not revoked.\n",
        .{},
    );
    ctx.store.removeIndex(index);
    try ctx.saveCredentials();
    // Drop the cached character list along with the session it belonged to.
    CharactersCli.forgetAccount(ctx, a.sub);
    Context.print("Done.\n", .{});
}

/// Full interactive login state machine using the external browser and pasted
/// callback URLs. Secrets are held only in memory and never printed.
pub fn login(ctx: *Context.Context) !void {
    const allocator = ctx.allocator;
    const io = ctx.io;

    var client = HttpClient.init(allocator, io);
    defer client.deinit();

    // --- Step 1: first authorization request -------------------------------
    var pkce = try oauth.generatePkce(allocator, io);
    defer pkce.deinit(allocator);

    const first_state = try oauth.generateState(allocator, io);
    defer allocator.free(first_state);

    const first_url = try oauth.buildFirstAuthUrl(allocator, pkce.challenge, first_state);
    defer allocator.free(first_url);

    Context.print("Opening your browser to sign in...\n", .{});
    browser.openBrowser(allocator, io, first_url) catch {};

    Context.print("\nAfter you finish signing in, your browser will show a page whose\n", .{});
    Context.print("URL begins with:\n  {s}\n", .{oauth.FIRST_REDIRECT_URI});
    Context.print("Paste that FULL URL here and press Enter:\n> ", .{});

    const first_input = try Context.readLine(allocator, io);
    defer allocator.free(first_input);

    var first_cb = url.parseFirstCallback(allocator, first_input) catch |err| {
        Context.printErr("invalid first callback: {s}\n", .{@errorName(err)});
        return err;
    };
    defer first_cb.deinit(allocator);

    if (!url.constantTimeEql(first_cb.state, first_state)) {
        Context.printErr("state mismatch on first callback; aborting.\n", .{});
        return error.StateMismatch;
    }
    Context.print("First callback received.\n", .{});

    // --- Step 2: authorization-code exchange -------------------------------
    var tokens = try oauth.exchangeCode(allocator, &client, first_cb.code, pkce.verifier);
    defer tokens.deinit(allocator);

    var first_payload = jwt.parseJwtPayload(allocator, tokens.id_token) catch |err| {
        Context.printErr("could not parse first id_token: {s}\n", .{@errorName(err)});
        return err;
    };
    defer jwt.freeJwtPayload(allocator, &first_payload);

    const first_sub = try allocator.dupe(u8, first_payload.sub);
    defer allocator.free(first_sub);

    // --- Step 3: second authorization request ------------------------------
    const second_state = try oauth.generateState(allocator, io);
    defer allocator.free(second_state);
    const nonce = try oauth.generateNonce(allocator, io);
    defer allocator.free(nonce);

    const second_url = try oauth.buildSecondAuthUrl(allocator, tokens.id_token, second_state, nonce);
    defer allocator.free(second_url);

    Context.print("\nOpening your browser to authorize the game session...\n", .{});
    browser.openBrowser(allocator, io, second_url) catch {};

    Context.print("\nYour browser will attempt to load a page at:\n  {s}\n", .{oauth.SECOND_REDIRECT_URI});
    Context.print("The connection will fail (that is expected). Copy the FULL URL from the\n", .{});
    Context.print("address bar and paste it here, then press Enter:\n> ", .{});

    const second_input = try Context.readLine(allocator, io);
    defer allocator.free(second_input);

    var second_cb = url.parseSecondCallback(allocator, second_input) catch |err| {
        Context.printErr("invalid second callback: {s}\n", .{@errorName(err)});
        return err;
    };
    defer second_cb.deinit(allocator);

    if (!url.constantTimeEql(second_cb.state, second_state)) {
        Context.printErr("state mismatch on second callback; aborting.\n", .{});
        return error.StateMismatch;
    }

    var second_payload = jwt.parseJwtPayload(allocator, second_cb.id_token) catch |err| {
        Context.printErr("could not parse second id_token: {s}\n", .{@errorName(err)});
        return err;
    };
    defer jwt.freeJwtPayload(allocator, &second_payload);

    // Validate nonce, subject continuity, auth_time, and nickname.
    const got_nonce = second_payload.nonce orelse {
        Context.printErr("second id_token missing nonce.\n", .{});
        return error.TokenClaimMissing;
    };
    if (!url.constantTimeEql(got_nonce, nonce)) {
        Context.printErr("nonce mismatch; aborting.\n", .{});
        return error.NonceMismatch;
    }
    if (!url.constantTimeEql(second_payload.sub, first_sub)) {
        Context.printErr("subject mismatch between tokens; aborting.\n", .{});
        return error.SubjectMismatch;
    }
    if (second_payload.auth_time == null) {
        Context.printErr("second id_token missing auth_time.\n", .{});
        return error.TokenClaimMissing;
    }
    const nickname = second_payload.nickname orelse {
        Context.printErr("second id_token missing nickname.\n", .{});
        return error.TokenClaimMissing;
    };

    const name = jwt.splitNickname(allocator, nickname) catch |err| {
        Context.printErr("invalid nickname format: {s}\n", .{@errorName(err)});
        return err;
    };
    defer allocator.free(name.display_name);
    defer allocator.free(name.suffix);

    // --- Step 4: game-session creation -------------------------------------
    var session = try oauth.createGameSession(allocator, &client, second_cb.id_token);
    defer session.deinit(allocator);

    // --- Step 5: persist and report ----------------------------------------
    try ctx.store.upsert(.{
        .sub = second_payload.sub,
        .display_name = name.display_name,
        .suffix = name.suffix,
        .session_id = session.session_id,
    });
    try ctx.saveCredentials();

    Context.print("\nLogged in as {s}#{s}.\n", .{ name.display_name, name.suffix });

    // Fetch and display characters as a confirmation.
    var lookup = try oauth.fetchCharacters(allocator, &client, session.session_id);
    defer lookup.deinit();
    switch (lookup.status) {
        .ok => {
            if (lookup.characters) |chars| {
                // Seed the local cache so later commands need no network call.
                const now = std.Io.Timestamp.now(io, .real).toSeconds();
                ctx.characters.put(second_payload.sub, chars.items, now) catch {};
                ctx.saveCharacters() catch |err| {
                    Context.printErr("warning: could not save character cache: {s}\n", .{@errorName(err)});
                };

                Context.print("Characters:\n", .{});
                for (chars.items, 0..) |c, i| {
                    Context.print("  [{d}] {s}\n", .{ i, c.display_name });
                }
            }
        },
        .rate_limited => Context.printErr("Rate limited while listing characters; try again later.\n", .{}),
        else => Context.printErr("Could not list characters right now (status: {s}).\n", .{@tagName(lookup.status)}),
    }
}
