@tool
extends RefCounted
## Form tools that create bodies from sketches and clicks (Stage 3, team M1): Extrude, Revolve,
## Sweep, Loft, Pipe and Face. A tool is enabled once its id is in TOOLS (see ui/form_tools.gd for
## the spec format and the run_<id> / handle_mouse_<id> / draw_<id> / handles_<id> functions the
## registry dispatches to). Never preload catalog.gd, forge_workspace.gd or form_editor.gd here,
## nor ui/form_tools.gd (it preloads this script).
##
## The sketch-based creates pick their curves through "selection" fields (the workspace's picker:
## profiles, sketch curves, model edges, axes, points), so the picks arrive in the values. Their
## cages come from core/form/form_create.gd; "Fit to Curves" then moves each cage so its limit
## surface passes exactly through the points built on the curves. Extra hooks this script uses:
## values_<id>(editor, values) -> changes (a face count that suits the picked profile) and
## button_<id>(editor, key) (Pipe's Add Section, Face's Pick Plane).

const CAGE := preload("res://addons/holo_forge/core/form/cage.gd")
const FORM_OPS := preload("res://addons/holo_forge/core/form/form_ops.gd")
const PRIMITIVES := preload("res://addons/holo_forge/core/form/primitives.gd")
const FORM_CREATE := preload("res://addons/holo_forge/core/form/form_create.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const UNITS := preload("res://addons/holo_forge/core/units.gd")

const _BODY_FIELD := {"key": "body", "label": "Body", "type": "enum", "options": "bodies"}
const _SPACING := [["uniform", "Uniform"], ["curvature", "Curvature"]]
const _SIDES := [["one_side", "One Side"], ["two_sides", "Two Sides"], ["symmetric", "Symmetric"]]
const _ENDS := [["free", "Free"], ["direction", "Direction"], ["tip", "Point Tip"]]
const _PIPE_ENDS := [["open", "Open"], ["square", "Square"], ["spike", "Spike"]]
## The picker kinds a curve slot takes (profiles, sketch curves, body edges).
const _CURVES := ["profile", "sketch_curve", "edge"]
## Screen distance (pixels) within which a Face click snaps to a cage vertex.
const SNAP_PX := 6.0
const MAX_SECTIONS := 8
## Loft Direction / Point Tip weights: the end tangent is the weight times the span, so 0 leaves
## the end flat and a negative weight would turn it back on itself.
const LOFT_WEIGHT_RANGE := [0.0, 10.0]
## Pipe Curve Tolerance (meters): how far apart path ends may be and still join, 0.0001 mm to
## 100 mm (0 would join nothing; a bigger gap joins curves that aren't one path).
const PIPE_TOLERANCE_RANGE := [1e-7, 0.1]

const TOOLS := {
	"extrude": {
		"title": "Extrude", "native": true, "preview": true, "handles": true,
		"hint": "Extrude: pick a profile (or sketch curves, or edges), set the distance, then OK.",
		"picks": [],
		"fields": [
			{"key": "profile", "label": "Profile", "type": "selection", "filter": _CURVES},
			{"key": "distance", "label": "Distance", "type": "expression", "kind": "length"},
			{"key": "direction", "label": "Direction", "type": "enum", "options": _SIDES},
			{"key": "distance2", "label": "Distance 2", "type": "expression", "kind": "length", "visible_if": {"direction": ["two_sides"]}},
			{"key": "taper", "label": "Taper Angle", "type": "expression", "kind": "angle"},
			{"key": "spacing", "label": "Spacing", "type": "enum", "options": _SPACING},
			{"key": "profile_faces", "label": "Profile Faces", "type": "expression", "kind": "number", "range": [1, 64, true]},
			{"key": "front_faces", "label": "Front Faces", "type": "expression", "kind": "number", "range": [1, 64, true]},
			{"key": "keep_creases", "label": "Keep Creases", "type": "bool"},
			{"key": "fit", "label": "Fit to Curves", "type": "bool"},
			_BODY_FIELD,
			{"key": "note", "type": "info", "text": "The ends stay open; Fill Hole closes them."},
		],
		"defaults": {"profile": [], "distance": "@S", "direction": "one_side", "distance2": "@S", "taper": "0 deg", "spacing": "uniform",
			"profile_faces": "8", "front_faces": "1", "keep_creases": true, "fit": true, "body": "new"},
	},
	"revolve": {
		"title": "Revolve", "native": true, "preview": true,
		"hint": "Revolve: pick a profile, then an axis (a sketch line, an axis or a straight edge), then OK.",
		"picks": [],
		"fields": [
			{"key": "profile", "label": "Profile", "type": "selection", "filter": _CURVES, "single": true, "gather": ["sketch_curve", "edge"]},
			{"key": "axis", "label": "Axis", "type": "selection", "filter": ["axis"], "single": true},
			{"key": "type", "label": "Type", "type": "enum", "options": [["full", "Full"], ["angle", "Angle"]]},
			{"key": "angle", "label": "Angle", "type": "expression", "kind": "angle", "visible_if": {"type": ["angle"]}},
			{"key": "direction", "label": "Direction", "type": "enum", "options": _SIDES, "visible_if": {"type": ["angle"]}},
			{"key": "angle2", "label": "Angle 2", "type": "expression", "kind": "angle", "visible_if": {"type": ["angle"], "direction": ["two_sides"]}},
			{"key": "spacing", "label": "Spacing", "type": "enum", "options": _SPACING},
			{"key": "profile_faces", "label": "Profile Faces", "type": "expression", "kind": "number", "range": [1, 64, true]},
			{"key": "around_faces", "label": "Around Faces", "type": "expression", "kind": "number", "range": [1, 64, true]},
			{"key": "weld", "label": "Weld on Axis", "type": "bool"},
			{"key": "symmetry", "label": "Symmetry", "type": "enum", "options": [["none", "None"], ["circular", "Circular"]], "visible_if": {"type": ["full"]}},
			{"key": "keep_creases", "label": "Keep Creases", "type": "bool"},
			{"key": "fit", "label": "Fit to Curves", "type": "bool"},
			_BODY_FIELD,
			{"key": "note", "type": "info", "text": ""},
		],
		"defaults": {"profile": [], "axis": [], "type": "full", "angle": "90 deg", "direction": "one_side", "angle2": "90 deg", "spacing": "uniform",
			"profile_faces": "4", "around_faces": "8", "weld": true, "symmetry": "none", "keep_creases": true, "fit": true, "body": "new"},
	},
	"sweep": {
		"title": "Sweep", "native": true, "preview": true,
		"hint": "Sweep: pick a profile, then the path it follows, then OK.",
		"picks": [],
		"fields": [
			{"key": "profile", "label": "Profile", "type": "selection", "filter": _CURVES, "single": true, "gather": ["sketch_curve", "edge"]},
			{"key": "path", "label": "Path", "type": "selection", "filter": ["sketch_curve", "edge"]},
			{"key": "profile_faces", "label": "Profile Faces", "type": "expression", "kind": "number", "range": [1, 64, true]},
			{"key": "profile_spacing", "label": "Profile Spacing", "type": "enum", "options": _SPACING},
			{"key": "path_faces", "label": "Path Faces", "type": "expression", "kind": "number", "range": [1, 64, true]},
			{"key": "path_spacing", "label": "Path Spacing", "type": "enum", "options": _SPACING},
			{"key": "orientation", "label": "Orientation", "type": "enum", "options": [["perpendicular", "Perpendicular"], ["parallel", "Parallel"]]},
			{"key": "extent", "label": "Distance", "type": "expression", "kind": "number", "range": [0, 1]},
			{"key": "keep_creases", "label": "Keep Creases", "type": "bool"},
			{"key": "fit", "label": "Fit to Curves", "type": "bool"},
			_BODY_FIELD,
			{"key": "note", "type": "info", "text": "Distance: how much of the path to follow (0 to 1)."},
		],
		"defaults": {"profile": [], "path": [], "profile_faces": "8", "profile_spacing": "uniform", "path_faces": "8", "path_spacing": "uniform",
			"orientation": "perpendicular", "extent": "1", "keep_creases": true, "fit": true, "body": "new"},
	},
	"loft": {
		"title": "Loft", "native": true, "preview": true,
		"hint": "Loft: pick two or more profiles in order (closed or open curves, or a point at an end), then OK.",
		"picks": [],
		"fields": [
			{"key": "profiles", "label": "Profiles", "type": "selection", "filter": ["profile", "sketch_curve", "edge", "point"]},
			{"key": "guide", "label": "Guide", "type": "enum", "options": [["none", "None"], ["rails", "Rails"], ["centerline", "Centerline"]]},
			{"key": "rails", "label": "Rails", "type": "selection", "filter": ["sketch_curve", "edge"], "visible_if": {"guide": ["rails"]}},
			{"key": "centerline", "label": "Centerline", "type": "selection", "filter": ["sketch_curve", "edge"], "visible_if": {"guide": ["centerline"]}},
			{"key": "closed", "label": "Closed", "type": "bool"},
			{"key": "length_faces", "label": "Length Faces", "type": "expression", "kind": "number", "range": [1, 64, true]},
			{"key": "width_faces", "label": "Width Faces", "type": "expression", "kind": "number", "range": [2, 64, true]},
			{"key": "spacing", "label": "Spacing", "type": "enum", "options": _SPACING},
			{"key": "start", "label": "Start", "type": "enum", "options": _ENDS},
			{"key": "start_angle", "label": "Start Takeoff", "type": "expression", "kind": "angle", "visible_if": {"start": ["direction"]}},
			{"key": "start_weight", "label": "Start Weight", "type": "expression", "kind": "number", "visible_if": {"start": ["direction", "tip"]}, "range": LOFT_WEIGHT_RANGE},
			{"key": "end", "label": "End", "type": "enum", "options": _ENDS},
			{"key": "end_angle", "label": "End Takeoff", "type": "expression", "kind": "angle", "visible_if": {"end": ["direction"]}},
			{"key": "end_weight", "label": "End Weight", "type": "expression", "kind": "number", "visible_if": {"end": ["direction", "tip"]}, "range": LOFT_WEIGHT_RANGE},
			{"key": "fit", "label": "Fit to Curves", "type": "bool"},
			_BODY_FIELD,
			{"key": "note", "type": "info", "text": "Length Faces: faces between two profiles."},
		],
		"defaults": {"profiles": [], "guide": "none", "rails": [], "centerline": [], "closed": false, "length_faces": "2", "width_faces": "8",
			"spacing": "uniform", "start": "free", "start_angle": "0 deg", "start_weight": "1", "end": "free", "end_angle": "0 deg", "end_weight": "1",
			"fit": true, "body": "new"},
	},
	"pipe": {
		"title": "Pipe", "native": true, "preview": true, "interact": true,
		"hint": "Pipe: pick the path's connected curves or edges, then OK.",
		"picks": [],
		"fields": [
			{"key": "path", "label": "Path", "type": "selection", "filter": ["sketch_curve", "edge"]},
			{"key": "diameter", "label": "Global Diameter", "type": "expression", "kind": "length"},
			{"key": "around_faces", "label": "Around Faces", "type": "expression", "kind": "number", "range": [3, 64, true]},
			{"key": "density", "label": "Density (0 = auto)", "type": "expression", "kind": "number", "range": [0, 256, true]},
			{"key": "start_end", "label": "Start End", "type": "enum", "options": _PIPE_ENDS},
			{"key": "end_end", "label": "End End", "type": "enum", "options": _PIPE_ENDS},
			{"key": "tolerance", "label": "Curve Tolerance", "type": "expression", "kind": "length", "range": PIPE_TOLERANCE_RANGE},
			{"key": "add_section", "label": "Add Section", "type": "button", "tooltip": "Then click on the path where the section goes (up to 8)"},
			{"key": "clear_sections", "label": "Clear Sections", "type": "button", "tooltip": "Remove every section"},
			{"key": "s1_pos", "label": "Section 1 Position", "type": "expression", "kind": "number", "visible_if": {"sections": ["1", "2", "3", "4", "5", "6", "7", "8"]}, "range": [0, 1]},
			{"key": "s1_dia", "label": "Section 1 Diameter", "type": "expression", "kind": "length", "visible_if": {"sections": ["1", "2", "3", "4", "5", "6", "7", "8"]}},
			{"key": "s1_angle", "label": "Section 1 Angle", "type": "expression", "kind": "angle", "visible_if": {"sections": ["1", "2", "3", "4", "5", "6", "7", "8"]}},
			{"key": "s2_pos", "label": "Section 2 Position", "type": "expression", "kind": "number", "visible_if": {"sections": ["2", "3", "4", "5", "6", "7", "8"]}, "range": [0, 1]},
			{"key": "s2_dia", "label": "Section 2 Diameter", "type": "expression", "kind": "length", "visible_if": {"sections": ["2", "3", "4", "5", "6", "7", "8"]}},
			{"key": "s2_angle", "label": "Section 2 Angle", "type": "expression", "kind": "angle", "visible_if": {"sections": ["2", "3", "4", "5", "6", "7", "8"]}},
			{"key": "s3_pos", "label": "Section 3 Position", "type": "expression", "kind": "number", "visible_if": {"sections": ["3", "4", "5", "6", "7", "8"]}, "range": [0, 1]},
			{"key": "s3_dia", "label": "Section 3 Diameter", "type": "expression", "kind": "length", "visible_if": {"sections": ["3", "4", "5", "6", "7", "8"]}},
			{"key": "s3_angle", "label": "Section 3 Angle", "type": "expression", "kind": "angle", "visible_if": {"sections": ["3", "4", "5", "6", "7", "8"]}},
			{"key": "s4_pos", "label": "Section 4 Position", "type": "expression", "kind": "number", "visible_if": {"sections": ["4", "5", "6", "7", "8"]}, "range": [0, 1]},
			{"key": "s4_dia", "label": "Section 4 Diameter", "type": "expression", "kind": "length", "visible_if": {"sections": ["4", "5", "6", "7", "8"]}},
			{"key": "s4_angle", "label": "Section 4 Angle", "type": "expression", "kind": "angle", "visible_if": {"sections": ["4", "5", "6", "7", "8"]}},
			{"key": "s5_pos", "label": "Section 5 Position", "type": "expression", "kind": "number", "visible_if": {"sections": ["5", "6", "7", "8"]}, "range": [0, 1]},
			{"key": "s5_dia", "label": "Section 5 Diameter", "type": "expression", "kind": "length", "visible_if": {"sections": ["5", "6", "7", "8"]}},
			{"key": "s5_angle", "label": "Section 5 Angle", "type": "expression", "kind": "angle", "visible_if": {"sections": ["5", "6", "7", "8"]}},
			{"key": "s6_pos", "label": "Section 6 Position", "type": "expression", "kind": "number", "visible_if": {"sections": ["6", "7", "8"]}, "range": [0, 1]},
			{"key": "s6_dia", "label": "Section 6 Diameter", "type": "expression", "kind": "length", "visible_if": {"sections": ["6", "7", "8"]}},
			{"key": "s6_angle", "label": "Section 6 Angle", "type": "expression", "kind": "angle", "visible_if": {"sections": ["6", "7", "8"]}},
			{"key": "s7_pos", "label": "Section 7 Position", "type": "expression", "kind": "number", "visible_if": {"sections": ["7", "8"]}, "range": [0, 1]},
			{"key": "s7_dia", "label": "Section 7 Diameter", "type": "expression", "kind": "length", "visible_if": {"sections": ["7", "8"]}},
			{"key": "s7_angle", "label": "Section 7 Angle", "type": "expression", "kind": "angle", "visible_if": {"sections": ["7", "8"]}},
			{"key": "s8_pos", "label": "Section 8 Position", "type": "expression", "kind": "number", "visible_if": {"sections": ["8"]}, "range": [0, 1]},
			{"key": "s8_dia", "label": "Section 8 Diameter", "type": "expression", "kind": "length", "visible_if": {"sections": ["8"]}},
			{"key": "s8_angle", "label": "Section 8 Angle", "type": "expression", "kind": "angle", "visible_if": {"sections": ["8"]}},
			{"key": "fit", "label": "Fit to Curves", "type": "bool"},
			_BODY_FIELD,
			{"key": "note", "type": "info", "text": ""},
		],
		"defaults": {"path": [], "diameter": "@S5", "around_faces": "8", "density": "0", "start_end": "open", "end_end": "open", "tolerance": "0.01 mm",
			"sections": "0",
			"s1_pos": "0.5", "s1_dia": "@S5", "s1_angle": "0 deg",
			"s2_pos": "0.5", "s2_dia": "@S5", "s2_angle": "0 deg",
			"s3_pos": "0.5", "s3_dia": "@S5", "s3_angle": "0 deg",
			"s4_pos": "0.5", "s4_dia": "@S5", "s4_angle": "0 deg",
			"s5_pos": "0.5", "s5_dia": "@S5", "s5_angle": "0 deg",
			"s6_pos": "0.5", "s6_dia": "@S5", "s6_angle": "0 deg",
			"s7_pos": "0.5", "s7_dia": "@S5", "s7_angle": "0 deg",
			"s8_pos": "0.5", "s8_dia": "@S5", "s8_angle": "0 deg",
			"fit": true, "body": "new"},
	},
	"face": {
		"title": "Face", "preview": true, "interact": true, "repeat": true,
		"hint": "Face: click four corners on the plane or on cage vertices, then OK.",
		"picks": [],
		"fields": [
			{"key": "mode", "label": "Mode", "type": "enum", "options": [["simple", "Simple"], ["edge", "Edge"], ["chain", "Chain"]]},
			{"key": "sides", "label": "Sides", "type": "enum", "options": [["four", "Four"], ["multiple", "Multiple"]], "visible_if": {"mode": ["simple"]}},
			{"key": "pick_plane", "label": "Pick Plane", "type": "button", "tooltip": "Pick the plane new corners lie on (otherwise the plane of the face under the first click, or XY)"},
			{"key": "note", "type": "info", "text": ""},
		],
		"defaults": {"mode": "simple", "sides": "four"},
	},
}


# ---------------------------------------------------------------------------------------------
# Shared
# ---------------------------------------------------------------------------------------------

static func _failure(message: String, info := {}) -> Dictionary:
	return {"ok": false, "error": message, "warnings": PackedStringArray(), "info": info}


## What core/references.gd resolves picks against, from a tool ctx (or the editor's workspace).
static func refs_ctx(ctx: Dictionary) -> Dictionary:
	var result: Dictionary = ctx.get("result", {})
	return {"doc": ctx.get("doc"), "kernel": ctx.get("kernel"), "sketches": result.get("sketches", {}), "bodies": result.get("bodies", {}),
		"construction": result.get("construction", {}), "values": result.get("values", {})}


static func _editor_refs_ctx(editor: Object) -> Dictionary:
	var ws: Object = editor.workspace
	return refs_ctx({"doc": ws.doc, "kernel": ws.kernel, "result": ws.result})


static func _count(values: Dictionary, key: String, fallback: int, lo := 1, hi := 64) -> int:
	var v: Variant = values.get(key, fallback)
	if not (v is float or v is int):
		return fallback
	return clampi(roundi(float(v)), lo, hi)


## Fits each part onto its curves (when asked), joins the parts into one cage, adds Revolve's
## symmetry, and makes it a new body or appends it to the picked one.
static func _finish(ctx: Dictionary, values: Dictionary, parts: Array, warnings: PackedStringArray, info: Dictionary, symmetry := {}) -> Dictionary:
	var cage := {}
	for part in parts:
		var c: Dictionary = part.cage
		if bool(values.get("fit", true)):
			var fitted := FORM_CREATE.fit_cage(c, part.fit)
			if str(fitted.error) != "":
				warnings.append(str(fitted.error))
			elif str(fitted.warning) != "":
				warnings.append(str(fitted.warning))
			c = fitted.cage
		cage = c if cage.is_empty() else CAGE.append(cage, c).cage
	var target := str(values.get("body", "new"))
	var cages: Dictionary = ctx.get("cages", {})
	var appending := target != "new" and cages.has(target)
	if not symmetry.is_empty():
		if appending:
			warnings.append("Symmetry isn't added to a cage appended to another body")
		else:
			cage = PRIMITIVES.primitive_symmetry(cage, "circular", symmetry.frame, Vector3i.ZERO, int(symmetry.count))
	var panel: Dictionary = info.get("panel", {})
	panel["note"] = "%d vertices, %d faces%s" % [CAGE.vertex_count(cage), CAGE.face_count(cage), "" if str(panel.get("note", "")) == "" else "; " + str(panel.note)]
	info["panel"] = panel
	if appending:
		return {"ok": true, "cages": {target: CAGE.append(cages[target], cage).cage}, "warnings": warnings, "info": info}
	return {"ok": true, "new_bodies": [cage], "warnings": warnings, "info": info}


## The chains a curve slot picked (error text when it can't be followed).
static func _chains(ctx: Dictionary, refs: Array, empty_message: String, tol := 0.0) -> Dictionary:
	if refs.is_empty():
		return {"error": empty_message}
	var found := FORM_CREATE.chains_of(refs, refs_ctx(ctx), tol)
	if str(found.error) != "":
		return found
	if (found.chains as Array).is_empty() and (found.points as Array).is_empty():
		return {"error": empty_message, "chains": [], "points": [], "warnings": found.warnings}
	return found


## A face count that suits the picked profile: 8 for a closed one, 4 for an open one, while the
## field still holds the count the tool put there (a typed count stays).
static func _auto_faces(editor: Object, values: Dictionary, pick_key: String, faces_key: String) -> Dictionary:
	var state: Dictionary = editor.tool_state
	var refs: Array = values.get(pick_key, [])
	var key := str(refs)
	if str(state.get("faces_for_" + faces_key, "[]")) == key:
		return {}
	state["faces_for_" + faces_key] = key
	var auto := str(state.get("auto_" + faces_key, "8"))
	if str(values.get(faces_key, "")).strip_edges() != auto:
		return {}
	var closed := true
	if not refs.is_empty():
		var found := FORM_CREATE.chains_of(refs, _editor_refs_ctx(editor))
		if not (found.chains as Array).is_empty():
			closed = bool(found.chains[0].closed)
	var want := "8" if closed else "4"
	state["auto_" + faces_key] = want
	return {faces_key: want} if want != auto else {}


# ---------------------------------------------------------------------------------------------
# Extrude
# ---------------------------------------------------------------------------------------------

static func run_extrude(ctx: Dictionary, _picks: Dictionary, values: Dictionary) -> Dictionary:
	var found := _chains(ctx, values.get("profile", []), "Pick a profile, sketch curves or edges to extrude.")
	if found.has("error") and str(found.error) != "":
		return _failure(str(found.error))
	var d := float(values.get("distance", 0.0))
	if absf(d) <= 1e-12:
		return _failure("The distance can't be zero.")
	var warnings: PackedStringArray = found.warnings
	var parts := []
	var opts := {"distance": d, "direction": str(values.get("direction", "one_side")), "distance2": float(values.get("distance2", 0.0)),
		"taper": float(values.get("taper", 0.0)), "front_faces": _count(values, "front_faces", 1), "keep_creases": bool(values.get("keep_creases", true))}
	var frame := {}
	for chain in found.chains:
		var plane := FORM_CREATE.chain_plane(chain)
		if not bool(plane.planar):
			return _failure("Extrude needs a flat profile: the picked curves don't lie in one plane.")
		var samples := FORM_CREATE.resample(chain, _count(values, "profile_faces", 8), {"spacing": str(values.get("spacing", "uniform"))})
		if bool(samples.raised):
			warnings.append("Profile Faces raised to %d to keep a vertex on every sharp corner" % int(samples.segments))
		var normal: Vector3 = (plane.plane as Transform3D).basis.z
		var built := FORM_CREATE.extrude(samples, normal, opts)
		if not bool(built.ok):
			return _failure(str(built.error))
		parts.append(built)
		if frame.is_empty():
			frame = {"origin": FORM_CREATE._centroid(samples.points), "normal": normal.normalized()}
	if ctx.get("editor") != null:
		(ctx.editor.tool_state as Dictionary)["extrude_frame"] = frame
	return _finish(ctx, values, parts, warnings, {})


static func values_extrude(editor: Object, values: Dictionary) -> Dictionary:
	return _auto_faces(editor, values, "profile", "profile_faces")


## The distance arrows (positive distances only; a negative one is typed).
static func handles_extrude(editor: Object, values: Dictionary) -> Array:
	var frame: Dictionary = editor.tool_state.get("extrude_frame", {})
	if frame.is_empty():
		return []
	var ev: Dictionary = editor.evaluated_values()
	var d := float(ev.get("distance", 0.0))
	var n: Vector3 = frame.normal
	var o: Vector3 = frame.origin
	var out := []
	match str(values.get("direction", "one_side")):
		"symmetric":
			if d > 0.0:
				out.append({"type": "arrow", "key": "distance", "origin": o + n * d * 0.5, "direction": n, "factor": 2.0})
		"two_sides":
			var d2 := float(ev.get("distance2", 0.0))
			if d > 0.0:
				out.append({"type": "arrow", "key": "distance", "origin": o + n * d, "direction": n, "factor": 1.0})
			if d2 > 0.0:
				out.append({"type": "arrow", "key": "distance2", "origin": o - n * d2, "direction": -n, "factor": 1.0})
		_:
			if d > 0.0:
				out.append({"type": "arrow", "key": "distance", "origin": o + n * d, "direction": n, "factor": 1.0})
	return out


# ---------------------------------------------------------------------------------------------
# Revolve
# ---------------------------------------------------------------------------------------------

static func run_revolve(ctx: Dictionary, _picks: Dictionary, values: Dictionary) -> Dictionary:
	var found := _chains(ctx, values.get("profile", []), "Pick a profile to revolve.")
	if found.has("error") and str(found.error) != "":
		return _failure(str(found.error))
	var axis_refs: Array = values.get("axis", [])
	if axis_refs.is_empty():
		return _failure("Pick an axis: a sketch line, an origin or construction axis, or a straight edge.")
	var axis := REFERENCES.axis(axis_refs[0], refs_ctx(ctx))
	if axis.has("error"):
		return _failure(str(axis.error))
	var origin: Vector3 = axis.origin
	var direction: Vector3 = (axis.direction as Vector3).normalized()
	var around := _count(values, "around_faces", 8)
	if str(values.get("type", "full")) == "full" and around < 3:
		return _failure("Around Faces must be a whole number from 3 to 64 for a full revolve.")
	var opts := {"type": str(values.get("type", "full")), "angle": float(values.get("angle", PI * 0.5)), "direction": str(values.get("direction", "one_side")),
		"angle2": float(values.get("angle2", PI * 0.5)), "around": around, "weld": bool(values.get("weld", true)),
		"keep_creases": bool(values.get("keep_creases", true))}
	var warnings: PackedStringArray = found.warnings
	var parts := []
	for chain in found.chains:
		var samples := FORM_CREATE.resample(chain, _count(values, "profile_faces", 4), {"spacing": str(values.get("spacing", "uniform"))})
		if bool(samples.raised):
			warnings.append("Profile Faces raised to %d to keep a vertex on every sharp corner" % int(samples.segments))
		var built := FORM_CREATE.revolve(samples, origin, direction, opts)
		if not bool(built.ok):
			return _failure(str(built.error))
		warnings.append_array(built.warnings)
		parts.append(built)
	var symmetry := {}
	if str(values.get("symmetry", "none")) == "circular" and str(values.get("type", "full")) == "full":
		var x := FORM_CREATE._perpendicular(direction)
		symmetry = {"frame": Transform3D(Basis(x, direction.cross(x), direction), origin), "count": around}
	return _finish(ctx, values, parts, warnings, {}, symmetry)


# ---------------------------------------------------------------------------------------------
# Sweep
# ---------------------------------------------------------------------------------------------

static func run_sweep(ctx: Dictionary, _picks: Dictionary, values: Dictionary) -> Dictionary:
	var profile := _chains(ctx, values.get("profile", []), "Pick a profile to sweep.")
	if profile.has("error") and str(profile.error) != "":
		return _failure(str(profile.error))
	var path := _chains(ctx, values.get("path", []), "Pick the path to sweep along.")
	if path.has("error") and str(path.error) != "":
		return _failure(str(path.error))
	if (profile.chains as Array).is_empty() or (path.chains as Array).is_empty():
		return _failure("Pick a profile and a path.")
	if (path.chains as Array).size() > 1:
		return _failure("The path's curves must connect end to end.")
	var warnings: PackedStringArray = profile.warnings
	if (profile.chains as Array).size() > 1:
		warnings.append("Only the first profile is swept")
	var pchain: Dictionary = profile.chains[0]
	var cchain: Dictionary = path.chains[0]
	var extent := clampf(float(values.get("extent", 1.0)), 0.0, 1.0)
	if extent <= 1e-6:
		return _failure("Distance must be more than 0 (a fraction of the path, up to 1).")
	var psamples := FORM_CREATE.resample(pchain, _count(values, "profile_faces", 8), {"spacing": str(values.get("profile_spacing", "uniform"))})
	var csamples := FORM_CREATE.resample(cchain, _count(values, "path_faces", 8),
		{"spacing": str(values.get("path_spacing", "uniform")), "to": float(cchain.length) * extent})
	var plane := FORM_CREATE.chain_plane(pchain)
	var built := FORM_CREATE.sweep(psamples, csamples, {"orientation": str(values.get("orientation", "perpendicular")),
		"profile_plane": plane.plane if bool(plane.planar) else null, "keep_creases": bool(values.get("keep_creases", true))})
	if not bool(built.ok):
		return _failure(str(built.error))
	return _finish(ctx, values, [built], warnings, {})


# ---------------------------------------------------------------------------------------------
# Loft
# ---------------------------------------------------------------------------------------------

static func run_loft(ctx: Dictionary, _picks: Dictionary, values: Dictionary) -> Dictionary:
	var found := _chains(ctx, values.get("profiles", []), "Pick two or more profiles, in order.")
	if found.has("error") and str(found.error) != "":
		return _failure(str(found.error))
	# Sections in pick order: curve chains and point tips.
	var items := []
	for chain in found.chains:
		items.append({"order": int(chain.order), "chain": chain})
	for p in found.points:
		items.append({"order": int(p.order), "point": p.point})
	items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.order) < int(b.order))
	if items.size() < 2:
		return _failure("Pick two or more profiles, in order.")
	var k := _count(values, "width_faces", 8, 2)
	var spacing := str(values.get("spacing", "uniform"))
	var sections := []
	var warnings: PackedStringArray = found.warnings
	for item in items:
		if item.has("point"):
			sections.append({"points": PackedVector3Array([item.point]), "closed": false, "point": true, "normal": Vector3.ZERO})
			continue
		var chain: Dictionary = item.chain
		var samples := FORM_CREATE.resample(chain, k, {"spacing": spacing})
		if int(samples.segments) != k:
			return _failure("Width Faces must be at least %d (a profile's sharp corners each need a vertex)." % int(samples.segments))
		var plane := FORM_CREATE.chain_plane(chain)
		sections.append({"points": samples.points, "closed": bool(samples.closed), "point": false,
			"normal": (plane.plane as Transform3D).basis.z if bool(plane.planar) else Vector3.ZERO})
	var opts := {"closed": bool(values.get("closed", false)), "length_faces": _count(values, "length_faces", 2),
		"start": {"type": str(values.get("start", "free")), "angle": float(values.get("start_angle", 0.0)), "weight": float(values.get("start_weight", 1.0))},
		"end": {"type": str(values.get("end", "free")), "angle": float(values.get("end_angle", 0.0)), "weight": float(values.get("end_weight", 1.0))}}
	for end in ["start", "end"]:
		var index := 0 if end == "start" else sections.size() - 1
		if str(opts[end].type) == "tip" and not bool(sections[index].point):
			return _failure("Point Tip needs a point as the %s profile." % ("first" if end == "start" else "last"))
	match str(values.get("guide", "none")):
		"rails":
			var rails := _chains(ctx, values.get("rails", []), "Pick the rails the loft follows.")
			if rails.has("error") and str(rails.error) != "":
				return _failure(str(rails.error))
			var guides := []
			for chain in rails.chains:
				guides.append(FORM_CREATE.guide(chain))
			opts["rails"] = guides
		"centerline":
			var line := _chains(ctx, values.get("centerline", []), "Pick the centerline the loft turns along.")
			if line.has("error") and str(line.error) != "":
				return _failure(str(line.error))
			opts["centerline"] = FORM_CREATE.guide(line.chains[0])
	var built := FORM_CREATE.loft(sections, opts)
	if not bool(built.ok):
		return _failure(str(built.error))
	return _finish(ctx, values, [built], warnings, {})


