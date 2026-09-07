// SPDX-License-Identifier: CC0-1.0

//! Variable-length integers: seven bits of payload per byte, with the top bit
//! saying whether another byte follows.
//!
//! The same LEB128 that DWARF, WebAssembly and Protocol Buffers use. Small
//! numbers cost one byte, which is what most numbers in a save file or a
//! packet turn out to be: an entity count, a component id, a frame delta.
//!
//! Signed types go through zigzag first, so `-1` costs one byte rather than
//! ten. That is the right default for the small signed deltas games send;
//! `zigzag` and `unzigzag` are public if you need the mapping on its own.
//!
//! Everything works on plain slices and reports how many bytes it touched, so
//! a varint can sit in the middle of a record. `endian.Reader` and
//! `endian.Writer` have `takeVarint` and `putVarint` built on this.

const std = @import("std");
const testing = std.testing;

pub const WriteError = error{
    /// The destination has no room left for the value.
    NoSpaceLeft,
};

pub const ReadError = error{
    /// The input ran out while a byte still promised another one.
    UnexpectedEnd,
    /// The encoded value carries more bits than `T` can hold.
    Overflow,
};

/// A value together with the number of bytes it came from.
pub fn Decoded(comptime T: type) type {
    return struct {
        value: T,
        len: usize,
    };
}

fn Unsigned(comptime T: type) type {
    return std.meta.Int(.unsigned, @typeInfo(T).int.bits);
}

/// The most bytes a `T` can ever take: seven payload bits each.
pub fn maxLen(comptime T: type) usize {
    return (@typeInfo(T).int.bits + 6) / 7;
}

/// Fold a signed value onto an unsigned one so that small magnitudes stay
/// small: `0, -1, 1, -2, 2` become `0, 1, 2, 3, 4`.
pub fn zigzag(comptime T: type, value: T) Unsigned(T) {
    const U = Unsigned(T);
    const bits = @typeInfo(T).int.bits;
    const raw: U = @bitCast(value);
    // An arithmetic shift by the sign bit gives all-ones for negatives.
    return (raw << 1) ^ @as(U, @bitCast(value >> (bits - 1)));
}

/// The inverse of `zigzag`.
pub fn unzigzag(comptime T: type, value: Unsigned(T)) T {
    const U = Unsigned(T);
    // `-(value & 1)` is all-ones when the low bit says "negative".
    const sign: U = @bitCast(-@as(T, @bitCast(value & 1)));
    return @bitCast((value >> 1) ^ sign);
}

/// Exactly how many bytes `encode` writes for `value`.
pub fn encodedLen(comptime T: type, value: T) usize {
    var rest = if (@typeInfo(T).int.signedness == .signed)
        zigzag(T, value)
    else
        value;
    var n: usize = 1;
    while (rest >= 0x80) : (n += 1) rest >>= 7;
    return n;
}

/// Encode `value` into the front of `out`, returning how many bytes it took.
pub fn encode(comptime T: type, out: []u8, value: T) WriteError!usize {
    var rest = if (@typeInfo(T).int.signedness == .signed)
        zigzag(T, value)
    else
        value;

    var n: usize = 0;
    while (true) {
        if (n == out.len) return error.NoSpaceLeft;
        const septet: u8 = @truncate(rest & 0x7F);
        rest >>= 7;
        if (rest == 0) {
            out[n] = septet;
            return n + 1;
        }
        out[n] = septet | 0x80;
        n += 1;
    }
}

/// Decode the value at the front of `bytes`, along with its length.
///
/// A redundant encoding - one padded out with `0x80` bytes that add nothing -
/// decodes to the value it spells, the way Protocol Buffers reads it. Only
/// bits that would not fit in `T` are an error.
pub fn decode(comptime T: type, bytes: []const u8) ReadError!Decoded(T) {
    const U = Unsigned(T);
    const bits = @typeInfo(T).int.bits;

    var raw: U = 0;
    var shift: u16 = 0;
    for (bytes, 0..) |byte, i| {
        const septet: U = @truncate(byte & 0x7F);
        if (shift >= bits) {
            // Past the end of the type: anything but zero has overflowed.
            if (septet != 0) return error.Overflow;
        } else {
            // The last septet may be cut short by the width of the type.
            if (bits - shift < 7 and septet >> @intCast(bits - shift) != 0) {
                return error.Overflow;
            }
            raw |= septet << @intCast(shift);
        }
        shift += 7;

        if (byte & 0x80 == 0) return .{
            .value = if (@typeInfo(T).int.signedness == .signed)
                unzigzag(T, raw)
            else
                raw,
            .len = i + 1,
        };
    }
    return error.UnexpectedEnd;
}

