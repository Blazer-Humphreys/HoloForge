@tool
extends "res://addons/holo_forge/tools/inspect_command.gd"
## Measure: pick one or two things (faces, edges, vertices, bodies, sketch curves and points,
## origin and construction planes, axes and points). One shows its own sizes; two show the
## minimum distance, drawn in the view, its X/Y/Z parts and the angle between them when both
## have a direction. Results update as you pick; the document never changes. From the Sketch
## toolbar (or I in a sketch) it runs over the open sketch, picking its points and curves as well
## as the model, and closing it returns to the sketch as it was.

const INSPECT := preload("res://addons/holo_forge/core/inspect.gd")
const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")

const KINDS := ["face", "edge", "vertex", "point", "body", "plane", "axis", "sketch_curve"]
const LINE_COLOR := Color(0.95, 0.4, 0.1)
const PROMPT := "Pick a face, edge, point, body, sketch curve, plane or axis; pick a second one for the distance and angle between them."

## The latest INSPECT.measure() result ({} before anything is picked).
var measured := {}
## Where the view click that picked a whole mesh body hit it (slot key -> {"body", "at"}): a mesh
## body is measured from a point, so its reference is given that point as "at".
var _clicked := {}


func _init(_type := "") -> void:
	pass


func title() -> String:
	return "Measure"


func fields() -> Array[Dictionary]:
	return [
		{"key": "first", "label": "First", "type": "selection", "filter": KINDS, "single": true},
		{"key": "second", "label": "Second", "type": "selection", "filter": KINDS, "single": true},
		{"key": "result", "type": "info", "text": PROMPT},
	]


func defaults() -> Dictionary:
	return {"first": [], "second": []}


func update() -> void:
	var values: Dictionary = current_values
	var refs := []
	for slot in ["first", "second"]:
		for item in values.get(slot, []):
			if item is Dictionary:
				refs.append(_with_click(slot, item))
	if refs.is_empty():
		measured = {}
		workspace.panel.set_info("result", PROMPT)
	else:
		var ctx := INSPECT.context(workspace.result, workspace.doc, workspace.kernel)
		# The bodies where the assembly places them while the view is posed (spec 3.12, C7.4).
		var poses: Dictionary = workspace.inspect_poses() if workspace.has_method("inspect_poses") else {}
		if not poses.is_empty():
			ctx["poses"] = poses
		measured = INSPECT.measure(refs[0], refs[1] if refs.size() > 1 else {}, ctx)
		workspace.panel.set_info("result", describe(measured))
	workspace.viewport.redraw_overlay()


## The result as text in the document's units.
func describe(m: Dictionary) -> String:
	if m.has("error"):
		return "\n".join(PackedStringArray([str(m.error)]) + remarks(m, ["error"]))
	if str(m.get("kind", "")) != "distance":
		return "\n".join(PackedStringArray([_single(m)]) + remarks(m))
	var lines := PackedStringArray()
	lines.append("Distance: %s" % length_text(float(m.distance)))
	var d: Vector3 = m.delta
	lines.append("ΔX %s   ΔY %s   ΔZ %s" % [length_text(d.x), length_text(d.y), length_text(d.z)])
	if m.has("angle"):
		lines.append("Angle: %s" % UNITS.format_value(float(m.angle), UNITS.KIND_ANGLE, doc_units()))
	lines.append("First: " + _single(m.first))
	lines.append("Second: " + _single(m.second))
	# (A mesh body is measured from the picked point, not as the least distance: the note says so.)
	lines.append_array(remarks(m))
	for side in ["first", "second"]:
		if m.get(side) is Dictionary:
			lines.append_array(remarks(m[side]))
	return "\n".join(lines)


## Every remark a result carries, one line each: its "note", "warning" and "error" (a text or a
## list of texts each, also as "notes" and "warnings"). skip: keys already shown.
static func remarks(entry: Dictionary, skip: Array = []) -> PackedStringArray:
	var lines := PackedStringArray()
	for key in ["error", "warning", "warnings", "note", "notes"]:
		if skip.has(key) or not entry.has(key):
			continue
		var held: Variant = entry[key]
		for text in (held if held is Array or held is PackedStringArray else [held]):
			if str(text).strip_edges() != "" and not lines.has(str(text)):
				lines.append(str(text))
	return lines


