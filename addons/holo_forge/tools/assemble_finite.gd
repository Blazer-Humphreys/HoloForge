@tool
extends RefCounted
## Guards the Assemble tools' values against numbers that are not finite (NaN, INF). Typed text
## can't give one (core/units.gd refuses it), but a stored or hand-edited assembly can, and a call
## from code can: such a value gets a sentence about the value, never a solve that reads as a
## Holo Forge fault (S-SOLVE-FAULT).

const DATA := preload("res://addons/holo_forge/core/assembly/assembly_data.gd")

## A panel field holding a value that is not a finite number (only a stored one can).
const S_FIELD := "<Field> holds <value>, which is not a finite number. Type a number."
## A stored assembly entry with a number that is not finite.
const S_STORED := "<Item>'s <key> is <value> in the stored assembly, not a finite number. Edit or delete <Item>."
## A Motion Study key from code with a time or value that is not finite.
const S_KEY := "A key's <key> is <value>, not a finite number. Give it a number."
## The assembly lists the tools solve with (studies are the Motion Study panel's).
const SOLVED_LISTS := ["origins", "joints", "rigid_groups", "links", "contact_sets"]


## The first number in v that is not finite, as [key, value] (the key of the dictionary entry that
## holds it, else fallback_key); [] when every number is finite.
static func first_bad(v: Variant, fallback_key := "") -> Array:
	match typeof(v):
		TYPE_FLOAT:
			return [] if is_finite(float(v)) else [fallback_key, float(v)]
		TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_ARRAY:
			for item in v:
				var found := first_bad(item, fallback_key)
				if not found.is_empty():
					return found
		TYPE_DICTIONARY:
			for key in v:
				var found := first_bad(v[key], str(key))
				if not found.is_empty():
					return found
	return []


## S_STORED for the first stored entry the solve reads that holds a number that is not finite (""
## when there is none). skip_id: an entry being edited (its panel fields carry its values, and the
## user can type over them). studies: the ids of studies to check too. doc names components.
static func stored_sentence(assembly: Dictionary, doc: Resource, skip_id := "", studies: Array = []) -> String:
	var placements: Variant = assembly.get("placements", {})
	if placements is Dictionary:
		for component in placements:
			if skip_id != "" and str(component) == skip_id:
				continue
			var found := first_bad(placements[component], "placement")
			if not found.is_empty():
				var name := str(doc.component_name(str(component))) if doc != null and doc.has_method("component_name") else str(component)
				return _stored(name, "placement", found[1])
	var contact := first_bad(assembly.get("contact", {}), "contact")
	if not contact.is_empty():
		return _stored("Contact", str(contact[0]), contact[1])
	var lists: Array = SOLVED_LISTS.duplicate()
	lists.append("studies")
	for list in lists:
		for entry in assembly.get(list, []):
			if not (entry is Dictionary):
				continue
			var id := str(entry.get("id", ""))
			if id == skip_id or (list == "studies" and not studies.has(id)):
				continue
			var found := first_bad(entry, "value")
			if not found.is_empty():
				return _stored(str(entry.get("name", id)), str(found[0]), found[1])
	return ""


## S_FIELD for a field.
static func field_sentence(label: String, value: float) -> String:
	return DATA.fill(S_FIELD, {"Field": label, "value": _text(value)})


## S_KEY for a study key's key ("time" or "value").
static func key_sentence(key: String, value: float) -> String:
	return DATA.fill(S_KEY, {"key": key, "value": _text(value)})


static func _stored(item: String, key: String, value: float) -> String:
	return DATA.fill(S_STORED, {"Item": item, "key": key.replace("_", " "), "value": _text(value)})


static func _text(value: float) -> String:
	if is_nan(value):
		return "NaN"
	return "INF" if value > 0.0 else "-INF"
