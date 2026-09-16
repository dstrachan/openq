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
    if (f.rank() == 1) {
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
    if (!keep) return acc.ref();
    return if (results.items.len == 0) vm.allocValue(.list, 0) else vm.enlist(results.items);
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
        .lambda, .unary_primitive, .operator, .projection, .each, .over, .scan, .each_prior, .each_right, .each_left => null,
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

/// `x f/:y`: `f[x;]` applied to each item of `y`.
pub fn right(vm: *Vm, f: *Value, args: []*Value) RunError!*Value {
    if (args.len != 2) return error.rank;
    return side(vm, f, args[0], args[1], false);
}

/// `x f\\:y`: `f[;y]` applied to each item of `x`.
pub fn left(vm: *Vm, f: *Value, args: []*Value) RunError!*Value {
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
