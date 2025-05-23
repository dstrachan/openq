const std = @import("std");
const builtin = @import("builtin");
const debug = std.debug;
const fs = std.fs;
const io = std.io;
const mem = std.mem;
const process = std.process;
const Allocator = mem.Allocator;

const build_options = @import("build_options");
const q = @import("q");
const Token = q.Token;
const Tokenizer = q.Tokenizer;
const Ast = q.Ast;

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
    \\  tokenize    Tokenize input
    \\  parse       Parse input
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
    _ = gpa; // autofix
    if (args.len <= 1) {
        debug.print("{s}\n", .{usage});
        fatal("expected command argument", .{});
    }

    const cmd = args[1];
    const cmd_args = args[2..];
    if (mem.eql(u8, cmd, "tokenize")) {
        try cmdTokenize(arena, cmd_args);
    } else if (mem.eql(u8, cmd, "parse")) {
        try cmdParse(arena, cmd_args);
    } else if (mem.eql(u8, cmd, "version")) {
        try io.getStdOut().writeAll(build_options.version ++ "\n");
    } else if (mem.eql(u8, cmd, "help") or mem.eql(u8, cmd, "-h") or mem.eql(u8, cmd, "--help")) {
        try io.getStdOut().writeAll(usage);
    } else {
        debug.print("{s}\n", .{usage});
        fatal("unknown command: {s}", .{cmd});
    }
}

const usage_tokenize =
    \\Usage: openq tokenize [file]
    \\
    \\  Given a .q source file, tokenizes the input.
    \\
    \\  If [file] is omitted, stdin is used.
    \\
    \\Options:
    \\
    \\  -h, --help             Print this help and exit
    \\  --color [auto|off|on]  Enable or disable colored error messages
    \\
;

fn cmdTokenize(arena: Allocator, args: []const []const u8) !void {
    var color: std.zig.Color = .auto;
    var q_source_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (mem.startsWith(u8, arg, "-")) {
            if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
                try io.getStdOut().writeAll(usage_tokenize);
                return cleanExit();
            } else if (mem.eql(u8, arg, "--color")) {
                if (i + 1 >= args.len) {
                    fatal("expected [auto|on|off] after --color", .{});
                }
                i += 1;
                const next_arg = args[i];
                color = std.meta.stringToEnum(std.zig.Color, next_arg) orelse {
                    fatal("expected [auto|on|off] after --color, found '{s}'", .{next_arg});
                };
            } else {
                fatal("unrecognized parameter: '{s}'", .{arg});
            }
        } else if (q_source_path == null) {
            q_source_path = arg;
        } else {
            fatal("extra positional parameter: '{s}'", .{arg});
        }
    }

    const display_path = q_source_path orelse "<stdin>";
    const source: [:0]const u8 = s: {
        var f = if (q_source_path) |p| file: {
            break :file fs.cwd().openFile(p, .{}) catch |err| {
                fatal("unable to open file '{s}' for tokenize: {s}", .{ display_path, @errorName(err) });
            };
        } else io.getStdIn();
        defer if (q_source_path != null) f.close();
        break :s std.zig.readSourceFileToEndAlloc(arena, f, null) catch |err| {
            fatal("unable to load file '{s}' for tokenize: {s}", .{ display_path, @errorName(err) });
        };
    };

    var tokens: std.ArrayListUnmanaged(Token) = .empty;
    var tokenizer: Tokenizer = .init(source);
    if (q_source_path != null) tokenizer.skipComments();
    while (true) {
        const token = tokenizer.next();
        try tokens.append(arena, token);
        if (token.tag == .eof) break;
    }

    const writer = io.getStdOut().writer();
    try writer.writeByte('[');
    for (tokens.items, 0..) |token, index| {
        try writer.print(
            \\{{"{s}":"{}"}}
        , .{ @tagName(token.tag), std.zig.fmtEscapes(source[token.loc.start..token.loc.end]) });
        if (index < tokens.items.len - 1) try writer.writeByte(',');
    }
    try writer.writeByte(']');

    return cleanExit();
}

const usage_parse =
    \\Usage: openq parse [file]
    \\
    \\  Given a .q source file, parses the input.
    \\
    \\  If [file] is omitted, stdin is used.
    \\
    \\Options:
    \\
    \\  -h, --help             Print this help and exit
    \\  --color [auto|off|on]  Enable or disable colored error messages
    \\
;

fn cmdParse(arena: Allocator, args: []const []const u8) !void {
    var color: std.zig.Color = .auto;
    var q_source_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (mem.startsWith(u8, arg, "-")) {
            if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
                try io.getStdOut().writeAll(usage_parse);
                return cleanExit();
            } else if (mem.eql(u8, arg, "--color")) {
                if (i + 1 >= args.len) {
                    fatal("expected [auto|on|off] after --color", .{});
                }
                i += 1;
                const next_arg = args[i];
                color = std.meta.stringToEnum(std.zig.Color, next_arg) orelse {
                    fatal("expected [auto|on|off] after --color, found '{s}'", .{next_arg});
                };
            } else {
                fatal("unrecognized parameter: '{s}'", .{arg});
            }
        } else if (q_source_path == null) {
            q_source_path = arg;
        } else {
            fatal("extra positional parameter: '{s}'", .{arg});
        }
    }

    const display_path = q_source_path orelse "<stdin>";
    const source: [:0]const u8 = s: {
        var f = if (q_source_path) |p| file: {
            break :file fs.cwd().openFile(p, .{}) catch |err| {
                fatal("unable to open file '{s}' for parse: {s}", .{ display_path, @errorName(err) });
            };
        } else io.getStdIn();
        defer if (q_source_path != null) f.close();
        break :s std.zig.readSourceFileToEndAlloc(arena, f, null) catch |err| {
            fatal("unable to load file '{s}' for parse: {s}", .{ display_path, @errorName(err) });
        };
    };

    const tree: Ast = try .parse(arena, source);

    const writer = io.getStdOut().writer();
    try writer.writeAll(
        \\{"tokens":[
    );
    for (0..tree.tokens.len) |index| {
        try writer.print(
            \\{{"{s}":"{}"}}
        , .{ @tagName(tree.tokenTag(@enumFromInt(index))), std.zig.fmtEscapes(tree.tokenSlice(@enumFromInt(index))) });
        if (index < tree.tokens.len - 1) try writer.writeByte(',');
    }
    try writer.writeAll("]}");

    return cleanExit();
}
