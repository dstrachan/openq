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

/// `+x` flip: a general list of lists transposed, atoms among the items spread down their
/// column (`+(1 2;3)` is `(1 3;2 3)`), the rows unified (`+(1 2;3 4)` is `(1 3;2 4)`,
/// `+(1 2;`a`b)` is `((1;`a);(2;`b))`); lists of different lengths are a `length` error
/// and a typed list, an atom or a list of atoms alone a `rank` error. A dictionary flips
/// to a table, which is not done yet.
pub fn flip(vm: *Vm, x: *Value) Vm.RunError!*Value {
    switch (x.as) {
        // A column dictionary flips to a table and a table back to its dictionary.
        .dict => |d| return q.operators.makeTable(vm, d.keys, d.values),
        .table => |t| return vm.createValue(.dict, .{ .keys = t.keys.ref(), .values = t.values.ref() }),
        .list => |items| {
            if (items.len == 0) return x.ref();
            var width: ?usize = null;
            for (items) |item| if (item.isList()) {
                if (width) |w| {
                    if (item.count() != w) return error.length;
                } else width = item.count();
            };
            const n = width orelse return error.rank;
            if (n == 0) return vm.allocValue(.list, 0);
            const rows = try vm.gpa.alloc(*Value, n);
            defer vm.gpa.free(rows);
            var done: usize = 0;
            defer for (rows[0..done]) |r| r.deref(vm.gpa);
            const cells = try vm.gpa.alloc(*Value, items.len);
            defer vm.gpa.free(cells);
            for (0..n) |j| {
                var got: usize = 0;
                defer for (cells[0..got]) |c| c.deref(vm.gpa);
                for (items) |item| {
                    cells[got] = if (item.isList()) try q.operators.itemAt(vm, item, j) else item.ref();
                    got += 1;
                }
                rows[done] = try vm.enlist(cells);
                done += 1;
            }
            return vm.enlist(rows);
        },
        else => return error.rank,
    }
}

pub fn neg(vm: *Vm, x: *Value) Vm.RunError!*Value {
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
        .dict => return mapValues(vm, x, neg),
        .table => return q.operators.mapColumns(vm, x, neg),
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
        .composition => return error.type,
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
        .list => |val| return if (val.len > 0) val[0].ref() else x.ref(),
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
        .composition,
        => return x.ref(),
        .boolean_list => |val| return vm.createValue(.boolean, if (val.len > 0) val[0] else false),
        .byte_list => |val| return vm.createValue(.byte, if (val.len > 0) val[0] else 0),
        inline .short_list,
        .int_list,
        .long_list,
        .timestamp_list,
        .month_list,
        .date_list,
        .timespan_list,
        .minute_list,
        .second_list,
        .time_list,
        => |val, tag| return vm.createValue(
            q.operators.counterpart(tag),
            if (val.len > 0) val[0] else @backingInt(Value.Integer(@typeInfo(@TypeOf(val)).pointer.child).null),
        ),
        inline .real_list, .float_list, .datetime_list => |val, tag| return vm.createValue(
            q.operators.counterpart(tag),
            if (val.len > 0) val[0] else std.math.nan(@typeInfo(@TypeOf(val)).pointer.child),
        ),
        .char_list => |val| return vm.createValue(.char, if (val.len > 0) val[0] else ' '),
        .symbol_list => |val| return vm.createValue(.symbol, if (val.len > 0) val[0] else .empty),
        .dict => |val| return first(vm, val.values),
        // The first row of a table, a row of nulls when it has none.
        .table => return q.operators.rowAt(vm, x, 0),
    }
}

pub fn list(vm: *Vm, x: *Value) !*Value {
    return enlist(vm, x);
}

fn enlistValue(vm: *Vm, x: *Value) Vm.RunError!*Value {
    return enlist(vm, x);
}

pub fn count(vm: *Vm, x: *Value) !*Value {
    return vm.createValue(.long, @intCast(x.count()));
}

/// `_:` is `floor` on numbers and `lower` on text, as in q: floats and reals floor to
/// longs (`0n` to `0N`, `0w` to `0W`, `-0w` and anything below the long range to `0N`,
/// anything above it to `0W`), integers stay as they are, chars and symbols go to lower
/// case, and a general list is done item by item.
pub fn lower(vm: *Vm, x: *Value) Vm.RunError!*Value {
    switch (x.as) {
        .float => |v| return vm.createValue(.long, floorToLong(v)),
        .real => |v| return vm.createValue(.long, floorToLong(v)),
        .float_list => |items| {
            const result = try vm.allocValue(.long_list, items.len);
            for (result.as.long_list, items) |*r, v| r.* = floorToLong(v);
            return result;
        },
        .real_list => |items| {
            const result = try vm.allocValue(.long_list, items.len);
            for (result.as.long_list, items) |*r, v| r.* = floorToLong(v);
            return result;
        },
        .short, .int, .long, .short_list, .int_list, .long_list => return x.ref(),
        .char => |c| return vm.createValue(.char, std.ascii.toLower(c)),
        .char_list => |text| {
            const result = try vm.allocValue(.char_list, text.len);
            for (result.as.char_list, text) |*r, c| r.* = std.ascii.toLower(c);
            return result;
        },
        .symbol => |s| return vm.createValue(.symbol, try lowerSymbol(vm, s)),
        .symbol_list => |items| {
            const result = try vm.allocValue(.symbol_list, items.len);
            errdefer result.deref(vm.gpa);
            for (result.as.symbol_list, items) |*r, s| r.* = try lowerSymbol(vm, s);
            return result;
        },
        .list => |items| {
            const results = try vm.gpa.alloc(*Value, items.len);
            defer vm.gpa.free(results);
            var done: usize = 0;
            defer for (results[0..done]) |r| r.deref(vm.gpa);
            for (items) |item| {
                results[done] = try lower(vm, item);
                done += 1;
            }
            return if (items.len == 0) vm.allocValue(.list, 0) else vm.enlist(results);
        },
        else => return error.type,
    }
}

