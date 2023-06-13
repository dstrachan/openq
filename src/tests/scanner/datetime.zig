const Token = @import("../../Token.zig");

const testTokens = @import("../scanner.zig").testTokens;

test "datetime tokens" {
    try testTokens("1999.01.01T", .{.datetime});
    try testTokens("1999.01.01T.", .{.datetime});
    try testTokens("1999.01.01T.123", .{.datetime});
    try testTokens("1999.01.01T1", .{.datetime});
    try testTokens("1999.01.01T1.", .{.datetime});
    try testTokens("1999.01.01T1.123", .{.datetime});
    try testTokens("1999.01.01T12", .{.datetime});
    try testTokens("1999.01.01T12.", .{.datetime});
    try testTokens("1999.01.01T12.123", .{.datetime});
    try testTokens("1999.01.01T12:", .{.datetime});
    try testTokens("1999.01.01T12:.", .{.datetime});
    try testTokens("1999.01.01T12:.123", .{.datetime});
    try testTokens("1999.01.01T123", .{.datetime});
    try testTokens("1999.01.01T123.", .{.datetime});
    try testTokens("1999.01.01T123.123", .{.datetime});
    try testTokens("1999.01.01T1234", .{.datetime});
    try testTokens("1999.01.01T1234.", .{.datetime});
    try testTokens("1999.01.01T1234.123", .{.datetime});
    try testTokens("1999.01.01T12:34", .{.datetime});
    try testTokens("1999.01.01T12:34.", .{.datetime});
    try testTokens("1999.01.01T12:34.123", .{.datetime});
    try testTokens("1999.01.01T12:34:", .{.datetime});
    try testTokens("1999.01.01T12:34:.", .{.datetime});
    try testTokens("1999.01.01T12:34:.123", .{.datetime});
    try testTokens("1999.01.01T12345", .{.datetime});
    try testTokens("1999.01.01T12345.", .{.datetime});
    try testTokens("1999.01.01T12345.123", .{.datetime});
    try testTokens("1999.01.01T12:345", .{.datetime});
    try testTokens("1999.01.01T12:345.", .{.datetime});
    try testTokens("1999.01.01T12:345.123", .{.datetime});
    try testTokens("1999.01.01T123456", .{.datetime});
    try testTokens("1999.01.01T123456.", .{.datetime});
    try testTokens("1999.01.01T123456.123", .{.datetime});
    try testTokens("1999.01.01T12:34:56", .{.datetime});
    try testTokens("1999.01.01T12:34:56.", .{.datetime});
    try testTokens("1999.01.01T12:34:56.123", .{.datetime});

    try testTokens("2000.01.01T", .{.datetime});
    try testTokens("2000.01.01T.", .{.datetime});
    try testTokens("2000.01.01T.123", .{.datetime});
    try testTokens("2000.01.01T1", .{.datetime});
    try testTokens("2000.01.01T1.", .{.datetime});
    try testTokens("2000.01.01T1.123", .{.datetime});
    try testTokens("2000.01.01T12", .{.datetime});
    try testTokens("2000.01.01T12.", .{.datetime});
    try testTokens("2000.01.01T12.123", .{.datetime});
    try testTokens("2000.01.01T12:", .{.datetime});
    try testTokens("2000.01.01T12:.", .{.datetime});
    try testTokens("2000.01.01T12:.123", .{.datetime});
    try testTokens("2000.01.01T123", .{.datetime});
    try testTokens("2000.01.01T123.", .{.datetime});
    try testTokens("2000.01.01T123.123", .{.datetime});
    try testTokens("2000.01.01T1234", .{.datetime});
    try testTokens("2000.01.01T1234.", .{.datetime});
    try testTokens("2000.01.01T1234.123", .{.datetime});
    try testTokens("2000.01.01T12:34", .{.datetime});
    try testTokens("2000.01.01T12:34.", .{.datetime});
    try testTokens("2000.01.01T12:34.123", .{.datetime});
    try testTokens("2000.01.01T12:34:", .{.datetime});
    try testTokens("2000.01.01T12:34:.", .{.datetime});
    try testTokens("2000.01.01T12:34:.123", .{.datetime});
    try testTokens("2000.01.01T12345", .{.datetime});
    try testTokens("2000.01.01T12345.", .{.datetime});
    try testTokens("2000.01.01T12345.123", .{.datetime});
    try testTokens("2000.01.01T12:345", .{.datetime});
    try testTokens("2000.01.01T12:345.", .{.datetime});
    try testTokens("2000.01.01T12:345.123", .{.datetime});
    try testTokens("2000.01.01T123456", .{.datetime});
    try testTokens("2000.01.01T123456.", .{.datetime});
    try testTokens("2000.01.01T123456.123", .{.datetime});
    try testTokens("2000.01.01T12:34:56", .{.datetime});
    try testTokens("2000.01.01T12:34:56.", .{.datetime});
    try testTokens("2000.01.01T12:34:56.123", .{.datetime});

    try testTokens("0nz", .{.datetime});
    try testTokens("0Nz", .{.datetime});
    try testTokens("0wz", .{.datetime});
    try testTokens("0Wz", .{.datetime});
    try testTokens("-0wz", .{.datetime});
    try testTokens("-0Wz", .{.datetime});
}

test "invalid datetime tokens" {
    try testTokens("1999.01.01T1:", .{.invalid});
    try testTokens("1999.01.01T12:3", .{.invalid});
    try testTokens("1999.01.01T12:34:5", .{.invalid});

    try testTokens("2000.01.01T1:", .{.invalid});
    try testTokens("2000.01.01T12:3", .{.invalid});
    try testTokens("2000.01.01T12:34:5", .{.invalid});
}
