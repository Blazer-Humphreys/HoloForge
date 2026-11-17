@tool
extends "res://addons/holo_forge/tools/assemble_command.gd"
## Place Component (spec 3.2, browser): moves a free component by Move X / Y / Z and turns it by
## Turn X / Y / Z about its box centre, in part axes, from where it shows now. The new placement
## (relative to its parent component, C1.2) is stored on OK (undo "Place <Comp>"); the model is
## not rebuilt. A grounded component is refused (S-PLACE-GROUNDED), and so is one a joint or a
## rigid group places (S-PLACE-JOINTED): its pose comes from them.

## The component placed.
var component_id := ""
## Its box centre where it shows now (part space).
var _center := Vector3.ZERO
var _center_known := false


func title() -> String:
	return "Place Component"


func action_name() -> String:
	return "Place %s" % comp_name(component_id)


func fields() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for axis in ["x", "y", "z"]:
		out.append({"key": "move_" + axis, "label": "Move " + axis.to_upper(), "type": "expression", "kind": "length", "default": 0.0})
	for axis in ["x", "y", "z"]:
		out.append({"key": "turn_" + axis, "label": "Turn " + axis.to_upper(), "type": "expression", "kind": "angle", "default": 0.0})
	out.append(UI.status_field())
	return out


func defaults() -> Dictionary:
	return values_for({})


## Why the component cannot be placed ("" when it can).
func place_refusal() -> String:
	var doc: Resource = workspace.doc
	if not doc.components.has(component_id):
		return "There is no such component."
	var stored := _stored_assembly()
	var unit := SOLVER.unit_of(doc.components, component_id)
	if DATA.is_grounded(stored, unit):
		return DATA.fill(DATA.S_PLACE_GROUNDED, {"Comp": comp_name(unit)})
	var by := str((workspace.assembly_solve.get("units", {}) as Dictionary).get(unit, {}).get("reached_by", ""))
	if by != "":
		var held := entry_of(stored, "joints", by)
		if held.is_empty():
			held = entry_of(stored, "rigid_groups", by)
		return DATA.fill(DATA.S_PLACE_JOINTED, {"Comp": comp_name(unit), "Joint": str(held.get("name", by))})
	return ""


func check() -> void:
	refusal = place_refusal()
	if refusal != "":
		return
	if not _center_known:
		# (Once, from where it shows when the tool opens: the preview moves it after that.)
		_center = _component_box().get_center()
		_center_known = true
	var candidate := build(current_values)
	show_solve(solve_with(candidate), candidate)


## The box around the component's own bodies (nested ones too) where they show now.
func _component_box() -> AABB:
	var doc: Resource = workspace.doc
	var box := AABB()
	var first := true
	for body in workspace.viewport.pickable_bodies():
		var body_id := str(body.id)
		var component: String = doc.body_component(body_id)
		var inside := false
		var guard := 0
		while component != "" and guard < 64:
			if component == component_id:
				inside = true
				break
			component = SOLVER.parent_of(doc.components, component)
			guard += 1
		if not inside:
			continue
		var shown: AABB = workspace.viewport.body_pose(body_id) * (body.aabb as AABB)
		box = shown if first else box.merge(shown)
		first = false
	return box


## The move as an xform64: T(move) · (turns about the box centre, X then Y then Z).
func delta(values: Dictionary) -> PackedFloat64Array:
	var move := XFORM.translation(value_of(values, "move_x", "length"), value_of(values, "move_y", "length"), value_of(values, "move_z", "length"))
	var tx := value_of(values, "turn_x", "angle")
	var ty := value_of(values, "turn_y", "angle")
	var tz := value_of(values, "turn_z", "angle")
	if tx == 0.0 and ty == 0.0 and tz == 0.0:
		return move
	var turn := XFORM.compose(XFORM.rot_x(tx), XFORM.compose(XFORM.rot_y(ty), XFORM.rot_z(tz)))
	var about := XFORM.compose(XFORM.translation(_center.x, _center.y, _center.z), XFORM.compose(turn, XFORM.translation(-_center.x, -_center.y, -_center.z)))
	return XFORM.compose(move, about)


## The assembly with the component's new placement: P_parent⁻¹ · Δ · P_now.
func build(values: Dictionary) -> Dictionary:
	var stored := _stored_assembly()
	var parent := SOLVER.parent_of(workspace.doc.components, component_id)
	var now := pose_of("", component_id)
	var moved := XFORM.compose(delta(values), now)
	var placement := XFORM.compose(XFORM.inverse(pose_of("", parent)), moved) if parent != "" else moved
	stored.placements[component_id] = placement
	return DATA.normalized(stored)


func apply_document(doc: Resource) -> void:
	if place_refusal() == "":
		doc.assembly = build(current_values)


## Move arrows along X, Y and Z and turn handles about them, at the box centre where the preview
## shows it.
func manipulators(values: Dictionary, _evaluated: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if refusal != "":
		return out
	var at := _center + Vector3(value_of(values, "move_x", "length"), value_of(values, "move_y", "length"), value_of(values, "move_z", "length"))
	var size := maxf(_component_box().size.length() * 0.35, 0.005)
	var axes := {"x": Vector3.RIGHT, "y": Vector3.UP, "z": Vector3.BACK}
	var starts := {"x": Vector3.UP, "y": Vector3.BACK, "z": Vector3.RIGHT}
	for axis in ["x", "y", "z"]:
		out.append({"type": "arrow", "key": "move_" + axis, "origin": at, "direction": axes[axis], "factor": 1.0, "base": value_of(values, "move_" + axis, "length"), "min": -1e9})
		out.append({"type": "angle", "key": "turn_" + axis, "origin": at, "axis": axes[axis], "start": starts[axis], "radius": size, "base": value_of(values, "turn_" + axis, "angle")})
	return out
