const std = @import("std");
const testing = std.testing;

const q = @import("../../root.zig");
const Vm = q.Vm;
const Value = q.Value;
const utils = @import("utils.zig");
const FromType = utils.FromType;
const cast = utils.cast;

pub fn impl(vm: *Vm, x: *Value, y: *Value) !*Value {
    return switch (x.type) {
        .boolean => switch (y.type) {
            .boolean => scalarMultiplyScalar(vm, x.as.boolean, y.as.boolean, .int),
            .boolean_list => scalarMultiplyList(vm, x.as.boolean, y.as.boolean_list, .int_list),
            .byte => scalarMultiplyScalar(vm, x.as.boolean, y.as.byte, .int),
            .byte_list => scalarMultiplyList(vm, x.as.boolean, y.as.byte_list, .int_list),
            .short => scalarMultiplyScalar(vm, x.as.boolean, y.as.short, .int),
            .short_list => scalarMultiplyList(vm, x.as.boolean, y.as.short_list, .int_list),
            .int => scalarMultiplyScalar(vm, x.as.boolean, y.as.int, .int),
            .int_list => scalarMultiplyList(vm, x.as.boolean, y.as.int_list, .int_list),
            .long => scalarMultiplyScalar(vm, x.as.boolean, y.as.long, .long),
            .long_list => scalarMultiplyList(vm, x.as.boolean, y.as.long_list, .long_list),
            .real => scalarMultiplyScalar(vm, x.as.boolean, y.as.real, .real),
            .real_list => scalarMultiplyList(vm, x.as.boolean, y.as.real_list, .real_list),
            .float => scalarMultiplyScalar(vm, x.as.boolean, y.as.float, .float),
            .float_list => scalarMultiplyList(vm, x.as.boolean, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .boolean_list => switch (y.type) {
            .boolean => listMultiplyScalar(vm, x.as.boolean_list, y.as.boolean, .int_list),
            .boolean_list => listMultiplyList(vm, x.as.boolean_list, y.as.boolean_list, .int_list),
            .byte => listMultiplyScalar(vm, x.as.boolean_list, y.as.byte, .int_list),
            .byte_list => listMultiplyList(vm, x.as.boolean_list, y.as.byte_list, .int_list),
            .short => listMultiplyScalar(vm, x.as.boolean_list, y.as.short, .int_list),
            .short_list => listMultiplyList(vm, x.as.boolean_list, y.as.short_list, .int_list),
            .int => listMultiplyScalar(vm, x.as.boolean_list, y.as.int, .int_list),
            .int_list => listMultiplyList(vm, x.as.boolean_list, y.as.int_list, .int_list),
            .long => listMultiplyScalar(vm, x.as.boolean_list, y.as.long, .long_list),
            .long_list => listMultiplyList(vm, x.as.boolean_list, y.as.long_list, .long_list),
            .real => listMultiplyScalar(vm, x.as.boolean_list, y.as.real, .real_list),
            .real_list => listMultiplyList(vm, x.as.boolean_list, y.as.real_list, .real_list),
            .float => listMultiplyScalar(vm, x.as.boolean_list, y.as.float, .float_list),
            .float_list => listMultiplyList(vm, x.as.boolean_list, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .byte => switch (y.type) {
            .boolean => scalarMultiplyScalar(vm, x.as.byte, y.as.boolean, .int),
            .boolean_list => scalarMultiplyList(vm, x.as.byte, y.as.boolean_list, .int_list),
            .byte => scalarMultiplyScalar(vm, x.as.byte, y.as.byte, .int),
            .byte_list => scalarMultiplyList(vm, x.as.byte, y.as.byte_list, .int_list),
            .short => scalarMultiplyScalar(vm, x.as.byte, y.as.short, .int),
            .short_list => scalarMultiplyList(vm, x.as.byte, y.as.short_list, .int_list),
            .int => scalarMultiplyScalar(vm, x.as.byte, y.as.int, .int),
            .int_list => scalarMultiplyList(vm, x.as.byte, y.as.int_list, .int_list),
            .long => scalarMultiplyScalar(vm, x.as.byte, y.as.long, .long),
            .long_list => scalarMultiplyList(vm, x.as.byte, y.as.long_list, .long_list),
            .real => scalarMultiplyScalar(vm, x.as.byte, y.as.real, .real),
            .real_list => scalarMultiplyList(vm, x.as.byte, y.as.real_list, .real_list),
            .float => scalarMultiplyScalar(vm, x.as.byte, y.as.float, .float),
            .float_list => scalarMultiplyList(vm, x.as.byte, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .byte_list => switch (y.type) {
            .boolean => listMultiplyScalar(vm, x.as.byte_list, y.as.boolean, .int_list),
            .boolean_list => listMultiplyList(vm, x.as.byte_list, y.as.boolean_list, .int_list),
            .byte => listMultiplyScalar(vm, x.as.byte_list, y.as.byte, .int_list),
            .byte_list => listMultiplyList(vm, x.as.byte_list, y.as.byte_list, .int_list),
            .short => listMultiplyScalar(vm, x.as.byte_list, y.as.short, .int_list),
            .short_list => listMultiplyList(vm, x.as.byte_list, y.as.short_list, .int_list),
            .int => listMultiplyScalar(vm, x.as.byte_list, y.as.int, .int_list),
            .int_list => listMultiplyList(vm, x.as.byte_list, y.as.int_list, .int_list),
            .long => listMultiplyScalar(vm, x.as.byte_list, y.as.long, .long_list),
            .long_list => listMultiplyList(vm, x.as.byte_list, y.as.long_list, .long_list),
            .real => listMultiplyScalar(vm, x.as.byte_list, y.as.real, .real_list),
            .real_list => listMultiplyList(vm, x.as.byte_list, y.as.real_list, .real_list),
            .float => listMultiplyScalar(vm, x.as.byte_list, y.as.float, .float_list),
            .float_list => listMultiplyList(vm, x.as.byte_list, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .short => switch (y.type) {
            .boolean => scalarMultiplyScalar(vm, x.as.short, y.as.boolean, .int),
            .boolean_list => scalarMultiplyList(vm, x.as.short, y.as.boolean_list, .int_list),
            .byte => scalarMultiplyScalar(vm, x.as.short, y.as.byte, .int),
            .byte_list => scalarMultiplyList(vm, x.as.short, y.as.byte_list, .int_list),
            .short => scalarMultiplyScalar(vm, x.as.short, y.as.short, .int),
            .short_list => scalarMultiplyList(vm, x.as.short, y.as.short_list, .int_list),
            .int => scalarMultiplyScalar(vm, x.as.short, y.as.int, .int),
            .int_list => scalarMultiplyList(vm, x.as.short, y.as.int_list, .int_list),
            .long => scalarMultiplyScalar(vm, x.as.short, y.as.long, .long),
            .long_list => scalarMultiplyList(vm, x.as.short, y.as.long_list, .long_list),
            .real => scalarMultiplyScalar(vm, x.as.short, y.as.real, .real),
            .real_list => scalarMultiplyList(vm, x.as.short, y.as.real_list, .real_list),
            .float => scalarMultiplyScalar(vm, x.as.short, y.as.float, .float),
            .float_list => scalarMultiplyList(vm, x.as.short, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .short_list => switch (y.type) {
            .boolean => listMultiplyScalar(vm, x.as.short_list, y.as.boolean, .int_list),
            .boolean_list => listMultiplyList(vm, x.as.short_list, y.as.boolean_list, .int_list),
            .byte => listMultiplyScalar(vm, x.as.short_list, y.as.byte, .int_list),
            .byte_list => listMultiplyList(vm, x.as.short_list, y.as.byte_list, .int_list),
            .short => listMultiplyScalar(vm, x.as.short_list, y.as.short, .int_list),
            .short_list => listMultiplyList(vm, x.as.short_list, y.as.short_list, .int_list),
            .int => listMultiplyScalar(vm, x.as.short_list, y.as.int, .int_list),
            .int_list => listMultiplyList(vm, x.as.short_list, y.as.int_list, .int_list),
            .long => listMultiplyScalar(vm, x.as.short_list, y.as.long, .long_list),
            .long_list => listMultiplyList(vm, x.as.short_list, y.as.long_list, .long_list),
            .real => listMultiplyScalar(vm, x.as.short_list, y.as.real, .real_list),
            .real_list => listMultiplyList(vm, x.as.short_list, y.as.real_list, .real_list),
            .float => listMultiplyScalar(vm, x.as.short_list, y.as.float, .float_list),
            .float_list => listMultiplyList(vm, x.as.short_list, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .int => switch (y.type) {
            .boolean => scalarMultiplyScalar(vm, x.as.int, y.as.boolean, .int),
            .boolean_list => scalarMultiplyList(vm, x.as.int, y.as.boolean_list, .int_list),
            .byte => scalarMultiplyScalar(vm, x.as.int, y.as.byte, .int),
            .byte_list => scalarMultiplyList(vm, x.as.int, y.as.byte_list, .int_list),
            .short => scalarMultiplyScalar(vm, x.as.int, y.as.short, .int),
            .short_list => scalarMultiplyList(vm, x.as.int, y.as.short_list, .int_list),
            .int => scalarMultiplyScalar(vm, x.as.int, y.as.int, .int),
            .int_list => scalarMultiplyList(vm, x.as.int, y.as.int_list, .int_list),
            .long => scalarMultiplyScalar(vm, x.as.int, y.as.long, .long),
            .long_list => scalarMultiplyList(vm, x.as.int, y.as.long_list, .long_list),
            .real => scalarMultiplyScalar(vm, x.as.int, y.as.real, .real),
            .real_list => scalarMultiplyList(vm, x.as.int, y.as.real_list, .real_list),
            .float => scalarMultiplyScalar(vm, x.as.int, y.as.float, .float),
            .float_list => scalarMultiplyList(vm, x.as.int, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .int_list => switch (y.type) {
            .boolean => listMultiplyScalar(vm, x.as.int_list, y.as.boolean, .int_list),
            .boolean_list => listMultiplyList(vm, x.as.int_list, y.as.boolean_list, .int_list),
            .byte => listMultiplyScalar(vm, x.as.int_list, y.as.byte, .int_list),
            .byte_list => listMultiplyList(vm, x.as.int_list, y.as.byte_list, .int_list),
            .short => listMultiplyScalar(vm, x.as.int_list, y.as.short, .int_list),
            .short_list => listMultiplyList(vm, x.as.int_list, y.as.short_list, .int_list),
            .int => listMultiplyScalar(vm, x.as.int_list, y.as.int, .int_list),
            .int_list => listMultiplyList(vm, x.as.int_list, y.as.int_list, .int_list),
            .long => listMultiplyScalar(vm, x.as.int_list, y.as.long, .long_list),
            .long_list => listMultiplyList(vm, x.as.int_list, y.as.long_list, .long_list),
            .real => listMultiplyScalar(vm, x.as.int_list, y.as.real, .real_list),
            .real_list => listMultiplyList(vm, x.as.int_list, y.as.real_list, .real_list),
            .float => listMultiplyScalar(vm, x.as.int_list, y.as.float, .float_list),
            .float_list => listMultiplyList(vm, x.as.int_list, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .long => switch (y.type) {
            .boolean => scalarMultiplyScalar(vm, x.as.long, y.as.boolean, .long),
            .boolean_list => scalarMultiplyList(vm, x.as.long, y.as.boolean_list, .long_list),
            .byte => scalarMultiplyScalar(vm, x.as.long, y.as.byte, .long),
            .byte_list => scalarMultiplyList(vm, x.as.long, y.as.byte_list, .long_list),
            .short => scalarMultiplyScalar(vm, x.as.long, y.as.short, .long),
            .short_list => scalarMultiplyList(vm, x.as.long, y.as.short_list, .long_list),
            .int => scalarMultiplyScalar(vm, x.as.long, y.as.int, .long),
            .int_list => scalarMultiplyList(vm, x.as.long, y.as.int_list, .long_list),
            .long => scalarMultiplyScalar(vm, x.as.long, y.as.long, .long),
            .long_list => scalarMultiplyList(vm, x.as.long, y.as.long_list, .long_list),
            .real => scalarMultiplyScalar(vm, x.as.long, y.as.real, .real),
            .real_list => scalarMultiplyList(vm, x.as.long, y.as.real_list, .real_list),
            .float => scalarMultiplyScalar(vm, x.as.long, y.as.float, .float),
            .float_list => scalarMultiplyList(vm, x.as.long, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .long_list => switch (y.type) {
            .boolean => listMultiplyScalar(vm, x.as.long_list, y.as.boolean, .long_list),
            .boolean_list => listMultiplyList(vm, x.as.long_list, y.as.boolean_list, .long_list),
            .byte => listMultiplyScalar(vm, x.as.long_list, y.as.byte, .long_list),
            .byte_list => listMultiplyList(vm, x.as.long_list, y.as.byte_list, .long_list),
            .short => listMultiplyScalar(vm, x.as.long_list, y.as.short, .long_list),
            .short_list => listMultiplyList(vm, x.as.long_list, y.as.short_list, .long_list),
            .int => listMultiplyScalar(vm, x.as.long_list, y.as.int, .long_list),
            .int_list => listMultiplyList(vm, x.as.long_list, y.as.int_list, .long_list),
            .long => listMultiplyScalar(vm, x.as.long_list, y.as.long, .long_list),
            .long_list => listMultiplyList(vm, x.as.long_list, y.as.long_list, .long_list),
            .real => listMultiplyScalar(vm, x.as.long_list, y.as.real, .real_list),
            .real_list => listMultiplyList(vm, x.as.long_list, y.as.real_list, .real_list),
            .float => listMultiplyScalar(vm, x.as.long_list, y.as.float, .float_list),
            .float_list => listMultiplyList(vm, x.as.long_list, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .real => switch (y.type) {
            .boolean => scalarMultiplyScalar(vm, x.as.real, y.as.boolean, .real),
            .boolean_list => scalarMultiplyList(vm, x.as.real, y.as.boolean_list, .real_list),
            .byte => scalarMultiplyScalar(vm, x.as.real, y.as.byte, .real),
            .byte_list => scalarMultiplyList(vm, x.as.real, y.as.byte_list, .real_list),
            .short => scalarMultiplyScalar(vm, x.as.real, y.as.short, .real),
            .short_list => scalarMultiplyList(vm, x.as.real, y.as.short_list, .real_list),
            .int => scalarMultiplyScalar(vm, x.as.real, y.as.int, .real),
            .int_list => scalarMultiplyList(vm, x.as.real, y.as.int_list, .real_list),
            .long => scalarMultiplyScalar(vm, x.as.real, y.as.long, .real),
            .long_list => scalarMultiplyList(vm, x.as.real, y.as.long_list, .real_list),
            .real => scalarMultiplyScalar(vm, x.as.real, y.as.real, .real),
            .real_list => scalarMultiplyList(vm, x.as.real, y.as.real_list, .real_list),
            .float => scalarMultiplyScalar(vm, x.as.real, y.as.float, .float),
            .float_list => scalarMultiplyList(vm, x.as.real, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .real_list => switch (y.type) {
            .boolean => listMultiplyScalar(vm, x.as.real_list, y.as.boolean, .real_list),
            .boolean_list => listMultiplyList(vm, x.as.real_list, y.as.boolean_list, .real_list),
            .byte => listMultiplyScalar(vm, x.as.real_list, y.as.byte, .real_list),
            .byte_list => listMultiplyList(vm, x.as.real_list, y.as.byte_list, .real_list),
            .short => listMultiplyScalar(vm, x.as.real_list, y.as.short, .real_list),
            .short_list => listMultiplyList(vm, x.as.real_list, y.as.short_list, .real_list),
            .int => listMultiplyScalar(vm, x.as.real_list, y.as.int, .real_list),
            .int_list => listMultiplyList(vm, x.as.real_list, y.as.int_list, .real_list),
            .long => listMultiplyScalar(vm, x.as.real_list, y.as.long, .real_list),
            .long_list => listMultiplyList(vm, x.as.real_list, y.as.long_list, .real_list),
            .real => listMultiplyScalar(vm, x.as.real_list, y.as.real, .real_list),
            .real_list => listMultiplyList(vm, x.as.real_list, y.as.real_list, .real_list),
            .float => listMultiplyScalar(vm, x.as.real_list, y.as.float, .float_list),
            .float_list => listMultiplyList(vm, x.as.real_list, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .float => switch (y.type) {
            .boolean => scalarMultiplyScalar(vm, x.as.float, y.as.boolean, .float),
            .boolean_list => scalarMultiplyList(vm, x.as.float, y.as.boolean_list, .float_list),
            .byte => scalarMultiplyScalar(vm, x.as.float, y.as.byte, .float),
            .byte_list => scalarMultiplyList(vm, x.as.float, y.as.byte_list, .float_list),
            .short => scalarMultiplyScalar(vm, x.as.float, y.as.short, .float),
            .short_list => scalarMultiplyList(vm, x.as.float, y.as.short_list, .float_list),
            .int => scalarMultiplyScalar(vm, x.as.float, y.as.int, .float),
            .int_list => scalarMultiplyList(vm, x.as.float, y.as.int_list, .float_list),
            .long => scalarMultiplyScalar(vm, x.as.float, y.as.long, .float),
            .long_list => scalarMultiplyList(vm, x.as.float, y.as.long_list, .float_list),
            .real => scalarMultiplyScalar(vm, x.as.float, y.as.real, .float),
            .real_list => scalarMultiplyList(vm, x.as.float, y.as.real_list, .float_list),
            .float => scalarMultiplyScalar(vm, x.as.float, y.as.float, .float),
            .float_list => scalarMultiplyList(vm, x.as.float, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .float_list => switch (y.type) {
            .boolean => listMultiplyScalar(vm, x.as.float_list, y.as.boolean, .float_list),
            .boolean_list => listMultiplyList(vm, x.as.float_list, y.as.boolean_list, .float_list),
            .byte => listMultiplyScalar(vm, x.as.float_list, y.as.byte, .float_list),
            .byte_list => listMultiplyList(vm, x.as.float_list, y.as.byte_list, .float_list),
            .short => listMultiplyScalar(vm, x.as.float_list, y.as.short, .float_list),
            .short_list => listMultiplyList(vm, x.as.float_list, y.as.short_list, .float_list),
            .int => listMultiplyScalar(vm, x.as.float_list, y.as.int, .float_list),
            .int_list => listMultiplyList(vm, x.as.float_list, y.as.int_list, .float_list),
            .long => listMultiplyScalar(vm, x.as.float_list, y.as.long, .float_list),
            .long_list => listMultiplyList(vm, x.as.float_list, y.as.long_list, .float_list),
            .real => listMultiplyScalar(vm, x.as.float_list, y.as.real, .float_list),
            .real_list => listMultiplyList(vm, x.as.float_list, y.as.real_list, .float_list),
            .float => listMultiplyScalar(vm, x.as.float_list, y.as.float, .float_list),
            .float_list => listMultiplyList(vm, x.as.float_list, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        else => @panic("NYI"),
    };
}

fn scalarMultiplyScalar(vm: *Vm, scalar1: anytype, scalar2: anytype, comptime result_type: Value.Type) !*Value {
    const value = cast(result_type, scalar1) * cast(result_type, scalar2);
    return vm.create(result_type, value);
}

fn scalarMultiplyList(vm: *Vm, scalar: anytype, list: anytype, comptime result_type: Value.Type) !*Value {
    const T = FromType(result_type);
    const result_list = try vm.gpa.alloc(T, list.len);

    for (list, result_list) |item, *result| {
        result.* = cast(result_type, scalar) * cast(result_type, item);
    }

    return vm.create(result_type, result_list);
}

fn listMultiplyScalar(vm: *Vm, list: anytype, scalar: anytype, comptime result_type: Value.Type) !*Value {
    const T = FromType(result_type);
    const result_list = try vm.gpa.alloc(T, list.len);

    for (list, result_list) |item, *result| {
        result.* = cast(result_type, item) * cast(result_type, scalar);
    }

    return vm.create(result_type, result_list);
}

fn listMultiplyList(vm: *Vm, list1: anytype, list2: anytype, comptime result_type: Value.Type) !*Value {
    if (list1.len != list2.len) @panic("length");

    const T = FromType(result_type);
    const result_list = try vm.gpa.alloc(T, list1.len);

    for (list1, list2, result_list) |x, y, *result| {
        result.* = cast(result_type, x) * cast(result_type, y);
    }

    return vm.create(result_type, result_list);
}

fn testMultiply(
    comptime x_type: Value.Type,
    x_val: anytype,
    comptime y_type: Value.Type,
    y_val: anytype,
    comptime expected_type: Value.Type,
    expected: anytype,
) !void {
    const gpa = testing.allocator;
    var vm: Vm = undefined;
    try vm.init(gpa);
    defer vm.deinit();

    const x = switch (x_type) {
        .boolean => try vm.createBoolean(x_val),
        .boolean_list => blk: {
            const list = try vm.gpa.dupe(bool, x_val);
            break :blk try vm.createBooleanList(list);
        },
        .byte => try vm.createByte(x_val),
        .byte_list => blk: {
            const list = try vm.gpa.dupe(u8, x_val);
            break :blk try vm.createByteList(list);
        },
        .short => try vm.createShort(x_val),
        .short_list => blk: {
            const list = try vm.gpa.dupe(i16, x_val);
            break :blk try vm.createShortList(list);
        },
        .int => try vm.createInt(x_val),
        .int_list => blk: {
            const list = try vm.gpa.dupe(i32, x_val);
            break :blk try vm.createIntList(list);
        },
        .long => try vm.createLong(x_val),
        .long_list => blk: {
            const list = try vm.gpa.dupe(i64, x_val);
            break :blk try vm.createLongList(list);
        },
        .real => try vm.createReal(x_val),
        .real_list => blk: {
            const list = try vm.gpa.dupe(f32, x_val);
            break :blk try vm.createRealList(list);
        },
        .float => try vm.createFloat(x_val),
        .float_list => blk: {
            const list = try vm.gpa.dupe(f64, x_val);
            break :blk try vm.createFloatList(list);
        },
        else => comptime unreachable,
    };
    defer x.deref(gpa);

    const y = switch (y_type) {
        .boolean => try vm.createBoolean(y_val),
        .boolean_list => blk: {
            const list = try vm.gpa.dupe(bool, y_val);
            break :blk try vm.createBooleanList(list);
        },
        .byte => try vm.createByte(y_val),
        .byte_list => blk: {
            const list = try vm.gpa.dupe(u8, y_val);
            break :blk try vm.createByteList(list);
        },
        .short => try vm.createShort(y_val),
        .short_list => blk: {
            const list = try vm.gpa.dupe(i16, y_val);
            break :blk try vm.createShortList(list);
        },
        .int => try vm.createInt(y_val),
        .int_list => blk: {
            const list = try vm.gpa.dupe(i32, y_val);
            break :blk try vm.createIntList(list);
        },
        .long => try vm.createLong(y_val),
        .long_list => blk: {
            const list = try vm.gpa.dupe(i64, y_val);
            break :blk try vm.createLongList(list);
        },
        .real => try vm.createReal(y_val),
        .real_list => blk: {
            const list = try vm.gpa.dupe(f32, y_val);
            break :blk try vm.createRealList(list);
        },
        .float => try vm.createFloat(y_val),
        .float_list => blk: {
            const list = try vm.gpa.dupe(f64, y_val);
            break :blk try vm.createFloatList(list);
        },
        else => comptime unreachable,
    };
    defer y.deref(gpa);

    const actual = try impl(&vm, x, y);
    defer actual.deref(gpa);

    try testing.expectEqual(expected_type, actual.type);

    switch (expected_type) {
        .int => try testing.expectEqual(expected, actual.as.int),
        .int_list => try testing.expectEqualSlices(i32, expected, actual.as.int_list),
        .long => try testing.expectEqual(expected, actual.as.long),
        .long_list => try testing.expectEqualSlices(i64, expected, actual.as.long_list),
        .real => try testing.expectEqual(expected, actual.as.real),
        .real_list => try testing.expectEqualSlices(f32, expected, actual.as.real_list),
        .float => try testing.expectEqual(expected, actual.as.float),
        .float_list => try testing.expectEqualSlices(f64, expected, actual.as.float_list),
        else => comptime unreachable,
    }
}

test "boolean" {
    // boolean * scalar
    try testMultiply(.boolean, true, .boolean, false, .int, 0);
    try testMultiply(.boolean, true, .byte, 5, .int, 5);
    try testMultiply(.boolean, true, .short, 10, .int, 10);
    try testMultiply(.boolean, true, .int, 100, .int, 100);
    try testMultiply(.boolean, true, .long, 1000, .long, 1000);
    try testMultiply(.boolean, true, .real, 2.5, .real, 2.5);
    try testMultiply(.boolean, true, .float, 2.5, .float, 2.5);

    // boolean * list
    try testMultiply(.boolean, true, .boolean_list, &.{ false, true, false }, .int_list, &[_]i32{ 0, 1, 0 });
    try testMultiply(.boolean, true, .byte_list, &[_]u8{ 1, 2, 3 }, .int_list, &[_]i32{ 1, 2, 3 });
    try testMultiply(.boolean, true, .short_list, &[_]i16{ 1, 2, 3 }, .int_list, &[_]i32{ 1, 2, 3 });
    try testMultiply(.boolean, true, .int_list, &[_]i32{ 1, 2, 3 }, .int_list, &[_]i32{ 1, 2, 3 });
    try testMultiply(.boolean, true, .long_list, &[_]i64{ 1, 2, 3 }, .long_list, &[_]i64{ 1, 2, 3 });
    try testMultiply(.boolean, true, .real_list, &[_]f32{ 1.0, 2.0, 3.0 }, .real_list, &[_]f32{ 1.0, 2.0, 3.0 });
    try testMultiply(.boolean, true, .float_list, &[_]f64{ 1.0, 2.0, 3.0 }, .float_list, &[_]f64{ 1.0, 2.0, 3.0 });

    // boolean_list * scalar
    try testMultiply(.boolean_list, &.{ true, false, true }, .boolean, false, .int_list, &[_]i32{ 0, 0, 0 });
    try testMultiply(.boolean_list, &.{ true, false, true }, .byte, 5, .int_list, &[_]i32{ 5, 0, 5 });
    try testMultiply(.boolean_list, &.{ true, false, true }, .short, 10, .int_list, &[_]i32{ 10, 0, 10 });
    try testMultiply(.boolean_list, &.{ true, false, true }, .int, 100, .int_list, &[_]i32{ 100, 0, 100 });
    try testMultiply(.boolean_list, &.{ true, false, true }, .long, 1000, .long_list, &[_]i64{ 1000, 0, 1000 });
    try testMultiply(.boolean_list, &.{ true, false, true }, .real, 2.5, .real_list, &[_]f32{ 2.5, 0.0, 2.5 });
    try testMultiply(.boolean_list, &.{ true, false, true }, .float, 2.5, .float_list, &[_]f64{ 2.5, 0.0, 2.5 });

    // boolean_list * list
    try testMultiply(.boolean_list, &.{ true, false }, .boolean_list, &.{ false, true }, .int_list, &[_]i32{ 0, 0 });
    try testMultiply(.boolean_list, &.{ true, false }, .byte_list, &[_]u8{ 1, 2 }, .int_list, &[_]i32{ 1, 0 });
    try testMultiply(.boolean_list, &.{ true, false }, .short_list, &[_]i16{ 1, 2 }, .int_list, &[_]i32{ 1, 0 });
    try testMultiply(.boolean_list, &.{ true, false }, .int_list, &[_]i32{ 1, 2 }, .int_list, &[_]i32{ 1, 0 });
    try testMultiply(.boolean_list, &.{ true, false }, .long_list, &[_]i64{ 1, 2 }, .long_list, &[_]i64{ 1, 0 });
    try testMultiply(.boolean_list, &.{ true, false }, .real_list, &[_]f32{ 1.5, 2.5 }, .real_list, &[_]f32{ 1.5, 0.0 });
    try testMultiply(.boolean_list, &.{ true, false }, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 1.5, 0.0 });
}

test "byte" {
    // byte * scalar
    try testMultiply(.byte, 5, .boolean, true, .int, 5);
    try testMultiply(.byte, 5, .byte, 3, .int, 15);
    try testMultiply(.byte, 5, .short, 10, .int, 50);
    try testMultiply(.byte, 5, .int, 100, .int, 500);
    try testMultiply(.byte, 5, .long, 1000, .long, 5000);
    try testMultiply(.byte, 5, .real, 2.5, .real, 12.5);
    try testMultiply(.byte, 5, .float, 2.5, .float, 12.5);

    // byte * list
    try testMultiply(.byte, 5, .boolean_list, &.{ true, false, true }, .int_list, &[_]i32{ 5, 0, 5 });
    try testMultiply(.byte, 5, .byte_list, &[_]u8{ 1, 2, 3 }, .int_list, &[_]i32{ 5, 10, 15 });
    try testMultiply(.byte, 5, .short_list, &[_]i16{ 1, 2, 3 }, .int_list, &[_]i32{ 5, 10, 15 });
    try testMultiply(.byte, 5, .int_list, &[_]i32{ 1, 2, 3 }, .int_list, &[_]i32{ 5, 10, 15 });
    try testMultiply(.byte, 5, .long_list, &[_]i64{ 1, 2, 3 }, .long_list, &[_]i64{ 5, 10, 15 });
    try testMultiply(.byte, 5, .real_list, &[_]f32{ 1.5, 2.5, 3.5 }, .real_list, &[_]f32{ 7.5, 12.5, 17.5 });
    try testMultiply(.byte, 5, .float_list, &[_]f64{ 1.5, 2.5, 3.5 }, .float_list, &[_]f64{ 7.5, 12.5, 17.5 });

    // byte_list * scalar
    try testMultiply(.byte_list, &[_]u8{ 1, 2, 3 }, .boolean, true, .int_list, &[_]i32{ 1, 2, 3 });
    try testMultiply(.byte_list, &[_]u8{ 2, 3, 4 }, .byte, 5, .int_list, &[_]i32{ 10, 15, 20 });
    try testMultiply(.byte_list, &[_]u8{ 1, 2, 3 }, .short, 10, .int_list, &[_]i32{ 10, 20, 30 });
    try testMultiply(.byte_list, &[_]u8{ 1, 2, 3 }, .int, 100, .int_list, &[_]i32{ 100, 200, 300 });
    try testMultiply(.byte_list, &[_]u8{ 1, 2, 3 }, .long, 1000, .long_list, &[_]i64{ 1000, 2000, 3000 });
    try testMultiply(.byte_list, &[_]u8{ 2, 4, 6 }, .real, 2.5, .real_list, &[_]f32{ 5.0, 10.0, 15.0 });
    try testMultiply(.byte_list, &[_]u8{ 2, 4, 6 }, .float, 2.5, .float_list, &[_]f64{ 5.0, 10.0, 15.0 });

    // byte_list * list
    try testMultiply(.byte_list, &[_]u8{ 2, 2 }, .boolean_list, &.{ true, false }, .int_list, &[_]i32{ 2, 0 });
    try testMultiply(.byte_list, &[_]u8{ 2, 3, 4 }, .byte_list, &[_]u8{ 1, 2, 3 }, .int_list, &[_]i32{ 2, 6, 12 });
    try testMultiply(.byte_list, &[_]u8{ 2, 3 }, .short_list, &[_]i16{ 10, 20 }, .int_list, &[_]i32{ 20, 60 });
    try testMultiply(.byte_list, &[_]u8{ 2, 3 }, .int_list, &[_]i32{ 100, 200 }, .int_list, &[_]i32{ 200, 600 });
    try testMultiply(.byte_list, &[_]u8{ 2, 3 }, .long_list, &[_]i64{ 1000, 2000 }, .long_list, &[_]i64{ 2000, 6000 });
    try testMultiply(.byte_list, &[_]u8{ 2, 4 }, .real_list, &[_]f32{ 1.5, 2.5 }, .real_list, &[_]f32{ 3.0, 10.0 });
    try testMultiply(.byte_list, &[_]u8{ 2, 4 }, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 3.0, 10.0 });
}

test "short" {
    // short * scalar
    try testMultiply(.short, 10, .boolean, true, .int, 10);
    try testMultiply(.short, 10, .byte, 5, .int, 50);
    try testMultiply(.short, 10, .short, 20, .int, 200);
    try testMultiply(.short, 10, .int, 500, .int, 5000);
    try testMultiply(.short, 10, .long, 2000, .long, 20000);
    try testMultiply(.short, 10, .real, 1.5, .real, 15.0);
    try testMultiply(.short, 10, .float, 1.5, .float, 15.0);

    // short * list
    try testMultiply(.short, 10, .boolean_list, &.{ true, false }, .int_list, &[_]i32{ 10, 0 });
    try testMultiply(.short, 10, .byte_list, &[_]u8{ 1, 2 }, .int_list, &[_]i32{ 10, 20 });
    try testMultiply(.short, 10, .short_list, &[_]i16{ 1, 2, 3 }, .int_list, &[_]i32{ 10, 20, 30 });
    try testMultiply(.short, 10, .int_list, &[_]i32{ 1, 2 }, .int_list, &[_]i32{ 10, 20 });
    try testMultiply(.short, 10, .long_list, &[_]i64{ 1, 2 }, .long_list, &[_]i64{ 10, 20 });
    try testMultiply(.short, 10, .real_list, &[_]f32{ 1.5, 2.5 }, .real_list, &[_]f32{ 15.0, 25.0 });
    try testMultiply(.short, 10, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 15.0, 25.0 });

    // short_list * scalar
    try testMultiply(.short_list, &[_]i16{ 1, 2, 3 }, .boolean, true, .int_list, &[_]i32{ 1, 2, 3 });
    try testMultiply(.short_list, &[_]i16{ 1, 2, 3 }, .byte, 5, .int_list, &[_]i32{ 5, 10, 15 });
    try testMultiply(.short_list, &[_]i16{ 1, 2, 3 }, .short, 10, .int_list, &[_]i32{ 10, 20, 30 });
    try testMultiply(.short_list, &[_]i16{ 1, 2, 3 }, .int, 100, .int_list, &[_]i32{ 100, 200, 300 });
    try testMultiply(.short_list, &[_]i16{ 1, 2, 3 }, .long, 1000, .long_list, &[_]i64{ 1000, 2000, 3000 });
    try testMultiply(.short_list, &[_]i16{ 2, 3, 4 }, .real, 1.5, .real_list, &[_]f32{ 3.0, 4.5, 6.0 });
    try testMultiply(.short_list, &[_]i16{ 2, 3, 4 }, .float, 1.5, .float_list, &[_]f64{ 3.0, 4.5, 6.0 });

    // short_list * list
    try testMultiply(.short_list, &[_]i16{ 2, 2 }, .boolean_list, &.{ true, false }, .int_list, &[_]i32{ 2, 0 });
    try testMultiply(.short_list, &[_]i16{ 2, 3 }, .byte_list, &[_]u8{ 1, 2 }, .int_list, &[_]i32{ 2, 6 });
    try testMultiply(.short_list, &[_]i16{ 2, 3 }, .short_list, &[_]i16{ 4, 5 }, .int_list, &[_]i32{ 8, 15 });
    try testMultiply(.short_list, &[_]i16{ 2, 3 }, .int_list, &[_]i32{ 100, 200 }, .int_list, &[_]i32{ 200, 600 });
    try testMultiply(.short_list, &[_]i16{ 2, 3 }, .long_list, &[_]i64{ 1000, 2000 }, .long_list, &[_]i64{ 2000, 6000 });
    try testMultiply(.short_list, &[_]i16{ 2, 4 }, .real_list, &[_]f32{ 1.5, 2.5 }, .real_list, &[_]f32{ 3.0, 10.0 });
    try testMultiply(.short_list, &[_]i16{ 2, 4 }, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 3.0, 10.0 });
}

test "int" {
    // int * scalar
    try testMultiply(.int, 100, .boolean, true, .int, 100);
    try testMultiply(.int, 100, .byte, 5, .int, 500);
    try testMultiply(.int, 100, .short, 10, .int, 1000);
    try testMultiply(.int, 100, .int, 200, .int, 20000);
    try testMultiply(.int, 100, .long, 5000, .long, 500000);
    try testMultiply(.int, 100, .real, 0.5, .real, 50.0);
    try testMultiply(.int, 100, .float, 0.5, .float, 50.0);

    // int * list
    try testMultiply(.int, 100, .boolean_list, &.{ true, false }, .int_list, &[_]i32{ 100, 0 });
    try testMultiply(.int, 100, .byte_list, &[_]u8{ 1, 2 }, .int_list, &[_]i32{ 100, 200 });
    try testMultiply(.int, 100, .short_list, &[_]i16{ 1, 2 }, .int_list, &[_]i32{ 100, 200 });
    try testMultiply(.int, 10, .int_list, &[_]i32{ 1, 2, 3 }, .int_list, &[_]i32{ 10, 20, 30 });
    try testMultiply(.int, 100, .long_list, &[_]i64{ 1, 2 }, .long_list, &[_]i64{ 100, 200 });
    try testMultiply(.int, 100, .real_list, &[_]f32{ 1.5, 2.5 }, .real_list, &[_]f32{ 150.0, 250.0 });
    try testMultiply(.int, 100, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 150.0, 250.0 });

    // int_list * scalar
    try testMultiply(.int_list, &[_]i32{ 1, 2, 3 }, .boolean, true, .int_list, &[_]i32{ 1, 2, 3 });
    try testMultiply(.int_list, &[_]i32{ 1, 2, 3 }, .byte, 5, .int_list, &[_]i32{ 5, 10, 15 });
    try testMultiply(.int_list, &[_]i32{ 1, 2, 3 }, .short, 10, .int_list, &[_]i32{ 10, 20, 30 });
    try testMultiply(.int_list, &[_]i32{ 1, 2, 3 }, .int, 10, .int_list, &[_]i32{ 10, 20, 30 });
    try testMultiply(.int_list, &[_]i32{ 1, 2, 3 }, .long, 1000, .long_list, &[_]i64{ 1000, 2000, 3000 });
    try testMultiply(.int_list, &[_]i32{ 2, 4, 6 }, .real, 1.5, .real_list, &[_]f32{ 3.0, 6.0, 9.0 });
    try testMultiply(.int_list, &[_]i32{ 2, 4, 6 }, .float, 1.5, .float_list, &[_]f64{ 3.0, 6.0, 9.0 });

    // int_list * list
    try testMultiply(.int_list, &[_]i32{ 2, 2 }, .boolean_list, &.{ true, false }, .int_list, &[_]i32{ 2, 0 });
    try testMultiply(.int_list, &[_]i32{ 10, 20 }, .byte_list, &[_]u8{ 1, 2 }, .int_list, &[_]i32{ 10, 40 });
    try testMultiply(.int_list, &[_]i32{ 10, 20 }, .short_list, &[_]i16{ 1, 2 }, .int_list, &[_]i32{ 10, 40 });
    try testMultiply(.int_list, &[_]i32{ 2, 3, 4 }, .int_list, &[_]i32{ 5, 6, 7 }, .int_list, &[_]i32{ 10, 18, 28 });
    try testMultiply(.int_list, &[_]i32{ 10, 20 }, .long_list, &[_]i64{ 1000, 2000 }, .long_list, &[_]i64{ 10000, 40000 });
    try testMultiply(.int_list, &[_]i32{ 2, 4 }, .real_list, &[_]f32{ 1.5, 2.5 }, .real_list, &[_]f32{ 3.0, 10.0 });
    try testMultiply(.int_list, &[_]i32{ 2, 4 }, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 3.0, 10.0 });
}

test "long" {
    // long * scalar
    try testMultiply(.long, 1000, .boolean, true, .long, 1000);
    try testMultiply(.long, 1000, .byte, 5, .long, 5000);
    try testMultiply(.long, 1000, .short, 10, .long, 10000);
    try testMultiply(.long, 1000, .int, 100, .long, 100000);
    try testMultiply(.long, 1000, .long, 2000, .long, 2000000);
    try testMultiply(.long, 1000, .real, 0.25, .real, 250.0);
    try testMultiply(.long, 1000, .float, 0.25, .float, 250.0);

    // long * list
    try testMultiply(.long, 1000, .boolean_list, &.{ true, false }, .long_list, &[_]i64{ 1000, 0 });
    try testMultiply(.long, 1000, .byte_list, &[_]u8{ 1, 2 }, .long_list, &[_]i64{ 1000, 2000 });
    try testMultiply(.long, 1000, .short_list, &[_]i16{ 1, 2 }, .long_list, &[_]i64{ 1000, 2000 });
    try testMultiply(.long, 1000, .int_list, &[_]i32{ 1, 2 }, .long_list, &[_]i64{ 1000, 2000 });
    try testMultiply(.long, 5, .long_list, &[_]i64{ 10, 20, 30 }, .long_list, &[_]i64{ 50, 100, 150 });
    try testMultiply(.long, 1000, .real_list, &[_]f32{ 1.5, 2.5 }, .real_list, &[_]f32{ 1500.0, 2500.0 });
    try testMultiply(.long, 1000, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 1500.0, 2500.0 });

    // long_list * scalar
    try testMultiply(.long_list, &[_]i64{ 1, 2, 3 }, .boolean, true, .long_list, &[_]i64{ 1, 2, 3 });
    try testMultiply(.long_list, &[_]i64{ 1, 2, 3 }, .byte, 5, .long_list, &[_]i64{ 5, 10, 15 });
    try testMultiply(.long_list, &[_]i64{ 1, 2, 3 }, .short, 10, .long_list, &[_]i64{ 10, 20, 30 });
    try testMultiply(.long_list, &[_]i64{ 1, 2, 3 }, .int, 100, .long_list, &[_]i64{ 100, 200, 300 });
    try testMultiply(.long_list, &[_]i64{ 10, 20, 30 }, .long, 5, .long_list, &[_]i64{ 50, 100, 150 });
    try testMultiply(.long_list, &[_]i64{ 2, 4, 6 }, .real, 1.5, .real_list, &[_]f32{ 3.0, 6.0, 9.0 });
    try testMultiply(.long_list, &[_]i64{ 2, 4, 6 }, .float, 1.5, .float_list, &[_]f64{ 3.0, 6.0, 9.0 });

    // long_list * list
    try testMultiply(.long_list, &[_]i64{ 2, 2 }, .boolean_list, &.{ true, false }, .long_list, &[_]i64{ 2, 0 });
    try testMultiply(.long_list, &[_]i64{ 100, 200 }, .byte_list, &[_]u8{ 1, 2 }, .long_list, &[_]i64{ 100, 400 });
    try testMultiply(.long_list, &[_]i64{ 100, 200 }, .short_list, &[_]i16{ 1, 2 }, .long_list, &[_]i64{ 100, 400 });
    try testMultiply(.long_list, &[_]i64{ 100, 200 }, .int_list, &[_]i32{ 1, 2 }, .long_list, &[_]i64{ 100, 400 });
    try testMultiply(.long_list, &[_]i64{ 10, 20 }, .long_list, &[_]i64{ 5, 15 }, .long_list, &[_]i64{ 50, 300 });
    try testMultiply(.long_list, &[_]i64{ 2, 4 }, .real_list, &[_]f32{ 1.5, 2.5 }, .real_list, &[_]f32{ 3.0, 10.0 });
    try testMultiply(.long_list, &[_]i64{ 2, 4 }, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 3.0, 10.0 });
}

test "real" {
    // real * scalar
    try testMultiply(.real, 1.5, .boolean, true, .real, 1.5);
    try testMultiply(.real, 1.5, .byte, 5, .real, 7.5);
    try testMultiply(.real, 1.5, .short, 10, .real, 15.0);
    try testMultiply(.real, 1.5, .int, 100, .real, 150.0);
    try testMultiply(.real, 1.5, .long, 1000, .real, 1500.0);
    try testMultiply(.real, 1.5, .real, 2.5, .real, 3.75);
    try testMultiply(.real, 1.5, .float, 2.0, .float, 3.0);

    // real * list
    try testMultiply(.real, 1.5, .boolean_list, &.{ true, false }, .real_list, &[_]f32{ 1.5, 0.0 });
    try testMultiply(.real, 1.5, .byte_list, &[_]u8{ 2, 4 }, .real_list, &[_]f32{ 3.0, 6.0 });
    try testMultiply(.real, 1.5, .short_list, &[_]i16{ 2, 4 }, .real_list, &[_]f32{ 3.0, 6.0 });
    try testMultiply(.real, 1.5, .int_list, &[_]i32{ 2, 4 }, .real_list, &[_]f32{ 3.0, 6.0 });
    try testMultiply(.real, 1.5, .long_list, &[_]i64{ 2, 4 }, .real_list, &[_]f32{ 3.0, 6.0 });
    try testMultiply(.real, 2.0, .real_list, &[_]f32{ 1.5, 2.5 }, .real_list, &[_]f32{ 3.0, 5.0 });
    try testMultiply(.real, 1.5, .float_list, &[_]f64{ 2.0, 4.0 }, .float_list, &[_]f64{ 3.0, 6.0 });

    // real_list * scalar
    try testMultiply(.real_list, &[_]f32{ 1, 2, 3 }, .boolean, true, .real_list, &[_]f32{ 1, 2, 3 });
    try testMultiply(.real_list, &[_]f32{ 1, 2, 3 }, .byte, 5, .real_list, &[_]f32{ 5, 10, 15 });
    try testMultiply(.real_list, &[_]f32{ 1, 2, 3 }, .short, 10, .real_list, &[_]f32{ 10, 20, 30 });
    try testMultiply(.real_list, &[_]f32{ 1, 2, 3 }, .int, 100, .real_list, &[_]f32{ 100, 200, 300 });
    try testMultiply(.real_list, &[_]f32{ 1, 2, 3 }, .long, 1000, .real_list, &[_]f32{ 1000, 2000, 3000 });
    try testMultiply(.real_list, &[_]f32{ 1.5, 2.5 }, .real, 2.0, .real_list, &[_]f32{ 3.0, 5.0 });
    try testMultiply(.real_list, &[_]f32{ 1.5, 2.5 }, .float, 2.0, .float_list, &[_]f64{ 3.0, 5.0 });

    // real_list * list
    try testMultiply(.real_list, &[_]f32{ 2, 2 }, .boolean_list, &.{ true, false }, .real_list, &[_]f32{ 2, 0 });
    try testMultiply(.real_list, &[_]f32{ 1.5, 2.5 }, .byte_list, &[_]u8{ 2, 4 }, .real_list, &[_]f32{ 3.0, 10.0 });
    try testMultiply(.real_list, &[_]f32{ 1.5, 2.5 }, .short_list, &[_]i16{ 2, 4 }, .real_list, &[_]f32{ 3.0, 10.0 });
    try testMultiply(.real_list, &[_]f32{ 1.5, 2.5 }, .int_list, &[_]i32{ 2, 4 }, .real_list, &[_]f32{ 3.0, 10.0 });
    try testMultiply(.real_list, &[_]f32{ 1.5, 2.5 }, .long_list, &[_]i64{ 2, 4 }, .real_list, &[_]f32{ 3.0, 10.0 });
    try testMultiply(.real_list, &[_]f32{ 1.0, 2.0 }, .real_list, &[_]f32{ 1.5, 2.5 }, .real_list, &[_]f32{ 1.5, 5.0 });
    try testMultiply(.real_list, &[_]f32{ 1.0, 2.0 }, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 1.5, 5.0 });
}

test "float" {
    // float * scalar
    try testMultiply(.float, 1.5, .boolean, true, .float, 1.5);
    try testMultiply(.float, 1.5, .byte, 5, .float, 7.5);
    try testMultiply(.float, 1.5, .short, 10, .float, 15.0);
    try testMultiply(.float, 1.5, .int, 100, .float, 150.0);
    try testMultiply(.float, 1.5, .long, 1000, .float, 1500.0);
    try testMultiply(.float, 1.5, .real, 2.5, .float, 3.75);
    try testMultiply(.float, 1.5, .float, 2.5, .float, 3.75);

    // float * list
    try testMultiply(.float, 1.5, .boolean_list, &.{ true, false }, .float_list, &[_]f64{ 1.5, 0.0 });
    try testMultiply(.float, 1.5, .byte_list, &[_]u8{ 2, 4 }, .float_list, &[_]f64{ 3.0, 6.0 });
    try testMultiply(.float, 1.5, .short_list, &[_]i16{ 2, 4 }, .float_list, &[_]f64{ 3.0, 6.0 });
    try testMultiply(.float, 1.5, .int_list, &[_]i32{ 2, 4 }, .float_list, &[_]f64{ 3.0, 6.0 });
    try testMultiply(.float, 1.5, .long_list, &[_]i64{ 2, 4 }, .float_list, &[_]f64{ 3.0, 6.0 });
    try testMultiply(.float, 2.0, .real_list, &[_]f32{ 1.5, 2.5 }, .float_list, &[_]f64{ 3.0, 5.0 });
    try testMultiply(.float, 2.0, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 3.0, 5.0 });

    // float_list * scalar
    try testMultiply(.float_list, &[_]f64{ 1, 2, 3 }, .boolean, true, .float_list, &[_]f64{ 1, 2, 3 });
    try testMultiply(.float_list, &[_]f64{ 1, 2, 3 }, .byte, 5, .float_list, &[_]f64{ 5, 10, 15 });
    try testMultiply(.float_list, &[_]f64{ 1, 2, 3 }, .short, 10, .float_list, &[_]f64{ 10, 20, 30 });
    try testMultiply(.float_list, &[_]f64{ 1, 2, 3 }, .int, 100, .float_list, &[_]f64{ 100, 200, 300 });
    try testMultiply(.float_list, &[_]f64{ 1, 2, 3 }, .long, 1000, .float_list, &[_]f64{ 1000, 2000, 3000 });
    try testMultiply(.float_list, &[_]f64{ 1.5, 2.5 }, .real, 2.0, .float_list, &[_]f64{ 3.0, 5.0 });
    try testMultiply(.float_list, &[_]f64{ 1.5, 2.5 }, .float, 2.0, .float_list, &[_]f64{ 3.0, 5.0 });

    // float_list * list
    try testMultiply(.float_list, &[_]f64{ 2, 2 }, .boolean_list, &.{ true, false }, .float_list, &[_]f64{ 2, 0 });
    try testMultiply(.float_list, &[_]f64{ 1.5, 2.5 }, .byte_list, &[_]u8{ 2, 4 }, .float_list, &[_]f64{ 3.0, 10.0 });
    try testMultiply(.float_list, &[_]f64{ 1.5, 2.5 }, .short_list, &[_]i16{ 2, 4 }, .float_list, &[_]f64{ 3.0, 10.0 });
    try testMultiply(.float_list, &[_]f64{ 1.5, 2.5 }, .int_list, &[_]i32{ 2, 4 }, .float_list, &[_]f64{ 3.0, 10.0 });
    try testMultiply(.float_list, &[_]f64{ 1.5, 2.5 }, .long_list, &[_]i64{ 2, 4 }, .float_list, &[_]f64{ 3.0, 10.0 });
    try testMultiply(.float_list, &[_]f64{ 1.0, 2.0 }, .real_list, &[_]f32{ 1.5, 2.5 }, .float_list, &[_]f64{ 1.5, 5.0 });
    try testMultiply(.float_list, &[_]f64{ 1.0, 2.0 }, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 1.5, 5.0 });
}
