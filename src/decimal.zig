//! Exact decimal display of floats with a chosen number of significant digits, matching C's
//! `%.Ng` and so q's `\P`. The binary value is expanded exactly (no shortest-representation
//! shortcuts), which is what makes `0.1` print as `0.10000000000000001` under `\P 17`.

const std = @import("std");
const Io = std.Io;

/// q clamps `\P` to 17 significant digits, and `\P 0` means 17 for floats.
pub const max_precision: u8 = 17;

/// Writes a finite float with `precision` significant digits in `%g` style: trailing zeros
/// are dropped, and exponent form is used when the exponent is below -4 or at least the
/// precision. Returns whether the text looks integral (no point or exponent), which is when
/// q adds an `f` suffix.
pub fn formatG(w: *Io.Writer, value: f64, precision: u8) Io.Writer.Error!bool {
    var buffer: [64]u8 = undefined;
    const text = renderG(&buffer, value, precision);
    try w.writeAll(text);
    return std.mem.findAny(u8, text, ".e") == null;
}

/// `formatG` into a caller-provided buffer of at least 32 bytes.
pub fn renderG(buffer: []u8, value: f64, precision_in: u8) []const u8 {
    std.debug.assert(std.math.isFinite(value));
    const precision: usize = if (precision_in == 0) max_precision else @min(precision_in, max_precision);
    if (value == 0) return renderZero(buffer, value);
    var digits = exactDigits(@abs(value));
    digits.round(precision);
    return layout(buffer, std.math.signbit(value), digits, precision);
}

/// The shortest digits that read back as the same real, laid out in `%g` style: q's `\P 0`
/// display for reals, where `1e10e` prints as `1e+10e` and `1.23456789e` as `1.2345679e`.
pub fn formatShortestReal(w: *Io.Writer, value: f32) Io.Writer.Error!void {
    std.debug.assert(std.math.isFinite(value));
    var buffer: [64]u8 = undefined;
    if (value == 0) return w.writeAll(renderZero(&buffer, value));

    var scientific: [64]u8 = undefined;
    const text = std.fmt.float.render(&scientific, @abs(value), .{ .mode = .scientific }) catch unreachable;
    const e = std.mem.findScalar(u8, text, 'e').?;
    var digits: Digits = .{ .text = undefined, .len = 0, .exponent = std.fmt.parseInt(i32, text[e + 1 ..], 10) catch unreachable };
    for (text[0..e]) |c| if (c != '.') {
        digits.text[digits.len] = c;
        digits.len += 1;
    };
    digits.trim();
    try w.writeAll(layout(&buffer, std.math.signbit(value), digits, digits.len));
}

fn renderZero(buffer: []u8, value: anytype) []const u8 {
    if (std.math.signbit(value)) {
        buffer[0] = '-';
        buffer[1] = '0';
        return buffer[0..2];
    }
    buffer[0] = '0';
    return buffer[0..1];
}

/// Lays out rounded digits the way `%g` does for the given precision.
fn layout(buffer: []u8, negative: bool, digits: Digits, precision: usize) []const u8 {
    var out: usize = 0;
    if (negative) {
        buffer[out] = '-';
        out += 1;
    }

    if (digits.exponent < -4 or digits.exponent >= @as(i32, @intCast(precision))) {
        // d.ddde±XX
        buffer[out] = digits.text[0];
        out += 1;
        if (digits.len > 1) {
            buffer[out] = '.';
            out += 1;
            @memcpy(buffer[out .. out + digits.len - 1], digits.text[1..digits.len]);
            out += digits.len - 1;
        }
        buffer[out] = 'e';
        buffer[out + 1] = if (digits.exponent < 0) '-' else '+';
        out += 2;
        const magnitude: u32 = @abs(digits.exponent);
        const written = std.fmt.bufPrint(buffer[out..], "{d:0>2}", .{magnitude}) catch unreachable;
        out += written.len;
    } else if (digits.exponent >= 0) {
        // ddd.ddd, padding the integer part with zeros when it has more places than digits.
        const integer_places: usize = @intCast(digits.exponent + 1);
        var i: usize = 0;
        while (i < integer_places) : (i += 1) {
            buffer[out] = if (i < digits.len) digits.text[i] else '0';
            out += 1;
        }
        if (digits.len > integer_places) {
            buffer[out] = '.';
            out += 1;
            @memcpy(buffer[out .. out + digits.len - integer_places], digits.text[integer_places..digits.len]);
            out += digits.len - integer_places;
        }
    } else {
        // 0.000ddd
        buffer[out] = '0';
        buffer[out + 1] = '.';
        out += 2;
        var zeros: usize = @intCast(-digits.exponent - 1);
        while (zeros > 0) : (zeros -= 1) {
            buffer[out] = '0';
            out += 1;
        }
        @memcpy(buffer[out .. out + digits.len], digits.text[0..digits.len]);
        out += digits.len;
    }
    return buffer[0..out];
}

