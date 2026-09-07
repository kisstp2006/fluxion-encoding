// SPDX-License-Identifier: CC0-1.0

//! Floats into as few bits as the job actually needs.
//!
//! A position is not accurate to 32 bits and a player cannot see the
//! difference, so sending one costs far more than it is worth. Every routine
//! here maps a float onto a small integer and back, and every one of them
//! tells you what that costs in precision:
//!
//!   `Range`       any interval, to any width
//!   `unit`        `[0, 1]`, and `signedUnit` for `[-1, 1]`
//!   `angle`       radians, wrapped, with both ends the same angle
//!   `normal`      a unit vector as two numbers, via the octahedron
//!   `rotation`    a quaternion as three, by dropping the largest component
//!
//! Each has a `put` and a `take` that go straight through a `bits.Writer` or
//! `bits.Reader`, so a packet is written in the units you think in.
//!
//! Quantizing is lossy on purpose. What comes back is within the precision
//! the width buys and no closer, so never round-trip a value through here and
//! then compare it for equality.

const std = @import("std");
const math = std.math;
const testing = std.testing;

const bits = @import("bits.zig");

/// The widest field these routines will produce, so a `u32` always holds one.
pub const max_bits: u16 = 32;

// -------------------------------------------------------------------------
// Scalars
// -------------------------------------------------------------------------

/// An interval of the number line, divided into `1 << bit_count` levels.
///
/// Both ends are exactly representable, which is what makes a `Range` safe for
/// a value that means something at its limits - a health bar at zero, a
/// throttle at one.
pub const Range = struct {
    min: f32,
    max: f32,
    bit_count: u16,

    pub fn init(min: f32, max: f32, bit_count: u16) Range {
        std.debug.assert(max > min);
        std.debug.assert(bit_count >= 1 and bit_count <= max_bits);
        return .{ .min = min, .max = max, .bit_count = bit_count };
    }

    /// The number of distinct values, less one: the largest quantized value.
    pub fn top(self: Range) u32 {
        return @intCast((@as(u64, 1) << @intCast(self.bit_count)) - 1);
    }

    /// The gap between one representable value and the next, which is also
    /// twice the worst-case error of a round trip.
    pub fn step(self: Range) f32 {
        return (self.max - self.min) / @as(f32, @floatFromInt(self.top()));
    }

    /// The furthest `decode(encode(x))` can land from `x`.
    pub fn precision(self: Range) f32 {
        return self.step() / 2;
    }

    /// Map `value` onto `bit_count` bits. Values outside the interval are
    /// clamped to its ends rather than wrapping.
    pub fn encode(self: Range, value: f32) u32 {
        const clamped = math.clamp(value, self.min, self.max);
        const t = (clamped - self.min) / (self.max - self.min);
        return @intFromFloat(@round(t * @as(f32, @floatFromInt(self.top()))));
    }

    /// Map back. Values above `top` are clamped, so a corrupt packet lands
    /// inside the interval rather than outside it.
    pub fn decode(self: Range, quantized: u32) f32 {
        const q: f32 = @floatFromInt(@min(quantized, self.top()));
        return self.min + q / @as(f32, @floatFromInt(self.top())) * (self.max - self.min);
    }

    /// Encode `value` and write it.
    pub fn put(self: Range, w: *bits.Writer, value: f32) bits.WriteError!void {
        return w.put(u32, self.encode(value), self.bit_count);
    }

    /// Read a value and decode it.
    pub fn take(self: Range, r: *bits.Reader) bits.ReadError!f32 {
        return self.decode(try r.take(u32, self.bit_count));
    }
};

/// `[0, 1]` in `bit_count` bits.
pub fn unit(bit_count: u16) Range {
    return .init(0, 1, bit_count);
}

/// `[-1, 1]` in `bit_count` bits.
pub fn signedUnit(bit_count: u16) Range {
    return .init(-1, 1, bit_count);
}