fn floorToLong(v: anytype) i64 {
    const f: f64 = @floatCast(v);
    if (std.math.isNan(f)) return @backingInt(Value.Long.null);
    const floored = @floor(f);
    if (floored >= 9223372036854775808.0) return @backingInt(Value.Long.inf);
    if (floored < -9223372036854775808.0) return @backingInt(Value.Long.null);
    return @intFromFloat(floored);
}

fn lowerSymbol(vm: *Vm, symbol: Symbol) !Symbol {
    const text = vm.internedString(symbol);
    const buffer = try vm.gpa.alloc(u8, text.len);
    defer vm.gpa.free(buffer);
    for (buffer, text) |*b, c| b.* = std.ascii.toLower(c);
    return vm.intern(buffer);
}

pub fn @"type"(vm: *Vm, x: *Value) !*Value {
    return vm.createValue(.short, @backingInt(x.as));
}

pub fn read_text(vm: *Vm, x: *Value) !*Value {
    return q.files.read0(vm, x);
}

pub fn read_binary(vm: *Vm, x: *Value) !*Value {
    return q.files.read1(vm, x);
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
        .composition,
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
        // Enlisting a dictionary with symbol keys makes a one-row table; any other
        // dictionary becomes a one-item general list.
        .dict => |d| {
            if (d.keys.as == .symbol_list) {
                const n = d.values.count();
                const cells = try vm.gpa.alloc(*Value, n);
                defer vm.gpa.free(cells);
                var made: usize = 0;
                defer for (cells[0..made]) |c| c.deref(vm.gpa);
                for (0..n) |i| {
                    const item = try q.operators.itemAt(vm, d.values, i);
                    defer item.deref(vm.gpa);
                    cells[made] = try enlist(vm, item);
                    made += 1;
                }
                const columns = try vm.allocValue(.list, n);
                for (columns.as.list, cells) |*slot, c| slot.* = c.ref();
                defer columns.deref(vm.gpa);
                return q.operators.makeTable(vm, d.keys, columns);
            }
            const v = try vm.allocValue(.list, 1);
            errdefer comptime unreachable;
            v.as.list[0] = x.ref();
            return v;
        },
        .table => {
            const v = try vm.allocValue(.list, 1);
            errdefer comptime unreachable;
            v.as.list[0] = x.ref();
            return v;
        },
    }
}

// avg is defined with the aggregates below.

pub fn exit(vm: *Vm, x: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    return error.nyi;
}

/// `getenv x`: the value of the environment variable named by a symbol, `""` when it is
/// not set, a list of symbols read each; anything else is a type error.
pub fn getenv(vm: *Vm, x: *Value) Vm.RunError!*Value {
    switch (x.as) {
        .symbol => |s| return textValue(vm, vm.environ.get(vm.internedString(s)) orelse ""),
        .symbol_list => |names| {
            if (names.len == 0) return vm.allocValue(.list, 0);
            const results = try vm.gpa.alloc(*Value, names.len);
            defer vm.gpa.free(results);
            var done: usize = 0;
            defer for (results[0..done]) |r| r.deref(vm.gpa);
            for (names) |s| {
                results[done] = try textValue(vm, vm.environ.get(vm.internedString(s)) orelse "");
                done += 1;
            }
            return vm.enlist(results);
        },
        .list => |items| return if (items.len == 0) x.ref() else error.type,
        else => return error.type,
    }
}

pub fn hopen(vm: *Vm, x: *Value) !*Value {
    return q.files.hopen(vm, x);
}

// last is defined with the aggregates below.

// max is defined with the aggregates below.

// min is defined with the aggregates below.

// prd is defined with the aggregates below.

// sum is defined with the aggregates below.

// ---------------------------------------------------------------------------------------
// Aggregates.

const Fold = enum { sum, prd, min, max };

pub fn sum(vm: *Vm, x: *Value) Vm.RunError!*Value {
    return aggregate(vm, x, .sum);
}
pub fn prd(vm: *Vm, x: *Value) Vm.RunError!*Value {
    return aggregate(vm, x, .prd);
}
pub fn min(vm: *Vm, x: *Value) Vm.RunError!*Value {
    return aggregate(vm, x, .min);
}
pub fn max(vm: *Vm, x: *Value) Vm.RunError!*Value {
    return aggregate(vm, x, .max);
}

/// `sum`, `prd`, `min` and `max` as q does them: an atom is its own result, `()` stays
/// `()`, a general list folds with `+`, `*`, `&` or `|` item by item, and a typed list
/// skips nulls. Sums and products of booleans, bytes, shorts, ints and chars are ints,
/// longs stay longs, reals and floats stay themselves and temporals sum to their own type
/// (`sum 2000.01.01 2000.01.02` is `2000.01.02`) but have no product, nor do chars. A
/// min or max keeps the list's type, with an empty typed list giving the type's infinity:
/// `0W` and `-0W` for numbers and temporals, `1b` and `0b`, `0xff` and `0x00`, `"\377"`
/// and `"\000"`. Symbols are type errors.
fn aggregate(vm: *Vm, x: *Value, comptime fold: Fold) Vm.RunError!*Value {
    switch (x.as) {
        .symbol, .symbol_list => return error.type,
        .list => |items| {
            if (items.len == 0) return x.ref();
            const operator = vm.getOperator(switch (fold) {
                .sum => .add,
                .prd => .multiply,
                .min => .@"and",
                .max => .@"or",
            });
            defer operator.deref(vm.gpa);
            var acc = items[0].ref();
            errdefer acc.deref(vm.gpa);
            for (items[1..]) |item| {
                var operands = [_]*Value{ acc, item };
                const next = try vm.applyImpl(operator, &operands);
                acc.deref(vm.gpa);
                acc = next;
            }
            return acc;
        },
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
        => |items, tag| return foldTyped(vm, items, tag, fold),
        .dict => |d| return aggregate(vm, d.values, fold),
        .table => |t| {
            const values = try mapItems(vm, t.values.as.list, switch (fold) {
                .sum => sum,
                .prd => prd,
                .min => min,
                .max => max,
            });
            errdefer values.deref(vm.gpa);
            return vm.createValue(.dict, .{ .keys = t.keys.ref(), .values = values });
        },
        else => return if (Vm.isFunction(x)) error.type else x.ref(),
    }
}

