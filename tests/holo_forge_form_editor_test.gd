@tool
extends RefCounted
## The Form environment inside the real editor (never saves the test scene): Create Form opens the
## Form toolbar (locked switcher) and its palette; a Box placed by clicks (a plane pick, the centre,
## the base, the height) makes a 26-vertex cage drawn as a smooth surface with its edge curves;
## Alt+1/2/3 switch Box / Control Frame / Smooth; a click picks a face, a double-click an edge loop
## of 8; an Edit Form drag on the gizmo's Z arrow moves the face by the drag (one undo step that
## undoes and redoes exactly); an Alt-drag extrudes a face (V +4, E +8, F +4, one step); soft
## modification moves a vertex at half the radius by half the drag; a mirrored box keeps its
## partner exact; Finish Form bakes the bodies and returns to Solid; the timeline chip reopens the
## form with the same cage; undoing Create Form with the form open closes it cleanly; dark and
## light themes recolour the form materials; a 1014-face drag frame is timed against a GDScript
## calibration; the Stage-3 check files run. With --holo-forge-screenshots=<dir> in a windowed editor
## it also saves PNGs of the view in both themes (form_<theme>_<what>.png).
##
## godot --headless --path . --editor -- --holo-forge-form-editor-test
## godot --path . --editor -- --holo-forge-form-editor-test --holo-forge-screenshots=C:/shots

const CATALOG := preload("res://addons/holo_forge/tools/catalog.gd")
const CAGE := preload("res://addons/holo_forge/core/form/cage.gd")
const FORM := preload("res://addons/holo_forge/core/features/form.gd")
const FORM_OPS := preload("res://addons/holo_forge/core/form/form_ops.gd")
const PRIMITIVES := preload("res://addons/holo_forge/core/form/primitives.gd")
const MANIPULATOR := preload("res://addons/holo_forge/core/manipulator_math.gd")
const FORGE_THEME := preload("res://addons/holo_forge/ui/forge_theme.gd")
const TIMING := preload("res://tests/holo_forge_timing.gd")
const CREATE_CHECKS := preload("res://tests/holo_forge_form_editor_create_checks.gd")
const MODIFY_CHECKS := preload("res://tests/holo_forge_form_editor_modify_checks.gd")
const FIX_CHECKS := preload("res://tests/holo_forge_form_editor_fix_checks.gd")
const SHOTS_ARG := "--holo-forge-screenshots="

## The drag-frame timing limit (5.6): 2 x the ratio measured on the dev machine on 2026-10-29
## against a 200k-iteration GDScript float loop: the 1014-face drag frame (handle_mouse motion
## through the mesh update, drag rate 6) measured 4.96-5.13 ms against 15.6 ms, ratio 0.318-0.329
## (target 33 ms).
const DRAG_RATIO_LIMIT := 0.66

var failures: Array[String] = []
var notes: Array[String] = []
var _tree: SceneTree
var _shots := ""
var ws
var doc: Resource
var part: Node3D
var editor: RefCounted
var form_id := ""
var body1 := ""
var body2 := ""


func check(ok: bool, detail: String) -> void:
	if not ok:
		failures.append(detail)
		push_error(detail)
		print("FAIL: ", detail)


func run(plugin: EditorPlugin) -> void:
	_tree = plugin.get_tree()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(SHOTS_ARG):
			_shots = arg.trim_prefix(SHOTS_ARG)
	if DisplayServer.get_name() == "headless":
		_shots = ""
	_tree.create_timer(900.0 if _shots != "" else 420.0).timeout.connect(func() -> void:
		print("FAIL Holo Forge FORM EDITOR: timed out ", failures)
		_tree.quit(1))
	if _shots != "":
		DirAccess.make_dir_recursive_absolute(_shots)
	var stable := 0
	for i in 900:
		await _tree.process_frame
		var opened := EditorInterface.get_edited_scene_root()
		if opened != null and opened.name == "ForgeEditorTest" and opened.is_inside_tree():
			stable += 1
			if stable >= 60:
				break
		else:
			stable = 0
			if i % 30 == 0:
				EditorInterface.open_scene_from_path("res://tests/holo_forge/forge_editor_test.tscn")
	var scene := EditorInterface.get_edited_scene_root()
	if scene == null or scene.name != "ForgeEditorTest":
		push_error("Holo Forge form editor test could not open its scene.")
		_tree.quit(1)
		return
	EditorInterface.set_main_screen_editor("Forge")
	await _frames(5)
	ws = plugin.get("workspace")
	if ws == null or ws.kernel == null or not ClassDB.class_exists("CadSubD"):
		check(false, "The Forge workspace with the native kernel (CadSubD) is needed.")
		_finish()
		return
	ws.theme_store = {}
	ws.set_theme_mode("dark")
	part = ws.add_part_to_scene()
	await _frames(2)
	if part == null or ws.part != part:
		check(false, "A part should be added to edit.")
		_finish()
		return
	doc = part.document
	editor = ws.form_editor
	await _check_create_form()
	await _check_box_by_clicks()
	if body1 == "":
		_finish()
		return
	await _check_display_keys()
	await _check_selection_clicks()
	await _check_soft_drag()
	await _check_edit_drag()
	await _check_alt_drag()
	await _check_symmetry_drag()
	if _shots != "":
		await _shoot_set("dark")
	await _check_finish()
	await _check_reopen()
	await _check_themes()
	if _shots != "":
		await _light_shots()
	await _check_undo_create()
	await _check_performance()
	for checks in [CREATE_CHECKS, MODIFY_CHECKS, FIX_CHECKS]:
		var found: Variant = await checks.run(ws)
		if found is Array:
			for f in found:
				check(false, str(f))
	_finish()


