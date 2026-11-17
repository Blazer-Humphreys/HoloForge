extends SceneTree
## Holo Forge Form native test (CadSubD, contract C3 of the Phase 6 work order): the cube cage's
## Catmull-Clark limit is sphere-like (radii 0.8395..0.8660) with exact limit points (+-0.5) and
## face centres (68/81); an infinitely sharp crease stays sharp on the limit and through
## conversion; conversion gives a closed valid solid by the direct shell build (volume 2.620419,
## matching a fine tessellation) for the cube, a pentagonal prism (n-gon sub-faces), a torus and
## two disjoint cubes, and an open surface for a plane; the tessellation keeps its contract
## (keys, canonical edge order, outward normals, CadShape winding); n-gon sub-face coordinates
## follow the documented layout; ray picking, visibility and closest points hit the limit surface;
## interpolate and fit solve exactly (and stay finite on the singular cube); B-rep projection and
## face grids; check_cage and set_cage report a non-manifold fan; timing ratios.
##
## godot --headless --path . --script res://tests/holo_forge_subd_native_test.gd

const TIMING := preload("res://tests/holo_forge_timing.gd")

## Timing ratio limits (5.6): 2 x the ratio measured on the dev machine on 2026-10-29 against a
## sphere make + tessellate calibration of 3.4 ms.
const LIMITS := {
	"set_cage_tessellate_1014": 8.8,     # measured 14.7-14.8 ms, ratio 4.32-4.39 (target 40 ms)
	"drag_frame_1014": 2.8,              # measured 4.7-4.8 ms at auto rate 12, ratio 1.37-1.38 (target 8 ms)
	"drag_frame_1014_drag_rate": 0.83,   # measured 1.4 ms at the drag rate 6, ratio 0.40-0.41
	"to_shapes_cube": 5.2,               # measured 8.9 ms at L6 with BRepCheck, ratio 2.59 (target 50 ms)
	"to_shapes_1014": 220.0,             # measured 381 ms at L6 with BRepCheck, ratio 110 (target 1.5 s)
}

const R_FACE := 68.0 / 81.0

var failures: Array[String] = []
var checked: Array[String] = []
var kernel


func _init() -> void:
	call_deferred("run")


func run() -> void:
	if not ClassDB.class_exists("CadSubD") or not ClassDB.class_exists("CadKernel"):
		print("NOTE: CadSubD is not registered (the holo_forge native DLL is missing): native subdivision checks skipped.")
		print("PASS holo_forge_subd_native: skipped, no native kernel.")
		quit(0)
		return
	kernel = ClassDB.instantiate("CadKernel")
	_check_sphere_limit()
	_check_exact_limits()
	_check_crease()
	_check_convert_cube()
	_check_ngons()
	_check_open_plane()
	_check_torus()
	_check_components()
	_check_tessellate_contract()
	_check_subfaces()
	_check_ray_and_visible()
	_check_closest_points()
	_check_interpolate()
	_check_fit()
	_check_project_and_grid()
	_check_bad_cages()
	_check_timing()
	if failures.is_empty():
		print("PASS holo_forge_subd_native: " + ", ".join(checked) + ".")
	else:
		print("FAIL holo_forge_subd_native")
	quit(0 if failures.is_empty() else 1)


# ---------------------------------------------------------------- cages (C1 literals)

func _cage(points: Array, faces: Array) -> Dictionary:
	var p := PackedFloat64Array()
	for v in points:
		p.append(float(v[0]))
		p.append(float(v[1]))
		p.append(float(v[2]))
	var fc := PackedInt32Array()
	var fi := PackedInt32Array()
	for f in faces:
		fc.append(f.size())
		for i in f:
			fi.append(i)
	return {"version": 1, "positions": p, "face_counts": fc, "face_indices": fi,
		"crease_edges": PackedInt32Array(), "crease_weights": PackedFloat32Array(),
		"corners": PackedInt32Array(), "corner_weights": PackedFloat32Array(),
		"frozen": PackedInt32Array(), "symmetry": [], "sym_isolated": PackedInt32Array(), "links": []}


## The cube cage [-1,1]^3: faces -Z, +Z, -Y, +X (face 3), +Y, -X, counter-clockwise from outside.
func _cube(offset := Vector3.ZERO) -> Dictionary:
	var pts := []
	for v in [[-1, -1, -1], [1, -1, -1], [1, 1, -1], [-1, 1, -1], [-1, -1, 1], [1, -1, 1], [1, 1, 1], [-1, 1, 1]]:
		pts.append([v[0] + offset.x, v[1] + offset.y, v[2] + offset.z])
	return _cage(pts, [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]])


## A cube with k x k quads per side over [-1,1]^3 (8 extraordinary corners), optionally with
## seeded per-vertex noise (the prototype's LCG, amplitude 0.6 / k).
func _grid_cube(k: int, noise_seed := -1) -> Dictionary:
	var ids := {}
	var pts := []
	var faces := []
	for f in 6:
		for b in k:
			for a in k:
				var q := [[a, b], [a + 1, b], [a + 1, b + 1], [a, b + 1]]
				var face := []
				for n in 4:
					var A: int = q[n][0]
					var B: int = q[n][1]
					var i := 0
					var j := 0
					var l := 0
					match f:
						0:
							i = k; j = A; l = B
						1:
							i = 0; l = A; j = B
						2:
							j = k; l = A; i = B
						3:
							j = 0; i = A; l = B
						4:
							l = k; i = A; j = B
						5:
							l = 0; j = A; i = B
					var key := Vector3i(i, j, l)
					if not ids.has(key):
						ids[key] = pts.size()
						pts.append([-1.0 + 2.0 * i / k, -1.0 + 2.0 * j / k, -1.0 + 2.0 * l / k])
					face.append(ids[key])
				faces.append(face)
	if noise_seed >= 0:
		var s: int = noise_seed
		for p in pts:
			for c in 3:
				s = (s * 1664525 + 1013904223) & 0xffffffff
				p[c] += (((s >> 8) & 0xffff) / 65535.0 - 0.5) * (0.6 / k)
	return _cage(pts, faces)


func _prism() -> Dictionary:
	var pts := []
	for z in 2:
		for i in 5:
			var a := TAU * i / 5.0
			pts.append([cos(a), sin(a), -1.0 if z == 0 else 1.0])
	var faces := [[4, 3, 2, 1, 0], [5, 6, 7, 8, 9]]
	for i in 5:
		var j := (i + 1) % 5
		faces.append([i, j, 5 + j, 5 + i])
	return _cage(pts, faces)