fn foldTyped(vm: *Vm, items: anytype, comptime tag: Value.Type, comptime fold: Fold) Vm.RunError!*Value {
    const Item = @TypeOf(items[0]);
    const is_float = Item == f32 or Item == f64;
    const atom_tag: Value.Type = @fromBackingInt(-@backingInt(tag));
    const is_temporal = switch (tag) {
        .timestamp_list, .month_list, .date_list, .datetime_list, .timespan_list, .minute_list, .second_list, .time_list => true,
        else => false,
    };
    // Sums and products widen small integers to int and keep the rest; min and max keep
    // the type.
    if (fold == .prd and (is_temporal or tag == .char_list)) return error.type;
    const result_tag: Value.Type = if (fold == .min or fold == .max) atom_tag else switch (tag) {
        .boolean_list, .byte_list, .short_list, .int_list, .char_list => .int,
        else => atom_tag,
    };
    const Result = @FieldType(Value.Union, @tagName(result_tag));
    var acc_i: ?i64 = null;
    var acc_f: ?f64 = null;
    for (items) |item| {
        const is_null = switch (Item) {
            bool, u8 => false,
            f32, f64 => std.math.isNan(item),
            else => item == std.math.minInt(Item),
        };
        if (is_null) continue;
        if (is_float) {
            const v: f64 = @floatCast(item);
            acc_f = if (acc_f) |a| switch (fold) {
                .sum => a + v,
                .prd => a * v,
                .min => @min(a, v),
                .max => @max(a, v),
            } else v;
        } else {
            const v: i64 = if (Item == bool) @intFromBool(item) else @intCast(item);
            acc_i = if (acc_i) |a| switch (fold) {
                .sum => a +% v,
                .prd => a *% v,
                .min => @min(a, v),
                .max => @max(a, v),
            } else v;
        }
    }
    if (is_float) {
        const total: f64 = acc_f orelse switch (fold) {
            .sum => 0,
            .prd => 1,
            .min => std.math.inf(f64),
            .max => -std.math.inf(f64),
        };
        return vm.createValue(result_tag, @as(Result, @floatCast(total)));
    }
    const total: i64 = acc_i orelse switch (fold) {
        .sum => 0,
        .prd => 1,
        .min => switch (Result) {
            bool => 1,
            u8 => 255,
            else => std.math.maxInt(Result),
        },
        .max => switch (Result) {
            bool => 0,
            u8 => 0,
            else => -std.math.maxInt(Result),
        },
    };
    return vm.createValue(result_tag, switch (Result) {
        bool => total != 0,
        u8 => @intCast(total),
        else => @truncate(total),
    });
}

/// `avg`: the mean as a float, nulls left out, `0n` for an empty list, an atom as a float,
/// and a general list averaged item by item. Bytes, chars and temporals average their
/// codes: `avg "ab"` is `97.5` and `avg 2000.01.01 2000.01.03` is `1f`.
pub fn avg(vm: *Vm, x: *Value) Vm.RunError!*Value {
    switch (x.as) {
        .list => |items| {
            if (items.len == 0) return vm.createValue(.float, std.math.nan(f64));
            const total = try aggregate(vm, x, .sum);
            defer total.deref(vm.gpa);
            const n = try vm.createValue(.long, @intCast(items.len));
            defer n.deref(vm.gpa);
            return q.operators.divide(vm, total, n);
        },
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
        => |items| {
            const Item = @TypeOf(items[0]);
            var total: f64 = 0;
            var n: usize = 0;
            for (items) |item| {
                const is_null = switch (Item) {
                    bool, u8 => false,
                    f32, f64 => std.math.isNan(item),
                    else => item == std.math.minInt(Item),
                };
                if (is_null) continue;
                total += switch (Item) {
                    bool => @as(f64, @floatFromInt(@intFromBool(item))),
                    f32, f64 => @as(f64, @floatCast(item)),
                    else => @as(f64, @floatFromInt(item)),
                };
                n += 1;
            }
            return vm.createValue(.float, if (n == 0) std.math.nan(f64) else total / @as(f64, @floatFromInt(n)));
        },
        .boolean, .byte, .char, .short, .int, .long, .real, .float => {
            const total = try aggregate(vm, x, .sum);
            defer total.deref(vm.gpa);
            const one = vm.getConstant(.one);
            defer one.deref(vm.gpa);
            return q.operators.divide(vm, total, one);
        },
        else => return error.type,
    }
}

/// `last x`: the last item, the null of the type for an empty list, an atom itself.
pub fn last(vm: *Vm, x: *Value) Vm.RunError!*Value {
    if (x.as == .table) return q.operators.rowAt(vm, x, if (x.count() == 0) std.math.maxInt(usize) else x.count() - 1);
    if (x.as == .dict) return last(vm, x.as.dict.values);
    if (!x.isList()) return x.ref();
    const n = x.count();
    if (n == 0) return q.operators.nullLike(vm, x);
    return q.operators.itemAt(vm, x, n - 1);
}

// ---------------------------------------------------------------------------------------
// The monadic glyphs: `$` string, `~` not, `^` null, `&` where, `|` reverse, `?` distinct,
// `=` group, `<` and `>` grade, `%` reciprocal, `!` key and `.` value.

/// A general list mapped item by item, `()` staying `()`.
fn mapItems(vm: *Vm, items: []*Value, comptime f: fn (*Vm, *Value) Vm.RunError!*Value) Vm.RunError!*Value {
    if (items.len == 0) return vm.allocValue(.list, 0);
    const results = try vm.gpa.alloc(*Value, items.len);
    defer vm.gpa.free(results);
    var done: usize = 0;
    defer for (results[0..done]) |r| r.deref(vm.gpa);
    for (items) |item| {
        results[done] = try f(vm, item);
        done += 1;
    }
    return vm.enlist(results);
}

/// A dictionary with `f` applied to its values.
fn mapValues(vm: *Vm, x: *Value, comptime f: fn (*Vm, *Value) Vm.RunError!*Value) Vm.RunError!*Value {
    const values = try f(vm, x.as.dict.values);
    errdefer values.deref(vm.gpa);
    return vm.createValue(.dict, .{ .keys = x.as.dict.keys.ref(), .values = values });
}

