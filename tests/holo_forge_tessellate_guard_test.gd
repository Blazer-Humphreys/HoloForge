extends SceneTree
## Regression checks for CadShape.tessellate's guard, the last line of defence for every body that
## is drawn, baked or exported, headless:
## - A face with real area and no triangles at all was skipped without a word (the guard took "no
##   mesh" for "nothing to check"): a converted body was drawn and baked with whole faces missing
##   and no warning. Such a face is meshed again on its own, and warned of by name with its area
##   when that gives nothing either.
## - A badly wrong mesh bought its own allowance: the area a mesh may miss along a curved edge was
##   measured on the mesh under test (how far its own chords of the edge lie off it), so a
##   cylinder wider than tall (20 mm radius, 5 mm tall) meshed coarsely, its rims in a few chords,
##   passed drawn at 55 % of its area, and at 27 %. The allowance comes from the edge and the
##   deflection asked for.
## - A tool's result keeps the faces the tool left alone. Drawing the result finer (a smaller
##   body in the viewport, an export, a bake) meshed those faces again, and the tool's input,
##   drawn again, then came out with open edges all along them (168 on a plate with a hole after
##   a fillet was exported, 504 on a cross-drilled block), with no warning.
## - None of this may warn of sound bodies: boxes, rounds, fillets, shells, spline bodies from
##   Form, sub-millimetre and 5 m bodies, at the viewport's deflection and a fine one.
## The damaged meshes are planted with CadShape.test_damage_mesh (a hook for this test only).

const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const PRIMITIVES := preload("res://addons/holo_forge/core/form/primitives.gd")
const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const INSERT := preload("res://addons/holo_forge/core/features/insert.gd")
const MESH_FEATURE := preload("res://addons/holo_forge/core/features/mesh.gd")
const MESH_CONVERT := preload("res://addons/holo_forge/core/features/mesh_convert.gd")
const MESH_BLOB := preload("res://addons/holo_forge/core/mesh/mesh_blob.gd")
const MM := 0.001

var failures: Array[String] = []
var checked: Array[String] = []
var kernel: RefCounted


func _init() -> void:
	call_deferred("run")


func check(ok: bool, detail: String) -> void:
	if not ok:
		failures.append(detail)
		print("  fail: ", detail)


func run() -> void:
	kernel = REGEN.make_kernel()
	if kernel != null and ClassDB.class_exists("CadShape") and ClassDB.class_has_method("CadShape", "test_damage_mesh"):
		_no_triangles()
		_half_drawn()
		_inputs_stay_right()
		_unmeshable_face()
		_drawing_told_on_feature()
		_no_false_warnings()
	else:
		print("note: CadKernel or CadShape.test_damage_mesh is not there; the native checks are skipped")
	if failures.is_empty():
		print("PASS holo_forge_tessellate_guard: ", ", ".join(checked))
		quit(0)
	else:
		print("FAIL holo_forge_tessellate_guard")
		for f in failures:
			print("  ", f)
		quit(1)


# --- Helpers -------------------------------------------------------------------------------------

func cyl(r: float, h: float, origin: Vector3, axis: Vector3) -> RefCounted:
	return kernel.make_cylinder(r * MM, h * MM, origin * MM, axis.normalized())


## The viewport's deflection for a body.
func viewport_deflection(shape: RefCounted) -> float:
	return clampf((shape.bbox() as AABB).size.length() * 0.0015, 0.00001, 0.01)


