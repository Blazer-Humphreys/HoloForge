@tool
extends RefCounted
## Real-mouse helpers for the Holo Forge editor hooks (a helper, not a test): every click, drag
## and key goes into the editor's window as Viewport.push_input events, so it takes the path a
## user's mouse takes (the window, the Forge view's overlay, _handle_at, the drag, the workspace).
##
## pull() presses on a view handle where a user would (the arrow's shaft, the dot, the ring), checks
## the press grabbed that very handle, moves with the button held and lets go; it works out what
## the drag should give from the same handle math the view uses (core/manipulator_math.gd), so a
## check can say the field and the model moved exactly as far as the mouse did. form_pull() does
## the same for the Form editor's own handles (arrows, face counts, sliders) and gizmo_pull() for
## the Edit Form gizmo.
##
## Points of the view (its own coordinates, as viewport.project() gives them) are rounded to whole
## pixels, so the event positions the view reads back are exactly the ones the expectation used.

const MANIPULATOR := preload("res://addons/holo_forge/core/manipulator_math.gd")
const UNITS := preload("res://addons/holo_forge/core/units.gd")
const FORM_GIZMO := preload("res://addons/holo_forge/ui/form_gizmo.gd")
const FORM_EDITOR := preload("res://addons/holo_forge/ui/form_editor.gd")

var ws
var gui: Viewport
var tree: SceneTree
var failures: Array[String] = []
var notes: Array[String] = []
## The section running (it heads each failure).
var section := ""
## How many handle drags were made, by section.
var pulls := {}
var _mouse := Vector2.ZERO


func _init(p_tree: SceneTree, p_ws) -> void:
	tree = p_tree
	ws = p_ws
	gui = ws.viewport.get_viewport()


# --- Reporting -----------------------------------------------------------------------------------

func check(ok: bool, detail: String) -> bool:
	if not ok:
		var text := "[%s] %s" % [section, detail]
		failures.append(text)
		push_error(text)
		print("FAIL: ", text)
	return ok


func note(text: String) -> void:
	notes.append("%s: %s" % [section, text])
	print("Forge HANDLES: [%s] %s" % [section, text])


func _counted() -> void:
	pulls[section] = int(pulls.get(section, 0)) + 1


func pull_count() -> int:
	var total := 0
	for key in pulls:
		total += int(pulls[key])
	return total


# --- Input ---------------------------------------------------------------------------------------

func frames(count: int) -> void:
	for i in count:
		await tree.process_frame


## A point of the Forge view (its own coordinates) in the editor window's.
func g(local: Vector2) -> Vector2:
	return (ws.viewport as Control).global_position + local


func center(control: Control) -> Vector2:
	return control.global_position + control.size * 0.5


func button(at: Vector2, pressed: bool, opts := {}) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = int(opts.get("button", MOUSE_BUTTON_LEFT))
	event.pressed = pressed
	event.position = at
	event.global_position = at
	event.double_click = bool(opts.get("double", false))
	event.ctrl_pressed = bool(opts.get("ctrl", false))
	event.shift_pressed = bool(opts.get("shift", false))
	event.alt_pressed = bool(opts.get("alt", false))
	event.button_mask = (MOUSE_BUTTON_MASK_RIGHT if event.button_index == MOUSE_BUTTON_RIGHT else MOUSE_BUTTON_MASK_LEFT) if pressed else 0
	_mouse = at
	gui.push_input(event, true)


func move(to: Vector2, mask := 0, opts := {}) -> void:
	gui.notification(Node.NOTIFICATION_VP_MOUSE_ENTER)
	var event := InputEventMouseMotion.new()
	event.position = to
	event.global_position = to
	event.relative = to - _mouse
	event.button_mask = mask
	event.shift_pressed = bool(opts.get("shift", false))
	event.alt_pressed = bool(opts.get("alt", false))
	event.ctrl_pressed = bool(opts.get("ctrl", false))
	_mouse = to
	gui.push_input(event, true)


func tap(at: Vector2, opts := {}) -> void:
	move(at, 0, opts)
	button(at, true, opts)
	button(at, false, opts)


## A click at a point of the window.
func click(at: Vector2, opts := {}) -> void:
	move(at, 0, opts)
	await tree.process_frame
	tap(at, opts)
	await tree.process_frame


