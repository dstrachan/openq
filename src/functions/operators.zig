const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const q = @import("../root.zig");
const Vm = q.Vm;
const Value = q.Value;
const Symbol = Value.Symbol;

pub fn assign(vm: *Vm, x: *Value, y: *Value) !*Value {
    std.log.debug("assign: {f}", .{x.fmt(vm)});
    switch (x.as) {
        .list => @panic("NYI"),
        .boolean => @panic("NYI"),
        .boolean_list => @panic("NYI"),
        .long => @panic("NYI"),
        .long_list => @panic("NYI"),
        .float => @panic("NYI"),
        .float_list => @panic("NYI"),
        .char => @panic("NYI"),
        .char_list => @panic("NYI"),
        .symbol => |identifier| {
            const home = (try vm.identifierHome(identifier, true)).?;
            try vm.namespaceSet(home.namespace, home.name, y);
            return y;
        },
        .symbol_list => @panic("NYI"),
        .dict => @panic("NYI"),
        .lambda => @panic("NYI"),
        .unary_primitive => @panic("NYI"),
        .operator => @panic("NYI"),
        .iterator => @panic("NYI"),
        .projection => @panic("NYI"),
        .each => @panic("NYI"),
        .over => @panic("NYI"),
        .scan => @panic("NYI"),
        .each_prior => @panic("NYI"),
        .each_right => @panic("NYI"),
        .each_left => @panic("NYI"),
    }
}

pub fn add(vm: *Vm, x: *Value, y: *Value) !*Value {
    switch (x.as) {
        .list => return error.nyi,
        .boolean => return error.nyi,
        .boolean_list => return error.nyi,
        .long => |x_val| switch (y.as) {
            .list => return error.nyi,
            .boolean => return error.nyi,
            .boolean_list => return error.nyi,
            .long => |y_val| return vm.createValue(.long, x_val + y_val),
            .long_list => return error.nyi,
            .float => |y_val| return vm.createValue(.float, @as(f64, @floatFromInt(x_val)) + y_val),
            .float_list => return error.nyi,
            .char => return error.nyi,
            .char_list => return error.nyi,
            .symbol => return error.nyi,
            .symbol_list => return error.nyi,
            .dict => return error.nyi,
            .lambda => return error.nyi,
            .unary_primitive => return error.nyi,
            .operator => return error.nyi,
            .iterator => return error.nyi,
            .projection => return error.nyi,
            .each => return error.nyi,
            .over => return error.nyi,
            .scan => return error.nyi,
            .each_prior => return error.nyi,
            .each_right => return error.nyi,
            .each_left => return error.nyi,
        },
        .long_list => return error.nyi,
        .float => |x_val| switch (y.as) {
            .list => return error.nyi,
            .boolean => return error.nyi,
            .boolean_list => return error.nyi,
            .long => |y_val| return vm.createValue(.float, x_val + @as(f64, @floatFromInt(y_val))),
            .long_list => return error.nyi,
            .float => |y_val| return vm.createValue(.float, x_val + y_val),
            .float_list => return error.nyi,
            .char => return error.nyi,
            .char_list => return error.nyi,
            .symbol => return error.nyi,
            .symbol_list => return error.nyi,
            .dict => return error.nyi,
            .lambda => return error.nyi,
            .unary_primitive => return error.nyi,
            .operator => return error.nyi,
            .iterator => return error.nyi,
            .projection => return error.nyi,
            .each => return error.nyi,
            .over => return error.nyi,
            .scan => return error.nyi,
            .each_prior => return error.nyi,
            .each_right => return error.nyi,
            .each_left => return error.nyi,
        },
        .float_list => return error.nyi,
        .char => return error.nyi,
        .char_list => return error.nyi,
        .symbol => return error.nyi,
        .symbol_list => return error.nyi,
        .dict => return error.nyi,
        .lambda => return error.nyi,
        .unary_primitive => return error.nyi,
        .operator => return error.nyi,
        .iterator => return error.nyi,
        .projection => return error.nyi,
        .each => return error.nyi,
        .over => return error.nyi,
        .scan => return error.nyi,
        .each_prior => return error.nyi,
        .each_right => return error.nyi,
        .each_left => return error.nyi,
    }
}

