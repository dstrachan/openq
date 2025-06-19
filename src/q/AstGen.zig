const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const q = @import("../root.zig");
const Ast = q.Ast;
const Qir = q.Qir;

const AstGen = @This();

gpa: Allocator,
arena: Allocator,
tree: *const Ast,
instructions: std.MultiArrayList(Qir.Inst) = .empty,
extra: std.ArrayListUnmanaged(u32) = .empty,
string_bytes: std.ArrayListUnmanaged(u8) = .empty,
compile_errors: std.ArrayListUnmanaged(Qir.Inst.CompileErrors.Item) = .empty,

const InnerError = error{ OutOfMemory, AnalysisFail };

fn addExtra(astgen: *AstGen, extra: anytype) Allocator.Error!u32 {
    const fields = std.meta.fields(@TypeOf(extra));
    try astgen.extra.ensureUnusedCapacity(astgen.gpa, fields.len);
    return addExtraAssumeCapacity(astgen, extra);
}

fn addExtraAssumeCapacity(astgen: *AstGen, extra: anytype) u32 {
    const fields = std.meta.fields(@TypeOf(extra));
    const extra_index: u32 = @intCast(astgen.extra.items.len);
    astgen.extra.items.len += fields.len;
    setExtra(astgen, extra_index, extra);
    return extra_index;
}

fn setExtra(astgen: *AstGen, index: usize, extra: anytype) void {
    const fields = std.meta.fields(@TypeOf(extra));
    var i = index;
    inline for (fields) |field| {
        astgen.extra.items[i] = switch (field.type) {
            u32 => @field(extra, field.name),

            Qir.NullTerminatedString,
            // Ast.TokenIndex is missing because it is a u32.
            Ast.OptionalTokenIndex,
            Ast.Node.Index,
            Ast.Node.OptionalIndex,
            => @intFromEnum(@field(extra, field.name)),

            Ast.Node.Offset,
            Ast.Node.OptionalOffset,
            => @bitCast(@intFromEnum(@field(extra, field.name))),

            i32,
            => @bitCast(@field(extra, field.name)),

            else => @compileError("bad field type: " ++ @typeName(field.type)),
        };
        i += 1;
    }
}

pub fn generate(gpa: Allocator, tree: Ast) !Qir {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var astgen: AstGen = .{
        .gpa = gpa,
        .arena = arena.allocator(),
        .tree = &tree,
    };
    defer astgen.deinit();

    // String table index 0 is reserved for `NullTerminatedString.empty`.
    try astgen.string_bytes.append(gpa, 0);

    // We expect at least as many QIR instructions and extra data items
    // as AST nodes.
    try astgen.instructions.ensureTotalCapacity(gpa, tree.nodes.len);

    // First few indexes of extra are reserved and set at the end.
    const reserved_count = @typeInfo(Qir.ExtraIndex).@"enum".fields.len;
    try astgen.extra.ensureTotalCapacity(gpa, tree.nodes.len + reserved_count);
    astgen.extra.items.len += reserved_count;

    const fatal = if (tree.errors.len == 0) fatal: {
        break :fatal false;
    } else fatal: {
        try astgen.lowerAstErrors();
        break :fatal true;
    };

    const err_index = @intFromEnum(Qir.ExtraIndex.compile_errors);
    if (astgen.compile_errors.items.len == 0) {
        astgen.extra.items[err_index] = 0;
    } else {
        try astgen.extra.ensureUnusedCapacity(gpa, 1 + astgen.compile_errors.items.len *
            @typeInfo(Qir.Inst.CompileErrors.Item).@"struct".fields.len);

        astgen.extra.items[err_index] = astgen.addExtraAssumeCapacity(Qir.Inst.CompileErrors{
            .items_len = @intCast(astgen.compile_errors.items.len),
        });

        for (astgen.compile_errors.items) |item| {
            _ = astgen.addExtraAssumeCapacity(item);
        }
    }

    return .{
        .instructions = if (fatal) .empty else astgen.instructions.toOwnedSlice(),
        .string_bytes = try astgen.string_bytes.toOwnedSlice(gpa),
        .extra = try astgen.extra.toOwnedSlice(gpa),
    };
}

