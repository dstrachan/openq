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
        .symbol => |identifier| {
            const home = (try vm.identifierHome(identifier, true)).?;
            try vm.namespaceSet(home.namespace, home.name, y);
            return y;
        },
        // A keyword resolved while parsing q arrives here as its value, never as a name.
        else => return error.assign,
    }
}

pub fn add(vm: *Vm, x: *Value, y: *Value) !*Value {
    return arithmetic(vm, x, y, .add);
}

pub fn subtract(vm: *Vm, x: *Value, y: *Value) !*Value {
    return arithmetic(vm, x, y, .subtract);
}

pub fn multiply(vm: *Vm, x: *Value, y: *Value) !*Value {
    return arithmetic(vm, x, y, .multiply);
}

/// Division always produces a float, with `0w`, `-0w` and `0n` for division by zero.
pub fn divide(vm: *Vm, x: *Value, y: *Value) !*Value {
    if (Temporal.of(x) != null or Temporal.of(y) != null) return temporalArithmetic(vm, x, y, .divide);
    const a = Numeric.of(x) orelse return arithmeticError(x, y);
    const b = Numeric.of(y) orelse return arithmeticError(x, y);
    return vm.createValue(.float, a.toFloat() / b.toFloat());
}

const Arithmetic = enum { add, subtract, multiply, divide };

/// Atom arithmetic with q's promotion: booleans, bytes and shorts compute as ints, a null
/// operand gives a null result, and the result takes the wider of the two kinds.
fn arithmetic(vm: *Vm, x: *Value, y: *Value, comptime op: Arithmetic) !*Value {
    if (Temporal.of(x) != null or Temporal.of(y) != null) return temporalArithmetic(vm, x, y, op);
    const a = Numeric.of(x) orelse return arithmeticError(x, y);
    const b = Numeric.of(y) orelse return arithmeticError(x, y);
    const kind: Numeric.Kind = @fromBackingInt(@max(@backingInt(a.kind()), @backingInt(b.kind())));
    switch (kind) {
        .int => {
            const l = a.toInt() orelse return vm.createValue(.int, @backingInt(Value.Int.null));
            const r = b.toInt() orelse return vm.createValue(.int, @backingInt(Value.Int.null));
            return vm.createValue(.int, integer(op, l, r));
        },
        .long => {
            const l = a.toLong() orelse return vm.createValue(.long, @backingInt(Value.Long.null));
            const r = b.toLong() orelse return vm.createValue(.long, @backingInt(Value.Long.null));
            return vm.createValue(.long, integer(op, l, r));
        },
        .real => return vm.createValue(.real, floating(op, a.toReal(), b.toReal())),
        .float => return vm.createValue(.float, floating(op, a.toFloat(), b.toFloat())),
    }
}

fn arithmeticError(x: *Value, y: *Value) error{ nyi, type } {
    // Vector arithmetic is not implemented yet; anything else is a type error.
    return if (x.isList() or y.isList()) error.nyi else error.type;
}

/// Integer arithmetic wraps, so `0Wi+1i` becomes `0Ni` as in q.
fn integer(comptime op: Arithmetic, l: anytype, r: @TypeOf(l)) @TypeOf(l) {
    return switch (op) {
        .add => l +% r,
        .subtract => l -% r,
        .multiply => l *% r,
        .divide => unreachable,
    };
}

fn floating(comptime op: Arithmetic, l: anytype, r: @TypeOf(l)) @TypeOf(l) {
    return switch (op) {
        .add => l + r,
        .subtract => l - r,
        .multiply => l * r,
        .divide => l / r,
    };
}

