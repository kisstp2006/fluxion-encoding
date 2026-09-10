// SPDX-License-Identifier: CC0-1.0

// Byte order: reading and writing fixed-width values in whichever one the
// format on the other side happens to use.
//
// Three ways in, from smallest to largest:
//
//   * `read` / `write`               one value at a known place in a buffer
//   * `WireReader` / `WireWriter`    a cursor that walks a buffer field by field
//   * `Big` / `Little`               a struct field that carries its own byte order
//
// Integers, floats and `bool` all go through the same calls. The type is a
// `$`-parameter - `r.take(uint)` - because it decides how many bytes to
// consume, and that has to be settled while the program is compiled.
//
// `WireReader` borrows a text parser's vocabulary on purpose - `peek`, `take`,
// `expect`, `save`, `restore` - because walking a binary header is the same
// job as walking a line of text. The names are `WireReader` and `WireWriter`
// rather than `Reader` and `Writer` so that they can sit in scope beside
// `BitPacker` and `BitUnpacker` from `bits` - and not `ByteReader`, which the
// standard library's `std::io` already owns.
module fluxion::encoding::endian;
import fluxion::encoding::varint;
import std::io;
import std::bits;

enum Endian
{
	LITTLE,
	BIG,
}

// The byte order of the machine this was compiled for.
const Endian NATIVE = env::BIG_ENDIAN ? BIG : LITTLE;

<*
 The one that is not `order`.
*>
fn Endian opposite(Endian order)
{
	return order == BIG ? LITTLE : BIG;
}

// The input ran out before the value did.
faultdef UNEXPECTED_END;

// The bytes were there, but not the ones that were expected.
faultdef UNEXPECTED_VALUE;

// The destination has no room left for the value.
faultdef NO_SPACE_LEFT;

// -------------------------------------------------------------------------
// Types on the wire
// -------------------------------------------------------------------------

<*
 How many bytes `$Type` occupies on the wire: a `bool` is one, an integer or
 a float is its size. Anything else is a compile error rather than a guess.
*>
macro sz @size_of($Type) @const
{
	$switch $Type::kind:
		$case BOOL:
			return 1;
		$case SIGNED_INT:
		$case UNSIGNED_INT:
		$case FLOAT:
			return $Type::size;
		$default:
			$error("fluxion-encoding: " +++ $Type::name +++ " has no byte-order representation; use an integer, float or bool");
	$endswitch
}

// The unsigned integer of the same width as `$Type`, which is what byte
// order is actually defined over. Returned as a typeid for `$Typefrom`.
macro typeid @bits_of($Type) @const @private
{
	$switch @size_of($Type):
		$case 1: return char::typeid;
		$case 2: return ushort::typeid;
		$case 4: return uint::typeid;
		$case 8: return ulong::typeid;
		$case 16: return uint128::typeid;
	$endswitch
}

macro to_bits(value) @private
{
	var $Type = $Typeof(value);
	$switch $Type::kind:
		$case BOOL:
			return (char)value;
		$case FLOAT:
			return bitcast(value, $Typefrom(@bits_of($Type)));
		$default:
			return ($Typefrom(@bits_of($Type)))value;
	$endswitch
}

macro from_bits($Type, bits) @private
{
	$switch $Type::kind:
		$case BOOL:
			return bits != 0;
		$case FLOAT:
			return bitcast(bits, $Type);
		$default:
			return ($Type)bits;
	$endswitch
}

<*
 `value` with its bytes reversed. Works on floats and `bool` as well as
 integers, which `bswap` alone does not.
*>
macro swap(value)
{
	var $Type = $Typeof(value);
	$if @size_of($Type) == 1:
		return value;
	$else
		return from_bits($Type, bits::bswap(to_bits(value)));
	$endif
}

<*
 Reinterpret a native-order `value` as `target` order.
*>
macro native_to(value, Endian target)
{
	return target == NATIVE ? value : swap(value);
}

