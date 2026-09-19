//! The iterators: each `'`, over `/`, scan `\\`, each-prior `':`, each-right `/:` and
//! each-left `\\:`, applied to a function to make a derived function, and the derived
//! functions applied to arguments. Verified against q 5.0.

const std = @import("std");

const q = @import("../root.zig");
const Vm = q.Vm;
const Value = q.Value;
const Operator = Value.Operator;
const itemAt = q.operators.itemAt;

const RunError = Vm.RunError;

/// `f'[x;y...]`: `f` applied to the items of the arguments in step. An atom argument goes
/// to every call, lists must agree in length, and atoms alone apply `f` once.
pub fn each(vm: *Vm, f: *Value, args: []*Value) RunError!*Value {
    if (try eachOverDicts(vm, f, args)) |result| return result;
    const n = try commonLength(args) orelse return vm.applyImpl(f, args);
    if (n == 0) return vm.allocValue(.list, 0);
    const results = try vm.gpa.alloc(*Value, n);
    defer vm.gpa.free(results);
    var done: usize = 0;
    defer for (results[0..done]) |r| r.deref(vm.gpa);
    const call_args = try vm.gpa.alloc(*Value, args.len);
    defer vm.gpa.free(call_args);
    for (0..n) |i| {
        var made: usize = 0;
        defer for (call_args[0..made]) |a| a.deref(vm.gpa);
        for (args, 0..) |a, k| {
            call_args[k] = if (a.isList()) try itemAt(vm, a, i) else a.ref();
            made += 1;
        }
        results[done] = try vm.applyImpl(f, call_args);
        done += 1;
    }
    return vm.enlist(results);
}

/// The length the list arguments share, null when all are atoms, `length` when they differ.
/// `f'` with a dictionary or a table among the arguments, or null without one: a table
/// goes row by row (rows that come back as like dictionaries make a table again), and a
/// dictionary keeps its keys, other dictionaries pairing by key (a missing key giving
/// the null of the values), lists by position and atoms whole.
fn eachOverDicts(vm: *Vm, f: *Value, args: []*Value) RunError!?*Value {
    var first_dict: ?*Value = null;
    for (args) |a| if (a.as == .table or (a.as == .dict and first_dict == null)) {
        if (a.as == .table) {
            // Rows stand in for the table.
            const n = a.count();
            const rows = try vm.gpa.alloc(*Value, n);
            defer vm.gpa.free(rows);
            var made: usize = 0;
            defer for (rows[0..made]) |r| r.deref(vm.gpa);
            for (0..n) |i| {
                rows[made] = try q.operators.rowAt(vm, a, i);
                made += 1;
            }
            const row_list = if (n == 0) try vm.allocValue(.list, 0) else try vm.allocValue(.list, n);
            if (n > 0) for (row_list.as.list, rows) |*slot, r| {
                slot.* = r.ref();
            };
            defer row_list.deref(vm.gpa);
            const replaced = try vm.gpa.dupe(*Value, args);
            defer vm.gpa.free(replaced);
            for (replaced) |*r| if (r.* == a) {
                r.* = row_list;
            };
            return try each(vm, f, replaced);
        }
        first_dict = a;
    };
    const d = (first_dict orelse return null).as.dict;
    const n = d.keys.count();
    const results = try vm.gpa.alloc(*Value, n);
    defer vm.gpa.free(results);
    var done: usize = 0;
    defer for (results[0..done]) |r| r.deref(vm.gpa);
    const call = try vm.gpa.alloc(*Value, args.len);
    defer vm.gpa.free(call);
    for (0..n) |i| {
        const key = try itemAt(vm, d.keys, i);
        defer key.deref(vm.gpa);
        var made: usize = 0;
        defer for (call[0..made]) |c| c.deref(vm.gpa);
        for (args) |a| {
            call[made] = switch (a.as) {
                .dict => |other| if (try vm.keyPosition(other.keys, key)) |j| try itemAt(vm, other.values, j) else try q.operators.nullLike(vm, other.values),
                else => if (a.isList()) try itemAt(vm, a, i) else a.ref(),
            };
            made += 1;
        }
        results[done] = try vm.applyImpl(f, call);
        done += 1;
    }
    const values = if (n == 0) try vm.allocValue(.list, 0) else try vm.enlist(results);
    errdefer values.deref(vm.gpa);
    return try vm.createValue(.dict, .{ .keys = d.keys.ref(), .values = values });
}

fn commonLength(args: []*Value) error{length}!?usize {
    var len: ?usize = null;
    for (args) |a| {
        if (!a.isList()) continue;
        if (len) |n| {
            if (n != a.count()) return error.length;
        } else len = a.count();
    }
    return len;
}