func _plane2() -> Dictionary:
	var pts := []
	for j in 3:
		for i in 3:
			pts.append([i - 1.0, j - 1.0, 0.0])
	var faces := []
	for j in 2:
		for i in 2:
			var a := j * 3 + i
			faces.append([a, a + 1, a + 4, a + 3])
	return _cage(pts, faces)


func _plane3() -> Dictionary:
	var pts := []
	for j in 4:
		for i in 4:
			pts.append([i - 1.5, j - 1.5, 0.1 * sin(i + 2.0 * j)])
	var faces := []
	for j in 3:
		for i in 3:
			var a := j * 4 + i
			faces.append([a, a + 1, a + 5, a + 4])
	return _cage(pts, faces)


func _torus(nu: int, nv: int) -> Dictionary:
	var pts := []
	for j in nv:
		for i in nu:
			var a := TAU * i / nu
			var b := TAU * j / nv
			pts.append([(1.0 + 0.4 * cos(b)) * cos(a), (1.0 + 0.4 * cos(b)) * sin(a), 0.4 * sin(b)])
	var faces := []
	for j in nv:
		for i in nu:
			var i1 := (i + 1) % nu
			var j1 := (j + 1) % nv
			faces.append([j * nu + i, j * nu + i1, j1 * nu + i1, j1 * nu + i])
	return _cage(pts, faces)


## The 8 x 4 sphere primitive: three rings of 8 on the unit sphere plus two poles (triangle fans).
func _sphere84() -> Dictionary:
	var pts := [[0.0, 0.0, 1.0]]
	for r in range(1, 4):
		var th := PI * r / 4.0
		for i in 8:
			var ph := TAU * i / 8.0
			pts.append([sin(th) * cos(ph), sin(th) * sin(ph), cos(th)])
	pts.append([0.0, 0.0, -1.0])
	var ring := func(r: int, i: int) -> int: return 1 + (r - 1) * 8 + (i % 8)
	var faces := []
	for i in 8:
		faces.append([0, ring.call(1, i), ring.call(1, i + 1)])
	for r in range(1, 3):
		for i in 8:
			faces.append([ring.call(r, i), ring.call(r + 1, i), ring.call(r + 1, i + 1), ring.call(r, i + 1)])
	for i in 8:
		faces.append([25, ring.call(3, i + 1), ring.call(3, i)])
	return _cage(pts, faces)


func _subd(cage: Dictionary):
	var s = ClassDB.instantiate("CadSubD")
	var ok: bool = s.set_cage(cage)
	_expect(ok, "set_cage should accept a valid cage (%s)." % s.get_last_error())
	return s


# ---------------------------------------------------------------- helpers

func _p3(a: PackedFloat64Array, i: int) -> Vector3:
	return Vector3(a[i * 3], a[i * 3 + 1], a[i * 3 + 2])


func _d3(a: PackedFloat64Array, i: int, x: float, y: float, z: float) -> float:
	return sqrt(pow(a[i * 3] - x, 2) + pow(a[i * 3 + 1] - y, 2) + pow(a[i * 3 + 2] - z, 2))


## Volume inside a tessellation by the divergence theorem (positive for outward surfaces).
func _mesh_volume(t: Dictionary) -> float:
	var p: PackedVector3Array = t.positions
	var idx: PackedInt32Array = t.indices
	var v := 0.0
	for k in range(0, idx.size(), 3):
		var a := p[idx[k]]
		var b := p[idx[k + 1]]
		var c := p[idx[k + 2]]
		v += float(a.x) * (float(b.y) * c.z - float(b.z) * c.y) + float(a.y) * (float(b.z) * c.x - float(b.x) * c.z) + float(a.z) * (float(b.x) * c.y - float(b.y) * c.x)
	return absf(v / 6.0)


func _canonical_edges(cage: Dictionary) -> PackedInt32Array:
	var out := PackedInt32Array()
	var seen := {}
	var counts: PackedInt32Array = cage.face_counts
	var idx: PackedInt32Array = cage.face_indices
	var o := 0
	for f in counts.size():
		var n: int = counts[f]
		for k in n:
			var a: int = idx[o + k]
			var b: int = idx[o + (k + 1) % n]
			var key := Vector2i(mini(a, b), maxi(a, b))
			if not seen.has(key):
				seen[key] = true
				out.append(key.x)
				out.append(key.y)
		o += n
	return out


## A small number in scientific notation (GDScript's % has no %g / %e).
func _g(x: float) -> String:
	if is_inf(x) or is_nan(x):
		return str(x)
	if x == 0.0:
		return "0"
	var e := floori(log(absf(x)) / log(10.0))
	if e >= -2 and e <= 4:
		return "%.4f" % x
	return "%.2fe%d" % [x / pow(10.0, e), e]


func _angle_deg(a: Vector3, b: Vector3) -> float:
	return rad_to_deg(a.angle_to(b))


func _winding_ok(t: Dictionary) -> bool:
	var p: PackedVector3Array = t.positions
	var nrm: PackedVector3Array = t.normals
	var idx: PackedInt32Array = t.indices
	if idx.is_empty():
		return false
	for k in range(0, idx.size(), 3):
		var p0 := p[idx[k]]
		var p1 := p[idx[k + 1]]
		var p2 := p[idx[k + 2]]
		# Godot front faces are clockwise from the front: (p2-p0)x(p1-p0) points out.
		var c := (p2 - p0).cross(p1 - p0)
		if c.length() > 1e-12 and c.dot(nrm[idx[k]]) <= 0.0:
			return false
	return true


# ---------------------------------------------------------------- 1, 2: limit values

func _check_sphere_limit() -> void:
	var s = _subd(_cube())
	var t: Dictionary = s.tessellate({"rate": 16})
	var p: PackedVector3Array = t.get("positions", PackedVector3Array())
	var rmin := INF
	var rmax := 0.0
	var worst := 0.0
	for v in p:
		var r := v.length()
		rmin = minf(rmin, r)
		rmax = maxf(rmax, r)
		worst = maxf(worst, absf(r - 0.852766) / 0.852766)
	print("subd: cube limit radii %.6f..%.6f over %d points, worst deviation %.3f%% from 0.852766" % [rmin, rmax, p.size(), worst * 100.0])
	_expect(p.size() == 6 * 17 * 17 and worst <= 0.02 and rmin >= 0.8394 and rmax <= 0.8661,
		"The cube cage's limit should be sphere-like: radii %.6f..%.6f (need 0.8394..0.8661, within 2%% of 0.852766)." % [rmin, rmax])
	checked.append("sphere-like cube limit (r %.4f..%.4f)" % [rmin, rmax])


