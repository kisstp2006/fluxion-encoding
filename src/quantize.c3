// SPDX-License-Identifier: CC0-1.0

// Floats into as few bits as the job actually needs.
//
// A position is not accurate to 32 bits and a player cannot see the
// difference. Every routine here maps a float onto a small integer and back,
// and says what that costs in precision:
//
//   `Range`        any interval, to any width
//   `unit`         `[0, 1]`, and `signed_unit` for `[-1, 1]`
//   `angle`        radians, wrapped, with both ends the same angle
//   `normal`       a unit vector as two numbers, via the octahedron
//   `rotation`     a quaternion as three, by dropping the largest component
//
// Each has a `put` and a `take` that go straight through a `BitPacker` or
// `BitUnpacker`, so a packet is written in the units you think in.
//
// Quantizing is lossy on purpose: what comes back is within the precision the
// width buys and no closer, so never round-trip a value and compare it for
// equality.
module fluxion::encoding::quantize;
import fluxion::encoding::bits;
import std::math;

// The widest field these routines will produce, so a `uint` always holds one.
const ushort MAX_BITS = 32;

// -------------------------------------------------------------------------
// Scalars
// -------------------------------------------------------------------------

<*
 An interval of the number line, divided into `1 << bit_count` levels.

 Both ends are exactly representable, which is what makes a `Range` safe for
 a value that means something at its limits - a health bar at zero, a
 throttle at one.
*>
struct Range
{
	float min;
	float max;
	ushort bit_count;
}

<*
 @require max > min : "an empty or backwards range"
 @require bit_count >= 1 && bit_count <= MAX_BITS : "a range is one to 32 bits wide"
*>
fn Range range(float min, float max, ushort bit_count)
{
	return { .min = min, .max = max, .bit_count = bit_count };
}

<*
 The number of distinct values, less one: the largest quantized value.
*>
fn uint Range.top(&self)
{
	return (uint)((1UL << self.bit_count) - 1);
}

<*
 The gap between one representable value and the next, which is also twice
 the worst-case error of a round trip.
*>
fn float Range.step(&self)
{
	return (self.max - self.min) / (float)self.top();
}

<*
 The furthest `decode(encode(x))` can land from `x`.
*>
fn float Range.precision(&self)
{
	return self.step() / 2;
}

<*
 Map `value` onto `bit_count` bits. Values outside the interval are clamped
 to its ends rather than wrapping.
*>
fn uint Range.encode(&self, float value)
{
	float clamped = math::clamp(value, self.min, self.max);
	float t = (clamped - self.min) / (self.max - self.min);
	return (uint)math::round(t * (float)self.top());
}

<*
 Map back. Values above `top` are clamped, so a corrupt packet lands inside
 the interval rather than outside it.
*>
fn float Range.decode(&self, uint quantized)
{
	float q = (float)min(quantized, self.top());
	return self.min + q / (float)self.top() * (self.max - self.min);
}

<*
 Encode `value` and write it.
*>
fn void? Range.put(&self, BitPacker* w, float value)
{
	return w.put(uint, self.encode(value), self.bit_count);
}

<*
 Read a value and decode it.
*>
fn float? Range.take(&self, BitUnpacker* r)
{
	return self.decode(r.take(uint, self.bit_count)!);
}

<*
 `[0, 1]` in `bit_count` bits.
*>
fn Range unit(ushort bit_count)
{
	return range(0, 1, bit_count);
}

<*
 `[-1, 1]` in `bit_count` bits.
*>
fn Range signed_unit(ushort bit_count)
{
	return range(-1, 1, bit_count);
}

// -------------------------------------------------------------------------
// Angles
// -------------------------------------------------------------------------

const float TAU = (float)math::PI * 2;

<*
 An angle in radians, wrapped into `[0, 2π)` and divided into
 `1 << bit_count` levels.

 Unlike a `Range`, both ends of the interval are the same angle, so no level
 is wasted on it and a heading wraps rather than clamping.
*>
struct Angle
{
	ushort bit_count;
}

<*
 @require bit_count >= 1 && bit_count <= MAX_BITS : "an angle is one to 32 bits wide"
*>
fn Angle angle(ushort bit_count)
{
	return { .bit_count = bit_count };
}

<*
 The number of distinct headings.
*>
fn ulong Angle.levels(&self)
{
	return 1UL << self.bit_count;
}

<*
 The angle between one heading and the next, in radians.
