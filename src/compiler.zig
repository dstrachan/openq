const Scanner = @import("scanner.zig");
const VM = @import("vm.zig");

const Self = @This();

const CompilerError = error{
    Unknown,
};

vm: VM,

pub fn init(vm: VM) Self {
    return .{
        .vm = vm,
    };
}

pub fn compile(self: Self, source: []const u8) CompilerError!void {
    var scanner = Scanner.init(source);
    while (scanner.nextToken()) |token| {
        self.vm.stdout.print("{}\n", .{token}) catch return CompilerError.Unknown;
    }
}
