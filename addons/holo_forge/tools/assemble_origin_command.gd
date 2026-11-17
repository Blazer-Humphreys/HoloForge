@tool
extends "res://addons/holo_forge/tools/assemble_command.gd"
## Joint Origin (spec 3.5): a named frame on a component that joints can snap to later (C2.6).
##
## One snap pick (Position), then Offset X / Y / Z, Angle and Flip about the snap frame. The
## origin belongs to the component of the picked body (the ground for a body in none) and moves
## with it. The preview draws its triad; OK adds it to doc.assembly.origins (undo "Joint Origin").


func title() -> String:
	return "Joint Origin"


func action_name() -> String:
	return "Joint Origin"


func fields() -> Array[Dictionary]:
	var out: Array[Dictionary] = [UI.snap_slot_field("snap", "Position")]
	out.append_array(UI.offset_fields())
	out.append(UI.name_field())
	out.append(UI.status_field())
	return out


func defaults() -> Dictionary:
	var id := DATA.new_id(_stored_assembly(), "origin")
	return values_for({"name": DATA.name_for("origin", id)})


func check() -> void:
	var picked := first_item(current_values, "snap")
	if picked.is_empty():
		prompt = "Pick a face, an edge or a vertex for the origin."
		return
	if str((picked.snap as Dictionary).get("kind", "")) == "origin":
		refusal = "Pick geometry for a new origin, not another origin."
		return
	var candidate := build(current_values)
	show_solve(solve_with(candidate), candidate)


## The assembly with the new origin, normalized.
func build(values: Dictionary) -> Dictionary:
	var stored := _stored_assembly()
	var picked := first_item(values, "snap")
	var id := DATA.new_id(stored, "origin")
	var origin := DATA.ORIGIN_DEFAULT.duplicate(true)
	origin["id"] = id
	var name := str(values.get("name", "")).strip_edges()
	origin["name"] = name if name != "" else DATA.name_for("origin", id)
	origin["component"] = str(picked.get("component", ""))
	origin["snap"] = (picked.get("snap", {}) as Dictionary).duplicate(true)
	origin["offset"] = [value_of(values, "offset_x", "length"), value_of(values, "offset_y", "length"), value_of(values, "offset_z", "length")]
	origin["angle"] = value_of(values, "angle", "angle")
	origin["flip"] = bool(values.get("flip", false))
	(stored.origins as Array).append(origin)
	return DATA.normalized(stored)


func apply_document(doc: Resource) -> void:
	doc.assembly = build(current_values)