/// How many bytes the varint at the front of `bytes` occupies, without
/// decoding it. Cheaper than `decode` when you only mean to step over it.
pub fn len(bytes: []const u8) ReadError!usize {
    for (bytes, 0..) |byte, i| {
        if (byte & 0x80 == 0) return i + 1;
    }
    return error.UnexpectedEnd;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "maxLen" {
    try testing.expectEqual(@as(usize, 2), maxLen(u8));
    try testing.expectEqual(@as(usize, 3), maxLen(u16));
    try testing.expectEqual(@as(usize, 5), maxLen(u32));
    try testing.expectEqual(@as(usize, 10), maxLen(u64));
}

test "small numbers cost one byte" {
    var buf: [10]u8 = undefined;
    for (0..128) |n| {
        const value: u32 = @intCast(n);
        try testing.expectEqual(@as(usize, 1), try encode(u32, &buf, value));
        try testing.expectEqual(@as(usize, 1), encodedLen(u32, value));
        try testing.expectEqual(value, (try decode(u32, &buf)).value);
    }
    // 128 is the first that needs two.
    try testing.expectEqual(@as(usize, 2), try encode(u32, &buf, 128));
    try testing.expectEqualSlices(u8, &.{ 0x80, 0x01 }, buf[0..2]);
}

test "known encodings" {
    var buf: [10]u8 = undefined;
    const cases = [_]struct { value: u32, wire: []const u8 }{
        .{ .value = 0, .wire = &.{0x00} },
        .{ .value = 1, .wire = &.{0x01} },
        .{ .value = 127, .wire = &.{0x7F} },
        .{ .value = 128, .wire = &.{ 0x80, 0x01 } },
        .{ .value = 300, .wire = &.{ 0xAC, 0x02 } },
        .{ .value = 16383, .wire = &.{ 0xFF, 0x7F } },
        .{ .value = 16384, .wire = &.{ 0x80, 0x80, 0x01 } },
        .{ .value = std.math.maxInt(u32), .wire = &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F } },
    };
    for (cases) |case| {
        const n = try encode(u32, &buf, case.value);
        try testing.expectEqualSlices(u8, case.wire, buf[0..n]);
        try testing.expectEqual(case.value, (try decode(u32, case.wire)).value);
        try testing.expectEqual(case.wire.len, (try decode(u32, case.wire)).len);
        try testing.expectEqual(case.wire.len, try len(case.wire));
    }
}

test "zigzag keeps small negatives small" {
    try testing.expectEqual(@as(u32, 0), zigzag(i32, 0));
    try testing.expectEqual(@as(u32, 1), zigzag(i32, -1));
    try testing.expectEqual(@as(u32, 2), zigzag(i32, 1));
    try testing.expectEqual(@as(u32, 3), zigzag(i32, -2));
    try testing.expectEqual(@as(u32, 4), zigzag(i32, 2));

    const edges = [_]i32{ 0, -1, 1, -2, 2, 1000, -1000, std.math.maxInt(i32), std.math.minInt(i32) };
    for (edges) |value| {
        try testing.expectEqual(value, unzigzag(i32, zigzag(i32, value)));
    }

    // Which is the whole point: -1 is one byte, not ten.
    var buf: [10]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), try encode(i32, &buf, -1));
    try testing.expectEqual(@as(usize, 1), try encode(i64, &buf, -1));
    try testing.expectEqual(@as(usize, 2), try encode(i32, &buf, -100));
}

test "round trip across the whole range of a type" {
    var buf: [10]u8 = undefined;
    for (0..256) |n| {
        const value: u8 = @intCast(n);
        const written = try encode(u8, &buf, value);
        try testing.expectEqual(written, encodedLen(u8, value));
        const back = try decode(u8, buf[0..written]);
        try testing.expectEqual(value, back.value);
        try testing.expectEqual(written, back.len);

        const signed: i8 = @bitCast(value);
        const signed_written = try encode(i8, &buf, signed);
        try testing.expectEqual(signed, (try decode(i8, buf[0..signed_written])).value);
    }
}

test "wide values" {
    var buf: [10]u8 = undefined;
    const values = [_]u64{
        0,
        1,
        std.math.maxInt(u32),
        1 << 63,
        std.math.maxInt(u64),
    };
    for (values) |value| {
        const written = try encode(u64, &buf, value);
        try testing.expectEqual(written, encodedLen(u64, value));
        try testing.expectEqual(value, (try decode(u64, buf[0..written])).value);
    }
    try testing.expectEqual(@as(usize, 10), try encode(u64, &buf, std.math.maxInt(u64)));
}

test "a varint in the middle of a record" {
    // Decoding reports its length, so the next field starts where it says.
    const wire = [_]u8{ 0xAC, 0x02, 'h', 'i' };
    const count = try decode(u32, &wire);
    try testing.expectEqual(@as(u32, 300), count.value);
    try testing.expectEqualStrings("hi", wire[count.len..]);
}

test "truncated and oversized input" {
    // A trailing byte that still promises another one.
    try testing.expectError(error.UnexpectedEnd, decode(u32, &.{0x80}));
    try testing.expectError(error.UnexpectedEnd, decode(u32, &.{ 0xFF, 0xFF }));
    try testing.expectError(error.UnexpectedEnd, decode(u32, ""));
    try testing.expectError(error.UnexpectedEnd, len(&.{0x80}));

    // More bits than the type can hold.
    try testing.expectError(error.Overflow, decode(u8, &.{ 0x80, 0x80, 0x01 }));
    try testing.expectError(error.Overflow, decode(u32, &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x10 }));
    try testing.expectError(
        error.Overflow,
        decode(u64, &.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02 }),
    );

    var buf: [1]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, encode(u32, &buf, 128));
}

test "redundant encodings decode to what they spell" {
    // Padded out with bytes that add nothing; Protocol Buffers reads these.
    try testing.expectEqual(@as(u32, 0), (try decode(u32, &.{ 0x80, 0x00 })).value);
    try testing.expectEqual(@as(u32, 1), (try decode(u32, &.{ 0x81, 0x80, 0x00 })).value);
    try testing.expectEqual(@as(usize, 3), (try decode(u32, &.{ 0x81, 0x80, 0x00 })).len);
    // But the value itself still has to fit.
    try testing.expectEqual(
        @as(u64, std.math.maxInt(u64)),
        (try decode(u64, &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 })).value,
    );
}
