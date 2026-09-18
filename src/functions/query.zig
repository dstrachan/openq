//! qSQL: the functional forms `?[t;where;by;spec]` (select and exec) and
//! `![t;where;by;spec]` (update and delete), which the parse trees of the statements
//! evaluate to. The shapes and edge cases follow q 5.0 (checked against 4.0 as well):
//!
//! - `where` is a list of constraint trees, each evaluated over the rows the earlier
//!   ones kept; a boolean atom keeps all or no rows. `i` is the original row number.
//! - `by` decides the form: a boolean is `select` (`1b` for `distinct`), a dictionary of
//!   names to trees is `select ... by`, `()` is `exec`, and any other tree `exec ... by`.
//! - A `select` column whose tree applies one of q's aggregates (`.Q.a0`, which q.k fills
//!   with count, first, last, sum, ..., med) gives one row: when the first column is such
//!   an aggregate every column's value is enlisted; otherwise atoms are spread to the
//!   rows and a result of atoms alone is `rank`.
//! - A fifth argument limits the rows, a long `n` (the first `n`, the last `-n`, `0W` all)
//!   or `(start;count)`; a sixth is a tree whose value indexes the rows (`(>:;`a)` for
//!   `select[>a]`), applied before the limit.

const std = @import("std");

const q = @import("../root.zig");
const Vm = q.Vm;
const Value = q.Value;
const RunError = Vm.RunError;

/// A table to query: the table itself, the global a symbol names, or a keyed table
/// taken apart into its plain form and the count of its key columns.
const Source = struct {
    table: *Value,
    keys: usize,
    name: ?*Value,

    fn init(vm: *Vm, x: *Value) RunError!Source {
        var name: ?*Value = null;
        var value = x.ref();
        if (x.as == .symbol) {
            value.deref(vm.gpa);
            value = try vm.readGlobal(x.as.symbol);
            name = x;
        }
        errdefer value.deref(vm.gpa);
        if (value.as == .table) return .{ .table = value, .keys = 0, .name = name };
        if (value.as == .dict and value.as.dict.keys.as == .table) {
            const keys = value.as.dict.keys.as.table.keys.count();
            const plain = try q.operators.keyTable(vm, 0, value);
            value.deref(vm.gpa);
            return .{ .table = plain, .keys = keys, .name = name };
        }
        return error.type;
    }

    fn deinit(self: Source, vm: *Vm) void {
        self.table.deref(vm.gpa);
    }

    /// A result keyed again the way the source was.
    fn rekey(self: Source, vm: *Vm, table: *Value) RunError!*Value {
        if (self.keys == 0) return table.ref();
        return q.operators.keyTable(vm, @intCast(self.keys), table);
    }
};

/// The rows a where clause kept: the table of those rows and their original numbers,
/// null when every row is kept and the table is the source itself.
const Filtered = struct {
    table: *Value,
    positions: ?*Value,

    fn deinit(self: Filtered, vm: *Vm) void {
        self.table.deref(vm.gpa);
        if (self.positions) |p| p.deref(vm.gpa);
    }

    /// The original numbers of the rows `rows` (relative to the kept table) name.
    fn original(self: Filtered, vm: *Vm, rows: *Value) RunError!*Value {
        const positions = self.positions orelse return rows.ref();
        var args = [_]*Value{rows};
        return vm.indexList(positions, &args);
    }

    /// The rows `rows` of the kept table, with their original numbers.
    fn subset(self: Filtered, vm: *Vm, rows: *Value) RunError!Filtered {
        const table = try q.operators.tableRows(vm, self.table, rows);
        errdefer table.deref(vm.gpa);
        return .{ .table = table, .positions = try self.original(vm, rows) };
    }
};

