// SPDX-License-Identifier: CC0-1.0

// Bit-level packing: fields that are not a whole number of bytes wide.
//
// A player state does not need a byte for a jump flag and four for a health
// value that only ever reaches 100. `BitPacker` puts each field in exactly as
// many bits as it needs and `BitUnpacker` takes them back out in the same
// order. (`BitWriter` and `BitReader` are names `std::io` already uses, and
// packing is what these do.)
//
// Bits go most-significant first, within each byte and across bytes, so a
// packet here matches the field diagrams in a protocol document. The last byte
// is padded with zeros.
//
// The vocabulary is `endian`'s one level down: `put` and `take` name a type
// and a width, `save` and `restore` back out of a reading. Nothing allocates.
//
// Zig had `u2` and `u12` to name a field's width in its type. C3 has the
// eight-bit-multiple types only, so the width is always said out loud - a
// two-bit team is `put(char, team, 2)` - and a signed field read back at a
// narrow width is sign-extended from that width, so four bits of `-3` come
// back as `-3` and not as `13`.
module fluxion::encoding::bits;

// The input ran out before the field did.
faultdef UNEXPECTED_END;

// The destination has no room left for the field.
faultdef NO_SPACE_LEFT;

<*
 Bytes needed to hold `bit_count` bits.
*>
fn sz byte_len(sz bit_count)
{
	return (bit_count + 7) / 8;
}

<*
 How many bits it takes to hold every value from `0` to `max_value`. Zero
 still costs one bit, since a field has to be written to be read back.
*>
fn ushort needed(ulong max_value)
{
	return max_value == 0 ? 1 : (ushort)(64 - max_value.clz());
}

<*
 How many bits a `$Type` has: one for a `bool`, its size in bits otherwise.
*>
macro ushort @bit_size($Type) @const
{
	$switch $Type::kind:
		$case BOOL:
			return 1;
		$case SIGNED_INT:
		$case UNSIGNED_INT:
		$case FLOAT:
			return $Type::size * 8;
		$default:
			$error("fluxion-encoding: " +++ $Type::name +++ " cannot be packed into bits; use an integer, float or bool");
	$endswitch
}

macro typeid @unsigned_of($Type) @const @private
{
	$switch $Type::size:
		$case 1: return char::typeid;
		$case 2: return ushort::typeid;
		$case 4: return uint::typeid;
		$case 8: return ulong::typeid;
	$endswitch
}

// `value` as the bits it is made of, in a `ulong`.
macro ulong to_raw(value) @private
{
	var $Type = $Typeof(value);
	$switch $Type::kind:
		$case BOOL:
			return (ulong)(char)value;
		$case FLOAT:
			return (ulong)bitcast(value, $Typefrom(@unsigned_of($Type)));
		$default:
			return (ulong)($Typefrom(@unsigned_of($Type)))value;
	$endswitch
}

// The low `count` bits of `raw`, as a `$Type`. A signed type is sign-extended
// from bit `count`, so a narrow field means what it meant when it went in.
macro from_raw($Type, ulong raw, ushort count) @private
{
	$switch $Type::kind:
		$case BOOL:
			return raw != 0;
		$case FLOAT:
			return bitcast(($Typefrom(@unsigned_of($Type)))raw, $Type);
		$case SIGNED_INT:
			// Shift the field to the top of the word and back down again as a
			// signed number: the arithmetic shift drags the sign bit along.
			ushort spare = 64 - count;
			return ($Type)(((long)(raw << spare)) >> spare);
		$default:
			return ($Type)raw;
	$endswitch
}

// -------------------------------------------------------------------------
// BitPacker
// -------------------------------------------------------------------------

<*
 Packs fields into a buffer you own, bit by bit.

 The buffer need not arrive zeroed: each byte is cleared as it is reached.
*>
struct BitPacker
{
	char[] bytes;
	// Bits written so far.
	sz bit;
}

fn void BitPacker.init(&self, char[] bytes)
{
	*self = { .bytes = bytes };
}

<*
 The whole bytes written so far, including the part-filled last one, whose
 spare low bits are zero.
*>
fn char[] BitPacker.written(&self)
{
	return self.bytes[:byte_len(self.bit)];
}

<*
 Bits written so far.
*>
fn sz BitPacker.bits_written(&self)
{
	return self.bit;
}

<*
 Bits still free.
*>
fn sz BitPacker.remaining(&self)
{
	return self.bytes.len * 8 - self.bit;
}

fn bool BitPacker.is_full(&self)
{
	return self.remaining() == 0;
}

