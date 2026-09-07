// SPDX-License-Identifier: CC0-1.0

//! Byte order: reading and writing fixed-width values in whichever one the
//! format on the other side happens to use.
//!
//! Three ways in, from smallest to largest:
//!
//!   * `read` / `write`        one value at a known place in a buffer
//!   * `Reader` / `Writer`     a cursor that walks a buffer field by field
//!   * `Big` / `Little`        a struct field that carries its own byte order
//!
//! Integers, floats and `bool` all go through the same calls. Widths are
//! whatever the type says: `u24` occupies three bytes, not four, so bit-packed
//! formats map straight onto Zig types.
//!
//! `Reader` borrows its vocabulary from a text parser on purpose - `peek`,
//! `take`, `expect`, `save`, `restore` - because walking a binary header is
//! the same job as walking a line of text.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const varint = @import("varint.zig");

/// Re-exported so callers need not reach into `std.builtin` for it.
pub const Endian = std.builtin.Endian;

/// The byte order of the machine this was compiled for.
pub const native: Endian = builtin.cpu.arch.endian();

/// The one that is not `order`.
pub fn opposite(order: Endian) Endian {
    return switch (order) {
        .little => .big,
        .big => .little,
    };
}

pub const ReadError = error{
    /// The input ran out before the value did.
    UnexpectedEnd,
};

pub const ExpectError = ReadError || error{
    /// The bytes were there, but not the ones that were expected.
    UnexpectedValue,
};

pub const WriteError = error{
    /// The destination has no room left for the value.
    NoSpaceLeft,
};

// -------------------------------------------------------------------------
// Types on the wire
// -------------------------------------------------------------------------

/// How many bytes `T` occupies on the wire.
///
/// A `bool` is one byte. An integer or float is exactly as wide as its bits
/// say, so `u24` is three bytes; a type whose width is not a whole number of
/// bytes is a compile error rather than a silent round-up.
pub fn sizeOf(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .bool => 1,
        .int => |info| @divExact(info.bits, 8),
        .float => |info| @divExact(info.bits, 8),
        else => @compileError("fluxion-encoding: " ++ @typeName(T) ++
            " has no byte-order representation; use an integer, float or bool"),
    };
}

/// The unsigned integer of the same width as `T`, which is what byte order is
/// actually defined over.
fn Bits(comptime T: type) type {
    return std.meta.Int(.unsigned, @as(u16, @intCast(sizeOf(T) * 8)));
}

fn toBits(comptime T: type, value: T) Bits(T) {
    return switch (@typeInfo(T)) {
        .bool => @intFromBool(value),
        .int => @bitCast(value),
        .float => @bitCast(value),
        else => unreachable,
    };
}

fn fromBits(comptime T: type, bits: Bits(T)) T {
    return switch (@typeInfo(T)) {
        .bool => bits != 0,
        .int => @bitCast(bits),
        .float => @bitCast(bits),
        else => unreachable,
    };
}

/// `value` with its bytes reversed. Works on floats as well as integers,
/// which `@byteSwap` alone does not.
pub fn swap(value: anytype) @TypeOf(value) {
    const T = @TypeOf(value);
    return fromBits(T, @byteSwap(toBits(T, value)));
}

/// Reinterpret a native-order `value` as `target` order.
pub fn nativeTo(comptime T: type, value: T, target: Endian) T {
    return if (target == native) value else swap(value);
}

/// Reinterpret a `source`-order `value` as native order. The same operation as
/// `nativeTo`, named for the direction you are thinking in.
pub fn toNative(comptime T: type, value: T, source: Endian) T {
    return if (source == native) value else swap(value);
}

/// Reverse the bytes of every element of `values` in place, for when a whole
/// array arrives in the wrong order.
pub fn swapSlice(comptime T: type, values: []T) void {
    for (values) |*value| value.* = swap(value.*);
}

// -------------------------------------------------------------------------
// One value at a time
// -------------------------------------------------------------------------

