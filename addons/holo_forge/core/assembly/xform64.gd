@tool
extends RefCounted
## Rigid transforms in doubles for the assembly (Holo Forge Phase 8, contract C1.3).
##
## An xform64 is a PackedFloat64Array of 12 in Godot's Transform3D layout: elements 0-2 are the
## basis column X (the image of the X axis), 3-5 the column Y, 6-8 the column Z and 9-11 the
## origin. Godot's Vector3, Basis and Transform3D are float32 in this build, so every assembly pose
## stays in these and becomes a Transform3D only at the edges (to_transform: viewport holders, the
## bake, inspect calls). Static functions, no state. Lengths in meters, angles in radians.

## How far a basis may be from orthonormal and right-handed and still count as a rigid turn
## (inverse() asserts it in debug builds; the solver's post-check uses it too).
const ORTHONORMAL_TOLERANCE := 1e-12
## A direction counts as a frame's X candidate only while |dot(candidate, Z)| stays below this
## (spec C2.2).
const FRAME_DOT_LIMIT := 0.9


static func identity() -> PackedFloat64Array:
	return PackedFloat64Array([1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0])


## a·b: b first, then a.
static func compose(a: PackedFloat64Array, b: PackedFloat64Array) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(12)
	for column in 4:
		var x := b[column * 3]
		var y := b[column * 3 + 1]
		var z := b[column * 3 + 2]
		out[column * 3] = a[0] * x + a[3] * y + a[6] * z
		out[column * 3 + 1] = a[1] * x + a[4] * y + a[7] * z
		out[column * 3 + 2] = a[2] * x + a[5] * y + a[8] * z
	out[9] += a[9]
	out[10] += a[10]
	out[11] += a[11]
	return out


## The inverse of a rigid transform: the transposed basis and the origin turned back.
static func inverse(a: PackedFloat64Array) -> PackedFloat64Array:
	assert(orthonormal_error(a) <= ORTHONORMAL_TOLERANCE, "xform64.inverse needs a rigid transform.")
	var out := PackedFloat64Array([
		a[0], a[3], a[6],
		a[1], a[4], a[7],
		a[2], a[5], a[8],
		0.0, 0.0, 0.0,
	])
	out[9] = -(a[0] * a[9] + a[1] * a[10] + a[2] * a[11])
	out[10] = -(a[3] * a[9] + a[4] * a[10] + a[5] * a[11])
	out[11] = -(a[6] * a[9] + a[7] * a[10] + a[8] * a[11])
	return out


## The point p (3 doubles) moved by a.
static func apply(a: PackedFloat64Array, p: PackedFloat64Array) -> PackedFloat64Array:
	return PackedFloat64Array([
		a[0] * p[0] + a[3] * p[1] + a[6] * p[2] + a[9],
		a[1] * p[0] + a[4] * p[1] + a[7] * p[2] + a[10],
		a[2] * p[0] + a[5] * p[1] + a[8] * p[2] + a[11],
	])


## The direction d (3 doubles) turned by a's basis (no translation).
static func apply_dir(a: PackedFloat64Array, d: PackedFloat64Array) -> PackedFloat64Array:
	return PackedFloat64Array([
		a[0] * d[0] + a[3] * d[1] + a[6] * d[2],
		a[1] * d[0] + a[4] * d[1] + a[7] * d[2],
		a[2] * d[0] + a[5] * d[1] + a[8] * d[2],
	])


## A Transform3D's float32 values as doubles (exact).
static func from_transform(t: Transform3D) -> PackedFloat64Array:
	return PackedFloat64Array([
		t.basis.x.x, t.basis.x.y, t.basis.x.z,
		t.basis.y.x, t.basis.y.y, t.basis.y.z,
		t.basis.z.x, t.basis.z.y, t.basis.z.z,
		t.origin.x, t.origin.y, t.origin.z,
	])


## The float32 Transform3D for a (only at the edges: holders, the bake, inspect calls).
static func to_transform(a: PackedFloat64Array) -> Transform3D:
	return Transform3D(Basis(Vector3(a[0], a[1], a[2]), Vector3(a[3], a[4], a[5]), Vector3(a[6], a[7], a[8])), Vector3(a[9], a[10], a[11]))