fn void BitPacker.reset(&self)
{
	self.bit = 0;
}

<*
 Write the low `count` bits of `value`. Bits above `count` are dropped, so
 the caller decides the width and the type only decides the meaning.

 @require count >= 1 && count <= @bit_size($Type) : "a field is between one bit and the type's width"
*>
macro void? BitPacker.put(&self, $Type, value, ushort count)
{
	if (self.remaining() < count) return NO_SPACE_LEFT~;
	self.put_raw(to_raw(($Type)value), count);
}

fn void BitPacker.put_raw(&self, ulong raw, ushort count)
{
	ushort left = count;
	while (left > 0)
	{
		sz index = self.bit / 8;
		ushort used = (ushort)(self.bit % 8);
		ushort free = 8 - used;
		ushort take = min(free, left);

		left -= take;
		// The next `take` bits of the value, counting from the top.
		ulong mask = (1UL << take) - 1;
		char chunk = (char)(raw >> left & mask);

		if (used == 0) self.bytes[index] = 0;
		self.bytes[index] |= chunk << (free - take);
		self.bit += take;
	}
}

<*
 Write every bit of a `$Type`, for a field that is its natural width.
*>
macro void? BitPacker.put_int(&self, $Type, value)
{
	return self.put($Type, value, @bit_size($Type));
}

<*
 One bit.
*>
fn void? BitPacker.put_bool(&self, bool value)
{
	return self.put(bool, value, 1);
}

<*
 Write `count` zero bits, as a reserved field or a spacer.
*>
fn void? BitPacker.put_zeroes(&self, sz count)
{
	if (self.remaining() < count) return NO_SPACE_LEFT~;
	sz left = count;
	while (left > 0)
	{
		sz take = min(left, 64);
		self.put_raw(0, (ushort)take);
		left -= take;
	}
}

<*
 Pad with zeros up to the next byte boundary, so raw bytes can follow.
*>
fn void? BitPacker.align_to_byte(&self)
{
	sz misaligned = self.bit % 8;
	if (misaligned != 0) self.put_zeroes(8 - misaligned)!;
}

<*
 Write whole bytes. Only valid on a byte boundary; call `align_to_byte` first
 if you are not sure you are on one.

 @require self.bit % 8 == 0 : "put_bytes off a byte boundary"
*>
fn void? BitPacker.put_bytes(&self, char[] bytes)
{
	if (self.remaining() < bytes.len * 8) return NO_SPACE_LEFT~;
	sz index = self.bit / 8;
	mem::copy(&self.bytes[index], bytes.ptr, bytes.len);
	self.bit += bytes.len * 8;
}

// -------------------------------------------------------------------------
// BitUnpacker
// -------------------------------------------------------------------------

<*
 Takes back what `BitPacker` put in, in the same order and the same widths.
*>
struct BitUnpacker
{
	char[] bytes;
	// Bits read so far.
	sz bit;
}

// An opaque cursor position, produced by `save` and consumed by `restore`.
alias Mark = sz;

fn void BitUnpacker.init(&self, char[] bytes)
{
	*self = { .bytes = bytes };
}

<*
 Bits not yet read.
*>
fn sz BitUnpacker.remaining(&self)
{
	return self.bytes.len * 8 - self.bit;
}

<*
 True once fewer than eight bits remain, which is all a `BitPacker` leaves
 behind as padding.
*>
fn bool BitUnpacker.is_at_end(&self)
{
	return self.remaining() < 8;
}

fn sz BitUnpacker.bits_read(&self)
{
	return self.bit;
}

fn Mark BitUnpacker.save(&self)
{
	return self.bit;
}

<*
 @require mark <= self.bytes.len * 8 : "a mark from another reader"
*>
fn void BitUnpacker.restore(&self, Mark mark)
{
	self.bit = mark;
}

fn void BitUnpacker.reset(&self)
{
	self.bit = 0;
}

<*
 Read `count` bits as a `$Type`.

 @require count >= 1 && count <= @bit_size($Type) : "a field is between one bit and the type's width"
*>
macro BitUnpacker.take(&self, $Type, ushort count)
{
	if (self.remaining() < count) return UNEXPECTED_END~;
	return from_raw($Type, self.take_raw(count), count);
}

fn ulong BitUnpacker.take_raw(&self, ushort count)
{
	ulong raw = 0;
	ushort left = count;
	while (left > 0)
	{
		sz index = self.bit / 8;
		ushort used = (ushort)(self.bit % 8);
		ushort free = 8 - used;
		ushort take_n = min(free, left);

		char mask = (char)((1 << take_n) - 1);
		char chunk = self.bytes[index] >> (free - take_n) & mask;

		left -= take_n;
		raw |= (ulong)chunk << left;
		self.bit += take_n;
	}
	return raw;
}