<*
 Reinterpret a `source`-order `value` as native order. The same operation as
 `native_to`, named for the direction you are thinking in.
*>
macro to_native(value, Endian source)
{
	return source == NATIVE ? value : swap(value);
}

<*
 Reverse the bytes of every element of `values` in place, for when a whole
 array arrives in the wrong order.
*>
macro void swap_slice(values)
{
	foreach (&value : values) *value = swap(*value);
}

// -------------------------------------------------------------------------
// One value at a time
// -------------------------------------------------------------------------

<*
 Read a `$Type` from the front of `bytes`.

 @require bytes.len >= @size_of($Type) : "not enough bytes for the type"
*>
macro read($Type, char[] bytes, Endian order)
{
	var $Bits = $Typefrom(@bits_of($Type));
	$if @size_of($Type) == 1:
		return from_bits($Type, bytes[0]);
	$else
		$Bits bits = order == BIG
			? bitorder::load_be(($Bits*)bytes.ptr)
			: bitorder::load_le(($Bits*)bytes.ptr);
		return from_bits($Type, bits);
	$endif
}

<*
 Write a `$Type` into the front of `out`.

 @require out.len >= @size_of($Type) : "not enough room for the type"
*>
macro void write($Type, char[] out, value, Endian order)
{
	$if @size_of($Type) == 1:
		out[0] = (char)to_bits(($Type)value);
	$else
		if (order == BIG)
		{
			bitorder::store_be(out.ptr, to_bits(($Type)value));
		}
		else
		{
			bitorder::store_le(out.ptr, to_bits(($Type)value));
		}
	$endif
}

<*
 Read a `$Type` that starts at `offset`, checking that it fits.
*>
macro read_at($Type, char[] bytes, sz offset, Endian order)
{
	const SIZE = @size_of($Type);
	if (offset > bytes.len || bytes.len - offset < SIZE) return UNEXPECTED_END~;
	return read($Type, bytes[offset:SIZE], order);
}

<*
 Write a `$Type` starting at `offset`, checking that it fits.
*>
macro void? write_at($Type, char[] out, sz offset, value, Endian order)
{
	const SIZE = @size_of($Type);
	if (offset > out.len || out.len - offset < SIZE) return NO_SPACE_LEFT~;
	write($Type, out[offset:SIZE], value, order);
}

// -------------------------------------------------------------------------
// Fields that carry their own byte order
// -------------------------------------------------------------------------

<*
 A `Type` stored as raw bytes in a known order, so a header can be described
 as a struct and mapped straight onto the bytes of a file:

     struct Header
     {
         Big{uint} magic;
         Big{ushort} version;
         Big{ushort} flags;
     }

 The stored form is a byte array, so the struct has no padding and no
 alignment of its own, and `get` converts only when the host disagrees.

 `ORDER` is an enum constant, which a C3 generic accepts as readily as a
 type; `Big` and `Little` below are generic aliases that fix it.
*>
struct Field (Printable) <Type, ORDER>
{
	// The wire form. Read it through `get`, not directly. `Type::size` and not
	// `@size_of(Type)`: a `bool` is one byte either way, and a macro call in
	// the array size of a generic struct is more than c3c 0.8.3 will take.
	char[Type::size] bytes;
}

alias Big <Type> = Field{Type, Endian.BIG};
alias Little <Type> = Field{Type, Endian.LITTLE};

fn Type Field.get(&self)
{
	return read(Type, &self.bytes, ORDER);
}

fn void Field.set(&self, Type value)
{
	write(Type, &self.bytes, value, ORDER);
}

<*
 What `%s` prints: the value, not the bytes.
*>
fn sz? Field.to_format(&self, Formatter* f) @dynamic
{
	return f.printf("%s", self.get());
}

<*
 A field holding `value`, for building a header as a literal:

     Header h = { .magic = endian::big(uint, 0x89504E47), .version = endian::big(ushort, 1) };

 A macro rather than a method, because a method needs a value to be called
 on and this is what makes the value.
