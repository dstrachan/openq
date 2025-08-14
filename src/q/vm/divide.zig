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
            .boolean => scalarDivideScalar(vm, x.as.boolean, y.as.boolean, .float),
            .boolean_list => scalarDivideList(vm, x.as.boolean, y.as.boolean_list, .float_list),
            .byte => scalarDivideScalar(vm, x.as.boolean, y.as.byte, .float),
            .byte_list => scalarDivideList(vm, x.as.boolean, y.as.byte_list, .float_list),
            .short => scalarDivideScalar(vm, x.as.boolean, y.as.short, .float),
            .short_list => scalarDivideList(vm, x.as.boolean, y.as.short_list, .float_list),
            .int => scalarDivideScalar(vm, x.as.boolean, y.as.int, .float),
            .int_list => scalarDivideList(vm, x.as.boolean, y.as.int_list, .float_list),
            .long => scalarDivideScalar(vm, x.as.boolean, y.as.long, .float),
            .long_list => scalarDivideList(vm, x.as.boolean, y.as.long_list, .float_list),
            .real => scalarDivideScalar(vm, x.as.boolean, y.as.real, .float),
            .real_list => scalarDivideList(vm, x.as.boolean, y.as.real_list, .float_list),
            .float => scalarDivideScalar(vm, x.as.boolean, y.as.float, .float),
            .float_list => scalarDivideList(vm, x.as.boolean, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .boolean_list => switch (y.type) {
            .boolean => listDivideScalar(vm, x.as.boolean_list, y.as.boolean, .float_list),
            .boolean_list => listDivideList(vm, x.as.boolean_list, y.as.boolean_list, .float_list),
            .byte => listDivideScalar(vm, x.as.boolean_list, y.as.byte, .float_list),
            .byte_list => listDivideList(vm, x.as.boolean_list, y.as.byte_list, .float_list),
            .short => listDivideScalar(vm, x.as.boolean_list, y.as.short, .float_list),
            .short_list => listDivideList(vm, x.as.boolean_list, y.as.short_list, .float_list),
            .int => listDivideScalar(vm, x.as.boolean_list, y.as.int, .float_list),
            .int_list => listDivideList(vm, x.as.boolean_list, y.as.int_list, .float_list),
            .long => listDivideScalar(vm, x.as.boolean_list, y.as.long, .float_list),
            .long_list => listDivideList(vm, x.as.boolean_list, y.as.long_list, .float_list),
            .real => listDivideScalar(vm, x.as.boolean_list, y.as.real, .float_list),
            .real_list => listDivideList(vm, x.as.boolean_list, y.as.real_list, .float_list),
            .float => listDivideScalar(vm, x.as.boolean_list, y.as.float, .float_list),
            .float_list => listDivideList(vm, x.as.boolean_list, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .byte => switch (y.type) {
            .boolean => scalarDivideScalar(vm, x.as.byte, y.as.boolean, .float),
            .boolean_list => scalarDivideList(vm, x.as.byte, y.as.boolean_list, .float_list),
            .byte => scalarDivideScalar(vm, x.as.byte, y.as.byte, .float),
            .byte_list => scalarDivideList(vm, x.as.byte, y.as.byte_list, .float_list),
            .short => scalarDivideScalar(vm, x.as.byte, y.as.short, .float),
            .short_list => scalarDivideList(vm, x.as.byte, y.as.short_list, .float_list),
            .int => scalarDivideScalar(vm, x.as.byte, y.as.int, .float),
            .int_list => scalarDivideList(vm, x.as.byte, y.as.int_list, .float_list),
            .long => scalarDivideScalar(vm, x.as.byte, y.as.long, .float),
            .long_list => scalarDivideList(vm, x.as.byte, y.as.long_list, .float_list),
            .real => scalarDivideScalar(vm, x.as.byte, y.as.real, .float),
            .real_list => scalarDivideList(vm, x.as.byte, y.as.real_list, .float_list),
            .float => scalarDivideScalar(vm, x.as.byte, y.as.float, .float),
            .float_list => scalarDivideList(vm, x.as.byte, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .byte_list => switch (y.type) {
            .boolean => listDivideScalar(vm, x.as.byte_list, y.as.boolean, .float_list),
            .boolean_list => listDivideList(vm, x.as.byte_list, y.as.boolean_list, .float_list),
            .byte => listDivideScalar(vm, x.as.byte_list, y.as.byte, .float_list),
            .byte_list => listDivideList(vm, x.as.byte_list, y.as.byte_list, .float_list),
            .short => listDivideScalar(vm, x.as.byte_list, y.as.short, .float_list),
            .short_list => listDivideList(vm, x.as.byte_list, y.as.short_list, .float_list),
            .int => listDivideScalar(vm, x.as.byte_list, y.as.int, .float_list),
            .int_list => listDivideList(vm, x.as.byte_list, y.as.int_list, .float_list),
            .long => listDivideScalar(vm, x.as.byte_list, y.as.long, .float_list),
            .long_list => listDivideList(vm, x.as.byte_list, y.as.long_list, .float_list),
            .real => listDivideScalar(vm, x.as.byte_list, y.as.real, .float_list),
            .real_list => listDivideList(vm, x.as.byte_list, y.as.real_list, .float_list),
            .float => listDivideScalar(vm, x.as.byte_list, y.as.float, .float_list),
            .float_list => listDivideList(vm, x.as.byte_list, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .short => switch (y.type) {
            .boolean => scalarDivideScalar(vm, x.as.short, y.as.boolean, .float),
            .boolean_list => scalarDivideList(vm, x.as.short, y.as.boolean_list, .float_list),
            .byte => scalarDivideScalar(vm, x.as.short, y.as.byte, .float),
            .byte_list => scalarDivideList(vm, x.as.short, y.as.byte_list, .float_list),
            .short => scalarDivideScalar(vm, x.as.short, y.as.short, .float),
            .short_list => scalarDivideList(vm, x.as.short, y.as.short_list, .float_list),
            .int => scalarDivideScalar(vm, x.as.short, y.as.int, .float),
            .int_list => scalarDivideList(vm, x.as.short, y.as.int_list, .float_list),
            .long => scalarDivideScalar(vm, x.as.short, y.as.long, .float),
            .long_list => scalarDivideList(vm, x.as.short, y.as.long_list, .float_list),
            .real => scalarDivideScalar(vm, x.as.short, y.as.real, .float),
            .real_list => scalarDivideList(vm, x.as.short, y.as.real_list, .float_list),
            .float => scalarDivideScalar(vm, x.as.short, y.as.float, .float),
            .float_list => scalarDivideList(vm, x.as.short, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .short_list => switch (y.type) {
            .boolean => listDivideScalar(vm, x.as.short_list, y.as.boolean, .float_list),
            .boolean_list => listDivideList(vm, x.as.short_list, y.as.boolean_list, .float_list),
            .byte => listDivideScalar(vm, x.as.short_list, y.as.byte, .float_list),
            .byte_list => listDivideList(vm, x.as.short_list, y.as.byte_list, .float_list),
            .short => listDivideScalar(vm, x.as.short_list, y.as.short, .float_list),
            .short_list => listDivideList(vm, x.as.short_list, y.as.short_list, .float_list),
            .int => listDivideScalar(vm, x.as.short_list, y.as.int, .float_list),
            .int_list => listDivideList(vm, x.as.short_list, y.as.int_list, .float_list),
            .long => listDivideScalar(vm, x.as.short_list, y.as.long, .float_list),
            .long_list => listDivideList(vm, x.as.short_list, y.as.long_list, .float_list),
            .real => listDivideScalar(vm, x.as.short_list, y.as.real, .float_list),
            .real_list => listDivideList(vm, x.as.short_list, y.as.real_list, .float_list),
            .float => listDivideScalar(vm, x.as.short_list, y.as.float, .float_list),
            .float_list => listDivideList(vm, x.as.short_list, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .int => switch (y.type) {
            .boolean => scalarDivideScalar(vm, x.as.int, y.as.boolean, .float),
            .boolean_list => scalarDivideList(vm, x.as.int, y.as.boolean_list, .float_list),
            .byte => scalarDivideScalar(vm, x.as.int, y.as.byte, .float),
            .byte_list => scalarDivideList(vm, x.as.int, y.as.byte_list, .float_list),
            .short => scalarDivideScalar(vm, x.as.int, y.as.short, .float),
            .short_list => scalarDivideList(vm, x.as.int, y.as.short_list, .float_list),
            .int => scalarDivideScalar(vm, x.as.int, y.as.int, .float),
            .int_list => scalarDivideList(vm, x.as.int, y.as.int_list, .float_list),
            .long => scalarDivideScalar(vm, x.as.int, y.as.long, .float),
            .long_list => scalarDivideList(vm, x.as.int, y.as.long_list, .float_list),
            .real => scalarDivideScalar(vm, x.as.int, y.as.real, .float),
            .real_list => scalarDivideList(vm, x.as.int, y.as.real_list, .float_list),
            .float => scalarDivideScalar(vm, x.as.int, y.as.float, .float),
            .float_list => scalarDivideList(vm, x.as.int, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .int_list => switch (y.type) {
            .boolean => listDivideScalar(vm, x.as.int_list, y.as.boolean, .float_list),
            .boolean_list => listDivideList(vm, x.as.int_list, y.as.boolean_list, .float_list),
            .byte => listDivideScalar(vm, x.as.int_list, y.as.byte, .float_list),
            .byte_list => listDivideList(vm, x.as.int_list, y.as.byte_list, .float_list),
            .short => listDivideScalar(vm, x.as.int_list, y.as.short, .float_list),
            .short_list => listDivideList(vm, x.as.int_list, y.as.short_list, .float_list),
            .int => listDivideScalar(vm, x.as.int_list, y.as.int, .float_list),
            .int_list => listDivideList(vm, x.as.int_list, y.as.int_list, .float_list),
            .long => listDivideScalar(vm, x.as.int_list, y.as.long, .float_list),
            .long_list => listDivideList(vm, x.as.int_list, y.as.long_list, .float_list),
            .real => listDivideScalar(vm, x.as.int_list, y.as.real, .float_list),
            .real_list => listDivideList(vm, x.as.int_list, y.as.real_list, .float_list),
            .float => listDivideScalar(vm, x.as.int_list, y.as.float, .float_list),
            .float_list => listDivideList(vm, x.as.int_list, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .long => switch (y.type) {
            .boolean => scalarDivideScalar(vm, x.as.long, y.as.boolean, .float),
            .boolean_list => scalarDivideList(vm, x.as.long, y.as.boolean_list, .float_list),
            .byte => scalarDivideScalar(vm, x.as.long, y.as.byte, .float),
            .byte_list => scalarDivideList(vm, x.as.long, y.as.byte_list, .float_list),
            .short => scalarDivideScalar(vm, x.as.long, y.as.short, .float),
            .short_list => scalarDivideList(vm, x.as.long, y.as.short_list, .float_list),
            .int => scalarDivideScalar(vm, x.as.long, y.as.int, .float),
            .int_list => scalarDivideList(vm, x.as.long, y.as.int_list, .float_list),
            .long => scalarDivideScalar(vm, x.as.long, y.as.long, .float),
            .long_list => scalarDivideList(vm, x.as.long, y.as.long_list, .float_list),
            .real => scalarDivideScalar(vm, x.as.long, y.as.real, .float),
            .real_list => scalarDivideList(vm, x.as.long, y.as.real_list, .float_list),
            .float => scalarDivideScalar(vm, x.as.long, y.as.float, .float),
            .float_list => scalarDivideList(vm, x.as.long, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .long_list => switch (y.type) {
            .boolean => listDivideScalar(vm, x.as.long_list, y.as.boolean, .float_list),
            .boolean_list => listDivideList(vm, x.as.long_list, y.as.boolean_list, .float_list),
            .byte => listDivideScalar(vm, x.as.long_list, y.as.byte, .float_list),
            .byte_list => listDivideList(vm, x.as.long_list, y.as.byte_list, .float_list),
            .short => listDivideScalar(vm, x.as.long_list, y.as.short, .float_list),
            .short_list => listDivideList(vm, x.as.long_list, y.as.short_list, .float_list),
            .int => listDivideScalar(vm, x.as.long_list, y.as.int, .float_list),
            .int_list => listDivideList(vm, x.as.long_list, y.as.int_list, .float_list),
            .long => listDivideScalar(vm, x.as.long_list, y.as.long, .float_list),
            .long_list => listDivideList(vm, x.as.long_list, y.as.long_list, .float_list),
            .real => listDivideScalar(vm, x.as.long_list, y.as.real, .float_list),
            .real_list => listDivideList(vm, x.as.long_list, y.as.real_list, .float_list),
            .float => listDivideScalar(vm, x.as.long_list, y.as.float, .float_list),
            .float_list => listDivideList(vm, x.as.long_list, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .real => switch (y.type) {
            .boolean => scalarDivideScalar(vm, x.as.real, y.as.boolean, .float),
            .boolean_list => scalarDivideList(vm, x.as.real, y.as.boolean_list, .float_list),
            .byte => scalarDivideScalar(vm, x.as.real, y.as.byte, .float),
            .byte_list => scalarDivideList(vm, x.as.real, y.as.byte_list, .float_list),
            .short => scalarDivideScalar(vm, x.as.real, y.as.short, .float),
            .short_list => scalarDivideList(vm, x.as.real, y.as.short_list, .float_list),
            .int => scalarDivideScalar(vm, x.as.real, y.as.int, .float),
            .int_list => scalarDivideList(vm, x.as.real, y.as.int_list, .float_list),
            .long => scalarDivideScalar(vm, x.as.real, y.as.long, .float),
            .long_list => scalarDivideList(vm, x.as.real, y.as.long_list, .float_list),
            .real => scalarDivideScalar(vm, x.as.real, y.as.real, .float),
            .real_list => scalarDivideList(vm, x.as.real, y.as.real_list, .float_list),
            .float => scalarDivideScalar(vm, x.as.real, y.as.float, .float),
            .float_list => scalarDivideList(vm, x.as.real, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .real_list => switch (y.type) {
            .boolean => listDivideScalar(vm, x.as.real_list, y.as.boolean, .float_list),
            .boolean_list => listDivideList(vm, x.as.real_list, y.as.boolean_list, .float_list),
            .byte => listDivideScalar(vm, x.as.real_list, y.as.byte, .float_list),
            .byte_list => listDivideList(vm, x.as.real_list, y.as.byte_list, .float_list),
            .short => listDivideScalar(vm, x.as.real_list, y.as.short, .float_list),
            .short_list => listDivideList(vm, x.as.real_list, y.as.short_list, .float_list),
            .int => listDivideScalar(vm, x.as.real_list, y.as.int, .float_list),
            .int_list => listDivideList(vm, x.as.real_list, y.as.int_list, .float_list),
            .long => listDivideScalar(vm, x.as.real_list, y.as.long, .float_list),
            .long_list => listDivideList(vm, x.as.real_list, y.as.long_list, .float_list),
            .real => listDivideScalar(vm, x.as.real_list, y.as.real, .float_list),
            .real_list => listDivideList(vm, x.as.real_list, y.as.real_list, .float_list),
            .float => listDivideScalar(vm, x.as.real_list, y.as.float, .float_list),
            .float_list => listDivideList(vm, x.as.real_list, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .float => switch (y.type) {
            .boolean => scalarDivideScalar(vm, x.as.float, y.as.boolean, .float),
            .boolean_list => scalarDivideList(vm, x.as.float, y.as.boolean_list, .float_list),
            .byte => scalarDivideScalar(vm, x.as.float, y.as.byte, .float),
            .byte_list => scalarDivideList(vm, x.as.float, y.as.byte_list, .float_list),
            .short => scalarDivideScalar(vm, x.as.float, y.as.short, .float),
            .short_list => scalarDivideList(vm, x.as.float, y.as.short_list, .float_list),
            .int => scalarDivideScalar(vm, x.as.float, y.as.int, .float),
            .int_list => scalarDivideList(vm, x.as.float, y.as.int_list, .float_list),
            .long => scalarDivideScalar(vm, x.as.float, y.as.long, .float),
            .long_list => scalarDivideList(vm, x.as.float, y.as.long_list, .float_list),
            .real => scalarDivideScalar(vm, x.as.float, y.as.real, .float),
            .real_list => scalarDivideList(vm, x.as.float, y.as.real_list, .float_list),
            .float => scalarDivideScalar(vm, x.as.float, y.as.float, .float),
            .float_list => scalarDivideList(vm, x.as.float, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        .float_list => switch (y.type) {
            .boolean => listDivideScalar(vm, x.as.float_list, y.as.boolean, .float_list),
            .boolean_list => listDivideList(vm, x.as.float_list, y.as.boolean_list, .float_list),
            .byte => listDivideScalar(vm, x.as.float_list, y.as.byte, .float_list),
            .byte_list => listDivideList(vm, x.as.float_list, y.as.byte_list, .float_list),
            .short => listDivideScalar(vm, x.as.float_list, y.as.short, .float_list),
            .short_list => listDivideList(vm, x.as.float_list, y.as.short_list, .float_list),
            .int => listDivideScalar(vm, x.as.float_list, y.as.int, .float_list),
            .int_list => listDivideList(vm, x.as.float_list, y.as.int_list, .float_list),
            .long => listDivideScalar(vm, x.as.float_list, y.as.long, .float_list),
            .long_list => listDivideList(vm, x.as.float_list, y.as.long_list, .float_list),
            .real => listDivideScalar(vm, x.as.float_list, y.as.real, .float_list),
            .real_list => listDivideList(vm, x.as.float_list, y.as.real_list, .float_list),
            .float => listDivideScalar(vm, x.as.float_list, y.as.float, .float_list),
            .float_list => listDivideList(vm, x.as.float_list, y.as.float_list, .float_list),
            else => @panic("NYI"),
        },
        else => @panic("NYI"),
    };
}

fn scalarDivideScalar(vm: *Vm, scalar1: anytype, scalar2: anytype, comptime result_type: Value.Type) !*Value {
    if (cast(result_type, scalar2) == 0) @panic("division by zero");
    const value = cast(result_type, scalar1) / cast(result_type, scalar2);
    return vm.create(result_type, value);
}

fn scalarDivideList(vm: *Vm, scalar: anytype, list: anytype, comptime result_type: Value.Type) !*Value {
    const T = FromType(result_type);
    const result_list = try vm.gpa.alloc(T, list.len);

    for (list, result_list) |item, *result| {
        if (cast(result_type, item) == 0) @panic("division by zero");
        result.* = cast(result_type, scalar) / cast(result_type, item);
    }

    return vm.create(result_type, result_list);
}

fn listDivideScalar(vm: *Vm, list: anytype, scalar: anytype, comptime result_type: Value.Type) !*Value {
    if (cast(result_type, scalar) == 0) @panic("division by zero");

    const T = FromType(result_type);
    const result_list = try vm.gpa.alloc(T, list.len);

    for (list, result_list) |item, *result| {
        result.* = cast(result_type, item) / cast(result_type, scalar);
    }

    return vm.create(result_type, result_list);
}

fn listDivideList(vm: *Vm, list1: anytype, list2: anytype, comptime result_type: Value.Type) !*Value {
    if (list1.len != list2.len) @panic("length");

    const T = FromType(result_type);
    const result_list = try vm.gpa.alloc(T, list1.len);

    for (list1, list2, result_list) |x, y, *result| {
        if (cast(result_type, y) == 0) @panic("division by zero");
        result.* = cast(result_type, x) / cast(result_type, y);
    }

    return vm.create(result_type, result_list);
}

fn testDivide(
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
        .real => try testing.expectEqual(expected, actual.as.real),
        .real_list => try testing.expectEqualSlices(f32, expected, actual.as.real_list),
        .float => try testing.expectEqual(expected, actual.as.float),
        .float_list => try testing.expectEqualSlices(f64, expected, actual.as.float_list),
        else => comptime unreachable,
    }
}

test "boolean" {
    // boolean / scalar
    try testDivide(.boolean, true, .boolean, true, .float, 1.0);
    try testDivide(.boolean, true, .byte, 2, .float, 0.5);
    try testDivide(.boolean, true, .short, 4, .float, 0.25);
    try testDivide(.boolean, true, .int, 2, .float, 0.5);
    try testDivide(.boolean, true, .long, 4, .float, 0.25);
    try testDivide(.boolean, true, .real, 2.0, .float, 0.5);
    try testDivide(.boolean, true, .float, 4.0, .float, 0.25);

    // boolean / list
    try testDivide(.boolean, true, .boolean_list, &.{ true, true }, .float_list, &[_]f64{ 1.0, 1.0 });
    try testDivide(.boolean, true, .byte_list, &[_]u8{ 1, 2 }, .float_list, &[_]f64{ 1.0, 0.5 });
    try testDivide(.boolean, true, .short_list, &[_]i16{ 2, 4 }, .float_list, &[_]f64{ 0.5, 0.25 });
    try testDivide(.boolean, true, .int_list, &[_]i32{ 2, 4 }, .float_list, &[_]f64{ 0.5, 0.25 });
    try testDivide(.boolean, true, .long_list, &[_]i64{ 2, 4 }, .float_list, &[_]f64{ 0.5, 0.25 });
    try testDivide(.boolean, true, .real_list, &[_]f32{ 2.0, 4.0 }, .float_list, &[_]f64{ 0.5, 0.25 });
    try testDivide(.boolean, true, .float_list, &[_]f64{ 2.0, 4.0 }, .float_list, &[_]f64{ 0.5, 0.25 });

    // boolean_list / scalar
    try testDivide(.boolean_list, &.{ true, true }, .boolean, true, .float_list, &[_]f64{ 1.0, 1.0 });
    try testDivide(.boolean_list, &.{ true, true }, .byte, 2, .float_list, &[_]f64{ 0.5, 0.5 });
    try testDivide(.boolean_list, &.{ true, true }, .short, 2, .float_list, &[_]f64{ 0.5, 0.5 });
    try testDivide(.boolean_list, &.{ true, true }, .int, 2, .float_list, &[_]f64{ 0.5, 0.5 });
    try testDivide(.boolean_list, &.{ true, true }, .long, 2, .float_list, &[_]f64{ 0.5, 0.5 });
    try testDivide(.boolean_list, &.{ true, true }, .real, 2.0, .float_list, &[_]f64{ 0.5, 0.5 });
    try testDivide(.boolean_list, &.{ true, true }, .float, 2.0, .float_list, &[_]f64{ 0.5, 0.5 });

    // boolean_list / list
    try testDivide(.boolean_list, &.{ true, true }, .boolean_list, &.{ true, true }, .float_list, &[_]f64{ 1.0, 1.0 });
    try testDivide(.boolean_list, &.{ true, true }, .byte_list, &[_]u8{ 2, 4 }, .float_list, &[_]f64{ 0.5, 0.25 });
    try testDivide(.boolean_list, &.{ true, true }, .short_list, &[_]i16{ 2, 4 }, .float_list, &[_]f64{ 0.5, 0.25 });
    try testDivide(.boolean_list, &.{ true, true }, .int_list, &[_]i32{ 2, 4 }, .float_list, &[_]f64{ 0.5, 0.25 });
    try testDivide(.boolean_list, &.{ true, true }, .long_list, &[_]i64{ 2, 4 }, .float_list, &[_]f64{ 0.5, 0.25 });
    try testDivide(.boolean_list, &.{ true, true }, .real_list, &[_]f32{ 2.0, 4.0 }, .float_list, &[_]f64{ 0.5, 0.25 });
    try testDivide(.boolean_list, &.{ true, true }, .float_list, &[_]f64{ 2.0, 4.0 }, .float_list, &[_]f64{ 0.5, 0.25 });
}

test "byte" {
    // byte / scalar
    try testDivide(.byte, 6, .boolean, true, .float, 6.0);
    try testDivide(.byte, 6, .byte, 2, .float, 3.0);
    try testDivide(.byte, 8, .short, 2, .float, 4.0);
    try testDivide(.byte, 10, .int, 2, .float, 5.0);
    try testDivide(.byte, 12, .long, 3, .float, 4.0);
    try testDivide(.byte, 10, .real, 2.0, .float, 5.0);
    try testDivide(.byte, 12, .float, 3.0, .float, 4.0);

    // byte / list
    try testDivide(.byte, 6, .boolean_list, &.{ true, true }, .float_list, &[_]f64{ 6.0, 6.0 });
    try testDivide(.byte, 6, .byte_list, &[_]u8{ 2, 3 }, .float_list, &[_]f64{ 3.0, 2.0 });
    try testDivide(.byte, 8, .short_list, &[_]i16{ 2, 4 }, .float_list, &[_]f64{ 4.0, 2.0 });
    try testDivide(.byte, 10, .int_list, &[_]i32{ 2, 5 }, .float_list, &[_]f64{ 5.0, 2.0 });
    try testDivide(.byte, 12, .long_list, &[_]i64{ 3, 4 }, .float_list, &[_]f64{ 4.0, 3.0 });
    try testDivide(.byte, 10, .real_list, &[_]f32{ 2.0, 5.0 }, .float_list, &[_]f64{ 5.0, 2.0 });
    try testDivide(.byte, 12, .float_list, &[_]f64{ 3.0, 4.0 }, .float_list, &[_]f64{ 4.0, 3.0 });

    // byte_list / scalar
    try testDivide(.byte_list, &[_]u8{ 6, 8 }, .boolean, true, .float_list, &[_]f64{ 6.0, 8.0 });
    try testDivide(.byte_list, &[_]u8{ 6, 8 }, .byte, 2, .float_list, &[_]f64{ 3.0, 4.0 });
    try testDivide(.byte_list, &[_]u8{ 6, 8 }, .short, 2, .float_list, &[_]f64{ 3.0, 4.0 });
    try testDivide(.byte_list, &[_]u8{ 6, 8 }, .int, 2, .float_list, &[_]f64{ 3.0, 4.0 });
    try testDivide(.byte_list, &[_]u8{ 6, 9 }, .long, 3, .float_list, &[_]f64{ 2.0, 3.0 });
    try testDivide(.byte_list, &[_]u8{ 6, 8 }, .real, 2.0, .float_list, &[_]f64{ 3.0, 4.0 });
    try testDivide(.byte_list, &[_]u8{ 6, 9 }, .float, 3.0, .float_list, &[_]f64{ 2.0, 3.0 });

    // byte_list / list
    try testDivide(.byte_list, &[_]u8{ 6, 8 }, .boolean_list, &.{ true, true }, .float_list, &[_]f64{ 6.0, 8.0 });
    try testDivide(.byte_list, &[_]u8{ 6, 8 }, .byte_list, &[_]u8{ 2, 4 }, .float_list, &[_]f64{ 3.0, 2.0 });
    try testDivide(.byte_list, &[_]u8{ 6, 8 }, .short_list, &[_]i16{ 2, 4 }, .float_list, &[_]f64{ 3.0, 2.0 });
    try testDivide(.byte_list, &[_]u8{ 6, 8 }, .int_list, &[_]i32{ 2, 4 }, .float_list, &[_]f64{ 3.0, 2.0 });
    try testDivide(.byte_list, &[_]u8{ 6, 9 }, .long_list, &[_]i64{ 2, 3 }, .float_list, &[_]f64{ 3.0, 3.0 });
    try testDivide(.byte_list, &[_]u8{ 6, 8 }, .real_list, &[_]f32{ 2.0, 4.0 }, .float_list, &[_]f64{ 3.0, 2.0 });
    try testDivide(.byte_list, &[_]u8{ 6, 9 }, .float_list, &[_]f64{ 2.0, 3.0 }, .float_list, &[_]f64{ 3.0, 3.0 });
}

test "short" {
    // short / scalar
    try testDivide(.short, 10, .boolean, true, .float, 10.0);
    try testDivide(.short, 10, .byte, 2, .float, 5.0);
    try testDivide(.short, 20, .short, 4, .float, 5.0);
    try testDivide(.short, 20, .int, 4, .float, 5.0);
    try testDivide(.short, 20, .long, 4, .float, 5.0);
    try testDivide(.short, 15, .real, 3.0, .float, 5.0);
    try testDivide(.short, 20, .float, 4.0, .float, 5.0);

    // short / list
    try testDivide(.short, 10, .boolean_list, &.{ true, true }, .float_list, &[_]f64{ 10.0, 10.0 });
    try testDivide(.short, 10, .byte_list, &[_]u8{ 2, 5 }, .float_list, &[_]f64{ 5.0, 2.0 });
    try testDivide(.short, 20, .short_list, &[_]i16{ 4, 5 }, .float_list, &[_]f64{ 5.0, 4.0 });
    try testDivide(.short, 20, .int_list, &[_]i32{ 4, 5 }, .float_list, &[_]f64{ 5.0, 4.0 });
    try testDivide(.short, 20, .long_list, &[_]i64{ 4, 5 }, .float_list, &[_]f64{ 5.0, 4.0 });
    try testDivide(.short, 15, .real_list, &[_]f32{ 3.0, 5.0 }, .float_list, &[_]f64{ 5.0, 3.0 });
    try testDivide(.short, 20, .float_list, &[_]f64{ 4.0, 5.0 }, .float_list, &[_]f64{ 5.0, 4.0 });

    // short_list / scalar
    try testDivide(.short_list, &[_]i16{ 10, 20 }, .boolean, true, .float_list, &[_]f64{ 10.0, 20.0 });
    try testDivide(.short_list, &[_]i16{ 10, 20 }, .byte, 2, .float_list, &[_]f64{ 5.0, 10.0 });
    try testDivide(.short_list, &[_]i16{ 10, 20 }, .short, 2, .float_list, &[_]f64{ 5.0, 10.0 });
    try testDivide(.short_list, &[_]i16{ 10, 20 }, .int, 2, .float_list, &[_]f64{ 5.0, 10.0 });
    try testDivide(.short_list, &[_]i16{ 10, 20 }, .long, 2, .float_list, &[_]f64{ 5.0, 10.0 });
    try testDivide(.short_list, &[_]i16{ 10, 15 }, .real, 5.0, .float_list, &[_]f64{ 2.0, 3.0 });
    try testDivide(.short_list, &[_]i16{ 10, 20 }, .float, 2.0, .float_list, &[_]f64{ 5.0, 10.0 });

    // short_list / list
    try testDivide(.short_list, &[_]i16{ 10, 20 }, .boolean_list, &.{ true, true }, .float_list, &[_]f64{ 10.0, 20.0 });
    try testDivide(.short_list, &[_]i16{ 10, 20 }, .byte_list, &[_]u8{ 2, 4 }, .float_list, &[_]f64{ 5.0, 5.0 });
    try testDivide(.short_list, &[_]i16{ 10, 20 }, .short_list, &[_]i16{ 2, 4 }, .float_list, &[_]f64{ 5.0, 5.0 });
    try testDivide(.short_list, &[_]i16{ 10, 20 }, .int_list, &[_]i32{ 2, 4 }, .float_list, &[_]f64{ 5.0, 5.0 });
    try testDivide(.short_list, &[_]i16{ 10, 20 }, .long_list, &[_]i64{ 2, 4 }, .float_list, &[_]f64{ 5.0, 5.0 });
    try testDivide(.short_list, &[_]i16{ 10, 15 }, .real_list, &[_]f32{ 2.0, 5.0 }, .float_list, &[_]f64{ 5.0, 3.0 });
    try testDivide(.short_list, &[_]i16{ 10, 20 }, .float_list, &[_]f64{ 2.0, 4.0 }, .float_list, &[_]f64{ 5.0, 5.0 });
}

test "int" {
    // int / scalar
    try testDivide(.int, 100, .boolean, true, .float, 100.0);
    try testDivide(.int, 100, .byte, 4, .float, 25.0);
    try testDivide(.int, 100, .short, 4, .float, 25.0);
    try testDivide(.int, 100, .int, 4, .float, 25.0);
    try testDivide(.int, 100, .long, 4, .float, 25.0);
    try testDivide(.int, 100, .real, 4.0, .float, 25.0);
    try testDivide(.int, 100, .float, 4.0, .float, 25.0);

    // int / list
    try testDivide(.int, 100, .boolean_list, &.{ true, true }, .float_list, &[_]f64{ 100.0, 100.0 });
    try testDivide(.int, 100, .byte_list, &[_]u8{ 4, 5 }, .float_list, &[_]f64{ 25.0, 20.0 });
    try testDivide(.int, 100, .short_list, &[_]i16{ 4, 5 }, .float_list, &[_]f64{ 25.0, 20.0 });
    try testDivide(.int, 100, .int_list, &[_]i32{ 4, 5 }, .float_list, &[_]f64{ 25.0, 20.0 });
    try testDivide(.int, 100, .long_list, &[_]i64{ 4, 5 }, .float_list, &[_]f64{ 25.0, 20.0 });
    try testDivide(.int, 100, .real_list, &[_]f32{ 4.0, 5.0 }, .float_list, &[_]f64{ 25.0, 20.0 });
    try testDivide(.int, 100, .float_list, &[_]f64{ 4.0, 5.0 }, .float_list, &[_]f64{ 25.0, 20.0 });

    // int_list / scalar
    try testDivide(.int_list, &[_]i32{ 100, 200 }, .boolean, true, .float_list, &[_]f64{ 100.0, 200.0 });
    try testDivide(.int_list, &[_]i32{ 100, 200 }, .byte, 4, .float_list, &[_]f64{ 25.0, 50.0 });
    try testDivide(.int_list, &[_]i32{ 100, 200 }, .short, 4, .float_list, &[_]f64{ 25.0, 50.0 });
    try testDivide(.int_list, &[_]i32{ 100, 200 }, .int, 4, .float_list, &[_]f64{ 25.0, 50.0 });
    try testDivide(.int_list, &[_]i32{ 100, 200 }, .long, 4, .float_list, &[_]f64{ 25.0, 50.0 });
    try testDivide(.int_list, &[_]i32{ 100, 200 }, .real, 4.0, .float_list, &[_]f64{ 25.0, 50.0 });
    try testDivide(.int_list, &[_]i32{ 100, 200 }, .float, 4.0, .float_list, &[_]f64{ 25.0, 50.0 });

    // int_list / list
    try testDivide(.int_list, &[_]i32{ 100, 200 }, .boolean_list, &.{ true, true }, .float_list, &[_]f64{ 100.0, 200.0 });
    try testDivide(.int_list, &[_]i32{ 100, 200 }, .byte_list, &[_]u8{ 4, 5 }, .float_list, &[_]f64{ 25.0, 40.0 });
    try testDivide(.int_list, &[_]i32{ 100, 200 }, .short_list, &[_]i16{ 4, 5 }, .float_list, &[_]f64{ 25.0, 40.0 });
    try testDivide(.int_list, &[_]i32{ 100, 200 }, .int_list, &[_]i32{ 4, 5 }, .float_list, &[_]f64{ 25.0, 40.0 });
    try testDivide(.int_list, &[_]i32{ 100, 200 }, .long_list, &[_]i64{ 4, 5 }, .float_list, &[_]f64{ 25.0, 40.0 });
    try testDivide(.int_list, &[_]i32{ 100, 200 }, .real_list, &[_]f32{ 4.0, 5.0 }, .float_list, &[_]f64{ 25.0, 40.0 });
    try testDivide(.int_list, &[_]i32{ 100, 200 }, .float_list, &[_]f64{ 4.0, 5.0 }, .float_list, &[_]f64{ 25.0, 40.0 });
}

test "long" {
    // long / scalar
    try testDivide(.long, 1000, .boolean, true, .float, 1000.0);
    try testDivide(.long, 1000, .byte, 4, .float, 250.0);
    try testDivide(.long, 1000, .short, 4, .float, 250.0);
    try testDivide(.long, 1000, .int, 4, .float, 250.0);
    try testDivide(.long, 1000, .long, 4, .float, 250.0);
    try testDivide(.long, 1000, .real, 4.0, .float, 250.0);
    try testDivide(.long, 1000, .float, 4.0, .float, 250.0);

    // long / list
    try testDivide(.long, 1000, .boolean_list, &.{ true, true }, .float_list, &[_]f64{ 1000.0, 1000.0 });
    try testDivide(.long, 1000, .byte_list, &[_]u8{ 4, 5 }, .float_list, &[_]f64{ 250.0, 200.0 });
    try testDivide(.long, 1000, .short_list, &[_]i16{ 4, 5 }, .float_list, &[_]f64{ 250.0, 200.0 });
    try testDivide(.long, 1000, .int_list, &[_]i32{ 4, 5 }, .float_list, &[_]f64{ 250.0, 200.0 });
    try testDivide(.long, 1000, .long_list, &[_]i64{ 4, 5 }, .float_list, &[_]f64{ 250.0, 200.0 });
    try testDivide(.long, 1000, .real_list, &[_]f32{ 4.0, 5.0 }, .float_list, &[_]f64{ 250.0, 200.0 });
    try testDivide(.long, 1000, .float_list, &[_]f64{ 4.0, 5.0 }, .float_list, &[_]f64{ 250.0, 200.0 });

    // long_list / scalar
    try testDivide(.long_list, &[_]i64{ 1000, 2000 }, .boolean, true, .float_list, &[_]f64{ 1000.0, 2000.0 });
    try testDivide(.long_list, &[_]i64{ 1000, 2000 }, .byte, 4, .float_list, &[_]f64{ 250.0, 500.0 });
    try testDivide(.long_list, &[_]i64{ 1000, 2000 }, .short, 4, .float_list, &[_]f64{ 250.0, 500.0 });
    try testDivide(.long_list, &[_]i64{ 1000, 2000 }, .int, 4, .float_list, &[_]f64{ 250.0, 500.0 });
    try testDivide(.long_list, &[_]i64{ 1000, 2000 }, .long, 4, .float_list, &[_]f64{ 250.0, 500.0 });
    try testDivide(.long_list, &[_]i64{ 1000, 2000 }, .real, 4.0, .float_list, &[_]f64{ 250.0, 500.0 });
    try testDivide(.long_list, &[_]i64{ 1000, 2000 }, .float, 4.0, .float_list, &[_]f64{ 250.0, 500.0 });

    // long_list / list
    try testDivide(.long_list, &[_]i64{ 1000, 2000 }, .boolean_list, &.{ true, true }, .float_list, &[_]f64{ 1000.0, 2000.0 });
    try testDivide(.long_list, &[_]i64{ 1000, 2000 }, .byte_list, &[_]u8{ 4, 5 }, .float_list, &[_]f64{ 250.0, 400.0 });
    try testDivide(.long_list, &[_]i64{ 1000, 2000 }, .short_list, &[_]i16{ 4, 5 }, .float_list, &[_]f64{ 250.0, 400.0 });
    try testDivide(.long_list, &[_]i64{ 1000, 2000 }, .int_list, &[_]i32{ 4, 5 }, .float_list, &[_]f64{ 250.0, 400.0 });
    try testDivide(.long_list, &[_]i64{ 1000, 2000 }, .long_list, &[_]i64{ 4, 5 }, .float_list, &[_]f64{ 250.0, 400.0 });
    try testDivide(.long_list, &[_]i64{ 1000, 2000 }, .real_list, &[_]f32{ 4.0, 5.0 }, .float_list, &[_]f64{ 250.0, 400.0 });
    try testDivide(.long_list, &[_]i64{ 1000, 2000 }, .float_list, &[_]f64{ 4.0, 5.0 }, .float_list, &[_]f64{ 250.0, 400.0 });
}

test "real" {
    // real / scalar
    try testDivide(.real, 10.0, .boolean, true, .float, 10.0);
    try testDivide(.real, 10.0, .byte, 2, .float, 5.0);
    try testDivide(.real, 10.0, .short, 2, .float, 5.0);
    try testDivide(.real, 10.0, .int, 2, .float, 5.0);
    try testDivide(.real, 10.0, .long, 2, .float, 5.0);
    try testDivide(.real, 10.0, .real, 2.0, .float, 5.0);
    try testDivide(.real, 10.0, .float, 2.0, .float, 5.0);

    // real / list
    try testDivide(.real, 10.0, .boolean_list, &.{ true, true }, .float_list, &[_]f64{ 10.0, 10.0 });
    try testDivide(.real, 10.0, .byte_list, &[_]u8{ 2, 5 }, .float_list, &[_]f64{ 5.0, 2.0 });
    try testDivide(.real, 10.0, .short_list, &[_]i16{ 2, 5 }, .float_list, &[_]f64{ 5.0, 2.0 });
    try testDivide(.real, 10.0, .int_list, &[_]i32{ 2, 5 }, .float_list, &[_]f64{ 5.0, 2.0 });
    try testDivide(.real, 10.0, .long_list, &[_]i64{ 2, 5 }, .float_list, &[_]f64{ 5.0, 2.0 });
    try testDivide(.real, 10.0, .real_list, &[_]f32{ 2.0, 5.0 }, .float_list, &[_]f64{ 5.0, 2.0 });
    try testDivide(.real, 10.0, .float_list, &[_]f64{ 2.0, 5.0 }, .float_list, &[_]f64{ 5.0, 2.0 });

    // real_list / scalar
    try testDivide(.real_list, &[_]f32{ 10.0, 20.0 }, .boolean, true, .float_list, &[_]f64{ 10.0, 20.0 });
    try testDivide(.real_list, &[_]f32{ 10.0, 20.0 }, .byte, 2, .float_list, &[_]f64{ 5.0, 10.0 });
    try testDivide(.real_list, &[_]f32{ 10.0, 20.0 }, .short, 2, .float_list, &[_]f64{ 5.0, 10.0 });
    try testDivide(.real_list, &[_]f32{ 10.0, 20.0 }, .int, 2, .float_list, &[_]f64{ 5.0, 10.0 });
    try testDivide(.real_list, &[_]f32{ 10.0, 20.0 }, .long, 2, .float_list, &[_]f64{ 5.0, 10.0 });
    try testDivide(.real_list, &[_]f32{ 10.0, 20.0 }, .real, 2.0, .float_list, &[_]f64{ 5.0, 10.0 });
    try testDivide(.real_list, &[_]f32{ 10.0, 20.0 }, .float, 2.0, .float_list, &[_]f64{ 5.0, 10.0 });

    // real_list / list
    try testDivide(.real_list, &[_]f32{ 10.0, 20.0 }, .boolean_list, &.{ true, true }, .float_list, &[_]f64{ 10.0, 20.0 });
    try testDivide(.real_list, &[_]f32{ 10.0, 20.0 }, .byte_list, &[_]u8{ 2, 4 }, .float_list, &[_]f64{ 5.0, 5.0 });
    try testDivide(.real_list, &[_]f32{ 10.0, 20.0 }, .short_list, &[_]i16{ 2, 4 }, .float_list, &[_]f64{ 5.0, 5.0 });
    try testDivide(.real_list, &[_]f32{ 10.0, 20.0 }, .int_list, &[_]i32{ 2, 4 }, .float_list, &[_]f64{ 5.0, 5.0 });
    try testDivide(.real_list, &[_]f32{ 10.0, 20.0 }, .long_list, &[_]i64{ 2, 4 }, .float_list, &[_]f64{ 5.0, 5.0 });
    try testDivide(.real_list, &[_]f32{ 10.0, 20.0 }, .real_list, &[_]f32{ 2.0, 4.0 }, .float_list, &[_]f64{ 5.0, 5.0 });
    try testDivide(.real_list, &[_]f32{ 10.0, 20.0 }, .float_list, &[_]f64{ 2.0, 4.0 }, .float_list, &[_]f64{ 5.0, 5.0 });
}

test "float" {
    // float / scalar
    try testDivide(.float, 10.0, .boolean, true, .float, 10.0);
    try testDivide(.float, 10.0, .byte, 2, .float, 5.0);
    try testDivide(.float, 10.0, .short, 2, .float, 5.0);
    try testDivide(.float, 10.0, .int, 2, .float, 5.0);
    try testDivide(.float, 10.0, .long, 2, .float, 5.0);
    try testDivide(.float, 10.0, .real, 2.0, .float, 5.0);
    try testDivide(.float, 10.0, .float, 2.0, .float, 5.0);

    // float / list
    try testDivide(.float, 10.0, .boolean_list, &.{ true, true }, .float_list, &[_]f64{ 10.0, 10.0 });
    try testDivide(.float, 10.0, .byte_list, &[_]u8{ 2, 5 }, .float_list, &[_]f64{ 5.0, 2.0 });
    try testDivide(.float, 10.0, .short_list, &[_]i16{ 2, 5 }, .float_list, &[_]f64{ 5.0, 2.0 });
    try testDivide(.float, 10.0, .int_list, &[_]i32{ 2, 5 }, .float_list, &[_]f64{ 5.0, 2.0 });
    try testDivide(.float, 10.0, .long_list, &[_]i64{ 2, 5 }, .float_list, &[_]f64{ 5.0, 2.0 });
    try testDivide(.float, 10.0, .real_list, &[_]f32{ 2.0, 5.0 }, .float_list, &[_]f64{ 5.0, 2.0 });
    try testDivide(.float, 10.0, .float_list, &[_]f64{ 2.0, 5.0 }, .float_list, &[_]f64{ 5.0, 2.0 });

    // float_list / scalar
    try testDivide(.float_list, &[_]f64{ 10.0, 20.0 }, .boolean, true, .float_list, &[_]f64{ 10.0, 20.0 });
    try testDivide(.float_list, &[_]f64{ 10.0, 20.0 }, .byte, 2, .float_list, &[_]f64{ 5.0, 10.0 });
    try testDivide(.float_list, &[_]f64{ 10.0, 20.0 }, .short, 2, .float_list, &[_]f64{ 5.0, 10.0 });
    try testDivide(.float_list, &[_]f64{ 10.0, 20.0 }, .int, 2, .float_list, &[_]f64{ 5.0, 10.0 });
    try testDivide(.float_list, &[_]f64{ 10.0, 20.0 }, .long, 2, .float_list, &[_]f64{ 5.0, 10.0 });
    try testDivide(.float_list, &[_]f64{ 10.0, 20.0 }, .real, 2.0, .float_list, &[_]f64{ 5.0, 10.0 });
    try testDivide(.float_list, &[_]f64{ 10.0, 20.0 }, .float, 2.0, .float_list, &[_]f64{ 5.0, 10.0 });

    // float_list / list
    try testDivide(.float_list, &[_]f64{ 10.0, 20.0 }, .boolean_list, &.{ true, true }, .float_list, &[_]f64{ 10.0, 20.0 });
    try testDivide(.float_list, &[_]f64{ 10.0, 20.0 }, .byte_list, &[_]u8{ 2, 4 }, .float_list, &[_]f64{ 5.0, 5.0 });
    try testDivide(.float_list, &[_]f64{ 10.0, 20.0 }, .short_list, &[_]i16{ 2, 4 }, .float_list, &[_]f64{ 5.0, 5.0 });
    try testDivide(.float_list, &[_]f64{ 10.0, 20.0 }, .int_list, &[_]i32{ 2, 4 }, .float_list, &[_]f64{ 5.0, 5.0 });
    try testDivide(.float_list, &[_]f64{ 10.0, 20.0 }, .long_list, &[_]i64{ 2, 4 }, .float_list, &[_]f64{ 5.0, 5.0 });
    try testDivide(.float_list, &[_]f64{ 10.0, 20.0 }, .real_list, &[_]f32{ 2.0, 4.0 }, .float_list, &[_]f64{ 5.0, 5.0 });
    try testDivide(.float_list, &[_]f64{ 10.0, 20.0 }, .float_list, &[_]f64{ 2.0, 4.0 }, .float_list, &[_]f64{ 5.0, 5.0 });
}
