@tool
extends "res://addons/holo_forge/tools/command.gd"
## Base for Inspect commands, which add no timeline feature: Measure, Interference, Center of
## Mass, Physical Material and the analyses.
##
## The workspace sets `workspace` before defaults() and then calls:
##   update()        after the values change or the design rebuilds: refresh the panel's info rows
##                   and what the command shows in the view (from current_values)
##   draw(overlay)   while the view's overlay draws
##   on_button(key)  when a "button" field is pressed
##   drag_ended(handle) when a drag of one of its handles ends (the mouse button is let go)
##   accept_error()  before OK: "" lets it finish, anything else is shown and keeps it open
##   finish()        on OK, after the command has closed; document changes go through
##                   workspace.change(), so each is one undo step
##   end()           when the command closes either way: remove what it added to the view
## changes_document() true means the command edits the document while it runs (an analysis
## entry): OK records everything since it started as one undo step and Cancel puts it back.
## Value changes only refresh the view; they never rebuild the model, and neither does OK when
## only analyses, canvases or decals changed. The Sketch toolbar's commands (Measure, Curvature
## Comb, Canvas) run over an open sketch, which gets its tool back when they close.

const UNITS := preload("res://addons/holo_forge/core/units.gd")

## The Forge workspace (ui/forge_workspace.gd).
var workspace: Object
## The values the panel shows, kept here so finish() still has them after the command closes.
var current_values := {}


## Inspect commands add no feature; they only keep the starting values.
func create_feature(_doc: Resource, values: Dictionary) -> Resource:
	current_values = values.duplicate(true)
	return null


func write_values(_doc: Resource, values: Dictionary) -> void:
	current_values = values.duplicate(true)


func changes_document() -> bool:
	return false


## The undo step's name, for commands that change the document.
func action_name() -> String:
	return title()


func update() -> void:
	pass


func draw(_overlay: Control) -> void:
	pass


func on_button(_key: String) -> void:
	pass


func drag_ended(_handle: Dictionary) -> void:
	pass


func accept_error() -> String:
	return ""


func finish() -> void:
	pass


func end() -> void:
	pass


## An expression's value in base units ({"ok", "value", "error"}); parameters work by name.
func evaluate(text: String, kind: String) -> Dictionary:
	var known := {}
	var values: Dictionary = workspace.result.get("values", {})
	for name in values:
		if (values[name] as Dictionary).get("ok", false):
			known[name] = values[name]
	return UNITS.evaluate(text, kind, str(workspace.doc.units), known)


## An expression field's value, or fallback when it doesn't evaluate.
func number(values: Dictionary, key: String, kind: String, fallback: float) -> float:
	var r := evaluate(str(values.get(key, "")), kind)
	return float(r.value) if r.ok else fallback


## Every expression field's value (meters, radians), for handles.
func evaluated(values: Dictionary) -> Dictionary:
	var out := {}
	for field in fields():
		if field.type == "expression":
			var r := evaluate(str(values.get(field.key, "")), str(field.get("kind", "length")))
			if r.ok:
				out[field.key] = float(r.value)
	return out


## Panel hints: each expression field's value, or its error.
func hints_for(values: Dictionary) -> Dictionary:
	var out := {}
	for field in fields():
		if field.type != "expression":
			continue
		var kind := str(field.get("kind", "length"))
		var r := evaluate(str(values.get(field.key, "")), kind)
		if r.ok:
			out[field.key] = {"ok": true, "text": UNITS.format_value(float(r.value), kind, str(workspace.doc.units))}
		else:
			out[field.key] = {"ok": false, "text": str(r.get("error", ""))}
	return out


## The bodies of everything selected in the view (faces and edges count for their body).
func selection_bodies() -> Array:
	var ids := []
	if workspace == null:
		return ids
	for pick in workspace.selection:
		var body_id := str(pick.get("body", ""))
		if body_id != "" and not ids.has(body_id):
			ids.append(body_id)
	return ids


## Body ids from a body slot's values that still exist.
func bodies_in(values: Dictionary, key: String) -> Array:
	var bodies: Dictionary = workspace.result.get("bodies", {})
	return (values.get(key, []) as Array).filter(func(id: Variant) -> bool: return id is String and bodies.has(id))


func doc_units() -> String:
	return str(workspace.doc.units) if workspace != null and workspace.doc != null else "mm"


func length_text(value: float) -> String:
	return UNITS.format_value(value, UNITS.KIND_LENGTH, doc_units())


## An area or volume in the document's unit squared or cubed, four significant digits.
func power_text(value: float, power: int) -> String:
	var unit := doc_units()
	var shown := value / pow(float(UNITS.LENGTH_UNITS.get(unit, 1.0)), power)
	return "%s %s%s" % [significant(shown), unit, "²" if power == 2 else "³"]


## A point (meters) in the document's units: a Vector3, or a PackedFloat64Array of 3 (doubles, as
## the mass results' "center64": read without going through float32).
func point_text(p: Variant) -> String:
	var unit := doc_units()
	var scale := float(UNITS.LENGTH_UNITS.get(unit, 1.0))
	var xyz := [0.0, 0.0, 0.0]
	if p is Vector3:
		xyz = [(p as Vector3).x, (p as Vector3).y, (p as Vector3).z]
	elif p is PackedFloat64Array and (p as PackedFloat64Array).size() == 3:
		xyz = [p[0], p[1], p[2]]
	return "(%s, %s, %s) %s" % [significant(float(xyz[0]) / scale), significant(float(xyz[1]) / scale), significant(float(xyz[2]) / scale), unit]


## A number with about five significant digits and no trailing zeros (String % has no %g).
static func significant(value: float) -> String:
	if value == 0.0 or not is_finite(value):
		return "0" if value == 0.0 else str(value)
	var decimals := clampi(4 - int(floor(log(absf(value)) / log(10.0))), 0, 9)
	var text := String.num(value, decimals)
	if text.contains("."):
		text = text.rstrip("0").rstrip(".")
	return "0" if text == "-0" else text
