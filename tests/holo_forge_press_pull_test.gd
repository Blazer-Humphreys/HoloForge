extends SceneTree
## Press Pull on a sketch profile, with real mouse and key events: in an empty design it makes a
## new body (it failed as "The join doesn't touch any solid body"), sized by dragging its distance
## arrow; on a box's top face it joins the box; beside a box it makes a body of its own. The
## feature edits from the timeline with its automatic operation shown as what it did (New Body),
## and one saved as Join before (with nothing to join) opens as that and builds. The distance
## field's grey hint stays empty while the field reads just its value.
##
## godot --headless --path . --script res://tests/holo_forge_press_pull_test.gd

const WORKSPACE := preload("res://addons/holo_forge/ui/forge_workspace.gd")
const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const CATALOG := preload("res://addons/holo_forge/tools/catalog.gd")
const SKETCH := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")

var failures: Array[String] = []
var ws: Control


func _init() -> void:
	call_deferred("run")


func run() -> void:
	create_timer(180.0).timeout.connect(func() -> void:
		print("FAIL holo_forge_press_pull: timed out ", failures)
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
		await _check_empty_design()
		await _check_on_and_beside_a_box()
		await _check_old_join()
	print("PASS holo_forge_press_pull: a profile Press Pull makes a new body in an empty design (dragged by its arrow), joins a box it sits on, makes its own body beside one, edits showing New Body (its automatic operation), an old Join one opens as that and builds, and the distance hint stays quiet." \
		if failures.is_empty() else "FAIL holo_forge_press_pull")
	quit(0 if failures.is_empty() else 1)


## A 40 x 20 mm rectangle on the ground, Press Pull, a click inside, a drag of the arrow, Enter.
func _check_empty_design() -> void:
	await _new_part()
	await _rectangle(SKETCH.ORIGIN_PLANES.xz, "xz", Vector3(-0.02, 0, 0.01), Vector3(0.02, 0, -0.01))
	ws.run_tool(CATALOG.find("solid.modify.press_pull"))
	await _frames(2)
	await _click(_screen(Vector3(0.005, 0, -0.003)))
	_expect(ws.command != null and ws.command.feature != null and ws.command.feature.type == "extrude", "A click inside the rectangle should make the Press Pull an extrude (%s)." % [ws.command.feature.type if ws.command != null and ws.command.feature != null else "none"])
	if ws.command == null:
		return
	_expect(str(ws.command.feature.options.get("operation", "")) == OPERATIONS.AUTO, "A profile Press Pull should take the automatic operation (%s)." % ws.command.feature.options.get("operation", ""))
	await _frames(2)
	var arrow: Dictionary = {}
	for handle in ws.viewport.handles:
		if str(handle.get("key", "")) == "distance":
			arrow = handle
	_expect(not arrow.is_empty(), "The distance arrow should show.")
	if arrow.is_empty():
		return
	var shape: Dictionary = ws.viewport._handle_screen_shape(arrow)
	var from: Vector2 = ws.viewport.global_position + (shape.from as Vector2).lerp(shape.to, 0.6)
	var along: Vector2 = ((shape.to as Vector2) - (shape.from as Vector2)).normalized()
	await _drag(from, from + along * 90.0)
	var text := str(ws.panel.values.get("distance", ""))
	await _key(KEY_ENTER)
	await _frames(3)
	var bodies: Dictionary = ws.result.get("bodies", {})
	var feature: Resource = ws.doc.features.back()
	var error := str(ws.result.get("errors", {}).get(feature.id, ""))
	_expect(error == "" and bodies.size() == 1, "Press Pull in an empty design should make one body (error '%s', %d bodies)." % [error, bodies.size()])
	var dragged := _length_of(text)
	_expect(dragged > 0.0001, "Dragging the arrow should set a distance (%s)." % text)
	for id in bodies:
		var volume: float = bodies[id].shape.volume()
		_expect(absf(volume - 0.04 * 0.02 * dragged) <= 1e-9 * maxf(1.0, volume * 1e6), "The body should be 40 x 20 mm x the dragged %s (%.6f mm3)." % [text, volume * 1e9])
		_expect(ws.doc.bodies.has(id), "The new body should be registered (named %s)." % ws.doc.body_name(id))
	# From the timeline it edits as Extrude: the automatic operation shows as what it did, New Body.
	ws.edit_feature(feature.id)
	await _frames(2)
	var option := ws.panel._editors.get("operation") as OptionButton
	_expect(option != null and option.get_item_text(option.selected) == "New Body" and str(feature.options.get("operation", "")) == OPERATIONS.AUTO, "Editing it should show New Body, still automatic (%s)." % (option.get_item_text(option.selected) if option != null else "no field"))
	ws.accept_command()
	await _frames(2)
	_expect(str(ws.result.get("errors", {}).get(feature.id, "")) == "" and ws.result.bodies.size() == 1, "OK on the edit should keep the body (%s)." % ws.result.get("errors", {}))
	# The grey hint beside Distance says nothing while the field holds just a value.
	ws.run_tool(CATALOG.find("solid.create.extrude"))
	await _frames(2)
	var hint := ws.panel._hints.get("distance") as Label
	_expect(hint != null and hint.text == "", "The distance hint should be empty for a plain value ('%s')." % (hint.text if hint != null else "none"))
	var distance_field := ws.panel._editors.get("distance") as LineEdit
	if distance_field != null and hint != null:
		distance_field.text = "10 mm * 2"
		distance_field.text_changed.emit(distance_field.text)
		await _frames(2)
		_expect(hint.text.begins_with("20"), "An expression's hint should show its value ('%s')." % hint.text)
	ws.cancel_command()
	await _frames(1)


## A rectangle on a 50 mm box's top face joins it; one on the ground beside the box is its own body.
func _check_on_and_beside_a_box() -> void:
	await _new_part()
	ws.run_tool(CATALOG.find("solid.create.box"))
	ws.accept_command()
	await _frames(2)
	var box := str(ws.result.bodies.keys()[0])
	var shape: RefCounted = ws.result.bodies[box].shape
	var top: float = (shape.bbox() as AABB).end.y
	var before: float = shape.volume()
	await _rectangle(SKETCH.face_plane(Vector3(0, top, 0), Vector3.UP), "", Vector3(-0.01, top, 0.005), Vector3(0.01, top, -0.005))
	await _pull(Vector3(0.002, top, -0.001), "5")
	_expect(ws.result.bodies.size() == 1, "On the box's top face the Press Pull should join it (%d bodies, %s)." % [ws.result.bodies.size(), ws.result.get("errors", {})])
	_expect(absf(float(ws.result.bodies[box].shape.volume()) - (before + 0.02 * 0.01 * 0.005)) < 1e-12, "The box should grow by 20 x 10 x 5 mm.")
	var far := (shape.bbox() as AABB).end.x + 0.03
	await _rectangle(SKETCH.ORIGIN_PLANES.xz, "xz", Vector3(far, 0, 0.005), Vector3(far + 0.02, 0, -0.005))
	await _pull(Vector3(far + 0.01, 0, 0.001), "5")
	_expect(ws.result.bodies.size() == 2 and ws.result.get("errors", {}).is_empty(), "Beside the box the Press Pull should make its own body (%d bodies, %s)." % [ws.result.bodies.size(), ws.result.get("errors", {})])


## A profile Press Pull saved as Join before Auto, with nothing to join: the error says how to fix
## it, and opening it from the timeline makes it the automatic operation, which builds.
func _check_old_join() -> void:
	await _new_part()
	await _rectangle(SKETCH.ORIGIN_PLANES.xz, "xz", Vector3(-0.02, 0, 0.01), Vector3(0.02, 0, -0.01))
	await _pull(Vector3(0.005, 0, -0.003), "10")
	var feature: Resource = ws.doc.features.back()
	ws.change("Old Join", func() -> void:
		feature.options["operation"] = OPERATIONS.JOIN
		var old_body := str(feature.options.get("body_id", ""))
		ws.doc.bodies.erase(old_body)
		feature.options["body_id"] = "")
	await _frames(2)
	var error := str(ws.result.get("errors", {}).get(feature.id, ""))
	_expect(error.contains("double-click"), "An old Join with nothing to join should say how to fix it ('%s')." % error)
	ws.edit_feature(feature.id)
	await _frames(2)
	_expect(str(feature.options.get("operation", "")) == OPERATIONS.AUTO, "Opening it should switch it to the automatic operation (%s)." % feature.options.get("operation", ""))
	ws.accept_command()
	await _frames(2)
	_expect(ws.result.get("errors", {}).is_empty() and ws.result.bodies.size() == 1, "Then it should build its body (%s)." % ws.result.get("errors", {}))


# --- Helpers ----------------------------------------------------------------------------------

func _new_part() -> void:
	if ws.command != null:
		ws.cancel_command()
	if ws.sketch_editor.active:
		ws.run_action("finish_sketch")
	var part: Node3D = CAD_PART.new()
	part.document = DOCUMENT.new()
	root.add_child(part)
	ws.set_part(part)
	await _frames(3)


func _rectangle(frame: Dictionary, ref: String, a: Vector3, b: Vector3) -> void:
	ws.create_sketch(frame, ref)
	await _frames(2)
	ws.viewport.fit()
	await _frames(2)
	ws.run_tool(CATALOG.find("sketch.create.2-point_rectangle"))
	await _frames(1)
	await _click(_screen(a))
	await _click(_screen(b))
	await _key(KEY_ESCAPE)
	ws.run_action("finish_sketch")
	await _frames(2)
	ws.viewport.fit()
	await _frames(2)


## Press Pull: a click at inside, the distance typed, Enter.
func _pull(inside: Vector3, distance: String) -> void:
	ws.run_tool(CATALOG.find("solid.modify.press_pull"))
	await _frames(2)
	await _click(_screen(inside))
	var field := ws.panel._editors.get("distance") as LineEdit
	if field != null:
		await _click(field.global_position + field.size * 0.5)
		await _key(KEY_A, true)
		for ch in distance:
			var event := InputEventKey.new()
			event.keycode = OS.find_keycode_from_string(ch)
			event.unicode = ch.unicode_at(0)
			event.pressed = true
			root.push_input(event)
			await process_frame
	await _key(KEY_ENTER)
	await _frames(3)


func _length_of(text: String) -> float:
	var number := text.replace("mm", "").strip_edges()
	return float(number) / 1000.0 if number.is_valid_float() else 0.0


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _screen(p: Vector3) -> Vector2:
	return ws.viewport.global_position + ws.viewport.project(p)


func _mouse(at: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = at
	event.global_position = at
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	root.push_input(event)


func _move(at: Vector2, held := false, relative := Vector2.ZERO) -> void:
	var event := InputEventMouseMotion.new()
	event.position = at
	event.global_position = at
	event.relative = relative
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
	root.push_input(event)


func _click(at: Vector2) -> void:
	_move(at)
	await process_frame
	_mouse(at, true)
	await process_frame
	_mouse(at, false)
	await process_frame


func _drag(from: Vector2, to: Vector2) -> void:
	_move(from)
	await process_frame
	_mouse(from, true)
	await process_frame
	for i in 8:
		_move(from.lerp(to, (i + 1) / 8.0), true, (to - from) / 8.0)
		await process_frame
	_mouse(to, false)
	await process_frame


func _key(code: Key, ctrl := false) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.ctrl_pressed = ctrl
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