static func values_loft(editor: Object, values: Dictionary) -> Dictionary:
	return _auto_faces(editor, values, "profiles", "width_faces")


# ---------------------------------------------------------------------------------------------
# Pipe
# ---------------------------------------------------------------------------------------------

static func run_pipe(ctx: Dictionary, _picks: Dictionary, values: Dictionary) -> Dictionary:
	# (Typed values out of PIPE_TOLERANCE_RANGE are refused by FORM_TOOLS.run before this.)
	var tol := float(values.get("tolerance", 1e-5))
	var refs: Array = values.get("path", [])
	if refs.is_empty():
		return _failure("Pick the path's curves or edges.")
	var found := FORM_CREATE.chains_of(refs, refs_ctx(ctx), tol)
	if bool(found.branching):
		return _failure(FORM_CREATE.BRANCHING)
	if str(found.error) != "":
		return _failure(str(found.error))
	if (found.chains as Array).is_empty():
		return _failure("Pick the path's curves or edges.")
	var d := float(values.get("diameter", 0.0))
	if d <= 0.0:
		return _failure("The diameter must be greater than zero.")
	var density := _count(values, "density", 0, 0, 256)
	var stations := []
	for i in range(1, clampi(int(str(values.get("sections", "0"))), 0, MAX_SECTIONS) + 1):
		stations.append({"position": float(values.get("s%d_pos" % i, 0.5)), "diameter": float(values.get("s%d_dia" % i, d)),
			"angle": float(values.get("s%d_angle" % i, 0.0))})
	var opts := {"diameter": d, "around": _count(values, "around_faces", 8, 3), "start_end": str(values.get("start_end", "open")),
		"end_end": str(values.get("end_end", "open")), "stations": stations}
	var parts := []
	var lines := []
	var segments := 0
	for chain in found.chains:
		var per_piece := PackedInt32Array()
		for piece in chain.pieces:
			per_piece.append(density if density > 0 else maxi(2, roundi(float(piece.length) / d)))
		var samples := FORM_CREATE.resample(chain, 0, {"per_piece": per_piece})
		segments += int(samples.segments)
		var plane := FORM_CREATE.chain_plane(chain)
		var chain_opts := opts.duplicate()
		chain_opts["length"] = float(chain.length)
		chain_opts["normal"] = (plane.plane as Transform3D).basis.z if bool(plane.planar) else Vector3.ZERO
		var built := FORM_CREATE.pipe(samples, chain_opts)
		if not bool(built.ok):
			return _failure(str(built.error))
		parts.append(built)
		var line := PackedVector3Array()
		var fractions := PackedFloat64Array()
		for q in 65:
			var s := float(chain.length) * q / 64.0
			line.append(FORM_CREATE.chain_point(chain, s).point)
			fractions.append(q / 64.0)
		lines.append({"points": line, "fractions": fractions})
	if ctx.get("editor") != null:
		(ctx.editor.tool_state as Dictionary)["pipe_paths"] = lines
	return _finish(ctx, values, parts, PackedStringArray(found.warnings), {"panel": {"note": "%d segments along the path" % segments}})


