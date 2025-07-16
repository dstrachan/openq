const q = @import("../../root.zig");
const Vm = q.Vm;
const Value = q.Value;

pub fn impl(vm: *Vm, x: *Value, y: *Value) !*Value {
    return switch (x.type) {
        .nil => @panic("NYI"),
        .mixed_list => @panic("NYI"),
        .boolean => @panic("NYI"),
        .boolean_list => @panic("NYI"),
        .guid => @panic("NYI"),
        .guid_list => @panic("NYI"),
        .byte => @panic("NYI"),
        .byte_list => @panic("NYI"),
        .short => @panic("NYI"),
        .short_list => @panic("NYI"),
        .int => @panic("NYI"),
        .int_list => @panic("NYI"),
        .long => @panic("NYI"),
        .long_list => @panic("NYI"),
        .real => @panic("NYI"),
        .real_list => @panic("NYI"),
        .float => @panic("NYI"),
        .float_list => @panic("NYI"),
        .char => switch (y.type) {
            .nil => @panic("NYI"),
            .mixed_list => @panic("NYI"),
            .boolean => @panic("NYI"),
            .boolean_list => @panic("NYI"),
            .guid => @panic("NYI"),
            .guid_list => @panic("NYI"),
            .byte => @panic("NYI"),
            .byte_list => @panic("NYI"),
            .short => @panic("NYI"),
            .short_list => @panic("NYI"),
            .int => @panic("NYI"),
            .int_list => @panic("NYI"),
            .long => @panic("NYI"),
            .long_list => @panic("NYI"),
            .real => @panic("NYI"),
            .real_list => @panic("NYI"),
            .float => @panic("NYI"),
            .float_list => @panic("NYI"),
            .char => blk: {
                const bytes = try vm.gpa.alloc(u8, 2);
                bytes[0] = x.as.char;
                bytes[1] = y.as.char;
                break :blk vm.createCharList(bytes);
            },
            .char_list => blk: {
                const bytes = try vm.gpa.alloc(u8, 1 + y.as.char_list.len);
                bytes[0] = x.as.char;
                @memcpy(bytes[1..], y.as.char_list);
                break :blk vm.createCharList(bytes);
            },
            .symbol => @panic("NYI"),
            .symbol_list => @panic("NYI"),
        },
        .char_list => switch (y.type) {
            .nil => @panic("NYI"),
            .mixed_list => @panic("NYI"),
            .boolean => @panic("NYI"),
            .boolean_list => @panic("NYI"),
            .guid => @panic("NYI"),
            .guid_list => @panic("NYI"),
            .byte => @panic("NYI"),
            .byte_list => @panic("NYI"),
            .short => @panic("NYI"),
            .short_list => @panic("NYI"),
            .int => @panic("NYI"),
            .int_list => @panic("NYI"),
            .long => @panic("NYI"),
            .long_list => @panic("NYI"),
            .real => @panic("NYI"),
            .real_list => @panic("NYI"),
            .float => @panic("NYI"),
            .float_list => @panic("NYI"),
            .char => blk: {
                const bytes = try vm.gpa.alloc(u8, x.as.char_list.len + 1);
                @memcpy(bytes[0..x.as.char_list.len], x.as.char_list);
                bytes[x.as.char_list.len] = y.as.char;
                break :blk vm.createCharList(bytes);
            },
            .char_list => blk: {
                const bytes = try vm.gpa.alloc(u8, x.as.char_list.len + y.as.char_list.len);
                @memcpy(bytes[0..x.as.char_list.len], x.as.char_list);
                @memcpy(bytes[x.as.char_list.len..], y.as.char_list);
                break :blk vm.createCharList(bytes);
            },
            .symbol => @panic("NYI"),
            .symbol_list => @panic("NYI"),
        },
        .symbol => switch (y.type) {
            .nil => @panic("NYI"),
            .mixed_list => @panic("NYI"),
            .boolean => @panic("NYI"),
            .boolean_list => @panic("NYI"),
            .guid => @panic("NYI"),
            .guid_list => @panic("NYI"),
            .byte => @panic("NYI"),
            .byte_list => @panic("NYI"),
            .short => @panic("NYI"),
            .short_list => @panic("NYI"),
            .int => @panic("NYI"),
            .int_list => @panic("NYI"),
            .long => @panic("NYI"),
            .long_list => @panic("NYI"),
            .real => @panic("NYI"),
            .real_list => @panic("NYI"),
            .float => @panic("NYI"),
            .float_list => @panic("NYI"),
            .char => @panic("NYI"),
            .char_list => @panic("NYI"),
            .symbol => blk: {
                const list = try vm.gpa.alloc([]u8, 2);
                list[0] = try vm.gpa.dupe(u8, x.as.symbol);
                list[1] = try vm.gpa.dupe(u8, y.as.symbol);
                break :blk vm.createSymbolList(list);
            },
            .symbol_list => blk: {
                const list = try vm.gpa.alloc([]u8, y.as.symbol_list.len + 1);
                list[0] = try vm.gpa.dupe(u8, x.as.symbol);
                for (list[1..], y.as.symbol_list) |*new, old| {
                    new.* = try vm.gpa.dupe(u8, old);
                }
                break :blk vm.createSymbolList(list);
            },
        },
        .symbol_list => switch (y.type) {
            .nil => @panic("NYI"),
            .mixed_list => @panic("NYI"),
            .boolean => @panic("NYI"),
            .boolean_list => @panic("NYI"),
            .guid => @panic("NYI"),
            .guid_list => @panic("NYI"),
            .byte => @panic("NYI"),
            .byte_list => @panic("NYI"),
            .short => @panic("NYI"),
            .short_list => @panic("NYI"),
            .int => @panic("NYI"),
            .int_list => @panic("NYI"),
            .long => @panic("NYI"),
            .long_list => @panic("NYI"),
            .real => @panic("NYI"),
            .real_list => @panic("NYI"),
            .float => @panic("NYI"),
            .float_list => @panic("NYI"),
            .char => @panic("NYI"),
            .char_list => @panic("NYI"),
            .symbol => blk: {
                const list = try vm.gpa.alloc([]u8, x.as.symbol_list.len + 1);
                for (list[0..x.as.symbol_list.len], x.as.symbol_list) |*new_symbol, old_symbol| {
                    new_symbol.* = try vm.gpa.dupe(u8, old_symbol);
                }
                list[x.as.symbol_list.len] = try vm.gpa.dupe(u8, y.as.symbol);
                break :blk vm.createSymbolList(list);
            },
            .symbol_list => blk: {
                const list = try vm.gpa.alloc([]u8, x.as.symbol_list.len + y.as.symbol_list.len);
                for (list[0..x.as.symbol_list.len], x.as.symbol_list) |*new, old| {
                    new.* = try vm.gpa.dupe(u8, old);
                }
                for (list[x.as.symbol_list.len..], y.as.symbol_list) |*new, old| {
                    new.* = try vm.gpa.dupe(u8, old);
                }
                break :blk vm.createSymbolList(list);
            },
        },
    };
}
