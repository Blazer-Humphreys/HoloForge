@tool
extends Resource
## A Holo Forge design: units, parameters, the feature timeline and per-body settings.
##
## Geometry is never stored here; it is rebuilt by replaying the timeline (see regen.gd).
## Lengths in expressions default to `units`; values are evaluated into meters.

const FEATURE := preload("res://addons/holo_forge/core/feature.gd")
const ASSEMBLY_DATA := preload("res://addons/holo_forge/core/assembly/assembly_data.gd")
## What each kind of sketch dimension sizes, for its parameter's label.
const DIMENSION_NAMES := {
	"length": "Length", "distance": "Distance", "distance_x": "Horizontal Distance", "distance_y": "Vertical Distance",
	"radius": "Radius", "diameter": "Diameter", "angle": "Angle", "arc_length": "Arc Length",
}

@export_enum("mm", "cm", "m", "in", "ft") var units: String = "mm"
## User parameters: {"name", "unit", "expression", "comment", "favorite"}.
@export var user_parameters: Array[Dictionary] = []
@export var features: Array[Resource] = []
## How many features are active; later ones are rolled back. -1 means all of them.
@export var rollback: int = -1
## name -> {"target": Vector3, "yaw": float, "pitch": float, "distance": float, "ortho": bool}
@export var named_views: Dictionary = {}
## name -> Array of pick keys ("face:body2:3")
@export var selection_sets: Dictionary = {}
## body id -> {"name": String, "visible": bool, "locked": bool, "feature": String, "component": String}
@export var bodies: Dictionary = {}
## component id -> {"name": String, "visible": bool, "parent": String, "feature": String}.
## Components group bodies; each one bakes to its own Node3D. "" is the top level.
@export var components: Dictionary = {}
## New bodies go into this component ("" for the top level).
@export var active_component: String = ""
## Appearances: target -> {"material": a res:// Material path or "library:<texture set folder>",
## "mapping": {"type": "automatic" | "planar" | "box" | "cylindrical" | "spherical",
## "scale": Vector2 (meters per texture repeat), "offset": Vector2, "rotation": float (radians),
## "origin": Vector3, "axis": Vector3}}. Targets: "face:<body id>:<face name>",
## "body:<body id>", "component:<component id>"; a face's beats its body's beats its component's.
## The pieces of a face a later feature splits ("<name>#k") read the face's entry.
@export var appearances: Dictionary = {}
## Physical materials (density for mass properties): "body:<id>" | "component:<id>" -> a name
## from core/physical_materials.gd. Bodies without one use the default (Steel).
@export var physical_materials: Dictionary = {}
## Analyses shown in the view (Inspect): [{"id", "type", "name", "visible", "options": {}}].
@export var analyses: Array[Dictionary] = []
## Canvases (reference images on a plane): [{"id", "name", "image": res:// path, "origin",
## "x", "y" (plane axes), "size": Vector2 (meters), "opacity", "visible", "through": bool}].
@export var canvases: Array[Dictionary] = []
## Decals (images projected onto a body): [{"id", "name", "image": res:// path, "body",
## "face": face name, "position": Vector3, "normal": Vector3, "up": Vector3, "size": Vector2,
## "rotation": float, "visible"}]. Each bakes to a Godot Decal under its body, put back on its
## face as the body is now (appearance.gd placed_decal), so it follows the face through edits.
@export var decals: Array[Dictionary] = []
## Origin item -> visible.
@export var origin_visibility: Dictionary = {
	"origin": true, "x_axis": true, "y_axis": true, "z_axis": true,
	"xy_plane": false, "xz_plane": false, "yz_plane": false,
}
## Running counters for ids and labels ("feature", "body", "d", and one per feature type).
@export var counters: Dictionary = {}
## The assembly: component placements, grounding, joints, motion links, contact sets and motion
## studies (schema in core/assembly/assembly_data.gd; read it through its normalized()). Not a
## feature and not on the timeline: it is solved after the whole timeline has built
## (core/assembly/solver.gd). {} means no assembly. It holds no Resources.
@export var assembly: Dictionary = {}
## The assembly's doubles bit for bit, written with the scene (declared after assembly, so a load
## sets assembly first): a text scene reads some doubles back changed (a float32-exact one, a
## negative zero), so loading puts the exact ones back (ASSEMBLY_DATA.exact_text / apply_exact).
## Always worked out from assembly, never stale; not a design setting of its own.
@export_storage var assembly_exact: String:
	get:
		return ASSEMBLY_DATA.exact_text(assembly)
	set(value):
		ASSEMBLY_DATA.apply_exact(assembly, value)


