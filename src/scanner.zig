const Self = @This();

source: []const u8,

pub fn init(source: []const u8) Self {
    return .{
        .source = source,
    };
}
