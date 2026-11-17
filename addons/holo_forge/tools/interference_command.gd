@tool
extends "res://addons/holo_forge/tools/inspect_command.gd"
## Interference: where bodies overlap (every pair of the picked bodies, or of all bodies when
## none are picked; surface bodies hold no volume, and the result says they weren't checked).
## Lists each clash with its volume, shows the overlaps in red through the
## bodies, and Create Bodies adds them as new bodies (a base feature, one undo step); Create
## Components does the same with each overlap body in a new component of its own
## ("Interference 1", ...).
##
## Mesh bodies are checked too: two closed mesh bodies by their mesh intersection, a mesh body
## against a solid by tessellating the solid first (the readout says so; such a volume is
## approximate). An overlap with a mesh body in it is a mesh, so Create Bodies and Create
## Components leave it out and say how to make it (Mesh > Modify > Combine, Intersect).

const INSPECT := preload("res://addons/holo_forge/core/inspect.gd")
const TESSELLATE := preload("res://addons/holo_forge/core/tessellate.gd")
const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")

const CLASH_COLOR := Color(0.95, 0.12, 0.1, 0.65)

## The clashes found: [{"a", "b", "volume", "shape"}] (pairs the kernel failed on are left out).
var clashes := []
## Pairs the kernel could not intersect: [{"a", "b", "error"}].
var failures := []
## Pairs with no overlap found that come so near each other that a thin one would not be seen
## ("unseen": true, with a "note" that says how near): [{"a", "b", "note"}]. Not interferences.
var unseen := []

var _checked_result: Dictionary
var _checked_ids := []
## The body poses the last check used ({} unposed).
var _checked_poses := {}
var _material: StandardMaterial3D


func _init(_type := "") -> void:
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.no_depth_test = true
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.albedo_color = CLASH_COLOR
	_material.render_priority = 2


func title() -> String:
	return "Interference"


func fields() -> Array[Dictionary]:
	return [
		{"key": "bodies", "label": "Bodies", "type": "selection", "filter": "body"},
		{"key": "result", "type": "info", "text": ""},
		{"key": "create", "label": "Create Bodies", "type": "button", "tooltip": "Add each overlap as a new body"},
		{"key": "create_components", "label": "Create Components", "type": "button", "tooltip": "Add each overlap as a body in a new component of its own"},
	]


func defaults() -> Dictionary:
	return {"bodies": selection_bodies() if selection_bodies().size() > 1 else []}


func update() -> void:
	var ids := checked_bodies()
	# The bodies where the assembly places them while the view is posed (spec 3.12, C7.4).
	var poses: Dictionary = workspace.inspect_poses() if workspace.has_method("inspect_poses") else {}
	# Checking every pair is costly; do it again only when the bodies, their poses or the design changed.
	if not (is_same(_checked_result, workspace.result) and ids == _checked_ids and poses == _checked_poses):
		_checked_result = workspace.result
		_checked_ids = ids
		_checked_poses = poses.duplicate()
		take(INSPECT.interference(workspace.kernel, workspace.result.get("bodies", {}), ids, workspace.doc, INSPECT.INTERFERENCE_SECONDS, poses))
		var meshes := []
		for clash in clashes:
			# (A pair reported without its overlap, as one not worked out in time, draws nothing.)
			if clash.get("shape") != null:
				meshes.append({"mesh": TESSELLATE.surface_mesh(TESSELLATE.tessellate(clash.shape)), "material": _material})
		workspace.viewport.set_command_meshes(meshes)
	workspace.panel.set_info("result", describe())


## Sorts what INSPECT.interference() found: pairs that could not be worked out (failures), pairs
## that nearly touch with no overlap found (unseen), and the overlaps (clashes).
func take(found_pairs: Array) -> void:
	clashes.clear()
	failures.clear()
	unseen.clear()
	for found in found_pairs:
		if found.has("error"):
			failures.append(found)
		elif bool(found.get("unseen", false)):
			unseen.append(found)
		else:
			clashes.append(found)


## The picked bodies, or [] (every body) when fewer than two are picked.
func checked_bodies() -> Array:
	var ids := bodies_in(current_values, "bodies")
	return ids if ids.size() > 1 else []


## The checked bodies that are surfaces: they hold no volume, so no overlap is looked for.
func surface_bodies() -> Array:
	var bodies: Dictionary = workspace.result.get("bodies", {})
	var ids := checked_bodies()
	return (ids if not ids.is_empty() else bodies.keys()).filter(func(id: String) -> bool:
		return bodies.has(id) and INSPECT.shape_kind(bodies[id].shape) == "surface")


