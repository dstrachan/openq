const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Value = @This();

pub const Type = enum {
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
};

pub const Union = union {
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
            .symbol => if (value.as.symbol.len > 0) gpa.free(value.as.symbol),
            .symbol_list => gpa.free(value.as.symbol_list),
            else => {},
        }
        gpa.destroy(value);
    }
}

pub fn format(value: Value, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
    switch (value.type) {
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
        .byte => try writer.print("0x{d}", .{std.fmt.fmtSliceHexLower(&.{value.as.byte})}),
        .byte_list => if (value.as.byte_list.len == 0) {
            try writer.writeAll("`byte$()");
        } else {
            try writer.print("0x{d}", .{std.fmt.fmtSliceHexLower(value.as.byte_list)});
        },
        .short => try writer.print("{d}h", .{value.as.short}),
        .short_list => @panic("NYI"),
        .int => try writer.print("{d}i", .{value.as.int}),
        .int_list => @panic("NYI"),
        .long => try writer.print("{d}", .{value.as.long}),
        .long_list => @panic("NYI"),
        .real => try writer.print("{d}e", .{value.as.real}),
        .real_list => @panic("NYI"),
        .float => try writer.print("{d}f", .{value.as.float}),
        .float_list => @panic("NYI"),
        .char => try writer.print("\"{}\"", .{std.zig.fmtEscapes(&.{value.as.char})}),
        .char_list => if (value.as.char_list.len == 1) {
            try writer.print(",\"{}\"", .{std.zig.fmtEscapes(value.as.char_list)});
        } else {
            try writer.print("\"{}\"", .{std.zig.fmtEscapes(value.as.char_list)});
        },
        .symbol => try writer.print("`{s}", .{value.as.symbol}),
        .symbol_list => @panic("NYI"),
    }
}
