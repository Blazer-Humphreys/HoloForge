@tool
extends RefCounted
## In-editor checks for the Form create tools (Stage 3, team M1), run by the Form editor hook
## (tests/holo_forge_form_editor_test.gd) with the open Forge workspace: one scenario per tool,
## each asserting its counts and one undo step. Returns failure strings ([] when all pass).
##
## A step of test sketches goes in first (a circle, a rectangle, a half circle with its axis line,
## a sweep path, three loft circles, a pipe arc), then a form: Extrude takes its profile from a
## real click in the view, Revolve its profile and axis through the picker's slots, Sweep, Loft
## and Pipe theirs likewise (Pipe also gets a section from Add Section and a click on the path),
## and Face is four clicks on the XY plane. Finish Form converts them without errors; every step
## is then undone, so the document is as it was. With --holo-forge-screenshots=<dir> in a windowed
## editor it saves each tool's preview (create_dark_<tool>.png) and the finished set in both themes.

const CAGE := preload("res://addons/holo_forge/core/form/cage.gd")
const SKETCH_DATA := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")

const MM := 0.001
## Where the check sketches sit (clear of the bodies the editor test made).
const BASE := Vector3(0.0, -0.08, 0.0)
const SHOTS_ARG := "--holo-forge-screenshots="