*>
fn float Angle.step(&self)
{
	return TAU / (float)self.levels();
}

<*
 The furthest a round trip can move an angle, in radians.
*>
fn float Angle.precision(&self)
{
	return self.step() / 2;
}

// `radians` brought into `[0, 2π)`. C3's `%` on floats keeps the sign of the
// dividend, as C's `fmod` does, so a negative angle needs one more turn.
fn float wrap(float radians) @private
{
	float wrapped = radians % TAU;
	return wrapped < 0 ? wrapped + TAU : wrapped;
}

fn uint Angle.encode(&self, float radians)
{
	float levels_f = (float)self.levels();
	float scaled = math::round(wrap(radians) / TAU * levels_f);
	// Rounding up from just under 2π lands on the level that is 0 again.
	return (uint)(scaled % levels_f);
}

fn float Angle.decode(&self, uint quantized)
{
	float levels_f = (float)self.levels();
	float q = (float)(quantized % self.levels());
	return q / levels_f * TAU;
}

fn void? Angle.put(&self, BitPacker* w, float radians)
{
	return w.put(uint, self.encode(radians), self.bit_count);
}

fn float? Angle.take(&self, BitUnpacker* r)
{
	return self.decode(r.take(uint, self.bit_count)!);
}

// -------------------------------------------------------------------------
// Unit vectors
// -------------------------------------------------------------------------

<*
 A unit vector squashed onto two numbers.
*>
struct Normal
{
	uint x;
	uint y;
}

<*
 A unit vector in `2 * bit_count` bits, by folding the sphere onto an
 octahedron and that onto a square.

 Spends its precision evenly over the sphere, unlike rebuilding the third
 component from two, which bunches up at the poles. Twelve bits a component
 is finer than a tenth of a degree.
*>
struct NormalCodec
{
	ushort bit_count;
}

<*
 @require bit_count >= 2 && bit_count <= MAX_BITS : "a normal is two to 32 bits a component"
*>
fn NormalCodec normal(ushort bit_count)
{
	return { .bit_count = bit_count };
}

fn Range NormalCodec.component(&self)
{
	return signed_unit(self.bit_count);
}

<*
 `v` must be a unit vector; a longer or shorter one is normalized first.
*>
fn Normal NormalCodec.encode(&self, float[3] v)
{
	float[3] n = normalized(v);
	float l1 = math::abs(n[0]) + math::abs(n[1]) + math::abs(n[2]);
	Range component = self.component();
	// A degenerate vector has no direction to keep; point it at +X.
	if (l1 == 0 || !math::is_finite(l1))
	{
		return { .x = component.encode(1), .y = component.encode(0) };
	}

	float px = n[0] / l1;
	float py = n[1] / l1;
	if (n[2] <= 0)
	{
		// Fold the lower half of the octahedron outwards.
		float fx = (1 - math::abs(py)) * sign_of(px);
		float fy = (1 - math::abs(px)) * sign_of(py);
		px = fx;
		py = fy;
	}

	return { .x = component.encode(px), .y = component.encode(py) };
}

fn float[3] NormalCodec.decode(&self, Normal n)
{
	Range component = self.component();
	float px = component.decode(n.x);
	float py = component.decode(n.y);

	float[3] v = { px, py, 1 - math::abs(px) - math::abs(py) };
	if (v[2] < 0)
	{
		float fx = (1 - math::abs(v[1])) * sign_of(v[0]);
		float fy = (1 - math::abs(v[0])) * sign_of(v[1]);
		v[0] = fx;
		v[1] = fy;
	}
	return normalized(v);
}

fn void? NormalCodec.put(&self, BitPacker* w, float[3] v)
{
	Normal n = self.encode(v);
	w.put(uint, n.x, self.bit_count)!;
	w.put(uint, n.y, self.bit_count)!;
}

fn float[3]? NormalCodec.take(&self, BitUnpacker* r)
{
	Normal n;
	n.x = r.take(uint, self.bit_count)!;
	n.y = r.take(uint, self.bit_count)!;
	return self.decode(n);
}

// `+1` for zero and positives, `-1` for negatives, so a component sitting
// exactly on an axis folds one way rather than becoming zero.
fn float sign_of(float value) @private
{
	return value >= 0 ? 1 : -1;
}

fn float[3] normalized(float[3] v) @private
{
	float length = math::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
	if (length == 0 || !math::is_finite(length)) return { 1, 0, 0 };
	return { v[0] / length, v[1] / length, v[2] / length };
}