/// The columns of a table as the environment for expressions, with `i` the row numbers.
fn environment(vm: *Vm, table: *Value, positions: ?*Value) RunError!*Value {
    const t = table.as.table;
    const columns = t.values.as.list;
    const names = try vm.allocValue(.symbol_list, columns.len + 1);
    errdefer names.deref(vm.gpa);
    @memcpy(names.as.symbol_list[0..columns.len], t.keys.as.symbol_list);
    names.as.symbol_list[columns.len] = try vm.intern("i");
    const values = try vm.allocValue(.list, columns.len + 1);
    errdefer {
        vm.gpa.free(values.as.list);
        vm.gpa.destroy(values);
    }
    const numbers = if (positions) |p| p.ref() else blk: {
        const n = Value.rows(t);
        const til = try vm.allocValue(.long_list, n);
        for (til.as.long_list, 0..) |*v, i| v.* = @intCast(i);
        break :blk til;
    };
    for (values.as.list[0..columns.len], columns) |*slot, c| slot.* = c.ref();
    values.as.list[columns.len] = numbers;
    return vm.createValue(.dict, .{ .keys = names, .values = values });
}

/// An expression tree evaluated with the table's columns in scope.
fn evalIn(vm: *Vm, table: *Value, positions: ?*Value, tree: *Value) RunError!*Value {
    const columns = try environment(vm, table, positions);
    defer columns.deref(vm.gpa);
    const saved = vm.columns;
    vm.columns = columns;
    defer vm.columns = saved;
    return vm.eval(tree);
}

/// A value stretched to `n` rows: an atom is repeated, a list must fit.
fn stretch(vm: *Vm, n: usize, value: *Value) RunError!*Value {
    if (value.isList()) {
        if (value.count() != n) return error.length;
        return value.ref();
    }
    const count = try vm.createValue(.long, @intCast(n));
    defer count.deref(vm.gpa);
    return q.operators.take(vm, count, value);
}

/// Whether a column tree applies one of q's aggregates (`.Q.a0`) at any depth; a quoted
/// constant (a one-item list) is not searched.
fn isAggregate(vm: *Vm, tree: *Value) RunError!bool {
    const aggregates = vm.readGlobal(try vm.intern(".Q.a0")) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer aggregates.deref(vm.gpa);
    if (aggregates.as != .list) return false;
    return applies(vm, tree, aggregates.as.list);
}

fn applies(vm: *Vm, tree: *Value, aggregates: []*Value) RunError!bool {
    if (tree.as == .list) {
        if (tree.as.list.len == 1) return false;
        for (tree.as.list) |item| if (try applies(vm, item, aggregates)) return true;
        return false;
    }
    if (tree.isList()) return false;
    for (aggregates) |a| if (try q.operators.matches(vm, a, tree)) return true;
    return false;
}

/// The rows a list of where trees keeps, each tree narrowing the table before the next.
fn filter(vm: *Vm, table: *Value, where: *Value) RunError!Filtered {
    if (where.as != .list) return error.type;
    var current: Filtered = .{ .table = table.ref(), .positions = null };
    errdefer current.deinit(vm);
    for (where.as.list) |tree| {
        const mask = try evalIn(vm, current.table, current.positions, tree);
        defer mask.deref(vm.gpa);
        const rows = switch (mask.as) {
            .boolean => |b| blk: {
                if (b) continue;
                break :blk try vm.allocValue(.long_list, 0);
            },
            .boolean_list => blk: {
                if (mask.count() != current.table.count()) return error.length;
                break :blk try q.unary_primitives.where(vm, mask);
            },
            else => return error.type,
        };
        defer rows.deref(vm.gpa);
        const narrowed = try current.subset(vm, rows);
        current.deinit(vm);
        current = narrowed;
    }
    return current;
}

/// The trees of a spec dictionary evaluated over a table, as a list of raw values.
fn columnValues(vm: *Vm, table: *Value, positions: ?*Value, spec: *Value) RunError!*Value {
    const trees = spec.as.dict.values;
    const n = trees.count();
    const values = try vm.allocValue(.list, n);
    var filled: usize = 0;
    errdefer {
        for (values.as.list[0..filled]) |v| v.deref(vm.gpa);
        vm.gpa.free(values.as.list);
        vm.gpa.destroy(values);
    }
    for (0..n) |k| {
        const tree = try q.operators.itemAt(vm, trees, k);
        defer tree.deref(vm.gpa);
        values.as.list[filled] = try evalIn(vm, table, positions, tree);
        filled += 1;
    }
    return values;
}

