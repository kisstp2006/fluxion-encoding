# Fluxion Encoding

Bytes to text and back, and the byte order in between. For Zig 0.16.

| Module | What it is |
| --- | --- |
| `base64` | RFC 4648 in both alphabets, padded or not, wrapped or not. Strict on the way in. |
| `hex` | Hex in either case, with separators either way, plus a hex dump for looking at binary. |
| `endian` | Fixed-width values in whichever byte order the format uses: one at a time, through a cursor, or as struct fields. |

The two codecs share one shape, so swapping between them is a change of name
and nothing else:

| Call | What it does |
| --- | --- |
| `encode` / `decode` | Into a slice you own. No allocation. |
| `encodeAlloc` / `decodeAlloc` | Into fresh memory. You free it. |
| `encodedLen` / `decodedLen` | How much room a call needs. |
| `encodeWriter` | Straight into a `std.Io.Writer`. |
| `isValid` | Would decoding succeed? |

Nothing here allocates unless it takes an `Allocator`, and everything that
allocates documents who owns the result.

## Install

```bash
zig fetch --save git+https://github.com/kisstp2006/fluxion-encoding
```

Or, for a checkout next to your project, add to `build.zig.zon`:

```zig
.dependencies = .{
    .fluxion_encoding = .{ .path = "../fluxion-encoding" },
},
```

Either way, wire it up in `build.zig`:

```zig
const fluxion = b.dependency("fluxion_encoding", .{
    .target = target,
    .optimize = optimize,
});
exe_mod.addImport("fluxion_encoding", fluxion.module("fluxion_encoding"));
```

```zig
const enc = @import("fluxion_encoding");
```

## Tour

### base64

```zig
var buf: [32]u8 = undefined;
const text = try enc.base64.encode(&buf, "fluxion", .{});   // "Zmx1eGlvbg=="

const token = try enc.base64.encodeAlloc(gpa, payload, .{
    .alphabet = .url_safe,
    .padding = false,      // the unpadded form JWTs use
});
defer gpa.free(token);
```

`encodedLen` and `decodedLen` are exact, so the no-allocation path never has
to guess:

```zig
const out = try gpa.alloc(u8, enc.base64.encodedLen(bytes.len, .{}));
_ = try enc.base64.encode(out, bytes, .{});
```

Decoding is strict by default. It rejects characters outside the alphabet,
misplaced padding, truncated groups, and a final character carrying bits that
decoding would throw away — the last of those being how one string of bytes
ends up with several spellings:

```zig
enc.base64.decode(&buf, "Zg==", .{});   // "f"
enc.base64.decode(&buf, "Zh==", .{});   // error.NonCanonical, same bytes
```

Loosen any of it through `DecodeOptions` when reading what someone else wrote.
`ignore_whitespace` is the one you will reach for most, because MIME and PEM
wrap their payload across lines:

```zig
const pem = "Zm9vYmFy\r\nZm9vYmFy\r\n";
try enc.base64.decode(&buf, pem, .{ .ignore_whitespace = true });
```

Encoding wraps too, so the round trip closes:

```zig
enc.base64.encode(&buf, payload, .{ .line_length = 64, .line_ending = "\n" });
```

Errors say which thing went wrong: `InvalidCharacter`, `InvalidPadding`,
`Truncated`, `NonCanonical`, `NoSpaceLeft`.

### hex

```zig
var buf: [16]u8 = undefined;
try enc.hex.encode(&buf, &.{ 0xDE, 0xAD, 0xBE, 0xEF }, .{});                  // "deadbeef"
try enc.hex.encode(&buf, &.{ 0xDE, 0xAD, 0xBE, 0xEF }, .{ .separator = ":" }); // "de:ad:be:ef"
```

Encoding picks a case; decoding accepts either, and skips whatever you tell it
to, so a separated form survives the round trip:

```zig
try enc.hex.decode(&out, "de:ad:be:ef", .{ .separators = ":" });
try enc.hex.decode(&out, "de ad\nbe ef", .{ .ignore_whitespace = true });
```

