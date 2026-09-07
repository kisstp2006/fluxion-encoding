// SPDX-License-Identifier: CC0-1.0

//! A tour of Fluxion Encoding. Run it with `zig build example`.
//!
//! It builds a small binary record by hand, ships it as text, reads it back,
//! and shows the same bytes several ways along the way. Then it packs an
//! entity update down to the precision each field is actually worth, and
//! unpacks it again.

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

    try sendAPacket(out);
    try out.flush();
}

// -------------------------------------------------------------------------
// An entity update, in as few bits as it will go
// -------------------------------------------------------------------------

/// A namespace of this project's own. Mint one with `Uuid.random` and keep it.
const asset_namespace = enc.Uuid.parseComptime("2f8a1c40-6d3e-4b17-9f22-c1a5e7b90d34");

const Entity = struct {
    id: u32,
    model: enc.Uuid,
    position: [3]f32,
    heading: f32,
    facing: [3]f32,
    rotation: [4]f32,
    health: u8,
    firing: bool,
};

// The precision each field is actually worth, decided once and shared by both
// ends of the wire.
const position = enc.quantize.Range.init(-500, 500, 16);
const heading = enc.quantize.angle(12);
const facing = enc.quantize.normal(10);
const rotation = enc.quantize.rotation(9);

fn sendAPacket(out: *Io.Writer) !void {
    const sent: Entity = .{
        .id = 4211,
        .model = .fromName(asset_namespace, "models/player.glb"),
        .position = .{ 12.5, -300.25, 64.0 },
        .heading = 1.75,
        .facing = .{ 0, 0, 1 },
        .rotation = .{ 0, 0.7071, 0, 0.7071 },
        .health = 87,
        .firing = true,
    };

    var buf: [64]u8 = undefined;

    // The header is byte-shaped: an asset id, then a varint entity id that
    // costs two bytes rather than four.
    var w = enc.write(&buf, .big);
    try w.putBytes(&sent.model.bytes);
    try w.putVarint(u32, sent.id);
    const header_len = w.written().len;

    // Everything after it is bit-shaped.
    var bw = enc.writeBits(buf[header_len..]);
    for (sent.position) |axis| try position.put(&bw, axis);
    try heading.put(&bw, sent.heading);
    try facing.put(&bw, sent.facing);
    try rotation.put(&bw, sent.rotation);
    try bw.put(u8, sent.health, enc.bits.needed(100));
    try bw.putBool(sent.firing);

    const packet = buf[0 .. header_len + bw.written().len];

    // What it cost, against the same fields sent at full width.
    const uncompressed = 16 + 4 + 3 * 4 + 4 + 3 * 4 + 4 * 4 + 1 + 1;
    try out.print(
        \\
        \\--- a packet ---
        \\header   {d} bytes (16 asset id + {d} varint entity id)
        \\payload  {d} bits ({d} bytes)
        \\total    {d} bytes, against {d} sent at full width
        \\
    , .{
        header_len,
        header_len - 16,
        bw.bitsWritten(),
        bw.written().len,
        packet.len,
        uncompressed,
    });
    try enc.hex.dump(out, packet, .{});

    // And the other end reads it back.
    var r = enc.read(packet, .big);
    const model: enc.Uuid = .fromBytes((try r.takeArray(16)).*);
    const id = try r.takeVarint(u32);

    var br = enc.readBits(r.rest());
    var got_position: [3]f32 = undefined;
    for (&got_position) |*axis| axis.* = try position.take(&br);
    const got_heading = try heading.take(&br);
    const got_facing = try facing.take(&br);
    const got_rotation = try rotation.take(&br);
    const got_health = try br.take(u8, enc.bits.needed(100));
    const got_firing = try br.takeBool();

    try out.print(
        \\
        \\entity {d}, model {f}
        \\position {d:.3} {d:.3} {d:.3}  (to within {d:.4})
        \\heading  {d:.4}                  (to within {d:.5})
        \\facing   {d:.3} {d:.3} {d:.3}
        \\rotation {d:.3} {d:.3} {d:.3} {d:.3}
        \\health   {d}, firing {}
        \\
    , .{
        id,
        model,
        got_position[0],
        got_position[1],
        got_position[2],
        position.precision(),
        got_heading,
        heading.precision(),
        got_facing[0],
        got_facing[1],
        got_facing[2],
        got_rotation[0],
        got_rotation[1],
        got_rotation[2],
        got_rotation[3],
        got_health,
        got_firing,
    });

    // The id is derived from the path, so it is the same id every run.
    try out.print(
        "\nmodels/player.glb -> {f}\n",
        .{enc.Uuid.fromName(asset_namespace, "models/player.glb")},
    );
}