## Add Section: the next click on the path places a section there; Clear Sections removes them.
static func button_pipe(editor: Object, key: String) -> void:
	match key:
		"add_section":
			if clampi(int(str(editor.tool_values.get("sections", "0"))), 0, MAX_SECTIONS) >= MAX_SECTIONS:
				editor.workspace.flash("A pipe takes up to %d sections." % MAX_SECTIONS)
				return
			if (editor.tool_state.get("pipe_paths", []) as Array).is_empty():
				editor.workspace.flash("Pick the path first, then add sections on it.")
				return
			editor.tool_state["adding_section"] = true
			editor.workspace.flash("Pipe: click on the path where the section goes.")
		"clear_sections":
			editor.tool_state.erase("adding_section")
			editor.set_tool_values({"sections": "0"})


static func handle_mouse_pipe(editor: Object, event: InputEvent) -> bool:
	if not bool(editor.tool_state.get("adding_section", false)):
		return false
	var button := event as InputEventMouseButton
	var at: Vector2 = (event as InputEventMouse).position
	var hit := _path_fraction(editor, at)
	editor.tool_state["section_hover"] = hit
	if button == null:
		return true
	if button.button_index != MOUSE_BUTTON_LEFT or not button.pressed:
		return true
	if hit.is_empty():
		editor.workspace.flash("Click on the path (the section goes where you click).")
		return true
	var count := clampi(int(str(editor.tool_values.get("sections", "0"))), 0, MAX_SECTIONS) + 1
	editor.tool_state.erase("adding_section")
	editor.tool_state.erase("section_hover")
	editor.set_tool_values({"sections": str(count), "s%d_pos" % count: "%.4f" % float(hit.fraction),
		"s%d_dia" % count: str(editor.tool_values.get("diameter", "")), "s%d_angle" % count: "0 deg"})
	editor.workspace.call_deferred("place_panel")
	return true