/// The items of a list `x` at `indices`, as a list of `x`'s type.
fn gather(vm: *Vm, x: *Value, indices: []const usize) Allocator.Error!*Value {
    switch (x.as) {
        .list => |items| {
            const result = try vm.allocValue(.list, indices.len);
            errdefer comptime unreachable;
            for (result.as.list, indices) |*r, i| r.* = items[i].ref();
            return result;
        },
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
            const result = try vm.allocValue(tag, indices.len);
            errdefer comptime unreachable;
            for (@field(result.as, @tagName(tag)), indices) |*r, i| r.* = items[i];
            return result;
        },
        else => unreachable,
    }
}

/// A string value holding `bytes`.
fn textValue(vm: *Vm, bytes: []const u8) Allocator.Error!*Value {
    const v = try vm.allocValue(.char_list, bytes.len);
    errdefer comptime unreachable;
    @memcpy(v.as.char_list, bytes);
    return v;
}

/// The value as a float, for reciprocals: nulls are `0n`, booleans, bytes, chars and
/// temporal values count by their number.
fn scalarFloat(comptime tag: Value.Type, v: anytype) f64 {
    return switch (tag) {
        .boolean => @floatFromInt(@intFromBool(v)),
        .byte, .char => @floatFromInt(v),
        .real, .float, .datetime => v,
        else => if (v == std.math.minInt(@TypeOf(v))) std.math.nan(f64) else @floatFromInt(v),
    };
}

fn isZero(comptime tag: Value.Type, v: anytype) bool {
    return switch (tag) {
        .boolean => !v,
        else => v == 0,
    };
}

fn isNullScalar(comptime tag: Value.Type, v: anytype) bool {
    return switch (tag) {
        .boolean, .byte => false,
        .char => v == ' ',
        .symbol => v == .empty,
        .real, .float, .datetime => std.math.isNan(v),
        else => v == std.math.minInt(@TypeOf(v)),
    };
}

/// `$x` string: an atom becomes its text without any type marker (`$1.5` is `"1.5"`, `$1.0`
/// is `,"1"`, `` $`a `` is `,"a"`, `$0x01` is `"01"`, `$1b` is `,"1"`), a null of any type
/// the empty string and an infinity `"0W"` or `"0w"`; a list is done item by item, so a
/// string becomes a list of one-char strings and `$""` is `()`; a dictionary keeps its
/// keys; a function gives its display text. Floats follow `\P` as display does.
pub fn string(vm: *Vm, x: *Value) Vm.RunError!*Value {
    switch (x.as) {
        .list => |items| return mapItems(vm, items, string),
        .dict => return mapValues(vm, x, string),
        .table => return q.operators.mapColumns(vm, x, string),
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
            const n = x.count();
            if (n == 0) return vm.allocValue(.list, 0);
            const results = try vm.gpa.alloc(*Value, n);
            defer vm.gpa.free(results);
            var done: usize = 0;
            defer for (results[0..done]) |r| r.deref(vm.gpa);
            for (0..n) |i| {
                const item = try q.operators.itemAt(vm, x, i);
                defer item.deref(vm.gpa);
                results[done] = try stringAtom(vm, item);
                done += 1;
            }
            return vm.enlist(results);
        },
        else => return stringAtom(vm, x),
    }
}

fn stringAtom(vm: *Vm, x: *Value) Vm.RunError!*Value {
    switch (x.as) {
        .boolean => |b| return textValue(vm, if (b) "1" else "0"),
        .byte => |b| {
            var buffer: [2]u8 = undefined;
            return textValue(vm, std.fmt.bufPrint(&buffer, "{x:0>2}", .{b}) catch unreachable);
        },
        .char => |c| return textValue(vm, &.{c}),
        .symbol => |s| return textValue(vm, vm.internedString(s)),
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
        => |v, tag| {
            const T = @TypeOf(v);
            if (T == f32 or T == f64) {
                if (std.math.isNan(v)) return textValue(vm, "");
                if (std.math.isInf(v)) return textValue(vm, if (v < 0) "-0w" else "0w");
            } else {
                if (v == std.math.minInt(T)) return textValue(vm, "");
                if (v == std.math.maxInt(T)) return textValue(vm, "0W");
                if (v == -std.math.maxInt(T)) return textValue(vm, "-0W");
            }
            var buffer: Io.Writer.Allocating = .init(vm.gpa);
            defer buffer.deinit();
            buffer.writer.print("{f}", .{x.fmt(vm)}) catch return error.OutOfMemory;
            const written = buffer.written();
            // Display adds a type letter that `string` leaves out.
            const drop: usize = switch (tag) {
                .short, .int, .real, .month => 1,
                .float => @intFromBool(written[written.len - 1] == 'f'),
                else => 0,
            };
            return textValue(vm, written[0 .. written.len - drop]);
        },
        else => {
            var buffer: Io.Writer.Allocating = .init(vm.gpa);
            defer buffer.deinit();
            buffer.writer.print("{f}", .{x.fmt(vm)}) catch return error.OutOfMemory;
            return textValue(vm, buffer.written());
        },
    }
}

/// `~x` not: whether each number is zero, as booleans; nulls are not zero, so `~0N` is
/// `0b`. Chars, bytes and temporal values count by their number; symbols and functions
/// are a type error.
pub fn not(vm: *Vm, x: *Value) Vm.RunError!*Value {
    switch (x.as) {
        .list => |items| return mapItems(vm, items, not),
        .dict => return mapValues(vm, x, not),
        .table => return q.operators.mapColumns(vm, x, not),
        // A symbol atom is `nyi` in q, unless it names a file, which `hdel` (`~:`) removes.
        .symbol => return if (q.files.isFileSymbol(vm, x)) q.files.delete(vm, x) else error.nyi,
        inline .boolean,
        .byte,
        .short,
        .int,
        .long,
        .real,
        .float,
        .char,
        .timestamp,
        .month,
        .date,
        .datetime,
        .timespan,
        .minute,
        .second,
        .time,
        => |v, tag| return vm.createValue(.boolean, isZero(tag, v)),
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
            const result = try vm.allocValue(.boolean_list, items.len);
            errdefer comptime unreachable;
            for (result.as.boolean_list, items) |*r, v| r.* = isZero(q.operators.counterpart(tag), v);
            return result;
        },
        else => return error.type,
    }
}

