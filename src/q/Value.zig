const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Value = @This();

pub const ValueType = enum(u8) {
    long,
    float,
};

pub const ValueUnion = union(ValueType) {
    long: i64,
    float: f64,
};

type: ValueType,
ref_count: u32 = 1,
as: ValueUnion,

pub fn init(value: ValueUnion) Value {
    return switch (value) {
        .long => .{ .type = .long, .as = value },
        .float => .{ .type = .float, .as = value },
    };
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