# --- Input ---------------------------------------------------------------------------------------

func _frames(count: int) -> void:
	for i in count:
		await _tree.process_frame


func _button(at: Vector2, pressed: bool, opts := {}) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = at
	event.global_position = at
	event.double_click = bool(opts.get("double", false))
	event.alt_pressed = bool(opts.get("alt", false))
	event.shift_pressed = bool(opts.get("shift", false))
	event.ctrl_pressed = bool(opts.get("ctrl", false))
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	return event


func _motion(at: Vector2, held: bool, opts := {}) -> InputEventMouseMotion:
	var event := InputEventMouseMotion.new()
	event.position = at
	event.global_position = at
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
	event.alt_pressed = bool(opts.get("alt", false))
	event.shift_pressed = bool(opts.get("shift", false))
	return event


func _send(event: InputEvent) -> void:
	ws.viewport._overlay_input(event)


func _click(at: Vector2, opts := {}) -> void:
	_send(_motion(at, false))
	_send(_button(at, true, opts))
	_send(_button(at, false, opts))


## A left drag from a to b in steps (the press, motions, the release).
func _drag(a: Vector2, b: Vector2, opts := {}, steps := 6) -> void:
	_send(_button(a, true, opts))
	for i in range(1, steps + 1):
		_send(_motion(a.lerp(b, float(i) / steps), true, opts))
	_send(_button(b, false, opts))


func _key(keycode: Key, alt := false) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	event.alt_pressed = alt
	return event


func _project(p: Vector3) -> Vector2:
	return ws.viewport.project(p)


func _wpp(p: Vector3) -> float:
	return 1.0 / float(ws.viewport.pixels_per_meter_at(p))


func _feature() -> Resource:
	return doc.find_feature(form_id)


func _cage(body_id: String) -> Dictionary:
	var f := _feature()
	return (f.options.bodies as Dictionary).get(body_id, {}) if f != null else {}


func _counts(body_id: String) -> Vector3i:
	var c := _cage(body_id)
	if c.is_empty():
		return Vector3i.ZERO
	return Vector3i(CAGE.vertex_count(c), CAGE.topology(c).nE, CAGE.face_count(c))


func _camera_position() -> Vector3:
	return ws.viewport.camera_position()


## The limit point and normal at the centre of a cage face.
func _face_centre(body_id: String, face: int) -> Array:
	var subd: RefCounted = editor.subd_of(body_id)
	var ev: Dictionary = subd.evaluate(PackedInt32Array([face]), PackedVector2Array([Vector2(0.5, 0.5)]))
	var p: PackedFloat64Array = ev.positions
	return [Vector3(p[0], p[1], p[2]), (ev.normals as PackedVector3Array)[0]]


## The cage face of a body that faces the camera best among those whose cage normal is near want
## (any when want is zero).
func _facing_face(body_id: String, want := Vector3.ZERO) -> int:
	var cage := _cage(body_id)
	var topo := CAGE.topology(cage)
	var best := -1
	var best_score := -INF
	for f in topo.nF:
		var n := topo.face_normal(cage, f)
		if want != Vector3.ZERO and n.dot(want) < 0.9:
			continue
		var c: Array = _face_centre(body_id, f)
		var score: float = (c[1] as Vector3).dot((_camera_position() - (c[0] as Vector3)).normalized())
		if score > best_score:
			best_score = score
			best = f
	return best


