@tool
extends RefCounted
## The Form tool registry (contract C7). Three scripts declare tools, so the Stage-3 teams never
## edit the same file: this one (the primitives, Edit Form, Display Mode, Crease / UnCrease, Freeze
## / Unfreeze and Clear Symmetry), ui/form_tools_create.gd (sketch-based creates) and
## ui/form_tools_modify.gd (the other modify, symmetry and utility tools). spec(), has_tool() and
## run() look in all three; a tool runs in the script that declares its id.
##
## A spec: {"title", "picks": [{"key", "label", "kinds": ["vertex"|"edge"|"face"|"body"|"profile"|
## "sketch_curve"|"model_edge"|"model_face"|"model_body"|"plane"|"axis"|"point"], "count" (-1 any),
## "required"}], "fields" (tools/command.gd field dicts), "defaults", "uses_selection", "preview",
## "native" (needs CadSubD), "repeat" (restart after OK), "interact" (the declaring script gets
## handle_mouse_<id>(editor, event) -> bool and draw_<id>(editor, overlay): clicks and drags of
## its own, like picks on the model or a curve's control points), "handles" (handles_<id>(editor,
## values) -> [{"type": "arrow"|"count"|"slider", "key", "origin", "direction", ...}], drawn and
## dragged by the editor: an arrow sets a length, base + distance dragged * "factor" (with "kind":
## "number" a plain number), clamped to "min" / "max" when given; a count steps a whole number; a
## slider is a knob on the segment origin + direction * [min, max] whose value is that fraction),
## "plane" (asks for a placement plane first), "select_through" (window and click selection take
## hidden elements while the tool runs; the setting comes back afterwards)}. Panel buttons the
## editor doesn't handle itself go to button_<id>(editor, key).
## Defaults may say "@S" (the workspace's default size), "@S4" (a quarter of it) or "@S5" (a fifth).
##
## run_<id>(ctx, picks, values) -> {"ok", "error", "warnings", "cages": {body id: cage},
## "new_bodies": [cage], "removed_bodies": [body id], "breps": {body id: bytes}, "display":
## {body id: mode}, "selection": [items], "info": {"panel": {info field key: text}, ...}}. ctx:
## {"feature", "doc", "cages": {body id: cage}, "subd": Callable(body id) -> CadSubD, "kernel",
## "result", "values" (evaluated: meters, radians, numbers), "editor", "panel" (a dictionary the
## tool may fill with info field texts instead of returning them; run() merges it into
## info.panel)}. picks: pick key -> Array of selection items ({"kind", "body",
## "index", "pair"}) or, for "placement", [{"origin", "x", "y", "normal"}].
##
## Never preload catalog.gd, forge_workspace.gd or form_editor.gd here (catalog.gd preloads this).

const CAGE := preload("res://addons/holo_forge/core/form/cage.gd")
const FORM_OPS := preload("res://addons/holo_forge/core/form/form_ops.gd")
const PRIMITIVES := preload("res://addons/holo_forge/core/form/primitives.gd")
const MANIPULATOR := preload("res://addons/holo_forge/core/manipulator_math.gd")
const UNITS := preload("res://addons/holo_forge/core/units.gd")
const CREATE := preload("res://addons/holo_forge/ui/form_tools_create.gd")
## The range of a typed scale factor (Edit Form, Edit By Curve): 0 would flatten the selection
## and a negative factor mirror it inside out; the gizmo's own scale drags stop at 0.01 too.
const SCALE_RANGE := [0.01, 1000.0]
const MODIFY := preload("res://addons/holo_forge/ui/form_tools_modify.gd")

const _BODY_FIELD := {"key": "body", "label": "Body", "type": "enum", "options": "bodies"}
const _COUNT_TIP := "Faces along this direction (whole numbers)"

