const std = @import("std");
const Allocator = std.mem.Allocator;

pub const JwtPayload = struct {
    sub: []const u8,
    nonce: ?[]const u8 = null,
    nickname: ?[]const u8 = null,
    auth_time: ?i64 = null,
};

pub fn parseJwtPayload(allocator: Allocator, token: []const u8) !JwtPayload {
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next() orelse return error.TokenFormatError;
    const payload_b64 = parts.next() orelse return error.TokenFormatError;

    if (parts.next() == null) {
        return error.TokenFormatError;
    }

    const payload_json = try base64UrlDecodeAlloc(allocator, payload_b64);
    defer allocator.free(payload_json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.TokenFormatError;
    const obj = parsed.value.object;

    const sub_val = obj.get("sub") orelse return error.TokenFormatError;
    if (sub_val != .string or sub_val.string.len == 0) return error.TokenFormatError;

    var result = JwtPayload{
        .sub = try allocator.dupe(u8, sub_val.string),
    };

    if (obj.get("nonce")) |n| {
        if (n == .string) {
            result.nonce = try allocator.dupe(u8, n.string);
        }
    }

    if (obj.get("nickname")) |n| {
        if (n == .string) {
            result.nickname = try allocator.dupe(u8, n.string);
        }
    }

    if (obj.get("auth_time")) |at| {
        if (at == .integer) {
            result.auth_time = at.integer;
        }
    }

    return result;
}

pub fn freeJwtPayload(allocator: Allocator, payload: *JwtPayload) void {
    allocator.free(payload.sub);
    if (payload.nonce) |n| allocator.free(n);
    if (payload.nickname) |n| allocator.free(n);
}

pub fn splitNickname(allocator: Allocator, nickname: []const u8) !struct { display_name: []const u8, suffix: []const u8 } {
    const hash_pos = std.mem.lastIndexOfScalar(u8, nickname, '#') orelse return error.TokenFormatError;
    if (hash_pos == 0 or hash_pos == nickname.len - 1) return error.TokenFormatError;
    return .{
        .display_name = try allocator.dupe(u8, nickname[0..hash_pos]),
        .suffix = try allocator.dupe(u8, nickname[hash_pos + 1 ..]),
    };
}

fn base64UrlDecodeAlloc(allocator: Allocator, b64: []const u8) ![]const u8 {
    var padded = std.ArrayList(u8).empty;
    defer padded.deinit(allocator);

    try padded.appendSlice(allocator, b64);
    const remainder = padded.items.len % 4;
    if (remainder != 0) {
        try padded.appendNTimes(allocator, '=', 4 - remainder);
    }

    for (padded.items) |*c| {
        if (c.* == '-') c.* = '+';
        if (c.* == '_') c.* = '/';
    }

    const dec = std.base64.standard.Decoder;
    const dest_len = try dec.calcSizeForSlice(padded.items);
    const dest = try allocator.alloc(u8, dest_len);
    errdefer allocator.free(dest);
    try dec.decode(dest, padded.items);
    return dest;
}

fn encodeBase64Url(allocator: Allocator, input: []const u8) ![]const u8 {
    const enc = std.base64.url_safe_no_pad;
    const encoded_len = enc.Encoder.calcSize(input.len);
    const buf = try allocator.alloc(u8, encoded_len);
    _ = enc.Encoder.encode(buf, input);
    return buf;
}

test "parse valid jwt payload" {
    const payload =
        \\{"sub":"user-123","nonce":"abc","nickname":"TestUser#1234","auth_time":1234567890}
    ;
    const b64 = try encodeBase64Url(std.testing.allocator, payload);
    defer std.testing.allocator.free(b64);

    const token = try std.fmt.allocPrint(std.testing.allocator, "header.{s}.sig", .{b64});
    defer std.testing.allocator.free(token);

    var result = try parseJwtPayload(std.testing.allocator, token);
    defer freeJwtPayload(std.testing.allocator, &result);

    try std.testing.expectEqualStrings("user-123", result.sub);
    try std.testing.expectEqualStrings("abc", result.nonce.?);
    try std.testing.expectEqualStrings("TestUser#1234", result.nickname.?);
    try std.testing.expectEqual(@as(i64, 1234567890), result.auth_time.?);
}

test "split nickname" {
    const allocator = std.testing.allocator;
    const result = try splitNickname(allocator, "TestUser#1234");
    defer allocator.free(result.display_name);
    defer allocator.free(result.suffix);

    try std.testing.expectEqualStrings("TestUser", result.display_name);
    try std.testing.expectEqualStrings("1234", result.suffix);
}

test "split nickname rejects no hash" {
    try std.testing.expectError(error.TokenFormatError, splitNickname(std.testing.allocator, "NoHashHere"));
}

test "split nickname rejects leading hash" {
    try std.testing.expectError(error.TokenFormatError, splitNickname(std.testing.allocator, "#leading"));
}

test "split nickname rejects trailing hash" {
    try std.testing.expectError(error.TokenFormatError, splitNickname(std.testing.allocator, "trailing#"));
}

test "parse jwt missing sub" {
    const payload =
        \\{"nonce":"abc"}
    ;
    const b64 = try encodeBase64Url(std.testing.allocator, payload);
    defer std.testing.allocator.free(b64);

    const token = try std.fmt.allocPrint(std.testing.allocator, "header.{s}.sig", .{b64});
    defer std.testing.allocator.free(token);

    try std.testing.expectError(error.TokenFormatError, parseJwtPayload(std.testing.allocator, token));
}

test "parse jwt too few parts" {
    try std.testing.expectError(error.TokenFormatError, parseJwtPayload(std.testing.allocator, "only.two"));
}

test "parse jwt single part" {
    try std.testing.expectError(error.TokenFormatError, parseJwtPayload(std.testing.allocator, "onlyone"));
}

test "parse jwt with only sub" {
    const payload =
        \\{"sub":"user-only"}
    ;
    const b64 = try encodeBase64Url(std.testing.allocator, payload);
    defer std.testing.allocator.free(b64);

    const token = try std.fmt.allocPrint(std.testing.allocator, "header.{s}.sig", .{b64});
    defer std.testing.allocator.free(token);

    var result = try parseJwtPayload(std.testing.allocator, token);
    defer freeJwtPayload(std.testing.allocator, &result);

    try std.testing.expectEqualStrings("user-only", result.sub);
    try std.testing.expect(result.nonce == null);
    try std.testing.expect(result.nickname == null);
    try std.testing.expect(result.auth_time == null);
}

test "freeJwtPayload with nulls" {
    var payload = JwtPayload{ .sub = try std.testing.allocator.dupe(u8, "test") };
    defer freeJwtPayload(std.testing.allocator, &payload);
}

test "split nickname multiple hashes" {
    const result = try splitNickname(std.testing.allocator, "User#Name#1234");
    defer std.testing.allocator.free(result.display_name);
    defer std.testing.allocator.free(result.suffix);

    try std.testing.expectEqualStrings("User#Name", result.display_name);
    try std.testing.expectEqualStrings("1234", result.suffix);
}

test "split nickname minimal valid" {
    const result = try splitNickname(std.testing.allocator, "a#b");
    defer std.testing.allocator.free(result.display_name);
    defer std.testing.allocator.free(result.suffix);

    try std.testing.expectEqualStrings("a", result.display_name);
    try std.testing.expectEqualStrings("b", result.suffix);
}

test "base64url round-trip" {
    const original = "hello world! 123 @#$%";
    const encoded = try encodeBase64Url(std.testing.allocator, original);
    defer std.testing.allocator.free(encoded);

    const decoded = try base64UrlDecodeAlloc(std.testing.allocator, encoded);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqualStrings(original, decoded);
}
