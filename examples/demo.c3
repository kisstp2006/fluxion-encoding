// SPDX-License-Identifier: CC0-1.0

// A tour of Fluxion Encoding. Run it with `c3c run demo`.
//
// It builds a small binary record by hand, ships it as text, reads it back,
// and shows the same bytes several ways along the way. Then it packs an
// entity update down to the precision each field is actually worth, and
// unpacks it again.
module demo;
import std::io;
import fluxion::encoding;

// The header of our imaginary format, laid out as the bytes on the wire. A
// struct of endian-tagged fields is all byte arrays, so it has no padding and
// can be pointed straight at a buffer.
struct Header
{
	Big{uint} magic;
	Big{ushort} version;
	Big{ushort} flags;
}

const uint MAGIC_FLUX = 0x464C5558; // "FLUX"

faultdef NOT_A_FLUX_RECORD, UNEXPECTED_SAMPLE_COUNT;

// Write a header and a named payload into `buf`, returning what was used.
fn char[]? build_record(char[] buf, String name, ushort[] samples)
{
	WireWriter w = encoding::write(buf, BIG);

	Header header = {
		.magic = endian::big(uint, MAGIC_FLUX),
		.version = endian::big(ushort, 2),
		.flags = endian::big(ushort, 0b0000_0001),
	};
	w.put_bytes(((char*)&header)[:Header::size])!;

	w.put(char, (char)name.len)!;
	w.put_bytes(name)!;
	// Records start on a four-byte boundary, so pad out to one.
	w.pad_to_alignment(4, 0)!;

	w.put(ushort, (ushort)samples.len)!;
	w.put_slice(samples)!;
	return w.written();
}

// `main` may not return an optional, so the tour lives in `run` and `main`
// only reports what went wrong, if anything did.
fn int main()
{
	if (catch err = run())
	{
		io::printfn("error: %s", err);
		return 1;
	}
	return 0;
}

fn void? run()
{
	// --- build ----------------------------------------------------------
	char[64] record_buf;
	char[] record = build_record(&record_buf, "level", { 1, 2, 3 })!;

	io::printfn("--- the record, %d bytes ---", record.len);
	hex::dump(io::stdout(), record)!;

	// --- as text --------------------------------------------------------
	char[] text = base64::encode_alloc(mem, record, { .alphabet = URL_SAFE, .no_padding = true });
	defer free(text);
	io::printfn("\n--- base64 ---\nurl-safe, unpadded: %s", (String)text);

	// The same bytes wrapped the way PEM does it.
	io::printn("PEM-style, 24 to a line:");
	base64::encode_stream(io::stdout(), record, { .line_length = 24, .line_ending = "\n" })!;
	io::printn("");

	// --- and back -------------------------------------------------------
	char[] decoded = base64::decode_alloc(mem, (String)text, { .alphabet = URL_SAFE })!;
	defer free(decoded);
	WireReader r = encoding::read(decoded, BIG);

	Header* header = (Header*)r.take_array(Header::size)!;
	if (header.magic.get() != MAGIC_FLUX) return NOT_A_FLUX_RECORD~;

	char[] name = r.take_bytes(r.take(char)!)!;
	r.skip_to_alignment(4)!;

	ushort[3] samples;
	ushort count = r.take(ushort)!;
	if (count != samples.len) return UNEXPECTED_SAMPLE_COUNT~;
	r.take_into(samples[..])!;

	io::printfn("\n--- read back ---\nversion  %s\nflags    0x%04x\nname     %s\nsamples  %s\nleft     %d bytes",
		header.version, header.flags.get(), (String)name, samples, r.remaining());

	// --- hex ------------------------------------------------------------
	char[4] field;
	endian::write(uint, &field, 0xDEADBEEF, BIG);

	char[16] digits;
	io::printfn("\n--- hex ---\n0xDEADBEEF big-endian:    %s", (String)hex::encode(&digits, &field, { .separator = ":" })!);

	endian::write(uint, &field, 0xDEADBEEF, LITTLE);
	io::printfn("0xDEADBEEF little-endian: %s", (String)hex::encode(&digits, &field, { .separator = ":" })!);

	// Hex decodes into a value, so a key or a hash needs no allocation.
	char[4] key = hex::decode_fixed(4, "de:ad:be:ef", { .separators = ":" })!;
	io::printfn("back again:               %s", key);

	send_a_packet()!;
}

// -------------------------------------------------------------------------
// An entity update, in as few bits as it will go
// -------------------------------------------------------------------------

