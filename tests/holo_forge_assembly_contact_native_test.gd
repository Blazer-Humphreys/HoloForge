extends SceneTree
## Holo Forge Phase 8, contact on the native side: CadMesh.overlap (work order C5.1, acceptance 5.3).
##   1  two 20 mm cubes overlapping 1 mm along X: volume, area and thickness of the overlap
##   2  face to face (gap 0): no volume, no thickness
##   3  1 mm apart: no overlap, answered by the box test
##   4  other_to_this = R_z(90 deg) + T(5, 0, 0) mm gives the volume of the same meshes pre-placed
##   5  the Manifold cache: the second call on two 20k-triangle spheres is far cheaper
##   6  the bound: two 200k-triangle meshes with time_limit 0.05 come back timed out within 1.05 s
##   7  open and inside-out meshes are refused with the C5.1 sentences
##   8  a changed mesh does not keep a cached Manifold of its old geometry
##   9  timing ratios (5.9): 2 x 12, 2 x 20k, 2 x 200k (cached) and 2 x 20k on first use
##  10  far from the origin: the warning names the distance
##  11  placements that are not rigid moves are refused at once
##  12  a mesh that crosses itself (fix round 1, verifier P6): an overlap there is refused with a
##      sentence that names the mesh problem and the repair, self_crossing true and the side, never
##      "a Holo Forge fault"; clean meshes and boxes apart say self_crossing false
##
## Meshes are float32: a "20 mm" cube's corners are the float32 values nearest 20 mm, so exact
## expectations (1e-9 relative) are computed from the stored corner values; the nominal millimetre
## values are checked within 1e-6 relative (float32 rounding).
##
## godot --headless --path . --script res://tests/holo_forge_assembly_contact_native_test.gd

const FIXTURES := preload("res://tests/holo_forge_mesh_fixtures.gd")
const TIMING := preload("res://tests/holo_forge_timing.gd")

const MM := 0.001
const NAME := "holo_forge_assembly_contact_native"
const CASES := ["#1 overlap 1 mm", "#2 face to face", "#3 apart", "#4 placement", "#5 cache", "#6 bound", "#7 refusals",
	"#8 changed mesh", "#9 timing", "#10 far from the origin", "#11 placement refusals", "#12 self-crossing"]
const OPEN_ERROR := "Contact needs closed bodies: the mesh is open."
const INSIDE_OUT_ERROR := "Contact needs closed bodies: the mesh is inside out."

## Timing ratio limits (5.9): 2 x the ratio measured on the dev machine (Ryzen 9 5900HX) against
## the sphere make + tessellate calibration (3.8 to 4.6 ms), measured 2026-11-13 in two runs with
## both Manifolds cached (a sweep's steady state) unless said otherwise:
const LIMITS := {
	"overlap_2x12": 0.12,         # two boxes of 12: 0.23 ms, ratio 0.051-0.061 (C9 target 1 ms)
	"overlap_2x20k": 7.3,         # two 20,480-triangle spheres: 12.7-14.0 ms, ratio 3.38-3.65 (target 30 ms)
	"overlap_2x200k": 40.0,       # two 199,692-triangle grid boxes: 73.7-75.6 ms, ratio 19.2-19.8 (target 400 ms)
	"overlap_2x20k_first": 46.0,  # the spheres made and used for the first time (both Manifolds built, and since fix
	                              # round 1 both tested once for crossing themselves, about 20-40 ms): 81-104 ms,
	                              # ratio 20.1-22.9 (target 3 x 30 ms), remeasured 2026-11-13 in two runs; it was
	                              # 62.5-64.5 ms, ratio 13.9, before the crossing test
}

var failed := 0
var kernel: RefCounted


func _init() -> void:
	call_deferred("run")


func run() -> void:
	if not ClassDB.class_exists("CadMesh") or not ClassDB.class_exists("CadKernel"):
		for name: String in CASES:
			print("SKIP %s %s: native library missing" % [NAME, name])
		quit(0)
		return
	if not ClassDB.class_has_method("CadMesh", "overlap"):
		for name: String in CASES:
			_report(name, false, "CadMesh has no overlap method (the loaded native library is older than Phase 8)")
		quit(1)
		return
	kernel = ClassDB.instantiate("CadKernel")
	_case_overlap()
	_case_touching()
	_case_apart()
	_case_placement()
	_case_cache()
	_case_bound()
	_case_refusals()
	_case_changed()
	_case_timing()
	_case_far()
	_case_bad_placement()
	_case_self_crossing()
	print(("PASS %s: all cases." % NAME) if failed == 0 else ("FAIL %s: %d case(s) failed." % [NAME, failed]))
	quit(0 if failed == 0 else 1)


