// SPDX-License-Identifier: CC0-1.0

// Internal plumbing: the output sinks the codecs write through.
//
// `base64` and `hex` each have one encoding and one decoding routine, written
// against a sink rather than a destination: a `Buffer` to fill a slice the
// caller owns, a `Counter` to measure the output without producing it, or an
// `OutStream` to stream it. All three answer to `write_byte` and `write`,
// which is the whole interface a codec needs.
//
// In Zig the codec took the sink as `anytype`. In C3 the codec is a macro
// whose sink parameter has no declared type, which is the same idea: the
// compiler stamps out one copy of the routine per sink type it meets, and
// `out.write_byte(c)` resolves against whichever type that is. The two
// signatures here match `OutStream`'s exactly - `sz?` and `void?` - so the
// same macro body compiles against all three without a branch.
//
// C3 has no private modules, so this one is public by necessity; it is not
// part of the promised API.
module fluxion::encoding::sink;

// The destination has no room left. The codecs pass this straight through,
// so a caller sees `sink::NO_SPACE_LEFT` from `base64::encode` and
// `hex::decode` alike.
faultdef NO_SPACE_LEFT;

<*
 Fills a caller-owned slice, and refuses to write past the end of it.
*>
struct Buffer
{
	char[] out;
	sz len;
}

fn void Buffer.init(&self, char[] out)
{
	*self = { .out = out };
}

fn void? Buffer.write_byte(&self, char byte)
{
	if (self.len == self.out.len) return NO_SPACE_LEFT~;
	self.out[self.len] = byte;
	self.len++;
}

fn sz? Buffer.write(&self, char[] bytes)
{
	if (self.out.len - self.len < bytes.len) return NO_SPACE_LEFT~;
	mem::copy(&self.out[self.len], bytes.ptr, bytes.len);
	self.len += bytes.len;
	return bytes.len;
}

<*
 The bytes written so far.
*>
fn char[] Buffer.written(&self)
{
	return self.out[:self.len];
}

<*
 Counts what would have been written. It never fails, but the signatures
 still say `sz?` and `void?` so that it fits where a `Buffer` fits.
*>
struct Counter
{
	sz len;
}

fn void? Counter.write_byte(&self, char byte)
{
	self.len++;
}

fn sz? Counter.write(&self, char[] bytes)
{
	self.len += bytes.len;
	return bytes.len;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

import std::io;

fn void test_buffer_stops_at_the_end_of_its_slice() @test
{
	char[4] out;
	Buffer b;
	b.init(&out);

	b.write("ab")!!;
	b.write_byte('c')!!;
	test::eq((String)b.written(), "abc");

	test::@error(b.write("de"), NO_SPACE_LEFT);
	b.write_byte('d')!!;
	test::@error(b.write_byte('e'), NO_SPACE_LEFT);
	test::eq((String)b.written(), "abcd");
}

fn void test_counter_measures_without_storing() @test
{
	Counter c;
	c.write("hello")!!;
	c.write_byte('!')!!;
	test::eq(c.len, 6);
}

fn void test_an_outstream_answers_to_the_same_two_calls() @test
{
	// This is what lets the codecs stream: the sink interface is exactly
	// the two methods `OutStream` already demands, so a `DString` - which
	// implements it - is a sink too.
	DString s;
	s.init(mem);
	defer s.free();
	OutStream w = &s;
	w.write("hi")!!;
	w.write_byte('!')!!;
	test::eq(s.str_view(), "hi!");
}