// -------------------------------------------------------------------------
// Rotations
// -------------------------------------------------------------------------

<*
 A rotation with its largest component left out.
*>
struct Rotation
{
	// Which component was dropped: 0 is x, 1 is y, 2 is z, 3 is w.
	char largest;
	// The other three, in their original order.
	uint[3] values;
}

<*
 A unit quaternion in `2 + 3 * bit_count` bits, by dropping the component
 with the largest magnitude and rebuilding it from the other three.

 A unit quaternion has three degrees of freedom, so the fourth number is
 redundant; dropping the largest keeps the rest inside `±1/√2`, which is
 where the precision goes. Nine bits a component suits a character rotation.

 `q` is `{ x, y, z, w }` and must be a unit quaternion; anything else is
 normalized first.
*>
struct RotationCodec
{
	ushort bit_count;
}

// The largest a component can be once the biggest one is set aside.
const float BOUND = 0.70710678118654752440f;

<*
 @require bit_count >= 2 && bit_count <= MAX_BITS : "a rotation is two to 32 bits a component"
*>
fn RotationCodec rotation(ushort bit_count)
{
	return { .bit_count = bit_count };
}

<*
 Total bits: two to say which component was dropped, plus the rest.
*>
fn ushort RotationCodec.total_bits(&self)
{
	return 2 + 3 * self.bit_count;
}

fn Range RotationCodec.component(&self)
{
	return range(-BOUND, BOUND, self.bit_count);
}

fn Rotation RotationCodec.encode(&self, float[4] q)
{
	float[4] n = normalized_quat(q);

	char largest = 0;
	foreach (i, value : n)
	{
		if (math::abs(value) > math::abs(n[largest])) largest = (char)i;
	}

	// q and -q are the same rotation, so flip the sign to make the dropped
	// component positive and save having to store its sign.
	if (n[largest] < 0)
	{
		foreach (&value : n) *value = -*value;
	}

	Range component = self.component();
	Rotation out = { .largest = largest };
	sz slot = 0;
	foreach (i, value : n)
	{
		if (i == largest) continue;
		out.values[slot] = component.encode(value);
		slot++;
	}
	return out;
}

fn float[4] RotationCodec.decode(&self, Rotation r)
{
	Range component = self.component();

	float[4] q;
	float sum = 0;
	sz slot = 0;
	foreach (i, &value : q)
	{
		if (i == r.largest) continue;
		*value = component.decode(r.values[slot]);
		sum += *value * *value;
		slot++;
	}
	// The one left out was the largest, so it was positive after the flip.
	q[r.largest] = math::sqrt(math::max(0.0f, 1 - sum));
	return normalized_quat(q);
}

fn void? RotationCodec.put(&self, BitPacker* w, float[4] q)
{
	Rotation r = self.encode(q);
	w.put(char, r.largest, 2)!;
	foreach (value : r.values) w.put(uint, value, self.bit_count)!;
}

fn float[4]? RotationCodec.take(&self, BitUnpacker* reader)
{
	Rotation r;
	r.largest = reader.take(char, 2)!;
	foreach (&value : r.values) *value = reader.take(uint, self.bit_count)!;
	return self.decode(r);
}

fn float[4] normalized_quat(float[4] q) @private
{
	float length = math::sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
	if (length == 0 || !math::is_finite(length)) return { 0, 0, 0, 1 };
	return { q[0] / length, q[1] / length, q[2] / length, q[3] / length };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

// The angle between two unit vectors, in radians.
fn float angle_between(float[3] a, float[3] b)
{
	float dot = a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
	return math::acos(math::clamp(dot, -1.0f, 1.0f));
}

// How far apart two rotations are, in radians, allowing for q and -q being
// the same rotation.
fn float rotation_between(float[4] a, float[4] b)
{
	float dot = math::abs(a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3]);
	return 2 * math::acos(math::clamp(dot, -1.0f, 1.0f));
}

fn void test_range_keeps_both_ends_exact() @test
{
	Range health = range(0, 100, 7);
	test::eq(health.encode(0), 0U);
	test::eq(health.encode(100), 127U);
	test::eq(health.decode(0), 0.0f);
	test::eq(health.decode(127), 100.0f);
}

fn void test_range_round_trips_inside_its_own_precision() @test
{
	Range position = range(-1000, 1000, 16);
	test::@check(position.precision() < 0.02);

	for (float value = -1000; value <= 1000; value += 7.3f)
	{
		float back = position.decode(position.encode(value));
		test::@check(math::abs(back - value) <= position.precision());
	}
}