func _check_exact_limits() -> void:
	var s = _subd(_cube())
	var lp: Dictionary = s.limit_points()
	var pos: PackedFloat64Array = lp.get("positions", PackedFloat64Array())
	var nrm: PackedVector3Array = lp.get("normals", PackedVector3Array())
	var worst := 0.0
	var outward := true
	for v in 8:
		var q := _p3(pos, v)
		for c in 3:
			worst = maxf(worst, absf(absf(pos[v * 3 + c]) - 0.5))
		outward = outward and nrm[v].dot(q) > 0.0
	_expect(pos.size() == 24 and worst <= 1e-9, "Every cube corner's limit should be (+-0.5, +-0.5, +-0.5) within 1e-9 (off by %s)." % _g(worst))
	_expect(outward, "Limit normals of the cube should point outward.")
	var e: Dictionary = s.evaluate(PackedInt32Array([3]), PackedVector2Array([Vector2(0.5, 0.5)]))
	var ep: PackedFloat64Array = e.get("positions", PackedFloat64Array())
	var err := _d3(ep, 0, R_FACE, 0.0, 0.0) if ep.size() == 3 else INF
	print("subd: corner limit error %s, +X face centre error %s" % [_g(worst), _g(err)])
	_expect(err <= 1e-9, "The +X face centre should evaluate to (68/81, 0, 0) within 1e-9 (off by %s)." % _g(err))
	# Bfr corner evaluation at the tessellation's approximation level 10 equals the exact limit.
	var t: Dictionary = s.tessellate({"rate": 4, "approx_level": 10})
	var tv: PackedVector3Array = t.vertices
	var corner_err := 0.0
	for v in 8:
		corner_err = maxf(corner_err, tv[v].distance_to(_p3(pos, v)))
	_expect(corner_err <= 1e-6, "Tessellation corner points should be the limit points (off by %s)." % _g(corner_err))
	checked.append("exact corners (+-0.5, err %s) and face centre 68/81 (err %s)" % [_g(worst), _g(err)])


# ---------------------------------------------------------------- 3, 4: creases

## Normals of faces 3 (+X) and 1 (+Z) at the midpoint of their shared edge (5, 6).
func _crease_angle(s) -> float:
	var e: Dictionary = s.evaluate(PackedInt32Array([3, 1]), PackedVector2Array([Vector2(0.5, 1.0), Vector2(1.0, 0.5)]))
	var n: PackedVector3Array = e.get("normals", PackedVector3Array())
	var p: PackedFloat64Array = e.get("positions", PackedFloat64Array())
	if n.size() != 2:
		return -1.0
	_expect(p.size() == 6 and _p3(p, 0).distance_to(_p3(p, 1)) < 1e-6, "Both faces should meet at the edge midpoint.")
	return _angle_deg(n[0], n[1])


func _check_crease() -> void:
	var smooth = _subd(_cube())
	var smooth_angle := _crease_angle(smooth)
	var cage := _cube()
	cage.crease_edges = PackedInt32Array([5, 6])
	cage.crease_weights = PackedFloat32Array([10.0])
	var creased = _subd(cage)
	var crease_angle := _crease_angle(creased)
	print("subd: normal jump across edge (5,6): smooth %.4f deg, creased %.3f deg" % [smooth_angle, crease_angle])
	_expect(smooth_angle >= 0.0 and smooth_angle <= 0.5, "Without a crease the limit should be smooth across the edge (%.3f deg)." % smooth_angle)
	_expect(crease_angle >= 60.0, "An infinitely sharp crease should stay sharp on the limit (%.2f deg, need >= 60)." % crease_angle)
	# Through conversion.
	var shapes: Array = creased.to_shapes({"isolation": 6, "name_prefix": "c"})
	var angle := -1.0
	if shapes.size() == 1:
		var shape = shapes[0]
		var e: Dictionary = creased.evaluate(PackedInt32Array([3]), PackedVector2Array([Vector2(0.5, 1.0)]))
		var mid := _p3(e.positions, 0)
		var fa: int = shape.find_face("c/f3")
		var fb: int = shape.find_face("c/f1")
		if fa >= 0 and fb >= 0:
			angle = _angle_deg(shape.face_normal_at(fa, mid), shape.face_normal_at(fb, mid))
	print("subd: converted crease normal jump %.3f deg" % angle)
	_expect(angle >= 60.0, "The crease should survive conversion (%.2f deg between faces c/f3 and c/f1)." % angle)
	checked.append("crease sharp on the limit (%.1f deg, smooth %.2f) and in the B-rep (%.1f deg)" % [crease_angle, smooth_angle, angle])


# ---------------------------------------------------------------- 5-10: conversion

func _check_convert_cube() -> void:
	var s = _subd(_cube())
	var shapes: Array = s.to_shapes({"isolation": 6, "name_prefix": "body1"})
	var report: Dictionary = s.get_last_report()
	_expect(shapes.size() == 1, "The cube should convert to one shape (%d; %s)." % [shapes.size(), s.get_last_error()])
	if shapes.size() != 1:
		return
	var shape = shapes[0]
	var comp: Dictionary = report.components[0]
	print("subd: cube convert report %s (%.1f ms)" % [comp, report.ms])
	_expect(comp.closed and comp.solid and comp.valid and comp.method == "direct",
		"The cube should convert by the direct build to a closed valid solid (%s)." % comp)
	_expect(shape.solid_count() == 1 and not shape.is_surface(), "The converted cube should be one solid.")
	var names: PackedStringArray = shape.get_face_names()
	var expected := PackedStringArray()
	for f in 6:
		expected.append("body1/f%d" % f)
	var sorted := names.duplicate()
	sorted.sort()
	_expect(shape.face_count() == 6 and sorted == expected, "The cube's faces should be named body1/f0..f5 (%s)." % names)
	var fine := _mesh_volume(s.tessellate({"rate": 64}))
	var vol: float = shape.volume()
	print("subd: cube volume %.7f (report %.7f), fine mesh %.7f, rel %s; vs 2.620419 rel %s" % [vol, comp.volume, fine, _g(absf(vol - fine) / fine), _g(absf(vol - 2.620419) / 2.620419)])
	_expect(absf(vol - fine) / fine <= 1e-3 and absf(vol - 2.620419) / 2.620419 <= 5e-4,
		"The cube's volume %.7f should match the fine mesh %.7f (0.1%%) and 2.620419 (0.05%%)." % [vol, fine])
	_expect(absf(float(comp.volume) - vol) <= 1e-9 * vol, "The report's volume should be the shape's.")
	# The sewing fallback gives the same solid, reported as such.
	var sewn: Array = s.to_shapes({"isolation": 6, "name_prefix": "body1", "force_sewing": true})
	var sewn_report: Dictionary = s.get_last_report()
	var sewn_ok := sewn.size() == 1
	if sewn_ok:
		var sc: Dictionary = sewn_report.components[0]
		var sewn_names: PackedStringArray = sewn[0].get_face_names()
		sewn_names.sort()
		print("subd: cube by sewing %s, warnings %s" % [sc, sewn_report.warnings])
		sewn_ok = sc.method == "sewing" and sc.closed and sc.solid and sc.valid and sewn[0].solid_count() == 1 \
			and absf(float(sewn[0].volume()) - vol) <= 1e-6 * vol and sewn_names == expected \
			and str(sewn_report.warnings).contains("sewing")
	_expect(sewn_ok, "The sewing fallback should give the same named closed solid and say so (%s)." % [sewn_report])
	checked.append("cube converts directly to a closed valid solid (vol %.6f, %.1f ms; sewing fallback agrees)" % [vol, report.ms])


