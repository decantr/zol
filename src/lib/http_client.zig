const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = std.http;
const build_options = @import("build_options");

pub const HttpMethod = enum {
    GET,
    POST,
};

/// Maximum response body we will buffer. Provider responses are untrusted;
/// everything is bounded.
pub const MAX_RESPONSE_BYTES: usize = 4 * 1024 * 1024;

pub const HttpRequest = struct {
    method: HttpMethod,
    url: []const u8,
    content_type: ?[]const u8 = null,
    authorization: ?[]const u8 = null,
    body: ?[]const u8 = null,
};

pub const HttpResponse = struct {
    status: u16,
    body: []const u8,

    pub fn deinit(self: *HttpResponse, allocator: Allocator) void {
        allocator.free(self.body);
    }
};

pub const HttpClient = struct {
    allocator: Allocator,
    client: http.Client,
    io: Io,

    pub fn init(allocator: Allocator, io: Io) HttpClient {
        return .{
            .allocator = allocator,
            .client = .{ .allocator = allocator, .io = io },
            .io = io,
        };
    }

    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
    }

    pub fn request(self: *HttpClient, req: HttpRequest) !HttpResponse {
        // HTTPS-only policy: the app never sends secrets over plaintext. The
        // registered http://localhost callback is validated as a string
        // elsewhere and is never fetched.
        if (!std.mem.startsWith(u8, req.url, "https://")) {
            return error.InsecureUrlRejected;
        }

        var headers: http.Client.Request.Headers = .{};
        const ua = "zol/" ++ build_options.version;
        headers.user_agent = .{ .override = ua };

        if (req.authorization) |auth| {
            headers.authorization = .{ .override = auth };
        }
        if (req.content_type) |ct| {
            headers.content_type = .{ .override = ct };
        }

        var extra_headers_buf: [1]http.Header = undefined;
        var extra_headers_len: usize = 0;
        extra_headers_buf[extra_headers_len] = .{ .name = "Accept", .value = "application/json" };
        extra_headers_len += 1;

        var aw: Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        const result = self.client.fetch(.{
            .location = .{ .url = req.url },
            .method = switch (req.method) {
                .GET => .GET,
                .POST => .POST,
            },
            .headers = headers,
            .extra_headers = extra_headers_buf[0..extra_headers_len],
            .payload = req.body,
            .response_writer = &aw.writer,
            // Do not silently follow cross-origin redirects with sensitive
            // headers attached.
            .redirect_behavior = .not_allowed,
            .keep_alive = false,
        }) catch |err| switch (err) {
            error.StreamTooLong => return error.ResponseTooLarge,
            else => return error.HttpTransportError,
        };

        if (aw.writer.buffered().len > MAX_RESPONSE_BYTES) {
            return error.ResponseTooLarge;
        }

        const status: u16 = @intFromEnum(result.status);

        return .{
            .status = status,
            .body = try aw.toOwnedSlice(),
        };
    }
};

test "http client rejects insecure url" {
    const io = std.testing.io;
    var client = HttpClient.init(std.testing.allocator, io);
    defer client.deinit();
    try std.testing.expectError(error.InsecureUrlRejected, client.request(.{
        .method = .GET,
        .url = "http://example.com",
    }));
}