# ---------------------------------------------------------------- helpers


func _report(name: String, ok: bool, detail: String) -> void:
	if ok:
		print("PASS %s %s: %s" % [NAME, name, detail])
	else:
		failed += 1
		push_error("%s %s: %s" % [NAME, name, detail])
		print("FAIL %s %s: %s" % [NAME, name, detail])


func _new() -> RefCounted:
	return ClassDB.instantiate("CadMesh")


func _mesh(fixture: Dictionary) -> RefCounted:
	var mesh := _new()
	if not mesh.set_arrays(fixture.positions, fixture.indices, fixture.groups, fixture.names, "godot"):
		push_error("fixture refused: " + mesh.get_last_error())
	return mesh


## A box from its min and max corners (12 triangles, 8 welded corners), as a fixture.
func _box_fixture(lo: Vector3, hi: Vector3) -> Dictionary:
	var positions := PackedVector3Array()
	for k in 2:
		for j in 2:
			for i in 2:
				positions.append(Vector3(hi.x if i == 1 else lo.x, hi.y if j == 1 else lo.y, hi.z if k == 1 else lo.z))
	# Corner id = i + 2 j + 4 k; counter-clockwise seen from outside.
	var ccw := PackedInt32Array([0, 2, 3, 0, 3, 1, 4, 5, 7, 4, 7, 6, 0, 1, 5, 0, 5, 4, 2, 6, 7, 2, 7, 3, 0, 4, 6, 0, 6, 2, 1, 3, 7, 1, 7, 5])
	return FIXTURES._pack(positions, ccw)


func _box(lo: Vector3, hi: Vector3) -> RefCounted:
	return _mesh(_box_fixture(lo, hi))


func _identity() -> PackedFloat64Array:
	return PackedFloat64Array([1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0])


func _move(x: float, y: float, z: float) -> PackedFloat64Array:
	return PackedFloat64Array([1, 0, 0, 0, 1, 0, 0, 0, 1, x, y, z])


func _near(value: float, wanted: float, relative: float) -> bool:
	return absf(value - wanted) <= relative * absf(wanted)


func _f32(value: float) -> float:
	return PackedFloat32Array([value])[0]


func _ms_since(started: int) -> float:
	return (Time.get_ticks_usec() - started) / 1000.0


func _brief(r: Dictionary) -> String:
	return "overlap %s, volume %s m3, area %s m2, thickness %s m, early_out %s, timed_out %s, built %s, %.3f ms, error '%s'" % [
		r.get("overlap"), float(r.get("volume", -1.0)), float(r.get("area", -1.0)), float(r.get("thickness", -1.0)), r.get("early_out"),
		r.get("timed_out"), r.get("built"), float(r.get("ms", -1.0)), r.get("error", "?")]


# ---------------------------------------------------------------- 1 to 4


## Two 20 mm cubes overlapping 1 mm along X (faces 20 x 20): 400 mm3, 880 mm2, 0.9090... mm.
func _case_overlap() -> void:
	var size := Vector3(20, 20, 20) * MM
	var shift := Vector3(19, 0, 0) * MM
	var a := _box(Vector3.ZERO, size)
	var b := _box(shift, shift + size)
	var r: Dictionary = a.overlap(b, _identity(), {"time_limit": 1.0})
	# From the stored (float32) corners, in doubles.
	var s := size.x
	var w := size.x - shift.x
	var volume := w * s * s
	var area := 2.0 * s * s + 4.0 * w * s
	var thickness := 2.0 * volume / area
	var point: PackedFloat64Array = r.get("point", PackedFloat64Array())
	var ok: bool = r.get("error", "x") == "" and r.get("overlap", false) and not r.get("early_out", true) and not r.get("timed_out", true) \
		and _near(r.volume, volume, 1e-9) and _near(r.area, area, 1e-9) and _near(r.thickness, thickness, 1e-9) \
		and _near(r.volume, 400.0 * MM * MM * MM, 1e-6) and _near(r.area, 880.0 * MM * MM, 1e-6) and _near(r.thickness, 800.0 / 880.0 * MM, 1e-6) \
		and point.size() == 3 and absf(point[0] - 0.5 * (shift.x + s)) < 1e-12 and absf(point[1] - 0.5 * s) < 1e-12 and absf(point[2] - 0.5 * s) < 1e-12
	_report("#1 overlap 1 mm", ok, "%s; expected %s m3, %s m2, %s m (from the float32 corners); point %s" % [_brief(r), volume, area, thickness, point])