## What a tessellation of shape shows: {"open": edges an odd number of triangles use (corners
## matched exactly), "cover": each face's drawn area over its own, "worst": the least of those,
## "warnings": PackedStringArray}.
func drawn(shape: RefCounted, linear := -1.0) -> Dictionary:
	var tess: Dictionary = shape.tessellate(linear if linear > 0.0 else viewport_deflection(shape), 0.3)
	var pos: PackedVector3Array = tess.get("positions", PackedVector3Array())
	var idx: PackedInt32Array = tess.get("indices", PackedInt32Array())
	var fid: PackedInt32Array = tess.get("face_ids", PackedInt32Array())
	var ids := {}
	var corner := PackedInt32Array()
	corner.resize(pos.size())
	for i in pos.size():
		if not ids.has(pos[i]):
			ids[pos[i]] = ids.size()
		corner[i] = ids[pos[i]]
	var uses := {}
	var per := {}
	for t in range(0, idx.size(), 3):
		per[fid[t / 3]] = float(per.get(fid[t / 3], 0.0)) + 0.5 * (pos[idx[t + 1]] - pos[idx[t]]).cross(pos[idx[t + 2]] - pos[idx[t]]).length()
		for e in 3:
			var u := corner[idx[t + e]]
			var v := corner[idx[t + (e + 1) % 3]]
			if u == v:
				continue
			var key := (mini(u, v) << 32) | maxi(u, v)
			uses[key] = int(uses.get(key, 0)) + 1
	var open := 0
	for key in uses:
		if int(uses[key]) % 2 != 0:
			open += 1
	var cover := PackedFloat64Array()
	var worst := 1.0
	for f in shape.face_count():
		var own := float((shape.face_info(f) as Dictionary).get("area", 0.0))
		var c := float(per.get(f, 0.0)) / own if own > 0.0 else 1.0
		cover.append(c)
		worst = minf(worst, c)
	return {"open": open, "cover": cover, "worst": worst, "warnings": tess.get("warnings", PackedStringArray())}


## A face of shape of the given kind ("plane", "cylinder", ...) with the largest area, or -1.
func face_of(shape: RefCounted, kind: String) -> int:
	var best := -1
	var largest := 0.0
	for f in shape.face_count():
		var info: Dictionary = shape.face_info(f)
		if str(info.get("type", "")) == kind and float(info.get("area", 0.0)) > largest:
			largest = float(info.area)
			best = f
	return best


func longest_line(shape: RefCounted) -> int:
	var best := -1
	var longest := 0.0
	for e in shape.edge_count():
		var info: Dictionary = shape.edge_info(e)
		if str(info.get("type", "")) == "line" and float(info.get("length", 0.0)) > longest:
			longest = float(info.length)
			best = e
	return best


## Makers of the bodies whose meshes are damaged (a fresh body each call: a mesh stays with its
## shape).
func bodies() -> Dictionary:
	return {
		"box": func(): return kernel.make_box(Vector3(40, 30, 10) * MM),
		"cylinder": func(): return cyl(5, 20, Vector3.ZERO, Vector3(0, 0, 1)),
		# (Wider than tall: its rims' length against its area let a coarse mesh pass at 27 %.)
		"disc": func(): return cyl(20, 5, Vector3.ZERO, Vector3(0, 0, 1)),
		"plate with a hole": func(): return kernel.boolean(kernel.make_box(Vector3(40, 30, 10) * MM), cyl(4, 20, Vector3(20, 15, -5), Vector3(0, 0, 1)), 1),
		"box with a rounded edge": func():
			var b: RefCounted = kernel.make_box(Vector3(40, 30, 10) * MM)
			return kernel.fillet(b, PackedInt32Array([longest_line(b)]), {"radius": 3 * MM}),
	}


# --- A face with no triangles --------------------------------------------------------------------

func _no_triangles() -> void:
	var cases := 0
	for name: String in bodies():
		for kind: String in ["plane", "cylinder"]:
			var probe: RefCounted = (bodies()[name] as Callable).call()
			var f := face_of(probe, kind) if probe != null else -1
			if f < 0:
				continue
			var own := float((probe.face_info(f) as Dictionary).area)
			var label := "The %s with its largest %s face (face %d, %.1f mm2) left without a mesh" % [name, kind, f, own * 1e6]
			# Meshed again on its own: drawn whole, nothing to warn of.
			var a: RefCounted = (bodies()[name] as Callable).call()
			drawn(a)
			check(a.test_damage_mesh(f, -1.0, 0.0, false), "%s: the mesh should be taken away." % label)
			var d := drawn(a)
			check(float(d.cover[f]) > 0.97 and (d.warnings as PackedStringArray).is_empty(), "%s is drawn with %.1f %% of that face (warnings %s); it should be meshed again and drawn whole." % [label, float(d.cover[f]) * 100.0, str(d.warnings)])
			# When it can't be meshed again: a warning that names the face and its area.
			var b: RefCounted = (bodies()[name] as Callable).call()
			drawn(b)
			b.test_damage_mesh(f, -1.0, 0.0, true)
			var w: PackedStringArray = drawn(b).warnings
			var said := false
			for line in w:
				said = said or (line.contains("face %d " % f) and line.contains("no mesh") and line.contains("mm2"))
			check(said and w.size() == 1, "%s and not meshable again should be warned of by name with its area, once; the warnings are %s." % [label, str(w)])
			cases += 1
	checked.append("%d faces left without triangles are meshed again and drawn whole, or warned of by name with their area" % cases)