/// Read a `T` from exactly the bytes it occupies.
pub fn read(comptime T: type, bytes: *const [sizeOf(T)]u8, order: Endian) T {
    return fromBits(T, std.mem.readInt(Bits(T), bytes, order));
}

/// Write a `T` into exactly the bytes it occupies.
pub fn write(comptime T: type, out: *[sizeOf(T)]u8, value: T, order: Endian) void {
    std.mem.writeInt(Bits(T), out, toBits(T, value), order);
}

/// Read a `T` that starts at `offset`, checking that it fits.
pub fn readAt(
    comptime T: type,
    bytes: []const u8,
    offset: usize,
    order: Endian,
) ReadError!T {
    const size = comptime sizeOf(T);
    if (offset > bytes.len or bytes.len - offset < size) return error.UnexpectedEnd;
    return read(T, bytes[offset..][0..size], order);
}

/// Write a `T` starting at `offset`, checking that it fits.
pub fn writeAt(
    comptime T: type,
    out: []u8,
    offset: usize,
    value: T,
    order: Endian,
) WriteError!void {
    const size = comptime sizeOf(T);
    if (offset > out.len or out.len - offset < size) return error.NoSpaceLeft;
    write(T, out[offset..][0..size], value, order);
}

// -------------------------------------------------------------------------
// Fields that carry their own byte order
// -------------------------------------------------------------------------

/// A `T` stored as raw bytes in a known order, so a header can be described as
/// a struct and mapped straight onto the bytes of a file:
///
/// ```zig
/// const Header = extern struct {
///     magic: endian.Big(u32),
///     version: endian.Big(u16),
///     flags: endian.Big(u16),
/// };
/// ```
///
/// The stored form is a byte array, so the struct has no padding and no
/// alignment of its own, and `get` converts only when the host disagrees with
/// the field.
pub fn Field(comptime T: type, comptime order: Endian) type {
    return extern struct {
        const Self = @This();

        /// The wire form. Read it through `get`, not directly.
        bytes: [sizeOf(T)]u8,

        pub const Value = T;
        pub const byte_order = order;

        pub fn init(value: T) Self {
            var self: Self = undefined;
            self.set(value);
            return self;
        }

        pub fn get(self: Self) T {
            return read(T, &self.bytes, order);
        }

        pub fn set(self: *Self, value: T) void {
            write(T, &self.bytes, value, order);
        }

        /// Print with `{f}`; shows the value, not the bytes.
        pub fn format(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.print("{any}", .{self.get()});
        }
    };
}

/// A big-endian `T`. See `Field`.
pub fn Big(comptime T: type) type {
    return Field(T, .big);
}

/// A little-endian `T`. See `Field`.
pub fn Little(comptime T: type) type {
    return Field(T, .little);
}

// -------------------------------------------------------------------------
// Reader
// -------------------------------------------------------------------------