func active_count() -> int:
	return features.size() if rollback < 0 else clampi(rollback, 0, features.size())


func next_number(counter: String) -> int:
	var n := int(counters.get(counter, 0)) + 1
	counters[counter] = n
	return n


## A numeric input that is also model parameter dN.
func make_input(expression: String, kind: String) -> Dictionary:
	return {"name": "d%d" % next_number("d"), "expression": expression, "kind": kind}


## Adds a feature at the timeline marker (the end unless the timeline is rolled back).
func add_feature(type: String, display_name: String, inputs: Dictionary, options: Dictionary) -> Resource:
	var feature: Resource = FEATURE.new()
	feature.id = "f%d" % next_number("feature")
	feature.type = type
	feature.label = "%s%d" % [display_name, next_number("type:" + type)]
	feature.inputs = inputs
	feature.options = options
	if rollback < 0 or rollback >= features.size():
		features.append(feature)
		rollback = -1
	else:
		features.insert(rollback, feature)
		rollback += 1
	return feature


## Registers a new body and returns its id; the creating feature keeps the id in its options.
func new_body(feature_id: String) -> String:
	var number := next_number("body")
	var body_id := "body%d" % number
	bodies[body_id] = {"name": "Body%d" % number, "visible": true, "locked": false, "feature": feature_id, "component": active_component}
	return body_id


## Registers a new component (inside the active one) and returns its id.
func new_component(feature_id := "") -> String:
	var number := next_number("component")
	var component_id := "comp%d" % number
	components[component_id] = {"name": "Component%d" % number, "visible": true, "parent": active_component, "feature": feature_id}
	return component_id


## A body's display name. Bodies a feature splits off or copies ("body3.f7.2") are named after
## the body they came from: "Body3 (2)"; a piece of such a piece ("body3.f5.2.f7.1") after that
## piece: "Body3 (2) (1)".
func body_name(body_id: String) -> String:
	if bodies.has(body_id):
		return str((bodies[body_id] as Dictionary).get("name", body_id))
	var parts := body_id.split(".")
	if parts.size() > 1 and bodies.has(parts[0]):
		var source := ".".join(parts.slice(0, parts.size() - 2)) if parts.size() > 3 else parts[0]
		return "%s (%s)" % [body_name(source), parts[parts.size() - 1]]
	return body_id


## A body's settings, falling back to the body it was split or copied from.
func body_settings(body_id: String) -> Dictionary:
	if bodies.has(body_id):
		return bodies[body_id]
	return bodies.get(body_id.split(".")[0], {})


func body_visible(body_id: String) -> bool:
	return bool(body_settings(body_id).get("visible", true)) and component_visible(body_component(body_id))


func body_component(body_id: String) -> String:
	return str(body_settings(body_id).get("component", ""))


func component_name(component_id: String) -> String:
	return str((components.get(component_id, {}) as Dictionary).get("name", component_id))


## False when the component or any component it sits in is hidden.
func component_visible(component_id: String) -> bool:
	var guard := 0
	while component_id != "" and guard < 64:
		var c: Dictionary = components.get(component_id, {})
		if not bool(c.get("visible", true)):
			return false
		component_id = str(c.get("parent", ""))
		guard += 1
	return true


