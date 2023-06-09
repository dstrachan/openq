const std = @import("std");

const Compiler = @import("compiler.zig");

const Self = @This();

allocator: std.mem.Allocator,
stdout: std.fs.File.Writer,
stderr: std.fs.File.Writer,

const RuntimeError = error{
    Unknown,
    CompilationFailed,
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
    const compiler = Compiler.init(self.*);
    compiler.compile(source) catch return RuntimeError.CompilationFailed;
}