/// The columns of a `select`: one row of enlisted values when the first column
/// aggregates, otherwise the values with atoms spread (and `rank` for atoms alone).
fn selectColumns(vm: *Vm, table: *Value, positions: ?*Value, spec: *Value) RunError!*Value {
    const values = try columnValues(vm, table, positions, spec);
    defer values.deref(vm.gpa);
    const trees = spec.as.dict.values;
    const first = try q.operators.itemAt(vm, trees, 0);
    defer first.deref(vm.gpa);
    if (try isAggregate(vm, first)) {
        const wrapped = try vm.allocValue(.list, values.as.list.len);
        var filled: usize = 0;
        errdefer {
            for (wrapped.as.list[0..filled]) |v| v.deref(vm.gpa);
            vm.gpa.free(wrapped.as.list);
            vm.gpa.destroy(wrapped);
        }
        for (values.as.list) |v| {
            wrapped.as.list[filled] = try q.unary_primitives.enlist(vm, v);
            filled += 1;
        }
        defer wrapped.deref(vm.gpa);
        return q.operators.makeTable(vm, spec.as.dict.keys, wrapped);
    }
    return q.operators.makeTable(vm, spec.as.dict.keys, values);
}

/// Whether a spec asks for every column: `()` or an empty dictionary.
fn wantsAll(spec: *Value) bool {
    return (spec.as == .list and spec.as.list.len == 0) or (spec.as == .dict and spec.as.dict.keys.count() == 0);
}

/// `?[t;where;by;spec]`, with the optional limit and sort.
pub fn select(vm: *Vm, args: []*Value) RunError!*Value {
    if (args.len > 6) return error.rank;
    const source = try Source.init(vm, args[0]);
    defer source.deinit(vm);
    const filtered = try filter(vm, source.table, args[1]);
    defer filtered.deinit(vm);
    const by = args[2];
    const spec = args[3];
    const limit: ?*Value = if (args.len > 4) args[4] else null;
    const sort: ?*Value = if (args.len > 5) args[5] else null;
    switch (by.as) {
        .boolean => |distinct| {
            const all = wantsAll(spec);
            if (!all and spec.as != .dict) return error.type;
            var result = if (all) filtered.table.ref() else try selectColumns(vm, filtered.table, filtered.positions, spec);
            errdefer result.deref(vm.gpa);
            if (distinct) try replace(vm, &result, try distinctRows(vm, result));
            if (sort) |s| try replace(vm, &result, try sortRows(vm, result, s));
            if (limit) |n| try replace(vm, &result, try limitRows(vm, result, n));
            if (all and source.keys > 0) try replace(vm, &result, try source.rekey(vm, result));
            return result;
        },
        .dict => {
            // A tree spec with a dictionary `by` is an exec keyed by the key table.
            if (!wantsAll(spec) and spec.as != .dict) return execBy(vm, filtered, by, spec, limit, sort);
            return groupedSelect(vm, filtered, by, spec, limit, sort);
        },
        .list => |items| if (items.len == 0) return exec(vm, filtered, spec),
        else => {},
    }
    return execBy(vm, filtered, by, spec, limit, sort);
}

/// Replaces `current` by `next`, releasing the old value.
fn replace(vm: *Vm, current: **Value, next: *Value) RunError!void {
    current.*.deref(vm.gpa);
    current.* = next;
}