*>
macro big($Type, value)
{
	Big{$Type} field;
	field.set(($Type)value);
	return field;
}

macro little($Type, value)
{
	Little{$Type} field;
	field.set(($Type)value);
	return field;
}

// -------------------------------------------------------------------------
// WireReader
// -------------------------------------------------------------------------

<*
 A cursor over a byte slice, with a byte order attached.

 Everything it hands back is either a value or a slice into the original
 input; it never allocates and never copies. `save` and `restore` let you try
 a reading and back out of it.
*>
struct WireReader
{
	char[] bytes;
	// Offset of the next byte to be read.
	sz index;
	// The order `take` and `peek` use when no other is given.
	Endian order;
}

// An opaque cursor position, produced by `save` and consumed by `restore`.
alias Mark = sz;

fn void WireReader.init(&self, char[] bytes, Endian order)
{
	*self = { .bytes = bytes, .order = order };
}

// ---------------------------------------------------------------------
// Position
// ---------------------------------------------------------------------

fn bool WireReader.is_at_end(&self)
{
	return self.index >= self.bytes.len;
}

<*
 Bytes not yet read.
*>
fn sz WireReader.remaining(&self)
{
	return self.bytes.len - self.index;
}

<*
 The bytes not yet read.
*>
fn char[] WireReader.rest(&self)
{
	return self.bytes[self.index..];
}

fn Mark WireReader.save(&self)
{
	return self.index;
}

<*
 @require mark <= self.bytes.len : "a mark from another reader"
*>
fn void WireReader.restore(&self, Mark mark)
{
	self.index = mark;
}

fn void WireReader.reset(&self)
{
	self.index = 0;
}

fn void? WireReader.seek(&self, sz index)
{
	if (index > self.bytes.len) return UNEXPECTED_END~;
	self.index = index;
}

fn void? WireReader.skip(&self, sz n)
{
	if (self.remaining() < n) return UNEXPECTED_END~;
	self.index += n;
}

<*
 Skip forward to the next multiple of `alignment`, as a format with padded
 records needs between one record and the next.

 @require alignment != 0 : "alignment of zero"
*>
fn void? WireReader.skip_to_alignment(&self, sz alignment)
{
	sz misaligned = self.index % alignment;
	if (misaligned != 0) self.skip(alignment - misaligned)!;
}

// ---------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------

<*
 Read a `$Type` and advance past it.

 A macro method: the type parameter makes it one, and the compiler builds a
 `take` for each type it is called with. `r.take(uint)` reads as a call on
 the reader either way.
*>
macro WireReader.take(&self, $Type)
{
	return self.take_in($Type, self.order);
}

<*
 Read a `$Type` in an order of its own, for the one field in a format that
 disagrees with the rest of it.
*>
macro WireReader.take_in(&self, $Type, Endian order)
{
	const SIZE = @size_of($Type);
	if (self.remaining() < SIZE) return UNEXPECTED_END~;
	var value = read($Type, self.bytes[self.index:SIZE], order);
	self.index += SIZE;
	return value;
}

<*
 Read a `$Type` without advancing.
*>
macro WireReader.peek(&self, $Type)
{
	const SIZE = @size_of($Type);
	if (self.remaining() < SIZE) return UNEXPECTED_END~;
	return read($Type, self.bytes[self.index:SIZE], self.order);
}

<*
 Read `n` bytes as they are, and advance past them. The result is a slice
 into the input, so it lives exactly as long as the input does.
*>
fn char[]? WireReader.take_bytes(&self, sz n)
{
	if (self.remaining() < n) return UNEXPECTED_END~;
	char[] taken = self.bytes[self.index:n];
	self.index += n;
	return taken;
}

<*
 The same, with the length known at compile time, so the result is a pointer
 to an array rather than a slice - which a struct pointer can be cast from.
*>
macro WireReader.take_array(&self, $n)
{
	if (self.remaining() < $n) return UNEXPECTED_END~;
	char[$n]* taken = (char[$n]*)&self.bytes[self.index];
	self.index += $n;
	return taken;
}

