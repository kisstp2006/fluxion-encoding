// SPDX-License-Identifier: CC0-1.0

// Variable-length integers: seven bits of payload per byte, with the top bit
// saying whether another byte follows.
//
// The same LEB128 that DWARF, WebAssembly and Protocol Buffers use. Small
// numbers cost one byte, which is what most numbers in a save file or a
// packet turn out to be: an entity count, a component id, a frame delta.
//
// Signed types go through zigzag first, so `-1` costs one byte rather than
// ten; `zigzag` and `unzigzag` are public if you need the mapping alone.
//
// Everything works on plain slices and reports how many bytes it touched, so a
// varint can sit in the middle of a record. `WireReader` and `WireWriter` have
// `take_varint` and `put_varint` built on this.
//
// The type is a `$`-parameter throughout - `varint::encode(uint, &buf, 300)`
// - because the width of the type is what decides when a value has
// overflowed, and a literal like `300` has no width of its own.
module fluxion::encoding::varint;

// The destination has no room left for the value.
faultdef NO_SPACE_LEFT;

// The input ran out while a byte still promised another one.
faultdef UNEXPECTED_END;

// The encoded value carries more bits than the type can hold.
faultdef OVERFLOW;

<*
 A value together with the number of bytes it came from.
*>
struct Decoded <Type>
{
	Type value;
	sz len;
}

// The unsigned integer of the same width as `$Type`, as a typeid to feed
// `$Typefrom`. A macro cannot return a type, but it can return the run-time
// name of one, and `$Typefrom` turns that back into a type at compile time.
macro typeid @unsigned_of($Type) @const @private
{
	$switch $Type::size:
		$case 1: return char::typeid;
		$case 2: return ushort::typeid;
		$case 4: return uint::typeid;
		$case 8: return ulong::typeid;
		$case 16: return uint128::typeid;
	$endswitch
}

macro bool @is_signed($Type) @const @private
{
	return $Type::kind == SIGNED_INT;
}

<*
 The most bytes a `$Type` can ever take: seven payload bits each.
*>
macro sz max_len($Type)
{
	return ($Type::size * 8 + 6) / 7;
}

<*
 Fold a signed value onto an unsigned one so that small magnitudes stay small:
 `0, -1, 1, -2, 2` become `0, 1, 2, 3, 4`.
*>
macro zigzag(value)
{
	var $Type = $Typeof(value);
	var $Unsigned = $Typefrom(@unsigned_of($Type));
	// An arithmetic shift by the sign bit gives all-ones for negatives. The
	// cast on the outside matters: C3 does arithmetic on anything narrower
	// than `int` in `int`, so without it a `char` shifted left keeps its ninth
	// bit and the result is no longer eight bits wide.
	return ($Unsigned)((($Unsigned)value << 1) ^ ($Unsigned)(value >> ($Type::size * 8 - 1)));
}

<*
 The inverse of `zigzag`, back to `$Type`.
*>
macro unzigzag($Type, value)
{
	var $Unsigned = $Typefrom(@unsigned_of($Type));
	// `-(value & 1)` is all-ones when the low bit says "negative".
	$Unsigned sign = ($Unsigned)(-(($Type)(value & 1)));
	return ($Type)(($Unsigned)(value >> 1) ^ sign);
}

// `value` as the unsigned number that goes on the wire.
macro to_wire($Type, value) @private
{
	$if @is_signed($Type):
		return zigzag(($Type)value);
	$else
		return ($Typefrom(@unsigned_of($Type)))value;
	$endif
}

<*
 Exactly how many bytes `encode` writes for `value`.
*>
macro sz encoded_len($Type, value)
{
	var rest = to_wire($Type, value);
	sz n = 1;
	for (; rest >= 0x80; n++) rest >>= 7;
	return n;
}

<*
 Encode `value` into the front of `out`, returning how many bytes it took.
*>
macro sz? encode($Type, char[] out, value)
{
	var rest = to_wire($Type, value);
	sz n = 0;
	while (true)
	{
		if (n == out.len) return NO_SPACE_LEFT~;
		char septet = (char)(rest & 0x7F);
		rest >>= 7;
		if (rest == 0)
		{
			out[n] = septet;
			return n + 1;
		}
		out[n] = septet | 0x80;
		n++;
	}
}

<*
 Decode the value at the front of `bytes`, along with its length.

 A redundant encoding - one padded out with `0x80` bytes that add nothing -
 decodes to the value it spells, the way Protocol Buffers reads it. Only bits
 that would not fit in `$Type` are an error.
*>
macro decode($Type, char[] bytes)
{
	var $Unsigned = $Typefrom(@unsigned_of($Type));
	const BITS = $Type::size * 8;

	$Unsigned raw = 0;
	uint shift = 0;
	foreach (i, byte : bytes)
	{
		$Unsigned septet = ($Unsigned)(byte & 0x7F);
		if (shift >= BITS)
		{
			// Past the end of the type: anything but zero has overflowed.
			if (septet != 0) return OVERFLOW~;
		}
		else
		{
			// The last septet may be cut short by the width of the type.
			if (BITS - shift < 7 && septet >> (BITS - shift) != 0) return OVERFLOW~;
			raw |= ($Unsigned)(septet << shift);
		}
		shift += 7;

		if ((byte & 0x80) == 0)
		{
			Decoded{$Type} decoded = { .len = i + 1 };
			$if @is_signed($Type):
				decoded.value = unzigzag($Type, raw);
			$else
				decoded.value = ($Type)raw;
			$endif
			return decoded;
		}
	}
	return UNEXPECTED_END~;
}

