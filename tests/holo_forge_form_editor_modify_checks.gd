@tool
extends RefCounted
## In-editor checks for the Form modify, symmetry and utility tools (Stage 3, team M2), run by the
## Form editor hook (tests/holo_forge_form_editor_test.gd) with the open Forge workspace: one
## scenario per tool, each started through the form editor's tool engine (start_tool, the panel
## values, tool_ok) on a fresh body, asserting its counts and exactly one undo step named
## "Form: <Title>", then undone. Also checks the view hooks (Insert Point's midpoint snap, the slot
## clicks and sliders). With --holo-forge-screenshots=<dir>, saves tool previews in both themes.
## Returns failure strings ([] when all pass).

const CAGE := preload("res://addons/holo_forge/core/form/cage.gd")
const FORM_OPS := preload("res://addons/holo_forge/core/form/form_ops.gd")
const PRIMITIVES := preload("res://addons/holo_forge/core/form/primitives.gd")
const MODIFY := preload("res://addons/holo_forge/ui/form_tools_modify.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const SKETCH_DATA := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const SHOTS_ARG := "--holo-forge-screenshots="
const S := 0.02


static func run(ws) -> Array:
	var c := Checks.new(ws)
	await c.all()
	return c.fails


class Checks:
	extends RefCounted
	var ws
	var editor
	var doc: Resource
	var fails: Array = []
	var notes: Array = []
	var shots := ""
	var box_body := ""
	var sketch_id := ""
	var line_entity := -1
	var form_id := ""

	func _init(p_ws) -> void:
		ws = p_ws
		editor = ws.form_editor
		doc = ws.doc
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with(SHOTS_ARG):
				shots = arg.trim_prefix(SHOTS_ARG)
		if DisplayServer.get_name() == "headless":
			shots = ""

	func check(ok: bool, detail: String) -> void:
		if not ok:
			fails.append("Form modify checks: " + detail)
			print("FAIL: Form modify checks: ", detail)

	func frames(n := 1) -> void:
		for i in n:
			await ws.get_tree().process_frame

	func all() -> void:
		if ws == null or doc == null or not ClassDB.class_exists("CadSubD"):
			check(false, "The Forge workspace with the native kernel is needed.")
			return
		if editor.active:
			ws.run_action("finish_form")
			await frames(2)
		_setup_model()
		var f: Resource = ws.create_form()
		await frames(1)
		if f == null or not editor.active:
			check(false, "A form should open for the modify checks.")
			return
		form_id = f.id
		ws.viewport.fit()
		await frames(1)
		await _insert_edge()
		await _subdivide()
		await _insert_point()
		await _merge_edge()
		await _bridge()
		await _fill_hole()
		await _erase_and_fill()
		await _weld_vertices()
		await _unweld_edges()
		await _bevel_edge()
		await _slide_edge()
		await _smooth()
		await _cylindrify()
		await _pull()
		await _flatten()
		await _straighten()
		await _match()
		await _interpolate()
		await _thicken()
		await _mirror_internal()
		await _circular_internal()
		await _mirror_duplicate()
		await _circular_duplicate()
		await _isolate_symmetry()
		await _repair_body()
		await _make_uniform()
		await _convert()
		await _edit_by_curve()
		if shots != "":
			await _shots()
		editor.cancel_tool()
		ws.run_action("finish_form")
		await frames(2)
		check(not editor.active, "Finish Form should close the form after the modify checks.")
		print("Forge FORM modify checks: %d tools, %s" % [28, ", ".join(notes)])

	# --- Setup -----------------------------------------------------------------------------------

	## A box feature (top face at y = 0) and an XY sketch with a line, both before the form.
	func _setup_model() -> void:
		var ids := ["", "", -1]
		ws.change("Modify Checks Model", func() -> void:
			var inputs := {"length": doc.make_input("60 mm", "length"), "height": doc.make_input("10 mm", "length"), "width": doc.make_input("60 mm", "length")}
			var box: Resource = doc.add_feature("box", "Box", inputs, {"position": Vector3(0.0, -0.01, 0.0), "operation": OPERATIONS.NEW_BODY})
			box.options["body_id"] = doc.new_body(box.id)
			ids[0] = str(box.options.body_id)
			var sketch: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options(SKETCH_DATA.ORIGIN_PLANES.xy, "xy"))
			var s = SKETCH_DATA.new(sketch, doc)
			var a: int = s.add_point(Vector2(0.10, -0.02))
			var b: int = s.add_point(Vector2(0.18, -0.02))
			ids[2] = s.add_line(a, b)
			ids[1] = sketch.id)
		box_body = str(ids[0])
		sketch_id = str(ids[1])
		line_entity = int(ids[2])

	# --- Helpers ---------------------------------------------------------------------------------

	func _feature() -> Resource:
		return doc.find_feature(form_id)

	func _cage(body_id: String) -> Dictionary:
		var f := _feature()
		return (f.options.bodies as Dictionary).get(body_id, {}) if f != null else {}

	func _vef(c: Dictionary) -> String:
		if c.is_empty():
			return "-"
		return "%d/%d/%d" % [CAGE.vertex_count(c), CAGE.topology(c).nE, CAGE.face_count(c)]

	## Adds a cage body as one step; returns its id.
	func _add(cage: Dictionary) -> String:
		var ids := []
		var fid := form_id
		ws.change("Form: Test Body", func() -> void: editor.apply_result(fid, {"cages": {}, "new_bodies": [cage]}, ids))
		await frames(1)
		return str(ids[0]) if not ids.is_empty() else ""

	## A left drag in the view from a to b, through the viewport's input (press, motions, release).
	func _drag(a: Vector2, b: Vector2) -> void:
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = a
		press.global_position = a
		press.button_mask = MOUSE_BUTTON_MASK_LEFT
		ws.viewport._overlay_input(press)
		for i in range(1, 7):
			var motion := InputEventMouseMotion.new()
			motion.position = a.lerp(b, i / 6.0)
			motion.global_position = motion.position
			motion.button_mask = MOUSE_BUTTON_MASK_LEFT
			ws.viewport._overlay_input(motion)
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.pressed = false
		release.position = b
		release.global_position = b
		ws.viewport._overlay_input(release)
		await frames(1)

	func _select(items: Array) -> void:
		editor.selection.clear()
		for item in items:
			editor.selection.append(item)
		editor._selection_changed()

	func _edge(body: String, a: int, b: int) -> Dictionary:
		return {"kind": "edge", "body": body, "index": -1, "pair": Vector2i(mini(a, b), maxi(a, b))}

	func _face(body: String, f: int) -> Dictionary:
		return {"kind": "face", "body": body, "index": f, "pair": Vector2i(-1, -1)}

	func _vertex(body: String, v: int) -> Dictionary:
		return {"kind": "vertex", "body": body, "index": v, "pair": Vector2i(-1, -1)}

	func _body(body: String) -> Dictionary:
		return {"kind": "body", "body": body, "index": -1, "pair": Vector2i(-1, -1)}

	func _loop_items(body: String, c: Dictionary, pred: Callable) -> Array:
		var topo := CAGE.topology(c)
		for e in topo.nE:
			var ab := topo.edge_vertices(e)
			if pred.call(CAGE.position(c, ab.x), CAGE.position(c, ab.y)):
				var out := []
				for x in topo.edge_loop(e):
					var xy := topo.edge_vertices(x)
					out.append(_edge(body, xy.x, xy.y))
				return out
		return []

	func _boundary_items(body: String, c: Dictionary, pred: Callable) -> Array:
		for loop in CAGE.topology(c).boundary_loops():
			var lp: PackedInt32Array = loop
			if pred.call(CAGE.position(c, lp[0])):
				var out := []
				for k in lp.size():
					out.append(_edge(body, lp[k], lp[(k + 1) % lp.size()]))
				return out
		return []

	func _moved(c: Dictionary, x: float, y: float, z: float) -> Dictionary:
		var all := PackedInt32Array()
		for v in CAGE.vertex_count(c):
			all.append(v)
		return FORM_OPS.transform_vertices(c, all, PackedFloat32Array(), FORM_OPS.xf_translation(x, y, z)).cage

	## Starts a tool on a selection with panel values, presses OK and checks the step; returns the
	## body's cage after OK. Leaves the step in place (call _undo after the scenario's checks).
	func _apply(id: String, title: String, items: Array, values := {}) -> Dictionary:
		_select(items)
		editor.start_tool(id)
		await frames(1)
		check(editor.tool == id, "%s should start (tool '%s')." % [title, editor.tool])
		if not values.is_empty():
			editor.set_tool_values(values)
		var history: UndoRedo = ws.history()
		var before := history.get_current_action()
		var preview_error := str(editor.get("_last_preview_error"))
		var spec_preview := bool(MODIFY.TOOLS[id].get("preview", false))
		check(not spec_preview or preview_error == "", "%s should preview without an error (%s)." % [title, preview_error])
		editor.tool_ok()
		await frames(1)
		check(history.get_current_action() == before + 1, "%s's OK should be exactly one undo step (%d -> %d; %s)." % [title, before, history.get_current_action(), ws.last_message])
		check(str(ws.last_step.get("name", "")) == "Form: " + title, "%s's step should be named Form: %s (%s)." % [title, title, ws.last_step.get("name", "")])
		editor.cancel_tool()
		return {}

	## Before a scenario: the form is open (a new one when an earlier scenario lost it); returns the
	## history position to go back to.
	func _begin() -> int:
		editor.cancel_tool()
		if not editor.active or doc.find_feature(form_id) == null:
			var f: Resource = ws.create_form()
			await frames(1)
			form_id = f.id if f != null else ""
		return ws.history().get_current_action()

	## After a scenario: undoes back to mark.
	func _undo_to(mark: int) -> void:
		editor.cancel_tool()
		var history: UndoRedo = ws.history()
		var guard := 64
		while history.get_current_action() > mark and guard > 0:
			guard -= 1
			history.undo()
		await frames(1)

	# --- Scenarios -------------------------------------------------------------------------------

	func _insert_edge() -> void:
		var mark: int = await _begin()
		var cage := PRIMITIVES.box(Vector3.ONE * S, Vector3i(2, 2, 2))
		var b: String = await _add(cage)
		var loop := _loop_items(b, cage, func(p: Vector3, q: Vector3) -> bool: return absf(p.z) < 1e-9 and absf(q.z) < 1e-9)
		_select(loop)
		editor.start_tool("insert_edge")
		await frames(1)
		var sliders: Array = MODIFY.sliders(editor)
		check(sliders.size() == 1 and str(sliders[0].key) == "location", "Insert Edge should offer a location slider on its rail (%s)." % [sliders])
		# The slider is an editor handle (spec "handles"): drawn by the editor and dragged through
		# its mouse handling, the knob following the drag along the rail within min..max.
		var slider := {}
		for h in editor.get("_handles"):
			if str((h as Dictionary).get("type", "")) == "slider" and str(h.key) == "location":
				slider = h
		check(not slider.is_empty(), "Insert Edge's slider should be one of the editor's handles (%s)." % [editor.get("_handles")])
		if not slider.is_empty():
			var shape: Dictionary = editor._handle_shape(slider)
			check(not shape.is_empty(), "Insert Edge's slider should be on screen.")
			if not shape.is_empty():
				await _drag(shape.at, (shape.from as Vector2).lerp(shape.to, 0.9))
				var moved := float(str(editor.tool_values.get("location", "0")))
				check(moved > 0.6 and moved <= 0.98, "Dragging Insert Edge's knob towards the far end should raise its location within 0.98 (%s)." % moved)
				await _drag(editor._handle_shape(slider).at, (shape.from as Vector2).lerp(shape.to, -0.5))
				moved = float(str(editor.tool_values.get("location", "0")))
				check(absf(moved - 0.02) < 1e-9, "Dragging the knob past the near end should stop at 0.02 (%s)." % moved)
		# Panel text a tool reports through its result (not by reaching into the panel).
		check(str(ws.panel.info("result")).begins_with("New edges"), "Insert Edge's note should reach the panel through its result (%s)." % ws.panel.info("result"))
		editor.cancel_tool()
		await _apply("insert_edge", "Insert Edge", loop)
		check(_vef(_cage(b)) == "34/64/32", "Insert Edge on the equator should give 34/64/32 (%s)." % _vef(_cage(b)))
		await _undo_to(mark)
		notes.append("insert edge")

	func _subdivide() -> void:
		var mark: int = await _begin()
		var b: String = await _add(PRIMITIVES.box(Vector3.ONE * S, Vector3i.ONE))
		await _apply("subdivide", "Subdivide", [_face(b, 0)])
		check(_vef(_cage(b)) == "13/20/9", "Subdivide one face should give 13/20/9 (%s)." % _vef(_cage(b)))
		await _undo_to(mark)
		notes.append("subdivide")

	func _insert_point() -> void:
		var mark: int = await _begin()
		var cube := PRIMITIVES.box(Vector3.ONE * S, Vector3i.ONE)
		var b: String = await _add(cube)
		editor.set_display("frame", [b])
		await frames(1)
		_select([])
		editor.start_tool("insert_point")
		await frames(1)
		# A click right at an edge's middle snaps to t = 0.5.
		var topo := CAGE.topology(cube)
		var cam: Vector3 = ws.viewport.camera_position()
		var snapped := false
		for e in topo.nE:
			var ab := topo.edge_vertices(e)
			var mid := (CAGE.position(cube, ab.x) + CAGE.position(cube, ab.y)) * 0.5
			var faces := topo.edge_faces(e)
			var facing := false
			for f in faces:
				if topo.face_normal(cube, f).dot(cam - mid) > 0.0:
					facing = true
			if not facing:
				continue
			var hit: Dictionary = MODIFY.edge_point(editor, ws.viewport.project(mid))
			if not hit.is_empty() and (hit.point as Dictionary).has("edge") and absf(float(hit.point.t) - 0.5) < 1e-9:
				snapped = true
				break
		check(snapped, "A click at a visible edge's middle should snap to t = 0.5.")
		var f0 := CAGE.face_vertices(cube, 0)
		editor.set_tool_values({"points": [{"edge": Vector2i(f0[0], f0[1]), "t": 0.5}, {"edge": Vector2i(f0[2], f0[3]), "t": 0.5}], "points_body": b})
		var history: UndoRedo = ws.history()
		var before := history.get_current_action()
		editor.tool_ok()
		await frames(1)
		check(history.get_current_action() == before + 1 and str(ws.last_step.get("name", "")) == "Form: Insert Point", "Insert Point should be one step (%s)." % ws.last_step.get("name", ""))
		check(_vef(_cage(b)) == "10/15/7", "Insert Point across a face should give 10/15/7 (%s)." % _vef(_cage(b)))
		check(editor.tool == "insert_point" and (editor.tool_values.get("points", []) as Array).is_empty(), "Insert Point should restart with no points (repeat).")
		editor.cancel_tool()
		editor.set_display("smooth", [b])
		await _undo_to(mark)
		notes.append("insert point (midpoint snap, repeat)")

	func _merge_edge() -> void:
		var mark: int = await _begin()
		var p1 := PRIMITIVES.plane(Vector2.ONE * S, Vector2i.ONE)
		var p2 := _moved(p1, 1.4 * S, 0.0, 0.0)
		var b1: String = await _add(p1)
		var b2: String = await _add(p2)
		var right := _boundary_side(p1, func(p: Vector3) -> bool: return p.x > 0.4 * S)
		var left := _boundary_side(p2, func(p: Vector3) -> bool: return p.x < 1.0 * S)
		# The preview draws the merged body once: the body the result removes leaves the view.
		_select([_edge(b1, right.x, right.y)])
		editor.start_tool("merge_edge")
		editor.set_tool_values({"edges2": [_edge(b2, left.x, left.y)]})
		await frames(1)
		var shown := []
		for item in editor._shown_bodies():
			shown.append(str(item.id))
		check(not shown.has(b1) and shown.has(b2), "Merge Edge's preview should draw the joined body once (shown %s, removed %s)." % [shown, b1])
		editor.cancel_tool()
		await _apply("merge_edge", "Merge Edge", [_edge(b1, right.x, right.y)], {"edges2": [_edge(b2, left.x, left.y)]})
		var f := _feature()
		check(_vef(_cage(b2)) == "6/7/2" and not (f.options.bodies as Dictionary).has(b1) and not doc.bodies.has(b1),
			"Merge Edge should weld the planes into one 6/7/2 body (%s; bodies %s)." % [_vef(_cage(b2)), (f.options.bodies as Dictionary).keys()])
		await _undo_to(mark)
		check((_feature().options.bodies as Dictionary).has(b1) == false, "Undo should take the test bodies away again.")
		notes.append("merge edge across bodies")

	## The boundary edge of a plane whose both ends pass pred (as a vertex pair).
	func _boundary_side(c: Dictionary, pred: Callable) -> Vector2i:
		var topo := CAGE.topology(c)
		for e in topo.nE:
			var ab := topo.edge_vertices(e)
			if topo.is_boundary_edge(e) and pred.call(CAGE.position(c, ab.x)) and pred.call(CAGE.position(c, ab.y)):
				return ab
		return Vector2i(-1, -1)

	func _bridge() -> void:
		var mark: int = await _begin()
		var tube := PRIMITIVES.cylinder(S, S, 8, 1, "open")
		var b: String = await _add(tube)
		var bottom := _boundary_items(b, tube, func(p: Vector3) -> bool: return p.z < 0.5 * S)
		var top := _boundary_items(b, tube, func(p: Vector3) -> bool: return p.z > 0.5 * S)
		await _apply("bridge", "Bridge", bottom, {"side2": top, "segments": "2"})
		check(_vef(_cage(b)) == "24/48/24", "Bridge of the cylinder's loops should give the 24/48/24 torus (%s)." % _vef(_cage(b)))
		await _undo_to(mark)
		notes.append("bridge")

	func _fill_hole() -> void:
		var mark: int = await _begin()
		var tube := PRIMITIVES.cylinder(S, S, 8, 2, "open")
		var b: String = await _add(tube)
		var hole := _boundary_items(b, tube, func(p: Vector3) -> bool: return p.z < 0.5 * S)
		await _apply("fill_hole", "Fill Hole", [hole[0]], {"mode": "star"})
		check(_vef(_cage(b)) == "24/40/17", "Fill Star should give 24/40/17 (%s)." % _vef(_cage(b)))
		await _undo_to(mark)
		notes.append("fill hole")

	func _erase_and_fill() -> void:
		var mark: int = await _begin()
		var b: String = await _add(PRIMITIVES.box(Vector3.ONE * S, Vector3i(2, 2, 2)))
		await _apply("erase_and_fill", "Erase and Fill", [_face(b, 0)])
		check(_vef(_cage(b)) == "26/48/24", "Erase and Fill of one face should give 26/48/24 (%s)." % _vef(_cage(b)))
		await _undo_to(mark)
		notes.append("erase and fill")

	func _weld_vertices() -> void:
		var mark: int = await _begin()
		var p1 := PRIMITIVES.plane(Vector2.ONE * S, Vector2i.ONE)
		var pair: Dictionary = CAGE.append(p1, _moved(p1, S, 0.0, 0.0)).cage
		var b: String = await _add(pair)
		# Weld Vertices forces select-through on while it runs (spec 3.3.10), then puts it back.
		for before in [false, true]:
			ws.viewport.select_through = before
			editor.start_tool("weld_vertices")
			await frames(1)
			check(ws.viewport.select_through, "Weld Vertices should turn select-through on while it runs (was %s)." % before)
			editor.cancel_tool()
			check(ws.viewport.select_through == before, "Select-through should be back to %s after Weld Vertices." % before)
		ws.viewport.select_through = false
		await _apply("weld_vertices", "Weld Vertices", [_body(b)], {"mode": "tolerance", "tolerance": "0.001 mm"})
		check(_vef(_cage(b)) == "6/7/2", "Weld to Tolerance should give 6/7/2 (%s)." % _vef(_cage(b)))
		await _undo_to(mark)
		notes.append("weld vertices")

	func _unweld_edges() -> void:
		var mark: int = await _begin()
		var tube := PRIMITIVES.cylinder(S, S, 8, 2, "open")
		var b: String = await _add(tube)
		var mid := _loop_items(b, tube, func(p: Vector3, q: Vector3) -> bool: return absf(p.z - 0.5 * S) < 1e-9 and absf(q.z - 0.5 * S) < 1e-9)
		await _apply("unweld_edges", "UnWeld Edges", mid)
		check(_vef(_cage(b)) == "32/48/16", "UnWeld of the middle loop should give 32/48/16 (%s)." % _vef(_cage(b)))
		await _undo_to(mark)
		notes.append("unweld")

	func _bevel_edge() -> void:
		var mark: int = await _begin()
		var cage := PRIMITIVES.box(Vector3.ONE * S, Vector3i(2, 2, 2))
		var b: String = await _add(cage)
		var loop := _loop_items(b, cage, func(p: Vector3, q: Vector3) -> bool: return absf(p.z) < 1e-9 and absf(q.z) < 1e-9)
		await _apply("bevel_edge", "Bevel Edge", loop, {"segments": "2"})
		check(_vef(_cage(b)) == "42/80/40", "Bevel with 2 segments should give 42/80/40 (%s)." % _vef(_cage(b)))
		await _undo_to(mark)
		notes.append("bevel")

	func _slide_edge() -> void:
		var mark: int = await _begin()
		var cage := PRIMITIVES.box(Vector3.ONE * S, Vector3i(2, 2, 2))
		var b: String = await _add(cage)
		var loop := _loop_items(b, cage, func(p: Vector3, q: Vector3) -> bool: return absf(p.z) < 1e-9 and absf(q.z) < 1e-9)
		await _apply("slide_edge", "Slide Edge", loop, {"slide": "0.5"})
		var c := _cage(b)
		var moved := 0
		for v in CAGE.vertex_count(cage):
			if not c.is_empty() and CAGE.position(c, v) != CAGE.position(cage, v):
				moved += 1
		check(_vef(c) == "26/48/24" and moved == 8, "Slide Edge should move the 8 loop vertices (%s, %d moved)." % [_vef(c), moved])
		await _undo_to(mark)
		notes.append("slide")

	func _smooth() -> void:
		var mark: int = await _begin()
		var bumpy := CAGE.copy(PRIMITIVES.plane(Vector2.ONE * 3.0 * S, Vector2i(3, 3)))
		var v0 := -1
		for v in CAGE.vertex_count(bumpy):
			var q := CAGE.position(bumpy, v)
			if absf(q.x - 0.5 * S) < 1e-9 and absf(q.y - 0.5 * S) < 1e-9:
				v0 = v
		CAGE.set_position_d(bumpy, v0, 0.5 * S, 0.5 * S, 0.6 * S)
		var b: String = await _add(bumpy)
		var faces := []
		for f in CAGE.face_count(bumpy):
			faces.append(_face(b, f))
		await _apply("smooth", "Smooth", faces)
		var c := _cage(b)
		check(not c.is_empty() and CAGE.position(c, v0).z < 0.6 * S * 0.6, "Smooth should pull the bump down (%s)." % [CAGE.position(c, v0) if not c.is_empty() else null])
		await _undo_to(mark)
		notes.append("smooth")

	func _cylindrify() -> void:
		var mark: int = await _begin()
		var tube := CAGE.copy(PRIMITIVES.cylinder(S, S, 8, 2, "open"))
		CAGE.set_position_d(tube, 0, CAGE.position_d(tube, 0)[0] * 1.2, CAGE.position_d(tube, 0)[1] * 1.2, CAGE.position_d(tube, 0)[2])
		var b: String = await _add(tube)
		var faces := []
		for f in CAGE.face_count(tube):
			faces.append(_face(b, f))
		await _apply("cylindrify", "Cylindrify", faces, {"auto_feature": false})
		check(_vef(_cage(b)) == "24/40/16" and CAGE.content_hash(_cage(b)) != CAGE.content_hash(tube), "Cylindrify should round the band (%s)." % _vef(_cage(b)))
		await _undo_to(mark)
		notes.append("cylindrify")

	func _pull() -> void:
		var mark: int = await _begin()
		# A 2x2 plane facing +Y just above the box's top face (y = 0).
		var plane := PRIMITIVES.plane(Vector2.ONE * S, Vector2i(2, 2))
		var all := PackedInt32Array()
		for v in CAGE.vertex_count(plane):
			all.append(v)
		plane = FORM_OPS.transform_vertices(plane, all, PackedFloat32Array(), FORM_OPS.xf_from(Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)), Vector3(0, 0.003, 0))).cage
		var b: String = await _add(plane)
		check(ws.result.get("bodies", {}).has(box_body), "The model box should be in the preview for Pull (%s)." % [ws.result.get("bodies", {}).keys()])
		await _apply("pull", "Pull", [_body(b)], {"target": "select", "target_bodies": [box_body]})
		var c := _cage(b)
		var worst := 0.0
		for v in CAGE.vertex_count(c):
			worst = maxf(worst, absf(CAGE.position_d(c, v)[1]))
		check(not c.is_empty() and worst <= 1e-9, "Pull should put the vertices on the box's top face (%s)." % worst)
		await _undo_to(mark)
		notes.append("pull onto the model box")

	func _flatten() -> void:
		var mark: int = await _begin()
		var bumpy := CAGE.copy(PRIMITIVES.plane(Vector2.ONE * 2.0 * S, Vector2i(2, 2)))
		for v in CAGE.vertex_count(bumpy):
			var q := CAGE.position_d(bumpy, v)
			CAGE.set_position_d(bumpy, v, q[0], q[1], 0.002 + 0.001 * v)
		var b: String = await _add(bumpy)
		await _apply("flatten", "Flatten", [_body(b)], {"direction": "plane", "plane": [{"kind": "origin", "name": "xy"}]})
		var c := _cage(b)
		var worst := 0.0
		for v in CAGE.vertex_count(c):
			worst = maxf(worst, absf(CAGE.position_d(c, v)[2]))
		check(not c.is_empty() and worst <= 1e-12, "Flatten onto the XY plane should leave z = 0 (%s)." % worst)
		await _undo_to(mark)
		notes.append("flatten")

	func _straighten() -> void:
		var mark: int = await _begin()
		var bumpy := CAGE.copy(PRIMITIVES.plane(Vector2.ONE * 2.0 * S, Vector2i(2, 2)))
		var row := []
		for v in CAGE.vertex_count(bumpy):
			var q := CAGE.position_d(bumpy, v)
			if q[1] < -0.5 * S:
				CAGE.set_position_d(bumpy, v, q[0], q[1], 0.001 * v)
		var b: String = await _add(bumpy)
		for v in CAGE.vertex_count(bumpy):
			if CAGE.position(bumpy, v).y < -0.5 * S:
				row.append(_vertex(b, v))
		await _apply("straighten", "Straighten", row)
		var c := _cage(b)
		var pts := PackedFloat64Array()
		for item in row:
			pts.append_array(CAGE.position_d(c, int(item.index)))
		var line := FORM_OPS.best_fit_line(pts)
		var off := 0.0
		for item in row:
			var q := CAGE.position_d(c, int(item.index))
			var o: PackedFloat64Array = line.origin
			var d: PackedFloat64Array = line.direction
			var t := (q[0] - o[0]) * d[0] + (q[1] - o[1]) * d[1] + (q[2] - o[2]) * d[2]
			off = maxf(off, Vector3(q[0] - o[0] - t * d[0], q[1] - o[1] - t * d[1], q[2] - o[2] - t * d[2]).length())
		check(not c.is_empty() and off <= 1e-12, "Straighten should line the row up (%s)." % off)
		await _undo_to(mark)
		notes.append("straighten")

	func _match() -> void:
		var mark: int = await _begin()
		# A strip whose lower side matches the sketch line at y = -0.02 (x 0.10 .. 0.18).
		var strip := _moved(PRIMITIVES.plane(Vector2(4.0 * S, S), Vector2i(4, 1)), 0.14, -0.012, 0.0)
		var b: String = await _add(strip)
		var topo := CAGE.topology(strip)
		var chain := []
		for e in topo.nE:
			var ab := topo.edge_vertices(e)
			if CAGE.position(strip, ab.x).y < -0.0215 and CAGE.position(strip, ab.y).y < -0.0215:
				chain.append(_edge(b, ab.x, ab.y))
		var ref := {"kind": "sketch_curve", "sketch": sketch_id, "entity": line_entity}
		# A panel button reaches the tool exactly once (the editor hands it to button_match).
		_select(chain)
		editor.start_tool("match")
		editor.set_tool_values({"target": [ref]})
		await frames(1)
		var reverse := bool(editor.tool_values.get("reverse", false))
		ws.panel.button_pressed.emit("alternate")
		check(bool(editor.tool_values.get("reverse", false)) == not reverse, "Match's Alternate Alignment should flip the alignment once per press (%s -> %s)." % [reverse, editor.tool_values.get("reverse")])
		editor.cancel_tool()
		await _apply("match", "Match", chain, {"target": [ref]})
		var c := _cage(b)
		var lp: PackedFloat64Array = editor.subd_of(b).limit_points().positions if editor.subd_of(b) != null else PackedFloat64Array()
		var worst := 0.0
		for item in chain:
			for v in [item.pair.x, item.pair.y]:
				worst = maxf(worst, absf(lp[3 * v + 1] + 0.02) + absf(lp[3 * v + 2]))
		check(chain.size() == 4 and not c.is_empty() and lp.size() > 0 and worst <= 1e-6, "Match G0 should put the boundary's limit on the sketch line (%s, %d edges)." % [worst, chain.size()])
		await _undo_to(mark)
		notes.append("match onto a sketch line")

	func _interpolate() -> void:
		var mark: int = await _begin()
		var sphere := PRIMITIVES.sphere(S, 8, 4)
		var b: String = await _add(sphere)
		await _apply("interpolate", "Interpolate", [_body(b)])
		var lp: PackedFloat64Array = editor.subd_of(b).limit_points().positions if editor.subd_of(b) != null else PackedFloat64Array()
		var worst := 0.0
		for v in CAGE.vertex_count(sphere):
			worst = maxf(worst, Vector3(lp[3 * v], lp[3 * v + 1], lp[3 * v + 2]).distance_to(CAGE.position(sphere, v)))
		check(_vef(_cage(b)) == "26/56/32" and worst <= 1e-8, "Interpolate should pass the limit through the old cage points (%s)." % worst)
		await _undo_to(mark)
		notes.append("interpolate")

	func _thicken() -> void:
		var mark: int = await _begin()
		var b: String = await _add(PRIMITIVES.plane(Vector2.ONE * S, Vector2i.ONE))
		await _apply("thicken", "Thicken", [_body(b)], {"thickness": "2 mm"})
		check(_vef(_cage(b)) == "8/12/6", "Thicken of a plane should give 8/12/6 (%s)." % _vef(_cage(b)))
		await _undo_to(mark)
		notes.append("thicken")

	func _mirror_internal() -> void:
		var mark: int = await _begin()
		var cage := PRIMITIVES.box(Vector3.ONE * S, Vector3i(2, 2, 2))
		var b: String = await _add(cage)
		var topo := CAGE.topology(cage)
		var px := -1
		var mx := -1
		for f in topo.nF:
			var n := topo.face_normal(cage, f)
			if n.x > 0.99 and px < 0:
				px = f
			if n.x < -0.99 and mx < 0:
				mx = f
		await _apply("mirror_internal", "Mirror - Internal", [_face(b, px), _face(b, mx)])
		var sym: Array = _cage(b).get("symmetry", [])
		check(sym.size() == 1 and str(sym[0].type) == "mirror", "Mirror - Internal should add a mirror (%s)." % [sym.size()])
		await _undo_to(mark)
		notes.append("mirror internal")

	func _circular_internal() -> void:
		var mark: int = await _begin()
		var b: String = await _add(PRIMITIVES.cylinder(S, S, 8, 2, "pole"))
		await _apply("circular_internal", "Circular - Internal", [_face(b, 0)])
		var sym: Array = _cage(b).get("symmetry", [])
		check(sym.size() == 1 and str(sym[0].type) == "circular", "Circular - Internal should add a circular symmetry (%s)." % [sym.size()])
		await _undo_to(mark)
		notes.append("circular internal")

	func _mirror_duplicate() -> void:
		var mark: int = await _begin()
		var b: String = await _add(_moved(PRIMITIVES.plane(Vector2.ONE * S, Vector2i.ONE), 0.5 * S, 0.0, 0.0))
		await _apply("mirror_duplicate", "Mirror - Duplicate", [_body(b)], {"plane": [{"kind": "origin", "name": "yz"}]})
		check(_vef(_cage(b)) == "6/7/2", "Mirror - Duplicate should give 6/7/2 (%s)." % _vef(_cage(b)))
		await _undo_to(mark)
		notes.append("mirror duplicate")

	func _circular_duplicate() -> void:
		var mark: int = await _begin()
		var b: String = await _add(_moved(PRIMITIVES.plane(Vector2.ONE * S, Vector2i.ONE), 3.0 * S, 0.0, 0.0))
		await _apply("circular_duplicate", "Circular - Duplicate", [_body(b)], {"axis": [{"kind": "origin", "name": "z"}], "weld": false})
		check(_vef(_cage(b)) == "16/16/4", "Circular - Duplicate should give 16/16/4 (%s)." % _vef(_cage(b)))
		await _undo_to(mark)
		notes.append("circular duplicate")

	func _isolate_symmetry() -> void:
		var mark: int = await _begin()
		var mirrored := PRIMITIVES.primitive_symmetry(PRIMITIVES.box(Vector3.ONE * S, Vector3i(2, 2, 2)), "mirror", Transform3D.IDENTITY, Vector3i(1, 0, 0), 0)
		var b: String = await _add(mirrored)
		await _apply("isolate_symmetry", "Isolate Symmetry", [_vertex(b, 0)])
		check((_cage(b).get("sym_isolated", PackedInt32Array()) as PackedInt32Array) == PackedInt32Array([0]), "Isolate Symmetry should isolate the vertex.")
		await _undo_to(mark)
		notes.append("isolate symmetry")

	func _repair_body() -> void:
		var mark: int = await _begin()
		var p1 := PRIMITIVES.plane(Vector2.ONE * S, Vector2i.ONE)
		var pair: Dictionary = CAGE.append(p1, _moved(p1, S, 0.0, 0.0)).cage
		var b: String = await _add(pair)
		_select([_body(b)])
		editor.start_tool("repair_body")
		await frames(1)
		var markers: Dictionary = editor.tool_state.get("repair_markers", {})
		check(markers.has(b), "Repair Body should keep its markers for drawing (%s)." % [markers.keys()])
		editor.cancel_tool()
		await _apply("repair_body", "Repair Body", [_body(b)])
		check(_vef(_cage(b)) == "6/7/2", "Repair should weld the coincident seam (%s)." % _vef(_cage(b)))
		await _undo_to(mark)
		notes.append("repair body")

	func _make_uniform() -> void:
		var mark: int = await _begin()
		var b: String = await _add(PRIMITIVES.cylinder(S, S, 8, 2, "pole"))
		await _apply("make_uniform", "Make Uniform", [_body(b)])
		var quads := true
		for n in (_cage(b).get("face_counts", PackedInt32Array()) as PackedInt32Array):
			quads = quads and n == 4
		check(quads and _vef(_cage(b)) == "114/224/112", "Make Uniform should leave only quads (%s)." % _vef(_cage(b)))
		await _undo_to(mark)
		notes.append("make uniform")

	func _convert() -> void:
		var mark: int = await _begin()
		var b: String = await _add(PRIMITIVES.box(Vector3.ONE * S, Vector3i.ONE))
		await _apply("convert", "Convert", [_body(b)])
		var f := _feature()
		check(not (f.options.bodies as Dictionary).has(b) and (f.options.breps as Dictionary).has(b) and ws.result.get("bodies", {}).has(b),
			"Convert should move the body into the form's B-reps, shown in the preview (%s)." % [(f.options.breps as Dictionary).keys()])
		await _undo_to(mark)
		mark = ws.history().get_current_action()
		# Face to Form on the model box's top face.
		var shape: RefCounted = ws.result.get("bodies", {}).get(box_body, {}).get("shape")
		var top := -1
		if shape != null:
			for i in shape.face_count():
				if (shape.face_info(i).normal as Vector3).y > 0.9:
					top = i
		var ref := REFERENCES.from_pick({"kind": "face", "body": box_body, "index": top, "point": Vector3.ZERO}, ws.result) if top >= 0 else {}
		var count := (_feature().options.bodies as Dictionary).size()
		await _apply("convert", "Convert", [], {"direction": "face_form", "faces": [ref]})
		check((_feature().options.bodies as Dictionary).size() == count + 1, "Face to Form should add a cage body (%d -> %d)." % [count, (_feature().options.bodies as Dictionary).size()])
		await _undo_to(mark)
		notes.append("convert (form to B-rep, face to form)")

	func _edit_by_curve() -> void:
		var mark: int = await _begin()
		var strip := PRIMITIVES.plane(Vector2(4.0 * S, S), Vector2i(4, 1))
		var b: String = await _add(strip)
		var topo := CAGE.topology(strip)
		var chain := []
		for e in topo.nE:
			var ab := topo.edge_vertices(e)
			if CAGE.position(strip, ab.x).y < -0.4 * S and CAGE.position(strip, ab.y).y < -0.4 * S:
				chain.append(_edge(b, ab.x, ab.y))
		await _apply("edit_by_curve", "Edit By Curve", chain, {"curve_offsets": [Vector3.ZERO, Vector3(0, 0, 0.004), Vector3.ZERO, Vector3.ZERO]})
		var c := _cage(b)
		var moved := 0
		for v in CAGE.vertex_count(strip):
			if not c.is_empty() and CAGE.position(c, v).z > 1e-6:
				moved += 1
		check(moved == 3, "Edit By Curve should lift the chain's inner vertices (%d moved)." % moved)
		# Picking another chain while the tool is open commits the first chain's edit as its own step
		# and starts the curve afresh.
		var upper := []
		for e in topo.nE:
			var ab := topo.edge_vertices(e)
			if CAGE.position(strip, ab.x).y > 0.4 * S and CAGE.position(strip, ab.y).y > 0.4 * S:
				upper.append(_edge(b, ab.x, ab.y))
		_select(chain)
		editor.start_tool("edit_by_curve")
		await frames(1)
		editor.set_tool_values({"curve_offsets": [Vector3.ZERO, Vector3.ZERO, Vector3(0, 0, -0.004), Vector3.ZERO]})
		var history: UndoRedo = ws.history()
		var before := history.get_current_action()
		_select(upper)
		await frames(2)
		var c2 := _cage(b)
		var lowered := 0
		for v in CAGE.vertex_count(strip):
			if not c2.is_empty() and CAGE.position(c2, v).z < CAGE.position(c, v).z - 1e-6:
				lowered += 1
		check(history.get_current_action() == before + 1 and str(ws.last_step.get("name", "")) == "Form: Edit By Curve" and lowered == 3,
			"Picking another chain should commit the first chain's edit as one step (%d -> %d, %s, %d lowered)." % [before, history.get_current_action(), ws.last_step.get("name", ""), lowered])
		check(editor.tool == "edit_by_curve" and (editor.tool_values.get("curve_offsets", []) as Array).is_empty(), "The curve should start afresh for the new chain.")
		editor.cancel_tool()
		await _undo_to(mark)
		notes.append("edit by curve (chain switch commits)")

	# --- Screenshots ------------------------------------------------------------------------------

	func _shot(file: String) -> void:
		await frames(3)
		ws.viewport.redraw_overlay()
		EditorInterface.get_base_control().queue_redraw()
		await RenderingServer.frame_post_draw
		var window: Window = EditorInterface.get_base_control().get_window()
		var image := window.get_texture().get_image()
		var rect := Rect2i(ws.viewport.get_global_rect()).intersection(Rect2i(Vector2i.ZERO, image.get_size()))
		image.get_region(rect).save_png(shots.path_join(file))
		print("Forge FORM: saved ", shots.path_join(file))

	## Tool previews in both themes: Insert Edge (its slider), Bridge (Side Two), Edit By Curve (the
	## curve), Repair Body (its markers).
	func _shots() -> void:
		DirAccess.make_dir_recursive_absolute(shots)
		var view: Dictionary = ws.viewport.view_state()
		for theme in ["dark", "light"]:
			ws.set_theme_mode(theme)
			await frames(1)
			var mark: int = await _begin()
			# The shot body stands apart from the model, framed close (indices as in the unmoved box).
			var box := PRIMITIVES.box(Vector3.ONE * S, Vector3i(2, 2, 2))
			var at := Vector3(0.12, 0.05, 0.0)
			var b: String = await _add(_moved(box, at.x, at.y, at.z))
			ws.viewport.set_view_state({"target": at, "distance": 0.075})
			await frames(1)
			var loop := _loop_items(b, box, func(p: Vector3, q: Vector3) -> bool: return absf(p.z) < 1e-9 and absf(q.z) < 1e-9)
			_select(loop)
			editor.start_tool("insert_edge")
			editor.set_tool_values({"location": "0.3", "mode": "exact"})
			await _shot("modify_%s_insert_edge.png" % theme)
			editor.cancel_tool()
			var topo := CAGE.topology(box)
			var strip := []
			for e in topo.nE:
				var ab := topo.edge_vertices(e)
				var p := CAGE.position(box, ab.x)
				var q := CAGE.position(box, ab.y)
				if absf(p.z - 0.5 * S) < 1e-9 and absf(q.z - 0.5 * S) < 1e-9 and absf(p.y + 0.5 * S) < 1e-9 and absf(q.y + 0.5 * S) < 1e-9:
					strip.append(_edge(b, ab.x, ab.y))
			_select(strip)
			editor.start_tool("edit_by_curve")
			editor.set_tool_values({"fit": "surface", "curve_offsets": [Vector3.ZERO, Vector3(0, 0.004, 0.006), Vector3.ZERO], "curve_selected": [1]})
			await _shot("modify_%s_edit_by_curve.png" % theme)
			editor.cancel_tool()
			_select([_body(b)])
			editor.start_tool("repair_body")
			editor.set_tool_values({"mode": "report"})
			await _shot("modify_%s_repair.png" % theme)
			editor.cancel_tool()
			var top := []
			var bottom := []
			for f in topo.nF:
				var n := topo.face_normal(box, f)
				if n.x > 0.99:
					top.append(_face(b, f))
				elif n.x < -0.99:
					bottom.append(_face(b, f))
			_select(top)
			editor.start_tool("bridge")
			editor.set_tool_values({"side2": bottom, "segments": "3"})
			await _shot("modify_%s_bridge.png" % theme)
			editor.cancel_tool()
			await _undo_to(mark)
		ws.viewport.set_view_state(view)
		ws.set_theme_mode("dark")
		await frames(1)