/// A cursor over a byte slice, with a byte order attached.
///
/// Everything it hands back is either a value or a slice into the original
/// input; it never allocates and never copies. `save` and `restore` let you
/// try a reading and back out of it.
pub const Reader = struct {
    bytes: []const u8,
    /// Offset of the next byte to be read.
    index: usize,
    /// The order `take` and `peek` use when no other is given.
    order: Endian,

    /// An opaque cursor position, produced by `save` and consumed by
    /// `restore`.
    pub const Mark = usize;

    pub fn init(bytes: []const u8, order: Endian) Reader {
        return .{ .bytes = bytes, .index = 0, .order = order };
    }

    // ---------------------------------------------------------------------
    // Position
    // ---------------------------------------------------------------------

    pub fn isAtEnd(self: *const Reader) bool {
        return self.index >= self.bytes.len;
    }

    /// Bytes not yet read.
    pub fn remaining(self: *const Reader) usize {
        return self.bytes.len - self.index;
    }

    /// The bytes not yet read.
    pub fn rest(self: *const Reader) []const u8 {
        return self.bytes[self.index..];
    }

    pub fn save(self: *const Reader) Mark {
        return self.index;
    }

    pub fn restore(self: *Reader, mark: Mark) void {
        std.debug.assert(mark <= self.bytes.len);
        self.index = mark;
    }

    pub fn reset(self: *Reader) void {
        self.index = 0;
    }

    pub fn seek(self: *Reader, index: usize) ReadError!void {
        if (index > self.bytes.len) return error.UnexpectedEnd;
        self.index = index;
    }

    pub fn skip(self: *Reader, n: usize) ReadError!void {
        if (self.remaining() < n) return error.UnexpectedEnd;
        self.index += n;
    }

    /// Skip forward to the next multiple of `alignment`, as a format with
    /// padded records needs between one record and the next.
    pub fn skipToAlignment(self: *Reader, alignment: usize) ReadError!void {
        std.debug.assert(alignment != 0);
        const misaligned = self.index % alignment;
        if (misaligned != 0) try self.skip(alignment - misaligned);
    }

    // ---------------------------------------------------------------------
    // Reading
    // ---------------------------------------------------------------------

    /// Read a `T` and advance past it.
    pub fn take(self: *Reader, comptime T: type) ReadError!T {
        return self.takeIn(T, self.order);
    }

    /// Read a `T` in an order of its own, for the one field in a format that
    /// disagrees with the rest of it.
    pub fn takeIn(self: *Reader, comptime T: type, order: Endian) ReadError!T {
        const size = comptime sizeOf(T);
        if (self.remaining() < size) return error.UnexpectedEnd;
        const value = read(T, self.bytes[self.index..][0..size], order);
        self.index += size;
        return value;
    }

    /// Read a `T` without advancing.
    pub fn peek(self: *const Reader, comptime T: type) ReadError!T {
        const size = comptime sizeOf(T);
        if (self.remaining() < size) return error.UnexpectedEnd;
        return read(T, self.bytes[self.index..][0..size], self.order);
    }

    /// Read `n` bytes as they are, and advance past them. The result is a
    /// slice into the input, so it lives exactly as long as the input does.
    pub fn takeBytes(self: *Reader, n: usize) ReadError![]const u8 {
        if (self.remaining() < n) return error.UnexpectedEnd;
        defer self.index += n;
        return self.bytes[self.index..][0..n];
    }

    /// The same, with the length known at compile time, so the result is an
    /// array pointer rather than a slice.
    pub fn takeArray(self: *Reader, comptime n: usize) ReadError!*const [n]u8 {
        if (self.remaining() < n) return error.UnexpectedEnd;
        defer self.index += n;
        return self.bytes[self.index..][0..n];
    }

    /// Fill `dest` with consecutive `T` values.
    pub fn takeInto(self: *Reader, comptime T: type, dest: []T) ReadError!void {
        if (self.remaining() < sizeOf(T) * dest.len) return error.UnexpectedEnd;
        for (dest) |*slot| slot.* = try self.take(T);
    }

    /// Read a variable-length `T`, where a small number costs one byte. See
    /// `varint`; byte order does not come into it.
    pub fn takeVarint(self: *Reader, comptime T: type) varint.ReadError!T {
        const decoded = try varint.decode(T, self.rest());
        self.index += decoded.len;
        return decoded.value;
    }

    /// Read a `T` and require it to equal `wanted`, for a version field or a
    /// magic number. The cursor advances either way.
    pub fn expect(self: *Reader, comptime T: type, wanted: T) ExpectError!void {
        const found = try self.take(T);
        if (found != wanted) return error.UnexpectedValue;
    }

    /// Read and require a literal run of bytes, for a magic number that is
    /// really a string.
    pub fn expectBytes(self: *Reader, wanted: []const u8) ExpectError!void {
        const found = try self.takeBytes(wanted.len);
        if (!std.mem.eql(u8, found, wanted)) return error.UnexpectedValue;
    }
};

/// Shorthand for `Reader.init`.
pub fn reader(bytes: []const u8, order: Endian) Reader {
    return .init(bytes, order);
}

