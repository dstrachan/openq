const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const q = @import("../root.zig");
const Vm = q.Vm;
const Value = q.Value;
const Symbol = Value.Symbol;

/// `:` applied as a function returns its right argument, which `prev::':` relies on; it
/// never assigns. Assignment is done by parse trees and bytecode through `assignGlobal`.
/// q 5.0 gives `'match` for `(:)[1;2]`, which is not copied.
pub fn assign(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm;
    _ = x;
    return y.ref();
}

/// Assigns `y` to the global named by the symbol `x`, creating namespaces as needed, and
/// returns `y` without a new reference.
pub fn assignGlobal(vm: *Vm, x: *Value, y: *Value) !*Value {
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
pub fn divide(vm: *Vm, x: *Value, y: *Value) ArithmeticError!*Value {
    if (x.isList() or y.isList()) return listArithmetic(vm, x, y, .divide);
    if (Temporal.of(x) != null or Temporal.of(y) != null) return temporalArithmetic(vm, x, y, .divide);
    const a = Numeric.of(x) orelse return error.type;
    const b = Numeric.of(y) orelse return error.type;
    return vm.createValue(.float, a.toFloat() / b.toFloat());
}

const Arithmetic = enum { add, subtract, multiply, divide };

const ArithmeticError = Vm.RunError;

/// Atom arithmetic with q's promotion: booleans, bytes and shorts compute as ints, a null
/// operand gives a null result, and the result takes the wider of the two kinds.
fn arithmetic(vm: *Vm, x: *Value, y: *Value, comptime op: Arithmetic) Vm.RunError!*Value {
    if (try withDicts(vm, x, y, switch (op) {
        .add => add,
        .subtract => subtract,
        .multiply => multiply,
        .divide => divide,
    })) |result| return result;
    if (x.isList() or y.isList()) return listArithmetic(vm, x, y, op);
    if (Temporal.of(x) != null or Temporal.of(y) != null) return temporalArithmetic(vm, x, y, op);
    const a = Numeric.of(x) orelse return error.type;
    const b = Numeric.of(y) orelse return error.type;
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

/// Arithmetic over lists, item by item: an atom pairs with every item of a list, and two
/// lists pair up and must be the same length. Each pair is computed as atoms and the results
/// unified, so `1 2 3+1` is a long list and `(1 2;3)+(1;2 3)` a general list. This is the
/// simple path; typed fast paths belong with the primitives of section 6. Byte lists are a
/// type error, as in q, although a byte atom computes.
fn listArithmetic(vm: *Vm, x: *Value, y: *Value, comptime op: Arithmetic) ArithmeticError!*Value {
    if (x.as == .byte_list or y.as == .byte_list) return error.type;
    const x_len: ?usize = if (x.isList()) x.count() else null;
    const y_len: ?usize = if (y.isList()) y.count() else null;
    if (x_len != null and y_len != null and x_len.? != y_len.?) return error.length;
    const len = x_len orelse y_len.?;
    // An empty list stays as it is; q would still promote its type (`(`long$())+1.5` is
    // `` `float$() ``), which the typed paths will do.
    if (len == 0) return (if (x_len != null) x else y).ref();

    const results = try vm.gpa.alloc(*Value, len);
    defer vm.gpa.free(results);
    var done: usize = 0;
    defer for (results[0..done]) |r| r.deref(vm.gpa);
    for (0..len) |i| {
        const a = if (x_len != null) try itemAt(vm, x, i) else x.ref();
        defer a.deref(vm.gpa);
        const b = if (y_len != null) try itemAt(vm, y, i) else y.ref();
        defer b.deref(vm.gpa);
        results[done] = if (op == .divide) try divide(vm, a, b) else try arithmetic(vm, a, b, op);
        done += 1;
    }
    return vm.enlist(results);
}

/// The list type holding atoms of `tag`, or the atom type of the list type `tag`.
pub fn counterpart(comptime tag: Value.Type) Value.Type {
    return @fromBackingInt(-@backingInt(tag));
}

/// Item `i` of a list as a value of its own: the referenced item of a general list, or a
/// fresh atom from a typed list.
pub fn itemAt(vm: *Vm, list: *Value, i: usize) Allocator.Error!*Value {
    switch (list.as) {
        .list => |items| return items[i].ref(),
        inline .boolean_list,
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
        => |items, tag| return vm.createValue(comptime counterpart(tag), items[i]),
        else => unreachable,
    }
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
    const n = Numeric.of(number) orelse return error.type;
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

// @"and" is defined with the comparisons below.

// @"or" is defined with the comparisons below.

/// `x^y` fill: `y` with its nulls replaced by `x`, both first cast to the type the pair
/// promotes to, as q does: numbers widen (`0.0^1 0N 3` is `1 0 3f`, `0^0Nh` is `0`), a
/// temporal type wins over a number (`0.5^0Nd` is `2000.01.02`, `2000.01.01^1 0N` is
/// `2000.01.02 2000.01.01`), two times of day take the finer, a char wins over a number
/// so `"a"^0N` is `"\000"` (the cast null is no longer null), symbols only fill symbols,
/// and other mixes are a type error. An atom fills every item of a list and an empty
/// typed list is retyped (`` 0n^`long$() `` is `` `float$() ``); two lists pair up; a list
/// filling an atom is `nyi` as in q. A dictionary is filled by value, and one dictionary
/// fills another by key, the result holding both sets of keys.
pub fn fill(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    if (y.as == .dict) {
        if (x.as != .dict) return mapDictValues(vm, y, x, fill);
        return fillDict(vm, x, y);
    }
    if (Vm.isFunction(x) or x.as == .dict) return error.nyi;
    if (Vm.isFunction(y)) return error.type;
    if (x.isList() and !y.isList()) return error.nyi;
    if (y.isList() and y.count() == 0 and y.as != .list) {
        // An empty typed list keeps no items but takes the promoted type.
        if (x.isList()) return y.ref();
        const atom_tag: Value.Type = @fromBackingInt(-@backingInt(std.meta.activeTag(y.as)));
        const target = try fillType(std.meta.activeTag(x.as), atom_tag);
        return switch (target) {
            inline .boolean, .byte, .short, .int, .long, .real, .float, .char, .symbol, .timestamp, .month, .date, .datetime, .timespan, .minute, .second, .time => |t| vm.allocValue(comptime counterpart(t), 0),
            else => unreachable,
        };
    }
    return pairwise(vm, x, y, fillAtoms);
}

/// `f[x;]` over a dictionary's values, keeping its keys.
fn mapDictValues(vm: *Vm, d: *Value, x: *Value, comptime f: fn (*Vm, *Value, *Value) Vm.RunError!*Value) Vm.RunError!*Value {
    const values = try f(vm, x, d.as.dict.values);
    errdefer values.deref(vm.gpa);
    return vm.createValue(.dict, .{ .keys = d.as.dict.keys.ref(), .values = values });
}

/// One dictionary filling another: `y`'s null values are replaced by `x`'s value under the
/// same key, and keys of `x` missing from `y` are kept, so `` (`a`b!1 2)^`a`c!0N 3 `` is
/// `` `a`b`c!1 2 3 ``.
fn fillDict(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    const yd = y.as.dict;
    const n = yd.keys.count();
    const filled = try vm.gpa.alloc(*Value, n);
    defer vm.gpa.free(filled);
    var done: usize = 0;
    defer for (filled[0..done]) |v| v.deref(vm.gpa);
    for (0..n) |i| {
        const key = try itemAt(vm, yd.keys, i);
        defer key.deref(vm.gpa);
        const value = try itemAt(vm, yd.values, i);
        defer value.deref(vm.gpa);
        var args = [_]*Value{key};
        const from_x = try vm.applyImpl(x, &args);
        defer from_x.deref(vm.gpa);
        filled[done] = try fill(vm, from_x, value);
        done += 1;
    }
    const values = if (n == 0) try vm.allocValue(.list, 0) else try vm.enlist(filled);
    defer values.deref(vm.gpa);
    const replaced = try vm.createValue(.dict, .{ .keys = yd.keys.ref(), .values = values.ref() });
    defer replaced.deref(vm.gpa);
    return join(vm, x, replaced);
}

/// The type a fill of two atom types works in: symbols with symbols only, a char over a
/// number, a temporal type over a number, two times of day the finer, and otherwise the
/// wider number (booleans below bytes below shorts, ints, longs, reals and floats).
fn fillType(x: Value.Type, y: Value.Type) error{type}!Value.Type {
    if (x == .symbol or y == .symbol) return if (x == y) .symbol else error.type;
    const x_temporal = isTemporalTag(x);
    const y_temporal = isTemporalTag(y);
    if (x == .char or y == .char) {
        if (x_temporal or y_temporal) return error.type;
        return .char;
    }
    if (x_temporal and y_temporal) {
        if (x == y) return x;
        if (Temporal.isTimeOfDay(x) and Temporal.isTimeOfDay(y)) return Temporal.finer(x, y);
        return error.type;
    }
    if (x_temporal) return x;
    if (y_temporal) return y;
    return if (numericRank(x) >= numericRank(y)) x else y;
}

fn isTemporalTag(tag: Value.Type) bool {
    return switch (tag) {
        .timestamp, .month, .date, .datetime, .timespan, .minute, .second, .time => true,
        else => false,
    };
}

fn numericRank(tag: Value.Type) u8 {
    return switch (tag) {
        .boolean => 0,
        .byte => 1,
        .short => 2,
        .int => 3,
        .long => 4,
        .real => 5,
        .float => 6,
        else => unreachable,
    };
}

/// Whether an atom is the null of its type.
fn atomIsNull(v: *Value) bool {
    return switch (v.as) {
        .char => |c| c == ' ',
        .symbol => |s| s == .empty,
        else => if (Comparable.of(v)) |c| c == .null else false,
    };
}

fn castAtom(vm: *Vm, target: Value.Type, v: *Value) Vm.RunError!*Value {
    if (std.meta.activeTag(v.as) == target) return v.ref();
    return switch (target) {
        inline .boolean, .byte, .short, .int, .long, .real, .float, .char, .symbol, .timestamp, .month, .date, .datetime, .timespan, .minute, .second, .time => |t| castToAtomType(vm, t, v),
        else => unreachable,
    };
}

fn fillAtoms(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    // Items of a general list may be lists or dictionaries themselves.
    if (x.isList() or y.isList() or y.as == .dict) return fill(vm, x, y);
    if (Vm.isFunction(x) or x.as == .dict) return error.nyi;
    if (Vm.isFunction(y) or y.as == .dict) return error.type;
    const target = try fillType(std.meta.activeTag(x.as), std.meta.activeTag(y.as));
    const cast_y = try castAtom(vm, target, y);
    if (!atomIsNull(cast_y)) return cast_y;
    cast_y.deref(vm.gpa);
    return castAtom(vm, target, x);
}

// equal is defined with the comparisons below.

// less_than is defined with the comparisons below.

// greater_than is defined with the comparisons below.

/// `x,y` joins: items of the same type make a typed list (`1,2` is `1 2`, `"ab","cd"` is
/// `"abcd"`) and anything else a general list of the items (`1,2h` is `(1;2h)`, `(1 2;3),4`
/// is `(1 2;3;4)`). An empty right side is dropped; an empty left side is dropped too when
/// it is `()` or a boolean, byte or char empty, while another typed empty casts the right
/// side to its type (`` `long$(),1.5 `` is `,2`, `` `long$(),`a `` is a type error), as q
/// does. Two dictionaries merge with the right side's values winning.
pub fn join(vm: *Vm, x: *Value, y: *Value) !*Value {
    if (x.as == .table or y.as == .table) return joinTables(vm, x, y);
    if (x.as == .dict and y.as == .dict) return joinDicts(vm, x, y);
    if (x.as == .dict or y.as == .dict) return error.type;

    if (x.isList() and x.count() == 0) {
        switch (x.as) {
            .list, .boolean_list, .byte_list, .char_list => return asList(vm, y),
            inline .short_list,
            .int_list,
            .long_list,
            .real_list,
            .float_list,
            .symbol_list,
            .timestamp_list,
            .month_list,
            .date_list,
            .datetime_list,
            .timespan_list,
            .minute_list,
            .second_list,
            .time_list,
            => |_, tag| {
                if (y.isList() and y.count() == 0) return x.ref();
                const cast_value = try castTo(vm, .{ .atom = comptime counterpart(tag) }, y);
                if (cast_value.isList()) return cast_value;
                defer cast_value.deref(vm.gpa);
                return asList(vm, cast_value);
            },
            else => unreachable,
        }
    }
    if (y.isList() and y.count() == 0) return asList(vm, x);

    const x_len = if (x.isList()) x.count() else 1;
    const y_len = if (y.isList()) y.count() else 1;
    const items = try vm.gpa.alloc(*Value, x_len + y_len);
    defer vm.gpa.free(items);
    var done: usize = 0;
    defer for (items[0..done]) |item| item.deref(vm.gpa);
    for (0..x_len) |i| {
        items[done] = if (x.isList()) try itemAt(vm, x, i) else x.ref();
        done += 1;
    }
    for (0..y_len) |i| {
        items[done] = if (y.isList()) try itemAt(vm, y, i) else y.ref();
        done += 1;
    }
    return vm.enlist(items);
}

/// A value as a list: a list as it is, an atom as a one-item list.
fn asList(vm: *Vm, value: *Value) !*Value {
    if (value.isList()) return value.ref();
    var one = [_]*Value{value};
    return vm.enlist(&one);
}

/// `(`a`b!1 2),(`b`c!3 4)` is `` `a`b`c!1 3 4 ``: the left keys in order, then the right
/// side's new keys, with the right side's value for any key it has.
fn joinDicts(vm: *Vm, x: *Value, y: *Value) !*Value {
    const xd = x.as.dict;
    const yd = y.as.dict;
    const x_len = xd.keys.count();
    const y_len = yd.keys.count();
    const keys = try vm.gpa.alloc(*Value, x_len + y_len);
    defer vm.gpa.free(keys);
    const values = try vm.gpa.alloc(*Value, x_len + y_len);
    defer vm.gpa.free(values);
    var n: usize = 0;
    defer for (keys[0..n], values[0..n]) |k, v| {
        k.deref(vm.gpa);
        v.deref(vm.gpa);
    };
    for (0..x_len) |i| {
        const key = try itemAt(vm, xd.keys, i);
        errdefer key.deref(vm.gpa);
        values[n] = if (findKey(yd.keys, key)) |j| try itemAt(vm, yd.values, j) else try itemAt(vm, xd.values, i);
        keys[n] = key;
        n += 1;
    }
    for (0..y_len) |i| {
        const key = try itemAt(vm, yd.keys, i);
        if (findKey(xd.keys, key) != null) {
            key.deref(vm.gpa);
            continue;
        }
        errdefer key.deref(vm.gpa);
        values[n] = try itemAt(vm, yd.values, i);
        keys[n] = key;
        n += 1;
    }
    const key_list = if (n == 0) try vm.allocValue(.list, 0) else try vm.enlist(keys[0..n]);
    errdefer key_list.deref(vm.gpa);
    const value_list = if (n == 0) try vm.allocValue(.list, 0) else try vm.enlist(values[0..n]);
    errdefer value_list.deref(vm.gpa);
    return vm.createValue(.dict, .{ .keys = key_list, .values = value_list });
}

/// `x#y`: `n#y` takes `n` items of `y`, a list of counts reshapes, and a count or a list of
/// keys applied to a dictionary takes its entries.
pub fn take(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    if (x.as == .symbol and y.as != .table) return setAttribute(vm, x.as.symbol, y);
    if (y.as == .dict) return takeDict(vm, x, y);
    if (y.as == .table) return takeTable(vm, x, y);
    const n: i64 = switch (x.as) {
        .short => |v| if (v == @backingInt(Value.Short.null)) return error.type else v,
        .int => |v| if (v == @backingInt(Value.Int.null)) return error.type else v,
        .long => |v| if (v == @backingInt(Value.Long.null)) return error.type else v,
        .long_list => |dims| return reshape(vm, dims, y),
        else => return error.type,
    };
    return takeItems(vm, y, n, 0);
}

/// `n` items of `y` from `start` items in: a list is cycled through and an atom repeated,
/// a negative `n` takes from the end, and an empty list gives nulls (`2#""` is `"  "`).
fn takeItems(vm: *Vm, y: *Value, n: i64, start: usize) Vm.RunError!*Value {
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
            const first: usize = if (n >= 0) start else (items.len - len % items.len) % items.len;
            for (out, 0..) |*item, i| {
                const source = items[(first + i) % items.len];
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
        .dict, .table => unreachable,
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
        .composition,
        => {
            const result = try vm.allocValue(.list, len);
            errdefer comptime unreachable;
            for (result.as.list) |*item| item.* = y.ref();
            return result;
        },
    }
}

/// `2 3#y` reshapes `y` into rows, `(0 1 2;3 4 5)`, cycling through `y` as take does and
/// nesting for further dimensions. One of two dimensions may be `0N`: `0N 3#til 7` cuts rows
/// of 3 with a short last row and `3 0N#til 7` spreads the items over 3 rows.
fn reshape(vm: *Vm, dims: []const i64, y: *Value) Vm.RunError!*Value {
    if (dims.len == 0) return error.length;
    var nulls: usize = 0;
    for (dims) |d| {
        if (d == @backingInt(Value.Long.null)) nulls += 1 else if (d <= 0) return error.length;
    }
    if (nulls == 0) {
        var offset: usize = 0;
        return reshapeFrom(vm, dims, y, &offset);
    }
    if (dims.len != 2 or nulls == 2) return error.domain;

    const len = if (y.isList()) y.count() else 1;
    var rows: std.ArrayList(*Value) = .empty;
    defer {
        for (rows.items) |row| row.deref(vm.gpa);
        rows.deinit(vm.gpa);
    }
    if (dims[0] == @backingInt(Value.Long.null)) {
        const width: usize = @intCast(dims[1]);
        var offset: usize = 0;
        while (offset < len) : (offset += width) {
            const row = try takeItems(vm, y, @intCast(@min(width, len - offset)), offset);
            errdefer row.deref(vm.gpa);
            try rows.append(vm.gpa, row);
        }
    } else {
        const count: usize = @intCast(dims[0]);
        for (0..count) |i| {
            const from = i * len / count;
            const to = (i + 1) * len / count;
            const row = try takeItems(vm, y, @intCast(to - from), from);
            errdefer row.deref(vm.gpa);
            try rows.append(vm.gpa, row);
        }
    }
    if (rows.items.len == 0) return vm.allocValue(.list, 0);
    return vm.enlist(rows.items);
}

fn reshapeFrom(vm: *Vm, dims: []const i64, y: *Value, offset: *usize) Vm.RunError!*Value {
    const count: usize = @intCast(dims[0]);
    if (dims.len == 1) {
        const result = try takeItems(vm, y, dims[0], offset.*);
        offset.* += count;
        return result;
    }
    const rows = try vm.gpa.alloc(*Value, count);
    defer vm.gpa.free(rows);
    var done: usize = 0;
    defer for (rows[0..done]) |row| row.deref(vm.gpa);
    for (rows) |*row| {
        row.* = try reshapeFrom(vm, dims[1..], y, offset);
        done += 1;
    }
    return vm.enlist(rows);
}

/// `n#d` takes the first (or last) `n` entries of a dictionary, and `keys#d` the entries for
/// `keys`, with a null like the dictionary's first value in place of a missing key:
/// `` `a`x#`a`b`c!1 2 3 `` is `` `a`x!1 0N ``.
fn takeDict(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    const entries = y.as.dict;
    switch (x.as) {
        .short, .int, .long => {
            const keys = try take(vm, x, entries.keys);
            errdefer keys.deref(vm.gpa);
            const values = try take(vm, x, entries.values);
            errdefer values.deref(vm.gpa);
            return vm.createValue(.dict, .{ .keys = keys, .values = values });
        },
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
        => {
            // Keys of another type than the dictionary's are a type error, as `2 3#`a`b!1 2`.
            if (std.meta.activeTag(x.as) != std.meta.activeTag(entries.keys.as)) return error.type;
            const len = x.count();
            const found = try vm.gpa.alloc(*Value, len);
            defer vm.gpa.free(found);
            var done: usize = 0;
            defer for (found[0..done]) |v| v.deref(vm.gpa);
            for (0..len) |i| {
                const key = try itemAt(vm, x, i);
                defer key.deref(vm.gpa);
                found[done] = if (findKey(entries.keys, key)) |index| try itemAt(vm, entries.values, index) else try nullLike(vm, entries.values);
                done += 1;
            }
            const values = if (len == 0) try takeItems(vm, entries.values, 0, 0) else try vm.enlist(found);
            errdefer values.deref(vm.gpa);
            const keys = x.ref();
            errdefer keys.deref(vm.gpa);
            return vm.createValue(.dict, .{ .keys = keys, .values = values });
        },
        else => return error.type,
    }
}

/// The position of an atom `key` in a typed list of keys, or null when it is not there or
/// the types differ. General keys are not searched yet.
fn findKey(keys: *Value, key: *Value) ?usize {
    switch (keys.as) {
        inline .boolean_list,
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
            const atom_tag = comptime counterpart(tag);
            if (key.as != atom_tag) return null;
            const needle = @field(key.as, @tagName(atom_tag));
            for (items, 0..) |item, i| if (item == needle) return i;
            return null;
        },
        else => return null,
    }
}

/// The value a missing dictionary key reads as: a null shaped like the first value.
pub fn nullLike(vm: *Vm, values: *Value) Allocator.Error!*Value {
    switch (values.as) {
        .list => |items| return if (items.len == 0) vm.allocValue(.list, 0) else nullOfValue(vm, items[0]),
        inline .boolean_list,
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
        => |_, tag| return vm.createValue(comptime counterpart(tag), try nullOf(vm, tag)),
        else => unreachable,
    }
}

/// The null of a value's own type: `0N` for a long, `""` for a string, `()` for a general
/// list and `::` for anything else.
pub fn nullOfValue(vm: *Vm, value: *Value) Allocator.Error!*Value {
    switch (value.as) {
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
        => |_, tag| return vm.createValue(tag, try nullOf(vm, comptime counterpart(tag))),
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
        => |_, tag| return vm.allocValue(tag, 0),
        else => return vm.getUnaryPrimitive(.identity),
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
        // A long pads a string, as `5$"ab"`, and a short casts by type number, as `5h$1.5`.
        .long => |n| return pad(vm, n, y),
        .short => |n| return castByTypeNumber(vm, n, y),
        else => return error.type,
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

const CastError = Vm.RunError;

/// `n$s` pads the string `s` with spaces to `n` chars or cuts it to fit: `5$"ab"` is
/// `"ab   "`, `-5$"ab"` is `"   ab"` and `-3$"abcdef"` is `"def"`. A list of strings is
/// padded string by string, and `()` counts as an empty string.
fn pad(vm: *Vm, n: i64, y: *Value) CastError!*Value {
    if (n == @backingInt(Value.Long.null)) return error.length;
    switch (y.as) {
        .char_list => |text| return padText(vm, n, text),
        .list => |items| {
            if (items.len == 0) return padText(vm, n, "");
            const results = try vm.gpa.alloc(*Value, items.len);
            defer vm.gpa.free(results);
            var done: usize = 0;
            defer for (results[0..done]) |r| r.deref(vm.gpa);
            for (items) |item| {
                if (item.as != .char_list) return error.type;
                results[done] = try padText(vm, n, item.as.char_list);
                done += 1;
            }
            return vm.enlist(results);
        },
        else => return error.type,
    }
}

fn padText(vm: *Vm, n: i64, text: []const u8) Allocator.Error!*Value {
    const len: usize = @intCast(@abs(n));
    const result = try vm.allocValue(.char_list, len);
    const out = result.as.char_list;
    @memset(out, ' ');
    const copied = @min(len, text.len);
    if (n >= 0) @memcpy(out[0..copied], text[0..copied]) else @memcpy(out[len - copied ..], text[text.len - copied ..]);
    return result;
}

/// `5h$y` casts by q's type number, read off `.Q.t`: `5h$1.5` is `2h` and `10h$1 2` a
/// string. 0 leaves `y` as it is, and a negative number parses text, so `-7h$"12"` is 12.
fn castByTypeNumber(vm: *Vm, n: i16, y: *Value) CastError!*Value {
    const letters = " bg xhijefcspmdznuvts";
    if (n == 0) return y.ref();
    const index = @abs(n);
    if (index >= letters.len) return error.type;
    const letter = letters[index];
    if (letter == ' ' or letter == 'g') return error.type;
    if (n < 0) return parseCast(vm, std.ascii.toUpper(letter), y);
    return castTo(vm, Target.fromLetter(letter).?, y);
}

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
        .composition,
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

/// `x_y` drop and cut, as q does them. An integer atom `x` (a boolean, byte, short, int
/// or long; a null or a float is `type`) drops that many items from the front of a list,
/// or from the back when negative, past the end giving the typed empty; on a dictionary
/// it drops entries. An atom `x` of another type is a key to delete from a dictionary
/// `y` (a missing key changes nothing), and a symbol list deletes several. A list of
/// integer indices `x` cuts a list `y` into the pieces starting at each index
/// (`0 2_"abcd"` is `("ab";"cd")`, `2 2_!4` is `` (`long$();2 3) ``), which must be
/// non-decreasing and within the count (else `domain`); a short list or a general list
/// is `type`. A list `x` with an integer atom `y` deletes the item at that position
/// (`1 2 3_1` is `1 3`, out of range changes nothing), and a dictionary `x` with an atom
/// `y` deletes that key.
pub fn drop(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    if (y.as == .table) return dropTable(vm, x, y);
    switch (x.as) {
        .boolean, .byte, .short, .int, .long => {
            const n: i64 = switch (x.as) {
                .boolean => |b| @intFromBool(b),
                .byte => |b| b,
                .short => |v| if (v == @backingInt(Value.Short.null)) return error.type else v,
                .int => |v| if (v == @backingInt(Value.Int.null)) return error.type else v,
                .long => |v| if (v == @backingInt(Value.Long.null)) return error.type else v,
                else => unreachable,
            };
            if (y.as == .dict) {
                if (n == 0) return error.type;
                const keys = try dropCount(vm, n, y.as.dict.keys);
                errdefer keys.deref(vm.gpa);
                const values = try dropCount(vm, n, y.as.dict.values);
                errdefer values.deref(vm.gpa);
                return vm.createValue(.dict, .{ .keys = keys, .values = values });
            }
            if (!y.isList()) return error.type;
            return dropCount(vm, n, y);
        },
        .list => {
            if (y.isList()) return error.type;
            return deleteAt(vm, x, y);
        },
        .boolean_list, .byte_list, .int_list, .long_list => {
            if (y.isList()) return cut(vm, x, y);
            return deleteAt(vm, x, y);
        },
        .short_list, .real_list, .float_list, .char_list, .timestamp_list, .month_list, .date_list, .datetime_list, .timespan_list, .minute_list, .second_list, .time_list => {
            if (y.isList()) return error.type;
            return deleteAt(vm, x, y);
        },
        .symbol_list => |names| {
            if (y.as != .dict) return error.type;
            var result = y.ref();
            for (names) |name| {
                const key = try vm.createValue(.symbol, name);
                defer key.deref(vm.gpa);
                const next = try deleteKey(vm, result, key);
                result.deref(vm.gpa);
                result = next;
            }
            return result;
        },
        .dict => {
            if (y.isList() or y.as == .dict or Vm.isFunction(y)) return error.type;
            return deleteKey(vm, x, y);
        },
        .real, .float, .char, .symbol, .timestamp, .month, .date, .datetime, .timespan, .minute, .second, .time => {
            if (y.as != .dict) return error.type;
            return deleteKey(vm, y, x);
        },
        else => return error.type,
    }
}

/// `n` items dropped from the front of a list, or from the back for a negative `n`.
fn dropCount(vm: *Vm, n: i64, y: *Value) Vm.RunError!*Value {
    const count: i64 = @intCast(y.count());
    const kept = @max(count - @as(i64, @intCast(@abs(n))), 0);
    return takeItems(vm, y, kept, if (n >= 0) @intCast(@min(n, count)) else 0);
}

/// The dictionary `d` without the entry for `key`, itself when the key is missing.
fn deleteKey(vm: *Vm, d: *Value, key: *Value) Vm.RunError!*Value {
    const entries = d.as.dict;
    const at = (try vm.keyPosition(entries.keys, key)) orelse return d.ref();
    const keys = try withoutItem(vm, entries.keys, at);
    errdefer keys.deref(vm.gpa);
    const values = try withoutItem(vm, entries.values, at);
    errdefer values.deref(vm.gpa);
    return vm.createValue(.dict, .{ .keys = keys, .values = values });
}

/// `x_i`: the list `x` without the item at position `i`, unchanged when `i` is out of range.
fn deleteAt(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    const i: i64 = switch (y.as) {
        .boolean => |b| @intFromBool(b),
        .byte => |b| b,
        .short => |v| v,
        .int => |v| v,
        .long => |v| v,
        else => return error.type,
    };
    if (i < 0 or i >= x.count()) return x.ref();
    return withoutItem(vm, x, @intCast(i));
}

fn withoutItem(vm: *Vm, list: *Value, at: usize) Vm.RunError!*Value {
    const n = list.count();
    const head = try takeItems(vm, list, @intCast(at), 0);
    defer head.deref(vm.gpa);
    const tail = try takeItems(vm, list, @intCast(n - at - 1), at + 1);
    defer tail.deref(vm.gpa);
    return join(vm, head, tail);
}

/// `x_y` with a list of indices: `y` cut into a piece from each index to the next.
fn cut(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    const n = x.count();
    const count: i64 = @intCast(y.count());
    const starts = try vm.gpa.alloc(i64, n);
    defer vm.gpa.free(starts);
    for (starts, 0..) |*start, i| {
        start.* = switch (x.as) {
            .boolean_list => |v| @intFromBool(v[i]),
            .byte_list => |v| v[i],
            .int_list => |v| if (v[i] == @backingInt(Value.Int.null)) return error.domain else v[i],
            .long_list => |v| if (v[i] == @backingInt(Value.Long.null)) return error.domain else v[i],
            else => unreachable,
        };
        if (start.* < 0 or start.* > count or (i > 0 and start.* < starts[i - 1])) return error.domain;
    }
    const pieces = try vm.allocValue(.list, n);
    var filled: usize = 0;
    errdefer {
        for (pieces.as.list[0..filled]) |piece| piece.deref(vm.gpa);
        vm.gpa.free(pieces.as.list);
        vm.gpa.destroy(pieces);
    }
    for (starts, 0..) |start, i| {
        const end = if (i + 1 < n) starts[i + 1] else count;
        pieces.as.list[filled] = try takeItems(vm, y, end - start, @intCast(start));
        filled += 1;
    }
    return pieces;
}

// match is defined with the comparisons below.

pub fn dict(vm: *Vm, x: *Value, y: *Value) !*Value {
    // `n!t` keys a table, `0!kt` unkeys one, and `t1!t2` keys a table by another.
    if (y.as == .table or (y.as == .dict and y.as.dict.keys.as == .table)) {
        if (x.as == .long and x.as.long >= 0) return keyTable(vm, x.as.long, y);
        if (x.as == .table and y.as == .table) {
            if (x.count() != y.count()) return error.length;
            return vm.createValue(.dict, .{ .keys = x.ref(), .values = y.ref() });
        }
        // A negative count is an internal function, handled below.
        if (x.as != .long) return error.type;
    }
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
            .table,
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
            .composition => return error.nyi,
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
                -1 => return hsym(vm, y),
                -2 => return vm.createValue(.symbol, if (y.attr == .none) .empty else try vm.intern(@tagName(y.attr))),
                -3 => return vm.createCharList("{f}", .{y.fmt(vm)}),
                -5 => return vm.parse(y),
                -6 => return vm.eval(y),
                -7 => return q.internal.hcount(vm, y),
                -12 => return q.internal.host(vm, y),
                -13 => return q.internal.addr(vm, y),
                -15 => return digest(vm, std.crypto.hash.Md5, y),
                -20 => return q.internal.gc(vm, y),
                -24 => return vm.eval(y),
                -29 => return q.internal.readJson(vm, y),
                -31 => return q.internal.writeJson(vm, y),
                -32 => return btoa(vm, y),
                -33 => return digest(vm, std.crypto.hash.Sha1, y),
                -34 => return q.internal.ts(vm, y),
                -35 => return q.internal.gzip(vm, y),
                -39 => return q.internal.ld(vm, y),
                // The debugger's `-101!` to `-104!` take the foreign `-100!` makes, so any
                // ordinary argument is a type error, as in q.
                -101, -102, -103, -104 => return error.type,
                -105 => return trap(vm, y),
                else => return error.nyi,
            },
        },
        .float => return error.nyi,
        .char => return error.nyi,
        .symbol => return error.nyi,
        .dict => return error.nyi,
        .table => return error.type,
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
        .composition => return error.nyi,
    }
}

/// `f@x` applies or indexes with one argument: `{x*2}@3` is 6 and `neg@1 2` is `-1 -2`.
pub fn apply_at(vm: *Vm, x: *Value, y: *Value) !*Value {
    var args = [_]*Value{y};
    return vm.applyImpl(x, &args);
}

/// `f . args` applies to the items of a list: `{x+y} . 1 2` is 3, `{x} . enlist 5` is 5.
pub fn apply(vm: *Vm, x: *Value, y: *Value) !*Value {
    if (!y.isList()) {
        var args = [_]*Value{y};
        return vm.applyImpl(x, &args);
    }
    const len = y.count();
    if (len == 0) return error.rank;
    const args = try vm.gpa.alloc(*Value, len);
    defer vm.gpa.free(args);
    var done: usize = 0;
    defer for (args[0..done]) |a| a.deref(vm.gpa);
    for (0..len) |i| {
        args[done] = try itemAt(vm, y, i);
        done += 1;
    }
    return vm.applyImpl(x, args);
}

pub fn file_text(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    return error.nyi;
}

pub fn file_binary(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    return error.nyi;
}

pub fn dynamic_load(vm: *Vm, x: *Value, y: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    _ = y; // autofix
    return error.nyi;
}

// in is defined with the comparisons below.

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

/// `x wsum y`: two lists give the float sum of the products with nulls left out
/// (`wsum[1 2;3 4]` is `11f`), and an atom on either side is `sum x*y` in its own type
/// (`wsum[1;3 4]` is 7).
pub fn wsum(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    if (x.isList() and y.isList()) {
        if (x.count() != y.count()) return error.length;
        var total: f64 = 0;
        for (0..x.count()) |i| {
            const a = try itemAt(vm, x, i);
            defer a.deref(vm.gpa);
            const b = try itemAt(vm, y, i);
            defer b.deref(vm.gpa);
            const fa = try floatOf(a);
            const fb = try floatOf(b);
            if (std.math.isNan(fa) or std.math.isNan(fb)) continue;
            total += fa * fb;
        }
        return vm.createValue(.float, total);
    }
    const products = try multiply(vm, x, y);
    defer products.deref(vm.gpa);
    return q.unary_primitives.sum(vm, products);
}

/// `x wavg y`: `wsum[x;y]` over `sum x`, as a float.
pub fn wavg(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    const weighted = try wsum(vm, x, y);
    defer weighted.deref(vm.gpa);
    const weights = try q.unary_primitives.sum(vm, x);
    defer weights.deref(vm.gpa);
    return divide(vm, weighted, weights);
}

/// A numeric atom as a float for the statistics, nulls as `0n`; symbols and the rest are
/// a type error.
pub fn floatOf(v: *Value) error{type}!f64 {
    return switch (v.as) {
        .boolean => |b| @floatFromInt(@intFromBool(b)),
        .byte => |b| @floatFromInt(b),
        .char => |c| @floatFromInt(c),
        .short => |s| if (s == @backingInt(Value.Short.null)) std.math.nan(f64) else @floatFromInt(s),
        .int, .month, .date, .minute, .second, .time => |i| if (i == @backingInt(Value.Int.null)) std.math.nan(f64) else @floatFromInt(i),
        .long, .timestamp, .timespan => |l| if (l == @backingInt(Value.Long.null)) std.math.nan(f64) else @floatFromInt(l),
        .real => |r| r,
        .float, .datetime => |f| f,
        else => error.type,
    };
}

/// `x div y`: floor division in `x`'s type (booleans, bytes, chars and shorts as ints),
/// so `-7 div 2` is -4 and `7 div 2.5` is 2; division by zero gives the infinity of the
/// sign, nulls stay null.
pub fn div(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    return pairwise(vm, x, y, divAtoms);
}

fn divAtoms(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    if (x.isList() or y.isList()) return div(vm, x, y);
    const a = try floatOf(x);
    const b = try floatOf(y);
    if (x.as == .symbol or y.as == .symbol) return error.type;
    const quotient = if (std.math.isNan(a) or std.math.isNan(b)) std.math.nan(f64) else if (b == 0) (if (a > 0) std.math.inf(f64) else if (a < 0) -std.math.inf(f64) else std.math.nan(f64)) else @floor(a / b);
    const target: Value.Type = switch (x.as) {
        .boolean, .byte, .char, .short, .int => .int,
        .long => .long,
        .real => .real,
        .float => .float,
        inline else => |_, tag| tag,
    };
    // Integer operands divide exactly, floats through the floored quotient.
    if (target == .long and x.as == .long and (y.as == .long or y.as == .int or y.as == .short or y.as == .boolean or y.as == .byte)) {
        const l = x.as.long;
        const r: i64 = switch (y.as) {
            .long => |v| v,
            .int => |v| v,
            .short => |v| v,
            .boolean => |v| @intFromBool(v),
            .byte => |v| v,
            else => unreachable,
        };
        if (l == @backingInt(Value.Long.null) or (y.as != .boolean and y.as != .byte and std.math.isNan(b))) return vm.createValue(.long, @backingInt(Value.Long.null));
        if (r == 0) return vm.createValue(.long, if (l > 0) @backingInt(Value.Long.inf) else if (l < 0) @backingInt(Value.Long.neg_inf) else @backingInt(Value.Long.null));
        return vm.createValue(.long, @divFloor(l, r));
    }
    const value = try vm.createValue(.float, quotient);
    defer value.deref(vm.gpa);
    return castAtom(vm, target, value);
}

/// `x xexp y`: `x` to the power `y` as a float, nulls giving `0n`.
pub fn xexp(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    return pairwise(vm, x, y, xexpAtoms);
}

fn xexpAtoms(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    if (x.isList() or y.isList()) return xexp(vm, x, y);
    if (x.as == .symbol or y.as == .symbol) return error.type;
    const a = try floatOf(x);
    const b = try floatOf(y);
    return vm.createValue(.float, if (std.math.isNan(a) or std.math.isNan(b)) std.math.nan(f64) else std.math.pow(f64, a, b));
}

/// The population covariance of two lists as a float, nulls left out; `cor` is it over
/// the two deviations, `0n` when one is zero.
pub fn cov(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    return vm.createValue(.float, try covariance(vm, x, y));
}

pub fn cor(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    const c = try covariance(vm, x, y);
    const sx = @sqrt(try covariance(vm, x, x));
    const sy = @sqrt(try covariance(vm, y, y));
    return vm.createValue(.float, c / (sx * sy));
}

fn covariance(vm: *Vm, x: *Value, y: *Value) Vm.RunError!f64 {
    if (x.as == .symbol or y.as == .symbol or x.as == .symbol_list or y.as == .symbol_list) return error.type;
    const nx: ?usize = if (x.isList()) x.count() else null;
    const ny: ?usize = if (y.isList()) y.count() else null;
    if (nx != null and ny != null and nx.? != ny.?) return error.length;
    const n = nx orelse ny orelse 1;
    var sum_x: f64 = 0;
    var sum_y: f64 = 0;
    var sum_xy: f64 = 0;
    var count: f64 = 0;
    for (0..n) |i| {
        const a = if (nx != null) try itemAt(vm, x, i) else x.ref();
        defer a.deref(vm.gpa);
        const b = if (ny != null) try itemAt(vm, y, i) else y.ref();
        defer b.deref(vm.gpa);
        const fa = try floatOf(a);
        const fb = try floatOf(b);
        if (std.math.isNan(fa) or std.math.isNan(fb)) continue;
        sum_x += fa;
        sum_y += fb;
        sum_xy += fa * fb;
        count += 1;
    }
    if (count == 0) return std.math.nan(f64);
    return sum_xy / count - (sum_x / count) * (sum_y / count);
}

/// `setenv[x;y]` sets the environment variable named by the symbol `x` to the string `y`
/// and gives `::`; a char atom is a type error, as in q.
pub fn setenv(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    if (x.as != .symbol or y.as != .char_list) return error.type;
    try vm.environ.put(vm.internedString(x.as.symbol), y.as.char_list);
    return vm.getUnaryPrimitive(.identity);
}

// ---------------------------------------------------------------------------------------
// Comparisons, match, min and max, and membership.

/// A comparable atom: nulls of every kind are equal to each other and below everything,
/// integers of every width, chars and booleans compare as numbers, temporal values by
/// their underlying number, and floats and reals as floats.
const Comparable = union(enum) {
    null,
    int: i64,
    float: f64,

    fn of(x: *Value) ?Comparable {
        return switch (x.as) {
            inline .boolean,
            .byte,
            .char,
            .short,
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
            => |v, tag| fromScalar(tag, v),
            else => null,
        };
    }

    /// The comparable of a scalar of atom type `tag`, as stored in the atom or its list.
    fn fromScalar(comptime tag: Value.Type, v: anytype) Comparable {
        return switch (tag) {
            .boolean => .{ .int = @intFromBool(v) },
            .byte, .char => .{ .int = v },
            .short => if (v == @backingInt(Value.Short.null)) .null else .{ .int = v },
            .int, .month, .date, .minute, .second, .time => if (v == @backingInt(Value.Int.null)) .null else .{ .int = v },
            .long, .timestamp, .timespan => if (v == @backingInt(Value.Long.null)) .null else .{ .int = v },
            .real, .float, .datetime => if (std.math.isNan(v)) .null else .{ .float = v },
            else => comptime unreachable,
        };
    }

    fn toFloat(self: Comparable) f64 {
        return switch (self) {
            .null => unreachable,
            .int => |v| @floatFromInt(v),
            .float => |v| v,
        };
    }
};

/// q compares floats to within one part in 2^43.
fn floatsEqual(a: f64, b: f64) bool {
    if (a == b) return true;
    if (std.math.isInf(a) or std.math.isInf(b)) return false;
    const scale = @max(@abs(a), @abs(b));
    return @abs(a - b) <= scale * 0x1p-43;
}

/// The order of two comparable atoms, with q's float tolerance for equality.
fn order(a: Comparable, b: Comparable) std.math.Order {
    if (a == .null or b == .null) {
        if (a == .null and b == .null) return .eq;
        return if (a == .null) .lt else .gt;
    }
    if (a == .int and b == .int) return std.math.order(a.int, b.int);
    const x = a.toFloat();
    const y = b.toFloat();
    if (floatsEqual(x, y)) return .eq;
    return if (x < y) .lt else .gt;
}

const Comparison = enum { eq, lt, gt };

/// `x=y`, `x<y` and `x>y` on atoms: numbers, chars and temporal values by `order`,
/// symbols by name, and anything else, or a symbol against a number, is a type error.
fn compareAtoms(vm: *Vm, x: *Value, y: *Value, comparison: Comparison) Vm.RunError!*Value {
    const o: std.math.Order = if (x.as == .symbol and y.as == .symbol)
        std.mem.order(u8, vm.internedString(x.as.symbol), vm.internedString(y.as.symbol))
    else if (Comparable.of(x)) |a| (if (Comparable.of(y)) |b| order(a, b) else return error.type) else return error.type;
    return vm.createValue(.boolean, switch (comparison) {
        .eq => o == .eq,
        .lt => o == .lt,
        .gt => o == .gt,
    });
}

/// Applies an atom function pairwise over lists, an atom pairing with every item, lists
/// pairing item by item and needing the same length, results unified into a list.
fn pairwise(vm: *Vm, x: *Value, y: *Value, comptime f: fn (*Vm, *Value, *Value) Vm.RunError!*Value) Vm.RunError!*Value {
    // The values of a dictionary or the columns of a table are lists, paired in turn.
    const over_lists = struct {
        fn g(inner_vm: *Vm, a: *Value, b: *Value) Vm.RunError!*Value {
            return pairwise(inner_vm, a, b, f);
        }
    }.g;
    if (try withDicts(vm, x, y, over_lists)) |result| return result;
    if (!x.isList() and !y.isList()) return f(vm, x, y);
    const x_len: ?usize = if (x.isList()) x.count() else null;
    const y_len: ?usize = if (y.isList()) y.count() else null;
    if (x_len != null and y_len != null and x_len.? != y_len.?) return error.length;
    const len = x_len orelse y_len.?;
    if (len == 0) return (if (x_len != null) x else y).ref();
    const results = try vm.gpa.alloc(*Value, len);
    defer vm.gpa.free(results);
    var done: usize = 0;
    defer for (results[0..done]) |r| r.deref(vm.gpa);
    for (0..len) |i| {
        const a = if (x_len != null) try itemAt(vm, x, i) else x.ref();
        defer a.deref(vm.gpa);
        const b = if (y_len != null) try itemAt(vm, y, i) else y.ref();
        defer b.deref(vm.gpa);
        results[done] = try f(vm, a, b);
        done += 1;
    }
    return vm.enlist(results);
}

fn equalAtoms(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    return compareAtoms(vm, x, y, .eq);
}
fn lessAtoms(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    return compareAtoms(vm, x, y, .lt);
}
fn greaterAtoms(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    return compareAtoms(vm, x, y, .gt);
}

pub fn equal(vm: *Vm, x: *Value, y: *Value) !*Value {
    return pairwise(vm, x, y, equalAtoms);
}

pub fn less_than(vm: *Vm, x: *Value, y: *Value) !*Value {
    return pairwise(vm, x, y, lessAtoms);
}

pub fn greater_than(vm: *Vm, x: *Value, y: *Value) !*Value {
    return pairwise(vm, x, y, greaterAtoms);
}

/// `x~y`: the same type and the same items throughout, floats to within the comparison
/// tolerance and nulls matching nulls, so `1~1f` is false and `0n~0n` true.
pub fn match(vm: *Vm, x: *Value, y: *Value) !*Value {
    return vm.createValue(.boolean, try matches(vm, x, y));
}

pub fn matches(vm: *Vm, x: *Value, y: *Value) Allocator.Error!bool {
    if (std.meta.activeTag(x.as) != std.meta.activeTag(y.as)) return false;
    switch (x.as) {
        .float, .real, .datetime => return order(Comparable.of(x).?, Comparable.of(y).?) == .eq,
        .float_list, .real_list, .datetime_list, .list => {
            const n = x.count();
            if (n != y.count()) return false;
            for (0..n) |i| {
                const a = try itemAt(vm, x, i);
                defer a.deref(vm.gpa);
                const b = try itemAt(vm, y, i);
                defer b.deref(vm.gpa);
                if (!try matches(vm, a, b)) return false;
            }
            return true;
        },
        .dict => |d| return try matches(vm, d.keys, y.as.dict.keys) and try matches(vm, d.values, y.as.dict.values),
        else => return x.eql(y),
    }
}

/// `x&y` and `x|y` on atoms: the smaller or larger, kept as it is when both are of one
/// type and otherwise promoted the way arithmetic promotes (`1&2.5` is `1f`); nulls are
/// the smallest. Symbols and functions are a type error.
fn minMaxAtoms(vm: *Vm, x: *Value, y: *Value, comptime want_min: bool) Vm.RunError!*Value {
    if (x.as == .symbol or y.as == .symbol) return error.type;
    const a = Comparable.of(x) orelse return error.type;
    const b = Comparable.of(y) orelse return error.type;
    const pick_x = switch (order(a, b)) {
        .lt => want_min,
        .gt => !want_min,
        .eq => true,
    };
    const chosen = if (pick_x) x else y;
    if (std.meta.activeTag(x.as) == std.meta.activeTag(y.as)) return chosen.ref();
    // Unlike arithmetic, min and max keep the wider of the two types by type number, so
    // `1b|1h` is `1h` and `1b|0x02` is `0x02`.
    if (Numeric.of(x) == null or Numeric.of(y) == null) return error.type;
    const target = try fillType(std.meta.activeTag(x.as), std.meta.activeTag(y.as));
    return castAtom(vm, target, chosen);
}

fn minAtoms(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    return minMaxAtoms(vm, x, y, true);
}
fn maxAtoms(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    return minMaxAtoms(vm, x, y, false);
}

pub fn @"and"(vm: *Vm, x: *Value, y: *Value) !*Value {
    return pairwise(vm, x, y, minAtoms);
}

pub fn @"or"(vm: *Vm, x: *Value, y: *Value) !*Value {
    return pairwise(vm, x, y, maxAtoms);
}

/// `x in y`: whether each item of `x` matches an item of `y`. A typed `x` against a
/// general `y` counts as one item (`"ab" in ("ab";"cd")`), typed lists of different
/// kinds are a type error (`1.0 in 1 2`), and an atom `y` is its own single item.
pub fn in(vm: *Vm, x: *Value, y: *Value) !*Value {
    const y_general = y.as == .list;
    const x_typed_list = x.isList() and x.as != .list;
    if (y.isList() and !y_general) {
        const y_atom: Value.Type = @fromBackingInt(-@backingInt(std.meta.activeTag(y.as)));
        if (x_typed_list and std.meta.activeTag(x.as) != std.meta.activeTag(y.as)) return error.type;
        if (!x.isList() and std.meta.activeTag(x.as) != y_atom) return error.type;
    }
    if (!x.isList() or (x_typed_list and y_general)) return vm.createValue(.boolean, try member(vm, x, y));
    const n = x.count();
    const result = try vm.allocValue(.boolean_list, n);
    errdefer result.deref(vm.gpa);
    for (0..n) |i| {
        const item = try itemAt(vm, x, i);
        defer item.deref(vm.gpa);
        result.as.boolean_list[i] = try member(vm, item, y);
    }
    return result;
}

fn member(vm: *Vm, item: *Value, y: *Value) Allocator.Error!bool {
    if (!y.isList()) return matches(vm, item, y);
    for (0..y.count()) |j| {
        const candidate = try itemAt(vm, y, j);
        defer candidate.deref(vm.gpa);
        if (try matches(vm, item, candidate)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------------------
// Ordering and search: the order grade sorts by, and `?` find, `bin` and `binr`.

/// The class a value sorts in: atoms first, then lists, then dictionaries, then functions.
fn sortClass(v: *Value) u8 {
    if (v.isList()) return 1;
    if (v.as == .dict) return 2;
    if (Vm.isFunction(v)) return 3;
    return 0;
}

/// q's order over any two values, the one grade uses on a general list: atoms come first,
/// by type in the order of the type numbers (booleans, bytes, shorts, ints, longs, reals,
/// floats, chars, symbols, then the temporal types) and within a type by value, nulls
/// lowest, symbols by name and floats to within the comparison tolerance; then lists, by
/// type number with general lists first and then item by item, a prefix sorting before
/// the longer list; then dictionaries and functions, which are all equal to each other.
pub fn compareValues(vm: *Vm, a: *Value, b: *Value) std.math.Order {
    const class_a = sortClass(a);
    const class_b = sortClass(b);
    if (class_a != class_b) return std.math.order(class_a, class_b);
    const type_a = @abs(@backingInt(std.meta.activeTag(a.as)));
    const type_b = @abs(@backingInt(std.meta.activeTag(b.as)));
    if (type_a != type_b) return std.math.order(type_a, type_b);
    switch (class_a) {
        0 => {
            if (a.as == .symbol) return std.mem.order(u8, vm.internedString(a.as.symbol), vm.internedString(b.as.symbol));
            return order(Comparable.of(a).?, Comparable.of(b).?);
        },
        1 => {
            const n = @min(a.count(), b.count());
            for (0..n) |i| {
                const o = compareItems(vm, a, i, b, i);
                if (o != .eq) return o;
            }
            return std.math.order(a.count(), b.count());
        },
        else => return .eq,
    }
}

/// Item `i` of `a` against item `j` of `b`, two lists of the same type, without making atoms.
pub fn compareItems(vm: *Vm, a: *Value, i: usize, b: *Value, j: usize) std.math.Order {
    switch (a.as) {
        .list => |items| return compareValues(vm, items[i], b.as.list[j]),
        .symbol_list => |items| return std.mem.order(u8, vm.internedString(items[i]), vm.internedString(b.as.symbol_list[j])),
        inline .boolean_list,
        .byte_list,
        .short_list,
        .int_list,
        .long_list,
        .real_list,
        .float_list,
        .char_list,
        .timestamp_list,
        .month_list,
        .date_list,
        .datetime_list,
        .timespan_list,
        .minute_list,
        .second_list,
        .time_list,
        => |items, tag| {
            const atom_tag = comptime counterpart(tag);
            return order(Comparable.fromScalar(atom_tag, items[i]), Comparable.fromScalar(atom_tag, @field(b.as, @tagName(tag))[j]));
        },
        else => unreachable,
    }
}

/// Whether item `i` of the typed list `x` is exactly the atom `y` of its type, the way `?`
/// find matches: no float tolerance, but a null finds a null.
fn itemIs(x: *Value, i: usize, y: *Value) bool {
    switch (x.as) {
        inline .boolean_list,
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
            const item = items[i];
            const needle = @field(y.as, @tagName(counterpart(tag)));
            return switch (@TypeOf(item)) {
                f32, f64 => item == needle or (std.math.isNan(item) and std.math.isNan(needle)),
                else => item == needle,
            };
        },
        else => unreachable,
    }
}

/// Applies a search to every item of `y`, unifying the results.
fn searchEach(vm: *Vm, x: *Value, y: *Value, comptime f: fn (*Vm, *Value, *Value) Vm.RunError!*Value) Vm.RunError!*Value {
    const n = y.count();
    if (n == 0) return vm.allocValue(.long_list, 0);
    const results = try vm.gpa.alloc(*Value, n);
    defer vm.gpa.free(results);
    var done: usize = 0;
    defer for (results[0..done]) |r| r.deref(vm.gpa);
    for (0..n) |i| {
        const item = try itemAt(vm, y, i);
        defer item.deref(vm.gpa);
        results[done] = try f(vm, x, item);
        done += 1;
    }
    return vm.enlist(results);
}

const SearchMode = enum { one, each, enlisted };

/// How `?` and `bin` read the right side against a general list `x`, which q decides by
/// the first item of `x`: after an atom, an atom is one key and any list is searched item
/// by item (`(1;2)?1 2` is `0 1`); after a list, a typed list is one key (`(1 2;3 4)?3 4`
/// is 1), a general list is searched item by item only when its own first item has the
/// type of `x`'s (`(1 2;3)?(1 2;3)` is `0 1` but `(1 2;3)?(3;1 2)` is 2), and an atom
/// given at the top level is enlisted first, so `(1 2;3)?3` is 2 and `(1 2;3 4) bin 3` is
/// 0. Within an item-by-item search an atom is one key.
fn searchMode(x: *Value, y: *Value, top: bool) SearchMode {
    const items = x.as.list;
    const head_is_list = items.len > 0 and items[0].isList();
    if (!head_is_list) return if (y.isList()) .each else .one;
    if (!y.isList()) return if (top) .enlisted else .one;
    if (y.as != .list) return .one;
    const same = y.as.list.len > 0 and std.meta.activeTag(y.as.list[0].as) == std.meta.activeTag(items[0].as);
    return if (same) .each else .one;
}

/// `x?y` finds the first position of `y` in `x`, or the count when it is missing: exact
/// matches (`1.0 2?1+1e-14` is 2), a null finding a null, an atom against a typed list
/// needing the list's own type, items of a general list by `~`. A list `y` is searched item
/// by item, except against a general list of lists, where `searchMode` decides. On a
/// dictionary the search runs over the values and returns the key (a null key when
/// missing). Roll and deal, `n?x` with an atom `x`, are not done.
pub fn find(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    return findImpl(vm, x, y, true);
}

fn findItem(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    return findImpl(vm, x, y, false);
}

fn findAtom(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    if (y.isList()) return error.type;
    return findImpl(vm, x, y, false);
}

/// Whether a general list on the right of a search against a typed list is flat, which q
/// decides by its first item: after an atom every item must be an atom (`1 2 3?(2;1 3)` is
/// a type error), after a list each item is searched on its own (`1 2?(1 2;3)` is
/// `(0 1;2)`).
fn flatSearch(y: *Value) bool {
    const items = y.as.list;
    return items.len > 0 and !items[0].isList();
}

fn findImpl(vm: *Vm, x: *Value, y: *Value, top: bool) Vm.RunError!*Value {
    switch (x.as) {
        .dict => |d| {
            const index = try findImpl(vm, d.values, y, top);
            defer index.deref(vm.gpa);
            var args = [_]*Value{index};
            return vm.applyImpl(d.keys, &args);
        },
        .list => |items| {
            const key = switch (searchMode(x, y, top)) {
                .each => return searchEach(vm, x, y, findItem),
                .one => y.ref(),
                .enlisted => try q.unary_primitives.enlist(vm, y),
            };
            defer key.deref(vm.gpa);
            for (items, 0..) |item, i| if (try matches(vm, item, key)) return vm.createValue(.long, @intCast(i));
            return vm.createValue(.long, @intCast(items.len));
        },
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
        => {
            if (y.isList()) {
                if (y.as != .list and std.meta.activeTag(y.as) != std.meta.activeTag(x.as)) return error.type;
                if (y.as == .list and flatSearch(y)) return searchEach(vm, x, y, findAtom);
                return searchEach(vm, x, y, findItem);
            }
            if (@backingInt(std.meta.activeTag(y.as)) != -@backingInt(std.meta.activeTag(x.as))) return error.type;
            const n = x.count();
            for (0..n) |i| if (itemIs(x, i, y)) return vm.createValue(.long, @intCast(i));
            return vm.createValue(.long, @intCast(n));
        },
        else => return roll(vm, x, y),
    }
}

/// `x bin y`: the position of the last item of the sorted list `x` at or below `y`, -1 when
/// there is none; `x binr y` the position of the first item at or above `y`, the count when
/// there is none. Nulls sit below everything, so `1 3 5 bin 0N` is -1 and `1 3 5 binr 0N`
/// is 0. The types follow `?` find: an atom against a typed list needs its type, a list `y`
/// is searched item by item or as one key by `searchMode`, and a dictionary is searched by
/// value and answers with the key.
pub fn bin(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    return binarySearch(vm, x, y, false, true);
}

pub fn binr(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    return binarySearch(vm, x, y, true, true);
}

fn binItem(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    return binarySearch(vm, x, y, false, false);
}

fn binrItem(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    return binarySearch(vm, x, y, true, false);
}

fn binarySearch(vm: *Vm, x: *Value, y: *Value, comptime right: bool, top: bool) Vm.RunError!*Value {
    const each = if (right) binrItem else binItem;
    var key = y.ref();
    defer key.deref(vm.gpa);
    switch (x.as) {
        .dict => |d| {
            const index = try binarySearch(vm, d.values, y, right, top);
            defer index.deref(vm.gpa);
            var args = [_]*Value{index};
            return vm.applyImpl(d.keys, &args);
        },
        .list => switch (searchMode(x, y, top)) {
            .each => return searchEach(vm, x, y, each),
            .one => {},
            .enlisted => {
                key.deref(vm.gpa);
                key = try q.unary_primitives.enlist(vm, y);
            },
        },
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
        => {
            if (y.isList()) {
                if (y.as != .list and std.meta.activeTag(y.as) != std.meta.activeTag(x.as)) return error.type;
                if (y.as == .list and flatSearch(y)) for (y.as.list) |item| if (item.isList()) return error.type;
                return searchEach(vm, x, y, each);
            }
            if (@backingInt(std.meta.activeTag(y.as)) != -@backingInt(std.meta.activeTag(x.as))) return error.type;
        },
        else => return error.type,
    }
    // The count of items below the key (binr) or at or below it (bin), by bisection.
    var low: usize = 0;
    var high: usize = x.count();
    while (low < high) {
        const mid = low + (high - low) / 2;
        const o = if (x.as == .list) compareValues(vm, x.as.list[mid], key) else compareAtomToItem(vm, x, mid, key);
        const below = if (right) o == .lt else o != .gt;
        if (below) low = mid + 1 else high = mid;
    }
    const position: i64 = if (right) @intCast(low) else @as(i64, @intCast(low)) - 1;
    return vm.createValue(.long, position);
}

/// Item `i` of the typed list `x` against the atom `y` of its type.
fn compareAtomToItem(vm: *Vm, x: *Value, i: usize, y: *Value) std.math.Order {
    switch (x.as) {
        .symbol_list => |items| return std.mem.order(u8, vm.internedString(items[i]), vm.internedString(y.as.symbol)),
        inline .boolean_list,
        .byte_list,
        .short_list,
        .int_list,
        .long_list,
        .real_list,
        .float_list,
        .char_list,
        .timestamp_list,
        .month_list,
        .date_list,
        .datetime_list,
        .timespan_list,
        .minute_list,
        .second_list,
        .time_list,
        => |items, tag| return order(Comparable.fromScalar(comptime counterpart(tag), items[i]), Comparable.of(y).?),
        else => unreachable,
    }
}

// ---------------------------------------------------------------------------------------
// `sv` and `vs`: data on the left of `/:` and `\:`.

/// A string value holding `bytes`.
fn textValue(vm: *Vm, bytes: []const u8) Allocator.Error!*Value {
    const v = try vm.allocValue(.char_list, bytes.len);
    errdefer comptime unreachable;
    @memcpy(v.as.char_list, bytes);
    return v;
}

/// The digits `0x40\:` and `0x24\:` write: base 64 in 10 bytes and base 36 in 12, the
/// most a long holds below 2^63; other bytes are `nyi` in q too.
fn digitWidth(base: u8) ?usize {
    return switch (base) {
        0x40 => 10,
        0x24 => 12,
        else => null,
    };
}

/// `x/:y`, `sv`: a string or char `x` joins a list of strings with it (`" "/:("ab";"cd")`
/// is `"ab cd"`, `()` gives `""`); `` ` `` joins symbols with dots (`` `/:`a`b `` is
/// `` `a.b ``) or strings as lines, each ending in a newline; `0x00` reads 8, 4 or 2 bytes
/// as a big-endian long, int or short, and `0x40` or `0x24` reads the digits `vs` wrote; a
/// number or a list of numbers is a base or mixed radix (`10/:1 2 3` is 123, `0 24 60 60/:1
/// 1 1 1` is 90061), applied down the columns of a list of lists.
pub fn sv(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    switch (x.as) {
        .char, .char_list => {
            const separator: []const u8 = if (x.as == .char) &.{x.as.char} else x.as.char_list;
            if (y.as != .list) return error.type;
            const items = y.as.list;
            var total: usize = 0;
            for (items, 0..) |item, i| {
                if (item.as != .char_list) return error.type;
                total += item.as.char_list.len + (if (i > 0) separator.len else 0);
            }
            const result = try vm.allocValue(.char_list, total);
            errdefer comptime unreachable;
            var filled: usize = 0;
            for (items, 0..) |item, i| {
                if (i > 0) {
                    @memcpy(result.as.char_list[filled .. filled + separator.len], separator);
                    filled += separator.len;
                }
                @memcpy(result.as.char_list[filled .. filled + item.as.char_list.len], item.as.char_list);
                filled += item.as.char_list.len;
            }
            return result;
        },
        .symbol => |s| {
            if (s != .empty) return error.nyi;
            switch (y.as) {
                .symbol_list => |names| {
                    if (names.len == 0) return error.type;
                    var buffer: std.ArrayList(u8) = .empty;
                    defer buffer.deinit(vm.gpa);
                    for (names, 0..) |name, i| {
                        if (i > 0) try buffer.append(vm.gpa, '.');
                        try buffer.appendSlice(vm.gpa, vm.internedString(name));
                    }
                    return vm.createValue(.symbol, try vm.intern(buffer.items));
                },
                .list => |items| {
                    var total: usize = 0;
                    for (items) |item| {
                        if (item.as != .char_list) return error.type;
                        total += item.as.char_list.len + 1;
                    }
                    const result = try vm.allocValue(.char_list, total);
                    errdefer comptime unreachable;
                    var filled: usize = 0;
                    for (items) |item| {
                        @memcpy(result.as.char_list[filled .. filled + item.as.char_list.len], item.as.char_list);
                        filled += item.as.char_list.len;
                        result.as.char_list[filled] = '\n';
                        filled += 1;
                    }
                    return result;
                },
                else => return error.type,
            }
        },
        .byte => |base| {
            if (y.as != .byte_list) return error.type;
            const bytes = y.as.byte_list;
            if (base == 0) {
                return switch (bytes.len) {
                    8 => vm.createValue(.long, std.mem.readInt(i64, bytes[0..8], .big)),
                    4 => vm.createValue(.int, std.mem.readInt(i32, bytes[0..4], .big)),
                    2 => vm.createValue(.short, std.mem.readInt(i16, bytes[0..2], .big)),
                    else => error.length,
                };
            }
            const width = digitWidth(base) orelse return error.nyi;
            if (bytes.len != width) return error.length;
            var acc: u64 = 0;
            for (bytes) |digit| acc = acc *% base +% digit;
            return vm.createValue(.long, @bitCast(acc));
        },
        .short, .int, .long, .short_list, .int_list, .long_list => return radixJoin(vm, x, y),
        else => return error.type,
    }
}

/// The bases of a radix, from an atom (repeated) or a list.
fn baseAt(x: *Value, i: usize) i64 {
    return switch (x.as) {
        .short => |v| v,
        .int => |v| v,
        .long => |v| v,
        .short_list => |v| v[i],
        .int_list => |v| v[i],
        .long_list => |v| v[i],
        else => unreachable,
    };
}

/// `x/:y` for a numeric base: digits fold from the most significant, `acc*base+digit`, the
/// base at each position coming from a radix list. Integer digits give a long and float
/// digits a float; a list of lists is folded column by column.
fn radixJoin(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    switch (y.as) {
        .list => |rows| {
            if (rows.len == 0) return error.nyi;
            var width: usize = 0;
            for (rows) |row| if (row.isList()) {
                width = @max(width, row.count());
            };
            const results = try vm.gpa.alloc(*Value, width);
            defer vm.gpa.free(results);
            var done: usize = 0;
            defer for (results[0..done]) |r| r.deref(vm.gpa);
            for (0..width) |j| {
                const column = try vm.gpa.alloc(*Value, rows.len);
                defer vm.gpa.free(column);
                var got: usize = 0;
                defer for (column[0..got]) |c| c.deref(vm.gpa);
                for (rows) |row| {
                    column[got] = if (row.isList()) try itemAt(vm, row, j) else row.ref();
                    got += 1;
                }
                const digits = try vm.enlist(column);
                defer digits.deref(vm.gpa);
                results[done] = try radixJoin(vm, x, digits);
                done += 1;
            }
            return vm.enlist(results);
        },
        .boolean_list, .short_list, .int_list, .long_list, .real_list, .float_list => {},
        else => return error.type,
    }
    const n = y.count();
    if (x.isList() and x.count() != n) return error.length;
    const is_float = y.as == .real_list or y.as == .float_list;
    if (is_float) {
        var acc: f64 = 0;
        for (0..n) |i| {
            const digit: f64 = switch (y.as) {
                .real_list => |v| v[i],
                .float_list => |v| v[i],
                else => unreachable,
            };
            acc = acc * @as(f64, @floatFromInt(baseAt(x, i))) + digit;
        }
        return vm.createValue(.float, acc);
    }
    var acc: i64 = 0;
    for (0..n) |i| {
        const digit: i64 = switch (y.as) {
            .boolean_list => |v| @intFromBool(v[i]),
            .short_list => |v| v[i],
            .int_list => |v| v[i],
            .long_list => |v| v[i],
            else => unreachable,
        };
        acc = acc *% baseAt(x, i) +% digit;
    }
    return vm.createValue(.long, acc);
}

/// `x\:y`, `vs`: a string or char `x` splits a string at it (`" "\:"a b"` is `(,"a";,"b")`,
/// empty pieces kept); `` ` `` splits a symbol at its dots (`` `\:`a.b `` is `` `a`b ``) or
/// a string into lines, dropping `\r` and a final empty line; `0x00` gives the big-endian
/// bytes of a number and `0x40` or `0x24` its ten base-64 or twelve base-36 digits; a
/// number or a list of numbers is a base or mixed radix giving the digits of an integer,
/// most significant first (`10\:123` is `1 2 3`, `2 4\:10` is `0 2`), or of each item of a
/// list as rows of digits (`10\:12 345` is `(0 3;1 4;2 5)`).
pub fn vs(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    switch (x.as) {
        .char, .char_list => {
            const separator: []const u8 = if (x.as == .char) &.{x.as.char} else x.as.char_list;
            if (separator.len == 0) return error.length;
            if (y.as != .char_list) return error.type;
            return splitText(vm, y.as.char_list, separator);
        },
        .symbol => |s| {
            if (s != .empty) return error.nyi;
            switch (y.as) {
                .symbol => |name| {
                    const text = vm.internedString(name);
                    var count: usize = 1;
                    for (text) |c| count += @intFromBool(c == '.');
                    const result = try vm.allocValue(.symbol_list, count);
                    errdefer result.deref(vm.gpa);
                    var it = std.mem.splitScalar(u8, text, '.');
                    var i: usize = 0;
                    while (it.next()) |part| : (i += 1) result.as.symbol_list[i] = try vm.intern(part);
                    return result;
                },
                .char_list => |text| {
                    var lines: std.ArrayList(*Value) = .empty;
                    defer lines.deinit(vm.gpa);
                    defer for (lines.items) |line| line.deref(vm.gpa);
                    var it = std.mem.splitScalar(u8, text, '\n');
                    while (it.next()) |line| {
                        if (it.peek() == null and line.len == 0) break;
                        const trimmed = if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
                        try lines.append(vm.gpa, try textValue(vm, trimmed));
                    }
                    if (lines.items.len == 0) return vm.allocValue(.list, 0);
                    return vm.enlist(lines.items);
                },
                else => return error.type,
            }
        },
        .byte => |base| {
            if (base == 0) {
                var buffer: [8]u8 = undefined;
                const len: usize = switch (y.as) {
                    .short => |v| blk: {
                        std.mem.writeInt(i16, buffer[0..2], v, .big);
                        break :blk 2;
                    },
                    .int => |v| blk: {
                        std.mem.writeInt(i32, buffer[0..4], v, .big);
                        break :blk 4;
                    },
                    .long => |v| blk: {
                        std.mem.writeInt(i64, buffer[0..8], v, .big);
                        break :blk 8;
                    },
                    .real => |v| blk: {
                        std.mem.writeInt(u32, buffer[0..4], @bitCast(v), .big);
                        break :blk 4;
                    },
                    .float => |v| blk: {
                        std.mem.writeInt(u64, buffer[0..8], @bitCast(v), .big);
                        break :blk 8;
                    },
                    .char => |c| blk: {
                        buffer[0] = c;
                        break :blk 1;
                    },
                    else => return error.type,
                };
                const bytes = buffer[0..len];
                const result = try vm.allocValue(.byte_list, bytes.len);
                errdefer comptime unreachable;
                @memcpy(result.as.byte_list, bytes);
                return result;
            }
            const width = digitWidth(base) orelse return error.nyi;
            if (y.as != .long) return error.nyi;
            if (y.as.long == @backingInt(Value.Long.null)) return vm.allocValue(.byte_list, 0);
            const result = try vm.allocValue(.byte_list, width);
            errdefer comptime unreachable;
            var v: u64 = @bitCast(y.as.long);
            var i: usize = width;
            while (i > 0) {
                i -= 1;
                result.as.byte_list[i] = @intCast(v % base);
                v /= base;
            }
            return result;
        },
        .short, .int, .long, .short_list, .int_list, .long_list => return radixSplit(vm, x, y),
        else => return error.type,
    }
}

/// `text` cut at every `separator`, empty pieces kept, as a list of strings.
fn splitText(vm: *Vm, text: []const u8, separator: []const u8) Vm.RunError!*Value {
    var pieces: std.ArrayList(*Value) = .empty;
    defer pieces.deinit(vm.gpa);
    defer for (pieces.items) |piece| piece.deref(vm.gpa);
    var it = std.mem.splitSequence(u8, text, separator);
    while (it.next()) |piece| try pieces.append(vm.gpa, try textValue(vm, piece));
    return vm.enlist(pieces.items);
}

/// The value of an integer atom for a radix, null for a null.
fn integerOf(y: *Value) error{type}!?i64 {
    return switch (y.as) {
        .boolean => |b| @intFromBool(b),
        .short => |v| if (v == @backingInt(Value.Short.null)) null else v,
        .int => |v| if (v == @backingInt(Value.Int.null)) null else v,
        .long => |v| if (v == @backingInt(Value.Long.null)) null else v,
        else => error.type,
    };
}

/// The digits of `value` in the radix `x`, least significant first, into `digits`: a
/// single base gives as many digits as a positive value needs (none for zero, a null or a
/// negative), a radix list one per base from the last, a base of zero or a null taking
/// a null digit.
fn radixDigits(vm: *Vm, x: *Value, value: ?i64, digits: *std.ArrayList(i64)) Allocator.Error!void {
    if (x.isList()) {
        var v = value;
        var i = x.count();
        while (i > 0) {
            i -= 1;
            const base = baseAt(x, i);
            if (base <= 0 or v == null) {
                try digits.append(vm.gpa, @backingInt(Value.Long.null));
                continue;
            }
            try digits.append(vm.gpa, @mod(v.?, base));
            v = @divFloor(v.?, base);
        }
        return;
    }
    const base = baseAt(x, 0);
    if (base <= 0) return;
    var v = value orelse return;
    while (v > 0) : (v = @divTrunc(v, base)) try digits.append(vm.gpa, @mod(v, base));
}

/// Digit `place` (0 for the units) of `value` in a single base, a null for a null and the
/// modulo digit for a negative, which is how the rows of `10\:-1 5` come out as `,9 5`.
fn digitAt(base: i64, value: ?i64, place: usize) i64 {
    var v = value orelse return @backingInt(Value.Long.null);
    for (0..place) |_| v = @divFloor(v, base);
    return @mod(v, base);
}

/// `x\:y` for a numeric radix: the digits of an integer, or the rows of digits of a list
/// of integers padded to the widest with zeros.
fn radixSplit(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    var digits: std.ArrayList(i64) = .empty;
    defer digits.deinit(vm.gpa);
    if (!y.isList()) {
        try radixDigits(vm, x, try integerOf(y), &digits);
        const result = try vm.allocValue(.long_list, digits.items.len);
        errdefer comptime unreachable;
        for (result.as.long_list, 0..) |*r, i| r.* = digits.items[digits.items.len - 1 - i];
        return result;
    }
    switch (y.as) {
        .boolean_list, .short_list, .int_list, .long_list => {},
        else => return error.type,
    }
    const n = y.count();
    const values = try vm.gpa.alloc(?i64, n);
    defer vm.gpa.free(values);
    const columns = try vm.gpa.alloc([]i64, n);
    defer vm.gpa.free(columns);
    var made: usize = 0;
    defer for (columns[0..made]) |c| vm.gpa.free(c);
    // The rows are as many as the widest item needs, at least one; with a single base a
    // negative or null item fills its column with modulo or null digits.
    var width: usize = 1;
    for (0..n) |i| {
        const item = try itemAt(vm, y, i);
        defer item.deref(vm.gpa);
        values[i] = try integerOf(item);
        digits.clearRetainingCapacity();
        try radixDigits(vm, x, values[i], &digits);
        columns[made] = try vm.gpa.dupe(i64, digits.items);
        made += 1;
        width = @max(width, digits.items.len);
    }
    const rows = try vm.allocValue(.list, width);
    var filled: usize = 0;
    errdefer {
        for (rows.as.list[0..filled]) |r| r.deref(vm.gpa);
        vm.gpa.free(rows.as.list);
        vm.gpa.destroy(rows);
    }
    for (0..width) |r| {
        const row = try vm.allocValue(.long_list, n);
        const place = width - 1 - r;
        for (row.as.long_list, columns, values) |*cell, column, value| {
            cell.* = if (x.isList())
                (if (place < column.len) column[place] else 0)
            else
                digitAt(baseAt(x, 0), value, place);
        }
        rows.as.list[filled] = row;
        filled += 1;
    }
    return rows;
}

// ---------------------------------------------------------------------------------------
// Attributes, the vector conditional, roll and deal, and the internal functions.

/// `` `s#y ``, `` `u#y ``, `` `p#y `` and `` `g#y `` set an attribute on a list, and
/// `` `#y `` clears it. Sorted needs the items non-decreasing in q's order (nulls first),
/// else `s-fail`; unique needs them distinct and parted needs equal items contiguous,
/// else `u-fail`; grouped checks nothing. As in q, sorted, parted and grouped are set on
/// the value itself, so a variable holding it sees the attribute, while unique makes a
/// copy. A dictionary takes only `s`, on itself and its keys; an atom is a type error.
fn setAttribute(vm: *Vm, name: Symbol, y: *Value) Vm.RunError!*Value {
    const text = vm.internedString(name);
    const attr: Value.Attr = if (text.len == 0) .none else if (text.len == 1) switch (text[0]) {
        's' => .s,
        'u' => .u,
        'p' => .p,
        'g' => .g,
        else => return error.type,
    } else return error.type;
    if (y.as == .dict) {
        if (attr != .s and attr != .none) return error.type;
        const keys = y.as.dict.keys;
        if (attr == .s and !try isSorted(vm, keys)) return vm.failWith("s-fail");
        keys.attr = attr;
        y.attr = attr;
        return y.ref();
    }
    if (!y.isList()) return error.type;
    switch (attr) {
        .none, .g => {},
        .s => if (!try isSorted(vm, y)) return vm.failWith("s-fail"),
        .u, .p => {
            const n = y.count();
            for (0..n) |i| {
                // Parted allows a repeat only right after itself; unique allows none.
                if (attr == .p and i > 0 and try sameItemOf(vm, y, i, i - 1)) continue;
                for (0..i) |j| if (try sameItemOf(vm, y, i, j)) return vm.failWith("u-fail");
            }
        },
    }
    // Unique makes a copy, and so does an empty list, which is a shared constant here.
    if (attr == .u or y.count() == 0) {
        const copy = try takeItems(vm, y, @intCast(y.count()), 0);
        copy.attr = attr;
        return copy;
    }
    y.attr = attr;
    return y.ref();
}

fn isSorted(vm: *Vm, list: *Value) Allocator.Error!bool {
    const n = list.count();
    if (n < 2) return true;
    for (0..n - 1) |i| if (compareItems(vm, list, i, list, i + 1) == .gt) return false;
    return true;
}

fn sameItemOf(vm: *Vm, x: *Value, i: usize, j: usize) Allocator.Error!bool {
    if (x.as == .list) return matches(vm, x.as.list[i], x.as.list[j]);
    return compareItems(vm, x, i, x, j) == .eq;
}

/// `?[c;a;b]`: for a boolean list `c`, the items of `a` where it is true and of `b`
/// elsewhere, atoms spread and lists of `c`'s length (else `length`), the picks unified
/// with numbers promoted (`?[101b;1 2 3;4 5 6f]` is `1 5 3f`) and a symbol among numbers
/// a type error; a boolean atom picks `a` or `b` whole.
pub fn vectorConditional(vm: *Vm, c: *Value, a: *Value, b: *Value) Vm.RunError!*Value {
    switch (c.as) {
        .boolean => |pick| return (if (pick) a else b).ref(),
        .boolean_list => {},
        else => return error.type,
    }
    const n = c.count();
    for ([_]*Value{ a, b }) |side| if (side.isList() and side.count() != n) return error.length;
    if (n == 0) return vm.allocValue(.list, 0);
    const picks = try vm.gpa.alloc(*Value, n);
    defer vm.gpa.free(picks);
    var done: usize = 0;
    defer for (picks[0..done]) |p| p.deref(vm.gpa);
    for (c.as.boolean_list, 0..) |pick, i| {
        const side = if (pick) a else b;
        picks[done] = if (side.isList()) try itemAt(vm, side, i) else side.ref();
        done += 1;
    }
    const result = try vm.enlist(picks);
    if (result.as != .list) return result;
    // Atoms of different numeric types promote to one type.
    for (picks) |p| if (p.isList() or p.as == .dict or Vm.isFunction(p)) return result;
    errdefer result.deref(vm.gpa);
    var target = std.meta.activeTag(picks[0].as);
    for (picks[1..]) |p| target = try fillType(target, std.meta.activeTag(p.as));
    const promoted = try vm.gpa.alloc(*Value, n);
    defer vm.gpa.free(promoted);
    var made: usize = 0;
    defer for (promoted[0..made]) |p| p.deref(vm.gpa);
    for (picks) |p| {
        promoted[made] = try castAtom(vm, target, p);
        made += 1;
    }
    result.deref(vm.gpa);
    return vm.enlist(promoted);
}

/// `n?x` roll and `-n?x` deal. An integer `n` draws `n` items: from a list, positions
/// with replacement, or without for a negative `n` (`length` past the count); from an
/// integer, float or temporal atom, values below it of its type (`0` draws from the whole
/// long range, a negative or null is `domain`); from a boolean, booleans; from a byte,
/// bytes; from a symbol `` `k ``, symbols of `k` lower-case letters. A null `n` with an
/// integer `x` is a permutation of `til x`. The generator is seeded by `\\S` but is not
/// q's, so the values differ from q's for the same seed.
fn roll(vm: *Vm, n_value: *Value, x: *Value) Vm.RunError!*Value {
    const n_raw: ?i64 = switch (n_value.as) {
        .short => |v| if (v == @backingInt(Value.Short.null)) null else v,
        .int => |v| if (v == @backingInt(Value.Int.null)) null else v,
        .long => |v| if (v == @backingInt(Value.Long.null)) null else v,
        else => return error.type,
    };
    const random = vm.random.random();
    if (n_raw == null) {
        const count: i64 = switch (x.as) {
            .short => |v| v,
            .int => |v| v,
            .long => |v| v,
            else => return error.type,
        };
        if (count < 0) return error.domain;
        return permutation(vm, random, @intCast(count), @intCast(count));
    }
    const deal = n_raw.? < 0;
    const n: usize = @intCast(@abs(n_raw.?));
    if (x.isList()) {
        const count = x.count();
        if (x.as == .list and count == 0) {
            const empties = try vm.allocValue(.list, n);
            errdefer comptime unreachable;
            for (empties.as.list) |*e| e.* = vm.getConstant(.empty_list);
            return empties;
        }
        if (count == 0) return error.length;
        if (deal and n > count) return error.length;
        const positions = if (deal) try permutation(vm, random, count, n) else blk: {
            const p = try vm.allocValue(.long_list, n);
            for (p.as.long_list) |*i| i.* = @intCast(random.uintLessThan(usize, count));
            break :blk p;
        };
        defer positions.deref(vm.gpa);
        var args = [_]*Value{positions};
        return vm.indexList(x, &args);
    }
    switch (x.as) {
        .symbol => |s| {
            const text = vm.internedString(s);
            const letters: usize = if (text.len == 1 and text[0] >= '1' and text[0] <= '8') text[0] - '0' else if (text.len == 1 and text[0] == '0') return error.domain else return vm.failWith(text);
            const result = try vm.allocValue(.symbol_list, n);
            errdefer result.deref(vm.gpa);
            var buffer: [8]u8 = undefined;
            for (result.as.symbol_list) |*item| {
                for (buffer[0..letters]) |*c| c.* = 'a' + random.uintLessThan(u8, 26);
                item.* = try vm.intern(buffer[0..letters]);
            }
            return result;
        },
        .boolean => {
            const result = try vm.allocValue(.boolean_list, n);
            for (result.as.boolean_list) |*b| b.* = random.boolean();
            return result;
        },
        .byte => |limit| {
            const result = try vm.allocValue(.byte_list, n);
            for (result.as.byte_list) |*b| b.* = if (limit == 0) random.int(u8) else random.uintLessThan(u8, limit);
            return result;
        },
        inline .real, .float => |limit, tag| {
            if (deal) return error.type;
            if (!(limit > 0)) return error.domain;
            const list_tag = comptime counterpart(tag);
            const result = try vm.allocValue(list_tag, n);
            for (@field(result.as, @tagName(list_tag))) |*f| f.* = random.float(@TypeOf(limit)) * limit;
            return result;
        },
        inline .short, .int, .long, .timestamp, .month, .date, .timespan, .minute, .second, .time => |limit, tag| {
            const T = @TypeOf(limit);
            if (limit == std.math.minInt(T) or limit < 0) return error.domain;
            if (deal) {
                if (n > limit) return error.length;
                const p = try permutation(vm, random, @intCast(limit), n);
                defer p.deref(vm.gpa);
                const list_tag = comptime counterpart(tag);
                const result = try vm.allocValue(list_tag, n);
                for (@field(result.as, @tagName(list_tag)), p.as.long_list) |*item, i| item.* = @intCast(i);
                return result;
            }
            const list_tag = comptime counterpart(tag);
            const result = try vm.allocValue(list_tag, n);
            for (@field(result.as, @tagName(list_tag))) |*item| {
                item.* = if (limit == 0) random.int(T) else @intCast(random.uintLessThan(u64, @intCast(limit)));
            }
            return result;
        },
        .datetime => |limit| {
            if (deal) return error.type;
            if (!(limit > 0)) return error.domain;
            const result = try vm.allocValue(.datetime_list, n);
            for (result.as.datetime_list) |*f| f.* = random.float(f64) * limit;
            return result;
        },
        else => return error.type,
    }
}

/// The first `n` positions of a random permutation of `til count`.
fn permutation(vm: *Vm, random: std.Random, count: usize, n: usize) Allocator.Error!*Value {
    const all = try vm.gpa.alloc(i64, count);
    defer vm.gpa.free(all);
    for (all, 0..) |*v, i| v.* = @intCast(i);
    random.shuffle(i64, all);
    const result = try vm.allocValue(.long_list, n);
    errdefer comptime unreachable;
    @memcpy(result.as.long_list, all[0..n]);
    return result;
}

/// `-1!x` hsym: a symbol made a file symbol by a leading colon, unless it has one already
/// or is empty.
fn hsym(vm: *Vm, y: *Value) Vm.RunError!*Value {
    if (y.as != .symbol) return error.type;
    const text = vm.internedString(y.as.symbol);
    if (text.len == 0 or text[0] == ':') return y.ref();
    const name = try std.mem.concat(vm.gpa, u8, &.{ ":", text });
    defer vm.gpa.free(name);
    return vm.createValue(.symbol, try vm.intern(name));
}

/// `-15!x` md5 and `-33!x` sha1 of a string, as bytes.
fn digest(vm: *Vm, comptime Hash: type, y: *Value) Vm.RunError!*Value {
    if (y.as != .char_list) return error.type;
    const result = try vm.allocValue(.byte_list, Hash.digest_length);
    errdefer comptime unreachable;
    Hash.hash(y.as.char_list, result.as.byte_list[0..Hash.digest_length], .{});
    return result;
}

/// `-32!x` btoa: the base64 text of a string or byte list.
fn btoa(vm: *Vm, y: *Value) Vm.RunError!*Value {
    const bytes: []const u8 = switch (y.as) {
        .char_list => |s| s,
        .byte_list => |b| b,
        else => return error.type,
    };
    const encoder = std.base64.standard.Encoder;
    const result = try vm.allocValue(.char_list, encoder.calcSize(bytes.len));
    errdefer comptime unreachable;
    _ = encoder.encode(result.as.char_list, bytes);
    return result;
}

/// `-105!(f;args;handler)`, `.Q.trp`: `f . args`, or on failure the handler applied to the
/// error text and a backtrace, which is `()` here as the debugger's frames are not kept.
fn trap(vm: *Vm, y: *Value) Vm.RunError!*Value {
    if (y.as != .list or y.as.list.len != 3) return error.type;
    const f = y.as.list[0];
    const handler = y.as.list[2];
    return apply(vm, f, y.as.list[1]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (!Vm.isFunction(handler)) return handler.ref();
            const text = try vm.errorText(err);
            defer text.deref(vm.gpa);
            var args = [_]*Value{ text, vm.getConstant(.empty_list) };
            defer args[1].deref(vm.gpa);
            return vm.applyImpl(handler, &args);
        },
    };
}

// ---------------------------------------------------------------------------------------
// Tables: the flip of a column dictionary, and dictionaries and tables as operands.

/// A table from column names and columns, the way `flip` makes one: the names must be
/// symbols (anything else is `nyi`, as in q), the columns lists of one length with atoms
/// spread to it (`flip `a`b!(1 2;3)` has a column `3 3`); all atoms is `rank` and
/// different lengths `length`.
pub fn makeTable(vm: *Vm, keys: *Value, values: *Value) Vm.RunError!*Value {
    if (keys.as != .symbol_list) return error.nyi;
    if (values.as != .list) return error.rank;
    const columns = values.as.list;
    if (columns.len != keys.count()) return error.length;
    var length: ?usize = null;
    for (columns) |column| if (column.isList()) {
        if (length) |n| {
            if (column.count() != n) return error.length;
        } else length = column.count();
    };
    const n = length orelse return error.rank;
    const spread = try vm.allocValue(.list, columns.len);
    var filled: usize = 0;
    errdefer {
        for (spread.as.list[0..filled]) |c| c.deref(vm.gpa);
        vm.gpa.free(spread.as.list);
        vm.gpa.destroy(spread);
    }
    for (columns) |column| {
        if (column.isList()) {
            spread.as.list[filled] = column.ref();
        } else {
            const count = try vm.createValue(.long, @intCast(n));
            defer count.deref(vm.gpa);
            spread.as.list[filled] = try take(vm, count, column);
        }
        filled += 1;
    }
    return vm.createValue(.table, .{ .keys = keys.ref(), .values = spread });
}

/// Row `i` of a table as a dictionary, a row of nulls past the end.
pub fn rowAt(vm: *Vm, table: *Value, i: usize) Vm.RunError!*Value {
    const t = table.as.table;
    const columns = t.values.as.list;
    const items = try vm.gpa.alloc(*Value, columns.len);
    defer vm.gpa.free(items);
    var done: usize = 0;
    defer for (items[0..done]) |v| v.deref(vm.gpa);
    for (columns) |column| {
        items[done] = if (i < column.count()) try itemAt(vm, column, i) else try nullLike(vm, column);
        done += 1;
    }
    const values = if (columns.len == 0) try vm.allocValue(.list, 0) else try vm.enlist(items);
    errdefer values.deref(vm.gpa);
    return vm.createValue(.dict, .{ .keys = t.keys.ref(), .values = values });
}

/// The columns of a table each indexed by `index`, as a table: `t[0 1]`.
pub fn tableRows(vm: *Vm, table: *Value, index: *Value) Vm.RunError!*Value {
    const t = table.as.table;
    const columns = t.values.as.list;
    const picked = try vm.allocValue(.list, columns.len);
    var filled: usize = 0;
    errdefer {
        for (picked.as.list[0..filled]) |c| c.deref(vm.gpa);
        vm.gpa.free(picked.as.list);
        vm.gpa.destroy(picked);
    }
    for (columns) |column| {
        var args = [_]*Value{index};
        picked.as.list[filled] = try vm.indexList(column, &args);
        filled += 1;
    }
    defer picked.deref(vm.gpa);
    return makeTable(vm, t.keys, picked);
}

/// `f` applied to every column of a table, the results making a table again.
pub fn mapColumns(vm: *Vm, table: *Value, comptime f: fn (*Vm, *Value) Vm.RunError!*Value) Vm.RunError!*Value {
    const t = table.as.table;
    const columns = t.values.as.list;
    const mapped = try vm.allocValue(.list, columns.len);
    var filled: usize = 0;
    errdefer {
        for (mapped.as.list[0..filled]) |c| c.deref(vm.gpa);
        vm.gpa.free(mapped.as.list);
        vm.gpa.destroy(mapped);
    }
    for (columns) |column| {
        mapped.as.list[filled] = try f(vm, column);
        filled += 1;
    }
    defer mapped.deref(vm.gpa);
    return makeTable(vm, t.keys, mapped);
}

/// A dyadic function over dictionaries and tables, or null when neither operand is one:
/// two dictionaries pair values by key, the result holding the keys of both with an
/// unpaired value kept as it is (`` (`a`b!1 2)+`b`c!10 20 `` is `` `a`b`c!1 12 20 ``); a
/// dictionary with anything else pairs its values with it; a table works as its column
/// dictionary and flips back.
pub fn withDicts(vm: *Vm, x: *Value, y: *Value, comptime f: fn (*Vm, *Value, *Value) Vm.RunError!*Value) Vm.RunError!?*Value {
    const x_table = x.as == .table;
    const y_table = y.as == .table;
    if (x_table or y_table) {
        const dx = if (x_table) try vm.createValue(.dict, .{ .keys = x.as.table.keys.ref(), .values = x.as.table.values.ref() }) else x.ref();
        defer dx.deref(vm.gpa);
        const dy = if (y_table) try vm.createValue(.dict, .{ .keys = y.as.table.keys.ref(), .values = y.as.table.values.ref() }) else y.ref();
        defer dy.deref(vm.gpa);
        const result = (try withDicts(vm, dx, dy, f)).?;
        defer result.deref(vm.gpa);
        return try makeTable(vm, result.as.dict.keys, result.as.dict.values);
    }
    if (x.as != .dict and y.as != .dict) return null;
    if (x.as == .dict and y.as == .dict) {
        const xd = x.as.dict;
        const yd = y.as.dict;
        var keys = xd.keys.ref();
        defer keys.deref(vm.gpa);
        var values: std.ArrayList(*Value) = .empty;
        defer values.deinit(vm.gpa);
        defer for (values.items) |v| v.deref(vm.gpa);
        for (0..xd.keys.count()) |i| {
            const key = try itemAt(vm, xd.keys, i);
            defer key.deref(vm.gpa);
            const xv = try itemAt(vm, xd.values, i);
            defer xv.deref(vm.gpa);
            if (try vm.keyPosition(yd.keys, key)) |j| {
                const yv = try itemAt(vm, yd.values, j);
                defer yv.deref(vm.gpa);
                try values.append(vm.gpa, try f(vm, xv, yv));
            } else try values.append(vm.gpa, xv.ref());
        }
        for (0..yd.keys.count()) |j| {
            const key = try itemAt(vm, yd.keys, j);
            defer key.deref(vm.gpa);
            if ((try vm.keyPosition(xd.keys, key)) != null) continue;
            const extended = try join(vm, keys, key);
            keys.deref(vm.gpa);
            keys = extended;
            try values.append(vm.gpa, try itemAt(vm, yd.values, j));
        }
        const value_list = if (values.items.len == 0) try vm.allocValue(.list, 0) else try vm.enlist(values.items);
        errdefer value_list.deref(vm.gpa);
        return try vm.createValue(.dict, .{ .keys = keys.ref(), .values = value_list });
    }
    const d = if (x.as == .dict) x.as.dict else y.as.dict;
    const values = if (x.as == .dict) try f(vm, d.values, y) else try f(vm, x, d.values);
    errdefer values.deref(vm.gpa);
    return try vm.createValue(.dict, .{ .keys = d.keys.ref(), .values = values });
}

/// `n!t` keys a table by its first `n` columns; `0!` on a keyed table joins the key and
/// value columns back into one table.
pub fn keyTable(vm: *Vm, n: i64, table: *Value) Vm.RunError!*Value {
    if (n < 0) return error.domain;
    if (table.as == .dict) {
        // Unkeying, or rekeying a keyed table.
        const d = table.as.dict;
        if (d.keys.as != .table or d.values.as != .table) return error.type;
        const keys = try join(vm, d.keys.as.table.keys, d.values.as.table.keys);
        defer keys.deref(vm.gpa);
        const values = try join(vm, d.keys.as.table.values, d.values.as.table.values);
        defer values.deref(vm.gpa);
        const plain = try makeTable(vm, keys, values);
        if (n == 0) return plain;
        defer plain.deref(vm.gpa);
        return keyTable(vm, n, plain);
    }
    if (table.as != .table) return error.type;
    if (n == 0) return table.ref();
    const t = table.as.table;
    const columns = t.values.as.list;
    if (n > columns.len) return error.length;
    const count: usize = @intCast(n);
    const key_names = try takeItems(vm, t.keys, @intCast(count), 0);
    defer key_names.deref(vm.gpa);
    const key_columns = try takeItems(vm, t.values, @intCast(count), 0);
    defer key_columns.deref(vm.gpa);
    const value_names = try takeItems(vm, t.keys, @intCast(columns.len - count), count);
    defer value_names.deref(vm.gpa);
    const value_columns = try takeItems(vm, t.values, @intCast(columns.len - count), count);
    defer value_columns.deref(vm.gpa);
    const keys = try makeTable(vm, key_names, key_columns);
    errdefer keys.deref(vm.gpa);
    const values = try makeTable(vm, value_names, value_columns);
    errdefer values.deref(vm.gpa);
    return vm.createValue(.dict, .{ .keys = keys, .values = values });
}

/// `x,y` with a table: two tables of the same columns append rows, a table and a
/// dictionary with its columns appends a row, and anything else is q's `mismatch`.
fn joinTables(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    if (x.as == .table and y.as == .table) {
        const xt = x.as.table;
        const yt = y.as.table;
        if (!xt.keys.eql(yt.keys)) return vm.failWith("mismatch");
        const columns = try vm.allocValue(.list, xt.values.as.list.len);
        var filled: usize = 0;
        errdefer {
            for (columns.as.list[0..filled]) |c| c.deref(vm.gpa);
            vm.gpa.free(columns.as.list);
            vm.gpa.destroy(columns);
        }
        for (xt.values.as.list, yt.values.as.list) |a, b| {
            columns.as.list[filled] = try join(vm, a, b);
            filled += 1;
        }
        defer columns.deref(vm.gpa);
        return makeTable(vm, xt.keys, columns);
    }
    if (x.as == .table and y.as == .dict) {
        const row = try q.unary_primitives.enlist(vm, y);
        defer row.deref(vm.gpa);
        return joinTables(vm, x, row);
    }
    return error.type;
}

/// `n#t` takes rows and `` `a`b#t `` takes columns.
fn takeTable(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    switch (x.as) {
        .symbol => return error.type,
        .symbol_list => {
            const columns = try vm.createValue(.dict, .{ .keys = y.as.table.keys.ref(), .values = y.as.table.values.ref() });
            defer columns.deref(vm.gpa);
            const taken = try takeDict(vm, x, columns);
            defer taken.deref(vm.gpa);
            return makeTable(vm, taken.as.dict.keys, taken.as.dict.values);
        },
        else => {
            const t = y.as.table;
            const picked = try vm.allocValue(.list, t.values.as.list.len);
            var filled: usize = 0;
            errdefer {
                for (picked.as.list[0..filled]) |c| c.deref(vm.gpa);
                vm.gpa.free(picked.as.list);
                vm.gpa.destroy(picked);
            }
            for (t.values.as.list) |column| {
                picked.as.list[filled] = try take(vm, x, column);
                filled += 1;
            }
            defer picked.deref(vm.gpa);
            return makeTable(vm, t.keys, picked);
        },
    }
}

/// `n_t` drops rows and `` `a_t `` or `` `a`b_t `` drops columns.
fn dropTable(vm: *Vm, x: *Value, y: *Value) Vm.RunError!*Value {
    switch (x.as) {
        .symbol, .symbol_list => {
            const columns = try vm.createValue(.dict, .{ .keys = y.as.table.keys.ref(), .values = y.as.table.values.ref() });
            defer columns.deref(vm.gpa);
            const kept = try drop(vm, x, columns);
            defer kept.deref(vm.gpa);
            return makeTable(vm, kept.as.dict.keys, kept.as.dict.values);
        },
        else => {
            const t = y.as.table;
            const picked = try vm.allocValue(.list, t.values.as.list.len);
            var filled: usize = 0;
            errdefer {
                for (picked.as.list[0..filled]) |c| c.deref(vm.gpa);
                vm.gpa.free(picked.as.list);
                vm.gpa.destroy(picked);
            }
            for (t.values.as.list) |column| {
                picked.as.list[filled] = try drop(vm, x, column);
                filled += 1;
            }
            defer picked.deref(vm.gpa);
            return makeTable(vm, t.keys, picked);
        },
    }
}