## A click at a point of the Forge view.
func click_view(local: Vector2, opts := {}) -> void:
	await click(g(local.round()), opts)


## A real click on a control, where it is when the button goes down.
func press(control: Control, opts := {}) -> void:
	if control == null or not control.is_visible_in_tree():
		check(false, "A control to click is missing or hidden (%s)." % [control])
		return
	var holder := control.get_parent()
	while holder != null and not holder is ScrollContainer:
		holder = holder.get_parent()
	if holder != null:
		(holder as ScrollContainer).ensure_control_visible(control)
		await frames(2)
	var at := center(control)
	move(at)
	for i in 4:
		await tree.process_frame
		if center(control).is_equal_approx(at):
			break
		at = center(control)
		move(at)
	tap(at, opts)
	await tree.process_frame


func key(code: Key, opts := {}) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = pressed
		event.shift_pressed = bool(opts.get("shift", false))
		event.ctrl_pressed = bool(opts.get("ctrl", false))
		event.alt_pressed = bool(opts.get("alt", false))
		gui.push_input(event)
		await tree.process_frame


func type_text(text: String) -> void:
	for ch in text:
		for pressed in [true, false]:
			var event := InputEventKey.new()
			event.keycode = OS.find_keycode_from_string(ch)
			event.unicode = ch.unicode_at(0) if pressed else 0
			event.pressed = pressed
			gui.push_input(event)
			await tree.process_frame


## Clicks into a panel field, selects what it holds and types text over it (the panel applies each
## keystroke); enter also presses Enter, which accepts the whole panel as OK does.
func type_into(field_key: String, text: String, enter := false) -> void:
	var field := ws.panel._editors.get(field_key) as LineEdit
	if field == null or not field.is_visible_in_tree():
		check(false, "The %s field should be in the panel." % field_key)
		return
	await press(field)
	check(field.has_focus(), "A click on the %s field should give it the keyboard." % field_key)
	await key(KEY_A, {"ctrl": true})
	await type_text(text)
	if enter:
		await key(KEY_ENTER)
	await frames(3)


func focus_view() -> void:
	ws.viewport.focus_view()
	await tree.process_frame


func press_ok() -> void:
	var ok_button: Button = ws.panel.get("_ok")
	await press(ok_button)
	await frames(3)


## Esc in the view (cancels the open command or tool).
func escape() -> void:
	await focus_view()
	await key(KEY_ESCAPE)
	await frames(3)


# --- The design ----------------------------------------------------------------------------------

func undo_name() -> String:
	var history: UndoRedo = ws.history()
	return history.get_current_action_name() if history != null else ""


func action() -> int:
	var history: UndoRedo = ws.history()
	return history.get_current_action() if history != null else -1


func undo() -> void:
	ws.history().undo()
	await frames(3)


func redo() -> void:
	ws.history().redo()
	await frames(3)


## The document as text: every feature (type, label, inputs, options, suppression), the bodies,
## the assembly, appearances, analyses and images, so undo can be checked to put it back exactly.
func doc_print() -> String:
	var doc: Resource = ws.doc
	if doc == null:
		return ""
	var parts := PackedStringArray()
	for f in doc.features:
		var inputs := {}
		for key in f.inputs:
			inputs[key] = f.expression(key)
		parts.append("%s|%s|%s|%s|%s|%s" % [f.id, f.type, f.label, var_to_str(inputs), var_to_str(f.options), f.suppressed])
	parts.append(var_to_str(doc.bodies))
	parts.append(var_to_str(doc.assembly))
	parts.append(var_to_str(doc.appearances))
	parts.append(var_to_str(doc.analyses))
	parts.append(var_to_str(doc.canvases))
	parts.append(var_to_str(doc.decals))
	return "\n".join(parts)


func shape_of(body_id: String) -> RefCounted:
	var body: Variant = (ws.result.get("bodies", {}) as Dictionary).get(body_id)
	return (body as Dictionary).get("shape") if body is Dictionary else null


func volume_mm3(body_id: String) -> float:
	var shape := shape_of(body_id)
	return float(shape.volume()) * 1e9 if shape != null else -1.0


func bbox(body_id: String) -> AABB:
	var shape := shape_of(body_id)
	return shape.bbox() if shape != null else AABB()


