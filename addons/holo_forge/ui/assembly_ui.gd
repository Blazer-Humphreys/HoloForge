@tool
extends RefCounted
## Panel rows of the Assemble tools (spec 3.3-3.10), as ui/command_panel.gd field dictionaries
## ({"key", "label", "type", "kind", "options", "default", "visible_if", ...}).
##
## Team V made the Stage 1 skeleton; team T owns it from Stage 2. The Assemble commands
## (tools/assemble_*.gd) put their panels together from these builders:
##   type_field()             the joint Type row (7 types, Revolute first by default); "icons" holds
##                            each type's pictogram file (spec 6.3)
##   snap_slot_field()        a selection slot whose hover shows snap candidates (C2.3); "snap": true
##                            tells the workspace to hand its picks to the command (take_pick())
##   offset_fields()          Offset X / Y / Z, Angle, Flip (3.3)
##   slide_axis_field()       Slide Axis for slider (X / Y / Z) and pin-slot (X / Y); for the other
##                            types it is left out (slide_axis_rows())
##   dof_rows()               the Motion rows: per DOF Value, Min (check + field), Max (check +
##                            field), Rest, each an angle or a length by the DOF (C1.2)
##   play_field(), name_field(), status_field()  Play Motion, Name and the status row
##   dof_values() / dofs_from() read the Motion rows back into a joint's "dofs" list and out of it.
## Expression defaults are in base units (meters, radians); text() writes one for a panel field.
## A field never carries "hidden": a row that a type does not have is not built (the panel is set
## up again when the type changes), and rows that come and go with a check use "visible_if".

const DATA := preload("res://addons/holo_forge/core/assembly/assembly_data.gd")
const UNITS := preload("res://addons/holo_forge/core/units.gd")

## The label of each joint type.
const TYPE_LABELS := {
	"rigid": "Rigid", "revolute": "Revolute", "slider": "Slider", "cylindrical": "Cylindrical",
	"pin_slot": "Pin-Slot", "planar": "Planar", "ball": "Ball",
}
## The label of each DOF name in the Motion rows.
const DOF_LABELS := {
	"rot_x": "Turn X", "rot_y": "Turn Y", "rot_z": "Turn Z", "slide": "Slide",
	"slide_x": "Slide X", "slide_y": "Slide Y", "slide_z": "Slide Z",
}
## The parts of a DOF's Motion row and the key suffix of each.
const DOF_PARTS := ["value", "limited_min", "min", "limited_max", "max", "rest"]
## The joint type pictograms (spec 6.3).
const ICON_DIR := "res://addons/holo_forge/icons/assemble/"
## The status row's key (refusals in red, notes in amber; tools/assemble_command.gd).
const STATUS_KEY := "status"


## The Type row: an enum of the 7 joint types; "icons" names each type's pictogram.
static func type_field(key := "type", default := DATA.DEFAULT_TYPE) -> Dictionary:
	var options := []
	var icons := []
	for type in DATA.TYPES:
		options.append([type, TYPE_LABELS.get(type, str(type).capitalize())])
		icons.append(ICON_DIR + "joint_%s.svg" % type)
	return {"key": key, "label": "Type", "type": "enum", "options": options, "default": default, "icons": icons}


## A snap slot: picks one face, edge, vertex or Joint Origin and shows its snap candidates while
## active (spec 3 conventions). label: "Component 1 (moves)" and so on.
static func snap_slot_field(key: String, label: String, filter := ["face", "edge", "vertex", "mesh_group"]) -> Dictionary:
	return {"key": key, "label": label, "type": "selection", "filter": filter, "single": true, "snap": true}


## Offset X / Y / Z (lengths along the base snap frame's axes), Angle (about its Z) and Flip.
static func offset_fields(prefix := "") -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for axis in ["x", "y", "z"]:
		out.append({"key": prefix + "offset_" + axis, "label": "Offset " + axis.to_upper(), "type": "expression", "kind": "length", "default": 0.0})
	out.append({"key": prefix + "angle", "label": "Angle", "type": "expression", "kind": "angle", "default": 0.0})
	out.append({"key": prefix + "flip", "label": "Flip", "type": "bool", "default": false})
	return out


## Slide Axis: X / Y / Z for a slider, X / Y for a pin-slot.
static func slide_axis_field(joint_type: String, key := "slide_axis") -> Dictionary:
	var axes := ["x", "y"] if joint_type == "pin_slot" else ["x", "y", "z"]
	var options := []
	for axis in axes:
		options.append([axis, axis.to_upper()])
	return {"key": key, "label": "Slide Axis", "type": "enum", "options": options, "default": DATA.DEFAULT_SLIDE_AXIS.get(joint_type, "z")}


