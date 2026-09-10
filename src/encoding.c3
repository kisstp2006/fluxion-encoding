// SPDX-License-Identifier: CC0-1.0

// Fluxion Encoding - bytes to text and back, and the byte order in between.
//
// Six pieces that fit together, each its own module under `fluxion::encoding`:
//
//   `base64`    RFC 4648 in both alphabets, padded or not, wrapped or not
//   `hex`       hex in either case, with separators, and a hex dump
//   `endian`    fixed-width values in whichever byte order the format uses
//   `varint`    integers that cost one byte when they are small
//   `bits`      fields that are not a whole number of bytes wide
//   `quantize`  floats, angles, normals and rotations, into those fields
//
// The two codecs share one shape, so swapping between them is a change of
// name and nothing else:
//
//   `encode` / `decode`              into a slice you own, no allocation
//   `encode_alloc` / `decode_alloc`  into fresh memory, you free it
//   `encoded_len` / `decoded_len`    how much room a call needs
//   `encode_stream`                  straight into an `OutStream`
//
// Nothing here allocates unless it takes an `Allocator`, and everything that
// allocates says who owns the result.
//
// This module holds the shorthands. Importing `fluxion::encoding` imports
// the six sub-modules with it.
module fluxion::encoding;
import fluxion::encoding::base64, fluxion::encoding::hex, fluxion::encoding::endian;
import fluxion::encoding::varint, fluxion::encoding::bits, fluxion::encoding::quantize;

<*
 A cursor that reads fixed-width values out of a byte slice, so call sites
 read `encoding::read(bytes, BIG)`. See `endian`.
*>
fn WireReader read(char[] bytes, Endian order)
{
	WireReader r;
	r.init(bytes, order);
	return r;
}

<*
 Its mirror, writing them into a slice you own. See `endian`.
*>
fn WireWriter write(char[] bytes, Endian order)
{
	WireWriter w;
	w.init(bytes, order);
	return w;
}

<*
 A cursor over the fields that are narrower than a byte. See `bits`.
*>
fn BitUnpacker read_bits(char[] bytes)
{
	BitUnpacker r;
	r.init(bytes);
	return r;
}

<*
 Its mirror. See `bits`.
*>
fn BitPacker write_bits(char[] bytes)
{
	BitPacker w;
	w.init(bytes);
	return w;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn void test_the_pieces_compose() @test
{
	// A record built by hand, handed over as text, and read back out.
	char[16] buf;
	WireWriter w = write(&buf, BIG);
	w.put_bytes("FLUX")!!;
	w.put(ushort, 1)!!;
	w.put(uint, 0xDEADBEEF)!!;

	char[] text = base64::encode_alloc(mem, w.written(), { .alphabet = URL_SAFE, .no_padding = true });
	defer free(text);
	test::eq((String)text, "RkxVWAAB3q2-7w");

	char[] bytes = base64::decode_alloc(mem, (String)text, { .alphabet = URL_SAFE })!!;
	defer free(bytes);

	WireReader r = read(bytes, BIG);
	r.expect_bytes("FLUX")!!;
	test::eq(r.take(ushort)!!, (ushort)1);

	uint payload = r.take(uint)!!;
	test::eq(payload, 0xDEADBEEFU);
	test::@check(r.is_at_end());

	// And the same four bytes as hex, which is the readable spelling.
	char[11] digits;
	char[4] field;
	endian::write(uint, &field, payload, BIG);
	test::eq((String)hex::encode(&digits, &field, { .separator = ":" })!!, "de:ad:be:ef");
}

fn void test_a_packet_in_as_few_bits_as_it_will_go() @test
{
	// A sixteen-byte asset id names what moved; the rest is quantized down to
	// the precision anyone can actually tell apart. Where the id came from is
	// fluxion-id's business - here it is sixteen bytes, which is all this
	// library ever sees of one.
	char[16] model = {
		0x2F, 0x8A, 0x1C, 0x40, 0x6D, 0x3E, 0x4B, 0x17,
		0x9F, 0x22, 0xC1, 0xA5, 0xE7, 0xB9, 0x0D, 0x34,
	};

	Range position = quantize::range(-500, 500, 16);
	Angle heading = quantize::angle(12);

	char[64] buf;
	WireWriter w = write(&buf, BIG);
	w.put_bytes(&model)!!; // 16 bytes
	w.put_varint(uint, 4211)!!; // an entity id, two bytes
	w.put_varint(int, -3)!!; // a frame delta, one byte

	// The rest goes into a bit stream, byte-aligned behind the header.
	BitPacker bw = write_bits(buf[w.written().len..]);
	position.put(&bw, 12.5f)!!;
	position.put(&bw, -300.25f)!!;
	heading.put(&bw, 1.75f)!!;
	bw.put_bool(true)!!;

	char[] packet = buf[:w.written().len + bw.written().len];
	test::eq(packet.len, 25);

	// And back.
	WireReader r = read(packet, BIG);
	test::eq(*r.take_array(16)!!, model);
	test::eq(r.take_varint(uint)!!, 4211U);
	test::eq(r.take_varint(int)!!, -3);

	BitUnpacker br = read_bits(r.rest());
	test::eq_approx(position.take(&br)!!, 12.5, delta: position.precision());
	test::eq_approx(position.take(&br)!!, -300.25, delta: position.precision());
	test::eq_approx(heading.take(&br)!!, 1.75, delta: heading.precision());
	test::@check(br.take_bool()!!);
}

fn void test_shorthands() @test
{
	char[4] buf;
	WireWriter w = write(&buf, LITTLE);
	w.put(uint, 0x01020304)!!;

	WireReader r = read(&buf, LITTLE);
	test::eq(r.take(uint)!!, 0x01020304U);

	BitPacker bw = write_bits(&buf);
	bw.put(char, 5, 3)!!;
	BitUnpacker br = read_bits(bw.written());
	test::eq(br.take(char, 3)!!, (char)5);
}
