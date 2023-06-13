const Token = @import("../../Token.zig");

const testTokens = @import("../scanner.zig").testTokens;

test "timestamp tokens" {
    try testTokens("0p", .{.timestamp});
    try testTokens("2p", .{.timestamp});
    try testTokens("-2p", .{.timestamp});

    try testTokens("1999.01.01D", .{.timestamp});
    try testTokens("1999.01.01D.", .{.timestamp});
    try testTokens("1999.01.01D.123", .{.timestamp});
    try testTokens("1999.01.01D1", .{.timestamp});
    try testTokens("1999.01.01D1.", .{.timestamp});
    try testTokens("1999.01.01D1.123", .{.timestamp});
    try testTokens("1999.01.01D12", .{.timestamp});
    try testTokens("1999.01.01D12.", .{.timestamp});
    try testTokens("1999.01.01D12.123", .{.timestamp});
    try testTokens("1999.01.01D12:", .{.timestamp});
    try testTokens("1999.01.01D12:.", .{.timestamp});
    try testTokens("1999.01.01D12:.123", .{.timestamp});
    try testTokens("1999.01.01D123", .{.timestamp});
    try testTokens("1999.01.01D123.", .{.timestamp});
    try testTokens("1999.01.01D123.123", .{.timestamp});
    try testTokens("1999.01.01D1234", .{.timestamp});
    try testTokens("1999.01.01D1234.", .{.timestamp});
    try testTokens("1999.01.01D1234.123", .{.timestamp});
    try testTokens("1999.01.01D12:34", .{.timestamp});
    try testTokens("1999.01.01D12:34.", .{.timestamp});
    try testTokens("1999.01.01D12:34.123", .{.timestamp});
    try testTokens("1999.01.01D12:34:", .{.timestamp});
    try testTokens("1999.01.01D12:34:.", .{.timestamp});
    try testTokens("1999.01.01D12:34:.123", .{.timestamp});
    try testTokens("1999.01.01D12345", .{.timestamp});
    try testTokens("1999.01.01D12345.", .{.timestamp});
    try testTokens("1999.01.01D12345.123", .{.timestamp});
    try testTokens("1999.01.01D12:345", .{.timestamp});
    try testTokens("1999.01.01D12:345.", .{.timestamp});
    try testTokens("1999.01.01D12:345.123", .{.timestamp});
    try testTokens("1999.01.01D123456", .{.timestamp});
    try testTokens("1999.01.01D123456.", .{.timestamp});
    try testTokens("1999.01.01D123456.123", .{.timestamp});
    try testTokens("1999.01.01D12:34:56", .{.timestamp});
    try testTokens("1999.01.01D12:34:56.", .{.timestamp});
    try testTokens("1999.01.01D12:34:56.123", .{.timestamp});

    try testTokens("2000.01.01D", .{.timestamp});
    try testTokens("2000.01.01D.", .{.timestamp});
    try testTokens("2000.01.01D.123", .{.timestamp});
    try testTokens("2000.01.01D1", .{.timestamp});
    try testTokens("2000.01.01D1.", .{.timestamp});
    try testTokens("2000.01.01D1.123", .{.timestamp});
    try testTokens("2000.01.01D12", .{.timestamp});
    try testTokens("2000.01.01D12.", .{.timestamp});
    try testTokens("2000.01.01D12.123", .{.timestamp});
    try testTokens("2000.01.01D12:", .{.timestamp});
    try testTokens("2000.01.01D12:.", .{.timestamp});
    try testTokens("2000.01.01D12:.123", .{.timestamp});
    try testTokens("2000.01.01D123", .{.timestamp});
    try testTokens("2000.01.01D123.", .{.timestamp});
    try testTokens("2000.01.01D123.123", .{.timestamp});
    try testTokens("2000.01.01D1234", .{.timestamp});
    try testTokens("2000.01.01D1234.", .{.timestamp});
    try testTokens("2000.01.01D1234.123", .{.timestamp});
    try testTokens("2000.01.01D12:34", .{.timestamp});
    try testTokens("2000.01.01D12:34.", .{.timestamp});
    try testTokens("2000.01.01D12:34.123", .{.timestamp});
    try testTokens("2000.01.01D12:34:", .{.timestamp});
    try testTokens("2000.01.01D12:34:.", .{.timestamp});
    try testTokens("2000.01.01D12:34:.123", .{.timestamp});
    try testTokens("2000.01.01D12345", .{.timestamp});
    try testTokens("2000.01.01D12345.", .{.timestamp});
    try testTokens("2000.01.01D12345.123", .{.timestamp});
    try testTokens("2000.01.01D12:345", .{.timestamp});
    try testTokens("2000.01.01D12:345.", .{.timestamp});
    try testTokens("2000.01.01D12:345.123", .{.timestamp});
    try testTokens("2000.01.01D123456", .{.timestamp});
    try testTokens("2000.01.01D123456.", .{.timestamp});
    try testTokens("2000.01.01D123456.123", .{.timestamp});
    try testTokens("2000.01.01D12:34:56", .{.timestamp});
    try testTokens("2000.01.01D12:34:56.", .{.timestamp});
    try testTokens("2000.01.01D12:34:56.123", .{.timestamp});

    try testTokens("0np", .{.timestamp});
    try testTokens("0Np", .{.timestamp});
    try testTokens("0wp", .{.timestamp});
    try testTokens("0Wp", .{.timestamp});
    try testTokens("-0wp", .{.timestamp});
    try testTokens("-0Wp", .{.timestamp});
}

test "invalid timestamp tokens" {
    try testTokens("1999.01.01D1:", .{.invalid});
    try testTokens("1999.01.01D1:.", .{.invalid});
    try testTokens("1999.01.01D1:.123", .{.invalid});
    try testTokens("1999.01.01D12:3", .{.invalid});
    try testTokens("1999.01.01D12:3.", .{.invalid});
    try testTokens("1999.01.01D12:3.123", .{.invalid});
    try testTokens("1999.01.01D12:3:", .{.invalid});
    try testTokens("1999.01.01D12:3:.", .{.invalid});
    try testTokens("1999.01.01D12:3:.123", .{.invalid});
    try testTokens("1999.01.01D12:34:5", .{.invalid});
    try testTokens("1999.01.01D12:34:5.", .{.invalid});
    try testTokens("1999.01.01D12:34:5.123", .{.invalid});

    try testTokens("2000.01.01D1:", .{.invalid});
    try testTokens("2000.01.01D1:.", .{.invalid});
    try testTokens("2000.01.01D1:.123", .{.invalid});
    try testTokens("2000.01.01D12:3", .{.invalid});
    try testTokens("2000.01.01D12:3.", .{.invalid});
    try testTokens("2000.01.01D12:3.123", .{.invalid});
    try testTokens("2000.01.01D12:3:", .{.invalid});
    try testTokens("2000.01.01D12:3:.", .{.invalid});
    try testTokens("2000.01.01D12:3:.123", .{.invalid});
    try testTokens("2000.01.01D12:34:5", .{.invalid});
    try testTokens("2000.01.01D12:34:5.", .{.invalid});
    try testTokens("2000.01.01D12:34:5.123", .{.invalid});
}
