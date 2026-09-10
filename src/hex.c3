// SPDX-License-Identifier: CC0-1.0

// Hexadecimal: two characters per byte, and a hex dump for looking at binary
// with your own eyes.
//
// The `encode` / `decode` family mirrors `base64` exactly, down to the option
// names, so the two are interchangeable wherever a codec is all that is
// wanted:
//
//   * `encode` / `decode`              - into a slice you own, no allocation
//   * `encode_alloc` / `decode_alloc`  - into fresh memory, you free it
//   * `encode_stream`                  - straight into an `OutStream`
//
// Encoding picks a case; decoding accepts either. Separators are a matter of
// options in both directions, so `de:ad:be:ef` survives a round trip.
module fluxion::encoding::hex;
import fluxion::encoding::sink;
import std::io;

enum Case
{
	LOWER,
	UPPER,
}

const char[16] LOWER_DIGITS = "0123456789abcdef";
const char[16] UPPER_DIGITS = "0123456789ABCDEF";

fn char[16]* Case.digits(self)
{
	return self == UPPER ? &UPPER_DIGITS : &LOWER_DIGITS;
}

// What `digit_value` answers for a character that is not a hex digit. Every
// real digit is below 16, so nothing collides with it.
const char NOT_A_DIGIT = 0xFF;

<*
 The value of one hex digit, or `NOT_A_DIGIT` if `c` is not one. Accepts
 either case.
*>
fn char digit_value(char c)
{
	switch
	{
		case c >= '0' && c <= '9': return c - '0';
		case c >= 'a' && c <= 'f': return c - 'a' + 10;
		case c >= 'A' && c <= 'F': return c - 'A' + 10;
		default: return NOT_A_DIGIT;
	}
}

<*
 The character for one hex digit.

 @require value < 16 : "a hex digit is 0 to 15"
*>
fn char digit_char(char value, Case letter_case)
{
	return (*letter_case.digits())[value];
}

// -------------------------------------------------------------------------
// Encoding
// -------------------------------------------------------------------------

struct EncodeOptions
{
	Case letter_case;
	// Written between every pair of bytes, and nowhere else. `":"` gives
	// `de:ad:be:ef`, `" "` gives a spaced dump.
	String separator;
}

<*
 Exactly how many bytes `encode` writes for `source_len` bytes of input.
