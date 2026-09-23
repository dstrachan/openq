const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const q = @import("root.zig");
const Ast = q.Ast;
const Node = Ast.Node;
const Value = q.Value;
pub const Symbol = Value.Symbol;
const UnaryPrimitive = Value.UnaryPrimitive;
const Operator = Value.Operator;
const Iterator = Value.Iterator;
const Compiler = q.Compiler;

const Vm = @This();

const Error = Allocator.Error || std.fmt.ParseIntError || Io.Writer.Error || error{
    parse,
    nyi,
    assign,
    length,
};
pub const RunError = Error || std.zig.ErrorBundle.RenderToStderrError || error{
    assign,
    domain,
    identifier,
    length,
    limit,
    nyi,
    os,
    parse,
    rank,
    signal,
    type,
};

io: Io,
gpa: Allocator,
stdout: *Io.Writer,
tree: *const Ast = undefined,
string_bytes: std.ArrayList(u8) = .empty,
string_table: std.HashMapUnmanaged(
    u32,
    void,
    std.hash_map.StringIndexContext,
    std.hash_map.default_max_load_percentage,
) = .empty,
stack: std.ArrayList(*Value) = .empty,
constants: [@typeInfo(Constant).@"enum".field_names.len]*Value = undefined,
unary_primitives: [@typeInfo(UnaryPrimitive).@"enum".field_names.len]*Value = undefined,
operators: [@typeInfo(Operator).@"enum".field_names.len]*Value = undefined,
iterators: [@typeInfo(Iterator).@"enum".field_names.len]*Value = undefined,
state: *Value = undefined,
/// The current namespace set by `\d`, as an interned path such as `.` or `.Q`.
namespace: Symbol = .empty,
/// Significant digits shown for floats, set by `\P`; 0 means the full 17.
precision: u8 = 7,
/// The time zone of `.z.P` and the other local clock variables, read once at init.
local_zone: q.clock.LocalZone = .utc,
/// The text of the last `'x` signal, which `error.signal` reports.
signal_message: ?[]u8 = null,
/// The seed `\S` shows and sets, and the generator roll and deal draw from. q's own
/// generator is not reproduced, so the numbers differ from q's for the same seed.
seed: i32 = -314159,
random: std.Random.Xoshiro256 = .init(@bitCast(@as(i64, -314159))),
/// The columns a query is evaluating its expressions over, `i` included, which a symbol
/// in a parse tree reads before any global; null outside a query.
columns: ?*Value = null,
/// The lambda a query is running inside, whose parameters and locals its expressions
/// read before globals, which resolve in the lambda's namespace; null at the top level.
scope: ?Scope = null,
/// The environment `getenv` reads and `setenv` writes: the process's own, copied in by
/// `main`, and empty in tests.
environ: std.process.Environ.Map,
/// The console size `\c` (rows, columns) and the web console size `\C`.
console: [2]i32 = .{ 25, 80 },
console_web: [2]i32 = .{ 36, 2000 },
/// The settings `\e`, `\g`, `\o`, `\t`, `\T`, `\W` and `\z` hold, as q shows them.
error_trap: i32 = 0,
gc_mode: i32 = 0,
utc_offset: i32 = @backingInt(Value.Int.null),
timer: i32 = 0,
timeout: i32 = 0,
week_offset: i32 = 2,
date_format: i32 = 0,
/// Open file handles by their number, which `hopen` gives out and `hclose` takes back.
handles: std.AutoArrayHashMapUnmanaged(i32, Io.File) = .empty,
/// The script `.z.f` names and the arguments `.z.x` lists, set by `main`; `.z.q` is the
/// quiet flag.
script: Symbol = .empty,
arguments: ?*Value = null,
quiet: bool = false,

pub const Scope = struct {
    lambda: *const Value.Lambda,
    slots: []?*Value,
};

const Constant = enum(u8) {
    empty_list,
    zero,
    one,
    semicolon,
    null_symbol,
};

/// What a new VM loads: q.k found as q finds it (`$QHOME/q.k`, else `q.k` in the
/// working directory), a given script, or nothing for tools that load it themselves.
pub const Startup = union(enum) {
    find,
    path: []const u8,
    none,
};

pub const Options = struct {
    startup: Startup = .find,
    /// The environment, for `QHOME` and `getenv`; empty when null.
    environ: ?*const std.process.Environ.Map = null,
};

/// A VM with q.k loaded from the working directory, as tests and tools start one.
pub fn init(io: Io, gpa: Allocator, stdout: *Io.Writer) !*Vm {
    return initOptions(io, gpa, stdout, .{});
}

pub fn initOptions(io: Io, gpa: Allocator, stdout: *Io.Writer, options: Options) !*Vm {
    const vm = try gpa.create(Vm);
    errdefer gpa.destroy(vm);
    vm.* = .{
        .io = io,
        .gpa = gpa,
        .stdout = stdout,
        .environ = .init(gpa),
    };
    errdefer vm.environ.deinit();
    errdefer vm.string_table.deinit(gpa);
    errdefer vm.string_bytes.deinit(gpa);

    var constants_created: usize = 0;
    errdefer for (0..constants_created) |i| vm.constants[i].deref(vm.gpa);
    vm.constants[@backingInt(Constant.empty_list)] = try vm.allocValue(.list, 0);
    constants_created += 1;
    vm.constants[@backingInt(Constant.zero)] = try vm.createValue(.long, 0);
    constants_created += 1;
    vm.constants[@backingInt(Constant.one)] = try vm.createValue(.long, 1);
    constants_created += 1;
    vm.constants[@backingInt(Constant.semicolon)] = try vm.createValue(.char, ';');
    constants_created += 1;
    vm.constants[@backingInt(Constant.null_symbol)] = try vm.createValue(.symbol, try vm.intern(""));
    constants_created += 1;
    // The empty symbol must be interned first so that `Symbol.empty` names it.
    assert(vm.constants[@backingInt(Constant.null_symbol)].as.symbol == .empty);
    vm.namespace = try vm.intern(".");
    assert(vm.namespace == .dot);

    var unary_primitives_created: usize = 0;
    errdefer for (0..unary_primitives_created) |i| vm.unary_primitives[i].deref(vm.gpa);
    inline for (&vm.unary_primitives, 0..) |*unary_primitive, i| {
        unary_primitive.* = try vm.createValue(.unary_primitive, @fromBackingInt(@intCast(i)));
        unary_primitives_created += 1;
    }

    var operators_created: usize = 0;
    errdefer for (0..operators_created) |i| vm.operators[i].deref(vm.gpa);
    inline for (&vm.operators, 0..) |*operator, i| {
        operator.* = try vm.createValue(.operator, @fromBackingInt(@intCast(i)));
        operators_created += 1;
    }

    var iterators_created: usize = 0;
    errdefer for (0..iterators_created) |i| vm.iterators[i].deref(vm.gpa);
    inline for (&vm.iterators, 0..) |*iterator, i| {
        iterator.* = try vm.createValue(.iterator, @fromBackingInt(@intCast(i)));
        iterators_created += 1;
    }

    const keys = try vm.allocValue(.symbol_list, 1);
    defer keys.deref(gpa);
    keys.as.symbol_list[0] = .empty;

    vm.state = state: {
        const global_state = global_state: {
            const values = try vm.allocValue(.list, 1);
            values.as.list[0] = vm.getUnaryPrimitive(.identity);
            errdefer values.deref(gpa);

            const dict = try vm.createValue(.dict, .{ .keys = keys, .values = values });
            errdefer comptime unreachable;
            _ = dict.as.dict.keys.ref();
            break :global_state dict;
        };
        defer global_state.deref(gpa);

        const values = try vm.allocValue(.list, 1);
        values.as.list[0] = global_state.ref();
        errdefer values.deref(gpa);

        const dict = try vm.createValue(.dict, .{ .keys = keys, .values = values });
        errdefer comptime unreachable;
        _ = dict.as.dict.keys.ref();
        break :state dict;
    };
    errdefer vm.state.deref(gpa);

    // `.z` exists from the start so that `.z.ph:...` and friends have somewhere to go; the
    // clock variables are computed on every read rather than stored in it.
    _ = try vm.namespaceAt(".z", true);

    vm.local_zone = .load(io, gpa);
    errdefer vm.local_zone.deinit();
    if (options.environ) |environ| try vm.environ.putAll(environ);

    // Nothing of the q language is built in beyond the k primitives: the keywords, `.Q`,
    // `.h` and `.j` all come from the real q.k, loaded now as q loads it at startup.
    switch (options.startup) {
        .none => {},
        .path => |path| {
            const loaded = try vm.loadScript(path);
            loaded.deref(gpa);
        },
        .find => {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const path = if (vm.environ.get("QHOME")) |home| std.fmt.bufPrint(&buffer, "{s}/q.k", .{home}) catch return error.QkNotFound else "q.k";
            const loaded = vm.loadScript(path) catch |err| switch (err) {
                error.signal => return error.QkNotFound,
                else => return err,
            };
            loaded.deref(gpa);
        },
    }
    return vm;
}

/// The projection `n!`, which is how q.k defines `parse` (`-5!`) and `eval` (`-6!`).
pub fn internalFunction(vm: *Vm, n: i64) !*Value {
    const args = try vm.gpa.alloc(*Value, 1);
    errdefer vm.gpa.free(args);
    args[0] = try vm.createValue(.long, n);
    errdefer args[0].deref(vm.gpa);
    const callee = vm.getOperator(.dict);
    errdefer callee.deref(vm.gpa);
    return vm.createValue(.projection, .{ .callee = callee, .args = args });
}

/// The parser's view of `.q`, so that q resolves keywords the way kdb+ does.
pub fn resolver(vm: *Vm) Ast.Resolver {
    return .{ .context = vm, .valence = qValence };
}

/// The valence the parser gives a `.q` keyword: two makes it infix. A dyadic lambda, an
/// operator, a projection with two left to fill and an each of a dyadic function are
/// infix (`x mmu y`, `x f' y`), while over, scan, each-prior, each-right and each-left
/// parse as monadic whatever they can take, so `prev prev x` nests and `sums x` applies.
fn qValence(context: *anyopaque, name: []const u8) ?usize {
    const vm: *Vm = @ptrCast(@alignCast(context));
    const entry = vm.qEntry(name) orelse return null;
    return switch (entry.as) {
        .over, .scan, .each_prior, .each_right, .each_left => 1,
        else => entry.rank(),
    };
}

/// The `.q` entry called `name`, borrowed, or null when there is none.
pub fn qEntry(vm: *Vm, name: []const u8) ?*Value {
    const symbol = vm.lookupSymbol(name) orelse return null;
    const namespace = (vm.namespaceAt(".q", false) catch return null) orelse return null;
    const dict = namespace.as.dict;
    const index = std.mem.findScalar(Symbol, dict.keys.as.symbol_list, symbol) orelse return null;
    return dict.values.as.list[index];
}

pub fn deinit(vm: *Vm) void {
    if (vm.signal_message) |message| vm.gpa.free(message);
    vm.environ.deinit();
    for (vm.handles.values()) |file| file.close(vm.io);
    vm.handles.deinit(vm.gpa);
    if (vm.arguments) |a| a.deref(vm.gpa);
    vm.local_zone.deinit();
    vm.string_table.deinit(vm.gpa);
    vm.string_bytes.deinit(vm.gpa);
    vm.state.deref(vm.gpa);
    for (vm.constants) |v| v.deref(vm.gpa);
    for (vm.unary_primitives) |v| v.deref(vm.gpa);
    for (vm.operators) |v| v.deref(vm.gpa);
    for (vm.iterators) |v| v.deref(vm.gpa);
    assert(vm.stack.items.len == 0);
    vm.stack.deinit(vm.gpa);
    vm.gpa.destroy(vm);
}

pub fn getConstant(vm: *Vm, constant: Constant) *Value {
    return vm.constants[@backingInt(constant)].ref();
}

pub fn getUnaryPrimitive(vm: *Vm, unary_primitive: UnaryPrimitive) *Value {
    return vm.unary_primitives[@backingInt(unary_primitive)].ref();
}

pub fn getOperator(vm: *Vm, operator: Operator) *Value {
    return vm.operators[@backingInt(operator)].ref();
}

pub fn getIterator(vm: *Vm, iterator: Iterator) *Value {
    return vm.iterators[@backingInt(iterator)].ref();
}

fn parseTree(vm: *Vm, tree: *const Ast) !*Value {
    vm.tree = tree;
    return vm.parseNode(.root);
}

pub fn evalTree(vm: *Vm, tree: *const Ast) !*Value {
    const value = try vm.parseTree(tree);
    defer value.deref(vm.gpa);
    return vm.eval(value);
}

fn push(vm: *Vm, value: *Value) void {
    vm.stack.append(vm.gpa, value) catch @panic("oom");
}

pub fn applyImpl(vm: *Vm, func: *Value, args: []*Value) RunError!*Value {
    assert(args.len > 0);
    switch (func.as) {
        // An int is a handle: `1 "text"` prints, `h "text"` appends to a file.
        .int, .long => return if (args.len == 1) q.files.write(vm, func, args[0]) else error.type,
        .boolean,
        .byte,
        .short,
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
        => return error.type,
        // A symbol names a global: `` `a 1 `` indexes `a` and `` `f 2 `` calls `f`.
        .symbol => |name| {
            const target = try vm.readGlobal(name);
            defer target.deref(vm.gpa);
            return vm.applyImpl(target, args);
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
        => return vm.indexList(func, args),
        .dict => return vm.indexDict(func, args),
        .table => return vm.indexTable(func, args),
        .lambda => return vm.callLambda(func, args),
        .unary_primitive => |unary_primitive| {
            if (unary_primitive == .enlist and args.len > 1) return vm.enlist(args);
            if (args.len > 1) return error.rank;
            switch (unary_primitive) {
                ._unused => unreachable,
                .empty => return q.unary_primitives.identity(vm, args[0]),
                inline else => |t| return @field(q.unary_primitives, @tagName(t))(vm, args[0]),
            }
        },
        .operator => |operator| {
            if (args.len > 2) {
                // `?[c;a;b]` is the vector conditional; the functional qSQL forms of `?` and
                // `!` with four arguments are not done yet.
                // Holes project whatever the count (`?[;;;]`, `@[1;;;;]`); the functional
                // qSQL forms of `?` and `!` on a table are not done, and on anything else
                // are `type`, while `!` with three or five arguments is `rank`, as in q.
                for (args) |a| if (a.isEmpty()) return vm.project(func, args);
                const tabular = args[0].as == .table or args[0].as == .symbol or (args[0].as == .dict and args[0].as.dict.keys.as == .table);
                if (operator == .find) {
                    if (args.len == 3) return q.operators.vectorConditional(vm, args[0], args[1], args[2]);
                    return if (tabular) q.query.select(vm, args) else error.type;
                }
                if (operator == .dict) {
                    if (args.len != 4) return error.rank;
                    return if (tabular) q.query.update(vm, args) else error.type;
                }
                // Only `.` and `@` take more: their amend and trap forms.
                if (operator != .apply and operator != .apply_at) return error.rank;
                if (args.len > 4) return error.rank;
                return vm.applyForm(operator, args);
            }
            if (args.len == 1) {
                var values: std.ArrayList(*Value) = try .initCapacity(vm.gpa, 1);
                defer values.deinit(vm.gpa);
                errdefer for (values.items) |v| v.deref(vm.gpa);

                values.appendAssumeCapacity(args[0].ref());

                const callee = func.ref();
                errdefer callee.deref(vm.gpa);

                return vm.createValue(.projection, .{
                    .callee = callee,
                    .args = values.toOwnedSliceAssert(),
                });
            }

            const is_first_empty = args[0].isEmpty();
            const is_second_empty = args[1].isEmpty();
            if (is_first_empty and is_second_empty) {
                return func.ref();
            } else if (is_first_empty or is_second_empty) {
                var values: std.ArrayList(*Value) = try .initCapacity(vm.gpa, 2);
                defer values.deinit(vm.gpa);
                errdefer for (values.items) |v| v.deref(vm.gpa);

                values.appendAssumeCapacity(args[0].ref());
                values.appendAssumeCapacity(args[1].ref());

                const callee = func.ref();
                errdefer callee.deref(vm.gpa);

                return vm.createValue(.projection, .{
                    .callee = callee,
                    .args = values.toOwnedSliceAssert(),
                });
            } else {
                switch (operator) {
                    inline else => |t| return @field(q.operators, @tagName(t))(vm, args[0], args[1]),
                }
            }
        },
        .iterator => |iterator| {
            // An iterator applied to a function makes the derived function; `'[f;g]` with
            // two arguments is the composition, or just `f g` when `g` is not a function.
            if (args.len == 2 and iterator == .each) {
                if (!isFunction(args[1])) return vm.applyImpl(args[0], args[1..]);
                const f = args[0].ref();
                errdefer f.deref(vm.gpa);
                const g = args[1].ref();
                errdefer g.deref(vm.gpa);
                return vm.createValue(.composition, .{ .f = f, .g = g });
            }
            if (args.len != 1) return error.rank;
            return vm.derive(iterator, args[0]);
        },
        .composition => |c| {
            // A hole projects the composition, and so do too few arguments for the right
            // function, which shows as its result being a projection: `(-+)[1]` is `-+[1]`,
            // while `(-+/) 1 2 3` folds and negates.
            for (args) |a| if (a.isEmpty()) return vm.project(func, args);
            const inner = try vm.applyImpl(c.g, args);
            defer inner.deref(vm.gpa);
            if (inner.as == .projection) return vm.project(func, args);
            var one = [_]*Value{inner};
            return vm.applyImpl(c.f, &one);
        },
        .projection => |projection| {
            // A projection of `enlist` has as many slots as it was given: `enlist[;5] 1` is
            // `1 5`, `enlist[;;5][1;2]` is `1 2 5` and `enlist[;5][1;2]` is a rank error.
            const variadic = projection.callee.as == .unary_primitive and projection.callee.as.unary_primitive == .enlist;
            const four = projection.callee.as == .operator and switch (projection.callee.as.operator) {
                .apply, .apply_at, .find, .dict => true,
                else => false,
            };
            const rank: usize = if (variadic) projection.args.len else if (four) 4 else projection.callee.rank();
            const holes = holes: {
                var n: usize = 0;
                for (projection.args) |a| n += @intFromBool(a.isEmpty());
                break :holes n;
            };
            // Fewer arguments than holes, or arguments with holes of their own, make a
            // projection of the projection, as q does: `{x+y+z}[;;3][1]` stays
            // `{x+y+z}[;;3][1]` and applies its holes left to right when called again.
            // `.`, `@`, `?` and `!` apply with two arguments and take three or four for
            // their amend, trap, conditional and functional forms.
            const flexible = projection.callee.as == .operator and switch (projection.callee.as.operator) {
                .apply, .apply_at, .find, .dict => true,
                else => false,
            };
            const min_rank: usize = if (flexible) 2 else rank;
            const args_len = projection.args.len - holes + args.len;
            if (args.len < holes or args_len < min_rank) return vm.project(func, args);
            for (args) |a| if (a.isEmpty()) return vm.project(func, args);
            if (args_len > rank) return error.rank;

            var new_args: std.ArrayList(*Value) = try .initCapacity(vm.gpa, args_len);
            defer new_args.deinit(vm.gpa);

            var j: usize = 0;
            for (0..args_len) |i| {
                if (i < projection.args.len) {
                    if (projection.args[i].isEmpty()) {
                        new_args.appendAssumeCapacity(args[j]);
                        j += 1;
                    } else {
                        new_args.appendAssumeCapacity(projection.args[i]);
                    }
                } else {
                    new_args.appendAssumeCapacity(args[j]);
                    j += 1;
                }
            }

            return vm.applyImpl(projection.callee, new_args.items);
        },
        .each, .over, .scan, .each_prior, .each_right, .each_left => {
            // A hole projects the derived function, as `f/[;x]` does in q, and so do too
            // few arguments for an each (`(+')[1]` is `+'[1]`), an each-right or an
            // each-left, while over, scan and each-prior take one.
            for (args) |a| if (a.isEmpty()) return vm.project(func, args);
            const short = switch (func.as) {
                // `.`, `@`, `?` and `!` apply with two: `(@')[d;`a`b]` is not a projection.
                .each => |d| args.len < minRank(d.value),
                // With data on the left (`" "\:x`) one argument is the whole application.
                inline .each_right, .each_left => |d| isFunction(d.value) and args.len < 2 and d.value.rank() >= 2,
                else => false,
            };
            if (short) return vm.project(func, args);
            // A monadic function under each-right or each-left given one argument is `type`.
            switch (func.as) {
                inline .each_right, .each_left => |d| if (isFunction(d.value) and args.len < 2) return error.type,
                else => {},
            }
            return switch (func.as) {
                .each => |d| q.iterators.each(vm, d.value, args),
                .over => |d| q.iterators.over(vm, d.value, args),
                .scan => |d| q.iterators.scan(vm, d.value, args),
                .each_prior => |d| q.iterators.prior(vm, d.value, args),
                .each_right => |d| q.iterators.right(vm, d.value, args),
                .each_left => |d| q.iterators.left(vm, d.value, args),
                else => unreachable,
            };
        },
    }
}

/// `@` and `.` with three or four arguments. With a function first they are the traps
/// `@[f;x;h]` and `.[f;args;h]`: `f` is applied and, when it fails, the handler is applied
/// to the error's text or, if it is not a function, returned as it is. Otherwise they amend:
/// `@[x;i;f]`, `@[x;i;f;y]`, `.[x;i;f]` and `.[x;i;f;y]`, `@` indexing one level and `.`
/// taking one index per dimension; a symbol `x` names a global, which is amended in place
/// and whose name is returned.
fn applyForm(vm: *Vm, operator: Operator, args: []*Value) RunError!*Value {
    const deep = operator == .apply;
    if (isFunction(args[0])) {
        if (args.len != 3) return error.rank;
        const f = args[0];
        const handler = args[2];
        return (if (deep) q.operators.apply(vm, f, args[1]) else q.operators.apply_at(vm, f, args[1])) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                if (!isFunction(handler)) return handler.ref();
                const text = try vm.errorText(err);
                defer text.deref(vm.gpa);
                var one = [_]*Value{text};
                return vm.applyImpl(handler, &one);
            },
        };
    }

    const x = args[0];
    const function = args[2];
    const value: ?*Value = if (args.len == 4) args[3] else null;
    // `@` indexes one level, so its index is a one-item index list.
    const index = if (deep) args[1].ref() else one: {
        const list = try vm.allocValue(.list, 1);
        list.as.list[0] = args[1].ref();
        break :one list;
    };
    defer index.deref(vm.gpa);
    if (x.as != .symbol) return vm.amendValue(x, index, function, value);

    const plain = function.as == .operator and function.as.operator == .assign and index.count() == 0 and value != null;
    // `.[`:path;();:;v]` is how q.k's `set` writes a file; other amends of a file are `type`.
    if (q.files.isFileSymbol(vm, x)) return if (plain) q.files.set(vm, x, value.?) else error.type;
    const new_value = if (plain) value.?.ref() else amended: {
        const old = try vm.readGlobal(x.as.symbol);
        defer old.deref(vm.gpa);
        break :amended try vm.amendValue(old, index, function, value);
    };
    defer new_value.deref(vm.gpa);
    _ = try q.operators.assignGlobal(vm, x, new_value);
    return x.ref();
}

/// The text a trap handler receives: the signalled message, or the error's name, which
/// matches q's for `rank`, `type`, `length` and `domain`.
pub fn errorText(vm: *Vm, err: RunError) Allocator.Error!*Value {
    const text = if (err == error.signal or err == error.identifier) (vm.signal_message orelse @errorName(err)) else @errorName(err);
    const value = try vm.allocValue(.char_list, text.len);
    @memcpy(value.as.char_list, text);
    return value;
}

/// The parse trees of the qSQL statements as q builds them: `select` is
/// `(?;t;where;by;aggregates[;n[;sort]])` with `where` a list of trees or `()`, `by` `0b`,
/// `1b` for `distinct` or a dictionary of names to trees, and the aggregates a dictionary
/// of names to trees or `()` for all columns; `exec` is `(?;t;where;by;spec)` with `by`
/// `()` or the enlisted tree and `spec` the enlisted tree or a dictionary; `update` is
/// `(!;t;where;0b;dictionary)`; `delete` of rows `(!;t;where;0b;`symbol$())` and of columns
/// `(!;t;();0b;,names)`.
pub fn queryTree(vm: *Vm, node: Node.Index) Error!*Value {
    const tree = vm.tree;
    const tag = tree.nodeTag(node);
    var items: std.ArrayList(*Value) = .empty;
    defer items.deinit(vm.gpa);
    errdefer for (items.items) |v| v.deref(vm.gpa);
    if (tag == .delete_cols) {
        const spans = tree.extraData(tree.nodeData(node).extra, Node.DeleteCols);
        const names = tree.extraDataSlice(.{ .start = spans.select_start, .end = spans.select_end }, Node.Index);
        try items.append(vm.gpa, vm.getOperator(.dict));
        try items.append(vm.gpa, try vm.parseNode(spans.from));
        try items.append(vm.gpa, vm.getConstant(.empty_list));
        try items.append(vm.gpa, try vm.createValue(.boolean, false));
        const list = try vm.allocValue(.symbol_list, names.len);
        errdefer list.deref(vm.gpa);
        for (list.as.symbol_list, names) |*slot, n| slot.* = try vm.intern(tree.tokenSlice(tree.nodeMainToken(n)));
        const wrapped = try vm.allocValue(.list, 1);
        wrapped.as.list[0] = list;
        try items.append(vm.gpa, wrapped);
        return vm.createValue(.list, try items.toOwnedSlice(vm.gpa));
    }
    if (tag == .delete_rows) {
        const spans = tree.extraData(tree.nodeData(node).extra, Node.DeleteRows);
        try items.append(vm.gpa, vm.getOperator(.dict));
        try items.append(vm.gpa, try vm.parseNode(spans.from));
        try items.append(vm.gpa, try vm.whereTree(tree.extraDataSlice(.{ .start = spans.where_start, .end = spans.where_end }, Node.Index)));
        try items.append(vm.gpa, try vm.createValue(.boolean, false));
        try items.append(vm.gpa, try vm.allocValue(.symbol_list, 0));
        return vm.createValue(.list, try items.toOwnedSlice(vm.gpa));
    }
    const spans: Node.Select = switch (tag) {
        .select => tree.extraData(tree.nodeData(node).extra, Node.Select),
        .exec => blk: {
            const e = tree.extraData(tree.nodeData(node).extra, Node.Exec);
            break :blk .{ .limit_start = e.select_start, .select_start = e.select_start, .by_start = e.by_start, .from = e.from, .where_start = e.where_start, .where_end = e.where_end };
        },
        .update => blk: {
            const u = tree.extraData(tree.nodeData(node).extra, Node.Update);
            break :blk .{ .limit_start = u.select_start, .select_start = u.select_start, .by_start = u.by_start, .from = u.from, .where_start = u.where_start, .where_end = u.where_end };
        },
        else => unreachable,
    };
    const limits = tree.extraDataSlice(.{ .start = spans.limit_start, .end = spans.select_start }, Node.Index);
    var selected = tree.extraDataSlice(.{ .start = spans.select_start, .end = spans.by_start }, Node.Index);
    const by = tree.extraDataSlice(.{ .start = spans.by_start, .end = spans.where_start }, Node.Index);
    const where = tree.extraDataSlice(.{ .start = spans.where_start, .end = spans.where_end }, Node.Index);

    try items.append(vm.gpa, vm.getOperator(if (tag == .update) .dict else .find));
    try items.append(vm.gpa, try vm.parseNode(spans.from));
    try items.append(vm.gpa, try vm.whereTree(where));

    // `select distinct a` is a select by `1b`.
    var distinct = false;
    if (tag == .select and selected.len > 0 and tree.nodeTag(selected[0]) == .apply_unary) {
        const f, _ = tree.nodeData(selected[0]).node_and_node;
        if ((tree.nodeTag(f) == .keyword or tree.nodeTag(f) == .identifier) and std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(f)), "distinct")) distinct = true;
    }
    if (tag == .exec) {
        try items.append(vm.gpa, if (by.len == 0) vm.getConstant(.empty_list) else if (by.len == 1) try vm.enlistTree(by[0]) else try vm.namedTrees(by));
        try items.append(vm.gpa, if (selected.len == 0) vm.getConstant(.empty_list) else if (selected.len == 1) try vm.enlistTree(selected[0]) else try vm.namedTrees(selected));
        return vm.createValue(.list, try items.toOwnedSlice(vm.gpa));
    }
    try items.append(vm.gpa, if (by.len == 0) try vm.createValue(.boolean, distinct) else try vm.namedTrees(by));
    if (distinct) {
        // Replace the first item by the argument of `distinct`.
        const copy = try vm.gpa.dupe(Node.Index, selected);
        defer vm.gpa.free(copy);
        _, const argument = tree.nodeData(selected[0]).node_and_node;
        copy[0] = argument;
        try items.append(vm.gpa, try vm.namedTrees(copy));
        selected = &.{};
    } else try items.append(vm.gpa, if (selected.len == 0) vm.getConstant(.empty_list) else try vm.namedTrees(selected));
    // `select[n]`, `select[n;>a]` and `select[>a]`: a count, then the enlisted sort tree.
    if (limits.len > 0) {
        const first = try vm.parseNode(limits[0]);
        if (isSortTree(first)) {
            errdefer first.deref(vm.gpa);
            // `select[>a;<b]` is a length error, as in q.
            if (limits.len > 1) return error.length;
            try items.append(vm.gpa, try vm.createValue(.long, @backingInt(Value.Long.inf)));
            try items.append(vm.gpa, try vm.wrapTree(first));
        } else {
            try items.append(vm.gpa, first);
            if (limits.len > 1) {
                const sort = try vm.parseNode(limits[1]);
                errdefer sort.deref(vm.gpa);
                try items.append(vm.gpa, try vm.wrapTree(sort));
            }
        }
    }
    return vm.createValue(.list, try items.toOwnedSlice(vm.gpa));
}

/// Every expression node of a qSQL statement: limits, select items, by items, the source
/// and the where constraints, for a compiler scanning the names they use.
pub fn queryNodes(vm: *Vm, node: Node.Index, list: *std.ArrayList(Node.Index)) Allocator.Error!void {
    const tree = vm.tree;
    switch (tree.nodeTag(node)) {
        .delete_cols => {
            const spans = tree.extraData(tree.nodeData(node).extra, Node.DeleteCols);
            try list.append(vm.gpa, spans.from);
        },
        .delete_rows => {
            const spans = tree.extraData(tree.nodeData(node).extra, Node.DeleteRows);
            try list.append(vm.gpa, spans.from);
            try list.appendSlice(vm.gpa, tree.extraDataSlice(.{ .start = spans.where_start, .end = spans.where_end }, Node.Index));
        },
        .select => {
            const spans = tree.extraData(tree.nodeData(node).extra, Node.Select);
            try list.appendSlice(vm.gpa, tree.extraDataSlice(.{ .start = spans.limit_start, .end = spans.where_start }, Node.Index));
            try list.append(vm.gpa, spans.from);
            try list.appendSlice(vm.gpa, tree.extraDataSlice(.{ .start = spans.where_start, .end = spans.where_end }, Node.Index));
        },
        .exec => {
            const spans = tree.extraData(tree.nodeData(node).extra, Node.Exec);
            try list.appendSlice(vm.gpa, tree.extraDataSlice(.{ .start = spans.select_start, .end = spans.where_start }, Node.Index));
            try list.append(vm.gpa, spans.from);
            try list.appendSlice(vm.gpa, tree.extraDataSlice(.{ .start = spans.where_start, .end = spans.where_end }, Node.Index));
        },
        .update => {
            const spans = tree.extraData(tree.nodeData(node).extra, Node.Update);
            try list.appendSlice(vm.gpa, tree.extraDataSlice(.{ .start = spans.select_start, .end = spans.where_start }, Node.Index));
            try list.append(vm.gpa, spans.from);
            try list.appendSlice(vm.gpa, tree.extraDataSlice(.{ .start = spans.where_start, .end = spans.where_end }, Node.Index));
        },
        else => unreachable,
    }
}

/// The source expression of a qSQL statement, the `t` of `from t`.
pub fn querySource(vm: *Vm, node: Node.Index) Node.Index {
    const tree = vm.tree;
    return switch (tree.nodeTag(node)) {
        .delete_cols => tree.extraData(tree.nodeData(node).extra, Node.DeleteCols).from,
        .delete_rows => tree.extraData(tree.nodeData(node).extra, Node.DeleteRows).from,
        .select => tree.extraData(tree.nodeData(node).extra, Node.Select).from,
        .exec => tree.extraData(tree.nodeData(node).extra, Node.Exec).from,
        .update => tree.extraData(tree.nodeData(node).extra, Node.Update).from,
        else => unreachable,
    };
}

/// Whether a tree is `(>:;e)` or `(<:;e)`, the sort of a `select[>a]`.
fn isSortTree(tree_value: *Value) bool {
    if (tree_value.as != .list or tree_value.as.list.len != 2) return false;
    const head = tree_value.as.list[0];
    return head.as == .unary_primitive and (head.as.unary_primitive == .desc or head.as.unary_primitive == .asc);
}

/// The tree `(';~:;e)` of `<=`, `>=` and `<>`, which evaluates to the composition of
/// `not` with the operator; `parse "a<=1"` shows it as `((';~:;>);`a;1)`.
fn negated(vm: *Vm, operator: Operator) Error!*Value {
    const list = try vm.allocValue(.list, 3);
    errdefer comptime unreachable;
    list.as.list[0] = vm.getIterator(.each);
    list.as.list[1] = vm.getUnaryPrimitive(.not);
    list.as.list[2] = vm.getOperator(operator);
    return list;
}

/// Whether a node is `<=`, `>=` or `<>`, whose tree is a composition to evaluate when a
/// lambda wants the value itself.
pub fn isNegatedComparison(tag: Node.Tag) bool {
    return tag == .l_angle_bracket_equal or tag == .r_angle_bracket_equal or tag == .l_angle_bracket_r_angle_bracket;
}

/// A node's value for a lambda's constant: its tree, except that `<=`, `>=` and `<>`
/// give their composition.
pub fn constantOf(vm: *Vm, node: Node.Index, unary: bool) Error!*Value {
    const tree = if (unary) try vm.parseUnaryNode(node) else try vm.parseNode(node);
    if (!isNegatedComparison(vm.tree.nodeTag(node))) return tree;
    defer tree.deref(vm.gpa);
    return vm.eval(tree) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}

/// The where clause: the list of constraint trees quoted (`,,(>;`a;1)`), or `()`.
fn whereTree(vm: *Vm, nodes: []const Node.Index) Error!*Value {
    if (nodes.len == 0) return vm.getConstant(.empty_list);
    const list = try vm.treeList(nodes);
    errdefer list.deref(vm.gpa);
    return vm.wrapTree(list);
}

/// The trees of `nodes` as a list, `()` for none.
fn treeList(vm: *Vm, nodes: []const Node.Index) Error!*Value {
    if (nodes.len == 0) return vm.getConstant(.empty_list);
    const list = try vm.allocValue(.list, nodes.len);
    var filled: usize = 0;
    errdefer {
        for (list.as.list[0..filled]) |t| t.deref(vm.gpa);
        vm.gpa.free(list.as.list);
        vm.gpa.destroy(list);
    }
    for (nodes) |n| {
        list.as.list[filled] = try vm.parseNode(n);
        filled += 1;
    }
    return list;
}

/// One tree enlisted, as `exec a` holds `,`a` and `exec distinct a` `,(?:;`a)`.
fn enlistTree(vm: *Vm, node: Node.Index) Error!*Value {
    const t = try vm.parseNode(node);
    errdefer t.deref(vm.gpa);
    return vm.wrapTree(t);
}

/// A one-item general list holding a tree, taking the reference.
fn wrapTree(vm: *Vm, t: *Value) Error!*Value {
    const list = try vm.allocValue(.list, 1);
    list.as.list[0] = t;
    return list;
}

/// A dictionary of column names to trees, named as q names them: `a:e` is `a`, a name
/// itself, an application whose first operand is a name (but not `i`) that name, and
/// anything else `x`; repeats take a number (`a`, `a1`).
fn namedTrees(vm: *Vm, nodes: []const Node.Index) Error!*Value {
    const tree = vm.tree;
    const names = try vm.allocValue(.symbol_list, nodes.len);
    errdefer names.deref(vm.gpa);
    const trees = try vm.allocValue(.list, nodes.len);
    var filled: usize = 0;
    errdefer {
        for (trees.as.list[0..filled]) |t| t.deref(vm.gpa);
        vm.gpa.free(trees.as.list);
        vm.gpa.destroy(trees);
    }
    var buffer: [40]u8 = undefined;
    for (nodes, 0..) |column, k| {
        var expr_node = column;
        var name: []const u8 = "";
        if (tree.nodeTag(column) == .apply_binary) {
            const lhs, const maybe_rhs = tree.nodeData(column).node_and_opt_node;
            const op: Node.Index = @fromBackingInt(@intCast(tree.nodeMainToken(column)));
            if (tree.nodeTag(op) == .colon and tree.nodeTag(lhs) == .identifier) if (maybe_rhs.unwrap()) |rhs| {
                name = tree.tokenSlice(tree.nodeMainToken(lhs));
                expr_node = rhs;
            };
        }
        const expr = try vm.parseNode(expr_node);
        errdefer expr.deref(vm.gpa);
        if (name.len == 0) name = columnName(vm, expr);
        // Repeated names count up.
        var candidate = name;
        var n: usize = 1;
        while (std.mem.findScalar(Symbol, names.as.symbol_list[0..k], try vm.intern(candidate)) != null) : (n += 1) {
            candidate = std.fmt.bufPrint(&buffer, "{s}{d}", .{ name, n }) catch name;
        }
        names.as.symbol_list[k] = try vm.intern(candidate);
        trees.as.list[filled] = expr;
        filled += 1;
    }
    // Symbols alone make a symbol list, as `exec a,b` holds `` `a`b!`a`b ``.
    const values = vm.enlist(trees.as.list) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    trees.deref(vm.gpa);
    errdefer values.deref(vm.gpa);
    return vm.createValue(.dict, .{ .keys = names, .values = values });
}

fn columnName(vm: *Vm, expr: *Value) []const u8 {
    const named: ?Symbol = switch (expr.as) {
        .symbol => |s| s,
        .list => |l| if (l.len > 1 and l[1].as == .symbol) l[1].as.symbol else null,
        else => null,
    };
    if (named) |s| {
        const text = vm.internedString(s);
        if (!std.mem.eql(u8, text, "i") and text.len > 0) return text;
    }
    return "x";
}

/// The parse tree of a table from column nodes: `(+:;(!;,names;(enlist;e1;e2)))`. A column
/// `a:e` is named `a`, a bare name `a` names itself, and anything else takes the name of
/// its first operand when that is a name, or `x`.
fn tableTree(vm: *Vm, nodes: []const Node.Index) Error!*Value {
    const gpa = vm.gpa;
    // The columns are named as a query names them: `a:e` is `a`, a name or an
    // application of one is that name, anything else `x`, repeats numbered.
    const named = try vm.namedTrees(nodes);
    defer named.deref(gpa);
    const names = named.as.dict.keys.ref();
    errdefer names.deref(gpa);
    const exprs = try vm.allocValue(.list, nodes.len + 1);
    var filled: usize = 1;
    errdefer {
        for (exprs.as.list[1..filled]) |e| e.deref(gpa);
        vm.gpa.free(exprs.as.list);
        vm.gpa.destroy(exprs);
    }
    exprs.as.list[0] = vm.getUnaryPrimitive(.enlist);
    for (0..nodes.len) |k| {
        exprs.as.list[filled] = try q.operators.itemAt(vm, named.as.dict.values, k);
        filled += 1;
    }
    const flipped = try vm.allocValue(.list, 2);
    errdefer {
        vm.gpa.free(flipped.as.list);
        vm.gpa.destroy(flipped);
    }
    const dict_tree = try vm.allocValue(.list, 3);
    errdefer {
        vm.gpa.free(dict_tree.as.list);
        vm.gpa.destroy(dict_tree);
    }
    const wrapped = try vm.allocValue(.list, 1);
    errdefer comptime unreachable;
    wrapped.as.list[0] = names;
    dict_tree.as.list[0] = vm.getOperator(.dict);
    dict_tree.as.list[1] = wrapped;
    dict_tree.as.list[2] = exprs;
    flipped.as.list[0] = vm.getUnaryPrimitive(.flip);
    flipped.as.list[1] = dict_tree;
    return flipped;
}

/// The parse tree `(op;lhs)` of a verb projected on its left operand, as `+[1]`.
fn parseProjection(vm: *Vm, op: Node.Index, lhs: Node.Index) Error!*Value {
    const list = try vm.allocValue(.list, 2);
    errdefer vm.gpa.free(list.as.list);
    list.as.list[0] = try vm.parseNode(op);
    errdefer list.as.list[0].deref(vm.gpa);
    list.as.list[1] = try vm.parseNode(lhs);
    return list;
}

/// Whether a node is a function by its syntax alone: a verb glyph, a dangling projection
/// (`1+`, `"s"$`), a derived function (`+/`) or a composition (`_-:`). These are what a
/// verb composes with; an identifier, a lambda or a parenthesised expression is applied to.
pub fn isFunctionForm(tree: *const Ast, node: Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .plus,
        .minus,
        .asterisk,
        .percent,
        .ampersand,
        .pipe,
        .caret,
        .equal,
        .l_angle_bracket,
        .l_angle_bracket_equal,
        .l_angle_bracket_r_angle_bracket,
        .r_angle_bracket,
        .r_angle_bracket_equal,
        .dollar,
        .comma,
        .hash,
        .underscore,
        .tilde,
        .bang,
        .question_mark,
        .at,
        .dot,
        .zero_colon,
        .one_colon,
        .two_colon,
        .colon_colon,
        .plus_colon,
        .minus_colon,
        .asterisk_colon,
        .percent_colon,
        .ampersand_colon,
        .pipe_colon,
        .caret_colon,
        .equal_colon,
        .l_angle_bracket_colon,
        .r_angle_bracket_colon,
        .dollar_colon,
        .comma_colon,
        .hash_colon,
        .underscore_colon,
        .tilde_colon,
        .bang_colon,
        .question_mark_colon,
        .at_colon,
        .dot_colon,
        .zero_colon_colon,
        .one_colon_colon,
        => true,
        // `1+` dangles; `"s"$-1!'` is the projection `$["s"]` composed with its right side.
        .apply_binary => if (tree.nodeData(node).node_and_opt_node[1].unwrap()) |rhs| isFunctionForm(tree, rhs) else true,
        .apostrophe, .apostrophe_colon, .slash, .slash_colon, .backslash, .backslash_colon => tree.nodeData(node).opt_node != .none,
        .apply_unary => isFunctionForm(tree, tree.nodeData(node).node_and_node[1]),
        else => false,
    };
}

/// Whether a value can be applied.
pub fn isFunction(value: *const Value) bool {
    return switch (value.as) {
        .lambda, .unary_primitive, .operator, .iterator, .projection, .each, .over, .scan, .each_prior, .each_right, .each_left, .composition => true,
        else => false,
    };
}

/// The derived function of an iterator on `function`: `+/` from `/` and `+`.
pub fn derive(vm: *Vm, iterator: Iterator, function: *Value) Allocator.Error!*Value {
    const f = function.ref();
    errdefer f.deref(vm.gpa);
    return switch (iterator) {
        .each => vm.createValue(.each, .{ .value = f }),
        .over => vm.createValue(.over, .{ .value = f }),
        .scan => vm.createValue(.scan, .{ .value = f }),
        .each_prior => vm.createValue(.each_prior, .{ .value = f }),
        .each_right => vm.createValue(.each_right, .{ .value = f }),
        .each_left => vm.createValue(.each_left, .{ .value = f }),
    };
}

/// The iterator an iterator node stands for.
pub fn iteratorOf(tag: Node.Tag) Iterator {
    return switch (tag) {
        .apostrophe => .each,
        .slash => .over,
        .backslash => .scan,
        .apostrophe_colon => .each_prior,
        .slash_colon => .each_right,
        .backslash_colon => .each_left,
        else => unreachable,
    };
}

pub fn enlist(vm: *Vm, args: []*Value) !*Value {
    const is_vector = is_vector: {
        const first_type = switch (args[0].as) {
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
            .dict,
            .table,
            => break :is_vector false,
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
            => @backingInt(args[0].as),
        };
        break :is_vector for (args[1..]) |a| {
            if (first_type != @backingInt(a.as)) break false;
        } else true;
    };
    if (is_vector) {
        switch (args[0].as) {
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
            => unreachable,
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
            => |_, tag| {
                const list_tag = @field(Value.Type, @tagName(tag) ++ "_list");
                const value = try vm.allocValue(list_tag, args.len);
                errdefer comptime unreachable;
                for (@field(value.as, @tagName(list_tag)), args) |*v, a| v.* = @field(a.as, @tagName(tag));
                return value;
            },
            .dict, .table => unreachable,
        }
    } else {
        // A list of dictionaries with one set of symbol keys, in one order, is a table.
        if (args[0].as == .dict and args[0].as.dict.keys.as == .symbol_list and args[0].as.dict.keys.count() > 0) like: {
            for (args[1..]) |a| if (a.as != .dict or !a.as.dict.keys.eql(args[0].as.dict.keys)) break :like;
            return vm.tableOfRows(args);
        }
        const list = try vm.gpa.alloc(*Value, args.len);
        errdefer {
            for (list) |v| v.deref(vm.gpa);
            vm.gpa.free(list);
        }
        var is_projection = false;
        for (list, args) |*v, a| {
            if (!is_projection and a.isEmpty()) is_projection = true;
            v.* = a.ref();
        }

        if (is_projection) {
            return vm.createValue(.projection, .{
                .callee = vm.getUnaryPrimitive(.enlist),
                .args = list,
            });
        } else {
            return vm.createValue(.list, list);
        }
    }
}

pub fn parse(vm: *Vm, x: *Value) !*Value {
    if (x.as != .char_list) return error.type;

    const slice = try vm.gpa.dupeSentinel(u8, x.as.char_list, 0);
    defer vm.gpa.free(slice);

    return vm.parseSource(slice, .q, "<parse>");
}

fn parseSource(vm: *Vm, source: [:0]const u8, mode: Ast.Mode, path: []const u8) !*Value {
    var tree: Ast = try .parse(vm.gpa, source, .{
        .skip_comments = false,
        .mode = mode,
        .resolver = vm.resolver(),
    });
    defer tree.deinit(vm.gpa);
    if (tree.errors.len > 0) {
        try q.printAstErrorsToStderr(vm.gpa, vm.io, tree, path, .auto);
        return error.parse;
    }

    return vm.parseTree(&tree);
}

pub fn createCharList(vm: *Vm, comptime fmt: []const u8, args: anytype) !*Value {
    var buffer: Io.Writer.Allocating = .init(vm.gpa);
    defer buffer.deinit();

    try buffer.writer.print(fmt, args);
    const slice = try buffer.toOwnedSlice();
    errdefer vm.gpa.free(slice);

    return vm.createValue(.char_list, slice);
}

pub fn evalSource(vm: *Vm, source: [:0]const u8, mode: Ast.Mode, path: []const u8) RunError!*Value {
    const value = try vm.parseSource(source, mode, path);
    defer value.deref(vm.gpa);
    return vm.evalStatement(value);
}

/// Evaluates a statement: as `eval`, except that an assignment, plain or amend, gives
/// `::` as q does (`value "a:1"` is `::`), while nested in an expression it keeps its
/// value (`b:a+:2` sets `b` to the new `a`).
pub fn evalStatement(vm: *Vm, x: *Value) RunError!*Value {
    const v = try vm.eval(x);
    if (!isAssignmentTree(x)) return v;
    v.deref(vm.gpa);
    return vm.getUnaryPrimitive(.identity);
}

/// Whether a parse tree is an assignment at its top: `x:v`, `x+:v`, `x[i]:v` or `x::v`.
fn isAssignmentTree(x: *Value) bool {
    if (x.as != .list or x.as.list.len != 3) return false;
    const value = x.as.list;
    const target = value[1];
    const indexed = target.as == .list and target.as.list.len > 1 and target.as.list[0].as == .symbol;
    if (value[0].as == .operator and value[0].as.operator == .assign) return target.as == .symbol or indexed;
    if (amendOperatorOf(value[0])) |_| return target.as == .symbol or indexed;
    return false;
}

pub fn eval(vm: *Vm, x: *Value) RunError!*Value {
    std.log.debug("eval: ({t}) {f}", .{ x.as, x.fmt(vm) });
    switch (x.as) {
        .list => |value| {
            if (value.len == 0) return vm.getConstant(.empty_list);
            // A one-item list quotes its item: `parse "`a"` is `,`a` and a constant list
            // in a tree is `enlist` applied, so `eval enlist x` is `x` unevaluated.
            if (value.len == 1) return value[0].ref();

            if (value[0].as == .char and value[0].as.char == ';') {
                for (value[1 .. value.len - 1]) |val| {
                    const v = try vm.evalStatement(val);
                    defer v.deref(vm.gpa);
                }
                // A trailing `;` leaves `::`, as `value "1+1;"` is `::` in q.
                const last = value[value.len - 1];
                if (last.as == .unary_primitive and last.as.unary_primitive == .empty) return vm.getUnaryPrimitive(.identity);
                return vm.evalStatement(last);
            }

            // Compound and indexed assignment as q parses them at the top level: `x+:v` is
            // `(+:;`x;v)`, `x[i]:v` is `(:;(`x;i);v)`, `x[i]+:v` is `(+:;(`x;i);v)` and
            // `x::v` is `(::;`x;v)`. A plain `x:v` is handled below.
            if (value.len == 3) if (amendOperatorOf(value[0])) |operator| {
                const target = value[1];
                const indexed = target.as == .list and target.as.list.len > 1 and target.as.list[0].as == .symbol;
                const plain = operator == .assign and value[0].as == .operator;
                if (indexed or (target.as == .symbol and !plain)) return vm.evalAmend(target, operator, value[2]);
            };

            // `x:v` assigns; `:` on anything else is the operator, which projects on one
            // argument (`:[1]`) and returns its right argument on two (`:[;2][1]` is 2).
            if (value[0].as == .operator and value[0].as.operator == .assign and value.len == 3 and value[1].as == .symbol) {
                if (value[2].isEmpty()) return error.rank;

                const v = try vm.eval(value[2]);
                errdefer v.deref(vm.gpa);

                // Inside a lambda's query or table literal, a parameter or local takes it.
                if (vm.scope) |scope| {
                    const name = value[1].as.symbol;
                    const slot: ?usize = if (std.mem.findScalar(Symbol, scope.lambda.params, name)) |i| i else if (std.mem.findScalar(Symbol, scope.lambda.locals, name)) |i| scope.lambda.params.len + i else null;
                    if (slot) |i| {
                        if (scope.slots[i]) |old| old.deref(vm.gpa);
                        scope.slots[i] = v.ref();
                        return v;
                    }
                }
                return q.operators.assignGlobal(vm, value[1], v);
            }

            // The conditional and the control words evaluate their arguments as they go,
            // as q does at the top level too; `$` with two arguments stays the cast.
            if (value[0].as == .operator and value[0].as.operator == .cast and value.len > 3) return vm.evalCond(value[1..]);
            if (value[0].as == .symbol) {
                const name = vm.internedString(value[0].as.symbol);
                if (std.mem.eql(u8, name, "if")) return vm.evalIf(value[1..]);
                if (std.mem.eql(u8, name, "while")) return vm.evalWhile(value[1..]);
                if (std.mem.eql(u8, name, "do")) return vm.evalDo(value[1..]);
            }
            if (value[0].as == .char and value[0].as.char == '\'' and value.len == 2) {
                const v = try vm.eval(value[1]);
                defer v.deref(vm.gpa);
                return vm.raiseSignal(v);
            }

            // Items are evaluated right to left into an array of this call's own: a nested
            // evaluation may grow a shared stack and move it under a slice held here.
            const items = try vm.gpa.alloc(*Value, value.len);
            defer vm.gpa.free(items);
            var done: usize = 0;
            defer for (items[items.len - done ..]) |v| v.deref(vm.gpa);
            var i = value.len;
            while (i > 0) {
                i -= 1;
                items[i] = try vm.eval(value[i]);
                done += 1;
            }
            return vm.applyImpl(items[0], items[1..]);
        },
        .symbol => |name| {
            if (vm.columns) |columns| if (try vm.keyPosition(columns.as.dict.keys, x)) |i| return q.operators.itemAt(vm, columns.as.dict.values, i);
            if (vm.scope) |scope| {
                if (std.mem.findScalar(Symbol, scope.lambda.params, name)) |i| return (scope.slots[i] orelse return vm.undefinedName(name)).ref();
                if (std.mem.findScalar(Symbol, scope.lambda.locals, name)) |i| return (scope.slots[scope.lambda.params.len + i] orelse return vm.undefinedName(name)).ref();
                return vm.readGlobalIn(name, scope.lambda.namespace);
            }
            return q.unary_primitives.value(vm, x);
        },
        .symbol_list => |value| {
            if (value.len == 1) return vm.createValue(.symbol, value[0]);
            if (value.len == 0) return x.ref();
            return error.type;
        },
        else => return x.ref(),
    }
}

/// The operator behind an assignment glyph in a parse tree: `::` assigns, and `+:` and
/// the other monadic glyphs stand for their dyadic operators.
fn amendOperatorOf(head: *Value) ?Operator {
    return switch (head.as) {
        .operator => |o| if (o == .assign) .assign else null,
        .unary_primitive => |p| switch (p) {
            .identity => .assign,
            .flip => .add,
            .neg => .subtract,
            .first => .multiply,
            .reciprocal => .divide,
            .where => .@"and",
            .reverse => .@"or",
            .null => .fill,
            .group => .equal,
            .asc => .less_than,
            .desc => .greater_than,
            .string => .cast,
            .list => .join,
            .count => .take,
            .lower => .drop,
            .not => .match,
            .key => .dict,
            .distinct => .find,
            .type => .apply_at,
            .value => .apply,
            else => null,
        },
        else => null,
    };
}

/// `x op: v` and `x[i] op: v` at the top level: the global is read, amended and stored,
/// and the statement is `::` as in q.
fn evalAmend(vm: *Vm, target: *Value, operator: Operator, rhs: *Value) RunError!*Value {
    const v = try vm.eval(rhs);
    defer v.deref(vm.gpa);
    const name = if (target.as == .symbol) target else target.as.list[0];
    const index = if (target.as == .symbol) try vm.allocValue(.list, 0) else try vm.evalIndex(target.as.list[1..]);
    defer index.deref(vm.gpa);
    const plain = target.as == .symbol and operator == .assign;
    const new_value = if (plain) v.ref() else amended: {
        const old = try vm.readGlobal(name.as.symbol);
        defer old.deref(vm.gpa);
        const function = vm.getOperator(operator);
        defer function.deref(vm.gpa);
        break :amended try vm.amendValue(old, index, function, v);
    };
    defer new_value.deref(vm.gpa);
    _ = try q.operators.assignGlobal(vm, name, new_value);
    return vm.amendedItems(new_value, index, plain, v);
}

/// What an amend evaluates to: the assigned value for `x:v`, the whole new value for
/// `x+:v`, and the new items at the index for `x[i]:v` and `x[i]+:v`.
fn amendedItems(vm: *Vm, new_value: *Value, index: *Value, plain: bool, value: *Value) RunError!*Value {
    if (plain) return value.ref();
    const n = index.count();
    if (n == 0) return new_value.ref();
    const items = try vm.gpa.alloc(*Value, n);
    defer vm.gpa.free(items);
    var made: usize = 0;
    defer for (items[0..made]) |i| i.deref(vm.gpa);
    for (0..n) |i| {
        items[made] = try q.operators.itemAt(vm, index, i);
        made += 1;
    }
    return vm.applyImpl(new_value, items);
}

/// The index list of `x[i;j]`, one item per dimension; an elided index is `::`.
fn evalIndex(vm: *Vm, nodes: []*Value) RunError!*Value {
    const items = try vm.gpa.alloc(*Value, nodes.len);
    defer vm.gpa.free(items);
    var done: usize = 0;
    defer for (items[0..done]) |item| item.deref(vm.gpa);
    for (nodes) |node| {
        items[done] = if (node.isEmpty()) vm.getUnaryPrimitive(.identity) else try vm.eval(node);
        done += 1;
    }
    return vm.enlist(items);
}

fn evalCond(vm: *Vm, args: []*Value) RunError!*Value {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 2) {
        const condition = try vm.eval(args[i]);
        defer condition.deref(vm.gpa);
        if (try truthy(condition)) return vm.evalBranch(args[i + 1]);
    }
    return if (i < args.len) vm.evalBranch(args[i]) else vm.getUnaryPrimitive(.identity);
}

fn evalBranch(vm: *Vm, branch: *Value) RunError!*Value {
    return if (branch.isEmpty()) vm.getUnaryPrimitive(.identity) else vm.eval(branch);
}

fn evalIf(vm: *Vm, args: []*Value) RunError!*Value {
    if (args.len == 0) return error.rank;
    const condition = try vm.eval(args[0]);
    defer condition.deref(vm.gpa);
    if (try truthy(condition)) try vm.evalStatements(args[1..]);
    return vm.getUnaryPrimitive(.identity);
}

fn evalWhile(vm: *Vm, args: []*Value) RunError!*Value {
    if (args.len == 0) return error.rank;
    while (true) {
        const condition = try vm.eval(args[0]);
        defer condition.deref(vm.gpa);
        if (!try truthy(condition)) break;
        try vm.evalStatements(args[1..]);
    }
    return vm.getUnaryPrimitive(.identity);
}

fn evalDo(vm: *Vm, args: []*Value) RunError!*Value {
    if (args.len == 0) return error.rank;
    const count = try vm.eval(args[0]);
    defer count.deref(vm.gpa);
    var remaining = try loopCount(count);
    while (remaining > 0) : (remaining -= 1) try vm.evalStatements(args[1..]);
    return vm.getUnaryPrimitive(.identity);
}

fn evalStatements(vm: *Vm, statements: []*Value) RunError!void {
    for (statements) |statement| {
        if (statement.isEmpty()) continue;
        const v = try vm.eval(statement);
        v.deref(vm.gpa);
    }
}

/// Whether a condition holds: an integer-like atom other than zero, as q reads it. A null
/// is nonzero and so holds; floats, symbols, lists and functions are a type error.
pub fn truthy(value: *Value) error{type}!bool {
    return switch (value.as) {
        .boolean => |b| b,
        .byte => |b| b != 0,
        .short => |v| v != 0,
        .int, .month, .date, .minute, .second, .time => |v| v != 0,
        .long, .timestamp, .timespan => |v| v != 0,
        else => error.type,
    };
}

fn loopCount(value: *Value) error{type}!i64 {
    return switch (value.as) {
        .boolean => |b| @intFromBool(b),
        .byte => |b| b,
        .short => |v| v,
        .int => |v| v,
        .long => |v| v,
        else => error.type,
    };
}

/// `'x`: records the message and fails with `error.signal`. A symbol or string names the
/// error; anything else is q's `stype`.
/// Fails with a signal carrying `text`, for q's named errors such as `s-fail`.
pub fn failWith(vm: *Vm, text: []const u8) RunError {
    const message = try vm.gpa.dupe(u8, text);
    if (vm.signal_message) |old| vm.gpa.free(old);
    vm.signal_message = message;
    return error.signal;
}

pub fn raiseSignal(vm: *Vm, value: *Value) RunError {
    const text: []const u8 = switch (value.as) {
        .symbol => |s| vm.internedString(s),
        .char_list => |s| s,
        .char => |ch| &[_]u8{ch},
        else => "stype",
    };
    const message = try vm.gpa.dupe(u8, text);
    if (vm.signal_message) |old| vm.gpa.free(old);
    vm.signal_message = message;
    return error.signal;
}

pub fn parseNode(vm: *Vm, node: Node.Index) Error!*Value {
    const tree = vm.tree;
    const gpa = vm.gpa;

    switch (tree.nodeTag(node)) {
        .root => {
            const nodes = tree.extraDataSlice(tree.nodeData(.root).extra_range, Node.Index);
            assert(nodes.len > 0);
            if (nodes.len == 1) return vm.parseNode(nodes[0]);

            var values: std.ArrayList(*Value) = try .initCapacity(gpa, nodes.len + 1);
            defer values.deinit(gpa);
            errdefer for (values.items) |v| v.deref(gpa);

            values.appendAssumeCapacity(vm.getConstant(.semicolon));
            for (nodes) |n| values.appendAssumeCapacity(try vm.parseNode(n));

            const list = try vm.createValue(.list, &.{});
            errdefer comptime unreachable;
            list.as.list = values.toOwnedSliceAssert();
            return list;
        },
        .empty => return vm.getUnaryPrimitive(.empty),
        .system => {
            // `\d .Q` is `value"\\d .Q"`.
            const slice = tree.tokenSlice(tree.nodeMainToken(node));
            const command = try vm.allocValue(.char_list, slice.len);
            errdefer command.deref(vm.gpa);
            @memcpy(command.as.char_list, slice);

            const list = try vm.allocValue(.list, 2);
            errdefer comptime unreachable;
            list.as.list[0] = vm.getUnaryPrimitive(.value);
            list.as.list[1] = command;
            return list;
        },

        .grouped_expression => return vm.parseNode(tree.nodeData(node).node_and_token[0]),
        .empty_list => return vm.getConstant(.empty_list),
        .list => {
            const nodes = tree.extraDataSlice(tree.nodeData(node).extra_range, Node.Index);
            assert(nodes.len > 1);

            var values: std.ArrayList(*Value) = try .initCapacity(gpa, nodes.len + 1);
            defer values.deinit(gpa);
            errdefer for (values.items) |v| v.deref(gpa);

            values.appendAssumeCapacity(vm.getUnaryPrimitive(.enlist));
            for (nodes) |n| values.appendAssumeCapacity(try vm.parseNode(n));

            const list = try vm.createValue(.list, &.{});
            errdefer comptime unreachable;
            list.as.list = values.toOwnedSliceAssert();
            return list;
        },
        .lambda => {
            var compiler: Compiler = .init(vm, tree);
            defer compiler.deinit();
            return compiler.compile(node);
        },

        .expr_block => {
            const nodes = tree.extraDataSlice(tree.nodeData(node).extra_range, Node.Index);
            if (nodes.len == 0) return vm.getUnaryPrimitive(.identity);

            var list: std.ArrayList(*Value) = try .initCapacity(vm.gpa, nodes.len + 1);
            defer list.deinit(vm.gpa);
            errdefer for (list.items) |v| v.deref(vm.gpa);

            list.appendAssumeCapacity(vm.getConstant(.semicolon));
            for (nodes) |n| list.appendAssumeCapacity(try vm.parseNode(n));

            const value = try vm.createValue(.list, &.{});
            errdefer comptime unreachable;
            value.as.list = list.toOwnedSliceAssert();
            return value;
        },

        .colon => return vm.getOperator(.assign),
        .plus => return vm.getOperator(.add),
        .minus => return vm.getOperator(.subtract),
        .asterisk => return vm.getOperator(.multiply),
        .percent => return vm.getOperator(.divide),
        .ampersand => return vm.getOperator(.@"and"),
        .pipe => return vm.getOperator(.@"or"),
        .caret => return vm.getOperator(.fill),
        .equal => return vm.getOperator(.equal),
        .l_angle_bracket => return vm.getOperator(.less_than),
        // `<=`, `>=` and `<>` are the compositions `'[~:;>]`, `'[~:;<]` and `'[~:;=]`, as
        // q has them (`value (<=)` is `(~:;>)` and they display as `~>`).
        .l_angle_bracket_equal => return vm.negated(.greater_than),
        .l_angle_bracket_r_angle_bracket => return vm.negated(.equal),
        .r_angle_bracket => return vm.getOperator(.greater_than),
        .r_angle_bracket_equal => return vm.negated(.less_than),
        .dollar => return vm.getOperator(.cast),
        .comma => return vm.getOperator(.join),
        .hash => return vm.getOperator(.take),
        .underscore => return vm.getOperator(.drop),
        .tilde => return vm.getOperator(.match),
        .bang => return vm.getOperator(.dict),
        .question_mark => return vm.getOperator(.find),
        .at => return vm.getOperator(.apply_at),
        .dot => return vm.getOperator(.apply),
        .zero_colon => return vm.getOperator(.file_text),
        .one_colon => return vm.getOperator(.file_binary),
        .two_colon => return vm.getOperator(.dynamic_load),

        .colon_colon => return vm.getUnaryPrimitive(.identity),
        .plus_colon => return vm.getUnaryPrimitive(.flip),
        .minus_colon => return vm.getUnaryPrimitive(.neg),
        .asterisk_colon => return vm.getUnaryPrimitive(.first),
        .percent_colon => return vm.getUnaryPrimitive(.reciprocal),
        .ampersand_colon => return vm.getUnaryPrimitive(.where),
        .pipe_colon => return vm.getUnaryPrimitive(.reverse),
        .caret_colon => return vm.getUnaryPrimitive(.null),
        .equal_colon => return vm.getUnaryPrimitive(.group),
        .l_angle_bracket_colon => return vm.getUnaryPrimitive(.asc),
        .r_angle_bracket_colon => return vm.getUnaryPrimitive(.desc),
        .dollar_colon => return vm.getUnaryPrimitive(.string),
        .comma_colon => return vm.getUnaryPrimitive(.list),
        .hash_colon => return vm.getUnaryPrimitive(.count),
        .underscore_colon => return vm.getUnaryPrimitive(.lower),
        .tilde_colon => return vm.getUnaryPrimitive(.not),
        .bang_colon => return vm.getUnaryPrimitive(.key),
        .question_mark_colon => return vm.getUnaryPrimitive(.distinct),
        .at_colon => return vm.getUnaryPrimitive(.type),
        .dot_colon => return vm.getUnaryPrimitive(.value),
        .zero_colon_colon => return vm.getUnaryPrimitive(.read_text),
        .one_colon_colon => return vm.getUnaryPrimitive(.read_binary),

        // An iterator applied to a function is `(iterator;function)`, as `parse "+/x"` shows
        // `((/;+);x)`; a bare iterator is its own value. The function under a glyph is the
        // dyadic operator (`+/` folds with `+`), which `parseNode` gives.
        .apostrophe,
        .apostrophe_colon,
        .slash,
        .slash_colon,
        .backslash,
        .backslash_colon,
        => |tag| {
            const iterator = vm.getIterator(iteratorOf(tag));
            errdefer iterator.deref(gpa);
            const function_node = tree.nodeData(node).opt_node.unwrap() orelse return iterator;
            const function = try vm.parseNode(function_node);
            errdefer function.deref(gpa);
            const list = try vm.allocValue(.list, 2);
            errdefer comptime unreachable;
            list.as.list[0] = iterator;
            list.as.list[1] = function;
            return list;
        },

        .call => {
            const nodes = tree.extraDataSlice(tree.nodeData(node).extra_range, Node.Index);
            assert(nodes.len > 1);

            var values: std.ArrayList(*Value) = try .initCapacity(gpa, nodes.len);
            defer values.deinit(gpa);
            errdefer for (values.items) |v| v.deref(gpa);

            values.appendAssumeCapacity(try vm.parseNode(nodes[0]));
            if (nodes.len == 2 and tree.nodeTag(nodes[1]) == .empty) {
                values.appendAssumeCapacity(vm.getUnaryPrimitive(.identity));
            } else for (nodes[1..]) |n| values.appendAssumeCapacity(try vm.parseNode(n));

            return vm.createValue(.list, values.toOwnedSliceAssert());
        },
        .apply_unary => {
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            // Applied to a function form, anything composes: `-_-:` is `'[-:;'[_:;-:]]`,
            // `type 1+` is `'[@:;+[1]]` and `f 1+` is `'[f;+[1]]`, while `-f` and `type(1+)`
            // apply, as q parses them.
            const composes = isFunctionForm(tree, rhs);

            var values: std.ArrayList(*Value) = try .initCapacity(gpa, if (composes) 3 else 2);
            defer values.deinit(gpa);
            errdefer for (values.items) |v| v.deref(gpa);

            if (composes) values.appendAssumeCapacity(vm.getIterator(.each));
            values.appendAssumeCapacity(try vm.parseUnaryNode(lhs));
            values.appendAssumeCapacity(try vm.parseNode(rhs));

            return vm.createValue(.list, values.toOwnedSliceAssert());
        },
        .apply_binary => {
            const lhs, const maybe_rhs = tree.nodeData(node).node_and_opt_node;
            const op: Node.Index = @fromBackingInt(@intCast(tree.nodeMainToken(node)));
            // A `.q` name cannot be assigned, even when its entry is a symbol that reads as an
            // alias (`.q.a:`alias` makes `a` read `alias` but `a:5` an error, as in q 5.0).
            const op_tag = tree.nodeTag(op);
            if ((op_tag == .colon or op_tag == .colon_colon) and tree.nodeTag(lhs) == .keyword) return error.assign;

            // A right operand that is a function form composes with the projection on the
            // left operand: `"s"$-1!'` is `'[$["s"];!'[-1]]`, as q parses it.
            if (maybe_rhs.unwrap()) |rhs| if (Compiler.assignOperator(op_tag) == null and isFunctionForm(tree, rhs)) {
                var values: std.ArrayList(*Value) = try .initCapacity(gpa, 3);
                defer values.deinit(gpa);
                errdefer for (values.items) |v| v.deref(gpa);
                values.appendAssumeCapacity(vm.getIterator(.each));
                values.appendAssumeCapacity(try vm.parseProjection(op, lhs));
                values.appendAssumeCapacity(try vm.parseNode(rhs));
                return vm.createValue(.list, values.toOwnedSliceAssert());
            };

            var values: std.ArrayList(*Value) = try .initCapacity(gpa, if (maybe_rhs == .none) 2 else 3);
            defer values.deinit(gpa);
            errdefer for (values.items) |v| v.deref(gpa);

            values.appendAssumeCapacity(try vm.parseNode(op));
            values.appendAssumeCapacity(try vm.parseNode(lhs));
            // A missing right operand projects on the left one, so `1+` is `+[1]`.
            if (maybe_rhs.unwrap()) |rhs| values.appendAssumeCapacity(try vm.parseNode(rhs));

            return vm.createValue(.list, values.toOwnedSliceAssert());
        },

        // TODO: Improve error reporting
        .number_literal => return vm.createNumberLiteral(tree, node),
        .number_list_literal => return vm.createNumberListLiteral(tree, node),
        .string_literal => {
            const main_token = tree.nodeMainToken(node);
            const slice = tree.tokenSlice(main_token);

            const buffer = try vm.gpa.alloc(u8, slice.len - 2);
            defer vm.gpa.free(buffer);

            var fixed: Io.Writer = .fixed(buffer);
            const w = &fixed;

            var index: usize = 1;
            while (true) {
                const b = slice[index];
                switch (b) {
                    '\\' => {
                        switch (slice[index + 1]) {
                            't' => try w.writeByte('\t'),
                            'n' => try w.writeByte('\n'),
                            'r' => try w.writeByte('\r'),
                            '\\' => try w.writeByte('\\'),
                            '"' => try w.writeByte('"'),
                            '/' => try w.writeByte('/'),
                            // Three octal digits, as `"\001"`; the tokenizer checked them.
                            '0'...'3' => {
                                try w.writeByte(std.fmt.parseInt(u8, slice[index + 1 .. index + 4], 8) catch unreachable);
                                index += 2;
                            },
                            else => unreachable,
                        }
                        index += 2;
                    },
                    '"' => break,
                    else => {
                        try w.writeByte(b);
                        index += 1;
                    },
                }
            }

            const buffered = fixed.buffered();
            if (buffered.len == 1) return vm.createValue(.char, buffered[0]);
            const char_list = try vm.allocValue(.char_list, buffered.len);
            errdefer comptime unreachable;
            @memcpy(char_list.as.char_list, buffered);
            return char_list;
        },
        .symbol_literal => {
            const main_token = tree.nodeMainToken(node);
            const slice = tree.tokenSlice(main_token);
            const symbol = try vm.intern(slice[1..]);
            const symbol_list = try vm.allocValue(.symbol_list, 1);
            errdefer comptime unreachable;
            symbol_list.as.symbol_list[0] = symbol;
            return symbol_list;
        },
        // A table literal is the flip of a column dictionary, `(+:;(!;,`a`b;(enlist;e1;e2)))`
        // as q parses it, and a keyed one `!` of the key and value tables.
        .table_literal => {
            const extra_index, _ = tree.nodeData(node).extra_and_token;
            const spans = tree.extraData(extra_index, Node.Table);
            const key_nodes = tree.extraDataSlice(.{ .start = spans.keys_start, .end = spans.columns_start }, Node.Index);
            const column_nodes = tree.extraDataSlice(.{ .start = spans.columns_start, .end = spans.columns_end }, Node.Index);
            const columns = try vm.tableTree(column_nodes);
            if (key_nodes.len == 0) return columns;
            errdefer columns.deref(gpa);
            const keys = try vm.tableTree(key_nodes);
            errdefer keys.deref(gpa);
            const keyed = try vm.allocValue(.list, 3);
            errdefer comptime unreachable;
            keyed.as.list[0] = vm.getOperator(.dict);
            keyed.as.list[1] = keys;
            keyed.as.list[2] = columns;
            return keyed;
        },
        .symbol_list_literal => {
            const first_token = tree.nodeMainToken(node);
            const last_token = tree.nodeData(node).token;
            const len = last_token - first_token + 1;

            const symbol_list = symbol_list: {
                var list: std.ArrayList(Symbol) = try .initCapacity(vm.gpa, len);
                defer list.deinit(vm.gpa);
                for (first_token..last_token + 1) |tok| {
                    const slice = tree.tokenSlice(@intCast(tok));
                    const symbol = try vm.intern(slice[1..]);
                    list.appendAssumeCapacity(symbol);
                }
                const symbol_list = try vm.createValue(.symbol_list, &.{});
                errdefer symbol_list.deref(vm.gpa);
                symbol_list.as.symbol_list = list.toOwnedSliceAssert();
                break :symbol_list symbol_list;
            };
            errdefer symbol_list.deref(vm.gpa);

            const list = try vm.allocValue(.list, 1);
            errdefer comptime unreachable;
            list.as.list[0] = symbol_list;
            return list;
        },
        .identifier => {
            const main_token = tree.nodeMainToken(node);
            const slice = tree.tokenSlice(main_token);
            const symbol = try vm.intern(slice);
            return vm.createValue(.symbol, symbol);
        },
        .keyword => {
            // q resolves keywords while parsing: `parse "neg 1"` holds `-:`, not `neg`. The
            // entry was there when the parser looked, so it is only missing if `.q` changed
            // since, in which case the name is left to run-time lookup.
            const slice = tree.tokenSlice(tree.nodeMainToken(node));
            if (vm.qEntry(slice)) |entry| return entry.ref();
            return vm.createValue(.symbol, try vm.intern(slice));
        },
        .builtin => {
            const builtin = std.meta.stringToEnum(Node.Builtin, tree.tokenSlice(tree.nodeMainToken(node))).?;
            switch (builtin) {
                inline else => |t| return if (comptime t.isDyadic())
                    vm.getOperator(@field(Operator, @tagName(t)))
                else
                    vm.getUnaryPrimitive(@field(UnaryPrimitive, @tagName(t))),
            }
        },

        .select, .exec, .update, .delete_rows, .delete_cols => return vm.queryTree(node),
    }
}

pub fn parseUnaryNode(vm: *Vm, node: Node.Index) !*Value {
    const tree = vm.tree;

    return switch (tree.nodeTag(node)) {
        .bang => vm.getUnaryPrimitive(.key),
        .hash => vm.getUnaryPrimitive(.count),
        .dollar => vm.getUnaryPrimitive(.string),
        .percent => vm.getUnaryPrimitive(.reciprocal),
        .ampersand => vm.getUnaryPrimitive(.where),
        .asterisk => vm.getUnaryPrimitive(.first),
        .plus => vm.getUnaryPrimitive(.flip),
        .comma => vm.getUnaryPrimitive(.list),
        .minus => vm.getUnaryPrimitive(.neg),
        .dot => vm.getUnaryPrimitive(.value),
        .colon => vm.getUnaryPrimitive(.identity),
        // `'x` at the top level parses as the char `'` applied, which `eval` signals; with
        // a function on its left the apostrophe is the each iterator.
        .apostrophe => if (tree.nodeData(node).opt_node == .none) vm.createValue(.char, '\'') else vm.parseNode(node),
        .l_angle_bracket => vm.getUnaryPrimitive(.asc),
        .equal => vm.getUnaryPrimitive(.group),
        .r_angle_bracket => vm.getUnaryPrimitive(.desc),
        .question_mark => vm.getUnaryPrimitive(.distinct),
        .at => vm.getUnaryPrimitive(.type),
        .caret => vm.getUnaryPrimitive(.null),
        .underscore => vm.getUnaryPrimitive(.lower),
        .pipe => vm.getUnaryPrimitive(.reverse),
        .tilde => vm.getUnaryPrimitive(.not),
        else => vm.parseNode(node),
    };
}

/// Runs a system command given as the text after its backslash, as `\d .Q` or `value "\\d"` would.
/// The command name is the text up to the first space; only exact names are built in, so
/// `\du -hs .` goes to the shell like any other unknown command.
pub fn system(vm: *Vm, command: []const u8) !*Value {
    const name_end = std.mem.findAny(u8, command, " \t") orelse command.len;
    const name = command[0..name_end];
    // A built-in command reads one word, so `\d .h / comment` and `\P 5 / c` ignore
    // the rest of the line as q does; the shell gets the whole line.
    const rest = std.mem.trim(u8, command[name_end..], " \t");
    const args = rest[0 .. std.mem.findAny(u8, rest, " \t") orelse rest.len];
    const Command = enum { a, b, c, C, cd, d, e, f, g, l, o, p, P, r, s, S, t, T, u, v, w, W, x, z, @"_", @"1", @"2", ts };
    if (command.len == 0) return vm.getUnaryPrimitive(.identity);
    // `\t:n expr` and `\ts:n expr` time `n` repetitions.
    if (std.mem.startsWith(u8, name, "t:") or std.mem.startsWith(u8, name, "ts:")) {
        const colon = std.mem.findScalar(u8, name, ':').?;
        const repeats = std.fmt.parseInt(usize, name[colon + 1 ..], 10) catch return vm.shell(command);
        return vm.timeExpression(rest, name[1] == 's', repeats);
    }
    const which = std.meta.stringToEnum(Command, name) orelse return vm.shell(command);
    switch (which) {
        .d => {
            if (args.len == 0) return vm.createValue(.symbol, vm.namespace);
            if (args[0] != '.') return error.domain;
            vm.namespace = try vm.intern(args);
            return vm.getUnaryPrimitive(.identity);
        },
        .P => {
            if (args.len == 0) return vm.createValue(.int, vm.precision);
            const precision = std.fmt.parseInt(u8, args, 10) catch return error.domain;
            vm.precision = @min(precision, q.decimal.max_precision);
            return vm.getUnaryPrimitive(.identity);
        },
        .S => {
            if (args.len == 0) return vm.createValue(.int, vm.seed);
            const seed = std.fmt.parseInt(i32, args, 10) catch return error.domain;
            if (seed == 0) return error.domain;
            vm.seed = seed;
            vm.random = .init(@bitCast(@as(i64, vm.seed)));
            return vm.getUnaryPrimitive(.identity);
        },
        // The console sizes: two numbers set them (kept within 10 and 2000), anything
        // else shows them, three numbers are `domain`.
        .c, .C => {
            const size = if (which == .c) &vm.console else &vm.console_web;
            var numbers: [3]i32 = undefined;
            var count: usize = 0;
            var it = std.mem.tokenizeAny(u8, rest, " \t");
            while (it.next()) |word| {
                const n = std.fmt.parseInt(i32, word, 10) catch break;
                if (count == 3) return error.domain;
                numbers[count] = n;
                count += 1;
            }
            if (count == 3) return error.domain;
            if (count == 2) {
                size[0] = @min(@max(numbers[0], 10), 2000);
                size[1] = @min(@max(numbers[1], 10), 2000);
                return vm.getUnaryPrimitive(.identity);
            }
            const result = try vm.allocValue(.int_list, 2);
            result.as.int_list[0] = size[0];
            result.as.int_list[1] = size[1];
            return result;
        },
        // Settings that are an int: shown bare, set with a number.
        .e, .g, .o, .t, .T, .W, .z => {
            const slot: *i32 = switch (which) {
                .e => &vm.error_trap,
                .g => &vm.gc_mode,
                .o => &vm.utc_offset,
                .t => &vm.timer,
                .T => &vm.timeout,
                .W => &vm.week_offset,
                .z => &vm.date_format,
                else => unreachable,
            };
            if (rest.len == 0) return vm.createValue(.int, slot.*);
            if (std.fmt.parseInt(i32, args, 10)) |n| {
                slot.* = n;
                return vm.getUnaryPrimitive(.identity);
            } else |_| {}
            if (which == .o and std.mem.eql(u8, args, "0N")) {
                slot.* = @backingInt(Value.Int.null);
                return vm.getUnaryPrimitive(.identity);
            }
            // `\t expr` times an expression in milliseconds.
            if (which == .t) return vm.timeExpression(rest, false, 1);
            return error.domain;
        },
        .ts => return vm.timeExpression(rest, true, 1),
        .s => {
            if (rest.len == 0) return vm.createValue(.int, 0);
            if (std.mem.eql(u8, args, "0")) return vm.getUnaryPrimitive(.identity);
            return vm.failWith("enable secondary threads via cmd line -s only");
        },
        .p => if (rest.len == 0) return vm.createValue(.int, 0) else return error.nyi,
        ._ => return vm.createValue(.boolean, false),
        .w => {
            const result = try vm.allocValue(.long_list, if (rest.len == 0) 6 else 2);
            @memset(result.as.long_list, 0);
            return result;
        },
        .cd => {
            if (rest.len == 0) {
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                const len = Io.Dir.cwd().realPathFile(vm.io, ".", &buffer) catch return error.os;
                return vm.createCharList("{s}", .{buffer[0..len]});
            }
            Io.Threaded.chdir(rest) catch |err| return q.internal.failOs(vm, rest, err);
            return vm.getUnaryPrimitive(.identity);
        },
        .l => {
            if (rest.len == 0 or rest.len != args.len) return error.nyi;
            return vm.loadScript(rest);
        },
        .x => {
            // Expunging a handler resets it; there is nothing to reset here.
            return vm.getUnaryPrimitive(.identity);
        },
        .a, .b, .f, .v => return vm.namespaceListing(which, rest),
        .r, .u, .@"1", .@"2" => return error.nyi,
    }
}

/// `\a`, `\b`, `\f` and `\v`: the tables, views, functions and variables of a namespace
/// (the current one, or the one named) as a sorted symbol list.
fn namespaceListing(vm: *Vm, which: anytype, path: []const u8) !*Value {
    const name = if (path.len == 0) vm.internedString(vm.namespace) else path;
    if (name.len == 0 or name[0] != '.') return vm.failWith(name);
    const namespace = (try vm.namespaceAt(name, false)) orelse return vm.failWith(name);
    const d = namespace.as.dict;
    var names: std.ArrayList(Symbol) = .empty;
    defer names.deinit(vm.gpa);
    for (d.keys.as.symbol_list, d.values.as.list) |key, value| {
        if (key == .empty) continue;
        if (value.as == .dict and value.as.dict.keys.as == .symbol_list and value.as.dict.keys.as.symbol_list.len > 0 and value.as.dict.keys.as.symbol_list[0] == .empty) continue;
        const wanted = switch (which) {
            .a => value.as == .table,
            .b => false,
            .f => isFunction(value),
            .v => !isFunction(value),
            else => unreachable,
        };
        if (wanted) try names.append(vm.gpa, key);
    }
    const Context = struct {
        vm: *Vm,
        fn lessThan(ctx: @This(), a: Symbol, b: Symbol) bool {
            return std.mem.order(u8, ctx.vm.internedString(a), ctx.vm.internedString(b)) == .lt;
        }
    };
    std.sort.block(Symbol, names.items, Context{ .vm = vm }, Context.lessThan);
    const result = try vm.allocValue(.symbol_list, names.items.len);
    @memcpy(result.as.symbol_list, names.items);
    return result;
}

/// `\t expr` and `\ts expr`: the milliseconds an expression takes, with `ts` the bytes
/// it used as well (none counted here).
fn timeExpression(vm: *Vm, text: []const u8, with_space: bool, repeats: usize) !*Value {
    const source = try vm.gpa.dupeSentinel(u8, text, 0);
    defer vm.gpa.free(source);
    const started = q.clock.now(vm.io);
    for (0..repeats) |_| {
        const value = try vm.evalSource(source, .q, "<timed>");
        value.deref(vm.gpa);
    }
    const elapsed: i64 = @divFloor(q.clock.now(vm.io) - started, 1_000_000);
    if (!with_space) return vm.createValue(.long, elapsed);
    const result = try vm.allocValue(.long_list, 2);
    result.as.long_list[0] = elapsed;
    result.as.long_list[1] = 0;
    return result;
}

/// `\l path`: runs a script, `.k` files in k mode and others in q mode, statement by
/// statement (a line and the indented lines after it), showing the value of every
/// expression that is not an assignment as the console would. A line holding only `/`
/// starts a block comment that a line holding only `\` ends, and such a `\` outside a
/// block ends the script. The namespace `\d` had is restored afterwards.
pub fn loadScript(vm: *Vm, path: []const u8) RunError!*Value {
    const source = Io.Dir.cwd().readFileAlloc(vm.io, path, vm.gpa, .unlimited) catch |err| return q.internal.failOs(vm, path, err);
    defer vm.gpa.free(source);
    const mode: Ast.Mode = if (std.mem.endsWith(u8, path, ".k")) .k else .q;
    return vm.runScript(source, mode, path, .script);
}

/// How statements run in sequence report their values, as q 4.0 does (checked with
/// minimal q.k files): a script (`\l`, q.k at startup, `openq file.q`) writes the k
/// display of every value but `::` and stops at the first error; the console (piped
/// standard input) shows every value through `.Q.s`, reports an error with the time
/// and carries on.
pub const Echo = enum { script, console };

fn runStatement(vm: *Vm, text: [:0]const u8, mode: Ast.Mode, path: []const u8, echo: Echo) RunError!void {
    const value = vm.evalSource(text, mode, path) catch |err| switch (echo) {
        .script => return err,
        .console => return vm.reportError(err, true),
    };
    defer value.deref(vm.gpa);
    switch (echo) {
        .console => vm.show(value) catch |err| try vm.reportError(err, true),
        .script => {
            if (value.as == .unary_primitive and value.as.unary_primitive == .identity) return;
            try vm.stdout.print("{f}\n", .{value.fmt(vm)});
            try vm.stdout.flush();
        },
    }
}

/// Reports an error on stderr as the console does: `'name`, or the signal's text, and
/// when `stamped` (the console reading a pipe) the local time first, as q 4.0 writes
/// `'2026.09.22T21:43:30.613 nosuch`.
pub fn reportError(vm: *Vm, err: RunError, stamped: bool) RunError!void {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    const text = if (err == error.signal or err == error.identifier) (vm.signal_message orelse @errorName(err)) else @errorName(err);
    try vm.stdout.flush();
    if (stamped) {
        const now = (try vm.clockVariable(try vm.intern(".z.Z"))).?;
        defer now.deref(vm.gpa);
        std.debug.print("'{f} {s}\n", .{ now.fmt(vm), text });
    } else std.debug.print("'{s}\n", .{text});
}

/// Shows a value on stdout as the q console does (checked against q 4.0 with minimal
/// q.k files): every result, `::` included, goes through `.Q.s` when it is defined
/// and the string it returns is written as it is (q.k's gives `""` for `::`, so an
/// assignment shows nothing; anything but a string shows nothing); an error from
/// `.Q.s` is the statement's error. Without `.Q.s` the console writes the k display
/// and a newline, and nothing for `::`.
pub fn show(vm: *Vm, value: *Value) RunError!void {
    defer vm.stdout.flush() catch {};
    const s = vm.readGlobal(try vm.intern(".Q.s")) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (value.as == .unary_primitive and value.as.unary_primitive == .identity) return;
            return vm.stdout.print("{f}\n", .{value.fmt(vm)});
        },
    };
    defer s.deref(vm.gpa);
    var args = [_]*Value{value};
    const shown = try vm.applyImpl(s, &args);
    defer shown.deref(vm.gpa);
    if (shown.as != .char_list) return;
    try vm.stdout.writeAll(shown.as.char_list);
}

/// Runs script text statement by statement (a line and the indented lines after it).
pub fn runScript(vm: *Vm, source: []const u8, mode: Ast.Mode, path: []const u8, echo: Echo) RunError!*Value {
    const saved = vm.namespace;
    defer vm.namespace = saved;

    var statement: std.ArrayList(u8) = .empty;
    defer statement.deinit(vm.gpa);
    var in_comment = false;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var pending: ?[]const u8 = null;
    while (true) {
        const line = pending orelse lines.next();
        pending = null;
        const continues = line != null and line.?.len > 0 and (line.?[0] == ' ' or line.?[0] == '\t');
        if (continues and statement.items.len > 0) {
            try statement.append(vm.gpa, '\n');
            try statement.appendSlice(vm.gpa, line.?);
            continue;
        }
        // The statement gathered so far is complete.
        if (statement.items.len > 0) {
            const trimmed = std.mem.trim(u8, statement.items, " \t\r");
            if (std.mem.eql(u8, trimmed, "/")) {
                in_comment = true;
            } else if (std.mem.eql(u8, trimmed, "\\")) {
                if (!in_comment) break;
                in_comment = false;
            } else if (echo == .console and std.mem.eql(u8, trimmed, "\\\\")) {
                // `\\` ends a console session.
                break;
            } else if (!in_comment and trimmed.len > 0 and trimmed[0] != '/') {
                const text = try vm.gpa.dupeSentinel(u8, trimmed, 0);
                defer vm.gpa.free(text);
                try vm.runStatement(text, mode, path, echo);
            }
            statement.clearRetainingCapacity();
        }
        const next = line orelse break;
        try statement.appendSlice(vm.gpa, std.mem.trimEnd(u8, next, "\r"));
    }
    return vm.getUnaryPrimitive(.identity);
}

/// Runs `command` the way q does: as `sh -c "<command> ><file>"` with a temporary file, so
/// the redirection binds to the last simple command and overrides any stdout redirection
/// there, while stderr and the output of earlier commands go to the terminal. The file's
/// lines come back as a list of strings; a failing command is an `os` error.
fn shell(vm: *Vm, command: []const u8) !*Value {
    var random: [8]u8 = undefined;
    vm.io.random(&random);
    var path_buffer: [32]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "/tmp/openq{x:0>16}", .{
        std.mem.readInt(u64, &random, .little),
    }) catch unreachable;

    const dir: Io.Dir = .cwd();
    const file = dir.createFile(vm.io, path, .{ .exclusive = true }) catch return error.os;
    file.close(vm.io);
    defer dir.deleteFile(vm.io, path) catch {};

    const script = try std.fmt.allocPrint(vm.gpa, "{s} >{s}", .{ command, path });
    defer vm.gpa.free(script);

    // The child shares the terminal, so flush anything queued ahead of its output.
    try vm.stdout.flush();
    var child = std.process.spawn(vm.io, .{ .argv = &.{ "/bin/sh", "-c", script } }) catch return error.os;
    const term = child.wait(vm.io) catch return error.os;
    if (!term.success()) return error.os;

    const output = dir.readFileAlloc(vm.io, path, vm.gpa, .unlimited) catch return error.os;
    defer vm.gpa.free(output);

    // One string per line; a trailing newline does not add an empty line.
    const trimmed = std.mem.trimEnd(u8, output, "\n");
    const count = if (trimmed.len == 0) 0 else std.mem.countScalar(u8, trimmed, '\n') + 1;
    const lines = try vm.allocValue(.list, count);
    var filled: usize = 0;
    errdefer {
        for (lines.as.list[0..filled]) |line| line.deref(vm.gpa);
        vm.gpa.free(lines.as.list);
        vm.gpa.destroy(lines);
    }
    var it = std.mem.splitScalar(u8, trimmed, '\n');
    while (it.next()) |line| {
        if (filled == count) break;
        const string = try vm.allocValue(.char_list, line.len);
        @memcpy(string.as.char_list, line);
        lines.as.list[filled] = string;
        filled += 1;
    }
    return lines;
}

pub const Home = struct {
    /// The namespace dictionary holding the name. Borrowed, not referenced.
    namespace: *Value,
    name: Symbol,
};

/// Finds the dictionary an identifier lives in and its bare name, as q does: a bare name
/// lives in the current namespace (`\d`), `.Q.qt` lives in the namespace `.Q`, and a
/// single-component name such as `.x` is an entry of the root directory `` ` `` beside the
/// namespaces, distinct from the bare global `x` whatever the current namespace. Missing
/// namespaces are created when `create` is set; otherwise null is returned.
pub fn identifierHome(vm: *Vm, identifier: Symbol, create: bool) !?Home {
    // Interning below may move the string bytes, so work on a copy.
    const string = try vm.gpa.dupe(u8, vm.internedString(identifier));
    defer vm.gpa.free(string);
    assert(string.len > 0);

    if (string[0] != '.') {
        // A name with a dot inside it, such as a file symbol `:/a/b.txt`, is no global.
        if (std.mem.findScalar(u8, string, '.') != null) return null;
        const namespace = (try vm.namespaceAt(vm.internedString(vm.namespace), create)) orelse return null;
        return .{ .namespace = namespace, .name = identifier };
    }

    const last_dot = std.mem.findScalarLast(u8, string, '.').?;
    if (last_dot == 0) return .{ .namespace = vm.state, .name = try vm.intern(string[1..]) };
    const namespace = (try vm.namespaceAt(string[0..last_dot], create)) orelse return null;
    return .{ .namespace = namespace, .name = try vm.intern(string[last_dot + 1 ..]) };
}

/// The value of a global name: a clock variable, the root for `` ` ``, or the entry found
/// through `identifierHome`, so a bare name reads from the current namespace.
pub fn readGlobal(vm: *Vm, identifier: Symbol) RunError!*Value {
    return vm.readGlobalIn(identifier, vm.namespace);
}

/// A global read with bare names taken from `scope`: a lambda reads its bare globals in
/// the namespace it was defined in, while a symbol names a global in the `\d` namespace.
pub fn readGlobalIn(vm: *Vm, identifier: Symbol, scope: Symbol) RunError!*Value {
    if (identifier == .empty) return vm.state.ref();
    if (try vm.clockVariable(identifier)) |clock| return clock;
    const saved = vm.namespace;
    vm.namespace = scope;
    defer vm.namespace = saved;
    const home = (try vm.identifierHome(identifier, false)) orelse return vm.undefinedName(identifier);
    const dict = home.namespace.as.dict;
    const index = std.mem.findScalar(Symbol, dict.keys.as.symbol_list, home.name) orelse return vm.undefinedName(identifier);
    return dict.values.as.list[index].ref();
}

/// An undefined name is the error `identifier`, reported as q reports it: by the name
/// (`'oops`), which the signal message carries.
pub fn undefinedName(vm: *Vm, identifier: Symbol) RunError {
    const message = try vm.gpa.dupe(u8, vm.internedString(identifier));
    if (vm.signal_message) |old| vm.gpa.free(old);
    vm.signal_message = message;
    return error.identifier;
}

/// Reading a parameter or local that has no value yet is `identifier`, named as q names it.
fn unsetLocal(vm: *Vm, lambda: Value.Lambda, slot: usize) RunError {
    const name = if (slot < lambda.params.len) lambda.params[slot] else lambda.locals[slot - lambda.params.len];
    return vm.undefinedName(name);
}

/// Runs a lambda: too many arguments are a rank error and too few or a hole make a
/// projection. Every lambda takes at least one argument, `{[]1}` included, whose single
/// parameter is unnamed, so `f[]` passes `::` to it. Parameters are filled from the
/// arguments, locals start unset (reading one is an error, as in q), and bare global names
/// resolve in the namespace the lambda was defined in, which is also where `x::v` assigns.
pub fn callLambda(vm: *Vm, func: *Value, args: []*Value) RunError!*Value {
    const lambda = func.as.lambda;
    assert(lambda.params.len > 0);
    const given = args;
    if (given.len > lambda.params.len) return error.rank;
    const has_hole = for (given) |a| {
        if (a.isEmpty()) break true;
    } else false;
    if (given.len < lambda.params.len or has_hole) return vm.project(func, given);

    const slots = try vm.gpa.alloc(?*Value, lambda.params.len + lambda.locals.len);
    defer {
        for (slots) |slot| if (slot) |v| v.deref(vm.gpa);
        vm.gpa.free(slots);
    }
    @memset(slots, null);
    for (slots[0..given.len], given) |*slot, a| slot.* = a.ref();

    var stack: std.ArrayList(*Value) = .empty;
    defer {
        for (stack.items) |v| v.deref(vm.gpa);
        stack.deinit(vm.gpa);
    }
    // The counts of the `do` loops in progress, innermost last.
    var counters: std.ArrayList(i64) = .empty;
    defer counters.deinit(vm.gpa);

    const code = lambda.bytecode;
    var pc: usize = 0;
    // q returns `::` from a lambda whose last statement was an amend (`{a::5}[]`), while
    // the amend still has its value inside an expression (`{(a::5)+1}[]` is 6).
    var after_amend = false;
    while (pc < code.len) {
        const byte = code[pc];
        pc += 1;
        if (byte >= @backingInt(Compiler.ByteCode.constant)) {
            try stack.append(vm.gpa, lambda.constants[byte - @backingInt(Compiler.ByteCode.constant)].ref());
            after_amend = false;
            continue;
        }
        if (byte >= @backingInt(Compiler.ByteCode.global)) {
            try stack.append(vm.gpa, try vm.readGlobalIn(lambda.globals[byte - @backingInt(Compiler.ByteCode.global)], lambda.namespace));
            after_amend = false;
            continue;
        }
        const op: Compiler.ByteCode = @fromBackingInt(byte);
        defer after_amend = op == .amend;
        switch (op) {
            .@"return" => {
                const result = stack.pop().?;
                if (!after_amend) return result;
                result.deref(vm.gpa);
                return vm.getUnaryPrimitive(.identity);
            },
            .pop => stack.pop().?.deref(vm.gpa),
            .nil => try stack.append(vm.gpa, vm.getUnaryPrimitive(.identity)),
            .empty => try stack.append(vm.gpa, vm.getUnaryPrimitive(.empty)),
            .empty_list => try stack.append(vm.gpa, vm.getConstant(.empty_list)),
            .zero => try stack.append(vm.gpa, vm.getConstant(.zero)),
            .one => try stack.append(vm.gpa, vm.getConstant(.one)),
            .null_symbol => try stack.append(vm.gpa, vm.getConstant(.null_symbol)),
            .self => try stack.append(vm.gpa, func.ref()),
            .global => unreachable, // handled above with the indexed forms
            .assign => {
                const slot = slotIndex(lambda, code[pc]);
                pc += 1;
                const value = stack.items[stack.items.len - 1];
                if (slots[slot]) |old| old.deref(vm.gpa);
                slots[slot] = value.ref();
            },
            .amend => {
                // `.[target;index;op;value]` with the value pushed first, then the index:
                // `x::v` has index `()` and `:`, `x+:v` index `()` and `+`, `x[i]:v` the
                // index list `,i`. The amended items are the expression's value, as q has
                // `b:a+:2` set `b` to the new `a` and `b:a[0]+:5` to the new item.
                const target = code[pc];
                const operator: Operator = @fromBackingInt(@as(@typeInfo(Operator).@"enum".tag_type, @intCast(code[pc + 1])));
                pc += 2;
                const index = stack.pop().?;
                defer index.deref(vm.gpa);
                const value = stack.items[stack.items.len - 1];
                const is_global = target >= @backingInt(Compiler.ByteCode.global);
                const plain = operator == .assign and index.isList() and index.count() == 0;
                const new_value = if (plain) value.ref() else amended: {
                    const old = if (is_global)
                        try vm.readGlobalIn(lambda.globals[target - @backingInt(Compiler.ByteCode.global)], lambda.namespace)
                    else
                        (slots[slotIndex(lambda, target)] orelse return vm.unsetLocal(lambda, slotIndex(lambda, target))).ref();
                    defer old.deref(vm.gpa);
                    const function = vm.getOperator(operator);
                    defer function.deref(vm.gpa);
                    break :amended try vm.amendValue(old, index, function, value);
                };
                defer new_value.deref(vm.gpa);
                if (is_global) {
                    const symbol = try vm.createValue(.symbol, lambda.globals[target - @backingInt(Compiler.ByteCode.global)]);
                    defer symbol.deref(vm.gpa);
                    const saved = vm.namespace;
                    vm.namespace = lambda.namespace;
                    defer vm.namespace = saved;
                    _ = try q.operators.assignGlobal(vm, symbol, new_value);
                } else {
                    const slot = slotIndex(lambda, target);
                    if (slots[slot]) |old| old.deref(vm.gpa);
                    slots[slot] = new_value.ref();
                }
                const result = try vm.amendedItems(new_value, index, plain, value);
                stack.items[stack.items.len - 1] = result;
                value.deref(vm.gpa);
            },
            .signal => {
                const v = stack.pop().?;
                defer v.deref(vm.gpa);
                return vm.raiseSignal(v);
            },
            .jump => pc = pc + std.mem.readInt(u16, code[pc..][0..2], .little),
            .jump_back => pc = pc - std.mem.readInt(u16, code[pc..][0..2], .little),
            .jump_if_false => {
                const condition = stack.pop().?;
                defer condition.deref(vm.gpa);
                if (try truthy(condition)) pc += 2 else pc = pc + std.mem.readInt(u16, code[pc..][0..2], .little);
            },
            .do_init => {
                const count = stack.pop().?;
                defer count.deref(vm.gpa);
                try counters.append(vm.gpa, try loopCount(count));
            },
            .do_step => {
                const remaining = &counters.items[counters.items.len - 1];
                if (remaining.* > 0) {
                    remaining.* -= 1;
                    pc += 2;
                } else {
                    _ = counters.pop();
                    pc = pc + std.mem.readInt(u16, code[pc..][0..2], .little);
                }
            },
            .query => {
                const query = stack.pop().?;
                defer query.deref(vm.gpa);
                const saved_scope = vm.scope;
                vm.scope = .{ .lambda = &lambda, .slots = slots };
                defer vm.scope = saved_scope;
                try stack.append(vm.gpa, try vm.eval(query));
            },
            .call => {
                const count = code[pc];
                pc += 1;
                const callee = stack.pop().?;
                defer callee.deref(vm.gpa);
                const call_args = try vm.gpa.alloc(*Value, count);
                defer vm.gpa.free(call_args);
                for (call_args) |*a| a.* = stack.pop().?;
                defer for (call_args) |a| a.deref(vm.gpa);
                try stack.append(vm.gpa, try vm.applyImpl(callee, call_args));
            },
            .param_1, .param_2, .param_3, .param_4, .param_5, .param_6, .param_7, .param_8 => {
                const slot = byte - @backingInt(Compiler.ByteCode.param_1);
                try stack.append(vm.gpa, (slots[slot] orelse return vm.unsetLocal(lambda, slot)).ref());
            },
            .local_wide => {
                const slot = slotIndex(lambda, code[pc]);
                pc += 1;
                try stack.append(vm.gpa, (slots[slot] orelse return vm.unsetLocal(lambda, slot)).ref());
            },
            .comma => unreachable,
            inline else => |t| {
                const name = @tagName(t);
                if (comptime std.mem.startsWith(u8, name, "local_")) {
                    const slot = lambda.params.len + (byte - @backingInt(Compiler.ByteCode.local_1));
                    try stack.append(vm.gpa, (slots[slot] orelse return vm.unsetLocal(lambda, slot)).ref());
                } else if (@hasField(Iterator, name)) {
                    // An iterator instruction turns the function on top of the stack into
                    // the derived function, as q compiles `x+/y` to push `+` then `over`.
                    const function = stack.pop().?;
                    defer function.deref(vm.gpa);
                    try stack.append(vm.gpa, try vm.derive(@field(Iterator, name), function));
                } else if (@hasField(UnaryPrimitive, name)) {
                    // A primitive applies to the value on top of the stack.
                    const x = stack.pop().?;
                    defer x.deref(vm.gpa);
                    const primitive = vm.getUnaryPrimitive(@field(UnaryPrimitive, name));
                    defer primitive.deref(vm.gpa);
                    var operands = [_]*Value{x};
                    try stack.append(vm.gpa, try vm.applyImpl(primitive, &operands));
                } else if (@hasField(Operator, name)) {
                    // An operator applies to the top two: the left operand is on top, as
                    // the right one was pushed first.
                    const x = stack.pop().?;
                    defer x.deref(vm.gpa);
                    const y = stack.pop().?;
                    defer y.deref(vm.gpa);
                    const operator = vm.getOperator(@field(Operator, name));
                    defer operator.deref(vm.gpa);
                    var operands = [_]*Value{ x, y };
                    try stack.append(vm.gpa, try vm.applyImpl(operator, &operands));
                } else {
                    unreachable;
                }
            },
        }
    }
    unreachable;
}

/// The array index of a q slot: parameters are slots 1 to 8, locals start at 9.
/// The fewest arguments a function applies with: two for `.`, `@`, `?` and `!`, whose
/// three- and four-argument forms are the amend, trap, conditional and functional ones.
fn minRank(value: *Value) usize {
    const flexible = struct {
        fn of(v: *Value) bool {
            return v.as == .operator and switch (v.as.operator) {
                .apply, .apply_at, .find, .dict => true,
                else => false,
            };
        }
    }.of;
    if (flexible(value)) return 2;
    // A projection of one, `x@`, wants the rest of the two (or its holes, if more).
    if (value.as == .projection and flexible(value.as.projection.callee)) {
        var holes: usize = 0;
        for (value.as.projection.args) |a| {
            if (a.isEmpty()) holes += 1;
        }
        const given = value.as.projection.args.len - holes;
        return @max(holes, 2 -| given);
    }
    return value.rank();
}

fn slotIndex(lambda: Value.Lambda, slot: u8) usize {
    return if (slot <= 8) slot - 1 else lambda.params.len + slot - 9;
}

/// `.[old;index;f;value]` as compound and indexed assignment, `@` and `.` produce it: an
/// empty index applies `f` to the whole value (`x+:v`, `.[x;();+;v]`), and otherwise
/// `index` holds one index per dimension, each an integer, a list of integers or a hole
/// (`::`) for every item. Without `value`, `f` is applied to each item alone (`@[x;i;-:]`).
pub fn amendValue(vm: *Vm, old: *Value, index: *Value, function: *Value, value: ?*Value) RunError!*Value {
    if (!index.isList()) return error.type;
    if (index.count() == 0) return vm.applyAmend(function, old, value);
    return vm.amendAt(old, index, 0, function, value);
}

/// `f[x;y]` or `f[x]` for an amend; `:` puts `y` in place.
fn applyAmend(vm: *Vm, function: *Value, x: *Value, y: ?*Value) RunError!*Value {
    if (function.as == .operator and function.as.operator == .assign) return (y orelse x).ref();
    // An atom in the function's place is `domain`, or `length` with a fourth argument, as
    // q reports `@[1 2 3;0;3]`; a list or a dictionary indexes and a symbol applies as
    // the global it names (`@[1 2 3;0;1 2]` is `2 2 3`).
    if (!isFunction(function) and function.as != .symbol and !function.isList() and function.as != .dict) return if (y == null) error.domain else error.length;
    if (y) |v| {
        var operands = [_]*Value{ x, v };
        return vm.applyImpl(function, &operands);
    }
    var operand = [_]*Value{x};
    return vm.applyImpl(function, &operand);
}

fn amendAt(vm: *Vm, old: *Value, index: *Value, dim: usize, function: *Value, value: ?*Value) RunError!*Value {
    if (old.as == .dict) return vm.amendDictAt(old, index, dim, function, value);
    if (old.as == .table) return vm.amendTableAt(old, index, dim, function, value);
    if (!old.isList()) return error.type;
    const at = try q.operators.itemAt(vm, index, dim);
    defer at.deref(vm.gpa);
    const last = dim + 1 == index.count();
    const all = at.isEmpty() or (at.as == .unary_primitive and at.as.unary_primitive == .identity);

    if (!all and !at.isList()) {
        // One position, with the value or the amended item put in its place.
        const i = try position(at, old.count());
        const item = try q.operators.itemAt(vm, old, i);
        defer item.deref(vm.gpa);
        const new_item = if (last) try vm.applyAmend(function, item, value) else try vm.amendAt(item, index, dim + 1, function, value);
        defer new_item.deref(vm.gpa);
        return vm.withItem(old, i, new_item);
    }

    // Every position, or each of a list of them; a value with one item per position is
    // spread over them, anything else goes to each (`a[0 1]:8 9` and `a[0 1]:9`).
    const count = if (all) old.count() else at.count();
    const spread = value != null and value.?.isList() and value.?.count() == count;
    var result = old.ref();
    errdefer result.deref(vm.gpa);
    for (0..count) |k| {
        const i = if (all) k else i: {
            const which = try q.operators.itemAt(vm, at, k);
            defer which.deref(vm.gpa);
            break :i try position(which, old.count());
        };
        const v: ?*Value = if (value) |whole| (if (spread) try q.operators.itemAt(vm, whole, k) else whole.ref()) else null;
        defer if (v) |each| each.deref(vm.gpa);
        const item = try q.operators.itemAt(vm, result, i);
        defer item.deref(vm.gpa);
        const new_item = if (last) try vm.applyAmend(function, item, v) else try vm.amendAt(item, index, dim + 1, function, v);
        defer new_item.deref(vm.gpa);
        const next = try vm.withItem(result, i, new_item);
        result.deref(vm.gpa);
        result = next;
    }
    return result;
}

/// Amending a table: a column name amends the column dictionary (a new column is added,
/// an atom spread to the rows), and a row index followed by a column name amends that
/// cell, as `.[t;(0;`a);:;9]`.
fn amendTableAt(vm: *Vm, old: *Value, index: *Value, dim: usize, function: *Value, value: ?*Value) RunError!*Value {
    const at = try q.operators.itemAt(vm, index, dim);
    defer at.deref(vm.gpa);
    const columns = try vm.createValue(.dict, .{ .keys = old.as.table.keys.ref(), .values = old.as.table.values.ref() });
    defer columns.deref(vm.gpa);
    switch (at.as) {
        .symbol, .symbol_list => {
            const amended = try vm.amendDictAt(columns, index, dim, function, value);
            defer amended.deref(vm.gpa);
            return q.operators.makeTable(vm, amended.as.dict.keys, amended.as.dict.values);
        },
        else => {
            if (dim + 1 >= index.count()) return error.nyi;
            const column = try q.operators.itemAt(vm, index, dim + 1);
            defer column.deref(vm.gpa);
            if (column.as != .symbol) return error.type;
            // Swap the indices: the column first, then the row within it.
            const swapped = try vm.allocValue(.list, index.count() - dim);
            defer swapped.deref(vm.gpa);
            swapped.as.list[0] = column.ref();
            swapped.as.list[1] = at.ref();
            for (swapped.as.list[2..], 0..) |*slot, k| slot.* = try q.operators.itemAt(vm, index, dim + 2 + k);
            const amended = try vm.amendDictAt(columns, swapped, 0, function, value);
            defer amended.deref(vm.gpa);
            return q.operators.makeTable(vm, amended.as.dict.keys, amended.as.dict.values);
        },
    }
}

/// Amending a dictionary by key: an existing key's value is amended in place, a missing
/// key is appended with the value itself (the function is not applied, so
/// `` @[`a`b!1 2;`c;+;5] `` is `` `a`b`c!1 2 5 ``) or, deeper, with the amended null
/// shaped like the values; a list of keys amends each in turn. Typed keys and values
/// only take atoms of their type, as `withItem` and `join` insist.
fn amendDictAt(vm: *Vm, old: *Value, index: *Value, dim: usize, function: *Value, value: ?*Value) RunError!*Value {
    const at = try q.operators.itemAt(vm, index, dim);
    defer at.deref(vm.gpa);
    if (at.isEmpty() or (at.as == .unary_primitive and at.as.unary_primitive == .identity)) return error.nyi;
    if (at.isList()) {
        const count = at.count();
        const spread = value != null and value.?.isList() and value.?.count() == count;
        var result = old.ref();
        errdefer result.deref(vm.gpa);
        for (0..count) |k| {
            const key = try q.operators.itemAt(vm, at, k);
            defer key.deref(vm.gpa);
            const v: ?*Value = if (value) |whole| (if (spread) try q.operators.itemAt(vm, whole, k) else whole.ref()) else null;
            defer if (v) |each| each.deref(vm.gpa);
            const next = try vm.amendDictKey(result, key, index, dim, function, v);
            result.deref(vm.gpa);
            result = next;
        }
        return result;
    }
    return vm.amendDictKey(old, at, index, dim, function, value);
}

fn amendDictKey(vm: *Vm, old: *Value, key: *Value, index: *Value, dim: usize, function: *Value, value: ?*Value) RunError!*Value {
    const dict = old.as.dict;
    const last = dim + 1 == index.count();
    if (try vm.keyPosition(dict.keys, key)) |i| {
        const item = try q.operators.itemAt(vm, dict.values, i);
        defer item.deref(vm.gpa);
        const new_item = if (last) try vm.applyAmend(function, item, value) else try vm.amendAt(item, index, dim + 1, function, value);
        defer new_item.deref(vm.gpa);
        const values = try vm.withItem(dict.values, i, new_item);
        errdefer values.deref(vm.gpa);
        return vm.createValue(.dict, .{ .keys = dict.keys.ref(), .values = values });
    }
    const new_item = if (last)
        (if (value) |v| v.ref() else blk: {
            const missing = try q.operators.nullLike(vm, dict.values);
            defer missing.deref(vm.gpa);
            break :blk try vm.applyAmend(function, missing, null);
        })
    else blk: {
        const missing = try q.operators.nullLike(vm, dict.values);
        defer missing.deref(vm.gpa);
        break :blk try vm.amendAt(missing, index, dim + 1, function, value);
    };
    defer new_item.deref(vm.gpa);
    // A typed value list only grows by an atom of its own type.
    if (dict.values.as != .list and @backingInt(std.meta.activeTag(new_item.as)) != -@backingInt(std.meta.activeTag(dict.values.as))) return error.type;
    const keys = try vm.appendItem(dict.keys, key);
    errdefer keys.deref(vm.gpa);
    const values = try vm.appendItem(dict.values, new_item);
    errdefer values.deref(vm.gpa);
    return vm.createValue(.dict, .{ .keys = keys, .values = values });
}

/// `list` with `item` added as one more item: joined onto a typed list, appended whole to
/// a general one (so a list value stays one entry).
fn appendItem(vm: *Vm, list: *Value, item: *Value) RunError!*Value {
    if (list.as != .list) return q.operators.join(vm, list, item);
    const items = list.as.list;
    const result = try vm.allocValue(.list, items.len + 1);
    errdefer comptime unreachable;
    for (result.as.list[0..items.len], items) |*r, v| r.* = v.ref();
    result.as.list[items.len] = item.ref();
    return result;
}

/// An index into a list of `count` items: an integer in range, or `length` as q says.
fn position(at: *Value, count: usize) error{ type, length }!usize {
    const i: i64 = switch (at.as) {
        .boolean => |b| @intFromBool(b),
        .byte => |b| b,
        .char => |c| c,
        .short => |v| v,
        .int => |v| v,
        .long => |v| v,
        else => return error.type,
    };
    if (i < 0 or i >= count) return error.length;
    return @intCast(i);
}

/// A copy of `list` with item `i` replaced. A typed list only takes an atom of its own
/// type, as `1 2 3` cannot hold `` `s `` or `1h`; a general list takes anything.
fn withItem(vm: *Vm, list: *Value, i: usize, item: *Value) RunError!*Value {
    switch (list.as) {
        .list => |items| {
            const result = try vm.allocValue(.list, items.len);
            for (result.as.list, items) |*r, v| r.* = v.ref();
            result.as.list[i].deref(vm.gpa);
            result.as.list[i] = item.ref();
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
            const atom_tag = comptime @as(Value.Type, @fromBackingInt(-@backingInt(tag)));
            if (item.as != atom_tag) return error.type;
            const result = try vm.allocValue(tag, items.len);
            @memcpy(@field(result.as, @tagName(tag)), items);
            @field(result.as, @tagName(tag))[i] = @field(item.as, @tagName(atom_tag));
            return result;
        },
        else => return error.type,
    }
}

/// A table from rows that are dictionaries over one set of symbol keys, each column the
/// unified values of one key.
fn tableOfRows(vm: *Vm, rows: []*Value) RunError!*Value {
    const keys = rows[0].as.dict.keys;
    const n = keys.count();
    const columns = try vm.allocValue(.list, n);
    var filled: usize = 0;
    errdefer {
        for (columns.as.list[0..filled]) |c| c.deref(vm.gpa);
        vm.gpa.free(columns.as.list);
        vm.gpa.destroy(columns);
    }
    const cells = try vm.gpa.alloc(*Value, rows.len);
    defer vm.gpa.free(cells);
    for (0..n) |k| {
        var got: usize = 0;
        defer for (cells[0..got]) |c| c.deref(vm.gpa);
        for (rows) |row| {
            cells[got] = try q.operators.itemAt(vm, row.as.dict.values, k);
            got += 1;
        }
        columns.as.list[filled] = try vm.enlist(cells);
        filled += 1;
    }
    defer columns.deref(vm.gpa);
    return q.operators.makeTable(vm, keys, columns);
}

/// Indexing a table, as `t[i]`, `t[i;c]` or `t c`: a symbol reads a column (a missing
/// one the null shaped like the first column) and a symbol list the columns; an integer
/// reads a row as a dictionary (a row of nulls past the end) and an integer list the
/// rows as a table; `::` or a hole keeps the table; further indices apply to what was
/// read, so `t[0;`a]` is an item and `t[0 1;`a]` a column. A symbol may only come first
/// on its own: `t[`a;0]` is `type`.
fn indexTable(vm: *Vm, table: *Value, args: []*Value) RunError!*Value {
    const t = table.as.table;
    const first = args[0];
    const rest = args[1..];
    if (first.isEmpty() or (first.as == .unary_primitive and first.as.unary_primitive == .identity)) {
        if (rest.len == 0) return table.ref();
        // After `::` only a column name may follow: `t[;0]` is `type`.
        if (rest[0].as != .symbol and rest[0].as != .symbol_list) return error.type;
        return vm.indexTable(table, rest);
    }
    switch (first.as) {
        .symbol, .symbol_list => {
            if (rest.len > 0) return error.type;
            const columns = try vm.createValue(.dict, .{ .keys = t.keys.ref(), .values = t.values.ref() });
            defer columns.deref(vm.gpa);
            return vm.indexDict(columns, args);
        },
        .boolean, .byte, .short, .int, .long => {
            const i: ?usize = switch (first.as) {
                .boolean => |b| @intFromBool(b),
                .byte => |b| b,
                .short => |v| if (v == @backingInt(Value.Short.null) or v < 0) null else @intCast(v),
                .int => |v| if (v == @backingInt(Value.Int.null) or v < 0) null else @intCast(v),
                .long => |v| if (v == @backingInt(Value.Long.null) or v < 0) null else @intCast(v),
                else => unreachable,
            };
            const row = try q.operators.rowAt(vm, table, i orelse std.math.maxInt(usize));
            if (rest.len == 0) return row;
            defer row.deref(vm.gpa);
            return vm.applyImpl(row, rest);
        },
        .list => |items| {
            if (items.len == 0) return vm.allocValue(.list, 0);
            return error.type;
        },
        .boolean_list, .byte_list, .short_list, .int_list, .long_list => {
            if (rest.len == 0) return q.operators.tableRows(vm, table, first);
            // Further indices apply to each row: `t[0 1;`a`b]` is `((1;`x);(2;`y))`.
            const n = first.count();
            const results = try vm.gpa.alloc(*Value, n);
            defer vm.gpa.free(results);
            var done: usize = 0;
            defer for (results[0..done]) |r| r.deref(vm.gpa);
            for (0..n) |k| {
                const which = try q.operators.itemAt(vm, first, k);
                defer which.deref(vm.gpa);
                var one = [_]*Value{which};
                const row = try vm.indexTable(table, &one);
                defer row.deref(vm.gpa);
                results[done] = try vm.applyImpl(row, rest);
                done += 1;
            }
            return if (n == 0) vm.allocValue(.list, 0) else vm.enlist(results);
        },
        else => return error.type,
    }
}

/// Indexing a dictionary, as `d[k]` or `d k`: a key reads its value and a missing key the
/// null shaped like the values (`` (`a`b!1 2)`c `` is `0N`, `` (`a`b!(1 2;3))`c `` is
/// `` `long$() ``), a key of another type than a typed key list is a type error, a list of
/// keys reads each (a nested list item by item: `` (`a`b!1 2)(`a`b;`b) `` is `(1 2;2)`),
/// `::` or a hole keeps the whole dictionary, and further indices apply to what was read,
/// or to every value under `::` (`` (`a`b!(1 2;3 4))[;1] `` is `` `a`b!2 4 ``).
fn indexDict(vm: *Vm, dict_value: *Value, args: []*Value) RunError!*Value {
    const dict = dict_value.as.dict;
    const first = args[0];
    const rest = args[1..];
    if (first.isEmpty() or (first.as == .unary_primitive and first.as.unary_primitive == .identity)) {
        if (rest.len == 0) return dict_value.ref();
        const values = try vm.indexList(dict.values, args);
        errdefer values.deref(vm.gpa);
        return vm.createValue(.dict, .{ .keys = dict.keys.ref(), .values = values });
    }
    if (!first.isList()) return vm.lookupKey(dict_value, first, rest);
    // A keyed table takes a list as one key row (`kt[1 2]` against one key column is
    // `length`), not as keys to look up one by one.
    if (dict.keys.as == .table and first.as != .table) return vm.lookupKey(dict_value, first, rest);
    const n = first.count();
    const items = try vm.gpa.alloc(*Value, n);
    defer vm.gpa.free(items);
    var done: usize = 0;
    defer for (items[0..done]) |item| item.deref(vm.gpa);
    const each_args = try vm.gpa.alloc(*Value, args.len);
    defer vm.gpa.free(each_args);
    @memcpy(each_args[1..], rest);
    for (0..n) |i| {
        const key = try q.operators.itemAt(vm, first, i);
        defer key.deref(vm.gpa);
        each_args[0] = key;
        items[done] = try vm.indexDict(dict_value, each_args);
        done += 1;
    }
    return vm.enlist(items);
}

/// One key's value, the values' null when it is missing, indexed further by `rest`.
fn lookupKey(vm: *Vm, dict_value: *Value, key: *Value, rest: []*Value) RunError!*Value {
    const dict = dict_value.as.dict;
    // A keyed table looks a row up by its key: an atom against a one-column key table, a
    // dictionary row, or a table of rows giving a table.
    if (dict.keys.as == .table) {
        if (key.as == .table) {
            const n = key.count();
            const rows = try vm.gpa.alloc(*Value, n);
            defer vm.gpa.free(rows);
            var done: usize = 0;
            defer for (rows[0..done]) |r| r.deref(vm.gpa);
            for (0..n) |i| {
                const row = try q.operators.rowAt(vm, key, i);
                defer row.deref(vm.gpa);
                rows[done] = try vm.lookupKey(dict_value, row, rest);
                done += 1;
            }
            return if (n == 0) vm.allocValue(.list, 0) else vm.enlist(rows);
        }
        const at = try vm.keyedPosition(dict.keys, key);
        const value = if (at) |i| try q.operators.rowAt(vm, dict.values, i) else try q.operators.rowAt(vm, dict.values, std.math.maxInt(usize));
        if (rest.len == 0) return value;
        defer value.deref(vm.gpa);
        return vm.applyImpl(value, rest);
    }
    const value = if (try vm.keyPosition(dict.keys, key)) |i|
        try q.operators.itemAt(vm, dict.values, i)
    else
        try q.operators.nullLike(vm, dict.values);
    if (rest.len == 0) return value;
    defer value.deref(vm.gpa);
    return vm.applyImpl(value, rest);
}

/// The row of a key table matching `key`: a dictionary compares as a whole row, an atom
/// against a one-column key table finds itself in that column, and a list is `length`.
fn keyedPosition(vm: *Vm, keys: *Value, key: *Value) RunError!?usize {
    const t = keys.as.table;
    const columns = t.values.as.list;
    // A dictionary key is matched on the key columns alone, by name: `kt[`k`a!(2;4)]`
    // looks `k` up and ignores `a`, and a key column the dictionary lacks matches nothing.
    if (key.as == .dict) {
        const d = key.as.dict;
        rows: for (0..Value.rows(t)) |i| {
            for (t.keys.as.symbol_list, columns) |name, column| {
                const name_value = try vm.createValue(.symbol, name);
                defer name_value.deref(vm.gpa);
                const at = (try vm.keyPosition(d.keys, name_value)) orelse return null;
                const wanted = try q.operators.itemAt(vm, d.values, at);
                defer wanted.deref(vm.gpa);
                const item = try q.operators.itemAt(vm, column, i);
                defer item.deref(vm.gpa);
                if (!try q.operators.matches(vm, item, wanted)) continue :rows;
            }
            return i;
        }
        return null;
    }
    if (key.isList()) return error.length;
    if (columns.len != 1) return error.type;
    return vm.keyPosition(columns[0], key);
}

/// Where `key` sits in a dictionary's keys, if at all. Typed keys only take an atom of
/// their own type (`(1 2!3 4) 2h` is a type error), and nulls find themselves; general
/// keys take anything that matches.
pub fn keyPosition(vm: *Vm, keys: *Value, key: *Value) RunError!?usize {
    switch (keys.as) {
        .list => |items| {
            for (items, 0..) |item, i| if (try q.operators.matches(vm, item, key)) return i;
            return null;
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
            const atom_tag = comptime q.operators.counterpart(tag);
            if (key.as != atom_tag) return error.type;
            const needle = @field(key.as, @tagName(atom_tag));
            const Item = @TypeOf(needle);
            for (items, 0..) |item, i| {
                const same = if (Item == f32 or Item == f64) item == needle or (std.math.isNan(item) and std.math.isNan(needle)) else item == needle;
                if (same) return i;
            }
            return null;
        },
        else => return error.type,
    }
}

/// Indexing a list, as `x[i]` or `x i`: an integer picks an item, with a null shaped like
/// the first item when it is out of range (`1 2 3[-1]` is `0N`, `"abc" 5` is `" "`), a list
/// of indices picks each, `::` or a hole keeps everything, and further indices apply to what
/// was picked, item by item after a list or a hole (`(1 2;3 4)[;0]` is `1 3`).
pub fn indexList(vm: *Vm, list: *Value, args: []*Value) RunError!*Value {
    const first = args[0];
    const rest = args[1..];
    const all = first.isEmpty() or (first.as == .unary_primitive and first.as.unary_primitive == .identity);
    if (!all and !first.isList()) {
        // Chars and bytes index by their codes, as `"abc" "a"` and `x["a"]` do in q.
        const index: ?i64 = switch (first.as) {
            .boolean => |b| @intFromBool(b),
            .byte => |b| b,
            .char => |c| c,
            .short => |v| if (v == @backingInt(Value.Short.null)) null else v,
            .int => |v| if (v == @backingInt(Value.Int.null)) null else v,
            .long => |v| if (v == @backingInt(Value.Long.null)) null else v,
            else => return error.type,
        };
        const picked = if (index != null and index.? >= 0 and index.? < list.count())
            try q.operators.itemAt(vm, list, @intCast(index.?))
        else
            try q.operators.nullLike(vm, list);
        if (rest.len == 0) return picked;
        defer picked.deref(vm.gpa);
        return vm.applyImpl(picked, rest);
    }

    // Everything, or each of a list of indices, then the remaining indices item by item.
    const selected = if (all) list.ref() else selected: {
        const len = first.count();
        // A typed empty index selects the typed empty of the list (`1 2 3[0#0]` is
        // `` `long$() ``) while `()` selects `()`.
        if (len == 0) {
            if (first.as == .list) break :selected try vm.allocValue(.list, 0);
            const zero = vm.getConstant(.zero);
            defer zero.deref(vm.gpa);
            break :selected try q.operators.take(vm, zero, list);
        }
        const items = try vm.gpa.alloc(*Value, len);
        defer vm.gpa.free(items);
        var done: usize = 0;
        defer for (items[0..done]) |v| v.deref(vm.gpa);
        for (0..len) |i| {
            const index = try q.operators.itemAt(vm, first, i);
            defer index.deref(vm.gpa);
            var one = [_]*Value{index};
            items[done] = try vm.indexList(list, &one);
            done += 1;
        }
        break :selected try vm.enlist(items);
    };
    if (rest.len == 0) return selected;
    defer selected.deref(vm.gpa);

    const len = selected.count();
    if (len == 0) return selected.ref();
    const items = try vm.gpa.alloc(*Value, len);
    defer vm.gpa.free(items);
    var done: usize = 0;
    defer for (items[0..done]) |v| v.deref(vm.gpa);
    for (0..len) |i| {
        const item = try q.operators.itemAt(vm, selected, i);
        defer item.deref(vm.gpa);
        items[done] = try vm.applyImpl(item, rest);
        done += 1;
    }
    return vm.enlist(items);
}

/// A projection of `func` on `args`, which may hold `.empty` holes.
pub fn project(vm: *Vm, func: *Value, args: []*Value) RunError!*Value {
    const copies = try vm.gpa.alloc(*Value, args.len);
    errdefer vm.gpa.free(copies);
    for (copies, args) |*copy, a| copy.* = a.ref();
    const callee = func.ref();
    errdefer callee.deref(vm.gpa);
    return vm.createValue(.projection, .{ .callee = callee, .args = copies });
}

/// `.z.P` and the other clock variables, which q reads from the clock at every reference
/// rather than storing: `D` date, `P` timestamp, `T` time, `N` timespan since midnight and
/// `Z` datetime, in local time for the capital letter and UTC for the lowercase one. Null
/// for any other identifier.
pub fn clockVariable(vm: *Vm, identifier: Symbol) !?*Value {
    const string = vm.internedString(identifier);
    if (!std.mem.startsWith(u8, string, ".z.")) return null;
    if (string.len != 4) return vm.systemVariable(string[3..]);
    const letter = string[3];
    if (std.mem.findScalar(u8, "DdPpTtNnZz", letter) == null) return vm.systemVariable(string[3..]);

    const utc = q.clock.now(vm.io);
    const nanos = if (std.ascii.isUpper(letter)) local: {
        const unix_seconds = @divFloor(utc, q.literal.ns_per_second) + q.literal.epoch_days * 86_400;
        break :local utc + vm.local_zone.offset(unix_seconds) * q.literal.ns_per_second;
    } else utc;
    const day = @divFloor(nanos, q.literal.ns_per_day);
    const since_midnight = @mod(nanos, q.literal.ns_per_day);

    return switch (std.ascii.toLower(letter)) {
        'd' => try vm.createValue(.date, @intCast(day)),
        'p' => try vm.createValue(.timestamp, nanos),
        't' => try vm.createValue(.time, @intCast(@divFloor(since_midnight, 1_000_000))),
        'n' => try vm.createValue(.timespan, since_midnight),
        'z' => try vm.createValue(.datetime, @as(f64, @floatFromInt(nanos)) / @as(f64, @floatFromInt(q.literal.ns_per_day))),
        else => unreachable,
    };
}

/// The `.z` variables besides the clock: `.z.q` quiet, `.z.f` script, `.z.x` arguments,
/// `.z.X` command line, `.z.e` and `.z.b` empty dictionaries, `.z.o` platform, `.z.K`
/// and `.z.k` the q.k version and date, `.z.i` pid, `.z.h` host, `.z.u` user, `.z.c`
/// cores, `.z.a` address, `.z.w` handle. `.z.s` outside a lambda is `nyi`; the handlers
/// (`.z.pi`, `.z.ex`...) are ordinary globals, undefined until assigned.
fn systemVariable(vm: *Vm, name: []const u8) !?*Value {
    if (name.len != 1) return null;
    switch (name[0]) {
        'q' => return try vm.createValue(.boolean, vm.quiet),
        'f' => return try vm.createValue(.symbol, vm.script),
        'x' => return if (vm.arguments) |a| a.ref() else try vm.allocValue(.list, 0),
        'X' => return if (vm.arguments) |a| a.ref() else try vm.allocValue(.list, 0),
        'e', 'b' => {
            const keys = try vm.allocValue(.symbol_list, 0);
            errdefer keys.deref(vm.gpa);
            const values = try vm.allocValue(.list, 0);
            errdefer values.deref(vm.gpa);
            return try vm.createValue(.dict, .{ .keys = keys, .values = values });
        },
        'o' => return try vm.createValue(.symbol, try vm.intern(if (@import("builtin").os.tag == .macos) "m64" else "l64")),
        'K' => return try vm.createValue(.float, 4.0),
        'k' => return try vm.createValue(.date, @intCast(q.literal.daysFromCivil(2023, 4, 17) - q.literal.epoch_days)),
        'w' => return try vm.createValue(.int, 0),
        'a' => return try vm.createValue(.int, 2130706433),
        'c' => return try vm.createValue(.int, @intCast(std.Thread.getCpuCount() catch 1)),
        'i' => return try vm.createValue(.int, @intCast(std.posix.system.getpid())),
        'h' => {
            var buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
            const host = std.posix.gethostname(&buffer) catch "";
            return try vm.createValue(.symbol, try vm.intern(host));
        },
        'u' => return try vm.createValue(.symbol, try vm.intern(vm.environ.get("USER") orelse "")),
        's' => return error.nyi,
        else => return null,
    }
}

/// The namespace dictionary at a dotted path, or null when it does not exist. `.` is the
/// root namespace of bare globals; `.Q` and `.a.b` are looked up from the root directory
/// `` ` ``, which holds the namespaces. With `create` set, missing levels are added the way
/// an assignment would. The returned value is borrowed, not referenced.
pub fn namespaceAt(vm: *Vm, path: []const u8, create: bool) !?*Value {
    assert(path.len > 0 and path[0] == '.');
    if (path.len == 1) return vm.state.as.dict.values.as.list[0];

    const owned = try vm.gpa.dupe(u8, path);
    defer vm.gpa.free(owned);

    var namespace = vm.state;
    var it = std.mem.splitScalar(u8, owned[1..], '.');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        const symbol = try vm.intern(part);
        const dict = namespace.as.dict;
        if (std.mem.findScalar(Symbol, dict.keys.as.symbol_list, symbol)) |index| {
            namespace = dict.values.as.list[index];
            if (namespace.as != .dict) return error.type;
        } else {
            if (!create) return null;
            const child = try vm.createNamespace();
            defer child.deref(vm.gpa);
            try vm.namespaceSet(namespace, symbol, child);
            namespace = child;
        }
    }
    return namespace;
}

/// An empty namespace: a dictionary whose only entry maps the empty symbol to `::`.
fn createNamespace(vm: *Vm) !*Value {
    const keys = try vm.allocValue(.symbol_list, 1);
    errdefer keys.deref(vm.gpa);
    keys.as.symbol_list[0] = .empty;

    const values = try vm.allocValue(.list, 1);
    errdefer values.deref(vm.gpa);
    values.as.list[0] = vm.getUnaryPrimitive(.identity);

    return vm.createValue(.dict, .{ .keys = keys, .values = values });
}

/// Sets `name` to `value` in the namespace dictionary, replacing any existing entry.
pub fn namespaceSet(vm: *Vm, namespace: *Value, name: Symbol, value: *Value) !void {
    const dict = &namespace.as.dict;
    const keys = dict.keys.as.symbol_list;
    const values = dict.values.as.list;

    if (std.mem.findScalar(Symbol, keys, name)) |index| {
        if (dict.values.ref_count == 0) {
            const old = values[index];
            values[index] = value.ref();
            old.deref(vm.gpa);
        } else {
            // The value list is shared, so replace it rather than mutate it.
            const new_values = try vm.allocValue(.list, values.len);
            errdefer comptime unreachable;
            for (new_values.as.list, values, 0..) |*new_v, old_v, i| {
                new_v.* = if (i == index) value.ref() else old_v.ref();
            }
            dict.values.deref(vm.gpa);
            dict.values = new_values;
        }
        return;
    }

    const new_keys = try vm.allocValue(.symbol_list, keys.len + 1);
    errdefer new_keys.deref(vm.gpa);
    @memcpy(new_keys.as.symbol_list[0..keys.len], keys);
    new_keys.as.symbol_list[keys.len] = name;

    const new_values = try vm.allocValue(.list, values.len + 1);
    errdefer comptime unreachable;
    for (new_values.as.list[0..values.len], values) |*new_v, old_v| new_v.* = old_v.ref();
    new_values.as.list[values.len] = value.ref();

    dict.keys.deref(vm.gpa);
    dict.keys = new_keys;
    dict.values.deref(vm.gpa);
    dict.values = new_values;
}

pub fn createValue(vm: *Vm, comptime tag: Value.Type, value: @FieldType(Value.Union, @tagName(tag))) !*Value {
    const self = try vm.gpa.create(Value);
    errdefer comptime unreachable;
    self.* = .{ .as = @unionInit(Value.Union, @tagName(tag), value) };
    return self;
}

pub fn allocValue(vm: *Vm, comptime tag: Value.Type, len: usize) !*Value {
    const T = @typeInfo(@FieldType(Value.Union, @tagName(tag))).pointer.child;
    const value = try vm.gpa.alloc(T, len);
    errdefer vm.gpa.free(value);
    return vm.createValue(tag, value);
}

pub fn intern(vm: *Vm, bytes: []const u8) !Symbol {
    const str_index: u32 = @intCast(vm.string_bytes.items.len);
    try vm.string_bytes.appendSlice(vm.gpa, bytes);
    const gop = try vm.string_table.getOrPutContextAdapted(
        vm.gpa,
        vm.string_bytes.items[str_index..],
        std.hash_map.StringIndexAdapter{ .bytes = &vm.string_bytes },
        std.hash_map.StringIndexContext{ .bytes = &vm.string_bytes },
    );
    if (gop.found_existing) {
        vm.string_bytes.shrinkRetainingCapacity(str_index);
        return @fromBackingInt(@intCast(gop.key_ptr.*));
    } else {
        gop.key_ptr.* = str_index;
        try vm.string_bytes.append(vm.gpa, 0);
        return @fromBackingInt(@intCast(str_index));
    }
}

/// The symbol for `bytes` if it has been interned, without interning it.
pub fn lookupSymbol(vm: *Vm, bytes: []const u8) ?Symbol {
    const index = vm.string_table.getKeyAdapted(
        bytes,
        std.hash_map.StringIndexAdapter{ .bytes = &vm.string_bytes },
    ) orelse return null;
    return @fromBackingInt(@intCast(index));
}

pub fn internedString(vm: *Vm, index: Symbol) [:0]const u8 {
    const slice = vm.string_bytes.items[@backingInt(index)..];
    return slice[0..std.mem.findScalar(u8, slice, 0).? :0];
}

pub fn createNumberLiteral(vm: *Vm, tree: *const Ast, node: Node.Index) !*Value {
    assert(tree.nodeTag(node) == .number_literal);
    const main_token = tree.nodeMainToken(node);
    const slice = tree.tokenSlice(main_token);
    return vm.createNumberLiteralSlice(slice);
}

pub fn createNumberLiteralSlice(vm: *Vm, slice: []const u8) !*Value {
    if (slice.len >= 2 and slice[0] == '0' and slice[1] == 'x') return vm.createByteLiteral(slice[2..]);
    // `101b` is a boolean list in one token; every other literal is an atom.
    if (slice[slice.len - 1] == 'b' and slice.len > 2) {
        const boolean_list = try vm.allocValue(.boolean_list, slice.len - 1);
        errdefer comptime unreachable;
        for (boolean_list.as.boolean_list, slice[0 .. slice.len - 1]) |*b, c| b.* = c == '1';
        return boolean_list;
    }
    switch (try q.literal.parse(slice)) {
        inline else => |value, kind| return vm.createValue(comptime kind.atomType(), value),
    }
}

/// `0x0102` is a byte list, `0x01` a byte atom and `0x` the empty byte list.
/// An odd number of digits is padded with a leading zero, so `0x1` is `0x01` and `0x123` is
/// `0x0123`.
fn createByteLiteral(vm: *Vm, hex: []const u8) !*Value {
    const len = (hex.len + 1) / 2;
    if (len == 1) return vm.createValue(.byte, try std.fmt.parseInt(u8, hex, 16));
    const list = try vm.allocValue(.byte_list, len);
    errdefer list.deref(vm.gpa);
    // With an odd count the first byte has a single digit; every later one has two.
    const lead = hex.len % 2;
    for (list.as.byte_list, 0..) |*b, i| {
        const digits = if (i == 0) hex[0 .. 2 - lead] else hex[2 * i - lead ..][0..2];
        b.* = try std.fmt.parseInt(u8, digits, 16);
    }
    return list;
}

/// A list literal takes its type from its last item, as `1 0Nh` or `2023.04.17 0Nd`; a list
/// of untyped numbers is long unless one of them needs to be a float.
pub fn createNumberListLiteral(vm: *Vm, tree: *const Ast, node: Node.Index) !*Value {
    assert(tree.nodeTag(node) == .number_list_literal);
    const first_token = tree.nodeMainToken(node);
    const last_token = tree.nodeData(node).token;

    // Only the last token may carry a type letter (`1 2 3h`, not `1h 2h`).
    for (first_token..last_token) |tok| {
        if (q.literal.hasSuffix(tree.tokenSlice(@intCast(tok)))) return error.parse;
    }
    switch (try q.literal.kindOf(tree.tokenSlice(last_token))) {
        // The parser keeps boolean and byte literals out of number lists.
        .boolean, .byte => unreachable,
        .long => {
            // Any float-shaped item, including a lowercase `0n`, makes the whole list float.
            for (first_token..last_token) |tok| {
                if (try q.literal.kindOf(tree.tokenSlice(@intCast(tok))) == .float) {
                    return vm.createTypedList(tree, .float, first_token, last_token);
                }
            }
            return vm.createTypedList(tree, .long, first_token, last_token);
        },
        inline else => |kind| return vm.createTypedList(tree, kind, first_token, last_token),
    }
}

fn createTypedList(vm: *Vm, tree: *const Ast, comptime kind: q.literal.Kind, first_token: Ast.TokenIndex, last_token: Ast.TokenIndex) !*Value {
    const list = try vm.allocValue(comptime kind.listType(), last_token - first_token + 1);
    errdefer list.deref(vm.gpa);
    const items = @field(list.as, @tagName(kind.listType()));
    for (items, first_token..) |*item, tok| {
        item.* = @field(try q.literal.parseAs(kind, tree.tokenSlice(@intCast(tok))), @tagName(kind));
    }
    return list;
}

const testing = std.testing;

fn expectEval(vm: *Vm, source: [:0]const u8, expected: []const u8) !void {
    const value = try vm.evalSource(source, .q, "<test>");
    defer value.deref(vm.gpa);

    var buffer: Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    try buffer.writer.print("{f}", .{value.fmt(vm)});
    try testing.expectEqualStrings(expected, buffer.written());
}

test "\\d sets the namespace for bare names" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "\\d", "`.");
    try expectEval(vm, "\\d .Q", "::");
    try expectEval(vm, "\\d", "`.Q");
    try expectEval(vm, "qt:1", "::");
    try expectEval(vm, "qt", "1");
    try expectEval(vm, ".Q.qt", "1");
    try expectEval(vm, "\\d .", "::");
    try expectEval(vm, "\\d", "`.");
    try expectEval(vm, ".Q.qt", "1");
    try testing.expectError(error.identifier, vm.evalSource("qt", .q, "<test>"));

    // Root names are not visible from inside a namespace.
    try expectEval(vm, "x:2", "::");
    try expectEval(vm, "\\d .Q", "::");
    try testing.expectError(error.identifier, vm.evalSource("x", .q, "<test>"));
    try expectEval(vm, "\\d .", "::");
    try expectEval(vm, "x", "2");

    // Several statements in one source, as in a script.
    try expectEval(vm, "\\d .Q\nw:7\n\\d .\n.Q.w", "7");
    try expectEval(vm, "\\d", "`.");
}

test "\\d creates a namespace only on assignment" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "\\d .bar", "::");
    try expectEval(vm, "\\d", "`.bar");
    try expectEval(vm, "\\d .", "::");
    try testing.expectError(error.identifier, vm.evalSource(".bar", .q, "<test>"));

    try expectEval(vm, "\\d .bar", "::");
    try expectEval(vm, "y:3", "::");
    try expectEval(vm, "\\d .", "::");
    try expectEval(vm, ".bar.y", "3");
    try expectEval(vm, ".bar", "``y!(::;3)");
    try expectEval(vm, ".a.b.c:4", "::");
    try expectEval(vm, ".a.b", "``c!(::;4)");
}

test ".x is a root directory entry, not the global x" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, ".x:1", "::");
    try testing.expectError(error.identifier, vm.evalSource("x", .q, "<test>"));
    try expectEval(vm, "x:2", "::");
    try expectEval(vm, ".x", "1");
    try expectEval(vm, "x", "2");
    try expectEval(vm, ".x~x", "0b");

    // The root directory is reached the same way from inside a namespace.
    try expectEval(vm, "\\d .foo", "::");
    try testing.expectError(error.identifier, vm.evalSource("x", .q, "<test>"));
    try expectEval(vm, ".x", "1");
    try expectEval(vm, "x:3", "::");
    try expectEval(vm, ".x", "1");
    try expectEval(vm, ".foo.x", "3");
    try expectEval(vm, ".z:5", "::");
    try expectEval(vm, "\\d .", "::");
    try expectEval(vm, "x", "2");
    try expectEval(vm, ".z", "5");
    try expectEval(vm, ".foo.x", "3");
    try expectEval(vm, ".foo", "``x!(::;3)");

    // Namespaces are not visible as bare globals of the root namespace.
    try testing.expectError(error.identifier, vm.evalSource("foo", .q, "<test>"));
}

fn expectEvalMode(vm: *Vm, mode: Ast.Mode, source: [:0]const u8, expected: []const u8) !void {
    const value = try vm.evalSource(source, mode, "<test>");
    defer value.deref(vm.gpa);

    var buffer: Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    try buffer.writer.print("{f}", .{value.fmt(vm)});
    try testing.expectEqualStrings(expected, buffer.written());
}

test "keywords are .q entries resolved while parsing q" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    // The seeded aliases behave as q.k defines them, and only in q mode, as in kdb+.
    try expectEval(vm, "neg 1", "-1");
    try expectEval(vm, "neg", "-:");
    try expectEval(vm, ".q.neg", "-:");
    try expectEval(vm, "parse \"neg 1\"", "(-:;1)");
    try expectEval(vm, "-5!\"neg 1\"", "(-:;1)");
    try expectEval(vm, "first 1 2", "1");
    try expectEval(vm, "1+", "+[1]");
    try expectEval(vm, "til 3", "0 1 2");
    try expectEval(vm, "1 and", "&[1]");
    try testing.expectError(error.identifier, vm.evalSource("neg 1", .k, "<test>"));
    try expectEvalMode(vm, .k, "-:1", "-1");

    // A valence-2 function placed in .q is infix from the next statement on, not in the same one.
    try expectEval(vm, ".q.p:+", "::");
    try expectEval(vm, "1 p 2", "3");
    try expectEval(vm, "1 p", "+[1]");
    try expectEval(vm, "p", "+");
    try expectEval(vm, "parse \"1 p 2\"", "(+;1;2)");
    try testing.expectError(error.identifier, vm.evalSource("1 p 2", .k, "<test>"));
    try testing.expectError(error.identifier, vm.evalSource(".q.p2:+;1 p2 2", .q, "<test>"));

    // Entries of other valence are inlined as nouns.
    try expectEval(vm, ".q.v:5", "::");
    try expectEval(vm, "v", "5");
    try expectEval(vm, "v+1", "6");

    // Keyword names cannot be assigned bare, in any namespace; k mode still can, as q.k does.
    try testing.expectError(error.assign, vm.evalSource("neg:1", .q, "<test>"));
    try expectEval(vm, "\\d .foo", "::");
    try testing.expectError(error.assign, vm.evalSource("p:1", .q, "<test>"));
    try expectEval(vm, "\\d .", "::");
    try expectEvalMode(vm, .k, "\\d .q", "::");
    try expectEvalMode(vm, .k, "neg:-:", "::");
    try expectEvalMode(vm, .k, "\\d .", "::");
    try expectEval(vm, "neg 1", "-1");
}

test "natives from .Q.res work in both modes" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "enlist 1", ",1");
    try expectEvalMode(vm, .k, "enlist 1", ",1");
    try expectEval(vm, "enlist", "enlist");
    try expectEvalMode(vm, .k, ",:", ",:");
    try expectEval(vm, "abs", "abs");
    try expectEval(vm, "abs[-1]", "1");
    try expectEvalMode(vm, .k, "abs[-1]", "1");
    try testing.expectError(error.identifier, vm.evalSource("count[1 2]", .k, "<test>"));

    try expectEval(vm, "in", "in");
    try expectEval(vm, "1 in", "in[1]");
    try expectEvalMode(vm, .k, "1 in", "in[1]");
    try expectEval(vm, "2 xexp", "xexp[2]");
    try expectEval(vm, "(1 in;2 bin)", "(in[1];bin[2])");
    try expectEval(vm, "1 in 1 2", "1b");
    try expectEvalMode(vm, .k, "(*1 2)in 1 4", "1b");
    try expectEvalMode(vm, .k, "(n:1 2)bin 2", "1");
}

test "system commands through value" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "value \"\\\\d\"", "`.");
    try expectEval(vm, "value \"\\\\d .Q\"", "::");
    try expectEval(vm, "value \"\\\\d\"", "`.Q");
    try expectEval(vm, "value \"1+2\"", "3");
    try expectEval(vm, "value \"\"", "::");
    try testing.expectError(error.domain, vm.evalSource("\\d Q", .q, "<test>"));
}

test "unknown system commands run in the shell" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "\\echo hi", ",\"hi\"");
    try expectEval(vm, "\\printf 'a\\nb\\n'", "(,\"a\";,\"b\")");
    try expectEval(vm, "\\printf 'a\\nb'", "(,\"a\";,\"b\")");
    try expectEval(vm, "\\true", "()");
    try expectEval(vm, "value \"\\\\echo hi\"", ",\"hi\"");
    try expectEval(vm, "type value \"\\\\echo hi\"", "0h");

    // As in q, the command runs as `sh -c "<command> >file"`: the capture binds to the last
    // simple command and wins over its own stdout redirection, and stderr is not captured.
    try expectEval(vm, "\\echo err >/dev/null", ",\"err\"");
    try expectEval(vm, "\\echo err 1>&2", ",\"err\"");
    try expectEval(vm, "\\echo A >/dev/null; echo D", ",,\"D\"");
    try expectEval(vm, "\\printf x >/dev/null; printf y", ",,\"y\"");
    try expectEval(vm, "\\(echo err 1>&2) 2>/dev/null", "()");

    // Only the exact name `d` is the namespace command.
    try expectEval(vm, "\\d .Q", "::");
    try expectEval(vm, "\\d", "`.Q");
    try expectEval(vm, "type value \"\\\\du -hs .\"", "0h");
    try testing.expectError(error.os, vm.evalSource("\\dx 2>/dev/null", .q, "<test>"));
    try testing.expectError(error.os, vm.evalSource("\\false", .q, "<test>"));
    try testing.expectError(error.os, vm.evalSource("\\nonexistent_cmd_xyz 2>/dev/null", .q, "<test>"));
}

test "assignment replaces an existing global" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "z:1", "::");
    try expectEval(vm, "z:5", "::");
    try expectEval(vm, "z", "5");
    try expectEval(vm, "\\d .Q", "::");
    try expectEval(vm, "z:`a", "::");
    try expectEval(vm, "z:`b", "::");
    try expectEval(vm, ".Q.z", "`b");
}

test "short, int, real and byte literals display as in q" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "1h", "1h");
    try expectEval(vm, "-1h", "-1h");
    try expectEval(vm, "0Nh", "0Nh");
    try expectEval(vm, "0Wh", "0Wh");
    try expectEval(vm, "-0Wh", "-0Wh");
    try expectEval(vm, "32767h", "0Wh");
    try expectEval(vm, "1 2h", "1 2h");
    try expectEval(vm, "1 0Nh", "1 0Nh");
    try expectEval(vm, "0N 1h", "0N 1h");
    try expectEval(vm, "0W -0W 1h", "0W -0W 1h");
    try expectEval(vm, "enlist 1h", ",1h");

    try expectEval(vm, "1i", "1i");
    try expectEval(vm, "0Ni", "0Ni");
    try expectEval(vm, "0Wi", "0Wi");
    try expectEval(vm, "-0Wi", "-0Wi");
    try expectEval(vm, "1 2i", "1 2i");
    try expectEval(vm, "0N 1i", "0N 1i");
    try expectEval(vm, "enlist 1i", ",1i");

    try expectEval(vm, "1e", "1e");
    try expectEval(vm, "1.5e", "1.5e");
    try expectEval(vm, "0.1e", "0.1e");
    try expectEval(vm, "0Ne", "0Ne");
    try expectEval(vm, "0We", "0we");
    try expectEval(vm, "-0We", "-0we");
    try expectEval(vm, "1 2e", "1 2e");
    try expectEval(vm, "1 2.5e", "1 2.5e");
    try expectEval(vm, "1.5 2e", "1.5 2e");
    try expectEval(vm, "1 0Ne", "1 0Ne");
    try expectEval(vm, "0.1 0.2e", "0.1 0.2e");
    try expectEval(vm, "100000e", "100000e");
    try expectEval(vm, "1000000e", "1000000e");
    try expectEval(vm, "enlist 1e", ",1e");

    try expectEval(vm, "0x01", "0x01");
    try expectEval(vm, "0x00", "0x00");
    try expectEval(vm, "0xff", "0xff");
    try expectEval(vm, "0x0102", "0x0102");
    try expectEval(vm, "0x1", "0x01");
    try expectEval(vm, "0x0", "0x00");
    try expectEval(vm, "0x123", "0x0123");
    try expectEval(vm, "0x01234", "0x001234");
    try expectEval(vm, "count 0x01234", "3");
    try expectEval(vm, "type 0x1", "-4h");
    try expectEval(vm, "type 0x123", "4h");
    try expectEval(vm, "0xfF", "0xff");
    try testing.expectError(error.InvalidCharacter, vm.evalSource("0xg", .q, "<test>"));
    try expectEval(vm, "enlist 0x01", ",0x01");
    try expectEval(vm, "0x", "`byte$()");
    try expectEval(vm, "enlist 0x", ",`byte$()");

    try expectEval(vm, "-3!(1h;2i;3e;0x04)", "\"(1h;2i;3e;0x04)\"");
}

test "type returns a short" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "type 1b", "-1h");
    try expectEval(vm, "type 101b", "1h");
    try expectEval(vm, "type 0x01", "-4h");
    try expectEval(vm, "type 0x0102", "4h");
    try expectEval(vm, "type 1h", "-5h");
    try expectEval(vm, "type 1 2h", "5h");
    try expectEval(vm, "type 1i", "-6h");
    try expectEval(vm, "type 0N", "-7h");
    try expectEval(vm, "type 1e", "-8h");
    try expectEval(vm, "type 1.5", "-9h");
    try expectEval(vm, "type \"a\"", "-10h");
    try expectEval(vm, "type `a", "-11h");
    try expectEval(vm, "type ()", "0h");
    try expectEval(vm, "type `a`b!1 2", "99h");
    try expectEval(vm, "type type 1", "-5h");
}

test "atom arithmetic promotes as q does" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "1+2", "3");
    try expectEval(vm, "1+0.5", "1.5");
    try expectEval(vm, "1.5+1", "2.5");
    try expectEval(vm, "2*1.5", "3f");

    // Booleans, bytes and shorts compute as ints; wider operands win.
    try expectEval(vm, "1h+1h", "2i");
    try expectEval(vm, "1h-2h", "-1i");
    try expectEval(vm, "1h*2h", "2i");
    try expectEval(vm, "1b+1b", "2i");
    try expectEval(vm, "1b+1h", "2i");
    try expectEval(vm, "1b*2h", "2i");
    try expectEval(vm, "0x01+0x01", "2i");
    try expectEval(vm, "0x02*3h", "6i");
    try expectEval(vm, "1i+1h", "2i");
    try expectEval(vm, "2h*3i", "6i");
    try expectEval(vm, "1h+1", "2");
    try expectEval(vm, "1i+1", "2");
    try expectEval(vm, "2h*3", "6");
    try expectEval(vm, "2h-3", "-1");
    try expectEval(vm, "0x01+1", "2");
    try expectEval(vm, "2e*3", "6e");
    try expectEval(vm, "2e*3f", "6f");
    try expectEval(vm, "1h+1f", "2f");

    // Nulls propagate into the result kind; infinities are ordinary values that wrap.
    try expectEval(vm, "0Nh+1h", "0Ni");
    try expectEval(vm, "0Nh*2", "0N");
    try expectEval(vm, "0Ni+1", "0N");
    try expectEval(vm, "0Wh+1h", "32768i");
    try expectEval(vm, "32767h+1h", "32768i");
    try expectEval(vm, "0Wi+1i", "0Ni");

    // Division is always float.
    try expectEval(vm, "1h%2h", "0.5");
    try expectEval(vm, "1%2", "0.5");
    try expectEval(vm, "1e%2e", "0.5");
    try expectEval(vm, "1i%2", "0.5");
    try expectEval(vm, "2i%4i", "0.5");
    try expectEval(vm, "2%0", "0w");
    try expectEval(vm, "-2%0", "-0w");
    try expectEval(vm, "0%0", "0n");
    try expectEval(vm, "1h%0", "0w");

    try testing.expectError(error.type, vm.evalSource("`a+1", .q, "<test>"));
    try expectEval(vm, "1 2+3", "4 5");
}

test "neg, first, enlist and match on the numeric types" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "neg 1h", "-1h");
    try expectEval(vm, "neg 0Nh", "0Nh");
    try expectEval(vm, "neg 1e", "-1e");
    try expectEval(vm, "neg 0x01", "-1i");
    try expectEval(vm, "neg 1b", "-1i");
    try expectEval(vm, "neg 1 2h", "-1 -2h");
    try expectEval(vm, "neg 1 2e", "-1 -2e");
    try expectEval(vm, "neg 0N 1i", "0N -1i");
    try expectEval(vm, "neg 0x0102", "-1 -2i");
    try expectEval(vm, "neg 101b", "-1 0 -1i");

    try expectEval(vm, "first 1 2h", "1h");
    try expectEval(vm, "first 1 2e", "1e");
    try expectEval(vm, "first 0x0102", "0x01");
    try expectEval(vm, "first 101b", "1b");

    try expectEval(vm, "(1h;2h)", "1 2h");
    try expectEval(vm, "(1e;2e)", "1 2e");
    try expectEval(vm, "(0x01;0x02)", "0x0102");
    try expectEval(vm, "(1h;2i)", "(1h;2i)");
    try expectEval(vm, "(1e;2f)", "(1e;2f)");
    try expectEval(vm, "(1b;1h)", "(1b;1h)");
    try expectEval(vm, "(0x01;1h)", "(0x01;1h)");

    try expectEval(vm, "1h~1h", "1b");
    try expectEval(vm, "1h~1", "0b");
    try expectEval(vm, "1 2h!3 4", "1 2h!3 4");
}

test "temporal literals display as in q" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "2023.04.17", "2023.04.17");
    try expectEval(vm, "2000.01.01", "2000.01.01");
    try expectEval(vm, "1999.12.31", "1999.12.31");
    try expectEval(vm, "2023.04.17d", "2023.04.17");
    try expectEval(vm, "0Nd", "0Nd");
    try expectEval(vm, "0Wd", "0Wd");
    try expectEval(vm, "-0Wd", "-0Wd");
    try expectEval(vm, "2023.04.17 2023.04.18", "2023.04.17 2023.04.18");
    try expectEval(vm, "2023.04.17 0Nd", "2023.04.17 0N");
    try expectEval(vm, "enlist 2023.04.17", ",2023.04.17");

    try expectEval(vm, "2023.04m", "2023.04m");
    try expectEval(vm, "2000.01m", "2000.01m");
    try expectEval(vm, "0Nm", "0Nm");
    try expectEval(vm, "0Wm", "0Wm");
    try expectEval(vm, "2023.04 2023.05m", "2023.04 2023.05m");

    try expectEval(vm, "2023.04.17D12:34:56.123456789", "2023.04.17D12:34:56.123456789");
    try expectEval(vm, "2023.04.17D12:34:56", "2023.04.17D12:34:56.000000000");
    try expectEval(vm, "2023.04.17D12:34", "2023.04.17D12:34:00.000000000");
    try expectEval(vm, "2023.04.17D", "2023.04.17D00:00:00.000000000");
    try expectEval(vm, "2023.04.17D12:34:56p", "2023.04.17D12:34:56.000000000");
    try expectEval(vm, "0Np", "0Np");
    try expectEval(vm, "0Wp", "0Wp");
    try expectEval(vm, "-0Wp", "-0Wp");
    try expectEval(vm, "2023.04.17D12:34:56.123456789 0Np", "2023.04.17D12:34:56.123456789 0N");

    try expectEval(vm, "2023.04.17T12:34:56.123", "2023.04.17T12:34:56.123");
    try expectEval(vm, "2023.04.17T12:34:56", "2023.04.17T12:34:56.000");
    try expectEval(vm, "0Nz", "0Nz");
    try expectEval(vm, "0Wz", "0wz");
    try expectEval(vm, "-0Wz", "-0wz");
    try expectEval(vm, "2023.04.17T12:34:56.123 0Nz", "2023.04.17T12:34:56.123 0N");

    try expectEval(vm, "0D12:34:56.123456789", "0D12:34:56.123456789");
    try expectEval(vm, "1D12:34:56", "1D12:34:56.000000000");
    try expectEval(vm, "0D00:00:01", "0D00:00:01.000000000");
    try expectEval(vm, "0D00:00", "0D00:00:00.000000000");
    try expectEval(vm, "100D00:00:00", "100D00:00:00.000000000");
    try expectEval(vm, "12:34:56.123456789n", "0D12:34:56.123456789");
    try expectEval(vm, "0Nn", "0Nn");
    try expectEval(vm, "0Wn", "0Wn");
    try expectEval(vm, "-0Wn", "-0Wn");
    try expectEval(vm, "0D12:34:56.123456789 0Nn", "0D12:34:56.123456789 0N");

    try expectEval(vm, "12:34", "12:34");
    try expectEval(vm, "12:34u", "12:34");
    try expectEval(vm, "25:00", "25:00");
    try expectEval(vm, "0Nu", "0Nu");
    try expectEval(vm, "0Wu", "0Wu");
    try expectEval(vm, "-0Wu", "-0Wu");
    try expectEval(vm, "12:34 12:35", "12:34 12:35");
    try expectEval(vm, "12:34 0Nu", "12:34 0N");

    try expectEval(vm, "12:34:56", "12:34:56");
    try expectEval(vm, "12:34:56v", "12:34:56");
    try expectEval(vm, "0Nv", "0Nv");
    try expectEval(vm, "0Wv", "0Wv");
    try expectEval(vm, "12:34:56 0Nv", "12:34:56 0N");

    try expectEval(vm, "12:34:56.123", "12:34:56.123");
    try expectEval(vm, "12:34:56.123t", "12:34:56.123");
    try expectEval(vm, "12:34:56t", "12:34:56.000");
    try expectEval(vm, "0Nt", "0Nt");
    try expectEval(vm, "0Wt", "0Wt");
    try expectEval(vm, "-0Wt", "-0Wt");
    try expectEval(vm, "12:34:56.123 0Nt", "12:34:56.123 0N");

    try expectEval(vm, "type 2023.04.17", "-14h");
    try expectEval(vm, "type 2023.04.17 2023.04.18", "14h");
    try expectEval(vm, "type 2023.04m", "-13h");
    try expectEval(vm, "type 2023.04.17D12:34:56", "-12h");
    try expectEval(vm, "type 2023.04.17T12:34:56", "-15h");
    try expectEval(vm, "type 0D00:00:01", "-16h");
    try expectEval(vm, "type 12:34", "-17h");
    try expectEval(vm, "type 12:34:56", "-18h");
    try expectEval(vm, "type 12:34:56.123", "-19h");
}

test "temporal arithmetic follows q" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    // An integer keeps the type; the same type subtracted gives an int for dates and months.
    try expectEval(vm, "2023.04.17+1", "2023.04.18");
    try expectEval(vm, "2023.04.17+1h", "2023.04.18");
    try expectEval(vm, "2023.04.17+1i", "2023.04.18");
    try expectEval(vm, "1+2023.04.17", "2023.04.18");
    try expectEval(vm, "2023.04.17-1", "2023.04.16");
    try expectEval(vm, "2023.04.17-2023.04.16", "1i");
    try expectEval(vm, "2023.04.17-2000.01.01", "8507i");
    try expectEval(vm, "2023.04.17+2023.04.17", "17014i");
    try expectEval(vm, "2023.04.17*2", "2046.08.01");
    try expectEval(vm, "2023.04.17%2", "4253.5");
    try expectEval(vm, "neg 2023.04.17", "1976.09.16");
    try expectEval(vm, "2023.04m+1", "2023.05m");
    try expectEval(vm, "2023.04m-1", "2023.03m");
    try expectEval(vm, "2023.04m-2023.01m", "3i");
    try expectEval(vm, "2023.04m+0.5", "279.5");

    // Times of day combine at the finer resolution and stay temporal when subtracted.
    try expectEval(vm, "12:34+1", "12:35");
    try expectEval(vm, "12:35-12:34", "00:01");
    try expectEval(vm, "12:34+12:34", "25:08");
    try expectEval(vm, "12:34:56+1", "12:34:57");
    try expectEval(vm, "12:34:57-12:34:56", "00:00:01");
    try expectEval(vm, "12:34:56.123+1", "12:34:56.124");
    try expectEval(vm, "12:34:56.124-12:34:56.123", "00:00:00.001");
    try expectEval(vm, "12:34+12:34:56", "25:08:56");
    try expectEval(vm, "12:34:56+12:34:56.123", "25:09:52.123");
    try expectEval(vm, "0D00:00:01+1", "0D00:00:01.000000001");
    try expectEval(vm, "0D00:00:02-0D00:00:01", "0D00:00:01.000000000");
    try expectEval(vm, "0D00:00:01*2", "0D00:00:02.000000000");
    // `0D00:00:02%2` is the float 1e9, whose q display needs the pending %g formatting.
    try expectEval(vm, "0D00:00:01+12:00", "0D12:00:01.000000000");
    try expectEval(vm, "neg 0D00:00:01", "-0D00:00:01.000000000");

    // A date-like value plus a time of day is a timestamp; a fraction of a day is a datetime.
    try expectEval(vm, "2023.04.17+12:00", "2023.04.17D12:00:00.000000000");
    try expectEval(vm, "2023.04.17+12:00:00", "2023.04.17D12:00:00.000000000");
    try expectEval(vm, "2023.04.17+12:00:00.000", "2023.04.17D12:00:00.000000000");
    try expectEval(vm, "2023.04.17+0D12:00:00", "2023.04.17D12:00:00.000000000");
    try expectEval(vm, "1899.12.31+0D12:00:00", "1899.12.31D12:00:00.000000000");
    try expectEval(vm, "2023.04.17+0.5", "2023.04.17T12:00:00.000");
    try expectEval(vm, "2023.04.17D12:00:00+1", "2023.04.17D12:00:00.000000001");
    try expectEval(vm, "2023.04.17D12:00:01-2023.04.17D12:00:00", "0D00:00:01.000000000");
    try expectEval(vm, "2023.04.17D12:00:00+0D01:00:00", "2023.04.17D13:00:00.000000000");
    try expectEval(vm, "0D01:00:00+2023.04.17D12:00:00", "2023.04.17D13:00:00.000000000");
    try expectEval(vm, "2023.04.17D12:00:00-0D01:00:00", "2023.04.17D11:00:00.000000000");
    try expectEval(vm, "2023.04.17D12:00:00+12:00", "2023.04.18D00:00:00.000000000");
    try expectEval(vm, "2023.04.17T12:00:00+1", "2023.04.18T12:00:00.000");
    try expectEval(vm, "2023.04.17T12:00:00+0.5", "2023.04.18T00:00:00.000");
    try expectEval(vm, "2023.04.17T12:00:00-2023.04.17T00:00:00", "0.5");
    try expectEval(vm, "2023.04.17T12:00:00+0D01:00:00", "2023.04.17D13:00:00.000000000");
    try expectEval(vm, "2023.04.17T12:00:00.000+0D00:00:00.5", "2023.04.17D12:00:00.500000000");
    try testing.expectError(error.type, vm.evalSource("2023.04.17+2023.04m", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("2023.04.17D12:00:00-2023.04.17", .q, "<test>"));

    // Nulls propagate and infinities wrap.
    try expectEval(vm, "0Nd+1", "0Nd");
    try expectEval(vm, "0Wd+1", "0Nd");
    try expectEval(vm, "0Nd-0Nd", "0Ni");

    try expectEval(vm, "(2023.04.17;2023.04.18)", "2023.04.17 2023.04.18");
    try expectEval(vm, "(2023.04.17;12:00)", "(2023.04.17;12:00)");
    try expectEval(vm, "first 2023.04.17 2023.04.18", "2023.04.17");
    try expectEval(vm, "2023.04.17~2023.04.17", "1b");
    try expectEval(vm, "12:00 12:01!1 2", "12:00 12:01!1 2");
}

test "\\P sets the float display precision" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "\\P", "7i");
    try expectEval(vm, "value \"\\\\P\"", "7i");
    try expectEval(vm, "type value \"\\\\P\"", "-6h");

    // Seven significant digits, C's %.7g: trailing zeros go, exponent form past the precision.
    try expectEval(vm, "1%3", "0.3333333");
    try expectEval(vm, "2%3", "0.6666667");
    try expectEval(vm, "1.23456789", "1.234568");
    try expectEval(vm, "123456789.0", "1.234568e+08");
    try expectEval(vm, "1234567.5", "1234568f");
    try expectEval(vm, "12345678.5", "1.234568e+07");
    try expectEval(vm, "0.0001", "0.0001");
    try expectEval(vm, "0.00001", "1e-05");
    try expectEval(vm, "1e7", "1e+07");
    try expectEval(vm, "1e6", "1000000f");
    try expectEval(vm, "9e15", "9e+15");
    try expectEval(vm, "0.1", "0.1");
    try expectEval(vm, "100000.5", "100000.5");
    try expectEval(vm, "1.5e-7", "1.5e-07");
    try expectEval(vm, "0D00:00:02%2", "1e+09");
    try expectEval(vm, "1e300", "1e+300");
    try expectEval(vm, "-0f", "-0f");
    try expectEval(vm, "3.14159265358979", "3.141593");
    try expectEval(vm, "1 2.5 1e10", "1 2.5 1e+10");
    try expectEval(vm, "0.5 0.25", "0.5 0.25");
    try expectEval(vm, "-3!1.23456789", "\"1.234568\"");

    // Reals display through the same rule from their double value.
    try expectEval(vm, "1.23456789e", "1.234568e");
    try expectEval(vm, "123456789e", "1.234568e+08e");
    try expectEval(vm, "0.1e", "0.1e");
    try expectEval(vm, "1e10e", "1e+10e");

    try expectEval(vm, "\\P 3", "::");
    try expectEval(vm, "\\P", "3i");
    try expectEval(vm, "1%3", "0.333");
    try expectEval(vm, "1.23456789", "1.23");
    try expectEval(vm, "1234.5", "1.23e+03");
    try expectEval(vm, "12345.0", "1.23e+04");
    try expectEval(vm, "1000f", "1e+03");
    try expectEval(vm, "0.001234", "0.00123");
    try expectEval(vm, "1.23456789e", "1.23e");
    try expectEval(vm, "1234e", "1.23e+03e");
    try expectEval(vm, "1 2.5 1234.5", "1 2.5 1.23e+03");

    try expectEval(vm, "\\P 10", "::");
    try expectEval(vm, "1%3", "0.3333333333");
    try expectEval(vm, "1.23456789", "1.23456789");
    try expectEval(vm, "1.23456789e", "1.234567881e");
    try expectEval(vm, "1234567890123.0", "1.23456789e+12");
    try expectEval(vm, "0.1e", "0.1000000015e");
    try expectEval(vm, "1.5e", "1.5e");
    try expectEval(vm, "123456789e", "123456792e");

    // 17 digits expand the binary value exactly.
    try expectEval(vm, "\\P 17", "::");
    try expectEval(vm, "1%3", "0.33333333333333331");
    try expectEval(vm, "0.1", "0.10000000000000001");
    try expectEval(vm, "1.23456789", "1.2345678899999999");
    try expectEval(vm, "1.23456789e", "1.2345678806304932e");
    try expectEval(vm, "0.1e", "0.10000000149011612e");

    // \P 0 is 17 digits for floats but the shortest round trip for reals; above 17 clamps.
    try expectEval(vm, "\\P 0", "::");
    try expectEval(vm, "\\P", "0i");
    try expectEval(vm, "1%3", "0.33333333333333331");
    try expectEval(vm, "0.1", "0.10000000000000001");
    try expectEval(vm, "1e7", "10000000f");
    try expectEval(vm, "1e16", "10000000000000000f");
    try expectEval(vm, "1e17", "1e+17");
    try expectEval(vm, "123456789.0", "123456789f");
    try expectEval(vm, "1e-5", "1.0000000000000001e-05");
    try expectEval(vm, "1.23456789e", "1.2345679e");
    try expectEval(vm, "0.1e", "0.1e");
    try expectEval(vm, "1e10e", "1e+10e");
    try expectEval(vm, "\\P 1", "::");
    try expectEval(vm, "1.5", "2f");
    try expectEval(vm, "12.5", "1e+01");
    try expectEval(vm, "0.15", "0.1");
    try expectEval(vm, "\\P 20", "::");
    try expectEval(vm, "\\P", "17i");
    try expectEval(vm, "0.1", "0.10000000000000001");
    try testing.expectError(error.domain, vm.evalSource("\\P x", .q, "<test>"));
}

test "take repeats, cycles and makes typed empties" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "0#0", "`long$()");
    try expectEval(vm, "0#1 2", "`long$()");
    try expectEval(vm, "0#1.5", "`float$()");
    try expectEval(vm, "0#\"a\"", "\"\"");
    try expectEval(vm, "0#\"ab\"", "\"\"");
    try expectEval(vm, "0#`a", "`symbol$()");
    try expectEval(vm, "0#`a`b", "`symbol$()");
    try expectEval(vm, "0#1b", "`boolean$()");
    try expectEval(vm, "0#0x01", "`byte$()");
    try expectEval(vm, "0#1h", "`short$()");
    try expectEval(vm, "0#1i", "`int$()");
    try expectEval(vm, "0#1e", "`real$()");
    try expectEval(vm, "0#2023.04.17", "`date$()");
    try expectEval(vm, "0#12:00", "`minute$()");
    try expectEval(vm, "0#()", "()");
    try expectEval(vm, "0#(1;\"a\")", "()");
    try expectEval(vm, "0#0N", "`long$()");
    try expectEval(vm, "0#enlist 1", "`long$()");
    try expectEval(vm, "0#0#0", "`long$()");
    try expectEval(vm, "type 0#0", "7h");
    try expectEval(vm, "count 0#0", "0");

    try expectEval(vm, "2#1", "1 1");
    try expectEval(vm, "1#1", ",1");
    try expectEval(vm, "-1#1", ",1");
    try expectEval(vm, "3#1 2", "1 2 1");
    try expectEval(vm, "2#1 2 3", "1 2");
    try expectEval(vm, "-2#1 2 3", "2 3");
    try expectEval(vm, "5#1 2", "1 2 1 2 1");
    try expectEval(vm, "-5#1 2", "2 1 2 1 2");
    try expectEval(vm, "4#1 2 3", "1 2 3 1");
    try expectEval(vm, "-4#1 2 3", "3 1 2 3");
    try expectEval(vm, "-3#1 2 3", "1 2 3");
    try expectEval(vm, "2#\"ab\"", "\"ab\"");
    try expectEval(vm, "3#\"a\"", "\"aaa\"");
    try expectEval(vm, "2#`a", "`a`a");
    try expectEval(vm, "1#`a`b", ",`a");
    try expectEval(vm, "-2#`a`b`c", "`b`c");
    try expectEval(vm, "2#1b", "11b");
    try expectEval(vm, "2#0N", "0N 0N");
    try expectEval(vm, "2#1.5", "1.5 1.5");
    try expectEval(vm, "2#0x01", "0x0101");
    try expectEval(vm, "3#0x0102", "0x010201");
    try expectEval(vm, "2#2023.04.17", "2023.04.17 2023.04.17");
    try expectEval(vm, "2#2023.04m", "2023.04 2023.04m");
    try expectEval(vm, "2#enlist 1", "1 1");
    try expectEval(vm, "2#(1;\"a\")", "(1;\"a\")");
    try expectEval(vm, "3#(1;\"a\")", "(1;\"a\";1)");
    try expectEval(vm, "2#(1;\"a\";`b)", "(1;\"a\")");
    try expectEval(vm, "2#(+)", "(+;+)");
    try expectEval(vm, "2#{[x]1}", "({[x]1};{[x]1})");
    try expectEval(vm, "2h#1 2", "1 2");
    try expectEval(vm, "2i#1 2", "1 2");

    // Taking from an empty list fills with nulls.
    try expectEval(vm, "2#()", "(();())");
    try expectEval(vm, "1#()", ",()");
    try expectEval(vm, "2#`long$()", "0N 0N");
    try expectEval(vm, "2#\"\"", "\"  \"");
    try expectEval(vm, "2#`symbol$()", "``");

    try testing.expectError(error.type, vm.evalSource("0N#1 2", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("1.5#1 2", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("\"a\"#1 2", .q, "<test>"));
}

test "cast makes typed empties and converts between types" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "`long$()", "`long$()");
    try expectEval(vm, "`float$()", "`float$()");
    try expectEval(vm, "`symbol$()", "`symbol$()");
    try expectEval(vm, "`char$()", "\"\"");
    try expectEval(vm, "`boolean$()", "`boolean$()");
    try expectEval(vm, "`byte$()", "`byte$()");
    try expectEval(vm, "`short$()", "`short$()");
    try expectEval(vm, "`int$()", "`int$()");
    try expectEval(vm, "`real$()", "`real$()");
    try expectEval(vm, "`date$()", "`date$()");
    try expectEval(vm, "`month$()", "`month$()");
    try expectEval(vm, "`timestamp$()", "`timestamp$()");
    try expectEval(vm, "`datetime$()", "`datetime$()");
    try expectEval(vm, "`timespan$()", "`timespan$()");
    try expectEval(vm, "`minute$()", "`minute$()");
    try expectEval(vm, "`second$()", "`second$()");
    try expectEval(vm, "`time$()", "`time$()");
    try expectEval(vm, "`$()", "`symbol$()");
    try expectEval(vm, "`long$`long$()", "`long$()");
    try expectEval(vm, "\"j\"$()", "`long$()");
    try expectEval(vm, "\"c\"$()", "\"\"");
    try expectEval(vm, "\"d\"$()", "`date$()");
    try expectEval(vm, "\"s\"$()", "`symbol$()");
    try expectEval(vm, "\"b\"$()", "`boolean$()");
    try expectEval(vm, "`long$\"\"", "`long$()");
    try expectEval(vm, "type `long$()", "7h");
    try expectEval(vm, "type \"j\"$()", "7h");

    // Numbers round half away from zero; shorts and ints saturate, bytes wrap.
    try expectEval(vm, "`long$enlist 1", ",1");
    try expectEval(vm, "`long$1 2h", "1 2");
    try expectEval(vm, "`float$1 2", "1 2f");
    try expectEval(vm, "`int$1.7", "2i");
    try expectEval(vm, "\"j\"$1.9", "2");
    try expectEval(vm, "\"j\"$2.5", "3");
    try expectEval(vm, "\"j\"$-2.5", "-3");
    try expectEval(vm, "\"j\"$0.5", "1");
    try expectEval(vm, "`long$1b", "1");
    try expectEval(vm, "`boolean$1 0", "10b");
    try expectEval(vm, "`boolean$0.5", "1b");
    try expectEval(vm, "`boolean$2", "1b");
    try expectEval(vm, "`boolean$0N", "1b");
    try expectEval(vm, "`short$70000", "0Wh");
    try expectEval(vm, "`short$-70000", "-0Wh");
    try expectEval(vm, "`short$32767", "0Wh");
    try expectEval(vm, "`int$0W", "0Wi");
    try expectEval(vm, "`int$-0W", "-0Wi");
    try expectEval(vm, "`int$3000000000", "0Wi");
    try expectEval(vm, "`long$0W", "0W");
    try expectEval(vm, "`byte$255", "0xff");
    try expectEval(vm, "`byte$256", "0x00");
    try expectEval(vm, "`byte$-1", "0xff");
    try expectEval(vm, "`byte$0N", "0x00");
    try expectEval(vm, "\"x\"$65", "0x41");
    try expectEval(vm, "\"x\"$1.7", "0x02");
    try expectEval(vm, "`real$1%3", "0.3333333e");
    try expectEval(vm, "\"f\"$1", "1f");
    try expectEval(vm, "\"h\"$1", "1h");
    try expectEval(vm, "\"i\"$1", "1i");
    try expectEval(vm, "\"e\"$1", "1e");
    try expectEval(vm, "\"b\"$0", "0b");
    try expectEval(vm, "`long$0x41", "65");
    try expectEval(vm, "`float$0x41", "65f");

    // Nulls stay null except into booleans and bytes.
    try expectEval(vm, "`long$0Nh", "0N");
    try expectEval(vm, "`int$0N", "0Ni");
    try expectEval(vm, "`short$0N", "0Nh");
    try expectEval(vm, "`short$0W", "0Wh");
    try expectEval(vm, "`short$-0W", "-0Wh");
    try expectEval(vm, "`long$0Wi", "2147483647");
    try expectEval(vm, "`long$0Wh", "32767");
    try expectEval(vm, "`real$0Nh", "0Ne");
    try expectEval(vm, "`float$0N", "0n");
    try expectEval(vm, "`long$0n", "0N");
    try expectEval(vm, "`long$0N", "0N");
    try expectEval(vm, "0n", "0n");
    try expectEval(vm, "0w", "0w");
    try expectEval(vm, "-0w", "-0w");
    try expectEval(vm, "0Nn", "0Nn");
    try expectEval(vm, "1 0n 2", "1 0n 2");

    // Chars and symbols.
    try expectEval(vm, "`char$65", "\"A\"");
    try expectEval(vm, "\"c\"$65", "\"A\"");
    try expectEval(vm, "\"c\"$65 66", "\"AB\"");
    try expectEval(vm, "\"c\"$0x41", "\"A\"");
    try expectEval(vm, "`char$\"a\"", "\"a\"");
    try expectEval(vm, "`char$1b", "\"\\001\"");
    try expectEval(vm, "\"a\\nb\"", "\"a\\nb\"");
    try expectEval(vm, "\"\\t\"", "\"\\t\"");
    try expectEval(vm, "\"\\\\\"", "\"\\\\\"");
    try expectEval(vm, "`char$0 27 65", "\"\\000\\033A\"");
    try expectEval(vm, "`long$\"12\"", "49 50");
    try expectEval(vm, "`long$\"a\"", "97");
    try expectEval(vm, "`boolean$\"a\"", "1b");
    try expectEval(vm, "`$\"abc\"", "`abc");
    try expectEval(vm, "`$\"\"", "`");
    try expectEval(vm, "`$\"a b\"", "`a b");
    try expectEval(vm, "`symbol$`a", "`a");
    try expectEval(vm, "`long$(1;2.5)", "1 3");
    try testing.expectError(error.type, vm.evalSource("`symbol$\"abc\"", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("`long$`a", .q, "<test>"));
    try testing.expectError(error.domain, vm.evalSource("`xyz$1", .q, "<test>"));

    // Temporal conversions go by days and nanoseconds.
    try expectEval(vm, "`long$2023.04.17", "8507");
    try expectEval(vm, "`float$2023.04.17", "8507f");
    try expectEval(vm, "`long$12:34", "754");
    try expectEval(vm, "`long$0D00:00:01", "1000000000");
    try expectEval(vm, "`float$2023.04.17T12:00", "8507.5");
    try expectEval(vm, "`date$8507", "2023.04.17");
    try expectEval(vm, "`date$0", "2000.01.01");
    try expectEval(vm, "`date$1.5", "2000.01.03");
    try expectEval(vm, "`date$0N", "0Nd");
    try expectEval(vm, "`date$0Nz", "0Nd");
    try expectEval(vm, "`date$2023.04.17D12:00", "2023.04.17");
    try expectEval(vm, "`date$2023.04.17T12:00", "2023.04.17");
    try expectEval(vm, "`date$2023.04m", "2023.04.01");
    try expectEval(vm, "`month$2023.04.17", "2023.04m");
    try expectEval(vm, "`month$2023.04.17D12:00", "2023.04m");
    try expectEval(vm, "`month$1", "2000.02m");
    try expectEval(vm, "`timestamp$1", "2000.01.01D00:00:00.000000001");
    try expectEval(vm, "`timestamp$1.5", "2000.01.01D00:00:00.000000002");
    try expectEval(vm, "`timestamp$2023.04.17", "2023.04.17D00:00:00.000000000");
    try expectEval(vm, "`timestamp$2023.04.17T12:00", "2023.04.17D12:00:00.000000000");
    try expectEval(vm, "`timestamp$2023.04m", "2023.04.01D00:00:00.000000000");
    try expectEval(vm, "`datetime$2023.04.17", "2023.04.17T00:00:00.000");
    try expectEval(vm, "`datetime$2023.04.17D12:00", "2023.04.17T12:00:00.000");
    try expectEval(vm, "`minute$1", "00:01");
    try expectEval(vm, "`minute$12:34:56", "12:34");
    try expectEval(vm, "`minute$0D12:34:56", "12:34");
    try expectEval(vm, "`minute$12:34:56.123", "12:34");
    try expectEval(vm, "`second$12:34", "12:34:00");
    try expectEval(vm, "`second$12:34:56.789", "12:34:56");
    try expectEval(vm, "`time$12:34:56", "12:34:56.000");
    try expectEval(vm, "`time$0D12:34:56.123456789", "12:34:56.123");
    try expectEval(vm, "`timespan$1", "0D00:00:00.000000001");
    try expectEval(vm, "`timespan$12:34", "0D12:34:00.000000000");
    try expectEval(vm, "`timespan$12:34:56.123", "0D12:34:56.123000000");
    try testing.expectError(error.type, vm.evalSource("`date$12:00", .q, "<test>"));
}

test "capital cast letters parse text as q does" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "\"J\"$\"12\"", "12");
    try expectEval(vm, "\"J\"$\" 12 \"", "12");
    try expectEval(vm, "\"J\"$\"-5\"", "-5");
    try expectEval(vm, "\"J\"$\"+5\"", "5");
    try expectEval(vm, "\"J\"$\"0N\"", "0N");
    try expectEval(vm, "\"J\"$\"0W\"", "0W");
    try expectEval(vm, "\"J\"$\"1.5\"", "0N");
    try expectEval(vm, "\"J\"$\"1e3\"", "0N");
    try expectEval(vm, "\"J\"$\"12abc\"", "0N");
    try expectEval(vm, "\"J\"$\"abc\"", "0N");
    try expectEval(vm, "\"J\"$\"\"", "0N");
    try expectEval(vm, "\"J\"$\"1\"", "1");
    try expectEval(vm, "\"J\"$\"1 2\"", "0N");
    try expectEval(vm, "\"J\"$(\"1\";\"2\")", "12");
    try expectEval(vm, "\"J\"$(\"1\";\"23\")", "1 23");
    try expectEval(vm, "\"J\"$((\"1\";\"2\");\"3\")", "12 3");
    try expectEval(vm, "\"J\"$(\"1\";\"x\")", "0N");
    try expectEval(vm, "\"J\"$(\"1\";\"xy\")", "1 0N");
    try expectEval(vm, "\"J\"$()", "`long$()");
    try expectEval(vm, "type \"J\"$\"12\"", "-7h");
    try testing.expectError(error.type, vm.evalSource("\"J\"$`a", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("\"J\"$1", .q, "<test>"));

    try expectEval(vm, "\"I\"$\"12\"", "12i");
    try expectEval(vm, "\"I\"$\"3000000000\"", "0Ni");
    try expectEval(vm, "\"H\"$\"12\"", "12h");
    try expectEval(vm, "\"H\"$\"70000\"", "0Nh");
    try expectEval(vm, "\"F\"$\"1.5\"", "1.5");
    try expectEval(vm, "\"F\"$\"1e3\"", "1000f");
    try expectEval(vm, "\"F\"$\"abc\"", "0n");
    try expectEval(vm, "\"F\"$\"\"", "0n");
    try expectEval(vm, "\"F\"$\"1\"", "1f");
    try expectEval(vm, "\"E\"$\"1.5\"", "1.5e");
    try expectEval(vm, "\"E\"$\"abc\"", "0Ne");
    try expectEval(vm, "\"B\"$\"1\"", "1b");
    try expectEval(vm, "\"B\"$\"0\"", "0b");
    try expectEval(vm, "\"B\"$\"t\"", "1b");
    try expectEval(vm, "\"B\"$\"Y\"", "1b");
    try expectEval(vm, "\"B\"$\"x\"", "1b");
    try expectEval(vm, "\"B\"$\"true\"", "0b");
    try expectEval(vm, "\"B\"$\"\"", "0b");
    try expectEval(vm, "\"B\"$\"101\"", "0b");
    try expectEval(vm, "\"X\"$\"41\"", "0x41");
    try expectEval(vm, "\"X\"$\"ff\"", "0xff");
    try expectEval(vm, "\"X\"$\"FF\"", "0xff");
    try expectEval(vm, "\"X\"$\"1\"", "0x01");
    try expectEval(vm, "\"X\"$\"xyz\"", "0x00");
    try expectEval(vm, "\"X\"$\"\"", "0x00");
    try expectEval(vm, "\"X\"$\"4142\"", "0x00");
    try expectEval(vm, "\"S\"$\"ab\"", "`ab");
    try expectEval(vm, "\"S\"$\"\"", "`");
    try expectEval(vm, "\"S\"$\" ab \"", "`ab");
    try expectEval(vm, "\"S\"$\"a b\"", "`a b");
    try expectEval(vm, "\"S\"$(\"a\";\"b\")", "`ab");
    try expectEval(vm, "\"S\"$(\"a\";\"bc\")", "`a`bc");
    try expectEval(vm, "\"C\"$\"ab\"", "\" \"");
    try expectEval(vm, "\"C\"$\"a\"", "\"a\"");

    try expectEval(vm, "\"D\"$\"2023.04.17\"", "2023.04.17");
    try expectEval(vm, "\"D\"$\"20230417\"", "2023.04.17");
    try expectEval(vm, "\"D\"$\"2023/04/17\"", "2023.04.17");
    try expectEval(vm, "\"D\"$\"2023-04-17\"", "2023.04.17");
    try expectEval(vm, "\"D\"$\"04/17/2023\"", "2023.04.17");
    try expectEval(vm, "\"D\"$\"17/04/2023\"", "0Nd");
    try expectEval(vm, "\"D\"$\"2024.02.29\"", "2024.02.29");
    try expectEval(vm, "\"D\"$\"2023.02.29\"", "0Nd");
    try expectEval(vm, "\"D\"$\"2023.02.30\"", "0Nd");
    try expectEval(vm, "\"D\"$\"2023.04.31\"", "0Nd");
    try expectEval(vm, "\"D\"$\"2023.13.01\"", "0Nd");
    try expectEval(vm, "\"J\"$\"9223372036854775807\"", "0W");
    try expectEval(vm, "\"J\"$\"9223372036854775808\"", "0N");
    try expectEval(vm, "\"H\"$\"-32768\"", "0Nh");
    try expectEval(vm, "\"F\"$\".5\"", "0.5");
    try expectEval(vm, "\"U\"$\"25:00\"", "25:00");
    try expectEval(vm, "\"D\"$\"abc\"", "0Nd");
    try expectEval(vm, "\"D\"$\"\"", "0Nd");
    try expectEval(vm, "\"M\"$\"2023.04\"", "2023.04m");
    try expectEval(vm, "\"M\"$\"202304\"", "2023.04m");
    try expectEval(vm, "\"M\"$\"2023.04m\"", "0Nm");
    try expectEval(vm, "\"M\"$\"2023.04.17\"", "0Nm");
    try expectEval(vm, "\"P\"$\"2023.04.17D12:34:56.123456789\"", "2023.04.17D12:34:56.123456789");
    try expectEval(vm, "\"P\"$\"2023.04.17\"", "2023.04.17D00:00:00.000000000");
    try expectEval(vm, "\"P\"$\"2023.04.17T12:00\"", "2023.04.17D12:00:00.000000000");
    try expectEval(vm, "\"P\"$\"2023.04.17 12:00\"", "2023.04.17D12:00:00.000000000");
    try expectEval(vm, "\"P\"$\"2023-04-17T12:00:00\"", "2023.04.17D12:00:00.000000000");
    try expectEval(vm, "\"Z\"$\"2023.04.17T12:00:00.000\"", "2023.04.17T12:00:00.000");
    try expectEval(vm, "\"Z\"$\"2023.04.17\"", "2023.04.17T00:00:00.000");
    try expectEval(vm, "\"Z\"$\"2023.04.17D12:00\"", "2023.04.17T12:00:00.000");
    try expectEval(vm, "\"N\"$\"0D12:34:56.123456789\"", "0D12:34:56.123456789");
    try expectEval(vm, "\"N\"$\"12:34:56.123456789\"", "0D12:34:56.123456789");
    try expectEval(vm, "\"N\"$\"12:34\"", "0D12:34:00.000000000");
    try expectEval(vm, "\"N\"$\"1D\"", "1D00:00:00.000000000");
    try expectEval(vm, "\"U\"$\"12:34\"", "12:34");
    try expectEval(vm, "\"U\"$\"12:34:56\"", "12:34");
    try expectEval(vm, "\"U\"$\"1234\"", "12:34");
    try expectEval(vm, "\"U\"$\"12\"", "12:00");
    try expectEval(vm, "\"V\"$\"12:34:56\"", "12:34:56");
    try expectEval(vm, "\"V\"$\"12:34\"", "12:34:00");
    try expectEval(vm, "\"V\"$\"123456\"", "12:34:56");
    try expectEval(vm, "\"T\"$\"12:34:56.123\"", "12:34:56.123");
    try expectEval(vm, "\"T\"$\"12:34:56\"", "12:34:56.000");
    try expectEval(vm, "\"T\"$\"12:34\"", "12:34:00.000");
    try expectEval(vm, "\"T\"$\"123456123\"", "12:34:56.123");
    try expectEval(vm, "\"T\"$\"abc\"", "0Nt");
    try testing.expectError(error.domain, vm.evalSource("\"Q\"$\"1\"", .q, "<test>"));
}

test ".z clock variables read the clock in local time and UTC" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "type .z.D", "-14h");
    try expectEval(vm, "type .z.d", "-14h");
    try expectEval(vm, "type .z.P", "-12h");
    try expectEval(vm, "type .z.p", "-12h");
    try expectEval(vm, "type .z.T", "-19h");
    try expectEval(vm, "type .z.t", "-19h");
    try expectEval(vm, "type .z.N", "-16h");
    try expectEval(vm, "type .z.n", "-16h");
    try expectEval(vm, "type .z.Z", "-15h");
    try expectEval(vm, "type .z.z", "-15h");
    try expectEvalMode(vm, .k, "@.z.p", "-12h");

    // UTC now agrees with the clock module to within a second.
    const utc = try vm.evalSource(".z.p", .q, "<test>");
    defer utc.deref(vm.gpa);
    const now = q.clock.now(vm.io);
    try testing.expect(now - utc.as.timestamp >= 0 and now - utc.as.timestamp < q.literal.ns_per_second);

    // The date, time, timespan and datetime are the timestamp's parts. A list is evaluated
    // right to left, so each item is read no later than the one before it.
    try expectEval(vm, "(`date$.z.p)-.z.d", "0i");
    try expectEval(vm, "(`date$.z.P)-.z.D", "0i");
    const parts = try vm.evalSource("(.z.p;.z.n;.z.t;.z.z)", .q, "<test>");
    defer parts.deref(vm.gpa);
    const stamp = parts.as.list[0].as.timestamp;
    const since_midnight = parts.as.list[1].as.timespan;
    try testing.expect(since_midnight <= @mod(stamp, q.literal.ns_per_day));
    try testing.expect(@mod(stamp, q.literal.ns_per_day) - since_midnight < q.literal.ns_per_second);
    try testing.expect(parts.as.list[2].as.time <= @divFloor(since_midnight, 1_000_000));
    const days = @as(f64, @floatFromInt(stamp)) / @as(f64, @floatFromInt(q.literal.ns_per_day));
    try testing.expect(parts.as.list[3].as.datetime <= days and days - parts.as.list[3].as.datetime < 1.0 / 86_400.0);

    // Local time is UTC shifted by the zone's offset, a whole number of minutes; `.z.p` is
    // read first, so the difference is the offset plus a few microseconds.
    const shift = try vm.evalSource(".z.P-.z.p", .q, "<test>");
    defer shift.deref(vm.gpa);
    const unix_seconds = @divFloor(now, q.literal.ns_per_second) + q.literal.epoch_days * 86_400;
    const expected_shift = vm.local_zone.offset(unix_seconds) * q.literal.ns_per_second;
    try testing.expect(shift.as.timespan >= expected_shift and shift.as.timespan - expected_shift < q.literal.ns_per_second);

    // `.z` is a namespace that accepts other entries; the clock names cannot be replaced.
    try expectEval(vm, ".z.foo:1", "::");
    try expectEval(vm, ".z.foo", "1");
    try expectEval(vm, ".z.D:1", "::");
    try expectEval(vm, "type .z.D", "-14h");
}

test "pad and cast by type number" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "5$\"ab\"", "\"ab   \"");
    try expectEval(vm, "-5$\"ab\"", "\"   ab\"");
    try expectEval(vm, "1$\"abc\"", ",\"a\"");
    try expectEval(vm, "0$\"abc\"", "\"\"");
    try expectEval(vm, "5$(\"ab\";\"cde\")", "(\"ab   \";\"cde  \")");
    try expectEval(vm, "5$\"\"", "\"     \"");
    try expectEval(vm, "5$()", "\"     \"");
    try expectEval(vm, "5$enlist \"a\"", "\"a    \"");
    try expectEval(vm, "-3$\"abcdef\"", "\"def\"");
    try expectEval(vm, "3$\"abcdef\"", "\"abc\"");
    try testing.expectError(error.type, vm.evalSource("5$\"a\"", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("5$1", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("5$`ab", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("5i$\"ab\"", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("5f$\"ab\"", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("2 3$\"ab\"", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("5$(\"ab\";\"c\")", .q, "<test>"));
    try testing.expectError(error.length, vm.evalSource("0N$\"ab\"", .q, "<test>"));

    try expectEval(vm, "5h$\"abc\"", "97 98 99h");
    try expectEval(vm, "5h$1.5", "2h");
    try expectEval(vm, "7h$1.5", "2");
    try expectEval(vm, "-5h$\"12\"", "12h");
    try expectEval(vm, "-7h$\"1\"", "1");
    try expectEval(vm, "0h$\"abc\"", "\"abc\"");
    try expectEval(vm, "0h$1 2", "1 2");
    try expectEval(vm, "10h$1 2", "\"\\001\\002\"");
    try testing.expectError(error.type, vm.evalSource("20h$1", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("11h$\"abc\"", .q, "<test>"));
}

test "reshape cuts a list into rows as q does" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "2 3#til 6", "(0 1 2;3 4 5)");
    try expectEval(vm, "2 3#1", "(1 1 1;1 1 1)");
    try expectEval(vm, "2 3#5", "(5 5 5;5 5 5)");
    try expectEval(vm, "2 3#til 4", "(0 1 2;3 0 1)");
    try expectEval(vm, "2 3#1 2 3 4 5 6 7 8", "(1 2 3;4 5 6)");
    try expectEval(vm, "2 0N#til 6", "(0 1 2;3 4 5)");
    try expectEval(vm, "0N 2#til 6", "(0 1;2 3;4 5)");
    try expectEval(vm, "0N 4#til 6", "(0 1 2 3;4 5)");
    try expectEval(vm, "0N 3#til 7", "(0 1 2;3 4 5;,6)");
    try expectEval(vm, "3 0N#til 7", "(0 1;2 3;4 5 6)");
    try expectEval(vm, "2 0N#til 7", "(0 1 2;3 4 5 6)");
    try expectEval(vm, "0N 2#()", "()");
    try expectEval(vm, "2 3 4#til 24", "((0 1 2 3;4 5 6 7;8 9 10 11);(12 13 14 15;16 17 18 19;20 21 22 23))");
    try expectEval(vm, "2 3#\"abcdef\"", "(\"abc\";\"def\")");
    try expectEval(vm, "2 3#`a`b", "(`a`b`a;`b`a`b)");
    try expectEval(vm, "3 3#`a", "(`a`a`a;`a`a`a;`a`a`a)");
    try expectEval(vm, "2 3#()", "((();();());(();();()))");
    try expectEval(vm, "2 3#til 0", "(0N 0N 0N;0N 0N 0N)");
    try expectEval(vm, "2 2#(1;2)", "(1 2;1 2)");
    try expectEval(vm, "2 3#enlist 1 2 3", "((1 2 3;1 2 3;1 2 3);(1 2 3;1 2 3;1 2 3))");
    try expectEval(vm, "2 3#(1;2;`a)", "((1;2;`a);(1;2;`a))");
    try expectEval(vm, "2 3#(1 2;3)", "((1 2;3;1 2);(3;1 2;3))");
    try expectEval(vm, "3 2#(1;2;3;4;5;6)", "(1 2;3 4;5 6)");
    try expectEval(vm, "1 2#1", ",1 1");
    try expectEval(vm, "2 3#0 1 2 3 4 5 6 7 8f", "(0 1 2f;3 4 5f)");
    try expectEval(vm, "2 2#2 3#til 6", "((0 1 2;3 4 5);(0 1 2;3 4 5))");
    try testing.expectError(error.length, vm.evalSource("0 3#til 6", .q, "<test>"));
    try testing.expectError(error.length, vm.evalSource("-2 3#til 6", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("2 3h#til 6", .q, "<test>"));
    try testing.expectError(error.domain, vm.evalSource("0N 2 3#til 12", .q, "<test>"));
    try testing.expectError(error.domain, vm.evalSource("0N 0N#til 6", .q, "<test>"));
}

test "take on a dictionary selects entries by count or by key" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "`a`c#`a`b`c!1 2 3", "`a`c!1 3");
    try expectEval(vm, "`a`x#`a`b`c!1 2 3", "`a`x!1 0N");
    try expectEval(vm, "`x`a#`a`b`c!(1;\"x\";`s)", "`x`a!0N 1");
    try expectEval(vm, "`a`c#`a`b`c!(1;\"x\";`s)", "`a`c!(1;`s)");
    try expectEval(vm, "`a`x#`a`b!(\"ab\";\"cd\")", "`a`x!(\"ab\";\"\")");
    try expectEval(vm, "`a`x#`a`b`c!1 2 3f", "`a`x!1 0n");
    try expectEval(vm, "`a`b#(`a`b`c)!(1 2;3;`x)", "`a`b!(1 2;3)");
    try expectEval(vm, "1 2#1 2 3!4 5 6", "1 2!4 5");
    try expectEval(vm, "1 9#1 2 3!4 5 6", "1 9!4 0N");
    try expectEval(vm, "2#`a`b`c!1 2 3", "`a`b!1 2");
    try expectEval(vm, "-2#`a`b`c!1 2 3", "`b`c!2 3");
    try expectEval(vm, "0#`a`b`c!1 2 3", "(`symbol$())!`long$()");
    try expectEval(vm, "(`symbol$())#`a`b!1 2", "(`symbol$())!`long$()");
    try expectEval(vm, "5#`a`b`c!1 2 3", "`a`b`c`a`b!1 2 3 1 2");
    try expectEval(vm, "2#`a`b!(1;\"x\")", "`a`b!(1;\"x\")");
    try expectEval(vm, "type `a`c#`a`b`c!1 2 3", "99h");
    try expectEval(vm, "(enlist `a)!enlist 1", "(,`a)!,1");
    try expectEval(vm, "(enlist \"a\")!enlist 1", "(,\"a\")!,1");
    try expectEval(vm, "(enlist \"ab\")!enlist 1", ",\"ab\"!,1");
    try expectEval(vm, "(`long$())!()", "(`long$())!()");
    try expectEval(vm, "\"ab\"!1 2", "\"ab\"!1 2");
    try expectEval(vm, "(1 2;3)!4 5", "(1 2;3)!4 5");
    try testing.expectError(error.type, vm.evalSource("`a#`a`b`c!1 2 3", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("2 3#`a`b!1 2", .q, "<test>"));
}

test "arithmetic over lists pairs items and unifies the results" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "1 2 3+1", "2 3 4");
    try expectEval(vm, "1+1 2 3", "2 3 4");
    try expectEval(vm, "1 2 3+1 2 3", "2 4 6");
    try expectEval(vm, "1 2 3+(1;2;3)", "2 4 6");
    try expectEval(vm, "1 2 3+1 2 3i", "2 4 6");
    try expectEval(vm, "1 2 3h+1 2 3h", "2 4 6i");
    try expectEval(vm, "1 2 3-1 2 3h", "0 0 0");
    try expectEval(vm, "1 2 3*2.5", "2.5 5 7.5");
    try expectEval(vm, "1 2 3%2", "0.5 1 1.5");
    try expectEval(vm, "1 2 3+0N 1 2", "0N 3 5");
    try expectEval(vm, "01b+1", "1 2");
    try expectEval(vm, "0x01+1 2", "2 3");
    try expectEval(vm, "2023.04.17 2023.04.18+1", "2023.04.18 2023.04.19");
    try expectEval(vm, "(1 2;3 4)+1", "(2 3;4 5)");
    try expectEval(vm, "(1 2;3 4)+1 2", "(2 3;5 6)");
    try expectEval(vm, "1+(1 2;3 4)", "(2 3;4 5)");
    try expectEval(vm, "(1 2;3)+(1;2 3)", "(2 3;5 6)");
    try expectEval(vm, "()+1", "()");
    try expectEval(vm, "1+`long$()", "`long$()");
    try expectEval(vm, "()+()", "()");
    try testing.expectError(error.length, vm.evalSource("1 2 3+1 2", .q, "<test>"));
    try testing.expectError(error.length, vm.evalSource("1 2 3+()", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("(1;2;`a)+1", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("\"ab\"+1", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("0x0102+1", .q, "<test>"));
}

test "string literal escapes decode as in q" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "\"\\001\"", "\"\\001\"");
    try expectEval(vm, "count \"\\001\"", "1");
    try expectEval(vm, "`long$\"\\123\"", "83");
    try expectEval(vm, "`long$\"\\1234\"", "83 52");
    try expectEval(vm, "`long$\"\\377\"", "255");
    try expectEval(vm, "`long$\"\\/\"", "47");
    try expectEval(vm, "`long$\"\\\"\"", "34");
    try expectEval(vm, "`long$\"\\\\\"", "92");
    try expectEval(vm, "`long$\"\\n\\t\\r\"", "10 9 13");
    try expectEval(vm, "\"a\\\"b\"", "\"a\\\"b\"");
    try testing.expectError(error.parse, vm.evalSource("\"\\q\"", .q, "<test>"));
    try testing.expectError(error.parse, vm.evalSource("\"\\1\"", .q, "<test>"));
    try testing.expectError(error.parse, vm.evalSource("\"\\12\"", .q, "<test>"));
    try testing.expectError(error.parse, vm.evalSource("\"\\400\"", .q, "<test>"));
    try testing.expectError(error.parse, vm.evalSource("\"\\8\"", .q, "<test>"));
    try testing.expectError(error.parse, vm.evalSource("\"\\x41\"", .q, "<test>"));
}

test "a type suffix belongs on the last token of a list literal" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "0N 0W -0Wh", "0N 0W -0Wh");
    try expectEval(vm, "0N 0Nh", "0N 0Nh");
    try expectEval(vm, "1e3 2", "1000 2f");
    try expectEval(vm, "0n 0w", "0n 0w");
    try expectEval(vm, "1 0n", "1 0n");
    try expectEval(vm, "1 2j", "1 2");
    try expectEval(vm, "2023.04.17 0Nd", "2023.04.17 0N");
    try expectEval(vm, "12:34 0Nu", "12:34 0N");
    try expectEval(vm, "1 2p", "2000.01.01D01:00:00.000000000 2000.01.01D02:00:00.000000000");
    try expectEval(vm, "3600p", "2000.01.02D12:00:00.000000000");
    try expectEval(vm, "25p", "2000.01.02D01:00:00.000000000");
    try expectEval(vm, "-1p", "1999.12.31D23:00:00.000000000");
    try expectEval(vm, "12345p", "2000.01.06D03:45:00.000000000");
    try expectEval(vm, "100n", "0D01:00:00.000000000");
    try expectEval(vm, "-100n", "-0D01:00:00.000000000");
    try expectEval(vm, "123456n", "0D12:34:56.000000000");
    try expectEval(vm, "100t", "01:00:00.000");
    try expectEval(vm, "3600t", "36:00:00.000");
    try expectEval(vm, "123456t", "12:34:56.000");
    try expectEval(vm, "1234u", "12:34");
    try expectEval(vm, "3600v", "36:00:00");
    try testing.expectError(error.InvalidCharacter, vm.evalSource("1234567n", .q, "<test>"));
    try testing.expectError(error.InvalidCharacter, vm.evalSource("1e9p", .q, "<test>"));
    try expectEval(vm, "0D01 0D02", "0D01:00:00.000000000 0D02:00:00.000000000");
    for ([_][:0]const u8{
        "1h 2h",   "1 2h 3", "1h 2",   "1e 2e",     "1f 2",             "1e 2", "0Nh 0N", "0Nd 2023.04.17",
        "0Np 0Np", "1j 2",   "1i 2 3", "0Nu 12:34", "0Nt 12:34:56.000", "1p 2", "1n 2n",
    }) |source| {
        try testing.expectError(error.parse, vm.evalSource(source, .q, "<test>"));
    }

    // Boolean and byte literals never join a number list: they are juxtaposed instead.
    try expectEval(vm, "parse \"1 0 1b\"", "(1 0;1b)");
    try expectEval(vm, "parse \"1 0 101b\"", "(1 0;101b)");
    try expectEval(vm, "parse \"1 0 0x01\"", "(1 0;0x01)");
    try expectEval(vm, "parse \"1 0 0x0001\"", "(1 0;0x0001)");
    try expectEval(vm, "parse \"1b 1 0\"", "(1b;1 0)");
    try expectEval(vm, "parse \"1 0 1b 2\"", "(1 0;(1b;2))");
    try expectEval(vm, "parse \"1 0 1b 1b\"", "(1 0;(1b;1b))");
    try expectEval(vm, "parse \"1 0 1.5 1b\"", "(1 0 1.5;1b)");
    try expectEval(vm, "parse \"1 0 1h 1b\"", "(1 0 1h;1b)");
    try testing.expectError(error.InvalidCharacter, vm.evalSource("3b", .q, "<test>"));
    try testing.expectError(error.InvalidCharacter, vm.evalSource("1 2 3b", .q, "<test>"));
}

test "lambdas take q's implicit parameters, locals and projections" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "{x} 1 2 3", "1 2 3");
    try expectEval(vm, "{y}[1;2]", "2");
    try expectEval(vm, "{z}[1;2;3]", "3");
    try expectEval(vm, "{}[]", "::");
    try expectEval(vm, "{x}[]", "::");
    try expectEval(vm, "{[]1}[]", "1");
    try expectEval(vm, "{[]1}[1]", "1");
    try expectEval(vm, "{[]1} 5", "1");
    try expectEval(vm, "{[]}[]", "::");
    try expectEval(vm, "{[]}[1]", "::");
    try expectEval(vm, "{}[1]", "::");
    try expectEval(vm, "{[a]a}[]", "::");
    try expectEval(vm, "(value {[]1})[1]", ",`");
    try testing.expectError(error.rank, vm.evalSource("{[]1}[1;2]", .q, "<test>"));
    try testing.expectError(error.rank, vm.evalSource("{}[1;2]", .q, "<test>"));
    try testing.expectError(error.identifier, vm.evalSource("{[]x}[5]", .q, "<test>"));
    try expectEval(vm, "{1}[]", "1");
    try expectEval(vm, "{x}[1]", "1");
    try expectEval(vm, "{[a;b]a+b}[1;2]", "3");
    try expectEval(vm, "({x+y})[1;2]", "3");
    try expectEval(vm, "{x;y}[1;2]", "2");
    try expectEval(vm, "{x+y;}[1;2]", "::");
    try expectEval(vm, "{x+y}[1]", "{x+y}[1]");
    try expectEval(vm, "{x+y}[1;] 2", "3");
    try expectEval(vm, "{x+y}[;2] 1", "3");
    try expectEval(vm, "{x+y+z}[;2][1;3]", "6");
    try expectEval(vm, "{x+y+z}[1;;3][2]", "6");
    try expectEval(vm, "{x+y+z}[1][2][3]", "6");
    try expectEval(vm, "{x+y+z}[;;3][1]", "{x+y+z}[;;3][1]");
    try expectEval(vm, "{x+y+z}[;;3][1;2]", "6");
    try expectEval(vm, "{x+y+z}[1][2]", "{x+y+z}[1][2]");
    try expectEval(vm, "{x+y+z}[1][2][3]", "6");
    try expectEval(vm, "{x+y+z}[1;2][3]", "6");
    try expectEval(vm, "{x+y}[;][1]", "{x+y}[;][1]");
    try expectEval(vm, "{x+y}[;][1][2]", "3");
    try expectEval(vm, "{x+y}[1][2]", "3");
    try expectEval(vm, "{x+y+z}[;2][1]", "{x+y+z}[;2][1]");
    try expectEval(vm, "{x+y+z}[;2][1][3]", "6");
    try expectEval(vm, "{x+y+z}[;2][;3]", "{x+y+z}[;2][;3]");
    try expectEval(vm, "{x+y+z}[;2][;3][1]", "6");
    try expectEval(vm, "value {x+y+z}[;;3][1]", "({x+y+z}[;;3];1)");
    try expectEval(vm, "value {x+y+z}[;2][;3]", "({x+y+z}[;2];::;3)");
    try expectEval(vm, "-3!{x+y+z}[;;3][1]", "\"{x+y+z}[;;3][1]\"");
    try expectEval(vm, "enlist[;;5][1]", "enlist[;;5][1]");
    try expectEval(vm, "enlist[;;5][1][2]", "1 2 5");
    try expectEval(vm, "+[;3][1]", "4");
    try expectEval(vm, "+[1][2]", "3");
    try expectEval(vm, "{x+y+z}[;;3][1]~{x+y+z}[1;;3]", "0b");
    try expectEval(vm, "{x+y+z}[;;3][1;]", "{x+y+z}[;;3][1;]");
    try expectEval(vm, "{x+y+z}[;;3][;1]", "{x+y+z}[;;3][;1]");
    try expectEval(vm, "{x+y+z}[;;3][;1][2]", "6");
    try expectEval(vm, "type {x+y+z}[;;3][1]", "104h");
    try expectEval(vm, "{x+y+z}[;;3][]", "{x+y+z}[;;3][::]");
    try expectEval(vm, "{x+y+z}[;;3][;]", "{x+y+z}[;;3][;]");
    try expectEval(vm, "{[a;b;c;d]a+b+c+d}[;;3][1][2]", "{[a;b;c;d]a+b+c+d}[;;3][1][2]");
    try expectEval(vm, "{[a;b;c;d]a+b+c+d}[;;3][1][2][4]", "10");
    try expectEval(vm, "{[a;b;c;d]a+b+c+d}[;;3][1][;4]", "{[a;b;c;d]a+b+c+d}[;;3][1][;4]");
    try expectEval(vm, "{[a;b;c;d]a+b+c+d}[;;3][1][;4][2]", "10");
    try expectEval(vm, "@[;1][2 3]", "3");
    try expectEval(vm, ".[;1 2][{x+y}]", "3");
    try testing.expectError(error.type, vm.evalSource("{x+y+z}[;;3][::;1]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("{x+y+z}[;;3][1;::]", .q, "<test>"));
    try expectEval(vm, "{x+y+z}[;;3][1][2]", "6");
    try expectEval(vm, "f:{x+y+z};g:f[1];h:g[2];h 3", "6");
    try expectEval(vm, "hn:{(x;y)}[;0];hy:hn 1;hy", "1 0");
    try expectEval(vm, "{x+y}[;][1;2]", "3");
    try expectEval(vm, "{a:1;a+x} 2", "3");
    try expectEval(vm, "{a:x;a}[5]", "5");
    try expectEval(vm, "{x:x+1;x} 1", "2");
    try expectEval(vm, "{x::5;x} 1", "5");
    try expectEval(vm, "{{x+y}[x;1]} 2", "3");
    try expectEval(vm, "{x y}[{x*2};3]", "6");
    try expectEval(vm, "{x} {y}", "{y}");
    try expectEval(vm, "{count x} 1 2 3", "3");
    try expectEval(vm, "{x*2}@3", "6");
    try expectEval(vm, "{[x]x*2} 3", "6");
    try expectEval(vm, "{(x;y)}[1;`a]", "(1;`a)");
    try expectEval(vm, "{.z.s} 1", "{.z.s}");
    try expectEval(vm, "-3!{x+y}", "\"{x+y}\"");
    try expectEval(vm, "(value {x+y})[1 2 3]", "(`x`y;`symbol$();,`)");
    try expectEval(vm, "(value {a:1;b::2;c})[1 2 3]", "(,`x;,`a;``b`c)");
    try expectEval(vm, "(value {[a]x})[1 2 3]", "(,`a;`symbol$();``x)");
    try testing.expectError(error.rank, vm.evalSource("{x}[1;2]", .q, "<test>"));
    try testing.expectError(error.identifier, vm.evalSource("{[a]x}[1]", .q, "<test>"));
    try testing.expectError(error.identifier, vm.evalSource("{r:a;a:1;r}[]", .q, "<test>"));
    try testing.expectError(error.identifier, vm.evalSource("{a:1;{a}[]}[]", .q, "<test>"));
}

test "lambdas resolve bare globals in their defining namespace and inline keywords" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    // A keyword is inlined when the lambda is parsed, so a later change to `.q` is not seen.
    try expectEval(vm, "f:{neg x};.q.neg:{x*10};f 1", "-1");
    try expectEval(vm, "neg 1", "10");
    try expectEvalMode(vm, .k, ".q.neg:-:", "::");
    try expectEval(vm, "neg 1", "-1");

    for ([_][:0]const u8{ "value \"\\\\d .foo\"", "t0:{x+1}", "f:{t0 x}", "g:{neg x}", "h:{x+y}", "a:5", "k:{a}", "k2:{.foo.a}", "s:{b::x}", "later:{t1 x}", "value \"\\\\d .\"" }) |source| {
        const value = try vm.evalSource(source, .q, "<test>");
        value.deref(vm.gpa);
    }
    try expectEval(vm, "t1:{x+100};a:7", "::");

    try expectEval(vm, ".foo.f 1", "2");
    try expectEval(vm, ".foo.g 1", "-1");
    try expectEval(vm, ".foo.h[1;2]", "3");
    try expectEval(vm, ".foo.k[]", "5");
    try expectEval(vm, ".foo.k2[]", "5");
    // A bare name is looked up in `.foo` only, never in the root, and binds at call time.
    try testing.expectError(error.identifier, vm.evalSource(".foo.later 1", .q, "<test>"));
    try expectEval(vm, ".foo.t1:{x+200};.foo.later 1", "201");
    // `::` assigns into the lambda's namespace.
    try expectEval(vm, ".foo.s 3;.foo.b", "3");
    try testing.expectError(error.identifier, vm.evalSource("b", .q, "<test>"));
    try expectEval(vm, "(value .foo.f)[3]", "`foo`t0");
    try expectEval(vm, "(value t1)[3]", ",`");
}

test "indexing and the apply operators follow q" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "1 2 3[0 2]", "1 3");
    try expectEval(vm, "1 2 3[-1]", "0N");
    try expectEval(vm, "1 2 3[0N]", "0N");
    try expectEval(vm, "1 2 3[::]", "1 2 3");
    try expectEval(vm, "1 2 3[1i]", "2");
    try expectEval(vm, "1 2 3[1h]", "2");
    try expectEval(vm, "1 2 3[1b]", "2");
    try expectEval(vm, "1 2 3[()]", "()");
    try expectEval(vm, "1 2 3[0#0]", "`long$()");
    try expectEval(vm, "\"abc\"[0#0]", "\"\"");
    try expectEval(vm, "1 2 3[(0;1)]", "1 2");
    try expectEval(vm, "(1;`a)[0 1]", "(1;`a)");
    try expectEval(vm, "(1;`a) 5", "0N");
    try expectEval(vm, "\"abc\" 5", "\" \"");
    try expectEval(vm, "`a`b`c 1", "`b");
    try expectEval(vm, "(1;\"ab\")[1 1]", "(\"ab\";\"ab\")");
    try expectEval(vm, "(1 2;3 4)[1;0]", "3");
    try expectEval(vm, "(1 2;3 4)[;0]", "1 3");
    try expectEval(vm, "{x[1]}[1 2 3]", "2");
    try testing.expectError(error.type, vm.evalSource("1 2 3[1.5]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("1 2 3[1;2]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("1 2 3[0 1;]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("1 2 3 sum", .q, "<test>"));

    try expectEval(vm, "{x+y}@1", "{x+y}[1]");
    try expectEval(vm, "{x+y} . 1 2", "3");
    try expectEval(vm, "{x+y} . (1;2)", "3");
    try expectEval(vm, "{x} . enlist 5", "5");
    try expectEval(vm, "(+) . 1 2", "3");
    try expectEval(vm, "@[{x*2};3]", "6");
    try expectEval(vm, ".[{x+y};1 2]", "3");
    try expectEval(vm, "neg@1", "-1");
    try expectEval(vm, "(neg)@1 2", "-1 -2");
}

test "a symbol-valued .q entry reads as an alias and cannot be assigned" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    // Verified against q 5.0; q 4.0 differs only in allowing the assignments.
    try expectEval(vm, ".q.a:`alias", "::");
    try testing.expectError(error.identifier, vm.evalSource("a", .q, "<test>"));
    try testing.expectError(error.identifier, vm.evalSource("{a}[]", .q, "<test>"));
    try expectEval(vm, "parse \"a 1\"", "(`alias;1)");
    try expectEval(vm, "alias:42;a", "42");
    try expectEval(vm, "{a}[]", "42");
    try expectEval(vm, "{[alias]a}[3]", "3");
    try expectEval(vm, "(value {a})[3]", "``alias");
    // The entry must exist before the line using it is parsed, in q as well.
    try expectEval(vm, ".q.b:`x", "::");
    try expectEval(vm, "{b}[7]", "7");
    try expectEval(vm, "(value {b})[1]", ",`x");
    try testing.expectError(error.assign, vm.evalSource("a:5", .q, "<test>"));
    try testing.expectError(error.assign, vm.evalSource("a::5", .q, "<test>"));
    try testing.expectError(error.assign, vm.evalSource("parse \"a:5\"", .q, "<test>"));
    try testing.expectError(error.assign, vm.evalSource("f:{a:5;a}", .q, "<test>"));
    try testing.expectError(error.assign, vm.evalSource("{a::5;alias}", .q, "<test>"));
    try expectEval(vm, ".q.d:5", "::");
    try testing.expectError(error.assign, vm.evalSource("{d:1}", .q, "<test>"));
    try testing.expectError(error.assign, vm.evalSource("d:1", .q, "<test>"));
    try expectEval(vm, "alias", "42");

    // The alias is a name in the lambda's namespace like any other, and not transitive.
    for ([_][:0]const u8{ "value \"\\\\d .foo\"", "f:{a}", "value \"\\\\d .\"" }) |source| {
        const value = try vm.evalSource(source, .q, "<test>");
        value.deref(vm.gpa);
    }
    try testing.expectError(error.identifier, vm.evalSource(".foo.f[]", .q, "<test>"));
    try expectEval(vm, ".foo.alias:9;.foo.f[]", "9");
    try expectEval(vm, ".q.c:`neg", "::");
    try testing.expectError(error.identifier, vm.evalSource("c 1", .q, "<test>"));
    try testing.expectError(error.identifier, vm.evalSource("{c x}[1]", .q, "<test>"));
}

test "lambda bytecode follows q's encoding" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    // The bytes q shows through `value`, minus its trailing stack-size byte.
    try expectEval(vm, "(value {x+y})[0]", "98 97 65 0");
    try expectEval(vm, "(value {neg x})[0]", "97 34 0");
    try expectEval(vm, "(value {x in y})[0]", "98 97 87 0");
    try expectEval(vm, "(value {x=y})[0]", "98 97 72 0");
    try expectEval(vm, "(value {x@y})[0]", "98 97 82 0");
    try expectEval(vm, "(value {x;y})[0]", "97 2 98 0");
    try expectEval(vm, "(value {x[1]})[0]", "13 97 82 0");
    try expectEval(vm, "(value {f[1;2]})[0]", "160 13 129 10 2 0");
    try expectEval(vm, "(value {(x;y)})[0]", "98 97 160 10 2 0");
    try expectEval(vm, "(value {a:1})[0]", "13 3 9 0");
    try expectEval(vm, "(value {x:1;x})[0]", "13 3 1 2 97 0");
    try expectEval(vm, "(value {a::1})[0]", "13 11 4 129 0 0");
    try expectEval(vm, "(value {a::1;a})[0]", "13 11 4 129 0 2 129 0");
    try expectEval(vm, "(value {[p]l:1;p+g1+g2})[0]", "13 3 9 2 130 129 65 97 65 0");
    try expectEval(vm, "(value {`a})[0]", "160 0");
    try expectEval(vm, "(value {})[0]", "16 0");

    // An amend as the last statement returns `::`, but has its value inside an expression.
    try expectEval(vm, "{a::5}[]", "::");
    try expectEval(vm, "{(a::5)+1}[]", "6");
    try expectEval(vm, "{r:(a::7);r}[]", "7");
    try expectEval(vm, "a", "7");
    try expectEval(vm, "{a:5}[]", "5");
    try expectEval(vm, "{x:5}[1]", "5");
}

fn expectSignal(vm: *Vm, source: [:0]const u8, message: []const u8) !void {
    try testing.expectError(error.signal, vm.evalSource(source, .q, "<test>"));
    try testing.expectEqualStrings(message, vm.signal_message.?);
}

test "conditionals, control words, return and signal follow q" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    // `$[c;a;b]`, at the top level and compiled, takes integer-like atoms as conditions.
    try expectEval(vm, "$[1b;1;2]", "1");
    try expectEval(vm, "$[0;1;2]", "2");
    try expectEval(vm, "$[0N;1;2]", "1");
    try expectEval(vm, "$[0x00;1;2]", "2");
    try expectEval(vm, "$[2023.01.01;1;2]", "1");
    try expectEval(vm, "$[1;1;0;2;3]", "1");
    try expectEval(vm, "$[0;1;0;2;3]", "3");
    try expectEval(vm, "$[0;1;1;2;3]", "2");
    try expectEval(vm, "$[0;1;0;2]", "::");
    try expectEval(vm, "$[1;;2]", "::");
    try expectEval(vm, "$[1;2;]", "2");
    try expectEval(vm, "$[1;1;'`boom]", "1");
    for ([_][:0]const u8{ "$[1 2;1;2]", "$[`a;1;2]", "$[1.0;1;2]", "$[0n;1;2]", "$[(::);1;2]", "$[1;2]" }) |source| {
        try testing.expectError(error.type, vm.evalSource(source, .q, "<test>"));
    }
    try expectEval(vm, "{$[x;1;2]}[0]", "2");
    try expectEval(vm, "{$[x;:1;2];3}[1]", "1");
    try expectEval(vm, "{$[x;:1;2];3}[0]", "3");
    try expectEval(vm, "{r:$[x;1;2];r*10}[0]", "20");
    try expectEval(vm, "{$[x;:`yes;:`no]}[1]", "`yes");

    try expectEval(vm, "if[1;2]", "::");
    try expectEval(vm, "if[0;'`boom]", "::");
    try expectEval(vm, "{if[x;:5];6}[1]", "5");
    try expectEval(vm, "{if[x;:5];6}[0]", "6");
    try expectEval(vm, "{if[x;'`boom];1}[0]", "1");
    try expectSignal(vm, "{if[x;'`boom];1}[1]", "boom");

    try expectEval(vm, "while[0;1]", "::");
    try expectEval(vm, "{while[x;x-:1];x}[3]", "0");
    try expectEval(vm, "n:3;while[n;n-:1];n", "0");
    try expectEval(vm, "{do[3;x+:1];x}[0]", "3");
    try expectEval(vm, "{do[0;x:1];x}[5]", "5");
    try expectEval(vm, "a:0;b:0;{do[2;a+:1;b+:2];(a;b)}[]", "2 4");
    try expectEval(vm, "c:0;do[4;c+:1];c", "4");

    try expectEval(vm, "{:x;y}[1;2]", "1");
    try expectEval(vm, "{:x}[3]", "3");
    try expectEval(vm, "{`a}[]", "`a");
    try expectEval(vm, "{`a`b}[]", "`a`b");
    try expectEval(vm, "{(::)x}[3]", "3");

    try expectSignal(vm, "{'`err}[]", "err");
    try expectSignal(vm, "{'\"msg\"}[]", "msg");
    try expectSignal(vm, "{'1}[]", "stype");
    try expectSignal(vm, "{'x}[`]", "");
    try expectSignal(vm, "'`boom", "boom");

    // The bytes q shows through `value`, minus its trailing stack-size byte.
    try expectEval(vm, "(value {$[x;1;2]})[0]", "97 6 6 0 13 5 3 0 160 0");
    try expectEval(vm, "(value {if[x;:1];2})[0]", "97 6 6 0 13 32 0 2 16 2 160 0");
    try expectEval(vm, "(value {:x})[0]", "97 32 0 0");
    try expectEval(vm, "(value {:x;y})[0]", "97 32 0 2 98 0");
    try expectEval(vm, "(value {while[x>0;x-:1];x})[0]", "12 97 74 6 11 0 13 11 4 1 2 2 9 13 0 16 2 97 0");
    try expectEval(vm, "(value {do[3;x+:1];x})[0]", "160 7 8 11 0 13 11 4 1 1 2 9 10 0 16 2 97 0");
    try expectEval(vm, "(value {'x})[0]", "97 1 0");
    try expectEval(vm, "(value {if[x;1;2]})[0]", "97 6 6 0 13 2 160 2 16 0");
}

test "compound and indexed assignment amend as q does" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "{x+:1;x}[1]", "2");
    try expectEval(vm, "{x-:1;x}[5]", "4");
    try expectEval(vm, "{x*:3;x}[2]", "6");
    try expectEval(vm, "{x*:2;x}[1 2 3]", "2 4 6");
    try expectEval(vm, "g:1 2 3;{g+:10}[];g", "11 12 13");
    try expectEval(vm, "(value {x+:1})[0]", "13 11 4 1 1 0");
    try expectEval(vm, "(value {a+:1})[3]", "``a");
    try expectEval(vm, "c:0;c+:1", "::");
    try expectEval(vm, "c", "1");
    try expectEval(vm, "c::9;c", "9");
    try expectEval(vm, "x:1 2 3;x[0]:5;x", "5 2 3");
    try expectEval(vm, "x[0]+:5;x", "10 2 3");
    try expectEval(vm, "x[0 1]:7;x", "7 7 3");
    try expectEval(vm, "m:(1 2;3 4);m[;1]:9;m", "(1 9;3 9)");

    try expectEval(vm, "{a:1 2 3;a[0]:9;a}[]", "9 2 3");
    try expectEval(vm, "{a:1 2 3;a[0]+:9;a}[]", "10 2 3");
    try expectEval(vm, "{a:1 2 3;a[0 1]:9;a}[]", "9 9 3");
    try expectEval(vm, "{a:1 2 3;a[0 1]:8 9;a}[]", "8 9 3");
    try expectEval(vm, "{a:(1 2;3 4);a[0;1]:9;a}[]", "(1 9;3 4)");
    try expectEval(vm, "{a:(1 2;3 4);a[;1]:9;a}[]", "(1 9;3 9)");
    try expectEval(vm, "{a:(1 2;3 4);a[0]:9;a}[]", "(9;3 4)");
    try expectEval(vm, "{a:(1;`s);a[0]:2.5;a}[]", "(2.5;`s)");
    try expectEval(vm, "g:1 2 3;{g[0]:7}[]", "::");
    try expectEval(vm, "g", "7 2 3");
    try expectEval(vm, "{g[1]+:10}[];g", "7 12 3");
    for ([_][:0]const u8{ "{a:1 2 3;a[0;1]:9;a}[]", "{a:1 2 3;a[0]:`s;a}[]", "{a:1 2 3;a[0]:1.5;a}[]", "{a:1 2 3;a[0]:1h;a}[]" }) |source| {
        try testing.expectError(error.type, vm.evalSource(source, .q, "<test>"));
    }
    for ([_][:0]const u8{ "{a:1 2 3;a[5]:9;a}[]", "{a:1 2 3;a[-1]:9;a}[]" }) |source| {
        try testing.expectError(error.length, vm.evalSource(source, .q, "<test>"));
    }
    try expectEval(vm, "(value {a[0]:1})[0]", "13 12 160 82 4 129 0 0");
    try expectEval(vm, "(value {a[0;1]:1})[0]", "13 13 12 160 10 2 4 129 0 0");
}

test "lambdas span indented continuation lines" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    // A line starting with whitespace continues the statement, as q reads scripts.
    try expectEval(vm, "{\n x+1} 2", "3");
    try expectEval(vm, "d:{[p]\n  q:p*2;\n\n  q+1}\nd 3", "7");
    try expectEval(vm, "g:{\n  / a comment\n  x*3}\ng 2", "6");
    try expectEval(vm, "e:{x\n\t+y}\ne[1;2]", "3");
    try expectEval(vm, "a:1\n +2\na", "3");
    // An unindented line ends the statement even inside a lambda, so this cannot parse.
    try testing.expectError(error.parse, vm.evalSource("b:{\nx+1}\nb 2", .q, "<test>"));
}

test "iterators follow q" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    // Parse trees: an iterator on a function is `(iterator;function)`.
    try expectEval(vm, "parse \"x f'y\"", "((';`f);`x;`y)");
    try expectEval(vm, "parse \"x+/y\"", "((/;+);`x;`y)");
    try expectEval(vm, "parse \"(+/)x\"", "((/;+);`x)");
    try expectEval(vm, "parse \"+/[s;x]\"", "((/;+);`s;`x)");
    try expectEval(vm, "parse \"k)#:'x\"", "((';#:);`x)");
    try expectEval(vm, "parse \"k)-1_'x\"", "((';_);-1;`x)");
    try expectEval(vm, "parse \"k)@\\\\:\\\\:\"", "(\\:;(\\:;@))");
    try expectEval(vm, "parse \"k)'/'\"", "(';(/;'))");
    try testing.expectError(error.parse, vm.evalSource("f'x", .q, "<test>"));

    // Bytecode: the function then the iterator instruction, minus q's trailing byte.
    try expectEval(vm, "(value {x+/y})[0]", "98 97 160 19 10 2 0");
    try expectEval(vm, "(value {f'[x;y]})[0]", "98 97 129 18 10 2 0");
    try expectEval(vm, "(value {(+/)x})[0]", "97 160 19 82 0");
    try expectEval(vm, "(value {f/[3;x]})[0]", "97 160 129 19 10 2 0");
    try expectEval(vm, "(value {x f/:y})[0]", "98 97 129 22 10 2 0");

    // Each.
    try expectEval(vm, "neg'[1 2 3]", "-1 -2 -3");
    try expectEval(vm, "{x*2}'[1 2 3]", "2 4 6");
    try expectEval(vm, "{x*2}'[5]", "10");
    try expectEval(vm, "{(x;y)}'[1 2;3 4]", "(1 3;2 4)");
    try expectEval(vm, "{(x;y)}'[1 2;3]", "(1 3;2 3)");
    try expectEval(vm, "{x+y}'[1 2 3;10 20 30]", "11 22 33");
    try expectEval(vm, "(::)'[1 2 3]", "1 2 3");
    try expectEval(vm, "{x}'[(1;`a;\"s\")]", "(1;`a;\"s\")");
    try expectEval(vm, "{x}'[()]", "()");
    try expectEval(vm, "{(x;y;z)}'[1 2;3 4;5 6]", "(1 3 5;2 4 6)");
    try expectEval(vm, "{x+y+z}'[1 2;3;4 5]", "8 10");
    try expectEval(vm, "1 2+''3 4", "4 6");
    try expectEval(vm, "{x*2}''[1 2 3]", "2 4 6");
    try expectEval(vm, "1 2 3 {x*y}' 10 20 30", "10 40 90");
    try expectEval(vm, "count each (1 2;3 4 5)", "2 3");
    try expectEvalMode(vm, .k, "#:'(1 2;3 4 5)", "2 3");
    try expectEvalMode(vm, .k, "1 2 3+'10 20 30", "11 22 33");
    try testing.expectError(error.length, vm.evalSource("{(x;y)}'[1 2;3 4 5]", .q, "<test>"));
    try testing.expectError(error.rank, vm.evalSource("{x}'[1 2;3 4;5 6]", .q, "<test>"));

    // Over and scan.
    try expectEval(vm, "+/[1 2 3]", "6");
    try expectEval(vm, "+/[1]", "1");
    try expectEval(vm, "+/[()]", "()");
    try expectEval(vm, "+/[`long$()]", "0");
    try expectEval(vm, "*/[`long$()]", "1");
    try expectEval(vm, "+/[`float$()]", "0f");
    try expectEval(vm, "+/[10;1 2 3]", "16");
    try expectEval(vm, "+/[10;()]", "10");
    try expectEval(vm, "+/[10;5]", "15");
    try expectEval(vm, "{x+y}/[1 2 3]", "6");
    try expectEval(vm, "{x+y}/[10;1 2 3]", "16");
    try expectEval(vm, "{x*2}/[3;1]", "8");
    try expectEval(vm, "{x*2}/[0;1]", "1");
    try expectEval(vm, "{x*2}/[-1;1]", "1");
    try expectEval(vm, "{x+1}/[0N;1]", "1");
    try expectEval(vm, "{x*2}/[2;1 2 3]", "4 8 12");
    try expectEval(vm, "{x*2}/[{x-128};1]", "128");
    try expectEval(vm, "+\\[1 2 3]", "1 3 6");
    try expectEval(vm, "+\\[10;1 2 3]", "11 13 16");
    try expectEval(vm, "{x*2}\\[3;1]", "1 2 4 8");
    try expectEval(vm, "{x*2}\\[0;1]", ",1");
    try expectEval(vm, "{x*2}\\[{x-128};1]", "1 2 4 8 16 32 64 128");
    try expectEval(vm, "{x+y}/[1 2 3;10 20 30]", "61 62 63");
    try expectEval(vm, "{x+y+z}/[1;1 2 3;10 20 30]", "67");
    try expectEval(vm, "{x+y+z}\\[1;1 2 3;10 20 30]", "12 34 67");
    try expectEval(vm, "+/[1 2 3;4 5 6]", "16 17 18");
    try expectEval(vm, "1 2 3+/4 5 6", "16 17 18");
    try expectEval(vm, "(+/)1 2 3", "6");
    try expectEval(vm, "+/[x:1 2 3]", "6");
    try expectEval(vm, "{x+y}\\[(1;2;3)]", "1 3 6");
    try expectEvalMode(vm, .k, "+/1 2 3", "6");
    try expectEvalMode(vm, .k, "+\\1 2 3", "1 3 6");
    try expectEvalMode(vm, .k, "10+/1 2 3", "16");
    try expectEval(vm, "{x+y} over 1 2 3", "6");
    try expectEval(vm, "{x+y} scan 1 2 3", "1 3 6");
    try testing.expectError(error.type, vm.evalSource("{x+1}/[3f;1]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("{x+1}/[3h;1]", .q, "<test>"));
    try testing.expectError(error.rank, vm.evalSource("+/[1 2 3;4 5 6;7 8 9]", .q, "<test>"));
    try testing.expectError(error.rank, vm.evalSource("(+/)[1;2;3]", .q, "<test>"));
    try testing.expectError(error.rank, vm.evalSource("{x*2}/[1;2;3]", .q, "<test>"));
    try testing.expectError(error.rank, vm.evalSource("{x+y+z}/[1;2;3;4]", .q, "<test>"));
    try expectEval(vm, "{x+y+z}/[1;2;3]", "6");
    try expectEval(vm, "{x*2}/[;2][3]", "16");
    try expectEval(vm, "(+/)[;1 2][10]", "13");
    try testing.expectError(error.rank, vm.evalSource("{x+y}/[1;2 3;4 5]", .q, "<test>"));

    // Each-prior, each-right and each-left.
    try expectEval(vm, "-':[1 3 6]", "1 2 3");
    try expectEval(vm, "-':[10;1 3 6]", "-9 2 3");
    try expectEval(vm, "+':[1 3 6]", "1 4 9");
    try expectEval(vm, "*':[1 3 6]", "1 3 18");
    try expectEval(vm, "%':[1 3 6]", "1 3 2f");
    try expectEval(vm, "-':[1.5 3]", "1.5 1.5");
    try expectEval(vm, "-':[1 3 6h]", "1 2 3i");
    try expectEval(vm, "-':[2023.01.02 2023.01.05]", "8402 3i");
    try expectEval(vm, "{x-y}':[1 3 6]", "0N 2 3");
    try expectEval(vm, "{(x;y)}':[1 3 6]", "(1 0N;3 1;6 3)");
    try expectEval(vm, "{(x;y)}':[`a`b]", "(`a`;`b`a)");
    try expectEval(vm, "-':[1]", "1");
    try expectEval(vm, "-':[()]", "()");
    try expectEval(vm, "{x+y}':[1;2 3]", "3 5");
    try expectEval(vm, "(-) prior 1 3 6", "1 2 3");
    try expectEvalMode(vm, .k, "-':1 3 6", "1 2 3");
    try expectEval(vm, "{(x;y)}/:[1 2;3 4]", "((1 2;3);(1 2;4))");
    try expectEval(vm, "{(x;y)}\\:[1 2;3 4]", "((1;3 4);(2;3 4))");
    try expectEval(vm, "1 2+/:3 4", "(4 5;5 6)");
    try expectEval(vm, "1 2+\\:3 4", "(4 5;5 6)");
    try testing.expectError(error.type, vm.evalSource("{x}/:[1 2 3]", .q, "<test>"));
    try expectEval(vm, "{x+y}/:[1 2 3]", "{x+y}/:[1 2 3]");

    // Derived functions are values.
    try expectEval(vm, "-3!(+/)", "\"+/\"");
    try expectEval(vm, "-3!+/", "![-3]+/");
    try expectEval(vm, "-3!({x}')", "\"{x}'\"");
    try expectEval(vm, "'[+]", "+'");
    try expectEvalMode(vm, .k, "{x/y}[+;1 2 3]", "6");
    try testing.expectError(error.parse, vm.evalSource("{x/y}", .q, "<test>"));
    try expectEval(vm, "f:{x+y};g:{f/[x]};g 1 2 3", "6");
}

test "compositions follow q" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    // A verb applied to a function form composes, whatever the left side; an identifier
    // or a parenthesised expression on the right is applied to.
    try expectEval(vm, "parse \"k)-_-:\"", "(';-:;(';_:;-:))");
    try expectEval(vm, "parse \"type 1+\"", "(';@:;(+;1))");
    try expectEval(vm, "parse \"type(1+)\"", "(@:;(+;1))");
    try expectEval(vm, "parse \"neg 1+\"", "(';-:;(+;1))");
    try expectEval(vm, "parse \"f 1+\"", "(';`f;(+;1))");
    try expectEval(vm, "parse \"k)\\\"s\\\"$-1!'\"", "(';($;\"s\");((';!);-1))");
    try expectEval(vm, "parse \"k)64/:b6?\"", "(';(/:;64);(?;`b6))");
    try expectEval(vm, "parse \"k)+/-:\"", "(';(/;+);-:)");
    try expectEval(vm, "parse \"k)#:-:\"", "(';#:;-:)");
    try expectEval(vm, "parse \"k)-f\"", "(-:;`f)");
    try expectEval(vm, "parse \"k)-(_:)\"", "(-:;_:)");
    try expectEval(vm, "parse \"k)-_-:x\"", "(-:;(_:;(-:;`x)))");
    try expectEval(vm, "parse \"k)(-_-:)x\"", "((';-:;(';_:;-:));`x)");
    try expectEval(vm, "parse \"k)-'\"", "(';-)");

    try expectEvalMode(vm, .k, "(-_-:) -1.5", "-1");
    try expectEvalMode(vm, .k, "f:-_-:;f -1.5", "-1");
    try expectEvalMode(vm, .k, "-3!f", "\"-_-:\"");
    try expectEvalMode(vm, .k, "@f", "105h");
    try expectEvalMode(vm, .k, "@1+", "@+[1]");
    try expectEvalMode(vm, .k, "@(1+)", "104h");
    try expectEval(vm, "type 1+", "@+[1]");
    try expectEval(vm, "type(1+)", "104h");
    try expectEval(vm, "neg 1+", "-+[1]");
    try expectEval(vm, "(neg 1+) 5", "-6");
    try expectEval(vm, "'[neg;+][1;2]", "-3");
    try expectEval(vm, "'[neg;neg] 2", "2");
    try expectEval(vm, "'[neg;1]", "-1");
    try expectEvalMode(vm, .k, "'[-:;_:] -1.5", "2");
    try expectEvalMode(vm, .k, "(')[-:;_:]", "-_:");
    try expectEvalMode(vm, .k, "('['[-:;_:];-:]) -1.5", "-1");
    try expectEvalMode(vm, .k, "'[-:;{x*2}] 3", "-6");
    try expectEvalMode(vm, .k, "(-+)[1;2]", "-3");
    try expectEvalMode(vm, .k, "(-+)[1]", "-+[1]");
    try expectEvalMode(vm, .k, "(-+/) 1 2 3", "-6");
    try expectEvalMode(vm, .k, "-3!(-+/)", "\"-+/\"");
    try expectEvalMode(vm, .k, "-3!-+/", "![-3]-+/");
    try expectEvalMode(vm, .k, "(+/-:) 1 2 3", "-6");
    try expectEvalMode(vm, .k, "-3!(+/-:)", "\"+/-:\"");
    try expectEvalMode(vm, .k, "(-#:') 1 2 3", "-1 -1 -1");
    try expectEvalMode(vm, .k, "(-#:) 1 2 3", "-3");
    try expectEvalMode(vm, .k, "-3!(#:-:)", "\"#-:\"");
    try expectEvalMode(vm, .k, "(#:-:) 1 2 3", "3");
    try expectEval(vm, "(value {'[neg;neg]})[0]", "160 160 161 10 2 0");
    try expectEval(vm, "(value {1+-:})[0]", "160 13 161 82 162 10 2 0");
    try expectEvalMode(vm, .k, "{1+-:}[] 5", "-4");
    try expectEval(vm, "parse \"k)1+2+\"", "(';(+;1);(+;2))");
    try expectEval(vm, "parse \"k)(1+)-:\"", "(-:;(+;1))");
    try testing.expectError(error.type, vm.evalSource("g:-{x*2};g 3", .k, "<test>"));
    try testing.expectError(error.type, vm.evalSource("f:{x*2};g:-f;g 3", .k, "<test>"));
    try testing.expectError(error.rank, vm.evalSource("'[-:;_:;+]", .k, "<test>"));
    try testing.expectError(error.rank, vm.evalSource("(-_-:)[1;2]", .k, "<test>"));
    // Inside a lambda the composition syntax works as at the top level.
    try expectEvalMode(vm, .k, "{-_-:}[] -1.5", "-1");
    try expectEvalMode(vm, .k, "{(-_-:) x} -1.5", "-1");
    try expectEvalMode(vm, .k, "{f:-_-:;f x} -1.5", "-1");
    try expectEvalMode(vm, .k, "{@1+}[]", "@+[1]");
    try expectEvalMode(vm, .k, "-3!{-_-:}[]", "\"-_-:\"");
}

test "floor and lower share the underscore primitive" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "floor 1.5", "1");
    try expectEval(vm, "floor -1.5", "-2");
    try expectEval(vm, "floor 1.5 2.7", "1 2");
    try expectEval(vm, "floor 1.5e", "1");
    try expectEval(vm, "floor -1.5e", "-2");
    try expectEval(vm, "type floor 1.5e", "-7h");
    try expectEval(vm, "floor 0n", "0N");
    try expectEval(vm, "floor 0w", "0W");
    try expectEval(vm, "floor -0w", "0N");
    try expectEval(vm, "floor 2.5 0n", "2 0N");
    try expectEval(vm, "floor 9.9e18", "0W");
    try expectEval(vm, "floor 1e18", "1000000000000000000");
    try expectEval(vm, "floor 1", "1");
    try expectEval(vm, "floor 1h", "1h");
    try expectEval(vm, "lower \"ABC\"", "\"abc\"");
    try expectEval(vm, "lower \"A\"", "\"a\"");
    try expectEval(vm, "lower `ABC`Def", "`abc`def");
    try expectEval(vm, "floor (1.5;\"A\")", "(1;\"a\")");
    try expectEvalMode(vm, .k, "_ 1.5", "1");
    try testing.expectError(error.type, vm.evalSource("floor 2023.04.17", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("floor 1b", .q, "<test>"));
}

test "projections of internals and glyphs, amend and trap forms of dot and at" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    // Internals and glyphs as values.
    try expectEvalMode(vm, .k, "md5:-15!;-3!md5", "\"![-15]\"");
    try expectEval(vm, "-3!(-15!)", "\"![-15]\"");
    try expectEvalMode(vm, .k, "@(-15!)", "104h");
    try expectEval(vm, "-3!$", "![-3]$");
    try expectEvalMode(vm, .k, "-3!.[;();,;]", "\".[;();,;]\"");
    try expectEvalMode(vm, .k, "@.[;();,;]", "104h");
    try expectEvalMode(vm, .k, "f:.[;();+;];f[1 2;3]", "4 5");
    try expectEvalMode(vm, .k, "g:.[;();:;];g[`gz;5];gz", "5");
    try expectEvalMode(vm, .k, "-3!@[;;:;]", "\"@[;;:;]\"");
    try expectEvalMode(vm, .k, "@[;;:;][1 2 3;0;9]", "9 2 3");
    try expectEvalMode(vm, .k, "-3!(?).", "![-3].[?]");

    // `:` applied as a function returns its right argument, so `prev` is `:':`.
    try expectEvalMode(vm, .k, "prev:(:':);prev 1 2 3", "0N 1 2");
    try expectEvalMode(vm, .k, "(:;^)[0][1;2]", "2");
    try expectEvalMode(vm, .k, "(:;^)[1] 5", "^[5]");
    try expectEvalMode(vm, .k, "a0:(#:;*:;last;sum);a0[0] 1 2 3", "3");
    try expectEvalMode(vm, .k, "a0[1] 1 2 3", "1");
    try expectEvalMode(vm, .k, "-3!a0", "\"(#:;*:;last;sum)\"");

    // Traps.
    try expectEval(vm, ".[+;1 2]", "3");
    try expectEval(vm, ".[+;1 2;{x}]", "3");
    try expectEval(vm, ".[{'\"boom\"};1 2;{x}]", "\"rank\"");
    try expectEval(vm, ".[+;1 2 3;{x}]", "\"rank\"");
    try expectEval(vm, "@[+;1;{x}]", "+[1]");
    try expectEval(vm, "@[{'\"boom\"};1;{x}]", "\"boom\"");
    try expectEval(vm, "@[{'`sym};1;{x}]", "\"sym\"");
    try expectEval(vm, "@[{1+`a};1;{x}]", "\"type\"");
    try expectEval(vm, "@[{x+y};1;{x}]", "{x+y}[1]");
    try expectEval(vm, "@[{x};1;`fallback]", "1");
    try expectEval(vm, ".[{x+y};1 2 3;`fallback]", "`fallback");
    try expectEval(vm, "@[value;\"1+2\";{x}]", "3");
    try expectEval(vm, "@[+;1][2]", "3");
    try expectEval(vm, ".[+;;{x}][1 2]", "3");

    // Amends.
    try expectEval(vm, "@[1 2 3;0;:;9]", "9 2 3");
    try expectEval(vm, "@[1 2 3;0;+;9]", "10 2 3");
    try expectEval(vm, "@[1 2 3;0 1;+;9]", "10 11 3");
    try expectEval(vm, "@[1 2 3;0;neg]", "-1 2 3");
    try expectEval(vm, "@[1 2 3;0 1;neg]", "-1 -2 3");
    try expectEval(vm, ".[(1 2;3 4);0 1;:;9]", "(1 9;3 4)");
    try expectEval(vm, ".[(1 2;3 4);0 1;+;9]", "(1 11;3 4)");
    try expectEval(vm, ".[1 2 3;enlist 0;neg]", "-1 2 3");
    try expectEval(vm, ".[1 2 3;();+;1]", "2 3 4");
    try expectEval(vm, ".[1 2 3;();:;9]", "9");
    try expectEval(vm, ".[(1 2;3 4);(0;1);:;9]", "(1 9;3 4)");
    try expectEval(vm, ".[(1 2;3 4);(::;1);:;9]", "(1 9;3 9)");
    try expectEval(vm, ".[`b;();:;7]", "`b");
    try expectEval(vm, "b", "7");
    try expectEval(vm, ".[`b;();+;1]", "`b");
    try expectEval(vm, "b", "8");
    try testing.expectError(error.length, vm.evalSource("@[1 2 3;5;:;9]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("@[`b;1;:;9]", .q, "<test>"));
    try testing.expectError(error.rank, vm.evalSource("@[+;1;{x};2]", .q, "<test>"));
    try testing.expectError(error.rank, vm.evalSource("+[1;2;3]", .q, "<test>"));
}

test "review fixes: precedence, k newlines, scans, equality, stubs and long lists" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    // A bracketed verb after a noun is applied to, as q parses it.
    try expectEval(vm, "parse \"x+[1;2]\"", "(`x;(+;1;2))");
    try expectEval(vm, "parse \"x $[1;2;3]\"", "(`x;($;1;2;3))");
    try expectEval(vm, "parse \"f +/[1 2]\"", "(`f;((/;+);1 2))");
    try expectEval(vm, "parse \"x -[1]\"", "(`x;(-;1))");
    try expectEval(vm, "parse \"k)x -1\"", "(`x;-1)");
    try expectEval(vm, "parse \"k)x - 1\"", "(-;`x;1)");
    try expectEval(vm, "1 2 3 $[1;0;2]", "1");

    // An assignment inside a bracketed cond used after a name compiles (the scan pass
    // walks the operator node), and compositions compile inside lambdas.
    try expectEvalMode(vm, .k, "{n:1;n+.z.s$[p:x;n;p]}", "k){n:1;n+.z.s$[p:x;n;p]}");
    try expectEvalMode(vm, .k, "{$[1;2;f $[p:1;2;3]]}[]", "2");
    try expectEvalMode(vm, .k, "{(!#:)'x}(1 2;3 4 5)", "(0 1;0 1 2)");

    // k mode: an indented newline inside brackets is `;`, an indented line at the top
    // level is a new statement; q mode joins indented lines.
    try expectEvalMode(vm, .k, "{1\n 2}[]", "2");
    try expectEvalMode(vm, .k, "(1\n 2)", "1 2");
    try expectEvalMode(vm, .k, "(\"a b\";\"c d\"\n \"e f\";\"g h\")", "(\"a b\";\"c d\";\"e f\";\"g h\")");
    try expectEvalMode(vm, .k, "a:1\n 2\na", "1");
    try testing.expectError(error.rank, vm.evalSource("f:{x};f[1\n 2]", .k, "<test>"));
    try expectEval(vm, "{1\n 2}[]", "1 2");
    try expectEval(vm, "(1\n +2)", "3");

    // Lists of different lengths are not equal (the compiler compares constants).
    try expectEvalMode(vm, .k, "{((1;`a);(1;`a;2))}[]", "((1;`a);(1;`a;2))");
    try expectEval(vm, "(1;`a)~(1;`a;2)", "0b");

    // Stubs fail with nyi instead of crashing.
    try testing.expectError(error.nyi, vm.evalSource("flip 1 2!(3 4;5 6)", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("1 2 3 like \"a\"", .q, "<test>"));

    // A long list literal that fails part way is cleaned up (it used to move the stack).
    try testing.expectError(error.type, vm.evalSource("(\"a\";\"b\";\"c\";\"d\";\"e\";\"f\";\"g\";\"h\";\"i\";\"j\";\"k\";\"l\";\"m\";\"n\";\"o\";\"p\";\"q\";\"r\";\"s\";\"t\";\"u\";\"v\" \"w\";\"x\")", .q, "<test>"));
}

test "keywords bound to derived functions parse as q parses them" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEvalMode(vm, .k, ".q.prev: :':", "::");
    try expectEvalMode(vm, .k, ".q.sums:+\\", "::");
    try expectEvalMode(vm, .k, ".q.deltas:-':", "::");
    try expectEvalMode(vm, .k, ".q.f7:{x+y}'", "::");
    try expectEval(vm, "prev til 10", "0N 0 1 2 3 4 5 6 7 8");
    try expectEval(vm, "prev prev til 10", "0N 0N 0 1 2 3 4 5 6 7");
    try expectEval(vm, "parse \"prev prev 3\"", "(:':;(:':;3))");
    try expectEval(vm, "parse \"1 sums 2\"", "(1;(+\\;2))");
    try expectEval(vm, "parse \"sums sums 1 2\"", "(+\\;(+\\;1 2))");
    try expectEval(vm, "parse \"1 deltas 2\"", "(1;(-':;2))");
    try expectEval(vm, "parse \"1 mmu 2\"", "($;1;2)");
    try expectEval(vm, "parse \"1 f7 2\"", "(k){x+y}';1;2)");
    try expectEval(vm, "sums 1 2 3", "1 3 6");
    try expectEval(vm, "deltas 1 3 6", "1 2 3");
    try expectEval(vm, "1 2 f7 3 4", "4 6");
    try expectEval(vm, "prev 0N 0 1", "0N 0N 0");
}

test "join follows q" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "1,2", "1 2");
    try expectEval(vm, "1,2 3", "1 2 3");
    try expectEval(vm, "1 2,3", "1 2 3");
    try expectEval(vm, "1 2,3 4", "1 2 3 4");
    try expectEval(vm, "1,2h", "(1;2h)");
    try expectEval(vm, "1 2,3h", "(1;2;3h)");
    try expectEval(vm, "1,2.5", "(1;2.5)");
    try expectEval(vm, "1,`a", "(1;`a)");
    try expectEval(vm, "`a,`b", "`a`b");
    try expectEval(vm, "`a`b,`c", "`a`b`c");
    try expectEval(vm, "\"a\",\"b\"", "\"ab\"");
    try expectEval(vm, "\"ab\",\"cd\"", "\"abcd\"");
    try expectEval(vm, "\"a\",1", "(\"a\";1)");
    try expectEval(vm, "\"ab\",1", "(\"a\";\"b\";1)");
    try expectEval(vm, "1b,0b", "10b");
    try expectEval(vm, "1b,1", "(1b;1)");
    try expectEval(vm, "0x01,0x02", "0x0102");
    try expectEval(vm, "(1 2;3),4", "(1 2;3;4)");
    try expectEval(vm, "(1 2;3 4),(5 6;7 8)", "(1 2;3 4;5 6;7 8)");
    try expectEval(vm, "2023.01.01,2023.01.02", "2023.01.01 2023.01.02");
    try expectEval(vm, "2023.01.01,1", "(2023.01.01;1)");
    try expectEval(vm, "12:00,13:00", "12:00 13:00");
    try expectEval(vm, "1 2,0N", "1 2 0N");
    try expectEval(vm, "type 1,2h", "0h");
    try expectEval(vm, "(neg;abs),neg", "(-:;abs;-:)");
    try expectEval(vm, ",[1;2]", "1 2");
    try expectEval(vm, "(,)[1;2]", "1 2");

    // Empty lists.
    try expectEval(vm, "1,()", ",1");
    try expectEval(vm, "(),1", ",1");
    try expectEval(vm, "(),()", "()");
    try expectEval(vm, "1 2,()", "1 2");
    try expectEval(vm, "(),1 2", "1 2");
    try expectEval(vm, "\"\",1", ",1");
    try expectEval(vm, "\"\",`a", ",`a");
    try expectEval(vm, "\"\",\"a\"", ",\"a\"");
    try expectEval(vm, "\"\",\"ab\"", "\"ab\"");
    try expectEval(vm, "\"\",`long$()", "`long$()");
    try expectEval(vm, "1.5,`long$()", ",1.5");
    try expectEval(vm, "1 2,`symbol$()", "1 2");
    try expectEval(vm, "`long$(),1", ",1");
    try expectEval(vm, "`long$(),1.5", ",2");
    try expectEval(vm, "`long$(),\"a\"", ",97");
    try expectEval(vm, "`long$(),1h", ",1");
    try expectEval(vm, "`float$(),1", ",1f");
    try expectEval(vm, "`float$(),1 2", "1 2f");
    try expectEval(vm, "`long$(),\"\"", "`long$()");
    try expectEval(vm, "(0#`),`a", ",`a");
    try expectEval(vm, "(0#0x00),1", ",1");
    try testing.expectError(error.type, vm.evalSource("`long$(),`a", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("`symbol$(),1", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("`float$(),`a`b", .q, "<test>"));

    // Dictionaries merge; a dictionary joined with anything else is a type error.
    try expectEval(vm, "(`a`b!1 2),(`c`d!3 4)", "`a`b`c`d!1 2 3 4");
    try expectEval(vm, "(`a`b!1 2),(`b`c!3 4)", "`a`b`c!1 3 4");
    try testing.expectError(error.type, vm.evalSource("(`a`b!1 2),`c", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("1 2,`a`b!1 2", .q, "<test>"));

    // Through iterators, compound assignment and the amend forms.
    try expectEval(vm, "\"ab\",'\"cd\"", "(\"ac\";\"bd\")");
    try expectEval(vm, "(1 2;3 4),'(5 6;7 8)", "(1 2 5 6;3 4 7 8)");
    try expectEval(vm, "(,/)(1 2;3;(4;`a))", "(1;2;3;4;`a)");
    try expectEval(vm, "1,/(2;3;4)", "1 2 3 4");
    try expectEval(vm, "x:1 2;x,:3;x", "1 2 3");
    try expectEval(vm, "y:();y,:1;y", ",1");
    try expectEval(vm, "z:\"\";z,:\"a\";z", ",\"a\"");
    try expectEval(vm, "u:.[;();,;];u[1 2;3]", "1 2 3");
}

test "comparisons, match, min, max, in and the aggregates follow q" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "1=1", "1b");
    try expectEval(vm, "1=1.0", "1b");
    try expectEval(vm, "1=1h", "1b");
    try expectEval(vm, "1<2", "1b");
    try expectEval(vm, "1 2 3=2", "010b");
    try expectEval(vm, "1 2 3<2", "100b");
    try expectEval(vm, "2<1 2 3", "001b");
    try expectEval(vm, "1 2=1 2", "11b");
    try expectEval(vm, "`a=`b", "0b");
    try expectEval(vm, "`a<`b", "1b");
    try expectEval(vm, "\"ab\"=\"ba\"", "00b");
    try expectEval(vm, "\"a\"=97", "1b");
    try expectEval(vm, "1b=1", "1b");
    try expectEval(vm, "1b<1", "0b");
    try expectEval(vm, "0x01<0x02", "1b");
    try expectEval(vm, "2023.01.01<2023.01.02", "1b");
    try expectEval(vm, "2023.01.01=8401", "1b");
    try expectEval(vm, "0N=0N", "1b");
    try expectEval(vm, "0N=0n", "1b");
    try expectEval(vm, "0N<1", "1b");
    try expectEval(vm, "1<0N", "0b");
    try expectEval(vm, "1=0n", "0b");
    try expectEval(vm, "1=1+1e-13", "1b");
    try expectEval(vm, "1=1+1e-12", "0b");
    try expectEval(vm, "(1;`a)=(1;`b)", "10b");
    try expectEval(vm, "`a=`a`b", "10b");
    try expectEval(vm, "1 2h=1 2", "11b");
    try expectEval(vm, "\"ab\"<\"b\"", "10b");
    try testing.expectError(error.length, vm.evalSource("1 2=1 2 3", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("`a=1", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("1 2=(1;`a)", .q, "<test>"));

    try expectEval(vm, "1~1", "1b");
    try expectEval(vm, "1~1f", "0b");
    try expectEval(vm, "1 2~1 2", "1b");
    try expectEval(vm, "(1;`a)~(1;`a)", "1b");
    try expectEval(vm, "\"\"~()", "0b");
    try expectEval(vm, "()~()", "1b");
    try expectEval(vm, "0n~0n", "1b");
    try expectEval(vm, "{x}~{x}", "1b");
    try expectEval(vm, "1.0~1.0+1e-13", "1b");
    try expectEval(vm, "1.0~1.0+1e-12", "0b");
    try expectEval(vm, "1~1 2", "0b");
    try expectEval(vm, "(`a`b!1 2)~`a`b!1 2", "1b");
    // The keyword must exist before the line using it is parsed, in q as well.
    try expectEval(vm, ".q.f:{x+y}", "::");
    try expectEval(vm, "3~1 f 2", "1b");

    try expectEval(vm, "1&2", "1");
    try expectEval(vm, "1|2", "2");
    try expectEval(vm, "1 2&2 1", "1 1");
    try expectEval(vm, "0N&1", "0N");
    try expectEval(vm, "0N|1", "1");
    try expectEval(vm, "1b&0b", "0b");
    try expectEval(vm, "1.5&2", "1.5");
    try expectEval(vm, "1&2.5", "1f");
    try expectEval(vm, "0n|1", "1f");
    try expectEval(vm, "\"a\"&\"b\"", "\"a\"");
    try expectEval(vm, "2023.01.01&2023.01.02", "2023.01.01");
    try testing.expectError(error.type, vm.evalSource("`a&`b", .q, "<test>"));

    try expectEval(vm, "1 2 3 in 2 4", "010b");
    try expectEval(vm, "2 in 1 2 3", "1b");
    try expectEval(vm, "(1;`a) in (1;`b;`a)", "11b");
    try expectEval(vm, "`a in `a`b", "1b");
    try expectEval(vm, "\"a\" in \"abc\"", "1b");
    try expectEval(vm, "\"ab\" in (\"ab\";\"cd\")", "1b");
    try expectEval(vm, "1 2 in 1", "10b");
    try testing.expectError(error.type, vm.evalSource("1.0 in 1 2", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("1h in 1 2", .q, "<test>"));

    try expectEval(vm, "sum 1 2 3", "6");
    try expectEval(vm, "sum 1 2 3h", "6i");
    try expectEval(vm, "sum 1 2 3f", "6f");
    try expectEval(vm, "sum 1 2 3e", "6e");
    try expectEval(vm, "sum 101b", "2i");
    try expectEval(vm, "sum \"ab\"", "195i");
    try expectEval(vm, "sum 1 0N 3", "4");
    try expectEval(vm, "sum ()", "()");
    try expectEval(vm, "sum `long$()", "0");
    try expectEval(vm, "sum `float$()", "0f");
    try expectEval(vm, "sum 5", "5");
    try expectEval(vm, "sum 0x01", "0x01");
    try expectEval(vm, "sum (1 2;3 4)", "4 6");
    try expectEval(vm, "sum 12:00 13:00", "25:00");
    try expectEval(vm, "sum 2023.01.01 2023.01.02", "2046.01.02");
    try expectEval(vm, "sum 0x0102", "3i");
    try expectEval(vm, "sum `byte$()", "0i");
    try expectEval(vm, "sum `date$()", "2000.01.01");
    try expectEval(vm, "prd 1 2 3", "6");
    try expectEval(vm, "prd 1 0N 3", "3");
    try expectEval(vm, "prd 2 3.5", "7f");
    try expectEval(vm, "prd 0x0102", "2i");
    try expectEval(vm, "prd 101b", "0i");
    try testing.expectError(error.type, vm.evalSource("prd \"ab\"", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("prd 2023.01.01 2023.01.02", .q, "<test>"));
    try expectEval(vm, "min 0x0201", "0x01");
    try expectEval(vm, "min `byte$()", "0xff");
    try expectEval(vm, "max `byte$()", "0x00");
    try expectEval(vm, "min \"\"", "\"\\377\"");
    try expectEval(vm, "max \"\"", "\"\\000\"");
    try expectEval(vm, "min `date$()", "0Wd");
    try expectEval(vm, "max `date$()", "-0Wd");
    try expectEval(vm, "avg 0x0102", "1.5");
    try expectEval(vm, "avg \"ab\"", "97.5");
    try expectEval(vm, "avg 2000.01.01 2000.01.03", "1f");
    try expectEval(vm, "avg 11b", "1f");
    // A symbol applies as the global it names.
    try expectEval(vm, "a:1 2 3;`a 1", "2");
    try expectEval(vm, "`a[1 2]", "2 3");
    try expectEval(vm, "`a[]", "1 2 3");
    try expectEval(vm, "g9:{x+1};`g9 2", "3");
    try expectEval(vm, "b:(1 2;3 4);`b[1;0]", "3");
    try expectEval(vm, "`a`b 1", "`b");
    try testing.expectError(error.identifier, vm.evalSource("`nope 1", .q, "<test>"));
    // Chars above 127 display as octal escapes.
    try expectEval(vm, "\"c\"$200 65", "\"\\310A\"");
    try expectEval(vm, "\"c\"$127", "\"\\177\"");
}

test "dictionary indexing follows q" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();
    try expectEval(vm, "(`a`b!1 2)`a", "1");
    try expectEval(vm, "(`a`b!1 2)`c", "0N");
    try expectEval(vm, "(`a`b!1 2)`", "0N");
    try expectEval(vm, "(`a`b!1 2)`a`c", "1 0N");
    try expectEval(vm, "(`a`b!1 2)[(`a;`c)]", "1 0N");
    try expectEval(vm, "(`a`b!1 2)(`a`b;`b)", "(1 2;2)");
    try expectEval(vm, "(`a`b!(1 2;3))`a`b`c", "(1 2;3;`long$())");
    try expectEval(vm, "(`a`b!(1;`x))`c", "0N");
    try expectEval(vm, "(`a`b!(`x;1))`c", "`");
    try expectEval(vm, "(`a`b!(#:;*:))`c", "::");
    try expectEval(vm, "(`a`b!\"xy\")`c", "\" \"");
    try expectEval(vm, "(`a`b!2000.01.01 2000.01.02)`c", "0Nd");
    try expectEval(vm, "(1 2!3 4) 2", "4");
    try expectEval(vm, "(1 2!3 4) 5", "0N");
    try expectEval(vm, "(1 2!3 4) 0N", "0N");
    try expectEval(vm, "(0N 2!3 4) 0N", "3");
    try expectEval(vm, "(1.5 2!3 4) 2f", "4");
    try expectEval(vm, "((1;`a)!3 4)`a", "4");
    try expectEval(vm, "((1;`a)!3 4) 2", "0N");
    try expectEval(vm, "((1;`a)!3 4)(1;`a)", "3 4");
    try testing.expectError(error.type, vm.evalSource("(1 2!3 4) 2h", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("(1 2!3 4) 2f", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("(1 2!3 4) `a", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("(`a`b!1 2)[0 1]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("(1.5 2!3 4) 2", .q, "<test>"));
    try expectEval(vm, "(`a`b!1 2)[]", "`a`b!1 2");
    try expectEval(vm, "(`a`b!1 2)[::]", "`a`b!1 2");
    try expectEval(vm, "(`a`b!(1 2;3 4))[;1]", "`a`b!2 4");
    try expectEval(vm, "(`a`b!(1 2;3 4))[`a;1]", "2");
    try expectEval(vm, "(`a`b!(1 2;3 4))[`a`b;1]", "2 4");
    try expectEval(vm, "(`a`b!(1 2;3 4))[`a`b;0 1]", "(1 2;3 4)");
    try expectEval(vm, "(`a`b!(1 2;3 4))[`a;]", "1 2");
    try testing.expectError(error.type, vm.evalSource("(`a`b!(1 2;3 4))[`a;`b]", .q, "<test>"));
    try expectEval(vm, "`.q[`count;0]", "1");
    try expectEval(vm, "`.q `count`first", "(#:;*:)");
    try expectEval(vm, "min 3 1 2", "1");
    try expectEval(vm, "min 3 1 2f", "1f");
    try expectEval(vm, "min 0N 1", "1");
    try expectEval(vm, "min `long$()", "0W");
    try expectEval(vm, "max `long$()", "-0W");
    try expectEval(vm, "min 1 2 3h", "1h");
    try expectEval(vm, "min \"ba\"", "\"a\"");
    try expectEval(vm, "max 101b", "1b");
    try expectEval(vm, "max 2023.01.01 2023.01.02", "2023.01.02");
    try expectEval(vm, "max 3 1 2", "3");
    try expectEval(vm, "avg 1 2 3", "2f");
    try expectEval(vm, "avg 1 2", "1.5");
    try expectEval(vm, "avg 1 0N 3", "2f");
    try expectEval(vm, "avg ()", "0n");
    try expectEval(vm, "avg `long$()", "0n");
    try expectEval(vm, "avg 5", "5f");
    try expectEval(vm, "avg 101b", "0.6666667");
    try expectEval(vm, "avg (1 2;3 4)", "2 3f");
    try expectEval(vm, "last 1 2 3", "3");
    try expectEval(vm, "last `long$()", "0N");
    try expectEval(vm, "last 5", "5");
    try expectEval(vm, "type sum 1 2h", "-6h");
    try expectEval(vm, "type max 1 2h", "-5h");
    try testing.expectError(error.type, vm.evalSource("sum `a`b", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("sum 0x01 0x02", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("max 0x01 0x02", .q, "<test>"));
}

test "string, not, null, where, reverse and reciprocal follow q" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "string `a", ",\"a\"");
    try expectEval(vm, "string `a`b", "(,\"a\";,\"b\")");
    try expectEval(vm, "string `", "\"\"");
    try expectEval(vm, "string 1", ",\"1\"");
    try expectEval(vm, "string 1 2", "(,\"1\";,\"2\")");
    try expectEval(vm, "string 1.5", "\"1.5\"");
    try expectEval(vm, "string 1.0", ",\"1\"");
    try expectEval(vm, "string 1e", ",\"1\"");
    try expectEval(vm, "string 1h", ",\"1\"");
    try expectEval(vm, "string 1i", ",\"1\"");
    try expectEval(vm, "string 1b", ",\"1\"");
    try expectEval(vm, "string 101b", "(,\"1\";,\"0\";,\"1\")");
    try expectEval(vm, "string 0x01", "\"01\"");
    try expectEval(vm, "string 0x0102", "(\"01\";\"02\")");
    try expectEval(vm, "string \"a\"", ",\"a\"");
    try expectEval(vm, "string \"ab\"", "(,\"a\";,\"b\")");
    try expectEval(vm, "string \"\"", "()");
    try expectEval(vm, "string 2023.01.01", "\"2023.01.01\"");
    try expectEval(vm, "string 2023.01m", "\"2023.01\"");
    try expectEval(vm, "string 12:00", "\"12:00\"");
    try expectEval(vm, "string 12:00:00.123", "\"12:00:00.123\"");
    try expectEval(vm, "string 0D12", "\"0D12:00:00.000000000\"");
    try expectEval(vm, "string 2023.01.01D12", "\"2023.01.01D12:00:00.000000000\"");
    try expectEval(vm, "string 2023.01.01T12", "\"2023.01.01T12:00:00.000\"");
    try expectEval(vm, "string 0N", "\"\"");
    try expectEval(vm, "string 0n", "\"\"");
    try expectEval(vm, "string 0Nh", "\"\"");
    try expectEval(vm, "string 0Nd", "\"\"");
    try expectEval(vm, "string 0W", "\"0W\"");
    try expectEval(vm, "string -0W", "\"-0W\"");
    try expectEval(vm, "string 0w", "\"0w\"");
    try expectEval(vm, "string -0w", "\"-0w\"");
    try expectEval(vm, "string 0Wd", "\"0W\"");
    try expectEval(vm, "string 0We", "\"0w\"");
    try expectEval(vm, "string -0Wz", "\"-0w\"");
    try expectEval(vm, "string ()", "()");
    try expectEval(vm, "string (1;`a;\"ab\")", "(,\"1\";,\"a\";(,\"a\";,\"b\"))");
    try expectEval(vm, "string (1 2;3)", "((,\"1\";,\"2\");,\"3\")");
    try expectEval(vm, "string {x+y}", "\"{x+y}\"");
    try expectEval(vm, "string (+)", ",\"+\"");
    try expectEval(vm, "string (-:)", "\"-:\"");
    try expectEval(vm, "string (+/)", "\"+/\"");
    try expectEval(vm, "string (1+)", "\"+[1]\"");
    try expectEval(vm, "string (::)", "\"::\"");
    try expectEval(vm, "string `a`b!1 2", "`a`b!(,\"1\";,\"2\")");
    try expectEval(vm, "string 1.5 2", "(\"1.5\";,\"2\")");
    try expectEval(vm, "string 1 0N 2", "(,\"1\";\"\";,\"2\")");
    try expectEval(vm, "string 1e10", "\"1e+10\"");
    try expectEval(vm, "string 123456789.123", "\"1.234568e+08\"");
    try expectEval(vm, "string 0.1+0.2", "\"0.3\"");
    try expectEval(vm, "string -1.5", "\"-1.5\"");
    try expectEval(vm, "string 100000000000000000", "\"100000000000000000\"");
    try expectEval(vm, "string 1 0W -0W 0N", "(,\"1\";\"0W\";\"-0W\";\"\")");
    try expectEval(vm, "string 2023.01.01 0Nd", "(\"2023.01.01\";\"\")");
    try expectEval(vm, "type string 1 2", "0h");
    try expectEval(vm, "type string \"\"", "0h");

    try expectEval(vm, "not 1", "0b");
    try expectEval(vm, "not 0", "1b");
    try expectEval(vm, "not 1 2 0", "001b");
    try expectEval(vm, "not 1.5", "0b");
    try expectEval(vm, "not 0n", "0b");
    try expectEval(vm, "not 0N", "0b");
    try expectEval(vm, "not \"a\"", "0b");
    try expectEval(vm, "not 101b", "010b");
    try expectEval(vm, "not 0x00", "1b");
    try expectEval(vm, "not 2023.01.01", "0b");
    try expectEval(vm, "not ()", "()");
    try expectEval(vm, "not `a`b!1 0", "`a`b!01b");
    try expectEval(vm, "not (1 2;0 1)", "(00b;10b)");
    try testing.expectError(error.nyi, vm.evalSource("not `a", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("not `a`b", .q, "<test>"));
    try testing.expectError(error.nyi, vm.evalSource("not `a`b!(`a;1)", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("not {x}", .q, "<test>"));
    try testing.expectError(error.nyi, vm.evalSource("not (1;0;`a)", .q, "<test>"));

    try expectEval(vm, "null 0N", "1b");
    try expectEval(vm, "null 1", "0b");
    try expectEval(vm, "null 0n", "1b");
    try expectEval(vm, "null \" \"", "1b");
    try expectEval(vm, "null \"ab \"", "001b");
    try expectEval(vm, "null `", "1b");
    try expectEval(vm, "null `a", "0b");
    try expectEval(vm, "null `a`", "01b");
    try expectEval(vm, "null 0Nh", "1b");
    try expectEval(vm, "null 0Nd", "1b");
    try expectEval(vm, "null 1 0N 3", "010b");
    try expectEval(vm, "null ()", "()");
    try expectEval(vm, "null (1;0N;`)", "011b");
    try expectEval(vm, "null `a`b!1 0N", "`a`b!01b");
    try expectEval(vm, "null {x}", "0b");
    try expectEval(vm, "null 0x00", "0b");
    try expectEval(vm, "null 0b", "0b");
    try expectEval(vm, "null (::)", "1b");
    try expectEval(vm, "null (+)", "0b");
    try expectEval(vm, "null (1 0N;0N)", "(01b;1b)");

    try expectEval(vm, "where 101b", "0 2");
    try expectEval(vm, "where 1 2 0", "0 1 1");
    try expectEval(vm, "where 1 0 2", "0 2 2");
    try expectEval(vm, "where 0 3", "1 1 1");
    try expectEval(vm, "where `long$()", "`long$()");
    try expectEval(vm, "where `boolean$()", "`long$()");
    try expectEval(vm, "where ()", "`long$()");
    try expectEval(vm, "where `a`b!1 0", ",`a");
    try expectEval(vm, "where `a`b!2 1", "`a`a`b");
    try expectEval(vm, "where `a`b!(1;2)", "`a`b`b");
    try expectEval(vm, "where ()!()", "()");
    try expectEval(vm, "where 1 2i", "0 1 1");
    try expectEval(vm, "where (1;2)", "0 1 1");
    try testing.expectError(error.type, vm.evalSource("where 1", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("where 1.5", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("where 1 2h", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("where \"ab\"", .q, "<test>"));
    try testing.expectError(error.limit, vm.evalSource("where 1 -1", .q, "<test>"));
    try testing.expectError(error.limit, vm.evalSource("where 0N 1", .q, "<test>"));

    try expectEval(vm, "reverse 1 2 3", "3 2 1");
    try expectEval(vm, "reverse \"abc\"", "\"cba\"");
    try expectEval(vm, "reverse `a`b", "`b`a");
    try expectEval(vm, "reverse (1;`a)", "(`a;1)");
    try expectEval(vm, "reverse ()", "()");
    try expectEval(vm, "reverse 1", "1");
    try expectEval(vm, "reverse `a`b!1 2", "`b`a!2 1");
    try expectEval(vm, "reverse 101b", "101b");
    try expectEval(vm, "reverse enlist 1", ",1");
    try expectEval(vm, "reverse (::)", "::");
    try expectEval(vm, "reverse (+)", "+");

    try expectEval(vm, "reciprocal 2", "0.5");
    try expectEval(vm, "reciprocal 0", "0w");
    try expectEval(vm, "reciprocal 1 2", "1 0.5");
    try expectEval(vm, "reciprocal 0N", "0n");
    try expectEval(vm, "reciprocal \"a\"", "0.01030928");
    try expectEval(vm, "reciprocal 1b", "1f");
    try expectEval(vm, "reciprocal 0x02", "0.5");
    try expectEval(vm, "reciprocal (1;2)", "1 0.5");
    try expectEval(vm, "reciprocal `a`b!1 2", "`a`b!1 0.5");
    try expectEval(vm, "reciprocal 2e", "0.5");
    try expectEval(vm, "reciprocal 0w", "0f");
    try expectEval(vm, "reciprocal -0w", "-0f");
    try expectEval(vm, "reciprocal 0n", "0n");
    try expectEval(vm, "reciprocal 1h", "1f");
    try expectEval(vm, "reciprocal 12:00", "0.001388889");
    try expectEval(vm, "reciprocal 2023.01.01", "0.0001190334");
    try expectEval(vm, "reciprocal ()", "()");
    try expectEval(vm, "reciprocal 2 4e", "0.5 0.25");
    try expectEval(vm, "reciprocal 2 4h", "0.5 0.25");
    try expectEval(vm, "reciprocal `long$()", "`float$()");
    try testing.expectError(error.type, vm.evalSource("reciprocal `a", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("reciprocal {x}", .q, "<test>"));
}

test "distinct, group and grade follow q" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "distinct 1 2 1", "1 2");
    try expectEval(vm, "distinct \"abca\"", "\"abc\"");
    try expectEval(vm, "distinct `a`b`a", "`a`b");
    try expectEval(vm, "distinct (1;`a;1)", "(1;`a)");
    try expectEval(vm, "distinct ()", "()");
    try expectEval(vm, "distinct 1.0 1.0 2", "1 2f");
    try expectEval(vm, "distinct 0n 0n", ",0n");
    try expectEval(vm, "distinct (1 2;1 2;3)", "(1 2;3)");
    try expectEval(vm, "distinct enlist 1", ",1");
    try expectEval(vm, "distinct (1 2;1 2)", ",1 2");
    try expectEval(vm, "distinct 0N 0N 1", "0N 1");
    try expectEval(vm, "distinct 1 1+1e-14", ",1f");
    try expectEval(vm, "distinct (1;1f;1)", "(1;1f)");
    try expectEval(vm, "distinct (0N;0n;0N)", "(0N;0n)");
    try expectEval(vm, "distinct 2023.01.01 2023.01.01", ",2023.01.01");
    try testing.expectError(error.type, vm.evalSource("distinct 1", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("distinct `a`b!1 2", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("distinct (+)", .q, "<test>"));

    try expectEval(vm, "group 1 2 1", "1 2!(0 2;,1)");
    try expectEval(vm, "group \"abca\"", "\"abc\"!(0 3;,1;,2)");
    try expectEval(vm, "group `a`b`a", "`a`b!(0 2;,1)");
    try expectEval(vm, "group (1;`a;1)", "(1;`a)!(0 2;,1)");
    try expectEval(vm, "group ()", "()!()");
    try expectEval(vm, "group 101b", "10b!(0 2;,1)");
    try expectEval(vm, "group `a`b!1 2", "1 2!(,`a;,`b)");
    try expectEval(vm, "group `a`b`c!1 2 1", "1 2!(`a`c;,`b)");
    try expectEval(vm, "group (1 2;1 2;3)", "(1 2;3)!(0 1;,2)");
    try expectEval(vm, "group enlist 1", "(,1)!,,0");
    try expectEval(vm, "group `long$()", "(`long$())!()");
    try expectEval(vm, "group 0N 0N 1", "0N 1!(0 1;,2)");
    try expectEval(vm, "group 1 1+1e-14", "(,1f)!,0 1");
    try testing.expectError(error.type, vm.evalSource("group 1", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("group {x}", .q, "<test>"));

    try expectEval(vm, "iasc 3 1 2", "1 2 0");
    try expectEval(vm, "idesc 3 1 2", "0 2 1");
    try expectEval(vm, "iasc \"cab\"", "1 2 0");
    try expectEval(vm, "iasc `c`a`b", "1 2 0");
    try expectEval(vm, "iasc (3;1;2)", "1 2 0");
    try expectEval(vm, "iasc (1;`a;2)", "0 2 1");
    try expectEval(vm, "iasc ()", "`long$()");
    try expectEval(vm, "iasc 1 1 1", "0 1 2");
    try expectEval(vm, "idesc 1 1 2", "2 0 1");
    try expectEval(vm, "idesc 1 1 1", "0 1 2");
    try expectEval(vm, "iasc 0N 1 -1", "0 2 1");
    try expectEval(vm, "idesc 0N 1 -1", "1 2 0");
    try expectEval(vm, "iasc 0n 1 -1", "0 2 1");
    try expectEval(vm, "iasc 101b", "1 0 2");
    try expectEval(vm, "iasc `a`b!3 1", "`b`a");
    try expectEval(vm, "idesc `a`b!3 1", "`a`b");
    try expectEval(vm, "iasc (1 2;1 1;0 5)", "2 1 0");
    try expectEval(vm, "iasc (1 2;1)", "1 0");
    try expectEvalMode(vm, .k, "<<3 1 2", "2 0 1");
    try expectEval(vm, "iasc 2023.01.02 2023.01.01", "1 0");
    try expectEval(vm, "iasc 0x0201", "1 0");
    try expectEval(vm, "iasc 1 2 3h", "0 1 2");
    try expectEval(vm, "iasc 1 1+1e-14", "0 1");
    try expectEval(vm, "iasc (1;\"a\";`b;2.5;0x01;1b)", "5 4 0 3 1 2");
    try expectEval(vm, "idesc (1;\"a\";`b;2.5;0x01;1b)", "2 1 3 0 4 5");
    try expectEval(vm, "iasc (2 1;1 2 3;1 2)", "2 1 0");
    try expectEval(vm, "iasc (`a`b;`a)", "1 0");
    try expectEval(vm, "iasc (1 2;\"ab\")", "0 1");
    try expectEval(vm, "iasc (\"ab\";\"a\";\"b\")", "1 2 0");
    try expectEval(vm, "idesc (\"ab\";\"a\";\"b\")", "0 2 1");
    try expectEval(vm, "iasc (1;1 2;0)", "2 0 1");
    try expectEval(vm, "iasc 1 0W 0N -0W", "2 3 0 1");
    try expectEval(vm, "iasc -0w 0w 0n 0", "2 0 3 1");
    try expectEval(vm, "iasc (98;\"a\";97;\"b\";96)", "4 2 0 1 3");
    try expectEval(vm, "iasc (0N;1;-0W;0n;`a)", "0 2 1 3 4");
    try expectEval(vm, "iasc (1 2;`a;3;\"x\";+)", "2 3 1 0 4");
    try expectEval(vm, "iasc ((1;2);(1;3);(1;2 3);(0;9))", "2 3 0 1");
    try expectEval(vm, "iasc (`a`b;`b;`c;`a)", "3 1 2 0");
    try testing.expectError(error.type, vm.evalSource("iasc {x}", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("idesc (::)", .q, "<test>"));
}

test "key, value, find, bin and binr follow q" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "key 3", "0 1 2");
    try expectEval(vm, "key 0", "`long$()");
    try expectEval(vm, "key `a`b!1 2", "`a`b");
    try expectEval(vm, "key 1 2", "`long");
    try expectEval(vm, "key \"ab\"", "`char");
    try expectEval(vm, "key `a`b", "`symbol");
    try expectEval(vm, "key 3h", "0 1 2");
    try expectEval(vm, "key 1b", ",0");
    try expectEval(vm, "key 0x02", "0 1");
    try expectEval(vm, "key 0x00", "`long$()");
    try expectEval(vm, "qqq:1 2;key `qqq", "`qqq");
    try expectEval(vm, "key `zzz", "()");
    try expectEval(vm, "key `.zzz", "()");
    try expectEval(vm, "key `.", ",`qqq");
    try expectEval(vm, "first key `", "`");
    try expectEval(vm, "`q in key `", "1b");
    try expectEval(vm, "2#key `.q", "``neg");
    try expectEval(vm, ".zq.a:1;key `.zq", "``a");
    try testing.expectError(error.domain, vm.evalSource("key -1", .q, "<test>"));
    try testing.expectError(error.domain, vm.evalSource("key 0N", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("key ()", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("key 3.0", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("key {x}", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("key \"a\"", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("key (1 2;3)", .q, "<test>"));

    try expectEval(vm, "value `a`b!1 2", "1 2");
    try expectEval(vm, "value ()", "()");
    try expectEval(vm, "value \"1+1\"", "2");
    try expectEval(vm, "value \"\"", "::");
    try expectEval(vm, "value (+;1;2)", "3");
    try expectEval(vm, "value (+;1)", "+[1]");
    try expectEval(vm, "value (+/)", "+");
    try expectEval(vm, "value (1+)", "(+;1)");
    try expectEval(vm, "value (+')", "+");
    try expectEval(vm, "value {x+y}[1]", "({x+y};1)");
    try expectEval(vm, "value {x+y}[;1]", "({x+y};::;1)");
    try expectEval(vm, "value (\"+\";1;2)", "3");
    try expectEval(vm, "value (+;1 2;3 4)", "4 6");
    try expectEval(vm, "value ({x+y};1;2)", "3");
    try expectEval(vm, "value (`a`b!1 2;`a)", "1");
    try expectEval(vm, "value ({x};1)", "1");
    try expectEval(vm, "value (enlist;1)", ",1");
    try testing.expectError(error.type, vm.evalSource("value 1 2 3", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("value 101b", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("value (1;2)", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("value 1", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("value (\"1+1\";2)", .q, "<test>"));
    try testing.expectError(error.identifier, vm.evalSource("value `zzz", .q, "<test>"));
    try testing.expectError(error.identifier, vm.evalSource("value (`nope;1)", .q, "<test>"));

    try expectEval(vm, "1 2 3?2", "1");
    try expectEval(vm, "1 2 3?5", "3");
    try expectEval(vm, "1 2 3?2 5", "1 3");
    try expectEval(vm, "\"abc\"?\"b\"", "1");
    try expectEval(vm, "\"abc\"?\"bc\"", "1 2");
    try expectEval(vm, "`a`b?`b", "1");
    try expectEval(vm, "`a`b?`a`c", "0 2");
    try expectEval(vm, "(1;`a;\"x\")?`a", "1");
    try expectEval(vm, "(1 2;3 4)?3 4", "1");
    try expectEval(vm, "(1;2)?1 2", "0 1");
    try expectEval(vm, "(1;2)?(1;2)", "0 1");
    try expectEval(vm, "(1 2;3 4)?(3 4;1 2)", "1 0");
    try expectEval(vm, "(1 2;3)?3", "2");
    try expectEval(vm, "(3;1 2)?3", "0");
    try expectEval(vm, "(3;1 2)?1 2", "2 2");
    try expectEval(vm, "(1 2;3)?(3;1 2)", "2");
    try expectEval(vm, "(1 2;3 4)?(1 2;3)", "0 2");
    try expectEval(vm, "(1;2)?(1 2;3)", "(0 1;2)");
    try expectEval(vm, "(1;\"ab\")?\"ab\"", "2 2");
    try expectEval(vm, "(\"ab\";1)?\"ab\"", "0");
    try expectEval(vm, "(1 2;3 4)?5 6", "2");
    try expectEval(vm, "(1 2;3) bin 3", "1");
    try expectEval(vm, "(1 2;3)?(1 2;3)", "0 1");
    try expectEval(vm, "(1 2;3)?enlist 1 2", ",0");
    try expectEval(vm, "1 2 3?()", "`long$()");
    try expectEval(vm, "()?1", "0");
    try expectEval(vm, "(`a`b!1 2)?2", "`b");
    try expectEval(vm, "(`a`b!1 2)?3", "`");
    try expectEval(vm, "(`a`b!1 2)?1 2", "`a`b");
    try expectEval(vm, "1 2 3?0N", "3");
    try expectEval(vm, "0N 1?0N", "0");
    try expectEval(vm, "1.0 2?1+1e-14", "2");
    try expectEval(vm, "(1;`a)?1f", "2");
    try expectEval(vm, "(1;1f)?1f", "1");
    try testing.expectError(error.type, vm.evalSource("1 2 3?2h", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("1 2 3?2.0", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("1 2 3?(2;1 3)", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("\"abc\"?98", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("1 2 3?2 3h", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("`a`b?\"a\"", .q, "<test>"));

    try expectEval(vm, "1 2 5h bin 3h", "1");
    try expectEval(vm, "1 3 5 bin 0 1 2 3 4 5 6", "-1 0 0 1 1 2 2");
    try expectEval(vm, "1 3 5 binr 3", "1");
    try expectEval(vm, "1 3 5 binr 0 1 2 3 4 5 6", "0 0 1 1 2 2 3");
    try expectEval(vm, "1 3 5 binr 5 6", "2 3");
    try expectEval(vm, "1 1 3 3 bin 1 3", "1 3");
    try expectEval(vm, "1 1 3 3 binr 1 3", "0 2");
    try expectEval(vm, "`a`c bin `b", "0");
    try expectEval(vm, "`a`c bin `a`b`c`d", "0 0 1 1");
    try expectEval(vm, "\"ace\" bin \"b\"", "0");
    try expectEval(vm, "1 3 5 bin 0N", "-1");
    try expectEval(vm, "0N 1 3 bin 0N", "0");
    try expectEval(vm, "1 3 5 binr 0N", "0");
    try expectEval(vm, "1 3 5 bin -0W", "-1");
    try expectEval(vm, "1 3 5 bin 0W", "2");
    try expectEval(vm, "1 3 5 binr 0W", "3");
    try expectEval(vm, "1 3 5 bin ()", "`long$()");
    try expectEval(vm, "1 3 5 bin `long$()", "`long$()");
    try expectEval(vm, "(1 2;3 4) bin 3 4", "1");
    try expectEval(vm, "(1 2;3 4) bin (2 3;3 4)", "0 1");
    try expectEval(vm, "(1 2;3 4) bin (1 2;5)", "0 -1");
    try expectEval(vm, "(1 2;3 4) bin (1;3)", "0");
    try expectEval(vm, "(1 2;3 4) bin 3", "0");
    try expectEval(vm, "(`a;1;`c) bin `b", "1");
    try expectEval(vm, "1 3 5 bin (1 2;3)", "(0 0;1)");
    try expectEval(vm, "1 3 5h bin 3 4h", "1 1");
    try expectEval(vm, "01b bin 1b", "1");
    try expectEval(vm, "() bin 1", "-1");
    try expectEval(vm, "2023.01.01 2023.01.03 bin 2023.01.02", "0");
    try expectEval(vm, "1 3 5 bin 0N 3", "-1 1");
    try expectEval(vm, "(`a`b!1 2) bin 1", "`a");
    try testing.expectError(error.type, vm.evalSource("1 3 5 bin 3.5", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("1 3 5.0 bin 3", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("1 2 5h bin 3", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("1 bin 1", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("1 3 5 bin `a", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("1 3 5 bin 1b", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("1 3 5 bin 1 3 5f", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("1b bin 1b", .q, "<test>"));

    // Dictionaries in lists, and a built-in system command reads one word.
    try expectEval(vm, "enlist ()!()", ",()!()");
    try expectEval(vm, "(enlist `)!enlist ()!()", "(,`)!,()!()");
    try expectEval(vm, "type (enlist `)!enlist ()!()", "99h");
    try expectEval(vm, "type enlist ()!()", "0h");
    try expectEval(vm, "(()!();()!())", "(()!();()!())");
    try expectEval(vm, "(`a`b!1 2;`a`b!3 4)", "+`a`b!(1 3;2 4)");
    try expectEval(vm, "(`a`b!1 2;`b`a!3 4)", "(`a`b!1 2;`b`a!3 4)");
    try expectEval(vm, "(`a`b!1 2;`a`c!3 4)", "(`a`b!1 2;`a`c!3 4)");
    try expectEval(vm, "value \"\\\\d .h / comment\"", "::");
    try expectEval(vm, "value \"\\\\d\"", "`.h");
    try expectEval(vm, "value \"\\\\d .\"", "::");
    try expectEval(vm, "value \"\\\\P 5 / c\"", "::");
    try expectEval(vm, "value \"\\\\P\"", "5i");
    try expectEval(vm, "value \"\\\\P 7\"", "::");
}

test "sv and vs through data on the left of /: and \\:, getenv and setenv" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    // Strings.
    try expectEvalMode(vm, .k, "\" \"\\:\"a b c\"", "(,\"a\";,\"b\";,\"c\")");
    try expectEvalMode(vm, .k, "\" \"\\:\"  a  b \"", "(\"\";\"\";,\"a\";\"\";,\"b\";\"\")");
    try expectEvalMode(vm, .k, "\" \"\\:\"\"", ",\"\"");
    try expectEvalMode(vm, .k, "\" \"\\:\"abc\"", ",\"abc\"");
    try expectEvalMode(vm, .k, "\"\\n\"\\:\"a\\nb\"", "(,\"a\";,\"b\")");
    try expectEvalMode(vm, .k, "\",\"\\:\"a,b,\"", "(,\"a\";,\"b\";\"\")");
    try expectEvalMode(vm, .k, "\"ab\"\\:\"xabyabz\"", "(,\"x\";,\"y\";,\"z\")");
    try expectEvalMode(vm, .k, "\"%\"\\:\"a%20b\"", "(,\"a\";\"20b\")");
    try expectEvalMode(vm, .k, "\"a\"\\:\"abc\"", "(\"\";\"bc\")");
    try expectEvalMode(vm, .k, "@\" \"\\:\"a b\"", "0h");
    try testing.expectError(error.length, vm.evalSource("\"\"\\:\"abc\"", .k, "<test>"));
    try testing.expectError(error.type, vm.evalSource("\" \"\\:`a", .k, "<test>"));
    try testing.expectError(error.type, vm.evalSource("\" \"\\:1 2", .k, "<test>"));
    try testing.expectError(error.type, vm.evalSource("\" \"\\:,\"a b\"", .k, "<test>"));
    try expectEvalMode(vm, .k, "\" \"/:(\"ab\";\"cd\")", "\"ab cd\"");
    try expectEvalMode(vm, .k, "\" \"/:(\"ab\";\"\";\"cd\")", "\"ab  cd\"");
    try expectEvalMode(vm, .k, "\" \"/:()", "\"\"");
    try expectEvalMode(vm, .k, "\" \"/:,\"ab\"", "\"ab\"");
    try expectEvalMode(vm, .k, "\" \"/:,\"\"", "\"\"");
    try expectEvalMode(vm, .k, "\", \"/:(\"ab\";\"cd\")", "\"ab, cd\"");
    try expectEvalMode(vm, .k, "@\" \"/:(\"ab\";\"cd\")", "10h");
    try testing.expectError(error.type, vm.evalSource("\" \"/:\"ab\"", .k, "<test>"));
    try testing.expectError(error.type, vm.evalSource("\" \"/:(1;2)", .k, "<test>"));
    try testing.expectError(error.type, vm.evalSource("\" \"/:(\"a\";\"bc\")", .k, "<test>"));

    // Symbols and lines.
    try expectEvalMode(vm, .k, "`\\:`a.b.c", "`a`b`c");
    try expectEvalMode(vm, .k, "`\\:`abc", ",`abc");
    try expectEvalMode(vm, .k, "`\\:`", ",`");
    try expectEvalMode(vm, .k, "`\\:`.a.b", "``a`b");
    try expectEvalMode(vm, .k, "`\\:\"abc\"", ",\"abc\"");
    try expectEvalMode(vm, .k, "`\\:\"a\\nb\"", "(,\"a\";,\"b\")");
    try expectEvalMode(vm, .k, "`\\:\"a\\nb\\n\"", "(,\"a\";,\"b\")");
    try expectEvalMode(vm, .k, "`\\:\"a\\r\\nb\"", "(,\"a\";,\"b\")");
    try expectEvalMode(vm, .k, "`\\:\"\"", "()");
    try expectEvalMode(vm, .k, "@`\\:`a", "11h");
    try testing.expectError(error.type, vm.evalSource("`\\:`a`b", .k, "<test>"));
    try testing.expectError(error.type, vm.evalSource("`\\:1", .k, "<test>"));
    try expectEvalMode(vm, .k, "`/:`a`b", "`a.b");
    try expectEvalMode(vm, .k, "`/:`a`b`c", "`a.b.c");
    try expectEvalMode(vm, .k, "`/:,`a", "`a");
    try expectEvalMode(vm, .k, "`/:``a", "`.a");
    try expectEvalMode(vm, .k, "`/:(\"ab\";\"cd\")", "\"ab\\ncd\\n\"");
    try expectEvalMode(vm, .k, "`/:(\"ab\";,\"c\")", "\"ab\\nc\\n\"");
    try expectEvalMode(vm, .k, "`/:(\"\";\"\")", "\"\\n\\n\"");
    try expectEvalMode(vm, .k, "`/:,\"ab\"", "\"ab\\n\"");
    try expectEvalMode(vm, .k, "`/:()", "\"\"");
    try expectEvalMode(vm, .k, "@`/:`a`b", "-11h");
    try testing.expectError(error.type, vm.evalSource("`/:`symbol$()", .k, "<test>"));
    try testing.expectError(error.type, vm.evalSource("`/:\"ab\"", .k, "<test>"));
    try testing.expectError(error.type, vm.evalSource("`/:(`a;\"b\")", .k, "<test>"));
    try testing.expectError(error.type, vm.evalSource("`/:(\"ab\";\"c\")", .k, "<test>"));
    try testing.expectError(error.type, vm.evalSource("`/:`a`b!1 2", .k, "<test>"));

    // Bytes.
    try expectEvalMode(vm, .k, "0x00\\:1234", "0x00000000000004d2");
    try expectEvalMode(vm, .k, "0x00\\:1234h", "0x04d2");
    try expectEvalMode(vm, .k, "0x00\\:1234i", "0x000004d2");
    try expectEvalMode(vm, .k, "0x00\\:1.5", "0x3ff8000000000000");
    try expectEvalMode(vm, .k, "0x00\\:1e", "0x3f800000");
    try expectEvalMode(vm, .k, "0x00\\:\"a\"", ",0x61");
    try expectEvalMode(vm, .k, "0x00\\:0N", "0x8000000000000000");
    try expectEvalMode(vm, .k, "0x00\\:-1", "0xffffffffffffffff");
    try expectEvalMode(vm, .k, "0x40\\:1234", "0x00000000000000001312");
    try expectEvalMode(vm, .k, "0x40\\:-1", "0x3f3f3f3f3f3f3f3f3f3f");
    try expectEvalMode(vm, .k, "0x40\\:0W", "0x3f3f3f3f3f3f3f3f3f3f");
    try expectEvalMode(vm, .k, "0x40\\:0N", "`byte$()");
    try expectEvalMode(vm, .k, "0x24\\:1234", "0x00000000000000000000220a");
    try expectEvalMode(vm, .k, "0x24\\:0", "0x000000000000000000000000");
    try testing.expectError(error.type, vm.evalSource("0x00\\:`a", .k, "<test>"));
    try testing.expectError(error.type, vm.evalSource("0x00\\:2023.01.01", .k, "<test>"));
    try testing.expectError(error.type, vm.evalSource("0x00\\:1b", .k, "<test>"));
    try testing.expectError(error.type, vm.evalSource("0x00\\:1 2", .k, "<test>"));
    try testing.expectError(error.nyi, vm.evalSource("0x02\\:5", .k, "<test>"));
    try testing.expectError(error.nyi, vm.evalSource("0x40\\:1234h", .k, "<test>"));
    try expectEvalMode(vm, .k, "0x00/:0x00000000000004d2", "1234");
    try expectEvalMode(vm, .k, "0x00/:0x04d2", "1234h");
    try expectEvalMode(vm, .k, "0x00/:0x000004d2", "1234i");
    try expectEvalMode(vm, .k, "0x00/:0x3ff8000000000000", "4609434218613702656");
    try expectEvalMode(vm, .k, "0x40/:0x00000000000000001312", "1234");
    try expectEvalMode(vm, .k, "0x40/:0x40\\:-1", "1152921504606846975");
    try testing.expectError(error.length, vm.evalSource("0x00/:0x0000000004d2", .k, "<test>"));
    try testing.expectError(error.length, vm.evalSource("0x40/:0x1312", .k, "<test>"));
    try testing.expectError(error.type, vm.evalSource("0x00/:0x01", .k, "<test>"));

    // Numbers and radixes.
    try expectEvalMode(vm, .k, "10\\:123", "1 2 3");
    try expectEvalMode(vm, .k, "10\\:0", "`long$()");
    try expectEvalMode(vm, .k, "10\\:-1", "`long$()");
    try expectEvalMode(vm, .k, "10\\:0N", "`long$()");
    try expectEvalMode(vm, .k, "2\\:5", "1 0 1");
    try expectEvalMode(vm, .k, "2\\:5h", "1 0 1");
    try expectEvalMode(vm, .k, "2\\:5i", "1 0 1");
    try expectEvalMode(vm, .k, "2 4\\:10", "0 2");
    try expectEvalMode(vm, .k, "24 60 60\\:3661", "1 1 1");
    try expectEvalMode(vm, .k, "0 24 60 60\\:3661", "0N 1 1 1");
    try expectEvalMode(vm, .k, "10\\:12 345", "(0 3;1 4;2 5)");
    try expectEvalMode(vm, .k, "10\\:1234 5", "(1 0;2 0;3 0;4 5)");
    try expectEvalMode(vm, .k, "2\\:1 2 3", "(0 1 1;1 0 1)");
    try expectEvalMode(vm, .k, "10\\:0 5", ",0 5");
    try expectEvalMode(vm, .k, "10\\:-1 5", ",9 5");
    try expectEvalMode(vm, .k, "10\\:0N 5", ",0N 5");
    try expectEvalMode(vm, .k, "@10\\:123", "7h");
    try expectEvalMode(vm, .k, "10/:1 2 3", "123");
    try expectEvalMode(vm, .k, "10/:0 1 2 3", "123");
    try expectEvalMode(vm, .k, "64/:1 2", "66");
    try expectEvalMode(vm, .k, "10/:1 2 3h", "123");
    try expectEvalMode(vm, .k, "10/:1 2 3i", "123");
    try expectEvalMode(vm, .k, "10/:1 2 3f", "123f");
    try expectEvalMode(vm, .k, "10/:`long$()", "0");
    try expectEvalMode(vm, .k, "10/:,5", "5");
    try expectEvalMode(vm, .k, "2 4/:1 2", "6");
    try expectEvalMode(vm, .k, "2 4 8/:1 2 3", "51");
    try expectEvalMode(vm, .k, "0 24 60 60/:1 1 1 1", "90061");
    try expectEvalMode(vm, .k, "10/:(1 2;3 4)", "13 24");
    try expectEvalMode(vm, .k, "10/:(1 2;3)", "13 23");
    try expectEvalMode(vm, .k, "2 4/:(1 2;3 3)", "7 11");
    try expectEvalMode(vm, .k, "@10/:1 2 3h", "-7h");
    try testing.expectError(error.type, vm.evalSource("10/:1", .k, "<test>"));
    try testing.expectError(error.nyi, vm.evalSource("10/:()", .k, "<test>"));
    // q.k's own definitions: `sv:{x/:y}` and `vs:{x\\:y}`, `j10:64/:b6?` and `x10:b6@0x40\\:`.
    try expectEvalMode(vm, .k, "sv9:{x/:y};vs9:{x\\:y};sv9[\" \"]vs9[\" \"]\"a b\"", "\"a b\"");
    try expectEvalMode(vm, .k, "b6:\"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/\";x10:b6@0x40\\:;x10 1234", "\"AAAAAAAATS\"");
    try expectEvalMode(vm, .k, "j10:64/:b6?;j10 x10 1234", "1234");

    // The environment: empty in tests, `setenv` fills it.
    try expectEval(vm, "getenv`NOPE_ZZZ_UNSET", "\"\"");
    try expectEval(vm, "getenv`", "\"\"");
    try expectEval(vm, "getenv()", "()");
    try expectEval(vm, "getenv`symbol$()", "()");
    try expectEval(vm, "setenv[`ZZQ;\"ab\"]", "::");
    try expectEval(vm, "getenv`ZZQ", "\"ab\"");
    try expectEval(vm, "getenv`ZZQ`ZZQ", "(\"ab\";\"ab\")");
    try expectEval(vm, "getenv`ZZQ`NOPE", "(\"ab\";\"\")");
    try expectEval(vm, "setenv[`ZZQ;\"\"];getenv`ZZQ", "\"\"");
    try expectEval(vm, "type getenv`NOPE", "10h");
    try testing.expectError(error.type, vm.evalSource("getenv\"HOME\"", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("getenv 1", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("setenv[`ZZQ;\"1\"]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("setenv[`ZZQ;1]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("setenv[\"ZZQ\";\"ab\"]", .q, "<test>"));
    // q.k's last line: a missing q.q is a caught error, not a crash.
    try expectEvalMode(vm, .k, "{@[.:;\"\\\\l \",$[#e:getenv`QINIT;e;\"q.q\"];::]}[]", "\"q.q. OS reports: No such file or directory\"");
}

test "flip transposes a list of lists as q does" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "flip (1 2;3)", "(1 3;2 3)");
    try expectEval(vm, "flip (1 2;3 4)", "(1 3;2 4)");
    try expectEval(vm, "flip (\"ab\";\"cd\")", "(\"ac\";\"bd\")");
    try expectEval(vm, "flip ()", "()");
    try expectEval(vm, "flip enlist 1 2", "(,1;,2)");
    try expectEval(vm, "flip (1 2;`a`b)", "((1;`a);(2;`b))");
    try expectEval(vm, "flip (1 2;3 4;5 6)", "(1 3 5;2 4 6)");
    try expectEval(vm, "flip (1 2;3;4 5)", "(1 3 4;2 3 5)");
    try expectEval(vm, "flip (1 2;\"ab\")", "((1;\"a\");(2;\"b\"))");
    try expectEval(vm, "flip (1 2f;3 4)", "((1f;3);(2f;4))");
    try expectEval(vm, "flip (0N 1;2 3)", "(0N 2;1 3)");
    try expectEval(vm, "flip (enlist 1;enlist 2)", ",1 2");
    try expectEval(vm, "flip ((1 2;3 4);(5 6;7 8))", "((1 2;5 6);(3 4;7 8))");
    try expectEval(vm, "flip ((1 2;3);(4;5 6))", "((1 2;4);(3;5 6))");
    try expectEval(vm, "flip (`long$();`long$())", "()");
    try expectEval(vm, "flip 2#enlist 1 2", "(1 1;2 2)");
    try expectEval(vm, "type flip (1 2;3 4)", "0h");
    try expectEvalMode(vm, .k, "+\" \"\\:'(\"htm text/html\";\"csv text/csv\")", "((\"htm\";\"csv\");(\"text/html\";\"text/csv\"))");
    try testing.expectError(error.rank, vm.evalSource("flip 1 2", .q, "<test>"));
    try testing.expectError(error.rank, vm.evalSource("flip 1", .q, "<test>"));
    try testing.expectError(error.rank, vm.evalSource("flip `a", .q, "<test>"));
    try testing.expectError(error.rank, vm.evalSource("flip {x}", .q, "<test>"));
    try testing.expectError(error.rank, vm.evalSource("flip (1;`a)", .q, "<test>"));
    try testing.expectError(error.length, vm.evalSource("flip (1 2;3 4 5)", .q, "<test>"));
}

test "value of a primitive is its q table number and k lambdas show a k) prefix" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "value (::)", "0");
    try expectEval(vm, "type value (::)", "-7h");
    try expectEval(vm, "value (:)", "0");
    try expectEval(vm, "value (+)", "1");
    try expectEval(vm, "value (-:)", "2");
    try expectEval(vm, "value (neg)", "2");
    try expectEval(vm, "value (#:)", "13");
    try expectEval(vm, "value (@)", "18");
    try expectEval(vm, "value (.:)", "19");
    try expectEval(vm, "value (2:)", "22");
    try expectEval(vm, "value (avg)", "23");
    try expectEval(vm, "value (last)", "24");
    try expectEval(vm, "value (enlist)", "41");
    try expectEval(vm, "value (hopen)", "44");
    try expectEval(vm, "value (in)", "23");
    try expectEval(vm, "value (bin)", "26");
    try expectEval(vm, "value (setenv)", "33");
    try expectEval(vm, "value (cor)", "36");
    try expectEval(vm, "value (')", "0");
    try expectEval(vm, "value (/)", "1");
    try expectEval(vm, "value (\\:)", "5");
    try expectEvalMode(vm, .k, ".(::)", "0");
    try expectEvalMode(vm, .k, ".(::;1)", "1");

    try expectEvalMode(vm, .k, "{x+y}", "k){x+y}");
    try expectEvalMode(vm, .k, "f:{x+y};f", "k){x+y}");
    try expectEvalMode(vm, .k, "{[a;b]a+b}", "k){[a;b]a+b}");
    try expectEvalMode(vm, .k, "{}", "k){}");
    try expectEvalMode(vm, .k, "$({x+y})", "\"k){x+y}\"");
    try expectEvalMode(vm, .k, "-3!{x+y}", "\"k){x+y}\"");
    try expectEvalMode(vm, .k, "@[{x+y};1]", "k){x+y}[1]");
    try expectEvalMode(vm, .k, "(1;{x})", "(1;k){x})");
    try expectEvalMode(vm, .k, "`a`b!(1;{x})", "`a`b!(1;k){x})");
    try expectEvalMode(vm, .k, "{.z.s}[]", "k){.z.s}");
    try expectEvalMode(vm, .k, "{x}[1]", "1");
    try expectEvalMode(vm, .k, "q){x}", "{x}");
    try expectEvalMode(vm, .k, "k){x}", "k){x}");
    try expectEval(vm, "{x+y}", "{x+y}");
    try expectEval(vm, "k){x}", "k){x}");
    try expectEval(vm, "q){x}", "{x}");
    try expectEval(vm, "parse \"k){x}\"", "k){x}");
    try expectEval(vm, "last value value \"k){x}\"", "\"k){x}\"");
    try expectEval(vm, "last value {x}", "\"{x}\"");
    try expectEval(vm, "value `.q.each", "k){x'y}");
    try expectEval(vm, "value (`.q.each;1)", "k){x'y}[1]");
    try expectEvalMode(vm, .k, "(:;`f;{x})", "(:;`f;k){x})");
}

test "fill, drop and cut follow q" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "0^1 0N 3", "1 0 3");
    try expectEval(vm, "0i^1 0N 3", "1 0 3");
    try expectEval(vm, "type 0i^1 0N 3", "7h");
    try expectEval(vm, "0.0^1 0N 3", "1 0 3f");
    try expectEval(vm, "0^1 0n 3", "1 0 3f");
    try expectEval(vm, "0h^1 0N 3h", "1 0 3h");
    try expectEval(vm, "1 2^0N 5", "1 5");
    try expectEval(vm, "1 2^0N 0N", "1 2");
    try expectEval(vm, "0N^1 0N", "1 0N");
    try expectEval(vm, "0N^0N", "0N");
    try expectEval(vm, "1^0N", "1");
    try expectEval(vm, "1^2", "2");
    try expectEval(vm, "1^0n", "1f");
    try expectEval(vm, "1.5^0N", "1.5");
    try expectEval(vm, "\"a\"^\" \"", "\"a\"");
    try expectEval(vm, "\"a\"^\"b\"", "\"b\"");
    try expectEval(vm, "\"ab\"^\" b\"", "\"ab\"");
    try expectEval(vm, "`a^`", "`a");
    try expectEval(vm, "`a^`b", "`b");
    try expectEval(vm, "`a^``b", "`a`b");
    try expectEval(vm, "(`)^`a`b", "`a`b");
    try expectEval(vm, "0^\"a\"", "\"a\"");
    try expectEval(vm, "0^\" \"", "\"\\000\"");
    try expectEval(vm, "\"x\"^0N", "\"\\000\"");
    try expectEval(vm, "\"x\"^1 0N", "\"\\001\\000\"");
    try expectEval(vm, "0^\"a \"", "\"a\\000\"");
    try expectEval(vm, "\"a\"^1", "\"\\001\"");
    try expectEval(vm, "\"x\"^\"a  b\"", "\"axxb\"");
    try expectEval(vm, "0^0Nh", "0");
    try expectEval(vm, "0^0Ni", "0");
    try expectEval(vm, "0^0Ne", "0e");
    try expectEval(vm, "0i^0Nh", "0i");
    try expectEval(vm, "0h^0Ni", "0i");
    try expectEval(vm, "0.0^0Ni", "0f");
    try expectEval(vm, "0i^0n", "0f");
    try expectEval(vm, "0.5^0Nh", "0.5");
    try expectEval(vm, "1e^0N", "1e");
    try expectEval(vm, "1^0b", "0");
    try expectEval(vm, "0b^1", "1");
    try expectEval(vm, "1^0x00", "0");
    try expectEval(vm, "0x00^1", "1");
    try expectEval(vm, "1b^0b", "0b");
    try expectEval(vm, "0x01^0x00", "0x00");
    try expectEval(vm, "1^0W", "0W");
    try expectEval(vm, "0N^0n", "0n");
    try expectEval(vm, "0n^0N", "0n");
    try expectEval(vm, "0Nh^1 2", "1 2");
    try expectEval(vm, "0^0Nd", "2000.01.01");
    try expectEval(vm, "0.5^0Nd", "2000.01.02");
    try expectEval(vm, "2023.01.01^0Nd", "2023.01.01");
    try expectEval(vm, "0^2023.01.01", "2023.01.01");
    try expectEval(vm, "2023.01.01^0N", "2023.01.01");
    try expectEval(vm, "0N^2023.01.01", "2023.01.01");
    try expectEval(vm, "2000.01.01^1 0N", "2000.01.02 2000.01.01");
    try expectEval(vm, "0Nd^0N", "0Nd");
    try expectEval(vm, "0^0Np", "2000.01.01D00:00:00.000000000");
    try expectEval(vm, "0^0Nz", "2000.01.01T00:00:00.000");
    try expectEval(vm, "0^0Nt", "00:00:00.000");
    try expectEval(vm, "1^0Nu", "00:01");
    try expectEval(vm, "1^0Nv", "00:00:01");
    try expectEval(vm, "1^0Nm", "2000.02m");
    try expectEval(vm, "1^0Nn", "0D00:00:00.000000001");
    try expectEval(vm, "0Np^0N", "0Np");
    try expectEval(vm, "0Nz^0N", "0Nz");
    try expectEval(vm, "12:00^0Nt", "12:00:00.000");
    try expectEval(vm, "0Nt^12:00", "12:00:00.000");
    try expectEval(vm, "0Nu^0Nt", "0Nt");
    try expectEval(vm, "0.5^1 0N 3", "1 0.5 3");
    try expectEval(vm, "1.5^1 0N", "1 1.5");
    try expectEval(vm, "0^1 0N 3f", "1 0 3f");
    try expectEval(vm, "0^1 0N 3e", "1 0 3e");
    try expectEval(vm, "0e^1 0N 3", "1 0 3e");
    try expectEval(vm, "1e^0N 2e", "1 2e");
    try expectEval(vm, "0i^1 0N 3f", "1 0 3f");
    try expectEval(vm, "0b^0N 1", "0 1");
    try expectEval(vm, "0x00^0N 1", "0 1");
    try expectEval(vm, "1^0N 0n", "1 1f");
    try expectEval(vm, "1.5^0N 0n", "1.5 1.5");
    try expectEval(vm, "1 2^0N 0n", "1 2f");
    try expectEval(vm, "1 2^(0N;0n)", "(1;2f)");
    try expectEval(vm, "(1;2.5)^0N 0n", "1 2.5");
    try expectEval(vm, "(1;2.5)^0N 0N", "(1;2.5)");
    try expectEval(vm, "(`a;1)^(`;0N)", "(`a;1)");
    try expectEval(vm, "(0;`a)^(0N;`)", "(0;`a)");
    try expectEval(vm, "0^(1 0N;0N)", "(1 0;0)");
    try expectEval(vm, "0^enlist 0N", ",0");
    try expectEval(vm, "0^()", "()");
    try expectEval(vm, "0^`long$()", "`long$()");
    try expectEval(vm, "0N^`long$()", "`long$()");
    try expectEval(vm, "0n^`long$()", "`float$()");
    try expectEval(vm, "type 0^`float$()", "9h");
    try expectEval(vm, "type 0h^`long$()", "7h");
    try expectEval(vm, "type 0^`short$()", "7h");
    try expectEval(vm, "type 2023.01.01^`long$()", "14h");
    try expectEval(vm, "0^`a`b!1 0N", "`a`b!1 0");
    try expectEval(vm, "(`a`b!1 2)^`a`c!0N 3", "`a`b`c!1 2 3");
    try expectEval(vm, "(`a`b!1 2)^`b`c!0N 3", "`a`b`c!1 2 3");
    try testing.expectError(error.type, vm.evalSource("0^`a", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("`a^0N", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("1^`", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("\"a\"^`", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("`a^\" \"", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("`a^1", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("12:00^0Nd", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("0^(1;0N;`)", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("0^(0N;`a)", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("0^`a`b!(0N;`)", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("0^{x}", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("1^(::)", .q, "<test>"));
    try testing.expectError(error.length, vm.evalSource("1 2 3^0N 1", .q, "<test>"));
    try testing.expectError(error.nyi, vm.evalSource("1 2^3", .q, "<test>"));
    try testing.expectError(error.nyi, vm.evalSource("(::)^1", .q, "<test>"));

    try expectEval(vm, "2 _ 1 2 3 4", "3 4");
    try expectEval(vm, "-2 _ 1 2 3 4", "1 2");
    try expectEval(vm, "0 _ 1 2 3", "1 2 3");
    try expectEval(vm, "5 _ 1 2 3", "`long$()");
    try expectEval(vm, "-5 _ 1 2 3", "`long$()");
    try expectEval(vm, "2 _ \"abcd\"", "\"cd\"");
    try expectEval(vm, "5 _ \"abc\"", "\"\"");
    try expectEval(vm, "1 _ `a`b`c", "`b`c");
    try expectEval(vm, "2 _ (1;`a;3)", ",3");
    try expectEval(vm, "1 _ ()", "()");
    try expectEval(vm, "1 _ \"\"", "\"\"");
    try expectEval(vm, "1 _ enlist 1", "`long$()");
    try expectEval(vm, "1h _ 1 2 3", "2 3");
    try expectEval(vm, "1b _ 1 2 3", "2 3");
    try expectEval(vm, "0x01 _ 0x010203", "0x0203");
    try expectEval(vm, "1 _ `a`b!1 2", "(,`b)!,2");
    try expectEval(vm, "-1 _ `a`b!1 2", "(,`a)!,1");
    try expectEval(vm, "1 _ `a`b`c!1 2 3", "`b`c!2 3");
    try expectEval(vm, "2 _ `a`b!1 2", "(`symbol$())!`long$()");
    try expectEval(vm, "type 1 _ `a`b!1 2", "99h");
    try expectEval(vm, "`a _ `a`b!1 2", "(,`b)!,2");
    try expectEval(vm, "`a`b _ `a`b`c!1 2 3", "(,`c)!,3");
    try expectEval(vm, "`z _ `a`b!1 2", "`a`b!1 2");
    try expectEval(vm, "(`a`b!1 2) _ `a", "(,`b)!,2");
    try expectEval(vm, "(1 2!3 4) _ 1", "(,2)!,4");
    try expectEval(vm, "(1 2!3 4) _ 5", "1 2!3 4");
    try expectEval(vm, "1 2 3 _ 1", "1 3");
    try expectEval(vm, "(1 2;3) _ 1", ",1 2");
    try expectEval(vm, "(til 5) _ 0", "1 2 3 4");
    try expectEval(vm, "\"abc\" _ 1", "\"ac\"");
    try expectEval(vm, "1 2 3 _ 5", "1 2 3");
    try expectEval(vm, "1 2 3 _ -1", "1 2 3");
    try expectEval(vm, "1 2 3 _ 0N", "1 2 3");
    try expectEval(vm, "0 2 _ til 5", "(0 1;2 3 4)");
    try expectEval(vm, "1 3 _ til 5", "(1 2;3 4)");
    try expectEval(vm, "2 2 _ til 4", "(`long$();2 3)");
    try expectEval(vm, "0 0 _ 1 2 3", "(`long$();1 2 3)");
    try expectEval(vm, "0 2 _ \"abcd\"", "(\"ab\";\"cd\")");
    try expectEval(vm, "2 3 _ \"abcdef\"", "(,\"c\";\"def\")");
    try expectEval(vm, "(enlist 1) _ 1 2 3", ",2 3");
    try expectEval(vm, "0 1 _ 1 2 3", "(,1;2 3)");
    try expectEval(vm, "(0;2) _ til 5", "(0 1;2 3 4)");
    try expectEval(vm, "0 2i _ til 4", "(0 1;2 3)");
    try expectEval(vm, "(0 2 _ til 5) 0", "0 1");
    try expectEvalMode(vm, .k, "3_!3", "`long$()");
    try expectEvalMode(vm, .k, "0_!3", "0 1 2");
    try expectEvalMode(vm, .k, "n:2;(0;n)_x:!5", "(0 1;2 3 4)");
    try testing.expectError(error.domain, vm.evalSource("2 0 _ til 4", .q, "<test>"));
    try testing.expectError(error.domain, vm.evalSource("2 5 _ til 4", .q, "<test>"));
    try testing.expectError(error.domain, vm.evalSource("0N 2 _ til 4", .q, "<test>"));
    try testing.expectError(error.domain, vm.evalSource("-1 2 _ til 4", .q, "<test>"));
    try testing.expectError(error.domain, vm.evalSource("1 2 3 _ 1 1", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("0 2h _ til 4", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("1 _ 5", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("1 _ 1", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("\"a\" _ \"abc\"", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("(`a`b!1 2) _ 0", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("0N _ 1 2 3", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("1.5 _ 1 2 3", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("(0 1;2) _ 1 2 3", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("(`a`b`c!1 2 3) _ `a`c", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("(`a`b`c!1 2 3) _ enlist `a", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("`a _ (`a`b;1 2)", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("`a _ 1 2 3", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("`a _ `a`b", .q, "<test>"));
}

test "attributes, the vector conditional, roll and deal, internals and dictionary amend follow q" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    // Attributes.
    try expectEval(vm, "`s#1 2 3", "`s#1 2 3");
    try expectEval(vm, "`s#1 1 2", "`s#1 1 2");
    try expectEval(vm, "`u#1 2 3", "`u#1 2 3");
    try expectEval(vm, "`p#1 1 2 2", "`p#1 1 2 2");
    try expectEval(vm, "`g#1 2 1", "`g#1 2 1");
    try expectEval(vm, "`s#\"abc\"", "`s#\"abc\"");
    try expectEval(vm, "`s#`a`b", "`s#`a`b");
    try expectEval(vm, "`s#()", "`s#()");
    try expectEval(vm, "`s#`long$()", "`s#`long$()");
    try expectEval(vm, "`s#01b", "`s#01b");
    try expectEval(vm, "`s#0x0102", "`s#0x0102");
    try expectEval(vm, "`s#(1;2)", "`s#1 2");
    try expectEval(vm, "`s#(1;2.5)", "`s#(1;2.5)");
    try expectEval(vm, "`s#(1;`a)", "`s#(1;`a)");
    try expectEval(vm, "`s#(1 2;3 4)", "`s#(1 2;3 4)");
    try expectEval(vm, "`s#enlist 1", "`s#,1");
    try expectEval(vm, "`#1 2 3", "1 2 3");
    try expectEval(vm, "`s#`a`b!1 2", "`s#`s#`a`b!1 2");
    try expectEval(vm, "`s#`s#1 2 3", "`s#1 2 3");
    try expectEval(vm, "`u#`s#1 2 3", "`u#1 2 3");
    try expectEval(vm, "attr 1 2 3", "`");
    try expectEval(vm, "attr `s#1 2 3", "`s");
    try expectEval(vm, "attr `u#1 2 3", "`u");
    try expectEval(vm, "attr `p#1 1 2", "`p");
    try expectEval(vm, "attr `g#1 2 1", "`g");
    try expectEval(vm, "attr 1", "`");
    try expectEval(vm, "attr ()", "`");
    try expectEval(vm, "attr `a`b!1 2", "`");
    try expectEval(vm, "attr {x}", "`");
    try expectEval(vm, "attr \"abc\"", "`");
    try expectEval(vm, "attr `s#`a`b!1 2", "`s");
    try expectEval(vm, "attr key `s#`a`b!1 2", "`s");
    try expectEval(vm, "attr value `s#`a`b!1 2", "`");
    try expectEval(vm, "attr `s#0N 1 2", "`s");
    try expectEval(vm, "attr `s#0n 1 2", "`s");
    try expectEval(vm, "attr `u#(1;`a;1 2)", "`u");
    try expectEval(vm, "attr `s#`u#1 2 3", "`s");
    try expectEval(vm, "attr `u#`s#1 2 3", "`u");
    try expectEval(vm, "attr `s#2023.01.01 2023.01.02", "`s");
    // Sorted, parted and grouped are set on the value itself; unique makes a copy.
    try expectEval(vm, "x:1 2 3;y:`s#x;attr x", "`s");
    try expectEval(vm, "x:1 2 3;y:`u#x;attr x", "`");
    try expectEval(vm, "a:b:1 2 3;c:`s#a;attr a", "`s");
    try expectEval(vm, "f:{`s#x};z:1 2 3;f z;attr z", "`s");
    try expectEval(vm, "g:{`s#1 2 3};attr g[]", "`s");
    try expectEval(vm, "attr 1_`s#1 2 3", "`");
    try expectEval(vm, "attr -1_`s#1 2 3", "`");
    try expectEval(vm, "attr 2#`s#1 2 3", "`");
    try expectEval(vm, "attr (`s#1 2 3)+1", "`");
    try expectEval(vm, "attr (`s#1 2 3),4", "`");
    try expectEval(vm, "attr (`s#1 2 3)[0 1]", "`");
    try expectEval(vm, "attr reverse `s#1 2 3", "`");
    try expectEval(vm, "attr @[`s#1 2 3;0;:;5]", "`");
    try expectEval(vm, "attr 0#`s#1 2 3", "`");
    try expectEval(vm, "attr (`s#1 2 3)=1 2 3", "`");
    try expectEval(vm, "attr {x} each `s#1 2 3", "`");
    try expectEval(vm, "attr enlist `s#1 2", "`");
    try expectEval(vm, "attr 1 2 3,`s#1 2 3", "`");
    try expectEval(vm, "attr $[1b;`s#1 2 3;0]", "`s");
    try expectEval(vm, "attr {x}`s#1 2 3", "`s");
    try expectEval(vm, "attr (::)`s#1 2 3", "`s");
    try expectEval(vm, "attr `s#1 2 3 4 5", "`s");
    try expectEval(vm, "attr distinct `s#1 2 3", "`s");
    try expectEvalMode(vm, .k, "asc9:{$[99h=@x;(!x)[i]!`s#r i:<r:. x;`s=-2!x;x;0h>@x;'`rank;`s#x@<x]};asc9 3 1 2", "`s#1 2 3");
    try expectEvalMode(vm, .k, "asc9 `a`b!3 1", "`b`a!`s#1 3");
    try expectEval(vm, "(`s#1 2 3) bin 2", "1");
    try expectEval(vm, "(`s#1 2 3)~1 2 3", "1b");
    try expectEval(vm, "1 2 3~`s#1 2 3", "1b");
    try expectEval(vm, "(`s#1 2 3)=1 2 3", "111b");
    try expectEval(vm, "-3!`s#1 2 3", "\"`s#1 2 3\"");
    try expectEval(vm, "-3!enlist `s#1 2", "\",`s#1 2\"");
    try expectEval(vm, "-3!(`s#1 2;3)", "\"(`s#1 2;3)\"");
    try expectEval(vm, "-3!`s#`a`b!1 2", "\"`s#`s#`a`b!1 2\"");
    try expectEval(vm, "string `s#1 2 3", "(,\"1\";,\"2\";,\"3\")");
    try expectEval(vm, "@[{`s#x};3 2 1;{x}]", "\"s-fail\"");
    try expectEval(vm, "@[{`s#x};1 0N 2;{x}]", "\"s-fail\"");
    try expectEval(vm, "@[{`s#x};101b;{x}]", "\"s-fail\"");
    try expectEval(vm, "@[{`s#x};\"ba\";{x}]", "\"s-fail\"");
    try expectEval(vm, "@[{`s#x};`b`a;{x}]", "\"s-fail\"");
    try expectEval(vm, "@[{`s#x};(2.5;1);{x}]", "\"s-fail\"");
    try expectEval(vm, "@[{`s#x};(3 4;1 2);{x}]", "\"s-fail\"");
    try expectEval(vm, "@[{`s#x};`b`a!1 2;{x}]", "\"s-fail\"");
    try expectEval(vm, "@[{`u#x};1 1 2;{x}]", "\"u-fail\"");
    try expectEval(vm, "@[{`p#x};1 2 1;{x}]", "\"u-fail\"");
    try expectEval(vm, "@[{`u#x};(1;`a;1);{x}]", "\"u-fail\"");
    try testing.expectError(error.type, vm.evalSource("`s#1", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("`z#1 2 3", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("`s`u#1 2 3", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("`g#`a`b!1 2", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("`u#`a`b!1 2", .q, "<test>"));

    // The vector conditional.
    try expectEval(vm, "?[101b;1 2 3;4 5 6]", "1 5 3");
    try expectEval(vm, "?[101b;1;4 5 6]", "1 5 1");
    try expectEval(vm, "?[101b;1 2 3;0]", "1 0 3");
    try expectEval(vm, "?[101b;1;0]", "1 0 1");
    try expectEval(vm, "?[1b;1;2]", "1");
    try expectEval(vm, "?[0b;1;2]", "2");
    try expectEval(vm, "?[101b;1 2 3;4 5 6f]", "1 5 3f");
    try expectEval(vm, "?[101b;1 2 3h;4 5 6]", "1 5 3");
    try expectEval(vm, "?[101b;\"abc\";\"xyz\"]", "\"ayc\"");
    try expectEval(vm, "?[101b;(1;`a;3);(4;5;`c)]", "1 5 3");
    try expectEval(vm, "?[`boolean$();();()]", "()");
    try expectEval(vm, "?[101b;(1 2;3 4;5 6);(7 8;9 10;11 12)]", "(1 2;9 10;5 6)");
    try expectEval(vm, "?[10b;1 2;3 4]", "1 4");
    try expectEval(vm, "type ?[101b;1 2 3;4 5 6]", "7h");
    try testing.expectError(error.type, vm.evalSource("?[1 0 1;1 2 3;4 5 6]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("?[101b;`a`b`c;4 5 6]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("?[101b;1 2 3;`a`b`c]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("?[1;1 2 3;4 5 6]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("?[(1;0;1);1 2 3;4 5 6]", .q, "<test>"));
    try testing.expectError(error.length, vm.evalSource("?[101b;1 2;4 5 6]", .q, "<test>"));
    try testing.expectError(error.length, vm.evalSource("?[`boolean$();1 2 3;4 5 6]", .q, "<test>"));
    try testing.expectError(error.length, vm.evalSource("?[101b;();()]", .q, "<test>"));

    // Roll and deal: types, counts and ranges, as the generator is not q's.
    try expectEval(vm, "type 0?10", "7h");
    try expectEval(vm, "type 0?1.0", "9h");
    try expectEval(vm, "type 0?`a`b", "11h");
    try expectEval(vm, "type 0?0b", "1h");
    try expectEval(vm, "type 5?10", "7h");
    try expectEval(vm, "type 5?1.0", "9h");
    try expectEval(vm, "type 5?`a`b", "11h");
    try expectEval(vm, "type 5?0b", "1h");
    try expectEval(vm, "type 5?\"ab\"", "10h");
    try expectEval(vm, "type 5?1h", "5h");
    try expectEval(vm, "type 5?1i", "6h");
    try expectEval(vm, "type 5?2023.01.01", "14h");
    try expectEval(vm, "type 5?1e", "8h");
    try expectEval(vm, "type 5?0x10", "4h");
    try expectEval(vm, "type 5?12:00", "17h");
    try expectEval(vm, "type 5?0D01", "16h");
    try expectEval(vm, "type 5?0x0102", "4h");
    try expectEval(vm, "type 5?0", "7h");
    try expectEval(vm, "type 2?1b", "1h");
    try expectEval(vm, "count 5?10", "5");
    try expectEval(vm, "count -5?10", "5");
    try expectEval(vm, "count -5?`a`b`c`d`e`f", "5");
    try expectEval(vm, "count 5h?10", "5");
    try expectEval(vm, "count 5i?10", "5");
    try expectEval(vm, "count 1?10", "1");
    try expectEval(vm, "sum -3?3", "3");
    try expectEval(vm, "count distinct -5?10", "5");
    try expectEval(vm, "count distinct -5?`a`b`c`d`e", "5");
    try expectEval(vm, "-1<min 5?10", "1b");
    try expectEval(vm, "10>max 5?10", "1b");
    try expectEval(vm, "1>max 5?1.0", "1b");
    try expectEval(vm, "min (5?1 2) in 1 2", "1b");
    try expectEval(vm, "5?()", "(();();();();())");
    try expectEval(vm, "count 5?`3", "5");
    try expectEval(vm, "count string first 5?`3", "3");
    try expectEval(vm, "count string first 5?`8", "8");
    try expectEval(vm, "sum 0N?10", "45");
    try expectEval(vm, "count 0N?10", "10");
    try expectEval(vm, "value \"\\\\S\"", "-314159i");
    try expectEval(vm, "value \"\\\\S 42\"", "::");
    try expectEval(vm, "value \"\\\\S\"", "42i");
    try expectEval(vm, "value \"\\\\S 1\";r1:5?100;value \"\\\\S 1\";r1~5?100", "1b");
    try expectEval(vm, "@[{5?x};`a;{x}]", ",\"a\"");
    try expectEval(vm, "@[{5?x};`9;{x}]", ",\"9\"");
    try testing.expectError(error.length, vm.evalSource("-5?4", .q, "<test>"));
    try testing.expectError(error.length, vm.evalSource("-6?`a`b`c`d`e", .q, "<test>"));
    try testing.expectError(error.domain, vm.evalSource("5?-1", .q, "<test>"));
    try testing.expectError(error.domain, vm.evalSource("5?0N", .q, "<test>"));
    try testing.expectError(error.domain, vm.evalSource("5?`0", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("5.0?10", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("-3?1.0", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("?[3;1;2]", .q, "<test>"));

    // Internals.
    try expectEval(vm, "-1!`a", "`:a");
    try expectEval(vm, "-1!`:a", "`:a");
    try expectEval(vm, "-1!`", "`");
    try expectEval(vm, "-1!`:", "`:");
    try expectEval(vm, "-1!`a.b", "`:a.b");
    try expectEval(vm, "type -1!`a", "-11h");
    try expectEval(vm, "-15!\"abc\"", "0x900150983cd24fb0d6963f7d28e17f72");
    try expectEval(vm, "-15!\"\"", "0xd41d8cd98f00b204e9800998ecf8427e");
    try expectEval(vm, "md5 \"abc\"", "0x900150983cd24fb0d6963f7d28e17f72");
    try expectEval(vm, "-33!\"abc\"", "0xa9993e364706816aba3e25717850c26c9cd0d89d");
    try expectEval(vm, "-33!\"\"", "0xda39a3ee5e6b4b0d3255bfef95601890afd80709");
    try expectEval(vm, "-32!\"abc\"", "\"YWJj\"");
    try expectEval(vm, "-32!\"ab\"", "\"YWI=\"");
    try expectEval(vm, "-32!\"\"", "\"\"");
    try expectEval(vm, "-32!0x616263", "\"YWJj\"");
    try expectEval(vm, "-24!\"1+1\"", "\"1+1\"");
    try expectEval(vm, "-24!(+;1;2)", "3");
    try expectEval(vm, "-24!1", "1");
    try expectEval(vm, "-6!\"1+1\"", "\"1+1\"");
    try expectEval(vm, "-6!1", "1");
    try expectEval(vm, "-6!(::;1)", "1");
    try expectEval(vm, "-6!(1;2)", "1 2");
    try expectEval(vm, "-6!()", "()");
    try expectEval(vm, "-6!(\"neg\";1)", "\"e\"");
    try expectEval(vm, "-105!({x+y};(1;2);{x})", "3");
    try expectEval(vm, "-105!({x};enlist 1;{x})", "1");
    try expectEval(vm, "-105!({'`oops};enlist 1;{[m;b]m})", "\"oops\"");
    try expectEval(vm, "-105!({'x};enlist 1;{[m;b]m})", "\"stype\"");
    try testing.expectError(error.rank, vm.evalSource("-105!({'`oops};enlist 1;{x})", .q, "<test>"));
    try expectEval(vm, "-105!({'x};enlist 1;{y})", "()");
    try testing.expectError(error.type, vm.evalSource("-1!`a`b", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("-1!\"a\"", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("-1!1", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("-15!`a", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("-15!1", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("-15!0x616263", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("-32!\"a\"", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("-32!`a", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("-105!(1;2;3)", .q, "<test>"));
    try testing.expectError(error.identifier, vm.evalSource("-6!(`neg;1)", .q, "<test>"));

    // Amend by key.
    try expectEval(vm, "@[`a`b!1 2;`a;:;5]", "`a`b!5 2");
    try expectEval(vm, "@[`a`b!1 2;`c;:;5]", "`a`b`c!1 2 5");
    try expectEval(vm, "@[`a`b!1 2;`a`c;:;5 6]", "`a`b`c!5 2 6");
    try expectEval(vm, "@[`a`b!1 2;`a;+;5]", "`a`b!6 2");
    try expectEval(vm, "@[`a`b!1 2;`c;+;5]", "`a`b`c!1 2 5");
    try expectEval(vm, "@[`a`b!1 2;`a;neg]", "`a`b!-1 2");
    try expectEval(vm, ".[`a`b!(1 2;3 4);(`a;1);:;9]", "`a`b!(1 9;3 4)");
    try expectEval(vm, ".[`a`b!1 2;();:;3]", "3");
    try expectEval(vm, ".[`a`b!1 2;enlist `a;:;9]", "`a`b!9 2");
    try expectEval(vm, "d:`a`b!1 2;d[`a]:5;d", "`a`b!5 2");
    try expectEval(vm, "d[`c]:7;d", "`a`b`c!5 2 7");
    try expectEval(vm, "d[`b]+:10;d", "`a`b`c!5 12 7");
    try expectEval(vm, "d[`x]+:1;d", "`a`b`c`x!5 12 7 1");
    try expectEval(vm, "@[`a`b!(1 2;3 4);`a;:;9]", "`a`b!(9;3 4)");
    try expectEval(vm, "@[`a`b!(1 2;3 4);`a;:;9 8]", "`a`b!(9 8;3 4)");
    try expectEval(vm, "@[`a`b!(1 2;3 4);`c;:;9 8]", "`a`b`c!(1 2;3 4;9 8)");
    try expectEval(vm, "@[`a`b!(1 2;3 4);`c;:;9]", "`a`b`c!(1 2;3 4;9)");
    try expectEval(vm, "@[`a`b!(1;`c);`d;:;9]", "`a`b`d!(1;`c;9)");
    try expectEval(vm, "@[1 2!3 4;1;:;5]", "1 2!5 4");
    try expectEval(vm, "@[1 2!3 4;5;:;5]", "1 2 5!3 4 5");
    try expectEval(vm, "@[`a`b!1 2;`a`a;+;1 1]", "`a`b!3 2");
    try expectEval(vm, "@[`a`b!1 2;`a`b`c;:;5 6 7]", "`a`b`c!5 6 7");
    try expectEval(vm, "@[`a`b!1 2;`;:;5]", "`a`b`!1 2 5");
    try expectEval(vm, "@[`a`b!1 2;(`a;`b);:;(5;6)]", "`a`b!5 6");
    try testing.expectError(error.length, vm.evalSource(".[`a`b!(1 2;3 4);(`c;1);:;9]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource(".[`a`b!1 2;(`a;`b);:;9]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("@[`a`b!1 2;0;:;5]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("@[`a`b!1 2;`a;:;`x]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("@[`a`b!1 2;`c;:;`x]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("@[`a`b!1 2;`c;:;1.5]", .q, "<test>"));
}

test "the internal functions hcount, host, addr, gc, JSON, ts, gzip and ld follow q" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    // Files, hosts and gc. The file comes from the test itself, through the shell.
    try expectEval(vm, "value \"\\\\sh -c 'printf hello\\\\\\\\nworld\\\\\\\\n >/tmp/openq_hc_test.txt'\"", "()");
    try expectEval(vm, "-7!`:/tmp/openq_hc_test.txt", "12");
    try expectEval(vm, "hcount `:/tmp/openq_hc_test.txt", "12");
    try expectEval(vm, "@[-7!;`:/tmp/openq_nope_test.txt;{x}]", "\"/tmp/openq_nope_test.txt. OS reports: No such file or directory\"");
    try expectEval(vm, "@[-7!;`:/tmp;{x}]", "\"/tmp. OS reports: Is a directory\"");
    try testing.expectError(error.type, vm.evalSource("-7!\"/tmp\"", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("-7!1", .q, "<test>"));
    try expectEval(vm, "-12!2130706433i", "`localhost");
    try expectEval(vm, "-12!16777343i", "`1.0.0.127");
    try expectEval(vm, "-12!0i", "`0.0.0.0");
    try expectEval(vm, "-13!`localhost", "2130706433i");
    try expectEval(vm, "-13!`LOCALHOST", "2130706433i");
    try expectEval(vm, "-13!`", "2130706433i");
    try expectEval(vm, "-13!`127.0.0.1", "2130706433i");
    try expectEval(vm, "-13!`nope.invalid", "-1i");
    try expectEval(vm, "type -13!`localhost", "-6h");
    try testing.expectError(error.type, vm.evalSource("-12!2130706433", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("-12!`localhost", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("-13!\"localhost\"", .q, "<test>"));
    try expectEval(vm, "-20!0", "0");
    try expectEval(vm, "-20!1", "0");
    try testing.expectError(error.nyi, vm.evalSource("-100!\"a:1\"", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("-101!\"a:1\"", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("-104!(1;2;3)", .q, "<test>"));
    try testing.expectError(error.nyi, vm.evalSource("-37!{x}", .q, "<test>"));

    // JSON in.
    try expectEval(vm, "-29!\"{\\\"a\\\":1,\\\"b\\\":[1,2.5,\\\"x\\\",true,null],\\\"c\\\":{\\\"d\\\":\\\"e\\\"}}\"", "`a`b`c!(1f;(1f;2.5;,\"x\";1b;0n);(,`d)!,,\"e\")");
    try expectEval(vm, "-29!\"[1,2,3]\"", "1 2 3f");
    try expectEval(vm, "-29!\"[1,2.5]\"", "1 2.5");
    try expectEval(vm, "-29!\"1.5\"", "1.5");
    try expectEval(vm, "-29!\"\\\"abc\\\"\"", "\"abc\"");
    try expectEval(vm, "-29!\"true\"", "1b");
    try expectEval(vm, "-29!\"null\"", "0n");
    try expectEval(vm, "-29!\"[]\"", "()");
    try expectEval(vm, "-29!\"{}\"", "(`symbol$())!()");
    try expectEval(vm, "-29!\"[\\\"a\\\",\\\"b\\\"]\"", "(,\"a\";,\"b\")");
    try expectEval(vm, "-29!\"[\\\"ab\\\",\\\"cd\\\"]\"", "(\"ab\";\"cd\")");
    try expectEval(vm, "-29!\"[true,false]\"", "10b");
    try expectEval(vm, "-29!\"[null,1]\"", "0n 1");
    try expectEval(vm, "-29!\"[1,\\\"a\\\"]\"", "(1f;,\"a\")");
    try expectEval(vm, "-29!\"1e3\"", "1000f");
    try expectEval(vm, "-29!\"-0.5\"", "-0.5");
    try expectEval(vm, "-29!\"[-1,-2]\"", "-1 -2f");
    try expectEval(vm, "-29!\"\\\"a\\\\nb\\\"\"", "\"a\\nb\"");
    try expectEval(vm, "-29!\"\\\"a\\\\tb\\\"\"", "\"a\\tb\"");
    try expectEval(vm, "-29!\"\\\"\\\\u0041\\\"\"", ",\"A\"");
    try expectEval(vm, "-29!\"\\\"\\\\u00e9\\\"\"", "\"\\303\\251\"");
    try expectEval(vm, "-29!\"\\\"\\\\/\\\"\"", ",\"/\"");
    try expectEval(vm, "-29!\"\\\"\\\\b\\\\f\\\"\"", "\"\\010\\014\"");
    try expectEval(vm, "-29!\" [1 , 2] \"", "1 2f");
    try expectEval(vm, "-29!\"[[1,2],[3]]\"", "(1 2f;,3f)");
    try expectEval(vm, "-29!\"[[1,2],[3,4]]\"", "(1 2f;3 4f)");
    try expectEval(vm, "-29!\"[[],{}]\"", "(();(`symbol$())!())");
    try expectEval(vm, "-29!\"[1,[2]]\"", "(1f;,2f)");
    try expectEval(vm, "-29!\"[1.0,2.0]\"", "1 2f");
    try expectEval(vm, "-29!\"{\\\"b\\\":1,\\\"a\\\":2}\"", "`b`a!1 2f");
    try expectEval(vm, "-29!\"{\\\"a\\\":1,\\\"a\\\":2}\"", "`a`a!1 2f");
    try expectEval(vm, "-29!\"{\\\"a\\\":[1,2]}\"", "(,`a)!,1 2f");
    try expectEval(vm, "-29!\"{\\\"a\\\":null}\"", "(,`a)!,0n");
    try expectEval(vm, "-29!\"[\\\"a\\\"]\"", ",,\"a\"");
    try expectEval(vm, "-29!\"[\\\"\\\"]\"", ",\"\"");
    try expectEval(vm, "-29!\"\\\"\\\"\"", "\"\"");
    try expectEval(vm, "-29!\"[true,1]\"", "(1b;1f)");
    try expectEval(vm, "-29!\"[null,null]\"", "0n 0n");
    try expectEval(vm, "-29!\"12345678901234567890\"", "9.223372e+18");
    try expectEval(vm, "-29!\"[1,1e400]\"", "1 0w");
    try expectEval(vm, "-29!0x5b312c325d", "1 2f");
    try expectEval(vm, "type -29!\"[1,2]\"", "9h");
    try expectEval(vm, "type -29!\"{}\"", "99h");
    try expectEval(vm, "@[-29!;\"bad\";{x}]", "\"illegal char b at 0\"");
    try expectEval(vm, "@[-29!;\"\";{x}]", "\"partial token at 1\"");
    try expectEval(vm, "@[-29!;\"[1,]\";{x}]", "\"illegal char ] at 3\"");
    try expectEval(vm, "@[-29!;\"{\\\"a\\\":1\";{x}]", "\"unclosed } at 7\"");
    try expectEval(vm, "@[-29!;\"[1,2\";{x}]", "\"unclosed ] at 5\"");
    try expectEval(vm, "@[-29!;\"[1 2]\";{x}]", "\"illegal char 2 at 3\"");
    try expectEval(vm, "@[-29!;\"tru\";{x}]", "\"illegal char   at 3\"");
    try expectEval(vm, "@[-29!;\"\\\"abc\";{x}]", "\"partial token at 5\"");
    try expectEval(vm, "@[-29!;\"1 2\";{x}]", "\"illegal char 2 at 2\"");
    try expectEval(vm, "@[-29!;\"[1,2]x\";{x}]", "\"illegal char x at 5\"");
    try expectEval(vm, "@[-29!;\"{\\\"a\\\":}\";{x}]", "\"illegal char } at 5\"");
    try expectEval(vm, "@[-29!;\"1e\";{x}]", "\"illegal char   at 2\"");
    try expectEval(vm, "@[-29!;\"0x10\";{x}]", "\"illegal char x at 1\"");
    try expectEval(vm, "@[-29!;\"01\";{x}]", "\"illegal char 1 at 1\"");
    try expectEval(vm, "@[-29!;\"1.\";{x}]", "\"illegal char   at 2\"");
    try expectEval(vm, "@[-29!;\".5\";{x}]", "\"illegal char . at 0\"");
    try expectEval(vm, "@[-29!;\"+1\";{x}]", "\"illegal char + at 0\"");
    try expectEval(vm, "@[-29!;\"1\";{x}]", "\"expected char or byte vector, but got type -10\"");
    try expectEval(vm, "@[-29!;1;{x}]", "\"expected char or byte vector, but got type -7\"");
    try expectEval(vm, "@[-29!;`a;{x}]", "\"expected char or byte vector, but got type -11\"");
    try expectEval(vm, "-29!\"[{\\\"a\\\":1},{\\\"b\\\":2}]\"", "((,`a)!,1f;(,`b)!,2f)");
    try expectEval(vm, "-29!\"[{\\\"a\\\":1},{\\\"a\\\":2}]\"", "+(,`a)!,1 2f");
    try expectEval(vm, "-29!\"{\\\"a\\\":{\\\"b\\\":1}}\"", "(,`a)!+(,`b)!,,1f");
    try expectEval(vm, "-29!\"{\\\"a\\\":[{\\\"b\\\":1}]}\"", "(,`a)!,+(,`b)!,,1f");
    try expectEval(vm, "-29!\"{\\\"a\\\":{\\\"b\\\":1},\\\"c\\\":2}\"", "`a`c!((,`b)!,1f;2f)");
    try expectEval(vm, "-29!\"[{},{}]\"", "((`symbol$())!();(`symbol$())!())");
    try expectEval(vm, "-31!(([]a:1 2;b:`x`y);(0#`)!())", "\"[{\\\"a\\\":1,\\\"b\\\":\\\"x\\\"},{\\\"a\\\":2,\\\"b\\\":\\\"y\\\"}]\"");

    // JSON out.
    try expectEval(vm, "o9:(0#`)!()", "::");
    try expectEval(vm, "-31!(1;o9)", ",\"1\"");
    try expectEval(vm, "-31!(1.5;o9)", "\"1.5\"");
    try expectEval(vm, "-31!(1.0;o9)", ",\"1\"");
    try expectEval(vm, "-31!(0N;o9)", "\"null\"");
    try expectEval(vm, "-31!(0n;o9)", "\"null\"");
    try expectEval(vm, "-31!(0Nh;o9)", "\"null\"");
    try expectEval(vm, "-31!(0w;o9)", "\"inf\"");
    try expectEval(vm, "-31!(-0w;o9)", "\"-inf\"");
    try expectEval(vm, "-31!(0W;o9)", "\"9223372036854775807\"");
    try expectEval(vm, "-31!(0Wh;o9)", "\"32767\"");
    try expectEval(vm, "-31!(1 2 3;o9)", "\"[1,2,3]\"");
    try expectEval(vm, "-31!(1 2.5;o9)", "\"[1,2.5]\"");
    try expectEval(vm, "-31!(1 0N 2;o9)", "\"[1,null,2]\"");
    try expectEval(vm, "-31!(0.1;o9)", "\"0.1\"");
    try expectEval(vm, "-31!(1e10;o9)", "\"1e+10\"");
    try expectEval(vm, "-31!(1e-7;o9)", "\"1e-07\"");
    try expectEval(vm, "-31!(1e-4;o9)", "\"0.0001\"");
    try expectEval(vm, "-31!(123456789.123;o9)", "\"1.234568e+08\"");
    try expectEval(vm, "-31!(1234567.8;o9)", "\"1234568\"");
    try expectEval(vm, "-31!(0.30000000000000004;o9)", "\"0.3\"");
    try expectEval(vm, "value \"\\\\P 17\";r9:-31!(0.1;o9);value \"\\\\P 7\";r9", "\"0.10000000000000001\"");
    try expectEval(vm, "-31!(1h;o9)", ",\"1\"");
    try expectEval(vm, "-31!(1.5e;o9)", "\"1.5\"");
    try expectEval(vm, "-31!(\"abc\";o9)", "\"\\\"abc\\\"\"");
    try expectEval(vm, "-31!(\"a\";o9)", "\"\\\"a\\\"\"");
    try expectEval(vm, "-31!(\"\";o9)", "\"\\\"\\\"\"");
    try expectEval(vm, "-31!(`abc;o9)", "\"\\\"abc\\\"\"");
    try expectEval(vm, "-31!(`;o9)", "\"\\\"\\\"\"");
    try expectEval(vm, "-31!(`a`b;o9)", "\"[\\\"a\\\",\\\"b\\\"]\"");
    try expectEval(vm, "-31!(``a;o9)", "\"[\\\"\\\",\\\"a\\\"]\"");
    try expectEval(vm, "-31!(1b;o9)", "\"true\"");
    try expectEval(vm, "-31!(101b;o9)", "\"[true,false,true]\"");
    try expectEval(vm, "-31!(`a`b!1 2;o9)", "\"{\\\"a\\\":1,\\\"b\\\":2}\"");
    try expectEval(vm, "-31!(1 2!3 4;o9)", "\"{\\\"1\\\":3,\\\"2\\\":4}\"");
    try expectEval(vm, "-31!(`a`b!(1 2;\"x\");o9)", "\"{\\\"a\\\":[1,2],\\\"b\\\":\\\"x\\\"}\"");
    try expectEval(vm, "-31!((1;`a;\"b\";2.5);o9)", "\"[1,\\\"a\\\",\\\"b\\\",2.5]\"");
    try expectEval(vm, "-31!((`a`b!1 2;3);o9)", "\"[{\\\"a\\\":1,\\\"b\\\":2},3]\"");
    try expectEval(vm, "-31!(();o9)", "\"[]\"");
    try expectEval(vm, "-31!(`long$();o9)", "\"[]\"");
    try expectEval(vm, "-31!((`symbol$())!();o9)", "\"{}\"");
    try expectEval(vm, "-31!(2023.01.01;o9)", "\"\\\"2023-01-01\\\"\"");
    try expectEval(vm, "-31!(2023.01.01 2023.01.02;o9)", "\"[\\\"2023-01-01\\\",\\\"2023-01-02\\\"]\"");
    try expectEval(vm, "-31!(2023.01m;o9)", "\"\\\"2023-01\\\"\"");
    try expectEval(vm, "-31!(12:00;o9)", "\"\\\"12:00\\\"\"");
    try expectEval(vm, "-31!(12:00:00;o9)", "\"\\\"12:00:00\\\"\"");
    try expectEval(vm, "-31!(12:00:00.123;o9)", "\"\\\"12:00:00.123\\\"\"");
    try expectEval(vm, "-31!(2023.01.01T12;o9)", "\"\\\"2023-01-01T12:00:00.000\\\"\"");
    try expectEval(vm, "-31!(2023.01.01D12:34:56.123456789;o9)", "\"\\\"2023-01-01T12:34:56.123456789\\\"\"");
    try expectEval(vm, "-31!(0D12:34:56.123456789;o9)", "\"\\\"0D12:34:56.123456789\\\"\"");
    try expectEval(vm, "-31!(-0D01;o9)", "\"\\\"-0D01:00:00.000000000\\\"\"");
    try expectEval(vm, "-31!(0Nd;o9)", "\"\\\"\\\"\"");
    try expectEval(vm, "-31!(0Np;o9)", "\"\\\"\\\"\"");
    try expectEval(vm, "-31!(0Nt;o9)", "\"\\\"\\\"\"");
    try expectEval(vm, "-31!(0Wd;o9)", "\"\\\"0000-00-00\\\"\"");
    try expectEval(vm, "-31!(0x0102;o9)", "\"[\\\"01\\\",\\\"02\\\"]\"");
    try expectEval(vm, "-31!(0x00;o9)", "\"\\\"00\\\"\"");
    try expectEval(vm, "-31!(\"a\\\"b\\\\c\\nd\";o9)", "\"\\\"a\\\\\\\"b\\\\\\\\c\\\\nd\\\"\"");
    try expectEval(vm, "-31!(\"\\t\\r\";o9)", "\"\\\"\\\\t\\\\r\\\"\"");
    try expectEval(vm, "-31!(\"\\000\\037\";o9)", "\"\\\"\\\\u0000\\\\u001f\\\"\"");
    try expectEval(vm, "-31!(\"\\177\";o9)", "\"\\\"\\177\\\"\"");
    try expectEval(vm, "-31!(`$\"a\\\"b\";o9)", "\"\\\"a\\\\\\\"b\\\"\"");
    try expectEval(vm, "-31!((::);o9)", "\"null\"");
    try expectEval(vm, "-31!({x};o9)", "\"\\\"{x}\\\"\"");
    try expectEval(vm, "-31!(+;o9)", "\"\\\"+\\\"\"");
    try expectEval(vm, "-31!((+;1);o9)", "\"[\\\"+\\\",1]\"");
    try expectEval(vm, "-31!((1 2;3 4);o9)", "\"[[1,2],[3,4]]\"");
    try testing.expectError(error.type, vm.evalSource("-31!(1;())", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("-31!(1;`a`b!1 2)", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("-31!1", .q, "<test>"));
    // A projection of enlist keeps only the slots it was given.
    try expectEval(vm, "enlist[;5] 1", "1 5");
    try expectEval(vm, "enlist[;5] 1 2", "(1 2;5)");
    try expectEval(vm, "enlist[;;5][1;2]", "1 2 5");
    try expectEval(vm, "enlist[1;2;3;4;5;6;7;8;9]", "1 2 3 4 5 6 7 8 9");
    try testing.expectError(error.rank, vm.evalSource("enlist[;5][1;2]", .q, "<test>"));
    try testing.expectError(error.rank, vm.evalSource("enlist[;;5][1;2;3]", .q, "<test>"));
    // JSON round trips through the seeded keywords q.k defines on these internals.
    try expectEvalMode(vm, .k, "j9:-31!(;(0#`)!())@;k9:-29!;k9 j9 `a`b!(1 2;\"x\")", "`a`b!(1 2f;,\"x\")");

    // ts.
    try expectEval(vm, "last -34!({x+y};(1;2))", "3");
    try expectEval(vm, "count first -34!({x+y};(1;2))", "2");
    try expectEval(vm, "type first -34!({x+y};(1;2))", "7h");
    try expectEval(vm, "-1<first first -34!({x};enlist 1)", "1b");
    try testing.expectError(error.type, vm.evalSource("-34!({x};1)", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("-34!(1;2)", .q, "<test>"));

    // gzip: q's header and trailer exactly, and zlib's deflate bytes for these inputs.
    try expectEval(vm, "-35!(6;0x616263)", "0x1f8b08000000000000134b4c4a0600c241243503000000");
    try expectEval(vm, "-35!(-1;0x616263)", "0x1f8b08000000000000134b4c4a0600c241243503000000");
    try expectEval(vm, "-35!(0;0x616263)", "0x1f8b0800000000000413010300fcff616263c241243503000000");
    try expectEval(vm, "-35!(1;0x616263)", "0x1f8b08000000000004134b4c4a0600c241243503000000");
    try expectEval(vm, "-35!(9;0x616263)", "0x1f8b08000000000002134b4c4a0600c241243503000000");
    try expectEval(vm, "-35!(6;0x)", "0x1f8b080000000000001303000000000000000000");
    try expectEval(vm, "type -35!(6;0x616263)", "4h");
    try expectEval(vm, "-35!(6;\"abc\")", "\"\\037\\213\\010\\000\\000\\000\\000\\000\\000\\023KLJ\\006\\000\\302A$5\\003\\000\\000\\000\"");
    try expectEval(vm, "-35!-35!(6;0x616263)", "0x616263");
    try expectEval(vm, "-35!-35!(6;\"abc\")", "\"abc\"");
    try expectEval(vm, "-35!0x1f8b08000000000000134b4c4a0600c241243503000000", "0x616263");
    try expectEval(vm, "(200#0x61)~-35!-35!(6;200#0x61)", "1b");
    try expectEval(vm, "(200#0x61)~-35!-35!(0;200#0x61)", "1b");
    try expectEval(vm, "(200#0x61)~-35!-35!(9;200#0x61)", "1b");
    try testing.expectError(error.domain, vm.evalSource("-35!(10;0x616263)", .q, "<test>"));
    try testing.expectError(error.domain, vm.evalSource("-35!(-2;0x616263)", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("-35!(6h;0x616263)", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("-35!(6;`long$())", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("-35!(6;0x616263;1)", .q, "<test>"));
    try testing.expectError(error.length, vm.evalSource("-35!0x616263", .q, "<test>"));
    try testing.expectError(error.length, vm.evalSource("-35!\"abc\"", .q, "<test>"));

    // ld.
    try expectEval(vm, "-39!(\"a:1\";\" +2\";\"b:2\")", "(1 3;(\"a:1\\n +2\";\"b:2\"))");
    try expectEval(vm, "-39!(\"a:1\";\"b:2\")", "(1 2;(\"a:1\";\"b:2\"))");
    try expectEval(vm, "-39!(\"a:1\";\"\";\"b:2\")", "(1 2 3;(\"a:1\";\"\";\"b:2\"))");
    try expectEval(vm, "-39!(\"a:1\";\"b:2 / c\";\"c:3\")", "(1 2 3;(\"a:1\";\"b:2 / c\";\"c:3\"))");
    try expectEval(vm, "-39!(\"a:{\";\" x\";\" }\")", "(,1;,\"a:{\\n x\\n }\")");
    try expectEval(vm, "-39!(\"a:1\";\"\\tb\")", "(,1;,\"a:1\\n b\")");
    try expectEval(vm, "-39!enlist \"\"", "(,1;,\"\")");
    try expectEval(vm, "-39!(\"\";\"\")", "(1 2;(\"\";\"\"))");
    try expectEval(vm, "-39!(\"\";\" x\")", "(`long$();())");
    try expectEval(vm, "-39!()", "(`long$();())");
    try expectEval(vm, "type -39!(\"a:1\";\"b:2\")", "0h");
    try testing.expectError(error.type, vm.evalSource("-39!\"a:1\"", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("-39!(\"a:1\";\" b\";\"c\")", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("-39!1", .q, "<test>"));
}

test "every operator projects on one argument as q does" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    for ([_][:0]const u8{ "+", "-", "*", "%", "&", "|", "^", "=", "<", ">", "$", ",", "#", "_", "~", "!", "?", "@", ".", "0:", "1:", "2:", "in", "bin", "like", "ss", "within", "cov", "setenv", "xexp", "div" }) |op| {
        const source = try std.fmt.allocPrintSentinel(testing.allocator, "{s}[1]", .{op}, 0);
        defer testing.allocator.free(source);
        try expectEval(vm, source, source);
        const typed = try std.fmt.allocPrintSentinel(testing.allocator, "type {s}[1]", .{op}, 0);
        defer testing.allocator.free(typed);
        try expectEval(vm, typed, "104h");
    }
    try expectEval(vm, ":[1]", ":[1]");
    try expectEval(vm, "type :[1]", "104h");
    try expectEval(vm, ":[1][2]", "2");
    try expectEval(vm, ":[;2]", ":[;2]");
    try expectEval(vm, ":[;2][1]", "2");
    try expectEval(vm, "value :[1]", "(:;1)");
    try expectEval(vm, "-3!(:[;1])", "\":[;1]\"");
    try expectEval(vm, "mmu[1]", "$[1]");
    try expectEval(vm, "and[1]", "&[1]");
    try expectEval(vm, "each[1]", "k){x'y}[1]");
    try expectEval(vm, "enlist[1]", ",1");
    try expectEval(vm, "type enlist[1]", "7h");
    try expectEval(vm, "+[]", "+[::]");
    try expectEval(vm, "(+)[]", "+[::]");
    try expectEval(vm, "type +[]", "104h");
    try expectEval(vm, "$[]", "$[::]");
    try expectEval(vm, "@[]", "@[::]");
    try expectEval(vm, "{x+y}[]", "{x+y}[::]");
    try expectEval(vm, "{x}[]", "::");
    try testing.expectError(error.type, vm.evalSource("neg[]", .q, "<test>"));
    // Projections of the overloaded operators apply as their two-argument forms.
    try expectEval(vm, "$[`long][1.5]", "2");
    try expectEval(vm, "![-3][1 2]", "\"1 2\"");
    try expectEval(vm, "![`a`b][1 2]", "`a`b!1 2");
    try expectEval(vm, "@[{x}][5]", "5");
    try expectEval(vm, ".[{x+y}][1 2]", "3");
    try expectEval(vm, "?[1 2 3][2]", "1");
    try expectEval(vm, "@[1 2 3][0]", "1");
    try expectEval(vm, "^[0][1 0N]", "1 0");
    try expectEval(vm, "#[2][1 2 3]", "1 2");
    try expectEval(vm, "_[2][1 2 3]", ",3");
    try expectEval(vm, "+[;2][1]", "3");
    try expectEval(vm, "$[;2]", "$[;2]");
    try expectEval(vm, "$[1;]", "$[1;]");
    try testing.expectError(error.type, vm.evalSource("$[1;2]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("$[1][2]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("$[;2][1]", .q, "<test>"));
    // `$` with three or more arguments is cond.
    try expectEval(vm, "$[1;2;3]", "2");
    try expectEval(vm, "$[1;;3]", "::");
    try expectEval(vm, "$[1;;]", "::");
    try expectEval(vm, "$[1;2;3;4]", "2");
    try testing.expectError(error.type, vm.evalSource("$[;;3]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("$[;;;;]", .q, "<test>"));
    // Holes project at any count; the functional forms are `type` off a table.
    try expectEval(vm, "?[;;3]", "?[;;3]");
    try expectEval(vm, "?[;;;]", "?[;;;]");
    try expectEval(vm, "?[1;;]", "?[1;;]");
    try expectEval(vm, "![;;;4]", "![;;;4]");
    try expectEval(vm, "![;;;;]", "![;;;;]");
    try expectEval(vm, "![1;;]", "![1;;]");
    try expectEval(vm, "@[;;;4]", "@[;;;4]");
    try expectEval(vm, "@[1;;;;]", "@[1;;;;]");
    try expectEval(vm, ".[;;;;;]", ".[;;;;;]");
    try expectEval(vm, "@[;;3]", "@[;;3]");
    try testing.expectError(error.type, vm.evalSource("?[;;;][1;2;3;4]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("?[1;2;3;4]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("?[1;2;3;4;5]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("![1;2;3;4]", .q, "<test>"));
    try testing.expectError(error.rank, vm.evalSource("![1;2;3]", .q, "<test>"));
    try testing.expectError(error.rank, vm.evalSource("![1;2;3;4;5]", .q, "<test>"));
    try testing.expectError(error.rank, vm.evalSource("@[1;2;3;4;5]", .q, "<test>"));
    // A value where amend wants a function.
    try testing.expectError(error.domain, vm.evalSource("@[1 2 3;0;3]", .q, "<test>"));
    try testing.expectError(error.length, vm.evalSource("@[1 2 3;0;3;4]", .q, "<test>"));
    try testing.expectError(error.identifier, vm.evalSource("@[1 2 3;0;`a;4]", .q, "<test>"));
    try testing.expectError(error.domain, vm.evalSource("@[;;3][1 2 3;0]", .q, "<test>"));
    try expectEval(vm, "@[1 2 3;0;1 2]", "2 2 3");
}

test "audit of q.k's definitions: what calling them uncovered" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    // In k mode `x_j` is three tokens whatever the name lookup re-lexes.
    try expectEvalMode(vm, .k, "j:1;{x_j}[2 3 4]", "2 4");
    try expectEvalMode(vm, .k, "f8:{$[^y;\"\";y<0;\"-\",f8[x;-y];y<1;1_f8[x;10+y];9e15>j:\"j\"$y*prd x#10f;(x_j),\".\",(x:-x)#j:$j;$y]}", "::");
    try expectEval(vm, "f8[2;3.14159]", "\"3.14\"");
    try expectEval(vm, "f8[2;3.0]", "\"3.00\"");
    try expectEval(vm, "f8[0;3.0]", "\"3.\"");
    // A `k)` prefix holds for the whole line.
    try expectEval(vm, "k)x:`a`b;`/:x", "`a.b");
    try expectEval(vm, "k)a1:1;b1:2", "::");
    try expectEval(vm, "b1", "2");
    // A symbol literal under an iterator compiles as the atom.
    try expectEvalMode(vm, .k, "{`/:x}[`a`b]", "`a.b");
    try expectEvalMode(vm, .k, "{`\\:x}[`a.b]", "`a`b");
    try expectEvalMode(vm, .k, "{`/:x,`$$y}[`a;1]", "`a.1");

    // An assignment is `::` as a statement and its value inside an expression: an amend
    // gives the new items.
    try expectEval(vm, "{a:1;b:a+:2;b}[]", "3");
    try expectEval(vm, "{a:1;b:a-:2;b}[]", "-1");
    try expectEval(vm, "{a:1 2;b:a,:3;b}[]", "1 2 3");
    try expectEval(vm, "{a:1 2;b:a[0]+:5;b}[]", "6");
    try expectEval(vm, "{a:1 2;b:a[0 1]+:5 6;b}[]", "6 8");
    try expectEval(vm, "{a:1 2;b:a[0]:5;b}[]", "5");
    try expectEval(vm, "{a:(1 2;3);b:a[0;1]:9;b}[]", "9");
    try expectEval(vm, "{a:1;a+:2}[]", "::");
    try expectEval(vm, "{a:1;a:2}[]", "2");
    try expectEval(vm, "a9:1;b9:a9+:2;b9", "3");
    try expectEval(vm, "a9:1 2;b9:a9[0]:7;b9", "7");
    try expectEval(vm, "a9:1 2;b9:a9,:3;b9", "1 2 3");
    try expectEval(vm, "value \"c8:1;c8+:1\"", "::");
    try expectEval(vm, "value \"(c8+:1)\"", "::");
    try expectEval(vm, "value \"c8:8\"", "::");
    try expectEval(vm, "value \"c8\"", "8");

    // Bare names in a lambda read its defining namespace; a symbol names a global in the
    // `\\d` namespace, so `set` from `.q` writes the root.
    try expectEval(vm, ".q.f9:{.[x;();:;y]}", "::");
    try expectEval(vm, "f9[`zz9;5]", "`zz9");
    try expectEval(vm, "zz9", "5");
    try expectEval(vm, ".q.g9:{get `zz9}", "::");
    try expectEval(vm, "g9[]", "5");
    try expectEval(vm, ".q.j9:{zz9}", "::");
    try expectEval(vm, "j9[]", "5");
    try expectEval(vm, ".q.zz9:7", "::");
    try expectEval(vm, "j9[]", "5");
    try expectEval(vm, ".q.l9:{.[`zz9;();:;6];zz9}", "::");
    try expectEval(vm, "l9[]", "7");
    try expectEval(vm, "zz9", "7");
    try expectEval(vm, ".q.zz9", "7");
    try expectEval(vm, ".q.n9:{value `zz9}", "::");
    try expectEval(vm, "n9[]", "6");
    try expectEval(vm, "\\d .foo9", "::");
    try expectEval(vm, "t0:{y0 x}", "::");
    try expectEval(vm, "\\d .", "::");
    try expectEval(vm, ".foo9.y0:{x*10}", "::");
    try expectEval(vm, ".foo9.t0 4", "40");

    // Over, scan and each-prior derived functions are monadic for repeat; each-prior of
    // a monadic function is each; a float on the left of scan is the weighted scan.
    try expectEval(vm, "1 (+':)/1 2 3", "1 3 5");
    try expectEval(vm, "1 (+/)/1 2 3", "6");
    try expectEval(vm, "2 (+\\)/1 2 3", "1 4 10");
    try expectEval(vm, "1 (+/:)/1 2 3", "7");
    try expectEvalMode(vm, .k, "x:2;y:3 1 2;(x-1)&':/y", "3 1 1");
    try expectEval(vm, "{x*2}':[1 2 3]", "2 4 6");
    try testing.expectError(error.rank, vm.evalSource("{x*2}':[1;1 2 3]", .q, "<test>"));
    try expectEval(vm, "0.5\\[1;1 2 3]", "1.5 2.75 4.375");
    try expectEval(vm, "1 (0.5)\\0.5 1 1.5", "1 1.5 2.25");
    try expectEvalMode(vm, .k, "ema9:{(*y)(1f-x)\\x*y};ema9[0.5;1 2 3]", "1 1.5 2.25");
    try testing.expectError(error.type, vm.evalSource("2\\[1;1 2 3]", .q, "<test>"));
    try testing.expectError(error.rank, vm.evalSource("0.5\\[1 2;1 2 3]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("0.5/[1;1 2 3]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("0.5\\[1 2 3]", .q, "<test>"));

    // Derived functions project on too few arguments.
    try expectEval(vm, "(+')[1]", "+'[1]");
    try expectEval(vm, "(+')[1] 2", "3");
    try expectEval(vm, "value (+')[1]", "(+';1)");
    try expectEval(vm, "(!')[-1]", "!'[-1]");
    try expectEvalMode(vm, .k, "(-1!')`a`b", "`:a`:b");
    try expectEvalMode(vm, .k, "(\"s\"$-1!')`a`b", "`:a`:b");
    try expectEvalMode(vm, .k, "-3!\"s\"$-1!'", "![-3]$[\"s\"]!'[-1]");
    try expectEval(vm, "(+/:)[1]", "+/:[1]");
    try expectEval(vm, "(+/:)[1] 2 3", "3 4");
    try expectEval(vm, "(+':)[1]", "1");
    try expectEval(vm, "({x+y}')[1]", "{x+y}'[1]");
    try expectEvalMode(vm, .k, "+\" \"\\:'(\"htm text/html\";\"csv text/csv\")", "((\"htm\";\"csv\");(\"text/html\";\"text/csv\"))");

    // Min and max keep the wider type by type number.
    try expectEval(vm, "1b|1h", "1h");
    try expectEval(vm, "1b&2h", "1h");
    try expectEval(vm, "0x01|1h", "1h");
    try expectEval(vm, "1b|0x02", "0x02");
    try expectEval(vm, "1h|1i", "1i");
    try expectEval(vm, "1b|1", "1");
    try expectEval(vm, "1e|1", "1e");
    try expectEval(vm, "1h|1f", "1f");

    // The mathematical natives.
    try expectEval(vm, "abs -1", "1");
    try expectEval(vm, "abs -1h", "1h");
    try expectEval(vm, "abs -1.5e", "1.5e");
    try expectEval(vm, "abs 0N", "0N");
    try expectEval(vm, "abs -0W", "0W");
    try expectEval(vm, "abs 1b", "1i");
    try expectEval(vm, "abs \"a\"", "97i");
    try expectEval(vm, "abs -1 2", "1 2");
    try expectEval(vm, "abs (1;-2.5)", "(1;2.5)");
    try expectEval(vm, "abs `a`b!-1 2", "`a`b!1 2");
    try expectEval(vm, "abs -0D01", "0D01:00:00.000000000");
    try testing.expectError(error.type, vm.evalSource("abs `a", .q, "<test>"));
    try expectEval(vm, "sqrt 4", "2f");
    try expectEval(vm, "sqrt 4h", "2f");
    try expectEval(vm, "sqrt -1", "0n");
    try expectEval(vm, "sqrt 0N", "0n");
    try expectEval(vm, "sqrt 1 4", "1 2f");
    try expectEval(vm, "sqrt \"a\"", "9.848858");
    try expectEval(vm, "sqrt 1b", "1f");
    try expectEval(vm, "sqrt 2023.01.01", "91.65697");
    try testing.expectError(error.type, vm.evalSource("sqrt `a", .q, "<test>"));
    try expectEval(vm, "log 1", "0f");
    try expectEval(vm, "log 0", "-0w");
    try expectEval(vm, "log -1", "0n");
    try expectEval(vm, "exp 1", "2.718282");
    try expectEval(vm, "exp 0N", "0n");
    try expectEval(vm, "sin 0", "0f");
    try expectEval(vm, "cos 0", "1f");
    try expectEval(vm, "tan 0", "0f");
    try expectEval(vm, "asin 1", "1.570796");
    try expectEval(vm, "acos 1", "0f");
    try expectEval(vm, "atan 1", "0.7853982");
    try expectEval(vm, "atan 0N", "0n");
    try expectEval(vm, "var 1 2 3", "0.6666667");
    try expectEval(vm, "var 1 2 3h", "0.6666667");
    try expectEval(vm, "var 1", "0f");
    try expectEval(vm, "var 1 0N 3", "1f");
    try expectEval(vm, "var ()", "()");
    try testing.expectError(error.type, vm.evalSource("var `a", .q, "<test>"));
    try expectEval(vm, "dev 1 2 3", "0.8164966");
    try expectEval(vm, "cov[1 2 3;1 2 3]", "0.6666667");
    try expectEval(vm, "cov[1 2 3;3 2 1]", "-0.6666667");
    try expectEval(vm, "cor[1 2 3;1 2 3]", "1f");
    try expectEval(vm, "cor[1 2 3;3 2 1]", "-1f");
    try expectEval(vm, "cor[1 1 1;1 2 3]", "0n");
    try testing.expectError(error.length, vm.evalSource("cov[1 2;1 2 3]", .q, "<test>"));
    try expectEval(vm, "wsum[1 2;3 4]", "11f");
    try expectEval(vm, "wsum[1;3 4]", "7");
    try expectEval(vm, "wsum[1 2;3]", "9");
    try expectEval(vm, "wsum[1 2h;3 4h]", "11f");
    try expectEval(vm, "wsum[1 2.5;3 4]", "13f");
    try expectEval(vm, "wsum[1 0N;3 4]", "3f");
    try expectEval(vm, "wavg[1 2;3 4]", "3.666667");
    try expectEval(vm, "wavg[1 1;3 4]", "3.5");
    try expectEval(vm, "wavg[1 2;3]", "3f");
    try expectEval(vm, "7 div 2", "3");
    try expectEval(vm, "-7 div 2", "-4");
    try expectEval(vm, "7 div -2", "-4");
    try expectEval(vm, "7 div 0", "0W");
    try expectEval(vm, "7.5 div 2", "3f");
    try expectEval(vm, "7 div 2.5", "2");
    try expectEval(vm, "7h div 2", "3i");
    try expectEval(vm, "7i div 2", "3i");
    try expectEval(vm, "7 div 2h", "3");
    try expectEval(vm, "0N div 2", "0N");
    try expectEval(vm, "7 div 0N", "0N");
    try expectEval(vm, "1b div 2", "0i");
    try expectEval(vm, "0x07 div 2", "3i");
    try expectEval(vm, "2023.01.05 div 2", "2011.07.04");
    try expectEval(vm, "\"a\" div 2", "48i");
    try expectEval(vm, "1 2 3 div 2", "0 1 1");
    try expectEvalMode(vm, .k, "mod9:{x-y*x div y};mod9[7;3]", "1");
    try expectEvalMode(vm, .k, "xbar9:{x*y div x:$[16h=abs[@x];\"j\"$x;x]};xbar9[5;12 17]", "10 15");
    try testing.expectError(error.type, vm.evalSource("7 div `a", .q, "<test>"));
    try expectEval(vm, "2 xexp 3", "8f");
    try expectEval(vm, "2 xexp 0.5", "1.414214");
    try expectEval(vm, "0 xexp 0", "1f");
    try expectEval(vm, "2 xexp -1", "0.5");
    try expectEval(vm, "2 xexp 0N", "0n");
    try expectEval(vm, "0N xexp 2", "0n");
    try expectEval(vm, "2h xexp 3", "8f");
    try expectEval(vm, "2 xexp 1 2", "2 4f");
    try expectEval(vm, "-8 xexp 1%3", "0n");
    try expectEval(vm, "1b xexp 2", "1f");
    try expectEvalMode(vm, .k, "xlog9:{log[y]%log x};xlog9[2;8]", "3f");
    try testing.expectError(error.type, vm.evalSource("2 xexp `a", .q, "<test>"));
    try expectEval(vm, "-35!(::)", "1b");
    try expectEval(vm, "(-35!)[]", "1b");
}

test "tables follow q: literals, flips, indexing, rows, columns and keyed tables" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "t:([]a:1 2;b:`x`y)", "::");
    try expectEval(vm, "t", "+`a`b!(1 2;`x`y)");
    try expectEval(vm, "-3!t", "\"+`a`b!(1 2;`x`y)\"");
    try expectEval(vm, "type t", "98h");
    try expectEval(vm, "count t", "2");
    try expectEval(vm, "parse \"([]a:1 2;b:3 4)\"", "(+:;(!;,`a`b;(enlist;1 2;3 4)))");
    try expectEval(vm, "parse \"([]a:1 2)\"", "(+:;(!;,,`a;(enlist;1 2)))");
    try expectEval(vm, "parse \"([k:1 2]a:3 4)\"", "(!;(+:;(!;,,`k;(enlist;1 2)));(+:;(!;,,`a;(enlist;3 4))))");
    try expectEval(vm, "parse \"([]a;b)\"", "(+:;(!;,`a`b;(enlist;`a;`b)))");
    try expectEval(vm, "([]a:())", "+(,`a)!,()");
    try expectEval(vm, "type ([]a:())", "98h");
    try expectEval(vm, "count ([]a:())", "0");
    try expectEval(vm, "a1:1 2;b1:3 4;([]a1;b1)", "+`a1`b1!(1 2;3 4)");
    try expectEval(vm, "([]a:1 2;b:3)", "+`a`b!(1 2;3 3)");
    try expectEval(vm, "([]1 2;3 4)", "+`x`x1!(1 2;3 4)");

    // Rows and columns.
    try expectEval(vm, "t 0", "`a`b!(1;`x)");
    try expectEval(vm, "t 1", "`a`b!(2;`y)");
    try expectEval(vm, "t 5", "`a`b!(0N;`)");
    try expectEval(vm, "t 0N", "`a`b!(0N;`)");
    try expectEval(vm, "t[-1]", "`a`b!(0N;`)");
    try expectEval(vm, "t`a", "1 2");
    try expectEval(vm, "t[`a`b]", "(1 2;`x`y)");
    try expectEval(vm, "t[`z]", "`long$()");
    try expectEval(vm, "t[0 1]", "+`a`b!(1 2;`x`y)");
    try expectEval(vm, "t[1 0]", "+`a`b!(2 1;`y`x)");
    try expectEval(vm, "t[0 0 1]", "+`a`b!(1 1 2;`x`x`y)");
    try expectEval(vm, "t[enlist 0]", "+`a`b!(,1;,`x)");
    try expectEval(vm, "t[`long$()]", "+`a`b!(`long$();`symbol$())");
    try expectEval(vm, "t[()]", "()");
    try expectEval(vm, "t[;`a]", "1 2");
    try expectEval(vm, "t[::;`a]", "1 2");
    try expectEval(vm, "t[0;`a]", "1");
    try expectEval(vm, "t[0 1;`a]", "1 2");
    try expectEval(vm, "t[0;`a`b]", "(1;`x)");
    try expectEval(vm, "t[0 1;`a`b]", "((1;`x);(2;`y))");
    try expectEval(vm, "t . (0;`a)", "1");
    try expectEval(vm, "t @ 0", "`a`b!(1;`x)");
    try expectEval(vm, "t[0][`a]", "1");
    try expectEval(vm, "(t 0)`b", "`x");
    try expectEval(vm, "count t 0", "2");
    try expectEval(vm, "key t 0", "`a`b");
    try expectEval(vm, "type t 0", "99h");
    try expectEval(vm, "t[0]~`a`b!(1;`x)", "1b");
    try expectEval(vm, "sum t[`a]", "3");
    try expectEval(vm, "t[`a]+1", "2 3");
    try testing.expectError(error.type, vm.evalSource("t[;0]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("t[`a;0]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("key t", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("value t", .q, "<test>"));

    // Flips and rows as dictionaries.
    try expectEval(vm, "flip t", "`a`b!(1 2;`x`y)");
    try expectEval(vm, "type flip t", "99h");
    try expectEval(vm, "flip `a`b!(1 2;`x`y)", "+`a`b!(1 2;`x`y)");
    try expectEval(vm, "flip `a`b!(1 2;3)", "+`a`b!(1 2;3 3)");
    try expectEval(vm, "flip (enlist `a)!enlist 1 2", "+(,`a)!,1 2");
    try expectEval(vm, "t~flip `a`b!(1 2;`x`y)", "1b");
    try expectEval(vm, "enlist `a`b!1 2", "+`a`b!(,1;,2)");
    try expectEval(vm, "enlist `a`b!(1 2;3)", "+`a`b!(,1 2;,3)");
    try expectEval(vm, "enlist 1 2!3 4", ",1 2!3 4");
    try expectEval(vm, "(`a`b!(1 2;3);`a`b!(4;5))", "+`a`b!((1 2;4);3 5)");
    try expectEval(vm, "type (`a`b!1 2;`a`b!3 4)", "98h");
    try testing.expectError(error.nyi, vm.evalSource("flip 1 2!(3 4;5 6)", .q, "<test>"));
    try testing.expectError(error.length, vm.evalSource("flip `a`b!(1 2;3 4 5)", .q, "<test>"));
    try testing.expectError(error.rank, vm.evalSource("flip `a`b!1 2", .q, "<test>"));
    try testing.expectError(error.rank, vm.evalSource("flip `a`b!(1;2)", .q, "<test>"));
    try testing.expectError(error.rank, vm.evalSource("flip (`symbol$())!()", .q, "<test>"));

    // Joins, takes, drops and the rest of the list primitives.
    try expectEval(vm, "t,t", "+`a`b!(1 2 1 2;`x`y`x`y)");
    try expectEval(vm, "t,'t", "+`a`b!(1 2;`x`y)");
    try expectEval(vm, "t,'([]c:5 6)", "+`a`b`c!(1 2;`x`y;5 6)");
    try expectEval(vm, "t,'([]a:5 6)", "+`a`b!(5 6;`x`y)");
    try expectEval(vm, "(2#t),t", "+`a`b!(1 2 1 2;`x`y`x`y)");
    try expectEval(vm, "@[,[t];([]c:1 2);{x}]", "\"mismatch\"");
    try expectEval(vm, "1#t", "+`a`b!(,1;,`x)");
    try expectEval(vm, "-1#t", "+`a`b!(,2;,`y)");
    try expectEval(vm, "1_t", "+`a`b!(,2;,`y)");
    try expectEval(vm, "`a`b#t", "+`a`b!(1 2;`x`y)");
    try expectEval(vm, "(enlist `b)#t", "+(,`b)!,`x`y");
    try expectEval(vm, "`a _ t", "+(,`b)!,`x`y");
    try expectEval(vm, "first t", "`a`b!(1;`x)");
    try expectEval(vm, "last t", "`a`b!(2;`y)");
    try expectEval(vm, "reverse t", "+`a`b!(2 1;`y`x)");
    try expectEval(vm, "t~t", "1b");
    try expectEval(vm, "string t", "+`a`b!((,\"1\";,\"2\");(,\"x\";,\"y\"))");
    try testing.expectError(error.type, vm.evalSource("`a#t", .q, "<test>"));

    // Each, arithmetic and aggregates over tables and dictionaries.
    try expectEval(vm, "count each t", "2 2");
    try expectEval(vm, "{x} each t", "+`a`b!(1 2;`x`y)");
    try expectEval(vm, "{x`a} each t", "1 2");
    try expectEval(vm, "first each t", "1 2");
    try expectEval(vm, "{x+1} each ([]a:1 2)", "+(,`a)!,2 3");
    try expectEval(vm, "{x} each `a`b!1 2", "`a`b!1 2");
    try expectEval(vm, "{x*2} each `a`b!1 2", "`a`b!2 4");
    try expectEval(vm, "{x+y}'[`a`b!1 2;10]", "`a`b!11 12");
    try expectEval(vm, "{x+y}'[`a`b!1 2;`a`b!10 20]", "`a`b!11 22");
    try expectEval(vm, "{x+y}'[`a`b!1 2;`b`a!10 20]", "`a`b!21 12");
    // `x@'!x` pairs the dictionary's values with its keys (`1@`a` is `type`); `(x@)'`
    // applies the projection to each key.
    try testing.expectError(error.type, vm.evalSource("x:`a`b!1 2;x@'!x", .k, "<test>"));
    try expectEvalMode(vm, .k, "x:`a`b!1 2;(x@)'!x", "1 2");
    try expectEval(vm, "sum ([]a:1 2;b:3 4)", "`a`b!3 7");
    try expectEval(vm, "max ([]a:1 2;b:3 4)", "`a`b!2 4");
    try expectEval(vm, "([]a:1 2)+1", "+(,`a)!,2 3");
    try expectEval(vm, "neg ([]a:1 2)", "+(,`a)!,-1 -2");
    try expectEval(vm, "t=t", "+`a`b!(11b;11b)");
    try expectEval(vm, "2*([]a:1 2)", "+(,`a)!,2 4");
    try expectEval(vm, "([]a:1 2)+([]a:3 4)", "+(,`a)!,4 6");
    try expectEval(vm, "(`a`b!1 2)+`a`b!10 20", "`a`b!11 22");
    try expectEval(vm, "(`a`b!1 2)+`b`c!10 20", "`a`b`c!1 12 20");
    try expectEval(vm, "(`a`b!1 2)+10", "`a`b!11 12");
    try expectEval(vm, "(`a`b!1 2)=`a`b!1 3", "`a`b!10b");
    try expectEval(vm, "(`a`b!1 2)|`a`b!0 3", "`a`b!1 3");
    try expectEval(vm, "sum `a`b!1 2", "3");
    try expectEval(vm, "neg `a`b!1 2", "`a`b!-1 -2");
    try testing.expectError(error.type, vm.evalSource("sum each t", .q, "<test>"));

    // Amending columns and cells.
    try expectEval(vm, "t[`a]:10 20", "::");
    try expectEval(vm, "t", "+`a`b!(10 20;`x`y)");
    try expectEval(vm, "@[t;`a;:;5 6]", "+`a`b!(5 6;`x`y)");
    try expectEval(vm, ".[t;(0;`a);:;9]", "+`a`b!(9 20;`x`y)");
    try expectEval(vm, "t[`c]:1 2", "::");
    try expectEval(vm, "t", "+`a`b`c!(10 20;`x`y;1 2)");
    try expectEval(vm, "t[`a]:`s#1 2;attr t`a", "`s");
    try expectEval(vm, "attr t", "`");

    // Keyed tables.
    try expectEval(vm, "kt:([k:1 2]a:3 4)", "::");
    try expectEval(vm, "kt", "(+(,`k)!,1 2)!+(,`a)!,3 4");
    try expectEval(vm, "type kt", "99h");
    try expectEval(vm, "count kt", "2");
    try expectEval(vm, "key kt", "+(,`k)!,1 2");
    try expectEval(vm, "value kt", "+(,`a)!,3 4");
    try expectEval(vm, "0!kt", "+`k`a!(1 2;3 4)");
    try expectEval(vm, "(0!kt)[0]", "`k`a!1 3");
    try expectEval(vm, "1!([]a:1 2;b:`x`y)", "(+(,`a)!,1 2)!+(,`b)!,`x`y");
    try expectEval(vm, "2!([]a:1 2;b:3 4;c:5 6)", "(+`a`b!(1 2;3 4))!+(,`c)!,5 6");
    try expectEval(vm, "0!2!([]a:1 2;b:3 4;c:5 6)", "+`a`b`c!(1 2;3 4;5 6)");
    try expectEval(vm, "0!([k:1 2]a:3 4;b:5 6)", "+`k`a`b!(1 2;3 4;5 6)");
    try expectEval(vm, "kt 1", "(,`a)!,3");
    try expectEval(vm, "kt[1]", "(,`a)!,3");
    try expectEval(vm, "kt 3", "(,`a)!,0N");
    try expectEval(vm, "kt ([]k:1 2)", "+(,`a)!,3 4");
    try expectEval(vm, "kt[`k`a!(2;4)]", "(,`a)!,4");
    try expectEval(vm, "t2:([]a:1 2;b:`x`y);t2~0!1!t2", "1b");
    try expectEval(vm, "(1!t2)[`a`b!(2;`y)]", "(,`b)!,`y");
    try testing.expectError(error.length, vm.evalSource("kt[1 2]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("kt[`k]", .q, "<test>"));
    try testing.expectError(error.nyi, vm.evalSource("flip kt", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("key 0!kt", .q, "<test>"));
}

test "qSQL follows q: parse trees, select, exec, update, delete and the functional forms" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "t:([]a:1 2 3;b:`x`y`x;c:10 20 30)", "::");

    // The parse trees, with the where clause and sort quoted and columns named as q names them.
    try expectEval(vm, "parse \"select a,c:1+a by b from t where a>1\"", "(?;`t;,,(>;`a;1);(,`b)!,`b;`a`c!(`a;(+;1;`a)))");
    try expectEval(vm, "parse \"select[2;>a] from t\"", "(?;`t;();0b;();2;,(>:;`a))");
    try expectEval(vm, "parse \"select[>a] from t\"", "(?;`t;();0b;();0W;,(>:;`a))");
    try expectEval(vm, "parse \"select distinct b,a:1 from t\"", "(?;`t;();1b;`b`a!(`b;1))");
    try expectEval(vm, "parse \"select count i by b from t\"", "(?;`t;();(,`b)!,`b;(,`x)!,(#:;`i))");
    try expectEval(vm, "parse \"delete from t where a>1\"", "(!;`t;,,(>;`a;1);0b;`symbol$())");
    try expectEval(vm, "parse \"delete b from t\"", "(!;`t;();0b;,,`b)");
    try expectEval(vm, "parse \"exec a by b from t\"", "(?;`t;();,`b;,`a)");
    try expectEval(vm, "parse \"exec a,b from t\"", "(?;`t;();();`a`b!`a`b)");
    try expectEval(vm, "parse \"update a:a*2 from t where b=`x\"", "(!;`t;,,(=;`b;,`x);0b;(,`a)!,(*;`a;2))");
    try expectEval(vm, "parse \"a<=1\"", "((';~:;>);`a;1)");
    // A one-item list quotes its item.
    try expectEval(vm, "eval enlist (1;`a)", "(1;`a)");
    try expectEval(vm, "eval enlist `a", "`a");
    try expectEval(vm, "eval `symbol$()", "`symbol$()");
    try testing.expectError(error.type, vm.evalSource("eval `a`b", .q, "<test>"));

    // select: naming, aggregates (one row when the first column aggregates), by, distinct.
    try expectEval(vm, "select a+1 from t", "+(,`a)!,2 3 4");
    try expectEval(vm, "select 1+a from t", "+(,`x)!,2 3 4");
    try expectEval(vm, "select count i from t", "+(,`x)!,,3");
    try expectEval(vm, "select sum a from t", "+(,`a)!,,6");
    try expectEval(vm, "select neg a from t", "+(,`a)!,-1 -2 -3");
    try expectEval(vm, "select a,a from t", "+`a`a1!(1 2 3;1 2 3)");
    try expectEval(vm, "select b,a from t", "+`b`a!(`x`y`x;1 2 3)");
    try expectEval(vm, "select a,sum a from t", "+`a`a1!(1 2 3;6 6 6)");
    try expectEval(vm, "select sum a,a from t", "+`a`a1!(,6;,1 2 3)");
    try testing.expectError(error.rank, vm.evalSource("select a:10 from t", .q, "<test>"));
    try expectEval(vm, "select by b from t", "(`s#+(,`b)!,`s#`x`y)!+`a`c!(3 2;30 20)");
    try expectEval(vm, "select a by b from t", "(`s#+(,`b)!,`s#`x`y)!+(,`a)!,(1 3;,2)");
    try expectEval(vm, "select max a by b from t", "(`s#+(,`b)!,`s#`x`y)!+(,`a)!,3 2");
    try expectEval(vm, "select count i by b from t", "(`s#+(,`b)!,`s#`x`y)!+(,`x)!,2 1");
    try expectEval(vm, "select sum c,cnt:count i by b from t", "(`s#+(,`b)!,`s#`x`y)!+`c`cnt!(40 20;2 1)");
    try expectEval(vm, "select count i by b,c from t", "(`s#+`b`c!(`p#`x`x`y;10 30 20))!+(,`x)!,1 1 1");
    try expectEval(vm, "select distinct b from t", "+(,`b)!,`x`y");
    try expectEval(vm, "select distinct b,a:1 from t", "+`b`a!(`x`y;1 1)");
    // where: constraints narrow in turn, `i` is the original row number, atoms keep all or none.
    try expectEval(vm, "select from t where b=`x,a>1", "+`a`b`c!(,3;,`x;,30)");
    try expectEval(vm, "select from t where a>1,i=1", "+`a`b`c!(,2;,`y;,20)");
    try expectEval(vm, "select a from t where a in 1 2", "+(,`a)!,1 2");
    try expectEval(vm, "select from t where a<>1", "+`a`b`c!(2 3;`y`x;20 30)");
    try expectEval(vm, "select from t where a>=2", "+`a`b`c!(2 3;`y`x;20 30)");
    try expectEval(vm, "select from t where a<=2", "+`a`b`c!(1 2;`x`y;10 20)");
    try expectEval(vm, "select from t where 1b", "+`a`b`c!(1 2 3;`x`y`x;10 20 30)");
    try expectEval(vm, "select from t where 0b", "+`a`b`c!(`long$();`symbol$();`long$())");
    try expectEval(vm, "select b from t where a>5", "+(,`b)!,`symbol$()");
    try expectEval(vm, "select sum a from t where a>5", "+(,`a)!,,0");
    try testing.expectError(error.length, vm.evalSource("select from t where 11b", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("select from t where a", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("select from t where a=`x", .q, "<test>"));
    // Limits and sorts.
    try expectEval(vm, "select[1] from t where a>1", "+`a`b`c!(,2;,`y;,20)");
    try expectEval(vm, "select[2;>a] from t", "+`a`b`c!(3 2;`x`y;30 20)");
    try expectEval(vm, "select[-2] from t", "+`a`b`c!(2 3;`y`x;20 30)");
    try expectEval(vm, "select[1 2] from t", "+`a`b`c!(2 3;`y`x;20 30)");
    try expectEval(vm, "select[>a] from t where a>1", "+`a`b`c!(3 2;`x`y;30 20)");
    try testing.expectError(error.length, vm.evalSource("select[>a;<b] from t", .q, "<test>"));
    // exec.
    try expectEval(vm, "exec a from t", "1 2 3");
    try expectEval(vm, "exec i from t", "0 1 2");
    try expectEval(vm, "exec distinct b from t", "`x`y");
    try expectEval(vm, "exec a,b from t where a>1", "`a`b!(2 3;`y`x)");
    try expectEval(vm, "exec sum a by b from t", "`s#`x`y!4 2");
    try expectEval(vm, "exec c by b from t", "`s#`x`y!(10 30;,20)");
    try expectEval(vm, "exec sum a by b from t where a>1", "`s#`x`y!3 2");
    // update and delete.
    try expectEval(vm, "update a:a*2 from t", "+`a`b`c!(2 4 6;`x`y`x;10 20 30)");
    try expectEval(vm, "update b:`z from t where a=1", "+`a`b`c!(1 2 3;`z`y`x;10 20 30)");
    try expectEval(vm, "update a+1 from t", "+`a`b`c!(2 3 4;`x`y`x;10 20 30)");
    try expectEval(vm, "update d:1 from t", "+`a`b`c`d!(1 2 3;`x`y`x;10 20 30;1 1 1)");
    try expectEval(vm, "update z:a+c from t where a>1", "+`a`b`c`z!(1 2 3;`x`y`x;10 20 30;0N 22 33)");
    try expectEval(vm, "update a:sum a from t where a>1", "+`a`b`c!(1 5 5;`x`y`x;10 20 30)");
    try expectEval(vm, "update d:sum a by b from t", "+`a`b`c`d!(1 2 3;`x`y`x;10 20 30;4 2 4)");
    try testing.expectError(error.length, vm.evalSource("update a:1 2 from t", .q, "<test>"));
    try expectEval(vm, "delete from t where a>1", "+`a`b`c!(,1;,`x;,10)");
    try expectEval(vm, "delete from t where a>5", "+`a`b`c!(1 2 3;`x`y`x;10 20 30)");
    try expectEval(vm, "delete b from t", "+`a`c!(1 2 3;10 20 30)");
    try expectEval(vm, "delete from t", "+`a`b`c!(`long$();`symbol$();`long$())");
    // A symbol names a global to update in place.
    try expectEval(vm, "![`t;();0b;(enlist `d)!enlist 1]", "`t");
    try expectEval(vm, "t", "+`a`b`c`d!(1 2 3;`x`y`x;10 20 30;1 1 1)");

    // The functional forms.
    try expectEval(vm, "u:([]a:1 2 3;b:`x`y`x;c:10 20 30)", "::");
    try expectEval(vm, "?[u;enlist (>;`a;1);0b;()]", "+`a`b`c!(2 3;`y`x;20 30)");
    try expectEval(vm, "?[u;();();`a]", "1 2 3");
    try expectEval(vm, "?[u;();();()]", "`a`b`c!(3;`x;30)");
    try expectEval(vm, "?[u;();`b;`a]", "`s#`x`y!(1 3;,2)");
    try expectEval(vm, "?[u;();(enlist `b)!enlist `b;`a]", "(`s#+(,`b)!,`s#`x`y)!(1 3;,2)");
    try expectEval(vm, "?[u;();`b`c!`b`c;(enlist `a)!enlist `a]", "(`s#+`b`c!(`p#`x`x`y;10 30 20))!+(,`a)!,(,1;,3;,2)");
    try expectEval(vm, "?[u;();0b;();0W;(>:;`a)]", "+`a`b`c!(3 2 1;`x`y`x;30 20 10)");
    try expectEval(vm, "?[u;();0b;();0W;(::;`a)]", "+`a`b`c!(2 3 0N;`y`x`;20 30 0N)");
    try expectEval(vm, "?[u;enlist (>;`a;5);`b;(sum;`a)]", "(`s#`symbol$())!`long$()");
    try expectEval(vm, "?[u;enlist (>;`a;5);(enlist `b)!enlist `b;(enlist `a)!enlist (sum;`a)]", "(`s#+(,`b)!,`symbol$())!+(,`a)!,`long$()");
    try testing.expectError(error.type, vm.evalSource("?[u;();0b;();2i]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("?[u;();0b;`a]", .q, "<test>"));
    try testing.expectError(error.rank, vm.evalSource("?[u;();0b;();0W;(>:;`a);7]", .q, "<test>"));
    try expectEval(vm, "![u;();0b;`a`z]", "+`b`c!(`x`y`x;10 20 30)");
    try testing.expectError(error.nyi, vm.evalSource("![u;enlist (>;`a;1);0b;`a`b]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("![u;();0b;()]", .q, "<test>"));

    // A keyed table is queried unkeyed; selecting all columns, updating and deleting keep the keys.
    try expectEval(vm, "kt:1!u", "::");
    try expectEval(vm, "select from kt", "(+(,`a)!,1 2 3)!+`b`c!(`x`y`x;10 20 30)");
    try expectEval(vm, "select b from kt", "+(,`b)!,`x`y`x");
    try expectEval(vm, "select from kt where a>1", "(+(,`a)!,2 3)!+`b`c!(`y`x;20 30)");
    try expectEval(vm, "update c:0 from kt", "(+(,`a)!,1 2 3)!+`b`c!(`x`y`x;0 0 0)");
    try expectEval(vm, "delete from kt where a>1", "(+(,`a)!,,1)!+`b`c!(,`x;,10)");
    try expectEval(vm, "delete b from kt", "(+(,`a)!,1 2 3)!+(,`c)!,10 20 30");
    try expectEval(vm, "exec b from kt", "`x`y`x");

    // Inside a lambda the query sees its parameters and locals; only the source is a global.
    try expectEval(vm, "f:{select from u where a>x};f 1", "+`a`b`c!(2 3;`y`x;20 30)");
    try expectEval(vm, "{select z:a+x from u} 10", "+(,`z)!,11 12 13");
    try expectEval(vm, "{v:2;select from u where a>v} 0", "+`a`b`c!(,3;,`x;,30)");
    try expectEval(vm, "(value f) 3", "``u");

    // `iasc` marks a list it finds ascending as sorted in place, so `select[<a]` marks the column.
    try expectEval(vm, "x:1 2 3;iasc x;x", "`s#1 2 3");
    try expectEval(vm, "x:3 1 2;iasc x;x", "3 1 2");
    try expectEval(vm, "select[<a] from u;u", "+`a`b`c!(`s#1 2 3;`x`y`x;10 20 30)");

    // A trailing `;` leaves `::`, and `value` of separators alone is `::`.
    try expectEval(vm, "value \"1+1;\"", "::");
    try expectEval(vm, "(::)~value \";\"", "1b");
    try expectEval(vm, "value \"1\"", "1");
    try expectEval(vm, "(::)~value \"\\\\\"", "1b");

    // `<=`, `>=` and `<>` are compositions of `not` with `>`, `<` and `=`.
    try expectEval(vm, "`a<>`b", "1b");
    try expectEval(vm, "1 2<=0N", "00b");
    try expectEval(vm, "-3!(<=)", "\"~>\"");
    try expectEval(vm, "value (<=)", "(~:;>)");
    try expectEval(vm, "type (<=)", "105h");
    try expectEval(vm, "(<=)[;2]", "~>[;2]");
    try expectEval(vm, "{x>=y}[2 3;2]", "11b");
}

test "like, ss and the symbol path forms follow q" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    // `like`: `?`, one `*` (or one at each end), classes with ranges, negation, a
    // leading `]` and a trailing `-` literal; `\` and `$` are plain characters.
    try expectEval(vm, "\"abc\" like \"a?c\"", "1b");
    try expectEval(vm, "\"abc\" like \"a?\"", "0b");
    try expectEval(vm, "\"abcabc\" like \"*abc\"", "1b");
    try expectEval(vm, "\"abc\" like \"*b*\"", "1b");
    try expectEval(vm, "\"abc\" like \"*x*\"", "0b");
    try expectEval(vm, "\"abc\" like \"abcd\"", "0b");
    try expectEval(vm, "\"\" like \"\"", "1b");
    try expectEval(vm, "\"abc\" like \"\"", "0b");
    try expectEval(vm, "\"1a\" like \"[0-9]*\"", "1b");
    try expectEval(vm, "\"a1\" like \"[0-9]*\"", "0b");
    try expectEval(vm, "\"-x\" like \"-[^0-9]*\"", "1b");
    try expectEval(vm, "\"-1\" like \"-[^0-9]*\"", "0b");
    try expectEval(vm, "\"a[c\" like \"a[[]c\"", "1b");
    try expectEval(vm, "\"a]c\" like \"a[]]c\"", "1b");
    try expectEval(vm, "\"a-c\" like \"a[a-]c\"", "1b");
    try expectEval(vm, "\"ab]\" like \"a[b]]\"", "1b");
    try expectEval(vm, "\"a*c\" like \"a\\\\*c\"", "0b");
    try expectEval(vm, "\"a\\\\c\" like \"a\\\\c\"", "1b");
    try expectEval(vm, "\"a$\" like \"*$\"", "1b");
    try expectEval(vm, "\"ABC\" like \"a*\"", "0b");
    try expectEval(vm, "`abc`x like \"ab*\"", "10b");
    try expectEval(vm, "(\"abc\";\"abd\";\"xy\") like \"ab?\"", "110b");
    try testing.expectError(error.type, vm.evalSource("\"abc\" like \"*\"", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("\"a\" like \"a*\"", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("(`abc;\"abd\") like \"a*\"", .q, "<test>"));
    try testing.expectError(error.nyi, vm.evalSource("\"abc\" like \"*a*b*\"", .q, "<test>"));
    try testing.expectError(error.nyi, vm.evalSource("\"abc\" like \"**\"", .q, "<test>"));
    try expectSignal(vm, "\"abc\" like \"a[bc\"", "[");
    try expectSignal(vm, "\"abc\" like \"ab[]\"", "[");

    // `ss`: positions of non-overlapping matches, a character or a pattern without `*`.
    try expectEval(vm, "\"hello\" ss \"l\"", "2 3");
    try expectEval(vm, "\"hello\" ss \"ll\"", ",2");
    try expectEval(vm, "\"hello\" ss \"[lo]\"", "2 3 4");
    try expectEval(vm, "\"hello\" ss \"?l\"", ",1");
    try expectEval(vm, "\"aaaa\" ss \"aa\"", "0 2");
    try expectEval(vm, "\"hello\" ss \"x\"", "`long$()");
    try expectEval(vm, "\"hello\" ss \"*\"", "`long$()");
    try expectEval(vm, "\"a[b\" ss \"[[]\"", ",1");
    try testing.expectError(error.length, vm.evalSource("\"hello\" ss \"l*\"", .q, "<test>"));
    try testing.expectError(error.length, vm.evalSource("\"hello\" ss \"\"", .q, "<test>"));
    try testing.expectError(error.length, vm.evalSource("\"hello\" ss \"l[\"", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("`hello ss \"l\"", .q, "<test>"));

    // File paths: `` ` `` joins symbols with `/` after a first one starting with `:`, and
    // splits such a symbol into its directory and name.
    try expectEvalMode(vm, .k, "`/:`:/a`b`c", "`:/a/b/c");
    try expectEvalMode(vm, .k, "`/:`:`a", "`:/a");
    try expectEvalMode(vm, .k, "`/:`:/a/`b", "`:/a//b");
    try expectEvalMode(vm, .k, "`/:``a", "`.a");
    try expectEvalMode(vm, .k, "`\\:`:/a/b/c.txt", "`:/a/b`c.txt");
    try expectEvalMode(vm, .k, "`\\:`:a", "`:.`a");
    try expectEvalMode(vm, .k, "`\\:`:/a", "`:`a");
    try expectEvalMode(vm, .k, "`\\:`:/", "`:`");
    try expectEvalMode(vm, .k, "`\\:`a.b.c", "`a`b`c");
}

test "files, handles, system commands, .z and serialisation follow q" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    // Text files: `0:` writes lines, `read0` reads them, a final newline adds no line.
    try expectEval(vm, "`:/tmp/openq_test.txt 0: (\"ab\";\"cd\";\"\")", "`:/tmp/openq_test.txt");
    try expectEval(vm, "read0 `:/tmp/openq_test.txt", "(\"ab\";\"cd\";\"\")");
    try expectEval(vm, "read1 `:/tmp/openq_test.txt", "0x61620a63640a0a");
    try expectEval(vm, "read1 (`:/tmp/openq_test.txt;1;3)", "0x620a63");
    try expectEval(vm, "-7!`:/tmp/openq_test.txt", "7");
    try testing.expectError(error.type, vm.evalSource("`:/tmp/openq_test.txt 0: (\"ab\";\"c\")", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("`:/tmp/openq_test.txt 0: 0x6162", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("\"/tmp/openq_test.txt\" 0: (\"x\";\"y\")", .q, "<test>"));
    try expectEval(vm, "`:/tmp/openq_test.txt 1: 0x0102", "`:/tmp/openq_test.txt");
    try expectEval(vm, "read1 `:/tmp/openq_test.txt", "0x0102");
    try expectEval(vm, "`:/tmp/openq_test.txt 0: ()", "`:/tmp/openq_test.txt");
    try expectEval(vm, "read0 `:/tmp/openq_test.txt", "()");
    try expectSignal(vm, "read0 `:/tmp/openq_nofile", "/tmp/openq_nofile. OS reports: No such file or directory");
    try expectSignal(vm, "-7!`:/tmp", "/tmp. OS reports: Is a directory");

    // Handles append; a negative handle adds a newline; `0` evaluates; `1` and `2` print.
    try expectEval(vm, "h:hopen `:/tmp/openq_test.txt;type h", "-6h");
    try expectEval(vm, "h \"xy\";h `sym;h 0x00;h enlist \"z\";neg[h] \"!\";read1 `:/tmp/openq_test.txt", "0x787973796d007a210a");
    try expectEval(vm, ">:[h]", "::");
    try expectSignal(vm, ">:[h]", "close. OS reports: Bad file descriptor");
    try testing.expectError(error.domain, vm.evalSource(">:[1i]", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("hopen `a", .q, "<test>"));
    try testing.expectError(error.domain, vm.evalSource("hopen 12345678", .q, "<test>"));
    try expectSignal(vm, "hopen `:/tmp", ":/tmp. OS reports: Is a directory");
    try expectEval(vm, "0 \"1+1\"", "2");
    try expectEval(vm, "-1 \"text\"", "-1");
    try expectEval(vm, "1 \"text\"", "1");
    try expectEval(vm, "2 \"err\"", "2");
    try expectEval(vm, "-1 ()", "-1");
    try testing.expectError(error.type, vm.evalSource("1 (1;2)", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("-1 `a", .q, "<test>"));

    // `key` lists a directory (sorted), names a file, and gives `()` for nothing.
    try expectEval(vm, "d:hopen `:/tmp/openq_dir/a.txt;d \"x\";>:[d];`:/tmp/openq_dir/b.txt 0: (\"y1\";\"y2\");key `:/tmp/openq_dir", "`s#`a.txt`b.txt");
    try expectEval(vm, "key `:/tmp/openq_dir/a.txt", "`:/tmp/openq_dir/a.txt");
    try expectEval(vm, "key `:/tmp/openq_dir/nofile", "()");
    // `hdel` (`~:` on a file symbol) removes files and empty directories.
    try expectEval(vm, "~:[`:/tmp/openq_dir/a.txt];~:[`:/tmp/openq_dir/b.txt];~:[`:/tmp/openq_dir]", "`:/tmp/openq_dir");
    try expectSignal(vm, "~:[`:/tmp/openq_dir]", "/tmp/openq_dir. OS reports: No such file or directory");

    // `set` and `get` through `.[`:path;();:;v]` and `value`, in q's file format.
    try expectEval(vm, ".[`:/tmp/openq_test.txt;();:;1 2 3]", "`:/tmp/openq_test.txt");
    try expectEval(vm, "read1 `:/tmp/openq_test.txt", "0xfe200700000000000000000000000000010000000000000002000000000000000300000000000000");
    try expectEval(vm, "value `:/tmp/openq_test.txt", "1 2 3");
    try expectEval(vm, ".[`:/tmp/openq_test.txt;();:;5];read1 `:/tmp/openq_test.txt", "0xff01f90500000000000000");
    try expectEval(vm, "value `:/tmp/openq_test.txt", "5");
    try expectEval(vm, ".[`:/tmp/openq_test.txt;();:;(1;`a;\"bc\";`b`c!3 4;([]a:1 2);{x+1})];value `:/tmp/openq_test.txt", "(1;`a;\"bc\";`b`c!3 4;+(,`a)!,1 2;{x+1})");
    try expectEval(vm, ".[`:/tmp/openq_test.txt;();:;`s#1 2 3];value `:/tmp/openq_test.txt", "`s#1 2 3");
    try testing.expectError(error.type, vm.evalSource(".[`:/tmp/openq_test.txt;();,;1]", .q, "<test>"));
    try expectEval(vm, "`:/tmp/openq_test.txt 0: enlist \"z:42\"", "`:/tmp/openq_test.txt");
    try expectSignal(vm, "value `:/tmp/openq_test.txt", "/tmp/openq_test.txt");

    // `-8!` and `-9!`: q's IPC bytes.
    try expectEval(vm, "-8!1 2", "0x010000001e00000007000200000001000000000000000200000000000000");
    try expectEval(vm, "-8!`a", "0x010000000b000000f56100");
    try expectEval(vm, "-8!()", "0x010000000e000000000000000000");
    try expectEval(vm, "-8!`a`b!1 2", "0x0100000029000000630b00020000006100620007000200000001000000000000000200000000000000");
    try expectEval(vm, "-9!-8!(1;`a;\"bc\";([]a:1 2);{x+1};+;-:;+[1];(<=);+/;`s#1 2;2000.01.01;1b)", "(1;`a;\"bc\";+(,`a)!,1 2;{x+1};+;-:;+[1];~>;+/;`s#1 2;2000.01.01;1b)");
    try expectSignal(vm, "-9!0x010000000d0000000000000000000000", "badmsg");

    // Scripts: `\\l` runs a file, `.k` in k mode, restoring `\\d`; an error stops it.
    try expectEval(vm, "`:/tmp/openq_test.q 0: (\"\\\\d .m\";\"v:1\";\"f:{x+\";\" 1}\";enlist \"/\";\"hidden:1\";enlist \"\\\\\";\"w:f 2\")", "`:/tmp/openq_test.q");
    try expectEval(vm, "\\l /tmp/openq_test.q", "::");
    try expectEval(vm, "(.m.v;.m.w;value \"\\\\d\")", "(1;3;`.)");
    try testing.expectError(error.identifier, vm.evalSource(".m.hidden", .q, "<test>"));
    try expectEval(vm, "`:/tmp/openq_test.k 0: (\"a:!3\";\"'\\\"oops\\\"\";\"b:1\")", "`:/tmp/openq_test.k");
    try expectSignal(vm, "\\l /tmp/openq_test.k", "oops");
    try expectEval(vm, "a", "0 1 2");
    try testing.expectError(error.identifier, vm.evalSource("b", .q, "<test>"));
    try expectSignal(vm, "\\l /tmp/openq_nofile.q", "/tmp/openq_nofile.q. OS reports: No such file or directory");
    try testing.expectError(error.nyi, vm.evalSource("\\l", .q, "<test>"));
    try expectEval(vm, "~:[`:/tmp/openq_test.q];~:[`:/tmp/openq_test.k];~:[`:/tmp/openq_test.txt]", "`:/tmp/openq_test.txt");

    // System commands hold their settings; `\\c` bounds the console and cuts `-3!`.
    try expectEval(vm, "\\c", "25 80i");
    try expectEval(vm, "\\C", "36 2000i");
    try expectEval(vm, "\\c 5 5", "::");
    try expectEval(vm, "\\c", "10 10i");
    try expectEval(vm, "-3!til 100", "\"0 1 2 3..\"");
    try expectEval(vm, "\\c 3000 3000", "::");
    try expectEval(vm, "\\c", "2000 2000i");
    try expectEval(vm, "\\c 1", "2000 2000i");
    try testing.expectError(error.domain, vm.evalSource("\\c 1 2 3", .q, "<test>"));
    try expectEval(vm, "\\c 25 80", "::");
    try expectEval(vm, "\\e 1", "::");
    try expectEval(vm, "\\e", "1i");
    try expectEval(vm, "\\o", "0Ni");
    try expectEval(vm, "\\z 1", "::");
    try expectEval(vm, "\\z", "1i");
    try expectEval(vm, "\\W", "2i");
    try expectEval(vm, "\\s", "0i");
    try expectSignal(vm, "\\s 4", "enable secondary threads via cmd line -s only");
    try expectEval(vm, "\\_", "0b");
    try expectEval(vm, "\\p", "0i");
    try expectEval(vm, "type value \"\\\\t 1+1\"", "-7h");
    try expectEval(vm, "count value \"\\\\ts 1+1\"", "2");
    try expectEval(vm, "count value \"\\\\w\"", "6");
    try expectEval(vm, "\\x .z.pi", "::");
    try expectEval(vm, "type value \"\\\\cd\"", "10h");
    try testing.expectError(error.domain, vm.evalSource("\\S 0", .q, "<test>"));
    try testing.expectError(error.nyi, vm.evalSource("\\1", .q, "<test>"));
    try expectEval(vm, "\\P 20", "::");
    try expectEval(vm, "\\P", "17i");
    try expectEval(vm, "\\P 7", "::");
    // Namespace listings: tables, views, functions and variables, sorted.
    try expectEval(vm, "\\d .lst", "::");
    try expectEval(vm, "t1:([]a:1 2)", "::");
    try expectEval(vm, "v1:1", "::");
    try expectEval(vm, "f1:{x}", "::");
    try expectEval(vm, "t0:([]b:1 2)", "::");
    try expectEval(vm, "\\a", "`t0`t1");
    try expectEval(vm, "\\v", "`t0`t1`v1");
    try expectEval(vm, "\\f", ",`f1");
    try expectEval(vm, "\\b", "`symbol$()");
    try expectEval(vm, "\\d .", "::");
    try expectEval(vm, "\\a .lst", "`t0`t1");
    try expectSignal(vm, "\\a .none", ".none");
    try expectSignal(vm, "\\v zz", "zz");

    // `.z`: the flags, the script and its arguments, the identity of the process.
    try expectEval(vm, ".z.q", "0b");
    try expectEval(vm, ".z.f", "`");
    try expectEval(vm, ".z.x", "()");
    try expectEval(vm, ".z.e", "(`symbol$())!()");
    try expectEval(vm, ".z.K", "4f");
    try expectEval(vm, ".z.k", "2023.04.17");
    try expectEval(vm, ".z.w", "0i");
    try expectEval(vm, "type .z.i", "-6h");
    try expectEval(vm, "type .z.h", "-11h");
    try expectEval(vm, "{$[x<2;x;x*.z.s x-1]} 5", "120");
    try testing.expectError(error.nyi, vm.evalSource(".z.s", .q, "<test>"));
    try testing.expectError(error.identifier, vm.evalSource(".z.ex", .q, "<test>"));
    // An undefined name is reported by name, as q reports it.
    try expectEval(vm, "@[value;\"nosuch\";{x}]", "\"nosuch\"");
    try expectEval(vm, "@[{nosuch2};1;{x}]", "\"nosuch2\"");
}

test "table literals name columns like queries, run inside lambdas, and join by rows" {
    var discarding: Io.Writer.Discarding = .init(&.{});
    const vm: *Vm = try .init(testing.io, testing.allocator, &discarding.writer);
    defer vm.deinit();

    try expectEval(vm, "a:1 2;b:3 4", "::");
    try expectEval(vm, "([]1 2;x:3 4)", "+`x`x1!(1 2;3 4)");
    try expectEval(vm, "([]neg a;neg a)", "+`a`a1!(-1 -2;-1 -2)");
    try expectEval(vm, "([]1+a;b)", "+`x`b!(2 3;3 4)");
    try expectEval(vm, "([]a[0 1];b)", "+`x`b!(1 2;3 4)");
    try expectEval(vm, "([x:1 2]3 4)", "(+(,`x)!,1 2)!+(,`x)!,3 4");
    // Inside a lambda the columns see parameters and locals, and assignments in the
    // columns (evaluated right to left) set locals, as q.k's `meta` relies on.
    try expectEval(vm, "{([]c:x)} 5 6", "+(,`c)!,5 6");
    try expectEval(vm, "{([k:t]v:2*t:x)} 1 2", "(+(,`k)!,1 2)!+(,`v)!,2 4");
    try expectEval(vm, "{v:x;([]v)} 7 8", "+(,`v)!,7 8");
    // A table joined with anything but a table or dictionary is its rows as a list.
    try expectEval(vm, "(enlist `a`b!1 2),3", "(`a`b!1 2;3)");
    try expectEval(vm, "3,([]a:1 2)", "(3;(,`a)!,1;(,`a)!,2)");
    try expectSignal(vm, "([]a:1 2),`b`c!3 4", "mismatch");
    try expectEval(vm, "(enlist `a)!enlist `b`c!1 2", "(,`a)!+`b`c!(,1;,2)");
    // A list of longs pads strings pairwise.
    try expectEval(vm, "5 3$(\"ab\";\"cde\")", "(\"ab   \";\"cde\")");
    try testing.expectError(error.length, vm.evalSource("1 2$\"abc\"", .q, "<test>"));
    try testing.expectError(error.type, vm.evalSource("2 3$\"ab\"", .q, "<test>"));
}