pub fn over(vm: *Vm, f: *Value, args: []*Value) RunError!*Value {
    return fold(vm, f, args, false);
}

pub fn scan(vm: *Vm, f: *Value, args: []*Value) RunError!*Value {
    return fold(vm, f, args, true);
}

/// `f/` and `f\\`. A monadic `f` converges (`f/[x]`), repeats (`f/[n;x]`) or runs while a
/// condition holds (`f/[c;x]`); with two or more parameters `f` folds over the items of a
/// list, from its first item or from a seed, and with a seed over several lists in step.
/// `scan` keeps every intermediate value, the initial one included for a monadic `f`.
fn fold(vm: *Vm, f: *Value, args: []*Value, comptime keep: bool) RunError!*Value {
    if (args.len == 0) return error.rank;
    // A float on the left of `\` is q's weighted scan: `0.5\[1;1 2 3]` is `1.5 2.75 4.375`,
    // each item `n` times the one before plus itself, from the seed.
    if (f.as == .float or f.as == .real) {
        if (!keep or args.len != 2) return error.type;
        return weightedScan(vm, if (f.as == .float) f.as.float else f.as.real, args[0], args[1]);
    }
    // An over, scan or each-prior derived function is applied to one argument, so with a
    // count it repeats: `1 (+':)/1 2 3` is `1 3 5`.
    const monadic = f.rank() == 1 or switch (f.as) {
        .over, .scan, .each_prior => true,
        else => false,
    };
    if (monadic) {
        if (args.len == 1) return converge(vm, f, args[0], keep);
        if (args.len != 2) return error.rank;
        return repeat(vm, f, args[0], args[1], keep);
    }

    var results: std.ArrayList(*Value) = .empty;
    defer {
        for (results.items) |r| r.deref(vm.gpa);
        results.deinit(vm.gpa);
    }

    if (args.len == 1) {
        const x = args[0];
        // A dictionary folds over its values (`,/[()!()]` is `()`).
        if (x.as == .dict) {
            var values = [_]*Value{x.as.dict.values};
            return fold(vm, f, &values, keep);
        }
        if (!x.isList()) return x.ref();
        const n = x.count();
        if (n == 0) return if (keep) x.ref() else emptyFold(vm, f, x);
        var acc = try itemAt(vm, x, 0);
        defer acc.deref(vm.gpa);
        if (keep) try results.append(vm.gpa, acc.ref());
        for (1..n) |i| {
            const item = try itemAt(vm, x, i);
            defer item.deref(vm.gpa);
            var operands = [_]*Value{ acc, item };
            const next = try vm.applyImpl(f, &operands);
            acc.deref(vm.gpa);
            acc = next;
            if (keep) try results.append(vm.gpa, acc.ref());
        }
        return if (keep) vm.enlist(results.items) else acc.ref();
    }

    // A seed, then the items of the remaining arguments in step.
    const lists = args[1..];
    const n = try commonLength(lists) orelse 1;
    var acc = args[0].ref();
    defer acc.deref(vm.gpa);
    const call_args = try vm.gpa.alloc(*Value, args.len);
    defer vm.gpa.free(call_args);
    for (0..n) |i| {
        var made: usize = 1;
        defer for (call_args[1..made]) |a| a.deref(vm.gpa);
        call_args[0] = acc;
        for (lists, 1..) |a, k| {
            call_args[k] = if (a.isList()) try itemAt(vm, a, i) else a.ref();
            made += 1;
        }
        const next = try vm.applyImpl(f, call_args);
        acc.deref(vm.gpa);
        acc = next;
        if (keep) try results.append(vm.gpa, acc.ref());
    }
    // Joining nothing onto a seed still joins: `0,/()` is `,0`, as in q.
    if (n == 0 and !keep and lists.len == 1 and f.as == .operator and f.as.operator == .join) return q.operators.join(vm, acc, lists[0]);
    if (!keep) return acc.ref();
    return if (results.items.len == 0) vm.allocValue(.list, 0) else vm.enlist(results.items);
}

fn weightedScan(vm: *Vm, weight: f64, seed: *Value, x: *Value) RunError!*Value {
    if (seed.isList()) return error.rank;
    const start = numberOf(seed) orelse return error.type;
    if (!x.isList()) return error.type;
    const n = x.count();
    const result = try vm.allocValue(.float_list, n);
    errdefer result.deref(vm.gpa);
    var acc = start;
    for (result.as.float_list, 0..) |*r, i| {
        const item = try itemAt(vm, x, i);
        defer item.deref(vm.gpa);
        acc = weight * acc + (numberOf(item) orelse return error.type);
        r.* = acc;
    }
    return result;
}

