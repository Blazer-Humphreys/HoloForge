@tool
extends "res://addons/holo_forge/tools/assemble_command.gd"
## Drive Joints (spec 3.7): sets a joint's DOF values, as the stored values (C4.1).
##
## Joint picks the joint (the browser's Drive opens on one); one Value row per DOF with a slider
## under it (its limits; an open end to ±360° for a turn, ± the moving unit's box diagonal for a
## slide: assemble_command.gd dof_range()), and a ring or slide handle on each DOF in the view.
## Dragging a slider drives like dragging the handle (on from the last event, the short contact
## deadline). Each changed value goes through core/assembly/motion.gd
## drive() in turn: limits and motion links hold (followers move too), and a stop says why (S-LIMIT,
## S-LINK-LIMIT, as notes). The preview shows that solve; OK stores the reached values of the joint
## and every joint that moved with it (undo "Drive <Joint>").

## The joint the panel opens on ("" for the first one).
var joint_id := ""
## The type the Value rows are built for.
var _type := ""
## The assembly with the driven values (rebuilt by check()).
var _driven := {}
## True while a DOF handle or a Value slider is dragged (the workspace sets it; drag_ended()
## clears it).
var dragging := false
## The sliders' spans per joint id (_slider_spans()).
var _spans := {}

## A drag event's contact deadline (spec 8.1 #13).
const DRAG_SECONDS := 0.1


func drag_ended(_handle: Dictionary) -> void:
	dragging = false


func title() -> String:
	return "Drive Joints"


func action_name() -> String:
	return "Drive %s" % str(entry_of(_stored_assembly(), "joints", str(current_values.get("joint", joint_id))).get("name", joint_id))


## The joints that can be driven: those with DOFs.
func _joint_options() -> Array:
	var out := []
	for joint in _stored_assembly().joints:
		if joint is Dictionary and not DATA.dof_names(str(joint.get("type", ""))).is_empty():
			out.append([str(joint.id), str(joint.get("name", joint.id))])
	return out


func fields() -> Array[Dictionary]:
	var out: Array[Dictionary] = [{"key": "joint", "label": "Joint", "type": "enum", "options": _joint_options()}]
	var spans := _slider_spans()
	for row in UI.dof_rows(_type, "dof", false):
		if int(row.dof) < spans.size():
			var span: PackedFloat64Array = spans[int(row.dof)]
			row["slider"] = {"min": span[0], "max": span[1], "tooltip": "Drag to drive the joint; it stops at its limits and, with contact on, where bodies touch."}
		out.append(row)
	out.append({"key": "contact", "label": "Contact", "type": "info", "text": _contact_text()})
	out.append(UI.status_field())
	return out


## The span of each DOF's slider for the joint shown (dof_range(), from where its DOFs are when
## the panel opens on it), worked out once per joint: [PackedFloat64Array [low, high]].
func _slider_spans() -> Array:
	if _spans.has(joint_id):
		return _spans[joint_id]
	var out := []
	if workspace == null or workspace.doc == null:
		return out
	var joint := entry_of(_stored_assembly(), "joints", joint_id)
	if joint.is_empty():
		return out
	var shown := _shown_values(joint_id)
	for i in DATA.dof_names(str(joint.get("type", ""))).size():
		out.append(dof_range(joint, i, float(shown.get("dof%d_value" % i, 0.0))))
	_spans[joint_id] = out
	return out


## The Contact row (spec 3.7): the global switch's state; its notes (S-CONTACT-DEV and the rest)
## show in the status row with the drive's stop sentence.
func _contact_text() -> String:
	if workspace == null or workspace.doc == null:
		return ""
	if bool(_stored_assembly().contact.get("enabled", false)):
		return "On: a drive stops where the contact sets' bodies touch."
	return "Off (Enable Contact Sets turns it on)."


func defaults() -> Dictionary:
	var options := _joint_options()
	if joint_id == "" and not options.is_empty():
		joint_id = str(options[0][0])
	_type = str(entry_of(_stored_assembly(), "joints", joint_id).get("type", ""))
	var numbers := {"joint": joint_id}
	numbers.merge(_shown_values(joint_id), true)
	return values_for(numbers)


## The values a joint's DOFs show now (the stored solve's, which are clamped), as Value rows.
func _shown_values(id: String) -> Dictionary:
	var out := {}
	var joint := entry_of(_stored_assembly(), "joints", id)
	var solved: Dictionary = (workspace.assembly_solve.get("joints", {}) as Dictionary).get(id, {})
	var values: PackedFloat64Array = solved.get("values", JOINT_MATH.joint_values(joint))
	for i in DATA.dof_names(str(joint.get("type", ""))).size():
		out["dof%d_value" % i] = values[i] if i < values.size() else 0.0
	return out


