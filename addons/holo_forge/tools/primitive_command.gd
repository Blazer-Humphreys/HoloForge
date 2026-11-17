@tool
extends "res://addons/holo_forge/tools/command.gd"
## Box, Cylinder and Sphere: sizes, a position on the ground plane, and an operation.
## Handles: arrows drag the sizes, a point handle moves the primitive. The position keeps an exact
## copy in doubles (core/point64.gd) when float32 would round it.

const POINT64 := preload("res://addons/holo_forge/core/point64.gd")

const SIZE_KEYS := {
	"box": ["length", "width", "height"],
	"cylinder": ["diameter", "height"],
	"sphere": ["diameter"],
}
const DISPLAY := {"box": "Box", "cylinder": "Cylinder", "sphere": "Sphere"}

var type := "box"


func _init(p_type := "box") -> void:
	type = p_type


func title() -> String:
	return DISPLAY.get(type, "Primitive")


func fields() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for key in SIZE_KEYS[type]:
		result.append({"key": key, "label": String(key).capitalize(), "type": "expression", "kind": "length"})
	result.append({"key": "position", "label": "Center" if type == "sphere" else "Base Center", "type": "point"})
	result.append_array(operation_fields())
	return result


func defaults() -> Dictionary:
	var size := str(hints.get("default_size", "50"))
	var values := {"position": hints.get("position", Vector3.ZERO), "operation": OPERATIONS.NEW_BODY, "targets": []}
	for key in SIZE_KEYS[type]:
		values[key] = size
	if type == "sphere":
		# A sphere sits on the ground by default: its center is lifted by its radius.
		values.position = (values.position as Vector3) + Vector3.UP * float(hints.get("default_size_m", 0.05)) * 0.5
	return values


func create_feature(doc: Resource, values: Dictionary) -> Resource:
	var inputs := {}
	for key in SIZE_KEYS[type]:
		inputs[key] = doc.make_input(str(values[key]), "length")
	feature = doc.add_feature(type, DISPLAY[type], inputs, {
		"position": values.position, "operation": values.operation, "targets": (values.targets as Array).duplicate(),
	})
	POINT64.store(feature.options, "position", values)
	sync_body(doc, feature)
	return feature


func read_values() -> Dictionary:
	var values := {
		"position": feature.options.get("position", Vector3.ZERO),
		"operation": feature.options.get("operation", OPERATIONS.NEW_BODY),
		"targets": (feature.options.get("targets", []) as Array).duplicate(),
	}
	POINT64.read(values, "position", feature.options)
	for key in SIZE_KEYS[type]:
		values[key] = feature.expression(key)
	return values


func write_values(doc: Resource, values: Dictionary) -> void:
	for key in SIZE_KEYS[type]:
		feature.set_expression(key, str(values[key]))
	POINT64.store(feature.options, "position", values)
	feature.options["operation"] = values.operation
	feature.options["targets"] = (values.targets as Array).duplicate()
	sync_body(doc, feature)


func manipulators(values: Dictionary, evaluated: Dictionary) -> Array[Dictionary]:
	var p: Vector3 = values.position
	var handles: Array[Dictionary] = []
	match type:
		"box":
			var length := float(evaluated.get("length", 0.0))
			var width := float(evaluated.get("width", 0.0))
			var height := float(evaluated.get("height", 0.0))
			handles.append({"type": "arrow", "key": "height", "origin": p + Vector3(0, height, 0), "direction": Vector3.UP, "factor": 1.0, "base": height})
			handles.append({"type": "arrow", "key": "length", "origin": p + Vector3(length * 0.5, height * 0.5, 0), "direction": Vector3.RIGHT, "factor": 2.0, "base": length})
			handles.append({"type": "arrow", "key": "width", "origin": p + Vector3(0, height * 0.5, width * 0.5), "direction": Vector3.BACK, "factor": 2.0, "base": width})
		"cylinder":
			var diameter := float(evaluated.get("diameter", 0.0))
			var height := float(evaluated.get("height", 0.0))
			handles.append({"type": "arrow", "key": "height", "origin": p + Vector3(0, height, 0), "direction": Vector3.UP, "factor": 1.0, "base": height})
			handles.append({"type": "arrow", "key": "diameter", "origin": p + Vector3(diameter * 0.5, height * 0.5, 0), "direction": Vector3.RIGHT, "factor": 2.0, "base": diameter})
		"sphere":
			var diameter := float(evaluated.get("diameter", 0.0))
			handles.append({"type": "arrow", "key": "diameter", "origin": p + Vector3(diameter * 0.5, 0, 0), "direction": Vector3.RIGHT, "factor": 2.0, "base": diameter})
	handles.append({"type": "point", "key": "position", "position": p, "normal": Vector3.UP})
	return handles
