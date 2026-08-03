const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const q = @import("../root.zig");
const Vm = q.Vm;
const Value = q.Value;
const Symbol = Value.Symbol;

pub fn identity(_: *Vm, x: *Value) !*Value {
    return x.ref();
}

pub fn flip(vm: *Vm, x: *Value) !*Value {
    _ = x; // autofix
    _ = vm; // autofix
    unreachable;
}

pub fn neg(vm: *Vm, x: *Value) !*Value {
    switch (x.as) {
        .list => |val| {
            const v = try vm.allocValue(.list, val.len);
            var i: usize = 0;
            errdefer {
                for (v.as.list[0..i]) |elem| elem.deref(vm.gpa);
                vm.gpa.destroy(v);
            }
            for (v.as.list, val) |*vv, elem| {
                vv.* = try neg(vm, elem);
                i += 1;
            }
            return v;
        },
        .boolean => return error.nyi,
        .boolean_list => return error.nyi,
        .long => |val| return vm.createValue(.long, -val),
        .long_list => |val| {
            const v = try vm.allocValue(.long_list, val.len);
            errdefer v.deref(vm.gpa);
            for (v.as.long_list, val) |*vv, elem| vv.* = -elem;
            return v;
        },
        .float => |val| return vm.createValue(.float, -val),
        .float_list => |val| {
            const v = try vm.allocValue(.float_list, val.len);
            errdefer v.deref(vm.gpa);
            for (v.as.float_list, val) |*vv, elem| vv.* = -elem;
            return v;
        },
        .char => return error.nyi,
        .char_list => return error.nyi,
        .symbol => return error.type,
        .symbol_list => return error.type,
        .dict => return error.nyi,
        .lambda => return error.type,
        .unary_primitive => return error.type,
        .operator => return error.type,
        .iterator => return error.type,
        .projection => return error.type,
        .each => return error.type,
        .over => return error.type,
        .scan => return error.type,
        .each_prior => return error.type,
        .each_right => return error.type,
        .each_left => return error.type,
    }
}

pub fn first(vm: *Vm, x: *Value) !*Value {
    switch (x.as) {
        .list => |val| return val[0].ref(),
        .boolean,
        .long,
        .float,
        .char,
        .symbol,
        .lambda,
        .unary_primitive,
        .operator,
        .iterator,
        .projection,
        .each,
        .over,
        .scan,
        .each_prior,
        .each_right,
        .each_left,
        => return x.ref(),
        .boolean_list => |val| return vm.createValue(.boolean, val[0]),
        .long_list => |val| return vm.createValue(.long, val[0]),
        .float_list => |val| return vm.createValue(.float, val[0]),
        .char_list => |val| return vm.createValue(.char, val[0]),
        .symbol_list => |val| return vm.createValue(.symbol, val[0]),
        .dict => |val| return first(vm, val.values),
    }
}

pub fn reciprocal(vm: *Vm, x: *Value) !*Value {
    _ = x; // autofix
    _ = vm; // autofix
    unreachable;
}

pub fn where(vm: *Vm, x: *Value) !*Value {
    _ = x; // autofix
    _ = vm; // autofix
    unreachable;
}

pub fn reverse(vm: *Vm, x: *Value) !*Value {
    _ = x; // autofix
    _ = vm; // autofix
    unreachable;
}

pub fn @"null"(vm: *Vm, x: *Value) !*Value {
    _ = x; // autofix
    _ = vm; // autofix
    unreachable;
}

pub fn group(vm: *Vm, x: *Value) !*Value {
    _ = x; // autofix
    _ = vm; // autofix
    unreachable;
}

pub fn asc(vm: *Vm, x: *Value) !*Value {
    _ = x; // autofix
    _ = vm; // autofix
    unreachable;
}

pub fn desc(vm: *Vm, x: *Value) !*Value {
    _ = x; // autofix
    _ = vm; // autofix
    unreachable;
}

pub fn string(vm: *Vm, x: *Value) !*Value {
    _ = x; // autofix
    _ = vm; // autofix
    unreachable;
}

pub fn list(vm: *Vm, x: *Value) !*Value {
    switch (x.as) {
        .list,
        .boolean_list,
        .long_list,
        .float_list,
        .char_list,
        .symbol_list,
        .lambda,
        .unary_primitive,
        .operator,
        .iterator,
        .projection,
        .each,
        .over,
        .scan,
        .each_prior,
        .each_right,
        .each_left,
        => {
            const v = try vm.allocValue(.list, 1);
            errdefer comptime unreachable;
            v.as.list[0] = x.ref();
            return v;
        },
        .boolean => |val| {
            const v = try vm.allocValue(.boolean_list, 1);
            errdefer comptime unreachable;
            v.as.boolean_list[0] = val;
            return v;
        },
        .long => |val| {
            const v = try vm.allocValue(.long_list, 1);
            errdefer comptime unreachable;
            v.as.long_list[0] = val;
            return v;
        },
        .float => |val| {
            const v = try vm.allocValue(.float_list, 1);
            errdefer comptime unreachable;
            v.as.float_list[0] = val;
            return v;
        },
        .char => |val| {
            const v = try vm.allocValue(.char_list, 1);
            errdefer comptime unreachable;
            v.as.char_list[0] = val;
            return v;
        },
        .symbol => |val| {
            const v = try vm.allocValue(.symbol_list, 1);
            errdefer comptime unreachable;
            v.as.symbol_list[0] = val;
            return v;
        },
        .dict => return error.nyi,
    }
}