/// Distinct rows of a table, in order of first appearance.
fn distinctRows(vm: *Vm, table: *Value) RunError!*Value {
    const n = table.count();
    var kept: std.ArrayList(i64) = .empty;
    defer kept.deinit(vm.gpa);
    var rows: std.ArrayList(*Value) = .empty;
    defer rows.deinit(vm.gpa);
    defer for (rows.items) |r| r.deref(vm.gpa);
    for (0..n) |i| {
        const row = try q.operators.rowAt(vm, table, i);
        errdefer row.deref(vm.gpa);
        var seen = false;
        for (rows.items) |r| if (try q.operators.matches(vm, r, row)) {
            seen = true;
            break;
        };
        if (seen) {
            row.deref(vm.gpa);
            continue;
        }
        try rows.append(vm.gpa, row);
        try kept.append(vm.gpa, @intCast(i));
    }
    const positions = try vm.allocValue(.long_list, kept.items.len);
    defer positions.deref(vm.gpa);
    @memcpy(positions.as.long_list, kept.items);
    return q.operators.tableRows(vm, table, positions);
}

/// The rows of a table in the order a sort tree's value gives: `(>:;`a)` is `idesc a`,
/// and any long list will do, numbers past the end giving null rows.
fn sortRows(vm: *Vm, table: *Value, sort: *Value) RunError!*Value {
    const order = try evalIn(vm, table, null, sort);
    defer order.deref(vm.gpa);
    if (order.as != .long_list) return error.type;
    return q.operators.tableRows(vm, table, order);
}

/// The rows a limit keeps: a long `n` (negative from the end, `0W` all) or `(start;count)`.
fn limitRows(vm: *Vm, table: *Value, limit: *Value) RunError!*Value {
    switch (limit.as) {
        .long => |n| {
            if (n == @backingInt(Value.Long.inf)) return table.ref();
            if (n == @backingInt(Value.Long.null)) return error.type;
            return q.operators.take(vm, limit, table);
        },
        .long_list => |pair| {
            if (pair.len != 2 or pair[0] < 0 or pair[1] < 0) return error.type;
            const start = try vm.createValue(.long, pair[0]);
            defer start.deref(vm.gpa);
            const dropped = try q.operators.drop(vm, start, table);
            if (pair[1] == @backingInt(Value.Long.inf)) return dropped;
            defer dropped.deref(vm.gpa);
            const count = try vm.createValue(.long, pair[1]);
            defer count.deref(vm.gpa);
            return q.operators.take(vm, count, dropped);
        },
        else => return error.type,
    }
}

/// The groups of a table by the `by` trees: a key table of the distinct keys in
/// ascending order, and the rows (relative to the table) of each.
const Groups = struct {
    keys: *Value,
    rows: *Value,

    fn deinit(self: Groups, vm: *Vm) void {
        self.keys.deref(vm.gpa);
        self.rows.deref(vm.gpa);
    }
};

fn groups(vm: *Vm, filtered: Filtered, by: *Value) RunError!Groups {
    const table = filtered.table;
    const n = table.count();
    // The by values over every row, atoms spread.
    const raw = try columnValues(vm, table, filtered.positions, by);
    defer raw.deref(vm.gpa);
    const columns = try vm.allocValue(.list, raw.as.list.len);
    var filled: usize = 0;
    errdefer {
        for (columns.as.list[0..filled]) |c| c.deref(vm.gpa);
        vm.gpa.free(columns.as.list);
        vm.gpa.destroy(columns);
    }
    for (raw.as.list) |v| {
        columns.as.list[filled] = try stretch(vm, n, v);
        filled += 1;
    }
    defer columns.deref(vm.gpa);
    // The key of every row: the one column, or the rows of the key columns.
    const key_of_row = if (columns.as.list.len == 1) columns.as.list[0].ref() else try q.unary_primitives.flip(vm, columns);
    defer key_of_row.deref(vm.gpa);
    const grouped = try q.unary_primitives.group(vm, key_of_row);
    defer grouped.deref(vm.gpa);
    const distinct = grouped.as.dict.keys;
    const order = try q.unary_primitives.asc(vm, distinct);
    defer order.deref(vm.gpa);
    var order_args = [_]*Value{order};
    const sorted_keys = try vm.indexList(distinct, &order_args);
    defer sorted_keys.deref(vm.gpa);
    const rows = try vm.indexList(grouped.as.dict.values, &order_args);
    errdefer rows.deref(vm.gpa);
    // The key table, sorted: `s#` on it and on a lone column, `p#` on the first of several.
    const key_columns = if (columns.as.list.len == 1) blk: {
        const one = try vm.allocValue(.list, 1);
        one.as.list[0] = sorted_keys.ref();
        break :blk one;
    } else try q.unary_primitives.flip(vm, sorted_keys);
    defer key_columns.deref(vm.gpa);
    const keys = try q.operators.makeTable(vm, by.as.dict.keys, key_columns);
    errdefer keys.deref(vm.gpa);
    keys.attr = .s;
    const first_column = keys.as.table.values.as.list[0];
    if (first_column.count() > 0) first_column.attr = if (columns.as.list.len == 1) .s else .p;
    return .{ .keys = keys, .rows = rows };
}

