extends SceneTree
## Holo Forge mesh bodies in the design: regressions found by the Phase 7 verifiers (verify2 B7 and
## P6; verify3 F3, F4, F5, F7 and its notes), and the fix round's own items.
##
##   interference  a mesh body that crosses itself is said so; an open mesh body that overlaps
##                 another is listed, not left out; an inside-out one is named; the whole call has
##                 one deadline and lists what it could not work out in time; the overlap with a
##                 round B-rep body says how approximate it is.
##   mass          flawed mesh bodies (inside-out, wrong-way, crossing, open) carry their flaws
##                 and a warning, never a negative mass; the readouts show them.
##   face groups   a face group pick is found again where it was picked when an earlier change
##                 renumbers the groups (with a warning), is refused when it is gone, and old
##                 picks without a point still go by name; the same for a group's appearance.
##   export        hidden bodies are left out unless picked, and named.
##   stored meshes a damaged file beside the scene is written again on the next save; a damaged
##                 or swapped stored mesh is an error also when its result is still kept.
##   patterns      a Mirror or Pattern of a Derive says which mesh bodies it leaves out; a Derive
##                 says which bodies its source stopped making.
##   previews      only the previewed feature gets the short time limit.
##   bake          a mesh body that did not change is not baked again.
##
## godot --headless --path . --script res://tests/holo_forge_mesh_regress_doc_test.gd

const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const INSERT := preload("res://addons/holo_forge/core/features/insert.gd")
const MESH_FEATURE := preload("res://addons/holo_forge/core/features/mesh.gd")
const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")
const MESH_BLOB := preload("res://addons/holo_forge/core/mesh/mesh_blob.gd")
const INSPECT := preload("res://addons/holo_forge/core/inspect.gd")
const ANALYSIS := preload("res://addons/holo_forge/core/analysis.gd")
const APPEARANCE := preload("res://addons/holo_forge/core/appearance.gd")
const TESSELLATE := preload("res://addons/holo_forge/core/tessellate.gd")
const EXPORT := preload("res://addons/holo_forge/core/export.gd")
const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const FIXTURES := preload("res://tests/holo_forge_mesh_fixtures.gd")

const TEMP := "user://holo_forge_mesh_fixtures/regress_doc"
const RED := "builtin:paint_red"

var failures: Array[String] = []
var checked: Array[String] = []
var notes: Array[String] = []


func _init() -> void:
	call_deferred("run")


func run() -> void:
	var kernel := REGEN.make_kernel()
	_expect(kernel != null, "The native kernel should load.")
	if kernel != null and not ClassDB.class_exists("CadMesh"):
		print("NOTE holo_forge_mesh_regress_doc: CadMesh is not in this build; nothing is checked.")
	elif kernel != null:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEMP))
		_clear()
		_check_interference(kernel)
		_check_mass(kernel)
		_check_group_picks(kernel)
		_check_export_hidden(kernel)
		_check_stored_meshes(kernel)
		_check_patterns_and_derive(kernel)
		_check_preview_limit(kernel)
		_check_second_round(kernel)
		_check_third_round(kernel)
		await _check_bake(kernel)
		_remove_folder(TEMP)
	for note in notes:
		print("NOTE holo_forge_mesh_regress_doc: " + note)
	if failures.is_empty():
		print("PASS holo_forge_mesh_regress_doc: " + "; ".join(checked) + ".")
	else:
		print("FAIL holo_forge_mesh_regress_doc")
		for failure in failures:
			print("  " + failure)
	quit(0 if failures.is_empty() else 1)


# --- Helpers ---------------------------------------------------------------------------------

func _clear() -> void:
	MESH_FEATURE.clear_cache()
	INSERT.clear_mesh_cache()
	INSERT.clear_derive_cache()


## True when a script has a method that takes at least argc arguments.
func _has(script: Script, method: String, argc := 0) -> bool:
	for found in script.get_script_method_list():
		if str(found.name) == method:
			return (found.args as Array).size() >= argc
	return false


## A call of a method this round added (or gave more arguments): null, and a failure, when the
## code under test does not have it yet.
func _call(script: Script, method: String, args: Array) -> Variant:
	if not _has(script, method, args.size()):
		failures.append("%s.%s with %d arguments is missing." % [script.resource_path.get_file(), method, args.size()])
		return null
	return script.callv(method, args)


func _entry(id: String, mesh: RefCounted) -> Dictionary:
	return MESH_BODY.entry(id, mesh, "f")


## A design that only names bodies (for sentences).
func _names(names: Dictionary) -> Resource:
	var doc: Resource = DOCUMENT.new()
	for id in names:
		doc.bodies[id] = {"name": names[id], "visible": true, "locked": false, "feature": "f", "component": ""}
	return doc


func _add_mesh(doc: Resource, mesh: RefCounted, name := "") -> String:
	var feature: Resource = doc.add_feature("mesh_import", "Mesh", {}, {
		"path": "", "kind": INSERT.KIND_MESH, "units": "m", "mesh_units": "m", "linked": false, "split": false,
		"transform": Transform3D.IDENTITY, "operation": OPERATIONS.NEW_BODY, "mesh": MESH_BLOB.from_mesh(mesh),
	})
	var body_id: String = doc.new_body(feature.id)
	feature.options["body_id"] = body_id
	if name != "":
		doc.bodies[body_id]["name"] = name
	return body_id


func _add_box(doc: Resource, size: Vector3, position: Vector3, name := "") -> String:
	var feature: Resource = doc.add_feature("box", "Box", {
		"length": doc.make_input("%f m" % size.x, "length"), "height": doc.make_input("%f m" % size.y, "length"),
		"width": doc.make_input("%f m" % size.z, "length"),
	}, {"operation": OPERATIONS.NEW_BODY, "position": position})
	feature.options.body_id = doc.new_body(feature.id)
	if name != "":
		doc.bodies[str(feature.options.body_id)]["name"] = name
	return str(feature.options.body_id)


## A Mesh tool feature; inputs are [expression, kind].
func _tool(doc: Resource, method: String, options: Dictionary, inputs := {}) -> Resource:
	var made := {}
	for key in inputs:
		made[key] = doc.make_input(str(inputs[key][0]), str(inputs[key][1]))
	var settings := {"method": method}
	settings.merge(options)
	return doc.add_feature("mesh", method.capitalize().replace(" ", ""), made, settings)


## A 20 mm cube with a face group per side: g0 -Z, g1 +Z, g2 -Y, g3 +Y, g4 -X, g5 +X.
func _grouped_cube() -> RefCounted:
	var cube: Dictionary = FIXTURES.two_cubes(Vector3.ZERO).first
	var mesh: RefCounted = MESH_BODY.new_mesh()
	mesh.set_arrays(cube.positions, cube.indices, PackedInt32Array([0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5]), PackedStringArray(["g0", "g1", "g2", "g3", "g4", "g5"]), "godot")
	return mesh


func _group_facing(mesh: RefCounted, direction: Vector3) -> String:
	for g in int(mesh.face_count()):
		var info: Dictionary = mesh.face_info(g)
		if bool(info.get("planar", false)) and (info.normal as Vector3).dot(direction) > 0.99:
			return str(mesh.get_face_names()[g])
	return ""


# --- Interference (verify2 B7) ---------------------------------------------------------------

