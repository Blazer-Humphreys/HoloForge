@tool
extends "res://addons/holo_forge/tools/inspect_command.gd"
## Canvas and Decal: a reference image on a plane (a doc.canvases entry, shown in the Forge view
## only) and an image projected onto a body's face (a doc.decals entry, baked by the CadPart as a
## Godot Decal under the body). Like analyses, the entry is added when the command starts and
## shows at once; OK keeps it as one undo step, Cancel takes it out. Double-clicking it in the
## browser opens the same panel. entry.panel keeps the panel's own values for that.
##
## Canvas calibration: tick Calibrate, click two points on the canvas (or type them), enter their
## real distance and press Calibrate: the canvas scales about the first point to match.
##
## Images stay on their geometry: a decal's position is always a point of its face (a dragged or
## typed one is moved onto it), and after every rebuild follow_geometry() puts each decal back on
## its face and moves each canvas with its picked plane, as fasteners follow theirs.

const INSPECT := preload("res://addons/holo_forge/core/inspect.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const APPEARANCE := preload("res://addons/holo_forge/core/appearance.gd")

const OUTLINE := Color(0.95, 0.55, 0.15)
const GROUND := {"origin": Vector3.ZERO, "normal": Vector3.UP, "x": Vector3.RIGHT}
## How far (meters) a decal may be from where its face puts it before it is moved there.
const MOVE_TOLERANCE := 1e-7

## "canvas" or "decal".
var type := "canvas"
## The doc.canvases / doc.decals entry this command edits.
var entry_id := ""
## Calibration clicks still to take on the canvas (0 when not picking).
var _calibration_clicks := 0
## Why the last face pick was refused (a decal can't sit on a mesh body), shown in the readout.
var _gate_note := ""


func _init(p_type := "insert:canvas") -> void:
	type = p_type.trim_prefix("insert:")


## The document list an image type lives in: "canvases" or "decals".
static func list_name(image_type: String) -> String:
	return "decals" if image_type == "decal" else "canvases"


## A new entry with a fresh id and a numbered name ("Canvas1", "Decal2"), shown.
static func new_entry(doc: Resource, image_type: String) -> Dictionary:
	var n: int = doc.next_number(image_type)
	return {"id": "%s%d" % [image_type, n], "name": "%s%d" % [image_type.capitalize(), n], "image": "", "visible": true}


## Keeps doc's images on the geometry of a new regen result (call it after every rebuild, before
## the view and the part show them): each decal goes where the bake puts it
## (APPEARANCE.placed_decal: the point of its face nearest where it was, facing the face's normal
## there), and each canvas on a picked plane moves and turns with that plane (its calibration
## points too). Origin-plane canvases, and images whose geometry didn't move, stay exactly as
## they are. Returns the names of the images whose face or plane can't be found any more: they
## stay where they were.
static func follow_geometry(doc: Resource, result: Dictionary, kernel: RefCounted) -> PackedStringArray:
	var lost := PackedStringArray()
	if doc == null or kernel == null:
		return lost
	var ctx := INSPECT.context(result, doc, kernel)
	for entry in doc.decals:
		if str(entry.get("body", "")) == "":
			continue
		var placed := _placed_decal(entry, result, kernel)
		if bool(placed.get("lost", false)):
			lost.append(str(entry.get("name", "")))
			continue
		var was: Vector3 = entry.get("position", Vector3.ZERO)
		var at: Vector3 = placed.get("position", was)
		var normal: Vector3 = placed.get("normal", entry.get("normal", Vector3.UP))
		if at.distance_to(was) <= MOVE_TOLERANCE and normal.is_equal_approx(entry.get("normal", Vector3.ZERO)):
			continue
		entry["position"] = at
		entry["normal"] = normal
		var panel: Dictionary = entry.get("panel", {})
		if panel.has("position"):
			panel["position"] = at
	for entry in doc.canvases:
		var refs: Array = (entry.get("panel", {}) as Dictionary).get("plane", [])
		if refs.is_empty() or not refs[0] is Dictionary:
			continue
		var plane := REFERENCES.plane(refs[0], ctx)
		if plane.has("error"):
			lost.append(str(entry.get("name", "")))
			continue
		var frame := {"origin": plane.origin, "normal": plane.normal, "x": plane.x}
		var old: Dictionary = entry.get("frame", {})
		if old == frame:
			continue
		entry["frame"] = frame
		if old.is_empty():
			# Saved before canvases remembered their plane: they follow it from now on.
			continue
		var move := _frame_transform(frame) * _frame_transform(old).affine_inverse()
		entry["origin"] = move * (entry.get("origin", Vector3.ZERO) as Vector3)
		entry["x"] = (move.basis * (entry.get("x", Vector3.RIGHT) as Vector3)).normalized()
		entry["y"] = (move.basis * (entry.get("y", Vector3.FORWARD) as Vector3)).normalized()
		var panel: Dictionary = entry.get("panel", {})
		for key in ["center", "cal_a", "cal_b"]:
			if panel.get(key) is Vector3:
				panel[key] = move * (panel[key] as Vector3)
	return lost


func title() -> String:
	return type.capitalize()


func changes_document() -> bool:
	return true


func action_name() -> String:
	return ("Edit " if editing else "Insert ") + title()


func fields() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var calibrating := {"calibrate": [true]}
	if type == "canvas":
		result.append({"key": "plane", "label": "Plane", "type": "selection", "filter": ["plane"], "single": true})
	else:
		result.append({"key": "face", "label": "Face", "type": "selection", "filter": ["face"], "single": true})
		result.append({"key": "position", "label": "Position", "type": "point"})
	result.append({"key": "image", "label": "Image", "type": "text"})
	result.append({"key": "browse", "label": "Choose Image...", "type": "button", "tooltip": "Pick an image file"})
	result.append({"key": "width", "label": "Width", "type": "expression", "kind": "length"})
	result.append({"key": "height", "label": "Height", "type": "expression", "kind": "length"})
	if type == "canvas":
		result.append({"key": "center", "label": "Center", "type": "point"})
	result.append({"key": "rotation", "label": "Rotation", "type": "expression", "kind": "angle"})
	if type == "canvas":
		result.append({"key": "opacity", "label": "Opacity (0 to 1)", "type": "expression", "kind": "number"})
		result.append({"key": "through", "label": "See Through Bodies", "type": "bool"})
		result.append({"key": "calibrate", "label": "Calibrate", "type": "bool"})
		result.append({"key": "cal_a", "label": "First Point", "type": "point", "visible_if": calibrating})
		result.append({"key": "cal_b", "label": "Second Point", "type": "point", "visible_if": calibrating})
		result.append({"key": "cal_distance", "label": "Real Distance", "type": "expression", "kind": "length", "visible_if": calibrating})
		result.append({"key": "pick_points", "label": "Click Two Points on the Canvas", "type": "button", "visible_if": calibrating})
		result.append({"key": "apply_calibration", "label": "Calibrate to the Real Distance", "type": "button", "visible_if": calibrating})
	else:
		result.append({"key": "flip", "label": "Flip (mirror)", "type": "bool"})
	result.append({"key": "result", "type": "info", "text": ""})
	return result


func defaults() -> Dictionary:
	var size := str(hints.get("default_size", "50"))
	if type == "decal":
		var quarter := UNITS.format_value(float(hints.get("default_size_m", 0.05)) * 0.25, UNITS.KIND_LENGTH, doc_units()).split(" ")[0]
		return {"face": [], "position": Vector3.ZERO, "image": "", "width": quarter, "height": quarter, "rotation": "0", "flip": false}
	return {
		"plane": [], "image": "", "width": size, "height": size, "center": Vector3.ZERO, "rotation": "0", "opacity": "0.5",
		"through": false, "calibrate": false, "cal_a": Vector3.ZERO, "cal_b": Vector3.ZERO, "cal_distance": size,
	}


func create_feature(doc: Resource, values: Dictionary) -> Resource:
	var created := new_entry(doc, type)
	entry_id = created.id
	_list(doc).append(created)
	write_values(doc, values)
	return null


func read_values() -> Dictionary:
	var values := defaults()
	var stored: Dictionary = entry().get("panel", {})
	for key in stored:
		var value: Variant = stored[key]
		values[key] = value.duplicate(true) if value is Array or value is Dictionary else value
	current_values = values.duplicate(true)
	return values


func write_values(doc: Resource, values: Dictionary) -> void:
	var target := entry()
	if target.is_empty():
		current_values = values.duplicate(true)
		return
	var before: Dictionary = target.get("panel", {})
	var moved := false
	if type == "canvas":
		# A new plane puts the canvas on that plane's origin.
		if str(values.get("plane", [])) != str(before.get("plane", [])):
			values["center"] = _plane_frame(values).origin
			moved = true
		_write_canvas(target, values)
	else:
		# A decal sits on a B-rep face: a pick on a mesh body is refused in one sentence, and the
		# decal keeps the face it had.
		var gate := _mesh_pick_gate(values)
		_gate_note = gate
		if gate != "":
			values["face"] = (before.get("face", []) as Array).duplicate(true)
			moved = true
			if workspace != null:
				workspace.flash(gate)
		elif str(values.get("face", [])) != str(before.get("face", [])):
			var placed := _face_point(values)
			if not placed.is_empty():
				values["position"] = placed.position
				moved = true
		moved = _write_decal(target, values) or moved
	target["image"] = str(values.get("image", "")).strip_edges()
	target["panel"] = values.duplicate(true)
	current_values = values.duplicate(true)
	if moved and workspace != null:
		workspace.panel.set_values(values)


## Why the picked face can't take a decal ("" when it can, or nothing is picked): it lies on a
## mesh body (APPEARANCE.decal_gate).
func _mesh_pick_gate(values: Dictionary) -> String:
	var refs: Array = values.get("face", [])
	if refs.is_empty() or not refs[0] is Dictionary or workspace == null:
		return ""
	var body: Dictionary = (workspace.result.get("bodies", {}) as Dictionary).get(str(refs[0].get("body", "")), {})
	return APPEARANCE.decal_gate(body.get("shape")) if not body.is_empty() else ""


## The entry being edited ({} when it is gone).
func entry() -> Dictionary:
	if workspace == null or workspace.doc == null:
		return {}
	for e in _list(workspace.doc):
		if str(e.get("id", "")) == entry_id:
			return e
	return {}


func accept_error() -> String:
	var target := entry()
	if str(target.get("image", "")) == "":
		return "Choose an image for the %s." % type
	if type == "decal" and str(target.get("body", "")) == "":
		return "Pick a face for the decal."
	return ""


func update() -> void:
	workspace.panel.set_info("result", describe())


## The panel's readout: what the entry is and where.
func describe() -> String:
	var target := entry()
	var size: Vector2 = target.get("size", Vector2.ZERO)
	var lines := PackedStringArray()
	if str(target.get("image", "")) == "":
		lines.append("Choose an image.")
	elif workspace.image_texture(str(target.image)) == null:
		lines.append("%s can't be read as an image." % str(target.image).get_file())
	lines.append("%s x %s" % [length_text(absf(size.x)), length_text(absf(size.y))])
	if type == "decal":
		if _gate_note != "":
			lines.append(_gate_note)
		lines.append("On %s" % workspace.doc.body_name(str(target.body)) if str(target.get("body", "")) != "" else "Pick a face.")
		if str(target.get("body", "")) != "" and bool(_placed_decal(target, workspace.result, workspace.kernel).get("lost", false)):
			lines.append("Its face can't be found any more, so it stays where it was; pick a face.")
	elif _calibration_clicks > 0:
		lines.append("Click the %s point on the canvas." % ("first" if _calibration_clicks == 2 else "second"))
	elif bool(current_values.get("calibrate", false)):
		var a: Vector3 = current_values.get("cal_a", Vector3.ZERO)
		var b: Vector3 = current_values.get("cal_b", Vector3.ZERO)
		lines.append("The points are %s apart." % length_text(a.distance_to(b)))
	return "\n".join(lines)


func on_button(key: String) -> void:
	match key:
		"browse":
			workspace.files.choose_image(set_image)
		"pick_points":
			_calibration_clicks = 2
			update()
			workspace.flash("Click the first point on the canvas.")
		"apply_calibration":
			calibrate()


## Uses an image file; the width stays and the height follows the image's proportions.
func set_image(path: String) -> void:
	var values: Dictionary = workspace.command_values.duplicate(true)
	values["image"] = path
	var texture: Texture2D = workspace.image_texture(path)
	if texture != null and texture.get_width() > 0:
		var width := number(values, "width", UNITS.KIND_LENGTH, 0.05)
		var height := width * float(texture.get_height()) / float(texture.get_width())
		values["height"] = UNITS.format_value(height, UNITS.KIND_LENGTH, doc_units()).split(" ")[0]
	workspace.set_command_values(values)


## Canvas calibration: scales the canvas about the first point so the two points lie the real
## distance apart. Returns false (and says why) when it can't.
func calibrate() -> bool:
	var values: Dictionary = workspace.command_values.duplicate(true)
	var a: Vector3 = values.get("cal_a", Vector3.ZERO)
	var b: Vector3 = values.get("cal_b", Vector3.ZERO)
	var measured := a.distance_to(b)
	var real := number(values, "cal_distance", UNITS.KIND_LENGTH, 0.0)
	if measured < 1e-9 or real <= 0.0:
		workspace.flash("Calibrate: pick two different points and type their real distance.")
		return false
	var factor := real / measured
	for key in ["width", "height"]:
		var meters := number(values, key, UNITS.KIND_LENGTH, 0.0) * factor
		values[key] = UNITS.format_value(meters, UNITS.KIND_LENGTH, doc_units()).split(" ")[0]
	values["center"] = a + ((values.get("center", Vector3.ZERO) as Vector3) - a) * factor
	values["cal_b"] = a + (b - a) * factor
	workspace.set_command_values(values)
	workspace.flash("Canvas scaled by %s." % significant(factor))
	return true


## Calibration clicks land on the canvas plane (the workspace asks commands first).
func handle_mouse(event: InputEvent) -> bool:
	if type != "canvas" or _calibration_clicks <= 0:
		return false
	var button := event as InputEventMouseButton
	if button == null:
		return event is InputEventMouseMotion
	if button.button_index != MOUSE_BUTTON_LEFT:
		return false
	if not button.pressed:
		return true
	var target := entry()
	var x: Vector3 = target.get("x", Vector3.RIGHT)
	var y: Vector3 = target.get("y", Vector3.FORWARD)
	var hit: Variant = workspace.viewport.plane_hit(button.position, target.get("origin", Vector3.ZERO), x.cross(y))
	if not hit is Vector3:
		return true
	var values: Dictionary = workspace.command_values.duplicate(true)
	values["cal_a" if _calibration_clicks == 2 else "cal_b"] = hit
	_calibration_clicks -= 1
	workspace.set_command_values(values)
	if _calibration_clicks == 1:
		workspace.flash("Click the second point on the canvas.")
	return true


func manipulators(values: Dictionary, _evaluated: Dictionary) -> Array[Dictionary]:
	var handles: Array[Dictionary] = []
	var target := entry()
	if target.is_empty():
		return handles
	if type == "canvas":
		var x: Vector3 = target.get("x", Vector3.RIGHT)
		var y: Vector3 = target.get("y", Vector3.FORWARD)
		handles.append({"type": "point", "key": "center", "position": values.get("center", Vector3.ZERO), "normal": x.cross(y)})
	elif str(target.get("body", "")) != "":
		handles.append({"type": "point", "key": "position", "position": values.get("position", Vector3.ZERO), "normal": target.get("normal", Vector3.UP)})
	return handles


## The image's outline (and the calibration points) while the panel is open.
func draw(overlay: Control) -> void:
	var target := entry()
	if target.is_empty():
		return
	var corners := []
	if type == "canvas":
		var o: Vector3 = target.get("origin", Vector3.ZERO)
		var hx: Vector3 = (target.get("x", Vector3.RIGHT) as Vector3) * (target.get("size", Vector2.ONE) as Vector2).x * 0.5
		var hy: Vector3 = (target.get("y", Vector3.FORWARD) as Vector3) * (target.get("size", Vector2.ONE) as Vector2).y * 0.5
		corners = [o - hx - hy, o + hx - hy, o + hx + hy, o - hx + hy]
	elif str(target.get("body", "")) != "":
		var t := APPEARANCE.decal_transform(target)
		var s := APPEARANCE.decal_size(target)
		for c in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
			corners.append(t * Vector3(c.x * s.x * 0.5, 0.0, c.y * s.z * 0.5))
	var view: Control = workspace.viewport
	for i in corners.size():
		var a: Vector2 = view.project(corners[i])
		var b: Vector2 = view.project(corners[(i + 1) % corners.size()])
		if a.is_finite() and b.is_finite():
			overlay.draw_dashed_line(a, b, OUTLINE, 1.5, 6.0)
	if type == "canvas" and bool(current_values.get("calibrate", false)):
		var a: Vector2 = view.project(current_values.get("cal_a", Vector3.ZERO))
		var b: Vector2 = view.project(current_values.get("cal_b", Vector3.ZERO))
		if a.is_finite() and b.is_finite():
			overlay.draw_line(a, b, OUTLINE, 2.0, true)
			overlay.draw_circle(a, 5.0, OUTLINE)
			overlay.draw_circle(b, 5.0, OUTLINE)


# --- Helpers ---------------------------------------------------------------------------------

func _list(doc: Resource) -> Array[Dictionary]:
	return doc.decals if type == "decal" else doc.canvases


func _context() -> Dictionary:
	return INSPECT.context(workspace.result, workspace.doc, workspace.kernel)


## The picked plane as {"origin", "normal", "x"}; the ground (XZ) plane when none is picked.
func _plane_frame(values: Dictionary) -> Dictionary:
	var refs: Array = values.get("plane", [])
	if not refs.is_empty() and refs[0] is Dictionary and workspace != null:
		var plane := REFERENCES.plane(refs[0], _context())
		if not plane.has("error"):
			return plane
	return GROUND


func _write_canvas(target: Dictionary, values: Dictionary) -> void:
	var plane := _plane_frame(values)
	var n := (plane.normal as Vector3).normalized()
	var x := (plane.x as Vector3).normalized().rotated(n, number(values, "rotation", UNITS.KIND_ANGLE, 0.0))
	target["origin"] = values.get("center", plane.origin)
	target["x"] = x
	target["y"] = n.cross(x)
	# The plane it was placed on: follow_geometry() moves the canvas when that plane moves.
	target["frame"] = {"origin": plane.origin, "normal": plane.normal, "x": plane.x}
	target["size"] = Vector2(absf(number(values, "width", UNITS.KIND_LENGTH, 0.05)), absf(number(values, "height", UNITS.KIND_LENGTH, 0.05)))
	target["opacity"] = clampf(number(values, "opacity", UNITS.KIND_NUMBER, 0.5), 0.0, 1.0)
	target["through"] = bool(values.get("through", false))


## Writes the decal's panel values into its entry. The position always lands on the face: one
## dragged in the face's tangent plane (the Position handle) or typed off it is moved to the
## face's nearest point, and values.position follows. Returns true when that moved it.
func _write_decal(target: Dictionary, values: Dictionary) -> bool:
	var moved := false
	var refs: Array = values.get("face", [])
	var found := REFERENCES.face(refs[0], _context()) if not refs.is_empty() and refs[0] is Dictionary else {"error": "none"}
	if found.has("error"):
		target["body"] = ""
		target["face"] = ""
	else:
		var typed: Vector3 = values.get("position", Vector3.ZERO)
		var p := _onto_face(found, typed, workspace.kernel)
		if p.distance_to(typed) > MOVE_TOLERANCE:
			values["position"] = p
			moved = true
		target["body"] = str(refs[0].body)
		target["face"] = str(refs[0].name)
		target["position"] = p
		target["normal"] = found.shape.face_normal_at(found.index, p)
		target["up"] = Vector3.ZERO
	var flip := -1.0 if bool(values.get("flip", false)) else 1.0
	target["size"] = Vector2(absf(number(values, "width", UNITS.KIND_LENGTH, 0.01)) * flip, absf(number(values, "height", UNITS.KIND_LENGTH, 0.01)))
	target["rotation"] = number(values, "rotation", UNITS.KIND_ANGLE, 0.0)
	return moved


## The point of a found face (REFERENCES.face) nearest point: on the face itself, also on a
## curved face or past its edges (point when the kernel can't tell).
static func _onto_face(found: Dictionary, point: Vector3, kernel: RefCounted) -> Vector3:
	if kernel == null:
		return point
	var near: Dictionary = kernel.closest_points(found.shape.face_shape(found.index), kernel.make_vertex(point))
	return near.a if near.has("a") else point


## A decal entry as its face in result puts it (APPEARANCE.placed_decal, the bake's own rule),
## or {"lost": true} when its body or face is gone.
static func _placed_decal(entry: Dictionary, result: Dictionary, kernel: RefCounted) -> Dictionary:
	var body: Dictionary = (result.get("bodies", {}) as Dictionary).get(str(entry.get("body", "")), {})
	if body.get("shape") == null:
		return {"lost": true}
	return APPEARANCE.placed_decal(entry, body.shape, kernel)


## A plane frame ({"origin", "normal", "x"}) as a transform: x, normal x x, normal.
static func _frame_transform(frame: Dictionary) -> Transform3D:
	var n := (frame.get("normal", Vector3.UP) as Vector3).normalized()
	var x := (frame.get("x", Vector3.RIGHT) as Vector3).normalized()
	return Transform3D(Basis(x, n.cross(x), n), frame.get("origin", Vector3.ZERO))


## Where a newly picked face puts the decal: the clicked point (the face's middle when the pick
## came from elsewhere), moved onto the face. {"position"} or {}.
func _face_point(values: Dictionary) -> Dictionary:
	var refs: Array = values.get("face", [])
	if refs.is_empty() or not refs[0] is Dictionary or workspace == null:
		return {}
	var found := REFERENCES.face(refs[0], _context())
	if found.has("error"):
		return {}
	var point: Vector3 = found.shape.face_info(found.index).point
	var clicked: Variant = workspace.picker.click_point(refs[0])
	if clicked is Vector3:
		point = clicked
	return {"position": _onto_face(found, point, workspace.kernel)}
