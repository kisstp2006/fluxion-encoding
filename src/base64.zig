// SPDX-License-Identifier: CC0-1.0

//! Base64 as RFC 4648 defines it, in both alphabets.
//!
//! Every routine comes in three shapes, and they all agree with each other:
//!
//!   * `encode` / `decode`            - into a slice you own, no allocation
//!   * `encodeAlloc` / `decodeAlloc`  - into fresh memory, you free it
//!   * `encodeWriter`                 - straight into a `std.Io.Writer`
//!
//! `encodedLen` and `decodedLen` say how much room a call needs, so the
//! no-allocation path never has to guess.
//!
//! Decoding is strict by default: it rejects characters outside the alphabet,
//! misplaced padding, truncated groups, and final characters carrying bits
//! that decoding would throw away. Loosen any of that through `DecodeOptions`
//! when you have to read what someone else wrote.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const sink = @import("sink.zig");

/// Which two characters fill the last slots of the 64-character alphabet.
pub const Alphabet = enum {
    /// RFC 4648 section 4: `+` and `/`. What MIME, PEM and most APIs use.
    standard,
    /// RFC 4648 section 5: `-` and `_`, so the output survives a URL or a
    /// file name untouched.
    url_safe,

    pub fn chars(self: Alphabet) *const [64]u8 {
        return switch (self) {
            .standard => &standard_chars,
            .url_safe => &url_safe_chars,
        };
    }
};

pub const standard_chars: [64]u8 =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".*;
pub const url_safe_chars: [64]u8 =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".*;

/// The character that pads a short final group out to four.
pub const pad_char: u8 = '=';

// -------------------------------------------------------------------------
// Encoding
// -------------------------------------------------------------------------

pub const EncodeOptions = struct {
    alphabet: Alphabet = .standard,
    /// Append `=` until the output length is a multiple of four. Turn this off
    /// for the unpadded form that JWTs and most URL-safe payloads use.
    padding: bool = true,
    /// Break the output into lines of this many characters. `0` keeps it on
    /// one line; MIME uses 76 and PEM uses 64.
    line_length: usize = 0,
    /// What separates those lines. Ignored when `line_length` is `0`, and
    /// never written after the last line.
    line_ending: []const u8 = "\r\n",
};

pub const EncodeError = error{
    /// The destination slice is smaller than `encodedLen`.
    NoSpaceLeft,
};

/// Exactly how many bytes `encode` writes for `source_len` bytes of input.
pub fn encodedLen(source_len: usize, options: EncodeOptions) usize {
    const remainder = source_len % 3;
    var n = source_len / 3 * 4;
    if (remainder != 0) n += if (options.padding) 4 else remainder + 1;
    if (options.line_length != 0 and n != 0) {
        const lines = (n + options.line_length - 1) / options.line_length;
        n += (lines - 1) * options.line_ending.len;
    }
    return n;
}

/// Encode `bytes` into `out`, returning the part of `out` that was written.
pub fn encode(out: []u8, bytes: []const u8, options: EncodeOptions) EncodeError![]u8 {
    var buffer: sink.Buffer = .init(out);
    try encodeInto(&buffer, bytes, options);
    return buffer.written();
}

/// Encode `bytes` into memory from `allocator`. Caller owns the result.
pub fn encodeAlloc(
    allocator: Allocator,
    bytes: []const u8,
    options: EncodeOptions,
) Allocator.Error![]u8 {
    const out = try allocator.alloc(u8, encodedLen(bytes.len, options));
    errdefer allocator.free(out);
    // `out` is exactly the size the encoder asked for, so it cannot run out.
    var buffer: sink.Buffer = .init(out);
    encodeInto(&buffer, bytes, options) catch unreachable;
    std.debug.assert(buffer.len == out.len);
    return out;
}

/// Encode `bytes` straight into `w`, with no intermediate buffer.
pub fn encodeWriter(
    w: *std.Io.Writer,
    bytes: []const u8,
    options: EncodeOptions,
) std.Io.Writer.Error!void {
    return encodeInto(w, bytes, options);
}

