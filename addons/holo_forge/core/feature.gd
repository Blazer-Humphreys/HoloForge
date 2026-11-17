@tool
extends Resource
## One step of a Holo Forge timeline (a sketch, an extrude, a box, ...).
##
## Numeric inputs are stored as expressions so they stay parametric; each one is also a model
## parameter (d1, d2, ...) that the Parameters dialog can edit. Everything else lives in options.

@export var id: String = ""
@export var type: String = ""
## The display name, e.g. "Box1".
@export var label: String = ""
@export var suppressed: bool = false
@export var group: String = ""
## key -> {"name": "d3", "expression": "20 mm", "kind": "length"}
@export var inputs: Dictionary = {}
## Non-numeric settings: operation, target bodies, position, created body id, ...
@export var options: Dictionary = {}


## A deep, independent copy (used for undo snapshots and command previews).
func copy() -> Resource:
	var other: Resource = get_script().new()
	other.id = id
	other.type = type
	other.label = label
	other.suppressed = suppressed
	other.group = group
	other.inputs = inputs.duplicate(true)
	other.options = options.duplicate(true)
	return other


func expression(key: String) -> String:
	return str((inputs.get(key, {}) as Dictionary).get("expression", ""))


func set_expression(key: String, value: String) -> void:
	if inputs.has(key):
		inputs[key]["expression"] = value
