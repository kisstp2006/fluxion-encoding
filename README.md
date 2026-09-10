# Fluxion Encoding

Bytes to text and back, and the byte order in between. For C3 0.8. Six
pieces that fit together:

| Module | What it is |
| --- | --- |
| `base64` | RFC 4648 in both alphabets, padded or not, wrapped or not. Strict on the way in. |
| `hex` | Hex in either case, with separators either way, plus a hex dump for looking at binary. |
| `endian` | Fixed-width values in whichever byte order the format uses: one at a time, through a cursor, or as struct fields. |
| `varint` | Integers that cost one byte when they are small. Signed ones go through zigzag, so `-1` costs one byte too. |
| `bits` | Fields that are not a whole number of bytes wide. |
| `quantize` | Floats, angles, normals and rotations into those fields, each saying what it costs in precision. |

The two codecs share one shape, so swapping between them is a change of name
and nothing else:

| Call | What it does |
| --- | --- |
| `encode` / `decode` | Into a slice you own. No allocation. |
| `encode_alloc` / `decode_alloc` | Into fresh memory. You free it. |
| `encoded_len` / `decoded_len` | How much room a call needs. |
| `encode_stream` | Straight into an `OutStream`. |
| `is_valid` | Would decoding succeed? |

Nothing here allocates unless it takes an `Allocator`, and everything that
allocates documents who owns the result.