// -------------------------------------------------------------------------
// Writer
// -------------------------------------------------------------------------

/// The mirror of `Reader`: fixed-width values into a buffer you own.
///
/// This is not a `std.Io.Writer`. It writes binary fields into a slice of a
/// known size and stops at the end of it, which is what a packet or a file
/// header wants.
pub const Writer = struct {
    bytes: []u8,
    /// Offset of the next byte to be written.
    index: usize,
    /// The order `put` uses when no other is given.
    order: Endian,

    pub fn init(bytes: []u8, order: Endian) Writer {
        return .{ .bytes = bytes, .index = 0, .order = order };
    }

    /// What has been written so far.
    pub fn written(self: *const Writer) []u8 {
        return self.bytes[0..self.index];
    }

    /// Room left.
    pub fn remaining(self: *const Writer) usize {
        return self.bytes.len - self.index;
    }

    pub fn isFull(self: *const Writer) bool {
        return self.index == self.bytes.len;
    }

    pub fn reset(self: *Writer) void {
        self.index = 0;
    }

    /// Write a `T` and advance past it.
    pub fn put(self: *Writer, comptime T: type, value: T) WriteError!void {
        return self.putIn(T, value, self.order);
    }

    /// Write a `T` in an order of its own.
    pub fn putIn(self: *Writer, comptime T: type, value: T, order: Endian) WriteError!void {
        const size = comptime sizeOf(T);
        if (self.remaining() < size) return error.NoSpaceLeft;
        write(T, self.bytes[self.index..][0..size], value, order);
        self.index += size;
    }

    /// Write a variable-length `T`, where a small number costs one byte. See
    /// `varint`; byte order does not come into it.
    pub fn putVarint(self: *Writer, comptime T: type, value: T) WriteError!void {
        self.index += try varint.encode(T, self.bytes[self.index..], value);
    }

    /// Write bytes as they are.
    pub fn putBytes(self: *Writer, bytes: []const u8) WriteError!void {
        if (self.remaining() < bytes.len) return error.NoSpaceLeft;
        @memcpy(self.bytes[self.index..][0..bytes.len], bytes);
        self.index += bytes.len;
    }

    /// Write consecutive `T` values.
    pub fn putSlice(self: *Writer, comptime T: type, values: []const T) WriteError!void {
        if (self.remaining() < sizeOf(T) * values.len) return error.NoSpaceLeft;
        for (values) |value| try self.put(T, value);
    }

    /// Write `n` copies of `filler`.
    pub fn putRepeated(self: *Writer, filler: u8, n: usize) WriteError!void {
        if (self.remaining() < n) return error.NoSpaceLeft;
        @memset(self.bytes[self.index..][0..n], filler);
        self.index += n;
    }

    /// Pad with `filler` up to the next multiple of `alignment`.
    pub fn padToAlignment(self: *Writer, alignment: usize, filler: u8) WriteError!void {
        std.debug.assert(alignment != 0);
        const misaligned = self.index % alignment;
        if (misaligned != 0) try self.putRepeated(filler, alignment - misaligned);
    }
};