## Face to face (gap 0): volume <= 1e-15 m3, thickness <= 1e-9 m.
func _case_touching() -> void:
	var size := Vector3(20, 20, 20) * MM
	var a := _box(Vector3.ZERO, size)
	var b := _box(Vector3(size.x, 0, 0), Vector3(size.x, 0, 0) + size)
	var r: Dictionary = a.overlap(b, _identity(), {"time_limit": 1.0})
	var r2: Dictionary = a.overlap(a, _move(size.x, 0, 0), {"time_limit": 1.0})
	var ok: bool = r.get("error", "x") == "" and float(r.get("volume", 1.0)) <= 1e-15 and float(r.get("thickness", 1.0)) <= 1e-9 and not r.get("timed_out", true) \
		and r2.get("error", "x") == "" and float(r2.get("volume", 1.0)) <= 1e-15 and float(r2.get("thickness", 1.0)) <= 1e-9
	_report("#2 face to face", ok, "pre-placed: %s; by other_to_this: %s" % [_brief(r), _brief(r2)])


## 1 mm apart: no overlap, early_out.
func _case_apart() -> void:
	var size := Vector3(20, 20, 20) * MM
	var a := _box(Vector3.ZERO, size)
	var b := _box(Vector3(21, 0, 0) * MM, Vector3(41, 20, 20) * MM)
	var r: Dictionary = a.overlap(b, _identity(), {})
	var r2: Dictionary = a.overlap(a, _move(0.021, 0.0, 0.0), {})
	var ok: bool = r.get("error", "x") == "" and r.get("overlap", true) == false and r.get("early_out", false) == true and float(r.get("volume", 1.0)) == 0.0 \
		and int(r.get("built", -1)) == 0 and r2.get("overlap", true) == false and r2.get("early_out", false) == true
	_report("#3 apart", ok, "%s; by other_to_this: %s" % [_brief(r), _brief(r2)])


## other_to_this = R_z(90 deg) + T(5, 0, 0) mm against the same meshes pre-placed with transformed.
## (The basis is built from exact columns: Godot's float32 cos(90 deg) is not 0. The 5 mm is
## float32's nearest value, so the pre-placed mesh holds the same faces where the overlap is.)
func _case_placement() -> void:
	var size := Vector3(20, 20, 20) * MM
	var a := _box(Vector3.ZERO, size)
	var b := _box(Vector3.ZERO, size)
	var t := _f32(5.0 * MM)
	var xf := PackedFloat64Array([0, 1, 0, -1, 0, 0, 0, 0, 1, t, 0, 0])
	var by_xform: Dictionary = a.overlap(b, xf, {"time_limit": 1.0})
	var placed: RefCounted = b.transformed(Transform3D(Basis(Vector3(0, 1, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1)), Vector3(t, 0, 0)))
	var pre: Dictionary = a.overlap(placed, _identity(), {"time_limit": 1.0}) if placed != null else {}
	var analytic := t * size.x * size.y
	var ok: bool = by_xform.get("error", "x") == "" and pre.get("error", "x") == "" and by_xform.get("overlap", false) \
		and _near(by_xform.volume, pre.volume, 1e-9) and _near(by_xform.volume, analytic, 1e-9) and _near(by_xform.area, pre.area, 1e-9)
	# The side with fewer triangles is the one moved: a box (12) against a sphere (20,480) takes the
	# other way round, and the answer comes back in the box's space. The same pair asked from the
	# sphere's side with the inverse placement gives the same volume and the same point, moved.
	var ball := _mesh(FIXTURES.icosphere(10.0 * MM, 5))
	var ty := _f32(1.0 * MM)
	var xf2 := PackedFloat64Array([0, 1, 0, -1, 0, 0, 0, 0, 1, t, ty, 0])
	var inv2 := PackedFloat64Array([0, -1, 0, 1, 0, 0, 0, 0, 1, -ty, t, 0])
	var from_box: Dictionary = a.overlap(ball, xf2, {"time_limit": 5.0})
	var from_ball: Dictionary = ball.overlap(a, inv2, {"time_limit": 5.0})
	var placed_ball: RefCounted = ball.transformed(Transform3D(Basis(Vector3(0, 1, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1)), Vector3(t, ty, 0)))
	var from_placed: Dictionary = a.overlap(placed_ball, _identity(), {"time_limit": 5.0})
	var p1: PackedFloat64Array = from_box.get("point", PackedFloat64Array())
	var p2: PackedFloat64Array = from_ball.get("point", PackedFloat64Array())
	var mapped := [-p2[1] + t, p2[0] + ty, p2[2]] if p2.size() == 3 else [INF, INF, INF]
	ok = ok and from_box.get("error", "x") == "" and from_ball.get("error", "x") == "" and from_box.get("overlap", false) \
		and _near(from_box.volume, from_ball.volume, 1e-9) and _near(from_box.area, from_ball.area, 1e-9) and _near(from_box.volume, from_placed.volume, 1e-5) \
		and p1.size() == 3 and absf(p1[0] - mapped[0]) < 1e-12 and absf(p1[1] - mapped[1]) < 1e-12 and absf(p1[2] - mapped[2]) < 1e-12
	_report("#4 placement", ok, "by other_to_this: %s; pre-placed: %s; analytic %s m3; box against ball: %s, point %s; ball against box: %s, point %s moved to %s; ball pre-placed (float32): %s m3" % [
		_brief(by_xform), _brief(pre), analytic, _brief(from_box), p1, _brief(from_ball), p2, mapped, from_placed.get("volume")])