/// A temporal atom: its type and its raw count, which is null when q's null.
const Temporal = struct {
    tag: Value.Type,
    raw: Raw,

    const Raw = union(enum) { int: ?i32, long: ?i64, float: f64 };

    fn of(x: *Value) ?Temporal {
        return switch (x.as) {
            inline .month, .date, .minute, .second, .time => |v, tag| .{ .tag = tag, .raw = .{ .int = if (v == @backingInt(Value.Int.null)) null else v } },
            inline .timestamp, .timespan => |v, tag| .{ .tag = tag, .raw = .{ .long = if (v == @backingInt(Value.Long.null)) null else v } },
            .datetime => |v| .{ .tag = .datetime, .raw = .{ .float = v } },
            else => null,
        };
    }

    fn isNull(self: Temporal) bool {
        return switch (self.raw) {
            .int => |v| v == null,
            .long => |v| v == null,
            .float => |v| std.math.isNan(v),
        };
    }

    /// The raw count as a float, the way `%` sees it.
    fn toFloat(self: Temporal) f64 {
        return switch (self.raw) {
            .int => |v| if (v) |i| @floatFromInt(i) else std.math.nan(f64),
            .long => |v| if (v) |i| @floatFromInt(i) else std.math.nan(f64),
            .float => |v| v,
        };
    }

    /// Nanoseconds of a non-null value: a time of day, a span, or whole days for a date.
    fn nanos(self: Temporal) i64 {
        if (self.tag == .datetime) return @intFromFloat(@round(self.raw.float * @as(f64, @floatFromInt(q.literal.ns_per_day))));
        const unit: i64 = if (self.tag == .date) q.literal.ns_per_day else if (self.tag == .timestamp) 1 else unitOf(self.tag);
        return switch (self.raw) {
            .int => |v| @as(i64, v.?) * unit,
            .long => |v| v.? * unit,
            .float => unreachable,
        };
    }

    fn isTimeOfDay(tag: Value.Type) bool {
        return switch (tag) {
            .minute, .second, .time, .timespan => true,
            else => false,
        };
    }

    fn isDateLike(tag: Value.Type) bool {
        return switch (tag) {
            .date, .timestamp, .datetime => true,
            else => false,
        };
    }

    /// The finer of two time-of-day types: a minute plus a second is a second.
    fn finer(a: Value.Type, b: Value.Type) Value.Type {
        return if (unitOf(a) <= unitOf(b)) a else b;
    }

    /// Nanoseconds per unit of a time-of-day type.
    fn unitOf(tag: Value.Type) i64 {
        return switch (tag) {
            .minute => 60 * q.literal.ns_per_second,
            .second => q.literal.ns_per_second,
            .time => 1_000_000,
            .timespan => 1,
            else => unreachable,
        };
    }
};

/// Creates a temporal atom from a raw count, or its null.
fn createTemporal(vm: *Vm, tag: Value.Type, value: ?i64) !*Value {
    return switch (tag) {
        inline .month, .date, .minute, .second, .time => |t| vm.createValue(t, if (value) |v| @as(i32, @truncate(v)) else @backingInt(Value.Int.null)),
        inline .timestamp, .timespan => |t| vm.createValue(t, if (value) |v| v else @backingInt(Value.Long.null)),
        .datetime => vm.createValue(.datetime, if (value) |v| @as(f64, @floatFromInt(v)) / @as(f64, @floatFromInt(q.literal.ns_per_day)) else std.math.nan(f64)),
        .int => vm.createValue(.int, if (value) |v| @as(i32, @truncate(v)) else @backingInt(Value.Int.null)),
        else => unreachable,
    };
}