func _check_interference(kernel: RefCounted) -> void:
	var cube := FIXTURES.to_mesh(FIXTURES.two_cubes(Vector3.ZERO).first)
	var shifted := FIXTURES.to_mesh(FIXTURES.two_cubes(Vector3(0.01, 0.0, 0.0)).second)
	var crossing: RefCounted = FIXTURES.to_mesh(FIXTURES.two_cubes(Vector3(0.01, 0.0, 0.0))).transformed(Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, 0.012)))
	var plate := FIXTURES.to_mesh(FIXTURES.open_plate())
	var inverted: RefCounted = cube.reverse({"mode": "whole"}).transformed(Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -0.012)))
	var doc := _names({"a": "Cube A", "b": "Cube B", "x": "Crossing pair", "p": "Plate", "far": "Far plate", "i": "Inverted", "box": "Box", "ball": "Ball", "deep": "Deep ball"})

	# A body that crosses itself: the overlap is told as it is worked out, with the warning.
	var hits: Array = INSPECT.interference(kernel, {"a": _entry("a", cube), "x": _entry("x", crossing)}, [], doc)
	_expect(hits.size() == 1 and str(hits[0].get("warning", "")).contains("Crossing pair crosses itself") and not hits[0].has("error"),
		"Interference with a mesh body that crosses itself should carry the kernel's warning, by the body's name (%s)." % _text(hits))
	# An open mesh body that reaches into another: listed with why, not left out.
	hits = INSPECT.interference(kernel, {"a": _entry("a", cube), "p": _entry("p", plate), "far": _entry("far", plate.transformed(Transform3D(Basis.IDENTITY, Vector3(0.0, 0.5, 0.0))))}, [], doc)
	_expect(hits.size() == 1 and str(hits[0].a) == "a" and str(hits[0].b) == "p" and str(hits[0].get("error", "")).contains("Plate is an open mesh body") and bool(hits[0].get("open", false))
		and float(hits[0].volume) == 0.0 and hits[0].shape == null, "An open mesh body whose bounds reach into a solid should be listed with why it is not checked; one apart is not (%s)." % _text(hits))
	# An inside-out body: the error names it.
	hits = INSPECT.interference(kernel, {"a": _entry("a", cube), "i": _entry("i", inverted)}, [], doc)
	_expect(hits.size() == 1 and str(hits[0].get("error", "")).begins_with("Inverted has 1 part") and not str(hits[0].get("error", "")).contains("Tool body"),
		"An inside-out mesh body should be named in the error (%s)." % _text(hits))
	hits = INSPECT.interference(kernel, {"i": _entry("i", inverted), "a": _entry("a", cube)}, [], doc)
	_expect(hits.size() == 1 and str(hits[0].get("error", "")).begins_with("Inverted has 1 part"), "The same with the inside-out body first (%s)." % _text(hits))

	# One deadline for the whole call: with no time, every mesh pair is listed as not checked.
	var box: RefCounted = kernel.make_box(Vector3(0.02, 0.02, 0.02), Vector3(0.0, -0.01, -0.01), "rbox")
	var box2: RefCounted = kernel.make_box(Vector3(0.02, 0.02, 0.02), Vector3(0.005, -0.005, -0.005), "rbox2")
	var mixed := {"a": _entry("a", cube), "b": _entry("b", shifted), "box": {"id": "box", "shape": box, "feature": "f"}, "box2": {"id": "box2", "shape": box2, "feature": "f"}}
	var none: Variant = _call(INSPECT, "interference", [kernel, mixed, [], doc, 0.0])
	if none is Array:
		var late := (none as Array).filter(func(hit: Dictionary) -> bool: return bool(hit.get("timed_out", false)))
		var solid_pairs := (none as Array).filter(func(hit: Dictionary) -> bool: return not hit.has("error"))
		_expect((none as Array).size() == 6 and late.size() == 5 and late.all(func(hit: Dictionary) -> bool: return str(hit.error).contains("not checked") and hit.shape == null)
			and solid_pairs.size() == 1 and str(solid_pairs[0].a) == "box" and str(solid_pairs[0].b) == "box2",
			"With no time left, every pair with a mesh body should be listed as not checked, and the B-rep pair still worked out (%s)." % _text(none))
	# A real run under a short limit: back in time, and every overlapping pair accounted for.
	var many := {}
	var base := FIXTURES.to_mesh(FIXTURES.large_grid(40, 0.1))
	for i in 6:
		many["m%d" % i] = _entry("m%d" % i, base.transformed(Transform3D(Basis.from_euler(Vector3(0.1 * i, 0.07 * i, 0.03 * i)), Vector3(0.012 * i, 0.004 * i, 0.002 * i))))
	var started := Time.get_ticks_msec()
	var bounded: Variant = _call(INSPECT, "interference", [kernel, many, [], null, 0.4])
	var took := (Time.get_ticks_msec() - started) / 1000.0
	if bounded is Array:
		_expect(took <= 0.4 + 1.5 and (bounded as Array).size() == 15 and (bounded as Array).all(func(hit: Dictionary) -> bool: return hit.has("error") or hit.shape != null),
			"Interference over 6 bodies (15 pairs) with 0.4 s should come back in time with every pair listed (%.2f s, %d entries)." % [took, (bounded as Array).size()])
		notes.append("interference over 6 mesh bodies of %d triangles with a 0.4 s limit: %.2f s, %d of 15 pairs worked out" % [int(base.triangle_count()), took, (bounded as Array).filter(func(hit: Dictionary) -> bool: return not hit.has("error")).size()])

	# A round B-rep body: the note says how approximate the overlap is; a thin overlap is refined.
	var ball: RefCounted = kernel.make_sphere(0.01, Vector3(0.0, 0.0, 0.0199), "rball")
	hits = INSPECT.interference(kernel, {"a": _entry("a", cube), "ball": {"id": "ball", "shape": ball, "feature": "f"}}, [], doc)
	var cap := PI * 1e-4 * 1e-4 * (3.0 * 0.01 - 1e-4) / 3.0
	_expect(hits.size() == 1 and not hits[0].has("error") and absf(float(hits[0].volume) - cap) < 0.1 * cap and str(hits[0].get("note", "")).contains("Ball was tessellated for Interference")
		and str(hits[0].get("note", "")).contains("approximate") and hits[0].get("approximate") is Dictionary,
		"A ball that overlaps by a thin cap should be within 10 %% of its true overlap (%s mm3), with a note that says how approximate it is (%s)." % [String.num(cap * 1e9, 4), _text(hits)])
	if hits.size() == 1:
		notes.append("B-rep ball overlapping a mesh cube by a 0.1 mm cap: %s mm3 for a true %s mm3; note: %s" % [String.num(float(hits[0].volume) * 1e9, 4), String.num(cap * 1e9, 4), str(hits[0].get("note", ""))])
	hits = INSPECT.interference(kernel, {"a": _entry("a", cube), "box": {"id": "box", "shape": box, "feature": "f"}}, [], doc)
	_expect(hits.size() == 1 and absf(float(hits[0].volume) - 4e-6) < 1e-9 and str(hits[0].get("note", "")) == "Box was tessellated for Interference." and not hits[0].has("approximate"),
		"A flat-sided B-rep body is exact: the note should not call it approximate (%s)." % _text(hits))
	checked.append("interference (a self-crossing body's warning, an open body listed, an inside-out body named, one deadline with unfinished pairs listed, a thin overlap with a round B-rep body refined and its error stated)")


func _text(hits: Variant) -> String:
	if not hits is Array:
		return str(hits)
	var parts := PackedStringArray()
	for hit in hits:
		parts.append("%s/%s %s mm3%s%s%s" % [hit.get("a", "?"), hit.get("b", "?"), String.num(float(hit.get("volume", 0.0)) * 1e9, 4),
			(" error '%s'" % hit.error) if hit.has("error") else "", (" warning '%s'" % hit.warning) if hit.has("warning") else "", (" note '%s'" % hit.note) if hit.has("note") else ""])
	return "; ".join(parts) if not parts.is_empty() else "nothing"


# --- Mass properties (verify2 P6) ------------------------------------------------------------