## A panel value (an expression text) as a number in base units (NAN when it can't be read).
func value_of(field_key: String, kind: String) -> float:
	var text := str(ws.command_values.get(field_key, ""))
	var r := UNITS.evaluate(text, kind, ws.doc.units, {})
	return float(r.value) if bool(r.get("ok", false)) else NAN


## How far a dragged value may be from the exact one once written as text (4 decimals of mm or
## degrees, 6 for joint values), a little over half the last digit.
static func text_tolerance(kind: String, decimals := 4) -> float:
	var unit_step := pow(10.0, -decimals)
	if kind == UNITS.KIND_ANGLE:
		return deg_to_rad(unit_step) * 0.51
	return unit_step * 0.001 * 0.51 + 1e-12


## Checks a field shows a dragged value.
func check_value(field_key: String, kind: String, expected: float, what: String, decimals := 4) -> bool:
	var got := value_of(field_key, kind)
	return check(is_finite(got) and absf(got - expected) <= text_tolerance(kind, decimals),
		"%s: the %s field should read %s (it reads '%s')." % [what, field_key, UNITS.format_value(expected, kind, ws.doc.units, decimals), ws.command_values.get(field_key, "")])


func look(target: Vector3, yaw: float, pitch: float, distance: float) -> void:
	ws.viewport.set_view_state({"target": target, "distance": distance, "yaw": yaw, "pitch": pitch})
	await frames(3)


## Slides the view sideways (then back a little) until none of the world points is under the
## panel, the ViewCube or the edge of the view, as a user would pan to see what they click.
## Returns false when no framing tried frees them all.
func clear_view(points: Array) -> bool:
	var state: Dictionary = ws.viewport.view_state()
	var right: Vector3 = ws.viewport.camera_basis().x
	for back in [1.0, 1.4, 2.0]:
		for side in [0.0, 0.1, 0.2, 0.3, -0.1, -0.2, 0.4]:
			var d: float = float(state.distance) * back
			ws.viewport.set_view_state({"target": (state.target as Vector3) + right * d * side, "distance": d})
			await frames(2)
			var free := true
			for p in points:
				var at: Vector2 = ws.viewport.project(p)
				free = free and at.is_finite() and not covered(at)
			if free:
				return true
	ws.viewport.set_view_state(state)
	await frames(2)
	return false


## Points the view at an AABB from a direction, leaving room for the panel on the right.
func look_at_box(box: AABB, yaw := 0.7, pitch := -0.5, scale := 2.6) -> void:
	var distance := maxf(box.size.length() * scale, 0.03)
	var right := Basis.from_euler(Vector3(pitch, yaw, 0.0)).x
	await look(box.get_center() + right * distance * 0.12, yaw, pitch, distance)


# --- View handles --------------------------------------------------------------------------------

func handles() -> Array:
	return ws.viewport.get("handles")


func handle(handle_key: String, type := "") -> Dictionary:
	for h in handles():
		if str(h.get("key", "")) == handle_key and (type == "" or str(h.get("type", "")) == type):
			return h
	return {}


func handle_keys() -> Array:
	return handles().map(func(h: Dictionary) -> String: return "%s:%s" % [h.get("type", ""), h.get("key", "")])


static func same_handle(a: Dictionary, b: Dictionary) -> bool:
	return not a.is_empty() and not b.is_empty() and str(a.get("type", "")) == str(b.get("type", "")) and str(a.get("key", "")) == str(b.get("key", ""))


## True where a press in the view would land on one of its own controls (the command panel, a
## tool panel, the view cube, the navigation bar) or off the view.
func covered(local: Vector2) -> bool:
	var view: Control = ws.viewport
	if local.x < 12.0 or local.y < 12.0 or local.x > view.size.x - 12.0 or local.y > view.size.y - 12.0:
		return true
	var overs: Array = [ws.panel, view.view_cube(), view.nav_bar()]
	if ws.get("mesh_direct_edit") != null:
		overs.append(ws.mesh_direct_edit.panel)
	for over in overs:
		if over != null and is_instance_valid(over) and (over as Control).is_visible_in_tree():
			var rect := Rect2((over as Control).global_position - view.global_position, (over as Control).size).grow(4.0)
			if rect.has_point(local):
				return true
	return false