<*
 Fill `dest` with consecutive values of its element type.
*>
macro void? WireReader.take_into(&self, dest)
{
	var $Type = $Typeof(dest[0]);
	if (self.remaining() < @size_of($Type) * dest.len) return UNEXPECTED_END~;
	foreach (&slot : dest) *slot = self.take($Type)!;
}

<*
 Read a variable-length `$Type`, where a small number costs one byte. See
 `varint`; byte order does not come into it.
*>
macro WireReader.take_varint(&self, $Type)
{
	var decoded = varint::decode($Type, self.rest())!;
	self.index += decoded.len;
	return decoded.value;
}

<*
 Read a `$Type` and require it to equal `wanted`, for a version field or a
 magic number. The cursor advances either way.
*>
macro void? WireReader.expect(&self, $Type, wanted)
{
	var found = self.take($Type)!;
	if (found != ($Type)wanted) return UNEXPECTED_VALUE~;
}

<*
 Read and require a literal run of bytes, for a magic number that is really
 a string.
*>
fn void? WireReader.expect_bytes(&self, char[] wanted)
{
	char[] found = self.take_bytes(wanted.len)!;
	if (found != wanted) return UNEXPECTED_VALUE~;
}

// -------------------------------------------------------------------------
// WireWriter
// -------------------------------------------------------------------------

<*
 The mirror of `WireReader`: fixed-width values into a buffer you own.

 This is not an `OutStream`. It writes binary fields into a slice of a known
 size and stops at the end of it, which is what a packet or a file header
 wants.
*>
struct WireWriter
{
	char[] bytes;
	// Offset of the next byte to be written.
	sz index;
	// The order `put` uses when no other is given.
	Endian order;
}

fn void WireWriter.init(&self, char[] bytes, Endian order)
{
	*self = { .bytes = bytes, .order = order };
}

<*
 What has been written so far.
*>
fn char[] WireWriter.written(&self)
{
	return self.bytes[:self.index];
}

<*
 Room left.
*>
fn sz WireWriter.remaining(&self)
{
	return self.bytes.len - self.index;
}

fn bool WireWriter.is_full(&self)
{
	return self.index == self.bytes.len;
}

fn void WireWriter.reset(&self)
{
	self.index = 0;
}

<*
 Write a `$Type` and advance past it.
*>
macro void? WireWriter.put(&self, $Type, value)
{
	return self.put_in($Type, value, self.order);
}

<*
 Write a `$Type` in an order of its own.
*>
macro void? WireWriter.put_in(&self, $Type, value, Endian order)
{
	const SIZE = @size_of($Type);
	if (self.remaining() < SIZE) return NO_SPACE_LEFT~;
	write($Type, self.bytes[self.index:SIZE], value, order);
	self.index += SIZE;
}

<*
 Write a variable-length `$Type`, where a small number costs one byte. See
 `varint`; byte order does not come into it.
*>
macro void? WireWriter.put_varint(&self, $Type, value)
{
	if (catch varint::encode($Type, self.bytes[self.index..], value)) return NO_SPACE_LEFT~;
	self.index += varint::encoded_len($Type, value);
}

<*
 Write bytes as they are.
*>
fn void? WireWriter.put_bytes(&self, char[] bytes)
{
	if (self.remaining() < bytes.len) return NO_SPACE_LEFT~;
	mem::copy(&self.bytes[self.index], bytes.ptr, bytes.len);
	self.index += bytes.len;
}

<*
 Write consecutive values of the slice's element type.
*>
macro void? WireWriter.put_slice(&self, values)
{
	var $Type = $Typeof(values[0]);
	if (self.remaining() < @size_of($Type) * values.len) return NO_SPACE_LEFT~;
	foreach (value : values) self.put($Type, value)!;
}

<*
 Write `n` copies of `filler`.