/// The exact decimal digits of a positive finite float, without trailing zeros, and the
/// decimal exponent of the first digit.
const Digits = struct {
    text: [800]u8,
    len: usize,
    exponent: i32,

    /// Rounds to `precision` significant digits, half to even on the exact remainder.
    fn round(d: *Digits, precision: usize) void {
        if (d.len <= precision) return;
        const next = d.text[precision];
        var up = next > '5';
        if (next == '5') {
            var nonzero = false;
            for (d.text[precision + 1 .. d.len]) |c| nonzero = nonzero or c != '0';
            up = nonzero or (d.text[precision - 1] - '0') % 2 == 1;
        }
        d.len = precision;
        if (up) {
            var i = d.len;
            while (i > 0) {
                i -= 1;
                if (d.text[i] == '9') {
                    d.text[i] = '0';
                } else {
                    d.text[i] += 1;
                    break;
                }
            } else {
                // Every digit was a 9: the number becomes a power of ten.
                d.text[0] = '1';
                d.len = 1;
                d.exponent += 1;
            }
        }
        d.trim();
    }

    fn trim(d: *Digits) void {
        while (d.len > 1 and d.text[d.len - 1] == '0') d.len -= 1;
    }
};

const Limb = u32;
const limb_base: u64 = 1_000_000_000;

fn exactDigits(value: f64) Digits {
    const bits: u64 = @bitCast(value);
    const biased: u64 = (bits >> 52) & 0x7ff;
    const fraction: u64 = bits & ((@as(u64, 1) << 52) - 1);
    var mantissa: u64 = undefined;
    var exponent: i32 = undefined;
    if (biased == 0) {
        mantissa = fraction;
        exponent = -1074;
    } else {
        mantissa = fraction | (@as(u64, 1) << 52);
        exponent = @as(i32, @intCast(biased)) - 1075;
    }

    // value = mantissa * 2^exponent. Scale to an integer N so that value = N / 10^shift.
    var limbs: [128]Limb = undefined;
    var len: usize = 0;
    var m = mantissa;
    while (m > 0) : (m /= limb_base) {
        limbs[len] = @intCast(m % limb_base);
        len += 1;
    }
    var shift: i32 = 0;
    if (exponent >= 0) {
        var remaining: u32 = @intCast(exponent);
        while (remaining > 0) {
            const step = @min(remaining, 28);
            len = mulSmall(&limbs, len, @as(u32, 1) << @intCast(step));
            remaining -= step;
        }
    } else {
        // m / 2^k = m * 5^k / 10^k.
        var remaining: u32 = @intCast(-exponent);
        shift = @intCast(remaining);
        while (remaining > 0) {
            const step = @min(remaining, 13);
            len = mulSmall(&limbs, len, std.math.pow(u32, 5, step));
            remaining -= step;
        }
    }

    var d: Digits = .{ .text = undefined, .len = 0, .exponent = 0 };
    var i = len;
    while (i > 0) {
        i -= 1;
        var chunk: [9]u8 = undefined;
        // The most significant limb prints without padding; the rest fill nine places.
        const text = if (i == len - 1)
            std.fmt.bufPrint(&chunk, "{d}", .{limbs[i]}) catch unreachable
        else
            std.fmt.bufPrint(&chunk, "{d:0>9}", .{limbs[i]}) catch unreachable;
        @memcpy(d.text[d.len .. d.len + text.len], text);
        d.len += text.len;
    }
    d.exponent = @as(i32, @intCast(d.len)) - 1 - shift;
    d.trim();
    return d;
}

