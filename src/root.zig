const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const tokenizer = @import("q/tokenizer.zig");
pub const Token = tokenizer.Token;
pub const Tokenizer = tokenizer.Tokenizer;
pub const Ast = @import("q/Ast.zig");
pub const Node = Ast.Node;
pub const Parse = @import("q/Parse.zig");
pub const AstGen = @import("q/AstGen.zig");
pub const Qir = @import("q/Qir.zig");
pub const Vm = @import("q/Vm.zig");
pub const Value = @import("q/Value.zig");
pub const Chunk = @import("q/Chunk.zig");
pub const OpCode = Chunk.OpCode;
pub const Compiler = @import("q/Compiler.zig");

pub fn putAstErrorsIntoBundle(gpa: Allocator, tree: Ast, path: []const u8, wip_errors: *std.zig.ErrorBundle.Wip) !void {
    var qir = try AstGen.generate(gpa, tree);
    defer qir.deinit(gpa);

    try addQirErrorMessages(wip_errors, qir, tree, path);
}

pub fn addQirErrorMessages(eb: *std.zig.ErrorBundle.Wip, qir: Qir, tree: Ast, src_path: []const u8) !void {
    const payload_index = qir.extra[@intFromEnum(Qir.ExtraIndex.compile_errors)];
    assert(payload_index != 0);

    const header = qir.extraData(Qir.Inst.CompileErrors, payload_index);
    const items_len = header.data.items_len;
    var extra_index = header.end;
    for (0..items_len) |_| {
        const item = qir.extraData(Qir.Inst.CompileErrors.Item, extra_index);
        extra_index = item.end;
        const err_span: Ast.Span = blk: {
            if (item.data.node.unwrap()) |node| {
                break :blk tree.nodeToSpan(node);
            } else if (item.data.token.unwrap()) |token| {
                const start = tree.tokenStart(token) + item.data.byte_offset;
                const end = start + @as(u32, @intCast(tree.tokenSlice(token).len)) - item.data.byte_offset;
                break :blk .{ .start = start, .end = end, .main = start };
            } else unreachable;
        };
        const err_loc = std.zig.findLineColumn(tree.source, err_span.main);

        {
            const msg = qir.nullTerminatedString(item.data.msg);
            try eb.addRootErrorMessage(.{
                .msg = try eb.addString(msg),
                .src_loc = try eb.addSourceLocation(.{
                    .src_path = try eb.addString(src_path),
                    .span_start = err_span.start,
                    .span_main = err_span.main,
                    .span_end = err_span.end,
                    .line = @intCast(err_loc.line),
                    .column = @intCast(err_loc.column),
                    .source_line = try eb.addString(err_loc.source_line),
                }),
                .notes_len = item.data.notesLen(qir),
            });
        }

        if (item.data.notes != 0) {
            const notes_start = try eb.reserveNotes(item.data.notesLen(qir));
            const block = qir.extraData(Qir.Inst.Block, item.data.notes);
            const body = qir.extra[block.end..][0..block.data.body_len];
            for (notes_start.., body) |note_i, body_elem| {
                const note_item = qir.extraData(Qir.Inst.CompileErrors.Item, body_elem);
                const msg = qir.nullTerminatedString(note_item.data.msg);
                const span: Ast.Span = blk: {
                    if (note_item.data.node.unwrap()) |node| {
                        break :blk tree.nodeToSpan(node);
                    } else if (note_item.data.token.unwrap()) |token| {
                        const start = tree.tokenStart(token) + note_item.data.byte_offset;
                        const end = start + @as(u32, @intCast(tree.tokenSlice(token).len)) - item.data.byte_offset;
                        break :blk .{ .start = start, .end = end, .main = start };
                    } else unreachable;
                };
                const loc = std.zig.findLineColumn(tree.source, span.main);

                // This line can cause `wip.extra.items` to be resized.
                const note_index = @intFromEnum(try eb.addErrorMessage(.{
                    .msg = try eb.addString(msg),
                    .src_loc = try eb.addSourceLocation(.{
                        .src_path = try eb.addString(src_path),
                        .span_start = span.start,
                        .span_main = span.main,
                        .span_end = span.end,
                        .line = @intCast(loc.line),
                        .column = @intCast(loc.column),
                        .source_line = if (loc.eql(err_loc))
                            0
                        else
                            try eb.addString(loc.source_line),
                    }),
                    .notes_len = 0, // TODO rework this function to be recursive
                }));
                eb.extra.items[note_i] = note_index;
            }
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
