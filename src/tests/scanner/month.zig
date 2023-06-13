const Token = @import("../../Token.zig");

const testTokens = @import("../scanner.zig").testTokens;

test "month tokens" {
    try testTokens("0001m", .{.month});
    try testTokens("0012m", .{.month});
    try testTokens("9901m", .{.month});
    try testTokens("9912m", .{.month});

    try testTokens("000101m", .{.month});
    try testTokens("000112m", .{.month});
    try testTokens("999901m", .{.month});
    try testTokens("999912m", .{.month});

    try testTokens("0001.01m", .{.month});
    try testTokens("0001.12m", .{.month});
    try testTokens("0002.01m", .{.month});
    try testTokens("0002.12m", .{.month});
    try testTokens("9999.01m", .{.month});
    try testTokens("9999.12m", .{.month});

    try testTokens("0nm", .{.month});
    try testTokens("0Nm", .{.month});
    try testTokens("0wm", .{.month});
    try testTokens("0Wm", .{.month});
    try testTokens("-0wm", .{.month});
    try testTokens("-0Wm", .{.month});
}

test "invalid month tokens" {
    try testTokens("0m", .{.invalid});
    try testTokens("9m", .{.invalid});
    try testTokens("00m", .{.invalid});
    try testTokens("02m", .{.invalid});
    try testTokens("99m", .{.invalid});
    try testTokens("000m", .{.invalid});
    try testTokens("002m", .{.invalid});
    try testTokens("999m", .{.invalid});

    try testTokens("0000m", .{.invalid});
    try testTokens("9999m", .{.invalid});

    try testTokens("000000m", .{.invalid});
    try testTokens("000001m", .{.invalid});
    try testTokens("000002m", .{.invalid});
    try testTokens("000013m", .{.invalid});
    try testTokens("000100m", .{.invalid});
    try testTokens("000113m", .{.invalid});
    try testTokens("999900m", .{.invalid});
    try testTokens("999913m", .{.invalid});

    try testTokens("0001.00m", .{.invalid});
    try testTokens("0001.13m", .{.invalid});
    try testTokens("0002.00m", .{.invalid});
    try testTokens("0002.13m", .{.invalid});
    try testTokens("9999.00m", .{.invalid});
    try testTokens("9999.13m", .{.invalid});
}
