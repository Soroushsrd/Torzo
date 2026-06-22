//! By convention, root.zig is the root source file when making a package.
//! this file will provide the bencode decoder functionalities
//! bencoding:
//!   1. Strings are length-prefixed -> 4:spam -> "spam"
//!   2. Integers are written as i<number>e -> i-3e -> -3
//!   3. Lists are encoded as l followed by their element(bencoded) and e: l4:spam4:eggse
//!       -> ['spam','eggs']
//!   4. Dicts are encoded as d, list of keys and values, e: d3:cow3:moo4:spam4:eggse
//!       -> {'cow':'moo','spam':'eggs'}

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const Sha1 = std.crypto.hash.Sha1;

pub const ParseErrors = error{
    UnexpectedEOF,
    InvalidByte,
    InvalidInt,
    LeadingZero,
    Overflow,
} || Allocator.Error || std.fmt.ParseIntError;

pub const ValueError = error{
    WrongType,
    NotADict,
    MissingField,
    InvalidePieces,
    Invalid,
} || Allocator.Error;

pub const Value = union(enum) {
    String: []const u8,
    Integer: i64,
    List: []Value,
    Dict: std.array_hash_map.String(Value),

    pub fn deinit(self: *Value, alloc: std.mem.Allocator) void {
        switch (self.*) {
            // its a borrowed view of the input. cant free it
            .String => {},
            .Integer => {},
            .List => |list| {
                for (list) |*element| {
                    element.deinit(alloc);
                }
                alloc.free(list);
            },
            .Dict => |*d| {
                for (d.values()) |*v| v.deinit(alloc);
                d.deinit(alloc);
            },
        }
    }

    pub fn getDict(self: Value) ValueError!std.array_hash_map.String(Value) {
        switch (self) {
            .Dict => |d| return d,
            else => return ValueError.NotADict,
        }
    }

    pub fn getStringOpt(self: Value, key: []const u8) ValueError!?[]const u8 {
        const v = try self.getDict();
        const d = v.get(key) orelse return null;
        return switch (d) {
            .String => |s| s,
            else => ValueError.WrongType,
        };
    }

    pub fn getIntOpt(self: Value, key: []const u8) ValueError!?i64 {
        const v = try self.getDict();
        const i = v.get(key) orelse return null;
        return switch (i) {
            .Integer => |r| r,
            else => ValueError.WrongType,
        };
    }
    pub fn getString(self: Value, key: []const u8) ValueError![]const u8 {
        const v = try self.getDict();
        const d = v.get(key) orelse return ValueError.MissingField;
        return switch (d) {
            .String => |s| s,
            else => ValueError.WrongType,
        };
    }

    pub fn getInt(self: Value, key: []const u8) ValueError!i64 {
        const v = try self.getDict();
        const i = v.get(key) orelse return ValueError.MissingField;
        return switch (i) {
            .Integer => |r| r,
            else => ValueError.WrongType,
        };
    }

    pub fn encode(self: Value, writer: *Io.Writer) !void {
        switch (self) {
            .String => |v| {
                try writer.print("{d}", .{v.len});
                try writer.writeByte(':');
                try writer.writeAll(v);
            },
            .Integer => |i| {
                try writer.writeByte('i');
                try writer.print("{d}", .{i});
                try writer.writeByte('e');
            },
            .List => |list| {
                try writer.writeByte('l');
                for (list) |element| {
                    try element.encode(writer);
                }
                try writer.writeByte('e');
            },
            .Dict => |dict| {
                try writer.writeByte('d');
                for (dict.keys(), dict.values()) |k, v| {
                    try (Value{ .String = k }).encode(writer);
                    try v.encode(writer);
                }
                try writer.writeByte('e');
            },
        }
    }
    // TODO: some getters
};

pub fn infoHash(info_raw: []const u8) [Sha1.digest_length]u8 {
    var out: [Sha1.digest_length]u8 = undefined;
    Sha1.hash(info_raw, &out, .{});
    return out;
}

