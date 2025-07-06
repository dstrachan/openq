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
const AstGen = q.AstGen;
const Qir = q.Qir;
const Vm = q.Vm;
const Chunk = q.Chunk;

const utils = @import("utils.zig");

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
    \\  validate    Validate input
    \\  repl        Start an interactive REPL
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
    } else if (mem.eql(u8, cmd, "validate")) {
        try cmdValidate(arena, cmd_args);
    } else if (mem.eql(u8, cmd, "repl")) {
        try cmdRepl(gpa, cmd_args);
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
    \\  --normalize            Normalize AST
    \\
;

fn cmdParse(arena: Allocator, args: []const []const u8) !void {
    var color: std.zig.Color = .auto;
    var q_source_path: ?[]const u8 = null;
    var normalize = false;

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
            } else if (mem.eql(u8, arg, "--normalize")) {
                normalize = true;
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

    const orig_tree: Ast = try .parse(arena, source);
    if (orig_tree.errors.len > 0) {
        try utils.printAstErrorsToStderr(arena, orig_tree, "<repl>", color);
        process.exit(1);
    } else {
        const tree = try orig_tree.normalize(arena);
        const writer = io.getStdOut().writer();
        try utils.writeJsonNode(writer, tree, .root);
    }

    return cleanExit();
}

const usage_validate =
    \\Usage: openq validate [file]
    \\
    \\  Given a .q source file, validates the input.
    \\
    \\  If [file] is omitted, stdin is used.
    \\
    \\Options:
    \\
    \\  -h, --help             Print this help and exit
    \\  --color [auto|off|on]  Enable or disable colored error messages
    \\
;

fn cmdValidate(arena: Allocator, args: []const []const u8) !void {
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

    const orig_tree: Ast = try .parse(arena, source);
    if (orig_tree.errors.len > 0) {
        try utils.printAstErrorsToStderr(arena, orig_tree, "<repl>", color);
        process.exit(1);
    }

    const tree = try orig_tree.normalize(arena);

    var vm: Vm = undefined;
    try Vm.init(&vm, arena);

    const qir = try AstGen.generate(arena, tree, &vm);
    if (qir.hasCompileErrors()) {
        try utils.printQirErrorsToStderr(arena, qir, tree, "<repl>", color);
        if (qir.loweringFailed()) {
            process.exit(1);
        }
    }

    {
        const token_bytes = @sizeOf(Ast.TokenList) +
            tree.tokens.len * (@sizeOf(Token.Tag) + @sizeOf(Ast.ByteOffset));
        const tree_bytes = @sizeOf(Ast) + tree.nodes.len * (@sizeOf(Ast.Node.Tag) + @sizeOf(Ast.TokenIndex) +
            // Here we don't use @sizeOf(Ast.Node.Data) because it would include
            // the debug safety tag but we want to measure release size.
            8);
        const instruction_bytes = qir.instructions.len *
            // Here we don't use @sizeOf(Qir.Inst.Data) because it would include
            // the debug safety tag but we want to measure release size.
            (@sizeOf(Qir.Inst.Tag) + 8);
        const extra_bytes = qir.extra.len * @sizeOf(u32);
        const total_bytes = @sizeOf(Qir) + instruction_bytes + extra_bytes + qir.string_bytes.len * @sizeOf(u8);
        const stdout = io.getStdOut();
        const fmtIntSizeBin = std.fmt.fmtIntSizeBin;
        // zig fmt: off
        try stdout.writer().print(
            \\# Source bytes:       {}
            \\# Tokens:             {} ({})
            \\# AST nodes:          {} ({})
            \\# Total QIR bytes:    {}
            \\# Instructions:       {d} ({})
            \\# String table bytes: {}
            \\# Extra data items:   {d} ({})
            \\
        , .{
            fmtIntSizeBin(source.len),
            tree.tokens.len, fmtIntSizeBin(token_bytes),
            tree.nodes.len, fmtIntSizeBin(tree_bytes),
            fmtIntSizeBin(total_bytes),
            qir.instructions.len, fmtIntSizeBin(instruction_bytes),
            fmtIntSizeBin(qir.string_bytes.len),
            qir.extra.len, fmtIntSizeBin(extra_bytes),
        });
        // zig fmt: on
    }

    // TODO: Print QIR

    return cleanExit();
}

const usage_repl =
    \\Usage: openq repl
    \\
    \\  Start an interactive REPL.
    \\
    \\Options:
    \\
    \\  -h, --help             Print this help and exit
    \\  --color [auto|off|on]  Enable or disable colored error messages
    \\
;

const banner = "OpenQ " ++ build_options.version ++ " " ++
    @tagName(builtin.mode) ++ " " ++ @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag) ++ "\n\n";

fn cmdRepl(gpa: Allocator, args: []const []const u8) !void {
    var color: std.zig.Color = .auto;

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
        } else {
            fatal("extra positional parameter: '{s}'", .{arg});
        }
    }

    const stdin = io.getStdIn().reader();
    const stderr = io.getStdErr().writer();

    try stderr.writeAll(banner);

    var vm: Vm = undefined;
    try vm.init(gpa);
    defer vm.deinit();

    var buffer: std.ArrayList(u8) = .init(gpa);
    defer buffer.deinit();
    while (true) {
        try stderr.writeAll("q)");

        buffer.shrinkRetainingCapacity(0);
        try stdin.streamUntilDelimiter(buffer.writer(), '\n', null);

        if (buffer.getLast() == '\r') _ = buffer.shrinkRetainingCapacity(buffer.items.len - 1);
        if (mem.eql(u8, buffer.items, "\\\\")) break;

        try buffer.append(0);

        var orig_tree: Ast = try .parse(gpa, buffer.items[0 .. buffer.items.len - 1 :0]);
        defer orig_tree.deinit(gpa);
        if (orig_tree.errors.len > 0) {
            try utils.printAstErrorsToStderr(gpa, orig_tree, "<repl>", color);
            continue;
        }

        var tree = try orig_tree.normalize(gpa);
        defer tree.deinit(gpa);

        var qir = try AstGen.generate(gpa, tree, &vm);
        defer qir.deinit(gpa);
        if (qir.hasCompileErrors()) {
            try utils.printQirErrorsToStderr(gpa, qir, tree, "<repl>", color);
            continue;
        }

        vm.interpret(&qir) catch |err| switch (err) {
            error.RunError => try stderr.writeAll("'run\n"),
        };
    }

    return cleanExit();
}
