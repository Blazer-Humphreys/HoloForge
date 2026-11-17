@tool
extends "res://addons/holo_forge/tools/assemble_command.gd"
## Rigid Group (spec 3.6): two or more components that move as one, held where they are now.
##
## Picks are bodies (in the view or the browser); each counts for its top-level component, once.
## The group stores each member's pose relative to the first one (relative = P_first⁻¹ · P_member,
## at the stored poses), so making it moves nothing. Fewer than two components is refused
## (S-GROUP-SMALL); so is a body of the ground (no component), which is fixed already.

const S_GROUND_MEMBER := "The ground's bodies are fixed already and cannot join a rigid group; ground the components instead."


func title() -> String:
	return "Rigid Group"


func action_name() -> String:
	return "Rigid Group"


func fields() -> Array[Dictionary]:
	return [
		{"key": "components", "label": "Components", "type": "selection", "filter": "body"},
		UI.name_field(),
		UI.status_field(),
	]


func defaults() -> Dictionary:
	var id := DATA.new_id(_stored_assembly(), "group")
	return values_for({"name": DATA.name_for("group", id)})


## The top-level components of the picked bodies, in pick order, each once; "" for a ground body.
func units(values: Dictionary) -> Array:
	var doc: Resource = workspace.doc
	var out := []
	for body in values.get("components", []):
		var unit := SOLVER.unit_of(doc.components, doc.body_component(str(body)))
		if not out.has(unit):
			out.append(unit)
	return out


func check() -> void:
	var members := units(current_values)
	if members.has(""):
		refusal = S_GROUND_MEMBER
		return
	if members.size() < 2:
		if members.is_empty():
			prompt = DATA.S_GROUP_SMALL
		else:
			refusal = DATA.S_GROUP_SMALL
		return
	var candidate := build(current_values)
	show_solve(solve_with(candidate), candidate)


func build(values: Dictionary) -> Dictionary:
	var stored := _stored_assembly()
	var members := units(values)
	var id := DATA.new_id(stored, "group")
	var group := DATA.GROUP_DEFAULT.duplicate(true)
	group["id"] = id
	var name := str(values.get("name", "")).strip_edges()
	group["name"] = name if name != "" else DATA.name_for("group", id)
	group["components"] = members
	var first := pose_of("", str(members[0]))
	var relative := {}
	for i in range(1, members.size()):
		relative[members[i]] = XFORM.compose(XFORM.inverse(first), pose_of("", str(members[i])))
	group["relative"] = relative
	(stored.rigid_groups as Array).append(group)
	return DATA.normalized(stored)


func apply_document(doc: Resource) -> void:
	doc.assembly = build(current_values)
