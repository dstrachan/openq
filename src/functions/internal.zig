//! The internal functions `n!x` beyond parse, eval and the ones defined with the
//! operators: `-7!` hcount, `-12!` host, `-13!` addr, `-20!` gc, `-29!` JSON reading,
//! `-31!` JSON writing, `-34!` ts, `-35!` gzip and `-39!` ld. Verified against q 5.0.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const q = @import("../root.zig");
const Vm = q.Vm;
const Value = q.Value;
const RunError = Vm.RunError;

fn textValue(vm: *Vm, bytes: []const u8) Allocator.Error!*Value {
    const v = try vm.allocValue(.char_list, bytes.len);
    errdefer comptime unreachable;
    @memcpy(v.as.char_list, bytes);
    return v;
}

/// The path a file symbol names, without its leading colon.
fn pathOf(vm: *Vm, y: *Value) error{type}![]const u8 {
    if (y.as != .symbol) return error.type;
    const text = vm.internedString(y.as.symbol);
    return if (text.len > 0 and text[0] == ':') text[1..] else text;
}

fn osMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory",
        error.IsDir => "Is a directory",
        error.AccessDenied, error.PermissionDenied => "Permission denied",
        error.NotDir => "Not a directory",
        else => @errorName(err),
    };
}

/// A failure the way q reports one about a file: `'path. OS reports: message`.
fn failOs(vm: *Vm, path: []const u8, err: anyerror) RunError {
    const message = try std.fmt.allocPrint(vm.gpa, "{s}. OS reports: {s}", .{ path, osMessage(err) });
    defer vm.gpa.free(message);
    return vm.failWith(message);
}

/// `-7!x` hcount: the size in bytes of the file a symbol names.
pub fn hcount(vm: *Vm, y: *Value) RunError!*Value {
    const path = try pathOf(vm, y);
    const stat = Io.Dir.cwd().statFile(vm.io, path, .{}) catch |err| return failOs(vm, path, err);
    if (stat.kind == .directory) return failOs(vm, path, error.IsDir);
    return vm.createValue(.long, @intCast(stat.size));
}

/// `-20!x` gc: the bytes returned to the system, none here.
pub fn gc(vm: *Vm, y: *Value) RunError!*Value {
    _ = y;
    return vm.createValue(.long, 0);
}

fn dotted(ip: u32) [15]u8 {
    var buffer: [15]u8 = undefined;
    _ = std.fmt.bufPrint(&buffer, "{d}.{d}.{d}.{d}", .{ ip >> 24, (ip >> 16) & 255, (ip >> 8) & 255, ip & 255 }) catch unreachable;
    return buffer;
}

fn dottedLen(ip: u32) usize {
    var buffer: [15]u8 = undefined;
    return (std.fmt.bufPrint(&buffer, "{d}.{d}.{d}.{d}", .{ ip >> 24, (ip >> 16) & 255, (ip >> 8) & 255, ip & 255 }) catch unreachable).len;
}

/// Looks a name or a dotted address up in `/etc/hosts`; `by_name` finds the address of a
/// name, otherwise the first name of an address. Names compare without case.
fn hostsFile(vm: *Vm, key: []const u8, by_name: bool) Allocator.Error!?[]const u8 {
    const text = Io.Dir.cwd().readFileAlloc(vm.io, "/etc/hosts", vm.gpa, .unlimited) catch return null;
    defer vm.gpa.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = raw[0 .. std.mem.findScalar(u8, raw, '#') orelse raw.len];
        var fields = std.mem.tokenizeAny(u8, line, " \t\r");
        const address = fields.next() orelse continue;
        if (by_name) {
            while (fields.next()) |name| if (std.ascii.eqlIgnoreCase(name, key)) return try vm.gpa.dupe(u8, address);
        } else if (std.mem.eql(u8, address, key)) {
            const name = fields.next() orelse continue;
            return try vm.gpa.dupe(u8, name);
        }
    }
    return null;
}

fn parseDotted(text: []const u8) ?u32 {
    var parts = std.mem.splitScalar(u8, text, '.');
    var ip: u32 = 0;
    var n: usize = 0;
    while (parts.next()) |part| : (n += 1) {
        if (n == 4 or part.len == 0) return null;
        const byte = std.fmt.parseInt(u8, part, 10) catch return null;
        ip = (ip << 8) | byte;
    }
    return if (n == 4) ip else null;
}