const TOOLS := {
	"box": {
		"title": "Box", "plane": true, "interact": true, "handles": true, "preview": true, "clicks": 3,
		"picks": [],
		"fields": [
			{"key": "placement", "label": "Placement", "type": "enum", "options": [["center", "Rectangle Center"], ["two_point", "2-Point"]]},
			{"key": "length", "label": "Length X", "type": "expression", "kind": "length"},
			{"key": "width", "label": "Width Y", "type": "expression", "kind": "length"},
			{"key": "height", "label": "Height Z", "type": "expression", "kind": "length"},
			{"key": "length_faces", "label": "Length Faces", "type": "expression", "kind": "number", "range": [1, 64, true]},
			{"key": "width_faces", "label": "Width Faces", "type": "expression", "kind": "number", "range": [1, 64, true]},
			{"key": "height_faces", "label": "Height Faces", "type": "expression", "kind": "number", "range": [1, 64, true]},
			{"key": "direction", "label": "Direction", "type": "enum", "options": [["one_side", "One Side"], ["symmetric", "Symmetric"]]},
			{"key": "symmetry", "label": "Symmetry", "type": "enum", "options": [["none", "None"], ["mirror", "Mirror"]]},
			{"key": "sym_x", "label": "Length Mirror", "type": "bool", "visible_if": {"symmetry": ["mirror"]}},
			{"key": "sym_y", "label": "Width Mirror", "type": "bool", "visible_if": {"symmetry": ["mirror"]}},
			{"key": "sym_z", "label": "Height Mirror", "type": "bool", "visible_if": {"symmetry": ["mirror"]}},
			_BODY_FIELD,
		],
		"defaults": {"placement": "center", "length": "@S", "width": "@S", "height": "@S", "length_faces": "2", "width_faces": "2",
			"height_faces": "2", "direction": "one_side", "symmetry": "none", "sym_x": true, "sym_y": false, "sym_z": false, "body": "new"},
	},
	"plane": {
		"title": "Plane", "plane": true, "interact": true, "handles": true, "preview": true, "clicks": 2,
		"picks": [],
		"fields": [
			{"key": "placement", "label": "Placement", "type": "enum", "options": [["center", "Rectangle Center"], ["two_point", "2-Point"]]},
			{"key": "length", "label": "Length", "type": "expression", "kind": "length"},
			{"key": "width", "label": "Width", "type": "expression", "kind": "length"},
			{"key": "length_faces", "label": "Length Faces", "type": "expression", "kind": "number", "range": [1, 64, true]},
			{"key": "width_faces", "label": "Width Faces", "type": "expression", "kind": "number", "range": [1, 64, true]},
			{"key": "symmetry", "label": "Symmetry", "type": "enum", "options": [["none", "None"], ["mirror", "Mirror"]]},
			{"key": "sym_x", "label": "Length Mirror", "type": "bool", "visible_if": {"symmetry": ["mirror"]}},
			{"key": "sym_y", "label": "Width Mirror", "type": "bool", "visible_if": {"symmetry": ["mirror"]}},
			_BODY_FIELD,
		],
		"defaults": {"placement": "center", "length": "@S", "width": "@S", "length_faces": "2", "width_faces": "2", "symmetry": "none",
			"sym_x": true, "sym_y": false, "body": "new"},
	},
	"cylinder": {
		"title": "Cylinder", "plane": true, "interact": true, "handles": true, "preview": true, "clicks": 3,
		"picks": [],
		"fields": [
			{"key": "diameter", "label": "Diameter", "type": "expression", "kind": "length"},
			{"key": "height", "label": "Height", "type": "expression", "kind": "length"},
			{"key": "around_faces", "label": "Diameter Faces", "type": "expression", "kind": "number", "range": [3, 64, true]},
			{"key": "height_faces", "label": "Height Faces", "type": "expression", "kind": "number", "range": [1, 64, true]},
			{"key": "direction", "label": "Direction", "type": "enum", "options": [["one_side", "One Side"], ["symmetric", "Symmetric"]]},
			{"key": "symmetry", "label": "Symmetry", "type": "enum", "options": [["none", "None"], ["mirror", "Mirror"], ["circular", "Circular"]]},
			{"key": "sym_x", "label": "X Mirror", "type": "bool", "visible_if": {"symmetry": ["mirror"]}},
			{"key": "sym_y", "label": "Y Mirror", "type": "bool", "visible_if": {"symmetry": ["mirror"]}},
			{"key": "sym_z", "label": "Height Mirror", "type": "bool", "visible_if": {"symmetry": ["mirror"]}},
			{"key": "sym_count", "label": "Symmetric Faces", "type": "expression", "kind": "number", "visible_if": {"symmetry": ["circular"]}, "range": [2, 64, true]},
			_BODY_FIELD,
		],
		"defaults": {"diameter": "@S", "height": "@S", "around_faces": "8", "height_faces": "2", "direction": "one_side", "symmetry": "none",
			"sym_x": true, "sym_y": false, "sym_z": false, "sym_count": "8", "body": "new"},
	},
	"sphere": {
		"title": "Sphere", "plane": true, "interact": true, "handles": true, "preview": true, "clicks": 2,
		"picks": [],
		"fields": [
			{"key": "diameter", "label": "Diameter", "type": "expression", "kind": "length"},
			{"key": "around_faces", "label": "Longitude Faces", "type": "expression", "kind": "number", "range": [3, 64, true]},
			{"key": "rows", "label": "Latitude Faces", "type": "expression", "kind": "number", "range": [2, 64, true]},
			{"key": "symmetry", "label": "Symmetry", "type": "enum", "options": [["none", "None"], ["mirror", "Mirror"], ["circular", "Circular"]]},
			{"key": "sym_x", "label": "X Mirror", "type": "bool", "visible_if": {"symmetry": ["mirror"]}},
			{"key": "sym_y", "label": "Y Mirror", "type": "bool", "visible_if": {"symmetry": ["mirror"]}},
			{"key": "sym_z", "label": "Z Mirror", "type": "bool", "visible_if": {"symmetry": ["mirror"]}},
			{"key": "sym_count", "label": "Symmetric Faces", "type": "expression", "kind": "number", "visible_if": {"symmetry": ["circular"]}, "range": [2, 64, true]},
			_BODY_FIELD,
		],
		"defaults": {"diameter": "@S", "around_faces": "8", "rows": "4", "symmetry": "none", "sym_x": true, "sym_y": false, "sym_z": false,
			"sym_count": "8", "body": "new"},
	},
	"torus": {
		"title": "Torus", "plane": true, "interact": true, "handles": true, "preview": true, "clicks": 2,
		"picks": [],
		"fields": [
			{"key": "diameter", "label": "Diameter 1", "type": "expression", "kind": "length"},
			{"key": "tube_diameter", "label": "Diameter 2", "type": "expression", "kind": "length"},
			{"key": "around_faces", "label": "Diameter 1 Faces", "type": "expression", "kind": "number", "range": [3, 64, true]},
			{"key": "tube_faces", "label": "Diameter 2 Faces", "type": "expression", "kind": "number", "range": [3, 64, true]},
			{"key": "symmetry", "label": "Symmetry", "type": "enum", "options": [["none", "None"], ["mirror", "Mirror"], ["circular", "Circular"]]},
			{"key": "sym_x", "label": "X Mirror", "type": "bool", "visible_if": {"symmetry": ["mirror"]}},
			{"key": "sym_y", "label": "Y Mirror", "type": "bool", "visible_if": {"symmetry": ["mirror"]}},
			{"key": "sym_z", "label": "Z Mirror", "type": "bool", "visible_if": {"symmetry": ["mirror"]}},
			{"key": "sym_count", "label": "Symmetric Faces", "type": "expression", "kind": "number", "visible_if": {"symmetry": ["circular"]}, "range": [2, 64, true]},
			_BODY_FIELD,
		],
		"defaults": {"diameter": "@S", "tube_diameter": "@S4", "around_faces": "8", "tube_faces": "6", "symmetry": "none", "sym_x": true,
			"sym_y": false, "sym_z": false, "sym_count": "8", "body": "new"},
	},
	"quadball": {
		"title": "Quadball", "plane": true, "interact": true, "handles": true, "preview": true, "clicks": 2,
		"picks": [],
		"fields": [
			{"key": "diameter", "label": "Diameter", "type": "expression", "kind": "length"},
			{"key": "span_faces", "label": "Span Faces", "type": "expression", "kind": "number", "range": [1, 64, true]},
			{"key": "symmetry", "label": "Symmetry", "type": "enum", "options": [["none", "None"], ["mirror", "Mirror"]]},
			{"key": "sym_x", "label": "X Mirror", "type": "bool", "visible_if": {"symmetry": ["mirror"]}},
			{"key": "sym_y", "label": "Y Mirror", "type": "bool", "visible_if": {"symmetry": ["mirror"]}},
			{"key": "sym_z", "label": "Z Mirror", "type": "bool", "visible_if": {"symmetry": ["mirror"]}},
			_BODY_FIELD,
		],
		"defaults": {"diameter": "@S", "span_faces": "2", "symmetry": "none", "sym_x": true, "sym_y": false, "sym_z": false, "body": "new"},
	},
	"edit_form": {
		"title": "Edit Form", "uses_selection": true, "preview": false,
		"picks": [{"key": "elements", "label": "Cage", "kinds": ["vertex", "edge", "face", "body"], "count": -1, "required": true}],
		"fields": [
			{"key": "transform_mode", "label": "Transform", "type": "enum", "options": [["multi", "Multi"], ["translate", "Translate"], ["rotate", "Rotate"], ["scale", "Scale"]]},
			{"key": "space", "label": "Coordinates", "type": "enum", "options": [["world", "World"], ["view", "View"], ["selection", "Selection"], ["local", "Local Per Entity"]]},
			{"key": "soft", "label": "Soft Modification", "type": "bool"},
			{"key": "extent", "label": "Extent", "type": "enum", "options": [["distance", "Distance"], ["faces", "Face Count"], ["rectangular", "Rectangular Face Count"]], "visible_if": {"soft": [true]}},
			{"key": "distance", "label": "Distance", "type": "expression", "kind": "length", "visible_if": {"soft": [true], "extent": ["distance"]}},
			{"key": "faces", "label": "Faces", "type": "expression", "kind": "number", "visible_if": {"soft": [true], "extent": ["faces"]}, "range": [0, 64, true]},
			{"key": "u_faces", "label": "U Faces", "type": "expression", "kind": "number", "visible_if": {"soft": [true], "extent": ["rectangular"]}, "range": [0.1, 64]},
			{"key": "v_faces", "label": "V Faces", "type": "expression", "kind": "number", "visible_if": {"soft": [true], "extent": ["rectangular"]}, "range": [0.1, 64]},
			{"key": "transition", "label": "Transition", "type": "enum", "options": [["smooth", "Smooth"], ["linear", "Linear"], ["bulge", "Bulge"]], "visible_if": {"soft": [true]}},
			{"key": "weight", "label": "Weight", "type": "expression", "kind": "number", "visible_if": {"soft": [true]}, "range": [0, 1]},
			{"key": "x_distance", "label": "X Distance", "type": "expression", "kind": "length"},
			{"key": "y_distance", "label": "Y Distance", "type": "expression", "kind": "length"},
			{"key": "z_distance", "label": "Z Distance", "type": "expression", "kind": "length"},
			{"key": "x_angle", "label": "X Angle", "type": "expression", "kind": "angle"},
			{"key": "y_angle", "label": "Y Angle", "type": "expression", "kind": "angle"},
			{"key": "z_angle", "label": "Z Angle", "type": "expression", "kind": "angle"},
			{"key": "x_scale", "label": "X Scale", "type": "expression", "kind": "number", "range": SCALE_RANGE},
			{"key": "y_scale", "label": "Y Scale", "type": "expression", "kind": "number", "range": SCALE_RANGE},
			{"key": "z_scale", "label": "Z Scale", "type": "expression", "kind": "number", "range": SCALE_RANGE},
			{"key": "xy_scale", "label": "XY Plane Scale", "type": "expression", "kind": "number", "range": SCALE_RANGE},
			{"key": "yz_scale", "label": "YZ Plane Scale", "type": "expression", "kind": "number", "range": SCALE_RANGE},
			{"key": "zx_scale", "label": "ZX Plane Scale", "type": "expression", "kind": "number", "range": SCALE_RANGE},
			{"key": "uniform_scale", "label": "Uniform Scale", "type": "expression", "kind": "number", "range": SCALE_RANGE},
			{"key": "sel_loop", "label": "Loop (Alt+P)", "type": "button", "tooltip": "Select the loops through the selected edges or vertices"},
			{"key": "sel_ring", "label": "Ring (Alt+L)", "type": "button", "tooltip": "Select the rings across the selected edges"},
			{"key": "sel_grow", "label": "Grow (Shift+Up)", "type": "button", "tooltip": "Add the neighbours of the selection"},
			{"key": "sel_shrink", "label": "Shrink (Shift+Down)", "type": "button", "tooltip": "Drop the selection's outer border"},
		],
		"defaults": {"transform_mode": "multi", "space": "world", "soft": false, "extent": "distance", "distance": "@EDGE2", "faces": "2",
			"u_faces": "2", "v_faces": "2", "transition": "smooth", "weight": "1", "x_distance": "0", "y_distance": "0", "z_distance": "0",
			"x_angle": "0 deg", "y_angle": "0 deg", "z_angle": "0 deg", "x_scale": "1", "y_scale": "1", "z_scale": "1", "xy_scale": "1",
			"yz_scale": "1", "zx_scale": "1", "uniform_scale": "1"},
	},
	"display_mode": {
		"title": "Display Mode", "uses_selection": true, "preview": false,
		"picks": [{"key": "bodies", "label": "Bodies", "kinds": ["body"], "count": -1, "required": false}],
		"fields": [
			{"key": "mode", "label": "Mode", "type": "enum", "options": [["box", "Box"], ["frame", "Control Frame"], ["smooth", "Smooth"]]},
			{"key": "note", "type": "info", "text": "No bodies picked: every body of the form changes."},
		],
		"defaults": {"mode": "smooth"},
	},
	"crease": {
		"title": "Crease", "uses_selection": true, "preview": true,
		"picks": [{"key": "elements", "label": "Edges / Vertices", "kinds": ["edge", "vertex"], "count": -1, "required": true}],
		"fields": [{"key": "note", "type": "info", "text": "Short crease fade near star points and poles"}],
		"defaults": {},
	},
	"uncrease": {
		"title": "UnCrease", "uses_selection": true, "preview": true,
		"picks": [{"key": "elements", "label": "Edges / Vertices", "kinds": ["edge", "vertex"], "count": -1, "required": true}],
		"fields": [{"key": "note", "type": "info", "text": "Short crease fade near star points and poles"}],
		"defaults": {},
	},
	"freeze": {
		"title": "Freeze", "uses_selection": true, "preview": true,
		"picks": [{"key": "elements", "label": "Cage", "kinds": ["face", "edge", "vertex"], "count": -1, "required": true}],
		"fields": [{"key": "note", "type": "info", "text": "Frozen cage stays put; the ring of vertices around it is locked too."}],
		"defaults": {},
	},
	"unfreeze": {
		"title": "Unfreeze", "uses_selection": true, "preview": true,
		"picks": [{"key": "elements", "label": "Cage", "kinds": ["face", "edge", "vertex"], "count": -1, "required": false}],
		"fields": [
			{"key": "all", "label": "All", "type": "button", "tooltip": "Unfreeze every frozen element of the form's bodies"},
			{"key": "note", "type": "info", "text": "Pick frozen elements, or press All."},
		],
		"defaults": {},
	},
	"clear_symmetry": {
		"title": "Clear Symmetry", "uses_selection": true, "preview": true,
		"picks": [{"key": "bodies", "label": "Bodies", "kinds": ["body"], "count": -1, "required": false}],
		"fields": [
			{"key": "separate", "label": "Separate Bodies", "type": "bool"},
			{"key": "note", "type": "info", "text": "No bodies picked: every body of the form."},
		],
		"defaults": {"separate": true},
	},
}


