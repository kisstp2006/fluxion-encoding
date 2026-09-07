// SPDX-License-Identifier: CC0-1.0

//! A 128-bit identifier, and the text it is usually written as.
//!
//! Every asset pipeline needs a name for a thing that survives the thing being
//! renamed, moved, or edited. Sixteen bytes is that name: it fits in a
//! register pair, compares in two instructions, sorts, hashes, and reads back
//! out as `f81d4fae-7dec-11d0-a765-00a0c91e6bf6` when a human has to look at
//! it.
//!
//! `random` gives a fresh one. `fromName` gives the *same* one every time for
//! the same namespace and text, which is what turns an asset path into a
//! stable id without a database to remember it.
//!
//! The bytes are stored in the order they are written, so a `Uuid` can be
//! memcpy'd into a file and read back on any machine. It is a value: copy it,
//! compare it with `std.meta.eql`, use it as a `std.AutoHashMap` key.

const std = @import("std");
const testing = std.testing;

const hex = @import("hex.zig");

const Uuid = @This();

/// Big-endian, as RFC 9562 lays them out: the text form reads straight off.
bytes: [16]u8,

pub const nil: Uuid = .{ .bytes = @splat(0) };
pub const max: Uuid = .{ .bytes = @splat(0xFF) };

/// The length of the canonical text form, `8-4-4-4-12`.
pub const string_len: usize = 36;

/// Where the dashes go in the canonical form.
const dash_positions = [_]usize{ 8, 13, 18, 23 };

pub const ParseError = error{
    /// A character that is neither a hex digit nor punctuation in a place
    /// punctuation may go.
    InvalidCharacter,
    /// The text did not hold exactly 32 hex digits.
    InvalidLength,
};

// -------------------------------------------------------------------------
// Making one
// -------------------------------------------------------------------------

/// Take sixteen bytes as they are, with no version or variant bits set. For
/// an id that came from somewhere else and means something already.
pub fn fromBytes(bytes: [16]u8) Uuid {
    return .{ .bytes = bytes };
}

/// The bits of a `u128`, most significant first.
pub fn fromInt(value: u128) Uuid {
    var self: Uuid = undefined;
    std.mem.writeInt(u128, &self.bytes, value, .big);
    return self;
}

pub fn toInt(self: Uuid) u128 {
    return std.mem.readInt(u128, &self.bytes, .big);
}

/// A fresh random id, version 4. Pass `std.crypto.random` for one nobody can
/// guess, or a seeded `std.Random` when a build has to be reproducible.
pub fn random(rng: std.Random) Uuid {
    var self: Uuid = undefined;
    rng.bytes(&self.bytes);
    self.stamp(4);
    return self;
}

/// The same id every time for the same `namespace` and `name`, version 5.
///
/// This is the one an asset pipeline wants: hand it a path and it hands back
/// an id that will still be the same next build, on another machine, without
/// anything having been written down.
///
/// ```zig
/// // Mint one of these once, with `random`, and keep it as a constant.
/// const assets = Uuid.parseComptime("2f8a1c40-6d3e-4b17-9f22-c1a5e7b90d34");
/// const cursor = Uuid.fromName(assets, "textures/ui/cursor.png");
/// ```
pub fn fromName(namespace: Uuid, name: []const u8) Uuid {
    var sha1: std.crypto.hash.Sha1 = .init(.{});
    sha1.update(&namespace.bytes);
    sha1.update(name);

    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    sha1.final(&digest);

    var self: Uuid = undefined;
    @memcpy(&self.bytes, digest[0..16]);
    self.stamp(5);
    return self;
}

/// Overwrite the version and variant bits, which RFC 9562 reserves.
fn stamp(self: *Uuid, comptime version_number: u4) void {
    self.bytes[6] = (self.bytes[6] & 0x0F) | (@as(u8, version_number) << 4);
    self.bytes[8] = (self.bytes[8] & 0x3F) | 0x80;
}

/// The namespaces RFC 9562 defines, for `fromName`. A project that is not
/// naming DNS names or URLs should mint its own with `random` and keep it as
/// a constant.
pub const namespaces = struct {
    pub const dns = parseComptime("6ba7b810-9dad-11d1-80b4-00c04fd430c8");
    pub const url = parseComptime("6ba7b811-9dad-11d1-80b4-00c04fd430c8");
    pub const oid = parseComptime("6ba7b812-9dad-11d1-80b4-00c04fd430c8");
    pub const x500 = parseComptime("6ba7b814-9dad-11d1-80b4-00c04fd430c8");
};

/// Parse at compile time, so a malformed literal is a compile error rather
/// than something to handle at runtime.
pub fn parseComptime(comptime text: []const u8) Uuid {
    const parsed = comptime blk: {
        break :blk parse(text) catch
            @compileError("fluxion-encoding: not a uuid: " ++ text);
    };
    return parsed;
}

// -------------------------------------------------------------------------
// Text
// -------------------------------------------------------------------------