func write_values(_doc: Resource, values: Dictionary) -> void:
	var id := str(values.get("joint", ""))
	if id != joint_id and id != "":
		# Another joint: its own Value rows.
		joint_id = id
		_type = str(entry_of(_stored_assembly(), "joints", id).get("type", ""))
		for key in values.keys():
			if str(key).begins_with("dof"):
				values.erase(key)
		var shown := _shown_values(id)
		for key in shown:
			remember(values, key, float(shown[key]), UI.dof_kind(str(DATA.dof_names(_type)[int(str(key).trim_prefix("dof").to_int())])))
		if workspace != null:
			workspace.panel.setup(title(), fields(), values, doc_units())
			workspace.call_deferred("place_panel")
	current_values = values.duplicate(true)


func check() -> void:
	var stored := _stored_assembly()
	var joint := entry_of(stored, "joints", joint_id)
	if joint.is_empty():
		prompt = "There is no joint to drive. Make one with Joint first."
		return
	var doc: Resource = workspace.doc
	# A drag drives on from where the last drag event reached (with contact, each event sweeps
	# only its own step, 0.1 s at most, spec 8.1 #13); a typed value drives from the stored value
	# with the full contact budget.
	var working := _driven if dragging and not _driven.is_empty() else stored
	var options := {"deadline_seconds": DRAG_SECONDS} if dragging else {}
	var now := JOINT_MATH.joint_values(joint)
	var last := {}
	for i in DATA.dof_names(_type).size():
		var key := "dof%d_value" % i
		var target := value_of(current_values, key, UI.dof_kind(str(DATA.dof_names(_type)[i])), now[i] if i < now.size() else 0.0)
		var held := JOINT_MATH.joint_values(entry_of(working, "joints", joint_id))
		if i < held.size() and target == held[i]:
			continue
		var kept: Dictionary = doc.assembly
		doc.assembly = working
		last = MOTION.drive(doc, workspace.result, workspace.kernel, joint_id, i, target, options)
		doc.assembly = kept
		# A drive MOTION.drive() refuses (suppressed or waiting joint, reversed limits, an empty or
		# broken link, a target that is not finite) moves nothing: its sentence is the refusal.
		if bool(last.get("refused", false)) and str(last.get("stopped_by", "")) == "":
			refusal = str(last.get("sentence", "")) if str(last.get("sentence", "")) != "" else "This joint cannot be driven now."
			_driven = {}
			return
		working = working.duplicate(true)
		for id in last.get("values", {}):
			var moved := entry_of(working, "joints", str(id))
			var list: PackedFloat64Array = last.values[id]
			for d in mini(list.size(), (moved.get("dofs", []) as Array).size()):
				moved.dofs[d]["value"] = list[d]
		if str(last.get("sentence", "")) != "":
			notes.append(str(last.sentence))
		# Contact notes (S-CONTACT-DEV, -START, -THIN, -NO-SETS, -SKIPPED) show in the status row.
		for warning in last.get("warnings", PackedStringArray()):
			if not notes.has(str(warning)):
				notes.append(str(warning))
	_driven = working
	var solve_out: Dictionary = solve_with(working) if not last.is_empty() else workspace.assembly_solve
	show_solve(solve_out, working)
	workspace.panel.set_info("contact", _contact_text())
	# A contact stop marks where the bodies met (spec 6.2).
	var point: Variant = (last.get("contact", {}) as Dictionary).get("point")
	if str(last.get("stopped_by", "")) == "contact" and point is PackedFloat64Array and (point as PackedFloat64Array).size() == 3 and workspace.assembly_display != null:
		workspace.assembly_display.flash_contact(workspace.viewport, Vector3(point[0], point[1], point[2]))


func apply_document(doc: Resource) -> void:
	if not _driven.is_empty():
		doc.assembly = _driven


## A ring or a slide on each DOF at the joint's frame.
func manipulators(_values: Dictionary, _evaluated: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var solved: Dictionary = (preview.get("joints", {}) as Dictionary).get(joint_id, {})
	var world: Variant = solved.get("world")
	if prompt != "" or not (world is PackedFloat64Array) or (world as PackedFloat64Array).size() != 12:
		return out
	var joint := entry_of(_stored_assembly(), "joints", joint_id)
	var values: PackedFloat64Array = solved.get("values", PackedFloat64Array())
	for handle in workspace.viewport.dof_handles(joint_id, XFORM.to_transform(world), _type, values, str(joint.get("slide_axis", "z"))):
		handle["key"] = "dof%d_value" % int(handle.dof)
		out.append(handle)
	return out


func play_joint() -> Dictionary:
	return entry_of(_stored_assembly(), "joints", joint_id)
