//! BitTorrent peer protocol operates over TCP
//! Peer protocol refers to pieces o f the file by index as described in the metainfo
//! and starts at zero.When a peer finishes downloading a piece and checks the hash matches
//! it will announce that it has that piece to all peers.
//! Connection contains 4 states: chocked, unchocked, interested, uninterested:
//!  - Data transfer happens when one side is interested and the otherside is notchoking
//!  - Interest state must be kept up to date at all times
//!  - Connections start out chocked and not interested
//!  - Downloades should keep several piece requests queued up at once to get good TCP perf
//! =============#WireProtocol#=========
//! The peer wire protocol constists of:
//!  - Handshake
//!  - A never ending stream of length prefixed msgs.
//! =============*HANDSHAKE*============
//! * Handshake starts with character 19 followed by the string 'BitTorrent protocol'.
//! * All later integers sent in the protocol are encoded as four bytes big endian.
//! * After fixed headers, eight reserved bytes are written which are all zero
//! * Next comes the 20 byte sha1 hash of the bencoded form of the info value from metainfo file
//! * If both sides dont send the same value, connection is severed.
//! * After the download hash comes the 20 byte peer-id which is reported in tracker requests
//!   and contained in peer lists in tracker responses.
//! * If the receiving side's peer id doesnt match what we expect, connection is severed.
//! ===========*KEEPALIVES*=============
//! Then comes the alternating streams of length prefixes and msgs. Msgs of length zero are
//! keepalives (hearbeats) and ignored. These are sent out every 2minutes.
//! ===========*PEERMSG*===============
//! All non-keepalive msgs start with a single byte which gives their type:
//! 0. choke           <--\
//! 1. unchoke            | These have no payload
//! 2. interested         |
//! 3. not interested  <--/
//! 4. have
//! 5. bitfield
//! 6. request
//! 7. piece
//! 8. cancel
//!
//! * Bitfield is only ever sent as the first msg. its payload is a bitfield with each index
//!   that the downloader has set to one and the rest set to zero. The first byte of the bitfield
//!   corresponds to indices 0-7 from high bit to low bit. The next 8-15 are spare bits set to 0.
//! * Have msg's payload is a single number. The index which that downloader just completed and
//!   its checked hash(?).
//! * Request msgs contain and index, begin, and a length. The last two are byte offsets. Length
//!   is generally a power of two unless it gets trucated by EOF. Current implementations use
//!   16 kiB and close connections which request an amount greater than that
//! * Cancel msgs have the same payload as request msgs. They are generally only sent towards the
//!   end of a download.
//! * Piece msgs contain an index, begin, and piece. They are correlated with request msgs.
//!   Downloaders generally download pieces in a random order.
//! ==================================
