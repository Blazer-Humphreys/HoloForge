extends SceneTree
## Holo Forge Convert Mesh, regressions (Phase 7 fix round; verifier V3's findings B1, B2, B3, B5,
## P1 to P3, N1 to N3, N7, N8, F8). Each case is the verifier's smallest input.
##
## Time bounds: Faceted with one flat face of a long outline (a comb and a perforated plate of
## 20,000 triangles), Prismatic on a 0.16 mm body, Organic on a 0.2 mm ball: each back within its
## limit + 1 s, with a body. A time refusal is kept, so a rebuild answers at once.
## Wrong bodies: a Prismatic body whose drawn triangles leave a gap is refused or repaired.
## Needless refusals: crossing holes of equal radius, rounds far from the origin and on small
## bodies, a ball as one round area, a hole that touches a riser; sentences that say what helps.
##
## godot --headless --path . --script res://tests/holo_forge_mesh_regress_convert_test.gd

const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const INSERT := preload("res://addons/holo_forge/core/features/insert.gd")
const MESH_FEATURE := preload("res://addons/holo_forge/core/features/mesh.gd")
const MESH_CONVERT := preload("res://addons/holo_forge/core/features/mesh_convert.gd")
const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")
const MESH_BLOB := preload("res://addons/holo_forge/core/mesh/mesh_blob.gd")
const ORGANIC := preload("res://addons/holo_forge/core/mesh/organic.gd")
const FIXTURES := preload("res://tests/holo_forge_mesh_fixtures.gd")
const TESSELLATE := preload("res://addons/holo_forge/core/tessellate.gd")

const MM := 0.001
const X := Vector3(1, 0, 0)
const Y := Vector3(0, 1, 0)
const Z := Vector3(0, 0, 1)

var failures: Array[String] = []
var checked: Array[String] = []
var notes: Array[String] = []
var kernel: RefCounted
var _started := false
var _finished := false


func _init() -> void:
	call_deferred("run")


func _process(_delta: float) -> bool:
	if _started and not _finished:
		print("FAIL holo_forge_mesh_regress_convert: the test stopped on a script error.")
		_finished = true
		quit(1)
	return false


func run() -> void:
	_started = true
	kernel = REGEN.make_kernel()
	if kernel == null or not ClassDB.class_exists("CadMesh") or not ClassDB.class_exists("CadSubD"):
		print("NOTE: CadMesh is not registered (the holo_forge native DLL is missing): the convert checks are skipped.")
		print("PASS holo_forge_mesh_regress_convert: skipped, the native library is not loaded.")
		_finished = true
		quit(0)
		return
	var only := OS.get_environment("HOLO_FORGE_MESH_REGRESS_ONLY")
	for part in [["b1", _check_long_outline], ["kept", _check_kept], ["b2", _check_small_prismatic], ["b3", _check_small_organic], ["b5", _check_drawn_closed],
			["p1a", _check_equal_holes], ["p1b", _check_rounds_far_and_small], ["p1d", _check_ball], ["p1e", _check_riser_and_wall], ["p2", _check_organic_sentences],
			["p3", _check_faceted_notes], ["n7", _check_organic_volume], ["n8", _check_far_flat],
			["r1", _check_later_tools], ["c1", _check_feature_time], ["notes2", _check_second_round_notes],
			["r3", _check_third_round]]:
		if only == "" or only.split(",").has(str(part[0])):
			MESH_FEATURE.clear_cache()
			MESH_CONVERT.clear_cache()
			(part[1] as Callable).call()
	for note in notes:
		print("NOTE holo_forge_mesh_regress_convert: " + note)
	if failures.is_empty():
		print("PASS holo_forge_mesh_regress_convert: " + "; ".join(checked) + ".")
	else:
		print("FAIL holo_forge_mesh_regress_convert")
		for failure in failures:
			print("  " + failure)
	_finished = true
	quit(0 if failures.is_empty() else 1)


# --- Helpers ---------------------------------------------------------------------------------

func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _now() -> float:
	return Time.get_ticks_usec() / 1e6


func _new() -> RefCounted:
	return ClassDB.instantiate("CadMesh")


func _mesh_of(positions: PackedVector3Array, indices: PackedInt32Array, groups := PackedInt32Array(), names := PackedStringArray()) -> RefCounted:
	var mesh := _new()
	_expect(mesh.set_arrays(positions, indices, groups, names, "godot"), "A fixture should load (%s)." % mesh.get_last_error())
	return mesh


func _tessellated(shape: RefCounted, detail := 5000.0, degrees := 8.0) -> RefCounted:
	var mesh := _new()
	var diagonal: float = (shape.bbox() as AABB).size.length()
	_expect(mesh.from_shape(shape, diagonal / detail, deg_to_rad(degrees), false, 20.0), "A body should tessellate (%s)." % mesh.get_last_error())
	return mesh


## The mesh scaled, then moved (as the verifier's probes place their bodies).
func _moved(mesh: RefCounted, xform: Transform3D, scale := 1.0) -> RefCounted:
	var arrays: Dictionary = mesh.get_arrays()
	var positions: PackedVector3Array = (arrays.positions as PackedVector3Array).duplicate()
	for i in positions.size():
		positions[i] = xform * (positions[i] * scale)
	return _mesh_of(positions, arrays.indices, arrays.groups, arrays.group_names)


func _box(size: Vector3, origin := Vector3.ZERO) -> RefCounted:
	return kernel.make_box(size * MM, origin * MM)


func _cyl(r: float, h: float, origin: Vector3, axis: Vector3) -> RefCounted:
	return kernel.make_cylinder(r * MM, h * MM, origin * MM, axis)


## A box with the edges picked by `wanted` (edge info -> bool) rounded.
func _rounded(size: Vector3, radius: float, wanted: Callable) -> RefCounted:
	var box := _box(size)
	var edges := PackedInt32Array()
	for e in int(box.edge_count()):
		if wanted.call(box.edge_info(e)):
			edges.append(e)
	var out: RefCounted = kernel.fillet(box, edges, {"radius": radius * MM})
	_expect(out != null, "A rounded box should build (%s)." % kernel.get_last_error())
	return out


func _top_rounded() -> RefCounted:
	return _rounded(Vector3(40, 30, 10), 2.0, func(info: Dictionary) -> bool: return absf((info.midpoint as Vector3).z - 0.01) < 1e-6)


## An open flat plate of n x n squares in two face groups.
func _plate(n: int, size: float, group_of: Callable) -> RefCounted:
	var positions := PackedVector3Array()
	var step := size / n
	for j in n + 1:
		for i in n + 1:
			positions.append(Vector3(i * step, 0.0, j * step))
	var indices := PackedInt32Array()
	var groups := PackedInt32Array()
	for j in n:
		for i in n:
			var a := j * (n + 1) + i
			var b := a + 1
			var c := a + n + 1
			var d := c + 1
			indices.append_array([a, c, b, b, c, d])
			var g: int = group_of.call(i, j)
			groups.append_array([g, g])
	return _mesh_of(positions, indices, groups, PackedStringArray(["g0", "g1"]))


func _add_mesh(doc: Resource, mesh: RefCounted, name := "") -> String:
	var feature: Resource = doc.add_feature("mesh_import", "Mesh", {}, {
		"path": "", "kind": INSERT.KIND_MESH, "units": "mm", "mesh_units": "mm", "linked": false, "split": false,
		"transform": Transform3D.IDENTITY, "operation": OPERATIONS.NEW_BODY, "mesh": MESH_BLOB.from_mesh(mesh),
	})
	var body_id: String = doc.new_body(feature.id)
	feature.options["body_id"] = body_id
	if name != "":
		doc.bodies[body_id]["name"] = name
	return body_id


func _rebuild(doc: Resource, limit := -1.0) -> Dictionary:
	return REGEN.rebuild(doc, kernel, {} if limit < 0.0 else {"mesh_time_limit": limit})


## Open edges of a body's drawn triangles, as the viewport makes them (corners at the same
## place count as one).
func _drawn_open_edges(shape: RefCounted) -> int:
	var linear := clampf(((shape.bbox() as AABB).size.length()) * 0.0015, 0.00001, 0.01)
	var tess: Dictionary = shape.tessellate(linear, 0.3)
	var drawn := _new()
	if not drawn.set_arrays(tess.positions, tess.indices, PackedInt32Array(), PackedStringArray(), "godot"):
		return -1
	var welded: RefCounted = drawn.welded()
	return int((welded.check(2.0) as Dictionary).get("boundary_edges", -1)) if welded != null else -1


func _face_kinds(shape: RefCounted) -> Dictionary:
	var kinds := {}
	for i in int(shape.face_count()):
		var kind := str((shape.face_info(i) as Dictionary).get("type", ""))
		kinds[kind] = int(kinds.get(kind, 0)) + 1
	return kinds