fn numberOf(v: *Value) ?f64 {
    return switch (v.as) {
        .boolean => |b| @floatFromInt(@intFromBool(b)),
        .byte => |b| @floatFromInt(b),
        .short => |s| @floatFromInt(s),
        .int => |i| @floatFromInt(i),
        .long => |l| @floatFromInt(l),
        .real => |r| r,
        .float => |f| f,
        else => null,
    };
}

/// What a fold of an empty list gives: the identity of `+`, `*`, `&` and `|` (`0`, `1`,
/// `0W`, `-0W`, typed like the list for `+` and `*`), the list itself for `,`, and `()`
/// for anything else.
fn emptyFold(vm: *Vm, f: *Value, x: *Value) RunError!*Value {
    // Only a typed empty list has an identity to give; `+/[()]` stays `()`.
    if (x.as == .list or f.as != .operator) return vm.allocValue(.list, 0);
    return switch (f.as.operator) {
        .add => typedNumber(vm, x, 0),
        .multiply => typedNumber(vm, x, 1),
        .@"and" => vm.createValue(.long, @backingInt(Value.Long.inf)),
        .@"or" => vm.createValue(.long, @backingInt(Value.Long.neg_inf)),
        .join => x.ref(),
        else => vm.allocValue(.list, 0),
    };
}

/// A small number typed like the items of a list: `0i` for chars (which add as ints),
/// `0f` for floats, `0e` for reals, and a long otherwise; symbols cannot be added.
fn typedNumber(vm: *Vm, x: *Value, n: i64) RunError!*Value {
    return switch (x.as) {
        .char_list => vm.createValue(.int, @intCast(n)),
        .float_list => vm.createValue(.float, @floatFromInt(n)),
        .real_list => vm.createValue(.real, @floatFromInt(n)),
        .symbol_list => error.type,
        else => vm.createValue(.long, n),
    };
}

/// `f/[x]` for a monadic `f`: `f` is applied until the result matches the previous one or
/// the original argument. The scan keeps every value up to the one that repeats.
fn converge(vm: *Vm, f: *Value, x: *Value, comptime keep: bool) RunError!*Value {
    var results: std.ArrayList(*Value) = .empty;
    defer {
        for (results.items) |r| r.deref(vm.gpa);
        results.deinit(vm.gpa);
    }
    var current = x.ref();
    defer current.deref(vm.gpa);
    if (keep) try results.append(vm.gpa, current.ref());
    while (true) {
        var operand = [_]*Value{current};
        const next = try vm.applyImpl(f, &operand);
        if (next.eql(current) or next.eql(x)) {
            next.deref(vm.gpa);
            break;
        }
        current.deref(vm.gpa);
        current = next;
        if (keep) try results.append(vm.gpa, current.ref());
    }
    return if (keep) vm.enlist(results.items) else current.ref();
}

/// `f/[n;x]` applies `f` `n` times (a null or negative count not at all) and `f/[c;x]`
/// while the monadic function `c` holds of the value. The scan starts with `x`.
fn repeat(vm: *Vm, f: *Value, control: *Value, x: *Value, comptime keep: bool) RunError!*Value {
    var results: std.ArrayList(*Value) = .empty;
    defer {
        for (results.items) |r| r.deref(vm.gpa);
        results.deinit(vm.gpa);
    }
    var current = x.ref();
    defer current.deref(vm.gpa);
    if (keep) try results.append(vm.gpa, current.ref());
    var remaining: ?i64 = switch (control.as) {
        .long => |n| if (n == @backingInt(Value.Long.null)) 0 else n,
        .int => |n| if (n == @backingInt(Value.Int.null)) 0 else n,
        .lambda, .unary_primitive, .operator, .projection, .each, .over, .scan, .each_prior, .each_right, .each_left, .composition => null,
        else => return error.type,
    };
    while (true) {
        if (remaining) |*n| {
            if (n.* <= 0) break;
            n.* -= 1;
        } else {
            var operand = [_]*Value{current};
            const condition = try vm.applyImpl(control, &operand);
            defer condition.deref(vm.gpa);
            if (!try Vm.truthy(condition)) break;
        }
        var operand = [_]*Value{current};
        const next = try vm.applyImpl(f, &operand);
        current.deref(vm.gpa);
        current = next;
        if (keep) try results.append(vm.gpa, current.ref());
    }
    return if (keep) vm.enlist(results.items) else current.ref();
}