/// `^x` null: whether each item is the null of its type (`0N`, `0n`, `" "`, `` ` ``, and
/// the temporal nulls), as booleans; booleans and bytes have no null. `::` is null and any
/// other function is not.
pub fn @"null"(vm: *Vm, x: *Value) Vm.RunError!*Value {
    switch (x.as) {
        .list => |items| return mapItems(vm, items, @"null"),
        .dict => return mapValues(vm, x, @"null"),
        .table => return q.operators.mapColumns(vm, x, @"null"),
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
        => |v, tag| return vm.createValue(.boolean, isNullScalar(tag, v)),
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
            const result = try vm.allocValue(.boolean_list, items.len);
            errdefer comptime unreachable;
            for (result.as.boolean_list, items) |*r, v| r.* = isNullScalar(q.operators.counterpart(tag), v);
            return result;
        },
        .unary_primitive => |p| return vm.createValue(.boolean, p == .identity),
        else => return vm.createValue(.boolean, false),
    }
}

/// `&x` where: the positions of the true items of a boolean list, and each position of an
/// int or long list repeated its count times (`&0 3` is `1 1 1`); a negative or null count
/// is a `limit` error. A general list of boolean, int and long atoms works the same way;
/// shorts, bytes and floats are a type error, as in q. On a dictionary the positions read
/// the keys (`` &`a`b!2 1 `` is `` `a`a`b ``).
pub fn where(vm: *Vm, x: *Value) Vm.RunError!*Value {
    switch (x.as) {
        .dict => |d| {
            const positions = try where(vm, d.values);
            defer positions.deref(vm.gpa);
            var args = [_]*Value{positions};
            return vm.applyImpl(d.keys, &args);
        },
        .boolean_list => |items| {
            var total: usize = 0;
            for (items) |b| total += @intFromBool(b);
            const result = try vm.allocValue(.long_list, total);
            errdefer comptime unreachable;
            var filled: usize = 0;
            for (items, 0..) |b, i| if (b) {
                result.as.long_list[filled] = @intCast(i);
                filled += 1;
            };
            return result;
        },
        .int_list, .long_list, .list => {
            const n = x.count();
            const counts = try vm.gpa.alloc(usize, n);
            defer vm.gpa.free(counts);
            var total: usize = 0;
            for (counts, 0..) |*c, i| {
                const repeats: i64 = switch (x.as) {
                    .int_list => |items| items[i],
                    .long_list => |items| items[i],
                    .list => |items| switch (items[i].as) {
                        .boolean => |b| @intFromBool(b),
                        .int => |v| v,
                        .long => |v| v,
                        else => return error.type,
                    },
                    else => unreachable,
                };
                if (repeats < 0) return error.limit;
                c.* = @intCast(repeats);
                total += c.*;
            }
            const result = try vm.allocValue(.long_list, total);
            errdefer comptime unreachable;
            var filled: usize = 0;
            for (counts, 0..) |c, i| {
                @memset(result.as.long_list[filled .. filled + c], @intCast(i));
                filled += c;
            }
            return result;
        },
        else => return error.type,
    }
}

/// `|x` reverse: a list backwards, a dictionary with both sides reversed, anything else
/// itself.
pub fn reverse(vm: *Vm, x: *Value) Vm.RunError!*Value {
    switch (x.as) {
        .table => return q.operators.mapColumns(vm, x, reverse),
        .dict => |d| {
            const keys = try reverse(vm, d.keys);
            errdefer keys.deref(vm.gpa);
            const values = try reverse(vm, d.values);
            errdefer values.deref(vm.gpa);
            return vm.createValue(.dict, .{ .keys = keys, .values = values });
        },
        .list => |items| {
            const result = try vm.allocValue(.list, items.len);
            errdefer comptime unreachable;
            for (result.as.list, 0..) |*r, i| r.* = items[items.len - 1 - i].ref();
            return result;
        },
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
            const result = try vm.allocValue(tag, items.len);
            errdefer comptime unreachable;
            for (@field(result.as, @tagName(tag)), 0..) |*r, i| r.* = items[items.len - 1 - i];
            return result;
        },
        else => return x.ref(),
    }
}

/// Whether items `i` and `j` of a list are the same for `distinct` and `group`: typed items
/// by the comparison order, so floats to within the tolerance and nulls alike, and items
/// of a general list by `~`.
fn sameItem(vm: *Vm, x: *Value, i: usize, j: usize) Allocator.Error!bool {
    if (x.as == .list) return q.operators.matches(vm, x.as.list[i], x.as.list[j]);
    return q.operators.compareItems(vm, x, i, x, j) == .eq;
}

/// The positions of the first occurrences in `x`, in order, and for each item the position
/// of its group among them.
fn groupPositions(vm: *Vm, x: *Value, firsts: *std.ArrayList(usize), ids: []usize) Allocator.Error!void {
    for (ids, 0..) |*id, i| {
        for (firsts.items, 0..) |first_at, g| {
            if (try sameItem(vm, x, i, first_at)) {
                id.* = g;
                break;
            }
        } else {
            id.* = firsts.items.len;
            try firsts.append(vm.gpa, i);
        }
    }
}

/// `?x` distinct: the items of a list in order of first appearance, floats within the
/// comparison tolerance counting as the same (`?1 1+1e-14` is `,1f`) and nulls likewise;
/// items of a general list by `~`. An atom, a dictionary or a function is a type error.
pub fn distinct(vm: *Vm, x: *Value) Vm.RunError!*Value {
    if (!x.isList()) return error.type;
    const n = x.count();
    var firsts: std.ArrayList(usize) = .empty;
    defer firsts.deinit(vm.gpa);
    const ids = try vm.gpa.alloc(usize, n);
    defer vm.gpa.free(ids);
    try groupPositions(vm, x, &firsts, ids);
    // Nothing removed gives the list itself, attribute and all, as in q.
    if (firsts.items.len == n) return x.ref();
    return gather(vm, x, firsts.items);
}

