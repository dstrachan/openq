const Token = @import("../../Token.zig");

const testTokens = @import("../scanner.zig").testTokens;

test "long tokens" {
    try testTokens("0", .{.long});
    try testTokens("0j", .{.long});
    try testTokens("2", .{.long});
    try testTokens("2j", .{.long});
    try testTokens("-2", .{.long});
    try testTokens("-2j", .{.long});

    try testTokens("0N", .{.long});
    try testTokens("0nj", .{.long});
    try testTokens("0Nj", .{.long});
    try testTokens("-0W", .{.long});
    try testTokens("-0wj", .{.long});
    try testTokens("-0Wj", .{.long});
    try testTokens("0W", .{.long});
    try testTokens("0wj", .{.long});
    try testTokens("0Wj", .{.long});
}
