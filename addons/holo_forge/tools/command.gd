@tool
extends RefCounted
## Base for an interactive feature command (Box, Extrude, ...).
##
## The workspace shows fields() in the command panel and keeps the command's feature in the
## document while the command runs, so every change previews through a real rebuild. OK keeps
## it as one undo step; Cancel restores the document as it was.
##
## Field: {"key", "label", "type": "expression"|"enum"|"selection"|"point"|"bool"|"text"|"info"|"button",
##         "kind" (expression: length|angle|number), "options" ([[value, label]]),
##         "filter" (selection: body|face|edge|vertex), "visible_if" ({key: [values]})}
## "info" rows show read-only text (set with the panel's set_info); "button" rows emit the
## panel's button_pressed. Inspect commands (tools/inspect_command.gd) make no feature.

const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")

## The feature this command creates or edits.
var feature: Resource
## True when the command edits an existing feature from the timeline.
var editing := false
## Workspace hints such as {"default_size": "50", "position": Vector3, "units": "mm"}.
var hints := {}
## The latest rebuild (set by the workspace), for handles that follow picked geometry.
var result := {}


func title() -> String:
	return "Command"


func fields() -> Array[Dictionary]:
	return []


## Starting values for a new feature.
func defaults() -> Dictionary:
	return {}


## Adds a new feature to doc from values and returns it.
func create_feature(_doc: Resource, _values: Dictionary) -> Resource:
	return null


## Current values read back from the feature (editing, or after manipulator drags).
func read_values() -> Dictionary:
	return {}


## Writes values into the feature.
func write_values(_doc: Resource, _values: Dictionary) -> void:
	pass


## On-canvas handles for the current values.
## {"type": "arrow", "key", "origin", "direction", "factor", "base", "min"?} drags a length field
## (never below "min", default a hair above 0);
## {"type": "point", "key", "position", "normal"} drags a point on a plane;
## {"type": "angle", "key", "origin", "axis", "start", "radius", "base"} drags an angle field.
## evaluated holds each expression field's value in meters/radians.
func manipulators(_values: Dictionary, _evaluated: Dictionary) -> Array[Dictionary]:
	return []


## The operation and target-body fields shared by Create features (ops: the operations offered;
## all of them when empty; visible_if: when they show at all).
static func operation_fields(ops: Array = [], visible_if: Dictionary = {}) -> Array[Dictionary]:
	var options := []
	for op in (ops if not ops.is_empty() else OPERATIONS.ALL):
		options.append([op, OPERATIONS.LABELS[op]])
	var targets_if := {"operation": [OPERATIONS.JOIN, OPERATIONS.CUT, OPERATIONS.INTERSECT]}
	targets_if.merge(visible_if)
	return [
		{"key": "operation", "label": "Operation", "type": "enum", "options": options, "visible_if": visible_if},
		{"key": "targets", "label": "Bodies", "type": "selection", "filter": "body", "visible_if": targets_if},
	]


## Keeps the feature's body (and component) in step with its operation: New Body owns a body,
## New Component a body in a component of its own, other operations change existing bodies.
## Features without an operation (none, or one their command hides) own nothing, and give up
## what they owned.
static func sync_body(doc: Resource, owner_feature: Resource) -> void:
	var op := str(owner_feature.options.get("operation", ""))
	var body_id := str(owner_feature.options.get("body_id", ""))
	var creates := OPERATIONS.reserves_body(op)
	if creates and body_id == "":
		body_id = doc.new_body(owner_feature.id)
		owner_feature.options["body_id"] = body_id
	elif not creates and body_id != "" and str((doc.bodies.get(body_id, {}) as Dictionary).get("feature", "")) == owner_feature.id:
		doc.bodies.erase(body_id)
		owner_feature.options["body_id"] = ""
		body_id = ""
	var component_id := str(owner_feature.options.get("component_id", ""))
	if op == OPERATIONS.NEW_COMPONENT and component_id == "":
		component_id = doc.new_component(owner_feature.id)
		owner_feature.options["component_id"] = component_id
		if doc.bodies.has(body_id):
			doc.bodies[body_id]["component"] = component_id
	elif op != OPERATIONS.NEW_COMPONENT and component_id != "" and str((doc.components.get(component_id, {}) as Dictionary).get("feature", "")) == owner_feature.id:
		doc.components.erase(component_id)
		owner_feature.options["component_id"] = ""
		if doc.bodies.has(body_id):
			doc.bodies[body_id]["component"] = doc.active_component