## Prismatic of a kernel body's tessellation, placed: the solid must come back with the
## original's volume. Returns the solid (null when refused, which fails the test).
func _prismatic_back(what: String, shape: RefCounted, xform := Transform3D.IDENTITY, scale := 1.0, options := {}) -> RefCounted:
	var mesh := _tessellated(shape)
	if xform != Transform3D.IDENTITY or scale != 1.0:
		mesh = _moved(mesh, xform, scale)
	var started := _now()
	var solid: RefCounted = mesh.to_prismatic(options)
	var took := _now() - started
	_expect(solid != null, "%s should convert ('%s')." % [what, mesh.get_last_error()])
	_expect(took <= float(options.get("time_limit", 20.0)) + 1.0, "%s should be back within its limit + 1 s (%.2f s)." % [what, took])
	if solid != null:
		var volume := float(shape.volume()) * scale * scale * scale
		_expect(absf(float(solid.volume()) - volume) <= 0.005 * volume, "%s should keep the original's volume (%s against %s)." % [what, str(solid.volume()), str(volume)])
		_expect(_drawn_open_edges(solid) == 0, "%s should draw closed (%d open edges)." % [what, _drawn_open_edges(solid)])
	return solid


# --- B1: one flat face with a long outline -------------------------------------------------------

func _check_long_outline() -> void:
	var comb := _plate(100, 0.1, func(i: int, j: int) -> int: return 0 if j == 0 or i % 2 == 0 else 1)
	var perforated := _plate(100, 0.1, func(i: int, j: int) -> int: return 1 if i % 2 == 1 and j % 2 == 1 else 0)
	var times := PackedStringArray()
	for item in [["a comb plate", comb, 51], ["a perforated plate", perforated, 2501]]:
		var mesh: RefCounted = item[1]
		for limit: float in [5.0, 20.0]:
			var estimate := float((mesh.convert_defaults("faceted", {"time_limit": limit}) as Dictionary).get("seconds", 0.0))
			var started := _now()
			var shape: RefCounted = mesh.to_faceted({"time_limit": limit})
			var took := _now() - started
			_expect(took <= limit + 1.0, "Faceted of %s (20,000 triangles, one face with about 10,000 outline edges) should be back within its %s s limit + 1 s (%.2f s)." % [item[0], str(limit), took])
			_expect(shape != null or MESH_FEATURE.is_time_refusal(str(mesh.get_last_error())), "Faceted of %s should convert or say it has no time ('%s')." % [item[0], mesh.get_last_error()])
			if limit == 20.0:
				_expect(shape != null and int(shape.face_count()) == int(item[2]) and bool(shape.is_surface()), "Faceted of %s should give %d merged faces (%s; '%s')." % [
					item[0], int(item[2]), str(shape.face_count()) if shape != null else "none", mesh.get_last_error()])
				_expect(took <= maxf(2.0 * estimate, estimate + 1.0), "The estimate for %s should not be far under the real time (%.2f s against %.2f s)." % [item[0], estimate, took])
				if shape != null:
					var linear := clampf(((shape.bbox() as AABB).size.length()) * 0.0015, 0.00001, 0.01)
					var tess: Dictionary = shape.tessellate(linear, 0.3)
					_expect((tess.indices as PackedInt32Array).size() / 3 == 20000 and Array(tess.get("warnings", [])).is_empty(), "The merged plate should draw the mesh's own 20,000 triangles.")
			times.append("%s at %s s: %.2f s" % [item[0], str(limit), took])
	# The largest such plates under the cap (57,800 triangles; about 29,000 and 30,000 outline edges),
	# made to run at limits under their estimate: back within the limit + 1 s, converted or stopped.
	var comb_large := _plate(170, 0.1, func(i: int, j: int) -> int: return 0 if j == 0 or i % 2 == 0 else 1)
	var perforated_large := _plate(170, 0.1, func(i: int, j: int) -> int: return 1 if i % 2 == 1 and j % 2 == 1 else 0)
	for item in [["a comb plate of 57,800 triangles", comb_large, 2.0, 86], ["a perforated plate of 57,800 triangles", perforated_large, 2.0, 7226], ["a comb plate of 57,800 triangles", comb_large, 20.0, 86]]:
		var large: RefCounted = item[1]
		var limit := float(item[2])
		var started := _now()
		var shape: RefCounted = large.to_faceted({"time_limit": limit, "skip_estimate": true})
		var took := _now() - started
		_expect(took <= limit + 1.0, "Faceted of %s should be back within its %s s limit + 1 s (%.2f s)." % [item[0], str(limit), took])
		_expect((shape != null and int(shape.face_count()) == int(item[3])) or MESH_FEATURE.is_time_refusal(str(large.get_last_error())), "Faceted of %s should convert to %d faces or say it has no time ('%s')." % [item[0], int(item[3]), large.get_last_error()])
		if limit == 20.0:
			_expect(shape != null, "Faceted of %s should convert with the full time ('%s')." % [item[0], large.get_last_error()])
		times.append("%s made to run at %s s: %.2f s, %s" % [item[0], str(limit), took, "converted" if shape != null else "stopped"])
	# When the time does run out, the sentence says what helps. "Reduce the body first" was false
	# while the long outline was what cost (Merge Flat off converted the same plates); now the
	# merged plate converts faster than its triangles as faces do, so it is the true one.
	_expect(comb.to_faceted({"time_limit": 0.05, "skip_estimate": true}) == null, "A 0.05 s limit should stop the comb plate.")
	var stopped := str(comb.get_last_error())
	_expect(MESH_FEATURE.is_time_refusal(stopped) and stopped.contains("Reduce the body first") and not stopped.contains("Merge Flat"), "A time-out should say what helps ('%s')." % stopped)
	var small := _plate(50, 0.1, func(i: int, j: int) -> int: return 0 if j == 0 or i % 2 == 0 else 1)
	var merged_time := _now()
	_expect(small.to_faceted({}) != null, "A comb plate of 5,000 triangles should convert ('%s')." % small.get_last_error())
	merged_time = _now() - merged_time
	var plain_time := _now()
	_expect(small.to_faceted({"merge_flat": false}) != null, "A comb plate of 5,000 triangles should convert without Merge Flat ('%s')." % small.get_last_error())
	plain_time = _now() - plain_time
	_expect(merged_time < plain_time, "With Merge Flat on, the comb plate should convert faster than with it off (%.2f s against %.2f s)." % [merged_time, plain_time])
	checked.append("B1 one flat face with a long outline (%s; Merge Flat on is the faster way: %.2f s against %.2f s at 5,000 triangles, and a time-out says to reduce the body)" % [", ".join(times), merged_time, plain_time])


# --- B1, F8: kept results ------------------------------------------------------------------------

func _check_kept() -> void:
	# A time refusal is kept: the next rebuild with the same time answers at once.
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, FIXTURES.to_mesh(FIXTURES.large_grid(20)), "Grid")
	var feature: Resource = MESH_CONVERT.add_convert(doc, "convert_faceted", [body]).feature
	var first := _rebuild(doc, 0.2)
	_expect(MESH_FEATURE.is_time_refusal(str(first.errors.get(feature.id, ""))), "A 4,800-triangle body at a 0.2 s limit should be refused for time ('%s')." % first.errors.get(feature.id, ""))
	var hits: int = MESH_CONVERT.cache_hits
	var second := _rebuild(doc, 0.2)
	_expect(MESH_CONVERT.cache_hits == hits + 1 and str(second.errors.get(feature.id, "")) == str(first.errors.get(feature.id, "")), "A kept time refusal should answer the next rebuild (%d hits)." % (MESH_CONVERT.cache_hits - hits))
	# With clearly more time it is tried again, and converts.
	var full := _rebuild(doc)
	_expect(not full.errors.has(feature.id), "With the full time the body should convert ('%s')." % full.errors.get(feature.id, ""))
	# More converted bodies than the old 12: a rebuild that changes nothing converts none of them.
	var many: Resource = DOCUMENT.new()
	var features := []
	for k in 14:
		var id := _add_mesh(many, FIXTURES.to_mesh(FIXTURES.icosphere(0.01 + 0.001 * k, 1)), "Ball%d" % k)
		features.append(MESH_CONVERT.add_convert(many, "convert_faceted", [id]).feature)
	var built := _rebuild(many)
	_expect(built.errors.is_empty(), "Fourteen small bodies should convert (%s)." % [built.errors])
	hits = MESH_CONVERT.cache_hits
	var started := _now()
	var again := _rebuild(many)
	var took := _now() - started
	_expect(again.errors.is_empty() and MESH_CONVERT.cache_hits == hits + 14, "A rebuild of fourteen converted bodies should convert none again (%d of 14 kept)." % (MESH_CONVERT.cache_hits - hits))
	checked.append("kept results (a time refusal answers the next rebuild and is tried again with more time; 14 converted bodies all kept, rebuilt in %.2f s)" % took)


# --- B2: Prismatic on a very small body ------------------------------------------------------------

