const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const assert = std.debug.assert;

const Chunk = @import("Chunk.zig");

const Value = @This();

pub const Type = enum {
    nil,
    mixed_list,
    boolean,
    boolean_list,
    guid,
    guid_list,
    byte,
    byte_list,
    short,
    short_list,
    int,
    int_list,
    long,
    long_list,
    real,
    real_list,
    float,
    float_list,
    char,
    char_list,
    symbol,
    symbol_list,
    function,
};

pub const Function = struct {
    arity: u8,
    chunk: *Chunk,
    source: []const u8,

    pub fn deinit(function: *Function, gpa: Allocator) void {
        function.chunk.deinit(gpa);
    }
};

pub const Union = union {
    nil: void,
    mixed_list: []Value,
    boolean: bool,
    boolean_list: []bool,
    guid: [16]u8,
    guid_list: [][16]u8,
    byte: u8,
    byte_list: []u8,
    short: i16,
    short_list: []i16,
    int: i32,
    int_list: []i32,
    long: i64,
    long_list: []i64,
    real: f32,
    real_list: []f32,
    float: f64,
    float_list: []f64,
    char: u8,
    char_list: []u8,
    symbol: []u8,
    symbol_list: [][]u8,
    function: Function,
};

type: Type,
ref_count: u32 = 1,
as: Union,

pub fn ref(value: *Value) *Value {
    value.ref_count += 1;
    return value;
}

pub fn deref(value: *Value, gpa: Allocator) void {
    assert(value.ref_count > 0);
    value.ref_count -= 1;
    if (value.ref_count == 0) {
        switch (value.type) {
            .mixed_list => gpa.free(value.as.mixed_list),
            .boolean_list => gpa.free(value.as.boolean_list),
            .guid_list => gpa.free(value.as.guid_list),
            .byte_list => gpa.free(value.as.byte_list),
            .short_list => gpa.free(value.as.short_list),
            .int_list => gpa.free(value.as.int_list),
            .long_list => gpa.free(value.as.long_list),
            .real_list => gpa.free(value.as.real_list),
            .float_list => gpa.free(value.as.float_list),
            .char_list => gpa.free(value.as.char_list),
            .symbol => gpa.free(value.as.symbol),
            .symbol_list => {
                for (value.as.symbol_list) |symbol| gpa.free(symbol);
                gpa.free(value.as.symbol_list);
            },
            .function => value.as.function.deinit(gpa),
            else => {},
        }
        gpa.destroy(value);
    }
}

pub fn format(value: Value, writer: *Writer) !void {
    switch (value.type) {
        .nil => try writer.writeAll("::"),
        .mixed_list => @panic("NYI"),
        .boolean => try writer.writeAll(if (value.as.boolean) "1b" else "0b"),
        .boolean_list => if (value.as.boolean_list.len == 0) {
            try writer.writeAll("`boolean$()");
        } else {
            for (value.as.boolean_list) |b| try writer.writeByte(if (b) '1' else '0');
            try writer.writeByte('b');
        },
        .guid => @panic("NYI"),
        .guid_list => @panic("NYI"),
        .byte => try writer.print("0x{x}", .{value.as.byte}),
        .byte_list => if (value.as.byte_list.len == 0) {
            try writer.writeAll("`byte$()");
        } else {
            try writer.print("0x{x}", .{value.as.byte_list});
        },
        .short => try writer.print("{d}h", .{value.as.short}),
        .short_list => if (value.as.short_list.len == 0) {
            try writer.writeAll("`short$()");
        } else {
            for (value.as.short_list, 0..) |item, i| {
                if (i > 0) try writer.writeByte(' ');
                try writer.print("{d}", .{item});
            }
            try writer.writeByte('h');
        },
        .int => try writer.print("{d}i", .{value.as.int}),
        .int_list => if (value.as.int_list.len == 0) {
            try writer.writeAll("`int$()");
        } else {
            for (value.as.int_list, 0..) |item, i| {
                if (i > 0) try writer.writeByte(' ');
                try writer.print("{d}", .{item});
            }
            try writer.writeByte('i');
        },
        .long => try writer.print("{d}", .{value.as.long}),
        .long_list => if (value.as.long_list.len == 0) {
            try writer.writeAll("`long$()");
        } else {
            for (value.as.long_list, 0..) |item, i| {
                if (i > 0) try writer.writeByte(' ');
                try writer.print("{d}", .{item});
            }
        },
        .real => try writer.print("{d}e", .{value.as.real}),
        .real_list => if (value.as.real_list.len == 0) {
            try writer.writeAll("`real$()");
        } else {
            for (value.as.real_list, 0..) |item, i| {
                if (i > 0) try writer.writeByte(' ');
                try writer.print("{d}", .{item});
            }
            try writer.writeByte('e');
        },
        .float => try writer.print("{d}f", .{value.as.float}),
        .float_list => if (value.as.float_list.len == 0) {
            try writer.writeAll("`float$()");
        } else {
            for (value.as.float_list, 0..) |item, i| {
                if (i > 0) try writer.writeByte(' ');
                try writer.print("{d}", .{item});
            }
            try writer.writeByte('f');
        },
        .char => try writer.print("\"{f}\"", .{std.zig.fmtString(&.{value.as.char})}),
        .char_list => if (value.as.char_list.len == 1) {
            try writer.print(",\"{f}\"", .{std.zig.fmtString(value.as.char_list)});
        } else {
            try writer.print("\"{f}\"", .{std.zig.fmtString(value.as.char_list)});
        },
        .symbol => try writer.print("`{s}", .{value.as.symbol}),
        .symbol_list => for (value.as.symbol_list) |symbol| {
            try writer.print("`{s}", .{symbol});
        },
        .function => try writer.writeAll(value.as.function.source),
    }
}
