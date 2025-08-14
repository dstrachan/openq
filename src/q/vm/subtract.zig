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
            .boolean => scalarSubtractScalar(vm, x.as.boolean, y.as.boolean, .int),
            .boolean_list => scalarSubtractList(vm, x.as.boolean, y.as.boolean_list, .int_list),
            .byte => scalarSubtractScalar(vm, x.as.boolean, y.as.byte, .int),
            .byte_list => scalarSubtractList(vm, x.as.boolean, y.as.byte_list, .int_list),
            .short => scalarSubtractScalar(vm, x.as.boolean, y.as.short, .int),
            .short_list => scalarSubtractList(vm, x.as.boolean, y.as.short_list, .int_list),
            .int => scalarSubtractScalar(vm, x.as.boolean, y.as.int, .int),
            .int_list => scalarSubtractList(vm, x.as.boolean, y.as.int_list, .int_list),
            .long => scalarSubtractScalar(vm, x.as.boolean, y.as.long, .long),
            .long_list => scalarSubtractList(vm, x.as.boolean, y.as.long_list, .long_list),
            .real => scalarSubtractScalar(vm, x.as.boolean, y.as.real, .real),
            .real_list => scalarSubtractList(vm, x.as.boolean, y.as.real_list, .real_list),
            .float => scalarSubtractScalar(vm, x.as.boolean, y.as.float, .float),
            .float_list => scalarSubtractList(vm, x.as.boolean, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .boolean_list => switch (y.type) {
            .boolean => listSubtractScalar(vm, x.as.boolean_list, y.as.boolean, .int_list),
            .boolean_list => listSubtractList(vm, x.as.boolean_list, y.as.boolean_list, .int_list),
            .byte => listSubtractScalar(vm, x.as.boolean_list, y.as.byte, .int_list),
            .byte_list => listSubtractList(vm, x.as.boolean_list, y.as.byte_list, .int_list),
            .short => listSubtractScalar(vm, x.as.boolean_list, y.as.short, .int_list),
            .short_list => listSubtractList(vm, x.as.boolean_list, y.as.short_list, .int_list),
            .int => listSubtractScalar(vm, x.as.boolean_list, y.as.int, .int_list),
            .int_list => listSubtractList(vm, x.as.boolean_list, y.as.int_list, .int_list),
            .long => listSubtractScalar(vm, x.as.boolean_list, y.as.long, .long_list),
            .long_list => listSubtractList(vm, x.as.boolean_list, y.as.long_list, .long_list),
            .real => listSubtractScalar(vm, x.as.boolean_list, y.as.real, .real_list),
            .real_list => listSubtractList(vm, x.as.boolean_list, y.as.real_list, .real_list),
            .float => listSubtractScalar(vm, x.as.boolean_list, y.as.float, .float_list),
            .float_list => listSubtractList(vm, x.as.boolean_list, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .byte => switch (y.type) {
            .boolean => scalarSubtractScalar(vm, x.as.byte, y.as.boolean, .int),
            .boolean_list => scalarSubtractList(vm, x.as.byte, y.as.boolean_list, .int_list),
            .byte => scalarSubtractScalar(vm, x.as.byte, y.as.byte, .int),
            .byte_list => scalarSubtractList(vm, x.as.byte, y.as.byte_list, .int_list),
            .short => scalarSubtractScalar(vm, x.as.byte, y.as.short, .int),
            .short_list => scalarSubtractList(vm, x.as.byte, y.as.short_list, .int_list),
            .int => scalarSubtractScalar(vm, x.as.byte, y.as.int, .int),
            .int_list => scalarSubtractList(vm, x.as.byte, y.as.int_list, .int_list),
            .long => scalarSubtractScalar(vm, x.as.byte, y.as.long, .long),
            .long_list => scalarSubtractList(vm, x.as.byte, y.as.long_list, .long_list),
            .real => scalarSubtractScalar(vm, x.as.byte, y.as.real, .real),
            .real_list => scalarSubtractList(vm, x.as.byte, y.as.real_list, .real_list),
            .float => scalarSubtractScalar(vm, x.as.byte, y.as.float, .float),
            .float_list => scalarSubtractList(vm, x.as.byte, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .byte_list => switch (y.type) {
            .boolean => listSubtractScalar(vm, x.as.byte_list, y.as.boolean, .int_list),
            .boolean_list => listSubtractList(vm, x.as.byte_list, y.as.boolean_list, .int_list),
            .byte => listSubtractScalar(vm, x.as.byte_list, y.as.byte, .int_list),
            .byte_list => listSubtractList(vm, x.as.byte_list, y.as.byte_list, .int_list),
            .short => listSubtractScalar(vm, x.as.byte_list, y.as.short, .int_list),
            .short_list => listSubtractList(vm, x.as.byte_list, y.as.short_list, .int_list),
            .int => listSubtractScalar(vm, x.as.byte_list, y.as.int, .int_list),
            .int_list => listSubtractList(vm, x.as.byte_list, y.as.int_list, .int_list),
            .long => listSubtractScalar(vm, x.as.byte_list, y.as.long, .long_list),
            .long_list => listSubtractList(vm, x.as.byte_list, y.as.long_list, .long_list),
            .real => listSubtractScalar(vm, x.as.byte_list, y.as.real, .real_list),
            .real_list => listSubtractList(vm, x.as.byte_list, y.as.real_list, .real_list),
            .float => listSubtractScalar(vm, x.as.byte_list, y.as.float, .float_list),
            .float_list => listSubtractList(vm, x.as.byte_list, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .short => switch (y.type) {
            .boolean => scalarSubtractScalar(vm, x.as.short, y.as.boolean, .int),
            .boolean_list => scalarSubtractList(vm, x.as.short, y.as.boolean_list, .int_list),
            .byte => scalarSubtractScalar(vm, x.as.short, y.as.byte, .int),
            .byte_list => scalarSubtractList(vm, x.as.short, y.as.byte_list, .int_list),
            .short => scalarSubtractScalar(vm, x.as.short, y.as.short, .int),
            .short_list => scalarSubtractList(vm, x.as.short, y.as.short_list, .int_list),
            .int => scalarSubtractScalar(vm, x.as.short, y.as.int, .int),
            .int_list => scalarSubtractList(vm, x.as.short, y.as.int_list, .int_list),
            .long => scalarSubtractScalar(vm, x.as.short, y.as.long, .long),
            .long_list => scalarSubtractList(vm, x.as.short, y.as.long_list, .long_list),
            .real => scalarSubtractScalar(vm, x.as.short, y.as.real, .real),
            .real_list => scalarSubtractList(vm, x.as.short, y.as.real_list, .real_list),
            .float => scalarSubtractScalar(vm, x.as.short, y.as.float, .float),
            .float_list => scalarSubtractList(vm, x.as.short, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .short_list => switch (y.type) {
            .boolean => listSubtractScalar(vm, x.as.short_list, y.as.boolean, .int_list),
            .boolean_list => listSubtractList(vm, x.as.short_list, y.as.boolean_list, .int_list),
            .byte => listSubtractScalar(vm, x.as.short_list, y.as.byte, .int_list),
            .byte_list => listSubtractList(vm, x.as.short_list, y.as.byte_list, .int_list),
            .short => listSubtractScalar(vm, x.as.short_list, y.as.short, .int_list),
            .short_list => listSubtractList(vm, x.as.short_list, y.as.short_list, .int_list),
            .int => listSubtractScalar(vm, x.as.short_list, y.as.int, .int_list),
            .int_list => listSubtractList(vm, x.as.short_list, y.as.int_list, .int_list),
            .long => listSubtractScalar(vm, x.as.short_list, y.as.long, .long_list),
            .long_list => listSubtractList(vm, x.as.short_list, y.as.long_list, .long_list),
            .real => listSubtractScalar(vm, x.as.short_list, y.as.real, .real_list),
            .real_list => listSubtractList(vm, x.as.short_list, y.as.real_list, .real_list),
            .float => listSubtractScalar(vm, x.as.short_list, y.as.float, .float_list),
            .float_list => listSubtractList(vm, x.as.short_list, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .int => switch (y.type) {
            .boolean => scalarSubtractScalar(vm, x.as.int, y.as.boolean, .int),
            .boolean_list => scalarSubtractList(vm, x.as.int, y.as.boolean_list, .int_list),
            .byte => scalarSubtractScalar(vm, x.as.int, y.as.byte, .int),
            .byte_list => scalarSubtractList(vm, x.as.int, y.as.byte_list, .int_list),
            .short => scalarSubtractScalar(vm, x.as.int, y.as.short, .int),
            .short_list => scalarSubtractList(vm, x.as.int, y.as.short_list, .int_list),
            .int => scalarSubtractScalar(vm, x.as.int, y.as.int, .int),
            .int_list => scalarSubtractList(vm, x.as.int, y.as.int_list, .int_list),
            .long => scalarSubtractScalar(vm, x.as.int, y.as.long, .long),
            .long_list => scalarSubtractList(vm, x.as.int, y.as.long_list, .long_list),
            .real => scalarSubtractScalar(vm, x.as.int, y.as.real, .real),
            .real_list => scalarSubtractList(vm, x.as.int, y.as.real_list, .real_list),
            .float => scalarSubtractScalar(vm, x.as.int, y.as.float, .float),
            .float_list => scalarSubtractList(vm, x.as.int, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .int_list => switch (y.type) {
            .boolean => listSubtractScalar(vm, x.as.int_list, y.as.boolean, .int_list),
            .boolean_list => listSubtractList(vm, x.as.int_list, y.as.boolean_list, .int_list),
            .byte => listSubtractScalar(vm, x.as.int_list, y.as.byte, .int_list),
            .byte_list => listSubtractList(vm, x.as.int_list, y.as.byte_list, .int_list),
            .short => listSubtractScalar(vm, x.as.int_list, y.as.short, .int_list),
            .short_list => listSubtractList(vm, x.as.int_list, y.as.short_list, .int_list),
            .int => listSubtractScalar(vm, x.as.int_list, y.as.int, .int_list),
            .int_list => listSubtractList(vm, x.as.int_list, y.as.int_list, .int_list),
            .long => listSubtractScalar(vm, x.as.int_list, y.as.long, .long_list),
            .long_list => listSubtractList(vm, x.as.int_list, y.as.long_list, .long_list),
            .real => listSubtractScalar(vm, x.as.int_list, y.as.real, .real_list),
            .real_list => listSubtractList(vm, x.as.int_list, y.as.real_list, .real_list),
            .float => listSubtractScalar(vm, x.as.int_list, y.as.float, .float_list),
            .float_list => listSubtractList(vm, x.as.int_list, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .long => switch (y.type) {
            .boolean => scalarSubtractScalar(vm, x.as.long, y.as.boolean, .long),
            .boolean_list => scalarSubtractList(vm, x.as.long, y.as.boolean_list, .long_list),
            .byte => scalarSubtractScalar(vm, x.as.long, y.as.byte, .long),
            .byte_list => scalarSubtractList(vm, x.as.long, y.as.byte_list, .long_list),
            .short => scalarSubtractScalar(vm, x.as.long, y.as.short, .long),
            .short_list => scalarSubtractList(vm, x.as.long, y.as.short_list, .long_list),
            .int => scalarSubtractScalar(vm, x.as.long, y.as.int, .long),
            .int_list => scalarSubtractList(vm, x.as.long, y.as.int_list, .long_list),
            .long => scalarSubtractScalar(vm, x.as.long, y.as.long, .long),
            .long_list => scalarSubtractList(vm, x.as.long, y.as.long_list, .long_list),
            .real => scalarSubtractScalar(vm, x.as.long, y.as.real, .real),
            .real_list => scalarSubtractList(vm, x.as.long, y.as.real_list, .real_list),
            .float => scalarSubtractScalar(vm, x.as.long, y.as.float, .float),
            .float_list => scalarSubtractList(vm, x.as.long, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .long_list => switch (y.type) {
            .boolean => listSubtractScalar(vm, x.as.long_list, y.as.boolean, .long_list),
            .boolean_list => listSubtractList(vm, x.as.long_list, y.as.boolean_list, .long_list),
            .byte => listSubtractScalar(vm, x.as.long_list, y.as.byte, .long_list),
            .byte_list => listSubtractList(vm, x.as.long_list, y.as.byte_list, .long_list),
            .short => listSubtractScalar(vm, x.as.long_list, y.as.short, .long_list),
            .short_list => listSubtractList(vm, x.as.long_list, y.as.short_list, .long_list),
            .int => listSubtractScalar(vm, x.as.long_list, y.as.int, .long_list),
            .int_list => listSubtractList(vm, x.as.long_list, y.as.int_list, .long_list),
            .long => listSubtractScalar(vm, x.as.long_list, y.as.long, .long_list),
            .long_list => listSubtractList(vm, x.as.long_list, y.as.long_list, .long_list),
            .real => listSubtractScalar(vm, x.as.long_list, y.as.real, .real_list),
            .real_list => listSubtractList(vm, x.as.long_list, y.as.real_list, .real_list),
            .float => listSubtractScalar(vm, x.as.long_list, y.as.float, .float_list),
            .float_list => listSubtractList(vm, x.as.long_list, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .real => switch (y.type) {
            .boolean => scalarSubtractScalar(vm, x.as.real, y.as.boolean, .real),
            .boolean_list => scalarSubtractList(vm, x.as.real, y.as.boolean_list, .real_list),
            .byte => scalarSubtractScalar(vm, x.as.real, y.as.byte, .real),
            .byte_list => scalarSubtractList(vm, x.as.real, y.as.byte_list, .real_list),
            .short => scalarSubtractScalar(vm, x.as.real, y.as.short, .real),
            .short_list => scalarSubtractList(vm, x.as.real, y.as.short_list, .real_list),
            .int => scalarSubtractScalar(vm, x.as.real, y.as.int, .real),
            .int_list => scalarSubtractList(vm, x.as.real, y.as.int_list, .real_list),
            .long => scalarSubtractScalar(vm, x.as.real, y.as.long, .real),
            .long_list => scalarSubtractList(vm, x.as.real, y.as.long_list, .real_list),
            .real => scalarSubtractScalar(vm, x.as.real, y.as.real, .real),
            .real_list => scalarSubtractList(vm, x.as.real, y.as.real_list, .real_list),
            .float => scalarSubtractScalar(vm, x.as.real, y.as.float, .float),
            .float_list => scalarSubtractList(vm, x.as.real, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .real_list => switch (y.type) {
            .boolean => listSubtractScalar(vm, x.as.real_list, y.as.boolean, .real_list),
            .boolean_list => listSubtractList(vm, x.as.real_list, y.as.boolean_list, .real_list),
            .byte => listSubtractScalar(vm, x.as.real_list, y.as.byte, .real_list),
            .byte_list => listSubtractList(vm, x.as.real_list, y.as.byte_list, .real_list),
            .short => listSubtractScalar(vm, x.as.real_list, y.as.short, .real_list),
            .short_list => listSubtractList(vm, x.as.real_list, y.as.short_list, .real_list),
            .int => listSubtractScalar(vm, x.as.real_list, y.as.int, .real_list),
            .int_list => listSubtractList(vm, x.as.real_list, y.as.int_list, .real_list),
            .long => listSubtractScalar(vm, x.as.real_list, y.as.long, .real_list),
            .long_list => listSubtractList(vm, x.as.real_list, y.as.long_list, .real_list),
            .real => listSubtractScalar(vm, x.as.real_list, y.as.real, .real_list),
            .real_list => listSubtractList(vm, x.as.real_list, y.as.real_list, .real_list),
            .float => listSubtractScalar(vm, x.as.real_list, y.as.float, .float_list),
            .float_list => listSubtractList(vm, x.as.real_list, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .float => switch (y.type) {
            .boolean => scalarSubtractScalar(vm, x.as.float, y.as.boolean, .float),
            .boolean_list => scalarSubtractList(vm, x.as.float, y.as.boolean_list, .float_list),
            .byte => scalarSubtractScalar(vm, x.as.float, y.as.byte, .float),
            .byte_list => scalarSubtractList(vm, x.as.float, y.as.byte_list, .float_list),
            .short => scalarSubtractScalar(vm, x.as.float, y.as.short, .float),
            .short_list => scalarSubtractList(vm, x.as.float, y.as.short_list, .float_list),
            .int => scalarSubtractScalar(vm, x.as.float, y.as.int, .float),
            .int_list => scalarSubtractList(vm, x.as.float, y.as.int_list, .float_list),
            .long => scalarSubtractScalar(vm, x.as.float, y.as.long, .float),
            .long_list => scalarSubtractList(vm, x.as.float, y.as.long_list, .float_list),
            .real => scalarSubtractScalar(vm, x.as.float, y.as.real, .float),
            .real_list => scalarSubtractList(vm, x.as.float, y.as.real_list, .float_list),
            .float => scalarSubtractScalar(vm, x.as.float, y.as.float, .float),
            .float_list => scalarSubtractList(vm, x.as.float, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .float_list => switch (y.type) {
            .boolean => listSubtractScalar(vm, x.as.float_list, y.as.boolean, .float_list),
            .boolean_list => listSubtractList(vm, x.as.float_list, y.as.boolean_list, .float_list),
            .byte => listSubtractScalar(vm, x.as.float_list, y.as.byte, .float_list),
            .byte_list => listSubtractList(vm, x.as.float_list, y.as.byte_list, .float_list),
            .short => listSubtractScalar(vm, x.as.float_list, y.as.short, .float_list),
            .short_list => listSubtractList(vm, x.as.float_list, y.as.short_list, .float_list),
            .int => listSubtractScalar(vm, x.as.float_list, y.as.int, .float_list),
            .int_list => listSubtractList(vm, x.as.float_list, y.as.int_list, .float_list),
            .long => listSubtractScalar(vm, x.as.float_list, y.as.long, .float_list),
            .long_list => listSubtractList(vm, x.as.float_list, y.as.long_list, .float_list),
            .real => listSubtractScalar(vm, x.as.float_list, y.as.real, .float_list),
            .real_list => listSubtractList(vm, x.as.float_list, y.as.real_list, .float_list),
            .float => listSubtractScalar(vm, x.as.float_list, y.as.float, .float_list),
            .float_list => listSubtractList(vm, x.as.float_list, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        else => @panic("NYI"),
    };
}

fn scalarSubtractScalar(vm: *Vm, scalar1: anytype, scalar2: anytype, comptime result_type: Value.Type) !*Value {
    const value = cast(result_type, scalar1) - cast(result_type, scalar2);
    return vm.create(result_type, value);
}

fn scalarSubtractList(vm: *Vm, scalar: anytype, list: anytype, comptime result_type: Value.Type) !*Value {
    const T = FromType(result_type);
    const result_list = try vm.gpa.alloc(T, list.len);

    for (list, result_list) |item, *result| {
        result.* = cast(result_type, scalar) - cast(result_type, item);
    }

    return vm.create(result_type, result_list);
}

fn listSubtractScalar(vm: *Vm, list: anytype, scalar: anytype, comptime result_type: Value.Type) !*Value {
    const T = FromType(result_type);
    const result_list = try vm.gpa.alloc(T, list.len);

    for (list, result_list) |item, *result| {
        result.* = cast(result_type, item) - cast(result_type, scalar);
    }

    return vm.create(result_type, result_list);
}

fn listSubtractList(vm: *Vm, list1: anytype, list2: anytype, comptime result_type: Value.Type) !*Value {
    if (list1.len != list2.len) @panic("length");

    const T = FromType(result_type);
    const result_list = try vm.gpa.alloc(T, list1.len);

    for (list1, list2, result_list) |x, y, *result| {
        result.* = cast(result_type, x) - cast(result_type, y);
    }

    return vm.create(result_type, result_list);
}

fn testSubtract(
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
    // boolean - scalar
    try testSubtract(.boolean, true, .boolean, false, .int, 1);
    try testSubtract(.boolean, true, .byte, 5, .int, -4);
    try testSubtract(.boolean, true, .short, 10, .int, -9);
    try testSubtract(.boolean, true, .int, 100, .int, -99);
    try testSubtract(.boolean, true, .long, 1000, .long, -999);
    try testSubtract(.boolean, true, .real, 2.5, .real, -1.5);
    try testSubtract(.boolean, true, .float, 2.5, .float, -1.5);

    // boolean - list
    try testSubtract(.boolean, true, .boolean_list, &.{ false, true, false }, .int_list, &[_]i32{ 1, 0, 1 });
    try testSubtract(.boolean, true, .byte_list, &[_]u8{ 1, 2, 3 }, .int_list, &[_]i32{ 0, -1, -2 });
    try testSubtract(.boolean, true, .short_list, &[_]i16{ 1, 2, 3 }, .int_list, &[_]i32{ 0, -1, -2 });
    try testSubtract(.boolean, true, .int_list, &[_]i32{ 1, 2, 3 }, .int_list, &[_]i32{ 0, -1, -2 });
    try testSubtract(.boolean, true, .long_list, &[_]i64{ 1, 2, 3 }, .long_list, &[_]i64{ 0, -1, -2 });
    try testSubtract(.boolean, true, .real_list, &[_]f32{ 1.0, 2.0, 3.0 }, .real_list, &[_]f32{ 0.0, -1.0, -2.0 });
    try testSubtract(.boolean, true, .float_list, &[_]f64{ 1.0, 2.0, 3.0 }, .float_list, &[_]f64{ 0.0, -1.0, -2.0 });

    // boolean_list - scalar
    try testSubtract(.boolean_list, &.{ true, false, true }, .boolean, false, .int_list, &[_]i32{ 1, 0, 1 });
    try testSubtract(.boolean_list, &.{ true, false, true }, .byte, 5, .int_list, &[_]i32{ -4, -5, -4 });
    try testSubtract(.boolean_list, &.{ true, false, true }, .short, 10, .int_list, &[_]i32{ -9, -10, -9 });
    try testSubtract(.boolean_list, &.{ true, false, true }, .int, 100, .int_list, &[_]i32{ -99, -100, -99 });
    try testSubtract(.boolean_list, &.{ true, false, true }, .long, 1000, .long_list, &[_]i64{ -999, -1000, -999 });
    try testSubtract(.boolean_list, &.{ true, false, true }, .real, 2.5, .real_list, &[_]f32{ -1.5, -2.5, -1.5 });
    try testSubtract(.boolean_list, &.{ true, false, true }, .float, 2.5, .float_list, &[_]f64{ -1.5, -2.5, -1.5 });

    // boolean_list - list
    try testSubtract(.boolean_list, &.{ true, false }, .boolean_list, &.{ false, true }, .int_list, &[_]i32{ 1, -1 });
    try testSubtract(.boolean_list, &.{ true, false }, .byte_list, &[_]u8{ 1, 2 }, .int_list, &[_]i32{ 0, -2 });
    try testSubtract(.boolean_list, &.{ true, false }, .short_list, &[_]i16{ 1, 2 }, .int_list, &[_]i32{ 0, -2 });
    try testSubtract(.boolean_list, &.{ true, false }, .int_list, &[_]i32{ 1, 2 }, .int_list, &[_]i32{ 0, -2 });
    try testSubtract(.boolean_list, &.{ true, false }, .long_list, &[_]i64{ 1, 2 }, .long_list, &[_]i64{ 0, -2 });
    try testSubtract(.boolean_list, &.{ true, false }, .real_list, &[_]f32{ 1.5, 2.5 }, .real_list, &[_]f32{ -0.5, -2.5 });
    try testSubtract(.boolean_list, &.{ true, false }, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ -0.5, -2.5 });
}

test "byte" {
    // byte - scalar
    try testSubtract(.byte, 5, .boolean, true, .int, 4);
    try testSubtract(.byte, 5, .byte, 3, .int, 2);
    try testSubtract(.byte, 5, .short, 10, .int, -5);
    try testSubtract(.byte, 5, .int, 100, .int, -95);
    try testSubtract(.byte, 5, .long, 1000, .long, -995);
    try testSubtract(.byte, 5, .real, 2.5, .real, 2.5);
    try testSubtract(.byte, 5, .float, 2.5, .float, 2.5);

    // byte - list
    try testSubtract(.byte, 5, .boolean_list, &.{ true, false, true }, .int_list, &[_]i32{ 4, 5, 4 });
    try testSubtract(.byte, 5, .byte_list, &[_]u8{ 1, 2, 3 }, .int_list, &[_]i32{ 4, 3, 2 });
    try testSubtract(.byte, 5, .short_list, &[_]i16{ 1, 2, 3 }, .int_list, &[_]i32{ 4, 3, 2 });
    try testSubtract(.byte, 5, .int_list, &[_]i32{ 1, 2, 3 }, .int_list, &[_]i32{ 4, 3, 2 });
    try testSubtract(.byte, 5, .long_list, &[_]i64{ 1, 2, 3 }, .long_list, &[_]i64{ 4, 3, 2 });
    try testSubtract(.byte, 5, .real_list, &[_]f32{ 1.5, 2.5, 3.5 }, .real_list, &[_]f32{ 3.5, 2.5, 1.5 });
    try testSubtract(.byte, 5, .float_list, &[_]f64{ 1.5, 2.5, 3.5 }, .float_list, &[_]f64{ 3.5, 2.5, 1.5 });

    // byte_list - scalar
    try testSubtract(.byte_list, &[_]u8{ 1, 2, 3 }, .boolean, true, .int_list, &[_]i32{ 0, 1, 2 });
    try testSubtract(.byte_list, &[_]u8{ 6, 7, 8 }, .byte, 5, .int_list, &[_]i32{ 1, 2, 3 });
    try testSubtract(.byte_list, &[_]u8{ 11, 12, 13 }, .short, 10, .int_list, &[_]i32{ 1, 2, 3 });
    try testSubtract(.byte_list, &[_]u8{ 101, 102, 103 }, .int, 100, .int_list, &[_]i32{ 1, 2, 3 });
    try testSubtract(.byte_list, &[_]u8{ 1, 2, 3 }, .long, 1000, .long_list, &[_]i64{ -999, -998, -997 });
    try testSubtract(.byte_list, &[_]u8{ 3, 4, 5 }, .real, 2.5, .real_list, &[_]f32{ 0.5, 1.5, 2.5 });
    try testSubtract(.byte_list, &[_]u8{ 3, 4, 5 }, .float, 2.5, .float_list, &[_]f64{ 0.5, 1.5, 2.5 });

    // byte_list - list
    try testSubtract(.byte_list, &[_]u8{ 2, 2 }, .boolean_list, &.{ true, false }, .int_list, &[_]i32{ 1, 2 });
    try testSubtract(.byte_list, &[_]u8{ 5, 7, 9 }, .byte_list, &[_]u8{ 1, 2, 3 }, .int_list, &[_]i32{ 4, 5, 6 });
    try testSubtract(.byte_list, &[_]u8{ 11, 22 }, .short_list, &[_]i16{ 10, 20 }, .int_list, &[_]i32{ 1, 2 });
    try testSubtract(.byte_list, &[_]u8{ 101, 202 }, .int_list, &[_]i32{ 100, 200 }, .int_list, &[_]i32{ 1, 2 });
    try testSubtract(.byte_list, &[_]u8{ 10, 20 }, .long_list, &[_]i64{ 1, 2 }, .long_list, &[_]i64{ 9, 18 });
    try testSubtract(.byte_list, &[_]u8{ 2, 4 }, .real_list, &[_]f32{ 1.5, 2.5 }, .real_list, &[_]f32{ 0.5, 1.5 });
    try testSubtract(.byte_list, &[_]u8{ 2, 4 }, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 0.5, 1.5 });
}

test "short" {
    // short - scalar
    try testSubtract(.short, 10, .boolean, true, .int, 9);
    try testSubtract(.short, 10, .byte, 5, .int, 5);
    try testSubtract(.short, 30, .short, 20, .int, 10);
    try testSubtract(.short, 510, .int, 500, .int, 10);
    try testSubtract(.short, 2010, .long, 2000, .long, 10);
    try testSubtract(.short, 10, .real, 1.5, .real, 8.5);
    try testSubtract(.short, 10, .float, 1.5, .float, 8.5);

    // short - list
    try testSubtract(.short, 11, .boolean_list, &.{ true, false }, .int_list, &[_]i32{ 10, 11 });
    try testSubtract(.short, 12, .byte_list, &[_]u8{ 1, 2 }, .int_list, &[_]i32{ 11, 10 });
    try testSubtract(.short, 13, .short_list, &[_]i16{ 1, 2, 3 }, .int_list, &[_]i32{ 12, 11, 10 });
    try testSubtract(.short, 12, .int_list, &[_]i32{ 1, 2 }, .int_list, &[_]i32{ 11, 10 });
    try testSubtract(.short, 12, .long_list, &[_]i64{ 1, 2 }, .long_list, &[_]i64{ 11, 10 });
    try testSubtract(.short, 13, .real_list, &[_]f32{ 1.5, 2.5 }, .real_list, &[_]f32{ 11.5, 10.5 });
    try testSubtract(.short, 13, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 11.5, 10.5 });

    // short_list - scalar
    try testSubtract(.short_list, &[_]i16{ 2, 3, 4 }, .boolean, true, .int_list, &[_]i32{ 1, 2, 3 });
    try testSubtract(.short_list, &[_]i16{ 6, 7, 8 }, .byte, 5, .int_list, &[_]i32{ 1, 2, 3 });
    try testSubtract(.short_list, &[_]i16{ 11, 12, 13 }, .short, 10, .int_list, &[_]i32{ 1, 2, 3 });
    try testSubtract(.short_list, &[_]i16{ 101, 102, 103 }, .int, 100, .int_list, &[_]i32{ 1, 2, 3 });
    try testSubtract(.short_list, &[_]i16{ 1001, 1002, 1003 }, .long, 1000, .long_list, &[_]i64{ 1, 2, 3 });
    try testSubtract(.short_list, &[_]i16{ 2, 3, 4 }, .real, 1.5, .real_list, &[_]f32{ 0.5, 1.5, 2.5 });
    try testSubtract(.short_list, &[_]i16{ 2, 3, 4 }, .float, 1.5, .float_list, &[_]f64{ 0.5, 1.5, 2.5 });

    // short_list - list
    try testSubtract(.short_list, &[_]i16{ 2, 2 }, .boolean_list, &.{ true, false }, .int_list, &[_]i32{ 1, 2 });
    try testSubtract(.short_list, &[_]i16{ 11, 22 }, .byte_list, &[_]u8{ 1, 2 }, .int_list, &[_]i32{ 10, 20 });
    try testSubtract(.short_list, &[_]i16{ 4, 6 }, .short_list, &[_]i16{ 3, 4 }, .int_list, &[_]i32{ 1, 2 });
    try testSubtract(.short_list, &[_]i16{ 101, 202 }, .int_list, &[_]i32{ 100, 200 }, .int_list, &[_]i32{ 1, 2 });
    try testSubtract(.short_list, &[_]i16{ 1001, 2002 }, .long_list, &[_]i64{ 1000, 2000 }, .long_list, &[_]i64{ 1, 2 });
    try testSubtract(.short_list, &[_]i16{ 2, 4 }, .real_list, &[_]f32{ 1.5, 2.5 }, .real_list, &[_]f32{ 0.5, 1.5 });
    try testSubtract(.short_list, &[_]i16{ 2, 4 }, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 0.5, 1.5 });
}

test "int" {
    // int - scalar
    try testSubtract(.int, 101, .boolean, true, .int, 100);
    try testSubtract(.int, 105, .byte, 5, .int, 100);
    try testSubtract(.int, 110, .short, 10, .int, 100);
    try testSubtract(.int, 300, .int, 200, .int, 100);
    try testSubtract(.int, 5100, .long, 5000, .long, 100);
    try testSubtract(.int, 100, .real, 0.5, .real, 99.5);
    try testSubtract(.int, 100, .float, 0.5, .float, 99.5);

    // int - list
    try testSubtract(.int, 101, .boolean_list, &.{ true, false }, .int_list, &[_]i32{ 100, 101 });
    try testSubtract(.int, 101, .byte_list, &[_]u8{ 1, 2 }, .int_list, &[_]i32{ 100, 99 });
    try testSubtract(.int, 101, .short_list, &[_]i16{ 1, 2 }, .int_list, &[_]i32{ 100, 99 });
    try testSubtract(.int, 11, .int_list, &[_]i32{ 1, 2, 3 }, .int_list, &[_]i32{ 10, 9, 8 });
    try testSubtract(.int, 101, .long_list, &[_]i64{ 1, 2 }, .long_list, &[_]i64{ 100, 99 });
    try testSubtract(.int, 101, .real_list, &[_]f32{ 1.5, 2.5 }, .real_list, &[_]f32{ 99.5, 98.5 });
    try testSubtract(.int, 101, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 99.5, 98.5 });

    // int_list - scalar
    try testSubtract(.int_list, &[_]i32{ 2, 3, 4 }, .boolean, true, .int_list, &[_]i32{ 1, 2, 3 });
    try testSubtract(.int_list, &[_]i32{ 6, 7, 8 }, .byte, 5, .int_list, &[_]i32{ 1, 2, 3 });
    try testSubtract(.int_list, &[_]i32{ 11, 12, 13 }, .short, 10, .int_list, &[_]i32{ 1, 2, 3 });
    try testSubtract(.int_list, &[_]i32{ 11, 12, 13 }, .int, 10, .int_list, &[_]i32{ 1, 2, 3 });
    try testSubtract(.int_list, &[_]i32{ 1001, 1002, 1003 }, .long, 1000, .long_list, &[_]i64{ 1, 2, 3 });
    try testSubtract(.int_list, &[_]i32{ 2, 3, 4 }, .real, 1.5, .real_list, &[_]f32{ 0.5, 1.5, 2.5 });
    try testSubtract(.int_list, &[_]i32{ 2, 3, 4 }, .float, 1.5, .float_list, &[_]f64{ 0.5, 1.5, 2.5 });

    // int_list - list
    try testSubtract(.int_list, &[_]i32{ 2, 2 }, .boolean_list, &.{ true, false }, .int_list, &[_]i32{ 1, 2 });
    try testSubtract(.int_list, &[_]i32{ 101, 202 }, .byte_list, &[_]u8{ 1, 2 }, .int_list, &[_]i32{ 100, 200 });
    try testSubtract(.int_list, &[_]i32{ 101, 202 }, .short_list, &[_]i16{ 1, 2 }, .int_list, &[_]i32{ 100, 200 });
    try testSubtract(.int_list, &[_]i32{ 5, 7, 9 }, .int_list, &[_]i32{ 4, 5, 6 }, .int_list, &[_]i32{ 1, 2, 3 });
    try testSubtract(.int_list, &[_]i32{ 1001, 2002 }, .long_list, &[_]i64{ 1000, 2000 }, .long_list, &[_]i64{ 1, 2 });
    try testSubtract(.int_list, &[_]i32{ 2, 4 }, .real_list, &[_]f32{ 1.5, 2.5 }, .real_list, &[_]f32{ 0.5, 1.5 });
    try testSubtract(.int_list, &[_]i32{ 2, 4 }, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 0.5, 1.5 });
}

test "long" {
    // long - scalar
    try testSubtract(.long, 1001, .boolean, true, .long, 1000);
    try testSubtract(.long, 1005, .byte, 5, .long, 1000);
    try testSubtract(.long, 1010, .short, 10, .long, 1000);
    try testSubtract(.long, 1100, .int, 100, .long, 1000);
    try testSubtract(.long, 3000, .long, 2000, .long, 1000);
    try testSubtract(.long, 1000, .real, 0.25, .real, 999.75);
    try testSubtract(.long, 1000, .float, 0.25, .float, 999.75);

    // long - list
    try testSubtract(.long, 1001, .boolean_list, &.{ true, false }, .long_list, &[_]i64{ 1000, 1001 });
    try testSubtract(.long, 1001, .byte_list, &[_]u8{ 1, 2 }, .long_list, &[_]i64{ 1000, 999 });
    try testSubtract(.long, 1001, .short_list, &[_]i16{ 1, 2 }, .long_list, &[_]i64{ 1000, 999 });
    try testSubtract(.long, 1001, .int_list, &[_]i32{ 1, 2 }, .long_list, &[_]i64{ 1000, 999 });
    try testSubtract(.long, 15, .long_list, &[_]i64{ 10, 20, 30 }, .long_list, &[_]i64{ 5, -5, -15 });
    try testSubtract(.long, 1001, .real_list, &[_]f32{ 1.5, 2.5 }, .real_list, &[_]f32{ 999.5, 998.5 });
    try testSubtract(.long, 1001, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 999.5, 998.5 });

    // long_list - scalar
    try testSubtract(.long_list, &[_]i64{ 2, 3, 4 }, .boolean, true, .long_list, &[_]i64{ 1, 2, 3 });
    try testSubtract(.long_list, &[_]i64{ 6, 7, 8 }, .byte, 5, .long_list, &[_]i64{ 1, 2, 3 });
    try testSubtract(.long_list, &[_]i64{ 11, 12, 13 }, .short, 10, .long_list, &[_]i64{ 1, 2, 3 });
    try testSubtract(.long_list, &[_]i64{ 101, 102, 103 }, .int, 100, .long_list, &[_]i64{ 1, 2, 3 });
    try testSubtract(.long_list, &[_]i64{ 15, 25, 35 }, .long, 5, .long_list, &[_]i64{ 10, 20, 30 });
    try testSubtract(.long_list, &[_]i64{ 2, 3, 4 }, .real, 1.5, .real_list, &[_]f32{ 0.5, 1.5, 2.5 });
    try testSubtract(.long_list, &[_]i64{ 2, 3, 4 }, .float, 1.5, .float_list, &[_]f64{ 0.5, 1.5, 2.5 });

    // long_list - list
    try testSubtract(.long_list, &[_]i64{ 2, 2 }, .boolean_list, &.{ true, false }, .long_list, &[_]i64{ 1, 2 });
    try testSubtract(.long_list, &[_]i64{ 1001, 2002 }, .byte_list, &[_]u8{ 1, 2 }, .long_list, &[_]i64{ 1000, 2000 });
    try testSubtract(.long_list, &[_]i64{ 1001, 2002 }, .short_list, &[_]i16{ 1, 2 }, .long_list, &[_]i64{ 1000, 2000 });
    try testSubtract(.long_list, &[_]i64{ 1001, 2002 }, .int_list, &[_]i32{ 1, 2 }, .long_list, &[_]i64{ 1000, 2000 });
    try testSubtract(.long_list, &[_]i64{ 15, 35 }, .long_list, &[_]i64{ 5, 15 }, .long_list, &[_]i64{ 10, 20 });
    try testSubtract(.long_list, &[_]i64{ 2, 4 }, .real_list, &[_]f32{ 1.5, 2.5 }, .real_list, &[_]f32{ 0.5, 1.5 });
    try testSubtract(.long_list, &[_]i64{ 2, 4 }, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 0.5, 1.5 });
}

test "real" {
    // real - scalar
    try testSubtract(.real, 2.5, .boolean, true, .real, 1.5);
    try testSubtract(.real, 6.5, .byte, 5, .real, 1.5);
    try testSubtract(.real, 11.5, .short, 10, .real, 1.5);
    try testSubtract(.real, 101.5, .int, 100, .real, 1.5);
    try testSubtract(.real, 1001.5, .long, 1000, .real, 1.5);
    try testSubtract(.real, 4.0, .real, 2.5, .real, 1.5);
    try testSubtract(.real, 3.75, .float, 2.25, .float, 1.5);

    // real - list
    try testSubtract(.real, 2.5, .boolean_list, &.{ true, false }, .real_list, &[_]f32{ 1.5, 2.5 });
    try testSubtract(.real, 2.5, .byte_list, &[_]u8{ 1, 2 }, .real_list, &[_]f32{ 1.5, 0.5 });
    try testSubtract(.real, 2.5, .short_list, &[_]i16{ 1, 2 }, .real_list, &[_]f32{ 1.5, 0.5 });
    try testSubtract(.real, 2.5, .int_list, &[_]i32{ 1, 2 }, .real_list, &[_]f32{ 1.5, 0.5 });
    try testSubtract(.real, 2.5, .long_list, &[_]i64{ 1, 2 }, .real_list, &[_]f32{ 1.5, 0.5 });
    try testSubtract(.real, 2.5, .real_list, &[_]f32{ 1.5, 2.5 }, .real_list, &[_]f32{ 1.0, 0.0 });
    try testSubtract(.real, 3.0, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 1.5, 0.5 });

    // real_list - scalar
    try testSubtract(.real_list, &[_]f32{ 2, 3, 4 }, .boolean, true, .real_list, &[_]f32{ 1, 2, 3 });
    try testSubtract(.real_list, &[_]f32{ 6, 7, 8 }, .byte, 5, .real_list, &[_]f32{ 1, 2, 3 });
    try testSubtract(.real_list, &[_]f32{ 11, 12, 13 }, .short, 10, .real_list, &[_]f32{ 1, 2, 3 });
    try testSubtract(.real_list, &[_]f32{ 101, 102, 103 }, .int, 100, .real_list, &[_]f32{ 1, 2, 3 });
    try testSubtract(.real_list, &[_]f32{ 1001, 1002, 1003 }, .long, 1000, .real_list, &[_]f32{ 1, 2, 3 });
    try testSubtract(.real_list, &[_]f32{ 2.5, 3.5 }, .real, 1.0, .real_list, &[_]f32{ 1.5, 2.5 });
    try testSubtract(.real_list, &[_]f32{ 2.5, 3.5 }, .float, 1.0, .float_list, &[_]f64{ 1.5, 2.5 });

    // real_list - list
    try testSubtract(.real_list, &[_]f32{ 2, 2 }, .boolean_list, &.{ true, false }, .real_list, &[_]f32{ 1, 2 });
    try testSubtract(.real_list, &[_]f32{ 2.5, 4.5 }, .byte_list, &[_]u8{ 1, 2 }, .real_list, &[_]f32{ 1.5, 2.5 });
    try testSubtract(.real_list, &[_]f32{ 2.5, 4.5 }, .short_list, &[_]i16{ 1, 2 }, .real_list, &[_]f32{ 1.5, 2.5 });
    try testSubtract(.real_list, &[_]f32{ 2.5, 4.5 }, .int_list, &[_]i32{ 1, 2 }, .real_list, &[_]f32{ 1.5, 2.5 });
    try testSubtract(.real_list, &[_]f32{ 2.5, 4.5 }, .long_list, &[_]i64{ 1, 2 }, .real_list, &[_]f32{ 1.5, 2.5 });
    try testSubtract(.real_list, &[_]f32{ 2.5, 4.5 }, .real_list, &[_]f32{ 1.5, 2.5 }, .real_list, &[_]f32{ 1.0, 2.0 });
    try testSubtract(.real_list, &[_]f32{ 2.5, 4.5 }, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 1.0, 2.0 });
}

test "float" {
    // float - scalar
    try testSubtract(.float, 2.5, .boolean, true, .float, 1.5);
    try testSubtract(.float, 6.5, .byte, 5, .float, 1.5);
    try testSubtract(.float, 11.5, .short, 10, .float, 1.5);
    try testSubtract(.float, 101.5, .int, 100, .float, 1.5);
    try testSubtract(.float, 1001.5, .long, 1000, .float, 1.5);
    try testSubtract(.float, 4.0, .real, 2.5, .float, 1.5);
    try testSubtract(.float, 4.0, .float, 2.5, .float, 1.5);

    // float - list
    try testSubtract(.float, 2.5, .boolean_list, &.{ true, false }, .float_list, &[_]f64{ 1.5, 2.5 });
    try testSubtract(.float, 2.5, .byte_list, &[_]u8{ 1, 2 }, .float_list, &[_]f64{ 1.5, 0.5 });
    try testSubtract(.float, 2.5, .short_list, &[_]i16{ 1, 2 }, .float_list, &[_]f64{ 1.5, 0.5 });
    try testSubtract(.float, 2.5, .int_list, &[_]i32{ 1, 2 }, .float_list, &[_]f64{ 1.5, 0.5 });
    try testSubtract(.float, 2.5, .long_list, &[_]i64{ 1, 2 }, .float_list, &[_]f64{ 1.5, 0.5 });
    try testSubtract(.float, 3.0, .real_list, &[_]f32{ 1.5, 2.5 }, .float_list, &[_]f64{ 1.5, 0.5 });
    try testSubtract(.float, 2.5, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 1.0, 0.0 });

    // float_list - scalar
    try testSubtract(.float_list, &[_]f64{ 2, 3, 4 }, .boolean, true, .float_list, &[_]f64{ 1, 2, 3 });
    try testSubtract(.float_list, &[_]f64{ 6, 7, 8 }, .byte, 5, .float_list, &[_]f64{ 1, 2, 3 });
    try testSubtract(.float_list, &[_]f64{ 11, 12, 13 }, .short, 10, .float_list, &[_]f64{ 1, 2, 3 });
    try testSubtract(.float_list, &[_]f64{ 101, 102, 103 }, .int, 100, .float_list, &[_]f64{ 1, 2, 3 });
    try testSubtract(.float_list, &[_]f64{ 1001, 1002, 1003 }, .long, 1000, .float_list, &[_]f64{ 1, 2, 3 });
    try testSubtract(.float_list, &[_]f64{ 2.5, 3.5 }, .real, 1.0, .float_list, &[_]f64{ 1.5, 2.5 });
    try testSubtract(.float_list, &[_]f64{ 2.5, 3.5 }, .float, 1.0, .float_list, &[_]f64{ 1.5, 2.5 });

    // float_list - list
    try testSubtract(.float_list, &[_]f64{ 2, 2 }, .boolean_list, &.{ true, false }, .float_list, &[_]f64{ 1, 2 });
    try testSubtract(.float_list, &[_]f64{ 2.5, 4.5 }, .byte_list, &[_]u8{ 1, 2 }, .float_list, &[_]f64{ 1.5, 2.5 });
    try testSubtract(.float_list, &[_]f64{ 2.5, 4.5 }, .short_list, &[_]i16{ 1, 2 }, .float_list, &[_]f64{ 1.5, 2.5 });
    try testSubtract(.float_list, &[_]f64{ 2.5, 4.5 }, .int_list, &[_]i32{ 1, 2 }, .float_list, &[_]f64{ 1.5, 2.5 });
    try testSubtract(.float_list, &[_]f64{ 2.5, 4.5 }, .long_list, &[_]i64{ 1, 2 }, .float_list, &[_]f64{ 1.5, 2.5 });
    try testSubtract(.float_list, &[_]f64{ 2.5, 4.5 }, .real_list, &[_]f32{ 1.5, 2.5 }, .float_list, &[_]f64{ 1.0, 2.0 });
    try testSubtract(.float_list, &[_]f64{ 2.5, 4.5 }, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 1.0, 2.0 });
}