## Drags the gizmo's arrow along axis (0 X, 1 Y, 2 Z) by px pixels-worth; returns the expected
## travel (meters, snapped like the gizmo).
func _drag_arrow(axis: int, px: float, opts := {}) -> float:
	var g = editor.gizmo
	var pivot: Vector3 = g.pivot
	var dir: Vector3 = g.basis[axis].normalized()
	var wpp := _wpp(pivot)
	var a := _project(pivot + dir * 58.0 * wpp)
	var b := _project(pivot + dir * (58.0 + px) * wpp)
	check(g.visible and g.hit(ws.viewport, a) == "move_" + "xyz"[axis], "A press 58 px along the gizmo's %s arrow should take the arrow (got '%s'; gizmo %s at %s, press %s, selection %s)." % ["XYZ"[axis], g.hit(ws.viewport, a), g.visible, pivot, a, editor.selection])
	var ra: Array = ws.viewport.ray_from(a)
	var rb: Array = ws.viewport.ray_from(b)
	var t0 := MANIPULATOR.closest_on_line(pivot, dir, ra[0], ra[1])
	var t1 := MANIPULATOR.closest_on_line(pivot, dir, rb[0], rb[1])
	_drag(a, b, opts)
	var snap: float = ws.viewport.snap_step
	return snappedf(t1 - t0, snap) if snap > 0.0 else t1 - t0


func _select(items: Array) -> void:
	editor.selection.clear()
	for item in items:
		editor.selection.append(item)
	editor._selection_changed()


func _vertex_item(body_id: String, v: int) -> Dictionary:
	return {"kind": "vertex", "body": body_id, "index": v, "pair": Vector2i(-1, -1)}


func _face_item(body_id: String, f: int) -> Dictionary:
	return {"kind": "face", "body": body_id, "index": f, "pair": Vector2i(-1, -1)}


func _set_values(values: Dictionary) -> void:
	var merged: Dictionary = editor.tool_values.duplicate(true)
	merged.merge(values, true)
	ws.panel.set_values(merged)
	ws._on_panel_values_changed(merged)


# --- 2. Create Form ------------------------------------------------------------------------------

func _check_create_form() -> void:
	var create_form := CATALOG.find("solid.create.create_form")
	check(CATALOG.is_enabled(create_form), "Solid > Create Form should be enabled.")
	var create: MenuButton = ws.toolbar.group_menu("Create")
	if create != null:
		var popup := create.get_popup()
		for i in popup.item_count:
			if popup.get_item_text(i) == "Create Form":
				check(not popup.is_item_disabled(i), "Create Form should be enabled in the CREATE menu.")
	ws.run_tool(create_form)
	await _frames(2)
	var f: Resource = doc.features.back() if not doc.features.is_empty() else null
	check(f != null and f.type == "form" and f.label == "Form1", "Create Form should add Form1 (%s)." % [f.label if f != null else null])
	if f == null:
		return
	form_id = f.id
	check(editor.active and ws.form_preview == form_id, "Create Form should open the Form environment.")
	check(ws.toolbar.workspace == "Form" and ws.toolbar.workspace_switcher().disabled and ws.toolbar.workspace_switcher().text == "Form",
		"The toolbar should show the Form workspace with the switcher locked (%s, disabled %s)." % [ws.toolbar.workspace, ws.toolbar.workspace_switcher().disabled])
	check(editor.palette.visible, "The FORM palette should show.")
	var chip := false
	for child in ws.timeline.find_children("*", "Button", true, false):
		if (child as Button).text == "Form1" and (child as Button).has_meta("feature_id"):
			chip = true
	check(chip, "The timeline should show a Form1 chip.")
	check(ws.toolbar.group_menu("Finish") != null, "The Form toolbar should have a FINISH block.")


# --- 3. Box by clicks ----------------------------------------------------------------------------