/// Emit one character, breaking the line first if this one would not fit.
fn emit(out: anytype, column: *usize, options: EncodeOptions, char: u8) !void {
    if (options.line_length != 0 and column.* == options.line_length) {
        try out.writeAll(options.line_ending);
        column.* = 0;
    }
    try out.writeByte(char);
    column.* += 1;
}

/// The one encoding routine. `out` is anything with `writeByte` and
/// `writeAll`: a `sink.Buffer`, a `sink.Counter`, or a `std.Io.Writer`.
fn encodeInto(out: anytype, bytes: []const u8, options: EncodeOptions) !void {
    const chars = options.alphabet.chars();
    var column: usize = 0;

    var i: usize = 0;
    while (i + 3 <= bytes.len) : (i += 3) {
        const group = @as(u24, bytes[i]) << 16 |
            @as(u24, bytes[i + 1]) << 8 |
            @as(u24, bytes[i + 2]);
        try emit(out, &column, options, chars[group >> 18]);
        try emit(out, &column, options, chars[group >> 12 & 0x3F]);
        try emit(out, &column, options, chars[group >> 6 & 0x3F]);
        try emit(out, &column, options, chars[group & 0x3F]);
    }

    switch (bytes.len - i) {
        0 => {},
        1 => {
            const group = @as(u24, bytes[i]) << 16;
            try emit(out, &column, options, chars[group >> 18]);
            try emit(out, &column, options, chars[group >> 12 & 0x3F]);
            if (options.padding) {
                try emit(out, &column, options, pad_char);
                try emit(out, &column, options, pad_char);
            }
        },
        2 => {
            const group = @as(u24, bytes[i]) << 16 | @as(u24, bytes[i + 1]) << 8;
            try emit(out, &column, options, chars[group >> 18]);
            try emit(out, &column, options, chars[group >> 12 & 0x3F]);
            try emit(out, &column, options, chars[group >> 6 & 0x3F]);
            if (options.padding) try emit(out, &column, options, pad_char);
        },
        else => unreachable,
    }
}

// -------------------------------------------------------------------------
// Decoding
// -------------------------------------------------------------------------

/// What to make of `=` in the input.
pub const PaddingPolicy = enum {
    /// A short final group must be padded out to four characters.
    require,
    /// Padding is accepted but not insisted upon.
    optional,
    /// `=` is never a valid character.
    forbid,
};

pub const DecodeOptions = struct {
    alphabet: Alphabet = .standard,
    padding: PaddingPolicy = .optional,
    /// Skip ASCII whitespace wherever it appears. MIME and PEM wrap their
    /// payload across lines, so anything read out of a file wants this on.
    ignore_whitespace: bool = false,
    /// Reject a final character carrying bits that decoding discards, which is
    /// how one string of bytes ends up with several spellings. `"Zg=="`
    /// decodes to "f"; so would `"Zh=="`, and this rejects it instead.
    canonical: bool = true,
};

pub const DecodeError = error{
    /// A character outside the alphabet that was not padding and not skipped.
    InvalidCharacter,
    /// `=` somewhere it cannot be, missing where `.require` demands it, or
    /// anything at all following a padded group.
    InvalidPadding,
    /// The input ends part-way through a group, leaving bits that cannot make
    /// up a whole byte.
    Truncated,
    /// The final character carries bits that decoding would discard, and
    /// `canonical` is set.
    NonCanonical,
    /// The destination slice is smaller than `decodedLen`.
    NoSpaceLeft,
};

/// Marks a byte that is not in the alphabet. No character can decode to it,
/// since every real six-bit value is below 64.
const invalid: u8 = 0xFF;

fn buildTable(comptime chars: [64]u8) [256]u8 {
    var table: [256]u8 = @splat(invalid);
    for (chars, 0..) |char, value| table[char] = @intCast(value);
    return table;
}

const standard_table = buildTable(standard_chars);
const url_safe_table = buildTable(url_safe_chars);

fn tableFor(alphabet: Alphabet) *const [256]u8 {
    return switch (alphabet) {
        .standard => &standard_table,
        .url_safe => &url_safe_table,
    };
}

