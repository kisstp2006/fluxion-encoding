// SPDX-License-Identifier: CC0-1.0

// Base64 as RFC 4648 defines it, in both alphabets.
//
// Every routine comes in three shapes, and they all agree with each other:
//
//   * `encode` / `decode`              - into a slice you own, no allocation
//   * `encode_alloc` / `decode_alloc`  - into fresh memory, you free it
//   * `encode_stream`                  - straight into an `OutStream`
//
// `encoded_len` and `decoded_len` say how much room a call needs, so the
// no-allocation path never has to guess.
//
// Decoding is strict by default: characters outside the alphabet, misplaced
// padding, truncated groups and final characters carrying bits that would be
// thrown away are all rejected. `DecodeOptions` loosens any of it for reading
// what someone else wrote.
//
// A word on the options structs. C3 zero-fills a struct and has no per-field
// defaults, so every option is named such that zero is the default: it is
// `no_padding`, not `padding = true`, and `allow_non_canonical`, not
// `canonical = true`. That way `{}` is "the defaults" and `{ .no_padding =
// true }` changes one thing, which is what Zig's `.{}` gave for free.
module fluxion::encoding::base64;
import fluxion::encoding::sink;
import std::io;

// Which two characters fill the last slots of the 64-character alphabet.
enum Alphabet
{
	// RFC 4648 section 4: `+` and `/`. What MIME, PEM and most APIs use.
	STANDARD,
	// RFC 4648 section 5: `-` and `_`, so the output survives a URL or a
	// file name untouched.
	URL_SAFE,
}

const char[64] STANDARD_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const char[64] URL_SAFE_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

fn char[64]* Alphabet.chars(self)
{
	return self == URL_SAFE ? &URL_SAFE_CHARS : &STANDARD_CHARS;
}

// The character that pads a short final group out to four.
const char PAD_CHAR = '=';

// -------------------------------------------------------------------------
// Encoding
// -------------------------------------------------------------------------

struct EncodeOptions
{
	Alphabet alphabet;
	// Leave off the `=` that would bring the output length to a multiple of
	// four. This is the unpadded form that JWTs and most URL-safe payloads
	// use.
	bool no_padding;
	// Break the output into lines of this many characters. `0` keeps it on
	// one line; MIME uses 76 and PEM uses 64.
	sz line_length;
	// What separates those lines. Empty means `\r\n`. Ignored when
	// `line_length` is `0`, and never written after the last line.
	String line_ending;
}

fn String EncodeOptions.ending(&self)
{
	return self.line_ending.len == 0 ? "\r\n" : self.line_ending;
}

<*
 Exactly how many bytes `encode` writes for `source_len` bytes of input.
*>
fn sz encoded_len(sz source_len, EncodeOptions options = {})
{
	sz remainder = source_len % 3;
	sz n = source_len / 3 * 4;
	if (remainder != 0) n += options.no_padding ? remainder + 1 : 4;
	if (options.line_length != 0 && n != 0)
	{
		sz lines = (n + options.line_length - 1) / options.line_length;
		n += (lines - 1) * options.ending().len;
	}
	return n;
}

<*
 Encode `bytes` into `out`, returning the part of `out` that was written.
 `sink::NO_SPACE_LEFT` if `out` is smaller than `encoded_len`.
*>
fn char[]? encode(char[] out, char[] bytes, EncodeOptions options = {})
{
	Buffer buffer;
	buffer.init(out);
	encode_into(&buffer, bytes, options)!;
	return buffer.written();
}

<*
 Encode `bytes` into memory from `allocator`. Caller owns the result.
*>
fn char[] encode_alloc(Allocator allocator, char[] bytes, EncodeOptions options = {})
{
	char[] out = alloc::alloc_array(allocator, char, encoded_len(bytes.len, options));
	// `out` is exactly the size the encoder asked for, so it cannot run out;
	// `!!` says so, and would abort if the arithmetic above were ever wrong.
	Buffer buffer;
	buffer.init(out);
	encode_into(&buffer, bytes, options)!!;
	assert(buffer.len == out.len);
	return out;
}

