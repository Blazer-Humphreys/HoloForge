@tool
extends "res://addons/holo_forge/tools/inspect_command.gd"
## Center of Mass and Physical Material.
##
## "inspect:center_of_mass": the mass, volume and center of the picked bodies (all of them when
## none are picked), each body's own numbers and material, and their centers drawn in the view.
## Keep in Analysis adds a Center of Mass analysis on OK so the point stays shown.
## "inspect:physical_material": gives the picked bodies (or their components) a material from
## core/physical_materials.gd, showing the mass before and after; OK applies it as one undo step.
## Apply To Components also takes the own materials of the bodies in those components off, so they
## read their component's; the "after" mass is read through the same lookup the mass properties use.

const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const INSPECT := preload("res://addons/holo_forge/core/inspect.gd")
const PHYSICAL := preload("res://addons/holo_forge/core/physical_materials.gd")
const ANALYSIS := preload("res://addons/holo_forge/core/analysis.gd")
const ANALYSIS_COMMAND := preload("res://addons/holo_forge/tools/analysis_command.gd")

## How many bodies the readout lists one by one.
const LISTED_BODIES := 8

var type := "center_of_mass"
## The latest INSPECT.mass_properties() result.
var props := {}


func _init(p_type := "inspect:center_of_mass") -> void:
	type = p_type.trim_prefix("inspect:")


func title() -> String:
	return "Physical Material" if type == "physical_material" else "Center of Mass"


func fields() -> Array[Dictionary]:
	if type == "physical_material":
		var options := []
		for name in PHYSICAL.names():
			options.append([name, "%s (%s kg/m³)" % [name, significant(PHYSICAL.density(name))]])
		return [
			{"key": "bodies", "label": "Bodies", "type": "selection", "filter": "body"},
			{"key": "apply_to", "label": "Apply To", "type": "enum", "options": [["bodies", "Bodies"], ["components", "Components"]]},
			{"key": "material", "label": "Material", "type": "enum", "options": options},
			{"key": "result", "type": "info", "text": ""},
		]
	return [
		{"key": "bodies", "label": "Bodies", "type": "selection", "filter": "body"},
		{"key": "result", "type": "info", "text": ""},
		{"key": "keep", "label": "Keep in Analysis", "type": "bool"},
	]


func defaults() -> Dictionary:
	var ids := selection_bodies()
	if type == "physical_material":
		var current: String = PHYSICAL.material_for(workspace.doc, ids[0]) if not ids.is_empty() else PHYSICAL.DEFAULT
		return {"bodies": ids, "apply_to": "bodies", "material": current}
	return {"bodies": ids, "keep": false}


func update() -> void:
	var values: Dictionary = current_values
	var ids := bodies_in(values, "bodies")
	# The bodies where the assembly places them while the view is posed (spec 3.12, C7.4).
	props = INSPECT.mass_properties(workspace.doc, workspace.result, ids, workspace.inspect_poses() if workspace.has_method("inspect_poses") else {})
	if type == "physical_material":
		workspace.panel.set_info("result", _material_text(values, ids))
	else:
		workspace.panel.set_info("result", describe(props))
	workspace.viewport.redraw_overlay()


