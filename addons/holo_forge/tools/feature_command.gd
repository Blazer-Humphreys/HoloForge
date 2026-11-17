@tool
extends "res://addons/holo_forge/tools/command.gd"
## A feature command built from its spec in feature_specs.gd: expression fields become inputs
## (model parameters), everything else options. Inputs for fields that are hidden when the
## feature is made are added the first time the field shows.
##
## "press_pull" is context sensitive, as in other CAD apps: a picked face offsets it, an edge
## fillets it, a profile extrudes it (the feature under the command is swapped to match).
## "press_pull:surface" (the Surface workspace's) extrudes a profile into a surface body instead.
##
## Mesh tools ("mesh:<method>" specs, the Mesh workspace):
##   Picks. Fields that take the mesh kinds ("mesh_body", "mesh_group", "mesh_triangles",
##   "mesh_boundary") are filled by handle_mouse() from clicks on mesh bodies (the workspace
##   gives the command the view's clicks before the picker), and start with what is selected in
##   the workspace (bodies, or the Mesh selection's face groups or triangles). What they store:
##     mesh_body       {"kind": "body", "body"}
##     mesh_group      {"kind": "mesh_group", "body", "group", "at", "normal"}
##     mesh_triangles  {"kind": "mesh_triangles", "body", "triangles", "digest", "at", "normal"}:
##                     one per body, a click adds or takes out its triangle (a "separate" field:
##                     one per click, up to its "limit")
##     mesh_boundary   {"kind": "mesh_boundary", "body", "loop" (CadMesh.boundary_loops id),
##                     "edges", "digest", "at", "normal"}
##   Every one of them holds a point on what was picked ("at") and how the surface faces there
##   ("normal"), also when a field starts with the workspace's selection: the middle of a selected
##   triangle of the group then (_group_anchors()). Face groups are named by order, so an earlier
##   change can give a picked name to another face; the point and the facing are what lets a
##   rebuild find the picked group again (MESH_BODY.resolve_group needs the name and both).
##   Defaults. "$D/150", "$T/2", "$detail*2", "$m:0.0001" follow the picked body (its diagonal D
##   and triangle count T): a field still holding the value the panel gave it is given the new one
##   when the picked bodies change (adjust_values()); a typed value is never changed, also one
##   typed the same as the value the panel had chosen (mark_typed(): the workspace tells of every
##   key typed in). A spec's "voxel" cell size starts no smaller than what fits the grid cap. An
##   "optional" field (Remesh's Minimum Edge) starts empty and is no input while it is empty: the
##   kernel keeps its own default, and the hint beside the field says "auto" (auto_hint()), with
##   the value the kernel used once a report has it.
##   Ranges. A field's "range" is checked as it is typed (range_problems(): the field's hint turns
##   red and the stat row says why) and on OK (refusal()); nothing is clamped.
##   The "stat" row. stat_text() says what the last rebuild made of the feature: the triangle
##   counts, open edges and deviation from the op's report (core/features/mesh.gd `reports`, when
##   the handler publishes one; else counted from the bodies), the refusal's sentence, or
##   "Preview skipped (too slow); press OK to compute." when the op did not fit a preview.
##   Previews. preview_meshes() gives what is drawn over the bodies while the tool is open: the
##   part a Plane Cut (Trim) takes away and the triangles Erase and Fill erases, on the mesh as it
##   was when the tool started ("removed"), and the triangles a tool added as fills or caps
##   (face groups named fill<k> or cut<k> that the body did not have; "fill").

