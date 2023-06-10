const std = @import("std");

const Scanner = @import("../scanner.zig");
const Token = @import("../Token.zig");

pub fn testTokens(source: []const u8, expected: []const Token.TokenType) !void {
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
