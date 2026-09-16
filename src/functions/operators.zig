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

/// `n#y` takes `n` items of `y`, cycling through a list (`3#1 2` is `1 2 1`), repeating an
/// atom (`2#1` is `1 1`), from the end for negative `n` (`-2#1 2 3` is `2 3`), and filling an
/// empty list with nulls (`2#""` is `"  "`). `0#y` is the empty list of `y`'s type, which is
/// how q spells typed empties: `0#0` is `` `long$() ``.
pub fn take(vm: *Vm, x: *Value, y: *Value) !*Value {
    const n: i64 = switch (x.as) {
        .short => |v| if (v == @backingInt(Value.Short.null)) return error.type else v,
        .int => |v| if (v == @backingInt(Value.Int.null)) return error.type else v,
        .long => |v| if (v == @backingInt(Value.Long.null)) return error.type else v,
        .short_list, .int_list, .long_list => return error.nyi, // reshape
        else => return error.type,
    };
    const len: usize = @intCast(@abs(n));
    switch (y.as) {
        inline .list,
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
        => |items, tag| {
            const result = try vm.allocValue(tag, len);
            errdefer result.deref(vm.gpa);
            const out = @field(result.as, @tagName(tag));
            if (items.len == 0) {
                for (out) |*item| item.* = try nullOf(vm, tag);
                return result;
            }
            const start: usize = if (n >= 0) 0 else (items.len - len % items.len) % items.len;
            for (out, 0..) |*item, i| {
                const source = items[(start + i) % items.len];
                item.* = if (tag == .list) source.ref() else source;
            }
            return result;
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
        => |atom, tag| {
            const list_tag = @field(Value.Type, @tagName(tag) ++ "_list");
            const result = try vm.allocValue(list_tag, len);
            errdefer comptime unreachable;
            for (@field(result.as, @tagName(list_tag))) |*item| item.* = atom;
            return result;
        },
        .dict => return error.nyi,
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
            const result = try vm.allocValue(.list, len);
            errdefer comptime unreachable;
            for (result.as.list) |*item| item.* = y.ref();
            return result;
        },
    }
}

/// The null item of a list type: what `2#""` or `2#`long$()` fills with.
fn nullOf(vm: *Vm, comptime tag: Value.Type) !@typeInfo(@FieldType(Value.Union, @tagName(tag))).pointer.child {
    return switch (tag) {
        .list => try vm.allocValue(.list, 0),
        .boolean_list => false,
        .byte_list => 0,
        .short_list => @backingInt(Value.Short.null),
        .int_list, .month_list, .date_list, .minute_list, .second_list, .time_list => @backingInt(Value.Int.null),
        .long_list, .timestamp_list, .timespan_list => @backingInt(Value.Long.null),
        .real_list => std.math.nan(f32),
        .float_list, .datetime_list => std.math.nan(f64),
        .char_list => ' ',
        .symbol_list => .empty,
        else => comptime unreachable,
    };
}

/// `x$y` casts `y` to the type named by the symbol `x` (`` `long$1.9 ``) or its letter
/// (`"j"$1.9`), and `` `$"abc" `` makes a symbol of a string. Casting `()` gives the typed
/// empty (`` `long$() ``). Numbers round half away from zero, shorts and ints saturate to their
/// infinities while bytes wrap, nulls stay null except into booleans and bytes, and temporal
/// values convert by days and nanoseconds.
pub fn cast(vm: *Vm, x: *Value, y: *Value) !*Value {
    const target: Target = switch (x.as) {
        .symbol => |name| Target.fromName(vm.internedString(name)) orelse return error.domain,
        // A capital letter parses text, as `"J"$"12"`.
        .char => |letter| if (std.ascii.isUpper(letter)) return parseCast(vm, letter, y) else Target.fromLetter(letter) orelse return error.domain,
        else => return error.nyi,
    };
    return castTo(vm, target, y);
}

const Target = union(enum) {
    /// A symbol from a string, spelled `` `$ ``.
    symbol_from_string,
    /// An atom type, whose list type holds cast lists.
    atom: Value.Type,

    fn fromName(name: []const u8) ?Target {
        if (name.len == 0) return .symbol_from_string;
        const tag = std.meta.stringToEnum(Value.Type, name) orelse return null;
        return if (@backingInt(tag) < 0) .{ .atom = tag } else null;
    }

    fn fromLetter(letter: u8) ?Target {
        return .{ .atom = switch (letter) {
            'b' => .boolean,
            'x' => .byte,
            'h' => .short,
            'i' => .int,
            'j' => .long,
            'e' => .real,
            'f' => .float,
            'c' => .char,
            's' => .symbol,
            'p' => .timestamp,
            'm' => .month,
            'd' => .date,
            'z' => .datetime,
            'n' => .timespan,
            'u' => .minute,
            'v' => .second,
            't' => .time,
            else => return null,
        } };
    }
};

