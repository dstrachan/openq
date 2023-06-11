const Token = @import("../../Token.zig");

const testTokens = @import("../scanner.zig").testTokens;

test "short tokens" {
    try testTokens("0h", .{.short});
    try testTokens("2h", .{.short});
    try testTokens("-2h", .{.short});

    try testTokens("0nh", .{.short});
    try testTokens("0Nh", .{.short});
    try testTokens("-0wh", .{.short});
    try testTokens("-0Wh", .{.short});
    try testTokens("0wh", .{.short});
    try testTokens("0Wh", .{.short});
}
