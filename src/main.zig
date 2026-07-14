const builtin = @import("builtin");
const native_os = builtin.os.tag;

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const build_options = @import("build_options");

const thread_stack_size = 60 << 20;

pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        .ReleaseSafe, .ReleaseFast => .info,
        .ReleaseSmall => .err,
    },
};
pub const std_options_cwd = if (native_os == .wasi) wasi_cwd else null;

var preopens: std.process.Preopens = .empty;
pub fn wasi_cwd() Io.Dir {
    // Expect the first preopen to be current working directory.
    const cwd_fd: std.posix.fd_t = 3;
    assert(std.mem.eql(u8, preopens.map.keys()[cwd_fd], "."));
    return .{ .handle = cwd_fd };
}

/// This can be global since stdin is a singleton.
var stdin_buffer: [4096]u8 align(std.heap.page_size_min) = undefined;
/// This can be global since stdout is a singleton.
var stdout_buffer: [4096]u8 align(std.heap.page_size_min) = undefined;

const usage =
    \\Usage: openq
    \\
    \\Commands:
    \\
    \\  version         Print version number and exit
    \\  help            Print this help and exit
    \\
    \\General Options:
    \\
    \\  -h, --help      Print command-specific usage
    \\
;

const use_safe_allocator = build_options.debug_gpa or
    (native_os != .wasi and switch (builtin.mode) {
        .Debug, .ReleaseSafe => true,
        .ReleaseFast, .ReleaseSmall => false,
    });

var safe_allocator: std.heap.DebugAllocator(.{
    .stack_trace_frames = build_options.mem_leak_frames,
}) = .init;

pub fn main(init: std.process.Init.Minimal) !void {
    const root_gpa = if (use_safe_allocator)
        safe_allocator.allocator()
    else if (native_os == .wasi)
        std.heap.wasm_allocator
    else
        std.heap.smp_allocator;
    defer if (use_safe_allocator) {
        _ = safe_allocator.deinit();
    };
    var io_impl: IoImpl = undefined;
    switch (build_options.io_mode) {
        .threaded => io_impl = .init(root_gpa, .{
            .stack_size = thread_stack_size,

            .argv0 = .init(init.args),
            .environ = init.environ,
        }),
        .evented => try io_impl.init(root_gpa, .{
            .argv0 = .init(init.args),
            .environ = init.environ,

            .backing_allocator_needs_mutex = false,
        }),
    }
    defer io_impl.deinit();
    const io = io_impl.io();
    const gpa = switch (build_options.io_mode) {
        .threaded => root_gpa,
        .evented => io_impl.allocator(),
    };
    var arena_instance: std.heap.ArenaAllocator = .init(gpa);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const args = try init.args.toSlice(arena);

    var environ_map = init.environ.createMap(arena) catch |err|
        std.process.fatal("failed to parse environment: {t}", .{err});

    if (native_os == .wasi) {
        preopens = try .init(arena);
    }

    return mainArgs(gpa, arena, io, args, &environ_map);
}

const Cmd = enum {
    version,

    help,
    @"-h",
    @"--help",
};

fn mainArgs(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    args: []const [:0]const u8,
    environ_map: *std.process.Environ.Map,
) !void {
    _ = gpa; // autofix
    _ = arena; // autofix
    _ = environ_map; // autofix
    if (args.len <= 1) return;

    const cmd = args[1];
    const cmd_args = args[2..];
    _ = cmd_args; // autofix
    switch (std.meta.stringToEnum(Cmd, cmd) orelse {
        std.debug.print("{s}\n", .{usage});
        std.process.fatal("unknown command: {s}", .{cmd});
    }) {
        .version => {
            try Io.File.stdout().writeStreamingAll(io, build_options.version ++ "\n");
        },
        .help, .@"-h", .@"--help" => {
            try Io.File.stdout().writeStreamingAll(io, usage);
        },
    }
}

const IoImpl = switch (build_options.io_mode) {
    .threaded => Io.Threaded,
    .evented => Io.Evented,
};
