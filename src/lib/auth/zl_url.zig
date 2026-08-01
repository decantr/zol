const std = @import("std");
const Allocator = std.mem.Allocator;

/// Maximum length of a callback URL we are willing to parse. Provider
/// responses are untrusted input, so we bound everything.
pub const MAX_URL_LEN = 8192;

fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => true,
        else => false,
    };
}

/// Percent-encode a string for use as a URL query value. Every byte that is
/// not RFC 3986 "unreserved" is encoded, including spaces (as %20, not '+').
pub fn percentEncode(allocator: Allocator, input: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (input) |c| {
        if (isUnreserved(c)) {
            try out.append(allocator, c);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, upperHex(c >> 4));
            try out.append(allocator, upperHex(c & 0x0f));
        }
    }
    return out.toOwnedSlice(allocator);
}

/// application/x-www-form-urlencoded encoding of a single key=value pair.
/// Spaces are encoded as '+' per the HTML form serialization algorithm.
pub fn formEncode(allocator: Allocator, key: []const u8, value: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try formEncodeComponent(allocator, &out, key);
    try out.append(allocator, '=');
    try formEncodeComponent(allocator, &out, value);
    return out.toOwnedSlice(allocator);
}

fn formEncodeComponent(allocator: Allocator, out: *std.ArrayList(u8), input: []const u8) !void {
    for (input) |c| {
        if (isUnreserved(c)) {
            try out.append(allocator, c);
        } else if (c == ' ') {
            try out.append(allocator, '+');
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, upperHex(c >> 4));
            try out.append(allocator, upperHex(c & 0x0f));
        }
    }
}

fn upperHex(nibble: u8) u8 {
    return "0123456789ABCDEF"[nibble & 0x0f];
}