func _check_box_by_clicks() -> void:
	ws.run_tool(CATALOG.find("form.create.box"))
	await _frames(1)
	check(editor.tool == "box" and ws.is_picking_plane(), "Box should ask for a plane first.")
	var s: float = ws.viewport.origin_size()
	_click(_project(Vector3(s * 0.5, s * 0.5, 0.0)))
	await _frames(1)
	var placement: Array = editor.tool_picks.get("placement", [])
	check(not ws.is_picking_plane() and not placement.is_empty() and (placement[0].normal as Vector3).is_equal_approx(Vector3.BACK),
		"A click on the XY origin plane should place the box on it (%s)." % [placement])
	_click(_project(Vector3.ZERO))
	_send(_motion(_project(Vector3(0.01, 0.01, 0.0)), false))
	_click(_project(Vector3(0.01, 0.01, 0.0)))
	_send(_motion(_project(Vector3(0.0, 0.0, 0.02)), false))
	_click(_project(Vector3(0.0, 0.0, 0.02)))
	await _frames(1)
	var values: Dictionary = editor.evaluated_values()
	check(absf(float(values.get("length", 0.0)) - 0.02) < 2e-4 and absf(float(values.get("height", 0.0)) - 0.02) < 2e-4,
		"The clicks should size the box 20 x 20 x 20 mm (%s, %s, %s)." % [values.get("length"), values.get("width"), values.get("height")])
	# Exact sizes for the checks that follow.
	_set_values({"length": "20 mm", "width": "20 mm", "height": "20 mm"})
	ws.accept_command()
	await _frames(2)
	var f := _feature()
	var bodies: Dictionary = f.options.bodies
	check(bodies.size() == 1, "OK should add one body (%d)." % bodies.size())
	if bodies.is_empty():
		return
	body1 = str(bodies.keys()[0])
	check(CAGE.vertex_count(_cage(body1)) == 26, "The box cage should have 26 vertices (%d)." % CAGE.vertex_count(_cage(body1)))
	var meshes: Dictionary = ws.viewport.form_meshes()
	check(meshes.has(body1 + "/surface") and meshes.has(body1 + "/limit"), "The view should show the smooth surface and its edge curves (%s)." % [meshes.keys()])
	ws.viewport.fit()
	await _frames(2)


# --- 4. Display keys ---------------------------------------------------------------------------

func _check_display_keys() -> void:
	for spec in [[KEY_1, "box", "/box", "/surface"], [KEY_2, "frame", "/points", "/box"], [KEY_3, "smooth", "/limit", "/lines"]]:
		ws.handle_key(_key(spec[0], true))
		await _frames(1)
		var meshes: Dictionary = ws.viewport.form_meshes()
		check(FORM.display_mode(_feature(), body1) == spec[1], "Alt+%s should show %s (%s)." % [OS.get_keycode_string(spec[0]), spec[1], FORM.display_mode(_feature(), body1)])
		check(meshes.has(body1 + spec[2]) and not meshes.has(body1 + spec[3]), "%s should draw %s, not %s (%s)." % [spec[1], spec[2], spec[3], meshes.keys()])
		check(str(ws.last_step.get("name", "")) == "Form: Display Mode", "A display change should be its own step (%s)." % ws.last_step.get("name", ""))


# --- 5. Clicks ---------------------------------------------------------------------------------

func _check_selection_clicks() -> void:
	var face := _facing_face(body1)
	var centre: Array = _face_centre(body1, face)
	_click(_project(centre[0]))
	await _frames(1)
	check(editor.selection.size() == 1 and editor.selection[0].kind == "face" and int(editor.selection[0].index) == face,
		"A click at a face's centre should select that face (%s)." % [editor.selection])
	# An equator edge (both ends half way up) on a side facing the camera.
	var cage := _cage(body1)
	var topo := CAGE.topology(cage)
	var best := -1
	var best_score := -INF
	for e in topo.nE:
		var ab := topo.edge_vertices(e)
		var pa := CAGE.position(cage, ab.x)
		var pb := CAGE.position(cage, ab.y)
		if absf(pa.z - 0.01) > 1e-6 or absf(pb.z - 0.01) > 1e-6:
			continue
		var mid := (pa + pb) * 0.5
		var out := Vector3(mid.x, mid.y, 0.0).normalized()
		var score := out.dot((_camera_position() - mid).normalized())
		if score > best_score:
			best_score = score
			best = e
	var line: PackedVector3Array = editor._edge_polyline(body1, best, Vector2i(-1, -1))
	var at := _project(line[line.size() / 2] if line.size() > 2 else (line[0] + line[1]) * 0.5)
	_click(at)
	_send(_button(at, true, {"double": true}))
	_send(_button(at, false))
	await _frames(1)
	var edges: Array = editor.selection.filter(func(item: Dictionary) -> bool: return item.kind == "edge")
	check(edges.size() == 8 and editor.selection.size() == 8, "A double-click on an equator edge should select its loop of 8 edges (%s)." % [editor.selection.size()])
	if _shots != "":
		await _shot("form_dark_selection_loop.png")


# --- 8. Soft modification ------------------------------------------------------------------------