/// The value of a tree over each group, as a column of one item per group; with no
/// groups the tree's value over the empty table cut to nothing, so the column is typed.
fn perGroup(vm: *Vm, filtered: Filtered, g: Groups, tree: ?*Value, column: ?usize) RunError!*Value {
    const n_groups = g.rows.count();
    if (n_groups == 0) {
        const value = if (tree) |t| try evalIn(vm, filtered.table, filtered.positions, t) else try q.operators.itemAt(vm, filtered.table.as.table.values, column.?);
        defer value.deref(vm.gpa);
        const zero = try vm.createValue(.long, 0);
        defer zero.deref(vm.gpa);
        return q.operators.take(vm, zero, value);
    }
    const cells = try vm.gpa.alloc(*Value, n_groups);
    defer vm.gpa.free(cells);
    var got: usize = 0;
    defer for (cells[0..got]) |c| c.deref(vm.gpa);
    for (0..n_groups) |k| {
        const rows = try q.operators.itemAt(vm, g.rows, k);
        defer rows.deref(vm.gpa);
        const subset = try filtered.subset(vm, rows);
        defer subset.deinit(vm);
        if (tree) |t| {
            cells[got] = try evalIn(vm, subset.table, subset.positions, t);
        } else {
            const values = try q.operators.itemAt(vm, subset.table.as.table.values, column.?);
            defer values.deref(vm.gpa);
            cells[got] = try q.unary_primitives.last(vm, values);
        }
        got += 1;
    }
    return vm.enlist(cells);
}

/// The value table of a `select ... by`: the spec's trees over each group, or without a
/// spec the last value of every column that is not a key.
fn groupedValues(vm: *Vm, filtered: Filtered, g: Groups, by: *Value, spec: *Value) RunError!*Value {
    const t = filtered.table.as.table;
    var names: *Value = undefined;
    var columns: *Value = undefined;
    if (wantsAll(spec)) {
        var kept: std.ArrayList(usize) = .empty;
        defer kept.deinit(vm.gpa);
        for (t.keys.as.symbol_list, 0..) |name, k| {
            if (std.mem.findScalar(Vm.Symbol, by.as.dict.keys.as.symbol_list, name) == null) try kept.append(vm.gpa, k);
        }
        names = try vm.allocValue(.symbol_list, kept.items.len);
        errdefer names.deref(vm.gpa);
        for (names.as.symbol_list, kept.items) |*slot, k| slot.* = t.keys.as.symbol_list[k];
        columns = try vm.allocValue(.list, kept.items.len);
        var filled: usize = 0;
        errdefer {
            for (columns.as.list[0..filled]) |c| c.deref(vm.gpa);
            vm.gpa.free(columns.as.list);
            vm.gpa.destroy(columns);
        }
        for (kept.items) |k| {
            columns.as.list[filled] = try perGroup(vm, filtered, g, null, k);
            filled += 1;
        }
    } else {
        names = spec.as.dict.keys.ref();
        errdefer names.deref(vm.gpa);
        const trees = spec.as.dict.values;
        columns = try vm.allocValue(.list, trees.count());
        var filled: usize = 0;
        errdefer {
            for (columns.as.list[0..filled]) |c| c.deref(vm.gpa);
            vm.gpa.free(columns.as.list);
            vm.gpa.destroy(columns);
        }
        for (0..trees.count()) |k| {
            const tree = try q.operators.itemAt(vm, trees, k);
            defer tree.deref(vm.gpa);
            columns.as.list[filled] = try perGroup(vm, filtered, g, tree, null);
            filled += 1;
        }
    }
    defer names.deref(vm.gpa);
    defer columns.deref(vm.gpa);
    return q.operators.makeTable(vm, names, columns);
}