/// `-12!x` host: the name an int IP address has in `/etc/hosts`, or the dotted address.
pub fn host(vm: *Vm, y: *Value) RunError!*Value {
    if (y.as != .int) return error.type;
    const ip: u32 = @bitCast(y.as.int);
    const text = dotted(ip);
    const address = text[0..dottedLen(ip)];
    if (try hostsFile(vm, address, false)) |name| {
        defer vm.gpa.free(name);
        return vm.createValue(.symbol, try vm.intern(name));
    }
    return vm.createValue(.symbol, try vm.intern(address));
}

/// `-13!x` addr: the int IP address of a host name: `localhost` and `` ` `` are the
/// loopback, a dotted address reads as itself, other names come from `/etc/hosts` or
/// DNS, and an unknown name is `-1i`.
pub fn addr(vm: *Vm, y: *Value) RunError!*Value {
    if (y.as != .symbol) return error.type;
    const name = vm.internedString(y.as.symbol);
    if (name.len == 0 or std.ascii.eqlIgnoreCase(name, "localhost")) return vm.createValue(.int, 2130706433);
    if (parseDotted(name)) |ip| return vm.createValue(.int, @bitCast(ip));
    if (try hostsFile(vm, name, true)) |address| {
        defer vm.gpa.free(address);
        if (parseDotted(address)) |ip| return vm.createValue(.int, @bitCast(ip));
    }
    return vm.createValue(.int, if (try dns(vm, name)) |ip| @bitCast(ip) else -1);
}

fn dns(vm: *Vm, name: []const u8) Allocator.Error!?u32 {
    const host_name = Io.net.HostName.init(name) catch return null;
    var buffer: [16]Io.net.HostName.LookupResult = undefined;
    var results: Io.Queue(Io.net.HostName.LookupResult) = .init(&buffer);
    host_name.lookup(vm.io, &results, .{ .port = 0 }) catch return null;
    var found: ?u32 = null;
    while (results.getOneUncancelable(vm.io)) |result| {
        switch (result) {
            .address => |address| if (found == null and address == .ip4) {
                found = std.mem.readInt(u32, &address.ip4.bytes, .big);
            },
            .canonical_name => {},
        }
    } else |_| {}
    return found;
}

/// `-34!(f;args)` ts: `(elapsed milliseconds and bytes; f . args)`; the bytes are 0 here.
pub fn ts(vm: *Vm, y: *Value) RunError!*Value {
    if (y.as != .list or y.as.list.len != 2 or !y.as.list[1].isList()) return error.type;
    const start = q.clock.now(vm.io);
    const result = try q.operators.apply(vm, y.as.list[0], y.as.list[1]);
    errdefer result.deref(vm.gpa);
    const elapsed = q.clock.now(vm.io) - start;
    const measure = try vm.allocValue(.long_list, 2);
    errdefer measure.deref(vm.gpa);
    measure.as.long_list[0] = @divTrunc(elapsed, 1_000_000);
    measure.as.long_list[1] = 0;
    const pair = try vm.allocValue(.list, 2);
    errdefer comptime unreachable;
    pair.as.list[0] = measure;
    pair.as.list[1] = result;
    return pair;
}