/// `f':[x]` applies `f` to each item and the one before it; the first item's predecessor
/// is the seed when one is given, and otherwise the identity of `+ - * % & |` typed like
/// the item, or a typed null, as q does.
pub fn prior(vm: *Vm, f: *Value, args: []*Value) RunError!*Value {
    // Each-prior of a monadic function is each: `{x*2}':[1 2 3]` is `2 4 6`.
    if (f.rank() == 1 and args.len == 1) return each(vm, f, args);
    const x, const seed: ?*Value = switch (args.len) {
        1 => .{ args[0], null },
        2 => .{ args[1], args[0] },
        else => return error.rank,
    };
    if (!x.isList()) {
        const previous = if (seed) |s| s.ref() else try firstPrevious(vm, f, x);
        defer previous.deref(vm.gpa);
        var operands = [_]*Value{ x, previous };
        return vm.applyImpl(f, &operands);
    }
    const n = x.count();
    if (n == 0) return vm.allocValue(.list, 0);
    const results = try vm.gpa.alloc(*Value, n);
    defer vm.gpa.free(results);
    var done: usize = 0;
    defer for (results[0..done]) |r| r.deref(vm.gpa);
    var previous = if (seed) |s| s.ref() else try firstPrevious(vm, f, x);
    defer previous.deref(vm.gpa);
    for (0..n) |i| {
        const item = try itemAt(vm, x, i);
        defer item.deref(vm.gpa);
        var operands = [_]*Value{ item, previous };
        results[done] = try vm.applyImpl(f, &operands);
        done += 1;
        previous.deref(vm.gpa);
        previous = item.ref();
    }
    return vm.enlist(results);
}

fn firstPrevious(vm: *Vm, f: *Value, x: *Value) RunError!*Value {
    const first = if (x.isList()) try itemAt(vm, x, 0) else x.ref();
    defer first.deref(vm.gpa);
    if (f.as == .operator) switch (f.as.operator) {
        .add, .subtract => return typedLike(vm, first, 0),
        .multiply, .divide => return typedLike(vm, first, 1),
        .@"and" => return vm.createValue(.long, @backingInt(Value.Long.inf)),
        .@"or" => return vm.createValue(.long, @backingInt(Value.Long.neg_inf)),
        else => {},
    };
    return q.operators.nullOfValue(vm, first);
}

/// `n` as an atom of the same type as `like`, or a long when `like` is not numeric.
fn typedLike(vm: *Vm, like: *Value, n: i64) RunError!*Value {
    return switch (like.as) {
        inline .boolean => vm.createValue(.boolean, n != 0),
        inline .byte, .short, .int, .long, .timestamp, .month, .date, .timespan, .minute, .second, .time => |_, tag| vm.createValue(tag, @intCast(n)),
        inline .real, .float, .datetime => |_, tag| vm.createValue(tag, @floatFromInt(n)),
        else => vm.createValue(.long, n),
    };
}

/// `x f/:y`: `f[x;]` applied to each item of `y`. With data instead of a function on the
/// left, `x/:y` is `sv`.
pub fn right(vm: *Vm, f: *Value, args: []*Value) RunError!*Value {
    if (!Vm.isFunction(f)) {
        if (args.len != 1) return error.rank;
        return q.operators.sv(vm, f, args[0]);
    }
    if (args.len != 2) return error.rank;
    return side(vm, f, args[0], args[1], false);
}

/// `x f\\:y`: `f[;y]` applied to each item of `x`. With data on the left, `x\\:y` is `vs`.
pub fn left(vm: *Vm, f: *Value, args: []*Value) RunError!*Value {
    if (!Vm.isFunction(f)) {
        if (args.len != 1) return error.rank;
        return q.operators.vs(vm, f, args[0]);
    }
    if (args.len != 2) return error.rank;
    return side(vm, f, args[0], args[1], true);
}

fn side(vm: *Vm, f: *Value, x: *Value, y: *Value, comptime over_left: bool) RunError!*Value {
    const iterated = if (over_left) x else y;
    if (!iterated.isList()) {
        var operands = [_]*Value{ x, y };
        return vm.applyImpl(f, &operands);
    }
    const n = iterated.count();
    if (n == 0) return vm.allocValue(.list, 0);
    const results = try vm.gpa.alloc(*Value, n);
    defer vm.gpa.free(results);
    var done: usize = 0;
    defer for (results[0..done]) |r| r.deref(vm.gpa);
    for (0..n) |i| {
        const item = try itemAt(vm, iterated, i);
        defer item.deref(vm.gpa);
        var operands = if (over_left) [_]*Value{ item, y } else [_]*Value{ x, item };
        results[done] = try vm.applyImpl(f, &operands);
        done += 1;
    }
    return vm.enlist(results);
}