/// Read the canonical `8-4-4-4-12` form.
///
/// Dashes may be anywhere or nowhere, surrounding braces are allowed, and
/// either case reads: all of `f81d4fae-7dec-11d0-a765-00a0c91e6bf6`,
/// `F81D4FAE7DEC11D0A76500A0C91E6BF6` and `{f81d4fae-...}` are the same id.
/// What is not allowed is anything that is not a hex digit, a dash or a brace.
pub fn parse(text: []const u8) ParseError!Uuid {
    var body = text;
    if (body.len >= 2 and body[0] == '{' and body[body.len - 1] == '}') {
        body = body[1 .. body.len - 1];
    }

    const options: hex.DecodeOptions = .{ .separators = "-" };
    const digits = hex.decodedLen(body, options) catch |err| return switch (err) {
        error.InvalidCharacter => error.InvalidCharacter,
        error.OddLength => error.InvalidLength,
        error.NoSpaceLeft => unreachable,
    };
    if (digits != 16) return error.InvalidLength;

    return .{ .bytes = hex.decodeFixed(16, body, options) catch unreachable };
}

/// The canonical form, held by value: nothing to allocate and nothing to free.
pub fn toString(self: Uuid) [string_len]u8 {
    return self.toStringCase(.lower);
}

pub fn toStringCase(self: Uuid, case: hex.Case) [string_len]u8 {
    var out: [string_len]u8 = undefined;
    var digit: usize = 0;
    var i: usize = 0;
    while (i < string_len) : (i += 1) {
        if (std.mem.indexOfScalar(usize, &dash_positions, i) != null) {
            out[i] = '-';
            continue;
        }
        const byte = self.bytes[digit / 2];
        const nibble: u4 = @intCast(if (digit % 2 == 0) byte >> 4 else byte & 0x0F);
        out[i] = hex.digitChar(nibble, case);
        digit += 1;
    }
    return out;
}

/// Print with `{f}`, in the canonical lowercase form.
pub fn format(self: Uuid, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(&self.toString());
}

// -------------------------------------------------------------------------
// Reading one
// -------------------------------------------------------------------------

/// The version digit, for an id that follows RFC 9562: 4 for `random`, 5 for
/// `fromName`. Meaningless for one made with `fromBytes`.
pub fn version(self: Uuid) u4 {
    return @intCast(self.bytes[6] >> 4);
}

pub fn isNil(self: Uuid) bool {
    return self.eql(nil);
}

pub fn eql(self: Uuid, other: Uuid) bool {
    return std.mem.eql(u8, &self.bytes, &other.bytes);
}

/// Byte order, which for these bytes is also numeric order.
pub fn order(self: Uuid, other: Uuid) std.math.Order {
    return std.mem.order(u8, &self.bytes, &other.bytes);
}

pub fn lessThan(self: Uuid, other: Uuid) bool {
    return self.order(other) == .lt;
}

