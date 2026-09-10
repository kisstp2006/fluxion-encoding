// SPDX-License-Identifier: CC0-1.0

//! Internal plumbing: the output sinks the codecs write through.
//!
//! `base64` and `hex` each have one encoding and one decoding routine, written
//! against a sink rather than a destination: a `Buffer` to fill a slice the
//! caller owns, a `Counter` to measure the output without producing it, or a
//! `std.Io.Writer` to stream it. All three answer to `writeByte` and
//! `writeAll`, which is the whole interface a codec needs.
//!
//! Not exported from `root.zig`.

const std = @import("std");
const testing = std.testing;

/// Fills a caller-owned slice, and refuses to write past the end of it.
pub const Buffer = struct {
    out: []u8,
    len: usize = 0,

    pub const Error = error{NoSpaceLeft};

    pub fn init(out: []u8) Buffer {
        return .{ .out = out };
    }

    pub fn writeByte(self: *Buffer, byte: u8) Error!void {
        if (self.len == self.out.len) return error.NoSpaceLeft;
        self.out[self.len] = byte;
        self.len += 1;
    }

    pub fn writeAll(self: *Buffer, bytes: []const u8) Error!void {
        if (self.out.len - self.len < bytes.len) return error.NoSpaceLeft;
        @memcpy(self.out[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    /// The bytes written so far.
    pub fn written(self: *const Buffer) []u8 {
        return self.out[0..self.len];
    }
};

/// Counts what would have been written. Its error set is empty, so a routine
/// driven by a `Counter` cannot fail for want of room.
pub const Counter = struct {
    len: usize = 0,

    pub const Error = error{};

    pub fn writeByte(self: *Counter, byte: u8) Error!void {
        _ = byte;
        self.len += 1;
    }

    pub fn writeAll(self: *Counter, bytes: []const u8) Error!void {
        self.len += bytes.len;
    }
};

test "Buffer stops at the end of its slice" {
    var out: [4]u8 = undefined;
    var b: Buffer = .init(&out);

    try b.writeAll("ab");
    try b.writeByte('c');
    try testing.expectEqualStrings("abc", b.written());

    try testing.expectError(error.NoSpaceLeft, b.writeAll("de"));
    try b.writeByte('d');
    try testing.expectError(error.NoSpaceLeft, b.writeByte('e'));
    try testing.expectEqualStrings("abcd", b.written());
}

test "Counter measures without storing" {
    var c: Counter = .{};
    try c.writeAll("hello");
    try c.writeByte('!');
    try testing.expectEqual(@as(usize, 6), c.len);
}

test "std.Io.Writer answers to the same two calls" {
    // This is what lets the codecs stream: the sink interface is a subset of
    // what std.Io.Writer already provides.
    var out: [8]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    try w.writeAll("hi");
    try w.writeByte('!');
    try testing.expectEqualStrings("hi!", w.buffered());
}