static func run(ws) -> Array:
	var failures: Array = []
	var tree: SceneTree = ws.get_tree()
	if ws.doc == null or not ClassDB.class_exists("CadSubD"):
		return ["The Form create checks need a part and the native kernel."]
	var editor = ws.form_editor
	if editor.active:
		ws.run_action("finish_form")
		await _frames(tree, 2)
	var doc: Resource = ws.doc
	var history: UndoRedo = ws.history()
	var start_action := history.get_current_action() if history != null else 0
	var saved_view: Dictionary = ws.viewport.view_state()
	var ids := {}
	ws.change("Form Create Checks: Sketches", func() -> void: _add_sketches(ws.doc, ids))
	await _frames(tree, 2)
	var form: Resource = ws.create_form()
	await _frames(tree, 1)
	if form == null or not editor.active:
		return ["The Form create checks could not open a form."]
	ws.viewport.set_view_state({"target": Vector3(0.04, -0.07, 0.03), "distance": 0.55, "ortho": false})
	ws.viewport.look_from(Vector3(0.25, 0.35, 1.0))
	await _frames(tree, 2)

	# Extrude: the profile from a click inside the circle.
	editor.start_tool("extrude")
	await _frames(tree, 1)
	_check(failures, editor.tool == "extrude" and ws.panel.active_selection_key == "profile", "Extrude should open with its Profile slot active (%s)." % ws.panel.active_selection_key)
	# Close in on the circle, then click inside it as far as can be from the sweep path's line (it
	# starts at the centre) and from the circle itself.
	var wide_view: Dictionary = ws.viewport.view_state()
	ws.viewport.set_view_state({"target": BASE, "distance": 0.07, "ortho": false})
	ws.viewport.look_from(Vector3(0.25, 0.35, 1.0))
	await _frames(tree, 1)
	var path_a: Vector2 = ws.viewport.project(BASE)
	var path_b: Vector2 = ws.viewport.project(BASE + Vector3(0, 0, 0.03))
	var inside := Vector2.ZERO
	var clear := -1.0
	for q in 8:
		var at: Vector2 = ws.viewport.project(BASE + Vector3(cos(TAU * q / 8.0), sin(TAU * q / 8.0), 0.0) * 0.005)
		var gap := Geometry2D.get_closest_point_to_segment(at, path_a, path_b).distance_to(at)
		if gap > clear:
			clear = gap
			inside = at
	_click(ws, inside)
	await _frames(tree, 1)
	var picked: Array = editor.tool_values.get("profile", [])
	_check(failures, picked.size() == 1 and str(picked[0].get("kind", "")) == "profile", "A click inside the circle should pick it as the profile (%s)." % [picked])
	if picked.size() != 1 or str(picked[0].get("kind", "")) != "profile":
		# Carry on with the profile picked through the slot.
		_set_values(ws, {"profile": []})
		ws.panel.activate_selection("profile")
		ws._on_reference_picked({"kind": "profile", "sketch": ids.circle_sketch, "point": Vector2.ZERO})
	ws.viewport.set_view_state(wide_view)
	await _frames(tree, 1)
	_set_values(ws, {"distance": "20 mm", "front_faces": "1"})
	await _shot(ws, tree, "create_dark_extrude.png", BASE + Vector3(0, 0, 0.01), 0.09)
	await _ok_one_step(ws, tree, failures, "Extrude", form.id, Vector3i(16, 24, 8))

	# Revolve: the half circle round its axis line.
	editor.start_tool("revolve")
	await _frames(tree, 1)
	ws._on_reference_picked({"kind": "sketch_curve", "sketch": ids.arc_sketch, "entity": ids.arc})
	ws.panel.activate_selection("axis")
	ws._on_reference_picked({"kind": "sketch_curve", "sketch": ids.arc_sketch, "entity": ids.axis})
	_set_values(ws, {"profile_faces": "4", "around_faces": "8"})
	await _shot(ws, tree, "create_dark_revolve.png", BASE + Vector3(0.1, 0, 0), 0.07)
	await _ok_one_step(ws, tree, failures, "Revolve", form.id, Vector3i(26, 56, 32))

	# Sweep: the circle along the line.
	editor.start_tool("sweep")
	await _frames(tree, 1)
	ws._on_reference_picked({"kind": "profile", "sketch": ids.circle_sketch, "point": Vector2(0.003, 0.002)})
	ws.panel.activate_selection("path")
	ws._on_reference_picked({"kind": "sketch_curve", "sketch": ids.path_sketch, "entity": ids.path})
	_set_values(ws, {"profile_faces": "8", "path_faces": "4"})
	await _shot(ws, tree, "create_dark_sweep.png", BASE + Vector3(0, 0, 0.015), 0.1)
	await _ok_one_step(ws, tree, failures, "Sweep", form.id, Vector3i(40, 72, 32))

	# Loft: three circles in order.
	editor.start_tool("loft")
	await _frames(tree, 1)
	for k in 3:
		ws._on_reference_picked({"kind": "profile", "sketch": ids["loft%d" % k], "point": Vector2.ZERO})
	_set_values(ws, {"length_faces": "2", "width_faces": "8"})
	await _shot(ws, tree, "create_dark_loft.png", BASE + Vector3(-0.1, 0, 0.06), 0.12)
	await _ok_one_step(ws, tree, failures, "Loft", form.id, Vector3i(40, 72, 32))

	# Pipe: the arc, 4 segments, and a section placed by a click on the path.
	editor.start_tool("pipe")
	await _frames(tree, 1)
	ws._on_reference_picked({"kind": "sketch_curve", "sketch": ids.pipe_sketch, "entity": ids.pipe})
	_set_values(ws, {"diameter": "8 mm", "density": "4"})
	await _frames(tree, 1)
	editor.on_button("add_section")
	var mid: Vector3 = (ids.pipe_origin as Vector3) + Vector3(cos(PI * 0.25), sin(PI * 0.25), 0.0) * 0.025
	var on_path: Vector2 = ws.viewport.project(mid)
	_click(ws, on_path)
	await _frames(tree, 1)
	_check(failures, str(editor.tool_values.get("sections", "0")) == "1" and absf(float(str(editor.tool_values.get("s1_pos", "0"))) - 0.5) < 0.05,
		"Add Section and a click at the path's middle should add a section there (%s at %s)." % [editor.tool_values.get("sections"), editor.tool_values.get("s1_pos")])
	_set_values(ws, {"s1_dia": "12 mm"})
	await _shot(ws, tree, "create_dark_pipe.png", (ids.pipe_origin as Vector3) + Vector3(0.012, 0.012, 0), 0.1)
	await _ok_one_step(ws, tree, failures, "Pipe", form.id, Vector3i(40, 72, 32))

	# Face: four clicks on the XY plane.
	editor.start_tool("face")
	await _frames(tree, 1)
	var corners := [Vector3(0.2, 0.05, 0.0), Vector3(0.22, 0.05, 0.0), Vector3(0.22, 0.07, 0.0), Vector3(0.2, 0.07, 0.0)]
	for corner in corners:
		var at: Vector2 = ws.viewport.project(corner)
		ws.viewport._overlay_input(_motion(at))
		_click(ws, at)
		await _frames(tree, 1)
	var placed: Array = editor.tool_picks.get("corners", [])
	var off := 0.0
	for i in mini(placed.size(), 4):
		off = maxf(off, (placed[i].point as Vector3).distance_to(corners[i]))
	await _shot(ws, tree, "create_dark_face.png", Vector3(0.21, 0.06, 0), 0.08)
	_check(failures, placed.size() == 4 and off < 1e-4, "Four clicks should place four corners on the XY plane (%d, off by %s m)." % [placed.size(), off])
	await _ok_one_step(ws, tree, failures, "Face", form.id, Vector3i(4, 4, 1))
	_check(failures, editor.tool == "face", "Face repeats: after OK it waits for the next face.")
	editor.cancel_tool()
	if _shots() != "":
		await _shot(ws, tree, "create_dark_all.png", Vector3(0.03, -0.09, 0.03), 0.32)
		ws.set_theme_mode("light")
		await _shot(ws, tree, "create_light_all.png", Vector3(0.03, -0.09, 0.03), 0.32)
		editor.start_tool("pipe")
		ws._on_reference_picked({"kind": "sketch_curve", "sketch": ids.pipe_sketch, "entity": ids.pipe})
		_set_values(ws, {"diameter": "8 mm", "density": "4", "sections": "1", "s1_pos": "0.5", "s1_dia": "12 mm"})
		await _shot(ws, tree, "create_light_pipe.png", (ids.pipe_origin as Vector3) + Vector3(0.012, 0.012, 0), 0.1)
		editor.cancel_tool()
		ws.set_theme_mode("dark")
		await _frames(tree, 1)

	# Finish converts every body; then every step goes back.
	ws.run_action("finish_form")
	await _frames(tree, 3)
	var errors: Dictionary = ws.result.get("errors", {})
	_check(failures, not errors.has(form.id), "Finish Form should convert the created bodies (%s)." % [errors.get(form.id, "")])
	var converted := 0
	for body_id in _form_bodies(doc, form.id):
		if (ws.result.get("bodies", {}) as Dictionary).has(body_id):
			converted += 1
	_check(failures, converted == 6, "All 6 created bodies should convert (%d)." % converted)
	if history != null:
		while history.get_current_action() > start_action:
			history.undo()
		await _frames(tree, 2)
		_check(failures, doc.find_feature(form.id) == null and not editor.active, "Undoing the checks' steps should leave the document as it was.")
	ws.viewport.set_view_state(saved_view)
	await _frames(tree, 1)
	return failures


