// SPDX-License-Identifier: CC0-1.0

//! A tour of Fluxion Encoding. Run it with `zig build example`.
//!
//! It builds a small binary record by hand, ships it as text, reads it back,
//! and shows the same bytes three ways along the way.

const std = @import("std");
const Io = std.Io;
const enc = @import("fluxion_encoding");

/// The header of our imaginary format, laid out as the bytes on the wire.
/// An `extern struct` of endian-tagged fields has no padding, so it can be
/// pointed straight at a buffer.
const Header = extern struct {
    magic: enc.Big(u32),
    version: enc.Big(u16),
    flags: enc.Big(u16),
};

const magic_flux: u32 = 0x464C5558; // "FLUX"

/// Write a header and a named payload into `buf`, returning what was used.
fn buildRecord(buf: []u8, name: []const u8, samples: []const u16) ![]u8 {
    var w = enc.write(buf, .big);

    const header: Header = .{
        .magic = .init(magic_flux),
        .version = .init(2),
        .flags = .init(0b0000_0001),
    };
    try w.putBytes(std.mem.asBytes(&header));

    try w.put(u8, @intCast(name.len));
    try w.putBytes(name);
    // Records start on a four-byte boundary, so pad out to one.
    try w.padToAlignment(4, 0);

    try w.put(u16, @intCast(samples.len));
    try w.putSlice(u16, samples);
    return w.written();
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout.interface;

    // --- build ----------------------------------------------------------
    var record_buf: [64]u8 = undefined;
    const record = try buildRecord(&record_buf, "level", &.{ 1, 2, 3 });

    try out.print("--- the record, {d} bytes ---\n", .{record.len});
    try enc.hex.dump(out, record, .{});

    // --- as text --------------------------------------------------------
    const text = try enc.base64.encodeAlloc(gpa, record, .{
        .alphabet = .url_safe,
        .padding = false,
    });
    try out.print("\n--- base64 ---\nurl-safe, unpadded: {s}\n", .{text});

    // The same bytes wrapped the way PEM does it.
    try out.writeAll("PEM-style, 24 to a line:\n");
    try enc.base64.encodeWriter(out, record, .{ .line_length = 24, .line_ending = "\n" });
    try out.writeByte('\n');

    // --- and back -------------------------------------------------------
    const decoded = try enc.base64.decodeAlloc(gpa, text, .{ .alphabet = .url_safe });
    var r = enc.read(decoded, .big);

    const header: *const Header = @ptrCast(try r.takeArray(@sizeOf(Header)));
    if (header.magic.get() != magic_flux) return error.NotAFluxRecord;

    const name = try r.takeBytes(try r.take(u8));
    try r.skipToAlignment(4);

    var samples: [3]u16 = undefined;
    const count = try r.take(u16);
    if (count != samples.len) return error.UnexpectedSampleCount;
    try r.takeInto(u16, &samples);

    try out.print(
        \\
        \\--- read back ---
        \\version  {f}
        \\flags    0b{b:0>8}
        \\name     {s}
        \\samples  {any}
        \\left     {d} bytes
        \\
    , .{ header.version, header.flags.get(), name, samples, r.remaining() });

    // --- hex ------------------------------------------------------------
    var field: [4]u8 = undefined;
    enc.endian.write(u32, &field, 0xDEADBEEF, .big);

    var digits: [16]u8 = undefined;
    try out.print("\n--- hex ---\n0xDEADBEEF big-endian:    {s}\n", .{
        try enc.hex.encode(&digits, &field, .{ .separator = ":" }),
    });

    enc.endian.write(u32, &field, 0xDEADBEEF, .little);
    try out.print("0xDEADBEEF little-endian: {s}\n", .{
        try enc.hex.encode(&digits, &field, .{ .separator = ":" }),
    });

    // Hex decodes into a value, so a key or a hash needs no allocation.
    const key = try enc.hex.decodeFixed(4, "de:ad:be:ef", .{ .separators = ":" });
    try out.print("back again:               {any}\n", .{key});

    try out.flush();
}
