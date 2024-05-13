const std = @import("std");
const testing = std.testing;

fn outputUnicodeEscape(
    codepoint: u21,
    out_stream: anytype,
) !void {
    if (codepoint <= 0xFFFF) {
        // If the character is in the Basic Multilingual Plane (U+0000 through U+FFFF),
        // then it may be represented as a six-character sequence: a reverse solidus, followed
        // by the lowercase letter u, followed by four hexadecimal digits that encode the character's code point.
        try out_stream.writeAll("\\u");
        try std.fmt.formatIntValue(codepoint, "x", std.fmt.FormatOptions{ .width = 4, .fill = '0' }, out_stream);
    } else {
        std.debug.assert(codepoint <= 0x10FFFF);
        // To escape an extended character that is not in the Basic Multilingual Plane,
        // the character is represented as a 12-character sequence, encoding the UTF-16 surrogate pair.

        const high = @as(u21, (codepoint - 0x10000) >> 10) + 0xD800;
        const low = @as(u21, codepoint & 0x3FF) + 0xDC00;
        try out_stream.writeAll("\\u");
        try std.fmt.formatIntValue(high, "x", std.fmt.FormatOptions{ .width = 4, .fill = '0' }, out_stream);
        try out_stream.writeAll("\\u");
        try std.fmt.formatIntValue(low, "x", std.fmt.FormatOptions{ .width = 4, .fill = '0' }, out_stream);
    }
}

pub fn dump(value: Value, indent: usize) anyerror!void {
    var out_stream = std.io.getStdOut().writer();

    switch (value) {
        .Integer => |n| {
            try out_stream.print("{}", .{n});
        },
        .String => |s| {
            var i: usize = 0;

            try out_stream.print("\"", .{});
            if (std.unicode.utf8ValidateSlice(s)) {
                while (i < s.len) : (i += 1) {
                    switch (s[i]) {
                        // normal ascii character
                        0x20...0x21, 0x23...0x2E, 0x30...0x5B, 0x5D...0x7F => |c| try out_stream.writeByte(c),
                        // only 2 characters that *must* be escaped
                        '\\' => try out_stream.writeAll("\\\\"),
                        '\"' => try out_stream.writeAll("\\\""),
                        // solidus is optional to escape
                        '/' => {
                            try out_stream.writeByte('/');
                        },
                        // control characters with short escapes
                        // TODO: option to switch between unicode and 'short' forms?
                        0x8 => try out_stream.writeAll("\\b"),
                        0xC => try out_stream.writeAll("\\f"),
                        '\n' => try out_stream.writeAll("\\n"),
                        '\r' => try out_stream.writeAll("\\r"),
                        '\t' => try out_stream.writeAll("\\t"),
                        else => {
                            const ulen = std.unicode.utf8ByteSequenceLength(s[i]) catch unreachable;
                            // control characters (only things left with 1 byte length) should always be printed as unicode escapes
                            if (ulen == 1) {
                                const codepoint = std.unicode.utf8Decode(s[i .. i + ulen]) catch unreachable;
                                try outputUnicodeEscape(codepoint, out_stream);
                            } else {
                                try out_stream.writeAll(s[i .. i + ulen]);
                            }
                            i += ulen - 1;
                        },
                    }
                }
            } else {
                for (s) |c| {
                    try out_stream.print("\\x{X}", .{c});
                }
            }
            try out_stream.print("\"", .{});
        },
        .Array => |arr| {
            for (arr.items) |v| {
                try out_stream.print("\n", .{});
                try out_stream.writeByteNTimes(' ', indent);
                try out_stream.print("- ", .{});
                try dump(v, indent + 2);
            }
        },
        .Map => |*map| {
            for (map.items) |kv| {
                try out_stream.print("\n", .{});
                try out_stream.writeByteNTimes(' ', indent);
                try out_stream.print("\"{s}\": ", .{kv.key});
                try dump(kv.value, indent + 2);
            }
        },
    }
}
pub const ValueTree = struct {
    arena: std.heap.ArenaAllocator,
    root: Value,

    pub fn deinit(self: *ValueTree) void {
        self.arena.deinit();
    }

    pub fn parse(input: []const u8, allocator: std.mem.Allocator) !ValueTree {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        var mut_input = input;
        const value = try parseInternal(&mut_input, arena.allocator(), 0);

        return ValueTree{ .arena = arena, .root = value };
    }

    fn parseInternal(input: *[]const u8, allocator: std.mem.Allocator, rec_count: usize) anyerror!Value {
        if (rec_count == 100) return error.RecursionLimitReached;

        if (peek(input.*)) |c| {
            return switch (c) {
                'i' => Value{ .Integer = try parseNumber(isize, input) },
                '0'...'9' => Value{ .String = try parseBytes([]const u8, u8, allocator, input) },
                'l' => {
                    var arr = Array.init(allocator);
                    errdefer arr.deinit();

                    try expectChar(input, 'l');
                    while (!match(input, 'e')) {
                        const v = try parseInternal(input, allocator, rec_count + 1);
                        try arr.append(v);
                    }
                    return Value{ .Array = arr };
                },
                'd' => {
                    var map = Map.init(allocator);

                    try expectChar(input, 'd');
                    while (!match(input, 'e')) {
                        const k = try parseBytes([]const u8, u8, allocator, input);
                        const v = try parseInternal(input, allocator, rec_count + 1);

                        if (mapLookup(map, k) != null) return error.DuplicateDictionaryKeys; // EEXISTS

                        try map.append(KV{ .key = try allocator.dupe(u8, k), .value = v });
                    }
                    return Value{ .Map = map };
                },
                else => error.UnexpectedChar,
            };
        } else return error.UnexpectedChar;
    }

    pub fn stringify(self: *const ValueTree, out_stream: anytype) @TypeOf(out_stream).Error!void {
        return self.root.stringify(out_stream);
    }
};

