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
scopes: std.ArrayListUnmanaged(std.StringHashMapUnmanaged(Ast.Node.Index)) = .empty,
locals: ?std.StringHashMapUnmanaged(Ast.Node.Index) = null,

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

    try astgen.scopes.append(gpa, .empty);

    // String table index 0 is reserved for `NullTerminatedString.empty`.
    try astgen.string_bytes.append(gpa, 0);

    // We expect at least as many QIR instructions and extra data items
    // as AST nodes.
    try astgen.instructions.ensureTotalCapacity(gpa, tree.nodes.len);

    // First few indexes of extra are reserved and set at the end.
    const reserved_count = @typeInfo(Qir.ExtraIndex).@"enum".fields.len;
    try astgen.extra.ensureTotalCapacity(gpa, tree.nodes.len + reserved_count);
    astgen.extra.items.len += reserved_count;

    // The AST -> QIR lowering process assumes an AST that does not have any parse errors.
    // Parse errors, or AstGen errors in the root struct, are considered "fatal", so we emit no QIR.
    const fatal = if (tree.errors.len == 0) fatal: {
        astgen.visit() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.AnalysisFail => break :fatal true, // Handled via compile_errors below.
        };
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
    for (astgen.scopes.items) |*scope| scope.deinit(astgen.gpa);
    astgen.scopes.deinit(astgen.gpa);
    if (astgen.locals) |*locals| locals.deinit(astgen.gpa);
}

fn visit(astgen: *AstGen) InnerError!void {
    // TODO: Remove once instructions are implemented.
    try astgen.instructions.append(astgen.gpa, .{ .tag = .dummy, .data = undefined });
    for (astgen.tree.rootStatements()) |node| {
        try astgen.visitNode(node);
    }
}