## The path point nearest a screen position (within 10 px): {"fraction", "point"} or {}.
static func _path_fraction(editor: Object, at: Vector2) -> Dictionary:
	var best := {}
	var best_px := 10.0
	for line in editor.tool_state.get("pipe_paths", []):
		var pts: PackedVector3Array = line.points
		var fr: PackedFloat64Array = line.fractions
		for i in pts.size() - 1:
			var a: Vector2 = editor.viewport.project(pts[i])
			var b: Vector2 = editor.viewport.project(pts[i + 1])
			if not (a.is_finite() and b.is_finite()):
				continue
			var q := Geometry2D.get_closest_point_to_segment(at, a, b)
			var dpx := q.distance_to(at)
			if dpx < best_px:
				best_px = dpx
				var t := (q - a).length() / maxf((b - a).length(), 1e-9)
				best = {"fraction": lerpf(fr[i], fr[i + 1], t), "point": pts[i].lerp(pts[i + 1], t)}
	return best


## Section markers on the path, and the spot a click would place one.
static func draw_pipe(editor: Object, overlay: Control) -> void:
	var c: Dictionary = editor.theme_colors
	var lines: Array = editor.tool_state.get("pipe_paths", [])
	if lines.is_empty():
		return
	var count := clampi(int(str(editor.tool_values.get("sections", "0"))), 0, MAX_SECTIONS)
	var ev: Dictionary = editor.evaluated_values()
	var line: Dictionary = lines[0]
	for i in range(1, count + 1):
		var f := clampf(float(ev.get("s%d_pos" % i, 0.5)), 0.0, 1.0)
		var p := _line_point(line, f)
		var at: Vector2 = editor.viewport.project(p)
		if at.is_finite():
			overlay.draw_arc(at, 6.0, 0.0, TAU, 20, c.form_preview, 2.0, true)
			overlay.draw_string(overlay.get_theme_default_font(), at + Vector2(8, -6), str(i), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, c.form_preview)
	var hover: Dictionary = editor.tool_state.get("section_hover", {})
	if bool(editor.tool_state.get("adding_section", false)) and not hover.is_empty():
		var at: Vector2 = editor.viewport.project(hover.point)
		if at.is_finite():
			overlay.draw_circle(at, 5.0, c.form_preview)