pub const KV = struct {
    key: []const u8,
    value: Value,
};

pub const Map = std.ArrayList(KV);
pub const Array = std.ArrayList(Value);

pub fn mapLookup(map: Map, key: []const u8) ?*Value {
    for (map.items) |*kv| {
        if (std.mem.eql(u8, key, kv.key)) return &kv.value;
    }
    return null;
}

/// Represents a bencode value
pub const Value = union(enum) {
    Integer: isize,
    String: []const u8,
    Array: Array,
    Map: Map,

    pub fn stringifyValue(self: Value, out_stream: anytype) @TypeOf(out_stream).Error!void {
        switch (self) {
            .Integer => |value| {
                try out_stream.writeByte('i');
                try std.fmt.formatIntValue(value, "", std.fmt.FormatOptions{}, out_stream);
                try out_stream.writeByte('e');
            },
            .Map => |map| {
                try out_stream.writeByte('d');
                for (map.items) |kv| {
                    try out_stream.writeAll(kv.key);
                    try stringifyValue(kv.value, out_stream);
                }

                try out_stream.writeByte('e');
                return;
            },
            .String => |s| {
                try std.fmt.formatIntValue(s.len, "", std.fmt.FormatOptions{}, out_stream);
                try out_stream.writeByte(':');
                try out_stream.writeAll(s[0..]);
                return;
            },
            .Array => |array| {
                try out_stream.writeByte('l');
                for (array.items) |x| {
                    try x.stringifyValue(out_stream);
                }
                try out_stream.writeByte('e');
                return;
            },
        }
    }
};

fn findFirstIndexOf(s: []const u8, needle: u8) ?usize {
    for (s, 0..) |c, i| {
        if (c == needle) return i;
    }
    return null;
}

fn expectChar(s: *[]const u8, needle: u8) !void {
    if (s.*.len > 0 and s.*[0] == needle) {
        s.* = s.*[1..];
        return;
    }
    return error.UnexpectedChar;
}

fn parseNumber(comptime T: type, s: *[]const u8) anyerror!T {
    try expectChar(s, 'i');

    const optional_end_index = findFirstIndexOf(s.*[0..], 'e');
    if (optional_end_index) |end_index| {
        if (s.*[0..end_index].len == 0) return error.NoDigitsInNumber;
        const n = try std.fmt.parseInt(T, s.*[0..end_index], 10);

        if (s.*[0] == '0' and n != 0) return error.ForbiddenHeadingZeroInNumber;
        if (s.*[0] == '-' and n == 0) return error.ForbiddenNegativeZeroNumber;

        s.* = s.*[end_index..];
        try expectChar(s, 'e');

        return n;
    } else {
        return error.MissingTerminatingNumberToken;
    }
}

fn peek(s: []const u8) ?u8 {
    return if (s.len > 0) s[0] else null;
}

fn match(s: *[]const u8, needle: u8) bool {
    if (peek(s.*)) |c| {
        if (c == needle) {
            s.* = s.*[1..];
            return true;
        }
    }
    return false;
}