# ---------------------------------------------------------------- 5 to 8


## The second call on the same two 20k-triangle spheres takes <= 30 % of the first.
func _case_cache() -> void:
	var fa := FIXTURES.icosphere(10.0 * MM, 5)
	var fb := FIXTURES.icosphere(10.0 * MM, 5, Vector3(15.0, 1.0, 0.5) * MM)
	var first := INF
	var second := INF
	var ok := true
	var notes := []
	for run in 3:
		var a := _mesh(fa)
		var b := _mesh(fb)
		var bytes_before: int = a.memory_bytes()
		var started := Time.get_ticks_usec()
		var r1: Dictionary = a.overlap(b, _identity(), {"time_limit": 5.0})
		var t1 := _ms_since(started)
		var bytes_after: int = a.memory_bytes()
		started = Time.get_ticks_usec()
		var r2: Dictionary = a.overlap(b, _identity(), {"time_limit": 5.0})
		var t2 := _ms_since(started)
		first = minf(first, t1)
		second = minf(second, t2)
		ok = ok and r1.get("error", "x") == "" and r1.get("overlap", false) and int(r1.get("built", -1)) == 2 and int(r2.get("built", -1)) == 0 \
			and float(r1.volume) == float(r2.volume) and bytes_after > bytes_before
		notes.append("run %d: %.2f then %.2f ms, built %s then %s, memory %d -> %d bytes" % [run + 1, t1, t2, r1.get("built"), r2.get("built"), bytes_before, bytes_after])
	ok = ok and second <= 0.3 * first
	_report("#5 cache", ok, "fastest first call %.2f ms, fastest second %.2f ms (%.0f %%; limit 30 %%); %s" % [first, second, 100.0 * second / first, "; ".join(notes)])


