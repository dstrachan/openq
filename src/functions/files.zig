//! Files and handles: `read0` and `read1`, the write forms of `0:` and `1:`, `hopen`,
//! `hclose` and writes through a handle, `key` of a directory, `hdel`, and `set` and
//! `get` with q's serialisation (`-8!` and `-9!`). Verified against q 5.0 and 4.0.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const q = @import("../root.zig");
const Vm = q.Vm;
const Value = q.Value;
const RunError = Vm.RunError;
const pathOf = q.internal.pathOf;
const failOs = q.internal.failOs;

/// Whether a symbol names a file: it starts with `:`.
pub fn isFileSymbol(vm: *Vm, x: *Value) bool {
    if (x.as != .symbol) return false;
    const text = vm.internedString(x.as.symbol);
    return text.len > 0 and text[0] == ':';
}

fn readAll(vm: *Vm, path: []const u8) RunError![]u8 {
    return Io.Dir.cwd().readFileAlloc(vm.io, path, vm.gpa, .unlimited) catch |err| return failOs(vm, path, err);
}

fn writeAll(vm: *Vm, path: []const u8, bytes: []const u8) RunError!void {
    const file = Io.Dir.cwd().createFile(vm.io, path, .{}) catch |err| return failOs(vm, path, err);
    defer file.close(vm.io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(vm.io, &buffer);
    writer.interface.writeAll(bytes) catch |err| return failOs(vm, path, err);
    writer.interface.flush() catch |err| return failOs(vm, path, err);
}

/// A file's bytes, or the range `(path;offset;length)` names.
fn bytesOf(vm: *Vm, x: *Value) RunError![]u8 {
    if (x.as == .list and x.as.list.len == 3) {
        const path = try pathOf(vm, x.as.list[0]);
        const offset = (try q.operators.integerOf(x.as.list[1])) orelse return error.type;
        const length = (try q.operators.integerOf(x.as.list[2])) orelse return error.type;
        if (offset < 0 or length < 0) return error.type;
        const all = try readAll(vm, path);
        defer vm.gpa.free(all);
        const start: usize = @min(@as(usize, @intCast(offset)), all.len);
        const end: usize = @min(start + @as(usize, @intCast(length)), all.len);
        return vm.gpa.dupe(u8, all[start..end]);
    }
    return readAll(vm, try pathOf(vm, x));
}

/// The lines of a text as strings: split at newlines, a final newline adding no line.
fn lines(vm: *Vm, text: []const u8) RunError!*Value {
    var items: std.ArrayList(*Value) = .empty;
    defer items.deinit(vm.gpa);
    defer for (items.items) |v| v.deref(vm.gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (it.peek() == null and line.len == 0) break;
        const string = try vm.allocValue(.char_list, line.len);
        @memcpy(string.as.char_list, line);
        try items.append(vm.gpa, string);
    }
    if (items.items.len == 0) return vm.allocValue(.list, 0);
    return vm.enlist(items.items);
}

/// `read0 x`: the lines of the file a symbol names, or of the range `(path;offset;length)`.
pub fn read0(vm: *Vm, x: *Value) RunError!*Value {
    const bytes = try bytesOf(vm, x);
    defer vm.gpa.free(bytes);
    return lines(vm, bytes);
}

/// `read1 x`: the bytes of a file or of a range of it.
pub fn read1(vm: *Vm, x: *Value) RunError!*Value {
    const bytes = try bytesOf(vm, x);
    defer vm.gpa.free(bytes);
    const result = try vm.allocValue(.byte_list, bytes.len);
    @memcpy(result.as.byte_list, bytes);
    return result;
}

/// `x 0: y`: writes the strings `y` to the file `x` as lines, giving `x` back. Anything
/// but a symbol path and a list of strings is `type`; parsing text with a type list is
/// not done.
pub fn writeText(vm: *Vm, x: *Value, y: *Value) RunError!*Value {
    if (x.as != .symbol) return if (x.as == .list) error.nyi else error.type;
    const path = try pathOf(vm, x);
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(vm.gpa);
    switch (y.as) {
        .list => |items| for (items) |item| {
            if (item.as != .char_list) return error.type;
            try buffer.appendSlice(vm.gpa, item.as.char_list);
            try buffer.append(vm.gpa, '\n');
        },
        else => return error.type,
    }
    try writeAll(vm, path, buffer.items);
    return x.ref();
}

/// `x 1: y`: writes the bytes or characters `y` to the file `x`, giving `x` back.
pub fn writeBytes(vm: *Vm, x: *Value, y: *Value) RunError!*Value {
    if (x.as != .symbol) return error.type;
    const path = try pathOf(vm, x);
    switch (y.as) {
        .byte_list => |bytes| try writeAll(vm, path, bytes),
        .char_list => |text| try writeAll(vm, path, text),
        else => return error.nyi,
    }
    return x.ref();
}

/// `hopen x`: opens the file a symbol (or a string of the same shape) names for appending,
/// creating it and its directories, and gives its handle, an int.
pub fn hopen(vm: *Vm, x: *Value) RunError!*Value {
    const path: []const u8 = switch (x.as) {
        .symbol => try pathOf(vm, x),
        .char_list => |text| if (text.len > 0 and text[0] == ':') text[1..] else return error.type,
        .int, .long => return error.domain,
        else => return error.type,
    };
    if (x.as == .symbol and !isFileSymbol(vm, x)) return error.type;
    const stat = Io.Dir.cwd().statFile(vm.io, path, .{}) catch null;
    // A directory is refused, named with its colon as q names it.
    if (stat != null and stat.?.kind == .directory) {
        const named = try std.fmt.allocPrint(vm.gpa, ":{s}", .{path});
        defer vm.gpa.free(named);
        return failOs(vm, named, error.IsDir);
    }
    // Missing directories are created, as q does; a failure shows when the file opens.
    if (std.fs.path.dirname(path)) |dir| Io.Dir.cwd().createDirPath(vm.io, dir) catch {};
    const file = Io.Dir.cwd().createFile(vm.io, path, .{ .truncate = false }) catch |err| return failOs(vm, path, err);
    errdefer file.close(vm.io);
    const handle: i32 = @intCast(file.handle);
    try vm.handles.put(vm.gpa, handle, file);
    return vm.createValue(.int, handle);
}

/// `hclose x`: closes a handle; the standard ones are `domain`, an unknown one an error.
pub fn hclose(vm: *Vm, x: *Value) RunError!*Value {
    const handle: i32 = switch (x.as) {
        .int => |v| v,
        .long => |v| std.math.cast(i32, v) orelse return error.domain,
        else => return error.type,
    };
    if (handle <= 2) return error.domain;
    const file = vm.handles.get(handle) orelse return vm.failWith("close. OS reports: Bad file descriptor");
    _ = vm.handles.swapRemove(handle);
    file.close(vm.io);
    return vm.getUnaryPrimitive(.identity);
}

/// The bytes a value writes through a handle: a string's characters, a symbol's name, a
/// list of strings joined with newlines, bytes as they are, and a number's own bytes.
fn rawBytes(vm: *Vm, x: *Value, buffer: *std.ArrayList(u8)) RunError!void {
    switch (x.as) {
        .char_list => |text| try buffer.appendSlice(vm.gpa, text),
        .char => |c| try buffer.append(vm.gpa, c),
        .symbol => |s| try buffer.appendSlice(vm.gpa, vm.internedString(s)),
        .byte_list => |bytes| try buffer.appendSlice(vm.gpa, bytes),
        .byte => |b| try buffer.append(vm.gpa, b),
        .list => |items| for (items, 0..) |item, i| {
            if (item.as != .char_list) return error.type;
            if (i > 0) try buffer.append(vm.gpa, '\n');
            try buffer.appendSlice(vm.gpa, item.as.char_list);
        },
        inline .boolean, .short, .int, .long, .real, .float => |v| try buffer.appendSlice(vm.gpa, std.mem.asBytes(&v)),
        else => return error.type,
    }
}

/// `h x` for a handle `h`: `0` evaluates a string, `1` and `2` print to stdout and stderr,
/// a file handle appends; a negative handle adds a newline. The handle comes back.
pub fn write(vm: *Vm, handle_value: *Value, x: *Value) RunError!*Value {
    const signed: i64 = switch (handle_value.as) {
        .int => |v| v,
        .long => |v| v,
        else => unreachable,
    };
    const handle: i32 = std.math.cast(i32, @abs(signed)) orelse return error.domain;
    if (handle == 0) {
        if (x.as != .char_list) return error.type;
        const source = try vm.gpa.dupeSentinel(u8, x.as.char_list, 0);
        defer vm.gpa.free(source);
        return vm.evalSource(source, .q, "<handle>");
    }
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(vm.gpa);
    if (handle <= 2) {
        // The console handles take text only.
        switch (x.as) {
            .char_list, .char, .list => {},
            else => return error.type,
        }
    }
    try rawBytes(vm, x, &buffer);
    if (signed < 0) try buffer.append(vm.gpa, '\n');
    if (handle == 1) {
        try vm.stdout.writeAll(buffer.items);
        try vm.stdout.flush();
    } else if (handle == 2) {
        std.debug.print("{s}", .{buffer.items});
    } else {
        const file = vm.handles.get(handle) orelse return error.domain;
        var write_buffer: [4096]u8 = undefined;
        var writer = file.writer(vm.io, &write_buffer);
        writer.seekTo(file.length(vm.io) catch return error.os) catch return error.os;
        writer.interface.writeAll(buffer.items) catch return error.os;
        writer.interface.flush() catch return error.os;
    }
    return handle_value.ref();
}

/// `key x` for a file symbol: a directory's entries as a sorted symbol list, a file's
/// own symbol, and `()` for nothing there.
pub fn list(vm: *Vm, x: *Value) RunError!*Value {
    const path = try pathOf(vm, x);
    const stat = Io.Dir.cwd().statFile(vm.io, path, .{}) catch return vm.allocValue(.list, 0);
    if (stat.kind != .directory) return x.ref();
    var dir = Io.Dir.cwd().openDir(vm.io, path, .{ .iterate = true }) catch return vm.allocValue(.list, 0);
    defer dir.close(vm.io);
    var names: std.ArrayList([]u8) = .empty;
    defer names.deinit(vm.gpa);
    defer for (names.items) |n| vm.gpa.free(n);
    var it = dir.iterate();
    while (it.next(vm.io) catch |err| return failOs(vm, path, err)) |entry| {
        try names.append(vm.gpa, try vm.gpa.dupe(u8, entry.name));
    }
    std.sort.block([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    const result = try vm.allocValue(.symbol_list, names.items.len);
    errdefer result.deref(vm.gpa);
    for (result.as.symbol_list, names.items) |*slot, name| slot.* = try vm.intern(name);
    result.attr = .s;
    return result;
}

/// `hdel x`: removes the file or directory a symbol names, giving the symbol back.
pub fn delete(vm: *Vm, x: *Value) RunError!*Value {
    const path = try pathOf(vm, x);
    Io.Dir.cwd().deleteFile(vm.io, path) catch |err| switch (err) {
        error.IsDir => Io.Dir.cwd().deleteDir(vm.io, path) catch |dir_err| return failOs(vm, path, dir_err),
        else => return failOs(vm, path, err),
    };
    return x.ref();
}

// Serialisation: q's IPC format, which `-8!` and `-9!` expose and files hold.

const Writer = struct {
    vm: *Vm,
    bytes: std.ArrayList(u8) = .empty,

    fn deinit(self: *Writer) void {
        self.bytes.deinit(self.vm.gpa);
    }

    fn byte(self: *Writer, b: u8) Allocator.Error!void {
        try self.bytes.append(self.vm.gpa, b);
    }

    fn int(self: *Writer, comptime T: type, v: T) Allocator.Error!void {
        try self.bytes.appendSlice(self.vm.gpa, std.mem.asBytes(&v));
    }

    fn string(self: *Writer, text: []const u8) Allocator.Error!void {
        try self.bytes.appendSlice(self.vm.gpa, text);
        try self.byte(0);
    }

    fn value(self: *Writer, x: *Value) RunError!void {
        const vm = self.vm;
        switch (x.as) {
            inline .boolean, .byte, .short, .int, .long, .real, .float, .char, .timestamp, .month, .date, .datetime, .timespan, .minute, .second, .time => |v, tag| {
                try self.byte(@bitCast(@as(i8, @backingInt(tag))));
                const payload = if (@TypeOf(v) == bool) @as(u8, @intFromBool(v)) else v;
                try self.int(@TypeOf(payload), payload);
            },
            .symbol => |s| {
                try self.byte(0xf5);
                try self.string(vm.internedString(s));
            },
            inline .boolean_list, .byte_list, .short_list, .int_list, .long_list, .real_list, .float_list, .char_list, .timestamp_list, .month_list, .date_list, .datetime_list, .timespan_list, .minute_list, .second_list, .time_list => |items, tag| {
                try self.byte(@intCast(@backingInt(tag)));
                try self.byte(@backingInt(x.attr));
                try self.int(u32, @intCast(items.len));
                for (items) |v| {
                    const payload = if (@TypeOf(v) == bool) @as(u8, @intFromBool(v)) else v;
                    try self.int(@TypeOf(payload), payload);
                }
            },
            .symbol_list => |items| {
                try self.byte(11);
                try self.byte(@backingInt(x.attr));
                try self.int(u32, @intCast(items.len));
                for (items) |s| try self.string(vm.internedString(s));
            },
            .list => |items| {
                try self.byte(0);
                try self.byte(@backingInt(x.attr));
                try self.int(u32, @intCast(items.len));
                for (items) |item| try self.value(item);
            },
            .dict => |d| {
                try self.byte(99);
                try self.value(d.keys);
                try self.value(d.values);
            },
            .table => |t| {
                try self.byte(98);
                try self.byte(@backingInt(x.attr));
                try self.byte(99);
                try self.value(t.keys);
                try self.value(t.values);
            },
            .lambda => |lambda| {
                try self.byte(100);
                const namespace = vm.internedString(lambda.namespace);
                try self.string(if (std.mem.eql(u8, namespace, ".")) "" else namespace);
                try self.byte(10);
                try self.byte(0);
                try self.int(u32, @intCast(lambda.source.len));
                try self.bytes.appendSlice(vm.gpa, lambda.source);
            },
            .unary_primitive => |p| {
                try self.byte(101);
                try self.byte(if (p == .empty) 0 else @intCast(@backingInt(p)));
            },
            .operator => |o| {
                try self.byte(102);
                try self.byte(@intCast(@backingInt(o)));
            },
            .iterator => |i| {
                try self.byte(103);
                try self.byte(@intCast(@backingInt(i)));
            },
            .projection => |p| {
                try self.byte(104);
                try self.int(u32, @intCast(1 + p.args.len));
                try self.value(p.callee);
                for (p.args) |a| try self.value(a);
            },
            .composition => |c| {
                try self.byte(105);
                try self.int(u32, 2);
                try self.value(c.f);
                try self.value(c.g);
            },
            inline .each, .over, .scan, .each_prior, .each_right, .each_left => |d, tag| {
                try self.byte(@intCast(@backingInt(tag)));
                try self.value(d.value);
            },
        }
    }
};

/// `-8!x`: the bytes of `x` in q's IPC format, header included.
pub fn serialize(vm: *Vm, x: *Value) RunError!*Value {
    var writer: Writer = .{ .vm = vm };
    defer writer.deinit();
    try writer.bytes.appendSlice(vm.gpa, &.{ 1, 0, 0, 0, 0, 0, 0, 0 });
    try writer.value(x);
    std.mem.writeInt(u32, writer.bytes.items[4..8], @intCast(writer.bytes.items.len), .little);
    const result = try vm.allocValue(.byte_list, writer.bytes.items.len);
    @memcpy(result.as.byte_list, writer.bytes.items);
    return result;
}

const Reader = struct {
    vm: *Vm,
    bytes: []const u8,
    at: usize = 0,

    const Error = RunError || error{BadMessage};

    fn take(self: *Reader, n: usize) error{BadMessage}![]const u8 {
        if (self.at + n > self.bytes.len) return error.BadMessage;
        defer self.at += n;
        return self.bytes[self.at .. self.at + n];
    }

    fn int(self: *Reader, comptime T: type) error{BadMessage}!T {
        const slice = try self.take(@sizeOf(T));
        return std.mem.bytesToValue(T, slice[0..@sizeOf(T)]);
    }

    fn string(self: *Reader) error{BadMessage}![]const u8 {
        const end = std.mem.findScalarPos(u8, self.bytes, self.at, 0) orelse return error.BadMessage;
        defer self.at = end + 1;
        return self.bytes[self.at..end];
    }

    fn value(self: *Reader) Error!*Value {
        const vm = self.vm;
        const type_byte: i8 = @bitCast((try self.take(1))[0]);
        if (type_byte < 0) {
            const tag = std.enums.fromInt(Value.Type, type_byte) orelse return error.BadMessage;
            switch (tag) {
                inline .boolean, .byte, .short, .int, .long, .real, .float, .char, .timestamp, .month, .date, .datetime, .timespan, .minute, .second, .time => |t| {
                    const Payload = @FieldType(Value.Union, @tagName(t));
                    const raw = try self.int(if (Payload == bool) u8 else Payload);
                    return vm.createValue(t, if (Payload == bool) raw != 0 else raw);
                },
                .symbol => return vm.createValue(.symbol, try vm.intern(try self.string())),
                else => return error.BadMessage,
            }
        }
        const tag = std.enums.fromInt(Value.Type, type_byte) orelse return error.BadMessage;
        switch (tag) {
            inline .boolean_list, .byte_list, .short_list, .int_list, .long_list, .real_list, .float_list, .char_list, .timestamp_list, .month_list, .date_list, .datetime_list, .timespan_list, .minute_list, .second_list, .time_list => |t| {
                const attr = (try self.take(1))[0];
                const count = try self.int(u32);
                const result = try vm.allocValue(t, count);
                errdefer result.deref(vm.gpa);
                const items = @field(result.as, @tagName(t));
                for (items) |*slot| {
                    const Payload = @TypeOf(slot.*);
                    const raw = try self.int(if (Payload == bool) u8 else Payload);
                    slot.* = if (Payload == bool) raw != 0 else raw;
                }
                result.attr = @enumFromInt(@min(attr, 4));
                return result;
            },
            .symbol_list => {
                const attr = (try self.take(1))[0];
                var count = try self.int(u32);
                // A file may hold a symbol list with its count zeroed; the strings tell.
                if (count == 0 and self.at < self.bytes.len) count = @intCast(std.mem.countScalar(u8, self.bytes[self.at..], 0));
                const result = try vm.allocValue(.symbol_list, count);
                errdefer result.deref(vm.gpa);
                for (result.as.symbol_list) |*slot| slot.* = try vm.intern(try self.string());
                result.attr = @enumFromInt(@min(attr, 4));
                return result;
            },
            .list => {
                const attr = (try self.take(1))[0];
                const count = try self.int(u32);
                const result = try vm.allocValue(.list, count);
                var filled: usize = 0;
                errdefer {
                    for (result.as.list[0..filled]) |v| v.deref(vm.gpa);
                    vm.gpa.free(result.as.list);
                    vm.gpa.destroy(result);
                }
                for (0..count) |_| {
                    result.as.list[filled] = try self.value();
                    filled += 1;
                }
                result.attr = @enumFromInt(@min(attr, 4));
                return result;
            },
            .dict => {
                const keys = try self.value();
                errdefer keys.deref(vm.gpa);
                const values = try self.value();
                errdefer values.deref(vm.gpa);
                return vm.createValue(.dict, .{ .keys = keys, .values = values });
            },
            .table => {
                const attr = (try self.take(1))[0];
                if ((try self.take(1))[0] != 99) return error.BadMessage;
                const keys = try self.value();
                defer keys.deref(vm.gpa);
                const values = try self.value();
                defer values.deref(vm.gpa);
                const result = try q.operators.makeTable(vm, keys, values);
                result.attr = @enumFromInt(@min(attr, 4));
                return result;
            },
            .lambda => {
                const namespace = try self.string();
                if ((try self.take(1))[0] != 10) return error.BadMessage;
                _ = try self.take(1);
                const count = try self.int(u32);
                const source = try vm.gpa.dupeSentinel(u8, try self.take(count), 0);
                defer vm.gpa.free(source);
                const saved = vm.namespace;
                defer vm.namespace = saved;
                vm.namespace = try vm.intern(if (namespace.len == 0) "." else namespace);
                return vm.evalSource(source, .q, "<lambda>");
            },
            .unary_primitive => {
                const n = (try self.take(1))[0];
                return if (n == 0) vm.getUnaryPrimitive(.identity) else vm.getUnaryPrimitive(std.enums.fromInt(Value.UnaryPrimitive, n) orelse return error.BadMessage);
            },
            .operator => return vm.getOperator(std.enums.fromInt(Value.Operator, (try self.take(1))[0]) orelse return error.BadMessage),
            .iterator => return vm.getIterator(std.enums.fromInt(Value.Iterator, (try self.take(1))[0]) orelse return error.BadMessage),
            .projection, .composition => {
                const count = try self.int(u32);
                const items = try vm.gpa.alloc(*Value, count);
                defer vm.gpa.free(items);
                var filled: usize = 0;
                defer for (items[0..filled]) |v| v.deref(vm.gpa);
                for (0..count) |_| {
                    items[filled] = try self.value();
                    filled += 1;
                }
                if (count == 0) return error.BadMessage;
                if (tag == .composition) {
                    if (count != 2) return error.BadMessage;
                    return vm.createValue(.composition, .{ .f = items[0].ref(), .g = items[1].ref() });
                }
                return vm.project(items[0], items[1..]);
            },
            inline .each, .over, .scan, .each_prior, .each_right, .each_left => |t| {
                const function = try self.value();
                defer function.deref(vm.gpa);
                return vm.derive(switch (t) {
                    .each => .each,
                    .over => .over,
                    .scan => .scan,
                    .each_prior => .each_prior,
                    .each_right => .each_right,
                    .each_left => .each_left,
                    else => unreachable,
                }, function);
            },
            else => return error.BadMessage,
        }
    }
};

fn deserializeBytes(vm: *Vm, bytes: []const u8) RunError!*Value {
    var reader: Reader = .{ .vm = vm, .bytes = bytes };
    return reader.value() catch |err| switch (err) {
        error.BadMessage => return vm.failWith("badmsg"),
        else => |e| return e,
    };
}

/// `-9!x`: the value the IPC bytes `x` hold; anything malformed is `badmsg`.
pub fn deserialize(vm: *Vm, x: *Value) RunError!*Value {
    if (x.as != .byte_list) return error.type;
    const bytes = x.as.byte_list;
    if (bytes.len < 8 or bytes[0] != 1) return vm.failWith("badmsg");
    if (std.mem.readInt(u32, bytes[4..8], .little) != bytes.len) return vm.failWith("badmsg");
    return deserializeBytes(vm, bytes[8..]);
}

/// `x set y` for a file symbol: writes `y` in q's file format, which holds atoms and
/// compound values as `0xff01` and the IPC bytes, and simple vectors as `0xfe20`, the
/// type and attribute, fourteen zero bytes and the raw items.
pub fn set(vm: *Vm, x: *Value, y: *Value) RunError!*Value {
    const path = try pathOf(vm, x);
    var writer: Writer = .{ .vm = vm };
    defer writer.deinit();
    switch (y.as) {
        inline .boolean_list, .byte_list, .short_list, .int_list, .long_list, .real_list, .float_list, .char_list, .timestamp_list, .month_list, .date_list, .datetime_list, .timespan_list, .minute_list, .second_list, .time_list => |items, tag| {
            try writer.bytes.appendSlice(vm.gpa, &.{ 0xfe, 0x20, @intCast(@backingInt(tag)), @backingInt(y.attr) });
            try writer.bytes.appendNTimes(vm.gpa, 0, 12);
            for (items) |v| {
                const payload = if (@TypeOf(v) == bool) @as(u8, @intFromBool(v)) else v;
                try writer.int(@TypeOf(payload), payload);
            }
        },
        else => {
            try writer.bytes.appendSlice(vm.gpa, &.{ 0xff, 0x01 });
            try writer.value(y);
        },
    }
    try writeAll(vm, path, writer.bytes.items);
    return x.ref();
}

/// `get x` for a file symbol: the value a q data file holds; any other file is an error
/// naming it.
pub fn get(vm: *Vm, x: *Value) RunError!*Value {
    const path = try pathOf(vm, x);
    const bytes = try readAll(vm, path);
    defer vm.gpa.free(bytes);
    if (bytes.len >= 2 and bytes[0] == 0xff and bytes[1] == 0x01) return deserializeBytes(vm, bytes[2..]) catch return vm.failWith(path);
    if (bytes.len >= 16 and bytes[0] == 0xfe and bytes[1] == 0x20) {
        const tag = std.enums.fromInt(Value.Type, @as(i8, @bitCast(bytes[2]))) orelse return vm.failWith(path);
        const data = bytes[16..];
        switch (tag) {
            inline .boolean_list, .byte_list, .short_list, .int_list, .long_list, .real_list, .float_list, .char_list, .timestamp_list, .month_list, .date_list, .datetime_list, .timespan_list, .minute_list, .second_list, .time_list => |t| {
                const result = try vm.allocValue(t, 0);
                errdefer result.deref(vm.gpa);
                const Item = @TypeOf(@field(result.as, @tagName(t))[0]);
                const size = if (Item == bool) 1 else @sizeOf(Item);
                const count = data.len / size;
                const items = try vm.gpa.alloc(Item, count);
                errdefer vm.gpa.free(items);
                var reader: Reader = .{ .vm = vm, .bytes = data };
                for (items) |*slot| {
                    const raw = reader.int(if (Item == bool) u8 else Item) catch unreachable;
                    slot.* = if (Item == bool) raw != 0 else raw;
                }
                vm.gpa.free(@field(result.as, @tagName(t)));
                @field(result.as, @tagName(t)) = items;
                result.attr = @enumFromInt(@min(bytes[3], 4));
                return result;
            },
            else => return vm.failWith(path),
        }
    }
    return vm.failWith(path);
}