pub fn count(vm: *Vm, x: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    unreachable;
}

pub fn lower(vm: *Vm, x: *Value) !*Value {
    _ = x; // autofix
    _ = vm; // autofix
    unreachable;
}

pub fn not(vm: *Vm, x: *Value) !*Value {
    _ = x; // autofix
    _ = vm; // autofix
    unreachable;
}

pub fn key(vm: *Vm, x: *Value) !*Value {
    switch (x.as) {
        .list => return error.nyi,
        .boolean => return error.nyi,
        .boolean_list => return error.nyi,
        .long => |val| {
            if (val < 0) return error.domain;
            const long_list = try vm.allocValue(.long_list, @intCast(val));
            errdefer comptime unreachable;
            for (long_list.as.long_list, 0..) |*v, i| v.* = @intCast(i);
            return long_list;
        },
        .long_list => return error.nyi,
        .float => return error.nyi,
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

pub fn distinct(vm: *Vm, x: *Value) !*Value {
    _ = x; // autofix
    _ = vm; // autofix
    unreachable;
}

pub fn @"type"(vm: *Vm, x: *Value) !*Value {
    return vm.createValue(.long, @intFromEnum(x.as));
}

pub fn value(vm: *Vm, x: *Value) !*Value {
    std.log.debug("value: {f}", .{x.fmt(vm)});
    switch (x.as) {
        .list => return error.nyi,
        .boolean => return error.nyi,
        .boolean_list => return error.nyi,
        .long => return error.nyi,
        .long_list => return error.nyi,
        .float => return error.nyi,
        .float_list => return error.nyi,
        .char => return error.nyi,
        .char_list => return error.nyi,
        .symbol => |identifier| {
            if (identifier == .empty) {
                return vm.state.ref();
            } else {
                const identifier_string = vm.internedString(identifier);
                const state, const symbol = if (identifier_string[0] == '.') state_symbol: {
                    assert(identifier_string.len > 1);
                    var it = std.mem.splitScalar(u8, identifier_string, '.');
                    var prev = it.first();
                    assert(prev.len == 0);
                    var symbol: Symbol = .empty;
                    var state = vm.state.as.dict;
                    while (it.next()) |entry| {
                        if (std.mem.findScalar(Symbol, state.keys.as.symbol_list, symbol)) |index| {
                            state = state.values.as.list[index].as.dict;
                        } else return error.identifier;

                        prev = entry;
                        symbol = try vm.intern(prev);
                    }

                    break :state_symbol .{ state, symbol };
                } else state_symbol: {
                    assert(std.mem.countScalar(u8, vm.internedString(identifier), '.') == 0);
                    break :state_symbol .{ vm.state.as.dict.values.as.list[0].as.dict, identifier };
                };

                if (std.mem.findScalar(Symbol, state.keys.as.symbol_list, symbol)) |index| {
                    return state.values.as.list[index].ref();
                } else return error.identifier;
            }
        },
        .symbol_list => return error.nyi,
        .dict => return error.nyi,
        .lambda => |lambda| {
            const bytecode = try vm.allocValue(.long_list, lambda.bytecode.len);
            errdefer bytecode.deref(vm.gpa);
            for (bytecode.as.long_list, lambda.bytecode) |*v, byte| v.* = byte;

            const params = try vm.allocValue(.symbol_list, lambda.params.len);
            errdefer params.deref(vm.gpa);
            for (params.as.symbol_list, lambda.params) |*v, symbol| v.* = symbol;

            const locals = try vm.allocValue(.symbol_list, lambda.locals.len);
            errdefer locals.deref(vm.gpa);
            for (locals.as.symbol_list, lambda.locals) |*v, symbol| v.* = symbol;

            const globals = try vm.allocValue(.symbol_list, lambda.globals.len);
            errdefer globals.deref(vm.gpa);
            for (globals.as.symbol_list, lambda.globals) |*v, symbol| v.* = symbol;

            const constants = try vm.allocValue(.list, lambda.constants.len);
            errdefer constants.deref(vm.gpa);
            for (constants.as.list, lambda.constants) |*v, val| v.* = val;

            const source = try vm.allocValue(.char_list, lambda.source.len);
            errdefer source.deref(vm.gpa);
            @memcpy(source.as.char_list, lambda.source);

            const list_value = try vm.allocValue(.list, 6);
            errdefer comptime unreachable;

            list_value.as.list[0] = bytecode;
            list_value.as.list[1] = params;
            list_value.as.list[2] = locals;
            list_value.as.list[3] = globals;
            list_value.as.list[4] = constants;
            list_value.as.list[5] = source;

            return list_value;
        },
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

pub fn read_text(vm: *Vm, x: *Value) !*Value {
    _ = x; // autofix
    _ = vm; // autofix
    unreachable;
}

pub fn read_binary(vm: *Vm, x: *Value) !*Value {
    _ = x; // autofix
    _ = vm; // autofix
    unreachable;
}
