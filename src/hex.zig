// SPDX-License-Identifier: CC0-1.0

//! Hexadecimal: two characters per byte, and a hex dump for looking at
//! binary with your own eyes.
//!
//! The `encode` / `decode` family mirrors `base64` exactly, down to the option
//! names, so the two are interchangeable wherever a codec is all that is
//! wanted:
//!
//!   * `encode` / `decode`            - into a slice you own, no allocation
//!   * `encodeAlloc` / `decodeAlloc`  - into fresh memory, you free it
//!   * `encodeWriter`                 - straight into a `std.Io.Writer`
//!
//! Encoding picks a case; decoding accepts either. Separators are a matter of
//! options in both directions, so `de:ad:be:ef` survives a round trip.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const sink = @import("sink.zig");

pub const Case = enum {
    lower,
    upper,

    fn digits(self: Case) *const [16]u8 {
        return switch (self) {
            .lower => "0123456789abcdef",
            .upper => "0123456789ABCDEF",
        };
    }
};

/// The value of one hex digit, or null if `char` is not one. Accepts either
/// case.
pub fn digitValue(char: u8) ?u4 {
    return switch (char) {
        '0'...'9' => @intCast(char - '0'),
        'a'...'f' => @intCast(char - 'a' + 10),
        'A'...'F' => @intCast(char - 'A' + 10),
        else => null,
    };
}

/// The character for one hex digit.
pub fn digitChar(value: u4, case: Case) u8 {
    return case.digits()[value];
}

// -------------------------------------------------------------------------
// Encoding
// -------------------------------------------------------------------------

pub const EncodeOptions = struct {
    case: Case = .lower,
    /// Written between every pair of bytes, and nowhere else. `":"` gives
    /// `de:ad:be:ef`, `" "` gives a spaced dump.
    separator: []const u8 = "",
};

pub const EncodeError = error{
    /// The destination slice is smaller than `encodedLen`.
    NoSpaceLeft,
};

