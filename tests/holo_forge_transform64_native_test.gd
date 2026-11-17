extends SceneTree
## Holo Forge Phase 8 fix round 1 (verifier finding B4): moves that take doubles.
##   CadKernel.transform_shape64(shape, m, tag := "move") -> CadShape
##   CadMesh.transformed64(m) -> CadMesh
## m is an xform64 (core/assembly/xform64.gd): 12 doubles, the basis columns X, Y, Z, then the origin.
##   1  both methods exist
##   2  a B-rep box moved 100 km (and turned) and back lands within 1e-9 m of where it was; the same
##      round trip through the float32 transform_shape is shown next to it (it misses by millimetres)
##   3  the moved shape keeps its face and edge names, its volume, and lies where m puts it
##   4  refusals: not 12 numbers, not finite, a scale, a mirror (null with a sentence, at once)
##   5  a mesh moved by transformed64 holds float32(m applied in doubles) exactly at every vertex,
##      where transformed (Transform3D, float32) rounds the move first
##   6  mesh refusals: as in 4, and a move past 1,000 km
##
## godot --headless --path . --script res://tests/holo_forge_transform64_native_test.gd

const FIXTURES := preload("res://tests/holo_forge_mesh_fixtures.gd")
const XFORM := preload("res://addons/holo_forge/core/assembly/xform64.gd")
const MM := 0.001
const NAME := "holo_forge_transform64_native"
const CASES := ["#1 methods", "#2 100 km round trip", "#3 names and place", "#4 shape refusals", "#5 mesh in doubles", "#6 mesh refusals"]

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
	kernel = ClassDB.instantiate("CadKernel")
	var has_shape := ClassDB.class_has_method("CadKernel", "transform_shape64")
	var has_mesh := ClassDB.class_has_method("CadMesh", "transformed64")
	_report("#1 methods", has_shape and has_mesh, "CadKernel.transform_shape64 %s, CadMesh.transformed64 %s" % [has_shape, has_mesh])
	if not (has_shape and has_mesh):
		for name: String in CASES.slice(1):
			_report(name, false, "the loaded native library has no double-precision moves")
		quit(1)
		return
	_case_round_trip()
	_case_names_and_place()
	_case_shape_refusals()
	_case_mesh_doubles()
	_case_mesh_refusals()
	print(("PASS %s: all cases." % NAME) if failed == 0 else ("FAIL %s: %d case(s) failed." % [NAME, failed]))
	quit(0 if failed == 0 else 1)


func _report(name: String, ok: bool, detail: String) -> void:
	if ok:
		print("PASS %s %s: %s" % [NAME, name, detail])
	else:
		failed += 1
		push_error("%s %s: %s" % [NAME, name, detail])
		print("FAIL %s %s: %s" % [NAME, name, detail])


## A turn of `angle` about a (normalized) axis, then a move: an xform64 built in doubles.
func _pose(axis: Vector3, angle: float, x: float, y: float, z: float) -> PackedFloat64Array:
	var len := sqrt(float(axis.x) * axis.x + float(axis.y) * axis.y + float(axis.z) * axis.z)
	var ux := float(axis.x) / len
	var uy := float(axis.y) / len
	var uz := float(axis.z) / len
	var c := cos(angle)
	var s := sin(angle)
	var t := 1.0 - c
	# Columns of the rotation matrix (Rodrigues).
	return PackedFloat64Array([
		t * ux * ux + c, t * ux * uy + s * uz, t * ux * uz - s * uy,
		t * ux * uy - s * uz, t * uy * uy + c, t * uy * uz + s * ux,
		t * ux * uz + s * uy, t * uy * uz - s * ux, t * uz * uz + c,
		x, y, z])


## Distances from a shape to probe points around a 20 mm box (doubles, from OCCT).
func _probe_distances(shape: RefCounted, probes: Array) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for probe: RefCounted in probes:
		out.append(float(kernel.closest_points(shape, probe).get("distance", INF)))
	return out


