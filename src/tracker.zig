//! Tracker GET requests have the following keys:
//!   1. info_hash
//!   2. peer_id: string of len 20 whci downloaded uses as its id. randomly generated.
//!   3. ip: optional parameter giving the OP or dns name which the peer is at.
//!   4. port: the port number peer is listening on (usually 6881, 6882 and so on)
//!   5. uploaded: total amount uploaded so far
//!   6. downloaded; total amount downloaded so far
//!   7. left: number of bytes this peer still has to download encoded in base ten ascii
//!   8. event: optional key that maps to 'started', 'completed', or 'stopped'.
//! Tracker responses are bencoded dictionaries. They have two keys: "interval" and "peers"
//! Interval key maps to the number of seconds the downloaded should wait between rerequests
//! Peers contains a list of dictinaries with the keys above (info_hash ,etc)
const std = @import("std");
const ip = std.Io.net.IpAddress;

pub const TrackerInfo = struct {
    info_hash: [20]u8,
    peer_id: [20]u8,
    ip: ?ip,
    port: usize,
    uploaded: usize,
    downloaded: usize,
    left: usize,
    event: ?Event,
};

pub const Event = enum { Started, Completed, Stopped };

pub fn generatePeerID(io: std.Io) ![20]u8 {
    var buffer: [20]u8 = undefined;
    try std.Io.randomSecure(io, &buffer);
    @memcpy(buffer[0..8], "-TR2940-");
    return buffer;
}

test "peer id generation" {
    const peer_id = try generatePeerID(std.testing.io);
    try std.testing.expectEqualSlices(u8, "-TR2940-", peer_id[0..8]);
}