const SPECS := preload("res://addons/holo_forge/tools/feature_specs.gd")
const UNITS := preload("res://addons/holo_forge/core/units.gd")
const POINT64 := preload("res://addons/holo_forge/core/point64.gd")
const INSPECT := preload("res://addons/holo_forge/core/inspect.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const SKETCH_SOLID := preload("res://addons/holo_forge/core/features/sketch_solid.gd")
const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")
const MESH := preload("res://addons/holo_forge/core/features/mesh.gd")
const MESH_SELECTION := preload("res://addons/holo_forge/ui/mesh_selection.gd")

const PRESS_PULL := "press_pull"
const SURFACE_PRESS_PULL := "press_pull:surface"
const PRESS_PULL_TYPES := {"face": "offset_face", "edge": "fillet", "profile": "extrude"}
## Selection filter kinds that pick on mesh bodies (as MESH_BODY.FILTER_KINDS).
const MESH_KINDS := ["mesh_body", "mesh_group", "mesh_triangles", "mesh_boundary"]
## How many triangles are tried for a point with a facing (a triangle without an area has none).
const ANCHOR_TRIES := 32
## The selection fields whose picks say which body a mesh tool works on (for D and T).
const METRIC_FIELDS := ["bodies", "body", "target", "objects", "selection", "groups", "source", "points"]
## How near (pixels) a click must be to an open edge to pick its loop.
const BOUNDARY_PICK_PX := 9.0
const STAT_KEY := "stat"
const PREVIEW_SKIPPED := "Preview skipped (too slow); press OK to compute."
## The result row between OK and the full-time rebuild (tool title, seconds).
const COMPUTING := "Computing %s with the full time limit (up to %d s)..."
const NOT_A_MESH := "%s is not a mesh body. Tessellate it first (Mesh > Create > Tessellate)."
const NOT_FLAT := "That face group isn't flat. Pick a flat one, a plane or a flat face."
const NEAR_AN_EDGE := "Click near an open edge to pick its hole."
const ONLY_IN_PREVIEW := "That spot is only in the preview. Click where the body was before this tool changed it."
## Two clicks on a mesh are the same picked point when they lie within this part of the body's
## diagonal of each other (Mesh Align's three points).
const SAME_POINT := 0.02
## A preview overlay is left out above this many triangles (building it would slow every change).
const PREVIEW_TRIANGLES := 250000
const TESSELLATE := preload("res://addons/holo_forge/core/tessellate.gd")
const MESH_DISPLAY := preload("res://addons/holo_forge/ui/mesh_display.gd")

## The tool key: "extrude", "plane:offset", "press_pull", ...
var key := ""
var spec := {}
## Set by read_values when a stored choice reads as another one (see the spec's "read_as"), or
## an empty one as the field's default: the feature doesn't hold what the panel shows.
var reads_otherwise := false
## The Forge workspace (set by start_command; tests may run a command without one): its document
## and kernel find picked directions, and its picker the click point.
var workspace: Object
## Mesh tools: the values the panel gave fields by itself (key -> text), so a typed one is told
## from one still following the picked body.
var _auto := {}
## Keys the user typed in (or a caller set as typed): they never follow the body again.
var _touched := {}
## Open-edge loops of the meshes asked about (digest -> CadMesh.boundary_loops()).
var _loops := {}
var _checks := {}
## How many triangles each body held when the command started (id -> count), for the stat row.
var _started_with := {}
## The mesh bodies as they were when the command started (id -> CadMesh), their tessellations
## (made when a preview first needs one) and their face group names: what the previews compare with.
var _started_shapes := {}
var _started_tess := {}
var _anchor_arrays := {}
## The last preview overlays, by what they were made from.
var _preview_key := ""
## True when an existing feature is edited and the bodies before it are known (note_input()).
var _input_known := false
var _preview_entries := []


func _init(p_key := "extrude") -> void:
	key = p_key
	spec = SPECS.get_spec("surface:extrude" if key == SURFACE_PRESS_PULL else PRESS_PULL_TYPES.profile if key == PRESS_PULL else key)


func title() -> String:
	return "Press Pull" if _pressing() else str(spec.get("title", "Feature"))


## True for Press Pull (either workspace's).
func _pressing() -> bool:
	return key == PRESS_PULL or key == SURFACE_PRESS_PULL


func fields() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if _pressing():
		result.append({"key": "pick", "label": "Face, Edge or Profile", "type": "selection", "filter": ["face", "edge", "profile"], "single": true})
		result.append({"key": "distance", "label": "Distance", "type": "expression", "kind": "length"})
		return result
	for field in spec.get("fields", []):
		result.append(field)
	if str(spec.get("op", "")) != "":
		result.append_array(operation_fields(spec.get("ops", []), spec.get("op_visible_if", {})))
	return result


func defaults() -> Dictionary:
	var values := {}
	if _pressing():
		return {"pick": [], "distance": _size_text("$size/10")}
	_auto.clear()
	_touched.clear()
	if is_mesh_tool():
		_prefill(values)
		_note_start()
	for field in fields():
		if values.has(field.key):
			continue
		var value = field.get("default")
		if value is String and str(value).begins_with("$"):
			if value == "$position":
				value = hints.get("position", Vector3.ZERO)
			elif str(value).begins_with("$size"):
				value = _size_text(value)
			else:
				value = _default_text(field, values)
				_auto[field.key] = value
		elif value is Array or value is Dictionary:
			value = value.duplicate(true)
		values[field.key] = value
	if str(spec.get("op", "")) != "":
		values["operation"] = spec.op
		values["targets"] = []
	return values


func create_feature(doc: Resource, values: Dictionary) -> Resource:
	if _pressing():
		return _press_pull_feature(doc, values)
	var inputs := {}
	for field in fields():
		if field.type == "expression" and _shown(field, values) and not _left_to_kernel(field, values):
			inputs[field.key] = doc.make_input(str(values.get(field.key, "0")), str(field.get("kind", "length")))
	var options := {}
	if spec.has("method"):
		options["method"] = spec.method
	feature = doc.add_feature(str(spec.type), str(spec.get("label", str(spec.title).get_slice("/", 0).replace(" ", ""))), inputs, options)
	_write_options(values)
	sync_body(doc, feature)
	return feature


func read_values() -> Dictionary:
	var values := defaults()
	reads_otherwise = false
	if _pressing():
		var input_key := "radius" if feature.type == "fillet" else "distance"
		values.distance = feature.expression(input_key) if feature.inputs.has(input_key) else values.distance
		values.pick = (feature.options.get("press_pull_pick", []) as Array).duplicate(true)
		# A profile Press Pull saved as Join (before Auto) is written again when it opens, as Auto.
		reads_otherwise = feature.type == "extrude" and str(feature.options.get("operation", "")) == OPERATIONS.JOIN
		return values
	for field in fields():
		var k: String = field.key
		if field.type == "expression":
			if feature.inputs.has(k):
				values[k] = feature.expression(k)
				# (A stored value is the user's: it never reads as one the panel chose.)
				_touched[k] = true
		elif feature.options.has(k) and feature.options[k] == null and field.type == "enum":
			# An empty choice reads as the field's default (the panel can't show nothing).
			reads_otherwise = true
		elif feature.options.has(k):
			var stored = feature.options[k]
			if str(field.get("parse", "")) == "int_list":
				values[k] = ", ".join((stored as Array).map(func(n) -> String: return str(n)))
			else:
				values[k] = stored.duplicate(true) if stored is Array or stored is Dictionary else stored
			if field.type == "point":
				POINT64.read(values, k, feature.options)
			# A stored choice no longer offered reads as the one it stands for (looked up as text
			# too: a document can hold a choice as a number), so the panel shows what OK will build.
			var read_as: Dictionary = field.get("read_as", {})
			var stands_for: Variant = read_as.get(values[k]) if read_as.has(values[k]) else read_as.get(str(values[k])) if not values[k] is String else null
			if stands_for != null:
				values[k] = stands_for
				reads_otherwise = true
		elif field.has("unset"):
			# Saved before the field existed: what the feature builds with, so an edit keeps it.
			values[k] = field.unset
	if feature.options.has("press_pull_pick") and str(values.get("operation", "")) == OPERATIONS.JOIN and spec.get("ops", []).has(OPERATIONS.AUTO):
		# A profile Press Pull saved as Join (before Auto): it opens, and is written back, as Auto.
		values["operation"] = OPERATIONS.AUTO
		reads_otherwise = true
	return values


func write_values(doc: Resource, values: Dictionary) -> void:
	if _pressing():
		_press_pull_write(doc, values)
		return
	for field in fields():
		if field.type != "expression":
			continue
		var k: String = field.key
		if _left_to_kernel(field, values):
			# An optional field nobody typed in: no input, so the kernel keeps its own default.
			feature.inputs.erase(k)
		elif feature.inputs.has(k):
			feature.set_expression(k, str(values.get(k, "")))
		elif _shown(field, values):
			feature.inputs[k] = doc.make_input(str(values.get(k, "0")), str(field.get("kind", "length")))
	_write_options(values)
	sync_body(doc, feature)


## The kinds the viewport may pick for a selection field, given the current choices.
func filter_for(field_key: String, values: Dictionary) -> Variant:
	for field in fields():
		if field.key != field_key:
			continue
		for option_key in field.get("filter_by", {}):
			var by: Dictionary = field.filter_by[option_key]
			var current := str(values.get(option_key, ""))
			if by.has(current):
				return by[current]
		return field.get("filter", [])
	return []


func manipulators(values: Dictionary, evaluated: Dictionary) -> Array[Dictionary]:
	var handles: Array[Dictionary] = []
	var arrow := str(spec.get("arrow", ""))
	if _pressing():
		arrow = "distance"
	if arrow == "" or not evaluated.has(arrow) or result.is_empty():
		return handles
	var amount := float(evaluated[arrow])
	var frame := _arrow_frame(values, amount)
	if frame.is_empty():
		return handles
	var handle := {"type": "arrow", "key": arrow, "origin": (frame.origin as Vector3) + (frame.direction as Vector3) * amount,
		"direction": frame.direction, "factor": 1.0, "base": amount}
	if bool(spec.get("arrow_signed", false)):
		# An offset goes both ways (Plane Cut): the arrow may be dragged below zero.
		handle["min"] = -1e9
	handles.append(handle)
	return handles


# --- Mesh tools ------------------------------------------------------------------------------

## True for a Mesh workspace tool (a "mesh:<method>" spec).
func is_mesh_tool() -> bool:
	return str(spec.get("type", "")) == "mesh" and not _pressing()


## The undo step's name for a mesh tool's OK ("Mesh: Reduce"); "" for other tools.
func undo_name() -> String:
	return "Mesh: %s" % str(spec.get("title", "")).get_slice(" (", 0) if is_mesh_tool() else ""


## What the picked bodies measure: {"D": the diagonal (of the first picked body; of all of them
## together for a spec with "metrics": "union"), "T": the first one's triangle count, "center",
## "known": false when no body is picked yet (D is then a size that suits the view), "shapes":
## the picked bodies' shapes, "ids"}.
func metrics(values: Dictionary) -> Dictionary:
	var ids := []
	var bodies: Dictionary = result.get("bodies", {})
	for field in fields():
		if field.type != "selection" or not METRIC_FIELDS.has(field.key):
			continue
		for item in values.get(field.key, []):
			var id := str(item) if item is String else str((item as Dictionary).get("body", "")) if item is Dictionary else ""
			if id != "" and bodies.has(id) and not ids.has(id):
				ids.append(id)
	var shapes := []
	for id in ids:
		shapes.append(bodies[id].shape)
	if shapes.is_empty():
		return {"D": float(hints.get("default_size_m", 0.05)) * 4.0, "T": 0, "center": Vector3.ZERO, "known": false, "shapes": [], "ids": []}
	var box: AABB = shapes[0].bbox()
	if str(spec.get("metrics", "")) == "union":
		for i in range(1, shapes.size()):
			box = box.merge(shapes[i].bbox())
	var first: RefCounted = shapes[0]
	return {
		"D": maxf(box.size.length(), 1e-9), "T": int(first.triangle_count()) if first.has_method("triangle_count") else 0,
		"center": box.get_center(), "box": box, "known": true, "shapes": shapes, "ids": ids,
	}


## Gives the fields that still hold a value the panel chose the value the picked bodies now ask
## for (another body, another diagonal). Returns true when values changed. A typed value stays.
func adjust_values(values: Dictionary) -> bool:
	if not is_mesh_tool() or editing or _auto.is_empty():
		return false
	var changed := false
	for field in fields():
		var k: String = field.key
		if not _auto.has(k) or _touched.has(k) or str(values.get(k, "")) != str(_auto[k]):
			# (Typed over: it no longer follows the body.)
			_auto.erase(k)
			continue
		var text := _default_text(field, values)
		if text != str(values[k]):
			values[k] = text
			_auto[k] = text
			changed = true
	return changed


## The user typed in a field (or a caller set its value as typed): from now on the value is
## theirs, also when it reads the same as the one the panel had chosen.
func mark_typed(key: String) -> void:
	_touched[key] = true
	_auto.erase(key)


## True while a field still holds the value the panel chose for it (nobody typed in it).
func is_untouched(key: String, values: Dictionary) -> bool:
	return _auto.has(key) and not _touched.has(key) and str(values.get(key, "")) == str(_auto[key])


## True for an "optional" field left empty: it is no input, and the kernel keeps its own default.
func _left_to_kernel(field: Dictionary, values: Dictionary) -> bool:
	return bool(field.get("optional", false)) and str(values.get(field.key, "")).strip_edges() == ""


## What the panel says beside an "optional" field left empty: "auto", with the value the kernel
## used in the feature's last build once a report has it ("" for any other field).
func auto_hint(field: Dictionary, values: Dictionary) -> String:
	if field.type != "expression" or not _left_to_kernel(field, values):
		return ""
	var used := _used_value(str(field.get("used", "")))
	if used <= 0.0:
		return "auto"
	var kind := str(field.get("kind", "length"))
	return "auto: %s" % (_length_text(used) if kind == "length" else _number_text(rad_to_deg(used) if kind == "angle" else used))


## Why a field's value is out of its range, per field: {key: sentence}. Only fields that show,
## evaluate and have a range count; a bound that hangs on a body not picked yet is not checked.
func range_problems(values: Dictionary) -> Dictionary:
	var problems := {}
	if not is_mesh_tool():
		return problems
	var measured := metrics(values)
	var evaluated := evaluated_values(values)
	for field in fields():
		if field.type != "expression" or not field.has("range") or not _shown(field, values) or not evaluated.has(field.key):
			continue
		if _left_to_kernel(field, values):
			# (No input: the kernel picks the value, so there is nothing to refuse.)
			continue
		var kind := str(field.get("kind", "length"))
		var v := float(evaluated[field.key])
		var low := _bound(field.range[0], kind, evaluated, measured)
		var high := _bound(field.range[1], kind, evaluated, measured)
		var label := str(field.get("label", field.key)).get_slice(" (", 0)
		if v == 0.0 and bool(field.get("zero_ok", false)):
			continue
		if v == 0.0 and bool(field.get("not_zero", false)):
			problems[field.key] = "%s can't be 0." % label
			continue
		var slack := maxf(absf(v), 1.0) * 1e-9
		var below := false
		if not is_nan(low):
			below = v <= low if bool(field.get("gt", false)) else v < low - slack
		var above := false
		if not is_nan(high):
			above = v >= high if bool(field.get("lt", false)) else v > high + slack
		var fraction := bool(field.get("whole", false)) and absf(v - roundf(v)) > 1e-9
		if not (below or above or fraction):
			continue
		var a := _bound_text(low, kind)
		var b := _bound_text(high, kind)
		if bool(field.get("whole", false)):
			problems[field.key] = "%s must be a whole number from %s to %s." % [label, a, b]
		elif is_nan(low):
			problems[field.key] = "%s must be at most %s." % [label, b]
		elif is_nan(high):
			problems[field.key] = "%s must be %s %s." % [label, "more than" if bool(field.get("gt", false)) else "at least", a]
		else:
			problems[field.key] = "%s must be between %s and %s." % [label, a, b]
	return problems


## Why OK can't go ahead ("" when it can): the first field out of its range.
func refusal(values: Dictionary) -> String:
	var problems := range_problems(values)
	for field in fields():
		if problems.has(field.key):
			return problems[field.key]
	return ""


## Every expression field's value in base units (meters, radians, plain numbers); fields that
## don't evaluate are left out.
func evaluated_values(values: Dictionary) -> Dictionary:
	var out := {}
	var known := {}
	var computed: Dictionary = result.get("values", {})
	for name in computed:
		if (computed[name] as Dictionary).get("ok", false):
			known[name] = computed[name]
	var units := str(hints.get("units", "mm"))
	for field in fields():
		if field.type != "expression" or not values.has(field.key):
			continue
		var r := UNITS.evaluate(str(values[field.key]), str(field.get("kind", "length")), units, known)
		if r.get("ok", false):
			out[field.key] = float(r.value)
	return out


## The stat row's text after a rebuild: why the feature failed (or that its preview was skipped),
## the first field out of its range, or what the op made. previewing: the rebuild ran with the
## preview's time limit.
func stat_text(values: Dictionary, previewing := true) -> String:
	if not is_mesh_tool() or feature == null:
		return ""
	var bad := refusal(values)
	if bad != "":
		return bad
	var error := str(result.get("errors", {}).get(feature.id, ""))
	if error != "":
		return PREVIEW_SKIPPED if previewing and is_time_refusal(error) else error
	var lines := PackedStringArray()
	# The handler's report of this build (core/features/mesh.gd `reports`): the triangles before
	# and after, the open edges and the deviation summed over the bodies, and the tool's own line.
	var report := _report()
	var output: Variant = report.get("output")
	if output is Dictionary and (output as Dictionary).has("triangles"):
		var input: Variant = report.get("input")
		var before := int((input as Dictionary).get("triangles", 0)) if input is Dictionary else 0
		lines.append(_triangles_line(before, int(output.triangles)))
		if (output as Dictionary).has("boundary_edges"):
			lines.append("Open edges: %s" % with_commas(int(output.boundary_edges)))
		var deviation: Variant = report.get("deviation")
		if deviation is Dictionary and (deviation as Dictionary).has("max"):
			lines.append("Max deviation: %s" % _length_text(float(deviation.max)))
	else:
		# No counts in the report (or no report): counted here from the bodies the feature made.
		var made := _made_bodies()
		var before := 0
		var after := 0
		var open := 0
		var counted := true
		for id in made:
			var shape: RefCounted = result.bodies[id].shape
			if not MESH_BODY.is_mesh(shape):
				continue
			after += int(shape.triangle_count())
			before += int(_started_with.get(id, 0))
			var found := _checked(shape)
			counted = counted and not found.is_empty()
			open += int(found.get("boundary_edges", 0))
		if after > 0:
			lines.append(_triangles_line(before, after))
			if counted:
				lines.append("Open edges: %s" % with_commas(open))
		elif not made.is_empty():
			lines.append("Bodies made: %d" % made.size())
	if str(report.get("stat", "")) != "":
		lines.append(str(report.stat))
	var warning := str(result.get("warnings", {}).get(feature.id, ""))
	if warning != "":
		lines.append(warning)
	return "\n".join(lines)


## True for the two sentences an op says when it is over its time limit (the up-front estimate
## and the time-out): in a preview they mean "press OK", not a failure.
static func is_time_refusal(error: String) -> bool:
	return (error.contains("would take about") and error.contains("(limit")) or (error.contains("took longer than") and error.contains("was stopped"))


## A count with its noun, singular for 1 ("1 pick", "20,480 triangles"; many: an irregular plural).
static func counted(value: int, one: String, many := "") -> String:
	return "%s %s" % [with_commas(value), one if absi(value) == 1 else (many if many != "" else one + "s")]


## 20480 as "20,480".
static func with_commas(value: int) -> String:
	var digits := str(absi(value))
	var out := ""
	while digits.length() > 3:
		out = "," + digits.substr(digits.length() - 3) + out
		digits = digits.substr(0, digits.length() - 3)
	return ("-" if value < 0 else "") + digits + out


## Choose File... (Texture Extrude's image): the picked file goes into the Image row, as if typed.
func on_button(button: String) -> void:
	if button != "browse" or workspace == null or not is_mesh_tool():
		return
	workspace.files.choose_image(func(path: String) -> void:
		if workspace.command != self:
			return
		var values: Dictionary = workspace.command_values.duplicate(true)
		values["image"] = path
		workspace.set_command_values(values))


## The view's clicks and moves while this command runs, before the picker gets them: fills the
## active selection field when it takes a mesh kind. Returns true when the event was used.
func handle_mouse(event: InputEvent) -> bool:
	if not is_mesh_tool() or workspace == null:
		return false
	var kinds: Array = workspace.active_kinds()
	if not _wants_mesh(kinds):
		return false
	var motion := event as InputEventMouseMotion
	if motion != null:
		var under := mesh_pick_at(motion.position, kinds)
		workspace.set_mesh_hover(under.get("ref", {}))
		# The picker still hovers the field's other kinds (planes, solids).
		return false
	var button := event as InputEventMouseButton
	if button == null or button.button_index != MOUSE_BUTTON_LEFT or not button.pressed:
		return false
	var found := mesh_pick_at(button.position, kinds)
	if found.has("refuse"):
		workspace.flash(str(found.refuse))
		return true
	if not found.has("ref"):
		return false
	var picked: Dictionary = found.ref
	if str(picked.get("kind", "")) == "mesh_boundary":
		picked = _with_rim_normal(picked)
	add_mesh_pick(picked)
	return true


static func _wants_mesh(kinds: Array) -> bool:
	for kind in kinds:
		if MESH_KINDS.has(kind):
			return true
	return false


## What a click at a screen position picks for a field that takes kinds: {"ref": the reference}
## (see the top of this file), {"refuse": why not}, or {} (nothing of a mesh kind there: the
## picker may take it).
func mesh_pick_at(screen: Vector2, kinds: Array) -> Dictionary:
	var view: Control = workspace.viewport
	var bodies: Dictionary = workspace.result.get("bodies", {})
	if kinds.has("mesh_boundary"):
		var loop := _boundary_at(screen)
		if not loop.is_empty():
			return {"ref": loop}
	var hit: Dictionary = view.face_hit_at(screen)
	if hit.is_empty() or not bodies.has(hit.body):
		return {}
	var body_id := str(hit.body)
	var shape: RefCounted = bodies[body_id].shape
	# (A body that a feature after the previewed one makes is not there yet where the tool works.)
	var later: String = workspace.later_body_refusal(body_id) if workspace.has_method("later_body_refusal") else ""
	if later != "":
		return {"refuse": later}
	if not MESH_BODY.is_mesh(shape):
		for kind in kinds:
			if not MESH_KINDS.has(kind):
				return {}
		return {"refuse": NOT_A_MESH % workspace.doc.body_name(body_id)}
	# A face group or a triangle is picked on the body as the tool works on it, not on the
	# preview's result: once the tool has changed the mesh, its triangles are numbered (and its
	# face groups named) differently there. The same ray is cast at the mesh the tool started on.
	var input := _input_shape(body_id)
	if MESH_BODY.is_mesh(input) and not is_same(input, shape) and (kinds.has("mesh_triangles") or kinds.has("mesh_group")) and str(input.digest()) != str(shape.digest()):
		var ray: Array = view.ray_from(screen)
		var on_input: Dictionary = input.ray_hit(ray[0], (ray[1] as Vector3).normalized())
		if bool(on_input.get("hit", false)):
			hit = {"body": body_id, "face": int(on_input.group), "point": on_input.point, "triangle": int(on_input.triangle), "normal": on_input.get("normal")}
		elif int(input.triangle_count()) != int(shape.triangle_count()):
			return {"refuse": ONLY_IN_PREVIEW}
		# (Else the preview only moved the body: its triangles and face groups are the same.)
		shape = input
	var by_triangle: bool = kinds.has("mesh_triangles") and (not kinds.has("mesh_group") or str(workspace.mesh_selection.mode) == MESH_SELECTION.TRIANGLES)
	if by_triangle:
		var ref := MESH_SELECTION.triangle_pick(body_id, PackedInt32Array([int(hit.triangle)]), shape)
		ref["at"] = hit.point
		return {"ref": _with_normal(ref, hit.get("normal"))}
	if kinds.has("mesh_group"):
		var group := int(hit.face)
		var names: PackedStringArray = shape.get_face_names()
		if group < 0 or group >= names.size():
			return {}
		if kinds.has("plane") and not bool((shape.face_info(group) as Dictionary).get("planar", false)):
			return {"refuse": NOT_FLAT}
		# (The name, the point and the facing: what MESH_BODY.resolve_group finds the group by
		# once an earlier change has renamed the groups.)
		return {"ref": _with_normal({"kind": MESH_BODY.GROUP_REF, "body": body_id, "group": str(names[group]), "at": hit.point}, hit.get("normal"))}
	if kinds.has("mesh_body"):
		return {"ref": {"kind": "body", "body": body_id}}
	return {"refuse": NEAR_AN_EDGE} if kinds.has("mesh_boundary") else {}


## Puts a picked reference into the active selection field: a triangle joins (or leaves) its
## body's triangle reference; anything else is added, or taken out when it is already there.
func add_mesh_pick(ref: Dictionary) -> void:
	var panel: Control = workspace.panel
	var field: Dictionary = panel.active_field()
	if field.is_empty():
		return
	var key: String = field.key
	if str(ref.get("kind", "")) != MESH_BODY.TRIANGLES_REF:
		panel.add_selection(ref)
		workspace.refresh_picks()
		return
	var values: Dictionary = workspace.command_values.duplicate(true)
	var list: Array = (values.get(key, []) as Array).duplicate(true)
	var triangle := int((ref.triangles as PackedInt32Array)[0])
	if bool(field.get("separate", false)):
		# One reference per click (Mesh Align's three points): a click on a point already picked
		# takes it out. A point is told by where it lies, not by its triangle: a flat face of two
		# triangles holds all three points.
		var at := -1
		var entry: Dictionary = workspace.result.get("bodies", {}).get(str(ref.body), {})
		var size := 0.0
		if entry.get("shape") != null:
			size = (entry.shape.bbox() as AABB).size.length()
		for i in list.size():
			if not (list[i] is Dictionary) or str(list[i].get("body", "")) != str(ref.body):
				continue
			var held_at: Variant = list[i].get("at")
			if held_at is Vector3 and ref.get("at") is Vector3:
				if (held_at as Vector3).distance_to(ref.at) <= maxf(size * SAME_POINT, 1e-9):
					at = i
			elif (list[i].get("triangles", PackedInt32Array()) as PackedInt32Array) == (ref.triangles as PackedInt32Array):
				at = i
		if at >= 0:
			list.remove_at(at)
		elif list.size() >= int(field.get("limit", 1 << 30)):
			workspace.flash("%s takes %s. Click one again to take it out." % [str(field.get("label", key)), counted(int(field.limit), "pick")])
			return
		else:
			# Where in its triangle the point lies (its weights at the three corners), so its dot
			# can follow a preview that moves the body (shown_point()).
			var weights: Variant = _point_weights(ref, triangle)
			if weights is Vector3:
				ref = ref.duplicate()
				ref["weights"] = weights
			list.append(ref)
	else:
		var merged := false
		for i in list.size():
			var held: Variant = list[i]
			if not (held is Dictionary) or str(held.get("kind", "")) != MESH_BODY.TRIANGLES_REF or str(held.get("body", "")) != str(ref.body):
				continue
			var triangles: PackedInt32Array = held.get("triangles", PackedInt32Array())
			var index := triangles.find(triangle)
			var anchor := {"at": ref.get("at"), "normal": ref.get("normal")}
			if index >= 0:
				triangles.remove_at(index)
				# (The pick's point and facing stay on a triangle it still holds.)
				anchor = _first_anchor(str(ref.body), _input_shape(str(ref.body)), triangles)
			else:
				triangles.append(triangle)
				triangles.sort()
			if triangles.is_empty():
				list.remove_at(i)
			else:
				var next: Dictionary = (held as Dictionary).duplicate()
				next["triangles"] = triangles
				next["digest"] = ref.digest
				for anchored in ["at", "normal"]:
					if anchor.get(anchored) is Vector3:
						next[anchored] = anchor[anchored]
					else:
						next.erase(anchored)
				list[i] = next
			merged = true
			break
		if not merged:
			if bool(field.get("single", false)):
				list = [ref]
			else:
				list.append(ref)
	values[key] = list
	workspace.set_command_values(values)
	workspace.refresh_picks()


## The points of a picked open-edge loop, for drawing ([] when it can't be found any more).
func boundary_points(ref: Dictionary) -> PackedVector3Array:
	var shape := _input_shape(str(ref.get("body", "")))
	if not MESH_BODY.is_mesh(shape):
		return PackedVector3Array()
	for loop in _loops_of(shape):
		if int(loop.id) == int(ref.get("loop", -1)):
			return loop.points
	return PackedVector3Array()


# --- Mesh helpers ----------------------------------------------------------------------------

## Starts the selection fields with what is selected in the workspace: the Mesh selection's face
## groups or triangles, and the selected bodies (mesh bodies for "mesh_body" fields, others for
## "body" fields). A single slot takes the first; no pick goes into two fields.
func _prefill(values: Dictionary) -> void:
	if workspace == null or workspace.get("mesh_selection") == null:
		return
	var bodies: Dictionary = result.get("bodies", {})
	var shapes: Dictionary = workspace.mesh_shapes()
	var selection: RefCounted = workspace.mesh_selection
	var selected_bodies := []
	for pick in workspace.selection:
		if str(pick.get("kind", "")) == "body" and bodies.has(pick.body) and not selected_bodies.has(pick.body):
			selected_bodies.append(str(pick.body))
	var used := {}
	var took_selection := false
	for field in fields():
		if field.type != "selection" or not (field.get("filter") is Array) or bool(field.get("separate", false)):
			continue
		var kinds: Array = field.filter
		var picks := []
		if not took_selection and not selection.is_empty() and (kinds.has("mesh_group") or kinds.has("mesh_triangles")):
			for body_id in selection.bodies():
				var shape: RefCounted = shapes.get(body_id)
				if shape == null:
					continue
				var as_groups: bool = kinds.has("mesh_group") and (str(selection.mode) == MESH_SELECTION.GROUPS or not kinds.has("mesh_triangles"))
				var selected: PackedInt32Array = selection.triangles_of(body_id)
				if as_groups:
					# Each group with a point on it and the facing there, as a group clicked in the
					# view has them: the middle of its first selected triangle.
					var wanted: PackedStringArray = selection.groups_of(body_id, shape)
					var anchors := _group_anchors(body_id, shape, selected, wanted)
					for name in wanted:
						var of_group := {"kind": MESH_BODY.GROUP_REF, "body": body_id, "group": name}
						var anchor: Dictionary = anchors.get(name, {})
						of_group.merge(anchor)
						picks.append(of_group)
				else:
					var of_triangles := MESH_SELECTION.triangle_pick(body_id, selected, shape)
					of_triangles.merge(_first_anchor(body_id, shape, selected))
					picks.append(of_triangles)
			took_selection = not picks.is_empty()
		elif kinds.has("mesh_body") or kinds.has("body"):
			for body_id in selected_bodies:
				var is_mesh := MESH_BODY.is_mesh(bodies[body_id])
				if used.has(body_id) or not (kinds.has("mesh_body") if is_mesh else kinds.has("body")):
					continue
				picks.append({"kind": "body", "body": body_id})
				if bool(field.get("single", false)):
					break
			for pick in picks:
				used[pick.body] = true
		if not picks.is_empty():
			values[field.key] = [picks[0]] if bool(field.get("single", false)) else picks


## A pick with how the surface faces at its point ("normal"), when that is known.
static func _with_normal(ref: Dictionary, normal: Variant) -> Dictionary:
	if normal is Vector3 and (normal as Vector3).length() > 0.5:
		ref["normal"] = (normal as Vector3).normalized()
	return ref


## A picked open-edge loop with the facing of the surface beside the point it was picked at (that
## of a triangle at that point of the rim), so it holds a point and a facing as the other mesh
## picks do.
func _with_rim_normal(ref: Dictionary) -> Dictionary:
	var body_id := str(ref.get("body", ""))
	var shape := _input_shape(body_id)
	if not MESH_BODY.is_mesh(shape) or not (ref.get("at") is Vector3):
		return ref
	var reach := maxf((shape.bbox() as AABB).size.length() * MESH_SELECTION.BOUNDARY_REACH, 1e-9)
	var beside: PackedInt32Array = shape.triangles_near(ref.at, reach, false)
	var anchor := _first_anchor(body_id, shape, beside)
	if anchor.is_empty():
		return ref
	var next := ref.duplicate()
	next["normal"] = anchor.normal
	return next


## For the face groups named in wanted, a point on each and how the surface faces there
## ({name: {"at", "normal"}}): the middle of the first of triangles (stored triangles of the body's
## mesh) that lies in the group and has an area.
func _group_anchors(body_id: String, shape: RefCounted, triangles: PackedInt32Array, wanted: PackedStringArray) -> Dictionary:
	var found := {}
	var names: PackedStringArray = shape.get_face_names()
	var group_of: PackedInt32Array = MESH_SELECTION.triangle_groups(shape) if names.size() > 1 else PackedInt32Array()
	var tried := {}
	for t in triangles:
		var g: int = group_of[t] if t >= 0 and t < group_of.size() else 0
		if g < 0 or g >= names.size() or found.has(names[g]) or int(tried.get(g, 0)) >= ANCHOR_TRIES:
			continue
		tried[g] = int(tried.get(g, 0)) + 1
		var anchor := _triangle_anchor(body_id, shape, t)
		if not anchor.is_empty():
			found[names[g]] = anchor
			if found.size() >= wanted.size():
				break
	return found


## {"at", "normal"} of the first of triangles that has an area ({} when none of the first few has).
func _first_anchor(body_id: String, shape: RefCounted, triangles: PackedInt32Array) -> Dictionary:
	for i in mini(triangles.size(), ANCHOR_TRIES):
		var anchor := _triangle_anchor(body_id, shape, triangles[i])
		if not anchor.is_empty():
			return anchor
	return {}


## The middle of a triangle of a mesh body and how the surface faces there: {"at", "normal"}, or
## {} for a triangle without an area. The facing is the mesh's own word for it (what a ray finds
## there, which MESH_BODY.resolve_group compares a pick's facing with) when a short ray from
## either side reaches the triangle; else the one its corners give.
func _triangle_anchor(body_id: String, shape: RefCounted, triangle: int) -> Dictionary:
	if not MESH_BODY.is_mesh(shape):
		return {}
	var corners := _triangle_corners(body_id, shape, triangle)
	if corners.size() != 3:
		corners = _stored_corners(shape, triangle)
	if corners.size() != 3:
		return {}
	var middle := (corners[0] + corners[1] + corners[2]) / 3.0
	var facing := (corners[2] - corners[0]).cross(corners[1] - corners[0]).normalized()
	if not facing.is_normalized():
		return {}
	var reach := maxf((shape.bbox() as AABB).size.length() * 1e-3, 1e-7)
	for side: float in [1.0, -1.0]:
		var hit: Dictionary = shape.ray_hit(middle + facing * reach * side, -facing * side, reach * 2.0)
		if bool(hit.get("hit", false)) and int(hit.triangle) == triangle and hit.get("normal") is Vector3 and (hit.normal as Vector3).length() > 0.5:
			return {"at": hit.point, "normal": (hit.normal as Vector3).normalized()}
	return {"at": middle, "normal": facing}


## A triangle's corners from the mesh's own arrays (a body the view has not drawn). The arrays of
## the last mesh asked about are kept until the tool has started (_note_start()).
func _stored_corners(shape: RefCounted, triangle: int) -> PackedVector3Array:
	var key := str(shape.digest())
	if not _anchor_arrays.has(key):
		_anchor_arrays.clear()
		_anchor_arrays[key] = shape.get_arrays()
	var arrays: Dictionary = _anchor_arrays[key]
	var indices: PackedInt32Array = arrays.get("indices", PackedInt32Array())
	var positions: PackedVector3Array = arrays.get("positions", PackedVector3Array())
	if triangle < 0 or triangle * 3 + 2 >= indices.size():
		return PackedVector3Array()
	return PackedVector3Array([positions[indices[triangle * 3]], positions[indices[triangle * 3 + 1]], positions[indices[triangle * 3 + 2]]])


## An existing feature is being edited: before is the model as it stands before that feature (a
## REGEN result, FORGE_WORKSPACE.bodies_before()). The tool's picks, its overlays and the stat
## row's "before" are of those bodies, as they are for a new feature of the bodies it started on.
func note_input(before: Dictionary) -> void:
	if not is_mesh_tool() or not (before.get("bodies") is Dictionary):
		return
	_started_with.clear()
	_started_shapes.clear()
	_started_tess.clear()
	_preview_key = ""
	for body_id in before.bodies:
		var shape: RefCounted = before.bodies[body_id].shape
		if MESH_BODY.is_mesh(shape):
			_started_with[body_id] = int(shape.triangle_count())
			_started_shapes[body_id] = shape
	_input_known = true


## The bodies the tool works on: those its picks name or lie on, and those its feature made or
## changed in the last rebuild (ids, in pick order).
func picked_bodies(values: Dictionary) -> Array:
	var ids := []
	for field in fields():
		if field.type != "selection":
			continue
		for pick in values.get(field.key, []):
			var id := str(pick) if pick is String else (str((pick as Dictionary).get("body", "")) if pick is Dictionary else "")
			if id != "" and not ids.has(id):
				ids.append(id)
	if is_mesh_tool() and feature != null:
		for id in _made_bodies():
			if not ids.has(id):
				ids.append(id)
	return ids


## Where a point picked on a mesh (a triangle pick with "at") lies on the body as it is shown:
## the same spot of its triangle when the preview only moved the mesh's points (Mesh Align's
## preview turns the body), else where it was picked. null for a pick without a point.
func shown_point(ref: Dictionary) -> Variant:
	var at: Variant = ref.get("at")
	if not (at is Vector3):
		return null
	var body_id := str(ref.get("body", ""))
	var weights: Variant = ref.get("weights")
	var triangles: PackedInt32Array = ref.get("triangles", PackedInt32Array())
	var now: Variant = (result.get("bodies", {}) as Dictionary).get(body_id, {}).get("shape")
	if weights is Vector3 and triangles.size() == 1 and workspace != null and MESH_BODY.is_mesh(now) and str(ref.get("digest", "")) != str(now.digest()) and triangles_shown(body_id, ref):
		var corners: PackedVector3Array = workspace.viewport.mesh_triangle_points(body_id, triangles[0])
		if corners.size() == 3:
			return corners[0] * weights.x + corners[1] * weights.y + corners[2] * weights.z
	return at


## Where in its triangle a picked point lies: its weights at the three corners, or null. The
## triangle is that of the mesh the pick was made on: the one the tool works on, else (a body
## the preview has moved) the one shown; the one the point really lies on is taken.
func _point_weights(ref: Dictionary, triangle: int) -> Variant:
	if not (ref.get("at") is Vector3):
		return null
	var body_id := str(ref.get("body", ""))
	var at: Vector3 = ref.at
	var shown: Variant = (result.get("bodies", {}) as Dictionary).get(body_id, {}).get("shape")
	for shape in [_input_shape(body_id), shown]:
		if not MESH_BODY.is_mesh(shape):
			continue
		var corners := _triangle_corners(body_id, shape, triangle)
		if corners.size() != 3:
			continue
		var weights := Geometry3D.get_triangle_barycentric_coords(at, corners[0], corners[1], corners[2])
		var back := corners[0] * weights.x + corners[1] * weights.y + corners[2] * weights.z
		var reach := maxf(corners[0].distance_to(corners[1]), corners[0].distance_to(corners[2]))
		if back.distance_to(at) <= reach * 1e-3 + 1e-9:
			return weights
	return null


## The corners of a triangle of the mesh a pick was made on (shape: the one shown, or the one the
## tool works on).
func _triangle_corners(body_id: String, shape: RefCounted, triangle: int) -> PackedVector3Array:
	var shown: Variant = (result.get("bodies", {}) as Dictionary).get(body_id, {}).get("shape")
	if workspace != null and is_same(shape, shown):
		return workspace.viewport.mesh_triangle_points(body_id, triangle)
	if not _started_shapes.has(body_id) or not is_same(shape, _started_shapes[body_id]):
		return PackedVector3Array()
	if not _started_tess.has(body_id):
		_started_tess[body_id] = TESSELLATE.tessellate(_started_shapes[body_id])
	var tess: Dictionary = _started_tess[body_id]
	var indices: PackedInt32Array = tess.get("indices", PackedInt32Array())
	var positions: PackedVector3Array = tess.get("positions", PackedVector3Array())
	if triangle < 0 or triangle * 3 + 2 >= indices.size():
		return PackedVector3Array()
	return PackedVector3Array([positions[indices[triangle * 3]], positions[indices[triangle * 3 + 1]], positions[indices[triangle * 3 + 2]]])


## Remembers each body's triangle count as the command starts (the stat row's "before").
func _note_start() -> void:
	_started_with.clear()
	_started_shapes.clear()
	_started_tess.clear()
	_anchor_arrays.clear()
	_preview_key = ""
	_input_known = false
	for body_id in result.get("bodies", {}):
		var shape: RefCounted = result.bodies[body_id].shape
		if MESH_BODY.is_mesh(shape):
			_started_with[body_id] = int(shape.triangle_count())
			_started_shapes[body_id] = shape


## What the tool draws over the bodies while it is open: [{"mesh": ArrayMesh, "look": "removed" |
## "fill" | "selected"}] (ui/mesh_display.gd materials). "selected": the triangles picked for the
## tool, once its preview has changed the mesh they were picked on. "removed": what a Plane Cut (Trim) takes away and what
## Erase and Fill erases, on the meshes as they were when the tool started (so it shows even when
## the preview itself was skipped; not when an existing feature is edited, where the mesh before it
## is not at hand). "fill": the triangles of face groups the tool added as fills or caps.
func preview_meshes(values: Dictionary) -> Array:
	if not is_mesh_tool() or feature == null:
		return []
	var removed := {}
	if not editing or _input_known:
		match str(spec.get("method", "")):
			"plane_cut":
				var plane: Variant = _removed_side(values)
				if plane != null and str(values.get("type", "trim")) == "trim":
					for body_id in metrics(values).ids:
						var shape: RefCounted = _started_shapes.get(body_id)
						if shape != null:
							removed[body_id] = shape.triangles_in_frustum([plane], "inside")
			"erase_fill":
				for pick in values.get("selection", []):
					var shape: RefCounted = _started_shapes.get(pick.get("body", "")) if pick is Dictionary else null
					if shape == null:
						continue
					var triangles: PackedInt32Array = removed.get(pick.body, PackedInt32Array())
					if str(pick.get("kind", "")) == MESH_BODY.TRIANGLES_REF and str(pick.get("digest", "")) == str(shape.digest()):
						triangles.append_array(pick.get("triangles", PackedInt32Array()))
					elif str(pick.get("kind", "")) == MESH_BODY.GROUP_REF:
						var group := int(shape.find_face(str(pick.get("group", ""))))
						if group >= 0:
							triangles.append_array(shape.group_triangles(group))
					removed[pick.body] = triangles
	# Picked triangles, once the preview has changed the mesh they were picked on: drawn from the
	# mesh the tool started on (on the preview's mesh their numbers mean other triangles). Erase
	# and Fill shows them as removed already.
	var picked := {}
	if (not editing or _input_known) and str(spec.get("method", "")) != "erase_fill":
		for field in fields():
			if field.type != "selection":
				continue
			for pick in values.get(field.key, []):
				if not (pick is Dictionary) or str(pick.get("kind", "")) != MESH_BODY.TRIANGLES_REF:
					continue
				var before: RefCounted = _started_shapes.get(pick.get("body", ""))
				if before == null or str(pick.get("digest", "")) != str(before.digest()) or triangles_shown(str(pick.body), pick):
					continue
				var triangles: PackedInt32Array = picked.get(pick.body, PackedInt32Array())
				triangles.append_array(pick.get("triangles", PackedInt32Array()))
				picked[pick.body] = triangles
	# Fills and caps: face groups named fill<k> or cut<k> that the body did not have at the start.
	var filled := {}
	for body_id in _made_bodies():
		var now: RefCounted = result.bodies[body_id].shape
		var before: RefCounted = _started_shapes.get(body_id)
		if not MESH_BODY.is_mesh(now) or before == null or is_same(now, before):
			continue
		var old: PackedStringArray = before.get_face_names()
		var names: PackedStringArray = now.get_face_names()
		var triangles := PackedInt32Array()
		for i in names.size():
			if (names[i].begins_with("fill") or names[i].begins_with("cut")) and not old.has(names[i]):
				triangles.append_array(now.group_triangles(i))
		if not triangles.is_empty():
			filled[body_id] = triangles
	var key := "%d|%d|%d" % [hash(removed), hash(filled), hash(picked)]
	for body_id in filled:
		key += "|" + str(result.bodies[body_id].shape.digest())
	if key == _preview_key:
		return _preview_entries
	_preview_key = key
	_preview_entries = []
	for body_id in removed:
		var triangles: PackedInt32Array = removed[body_id]
		if triangles.is_empty() or triangles.size() > PREVIEW_TRIANGLES:
			continue
		if not _started_tess.has(body_id):
			_started_tess[body_id] = TESSELLATE.tessellate(_started_shapes[body_id])
		_preview_entries.append({"mesh": MESH_DISPLAY.selection_mesh(_started_tess[body_id], triangles), "look": "removed", "body": body_id, "triangles": triangles.size()})
	for body_id in picked:
		var triangles: PackedInt32Array = picked[body_id]
		if triangles.is_empty() or triangles.size() > PREVIEW_TRIANGLES:
			continue
		if not _started_tess.has(body_id):
			_started_tess[body_id] = TESSELLATE.tessellate(_started_shapes[body_id])
		_preview_entries.append({"mesh": MESH_DISPLAY.selection_mesh(_started_tess[body_id], triangles), "look": "selected", "body": body_id, "triangles": triangles.size()})
	for body_id in filled:
		var triangles: PackedInt32Array = filled[body_id]
		if triangles.size() > PREVIEW_TRIANGLES:
			continue
		_preview_entries.append({"mesh": MESH_DISPLAY.selection_mesh(TESSELLATE.tessellate(result.bodies[body_id].shape), triangles), "look": "fill", "body": body_id, "triangles": triangles.size()})
	return _preview_entries


## The half space a Plane Cut (Trim) takes away, as a Plane whose normal points out of it (the
## form CadMesh.triangles_in_frustum takes): the side the plane's normal points away from, or with
## Keep Other Side the side it points to. null while no plane is picked.
func _removed_side(values: Dictionary) -> Variant:
	var refs: Array = values.get("plane", [])
	if refs.is_empty() or not refs[0] is Dictionary or workspace == null:
		return null
	var found := REFERENCES.plane(refs[0], INSPECT.context(result, workspace.doc, workspace.kernel))
	if found.has("error"):
		return null
	var normal := (found.normal as Vector3).normalized()
	var origin: Vector3 = (found.origin as Vector3) + normal * float(evaluated_values(values).get("offset", 0.0))
	return Plane(-normal, origin) if bool(values.get("flip", false)) else Plane(normal, origin)


## A "$..." default as the text the field shows: "$D/150", "$T/2", "$detail*2", "$m:0.0001".
func _default_text(field: Dictionary, values: Dictionary) -> String:
	var token := str(field.get("default", "")).trim_prefix("$")
	var kind := str(field.get("kind", "length"))
	var measured := metrics(values)
	var amount := 0.0
	if token.begins_with("m:"):
		amount = token.trim_prefix("m:").to_float()
	else:
		amount = _formula(token, evaluated_values(values), measured)
		if is_nan(amount):
			amount = 0.0
	var voxel: Dictionary = spec.get("voxel", {})
	if str(voxel.get("field", "")) == str(field.key):
		amount = _fitting_cell(amount, voxel, values, measured)
	if kind == "number":
		return _number_text(roundf(amount) if bool(field.get("whole", false)) else amount)
	return _length_text(amount).get_slice(" ", 0) if kind == "length" else _number_text(rad_to_deg(amount))


## A cell size no smaller than what fits the grid cap (MESH.MAX_VOXEL_SAMPLES) on the picked
## bodies: the kernel's own answer for one body (CadMesh.op_defaults), else worked out from the
## bodies' bounds grown by the tool's margin.
func _fitting_cell(wanted: float, voxel: Dictionary, values: Dictionary, measured: Dictionary) -> float:
	if not bool(measured.get("known", false)):
		return wanted
	var shapes: Array = measured.shapes
	var evaluated := evaluated_values(values)
	if shapes.size() == 1 and MESH_BODY.is_mesh(shapes[0]) and shapes[0].has_method("op_defaults"):
		var asked := {}
		for key in voxel.get("margin", []):
			if evaluated.has(key) and key != "gap" and key != "offset":
				asked[key] = evaluated[key]
		var answer: Dictionary = shapes[0].op_defaults(str(voxel.get("op", "")), asked)
		if float(answer.get("detail", 0.0)) > 0.0:
			return float(answer.detail)
	var box: AABB = measured.get("box", AABB())
	var cell := maxf(wanted, 1e-9)
	for attempt in 24:
		var margin := float(voxel.get("cells", 2.0)) * cell
		for key in voxel.get("margin", []):
			margin += absf(float(evaluated.get(key, 2.0 * cell if key == "gap" else 0.0)))
		var cells := 1.0
		for axis in 3:
			cells *= ceilf((box.size[axis] + 2.0 * margin) / cell) + 1.0
		if cells <= float(MESH.MAX_VOXEL_SAMPLES):
			break
		cell *= maxf(pow(cells / float(MESH.MAX_VOXEL_SAMPLES), 1.0 / 3.0), 1.01)
	return cell


## A range bound or default formula: a number, or "[-]name[op number]" with name D, T or a
## field's key and op one of * / + -. NAN when it names something not known yet.
func _formula(text: Variant, evaluated: Dictionary, measured: Dictionary) -> float:
	if text is float or text is int:
		return float(text)
	var formula := str(text).strip_edges()
	if formula == "":
		return NAN
	if formula.is_valid_float():
		return formula.to_float()
	var sign := 1.0
	if formula.begins_with("-"):
		sign = -1.0
		formula = formula.substr(1)
	var at := -1
	for i in range(1, formula.length()):
		if formula[i] in ["*", "/", "+", "-"]:
			at = i
			break
	var name := formula if at < 0 else formula.substr(0, at)
	var base := NAN
	if name == "D":
		base = float(measured.D) if bool(measured.get("known", false)) or not measured.has("strict") else NAN
	elif name == "T":
		base = float(measured.T) if int(measured.get("T", 0)) > 0 else NAN
	elif evaluated.has(name):
		base = float(evaluated[name])
	if is_nan(base):
		return NAN
	if at < 0:
		return sign * base
	var number := formula.substr(at + 1).to_float()
	match formula[at]:
		"*":
			return sign * base * number
		"/":
			return sign * base / number if number != 0.0 else NAN
		"+":
			return sign * base + number
	return sign * base - number


## A range bound in base units (an angle's bound is written in degrees); NAN when it can't be
## known yet (no body picked: D and T mean nothing then).
func _bound(bound: Variant, kind: String, evaluated: Dictionary, measured: Dictionary) -> float:
	var strict := measured.duplicate()
	strict["strict"] = true
	var value := _formula(bound, evaluated, strict)
	return deg_to_rad(value) if kind == "angle" and not is_nan(value) else value


func _bound_text(value: float, kind: String) -> String:
	if is_nan(value):
		return "?"
	match kind:
		"length":
			return _length_text(value)
		"angle":
			return _number_text(rad_to_deg(value)) + " deg"
	return with_commas(int(value)) if absf(value - roundf(value)) < 1e-9 and absf(value) >= 1000.0 else _number_text(value)


## A length in the document's unit with about four significant digits ("0.0125 mm").
func _length_text(meters: float) -> String:
	var units := str(hints.get("units", "mm"))
	return "%s %s" % [_number_text(meters / float(UNITS.LENGTH_UNITS.get(units, 0.001))), units]


## A number with about four significant digits and no trailing zeros (String % has no %g).
static func _number_text(value: float) -> String:
	if value == 0.0 or not is_finite(value):
		return "0"
	var decimals := clampi(3 - int(floor(log(absf(value)) / log(10.0))), 0, 9)
	var text := String.num(value, decimals)
	if text.contains("."):
		text = text.rstrip("0").rstrip(".")
	return "0" if text == "-0" or text == "" else text


func _triangles_line(before: int, after: int) -> String:
	if before <= 0 or before == after:
		return "Triangles: %s" % with_commas(after)
	return "Triangles: %s → %s (%s%%)" % [with_commas(before), with_commas(after), String.num(100.0 * after / before, 1)]


## The op's report of the last rebuild, when the mesh handler publishes one
## (core/features/mesh.gd `reports`: feature id -> CadMesh.get_last_report(), with an optional
## "stat" line of the tool's own); {} otherwise.
func _report() -> Dictionary:
	# (Read through the script object: the handler may not publish reports in this build.)
	var handler: Script = MESH
	var published: Variant = handler.get("reports")
	if published is Dictionary and (published as Dictionary).get(feature.id) is Dictionary:
		return published[feature.id]
	return {}


## A value the kernel used in the feature's last build, by its key in the op's own report (one
## body's op); 0 when there is none.
func _used_value(report_key: String) -> float:
	if report_key == "" or feature == null:
		return 0.0
	var report := _report()
	var value: Variant = report.get(report_key)
	if not (value is float or value is int):
		var bodies: Variant = report.get("bodies")
		if bodies is Array and (bodies as Array).size() == 1 and bodies[0] is Dictionary:
			value = (bodies[0] as Dictionary).get(report_key)
	return float(value) if value is float or value is int else 0.0


## The bodies the feature made or changed in the last rebuild.
func _made_bodies() -> Array:
	var made := []
	for body_id in result.get("bodies", {}):
		if str(result.bodies[body_id].get("feature", "")) == feature.id:
			made.append(body_id)
	return made


## CadMesh.check() of a mesh (its linear part, within MESH.CHECK_SECONDS), asked once per mesh.
func _checked(shape: RefCounted) -> Dictionary:
	var key := str(shape.digest())
	if not _checks.has(key):
		if _checks.size() >= 8:
			_checks.clear()
		_checks[key] = shape.check(MESH.CHECK_SECONDS)
	return _checks[key]


func _loops_of(shape: RefCounted) -> Array:
	var key := str(shape.digest())
	if not _loops.has(key):
		if _loops.size() >= 4:
			_loops.clear()
		_loops[key] = shape.boundary_loops()
	return _loops[key]


## True when the triangle numbers of a pick mean the same triangles on the mesh shown now: it is
## the mesh they were picked on, or that mesh with only its points moved (the same triangle count
## and face groups: a preview that moved or smoothed the body).
func triangles_shown(body_id: String, pick: Dictionary) -> bool:
	var now: Variant = (result.get("bodies", {}) as Dictionary).get(body_id, {}).get("shape")
	if not MESH_BODY.is_mesh(now):
		return false
	var digest := str(pick.get("digest", ""))
	if digest == "" or digest == str(now.digest()):
		return true
	var before := _input_shape(body_id)
	return MESH_BODY.is_mesh(before) and digest == str(before.digest()) and int(before.triangle_count()) == int(now.triangle_count()) and before.get_face_names() == now.get_face_names()


## A mesh body as the tool works on it: the mesh it had when the tool started, or, for an
## existing feature being edited, the mesh before that feature (note_input()). The preview shows
## the tool's result, where a hole it closed has no open edge left to pick. Else the one shown.
func _input_shape(body_id: String) -> RefCounted:
	if (not editing or _input_known) and _started_shapes.has(body_id):
		return _started_shapes[body_id]
	return (workspace.result.get("bodies", {}) as Dictionary).get(body_id, {}).get("shape") if workspace != null else null


## The open-edge loop nearest a screen position (within BOUNDARY_PICK_PX) as a reference, or {}.
## The loops are those of the bodies as the tool works on them (_input_shape()): with every hole
## closed in the preview, a click at a fill's rim still picks that hole.
func _boundary_at(screen: Vector2) -> Dictionary:
	var view: Control = workspace.viewport
	var best := {}
	var best_px := BOUNDARY_PICK_PX
	for body_id in workspace.result.get("bodies", {}):
		var shape := _input_shape(str(body_id))
		if not MESH_BODY.is_mesh(shape) or not workspace.doc.body_visible(body_id) or (workspace.has_method("later_body_refusal") and workspace.later_body_refusal(str(body_id)) != ""):
			continue
		for loop in _loops_of(shape):
			var points: PackedVector3Array = loop.points
			var previous: Vector2 = view.project(points[points.size() - 1]) if not points.is_empty() else Vector2.INF
			for i in points.size():
				var here: Vector2 = view.project(points[i])
				if here.is_finite() and previous.is_finite():
					var near := Geometry2D.get_closest_point_to_segment(screen, previous, here)
					var px := near.distance_to(screen)
					if px < best_px:
						best_px = px
						best = {"kind": "mesh_boundary", "body": body_id, "loop": int(loop.id), "edges": int(loop.edges),
							"digest": str(shape.digest()), "at": points[i]}
				previous = here
	return best


# --- Helpers ---------------------------------------------------------------------------------

func _write_options(values: Dictionary) -> void:
	for field in fields():
		# Expressions are inputs; notes and buttons hold nothing.
		if field.type == "expression" or field.type == "info" or field.type == "button":
			continue
		var k: String = field.key
		var value = values.get(k, field.get("default"))
		if str(field.get("parse", "")) == "int_list":
			var numbers := []
			for part in str(value).split(",", false):
				if part.strip_edges().is_valid_int():
					numbers.append(int(part.strip_edges()))
			value = numbers
		if field.type == "point" and value is Vector3:
			# (With the exact copy in doubles when float32 rounds it: core/point64.gd.)
			var point_values := {k: value}
			POINT64.read(point_values, k, values)
			POINT64.store(feature.options, k, point_values)
			continue
		feature.options[k] = value.duplicate(true) if value is Array or value is Dictionary else value
	# A hidden Operation (a stitched Patch's): the feature makes no body of its own (sync_body).
	if str(spec.get("op", "")) != "" and not _shown({"visible_if": spec.get("op_visible_if", {})}, values):
		feature.options.erase("operation")
		feature.options.erase("targets")


func _shown(field: Dictionary, values: Dictionary) -> bool:
	var condition: Dictionary = field.get("visible_if", {})
	for other in condition:
		if not (condition[other] as Array).has(values.get(other)):
			return false
	return true


## "$size" (a size that suits the view) or "$size/4" as text in document units.
func _size_text(token: String) -> String:
	var meters := float(hints.get("default_size_m", 0.05))
	if token.contains("/"):
		meters /= maxf(float(token.get_slice("/", 1)), 1e-9)
	var units := str(hints.get("units", "mm"))
	return UNITS.format_value(meters, UNITS.KIND_LENGTH, units).split(" ")[0]


## Where the distance arrow starts and which way it points (extrude: the profile's plane, or the
## picked Direction; curves and edges: where the made body starts, so the tip sits on its far end;
## offset face, press pull: the face; offset plane: the base plane). amount: the distance.
func _arrow_frame(values: Dictionary, amount := 0.0) -> Dictionary:
	var refs: Array = values.get("pick", values.get("profiles", values.get("faces", values.get("plane", []))))
	if refs.is_empty() or not refs[0] is Dictionary:
		return {}
	var ref: Dictionary = refs[0]
	var flip := -1.0 if bool(values.get("flip", false)) else 1.0
	if is_mesh_tool():
		# A mesh tool's plane (Plane Cut): its Flip keeps the other side, the offset's way stays; the
		# arrow stands on the plane under the picked bodies' middle.
		var ctx := INSPECT.context(result, workspace.doc if workspace != null else null, workspace.kernel if workspace != null else null)
		var found := REFERENCES.plane(ref, ctx)
		if found.has("error"):
			return {}
		var normal := (found.normal as Vector3).normalized()
		var origin: Vector3 = found.origin
		var measured := metrics(values)
		if bool(measured.get("known", false)):
			var center: Vector3 = measured.center
			origin = center - normal * (center - origin).dot(normal)
		return {"origin": origin, "direction": normal}
	var along := _picked_direction(values)
	match str(ref.get("kind", "")):
		"profile":
			var sketch_state: Dictionary = result.get("sketches", {}).get(ref.get("sketch", ""), {})
			if sketch_state.is_empty():
				return {}
			var plane: Transform3D = sketch_state.plane
			var normal := plane.basis.z if along.is_zero_approx() else along
			return {"origin": plane * Vector3(float(ref.point.x), float(ref.point.y), 0.0), "direction": normal * flip}
		"sketch_curve", "edge":
			return _from_body((_curves_normal(refs) if along.is_zero_approx() else along) * flip, amount, values)
		"face":
			var body: Dictionary = result.get("bodies", {}).get(ref.get("body", ""), {})
			if body.is_empty():
				return {}
			var index: int = body.shape.find_face(str(ref.get("name", "")))
			var info: Dictionary = body.shape.face_info(index) if index >= 0 else {}
			if not info.get("planar", false):
				return {}
			var normal: Vector3 = info.normal if along.is_zero_approx() else along
			return {"origin": info.point, "direction": normal * flip}
		"origin", "construct":
			var c: Dictionary = result.get("construction", {}).get(ref.get("feature", ""), {}) if ref.kind == "construct" else {}
			if ref.kind == "origin":
				var normals := {"xy": Vector3.BACK, "xz": Vector3.UP, "yz": Vector3.RIGHT}
				return {"origin": Vector3.ZERO, "direction": normals.get(ref.get("name", ""), Vector3.UP)} if normals.has(ref.get("name", "")) else {}
			return {"origin": c.origin, "direction": c.normal} if c.get("type", "") == "plane" else {}
	return {}


## The picked Direction (Surface Extrude: an axis, or a plane's normal), found in the last
## rebuild; ZERO when none is picked or it can't be found.
func _picked_direction(values: Dictionary) -> Vector3:
	var picks: Variant = values.get("direction", [])
	if not picks is Array or (picks as Array).is_empty() or not picks[0] is Dictionary:
		return Vector3.ZERO
	var ctx := INSPECT.context(result, workspace.doc if workspace != null else null, workspace.kernel if workspace != null else null)
	var found := REFERENCES.axis(picks[0], ctx)
	if found.has("error"):
		found = REFERENCES.plane(picks[0], ctx)
		return (found.get("normal", Vector3.ZERO) as Vector3).normalized()
	return (found.direction as Vector3).normalized()


## The normal of the picked curves' sketch, or of the plane picked body edges lie in (as the
## surface extrude takes them); ZERO when they set none.
func _curves_normal(refs: Array) -> Vector3:
	var ref: Dictionary = refs[0]
	if ref.kind == "sketch_curve":
		var sketch_state: Dictionary = result.get("sketches", {}).get(ref.get("sketch", ""), {})
		return (sketch_state.plane as Transform3D).basis.z if not sketch_state.is_empty() else Vector3.ZERO
	var edges := []
	for pick in refs:
		var body: Dictionary = result.get("bodies", {}).get(str(pick.get("body", "")), {}) if pick is Dictionary else {}
		var index: int = body.shape.find_edge(str(pick.get("name", ""))) if not body.is_empty() and pick.get("kind", "") == "edge" else -1
		if index >= 0:
			edges.append(body.shape.edge_shape(index))
	var found := SKETCH_SOLID._edges_plane(edges) if not edges.is_empty() else {}
	return (found.plane as Transform3D).basis.z if not found.is_empty() else Vector3.ZERO


## The arrow along direction for the body this feature made, from where the body starts, so the
## tip lands on its far end ({} without a body, or for extents other than a distance).
func _from_body(direction: Vector3, amount: float, values: Dictionary) -> Dictionary:
	if direction.is_zero_approx() or str(values.get("extent", "distance")) != "distance" or feature == null:
		return {}
	var body: Dictionary = result.get("bodies", {}).get(str(feature.options.get("body_id", "")), {})
	if body.is_empty():
		return {}
	var box: AABB = body.shape.bbox()
	var d := direction.normalized()
	var lo := INF
	var hi := -INF
	for i in 8:
		var t := box.get_endpoint(i).dot(d)
		lo = minf(lo, t)
		hi = maxf(hi, t)
	var far := hi if amount >= 0.0 else lo
	var center := box.get_center()
	return {"origin": center + d * (far - amount - center.dot(d)), "direction": d}


# --- Press Pull --------------------------------------------------------------------------------

## The feature type a pick makes: a profile extrudes (into a surface body in the Surface
## workspace), an edge fillets, a face offsets.
func _press_pull_type(values: Dictionary) -> String:
	var picks: Array = values.get("pick", [])
	if picks.is_empty() or not picks[0] is Dictionary:
		return "offset_face"
	var type: String = PRESS_PULL_TYPES.get(str(picks[0].get("kind", "")), "offset_face")
	return "surface" if type == "extrude" and key == SURFACE_PRESS_PULL else type


func _press_pull_feature(doc: Resource, values: Dictionary) -> Resource:
	var type := _press_pull_type(values)
	var options := {"press_pull_pick": (values.get("pick", []) as Array).duplicate(true)}
	var picks: Array = options.press_pull_pick
	match type:
		"extrude":
			options.merge({"profiles": picks, "operation": OPERATIONS.AUTO, "targets": []})
		"surface":
			options.merge({"method": "extrude", "profiles": picks, "operation": OPERATIONS.NEW_BODY, "targets": []})
		"fillet":
			options.merge({"edges": picks, "radius_type": "constant"})
		_:
			options.merge({"faces": picks})
	var input_key := "radius" if type == "fillet" else "distance"
	var label: String = {"extrude": "Extrude", "surface": "SurfaceExtrude", "fillet": "Fillet", "offset_face": "OffsetFace"}[type]
	feature = doc.add_feature(type, label, {input_key: doc.make_input(str(values.get("distance", "1")), "length")}, options)
	sync_body(doc, feature)
	return feature


func _press_pull_write(doc: Resource, values: Dictionary) -> void:
	var type := _press_pull_type(values)
	if type != feature.type:
		# The pick changed kind: swap the feature for the matching one, at the same place.
		var at: int = doc.feature_index(feature.id)
		var saved_rollback: int = doc.rollback
		doc.remove_feature(feature.id)
		doc.rollback = at
		_press_pull_feature(doc, values)
		doc.rollback = saved_rollback
		return
	var picks: Array = (values.get("pick", []) as Array).duplicate(true)
	feature.options["press_pull_pick"] = picks
	match type:
		"extrude", "surface":
			feature.options["profiles"] = picks
			if type == "extrude" and str(feature.options.get("operation", "")) == OPERATIONS.JOIN:
				feature.options["operation"] = OPERATIONS.AUTO
				sync_body(doc, feature)
		"fillet":
			feature.options["edges"] = picks
		_:
			feature.options["faces"] = picks
	var input_key := "radius" if type == "fillet" else "distance"
	feature.set_expression(input_key, str(values.get("distance", "1")))