pub fn subtract(vm: *Vm, x: *Value, y: *Value) !*Value {
    switch (x.as) {
        .list => return error.nyi,
        .boolean => return error.nyi,
        .boolean_list => return error.nyi,
        .long => |x_val| switch (y.as) {
            .list => return error.nyi,
            .boolean => return error.nyi,
            .boolean_list => return error.nyi,
            .long => |y_val| return vm.createValue(.long, x_val - y_val),
            .long_list => return error.nyi,
            .float => |y_val| return vm.createValue(.float, @as(f64, @floatFromInt(x_val)) - y_val),
            .float_list => return error.nyi,
            .char => return error.nyi,
            .char_list => return error.nyi,
            .symbol => return error.nyi,
            .symbol_list => return error.nyi,
            .dict => return error.nyi,
            .lambda => return error.nyi,
            .unary_primitive => return error.nyi,
            .operator => return error.nyi,
            .iterator => return error.nyi,
            .projection => return error.nyi,
            .each => return error.nyi,
            .over => return error.nyi,
            .scan => return error.nyi,
            .each_prior => return error.nyi,
            .each_right => return error.nyi,
            .each_left => return error.nyi,
        },
        .long_list => return error.nyi,
        .float => |x_val| switch (y.as) {
            .list => return error.nyi,
            .boolean => return error.nyi,
            .boolean_list => return error.nyi,
            .long => |y_val| return vm.createValue(.float, x_val - @as(f64, @floatFromInt(y_val))),
            .long_list => return error.nyi,
            .float => |y_val| return vm.createValue(.float, x_val - y_val),
            .float_list => return error.nyi,
            .char => return error.nyi,
            .char_list => return error.nyi,
            .symbol => return error.nyi,
            .symbol_list => return error.nyi,
            .dict => return error.nyi,
            .lambda => return error.nyi,
            .unary_primitive => return error.nyi,
            .operator => return error.nyi,
            .iterator => return error.nyi,
            .projection => return error.nyi,
            .each => return error.nyi,
            .over => return error.nyi,
            .scan => return error.nyi,
            .each_prior => return error.nyi,
            .each_right => return error.nyi,
            .each_left => return error.nyi,
        },
        .float_list => return error.nyi,
        .char => return error.nyi,
        .char_list => return error.nyi,
        .symbol => return error.nyi,
        .symbol_list => return error.nyi,
        .dict => return error.nyi,
        .lambda => return error.nyi,
        .unary_primitive => return error.nyi,
        .operator => return error.nyi,
        .iterator => return error.nyi,
        .projection => return error.nyi,
        .each => return error.nyi,
        .over => return error.nyi,
        .scan => return error.nyi,
        .each_prior => return error.nyi,
        .each_right => return error.nyi,
        .each_left => return error.nyi,
    }
}

pub fn multiply(vm: *Vm, x: *Value, y: *Value) !*Value {
    switch (x.as) {
        .list => return error.nyi,
        .boolean => return error.nyi,
        .boolean_list => return error.nyi,
        .long => |x_val| switch (y.as) {
            .list => return error.nyi,
            .boolean => return error.nyi,
            .boolean_list => return error.nyi,
            .long => |y_val| return vm.createValue(.long, x_val * y_val),
            .long_list => return error.nyi,
            .float => |y_val| return vm.createValue(.float, @as(f64, @floatFromInt(x_val)) * y_val),
            .float_list => return error.nyi,
            .char => return error.nyi,
            .char_list => return error.nyi,
            .symbol => return error.nyi,
            .symbol_list => return error.nyi,
            .dict => return error.nyi,
            .lambda => return error.nyi,
            .unary_primitive => return error.nyi,
            .operator => return error.nyi,
            .iterator => return error.nyi,
            .projection => return error.nyi,
            .each => return error.nyi,
            .over => return error.nyi,
            .scan => return error.nyi,
            .each_prior => return error.nyi,
            .each_right => return error.nyi,
            .each_left => return error.nyi,
        },
        .long_list => return error.nyi,
        .float => |x_val| switch (y.as) {
            .list => return error.nyi,
            .boolean => return error.nyi,
            .boolean_list => return error.nyi,
            .long => |y_val| return vm.createValue(.float, x_val * @as(f64, @floatFromInt(y_val))),
            .long_list => return error.nyi,
            .float => |y_val| return vm.createValue(.float, x_val * y_val),
            .float_list => return error.nyi,
            .char => return error.nyi,
            .char_list => return error.nyi,
            .symbol => return error.nyi,
            .symbol_list => return error.nyi,
            .dict => return error.nyi,
            .lambda => return error.nyi,
            .unary_primitive => return error.nyi,
            .operator => return error.nyi,
            .iterator => return error.nyi,
            .projection => return error.nyi,
            .each => return error.nyi,
            .over => return error.nyi,
            .scan => return error.nyi,
            .each_prior => return error.nyi,
            .each_right => return error.nyi,
            .each_left => return error.nyi,
        },
        .float_list => return error.nyi,
        .char => return error.nyi,
        .char_list => return error.nyi,
        .symbol => return error.nyi,
        .symbol_list => return error.nyi,
        .dict => return error.nyi,
        .lambda => return error.nyi,
        .unary_primitive => return error.nyi,
        .operator => return error.nyi,
        .iterator => return error.nyi,
        .projection => return error.nyi,
        .each => return error.nyi,
        .over => return error.nyi,
        .scan => return error.nyi,
        .each_prior => return error.nyi,
        .each_right => return error.nyi,
        .each_left => return error.nyi,
    }
}