## Two 200k-triangle meshes, time_limit 0.05: timed_out within 1.05 s; with time the same pair works.
func _case_bound() -> void:
	var grid := FIXTURES.large_grid(129)
	var a := _mesh(grid)
	var b: RefCounted = a.transformed(Transform3D(Basis.IDENTITY, Vector3(50.3, 50.2, 50.1) * MM))
	var started := Time.get_ticks_usec()
	var r: Dictionary = a.overlap(b, _identity(), {"time_limit": 0.05})
	var ms := _ms_since(started)
	started = Time.get_ticks_usec()
	var whole: Dictionary = a.overlap(b, _identity(), {"time_limit": 20.0})
	var whole_ms := _ms_since(started)
	var ba: AABB = a.bbox()
	var bb: AABB = b.bbox()
	var lo := Vector3(maxf(ba.position.x, bb.position.x), maxf(ba.position.y, bb.position.y), maxf(ba.position.z, bb.position.z))
	var hi := Vector3(minf(ba.end.x, bb.end.x), minf(ba.end.y, bb.end.y), minf(ba.end.z, bb.end.z))
	var expected := float(hi.x - lo.x) * float(hi.y - lo.y) * float(hi.z - lo.z)
	var ok: bool = a.triangle_count() == 199692 and r.get("timed_out", false) == true and ms <= 1050.0 \
		and whole.get("error", "x") == "" and not whole.get("timed_out", true) and _near(whole.volume, expected, 1e-5)
	_report("#6 bound", ok, "limit 0.05 s: back after %.1f ms, %s; limit 20 s: %.1f ms, %s (expected %s m3)" % [ms, _brief(r), whole_ms, _brief(whole), expected])


## Open and inside-out meshes are refused with the C5.1 sentences, on either side, at once.
func _case_refusals() -> void:
	var cube := _mesh(FIXTURES.cube(20.0 * MM))
	var plate := _mesh(FIXTURES.open_plate())
	var flipped := _mesh(FIXTURES.flipped(FIXTURES.cube(20.0 * MM)))
	var empty := _new()
	var rows := []
	var ok := true
	for item: Array in [[cube, plate, OPEN_ERROR, "other"], [plate, cube, OPEN_ERROR, "this"], [cube, flipped, INSIDE_OUT_ERROR, "other"],
			[flipped, cube, INSIDE_OUT_ERROR, "this"]]:
		var started := Time.get_ticks_usec()
		var r: Dictionary = (item[0] as RefCounted).overlap(item[1], _identity(), {})
		var ms := _ms_since(started)
		ok = ok and r.get("error", "") == item[2] and r.get("refused", "") == item[3] and not r.get("overlap", true) and ms <= 200.0
		rows.append("'%s' (%s, %.2f ms)" % [r.get("error", ""), r.get("refused", ""), ms])
	var r_empty: Dictionary = cube.overlap(empty, _identity(), {})
	ok = ok and str(r_empty.get("error", "")).begins_with("Contact needs closed bodies: the mesh") and r_empty.get("refused", "") == "other"
	rows.append("empty: '%s'" % r_empty.get("error", ""))
	_report("#7 refusals", ok, "; ".join(rows))


## A changed mesh never answers from its old geometry. Meshes cannot change once made, so the
## only change is an instance that gets its arrays (an empty one) or a new mesh from an op.
func _case_changed() -> void:
	var size := Vector3(20, 20, 20) * MM
	var a := _box(Vector3.ZERO, size)
	var b := _box(Vector3(19, 0, 0) * MM, Vector3(39, 20, 20) * MM)
	var r1: Dictionary = a.overlap(b, _identity(), {})
	# An op's result is a new mesh: its Manifold is built from its own geometry.
	var moved: RefCounted = a.transformed(Transform3D(Basis.IDENTITY, Vector3(-0.5, 0, 0) * MM))
	var r2: Dictionary = moved.overlap(b, _identity(), {})
	var w2 := float((size.x - 0.5 * MM) - (19.0 * MM))
	var moved_hi: float = moved.bbox().end.x
	var expected2 := (moved_hi - (Vector3(19, 0, 0) * MM).x) * size.y * size.z
	# An instance that had no arrays (refused) gets them: the overlap is the new geometry's.
	var late := _new()
	var r3: Dictionary = late.overlap(b, _identity(), {})
	var late_lo := Vector3(15, 0, 0) * MM
	var late_hi := Vector3(35, 20, 20) * MM
	var fixture := _box_fixture(late_lo, late_hi)
	late.set_arrays(fixture.positions, fixture.indices, fixture.groups, fixture.names, "godot")
	var r4: Dictionary = b.overlap(late, _identity(), {})
	var expected4 := (late_hi.x - (Vector3(19, 0, 0) * MM).x) * size.y * size.z
	# A made mesh refuses new arrays, and its cached overlap stays the same.
	var refused: bool = not a.set_arrays(fixture.positions, fixture.indices, fixture.groups, fixture.names, "godot")
	var r5: Dictionary = a.overlap(b, _identity(), {})
	var ok: bool = r1.get("error", "x") == "" and r2.get("error", "x") == "" and int(r2.get("built", -1)) == 1 and _near(r2.volume, expected2, 1e-9) \
		and _near(r2.volume, w2 * size.y * size.z, 1e-6) and str(r3.get("error", "")) != "" and r3.get("refused", "") == "this" \
		and r4.get("error", "x") == "" and int(r4.get("built", -1)) == 1 and r4.get("overlap", false) and _near(r4.volume, expected4, 1e-9) \
		and refused and r5.volume == r1.volume and int(r5.get("built", -1)) == 0
	_report("#8 changed mesh", ok, "before %s m3; moved 0.5 mm: %s (expected %s); empty then filled: '%s', then %s; set_arrays on a made mesh refused: %s, %s" % [
		float(r1.get("volume", -1.0)), _brief(r2), expected2, r3.get("error", ""), _brief(r4), refused, _brief(r5)])