## The mass numbers as text in the document's units.
func describe(p: Dictionary) -> String:
	var per_body: Dictionary = p.get("bodies", {})
	if per_body.is_empty():
		return "There are no bodies."
	var lines := PackedStringArray()
	lines.append("Mass: %s kg" % significant(float(p.mass)))
	lines.append("Volume: %s" % power_text(float(p.volume), 3))
	# (In doubles, center64, when the result has it: a float32 center steps by mm 100 km out. The
	# marks drawn in the view keep the float32 center, which is fine for drawing.)
	var center64: Variant = p.get("center64")
	lines.append("Center: %s" % point_text(center64 if center64 is PackedFloat64Array and (center64 as PackedFloat64Array).size() == 3 else p.center))
	var listed := 0
	for body_id in per_body:
		if listed == LISTED_BODIES:
			lines.append("  ... %d more" % (per_body.size() - listed))
			break
		var entry: Dictionary = per_body[body_id]
		lines.append("  %s (%s): %s kg" % [workspace.doc.body_name(body_id), entry.material, significant(float(entry.mass))])
		# (An open mesh body has no volume: why it shows no mass.)
		for remark in remarks(entry):
			lines.append("    %s" % remark)
		listed += 1
	# Remarks on the whole result ("<Body>: <warning>" for each flawed body, core/inspect.gd): those
	# of the bodies listed above are there already; the others' are printed here. Without them,
	# how many of the bodies not listed carry a warning.
	var said := {}
	var unlisted := 0
	var seen := 0
	for body_id in per_body:
		seen += 1
		var warning := str((per_body[body_id] as Dictionary).get("warning", ""))
		if seen <= LISTED_BODIES:
			said["%s: %s" % [workspace.doc.body_name(body_id), warning]] = true
		elif not remarks(per_body[body_id]).is_empty():
			unlisted += 1
	if unlisted > 0 and not p.has("warnings"):
		lines.append("  %d of the bodies not listed %s a warning; pick fewer bodies to read it." % [unlisted, "has" if unlisted == 1 else "have"])
	for remark in remarks(p):
		if not said.has(remark):
			lines.append(remark)
	return "\n".join(lines)


## Every remark a mass entry carries, one line each: its "error", "warning" and "note" (a text or
## a list of texts each, also as "warnings" and "notes"), then what the mesh check counted
## (edges facing the wrong way, inside-out parts, places where the body crosses itself) and any
## flaw named in "flaws" that the counts do not cover.
static func remarks(entry: Dictionary) -> PackedStringArray:
	var lines := PackedStringArray()
	for key in ["error", "warning", "warnings", "note", "notes"]:
		if not entry.has(key):
			continue
		var held: Variant = entry[key]
		for text in (held if held is Array or held is PackedStringArray else [held]):
			if str(text).strip_edges() != "" and not lines.has(str(text)):
				lines.append(str(text))
	var counted := PackedStringArray()
	var covered := {}
	for item in [["wrong_way_edges", "wrong_way", "edge facing the wrong way", "edges facing the wrong way"],
			["inside_out_parts", "inside_out", "inside-out part", "inside-out parts"],
			["self_intersections", "self_crossing", "place where it crosses itself", "places where it crosses itself"]]:
		var count := int(entry.get(item[0], 0))
		if count > 0:
			counted.append("%d %s" % [count, item[2] if count == 1 else item[3]])
			covered[item[1]] = true
	var flaws: Variant = entry.get("flaws", [])
	if flaws is Array or flaws is PackedStringArray:
		for flaw in flaws:
			var word := str({"open": "open", "wrong_way": "triangles facing the wrong way", "no_volume": "no volume", "inside_out": "inside-out",
				"self_crossing": "crosses itself"}.get(str(flaw), str(flaw).replace("_", " ")))
			var said := false
			for line in lines:
				said = said or line.to_lower().contains(word) or line.to_lower().contains(str(flaw).replace("_", "-")) or line.to_lower().contains(str(flaw).replace("_", " "))
			if not covered.has(str(flaw)) and not said:
				counted.append(word)
	if not counted.is_empty():
		lines.append("Mesh check: %s." % ", ".join(counted))
	return lines


func _material_text(values: Dictionary, ids: Array) -> String:
	if ids.is_empty():
		return "Pick the bodies to give a material."
	var name := str(values.get("material", PHYSICAL.DEFAULT))
	var doc: Resource = workspace.doc
	# The mass after OK, each body read through PHYSICAL.material_for() as OK leaves the document.
	var trial: Resource = DOCUMENT.new()
	trial.bodies = doc.bodies
	trial.components = doc.components
	trial.physical_materials = assigned(doc, ids, str(values.get("apply_to", "bodies")) == "components", name)
	var after := 0.0
	var kept := PackedStringArray()
	for body_id in ids:
		var material := PHYSICAL.material_for(trial, body_id)
		# Solid volume only: a surface (open shell) body has no mass, as in the mass properties.
		after += INSPECT.solid_volume(workspace.result.bodies[body_id].shape) * PHYSICAL.density(material)
		if material != name:
			kept.append("%s keeps %s" % [doc.body_name(body_id), material])
	var text := "Mass now: %s kg\nWith %s: %s kg" % [significant(float(props.get("mass", 0.0))), name, significant(after)]
	return text + ("\n" + ", ".join(kept) + "." if not kept.is_empty() else "")


