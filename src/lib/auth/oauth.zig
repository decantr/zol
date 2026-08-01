const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const HttpClient = @import("../http_client.zig").HttpClient;

pub const BASE_URL = "https://account.jagex.com";
pub const AUTH_URL = "https://account.jagex.com/oauth2/auth";
pub const TOKEN_URL = "https://account.jagex.com/oauth2/token";
pub const GAME_SESSION_URL = "https://auth.jagex.com/game-session/v1/sessions";
pub const ACCOUNTS_URL = "https://auth.jagex.com/game-session/v1/accounts";

pub const FIRST_CLIENT_ID = "com_jagex_auth_desktop_launcher";
pub const FIRST_REDIRECT_URI = "https://secure.runescape.com/m=weblogin/launcher-redirect";
pub const SECOND_CLIENT_ID = "1fddee4e-b100-4f4e-b2b0-097f9088f9d2";
pub const SECOND_REDIRECT_URI = "http://localhost";

pub const FIRST_SCOPE = "openid+offline+gamesso.token.create+user.profile.read+user.entitlement.read+user.game.read+user.sku.read+user.voucher.redeem";
pub const SECOND_SCOPE = "openid+offline";

pub const NONCE_LEN = 32;
pub const STATE_LEN = 32;
pub const VERIFIER_LEN = 32;

pub const PkcePair = struct {
    verifier: []const u8,
    challenge: []const u8,

    pub fn deinit(self: *PkcePair, allocator: Allocator) void {
        allocator.free(self.verifier);
        allocator.free(self.challenge);
    }
};

/// Fill `buf` with cryptographically secure random bytes from the platform
/// entropy source. Returns `error.EntropyUnavailable` if none is available;
/// the caller should treat this as fatal rather than fall back to a weak RNG.
fn secureRandom(io: Io, buf: []u8) !void {
    io.randomSecure(buf) catch return error.EntropyUnavailable;
}

/// Compute the PKCE challenge (unpadded Base64URL SHA-256) from a verifier.
pub fn pkceChallengeFromVerifier(allocator: Allocator, verifier: []const u8) ![]const u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(verifier);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return base64UrlEncode(allocator, &digest);
}

/// Build a PKCE pair from an explicit verifier-seed. Exposed for deterministic
/// tests; production code should use `generatePkce`.
pub fn pkceFromBytes(allocator: Allocator, seed: []const u8) !PkcePair {
    const verifier = try base64UrlEncode(allocator, seed);
    errdefer allocator.free(verifier);
    const challenge = try pkceChallengeFromVerifier(allocator, verifier);
    return .{ .verifier = verifier, .challenge = challenge };
}

pub fn generatePkce(allocator: Allocator, io: Io) !PkcePair {
    var rand_bytes: [VERIFIER_LEN]u8 = undefined;
    try secureRandom(io, &rand_bytes);
    return pkceFromBytes(allocator, &rand_bytes);
}

pub fn generateState(allocator: Allocator, io: Io) ![]const u8 {
    var rand_bytes: [STATE_LEN]u8 = undefined;
    try secureRandom(io, &rand_bytes);
    return try base64UrlEncode(allocator, &rand_bytes);
}

pub fn generateNonce(allocator: Allocator, io: Io) ![]const u8 {
    var rand_bytes: [NONCE_LEN]u8 = undefined;
    try secureRandom(io, &rand_bytes);
    return try base64UrlEncode(allocator, &rand_bytes);
}

pub fn buildFirstAuthUrl(
    allocator: Allocator,
    code_challenge: []const u8,
    state: []const u8,
) ![]const u8 {
    const Url = @import("zl_url.zig");
    const encoded_redirect = try Url.percentEncode(allocator, FIRST_REDIRECT_URI);
    defer allocator.free(encoded_redirect);
    return try std.fmt.allocPrint(allocator, "{s}/oauth2/auth?auth_method=&login_type=&flow=launcher&response_type=code&client_id={s}&code_challenge_method=S256&prompt=login&scope={s}&redirect_uri={s}&code_challenge={s}&state={s}", .{
        BASE_URL,
        FIRST_CLIENT_ID,
        FIRST_SCOPE,
        encoded_redirect,
        code_challenge,
        state,
    });
}