func _check_small_prismatic() -> void:
	var shape := _top_rounded()
	if shape == null:
		return
	var mesh := _tessellated(shape)
	var times := PackedStringArray()
	for scale: float in [0.004, 0.002]:
		var small := _moved(mesh, Transform3D.IDENTITY, scale)
		for limit: float in [2.0, 5.0, 20.0]:
			var started := _now()
			var solid: RefCounted = small.to_prismatic({"time_limit": limit})
			var took := _now() - started
			_expect(took <= limit + 1.0, "Prismatic of a %s mm body should be back within its %s s limit + 1 s (%.2f s)." % [str(40.0 * scale), str(limit), took])
			_expect(solid != null or str(small.get_last_error()) != "", "Prismatic of a small body should convert or say why not.")
			if limit == 20.0:
				var volume := float(shape.volume()) * scale * scale * scale
				_expect(solid != null and absf(float(solid.volume()) - volume) <= 0.005 * volume, "Prismatic of a %s mm body with four rounds should convert as the 40 mm one does ('%s')." % [str(40.0 * scale), small.get_last_error()])
			times.append("x%s at %s s: %.2f s" % [str(scale), str(limit), took])
	checked.append("B2 Prismatic on a 0.16 mm and a 0.08 mm body (%s)" % ", ".join(times))


# --- B3: Organic on a very small body --------------------------------------------------------------

func _check_small_organic() -> void:
	var ball := FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 4))
	var times := PackedStringArray()
	for scale: float in [0.005, 0.002, 0.0005]:
		var small := _moved(ball, Transform3D.IDENTITY, scale)
		var size: float = (small.bbox() as AABB).size.length()
		var started := _now()
		var made := ORGANIC.convert(small, {"faces": 200})
		var took := _now() - started
		_expect(took <= 21.0, "Organic of a ball of r = %s mm should be back within 20 s + 1 s (%.2f s)." % [str(50.0 * scale), took])
		_expect(str(made.error) == "" and made.shape != null, "Organic of a ball of r = %s mm should convert ('%s')." % [str(50.0 * scale), made.error])
		if made.shape != null:
			var shape: RefCounted = made.shape
			var box: AABB = shape.bbox()
			_expect(absf(box.size.length() - size) <= 0.05 * size and box.get_center().length() <= 0.05 * size, "The small ball's solid should have the ball's size and place (%s)." % [box])
			_expect(float((made.report.deviation as Dictionary).max) <= 4.0 * size / 500.0, "The small ball's solid should be within its deviation (%s)." % [made.report.deviation])
			_expect(_drawn_open_edges(shape) >= 0, "The small ball's solid should draw.")
		times.append("r = %s mm: %.2f s" % [str(50.0 * scale), took])
	# Output Form Body: the Form feature rebuilds its cage at the body's own size, which Form does
	# in tens of seconds under about a millimeter (29 s at 0.35 mm). Refused up front for such a
	# body, with what to pick; taken from 2 mm on, and the Form feature then rebuilds in time.
	for item in [[0.002, true], [0.04, false]]:
		var scale := float(item[0])
		var doc: Resource = DOCUMENT.new()
		var id := _add_mesh(doc, _moved(ball, Transform3D.IDENTITY, scale), "Bead")
		var feature: Resource = MESH_CONVERT.add_convert(doc, "convert_organic", [id], {"output": "form_body"}, {"faces": ["200", "number"]}).feature
		var started := _now()
		var built := _rebuild(doc)
		var took := _now() - started
		var error := str(built.errors.get(feature.id, ""))
		if bool(item[1]):
			_expect(error.begins_with("Bead is ") and error.contains("Use Output: Solid Body") and took <= 1.0, "Output Form Body of a ball of r = %s mm should be refused at once with what to pick ('%s', %.2f s)." % [str(50.0 * scale), error, took])
			times.append("Form Body at r = %s mm refused in %.2f s" % [str(50.0 * scale), took])
		else:
			_expect(error == "", "Output Form Body of a ball of r = %s mm should build ('%s')." % [str(50.0 * scale), error])
			var swapped: Dictionary = MESH_CONVERT.form_body(doc, feature)
			started = _now()
			var again := _rebuild(doc)
			took = _now() - started
			_expect(str(swapped.error) == "" and again.errors.is_empty() and took <= 5.0, "The form body of a ball of r = %s mm should rebuild in time ('%s', %s, %.2f s)." % [str(50.0 * scale), swapped.error, again.errors, took])
			times.append("Form Body at r = %s mm rebuilt in %.2f s" % [str(50.0 * scale), took])
	checked.append("B3 Organic on small balls at 200 faces (%s)" % ", ".join(times))


# --- B5: a body whose drawn triangles leave a gap --------------------------------------------------

func _check_drawn_closed() -> void:
	var cross: RefCounted = kernel.boolean(_cyl(5, 40, Vector3(0, 0, -20), Z), _cyl(5, 40, Vector3(-20, 0, 0), X), 0)
	var mesh := _tessellated(cross)
	var results := PackedStringArray()
	for scale: float in [1.0, 250.0, 1000.0]:
		var there := _moved(mesh, Transform3D(Basis(Y, 0.3), Vector3.ZERO), scale)
		var solid: RefCounted = there.to_prismatic({})
		if solid == null:
			_expect(str(there.get_last_error()) != "", "A refused cross should say why.")
			results.append("x%s refused ('%s')" % [str(scale), str(there.get_last_error()).get_slice(". ", 0)])
			_expect(scale != 1.0, "The cross at its own size should convert ('%s')." % there.get_last_error())
			continue
		var open := _drawn_open_edges(solid)
		_expect(open == 0, "A converted cross at x%s should draw closed (%d open edges)." % [str(scale), open])
		results.append("x%s closed" % str(scale))
	checked.append("B5 the drawn triangles of a Prismatic body close (two crossing cylinders turned 0.3 rad: %s)" % ", ".join(results))


# --- P1a: crossing holes of equal radius -----------------------------------------------------------

func _check_equal_holes() -> void:
	var done := PackedStringArray()
	for r: float in [5.0, 4.99, 4.9, 5.01]:
		var block: RefCounted = kernel.boolean(kernel.boolean(_box(Vector3(30, 30, 30)), _cyl(5, 40, Vector3(15, 15, -5), Z), 1), _cyl(r, 40, Vector3(-5, 15, 15), X), 1)
		var solid := _prismatic_back("A block with crossing holes of r = 5 and %s mm" % str(r), block)
		if solid != null:
			done.append("5 / %s mm: %d faces" % [str(r), int(solid.face_count())])
	var offset: RefCounted = kernel.boolean(kernel.boolean(_box(Vector3(30, 30, 30)), _cyl(5, 40, Vector3(15, 15, -5), Z), 1), _cyl(3, 40, Vector3(-5, 19, 15), X), 1)
	if _prismatic_back("A block with an r = 3 hole 4 mm off the axis of an r = 5 hole", offset) != null:
		done.append("3 mm, 4 mm off axis")
	checked.append("P1a crossing holes of equal and nearly equal radius convert (%s)" % ", ".join(done))


# --- P1b, P1c: rounds far from the origin and on small bodies ----------------------------------------

func _check_rounds_far_and_small() -> void:
	var one := _rounded(Vector3(40, 30, 10), 3.0, func(info: Dictionary) -> bool: return absf((info.midpoint as Vector3).z - 0.01) < 1e-6 and absf((info.midpoint as Vector3).x) < 1e-6)
	var four := _top_rounded()
	if one == null or four == null:
		return
	var places := [Transform3D(Basis(Vector3(1, 2, 3).normalized(), 0.7), Vector3(3, 2, -1)), Transform3D(Basis(Vector3(1, 2, 3).normalized(), 0.7), Vector3(10, -5, 8)),
		Transform3D(Basis.IDENTITY, Vector3(100, 50, -80))]
	var count := 0
	for place: Transform3D in places:
		for item in [["one round", one], ["four rounds", four]]:
			# (At 100 m a float holds 8 micrometers: the default tolerance of a 51 mm body is 51.)
			if _prismatic_back("A box with %s at %s m" % [item[0], place.origin], item[1], place) != null:
				count += 1
	for scale: float in [0.1, 0.03, 0.01]:
		if _prismatic_back("A box with four rounds at x%s (%s mm long)" % [str(scale), str(40.0 * scale)], four, Transform3D.IDENTITY, scale) != null:
			count += 1
	checked.append("P1b, P1c rounds far from the origin (3 m, 14 m and 138 m away, turned) and on small bodies (4, 1.2 and 0.4 mm long): %d of 9 converted" % count)


# --- P1d: a ball ---------------------------------------------------------------------------------