*>
fn void? WireWriter.put_repeated(&self, char filler, sz n)
{
	if (self.remaining() < n) return NO_SPACE_LEFT~;
	self.bytes[self.index:n] = filler;
	self.index += n;
}

<*
 Pad with `filler` up to the next multiple of `alignment`.

 @require alignment != 0 : "alignment of zero"
*>
fn void? WireWriter.pad_to_alignment(&self, sz alignment, char filler)
{
	sz misaligned = self.index % alignment;
	if (misaligned != 0) self.put_repeated(filler, alignment - misaligned)!;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn void test_size_of_follows_the_type_not_the_machine() @test
{
	test::eq(@size_of(bool), 1);
	test::eq(@size_of(char), 1);
	test::eq(@size_of(int), 4);
	test::eq(@size_of(float), 4);
	test::eq(@size_of(double), 8);
	test::eq(@size_of(uint128), 16);
}

fn void test_read_and_write() @test
{
	char[4] bytes = { 0x12, 0x34, 0x56, 0x78 };
	test::eq(read(uint, &bytes, BIG), 0x12345678U);
	test::eq(read(uint, &bytes, LITTLE), 0x78563412U);

	char[4] out;
	write(uint, &out, 0x12345678, BIG);
	test::eq(out, bytes);
	write(uint, &out, 0x78563412, LITTLE);
	test::eq(out, bytes);
}

fn void test_signed_float_and_bool() @test
{
	char[8] buf;

	write(short, buf[:2], -2, BIG);
	test::eq(buf[:2], (char[]){ 0xFF, 0xFE });
	test::eq(read(short, buf[:2], BIG), (short)-2);

	write(float, buf[:4], 1.0f, BIG);
	test::eq(buf[:4], (char[]){ 0x3F, 0x80, 0x00, 0x00 });
	test::eq(read(float, buf[:4], BIG), 1.0f);

	write(double, buf[:8], -0.5, LITTLE);
	test::eq(read(double, buf[:8], LITTLE), -0.5);

	write(bool, buf[:1], true, BIG);
	test::eq(buf[0], (char)1);
	test::@check(read(bool, buf[:1], LITTLE));
}

fn void test_swap() @test
{
	test::eq(swap(0x12345678U), 0x78563412U);
	test::eq(swap((ushort)0xFF00), (ushort)0x00FF);
	// Floats too, which bswap will not take.
	test::eq(swap(swap(1.0f)), 1.0f);
	// And a single byte is its own swap.
	test::eq(swap((char)7), (char)7);

	ushort[2] values = { 0x0102, 0x0304 };
	swap_slice(values[..]);
	test::eq(values, (ushort[2]){ 0x0201, 0x0403 });
}

fn void test_native_to_and_to_native_round_trip() @test
{
	uint value = 0xDEADBEEF;
	test::eq(to_native(native_to(value, BIG), BIG), value);
	test::eq(to_native(native_to(value, LITTLE), LITTLE), value);
	test::eq(native_to(value, NATIVE), value);
	test::eq(opposite(NATIVE), NATIVE == LITTLE ? Endian.BIG : Endian.LITTLE);
}

fn void test_read_at_and_write_at_are_bounds_checked() @test
{
	char[6] buf;
	write_at(uint, &buf, 2, 0x11223344, BIG)!!;
	test::eq(buf, (char[6]){ 0, 0, 0x11, 0x22, 0x33, 0x44 });
	test::eq(read_at(uint, &buf, 2, BIG)!!, 0x11223344U);

	test::@error(read_at(uint, &buf, 3, BIG), UNEXPECTED_END);
	test::@error(read_at(uint, &buf, 99, BIG), UNEXPECTED_END);
	test::@error(write_at(uint, &buf, 3, 0, BIG), NO_SPACE_LEFT);
}

struct Header
{
	Big{uint} magic;
	Big{ushort} version;
	Little{ushort} flags;
}

fn void test_a_header_described_as_a_struct() @test
{
	// No padding: the struct is exactly the bytes on the wire.
	test::eq(Header::size, 8);

	char[8] wire = { 0x89, 'P', 'N', 'G', 0x00, 0x01, 0x02, 0x00 };
	Header* header = (Header*)&wire;
	test::eq(header.magic.get(), 0x89504E47U);
	test::eq(header.version.get(), (ushort)1);
	test::eq(header.flags.get(), (ushort)2);

	Header built = { .magic = big(uint, 0x89504E47), .version = big(ushort, 1), .flags = little(ushort, 2) };
	test::eq(((char*)&built)[:8], wire[..]);

	built.version.set(3);
	test::eq(built.version.get(), (ushort)3);
	@pool()
	{
		test::eq(string::tformat("v%s", built.version), "v3");
	};
}

fn void test_reader_walks_a_record() @test
{
	char[] wire = {
		'F', 'L', 'U', 'X', // magic
		0x00, 0x02, // version
		0x00, 0x00, 0x00, 0x2A, // count
		0x03, // name length
		'a', 'b', 'c', // name
	};

	WireReader r;
	r.init(wire, BIG);
	r.expect_bytes("FLUX")!!;
	test::eq(r.take(ushort)!!, (ushort)2);
	test::eq(r.take(uint)!!, 42U);

	char name_len = r.take(char)!!;
	test::eq((String)r.take_bytes(name_len)!!, "abc");
	test::@check(r.is_at_end());
	test::eq(r.remaining(), 0);
}

fn void test_reader_peek_save_and_restore() @test
{
	char[4] wire = { 0x00, 0x01, 0x00, 0x02 };
	WireReader r;
	r.init(&wire, BIG);

	// Peek does not move, so the same value comes back twice.
	test::eq(r.peek(ushort)!!, (ushort)1);
	test::eq(r.peek(ushort)!!, (ushort)1);
	test::eq(r.index, 0);

	Mark mark = r.save();
	test::eq(r.take(ushort)!!, (ushort)1);
	test::eq(r.take(ushort)!!, (ushort)2);
	r.restore(mark);
	// The same bytes read the other way round.
	test::eq(r.take_in(uint, LITTLE)!!, 0x02000100U);
}

fn void test_reader_stops_at_the_end() @test
{
	char[3] wire = { 0x01, 0x02, 0x03 };
	WireReader r;
	r.init(&wire, LITTLE);

	test::@error(r.take(uint), UNEXPECTED_END);
	// A failed read leaves the cursor where it was.
	test::eq(r.index, 0);

	test::eq(r.take(ushort)!!, (ushort)0x0201);
	test::@error(r.take(ushort), UNEXPECTED_END);
	test::@error(r.take_bytes(2), UNEXPECTED_END);
	test::@error(r.skip(2), UNEXPECTED_END);
	test::@error(r.seek(4), UNEXPECTED_END);
	test::eq(r.take(char)!!, (char)3);
}

fn void test_reader_expect_reports_the_mismatch() @test
{
	char[6] wire = { 'F', 'L', 'U', 'X', 0x00, 0x09 };
	WireReader r;
	r.init(&wire, BIG);
	test::@error(r.expect_bytes("RIFF"), UNEXPECTED_VALUE);

	r.reset();
	r.expect_bytes("FLUX")!!;
	test::@error(r.expect(ushort, 1), UNEXPECTED_VALUE);
}

fn void test_reader_take_into_and_alignment() @test
{
	char[10] wire = { 0x00, 0x01, 0x00, 0x02, 0x00, 0x03, 0xFF, 0xFF, 0x00, 0x07 };
	WireReader r;
	r.init(&wire, BIG);

	ushort[3] samples;
	r.take_into(samples[..])!!;
	test::eq(samples, (ushort[3]){ 1, 2, 3 });

	r.skip(2)!!; // over the 0xFFFF filler
	test::eq(r.take(ushort)!!, (ushort)7);

	// Alignment skips only when the cursor is not already on a boundary.
	r.reset();
	r.skip(1)!!;
	r.skip_to_alignment(4)!!;
	test::eq(r.index, 4);
	r.skip_to_alignment(4)!!;
	test::eq(r.index, 4);
}

fn void test_writer_builds_a_record_the_reader_can_read_back() @test
{
	char[16] buf;
	WireWriter w;
	w.init(&buf, BIG);

	w.put_bytes("FLUX")!!;
	w.put(ushort, 2)!!;
	w.put(uint, 42)!!;
	w.put(char, 3)!!;
	w.put_bytes("abc")!!;

	WireReader r;
	r.init(w.written(), BIG);
	r.expect_bytes("FLUX")!!;
	test::eq(r.take(ushort)!!, (ushort)2);
	test::eq(r.take(uint)!!, 42U);
	char name_len = r.take(char)!!;
	test::eq((String)r.take_bytes(name_len)!!, "abc");
	test::@check(r.is_at_end());
}

fn void test_writer_stops_at_the_end_of_its_buffer() @test
{
	char[4] buf;
	WireWriter w;
	w.init(&buf, LITTLE);

	w.put(ushort, 1)!!;
	test::eq(w.remaining(), 2);
	test::@error(w.put(uint, 1), NO_SPACE_LEFT);
	// A refused write changes nothing.
	test::eq(w.index, 2);

	w.put(ushort, 2)!!;
	test::@check(w.is_full());
	test::@error(w.put(char, 0), NO_SPACE_LEFT);
	test::eq(w.written(), (char[]){ 1, 0, 2, 0 });
}

fn void test_writer_padding_and_slices() @test
{
	char[16] buf;
	WireWriter w;
	w.init(&buf, BIG);

	w.put_bytes("ab")!!;
	w.pad_to_alignment(4, 0)!!;
	test::eq(w.index, 4);
	w.put_slice((ushort[]){ 1, 2 })!!;
	w.put_repeated(0xFF, 2)!!;
	test::eq(w.written(), (char[]){ 'a', 'b', 0, 0, 0x00, 0x01, 0x00, 0x02, 0xFF, 0xFF });

	w.reset();
	test::eq(w.written().len, 0);
}

fn void test_varints_sit_among_the_fixed_width_fields() @test
{
	char[16] buf;
	WireWriter w;
	w.init(&buf, BIG);

	w.put_bytes("FLUX")!!;
	w.put_varint(uint, 300)!!; // two bytes, not four
	w.put_varint(int, -1)!!; // one byte, not four
	w.put(ushort, 7)!!;
	test::eq(w.written().len, 9);

	WireReader r;
	r.init(w.written(), BIG);
	r.expect_bytes("FLUX")!!;
	test::eq(r.take_varint(uint)!!, 300U);
	test::eq(r.take_varint(int)!!, -1);
	test::eq(r.take(ushort)!!, (ushort)7);
	test::@check(r.is_at_end());
}

fn void test_a_varint_that_runs_off_the_end() @test
{
	char[1] buf;
	WireWriter w;
	w.init(&buf, BIG);
	test::@error(w.put_varint(uint, 128), NO_SPACE_LEFT);
	test::eq(w.index, 0);

	char[1] truncated = { 0x80 };
	WireReader r;
	r.init(&truncated, BIG);
	test::@error(r.take_varint(uint), varint::UNEXPECTED_END);
}

fn void test_mixed_byte_order_inside_one_record() @test
{
	// A real format that changed its mind: a big-endian header over a
	// little-endian payload.
	char[8] buf;
	WireWriter w;
	w.init(&buf, BIG);
	w.put(uint, 0x01020304)!!;
	w.put_in(uint, 0x01020304, LITTLE)!!;

	test::eq(w.written(), (char[]){ 0x01, 0x02, 0x03, 0x04, 0x04, 0x03, 0x02, 0x01 });

	WireReader r;
	r.init(w.written(), BIG);
	test::eq(r.take(uint)!!, 0x01020304U);
	test::eq(r.take_in(uint, LITTLE)!!, 0x01020304U);
}
