@tool
extends RefCounted
## Physical materials: the density (kg/m^3) mass properties use, and a display color.
##
## doc.physical_materials maps "body:<body id>" or "component:<component id>" to a name in TABLE.
## A body uses its own entry, else its component's, else the nearest parent component's, else
## DEFAULT. Bodies a feature split off or copied ("body3.f7.2") have entries of their own under
## their exact id; without one they fall back to the body they came from ("body3"), like
## doc.body_settings. Names that are not in TABLE are skipped.

const DEFAULT := "Steel"

const TABLE := {
	"Steel": {"density": 7850.0, "color": Color(0.62, 0.64, 0.67)},
	"Stainless Steel": {"density": 8000.0, "color": Color(0.74, 0.75, 0.77)},
	"Aluminum": {"density": 2700.0, "color": Color(0.8, 0.82, 0.85)},
	"Titanium": {"density": 4500.0, "color": Color(0.55, 0.55, 0.58)},
	"Copper": {"density": 8960.0, "color": Color(0.85, 0.5, 0.32)},
	"Brass": {"density": 8500.0, "color": Color(0.85, 0.7, 0.35)},
	"ABS Plastic": {"density": 1050.0, "color": Color(0.9, 0.9, 0.88)},
	"PLA": {"density": 1240.0, "color": Color(0.95, 0.95, 0.93)},
	"Nylon": {"density": 1150.0, "color": Color(0.93, 0.91, 0.85)},
	"Polycarbonate": {"density": 1200.0, "color": Color(0.82, 0.88, 0.92)},
	"Carbon Fiber": {"density": 1600.0, "color": Color(0.12, 0.12, 0.13)},
	"Oak": {"density": 750.0, "color": Color(0.7, 0.53, 0.33)},
	"Rubber": {"density": 1100.0, "color": Color(0.08, 0.08, 0.08)},
	"Glass": {"density": 2500.0, "color": Color(0.75, 0.88, 0.9)},
	"Concrete": {"density": 2400.0, "color": Color(0.6, 0.6, 0.58)},
	"Foam": {"density": 30.0, "color": Color(0.95, 0.85, 0.55)},
}


## Every material name, in table order.
static func names() -> PackedStringArray:
	return PackedStringArray(TABLE.keys())


static func is_known(name: String) -> bool:
	return TABLE.has(name)


## A material's density in kg/m^3 (the default material's for unknown names).
static func density(name: String) -> float:
	return float((TABLE.get(name, TABLE[DEFAULT]) as Dictionary).density)


static func color(name: String) -> Color:
	return (TABLE.get(name, TABLE[DEFAULT]) as Dictionary).color


## The material name a body uses: its own, its component chain's, or DEFAULT. assigned stands in
## for doc.physical_materials when given (a trial copy, to preview a change before making it).
static func material_for(doc: Resource, body_id: String, assigned: Variant = null) -> String:
	if doc == null:
		return DEFAULT
	if not assigned is Dictionary:
		assigned = doc.physical_materials
	var source := body_id.split(".")[0]
	for key in ["body:" + body_id, "body:" + source]:
		if is_known(str(assigned.get(key, ""))):
			return str(assigned[key])
	var component_id: String = doc.body_component(body_id)
	var guard := 0
	while component_id != "" and guard < 64:
		var name := str(assigned.get("component:" + component_id, ""))
		if is_known(name):
			return name
		component_id = str((doc.components.get(component_id, {}) as Dictionary).get("parent", ""))
		guard += 1
	return DEFAULT


static func density_for(doc: Resource, body_id: String) -> float:
	return density(material_for(doc, body_id))


## Gives keys ("body:<id>", "component:<id>") the material name in assigned (doc.physical_materials
## or a trial copy of it, changed in place). A component's material reaches all of its bodies: the
## materials of their own ("body:<id>", and split-off pieces' "body:<id>.<...>") are taken away,
## or they would still win over it.
static func assign(assigned: Dictionary, doc: Resource, keys: Array, name: String) -> void:
	var components := {}
	for key in keys:
		if str(key).begins_with("component:"):
			components[str(key).trim_prefix("component:")] = true
	if not components.is_empty() and doc != null:
		for key in assigned.keys():
			if str(key).begins_with("body:") and components.has(doc.body_component(str(key).trim_prefix("body:"))):
				assigned.erase(key)
	for key in keys:
		assigned[str(key)] = name