fn parseArray(comptime T: type, childType: type, allocator: *std.mem.Allocator, s: *[]const u8, rec_count: usize) anyerror!T {
    try expectChar(s, 'l');

    var arraylist = std.ArrayList(childType).init(allocator);
    errdefer {
        arraylist.deinit();
    }

    while (!match(s, 'e')) {
        const item = try ValueTree.parseInternal(childType, allocator, s, rec_count + 1);
        try arraylist.append(item);
    }

    return arraylist.toOwnedSlice();
}

fn parseBytes(comptime T: type, comptime childType: type, allocator: std.mem.Allocator, s: *[]const u8) anyerror!T {
    const optional_end_index = findFirstIndexOf(s.*[0..], ':');
    if (optional_end_index) |end_index| {
        if (s.*[0..end_index].len == 0) return error.MissingLengthBytes;

        const n = try std.fmt.parseInt(usize, s.*[0..end_index], 10);
        s.* = s.*[end_index..];
        try expectChar(s, ':');

        if (s.*.len < n) return error.InvalidByteLength;

        const bytes: []const u8 = s.*[0..n];
        var arraylist = std.ArrayList(childType).init(allocator);
        errdefer {
            arraylist.deinit();
        }
        try arraylist.appendSlice(bytes);

        s.* = s.*[n..];

        return arraylist.toOwnedSlice();
    }
    return error.MissingSeparatingStringToken;
}

pub fn stringify(value: anytype, out_stream: anytype) @TypeOf(out_stream).Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .Int, .ComptimeInt => {
            try out_stream.writeByte('i');
            try std.fmt.formatIntValue(value, "", std.fmt.FormatOptions{}, out_stream);
            try out_stream.writeByte('e');
        },
        .Union => {
            if (comptime std.meta.hasFn(T, "bencodeStringify")) {
                return value.bencodeStringify(out_stream);
            }

            const info = @typeInfo(T).Union;
            if (info.tag_type) |UnionTagType| {
                inline for (info.fields, 0..) |u_field, index| {
                    // I'm not sure what's going on here. I'm guessing we're trying to stringify correct union field based on some tag value. I think Zig has changed the union field type and doesn't embed something we need anymore.
                    if (@intFromEnum(@as(UnionTagType, value)) == index) {
                        // This is what the code was, probably for an older version.
                        // if (@enumToInt(@as(UnionTagType, value)) == u_field.enum_field.?.value) {
                        return try stringify(@field(value, u_field.name), out_stream);
                    }
                }
            } else {
                @compileError("Unable to stringify untagged union '" ++ @typeName(T) ++ "'");
            }
        },
        .Struct => |S| {
            if (comptime std.meta.hasFn(T, "bencodeStringify")) {
                return value.bencodeStringify(out_stream);
            }

            try out_stream.writeByte('d');
            inline for (S.fields) |Field| {
                // don't include void fields
                if (Field.type == void) continue;

                try stringify(Field.name, out_stream);
                try stringify(@field(value, Field.name), out_stream);
            }
            try out_stream.writeByte('e');
            return;
        },
        .ErrorSet => return stringify(@as([]const u8, @errorName(value)), out_stream),
        .Pointer => |ptr_info| switch (ptr_info.size) {
            .One => switch (@typeInfo(ptr_info.child)) {
                .Array => {
                    const Slice = []const std.meta.Elem(ptr_info.child);
                    return stringify(@as(Slice, value), out_stream);
                },
                else => {
                    // TODO: avoid loops?
                    return stringify(value.*, out_stream);
                },
            },
            // TODO: .Many when there is a sentinel (waiting for https://github.com/ziglang/zig/pull/3972)
            .Slice => {
                if (ptr_info.child == u8) {
                    try std.fmt.formatIntValue(value.len, "", std.fmt.FormatOptions{}, out_stream);
                    try out_stream.writeByte(':');
                    try out_stream.writeAll(value[0..]);
                    return;
                }

                try out_stream.writeByte('l');
                for (value) |x| {
                    try stringify(x, out_stream);
                }
                try out_stream.writeByte('e');
                return;
            },
            else => @compileError("Unable to stringify type '" ++ @typeName(T) ++ "'"),
        },
        .Array => return stringify(&value, out_stream),
        .Vector => |info| {
            const array: [info.len]info.child = value;
            return stringify(&array, out_stream);
        },
        else => @compileError("Unable to stringify type '" ++ @typeName(T) ++ "'"),
    }
}

