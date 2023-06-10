const Token = @import("../../Token.zig");

const testTokens = @import("../scanner.zig").testTokens;

test "byte tokens" {
    try testTokens("0x0", &[_]Token.TokenType{.byte});
    try testTokens("0x00", &[_]Token.TokenType{.byte});
    try testTokens("0x1", &[_]Token.TokenType{.byte});
    try testTokens("0x01", &[_]Token.TokenType{.byte});
    try testTokens("0xF", &[_]Token.TokenType{.byte});
    try testTokens("0x0F", &[_]Token.TokenType{.byte});
    try testTokens("0xf", &[_]Token.TokenType{.byte});
    try testTokens("0x0f", &[_]Token.TokenType{.byte});
    try testTokens("0xFF", &[_]Token.TokenType{.byte});
    try testTokens("0xff", &[_]Token.TokenType{.byte});
}

test "byte_list tokens" {
    try testTokens("0x000", &[_]Token.TokenType{.byte_list});
    try testTokens("0x0000", &[_]Token.TokenType{.byte_list});
    try testTokens("0x100", &[_]Token.TokenType{.byte_list});
    try testTokens("0x0100", &[_]Token.TokenType{.byte_list});
    try testTokens("0xF00", &[_]Token.TokenType{.byte_list});
    try testTokens("0x0F00", &[_]Token.TokenType{.byte_list});
    try testTokens("0xf00", &[_]Token.TokenType{.byte_list});
    try testTokens("0x0f00", &[_]Token.TokenType{.byte_list});
    try testTokens("0xFF00", &[_]Token.TokenType{.byte_list});
    try testTokens("0xff00", &[_]Token.TokenType{.byte_list});
}