*>
fn sz encoded_len(sz source_len, EncodeOptions options = {})
{
	if (source_len == 0) return 0;
	return source_len * 2 + (source_len - 1) * options.separator.len;
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
	// `out` is exactly the size the encoder asked for, so it cannot run out.
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

// The one encoding routine. `out` is anything with `write_byte` and `write`:
// a `sink::Buffer`, a `sink::Counter`, or an `OutStream`.
macro void? encode_into(out, char[] bytes, EncodeOptions options) @private
{
	char[16]* digits = options.letter_case.digits();
	foreach (i, byte : bytes)
	{
		if (i != 0) out.write(options.separator)!;
		out.write_byte((*digits)[byte >> 4])!;
		out.write_byte((*digits)[byte & 0x0F])!;
	}
}

// -------------------------------------------------------------------------
// Decoding
// -------------------------------------------------------------------------

struct DecodeOptions
{
	// Skip ASCII whitespace wherever it appears, so text pasted out of a log
	// or split across lines still reads.
	bool ignore_whitespace;
	// Every character in this set is skipped as well. Pass `":"` to read
	// `de:ad:be:ef`, or `":-"` to accept either spelling.
	String separators;
}

// A character that is neither a hex digit nor something to skip.
faultdef INVALID_CHARACTER;

// The input held an odd number of hex digits, so the last byte is half
// written.
faultdef ODD_LENGTH;

fn bool skippable(char c, DecodeOptions* options) @private
{
	if (options.ignore_whitespace && c.is_space()) return true;
	return @ok(options.separators.index_of_char(c));
}

<*
 Exactly how many bytes `decode` will write, validating `text` on the way.
 Fails with the same faults `decode` would.
*>
fn sz? decoded_len(String text, DecodeOptions options = {})
{
	sz digits = 0;
	foreach (c : text)
	{
		if (skippable(c, &options)) continue;
		if (digit_value(c) == NOT_A_DIGIT) return INVALID_CHARACTER~;
		digits++;
	}
	if (digits % 2 != 0) return ODD_LENGTH~;
	return digits / 2;
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

<*
 Decode text of a length known up front - a hash, a UUID, a key - into an
 array held by value, so there is nothing to allocate and nothing to free.
 Text that decodes to any other length is `ODD_LENGTH`.

 The length is a `$`-parameter because it is part of the return type, and a
 return type has to be known while the program is being compiled.
*>
macro decode_fixed($n, String text, DecodeOptions options = {})
{
	if (decoded_len(text, options)! != $n) return ODD_LENGTH~;
	char[$n] out;
	Buffer buffer;
	buffer.init(&out);
	decode_into(&buffer, text, options)!!;
	return out;
}

// The one decoding routine. `out` is anything with `write_byte` and `write`;
// see `sink`.
macro void? decode_into(out, String text, DecodeOptions options) @private
{
	char high = NOT_A_DIGIT;
	foreach (c : text)
	{
		if (skippable(c, &options)) continue;
		char value = digit_value(c);
		if (value == NOT_A_DIGIT) return INVALID_CHARACTER~;
		if (high != NOT_A_DIGIT)
		{
			out.write_byte(high << 4 | value)!;
			high = NOT_A_DIGIT;
		}
		else
		{
			high = value;
		}
	}
	if (high != NOT_A_DIGIT) return ODD_LENGTH~;
}

// -------------------------------------------------------------------------
// Dumping
// -------------------------------------------------------------------------

struct DumpOptions
{
	// Bytes shown per line. `0` means 16.
	sz columns;
	// The address printed beside the first byte, for when `bytes` is a
	// window into something larger.
	sz base_offset;
	// Leave out the offset column on the left.
	bool hide_offset;
	// Leave out the printable-ASCII column on the right.
	bool hide_ascii;
	Case letter_case;
}

<*
 Write a hex dump of `bytes` to `w`, one line per `columns` bytes:

     00000000  66 6c 75 78 69 6f 6e 20  65 6e 63 6f 64 69 6e 67  |fluxion encoding|

 Every line ends in `\n`, including the last.
*>
fn void? dump(OutStream w, char[] bytes, DumpOptions options = {})
{
	sz columns = options.columns == 0 ? 16 : options.columns;
	char[16]* digits = options.letter_case.digits();

	for (sz start = 0; start < bytes.len; start += columns)
	{
		char[] line = bytes[start:min(columns, bytes.len - start)];

		if (!options.hide_offset) io::fprintf(w, "%08x  ", options.base_offset + start)!;

		for (sz i = 0; i < columns; i++)
		{
			if (i != 0) w.write_byte(' ')!;
			// A wider gap every eight bytes, so the eye can count them.
			if (i != 0 && i % 8 == 0) w.write_byte(' ')!;
			if (i < line.len)
			{
				w.write_byte((*digits)[line[i] >> 4])!;
				w.write_byte((*digits)[line[i] & 0x0F])!;
			}
			else
			{
				// Blanks, so a short last line keeps the ASCII column aligned.
				w.write("  ")!;
			}
		}

		if (!options.hide_ascii)
		{
			w.write("  |")!;
			foreach (byte : line)
			{
				w.write_byte(byte.is_print() ? byte : '.')!;
			}
			w.write_byte('|')!;
		}
		w.write_byte('\n')!;
	}
}

<*
 A hex dump of `bytes` in memory from `allocator`. Caller owns the result.
*>
fn String dump_alloc(Allocator allocator, char[] bytes, DumpOptions options = {})
{
	DString out;
	out.init(allocator);
	defer out.free();
	// A `DString` only fails for want of memory, and the standard library
	// aborts on that rather than reporting it, so nothing can reach `!!`.
	dump(&out, bytes, options)!!;
	return out.copy_str(allocator);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn void test_digits() @test
{
	test::eq(digit_value('0'), (char)0);
	test::eq(digit_value('a'), (char)10);
	test::eq(digit_value('A'), (char)10);
	test::eq(digit_value('f'), (char)15);
	test::eq(digit_value('g'), NOT_A_DIGIT);
	test::eq(digit_value(' '), NOT_A_DIGIT);

	test::eq(digit_char(14, LOWER), 'e');
	test::eq(digit_char(14, UPPER), 'E');
}

fn void test_encode_and_decode() @test
{
	char[4] bytes = { 0xDE, 0xAD, 0xBE, 0xEF };
	char[16] buf;

	test::eq((String)encode(&buf, &bytes)!!, "deadbeef");
	test::eq((String)encode(&buf, &bytes, { .letter_case = UPPER })!!, "DEADBEEF");

	char[4] back;
	test::eq(decode(&back, "deadbeef")!!, bytes[..]);
	test::eq(decode(&back, "DEADBEEF")!!, bytes[..]);
	// Mixed case is fine on the way in.
	test::eq(decode(&back, "DeAdBeEf")!!, bytes[..]);
}

fn void test_empty_input() @test
{
	char[4] buf;
	test::eq((String)encode(&buf, "")!!, "");
	test::eq(encoded_len(0, { .separator = ":" }), 0);
	test::eq(decode(&buf, "")!!.len, 0);
}

fn void test_separators_go_both_ways() @test
{
	char[4] bytes = { 0xDE, 0xAD, 0xBE, 0xEF };
	char[16] buf;
	char[] spaced = encode(&buf, &bytes, { .separator = ":" })!!;
	test::eq((String)spaced, "de:ad:be:ef");
	test::eq(spaced.len, encoded_len(bytes.len, { .separator = ":" }));

	char[4] back;
	test::@error(decode(&back, (String)spaced), INVALID_CHARACTER);
	test::eq(decode(&back, (String)spaced, { .separators = ":" })!!, bytes[..]);
}

fn void test_whitespace() @test
{
	char[4] buf;
	test::@error(decode(&buf, "de ad\nbe ef"), INVALID_CHARACTER);
	char[4] wanted = { 0xDE, 0xAD, 0xBE, 0xEF };
	test::eq(decode(&buf, "de ad\nbe ef", { .ignore_whitespace = true })!!, wanted[..]);
}

fn void test_malformed_input() @test
{
	char[8] buf;
	test::@error(decode(&buf, "abc"), ODD_LENGTH);
	test::@error(decode(&buf, "abzz"), INVALID_CHARACTER);
	test::@error(decode(buf[:1], "abcd"), sink::NO_SPACE_LEFT);
	test::@error(encode(buf[:3], "ab"), sink::NO_SPACE_LEFT);
}

fn void test_round_trip_over_every_byte_value() @test
{
	char[256] source;
	foreach (i, &b : source) *b = (char)i;

	char[] encoded = encode_alloc(mem, &source, { .letter_case = UPPER });
	defer free(encoded);
	test::eq(encoded.len, 512);

	char[] decoded = decode_alloc(mem, (String)encoded)!!;
	defer free(decoded);
	test::eq(decoded, source[..]);
}

fn void test_decode_fixed() @test
{
	char[4] key = decode_fixed(4, "deadbeef")!!;
	char[4] wanted = { 0xDE, 0xAD, 0xBE, 0xEF };
	test::eq(key, wanted);
	// The result is a value, so it can be compared and copied like one.
	test::eq(key, decode_fixed(4, "DEADBEEF")!!);

	test::@error(decode_fixed(4, "deadbe"), ODD_LENGTH);
	test::@error(decode_fixed(4, "deadbeef00"), ODD_LENGTH);
	test::@error(decode_fixed(4, "deadbeez"), INVALID_CHARACTER);
}

fn void test_is_valid() @test
{
	test::@check(is_valid("deadbeef"));
	test::@check(is_valid(""));
	test::@check(!is_valid("deadbee"));
	test::@check(!is_valid("de:ad"));
	test::@check(is_valid("de:ad", { .separators = ":" }));
}

fn void test_encode_stream_matches_encode() @test
{
	DString out;
	out.init(mem);
	defer out.free();
	encode_stream(&out, "hello", { .separator = " " })!!;

	char[32] buf;
	test::eq(out.str_view(), (String)encode(&buf, "hello", { .separator = " " })!!);
}

fn void test_dump() @test
{
	String dumped = dump_alloc(mem, "fluxion encoding\n");
	defer free(dumped);
	test::eq(dumped,
		"00000000  66 6c 75 78 69 6f 6e 20  65 6e 63 6f 64 69 6e 67  |fluxion encoding|\n"
		"00000010  0a                                                |.|\n");
}

fn void test_dump_options() @test
{
	char[4] bytes = { 0x00, 0x7F, 0x80, 0xFF };

	String narrow = dump_alloc(mem, &bytes, { .columns = 4, .base_offset = 0x1000, .letter_case = UPPER });
	defer free(narrow);
	test::eq(narrow, "00001000  00 7F 80 FF  |....|\n");

	String bare = dump_alloc(mem, &bytes, { .columns = 4, .hide_offset = true, .hide_ascii = true });
	defer free(bare);
	test::eq(bare, "00 7f 80 ff\n");

	String empty = dump_alloc(mem, "");
	defer free(empty);
	test::eq(empty, "");
}