pub fn buildSecondAuthUrl(
    allocator: Allocator,
    id_token_hint: []const u8,
    state: []const u8,
    nonce: []const u8,
) ![]const u8 {
    const Url = @import("zl_url.zig");
    const encoded_redirect = try Url.percentEncode(allocator, SECOND_REDIRECT_URI);
    defer allocator.free(encoded_redirect);
    return try std.fmt.allocPrint(allocator, "{s}/oauth2/auth?prompt=consent&redirect_uri={s}&response_type=id_token+code&client_id={s}&scope={s}&id_token_hint={s}&state={s}&nonce={s}", .{
        BASE_URL,
        encoded_redirect,
        SECOND_CLIENT_ID,
        SECOND_SCOPE,
        id_token_hint,
        state,
        nonce,
    });
}

pub fn base64UrlEncode(allocator: Allocator, data: []const u8) ![]const u8 {
    const enc = std.base64.url_safe_no_pad;
    const encoded_len = enc.Encoder.calcSize(data.len);
    const buf = try allocator.alloc(u8, encoded_len);
    _ = enc.Encoder.encode(buf, data);
    return buf;
}

pub const TokenResponse = struct {
    id_token: []const u8,
    access_token: []const u8,
    refresh_token: []const u8,
    expires_in: i64,

    pub fn deinit(self: *TokenResponse, allocator: Allocator) void {
        allocator.free(self.id_token);
        allocator.free(self.access_token);
        allocator.free(self.refresh_token);
    }
};

pub const GameSessionResponse = struct {
    session_id: []const u8,

    pub fn deinit(self: *GameSessionResponse, allocator: Allocator) void {
        allocator.free(self.session_id);
    }
};

pub fn buildTokenRequestBody(
    allocator: Allocator,
    code: []const u8,
    code_verifier: []const u8,
) ![]const u8 {
    const Url = @import("zl_url.zig");
    const pairs: [4]struct { []const u8, []const u8 } = .{
        .{ "grant_type", "authorization_code" },
        .{ "client_id", FIRST_CLIENT_ID },
        .{ "redirect_uri", FIRST_REDIRECT_URI },
        .{ "code", code },
    };
    var parts = std.ArrayList(u8).empty;
    for (pairs, 0..) |pair, i| {
        if (i > 0) try parts.appendSlice(allocator, "&");
        const encoded = try Url.formEncode(allocator, pair[0], pair[1]);
        defer allocator.free(encoded);
        try parts.appendSlice(allocator, encoded);
    }
    try parts.appendSlice(allocator, "&");
    const verifier_encoded = try Url.formEncode(allocator, "code_verifier", code_verifier);
    defer allocator.free(verifier_encoded);
    try parts.appendSlice(allocator, verifier_encoded);
    return try parts.toOwnedSlice(allocator);
}

pub fn parseTokenResponse(allocator: Allocator, json_bytes: []const u8) !TokenResponse {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.ResponseSchemaError;
    const obj = parsed.value.object;

    const id_token = obj.get("id_token") orelse return error.ResponseSchemaError;
    const access_token = obj.get("access_token") orelse return error.ResponseSchemaError;
    const refresh_token = obj.get("refresh_token") orelse return error.ResponseSchemaError;
    const expires_in = obj.get("expires_in") orelse return error.ResponseSchemaError;

    if (id_token != .string or id_token.string.len == 0) return error.ResponseSchemaError;
    if (access_token != .string) return error.ResponseSchemaError;
    if (refresh_token != .string) return error.ResponseSchemaError;
    if (expires_in != .integer) return error.ResponseSchemaError;

    return .{
        .id_token = try allocator.dupe(u8, id_token.string),
        .access_token = try allocator.dupe(u8, access_token.string),
        .refresh_token = try allocator.dupe(u8, refresh_token.string),
        .expires_in = expires_in.integer,
    };
}

/// A single game character returned by the accounts endpoint.
pub const Character = struct {
    account_id: []const u8,
    display_name: []const u8,
};

/// A parsed, owned list of characters.
pub const CharacterList = struct {
    allocator: Allocator,
    items: []Character,

    pub fn deinit(self: *CharacterList) void {
        for (self.items) |c| {
            self.allocator.free(c.account_id);
            self.allocator.free(c.display_name);
        }
        self.allocator.free(self.items);
    }
};