func _check_soft_drag() -> void:
	var cage := _cage(body1)
	var top := -1
	for v in CAGE.vertex_count(cage):
		if CAGE.position(cage, v).distance_to(Vector3(0, 0, 0.02)) < 1e-6:
			top = v
	var side := -1
	for v in CAGE.vertex_count(cage):
		if CAGE.position(cage, v).distance_to(Vector3(0.01, 0, 0.02)) < 1e-6:
			side = v
	check(top >= 0 and side >= 0, "The box should have a top centre vertex and one 10 mm from it.")
	if top < 0 or side < 0:
		return
	_select([_vertex_item(body1, top)])
	editor.start_tool("edit_form")
	_set_values({"transform_mode": "translate", "soft": true, "extent": "distance", "distance": "20 mm", "transition": "smooth", "weight": "1"})
	await _frames(1)
	check(editor.gizmo.visible, "Edit Form should show the gizmo at the selected vertex.")
	var top_before := CAGE.position_d(cage, top)
	var side_before := CAGE.position_d(_cage(body1), side)
	var history: UndoRedo = ws.history()
	var count := history.get_current_action()
	var expected := _drag_arrow(2, 40.0)
	await _frames(1)
	var top_after := CAGE.position_d(_cage(body1), top)
	var side_after := CAGE.position_d(_cage(body1), side)
	var moved := top_after[2] - top_before[2]
	var half := side_after[2] - side_before[2]
	check(absf(moved - expected) <= _wpp(editor.gizmo.pivot) + 1e-12 and absf(moved) > 0.0, "The selected vertex should move by the drag (%s vs %s)." % [moved, expected])
	check(absf(half - 0.5 * moved) <= 1e-12, "A vertex at R/2 should move half as far with a Smooth falloff (%s vs %s)." % [half, 0.5 * moved])
	check(history.get_current_action() == count + 1, "The soft drag should be one undo step.")
	if _shots != "":
		await _shot("form_dark_soft.png")
	history.undo()
	await _frames(1)
	_set_values({"soft": false})
	editor.cancel_tool()


# --- 6. Edit Form drag ---------------------------------------------------------------------------

func _check_edit_drag() -> void:
	var face := _facing_face(body1, Vector3.BACK)
	_select([_face_item(body1, face)])
	editor.start_tool("edit_form")
	_set_values({"transform_mode": "translate", "space": "world", "soft": false})
	await _frames(1)
	check(editor.gizmo.visible, "Edit Form should show the gizmo at the selected face.")
	var verts := CAGE.face_vertices(_cage(body1), face)
	var before := {}
	for v in verts:
		before[v] = CAGE.position_d(_cage(body1), v)
	var history: UndoRedo = ws.history()
	var count := history.get_current_action()
	var expected := _drag_arrow(2, 45.0)
	await _frames(1)
	var tolerance := _wpp(editor.gizmo.pivot)
	for v in verts:
		var now := CAGE.position_d(_cage(body1), v)
		check(absf(now[2] - before[v][2] - expected) <= tolerance and now[0] == before[v][0] and now[1] == before[v][1],
			"Face vertex %d should move %s m along Z (moved %s)." % [v, expected, now[2] - before[v][2]])
	check(history.get_current_action() == count + 1 and str(ws.last_step.get("name", "")) == "Form: Edit Form", "The drag should be one step named Form: Edit Form.")
	var after := {}
	for v in verts:
		after[v] = CAGE.position_d(_cage(body1), v)
	history.undo()
	await _frames(1)
	for v in verts:
		check(CAGE.position_d(_cage(body1), v) == before[v], "Undo should put vertex %d back exactly." % v)
	history.redo()
	await _frames(1)
	for v in verts:
		check(CAGE.position_d(_cage(body1), v) == after[v], "Redo should move vertex %d again exactly." % v)
	if _shots != "":
		await _shot("form_dark_gizmo.png")


# --- 7. Alt-drag -------------------------------------------------------------------------------

func _check_alt_drag() -> void:
	var face := _facing_face(body1, Vector3.RIGHT)
	_select([_face_item(body1, face)])
	editor.start_tool("edit_form")
	await _frames(1)
	var before := _counts(body1)
	var region_x := CAGE.position_d(_cage(body1), CAGE.face_vertices(_cage(body1), face)[0])[0]
	var history: UndoRedo = ws.history()
	var count := history.get_current_action()
	var travel := _drag_arrow(0, 40.0, {"alt": true})
	await _frames(1)
	var after := _counts(body1)
	var moved_x := CAGE.position_d(_cage(body1), CAGE.face_vertices(_cage(body1), face)[0])[0]
	check(travel > 0.0 and absf(moved_x - region_x - travel) <= _wpp(editor.gizmo.pivot), "The extruded face should move out along +X by the drag (%s vs %s)." % [moved_x - region_x, travel])
	check(after - before == Vector3i(4, 8, 4), "An Alt-drag on one face should add V 4, E 8, F 4 (%s -> %s)." % [before, after])
	check(history.get_current_action() == count + 1, "The Alt-drag (extrude and move) should be one undo step.")
	check(CAGE.validate(_cage(body1)).is_empty(), "The extruded cage should be valid (%s)." % [CAGE.validate(_cage(body1))])
	editor.cancel_tool()