/// `-39!lines` ld: script lines joined into statements, an indented line continuing the
/// one before it (a leading tab becoming a space), with the 1-based line each statement
/// starts on. A statement that begins with an empty line and continues is dropped, as q
/// drops it.
pub fn ld(vm: *Vm, y: *Value) RunError!*Value {
    if (y.as != .list) return error.type;
    for (y.as.list) |line| if (line.as != .char_list) return error.type;
    var starts: std.ArrayList(i64) = .empty;
    defer starts.deinit(vm.gpa);
    var statements: std.ArrayList(std.ArrayList(u8)) = .empty;
    defer {
        for (statements.items) |*s| s.deinit(vm.gpa);
        statements.deinit(vm.gpa);
    }
    var dropped = false;
    for (y.as.list, 1..) |line, number| {
        const text = line.as.char_list;
        const continues = text.len > 0 and (text[0] == ' ' or text[0] == '\t');
        if (continues) {
            if (statements.items.len == 0 or dropped) continue;
            const current = &statements.items[statements.items.len - 1];
            if (current.items.len == 0) {
                current.deinit(vm.gpa);
                _ = statements.pop();
                _ = starts.pop();
                dropped = true;
                continue;
            }
            try current.append(vm.gpa, '\n');
            try current.append(vm.gpa, ' ');
            try current.appendSlice(vm.gpa, text[1..]);
            continue;
        }
        dropped = false;
        try starts.append(vm.gpa, @intCast(number));
        var statement: std.ArrayList(u8) = .empty;
        try statement.appendSlice(vm.gpa, text);
        try statements.append(vm.gpa, statement);
    }
    const numbers = try vm.allocValue(.long_list, starts.items.len);
    errdefer numbers.deref(vm.gpa);
    @memcpy(numbers.as.long_list, starts.items);
    const texts = try vm.allocValue(.list, statements.items.len);
    var filled: usize = 0;
    errdefer {
        for (texts.as.list[0..filled]) |t| t.deref(vm.gpa);
        vm.gpa.free(texts.as.list);
        vm.gpa.destroy(texts);
    }
    for (statements.items) |s| {
        texts.as.list[filled] = try textValue(vm, s.items);
        filled += 1;
    }
    const pair = try vm.allocValue(.list, 2);
    errdefer comptime unreachable;
    pair.as.list[0] = numbers;
    pair.as.list[1] = texts;
    return pair;
}

// ---------------------------------------------------------------------------------------
// gzip.

/// `-35!(level;bytes)` compresses with gzip and `-35!bytes` decompresses; a string goes
/// in and comes out as a string. The level runs 0 to 9 with -1 the default 6 (else
/// `domain`); the header carries q's flag byte for the level and its OS byte, level 0
/// writes stored blocks, and the other levels use Zig's deflate, whose output can differ
/// from zlib's for the same input. Decompressing anything but gzip data is `length`.
pub fn gzip(vm: *Vm, y: *Value) RunError!*Value {
    if (y.as == .list) {
        if (y.as.list.len != 2) return error.type;
        const level: i64 = switch (y.as.list[0].as) {
            .long => |v| v,
            else => return error.type,
        };
        if (level < -1 or level > 9) return error.domain;
        const data = y.as.list[1];
        const bytes: []const u8 = switch (data.as) {
            .byte_list => |b| b,
            .char_list => |c| c,
            else => return error.type,
        };
        const out = try compress(vm, if (level == -1) 6 else @intCast(level), bytes);
        defer vm.gpa.free(out);
        return bytesLike(vm, data, out);
    }
    const bytes: []const u8 = switch (y.as) {
        .byte_list => |b| b,
        .char_list => |c| c,
        else => return error.type,
    };
    if (bytes.len < 18 or bytes[0] != 0x1f or bytes[1] != 0x8b) return error.length;
    var reader: Io.Reader = .fixed(bytes);
    const window = try vm.gpa.alloc(u8, std.compress.flate.max_window_len);
    defer vm.gpa.free(window);
    var decompress: std.compress.flate.Decompress = .init(&reader, .gzip, window);
    const out = decompress.reader.allocRemaining(vm.gpa, .unlimited) catch return error.length;
    defer vm.gpa.free(out);
    return bytesLike(vm, y, out);
}

fn bytesLike(vm: *Vm, like: *Value, bytes: []const u8) Allocator.Error!*Value {
    if (like.as == .char_list) return textValue(vm, bytes);
    const result = try vm.allocValue(.byte_list, bytes.len);
    errdefer comptime unreachable;
    @memcpy(result.as.byte_list, bytes);
    return result;
}