func _check_mass(kernel: RefCounted) -> void:
	var cube := FIXTURES.to_mesh(FIXTURES.two_cubes(Vector3.ZERO).first)
	var bodies := {
		"ok": _entry("ok", cube), "i": _entry("i", cube.reverse({"mode": "whole"})), "w": _entry("w", FIXTURES.to_mesh(FIXTURES.flipped_half())),
		"x": _entry("x", FIXTURES.to_mesh(FIXTURES.two_cubes(Vector3(0.01, 0.0, 0.0)))), "p": _entry("p", FIXTURES.to_mesh(FIXTURES.open_plate())),
	}
	var doc := _names({"ok": "Good cube", "i": "Inverted", "w": "Half flipped", "x": "Crossing pair", "p": "Plate"})
	var props: Dictionary = INSPECT.mass_properties(doc, {"bodies": bodies}, [])
	var per: Dictionary = props.bodies
	_expect(not per.ok.has("warning") and not per.ok.has("flaws") and absf(float(per.ok.mass) - float(per.ok.density) * 8e-6) < 1e-6 * float(per.ok.mass), "A sound cube has its mass and no flaws.")
	_expect(float(per.i.mass) > 0.0 and absf(float(per.i.volume) - 8e-6) < 1e-11 and Array(per.i.get("flaws", [])) == ["inside_out"] and int(per.i.get("inside_out_parts", 0)) == 1 and str(per.i.get("warning", "")).contains("inside-out")
		and absf(INSPECT.solid_volume(bodies.i.shape) - 8e-6) < 1e-11, "An inside-out cube: its true volume and mass, never negative, with the flaw and the warning (%s; solid_volume %s)." % [str(per.i.get("flaws")), INSPECT.solid_volume(bodies.i.shape)])
	_expect(float(per.w.mass) == 0.0 and Array(per.w.get("flaws", [])) == ["wrong_way"] and int(per.w.get("wrong_way_edges", 0)) == 48 and str(per.w.get("warning", "")).contains("wrong way"),
		"A body with triangles facing the wrong way: no mass, the flaw, its count and the warning (%s)." % str(per.w.get("flaws")))
	_expect(Array(per.x.get("flaws", [])) == ["self_crossing"] and int(per.x.get("self_intersections", 0)) == 52 and str(per.x.get("warning", "")).contains("crosses itself"),
		"A body that crosses itself: the flaw, its count and the warning (%s)." % str(per.x.get("flaws")))
	_expect(float(per.p.mass) == 0.0 and Array(per.p.get("flaws", [])) == ["open"] and str(per.p.get("warning", "")).contains("open"), "An open body: no mass, the flaw and the warning (%s)." % str(per.p.get("flaws")))
	var told := PackedStringArray(props.get("warnings", PackedStringArray()))
	_expect(told.size() == 4 and told[0].begins_with("Inverted: ") and told[1].begins_with("Half flipped: ") and told[2].begins_with("Crossing pair: ") and told[3].begins_with("Plate: "),
		"The mass properties should list every flawed body's warning by name (%s)." % str(told))
	_expect(float(props.mass) >= 0.0 and float(props.volume) >= 0.0, "The totals are never negative.")
	var shown: Dictionary = ANALYSIS.build({"id": "a1", "type": "center_of_mass", "name": "com", "visible": true, "options": {}}, {"bodies": bodies}, {}, kernel, doc)
	_expect(not shown.has("error") and str(shown.info).contains("Inverted: ") and str(shown.info).contains("inside-out") and str(shown.info).contains("Crossing pair: ") and str(shown.info).contains("Plate: "),
		"Center of Mass should show the flawed bodies' warnings (%s)." % str(shown.get("info", shown.get("error", ""))))
	_expect(not str(ANALYSIS.build({"id": "a1", "type": "center_of_mass", "name": "com", "visible": true, "options": {}}, {"bodies": {"ok": bodies.ok}}, {}, kernel, doc).info).contains(":"), "A sound body adds no warning to the readout.")
	checked.append("mass properties (inside-out, wrong-way, self-crossing and open mesh bodies carry flaws, counts and warnings, never a negative mass; the totals and the Center of Mass readout list them)")


# --- Face group picks (verify3 F3) -----------------------------------------------------------

func _check_group_picks(kernel: RefCounted) -> void:
	# The rule itself, on a cube with a group per side.
	var cube := _grouped_cube()
	var top := {"kind": "mesh_group", "body": "c", "group": "g3", "at": Vector3(0.002, 0.01, 0.003), "normal": Vector3.UP}
	var same: Variant = _call(MESH_BODY, "resolve_group", [cube, top])
	var turned: RefCounted = cube.transformed(Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3.ZERO))
	var moved: Variant = _call(MESH_BODY, "resolve_group", [turned, top])
	var by_name: Variant = _call(MESH_BODY, "resolve_group", [turned, {"kind": "mesh_group", "body": "c", "group": "g3"}])
	var smaller: RefCounted = cube.transformed(Transform3D(Basis.from_scale(Vector3.ONE * 0.5), Vector3.ZERO))
	var unchecked: Variant = _call(MESH_BODY, "resolve_group", [smaller, top])
	var lost: Variant = _call(MESH_BODY, "resolve_group", [smaller.transformed(Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3.ZERO)), top])
	var gone: Variant = _call(MESH_BODY, "resolve_group", [cube, {"kind": "mesh_group", "body": "c", "group": "nope"}])
	if same is Dictionary and moved is Dictionary and by_name is Dictionary and unchecked is Dictionary and lost is Dictionary and gone is Dictionary:
		_expect(str(same.get("name", "")) == "g3" and not bool(same.get("moved", false)) and int(same.get("index", -1)) == 3, "A pick that is still where it was resolves to itself (%s)." % str(same))
		_expect(str(moved.get("name", "")) == "g0" and bool(moved.get("moved", false)) and str(moved.get("from", "")) == "g3" and int(moved.get("index", -1)) == 0,
			"After the groups are renumbered, the pick should follow the group that is where it was picked (%s)." % str(moved))
		_expect(str(by_name.get("name", "")) == "g3" and not bool(by_name.get("moved", false)), "An old pick without a point goes by name (%s)." % str(by_name))
		_expect(str(unchecked.get("name", "")) == "g3" and not bool(unchecked.get("moved", false)) and not unchecked.has("error"), "A pick whose point is no longer on the body, on a group that still faces the same way, goes by name (%s)." % str(unchecked))
		_expect(str(lost.get("error", "")).contains("no longer where it was picked"), "A pick whose point is off the body, on a name that now faces another way, is refused (%s)." % str(lost))
		_expect(str(gone.get("error", "")).contains("can't be found"), "A name that is gone is an error (%s)." % str(gone))
	var from_pick := REFERENCES.from_pick({"kind": "mesh_group", "body": "c", "index": 3, "point": Vector3(0.002, 0.01, 0.003), "normal": Vector3.UP}, {"bodies": {"c": _entry("c", cube)}})
	_expect(from_pick.get("at") == Vector3(0.002, 0.01, 0.003) and from_pick.get("normal") == Vector3.UP, "A pick on a face group should keep where it was picked and the normal there (%s)." % str(from_pick))

	# Through the timeline (the verifier's case): the top face of a cube is picked as the plane of a
	# Plane Cut after Generate Face Groups; then a cut is inserted before the groups are made.
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, FIXTURES.to_mesh(FIXTURES.two_cubes(Vector3.ZERO).first), "Cube")
	_tool(doc, "generate_groups", {"bodies": [{"kind": "body", "body": body}], "algorithm": "fast"}, {"angle": ["20", "angle"]})
	var first := REGEN.rebuild(doc, kernel)
	var grouped: RefCounted = first.bodies[body].shape
	var top_name := _group_facing(grouped, Vector3.UP)
	var top_info: Dictionary = grouped.face_info(int(grouped.find_face(top_name)))
	var top_ref := REFERENCES.from_pick({"kind": "mesh_group", "body": body, "index": int(grouped.find_face(top_name)), "point": top_info.point, "normal": Vector3.UP}, first)
	var cut := _tool(doc, "plane_cut", {"bodies": [{"kind": "body", "body": body}], "plane": [top_ref], "type": "trim", "flip": true, "fill": "uniform"}, {"offset": ["-5 mm", "length"]})
	doc.appearances[APPEARANCE.face_target(body, top_name)] = {"material": RED, "at": top_info.point, "normal": Vector3.UP}
	var before := REGEN.rebuild(doc, kernel)
	var size_before: Vector3 = (before.bodies[body].shape.bbox() as AABB).size * 1000.0
	_expect(before.errors.is_empty() and (size_before - Vector3(20, 15, 20)).length() < 0.01 and not str(before.warnings.get(cut.id, "")).contains("moved"),
		"The Plane Cut 5 mm under the top face should leave 20 x 15 x 20 mm, with no word of a moved group (%s; %s)." % [size_before, str(before.errors)])
	doc.rollback = 1
	_tool(doc, "plane_cut", {"bodies": [{"kind": "body", "body": body}], "plane": [{"kind": "origin", "name": "yz"}], "type": "trim", "flip": false, "fill": "uniform"}, {"offset": ["8 mm", "length"]})
	doc.rollback = -1
	var after := REGEN.rebuild(doc, kernel)
	var middle: Resource = DOCUMENT.new()
	middle.restore(doc.snapshot())
	middle.rollback = 3
	var regrouped: RefCounted = REGEN.rebuild(middle, kernel).bodies[body].shape
	var now_top := _group_facing(regrouped, Vector3.UP)
	var size_after: Vector3 = (after.bodies[body].shape.bbox() as AABB).size * 1000.0 if after.bodies.has(body) else Vector3.ZERO
	if now_top == top_name:
		notes.append("the earlier cut did not renumber the face groups in this build (%s stays the top): the timeline case shows nothing" % top_name)
	_expect(not after.errors.has(cut.id) and (size_after - Vector3(2, 15, 20)).length() < 0.01,
		"After an earlier cut renumbers the groups (the top was %s, is %s), the Plane Cut should still cut under the top face: 2 x 15 x 20 mm (%s; error '%s')." % [top_name, now_top, size_after, after.errors.get(cut.id, "")])
	_expect(now_top == top_name or str(after.warnings.get(cut.id, "")).contains("pick of face group %s now lands on face group %s" % [top_name, now_top]),
		"The Plane Cut should say that its pick of face group %s now lands on %s ('%s')." % [top_name, now_top, after.warnings.get(cut.id, "")])
	# The appearance of that face group follows it too.
	var mesh_then: RefCounted = regrouped
	var tess := TESSELLATE.tessellate(mesh_then)
	var built: Dictionary = APPEARANCE.build_mesh(doc, body, mesh_then, tess, StandardMaterial3D.new())
	var red_surface := (built.ids as PackedStringArray).find(RED)
	var top_now_index := int(mesh_then.find_face(now_top))
	_expect(red_surface >= 0 and int(built.face_surfaces[top_now_index]) == red_surface and (built.face_surfaces as PackedInt32Array).count(red_surface) == 1,
		"The appearance given to the top face group should stay on the top face after the groups are renumbered (surfaces %s, top is group %d)." % [str(built.face_surfaces), top_now_index])
	_expect(now_top == top_name or (built.get("notes", PackedStringArray()) as PackedStringArray).size() == 1, "The bake should note the appearance that moved (%s)." % str(built.get("notes", [])))
	# An appearance without a point (an old design) goes by name, as before.
	doc.appearances[APPEARANCE.face_target(body, top_name)] = {"material": RED}
	built = APPEARANCE.build_mesh(doc, body, mesh_then, tess, StandardMaterial3D.new())
	_expect(int(built.face_surfaces[int(mesh_then.find_face(top_name))]) == (built.ids as PackedStringArray).find(RED), "An appearance without a picked point goes by the group's name.")
	doc.appearances.clear()
	checked.append("face group picks (found again where they were picked after the groups are renumbered, with a warning; refused when gone; old picks by name; the Plane Cut of the verifier's case; a face group's appearance)")