/// `select ... by ...`: a keyed table from the groups to their values; a sort or limit
/// applies to the joined rows, and a limit alone keeps the key table sorted.
fn groupedSelect(vm: *Vm, filtered: Filtered, by: *Value, spec: *Value, limit: ?*Value, sort: ?*Value) RunError!*Value {
    const g = try groups(vm, filtered, by);
    defer g.deinit(vm);
    const values = try groupedValues(vm, filtered, g, by, spec);
    defer values.deref(vm.gpa);
    var keyed = try vm.createValue(.dict, .{ .keys = g.keys.ref(), .values = values.ref() });
    errdefer keyed.deref(vm.gpa);
    if (sort == null and limit == null) return keyed;
    var plain = try q.operators.keyTable(vm, 0, keyed);
    defer plain.deref(vm.gpa);
    if (sort) |s| try replace(vm, &plain, try sortRows(vm, plain, s));
    if (limit) |n| try replace(vm, &plain, try limitRows(vm, plain, n));
    try replace(vm, &keyed, try q.operators.keyTable(vm, @intCast(by.as.dict.keys.count()), plain));
    if (sort == null) keyed.as.dict.keys.attr = .s;
    return keyed;
}

/// `exec` without groups: a tree's value, a dictionary of values, or without a spec the
/// last row.
fn exec(vm: *Vm, filtered: Filtered, spec: *Value) RunError!*Value {
    if (spec.as == .list and spec.as.list.len == 0) return q.unary_primitives.last(vm, filtered.table);
    if (spec.as == .dict) {
        const values = try columnValues(vm, filtered.table, filtered.positions, spec);
        defer values.deref(vm.gpa);
        return vm.createValue(.dict, .{ .keys = spec.as.dict.keys.ref(), .values = values.ref() });
    }
    return evalIn(vm, filtered.table, filtered.positions, spec);
}

/// `exec ... by ...`: a dictionary from the sorted distinct keys (a list for one tree, a
/// key table for a dictionary of trees) to the spec's value per group, a table for a
/// dictionary of trees. A limit takes the first groups; a sort is not done (q crashes).
fn execBy(vm: *Vm, filtered: Filtered, by: *Value, spec: *Value, limit: ?*Value, sort: ?*Value) RunError!*Value {
    if (sort != null) return error.nyi;
    if (spec.as == .list and spec.as.list.len == 0) return error.nyi;
    const by_dict = if (by.as == .dict) by.ref() else try singleton(vm, by);
    defer by_dict.deref(vm.gpa);
    const g = try groups(vm, filtered, by_dict);
    defer g.deinit(vm);
    var keys = if (by.as == .dict) g.keys.ref() else g.keys.as.table.values.as.list[0].ref();
    defer keys.deref(vm.gpa);
    // The key list is sorted even when empty (`` (`s#`symbol$())!`long$() ``).
    if (by.as != .dict) keys.attr = .s;
    var values: *Value = undefined;
    if (spec.as == .dict) {
        values = try groupedValues(vm, filtered, g, by_dict, spec);
    } else {
        values = try perGroup(vm, filtered, g, spec, null);
    }
    defer values.deref(vm.gpa);
    if (limit) |n| {
        try replace(vm, &keys, try limitRows(vm, keys, n));
        try replace(vm, &values, try limitRows(vm, values, n));
        keys.attr = .s;
    }
    return vm.createValue(.dict, .{ .keys = keys.ref(), .values = values.ref() });
}