<*
 Encode `bytes` straight into `out`, with no intermediate buffer.
*>
fn void? encode_stream(OutStream out, char[] bytes, EncodeOptions options = {})
{
	return encode_into(out, bytes, options);
}

// Emit one character, breaking the line first if this one would not fit.
macro void? emit(out, sz* column, EncodeOptions* options, char c) @private
{
	if (options.line_length != 0 && *column == options.line_length)
	{
		out.write(options.ending())!;
		*column = 0;
	}
	out.write_byte(c)!;
	(*column)++;
}

// The one encoding routine. `out` is anything with `write_byte` and `write`:
// a `sink::Buffer`, a `sink::Counter`, or an `OutStream`.
macro void? encode_into(out, char[] bytes, EncodeOptions options) @private
{
	char[64]* chars = options.alphabet.chars();
	sz column = 0;

	sz i = 0;
	for (; i + 3 <= bytes.len; i += 3)
	{
		uint group = (uint)bytes[i] << 16 | (uint)bytes[i + 1] << 8 | (uint)bytes[i + 2];
		emit(out, &column, &options, (*chars)[group >> 18])!;
		emit(out, &column, &options, (*chars)[group >> 12 & 0x3F])!;
		emit(out, &column, &options, (*chars)[group >> 6 & 0x3F])!;
		emit(out, &column, &options, (*chars)[group & 0x3F])!;
	}

	switch (bytes.len - i)
	{
		case 1:
			uint group = (uint)bytes[i] << 16;
			emit(out, &column, &options, (*chars)[group >> 18])!;
			emit(out, &column, &options, (*chars)[group >> 12 & 0x3F])!;
			if (!options.no_padding)
			{
				emit(out, &column, &options, PAD_CHAR)!;
				emit(out, &column, &options, PAD_CHAR)!;
			}
		case 2:
			uint group = (uint)bytes[i] << 16 | (uint)bytes[i + 1] << 8;
			emit(out, &column, &options, (*chars)[group >> 18])!;
			emit(out, &column, &options, (*chars)[group >> 12 & 0x3F])!;
			emit(out, &column, &options, (*chars)[group >> 6 & 0x3F])!;
			if (!options.no_padding) emit(out, &column, &options, PAD_CHAR)!;
		default:
			break;
	}
}

// -------------------------------------------------------------------------
// Decoding
// -------------------------------------------------------------------------

// What to make of `=` in the input.
enum PaddingPolicy
{
	// Padding is accepted but not insisted upon. The default.
	OPTIONAL,
	// A short final group must be padded out to four characters.
	REQUIRE,
	// `=` is never a valid character.
	FORBID,
}

struct DecodeOptions
{
	Alphabet alphabet;
	PaddingPolicy padding;
	// Skip ASCII whitespace wherever it appears. MIME and PEM wrap their
	// payload across lines, so anything read out of a file wants this on.
	bool ignore_whitespace;
	// Accept a final character carrying bits that decoding discards, which
	// is how one string of bytes ends up with several spellings. `"Zg=="`
	// decodes to "f"; so would `"Zh=="`, and by default that is rejected.
	bool allow_non_canonical;
}

// A character outside the alphabet that was not padding and not skipped.
faultdef INVALID_CHARACTER;

// `=` somewhere it cannot be, missing where `REQUIRE` demands it, or
// anything at all following a padded group.
faultdef INVALID_PADDING;

// The input ends part-way through a group, leaving bits that cannot make up
// a whole byte.
faultdef TRUNCATED;

// The final character carries bits that decoding would discard, and
// `allow_non_canonical` is off.
faultdef NON_CANONICAL;

// Marks a byte that is not in the alphabet. No character can decode to it,
// since every real six-bit value is below 64.
const char INVALID = 0xFF;

macro char[256] @build_table(char[64] $chars) @const @private
{
	var $t = (char[256]){};
	$for var $i = 0; $i < 256; $i++:
		$t[$i] = INVALID;
	$endfor
	$for var $i = 0; $i < 64; $i++:
		$t[$chars[$i]] = $i;
	$endfor
	return $t;
}

