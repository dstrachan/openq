const q = @import("../../root.zig");
const Vm = q.Vm;
const Value = q.Value;

pub fn impl(vm: *Vm, x: *Value) !*Value {
    _ = vm; // autofix
    _ = x; // autofix
    return error.NYI;
}