pub fn parseTorrent(allocator: Allocator, input: []const u8) ParseErrors!struct { value: Value, info_raw: ?[]const u8 } {
    if (input.len == 0) return ParseErrors.UnexpectedEOF;
    if (input[0] != 'd') return ParseErrors.InvalidByte;

    var pos: usize = 0;
    var info_raw: ?[]const u8 = null;
    const value = try parseDictCapturing(input, &pos, allocator, "info", &info_raw);
    return .{ .value = value, .info_raw = info_raw };
}

fn parseDictCapturing(
    input: []const u8,
    pos: *usize,
    alloc: Allocator,
    capture_key: []const u8,
    captured: *?[]const u8,
) ParseErrors!Value {
    pos.* += 1;
    var dict: std.array_hash_map.String(Value) = .empty;
    errdefer {
        for (dict.values()) |*v| {
            v.deinit(alloc);
        }
        dict.deinit(alloc);
    }

    while (true) {
        if (pos.* >= input.len) return ParseErrors.UnexpectedEOF;
        if (input[pos.*] == 'e') {
            pos.* += 1;
            break;
        }
        const key = (try parseString(input, pos)).String;

        const val_start = pos.*;
        const value = try parseValue(alloc, pos, input);
        const val_end = pos.*;

        if (std.mem.eql(u8, key, capture_key)) {
            captured.* = input[val_start..val_end];
        }
        try dict.put(alloc, key, value);
    }
    return .{ .Dict = dict };
}

fn parseValue(allocator: Allocator, pos: *usize, input: []const u8) ParseErrors!Value {
    if (pos.* >= input.len) return error.UnexpectedEOF;
    return switch (input[pos.*]) {
        'i' => .{ .Integer = try parseInteger(input, pos) },
        'l' => try parseList(input, pos, allocator),
        'd' => try parseInnerDict(input, pos, allocator),
        '0'...'9' => try parseString(input, pos),
        else => ParseErrors.InvalidByte,
    };
}

fn parseInnerDict(input: []const u8, pos: *usize, alloc: Allocator) ParseErrors!Value {
    pos.* += 1;
    var dict: std.array_hash_map.String(Value) = .empty;
    errdefer {
        for (dict.values()) |*v| {
            v.deinit(alloc);
        }
        dict.deinit(alloc);
    }

    while (true) {
        if (pos.* >= input.len) return ParseErrors.UnexpectedEOF;
        if (input[pos.*] == 'e') {
            pos.* += 1;
            break;
        }
        if (input[pos.*] < '0' or input[pos.*] > '9') return ParseErrors.InvalidByte;

        // TODO: do i need sorting?
        const key = (try parseString(input, pos)).String;
        const value = try parseValue(alloc, pos, input);
        try dict.put(alloc, key, value);
    }

    return .{ .Dict = dict };
}

fn parseList(input: []const u8, pos: *usize, alloc: Allocator) ParseErrors!Value {
    pos.* += 1;

    var list: std.ArrayList(Value) = .empty;
    errdefer {
        for (list.items) |*el| {
            el.deinit(alloc);
        }
        list.deinit(alloc);
    }

    while (true) {
        if (pos.* >= input.len) return error.UnexpectedEOF;
        if (input[pos.*] == 'e') {
            pos.* += 1;
            break;
        }
        const val = try parseValue(alloc, pos, input);
        try list.append(alloc, val);
    }

    return .{ .List = try list.toOwnedSlice(alloc) };
}

fn parseInteger(input: []const u8, pos: *usize) ParseErrors!i64 {
    const start = pos.* + 1;
    const e = std.mem.findScalarPos(u8, input, start, 'e') orelse return error.UnexpectedEOF;
    const num = input[start..e];
    if (num.len == 0) return error.InvalidInt;

    // to validate the number
    if (std.mem.eql(u8, num, "-0")) return error.InvalidInt;
    const digit = if (num[0] == '-') num[1..] else num;
    if (digit.len == 0) return ParseErrors.InvalidInt;
    if (digit.len >= 2 and digit[0] == '0') return error.LeadingZero;
    pos.* = e + 1;

    return try std.fmt.parseInt(i64, num, 10);
}