/// Temporal arithmetic as q does it: an integer keeps the temporal type, `%` gives a float,
/// a fraction of a day turns a date into a datetime, subtracting two dates or months gives
/// an int while subtracting two times gives a time and two timestamps a timespan, times of
/// day combine at the finer resolution, and a date-like value plus a time of day is a
/// timestamp.
fn temporalArithmetic(vm: *Vm, x: *Value, y: *Value, comptime op: Arithmetic) !*Value {
    const tx = Temporal.of(x);
    const ty = Temporal.of(y);

    if (tx != null and ty != null) {
        const a = tx.?;
        const b = ty.?;
        if (op == .multiply or op == .divide) return error.type;
        if (a.tag == b.tag) {
            const result_tag: Value.Type = switch (a.tag) {
                .date, .month => .int,
                .minute, .second, .time, .timespan => a.tag,
                .timestamp => if (op == .subtract) .timespan else return error.nyi,
                .datetime => if (op == .subtract) .float else return error.nyi,
                else => unreachable,
            };
            if (result_tag == .float) return vm.createValue(.float, floating(op, a.raw.float, b.raw.float));
            if (a.isNull() or b.isNull()) return createTemporal(vm, result_tag, null);
            return switch (a.raw) {
                .int => |l| createTemporal(vm, result_tag, integer(op, @as(i64, l.?), @as(i64, b.raw.int.?))),
                .long => |l| createTemporal(vm, result_tag, integer(op, l.?, b.raw.long.?)),
                .float => unreachable,
            };
        }
        if (Temporal.isTimeOfDay(a.tag) and Temporal.isTimeOfDay(b.tag)) {
            const tag = Temporal.finer(a.tag, b.tag);
            if (a.isNull() or b.isNull()) return createTemporal(vm, tag, null);
            return createTemporal(vm, tag, @divTrunc(integer(op, a.nanos(), b.nanos()), Temporal.unitOf(tag)));
        }
        if (Temporal.isDateLike(a.tag) and Temporal.isTimeOfDay(b.tag)) {
            if (a.isNull() or b.isNull()) return createTemporal(vm, .timestamp, null);
            return createTemporal(vm, .timestamp, integer(op, a.nanos(), b.nanos()));
        }
        if (Temporal.isTimeOfDay(a.tag) and Temporal.isDateLike(b.tag) and op == .add) {
            if (a.isNull() or b.isNull()) return createTemporal(vm, .timestamp, null);
            return createTemporal(vm, .timestamp, a.nanos() + b.nanos());
        }
        return error.type;
    }

    // One side is a number. Commutative operations put the temporal value first.
    const t, const number, const flipped = if (tx) |a| .{ a, y, false } else .{ ty.?, x, true };
    const n = Numeric.of(number) orelse return arithmeticError(x, y);
    switch (op) {
        .divide => {
            const raw = t.toFloat();
            return vm.createValue(.float, if (flipped) n.toFloat() / raw else raw / n.toFloat());
        },
        .add, .subtract, .multiply => switch (n) {
            .int, .long => {
                const m = n.toLongAny() orelse return createTemporal(vm, t.tag, null);
                if (t.isNull()) return createTemporal(vm, t.tag, null);
                return switch (t.raw) {
                    .int => |v| createTemporal(vm, t.tag, if (flipped and op == .subtract) integer(op, m, @as(i64, v.?)) else integer(op, @as(i64, v.?), m)),
                    .long => |v| createTemporal(vm, t.tag, if (flipped and op == .subtract) integer(op, m, v.?) else integer(op, v.?, m)),
                    .float => |v| vm.createValue(.datetime, if (flipped and op == .subtract) floating(op, @as(f64, @floatFromInt(m)), v) else floating(op, v, @as(f64, @floatFromInt(m)))),
                };
            },
            .real, .float => {
                const l = t.toFloat();
                const r = n.toFloat();
                const value = if (flipped and op == .subtract) floating(op, r, l) else floating(op, l, r);
                // Fractional days turn a date into a datetime; every other type becomes a plain float.
                if ((t.tag == .date or t.tag == .datetime) and op != .multiply) return vm.createValue(.datetime, value);
                return vm.createValue(.float, value);
            },
        },
    }
}