static func translation(x: float, y: float, z: float) -> PackedFloat64Array:
	return PackedFloat64Array([1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, x, y, z])


## A turn of r radians about X (right-handed).
static func rot_x(r: float) -> PackedFloat64Array:
	var c := cos(r)
	var s := sin(r)
	return PackedFloat64Array([1.0, 0.0, 0.0, 0.0, c, s, 0.0, -s, c, 0.0, 0.0, 0.0])


## A turn of r radians about Y (right-handed).
static func rot_y(r: float) -> PackedFloat64Array:
	var c := cos(r)
	var s := sin(r)
	return PackedFloat64Array([c, 0.0, -s, 0.0, 1.0, 0.0, s, 0.0, c, 0.0, 0.0, 0.0])


## A turn of r radians about Z (right-handed).
static func rot_z(r: float) -> PackedFloat64Array:
	var c := cos(r)
	var s := sin(r)
	return PackedFloat64Array([c, s, 0.0, -s, c, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0])


## A snap frame (spec C2.2): origin at origin, Z along z_dir, X the first of x_hint (when given),
## part X and part Y whose |dot(axis, Z)| < FRAME_DOT_LIMIT, projected onto the plane normal to Z;
## Y = Z × X. origin, z_dir and x_hint are 3 doubles. Empty when z_dir has no direction or a
## value is not finite.
static func frame(origin: PackedFloat64Array, z_dir: PackedFloat64Array, x_hint := PackedFloat64Array()) -> PackedFloat64Array:
	if origin.size() != 3 or z_dir.size() != 3:
		return PackedFloat64Array()
	var z := _unit(z_dir)
	if z.is_empty() or not (_finite(origin[0]) and _finite(origin[1]) and _finite(origin[2])):
		return PackedFloat64Array()
	var candidates: Array[PackedFloat64Array] = []
	if x_hint.size() == 3:
		var hint := _unit(x_hint)
		if not hint.is_empty():
			candidates.append(hint)
	candidates.append(PackedFloat64Array([1.0, 0.0, 0.0]))
	candidates.append(PackedFloat64Array([0.0, 1.0, 0.0]))
	var x := PackedFloat64Array()
	for candidate in candidates:
		var along := _dot(candidate, z)
		if absf(along) >= FRAME_DOT_LIMIT:
			continue
		x = _unit(PackedFloat64Array([candidate[0] - along * z[0], candidate[1] - along * z[1], candidate[2] - along * z[2]]))
		if not x.is_empty():
			break
	if x.is_empty():
		return PackedFloat64Array()
	var y := _cross(z, x)
	return PackedFloat64Array([x[0], x[1], x[2], y[0], y[1], y[2], z[0], z[1], z[2], origin[0], origin[1], origin[2]])


## The distance between the origins of a and b.
static func distance(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	var dx := b[9] - a[9]
	var dy := b[10] - a[10]
	var dz := b[11] - a[11]
	return sqrt(dx * dx + dy * dy + dz * dz)


## The angle (radians, 0..π) of the turn a⁻¹·b. Worked out from the turn's vector part and
## 1 + trace with atan2 (never acos), so small angles keep full precision; near a half turn,
## where both go to zero, from the quaternion taken off the largest diagonal entry instead.
static func angle_between(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	# r[i][j] = row i, column j of Aᵀ·B = column i of A · column j of B.
	var r := []
	for i in 3:
		var row := PackedFloat64Array()
		for j in 3:
			row.append(a[i * 3] * b[j * 3] + a[i * 3 + 1] * b[j * 3 + 1] + a[i * 3 + 2] * b[j * 3 + 2])
		r.append(row)
	var trace: float = r[0][0] + r[1][1] + r[2][2]
	var vx: float = r[2][1] - r[1][2]
	var vy: float = r[0][2] - r[2][0]
	var vz: float = r[1][0] - r[0][1]
	if 1.0 + trace > 1.0:
		# |v| = 2 sin θ and 1 + trace = 2 + 2 cos θ, so their ratio is tan(θ / 2).
		return 2.0 * atan2(sqrt(vx * vx + vy * vy + vz * vz), 1.0 + trace)
	# Shepperd: the quaternion from the largest diagonal entry, then θ = 2 atan2(|xyz|, |w|).
	var i := 0
	if r[1][1] > r[i][i]:
		i = 1
	if r[2][2] > r[i][i]:
		i = 2
	var j := (i + 1) % 3
	var k := (i + 2) % 3
	var s := sqrt(maxf(0.0, 1.0 + r[i][i] - r[j][j] - r[k][k])) * 2.0
	if s == 0.0:
		return 0.0
	var q := PackedFloat64Array([0.0, 0.0, 0.0])
	q[i] = s / 4.0
	q[j] = (r[j][i] + r[i][j]) / s
	q[k] = (r[k][i] + r[i][k]) / s
	var w: float = (r[k][j] - r[j][k]) / s
	return 2.0 * atan2(sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2]), absf(w))