func _check_ngons() -> void:
	var s = _subd(_prism())
	var shapes: Array = s.to_shapes({"isolation": 6, "name_prefix": "p"})
	_expect(shapes.size() == 1, "The prism should convert to one shape (%s)." % s.get_last_error())
	if shapes.size() != 1:
		return
	var comp: Dictionary = s.get_last_report().components[0]
	var shape = shapes[0]
	var names: PackedStringArray = shape.get_face_names()
	var subs := 0
	for n in names:
		if n.contains("."):
			subs += 1
	var fine := _mesh_volume(s.tessellate({"rate": 64}))
	var vol: float = shape.volume()
	print("subd: prism report %s, volume %.7f vs fine %.7f" % [comp, vol, fine])
	_expect(comp.closed and comp.solid and comp.valid, "The prism should be a closed valid solid (%s)." % comp)
	_expect(comp.method == "direct", "The prism (n-gons) should convert by the direct build, not sewing (%s)." % comp.method)
	_expect(shape.face_count() == 15 and subs == 10 and names.has("p/f1.4") and names.has("p/f2"),
		"The prism should have 5 quad faces and 2 x 5 sub-faces named f<i>.<k> (%s)." % names)
	_expect(absf(vol - fine) / fine <= 1e-3, "The prism's volume %.7f should match the fine mesh %.7f." % [vol, fine])
	var sewn: Array = s.to_shapes({"isolation": 6, "name_prefix": "p", "force_sewing": true})
	var sc: Dictionary = s.get_last_report().components[0] if sewn.size() == 1 else {}
	_expect(sewn.size() == 1 and sc.get("closed", false) and sc.get("solid", false) and sc.get("valid", false) and absf(float(sewn[0].volume()) - vol) <= 1e-6 * vol,
		"The prism's sewing fallback (cutting at the n-gon half edges) should also close (%s)." % [sc])
	checked.append("pentagonal prism: 15 faces with n-gon sub-faces, direct build (vol %.6f; sewing fallback agrees)" % vol)


func _check_open_plane() -> void:
	var s = _subd(_plane2())
	var shapes: Array = s.to_shapes({})
	_expect(shapes.size() == 1, "The plane should convert to one shape.")
	if shapes.size() != 1:
		return
	var comp: Dictionary = s.get_last_report().components[0]
	_expect(shapes[0].is_surface() and shapes[0].face_count() == 4 and not comp.closed and comp.free_edges == 8,
		"The 2x2 plane should become an open surface of 4 faces with 8 free edges (%s)." % comp)
	checked.append("open 2x2 plane: surface body, 8 free edges")


func _check_torus() -> void:
	var s = _subd(_torus(8, 6))
	var shapes: Array = s.to_shapes({})
	_expect(shapes.size() == 1, "The torus should convert to one shape.")
	if shapes.size() != 1:
		return
	var comp: Dictionary = s.get_last_report().components[0]
	var fine := _mesh_volume(s.tessellate({"rate": 64}))
	var vol: float = shapes[0].volume()
	_expect(comp.closed and comp.solid and comp.valid, "The torus should be a closed valid solid (%s)." % comp)
	_expect(absf(vol - fine) / fine <= 1e-3, "The torus volume %.7f should match the fine mesh %.7f." % [vol, fine])
	checked.append("torus 8x6 solid (vol %.5f)" % vol)


func _check_components() -> void:
	var a := _cube()
	var b := _cube(Vector3(4, 0, 0))
	var pos: PackedFloat64Array = a.positions
	pos.append_array(b.positions)
	var counts: PackedInt32Array = a.face_counts
	counts.append_array(b.face_counts)
	var idx: PackedInt32Array = a.face_indices
	for i in b.face_indices:
		idx.append(i + 8)
	a.positions = pos
	a.face_counts = counts
	a.face_indices = idx
	var s = _subd(a)
	var shapes: Array = s.to_shapes({})
	var comps: Array = s.get_last_report().get("components", [])
	var ok := shapes.size() == 2 and comps.size() == 2
	for c in comps:
		ok = ok and c.solid and c.valid
	_expect(ok, "Two disjoint cubes should give two valid solids (%s)." % [comps])
	if shapes.size() == 2:
		_expect(shapes[0].center_of_mass().x < shapes[1].center_of_mass().x, "Components should come in order of their lowest face.")
	checked.append("two disjoint cubes give two solids")


# ---------------------------------------------------------------- 11: tessellation contract

