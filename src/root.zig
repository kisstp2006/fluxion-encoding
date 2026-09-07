// SPDX-License-Identifier: CC0-1.0

//! Fluxion Encoding - bytes to text and back, and the byte order in between.
//!
//! Three pieces:
//!
//!   `base64`  RFC 4648 in both alphabets, padded or not, wrapped or not
//!   `hex`     hex in either case, with separators, and a hex dump
//!   `endian`  fixed-width values in whichever byte order the format uses
//!
//! The two codecs share one shape, so swapping between them is a change of
//! name and nothing else:
//!
//!   `encode` / `decode`            into a slice you own, no allocation
//!   `encodeAlloc` / `decodeAlloc`  into fresh memory, you free it
//!   `encodedLen` / `decodedLen`    how much room a call needs
//!   `encodeWriter`                 straight into a `std.Io.Writer`
//!
//! Nothing here allocates unless it takes an `Allocator`, and everything that
//! allocates says who owns the result.

const std = @import("std");
const testing = std.testing;

pub const base64 = @import("base64.zig");
pub const hex = @import("hex.zig");
pub const endian = @import("endian.zig");

/// Byte order, re-exported from `std.builtin`. See `endian`.
pub const Endian = endian.Endian;

/// A cursor that reads fixed-width values out of a byte slice. See `endian`.
pub const Reader = endian.Reader;

/// Its mirror, writing them into a slice you own. See `endian`.
pub const Writer = endian.Writer;

/// A big-endian field inside a struct that maps onto bytes. See `endian`.
pub const Big = endian.Big;

/// A little-endian one. See `endian`.
pub const Little = endian.Little;

/// Shorthand for `Reader.init`, so call sites read `enc.read(bytes, .big)`.
pub fn read(bytes: []const u8, order: Endian) Reader {
    return .init(bytes, order);
}

/// Shorthand for `Writer.init`.
pub fn write(bytes: []u8, order: Endian) Writer {
    return .init(bytes, order);
}

test {
    // Pull each module in so `zig build test` runs its tests too.
    _ = base64;
    _ = hex;
    _ = endian;
    _ = @import("sink.zig");
}

test "the pieces compose" {
    // A record built by hand, handed over as text, and read back out.
    var buf: [16]u8 = undefined;
    var w = write(&buf, .big);
    try w.putBytes("FLUX");
    try w.put(u16, 1);
    try w.put(u32, 0xDEADBEEF);

    const text = try base64.encodeAlloc(testing.allocator, w.written(), .{
        .alphabet = .url_safe,
        .padding = false,
    });
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("RkxVWAAB3q2-7w", text);

    const bytes = try base64.decodeAlloc(testing.allocator, text, .{
        .alphabet = .url_safe,
    });
    defer testing.allocator.free(bytes);

    var r = read(bytes, .big);
    try r.expectBytes("FLUX");
    try testing.expectEqual(@as(u16, 1), try r.take(u16));

    const payload = try r.take(u32);
    try testing.expectEqual(@as(u32, 0xDEADBEEF), payload);
    try testing.expect(r.isAtEnd());

    // And the same four bytes as hex, which is the readable spelling.
    var digits: [11]u8 = undefined;
    var field: [4]u8 = undefined;
    endian.write(u32, &field, payload, .big);
    try testing.expectEqualStrings(
        "de:ad:be:ef",
        try hex.encode(&digits, &field, .{ .separator = ":" }),
    );
}

test "shorthands" {
    var buf: [4]u8 = undefined;
    var w = write(&buf, .little);
    try w.put(u32, 0x01020304);

    var r = read(&buf, .little);
    try testing.expectEqual(@as(u32, 0x01020304), try r.take(u32));
}
