extends SceneTree
## The view's Orbit, Pan and Zoom buttons never get in the way of picking, driven with real mouse
## and key events: with Fillet (and Chamfer) open, a click in Orbit, Pan or Zoom still picks an
## edge, a drag moves the camera and picks nothing, Escape goes back to Select keeping the command
## and its picks (also from a focused panel field), and a second Escape cancels the command. None of
## the bar's buttons takes keyboard focus, so Enter after Fit still finishes the command. In a sketch,
## clicks in Orbit still draw.
##
## godot --headless --path . --script res://tests/holo_forge_navigation_test.gd

const WORKSPACE := preload("res://addons/holo_forge/ui/forge_workspace.gd")
const VIEWPORT := preload("res://addons/holo_forge/ui/forge_viewport.gd")
const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const CATALOG := preload("res://addons/holo_forge/tools/catalog.gd")
const SKETCH := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")

var failures: Array[String] = []
var ws: Control


func _init() -> void:
	call_deferred("run")


func run() -> void:
	create_timer(180.0).timeout.connect(func() -> void:
		print("FAIL holo_forge_navigation: timed out ", failures)
		quit(1))
	root.size = Vector2i(1600, 1000)
	ws = WORKSPACE.new()
	root.add_child(ws)
	ws.size = Vector2(1500, 950)
	for i in 3:
		await process_frame
	if ws.kernel == null:
		_expect(false, "The native kernel should load.")
	else:
		await _new_part()
		ws.run_tool(CATALOG.find("solid.create.box"))
		ws.accept_command()
		await process_frame
		var body := str(ws.result.bodies.keys()[0])
		for mode in [VIEWPORT.NavMode.ORBIT, VIEWPORT.NavMode.PAN, VIEWPORT.NavMode.ZOOM]:
			await _check_mode("solid.modify.fillet", mode, body)
		await _check_mode("solid.modify.chamfer", VIEWPORT.NavMode.ORBIT, body)
		await _check_escape_from_field(body)
		await _check_enter_after_fit(body)
		await _check_fit_narrow(body)
		await _check_sketch_clicks()
	print("PASS holo_forge_navigation: in Orbit, Pan and Zoom a click still picks for Fillet and Chamfer and a drag only moves the view, Escape goes back to Select keeping the command and its picks (also from a panel field) and a second Escape cancels, the bar's buttons take no focus (Enter after Fit finishes the command), Fit shows the whole part in narrow and wide views, and clicks in Orbit still draw in a sketch." \
		if failures.is_empty() else "FAIL holo_forge_navigation")
	quit(0 if failures.is_empty() else 1)


func _check_mode(tool_id: String, mode: int, body: String) -> void:
	var name: String = ["Select", "Orbit", "Pan", "Zoom"][mode]
	var at := "%s in %s" % [CATALOG.find(tool_id).name, name]
	ws.run_tool(CATALOG.find(tool_id))
	await _settle()
	var edges := _top_edges(body)
	await _click(_screen(edges[0]))
	_expect(_picked() == 1, "%s: the first edge should be picked (%d)." % [at, _picked()])
	var focus_before := root.gui_get_focus_owner()
	var button := _nav_button(name)
	await _click(_center(button))
	_expect(ws.viewport.nav_mode == mode and (button as Button).button_pressed, "%s: the button should turn %s on." % [at, name])
	_expect(root.gui_get_focus_owner() == focus_before, "%s: the button shouldn't take the keyboard focus (%s)." % [at, root.gui_get_focus_owner()])
	# A click (no drag) still picks.
	await _click(_screen(edges[1]))
	_expect(_picked() == 2 and ws.viewport.nav_mode == mode, "%s: a click should pick the second edge and stay in %s (picked %d)." % [at, name, _picked()])
	# A drag moves the view and picks nothing.
	var camera := _camera_state()
	var from := _screen(edges[2])
	await _drag(from, from + Vector2(60, 25))
	_expect(_camera_state() != camera, "%s: a drag should move the view." % at)
	_expect(_picked() == 2, "%s: a drag shouldn't pick (picked %d)." % [at, _picked()])
	# Escape: back to Select, the command and its picks stay; a second Escape cancels.
	await _key(KEY_ESCAPE)
	_expect(ws.viewport.nav_mode == VIEWPORT.NavMode.SELECT and not (button as Button).button_pressed, "%s: Escape should go back to Select and release the button." % at)
	_expect(ws.command != null and _picked() == 2, "%s: Escape out of %s should keep the command and its 2 edges (%s)." % [at, name, "open" if ws.command != null else "cancelled"])
	await _key(KEY_ESCAPE)
	_expect(ws.command == null, "%s: a second Escape should cancel the command." % at)


## Escape with the panel's radius field focused leaves Orbit; it doesn't cancel the command.
func _check_escape_from_field(body: String) -> void:
	ws.run_tool(CATALOG.find("solid.modify.fillet"))
	await _settle()
	await _click(_screen(_top_edges(body)[0]))
	await _click(_center(_nav_button("Orbit")))
	ws.panel.focus_first()
	await process_frame
	var focused := root.gui_get_focus_owner()
	_expect(focused != null and ws.panel.is_ancestor_of(focused), "A panel field should have the focus (%s)." % focused)
	await _key(KEY_ESCAPE)
	_expect(ws.command != null and _picked() == 1 and ws.viewport.nav_mode == VIEWPORT.NavMode.SELECT, "Escape in a panel field while in Orbit should only leave Orbit (%s, %d picked)." % ["open" if ws.command != null else "cancelled", _picked()])
	if ws.command != null:
		ws.cancel_command()
	await process_frame


