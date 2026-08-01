//! By convention, root.zig is the root source file when making a package.
const std = @import("std");

pub const url = @import("lib/auth/zl_url.zig");
pub const oauth = @import("lib/auth/oauth.zig");
pub const jwt = @import("lib/auth/jwt.zig");
pub const browser = @import("lib/auth/browser_open.zig");
pub const http_client = @import("lib/http_client.zig");
pub const accounts = @import("lib/accounts.zig");
pub const character_cache = @import("lib/character_cache.zig");
pub const config = @import("lib/config.zig");

test {
    // Ensure the test runner discovers tests in every library module.
    std.testing.refAllDecls(url);
    std.testing.refAllDecls(oauth);
    std.testing.refAllDecls(jwt);
    std.testing.refAllDecls(browser);
    std.testing.refAllDecls(http_client);
    std.testing.refAllDecls(accounts);
    std.testing.refAllDecls(character_cache);
    std.testing.refAllDecls(config);
}