static func _line_point(line: Dictionary, f: float) -> Vector3:
	var pts: PackedVector3Array = line.points
	var fr: PackedFloat64Array = line.fractions
	for i in pts.size() - 1:
		if f <= fr[i + 1] or i == pts.size() - 2:
			var span := fr[i + 1] - fr[i]
			return pts[i].lerp(pts[i + 1], clampf((f - fr[i]) / span, 0.0, 1.0) if span > 0.0 else 0.0)
	return pts[0]


# ---------------------------------------------------------------------------------------------
# Face
# ---------------------------------------------------------------------------------------------

## A face from clicks. picks: "corners" [{"point": Vector3, "body": id ("" for a new point),
## "vertex": int}], "edge" {"body", "pair": Vector2i} (Edge mode: its two ends come first,
## turned against their face), "chain" {"body", "pairs": PackedInt32Array, "start": vertex}
## and "offset": Vector3 (Chain mode: the chain's open edges extended to the offset point).
## Snapped corners reuse their vertices; corners on two bodies join them into one.
static func run_face(ctx: Dictionary, picks: Dictionary, values: Dictionary) -> Dictionary:
	var cages: Dictionary = ctx.get("cages", {})
	var mode := str(values.get("mode", "simple"))
	if mode == "chain":
		return _face_chain(ctx, picks)
	var corners: Array = (picks.get("corners", []) as Array).duplicate()
	if mode == "edge":
		var edge: Dictionary = picks.get("edge", {})
		if edge.is_empty() or not cages.has(str(edge.get("body", ""))):
			return _failure("Pick an open boundary edge of a body, then click two more corners.")
		var pair: Vector2i = edge.pair
		var cage: Dictionary = cages[edge.body]
		var topo := CAGE.topology(cage)
		# Against the existing face: it runs a -> b, the new face b -> a.
		var a := pair.x
		var b := pair.y
		if topo.half_edge(a, b) < 0:
			a = pair.y
			b = pair.x
		corners.push_front({"point": CAGE.position(cage, a), "body": str(edge.body), "vertex": a})
		corners.push_front({"point": CAGE.position(cage, b), "body": str(edge.body), "vertex": b})
		if corners.size() < 4:
			return _failure("Click %d more corner%s." % [4 - corners.size(), "" if corners.size() == 3 else "s"])
		corners = corners.slice(0, 4)
		corners = _untangle(corners)
	else:
		var four := str(values.get("sides", "four")) == "four"
		var need := 4 if four else 3
		if corners.size() < need:
			return _failure("Click %d more corner%s." % [need - corners.size(), "" if need - corners.size() == 1 else "s"])
		if four:
			corners = corners.slice(0, 4)
	var camera: Vector3 = Vector3(0.0, 0.0, 1e6)
	var editor: Object = ctx.get("editor")
	if editor != null and editor.viewport != null and editor.viewport.camera() != null:
		camera = editor.viewport.camera().global_position
	return build_face(cages, corners, camera)