## Fit takes no focus: Enter afterwards still finishes the open Fillet.
func _check_enter_after_fit(body: String) -> void:
	var count: int = ws.doc.features.size()
	ws.run_tool(CATALOG.find("solid.modify.fillet"))
	await _settle()
	await _click(_screen(_top_edges(body)[0]))
	ws.panel.focus_first()
	await process_frame
	await _click(_center(_nav_button("Fit")))
	_expect(not (root.gui_get_focus_owner() is Button), "Fit shouldn't take the focus (%s)." % root.gui_get_focus_owner())
	await _key(KEY_ENTER)
	await _settle()
	_expect(ws.command == null and ws.doc.features.size() == count + 1, "Enter after Fit should finish the Fillet (%s, %d features)." % ["open" if ws.command != null else "done", ws.doc.features.size()])
	if ws.command != null:
		ws.cancel_command()
	await process_frame


## Fit shows the whole part in a view narrower than it is tall (the camera's FOV is vertical, so
## the side angle is the smaller one there) and in a wide one, in perspective and orthographic.
func _check_fit_narrow(body: String) -> void:
	var old_size: Vector2 = ws.size
	var box: AABB = ws.result.bodies[body].shape.bbox()
	for view in [Vector2(260, 900), Vector2(1500, 260)]:
		ws.size = view
		for i in 3:
			await process_frame
		for ortho in [false, true]:
			ws.viewport.set_ortho(ortho)
			ws.viewport.look_from(Vector3.UP)
			ws.viewport.fit()
			await process_frame
			var vp_size: Vector2 = ws.viewport.size
			var outside := []
			for c in 8:
				var at: Vector2 = ws.viewport.project(box.get_endpoint(c))
				if not Rect2(Vector2.ZERO, vp_size).has_point(at):
					outside.append(at)
			_expect(outside.is_empty(), "Fit in the %s view (%s) should show every corner of the box (outside: %s)." % [("orthographic" if ortho else "perspective"), vp_size, outside])
	ws.viewport.set_ortho(false)
	_expect(is_equal_approx(VIEWPORT.fit_half_angle(Vector2(100, 100)), deg_to_rad(VIEWPORT.FOV) * 0.5) and VIEWPORT.fit_half_angle(Vector2(100, 400)) < deg_to_rad(VIEWPORT.FOV) * 0.5 * 0.3, "fit_half_angle should be the FOV's half in a square view and narrower in a tall one.")
	ws.size = old_size
	for i in 3:
		await process_frame


## In a sketch, the Line tool's clicks made in Orbit still draw.
func _check_sketch_clicks() -> void:
	await _new_part()
	ws.create_sketch(SKETCH.ORIGIN_PLANES.xz, "xz")
	await _settle()
	ws.run_tool(CATALOG.find("sketch.create.line"))
	await process_frame
	await _click(_center(_nav_button("Orbit")))
	_expect(ws.viewport.nav_mode == VIEWPORT.NavMode.ORBIT, "Orbit should be on in the sketch.")
	await _click(_screen(Vector3(0.0, 0.0, 0.0)))
	await _click(_screen(Vector3(0.03, 0.0, 0.0)))
	var lines: int = ws.sketch_editor.sketch().entities().filter(func(e: Dictionary) -> bool: return e.type == "line").size()
	_expect(lines >= 1, "Two clicks with Line in Orbit should draw a line (%d lines)." % lines)
	await _key(KEY_ESCAPE)
	_expect(ws.viewport.nav_mode == VIEWPORT.NavMode.SELECT and ws.sketch_editor.active, "Escape should leave Orbit and stay in the sketch.")


# --- Helpers ----------------------------------------------------------------------------------

func _new_part() -> void:
	var part: Node3D = CAD_PART.new()
	part.document = DOCUMENT.new()
	root.add_child(part)
	ws.set_part(part)
	await process_frame


func _settle() -> void:
	for i in 3:
		await process_frame
	ws.viewport.fit()
	await process_frame


func _top_edges(body: String) -> Array:
	var shape: RefCounted = ws.result.bodies[body].shape
	var top: float = (shape.bbox() as AABB).end.y
	var out := []
	for e in shape.edge_count():
		var mid: Vector3 = shape.edge_info(e).midpoint
		if absf(mid.y - top) < 1e-7:
			out.append(mid)
	return out


func _picked() -> int:
	return (ws.command_values.get("edges", []) as Array).size() if ws.command != null else -1


func _camera_state() -> Array:
	return [ws.viewport.yaw, ws.viewport.pitch, ws.viewport.target, ws.viewport.distance]


func _nav_button(text: String) -> Control:
	for child in ws.viewport._nav_bar.get_children():
		if (child as Control).get("text") == text:
			return child
	return null


func _screen(p: Vector3) -> Vector2:
	return ws.viewport.global_position + ws.viewport.project(p)


func _center(c: Control) -> Vector2:
	return c.global_position + c.size * 0.5


func _mouse(at: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = at
	event.global_position = at
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	root.push_input(event)


func _move(at: Vector2, held: bool, relative := Vector2.ZERO) -> void:
	var event := InputEventMouseMotion.new()
	event.position = at
	event.global_position = at
	event.relative = relative
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
	root.push_input(event)


func _click(at: Vector2) -> void:
	_move(at, false)
	await process_frame
	_mouse(at, true)
	await process_frame
	_mouse(at, false)
	await process_frame


func _drag(from: Vector2, to: Vector2) -> void:
	_move(from, false)
	await process_frame
	_mouse(from, true)
	await process_frame
	for i in 6:
		_move(from.lerp(to, (i + 1) / 6.0), true, (to - from) / 6.0)
		await process_frame
	_mouse(to, false)
	await process_frame


func _key(code: Key) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	root.push_input(event)
	await process_frame
	var up := event.duplicate() as InputEventKey
	up.pressed = false
	root.push_input(up)
	await process_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)
		print("FAIL: ", message)