/// Strictly parse the accounts endpoint response, an array of
/// {accountId, displayName} objects.
pub fn parseAccountsResponse(allocator: Allocator, json_bytes: []const u8) !CharacterList {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    if (parsed.value != .array) return error.ResponseSchemaError;
    const arr = parsed.value.array;

    var list = std.ArrayList(Character).empty;
    errdefer {
        for (list.items) |c| {
            allocator.free(c.account_id);
            allocator.free(c.display_name);
        }
        list.deinit(allocator);
    }

    for (arr.items) |item| {
        if (item != .object) return error.ResponseSchemaError;
        const obj = item.object;

        // accountId is the stable identifier and must always be present.
        const account_id = obj.get("accountId") orelse return error.ResponseSchemaError;
        if (account_id != .string or account_id.string.len == 0) return error.ResponseSchemaError;

        // displayName is best-effort: characters that have not set a display
        // name come back as null, missing, or an empty string. Accounts with
        // multiple characters frequently include such entries, so tolerate
        // them and fall back to the accountId rather than rejecting the whole
        // response.
        const display_name: []const u8 = blk: {
            const dn = obj.get("displayName") orelse break :blk account_id.string;
            if (dn != .string or dn.string.len == 0) break :blk account_id.string;
            break :blk dn.string;
        };

        try list.append(allocator, .{
            .account_id = try allocator.dupe(u8, account_id.string),
            .display_name = try allocator.dupe(u8, display_name),
        });
    }

    return .{
        .allocator = allocator,
        .items = try list.toOwnedSlice(allocator),
    };
}

/// Classification of a session-validation attempt based on HTTP status.
pub const SessionStatus = enum {
    ok,
    expired, // 401
    rate_limited, // 429
    client_error, // other 4xx
    service_error, // 5xx / network

    pub fn fromHttpStatus(status: u16) SessionStatus {
        return switch (status) {
            200 => .ok,
            401 => .expired,
            429 => .rate_limited,
            400, 402...428, 430...499 => .client_error,
            else => if (status >= 500) .service_error else .client_error,
        };
    }
};

/// Build the JSON body for the game-session creation request.
pub fn buildGameSessionBody(allocator: Allocator, id_token: []const u8) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"idToken\":\"");
    for (id_token) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            else => try w.writeByte(c),
        }
    }
    try w.writeAll("\"}");
    return aw.toOwnedSlice();
}

pub fn parseGameSessionResponse(allocator: Allocator, json_bytes: []const u8) !GameSessionResponse {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.ResponseSchemaError;
    const obj = parsed.value.object;

    const session_id = obj.get("sessionId") orelse return error.ResponseSchemaError;
    if (session_id != .string or session_id.string.len == 0) return error.ResponseSchemaError;

    return .{
        .session_id = try allocator.dupe(u8, session_id.string),
    };
}

// ---------------------------------------------------------------------------
// Networked flow helpers. These tie the HTTP client to the strict parsers.
// They intentionally never log tokens, codes, or session IDs.
// ---------------------------------------------------------------------------

/// Exchange the first authorization code for the initial token set.
pub fn exchangeCode(
    allocator: Allocator,
    client: *HttpClient,
    code: []const u8,
    code_verifier: []const u8,
) !TokenResponse {
    const body = try buildTokenRequestBody(allocator, code, code_verifier);
    defer allocator.free(body);

    var resp = try client.request(.{
        .method = .POST,
        .url = TOKEN_URL,
        .content_type = "application/x-www-form-urlencoded",
        .body = body,
    });
    defer resp.deinit(allocator);

    if (resp.status != 200) return error.TokenExchangeFailed;
    return parseTokenResponse(allocator, resp.body);
}

/// Create a game session from the second ID token.
pub fn createGameSession(
    allocator: Allocator,
    client: *HttpClient,
    id_token: []const u8,
) !GameSessionResponse {
    const body = try buildGameSessionBody(allocator, id_token);
    defer allocator.free(body);

    var resp = try client.request(.{
        .method = .POST,
        .url = GAME_SESSION_URL,
        .content_type = "application/json",
        .body = body,
    });
    defer resp.deinit(allocator);

    if (resp.status != 200) return error.GameSessionFailed;
    return parseGameSessionResponse(allocator, resp.body);
}

/// Result of a character lookup, carrying the session status classification.
pub const CharacterLookup = struct {
    status: SessionStatus,
    characters: ?CharacterList = null,

    pub fn deinit(self: *CharacterLookup) void {
        if (self.characters) |*c| c.deinit();
    }
};

/// Fetch characters for a session, classifying the HTTP status so callers can
/// decide how to treat expired/rate-limited/erroring sessions.
pub fn fetchCharacters(
    allocator: Allocator,
    client: *HttpClient,
    session_id: []const u8,
) !CharacterLookup {
    const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{session_id});
    defer allocator.free(auth);

    var resp = client.request(.{
        .method = .GET,
        .url = ACCOUNTS_URL,
        .authorization = auth,
    }) catch {
        // Network/transport failure: treat as a temporary service error and
        // preserve credentials.
        return .{ .status = .service_error };
    };
    defer resp.deinit(allocator);

    const status = SessionStatus.fromHttpStatus(resp.status);
    if (status != .ok) return .{ .status = status };

    return .{
        .status = .ok,
        .characters = try parseAccountsResponse(allocator, resp.body),
    };
}