func _check_tessellate_contract() -> void:
	var cage := _cube()
	var s = _subd(cage)
	var t: Dictionary = s.tessellate()
	var keys := ["positions", "normals", "uvs", "indices", "face_ids", "vertex_faces", "edge_points", "edge_ids", "edge_pairs", "vertices", "rate", "approx_level"]
	var missing := []
	for k in keys:
		if not t.has(k):
			missing.append(k)
	_expect(missing.is_empty(), "tessellate should return every contract key (missing %s)." % [missing])
	if not missing.is_empty():
		return
	_expect(t.rate == 12 and t.approx_level == 4, "The cube's auto rate should be 12 at approximation level 4 (%d, %d)." % [t.rate, t.approx_level])
	_expect(t.edge_pairs == _canonical_edges(cage), "edge_pairs should follow the canonical C1 edge order (%s)." % t.edge_pairs)
	var prism := _prism()
	var sp = _subd(prism)
	_expect(sp.tessellate({"rate": 3}).edge_pairs == _canonical_edges(prism), "The prism's edge_pairs should follow the canonical order.")
	var p: PackedVector3Array = t.positions
	var n: PackedVector3Array = t.normals
	var fids: PackedInt32Array = t.face_ids
	var idx: PackedInt32Array = t.indices
	_expect(fids.size() * 3 == idx.size() and (t.uvs as PackedVector2Array).size() == p.size() and (t.vertex_faces as PackedInt32Array).size() == p.size(),
		"face_ids should be per triangle and uvs/vertex_faces per vertex.")
	var in_range := true
	for f in fids:
		in_range = in_range and f >= 0 and f < 6
	_expect(in_range, "face_ids should name cage faces.")
	var outward := true
	for i in p.size():
		outward = outward and n[i].dot(p[i]) > 0.0
	_expect(outward, "Every cube tessellation normal should point outward.")
	_expect(_winding_ok(t), "Triangles should wind like CadShape.tessellate (clockwise from the front).")
	var box_tess: Dictionary = kernel.make_box(Vector3(1, 1, 1)).tessellate(0.01, 0.2)
	_expect(_winding_ok(box_tess), "A CadShape box should pass the same winding test.")
	# Edge curves: each canonical edge's segments run between its two limit points.
	var ep: PackedVector3Array = t.edge_points
	var eids: PackedInt32Array = t.edge_ids
	var verts: PackedVector3Array = t.vertices
	var pairs: PackedInt32Array = t.edge_pairs
	var ends := {}
	for k in eids.size():
		for q in [ep[k * 2], ep[k * 2 + 1]]:
			ends[eids[k]] = ends.get(eids[k], [])
			ends[eids[k]].append(q)
	var curves_ok := eids.size() == 12 * int(t.rate)
	for e in 12:
		var a: Vector3 = verts[pairs[e * 2]]
		var b: Vector3 = verts[pairs[e * 2 + 1]]
		var hit_a := false
		var hit_b := false
		for q in ends.get(e, []):
			hit_a = hit_a or q.distance_to(a) < 1e-6
			hit_b = hit_b or q.distance_to(b) < 1e-6
		curves_ok = curves_ok and hit_a and hit_b
	_expect(curves_ok, "Every edge curve should run between its two vertices' limit points.")
	# Weights interpolate through the surface: constant in, constant out.
	var w := PackedFloat32Array()
	w.resize(8)
	w.fill(0.75)
	var tw: Dictionary = s.tessellate({"weights": w, "rate": 4})
	var wo: PackedFloat32Array = tw.get("weights", PackedFloat32Array())
	var wok := wo.size() == (tw.positions as PackedVector3Array).size()
	for x in wo:
		wok = wok and absf(x - 0.75) < 1e-6
	_expect(wok, "Constant weights should interpolate to the same constant.")
	# A drag: new positions, same pattern, moved points.
	var moved: PackedFloat64Array = cage.positions.duplicate()
	for i in moved.size():
		moved[i] *= 2.0
	_expect(s.set_positions(moved), "set_positions should accept the same vertex count.")
	var t2: Dictionary = s.tessellate()
	_expect(t2.indices == t.indices and (t2.positions as PackedVector3Array)[0].is_equal_approx((t.positions as PackedVector3Array)[0] * 2.0),
		"After set_positions the pattern should stay and the points scale with the cage.")
	_expect(not s.set_positions(PackedFloat64Array([1.0, 2.0, 3.0])), "set_positions should refuse a different vertex count.")
	checked.append("tessellate contract (keys, canonical edges, outward normals, CadShape winding, edge curves, weights, drag update)")


# ---------------------------------------------------------------- sub-face layout

func _check_subfaces() -> void:
	# Sub-face k of an n-gon: (0,0) at corner k, (1,0) at the midpoint of edge (k, k+1), (1,1) at
	# the face centre, (0,1) at the midpoint of edge (k-1, k).
	var cage := _prism()
	var s = _subd(cage)
	var lim: PackedFloat64Array = s.limit_points().positions
	var faces := PackedInt32Array()
	var uvs := PackedVector2Array()
	for k in 5:
		for st in [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]:
			faces.append(1)
			uvs.append(s.subface_uv(1, k, st.x, st.y))
	for k in 5:
		# The side quad 2 + k = [k, k+1, 5+k+1, 5+k]: its top edge runs corner 2 -> 3 (v = 1).
		faces.append(2 + k)
		uvs.append(Vector2(0.5, 1.0))
	var e: Dictionary = s.evaluate(faces, uvs)
	var p: PackedFloat64Array = e.get("positions", PackedFloat64Array())
	var worst := 0.0
	if p.size() == faces.size() * 3:
		for k in 5:
			var b := k * 4
			worst = maxf(worst, _p3(p, b).distance_to(_p3(lim, 5 + k)))
			worst = maxf(worst, _p3(p, b + 2).distance_to(_p3(p, 2)))
			var next := ((k + 1) % 5) * 4
			worst = maxf(worst, _p3(p, b + 1).distance_to(_p3(p, next + 3)))
			worst = maxf(worst, _p3(p, b + 1).distance_to(_p3(p, 20 + k)))
	else:
		worst = INF
	print("subd: sub-face layout check, worst mismatch %s" % _g(worst))
	_expect(worst <= 1e-9, "n-gon sub-face coordinates should follow corner / next-edge midpoint / centre / previous-edge midpoint (off by %s)." % _g(worst))
	checked.append("n-gon sub-face layout (corner, next midpoint, centre, previous midpoint; %s)" % _g(worst))


# ---------------------------------------------------------------- 12: picking

