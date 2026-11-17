@tool
extends "res://addons/holo_forge/tools/inspect_command.gd"
## Texture Map Controls: the texture mapping of the appearance a picked face or body shows (the
## doc.appearances entry it actually reads: its own, its body's or its component's), as typed
## fields and as handles on the face: two arrows that stretch one texture repeat along the mapped
## U and V directions, a dot that turns the texture about the surface, a point that slides the
## texture along the surface (its offset) and, for round projections, the projection's center.
## The view previews every change; OK keeps it as one undo step, Cancel puts it back.
##
## The math is in static functions (panel values <-> mapping, the gizmo frame on a face, the
## handles, offset drags), so tests drive it without the editor. A frame is
## {"anchor": Vector3 on the face, "u", "v": Vector3 (one texture repeat along U and V: moving by
## u raises u by 1 and keeps v), "normal": the face's outward normal there, "turn_axis": the axis
## the texture turns counter-clockwise about as its rotation grows}.

const APPEARANCE := preload("res://addons/holo_forge/core/appearance.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const TESSELLATE := preload("res://addons/holo_forge/core/tessellate.gd")
const MATERIAL_LIBRARY := preload("res://addons/holo_forge/core/material_library.gd")

## Projections placed by an origin and an axis (automatic follows the face itself).
const ORIGIN_TYPES := ["planar", "box", "cylindrical", "spherical"]
## Projections whose origin is their center (it gets a handle of its own).
const ROUND_TYPES := ["cylindrical", "spherical"]
const AXES := {
	"auto": Vector3.ZERO, "x": Vector3.RIGHT, "-x": Vector3.LEFT, "y": Vector3.UP, "-y": Vector3.DOWN,
	"z": Vector3.BACK, "-z": Vector3.FORWARD,
}
const AXIS_OPTIONS := [
	["auto", "Automatic"], ["x", "+X"], ["-x", "-X"], ["y", "+Y"], ["-y", "-Y"], ["z", "+Z"], ["-z", "-Z"],
	["custom", "Custom"],
]
## The smallest repeat length a field or arrow can set (1 µm).
const MIN_SCALE := 1e-6
## How far from the gizmo's center the turn handle sits, and the arrows' length (as the view
## draws them), in pixels.
const TURN_RADIUS_PX := 100.0
const ARROW_PX := 70.0
const TILE_COLOR := Color(0.95, 0.55, 0.15)

## The doc.appearances key being edited ("" when the pick shows no appearance).
var target_key := ""
## Where the gizmo sits (on the face); dragging its point handle moves it with the texture.
var anchor := Vector3.ZERO
## Where the anchor handle's drag was last (the view's raw hit on the handle's plane), null between
## drags. The next drag event slides the texture from there: anchor itself is kept on the face, so
## measuring from it would add a drag's overshoot past the face's edge again on every event.
var _drag_from: Variant = null
## The pick the values describe (the target slot's reference), to tell when it changes.
var _ref := {}
## pick_target() for _ref.
var _pick := {"target": "", "body": "", "face": -1}
## Body id -> the mesh the preview shows (only bodies the edited entry reaches are rebuilt).
var _meshes := {}
## doc.appearances as last previewed (text), to skip rebuilding unchanged meshes.
var _previewed := ""
## doc.appearances but the edited entry as last previewed (text), and the rebuild the meshes are of.
var _previewed_others := ""
var _previewed_result: Variant = null


func _init(_p_type := "appearance:texture_map") -> void:
	pass


func title() -> String:
	return "Texture Map Controls"


func changes_document() -> bool:
	return true


func fields() -> Array[Dictionary]:
	var types := []
	for t in APPEARANCE.TYPES:
		types.append([t, APPEARANCE.TYPE_LABELS[t]])
	var placed := {"type": ORIGIN_TYPES}
	return [
		{"key": "target", "label": "Face / Body", "type": "selection", "filter": ["face", "body"], "single": true},
		{"key": "type", "label": "Projection", "type": "enum", "options": types},
		{"key": "scale_u", "label": "Scale U", "type": "expression", "kind": "length"},
		{"key": "scale_v", "label": "Scale V", "type": "expression", "kind": "length"},
		{"key": "flip_u", "label": "Flip U", "type": "bool"},
		{"key": "flip_v", "label": "Flip V", "type": "bool"},
		{"key": "rotation", "label": "Rotation", "type": "expression", "kind": "angle"},
		{"key": "offset_u", "label": "Offset U", "type": "expression", "kind": "number"},
		{"key": "offset_v", "label": "Offset V", "type": "expression", "kind": "number"},
		{"key": "origin", "label": "Origin", "type": "point", "visible_if": placed},
		{"key": "axis", "label": "Axis", "type": "enum", "options": AXIS_OPTIONS, "visible_if": placed},
		{"key": "axis_x", "label": "Axis X", "type": "expression", "kind": "number", "visible_if": {"type": ORIGIN_TYPES, "axis": ["custom"]}},
		{"key": "axis_y", "label": "Axis Y", "type": "expression", "kind": "number", "visible_if": {"type": ORIGIN_TYPES, "axis": ["custom"]}},
		{"key": "axis_z", "label": "Axis Z", "type": "expression", "kind": "number", "visible_if": {"type": ORIGIN_TYPES, "axis": ["custom"]}},
		{"key": "fit", "label": "Fit Origin and Axis to the Face", "type": "button", "visible_if": placed,
			"tooltip": "Center the projection on the face (a round face's own axis or center)"},
		{"key": "result", "type": "info", "text": ""},
	]


## Starts on the selection (a face, else its body), preferring a pick that shows an appearance;
## with nothing selected, on the first appearance a body reads.
func defaults() -> Dictionary:
	var ref := _initial_ref()
	_take_pick(ref)
	var values := values_from_mapping(_mapping(), doc_units())
	values["target"] = [ref] if not ref.is_empty() else []
	return values


func write_values(doc: Resource, values: Dictionary) -> void:
	if workspace == null or doc == null:
		current_values = values.duplicate(true)
		return
	var refs: Array = values.get("target", [])
	var ref: Dictionary = refs[0] if not refs.is_empty() and refs[0] is Dictionary else {}
	if ref != _ref:
		# A new pick: show the mapping it reads, with the gizmo where it was clicked.
		_take_pick(ref)
		values.merge(values_from_mapping(_mapping(), doc.units), true)
		values.erase("anchor")
		current_values = values.duplicate(true)
		workspace.panel.set_values(values)
		return
	if target_key != "" and doc.appearances.get(target_key) is Dictionary:
		var entry: Dictionary = doc.appearances[target_key]
		var stored: Dictionary = entry.get("mapping", {})
		if values.get("anchor") is Vector3:
			# The point handle: the texture slides with it (its offset) by as much as the drag moved
			# since its last event (from the handle itself at the drag's start), and the gizmo follows.
			var to: Vector3 = values.anchor
			var frame := _frame()
			if not frame.is_empty():
				var from: Vector3 = _drag_from if _drag_from is Vector3 else anchor
				var moved := dragged_offset(frame, APPEARANCE.mapping_with_defaults(stored).offset, from, to)
				values["offset_u"] = _num(moved.x)
				values["offset_v"] = _num(moved.y)
				anchor = to
			_drag_from = to
		entry["mapping"] = changed_mapping(stored, values, doc.units, _known())
		_preview()
	values.erase("anchor")
	current_values = values.duplicate(true)


func accept_error() -> String:
	if _pick.body == "":
		return "Pick a face or body."
	if target_key == "":
		return "%s shows no appearance: apply one in the Appearance panel first." % workspace.doc.body_name(str(_pick.body))
	return ""


func update() -> void:
	workspace.panel.set_info("result", describe())
	workspace.viewport.redraw_overlay()


## The panel's readout: which appearance is edited and how big one repeat is here.
func describe() -> String:
	var doc: Resource = workspace.doc
	if _pick.body == "":
		return "Pick a face or body."
	if target_key == "":
		return "%s shows no appearance. Apply one in the Appearance panel first." % doc.body_name(str(_pick.body))
	var lines := PackedStringArray()
	var entry: Dictionary = doc.appearances.get(target_key, {})
	lines.append("Editing %s (%s)." % [target_label(doc, target_key), MATERIAL_LIBRARY.name_of(str(entry.get("material", "")))])
	var frame := _frame()
	if frame.is_empty():
		lines.append("The texture collapses on this face: check the scale and axis.")
	else:
		lines.append("One repeat here: %s x %s" % [length_text((frame.u as Vector3).length()), length_text((frame.v as Vector3).length())])
	return "\n".join(lines)


## "a face of Body1 (its own appearance)", "Body1's appearance", "Component2's appearance".
static func target_label(doc: Resource, key: String) -> String:
	if key.begins_with("face:"):
		var body_id := key.trim_prefix("face:").get_slice(":", 0)
		return "a face of %s (its own appearance)" % doc.body_name(body_id)
	if key.begins_with("body:"):
		return "%s's appearance" % doc.body_name(key.trim_prefix("body:"))
	if key.begins_with("component:"):
		return "%s's appearance" % doc.component_name(key.trim_prefix("component:"))
	return key


func on_button(key: String) -> void:
	if key != "fit" or _pick.body == "" or int(_pick.face) < 0:
		return
	var values: Dictionary = workspace.command_values.duplicate(true)
	var fit := fit_projection(_shape(), int(_pick.face), str(values.get("type", "")))
	values["origin"] = fit.origin
	if fit.has("axis"):
		var axis: Vector3 = fit.axis
		values["axis"] = axis_choice(axis)
		values["axis_x"] = _num(axis.x)
		values["axis_y"] = _num(axis.y)
		values["axis_z"] = _num(axis.z)
	workspace.set_command_values(values)


## The next anchor drag starts from the handle again.
func drag_ended(_handle: Dictionary) -> void:
	_drag_from = null


func manipulators(_values: Dictionary, _evaluated: Dictionary) -> Array[Dictionary]:
	var frame := _frame()
	if frame.is_empty():
		var none: Array[Dictionary] = []
		return none
	anchor = frame.anchor
	return handles(frame, _mapping(), 1.0 / maxf(workspace.viewport.pixels_per_meter_at(anchor), 1e-12))


## One texture repeat outlined at the gizmo, U and V at the arrow tips, and a round projection's
## axis through its center.
func draw(overlay: Control) -> void:
	var frame := _frame()
	if frame.is_empty():
		return
	var view: Control = workspace.viewport
	var a: Vector3 = frame.anchor
	var u: Vector3 = frame.u
	var v: Vector3 = frame.v
	var corners := [a, a + u, a + u + v, a + v]
	for i in 4:
		var p: Vector2 = view.project(corners[i])
		var q: Vector2 = view.project(corners[(i + 1) % 4])
		if p.is_finite() and q.is_finite():
			overlay.draw_dashed_line(p, q, TILE_COLOR, 1.5, 5.0)
	var font := overlay.get_theme_default_font()
	var pixel := 1.0 / maxf(view.pixels_per_meter_at(a), 1e-12)
	# U and V in the view's palette, on a backing that reads on any background.
	var colors: Dictionary = view.get("theme_colors")
	for label in [["U", u], ["V", v]]:
		var tip: Vector2 = view.project(a + (label[1] as Vector3).normalized() * pixel * (ARROW_PX + 22.0))
		if tip.is_finite():
			var size := font.get_string_size(label[0], HORIZONTAL_ALIGNMENT_LEFT, -1, 13)
			overlay.draw_rect(Rect2(tip - Vector2(7, size.y - 7), size + Vector2(6, 4)), colors.note_back, true)
			overlay.draw_string(font, tip - Vector2(4, -5), label[0], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, colors.note_text)
	var mapping := _mapping()
	if ROUND_TYPES.has(str(mapping.type)):
		var origin: Vector3 = mapping.origin
		var axis := round_axis(mapping)
		var reach := maxf(((_shape().bbox() as AABB).size).length(), pixel * 80.0)
		var p: Vector2 = view.project(origin - axis * reach)
		var q: Vector2 = view.project(origin + axis * reach)
		if p.is_finite() and q.is_finite():
			overlay.draw_dashed_line(p, q, TILE_COLOR, 1.5, 8.0)


# --- Static math (tests drive these) ---------------------------------------------------------

## Panel values for a mapping: lengths as bare numbers in the document's units, the rotation in
## degrees, offsets in repeats, the axis as one of AXIS_OPTIONS (plus its components).
static func values_from_mapping(mapping: Dictionary, units: String) -> Dictionary:
	var m := APPEARANCE.mapping_with_defaults(mapping)
	var scale: Vector2 = m.scale
	var offset: Vector2 = m.offset
	var axis: Vector3 = m.axis
	return {
		"type": str(m.type),
		"scale_u": _length(absf(scale.x), units), "scale_v": _length(absf(scale.y), units),
		"flip_u": scale.x < 0.0, "flip_v": scale.y < 0.0,
		"rotation": UNITS.format_value(float(m.rotation), UNITS.KIND_ANGLE, units).split(" ")[0],
		"offset_u": _num(offset.x), "offset_v": _num(offset.y),
		"origin": m.origin,
		"axis": axis_choice(axis), "axis_x": _num(axis.x), "axis_y": _num(axis.y), "axis_z": _num(axis.z),
	}


## The mapping panel values describe. Fields that don't evaluate (or a zero scale) keep
## fallback's value; known holds parameter values expressions may use.
static func mapping_from_values(values: Dictionary, units: String, known := {}, fallback := {}) -> Dictionary:
	var base := APPEARANCE.mapping_with_defaults(fallback)
	var old_scale: Vector2 = base.scale
	var old_offset: Vector2 = base.offset
	var type := str(values.get("type", base.type))
	if not APPEARANCE.TYPES.has(type):
		type = str(base.type)
	var scale := Vector2.ZERO
	for i in 2:
		var size := absf(_value(values, ["scale_u", "scale_v"][i], UNITS.KIND_LENGTH, units, known, absf(old_scale[i])))
		if size < MIN_SCALE:
			size = maxf(absf(old_scale[i]), MIN_SCALE)
		var flipped := bool(values.get(["flip_u", "flip_v"][i], old_scale[i] < 0.0))
		scale[i] = -size if flipped else size
	var origin: Variant = values.get("origin", base.origin)
	return {
		"type": type, "scale": scale,
		"rotation": _value(values, "rotation", UNITS.KIND_ANGLE, units, known, float(base.rotation)),
		"offset": Vector2(_value(values, "offset_u", UNITS.KIND_NUMBER, units, known, old_offset.x), _value(values, "offset_v", UNITS.KIND_NUMBER, units, known, old_offset.y)),
		"origin": origin if origin is Vector3 else base.origin,
		"axis": axis_from_values(values, units, known, base.axis),
	}


## A stored mapping with what the panel values change applied: only the keys (and the U or V
## half of a pair) whose fields differ from the stored mapping's, so untouched keys stay unset.
static func changed_mapping(stored: Dictionary, values: Dictionary, units: String, known := {}) -> Dictionary:
	var full := APPEARANCE.mapping_with_defaults(stored)
	var shown := values_from_mapping(full, units)
	var next := mapping_from_values(values, units, known, full)
	var out := stored.duplicate(true)
	if _differs(values, shown, ["type"]):
		out["type"] = next.type
	for pair in [["scale", ["scale_u", "flip_u"], ["scale_v", "flip_v"]], ["offset", ["offset_u"], ["offset_v"]]]:
		var key: String = pair[0]
		var value: Vector2 = full[key]
		var changed := false
		for i in 2:
			if _differs(values, shown, pair[i + 1]):
				value[i] = (next[key] as Vector2)[i]
				changed = true
		if changed:
			out[key] = value
	if _differs(values, shown, ["rotation"]):
		out["rotation"] = next.rotation
	if values.get("origin") is Vector3 and values.origin != full.origin:
		out["origin"] = next.origin
	if _differs(values, shown, ["axis", "axis_x", "axis_y", "axis_z"]):
		out["axis"] = next.axis
	return out


## The axis the values pick: Automatic (zero), a world direction, or the Custom components.
static func axis_from_values(values: Dictionary, units: String, known := {}, fallback := Vector3.ZERO) -> Vector3:
	var choice := str(values.get("axis", axis_choice(fallback)))
	if AXES.has(choice):
		return AXES[choice]
	if choice != "custom":
		return fallback
	var axis := Vector3.ZERO
	for i in 3:
		axis[i] = _value(values, ["axis_x", "axis_y", "axis_z"][i], UNITS.KIND_NUMBER, units, known, fallback[i])
	return axis


## The AXIS_OPTIONS key for an axis ("auto" for zero, "custom" when it isn't a world direction).
static func axis_choice(axis: Vector3) -> String:
	if axis.is_zero_approx():
		return "auto"
	var n := axis.normalized()
	for key in AXES:
		if key != "auto" and (AXES[key] as Vector3).distance_to(n) < 1e-5:
			return key
	return "custom"


## What a pick (a face or body reference) edits: {"target": the doc.appearances key it reads (""
## when none), "body", "face": the face the gizmo sits on (-1 for none)}. A face reads its own,
## its body's or its component's entry; a body its body-wide one (else the one its largest face
## with an appearance has), with the gizmo on its largest face that shows it.
static func pick_target(doc: Resource, result: Dictionary, ref: Dictionary) -> Dictionary:
	var none := {"target": "", "body": "", "face": -1}
	var body_id := str(ref.get("body", ""))
	var body: Dictionary = result.get("bodies", {}).get(body_id, {})
	if body.is_empty():
		return none
	var shape: RefCounted = body.shape
	var names: PackedStringArray = shape.get_face_names()
	if str(ref.get("kind", "")) == "face":
		var found := REFERENCES.face(ref, {"bodies": result.get("bodies", {})})
		if found.has("error"):
			return none
		var index := int(found.index)
		return {"target": str(APPEARANCE.resolve(doc, body_id, names[index]).target), "body": body_id, "face": index}
	var target := str(APPEARANCE.resolve(doc, body_id, "").target)
	var reads := PackedStringArray()
	var areas := PackedFloat64Array()
	for f in names.size():
		reads.append(str(APPEARANCE.resolve(doc, body_id, names[f]).target))
		areas.append(float((shape.face_info(f) as Dictionary).get("area", 0.0)))
	if target == "":
		var widest := -1.0
		for f in names.size():
			if reads[f] != "" and areas[f] > widest:
				widest = areas[f]
				target = reads[f]
	var face := -1
	for f in names.size():
		if reads[f] == target and (face < 0 or areas[f] > areas[face]):
			face = f
	return {"target": target, "body": body_id, "face": face}


## A reference to something that reads the doc.appearances entry target: the face itself for a
## face entry, else the first body it reaches. {} when no body in result reads it.
static func ref_for_target(doc: Resource, result: Dictionary, target: String) -> Dictionary:
	var bodies: Dictionary = result.get("bodies", {})
	for body_id in bodies:
		if not APPEARANCE.reaches(doc, str(body_id), target):
			continue
		if not target.begins_with("face:"):
			return {"kind": "body", "body": str(body_id)}
		var shape: RefCounted = bodies[body_id].shape
		var names: PackedStringArray = shape.get_face_names()
		var index: int = shape.find_face(target.substr(target.find(":", 5) + 1))
		if index < 0:
			# A later feature split the face ("<name>#k"): a piece that still reads the entry.
			for f in names.size():
				if str(APPEARANCE.resolve(doc, str(body_id), names[f]).get("target", "")) == target:
					index = f
					break
		if index >= 0 and index < names.size():
			return {"kind": "face", "body": str(body_id), "name": str(names[index]), "sig": REFERENCES.face_signature(shape, index)}
	return {}


## Where the gizmo starts on a face with no click: a flat face's center, a curved face's point at
## the middle of its own u,v range (the centroid of a round face is off the face), else its vertex
## nearest that middle (a hole there).
static func start_point(shape: RefCounted, face_index: int, tess: Dictionary) -> Vector3:
	var info: Dictionary = shape.face_info(face_index)
	if bool(info.get("planar", false)):
		return info.get("point", Vector3.ZERO)
	var positions: PackedVector3Array = tess.get("positions", PackedVector3Array())
	var raw: PackedVector2Array = tess.get("uvs", PackedVector2Array())
	var vertices := _face_vertices(tess, face_index)
	if vertices.is_empty() or raw.size() < positions.size():
		return info.get("point", Vector3.ZERO)
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for v in vertices:
		lo = lo.min(raw[v])
		hi = hi.max(raw[v])
	var middle := (lo + hi) * 0.5
	var indices: PackedInt32Array = tess.get("indices", PackedInt32Array())
	var face_ids: PackedInt32Array = tess.get("face_ids", PackedInt32Array())
	for t in face_ids.size():
		if face_ids[t] != face_index:
			continue
		var corner := [indices[t * 3], indices[t * 3 + 1], indices[t * 3 + 2]]
		var w := _barycentric_2d(middle, raw[corner[0]], raw[corner[1]], raw[corner[2]])
		if w.x >= -1e-9 and w.y >= -1e-9 and w.z >= -1e-9:
			return positions[corner[0]] * w.x + positions[corner[1]] * w.y + positions[corner[2]] * w.z
	var span := (hi - lo).max(Vector2(1e-12, 1e-12))
	var best := vertices[0]
	var best_d := INF
	for v in vertices:
		var d := ((raw[v] - lo) / span).distance_squared_to(Vector2(0.5, 0.5))
		if d < best_d:
			best_d = d
			best = v
	return positions[best]


## The gizmo's frame (see the top) on one face, at its point nearest near; {} when the face has
## no triangles or the texture collapses there. Measured on the triangle under the anchor with the
## same texture coordinates the bake makes, so it holds for every projection type.
static func surface_frame(shape: RefCounted, face_index: int, tess: Dictionary, mapping: Dictionary, near: Vector3) -> Dictionary:
	var m := APPEARANCE.mapping_with_defaults(mapping)
	var positions: PackedVector3Array = tess.get("positions", PackedVector3Array())
	var normals: PackedVector3Array = tess.get("normals", PackedVector3Array())
	var indices: PackedInt32Array = tess.get("indices", PackedInt32Array())
	var face_ids: PackedInt32Array = tess.get("face_ids", PackedInt32Array())
	var best := -1
	var best_d := INF
	var best_point := Vector3.ZERO
	for t in face_ids.size():
		if face_ids[t] != face_index:
			continue
		var p := _closest_on_triangle(near, positions[indices[t * 3]], positions[indices[t * 3 + 1]], positions[indices[t * 3 + 2]])
		var d := p.distance_squared_to(near)
		if d < best_d:
			best_d = d
			best = t
			best_point = p
	if best < 0:
		return {}
	var corners := APPEARANCE.face_corner_uvs(shape, face_index, tess, PackedInt32Array([best]), m)
	var p0 := positions[indices[best * 3]]
	var p1 := positions[indices[best * 3 + 1]]
	var p2 := positions[indices[best * 3 + 2]]
	var e1 := p1 - p0
	var e2 := p2 - p0
	var d1 := corners[1] - corners[0]
	var d2 := corners[2] - corners[0]
	# The edges' uv steps as columns of a 2x2 matrix: its inverse turns a uv step into edge amounts.
	var det := float(d1.x) * d2.y - float(d2.x) * d1.y
	if absf(det) < 1e-20:
		return {}
	var u := (e1 * d2.y - e2 * d1.y) / det
	var v := (e2 * d1.x - e1 * d2.x) / det
	var w := _barycentric(best_point, p0, p1, p2)
	var normal := normals[indices[best * 3]] * w.x + normals[indices[best * 3 + 1]] * w.y + normals[indices[best * 3 + 2]] * w.z
	if normal.length() < 1e-9:
		normal = e1.cross(e2)
	# The rotation turns the surface's own (unscaled) U and V, so a flip on one of them doesn't
	# change which way the texture turns.
	var scale: Vector2 = m.scale
	var turn := v.cross(u) * signf(scale.x * scale.y)
	if turn.length() < 1e-12:
		return {}
	return {"anchor": best_point, "u": u, "v": v, "normal": normal.normalized(), "turn_axis": turn.normalized()}


## On-canvas handles for a frame (pixel: meters per screen pixel at the anchor): Scale U and V
## arrows along u and v (dragging one by d meters lengthens the repeat by d where the mapping is
## true to size), the Rotation dot (dragging it round by an angle turns the texture as much), the
## anchor point (slides the texture: write_values turns it into an offset) and, for round
## projections, the origin.
static func handles(frame: Dictionary, mapping: Dictionary, pixel: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if frame.is_empty():
		return out
	var m := APPEARANCE.mapping_with_defaults(mapping)
	var scale: Vector2 = m.scale
	var at: Vector3 = frame.anchor
	var u: Vector3 = frame.u
	var v: Vector3 = frame.v
	for i in 2:
		var along: Vector3 = [u, v][i]
		out.append({"type": "arrow", "key": ["scale_u", "scale_v"][i], "origin": at, "direction": along.normalized(),
			"base": absf(scale[i]), "factor": absf(scale[i]) / maxf(along.length(), 1e-12), "min": MIN_SCALE})
	var radius := TURN_RADIUS_PX * pixel
	var start := (u.normalized() + v.normalized()).normalized()
	out.append({"type": "angle", "key": "rotation", "origin": at, "axis": frame.turn_axis, "start": start * radius,
		"radius": radius, "base": float(m.rotation)})
	out.append({"type": "point", "key": "anchor", "position": at, "normal": frame.normal})
	if ROUND_TYPES.has(str(m.type)):
		out.append({"type": "point", "key": "origin", "position": m.origin, "normal": round_axis(m)})
	return out


## A round projection's axis: the mapping's, or +Y when it has none (as the bake reads it).
static func round_axis(mapping: Dictionary) -> Vector3:
	var axis: Vector3 = mapping.get("axis", Vector3.ZERO)
	return axis.normalized() if not axis.is_zero_approx() else Vector3.UP


## The offset after the anchor handle moves from one point to another: the texture moves with it
## (the texture point under from ends up under to).
static func dragged_offset(frame: Dictionary, offset: Vector2, from: Vector3, to: Vector3) -> Vector2:
	var d := to - from
	var u: Vector3 = frame.u
	var v: Vector3 = frame.v
	# d as a u, v combination (least squares: drops any part along the normal).
	var uu := u.dot(u)
	var uv := u.dot(v)
	var vv := v.dot(v)
	var det := uu * vv - uv * uv
	if absf(det) < 1e-30:
		return offset
	var du := d.dot(u)
	var dv := d.dot(v)
	return offset - Vector2((vv * du - uv * dv) / det, (uu * dv - uv * du) / det)


## Origin (and axis) that center a projection on a face: a cylinder, cone or torus face's own
## axis for cylindrical, a sphere's center for spherical, the face's center for planar, else the
## body's middle. {"origin", "axis"?}.
static func fit_projection(shape: RefCounted, face_index: int, type: String) -> Dictionary:
	var info: Dictionary = shape.face_info(face_index)
	var middle := (shape.bbox() as AABB).get_center()
	match type:
		"cylindrical":
			if info.has("axis"):
				return {"origin": info.get("axis_origin", middle), "axis": info.axis}
		"spherical":
			if info.has("center"):
				return {"origin": info.center}
		"planar":
			return {"origin": info.get("point", middle)}
	return {"origin": middle}


# --- Helpers ---------------------------------------------------------------------------------

func _initial_ref() -> Dictionary:
	if workspace == null or workspace.doc == null:
		return {}
	var doc: Resource = workspace.doc
	var result: Dictionary = workspace.result
	var first := {}
	for pick in workspace.selection:
		var ref := REFERENCES.from_pick(pick, result) if str(pick.get("kind", "")) == "face" else {}
		if ref.is_empty() and result.get("bodies", {}).has(str(pick.get("body", ""))):
			ref = {"kind": "body", "body": str(pick.body)}
		if ref.is_empty():
			continue
		if str(pick_target(doc, result, ref).target) != "":
			return ref
		if first.is_empty():
			first = ref
	if not first.is_empty():
		return first
	for key in doc.appearances:
		var ref := ref_for_target(doc, result, str(key))
		if not ref.is_empty():
			return ref
	return {}


## Makes ref the pick: what it edits, and the gizmo where it was clicked (else the face's middle).
func _take_pick(ref: Dictionary) -> void:
	_ref = ref.duplicate(true)
	_drag_from = null
	_pick = pick_target(workspace.doc, workspace.result, ref) if workspace != null and workspace.doc != null else {"target": "", "body": "", "face": -1}
	target_key = str(_pick.target)
	if int(_pick.face) < 0:
		return
	var clicked: Variant = workspace.picker.click_point(ref) if workspace.get("picker") != null else null
	anchor = clicked if clicked is Vector3 else start_point(_shape(), int(_pick.face), _tess())
	var frame := _frame()
	if not frame.is_empty():
		anchor = frame.anchor


## The edited entry's mapping with every key filled in.
func _mapping() -> Dictionary:
	var entry: Variant = workspace.doc.appearances.get(target_key) if workspace != null and target_key != "" else null
	return APPEARANCE.mapping_with_defaults((entry as Dictionary).get("mapping", {}) if entry is Dictionary else {})


func _shape() -> RefCounted:
	return workspace.result.bodies[_pick.body].shape


func _tess() -> Dictionary:
	var tess: Dictionary = workspace.tessellations.get(_pick.body, {})
	return tess if not tess.is_empty() else TESSELLATE.tessellate(_shape())


func _frame() -> Dictionary:
	if target_key == "" or int(_pick.face) < 0 or not workspace.result.get("bodies", {}).has(_pick.body):
		return {}
	return surface_frame(_shape(), int(_pick.face), _tess(), _mapping(), anchor)


## Parameter values for expressions.
func _known() -> Dictionary:
	var known := {}
	var values: Dictionary = workspace.result.get("values", {})
	for name in values:
		if (values[name] as Dictionary).get("ok", false):
			known[name] = values[name]
	return known


## Shows the edited mapping in the view at once: rebuilds the meshes of the bodies the entry
## reaches (from the cached tessellations, no kernel rebuild). The baked part follows on OK; on
## Cancel the workspace shows its own bodies again (preview_bodies).
func _preview() -> void:
	var doc: Resource = workspace.doc
	var key := str(doc.appearances)
	if key == _previewed:
		return
	_previewed = key
	# Another entry changed under the command (an appearance applied from the Appearance panel), or
	# the model was rebuilt: every body's mesh is made again, not only those the entry reaches.
	var others: Dictionary = doc.appearances.duplicate()
	others.erase(target_key)
	if str(others) != _previewed_others or not is_same(workspace.result, _previewed_result):
		_previewed_others = str(others)
		_previewed_result = workspace.result
		_meshes.clear()
	var entries := []
	var bodies: Dictionary = workspace.result.get("bodies", {})
	for body_id in bodies:
		var tess: Dictionary = workspace.tessellations.get(body_id, {})
		if tess.is_empty():
			tess = TESSELLATE.tessellate(bodies[body_id].shape)
		if not _meshes.has(body_id) or APPEARANCE.reaches(doc, str(body_id), target_key):
			_meshes[body_id] = APPEARANCE.build_mesh(doc, body_id, bodies[body_id].shape, tess, workspace.viewport.surface_material(), workspace.viewport.surface_body_material()).mesh
		var settings: Dictionary = doc.body_settings(body_id)
		entries.append({"id": body_id, "tess": tess, "visible": doc.body_visible(body_id), "selectable": not bool(settings.get("locked", false)),
			"mesh": _meshes[body_id], "surface": APPEARANCE.two_sided(bodies[body_id].shape)})
	if workspace.has_method("preview_bodies"):
		workspace.preview_bodies(entries)
	else:
		workspace.viewport.set_bodies(entries)


static func _value(values: Dictionary, key: String, kind: String, units: String, known: Dictionary, fallback: float) -> float:
	var r := UNITS.evaluate(str(values.get(key, "")), kind, units, known)
	return float(r.value) if r.ok else fallback


static func _differs(values: Dictionary, shown: Dictionary, keys: Array) -> bool:
	for key in keys:
		if values.has(key) and str(values[key]) != str(shown[key]):
			return true
	return false


static func _length(meters: float, units: String) -> String:
	return UNITS.format_value(meters, UNITS.KIND_LENGTH, units).split(" ")[0]


## A plain number with at most four decimals and no trailing zeros.
static func _num(value: float) -> String:
	var text := String.num(snappedf(value, 0.0001), 4)
	text = text.rstrip("0").rstrip(".") if text.contains(".") else text
	return "0" if text == "-0" else text


static func _face_vertices(tess: Dictionary, face_index: int) -> PackedInt32Array:
	var indices: PackedInt32Array = tess.get("indices", PackedInt32Array())
	var face_ids: PackedInt32Array = tess.get("face_ids", PackedInt32Array())
	var seen := {}
	var out := PackedInt32Array()
	for t in face_ids.size():
		if face_ids[t] != face_index:
			continue
		for c in 3:
			var v := indices[t * 3 + c]
			if not seen.has(v):
				seen[v] = true
				out.append(v)
	return out


## The point of triangle a, b, c nearest p.
static func _closest_on_triangle(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var ab := b - a
	var ac := c - a
	var ap := p - a
	var d1 := ab.dot(ap)
	var d2 := ac.dot(ap)
	if d1 <= 0.0 and d2 <= 0.0:
		return a
	var bp := p - b
	var d3 := ab.dot(bp)
	var d4 := ac.dot(bp)
	if d3 >= 0.0 and d4 <= d3:
		return b
	var vc := d1 * d4 - d3 * d2
	if vc <= 0.0 and d1 >= 0.0 and d3 <= 0.0:
		return a + ab * (d1 / (d1 - d3))
	var cp := p - c
	var d5 := ab.dot(cp)
	var d6 := ac.dot(cp)
	if d6 >= 0.0 and d5 <= d6:
		return c
	var vb := d5 * d2 - d1 * d6
	if vb <= 0.0 and d2 >= 0.0 and d6 <= 0.0:
		return a + ac * (d2 / (d2 - d6))
	var va := d3 * d6 - d5 * d4
	if va <= 0.0 and d4 - d3 >= 0.0 and d5 - d6 >= 0.0:
		return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
	var denom := va + vb + vc
	if absf(denom) < 1e-30:
		return a
	return a + ab * (vb / denom) + ac * (vc / denom)


## Barycentric weights of p (in the triangle's plane) for a, b, c.
static func _barycentric(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var v0 := b - a
	var v1 := c - a
	var v2 := p - a
	var d00 := v0.dot(v0)
	var d01 := v0.dot(v1)
	var d11 := v1.dot(v1)
	var d20 := v2.dot(v0)
	var d21 := v2.dot(v1)
	var denom := d00 * d11 - d01 * d01
	if absf(denom) < 1e-30:
		return Vector3(1, 0, 0)
	var y := (d11 * d20 - d01 * d21) / denom
	var z := (d00 * d21 - d01 * d20) / denom
	return Vector3(1.0 - y - z, y, z)


## Barycentric weights of a 2D point for triangle a, b, c (all -1 when it is degenerate).
static func _barycentric_2d(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> Vector3:
	var area := float((b - a).cross(c - a))
	if absf(area) < 1e-30:
		return Vector3(-1, -1, -1)
	var y := float((p - a).cross(c - a)) / area
	var z := float((b - a).cross(p - a)) / area
	return Vector3(1.0 - y - z, y, z)
