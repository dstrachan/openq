const Token = @import("../../Token.zig");

const testTokens = @import("../scanner.zig").testTokens;

test "symbol tokens" {
    try testTokens("`", .{.symbol});
    try testTokens("`a", .{.symbol});
    try testTokens("`test", .{.symbol});
    try testTokens("`test_with_underscores", .{.symbol});
    try testTokens("`0test", .{.symbol});
    try testTokens("`test0", .{.symbol});
    try testTokens("`test.with.dots", .{.symbol});
    try testTokens("`.test.with.leading.dot", .{.symbol});
    try testTokens("`test:with:colons", .{.symbol});
    try testTokens("`:test:with:leading:colon", .{.symbol});
    try testTokens("`:test/with/slash", .{.symbol});

    try testTokens("`_fails_with_leading_underscore", .{ .symbol, .underscore, .identifier });
    try testTokens("`no_colon_test/with_slash_fails", .{ .symbol, .forward_slash, .identifier });
}

test "symbol_list tokens" {
    try testTokens("``", .{.symbol_list});
    try testTokens("`a`b`c", .{.symbol_list});
    try testTokens("``b`c", .{.symbol_list});
    try testTokens("`a``c", .{.symbol_list});
    try testTokens("`a`b`", .{.symbol_list});
    try testTokens("`:a`:b`:c", .{.symbol_list});
    try testTokens("``:b`:c", .{.symbol_list});
    try testTokens("`:a``:c", .{.symbol_list});
    try testTokens("`:a`:b`", .{.symbol_list});
}