func _probes(m := PackedFloat64Array()) -> Array:
	var points := [Vector3(31, 7, 5), Vector3(-6, 25, 9), Vector3(4, -3, -8), Vector3(10, 10, 33), Vector3(26, 27, 28)]
	var out := []
	for p: Vector3 in points:
		var v: RefCounted = kernel.make_vertex(p * MM)
		out.append(v if m.is_empty() else kernel.transform_shape64(v, m))
	return out


## The largest gap between where the round trip left a shape and the original (OCCT distances in
## doubles to probe points; and from each probe moved alone and back to itself).
func _worst(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	var worst := 0.0
	for i in a.size():
		worst = maxf(worst, absf(a[i] - b[i]))
	return worst


func _case_round_trip() -> void:
	var box: RefCounted = kernel.make_box(Vector3(20, 20, 20) * MM, Vector3.ZERO, "box")
	var m := _pose(Vector3(1, 2, 3), 0.7, 100000.0, 33000.0, -100000.0)
	var back := XFORM.inverse(m)
	var there: RefCounted = kernel.transform_shape64(box, m)
	var again: RefCounted = kernel.transform_shape64(there, back) if there != null else null
	var probes := _probes()
	var before := _probe_distances(box, probes)
	var after := _probe_distances(again, probes) if again != null else PackedFloat64Array()
	var gap := _worst(before, after) if after.size() == before.size() else INF
	# A single vertex moved out and back: its distance to the original.
	var vertex: RefCounted = kernel.make_vertex(Vector3(13, 7, 3) * MM)
	var vertex_there: RefCounted = kernel.transform_shape64(vertex, m)
	var vertex_back: RefCounted = kernel.transform_shape64(vertex_there, back) if vertex_there != null else null
	var vertex_gap := float(kernel.closest_points(vertex, vertex_back).get("distance", INF)) if vertex_back != null else INF
	# The float32 path: the same move through Transform3D.
	var there32: RefCounted = kernel.transform_shape(box, XFORM.to_transform(m), "move")
	var again32: RefCounted = kernel.transform_shape(there32, XFORM.to_transform(back), "move")
	var gap32 := _worst(before, _probe_distances(again32, probes))
	var vertex32: RefCounted = kernel.transform_shape(kernel.transform_shape(vertex, XFORM.to_transform(m), "move"), XFORM.to_transform(back), "move")
	var vertex_gap32 := float(kernel.closest_points(vertex, vertex32).get("distance", INF))
	# The volume: faces within 1e-9 m of where they were change it by at most the area x 1e-9 m.
	var volume_change := absf(float(again.volume()) - float(box.volume())) if again != null else INF
	var volume_kept := volume_change <= 6.0 * 0.02 * 0.02 * 1e-9
	var ok := gap <= 1e-9 and vertex_gap <= 1e-9 and volume_kept and gap32 > 1e-6
	_report("#2 100 km round trip", ok, "doubles: probe distances off by %s m, a vertex off by %s m, the volume by %s m3; float32 transform_shape: probes off by %s m, the vertex by %s m" % [
		String.num_scientific(gap), String.num_scientific(vertex_gap), String.num_scientific(volume_change), String.num_scientific(gap32), String.num_scientific(vertex_gap32)])


func _case_names_and_place() -> void:
	var box: RefCounted = kernel.make_box(Vector3(20, 20, 20) * MM, Vector3.ZERO, "box")
	var m := _pose(Vector3(0, 0, 1), 0.3, 0.25, -0.125, 0.5)
	var moved: RefCounted = kernel.transform_shape64(box, m)
	var ok: bool = moved != null and moved.get_face_names() == box.get_face_names() and moved.get_edge_names() == box.get_edge_names() \
		and absf(float(moved.volume()) - float(box.volume())) <= 1e-12 * float(box.volume())
	# Where it lies: moved probes are as far from the moved box as the probes from the box.
	var gap := INF
	if moved != null:
		gap = _worst(_probe_distances(box, _probes()), _probe_distances(moved, _probes(m)))
	ok = ok and gap <= 1e-12
	_report("#3 names and place", ok, "names kept %s, volume %s -> %s m3, probes off by %s m" % [
		moved != null and moved.get_face_names() == box.get_face_names(), box.volume(), moved.volume() if moved != null else "null", String.num_scientific(gap)])


func _case_shape_refusals() -> void:
	var box: RefCounted = kernel.make_box(Vector3(20, 20, 20) * MM, Vector3.ZERO, "box")
	var rows := []
	var ok := true
	for m: PackedFloat64Array in [PackedFloat64Array([1, 0, 0, 0, 1, 0, 0, 0, 1]), PackedFloat64Array([1, 0, 0, 0, 1, 0, 0, 0, 1, NAN, 0, 0]),
			PackedFloat64Array([2, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0]), PackedFloat64Array([-1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]),
			PackedFloat64Array([1, 1e-6, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0])]:
		var started := Time.get_ticks_usec()
		var out: RefCounted = kernel.transform_shape64(box, m)
		var ms := (Time.get_ticks_usec() - started) / 1000.0
		var error := str(kernel.get_last_error())
		ok = ok and out == null and error != "" and not error.contains("fault") and ms <= 200.0
		rows.append("'%s' (%.2f ms)" % [error, ms])
	# Nearly rigid (1e-12, what xform64 composes to) is taken and made exactly rigid.
	var near := PackedFloat64Array([1, 1e-12, 0, 0, 1, 0, 0, 0, 1, 0.1, 0, 0])
	var taken: RefCounted = kernel.transform_shape64(box, near)
	ok = ok and taken != null and kernel.get_last_error() == ""
	rows.append("1e-12 off rigid: %s" % ("taken" if taken != null else kernel.get_last_error()))
	_report("#4 shape refusals", ok, "; ".join(rows))


func _case_mesh_doubles() -> void:
	var fixture := FIXTURES.icosphere(10.0 * MM, 3)
	var mesh := FIXTURES.to_mesh(fixture)
	var m := _pose(Vector3(1, -1, 2), 1.1, 1.0 / 3.0, 2.0 / 7.0, 0.1)
	var moved: RefCounted = mesh.transformed64(m)
	var moved32: RefCounted = mesh.transformed(XFORM.to_transform(m))
	var exact := 0
	var exact32 := 0
	var total := 0
	if moved != null:
		var positions: PackedVector3Array = mesh.get_arrays().positions
		var got: PackedVector3Array = moved.get_arrays().positions
		var got32: PackedVector3Array = moved32.get_arrays().positions
		total = positions.size()
		for i in total:
			var p := XFORM.apply(m, PackedFloat64Array([positions[i].x, positions[i].y, positions[i].z]))
			var want := Vector3(p[0], p[1], p[2])  # float32 rounding of the double result
			exact += 1 if got[i] == want else 0
			exact32 += 1 if got32[i] == want else 0
	var ok: bool = moved != null and total > 0 and exact == total and moved.triangle_count() == mesh.triangle_count() and exact32 < total
	_report("#5 mesh in doubles", ok, "transformed64: %d of %d vertices exactly float32(m p in doubles); transformed (float32 move): %d of %d" % [exact, total, exact32, total])


func _case_mesh_refusals() -> void:
	var mesh := FIXTURES.to_mesh(FIXTURES.cube(20.0 * MM))
	var rows := []
	var ok := true
	for m: PackedFloat64Array in [PackedFloat64Array([1, 0, 0, 0, 1, 0, 0, 0, 1]), PackedFloat64Array([1, 0, 0, 0, 1, 0, 0, 0, 1, INF, 0, 0]),
			PackedFloat64Array([2, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0]), PackedFloat64Array([-1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]),
			PackedFloat64Array([1, 0, 0, 0, 1, 0, 0, 0, 1, 2.0e6, 0, 0])]:
		var started := Time.get_ticks_usec()
		var out: RefCounted = mesh.transformed64(m)
		var ms := (Time.get_ticks_usec() - started) / 1000.0
		var error := str(mesh.get_last_error())
		ok = ok and out == null and error != "" and ms <= 200.0
		rows.append("'%s' (%.2f ms)" % [error, ms])
	_report("#6 mesh refusals", ok, "; ".join(rows))