const char[256] STANDARD_TABLE = @build_table(STANDARD_CHARS);
const char[256] URL_SAFE_TABLE = @build_table(URL_SAFE_CHARS);

fn char[256]* table_for(Alphabet alphabet) @private
{
	return alphabet == URL_SAFE ? &URL_SAFE_TABLE : &STANDARD_TABLE;
}

<*
 Exactly how many bytes `decode` will write, validating `text` on the way.
 Fails with the same faults `decode` would.
*>
fn sz? decoded_len(String text, DecodeOptions options = {})
{
	Counter counter;
	decode_into(&counter, text, options)!;
	return counter.len;
}

<*
 A ceiling on the decoded size that costs nothing to compute, for sizing a
 scratch buffer up front. `decoded_len` is the exact answer.
*>
fn sz decoded_len_upper_bound(sz text_len)
{
	return (text_len + 3) / 4 * 3;
}

<*
 True if `text` decodes cleanly under `options`.
*>
fn bool is_valid(String text, DecodeOptions options = {})
{
	return @ok(decoded_len(text, options));
}

<*
 Decode `text` into `out`, returning the part of `out` that was written.
*>
fn char[]? decode(char[] out, String text, DecodeOptions options = {})
{
	Buffer buffer;
	buffer.init(out);
	decode_into(&buffer, text, options)!;
	return buffer.written();
}

<*
 Decode `text` into memory from `allocator`. Caller owns the result.
*>
fn char[]? decode_alloc(Allocator allocator, String text, DecodeOptions options = {})
{
	char[] out = alloc::alloc_array(allocator, char, decoded_len(text, options)!);
	Buffer buffer;
	buffer.init(out);
	decode_into(&buffer, text, options)!!;
	return out;
}

// Turn a full or short group of six-bit values into whole bytes.
macro void? flush(out, char[4] group, sz count, bool allow_non_canonical) @private
{
	// The bits of a short group that no output byte will carry.
	char leftover;
	switch (count)
	{
		case 2: leftover = group[1] & 0x0F;
		case 3: leftover = group[2] & 0x03;
		default: leftover = 0;
	}
	if (!allow_non_canonical && leftover != 0) return NON_CANONICAL~;

	uint bits = (uint)group[0] << 18 |
		(uint)group[1] << 12 |
		(uint)(count > 2 ? group[2] : 0) << 6 |
		(uint)(count > 3 ? group[3] : 0);

	out.write_byte((char)(bits >> 16))!;
	if (count > 2) out.write_byte((char)(bits >> 8))!;
	if (count > 3) out.write_byte((char)bits)!;
}