/// A one-entry dictionary from `x` to a tree, the shape `groups` takes.
fn singleton(vm: *Vm, tree: *Value) RunError!*Value {
    const name = try vm.allocValue(.symbol_list, 1);
    errdefer name.deref(vm.gpa);
    name.as.symbol_list[0] = try vm.intern("x");
    const trees = try vm.allocValue(.list, 1);
    errdefer trees.deref(vm.gpa);
    trees.as.list[0] = tree.ref();
    return vm.createValue(.dict, .{ .keys = name, .values = trees });
}

/// `![t;where;by;spec]`: `update` with a dictionary of columns (grouped when `by` is a
/// dictionary), `delete` of columns with a list of names and of rows with an empty symbol
/// list. A symbol names a global, which is replaced and given back as the result.
pub fn update(vm: *Vm, args: []*Value) RunError!*Value {
    const source = try Source.init(vm, args[0]);
    defer source.deinit(vm);
    const where = args[1];
    const by = args[2];
    const spec = args[3];
    var result: *Value = undefined;
    if (spec.as == .symbol_list and spec.count() == 0) {
        const filtered = try filter(vm, source.table, where);
        defer filtered.deinit(vm);
        // Deleting no rows gives the table itself back, attributes and all.
        if (filtered.positions) |p| if (p.count() == 0) return source.rekey(vm, source.table);
        const n = source.table.count();
        const mask = try vm.allocValue(.boolean_list, n);
        defer mask.deref(vm.gpa);
        @memset(mask.as.boolean_list, true);
        if (filtered.positions) |p| {
            for (p.as.long_list) |i| mask.as.boolean_list[@intCast(i)] = false;
        } else @memset(mask.as.boolean_list, false);
        const kept = try q.unary_primitives.where(vm, mask);
        defer kept.deref(vm.gpa);
        result = try q.operators.tableRows(vm, source.table, kept);
    } else if (spec.as == .symbol_list) {
        if (where.as != .list) return error.type;
        if (where.as.list.len > 0) return error.nyi;
        // Only names the table has are dropped.
        var present: std.ArrayList(Vm.Symbol) = .empty;
        defer present.deinit(vm.gpa);
        for (spec.as.symbol_list) |name| {
            if (std.mem.findScalar(Vm.Symbol, source.table.as.table.keys.as.symbol_list, name) != null) try present.append(vm.gpa, name);
        }
        const names = try vm.allocValue(.symbol_list, present.items.len);
        defer names.deref(vm.gpa);
        @memcpy(names.as.symbol_list, present.items);
        result = try q.operators.drop(vm, names, source.table);
    } else if (spec.as == .dict) {
        result = if (by.as == .dict) try groupedUpdate(vm, source.table, where, by, spec) else try rowUpdate(vm, source.table, where, spec);
    } else return error.type;
    defer result.deref(vm.gpa);
    const keyed = try source.rekey(vm, result);
    if (source.name) |name| {
        defer keyed.deref(vm.gpa);
        _ = try q.operators.assignGlobal(vm, name, keyed);
        return name.ref();
    }
    return keyed;
}

/// A table with one column replaced or, for a new name, appended.
fn withColumn(vm: *Vm, table: *Value, name: Vm.Symbol, column: *Value) RunError!*Value {
    const t = table.as.table;
    const existing = std.mem.findScalar(Vm.Symbol, t.keys.as.symbol_list, name);
    const n = t.values.as.list.len + @as(usize, if (existing == null) 1 else 0);
    const names = try vm.allocValue(.symbol_list, n);
    errdefer names.deref(vm.gpa);
    @memcpy(names.as.symbol_list[0..t.values.as.list.len], t.keys.as.symbol_list);
    const columns = try vm.allocValue(.list, n);
    errdefer {
        vm.gpa.free(columns.as.list);
        vm.gpa.destroy(columns);
    }
    for (columns.as.list[0..t.values.as.list.len], t.values.as.list) |*slot, c| slot.* = c.ref();
    if (existing) |k| {
        columns.as.list[k].deref(vm.gpa);
        columns.as.list[k] = column.ref();
    } else {
        names.as.symbol_list[n - 1] = name;
        columns.as.list[n - 1] = column.ref();
    }
    defer names.deref(vm.gpa);
    defer columns.deref(vm.gpa);
    return q.operators.makeTable(vm, names, columns);
}

