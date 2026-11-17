@tool
extends "res://addons/holo_forge/tools/inspect_command.gd"
## Analysis commands (Zebra, Draft, Curvature Map, Isocurve, Accessibility, Minimum Radius,
## Curvature Comb, Section, Environment Map, Component Colors, Center of Mass): a small panel for
## the options of one doc.analyses entry ({"id", "type", "name", "visible", "options"}). The entry
## is added when the command starts and shows in the view at once; OK keeps it as one undo step,
## Cancel takes it out again. Editing an entry from the browser opens the same panel.
##
## Directions are picked (a plane or flat face gives its normal, an axis, edge or round face its
## direction) with Flip to turn them round. options["panel"] keeps the panel's own values, so the
## entry opens again as it was typed; core/analysis.gd ignores it. Picks are kept as references
## (plane_ref, direction_ref, curves, edges) that every build finds again, so a section, draft or
## accessibility direction follows its plane, face or axis through model edits and undo; the
## workspace builds each entry from live_options(), so typed expressions follow their parameters.
## Comb scales ("scale", "comb_scale") are multiples of the automatic tooth size (1 = auto).

const ANALYSIS := preload("res://addons/holo_forge/core/analysis.gd")
const INSPECT := preload("res://addons/holo_forge/core/inspect.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")

const DIRECTION_KINDS := ["plane", "axis"]
const PLANE_COLOR := Color(0.95, 0.55, 0.15)

var type := "zebra"
## The doc.analyses entry this command edits.
var entry_id := ""


func _init(p_type := "analysis:zebra") -> void:
	type = p_type.trim_prefix("analysis:")


## A new doc.analyses entry (visible) with a fresh id and a numbered name ("Zebra1").
static func new_entry(doc: Resource, analysis_type: String, options: Dictionary) -> Dictionary:
	var label := str(ANALYSIS.LABELS.get(analysis_type, analysis_type.capitalize()))
	return {
		"id": "analysis%d" % doc.next_number("analysis"), "type": analysis_type,
		"name": "%s%d" % [label.replace(" ", ""), doc.next_number("analysis:" + analysis_type)],
		"visible": true, "options": options,
	}


func title() -> String:
	var label := str(ANALYSIS.LABELS.get(type, type.capitalize()))
	return label if type in ["environment_map", "component_colors", "center_of_mass"] else label + " Analysis"


func changes_document() -> bool:
	return true


func action_name() -> String:
	return ("Edit " if editing else "Create ") + title()


func fields() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	match type:
		"zebra":
			result.append({"key": "stripes", "label": "Stripes", "type": "expression", "kind": "number"})
			result.append({"key": "direction", "label": "Stripes Run", "type": "enum", "options": [["horizontal", "Horizontal"], ["vertical", "Vertical"]]})
		"draft":
			result.append({"key": "direction", "label": "Pull Direction", "type": "selection", "filter": DIRECTION_KINDS, "single": true})
			result.append({"key": "flip", "label": "Flip", "type": "bool"})
			result.append({"key": "angle", "label": "Draft Angle", "type": "expression", "kind": "angle"})
		"curvature_map":
			result.append({"key": "mode", "label": "Curvature", "type": "enum", "options": [
				["gaussian", "Gaussian"], ["mean", "Mean"], ["maximum", "Maximum"], ["minimum", "Minimum"]]})
		"minimum_radius":
			result.append({"key": "radius", "label": "Minimum Radius", "type": "expression", "kind": "length"})
		"accessibility":
			result.append({"key": "direction", "label": "Tool From", "type": "selection", "filter": DIRECTION_KINDS, "single": true})
			result.append({"key": "flip", "label": "Flip", "type": "bool"})
		"isocurve":
			result.append({"key": "u_count", "label": "U Curves", "type": "expression", "kind": "number"})
			result.append({"key": "v_count", "label": "V Curves", "type": "expression", "kind": "number"})
			result.append({"key": "planar", "label": "Flat Faces Too", "type": "bool"})
			result.append({"key": "comb", "label": "Curvature Combs", "type": "bool"})
			result.append({"key": "comb_density", "label": "Comb Density", "type": "expression", "kind": "number", "visible_if": {"comb": [true]}})
			result.append({"key": "comb_scale", "label": "Comb Scale (1 = auto)", "type": "expression", "kind": "number", "visible_if": {"comb": [true]}})
		"curvature_comb":
			result.append({"key": "curves", "label": "Curves", "type": "selection", "filter": ["sketch_curve", "edge", "body"]})
			result.append({"key": "density", "label": "Density", "type": "expression", "kind": "number"})
			result.append({"key": "scale", "label": "Scale (1 = auto)", "type": "expression", "kind": "number"})
		"section":
			result.append({"key": "plane", "label": "Plane", "type": "selection", "filter": ["plane"], "single": true})
			result.append({"key": "offset", "label": "Offset", "type": "expression", "kind": "length"})
			result.append({"key": "tilt", "label": "Tilt", "type": "expression", "kind": "angle"})
			result.append({"key": "spin", "label": "Spin", "type": "expression", "kind": "angle"})
			result.append({"key": "flip", "label": "Flip", "type": "bool"})
		"center_of_mass":
			result.append({"key": "bodies", "label": "Bodies", "type": "selection", "filter": "body"})
	result.append({"key": "result", "type": "info", "text": ""})
	return result