fn fromHex(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Percent-decode a URL component. '+' is NOT treated as space here; callers
/// dealing with form bodies should decode '+' separately if needed. OAuth
/// callback values do not use '+' for space.
pub fn percentDecode(allocator: Allocator, input: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c == '%') {
            if (i + 2 >= input.len) return error.InvalidPercentEncoding;
            const hi = fromHex(input[i + 1]) orelse return error.InvalidPercentEncoding;
            const lo = fromHex(input[i + 2]) orelse return error.InvalidPercentEncoding;
            try out.append(allocator, (hi << 4) | lo);
            i += 3;
        } else {
            try out.append(allocator, c);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// A single parsed key/value pair with decoded value. Keys are compared
/// literally (already lowercase in the OAuth spec).
pub const Param = struct {
    key: []const u8,
    value: []const u8,
};

/// Parsed set of query/fragment parameters. Owns the decoded values.
pub const ParamMap = struct {
    allocator: Allocator,
    params: std.ArrayList(Param),

    pub fn deinit(self: *ParamMap) void {
        for (self.params.items) |p| {
            self.allocator.free(p.key);
            self.allocator.free(p.value);
        }
        self.params.deinit(self.allocator);
    }

    /// Returns the single value for `key`. Errors if the key is missing or
    /// appears more than once (duplicate parameters are rejected as malformed).
    pub fn getUnique(self: *const ParamMap, key: []const u8) !?[]const u8 {
        var found: ?[]const u8 = null;
        for (self.params.items) |p| {
            if (std.mem.eql(u8, p.key, key)) {
                if (found != null) return error.DuplicateParameter;
                found = p.value;
            }
        }
        return found;
    }

    /// Like `getUnique` but requires the value to be present and nonempty.
    pub fn requireUnique(self: *const ParamMap, key: []const u8) ![]const u8 {
        const v = (try self.getUnique(key)) orelse return error.MissingParameter;
        if (v.len == 0) return error.EmptyParameter;
        return v;
    }
};

/// Parse an `x=1&y=2` style component into decoded key/value pairs.
pub fn parseParams(allocator: Allocator, raw: []const u8) !ParamMap {
    return parseParamsSep(allocator, raw, '&');
}

/// Like `parseParams` but with a configurable pair separator. OAuth query and
/// fragment components use `&`; the Jagex custom URI scheme uses `,`.
pub fn parseParamsSep(allocator: Allocator, raw: []const u8, separator: u8) !ParamMap {
    var map = ParamMap{
        .allocator = allocator,
        .params = std.ArrayList(Param).empty,
    };
    errdefer map.deinit();

    if (raw.len == 0) return map;

    var it = std.mem.splitScalar(u8, raw, separator);
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=');
        const key_raw = if (eq) |i| pair[0..i] else pair;
        const val_raw = if (eq) |i| pair[i + 1 ..] else "";
        const key = try percentDecode(allocator, key_raw);
        errdefer allocator.free(key);
        const value = try percentDecode(allocator, val_raw);
        errdefer allocator.free(value);
        try map.params.append(allocator, .{ .key = key, .value = value });
    }
    return map;
}

/// Result of parsing the first OAuth callback URL.
pub const FirstCallback = struct {
    code: []const u8,
    state: []const u8,

    pub fn deinit(self: *FirstCallback, allocator: Allocator) void {
        allocator.free(self.code);
        allocator.free(self.state);
    }
};

/// The Jagex desktop custom URI scheme. Depending on the account's login
/// method, the first callback is delivered either as the HTTPS launcher
/// redirect or through this registered custom scheme.
const JAGEX_SCHEME = "jagex:";
const HTTPS_FIRST_PREFIX = "https://secure.runescape.com/m=weblogin/launcher-redirect";

/// Parse and strictly validate the first callback. Two shapes are accepted:
///
///   1. HTTPS launcher redirect (standard OAuth):
///      https://secure.runescape.com/m=weblogin/launcher-redirect?code=...&state=...
///      Values are `&`-separated query parameters.
///
///   2. Jagex custom URI scheme (used by some login methods):
///      jagex:code=...,state=...,intent=social_auth
///      Values are `,`-separated parameters and there is no `?`.
///
/// Exact scheme/host/path is required. OAuth error responses are rejected.
pub fn parseFirstCallback(allocator: Allocator, url: []const u8) !FirstCallback {
    const trimmed = std.mem.trim(u8, url, " \t\r\n");
    if (trimmed.len > MAX_URL_LEN) return error.UrlTooLong;

    var params = blk: {
        if (std.mem.startsWith(u8, trimmed, JAGEX_SCHEME)) {
            // Custom scheme: comma-separated parameters after "jagex:".
            const rest = trimmed[JAGEX_SCHEME.len..];
            if (rest.len == 0) return error.CallbackFormatError;
            break :blk try parseParamsSep(allocator, rest, ',');
        } else if (std.mem.startsWith(u8, trimmed, HTTPS_FIRST_PREFIX)) {
            const rest = trimmed[HTTPS_FIRST_PREFIX.len..];
            if (rest.len == 0 or rest[0] != '?') return error.CallbackFormatError;
            break :blk try parseParamsSep(allocator, rest[1..], '&');
        } else {
            return error.CallbackOriginMismatch;
        }
    };
    defer params.deinit();

    try rejectOAuthError(&params);

    const code = try params.requireUnique("code");
    const state = try params.requireUnique("state");

    return .{
        .code = try allocator.dupe(u8, code),
        .state = try allocator.dupe(u8, state),
    };
}

/// Result of parsing the second OAuth callback URL.
pub const SecondCallback = struct {
    code: []const u8,
    state: []const u8,
    id_token: []const u8,

    pub fn deinit(self: *SecondCallback, allocator: Allocator) void {
        allocator.free(self.code);
        allocator.free(self.state);
        allocator.free(self.id_token);
    }
};

/// Parse and strictly validate the second callback:
///   http://localhost/#code=...&state=...&id_token=...
/// The response values are in the URL fragment, not the query. Exact scheme,
/// host, port (default), and path (/) are required.
pub fn parseSecondCallback(allocator: Allocator, url: []const u8) !SecondCallback {
    const trimmed = std.mem.trim(u8, url, " \t\r\n");
    if (trimmed.len > MAX_URL_LEN) return error.UrlTooLong;

    // Accept both "http://localhost/#..." and "http://localhost#...".
    const scheme = "http://localhost";
    if (!std.mem.startsWith(u8, trimmed, scheme)) return error.CallbackOriginMismatch;

    var rest = trimmed[scheme.len..];
    // Optional trailing path segment "/" before the fragment.
    if (rest.len > 0 and rest[0] == '/') {
        rest = rest[1..];
    }
    if (rest.len == 0 or rest[0] != '#') return error.CallbackFragmentMissing;
    const fragment = rest[1..];

    var params = try parseParams(allocator, fragment);
    defer params.deinit();

    try rejectOAuthError(&params);

    const code = try params.requireUnique("code");
    const state = try params.requireUnique("state");
    const id_token = try params.requireUnique("id_token");

    return .{
        .code = try allocator.dupe(u8, code),
        .state = try allocator.dupe(u8, state),
        .id_token = try allocator.dupe(u8, id_token),
    };
}

fn rejectOAuthError(params: *const ParamMap) !void {
    if (try params.getUnique("error")) |_| {
        return error.OAuthError;
    }
}

/// Constant-time comparison for state/nonce/subject continuity checks.
pub fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| {
        diff |= x ^ y;
    }
    return diff == 0;
}

