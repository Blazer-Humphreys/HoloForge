@tool
extends RefCounted
## Cage builders for the Form create tools: box, plane, cylinder, sphere, torus and quadball,
## each a valid cage in local coordinates with outward counter-clockwise faces. The caller moves
## it into the placement frame (form_ops.transform_vertices) and adds symmetry with
## primitive_symmetry(). Coordinates that should mirror are computed so they negate exactly.

const CAGE := preload("res://addons/holo_forge/core/form/cage.gd")
const FORM_OPS := preload("res://addons/holo_forge/core/form/form_ops.gd")


## Centred on the origin; counts = faces along x, y and z.
static func box(size: Vector3, counts: Vector3i) -> Dictionary:
	var n := [maxi(1, counts.x), maxi(1, counts.y), maxi(1, counts.z)]
	var s := [float(size.x), float(size.y), float(size.z)]
	var ids := {}
	var pos := PackedFloat64Array()
	for k in n[2] + 1:
		for j in n[1] + 1:
			for i in n[0] + 1:
				if i == 0 or i == n[0] or j == 0 or j == n[1] or k == 0 or k == n[2]:
					ids[Vector3i(i, j, k)] = pos.size() / 3
					pos.append(_grid(s[0], i, n[0]))
					pos.append(_grid(s[1], j, n[1]))
					pos.append(_grid(s[2], k, n[2]))
	var faces := []
	# [fixed axis, at the high end, u axis, v axis] with u x v pointing out.
	for side in [[0, 1, 1, 2], [0, 0, 2, 1], [1, 1, 2, 0], [1, 0, 0, 2], [2, 1, 0, 1], [2, 0, 1, 0]]:
		var a: int = side[0]
		var fixed: int = n[a] if side[1] == 1 else 0
		var ua: int = side[2]
		var va: int = side[3]
		for jv in n[va]:
			for ju in n[ua]:
				var quad := PackedInt32Array()
				for d in [[0, 0], [1, 0], [1, 1], [0, 1]]:
					var q := [0, 0, 0]
					q[a] = fixed
					q[ua] = ju + d[0]
					q[va] = jv + d[1]
					quad.append(ids[Vector3i(q[0], q[1], q[2])])
				faces.append(quad)
	return _cage(pos, faces)


## In XY, centred, normal +Z; counts = faces along x and y.
static func plane(size: Vector2, counts: Vector2i) -> Dictionary:
	var nx := maxi(1, counts.x)
	var ny := maxi(1, counts.y)
	var pos := PackedFloat64Array()
	for j in ny + 1:
		for i in nx + 1:
			pos.append(_grid(size.x, i, nx))
			pos.append(_grid(size.y, j, ny))
			pos.append(0.0)
	var faces := []
	for j in ny:
		for i in nx:
			var v := j * (nx + 1) + i
			faces.append(PackedInt32Array([v, v + 1, v + nx + 2, v + nx + 1]))
	return _cage(pos, faces)


## Axis +Z, base at z = 0; around faces around, rows faces up. caps: "pole" (a triangle fan
## round a centre vertex at each end), "ngon" (one n-gon each end) or "open".
static func cylinder(diameter: float, height: float, around: int, rows: int, caps := "pole") -> Dictionary:
	var n := maxi(3, around)
	var h := maxi(1, rows)
	var r := diameter * 0.5
	var pos := PackedFloat64Array()
	for ring in h + 1:
		var z := height * ring / h
		for k in n:
			var a := TAU * k / n
			pos.append(r * cos(a))
			pos.append(r * sin(a))
			pos.append(z)
	var faces := []
	for ring in h:
		for k in n:
			var v0 := ring * n + k
			var v1 := ring * n + (k + 1) % n
			faces.append(PackedInt32Array([v0, v1, v1 + n, v0 + n]))
	var top := h * n
	if caps == "pole":
		var pb := pos.size() / 3
		pos.append_array(PackedFloat64Array([0.0, 0.0, 0.0]))
		var pt := pb + 1
		pos.append_array(PackedFloat64Array([0.0, 0.0, height]))
		for k in n:
			faces.append(PackedInt32Array([pb, (k + 1) % n, k]))
		for k in n:
			faces.append(PackedInt32Array([pt, top + k, top + (k + 1) % n]))
	elif caps == "ngon":
		var bottom := PackedInt32Array()
		for k in n:
			bottom.append((n - k) % n)
		faces.append(bottom)
		var upper := PackedInt32Array()
		for k in n:
			upper.append(top + k)
		faces.append(upper)
	return _cage(pos, faces)


## Centred on the origin, poles on -Z and +Z closed by triangle fans; around faces around,
## rows bands from pole to pole.
static func sphere(diameter: float, around: int, rows: int) -> Dictionary:
	var n := maxi(3, around)
	var lat := maxi(2, rows)
	var r := diameter * 0.5
	var pos := PackedFloat64Array()
	for ring in range(1, lat):
		var phi := PI * ring / lat
		var z := -r * cos(phi)
		var rho := r * sin(phi)
		for k in n:
			var a := TAU * k / n
			pos.append(rho * cos(a))
			pos.append(rho * sin(a))
			pos.append(z)
	var faces := []
	for ring in lat - 2:
		for k in n:
			var v0 := ring * n + k
			var v1 := ring * n + (k + 1) % n
			faces.append(PackedInt32Array([v0, v1, v1 + n, v0 + n]))
	var pb := pos.size() / 3
	pos.append_array(PackedFloat64Array([0.0, 0.0, -r]))
	var pt := pb + 1
	pos.append_array(PackedFloat64Array([0.0, 0.0, r]))
	var top := (lat - 2) * n
	for k in n:
		faces.append(PackedInt32Array([pb, (k + 1) % n, k]))
	for k in n:
		faces.append(PackedInt32Array([pt, top + k, top + (k + 1) % n]))
	return _cage(pos, faces)


