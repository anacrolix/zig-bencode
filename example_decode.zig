const std = @import("std");
const bencode = @import("src/main.zig");

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var v = try bencode.ValueTree.parse("d3:agei18e4:name3:joee", allocator);
    defer v.deinit();

    if (bencode.mapLookup(v.root.Map, "age")) |age| {
        if (bencode.isInteger(age.*)) std.debug.print("age={} ", .{age.Integer});
    }

    if (bencode.mapLookup(v.root.Map, "name")) |name| {
        if (bencode.isString(name.*)) std.debug.print("name={s}\n", .{name.String});
    }
}