// -------------------------------------------------------------------------
// Angles
// -------------------------------------------------------------------------

pub const tau: f32 = math.tau;

/// An angle in radians, wrapped into `[0, 2π)` and divided into
/// `1 << bit_count` levels.
///
/// Unlike a `Range`, the two ends of the interval are the same angle, so no
/// level is wasted duplicating it - and a heading never has to be clamped,
/// because it wraps instead.
pub const Angle = struct {
    bit_count: u16,

    pub fn init(bit_count: u16) Angle {
        std.debug.assert(bit_count >= 1 and bit_count <= max_bits);
        return .{ .bit_count = bit_count };
    }

    /// The number of distinct headings.
    pub fn levels(self: Angle) u64 {
        return @as(u64, 1) << @intCast(self.bit_count);
    }

    /// The angle between one heading and the next, in radians.
    pub fn step(self: Angle) f32 {
        return tau / @as(f32, @floatFromInt(self.levels()));
    }

    /// The furthest a round trip can move an angle, in radians.
    pub fn precision(self: Angle) f32 {
        return self.step() / 2;
    }

    pub fn encode(self: Angle, radians: f32) u32 {
        const levels_f: f32 = @floatFromInt(self.levels());
        const wrapped = @mod(radians, tau);
        const scaled = @round(wrapped / tau * levels_f);
        // Rounding up from just under 2π lands on the level that is 0 again.
        return @intFromFloat(@mod(scaled, levels_f));
    }

    pub fn decode(self: Angle, quantized: u32) f32 {
        const levels_f: f32 = @floatFromInt(self.levels());
        const q: f32 = @floatFromInt(@mod(quantized, self.levels()));
        return q / levels_f * tau;
    }

    pub fn put(self: Angle, w: *bits.Writer, radians: f32) bits.WriteError!void {
        return w.put(u32, self.encode(radians), self.bit_count);
    }

    pub fn take(self: Angle, r: *bits.Reader) bits.ReadError!f32 {
        return self.decode(try r.take(u32, self.bit_count));
    }
};

/// Shorthand for `Angle.init`.
pub fn angle(bit_count: u16) Angle {
    return .init(bit_count);
}

// -------------------------------------------------------------------------
// Unit vectors
// -------------------------------------------------------------------------

/// A unit vector squashed onto two numbers.
pub const Normal = struct {
    x: u32,
    y: u32,
};

/// A unit vector in `2 * bit_count` bits, by folding the sphere onto an
/// octahedron and that onto a square.
///
/// Spends its precision evenly over the sphere, unlike storing two of the
/// three components and rebuilding the third, which bunches up at the poles.
/// Twelve bits a component is finer than a tenth of a degree, which is well
/// past what a normal or a look direction needs.
pub const NormalCodec = struct {
    bit_count: u16,

    pub fn init(bit_count: u16) NormalCodec {
        std.debug.assert(bit_count >= 2 and bit_count <= max_bits);
        return .{ .bit_count = bit_count };
    }

    fn component(self: NormalCodec) Range {
        return signedUnit(self.bit_count);
    }

    /// `v` must be a unit vector; a longer or shorter one is normalized first.
    pub fn encode(self: NormalCodec, v: [3]f32) Normal {
        const n = normalized(v);
        const l1 = @abs(n[0]) + @abs(n[1]) + @abs(n[2]);
        // A degenerate vector has no direction to keep; point it at +X.
        if (l1 == 0 or !math.isFinite(l1)) {
            const range = self.component();
            return .{ .x = range.encode(1), .y = range.encode(0) };
        }

        var px = n[0] / l1;
        var py = n[1] / l1;
        if (n[2] <= 0) {
            // Fold the lower half of the octahedron outwards.
            const fx = (1 - @abs(py)) * signOf(px);
            const fy = (1 - @abs(px)) * signOf(py);
            px = fx;
            py = fy;
        }

        const range = self.component();
        return .{ .x = range.encode(px), .y = range.encode(py) };
    }

    pub fn decode(self: NormalCodec, n: Normal) [3]f32 {
        const range = self.component();
        const px = range.decode(n.x);
        const py = range.decode(n.y);

        var v: [3]f32 = .{ px, py, 1 - @abs(px) - @abs(py) };
        if (v[2] < 0) {
            const fx = (1 - @abs(v[1])) * signOf(v[0]);
            const fy = (1 - @abs(v[0])) * signOf(v[1]);
            v[0] = fx;
            v[1] = fy;
        }
        return normalized(v);
    }

    pub fn put(self: NormalCodec, w: *bits.Writer, v: [3]f32) bits.WriteError!void {
        const n = self.encode(v);
        try w.put(u32, n.x, self.bit_count);
        try w.put(u32, n.y, self.bit_count);
    }

    pub fn take(self: NormalCodec, r: *bits.Reader) bits.ReadError![3]f32 {
        const n: Normal = .{
            .x = try r.take(u32, self.bit_count),
            .y = try r.take(u32, self.bit_count),
        };
        return self.decode(n);
    }
};