# ---------------------------------------------------------------- 9 to 11


func _case_timing() -> void:
	var calibration := func() -> void:
		var sphere: RefCounted = kernel.make_sphere(0.02, Vector3.ZERO, "cal")
		sphere.tessellate(0.0002, 0.3)
	var size := Vector3(20, 20, 20) * MM
	var a12 := _box(Vector3.ZERO, size)
	var b12 := _box(Vector3(19, 1, 2) * MM, Vector3(39, 21, 22) * MM)
	var fa := FIXTURES.icosphere(10.0 * MM, 5)
	var fb := FIXTURES.icosphere(10.0 * MM, 5, Vector3(15.0, 1.0, 0.5) * MM)
	var a20 := _mesh(fa)
	var b20 := _mesh(fb)
	var grid := FIXTURES.large_grid(129)
	var a200 := _mesh(grid)
	var b200: RefCounted = a200.transformed(Transform3D(Basis.IDENTITY, Vector3(50.3, 50.2, 50.1) * MM))
	var id := _identity()
	# Caches built once (the sweep's steady state).
	for pair: Array in [[a12, b12], [a20, b20], [a200, b200]]:
		(pair[0] as RefCounted).overlap(pair[1], id, {"time_limit": 20.0})
	var results := {}
	results["overlap_2x12"] = TIMING.compare(func() -> void: a12.overlap(b12, id, {}), calibration, 5, "overlap 2 x 12")
	results["overlap_2x20k"] = TIMING.compare(func() -> void: a20.overlap(b20, id, {}), calibration, 5, "overlap 2 x 20k")
	results["overlap_2x200k"] = TIMING.compare(func() -> void: a200.overlap(b200, id, {"time_limit": 20.0}), calibration, 3, "overlap 2 x 200k")
	var first := func() -> void:
		var x := _mesh(fa)
		var y := _mesh(fb)
		x.overlap(y, id, {"time_limit": 20.0})
	results["overlap_2x20k_first"] = TIMING.compare(first, calibration, 3, "overlap 2 x 20k, first call")
	var targets := {"overlap_2x12": 1.0, "overlap_2x20k": 30.0, "overlap_2x200k": 400.0, "overlap_2x20k_first": 90.0}
	var parts := []
	var ok := true
	for key: String in LIMITS:
		var r: Dictionary = results[key]
		parts.append("%s %.3f ms (C9 target %.0f ms), ratio %.4f, limit %s" % [key, r.op, targets[key], r.ratio, LIMITS[key]])
		if float(LIMITS[key]) > 0.0:
			ok = ok and r.ratio <= LIMITS[key]
		else:
			ok = false
	_report("#9 timing", ok, "calibration %.2f ms; %s" % [results["overlap_2x12"].calibration, "; ".join(parts)])


## A 20 mm cube 100 km from the origin: the result comes with a warning that names the distance.
func _case_far() -> void:
	var far := Vector3(100000.0, 0, 0)
	var a := _mesh(FIXTURES.cube(20.0 * MM, far))
	var b := _mesh(FIXTURES.cube(20.0 * MM, far + Vector3(10.0, 0, 0) * MM))
	var near := _mesh(FIXTURES.cube(20.0 * MM))
	var r: Dictionary = a.overlap(b, _identity(), {})
	var r_near: Dictionary = near.overlap(near, _move(0.01, 0, 0), {})
	var warning := str(r.get("warning", ""))
	var ok: bool = r.get("error", "x") == "" and warning.contains("from the origin") and warning.contains("100 km") and float(r.get("step", 0.0)) > 0.001 * MM \
		and str(r_near.get("warning", "x")) == ""
	_report("#10 far from the origin", ok, "warning '%s', step %s m; near the origin: warning '%s'" % [warning, r.get("step"), r_near.get("warning", "?")])