## Where a user would press to take a view handle (its arrow shaft, its dot, its ring, its slide),
## rounded to whole pixels; INF when no free point of it takes the press. A point or angle handle
## is pressed on its dot only: that is where a user aims.
func grab_point(h: Dictionary) -> Vector2:
	var shape: Dictionary = ws.viewport._handle_screen_shape(h)
	if shape.is_empty():
		return Vector2.INF
	var candidates := []
	match str(h.type):
		"arrow":
			for f in [0.6, 0.75, 0.45, 0.9, 0.3]:
				candidates.append((shape.from as Vector2).lerp(shape.to, f))
		"slide":
			for f in [0.85, 0.15, 0.7, 0.3, 0.95, 0.05]:
				candidates.append((shape.from as Vector2).lerp(shape.to, f))
		"point", "angle", "scale":
			candidates.append(shape.at)
		"ring":
			var outline: PackedVector2Array = shape.points
			for i in outline.size():
				candidates.append(outline[i])
	for c: Vector2 in candidates:
		var at := c.round()
		if covered(at):
			continue
		if same_handle(ws.viewport._handle_at(at), h):
			return at
	return Vector2.INF


## What has the press now (the view's drag: {"type": "handle", "handle", ...} during a handle drag).
func held() -> Dictionary:
	return ws.viewport.get("_drag")


## The screen direction a handle moves along at its press point: an arrow or slide along its axis,
## an angle dot round its centre (counter-clockwise on screen), a scale dot away from its centre,
## a point to the right.
func screen_along(h: Dictionary) -> Vector2:
	var shape: Dictionary = ws.viewport._handle_screen_shape(h)
	match str(h.type):
		"arrow", "slide":
			return ((shape.to as Vector2) - (shape.from as Vector2)).normalized()
		"angle":
			var r := (shape.at as Vector2) - (shape.center as Vector2)
			return Vector2(r.y, -r.x).normalized() if r.length() > 1e-6 else Vector2.RIGHT
		"scale":
			var r := (shape.at as Vector2) - (shape.center as Vector2)
			return r.normalized() if r.length() > 1e-6 else Vector2.RIGHT
	return Vector2.RIGHT


## Drags a view handle with the mouse: down on it (grab_point), moves with the button held, up.
## path: the points of the view after the press (a Vector2 is a straight drag by that many pixels
## in steps). Returns {"ok", "value" (the value the drag should give: a float, or a Vector3 for a
## point), "press", "end"}; ok is false (with a failure) when the handle could not be taken.
func pull(h: Dictionary, path: Variant, steps := 5, opts := {}) -> Dictionary:
	var what := "%s %s" % [h.get("type", ""), h.get("key", "")]
	if h.is_empty():
		check(false, "A handle to drag is missing (handles: %s)." % [handle_keys()])
		return {"ok": false}
	var at := grab_point(h)
	if not check(at.is_finite(), "The %s handle should be under the mouse somewhere a user can press it (shape %s, handles %s)." % [what, ws.viewport._handle_screen_shape(h), handle_keys()]):
		return {"ok": false}
	var points := PackedVector2Array()
	if path is Vector2:
		for i in range(1, steps + 1):
			points.append((at + (path as Vector2) * float(i) / float(steps)).round())
	else:
		for p in path:
			points.append((p as Vector2).round())
	move(g(at), 0, opts)
	await tree.process_frame
	button(g(at), true, opts)
	var drag := held()
	if not check(str(drag.get("type", "")) == "handle" and same_handle(drag.get("handle", {}), h), "A press on the %s handle at %s should take it (took %s)." % [what, at, drag]):
		button(g(at), false, opts)
		await frames(2)
		return {"ok": false}
	var grabbed: Dictionary = drag.handle
	var expected: Variant = _expected(grabbed, drag, at, points)
	for p in points:
		move(g(p), MOUSE_BUTTON_MASK_LEFT, opts)
		await tree.process_frame
	button(g(points[points.size() - 1] if not points.is_empty() else at), false, opts)
	await frames(3)
	_counted()
	return {"ok": true, "value": expected, "press": at, "end": points[points.size() - 1] if not points.is_empty() else at, "handle": grabbed}


