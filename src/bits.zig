// SPDX-License-Identifier: CC0-1.0

//! Bit-level packing: fields that are not a whole number of bytes wide.
//!
//! A player state does not need a byte for a jump flag and four for a health
//! value that only ever reaches 100. `Writer` puts each field in exactly as
//! many bits as it needs and `Reader` takes them back out in the same order.
//!
//! Bits go most-significant first, within each byte and across bytes, so a
//! packet here matches the field diagrams in a protocol document. The last byte
//! is padded with zeros.
//!
//! The vocabulary is `endian`'s one level down: `put` and `take` name a type
//! and a width, `save` and `restore` back out of a reading. Nothing allocates.

const std = @import("std");
const testing = std.testing;

pub const ReadError = error{
    /// The input ran out before the field did.
    UnexpectedEnd,
};

pub const WriteError = error{
    /// The destination has no room left for the field.
    NoSpaceLeft,
};

/// Bytes needed to hold `bit_count` bits.
pub fn byteLen(bit_count: usize) usize {
    return (bit_count + 7) / 8;
}

/// How many bits it takes to hold every value from `0` to `max_value`. Zero
/// still costs one bit, since a field has to be written to be read back.
pub fn needed(max_value: u64) u16 {
    return if (max_value == 0) 1 else 64 - @clz(max_value);
}

/// The unsigned integer that `T` occupies bit for bit.
fn Unsigned(comptime T: type) type {
    return std.meta.Int(.unsigned, @bitSizeOf(T));
}

fn toRaw(comptime T: type, value: T) u64 {
    return switch (@typeInfo(T)) {
        .bool => @intFromBool(value),
        .int => @as(Unsigned(T), @bitCast(value)),
        .float => @as(Unsigned(T), @bitCast(value)),
        else => @compileError("fluxion-encoding: " ++ @typeName(T) ++
            " cannot be packed into bits; use an integer, float or bool"),
    };
}

fn fromRaw(comptime T: type, raw: u64) T {
    return switch (@typeInfo(T)) {
        .bool => raw != 0,
        .int => @bitCast(@as(Unsigned(T), @truncate(raw))),
        .float => @bitCast(@as(Unsigned(T), @truncate(raw))),
        else => comptime unreachable,
    };
}

// -------------------------------------------------------------------------
// Writer
// -------------------------------------------------------------------------

/// Packs fields into a buffer you own, bit by bit.
///
/// The buffer need not arrive zeroed: each byte is cleared as it is reached.
pub const Writer = struct {
    bytes: []u8,
    /// Bits written so far.
    bit: usize,

    pub fn init(bytes: []u8) Writer {
        return .{ .bytes = bytes, .bit = 0 };
    }

    /// The whole bytes written so far, including the part-filled last one,
    /// whose spare low bits are zero.
    pub fn written(self: *const Writer) []u8 {
        return self.bytes[0..byteLen(self.bit)];
    }

    /// Bits written so far.
    pub fn bitsWritten(self: *const Writer) usize {
        return self.bit;
    }

    /// Bits still free.
    pub fn remaining(self: *const Writer) usize {
        return self.bytes.len * 8 - self.bit;
    }

    pub fn isFull(self: *const Writer) bool {
        return self.remaining() == 0;
    }

    pub fn reset(self: *Writer) void {
        self.bit = 0;
    }

    /// Write the low `count` bits of `value`. Bits above `count` are dropped,
    /// so the caller decides the width and the type only decides the meaning.
    pub fn put(self: *Writer, comptime T: type, value: T, count: u16) WriteError!void {
        std.debug.assert(count >= 1 and count <= @bitSizeOf(T));
        if (self.remaining() < count) return error.NoSpaceLeft;

        const raw = toRaw(T, value);
        var left = count;
        while (left > 0) {
            const index = self.bit / 8;
            const used: u3 = @intCast(self.bit % 8);
            const free: u4 = 8 - @as(u4, used);
            const take: u4 = @intCast(@min(@as(u16, free), left));

            left -= take;
            // The next `take` bits of the value, counting from the top.
            const mask = (@as(u64, 1) << @intCast(take)) - 1;
            const chunk: u8 = @truncate(raw >> @intCast(left) & mask);

            if (used == 0) self.bytes[index] = 0;
            self.bytes[index] |= chunk << @intCast(free - take);
            self.bit += take;
        }
    }

    /// Write every bit of a `T`, for a field that is its natural width.
    pub fn putInt(self: *Writer, comptime T: type, value: T) WriteError!void {
        return self.put(T, value, @bitSizeOf(T));
    }

    /// One bit.
    pub fn putBool(self: *Writer, value: bool) WriteError!void {
        return self.put(bool, value, 1);
    }

    /// Write `count` zero bits, as a reserved field or a spacer.
    pub fn putZeroes(self: *Writer, count: usize) WriteError!void {
        if (self.remaining() < count) return error.NoSpaceLeft;
        var left = count;
        while (left > 0) {
            const take = @min(left, 64);
            try self.put(u64, 0, @intCast(take));
            left -= take;
        }
    }

    /// Pad with zeros up to the next byte boundary, so raw bytes can follow.
    pub fn alignToByte(self: *Writer) WriteError!void {
        const misaligned = self.bit % 8;
        if (misaligned != 0) try self.putZeroes(8 - misaligned);
    }

    /// Write whole bytes. Only valid on a byte boundary; call `alignToByte`
    /// first if you are not sure you are on one.
    pub fn putBytes(self: *Writer, bytes: []const u8) WriteError!void {
        std.debug.assert(self.bit % 8 == 0);
        if (self.remaining() < bytes.len * 8) return error.NoSpaceLeft;
        const index = self.bit / 8;
        @memcpy(self.bytes[index..][0..bytes.len], bytes);
        self.bit += bytes.len * 8;
    }
};