fn parseString(input: []const u8, pos: *usize) ParseErrors!Value {
    const colon = std.mem.findScalarPos(u8, input, pos.*, ':') orelse return ParseErrors.UnexpectedEOF;
    // an array to hold the data
    const length = input[pos.*..colon];
    if (length.len == 0) return ParseErrors.InvalidInt;
    if (length.len > 2 and length[0] == '0') return ParseErrors.LeadingZero;
    const len_num = try std.fmt.parseInt(usize, length, 10);

    const str_start = colon + 1;
    const end = std.math.add(usize, str_start, len_num) catch return ParseErrors.Overflow;
    if (end > input.len) return ParseErrors.UnexpectedEOF;

    pos.* = end;
    return .{ .String = input[str_start..end] };
}

// ===============TESTS=====================

fn expectRoundTrip(input: []const u8) !void {
    var pos: usize = 0;
    var value = try parseValue(testing.allocator, &pos, input);
    defer value.deinit(testing.allocator);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try value.encode(&aw.writer);
    try testing.expectEqualStrings(input, aw.written());
}

test "string" {
    var pos: usize = 0;
    var v = try parseValue(testing.allocator, &pos, "4:spam");
    defer v.deinit(testing.allocator);
    try testing.expectEqualStrings("spam", v.String);
}

test "empty string" {
    var pos: usize = 0;
    var v = try parseValue(testing.allocator, &pos, "0:");
    defer v.deinit(testing.allocator);
    try testing.expectEqualStrings("", v.String);
}

test "integer" {
    var pos: usize = 0;
    var v = try parseValue(testing.allocator, &pos, "i3e");
    defer v.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 3), v.Integer);
}

test "negative int" {
    var pos: usize = 0;
    var v = try parseValue(testing.allocator, &pos, "i-3e");
    defer v.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, -3), v.Integer);
}

test "list" {
    var pos: usize = 0;
    var v = try parseValue(testing.allocator, &pos, "l4:spam4:eggse");
    defer v.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), v.List.len);
    try testing.expectEqualStrings("spam", v.List[0].String);
    try testing.expectEqualStrings("eggs", v.List[1].String);
}

test "dict" {
    var pos: usize = 0;
    var v = try parseValue(testing.allocator, &pos, "d3:cow3:moo4:spam4:eggse");
    defer v.deinit(testing.allocator);
    try testing.expectEqualStrings("moo", v.Dict.get("cow").?.String);
    try testing.expectEqualStrings("eggs", v.Dict.get("spam").?.String);
}

test "round trip" {
    try expectRoundTrip("4:spam");
    try expectRoundTrip("i-42e");
    try expectRoundTrip("l4:spam4:eggse");
    try expectRoundTrip("d3:cow3:moo4:spam4:eggse");
    try expectRoundTrip("d4:listli1ei2ee3:keyi0ee");
}

test "leading zero integer" {
    var pos: usize = 0;
    try testing.expectError(error.LeadingZero, parseValue(std.testing.allocator, &pos, "i03e"));
}

test "trucated ints" {
    var pos: usize = 0;
    try testing.expectError(error.UnexpectedEOF, parseValue(std.testing.allocator, &pos, "i42"));
}

test "negative zero" {
    var pos: usize = 0;
    try testing.expectError(error.InvalidInt, parseValue(testing.allocator, &pos, "i-0e"));
}

test "string longer than input" {
    var pos: usize = 0;
    try testing.expectError(error.UnexpectedEOF, parseValue(testing.allocator, &pos, "10:spam"));
}

test "unterminated list" {
    var pos: usize = 0;
    try testing.expectError(error.UnexpectedEOF, parseValue(testing.allocator, &pos, "l4:spam"));
}

test "invalid leading byte" {
    var pos: usize = 0;
    try testing.expectError(error.InvalidByte, parseValue(testing.allocator, &pos, "x"));
}