// The one decoding routine. `out` is anything with `write_byte` and `write`;
// see `sink`.
macro void? decode_into(out, String text, DecodeOptions options) @private
{
	char[256]* table = table_for(options.alphabet);

	char[4] group;
	// Characters gathered into the current group, and `=` seen after them.
	sz count = 0;
	sz pad = 0;
	// Set once a padded group has closed the stream: nothing may follow.
	bool closed = false;

	foreach (c : text)
	{
		if (options.ignore_whitespace && c.is_space()) continue;
		if (closed) return INVALID_PADDING~;

		if (c == PAD_CHAR)
		{
			if (options.padding == FORBID) return INVALID_PADDING~;
			// Fewer than two characters can never have produced a byte, so
			// there is nothing here for padding to round out.
			if (count + pad < 2) return INVALID_PADDING~;
			pad++;
			if (count + pad == 4)
			{
				flush(out, group, count, options.allow_non_canonical)!;
				count = 0;
				pad = 0;
				closed = true;
			}
			continue;
		}

		// A character after `=` but still inside the group, as in "Zm=8".
		if (pad != 0) return INVALID_PADDING~;

		char value = (*table)[c];
		if (value == INVALID) return INVALID_CHARACTER~;
		group[count] = value;
		count++;
		if (count == 4)
		{
			flush(out, group, 4, options.allow_non_canonical)!;
			count = 0;
		}
	}

	if (count == 0) return;
	if (count == 1) return TRUNCATED~;
	if (options.padding == REQUIRE) return INVALID_PADDING~;
	flush(out, group, count, options.allow_non_canonical)!;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

struct Vector
{
	String plain;
	String encoded;
}

// The vectors from RFC 4648 section 10.
const Vector[] RFC_VECTORS = {
	{ "", "" },
	{ "f", "Zg==" },
	{ "fo", "Zm8=" },
	{ "foo", "Zm9v" },
	{ "foob", "Zm9vYg==" },
	{ "fooba", "Zm9vYmE=" },
	{ "foobar", "Zm9vYmFy" },
};

fn void test_rfc_4648_test_vectors() @test
{
	char[16] buf;
	char[8] back;
	foreach (v : RFC_VECTORS)
	{
		test::eq((String)encode(&buf, v.plain)!!, v.encoded);
		test::eq((String)decode(&back, v.encoded)!!, v.plain);
	}
}

fn void test_encoded_len_and_decoded_len_agree_with_what_happens() @test
{
	char[64] buf;
	EncodeOptions[] option_sets = {
		{},
		{ .no_padding = true },
		{ .alphabet = URL_SAFE },
		{ .line_length = 8 },
		{ .line_length = 4, .line_ending = "\n", .no_padding = true },
	};
	foreach (options : option_sets)
	{
		for (sz len = 0; len < 24; len++)
		{
			String source = "the quick brown fox jumps"[:len];
			char[] encoded = encode(&buf, source, options)!!;
			test::eq(encoded.len, encoded_len(len, options));

			DecodeOptions decode_options = { .alphabet = options.alphabet, .ignore_whitespace = true };
			test::eq(decoded_len((String)encoded, decode_options)!!, len);
			test::@check(len <= decoded_len_upper_bound(encoded.len));
		}
	}
}

fn void test_round_trip_over_every_byte_value() @test
{
	char[256] source;
	foreach (i, &b : source) *b = (char)i;

	char[] encoded = encode_alloc(mem, &source);
	defer free(encoded);

	char[] decoded = decode_alloc(mem, (String)encoded)!!;
	defer free(decoded);

	test::eq(decoded, source[..]);
}

fn void test_the_url_safe_alphabet_avoids_plus_and_slash() @test
{
	// These two inputs pick out the characters the alphabets disagree on.
	char[8] buf;
	char[3] plus = { 0xFB, 0xEF, 0xBE };
	test::eq((String)encode(&buf, &plus)!!, "++++");
	test::eq((String)encode(&buf, &plus, { .alphabet = URL_SAFE })!!, "----");

	char[3] slash = { 0xFF, 0xFF, 0xFF };
	test::eq((String)encode(&buf, &slash)!!, "////");
	test::eq((String)encode(&buf, &slash, { .alphabet = URL_SAFE })!!, "____");

	// Each alphabet rejects the other's two characters.
	char[4] back;
	test::@error(decode(&back, "----"), INVALID_CHARACTER);
	test::@error(decode(&back, "++++", { .alphabet = URL_SAFE }), INVALID_CHARACTER);
}

fn void test_unpadded_output_as_jwts_use() @test
{
	char[8] buf;
	EncodeOptions options = { .alphabet = URL_SAFE, .no_padding = true };
	test::eq((String)encode(&buf, "f", options)!!, "Zg");
	test::eq((String)encode(&buf, "fo", options)!!, "Zm8");
	test::eq((String)encode(&buf, "foo", options)!!, "Zm9v");

	char[4] back;
	DecodeOptions strict = { .alphabet = URL_SAFE, .padding = FORBID };
	test::eq((String)decode(&back, "Zm8", strict)!!, "fo");
	test::@error(decode(&back, "Zm8=", strict), INVALID_PADDING);
}

fn void test_padding_policies() @test
{
	char[8] buf;
	test::eq((String)decode(&buf, "Zm8=", { .padding = REQUIRE })!!, "fo");
	test::@error(decode(&buf, "Zm8", { .padding = REQUIRE }), INVALID_PADDING);

	// A group that is already full needs no padding under any policy.
	test::eq((String)decode(&buf, "Zm9v", { .padding = REQUIRE })!!, "foo");
	test::eq((String)decode(&buf, "Zm9v", { .padding = FORBID })!!, "foo");
}

fn void test_misplaced_padding_is_rejected() @test
{
	char[16] buf;
	String[] cases = {
		"=",        // nothing to pad
		"====",     // still nothing, four times over
		"Z===",     // one character can never make a byte
		"Zm9v=",    // a full group needs no padding
		"Zg==Zg==", // two payloads glued together
		"Zg==x",    // anything at all after a closed group
		"Zm=8",     // padding in the middle of a group
	};
	foreach (text : cases)
	{
		test::@error(decode(&buf, text), INVALID_PADDING);
	}
}

fn void test_truncated_and_invalid_input() @test
{
	char[16] buf;
	test::@error(decode(&buf, "Z"), TRUNCATED);
	test::@error(decode(&buf, "Zm9vZ"), TRUNCATED);
	test::@error(decode(&buf, "Zm9 v"), INVALID_CHARACTER);
	test::@error(decode(&buf, "Zm9*"), INVALID_CHARACTER);
	test::@error(decode(buf[:2], "Zm9vYmFy"), sink::NO_SPACE_LEFT);
	test::@error(encode(buf[:3], "foo"), sink::NO_SPACE_LEFT);
}

fn void test_non_canonical_encodings() @test
{
	char[8] buf;
	// "Zg==" and "Zh==" would both decode to "f"; only the first is canonical.
	test::eq((String)decode(&buf, "Zg==")!!, "f");
	test::@error(decode(&buf, "Zh=="), NON_CANONICAL);
	test::eq((String)decode(&buf, "Zh==", { .allow_non_canonical = true })!!, "f");

	test::eq((String)decode(&buf, "Zm8=")!!, "fo");
	test::@error(decode(&buf, "Zm9="), NON_CANONICAL);
}

fn void test_whitespace_as_mime_and_pem_produce_it() @test
{
	String wrapped = "Zm9v\r\nYmFy\r\nZm9v\n";
	char[16] buf;
	test::@error(decode(&buf, wrapped), INVALID_CHARACTER);
	test::eq((String)decode(&buf, wrapped, { .ignore_whitespace = true })!!, "foobarfoo");

	// It may even land inside a group, or in front of the padding.
	test::eq((String)decode(&buf, " Z m 8 = ", { .ignore_whitespace = true })!!, "fo");
}

fn void test_line_wrapping() @test
{
	char[64] buf;
	char[] wrapped = encode(&buf, "any carnal pleasure", { .line_length = 8, .line_ending = "\n" })!!;
	test::eq((String)wrapped, "YW55IGNh\ncm5hbCBw\nbGVhc3Vy\nZQ==");

	char[] decoded = decode_alloc(mem, (String)wrapped, { .ignore_whitespace = true })!!;
	defer free(decoded);
	test::eq((String)decoded, "any carnal pleasure");

	// No trailing line ending, even when the last line comes out exactly full.
	char[] exact = encode(&buf, "foobar", { .line_length = 4, .line_ending = "\n" })!!;
	test::eq((String)exact, "Zm9v\nYmFy");
}

fn void test_encode_stream_matches_encode() @test
{
	DString out;
	out.init(mem);
	defer out.free();
	EncodeOptions options = { .line_length = 8, .line_ending = "\n" };
	encode_stream(&out, "any carnal pleasure", options)!!;

	char[64] buf;
	test::eq(out.str_view(), (String)encode(&buf, "any carnal pleasure", options)!!);
}

fn void test_is_valid() @test
{
	test::@check(is_valid("Zm9vYmFy"));
	test::@check(is_valid(""));
	test::@check(!is_valid("Zm9vYmF"));
	test::@check(!is_valid("Zm9v YmFy"));
	test::@check(is_valid("Zm9v YmFy", { .ignore_whitespace = true }));
}
