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
            .boolean => scalarAddScalar(vm, x.as.boolean, y.as.boolean, .int),
            .boolean_list => scalarAddList(vm, x.as.boolean, y.as.boolean_list, .int_list),
            .byte => scalarAddScalar(vm, x.as.boolean, y.as.byte, .int),
            .byte_list => scalarAddList(vm, x.as.boolean, y.as.byte_list, .int_list),
            .short => scalarAddScalar(vm, x.as.boolean, y.as.short, .int),
            .short_list => scalarAddList(vm, x.as.boolean, y.as.short_list, .int_list),
            .int => scalarAddScalar(vm, x.as.boolean, y.as.int, .int),
            .int_list => scalarAddList(vm, x.as.boolean, y.as.int_list, .int_list),
            .long => scalarAddScalar(vm, x.as.boolean, y.as.long, .long),
            .long_list => scalarAddList(vm, x.as.boolean, y.as.long_list, .long_list),
            .real => scalarAddScalar(vm, x.as.boolean, y.as.real, .real),
            .real_list => scalarAddList(vm, x.as.boolean, y.as.real_list, .real_list),
            .float => scalarAddScalar(vm, x.as.boolean, y.as.float, .float),
            .float_list => scalarAddList(vm, x.as.boolean, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .boolean_list => switch (y.type) {
            .boolean => listAddScalar(vm, x.as.boolean_list, y.as.boolean, .int_list),
            .boolean_list => listAddList(vm, x.as.boolean_list, y.as.boolean_list, .int_list),
            .byte => listAddScalar(vm, x.as.boolean_list, y.as.byte, .int_list),
            .byte_list => listAddList(vm, x.as.boolean_list, y.as.byte_list, .int_list),
            .short => listAddScalar(vm, x.as.boolean_list, y.as.short, .int_list),
            .short_list => listAddList(vm, x.as.boolean_list, y.as.short_list, .int_list),
            .int => listAddScalar(vm, x.as.boolean_list, y.as.int, .int_list),
            .int_list => listAddList(vm, x.as.boolean_list, y.as.int_list, .int_list),
            .long => listAddScalar(vm, x.as.boolean_list, y.as.long, .long_list),
            .long_list => listAddList(vm, x.as.boolean_list, y.as.long_list, .long_list),
            .real => listAddScalar(vm, x.as.boolean_list, y.as.real, .real_list),
            .real_list => listAddList(vm, x.as.boolean_list, y.as.real_list, .real_list),
            .float => listAddScalar(vm, x.as.boolean_list, y.as.float, .float_list),
            .float_list => listAddList(vm, x.as.boolean_list, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .byte => switch (y.type) {
            .boolean => scalarAddScalar(vm, x.as.byte, y.as.boolean, .int),
            .boolean_list => scalarAddList(vm, x.as.byte, y.as.boolean_list, .int_list),
            .byte => scalarAddScalar(vm, x.as.byte, y.as.byte, .int),
            .byte_list => scalarAddList(vm, x.as.byte, y.as.byte_list, .int_list),
            .short => scalarAddScalar(vm, x.as.byte, y.as.short, .int),
            .short_list => scalarAddList(vm, x.as.byte, y.as.short_list, .int_list),
            .int => scalarAddScalar(vm, x.as.byte, y.as.int, .int),
            .int_list => scalarAddList(vm, x.as.byte, y.as.int_list, .int_list),
            .long => scalarAddScalar(vm, x.as.byte, y.as.long, .long),
            .long_list => scalarAddList(vm, x.as.byte, y.as.long_list, .long_list),
            .real => scalarAddScalar(vm, x.as.byte, y.as.real, .real),
            .real_list => scalarAddList(vm, x.as.byte, y.as.real_list, .real_list),
            .float => scalarAddScalar(vm, x.as.byte, y.as.float, .float),
            .float_list => scalarAddList(vm, x.as.byte, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .byte_list => switch (y.type) {
            .boolean => listAddScalar(vm, x.as.byte_list, y.as.boolean, .int_list),
            .boolean_list => listAddList(vm, x.as.byte_list, y.as.boolean_list, .int_list),
            .byte => listAddScalar(vm, x.as.byte_list, y.as.byte, .int_list),
            .byte_list => listAddList(vm, x.as.byte_list, y.as.byte_list, .int_list),
            .short => listAddScalar(vm, x.as.byte_list, y.as.short, .int_list),
            .short_list => listAddList(vm, x.as.byte_list, y.as.short_list, .int_list),
            .int => listAddScalar(vm, x.as.byte_list, y.as.int, .int_list),
            .int_list => listAddList(vm, x.as.byte_list, y.as.int_list, .int_list),
            .long => listAddScalar(vm, x.as.byte_list, y.as.long, .long_list),
            .long_list => listAddList(vm, x.as.byte_list, y.as.long_list, .long_list),
            .real => listAddScalar(vm, x.as.byte_list, y.as.real, .real_list),
            .real_list => listAddList(vm, x.as.byte_list, y.as.real_list, .real_list),
            .float => listAddScalar(vm, x.as.byte_list, y.as.float, .float_list),
            .float_list => listAddList(vm, x.as.byte_list, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .short => switch (y.type) {
            .boolean => scalarAddScalar(vm, x.as.short, y.as.boolean, .int),
            .boolean_list => scalarAddList(vm, x.as.short, y.as.boolean_list, .int_list),
            .byte => scalarAddScalar(vm, x.as.short, y.as.byte, .int),
            .byte_list => scalarAddList(vm, x.as.short, y.as.byte_list, .int_list),
            .short => scalarAddScalar(vm, x.as.short, y.as.short, .int),
            .short_list => scalarAddList(vm, x.as.short, y.as.short_list, .int_list),
            .int => scalarAddScalar(vm, x.as.short, y.as.int, .int),
            .int_list => scalarAddList(vm, x.as.short, y.as.int_list, .int_list),
            .long => scalarAddScalar(vm, x.as.short, y.as.long, .long),
            .long_list => scalarAddList(vm, x.as.short, y.as.long_list, .long_list),
            .real => scalarAddScalar(vm, x.as.short, y.as.real, .real),
            .real_list => scalarAddList(vm, x.as.short, y.as.real_list, .real_list),
            .float => scalarAddScalar(vm, x.as.short, y.as.float, .float),
            .float_list => scalarAddList(vm, x.as.short, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .short_list => switch (y.type) {
            .boolean => listAddScalar(vm, x.as.short_list, y.as.boolean, .int_list),
            .boolean_list => listAddList(vm, x.as.short_list, y.as.boolean_list, .int_list),
            .byte => listAddScalar(vm, x.as.short_list, y.as.byte, .int_list),
            .byte_list => listAddList(vm, x.as.short_list, y.as.byte_list, .int_list),
            .short => listAddScalar(vm, x.as.short_list, y.as.short, .int_list),
            .short_list => listAddList(vm, x.as.short_list, y.as.short_list, .int_list),
            .int => listAddScalar(vm, x.as.short_list, y.as.int, .int_list),
            .int_list => listAddList(vm, x.as.short_list, y.as.int_list, .int_list),
            .long => listAddScalar(vm, x.as.short_list, y.as.long, .long_list),
            .long_list => listAddList(vm, x.as.short_list, y.as.long_list, .long_list),
            .real => listAddScalar(vm, x.as.short_list, y.as.real, .real_list),
            .real_list => listAddList(vm, x.as.short_list, y.as.real_list, .real_list),
            .float => listAddScalar(vm, x.as.short_list, y.as.float, .float_list),
            .float_list => listAddList(vm, x.as.short_list, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .int => switch (y.type) {
            .boolean => scalarAddScalar(vm, x.as.int, y.as.boolean, .int),
            .boolean_list => scalarAddList(vm, x.as.int, y.as.boolean_list, .int_list),
            .byte => scalarAddScalar(vm, x.as.int, y.as.byte, .int),
            .byte_list => scalarAddList(vm, x.as.int, y.as.byte_list, .int_list),
            .short => scalarAddScalar(vm, x.as.int, y.as.short, .int),
            .short_list => scalarAddList(vm, x.as.int, y.as.short_list, .int_list),
            .int => scalarAddScalar(vm, x.as.int, y.as.int, .int),
            .int_list => scalarAddList(vm, x.as.int, y.as.int_list, .int_list),
            .long => scalarAddScalar(vm, x.as.int, y.as.long, .long),
            .long_list => scalarAddList(vm, x.as.int, y.as.long_list, .long_list),
            .real => scalarAddScalar(vm, x.as.int, y.as.real, .real),
            .real_list => scalarAddList(vm, x.as.int, y.as.real_list, .real_list),
            .float => scalarAddScalar(vm, x.as.int, y.as.float, .float),
            .float_list => scalarAddList(vm, x.as.int, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .int_list => switch (y.type) {
            .boolean => listAddScalar(vm, x.as.int_list, y.as.boolean, .int_list),
            .boolean_list => listAddList(vm, x.as.int_list, y.as.boolean_list, .int_list),
            .byte => listAddScalar(vm, x.as.int_list, y.as.byte, .int_list),
            .byte_list => listAddList(vm, x.as.int_list, y.as.byte_list, .int_list),
            .short => listAddScalar(vm, x.as.int_list, y.as.short, .int_list),
            .short_list => listAddList(vm, x.as.int_list, y.as.short_list, .int_list),
            .int => listAddScalar(vm, x.as.int_list, y.as.int, .int_list),
            .int_list => listAddList(vm, x.as.int_list, y.as.int_list, .int_list),
            .long => listAddScalar(vm, x.as.int_list, y.as.long, .long_list),
            .long_list => listAddList(vm, x.as.int_list, y.as.long_list, .long_list),
            .real => listAddScalar(vm, x.as.int_list, y.as.real, .real_list),
            .real_list => listAddList(vm, x.as.int_list, y.as.real_list, .real_list),
            .float => listAddScalar(vm, x.as.int_list, y.as.float, .float_list),
            .float_list => listAddList(vm, x.as.int_list, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .long => switch (y.type) {
            .boolean => scalarAddScalar(vm, x.as.long, y.as.boolean, .long),
            .boolean_list => scalarAddList(vm, x.as.long, y.as.boolean_list, .long_list),
            .byte => scalarAddScalar(vm, x.as.long, y.as.byte, .long),
            .byte_list => scalarAddList(vm, x.as.long, y.as.byte_list, .long_list),
            .short => scalarAddScalar(vm, x.as.long, y.as.short, .long),
            .short_list => scalarAddList(vm, x.as.long, y.as.short_list, .long_list),
            .int => scalarAddScalar(vm, x.as.long, y.as.int, .long),
            .int_list => scalarAddList(vm, x.as.long, y.as.int_list, .long_list),
            .long => scalarAddScalar(vm, x.as.long, y.as.long, .long),
            .long_list => scalarAddList(vm, x.as.long, y.as.long_list, .long_list),
            .real => scalarAddScalar(vm, x.as.long, y.as.real, .real),
            .real_list => scalarAddList(vm, x.as.long, y.as.real_list, .real_list),
            .float => scalarAddScalar(vm, x.as.long, y.as.float, .float),
            .float_list => scalarAddList(vm, x.as.long, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .long_list => switch (y.type) {
            .boolean => listAddScalar(vm, x.as.long_list, y.as.boolean, .long_list),
            .boolean_list => listAddList(vm, x.as.long_list, y.as.boolean_list, .long_list),
            .byte => listAddScalar(vm, x.as.long_list, y.as.byte, .long_list),
            .byte_list => listAddList(vm, x.as.long_list, y.as.byte_list, .long_list),
            .short => listAddScalar(vm, x.as.long_list, y.as.short, .long_list),
            .short_list => listAddList(vm, x.as.long_list, y.as.short_list, .long_list),
            .int => listAddScalar(vm, x.as.long_list, y.as.int, .long_list),
            .int_list => listAddList(vm, x.as.long_list, y.as.int_list, .long_list),
            .long => listAddScalar(vm, x.as.long_list, y.as.long, .long_list),
            .long_list => listAddList(vm, x.as.long_list, y.as.long_list, .long_list),
            .real => listAddScalar(vm, x.as.long_list, y.as.real, .real_list),
            .real_list => listAddList(vm, x.as.long_list, y.as.real_list, .real_list),
            .float => listAddScalar(vm, x.as.long_list, y.as.float, .float_list),
            .float_list => listAddList(vm, x.as.long_list, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .real => switch (y.type) {
            .boolean => scalarAddScalar(vm, x.as.real, y.as.boolean, .real),
            .boolean_list => scalarAddList(vm, x.as.real, y.as.boolean_list, .real_list),
            .byte => scalarAddScalar(vm, x.as.real, y.as.byte, .real),
            .byte_list => scalarAddList(vm, x.as.real, y.as.byte_list, .real_list),
            .short => scalarAddScalar(vm, x.as.real, y.as.short, .real),
            .short_list => scalarAddList(vm, x.as.real, y.as.short_list, .real_list),
            .int => scalarAddScalar(vm, x.as.real, y.as.int, .real),
            .int_list => scalarAddList(vm, x.as.real, y.as.int_list, .real_list),
            .long => scalarAddScalar(vm, x.as.real, y.as.long, .real),
            .long_list => scalarAddList(vm, x.as.real, y.as.long_list, .real_list),
            .real => scalarAddScalar(vm, x.as.real, y.as.real, .real),
            .real_list => scalarAddList(vm, x.as.real, y.as.real_list, .real_list),
            .float => scalarAddScalar(vm, x.as.real, y.as.float, .float),
            .float_list => scalarAddList(vm, x.as.real, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .real_list => switch (y.type) {
            .boolean => listAddScalar(vm, x.as.real_list, y.as.boolean, .real_list),
            .boolean_list => listAddList(vm, x.as.real_list, y.as.boolean_list, .real_list),
            .byte => listAddScalar(vm, x.as.real_list, y.as.byte, .real_list),
            .byte_list => listAddList(vm, x.as.real_list, y.as.byte_list, .real_list),
            .short => listAddScalar(vm, x.as.real_list, y.as.short, .real_list),
            .short_list => listAddList(vm, x.as.real_list, y.as.short_list, .real_list),
            .int => listAddScalar(vm, x.as.real_list, y.as.int, .real_list),
            .int_list => listAddList(vm, x.as.real_list, y.as.int_list, .real_list),
            .long => listAddScalar(vm, x.as.real_list, y.as.long, .real_list),
            .long_list => listAddList(vm, x.as.real_list, y.as.long_list, .real_list),
            .real => listAddScalar(vm, x.as.real_list, y.as.real, .real_list),
            .real_list => listAddList(vm, x.as.real_list, y.as.real_list, .real_list),
            .float => listAddScalar(vm, x.as.real_list, y.as.float, .float_list),
            .float_list => listAddList(vm, x.as.real_list, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .float => switch (y.type) {
            .boolean => scalarAddScalar(vm, x.as.float, y.as.boolean, .float),
            .boolean_list => scalarAddList(vm, x.as.float, y.as.boolean_list, .float_list),
            .byte => scalarAddScalar(vm, x.as.float, y.as.byte, .float),
            .byte_list => scalarAddList(vm, x.as.float, y.as.byte_list, .float_list),
            .short => scalarAddScalar(vm, x.as.float, y.as.short, .float),
            .short_list => scalarAddList(vm, x.as.float, y.as.short_list, .float_list),
            .int => scalarAddScalar(vm, x.as.float, y.as.int, .float),
            .int_list => scalarAddList(vm, x.as.float, y.as.int_list, .float_list),
            .long => scalarAddScalar(vm, x.as.float, y.as.long, .float),
            .long_list => scalarAddList(vm, x.as.float, y.as.long_list, .float_list),
            .real => scalarAddScalar(vm, x.as.float, y.as.real, .float),
            .real_list => scalarAddList(vm, x.as.float, y.as.real_list, .float_list),
            .float => scalarAddScalar(vm, x.as.float, y.as.float, .float),
            .float_list => scalarAddList(vm, x.as.float, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .float_list => switch (y.type) {
            .boolean => listAddScalar(vm, x.as.float_list, y.as.boolean, .float_list),
            .boolean_list => listAddList(vm, x.as.float_list, y.as.boolean_list, .float_list),
            .byte => listAddScalar(vm, x.as.float_list, y.as.byte, .float_list),
            .byte_list => listAddList(vm, x.as.float_list, y.as.byte_list, .float_list),
            .short => listAddScalar(vm, x.as.float_list, y.as.short, .float_list),
            .short_list => listAddList(vm, x.as.float_list, y.as.short_list, .float_list),
            .int => listAddScalar(vm, x.as.float_list, y.as.int, .float_list),
            .int_list => listAddList(vm, x.as.float_list, y.as.int_list, .float_list),
            .long => listAddScalar(vm, x.as.float_list, y.as.long, .float_list),
            .long_list => listAddList(vm, x.as.float_list, y.as.long_list, .float_list),
            .real => listAddScalar(vm, x.as.float_list, y.as.real, .float_list),
            .real_list => listAddList(vm, x.as.float_list, y.as.real_list, .float_list),
            .float => listAddScalar(vm, x.as.float_list, y.as.float, .float_list),
            .float_list => listAddList(vm, x.as.float_list, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        else => @panic("NYI"),
    };
}

fn scalarAddScalar(vm: *Vm, scalar1: anytype, scalar2: anytype, comptime result_type: Value.Type) !*Value {
    const value = cast(result_type, scalar1) + cast(result_type, scalar2);
    return vm.create(result_type, value);
}

fn scalarAddList(vm: *Vm, scalar: anytype, list: anytype, comptime result_type: Value.Type) !*Value {
    const T = FromType(result_type);
    const result_list = try vm.gpa.alloc(T, list.len);

    for (list, result_list) |item, *result| {
        result.* = cast(result_type, scalar) + cast(result_type, item);
    }

    return vm.create(result_type, result_list);
}

fn listAddScalar(vm: *Vm, list: anytype, scalar: anytype, comptime result_type: Value.Type) !*Value {
    const T = FromType(result_type);
    const result_list = try vm.gpa.alloc(T, list.len);

    for (list, result_list) |item, *result| {
        result.* = cast(result_type, item) + cast(result_type, scalar);
    }

    return vm.create(result_type, result_list);
}

fn listAddList(vm: *Vm, list1: anytype, list2: anytype, comptime result_type: Value.Type) !*Value {
    if (list1.len != list2.len) @panic("length");

    const T = FromType(result_type);
    const result_list = try vm.gpa.alloc(T, list1.len);

    for (list1, list2, result_list) |x, y, *result| {
        result.* = cast(result_type, x) + cast(result_type, y);
    }

    return vm.create(result_type, result_list);
}

fn testAdd(
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
    // boolean + scalar
    try testAdd(.boolean, true, .boolean, false, .int, 1);
    try testAdd(.boolean, true, .byte, 5, .int, 6);
    try testAdd(.boolean, true, .short, 10, .int, 11);
    try testAdd(.boolean, true, .int, 100, .int, 101);
    try testAdd(.boolean, true, .long, 1000, .long, 1001);
    try testAdd(.boolean, true, .real, 2.5, .real, 3.5);
    try testAdd(.boolean, true, .float, 2.5, .float, 3.5);

    // boolean + list
    try testAdd(.boolean, true, .boolean_list, &.{ false, true, false }, .int_list, &[_]i32{ 1, 2, 1 });
    try testAdd(.boolean, true, .byte_list, &[_]u8{ 1, 2, 3 }, .int_list, &[_]i32{ 2, 3, 4 });
    try testAdd(.boolean, true, .short_list, &[_]i16{ 1, 2, 3 }, .int_list, &[_]i32{ 2, 3, 4 });
    try testAdd(.boolean, true, .int_list, &[_]i32{ 1, 2, 3 }, .int_list, &[_]i32{ 2, 3, 4 });
    try testAdd(.boolean, true, .long_list, &[_]i64{ 1, 2, 3 }, .long_list, &[_]i64{ 2, 3, 4 });
    try testAdd(.boolean, true, .real_list, &[_]f32{ 1.0, 2.0, 3.0 }, .real_list, &[_]f32{ 2.0, 3.0, 4.0 });
    try testAdd(.boolean, true, .float_list, &[_]f64{ 1.0, 2.0, 3.0 }, .float_list, &[_]f64{ 2.0, 3.0, 4.0 });

    // boolean_list + scalar
    try testAdd(.boolean_list, &.{ true, false, true }, .boolean, false, .int_list, &[_]i32{ 1, 0, 1 });
    try testAdd(.boolean_list, &.{ true, false, true }, .byte, 5, .int_list, &[_]i32{ 6, 5, 6 });
    try testAdd(.boolean_list, &.{ true, false, true }, .short, 10, .int_list, &[_]i32{ 11, 10, 11 });
    try testAdd(.boolean_list, &.{ true, false, true }, .int, 100, .int_list, &[_]i32{ 101, 100, 101 });
    try testAdd(.boolean_list, &.{ true, false, true }, .long, 1000, .long_list, &[_]i64{ 1001, 1000, 1001 });
    try testAdd(.boolean_list, &.{ true, false, true }, .real, 2.5, .real_list, &[_]f32{ 3.5, 2.5, 3.5 });
    try testAdd(.boolean_list, &.{ true, false, true }, .float, 2.5, .float_list, &[_]f64{ 3.5, 2.5, 3.5 });

    // boolean_list + list
    try testAdd(.boolean_list, &.{ true, false }, .boolean_list, &.{ false, true }, .int_list, &[_]i32{ 1, 1 });
    try testAdd(.boolean_list, &.{ true, false }, .byte_list, &[_]u8{ 1, 2 }, .int_list, &[_]i32{ 2, 2 });
    try testAdd(.boolean_list, &.{ true, false }, .short_list, &[_]i16{ 1, 2 }, .int_list, &[_]i32{ 2, 2 });
    try testAdd(.boolean_list, &.{ true, false }, .int_list, &[_]i32{ 1, 2 }, .int_list, &[_]i32{ 2, 2 });
    try testAdd(.boolean_list, &.{ true, false }, .long_list, &[_]i64{ 1, 2 }, .long_list, &[_]i64{ 2, 2 });
    try testAdd(.boolean_list, &.{ true, false }, .real_list, &[_]f32{ 1.5, 2.5 }, .real_list, &[_]f32{ 2.5, 2.5 });
    try testAdd(.boolean_list, &.{ true, false }, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 2.5, 2.5 });
}

test "byte" {
    // byte + scalar
    try testAdd(.byte, 5, .boolean, true, .int, 6);
    try testAdd(.byte, 5, .byte, 3, .int, 8);
    try testAdd(.byte, 5, .short, 10, .int, 15);
    try testAdd(.byte, 5, .int, 100, .int, 105);
    try testAdd(.byte, 5, .long, 1000, .long, 1005);
    try testAdd(.byte, 5, .real, 2.5, .real, 7.5);
    try testAdd(.byte, 5, .float, 2.5, .float, 7.5);

    // byte + list
    try testAdd(.byte, 5, .boolean_list, &.{ true, false, true }, .int_list, &[_]i32{ 6, 5, 6 });
    try testAdd(.byte, 5, .byte_list, &[_]u8{ 1, 2, 3 }, .int_list, &[_]i32{ 6, 7, 8 });
    try testAdd(.byte, 5, .short_list, &[_]i16{ 1, 2, 3 }, .int_list, &[_]i32{ 6, 7, 8 });
    try testAdd(.byte, 5, .int_list, &[_]i32{ 1, 2, 3 }, .int_list, &[_]i32{ 6, 7, 8 });
    try testAdd(.byte, 5, .long_list, &[_]i64{ 1, 2, 3 }, .long_list, &[_]i64{ 6, 7, 8 });
    try testAdd(.byte, 5, .real_list, &[_]f32{ 1.5, 2.5, 3.5 }, .real_list, &[_]f32{ 6.5, 7.5, 8.5 });
    try testAdd(.byte, 5, .float_list, &[_]f64{ 1.5, 2.5, 3.5 }, .float_list, &[_]f64{ 6.5, 7.5, 8.5 });

    // byte_list + scalar
    try testAdd(.byte_list, &[_]u8{ 1, 2, 3 }, .boolean, true, .int_list, &[_]i32{ 2, 3, 4 });
    try testAdd(.byte_list, &[_]u8{ 1, 2, 3 }, .byte, 5, .int_list, &[_]i32{ 6, 7, 8 });
    try testAdd(.byte_list, &[_]u8{ 1, 2, 3 }, .short, 10, .int_list, &[_]i32{ 11, 12, 13 });
    try testAdd(.byte_list, &[_]u8{ 1, 2, 3 }, .int, 100, .int_list, &[_]i32{ 101, 102, 103 });
    try testAdd(.byte_list, &[_]u8{ 1, 2, 3 }, .long, 1000, .long_list, &[_]i64{ 1001, 1002, 1003 });
    try testAdd(.byte_list, &[_]u8{ 1, 2, 3 }, .real, 2.5, .real_list, &[_]f32{ 3.5, 4.5, 5.5 });
    try testAdd(.byte_list, &[_]u8{ 1, 2, 3 }, .float, 2.5, .float_list, &[_]f64{ 3.5, 4.5, 5.5 });

    // byte_list + list
    try testAdd(.byte_list, &[_]u8{ 1, 2 }, .boolean_list, &.{ true, false }, .int_list, &[_]i32{ 2, 2 });
    try testAdd(.byte_list, &[_]u8{ 1, 2, 3 }, .byte_list, &[_]u8{ 4, 5, 6 }, .int_list, &[_]i32{ 5, 7, 9 });
    try testAdd(.byte_list, &[_]u8{ 1, 2 }, .short_list, &[_]i16{ 10, 20 }, .int_list, &[_]i32{ 11, 22 });
    try testAdd(.byte_list, &[_]u8{ 1, 2 }, .int_list, &[_]i32{ 100, 200 }, .int_list, &[_]i32{ 101, 202 });
    try testAdd(.byte_list, &[_]u8{ 1, 2 }, .long_list, &[_]i64{ 1000, 2000 }, .long_list, &[_]i64{ 1001, 2002 });
    try testAdd(.byte_list, &[_]u8{ 1, 2 }, .real_list, &[_]f32{ 1.5, 2.5 }, .real_list, &[_]f32{ 2.5, 4.5 });
    try testAdd(.byte_list, &[_]u8{ 1, 2 }, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 2.5, 4.5 });
}

test "short" {
    // short + scalar
    try testAdd(.short, 10, .boolean, true, .int, 11);
    try testAdd(.short, 10, .byte, 5, .int, 15);
    try testAdd(.short, 10, .short, 20, .int, 30);
    try testAdd(.short, 10, .int, 500, .int, 510);
    try testAdd(.short, 10, .long, 2000, .long, 2010);
    try testAdd(.short, 10, .real, 1.5, .real, 11.5);
    try testAdd(.short, 10, .float, 1.5, .float, 11.5);

    // short + list
    try testAdd(.short, 10, .boolean_list, &.{ true, false }, .int_list, &[_]i32{ 11, 10 });
    try testAdd(.short, 10, .byte_list, &[_]u8{ 1, 2 }, .int_list, &[_]i32{ 11, 12 });
    try testAdd(.short, 10, .short_list, &[_]i16{ 1, 2, 3 }, .int_list, &[_]i32{ 11, 12, 13 });
    try testAdd(.short, 10, .int_list, &[_]i32{ 1, 2 }, .int_list, &[_]i32{ 11, 12 });
    try testAdd(.short, 10, .long_list, &[_]i64{ 1, 2 }, .long_list, &[_]i64{ 11, 12 });
    try testAdd(.short, 10, .real_list, &[_]f32{ 1.5, 2.5 }, .real_list, &[_]f32{ 11.5, 12.5 });
    try testAdd(.short, 10, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 11.5, 12.5 });

    // short_list + scalar
    try testAdd(.short_list, &[_]i16{ 1, 2, 3 }, .boolean, true, .int_list, &[_]i32{ 2, 3, 4 });
    try testAdd(.short_list, &[_]i16{ 1, 2, 3 }, .byte, 5, .int_list, &[_]i32{ 6, 7, 8 });
    try testAdd(.short_list, &[_]i16{ 1, 2, 3 }, .short, 10, .int_list, &[_]i32{ 11, 12, 13 });
    try testAdd(.short_list, &[_]i16{ 1, 2, 3 }, .int, 100, .int_list, &[_]i32{ 101, 102, 103 });
    try testAdd(.short_list, &[_]i16{ 1, 2, 3 }, .long, 1000, .long_list, &[_]i64{ 1001, 1002, 1003 });
    try testAdd(.short_list, &[_]i16{ 1, 2, 3 }, .real, 1.5, .real_list, &[_]f32{ 2.5, 3.5, 4.5 });
    try testAdd(.short_list, &[_]i16{ 1, 2, 3 }, .float, 1.5, .float_list, &[_]f64{ 2.5, 3.5, 4.5 });

    // short_list + list
    try testAdd(.short_list, &[_]i16{ 1, 2 }, .boolean_list, &.{ true, false }, .int_list, &[_]i32{ 2, 2 });
    try testAdd(.short_list, &[_]i16{ 10, 20 }, .byte_list, &[_]u8{ 1, 2 }, .int_list, &[_]i32{ 11, 22 });
    try testAdd(.short_list, &[_]i16{ 1, 2 }, .short_list, &[_]i16{ 3, 4 }, .int_list, &[_]i32{ 4, 6 });
    try testAdd(.short_list, &[_]i16{ 1, 2 }, .int_list, &[_]i32{ 100, 200 }, .int_list, &[_]i32{ 101, 202 });
    try testAdd(.short_list, &[_]i16{ 1, 2 }, .long_list, &[_]i64{ 1000, 2000 }, .long_list, &[_]i64{ 1001, 2002 });
    try testAdd(.short_list, &[_]i16{ 1, 2 }, .real_list, &[_]f32{ 1.5, 2.5 }, .real_list, &[_]f32{ 2.5, 4.5 });
    try testAdd(.short_list, &[_]i16{ 1, 2 }, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 2.5, 4.5 });
}

test "int" {
    // int + scalar
    try testAdd(.int, 100, .boolean, true, .int, 101);
    try testAdd(.int, 100, .byte, 5, .int, 105);
    try testAdd(.int, 100, .short, 10, .int, 110);
    try testAdd(.int, 100, .int, 200, .int, 300);
    try testAdd(.int, 100, .long, 5000, .long, 5100);
    try testAdd(.int, 100, .real, 0.5, .real, 100.5);
    try testAdd(.int, 100, .float, 0.5, .float, 100.5);

    // int + list
    try testAdd(.int, 100, .boolean_list, &.{ true, false }, .int_list, &[_]i32{ 101, 100 });
    try testAdd(.int, 100, .byte_list, &[_]u8{ 1, 2 }, .int_list, &[_]i32{ 101, 102 });
    try testAdd(.int, 100, .short_list, &[_]i16{ 1, 2 }, .int_list, &[_]i32{ 101, 102 });
    try testAdd(.int, 10, .int_list, &[_]i32{ 1, 2, 3 }, .int_list, &[_]i32{ 11, 12, 13 });
    try testAdd(.int, 100, .long_list, &[_]i64{ 1, 2 }, .long_list, &[_]i64{ 101, 102 });
    try testAdd(.int, 100, .real_list, &[_]f32{ 1.5, 2.5 }, .real_list, &[_]f32{ 101.5, 102.5 });
    try testAdd(.int, 100, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 101.5, 102.5 });

    // int_list + scalar
    try testAdd(.int_list, &[_]i32{ 1, 2, 3 }, .boolean, true, .int_list, &[_]i32{ 2, 3, 4 });
    try testAdd(.int_list, &[_]i32{ 1, 2, 3 }, .byte, 5, .int_list, &[_]i32{ 6, 7, 8 });
    try testAdd(.int_list, &[_]i32{ 1, 2, 3 }, .short, 10, .int_list, &[_]i32{ 11, 12, 13 });
    try testAdd(.int_list, &[_]i32{ 1, 2, 3 }, .int, 10, .int_list, &[_]i32{ 11, 12, 13 });
    try testAdd(.int_list, &[_]i32{ 1, 2, 3 }, .long, 1000, .long_list, &[_]i64{ 1001, 1002, 1003 });
    try testAdd(.int_list, &[_]i32{ 1, 2, 3 }, .real, 1.5, .real_list, &[_]f32{ 2.5, 3.5, 4.5 });
    try testAdd(.int_list, &[_]i32{ 1, 2, 3 }, .float, 1.5, .float_list, &[_]f64{ 2.5, 3.5, 4.5 });

    // int_list + list
    try testAdd(.int_list, &[_]i32{ 1, 2 }, .boolean_list, &.{ true, false }, .int_list, &[_]i32{ 2, 2 });
    try testAdd(.int_list, &[_]i32{ 100, 200 }, .byte_list, &[_]u8{ 1, 2 }, .int_list, &[_]i32{ 101, 202 });
    try testAdd(.int_list, &[_]i32{ 100, 200 }, .short_list, &[_]i16{ 1, 2 }, .int_list, &[_]i32{ 101, 202 });
    try testAdd(.int_list, &[_]i32{ 1, 2, 3 }, .int_list, &[_]i32{ 4, 5, 6 }, .int_list, &[_]i32{ 5, 7, 9 });
    try testAdd(.int_list, &[_]i32{ 1, 2 }, .long_list, &[_]i64{ 1000, 2000 }, .long_list, &[_]i64{ 1001, 2002 });
    try testAdd(.int_list, &[_]i32{ 1, 2 }, .real_list, &[_]f32{ 1.5, 2.5 }, .real_list, &[_]f32{ 2.5, 4.5 });
    try testAdd(.int_list, &[_]i32{ 1, 2 }, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 2.5, 4.5 });
}

test "long" {
    // long + scalar
    try testAdd(.long, 1000, .boolean, true, .long, 1001);
    try testAdd(.long, 1000, .byte, 5, .long, 1005);
    try testAdd(.long, 1000, .short, 10, .long, 1010);
    try testAdd(.long, 1000, .int, 100, .long, 1100);
    try testAdd(.long, 1000, .long, 2000, .long, 3000);
    try testAdd(.long, 1000, .real, 0.25, .real, 1000.25);
    try testAdd(.long, 1000, .float, 0.25, .float, 1000.25);

    // long + list
    try testAdd(.long, 1000, .boolean_list, &.{ true, false }, .long_list, &[_]i64{ 1001, 1000 });
    try testAdd(.long, 1000, .byte_list, &[_]u8{ 1, 2 }, .long_list, &[_]i64{ 1001, 1002 });
    try testAdd(.long, 1000, .short_list, &[_]i16{ 1, 2 }, .long_list, &[_]i64{ 1001, 1002 });
    try testAdd(.long, 1000, .int_list, &[_]i32{ 1, 2 }, .long_list, &[_]i64{ 1001, 1002 });
    try testAdd(.long, 5, .long_list, &[_]i64{ 10, 20, 30 }, .long_list, &[_]i64{ 15, 25, 35 });
    try testAdd(.long, 1000, .real_list, &[_]f32{ 1.5, 2.5 }, .real_list, &[_]f32{ 1001.5, 1002.5 });
    try testAdd(.long, 1000, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 1001.5, 1002.5 });

    // long_list + scalar
    try testAdd(.long_list, &[_]i64{ 1, 2, 3 }, .boolean, true, .long_list, &[_]i64{ 2, 3, 4 });
    try testAdd(.long_list, &[_]i64{ 1, 2, 3 }, .byte, 5, .long_list, &[_]i64{ 6, 7, 8 });
    try testAdd(.long_list, &[_]i64{ 1, 2, 3 }, .short, 10, .long_list, &[_]i64{ 11, 12, 13 });
    try testAdd(.long_list, &[_]i64{ 1, 2, 3 }, .int, 100, .long_list, &[_]i64{ 101, 102, 103 });
    try testAdd(.long_list, &[_]i64{ 10, 20, 30 }, .long, 5, .long_list, &[_]i64{ 15, 25, 35 });
    try testAdd(.long_list, &[_]i64{ 1, 2, 3 }, .real, 1.5, .real_list, &[_]f32{ 2.5, 3.5, 4.5 });
    try testAdd(.long_list, &[_]i64{ 1, 2, 3 }, .float, 1.5, .float_list, &[_]f64{ 2.5, 3.5, 4.5 });

    // long_list + list
    try testAdd(.long_list, &[_]i64{ 1, 2 }, .boolean_list, &.{ true, false }, .long_list, &[_]i64{ 2, 2 });
    try testAdd(.long_list, &[_]i64{ 1000, 2000 }, .byte_list, &[_]u8{ 1, 2 }, .long_list, &[_]i64{ 1001, 2002 });
    try testAdd(.long_list, &[_]i64{ 1000, 2000 }, .short_list, &[_]i16{ 1, 2 }, .long_list, &[_]i64{ 1001, 2002 });
    try testAdd(.long_list, &[_]i64{ 1000, 2000 }, .int_list, &[_]i32{ 1, 2 }, .long_list, &[_]i64{ 1001, 2002 });
    try testAdd(.long_list, &[_]i64{ 10, 20 }, .long_list, &[_]i64{ 5, 15 }, .long_list, &[_]i64{ 15, 35 });
    try testAdd(.long_list, &[_]i64{ 1, 2 }, .real_list, &[_]f32{ 1.5, 2.5 }, .real_list, &[_]f32{ 2.5, 4.5 });
    try testAdd(.long_list, &[_]i64{ 1, 2 }, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 2.5, 4.5 });
}

test "real" {
    // real + scalar
    try testAdd(.real, 1.5, .boolean, true, .real, 2.5);
    try testAdd(.real, 1.5, .byte, 5, .real, 6.5);
    try testAdd(.real, 1.5, .short, 10, .real, 11.5);
    try testAdd(.real, 1.5, .int, 100, .real, 101.5);
    try testAdd(.real, 1.5, .long, 1000, .real, 1001.5);
    try testAdd(.real, 1.5, .real, 2.5, .real, 4.0);
    try testAdd(.real, 1.5, .float, 2.25, .float, 3.75);

    // real + list
    try testAdd(.real, 1.5, .boolean_list, &.{ true, false }, .real_list, &[_]f32{ 2.5, 1.5 });
    try testAdd(.real, 1.5, .byte_list, &[_]u8{ 1, 2 }, .real_list, &[_]f32{ 2.5, 3.5 });
    try testAdd(.real, 1.5, .short_list, &[_]i16{ 1, 2 }, .real_list, &[_]f32{ 2.5, 3.5 });
    try testAdd(.real, 1.5, .int_list, &[_]i32{ 1, 2 }, .real_list, &[_]f32{ 2.5, 3.5 });
    try testAdd(.real, 1.5, .long_list, &[_]i64{ 1, 2 }, .real_list, &[_]f32{ 2.5, 3.5 });
    try testAdd(.real, 1.0, .real_list, &[_]f32{ 1.5, 2.5 }, .real_list, &[_]f32{ 2.5, 3.5 });
    try testAdd(.real, 1.5, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 3.0, 4.0 });

    // real_list + scalar
    try testAdd(.real_list, &[_]f32{ 1, 2, 3 }, .boolean, true, .real_list, &[_]f32{ 2, 3, 4 });
    try testAdd(.real_list, &[_]f32{ 1, 2, 3 }, .byte, 5, .real_list, &[_]f32{ 6, 7, 8 });
    try testAdd(.real_list, &[_]f32{ 1, 2, 3 }, .short, 10, .real_list, &[_]f32{ 11, 12, 13 });
    try testAdd(.real_list, &[_]f32{ 1, 2, 3 }, .int, 100, .real_list, &[_]f32{ 101, 102, 103 });
    try testAdd(.real_list, &[_]f32{ 1, 2, 3 }, .long, 1000, .real_list, &[_]f32{ 1001, 1002, 1003 });
    try testAdd(.real_list, &[_]f32{ 1.5, 2.5 }, .real, 1.0, .real_list, &[_]f32{ 2.5, 3.5 });
    try testAdd(.real_list, &[_]f32{ 1.5, 2.5 }, .float, 1.0, .float_list, &[_]f64{ 2.5, 3.5 });

    // real_list + list
    try testAdd(.real_list, &[_]f32{ 1, 2 }, .boolean_list, &.{ true, false }, .real_list, &[_]f32{ 2, 2 });
    try testAdd(.real_list, &[_]f32{ 1.5, 2.5 }, .byte_list, &[_]u8{ 1, 2 }, .real_list, &[_]f32{ 2.5, 4.5 });
    try testAdd(.real_list, &[_]f32{ 1.5, 2.5 }, .short_list, &[_]i16{ 1, 2 }, .real_list, &[_]f32{ 2.5, 4.5 });
    try testAdd(.real_list, &[_]f32{ 1.5, 2.5 }, .int_list, &[_]i32{ 1, 2 }, .real_list, &[_]f32{ 2.5, 4.5 });
    try testAdd(.real_list, &[_]f32{ 1.5, 2.5 }, .long_list, &[_]i64{ 1, 2 }, .real_list, &[_]f32{ 2.5, 4.5 });
    try testAdd(.real_list, &[_]f32{ 1.0, 2.0 }, .real_list, &[_]f32{ 1.5, 2.5 }, .real_list, &[_]f32{ 2.5, 4.5 });
    try testAdd(.real_list, &[_]f32{ 1.0, 2.0 }, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 2.5, 4.5 });
}

test "float" {
    // float + scalar
    try testAdd(.float, 1.5, .boolean, true, .float, 2.5);
    try testAdd(.float, 1.5, .byte, 5, .float, 6.5);
    try testAdd(.float, 1.5, .short, 10, .float, 11.5);
    try testAdd(.float, 1.5, .int, 100, .float, 101.5);
    try testAdd(.float, 1.5, .long, 1000, .float, 1001.5);
    try testAdd(.float, 1.5, .real, 2.5, .float, 4.0);
    try testAdd(.float, 1.5, .float, 2.5, .float, 4.0);

    // float + list
    try testAdd(.float, 1.5, .boolean_list, &.{ true, false }, .float_list, &[_]f64{ 2.5, 1.5 });
    try testAdd(.float, 1.5, .byte_list, &[_]u8{ 1, 2 }, .float_list, &[_]f64{ 2.5, 3.5 });
    try testAdd(.float, 1.5, .short_list, &[_]i16{ 1, 2 }, .float_list, &[_]f64{ 2.5, 3.5 });
    try testAdd(.float, 1.5, .int_list, &[_]i32{ 1, 2 }, .float_list, &[_]f64{ 2.5, 3.5 });
    try testAdd(.float, 1.5, .long_list, &[_]i64{ 1, 2 }, .float_list, &[_]f64{ 2.5, 3.5 });
    try testAdd(.float, 1.5, .real_list, &[_]f32{ 1.5, 2.5 }, .float_list, &[_]f64{ 3.0, 4.0 });
    try testAdd(.float, 1.0, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 2.5, 3.5 });

    // float_list + scalar
    try testAdd(.float_list, &[_]f64{ 1, 2, 3 }, .boolean, true, .float_list, &[_]f64{ 2, 3, 4 });
    try testAdd(.float_list, &[_]f64{ 1, 2, 3 }, .byte, 5, .float_list, &[_]f64{ 6, 7, 8 });
    try testAdd(.float_list, &[_]f64{ 1, 2, 3 }, .short, 10, .float_list, &[_]f64{ 11, 12, 13 });
    try testAdd(.float_list, &[_]f64{ 1, 2, 3 }, .int, 100, .float_list, &[_]f64{ 101, 102, 103 });
    try testAdd(.float_list, &[_]f64{ 1, 2, 3 }, .long, 1000, .float_list, &[_]f64{ 1001, 1002, 1003 });
    try testAdd(.float_list, &[_]f64{ 1.5, 2.5 }, .real, 1.0, .float_list, &[_]f64{ 2.5, 3.5 });
    try testAdd(.float_list, &[_]f64{ 1.5, 2.5 }, .float, 1.0, .float_list, &[_]f64{ 2.5, 3.5 });

    // float_list + list
    try testAdd(.float_list, &[_]f64{ 1, 2 }, .boolean_list, &.{ true, false }, .float_list, &[_]f64{ 2, 2 });
    try testAdd(.float_list, &[_]f64{ 1.5, 2.5 }, .byte_list, &[_]u8{ 1, 2 }, .float_list, &[_]f64{ 2.5, 4.5 });
    try testAdd(.float_list, &[_]f64{ 1.5, 2.5 }, .short_list, &[_]i16{ 1, 2 }, .float_list, &[_]f64{ 2.5, 4.5 });
    try testAdd(.float_list, &[_]f64{ 1.5, 2.5 }, .int_list, &[_]i32{ 1, 2 }, .float_list, &[_]f64{ 2.5, 4.5 });
    try testAdd(.float_list, &[_]f64{ 1.5, 2.5 }, .long_list, &[_]i64{ 1, 2 }, .float_list, &[_]f64{ 2.5, 4.5 });
    try testAdd(.float_list, &[_]f64{ 1.0, 2.0 }, .real_list, &[_]f32{ 1.5, 2.5 }, .float_list, &[_]f64{ 2.5, 4.5 });
    try testAdd(.float_list, &[_]f64{ 1.0, 2.0 }, .float_list, &[_]f64{ 1.5, 2.5 }, .float_list, &[_]f64{ 2.5, 4.5 });
}