## A picked reference as it is measured: a whole mesh body picked in the view gets the point the
## click hit as "at" (kept per slot, so it stays when the other slot is picked).
func _with_click(slot: String, ref: Dictionary) -> Dictionary:
	if str(ref.get("kind", "")) != "body" or ref.has("at"):
		return ref
	var body_id := str(ref.get("body", ""))
	if not MESH_BODY.is_mesh((workspace.result.get("bodies", {}) as Dictionary).get(body_id, {})):
		return ref
	var clicked: Variant = workspace.picker.click_point(ref)
	if clicked is Vector3:
		_clicked[slot] = {"body": body_id, "at": clicked}
	var kept: Dictionary = _clicked.get(slot, {})
	if str(kept.get("body", "")) != body_id:
		return ref
	var with_point := ref.duplicate()
	with_point["at"] = kept.at
	return with_point


func _single(v: Dictionary) -> String:
	match str(v.get("kind", "")):
		"face" when bool(v.get("mesh", false)):
			# A face group of a mesh body: flat ones measure like a plane.
			var triangles := int(v.get("triangles", 0))
			return "%s, area %s (%d triangle%s)" % ["Flat face group" if str(v.get("face_type", "")) == "plane" else "Face group",
				power_text(float(v.area), 2), triangles, "" if triangles == 1 else "s"]
		"triangles":
			var count := int(v.get("count", 0))
			return "%d triangle%s of a mesh body" % [count, "" if count == 1 else "s"]
		"body" when bool(v.get("mesh", false)):
			var size := "%d triangle%s, %d face group%s" % [int(v.get("triangles", 0)), "" if int(v.get("triangles", 0)) == 1 else "s", int(v.get("groups", 0)), "" if int(v.get("groups", 0)) == 1 else "s"]
			if bool(v.get("surface", false)):
				return "Open mesh body (no volume), area %s, %s" % [power_text(float(v.area), 2), size]
			return "Mesh body, volume %s, area %s, %s" % [power_text(float(v.volume), 3), power_text(float(v.area), 2), size]
		"face":
			var text := "%s face, area %s" % [str(v.get("face_type", "")).capitalize(), power_text(float(v.area), 2)]
			if v.has("radius"):
				text += ", radius %s (diameter %s)" % [length_text(float(v.radius)), length_text(float(v.diameter))]
			return text
		"edge":
			var text := "%s edge, length %s" % [str(v.get("edge_type", "")).capitalize(), length_text(float(v.length))]
			if v.has("radius"):
				text += ", radius %s" % length_text(float(v.radius))
			return text
		"point":
			return "Point at %s" % point_text(v.position)
		"body":
			if bool(v.get("surface", false)):
				return "Surface body (no volume), area %s" % power_text(float(v.area), 2)
			return "Body, volume %s, area %s" % [power_text(float(v.volume), 3), power_text(float(v.area), 2)]
		"plane":
			return "Plane through %s" % point_text(v.origin)
		"axis":
			return "Axis through %s" % point_text(v.origin)
		"profile":
			return "Profile, area %s" % power_text(float(v.area), 2)
		"curve":
			var text := "Curve, length %s" % length_text(float(v.length))
			if v.has("radius"):
				text += ", radius %s" % length_text(float(v.radius))
			return text
	return "?"


func draw(overlay: Control) -> void:
	var view: Control = workspace.viewport
	var font := overlay.get_theme_default_font()
	match str(measured.get("kind", "")):
		"distance":
			var a: Vector2 = view.project(measured.point_a)
			var b: Vector2 = view.project(measured.point_b)
			if not (a.is_finite() and b.is_finite()):
				return
			overlay.draw_line(a, b, LINE_COLOR, 2.0, true)
			overlay.draw_circle(a, 4.0, LINE_COLOR)
			overlay.draw_circle(b, 4.0, LINE_COLOR)
			_label(overlay, font, (a + b) * 0.5 + Vector2(8, -8), length_text(float(measured.distance)))
		"point":
			var p: Vector2 = view.project(measured.position)
			if p.is_finite():
				overlay.draw_circle(p, 4.0, LINE_COLOR)


## The distance on a backing in the view's palette (dark on the dark theme, light on the light).
func _label(overlay: Control, font: Font, at: Vector2, text: String) -> void:
	var colors: Dictionary = workspace.viewport.get("theme_colors")
	var size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13)
	overlay.draw_rect(Rect2(at - Vector2(3, size.y - 2), size + Vector2(6, 4)), colors.note_back, true)
	overlay.draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, colors.note_text)