func _check_ball() -> void:
	# One face group that is one round area needs no Generate Face Groups.
	var ball := FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 5))
	var solid: RefCounted = ball.to_prismatic({})
	_expect(solid != null and int(solid.face_count()) == 1 and int(_face_kinds(solid).get("sphere", 0)) == 1, "A ball in one face group should convert to one sphere ('%s')." % ball.get_last_error())
	# One group that is several areas still needs its groups.
	var cube := FIXTURES.to_mesh(FIXTURES.large_grid(4))
	_expect(cube.to_prismatic({}) == null and str(cube.get_last_error()).begins_with("Generate Face Groups (Accurate) first"), "A cube in one face group should be sent to Generate Face Groups ('%s')." % cube.get_last_error())
	# A kernel ball through Tessellate and Generate Face Groups (two of its triangles have no
	# area and get groups of their own): it converts, or the refusal says how far off the best fit is.
	var sphere: RefCounted = kernel.make_sphere(0.02, Vector3.ZERO, "ball")
	var grouped: RefCounted = _tessellated(sphere).generate_groups({})
	_expect(grouped != null, "The tessellated ball should take face groups.")
	if grouped != null:
		var back: RefCounted = grouped.to_prismatic({})
		var error := str(grouped.get_last_error())
		_expect(back != null or not error.contains("is not flat or round") or error.contains("(best: "), "A group that fits nothing should be refused with its best fit ('%s')." % error)
		notes.append("P1d a tessellated kernel ball with Generate Face Groups (%d groups): %s" % [int(grouped.group_count()), "converted to %d faces" % int(back.face_count()) if back != null else error])
	checked.append("P1d a ball in one face group converts to one sphere; a one-group cube is still sent to Generate Face Groups")


# --- P1e, P1f: a hole that touches a riser, a wall thinner than the tolerance ----------------------

func _check_riser_and_wall() -> void:
	var step: RefCounted = kernel.boolean(_box(Vector3(40, 30, 10)), _box(Vector3(20, 30, 10), Vector3(0, 0, 10)), 0)
	var holed: RefCounted = kernel.boolean(step, _cyl(4, 20, Vector3(24, 15, -5), Z), 1)
	var mesh := _tessellated(holed)
	var solid: RefCounted = mesh.to_prismatic({})
	var riser := str(mesh.get_last_error())
	_expect(solid != null or (riser != "" and not riser.contains("Generate Face Groups (Accurate)")), "A hole that touches a riser should convert, or be refused without a hint that does not help ('%s')." % riser)
	if solid != null:
		_expect(absf(float(solid.volume()) - float(holed.volume())) <= 0.005 * float(holed.volume()) and _drawn_open_edges(solid) == 0, "The hole at the riser should come back right.")
	notes.append("P1e a hole whose cylinder touches a step's riser: %s" % ("converted to %d faces" % int(solid.face_count()) if solid != null else riser))
	# A 0.5 mm wall with a Fit Tolerance of the wall or more: the two sides fall on one plane.
	var shell: RefCounted = kernel.shell(_box(Vector3(40, 30, 10)), PackedInt32Array(), {"thickness": 0.5 * MM})
	_expect(shell != null, "The thin-walled box should build (%s)." % kernel.get_last_error())
	if shell != null:
		var thin := _tessellated(shell)
		for tolerance: float in [0.5 * MM, 1.0 * MM]:
			_expect(thin.to_prismatic({"tolerance": tolerance}) == null, "A wall as thin as the Fit Tolerance should not convert.")
			var error := str(thin.get_last_error())
			_expect(error.contains("Lower the Fit Tolerance"), "A wall as thin as the Fit Tolerance should be told to lower it ('%s')." % error)
		_expect(thin.to_prismatic({}) != null, "The thin-walled box should convert at the default tolerance ('%s')." % thin.get_last_error())
	checked.append("P1e, P1f a hole at a riser converts or is refused truly; a wall as thin as the Fit Tolerance is told to lower it")


# --- P2: Organic speaks in its own fields ------------------------------------------------------------

func _check_organic_sentences() -> void:
	var foreign := ["Edge Length", "Density", "Passes"]
	var said := PackedStringArray()
	var blob := FIXTURES.to_mesh(FIXTURES.holed_blob().reference)
	var needle := _moved(FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 4)), Transform3D(Basis.from_scale(Vector3(1.0, 0.08, 0.08)), Vector3.ZERO))
	var hollow_fixture := FIXTURES.icosphere(0.05, 3)
	var inner := FIXTURES.icosphere(0.03, 3)
	var hollow_positions: PackedVector3Array = (hollow_fixture.positions as PackedVector3Array).duplicate()
	var hollow_indices: PackedInt32Array = (hollow_fixture.indices as PackedInt32Array).duplicate()
	var base := hollow_positions.size()
	hollow_positions.append_array(inner.positions)
	for i in range(0, (inner.indices as PackedInt32Array).size(), 3):
		# (The void faces inward.)
		hollow_indices.append_array([base + inner.indices[i], base + inner.indices[i + 2], base + inner.indices[i + 1]])
	var hollow := _mesh_of(hollow_positions, hollow_indices)
	for item in [["a blob at 24 faces", blob, {"faces": 24}], ["a needle at 200 faces", needle, {"faces": 200}], ["a hollow ball", hollow, {"faces": 200}]]:
		var made := ORGANIC.convert(item[1], item[2])
		var text := str(made.error) + " " + str(made.warning)
		for word: String in foreign:
			_expect(not text.contains(word), "Organic of %s should not speak of %s ('%s')." % [item[0], word, text])
		said.append("%s: %s" % [item[0], "converted" if str(made.error) == "" else str(made.error)])
	var hollow_error := str(ORGANIC.convert(hollow, {"faces": 200}).error)
	_expect(hollow_error != "" and not hollow_error.contains("Raise Target Cage Faces"), "A hollow ball should not be told to raise Target Cage Faces ('%s')." % hollow_error)
	var low := ORGANIC.convert(blob, {"faces": 24})
	_expect(str(low.error) == "" or str(low.error).contains("Target Cage Faces") or str(low.error).contains("Allowed Deviation"), "Organic at 24 faces should convert or speak of its own fields ('%s')." % low.error)
	for line in said:
		notes.append("P2 " + line)
	checked.append("P2 Organic's refusals speak in Organic's fields (24 faces, a needle, a hollow ball)")


# --- P3, N1 to N3: what Faceted says ---------------------------------------------------------------

func _check_faceted_notes() -> void:
	# The same piece twice in one place.
	var twice := FIXTURES.to_mesh(FIXTURES.two_cubes(Vector3.ZERO))
	var doubled: RefCounted = twice.to_faceted({"name": "Pair"})
	var said := str(twice.get_last_error()) + str(twice.get_last_warning())
	_expect(said.contains("same place"), "Two pieces in one place should be told ('%s')." % said)
	_expect(doubled == null or absf(float(doubled.volume()) - 16000.0 * 1e-9) < 16000.0 * 1e-9 * 1e-5, "Two pieces in one place convert as they are, when they convert.")
	# Two triangles back to back: closed, no volume.
	var corners := PackedVector3Array([Vector3(0, 0, 0), Vector3(0.01, 0, 0), Vector3(0, 0.01, 0)])
	var pillow := _mesh_of(corners, PackedInt32Array([0, 1, 2, 0, 2, 1]))
	for merge: bool in [true, false]:
		_expect(pillow.to_faceted({"merge_flat": merge}) == null and str(pillow.get_last_error()).contains("no volume"), "Two triangles back to back should be refused as a piece with no volume ('%s')." % pillow.get_last_error())
	_expect(pillow.to_prismatic({}) == null and str(pillow.get_last_error()).contains("no volume"), "Prismatic of two triangles back to back should say there is no volume ('%s')." % pillow.get_last_error())
	var flat_made := ORGANIC.convert(pillow, {})
	_expect(flat_made.shape == null and str(flat_made.error).contains("no volume"), "Organic of two triangles back to back should say there is no volume ('%s')." % flat_made.error)
	# A face count that is no number.
	var no_number := ORGANIC.convert(FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 3)), {"faces": NAN})
	_expect(no_number.shape == null and str(no_number.error).begins_with("Target Cage Faces must be a whole number"), "Organic with a face count that is no number should name the field ('%s')." % no_number.error)
	# Such a pair beside a real piece: refused with the tool that takes it out, and that tool does.
	var cube := FIXTURES.large_grid(2)
	var with_pair: PackedVector3Array = (cube.positions as PackedVector3Array).duplicate()
	var pair_indices: PackedInt32Array = (cube.indices as PackedInt32Array).duplicate()
	var first := with_pair.size()
	with_pair.append_array([Vector3(1, 0, 0), Vector3(1.01, 0, 0), Vector3(1, 0.01, 0)])
	pair_indices.append_array([first, first + 1, first + 2, first, first + 2, first + 1])
	var beside := _mesh_of(with_pair, pair_indices)
	_expect(beside.to_faceted({}) == null and str(beside.get_last_error()).contains("1 piece with no volume") and str(beside.get_last_error()).contains("Run Stitch and Remove first"), "A piece with no volume beside a cube should be refused with what takes it out ('%s')." % beside.get_last_error())
	var cleaned: RefCounted = beside.stitch_and_remove({})
	_expect(cleaned != null and cleaned.to_faceted({}) != null, "After Stitch and Remove the cube should convert ('%s')." % (cleaned.get_last_error() if cleaned != null else beside.get_last_error()))
	# The same for the piece that lies twice in one place.
	var single: RefCounted = twice.stitch_and_remove({})
	var once: RefCounted = single.to_faceted({}) if single != null else null
	_expect(once != null and str(single.get_last_warning()) == "" and absf(float(once.volume()) - 8000.0 * 1e-9) < 8000.0 * 1e-9 * 1e-5, "After Stitch and Remove the doubled cube should convert once, with no warning.")
	# A group named like another group's triangle face.
	var grid := FIXTURES.large_grid(2)
	var groups := PackedInt32Array()
	groups.resize((grid.indices as PackedInt32Array).size() / 3)
	for t in groups.size():
		groups[t] = 1 if t < 8 else 0
	var named := _mesh_of(grid.positions, grid.indices, groups, PackedStringArray(["g0", "g0/t9"]))
	var shape: RefCounted = named.to_faceted({})
	_expect(shape != null, "The oddly named cube should convert ('%s')." % named.get_last_error())
	if shape != null:
		var seen := {}
		for name in shape.get_face_names():
			_expect(not seen.has(name), "Two faces should not share the name '%s'." % name)
			seen[name] = true
	# One inside-out piece is one piece.
	var inside_out: RefCounted = FIXTURES.to_mesh(FIXTURES.icosphere(0.02, 2)).reverse({"mode": "whole"})
	_expect(inside_out.to_faceted({"name": "Ball"}) == null and str(inside_out.get_last_error()) == "Ball has 1 part that is inside-out. Reverse Normal can fix it.", "One inside-out part should be said in the singular ('%s')." % inside_out.get_last_error())
	checked.append("P3, N1 to N3 Faceted (the same piece twice in one place is told; a piece with no volume refused; face names never shared; '1 part that is inside-out')")