fn deinit(astgen: *AstGen) void {
    astgen.instructions.deinit(astgen.gpa);
    astgen.extra.deinit(astgen.gpa);
    astgen.string_bytes.deinit(astgen.gpa);
    astgen.compile_errors.deinit(astgen.gpa);
}

fn lowerAstErrors(astgen: *AstGen) !void {
    const gpa = astgen.gpa;
    const tree = astgen.tree;
    assert(tree.errors.len > 0);

    var msg: std.ArrayListUnmanaged(u8) = .empty;
    defer msg.deinit(gpa);

    var notes: std.ArrayListUnmanaged(u32) = .empty;
    defer notes.deinit(gpa);

    const parse_err = tree.errors[0];
    const tok = parse_err.token;
    const tok_start = tree.tokenStart(tok);

    if (tree.tokenTag(tok) == .invalid and
        (tree.source[tok_start] == '"' or tree.source[tok_start] == '/' or tree.source[tok_start] == '\\'))
    {
        const tok_len: u32 = @intCast(tree.tokenSlice(tok).len);
        const tok_end = tok_start + tok_len;
        const bad_off = blk: {
            var idx = tok_start;
            while (idx < tok_end) : (idx += 1) {
                switch (tree.source[idx]) {
                    0x00...0x09, 0x0b...0x1f, 0x7f => break,
                    else => {},
                }
            }
            break :blk idx - tok_start;
        };

        const err: Ast.Error = .{
            .tag = .invalid_byte,
            .token = tok,
            .extra = .{ .offset = bad_off },
        };
        msg.clearRetainingCapacity();
        try tree.renderError(err, msg.writer(gpa));
        return astgen.appendErrorTokNotesOff(tok, bad_off, "{s}", .{msg.items}, notes.items);
    }

    var cur_err = tree.errors[0];
    for (tree.errors[1..]) |err| {
        if (err.is_note) {
            try tree.renderError(err, msg.writer(gpa));
            try notes.append(gpa, try astgen.errNoteTok(err.token, "{s}", .{msg.items}));
        } else {
            try tree.renderError(cur_err, msg.writer(gpa));
            try astgen.appendErrorTokNotes(cur_err.token, "{s}", .{msg.items}, notes.items);
            notes.clearRetainingCapacity();
            cur_err = err;

            // TODO: Make parse more robust.
            return;
        }
        msg.clearRetainingCapacity();
    }

    try tree.renderError(cur_err, msg.writer(gpa));
    try astgen.appendErrorTokNotes(cur_err.token, "{s}", .{msg.items}, notes.items);
}

fn failNode(
    astgen: *AstGen,
    node: Ast.Node.Index,
    comptime format: []const u8,
    args: anytype,
) InnerError {
    return astgen.failNodeNotes(node, format, args, &[0]u32{});
}

fn appendErrorNode(
    astgen: *AstGen,
    node: Ast.Node.Index,
    comptime format: []const u8,
    args: anytype,
) Allocator.Error!void {
    try astgen.appendErrorNodeNotes(node, format, args, &[0]u32{});
}

fn appendErrorNodeNotes(
    astgen: *AstGen,
    node: Ast.Node.Index,
    comptime format: []const u8,
    args: anytype,
    notes: []const u32,
) Allocator.Error!void {
    @branchHint(.cold);
    const string_bytes = &astgen.string_bytes;
    const msg: Qir.NullTerminatedString = @enumFromInt(string_bytes.items.len);
    try string_bytes.writer(astgen.gpa).print(format ++ "\x00", args);
    const notes_index: u32 = if (notes.len != 0) blk: {
        const notes_start = astgen.extra.items.len;
        try astgen.extra.ensureTotalCapacity(astgen.gpa, notes_start + 1 + notes.len);
        astgen.extra.appendAssumeCapacity(@intCast(notes.len));
        astgen.extra.appendSliceAssumeCapacity(notes);
        break :blk @intCast(notes_start);
    } else 0;
    try astgen.compile_errors.append(astgen.gpa, .{
        .msg = msg,
        .node = node.toOptional(),
        .token = .none,
        .byte_offset = 0,
        .notes = notes_index,
    });
}

fn failNodeNotes(
    astgen: *AstGen,
    node: Ast.Node.Index,
    comptime format: []const u8,
    args: anytype,
    notes: []const u32,
) InnerError {
    try appendErrorNodeNotes(astgen, node, format, args, notes);
    return error.AnalysisFail;
}