fn visitNode(astgen: *AstGen, node: Ast.Node.Index) !void {
    const gpa = astgen.gpa;
    const tree = astgen.tree;
    switch (tree.nodeTag(node)) {
        .root => unreachable,
        .no_op => {},

        .grouped_expression => try astgen.visitNode(tree.nodeData(node).node),
        .empty_list => {},
        .list => {
            const nodes = tree.extraDataSlice(tree.nodeData(node).extra_range, Ast.Node.Index);
            var it = std.mem.reverseIterator(nodes);
            while (it.next()) |n| try astgen.visitNode(n);
        },

        .table_literal => {
            const table = tree.extraData(tree.nodeData(node).extra_and_token[0], Ast.Node.Table);

            inline for (&.{
                tree.extraDataSlice(.{ .start = table.columns_start, .end = table.columns_end }, Ast.Node.Index),
                tree.extraDataSlice(.{ .start = table.keys_start, .end = table.columns_start }, Ast.Node.Index),
            }) |columns| {
                var it = std.mem.reverseIterator(columns);
                while (it.next()) |n| {
                    if (tree.nodeTag(n) == .call) {
                        const nodes = tree.extraDataSlice(tree.nodeData(n).extra_range, Ast.Node.Index);
                        if (nodes.len == 3 and tree.nodeTag(nodes[0]) == .colon and tree.nodeTag(nodes[1]) == .identifier) {
                            try astgen.visitNode(nodes[2]);
                            continue;
                        }
                    }
                    try astgen.visitNode(n);
                }
            }
        },

        .function => {
            const function = tree.extraData(tree.nodeData(node).extra_and_token[0], Ast.Node.Function);
            const params = tree.extraDataSlice(.{
                .start = function.params_start,
                .end = function.body_start,
            }, Ast.Node.Index);
            const body = tree.extraDataSlice(.{
                .start = function.body_start,
                .end = function.body_end,
            }, Ast.Node.Index);

            if (params.len > 8) return astgen.appendErrorNode(params[8], "too many function parameters", .{});

            const prev_locals = astgen.locals;
            astgen.locals = .empty;
            defer {
                astgen.locals.?.deinit(gpa);
                astgen.locals = prev_locals;
            }
            for (body) |n| try astgen.findLocals(n);

            try astgen.scopes.append(gpa, .empty);
            defer {
                astgen.scopes.items[astgen.scopes.items.len - 1].deinit(gpa);
                _ = astgen.scopes.pop();
            }

            var scope = &astgen.scopes.items[astgen.scopes.items.len - 1];
            try scope.ensureUnusedCapacity(gpa, @intCast(params.len));
            for (params, 0..) |param, i| {
                if (tree.nodeTag(param) != .identifier) return astgen.appendErrorNode(param, "invalid function parameter", .{});

                const token = tree.nodeMainToken(param);
                const slice = if (tree.tokenTag(token) == .eof) switch (i) {
                    0 => "x",
                    1 => "y",
                    2 => "z",
                    else => unreachable,
                } else tree.tokenSlice(token);
                const gop = scope.getOrPutAssumeCapacity(slice);
                if (gop.found_existing) {
                    return astgen.appendErrorNodeNotes(param, "redeclaration of function parameter '{s}'", .{slice}, &.{
                        try astgen.errNoteNode(gop.value_ptr.*, "previous declaration here", .{}),
                    });
                }
                gop.value_ptr.* = param;
            }

            for (body) |n| try astgen.visitNode(n);
        },

        .expr_block => {
            const nodes = tree.extraDataSlice(tree.nodeData(node).extra_range, Ast.Node.Index);
            for (nodes) |n| try astgen.visitNode(n);
        },

        .colon,
        .colon_colon,
        .plus,
        .plus_colon,
        .minus,
        .minus_colon,
        .asterisk,
        .asterisk_colon,
        .percent,
        .percent_colon,
        .ampersand,
        .ampersand_colon,
        .pipe,
        .pipe_colon,
        .caret,
        .caret_colon,
        .equal,
        .equal_colon,
        .l_angle_bracket,
        .l_angle_bracket_colon,
        .l_angle_bracket_equal,
        .l_angle_bracket_r_angle_bracket,
        .r_angle_bracket,
        .r_angle_bracket_colon,
        .r_angle_bracket_equal,
        .dollar,
        .dollar_colon,
        .comma,
        .comma_colon,
        .hash,
        .hash_colon,
        .underscore,
        .underscore_colon,
        .tilde,
        .tilde_colon,
        .bang,
        .bang_colon,
        .question_mark,
        .question_mark_colon,
        .at,
        .at_colon,
        .dot,
        .dot_colon,
        .zero_colon,
        .zero_colon_colon,
        .one_colon,
        .one_colon_colon,
        .two_colon,
        => {},

        .apostrophe,
        .apostrophe_colon,
        .slash,
        .slash_colon,
        .backslash,
        .backslash_colon,
        => if (tree.nodeData(node).opt_node.unwrap()) |n| try astgen.visitNode(n),

        .call => {
            const nodes = tree.extraDataSlice(tree.nodeData(node).extra_range, Ast.Node.Index);
            const func = nodes[0];
            const args = nodes[1..];
            switch (tree.nodeTag(func)) {
                .colon => {
                    if (args.len != 2) return astgen.appendErrorNode(
                        node,
                        "expected 2 arguments, found {d}",
                        .{args.len},
                    );
                    if (tree.nodeTag(args[1]) == .no_op) return astgen.appendErrorNode(
                        node,
                        "expected 2 arguments, found 1",
                        .{},
                    );
                    if (tree.nodeTag(args[0]) != .identifier) return astgen.appendErrorNode(
                        args[0],
                        "invalid assignment target",
                        .{},
                    );

                    try astgen.visitNode(args[1]);

                    const slice = tree.tokenSlice(tree.nodeMainToken(args[0]));
                    try astgen.scopes.items[astgen.scopes.items.len - 1].put(gpa, slice, args[0]);

                    return;
                },
                else => {},
            }
            var it = std.mem.reverseIterator(nodes);
            while (it.next()) |n| try astgen.visitNode(n);
        },
        .apply_unary => unreachable,
        .apply_binary => unreachable,

        .number_literal,
        .number_list_literal,
        .string_literal,
        .symbol_literal,
        .symbol_list_literal,
        .builtin,
        => {},

        .identifier => {
            const slice = tree.tokenSlice(tree.nodeMainToken(node));
            if (slice[0] != '.') {
                if (astgen.locals) |locals| {
                    if (locals.get(slice)) |local_node| {
                        if (!astgen.scopes.getLast().contains(slice)) {
                            return astgen.appendErrorNodeNotes(node, "use of undeclared identifier '{s}'", .{slice}, &.{
                                try astgen.errNoteNode(local_node, "initial declaration here", .{}),
                            });
                        }
                    }
                } else {
                    if (!astgen.scopes.getLast().contains(slice)) {
                        return astgen.appendErrorNode(node, "use of undeclared identifier '{s}'", .{slice});
                    }
                }
            }
        },

        .select => try astgen.visitNode(tree.extraData(tree.nodeData(node).extra, Ast.Node.Select).from),
        .exec => try astgen.visitNode(tree.extraData(tree.nodeData(node).extra, Ast.Node.Exec).from),
        .update => try astgen.visitNode(tree.extraData(tree.nodeData(node).extra, Ast.Node.Update).from),
        .delete_rows => try astgen.visitNode(tree.extraData(tree.nodeData(node).extra, Ast.Node.DeleteRows).from),
        .delete_cols => try astgen.visitNode(tree.extraData(tree.nodeData(node).extra, Ast.Node.DeleteCols).from),
    }
}

