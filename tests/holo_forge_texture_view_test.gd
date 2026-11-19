extends SceneTree
## Texture Map Controls keeps the texture in clear view and number fields drag, with real mouse
## events where a user would use them:
## - While Texture Map Controls is open, its picked face is outlined (its four sides), not tinted:
##   the view adds no fill over it. Cancel brings the usual tinted selection back.
## - The uniform Scale dot pulled out scales U and V by the same ratio, and the Rotation ring
##   round the anchor turns the texture.
## - A number field in the command panel (Box) drags: right raises the value, left lowers it,
##   Shift steps finer; a click without a drag only places the caret. Angles move half a degree a
##   pixel, "whole" fields by whole numbers, "bare" fields write no unit.
##
## godot --headless --path . --script res://tests/holo_forge_texture_view_test.gd

const WORKSPACE := preload("res://addons/holo_forge/ui/forge_workspace.gd")
const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const CATALOG := preload("res://addons/holo_forge/tools/catalog.gd")
const APPEARANCE := preload("res://addons/holo_forge/core/appearance.gd")
const UNITS := preload("res://addons/holo_forge/core/units.gd")
const NUMBER_DRAG := preload("res://addons/holo_forge/ui/number_drag.gd")
const MANIPULATOR := preload("res://addons/holo_forge/core/manipulator_math.gd")
const RED := "builtin:paint_red"

var failures: Array[String] = []
var ws: Control


func _init() -> void:
	call_deferred("run")


func run() -> void:
	create_timer(180.0).timeout.connect(func() -> void:
		print("FAIL holo_forge_texture_view: timed out ", failures)
		quit(1))
	root.size = Vector2i(1600, 1000)
	await _check_number_drag_alone()
	ws = WORKSPACE.new()
	root.add_child(ws)
	ws.size = Vector2(1500, 950)
	await _frames(3)
	if ws.kernel == null:
		_expect(false, "The native kernel should load.")
	else:
		await _check_texture_map()
		await _check_panel_drag()
	for failure in failures:
		print("  - ", failure)
	print("PASS holo_forge_texture_view: Texture Map Controls outlines its face (no tint) and Cancel tints again; the Scale dot scales U and V together and the ring turns the texture; command panel numbers drag right up, left down, Shift finer, a click only types; angle, whole and bare drags." \
		if failures.is_empty() else "FAIL holo_forge_texture_view")
	quit(0 if failures.is_empty() else 1)


## A LineEdit with the helper on its own: lengths step by a hundredth of their size, angles by
## half a degree, whole numbers by one every 8 px, bare text has no unit, Shift is finer.
func _check_number_drag_alone() -> void:
	var box := VBoxContainer.new()
	box.position = Vector2(40, 40)
	box.size = Vector2(300, 200)
	root.add_child(box)
	var edits := {}
	var seen := {}
	for spec in [["len", UNITS.KIND_LENGTH, {}, "10 mm"], ["ang", UNITS.KIND_ANGLE, {}, "30 deg"], ["whole", UNITS.KIND_NUMBER, {"whole": true, "range": [1, 50]}, "3"],
			["bare", UNITS.KIND_LENGTH, {"bare": true}, "200"]]:
		var edit := LineEdit.new()
		edit.custom_minimum_size = Vector2(200, 30)
		edit.text = spec[3]
		box.add_child(edit)
		var key: String = spec[0]
		seen[key] = 0
		NUMBER_DRAG.attach(edit, spec[1], func() -> String: return "mm", func(_text: String) -> void: seen[key] += 1, spec[2])
		edits[key] = edit
	await _frames(2)
	await _drag_field(edits.len, 50.0)
	_expect(edits.len.text == "15 mm" and seen.len > 0, "50 px right on 10 mm should give 15 mm (%s, %d changes)." % [edits.len.text, seen.len])
	await _drag_field(edits.len, -200.0)
	_expect(edits.len.text == "-5 mm", "200 px left on 15 mm should go below zero to -5 mm (%s)." % edits.len.text)
	await _drag_field(edits.len, 50.0, true)
	_expect(edits.len.text == "-4.95 mm", "Shift should step a tenth as far (-5 mm + 50 px = %s)." % edits.len.text)
	await _drag_field(edits.ang, -20.0)
	_expect(edits.ang.text == "20 deg", "20 px left on 30 deg should give 20 deg (%s)." % edits.ang.text)
	await _drag_field(edits.whole, 40.0)
	_expect(edits.whole.text == "8", "40 px right on a whole 3 should give 8 (%s)." % edits.whole.text)
	await _drag_field(edits.whole, -400.0)
	_expect(edits.whole.text == "1", "A whole field should stop at its range's low end (%s)." % edits.whole.text)
	await _drag_field(edits.bare, 30.0)
	_expect(edits.bare.text == "230", "A bare field should write no unit (200 + 30 px = %s)." % edits.bare.text)
	# A click without a drag only places the caret.
	var before: String = edits.len.text
	var changes: int = seen.len
	await _click(edits.len.global_position + edits.len.size * 0.5)
	_expect(edits.len.text == before and seen.len == changes and edits.len.has_focus(), "A click should leave the value and give the field the keyboard (%s)." % edits.len.text)
	_expect(not NUMBER_DRAG.of(edits.len).is_dragging(), "No drag should be left on.")
	box.queue_free()
	await _frames(1)