# --- A face drawn in part ------------------------------------------------------------------------

func _half_drawn() -> void:
	var cases := 0
	for name: String in bodies():
		for kind: String in ["plane", "cylinder"]:
			var probe: RefCounted = (bodies()[name] as Callable).call()
			var f := face_of(probe, kind) if probe != null else -1
			if f < 0:
				continue
			var size: float = (probe.bbox() as AABB).size.length()
			# (A mesh at the viewport's deflection, and one so coarse that a round's rim is three
			# or four chords: the allowance measured on the mesh itself let that one pass.)
			for coarse: float in [0.0, 0.3 * size]:
				var label := "The %s with its largest %s face (face %d) drawn to about 58 %% from a %s mesh" % [name, kind, f, "coarse" if coarse > 0.0 else "fine"]
				var a: RefCounted = (bodies()[name] as Callable).call()
				drawn(a)
				check(a.test_damage_mesh(f, 0.58, coarse, false), "%s: the mesh should be damaged." % label)
				var d := drawn(a)
				check(float(d.cover[f]) > 0.97 or not (d.warnings as PackedStringArray).is_empty(), "%s is drawn with %.1f %% of that face and no warning." % [label, float(d.cover[f]) * 100.0])
				var b: RefCounted = (bodies()[name] as Callable).call()
				drawn(b)
				b.test_damage_mesh(f, 0.58, coarse, true)
				var d2 := drawn(b)
				var said := false
				for line in (d2.warnings as PackedStringArray):
					said = said or line.contains("face %d'" % f) or line.contains("face %d " % f)
				check(float(d2.cover[f]) > 0.97 or said, "%s, not meshable again, is drawn with %.1f %% of that face and no warning of it (warnings %s)." % [label, float(d2.cover[f]) * 100.0, str(d2.warnings)])
				cases += 1
	checked.append("%d faces drawn to 58 %% (from fine and coarse meshes) are meshed again or warned of by name" % cases)


# --- A tool's input drawn again ------------------------------------------------------------------

