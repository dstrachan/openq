const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const zig = std.zig;
const Color = zig.Color;
const ErrorBundle = zig.ErrorBundle;
const Span = zig.Ast.Span;

pub const Token = @import("Token.zig");
pub const Tokenizer = @import("Tokenizer.zig");
pub const Ast = @import("Ast.zig");
pub const Parse = @import("Parse.zig");
pub const Vm = @import("Vm.zig");
pub const Value = @import("Value.zig");

pub fn printAstErrorsToStderr(gpa: Allocator, io: Io, tree: Ast, path: []const u8, color: Color) !void {
    var wip_errors: ErrorBundle.Wip = undefined;
    try wip_errors.init(gpa);
    defer wip_errors.deinit();

    try putAstErrorsIntoBundle(gpa, tree, path, &wip_errors);

    var error_bundle = try wip_errors.toOwnedBundle("");
    defer error_bundle.deinit(gpa);
    return error_bundle.renderToStderr(io, .{}, color);
}

pub fn putAstErrorsIntoBundle(gpa: Allocator, tree: Ast, src_path: []const u8, eb: *ErrorBundle.Wip) !void {
    assert(tree.errors.len > 0);

    var msg: Io.Writer.Allocating = .init(gpa);
    defer msg.deinit();
    const msg_w = &msg.writer;

    for (tree.errors) |err| {
        const err_span: Span = blk: {
            const start = tree.tokenStart(err.token);
            const end = start + @as(u32, @intCast(tree.tokenSlice(err.token).len));
            break :blk .{ .start = start, .end = end, .main = start };
        };
        const err_loc = zig.findLineColumn(tree.source, err_span.main);

        try tree.renderError(err, msg_w);
        try eb.addRootErrorMessage(.{
            .msg = try eb.addString(msg.written()),
            .src_loc = try eb.addSourceLocation(.{
                .src_path = try eb.addString(src_path),
                .span_start = err_span.start,
                .span_main = err_span.main,
                .span_end = err_span.end,
                .line = @intCast(err_loc.line),
                .column = @intCast(err_loc.column),
                .source_line = try eb.addString(err_loc.source_line),
            }),
            .notes_len = 0,
        });
        msg.clearRetainingCapacity();
    }
}

pub fn parseNumber(s: []const u8) !union(enum) { long: i64, float: f64 } {
    switch (s.len) {
        2 => if (s[0] == '0') switch (s[1]) {
            'N' => return .{ .long = @intFromEnum(Value.Long.null) },
            'n' => return .{ .float = std.math.nan(f64) },
            'W' => return .{ .long = @intFromEnum(Value.Long.inf) },
            'w' => return .{ .float = std.math.inf(f64) },
            else => {},
        },
        3 => if (s[0] == '-' and s[1] == '0') switch (s[2]) {
            'W' => return .{ .long = @intFromEnum(Value.Long.neg_inf) },
            'w' => return .{ .float = -std.math.inf(f64) },
            else => {},
        },
        else => {},
    }

    if (std.fmt.parseInt(i64, s, 10)) |long| {
        return .{ .long = long };
    } else |_| {
        return .{ .float = try std.fmt.parseFloat(f64, s) };
    }
}

pub fn parseLong(s: []const u8) !i64 {
    return switch (s.len) {
        2 => if (s[0] == '0') switch (s[1]) {
            'N', 'n' => @intFromEnum(Value.Long.null),
            'W', 'w' => @intFromEnum(Value.Long.inf),
            else => null,
        } else null,
        3 => if (s[0] == '-' and s[1] == '0') switch (s[2]) {
            'W', 'w' => @intFromEnum(Value.Long.neg_inf),
            else => null,
        } else null,
        else => null,
    } orelse std.fmt.parseInt(i64, s, 10);
}

pub fn parseFloat(s: []const u8) !f64 {
    return switch (s.len) {
        2 => if (s[0] == '0') switch (s[1]) {
            'N', 'n' => std.math.nan(f64),
            'W', 'w' => std.math.inf(f64),
            else => null,
        } else null,
        3 => if (s[0] == '-' and s[1] == '0') switch (s[2]) {
            'W', 'w' => -std.math.inf(f64),
            else => null,
        } else null,
        else => null,
    } orelse std.fmt.parseFloat(f64, s);
}

test {
    std.testing.refAllDecls(@This());
}