/// Exactly how many bytes `decode` will write, validating `text` on the way.
/// Fails with the same errors `decode` would.
pub fn decodedLen(text: []const u8, options: DecodeOptions) DecodeError!usize {
    var counter: sink.Counter = .{};
    try decodeInto(&counter, text, options);
    return counter.len;
}

/// A ceiling on the decoded size that costs nothing to compute, for sizing a
/// scratch buffer up front. `decodedLen` is the exact answer.
pub fn decodedLenUpperBound(text_len: usize) usize {
    return (text_len + 3) / 4 * 3;
}

/// True if `text` decodes cleanly under `options`.
pub fn isValid(text: []const u8, options: DecodeOptions) bool {
    _ = decodedLen(text, options) catch return false;
    return true;
}

/// Decode `text` into `out`, returning the part of `out` that was written.
pub fn decode(out: []u8, text: []const u8, options: DecodeOptions) DecodeError![]u8 {
    var buffer: sink.Buffer = .init(out);
    try decodeInto(&buffer, text, options);
    return buffer.written();
}

/// Decode `text` into memory from `allocator`. Caller owns the result.
pub fn decodeAlloc(
    allocator: Allocator,
    text: []const u8,
    options: DecodeOptions,
) (DecodeError || Allocator.Error)![]u8 {
    const out = try allocator.alloc(u8, try decodedLen(text, options));
    errdefer allocator.free(out);
    var buffer: sink.Buffer = .init(out);
    decodeInto(&buffer, text, options) catch unreachable;
    return out;
}

/// Turn a full or short group of six-bit values into whole bytes.
fn flush(out: anytype, group: [4]u8, count: usize, canonical: bool) !void {
    // The bits of a short group that no output byte will carry.
    const leftover: u8 = switch (count) {
        2 => group[1] & 0x0F,
        3 => group[2] & 0x03,
        else => 0,
    };
    if (canonical and leftover != 0) return error.NonCanonical;

    const bits = @as(u24, group[0]) << 18 |
        @as(u24, group[1]) << 12 |
        @as(u24, if (count > 2) group[2] else 0) << 6 |
        @as(u24, if (count > 3) group[3] else 0);

    try out.writeByte(@truncate(bits >> 16));
    if (count > 2) try out.writeByte(@truncate(bits >> 8));
    if (count > 3) try out.writeByte(@truncate(bits));
}