/// Shorthand for `NormalCodec.init`.
pub fn normal(bit_count: u16) NormalCodec {
    return .init(bit_count);
}

/// `+1` for zero and positives, `-1` for negatives, so a component sitting
/// exactly on an axis folds one way rather than becoming zero.
fn signOf(value: f32) f32 {
    return if (value >= 0) 1 else -1;
}

fn normalized(v: [3]f32) [3]f32 {
    const length = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (length == 0 or !math.isFinite(length)) return .{ 1, 0, 0 };
    return .{ v[0] / length, v[1] / length, v[2] / length };
}

// -------------------------------------------------------------------------
// Rotations
// -------------------------------------------------------------------------

/// A rotation with its largest component left out.
pub const Rotation = struct {
    /// Which component was dropped: 0 is x, 1 is y, 2 is z, 3 is w.
    largest: u2,
    /// The other three, in their original order.
    values: [3]u32,
};

/// A unit quaternion in `2 + 3 * bit_count` bits, by dropping the component
/// with the largest magnitude and rebuilding it from the other three.
///
/// A unit quaternion has only three degrees of freedom, so the fourth number
/// is redundant; dropping the largest one keeps the remaining three inside
/// `±1/√2`, which is where the precision goes. Nine bits a component is the
/// usual choice for a character's rotation.
///
/// `q` is `.{ x, y, z, w }` and must be a unit quaternion; a longer or shorter
/// one is normalized first.
pub const RotationCodec = struct {
    bit_count: u16,

    /// The largest a component can be once the biggest one is set aside.
    pub const bound: f32 = math.sqrt1_2;

    pub fn init(bit_count: u16) RotationCodec {
        std.debug.assert(bit_count >= 2 and bit_count <= max_bits);
        return .{ .bit_count = bit_count };
    }

    /// Total bits: two to say which component was dropped, plus the rest.
    pub fn totalBits(self: RotationCodec) u16 {
        return 2 + 3 * self.bit_count;
    }

    fn component(self: RotationCodec) Range {
        return .init(-bound, bound, self.bit_count);
    }

    pub fn encode(self: RotationCodec, q: [4]f32) Rotation {
        var n = normalizedQuat(q);

        var largest: u2 = 0;
        for (n, 0..) |value, i| {
            if (@abs(value) > @abs(n[largest])) largest = @intCast(i);
        }

        // q and -q are the same rotation, so flip the sign to make the
        // dropped component positive and save having to store its sign.
        if (n[largest] < 0) for (&n) |*value| {
            value.* = -value.*;
        };

        const range = self.component();
        var out: Rotation = .{ .largest = largest, .values = undefined };
        var slot: usize = 0;
        for (n, 0..) |value, i| {
            if (i == largest) continue;
            out.values[slot] = range.encode(value);
            slot += 1;
        }
        return out;
    }

    pub fn decode(self: RotationCodec, r: Rotation) [4]f32 {
        const range = self.component();

        var q: [4]f32 = undefined;
        var sum: f32 = 0;
        var slot: usize = 0;
        for (&q, 0..) |*value, i| {
            if (i == r.largest) continue;
            value.* = range.decode(r.values[slot]);
            sum += value.* * value.*;
            slot += 1;
        }
        // The one left out was the largest, so it was positive after the flip.
        q[r.largest] = @sqrt(@max(0, 1 - sum));
        return normalizedQuat(q);
    }

    pub fn put(self: RotationCodec, w: *bits.Writer, q: [4]f32) bits.WriteError!void {
        const r = self.encode(q);
        try w.putInt(u2, r.largest);
        for (r.values) |value| try w.put(u32, value, self.bit_count);
    }

    pub fn take(self: RotationCodec, reader: *bits.Reader) bits.ReadError![4]f32 {
        var r: Rotation = .{ .largest = try reader.takeInt(u2), .values = undefined };
        for (&r.values) |*value| value.* = try reader.take(u32, self.bit_count);
        return self.decode(r);
    }
};

