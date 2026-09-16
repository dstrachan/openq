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
                vm.gpa.free(v.as.list);
                vm.gpa.destroy(v);
            }
            for (v.as.list, val) |*vv, elem| {
                vv.* = try neg(vm, elem);
                i += 1;
            }
            return v;
        },
        // Booleans and bytes negate to ints, as q does; nulls wrap back onto themselves.
        .boolean => |val| return vm.createValue(.int, -%@as(i32, @intFromBool(val))),
        .boolean_list => |val| {
            const v = try vm.allocValue(.int_list, val.len);
            errdefer comptime unreachable;
            for (v.as.int_list, val) |*vv, elem| vv.* = -%@as(i32, @intFromBool(elem));
            return v;
        },
        .byte => |val| return vm.createValue(.int, -%@as(i32, val)),
        .byte_list => |val| {
            const v = try vm.allocValue(.int_list, val.len);
            errdefer comptime unreachable;
            for (v.as.int_list, val) |*vv, elem| vv.* = -%@as(i32, elem);
            return v;
        },
        inline .short,
        .int,
        .long,
        .real,
        .float,
        .timestamp,
        .month,
        .date,
        .datetime,
        .timespan,
        .minute,
        .second,
        .time,
        => |val, tag| return vm.createValue(tag, negate(val)),
        inline .short_list,
        .int_list,
        .long_list,
        .real_list,
        .float_list,
        .timestamp_list,
        .month_list,
        .date_list,
        .datetime_list,
        .timespan_list,
        .minute_list,
        .second_list,
        .time_list,
        => |val, tag| {
            const v = try vm.allocValue(tag, val.len);
            errdefer comptime unreachable;
            for (@field(v.as, @tagName(tag)), val) |*vv, elem| vv.* = negate(elem);
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

/// Negation that keeps an integer null (the minimum value) a null by wrapping.
fn negate(number: anytype) @TypeOf(number) {
    return switch (@typeInfo(@TypeOf(number))) {
        .int => -%number,
        else => -number,
    };
}

pub fn first(vm: *Vm, x: *Value) !*Value {
    switch (x.as) {
        .list => |val| return val[0].ref(),
        .boolean,
        .byte,
        .short,
        .int,
        .long,
        .real,
        .float,
        .char,
        .symbol,
        .timestamp,
        .month,
        .date,
        .datetime,
        .timespan,
        .minute,
        .second,
        .time,
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
        .byte_list => |val| return vm.createValue(.byte, val[0]),
        .short_list => |val| return vm.createValue(.short, val[0]),
        .int_list => |val| return vm.createValue(.int, val[0]),
        .long_list => |val| return vm.createValue(.long, val[0]),
        .real_list => |val| return vm.createValue(.real, val[0]),
        .float_list => |val| return vm.createValue(.float, val[0]),
        .char_list => |val| return vm.createValue(.char, val[0]),
        .timestamp_list => |val| return vm.createValue(.timestamp, val[0]),
        .month_list => |val| return vm.createValue(.month, val[0]),
        .date_list => |val| return vm.createValue(.date, val[0]),
        .datetime_list => |val| return vm.createValue(.datetime, val[0]),
        .timespan_list => |val| return vm.createValue(.timespan, val[0]),
        .minute_list => |val| return vm.createValue(.minute, val[0]),
        .second_list => |val| return vm.createValue(.second, val[0]),
        .time_list => |val| return vm.createValue(.time, val[0]),
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
    return enlist(vm, x);
}

pub fn count(vm: *Vm, x: *Value) !*Value {
    return vm.createValue(.long, @intCast(x.count()));
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
        .byte => return error.nyi,
        .byte_list => return error.nyi,
        .short => return error.nyi,
        .short_list => return error.nyi,
        .int => return error.nyi,
        .int_list => return error.nyi,
        .real => return error.nyi,
        .real_list => return error.nyi,
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
        .timestamp => return error.nyi,
        .timestamp_list => return error.nyi,
        .month => return error.nyi,
        .month_list => return error.nyi,
        .date => return error.nyi,
        .date_list => return error.nyi,
        .datetime => return error.nyi,
        .datetime_list => return error.nyi,
        .timespan => return error.nyi,
        .timespan_list => return error.nyi,
        .minute => return error.nyi,
        .minute_list => return error.nyi,
        .second => return error.nyi,
        .second_list => return error.nyi,
        .time => return error.nyi,
        .time_list => return error.nyi,
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
    return vm.createValue(.short, @backingInt(x.as));
}

pub fn value(vm: *Vm, x: *Value) !*Value {
    std.log.debug("value: {f}", .{x.fmt(vm)});
    switch (x.as) {
        .list => return error.nyi,
        .boolean => return error.nyi,
        .boolean_list => return error.nyi,
        .byte => return error.nyi,
        .byte_list => return error.nyi,
        .short => return error.nyi,
        .short_list => return error.nyi,
        .int => return error.nyi,
        .int_list => return error.nyi,
        .long => return error.nyi,
        .long_list => return error.nyi,
        .real => return error.nyi,
        .real_list => return error.nyi,
        .float => return error.nyi,
        .float_list => return error.nyi,
        .char => return error.nyi,
        .char_list => |source| {
            // A string starting with a backslash is a system command; anything else is q source.
            if (source.len > 0 and source[0] == '\\') return vm.system(source[1..]);
            if (std.mem.trim(u8, source, " \t\r\n").len == 0) return vm.getUnaryPrimitive(.identity);
            const slice = try vm.gpa.dupeSentinel(u8, source, 0);
            defer vm.gpa.free(slice);
            return vm.evalSource(slice, .q, "<value>");
        },
        .symbol => |identifier| return vm.readGlobal(identifier),
        .symbol_list => return error.nyi,
        .timestamp => return error.nyi,
        .timestamp_list => return error.nyi,
        .month => return error.nyi,
        .month_list => return error.nyi,
        .date => return error.nyi,
        .date_list => return error.nyi,
        .datetime => return error.nyi,
        .datetime_list => return error.nyi,
        .timespan => return error.nyi,
        .timespan_list => return error.nyi,
        .minute => return error.nyi,
        .minute_list => return error.nyi,
        .second => return error.nyi,
        .second_list => return error.nyi,
        .time => return error.nyi,
        .time_list => return error.nyi,
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

            // As in q, the globals list starts with the namespace the lambda was defined in,
            // written without its dot: `` ` `` for the root and `` `foo `` for `.foo`.
            const globals = try vm.allocValue(.symbol_list, lambda.globals.len + 1);
            errdefer globals.deref(vm.gpa);
            globals.as.symbol_list[0] = try vm.intern(vm.internedString(lambda.namespace)[1..]);
            for (globals.as.symbol_list[1..], lambda.globals) |*v, symbol| v.* = symbol;

            const constants = try vm.allocValue(.list, lambda.constants.len);
            errdefer constants.deref(vm.gpa);
            for (constants.as.list, lambda.constants) |*v, val| v.* = val.ref();

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

pub fn enlist(vm: *Vm, x: *Value) !*Value {
    switch (x.as) {
        .list,
        .boolean_list,
        .byte_list,
        .short_list,
        .int_list,
        .long_list,
        .real_list,
        .float_list,
        .char_list,
        .symbol_list,
        .timestamp_list,
        .month_list,
        .date_list,
        .datetime_list,
        .timespan_list,
        .minute_list,
        .second_list,
        .time_list,
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
        inline .boolean,
        .byte,
        .short,
        .int,
        .long,
        .real,
        .float,
        .char,
        .symbol,
        .timestamp,
        .month,
        .date,
        .datetime,
        .timespan,
        .minute,
        .second,
        .time,
        => |val, tag| {
            const list_tag = @field(Value.Type, @tagName(tag) ++ "_list");
            const v = try vm.allocValue(list_tag, 1);
            errdefer comptime unreachable;
            @field(v.as, @tagName(list_tag))[0] = val;
            return v;
        },
        .dict => return error.nyi,
    }
}

pub fn abs(vm: *Vm, x: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    return error.nyi;
}

pub fn acos(vm: *Vm, x: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    return error.nyi;
}

pub fn asin(vm: *Vm, x: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    return error.nyi;
}

pub fn atan(vm: *Vm, x: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    return error.nyi;
}

pub fn avg(vm: *Vm, x: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    return error.nyi;
}

pub fn cos(vm: *Vm, x: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    return error.nyi;
}

pub fn dev(vm: *Vm, x: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    return error.nyi;
}

pub fn exit(vm: *Vm, x: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    return error.nyi;
}

pub fn exp(vm: *Vm, x: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    return error.nyi;
}

pub fn getenv(vm: *Vm, x: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    return error.nyi;
}

pub fn hopen(vm: *Vm, x: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    return error.nyi;
}

pub fn last(vm: *Vm, x: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    return error.nyi;
}

pub fn log(vm: *Vm, x: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    return error.nyi;
}

pub fn max(vm: *Vm, x: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    return error.nyi;
}

pub fn min(vm: *Vm, x: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    return error.nyi;
}

pub fn prd(vm: *Vm, x: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    return error.nyi;
}

pub fn sin(vm: *Vm, x: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    return error.nyi;
}

pub fn sqrt(vm: *Vm, x: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    return error.nyi;
}

pub fn sum(vm: *Vm, x: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    return error.nyi;
}

pub fn tan(vm: *Vm, x: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    return error.nyi;
}

pub fn @"var"(vm: *Vm, x: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    return error.nyi;
}