pub fn divide(vm: *Vm, x: *Value, y: *Value) !*Value {
    switch (x.as) {
        .list => return error.nyi,
        .boolean => return error.nyi,
        .boolean_list => return error.nyi,
        .long => |x_val| switch (y.as) {
            .list => return error.nyi,
            .boolean => return error.nyi,
            .boolean_list => return error.nyi,
            .long => |y_val| return vm.createValue(.float, @as(f64, @floatFromInt(x_val)) / @as(f64, @floatFromInt(y_val))),
            .long_list => return error.nyi,
            .float => |y_val| return vm.createValue(.float, @as(f64, @floatFromInt(x_val)) / y_val),
            .float_list => return error.nyi,
            .char => return error.nyi,
            .char_list => return error.nyi,
            .symbol => return error.nyi,
            .symbol_list => return error.nyi,
            .dict => return error.nyi,
            .lambda => return error.nyi,
            .unary_primitive => return error.nyi,
            .operator => return error.nyi,
            .iterator => return error.nyi,
            .projection => return error.nyi,
            .each => return error.nyi,
            .over => return error.nyi,
            .scan => return error.nyi,
            .each_prior => return error.nyi,
            .each_right => return error.nyi,
            .each_left => return error.nyi,
        },
        .long_list => return error.nyi,
        .float => |x_val| switch (y.as) {
            .list => return error.nyi,
            .boolean => return error.nyi,
            .boolean_list => return error.nyi,
            .long => |y_val| return vm.createValue(.float, x_val / @as(f64, @floatFromInt(y_val))),
            .long_list => return error.nyi,
            .float => |y_val| return vm.createValue(.float, x_val / y_val),
            .float_list => return error.nyi,
            .char => return error.nyi,
            .char_list => return error.nyi,
            .symbol => return error.nyi,
            .symbol_list => return error.nyi,
            .dict => return error.nyi,
            .lambda => return error.nyi,
            .unary_primitive => return error.nyi,
            .operator => return error.nyi,
            .iterator => return error.nyi,
            .projection => return error.nyi,
            .each => return error.nyi,
            .over => return error.nyi,
            .scan => return error.nyi,
            .each_prior => return error.nyi,
            .each_right => return error.nyi,
            .each_left => return error.nyi,
        },
        .float_list => return error.nyi,
        .char => return error.nyi,
        .char_list => return error.nyi,
        .symbol => return error.nyi,
        .symbol_list => return error.nyi,
        .dict => return error.nyi,
        .lambda => return error.nyi,
        .unary_primitive => return error.nyi,
        .operator => return error.nyi,
        .iterator => return error.nyi,
        .projection => return error.nyi,
        .each => return error.nyi,
        .over => return error.nyi,
        .scan => return error.nyi,
        .each_prior => return error.nyi,
        .each_right => return error.nyi,
        .each_left => return error.nyi,
    }
}

pub fn @"and"(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    unreachable;
}

pub fn @"or"(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    unreachable;
}

pub fn fill(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    unreachable;
}

pub fn equal(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    unreachable;
}

pub fn less_than(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    unreachable;
}

pub fn greater_than(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    unreachable;
}

pub fn cast(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    unreachable;
}