func defaults() -> Dictionary:
	match type:
		"zebra":
			return {"stripes": "12", "direction": "horizontal"}
		"draft":
			return {"direction": [], "flip": false, "angle": "3"}
		"curvature_map":
			return {"mode": "gaussian"}
		"minimum_radius":
			return {"radius": UNITS.format_value(0.001, UNITS.KIND_LENGTH, doc_units()).split(" ")[0]}
		"accessibility":
			return {"direction": [], "flip": false}
		"isocurve":
			return {"u_count": "5", "v_count": "5", "planar": false, "comb": false, "comb_density": "32", "comb_scale": "1"}
		"curvature_comb":
			return {"curves": [], "density": "32", "scale": "1"}
		"section":
			return {"plane": [], "offset": "0", "tilt": "0", "spin": "0", "flip": false}
		"center_of_mass":
			return {"bodies": selection_bodies()}
	return {}


func create_feature(doc: Resource, values: Dictionary) -> Resource:
	var created := new_entry(doc, type, {})
	entry_id = created.id
	doc.analyses.append(created)
	write_values(doc, values)
	return null


func read_values() -> Dictionary:
	var values := defaults()
	var options: Dictionary = entry().get("options", {})
	var stored: Dictionary = options.get("panel", {})
	if type == "center_of_mass" and not options.has("panel"):
		# An entry kept without panel values (made before they were stored): its own bodies, not
		# whatever is selected now.
		values["bodies"] = (options.get("body_ids", []) as Array).duplicate()
	for key in stored:
		var value: Variant = stored[key]
		values[key] = value.duplicate(true) if value is Array or value is Dictionary else value
	current_values = values.duplicate(true)
	return values


func write_values(_doc: Resource, values: Dictionary) -> void:
	current_values = values.duplicate(true)
	var target := entry()
	if not target.is_empty():
		target["options"] = options_for(values)


## The doc.analyses entry being edited ({} when it is gone).
func entry() -> Dictionary:
	for e in workspace.doc.analyses:
		if str(e.get("id", "")) == entry_id:
			return e
	return {}