test "percent encode reserved characters" {
    const r = try percentEncode(std.testing.allocator, "a b/c?d=e&f");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("a%20b%2Fc%3Fd%3De%26f", r);
}

test "percent encode leaves unreserved" {
    const r = try percentEncode(std.testing.allocator, "AZaz09-_.~");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("AZaz09-_.~", r);
}

test "form encode uses plus for space" {
    const r = try formEncode(std.testing.allocator, "grant type", "auth code");
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("grant+type=auth+code", r);
}

test "percent decode round trip" {
    const enc = try percentEncode(std.testing.allocator, "hello world!@#");
    defer std.testing.allocator.free(enc);
    const dec = try percentDecode(std.testing.allocator, enc);
    defer std.testing.allocator.free(dec);
    try std.testing.expectEqualStrings("hello world!@#", dec);
}

test "percent decode invalid" {
    try std.testing.expectError(error.InvalidPercentEncoding, percentDecode(std.testing.allocator, "%zz"));
    try std.testing.expectError(error.InvalidPercentEncoding, percentDecode(std.testing.allocator, "%4"));
}

test "parse params unique and duplicate" {
    var m = try parseParams(std.testing.allocator, "a=1&b=2&a=3");
    defer m.deinit();
    try std.testing.expectEqualStrings("2", (try m.getUnique("b")).?);
    try std.testing.expectError(error.DuplicateParameter, m.getUnique("a"));
}

test "parse first callback valid" {
    var cb = try parseFirstCallback(
        std.testing.allocator,
        "https://secure.runescape.com/m=weblogin/launcher-redirect?code=abc&state=xyz",
    );
    defer cb.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("abc", cb.code);
    try std.testing.expectEqualStrings("xyz", cb.state);
}

test "parse first callback accepts jagex custom scheme" {
    // Shape observed from the provider for some login methods. The key
    // material below is synthetic; only the format matters.
    var cb = try parseFirstCallback(
        std.testing.allocator,
        "jagex:code=SYNTH_CODE_000,state=SYNTH_STATE_111,intent=social_auth",
    );
    defer cb.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("SYNTH_CODE_000", cb.code);
    try std.testing.expectEqualStrings("SYNTH_STATE_111", cb.state);
}