# --- 9. Symmetry -------------------------------------------------------------------------------

func _check_symmetry_drag() -> void:
	editor.start_tool("box")
	_set_values({"length": "20 mm", "width": "20 mm", "height": "20 mm", "symmetry": "mirror", "sym_x": true, "sym_y": false, "sym_z": false})
	editor.set_placement(Vector3(0.05, 0.0, 0.0), Vector3.RIGHT, Vector3.UP, Vector3.BACK)
	ws.accept_command()
	await _frames(2)
	for body_id in _feature().options.bodies:
		if str(body_id) != body1:
			body2 = str(body_id)
	check(body2 != "", "A second box should be added.")
	if body2 == "":
		return
	ws.viewport.fit()
	await _frames(2)
	var cage := _cage(body2)
	var sym: Array = cage.get("symmetry", [])
	check(sym.size() == 1 and str(sym[0].type) == "mirror", "The box should carry one mirror (%s)." % [sym.size()])
	if sym.is_empty():
		return
	var mover := -1
	var best := -INF
	for v in CAGE.vertex_count(cage):
		var p := CAGE.position(cage, v)
		var score := (p - Vector3(0.05, 0, 0.01)).normalized().dot((_camera_position() - p).normalized())
		if p.x > 0.0555 and score > best:
			best = score
			mover = v
	_select([_vertex_item(body2, mover)])
	editor.start_tool("edit_form")
	_set_values({"transform_mode": "translate", "space": "world"})
	await _frames(1)
	_drag_arrow(1, 35.0)
	await _frames(1)
	cage = _cage(body2)
	var partner: int = (cage.symmetry[0].map as PackedInt32Array)[mover]
	var image := FORM_OPS.reflect_d(CAGE.position_d(cage, mover), cage.symmetry[0].origin, cage.symmetry[0].normal)
	var q := CAGE.position_d(cage, partner)
	var gap := Vector3(image[0] - q[0], image[1] - q[1], image[2] - q[2]).length()
	check(partner >= 0 and partner != mover and gap <= 1e-9, "The partner should mirror the dragged vertex within 1e-9 m (gap %s)." % gap)
	check(CAGE.position_d(cage, mover)[1] != 0.0, "The dragged vertex should have moved in Y.")
	editor.cancel_tool()


# --- 10, 11. Finish and reopen -------------------------------------------------------------------

var _hashes := {}


func _check_finish() -> void:
	for body_id in [body1, body2]:
		if body_id != "":
			_hashes[body_id] = CAGE.content_hash(_cage(body_id))
	ws.run_action("finish_form")
	await _frames(3)
	check(not editor.active and ws.form_preview == "", "Finish Form should leave the environment.")
	var nodes: Dictionary = part.body_nodes()
	for body_id in [body1, body2]:
		if body_id == "":
			continue
		check(nodes.has(body_id) and (nodes[body_id] as Node).name == doc.body_name(body_id),
			"The part should bake %s as a node named %s (%s)." % [body_id, doc.body_name(body_id), nodes.keys()])
	check((ws.result.get("errors", {}) as Dictionary).is_empty(), "The timeline should show no error (%s)." % [ws.result.get("errors", {})])
	check(ws.toolbar.workspace == "Solid" and not ws.toolbar.workspace_switcher().disabled, "The toolbar should return to Solid (%s)." % ws.toolbar.workspace)
	check(ws.last_message.begins_with("Form finished: 2 bodies converted"), "Finish Form should say what it converted (%s)." % ws.last_message)
	if _shots != "":
		await _shot("form_dark_finished.png")


func _check_reopen() -> void:
	ws.timeline.feature_edit_requested.emit(form_id)
	await _frames(2)
	check(editor.active and editor.feature_id == form_id and ws.toolbar.workspace == "Form", "Double-clicking the Form chip should reopen the form.")
	for body_id in _hashes:
		check(CAGE.content_hash(_cage(body_id)) == _hashes[body_id], "%s should come back with the same cage." % body_id)
	check(ws.viewport.form_meshes().has(body1 + "/surface") or ws.viewport.form_meshes().has(body1 + "/box"), "The reopened form should draw its bodies.")


