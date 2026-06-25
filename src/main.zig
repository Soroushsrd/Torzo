const std = @import("std");

const tor = @import("tor");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const user_args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    var output_path: ?[]const u8 = null;
    var input_path: ?[]const u8 = null;
    switch (user_args.len) {
        2 => {
            // output path is the local directory
            // it stays null for now
            input_path = user_args[1];
        },
        3 => {
            output_path = user_args[2];
            input_path = user_args[1];
        },
        else => {
            std.log.err("tor <torrent file path> (optional)<output path>", .{});
            return;
        },
    }

    const in_path = input_path.?;
    const in_file = std.Io.Dir.cwd().openFile(io, in_path, .{ .mode = .read_only }) catch |e| {
        std.log.err("opening the input file ({s}) failed: {any}", .{ in_path, e });
        return;
    };
    defer in_file.close(io);

    var read_buff: [4096]u8 = undefined;
    var file_reader = in_file.reader(io, &read_buff);
    const reader = &file_reader.interface;

    var contents: std.ArrayList(u8) = .empty;
    try reader.appendRemaining(arena, &contents, .unlimited);
    std.log.info("read {d} bytes from {s}", .{ contents.items.len, in_path });

    const result = try tor.Bencode.parseTorrent(arena, contents.items);
    const hash = tor.Bencode.infoHash(result.info_raw orelse {
        std.log.err("torrent has no 'info' dict", .{});
        return;
    });
    std.log.info("infohash: {x}", .{hash});
    const meta = try tor.MetaInfo.MetaInfo.fromBencode(arena, result.value, hash);
    std.log.info("name: {s}", .{meta.info.name});
    std.log.info("piece length: {d}", .{meta.info.piece_len});
    std.log.info("num pieces: {d}", .{meta.info.pieces.len / 20});
    if (meta.info.length) |len| std.log.info("single file, {d} bytes", .{len});
    if (meta.announce) |a| std.log.info("tracker: {s}", .{a});
}