/// Exactly how many bytes `encode` writes for `source_len` bytes of input.
pub fn encodedLen(source_len: usize, options: EncodeOptions) usize {
    if (source_len == 0) return 0;
    return source_len * 2 + (source_len - 1) * options.separator.len;
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

/// The one encoding routine. `out` is anything with `writeByte` and
/// `writeAll`: a `sink.Buffer`, a `sink.Counter`, or a `std.Io.Writer`.
fn encodeInto(out: anytype, bytes: []const u8, options: EncodeOptions) !void {
    const digits = options.case.digits();
    for (bytes, 0..) |byte, i| {
        if (i != 0) try out.writeAll(options.separator);
        try out.writeByte(digits[byte >> 4]);
        try out.writeByte(digits[byte & 0x0F]);
    }
}

// -------------------------------------------------------------------------
// Decoding
// -------------------------------------------------------------------------

pub const DecodeOptions = struct {
    /// Skip ASCII whitespace wherever it appears, so text pasted out of a log
    /// or split across lines still reads.
    ignore_whitespace: bool = false,
    /// Every character in this set is skipped as well. Pass `":"` to read
    /// `de:ad:be:ef`, or `":-"` to accept either spelling.
    separators: []const u8 = "",
};

pub const DecodeError = error{
    /// A character that is neither a hex digit nor something to skip.
    InvalidCharacter,
    /// The input held an odd number of hex digits, so the last byte is half
    /// written.
    OddLength,
    /// The destination slice is smaller than `decodedLen`.
    NoSpaceLeft,
};

fn skippable(char: u8, options: DecodeOptions) bool {
    if (options.ignore_whitespace and std.ascii.isWhitespace(char)) return true;
    return std.mem.indexOfScalar(u8, options.separators, char) != null;
}

/// Exactly how many bytes `decode` will write, validating `text` on the way.
/// Fails with the same errors `decode` would.
pub fn decodedLen(text: []const u8, options: DecodeOptions) DecodeError!usize {
    var digits: usize = 0;
    for (text) |char| {
        if (skippable(char, options)) continue;
        if (digitValue(char) == null) return error.InvalidCharacter;
        digits += 1;
    }
    if (digits % 2 != 0) return error.OddLength;
    return digits / 2;
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

/// Decode text of a length known up front - a hash, a UUID, a key - into an
/// array held by value, so there is nothing to allocate and nothing to free.
/// Text that decodes to any other length is `error.OddLength`.
pub fn decodeFixed(
    comptime n: usize,
    text: []const u8,
    options: DecodeOptions,
) DecodeError![n]u8 {
    if (try decodedLen(text, options) != n) return error.OddLength;
    var out: [n]u8 = undefined;
    var buffer: sink.Buffer = .init(&out);
    decodeInto(&buffer, text, options) catch unreachable;
    return out;
}

/// The one decoding routine. `out` is anything with `writeByte` and
/// `writeAll`; see `sink`.
fn decodeInto(out: anytype, text: []const u8, options: DecodeOptions) !void {
    var high: ?u4 = null;
    for (text) |char| {
        if (skippable(char, options)) continue;
        const value = digitValue(char) orelse return error.InvalidCharacter;
        if (high) |h| {
            try out.writeByte(@as(u8, h) << 4 | value);
            high = null;
        } else {
            high = value;
        }
    }
    if (high != null) return error.OddLength;
}

// -------------------------------------------------------------------------
// Dumping
// -------------------------------------------------------------------------

pub const DumpOptions = struct {
    /// Bytes shown per line.
    columns: usize = 16,
    /// The address printed beside the first byte, for when `bytes` is a
    /// window into something larger.
    base_offset: usize = 0,
    /// Show the offset column on the left.
    show_offset: bool = true,
    /// Show the printable-ASCII column on the right.
    show_ascii: bool = true,
    case: Case = .lower,
};

/// Write a hex dump of `bytes` to `w`, one line per `columns` bytes:
///
/// ```
/// 00000000  66 6c 75 78 69 6f 6e 20  65 6e 63 6f 64 69 6e 67  |fluxion encoding|
/// ```
///
/// Every line ends in `\n`, including the last.
pub fn dump(w: *std.Io.Writer, bytes: []const u8, options: DumpOptions) std.Io.Writer.Error!void {
    std.debug.assert(options.columns != 0);
    const digits = options.case.digits();

    var start: usize = 0;
    while (start < bytes.len) : (start += options.columns) {
        const line = bytes[start..@min(start + options.columns, bytes.len)];

        if (options.show_offset) try w.print("{x:0>8}  ", .{options.base_offset + start});

        for (0..options.columns) |i| {
            if (i != 0) try w.writeByte(' ');
            // A wider gap every eight bytes, so the eye can count them.
            if (i != 0 and i % 8 == 0) try w.writeByte(' ');
            if (i < line.len) {
                try w.writeByte(digits[line[i] >> 4]);
                try w.writeByte(digits[line[i] & 0x0F]);
            } else {
                // Blanks, so a short last line keeps the ASCII column aligned.
                try w.writeAll("  ");
            }
        }

        if (options.show_ascii) {
            try w.writeAll("  |");
            for (line) |byte| {
                try w.writeByte(if (std.ascii.isPrint(byte)) byte else '.');
            }
            try w.writeByte('|');
        }
        try w.writeByte('\n');
    }
}

/// A hex dump of `bytes` in memory from `allocator`. Caller owns the result.
pub fn dumpAlloc(
    allocator: Allocator,
    bytes: []const u8,
    options: DumpOptions,
) Allocator.Error![]u8 {
    var allocating: std.Io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();
    dump(&allocating.writer, bytes, options) catch return error.OutOfMemory;
    return allocating.toOwnedSlice();
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "digits" {
    try testing.expectEqual(@as(?u4, 0), digitValue('0'));
    try testing.expectEqual(@as(?u4, 10), digitValue('a'));
    try testing.expectEqual(@as(?u4, 10), digitValue('A'));
    try testing.expectEqual(@as(?u4, 15), digitValue('f'));
    try testing.expectEqual(@as(?u4, null), digitValue('g'));
    try testing.expectEqual(@as(?u4, null), digitValue(' '));

    try testing.expectEqual(@as(u8, 'e'), digitChar(14, .lower));
    try testing.expectEqual(@as(u8, 'E'), digitChar(14, .upper));
}

test "encode and decode" {
    const bytes = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    var buf: [16]u8 = undefined;

    try testing.expectEqualStrings("deadbeef", try encode(&buf, &bytes, .{}));
    try testing.expectEqualStrings("DEADBEEF", try encode(&buf, &bytes, .{ .case = .upper }));

    var back: [4]u8 = undefined;
    try testing.expectEqualSlices(u8, &bytes, try decode(&back, "deadbeef", .{}));
    try testing.expectEqualSlices(u8, &bytes, try decode(&back, "DEADBEEF", .{}));
    // Mixed case is fine on the way in.
    try testing.expectEqualSlices(u8, &bytes, try decode(&back, "DeAdBeEf", .{}));
}

test "empty input" {
    var buf: [4]u8 = undefined;
    try testing.expectEqualStrings("", try encode(&buf, "", .{}));
    try testing.expectEqual(@as(usize, 0), encodedLen(0, .{ .separator = ":" }));
    try testing.expectEqualSlices(u8, &.{}, try decode(&buf, "", .{}));
}

test "separators go both ways" {
    const bytes = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    var buf: [16]u8 = undefined;
    const spaced = try encode(&buf, &bytes, .{ .separator = ":" });
    try testing.expectEqualStrings("de:ad:be:ef", spaced);
    try testing.expectEqual(encodedLen(bytes.len, .{ .separator = ":" }), spaced.len);

    var back: [4]u8 = undefined;
    try testing.expectError(error.InvalidCharacter, decode(&back, spaced, .{}));
    try testing.expectEqualSlices(
        u8,
        &bytes,
        try decode(&back, spaced, .{ .separators = ":" }),
    );
}

test "whitespace" {
    var buf: [4]u8 = undefined;
    try testing.expectError(error.InvalidCharacter, decode(&buf, "de ad\nbe ef", .{}));
    try testing.expectEqualSlices(
        u8,
        &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF },
        try decode(&buf, "de ad\nbe ef", .{ .ignore_whitespace = true }),
    );
}

test "malformed input" {
    var buf: [8]u8 = undefined;
    try testing.expectError(error.OddLength, decode(&buf, "abc", .{}));
    try testing.expectError(error.InvalidCharacter, decode(&buf, "abzz", .{}));
    try testing.expectError(error.NoSpaceLeft, decode(buf[0..1], "abcd", .{}));
    try testing.expectError(error.NoSpaceLeft, encode(buf[0..3], "ab", .{}));
}

test "round trip over every byte value" {
    var source: [256]u8 = undefined;
    for (&source, 0..) |*b, i| b.* = @intCast(i);

    const encoded = try encodeAlloc(testing.allocator, &source, .{ .case = .upper });
    defer testing.allocator.free(encoded);
    try testing.expectEqual(@as(usize, 512), encoded.len);

    const decoded = try decodeAlloc(testing.allocator, encoded, .{});
    defer testing.allocator.free(decoded);
    try testing.expectEqualSlices(u8, &source, decoded);
}

test "decodeFixed" {
    const key = try decodeFixed(4, "deadbeef", .{});
    try testing.expectEqual([4]u8{ 0xDE, 0xAD, 0xBE, 0xEF }, key);
    // The result is a value, so it can be compared and copied like one.
    try testing.expect(std.meta.eql(key, try decodeFixed(4, "DEADBEEF", .{})));

    try testing.expectError(error.OddLength, decodeFixed(4, "deadbe", .{}));
    try testing.expectError(error.OddLength, decodeFixed(4, "deadbeef00", .{}));
    try testing.expectError(error.InvalidCharacter, decodeFixed(4, "deadbeez", .{}));
}

test "isValid" {
    try testing.expect(isValid("deadbeef", .{}));
    try testing.expect(isValid("", .{}));
    try testing.expect(!isValid("deadbee", .{}));
    try testing.expect(!isValid("de:ad", .{}));
    try testing.expect(isValid("de:ad", .{ .separators = ":" }));
}

test "encodeWriter matches encode" {
    var out: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    try encodeWriter(&w, "hello", .{ .separator = " " });

    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings(try encode(&buf, "hello", .{ .separator = " " }), w.buffered());
}

test "dump" {
    const dumped = try dumpAlloc(testing.allocator, "fluxion encoding\n", .{});
    defer testing.allocator.free(dumped);
    try testing.expectEqualStrings(
        "00000000  66 6c 75 78 69 6f 6e 20  65 6e 63 6f 64 69 6e 67  |fluxion encoding|\n" ++
            "00000010  0a                                                |.|\n",
        dumped,
    );
}

test "dump options" {
    const bytes = [_]u8{ 0x00, 0x7F, 0x80, 0xFF };

    const narrow = try dumpAlloc(testing.allocator, &bytes, .{
        .columns = 4,
        .base_offset = 0x1000,
        .case = .upper,
    });
    defer testing.allocator.free(narrow);
    try testing.expectEqualStrings("00001000  00 7F 80 FF  |....|\n", narrow);

    const bare = try dumpAlloc(testing.allocator, &bytes, .{
        .columns = 4,
        .show_offset = false,
        .show_ascii = false,
    });
    defer testing.allocator.free(bare);
    try testing.expectEqualStrings("00 7f 80 ff\n", bare);

    const empty = try dumpAlloc(testing.allocator, "", .{});
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("", empty);
}