Identifiers live next door: [Fluxion Id](https://github.com/kisstp2006/fluxion-id)
mints the UUIDs an asset pipeline names things with. This library carries their
sixteen bytes and prints them; it does not define them.

## Install

The library is the `fluxion_encoding.c3l` directory in this repository. For a
checkout next to your project, add to `project.json`:

```json
"dependency-search-paths": ["../fluxion-encoding"],
"dependencies": ["fluxion_encoding"]
```

Then, in the code:

```c3
import fluxion::encoding;
```

## Tour

Every routine that takes options takes a struct, and every option is named so
that zero is the default: `{}` is "the defaults", `{ .no_padding = true }`
changes one thing. The options parameter can be left off altogether.

### base64

```c3
char[32] buf;
char[] text = base64::encode(&buf, "fluxion")!;   // "Zmx1eGlvbg=="

char[] token = base64::encode_alloc(allocator, payload, {
    .alphabet = URL_SAFE,
    .no_padding = true,      // the unpadded form JWTs use
});
defer free(token);
```

`encoded_len` and `decoded_len` are exact, so the no-allocation path never has
to guess:

```c3
char[] out = alloc::alloc_array(allocator, char, base64::encoded_len(bytes.len));
base64::encode(out, bytes)!;
```

Decoding is strict by default. It rejects characters outside the alphabet,
misplaced padding, truncated groups, and a final character carrying bits that
decoding would throw away - the last of those being how one string of bytes
ends up with several spellings:

```c3
base64::decode(&buf, "Zg==")!;   // "f"
base64::decode(&buf, "Zh==")!;   // NON_CANONICAL, same bytes
```

Loosen any of it through `DecodeOptions` when reading what someone else wrote.
`ignore_whitespace` is the one you will reach for most, because MIME and PEM
wrap their payload across lines:

```c3
String pem = "Zm9vYmFy\r\nZm9vYmFy\r\n";
base64::decode(&buf, pem, { .ignore_whitespace = true })!;
```

Encoding wraps too, so the round trip closes:

```c3
base64::encode(&buf, payload, { .line_length = 64, .line_ending = "\n" })!;
```

Faults say which thing went wrong: `INVALID_CHARACTER`, `INVALID_PADDING`,
`TRUNCATED`, `NON_CANONICAL`, and `sink::NO_SPACE_LEFT` for a destination that
is too small.

### hex

```c3
char[16] buf;
hex::encode(&buf, { 0xDE, 0xAD, 0xBE, 0xEF })!;                      // "deadbeef"
hex::encode(&buf, { 0xDE, 0xAD, 0xBE, 0xEF }, { .separator = ":" })!; // "de:ad:be:ef"
```

Encoding picks a case; decoding accepts either, and skips whatever you tell it
to, so a separated form survives the round trip:

```c3
hex::decode(&out, "de:ad:be:ef", { .separators = ":" })!;
hex::decode(&out, "de ad\nbe ef", { .ignore_whitespace = true })!;
```

When the length is known up front - a hash, a UUID, a key - `decode_fixed`
hands back an array by value, so there is nothing to allocate and nothing to
free:

```c3
char[4] key = hex::decode_fixed(4, "deadbeef")!;
```

And for looking at binary with your own eyes:

```c3
hex::dump(io::stdout(), bytes)!;
```

```
00000000  46 4c 55 58 00 02 00 01  05 6c 65 76 65 6c 00 00  |FLUX.....level..|
00000010  00 03 00 01 00 02 00 03                           |........|
```

`columns`, `base_offset`, `hide_offset`, `hide_ascii` and `letter_case` are
all options; `dump_alloc` returns the same thing as a string.

### endian

Three ways in, from smallest to largest.

**One value at a time.** Integers, floats and `bool` all go through the same
calls. The type is a `$`-parameter, because it decides how many bytes are
involved:

```c3
uint n = endian::read(uint, bytes[:4], BIG);
endian::write(float, out[:4], 1.5f, LITTLE);

endian::read_at(uint, bytes, 12, BIG)!;   // bounds-checked
endian::swap(0x12345678U);                // 0x78563412, floats too
```

**A cursor.** `WireReader` walks a buffer field by field, borrowing its
vocabulary from a text parser on purpose, because walking a binary header is
the same job as walking a line of text:

```c3
WireReader r = encoding::read(bytes, BIG);

r.expect_bytes("FLUX")!;
ushort version = r.take(ushort)!;
char[] name = r.take_bytes(r.take(char)!)!;
r.skip_to_alignment(4)!;
```

Everything it hands back is a value or a slice into the original input; it
never allocates and never copies. `peek` looks without moving, `save` and
`restore` back out of a reading that turned out wrong, and `take_in` overrides
the byte order for the one field in a format that disagrees with the rest of
it.

`WireWriter` is the mirror image, filling a buffer you own:

```c3
WireWriter w = encoding::write(&buf, BIG);

w.put_bytes("FLUX")!;
w.put(ushort, 2)!;
w.put_slice((ushort[]){ 1, 2, 3 })!;
w.pad_to_alignment(4, 0)!;

char[] record = w.written();
```

It is not an `OutStream`: it writes fixed-width binary fields into a slice of
a known size and stops at the end of it, which is what a packet or a file
header wants.

**Struct fields.** `Big{Type}` and `Little{Type}` store a value in a known
order, so a header can be described once and pointed straight at the bytes:

```c3
struct Header
{
    Big{uint} magic;
    Big{ushort} version;
    Big{ushort} flags;
}

Header* header = (Header*)bytes.ptr;
header.magic.get();     // converted on read, only if the host disagrees
```

The stored form is a byte array, so the struct has no padding and no alignment
of its own - `Header::size` is 8, exactly the bytes on the wire. To build one
as a literal, `endian::big(uint, 0x89504E47)` makes a field holding a value.

### varint

Seven bits of payload per byte, with the top bit saying whether another
follows - the LEB128 that DWARF, WebAssembly and Protocol Buffers use. Most
numbers in a save file or a packet are small, and this is what small costs:

```c3
char[10] buf;
varint::encode(uint, &buf, 300)!;      // 2 bytes, not 4
varint::encode(uint, &buf, 42)!;       // 1 byte
varint::encode(int, &buf, -1)!;        // 1 byte, via zigzag
```

Decoding reports how far it got, so a varint can sit in the middle of a
record:

```c3
Decoded{uint} count = varint::decode(uint, wire)!;
// count.value == 300, count.len == 2 - the next field starts at wire[2..]
```

`WireReader` and `WireWriter` have it built in, so a mixed record needs only
one cursor:

```c3
w.put_varint(uint, entity_id)!;
uint id = r.take_varint(uint)!;
```

### bits

A jump flag does not need a byte, and health that never passes 100 does not
need four:

```c3
char[8] buf;
BitPacker w = encoding::write_bits(&buf);

w.put_int(ushort, entity_id)!;                   // 16 bits
w.put(char, health, bits::needed(100))!;         //  7 bits
w.put_bool(jumping)!;                            //  1 bit
w.put(char, team, 2)!;                           //  2 bits
// 26 bits - four bytes, not six
```

`encoding::read_bits` takes them back out in the same order and the same
widths. Bits go most-significant first, within each byte and across bytes, so
a packet laid out here matches the way the field diagrams in a protocol
document read. A signed field read back at a narrow width is sign-extended
from that width, so four bits of `-3` come back as `-3`.

`save`/`restore`, `peek`, `align_to_byte` and `put_bytes`/`take_bytes` are all
there, so a bit stream can drop back to whole bytes for a payload and pick up
again after it.

### quantize

A position is not accurate to 32 bits and a player cannot see the difference.
Every codec here maps a float onto a small integer and back, and every one
says what that costs:

```c3
Range position = quantize::range(-500, 500, 16);
position.precision();          // 0.0076 - worst case, in metres

Angle heading = quantize::angle(12);           // radians, wrapped
NormalCodec facing = quantize::normal(10);     // a unit vector, 20 bits
RotationCodec rotation = quantize::rotation(9); // a quaternion, 29 bits
```

Each has a `put` and a `take` that go straight through a bit stream, so a
packet is written in the units you think in:

```c3
position.put(&w, transform.x)!;
heading.put(&w, transform.yaw)!;
rotation.put(&w, transform.orientation)!;   // { x, y, z, w }

float x = position.take(&r)!;
```

`Range` keeps both ends of its interval exactly representable, so a health bar
at zero and a throttle at one both survive. `angle` wraps instead of clamping,
because 2π and 0 are the same heading. `normal` folds the sphere onto an
octahedron, which spreads its precision evenly instead of bunching it at the
poles. `rotation` drops the largest of the four components and rebuilds it,
because a unit quaternion only has three degrees of freedom.

Quantizing is lossy on purpose - never round-trip a value through it and then
compare for equality.

## A packet, in as few bits as it will go

```c3
const Range POSITION = { .min = -500, .max = 500, .bit_count = 16 };
const Angle HEADING = { .bit_count = 12 };
const NormalCodec FACING = { .bit_count = 10 };
const RotationCodec ROTATION = { .bit_count = 9 };

char[64] buf;

// The header is byte-shaped.
WireWriter w = encoding::write(&buf, BIG);
w.put_bytes(&model_id)!;              // 16 bytes, minted by fluxion-id
w.put_varint(uint, entity_id)!;       // 2, not 4

// Everything after it is bit-shaped.
BitPacker bw = encoding::write_bits(buf[w.written().len..]);
foreach (axis : transform.position) POSITION.put(&bw, axis)!;   // 48 bits
HEADING.put(&bw, transform.yaw)!;                               // 12
FACING.put(&bw, transform.look)!;                               // 20
ROTATION.put(&bw, transform.orientation)!;                      // 29
bw.put(char, health, bits::needed(100))!;                       //  7
bw.put_bool(firing)!;                                           //  1
```

Thirty-three bytes, against sixty-six for the same fields at full width. Run
`c3c run demo` to watch it go out and come back.

## Everything together

```c3
// Build a record by hand.
char[64] buf;
WireWriter w = encoding::write(&buf, BIG);
w.put_bytes("FLUX")!;
w.put(ushort, 1)!;
w.put(uint, 0xDEADBEEF)!;

// Ship it as text.
char[] text = base64::encode_alloc(allocator, w.written(), {
    .alphabet = URL_SAFE,
    .no_padding = true,
});
defer free(text);           // "RkxVWAAB3q2-7w"

// Read it back.
char[] bytes = base64::decode_alloc(allocator, (String)text, { .alphabet = URL_SAFE })!;
defer free(bytes);

WireReader r = encoding::read(bytes, BIG);
r.expect_bytes("FLUX")!;
ushort version = r.take(ushort)!;   // 1
uint payload = r.take(uint)!;       // 0xDEADBEEF
```

## Build

```bash
c3c test          # run the test suite
c3c run demo      # build and run the demo tour
```

## Layout

```
fluxion_encoding.c3l/manifest.json   what a consumer's build reads
src/                                 the library, one module per file
examples/demo.c3                     the tour
project.json5                        this repository's own build: tests and the demo
```

## Requirements

C3 0.8.3.

## License

`SPDX-License-Identifier: CC0-1.0`

[CC0 1.0 Universal](LICENSE) - public domain dedication. Do whatever you like
with this, no attribution required.