/// `=x` group: a dictionary from the distinct items of a list, in order of first
/// appearance, to the positions where each occurs (`=1 2 1` is `1 2!(0 2;,1)`, `=()` is
/// `()!()`). Grouping a dictionary maps its distinct values to their keys.
pub fn group(vm: *Vm, x: *Value) Vm.RunError!*Value {
    switch (x.as) {
        .dict => |d| {
            const grouped = try group(vm, d.values);
            defer grouped.deref(vm.gpa);
            const positions = grouped.as.dict.values.as.list;
            const values = try vm.allocValue(.list, positions.len);
            var filled: usize = 0;
            errdefer {
                for (values.as.list[0..filled]) |v| v.deref(vm.gpa);
                vm.gpa.free(values.as.list);
                vm.gpa.destroy(values);
            }
            for (positions) |p| {
                var args = [_]*Value{p};
                values.as.list[filled] = try vm.applyImpl(d.keys, &args);
                filled += 1;
            }
            return vm.createValue(.dict, .{ .keys = grouped.as.dict.keys.ref(), .values = values });
        },
        else => {
            if (!x.isList()) return error.type;
            const n = x.count();
            var firsts: std.ArrayList(usize) = .empty;
            defer firsts.deinit(vm.gpa);
            const ids = try vm.gpa.alloc(usize, n);
            defer vm.gpa.free(ids);
            try groupPositions(vm, x, &firsts, ids);
            const keys = try gather(vm, x, firsts.items);
            errdefer keys.deref(vm.gpa);
            const values = try vm.allocValue(.list, firsts.items.len);
            var filled: usize = 0;
            errdefer {
                for (values.as.list[0..filled]) |v| v.deref(vm.gpa);
                vm.gpa.free(values.as.list);
                vm.gpa.destroy(values);
            }
            for (firsts.items, 0..) |_, g| {
                var size: usize = 0;
                for (ids) |id| size += @intFromBool(id == g);
                const positions = try vm.allocValue(.long_list, size);
                var k: usize = 0;
                for (ids, 0..) |id, i| if (id == g) {
                    positions.as.long_list[k] = @intCast(i);
                    k += 1;
                };
                values.as.list[filled] = positions;
                filled += 1;
            }
            return vm.createValue(.dict, .{ .keys = keys, .values = values });
        },
    }
}

/// `<x` and `>x` grade: the positions that would sort a list, stably, by q's order (atoms
/// by type and then value with nulls lowest, then lists item by item, then functions), so
/// `>1 1 2` is `2 0 1`. Grading a dictionary sorts its keys by its values.
pub fn asc(vm: *Vm, x: *Value) Vm.RunError!*Value {
    return grade(vm, x, false);
}

pub fn desc(vm: *Vm, x: *Value) Vm.RunError!*Value {
    return grade(vm, x, true);
}

fn grade(vm: *Vm, x: *Value, comptime descending: bool) Vm.RunError!*Value {
    // A table grades by its rows, each row's values compared column by column.
    if (x.as == .table) {
        const n = x.count();
        const rows = try vm.gpa.alloc(*Value, n);
        defer vm.gpa.free(rows);
        var made: usize = 0;
        defer for (rows[0..made]) |r| r.deref(vm.gpa);
        for (0..n) |i| {
            const row = try q.operators.rowAt(vm, x, i);
            defer row.deref(vm.gpa);
            rows[made] = row.as.dict.values.ref();
            made += 1;
        }
        const row_list = try vm.allocValue(.list, n);
        for (row_list.as.list, rows) |*slot, r| slot.* = r.ref();
        defer row_list.deref(vm.gpa);
        return grade(vm, row_list, descending);
    }
    if (x.as == .dict) {
        const positions = try grade(vm, x.as.dict.values, descending);
        defer positions.deref(vm.gpa);
        var args = [_]*Value{positions};
        return vm.applyImpl(x.as.dict.keys, &args);
    }
    // `>:` on a handle is `hclose`, as q.k defines it.
    if (descending and (x.as == .int or x.as == .long)) return q.files.hclose(vm, x);
    if (!x.isList()) return error.type;
    const n = x.count();
    const result = try vm.allocValue(.long_list, n);
    errdefer comptime unreachable;
    for (result.as.long_list, 0..) |*r, i| r.* = @intCast(i);
    const Context = struct {
        vm: *Vm,
        x: *Value,
        fn lessThan(ctx: @This(), a: i64, b: i64) bool {
            const o = q.operators.compareItems(ctx.vm, ctx.x, @intCast(a), ctx.x, @intCast(b));
            return if (descending) o == .gt else o == .lt;
        }
    };
    std.sort.block(i64, result.as.long_list, Context{ .vm = vm, .x = x }, Context.lessThan);
    // Grading a list found already ascending marks it sorted in place, as q does: after
    // `iasc x` (and so `asc x`, `med x` or `select[<a]`) `x` itself shows `s#`.
    if (!descending and n > 0) {
        const in_order = for (result.as.long_list, 0..) |r, i| {
            if (r != i) break false;
        } else true;
        if (in_order) x.attr = .s;
    }
    return result;
}

/// `%x` reciprocal: `1%x` as a float, so `%0` is `0w` and `%0N` is `0n`; booleans, bytes,
/// chars and temporal values divide by their number. Symbols and functions are a type
/// error.
pub fn reciprocal(vm: *Vm, x: *Value) Vm.RunError!*Value {
    switch (x.as) {
        .list => |items| return mapItems(vm, items, reciprocal),
        .dict => return mapValues(vm, x, reciprocal),
        .table => return q.operators.mapColumns(vm, x, reciprocal),
        inline .boolean,
        .byte,
        .short,
        .int,
        .long,
        .real,
        .float,
        .char,
        .timestamp,
        .month,
        .date,
        .datetime,
        .timespan,
        .minute,
        .second,
        .time,
        => |v, tag| return vm.createValue(.float, 1.0 / scalarFloat(tag, v)),
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
            const result = try vm.allocValue(.float_list, items.len);
            errdefer comptime unreachable;
            for (result.as.float_list, items) |*r, v| r.* = 1.0 / scalarFloat(q.operators.counterpart(tag), v);
            return result;
        },
        else => return error.type,
    }
}