func _check_ray_and_visible() -> void:
	var s = _subd(_cube())
	var hit: Dictionary = s.ray_hit(Vector3(5, 0, 0), Vector3(-1, 0, 0))
	var ok: bool = hit.get("hit", false)
	var d_err := absf(float(hit.get("distance", INF)) - (5.0 - R_FACE))
	var p_err := (hit.get("point", Vector3.ZERO) as Vector3).distance_to(Vector3(R_FACE, 0, 0))
	print("subd: ray hit face %s, distance error %s, point error %s" % [hit.get("face", -1), _g(d_err), _g(p_err)])
	_expect(ok and hit.face == 3 and d_err <= 1e-6 and p_err <= 1e-6,
		"A ray from (5,0,0) along -X should hit the +X face at 68/81 (%s)." % hit)
	var cage_hit: Dictionary = s.ray_hit(Vector3(5, 0.2, 0.1), Vector3(-1, 0, 0), 1)
	_expect(cage_hit.get("hit", false) and cage_hit.face == 3 and absf(float(cage_hit.distance) - 4.0) < 1e-9,
		"A ray against the cage polygons should hit the cage's +X face at x = 1 (%s)." % cage_hit)
	# On an n-gon (the prism's top pentagon) the refined hit lies on the limit surface.
	var sp = _subd(_prism())
	var worst_ngon := 0.0
	var ngon_faces := true
	for xy in [Vector2(0.31, 0.17), Vector2(-0.4, 0.05), Vector2(0.02, -0.33), Vector2(0.0, 0.0)]:
		var h: Dictionary = sp.ray_hit(Vector3(xy.x, xy.y, 5.0), Vector3(0, 0, -1))
		ngon_faces = ngon_faces and h.get("hit", false) and h.face == 1
		if h.get("hit", false):
			var cp: Dictionary = sp.closest_points(PackedVector3Array([h.point]))
			worst_ngon = maxf(worst_ngon, cp.distances[0])
	_expect(ngon_faces and worst_ngon <= 1e-6, "Rays onto the prism's pentagon should hit face 1 on its limit surface (off by %s)." % _g(worst_ngon))
	var miss: Dictionary = s.ray_hit(Vector3(5, 5, 5), Vector3(1, 0, 0))
	_expect(not miss.get("hit", true), "A ray pointing away should miss.")
	var vis: PackedByteArray = s.visible(PackedVector3Array([Vector3(R_FACE, 0, 0), Vector3(-R_FACE, 0, 0)]), Vector3(5, 0, 0))
	_expect(vis.size() == 2 and vis[0] == 1 and vis[1] == 0, "From +X the near face centre should be visible and the far one hidden (%s)." % vis)
	var ortho: PackedByteArray = s.visible(PackedVector3Array([Vector3(R_FACE, 0, 0), Vector3(-R_FACE, 0, 0)]), Vector3.ZERO, Vector3(-1, 0, 0))
	_expect(ortho.size() == 2 and ortho[0] == 1 and ortho[1] == 0, "An orthographic view along -X should see the same (%s)." % ortho)
	checked.append("ray_hit on the limit (distance err %s, n-gon hits on the limit within %s) and cage, visible() perspective and orthographic" % [_g(d_err), _g(worst_ngon)])


# ---------------------------------------------------------------- 13: closest points

## Squared-distance grid over sample points for exact nearest-sample queries.
class Grid:
	var cell := 0.05
	var cells := {}
	var points: PackedVector3Array

	func _init(pts: PackedVector3Array, c: float) -> void:
		points = pts
		cell = c
		for i in pts.size():
			var k := Vector3i((pts[i] / cell).floor())
			if not cells.has(k):
				cells[k] = PackedInt32Array()
			cells[k].append(i)

	## The nearest sample distance, searching cells out to radius r (INF when none within r).
	func nearest_within(q: Vector3, r: float) -> float:
		var lo := Vector3i(((q - Vector3.ONE * r) / cell).floor())
		var hi := Vector3i(((q + Vector3.ONE * r) / cell).floor())
		var best := INF
		for x in range(lo.x, hi.x + 1):
			for y in range(lo.y, hi.y + 1):
				for z in range(lo.z, hi.z + 1):
					var k := Vector3i(x, y, z)
					if cells.has(k):
						for i in cells[k]:
							best = minf(best, q.distance_to(points[i]))
		return best


func _closest_case(label: String, cage: Dictionary, count: int) -> Dictionary:
	var s = _subd(cage)
	var dense: Dictionary = s.tessellate({"rate": 48, "approx_level": 10})
	var dp: PackedVector3Array = dense.positions
	var grid := Grid.new(dp, 0.05)
	var queries := PackedVector3Array()
	var seed := [12345]
	var rnd := func() -> float:
		seed[0] = (int(seed[0]) * 1664525 + 1013904223) & 0xffffffff
		return ((int(seed[0]) >> 8) & 0xffff) / 65535.0 - 0.5
	for i in count:
		var base := dp[int((rnd.call() + 0.5) * (dp.size() - 1))]
		queries.append(base + Vector3(rnd.call(), rnd.call(), rnd.call()) * 0.4)
	var started := Time.get_ticks_usec()
	var r: Dictionary = s.closest_points(queries)
	var us := (Time.get_ticks_usec() - started) / float(count)
	var dist: PackedFloat64Array = r.get("distances", PackedFloat64Array())
	var pos: PackedFloat64Array = r.get("positions", PackedFloat64Array())
	var fails := 0
	var worst := 0.0
	var consistent := dist.size() == count
	for i in mini(count, dist.size()):
		consistent = consistent and absf(_p3(pos, i).distance_to(queries[i]) - dist[i]) < 1e-6
		var dense_best := grid.nearest_within(queries[i], dist[i] + 1e-3)
		var excess := dist[i] - dense_best
		if excess > 1e-6:
			fails += 1
			worst = maxf(worst, excess)
	print("subd: closest points on %s: %d/%d worse than dense rate-48 sampling (max excess %s), %.1f us/query" % [label, fails, count, _g(worst), us])
	_expect(consistent, "closest_points distances should match its positions (%s)." % label)
	return {"fails": fails, "us": us, "worst": worst}


func _check_closest_points() -> void:
	var noisy := _closest_case("noisy 3x3 cube", _grid_cube(3, 7), 300)
	_expect(noisy.fails == 0, "closest_points should never lose to dense sampling on the noisy cube (%d failures, max excess %s)." % [noisy.fails, _g(noisy.worst)])
	var plain := _closest_case("cube cage", _cube(), 300)
	_expect(plain.fails == 0, "closest_points should never lose to dense sampling on the cube cage (%d failures, max excess %s)." % [plain.fails, _g(plain.worst)])
	# The cube's face centre projects onto itself.
	var s = _subd(_cube())
	var r: Dictionary = s.closest_points(PackedVector3Array([Vector3(3, 0, 0)]))
	_expect(r.faces[0] == 3 and absf(r.distances[0] - (3.0 - R_FACE)) < 1e-9, "(3,0,0) should project to the +X face centre (%s)." % r)
	var far: Dictionary = s.closest_points(PackedVector3Array([Vector3(30, 0, 0)]), 1.0)
	_expect(far.faces[0] == -1, "A point beyond max_distance should get face -1.")
	checked.append("closest_points 0/300 failures on the noisy cube (%.1f us/query) and the cube cage" % noisy.us)


# ---------------------------------------------------------------- 14-16: least squares