// The id of one asset, as the sixteen bytes it travels as. Minting these and
// spelling them `2f8a1c40-...` is fluxion-id's job; putting them on a wire is
// this library's.
const char[16] PLAYER_MODEL = {
	0x2F, 0x8A, 0x1C, 0x40, 0x6D, 0x3E, 0x4B, 0x17,
	0x9F, 0x22, 0xC1, 0xA5, 0xE7, 0xB9, 0x0D, 0x34,
};

struct Entity
{
	uint id;
	char[16] model;
	float[3] position;
	float heading;
	float[3] facing;
	float[4] rotation;
	char health;
	bool firing;
}

// The precision each field is actually worth, decided once and shared by both
// ends of the wire.
const Range POSITION = { .min = -500, .max = 500, .bit_count = 16 };
const Angle HEADING = { .bit_count = 12 };
const NormalCodec FACING = { .bit_count = 10 };
const RotationCodec ROTATION = { .bit_count = 9 };

fn void? send_a_packet()
{
	Entity sent = {
		.id = 4211,
		.model = PLAYER_MODEL,
		.position = { 12.5f, -300.25f, 64.0f },
		.heading = 1.75f,
		.facing = { 0, 0, 1 },
		.rotation = { 0, 0.7071f, 0, 0.7071f },
		.health = 87,
		.firing = true,
	};

	char[64] buf;

	// The header is byte-shaped: an asset id, then a varint entity id that
	// costs two bytes rather than four.
	WireWriter w = encoding::write(&buf, BIG);
	w.put_bytes(&sent.model)!;
	w.put_varint(uint, sent.id)!;
	sz header_len = w.written().len;

	// Everything after it is bit-shaped.
	BitPacker bw = encoding::write_bits(buf[header_len..]);
	foreach (axis : sent.position) POSITION.put(&bw, axis)!;
	HEADING.put(&bw, sent.heading)!;
	FACING.put(&bw, sent.facing)!;
	ROTATION.put(&bw, sent.rotation)!;
	bw.put(char, sent.health, bits::needed(100))!;
	bw.put_bool(sent.firing)!;

	char[] packet = buf[:header_len + bw.written().len];

	// What it cost, against the same fields sent at full width.
	sz uncompressed = 16 + 4 + 3 * 4 + 4 + 3 * 4 + 4 * 4 + 1 + 1;
	io::printfn("\n--- a packet ---\nheader   %d bytes (16 asset id + %d varint entity id)\npayload  %d bits (%d bytes)\ntotal    %d bytes, against %d sent at full width",
		header_len, header_len - 16, bw.bits_written(), bw.written().len, packet.len, uncompressed);
	hex::dump(io::stdout(), packet)!;

	// And the other end reads it back.
	WireReader r = encoding::read(packet, BIG);
	char[16] model = *r.take_array(16)!;
	uint id = r.take_varint(uint)!;

	// Sixteen opaque bytes are unreadable, so print them as hex - the same
	// thirty-two digits a uuid is spelled with, without the dashes.
	char[32] model_text;
	hex::encode(&model_text, &model)!;

	BitUnpacker br = encoding::read_bits(r.rest());
	float[3] got_position;
	foreach (&axis : got_position) *axis = POSITION.take(&br)!;
	float got_heading = HEADING.take(&br)!;
	float[3] got_facing = FACING.take(&br)!;
	float[4] got_rotation = ROTATION.take(&br)!;
	char got_health = br.take(char, bits::needed(100))!;
	bool got_firing = br.take_bool()!;

	io::printfn("\nentity %d, model %s", id, (String)model_text[..]);
	io::printfn("position %.3f %.3f %.3f  (to within %.4f)", got_position[0], got_position[1], got_position[2], POSITION.precision());
	io::printfn("heading  %.4f                  (to within %.5f)", got_heading, HEADING.precision());
	io::printfn("facing   %.3f %.3f %.3f", got_facing[0], got_facing[1], got_facing[2]);
	io::printfn("rotation %.3f %.3f %.3f %.3f", got_rotation[0], got_rotation[1], got_rotation[2], got_rotation[3]);
	io::printfn("health   %d, firing %s", got_health, got_firing);

	// The same sixteen bytes, spelled the way a person reads them back.
	char[47] grouped;
	io::printfn("\nmodels/player.glb -> %s", (String)hex::encode(&grouped, &model, { .separator = ":" })!);
}
