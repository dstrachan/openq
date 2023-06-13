const Token = @import("../../Token.zig");

const testTokens = @import("../scanner.zig").testTokens;

test "date tokens" {
    try testTokens("000101d", .{.date});
    try testTokens("000131d", .{.date});
    try testTokens("001201d", .{.date});
    try testTokens("001231d", .{.date});
    try testTokens("990101d", .{.date});
    try testTokens("990131d", .{.date});
    try testTokens("991201d", .{.date});
    try testTokens("991231d", .{.date});

    try testTokens("00010101d", .{.date});
    try testTokens("00010131d", .{.date});
    try testTokens("00011201d", .{.date});
    try testTokens("00011231d", .{.date});
    try testTokens("99990101d", .{.date});
    try testTokens("99990131d", .{.date});
    try testTokens("99991201d", .{.date});
    try testTokens("99991231d", .{.date});

    try testTokens("0001.01.01", .{.date});
    try testTokens("0001.01.31", .{.date});
    try testTokens("0001.12.01", .{.date});
    try testTokens("0001.12.31", .{.date});
    try testTokens("9999.01.01", .{.date});
    try testTokens("9999.01.31", .{.date});
    try testTokens("9999.12.01", .{.date});
    try testTokens("9999.12.31", .{.date});

    try testTokens("0nd", .{.date});
    try testTokens("0Nd", .{.date});
    try testTokens("0wd", .{.date});
    try testTokens("0Wd", .{.date});
    try testTokens("-0wd", .{.date});
    try testTokens("-0Wd", .{.date});
}

test "invalid date tokens" {
    try testTokens("0d", .{.invalid});
    try testTokens("9d", .{.invalid});
    try testTokens("00d", .{.invalid});
    try testTokens("02d", .{.invalid});
    try testTokens("99d", .{.invalid});
    try testTokens("000d", .{.invalid});
    try testTokens("002d", .{.invalid});
    try testTokens("999d", .{.invalid});
    try testTokens("0000d", .{.invalid});
    try testTokens("0002d", .{.invalid});
    try testTokens("9999d", .{.invalid});

    try testTokens("000000d", .{.invalid});
    try testTokens("000001d", .{.invalid});
    try testTokens("000002d", .{.invalid});
    try testTokens("000032d", .{.invalid});
    try testTokens("000100d", .{.invalid});
    try testTokens("000132d", .{.invalid});
    try testTokens("990000d", .{.invalid});
    try testTokens("990001d", .{.invalid});
    try testTokens("990002d", .{.invalid});
    try testTokens("990032d", .{.invalid});
    try testTokens("990100d", .{.invalid});
    try testTokens("990132d", .{.invalid});

    try testTokens("00000000d", .{.invalid});
    try testTokens("00000001d", .{.invalid});
    try testTokens("00000002d", .{.invalid});
    try testTokens("00000032d", .{.invalid});
    try testTokens("00000100d", .{.invalid});
    try testTokens("00000101d", .{.invalid});
    try testTokens("00000102d", .{.invalid});
    try testTokens("00000132d", .{.invalid});
    try testTokens("00001300d", .{.invalid});
    try testTokens("00001301d", .{.invalid});
    try testTokens("00001332d", .{.invalid});
    try testTokens("00010000d", .{.invalid});
    try testTokens("00010001d", .{.invalid});
    try testTokens("00010002d", .{.invalid});
    try testTokens("00010032d", .{.invalid});
    try testTokens("00010100d", .{.invalid});
    try testTokens("00010132d", .{.invalid});
    try testTokens("00011300d", .{.invalid});
    try testTokens("00011301d", .{.invalid});
    try testTokens("00011332d", .{.invalid});
    try testTokens("99990000d", .{.invalid});
    try testTokens("99990001d", .{.invalid});
    try testTokens("99990032d", .{.invalid});
    try testTokens("99990100d", .{.invalid});
    try testTokens("99990132d", .{.invalid});
    try testTokens("99991300d", .{.invalid});
    try testTokens("99991301d", .{.invalid});
    try testTokens("99991332d", .{.invalid});

    try testTokens("0000.00.00", .{.invalid});
    try testTokens("0000.00.01", .{.invalid});
    try testTokens("0000.00.32", .{.invalid});
    try testTokens("0000.01.00", .{.invalid});
    try testTokens("0000.01.01", .{.invalid});
    try testTokens("0000.01.32", .{.invalid});
    try testTokens("0000.13.00", .{.invalid});
    try testTokens("0000.13.01", .{.invalid});
    try testTokens("0000.13.32", .{.invalid});
    try testTokens("0001.00.00", .{.invalid});
    try testTokens("0001.00.01", .{.invalid});
    try testTokens("0001.00.32", .{.invalid});
    try testTokens("0001.01.00", .{.invalid});
    try testTokens("0001.13.00", .{.invalid});
    try testTokens("0001.13.01", .{.invalid});
    try testTokens("0001.13.32", .{.invalid});
    try testTokens("9999.00.00", .{.invalid});
    try testTokens("9999.00.01", .{.invalid});
    try testTokens("9999.00.32", .{.invalid});
    try testTokens("9999.01.00", .{.invalid});
    try testTokens("9999.13.00", .{.invalid});
    try testTokens("9999.13.01", .{.invalid});
    try testTokens("9999.13.32", .{.invalid});
}