## a with its basis made orthonormal and right-handed (X kept in direction, Y made normal to it,
## Z = X × Y); the origin is kept. Empty when the basis is degenerate.
static func orthonormalize(a: PackedFloat64Array) -> PackedFloat64Array:
	if a.size() != 12:
		return PackedFloat64Array()
	var x := _unit(PackedFloat64Array([a[0], a[1], a[2]]))
	if x.is_empty():
		return PackedFloat64Array()
	var y_in := PackedFloat64Array([a[3], a[4], a[5]])
	var along := _dot(y_in, x)
	var y := _unit(PackedFloat64Array([y_in[0] - along * x[0], y_in[1] - along * x[1], y_in[2] - along * x[2]]))
	if y.is_empty():
		return PackedFloat64Array()
	var z := _cross(x, y)
	return PackedFloat64Array([x[0], x[1], x[2], y[0], y[1], y[2], z[0], z[1], z[2], a[9], a[10], a[11]])


## True when a has 12 values and every one is finite.
static func is_finite(a: Variant) -> bool:
	return _finite_xform(a)


## is_finite() under a name of its own: inside this script a call to is_finite() reaches the
## global one for single floats.
static func _finite_xform(a: Variant) -> bool:
	if not (a is PackedFloat64Array) or (a as PackedFloat64Array).size() != 12:
		return false
	# v * 0 is 0 for a finite v and NaN for an infinite or NaN one, so one sum tells.
	var probe := 0.0
	for value: float in a:
		probe += value * 0.0
	return probe == 0.0


## How far a's basis is from a right-handed orthonormal one: the largest of the columns' squared
## length errors, their pairwise dot products and |det − 1|. INF when a is not a finite xform64.
static func orthonormal_error(a: Variant) -> float:
	if not _finite_xform(a):
		return INF
	var m: PackedFloat64Array = a
	var x0 := m[0]
	var x1 := m[1]
	var x2 := m[2]
	var y0 := m[3]
	var y1 := m[4]
	var y2 := m[5]
	var z0 := m[6]
	var z1 := m[7]
	var z2 := m[8]
	var worst := absf(x0 * x0 + x1 * x1 + x2 * x2 - 1.0)
	worst = maxf(worst, absf(y0 * y0 + y1 * y1 + y2 * y2 - 1.0))
	worst = maxf(worst, absf(z0 * z0 + z1 * z1 + z2 * z2 - 1.0))
	worst = maxf(worst, absf(x0 * y0 + x1 * y1 + x2 * y2))
	worst = maxf(worst, absf(y0 * z0 + y1 * z1 + y2 * z2))
	worst = maxf(worst, absf(z0 * x0 + z1 * x1 + z2 * x2))
	# det = (x × y) · z
	worst = maxf(worst, absf((x1 * y2 - x2 * y1) * z0 + (x2 * y0 - x0 * y2) * z1 + (x0 * y1 - x1 * y0) * z2 - 1.0))
	return worst


## A single double is finite.
static func _finite(x: float) -> bool:
	return not (is_nan(x) or is_inf(x))


static func _dot(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


static func _cross(a: PackedFloat64Array, b: PackedFloat64Array) -> PackedFloat64Array:
	return PackedFloat64Array([a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]])


## v scaled to length 1; empty when it has no length or is not finite.
static func _unit(v: PackedFloat64Array) -> PackedFloat64Array:
	var length := sqrt(_dot(v, v))
	if not _finite(length) or length <= 0.0:
		return PackedFloat64Array()
	return PackedFloat64Array([v[0] / length, v[1] / length, v[2] / length])