# --- Export (verify3 F4) ---------------------------------------------------------------------

func _check_export_hidden(kernel: RefCounted) -> void:
	var doc: Resource = DOCUMENT.new()
	var solid := _add_box(doc, Vector3(0.02, 0.02, 0.02), Vector3.ZERO, "Solid")
	var hidden := _add_mesh(doc, FIXTURES.to_mesh(FIXTURES.icosphere(0.02, 2)), "Hidden ball")
	doc.bodies[hidden]["visible"] = false
	var result := REGEN.rebuild(doc, kernel)
	var folder := TEMP + "/export"
	var report: Dictionary = EXPORT.export_cad_report(kernel, result, [], folder + "/shown.stl", doc)
	var back: RefCounted = MESH_BODY.new_mesh()
	_expect(str(report.error) == "" and report.written == [solid] and report.get("hidden", []) == [hidden] and str(report.note).contains("Hidden ball") and str(report.note).contains("hidden")
		and back.read_stl(folder + "/shown.stl", 0.001) and int(back.triangle_count()) == 12, "With nothing picked, a hidden body should be left out of the file and named (written %s, note '%s', %d triangles)." % [str(report.written), report.note, int(back.triangle_count())])
	report = EXPORT.export_cad_report(kernel, result, [hidden], folder + "/picked.stl", doc)
	back = MESH_BODY.new_mesh()
	_expect(str(report.error) == "" and report.written == [hidden] and report.get("hidden", []) == [] and str(report.note) == "" and back.read_stl(folder + "/picked.stl", 0.001) and int(back.triangle_count()) == 320,
		"A hidden body that is picked is exported (%s)." % str(report))
	var everything: Variant = _call(EXPORT, "export_cad_report", [kernel, result, [], folder + "/all.stl", doc, true])
	if everything is Dictionary:
		back = MESH_BODY.new_mesh()
		_expect((everything.written as Array).size() == 2 and back.read_stl(folder + "/all.stl", 0.001) and int(back.triangle_count()) == 332, "Hidden bodies can still be asked for (%s)." % str(everything.written))
	doc.bodies[solid]["visible"] = false
	report = EXPORT.export_cad_report(kernel, result, [], folder + "/none.stl", doc)
	_expect(str(report.error).contains("hidden") and not FileAccess.file_exists(folder + "/none.stl"), "With every body hidden and none picked, nothing is written and the error says why ('%s')." % report.error)
	_expect(EXPORT.export_cad(kernel, result, [], folder + "/nodoc.stl") == "", "Without the design (no way to tell what is hidden) every body is exported, as before.")
	checked.append("export (hidden bodies left out and named unless picked or asked for; nothing written when all are hidden)")


# --- Stored meshes (verify3 F5 and notes) ----------------------------------------------------

