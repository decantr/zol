const std = @import("std");

pub const Account = struct {
    sub: []const u8,
    display_name: []const u8,
    suffix: []const u8,
    session_id: []const u8,

    pub const empty: Account = .{
        .sub = "",
        .display_name = "",
        .suffix = "",
        .session_id = "",
    };
};

pub const AccountStore = struct {
    allocator: std.mem.Allocator,
    string_arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) AccountStore {
        return AccountStore{
            .allocator = allocator,
            .string_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *AccountStore) void {
        self.string_arena.deinit();
    }
};