/// `!x` key: the keys of a dictionary; `til` for a boolean, byte, short, int or long atom
/// (a negative or null count is a `domain` error); the type name of a typed list (`!1 2`
/// is `` `long ``); and for a symbol the keys of the namespace it names (`` !`.q ``, the
/// root's entries for `` ` `` and the root's variables for `` `. ``), the name itself when it
/// is a defined variable, or `()`.
pub fn key(vm: *Vm, x: *Value) Vm.RunError!*Value {
    switch (x.as) {
        .dict => |d| return d.keys.ref(),
        .table => return error.type,
        .boolean => |b| return til(vm, @intFromBool(b)),
        .byte => |b| return til(vm, b),
        inline .short, .int, .long => |v| {
            if (v == std.math.minInt(@TypeOf(v)) or v < 0) return error.domain;
            if (v > std.math.maxInt(i32)) return error.limit;
            return til(vm, @intCast(v));
        },
        .symbol => |s| return keyOfName(vm, x, s),
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
        => |_, tag| {
            const name = @tagName(tag);
            return vm.createValue(.symbol, try vm.intern(name[0 .. name.len - "_list".len]));
        },
        else => return error.type,
    }
}

fn til(vm: *Vm, n: usize) Allocator.Error!*Value {
    const result = try vm.allocValue(.long_list, n);
    errdefer comptime unreachable;
    for (result.as.long_list, 0..) |*r, i| r.* = @intCast(i);
    return result;
}

fn keyOfName(vm: *Vm, x: *Value, s: Symbol) Vm.RunError!*Value {
    if (s == .empty) return vm.state.as.dict.keys.ref();
    const name = vm.internedString(s);
    // A file symbol lists a directory.
    if (name[0] == ':') return q.files.list(vm, x);
    if (name[0] == '.') {
        const namespace = (try vm.namespaceAt(name, false)) orelse return vm.allocValue(.list, 0);
        const keys = namespace.as.dict.keys;
        // The root namespace lists its variables without the empty symbol that leads every
        // other namespace's keys.
        if (name.len == 1 and keys.as.symbol_list.len > 0 and keys.as.symbol_list[0] == .empty) {
            const result = try vm.allocValue(.symbol_list, keys.as.symbol_list.len - 1);
            errdefer comptime unreachable;
            @memcpy(result.as.symbol_list, keys.as.symbol_list[1..]);
            return result;
        }
        return keys.ref();
    }
    const global = vm.readGlobal(s) catch |err| switch (err) {
        error.identifier => return vm.allocValue(.list, 0),
        else => return err,
    };
    global.deref(vm.gpa);
    return x.ref();
}

/// `.x` value: the values of a dictionary; a string evaluated (a leading backslash runs a
/// system command); the global a symbol names; a lambda's structure; for a list, its first
/// item (a string evaluated, a symbol read) applied to the rest (`value (+;1;2)` is 3,
/// `value ("+";1;2)` too); a projection as its function and arguments with `::` in the
/// holes; and the function under an iterator. Atoms are a type error.
pub fn value(vm: *Vm, x: *Value) Vm.RunError!*Value {
    switch (x.as) {
        .dict => |d| return d.values.ref(),
        .table => return error.type,
        // A primitive, an operator or an iterator is its number in q's table, which the
        // enums follow: `value (::)` is 0, `value (+)` is 1, `value (enlist)` 41, `value (')` 0.
        .unary_primitive => |p| return vm.createValue(.long, switch (p) {
            .empty => 0,
            ._unused => unreachable,
            else => @backingInt(p),
        }),
        .operator => |o| return vm.createValue(.long, @backingInt(o)),
        .iterator => |i| return vm.createValue(.long, @backingInt(i)),
        .list => |items| {
            if (items.len == 0) return x.ref();
            const f = switch (items[0].as) {
                .char_list => try value(vm, items[0]),
                // A char is a glyph: `value ("+";1;2)` is 3.
                .char => |c| try vm.evalSource(&[_:0]u8{c}, .q, "<value>"),
                .symbol => |s| try vm.readGlobal(s),
                else => items[0].ref(),
            };
            defer f.deref(vm.gpa);
            if (items.len == 1) {
                var args = [_]*Value{vm.getUnaryPrimitive(.identity)};
                defer args[0].deref(vm.gpa);
                return vm.applyImpl(f, &args);
            }
            return vm.applyImpl(f, items[1..]);
        },
        // A character is one-character source: `value "1"` is 1, `value ";"` is `::`.
        .char => |c| {
            if (c == ';' or c == ' ' or c == '\\') return vm.getUnaryPrimitive(.identity);
            return vm.evalSource(&[_:0]u8{c}, .q, "<value>");
        },
        .char_list => |source| {
            // A string starting with a backslash is a system command; anything else is q source.
            if (source.len > 0 and source[0] == '\\') return vm.system(source[1..]);
            // Nothing but separators evaluates to `::` (`value ";"`), though `parse ";"` is `type`.
            if (std.mem.trim(u8, source, " \t\r\n;").len == 0) return vm.getUnaryPrimitive(.identity);
            const slice = try vm.gpa.dupeSentinel(u8, source, 0);
            defer vm.gpa.free(slice);
            return vm.evalSource(slice, .q, "<value>");
        },
        // A file symbol reads the q data file it names.
        .symbol => |identifier| return if (q.files.isFileSymbol(vm, x)) q.files.get(vm, x) else vm.readGlobal(identifier),
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
        // `value (<=)` is `(~:;>)`: the composed functions.
        .composition => |c| {
            const result = try vm.allocValue(.list, 2);
            errdefer comptime unreachable;
            result.as.list[0] = c.f.ref();
            result.as.list[1] = c.g.ref();
            return result;
        },
        .projection => |p| {
            const result = try vm.allocValue(.list, 1 + p.args.len);
            errdefer comptime unreachable;
            result.as.list[0] = p.callee.ref();
            for (result.as.list[1..], p.args) |*r, a| r.* = if (a.isEmpty()) vm.getUnaryPrimitive(.identity) else a.ref();
            return result;
        },
        inline .each, .over, .scan, .each_prior, .each_right, .each_left => |d| return d.value.ref(),
        else => return error.type,
    }
}

// ---------------------------------------------------------------------------------------
// The mathematical natives.

