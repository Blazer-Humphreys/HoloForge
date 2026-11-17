extends SceneTree
## Holo Forge Phase 6 acceptance test (the Form feature, contract C2, and the Form environment's
## workspace hooks without an editor):
## - a form holding the cube cage converts into one closed solid with the cube cage's limit volume;
## - an open form previews: its cage bodies and every feature after it are left out;
## - the conversion cache hands back the very same shapes for an unchanged cage, also after an
##   undo-style restore, and new ones once a vertex moves;
## - a creased cage edge stays sharp through conversion; a mirrored cage stays exactly symmetric
##   through an edit and conversion;
## - one Catmull-Clark step leaves the limit surface where it was;
## - in a headless workspace: Create Form, a Box through the tool engine (one step), a view-only
##   display change, and Finish Form;
## - documents without forms rebuild exactly as before, keep their snapshot keys and load from a
##   saved resource without warnings.
##
## godot --headless --path . --script res://tests/holo_forge_form_test.gd

const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const FORM := preload("res://addons/holo_forge/core/features/form.gd")
const CAGE := preload("res://addons/holo_forge/core/form/cage.gd")
const FORM_OPS := preload("res://addons/holo_forge/core/form/form_ops.gd")
const PRIMITIVES := preload("res://addons/holo_forge/core/form/primitives.gd")
const SKETCH_DATA := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const WORKSPACE := preload("res://addons/holo_forge/ui/forge_workspace.gd")
const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")

## The cube cage [-1, 1]^3's limit volume (the native test's 2.620419), and at 10 mm half-size.
const CUBE_LIMIT_VOLUME := 2.620419
const HALF := 0.01
## doc.snapshot() keys before Phase 6: forms add none.
const SNAPSHOT_KEYS := ["units", "user_parameters", "features", "rollback", "named_views", "selection_sets", "bodies",
	"origin_visibility", "counters", "components", "active_component", "appearances", "physical_materials", "analyses",
	"canvases", "decals"]

var failures: Array[String] = []
var checked: Array[String] = []
var kernel: RefCounted
var doc: Resource


func _init() -> void:
	call_deferred("run")


func run() -> void:
	create_timer(240.0).timeout.connect(func() -> void:
		print("FAIL holo_forge_form: timed out ", failures)
		quit(1))
	kernel = REGEN.make_kernel()
	var native := kernel != null and ClassDB.class_exists("CadSubD")
	if not native:
		print("NOTE: CadKernel / CadSubD are not registered (the holo_forge native DLL is missing): conversion checks skipped.")
	else:
		_check_regen()
		_check_preview()
		_check_cache()
		_check_crease()
		_check_symmetry()
		_check_catmull_clark()
		await _check_workspace()
		_check_old_documents()
	if failures.is_empty():
		print("PASS holo_forge_form: " + (", ".join(checked) if native else "skipped, no native kernel") + ".")
	else:
		print("FAIL holo_forge_form")
		for f in failures:
			print("  - ", f)
	quit(0 if failures.is_empty() else 1)