## Not 12 numbers, not finite, a scale, a mirror: refused before any work.
func _case_bad_placement() -> void:
	var a := _mesh(FIXTURES.cube(20.0 * MM))
	var rows := []
	var ok := true
	for xf: PackedFloat64Array in [PackedFloat64Array([1, 0, 0, 0, 1, 0, 0, 0, 1]), PackedFloat64Array([1, 0, 0, 0, 1, 0, 0, 0, 1, NAN, 0, 0]),
			PackedFloat64Array([2, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0]), PackedFloat64Array([-1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0])]:
		var started := Time.get_ticks_usec()
		var r: Dictionary = a.overlap(a, xf, {})
		var ms := _ms_since(started)
		ok = ok and str(r.get("error", "")) != "" and not r.get("overlap", true) and ms <= 200.0
		rows.append("'%s' (%.2f ms)" % [r.get("error", ""), ms])
	_report("#11 placement refusals", ok, "; ".join(rows))


## Meshes that cross themselves (the verifier's p7_native fixtures): two spheres in one mesh
## against a cube in their shared lens, and two overlapping cubes in one mesh against a cube inside
## both. Manifold counts the doubly covered part twice there, so no number is given: the error
## names the mesh problem and the repair, self_crossing is true and refused says which side.
func _case_self_crossing() -> void:
	var lens := _mesh(FIXTURES.self_crossing())
	var lens_probe := _mesh(FIXTURES.cube(10.0 * MM, Vector3(10.0 * MM, 0, 0)))
	var twin := _mesh(FIXTURES.two_cubes(Vector3(10, 0, 0) * MM))
	var twin_probe := _mesh(FIXTURES.cube(6.0 * MM, Vector3(8.0, 0, 0) * MM))
	var rows := []
	var ok := true
	for item: Array in [[lens, lens_probe, "this"], [lens_probe, lens, "other"], [twin, twin_probe, "this"], [twin_probe, twin, "other"]]:
		var started := Time.get_ticks_usec()
		var r: Dictionary = (item[0] as RefCounted).overlap(item[1], _identity(), {})
		var ms := _ms_since(started)
		var error := str(r.get("error", ""))
		ok = ok and r.get("self_crossing", false) == true and r.get("refused", "") == item[2] and error.contains("crosses itself") and error.contains("Repair") \
			and not error.contains("fault") and not r.get("overlap", true) and not bool(r.get("timed_out", true)) and ms <= 1000.0
		rows.append("'%s' (self_crossing %s, refused %s, %.2f ms)" % [error, r.get("self_crossing"), r.get("refused", ""), ms])
	# A second call answers from the kept count, fast.
	var started := Time.get_ticks_usec()
	var again: Dictionary = lens.overlap(lens_probe, _identity(), {})
	var again_ms := _ms_since(started)
	ok = ok and again.get("self_crossing", false) == true and again_ms <= 50.0
	# Boxes apart: no overlap is right even for a mesh that crosses itself; clean pairs say false.
	var apart: Dictionary = lens.overlap(lens_probe, _move(0.2, 0, 0), {})
	var a := _box(Vector3.ZERO, Vector3(20, 20, 20) * MM)
	var b := _box(Vector3(19, 0, 0) * MM, Vector3(39, 20, 20) * MM)
	var clean: Dictionary = a.overlap(b, _identity(), {})
	ok = ok and apart.get("error", "x") == "" and apart.get("self_crossing", true) == false and bool(apart.get("early_out", false)) \
		and clean.get("error", "x") == "" and clean.get("self_crossing", true) == false and bool(clean.get("overlap", false))
	_report("#12 self-crossing", ok, "%s; again %.2f ms; boxes apart: error '%s', self_crossing %s; clean pair: self_crossing %s, volume %s m3" % [
		"; ".join(rows), again_ms, apart.get("error", "?"), apart.get("self_crossing"), clean.get("self_crossing"), float(clean.get("volume", -1.0))])