fn findLocals(astgen: *AstGen, node: Ast.Node.Index) !void {
    const gpa = astgen.gpa;
    const tree = astgen.tree;
    switch (tree.nodeTag(node)) {
        .root => unreachable,
        .no_op => {},

        .grouped_expression => try astgen.findLocals(tree.nodeData(node).node),
        .empty_list => {},
        .list => {
            const nodes = tree.extraDataSlice(tree.nodeData(node).extra_range, Ast.Node.Index);
            var it = std.mem.reverseIterator(nodes);
            while (it.next()) |n| try astgen.findLocals(n);
        },

        .table_literal => {
            const table = tree.extraData(tree.nodeData(node).extra_and_token[0], Ast.Node.Table);

            inline for (&.{
                tree.extraDataSlice(.{ .start = table.columns_start, .end = table.columns_end }, Ast.Node.Index),
                tree.extraDataSlice(.{ .start = table.keys_start, .end = table.columns_start }, Ast.Node.Index),
            }) |columns| {
                var it = std.mem.reverseIterator(columns);
                while (it.next()) |n| {
                    if (tree.nodeTag(n) == .call) {
                        const nodes = tree.extraDataSlice(tree.nodeData(n).extra_range, Ast.Node.Index);
                        if (nodes.len == 3 and tree.nodeTag(nodes[0]) == .colon and tree.nodeTag(nodes[1]) == .identifier) {
                            try astgen.findLocals(nodes[2]);
                            continue;
                        }
                    }
                    try astgen.findLocals(n);
                }
            }
        },

        .function => {
            const function = tree.extraData(tree.nodeData(node).extra_and_token[0], Ast.Node.Function);
            const body = tree.extraDataSlice(.{
                .start = function.body_start,
                .end = function.body_end,
            }, Ast.Node.Index);

            const prev_locals = astgen.locals;
            astgen.locals = .empty;
            defer {
                astgen.locals.?.deinit(gpa);
                astgen.locals = prev_locals;
            }
            for (body) |n| try astgen.findLocals(n);
        },

        .expr_block => {
            const nodes = tree.extraDataSlice(tree.nodeData(node).extra_range, Ast.Node.Index);
            for (nodes) |n| try astgen.findLocals(n);
        },

        .colon,
        .colon_colon,
        .plus,
        .plus_colon,
        .minus,
        .minus_colon,
        .asterisk,
        .asterisk_colon,
        .percent,
        .percent_colon,
        .ampersand,
        .ampersand_colon,
        .pipe,
        .pipe_colon,
        .caret,
        .caret_colon,
        .equal,
        .equal_colon,
        .l_angle_bracket,
        .l_angle_bracket_colon,
        .l_angle_bracket_equal,
        .l_angle_bracket_r_angle_bracket,
        .r_angle_bracket,
        .r_angle_bracket_colon,
        .r_angle_bracket_equal,
        .dollar,
        .dollar_colon,
        .comma,
        .comma_colon,
        .hash,
        .hash_colon,
        .underscore,
        .underscore_colon,
        .tilde,
        .tilde_colon,
        .bang,
        .bang_colon,
        .question_mark,
        .question_mark_colon,
        .at,
        .at_colon,
        .dot,
        .dot_colon,
        .zero_colon,
        .zero_colon_colon,
        .one_colon,
        .one_colon_colon,
        .two_colon,
        => {},

        .apostrophe,
        .apostrophe_colon,
        .slash,
        .slash_colon,
        .backslash,
        .backslash_colon,
        => if (tree.nodeData(node).opt_node.unwrap()) |n| try astgen.findLocals(n),

        .call => {
            const nodes = tree.extraDataSlice(tree.nodeData(node).extra_range, Ast.Node.Index);
            const func = nodes[0];
            const args = nodes[1..];
            switch (tree.nodeTag(func)) {
                .colon => {
                    try astgen.findLocals(args[1]);

                    const slice = tree.tokenSlice(tree.nodeMainToken(args[0]));
                    if (slice[0] != '.') try astgen.locals.?.put(gpa, slice, args[0]);

                    return;
                },
                else => {},
            }
            var it = std.mem.reverseIterator(nodes);
            while (it.next()) |n| try astgen.findLocals(n);
        },
        .apply_unary => unreachable,
        .apply_binary => unreachable,

        .number_literal,
        .number_list_literal,
        .string_literal,
        .symbol_literal,
        .symbol_list_literal,
        .builtin,
        => {},

        .identifier => {},

        .select => try astgen.findLocals(tree.extraData(tree.nodeData(node).extra, Ast.Node.Select).from),
        .exec => try astgen.findLocals(tree.extraData(tree.nodeData(node).extra, Ast.Node.Exec).from),
        .update => try astgen.findLocals(tree.extraData(tree.nodeData(node).extra, Ast.Node.Update).from),
        .delete_rows => try astgen.findLocals(tree.extraData(tree.nodeData(node).extra, Ast.Node.DeleteRows).from),
        .delete_cols => try astgen.findLocals(tree.extraData(tree.nodeData(node).extra, Ast.Node.DeleteCols).from),
    }
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

fn testNoFail(source: [:0]const u8) !void {
    const gpa = std.testing.allocator;

    var orig_tree: Ast = try .parse(gpa, source);
    defer orig_tree.deinit(gpa);
    var tree = try orig_tree.normalize(gpa);
    defer tree.deinit(gpa);

    var qir = try generate(gpa, tree);
    defer qir.deinit(gpa);
    try std.testing.expect(!qir.hasCompileErrors());
}

fn testFail(source: [:0]const u8, expected: []const u8) !void {
    const gpa = std.testing.allocator;

    var orig_tree: Ast = try .parse(gpa, source);
    defer orig_tree.deinit(gpa);
    var tree = try orig_tree.normalize(gpa);
    defer tree.deinit(gpa);

    var qir = try generate(gpa, tree);
    defer qir.deinit(gpa);
    try std.testing.expect(qir.hasCompileErrors());

    var wip_errors: std.zig.ErrorBundle.Wip = undefined;
    try wip_errors.init(gpa);
    defer wip_errors.deinit();
    try q.addQirErrorMessages(&wip_errors, qir, tree, "test");

    var error_bundle = try wip_errors.toOwnedBundle("");
    defer error_bundle.deinit(gpa);

    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(gpa);
    try error_bundle.renderToWriter(.{ .ttyconf = .no_color }, output.writer(gpa));

    try std.testing.expectEqualStrings(expected, std.mem.trim(u8, output.items, &std.ascii.whitespace));
}

test "undeclared identifier - identifier" {
    try testFail("test",
        \\test:1:1: error: use of undeclared identifier 'test'
        \\test
        \\^~~~
    );
    try testFail("a:a+b",
        \\test:1:5: error: use of undeclared identifier 'b'
        \\a:a+b
        \\    ^
        \\test:1:3: error: use of undeclared identifier 'a'
        \\a:a+b
        \\  ^
    );
    try testFail("a:a+b:1",
        \\test:1:3: error: use of undeclared identifier 'a'
        \\a:a+b:1
        \\  ^
    );
    try testFail(
        \\a:1
        \\b:2
        \\c:a+b
        \\d:c+d
    ,
        \\test:4:5: error: use of undeclared identifier 'd'
        \\d:c+d
        \\    ^
    );
}

test "undeclared identifier - sql" {
    try testFail("select x from y where z",
        \\test:1:15: error: use of undeclared identifier 'y'
        \\select x from y where z
        \\              ^
    );
    try testFail("exec x from y where z",
        \\test:1:13: error: use of undeclared identifier 'y'
        \\exec x from y where z
        \\            ^
    );
    try testFail("update x from y where z",
        \\test:1:15: error: use of undeclared identifier 'y'
        \\update x from y where z
        \\              ^
    );
    try testFail("delete from y where z",
        \\test:1:13: error: use of undeclared identifier 'y'
        \\delete from y where z
        \\            ^
    );
    try testFail("delete x from y",
        \\test:1:15: error: use of undeclared identifier 'y'
        \\delete x from y
        \\              ^
    );
}

test "undeclared identifier - table literal" {
    try testFail("([]x)",
        \\test:1:4: error: use of undeclared identifier 'x'
        \\([]x)
        \\   ^
    );
    try testFail("([x]())",
        \\test:1:3: error: use of undeclared identifier 'x'
        \\([x]())
        \\  ^
    );
    try testFail("([x]x:())",
        \\test:1:3: error: use of undeclared identifier 'x'
        \\([x]x:())
        \\  ^
    );
    try testFail("([x:()]x)",
        \\test:1:8: error: use of undeclared identifier 'x'
        \\([x:()]x)
        \\       ^
    );
    try testNoFail("([x]x:x:())");
    try testFail("([x:x:()]x)",
        \\test:1:10: error: use of undeclared identifier 'x'
        \\([x:x:()]x)
        \\         ^
    );
}

test "undeclared identifier - function" {
    try testNoFail("{x:x+y:y+z:z+1}");
    try testFail("{a:a+b:b+c:c+1}",
        \\test:1:12: error: use of undeclared identifier 'c'
        \\{a:a+b:b+c:c+1}
        \\           ^
        \\test:1:10: note: initial declaration here
        \\{a:a+b:b+c:c+1}
        \\         ^
        \\test:1:8: error: use of undeclared identifier 'b'
        \\{a:a+b:b+c:c+1}
        \\       ^
        \\test:1:6: note: initial declaration here
        \\{a:a+b:b+c:c+1}
        \\     ^
        \\test:1:4: error: use of undeclared identifier 'a'
        \\{a:a+b:b+c:c+1}
        \\   ^
        \\test:1:2: note: initial declaration here
        \\{a:a+b:b+c:c+1}
        \\ ^
    );

    try testNoFail("{.ns.a}");
    try testNoFail("{.ns.a:.ns.a+b}");

    try testFail(
        \\{[]a:a+b;{[]a:a+b}}
    ,
        \\test:1:6: error: use of undeclared identifier 'a'
        \\{[]a:a+b;{[]a:a+b}}
        \\     ^
        \\test:1:4: note: initial declaration here
        \\{[]a:a+b;{[]a:a+b}}
        \\   ^
        \\test:1:15: error: use of undeclared identifier 'a'
        \\{[]a:a+b;{[]a:a+b}}
        \\              ^
        \\test:1:13: note: initial declaration here
        \\{[]a:a+b;{[]a:a+b}}
        \\            ^
    );
}

test "too many function parameters" {
    try testFail("{[x1;x2;x3;x4;x5;x6;x7;x8;x9;x10]}",
        \\test:1:27: error: too many function parameters
        \\{[x1;x2;x3;x4;x5;x6;x7;x8;x9;x10]}
        \\                          ^~
    );
}

test "duplicate function parameters" {
    try testFail("{[x1;x1;x1]}",
        \\test:1:6: error: redeclaration of function parameter 'x1'
        \\{[x1;x1;x1]}
        \\     ^~
        \\test:1:3: note: previous declaration here
        \\{[x1;x1;x1]}
        \\  ^~
    );
    try testFail("{[x1;x2;x1]}",
        \\test:1:9: error: redeclaration of function parameter 'x1'
        \\{[x1;x2;x1]}
        \\        ^~
        \\test:1:3: note: previous declaration here
        \\{[x1;x2;x1]}
        \\  ^~
    );
}

test "invalid function parameter" {
    try testFail("{[`x]}",
        \\test:1:3: error: invalid function parameter
        \\{[`x]}
        \\  ^~
    );

    // TODO: Implement 4.1 pattern matching
    return error.SkipZigTest;
}

test "too many arguments for assignment" {
    try testFail("a:",
        \\test:1:1: error: expected 2 arguments, found 1
        \\a:
        \\^~
    );
    try testFail(":[a]",
        \\test:1:1: error: expected 2 arguments, found 1
        \\:[a]
        \\^~~~
    );
    try testFail(":[a;]",
        \\test:1:1: error: expected 2 arguments, found 1
        \\:[a;]
        \\^~~~~
    );
    try testFail(":[a;b;c]",
        \\test:1:1: error: expected 2 arguments, found 3
        \\:[a;b;c]
        \\^~~~~~~~
    );
}

test "invalid assignment target" {
    try testFail(
        \\"test":123
    ,
        \\test:1:1: error: invalid assignment target
        \\"test":123
        \\^~~~~~
    );
}