## The Slide Axis row when the type has one, else none.
static func slide_axis_rows(joint_type: String, key := "slide_axis") -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if DATA.DEFAULT_SLIDE_AXIS.has(joint_type):
		out.append(slide_axis_field(joint_type, key))
	return out


## The Motion rows of a joint type: for each DOF a Value, a Min check and field, a Max check and
## field and a Rest, keyed "<prefix><i>_<part>" (DOF_PARTS). Rotations are angles, slides lengths.
## with_limits false gives only the Value rows (Drive Joints).
static func dof_rows(joint_type: String, prefix := "dof", with_limits := true) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var names := DATA.dof_names(joint_type)
	for i in names.size():
		var name := str(names[i])
		var kind := dof_kind(name)
		var label := str(DOF_LABELS.get(name, name))
		var key := "%s%d_" % [prefix, i]
		out.append({"key": key + "value", "label": label, "type": "expression", "kind": kind, "default": 0.0, "dof": i})
		if not with_limits:
			continue
		out.append({"key": key + "limited_min", "label": label + " Min", "type": "bool", "default": false, "dof": i})
		out.append({"key": key + "min", "label": "Min", "type": "expression", "kind": kind, "default": 0.0, "dof": i, "visible_if": {key + "limited_min": [true]}})
		out.append({"key": key + "limited_max", "label": label + " Max", "type": "bool", "default": false, "dof": i})
		out.append({"key": key + "max", "label": "Max", "type": "expression", "kind": kind, "default": 0.0, "dof": i, "visible_if": {key + "limited_max": [true]}})
		out.append({"key": key + "rest", "label": "Rest", "type": "expression", "kind": kind, "default": 0.0, "dof": i})
	return out


## "angle" for a rotation DOF name, "length" for a slide.
static func dof_kind(dof_name: String) -> String:
	return UNITS.KIND_ANGLE if DATA.is_rotation(dof_name) else UNITS.KIND_LENGTH


## Play Motion (C4.5, view-only).
static func play_field(key := "play") -> Dictionary:
	return {"key": key, "label": "Play Motion", "type": "button", "tooltip": "Shows the motion over its range in the view; nothing is stored."}


## The Name row.
static func name_field(key := "name") -> Dictionary:
	return {"key": key, "label": "Name", "type": "text"}


## The status row: refusals (red, OK off) and notes (amber).
static func status_field() -> Dictionary:
	return {"key": STATUS_KEY, "type": "info", "text": ""}


## A joint's "dofs" list from the Motion rows' values ({key: value in base units, or bool}).
static func dofs_from(values: Dictionary, joint_type: String, prefix := "dof") -> Array:
	var out := []
	for i in DATA.dof_names(joint_type).size():
		var dof := DATA.DOF_DEFAULT.duplicate()
		for part in DOF_PARTS:
			var key := "%s%d_%s" % [prefix, i, part]
			if values.has(key):
				dof[part] = bool(values[key]) if part.begins_with("limited_") else float(values[key])
		out.append(dof)
	return out


## The Motion rows' values ({key: value}) of a joint's "dofs" list (numbers in base units).
static func dof_values(dofs: Array, prefix := "dof") -> Dictionary:
	var out := {}
	for i in dofs.size():
		var dof: Dictionary = dofs[i] if dofs[i] is Dictionary else DATA.DOF_DEFAULT
		for part in DOF_PARTS:
			out["%s%d_%s" % [prefix, i, part]] = dof.get(part, DATA.DOF_DEFAULT[part])
	return out


## A value in base units as panel text in the document's units ("12.5 mm", "90 deg").
static func text(value: float, kind: String, document_units: String) -> String:
	if kind == UNITS.KIND_NUMBER:
		var shown := String.num(value, 6)
		return shown.rstrip("0").rstrip(".") if shown.contains(".") else shown
	return UNITS.format_value(value, kind, document_units, 6)


## Panel values for fields: each expression's base-unit "default" (or the number given in
## numbers by key) as text, other kinds as they are.
static func panel_values(fields: Array, numbers: Dictionary, document_units: String) -> Dictionary:
	var out := {}
	for field in fields:
		var key := str(field.get("key", ""))
		var given: Variant = numbers.get(key, field.get("default"))
		match str(field.get("type", "")):
			"expression":
				out[key] = text(float(given if given != null else 0.0), str(field.get("kind", "length")), document_units)
			"selection":
				out[key] = given if given is Array else []
			"info", "button":
				pass
			_:
				if given != null:
					out[key] = given
	return out