/// A numeric atom widened to the kind q computes in. Integer nulls are carried as null.
const Numeric = union(enum) {
    int: ?i32,
    long: ?i64,
    real: f32,
    float: f64,

    const Kind = enum { int, long, real, float };

    fn of(x: *Value) ?Numeric {
        return switch (x.as) {
            .boolean => |v| .{ .int = @intFromBool(v) },
            .byte => |v| .{ .int = v },
            .short => |v| .{ .int = if (v == @backingInt(Value.Short.null)) null else v },
            .int => |v| .{ .int = if (v == @backingInt(Value.Int.null)) null else v },
            .long => |v| .{ .long = if (v == @backingInt(Value.Long.null)) null else v },
            .real => |v| .{ .real = v },
            .float => |v| .{ .float = v },
            else => null,
        };
    }

    fn kind(self: Numeric) Kind {
        return switch (self) {
            .int => .int,
            .long => .long,
            .real => .real,
            .float => .float,
        };
    }

    fn toInt(self: Numeric) ?i32 {
        return self.int;
    }

    fn toLong(self: Numeric) ?i64 {
        return switch (self) {
            .int => |v| if (v) |i| @as(i64, i) else null,
            .long => |v| v,
            else => unreachable,
        };
    }

    /// The integer value of an int or long operand, null for a null; not for reals or floats.
    fn toLongAny(self: Numeric) ?i64 {
        return switch (self) {
            .int => |v| if (v) |i| @as(i64, i) else null,
            .long => |v| v,
            else => unreachable,
        };
    }

    fn toReal(self: Numeric) f32 {
        return switch (self) {
            .int => |v| if (v) |i| @floatFromInt(i) else std.math.nan(f32),
            .long => |v| if (v) |i| @floatFromInt(i) else std.math.nan(f32),
            .real => |v| v,
            .float => unreachable,
        };
    }

    fn toFloat(self: Numeric) f64 {
        return switch (self) {
            .int => |v| if (v) |i| @floatFromInt(i) else std.math.nan(f64),
            .long => |v| if (v) |i| @floatFromInt(i) else std.math.nan(f64),
            .real => |v| v,
            .float => |v| v,
        };
    }
};

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
        .byte => return error.nyi,
        .short => return error.nyi,
        .int => return error.nyi,
        .real => return error.nyi,
        .timestamp => return error.nyi,
        .month => return error.nyi,
        .date => return error.nyi,
        .datetime => return error.nyi,
        .timespan => return error.nyi,
        .minute => return error.nyi,
        .second => return error.nyi,
        .time => return error.nyi,
        .boolean_list => return error.nyi,
        .byte_list => return error.nyi,
        .short_list => return error.nyi,
        .int_list => return error.nyi,
        .real_list => return error.nyi,
        .timestamp_list => return error.nyi,
        .month_list => return error.nyi,
        .date_list => return error.nyi,
        .datetime_list => return error.nyi,
        .timespan_list => return error.nyi,
        .minute_list => return error.nyi,
        .second_list => return error.nyi,
        .time_list => return error.nyi,
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
            .byte => return error.nyi,
            .short => return error.nyi,
            .int => return error.nyi,
            .real => return error.nyi,
            .timestamp => return error.nyi,
            .month => return error.nyi,
            .date => return error.nyi,
            .datetime => return error.nyi,
            .timespan => return error.nyi,
            .minute => return error.nyi,
            .second => return error.nyi,
            .time => return error.nyi,
            .boolean_list => return error.nyi,
            .byte_list => return error.nyi,
            .short_list => return error.nyi,
            .int_list => return error.nyi,
            .real_list => return error.nyi,
            .timestamp_list => return error.nyi,
            .month_list => return error.nyi,
            .date_list => return error.nyi,
            .datetime_list => return error.nyi,
            .timespan_list => return error.nyi,
            .minute_list => return error.nyi,
            .second_list => return error.nyi,
            .time_list => return error.nyi,
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
        => switch (y.as) {
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
            .dict,
            => {
                if (x.count() != y.count()) return error.length;
                const value = try vm.createValue(.dict, .{ .keys = undefined, .values = undefined });
                value.as.dict.keys = x.ref();
                value.as.dict.values = y.ref();
                return value;
            },
            .boolean => return error.nyi,
            .byte => return error.nyi,
            .short => return error.nyi,
            .int => return error.nyi,
            .real => return error.nyi,
            .timestamp => return error.nyi,
            .month => return error.nyi,
            .date => return error.nyi,
            .datetime => return error.nyi,
            .timespan => return error.nyi,
            .minute => return error.nyi,
            .second => return error.nyi,
            .time => return error.nyi,
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
        .byte => return error.nyi,
        .short => return error.nyi,
        .int => return error.nyi,
        .real => return error.nyi,
        .timestamp => return error.nyi,
        .month => return error.nyi,
        .date => return error.nyi,
        .datetime => return error.nyi,
        .timespan => return error.nyi,
        .minute => return error.nyi,
        .second => return error.nyi,
        .time => return error.nyi,
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

pub fn in(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    return error.nyi;
}

pub fn within(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    return error.nyi;
}

pub fn like(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    return error.nyi;
}

pub fn bin(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    return error.nyi;
}

pub fn binr(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    return error.nyi;
}

pub fn ss(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    return error.nyi;
}

pub fn insert(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    return error.nyi;
}

pub fn wsum(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    return error.nyi;
}

pub fn wavg(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    return error.nyi;
}

pub fn div(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    return error.nyi;
}

pub fn xexp(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    return error.nyi;
}

pub fn cor(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    return error.nyi;
}

pub fn cov(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    return error.nyi;
}

pub fn setenv(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    return error.nyi;
}