## The spec of a tool id from whichever registry script declares it ({} when none does).
static func spec(id: String) -> Dictionary:
	if TOOLS.has(id):
		return TOOLS[id]
	if (CREATE.TOOLS as Dictionary).has(id):
		return CREATE.TOOLS[id]
	if (MODIFY.TOOLS as Dictionary).has(id):
		return MODIFY.TOOLS[id]
	return {}


static func has_tool(id: String) -> bool:
	return owner(id) != null


## The registry script that declares id (null when none does).
static func owner(id: String) -> Script:
	if id == "":
		return null
	if TOOLS.has(id):
		return load("res://addons/holo_forge/ui/form_tools.gd")
	if (CREATE.TOOLS as Dictionary).has(id):
		return CREATE
	if (MODIFY.TOOLS as Dictionary).has(id):
		return MODIFY
	return null


## Runs a tool in its declaring script (see the header for the result).
static func run(id: String, ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var script := owner(id)
	if script == null or not script.has_method("run_" + id):
		return failure("%s isn't wired yet." % str(spec(id).get("title", id)))
	# Panel text the tool writes into ctx.panel on the way (info field key -> text) comes back in
	# the result's info.panel, beside any the result carries itself.
	# Typed numbers out of a field's range (or fractional counts) are refused with a sentence; the
	# tools clamped and rounded them silently before (Quantity 100 made 64 copies).
	var doc: Variant = ctx.get("doc")
	var bad := range_error(id, values, str(doc.get("units")) if doc is Object and doc.get("units") != null else "mm")
	if bad != "":
		return failure(bad)
	var outer: Variant = ctx.get("panel")
	var panel := {}
	ctx["panel"] = panel
	var r: Variant = script.call("run_" + id, ctx, picks, values)
	if outer != null:
		ctx["panel"] = outer
	else:
		ctx.erase("panel")
	if not r is Dictionary:
		return failure("%s gave no result." % str(spec(id).get("title", id)))
	var out := normalized(r)
	if not panel.is_empty():
		if not out.info is Dictionary:
			out.info = {}
		var shown: Variant = (out.info as Dictionary).get("panel", {})
		if not shown is Dictionary:
			shown = {}
		for key in panel:
			if not (shown as Dictionary).has(key):
				shown[key] = panel[key]
		out.info["panel"] = shown
	return out


## The first visible field of a tool whose value is outside its "range" [min, max, whole] (or
## isn't a whole number when whole is true), as a sentence; "" when every value fits. A length
## field's range is in meters and is written in units (the document's length unit); an angle's is
## in radians, written in degrees.
static func range_error(id: String, values: Dictionary, units := "mm") -> String:
	for field in spec(id).get("fields", []):
		var range: Array = (field as Dictionary).get("range", [])
		if range.size() < 2 or not values.has(field.key):
			continue
		var shown := true
		var condition: Dictionary = field.get("visible_if", {})
		for key in condition:
			if not (condition[key] as Array).has(values.get(key)):
				shown = false
		if not shown:
			continue
		var v: Variant = values[field.key]
		if not (v is float or v is int):
			continue
		var x := float(v)
		var lo := float(range[0])
		var hi := float(range[1])
		var whole := range.size() > 2 and bool(range[2])
		var label := str(field.get("label", field.key))
		if whole and (absf(x - roundf(x)) > 1e-9 or x < lo or x > hi):
			return "%s must be a whole number from %d to %d." % [label, int(lo), int(hi)]
		if not is_finite(x) or x < lo - 1e-12 or x > hi + 1e-12:
			# Written like the field shows it: plain numbers without a trailing ".0", lengths in the
			# document's unit, angles in degrees.
			var kind := str(field.get("kind", UNITS.KIND_NUMBER))
			return "%s must be from %s to %s." % [label, UNITS.format_value(lo, kind, units, 8), UNITS.format_value(hi, kind, units, 8)]
	return ""


## Calls an optional hook of the declaring script ("handle_mouse", "draw", "handles"); fallback
## when it has none.
static func hook(kind: String, id: String, args: Array, fallback: Variant = null) -> Variant:
	var script := owner(id)
	var name := "%s_%s" % [kind, id]
	if script == null or not script.has_method(name):
		return fallback
	return script.callv(name, args)


## Starting panel values: the spec's defaults with the size placeholders filled in (size_m: the
## workspace's default size in meters, edge_m: twice the mean edge length at the selection).
static func defaults(id: String, units: String, size_m: float, edge_m := 0.0) -> Dictionary:
	var values: Dictionary = (spec(id).get("defaults", {}) as Dictionary).duplicate(true)
	for key in values:
		if not values[key] is String:
			continue
		match str(values[key]):
			"@S":
				values[key] = _length_text(size_m, units)
			"@S4":
				values[key] = _length_text(size_m * 0.25, units)
			"@S5":
				values[key] = _length_text(size_m * 0.2, units)
			"@EDGE2":
				values[key] = _length_text(edge_m if edge_m > 0.0 else size_m * 0.25, units)
	return values


static func _length_text(meters: float, units: String) -> String:
	return UNITS.format_value(meters, UNITS.KIND_LENGTH, units)


static func failure(message: String) -> Dictionary:
	return {"ok": false, "error": message, "warnings": PackedStringArray(), "cages": {}, "new_bodies": [], "removed_bodies": [],
		"breps": {}, "display": {}, "selection": [], "info": {}}


## A result with every key present.
static func normalized(r: Dictionary) -> Dictionary:
	var out := failure("")
	out.merge(r, true)
	out.ok = bool(r.get("ok", false))
	return out


## Cage selection items grouped by body: {body id: {"vertices", "edges" (pairs), "faces", "body"}}.
static func by_body(items: Array) -> Dictionary:
	var out := {}
	for item in items:
		if not item is Dictionary or not (item as Dictionary).has("body"):
			continue
		var body := str(item.body)
		if not out.has(body):
			out[body] = {"vertices": PackedInt32Array(), "edges": PackedInt32Array(), "faces": PackedInt32Array(), "body": false}
		var sel: Dictionary = out[body]
		match str(item.get("kind", "")):
			"vertex":
				var v: PackedInt32Array = sel.vertices
				v.append(int(item.index))
				sel.vertices = v
			"edge":
				var pair: Vector2i = item.get("pair", Vector2i(-1, -1))
				var e: PackedInt32Array = sel.edges
				e.append(mini(pair.x, pair.y))
				e.append(maxi(pair.x, pair.y))
				sel.edges = e
			"face":
				var f: PackedInt32Array = sel.faces
				f.append(int(item.index))
				sel.faces = f
			"body":
				sel.body = true
	return out


## The bodies a pick list names (any element of a body names it); every cage body when it names none.
static func picked_bodies(items: Array, cages: Dictionary) -> Array:
	var bodies := []
	for item in items:
		if item is Dictionary and cages.has(str(item.get("body", ""))) and not bodies.has(str(item.body)):
			bodies.append(str(item.body))
	return bodies if not bodies.is_empty() else cages.keys()


# --- Primitives -------------------------------------------------------------------------------

static func run_box(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var size := Vector3(float(values.get("length", 0.0)), float(values.get("width", 0.0)), float(values.get("height", 0.0)))
	if size.x <= 0.0 or size.y <= 0.0 or size.z <= 0.0:
		return failure("The box sizes must be greater than zero.")
	var bad := _counts_error(values, [["length_faces", "Length Faces", 1], ["width_faces", "Width Faces", 1], ["height_faces", "Height Faces", 1]])
	if bad != "":
		return failure(bad)
	var counts := Vector3i(_count(values, "length_faces", 2), _count(values, "width_faces", 2), _count(values, "height_faces", 2))
	var frame := placement_frame(picks)
	var center := frame
	if str(values.get("direction", "one_side")) == "one_side":
		center.origin += frame.basis.z * size.z * 0.5
	var cage := place(PRIMITIVES.box(size, counts), center)
	if str(values.get("symmetry", "none")) == "mirror":
		cage = PRIMITIVES.primitive_symmetry(cage, "mirror", center, _mirror_axes(values), 0)
		var unfit := _symmetry_unfit(cage, "Box")
		if unfit != "":
			return failure(unfit)
	return _add_body(ctx, values, cage)


static func run_plane(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var size := Vector2(float(values.get("length", 0.0)), float(values.get("width", 0.0)))
	if size.x <= 0.0 or size.y <= 0.0:
		return failure("The plane sizes must be greater than zero.")
	var bad := _counts_error(values, [["length_faces", "Length Faces", 1], ["width_faces", "Width Faces", 1]])
	if bad != "":
		return failure(bad)
	var frame := placement_frame(picks)
	var cage := place(PRIMITIVES.plane(size, Vector2i(_count(values, "length_faces", 2), _count(values, "width_faces", 2))), frame)
	if str(values.get("symmetry", "none")) == "mirror":
		var axes := _mirror_axes(values)
		axes.z = 0
		cage = PRIMITIVES.primitive_symmetry(cage, "mirror", frame, axes, 0)
		var unfit := _symmetry_unfit(cage, "Plane")
		if unfit != "":
			return failure(unfit)
	return _add_body(ctx, values, cage)


static func run_cylinder(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var d := float(values.get("diameter", 0.0))
	var h := float(values.get("height", 0.0))
	if d <= 0.0 or h <= 0.0:
		return failure("The cylinder sizes must be greater than zero.")
	var bad := _counts_error(values, [["around_faces", "Diameter Faces", 3], ["height_faces", "Height Faces", 1], ["sym_count", "Symmetric Faces", 2]])
	if bad != "":
		return failure(bad)
	var around := maxi(3, _count(values, "around_faces", 8))
	var rows := _count(values, "height_faces", 2)
	var circular := _circular_count(values, around)
	if circular < 0:
		return failure("Symmetric faces must divide %d" % around)
	var frame := placement_frame(picks)
	var base := frame
	if str(values.get("direction", "one_side")) == "symmetric":
		base.origin -= frame.basis.z * h * 0.5
	var cage := place(PRIMITIVES.cylinder(d, h, around, rows, "pole"), base)
	cage = _primitive_symmetry(cage, values, base, Transform3D(base.basis, base.origin + base.basis.z * h * 0.5), circular)
	var unfit := _symmetry_unfit(cage, "Cylinder", "an even Diameter Faces count")
	if unfit != "":
		return failure(unfit)
	return _add_body(ctx, values, cage)


static func run_sphere(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var d := float(values.get("diameter", 0.0))
	if d <= 0.0:
		return failure("The sphere diameter must be greater than zero.")
	var bad := _counts_error(values, [["around_faces", "Longitude Faces", 3], ["rows", "Latitude Faces", 2], ["sym_count", "Symmetric Faces", 2]])
	if bad != "":
		return failure(bad)
	var around := maxi(3, _count(values, "around_faces", 8))
	var circular := _circular_count(values, around)
	if circular < 0:
		return failure("Symmetric faces must divide %d" % around)
	var frame := placement_frame(picks)
	var cage := place(PRIMITIVES.sphere(d, around, maxi(2, _count(values, "rows", 4))), frame)
	cage = _primitive_symmetry(cage, values, frame, frame, circular)
	var unfit := _symmetry_unfit(cage, "Sphere", "an even Longitude Faces count")
	if unfit != "":
		return failure(unfit)
	return _add_body(ctx, values, cage)


static func run_torus(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var d1 := float(values.get("diameter", 0.0))
	var d2 := float(values.get("tube_diameter", 0.0))
	if d1 <= 0.0 or d2 <= 0.0:
		return failure("The torus diameters must be greater than zero.")
	if d2 >= d1:
		return failure("Diameter 2 must be smaller than Diameter 1.")
	var bad := _counts_error(values, [["around_faces", "Diameter 1 Faces", 3], ["tube_faces", "Diameter 2 Faces", 3], ["sym_count", "Symmetric Faces", 2]])
	if bad != "":
		return failure(bad)
	var around := maxi(3, _count(values, "around_faces", 8))
	var circular := _circular_count(values, around)
	if circular < 0:
		return failure("Symmetric faces must divide %d" % around)
	var frame := placement_frame(picks)
	var cage := place(PRIMITIVES.torus(d1, d2, around, maxi(3, _count(values, "tube_faces", 6))), frame)
	cage = _primitive_symmetry(cage, values, frame, frame, circular)
	var unfit := _symmetry_unfit(cage, "Torus", "even face counts")
	if unfit != "":
		return failure(unfit)
	return _add_body(ctx, values, cage)


static func run_quadball(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var d := float(values.get("diameter", 0.0))
	if d <= 0.0:
		return failure("The quadball diameter must be greater than zero.")
	var bad := _counts_error(values, [["span_faces", "Span Faces", 1]])
	if bad != "":
		return failure(bad)
	var frame := placement_frame(picks)
	var cage := place(PRIMITIVES.quadball(d, _count(values, "span_faces", 2)), frame)
	if str(values.get("symmetry", "none")) == "mirror":
		cage = PRIMITIVES.primitive_symmetry(cage, "mirror", frame, _mirror_axes(values), 0)
		var unfit := _symmetry_unfit(cage, "Quadball")
		if unfit != "":
			return failure(unfit)
	return _add_body(ctx, values, cage)


## The placement frame from picks.placement (the picked plane and clicked centre; the XY origin
## plane at the origin when nothing was placed): X, Y in the plane, Z its normal.
static func placement_frame(picks: Dictionary) -> Transform3D:
	var list: Array = picks.get("placement", [])
	if list.is_empty() or not list[0] is Dictionary:
		return Transform3D(Basis(Vector3.RIGHT, Vector3.UP, Vector3.BACK), Vector3.ZERO)
	var p: Dictionary = list[0]
	var x: Vector3 = (p.get("x", Vector3.RIGHT) as Vector3).normalized()
	var y: Vector3 = (p.get("y", Vector3.UP) as Vector3).normalized()
	var z: Vector3 = p.get("normal", x.cross(y))
	return Transform3D(Basis(x, y, z.normalized()), p.get("origin", Vector3.ZERO))


## A local cage moved into a frame (doubles).
static func place(cage: Dictionary, frame: Transform3D) -> Dictionary:
	var all := PackedInt32Array()
	for v in CAGE.vertex_count(cage):
		all.append(v)
	return FORM_OPS.transform_vertices(cage, all, PackedFloat32Array(), FORM_OPS.xf_from(frame.basis, frame.origin)).cage


static func _primitive_symmetry(cage: Dictionary, values: Dictionary, axis_frame: Transform3D, mirror_frame: Transform3D, circular: int) -> Dictionary:
	match str(values.get("symmetry", "none")):
		"mirror":
			return PRIMITIVES.primitive_symmetry(cage, "mirror", mirror_frame, _mirror_axes(values), 0)
		"circular":
			return PRIMITIVES.primitive_symmetry(cage, "circular", axis_frame, Vector3i.ZERO, circular)
	return cage


static func _mirror_axes(values: Dictionary) -> Vector3i:
	return Vector3i(1 if bool(values.get("sym_x", false)) else 0, 1 if bool(values.get("sym_y", false)) else 0, 1 if bool(values.get("sym_z", false)) else 0)


## The circular symmetry count (0 when the tool's symmetry isn't circular, -1 when it doesn't
## divide around).
static func _circular_count(values: Dictionary, around: int) -> int:
	if str(values.get("symmetry", "none")) != "circular":
		return 0
	var n := _count(values, "sym_count", around)
	if n < 2 or around % n != 0:
		return -1
	return n


## Face counts as typed must be whole numbers in range (they were rounded and clamped silently
## before): the first bad one as a sentence, "" when all are fine. specs: [key, label, minimum].
static func _counts_error(values: Dictionary, specs: Array) -> String:
	for spec in specs:
		var key: String = spec[0]
		if not values.has(key):
			continue
		if key == "sym_count" and str(values.get("symmetry", "none")) != "circular":
			continue
		var v: Variant = values[key]
		if not (v is float or v is int):
			continue
		var x := float(v)
		var lo: int = spec[2]
		if absf(x - roundf(x)) > 1e-9 or x < lo or x > 64:
			return "%s must be a whole number from %d to 64." % [spec[1], lo]
	return ""


## A sentence when the cage's symmetry leaves vertices without partners (a mirror through an odd
## count of faces, say), "" when every vertex has one.
static func _symmetry_unfit(cage: Dictionary, title: String, hint := "even face counts") -> String:
	var broken := _broken_partners(cage)
	if broken == 0:
		return ""
	return "That symmetry does not fit this %s: %d vertices would have no partner; use %s, or another symmetry." % [title.to_lower(), broken, hint]


## Vertices (not isolated) whose symmetry map entry is -1 (open circular orbit ends excluded).
static func _broken_partners(cage: Dictionary) -> int:
	var nV := CAGE.vertex_count(cage)
	var iso := PackedByteArray()
	iso.resize(nV)
	for v in (cage.get("sym_isolated", PackedInt32Array()) as PackedInt32Array):
		if v >= 0 and v < nV:
			iso[v] = 1
	var broken := 0
	for entry in cage.get("symmetry", []):
		var m: PackedInt32Array = entry.get("map", PackedInt32Array())
		if m.size() != nV:
			broken += nV
			continue
		var open := str(entry.get("type", "")) == "circular" and bool(entry.get("open", false))
		var has_pred := PackedByteArray()
		if open:
			has_pred.resize(nV)
			for v in nV:
				if m[v] >= 0:
					has_pred[m[v]] = 1
		for v in nV:
			if m[v] < 0 and not iso[v] and (not open or not has_pred[v]):
				broken += 1
	return broken


static func _count(values: Dictionary, key: String, fallback: int) -> int:
	var v: Variant = values.get(key, fallback)
	if not (v is float or v is int):
		return fallback
	return clampi(roundi(float(v)), 1, 64)


## A new body, or the cage appended to the picked body ("body" field) as a separate component.
static func _add_body(ctx: Dictionary, values: Dictionary, cage: Dictionary) -> Dictionary:
	var target := str(values.get("body", "new"))
	var cages: Dictionary = ctx.get("cages", {})
	if target != "new" and cages.has(target):
		var merged: Dictionary = CAGE.append(cages[target], cage).cage
		var warnings := PackedStringArray()
		if not (merged.get("symmetry", []) as Array).is_empty():
			# The body's symmetry takes the new piece in when it fits (its partners are found);
			# otherwise say how many of its vertices have none.
			merged = FORM_OPS.rebuild_symmetry(merged, 0.0).cage
			var broken := _broken_partners(merged)
			if broken > 0:
				warnings.append("The new piece does not fit the body's symmetry: %d of its vertices have no partner." % broken)
		return {"ok": true, "cages": {target: merged}, "warnings": warnings}
	return {"ok": true, "new_bodies": [cage]}


## The editor clicks of a primitive: the centre (or first corner) on the plane, then the base size,
## then (box, cylinder) the height along the normal. Values stay editable until OK.
static func handle_mouse_box(editor: Object, event: InputEvent) -> bool:
	return placement_mouse(editor, event, "box")


static func handle_mouse_plane(editor: Object, event: InputEvent) -> bool:
	return placement_mouse(editor, event, "plane")


static func handle_mouse_cylinder(editor: Object, event: InputEvent) -> bool:
	return placement_mouse(editor, event, "cylinder")


static func handle_mouse_sphere(editor: Object, event: InputEvent) -> bool:
	return placement_mouse(editor, event, "sphere")


static func handle_mouse_torus(editor: Object, event: InputEvent) -> bool:
	return placement_mouse(editor, event, "torus")


static func handle_mouse_quadball(editor: Object, event: InputEvent) -> bool:
	return placement_mouse(editor, event, "quadball")


static func placement_mouse(editor: Object, event: InputEvent, id: String) -> bool:
	var button := event as InputEventMouseButton
	var motion := event as InputEventMouseMotion
	if button != null and button.button_index != MOUSE_BUTTON_LEFT:
		return false
	if button == null and motion == null:
		return false
	var state: Dictionary = editor.tool_state
	var clicks: Array = state.get("clicks", [])
	var needed := int(TOOLS[id].get("clicks", 2))
	if clicks.size() >= needed:
		# Placed: the clicks are done (values stay editable); the view's picks pass through.
		return false
	if button != null and button.pressed:
		return true
	var mouse: Vector2 = (event as InputEventMouse).position
	var plane: Dictionary = state.get("plane", {"origin": Vector3.ZERO, "x": Vector3.RIGHT, "y": Vector3.UP})
	var x: Vector3 = plane.x
	var y: Vector3 = plane.y
	var n: Vector3 = x.cross(y).normalized()
	var viewport: Object = editor.viewport
	var on_plane: Variant = viewport.plane_hit(mouse, plane.origin, n)
	var values: Dictionary = {}
	var units: String = editor.units()
	if clicks.size() == 0:
		if button == null or on_plane == null:
			return true
		clicks.append(on_plane)
		state["clicks"] = clicks
		state["center"] = on_plane
		editor.set_placement(on_plane, x, y, n)
		return true
	if clicks.size() == 1:
		if on_plane == null:
			return true
		var first: Vector3 = clicks[0]
		var d: Vector3 = (on_plane as Vector3) - first
		var dx := d.dot(x)
		var dy := d.dot(y)
		match id:
			"box", "plane":
				if str(editor.tool_values.get("placement", "center")) == "two_point":
					values["length"] = _length_text(maxf(absf(dx), 1e-6), units)
					values["width"] = _length_text(maxf(absf(dy), 1e-6), units)
					state["center"] = first + x * dx * 0.5 + y * dy * 0.5
				else:
					values["length"] = _length_text(maxf(2.0 * absf(dx), 1e-6), units)
					values["width"] = _length_text(maxf(2.0 * absf(dy), 1e-6), units)
			"cylinder", "sphere", "torus", "quadball":
				values["diameter"] = _length_text(maxf(2.0 * Vector2(dx, dy).length(), 1e-6), units)
		editor.set_placement(state.center, x, y, n)
		editor.set_tool_values(values)
		if button != null:
			clicks.append(on_plane)
			state["clicks"] = clicks
		return true
	# The height along the normal through the base centre.
	var center: Vector3 = state.get("center", clicks[0])
	var ray: Array = viewport.ray_from(mouse)
	var t := MANIPULATOR.closest_on_line(center, n, ray[0], ray[1])
	if is_nan(t):
		return true
	var symmetric := str(editor.tool_values.get("direction", "one_side")) == "symmetric"
	values["height"] = _length_text(maxf(absf(t) * (2.0 if symmetric else 1.0), 1e-6), units)
	# Pulled below the plane: the shape grows the other way (the frame turns over about X).
	var flip := t < 0.0 and not symmetric
	editor.set_placement(center, x, -y if flip else y, -n if flip else n)
	editor.set_tool_values(values)
	if button != null:
		clicks.append(Vector3(center + n * t))
		state["clicks"] = clicks
	return true


## Distance arrows and face-count handles on a primitive being placed.
static func handles_box(editor: Object, values: Dictionary) -> Array:
	return _primitive_handles(editor, values, "box")


static func handles_plane(editor: Object, values: Dictionary) -> Array:
	return _primitive_handles(editor, values, "plane")


static func handles_cylinder(editor: Object, values: Dictionary) -> Array:
	return _primitive_handles(editor, values, "cylinder")


static func handles_sphere(editor: Object, values: Dictionary) -> Array:
	return _primitive_handles(editor, values, "sphere")


static func handles_torus(editor: Object, values: Dictionary) -> Array:
	return _primitive_handles(editor, values, "torus")


static func handles_quadball(editor: Object, values: Dictionary) -> Array:
	return _primitive_handles(editor, values, "quadball")


static func _primitive_handles(editor: Object, values: Dictionary, id: String) -> Array:
	var f := placement_frame(editor.tool_picks)
	var x := f.basis.x
	var y := f.basis.y
	var z := f.basis.z
	var o := f.origin
	var ev: Dictionary = editor.evaluated_values()
	var out := []
	match id:
		"box", "plane":
			var l := float(ev.get("length", 0.0))
			var w := float(ev.get("width", 0.0))
			var h := float(ev.get("height", 0.0)) if id == "box" else 0.0
			var mid := o + z * (h * 0.5 if str(values.get("direction", "one_side")) == "one_side" else 0.0)
			out.append({"type": "arrow", "key": "length", "origin": mid + x * l * 0.5, "direction": x, "factor": 2.0})
			out.append({"type": "arrow", "key": "width", "origin": mid + y * w * 0.5, "direction": y, "factor": 2.0})
			out.append({"type": "count", "key": "length_faces", "origin": mid - y * w * 0.5, "direction": x})
			out.append({"type": "count", "key": "width_faces", "origin": mid - x * l * 0.5, "direction": y})
			if id == "box":
				var top := o + z * (h if str(values.get("direction", "one_side")) == "one_side" else h * 0.5)
				out.append({"type": "arrow", "key": "height", "origin": top, "direction": z, "factor": 1.0 if str(values.get("direction", "one_side")) == "one_side" else 2.0})
				out.append({"type": "count", "key": "height_faces", "origin": mid + x * l * 0.5 + y * w * 0.5, "direction": z})
		"cylinder":
			var r := float(ev.get("diameter", 0.0)) * 0.5
			var h := float(ev.get("height", 0.0))
			var symmetric := str(values.get("direction", "one_side")) == "symmetric"
			out.append({"type": "arrow", "key": "diameter", "origin": o + x * r, "direction": x, "factor": 2.0})
			out.append({"type": "arrow", "key": "height", "origin": o + z * (h * 0.5 if symmetric else h), "direction": z, "factor": 2.0 if symmetric else 1.0})
			out.append({"type": "count", "key": "around_faces", "origin": o + y * r, "direction": y})
		"sphere", "quadball":
			var r := float(ev.get("diameter", 0.0)) * 0.5
			out.append({"type": "arrow", "key": "diameter", "origin": o + x * r, "direction": x, "factor": 2.0})
			out.append({"type": "count", "key": "around_faces" if id == "sphere" else "span_faces", "origin": o + y * r, "direction": y})
		"torus":
			var r := float(ev.get("diameter", 0.0)) * 0.5
			var t := float(ev.get("tube_diameter", 0.0)) * 0.5
			out.append({"type": "arrow", "key": "diameter", "origin": o + x * (r + t), "direction": x, "factor": 2.0})
			out.append({"type": "arrow", "key": "tube_diameter", "origin": o + y * r + z * t, "direction": z, "factor": 2.0})
			out.append({"type": "count", "key": "around_faces", "origin": o - x * r, "direction": -x})
	return out


# --- Display mode, creases, freeze, symmetry -------------------------------------------------------

## Display Mode: a view-only change of the picked bodies' (or every body's) display.
static func run_display_mode(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var mode := str(values.get("mode", "smooth"))
	if not mode in ["box", "frame", "smooth"]:
		return failure("Pick Box, Control Frame or Smooth.")
	var cages: Dictionary = ctx.get("cages", {})
	if cages.is_empty():
		return failure("The form has no bodies yet.")
	var display := {}
	for body in picked_bodies(picks.get("bodies", []), cages):
		display[body] = mode
	return {"ok": true, "display": display}


static func run_crease(ctx: Dictionary, picks: Dictionary, _values: Dictionary) -> Dictionary:
	return _per_body(ctx, picks.get("elements", []), func(cage: Dictionary, sel: Dictionary) -> Dictionary: return FORM_OPS.crease(cage, sel, {}),
		"Pick cage edges or vertices to crease.")


static func run_uncrease(ctx: Dictionary, picks: Dictionary, _values: Dictionary) -> Dictionary:
	return _per_body(ctx, picks.get("elements", []), func(cage: Dictionary, sel: Dictionary) -> Dictionary: return FORM_OPS.uncrease(cage, sel, {}),
		"Pick creased edges or sharp vertices.")


static func run_freeze(ctx: Dictionary, picks: Dictionary, _values: Dictionary) -> Dictionary:
	return _per_body(ctx, picks.get("elements", []), func(cage: Dictionary, sel: Dictionary) -> Dictionary: return FORM_OPS.freeze(cage, sel, {}),
		"Pick cage faces, edges or vertices to freeze.")


static func run_unfreeze(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var cages: Dictionary = ctx.get("cages", {})
	if bool(values.get("all", false)):
		var changed := {}
		for body in cages:
			var r := FORM_OPS.unfreeze(cages[body], {}, {"all": true})
			if r.ok:
				changed[body] = r.cage
		if changed.is_empty():
			return failure(FORM_OPS.NOTHING)
		return {"ok": true, "cages": changed}
	return _per_body(ctx, picks.get("elements", []), func(cage: Dictionary, sel: Dictionary) -> Dictionary: return FORM_OPS.unfreeze(cage, sel, {}),
		"Pick frozen faces, edges or vertices, or press All.")


## Clear Symmetry: no symmetry left on the picked bodies (every body when none is picked); with
## Separate Bodies, each further connected component becomes a body of its own.
static func run_clear_symmetry(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var cages: Dictionary = ctx.get("cages", {})
	if cages.is_empty():
		return failure("The form has no bodies yet.")
	var out := {"ok": true, "cages": {}, "new_bodies": []}
	var separate := bool(values.get("separate", true))
	var changed := false
	for body in picked_bodies(picks.get("bodies", []), cages):
		var cage: Dictionary = cages[body]
		var r := FORM_OPS.clear_symmetry(cage, {}, {"separate": separate})
		if not r.ok:
			return failure(r.error)
		var comps: Array = r.info.get("components", [r.cage])
		var had := not (cage.get("symmetry", []) as Array).is_empty() or not (cage.get("sym_isolated", PackedInt32Array()) as PackedInt32Array).is_empty()
		if not had and comps.size() <= 1:
			continue
		changed = true
		out.cages[body] = r.cage
		if separate and comps.size() > 1:
			for k in range(1, comps.size()):
				(out.new_bodies as Array).append(comps[k])
	if not changed:
		return failure(FORM_OPS.NOTHING)
	return out


## Runs op(cage, selection) on every body the items touch. A body where nothing changes ("Nothing
## to change") is left out; the tool fails with that message when no body changes.
static func _per_body(ctx: Dictionary, items: Array, op: Callable, empty_message: String) -> Dictionary:
	var cages: Dictionary = ctx.get("cages", {})
	var groups := by_body(items)
	if groups.is_empty():
		return failure(empty_message)
	var out := {"ok": true, "cages": {}, "warnings": PackedStringArray(), "info": {"changed": 0}}
	var nothing := false
	for body in groups:
		if not cages.has(body):
			continue
		var r: Dictionary = op.call(cages[body], groups[body])
		if not r.ok:
			if str(r.error) == FORM_OPS.NOTHING:
				nothing = true
				continue
			return failure(r.error)
		out.cages[body] = r.cage
		var warnings: PackedStringArray = out.warnings
		warnings.append_array(r.warnings)
		out.warnings = warnings
		out.info.changed = int(out.info.changed) + int((r.info as Dictionary).get("changed", 0))
	if (out.cages as Dictionary).is_empty():
		return failure(FORM_OPS.NOTHING if nothing else empty_message)
	return out