func _inputs_stay_right() -> void:
	var makers := {
		"pipe cross": func(): return kernel.boolean(cyl(5, 40, Vector3(0, 0, -20), Vector3(0, 0, 1)), cyl(5, 40, Vector3(-20, 0, 0), Vector3(1, 0, 0)), 0),
		"plate with a hole": bodies()["plate with a hole"],
		"cross-drilled block": func(): return kernel.boolean(kernel.boolean(kernel.make_box(Vector3(30, 30, 30) * MM, Vector3(-15, -15, -15) * MM), cyl(5, 40, Vector3(0, 0, -20), Vector3(0, 0, 1)), 1), cyl(5, 40, Vector3(-20, 0, 0), Vector3(1, 0, 0)), 1),
	}
	var pairs := 0
	for name: String in makers:
		for tool: String in ["cut", "join", "fillet", "chamfer", "offset face"]:
			var body: RefCounted = (makers[name] as Callable).call()
			check(body != null, "The %s should be made." % name)
			if body == null:
				continue
			var d: float = (body.bbox() as AABB).size.length()
			var before := drawn(body)
			var bb: AABB = body.bbox()
			var lo := bb.position - bb.size * 0.1
			var hi := bb.end + bb.size * 0.1
			hi.x = bb.position.x + bb.size.x * 0.437
			var result: RefCounted = null
			match tool:
				"cut":
					result = kernel.boolean(body, kernel.make_box(hi - lo, lo), 1)
				"join":
					result = kernel.boolean(body, kernel.make_box(hi - lo, lo), 0)
				"fillet":
					var e := longest_line(body)
					result = kernel.fillet(body, PackedInt32Array([e]), {"radius": d * 0.02}) if e >= 0 else null
				"chamfer":
					var e := longest_line(body)
					result = kernel.chamfer(body, PackedInt32Array([e]), {"distance": d * 0.02}) if e >= 0 else null
				"offset face":
					var f := face_of(body, "plane")
					result = kernel.offset_faces(body, PackedInt32Array([f]), d * 0.02) if f >= 0 else null
			if result == null:
				continue
			# The result drawn as the viewport draws it, and as an export or a bake meshes it.
			var r1 := drawn(result)
			var r2 := drawn(result, 0.00001)
			var after := drawn(body)
			var label := "The %s drawn again after its %s was drawn and meshed finely" % [name, tool]
			check(int(before.open) == 0 and int(after.open) == 0, "%s has %d open edges (%d the first time)." % [label, after.open, before.open])
			check(float(after.worst) > 0.97 and (after.warnings as PackedStringArray).is_empty(), "%s is drawn with %.1f %% of its worst face, warnings %s." % [label, float(after.worst) * 100.0, str(after.warnings)])
			check(int(r1.open) == 0 and int(r2.open) == 0, "The %s of the %s is drawn with %d and %d open edges." % [tool, name, r1.open, r2.open])
			# And the result again after its input: the same holds the other way round.
			var again := drawn(result)
			check(int(again.open) == 0, "The %s of the %s, drawn again after its input, has %d open edges." % [tool, name, again.open])
			pairs += 1
	checked.append("%d tool inputs drawn again after their results (and the results after them) are closed" % pairs)


# --- A face the mesher can't mesh ----------------------------------------------------------------