func draw(overlay: Control) -> void:
	if type != "center_of_mass":
		return
	var per_body: Dictionary = props.get("bodies", {})
	if per_body.is_empty():
		return
	var view: Control = workspace.viewport
	var font := overlay.get_theme_default_font()
	var marks := []
	if per_body.size() > 1:
		for body_id in per_body:
			marks.append([per_body[body_id].center, ANALYSIS.COM_COLORS.body, workspace.doc.body_name(body_id)])
	marks.append([props.center, ANALYSIS.COM_COLORS.total, "Center of Mass"])
	# Labels in the view's palette, on a backing that reads on any background.
	var colors: Dictionary = view.get("theme_colors")
	for mark in marks:
		var at: Vector2 = view.project(mark[0])
		if at.is_finite():
			overlay.draw_circle(at, 5.0, mark[1])
			overlay.draw_arc(at, 5.0, 0.0, TAU, 16, Color.WHITE, 1.5, true)
			var size := font.get_string_size(mark[2], HORIZONTAL_ALIGNMENT_LEFT, -1, 12)
			overlay.draw_rect(Rect2(at + Vector2(5, -6 - size.y + 2), size + Vector2(6, 4)), colors.note_back, true)
			overlay.draw_string(font, at + Vector2(8, -6), mark[2], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, colors.note_text)


func accept_error() -> String:
	if type == "physical_material" and bodies_in(current_values, "bodies").is_empty():
		return "Pick the bodies to give a material."
	return ""


func finish() -> void:
	var values: Dictionary = current_values
	var ids := bodies_in(values, "bodies")
	var doc: Resource = workspace.doc
	if type == "physical_material":
		var name := str(values.get("material", PHYSICAL.DEFAULT))
		var components := str(values.get("apply_to", "bodies")) == "components"
		var keys := targets(doc, ids, components)
		var materials := assigned(doc, ids, components, name)
		workspace.change("Physical Material", func() -> void: doc.physical_materials = materials.duplicate())
		workspace.flash("%s: %s." % [name, ", ".join(keys.map(func(key: String) -> String: return _target_name(doc, key)))])
	elif bool(values.get("keep", false)):
		# The panel values too, so editing the analysis opens on its own bodies.
		workspace.change("Create Center of Mass Analysis", func() -> void:
			doc.analyses.append(ANALYSIS_COMMAND.new_entry(doc, "center_of_mass", {"body_ids": ids, "panel": {"bodies": ids.duplicate()}})))


## doc.physical_materials keys for bodies, or their components (top-level bodies keep their own).
## A body a feature split off or copied ("body3.f7.2") gets a key of its own, so each piece can
## have its own material; pieces without one still read their source body's (PHYSICAL.material_for).
static func targets(doc: Resource, ids: Array, components: bool) -> Array[String]:
	var keys: Array[String] = []
	for body_id in ids:
		var component: String = doc.body_component(body_id)
		var key := ("component:" + component) if components and component != "" else ("body:" + str(body_id))
		if not keys.has(key):
			keys.append(key)
	return keys


## doc.physical_materials after giving the bodies (or their components) the material name: the
## targets() keys set through PHYSICAL.assign, which for components also erases the own keys of the
## bodies in them (split pieces too), so the component's material reaches every one of them. The
## preview and OK both read this, so the panel shows the mass OK gives.
static func assigned(doc: Resource, ids: Array, components: bool, name: String) -> Dictionary:
	var out: Dictionary = doc.physical_materials.duplicate()
	PHYSICAL.assign(out, doc, targets(doc, ids, components), name)
	return out


static func _target_name(doc: Resource, key: String) -> String:
	return doc.component_name(key.trim_prefix("component:")) if key.begins_with("component:") else doc.body_name(key.trim_prefix("body:"))