func _check_stored_meshes(kernel: RefCounted) -> void:
	_clear()
	var mesh := FIXTURES.to_mesh(FIXTURES.large_grid(100))
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, mesh, "Big")
	var feature: Resource = doc.features[0]
	var blob: Resource = feature.options.mesh
	var part: Node3D = CAD_PART.new()
	part.name = "DocPart"
	part.document = doc
	root.add_child(part)
	var folder := TEMP + "/scene_forge"
	var kept: Array = part.save_mesh_blobs(folder)
	_expect(kept.size() == 1 and FileAccess.file_exists(str(kept[0])), "The big stored mesh should be saved beside the scene (%s)." % str(kept))
	if kept.size() != 1:
		return
	var path := str(kept[0])
	var good := FileAccess.get_file_as_bytes(path)
	# Damage on disk while the design is open and sound: the next save writes the file again.
	for damage in ["cut in half", "one byte flipped", "emptied"]:
		var hurt := good.slice(0, good.size() / 2) if damage == "cut in half" else (PackedByteArray() if damage == "emptied" else good.duplicate())
		if damage == "one byte flipped":
			hurt[hurt.size() / 2] = hurt[hurt.size() / 2] ^ 0x5A
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_buffer(hurt)
		file.close()
		part.save_mesh_blobs(folder)
		var again: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) if FileAccess.get_file_as_bytes(path).size() > 0 else null
		var back: RefCounted = again.to_mesh() if again != null and again.get_script() == MESH_BLOB else null
		_expect(back != null and str(back.digest()) == str(mesh.digest()), "A file beside the scene that was %s should be written again by the next save." % damage)
	# A sound file is not written again.
	var stamp := FileAccess.get_modified_time(path)
	var bytes := FileAccess.get_file_as_bytes(path)
	part.save_mesh_blobs(folder)
	_expect(FileAccess.get_file_as_bytes(path) == bytes and FileAccess.get_modified_time(path) == stamp, "A sound file is left as it is.")

	# A stored mesh that is damaged is the feature's error also when its result is still kept.
	var sound := REGEN.rebuild(doc, kernel)
	_expect(sound.errors.is_empty() and str(sound.bodies[body].shape.digest()) == str(mesh.digest()), "The design builds (%s)." % str(sound.errors))
	var raw: PackedByteArray = mesh.to_blob()
	raw[60] = raw[60] ^ 0x5A
	var damaged: Resource = MESH_BLOB.new()
	damaged.format = blob.format
	damaged.digest = blob.digest
	damaged.size = blob.size
	damaged.vertices = blob.vertices
	damaged.triangles = blob.triangles
	damaged.data = raw.compress(FileAccess.COMPRESSION_ZSTD)
	feature.options["mesh"] = damaged
	var hidden_damage := REGEN.rebuild(doc, kernel)
	_expect(str(hidden_damage.errors.get(feature.id, "")).begins_with("The stored mesh of %s is damaged (checksum mismatch)." % feature.label) and str(hidden_damage.errors.get(feature.id, "")).contains("or delete %s" % feature.label) and not hidden_damage.bodies.has(body),
		"A damaged stored mesh should be an error although the sound one's result is still kept ('%s')." % hidden_damage.errors.get(feature.id, ""))
	# The file swapped for another valid stored mesh: its name says which mesh it should hold.
	var other: Resource = MESH_BLOB.from_mesh(FIXTURES.to_mesh(FIXTURES.icosphere(0.07, 3)))
	ResourceSaver.save(other, path, ResourceSaver.FLAG_COMPRESS)
	var swapped: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	feature.options["mesh"] = swapped
	var wrong := REGEN.rebuild(doc, kernel)
	_expect(str(wrong.errors.get(feature.id, "")).contains("holds another mesh") and str(wrong.errors.get(feature.id, "")).contains(path.get_file()) and not wrong.bodies.has(body),
		"A file beside the scene that holds another valid mesh should be an error, not another body ('%s')." % wrong.errors.get(feature.id, ""))
	feature.options["mesh"] = blob
	_expect(REGEN.rebuild(doc, kernel).errors.is_empty(), "The sound stored mesh builds again.")
	root.remove_child(part)
	part.free()
	checked.append("stored meshes (a damaged file beside the scene is written again on save, a sound one left alone; a damaged or swapped stored mesh is an error although its result is kept)")


# --- Patterns of a Derive, and a Derive whose source changed (verify3 F7, notes) -------------

func _check_patterns_and_derive(kernel: RefCounted) -> void:
	_clear()
	var source: Resource = DOCUMENT.new()
	_add_box(source, Vector3(0.02, 0.02, 0.02), Vector3(0.05, 0.0, 0.0), "Block")
	_add_mesh(source, FIXTURES.to_mesh(FIXTURES.icosphere(0.01, 2, Vector3(0.05, 0.05, 0.0))), "Ball")
	_add_box(source, Vector3(0.01, 0.01, 0.01), Vector3(0.05, 0.0, 0.05), "Peg")
	var path := TEMP + "/derive_source.tres"
	_expect(ResourceSaver.save(source, path) == OK, "The source design should save.")
	var doc: Resource = DOCUMENT.new()
	var derived: Dictionary = INSERT.add_derive(doc, path, kernel)
	_expect(str(derived.error) == "" and derived.feature != null, "The design should derive (%s)." % derived.error)
	if derived.feature == null:
		return
	var derive: Resource = derived.feature
	var plain := REGEN.rebuild(doc, kernel)
	_expect(plain.errors.is_empty() and plain.bodies.size() == 3 and not plain.warnings.has(derive.id), "The Derive brings in three bodies (%s, %s)." % [str(plain.errors), str(plain.warnings)])
	# A Mirror and a Pattern of the Derive copy its B-rep bodies only, and say so.
	var mirror: Resource = doc.add_feature("mirror", "Mirror", {}, {"object_type": "features", "objects": [{"kind": "feature", "feature": derive.id}], "plane": [{"kind": "origin", "name": "yz"}]})
	var mirrored := REGEN.rebuild(doc, kernel)
	_expect(not mirrored.errors.has(mirror.id) and mirrored.bodies.size() > 3 and str(mirrored.warnings.get(mirror.id, "")).contains("Ball") and str(mirrored.warnings.get(mirror.id, "")).contains("mesh bod"),
		"A Mirror of a Derive should say which mesh bodies it leaves out ('%s'; %d bodies, error '%s')." % [mirrored.warnings.get(mirror.id, ""), mirrored.bodies.size(), mirrored.errors.get(mirror.id, "")])
	_expect(str(mirrored.warnings.get(mirror.id, "")).contains("(Ball) is left out"), "The sentence should read 'its mesh body (Ball) is left out' ('%s')." % mirrored.warnings.get(mirror.id, ""))
	doc.remove_feature(mirror.id)
	var pattern: Resource = doc.add_feature("rect_pattern", "Pattern", {"quantity1": doc.make_input("2", "number"), "distance1": doc.make_input("40 mm", "length")},
		{"object_type": "features", "objects": [{"kind": "feature", "feature": derive.id}], "direction1": [{"kind": "origin", "name": "z"}], "distance_type": "spacing"})
	var patterned := REGEN.rebuild(doc, kernel)
	_expect(not patterned.errors.has(pattern.id) and str(patterned.warnings.get(pattern.id, "")).contains("Ball") and str(patterned.warnings.get(pattern.id, "")).contains("mesh bod"),
		"A Pattern of a Derive should say which mesh bodies it leaves out ('%s', error '%s')." % [patterned.warnings.get(pattern.id, ""), patterned.errors.get(pattern.id, "")])
	doc.remove_feature(pattern.id)
	# The source stops making a body: the Derive says which one is gone.
	var fewer: Resource = DOCUMENT.new()
	fewer.restore(source.snapshot())
	fewer.remove_feature(fewer.features[2].id)
	# (A later modified time, so the change is seen whatever the file system's clock step.)
	OS.delay_msec(1100)
	_expect(ResourceSaver.save(fewer, path) == OK, "The changed source should save.")
	INSERT.clear_derive_cache()
	var shrunk := REGEN.rebuild(doc, kernel)
	_expect(not shrunk.errors.has(derive.id) and shrunk.bodies.size() == 2 and str(shrunk.warnings.get(derive.id, "")).contains("Peg") and str(shrunk.warnings.get(derive.id, "")).contains("no longer"),
		"A Derive whose source stopped making a body should say which ('%s'; %d bodies, error '%s')." % [shrunk.warnings.get(derive.id, ""), shrunk.bodies.size(), shrunk.errors.get(derive.id, "")])
	INSERT.clear_derive_cache()
	checked.append("patterns and Derive (a Mirror or Pattern of a Derive names the mesh bodies it leaves out; a Derive names the bodies its source stopped making)")


# --- Preview time limit (10.10 item 3) -------------------------------------------------------

func _check_preview_limit(kernel: RefCounted) -> void:
	var doc: Resource = DOCUMENT.new()
	var made := []
	for k in 2:
		var ball: Resource = doc.add_feature("sphere", "Sphere", {"diameter": doc.make_input("%d mm" % (100 + 10 * k), "length")}, {"operation": OPERATIONS.NEW_BODY, "position": Vector3(0.3 * k, 0.0, 0.0)})
		ball.options.body_id = doc.new_body(ball.id)
		made.append(MESH_FEATURE.add_tessellate(doc, [ball.options.body_id], {"quality": "very_high"}))
	var first: Resource = made[0].feature
	var second: Resource = made[1].feature
	# The short limit for the previewed feature only: the one before it still builds.
	_clear()
	var preview := REGEN.rebuild(doc, kernel, {"mesh_time_limit": 0.05, "mesh_preview_feature": second.id})
	# (Third round: the first one, its kept result gone, gets what is left of the preview's lead time;
	# when that is not enough the preview stops before it and says so.)
	var stopped := str(preview.get("preview_stopped", ""))
	_expect(not preview.errors.has(first.id) and ((preview.bodies.has(str(made[0].bodies[0])) and preview.errors.has(second.id)) or stopped.contains(str(first.label))),
		"While the second Tessellate previews, only it should get the short limit, or the preview should stop before the first and say so (first: '%s', second: '%s', stopped '%s')." % [preview.errors.get(first.id, ""), preview.errors.get(second.id, ""), stopped])
	# Without a previewed feature the limit is the rebuild's, as before.
	_clear()
	var whole := REGEN.rebuild(doc, kernel, {"mesh_time_limit": 0.05})
	_expect(whole.errors.has(first.id) and whole.errors.has(second.id), "A rebuild-wide limit still reaches every Mesh feature (%s)." % str(whole.errors.keys()))
	_clear()
	var full := REGEN.rebuild(doc, kernel)
	_expect(full.errors.is_empty(), "With the full time both build (%s)." % str(full.errors))
	checked.append("preview limit (only the previewed feature gets the short time; a rebuild-wide limit still works)")


