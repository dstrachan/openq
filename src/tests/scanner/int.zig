const Token = @import("../../Token.zig");

const testTokens = @import("../scanner.zig").testTokens;

test "int tokens" {
    try testTokens("0i", .{.int});
    try testTokens("2i", .{.int});
    try testTokens("-2i", .{.int});

    try testTokens("0ni", .{.int});
    try testTokens("0Ni", .{.int});
    try testTokens("-0wi", .{.int});
    try testTokens("-0Wi", .{.int});
    try testTokens("0wi", .{.int});
    try testTokens("0Wi", .{.int});
}