const CastError = Allocator.Error || error{ type, nyi, domain };

/// `"J"$"12"` and the other capital letters parse a string, a char, or each string of a
/// list of strings; `()` gives the typed empty.
fn parseCast(vm: *Vm, letter: u8, y: *Value) CastError!*Value {
    switch (y.as) {
        .char_list => |text| return parseCastText(vm, letter, text),
        .char => |c| return parseCastText(vm, letter, &.{c}),
        .list => |items| {
            if (items.len == 0) return switch (letter) {
                'S' => vm.allocValue(.symbol_list, 0),
                'C' => vm.allocValue(.char_list, 0),
                else => switch (q.literal.kindOfCapital(letter) orelse return error.domain) {
                    inline else => |kind| vm.allocValue(comptime kind.listType(), 0),
                },
            };
            const results = try vm.gpa.alloc(*Value, items.len);
            defer vm.gpa.free(results);
            var done: usize = 0;
            defer for (results[0..done]) |r| r.deref(vm.gpa);
            for (items) |item| {
                results[done] = try parseCast(vm, letter, item);
                done += 1;
            }
            return vm.enlist(results);
        },
        else => return error.type,
    }
}

fn parseCastText(vm: *Vm, letter: u8, text: []const u8) CastError!*Value {
    switch (letter) {
        'S' => return vm.createValue(.symbol, try vm.intern(std.mem.trim(u8, text, " "))),
        // q keeps a single char and turns anything else into a space.
        'C' => return vm.createValue(.char, if (text.len == 1) text[0] else ' '),
        else => {
            const kind = q.literal.kindOfCapital(letter) orelse return error.domain;
            switch (q.literal.parseLoose(kind, text)) {
                inline else => |value, k| return vm.createValue(comptime k.atomType(), value),
            }
        },
    }
}

fn castTo(vm: *Vm, target: Target, y: *Value) CastError!*Value {
    switch (target) {
        .symbol_from_string => switch (y.as) {
            .list => |items| {
                if (items.len == 0) return vm.allocValue(.symbol_list, 0);
                return castEach(vm, target, items);
            },
            .char_list => |text| return vm.createValue(.symbol, try vm.intern(text)),
            .char => |c| return vm.createValue(.symbol, try vm.intern(&.{c})),
            .symbol, .symbol_list => return y.ref(),
            else => return error.type,
        },
        .atom => |tag| switch (tag) {
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
            => |t| return castToAtomType(vm, t, y),
            else => unreachable,
        },
    }
}

/// Casts every item of a general list and unifies the results.
fn castEach(vm: *Vm, target: Target, items: []*Value) !*Value {
    const results = try vm.gpa.alloc(*Value, items.len);
    defer vm.gpa.free(results);
    var done: usize = 0;
    defer for (results[0..done]) |r| r.deref(vm.gpa);
    for (items) |item| {
        results[done] = try castTo(vm, target, item);
        done += 1;
    }
    return vm.enlist(results);
}

fn castToAtomType(vm: *Vm, comptime tag: Value.Type, y: *Value) !*Value {
    const list_tag = @field(Value.Type, @tagName(tag) ++ "_list");
    switch (y.as) {
        .list => |items| {
            if (items.len == 0) return vm.allocValue(list_tag, 0);
            return castEach(vm, .{ .atom = tag }, items);
        },
        .dict => return error.nyi,
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
        => return error.type,
        else => {},
    }
    if (y.isList()) {
        const result = try vm.allocValue(list_tag, y.count());
        errdefer result.deref(vm.gpa);
        for (@field(result.as, @tagName(list_tag)), 0..) |*item, i| item.* = try convert(tag, Scalar.at(y, i));
        return result;
    }
    return vm.createValue(tag, try convert(tag, Scalar.at(y, 0)));
}

