const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const build_options = @import("build_options");

pub fn main(init: std.process.Init) !void {
    _ = init; // autofix
    std.log.info("version: {s}", .{build_options.version});
}