fn compress(vm: *Vm, level: u8, bytes: []const u8) RunError![]u8 {
    var out: Io.Writer.Allocating = .init(vm.gpa);
    defer out.deinit();
    const w = &out.writer;
    const flag: u8 = switch (level) {
        0, 1 => 4,
        9 => 2,
        else => 0,
    };
    w.writeAll(&.{ 0x1f, 0x8b, 8, 0, 0, 0, 0, 0, flag, 0x13 }) catch return error.OutOfMemory;
    if (level == 0) {
        var rest = bytes;
        while (true) {
            const chunk = rest[0..@min(rest.len, 65535)];
            rest = rest[chunk.len..];
            const final: u8 = @intFromBool(rest.len == 0);
            w.writeByte(final) catch return error.OutOfMemory;
            w.writeInt(u16, @intCast(chunk.len), .little) catch return error.OutOfMemory;
            w.writeInt(u16, ~@as(u16, @intCast(chunk.len)), .little) catch return error.OutOfMemory;
            w.writeAll(chunk) catch return error.OutOfMemory;
            if (rest.len == 0) break;
        }
    } else {
        const window = try vm.gpa.alloc(u8, std.compress.flate.max_window_len);
        defer vm.gpa.free(window);
        const options: std.compress.flate.Compress.Options = switch (level) {
            1 => .level_1,
            2 => .level_2,
            3 => .level_3,
            4 => .level_4,
            5 => .level_5,
            6 => .level_6,
            7 => .level_7,
            8 => .level_8,
            else => .level_9,
        };
        var deflate = std.compress.flate.Compress.init(w, window, .raw, options) catch return error.OutOfMemory;
        deflate.writer.writeAll(bytes) catch return error.OutOfMemory;
        deflate.finish() catch return error.OutOfMemory;
    }
    w.writeInt(u32, std.hash.Crc32.hash(bytes), .little) catch return error.OutOfMemory;
    w.writeInt(u32, @truncate(bytes.len), .little) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------------------
// JSON.

/// `-29!x` reads JSON from a string or byte list the way `.j.k` does: numbers are floats,
/// strings are strings, `true` and `false` booleans, `null` is `0n`, arrays are lists
/// unified like any list and objects are dictionaries with symbol keys. q turns an array
/// of like objects, and a nested object, into a table; here they stay a list of
/// dictionaries and a one-item list holding the dictionary until tables exist. Errors
/// carry q's text: `illegal char c at n`, `partial token at n`, `unclosed ] at n`.
pub fn readJson(vm: *Vm, y: *Value) RunError!*Value {
    const text: []const u8 = switch (y.as) {
        .char_list => |c| c,
        .byte_list => |b| b,
        else => {
            const message = try std.fmt.allocPrint(vm.gpa, "expected char or byte vector, but got type {d}", .{@backingInt(std.meta.activeTag(y.as))});
            defer vm.gpa.free(message);
            return vm.failWith(message);
        },
    };
    var parser: JsonReader = .{ .vm = vm, .text = text, .i = 0 };
    parser.skipSpace();
    if (parser.i >= text.len) return parser.partial();
    const value = try parser.value();
    errdefer value.deref(vm.gpa);
    parser.skipSpace();
    if (parser.i < text.len) return parser.illegal();
    return value;
}

const JsonReader = struct {
    vm: *Vm,
    text: []const u8,
    i: usize,

    fn peek(p: *JsonReader) u8 {
        return if (p.i < p.text.len) p.text[p.i] else ' ';
    }

    fn skipSpace(p: *JsonReader) void {
        while (p.i < p.text.len and (p.text[p.i] == ' ' or p.text[p.i] == '\t' or p.text[p.i] == '\n' or p.text[p.i] == '\r')) p.i += 1;
    }

    fn illegal(p: *JsonReader) RunError {
        const message = try std.fmt.allocPrint(p.vm.gpa, "illegal char {c} at {d}", .{ p.peek(), p.i });
        defer p.vm.gpa.free(message);
        return p.vm.failWith(message);
    }

    fn partial(p: *JsonReader) RunError {
        const message = try std.fmt.allocPrint(p.vm.gpa, "partial token at {d}", .{p.text.len + 1});
        defer p.vm.gpa.free(message);
        return p.vm.failWith(message);
    }

    fn unclosed(p: *JsonReader, close: u8) RunError {
        const message = try std.fmt.allocPrint(p.vm.gpa, "unclosed {c} at {d}", .{ close, p.text.len + 1 });
        defer p.vm.gpa.free(message);
        return p.vm.failWith(message);
    }

    fn value(p: *JsonReader) RunError!*Value {
        const vm = p.vm;
        switch (p.peek()) {
            '[' => {
                p.i += 1;
                var items: std.ArrayList(*Value) = .empty;
                defer items.deinit(vm.gpa);
                defer for (items.items) |item| item.deref(vm.gpa);
                p.skipSpace();
                if (p.peek() == ']') {
                    p.i += 1;
                    return vm.allocValue(.list, 0);
                }
                while (true) {
                    p.skipSpace();
                    if (p.i >= p.text.len) return p.unclosed(']');
                    try items.append(vm.gpa, try p.value());
                    p.skipSpace();
                    if (p.i >= p.text.len) return p.unclosed(']');
                    switch (p.peek()) {
                        ',' => p.i += 1,
                        ']' => {
                            p.i += 1;
                            return vm.enlist(items.items);
                        },
                        else => return p.illegal(),
                    }
                }
            },
            '{' => {
                p.i += 1;
                var keys: std.ArrayList(Value.Symbol) = .empty;
                defer keys.deinit(vm.gpa);
                var values: std.ArrayList(*Value) = .empty;
                defer values.deinit(vm.gpa);
                defer for (values.items) |item| item.deref(vm.gpa);
                p.skipSpace();
                if (p.peek() == '}') p.i += 1 else while (true) {
                    p.skipSpace();
                    if (p.i >= p.text.len) return p.unclosed('}');
                    if (p.peek() != '"') return p.illegal();
                    const key = try p.string();
                    defer vm.gpa.free(key);
                    try keys.append(vm.gpa, try vm.intern(key));
                    p.skipSpace();
                    if (p.i >= p.text.len) return p.unclosed('}');
                    if (p.peek() != ':') return p.illegal();
                    p.i += 1;
                    p.skipSpace();
                    if (p.i >= p.text.len) return p.unclosed('}');
                    try values.append(vm.gpa, try p.value());
                    p.skipSpace();
                    if (p.i >= p.text.len) return p.unclosed('}');
                    switch (p.peek()) {
                        ',' => p.i += 1,
                        '}' => {
                            p.i += 1;
                            break;
                        },
                        else => return p.illegal(),
                    }
                }
                const key_list = try vm.allocValue(.symbol_list, keys.items.len);
                errdefer key_list.deref(vm.gpa);
                @memcpy(key_list.as.symbol_list, keys.items);
                const value_list = if (values.items.len == 0) try vm.allocValue(.list, 0) else try vm.enlist(values.items);
                errdefer value_list.deref(vm.gpa);
                return vm.createValue(.dict, .{ .keys = key_list, .values = value_list });
            },
            '"' => {
                const text = try p.string();
                defer vm.gpa.free(text);
                return textValue(vm, text);
            },
            't' => return p.word("true", try vm.createValue(.boolean, true)),
            'f' => return p.word("false", try vm.createValue(.boolean, false)),
            'n' => return p.word("null", try vm.createValue(.float, std.math.nan(f64))),
            '-', '0'...'9' => return p.number(),
            else => return p.illegal(),
        }
    }

    fn word(p: *JsonReader, expected: []const u8, result: *Value) RunError!*Value {
        errdefer result.deref(p.vm.gpa);
        for (expected) |c| {
            if (p.peek() != c) return p.illegal();
            p.i += 1;
        }
        return result;
    }

    /// A number: JSON's grammar, an integer read as a long that saturates and then
    /// becomes a float, anything with a fraction or an exponent read as a float.
    fn number(p: *JsonReader) RunError!*Value {
        const start = p.i;
        if (p.peek() == '-') p.i += 1;
        if (p.peek() == '0') {
            p.i += 1;
        } else if (p.peek() >= '1' and p.peek() <= '9') {
            while (p.peek() >= '0' and p.peek() <= '9') p.i += 1;
        } else return p.illegal();
        var integral = true;
        if (p.peek() == '.') {
            integral = false;
            p.i += 1;
            if (!(p.peek() >= '0' and p.peek() <= '9')) return p.illegal();
            while (p.peek() >= '0' and p.peek() <= '9') p.i += 1;
        }
        if (p.peek() == 'e' or p.peek() == 'E') {
            integral = false;
            p.i += 1;
            if (p.peek() == '+' or p.peek() == '-') p.i += 1;
            if (!(p.peek() >= '0' and p.peek() <= '9')) return p.illegal();
            while (p.peek() >= '0' and p.peek() <= '9') p.i += 1;
        }
        const text = p.text[start..p.i];
        if (integral) {
            const v: i64 = std.fmt.parseInt(i64, text, 10) catch |err| switch (err) {
                error.Overflow => if (text[0] == '-') @as(i64, std.math.minInt(i64) + 1) else @as(i64, std.math.maxInt(i64)),
                else => unreachable,
            };
            return p.vm.createValue(.float, @floatFromInt(v));
        }
        return p.vm.createValue(.float, std.fmt.parseFloat(f64, text) catch unreachable);
    }

    /// A string literal, decoded, as owned bytes. Runs off the end are `partial token`.
    fn string(p: *JsonReader) RunError![]u8 {
        const vm = p.vm;
        p.i += 1;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(vm.gpa);
        while (true) {
            if (p.i >= p.text.len) return p.partial();
            const c = p.text[p.i];
            p.i += 1;
            switch (c) {
                '"' => return out.toOwnedSlice(vm.gpa),
                '\\' => {
                    if (p.i >= p.text.len) return p.partial();
                    const e = p.text[p.i];
                    p.i += 1;
                    switch (e) {
                        '"', '\\', '/' => try out.append(vm.gpa, e),
                        'b' => try out.append(vm.gpa, 8),
                        'f' => try out.append(vm.gpa, 12),
                        'n' => try out.append(vm.gpa, '\n'),
                        'r' => try out.append(vm.gpa, '\r'),
                        't' => try out.append(vm.gpa, '\t'),
                        'u' => {
                            if (p.i + 4 > p.text.len) return p.partial();
                            var code: u21 = std.fmt.parseInt(u16, p.text[p.i .. p.i + 4], 16) catch return p.illegal();
                            p.i += 4;
                            if (code >= 0xd800 and code < 0xdc00 and p.i + 6 <= p.text.len and p.text[p.i] == '\\' and p.text[p.i + 1] == 'u') {
                                const low = std.fmt.parseInt(u16, p.text[p.i + 2 .. p.i + 6], 16) catch return p.illegal();
                                if (low >= 0xdc00 and low < 0xe000) {
                                    code = 0x10000 + ((code - 0xd800) << 10) + (low - 0xdc00);
                                    p.i += 6;
                                }
                            }
                            var buffer: [4]u8 = undefined;
                            const len = std.unicode.utf8Encode(code, &buffer) catch return p.illegal();
                            try out.appendSlice(vm.gpa, buffer[0..len]);
                        },
                        else => return p.illegal(),
                    }
                },
                else => try out.append(vm.gpa, c),
            }
        }
    }
};

/// `-31!(x;options)` writes JSON the way `.j.j` does, with an empty dictionary of
/// options: longs and other integers as numbers, floats to `\P` digits (`inf` and
/// `-inf` for the infinities), integer nulls and `::` as `null`, booleans, strings and
/// symbols as strings with `\"`, `\\`, `\n`, `\r`, `\t`, `\b`, `\f` and `\u00xx` escapes,
/// bytes as hex strings, temporal values as ISO text (`"2023-01-01"`,
/// `"2023-01-01T12:00:00.000000000"`, a null as `""`), lists as arrays, dictionaries as
/// objects whose keys are the keys' text, and functions as their display text.
pub fn writeJson(vm: *Vm, y: *Value) RunError!*Value {
    if (y.as != .list or y.as.list.len != 2) return error.type;
    const options = y.as.list[1];
    if (options.as != .dict or options.as.dict.keys.as != .symbol_list or options.as.dict.keys.count() != 0) return error.type;
    var out: Io.Writer.Allocating = .init(vm.gpa);
    defer out.deinit();
    try jsonValue(vm, &out.writer, y.as.list[0]);
    return textValue(vm, out.written());
}

fn jsonString(w: *Io.Writer, text: []const u8) Io.Writer.Error!void {
    try w.writeByte('"');
    for (text) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        8 => try w.writeAll("\\b"),
        12 => try w.writeAll("\\f"),
        0...7, 11, 14...31 => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn jsonFloat(vm: *Vm, w: *Io.Writer, v: f64) Io.Writer.Error!void {
    if (std.math.isNan(v)) return w.writeAll("null");
    if (std.math.isInf(v)) return w.writeAll(if (v < 0) "-inf" else "inf");
    _ = try q.decimal.formatG(w, v, vm.precision);
}

/// Temporal values as JSON text: q's display with the date's dots as dashes, the `D` of a
/// timestamp as `T`, a month without its `m`, an infinite date as `0000-00-00` and any
/// null as an empty string.
fn jsonTemporal(vm: *Vm, w: *Io.Writer, x: *Value) RunError!void {
    if (isNullTemporal(x)) return w.writeAll("\"\"");
    if (x.as == .date and (x.as.date == std.math.maxInt(i32) or x.as.date == -std.math.maxInt(i32))) return w.writeAll("\"0000-00-00\"");
    var buffer: Io.Writer.Allocating = .init(vm.gpa);
    defer buffer.deinit();
    buffer.writer.print("{f}", .{x.fmt(vm)}) catch return error.OutOfMemory;
    var text = buffer.written();
    switch (x.as) {
        .month => text = text[0 .. text.len - 1],
        else => {},
    }
    switch (x.as) {
        .date, .month, .datetime, .timestamp => {
            const date_len: usize = @min(text.len, if (x.as == .month) @as(usize, 7) else @as(usize, 10));
            for (text[0..date_len]) |*c| if (c.* == '.') {
                c.* = '-';
            };
            if (x.as == .timestamp and text.len > 10) text[10] = 'T';
        },
        else => {},
    }
    try jsonString(w, text);
}

fn isNullTemporal(x: *Value) bool {
    return switch (x.as) {
        .month, .date, .minute, .second, .time => |v| v == std.math.minInt(i32),
        .timestamp, .timespan => |v| v == std.math.minInt(i64),
        .datetime => |v| std.math.isNan(v),
        else => false,
    };
}

fn jsonValue(vm: *Vm, w: *Io.Writer, x: *Value) RunError!void {
    switch (x.as) {
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .byte => |b| try w.print("\"{x:0>2}\"", .{b}),
        .short => |v| if (v == std.math.minInt(i16)) try w.writeAll("null") else try w.print("{d}", .{v}),
        .int => |v| if (v == std.math.minInt(i32)) try w.writeAll("null") else try w.print("{d}", .{v}),
        .long => |v| if (v == std.math.minInt(i64)) try w.writeAll("null") else try w.print("{d}", .{v}),
        .real => |v| try jsonFloat(vm, w, v),
        .float => |v| try jsonFloat(vm, w, v),
        .char => |c| try jsonString(w, &.{c}),
        .char_list => |s| try jsonString(w, s),
        .symbol => |s| try jsonString(w, vm.internedString(s)),
        .timestamp, .month, .date, .datetime, .timespan, .minute, .second, .time => try jsonTemporal(vm, w, x),
        .dict => |d| {
            try w.writeByte('{');
            const n = d.keys.count();
            for (0..n) |i| {
                if (i > 0) try w.writeByte(',');
                const key = try q.operators.itemAt(vm, d.keys, i);
                defer key.deref(vm.gpa);
                const text = try q.unary_primitives.string(vm, key);
                defer text.deref(vm.gpa);
                if (text.as == .char_list) try jsonString(w, text.as.char_list) else try jsonValue(vm, w, key);
                try w.writeByte(':');
                const item = try q.operators.itemAt(vm, d.values, i);
                defer item.deref(vm.gpa);
                try jsonValue(vm, w, item);
            }
            try w.writeByte('}');
        },
        .unary_primitive => |p| if (p == .identity) try w.writeAll("null") else try jsonFunction(vm, w, x),
        .lambda, .operator, .iterator, .projection, .composition, .each, .over, .scan, .each_prior, .each_right, .each_left => try jsonFunction(vm, w, x),
        else => {
            try w.writeByte('[');
            const n = x.count();
            for (0..n) |i| {
                if (i > 0) try w.writeByte(',');
                const item = try q.operators.itemAt(vm, x, i);
                defer item.deref(vm.gpa);
                try jsonValue(vm, w, item);
            }
            try w.writeByte(']');
        },
    }
}

fn jsonFunction(vm: *Vm, w: *Io.Writer, x: *Value) RunError!void {
    var buffer: Io.Writer.Allocating = .init(vm.gpa);
    defer buffer.deinit();
    buffer.writer.print("{f}", .{x.fmt(vm)}) catch return error.OutOfMemory;
    try jsonString(w, buffer.written());
}
