@tool
extends RefCounted
## In-editor regression checks for the Phase 6 review findings, run by the Form editor hook
## (tests/holo_forge_form_editor_test.gd) with the open Forge workspace: window selection leaves
## hidden back faces and edges out, a crossing box inside a face takes it, hover and drags with a
## whole body selected stay fast, the Rectangular soft extent is measured in the selection's frame,
## soft modification under a mirror moves the dragged vertex by the full drag, Local Per Entity
## typed values move each face along its own normal, the soft preview colours are sRGB, the palette
## follows undo, selection helpers keep the selection when they find nothing, Esc during a
## primitive's plane pick keeps the tool, leaving the view clears the hover, circular symmetry
## draws its axis, the overlay follows the editor scale, Edit Form's command panel keeps off the
## gizmo, Finish names a flat body, and the interactive Finish shows "Converting form bodies..."
## before it converts.
## Returns failure strings ([] when all pass).

const CAGE := preload("res://addons/holo_forge/core/form/cage.gd")
const FORM_OPS := preload("res://addons/holo_forge/core/form/form_ops.gd")
const PRIMITIVES := preload("res://addons/holo_forge/core/form/primitives.gd")
const MANIPULATOR := preload("res://addons/holo_forge/core/manipulator_math.gd")
const SHOTS_ARG := "--holo-forge-screenshots="
const TIMING := preload("res://tests/holo_forge_timing.gd")
## Hover change / drag frame against the 200k-iteration float loop calibration, with a whole
## 486-face body selected (measured 2026-10-30 in the headless editor: hover 0.95 ms, ratio 0.061;
## drag frame 6.2 ms, ratio 0.40; calibration 15.6 ms. Before the fix: 93-97 ms and 27-29 ms).
## Limits are twice the measured ratio.
const HOVER_RATIO_LIMIT := 0.12
const BODY_DRAG_RATIO_LIMIT := 0.8


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
	var form_id := ""
	var shots := ""

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
			fails.append("Form fix checks: " + detail)
			print("FAIL: Form fix checks: ", detail)

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
		var f: Resource = ws.create_form()
		await frames(1)
		if f == null or not editor.active:
			check(false, "A form should open for the fix checks.")
			return
		form_id = f.id
		var box := add_body(PRIMITIVES.box(Vector3.ONE * 0.04, Vector3i(4, 4, 4)))
		ws.viewport.fit()
		await frames(2)
		await _window_visibility(box)
		await _crossing_inside_face(box)
		await _rectangular_soft(box)
		await _local_per_entity(box)
		await _palette_undo()
		await _helpers_keep_selection(box)
		await _mouse_exit(box)
		await _editor_scale(box)
		await _panel_clear_of_gizmo(box)
		await _soft_under_mirror()
		await _circular_cue()
		if shots != "":
			for theme in ["dark", "light"]:
				await _review_shots(theme, box)
			ws.set_theme_mode("dark")
			await frames(1)
		await _body_timing()
		await _plane_pick_escape()
		await _finish_names_flat_body()
		await _interactive_finish()

	# --- Helpers ---------------------------------------------------------------------------------

	func add_body(cage: Dictionary) -> String:
		var before: Array = (doc.find_feature(form_id).options.bodies as Dictionary).keys()
		var fid := form_id
		ws.change("Form: Test Body", func() -> void: editor.apply_result(fid, {"cages": {}, "new_bodies": [cage]}, []))
		for body_id in (doc.find_feature(form_id).options.bodies as Dictionary).keys():
			if not before.has(body_id):
				return str(body_id)
		return ""

	func cage(body_id: String) -> Dictionary:
		return (doc.find_feature(form_id).options.bodies as Dictionary).get(body_id, {})

	func vertex_at(body_id: String, p: Vector3) -> int:
		var c := cage(body_id)
		for v in CAGE.vertex_count(c):
			if CAGE.position(c, v).distance_to(p) < 1e-6:
				return v
		return -1

	func face_at(body_id: String, centre: Vector3) -> int:
		var c := cage(body_id)
		var best := -1
		var best_d := INF
		for face in CAGE.face_count(c):
			var s := Vector3.ZERO
			var fv := CAGE.face_vertices(c, face)
			for v in fv:
				s += CAGE.position(c, v)
			var d := (s / fv.size()).distance_to(centre)
			if d < best_d:
				best_d = d
				best = face
		return best

	func select(items: Array) -> void:
		editor.selection.clear()
		for item in items:
			editor.selection.append(item)
		editor._selection_changed()

	func item(kind: String, body_id: String, index: int) -> Dictionary:
		return {"kind": kind, "body": body_id, "index": index, "pair": Vector2i(-1, -1)}

	func set_values(values: Dictionary) -> void:
		var merged: Dictionary = editor.tool_values.duplicate(true)
		merged.merge(values, true)
		ws.panel.set_values(merged)
		ws._on_panel_values_changed(merged)

	func button(at: Vector2, pressed: bool) -> InputEventMouseButton:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.position = at
		e.global_position = at
		e.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		return e

	func motion(at: Vector2) -> InputEventMouseMotion:
		var e := InputEventMouseMotion.new()
		e.position = at
		e.global_position = at
		e.button_mask = MOUSE_BUTTON_MASK_LEFT
		return e

	func wpp(p: Vector3) -> float:
		return 1.0 / float(ws.viewport.pixels_per_meter_at(p))

	## Drags the gizmo's arrow along axis by px pixels-worth; returns the travel (meters).
	func drag_arrow(axis: int, px: float) -> float:
		var g = editor.gizmo
		var pivot: Vector3 = g.pivot
		var dir: Vector3 = g.basis[axis].normalized()
		var w := wpp(pivot)
		var a: Vector2 = ws.viewport.project(pivot + dir * 58.0 * w)
		var b: Vector2 = ws.viewport.project(pivot + dir * (58.0 + px) * w)
		var ra: Array = ws.viewport.ray_from(a)
		var rb: Array = ws.viewport.ray_from(b)
		var t0 := MANIPULATOR.closest_on_line(pivot, dir, ra[0], ra[1])
		var t1 := MANIPULATOR.closest_on_line(pivot, dir, rb[0], rb[1])
		ws.viewport._overlay_input(button(a, true))
		for i in range(1, 7):
			ws.viewport._overlay_input(motion(a.lerp(b, i / 6.0)))
		ws.viewport._overlay_input(button(b, false))
		var snap: float = ws.viewport.snap_step
		return snappedf(t1 - t0, snap) if snap > 0.0 else t1 - t0

	func calibration() -> void:
		var x := 0.0
		for i in 200000:
			x += sin(float(i) * 1e-3)

	# --- Region selection (G-4, U-6) -------------------------------------------------------------

	func _window_visibility(body_id: String) -> void:
		var entry: Dictionary = editor._subd.get(body_id, {})
		var subd: RefCounted = entry.get("subd")
		var size: Vector2 = ws.viewport.size
		var saved_priority: String = ws.viewport.priority
		var view_dir: Vector3 = -(ws.viewport.camera_basis() as Basis).z if ws.viewport.ortho else Vector3.ZERO
		for kind in ["face", "edge"]:
			ws.viewport.priority = kind
			editor._region_select(PackedVector2Array([Vector2(2, 2), size - Vector2(2, 2)]), false, false, false)
			var picked: Array = editor.selection.filter(func(s: Dictionary) -> bool: return s.kind == kind and s.body == body_id)
			var points: PackedVector3Array = editor._face_centre_points(entry, editor.display_mode(body_id)) if kind == "face" else editor._edge_mid_points(entry, editor.display_mode(body_id))
			var seen: PackedByteArray = subd.visible(points, (ws.viewport.camera_position() as Vector3), view_dir, maxf(float(entry.diag) * 2e-3, 1e-7), 0)
			var hidden := 0
			var visible_total := 0
			for i in seen.size():
				visible_total += 1 if seen[i] != 0 else 0
			for s in picked:
				if seen[int(s.index)] == 0:
					hidden += 1
			check(not picked.is_empty() and hidden == 0, "A window around the whole body should take no hidden %s (%d of %d taken are hidden)." % [kind, hidden, picked.size()])
			check(picked.size() == visible_total, "The window should take every visible %s (%d taken, %d visible)." % [kind, picked.size(), visible_total])
			if kind == "face" and not ws.viewport.ortho:
				# From the opposite side of the body none of the taken faces can be seen (the box
				# is convex): nothing taken was a back face.
				var target: Vector3 = ws.viewport.target
				var behind: PackedByteArray = subd.visible(points, target * 2.0 - (ws.viewport.camera_position() as Vector3), Vector3.ZERO, maxf(float(entry.diag) * 2e-3, 1e-7), 0)
				var seen_behind := 0
				for s in picked:
					if behind[int(s.index)] != 0:
						seen_behind += 1
				check(seen_behind == 0, "No face taken by the window should face away from the camera (%d do)." % seen_behind)
		ws.viewport.priority = saved_priority
		select([])

	func _crossing_inside_face(body_id: String) -> void:
		var entry: Dictionary = editor._subd.get(body_id, {})
		var cam_pos: Vector3 = ws.viewport.camera_position()
		# A face next to the top centre (its corners' limit points lie well outside a 16 px box at
		# its centre, unlike a corner face, whose rounded corner sits near its middle).
		var best := face_at(body_id, Vector3(0.005, 0.005, 0.02))
		var centres: PackedVector3Array = editor._face_centre_points(entry, editor.display_mode(body_id))
		var at: Vector2 = ws.viewport.project(centres[best])
		var saved_priority: String = ws.viewport.priority
		ws.viewport.priority = "face"
		# Right to left (crossing), a small box wholly inside the face (a fifth of the way to its
		# nearest corner on screen): no vertex is inside it.
		var pts: PackedVector2Array = editor._screen_points(body_id, entry, editor.display_mode(body_id))
		var r := INF
		for v in CAGE.face_vertices(entry.cage, best):
			r = minf(r, pts[v].distance_to(at))
		r = maxf(r * 0.2, 1.5)
		editor._region_select(PackedVector2Array([at + Vector2(r, -r), at + Vector2(-r, r)]), true, false, false)
		var picked: Array = editor.selection.filter(func(s: Dictionary) -> bool: return s.kind == "face")
		check(picked.size() == 1 and int(picked[0].index) == best, "A crossing box inside a face should take that face (%s, want %d)." % [picked.map(func(s): return s.index), best])
		ws.viewport.priority = saved_priority
		select([])

	# --- Soft modification (G-2, G-3, U-3) ------------------------------------------------------

	func _rectangular_soft(body_id: String) -> void:
		var side := vertex_at(body_id, Vector3(0.02, 0.0, 0.0))
		var up1 := vertex_at(body_id, Vector3(0.02, 0.0, 0.01))
		var up2 := vertex_at(body_id, Vector3(0.02, 0.0, 0.02))
		var far := vertex_at(body_id, Vector3(-0.02, 0.0, 0.0))
		check(side >= 0 and up1 >= 0 and up2 >= 0 and far >= 0, "Box 4,4,4 should have the side vertices the soft check uses.")
		if side < 0 or up1 < 0 or up2 < 0 or far < 0:
			return
		select([item("vertex", body_id, side)])
		editor.start_tool("edit_form")
		set_values({"space": "world", "soft": true, "extent": "rectangular", "u_faces": "2", "v_faces": "2", "transition": "linear", "weight": "1"})
		await frames(1)
		var w: PackedFloat32Array = editor._soft.get(body_id, PackedFloat32Array())
		check(w.size() == CAGE.vertex_count(cage(body_id)), "Soft weights should be shown for the body.")
		if w.size() == CAGE.vertex_count(cage(body_id)):
			check(absf(w[side] - 1.0) < 1e-6 and absf(w[up1] - 0.5) < 1e-6 and w[up2] == 0.0 and w[far] == 0.0,
				"Rectangular 2 x 2 faces in the selection's frame: weights 1 / 0.5 / 0 at 0 / 10 / 20 mm up, 0 on the far side (%s, %s, %s, %s)." % [w[side], w[up1], w[up2], w[far]])
		var soft_material: StandardMaterial3D = editor.display.materials.surface_soft
		check(soft_material.vertex_color_is_srgb, "The soft preview material should treat its colours as sRGB (a zero weight looks like the surface).")
		set_values({"soft": false})
		editor.cancel_tool()
		select([])

	func _soft_under_mirror() -> void:
		var c := PRIMITIVES.box(Vector3.ONE * 0.04, Vector3i(4, 4, 4))
		c = PRIMITIVES.primitive_symmetry(c, "mirror", Transform3D.IDENTITY, Vector3i(1, 0, 0), 0)
		# Moved off to the side so it doesn't overlap the first box.
		var moved: Dictionary = FORM_OPS.transform_vertices(c, FORM_OPS._range(CAGE.vertex_count(c)), PackedFloat32Array(), FORM_OPS.xf_translation(0.0, 0.08, 0.0)).cage
		var sym: Array = moved.symmetry
		sym[0].origin = PackedFloat64Array([0.0, 0.08, 0.0])
		moved.symmetry = sym
		var body_id := add_body(moved)
		ws.viewport.fit()
		await frames(1)
		var v := vertex_at(body_id, Vector3(0.01, 0.08, 0.02))
		check(v >= 0, "The mirrored box should have a vertex at (10, 80, 20) mm.")
		if v < 0:
			return
		select([item("vertex", body_id, v)])
		editor.start_tool("edit_form")
		set_values({"transform_mode": "translate", "space": "world", "soft": true, "extent": "distance", "distance": "30 mm", "transition": "smooth", "weight": "1"})
		await frames(1)
		var before := CAGE.position_d(cage(body_id), v)
		var travel := drag_arrow(0, 30.0)
		await frames(1)
		var c2 := cage(body_id)
		var after := CAGE.position_d(c2, v)
		check(absf((after[0] - before[0]) - travel) <= wpp(editor.gizmo.pivot) + 1e-12 and absf(travel) > 0.0,
			"Under a mirror the dragged vertex should move by the whole drag with soft modification on (%s vs %s)." % [after[0] - before[0], travel])
		var partner: int = (c2.symmetry[0].map as PackedInt32Array)[v]
		var image := FORM_OPS.reflect_d(after, c2.symmetry[0].origin, c2.symmetry[0].normal)
		var q := CAGE.position_d(c2, partner)
		check(partner >= 0 and Vector3(image[0] - q[0], image[1] - q[1], image[2] - q[2]).length() <= 1e-9, "The partner should mirror the dragged vertex.")
		ws.history().undo()
		await frames(1)
		set_values({"soft": false})
		editor.cancel_tool()
		select([])

	# --- Local Per Entity typed values (G-1) --------------------------------------------------------

	func _local_per_entity(body_id: String) -> void:
		var px := face_at(body_id, Vector3(0.02, 0.005, 0.005))
		var nx := face_at(body_id, Vector3(-0.02, 0.005, 0.005))
		select([item("face", body_id, px), item("face", body_id, nx)])
		editor.start_tool("edit_form")
		set_values({"space": "local", "soft": false})
		await frames(1)
		var c := cage(body_id)
		var before := {}
		for face in [px, nx]:
			for v in CAGE.face_vertices(c, face):
				before[v] = CAGE.position_d(c, v)
		editor.tool_values["z_distance"] = "2 mm"
		editor._edit_form_ok()
		await frames(1)
		var c2 := cage(body_id)
		var ok := true
		var detail := ""
		for face in [px, nx]:
			var sign := 1.0 if face == px else -1.0
			for v in CAGE.face_vertices(c, face):
				var now := CAGE.position_d(c2, v)
				var b: PackedFloat64Array = before[v]
				if absf(now[0] - b[0] - sign * 0.002) > 1e-9 or absf(now[1] - b[1]) > 1e-9 or absf(now[2] - b[2]) > 1e-9:
					ok = false
					detail = "%s -> %s" % [b, now]
		check(ok, "Local Per Entity Z 2 mm should move the +X and -X faces out along their own normals (%s)." % detail)
		if str(ws.last_step.get("name", "")) == "Form: Edit Form":
			ws.history().undo()
			await frames(1)
		editor.cancel_tool()
		select([])

	# --- Palette, helpers, hover, scale (U-4, U-5, U-9, U-11) ----------------------------------------

	func _palette_undo() -> void:
		editor.set_conversion_quality("high")
		await frames(1)
		ws.history().undo()
		await frames(1)
		var shown := str(editor._palette_conversion.get_item_metadata(editor._palette_conversion.selected))
		check(shown == str(doc.find_feature(form_id).options.get("quality", "standard")) and shown == "standard",
			"The palette's conversion quality should follow undo (shows %s)." % shown)

	func _helpers_keep_selection(body_id: String) -> void:
		var a := face_at(body_id, Vector3(0.005, 0.005, 0.02))
		var b := face_at(body_id, Vector3(-0.015, -0.015, 0.02))
		select([item("face", body_id, a), item("face", body_id, b)])
		editor.select_helper("loop")
		check(editor.selection.size() == 2, "Select Loop on two faces that aren't neighbours should keep the selection (%d)." % editor.selection.size())
		check(str(ws.last_message).contains("neighbouring"), "and say what it needs (%s)." % ws.last_message)
		select([item("body", body_id, -1)])
		editor.invert_selection()
		check(editor.selection.size() >= 1, "Invert with a body selected should not drop the selection.")
		select([])

	func _mouse_exit(body_id: String) -> void:
		var entry: Dictionary = editor._subd.get(body_id, {})
		var centres: PackedVector3Array = editor._face_centre_points(entry, editor.display_mode(body_id))
		var at: Vector2 = ws.viewport.project(centres[face_at(body_id, Vector3(0.005, 0.005, 0.02))])
		editor._update_hover(at)
		var had: bool = not editor.hover.is_empty()
		var overlay: Control = ws.viewport.get("_overlay")
		overlay.mouse_exited.emit()
		check(had and editor.hover.is_empty(), "Leaving the view should clear the form hover (had %s, now %s)." % [had, editor.hover])

	func _editor_scale(body_id: String) -> void:
		select([item("face", body_id, face_at(body_id, Vector3(0.005, 0.005, 0.02)))])
		editor.start_tool("edit_form")
		await frames(1)
		editor.ui_scale = 2.0
		ws.viewport.redraw_overlay()
		await frames(2)
		var g = editor.gizmo
		check(is_equal_approx(float(g.px), 2.0), "The gizmo should take the editor scale (px %s)." % g.px)
		# The arrow is hit at twice the distance on a 2x editor.
		var pivot: Vector3 = g.pivot
		var at: Vector2 = ws.viewport.project(pivot + (g.basis.z as Vector3).normalized() * 120.0 * wpp(pivot))
		check(g.hit(ws.viewport, at) == "move_z", "A press 120 px along Z should take the 2x arrow (got '%s')." % g.hit(ws.viewport, at))
		editor.ui_scale = 0.0
		ws.viewport.redraw_overlay()
		await frames(1)
		editor.cancel_tool()
		select([])

	# --- Circular cue (U-7) ----------------------------------------------------------------------

	func _circular_cue() -> void:
		var cyl := PRIMITIVES.cylinder(0.02, 0.02, 8, 2, "pole")
		cyl = FORM_OPS.transform_vertices(cyl, FORM_OPS._range(CAGE.vertex_count(cyl)), PackedFloat32Array(), FORM_OPS.xf_translation(0.0, -0.08, 0.0)).cage
		cyl = PRIMITIVES.primitive_symmetry(cyl, "circular", Transform3D(Basis.IDENTITY, Vector3(0, -0.08, 0)), Vector3i.ZERO, 8)
		var body_id := add_body(cyl)
		await frames(1)
		check(ws.viewport.form_meshes().has(body_id + "/axis0"), "A circular symmetry should draw its axis (%s)." % [ws.viewport.form_meshes().keys().filter(func(k): return str(k).begins_with(body_id))])
		var seams: Dictionary = editor._seam_edges(cage(body_id), CAGE.topology(cage(body_id)))
		check(seams.size() >= 8, "A circular symmetry's sector borders should be seams (%d)." % seams.size())

	# --- Hover and drag cost with a whole body selected (U-1, U-2, T-1) -----------------------------

	func _body_timing() -> void:
		var big := PRIMITIVES.box(Vector3.ONE * 0.04, Vector3i(9, 9, 9))
		big = FORM_OPS.transform_vertices(big, FORM_OPS._range(CAGE.vertex_count(big)), PackedFloat32Array(), FORM_OPS.xf_translation(0.1, 0.0, 0.0)).cage
		var body_id := add_body(big)
		check(CAGE.face_count(big) == 486, "The timing body should have 486 faces.")
		ws.viewport.fit()
		await frames(1)
		select([item("body", body_id, -1)])
		var entry: Dictionary = editor._subd.get(body_id, {})
		var centres: PackedVector3Array = editor._face_centre_points(entry, editor.display_mode(body_id))
		var cam_pos: Vector3 = ws.viewport.camera_position()
		var topo: CAGE.Topo = entry.topo
		var facing := []
		for face in topo.nF:
			if topo.face_normal(big, face).dot((cam_pos - centres[face]).normalized()) > 0.5:
				facing.append(face)
			if facing.size() >= 2:
				break
		var a: Vector2 = ws.viewport.project(centres[facing[0]])
		var b: Vector2 = ws.viewport.project(centres[facing[1]])
		editor._update_hover(a)
		var flip := [false]
		var hover_op := func() -> void:
			flip[0] = not flip[0]
			editor._update_hover(b if flip[0] else a)
		var hover := TIMING.compare(hover_op, calibration, 7, "form hover with a body selected 486")
		check(float(hover.ratio) <= HOVER_RATIO_LIMIT, "Hover changes with a 486-face body selected should be cheap (%.2f ms, ratio %.3f, limit %.2f)." % [hover.op, hover.ratio, HOVER_RATIO_LIMIT])
		print("Forge FORM fix: hover with a body selected 486 faces %.2f ms, ratio %.3f" % [hover.op, hover.ratio])
		# A drag of the whole body: one motion (transform, symmetry, tessellation, meshes).
		editor.start_tool("edit_form")
		set_values({"transform_mode": "translate", "space": "world", "soft": false})
		await frames(1)
		var g = editor.gizmo
		var pivot: Vector3 = g.pivot
		var w := wpp(pivot)
		var p0: Vector2 = ws.viewport.project(pivot + Vector3.BACK * 58.0 * w)
		var p1: Vector2 = ws.viewport.project(pivot + Vector3.BACK * 80.0 * w)
		var p2: Vector2 = ws.viewport.project(pivot + Vector3.BACK * 95.0 * w)
		ws.viewport._overlay_input(button(p0, true))
		ws.viewport._overlay_input(motion(p1))
		var flip2 := [false]
		var drag_op := func() -> void:
			flip2[0] = not flip2[0]
			ws.viewport._overlay_input(motion(p2 if flip2[0] else p1))
		var drag := TIMING.compare(drag_op, calibration, 5, "form drag frame body 486")
		ws.viewport._overlay_input(button(p1, false))
		await frames(1)
		check(float(drag.ratio) <= BODY_DRAG_RATIO_LIMIT, "A drag frame with a 486-face body selected should stay within %.1f x the calibration (%.2f ms, ratio %.3f)." % [BODY_DRAG_RATIO_LIMIT, drag.op, drag.ratio])
		print("Forge FORM fix: drag frame with a body selected 486 faces %.2f ms, ratio %.3f" % [drag.op, drag.ratio])
		if str(ws.last_step.get("name", "")) == "Form: Edit Form":
			ws.history().undo()
			await frames(1)
		editor.cancel_tool()
		select([])

	# --- Esc during a primitive's plane pick (U-8) ----------------------------------------------------

	func _plane_pick_escape() -> void:
		editor.start_tool("box")
		await frames(1)
		if not ws.is_picking_plane():
			ws.start_plane_pick(Callable(editor, "_on_tool_plane"), "Box: pick a plane or flat face")
		var e := InputEventKey.new()
		e.keycode = KEY_ESCAPE
		e.pressed = true
		ws.handle_key(e)
		check(str(ws.last_message).begins_with("Plane pick cancelled") and editor.tool == "box",
			"Esc during the Box's plane pick should keep the tool and say OK still places it (%s, tool %s)." % [ws.last_message, editor.tool])
		editor.cancel_tool()

	# --- Screenshots of the reviewed views (both themes) ----------------------------------------------

	func shot(file: String, control: Control = null) -> void:
		await frames(3)
		ws.viewport.redraw_overlay()
		EditorInterface.get_base_control().queue_redraw()
		await RenderingServer.frame_post_draw
		var window: Window = EditorInterface.get_base_control().get_window()
		var image := window.get_texture().get_image()
		var target: Control = control if control != null else ws.viewport
		var rect := Rect2i(target.get_global_rect()).intersection(Rect2i(Vector2i.ZERO, image.get_size()))
		image.get_region(rect).save_png(shots.path_join(file))
		print("Forge FORM fix: saved ", shots.path_join(file))

	## The view framed on the 40 mm box at the origin, from the default angle.
	func frame_box() -> void:
		ws.viewport.home()
		ws.viewport.target = Vector3.ZERO
		ws.viewport.distance = 0.16
		ws.viewport._update_camera()

	func _review_shots(theme: String, box: String) -> void:
		ws.set_theme_mode(theme)
		frame_box()
		await frames(2)
		# Window selection of faces (hidden back faces left out), seen from the default camera
		# and from behind.
		var saved_priority: String = ws.viewport.priority
		ws.viewport.priority = "face"
		var size: Vector2 = ws.viewport.size
		select([])
		editor._region_select(PackedVector2Array([Vector2(2, 2), size - Vector2(2, 2)]), false, false, false)
		ws.viewport.priority = saved_priority
		await shot("fix_%s_window_front.png" % theme)
		var toward: Vector3 = ((ws.viewport.camera_position() as Vector3) - ws.viewport.target).normalized()
		ws.viewport.look_from(-toward)
		await frames(2)
		await shot("fix_%s_window_back.png" % theme)
		frame_box()
		await frames(2)
		# Soft modification preview: the surface keeps its colour where the weight is zero.
		var side := vertex_at(box, Vector3(0.02, 0.0, 0.0))
		select([item("vertex", box, side)])
		editor.start_tool("edit_form")
		set_values({"space": "world", "soft": true, "extent": "distance", "distance": "18 mm", "transition": "smooth", "weight": "1"})
		await frames(1)
		await shot("fix_%s_soft.png" % theme)
		set_values({"extent": "rectangular", "u_faces": "2", "v_faces": "2", "transition": "linear"})
		await frames(1)
		await shot("fix_%s_soft_rectangular.png" % theme)
		set_values({"soft": false})
		editor.cancel_tool()
		select([])
		await frames(1)
		# The whole Forge screen: the circular body's axis and sector seams, the mirrored body's
		# plane, and the toolbar with FINISH at its right end.
		ws.viewport.fit()
		await frames(2)
		await shot("fix_%s_screen.png" % theme, EditorInterface.get_editor_main_screen())
		# The circular body up close.
		ws.viewport.home()
		ws.viewport.target = Vector3(0, -0.08, 0.01)
		ws.viewport.distance = 0.09
		ws.viewport._update_camera()
		await frames(2)
		await shot("fix_%s_circular.png" % theme)
		ws.viewport.fit()

	# --- Finish names a flat body (G-5) -------------------------------------------------------------

	func _finish_names_flat_body() -> void:
		var flat := PRIMITIVES.box(Vector3.ONE * 0.01, Vector3i(1, 1, 1))
		var p: PackedFloat64Array = flat.positions
		for v in CAGE.vertex_count(flat):
			p[3 * v] += 0.2
			p[3 * v + 2] = 0.0
		flat.positions = p
		var body_id := add_body(flat)
		ws.run_action("finish_form")
		await frames(2)
		var warning := str((ws.result.get("warnings", {}) as Dictionary).get(form_id, ""))
		check(warning.contains(doc.body_name(body_id)) and (warning.contains("no area") or warning.contains("no volume")),
			"Finishing a form with a flat body should warn about it by name (%s)." % warning)
		check(str(ws.last_message).contains("Repair Body"), "Finish should point to Repair Body (%s)." % ws.last_message)
		ws.history().undo()
		await frames(2)

	# --- Edit Form's command panel keeps off the gizmo ------------------------------------------

	## The view panned so the gizmo sits where the command panel goes (top right, under the view
	## cube): the panel moves off it (left, away from the selection) and comes back to its own spot
	## once the gizmo leaves it. Screenshot fix_dark_panel_gizmo.png.
	func _panel_clear_of_gizmo(body_id: String) -> void:
		frame_box()
		await frames(2)
		var v := vertex_at(body_id, Vector3(0.02, 0.0, 0.0))
		select([item("vertex", body_id, v)])
		editor.start_tool("edit_form")
		set_values({"transform_mode": "multi", "space": "world", "soft": false})
		await frames(2)
		var panel: Control = ws.panel
		var view: Vector2 = ws.viewport.size
		var top := float(ws.get_script().get_script_constant_map().get("PANEL_TOP", 150.0))
		var home := Rect2(Vector2(maxf(view.x - panel.size.x - 10.0, 10.0), top), panel.size)
		check(panel.visible and panel.position.is_equal_approx(home.position),
			"Edit Form's panel should start at its own spot (at %s, spot %s)." % [panel.position, home.position])
		# Pan so the pivot projects into the panel's spot.
		var want := Vector2(home.get_center().x, home.position.y + minf(home.size.y * 0.5, 140.0))
		var pivot: Vector3 = editor.gizmo.pivot
		var ray: Array = ws.viewport.ray_from(want)
		var dir: Vector3 = ray[1]
		var q: Vector3 = ray[0] + dir * (pivot - (ray[0] as Vector3)).dot(dir)
		ws.viewport.target += pivot - q
		ws.viewport._update_camera()
		await frames(2)
		var g: Rect2 = editor.gizmo.screen_rect(ws.viewport)
		check(g.has_area() and g.intersects(home), "The test should put the gizmo %s under the panel's spot %s." % [g, home])
		if view.x < 2.0 * panel.size.x + 60.0 or view.y < 400.0:
			# The headless editor's view (about 200 x 260) is narrower than the panel: there is no
			# place clear of the gizmo, so only the windowed run checks the placement.
			print("Form fix checks: view %s too small for the panel placement check" % view)
			editor.cancel_tool()
			select([])
			await frames(1)
			return
		var rect := Rect2(panel.position, panel.size)
		check(not rect.intersects(g), "Edit Form's panel %s should keep off the gizmo %s." % [rect, g])
		check(Rect2(Vector2.ZERO, view).encloses(rect), "The moved panel %s should stay inside the view %s." % [rect, view])
		if editor.palette != null and editor.palette.visible:
			check(not rect.intersects(Rect2(editor.palette.position, editor.palette.size)),
				"The moved panel %s should keep off the palette %s." % [rect, Rect2(editor.palette.position, editor.palette.size)])
		if shots != "":
			await shot("fix_dark_panel_gizmo.png")
		# A camera move that keeps the gizmo clear of the panel leaves it where it is.
		var moved_to := panel.position
		ws.viewport.target += Vector3(0.0, 0.0, 0.0001)
		ws.viewport._update_camera()
		await frames(2)
		check(panel.position.is_equal_approx(moved_to), "A small camera move should leave the panel where it is (%s, was %s)." % [panel.position, moved_to])
		# The gizmo back in the middle: a new gizmo place puts the panel back at its own spot.
		frame_box()
		select([item("vertex", body_id, v)])
		await frames(2)
		g = editor.gizmo.screen_rect(ws.viewport)
		if not g.intersects(home):
			check(panel.position.is_equal_approx(home.position),
				"With the gizmo clear of it the panel should go back to its own spot (at %s, spot %s)." % [panel.position, home.position])
		editor.cancel_tool()
		select([])
		await frames(1)

	# --- The interactive Finish shows its message before converting ---------------------------------

	## The FINISH FORM button's path (editor.finish()): the form closes and "Converting form
	## bodies..." is in the status line at once, while the rebuild waits FINISH_DELAY_FRAMES frames
	## (the result still holds the preview); then the bodies convert and the finish message shows.
	func _interactive_finish() -> void:
		if not editor.has_method("finish"):
			check(false, "The form editor should have the interactive finish().")
			return
		if not editor.active:
			ws.edit_feature(form_id)
			await frames(2)
		if not editor.active:
			check(false, "The form should open again for the interactive Finish check.")
			return
		var preview := bool((ws.result.get("forms", {}).get(form_id, {}) as Dictionary).get("preview", false))
		check(preview, "The open form's result should be its preview.")
		var converting := str(editor.get_script().get_script_constant_map().get("CONVERTING_MESSAGE", "Converting form bodies..."))
		editor.finish()
		check(not editor.active and ws.form_preview == "", "The interactive Finish should leave the environment at once.")
		check(ws.last_message == converting and str(ws._status.text) == converting,
			"The interactive Finish should show '%s' before converting (got '%s' / '%s')." % [converting, ws.last_message, ws._status.text])
		check(editor.is_finishing() and bool((ws.result.get("forms", {}).get(form_id, {}) as Dictionary).get("preview", false)),
			"The conversion should wait a frame or two after the message (the result should still be the preview).")
		if shots != "":
			# The frame that draws the message (the conversion runs two frames later).
			await RenderingServer.frame_post_draw
			var window: Window = EditorInterface.get_base_control().get_window()
			var image := window.get_texture().get_image()
			image.save_png(shots.path_join("fix_dark_finish_converting.png"))
			print("Forge FORM fix: saved ", shots.path_join("fix_dark_finish_converting.png"))
		await frames(4)
		check(not editor.is_finishing(), "The interactive Finish should have converted after a few frames.")
		var summary: Dictionary = ws.result.get("forms", {}).get(form_id, {})
		check(not bool(summary.get("preview", true)), "After the interactive Finish the result should hold the converted form (%s)." % [summary.keys()])
		check(str(ws.last_message).begins_with("Form finished"), "The interactive Finish should end with the finish message (%s)." % ws.last_message)
		# The synchronous path (run_action, tests, other tools) is unchanged.
		ws.edit_feature(form_id)
		await frames(2)
		if editor.active:
			ws.run_action("finish_form")
			check(not editor.active and str(ws.last_message).begins_with("Form finished") and not editor.is_finishing(),
				"run_action('finish_form') should still convert at once (%s)." % ws.last_message)
