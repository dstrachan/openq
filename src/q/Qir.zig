const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const q = @import("../root.zig");
const Ast = q.Ast;

const Qir = @This();

instructions: std.MultiArrayList(Inst).Slice,
/// In order to store references to strings in fewer bytes, we copy all
/// string bytes into here. String bytes can be null. It is up to whomever
/// is referencing the data here whether they want to store both index and length,
/// thus allowing null bytes, or store only index, and use null-termination. The
/// `string_bytes` array is agnostic to either usage.
/// Index 0 is reserved for special cases.
string_bytes: []u8,
/// The meaning of this data is determined by `Inst.Tag` value.
/// The first few indexes are reserved. See `ExtraIndex` for the values.
extra: []u32,

pub const ExtraIndex = enum(u32) {
    /// If this is 0, no compile errors. Otherwise there is a `CompileErrors`
    /// payload at this index.
    compile_errors,

    _,
};

fn ExtraData(comptime T: type) type {
    return struct { data: T, end: usize };
}

/// Returns the requested data, as well as the new index which is at the start of the
/// trailers for the object.
pub fn extraData(code: Qir, comptime T: type, index: usize) ExtraData(T) {
    const fields = @typeInfo(T).@"struct".fields;
    var i: usize = index;
    var result: T = undefined;
    inline for (fields) |field| {
        @field(result, field.name) = switch (field.type) {
            u32 => code.extra[i],

            NullTerminatedString,
            // Ast.TokenIndex is missing because it is a u32.
            Ast.OptionalTokenIndex,
            Ast.Node.Index,
            Ast.Node.OptionalIndex,
            => @enumFromInt(code.extra[i]),

            Ast.Node.Offset,
            Ast.Node.OptionalOffset,
            => @enumFromInt(@as(i32, @bitCast(code.extra[i]))),

            else => @compileError("bad field type: " ++ @typeName(field.type)),
        };
        i += 1;
    }
    return .{
        .data = result,
        .end = i,
    };
}

pub const NullTerminatedString = enum(u32) {
    empty = 0,
    _,
};

/// Given an index into `string_bytes` returns the null-terminated string found there.
pub fn nullTerminatedString(code: Qir, index: NullTerminatedString) [:0]const u8 {
    const slice = code.string_bytes[@intFromEnum(index)..];
    return slice[0..std.mem.indexOfScalar(u8, slice, 0).? :0];
}

pub fn hasCompileErrors(code: Qir) bool {
    if (code.extra[@intFromEnum(ExtraIndex.compile_errors)] != 0) {
        return true;
    } else {
        assert(code.instructions.len != 0); // i.e. lowering did not fail
        return false;
    }
}

pub fn loweringFailed(code: Qir) bool {
    if (code.instructions.len == 0) {
        assert(code.hasCompileErrors());
        return true;
    } else {
        return false;
    }
}

pub fn deinit(code: *Qir, gpa: Allocator) void {
    code.instructions.deinit(gpa);
    gpa.free(code.string_bytes);
    gpa.free(code.extra);
    code.* = undefined;
}

pub const Inst = struct {
    tag: Tag,
    data: Data,

    pub const Tag = enum(u8) {};

    pub const Data = union {};

    /// This data is stored inside extra, with trailing operands according to `body_len`.
    /// Each operand is an `Index`.
    pub const Block = struct {
        body_len: u32,
    };

    /// Trailing: `CompileErrors.Item` for each `items_len`.
    pub const CompileErrors = struct {
        items_len: u32,

        /// Trailing: `note_payload_index: u32` for each `notes_len`.
        /// It's a payload index of another `Item`.
        pub const Item = struct {
            /// null terminated string index
            msg: NullTerminatedString,
            node: Ast.Node.OptionalIndex,
            /// If node is .none then this will be populated.
            token: Ast.OptionalTokenIndex,
            /// Can be used in combination with `token`.
            byte_offset: u32,
            /// 0 or a payload index of a `Block`, each is a payload
            /// index of another `Item`.
            notes: u32,

            pub fn notesLen(item: Item, code: Qir) u32 {
                if (item.notes == 0) return 0;
                const block = code.extraData(Block, item.notes);
                return block.data.body_len;
            }
        };
    };
};