func _expect(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
		push_error(message)


# --- Helpers -----------------------------------------------------------------------------------

## A document with one Form feature holding the given cages: [doc, feature, [body ids]].
func _form_doc(cages: Array) -> Array:
	doc = DOCUMENT.new()
	var f: Resource = doc.add_feature("form", "Form", {}, FORM.new_options())
	var ids := []
	for cage in cages:
		var body_id: String = doc.new_body(f.id)
		f.options.bodies[body_id] = cage
		ids.append(body_id)
	return [doc, f, ids]


func _cube(half := HALF) -> Dictionary:
	return PRIMITIVES.box(Vector3.ONE * 2.0 * half, Vector3i(1, 1, 1))


func _add(type: String, inputs: Dictionary, options: Dictionary) -> Resource:
	var made := {}
	for key in inputs:
		var spec = inputs[key]
		made[key] = doc.make_input(spec[0], spec[1]) if spec is Array else doc.make_input(str(spec), "length")
	var feature: Resource = doc.add_feature(type, type.capitalize(), made, options)
	if OPERATIONS.creates_body(str(options.get("operation", ""))):
		feature.options["body_id"] = doc.new_body(feature.id)
	return feature


func _box(position_mm: Vector3, l: float, h: float, w: float) -> Resource:
	return _add("box", {"length": "%s mm" % l, "height": "%s mm" % h, "width": "%s mm" % w}, {"position": position_mm * 0.001, "operation": OPERATIONS.NEW_BODY})


# --- 1. Regen ----------------------------------------------------------------------------------

func _check_regen() -> void:
	FORM.clear_cache()
	var made := _form_doc([_cube()])
	var f: Resource = made[1]
	var body_id: String = made[2][0]
	var r := REGEN.rebuild(doc, kernel)
	var body: Dictionary = r.bodies.get(body_id, {})
	_expect(not body.is_empty(), "The form's cube cage should convert into body %s (errors %s)." % [body_id, r.errors])
	if body.is_empty():
		return
	var shape: RefCounted = body.shape
	var expected := CUBE_LIMIT_VOLUME * HALF * HALF * HALF
	_expect(shape.solid_count() == 1, "The converted cube should be one solid (%d)." % shape.solid_count())
	_expect(absf(shape.volume() - expected) <= expected * 5e-4, "The converted cube's volume should be %s m3 within 0.05%% (%s)." % [String.num_scientific(expected), String.num_scientific(shape.volume())])
	var summary: Dictionary = r.forms.get(f.id, {})
	_expect(summary.get("preview", true) == false, "A normal rebuild should not preview the form (%s)." % [summary])
	_expect((summary.get("outputs", {}) as Dictionary).get(body_id, []) == [body_id], "The form summary should list the body's output (%s)." % [summary])
	_expect(str(body.feature) == f.id and (r.errors as Dictionary).is_empty(), "The body should belong to the form, with no errors (%s)." % [r.errors])
	checked.append("cube cage -> 1 solid of %s m3 (0.05%%)" % String.num_scientific(snappedf(shape.volume(), 1e-12)))


# --- 2. Preview --------------------------------------------------------------------------------

func _check_preview() -> void:
	var made := _form_doc([_cube()])
	var f: Resource = made[1]
	var body_id: String = made[2][0]
	var box := _box(Vector3(50, 0, 0), 10, 10, 10)
	var box_body := str(box.options.body_id)
	var preview := REGEN.rebuild(doc, kernel, {"form_preview": f.id})
	_expect(not preview.bodies.has(body_id), "In preview the cage body should be left out (the editor draws it).")
	_expect(not preview.bodies.has(box_body), "In preview the timeline should stop after the form (the later box is left out).")
	_expect(bool(preview.forms.get(f.id, {}).get("preview", false)), "The form summary should say preview (%s)." % [preview.forms])
	var normal := REGEN.rebuild(doc, kernel)
	_expect(normal.bodies.has(body_id) and normal.bodies.has(box_body), "A normal rebuild should have both the form body and the box (%s)." % [normal.bodies.keys()])
	checked.append("preview leaves the cage and later features out")


# --- 3. Cache ----------------------------------------------------------------------------------

func _check_cache() -> void:
	FORM.clear_cache()
	var made := _form_doc([_cube()])
	var f: Resource = made[1]
	var body_id: String = made[2][0]
	var first: RefCounted = REGEN.rebuild(doc, kernel).bodies[body_id].shape
	var second: RefCounted = REGEN.rebuild(doc, kernel).bodies[body_id].shape
	_expect(is_same(first, second), "Two rebuilds of an unchanged cage should hand back the same CadShape.")
	doc.restore(doc.snapshot())
	var restored: RefCounted = REGEN.rebuild(doc, kernel).bodies[body_id].shape
	_expect(is_same(first, restored), "After a snapshot restore (as undo does) the cache should still hit.")
	f = doc.find_feature(f.id)
	var cage: Dictionary = f.options.bodies[body_id]
	var p: PackedFloat64Array = cage.positions
	p[0] += 0.001
	cage.positions = p
	var moved: RefCounted = REGEN.rebuild(doc, kernel).bodies[body_id].shape
	_expect(not is_same(first, moved), "Moving a vertex should convert again (a new CadShape).")
	checked.append("cache: same shapes until a vertex moves (restore included)")


# --- 4. Crease ---------------------------------------------------------------------------------

func _check_crease() -> void:
	FORM.clear_cache()
	var cube := _cube()
	var topo := CAGE.topology(cube)
	var e := 0
	var ab := topo.edge_vertices(e)
	CAGE.set_crease(cube, ab.x, ab.y, CAGE.SHARP)
	var made := _form_doc([cube])
	var f: Resource = made[1]
	var body_id: String = made[2][0]
	var r := REGEN.rebuild(doc, kernel)
	if not r.bodies.has(body_id):
		_expect(false, "The creased cube should convert (%s)." % [r.errors])
		return
	var shape: RefCounted = r.bodies[body_id].shape
	var subd: RefCounted = ClassDB.instantiate("CadSubD")
	subd.set_cage(cube)
	var normals := []
	for face in topo.edge_faces(e):
		var verts := CAGE.face_vertices(cube, face)
		var k := 0
		for i in verts.size():
			if (verts[i] == ab.x and verts[(i + 1) % verts.size()] == ab.y) or (verts[i] == ab.y and verts[(i + 1) % verts.size()] == ab.x):
				k = i
		var uv: Vector2 = [Vector2(0.5, 0.0), Vector2(1.0, 0.5), Vector2(0.5, 1.0), Vector2(0.0, 0.5)][k]
		var ev: Dictionary = subd.evaluate(PackedInt32Array([face]), PackedVector2Array([uv]))
		var pd: PackedFloat64Array = ev.positions
		var point := Vector3(pd[0], pd[1], pd[2])
		var index: int = shape.find_face("%s/%s/f%d" % [f.id, body_id, face])
		_expect(index >= 0, "The converted face of cage face %d should be named %s/%s/f%d." % [face, f.id, body_id, face])
		if index >= 0:
			normals.append(shape.face_normal_at(index, point))
	if normals.size() == 2:
		var angle := rad_to_deg((normals[0] as Vector3).angle_to(normals[1]))
		_expect(angle >= 60.0, "The faces either side of the creased edge should meet at 60 deg or more (%.2f)." % angle)
		checked.append("crease stays sharp after conversion (%.1f deg)" % angle)


# --- 5. Symmetry -------------------------------------------------------------------------------

func _check_symmetry() -> void:
	FORM.clear_cache()
	var box := PRIMITIVES.box(Vector3.ONE * 0.02, Vector3i(2, 2, 2))
	box = PRIMITIVES.primitive_symmetry(box, "mirror", Transform3D.IDENTITY, Vector3i(1, 0, 0), 0)
	var mover := -1
	for v in CAGE.vertex_count(box):
		var q := CAGE.position_d(box, v)
		if q[0] > 0.005 and q[1] > 0.005 and q[2] > 0.005:
			mover = v
			break
	var r := FORM_OPS.edit_transform(box, {"vertices": PackedInt32Array([mover])}, {"translate": Vector3(0.0013, 0.0021, -0.0007)})
	_expect(r.ok, "The mirrored edit should apply (%s)." % r.error)
	var made := _form_doc([r.cage])
	var body_id: String = made[2][0]
	var built := REGEN.rebuild(doc, kernel)
	if not built.bodies.has(body_id):
		_expect(false, "The mirrored box should convert (%s)." % [built.errors])
		return
	var com: Vector3 = built.bodies[body_id].shape.center_of_mass()
	_expect(absf(com.x) <= 1e-9, "The mirrored body's centre of mass should lie on the mirror plane (x = %s m)." % String.num_scientific(com.x))
	checked.append("mirror edit converts symmetric (|x_com| %s m)" % String.num_scientific(absf(com.x)))


# --- 6. Catmull-Clark exactness ----------------------------------------------------------------

func _check_catmull_clark() -> void:
	# At 10 mm the float32 points closest_points takes round by under 1e-9 m.
	var cube := _cube(HALF)
	var step := CAGE.catmull_clark_step(cube)
	var parent: RefCounted = ClassDB.instantiate("CadSubD")
	var child: RefCounted = ClassDB.instantiate("CadSubD")
	_expect(parent.set_cage(cube) and child.set_cage(step.cage), "Both cages should load.")
	var rng := RandomNumberGenerator.new()
	rng.seed = 6
	var faces := PackedInt32Array()
	var uvs := PackedVector2Array()
	for i in 100:
		faces.append(rng.randi_range(0, 5))
		uvs.append(Vector2(rng.randf(), rng.randf()))
	var ev: Dictionary = parent.evaluate(faces, uvs)
	var pd: PackedFloat64Array = ev.positions
	var points := PackedVector3Array()
	for i in 100:
		points.append(Vector3(pd[3 * i], pd[3 * i + 1], pd[3 * i + 2]))
	var cp: Dictionary = child.closest_points(points)
	var worst := 0.0
	for d in cp.get("distances", PackedFloat64Array()):
		worst = maxf(worst, d)
	# The points went through float32 (Vector3): compare against that rounding, never looser than 1e-9.
	var rounding := 0.0
	for i in 100:
		var dx: float = pd[3 * i] - float(points[i].x)
		var dy: float = pd[3 * i + 1] - float(points[i].y)
		var dz: float = pd[3 * i + 2] - float(points[i].z)
		rounding = maxf(rounding, sqrt(dx * dx + dy * dy + dz * dz))
	_expect((cp.get("distances", PackedFloat64Array()) as PackedFloat64Array).size() == 100 and worst <= maxf(1e-9, 2.0 * rounding + 1e-12),
		"The limit of the cube and of its Catmull-Clark step should agree within 1e-9 (worst %s, float32 rounding %s)." % [String.num_scientific(worst), String.num_scientific(rounding)])
	checked.append("Catmull-Clark step keeps the limit (worst %s m)" % String.num_scientific(snappedf(worst, 1e-13)))


# --- 7. Headless workspace ---------------------------------------------------------------------

func _check_workspace() -> void:
	FORM.clear_cache()
	var ws: Control = WORKSPACE.new()
	root.add_child(ws)
	ws.size = Vector2(1400, 900)
	for i in 3:
		await process_frame
	var part: Node3D = CAD_PART.new()
	part.document = DOCUMENT.new()
	root.add_child(part)
	ws.set_part(part)
	await process_frame
	var d: Resource = part.document
	var f: Resource = ws.create_form()
	_expect(f != null and d.features.size() == 1 and d.features[0].type == "form", "Create Form should add a form feature.")
	_expect(str(ws.last_step.get("name", "")) == "Create Form", "Create Form should be one step named Create Form (%s)." % ws.last_step.get("name", ""))
	_expect(f != null and ws.form_preview == f.id and ws.form_editor.active, "Create Form should open the form in preview (%s)." % ws.form_preview)
	if f == null:
		ws.queue_free()
		return
	# Box through the tool engine: OK before any click places it at the XY origin plane.
	var editor: RefCounted = ws.form_editor
	editor.start_tool("box")
	_expect(editor.tool == "box" and ws.panel.visible, "The Box tool should open its panel.")
	editor.set_tool_values({"length": "20 mm", "width": "20 mm", "height": "20 mm"})
	var model_before: Dictionary = ws._model_of(d.snapshot())
	editor.tool_ok()
	await process_frame
	f = d.find_feature(f.id)
	var bodies: Dictionary = f.options.bodies
	_expect(str(ws.last_step.get("name", "")) == "Form: Box", "OK should record one step named Form: Box (%s)." % ws.last_step.get("name", ""))
	_expect(ws._model_of(ws.last_step.get("before", {})) == model_before, "Form: Box should be exactly one step (its before is the state before OK).")
	_expect(bodies.size() == 1, "The form should hold one body (%d)." % bodies.size())
	var body_id: String = str(bodies.keys()[0]) if not bodies.is_empty() else ""
	if body_id != "":
		var cage: Dictionary = bodies[body_id]
		_expect(CAGE.vertex_count(cage) == 26 and CAGE.face_count(cage) == 24, "The default box cage should be 26 / 24 (%d / %d)." % [CAGE.vertex_count(cage), CAGE.face_count(cage)])
		_expect(CAGE.validate(cage).is_empty(), "The box cage should be valid (%s)." % [CAGE.validate(cage)])
		var bounds := CAGE.bounds(cage)
		_expect(bounds.size.is_equal_approx(Vector3(0.02, 0.02, 0.02)) and absf(bounds.position.z) < 1e-9,
			"The box should be 20 mm, standing on the XY plane (One Side) (%s)." % bounds)
		_expect(ws.viewport.form_meshes().has(body_id + "/surface"), "The view should show the box's smooth surface (%s)." % [ws.viewport.form_meshes().keys()])
	# Display mode: a view-only step.
	var rebuilds: int = ws.rebuild_count
	editor.set_display("box")
	f = d.find_feature(f.id)
	_expect(ws.rebuild_count == rebuilds, "A display change should rebuild nothing (%d -> %d)." % [rebuilds, ws.rebuild_count])
	_expect(str(ws.last_step.get("name", "")) == "Form: Display Mode", "The display change should be a step named Form: Display Mode (%s)." % ws.last_step.get("name", ""))
	_expect(FORM.display_mode(f, body_id) == "box", "The body should now show as Box.")
	_expect(ws.viewport.form_meshes().has(body_id + "/box") and not ws.viewport.form_meshes().has(body_id + "/surface"), "Box mode should show the cage faces, no smooth surface (%s)." % [ws.viewport.form_meshes().keys()])
	d.restore(ws.last_step.before)
	_expect(FORM.display_mode(d.find_feature(f.id), body_id) == "smooth", "Restoring the step's before should bring back Smooth.")
	ws._refresh_for(d.snapshot())
	# Finish Form converts and returns.
	ws.run_action("finish_form")
	await process_frame
	_expect(ws.form_preview == "" and not editor.active, "Finish Form should leave the environment (%s)." % ws.form_preview)
	_expect(ws.result.get("bodies", {}).has(body_id), "After Finish Form the body should be in the rebuild (%s, errors %s)." % [ws.result.get("bodies", {}).keys(), ws.result.get("errors", {})])
	_expect(part.body_nodes().size() == 1, "Finish Form should bake the body (%d nodes)." % part.body_nodes().size())
	checked.append("workspace: Create Form, Form: Box (one step, 26 vertices), view-only Form: Display Mode, Finish Form bakes")
	ws.set_part(null)
	ws.queue_free()
	part.queue_free()
	await process_frame


# --- 8. Old documents --------------------------------------------------------------------------

func _check_old_documents() -> void:
	doc = DOCUMENT.new()
	var box := _box(Vector3.ZERO, 30, 20, 40)
	var r0 := REGEN.rebuild(doc, kernel)
	var edge := {}
	var shape: RefCounted = r0.bodies[str(box.options.body_id)].shape
	for e in shape.edge_count():
		var info: Dictionary = shape.edge_info(e)
		if info.get("type", "") == "line" and absf(float(info.length) - 0.03) < 1e-6:
			edge = {"kind": "edge", "body": str(box.options.body_id), "name": shape.get_edge_names()[e], "sig": {"type": "line", "point": info.midpoint, "length": info.length}}
			break
	_add("fillet", {"radius": "2 mm"}, {"edges": [edge]})
	var sketch: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options(SKETCH_DATA.ORIGIN_PLANES.xz, "xz"))
	var s = SKETCH_DATA.new(sketch, doc)
	var c := Vector2(0.06, 0.0)
	var p := [s.add_point(c), s.add_point(c + Vector2(0.02, 0)), s.add_point(c + Vector2(0.02, 0.01)), s.add_point(c + Vector2(0, 0.01))]
	for i in 4:
		s.add_line(p[i], p[(i + 1) % 4])
	_add("extrude", {"distance": "10 mm"}, {"profiles": [{"kind": "profile", "sketch": sketch.id, "point": c + Vector2(0.01, 0.005)}], "operation": OPERATIONS.NEW_BODY})
	var before := REGEN.rebuild(doc, kernel)
	var after := REGEN.rebuild(doc, kernel, {})
	_expect(before.bodies.keys() == after.bodies.keys() and before.bodies.size() == 2, "The old-style document should give the same bodies (%s / %s)." % [before.bodies.keys(), after.bodies.keys()])
	for body_id in before.bodies:
		var a: float = before.bodies[body_id].shape.volume()
		var b: float = after.bodies[body_id].shape.volume() if after.bodies.has(body_id) else -1.0
		_expect(absf(a - b) <= absf(a) * 1e-12, "%s should keep its volume (%s / %s)." % [body_id, a, b])
	_expect((before.errors as Dictionary).is_empty() and (before.forms as Dictionary).is_empty(), "No errors and no forms (%s)." % [before.errors])
	_expect(doc.snapshot().keys() == SNAPSHOT_KEYS, "The snapshot keys should be as before Phase 6 (%s)." % [doc.snapshot().keys()])
	var path := "user://holo_forge_form_test_%d.tres" % OS.get_process_id()
	var saved := ResourceSaver.save(doc, path)
	var loaded: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	_expect(saved == OK and loaded != null, "The document should save and load.")
	if loaded != null:
		var r := REGEN.rebuild(loaded, kernel)
		_expect(r.bodies.size() == 2 and (r.warnings as Dictionary).is_empty() and (r.errors as Dictionary).is_empty(),
			"The loaded document should rebuild without warnings (%s, %s)." % [r.warnings, r.errors])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	checked.append("old documents rebuild identically, keep their snapshot keys and load without warnings")