func describe() -> String:
	var doc: Resource = workspace.doc
	var lines := PackedStringArray()
	var count := checked_bodies().size()
	var skipped := surface_bodies()
	lines.append("Checking %s." % ("%d bodies" % count if count > 0 else "every body"))
	if not skipped.is_empty():
		lines.append("Surfaces have no volume and are not checked: %s." % ", ".join(PackedStringArray(skipped.map(func(id: String) -> String: return doc.body_name(id)))))
	# Pairs with an overlap worked out, and pairs reported without one (not worked out in time).
	var found := clashes.filter(func(clash: Dictionary) -> bool: return clash.has("volume") or clash.get("shape") != null)
	var open := clashes.filter(func(clash: Dictionary) -> bool: return not (clash.has("volume") or clash.get("shape") != null))
	if found.is_empty():
		var none := "No interference." if skipped.is_empty() else "No interference between the solids."
		if not unseen.is_empty():
			none = "No interference found."
		lines.append(none if open.is_empty() and failures.is_empty() else "No interference found in the pairs that were checked.")
	else:
		lines.append("%d interference%s:" % [found.size(), "" if found.size() == 1 else "s"])
		for clash in found:
			lines.append("  %s / %s: %s" % [_pair_name(clash, "a"), _pair_name(clash, "b"), power_text(float(clash.get("volume", 0.0)), 3) if clash.has("volume") else "overlap"])
			# (A solid tessellated to meet a mesh body: its note says that the volume is approximate
			# and by how much; a body that crosses itself: its warning.)
			for remark in remarks(clash, ["error"]):
				lines.append("    %s" % remark)
	for clash in open:
		var said := remarks(clash)
		lines.append("  %s / %s not checked: %s" % [_pair_name(clash, "a"), _pair_name(clash, "b"), " ".join(said) if not said.is_empty() else "no result came back."])
	for failure in failures:
		# (A pair left out for time, or with an open mesh body, says so in its own sentence.)
		var own_words := bool(failure.get("timed_out", false)) or bool(failure.get("open", false))
		lines.append("  %s / %s%s %s" % [_pair_name(failure, "a"), _pair_name(failure, "b"), ":" if own_words else " could not be checked:", failure.error])
		for remark in remarks(failure, ["error"]):
			lines.append("    %s" % remark)
	# Pairs that nearly touch: no interference was found, and the remark says what would not
	# have been seen. Under the list, in their own lines.
	for near in unseen:
		var said := remarks(near)
		lines.append("%s / %s: %s" % [_pair_name(near, "a"), _pair_name(near, "b"), " ".join(said) if not said.is_empty() else "No overlap was found, but the bodies nearly touch."])
	return "\n".join(lines)


## The name of one body of a pair ("?" when the entry does not name it).
func _pair_name(entry: Dictionary, side: String) -> String:
	return workspace.doc.body_name(str(entry[side])) if entry.has(side) else "?"


## Every remark an entry carries, one line each: its "error", "warning" and "note" (a text or a
## list of texts each, also as "warnings" and "notes"). skip: keys already shown.
static func remarks(entry: Dictionary, skip: Array = []) -> PackedStringArray:
	var lines := PackedStringArray()
	for key in ["error", "warning", "warnings", "note", "notes"]:
		if skip.has(key) or not entry.has(key):
			continue
		var held: Variant = entry[key]
		for text in (held if held is Array or held is PackedStringArray else [held]):
			if str(text).strip_edges() != "" and not lines.has(str(text)):
				lines.append(str(text))
	return lines


## The overlaps that are B-rep solids (what a base feature can hold); an overlap with a mesh body
## in it is a mesh.
func solid_clashes() -> Array:
	return clashes.filter(func(clash: Dictionary) -> bool: return not MESH_BODY.is_mesh(clash.get("shape")))


func on_button(key: String) -> void:
	if key == "create":
		create_bodies()
	elif key == "create_components":
		create_bodies(true)


## Adds every overlap as a new body (one base feature, one undo step), each in a new component of
## its own with as_components, and closes the command.
func create_bodies(as_components := false) -> void:
	if clashes.is_empty():
		workspace.flash("There are no overlaps to make %s from." % ("components" if as_components else "bodies"))
		return
	var solids := solid_clashes()
	var left_out := clashes.size() - solids.size()
	var mesh_note := ""
	if left_out > 0:
		mesh_note = " %d overlap%s with a mesh body %s left out: make %s with Mesh > Modify > Combine (Intersect)." % [
			left_out, "" if left_out == 1 else "s", "was" if left_out == 1 else "were", "it" if left_out == 1 else "them"]
	if solids.is_empty():
		workspace.flash("The overlaps are meshes, so no %s were made.%s" % ["components" if as_components else "bodies", mesh_note])
		return
	var breps := []
	for clash in solids:
		breps.append(clash.shape.to_brep_bytes())
	var ws: Object = workspace
	ws.cancel_command()
	var doc: Resource = ws.doc
	ws.change("Create %s from Interference" % ("Components" if as_components else "Bodies"), func() -> void:
		INSPECT.add_overlaps(doc, breps, as_components))
	if as_components:
		ws.flash("Added %d component%s from the overlaps.%s" % [breps.size(), "" if breps.size() == 1 else "s", mesh_note])
	else:
		ws.flash("Added %d bod%s from the overlaps.%s" % [breps.size(), "y" if breps.size() == 1 else "ies", mesh_note])


func end() -> void:
	workspace.viewport.set_command_meshes([])