fn void test_range_clamps_rather_than_wrapping() @test
{
	Range r = range(0, 1, 8);
	test::eq(r.encode(-5), 0U);
	test::eq(r.encode(5), 255U);
	// A quantized value from a corrupt packet lands inside the interval.
	test::eq(r.decode(99999), 1.0f);
}

fn void test_unit_and_signed_unit() @test
{
	Range u = unit(8);
	test::eq(u.encode(0), 0U);
	test::eq(u.encode(1), 255U);

	Range s = signed_unit(8);
	test::eq(s.encode(-1), 0U);
	test::eq(s.encode(1), 255U);
	// Both ends being exact leaves an even number of levels, so the midpoint
	// falls between two of them: zero round-trips to within `precision`, not
	// to itself. The epsilon is there because it lands exactly on the bound.
	test::@check(math::abs(s.decode(s.encode(0))) <= s.precision() + 1e-6f);
}

fn void test_narrow_ranges_still_work() @test
{
	Range one_bit = range(0, 1, 1);
	test::eq(one_bit.encode(0.2f), 0U);
	test::eq(one_bit.encode(0.8f), 1U);
	test::eq(one_bit.decode(1), 1.0f);
}

fn void test_angle_wraps_at_both_ends() @test
{
	Angle heading = angle(8);
	test::eq(heading.levels(), 256UL);
	test::eq(heading.encode(0), 0U);
	// 2π is the same heading as 0, not one past the end.
	test::eq(heading.encode(TAU), 0U);
	test::eq(heading.encode(-TAU), 0U);
	test::eq(heading.encode((float)math::PI), 128U);
	// And a heading well outside one turn still lands somewhere sensible.
	test::eq(heading.encode(0.5f), heading.encode(0.5f + 4 * TAU));
}

fn void test_angle_round_trips_inside_its_own_precision() @test
{
	Angle heading = angle(12);
	test::@check(heading.precision() < 0.001);

	for (float radians = -10; radians < 10; radians += 0.017f)
	{
		float back = heading.decode(heading.encode(radians));
		float wanted = wrap(radians);
		// Both are in [0, 2π), so the distance may wrap around zero.
		float gap = math::min(math::abs(back - wanted), TAU - math::abs(back - wanted));
		test::@check(gap <= heading.precision() + 1e-6f, "radians %f", radians);
	}
}

fn void test_normals_keep_their_direction() @test
{
	NormalCodec codec = normal(12);
	float[3][] directions = {
		{ 1, 0, 0 },
		{ -1, 0, 0 },
		{ 0, 1, 0 },
		{ 0, -1, 0 },
		{ 0, 0, 1 },
		{ 0, 0, -1 },
		{ 0.577f, 0.577f, 0.577f },
		{ -0.577f, 0.577f, -0.577f },
		{ 0.1f, -0.9f, 0.42f },
	};
	foreach (v : directions)
	{
		float[3] back = codec.decode(codec.encode(v));
		// A tenth of a degree at twelve bits a component.
		test::@check(angle_between(normalized(v), back) < 0.002);
		// And what comes back is still a unit vector.
		float length = math::sqrt(back[0] * back[0] + back[1] * back[1] + back[2] * back[2]);
		test::eq_approx(length, 1.0, delta: 1e-5);
	}
}

fn void test_normals_spread_their_error_evenly() @test
{
	// The failure mode this encoding exists to avoid is precision bunching up
	// somewhere on the sphere, so sweep the whole of it.
	NormalCodec codec = normal(12);
	float worst = 0;

	for (int i = 0; i < 500; i++)
	{
		// A deterministic spiral over the sphere.
		float t = (float)i / 500;
		float z = 1 - 2 * t;
		float radius = math::sqrt(math::max(0.0f, 1 - z * z));
		float theta = (float)i * 2.39996f;
		float[3] v = { radius * math::cos(theta), radius * math::sin(theta), z };

		float gap = angle_between(normalized(v), codec.decode(codec.encode(v)));
		worst = math::max(worst, gap);
	}
	test::@check(worst < 0.002);
}

