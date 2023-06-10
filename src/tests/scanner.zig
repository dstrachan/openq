const std = @import("std");

const Scanner = @import("../scanner.zig");
const Token = @import("../Token.zig");

fn toSlice(comptime T: type, value: anytype, allocator: std.mem.Allocator) ![]T {
    const ValueType = @TypeOf(value);
    const value_type_info = @typeInfo(ValueType);
    if (value_type_info != .Struct) {
        @compileError("expected tuple or struct argument, found " ++ @typeName(ValueType));
    }

    const fields_info = value_type_info.Struct.fields;
    const values = try allocator.alloc(T, fields_info.len);
    inline for (fields_info, 0..) |field, i| {
        values[i] = @field(value, field.name);
    }

    return values;
}

pub fn testTokens(source: []const u8, tokens: anytype) !void {
    const expected = try toSlice(Token.TokenType, tokens, std.testing.allocator);
    defer std.testing.allocator.free(expected);

    var scanner = Scanner.init(source);
    var actual = std.ArrayList(Token.TokenType).init(std.testing.allocator);
    defer actual.deinit();
    while (scanner.nextToken()) |token| {
        try actual.append(token.token_type);
    }

    std.testing.expectEqualSlices(Token.TokenType, expected, actual.items) catch |e| {
        std.debug.print("{s}\n\n================================================\n\n", .{source});
        return e;
    };
}

test "scanner" {
    _ = @import("scanner/boolean.zig");
    _ = @import("scanner/guid.zig");
    _ = @import("scanner/byte.zig");
}