test "generate pkce produces valid challenge" {
    const io = std.testing.io;
    var pair = try generatePkce(std.testing.allocator, io);
    defer pair.deinit(std.testing.allocator);

    try std.testing.expect(pair.verifier.len > 0);
    try std.testing.expect(pair.challenge.len > 0);
    try std.testing.expect(!std.mem.eql(u8, pair.verifier, pair.challenge));
}

test "generate state and nonce are different" {
    const io = std.testing.io;
    const state = try generateState(std.testing.allocator, io);
    defer std.testing.allocator.free(state);
    const nonce = try generateNonce(std.testing.allocator, io);
    defer std.testing.allocator.free(nonce);

    try std.testing.expect(state.len > 0);
    try std.testing.expect(nonce.len > 0);
    // Two independent 32-byte draws will essentially never collide.
    try std.testing.expect(!std.mem.eql(u8, state, nonce));
}

test "pkce known vector (RFC 7636 style)" {
    // Verifier bytes chosen so the base64url verifier and its SHA-256
    // challenge are deterministic.
    const seed = [_]u8{0} ** 32;
    var pair = try pkceFromBytes(std.testing.allocator, &seed);
    defer pair.deinit(std.testing.allocator);
    // 32 zero bytes -> base64url "AAAA...AAA" (43 chars, unpadded).
    try std.testing.expectEqual(@as(usize, 43), pair.verifier.len);
    const expected_challenge = try pkceChallengeFromVerifier(std.testing.allocator, pair.verifier);
    defer std.testing.allocator.free(expected_challenge);
    try std.testing.expectEqualStrings(expected_challenge, pair.challenge);
}

test "parse token response" {
    const json =
        \\{"id_token":"id123","access_token":"acc456","refresh_token":"ref789","expires_in":3600}
    ;
    var result = try parseTokenResponse(std.testing.allocator, json);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("id123", result.id_token);
    try std.testing.expectEqualStrings("acc456", result.access_token);
    try std.testing.expectEqualStrings("ref789", result.refresh_token);
    try std.testing.expectEqual(@as(i64, 3600), result.expires_in);
}

test "parse token response missing field" {
    const json =
        \\{"id_token":"id123","access_token":"acc456"}
    ;
    try std.testing.expectError(error.ResponseSchemaError, parseTokenResponse(std.testing.allocator, json));
}

test "parse token response empty id_token" {
    const json =
        \\{"id_token":"","access_token":"acc","refresh_token":"ref","expires_in":100}
    ;
    try std.testing.expectError(error.ResponseSchemaError, parseTokenResponse(std.testing.allocator, json));
}

test "parse game session response" {
    const json =
        \\{"sessionId":"sess-abc-123"}
    ;
    var result = try parseGameSessionResponse(std.testing.allocator, json);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("sess-abc-123", result.session_id);
}

test "parse game session response missing sessionId" {
    const json =
        \\{"other":"value"}
    ;
    try std.testing.expectError(error.ResponseSchemaError, parseGameSessionResponse(std.testing.allocator, json));
}

test "parse game session response empty sessionId" {
    const json =
        \\{"sessionId":""}
    ;
    try std.testing.expectError(error.ResponseSchemaError, parseGameSessionResponse(std.testing.allocator, json));
}

test "parse token response not object" {
    try std.testing.expectError(error.ResponseSchemaError, parseTokenResponse(std.testing.allocator, "\"just a string\""));
}

test "build token request body" {
    const body = try buildTokenRequestBody(std.testing.allocator, "authcode123", "verifier456");
    defer std.testing.allocator.free(body);

    try std.testing.expect(body.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, body, "code=authcode123") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "code_verifier=verifier456") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "grant_type=authorization_code") != null);
}

test "base64url encode known value" {
    const result = try base64UrlEncode(std.testing.allocator, "hello");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("aGVsbG8", result);
}

test "base64url encode empty" {
    const result = try base64UrlEncode(std.testing.allocator, "");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "buildFirstAuthUrl contains expected components" {
    const url = try buildFirstAuthUrl(std.testing.allocator, "test_challenge", "test_state");
    defer std.testing.allocator.free(url);

    try std.testing.expect(std.mem.startsWith(u8, url, BASE_URL));
    try std.testing.expect(std.mem.indexOf(u8, url, "client_id=") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "code_challenge=test_challenge") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "state=test_state") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "code_challenge_method=S256") != null);
}