## In XY around Z: around faces round the ring, tube faces round the tube.
static func torus(major_diameter: float, minor_diameter: float, around: int, tube: int) -> Dictionary:
	var n1 := maxi(3, around)
	var n2 := maxi(3, tube)
	var big := major_diameter * 0.5
	var small := minor_diameter * 0.5
	var pos := PackedFloat64Array()
	for i in n1:
		var a := TAU * i / n1
		for j in n2:
			var b := TAU * j / n2
			var rho := big + small * cos(b)
			pos.append(rho * cos(a))
			pos.append(rho * sin(a))
			pos.append(small * sin(b))
	var faces := []
	for i in n1:
		for j in n2:
			var v00 := i * n2 + j
			var v10 := ((i + 1) % n1) * n2 + j
			var v11 := ((i + 1) % n1) * n2 + (j + 1) % n2
			var v01 := i * n2 + (j + 1) % n2
			faces.append(PackedInt32Array([v00, v10, v11, v01]))
	return _cage(pos, faces)


## A cube of span x span faces per side, its vertices pushed onto the sphere.
static func quadball(diameter: float, span: int) -> Dictionary:
	var s := maxi(1, span)
	var c := box(Vector3(2, 2, 2), Vector3i(s, s, s))
	var p: PackedFloat64Array = c.positions
	var r := diameter * 0.5
	for v in p.size() / 3:
		var x := p[3 * v]
		var y := p[3 * v + 1]
		var z := p[3 * v + 2]
		var l := sqrt(x * x + y * y + z * z)
		p[3 * v] = x / l * r
		p[3 * v + 1] = y / l * r
		p[3 * v + 2] = z / l * r
	c.positions = p
	return c


## Adds symmetry to a primitive already placed in frame. kind "mirror": one mirror per flagged
## axis of axes (plane through the frame origin, normal = that frame axis); kind "circular": one
## circular entry about the frame Z axis with circular_count copies. Maps are built
## geometrically and the partners snapped exactly onto each other. Returns the cage.
static func primitive_symmetry(c: Dictionary, kind: String, frame: Transform3D, axes: Vector3i, circular_count: int) -> Dictionary:
	var out := CAGE.copy(c)
	var sym: Array = out.symmetry
	var o := PackedFloat64Array([frame.origin.x, frame.origin.y, frame.origin.z])
	if kind == "mirror":
		# A float32 frame is only orthogonal to about 1e-7: square it up in doubles so the mirror
		# planes are exactly perpendicular and their partners agree.
		var axes_d := _orthonormal(frame.basis)
		for k in 3:
			if axes[k] == 0:
				continue
			sym.append({"type": "mirror", "origin": o.duplicate(), "normal": axes_d[k], "map": PackedInt32Array()})
	elif kind == "circular" and circular_count >= 2:
		sym.append({"type": "circular", "origin": o.duplicate(), "axis": _orthonormal(frame.basis)[2], "count": circular_count, "step": TAU / circular_count, "open": false, "map": PackedInt32Array()})
	if sym.is_empty():
		return out
	out.symmetry = sym
	var r: Dictionary = FORM_OPS.rebuild_symmetry(out, 0.0)
	out = r.cage
	var all := PackedInt32Array()
	for v in CAGE.vertex_count(out):
		all.append(v)
	return FORM_OPS.apply_symmetry(out, all).cage


## The basis columns made orthonormal in doubles (Gram-Schmidt from X, then Y; Z = X x Y).
static func _orthonormal(b: Basis) -> Array:
	var x := FORM_OPS.unit_d(PackedFloat64Array([b.x.x, b.x.y, b.x.z]))
	var y0 := PackedFloat64Array([b.y.x, b.y.y, b.y.z])
	var d := y0[0] * x[0] + y0[1] * x[1] + y0[2] * x[2]
	var y := FORM_OPS.unit_d(PackedFloat64Array([y0[0] - d * x[0], y0[1] - d * x[1], y0[2] - d * x[2]]))
	var z := PackedFloat64Array([x[1] * y[2] - x[2] * y[1], x[2] * y[0] - x[0] * y[2], x[0] * y[1] - x[1] * y[0]])
	var z0 := PackedFloat64Array([b.z.x, b.z.y, b.z.z])
	if z[0] * z0[0] + z[1] * z0[1] + z[2] * z0[2] < 0.0:
		z = PackedFloat64Array([-z[0], -z[1], -z[2]])
	return [x, y, FORM_OPS.unit_d(z)]


## s * (2i - n) / 2n: the grid coordinate, negating exactly for i and n - i.
static func _grid(s: float, i: int, n: int) -> float:
	return s * float(2 * i - n) / float(2 * n)


static func _cage(pos: PackedFloat64Array, faces: Array) -> Dictionary:
	var counts := PackedInt32Array()
	var idx := PackedInt32Array()
	for f in faces:
		counts.append((f as PackedInt32Array).size())
		idx.append_array(f)
	return CAGE.make(pos, counts, idx)