/// The one decoding routine. `out` is anything with `writeByte` and
/// `writeAll`; see `sink`.
fn decodeInto(out: anytype, text: []const u8, options: DecodeOptions) !void {
    const table = tableFor(options.alphabet);

    var group: [4]u8 = undefined;
    // Characters gathered into the current group, and `=` seen after them.
    var count: usize = 0;
    var pad: usize = 0;
    // Set once a padded group has closed the stream: nothing may follow.
    var closed = false;

    for (text) |char| {
        if (options.ignore_whitespace and std.ascii.isWhitespace(char)) continue;
        if (closed) return error.InvalidPadding;

        if (char == pad_char) {
            if (options.padding == .forbid) return error.InvalidPadding;
            // Fewer than two characters can never have produced a byte, so
            // there is nothing here for padding to round out.
            if (count + pad < 2) return error.InvalidPadding;
            pad += 1;
            if (count + pad == 4) {
                try flush(out, group, count, options.canonical);
                count = 0;
                pad = 0;
                closed = true;
            }
            continue;
        }

        // A character after `=` but still inside the group, as in "Zm=8".
        if (pad != 0) return error.InvalidPadding;

        const value = table[char];
        if (value == invalid) return error.InvalidCharacter;
        group[count] = value;
        count += 1;
        if (count == 4) {
            try flush(out, group, 4, options.canonical);
            count = 0;
        }
    }

    if (count == 0) return;
    if (count == 1) return error.Truncated;
    if (options.padding == .require) return error.InvalidPadding;
    try flush(out, group, count, options.canonical);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

/// The vectors from RFC 4648 section 10.
const rfc_vectors = [_]struct { plain: []const u8, encoded: []const u8 }{
    .{ .plain = "", .encoded = "" },
    .{ .plain = "f", .encoded = "Zg==" },
    .{ .plain = "fo", .encoded = "Zm8=" },
    .{ .plain = "foo", .encoded = "Zm9v" },
    .{ .plain = "foob", .encoded = "Zm9vYg==" },
    .{ .plain = "fooba", .encoded = "Zm9vYmE=" },
    .{ .plain = "foobar", .encoded = "Zm9vYmFy" },
};

test "RFC 4648 test vectors" {
    var buf: [16]u8 = undefined;
    var back: [8]u8 = undefined;
    for (rfc_vectors) |v| {
        try testing.expectEqualStrings(v.encoded, try encode(&buf, v.plain, .{}));
        try testing.expectEqualStrings(v.plain, try decode(&back, v.encoded, .{}));
    }
}

test "encodedLen and decodedLen agree with what happens" {
    var buf: [64]u8 = undefined;
    const option_sets = [_]EncodeOptions{
        .{},
        .{ .padding = false },
        .{ .alphabet = .url_safe },
        .{ .line_length = 8 },
        .{ .line_length = 4, .line_ending = "\n", .padding = false },
    };
    for (option_sets) |options| {
        for (0..24) |len| {
            const source = "the quick brown fox jumps"[0..len];
            const encoded = try encode(&buf, source, options);
            try testing.expectEqual(encodedLen(len, options), encoded.len);

            const decode_options: DecodeOptions = .{
                .alphabet = options.alphabet,
                .ignore_whitespace = true,
            };
            try testing.expectEqual(len, try decodedLen(encoded, decode_options));
            try testing.expect(len <= decodedLenUpperBound(encoded.len));
        }
    }
}

test "round trip over every byte value" {
    var source: [256]u8 = undefined;
    for (&source, 0..) |*b, i| b.* = @intCast(i);

    const encoded = try encodeAlloc(testing.allocator, &source, .{});
    defer testing.allocator.free(encoded);

    const decoded = try decodeAlloc(testing.allocator, encoded, .{});
    defer testing.allocator.free(decoded);

    try testing.expectEqualSlices(u8, &source, decoded);
}

test "the url-safe alphabet avoids + and /" {
    // These two inputs pick out the characters the alphabets disagree on.
    var buf: [8]u8 = undefined;
    const plus = [_]u8{ 0xFB, 0xEF, 0xBE };
    try testing.expectEqualStrings("++++", try encode(&buf, &plus, .{}));
    try testing.expectEqualStrings("----", try encode(&buf, &plus, .{ .alphabet = .url_safe }));

    const slash = [_]u8{ 0xFF, 0xFF, 0xFF };
    try testing.expectEqualStrings("////", try encode(&buf, &slash, .{}));
    try testing.expectEqualStrings("____", try encode(&buf, &slash, .{ .alphabet = .url_safe }));

    // Each alphabet rejects the other's two characters.
    var back: [4]u8 = undefined;
    try testing.expectError(error.InvalidCharacter, decode(&back, "----", .{}));
    try testing.expectError(error.InvalidCharacter, decode(&back, "++++", .{
        .alphabet = .url_safe,
    }));
}

test "unpadded output, as JWTs use" {
    var buf: [8]u8 = undefined;
    const options: EncodeOptions = .{ .alphabet = .url_safe, .padding = false };
    try testing.expectEqualStrings("Zg", try encode(&buf, "f", options));
    try testing.expectEqualStrings("Zm8", try encode(&buf, "fo", options));
    try testing.expectEqualStrings("Zm9v", try encode(&buf, "foo", options));

    var back: [4]u8 = undefined;
    const strict: DecodeOptions = .{ .alphabet = .url_safe, .padding = .forbid };
    try testing.expectEqualStrings("fo", try decode(&back, "Zm8", strict));
    try testing.expectError(error.InvalidPadding, decode(&back, "Zm8=", strict));
}

test "padding policies" {
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("fo", try decode(&buf, "Zm8=", .{ .padding = .require }));
    try testing.expectError(error.InvalidPadding, decode(&buf, "Zm8", .{ .padding = .require }));

    // A group that is already full needs no padding under any policy.
    try testing.expectEqualStrings("foo", try decode(&buf, "Zm9v", .{ .padding = .require }));
    try testing.expectEqualStrings("foo", try decode(&buf, "Zm9v", .{ .padding = .forbid }));
}

test "misplaced padding is rejected" {
    var buf: [16]u8 = undefined;
    const cases = [_][]const u8{
        "=", // nothing to pad
        "====", // still nothing, four times over
        "Z===", // one character can never make a byte
        "Zm9v=", // a full group needs no padding
        "Zg==Zg==", // two payloads glued together
        "Zg==x", // anything at all after a closed group
        "Zm=8", // padding in the middle of a group
    };
    for (cases) |case| {
        try testing.expectError(error.InvalidPadding, decode(&buf, case, .{}));
    }
}

test "truncated and invalid input" {
    var buf: [16]u8 = undefined;
    try testing.expectError(error.Truncated, decode(&buf, "Z", .{}));
    try testing.expectError(error.Truncated, decode(&buf, "Zm9vZ", .{}));
    try testing.expectError(error.InvalidCharacter, decode(&buf, "Zm9 v", .{}));
    try testing.expectError(error.InvalidCharacter, decode(&buf, "Zm9*", .{}));
    try testing.expectError(error.NoSpaceLeft, decode(buf[0..2], "Zm9vYmFy", .{}));
    try testing.expectError(error.NoSpaceLeft, encode(buf[0..3], "foo", .{}));
}

test "non-canonical encodings" {
    var buf: [8]u8 = undefined;
    // "Zg==" and "Zh==" would both decode to "f"; only the first is canonical.
    try testing.expectEqualStrings("f", try decode(&buf, "Zg==", .{}));
    try testing.expectError(error.NonCanonical, decode(&buf, "Zh==", .{}));
    try testing.expectEqualStrings("f", try decode(&buf, "Zh==", .{ .canonical = false }));

    try testing.expectEqualStrings("fo", try decode(&buf, "Zm8=", .{}));
    try testing.expectError(error.NonCanonical, decode(&buf, "Zm9=", .{}));
}

test "whitespace, as MIME and PEM produce it" {
    const wrapped = "Zm9v\r\nYmFy\r\nZm9v\n";
    var buf: [16]u8 = undefined;
    try testing.expectError(error.InvalidCharacter, decode(&buf, wrapped, .{}));
    try testing.expectEqualStrings(
        "foobarfoo",
        try decode(&buf, wrapped, .{ .ignore_whitespace = true }),
    );

    // It may even land inside a group, or in front of the padding.
    try testing.expectEqualStrings(
        "fo",
        try decode(&buf, " Z m 8 = ", .{ .ignore_whitespace = true }),
    );
}

test "line wrapping" {
    var buf: [64]u8 = undefined;
    const wrapped = try encode(&buf, "any carnal pleasure", .{
        .line_length = 8,
        .line_ending = "\n",
    });
    try testing.expectEqualStrings("YW55IGNh\ncm5hbCBw\nbGVhc3Vy\nZQ==", wrapped);

    const decoded = try decodeAlloc(testing.allocator, wrapped, .{ .ignore_whitespace = true });
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings("any carnal pleasure", decoded);

    // No trailing line ending, even when the last line comes out exactly full.
    const exact = try encode(&buf, "foobar", .{ .line_length = 4, .line_ending = "\n" });
    try testing.expectEqualStrings("Zm9v\nYmFy", exact);
}

test "encodeWriter matches encode" {
    var out: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    const options: EncodeOptions = .{ .line_length = 8, .line_ending = "\n" };
    try encodeWriter(&w, "any carnal pleasure", options);

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(
        try encode(&buf, "any carnal pleasure", options),
        w.buffered(),
    );
}

test "isValid" {
    try testing.expect(isValid("Zm9vYmFy", .{}));
    try testing.expect(isValid("", .{}));
    try testing.expect(!isValid("Zm9vYmF", .{}));
    try testing.expect(!isValid("Zm9v YmFy", .{}));
    try testing.expect(isValid("Zm9v YmFy", .{ .ignore_whitespace = true }));
}
