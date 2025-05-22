const std = @import("std");
const builtin = @import("builtin");
const debug = std.debug;
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const process = std.process;
const Allocator = mem.Allocator;

const build_options = @import("build_options");

pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        .ReleaseSafe, .ReleaseFast => .info,
        .ReleaseSmall => .err,
    },
};

var wasi_preopens: fs.wasi.Preopens = undefined;

const fatal = process.fatal;
const cleanExit = process.cleanExit;

const usage =
    \\Usage: openq [command] [options]
    \\
    \\Commands:
    \\
    \\  help        Print this help and exit
    \\  version     Print version number and exit
    \\
    \\Options:
    \\
    \\  -h, --help  Print command-specific usage
    \\
;

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    const gpa, const is_debug = gpa: {
        if (builtin.os.tag == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };
    var arena_instance = std.heap.ArenaAllocator.init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const args = try process.argsAlloc(arena);

    if (builtin.os.tag == .wasi) {
        wasi_preopens = try fs.wasi.preopensAlloc(arena);
    }

    return mainArgs(gpa, arena, args);
}

fn mainArgs(gpa: Allocator, arena: Allocator, args: []const []const u8) !void {
    _ = arena; // autofix
    _ = gpa; // autofix
    if (args.len <= 1) {
        debug.print("{s}\n", .{usage});
        fatal("expected command argument", .{});
    }

    const cmd = args[1];
    const cmd_args = args[2..];
    _ = cmd_args; // autofix
    if (mem.eql(u8, cmd, "version")) {
        try io.getStdOut().writeAll(build_options.version ++ "\n");
    } else if (mem.eql(u8, cmd, "help") or mem.eql(u8, cmd, "-h") or mem.eql(u8, cmd, "--help")) {
        try io.getStdOut().writeAll(usage);
    } else {
        debug.print("{s}\n", .{usage});
        fatal("unknown command: {s}", .{cmd});
    }
}
