const std = @import("std");
const Bencode = @import("bencode.zig");
const Allocator = std.mem.Allocator;
const ValueError = Bencode.ValueError;
const Value = Bencode.Value;

pub const MetaInfo = struct {
    /// 'announce'
    announce: ?[]const u8,
    /// 'announce-list'
    announce_list: ?[][][]const u8,
    /// 'encoding'
    encoding: ?[]const u8,
    /// 'info'
    info: Info,
    /// calculated info hash using SHA1 hash
    info_hash: [20]u8,

    pub fn fromBencode(alloc: Allocator, root: Value, info_hash: [20]u8) ValueError!MetaInfo {
        const announce = try root.getStringOpt("announce");
        const encoding = try root.getStringOpt("encoding");
        const announce_list = try parseAnnounceList(alloc, try root.getDict());

        const info_val = (try root.getDict()).get("info") orelse return ValueError.MissingField;
        const info = try parseInfo(alloc, info_val);

        return .{
            .announce = announce,
            .announce_list = announce_list,
            .encoding = encoding,
            .info = info,
            .info_hash = info_hash,
        };
    }

    pub fn getTrackerUrl(self: MetaInfo, alloc: Allocator) [][]const u8 {
        var seen = std.StringHashMap(void).init(alloc);
        defer seen.deinit(alloc);

        var list = try std.ArrayList([]const u8).initCapacity(alloc, 10);
        errdefer list.deinit(alloc);
        if (self.announce_list) |tiers| {
            for (tiers) |tier| {
                for (tier) |url| {
                    const gop = try seen.getOrPut(url);
                    if (!gop.found_existing) {
                        try list.append(alloc, url);
                    }
                }
            }
        }
        if (self.announce) |url| {
            const gop = try seen.getOrPut(url);
            if (!gop.found_existing) {
                try list.append(alloc, url);
            }
        }
        return list.toOwnedSlice(alloc);
    }
};

fn parseInfo(alloc: Allocator, info_val: Value) ValueError!Info {
    const name = try info_val.getString("name");
    const pieces = try info_val.getString("pieces");

    if (pieces.len == 0 or pieces.len % 20 != 0) return ValueError.InvalidePieces;

    const piece_len_i = try info_val.getInt("piece length");
    if (piece_len_i <= 0) return ValueError.WrongType;
    const piece_len: usize = @intCast(piece_len_i);

    const length_opt = try info_val.getIntOpt("length");
    const files_opt = try parseFiles(alloc, try info_val.getDict());

    if (length_opt != null and files_opt != null) return ValueError.Invalid;
    if (length_opt == null and files_opt == null) return ValueError.Invalid;

    // var length: ?usize = null;
    const length: ?usize = if (length_opt) |l| blk: {
        if (l < 0) return ValueError.WrongType;
        break :blk @intCast(l);
    } else null;

    return .{
        .name = name,
        .piece_len = piece_len,
        .pieces = pieces,
        .length = length,
        .files = files_opt,
    };
}

fn parseFiles(alloc: Allocator, info_dict: std.array_hash_map.String(Value)) ValueError!?[]TorrentFile {
    const files_val = info_dict.get("files") orelse return null;
    const list = switch (files_val) {
        .List => |l| l,
        else => return ValueError.WrongType,
    };

    var files: std.ArrayList(TorrentFile) = .empty;
    errdefer files.deinit(alloc);

    for (list) |entry| {
        const len_i = try entry.getInt("length");
        if (len_i < 0) return ValueError.WrongType;
        const path = try parsePath(alloc, try entry.getDict());
        try files.append(alloc, .{
            .length = @intCast(len_i),
            .path = path,
        });
    }
    return try files.toOwnedSlice(alloc);
}

fn parsePath(alloc: Allocator, file_dict: std.array_hash_map.String(Value)) ValueError![][]const u8 {
    const path_val = file_dict.get("path") orelse return ValueError.MissingField;
    const components = switch (path_val) {
        .List => |l| l,
        else => return ValueError.WrongType,
    };

    var parts: std.ArrayList([]const u8) = .empty;
    errdefer parts.deinit(alloc);

    for (components) |v| {
        const str = switch (v) {
            .String => |s| s,
            else => return ValueError.WrongType,
        };
        try parts.append(alloc, str);
    }
    return try parts.toOwnedSlice(alloc);
}

fn parseAnnounceList(alloc: Allocator, dict: std.array_hash_map.String(Value)) ValueError!?[][][]const u8 {
    const al_val = dict.get("announce-list") orelse return null;
    const tiers = switch (al_val) {
        .List => |l| l,
        else => return ValueError.WrongType,
    };

    var out: std.ArrayList([][]const u8) = .empty;
    errdefer out.deinit(alloc);

    for (tiers) |entry| {
        const tier = switch (entry) {
            .List => |l| l,
            else => return ValueError.WrongType,
        };
        var urls: std.ArrayList([]const u8) = .empty;
        errdefer urls.deinit(alloc);

        for (tier) |url_val| {
            const url = switch (url_val) {
                .String => |s| s,
                else => return ValueError.WrongType,
            };
            try urls.append(alloc, url);
        }
        try out.append(alloc, try urls.toOwnedSlice(alloc));
    }

    return try out.toOwnedSlice(alloc);
}

pub const Info = struct {
    /// maps to a string which is the suggest name to save the file
    /// if 'files' is present, this maps to the directory they should
    /// be saved in. otherwise its the name of the file
    name: []const u8,
    /// number of bytes in each piece the file is split into
    /// always a power of 2
    piece_len: usize,
    /// maps to a string whose length is a multiple of 20
    /// it is to be subdivided into strings of length 20
    /// each of which is the SHA1 hash of the piece at the corresponding idx
    pieces: []const u8,
    /// if length is present, then the download represents a single file
    /// in this case, length maps to the length of the file in bytes
    /// either length or files is present
    length: ?usize,
    /// a set of files which go in a directory structure
    /// files should be concatenated in the order they appear in the files list
    files: ?[]TorrentFile,
};

pub const TorrentFile = struct {
    length: usize,
    path: [][]const u8,
};