## The analysis options (core/analysis.gd) for the panel's values.
func options_for(values: Dictionary) -> Dictionary:
	var o := {}
	match type:
		"zebra":
			o["stripes"] = maxf(roundf(number(values, "stripes", UNITS.KIND_NUMBER, 12.0)), 1.0)
			o["direction"] = str(values.get("direction", "horizontal"))
		"draft":
			o["pull"] = direction(values, Vector3.UP)
			o["flip"] = bool(values.get("flip", false))
			_keep_ref(o, values, "direction", "direction_ref")
			o["angle"] = absf(number(values, "angle", UNITS.KIND_ANGLE, deg_to_rad(3.0)))
		"curvature_map":
			o["mode"] = str(values.get("mode", "gaussian"))
		"minimum_radius":
			o["radius"] = absf(number(values, "radius", UNITS.KIND_LENGTH, 0.001))
		"accessibility":
			# The picked direction is where the tool comes from; the analysis wants tool -> part.
			o["direction"] = -direction(values, Vector3.UP)
			o["flip"] = bool(values.get("flip", false))
			_keep_ref(o, values, "direction", "direction_ref")
		"isocurve":
			o["u_count"] = clampi(roundi(number(values, "u_count", UNITS.KIND_NUMBER, 5.0)), 0, 50)
			o["v_count"] = clampi(roundi(number(values, "v_count", UNITS.KIND_NUMBER, 5.0)), 0, 50)
			o["planar"] = bool(values.get("planar", false))
			o["comb"] = bool(values.get("comb", false))
			o["comb_density"] = clampi(roundi(number(values, "comb_density", UNITS.KIND_NUMBER, 32.0)), 2, 400)
			o["comb_scale"] = scale_factor(values, "comb_scale")
		"curvature_comb":
			# Exactly the picked sketch curves are combed, each in its own sketch.
			var curves := []
			var edges := []
			for ref in values.get("curves", []):
				if not ref is Dictionary:
					continue
				if str(ref.get("kind", "")) == "sketch_curve":
					curves.append(ref.duplicate(true))
				else:
					edges.append(ref.duplicate(true))
			o["curves"] = curves
			if not curves.is_empty():
				# The first picked curve's sketch, for readers of entries made before curves were kept.
				o["sketch"] = str(curves[0].get("sketch", ""))
			o["edges"] = edges
			o["density"] = clampi(roundi(number(values, "density", UNITS.KIND_NUMBER, 32.0)), 2, 400)
			o["scale"] = scale_factor(values, "scale")
		"section":
			var frame := section_frame(values)
			var tilt := number(values, "tilt", UNITS.KIND_ANGLE, 0.0)
			var spin := number(values, "spin", UNITS.KIND_ANGLE, 0.0)
			var offset := number(values, "offset", UNITS.KIND_LENGTH, 0.0)
			# The plane turns about the base point, and Offset moves it along its turned normal.
			var turned := ANALYSIS.section_basis(frame.normal, frame.x, tilt, spin)
			o["normal"] = frame.normal
			o["x"] = frame.x
			o["tilt"] = tilt
			o["spin"] = spin
			o["offset"] = offset
			o["flip"] = bool(values.get("flip", false))
			# A picked plane is found again on every build, so the cut follows it; origin is where it
			# is now. Without one the build cuts through the shown model's middle (no origin kept).
			if _keep_ref(o, values, "plane", "plane_ref"):
				o["origin"] = (frame.base as Vector3) + turned.z * offset
		"center_of_mass":
			o["body_ids"] = (values.get("bodies", []) as Array).duplicate()
	o["panel"] = values.duplicate(true)
	return o


## The options to build the entry with now: options_for() its stored panel values, so typed
## expressions follow the parameters they use (the build itself finds picked references again).
## Entries without panel values keep their stored options.
func live_options(stored: Dictionary) -> Dictionary:
	var values: Dictionary = stored.get("panel", {})
	return options_for(values) if not values.is_empty() else stored


## Copies a single-pick slot's reference into the options under option_key (the build finds it
## again in every rebuild). Returns true when something is picked.
func _keep_ref(o: Dictionary, values: Dictionary, slot: String, option_key: String) -> bool:
	var refs: Array = values.get(slot, [])
	if refs.is_empty() or not refs[0] is Dictionary:
		return false
	o[option_key] = (refs[0] as Dictionary).duplicate(true)
	return true


## A comb scale field as a multiple of the automatic size (1 when it is 0, negative or not a
## number, as entries typed when 0 meant automatic).
func scale_factor(values: Dictionary, key: String) -> float:
	var factor := number(values, key, UNITS.KIND_NUMBER, 1.0)
	return factor if factor > 0.0 else 1.0


## A picked direction: a plane's normal or an axis' direction (default when nothing is picked
## or it can't be found), turned round by Flip.
func direction(values: Dictionary, fallback: Vector3) -> Vector3:
	var d := fallback
	var refs: Array = values.get("direction", [])
	if not refs.is_empty() and refs[0] is Dictionary:
		var ctx := INSPECT.context(workspace.result, workspace.doc, workspace.kernel)
		var plane := REFERENCES.plane(refs[0], ctx)
		if not plane.has("error"):
			d = (plane.normal as Vector3).normalized()
		else:
			var axis := REFERENCES.axis(refs[0], ctx)
			if not axis.has("error"):
				d = (axis.direction as Vector3).normalized()
	return -d if bool(values.get("flip", false)) else d