/// Shorthand for `Writer.init`.
pub fn writer(bytes: []u8) Writer {
    return .init(bytes);
}

// -------------------------------------------------------------------------
// Reader
// -------------------------------------------------------------------------

/// Takes back what `Writer` put in, in the same order and the same widths.
pub const Reader = struct {
    bytes: []const u8,
    /// Bits read so far.
    bit: usize,

    /// An opaque cursor position, produced by `save` and consumed by
    /// `restore`.
    pub const Mark = usize;

    pub fn init(bytes: []const u8) Reader {
        return .{ .bytes = bytes, .bit = 0 };
    }

    /// Bits not yet read.
    pub fn remaining(self: *const Reader) usize {
        return self.bytes.len * 8 - self.bit;
    }

    /// True once fewer than eight bits remain, which is all a `Writer` leaves
    /// behind as padding.
    pub fn isAtEnd(self: *const Reader) bool {
        return self.remaining() < 8;
    }

    pub fn bitsRead(self: *const Reader) usize {
        return self.bit;
    }

    pub fn save(self: *const Reader) Mark {
        return self.bit;
    }

    pub fn restore(self: *Reader, mark: Mark) void {
        std.debug.assert(mark <= self.bytes.len * 8);
        self.bit = mark;
    }

    pub fn reset(self: *Reader) void {
        self.bit = 0;
    }

    /// Read `count` bits as a `T`.
    pub fn take(self: *Reader, comptime T: type, count: u16) ReadError!T {
        std.debug.assert(count >= 1 and count <= @bitSizeOf(T));
        if (self.remaining() < count) return error.UnexpectedEnd;

        var raw: u64 = 0;
        var left = count;
        while (left > 0) {
            const index = self.bit / 8;
            const used: u3 = @intCast(self.bit % 8);
            const free: u4 = 8 - @as(u4, used);
            const take_n: u4 = @intCast(@min(@as(u16, free), left));

            const mask: u8 = @intCast((@as(u16, 1) << @intCast(take_n)) - 1);
            const chunk = self.bytes[index] >> @intCast(free - take_n) & mask;

            left -= take_n;
            raw |= @as(u64, chunk) << @intCast(left);
            self.bit += take_n;
        }
        return fromRaw(T, raw);
    }

    /// Read every bit of a `T`.
    pub fn takeInt(self: *Reader, comptime T: type) ReadError!T {
        return self.take(T, @bitSizeOf(T));
    }

    /// One bit.
    pub fn takeBool(self: *Reader) ReadError!bool {
        return self.take(bool, 1);
    }

    /// Read `count` bits without advancing.
    pub fn peek(self: *const Reader, comptime T: type, count: u16) ReadError!T {
        var copy = self.*;
        return copy.take(T, count);
    }

    pub fn skip(self: *Reader, count: usize) ReadError!void {
        if (self.remaining() < count) return error.UnexpectedEnd;
        self.bit += count;
    }

    /// Step over the padding to the next byte boundary.
    pub fn alignToByte(self: *Reader) ReadError!void {
        const misaligned = self.bit % 8;
        if (misaligned != 0) try self.skip(8 - misaligned);
    }

    /// Read whole bytes as they are. Only valid on a byte boundary; call
    /// `alignToByte` first if you are not sure you are on one. The result is a
    /// slice into the input.
    pub fn takeBytes(self: *Reader, n: usize) ReadError![]const u8 {
        std.debug.assert(self.bit % 8 == 0);
        if (self.remaining() < n * 8) return error.UnexpectedEnd;
        const index = self.bit / 8;
        defer self.bit += n * 8;
        return self.bytes[index..][0..n];
    }
};

