const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Value = @This();

pub const ValueType = enum {
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

pub const ValueUnion = union {
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
    symbol: [*:0]u8,
    symbol_list: [][*:0]u8,
};

type: ValueType,
ref_count: u32 = 1,
as: ValueUnion,

pub inline fn boolean(value: bool) Value {
    return .{ .type = .boolean, .as = .{ .boolean = value } };
}

pub inline fn guid(value: [16]u8) Value {
    return .{ .type = .guid, .as = .{ .guid = value } };
}

pub inline fn byte(value: u8) Value {
    return .{ .type = .byte, .as = .{ .byte = value } };
}

pub inline fn short(value: i16) Value {
    return .{ .type = .short, .as = .{ .short = value } };
}

pub inline fn int(value: i32) Value {
    return .{ .type = .int, .as = .{ .int = value } };
}

pub inline fn long(value: i64) Value {
    return .{ .type = .long, .as = .{ .long = value } };
}

pub inline fn real(value: f32) Value {
    return .{ .type = .real, .as = .{ .real = value } };
}

pub inline fn float(value: f64) Value {
    return .{ .type = .float, .as = .{ .float = value } };
}

pub inline fn char(value: u8) Value {
    return .{ .type = .char, .as = .{ .byte = value } };
}

pub inline fn charList(value: []u8) Value {
    return .{ .type = .char_list, .as = .{ .char_list = value } };
}

pub inline fn symbol(value: [*:0]u8) Value {
    return .{ .type = .symbol, .as = .{ .symbol = value } };
}

pub fn ref(value: *Value) void {
    value.ref_count += 1;
}

pub fn deref(value: *Value, gpa: Allocator) void {
    assert(value.ref_count > 0);
    value.ref_count -= 1;
    if (value.ref_count == 0) switch (value.type) {
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
        .symbol_list => gpa.free(value.as.symbol_list),
        else => {},
    };
}

pub fn print(value: Value) !void {
    const stdout = std.io.getStdOut().writer();
    switch (value.type) {
        .mixed_list => @panic("NYI"),
        .boolean => try stdout.writeAll(if (value.as.boolean) "1b" else "0b"),
        .boolean_list => if (value.as.boolean_list.len == 0) {
            try stdout.writeAll("`boolean$()");
        } else {
            for (value.as.boolean_list) |b| try stdout.writeByte(if (b) '1' else '0');
            try stdout.writeByte('b');
        },
        .guid => @panic("NYI"),
        .guid_list => @panic("NYI"),
        .byte => try stdout.print("0x{d}", .{std.fmt.fmtSliceHexLower(&.{value.as.byte})}),
        .byte_list => if (value.as.byte_list.len == 0) {
            try stdout.writeAll("`byte$()");
        } else {
            try stdout.print("0x{d}", .{std.fmt.fmtSliceHexLower(value.as.byte_list)});
        },
        .short => try stdout.print("{d}h", .{value.as.short}),
        .short_list => @panic("NYI"),
        .int => try stdout.print("{d}i", .{value.as.int}),
        .int_list => @panic("NYI"),
        .long => try stdout.print("{d}", .{value.as.long}),
        .long_list => @panic("NYI"),
        .real => try stdout.print("{d}e", .{value.as.real}),
        .real_list => @panic("NYI"),
        .float => try stdout.print("{d}f", .{value.as.float}),
        .float_list => @panic("NYI"),
        .char => try stdout.print("\"{}\"", .{std.zig.fmtEscapes(&.{value.as.char})}),
        .char_list => if (value.as.char_list.len == 1) {
            try stdout.print(",\"{}\"", .{std.zig.fmtEscapes(value.as.char_list)});
        } else {
            try stdout.print("\"{}\"", .{std.zig.fmtEscapes(value.as.char_list)});
        },
        .symbol => try stdout.print("`{s}", .{value.as.symbol}),
        .symbol_list => @panic("NYI"),
    }
}