func feature_index(feature_id: String) -> int:
	for i in features.size():
		if features[i].id == feature_id:
			return i
	return -1


func find_feature(feature_id: String) -> Resource:
	var i := feature_index(feature_id)
	return features[i] if i >= 0 else null


## Removes a feature and the bodies it created.
func remove_feature(feature_id: String) -> void:
	var i := feature_index(feature_id)
	if i < 0:
		return
	features.remove_at(i)
	if rollback > i:
		rollback -= 1
	for body_id in bodies.keys():
		if str(bodies[body_id].get("feature", "")) == feature_id:
			bodies.erase(body_id)
	for component_id in components.keys():
		if str(components[component_id].get("feature", "")) == feature_id:
			components.erase(component_id)
			if active_component == component_id:
				active_component = ""


## Every model parameter: [{"name", "expression", "kind", "feature", "key", "label"}]. A sketch
## dimension's label says what it sizes ("Sketch1 Length", "Sketch1 Diameter").
func model_parameters() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for feature in features:
		var sizes := {}
		if feature.type == "sketch":
			for c in feature.options.get("constraints", []):
				if c.has("key"):
					sizes[str(c.key)] = DIMENSION_NAMES.get(str(c.type), String(str(c.type)).capitalize())
		for key in feature.inputs:
			var input: Dictionary = feature.inputs[key]
			result.append({
				"name": str(input.get("name", "")), "expression": str(input.get("expression", "")),
				"kind": str(input.get("kind", "length")), "feature": feature.id, "key": key,
				"label": "%s %s" % [feature.label, sizes.get(str(key), String(key).capitalize())],
			})
	return result


## An independent copy of everything editable, for undo/redo and command previews.
func snapshot() -> Dictionary:
	var copies: Array[Resource] = []
	for feature in features:
		copies.append(feature.copy())
	var state := {
		"units": units, "user_parameters": user_parameters.duplicate(true), "features": copies,
		"rollback": rollback, "named_views": named_views.duplicate(true),
		"selection_sets": selection_sets.duplicate(true), "bodies": bodies.duplicate(true),
		"origin_visibility": origin_visibility.duplicate(true), "counters": counters.duplicate(true),
		"components": components.duplicate(true), "active_component": active_component,
		"appearances": appearances.duplicate(true), "physical_materials": physical_materials.duplicate(true),
		"analyses": analyses.duplicate(true), "canvases": canvases.duplicate(true), "decals": decals.duplicate(true),
	}
	# A document without an assembly keeps the snapshot it had before Phase 8 (restore() reads a
	# missing "assembly" as none).
	if not assembly.is_empty():
		state["assembly"] = assembly.duplicate(true)
	return state


func restore(state: Dictionary) -> void:
	units = state.units
	user_parameters.assign((state.user_parameters as Array).duplicate(true))
	features.clear()
	for feature in state.features:
		features.append(feature.copy())
	rollback = state.rollback
	named_views = (state.named_views as Dictionary).duplicate(true)
	selection_sets = (state.selection_sets as Dictionary).duplicate(true)
	bodies = (state.bodies as Dictionary).duplicate(true)
	origin_visibility = (state.origin_visibility as Dictionary).duplicate(true)
	counters = (state.counters as Dictionary).duplicate(true)
	components = (state.get("components", {}) as Dictionary).duplicate(true)
	active_component = str(state.get("active_component", ""))
	appearances = (state.get("appearances", {}) as Dictionary).duplicate(true)
	physical_materials = (state.get("physical_materials", {}) as Dictionary).duplicate(true)
	analyses.assign((state.get("analyses", []) as Array).duplicate(true))
	canvases.assign((state.get("canvases", []) as Array).duplicate(true))
	decals.assign((state.get("decals", []) as Array).duplicate(true))
	# (Snapshots and documents from before the assembly existed restore with none.)
	assembly = (state.get("assembly", {}) as Dictionary).duplicate(true)
	emit_changed()