pub fn join(vm: *Vm, x: *Value, y: *Value) !*Value {
    switch (x.as) {
        .list => |x_val| {
            const list = try vm.allocValue(.list, x_val.len + 1);
            errdefer comptime unreachable;
            for (list.as.list[0..x_val.len], x_val) |*v, x_v| v.* = x_v.ref();
            list.as.list[x_val.len] = y.ref();
            return list;
        },
        .boolean => return error.nyi,
        .boolean_list => return error.nyi,
        .long => return error.nyi,
        .long_list => return error.nyi,
        .float => return error.nyi,
        .float_list => return error.nyi,
        .char => return error.nyi,
        .char_list => return error.nyi,
        .symbol => return error.nyi,
        .symbol_list => |x_val| switch (y.as) {
            .list => return error.nyi,
            .boolean => return error.nyi,
            .boolean_list => return error.nyi,
            .long => return error.nyi,
            .long_list => return error.nyi,
            .float => return error.nyi,
            .float_list => return error.nyi,
            .char => return error.nyi,
            .char_list => return error.nyi,
            .symbol => |y_val| {
                const list = try vm.allocValue(.symbol_list, x_val.len + 1);
                errdefer comptime unreachable;
                @memcpy(list.as.symbol_list[0..x_val.len], x_val);
                list.as.symbol_list[x_val.len] = y_val;
                return list;
            },
            .symbol_list => return error.nyi,
            .dict => return error.nyi,
            .lambda => return error.nyi,
            .unary_primitive => return error.nyi,
            .operator => return error.nyi,
            .iterator => return error.nyi,
            .projection => return error.nyi,
            .each => return error.nyi,
            .over => return error.nyi,
            .scan => return error.nyi,
            .each_prior => return error.nyi,
            .each_right => return error.nyi,
            .each_left => return error.nyi,
        },
        .dict => return error.nyi,
        .lambda => return error.nyi,
        .unary_primitive => return error.nyi,
        .operator => return error.nyi,
        .iterator => return error.nyi,
        .projection => return error.nyi,
        .each => return error.nyi,
        .over => return error.nyi,
        .scan => return error.nyi,
        .each_prior => return error.nyi,
        .each_right => return error.nyi,
        .each_left => return error.nyi,
    }
}

pub fn take(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    unreachable;
}

pub fn drop(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    unreachable;
}

pub fn match(vm: *Vm, x: *Value, y: *Value) !*Value {
    return vm.createValue(.boolean, x.eql(y));
}

pub fn dict(vm: *Vm, x: *Value, y: *Value) !*Value {
    switch (x.as) {
        .list,
        .boolean_list,
        .long_list,
        .float_list,
        .char_list,
        .symbol_list,
        => switch (y.as) {
            .list,
            .boolean_list,
            .long_list,
            .float_list,
            .char_list,
            .symbol_list,
            .dict,
            => {
                if (x.count() != y.count()) return error.length;
                const value = try vm.createValue(.dict, .{ .keys = undefined, .values = undefined });
                value.as.dict.keys = x.ref();
                value.as.dict.values = y.ref();
                return value;
            },
            .boolean => return error.nyi,
            .long => return error.nyi,
            .float => return error.nyi,
            .char => return error.nyi,
            .symbol => return error.nyi,
            .lambda => return error.nyi,
            .unary_primitive => return error.nyi,
            .operator => return error.nyi,
            .iterator => return error.nyi,
            .projection => return error.nyi,
            .each => return error.nyi,
            .over => return error.nyi,
            .scan => return error.nyi,
            .each_prior => return error.nyi,
            .each_right => return error.nyi,
            .each_left => return error.nyi,
        },
        .boolean => return error.nyi,
        .long => |val| switch (Value.Long.from(val)) {
            .null => {
                try vm.stdout.print("{f}\n", .{y.fmt(vm)});
                try vm.stdout.flush();
                return y.ref();
            },
            else => switch (val) {
                -3 => return vm.createCharList("{f}", .{y.fmt(vm)}),
                -5 => return vm.parse(y),
                -6 => return vm.eval(y),
                else => return error.nyi,
            },
        },
        .float => return error.nyi,
        .char => return error.nyi,
        .symbol => return error.nyi,
        .dict => return error.nyi,
        .lambda => return error.nyi,
        .unary_primitive => return error.nyi,
        .operator => return error.nyi,
        .iterator => return error.nyi,
        .projection => return error.nyi,
        .each => return error.nyi,
        .over => return error.nyi,
        .scan => return error.nyi,
        .each_prior => return error.nyi,
        .each_right => return error.nyi,
        .each_left => return error.nyi,
    }
}

pub fn find(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    unreachable;
}

pub fn apply_at(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    unreachable;
}

pub fn apply(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    unreachable;
}

pub fn file_text(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    unreachable;
}

pub fn file_binary(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    unreachable;
}

pub fn dynamic_load(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    unreachable;
}