## Joins corners into one face: {"ok", "cages" / "new_bodies", "removed_bodies", "selection"} or
## a failure. camera: where the face looks when it touches no other face.
static func build_face(cages: Dictionary, corners: Array, camera: Vector3) -> Dictionary:
	var bodies := []
	for c in corners:
		var body := str(c.get("body", ""))
		if body != "" and not bodies.has(body) and cages.has(body):
			bodies.append(body)
	var base: Dictionary = CAGE.empty()
	var offsets := {}
	if not bodies.is_empty():
		base = CAGE.copy(cages[bodies[0]])
		offsets[bodies[0]] = 0
		for i in range(1, bodies.size()):
			var r := CAGE.append(base, cages[bodies[i]])
			offsets[bodies[i]] = int(r.offset)
			base = r.cage
	var topo := CAGE.topology(base)
	var p: PackedFloat64Array = (base.positions as PackedFloat64Array).duplicate()
	var face := PackedInt32Array()
	for c in corners:
		var body := str(c.get("body", ""))
		if body != "" and offsets.has(body):
			face.append(int(offsets[body]) + int(c.vertex))
		else:
			var q: Vector3 = c.point
			face.append(p.size() / 3)
			p.append(q.x)
			p.append(q.y)
			p.append(q.z)
	for i in face.size():
		for j in range(i + 1, face.size()):
			if face[i] == face[j]:
				return _failure("A face can't use the same vertex twice.")
	if topo.face_by_vertices(face) >= 0:
		return _failure("That face is already there.")
	# Agree with the faces it touches, or face the camera when it touches none.
	var agree := 0
	var against := 0
	var n := face.size()
	for k in n:
		var a := face[k]
		var b := face[(k + 1) % n]
		if a < topo.nV and b < topo.nV:
			if topo.half_edge(a, b) >= 0:
				against += 1
			if topo.half_edge(b, a) >= 0:
				agree += 1
	if agree > 0 and against > 0:
		return _failure("That face would turn against its neighbours; click the corners the other way round.")
	var out := CAGE.copy(base)
	out.positions = p
	var normal := Vector3.ZERO
	var centre := Vector3.ZERO
	for k in n:
		var a := Vector3(p[3 * face[k]], p[3 * face[k] + 1], p[3 * face[k] + 2])
		var b := Vector3(p[3 * face[(k + 1) % n]], p[3 * face[(k + 1) % n] + 1], p[3 * face[(k + 1) % n] + 2])
		normal += a.cross(b)
		centre += a
	centre /= n
	if against > 0 or (agree == 0 and normal.dot(camera - centre) < 0.0):
		face.reverse()
	if normal.length() <= 1e-18:
		return _failure("The corners lie on one line; spread them out.")
	var counts: PackedInt32Array = out.face_counts
	var idx: PackedInt32Array = out.face_indices
	counts.append(n)
	idx.append_array(face)
	out.face_counts = counts
	out.face_indices = idx
	# The symmetry maps cover the new vertices (as -1 until rebuilt).
	CAGE._extend_symmetry(out, CAGE.vertex_count(out))
	if not (out.symmetry as Array).is_empty():
		out = FORM_OPS.rebuild_symmetry(out).cage
	var problems := CAGE.validate(out)
	if not problems.is_empty():
		return _failure("That face would make the body non-manifold (%s)." % problems[0])
	var new_face := counts.size() - 1
	if bodies.is_empty():
		return {"ok": true, "new_bodies": [out], "info": {"panel": {"note": "A new body"}}}
	return {"ok": true, "cages": {bodies[0]: out}, "removed_bodies": bodies.slice(1),
		"selection": [{"kind": "face", "body": bodies[0], "index": new_face, "pair": Vector2i(-1, -1)}],
		"info": {"panel": {"note": "Joins %d bodies" % bodies.size() if bodies.size() > 1 else ""}}}