## The value a drag of a view handle gives at its last point, as forge_viewport.gd _drag_handle()
## works it out (a ring's turn summed event by event, as the view unwraps it).
func _expected(h: Dictionary, drag: Dictionary, at: Vector2, points: PackedVector2Array) -> Variant:
	var last: Vector2 = points[points.size() - 1] if not points.is_empty() else at
	var ray: Array = ws.viewport.ray_from(last)
	match str(h.type):
		"arrow":
			var t := MANIPULATOR.closest_on_line(h.origin, h.direction, ray[0], ray[1])
			if is_nan(t) or is_nan(float(drag.start_t)):
				return float(h.get("base", 0.0))
			return maxf(float(h.base) + (t - float(drag.start_t)) * float(h.get("factor", 1.0)), float(h.get("min", 0.00001)))
		"slide":
			var t := MANIPULATOR.closest_on_line(h.origin, h.direction, ray[0], ray[1])
			return float(h.get("base", 0.0)) + t - float(drag.start_t)
		"scale":
			# The ratio each of its "bases" is multiplied by.
			var t := MANIPULATOR.closest_on_line(h.origin, h.direction, ray[0], ray[1])
			if is_nan(t) or absf(float(drag.start_t)) < 1e-12:
				return 1.0
			return maxf(t / float(drag.start_t), float(h.get("min_ratio", 0.01)))
		"angle":
			var angle := MANIPULATOR.angle_on_plane(h.origin, h.axis, h.start, ray[0], ray[1])
			return float(h.get("base", 0.0)) + angle
		"point":
			var hit: Variant = MANIPULATOR.on_plane(h.position, h.normal, ray[0], ray[1])
			return MANIPULATOR.snap(hit, ws.viewport.snap_step) if hit is Vector3 else h.position
		"ring":
			var turned := 0.0
			var previous := 0.0
			for p in points:
				var r: Array = ws.viewport.ray_from(p)
				var angle := MANIPULATOR.angle_on_plane(h.origin, h.axis, drag.start_vector, r[0], r[1])
				if is_nan(angle):
					continue
				turned += wrapf(angle - previous, -PI, PI)
				previous = angle
			return float(h.get("base", 0.0)) + turned
	return null


## A drag along a ring handle's outline: from where it is grabbed, count segments on (48 to a turn).
func ring_path(h: Dictionary, count: int) -> PackedVector2Array:
	var shape: Dictionary = ws.viewport._handle_screen_shape(h)
	var outline: PackedVector2Array = shape.get("points", PackedVector2Array())
	var at := grab_point(h)
	var start := 0
	for i in outline.size():
		if outline[i].round() == at:
			start = i
			break
	var out := PackedVector2Array()
	for k in range(1, count + 1):
		var i := start + k
		if outline.size() > 1:
			# (The outline is closed: its last point repeats the first.)
			i = i % (outline.size() - 1)
		out.append(outline[i])
	return out


# --- Form editor handles -------------------------------------------------------------------------

func form_handles() -> Array:
	return ws.form_editor.get("_handles")


func form_handle(handle_key: String) -> Dictionary:
	for h in form_handles():
		if str(h.get("key", "")) == handle_key:
			return h
	return {}


## Where a user would press a Form tool handle: an arrow's shaft, a count's or slider's knob.
func form_grab_point(h: Dictionary) -> Vector2:
	var editor = ws.form_editor
	var shape: Dictionary = editor._handle_shape(h)
	if shape.is_empty():
		return Vector2.INF
	var candidates := []
	if str(h.type) == "arrow":
		for f in [0.7, 0.55, 0.85, 0.4]:
			candidates.append((shape.from as Vector2).lerp(shape.to, f))
	else:
		candidates.append(shape.at)
	for c: Vector2 in candidates:
		var at := c.round()
		if covered(at):
			continue
		if same_handle(editor._handle_at(at), h):
			return at
	return Vector2.INF