## A box with a red top face: Texture Map Controls outlines it; the Scale dot and the ring work.
func _check_texture_map() -> void:
	var part: Node3D = CAD_PART.new()
	part.document = DOCUMENT.new()
	root.add_child(part)
	ws.set_part(part)
	await _frames(2)
	ws.run_tool(CATALOG.find("solid.create.box"))
	ws.accept_command()
	await _frames(2)
	var body := str(ws.result.bodies.keys()[0])
	var shape: RefCounted = ws.result.bodies[body].shape
	var top := _top_face(shape)
	var target := APPEARANCE.face_target(body, str(shape.get_face_names()[top]))
	ws.change("Red Top", func() -> void: ws.doc.appearances[target] = {"material": RED, "mapping": {"type": "planar", "scale": Vector2(0.02, 0.02)}})
	await _frames(2)
	ws.viewport.yaw = 0.6
	ws.viewport.pitch = -0.8
	ws.viewport.fit()
	await _frames(2)
	ws.selection.clear()
	ws.selection.append({"kind": "face", "body": body, "index": top, "point": Vector3.ZERO})
	ws._selection_changed(true)
	await _frames(1)
	_expect(_fills() > 0 and ws.viewport.face_outlines().is_empty(), "Outside Texture Map Controls a picked face should be tinted (%d fills, %s)." % [_fills(), ws.viewport.face_outlines()])
	ws.run_tool(CATALOG.find("solid.modify.texture_map_controls"))
	await _frames(3)
	if not _expect(ws.command != null and str(ws.command.get("target_key")) == target, "Texture Map Controls should open on the red top (%s)." % [ws.command.get("target_key") if ws.command != null else "closed"]):
		return
	var outlines: Array = ws.viewport.face_outlines()
	_expect(ws.viewport.outline_faces and _fills() == 0, "Texture Map Controls should add no tint over the face (%d fills)." % _fills())
	_expect(outlines.size() == 1 and outlines[0].look == "selected" and int(outlines[0].segments) == 4, "The face should be outlined by its four sides (%s)." % [outlines])
	# Hovering the face outlines it too (no tint).
	var center := _screen((shape.bbox() as AABB).get_center() + Vector3(0, (shape.bbox() as AABB).size.y * 0.5, 0) + Vector3(0.004, 0, 0.004))
	_move(center)
	await _frames(2)
	_expect(_fills() == 0, "Hovering in Texture Map Controls should add no tint either (%d fills)." % _fills())
	# The uniform Scale dot, pulled out by half its distance again: U and V both grow 1.5 times.
	var dot := _handle("scale_uv", "scale")
	if _expect(not dot.is_empty(), "The Scale dot should show (%s)." % [ws.viewport.handles.map(func(h: Dictionary) -> String: return "%s:%s" % [h.type, h.key])]):
		var shape2d: Dictionary = ws.viewport._handle_screen_shape(dot)
		var at: Vector2 = shape2d.at
		var away: Vector2 = (at - (shape2d.center as Vector2))
		var g: Vector2 = ws.viewport.global_position
		_expect(ws.viewport._handle_at(at).get("key", "") == "scale_uv", "A press on the dot should take it.")
		await _drag(g + at, g + at + away * 0.5)
		var end_ray: Array = ws.viewport.ray_from(at + away * 0.5)
		var start_ray: Array = ws.viewport.ray_from(at)
		var ratio := MANIPULATOR.closest_on_line(dot.origin, dot.direction, end_ray[0], end_ray[1]) / MANIPULATOR.closest_on_line(dot.origin, dot.direction, start_ray[0], start_ray[1])
		var scale: Vector2 = ws.doc.appearances[target].mapping.scale
		_expect(ratio > 1.2 and absf(scale.x / 0.02 - ratio) < 1e-3 and absf(scale.y / 0.02 - ratio) < 1e-3, "The Scale dot should grow U and V by the same ratio (%s, ratio %.4f)." % [scale, ratio])
		_expect(str(ws.command_values.scale_u) == str(ws.command_values.scale_v), "Both scale fields should read the same (%s, %s)." % [ws.command_values.scale_u, ws.command_values.scale_v])
	# The Rotation ring: a drag along a quarter of it turns the texture about 90 degrees.
	var ring := _handle("rotation", "ring")
	if _expect(not ring.is_empty(), "The Rotation ring should show."):
		var outline: PackedVector2Array = ws.viewport._handle_screen_shape(ring).points
		var g: Vector2 = ws.viewport.global_position
		var path: Array[Vector2] = []
		for i in range(0, 13):
			path.append(g + outline[i])
		_expect(ws.viewport._handle_at(outline[0]).get("key", "") == "rotation", "A press on the ring should take it (%s)." % ws.viewport._handle_at(outline[0]))
		await _drag_path(path)
		var turned := absf(rad_to_deg(float(ws.doc.appearances[target].mapping.get("rotation", 0.0))))
		_expect(turned > 60.0 and turned < 120.0, "A quarter of the ring should turn the texture about 90 degrees (%.2f)." % turned)
	ws.cancel_command()
	await _frames(2)
	_expect(not ws.viewport.outline_faces and _fills() > 0 and ws.viewport.face_outlines().is_empty(), "After Cancel the selection should be tinted again (%d fills)." % _fills())
	_expect(not (ws.doc.appearances[target].mapping as Dictionary).has("rotation"), "Cancel should put the mapping back (%s)." % [ws.doc.appearances[target].mapping])