## Four corners reordered so the quad doesn't cross itself: of the two orders that keep the first
## two corners, the one enclosing more area (a crossed quad's halves cancel).
static func _untangle(corners: Array) -> Array:
	var swapped := [corners[0], corners[1], corners[3], corners[2]]
	return swapped if _area(swapped) > _area(corners) * (1.0 + 1e-9) else corners


## Twice the area of a polygon of corners (Newell's vector length).
static func _area(corners: Array) -> float:
	var n := Vector3.ZERO
	for k in corners.size():
		var a: Vector3 = corners[k].point
		var b: Vector3 = corners[(k + 1) % corners.size()].point
		n += a.cross(b)
	return n.length()


## Chain mode: the picked open edges extended, the new row moved to the offset point.
static func _face_chain(ctx: Dictionary, picks: Dictionary) -> Dictionary:
	var cages: Dictionary = ctx.get("cages", {})
	var chain: Dictionary = picks.get("chain", {})
	if chain.is_empty() or (chain.get("pairs", PackedInt32Array()) as PackedInt32Array).is_empty() or not cages.has(str(chain.get("body", ""))):
		return _failure("Click open boundary edges of a body, then click where the new row of faces goes.")
	if not picks.has("offset"):
		return _failure("Click where the new row of faces goes.")
	var cage: Dictionary = cages[chain.body]
	var pairs: PackedInt32Array = chain.pairs
	var r := FORM_OPS.extend_edges(cage, {"vertices": PackedInt32Array(), "edges": pairs, "faces": PackedInt32Array()}, {})
	if not bool(r.ok):
		return _failure(str(r.error))
	var out: Dictionary = r.cage
	var start := int(chain.get("start", pairs[0]))
	var delta: Vector3 = (picks.offset as Vector3) - CAGE.position(cage, start)
	# The chain's copies (exactly on the chain's vertices) move by the offset.
	var chain_verts := {}
	for v in pairs:
		chain_verts[v] = CAGE.position_d(cage, v)
	var p: PackedFloat64Array = out.positions
	var moved := PackedInt32Array()
	for w in (r.info.get("new_vertices", PackedInt32Array()) as PackedInt32Array):
		for v in chain_verts:
			var q: PackedFloat64Array = chain_verts[v]
			if p[3 * w] == q[0] and p[3 * w + 1] == q[1] and p[3 * w + 2] == q[2]:
				p[3 * w] += delta.x
				p[3 * w + 1] += delta.y
				p[3 * w + 2] += delta.z
				moved.append(w)
				break
	out.positions = p
	if not (out.symmetry as Array).is_empty() and not moved.is_empty():
		out = FORM_OPS.apply_symmetry(out, moved).cage
	var problems := CAGE.validate(out)
	if not problems.is_empty():
		return _failure("Those edges can't be extended (%s)." % problems[0])
	return {"ok": true, "cages": {str(chain.body): out}}


static func button_face(editor: Object, key: String) -> void:
	if key != "pick_plane":
		return
	editor.workspace.start_plane_pick(func(frame: Dictionary, _ref: String) -> void:
		if editor.tool != "face":
			return
		var x: Vector3 = (frame.get("x", Vector3.RIGHT) as Vector3).normalized()
		var y: Vector3 = (frame.get("y", Vector3.UP) as Vector3).normalized()
		editor.tool_state["face_plane"] = {"origin": frame.get("origin", Vector3.ZERO), "normal": x.cross(y).normalized()}
		editor.workspace.flash("Face: corners now go on the picked plane."),
		"Face: pick the plane new corners lie on.")


static func handle_mouse_face(editor: Object, event: InputEvent) -> bool:
	var button := event as InputEventMouseButton
	if button != null and button.button_index != MOUSE_BUTTON_LEFT:
		return false
	var mouse := event as InputEventMouse
	if mouse == null:
		return false
	var at := mouse.position
	var state: Dictionary = editor.tool_state
	var picks: Dictionary = editor.tool_picks
	var mode := str(editor.tool_values.get("mode", "simple"))
	if button == null:
		state["hover"] = _face_point(editor, at, false)
		return true
	if not button.pressed:
		return true
	match mode:
		"edge":
			if not picks.has("edge"):
				var edge := _boundary_edge(editor, at)
				if edge.is_empty():
					editor.workspace.flash("Face: click an open boundary edge of a body first.")
					return true
				picks["edge"] = edge
			else:
				var corners: Array = picks.get("corners", [])
				if corners.size() < 2:
					var p := _face_point(editor, at, true)
					if not p.is_empty():
						corners.append(p)
						picks["corners"] = corners
		"chain":
			var edge := _boundary_edge(editor, at)
			var chain: Dictionary = picks.get("chain", {})
			if not edge.is_empty() and (chain.is_empty() or str(chain.body) == str(edge.body)):
				var pairs: PackedInt32Array = chain.get("pairs", PackedInt32Array())
				var pair: Vector2i = edge.pair
				var found := -1
				for i in pairs.size() / 2:
					if pairs[2 * i] == mini(pair.x, pair.y) and pairs[2 * i + 1] == maxi(pair.x, pair.y):
						found = i
				if found >= 0:
					pairs.remove_at(2 * found)
					pairs.remove_at(2 * found)
				else:
					pairs.append(mini(pair.x, pair.y))
					pairs.append(maxi(pair.x, pair.y))
				if pairs.is_empty():
					picks.erase("chain")
				else:
					picks["chain"] = {"body": str(edge.body), "pairs": pairs, "start": int(chain.get("start", pair.x))}
				picks.erase("offset")
			elif not chain.is_empty():
				var p := _face_point(editor, at, true)
				if not p.is_empty():
					picks["offset"] = p.point
		_:
			var corners: Array = picks.get("corners", [])
			var four := str(editor.tool_values.get("sides", "four")) == "four"
			if (four and corners.size() >= 4) or bool(state.get("closed", false)):
				editor.workspace.flash("Face: press OK (or Enter) to add the face.")
				return true
			var p := _face_point(editor, at, true)
			if p.is_empty():
				return true
			if not four and corners.size() >= 3 and _same_corner(editor, p, corners[0]):
				state["closed"] = true
				editor.workspace.flash("Face: closed; press OK to add it.")
			else:
				corners.append(p)
				picks["corners"] = corners
	editor.update_tool()
	return true