pub fn hash(self: Uuid) u64 {
    return std.hash.Wyhash.hash(0, &self.bytes);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const sample_text = "f81d4fae-7dec-11d0-a765-00a0c91e6bf6";
const sample_bytes = [16]u8{
    0xF8, 0x1D, 0x4F, 0xAE, 0x7D, 0xEC, 0x11, 0xD0,
    0xA7, 0x65, 0x00, 0xA0, 0xC9, 0x1E, 0x6B, 0xF6,
};

test "parse and print the canonical form" {
    const id = try parse(sample_text);
    try testing.expectEqualSlices(u8, &sample_bytes, &id.bytes);
    try testing.expectEqualStrings(sample_text, &id.toString());
    try testing.expectFmt(sample_text, "{f}", .{id});
}

test "parse is forgiving about punctuation and case" {
    const id = try parse(sample_text);
    const spellings = [_][]const u8{
        sample_text,
        "F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6",
        "f81d4fae7dec11d0a76500a0c91e6bf6",
        "{f81d4fae-7dec-11d0-a765-00a0c91e6bf6}",
        "{F81D4FAE7DEC11D0A76500A0C91E6BF6}",
        "f8-1d-4f-ae-7d-ec-11-d0-a7-65-00-a0-c9-1e-6b-f6",
    };
    for (spellings) |text| {
        try testing.expect(id.eql(try parse(text)));
    }
    // But printing always gives the one spelling back.
    try testing.expectEqualStrings(sample_text, &(try parse(spellings[1])).toString());
    try testing.expectEqualStrings(
        "F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6",
        &id.toStringCase(.upper),
    );
}

test "malformed text" {
    try testing.expectError(error.InvalidLength, parse(""));
    try testing.expectError(error.InvalidLength, parse("f81d4fae"));
    try testing.expectError(error.InvalidLength, parse(sample_text ++ "00"));
    try testing.expectError(error.InvalidLength, parse("f81d4fae-7dec-11d0-a765-00a0c91e6bf"));
    try testing.expectError(error.InvalidCharacter, parse("g81d4fae-7dec-11d0-a765-00a0c91e6bf6"));
    try testing.expectError(error.InvalidCharacter, parse("f81d4fae 7dec 11d0 a765 00a0c91e6bf6"));
}

test "nil and max" {
    try testing.expect(nil.isNil());
    try testing.expectEqualStrings("00000000-0000-0000-0000-000000000000", &nil.toString());
    try testing.expectEqualStrings("ffffffff-ffff-ffff-ffff-ffffffffffff", &max.toString());
    try testing.expect((try parse("00000000-0000-0000-0000-000000000000")).isNil());
    try testing.expect(!(try parse(sample_text)).isNil());
}

test "round trip through bytes and integers" {
    const id = try parse(sample_text);
    try testing.expect(id.eql(fromBytes(id.bytes)));
    try testing.expect(id.eql(fromInt(id.toInt())));
    try testing.expectEqual(@as(u128, 0xF81D4FAE7DEC11D0A76500A0C91E6BF6), id.toInt());

    // The stored order is the printed order, so a memcpy to disk reads back.
    try testing.expectEqual(@as(u8, 0xF8), id.bytes[0]);
}

test "random ids are version 4 and distinct" {
    var prng: std.Random.DefaultPrng = .init(0x5EED);
    const rng = prng.random();

    var seen: std.AutoHashMapUnmanaged(Uuid, void) = .empty;
    defer seen.deinit(testing.allocator);

    for (0..1000) |_| {
        const id = random(rng);
        try testing.expectEqual(@as(u4, 4), id.version());
        // The variant bits are stamped too.
        try testing.expectEqual(@as(u8, 0x80), id.bytes[8] & 0xC0);
        try testing.expect(!id.isNil());
        try seen.put(testing.allocator, id, {});
    }
    try testing.expectEqual(@as(usize, 1000), seen.count());
}

test "fromName gives the same id every time" {
    // A namespace of this project's own, not one of the RFC's.
    const assets = parseComptime("2f8a1c40-6d3e-4b17-9f22-c1a5e7b90d34");
    const cursor = fromName(assets, "textures/ui/cursor.png");

    try testing.expect(cursor.eql(fromName(assets, "textures/ui/cursor.png")));
    try testing.expectEqual(@as(u4, 5), cursor.version());
    try testing.expectEqual(@as(u8, 0x80), cursor.bytes[8] & 0xC0);

    // A different name, or the same name in a different namespace, is a
    // different id.
    try testing.expect(!cursor.eql(fromName(assets, "textures/ui/cursor2.png")));
    try testing.expect(!cursor.eql(fromName(namespaces.dns, "textures/ui/cursor.png")));
}

test "fromName matches the RFC's own example" {
    // RFC 9562 appendix: the DNS namespace over "www.example.com".
    const id = fromName(namespaces.dns, "www.example.com");
    try testing.expectEqualStrings("2ed6657d-e927-568b-95e1-2665a8aea6a2", &id.toString());
}

test "namespaces are parsed at compile time" {
    try testing.expectEqualStrings(
        "6ba7b810-9dad-11d1-80b4-00c04fd430c8",
        &namespaces.dns.toString(),
    );
    const mine = parseComptime(sample_text);
    try testing.expect(mine.eql(try parse(sample_text)));
}

test "ordering and hashing" {
    const a = try parse("00000000-0000-0000-0000-000000000001");
    const b = try parse("00000000-0000-0000-0000-000000000002");

    try testing.expect(a.lessThan(b));
    try testing.expect(!b.lessThan(a));
    try testing.expectEqual(std.math.Order.lt, a.order(b));
    try testing.expectEqual(std.math.Order.eq, a.order(a));
    try testing.expectEqual(a.hash(), (try parse("00000000-0000-0000-0000-000000000001")).hash());

    // Byte order is numeric order, so sorting ids sorts their values.
    var ids = [_]Uuid{ b, nil, a, max };
    std.mem.sort(Uuid, &ids, {}, struct {
        fn lt(_: void, x: Uuid, y: Uuid) bool {
            return x.lessThan(y);
        }
    }.lt);
    try testing.expect(ids[0].isNil());
    try testing.expect(ids[1].eql(a));
    try testing.expect(ids[2].eql(b));
    try testing.expect(ids[3].eql(max));
}

test "works as a value and as a map key" {
    var map: std.AutoHashMapUnmanaged(Uuid, u32) = .empty;
    defer map.deinit(testing.allocator);

    const id = try parse(sample_text);
    try map.put(testing.allocator, id, 7);
    // The same id arrived at a different way must hit the same slot.
    try testing.expectEqual(@as(?u32, 7), map.get(try parse("F81D4FAE7DEC11D0A76500A0C91E6BF6")));
    try testing.expect(std.meta.eql(id, fromBytes(sample_bytes)));

    // It copies like an integer, so a copy is independent.
    var copy = id;
    copy.bytes[0] = 0;
    try testing.expectEqual(@as(u8, 0xF8), id.bytes[0]);
}
