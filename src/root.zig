// SPDX-License-Identifier: CC0-1.0

//! Fluxion Encoding - bytes to text and back, and the byte order in between.
//!
//! Six pieces that fit together:
//!
//!   `base64`    RFC 4648 in both alphabets, padded or not, wrapped or not
//!   `hex`       hex in either case, with separators, and a hex dump
//!   `endian`    fixed-width values in whichever byte order the format uses
//!   `varint`    integers that cost one byte when they are small
//!   `bits`      fields that are not a whole number of bytes wide
//!   `quantize`  floats, angles, normals and rotations, into those fields
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
pub const varint = @import("varint.zig");
pub const bits = @import("bits.zig");
pub const quantize = @import("quantize.zig");

/// Moved. A UUID is a name for a thing, not a way of writing bytes down, so it
/// lives in fluxion-id along with `TypeId` and `handle` - and the version there
/// is the complete one: versions 4, 5 and 7, the URN form, `variant`, and a
/// `Clock` that keeps ids ordered inside a millisecond.
///
/// ```zig
/// const ids = @import("fluxion_id");
/// const asset = ids.Uuid.fromName(namespace, "models/player.glb");
/// ```
///
/// This library still carries the bytes: `putBytes(&id.bytes)` writes one, and
/// `hex` prints one. It just does not define it.
pub const Uuid = @compileError(
    "fluxion-encoding: Uuid moved to fluxion-id. " ++
        "Depend on fluxion_id and use `ids.Uuid`.",
);

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

/// Shorthand for `bits.Reader.init`, for the fields that are narrower than a
/// byte.
pub fn readBits(bytes: []const u8) bits.Reader {
    return .init(bytes);
}

/// Shorthand for `bits.Writer.init`.
pub fn writeBits(bytes: []u8) bits.Writer {
    return .init(bytes);
}

test {
    // Pull each module in so `zig build test` runs its tests too.
    _ = base64;
    _ = hex;
    _ = endian;
    _ = varint;
    _ = bits;
    _ = quantize;
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

test "a packet, in as few bits as it will go" {
    // A sixteen-byte asset id names what moved; the rest is quantized down to
    // the precision anyone can actually tell apart. Where the id came from is
    // fluxion-id's business - here it is sixteen bytes, which is all this
    // library ever sees of one.
    const model: [16]u8 = .{
        0x2F, 0x8A, 0x1C, 0x40, 0x6D, 0x3E, 0x4B, 0x17,
        0x9F, 0x22, 0xC1, 0xA5, 0xE7, 0xB9, 0x0D, 0x34,
    };

    const position = quantize.Range.init(-500, 500, 16);
    const heading = quantize.angle(12);

    var buf: [64]u8 = undefined;
    var w = write(&buf, .big);
    try w.putBytes(&model); // 16 bytes
    try w.putVarint(u32, 4211); // an entity id, two bytes
    try w.putVarint(i32, -3); // a frame delta, one byte

    // The rest goes into a bit stream, byte-aligned behind the header.
    var bw = writeBits(buf[w.written().len..]);
    try position.put(&bw, 12.5);
    try position.put(&bw, -300.25);
    try heading.put(&bw, 1.75);
    try bw.putBool(true);

    const packet = buf[0 .. w.written().len + bw.written().len];
    try testing.expectEqual(@as(usize, 25), packet.len);

    // And back.
    var r = read(packet, .big);
    try testing.expectEqualSlices(u8, &model, try r.takeArray(16));
    try testing.expectEqual(@as(u32, 4211), try r.takeVarint(u32));
    try testing.expectEqual(@as(i32, -3), try r.takeVarint(i32));

    var br = readBits(r.rest());
    try testing.expectApproxEqAbs(@as(f32, 12.5), try position.take(&br), position.precision());
    try testing.expectApproxEqAbs(@as(f32, -300.25), try position.take(&br), position.precision());
    try testing.expectApproxEqAbs(@as(f32, 1.75), try heading.take(&br), heading.precision());
    try testing.expect(try br.takeBool());
}

test "shorthands" {
    var buf: [4]u8 = undefined;
    var w = write(&buf, .little);
    try w.put(u32, 0x01020304);

    var r = read(&buf, .little);
    try testing.expectEqual(@as(u32, 0x01020304), try r.take(u32));

    var bw = writeBits(&buf);
    try bw.put(u8, 5, 3);
    var br = readBits(bw.written());
    try testing.expectEqual(@as(u8, 5), try br.take(u8, 3));
}
