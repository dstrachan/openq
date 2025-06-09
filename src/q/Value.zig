const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Value = @This();

pub const ValueType = enum(u8) {
    boolean,
    guid,
    byte,
    short,
    int,
    long,
    real,
    float,
    char,
    symbol,
};

pub const ValueUnion = union {
    boolean: bool,
    guid: [16]u8,
    byte: u8,
    short: i16,
    int: i32,
    long: i64,
    real: f32,
    float: f64,
    symbol: [*:0]u8,
    table: [*]Value,
    list: []u8,
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

pub inline fn symbol(value: [*:0]u8) Value {
    return .{ .type = .symbol, .as = .{ .symbol = value } };
}

pub fn ref(value: *Value) void {
    value.ref_count += 1;
}

pub fn deref(value: *Value) void {
    assert(value.ref_count > 0);
    value.ref_count -= 1;
    if (value.ref_count == 0) switch (value.as) {
        .long => {},
        .float => {},
    };
}

pub fn print(value: Value) !void {
    const stdout = std.io.getStdOut().writer();
    switch (value.type) {
        .boolean => try stdout.writeAll(if (value.as.boolean) "1b" else "0b"),
        .guid => @panic("NYI"),
        .byte => try stdout.print("0x{d}", .{std.fmt.fmtSliceHexLower(&.{value.as.byte})}),
        .short => try stdout.print("{d}h", .{value.as.short}),
        .int => try stdout.print("{d}i", .{value.as.int}),
        .long => try stdout.print("{d}", .{value.as.long}),
        .real => try stdout.print("{d}e", .{value.as.real}),
        .float => try stdout.print("{d}f", .{value.as.float}),
        .char => try stdout.print("\"{c}\"", .{value.as.byte}),
        .symbol => try stdout.print("`{s}", .{value.as.symbol}),
    }
}
