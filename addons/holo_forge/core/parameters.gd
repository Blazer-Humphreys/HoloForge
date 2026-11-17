@tool
extends RefCounted
## Evaluates a document's user and model parameters into base units (meters, radians).
## Parameters may refer to each other in any order; cycles and unknown names become errors.

const UNITS := preload("res://addons/holo_forge/core/units.gd")


## Returns name -> {"ok", "value", "l", "a", "error"}.
static func evaluate(doc: Resource) -> Dictionary:
	var pending := {}
	for p in doc.user_parameters:
		pending[str(p.get("name", ""))] = {"expression": str(p.get("expression", "")), "kind": UNITS.unit_kind(str(p.get("unit", "")))}
	for p in doc.model_parameters():
		pending[p.name] = {"expression": p.expression, "kind": p.kind}

	var results := {}
	var known := {}
	var progress := true
	while progress and not pending.is_empty():
		progress = false
		for name in pending.keys():
			var entry: Dictionary = pending[name]
			var r := UNITS.evaluate(entry.expression, entry.kind, doc.units, known)
			# An unknown name may just not be evaluated yet; try again next pass.
			if not r.ok and str(r.error).begins_with("Unknown name"):
				results[name] = r
				continue
			results[name] = r
			if r.ok:
				known[name] = r
			pending.erase(name)
			progress = true
	for name in pending:
		var r: Dictionary = results.get(name, {})
		r["ok"] = false
		r["error"] = "%s (or a circular reference)" % r.get("error", "Unknown name")
		results[name] = r
	return results


## True when name can be used for a new user parameter.
static func is_valid_name(doc: Resource, name: String, ignore := "") -> bool:
	if not name.is_valid_identifier() or name in UNITS.FUNCTIONS or name in ["PI", "pi"]:
		return false
	if UNITS.LENGTH_UNITS.has(name) or UNITS.ANGLE_UNITS.has(name):
		return false
	for p in doc.user_parameters:
		if str(p.get("name", "")) == name and name != ignore:
			return false
	for p in doc.model_parameters():
		if p.name == name and name != ignore:
			return false
	return true