# --- Second fix round (the re-verifier's F3, I1, I2, I3, the thin overlap) ----------------------
func _check_second_round(kernel: RefCounted) -> void:
	# F3. Picks that hold less than name, point and facing are never followed, and say so.
	var cube := _grouped_cube()
	var fixture: Dictionary = FIXTURES.two_cubes(Vector3.ZERO).first
	# The same cube after its groups were numbered anew: g3 is the +Z side now, g1 the top.
	var renumbered: RefCounted = MESH_BODY.new_mesh()
	renumbered.set_arrays(fixture.positions, fixture.indices, PackedInt32Array([0, 0, 3, 3, 2, 2, 1, 1, 4, 4, 5, 5]), PackedStringArray(["g0", "g1", "g2", "g3", "g4", "g5"]), "godot")
	var middle := Vector3(0, 0.01, 0)
	var on_edge := Vector3(0.01, 0.01, 0.002)
	var by_name: Dictionary = MESH_BODY.resolve_group(renumbered, {"group": "g3"})
	_expect(str(by_name.get("name", "")) == "g3" and bool(by_name.get("unchecked", false)) and not bool(by_name.get("moved", false)), "A pick kept by name only should be used unchecked (%s)." % str(by_name))
	var sure: Dictionary = MESH_BODY.resolve_group(cube, {"group": "g3", "at": middle})
	_expect(str(sure.get("name", "")) == "g3" and not sure.has("unchecked") and not sure.has("error"), "A pick by name and point is confirmed when the named group is the only one through the point (%s)." % str(sure))
	var off: Dictionary = MESH_BODY.resolve_group(renumbered, {"group": "g3", "at": middle})
	_expect(off.has("error") and str(off.error).contains("Pick it again"), "A pick by name and point whose point is clearly off the named group should be refused, not followed (%s)." % str(off))
	var several: Dictionary = MESH_BODY.resolve_group(cube, {"group": "g3", "at": on_edge})
	_expect(str(several.get("name", "")) == "g3" and bool(several.get("unchecked", false)) and not bool(several.get("moved", false)), "A pick by name and point where several groups meet should be used unchecked, never moved (%s)." % str(several))
	var followed: Dictionary = MESH_BODY.resolve_group(renumbered, {"group": "g3", "at": middle, "normal": Vector3.UP})
	_expect(str(followed.get("name", "")) == "g1" and bool(followed.get("moved", false)), "A pick with name, point and facing is still followed (%s)." % str(followed))
	# Through the timeline (the verifier's case): an earlier trim hands g3 to another face.
	for form in ["name", "at"]:
		_clear()
		var doc: Resource = DOCUMENT.new()
		var id := _add_mesh(doc, FIXTURES.to_mesh(fixture), "Cube")
		_tool(doc, "generate_groups", {"bodies": [{"kind": "body", "body": id}], "algorithm": "fast"}, {"angle": ["20", "angle"]})
		var grouped: RefCounted = REGEN.rebuild(doc, kernel).bodies[id].shape
		var pick := {"kind": "mesh_group", "body": id, "group": _group_facing(grouped, Vector3.UP)}
		if form == "at":
			pick["at"] = middle
		var cut := _tool(doc, "plane_cut", {"bodies": [{"kind": "body", "body": id}], "plane": [pick], "type": "trim", "flip": true, "fill": "uniform"}, {"offset": ["-5 mm", "length"]})
		var before := REGEN.rebuild(doc, kernel)
		var said := str(before.warnings.get(cut.id, ""))
		_expect(not before.errors.has(cut.id) and said.contains("could not be confirmed") == (form == "name"), "Before any earlier change, a pick by %s should build, with a warning only when it is by name alone ('%s', '%s')." % [form, before.errors.get(cut.id, ""), said])
		doc.rollback = 1
		_tool(doc, "plane_cut", {"bodies": [{"kind": "body", "body": id}], "plane": [{"kind": "origin", "name": "yz"}], "type": "trim", "flip": false, "fill": "uniform"}, {"offset": ["8 mm", "length"]})
		doc.rollback = -1
		var after := REGEN.rebuild(doc, kernel)
		_expect(after.errors.has(cut.id) or str(after.warnings.get(cut.id, "")).contains("could not be confirmed"), "After an earlier trim, a Plane Cut that picked the top by %s must fail or warn, never cut another face silently ('%s')." % [form, after.warnings.get(cut.id, "")])
		_expect(not str(after.warnings.get(cut.id, "")).contains("now lands on"), "A pick by %s must never claim to have followed the group ('%s')." % [form, after.warnings.get(cut.id, "")])
	# I2. A closed body whose triangles disagree is not called open.
	var flipped_indices: PackedInt32Array = (fixture.indices as PackedInt32Array).duplicate()
	var swap := flipped_indices[1]
	flipped_indices[1] = flipped_indices[2]
	flipped_indices[2] = swap
	var flipped: RefCounted = MESH_BODY.new_mesh()
	flipped.set_arrays(fixture.positions, flipped_indices, PackedInt32Array(), PackedStringArray(), "godot")
	var solid: RefCounted = FIXTURES.to_mesh(FIXTURES.two_cubes(Vector3(0.005, 0.0, 0.0)).first)
	var hits: Array = INSPECT.interference(kernel, {"f": _entry("f", flipped), "s": _entry("s", solid)}, [], _names({"f": "Flipped", "s": "Solid"}))
	_expect(hits.size() == 1 and str(hits[0].get("error", "")).contains("Flipped") and str(hits[0].error).contains("face the other way") and not str(hits[0].error).contains("open mesh body"),
		"A closed body with wrong-way triangles should be told as that, with its own remedy (%s)." % _text(hits))
	# I1. The stated bound holds also when the time runs out after the coarse pass.
	var ball: RefCounted = kernel.make_sphere(0.02, Vector3.ZERO, "r2a")
	var heavy: RefCounted = MESH_BODY.new_mesh()
	heavy.from_shape(ball, 0.0000010001, deg_to_rad(1.0), false, 30.0)
	var lack := (4.0 / 3.0 * PI * 8e-6 - float(heavy.volume()))
	# (The lens two balls of 20 mm radius share at 30 mm apart.)
	var truth := PI * pow(0.01, 2.0) * (0.03 * 0.03 + 2.0 * 0.03 * 0.02 - 3.0 * 0.0004 + 2.0 * 0.03 * 0.02 + 6.0 * 0.0004 - 3.0 * 0.0004) / (12.0 * 0.03)
	for limit: float in [1.5, 20.0]:
		_clear()
		var found: Array = INSPECT.interference(kernel, {"m": _entry("m", heavy), "b": {"id": "b", "shape": kernel.make_sphere(0.02, Vector3(0.03, 0, 0), "r2b"), "feature": "f"}}, [], null, limit)
		if found.size() == 1 and not found[0].has("error") and found[0].has("approximate"):
			var wrong := absf(float(found[0].volume) - truth)
			_expect(wrong <= float(found[0].approximate.within) + lack, "With a %s s limit the overlap of a mesh ball and a B-rep ball should be within what is stated (off by %s mm3, stated %s mm3)." % [str(limit), String.num(wrong * 1e9, 3), String.num(float(found[0].approximate.within) * 1e9, 3)])
		else:
			_expect(found.size() == 1 and bool(found[0].get("timed_out", false)), "With a %s s limit the pair should be worked out or listed as not checked (%s)." % [str(limit), _text(found)])
	# A B-rep ball that dips half a thousandth of a millimeter into a mesh cube: not seen, and said.
	_clear()
	var box: RefCounted = FIXTURES.to_mesh(fixture)
	var thin: Array = INSPECT.interference(kernel, {"a": _entry("a", box), "b": {"id": "b", "shape": kernel.make_sphere(0.01, Vector3(0, 0.02 - 0.0000005, 0), "r2c"), "feature": "f"}}, [])
	_expect(thin.size() == 1 and (float(thin[0].volume) > 0.0 or (bool(thin[0].get("unseen", false)) and str(thin[0].get("note", "")).contains("thinner than that is not seen"))),
		"A dip thinner than the tessellation shows should be found or said to be unseen (%s)." % _text(thin))
	var apart: Array = INSPECT.interference(kernel, {"a": _entry("a", box), "b": {"id": "b", "shape": kernel.make_sphere(0.01, Vector3(0.018, 0.018, 0), "r2d"), "feature": "f"}}, [])
	_expect(apart.is_empty(), "A ball 1.3 mm off the cube's edge, boxes overlapping, should list nothing (%s)." % _text(apart))
	# I3. A preview of an earlier feature stops after it.
	_clear()
	var design: Resource = DOCUMENT.new()
	var big := _add_mesh(design, FIXTURES.to_mesh(FIXTURES.icosphere(0.02, 6)), "Ball")
	var scale := _tool(design, "scale", {"bodies": [{"kind": "body", "body": big}], "uniform": true}, {"scale": ["1.0", "number"]})
	_tool(design, "reduce", {"bodies": [{"kind": "body", "body": big}], "target": "proportion", "algorithm": "adaptive"}, {"proportion": ["50", "number"]})
	var smooth := _tool(design, "smooth", {"bodies": [{"kind": "body", "body": big}], "keep_volume": true}, {"strength": ["0.3", "number"], "iterations": ["3", "number"]})
	var whole := REGEN.rebuild(design, kernel)
	scale.set_expression("scale", "1.5")
	var started := Time.get_ticks_msec()
	var preview := REGEN.rebuild(design, kernel, {"mesh_time_limit": MESH_FEATURE.PREVIEW_SECONDS, "mesh_preview_feature": scale.id})
	var took := (Time.get_ticks_msec() - started) / 1000.0
	var shown: RefCounted = preview.bodies[big].shape if preview.bodies.has(big) else null
	_expect(whole.errors.is_empty() and preview.errors.is_empty() and str(preview.get("preview_stops_at", "")) == str(scale.id) and shown != null and int(shown.triangle_count()) == 81920
		and absf((shown.bbox() as AABB).size.x - 0.06) < 1e-4, "A preview of an edited Scale should stop after it and show the body as it leaves the Scale (stops at '%s', errors %s)." % [preview.get("preview_stops_at", ""), str(preview.errors)])
	_expect(took < MESH_FEATURE.PREVIEW_SECONDS + 0.5, "A preview of an earlier feature should not run the features after it (%.2f s)." % took)
	var last := REGEN.rebuild(design, kernel, {"mesh_time_limit": MESH_FEATURE.OK_SECONDS, "mesh_preview_feature": smooth.id})
	_expect(not last.has("preview_stops_at") and last.errors.is_empty(), "A preview of the last feature leaves nothing out (%s)." % str(last.errors))
	notes.append("a preview of an edited Scale before Reduce and Smooth on %d triangles: %.2f s" % [81920, took])
	checked.append("second round (picks by name or by name and point are never followed: confirmed, refused or used with a warning; a wrong-way body's own sentence; the interference bound with a short limit; an unseen thin overlap said; a preview stops after the previewed feature)")


