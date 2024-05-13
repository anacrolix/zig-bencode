const std = @import("std");
const bencode = @import("src/main.zig");

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    const arg = if (args.len == 2) args[1] else return error.MissingCliArgument;

    const File = std.fs.File;

    var file = try std.fs.cwd().openFile(arg, File.OpenFlags{ .mode = File.OpenMode.read_only });
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 100_000);

    var value = try bencode.ValueTree.parse(content, allocator);
    defer value.deinit();

    bencode.dump(value.root, 0) catch |err| {
        try std.io.getStdErr().writer().print("Error dumping: {}\n", .{err});
        return;
    };
}