/// Shorthand for `RotationCodec.init`.
pub fn rotation(bit_count: u16) RotationCodec {
    return .init(bit_count);
}

fn normalizedQuat(q: [4]f32) [4]f32 {
    const length = @sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
    if (length == 0 or !math.isFinite(length)) return .{ 0, 0, 0, 1 };
    return .{ q[0] / length, q[1] / length, q[2] / length, q[3] / length };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

/// The angle between two unit vectors, in radians.
fn angleBetween(a: [3]f32, b: [3]f32) f32 {
    const dot = a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
    return math.acos(math.clamp(dot, -1, 1));
}

/// How far apart two rotations are, in radians, allowing for q and -q being
/// the same rotation.
fn rotationBetween(a: [4]f32, b: [4]f32) f32 {
    const dot = @abs(a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3]);
    return 2 * math.acos(math.clamp(dot, -1, 1));
}

test "Range keeps both ends exact" {
    const health = Range.init(0, 100, 7);
    try testing.expectEqual(@as(u32, 0), health.encode(0));
    try testing.expectEqual(@as(u32, 127), health.encode(100));
    try testing.expectEqual(@as(f32, 0), health.decode(0));
    try testing.expectEqual(@as(f32, 100), health.decode(127));
}

test "Range round-trips inside its own precision" {
    const position = Range.init(-1000, 1000, 16);
    try testing.expect(position.precision() < 0.02);

    var value: f32 = -1000;
    while (value <= 1000) : (value += 7.3) {
        const back = position.decode(position.encode(value));
        try testing.expect(@abs(back - value) <= position.precision());
    }
}

test "Range clamps rather than wrapping" {
    const range = Range.init(0, 1, 8);
    try testing.expectEqual(@as(u32, 0), range.encode(-5));
    try testing.expectEqual(@as(u32, 255), range.encode(5));
    // A quantized value from a corrupt packet lands inside the interval.
    try testing.expectEqual(@as(f32, 1), range.decode(99999));
}

test "unit and signedUnit" {
    const u = unit(8);
    try testing.expectEqual(@as(u32, 0), u.encode(0));
    try testing.expectEqual(@as(u32, 255), u.encode(1));

    const s = signedUnit(8);
    try testing.expectEqual(@as(u32, 0), s.encode(-1));
    try testing.expectEqual(@as(u32, 255), s.encode(1));
    // Both ends being exact leaves an even number of levels, so the midpoint
    // falls between two of them: zero round-trips to within `precision`, not
    // to itself. The epsilon is there because it lands exactly on the bound.
    try testing.expect(@abs(s.decode(s.encode(0))) <= s.precision() + 1e-6);
}