When the length is known up front — a hash, a UUID, a key — `decodeFixed`
hands back an array by value, so there is nothing to allocate and nothing to
free:

```zig
const key = try enc.hex.decodeFixed(4, "deadbeef", .{});   // [4]u8
```

And for looking at binary with your own eyes:

```zig
try enc.hex.dump(writer, bytes, .{});
```

```
00000000  46 4c 55 58 00 02 00 01  05 6c 65 76 65 6c 00 00  |FLUX.....level..|
00000010  00 03 00 01 00 02 00 03                           |........|
```

`columns`, `base_offset`, `show_offset`, `show_ascii` and `case` are all
options; `dumpAlloc` returns the same thing as a string.

### endian

Three ways in, from smallest to largest.

**One value at a time.** Integers, floats and `bool` all go through the same
calls, and widths are whatever the type says — `u24` occupies three bytes, not
four, so bit-packed formats map straight onto Zig types:

```zig
const n = enc.endian.read(u32, bytes[0..4], .big);
enc.endian.write(f32, out[0..4], 1.5, .little);

try enc.endian.readAt(u32, bytes, 12, .big);   // bounds-checked
enc.endian.swap(@as(u32, 0x12345678));         // 0x78563412, floats too
```

**A cursor.** `Reader` walks a buffer field by field, borrowing its vocabulary
from a text parser on purpose, because walking a binary header is the same job
as walking a line of text:

```zig
var r = enc.read(bytes, .big);

try r.expectBytes("FLUX");
const version = try r.take(u16);
const name = try r.takeBytes(try r.take(u8));
try r.skipToAlignment(4);
```

Everything it hands back is a value or a slice into the original input; it
never allocates and never copies. `peek` looks without moving, `save` and
`restore` back out of a reading that turned out wrong, and `takeIn` overrides
the byte order for the one field in a format that disagrees with the rest of
it.

`Writer` is the mirror image, filling a buffer you own:

```zig
var w = enc.write(&buf, .big);

try w.putBytes("FLUX");
try w.put(u16, 2);
try w.putSlice(u16, &.{ 1, 2, 3 });
try w.padToAlignment(4, 0);

const record = w.written();
```

It is not a `std.Io.Writer`: it writes fixed-width binary fields into a slice
of a known size and stops at the end of it, which is what a packet or a file
header wants.

**Struct fields.** `Big(T)` and `Little(T)` store a value in a known order, so
a header can be described once and pointed straight at the bytes:

```zig
const Header = extern struct {
    magic: enc.Big(u32),
    version: enc.Big(u16),
    flags: enc.Big(u16),
};

const header: *const Header = @ptrCast(bytes[0..8]);
header.magic.get();     // converted on read, only if the host disagrees
```

The stored form is a byte array, so the struct has no padding and no alignment
of its own — `@sizeOf(Header)` is 8, exactly the bytes on the wire.

## Everything together

```zig
// Build a record by hand.
var buf: [64]u8 = undefined;
var w = enc.write(&buf, .big);
try w.putBytes("FLUX");
try w.put(u16, 1);
try w.put(u32, 0xDEADBEEF);

// Ship it as text.
const text = try enc.base64.encodeAlloc(gpa, w.written(), .{
    .alphabet = .url_safe,
    .padding = false,
});
defer gpa.free(text);       // "RkxVWAAB3q2-7w"

// Read it back.
const bytes = try enc.base64.decodeAlloc(gpa, text, .{ .alphabet = .url_safe });
defer gpa.free(bytes);

var r = enc.read(bytes, .big);
try r.expectBytes("FLUX");
const version = try r.take(u16);    // 1
const payload = try r.take(u32);    // 0xDEADBEEF
```

## Build

```bash
zig build test        # run the test suite
zig build example     # build and run the demo tour
zig build docs        # generate API docs into zig-out/docs
```

## Requirements

Zig 0.16.0.

## License

`SPDX-License-Identifier: CC0-1.0`

[CC0 1.0 Universal](LICENSE) — public domain dedication. Do whatever you like
with this, no attribution required.