/// Shorthand for `Writer.init`.
pub fn writer(bytes: []u8, order: Endian) Writer {
    return .init(bytes, order);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "sizeOf follows the type, not the machine" {
    try testing.expectEqual(@as(usize, 1), sizeOf(bool));
    try testing.expectEqual(@as(usize, 1), sizeOf(u8));
    try testing.expectEqual(@as(usize, 3), sizeOf(u24));
    try testing.expectEqual(@as(usize, 4), sizeOf(i32));
    try testing.expectEqual(@as(usize, 4), sizeOf(f32));
    try testing.expectEqual(@as(usize, 8), sizeOf(f64));
}

test "read and write" {
    const bytes = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    try testing.expectEqual(@as(u32, 0x12345678), read(u32, &bytes, .big));
    try testing.expectEqual(@as(u32, 0x78563412), read(u32, &bytes, .little));

    var out: [4]u8 = undefined;
    write(u32, &out, 0x12345678, .big);
    try testing.expectEqualSlices(u8, &bytes, &out);
    write(u32, &out, 0x78563412, .little);
    try testing.expectEqualSlices(u8, &bytes, &out);
}

test "odd widths occupy exactly their own bytes" {
    const bytes = [_]u8{ 0xAA, 0xBB, 0xCC };
    try testing.expectEqual(@as(u24, 0xAABBCC), read(u24, &bytes, .big));
    try testing.expectEqual(@as(u24, 0xCCBBAA), read(u24, &bytes, .little));
}

test "signed, float and bool" {
    var buf: [8]u8 = undefined;

    write(i16, buf[0..2], -2, .big);
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0xFE }, buf[0..2]);
    try testing.expectEqual(@as(i16, -2), read(i16, buf[0..2], .big));

    write(f32, buf[0..4], 1.0, .big);
    try testing.expectEqualSlices(u8, &.{ 0x3F, 0x80, 0x00, 0x00 }, buf[0..4]);
    try testing.expectEqual(@as(f32, 1.0), read(f32, buf[0..4], .big));

    write(f64, buf[0..8], -0.5, .little);
    try testing.expectEqual(@as(f64, -0.5), read(f64, buf[0..8], .little));

    write(bool, buf[0..1], true, .big);
    try testing.expectEqual(@as(u8, 1), buf[0]);
    try testing.expect(read(bool, buf[0..1], .little));
}

test "swap" {
    try testing.expectEqual(@as(u32, 0x78563412), swap(@as(u32, 0x12345678)));
    try testing.expectEqual(@as(u16, 0x00FF), swap(@as(u16, 0xFF00)));
    // Floats too, which @byteSwap will not take.
    try testing.expectEqual(@as(f32, 1.0), swap(swap(@as(f32, 1.0))));

    var values = [_]u16{ 0x0102, 0x0304 };
    swapSlice(u16, &values);
    try testing.expectEqualSlices(u16, &.{ 0x0201, 0x0403 }, &values);
}

test "nativeTo and toNative round-trip" {
    const value: u32 = 0xDEADBEEF;
    try testing.expectEqual(value, toNative(u32, nativeTo(u32, value, .big), .big));
    try testing.expectEqual(value, toNative(u32, nativeTo(u32, value, .little), .little));
    try testing.expectEqual(value, nativeTo(u32, value, native));
    try testing.expectEqual(opposite(native), if (native == .little) Endian.big else Endian.little);
}

test "readAt and writeAt are bounds-checked" {
    var buf: [6]u8 = @splat(0);
    try writeAt(u32, &buf, 2, 0x11223344, .big);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0x11, 0x22, 0x33, 0x44 }, &buf);
    try testing.expectEqual(@as(u32, 0x11223344), try readAt(u32, &buf, 2, .big));

    try testing.expectError(error.UnexpectedEnd, readAt(u32, &buf, 3, .big));
    try testing.expectError(error.UnexpectedEnd, readAt(u32, &buf, 99, .big));
    try testing.expectError(error.NoSpaceLeft, writeAt(u32, &buf, 3, 0, .big));
}

test "a header described as a struct" {
    const Header = extern struct {
        magic: Big(u32),
        version: Big(u16),
        flags: Little(u16),
    };

    // No padding: the struct is exactly the bytes on the wire.
    try testing.expectEqual(@as(usize, 8), @sizeOf(Header));

    const wire = [_]u8{ 0x89, 'P', 'N', 'G', 0x00, 0x01, 0x02, 0x00 };
    const header: *const Header = @ptrCast(&wire);
    try testing.expectEqual(@as(u32, 0x89504E47), header.magic.get());
    try testing.expectEqual(@as(u16, 1), header.version.get());
    try testing.expectEqual(@as(u16, 2), header.flags.get());

    var built: Header = .{
        .magic = .init(0x89504E47),
        .version = .init(1),
        .flags = .init(2),
    };
    try testing.expectEqualSlices(u8, &wire, std.mem.asBytes(&built));

    built.version.set(3);
    try testing.expectEqual(@as(u16, 3), built.version.get());
    try testing.expectFmt("v3", "v{f}", .{built.version});
}