## A pipe cross (r 5 and r 4) as a mesh body, turned 1.3 rad about y, converted Prismatic and cut
## by a box at 0.437 of its length: OCCT's cut kept the loop where the pipes meet whole, as a hole
## in the big pipe's face running out across the cut edge, which OCCT's mesher gives no triangles
## at any deflection (40 % of the body left out, 422 open edges at 8 mm), and the feature said
## nothing. A boolean whose new faces aren't sound is tried again with a small fuzzy value, and
## refused saying why when that doesn't mend it.
func _unmeshable_face() -> void:
	var n := 0
	var refused := 0
	for length_mm: float in [8.0, 19.0]:
		var base: RefCounted = kernel.boolean(kernel.make_cylinder(0.005, 0.04, Vector3(0, 0, -0.02), Vector3(0, 0, 1)), kernel.make_cylinder(0.004, 0.04, Vector3(-0.02, 0, 0), Vector3(1, 0, 0)), 0)
		var base_mesh: RefCounted = ClassDB.instantiate("CadMesh")
		var diagonal: float = (base.bbox() as AABB).size.length()
		check(base_mesh.from_shape(base, diagonal / 5000.0, deg_to_rad(8.0), false, 20.0), "The pipe cross should mesh (%s)." % base_mesh.get_last_error())
		var k: float = length_mm * 0.001 / (base_mesh.bbox() as AABB).size.length()
		var arrays: Dictionary = base_mesh.get_arrays()
		var p: PackedVector3Array = arrays.positions.duplicate()
		var turn := Transform3D(Basis(Vector3(0, 1, 0), 1.3), Vector3.ZERO)
		for i in p.size():
			p[i] = turn * (p[i] * k)
		var mesh: RefCounted = ClassDB.instantiate("CadMesh")
		mesh.set_arrays(p, arrays.indices, arrays.groups, arrays.group_names, "godot")
		MESH_CONVERT.clear_cache()
		MESH_FEATURE.clear_cache()
		var doc: Resource = DOCUMENT.new()
		var imported: Resource = doc.add_feature("mesh_import", "Mesh", {}, {
			"path": "", "kind": INSERT.KIND_MESH, "units": "mm", "mesh_units": "mm", "linked": false, "split": false,
			"transform": Transform3D.IDENTITY, "operation": OPERATIONS.NEW_BODY, "mesh": MESH_BLOB.from_mesh(mesh),
		})
		var body_id: String = doc.new_body(imported.id)
		imported.options["body_id"] = body_id
		var conv: Resource = MESH_CONVERT.add_convert(doc, "convert_prismatic", [body_id]).feature
		var bb: AABB = mesh.bbox()
		var lo := bb.position - bb.size * 0.1
		var hi := bb.end + bb.size * 0.1
		hi.x = bb.position.x + bb.size.x * 0.437
		var box: Resource = doc.add_feature("box", "Box", {"length": doc.make_input("%s m" % String.num(hi.x - lo.x, 12), "length"), "height": doc.make_input("%s m" % String.num(hi.y - lo.y, 12), "length"), "width": doc.make_input("%s m" % String.num(hi.z - lo.z, 12), "length")},
			{"operation": OPERATIONS.NEW_BODY, "position": Vector3((lo.x + hi.x) * 0.5, lo.y, (lo.z + hi.z) * 0.5)})
		box.options.body_id = doc.new_body(box.id)
		REGEN.rebuild(doc, kernel)
		var out_id := str(conv.options.outputs[0])
		var comb: Resource = doc.add_feature("combine", "Combine", {}, {"target": [{"kind": "body", "body": out_id}], "tools": [{"kind": "body", "body": str(box.options.body_id)}], "operation": "cut"})
		var result: Dictionary = REGEN.rebuild(doc, kernel)
		var label := "The converted %s mm pipe cross, cut" % length_mm
		# (Built and drawn whole, or refused saying why: never kept with a face it can't draw.)
		if result.errors.has(comb.id):
			var said := str(result.errors[comb.id])
			check(said.contains("unsound") or said.contains("came out wrong"), "%s is refused for another reason: %s" % [label, said])
			refused += 1
			continue
		var shape: RefCounted = result.bodies.get(out_id, {}).get("shape")
		check(shape != null, "%s should be there." % label)
		if shape == null:
			continue
		var d := drawn(shape)
		var area := 0.0
		for f in shape.face_count():
			area += float(d.cover[f]) * float((shape.face_info(f) as Dictionary).area)
		check(int(d.open) == 0 and area > 0.97 * float(shape.area()) and (d.warnings as PackedStringArray).is_empty(), "%s is drawn with %.1f %% of its area, %d open edges, warnings %s." % [label, area / float(shape.area()) * 100.0, d.open, str(d.warnings)])
		check(str(result.get("made_by", {}).get(out_id, "")) == str(comb.id), "%s should be told as made by the Combine (made_by %s)." % [label, str(result.get("made_by", {}))])
		n += 1
	checked.append("of 2 converted pipe crosses cut where OCCT left the big pipe's face unsound, %d are drawn whole and closed and %d refused saying why" % [n, refused])


## What a body's drawing is found wrong with goes on the feature that last made or changed it.
func _drawing_told_on_feature() -> void:
	var result := {"bodies": {}, "errors": {}, "warnings": {"f2": "kept"}, "made_by": {"b1": "f2", "b2": "f3"}}
	REGEN.note_drawing(result, "b1", {"warnings": PackedStringArray(["face 0 has no mesh"])}, "Cross")
	REGEN.note_drawing(result, "b1", {"warnings": PackedStringArray(["face 0 has no mesh"])}, "Cross")
	REGEN.note_drawing(result, "b2", {}, "Box")
	check(str(result.warnings.get("f2", "")) == "kept; Cross is drawn wrong: face 0 has no mesh" and not result.warnings.has("f3"), "A drawing's warnings should go once on the feature that made the body: %s." % str(result.warnings))
	checked.append("a body's drawing warnings are told on the feature that last changed it")


# --- Sound bodies --------------------------------------------------------------------------------