pub fn isArray(v: Value) bool {
    return switch (v) {
        .Array => true,
        else => false,
    };
}

pub fn isInteger(v: Value) bool {
    return switch (v) {
        .Integer => true,
        else => false,
    };
}
pub fn isString(v: Value) bool {
    return switch (v) {
        .String => true,
        else => false,
    };
}
pub fn isMap(v: Value) bool {
    return switch (v) {
        .Map => true,
        else => false,
    };
}

const expectEqual = testing.expectEqual;
const expectError = testing.expectError;
const expectEqualSlices = testing.expectEqualSlices;

test "isArray" {
    try expectEqual(false, isArray(Value{ .Integer = 99 }));
    try expectEqual(false, isArray(Value{ .String = "foo" }));
    try expectEqual(false, isArray(Value{ .Map = Map.init(std.testing.allocator) }));
    try expectEqual(true, isArray(Value{ .Array = std.ArrayList(Value).init(std.testing.allocator) }));
}

test "isInteger" {
    try expectEqual(true, isInteger(Value{ .Integer = 99 }));
    try expectEqual(false, isInteger(Value{ .String = "foo" }));
    try expectEqual(false, isInteger(Value{ .Map = Map.init(std.testing.allocator) }));
    try expectEqual(false, isInteger(Value{ .Array = std.ArrayList(Value).init(std.testing.allocator) }));
}

test "isString" {
    try expectEqual(false, isString(Value{ .Integer = 99 }));
    try expectEqual(true, isString(Value{ .String = "foo" }));
    try expectEqual(false, isString(Value{ .Map = Map.init(std.testing.allocator) }));
    try expectEqual(false, isString(Value{ .Array = std.ArrayList(Value).init(std.testing.allocator) }));
}

test "isMap" {
    try expectEqual(false, isMap(Value{ .Integer = 99 }));
    try expectEqual(false, isMap(Value{ .String = "foo" }));
    try expectEqual(true, isMap(Value{ .Map = Map.init(std.testing.allocator) }));
    try expectEqual(false, isMap(Value{ .Array = std.ArrayList(Value).init(std.testing.allocator) }));
}

test "parse into number" {
    try expectEqual((try ValueTree.parse("i20e", testing.allocator)).root.Integer, 20);
}

test "parse into number with missing end token" {
    try expectError(error.MissingTerminatingNumberToken, ValueTree.parse("i20", testing.allocator));
}

test "parse into number with missing start token" {
    try testing.expectError(error.MissingSeparatingStringToken, ValueTree.parse("20e", testing.allocator));
}

test "parse into number 0" {
    try expectEqual((try ValueTree.parse("i0e", testing.allocator)).root.Integer, 0);
}

test "parse into negative number" {
    try expectEqual((try ValueTree.parse("i-42e", testing.allocator)).root.Integer, -42);
}

test "parse empty string into number" {
    try testing.expectError(error.UnexpectedChar, ValueTree.parse("", testing.allocator));
}

test "parse negative zero into number" {
    try testing.expectError(error.ForbiddenNegativeZeroNumber, ValueTree.parse("i-0e", testing.allocator));
}

test "parse into overflowing number" {
    try testing.expectError(error.Overflow, ValueTree.parse("i999999999999999999999999e", testing.allocator));
    try testing.expectError(error.Overflow, ValueTree.parse("i-999999999999999999999999e", testing.allocator));
}

test "parse into number with heading 0" {
    try testing.expectError(error.ForbiddenHeadingZeroInNumber, ValueTree.parse("i01e", testing.allocator));
}

test "parse into number without digits" {
    try testing.expectError(error.MissingTerminatingNumberToken, ValueTree.parse("i", testing.allocator));
    try testing.expectError(error.NoDigitsInNumber, ValueTree.parse("ie", testing.allocator));
}

test "parse into bytes" {
    const value = (try ValueTree.parse("3:abc", testing.allocator)).root.String;
    defer testing.allocator.free(value);

    try expectEqualSlices(u8, value, "abc");
}

test "parse into unicode bytes" {
    const value = (try ValueTree.parse("9:毛泽东", testing.allocator)).root.String;
    defer testing.allocator.free(value);

    try expectEqualSlices(u8, value, "毛泽东");
}