## The corner under a screen position: a cage vertex within SNAP_PX, else the point on the active
## plane (fixed by the first click: the plane of the face under it, or XY). commit: remember the
## plane the first click chose.
static func _face_point(editor: Object, at: Vector2, commit: bool) -> Dictionary:
	var snapped := _snap_vertex(editor, at)
	var state: Dictionary = editor.tool_state
	var plane: Dictionary = state.get("face_plane", {})
	if plane.is_empty():
		plane = _plane_under(editor, at)
		if commit:
			state["face_plane"] = plane
	if not snapped.is_empty():
		return snapped
	var hit: Variant = editor.viewport.plane_hit(at, plane.origin, plane.normal)
	if hit == null:
		return {}
	return {"point": hit, "body": "", "vertex": -1}


## A stored cage vertex of the open form within SNAP_PX of a screen position ({} when none).
static func _snap_vertex(editor: Object, at: Vector2) -> Dictionary:
	var best := {}
	var best_px := SNAP_PX
	for body_id in editor.body_ids():
		var cage: Dictionary = editor.cage_of(str(body_id))
		if cage.is_empty() or not editor.workspace.doc.body_visible(str(body_id)):
			continue
		var smooth := str(editor.display_mode(str(body_id))) == "smooth"
		var limit: PackedVector3Array = (editor.tess_of(str(body_id)) as Dictionary).get("vertices", PackedVector3Array())
		for v in CAGE.vertex_count(cage):
			var p := limit[v] if smooth and v < limit.size() else CAGE.position(cage, v)
			var s: Vector2 = editor.viewport.project(p)
			if s.is_finite() and s.distance_to(at) < best_px:
				best_px = s.distance_to(at)
				best = {"point": CAGE.position(cage, v), "body": str(body_id), "vertex": v}
	return best


## The plane under a screen position: a cage face's (through the hit, along its normal), a flat
## model face's, else the XY origin plane.
static func _plane_under(editor: Object, at: Vector2) -> Dictionary:
	var face: Dictionary = editor._face_hit(at)
	if not face.is_empty():
		var cage: Dictionary = editor.cage_of(str(face.body))
		if not cage.is_empty():
			var n := CAGE.topology(cage).face_normal(cage, int(face.face))
			if n.length() > 0.5:
				return {"origin": face.point, "normal": n}
	var plane: Dictionary = editor.workspace.plane_at(at)
	if not plane.is_empty() and str(plane.ref).begins_with("face:"):
		var frame: Dictionary = plane.frame
		return {"origin": frame.origin, "normal": (frame.x as Vector3).cross(frame.y).normalized()}
	return {"origin": Vector3.ZERO, "normal": Vector3.BACK}


static func _same_corner(editor: Object, p: Dictionary, first: Dictionary) -> bool:
	if str(p.body) != "" and str(p.body) == str(first.body) and int(p.vertex) == int(first.vertex):
		return true
	var a: Vector2 = editor.viewport.project(p.point)
	var b: Vector2 = editor.viewport.project(first.point)
	return a.is_finite() and b.is_finite() and a.distance_to(b) <= SNAP_PX


## An open boundary cage edge under a screen position: {"body", "pair"} or {}.
static func _boundary_edge(editor: Object, at: Vector2) -> Dictionary:
	var pick: Dictionary = editor.pick_at(at, ["edge"])
	if pick.is_empty() or str(pick.get("kind", "")) != "edge":
		return {}
	var cage: Dictionary = editor.cage_of(str(pick.body))
	if cage.is_empty():
		return {}
	var pair: Vector2i = pick.pair
	var topo := CAGE.topology(cage)
	var e := topo.edge_index(pair.x, pair.y)
	if e < 0 or not topo.is_boundary_edge(e):
		return {}
	return {"body": str(pick.body), "pair": pair}


## The corners clicked so far, the edge or chain picked, and the line to the cursor.
static func draw_face(editor: Object, overlay: Control) -> void:
	var c: Dictionary = editor.theme_colors
	var color: Color = c.form_preview
	var picks: Dictionary = editor.tool_picks
	var state: Dictionary = editor.tool_state
	var pts := PackedVector2Array()
	var edge: Dictionary = picks.get("edge", {})
	if not edge.is_empty():
		var cage: Dictionary = editor.cage_of(str(edge.body))
		if not cage.is_empty():
			var pair: Vector2i = edge.pair
			var a: Vector2 = editor.viewport.project(CAGE.position(cage, pair.y))
			var b: Vector2 = editor.viewport.project(CAGE.position(cage, pair.x))
			if a.is_finite() and b.is_finite():
				overlay.draw_line(a, b, c.form_select_line, 3.0, true)
				pts.append(a)
				pts.append(b)
	var chain: Dictionary = picks.get("chain", {})
	if not chain.is_empty():
		var cage: Dictionary = editor.cage_of(str(chain.body))
		var pairs: PackedInt32Array = chain.pairs
		for i in pairs.size() / 2:
			var a: Vector2 = editor.viewport.project(CAGE.position(cage, pairs[2 * i]))
			var b: Vector2 = editor.viewport.project(CAGE.position(cage, pairs[2 * i + 1]))
			if a.is_finite() and b.is_finite():
				overlay.draw_line(a, b, c.form_select_line, 3.0, true)
		if picks.has("offset"):
			var from: Vector2 = editor.viewport.project(CAGE.position(cage, int(chain.get("start", pairs[0]))))
			var to: Vector2 = editor.viewport.project(picks.offset)
			if from.is_finite() and to.is_finite():
				overlay.draw_dashed_line(from, to, color, 2.0, 6.0)
				overlay.draw_circle(to, 4.0, color)
	for corner in picks.get("corners", []):
		var s: Vector2 = editor.viewport.project(corner.point)
		if s.is_finite():
			pts.append(s)
	var hover: Dictionary = state.get("hover", {})
	var lines := pts.duplicate()
	if not hover.is_empty() and str(editor.tool_values.get("mode", "simple")) != "chain":
		var s: Vector2 = editor.viewport.project(hover.point)
		if s.is_finite():
			lines.append(s)
			if str(hover.body) != "":
				overlay.draw_arc(s, 7.0, 0.0, TAU, 20, color, 1.5, true)
	for i in range(1, lines.size()):
		overlay.draw_dashed_line(lines[i - 1], lines[i], color, 2.0, 6.0)
	if lines.size() >= 3:
		overlay.draw_dashed_line(lines[lines.size() - 1], lines[0], Color(color, 0.5), 1.5, 4.0)
	for s in pts:
		overlay.draw_circle(s, 4.0, color)
