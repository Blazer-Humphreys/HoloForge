@tool
extends "res://addons/holo_forge/tools/assemble_command.gd"
## Contact Settings (spec 3.9, from the browser's Contact Sets folder): the contact check's
## Tolerance (0 to 1 mm), Step (0.01 to 10 mm) and Precision (0.0001 mm to a tenth of the Step),
## stored in doc.assembly.contact on OK (undo "Contact Settings"). A value outside its range is
## refused in the status row with OK off.

const TOLERANCE_MAX := 1e-3
const STEP_MIN := 1e-5
const STEP_MAX := 1e-2
const PRECISION_MIN := 1e-7
## Rounding allowed at a range's ends (values are typed in the document's units).
const SLACK := 1e-12


func title() -> String:
	return "Contact Settings"


func action_name() -> String:
	return "Contact Settings"


func fields() -> Array[Dictionary]:
	return [
		{"key": "tolerance", "label": "Tolerance", "type": "expression", "kind": "length", "tooltip": "Bodies closer than this count as touching."},
		{"key": "step", "label": "Step", "type": "expression", "kind": "length", "tooltip": "How far a motion goes between two contact checks."},
		{"key": "precision", "label": "Precision", "type": "expression", "kind": "length", "tooltip": "How exactly a stop is found between two steps."},
		UI.status_field(),
	]


func defaults() -> Dictionary:
	var contact: Dictionary = _stored_assembly().contact
	return values_for({"tolerance": float(contact.tolerance), "step": float(contact.step), "precision": float(contact.precision)})


func check() -> void:
	var units := doc_units()
	var tolerance := value_of(current_values, "tolerance", "length", -1.0)
	var step := value_of(current_values, "step", "length", -1.0)
	var precision := value_of(current_values, "precision", "length", -1.0)
	var mm := func(v: float) -> String: return JOINT_MATH.format_length(v, units)
	if tolerance < -SLACK or tolerance > TOLERANCE_MAX + SLACK:
		refusal = "Tolerance must be between 0 and %s." % mm.call(TOLERANCE_MAX)
	elif step < STEP_MIN - SLACK or step > STEP_MAX + SLACK:
		refusal = "Step must be between %s and %s." % [mm.call(STEP_MIN), mm.call(STEP_MAX)]
	elif precision < PRECISION_MIN - SLACK or precision > step * 0.1 + SLACK:
		refusal = "Precision must be between %s and a tenth of the Step (%s)." % [mm.call(PRECISION_MIN), mm.call(step * 0.1)]


func apply_document(doc: Resource) -> void:
	var stored := _stored_assembly()
	stored.contact["tolerance"] = value_of(current_values, "tolerance", "length")
	stored.contact["step"] = value_of(current_values, "step", "length")
	stored.contact["precision"] = value_of(current_values, "precision", "length")
	doc.assembly = stored