/// The column `name` of a table, or a column of nulls shaped like `like` for a new name.
fn baseColumn(vm: *Vm, table: *Value, name: Vm.Symbol, like: *Value) RunError!*Value {
    const t = table.as.table;
    if (std.mem.findScalar(Vm.Symbol, t.keys.as.symbol_list, name)) |k| return t.values.as.list[k].ref();
    const null_item = try q.operators.nullLike(vm, like);
    defer null_item.deref(vm.gpa);
    return stretch(vm, table.count(), null_item);
}

/// A column with `values` written at the rows `positions`.
fn writeRows(vm: *Vm, column: *Value, positions: *Value, values: *Value) RunError!*Value {
    const index = try vm.allocValue(.list, 1);
    defer index.deref(vm.gpa);
    index.as.list[0] = positions.ref();
    const assign = vm.getOperator(.assign);
    defer assign.deref(vm.gpa);
    return vm.amendValue(column, index, assign, values);
}

/// `update`: each column expression evaluated over the rows the where clause keeps and
/// written back at those rows; a new column starts as nulls; an atom is spread.
fn rowUpdate(vm: *Vm, table: *Value, where: *Value, spec: *Value) RunError!*Value {
    const filtered = try filter(vm, table, where);
    defer filtered.deinit(vm);
    const values = try columnValues(vm, filtered.table, filtered.positions, spec);
    defer values.deref(vm.gpa);
    var result = table.ref();
    errdefer result.deref(vm.gpa);
    for (spec.as.dict.keys.as.symbol_list, values.as.list) |name, value| {
        const fitted = try stretch(vm, filtered.table.count(), value);
        defer fitted.deref(vm.gpa);
        const column = if (filtered.positions) |positions| blk: {
            const base = try baseColumn(vm, result, name, fitted);
            defer base.deref(vm.gpa);
            break :blk try writeRows(vm, base, positions, fitted);
        } else fitted.ref();
        defer column.deref(vm.gpa);
        try replace(vm, &result, try withColumn(vm, result, name, column));
    }
    return result;
}

/// `update ... by ...`: each column expression evaluated over every group and its
/// value spread to the group's rows.
fn groupedUpdate(vm: *Vm, table: *Value, where: *Value, by: *Value, spec: *Value) RunError!*Value {
    const filtered = try filter(vm, table, where);
    defer filtered.deinit(vm);
    const g = try groups(vm, filtered, by);
    defer g.deinit(vm);
    var result = table.ref();
    errdefer result.deref(vm.gpa);
    const trees = spec.as.dict.values;
    for (spec.as.dict.keys.as.symbol_list, 0..) |name, k| {
        const tree = try q.operators.itemAt(vm, trees, k);
        defer tree.deref(vm.gpa);
        var column: ?*Value = null;
        defer if (column) |c| c.deref(vm.gpa);
        for (0..g.rows.count()) |group| {
            const rows = try q.operators.itemAt(vm, g.rows, group);
            defer rows.deref(vm.gpa);
            const subset = try filtered.subset(vm, rows);
            defer subset.deinit(vm);
            const value = try evalIn(vm, subset.table, subset.positions, tree);
            defer value.deref(vm.gpa);
            const fitted = try stretch(vm, subset.table.count(), value);
            defer fitted.deref(vm.gpa);
            const fresh = column == null;
            const base = column orelse try baseColumn(vm, result, name, fitted);
            defer if (fresh) base.deref(vm.gpa);
            const written = try writeRows(vm, base, subset.positions.?, fitted);
            if (column) |c| c.deref(vm.gpa);
            column = written;
        }
        if (column) |c| try replace(vm, &result, try withColumn(vm, result, name, c));
    }
    return result;
}