## Drags a Form tool handle by pixels along its own screen direction (an arrow or a count) or
## along the slider's track; returns {"ok", "value"}: the text the tool's field should then hold.
func form_pull(h: Dictionary, pixels: float, steps := 5) -> Dictionary:
	var editor = ws.form_editor
	var what := "%s %s" % [h.get("type", ""), h.get("key", "")]
	var at := form_grab_point(h)
	if not check(at.is_finite(), "The Form %s handle should be under the mouse somewhere a user can press it (%s)." % [what, editor._handle_shape(h)]):
		return {"ok": false}
	var shape: Dictionary = editor._handle_shape(h)
	var along: Vector2 = shape.get("dir", Vector2.ZERO)
	if shape.has("from"):
		along = ((shape.to as Vector2) - (shape.from as Vector2)).normalized()
	var points := PackedVector2Array()
	for i in range(1, steps + 1):
		points.append((at + along * pixels * float(i) / float(steps)).round())
	move(g(at))
	await tree.process_frame
	button(g(at), true)
	var drag: Dictionary = editor.get("_drag")
	if not check(str(drag.get("type", "")) == "tool_handle" and same_handle(drag.get("handle", {}), h), "A press on the Form %s handle should take it (took %s)." % [what, drag]):
		button(g(at), false)
		await frames(2)
		return {"ok": false}
	var expected := _form_expected(drag, at, points[points.size() - 1])
	for p in points:
		move(g(p), MOUSE_BUTTON_MASK_LEFT)
		await tree.process_frame
	button(g(points[points.size() - 1]), false)
	await frames(3)
	_counted()
	return {"ok": true, "value": expected}


## The field text a Form tool handle drag gives (form_editor.gd _tool_handle_motion()).
func _form_expected(drag: Dictionary, start: Vector2, last: Vector2) -> String:
	var editor = ws.form_editor
	var h: Dictionary = drag.handle
	var ui := float(editor._ui_scale())
	if str(h.type) == "count":
		var shape: Dictionary = editor._handle_shape(h)
		var dir: Vector2 = shape.get("dir", Vector2.RIGHT)
		var steps := roundi((last - start).dot(dir) / (FORM_EDITOR.COUNT_PX * ui))
		return str(clampi(int(drag.base) + steps, 1, 64))
	var ray: Array = ws.viewport.ray_from(last)
	var t := MANIPULATOR.closest_on_line(h.origin, h.direction, ray[0], ray[1])
	if str(h.type) == "slider":
		var span := (h.direction as Vector3).length()
		return "%.3f" % clampf(float(drag.base) + (t - float(drag.t0)) / span, float(h.get("min", 0.0)), float(h.get("max", 1.0)))
	var value := float(drag.base) + (t - float(drag.t0)) * float(h.get("factor", 1.0))
	if str(h.get("kind", "length")) == "number":
		return "%.4g" % clampf(value, float(h.get("min", -INF)), float(h.get("max", INF)))
	value = clampf(value, float(h.get("min", 1e-6)), float(h.get("max", INF)))
	var snap: float = ws.viewport.snap_step
	if snap > 0.0:
		value = maxf(snappedf(value, snap), snap)
	return UNITS.format_value(value, UNITS.KIND_LENGTH, editor.units())


# --- The Edit Form gizmo -------------------------------------------------------------------------

## Where a user would press a part of the Edit Form gizmo (ui/form_gizmo.gd: move_x, plane_xy,
## rot_z, scale_y, pscale_zx, uniform, ...): on the arrow's shaft, inside the square, on the
## bracket, the bar, the ring or the centre, rounded; INF when no free point of it takes the press.
func gizmo_grab_point(id: String) -> Vector2:
	var gz = ws.form_editor.gizmo
	var view = ws.viewport
	if not gz.visible:
		return Vector2.INF
	var wpp: float = gz.world_per_px(view)
	var c: Vector2 = view.project(gz.pivot)
	var candidates := []
	var kind := id.get_slice("_", 0)
	var key := id.get_slice("_", 1)
	var i := "xyz".find(key) if key.length() == 1 else -1
	match kind:
		"move":
			var tip: Vector2 = gz._arrow_tip(view, i, wpp)
			for f in [0.75, 0.6, 0.9, 0.5, 1.05]:
				candidates.append(c.lerp(tip, f))
		"plane":
			var quad: PackedVector2Array = gz._plane_quad(view, key, wpp)
			if quad.size() == 4:
				var mid := (quad[0] + quad[1] + quad[2] + quad[3]) * 0.25
				candidates.append(mid)
				for q in quad:
					candidates.append(mid.lerp(q, 0.5))
		"pscale":
			for seg in gz._bracket(view, key, wpp):
				for f in [0.5, 0.25, 0.75]:
					candidates.append((seg[0] as Vector2).lerp(seg[1], f))
		"scale":
			var dash: Array = gz._scale_dash(view, i, wpp)
			for f in [0.5, 0.3, 0.7]:
				if dash.size() == 2:
					candidates.append((dash[0] as Vector2).lerp(dash[1], f))
		"rot":
			for q in MANIPULATOR.ring_points(gz.pivot, gz.axis(i), FORM_GIZMO.RING_PX * float(gz.px) * wpp, 48):
				candidates.append(view.project(q))
		"uniform":
			candidates.append(c)
	for p: Vector2 in candidates:
		if not p.is_finite():
			continue
		var at := p.round()
		if not covered(at) and gz.hit(view, at) == id:
			return at
	return Vector2.INF