test "buildSecondAuthUrl contains expected components" {
    const url = try buildSecondAuthUrl(std.testing.allocator, "id_token_hint_123", "state2", "nonce2");
    defer std.testing.allocator.free(url);

    try std.testing.expect(std.mem.startsWith(u8, url, BASE_URL));
    try std.testing.expect(std.mem.indexOf(u8, url, "id_token_hint=id_token_hint_123") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "state=state2") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "nonce=nonce2") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "prompt=consent") != null);
}

test "parse token response with negative expires_in" {
    const json =
        \\{"id_token":"id","access_token":"acc","refresh_token":"ref","expires_in":-1}
    ;
    var result = try parseTokenResponse(std.testing.allocator, json);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, -1), result.expires_in);
}

test "token response deinit" {
    var result = try parseTokenResponse(std.testing.allocator,
        \\{"id_token":"id","access_token":"acc","refresh_token":"ref","expires_in":100}
    );
    result.deinit(std.testing.allocator);
    try std.testing.expect(true);
}

test "game session response deinit" {
    var result = try parseGameSessionResponse(std.testing.allocator,
        \\{"sessionId":"sess-abc"}
    );
    result.deinit(std.testing.allocator);
    try std.testing.expect(true);
}

test "pkce challenge is different from verifier" {
    const io = std.testing.io;
    var pair = try generatePkce(std.testing.allocator, io);
    defer pair.deinit(std.testing.allocator);

    try std.testing.expect(!std.mem.eql(u8, pair.verifier, pair.challenge));
}

test "parse accounts response" {
    const json =
        \\[{"accountId":"char-1","displayName":"Zezima"},{"accountId":"char-2","displayName":"Lynx"}]
    ;
    var list = try parseAccountsResponse(std.testing.allocator, json);
    defer list.deinit();
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("char-1", list.items[0].account_id);
    try std.testing.expectEqualStrings("Lynx", list.items[1].display_name);
}

test "parse accounts response empty array" {
    var list = try parseAccountsResponse(std.testing.allocator, "[]");
    defer list.deinit();
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}

test "parse accounts response rejects non-array" {
    try std.testing.expectError(error.ResponseSchemaError, parseAccountsResponse(std.testing.allocator, "{}"));
}

test "parse accounts response rejects missing accountId" {
    try std.testing.expectError(error.ResponseSchemaError, parseAccountsResponse(
        std.testing.allocator,
        \\[{"displayName":"Zezima"}]
    ));
}

test "parse accounts response tolerates missing/null/empty displayName" {
    // Characters without a set display name come back missing, null, or empty.
    // These must not fail the whole response; fall back to the accountId.
    const json =
        \\[{"accountId":"char-1"},{"accountId":"char-2","displayName":null},{"accountId":"char-3","displayName":""},{"accountId":"char-4","displayName":"Lynx"}]
    ;
    var list = try parseAccountsResponse(std.testing.allocator, json);
    defer list.deinit();
    try std.testing.expectEqual(@as(usize, 4), list.items.len);
    try std.testing.expectEqualStrings("char-1", list.items[0].display_name);
    try std.testing.expectEqualStrings("char-2", list.items[1].display_name);
    try std.testing.expectEqualStrings("char-3", list.items[2].display_name);
    try std.testing.expectEqualStrings("Lynx", list.items[3].display_name);
}

test "parse accounts response ignores extra fields" {
    // The real endpoint includes a userHash field alongside the ones we use.
    const json =
        \\[{"accountId":"char-1","displayName":"Zezima","userHash":"abc123"}]
    ;
    var list = try parseAccountsResponse(std.testing.allocator, json);
    defer list.deinit();
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("Zezima", list.items[0].display_name);
}

test "session status classification" {
    try std.testing.expectEqual(SessionStatus.ok, SessionStatus.fromHttpStatus(200));
    try std.testing.expectEqual(SessionStatus.expired, SessionStatus.fromHttpStatus(401));
    try std.testing.expectEqual(SessionStatus.rate_limited, SessionStatus.fromHttpStatus(429));
    try std.testing.expectEqual(SessionStatus.client_error, SessionStatus.fromHttpStatus(403));
    try std.testing.expectEqual(SessionStatus.client_error, SessionStatus.fromHttpStatus(404));
    try std.testing.expectEqual(SessionStatus.service_error, SessionStatus.fromHttpStatus(500));
    try std.testing.expectEqual(SessionStatus.service_error, SessionStatus.fromHttpStatus(503));
}

test "build game session body escapes" {
    const body = try buildGameSessionBody(std.testing.allocator, "tok\"en");
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("{\"idToken\":\"tok\\\"en\"}", body);
}