## The form's body ids (cage bodies and converted ones).
static func _form_bodies(doc: Resource, form_id: String) -> Array:
	var f: Resource = doc.find_feature(form_id)
	if f == null:
		return []
	return (f.options.get("bodies", {}) as Dictionary).keys() + (f.options.get("breps", {}) as Dictionary).keys()


## OK as one undo step "Form: <title>" adding one body with the given counts.
static func _ok_one_step(ws, tree: SceneTree, failures: Array, title: String, form_id: String, counts: Vector3i) -> void:
	var history: UndoRedo = ws.history()
	var before := history.get_current_action() if history != null else 0
	var f: Resource = ws.doc.find_feature(form_id)
	var known: Array = (f.options.bodies as Dictionary).keys() if f != null else []
	ws.accept_command()
	await _frames(tree, 2)
	f = ws.doc.find_feature(form_id)
	if f == null:
		failures.append("%s: the form went away." % title)
		return
	var added := []
	for body_id in (f.options.bodies as Dictionary):
		if not known.has(body_id):
			added.append(body_id)
	_check(failures, history == null or history.get_current_action() == before + 1, "%s's OK should be one undo step." % title)
	_check(failures, str(ws.last_step.get("name", "")) == "Form: " + title, "The step should be named Form: %s (%s)." % [title, ws.last_step.get("name", "")])
	_check(failures, added.size() == 1, "%s should add one body (%d; %s)." % [title, added.size(), ws.last_message])
	if added.size() == 1:
		var cage: Dictionary = f.options.bodies[added[0]]
		var got := Vector3i(CAGE.vertex_count(cage), CAGE.topology(cage).nE, CAGE.face_count(cage))
		_check(failures, got == counts, "%s's cage should be V/E/F %d/%d/%d (got %d/%d/%d)." % [title, counts.x, counts.y, counts.z, got.x, got.y, got.z])
		_check(failures, CAGE.validate(cage).is_empty(), "%s's cage should be valid (%s)." % [title, CAGE.validate(cage)])
		_check(failures, (ws.viewport.form_meshes() as Dictionary).has(str(added[0]) + "/surface"), "%s's body should be drawn." % title)