## The screen path a gizmo drag takes from its press: along an arrow or bar, across a square or
## bracket's diagonal, round the pivot for a ring (by angle radians), right for the centre circle.
func gizmo_path(id: String, at: Vector2, pixels: float, steps := 6) -> PackedVector2Array:
	var gz = ws.form_editor.gizmo
	var view = ws.viewport
	var c: Vector2 = view.project(gz.pivot)
	var points := PackedVector2Array()
	var kind := id.get_slice("_", 0)
	var dir := Vector2.RIGHT
	match kind:
		"move", "scale":
			dir = (at - c).normalized()
		"plane", "pscale":
			var axes: Array = FORM_GIZMO.PLANES[id.get_slice("_", 1)]
			var u: Vector2 = view.project(gz.pivot + gz.axis(axes[0]) * 0.01) - c
			var v: Vector2 = view.project(gz.pivot + gz.axis(axes[1]) * 0.01) - c
			dir = (u.normalized() + v.normalized()).normalized()
		"rot":
			var r := at - c
			var angle := pixels / maxf(r.length(), 1.0)
			for k in range(1, steps + 1):
				points.append((c + r.rotated(angle * float(k) / float(steps))).round())
			return points
	for k in range(1, steps + 1):
		points.append((at + dir * pixels * float(k) / float(steps)).round())
	return points


## Drags a part of the Edit Form gizmo with the mouse (gizmo_grab_point, then gizmo_path); checks
## the press took that part. Returns {"ok", "xf": the transform the gizmo's own math gives for the
## drag's last point (drag_xf, 12 doubles), "bodies": the drag's start cages and moving vertices
## (form_editor.gd _prepare_drag_bodies)}.
func gizmo_pull(id: String, pixels: float, opts := {}) -> Dictionary:
	var editor = ws.form_editor
	var at := gizmo_grab_point(id)
	if not check(at.is_finite(), "The gizmo's %s should be under the mouse somewhere a user can press it (pivot %s)." % [id, ws.viewport.project(editor.gizmo.pivot)]):
		return {"ok": false}
	var points := gizmo_path(id, at, pixels)
	move(g(at), 0, opts)
	await tree.process_frame
	button(g(at), true, opts)
	var drag: Dictionary = editor.get("_drag")
	if not check(str(drag.get("type", "")) == "gizmo" and str(drag.get("handle", "")) == id, "A press on the gizmo's %s should take it (took %s)." % [id, drag.get("handle", drag.get("type", ""))]):
		button(g(at), false, opts)
		await frames(2)
		return {"ok": false}
	var bodies: Dictionary = drag.get("bodies", {})
	var xf: PackedFloat64Array = editor.gizmo.drag_xf(drag.state, ws.viewport, points[points.size() - 1], bool(opts.get("shift", false)), float(ws.viewport.snap_step))
	for p in points:
		move(g(p), MOUSE_BUTTON_MASK_LEFT, opts)
		await tree.process_frame
	button(g(points[points.size() - 1]), false, opts)
	await frames(3)
	_counted()
	return {"ok": true, "xf": xf, "bodies": bodies}


# --- Window --------------------------------------------------------------------------------------

## The editor's windows that are showing (for a failure message).
func open_windows() -> Array:
	var found := []
	for node in EditorInterface.get_base_control().get_window().find_children("*", "Window", true, false):
		if (node as Window).visible:
			found.append(str(node.name) + ":" + node.get_class())
	return found