test "narrow ranges still work" {
    const one_bit = Range.init(0, 1, 1);
    try testing.expectEqual(@as(u32, 0), one_bit.encode(0.2));
    try testing.expectEqual(@as(u32, 1), one_bit.encode(0.8));
    try testing.expectEqual(@as(f32, 1), one_bit.decode(1));
}

test "Angle wraps at both ends" {
    const heading = angle(8);
    try testing.expectEqual(@as(u64, 256), heading.levels());
    try testing.expectEqual(@as(u32, 0), heading.encode(0));
    // 2π is the same heading as 0, not one past the end.
    try testing.expectEqual(@as(u32, 0), heading.encode(tau));
    try testing.expectEqual(@as(u32, 0), heading.encode(-tau));
    try testing.expectEqual(@as(u32, 128), heading.encode(math.pi));
    // And a heading well outside one turn still lands somewhere sensible.
    try testing.expectEqual(heading.encode(0.5), heading.encode(0.5 + 4 * tau));
}

test "Angle round-trips inside its own precision" {
    const heading = angle(12);
    try testing.expect(heading.precision() < 0.001);

    var radians: f32 = -10;
    while (radians < 10) : (radians += 0.017) {
        const back = heading.decode(heading.encode(radians));
        const wanted = @mod(radians, tau);
        // Both are in [0, 2π), so the distance may wrap around zero.
        const gap = @min(@abs(back - wanted), tau - @abs(back - wanted));
        try testing.expect(gap <= heading.precision() + 1e-6);
    }
}

test "normals keep their direction" {
    const codec = normal(12);
    const directions = [_][3]f32{
        .{ 1, 0, 0 },
        .{ -1, 0, 0 },
        .{ 0, 1, 0 },
        .{ 0, -1, 0 },
        .{ 0, 0, 1 },
        .{ 0, 0, -1 },
        .{ 0.577, 0.577, 0.577 },
        .{ -0.577, 0.577, -0.577 },
        .{ 0.1, -0.9, 0.42 },
    };
    for (directions) |v| {
        const back = codec.decode(codec.encode(v));
        // A tenth of a degree at twelve bits a component.
        try testing.expect(angleBetween(normalized(v), back) < 0.002);
        // And what comes back is still a unit vector.
        const length = @sqrt(back[0] * back[0] + back[1] * back[1] + back[2] * back[2]);
        try testing.expectApproxEqAbs(@as(f32, 1), length, 1e-5);
    }
}

test "normals spread their error evenly" {
    // The failure mode this encoding exists to avoid is precision bunching up
    // somewhere on the sphere, so sweep the whole of it.
    const codec = normal(12);
    var worst: f32 = 0;

    var i: usize = 0;
    while (i < 500) : (i += 1) {
        // A deterministic spiral over the sphere.
        const t = @as(f32, @floatFromInt(i)) / 500;
        const z = 1 - 2 * t;
        const radius = @sqrt(@max(0, 1 - z * z));
        const theta = @as(f32, @floatFromInt(i)) * 2.39996;
        const v: [3]f32 = .{ radius * @cos(theta), radius * @sin(theta), z };

        const gap = angleBetween(normalized(v), codec.decode(codec.encode(v)));
        worst = @max(worst, gap);
    }
    try testing.expect(worst < 0.002);
}

test "a degenerate normal gets a direction rather than a NaN" {
    const codec = normal(10);
    for ([_][3]f32{ .{ 0, 0, 0 }, .{ math.nan(f32), 0, 0 }, .{ math.inf(f32), 1, 0 } }) |bad| {
        const back = codec.decode(codec.encode(bad));
        for (back) |value| try testing.expect(!math.isNan(value));
        // It points at +X, to within the precision the width buys.
        try testing.expect(angleBetween(.{ 1, 0, 0 }, back) < 0.01);
    }
}

