const std = @import("std");

const Self = @This();

allocator: std.mem.Allocator,
error_message: ?[]const u8 = null,
stdout: std.fs.File.Writer,
stderr: std.fs.File.Writer,

const RuntimeError = error{
    Unknown,
};

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .stdout = std.io.getStdOut().writer(),
        .stderr = std.io.getStdErr().writer(),
    };
}

pub fn deinit(self: Self) void {
    _ = self;
}

pub fn interpret(self: *Self, source: []const u8) RuntimeError!void {
    _ = source;
    self.error_message = null;
}