# --- N7: Organic's volume --------------------------------------------------------------------------

func _check_organic_volume() -> void:
	# (The verifier's disc: 100 x 8 x 100 mm, 20,480 triangles, 500 faces, Allowed Deviation D / 10.
	# It came back 27 % short of the mesh's volume.)
	var disc := _moved(FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 5)), Transform3D(Basis.from_scale(Vector3(1.0, 0.08, 1.0)), Vector3.ZERO))
	var size: float = (disc.bbox() as AABB).size.length()
	var started := _now()
	var made := ORGANIC.convert(disc, {"faces": 500, "tolerance": size / 10.0})
	var took := _now() - started
	if made.shape != null:
		_expect(absf(float(made.report.get("volume_change", 1.0))) <= 0.05, "A converted disc should hold the mesh's volume within 5 %% (%s)." % str(made.report.get("volume_change")))
	else:
		_expect(str(made.error).contains("volume") or str(made.error).contains("away from"), "A refused disc should say what is off ('%s')." % made.error)
	_expect(took <= 21.0, "The disc should be back within 20 s + 1 s (%.2f s)." % took)
	notes.append("N7 a thin disc at 500 faces and the largest Allowed Deviation (%.2f s): %s" % [took, "converted, volume off by %s" % str(made.report.get("volume_change")) if made.shape != null else str(made.error)])
	checked.append("N7 Organic refuses a solid more than 5 % off the mesh's volume")


# --- N8: flat groups far from the origin -----------------------------------------------------------

func _check_far_flat() -> void:
	var bracket: RefCounted = FIXTURES.l_bracket().mesh
	# (Turned: its flat faces lie along no axis, so the corners stored 138 m out leave them rough.)
	var far := _moved(bracket, Transform3D(Basis(Vector3(1, 2, 3).normalized(), 0.7), Vector3(100, 50, -80)))
	var shape: RefCounted = far.to_faceted({})
	_expect(shape != null, "The bracket 138 m from the origin should convert ('%s')." % far.get_last_error())
	if shape != null:
		var merged := int((far.get_last_report().output as Dictionary).merged_faces)
		var warning := str(far.get_last_warning())
		_expect(merged == 8 or warning.contains("Flat Tolerance"), "Flat groups left unmerged far from the origin should be told (%d of 8 merged; '%s')." % [merged, warning])
		notes.append("N8 the bracket 138 m from the origin: %d of 8 flat groups merged; '%s'" % [merged, warning])
	# The Flat Tolerance it names merges them all, with nothing left to say.
	var told: RefCounted = far.to_faceted({"flat_tolerance": 0.00005})
	_expect(told != null and int((far.get_last_report().output as Dictionary).merged_faces) == 8 and str(far.get_last_warning()) == "", "At the Flat Tolerance the warning names (0.05 mm) all 8 flat groups should merge ('%s', '%s')." % [far.get_last_error(), far.get_last_warning()])
	checked.append("N8 flat groups left unmerged far from the origin are told, and the Flat Tolerance named merges them")


# --- R1 (second round): a converted body in the Solid tools and the display ------------------------

## What the viewport draws of a body (core/tessellate.gd, the display's own call): the share of
## the body's area its triangles cover, their open edges, and the worst face's share.
func _drawn(shape: RefCounted) -> Dictionary:
	var tess: Dictionary = TESSELLATE.tessellate(shape)
	var positions: PackedVector3Array = tess.get("positions", PackedVector3Array())
	var indices: PackedInt32Array = tess.get("indices", PackedInt32Array())
	var ids: PackedInt32Array = tess.get("face_ids", PackedInt32Array())
	var per := PackedFloat64Array()
	per.resize(int(shape.face_count()))
	var total := 0.0
	for t in ids.size():
		var a := positions[indices[t * 3]]
		var area := 0.5 * (positions[indices[t * 3 + 1]] - a).cross(positions[indices[t * 3 + 2]] - a).length()
		total += area
		if ids[t] >= 0 and ids[t] < per.size():
			per[ids[t]] += area
	var worst := 1.0
	for i in per.size():
		var own := float((shape.face_info(i) as Dictionary).get("area", 0.0))
		if own > 0.0:
			worst = minf(worst, per[i] / own)
	var open := -1
	if indices.size() >= 3:
		var drawn := _new()
		if drawn.set_arrays(positions, indices, PackedInt32Array(), PackedStringArray(), "godot"):
			var welded: RefCounted = drawn.welded()
			open = int((welded.check(2.0) as Dictionary).get("boundary_edges", -1)) if welded != null else -1
	return {"cover": total / maxf(float(shape.area()), 1e-30), "worst": worst, "open": open, "warnings": Array(tess.get("warnings", []))}


## A converted body must be drawn as the kernel's own body is after the same tool: every face
## covered (97 % of its area: the triangles' chords across a bend are the rest) and no open edge.
## Returns "" when it is, else what is wrong. (Where the kernel's own body is drawn wrong too,
## the tool or the size is the cause, not the conversion: said in `both`.)
func _as_the_kernels(what: String, converted: RefCounted, own: RefCounted, both: PackedStringArray) -> String:
	if converted == null and own == null:
		return ""
	if converted == null:
		return "%s: the tool failed on the converted body (%s) and worked on the kernel's own" % [what, kernel.get_last_error()]
	if own == null:
		return ""
	var a := _drawn(converted)
	var b := _drawn(own)
	var a_right: bool = int(a.open) == 0 and float(a.worst) >= 0.97
	var b_right: bool = int(b.open) == 0 and float(b.worst) >= 0.97
	if a_right:
		return ""
	if not b_right:
		both.append(what)
		return ""
	return "%s: the converted body is drawn with %.1f %% of its area (worst face %.1f %%), %d open edges, %d warnings; the kernel's own body %.1f %%, %d open edges" % [
		what, 100.0 * float(a.cover), 100.0 * float(a.worst), int(a.open), (a.warnings as Array).size(), 100.0 * float(b.cover), int(b.open)]


## The later Solid tools of the sweep, by name.
const LATER_TOOLS := ["cut", "join", "intersect", "move", "move, cut", "scale", "scale, cut", "mirror", "mirror, cut"]