test "rotations keep their orientation" {
    const codec = rotation(9);
    try testing.expectEqual(@as(u16, 29), codec.totalBits());

    const rotations = [_][4]f32{
        .{ 0, 0, 0, 1 }, // identity
        .{ 1, 0, 0, 0 }, // half turn about x
        .{ 0, 0.7071, 0, 0.7071 },
        .{ -0.5, 0.5, -0.5, 0.5 },
        .{ 0.183, 0.365, 0.548, 0.730 },
        .{ 0, 0, 0, -1 }, // the identity spelled the other way
    };
    for (rotations) |q| {
        const back = codec.decode(codec.encode(q));
        try testing.expect(rotationBetween(normalizedQuat(q), back) < 0.02);
    }
}

test "rotations survive whichever component is largest" {
    const codec = rotation(10);
    // One rotation per dropped component, to exercise all four paths.
    const rotations = [_][4]f32{
        .{ 0.9, 0.2, 0.2, 0.2 },
        .{ 0.2, 0.9, 0.2, 0.2 },
        .{ 0.2, 0.2, 0.9, 0.2 },
        .{ 0.2, 0.2, 0.2, 0.9 },
        .{ -0.9, 0.2, 0.2, 0.2 }, // and with the largest one negative
    };
    for (rotations) |q| {
        const encoded = codec.encode(q);
        const back = codec.decode(encoded);
        try testing.expect(rotationBetween(normalizedQuat(q), back) < 0.01);
        // Whichever component was largest is the one left out.
        var largest: usize = 0;
        const n = normalizedQuat(q);
        for (n, 0..) |value, i| {
            if (@abs(value) > @abs(n[largest])) largest = i;
        }
        try testing.expectEqual(@as(u2, @intCast(largest)), encoded.largest);
    }
}

test "a degenerate rotation gets the identity rather than a NaN" {
    const codec = rotation(9);
    const back = codec.decode(codec.encode(.{ 0, 0, 0, 0 }));
    for (back) |value| try testing.expect(!math.isNan(value));
    try testing.expect(rotationBetween(back, .{ 0, 0, 0, 1 }) < 0.01);
}

test "a whole player state through a bit stream" {
    // What a game would actually send, and what it costs.
    const position = Range.init(-500, 500, 16);
    const heading = angle(12);
    const look = normal(10);
    const spin = rotation(9);

    var buf: [32]u8 = undefined;
    var w = bits.writer(&buf);

    try position.put(&w, 12.5);
    try position.put(&w, -300.25);
    try position.put(&w, 0);
    try heading.put(&w, 1.75);
    try look.put(&w, .{ 0, 0, 1 });
    try spin.put(&w, .{ 0, 0.7071, 0, 0.7071 });

    // 48 + 12 + 20 + 29 = 109 bits, fourteen bytes for a full transform.
    try testing.expectEqual(@as(usize, 109), w.bitsWritten());
    try testing.expectEqual(@as(usize, 14), w.written().len);

    var r = bits.reader(w.written());
    try testing.expectApproxEqAbs(@as(f32, 12.5), try position.take(&r), position.precision());
    try testing.expectApproxEqAbs(@as(f32, -300.25), try position.take(&r), position.precision());
    try testing.expectApproxEqAbs(@as(f32, 0), try position.take(&r), position.precision());
    try testing.expectApproxEqAbs(@as(f32, 1.75), try heading.take(&r), heading.precision());
    try testing.expect(angleBetween(.{ 0, 0, 1 }, try look.take(&r)) < 0.01);
    try testing.expect(rotationBetween(.{ 0, 0.7071, 0, 0.7071 }, try spin.take(&r)) < 0.02);
    try testing.expect(r.isAtEnd());
}

test "wider fields buy proportionally more precision" {
    const coarse = Range.init(0, 1, 8);
    const fine = Range.init(0, 1, 16);
    try testing.expect(fine.precision() < coarse.precision() / 100);

    const coarse_angle = angle(8);
    const fine_angle = angle(16);
    try testing.expect(fine_angle.precision() < coarse_angle.precision() / 100);
}