/// Multiplies a little-endian base-10^9 number in place by a factor below 2^32.
fn mulSmall(limbs: *[128]Limb, len: usize, factor: u32) usize {
    var carry: u64 = 0;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const product = @as(u64, limbs[i]) * factor + carry;
        limbs[i] = @intCast(product % limb_base);
        carry = product / limb_base;
    }
    var new_len = len;
    while (carry > 0) : (carry /= limb_base) {
        limbs[new_len] = @intCast(carry % limb_base);
        new_len += 1;
    }
    return new_len;
}

fn expectG(expected: []const u8, value: f64, precision: u8) !void {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(expected, renderG(&buffer, value, precision));
}

test "%g with q's default precision of 7" {
    try expectG("0.3333333", 1.0 / 3.0, 7);
    try expectG("0.6666667", 2.0 / 3.0, 7);
    try expectG("1.234568", 1.23456789, 7);
    try expectG("1.234568e+08", 123456789.0, 7);
    try expectG("1234568", 1234567.5, 7);
    try expectG("1.234568e+07", 12345678.5, 7);
    try expectG("0.0001", 0.0001, 7);
    try expectG("1e-05", 0.00001, 7);
    try expectG("1e+07", 1e7, 7);
    try expectG("1000000", 1e6, 7);
    try expectG("1e+15", 1e15, 7);
    try expectG("9e+15", 9e15, 7);
    try expectG("0.1", 0.1, 7);
    try expectG("100000.5", 100000.5, 7);
    try expectG("1.5e-07", 1.5e-7, 7);
    try expectG("1e+09", 1e9, 7);
    try expectG("1e+300", 1e300, 7);
    try expectG("1.797693e+308", std.math.floatMax(f64), 7);
    try expectG("-0", -0.0, 7);
    try expectG("0.25", 0.25, 7);
    try expectG("3.141593", 3.14159265358979, 7);
    try expectG("2", 1.5, 1);
    try expectG("1e+01", 12.5, 1);
    try expectG("0.1", 0.15, 1);
    try expectG("0.3", 1.0 / 3.0, 1);
}

test "%g with other precisions and the exact expansion at 17" {
    try expectG("0.333", 1.0 / 3.0, 3);
    try expectG("1.23", 1.23456789, 3);
    try expectG("1.23e+03", 1234.5, 3);
    try expectG("1.23e+04", 12345.0, 3);
    try expectG("1e+03", 1000.0, 3);
    try expectG("0.00123", 0.001234, 3);
    try expectG("0.3333333333", 1.0 / 3.0, 10);
    try expectG("1.23456789", 1.23456789, 10);
    try expectG("1.23456789e+12", 1234567890123.0, 10);
    try expectG("1.234567881", @as(f32, 1.23456789), 10);
    try expectG("0.1000000015", @as(f32, 0.1), 10);
    try expectG("123456792", @as(f32, 123456789.0), 10);
    try expectG("0.33333333333333331", 1.0 / 3.0, 17);
    try expectG("0.10000000000000001", 0.1, 17);
    try expectG("1.2345678899999999", 1.23456789, 17);
    try expectG("1.2345678806304932", @as(f32, 1.23456789), 17);
    try expectG("0.10000000149011612", @as(f32, 0.1), 17);
    try expectG("10000000", 1e7, 0);
    try expectG("10000000000000000", 1e16, 0);
    try expectG("1e+17", 1e17, 0);
    try expectG("123456789", 123456789.0, 0);
    try expectG("1.0000000000000001e-05", 1e-5, 0);
    try expectG("0.33333333333333331", 1.0 / 3.0, 20);
}