fn void test_a_degenerate_normal_gets_a_direction_rather_than_a_nan() @test
{
	NormalCodec codec = normal(10);
	float[3][] bad = { { 0, 0, 0 }, { float::nan, 0, 0 }, { float::inf, 1, 0 } };
	foreach (v : bad)
	{
		float[3] back = codec.decode(codec.encode(v));
		foreach (value : back) test::@check(!math::is_nan(value));
		// It points at +X, to within the precision the width buys.
		test::@check(angle_between({ 1, 0, 0 }, back) < 0.01);
	}
}

fn void test_rotations_keep_their_orientation() @test
{
	RotationCodec codec = rotation(9);
	test::eq(codec.total_bits(), (ushort)29);

	float[4][] rotations = {
		{ 0, 0, 0, 1 }, // identity
		{ 1, 0, 0, 0 }, // half turn about x
		{ 0, 0.7071f, 0, 0.7071f },
		{ -0.5f, 0.5f, -0.5f, 0.5f },
		{ 0.183f, 0.365f, 0.548f, 0.730f },
		{ 0, 0, 0, -1 }, // the identity spelled the other way
	};
	foreach (q : rotations)
	{
		float[4] back = codec.decode(codec.encode(q));
		test::@check(rotation_between(normalized_quat(q), back) < 0.02);
	}
}

fn void test_rotations_survive_whichever_component_is_largest() @test
{
	RotationCodec codec = rotation(10);
	// One rotation per dropped component, to exercise all four paths.
	float[4][] rotations = {
		{ 0.9f, 0.2f, 0.2f, 0.2f },
		{ 0.2f, 0.9f, 0.2f, 0.2f },
		{ 0.2f, 0.2f, 0.9f, 0.2f },
		{ 0.2f, 0.2f, 0.2f, 0.9f },
		{ -0.9f, 0.2f, 0.2f, 0.2f }, // and with the largest one negative
	};
	foreach (q : rotations)
	{
		Rotation encoded = codec.encode(q);
		float[4] back = codec.decode(encoded);
		test::@check(rotation_between(normalized_quat(q), back) < 0.01);
		// Whichever component was largest is the one left out.
		char largest = 0;
		float[4] n = normalized_quat(q);
		foreach (i, value : n)
		{
			if (math::abs(value) > math::abs(n[largest])) largest = (char)i;
		}
		test::eq(encoded.largest, largest);
	}
}

fn void test_a_degenerate_rotation_gets_the_identity_rather_than_a_nan() @test
{
	RotationCodec codec = rotation(9);
	float[4] back = codec.decode(codec.encode({ 0, 0, 0, 0 }));
	foreach (value : back) test::@check(!math::is_nan(value));
	test::@check(rotation_between(back, { 0, 0, 0, 1 }) < 0.01);
}

fn void test_a_whole_player_state_through_a_bit_stream() @test
{
	// What a game would actually send, and what it costs.
	Range position = range(-500, 500, 16);
	Angle heading = angle(12);
	NormalCodec look = normal(10);
	RotationCodec spin = rotation(9);

	char[32] buf;
	BitPacker w;
	w.init(&buf);

	position.put(&w, 12.5f)!!;
	position.put(&w, -300.25f)!!;
	position.put(&w, 0)!!;
	heading.put(&w, 1.75f)!!;
	look.put(&w, { 0, 0, 1 })!!;
	spin.put(&w, { 0, 0.7071f, 0, 0.7071f })!!;

	// 48 + 12 + 20 + 29 = 109 bits, fourteen bytes for a full transform.
	test::eq(w.bits_written(), 109);
	test::eq(w.written().len, 14);

	BitUnpacker r;
	r.init(w.written());
	test::eq_approx(position.take(&r)!!, 12.5, delta: position.precision());
	test::eq_approx(position.take(&r)!!, -300.25, delta: position.precision());
	test::eq_approx(position.take(&r)!!, 0.0, delta: position.precision());
	test::eq_approx(heading.take(&r)!!, 1.75, delta: heading.precision());
	test::@check(angle_between({ 0, 0, 1 }, look.take(&r)!!) < 0.01);
	test::@check(rotation_between({ 0, 0.7071f, 0, 0.7071f }, spin.take(&r)!!) < 0.02);
	test::@check(r.is_at_end());
}

fn void test_wider_fields_buy_proportionally_more_precision() @test
{
	Range coarse = range(0, 1, 8);
	Range fine = range(0, 1, 16);
	test::@check(fine.precision() < coarse.precision() / 100);

	Angle coarse_angle = angle(8);
	Angle fine_angle = angle(16);
	test::@check(fine_angle.precision() < coarse_angle.precision() / 100);
}