test "Reader walks a record" {
    const wire = [_]u8{
        'F', 'L', 'U', 'X', // magic
        0x00, 0x02, // version
        0x00, 0x00, 0x00, 0x2A, // count
        0x03, // name length
        'a', 'b', 'c', // name
    };

    var r: Reader = .init(&wire, .big);
    try r.expectBytes("FLUX");
    try testing.expectEqual(@as(u16, 2), try r.take(u16));
    try testing.expectEqual(@as(u32, 42), try r.take(u32));

    const name_len = try r.take(u8);
    try testing.expectEqualStrings("abc", try r.takeBytes(name_len));
    try testing.expect(r.isAtEnd());
    try testing.expectEqual(@as(usize, 0), r.remaining());
}

test "Reader peek, save and restore" {
    const wire = [_]u8{ 0x00, 0x01, 0x00, 0x02 };
    var r: Reader = .init(&wire, .big);

    // Peek does not move, so the same value comes back twice.
    try testing.expectEqual(@as(u16, 1), try r.peek(u16));
    try testing.expectEqual(@as(u16, 1), try r.peek(u16));
    try testing.expectEqual(@as(usize, 0), r.index);

    const mark = r.save();
    try testing.expectEqual(@as(u16, 1), try r.take(u16));
    try testing.expectEqual(@as(u16, 2), try r.take(u16));
    r.restore(mark);
    // The same bytes read the other way round.
    try testing.expectEqual(@as(u32, 0x02000100), try r.takeIn(u32, .little));
}

test "Reader stops at the end" {
    const wire = [_]u8{ 0x01, 0x02, 0x03 };
    var r: Reader = .init(&wire, .little);

    try testing.expectError(error.UnexpectedEnd, r.take(u32));
    // A failed read leaves the cursor where it was.
    try testing.expectEqual(@as(usize, 0), r.index);

    try testing.expectEqual(@as(u16, 0x0201), try r.take(u16));
    try testing.expectError(error.UnexpectedEnd, r.take(u16));
    try testing.expectError(error.UnexpectedEnd, r.takeBytes(2));
    try testing.expectError(error.UnexpectedEnd, r.skip(2));
    try testing.expectError(error.UnexpectedEnd, r.seek(4));
    try testing.expectEqual(@as(u8, 3), try r.take(u8));
}

test "Reader expect reports the mismatch" {
    const wire = [_]u8{ 'F', 'L', 'U', 'X', 0x00, 0x09 };
    var r: Reader = .init(&wire, .big);
    try testing.expectError(error.UnexpectedValue, r.expectBytes("RIFF"));

    r.reset();
    try r.expectBytes("FLUX");
    try testing.expectError(error.UnexpectedValue, r.expect(u16, 1));
}

test "Reader takeInto and alignment" {
    const wire = [_]u8{ 0x00, 0x01, 0x00, 0x02, 0x00, 0x03, 0xFF, 0xFF, 0x00, 0x07 };
    var r: Reader = .init(&wire, .big);

    var samples: [3]u16 = undefined;
    try r.takeInto(u16, &samples);
    try testing.expectEqualSlices(u16, &.{ 1, 2, 3 }, &samples);

    try r.skip(2); // over the 0xFFFF filler
    try testing.expectEqual(@as(u16, 7), try r.take(u16));

    // Alignment skips only when the cursor is not already on a boundary.
    r.reset();
    try r.skip(1);
    try r.skipToAlignment(4);
    try testing.expectEqual(@as(usize, 4), r.index);
    try r.skipToAlignment(4);
    try testing.expectEqual(@as(usize, 4), r.index);
}