func _check_interpolate() -> void:
	var cage := _sphere84()
	var s = _subd(cage)
	_expect(s.get_vertex_count() == 26 and s.get_edge_count() == 56 and s.get_face_count() == 32, "The 8x4 sphere cage should be 26/56/32.")
	var targets: PackedFloat64Array = cage.positions
	var started := Time.get_ticks_usec()
	var solved: PackedFloat64Array = s.interpolate(targets)
	var ms := (Time.get_ticks_usec() - started) / 1000.0
	_expect(solved.size() == targets.size(), "interpolate should return 3 values per vertex (%s)." % s.get_last_error())
	var worst := INF
	if solved.size() == targets.size():
		s.set_positions(solved)
		var lim: PackedFloat64Array = s.limit_points().positions
		worst = 0.0
		for v in 26:
			worst = maxf(worst, _p3(lim, v).distance_to(_p3(targets, v)))
			worst = maxf(worst, _d3(lim, v, targets[v * 3], targets[v * 3 + 1], targets[v * 3 + 2]))
	print("subd: interpolate sphere 8x4: max |limit - target| %s (%.2f ms)" % [_g(worst), ms])
	_expect(worst <= 1e-9, "interpolate should put every vertex's limit on its target (off by %s)." % _g(worst))
	# Partly free: fixed vertices stay put.
	var s2 = _subd(cage)
	var part: PackedFloat64Array = s2.interpolate(targets, PackedInt32Array([0, 1, 2]))
	var fixed_ok := part.size() == targets.size()
	for i in range(9, targets.size()):
		fixed_ok = fixed_ok and part[i] == targets[i]
	_expect(fixed_ok, "Vertices outside the free list should keep their positions exactly.")
	# The singular cube (checkerboard null mode): finite, small residual, minimal move.
	var cube := _cube()
	var sc = _subd(cube)
	var cpos: PackedFloat64Array = cube.positions
	var csol: PackedFloat64Array = sc.interpolate(cpos)
	var finite := csol.size() == 24
	var move := 0.0
	for v in 8:
		for c in 3:
			finite = finite and is_finite(csol[v * 3 + c])
		move = maxf(move, _p3(csol, v).distance_to(_p3(cpos, v)))
	var cres := INF
	if finite:
		sc.set_positions(csol)
		var clim: PackedFloat64Array = sc.limit_points().positions
		cres = 0.0
		for v in 8:
			cres = maxf(cres, _d3(clim, v, cpos[v * 3], cpos[v * 3 + 1], cpos[v * 3 + 2]))
	print("subd: interpolate singular cube: residual %s, max move %.4f" % [_g(cres), move])
	_expect(finite and cres <= 1e-6 and move <= 2.0, "interpolate on the singular cube should stay finite (residual %s, move %.3f)." % [_g(cres), move])
	# A larger, well-conditioned cage: the noisy 3x3 cube through its own cage points.
	var noisy := _grid_cube(3, 7)
	var sn = _subd(noisy)
	var npos: PackedFloat64Array = noisy.positions
	var nsol: PackedFloat64Array = sn.interpolate(npos)
	var nres := INF
	if nsol.size() == npos.size():
		sn.set_positions(nsol)
		var nlim: PackedFloat64Array = sn.limit_points().positions
		nres = 0.0
		for v in npos.size() / 3:
			nres = maxf(nres, _d3(nlim, v, npos[v * 3], npos[v * 3 + 1], npos[v * 3 + 2]))
	print("subd: interpolate noisy 3x3 cube through its cage points: residual %s" % _g(nres))
	_expect(nres <= 1e-9, "interpolate on the noisy cube should be exact (%s)." % _g(nres))
	checked.append("interpolate exact on the sphere cage (%s) and noisy cube (%s); singular cube finite (res %s, move %.3f)" % [_g(worst), _g(nres), _g(cres), move])


func _check_fit() -> void:
	var s = _subd(_plane3())
	var faces := PackedInt32Array()
	var uvs := PackedVector2Array()
	for f in 9:
		for uv in [Vector2(0.25, 0.3), Vector2(0.7, 0.8)]:
			if faces.size() < 16:
				faces.append(f)
				uvs.append(uv)
	var e: Dictionary = s.evaluate(faces, uvs)
	var targets: PackedFloat64Array = e.positions.duplicate()
	for i in faces.size():
		targets[i * 3 + 2] += 0.1
	var solved: PackedFloat64Array = s.fit(faces, uvs, targets, PackedInt32Array())
	var res := INF
	if solved.size() == 48:
		s.set_positions(solved)
		var e2: Dictionary = s.evaluate(faces, uvs)
		res = 0.0
		for i in faces.size():
			res = maxf(res, _d3(e2.positions, i, targets[i * 3], targets[i * 3 + 1], targets[i * 3 + 2]))
	print("subd: fit 3x3 plane lifted 0.1 at 16 locations: residual %s" % _g(res))
	_expect(res <= 1e-6, "fit should lift the plane's limit onto its 16 targets (residual %s)." % _g(res))
	checked.append("fit residual %s" % _g(res))


# ---------------------------------------------------------------- 17-18: B-rep helpers

func _check_project_and_grid() -> void:
	var s = ClassDB.instantiate("CadSubD")
	var box = kernel.make_box(Vector3(1, 2, 3))
	var pts := PackedVector3Array([Vector3(0.3, 2.4, 1.1), Vector3(0.9, 2.05, 2.7), Vector3(0.5, 1.0, 3.5), Vector3(1.6, 1.0, 1.0)])
	var r: Dictionary = s.project_to_shape(box, pts)
	var pos: PackedFloat64Array = r.get("positions", PackedFloat64Array())
	var expect_pts := [Vector3(0.3, 2.0, 1.1), Vector3(0.9, 2.0, 2.7), Vector3(0.5, 1.0, 3.0), Vector3(1.0, 1.0, 1.0)]
	var worst := 0.0
	if pos.size() == 12:
		for i in 4:
			worst = maxf(worst, _d3(pos, i, expect_pts[i].x, expect_pts[i].y, expect_pts[i].z))
	else:
		worst = INF
	var n: PackedVector3Array = r.get("normals", PackedVector3Array())
	print("subd: project_to_shape onto a box: worst %s" % _g(worst))
	_expect(worst <= 1e-9 and n.size() == 4 and n[0].is_equal_approx(Vector3.UP) and (r.faces as PackedInt32Array).count(-1) == 0,
		"Points above box faces should land on them within 1e-9 with outward normals (%s, %s)." % [_g(worst), r])
	# face_grid: the box face under (0.5, 2, 1.5) is four-sided and flat.
	var face := -1
	for f in box.face_count():
		var info: Dictionary = box.face_info(f)
		if info.get("planar", false) and (info.normal as Vector3).is_equal_approx(Vector3.UP):
			face = f
	var g: Dictionary = s.face_grid(box, face, 4, 3)
	var gp: PackedFloat64Array = g.get("positions", PackedFloat64Array())
	var flat := gp.size() == 5 * 4 * 3
	for i in gp.size() / 3:
		flat = flat and absf(gp[i * 3 + 1] - 2.0) <= 1e-9
	_expect(g.get("ok", false) and g.get("four_sided", false) and flat, "A box face should give a flat four-sided 5x4 grid (%s)." % [g])
	var sphere = kernel.make_sphere(1.0)
	var sg: Dictionary = s.face_grid(sphere, 0, 4, 4)
	_expect(not sg.get("ok", true) and sg.get("error", "") == "Only four-sided faces can become a cage in this version",
		"A sphere face should not become a grid (%s)." % [sg])
	checked.append("project_to_shape onto a box (%s), face_grid four-sided box face and refused sphere" % _g(worst))