## One of LATER_TOOLS on a body just made (null when the tool gives nothing). `box` leaves part
## of the body alone (one end of a pin stays as it was): a Combine keeps the untouched faces as
## they are, which is where carried triangles went wrong.
func _later_tool(tool: String, shape: RefCounted, box: RefCounted, size: float) -> RefCounted:
	if shape == null:
		return null
	var shift := Transform3D(Basis(Vector3(0, 0, 1), 0.3), Vector3(0.37, -0.11, 0.05) * size)
	var grow := Transform3D(Basis.from_scale(Vector3.ONE * 1.7), Vector3.ZERO)
	match tool:
		"cut":
			return kernel.boolean(shape, box, 1)
		"join":
			return kernel.boolean(shape, box, 0)
		"intersect":
			return kernel.boolean(shape, box, 2)
		"move":
			return kernel.transform_shape(shape, shift, "moved")
		"move, cut":
			var there: RefCounted = kernel.transform_shape(shape, shift, "moved")
			return kernel.boolean(there, kernel.transform_shape(box, shift, "movedbox"), 1) if there != null else null
		"scale":
			return kernel.transform_shape(shape, grow, "scaled")
		"scale, cut":
			var larger: RefCounted = kernel.transform_shape(shape, grow, "scaled")
			return kernel.boolean(larger, kernel.transform_shape(box, grow, "scaledbox"), 1) if larger != null else null
		"mirror":
			return kernel.mirror_shape(shape, Vector3.ZERO, Vector3(1, 0, 0), "mirrored")
		"mirror, cut":
			var other: RefCounted = kernel.mirror_shape(shape, Vector3.ZERO, Vector3(1, 0, 0), "mirrored")
			return kernel.boolean(other, kernel.mirror_shape(box, Vector3.ZERO, Vector3(1, 0, 0), "mirroredbox"), 1) if other != null else null
	return null


func _check_later_tools() -> void:
	var count := 0
	var both := PackedStringArray()
	for size: float in [0.008, 0.2, 5.0]:
		# A pin (one cylinder, two flat ends) turned 0.2 rad, as the re-verifier's smallest input.
		var k := size / 0.0067
		var pin: RefCounted = kernel.make_cylinder(0.0015 * k, 0.006 * k, Vector3(0, 0, -0.003 * k), Z)
		var turn := Transform3D(Basis(Y, 0.2), Vector3.ZERO)
		var fine := _moved(_tessellated(pin), turn)
		var coarse := _moved(_tessellated(pin, 300.0, 20.0), turn)
		var bb: AABB = fine.bbox()
		var lo := bb.position - bb.size * 0.1
		var hi := bb.end + bb.size * 0.1
		hi.x = bb.position.x + bb.size.x * 0.437
		hi.z = bb.position.z + bb.size.z * 0.55
		var box: RefCounted = kernel.make_box(hi - lo, lo)
		var prismatic: RefCounted = fine.to_prismatic({})
		_expect(prismatic != null, "A %s m pin should convert (Prismatic: '%s')." % [str(size), fine.get_last_error()])
		var faceted: RefCounted = coarse.to_faceted({})
		_expect(faceted != null, "A %s m pin should convert (Faceted: '%s')." % [str(size), coarse.get_last_error()])
		# (Every tool gets a body made anew, converted or the kernel's own, as a rebuild from
		# scratch does: nothing an earlier drawing left on a body reaches the next tool.)
		for kind: String in ["Prismatic", "Faceted"]:
			if (prismatic if kind == "Prismatic" else faceted) == null:
				continue
			var as_made := _as_the_kernels("%s pin of %s m as made" % [kind, str(size)], prismatic if kind == "Prismatic" else faceted, kernel.transform_shape(pin, turn, "own"), both)
			_expect(as_made == "", as_made)
			for tool: String in LATER_TOOLS:
				var body: RefCounted = fine.to_prismatic({}) if kind == "Prismatic" else coarse.to_faceted({})
				var wrong := _as_the_kernels("%s pin of %s m, then %s" % [kind, str(size), tool], _later_tool(tool, body, box, size), _later_tool(tool, kernel.transform_shape(pin, turn, "own"), box, size), both)
				_expect(wrong == "", wrong)
				count += 1
		# No triangles leave Prismatic: a body it made holds none before it is first drawn, as a
		# kernel body. (BRep bytes are written without triangles, so the two must be the same.)
		if prismatic != null:
			var again: RefCounted = fine.to_prismatic({})
			var bare: RefCounted = ClassDB.instantiate("CadShape")
			_expect(bare.load_brep_bytes(again.to_brep_bytes()) and _drawn(bare).open == 0, "A %s m Prismatic pin read back from its BRep bytes should draw closed." % str(size))
	# Through the features, as a design does it (the re-verifier's r24): Convert, a Box, Combine.
	for length: float in [0.006, 3.0]:
		var k := length / 0.006
		var pin: RefCounted = kernel.make_cylinder(0.0015 * k, 0.006 * k, Vector3(0, 0, -0.003 * k), Z)
		var mesh := _moved(_tessellated(pin), Transform3D(Basis(Y, 0.2), Vector3.ZERO))
		var doc: Resource = DOCUMENT.new()
		var body := _add_mesh(doc, mesh, "Pin")
		var convert: Resource = MESH_CONVERT.add_convert(doc, "convert_prismatic", [body]).feature
		var bb: AABB = mesh.bbox()
		var lo := bb.position - bb.size * 0.1
		var hi := bb.end + bb.size * 0.1
		hi.x = bb.position.x + bb.size.x * 0.437
		var box: Resource = doc.add_feature("box", "Box", {"length": doc.make_input("%s m" % String.num(hi.x - lo.x, 12), "length"), "height": doc.make_input("%s m" % String.num(hi.y - lo.y, 12), "length"),
			"width": doc.make_input("%s m" % String.num(hi.z - lo.z, 12), "length")}, {"operation": OPERATIONS.NEW_BODY, "position": lo})
		box.options.body_id = doc.new_body(box.id)
		var first := _rebuild(doc)
		_expect(first.errors.is_empty(), "The pin and the box should build (%s)." % [first.errors])
		if not first.errors.is_empty():
			continue
		var out_id := str(convert.options.outputs[0])
		doc.add_feature("combine", "Combine", {}, {"target": [{"kind": "body", "body": out_id}], "tools": [{"kind": "body", "body": str(box.options.body_id)}], "operation": "cut"})
		var result := _rebuild(doc)
		_expect(result.errors.is_empty() and result.bodies.has(out_id), "The Combine should build (%s)." % [result.errors])
		if result.bodies.has(out_id):
			var drawn := _drawn(result.bodies[out_id].shape)
			_expect(int(drawn.open) == 0 and float(drawn.worst) >= 0.97, "A %s m Prismatic pin after a Combine (cut) feature should draw whole (%.1f %% of its area, worst face %.1f %%, %d open edges)." % [
				str(length), 100.0 * float(drawn.cover), 100.0 * float(drawn.worst), int(drawn.open)])
			count += 1
	checked.append("R1 a converted body in the Solid tools (Prismatic and Faceted pins of 8 mm, 0.2 m and 5 m; cut, join, intersect, move, scale and mirror, each then cut; the Combine feature at 6 mm and 3 m): %d results drawn as the kernel's own%s" % [
		count, "" if both.is_empty() else "; drawn wrong for the kernel's own body too: %s" % ", ".join(both)])


# --- C1 and C2: a feature's time over its bodies ----------------------------------------------------