test "parse first callback jagex scheme ignores extra intent field" {
    var cb = try parseFirstCallback(
        std.testing.allocator,
        "jagex:code=c,state=s,intent=social_auth",
    );
    defer cb.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("c", cb.code);
    try std.testing.expectEqualStrings("s", cb.state);
}

test "parse first callback jagex scheme rejects oauth error" {
    try std.testing.expectError(error.OAuthError, parseFirstCallback(
        std.testing.allocator,
        "jagex:error=access_denied,state=s",
    ));
}

test "parse first callback jagex scheme missing state" {
    try std.testing.expectError(error.MissingParameter, parseFirstCallback(
        std.testing.allocator,
        "jagex:code=c,intent=social_auth",
    ));
}

test "parse first callback jagex scheme rejects duplicate code" {
    try std.testing.expectError(error.DuplicateParameter, parseFirstCallback(
        std.testing.allocator,
        "jagex:code=c1,code=c2,state=s",
    ));
}

test "parse first callback jagex scheme empty payload" {
    try std.testing.expectError(error.CallbackFormatError, parseFirstCallback(
        std.testing.allocator,
        "jagex:",
    ));
}

test "parse first callback rejects wrong origin" {
    try std.testing.expectError(error.CallbackOriginMismatch, parseFirstCallback(
        std.testing.allocator,
        "http://secure.runescape.com/m=weblogin/launcher-redirect?code=abc&state=xyz",
    ));
    try std.testing.expectError(error.CallbackOriginMismatch, parseFirstCallback(
        std.testing.allocator,
        "https://evil.com/m=weblogin/launcher-redirect?code=abc&state=xyz",
    ));
}

test "parse first callback rejects oauth error" {
    try std.testing.expectError(error.OAuthError, parseFirstCallback(
        std.testing.allocator,
        "https://secure.runescape.com/m=weblogin/launcher-redirect?error=access_denied&state=xyz",
    ));
}

test "parse first callback missing code" {
    try std.testing.expectError(error.MissingParameter, parseFirstCallback(
        std.testing.allocator,
        "https://secure.runescape.com/m=weblogin/launcher-redirect?state=xyz",
    ));
}

test "parse first callback duplicate state" {
    try std.testing.expectError(error.DuplicateParameter, parseFirstCallback(
        std.testing.allocator,
        "https://secure.runescape.com/m=weblogin/launcher-redirect?code=a&state=x&state=y",
    ));
}

test "parse second callback valid with slash" {
    var cb = try parseSecondCallback(
        std.testing.allocator,
        "http://localhost/#code=c1&state=s1&id_token=t1",
    );
    defer cb.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("c1", cb.code);
    try std.testing.expectEqualStrings("s1", cb.state);
    try std.testing.expectEqualStrings("t1", cb.id_token);
}

test "parse second callback valid without slash" {
    var cb = try parseSecondCallback(
        std.testing.allocator,
        "http://localhost#code=c1&state=s1&id_token=t1",
    );
    defer cb.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("t1", cb.id_token);
}

test "parse second callback rejects query instead of fragment" {
    try std.testing.expectError(error.CallbackFragmentMissing, parseSecondCallback(
        std.testing.allocator,
        "http://localhost/?code=c1&state=s1&id_token=t1",
    ));
}

test "parse second callback rejects https" {
    try std.testing.expectError(error.CallbackOriginMismatch, parseSecondCallback(
        std.testing.allocator,
        "https://localhost/#code=c1&state=s1&id_token=t1",
    ));
}

test "parse second callback missing id_token" {
    try std.testing.expectError(error.MissingParameter, parseSecondCallback(
        std.testing.allocator,
        "http://localhost/#code=c1&state=s1",
    ));
}

test "constant time eql" {
    try std.testing.expect(constantTimeEql("abc", "abc"));
    try std.testing.expect(!constantTimeEql("abc", "abd"));
    try std.testing.expect(!constantTimeEql("abc", "ab"));
}