# --- Third fix round (R3: D2, D3, I1) --------------------------------------------------------

func _check_third_round(kernel: RefCounted) -> void:
	# D2. A rigid move of the body: the pick lands on another group, and the sentence says only what
	# is known (the groups were renumbered or the body moved), never "moved from ... to ...".
	var cube := _grouped_cube()
	var turned: RefCounted = cube.transformed(Transform3D(Basis(Vector3.RIGHT, PI / 2.0), Vector3.ZERO))
	var top := _group_facing(cube, Vector3.UP)
	var landed: Dictionary = MESH_BODY.resolve_group(turned, {"group": top, "at": Vector3(0, 0.01, 0), "normal": Vector3.UP})
	var told := MESH_BODY.moved_note("Plane Cut1", top, str(landed.get("name", "")))
	_expect(bool(landed.get("moved", false)) and str(landed.name) == _group_facing(turned, Vector3.UP) and told.contains("now lands on face group %s" % landed.name)
		and told.contains("renumbered the face groups or moved the body") and told.contains("Pick it again if %s is meant" % top) and not told.contains("moved from"),
		"After the body was turned, a pick of %s should land on the group now at its place and say both causes ('%s'; %s)." % [top, told, str(landed)])
	# D3. A preview whose earlier Remesh has to be worked out again: within its limit plus a second,
	# stopped with a sentence, and no error on the Remesh.
	_clear()
	var design: Resource = DOCUMENT.new()
	var ball := _add_mesh(design, FIXTURES.to_mesh(FIXTURES.icosphere(0.02, 6)), "Ball")
	var remesh := _tool(design, "remesh", {"bodies": [{"kind": "body", "body": ball}]}, {})
	var smooth := _tool(design, "smooth", {"bodies": [{"kind": "body", "body": ball}], "keep_volume": true}, {"strength": ["0.3", "number"], "iterations": ["1", "number"]})
	var whole := REGEN.rebuild(design, kernel)
	_clear()
	var started := Time.get_ticks_msec()
	var preview := REGEN.rebuild(design, kernel, {"mesh_time_limit": MESH_FEATURE.PREVIEW_SECONDS, "mesh_preview_feature": smooth.id})
	var took := (Time.get_ticks_msec() - started) / 1000.0
	var said := str(preview.get("preview_stopped", ""))
	_expect(whole.errors.is_empty() and took <= MESH_FEATURE.PREVIEW_SECONDS + 1.0 and preview.errors.is_empty()
		and said.contains("%s is not previewed" % smooth.label) and said.contains(remesh.label) and str(preview.warnings.get(smooth.id, "")).contains(said)
		and str(preview.get("preview_stops_at", "")) == str(design.features[0].id) and preview.bodies.has(ball),
		"A preview whose earlier Remesh lost its kept result should stop within %s s with a sentence and no Remesh error (%.2f s; stopped '%s'; stops at '%s'; errors %s)." % [String.num(MESH_FEATURE.PREVIEW_SECONDS + 1.0, 1), took, said, preview.get("preview_stops_at", ""), str(preview.errors)])
	notes.append("a preview of a Smooth after a Remesh whose kept result was gone: %.2f s, '%s'" % [took, said.left(80)])
	var after_ok := REGEN.rebuild(design, kernel)
	var again := REGEN.rebuild(design, kernel, {"mesh_time_limit": MESH_FEATURE.PREVIEW_SECONDS, "mesh_preview_feature": smooth.id})
	_expect(after_ok.errors.is_empty() and not again.has("preview_stopped"), "Once the full build kept the Remesh again, the preview should run (%s; %s)." % [str(after_ok.errors), str(again.get("preview_stopped", ""))])
	# A chain of Scales whose kept results are gone: stopped near the limit with a sentence.
	_clear()
	var chain: Resource = DOCUMENT.new()
	var grid := _add_mesh(chain, FIXTURES.to_mesh(FIXTURES.large_grid(166)), "Grid")
	var scales := []
	for k in 16:
		scales.append(_tool(chain, "scale", {"bodies": [{"kind": "body", "body": grid}], "uniform": true}, {"scale": ["1.01", "number"]}))
	REGEN.rebuild(chain, kernel)
	_clear()
	started = Time.get_ticks_msec()
	var long := REGEN.rebuild(chain, kernel, {"mesh_time_limit": MESH_FEATURE.PREVIEW_SECONDS, "mesh_preview_feature": scales[15].id})
	took = (Time.get_ticks_msec() - started) / 1000.0
	_expect(took <= MESH_FEATURE.PREVIEW_SECONDS + 1.0 + 0.5 and long.errors.is_empty() and (long.has("preview_stopped") or not long.has("preview_stops_at")),
		"A preview after 15 Scales whose kept results are gone should stop near its limit with a sentence (%.2f s; '%s'; errors %s)." % [took, long.get("preview_stopped", ""), str(long.errors)])
	notes.append("a preview of the last of 16 Scales on %d triangles with nothing kept: %.2f s" % [int(FIXTURES.to_mesh(FIXTURES.large_grid(166)).triangle_count()), took])
	# Every feature after the previewed one suppressed: nothing is left out, so nothing is said.
	_clear()
	for i in range(design.feature_index(remesh.id) + 1, design.features.size()):
		design.features[i].suppressed = true
	var none := REGEN.rebuild(design, kernel, {"mesh_time_limit": MESH_FEATURE.PREVIEW_SECONDS, "mesh_preview_feature": remesh.id})
	_expect(not none.has("preview_stops_at"), "With every later feature suppressed a preview leaves nothing out (stops at '%s')." % none.get("preview_stops_at", ""))
	# I1. A thin overlap of two mesh cubes: the volume is within what is stated (float corners).
	for case in [[2.0, 0.000001], [2.0, 0.000002], [2.0, 0.00001], [0.02, 0.000001], [0.02, 0.005]]:
		var s: float = case[0]
		var dip: float = case[1]
		_clear()
		var one: RefCounted = FIXTURES.to_mesh(FIXTURES.cube(s, Vector3.ZERO))
		var two: RefCounted = one.transformed(Transform3D(Basis.IDENTITY, Vector3(s - dip, s * 0.13, s * 0.07)))
		var truth := dip * (s * 0.87) * (s * 0.93)
		var found: Array = INSPECT.interference(kernel, {"a": _entry("a", one), "b": _entry("b", two)}, [])
		var within := float(found[0].approximate.within) if found.size() == 1 and found[0].has("approximate") else 0.0
		var off := absf(float(found[0].volume) - truth) if found.size() == 1 else INF
		_expect(found.size() == 1 and off <= within + truth * 1e-4, "Mesh cubes of %s mm overlapping by %s mm: the volume should be within what is stated (off %s mm3, stated %s mm3; %s)." % [String.num(s * 1000.0, 0), String.num(dip * 1000.0, 4), String.num(off * 1e9, 6), String.num(within * 1e9, 6), _text(found)])
		if dip >= 0.005 and found.size() == 1:
			_expect(not found[0].has("approximate"), "A plain overlap of mesh cubes should be given as exact (%s)." % _text(found))
	checked.append("third round (a pick after a rigid move says both causes; a preview stops near its limit with a sentence when earlier kept results are gone, and says nothing when the later features are suppressed; thin mesh overlaps carry a true bound)")