test "parse into bytes with invalid size" {
    try testing.expectError(error.InvalidByteLength, ValueTree.parse("10:foo", testing.allocator));
    try testing.expectError(error.InvalidByteLength, ValueTree.parse("10:", testing.allocator));
    try testing.expectError(error.MissingSeparatingStringToken, ValueTree.parse("10", testing.allocator));
    // No way to detect this case I think since there is no terminating token
    var value = (try ValueTree.parse("3:abcd", testing.allocator));
    defer value.deinit();
    try expectEqualSlices(u8, value.root.String, "abc");
}

test "parse empty string into bytes" {
    try testing.expectError(error.UnexpectedChar, ValueTree.parse("", testing.allocator));
}

test "parse into bytes with missing length" {
    try testing.expectError(error.UnexpectedChar, ValueTree.parse(":", testing.allocator));
}

test "parse into bytes with missing separator" {
    try testing.expectError(error.MissingSeparatingStringToken, ValueTree.parse("4", testing.allocator));
}

test "parse into empty array" {
    var value = try ValueTree.parse("le", testing.allocator);
    defer value.deinit();

    try expectEqual(value.root.Array.items.len, 0);
}

test "parse into array of u8 numbers" {
    var value = try ValueTree.parse("li4ei10ee", testing.allocator);
    defer value.deinit();

    try expectEqual(value.root.Array.items.len, 2);
    try expectEqual(value.root.Array.items[0].Integer, 4);
    try expectEqual(value.root.Array.items[1].Integer, 10);
}

test "parse into array of isize numbers" {
    var value = try ValueTree.parse("li-4ei500ee", testing.allocator);
    defer value.deinit();

    try expectEqual(value.root.Array.items.len, 2);
    try expectEqual(value.root.Array.items[0].Integer, -4);
    try expectEqual(value.root.Array.items[1].Integer, 500);
}

test "parse into empty array of bytes" {
    var value = try ValueTree.parse("le", testing.allocator);
    defer value.deinit();

    try expectEqual(value.root.Array.items.len, 0);
}

test "parse into array of bytes" {
    var value = try ValueTree.parse("l3:foo5:helloe", testing.allocator);
    defer value.deinit();

    try expectEqual(value.root.Array.items.len, 2);
    try expectEqualSlices(u8, value.root.Array.items[0].String, "foo");
    try expectEqualSlices(u8, value.root.Array.items[1].String, "hello");
}

test "parse into heterogeneous array" {
    var value = try ValueTree.parse("l3:fooi20ee", testing.allocator);
    defer value.deinit();

    try expectEqual(value.root.Array.items.len, 2);
    try expectEqualSlices(u8, value.root.Array.items[0].String, "foo");
    try expectEqual(value.root.Array.items[1].Integer, 20);
}

test "parse into array" {
    var value = try ValueTree.parse("l3:foo5:helloe", testing.allocator);
    defer value.deinit();

    try expectEqual(value.root.Array.items.len, 2);
    try expectEqualSlices(u8, value.root.Array.items[0].String, "foo");
    try expectEqualSlices(u8, value.root.Array.items[1].String, "hello");
}

test "parse array into bytes with invalid size" {
    try testing.expectError(error.InvalidByteLength, ValueTree.parse("10:", testing.allocator));
}

test "parse bytes into array" {
    var value = try ValueTree.parse("2:fo", testing.allocator);
    defer value.deinit();

    try expectEqualSlices(u8, value.root.String, "fo");
}

test "parse into array with missing terminator" {
    try testing.expectError(error.UnexpectedChar, ValueTree.parse("l3:foo5:hello", testing.allocator));
}

test "parse into empty map" {
    const map = (try ValueTree.parse("de", testing.allocator)).root.Map;
    try expectEqual(@as(usize, 0), map.items.len);
}

test "parse into array and reach recursion limit" {
    try testing.expectError(error.RecursionLimitReached, ValueTree.parse("l" ** 101 ++ "e" ** 101, testing.allocator));
}

test "parse map with duplicate keys" {
    try testing.expectError(error.DuplicateDictionaryKeys, ValueTree.parse("d1:ni9e1:ni9ee", testing.allocator));
}

test "parse map with unordered keys" {
    var value_tree = try ValueTree.parse("d1:ni9e1:mi8ee", testing.allocator);
    defer value_tree.deinit();

    const kv1 = mapLookup(value_tree.root.Map, "m");
    try expectEqual(kv1.?.Integer, 8);

    const kv2 = mapLookup(value_tree.root.Map, "n");
    try expectEqual(kv2.?.Integer, 9);
}