# ---------------------------------------------------------------- 19: bad cages

func _check_bad_cages() -> void:
	var fan := _cage([[0, 0, 0], [1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1]], [[0, 1, 2], [1, 0, 3], [0, 1, 4]])
	var s = ClassDB.instantiate("CadSubD")
	var c: Dictionary = s.check_cage(fan)
	var nm: PackedInt32Array = c.get("non_manifold_edges", PackedInt32Array())
	_expect(not c.get("ok", true) and nm.size() == 2 and nm[0] == 0 and nm[1] == 1, "check_cage should report edge (0,1) of the fan as non-manifold (%s)." % [c])
	_expect(not s.set_cage(fan) and s.get_last_error() != "", "set_cage should refuse the non-manifold fan with an error.")
	var good: Dictionary = s.check_cage(_cube())
	_expect(good.get("ok", false), "check_cage should pass the cube (%s)." % [good])
	var flipped := _cube()
	var idx: PackedInt32Array = flipped.face_indices
	var f2 := [idx[8], idx[9], idx[10], idx[11]]
	for k in 4:
		idx[8 + k] = f2[3 - k]
	flipped.face_indices = idx
	var fc: Dictionary = s.check_cage(flipped)
	_expect(not fc.ok and fc.flipped_faces == PackedInt32Array([2]), "check_cage should find the one flipped face (%s)." % [fc])
	_expect(not s.set_cage(flipped), "set_cage should refuse inconsistent orientation.")
	var crossing := _cube()
	var cross_pos: PackedFloat64Array = crossing.positions
	var extra := _cube(Vector3(1.0, 0.3, 0.2))
	cross_pos.append_array(extra.positions)
	var ccounts: PackedInt32Array = crossing.face_counts
	ccounts.append_array(extra.face_counts)
	var cidx: PackedInt32Array = crossing.face_indices
	for i in extra.face_indices:
		cidx.append(i + 8)
	crossing.positions = cross_pos
	crossing.face_counts = ccounts
	crossing.face_indices = cidx
	var xc: Dictionary = s.check_cage(crossing)
	_expect(not xc.ok and (xc.self_intersecting_faces as PackedInt32Array).size() >= 2, "Two overlapping cubes should report self-intersecting faces (%s)." % [xc])
	var bad := _cube()
	bad.face_indices = PackedInt32Array([0, 3, 2, 99, 4, 5, 6, 7, 0, 1, 5, 4, 1, 2, 6, 5, 2, 3, 7, 6, 3, 0, 4, 7])
	_expect(not s.set_cage(bad) and s.get_last_error().contains("out of range"), "set_cage should refuse an index out of range (%s)." % s.get_last_error())
	checked.append("check_cage non-manifold / flipped / self-intersection reports, set_cage refusals")


# ---------------------------------------------------------------- 20: timing

func _check_timing() -> void:
	var big := _grid_cube(13)
	var calibration := func() -> void:
		var sphere = kernel.make_sphere(0.02, Vector3.ZERO, "cal")
		sphere.tessellate(0.0002, 0.3)
	var results := {}
	var cold := func() -> void:
		var x = ClassDB.instantiate("CadSubD")
		x.set_cage(big)
		x.tessellate()
	results["set_cage_tessellate_1014"] = TIMING.compare(cold, calibration, 3, "set_cage + tessellate, 1014-face cube")
	var drag = _subd(big)
	drag.tessellate()
	var a: PackedFloat64Array = big.positions
	var b: PackedFloat64Array = a.duplicate()
	for i in range(0, b.size(), 3):
		b[i] += 0.01 * sin(i)
	var flip := [false]
	var frame := func() -> void:
		flip[0] = not flip[0]
		drag.set_positions(b if flip[0] else a)
		drag.tessellate()
	var drag_frame := func() -> void:
		flip[0] = not flip[0]
		drag.set_positions(b if flip[0] else a)
		drag.tessellate({"rate": 6})
	results["drag_frame_1014"] = TIMING.compare(frame, calibration, 5, "drag frame (set_positions + tessellate auto rate 12), 1014 faces")
	results["drag_frame_1014_drag_rate"] = TIMING.compare(drag_frame, calibration, 5, "drag frame at drag rate 6, 1014 faces")
	var cube = _subd(_cube())
	results["to_shapes_cube"] = TIMING.compare(func() -> void: cube.to_shapes({}), calibration, 3, "to_shapes cube L6")
	var bigs = _subd(big)
	results["to_shapes_1014"] = TIMING.compare(func() -> void: bigs.to_shapes({}), calibration, 2, "to_shapes 1014-face cube L6")
	var rep: Dictionary = bigs.get_last_report()
	print("subd: 1014-face convert stages: %s" % [rep])
	var over := []
	for key in results:
		var r: Dictionary = results[key]
		print("subd timing %s: %.2f ms (calibration %.3f ms), ratio %.3f, limit %.3f" % [key, r.op, r.calibration, r.ratio, LIMITS[key]])
		if r.ratio > LIMITS[key]:
			over.append("%s ratio %.3f > %.3f" % [key, r.ratio, LIMITS[key]])
	_expect(over.is_empty(), "Timing ratios over their limits: %s." % [over])
	checked.append("timing ratios (tessellate %.1f ms, drag %.1f / %.1f ms, convert %.0f / %.0f ms)" % [results.set_cage_tessellate_1014.op, results.drag_frame_1014.op, results.drag_frame_1014_drag_rate.op, results.to_shapes_cube.op, results.to_shapes_1014.op])


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)
		print("FAIL: ", message)