# --- Bake (fix round item) -------------------------------------------------------------------

func _check_bake(kernel: RefCounted) -> void:
	_clear()
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, FIXTURES.to_mesh(FIXTURES.large_grid(160, 1.0)), "Big")
	var small := _add_mesh(doc, _grouped_cube().transformed(Transform3D(Basis.IDENTITY, Vector3(0.3, 0.0, 0.0))), "Small")
	var solid := _add_box(doc, Vector3(0.02, 0.02, 0.02), Vector3(-0.3, 0.0, 0.0), "Solid")
	var result := REGEN.rebuild(doc, kernel)
	var triangles := int(result.bodies[body].shape.triangle_count())
	var part: Node3D = CAD_PART.new()
	part.name = "BakePart"
	part.document = doc
	part.generate_collision = true
	root.add_child(part)
	var started := Time.get_ticks_usec()
	part.apply_result(result)
	var first_ms := (Time.get_ticks_usec() - started) / 1000.0
	await process_frame
	var node: MeshInstance3D = part.body_nodes().get(body)
	var small_node: MeshInstance3D = part.body_nodes().get(small)
	var mesh_before: Mesh = node.mesh if node != null else null
	var shape_before: Shape3D = (node.get_node("Collision/Shape") as CollisionShape3D).shape if node != null else null
	var again := REGEN.rebuild(doc, kernel)
	started = Time.get_ticks_usec()
	part.apply_result(again)
	var second_ms := (Time.get_ticks_usec() - started) / 1000.0
	await process_frame
	_expect(node != null and is_same(part.body_nodes().get(body), node) and is_same(node.mesh, mesh_before) and is_same((node.get_node("Collision/Shape") as CollisionShape3D).shape, shape_before),
		"A mesh body that did not change should keep its baked mesh and collision shape.")
	_expect(second_ms < first_ms * 0.25, "Baking again with nothing changed should take a fraction of the first bake (%.1f ms after %.1f ms for %d triangles)." % [second_ms, first_ms, triangles])
	notes.append("bake of a %d-triangle mesh body (with collision), a small one and a box: %.1f ms the first time, %.1f ms again with nothing changed" % [triangles, first_ms, second_ms])
	# What changes a body's look or shape bakes it again.
	var small_before: Mesh = small_node.mesh
	doc.appearances[APPEARANCE.body_target(small)] = {"material": RED}
	part.apply_result(again)
	_expect(not is_same(small_node.mesh, small_before) and small_node.mesh.surface_get_material(0) == APPEARANCE.MATERIAL_LIBRARY.material(RED) and is_same(node.mesh, mesh_before),
		"A new appearance should bake that body again, and only that one.")
	small_before = small_node.mesh
	doc.appearances[APPEARANCE.face_target(small, "g3")] = {"material": "builtin:metal_chrome"}
	part.apply_result(again)
	_expect(not is_same(small_node.mesh, small_before) and small_node.mesh.get_surface_count() == 2, "A face group's appearance should bake the body again.")
	small_before = small_node.mesh
	doc.bodies[small]["name"] = "Renamed"
	doc.bodies[small]["visible"] = false
	part.apply_result(again)
	_expect(is_same(small_node.mesh, small_before) and small_node.name == "Renamed" and not small_node.visible, "A new name or a hidden body needs no new mesh, and still shows on the node.")
	var move: Resource = doc.add_feature("move", "Move", {"x": doc.make_input("5 mm", "length")}, {"objects": [{"kind": "body", "body": small}], "move_type": "free"})
	var moved := REGEN.rebuild(doc, kernel)
	part.apply_result(moved)
	_expect(not moved.errors.has(move.id) and not is_same(small_node.mesh, small_before) and absf(small_node.get_aabb().get_center().x - 0.305) < 1e-5, "A body that moved is baked again (%s)." % moved.errors.get(move.id, ""))
	part.generate_collision = false
	part.apply_result(moved)
	_expect(node.get_node_or_null("Collision") == null and is_same(node.mesh, mesh_before), "Turning collision off removes it without baking the mesh again.")
	part.generate_collision = true
	part.apply_result(moved)
	var shape_now: Shape3D = (node.get_node("Collision/Shape") as CollisionShape3D).shape if node.get_node_or_null("Collision/Shape") != null else null
	_expect(shape_now is ConcavePolygonShape3D and (shape_now as ConcavePolygonShape3D).get_faces().size() == triangles * 3 and is_same(node.mesh, mesh_before), "Turning collision on again adds it for the kept mesh.")
	_expect(part.body_nodes().has(solid) and (part.body_nodes()[solid] as MeshInstance3D).mesh != null, "The B-rep body bakes as before.")
	root.remove_child(part)
	part.free()
	checked.append("bake (an unchanged mesh body keeps its baked mesh and collision; a new look, a move or the collision switch still take effect)")


func _remove_folder(folder: String) -> void:
	var system := ProjectSettings.globalize_path(folder)
	var dir := DirAccess.open(system)
	if dir == null:
		return
	for file in dir.get_files():
		DirAccess.remove_absolute(system.path_join(file))
	for sub in dir.get_directories():
		_remove_folder(system.path_join(sub))
	DirAccess.remove_absolute(system)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