static func _add_sketches(doc: Resource, ids: Dictionary) -> void:
	var circle: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options({"origin": BASE, "x": Vector3.RIGHT, "y": Vector3.UP}, "frame"))
	var s = SKETCH_DATA.new(circle, doc)
	s.add_circle(s.add_point(Vector2.ZERO), 10 * MM)
	ids["circle_sketch"] = circle.id
	# A half circle on a vertical plane through x = 0.1 m with its axis line (a construction line).
	var arc: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options({"origin": BASE + Vector3(0.1, 0, 0), "x": Vector3.RIGHT, "y": Vector3.UP}, "frame"))
	s = SKETCH_DATA.new(arc, doc)
	var centre: int = s.add_point(Vector2.ZERO)
	var bottom: int = s.add_point(Vector2(0, -10) * MM)
	var top: int = s.add_point(Vector2(0, 10) * MM)
	ids["arc"] = s.add_arc(centre, bottom, top)
	ids["axis"] = s.add_line(s.add_point(Vector2(0, -14) * MM), s.add_point(Vector2(0, 14) * MM), true)
	ids["arc_sketch"] = arc.id
	# The sweep path: 30 mm along +Z from the circle's centre.
	var path: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options({"origin": BASE, "x": Vector3.FORWARD, "y": Vector3.UP}, "frame"))
	s = SKETCH_DATA.new(path, doc)
	ids["path"] = s.add_line(s.add_point(Vector2.ZERO), s.add_point(Vector2(-30, 0) * MM))
	ids["path_sketch"] = path.id
	# Three loft circles at x = -0.1 m.
	var k := 0
	for spec in [[0.04, 8.0], [0.06, 12.0], [0.08, 6.0]]:
		var loft: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options({"origin": BASE + Vector3(-0.1, 0, spec[0]), "x": Vector3.RIGHT, "y": Vector3.UP}, "frame"))
		var ls = SKETCH_DATA.new(loft, doc)
		ls.add_circle(ls.add_point(Vector2.ZERO), spec[1] * MM)
		ids["loft%d" % k] = loft.id
		k += 1
	# The pipe's quarter circle (r 25 mm).
	var pipe_origin := BASE + Vector3(0.1, -0.07, 0.0)
	var pipe: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options({"origin": pipe_origin, "x": Vector3.RIGHT, "y": Vector3.UP}, "frame"))
	s = SKETCH_DATA.new(pipe, doc)
	ids["pipe"] = s.add_arc(s.add_point(Vector2.ZERO), s.add_point(Vector2(25, 0) * MM), s.add_point(Vector2(0, 25) * MM))
	ids["pipe_sketch"] = pipe.id
	ids["pipe_origin"] = pipe_origin


## The screenshot folder (--holo-forge-screenshots=<dir>, windowed editors only), or "".
static func _shots() -> String:
	if DisplayServer.get_name() == "headless":
		return ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(SHOTS_ARG):
			return arg.trim_prefix(SHOTS_ARG)
	return ""


## Saves the Forge view (the 3D view with its overlay and panels) as a PNG.
static func _shot(ws, tree: SceneTree, file: String, target := Vector3.INF, distance := 0.0) -> void:
	var dir := _shots()
	if dir == "":
		return
	# A closer look for the picture, then the view as it was.
	var view: Dictionary = ws.viewport.view_state()
	if target.is_finite():
		ws.viewport.set_view_state({"target": target, "distance": distance})
	await _frames(tree, 3)
	ws.viewport.redraw_overlay()
	await RenderingServer.frame_post_draw
	var window: Window = ws.get_window()
	var image := window.get_texture().get_image()
	var rect := Rect2i(ws.viewport.get_global_rect()).intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	image.get_region(rect).save_png(dir.path_join(file))
	print("Forge FORM create checks: saved ", dir.path_join(file))
	ws.viewport.set_view_state(view)


static func _check(failures: Array, ok: bool, detail: String) -> void:
	if not ok:
		failures.append(detail)
		print("FAIL: ", detail)


static func _frames(tree: SceneTree, count: int) -> void:
	for i in count:
		await tree.process_frame


static func _set_values(ws, values: Dictionary) -> void:
	var merged: Dictionary = ws.form_editor.tool_values.duplicate(true)
	merged.merge(values, true)
	ws.panel.set_values(merged)
	ws._on_panel_values_changed(merged)


static func _button(at: Vector2, pressed: bool) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = at
	event.global_position = at
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	return event


static func _motion(at: Vector2) -> InputEventMouseMotion:
	var event := InputEventMouseMotion.new()
	event.position = at
	event.global_position = at
	return event


static func _click(ws, at: Vector2) -> void:
	ws.viewport._overlay_input(_motion(at))
	ws.viewport._overlay_input(_button(at, true))
	ws.viewport._overlay_input(_button(at, false))
