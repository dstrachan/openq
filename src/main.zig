const builtin = @import("builtin");
const native_os = builtin.os.tag;

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const q = @import("root.zig");
const Ast = q.Ast;
const Value = q.Value;
const Vm = q.Vm;

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

    if (args.len <= 1) return cmdRepl(gpa, io, &environ_map, null, &.{}, false, &.{}, args);
    return mainArgs(gpa, arena, io, args, &environ_map);
}

const Cmd = enum {
    version,

    help,
    @"-h",
    @"--help",
};

/// The command line as q reads it: the first argument, unless it starts with `-`, is
/// the script; `-q` is quiet; q's own options (`-c 10 20`, `-P 3`, `-S 5`...) are applied
/// and consumed with their values; everything else is left for `.z.x`.
fn mainArgs(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    args: []const [:0]const u8,
    environ_map: *std.process.Environ.Map,
) !void {
    if (std.meta.stringToEnum(Cmd, args[1])) |cmd| switch (cmd) {
        .version => return Io.File.stdout().writeStreamingAll(io, build_options.version ++ "\n"),
        .help, .@"-h", .@"--help" => return Io.File.stdout().writeStreamingAll(io, usage),
    };
    const script: ?[]const u8 = if (args[1][0] != '-') args[1] else null;
    var rest = args[if (script != null) 2 else 1..];
    var quiet = false;
    var settings: std.ArrayList([]const u8) = .empty;
    var script_args: std.ArrayList([:0]const u8) = .empty;
    while (rest.len > 0) {
        const arg = rest[0];
        rest = rest[1..];
        if (arg.len == 2 and arg[0] == '-') {
            // The count of values each of q's options takes.
            const values: ?usize = switch (arg[1]) {
                'b', 'l', 'L', 'q' => 0,
                'c', 'C' => 2,
                'e', 'E', 'g', 'm', 'o', 'p', 'P', 'r', 's', 'S', 't', 'T', 'u', 'U', 'w', 'W', 'z' => 1,
                else => null,
            };
            if (values) |n| {
                if (arg[1] == 'q') quiet = true;
                const taken = @min(n, rest.len);
                // Settings the VM has a command for are applied at startup.
                if (std.mem.indexOfScalar(u8, "cCeEgoPStTWz", arg[1]) != null) {
                    var text: std.ArrayList(u8) = .empty;
                    try text.append(arena, arg[1]);
                    for (rest[0..taken]) |v| {
                        try text.append(arena, ' ');
                        try text.appendSlice(arena, v);
                    }
                    try settings.append(arena, text.items);
                }
                rest = rest[taken..];
                continue;
            }
        }
        try script_args.append(arena, arg);
    }
    return cmdRepl(gpa, io, environ_map, script, script_args.items, quiet, settings.items, args);
}

const banner = "OpenQ " ++ build_options.version ++ " " ++
    @tagName(builtin.mode) ++ " " ++ @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag) ++ "\n";

fn cmdRepl(gpa: Allocator, io: Io, environ_map: *std.process.Environ.Map, script: ?[]const u8, script_args: []const [:0]const u8, quiet: bool, settings: []const []const u8, argv: []const [:0]const u8) !void {
    var stdin_reader = Io.File.stdin().reader(io, &stdin_buffer);
    const stdin = &stdin_reader.interface;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const vm: *Vm = Vm.initOptions(io, gpa, stdout, .{
        .environ = environ_map,
        .command_line = argv,
        .arguments = script_args,
        .script = script,
        .quiet = quiet,
        .settings = settings,
    }) catch |err| switch (err) {
        error.QkNotFound => std.process.fatal("q.k not found: set QHOME or run where q.k is", .{}),
        else => return err,
    };
    defer vm.deinit();

    // The script runs before the console starts.
    if (script) |path| {
        const value = vm.loadScript(path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.signal, error.identifier => {
                std.debug.print("'{s}\n", .{vm.signal_message orelse @errorName(err)});
                std.process.exit(1);
            },
            else => {
                std.debug.print("'{t}\n", .{err});
                std.process.exit(1);
            },
        };
        value.deref(gpa);
    }

    var buffer: Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();

    if (try Io.File.stdin().isTty(io)) {
        if (!quiet) std.debug.print("{s}\n", .{banner});

        var mode: Ast.Mode = .q;
        while (true) {
            if (vm.namespace == .dot) {
                std.debug.print("{t})", .{mode});
            } else {
                std.debug.print("{t}{s})", .{ mode, vm.internedString(vm.namespace) });
            }

            buffer.shrinkRetainingCapacity(0);
            _ = try stdin.streamDelimiterEnding(&buffer.writer, '\n');
            defer _ = stdin.takeByte() catch {};

            const written = buffer.written();
            const slice = std.mem.trimEnd(u8, written, "\t\r ");
            const source: [:0]u8 = if (written.len == slice.len) source: {
                try buffer.writer.writeByte(0);
                break :source buffer.written()[0..slice.len :0];
            } else source: {
                written[slice.len] = 0;
                break :source written[0..slice.len :0];
            };

            if (source.len == 0) continue;
            if (source.len == 1 and source[0] == '\\') {
                mode = if (mode == .q) .k else .q;
                continue;
            }
            if (source.len == 2 and source[0] == '\\' and source[1] == '\\') break;

            const value = vm.evalSource(source, mode, "<stdin>") catch |err| {
                try vm.reportError(err, false);
                continue;
            };
            defer value.deref(gpa);

            try printResult(stdout, vm, value);
        }
    } else {
        const len = try stdin.streamRemaining(&buffer.writer);
        try buffer.writer.writeByte(0);

        const source = buffer.written()[0..len :0];

        // Piped input is the console: every result shown through `.Q.s`, errors
        // reported with the time, and the session carrying on past them.
        const value = try vm.runScript(source, .q, "<stdin>", .console);
        value.deref(gpa);
        try stdout.flush();
    }
}

fn printResult(stdout: *Io.Writer, vm: *Vm, value: *Value) !void {
    vm.show(value) catch |err| try vm.reportError(err, false);
    try stdout.flush();
}

const IoImpl = switch (build_options.io_mode) {
    .threaded => Io.Threaded,
    .evented => Io.Evented,
};