/// One item of a data value, reduced to what casting needs.
const Scalar = union(enum) {
    /// Booleans, bytes, shorts, ints, longs and chars (their code).
    integer: i64,
    /// A null short, int or long.
    null_integer,
    floating: f64,
    symbol: Symbol,
    /// A non-null int- or long-backed temporal.
    temporal: struct { tag: Value.Type, raw: i64 },
    null_temporal: Value.Type,
    datetime: f64,

    fn at(y: *Value, i: usize) Scalar {
        return switch (y.as) {
            .boolean => |v| .{ .integer = @intFromBool(v) },
            .boolean_list => |v| .{ .integer = @intFromBool(v[i]) },
            .byte => |v| .{ .integer = v },
            .byte_list => |v| .{ .integer = v[i] },
            .char => |v| .{ .integer = v },
            .char_list => |v| .{ .integer = v[i] },
            .short => |v| ofInteger(Value.Short, v),
            .short_list => |v| ofInteger(Value.Short, v[i]),
            .int => |v| ofInteger(Value.Int, v),
            .int_list => |v| ofInteger(Value.Int, v[i]),
            .long => |v| ofInteger(Value.Long, v),
            .long_list => |v| ofInteger(Value.Long, v[i]),
            .real => |v| .{ .floating = v },
            .real_list => |v| .{ .floating = v[i] },
            .float => |v| .{ .floating = v },
            .float_list => |v| .{ .floating = v[i] },
            .symbol => |v| .{ .symbol = v },
            .symbol_list => |v| .{ .symbol = v[i] },
            .datetime => |v| .{ .datetime = v },
            .datetime_list => |v| .{ .datetime = v[i] },
            inline .month, .date, .minute, .second, .time => |v, t| ofTemporal(t, Value.Int, v),
            inline .month_list, .date_list, .minute_list, .second_list, .time_list => |v, t| ofTemporal(atomOf(t), Value.Int, v[i]),
            inline .timestamp, .timespan => |v, t| ofTemporal(t, Value.Long, v),
            inline .timestamp_list, .timespan_list => |v, t| ofTemporal(atomOf(t), Value.Long, v[i]),
            else => unreachable,
        };
    }

    fn ofInteger(comptime I: type, v: anytype) Scalar {
        return if (v == @backingInt(I.null)) .null_integer else .{ .integer = v };
    }

    fn ofTemporal(comptime tag: Value.Type, comptime I: type, v: anytype) Scalar {
        return if (v == @backingInt(I.null)) .{ .null_temporal = tag } else .{ .temporal = .{ .tag = tag, .raw = v } };
    }

    fn atomOf(comptime list_tag: Value.Type) Value.Type {
        const name = @tagName(list_tag);
        return @field(Value.Type, name[0 .. name.len - "_list".len]);
    }
};

fn convert(comptime tag: Value.Type, s: Scalar) !@FieldType(Value.Union, @tagName(tag)) {
    return switch (tag) {
        .boolean => switch (s) {
            .integer => |v| v != 0,
            .null_integer => true,
            .floating => |v| v != 0,
            .symbol => error.type,
            .temporal => |t| t.raw != 0,
            .null_temporal => true,
            .datetime => |v| v != 0,
        },
        .byte, .char => switch (s) {
            .integer => |v| @truncate(@as(u64, @bitCast(v))),
            .null_integer => 0,
            .floating => |v| @truncate(@as(u128, @bitCast(roundToInteger(v) orelse 0))),
            .symbol => error.type,
            .temporal => |t| @truncate(@as(u64, @bitCast(t.raw))),
            .null_temporal => 0,
            .datetime => |v| @truncate(@as(u128, @bitCast(roundToInteger(v) orelse 0))),
        },
        .short => try convertInteger(Value.Short, s),
        .int => try convertInteger(Value.Int, s),
        .long => try convertInteger(Value.Long, s),
        .real => @floatCast(try convertFloat(s)),
        .float => try convertFloat(s),
        .symbol => switch (s) {
            .symbol => |v| v,
            else => error.type,
        },
        .datetime => switch (s) {
            .integer => |v| @floatFromInt(v),
            .null_integer => std.math.nan(f64),
            .floating => |v| v,
            .symbol => error.type,
            .temporal => |t| switch (t.tag) {
                .date => @floatFromInt(t.raw),
                .timestamp => @as(f64, @floatFromInt(t.raw)) / @as(f64, @floatFromInt(q.literal.ns_per_day)),
                .month => @floatFromInt(monthToDays(t.raw)),
                else => error.type,
            },
            .null_temporal => std.math.nan(f64),
            .datetime => |v| v,
        },
        .month, .date, .minute, .second, .time => try convertTemporal(tag, Value.Int, s),
        .timestamp, .timespan => try convertTemporal(tag, Value.Long, s),
        else => comptime unreachable,
    };
}