func form_body(cage: Dictionary) -> RefCounted:
	if not ClassDB.class_exists("CadSubD"):
		return null
	var s: RefCounted = ClassDB.instantiate("CadSubD")
	if not s.set_cage(cage):
		return null
	var shapes: Array = s.to_shapes({"isolation": 4, "name_prefix": "t/b"})
	return shapes[0] if not shapes.is_empty() else null


func _no_false_warnings() -> void:
	var list := []
	for s: float in [0.0003, 0.02, 5.0]:
		var box: RefCounted = kernel.make_box(Vector3(1.0, 0.7, 0.5) * s)
		list.append(["box %s m" % s, box])
		list.append(["cylinder %s m" % s, kernel.make_cylinder(0.3 * s, s, Vector3.ZERO, Vector3(0, 0, 1))])
		list.append(["ball %s m" % s, kernel.make_sphere(0.5 * s, Vector3.ZERO)])
		var e := longest_line(box)
		list.append(["box %s m, an edge rounded" % s, kernel.fillet(box, PackedInt32Array([e]), {"radius": 0.05 * s})])
		list.append(["box %s m, an edge chamfered" % s, kernel.chamfer(box, PackedInt32Array([e]), {"distance": 0.05 * s})])
		list.append(["box %s m, hollow" % s, kernel.shell(box, PackedInt32Array(), {"thickness": 0.04 * s})])
		list.append(["box %s m, open at a face" % s, kernel.shell(box, PackedInt32Array([face_of(box, "plane")]), {"thickness": 0.04 * s})])
		var drilled: RefCounted = kernel.boolean(box, kernel.make_cylinder(0.1 * s, 2.0 * s, Vector3(0.5, 0.35, -0.5) * s, Vector3(0, 0, 1)), 1)
		list.append(["box %s m with a hole" % s, drilled])
		list.append(["cylinder %s m, hollow" % s, kernel.shell(kernel.make_cylinder(0.3 * s, s, Vector3.ZERO, Vector3(0, 0, 1)), PackedInt32Array(), {"thickness": 0.04 * s})])
	list.append(["torus", kernel.torus({"major_radius": 0.02, "minor_radius": 0.005})])
	list.append(["Form box 20 mm", form_body(PRIMITIVES.box(Vector3(0.02, 0.02, 0.02), Vector3i(2, 2, 2)))])
	list.append(["Form ball 20 mm", form_body(PRIMITIVES.sphere(0.02, 8, 4))])
	list.append(["Form ball 0.5 mm", form_body(PRIMITIVES.sphere(0.0005, 8, 4))])
	list.append(["Form torus 50 mm", form_body(PRIMITIVES.torus(0.05, 0.012, 8, 6))])
	var n := 0
	var tessellations := 0
	var slowest := 0.0
	var total := 0.0
	for item in list:
		var shape: RefCounted = item[1]
		if shape == null:
			continue
		n += 1
		for fine: bool in [false, true]:
			var linear := viewport_deflection(shape) * (0.1 if fine else 1.0)
			var t0 := Time.get_ticks_usec()
			var d := drawn(shape, linear)
			var ms := (Time.get_ticks_usec() - t0) / 1000.0
			tessellations += 1
			total += ms
			slowest = maxf(slowest, ms)
			var label := "The %s meshed at %.5f mm" % [item[0], linear * 1000.0]
			check((d.warnings as PackedStringArray).is_empty(), "%s is warned of: %s." % [label, str(d.warnings)])
			check(int(d.open) == 0 or shape.is_surface(), "%s has %d open edges." % [label, d.open])
			# (A round's facets at the viewport's angle cover a few percent less than the round.)
			check(float(d.worst) > 0.9, "%s is drawn with %.1f %% of its worst face." % [label, float(d.worst) * 100.0])
	checked.append("%d sound bodies (boxes, rounds, fillets, shells, Form bodies; 0.3 mm to 5 m) draw closed with no warning (%d tessellations, %.0f ms in all, slowest %.0f ms, each with this test's own census)" % [n, tessellations, total, slowest])