/// Shorthand for `Reader.init`.
pub fn reader(bytes: []const u8) Reader {
    return .init(bytes);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "byteLen and needed" {
    try testing.expectEqual(@as(usize, 0), byteLen(0));
    try testing.expectEqual(@as(usize, 1), byteLen(1));
    try testing.expectEqual(@as(usize, 1), byteLen(8));
    try testing.expectEqual(@as(usize, 2), byteLen(9));

    try testing.expectEqual(@as(u16, 1), needed(0));
    try testing.expectEqual(@as(u16, 1), needed(1));
    try testing.expectEqual(@as(u16, 2), needed(2));
    try testing.expectEqual(@as(u16, 2), needed(3));
    try testing.expectEqual(@as(u16, 7), needed(100));
    try testing.expectEqual(@as(u16, 8), needed(255));
    try testing.expectEqual(@as(u16, 64), needed(std.math.maxInt(u64)));
}

test "bits land most-significant first" {
    var buf: [2]u8 = undefined;
    var w = writer(&buf);

    try w.putBool(true); // 1
    try w.putBool(false); // 0
    try w.put(u8, 0b110, 3); // 110
    try w.putBool(true); // 1

    // Six bits in, so the last two of the byte are padding.
    try testing.expectEqual(@as(usize, 6), w.bitsWritten());
    try testing.expectEqual(@as(usize, 1), w.written().len);
    try testing.expectEqual(@as(u8, 0b1011_0100), buf[0]);
}

test "a field wider than a byte" {
    var buf: [4]u8 = undefined;
    var w = writer(&buf);

    try w.put(u8, 0b111, 3);
    try w.put(u16, 0xABC, 12); // straddles two byte boundaries
    try testing.expectEqual(@as(usize, 15), w.bitsWritten());

    var r = reader(w.written());
    try testing.expectEqual(@as(u8, 0b111), try r.take(u8, 3));
    try testing.expectEqual(@as(u16, 0xABC), try r.take(u16, 12));
}

test "round trip a player state" {
    // The shape a game would actually send: a few small fields, packed.
    const State = struct {
        id: u16,
        health: u8, // 0..100
        jumping: bool,
        team: u2,
        angle: u12,
    };
    const sent: State = .{ .id = 4211, .health = 87, .jumping = true, .team = 2, .angle = 3000 };

    var buf: [8]u8 = undefined;
    var w = writer(&buf);
    try w.putInt(u16, sent.id);
    try w.put(u8, sent.health, needed(100));
    try w.putBool(sent.jumping);
    try w.putInt(u2, sent.team);
    try w.putInt(u12, sent.angle);

    // 16 + 7 + 1 + 2 + 12 = 38 bits, five bytes rather than seven.
    try testing.expectEqual(@as(usize, 38), w.bitsWritten());
    try testing.expectEqual(@as(usize, 5), w.written().len);

    var r = reader(w.written());
    try testing.expectEqual(sent.id, try r.takeInt(u16));
    try testing.expectEqual(sent.health, try r.take(u8, needed(100)));
    try testing.expectEqual(sent.jumping, try r.takeBool());
    try testing.expectEqual(sent.team, try r.takeInt(u2));
    try testing.expectEqual(sent.angle, try r.takeInt(u12));
    try testing.expect(r.isAtEnd());
}

test "every width round-trips at every offset" {
    var buf: [24]u8 = undefined;
    var width: u16 = 1;
    while (width <= 32) : (width += 1) {
        var offset: u16 = 0;
        while (offset < 8) : (offset += 1) {
            // The top `width` bits of a fixed pattern, so the value always fits.
            const value: u32 = @as(u32, 0xDEADBEEF) >> @intCast(32 - width);

            var w = writer(&buf);
            if (offset != 0) try w.put(u8, 0, offset);
            try w.put(u32, value, width);

            var r = reader(w.written());
            if (offset != 0) _ = try r.take(u8, offset);
            try testing.expectEqual(value, try r.take(u32, width));
        }
    }
}

test "signed, float and bool go through unchanged" {
    var buf: [16]u8 = undefined;
    var w = writer(&buf);

    try w.putBool(true);
    try w.putInt(i16, -1234);
    try w.putInt(f32, 1.5);
    try w.put(i8, -3, 4); // a small signed field, four bits wide

    var r = reader(w.written());
    try testing.expect(try r.takeBool());
    try testing.expectEqual(@as(i16, -1234), try r.takeInt(i16));
    try testing.expectEqual(@as(f32, 1.5), try r.takeInt(f32));
    // Four bits of -3 read back as a four-bit signed value.
    try testing.expectEqual(@as(i4, -3), try r.take(i4, 4));
}

test "peek, save and restore" {
    var buf: [2]u8 = undefined;
    var w = writer(&buf);
    try w.put(u8, 5, 4);
    try w.put(u8, 9, 4);

    var r = reader(w.written());
    try testing.expectEqual(@as(u8, 5), try r.peek(u8, 4));
    try testing.expectEqual(@as(usize, 0), r.bitsRead());

    const mark = r.save();
    try testing.expectEqual(@as(u8, 5), try r.take(u8, 4));
    try testing.expectEqual(@as(u8, 9), try r.take(u8, 4));
    r.restore(mark);
    // The same eight bits read as one field instead of two.
    try testing.expectEqual(@as(u8, 0x59), try r.takeInt(u8));
}

test "alignment and raw bytes" {
    var buf: [8]u8 = undefined;
    var w = writer(&buf);

    try w.put(u8, 0b101, 3);
    try w.alignToByte();
    try testing.expectEqual(@as(usize, 8), w.bitsWritten());
    try w.putBytes("hi");
    try testing.expectEqual(@as(u8, 0b1010_0000), buf[0]);

    var r = reader(w.written());
    try testing.expectEqual(@as(u8, 0b101), try r.take(u8, 3));
    try r.alignToByte();
    try testing.expectEqualStrings("hi", try r.takeBytes(2));
    try testing.expect(r.isAtEnd());

    // Aligning when already on a boundary does nothing.
    try r.alignToByte();
    try testing.expectEqual(@as(usize, 24), r.bitsRead());
}

test "running out of room" {
    var buf: [1]u8 = undefined;
    var w = writer(&buf);
    try w.put(u8, 0, 6);
    try testing.expectEqual(@as(usize, 2), w.remaining());
    try testing.expectError(error.NoSpaceLeft, w.put(u8, 0, 3));
    // A refused write changes nothing.
    try testing.expectEqual(@as(usize, 6), w.bitsWritten());
    try w.put(u8, 3, 2);
    try testing.expect(w.isFull());
    try testing.expectError(error.NoSpaceLeft, w.putBool(true));

    var r = reader(&buf);
    _ = try r.take(u8, 6);
    try testing.expectError(error.UnexpectedEnd, r.take(u8, 3));
    try testing.expectError(error.UnexpectedEnd, r.skip(3));
    _ = try r.take(u8, 2);
    try testing.expectError(error.UnexpectedEnd, r.takeBool());
}

test "the buffer need not arrive zeroed" {
    var buf: [2]u8 = @splat(0xFF);
    var w = writer(&buf);
    try w.put(u8, 0, 4);
    try w.put(u8, 0b1010, 4);
    try testing.expectEqual(@as(u8, 0b0000_1010), buf[0]);

    // And the spare bits of a part-filled last byte are zero too.
    w.reset();
    @memset(&buf, 0xFF);
    try w.put(u8, 0b11, 2);
    try testing.expectEqual(@as(u8, 0b1100_0000), w.written()[0]);
}

test "putZeroes crosses word boundaries" {
    var buf: [16]u8 = undefined;
    var w = writer(&buf);
    try w.putBool(true);
    try w.putZeroes(100);
    try testing.expectEqual(@as(usize, 101), w.bitsWritten());

    var r = reader(w.written());
    try testing.expect(try r.takeBool());
    var i: usize = 0;
    while (i < 100) : (i += 1) try testing.expect(!try r.takeBool());
}