<*
 How many bytes the varint at the front of `bytes` occupies, without decoding
 it. Cheaper than `decode` when you only mean to step over it.
*>
fn sz? len(char[] bytes)
{
	foreach (i, byte : bytes)
	{
		if ((byte & 0x80) == 0) return i + 1;
	}
	return UNEXPECTED_END~;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn void test_max_len() @test
{
	test::eq(max_len(char), 2);
	test::eq(max_len(ushort), 3);
	test::eq(max_len(uint), 5);
	test::eq(max_len(ulong), 10);
}

fn void test_small_numbers_cost_one_byte() @test
{
	char[10] buf;
	for (uint value = 0; value < 128; value++)
	{
		test::eq(encode(uint, &buf, value)!!, 1);
		test::eq(encoded_len(uint, value), 1);
		test::eq(decode(uint, &buf)!!.value, value);
	}
	// 128 is the first that needs two.
	test::eq(encode(uint, &buf, 128)!!, 2);
	test::eq(buf[:2], (char[]){ 0x80, 0x01 });
}

struct Case
{
	uint value;
	char[] wire;
}

fn void test_known_encodings() @test
{
	char[10] buf;
	Case[] cases = {
		{ 0, { 0x00 } },
		{ 1, { 0x01 } },
		{ 127, { 0x7F } },
		{ 128, { 0x80, 0x01 } },
		{ 300, { 0xAC, 0x02 } },
		{ 16383, { 0xFF, 0x7F } },
		{ 16384, { 0x80, 0x80, 0x01 } },
		{ uint::max, { 0xFF, 0xFF, 0xFF, 0xFF, 0x0F } },
	};
	foreach (c : cases)
	{
		sz n = encode(uint, &buf, c.value)!!;
		test::eq(buf[:n], c.wire);
		test::eq(decode(uint, c.wire)!!.value, c.value);
		test::eq(decode(uint, c.wire)!!.len, c.wire.len);
		test::eq(len(c.wire)!!, c.wire.len);
	}
}

fn void test_zigzag_keeps_small_negatives_small() @test
{
	test::eq(zigzag((int)0), 0U);
	test::eq(zigzag((int)-1), 1U);
	test::eq(zigzag((int)1), 2U);
	test::eq(zigzag((int)-2), 3U);
	test::eq(zigzag((int)2), 4U);

	int[] edges = { 0, -1, 1, -2, 2, 1000, -1000, int::max, int::min };
	foreach (value : edges)
	{
		test::eq(unzigzag(int, zigzag(value)), value);
	}

	// Which is the whole point: -1 is one byte, not ten.
	char[10] buf;
	test::eq(encode(int, &buf, -1)!!, 1);
	test::eq(encode(long, &buf, -1)!!, 1);
	test::eq(encode(int, &buf, -100)!!, 2);
}

fn void test_round_trip_across_the_whole_range_of_a_type() @test
{
	char[10] buf;
	for (uint n = 0; n < 256; n++)
	{
		char value = (char)n;
		sz written = encode(char, &buf, value)!!;
		test::eq(written, encoded_len(char, value));
		Decoded{char} back = decode(char, buf[:written])!!;
		test::eq(back.value, value);
		test::eq(back.len, written);

		ichar signed = (ichar)value;
		sz signed_written = encode(ichar, &buf, signed)!!;
		test::eq(decode(ichar, buf[:signed_written])!!.value, signed);
	}
}

fn void test_wide_values() @test
{
	char[10] buf;
	ulong[] values = { 0, 1, uint::max, 1UL << 63, ulong::max };
	foreach (value : values)
	{
		sz written = encode(ulong, &buf, value)!!;
		test::eq(written, encoded_len(ulong, value));
		test::eq(decode(ulong, buf[:written])!!.value, value);
	}
	test::eq(encode(ulong, &buf, ulong::max)!!, 10);
}

fn void test_a_varint_in_the_middle_of_a_record() @test
{
	// Decoding reports its length, so the next field starts where it says.
	char[4] wire = { 0xAC, 0x02, 'h', 'i' };
	Decoded{uint} count = decode(uint, &wire)!!;
	test::eq(count.value, 300U);
	test::eq((String)wire[count.len..], "hi");
}

fn void test_truncated_and_oversized_input() @test
{
	// A trailing byte that still promises another one.
	test::@error(decode(uint, (char[]){ 0x80 }), UNEXPECTED_END);
	test::@error(decode(uint, (char[]){ 0xFF, 0xFF }), UNEXPECTED_END);
	test::@error(decode(uint, ""), UNEXPECTED_END);
	test::@error(len((char[]){ 0x80 }), UNEXPECTED_END);

	// More bits than the type can hold.
	test::@error(decode(char, (char[]){ 0x80, 0x80, 0x01 }), OVERFLOW);
	test::@error(decode(uint, (char[]){ 0xFF, 0xFF, 0xFF, 0xFF, 0x10 }), OVERFLOW);
	test::@error(decode(ulong, (char[]){ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02 }), OVERFLOW);

	char[1] buf;
	test::@error(encode(uint, &buf, 128), NO_SPACE_LEFT);
}

fn void test_redundant_encodings_decode_to_what_they_spell() @test
{
	// Padded out with bytes that add nothing; Protocol Buffers reads these.
	test::eq(decode(uint, (char[]){ 0x80, 0x00 })!!.value, 0U);
	test::eq(decode(uint, (char[]){ 0x81, 0x80, 0x00 })!!.value, 1U);
	test::eq(decode(uint, (char[]){ 0x81, 0x80, 0x00 })!!.len, 3);
	// But the value itself still has to fit.
	test::eq(decode(ulong, (char[]){ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 })!!.value, ulong::max);
}