test "parse map" {
    var value_tree = try ValueTree.parse("d6:abcdef3:abc2:foi5ee", testing.allocator);
    defer value_tree.deinit();

    const kv1 = mapLookup(value_tree.root.Map, "abcdef");
    try expectEqualSlices(u8, kv1.?.String, "abc");

    const kv2 = mapLookup(value_tree.root.Map, "fo");
    try expectEqual(kv2.?.Integer, 5);
}

test "parse into map at the limit of the recursion limit" {
    var s = std.ArrayList(u8).init(testing.allocator);
    var i: usize = 0;

    try s.append('d');
    while (i <= 98) : (i += 1) {
        try s.appendSlice("1:xd");
    }
    i = 0;
    while (i <= 99) : (i += 1) {
        try s.appendSlice("e");
    }
    defer s.deinit();

    var value = try ValueTree.parse(s.items, testing.allocator);
    defer value.deinit();
    try testing.expect(value.root.Map.items.len > 0);
}

test "parse into map and reach the recursion limit" {
    var s = std.ArrayList(u8).init(testing.allocator);
    var i: usize = 0;

    try s.append('d');
    while (i <= 99) : (i += 1) {
        try s.appendSlice("1:xd");
    }
    i = 0;
    while (i <= 100) : (i += 1) {
        try s.appendSlice("e");
    }
    defer s.deinit();

    try testing.expectError(error.RecursionLimitReached, ValueTree.parse(s.items, testing.allocator));
}

fn teststringify(expected: []const u8, value: anytype) !void {
    const ValidationOutStream = struct {
        const Self = @This();
        pub const OutStream = std.io.Writer(*Self, Error, write);
        pub const Error = error{
            TooMuchData,
            DifferentData,
        };

        expected_remaining: []const u8,

        fn init(exp: []const u8) Self {
            return .{ .expected_remaining = exp };
        }

        pub fn outStream(self: *Self) OutStream {
            return .{ .context = self };
        }

        fn write(self: *Self, bytes: []const u8) Error!usize {
            if (self.expected_remaining.len < bytes.len) {
                std.log.warn(
                    \\====== expected this output: =========
                    \\{s}
                    \\======== instead found this: =========
                    \\{s}
                    \\======================================
                , .{
                    self.expected_remaining,
                    bytes,
                });
                return error.TooMuchData;
            }
            if (!std.mem.eql(u8, self.expected_remaining[0..bytes.len], bytes)) {
                std.log.warn(
                    \\====== expected this output: =========
                    \\{s}
                    \\======== instead found this: =========
                    \\{s}
                    \\======================================
                , .{
                    self.expected_remaining[0..bytes.len],
                    bytes,
                });
                return error.DifferentData;
            }
            self.expected_remaining = self.expected_remaining[bytes.len..];
            return bytes.len;
        }
    };

    var vos = ValidationOutStream.init(expected);
    try stringify(value, vos.outStream());
    if (vos.expected_remaining.len > 0) return error.NotEnoughData;
}

test "stringify number" {
    try teststringify("i0e", 0);
    try teststringify("i9e", 9);
    try teststringify("i-345e", -345);
}

test "stringify bytes" {
    try teststringify("3:foo", "foo");
    try teststringify("6:abcdef", "abcdef");
    try teststringify("0:", "");
    try teststringify("0:", [_]u8{});
    try teststringify("2:ab", [_]u8{ 'a', 'b' });
}

test "stringify arrays" {
    try teststringify("le", [_]isize{});
    try teststringify("li0ei5ee", [_]isize{ 0, 5 });
    try teststringify("l4:abcde", [_][]const u8{"abcd"});
}

test "stringify struct" {
    try teststringify("d3:agei18e4:name3:joee", struct { age: usize, name: []const u8 }{ .age = 18, .name = "joe" });
}

test "stringify tagged unions" {
    try teststringify("i42e", union(enum) {
        Foo: u32,
        Bar: []const u8,
    }{ .Foo = 42 });
}

test "stringify struct with void field" {
    try teststringify("d3:fooi42ee", struct {
        foo: u32,
        bar: void = {},
    }{ .foo = 42 });
}

test "stringify array of structs" {
    const MyStruct = struct {
        foo: u32,
    };
    try teststringify("ld3:fooi42eed3:fooi100eed3:fooi1000eee", [_]MyStruct{
        MyStruct{ .foo = 42 },
        MyStruct{ .foo = 100 },
        MyStruct{ .foo = 1000 },
    });
}

test "stringify vector" {
    const result: @Vector(2, u32) = @splat(1);
    try teststringify("li1ei1ee", result);
}