<*
 Read every bit of a `$Type`.
*>
macro BitUnpacker.take_int(&self, $Type)
{
	return self.take($Type, @bit_size($Type));
}

<*
 One bit.
*>
fn bool? BitUnpacker.take_bool(&self)
{
	return self.take(bool, 1);
}

<*
 Read `count` bits without advancing.
*>
macro BitUnpacker.peek(&self, $Type, ushort count)
{
	BitUnpacker copy = *self;
	return copy.take($Type, count);
}

fn void? BitUnpacker.skip(&self, sz count)
{
	if (self.remaining() < count) return UNEXPECTED_END~;
	self.bit += count;
}

<*
 Step over the padding to the next byte boundary.
*>
fn void? BitUnpacker.align_to_byte(&self)
{
	sz misaligned = self.bit % 8;
	if (misaligned != 0) self.skip(8 - misaligned)!;
}

<*
 Read whole bytes as they are. Only valid on a byte boundary; call
 `align_to_byte` first if you are not sure you are on one. The result is a
 slice into the input.

 @require self.bit % 8 == 0 : "take_bytes off a byte boundary"
*>
fn char[]? BitUnpacker.take_bytes(&self, sz n)
{
	if (self.remaining() < n * 8) return UNEXPECTED_END~;
	sz index = self.bit / 8;
	char[] taken = self.bytes[index:n];
	self.bit += n * 8;
	return taken;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn void test_byte_len_and_needed() @test
{
	test::eq(byte_len(0), 0);
	test::eq(byte_len(1), 1);
	test::eq(byte_len(8), 1);
	test::eq(byte_len(9), 2);

	test::eq(needed(0), (ushort)1);
	test::eq(needed(1), (ushort)1);
	test::eq(needed(2), (ushort)2);
	test::eq(needed(3), (ushort)2);
	test::eq(needed(100), (ushort)7);
	test::eq(needed(255), (ushort)8);
	test::eq(needed(ulong::max), (ushort)64);
}

fn void test_bits_land_most_significant_first() @test
{
	char[2] buf;
	BitPacker w;
	w.init(&buf);

	w.put_bool(true)!!; // 1
	w.put_bool(false)!!; // 0
	w.put(char, 0b110, 3)!!; // 110
	w.put_bool(true)!!; // 1

	// Six bits in, so the last two of the byte are padding.
	test::eq(w.bits_written(), 6);
	test::eq(w.written().len, 1);
	test::eq(buf[0], (char)0b1011_0100);
}

fn void test_a_field_wider_than_a_byte() @test
{
	char[4] buf;
	BitPacker w;
	w.init(&buf);

	w.put(char, 0b111, 3)!!;
	w.put(ushort, 0xABC, 12)!!; // straddles two byte boundaries
	test::eq(w.bits_written(), 15);

	BitUnpacker r;
	r.init(w.written());
	test::eq(r.take(char, 3)!!, (char)0b111);
	test::eq(r.take(ushort, 12)!!, (ushort)0xABC);
}

struct State
{
	ushort id;
	char health; // 0..100
	bool jumping;
	char team; // two bits
	ushort angle; // twelve bits
}

fn void test_round_trip_a_player_state() @test
{
	// The shape a game would actually send: a few small fields, packed.
	State sent = { .id = 4211, .health = 87, .jumping = true, .team = 2, .angle = 3000 };

	char[8] buf;
	BitPacker w;
	w.init(&buf);
	w.put_int(ushort, sent.id)!!;
	w.put(char, sent.health, needed(100))!!;
	w.put_bool(sent.jumping)!!;
	w.put(char, sent.team, 2)!!;
	w.put(ushort, sent.angle, 12)!!;

	// 16 + 7 + 1 + 2 + 12 = 38 bits, five bytes rather than seven.
	test::eq(w.bits_written(), 38);
	test::eq(w.written().len, 5);

	BitUnpacker r;
	r.init(w.written());
	test::eq(r.take_int(ushort)!!, sent.id);
	test::eq(r.take(char, needed(100))!!, sent.health);
	test::eq(r.take_bool()!!, sent.jumping);
	test::eq(r.take(char, 2)!!, sent.team);
	test::eq(r.take(ushort, 12)!!, sent.angle);
	test::@check(r.is_at_end());
}

fn void test_every_width_round_trips_at_every_offset() @test
{
	char[24] buf;
	for (ushort width = 1; width <= 32; width++)
	{
		for (ushort offset = 0; offset < 8; offset++)
		{
			// The top `width` bits of a fixed pattern, so the value always fits.
			uint value = 0xDEADBEEFU >> (32 - width);

			BitPacker w;
			w.init(&buf);
			if (offset != 0) w.put(char, 0, offset)!!;
			w.put(uint, value, width)!!;

			BitUnpacker r;
			r.init(w.written());
			if (offset != 0) r.take(char, offset)!!;
			test::eq(r.take(uint, width)!!, value);
		}
	}
}

fn void test_signed_float_and_bool_go_through_unchanged() @test
{
	char[16] buf;
	BitPacker w;
	w.init(&buf);

	w.put_bool(true)!!;
	w.put_int(short, -1234)!!;
	w.put_int(float, 1.5f)!!;
	w.put(ichar, -3, 4)!!; // a small signed field, four bits wide

	BitUnpacker r;
	r.init(w.written());
	test::@check(r.take_bool()!!);
	test::eq(r.take_int(short)!!, (short)-1234);
	test::eq(r.take_int(float)!!, 1.5f);
	// Four bits of -3 read back as a four-bit signed value: sign-extended
	// from bit four, not left as 13.
	test::eq(r.take(ichar, 4)!!, (ichar)-3);
}

fn void test_peek_save_and_restore() @test
{
	char[2] buf;
	BitPacker w;
	w.init(&buf);
	w.put(char, 5, 4)!!;
	w.put(char, 9, 4)!!;

	BitUnpacker r;
	r.init(w.written());
	test::eq(r.peek(char, 4)!!, (char)5);
	test::eq(r.bits_read(), 0);

	Mark mark = r.save();
	test::eq(r.take(char, 4)!!, (char)5);
	test::eq(r.take(char, 4)!!, (char)9);
	r.restore(mark);
	// The same eight bits read as one field instead of two.
	test::eq(r.take_int(char)!!, (char)0x59);
}

fn void test_alignment_and_raw_bytes() @test
{
	char[8] buf;
	BitPacker w;
	w.init(&buf);

	w.put(char, 0b101, 3)!!;
	w.align_to_byte()!!;
	test::eq(w.bits_written(), 8);
	w.put_bytes("hi")!!;
	test::eq(buf[0], (char)0b1010_0000);

	BitUnpacker r;
	r.init(w.written());
	test::eq(r.take(char, 3)!!, (char)0b101);
	r.align_to_byte()!!;
	test::eq((String)r.take_bytes(2)!!, "hi");
	test::@check(r.is_at_end());

	// Aligning when already on a boundary does nothing.
	r.align_to_byte()!!;
	test::eq(r.bits_read(), 24);
}

fn void test_running_out_of_room() @test
{
	char[1] buf;
	BitPacker w;
	w.init(&buf);
	w.put(char, 0, 6)!!;
	test::eq(w.remaining(), 2);
	test::@error(w.put(char, 0, 3), NO_SPACE_LEFT);
	// A refused write changes nothing.
	test::eq(w.bits_written(), 6);
	w.put(char, 3, 2)!!;
	test::@check(w.is_full());
	test::@error(w.put_bool(true), NO_SPACE_LEFT);

	BitUnpacker r;
	r.init(&buf);
	r.take(char, 6)!!;
	test::@error(r.take(char, 3), UNEXPECTED_END);
	test::@error(r.skip(3), UNEXPECTED_END);
	r.take(char, 2)!!;
	test::@error(r.take_bool(), UNEXPECTED_END);
}

fn void test_the_buffer_need_not_arrive_zeroed() @test
{
	char[2] buf;
	buf[..] = 0xFF;
	BitPacker w;
	w.init(&buf);
	w.put(char, 0, 4)!!;
	w.put(char, 0b1010, 4)!!;
	test::eq(buf[0], (char)0b0000_1010);

	// And the spare bits of a part-filled last byte are zero too.
	w.reset();
	buf[..] = 0xFF;
	w.put(char, 0b11, 2)!!;
	test::eq(w.written()[0], (char)0b1100_0000);
}

fn void test_put_zeroes_crosses_word_boundaries() @test
{
	char[16] buf;
	BitPacker w;
	w.init(&buf);
	w.put_bool(true)!!;
	w.put_zeroes(100)!!;
	test::eq(w.bits_written(), 101);

	BitUnpacker r;
	r.init(w.written());
	test::@check(r.take_bool()!!);
	for (int i = 0; i < 100; i++) test::@check(!r.take_bool()!!);
}
