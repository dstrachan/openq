const q = @import("../../root.zig");
const Value = q.Value;

pub fn FromType(comptime value_type: Value.Type) type {
    return switch (value_type) {
        .int, .int_list => i32,
        .long, .long_list => i64,
        .real, .real_list => f32,
        .float, .float_list => f64,
        else => comptime unreachable,
    };
}

pub fn cast(comptime value_type: Value.Type, value: anytype) FromType(value_type) {
    const T = FromType(value_type);
    return switch (@typeInfo(@TypeOf(value))) {
        .bool => if (@typeInfo(T) == .float) @floatFromInt(@intFromBool(value)) else @intFromBool(value),
        .int => if (@typeInfo(T) == .float) @floatFromInt(value) else value,
        .float => value,
        else => comptime unreachable,
    };
}