# --- 13. Themes ----------------------------------------------------------------------------------

func _check_themes() -> void:
	for mode in ["dark", "light"]:
		ws.set_theme_mode(mode)
		await _frames(1)
		var palette := FORGE_THEME.palette(mode)
		var surface: StandardMaterial3D = editor.display.materials.surface
		var line: StandardMaterial3D = editor.display.materials.line
		check(surface.albedo_color.is_equal_approx(palette.form_surface) and line.albedo_color.is_equal_approx(palette.form_cage_line),
			"The %s theme should recolour the form materials (%s)." % [mode, surface.albedo_color])
		check(editor.theme_colors.get("form_crease") == palette.form_crease, "The overlay should take the %s tokens." % mode)


# --- 12. Undo Create Form while open --------------------------------------------------------------

func _check_undo_create() -> void:
	ws.run_action("create_form")
	await _frames(2)
	var second: Resource = doc.features.back()
	check(editor.active and second != null and second.type == "form" and second.id != form_id, "Create Form should open a second form.")
	var history: UndoRedo = ws.history()
	history.undo()
	await _frames(3)
	check(not editor.active and doc.find_feature(second.id) == null, "Undoing Create Form should close the environment cleanly.")
	check(ws.toolbar.workspace == "Solid" and not ws.toolbar.workspace_switcher().disabled, "The toolbar should be back to Solid.")
	check(ws.viewport.form_meshes().is_empty(), "No form meshes should be left (%s)." % [ws.viewport.form_meshes().keys()])


# --- 14. Performance -----------------------------------------------------------------------------

func _check_performance() -> void:
	var f: Resource = ws.create_form()
	await _frames(1)
	if f == null:
		check(false, "A form should open for the timing check.")
		return
	var big := PRIMITIVES.box(Vector3.ONE * 0.04, Vector3i(13, 13, 13))
	var fid: String = f.id
	ws.change("Form: Test Body", func() -> void: editor.apply_result(fid, {"cages": {}, "new_bodies": [big]}, []))
	await _frames(1)
	var body_id := str((doc.find_feature(fid).options.bodies as Dictionary).keys()[0])
	check(CAGE.face_count(big) == 1014, "The timing cage should have 1014 faces.")
	ws.viewport.fit()
	await _frames(1)
	var topo := CAGE.topology(big)
	var top := -1
	var best := -INF
	for face in topo.nF:
		var n := topo.face_normal(big, face)
		var c := Vector3.ZERO
		for v in CAGE.face_vertices(big, face):
			c += CAGE.position(big, v)
		c /= 4.0
		var score := n.dot((_camera_position() - c).normalized()) if n.z > 0.9 else -INF
		if score > best:
			best = score
			top = face
	_select([_face_item(body_id, top)])
	editor.start_tool("edit_form")
	_set_values({"transform_mode": "translate"})
	await _frames(1)
	var g = editor.gizmo
	var pivot: Vector3 = g.pivot
	var wpp := _wpp(pivot)
	var a := _project(pivot + Vector3.BACK * 58.0 * wpp)
	var b := _project(pivot + Vector3.BACK * 90.0 * wpp)
	var c2 := _project(pivot + Vector3.BACK * 110.0 * wpp)
	_send(_button(a, true))
	_send(_motion(b, true))
	var flip := [false]
	var op := func() -> void:
		flip[0] = not flip[0]
		_send(_motion(c2 if flip[0] else b, true))
	var calibration := func() -> void:
		var x := 0.0
		for i in 200000:
			x += sin(float(i) * 1e-3)
	var timing := TIMING.compare(op, calibration, 5, "form drag frame 1014")
	_send(_button(b, false))
	await _frames(1)
	check(float(timing.ratio) <= DRAG_RATIO_LIMIT, "The 1014-face drag frame should stay within %s x the calibration (%.2f ms, ratio %.3f)." % [DRAG_RATIO_LIMIT, timing.op, timing.ratio])
	notes.append("drag frame 1014 faces %.2f ms (ratio %.3f against %.2f ms; last frame %.2f ms)" % [timing.op, timing.ratio, timing.calibration, editor.last_drag_ms])
	print("Forge FORM: drag frame 1014 faces %.2f ms, calibration %.2f ms, ratio %.3f" % [timing.op, timing.calibration, timing.ratio])
	# Hover picking on the same cage (not a limit check: reported for the 4 ms hover budget).
	editor.cancel_tool()
	# The first pick after a new tessellation builds the native picking BVH (timed on its own).
	var hover_at := _project(pivot)
	var first := Time.get_ticks_usec()
	editor._update_hover(hover_at)
	var first_ms := (Time.get_ticks_usec() - first) / 1000.0
	var started := Time.get_ticks_usec()
	for i in 20:
		editor._update_hover(hover_at + Vector2(float(i % 3), 0.0))
	var hover_ms := (Time.get_ticks_usec() - started) / 20000.0
	notes.append("hover pick 1014 faces %.2f ms (first after a new tessellation %.1f ms)" % [hover_ms, first_ms])
	print("Forge FORM: hover pick 1014 faces %.2f ms, first after a new tessellation %.1f ms" % [hover_ms, first_ms])
	ws.history().undo()
	await _frames(1)
	ws.history().undo()
	await _frames(2)