## The section plane before its offset and turn: {"base", "normal", "x" (its in-plane x axis, ZERO
## for ANALYSIS.section_basis' default)}; the model's middle across X when no plane is picked.
func section_frame(values: Dictionary) -> Dictionary:
	var refs: Array = values.get("plane", [])
	if not refs.is_empty() and refs[0] is Dictionary:
		var plane := REFERENCES.plane(refs[0], INSPECT.context(workspace.result, workspace.doc, workspace.kernel))
		if not plane.has("error"):
			return {"base": plane.origin, "normal": (plane.normal as Vector3).normalized(), "x": plane.get("x", Vector3.ZERO)}
	return {"base": _model_box().get_center(), "normal": Vector3.RIGHT, "x": Vector3.ZERO}


## The bounds of the bodies the view shows (the build's section default cuts through their middle).
func _model_box() -> AABB:
	var box := AABB()
	var first := true
	var bodies: Dictionary = workspace.result.get("bodies", {})
	for body_id in bodies:
		if not workspace.doc.body_visible(str(body_id)):
			continue
		var b: AABB = bodies[body_id].shape.bbox()
		box = b if first else box.merge(b)
		first = false
	return box


func update() -> void:
	workspace.panel.set_info("result", workspace.analysis_text(entry_id))


## Section: an arrow drags Offset along the turned normal; two angle handles on the plane's edge
## turn it, Tilt (the dot on its y axis, about its x axis) and Spin (the dot on its x axis, about
## its y axis as tilted).
func manipulators(values: Dictionary, evaluated: Dictionary) -> Array[Dictionary]:
	var handles: Array[Dictionary] = []
	if type != "section" or workspace == null:
		return handles
	var frame := section_frame(values)
	var offset := float(evaluated.get("offset", 0.0))
	var tilt := float(evaluated.get("tilt", 0.0))
	var spin := float(evaluated.get("spin", 0.0))
	var turned := ANALYSIS.section_basis(frame.normal, frame.x, tilt, spin)
	var tilted := ANALYSIS.section_basis(frame.normal, frame.x, tilt, 0.0)
	var unturned := ANALYSIS.section_basis(frame.normal, frame.x, 0.0, 0.0)
	var center: Vector3 = (frame.base as Vector3) + turned.z * offset
	var radius := maxf(_model_box().size.length() * 0.35, 0.005)
	handles.append({"type": "arrow", "key": "offset", "origin": center, "direction": turned.z, "factor": 1.0, "base": offset, "min": -INF})
	# Turning by tilt (or spin) rotates the whole plane about these axes, so a drag adds its angle.
	handles.append({"type": "angle", "key": "tilt", "origin": center, "axis": unturned.x, "start": tilted.y, "radius": radius, "base": tilt})
	handles.append({"type": "angle", "key": "spin", "origin": center, "axis": tilted.y, "start": turned.x, "radius": radius, "base": spin})
	return handles


## The section plane's outline while its panel is open: where the build cuts now (the picked plane
## found again, or the shown model's middle), moved and turned by the panel's values.
func draw(overlay: Control) -> void:
	if type != "section" or workspace == null:
		return
	var values: Dictionary = current_values
	var frame := section_frame(values)
	var turned := ANALYSIS.section_basis(frame.normal, frame.x, number(values, "tilt", UNITS.KIND_ANGLE, 0.0), number(values, "spin", UNITS.KIND_ANGLE, 0.0))
	var o: Vector3 = (frame.base as Vector3) + turned.z * number(values, "offset", UNITS.KIND_LENGTH, 0.0)
	var u := turned.x
	var v := turned.y
	var h := maxf(_model_box().size.length() * 0.6, 0.01)
	var corners := [o - u * h - v * h, o + u * h - v * h, o + u * h + v * h, o - u * h + v * h, o - u * h - v * h]
	var view: Control = workspace.viewport
	for i in range(1, corners.size()):
		var a: Vector2 = view.project(corners[i - 1])
		var b: Vector2 = view.project(corners[i])
		if a.is_finite() and b.is_finite():
			overlay.draw_dashed_line(a, b, PLANE_COLOR, 1.5, 6.0)