func _check_feature_time() -> void:
	# A feature's bodies share its time (the panel promises the feature takes no longer than its
	# limit): each body gets what the bodies before it left.
	var doc: Resource = DOCUMENT.new()
	var ids := []
	for k in 3:
		ids.append(_add_mesh(doc, FIXTURES.to_mesh(FIXTURES.icosphere(0.01 + 0.002 * k, 2)), "Ball%d" % k))
	var feature: Resource = MESH_CONVERT.add_convert(doc, "convert_faceted", ids).feature
	var built := _rebuild(doc)
	_expect(built.errors.is_empty(), "Three balls in one feature should convert (%s)." % [built.errors])
	var entries: Array = MESH_CONVERT._kept.values()
	var shared := entries.size() == 3
	var charged := 0.0
	for entry in entries:
		shared = shared and absf(float(entry.limit) - (20.0 - charged)) < 0.05
		charged += float(entry.took)
	_expect(shared, "Each body should get the 20 s less what the bodies before it took (%s)." % [entries.map(func(e: Dictionary) -> String: return "limit %s took %s" % [str(e.limit), str(e.took)])])
	# On a full-time build a kept body is charged what it took when it was converted, so the
	# feature fails or passes as it would from scratch. (The times are set here to stand for slow
	# bodies: 15 s and 10 s.)
	var keys: Array = MESH_CONVERT._kept.keys()
	MESH_CONVERT._kept[keys[0]].took = 15.0
	MESH_CONVERT._kept[keys[1]].took = 10.0
	var charged_build := _rebuild(doc)
	var late := str(charged_build.errors.get(feature.id, ""))
	_expect(MESH_FEATURE.is_time_refusal(late) and late.contains("would take about 10 s on Ball1 (limit") and late.contains("The bodies before it used the rest of the feature's 20 s"),
		"A kept body that took longer than what the bodies before it leave should be refused as from scratch ('%s')." % late)
	MESH_CONVERT._kept[keys[0]].took = 19.99
	var none_left := str(_rebuild(doc).errors.get(feature.id, ""))
	_expect(none_left.contains("took longer than 20 s on its bodies and was stopped before Ball1"), "With the time charged to the first body, the second should be stopped before it starts ('%s')." % none_left)
	# A preview charges a kept body nothing: it answers at once.
	var preview := _rebuild(doc, 0.5)
	_expect(not preview.errors.has(feature.id), "A preview should answer kept bodies at once whatever they took (%s)." % [preview.errors])
	# A body converted now gets what the bodies before it left, and when refused for time is told
	# so. (GridA's kept time is set to leave GridB half of what its estimate says it needs.)
	MESH_CONVERT.clear_cache()
	var grid_b := FIXTURES.to_mesh(FIXTURES.large_grid(30))
	grid_b.to_faceted({"time_limit": 0.001, "merge_flat": false})
	var needs := str(grid_b.get_last_error()).get_slice("would take about ", 1).get_slice(" s", 0)
	_expect(needs.is_valid_float(), "GridB at a 1 ms limit should be refused by its estimate ('%s')." % grid_b.get_last_error())
	var two: Resource = DOCUMENT.new()
	var first_id := _add_mesh(two, FIXTURES.to_mesh(FIXTURES.large_grid(4)), "GridA")
	var second_id := _add_mesh(two, grid_b, "GridB")
	var both: Resource = MESH_CONVERT.add_convert(two, "convert_faceted", [first_id], {"merge_flat": false}).feature
	_rebuild(two)
	MESH_CONVERT._kept.values()[0].took = 20.0 - float(needs) * 0.5
	both.options.bodies = [{"kind": "body", "body": first_id}, {"kind": "body", "body": second_id}]
	var short := _rebuild(two)
	var error := str(short.errors.get(both.id, ""))
	_expect(MESH_FEATURE.is_time_refusal(error) and error.contains("on GridB (limit") and error.contains("The bodies before it used the rest of the feature's 20 s: pick fewer bodies at once."),
		"The second grid should be refused for time, and told the first used it ('%s')." % error)
	# The first body is not told that.
	MESH_CONVERT.clear_cache()
	var one: Resource = DOCUMENT.new()
	var lone := _add_mesh(one, FIXTURES.to_mesh(FIXTURES.large_grid(20)), "GridA")
	var alone: Resource = MESH_CONVERT.add_convert(one, "convert_faceted", [lone], {"merge_flat": false}).feature
	var refused := str(_rebuild(one, 0.3).errors.get(alone.id, ""))
	_expect(MESH_FEATURE.is_time_refusal(refused) and not refused.contains("bodies before it"), "A lone body refused for time should not be told of bodies before it ('%s')." % refused)
	# The estimate counts the faces the result will have: a 39,762-triangle plate that merges into
	# one face is not refused at a 1 s limit (it was, at about 12 s by its triangles).
	var flat_plate := _plate(141, 0.1, func(_i: int, _j: int) -> int: return 0)
	var started := _now()
	var merged: RefCounted = flat_plate.to_faceted({"time_limit": 1.0})
	_expect(merged != null and int(merged.face_count()) == 1, "A flat plate of 39,762 triangles should merge into one face within 1 s ('%s', %.2f s)." % [flat_plate.get_last_error(), _now() - started])
	checked.append("C1 and C2 a feature's time (its bodies share the limit; a kept body is charged what it took on a full-time build, so from scratch and in the session agree; a preview answers kept bodies at once and tells a body refused after others; the Faceted estimate counts the result's faces)")


# --- Notes of the second round -----------------------------------------------------------------------

func _check_second_round_notes() -> void:
	# A one-group ball a hair too coarse for the Fit Tolerance: raising it is the fix, and is said.
	var ball := FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 5))
	var tight: float = (ball.bbox() as AABB).size.length() * 1e-5
	_expect(ball.to_prismatic({"tolerance": tight}) == null, "A ball should not fit a sphere within a hundred-thousandth of its size.")
	var said := str(ball.get_last_error())
	_expect(said.contains("(best: sphere, off by ") and said.contains("Raise the Fit Tolerance to "), "A one-group ball all but round should be told to raise the Fit Tolerance ('%s')." % said)
	var named := said.get_slice("Raise the Fit Tolerance to ", 1).get_slice(" mm", 0)
	_expect(named.is_valid_float() and ball.to_prismatic({"tolerance": float(named) * MM}) != null, "At the Fit Tolerance the refusal names (%s mm) the ball should convert ('%s')." % [named, ball.get_last_error()])
	# A one-group cube is still sent to Generate Face Groups (Accurate splits it); a coarse ball,
	# whose sphere would be far off its volume, is not told to raise the tolerance.
	var cube := FIXTURES.to_mesh(FIXTURES.large_grid(4))
	_expect(cube.to_prismatic({}) == null and str(cube.get_last_error()).begins_with("Generate Face Groups (Accurate) first"), "A one-group cube should still be sent to Generate Face Groups ('%s')." % cube.get_last_error())
	var rough := FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 1))
	_expect(rough.to_prismatic({}) == null and not str(rough.get_last_error()).contains("Raise the Fit Tolerance"), "A ball of 80 triangles should not be told to raise the Fit Tolerance ('%s')." % rough.get_last_error())
	# Two holes of 5.0 and 5.05 mm far from the origin are given one radius: the body is told.
	var block: RefCounted = kernel.boolean(kernel.boolean(_box(Vector3(60, 30, 20)), _cyl(5.0, 40, Vector3(15, 15, -10), Z), 1), _cyl(5.05, 40, Vector3(42, 15, -10), Z), 1)
	var far := _moved(_tessellated(block), Transform3D(Basis.IDENTITY, Vector3(100, 50, -80)))
	var size: float = (far.bbox() as AABB).size.length()
	var solid: RefCounted = far.to_prismatic({"tolerance": size / 250.0})
	_expect(solid != null, "The block with two holes 138 m away should convert ('%s')." % far.get_last_error())
	if solid != null:
		var report: Dictionary = far.get_last_report()
		var warning := str(far.get_last_warning())
		_expect(int(report.get("equal_radii", 0)) == 0 or (warning.contains("was given the radius of") and warning.contains("Lower the Fit Tolerance below")), "Radii made equal should be told (%d made equal; '%s')." % [int(report.get("equal_radii", 0)), warning])
		notes.append("the block with 5.0 and 5.05 mm holes 138 m away at a Fit Tolerance of %s mm: %d radii made equal; '%s'" % [String.num(size / 250.0 * 1000.0, 3), int(report.get("equal_radii", 0)), warning])
		# The Fit Tolerance the warning names keeps them apart.
		var below := warning.get_slice("Lower the Fit Tolerance below ", 1).get_slice(" mm", 0)
		if below.is_valid_float():
			var apart: RefCounted = far.to_prismatic({"tolerance": float(below) * 0.9 * MM})
			_expect(apart == null or (int(far.get_last_report().get("equal_radii", 0)) == 0 and not str(far.get_last_warning()).contains("was given the radius of")),
				"Under the Fit Tolerance the warning names (%s mm) the two radii should stay apart ('%s')." % [below, far.get_last_warning()])
			notes.append("the same block at %s mm: %s" % [String.num(float(below) * 0.9, 4), "converted, the radii kept apart" if apart != null else str(far.get_last_error())])
	var near: RefCounted = _tessellated(block).to_prismatic({})
	_expect(near != null and str(_tessellated(block).get_last_warning()) == "", "Near the origin the two holes keep their radii, with nothing said.")
	# A triangle without area, by the one rule the mesh's own check goes by (its height over its
	# longest edge is under what a float holds at its place): a 1 m cube with a sliver 30 nm high
	# along one edge, in a face group of its own. The check counts it, Faceted refuses it by that
	# count, and Prismatic leaves its group out instead of fitting a plane of its own to it.
	var cube_mesh := _tessellated(_box(Vector3(1000, 1000, 1000)))
	var arrays: Dictionary = cube_mesh.get_arrays()
	var positions: PackedVector3Array = (arrays.positions as PackedVector3Array).duplicate()
	var indices: PackedInt32Array = (arrays.indices as PackedInt32Array).duplicate()
	var groups: PackedInt32Array = (arrays.groups as PackedInt32Array).duplicate()
	var names: PackedStringArray = (arrays.group_names as PackedStringArray).duplicate()
	var a := indices[0]
	var b := indices[1]
	var c := indices[2]
	var normal := (positions[b] - positions[a]).cross(positions[c] - positions[a]).normalized()
	positions.append(0.5 * (positions[a] + positions[b]) + normal * 3e-8)
	var m := positions.size() - 1
	indices[1] = m  # (a, m, c)
	indices.append_array([m, b, c, a, b, m])
	groups.append_array([groups[0], names.size()])
	names.append("sliver")
	var slivered := _mesh_of(positions, indices, groups, names)
	_expect(int((slivered.check(2.0) as Dictionary).get("degenerate_triangles", -1)) == 1 and not bool(slivered.is_surface()), "The cube with a sliver should be closed, with 1 triangle without area (%s)." % [slivered.check(2.0)])
	_expect(slivered.to_faceted({}) == null and str(slivered.get_last_error()).contains("1 triangle without area"), "Faceted should refuse the sliver as the check counts it ('%s')." % slivered.get_last_error())
	var boxed: RefCounted = slivered.to_prismatic({})
	_expect(boxed != null and int(boxed.face_count()) == 6 and int(slivered.get_last_report().get("skipped_groups", 0)) == 1,
		"Prismatic should leave the sliver's group out and give the cube's 6 faces ('%s', %s faces, %s groups left out)." % [slivered.get_last_error(), str(boxed.face_count()) if boxed != null else "no", str(slivered.get_last_report().get("skipped_groups"))])
	# More converted bodies than are kept: nothing a rebuild's bodies hold is let go (the second
	# rebuild converts nothing); a design built after the first is dropped pushes the first's out,
	# and building the first again says why each body was converted again.
	MESH_CONVERT.clear_cache()
	var designs := []
	for d in 2:
		var many: Resource = DOCUMENT.new()
		var ids := []
		for k in MESH_CONVERT.KEPT + 3:
			ids.append(_add_mesh(many, FIXTURES.to_mesh(FIXTURES.icosphere(0.01 + 0.0001 * k + 0.05 * d, 0)), "Bead%d" % k))
		designs.append([many, MESH_CONVERT.add_convert(many, "convert_faceted", ids).feature])
	var first := _rebuild(designs[0][0])
	var feature: Resource = designs[0][1]
	_expect(first.errors.is_empty() and not str(first.warnings.get(feature.id, "")).contains("converted again"), "%d small bodies should convert, with nothing said the first time (%s; '%s')." % [MESH_CONVERT.KEPT + 3, first.errors, str(first.warnings.get(feature.id, "")).left(200)])
	var hits: int = MESH_CONVERT.cache_hits
	var again := _rebuild(designs[0][0])
	_expect(MESH_CONVERT.cache_hits - hits == MESH_CONVERT.KEPT + 3 and not str(again.warnings.get(feature.id, "")).contains("converted again"),
		"A rebuild of a design over the kept count should convert nothing again (%d answered; '%s')." % [MESH_CONVERT.cache_hits - hits, str(again.warnings.get(feature.id, "")).left(300)])
	first = {}
	again = {}
	_rebuild(designs[1][0])
	var back := _rebuild(designs[0][0])
	_expect(str(back.warnings.get(feature.id, "")).contains("was converted again: its kept result had been let go to stay within 256 kept results."),
		"Bodies converted again after their kept results were let go should say why ('%s')." % str(back.warnings.get(feature.id, "")).left(300))
	MESH_CONVERT.clear_cache()
	checked.append("notes (a one-group ball all but round is told the Fit Tolerance that converts it; radii made equal are named; a triangle without area is one by the shared rule in the check, Faceted and Prismatic; nothing a rebuild holds is let go, and a body converted again after its kept result was let go says why)")