/// Rounds half away from zero, as q casts do; null for a NaN.
fn roundToInteger(v: f64) ?i128 {
    if (std.math.isNan(v)) return null;
    if (std.math.isInf(v)) return if (v > 0) std.math.maxInt(i64) else std.math.minInt(i64) + 1;
    return @intFromFloat(@round(v));
}

/// Saturates to the type's infinities, as `` `short$70000 `` is `0Wh`.
fn saturate(comptime I: type, v: i128) @typeInfo(I).@"enum".tag_type {
    const T = @typeInfo(I).@"enum".tag_type;
    if (v >= std.math.maxInt(T)) return @backingInt(I.inf);
    if (v <= -std.math.maxInt(T)) return @backingInt(I.neg_inf);
    return @intCast(v);
}

fn convertInteger(comptime I: type, s: Scalar) !@typeInfo(I).@"enum".tag_type {
    return switch (s) {
        .integer => |v| saturate(I, v),
        .null_integer => @backingInt(I.null),
        .floating => |v| if (roundToInteger(v)) |r| saturate(I, r) else @backingInt(I.null),
        .symbol => error.type,
        .temporal => |t| saturate(I, t.raw),
        .null_temporal => @backingInt(I.null),
        .datetime => |v| if (roundToInteger(v)) |r| saturate(I, r) else @backingInt(I.null),
    };
}

fn convertFloat(s: Scalar) !f64 {
    return switch (s) {
        .integer => |v| @floatFromInt(v),
        .null_integer => std.math.nan(f64),
        .floating => |v| v,
        .symbol => error.type,
        .temporal => |t| @floatFromInt(t.raw),
        .null_temporal => std.math.nan(f64),
        .datetime => |v| v,
    };
}

fn convertTemporal(comptime tag: Value.Type, comptime I: type, s: Scalar) !@typeInfo(I).@"enum".tag_type {
    return switch (s) {
        .integer => |v| saturate(I, v),
        .null_integer => @backingInt(I.null),
        .floating => |v| if (roundToInteger(v)) |r| saturate(I, r) else @backingInt(I.null),
        .symbol => error.type,
        .null_temporal => @backingInt(I.null),
        .datetime => |v| if (std.math.isNan(v)) @backingInt(I.null) else switch (tag) {
            .date => saturate(I, @intFromFloat(@floor(v))),
            .timestamp => saturate(I, @intFromFloat(@round(v * @as(f64, @floatFromInt(q.literal.ns_per_day))))),
            .month => saturate(I, daysToMonth(@intFromFloat(@floor(v)))),
            else => error.type,
        },
        .temporal => |t| if (t.tag == tag) saturate(I, t.raw) else switch (tag) {
            .date => switch (t.tag) {
                .timestamp => saturate(I, @divFloor(t.raw, q.literal.ns_per_day)),
                .month => saturate(I, monthToDays(t.raw)),
                else => error.type,
            },
            .timestamp => switch (t.tag) {
                .date => saturate(I, @as(i128, t.raw) * q.literal.ns_per_day),
                .month => saturate(I, @as(i128, monthToDays(t.raw)) * q.literal.ns_per_day),
                else => error.type,
            },
            .month => switch (t.tag) {
                .date => saturate(I, daysToMonth(t.raw)),
                .timestamp => saturate(I, daysToMonth(@divFloor(t.raw, q.literal.ns_per_day))),
                else => error.type,
            },
            .minute, .second, .time, .timespan => switch (t.tag) {
                .minute, .second, .time, .timespan => saturate(I, @divTrunc(t.raw * Temporal.unitOf(t.tag), Temporal.unitOf(tag))),
                .timestamp => saturate(I, @divTrunc(@mod(t.raw, q.literal.ns_per_day), Temporal.unitOf(tag))),
                else => error.type,
            },
            else => comptime unreachable,
        },
    };
}

/// Days since 2000.01.01 of the first day of a month count since 2000.01.
fn monthToDays(months: i64) i64 {
    return q.literal.daysFromCivil(2000 + @divFloor(months, 12), @mod(months, 12) + 1, 1) - q.literal.epoch_days;
}

fn daysToMonth(days: i64) i64 {
    const civil = q.literal.civilFromDays(days + q.literal.epoch_days);
    return (civil.year - 2000) * 12 + civil.month - 1;
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