## A number field of the Box command drags with real mouse events.
func _check_panel_drag() -> void:
	ws.selection.clear()
	ws._selection_changed(true)
	ws.run_tool(CATALOG.find("solid.create.box"))
	await _frames(2)
	var edit: LineEdit = null
	var key := ""
	for field in ws.command.fields():
		if str(field.get("type", "")) == "expression" and str(field.get("kind", "")) == UNITS.KIND_LENGTH and ws.panel._editors.get(field.key) is LineEdit:
			edit = ws.panel._editors[field.key]
			key = str(field.key)
			break
	if not _expect(edit != null, "The Box command should have a length field."):
		return
	var before := UNITS.evaluate(edit.text, UNITS.KIND_LENGTH, ws.doc.units, {})
	await _drag_field(edit, 60.0)
	var after := UNITS.evaluate(str(ws.command_values.get(key, "")), UNITS.KIND_LENGTH, ws.doc.units, {})
	_expect(before.ok and after.ok and float(after.value) > float(before.value) and edit.text == str(ws.command_values.get(key, "")),
		"Dragging %s right should raise it and go into the command (%s -> %s)." % [key, before.get("value"), ws.command_values.get(key)])
	await _drag_field(edit, -120.0)
	var lower := UNITS.evaluate(str(ws.command_values.get(key, "")), UNITS.KIND_LENGTH, ws.doc.units, {})
	_expect(lower.ok and float(lower.value) < float(before.value), "Dragging it left should lower it (%s)." % ws.command_values.get(key))
	_expect(ws.result.get("errors", {}).is_empty(), "The dragged box should build (%s)." % [ws.result.get("errors", {})])
	ws.cancel_command()
	await _frames(1)


# --- Helpers ----------------------------------------------------------------------------------

func _top_face(shape: RefCounted) -> int:
	for f in shape.face_count():
		var info: Dictionary = shape.face_info(f)
		if info.get("planar", false) and (info.normal as Vector3).is_equal_approx(Vector3.UP):
			return f
	return -1


func _fills() -> int:
	var count := 0
	for child in ws.viewport._highlight_root.get_children():
		if not child.is_queued_for_deletion():
			count += 1
	return count


func _handle(key: String, type: String) -> Dictionary:
	for h in ws.viewport.handles:
		if str(h.get("key", "")) == key and str(h.get("type", "")) == type:
			return h
	return {}


## Presses a field near its left side and drags sideways by dx pixels in a few steps.
func _drag_field(edit: LineEdit, dx: float, shift := false) -> void:
	var from := edit.global_position + Vector2(20, edit.size.y * 0.5)
	var to := from + Vector2(dx, 0)
	await _drag(from, to, shift)


func _drag(from: Vector2, to: Vector2, shift := false) -> void:
	_move(from)
	await process_frame
	_mouse(from, true, shift)
	await process_frame
	var last := from
	for i in 8:
		var p := from.lerp(to, (i + 1) / 8.0)
		_move(p, true, p - last, shift)
		last = p
		await process_frame
	_mouse(to, false, shift)
	await _frames(2)


func _drag_path(points: Array[Vector2]) -> void:
	_move(points[0])
	await process_frame
	_mouse(points[0], true)
	await process_frame
	var last := points[0]
	for p in points.slice(1):
		_move(p, true, p - last)
		last = p
		await process_frame
	_mouse(last, false)
	await _frames(2)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _screen(p: Vector3) -> Vector2:
	return ws.viewport.global_position + ws.viewport.project(p)


func _mouse(at: Vector2, pressed: bool, shift := false) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = at
	event.global_position = at
	event.shift_pressed = shift
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	root.push_input(event)


func _move(at: Vector2, held := false, relative := Vector2.ZERO, shift := false) -> void:
	var event := InputEventMouseMotion.new()
	event.position = at
	event.global_position = at
	event.relative = relative
	event.shift_pressed = shift
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
	root.push_input(event)


func _click(at: Vector2) -> void:
	_move(at)
	await process_frame
	_mouse(at, true)
	await process_frame
	_mouse(at, false)
	await process_frame


func _expect(ok: bool, message: String) -> bool:
	if not ok:
		failures.append(message)
	return ok