# --- Third round: sentences that name the cause and a step that helps ------------------------------

func _check_third_round() -> void:
	# C3: Organic called on its own names "the mesh", never the placeholder, and a refusal by its
	# estimate says "would take about", never that it ran over a limit it did not reach.
	var plate: RefCounted = FIXTURES.to_mesh(FIXTURES.open_plate())
	var open_error := str(ORGANIC.convert(plate, {}).error)
	_expect(open_error.begins_with("The mesh is not closed") and not open_error.contains("{body}"), "Organic on its own should name the mesh ('%s')." % open_error)
	var named := str(ORGANIC.convert(plate, {"name": "Plate"}).error)
	_expect(named.begins_with("Plate is not closed"), "Organic should use the name it is given ('%s')." % named)
	var ball := FIXTURES.to_mesh(FIXTURES.icosphere(0.0001, 3))
	var estimate := ORGANIC.seconds_after_remesh(500)
	var false_stops := PackedStringArray()
	for extra: float in [0.0, 0.05, 0.1, 0.2, 0.3]:
		var limit := estimate + extra
		var started := _now()
		var made := ORGANIC.convert(ball, {"faces": 500, "time_limit": limit})
		var took := _now() - started
		var error := str(made.error)
		if error.contains("took longer than") and took < limit:
			false_stops.append("%s after %.2f s at a limit of %.2f s" % [error, took, limit])
		_expect(error == "" or MESH_FEATURE.is_time_refusal(error) or not error.contains("{body}"), "Organic at %.2f s: '%s'." % [limit, error])
	_expect(false_stops.is_empty(), "Organic should not say it took longer than a limit it did not reach: %s" % "; ".join(false_stops))
	# C4: far from the origin the sentences name the distance and a step that helps.
	var holed: RefCounted = kernel.boolean(_box(Vector3(20, 20, 4)), _cyl(4.0, 10, Vector3(10, 10, -3), Z), 1)
	var flat_far := _moved(_tessellated(holed), Transform3D(Basis.IDENTITY, Vector3(11547, 11547, 11547)))
	_expect(flat_far.to_faceted({}) == null, "The holed plate 20 km from the origin should be refused by Faceted.")
	var faceted_far := str(flat_far.get_last_error())
	_expect(faceted_far.contains("km from the origin, where positions are stored only to about") and faceted_far.contains("Convert the mesh before it is placed this far from the origin") and not faceted_far.contains("Stitch"),
		"Faceted far away should name the distance and not send the user to Stitch and Remove ('%s')." % faceted_far)
	var round_far := _moved(_tessellated(holed), Transform3D(Basis.IDENTITY, Vector3(577, 577, 577)))
	var prismatic_far: RefCounted = round_far.to_prismatic({})
	var said := str(round_far.get_last_error())
	_expect(prismatic_far != null or (said.contains("from the origin, where positions are stored only to about") and not said.contains("Generate Face Groups")),
		"Prismatic far away should name the distance, not Generate Face Groups ('%s')." % said)
	notes.append("C4 the holed plate 20 km out, Faceted: '%s'; 1 km out, Prismatic: '%s'" % [faceted_far, "converted" if prismatic_far != null else said])
	# ... and the step it names works: the same plate converted near the origin, then moved out.
	var near: RefCounted = _tessellated(holed).to_faceted({})
	var moved_out: RefCounted = kernel.transform_shape(near, Transform3D(Basis.IDENTITY, Vector3(11547, 11547, 11547)), "far") if near != null else null
	_expect(moved_out != null and not moved_out.is_null() and absf(float(moved_out.volume()) - float(near.volume())) <= 1e-9 * absf(float(near.volume())) + 1e-15,
		"The plate converted near the origin should keep its volume when moved 20 km out.")
	# C5: a coarse one-group ball is not sent between Generate Face Groups and Accurate: Accurate
	# leaves it one group, so neither is named, and the steps it names work.
	var coarse := FIXTURES.to_mesh(FIXTURES.icosphere(0.02, 1))
	_expect(coarse.to_prismatic({}) == null, "A ball of 80 triangles should not convert to a sphere within the default Fit Tolerance.")
	var coarse_said := str(coarse.get_last_error())
	_expect(coarse_said.contains("one smooth area") and not coarse_said.contains("Generate Face Groups") and coarse_said.contains("Faceted"), "The coarse ball should be told it is one smooth area, without Generate Face Groups ('%s')." % coarse_said)
	var accurate: RefCounted = coarse.generate_groups({"method": "accurate"})
	_expect(accurate != null and int(accurate.group_count()) == 1, "Generate Face Groups (Accurate) leaves the coarse ball one group (%s)." % [accurate.group_count() if accurate != null else coarse.get_last_error()])
	_expect(coarse.to_faceted({}) != null, "Faceted, which the sentence names, should convert the coarse ball ('%s')." % coarse.get_last_error())
	var wide: RefCounted = coarse.to_prismatic({"tolerance": (coarse.bbox() as AABB).size.length() / 20.0})
	var wide_said := str(coarse.get_last_error())
	_expect(wide == null and wide_said.contains("volume is off") and not wide_said.contains("Generate Face Groups") and not wide_said.contains("Lower the Fit Tolerance"),
		"At the widest Fit Tolerance the coarse ball's volume refusal should not send the user back ('%s')." % wide_said)
	var fast: RefCounted = coarse.generate_groups({"method": "fast"})
	if fast != null:
		var fast_shape: RefCounted = fast.to_prismatic({})
		notes.append("C5 the coarse ball grouped Fast (%d groups): %s" % [int(fast.group_count()), "converted" if fast_shape != null else str(fast.get_last_error())])
	notes.append("C5 the coarse ball: '%s'" % coarse_said)
	checked.append("third round (Organic names the mesh and says 'would take about' when its estimate refuses; far from the origin Faceted and Prismatic name the distance and the step that helps; a coarse one-group ball is not sent between Generate Face Groups and Accurate)")