test "Writer builds a record the Reader can read back" {
    var buf: [16]u8 = undefined;
    var w: Writer = .init(&buf, .big);

    try w.putBytes("FLUX");
    try w.put(u16, 2);
    try w.put(u32, 42);
    try w.put(u8, 3);
    try w.putBytes("abc");

    var r: Reader = .init(w.written(), .big);
    try r.expectBytes("FLUX");
    try testing.expectEqual(@as(u16, 2), try r.take(u16));
    try testing.expectEqual(@as(u32, 42), try r.take(u32));
    const name_len = try r.take(u8);
    try testing.expectEqualStrings("abc", try r.takeBytes(name_len));
    try testing.expect(r.isAtEnd());
}

test "Writer stops at the end of its buffer" {
    var buf: [4]u8 = undefined;
    var w: Writer = .init(&buf, .little);

    try w.put(u16, 1);
    try testing.expectEqual(@as(usize, 2), w.remaining());
    try testing.expectError(error.NoSpaceLeft, w.put(u32, 1));
    // A refused write changes nothing.
    try testing.expectEqual(@as(usize, 2), w.index);

    try w.put(u16, 2);
    try testing.expect(w.isFull());
    try testing.expectError(error.NoSpaceLeft, w.put(u8, 0));
    try testing.expectEqualSlices(u8, &.{ 1, 0, 2, 0 }, w.written());
}

test "Writer padding and slices" {
    var buf: [16]u8 = undefined;
    var w: Writer = .init(&buf, .big);

    try w.putBytes("ab");
    try w.padToAlignment(4, 0);
    try testing.expectEqual(@as(usize, 4), w.index);
    try w.putSlice(u16, &.{ 1, 2 });
    try w.putRepeated(0xFF, 2);
    try testing.expectEqualSlices(
        u8,
        &.{ 'a', 'b', 0, 0, 0x00, 0x01, 0x00, 0x02, 0xFF, 0xFF },
        w.written(),
    );

    w.reset();
    try testing.expectEqual(@as(usize, 0), w.written().len);
}

test "varints sit among the fixed-width fields" {
    var buf: [16]u8 = undefined;
    var w: Writer = .init(&buf, .big);

    try w.putBytes("FLUX");
    try w.putVarint(u32, 300); // two bytes, not four
    try w.putVarint(i32, -1); // one byte, not four
    try w.put(u16, 7);
    try testing.expectEqual(@as(usize, 9), w.written().len);

    var r: Reader = .init(w.written(), .big);
    try r.expectBytes("FLUX");
    try testing.expectEqual(@as(u32, 300), try r.takeVarint(u32));
    try testing.expectEqual(@as(i32, -1), try r.takeVarint(i32));
    try testing.expectEqual(@as(u16, 7), try r.take(u16));
    try testing.expect(r.isAtEnd());
}

test "a varint that runs off the end" {
    var buf: [1]u8 = undefined;
    var w: Writer = .init(&buf, .big);
    try testing.expectError(error.NoSpaceLeft, w.putVarint(u32, 128));
    try testing.expectEqual(@as(usize, 0), w.index);

    const truncated = [_]u8{0x80};
    var r: Reader = .init(&truncated, .big);
    try testing.expectError(error.UnexpectedEnd, r.takeVarint(u32));
}

test "mixed byte order inside one record" {
    // A real format that changed its mind: a big-endian header over a
    // little-endian payload.
    var buf: [8]u8 = undefined;
    var w: Writer = .init(&buf, .big);
    try w.put(u32, 0x01020304);
    try w.putIn(u32, 0x01020304, .little);

    try testing.expectEqualSlices(
        u8,
        &.{ 0x01, 0x02, 0x03, 0x04, 0x04, 0x03, 0x02, 0x01 },
        w.written(),
    );

    var r: Reader = .init(w.written(), .big);
    try testing.expectEqual(@as(u32, 0x01020304), try r.take(u32));
    try testing.expectEqual(@as(u32, 0x01020304), try r.takeIn(u32, .little));
}