/// `abs x`: the magnitude in the value's own type, booleans, bytes and chars as ints,
/// nulls kept and `-0W` made `0W`; symbols are a type error.
pub fn abs(vm: *Vm, x: *Value) Vm.RunError!*Value {
    switch (x.as) {
        .list => |items| return mapItems(vm, items, abs),
        .dict => return mapValues(vm, x, abs),
        .table => return q.operators.mapColumns(vm, x, abs),
        .boolean => |b| return vm.createValue(.int, @intFromBool(b)),
        .byte => |b| return vm.createValue(.int, b),
        .char => |c| return vm.createValue(.int, c),
        inline .short, .int, .long, .timestamp, .month, .date, .timespan, .minute, .second, .time => |v, tag| {
            return vm.createValue(tag, if (v == std.math.minInt(@TypeOf(v))) v else if (v < 0) -v else v);
        },
        inline .real, .float, .datetime => |v, tag| return vm.createValue(tag, @abs(v)),
        .boolean_list => |items| {
            const result = try vm.allocValue(.int_list, items.len);
            for (result.as.int_list, items) |*r, b| r.* = @intFromBool(b);
            return result;
        },
        inline .byte_list, .char_list => |items| {
            const result = try vm.allocValue(.int_list, items.len);
            for (result.as.int_list, items) |*r, b| r.* = b;
            return result;
        },
        inline .short_list, .int_list, .long_list, .timestamp_list, .month_list, .date_list, .timespan_list, .minute_list, .second_list, .time_list => |items, tag| {
            const result = try vm.allocValue(tag, items.len);
            for (@field(result.as, @tagName(tag)), items) |*r, v| r.* = if (v == std.math.minInt(@TypeOf(v))) v else if (v < 0) -v else v;
            return result;
        },
        inline .real_list, .float_list, .datetime_list => |items, tag| {
            const result = try vm.allocValue(tag, items.len);
            for (@field(result.as, @tagName(tag)), items) |*r, v| r.* = @abs(v);
            return result;
        },
        else => return error.type,
    }
}

/// A float function of a number: nulls give `0n`, booleans, bytes, chars and temporal
/// values count by their number, lists go item by item and symbols are a type error.
fn floatFunction(vm: *Vm, x: *Value, comptime f: fn (f64) f64) Vm.RunError!*Value {
    switch (x.as) {
        .list => |items| {
            if (items.len == 0) return vm.allocValue(.list, 0);
            const results = try vm.gpa.alloc(*Value, items.len);
            defer vm.gpa.free(results);
            var done: usize = 0;
            defer for (results[0..done]) |r| r.deref(vm.gpa);
            for (items) |item| {
                results[done] = try floatFunction(vm, item, f);
                done += 1;
            }
            return vm.enlist(results);
        },
        .dict => |d| {
            const values = try floatFunction(vm, d.values, f);
            errdefer values.deref(vm.gpa);
            return vm.createValue(.dict, .{ .keys = d.keys.ref(), .values = values });
        },
        .table => |t| {
            const values = try floatFunction(vm, t.values, f);
            defer values.deref(vm.gpa);
            return q.operators.makeTable(vm, t.keys, values);
        },
        .symbol, .symbol_list => return error.type,
        else => {},
    }
    if (x.isList()) {
        const n = x.count();
        const result = try vm.allocValue(.float_list, n);
        errdefer result.deref(vm.gpa);
        for (result.as.float_list, 0..) |*r, i| {
            const item = try q.operators.itemAt(vm, x, i);
            defer item.deref(vm.gpa);
            r.* = f(try q.operators.floatOf(item));
        }
        return result;
    }
    return vm.createValue(.float, f(try q.operators.floatOf(x)));
}

fn sqrtOf(v: f64) f64 {
    return @sqrt(v);
}
fn logOf(v: f64) f64 {
    return @log(v);
}
fn expOf(v: f64) f64 {
    return @exp(v);
}
fn sinOf(v: f64) f64 {
    return @sin(v);
}
fn cosOf(v: f64) f64 {
    return @cos(v);
}
fn tanOf(v: f64) f64 {
    return @tan(v);
}
fn asinOf(v: f64) f64 {
    return std.math.asin(v);
}
fn acosOf(v: f64) f64 {
    return std.math.acos(v);
}
fn atanOf(v: f64) f64 {
    return std.math.atan(v);
}

pub fn sqrt(vm: *Vm, x: *Value) Vm.RunError!*Value {
    return floatFunction(vm, x, sqrtOf);
}
pub fn log(vm: *Vm, x: *Value) Vm.RunError!*Value {
    return floatFunction(vm, x, logOf);
}
pub fn exp(vm: *Vm, x: *Value) Vm.RunError!*Value {
    return floatFunction(vm, x, expOf);
}
pub fn sin(vm: *Vm, x: *Value) Vm.RunError!*Value {
    return floatFunction(vm, x, sinOf);
}
pub fn cos(vm: *Vm, x: *Value) Vm.RunError!*Value {
    return floatFunction(vm, x, cosOf);
}
pub fn tan(vm: *Vm, x: *Value) Vm.RunError!*Value {
    return floatFunction(vm, x, tanOf);
}
pub fn asin(vm: *Vm, x: *Value) Vm.RunError!*Value {
    return floatFunction(vm, x, asinOf);
}
pub fn acos(vm: *Vm, x: *Value) Vm.RunError!*Value {
    return floatFunction(vm, x, acosOf);
}
pub fn atan(vm: *Vm, x: *Value) Vm.RunError!*Value {
    return floatFunction(vm, x, atanOf);
}

/// `var x`: the population variance as a float with nulls left out, an atom giving `0f`
/// and `()` staying `()`; `dev` is its square root.
pub fn @"var"(vm: *Vm, x: *Value) Vm.RunError!*Value {
    if (x.as == .list and x.as.list.len == 0) return x.ref();
    return q.operators.cov(vm, x, x);
}

pub fn dev(vm: *Vm, x: *Value) Vm.RunError!*Value {
    const variance = try @"var"(vm, x);
    if (variance.as != .float) return variance;
    defer variance.deref(vm.gpa);
    return vm.createValue(.float, @sqrt(variance.as.float));
}