fn failTok(
    astgen: *AstGen,
    token: Ast.TokenIndex,
    comptime format: []const u8,
    args: anytype,
) InnerError {
    return astgen.failTokNotes(token, format, args, &[0]u32{});
}

fn appendErrorTok(
    astgen: *AstGen,
    token: Ast.TokenIndex,
    comptime format: []const u8,
    args: anytype,
) !void {
    try astgen.appendErrorTokNotesOff(token, 0, format, args, &[0]u32{});
}

fn failTokNotes(
    astgen: *AstGen,
    token: Ast.TokenIndex,
    comptime format: []const u8,
    args: anytype,
    notes: []const u32,
) InnerError {
    try appendErrorTokNotesOff(astgen, token, 0, format, args, notes);
    return error.AnalysisFail;
}

fn appendErrorTokNotes(
    astgen: *AstGen,
    token: Ast.TokenIndex,
    comptime format: []const u8,
    args: anytype,
    notes: []const u32,
) !void {
    return appendErrorTokNotesOff(astgen, token, 0, format, args, notes);
}

/// Same as `fail`, except given a token plus an offset from its starting byte
/// offset.
fn failOff(
    astgen: *AstGen,
    token: Ast.TokenIndex,
    byte_offset: u32,
    comptime format: []const u8,
    args: anytype,
) InnerError {
    try appendErrorTokNotesOff(astgen, token, byte_offset, format, args, &.{});
    return error.AnalysisFail;
}

fn appendErrorTokNotesOff(
    astgen: *AstGen,
    token: Ast.TokenIndex,
    byte_offset: u32,
    comptime format: []const u8,
    args: anytype,
    notes: []const u32,
) !void {
    @branchHint(.cold);
    const gpa = astgen.gpa;
    const string_bytes = &astgen.string_bytes;
    const msg: Qir.NullTerminatedString = @enumFromInt(string_bytes.items.len);
    try string_bytes.writer(gpa).print(format ++ "\x00", args);
    const notes_index: u32 = if (notes.len != 0) blk: {
        const notes_start = astgen.extra.items.len;
        try astgen.extra.ensureTotalCapacity(gpa, notes_start + 1 + notes.len);
        astgen.extra.appendAssumeCapacity(@intCast(notes.len));
        astgen.extra.appendSliceAssumeCapacity(notes);
        break :blk @intCast(notes_start);
    } else 0;
    try astgen.compile_errors.append(gpa, .{
        .msg = msg,
        .node = .none,
        .token = .fromToken(token),
        .byte_offset = byte_offset,
        .notes = notes_index,
    });
}

fn errNoteTok(
    astgen: *AstGen,
    token: Ast.TokenIndex,
    comptime format: []const u8,
    args: anytype,
) Allocator.Error!u32 {
    return errNoteTokOff(astgen, token, 0, format, args);
}

fn errNoteTokOff(
    astgen: *AstGen,
    token: Ast.TokenIndex,
    byte_offset: u32,
    comptime format: []const u8,
    args: anytype,
) Allocator.Error!u32 {
    @branchHint(.cold);
    const string_bytes = &astgen.string_bytes;
    const msg: Qir.NullTerminatedString = @enumFromInt(string_bytes.items.len);
    try string_bytes.writer(astgen.gpa).print(format ++ "\x00", args);
    return astgen.addExtra(Qir.Inst.CompileErrors.Item{
        .msg = msg,
        .node = .none,
        .token = .fromToken(token),
        .byte_offset = byte_offset,
        .notes = 0,
    });
}

fn errNoteNode(
    astgen: *AstGen,
    node: Ast.Node.Index,
    comptime format: []const u8,
    args: anytype,
) Allocator.Error!u32 {
    @branchHint(.cold);
    const string_bytes = &astgen.string_bytes;
    const msg: Qir.NullTerminatedString = @enumFromInt(string_bytes.items.len);
    try string_bytes.writer(astgen.gpa).print(format ++ "\x00", args);
    return astgen.addExtra(Qir.Inst.CompileErrors.Item{
        .msg = msg,
        .node = node.toOptional(),
        .token = .none,
        .byte_offset = 0,
        .notes = 0,
    });
}