# --- Screenshots ---------------------------------------------------------------------------------

## Saves the Forge view (the 3D view with its overlay and panels) as a PNG.
func _shot(file: String) -> void:
	if _shots == "":
		return
	await _frames(3)
	ws.viewport.redraw_overlay()
	EditorInterface.get_base_control().queue_redraw()
	await RenderingServer.frame_post_draw
	var window: Window = EditorInterface.get_base_control().get_window()
	var image := window.get_texture().get_image()
	var rect := Rect2i(ws.viewport.get_global_rect()).intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	image.get_region(rect).save_png(_shots.path_join(file))
	print("Forge FORM: saved ", _shots.path_join(file))


## The display modes, a selection with its partners, the gizmo and soft modification.
func _shoot_set(theme: String) -> void:
	editor.cancel_tool()
	ws.viewport.fit()
	await _frames(2)
	for mode in ["box", "frame", "smooth"]:
		editor.set_display(mode, [body1, body2])
		_select([])
		await _shot("form_%s_%s.png" % [theme, mode])
	editor.set_display("frame", [body2])
	editor.set_display("smooth", [body1])
	var face := _facing_face(body1)
	var cage := _cage(body1)
	var topo := CAGE.topology(cage)
	var items := [_face_item(body1, face)]
	for e in topo.face_edges(_facing_face(body1, Vector3.RIGHT)):
		var ab := topo.edge_vertices(e)
		items.append({"kind": "edge", "body": body1, "index": e, "pair": Vector2i(ab.x, ab.y)})
	var cage2 := _cage(body2)
	for v in CAGE.vertex_count(cage2):
		var p := CAGE.position(cage2, v)
		if p.x > 0.0555 and p.z > 0.019:
			items.append(_vertex_item(body2, v))
			break
	_select(items)
	await _shot("form_%s_selection.png" % theme)
	_select([_face_item(body1, face)])
	editor.start_tool("edit_form")
	await _frames(1)
	await _shot("form_%s_gizmo.png" % theme)
	_set_values({"soft": true, "extent": "distance", "distance": "18 mm"})
	await _shot("form_%s_soft.png" % theme)
	_set_values({"soft": false})
	editor.cancel_tool()
	_select([items.back()])
	await _shot("form_%s_symmetry.png" % theme)
	_select([])


## Light theme: the same set in the reopened form, then its Finish.
func _light_shots() -> void:
	ws.set_theme_mode("light")
	if not editor.active:
		ws.edit_feature(form_id)
	await _frames(2)
	await _shoot_set("light")
	ws.run_action("finish_form")
	await _frames(3)
	await _shot("form_light_finished.png")
	ws.set_theme_mode("dark")
	ws.edit_feature(form_id)
	await _frames(2)


func _finish() -> void:
	await _frames(4)
	if failures.is_empty():
		print("PASS Holo Forge FORM EDITOR: Create Form opens the locked Form toolbar and palette; a Box from a plane click and three clicks makes a 26-vertex cage drawn smooth with edge curves; Alt+1/2/3 switch Box, Control Frame and Smooth (view-only steps); a click picks a face and a double-click an 8-edge loop; an Edit Form Z-arrow drag moves the face by the drag as one step that undoes and redoes exactly; an Alt-drag extrudes (+4/+8/+4, one step); soft modification moves a vertex at R/2 by half; a mirrored partner stays within 1e-9 m; Finish Form bakes 2 named bodies with no errors and returns to Solid; the timeline chip reopens the same cages; undoing Create Form with the form open closes it; dark and light recolour the form materials; " + "; ".join(notes) + "; Stage-3 check files run")
	else:
		print("FAIL Holo Forge FORM EDITOR: ", failures)
	_tree.quit(0 if failures.is_empty() else 1)
