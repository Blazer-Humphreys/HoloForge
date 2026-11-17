@tool
extends "res://addons/holo_forge/tools/assemble_command.gd"
## Joint and As-built Joint (spec 3.3, 3.4): one joint between two components.
##
## Joint: Component 1 (moves) and Component 2 are snap picks; the joint frame is Component 2's
## snap frame with the Offset / Angle / Flip rows, and Component 1's snap meets it turned over
## (C2.4). As-built Joint: the two picks only say which components; Position (a snap, or the moving
## component's box centre when left empty) is where the joint sits now, so making it moves nothing.
## The side whose component holds the Position pick keeps that snap; the other side, and both when
## the pick is on a third component, keep a fixed frame (C2.4).
##
## Rows follow the Type: Slide Axis for slider and pin-slot, and per DOF the Motion rows (Value,
## Min, Max, Rest). A first pick on a fixed component swaps the sides (S-SIDES-SWAPPED, a note).
## Refused: no components (S-NO-COMPONENTS), both picks on one unit (S-SAME-UNIT), limits out of
## order (S-LIMITS-ORDER, S-LIMITS-EQUAL, S-REST-OUTSIDE). A value beyond its limit is a note
## (S-LIMIT) and is stored clamped. The preview solves the document with the new joint and poses
## the view (nothing is written before OK); the moving component's start shows as a ghost.
## With joint_id set (Edit Joint) it opens on that joint and OK replaces it.

## True for As-built Joint.
var as_built := false
## The joint being edited ("" for a new one).
var joint_id := ""
## The type the panel's rows are built for.
var _type := DATA.DEFAULT_TYPE
## The id a new joint gets (worked out once, so the preview and OK agree).
var _new_id := ""
## The assembly Play Motion runs in.
var _play_assembly := {}


func _init(p_type := "") -> void:
	super(p_type)
	as_built = p_type == "assemble:as_built_joint"


func title() -> String:
	if joint_id != "":
		return "Edit Joint"
	return "As-built Joint" if as_built else "Joint"


func action_name() -> String:
	if joint_id != "":
		return "Edit %s" % str(entry_of(_stored_assembly(), "joints", joint_id).get("name", joint_id))
	return "As-built Joint" if as_built else "Joint"


func fields() -> Array[Dictionary]:
	var out: Array[Dictionary] = [UI.type_field()]
	out.append(UI.snap_slot_field("a", "Component 1 (moves)"))
	out.append(UI.snap_slot_field("b", "Component 2"))
	if as_built:
		out.append(UI.snap_slot_field("origin", "Position"))
	else:
		out.append_array(UI.offset_fields())
	out.append_array(UI.slide_axis_rows(_type))
	out.append_array(UI.dof_rows(_type))
	if _type != "rigid":
		out.append(UI.play_field())
	out.append(UI.name_field())
	out.append(UI.status_field())
	return out


func defaults() -> Dictionary:
	_type = DATA.DEFAULT_TYPE
	var stored := _stored_assembly()
	_new_id = DATA.new_id(stored, "joint")
	return values_for({"type": _type, "name": DATA.name_for("joint", _new_id), "slide_axis": DATA.DEFAULT_SLIDE_AXIS.get(_type, "z")})


## Opens on the stored joint (Edit Joint).
func read_values() -> Dictionary:
	var joint := entry_of(_stored_assembly(), "joints", joint_id)
	as_built = bool(joint.get("as_built", false))
	_type = str(joint.get("type", DATA.DEFAULT_TYPE))
	var numbers := {
		"type": _type, "name": str(joint.get("name", joint_id)), "slide_axis": str(joint.get("slide_axis", "z")),
		"flip": bool(joint.get("flip", false)), "angle": float(joint.get("angle", 0.0)),
	}
	var offset: Array = Array(joint.get("offset", [0.0, 0.0, 0.0]))
	for i in 3:
		numbers["offset_" + "xyz"[i]] = float(offset[i]) if i < offset.size() else 0.0
	numbers.merge(UI.dof_values(joint.get("dofs", [])), true)
	for side in ["a", "b"]:
		var entry: Dictionary = joint.get(side, {})
		var item := snap_item(entry.get("snap", {}))
		if not item.is_empty():
			item["component"] = str(entry.get("component", item.component))
		numbers[side] = [item] if not item.is_empty() else []
	var values := values_for(numbers)
	current_values = values.duplicate(true)
	return values


func write_values(_doc: Resource, values: Dictionary) -> void:
	var new_type := str(values.get("type", _type))
	if new_type != _type and DATA.DOF_NAMES.has(new_type):
		# The rows follow the type: DOFs of the same name keep their rows' values (retype_dofs).
		# values is the workspace's own dictionary: it is changed in place.
		var dofs := DATA.retype_dofs(_type, UI.dofs_from(_numbers(values), _type), new_type)
		for key in values.keys():
			if str(key).begins_with("dof") or key == "slide_axis":
				values.erase(key)
		_type = new_type
		var fresh := UI.dof_values(dofs)
		fresh["slide_axis"] = DATA.DEFAULT_SLIDE_AXIS.get(_type, "z")
		for field in fields():
			var key := str(field.key)
			if not fresh.has(key):
				continue
			if str(field.type) == "expression":
				remember(values, key, float(fresh[key]), str(field.get("kind", "length")))
			else:
				values[key] = fresh[key]
		if workspace != null:
			workspace.panel.setup(title(), fields(), values, doc_units())
			workspace.call_deferred("place_panel")
	current_values = values.duplicate(true)


## The panel's values as numbers: expressions in base units (exact while untouched), the rest as
## they are.
func _numbers(values: Dictionary) -> Dictionary:
	var out := values.duplicate(true)
	for field in fields():
		if str(field.type) == "expression":
			out[field.key] = value_of(values, field.key, str(field.get("kind", "length")))
	return out


func check() -> void:
	var doc: Resource = workspace.doc
	if doc.components.is_empty():
		refusal = DATA.S_NO_COMPONENTS
		return
	var values := current_values
	var numbers := _numbers(values)
	var names := DATA.dof_names(_type)
	for i in names.size():
		var p := "dof%d_" % i
		var lo := float(numbers.get(p + "min", 0.0))
		var hi := float(numbers.get(p + "max", 0.0))
		var on_lo := bool(numbers.get(p + "limited_min", false))
		var on_hi := bool(numbers.get(p + "limited_max", false))
		var rest := float(numbers.get(p + "rest", 0.0))
		if on_lo and on_hi and lo > hi:
			refusal = DATA.S_LIMITS_ORDER
			return
		if on_lo and on_hi and lo == hi:
			refusal = DATA.S_LIMITS_EQUAL
			return
		if (on_lo and rest < lo) or (on_hi and rest > hi):
			refusal = DATA.S_REST_OUTSIDE
			return
	var a := first_item(values, "a")
	var b := first_item(values, "b")
	if a.is_empty():
		prompt = "Pick where Component 1, the one that moves, joins."
		return
	if b.is_empty():
		prompt = "Pick where it joins Component 2."
		return
	var sides := SOLVER.sides(doc, str(a.component), str(b.component))
	if str(sides.error) != "":
		refusal = str(sides.error)
		return
	notes.append_array(sides.notes)
	var candidate := build(values, sides)
	# Limits its Motion Links leave no value for (S-LIMITS-LINKED-EMPTY), or reversed ones.
	var limited := MOTION.limits_refusal(candidate, _id(), doc_units())
	if limited != "":
		refusal = limited
		return
	var joint := entry_of(candidate, "joints", _id())
	var solve_out := solve_with(candidate)
	var solved: Dictionary = (solve_out.get("joints", {}) as Dictionary).get(_id(), {})
	if str(solved.get("sentence", "")) != "":
		notes.append(str(solved.sentence))
	for i in names.size():
		var p := "dof%d_" % i
		var dof: Dictionary = (joint.get("dofs", []) as Array)[i]
		var asked := float(numbers.get(p + "value", 0.0))
		var held := JOINT_MATH.clamp_value(dof, asked)
		if held != asked:
			notes.append(DATA.fill(DATA.S_LIMIT, {
				"Joint": str(joint.get("name", "")), "limit": JOINT_MATH.format_dof(_type, i, held, doc_units()),
				"target": JOINT_MATH.format_dof(_type, i, asked, doc_units()),
			}))
	show_solve(solve_out, candidate)
	var moving := str(sides.a)
	workspace.assembly_display.show_ghost(workspace.viewport, unit_bodies(moving) if moving != "" else [], workspace.assembly_solve)


## Edit Joint's joint: a value of its that is not finite shows in its field, where it can be
## typed over (assemble_command.gd finite_refusal()).
func editing_id() -> String:
	return joint_id


## The joint's id (the edited one, or the new one).
func _id() -> String:
	return joint_id if joint_id != "" else _new_id


## The assembly with the joint made from values (sides: SOLVER.sides() of the picks), normalized;
## DOF values clamped to their limits.
func build(values: Dictionary, sides: Dictionary) -> Dictionary:
	var stored := _stored_assembly()
	var numbers := _numbers(values)
	var a := first_item(values, "a")
	var b := first_item(values, "b")
	if bool(sides.get("swapped", false)):
		var held := a
		a = b
		b = held
	var joint: Dictionary = entry_of(stored, "joints", joint_id).duplicate(true) if joint_id != "" else DATA.JOINT_DEFAULT.duplicate(true)
	if joint_id == "":
		DATA.new_id(stored, "joint")
		joint["id"] = _new_id
	var name := str(values.get("name", "")).strip_edges()
	joint["name"] = name if name != "" else DATA.name_for("joint", _id())
	joint["type"] = _type
	joint["as_built"] = as_built
	joint["slide_axis"] = str(values.get("slide_axis", DATA.DEFAULT_SLIDE_AXIS.get(_type, "z")))
	var dofs := UI.dofs_from(numbers, _type)
	for dof in dofs:
		dof["value"] = JOINT_MATH.clamp_value(dof, float(dof.value))
	joint["dofs"] = dofs
	if as_built:
		joint["offset"] = [0.0, 0.0, 0.0]
		joint["angle"] = 0.0
		joint["flip"] = false
		var stored_sides: bool = joint_id != "" and first_item(values, "origin").is_empty() \
			and str((joint.get("a", {}) as Dictionary).get("component", "")) == str(a.component) \
			and str((joint.get("b", {}) as Dictionary).get("component", "")) == str(b.component)
		if not stored_sides:
			# (An edited as-built joint keeps its frames unless a new Position is picked.)
			var made := _as_built_sides(values, a, b, sides)
			joint["a"] = made[0]
			joint["b"] = made[1]
	else:
		joint["offset"] = [float(numbers.get("offset_x", 0.0)), float(numbers.get("offset_y", 0.0)), float(numbers.get("offset_z", 0.0))]
		joint["angle"] = float(numbers.get("angle", 0.0))
		joint["flip"] = bool(numbers.get("flip", false))
		joint["a"] = {"component": str(a.component), "snap": (a.snap as Dictionary).duplicate(true)}
		joint["b"] = {"component": str(b.component), "snap": (b.snap as Dictionary).duplicate(true)}
	var joints: Array = stored.joints
	var at := -1
	for i in joints.size():
		if joints[i] is Dictionary and str(joints[i].get("id", "")) == _id():
			at = i
	if at >= 0:
		joints[at] = joint
	else:
		joints.append(joint)
	return DATA.normalized(stored)


## The sides of an as-built joint (C2.4): W is the Position pick where it shows now (or the
## moving unit's box centre); the side on the Position pick's unit keeps that snap, every other
## side gets a fixed frame P⁻¹ · W on its picked body.
func _as_built_sides(values: Dictionary, a: Dictionary, b: Dictionary, sides: Dictionary) -> Array:
	var doc: Resource = workspace.doc
	var stored := _stored_assembly()
	var picked := first_item(values, "origin")
	var world := XFORM.identity()
	var picked_unit := "\n"
	if not picked.is_empty():
		var snap: Dictionary = picked.snap
		var frame: PackedFloat64Array = SNAPS.resolve(snap, workspace.result, doc, stored).frame
		var body := str(snap.get("body", ""))
		if str(snap.get("kind", "")) == "origin":
			var origin := entry_of(stored, "origins", str(snap.get("origin", "")))
			body = str((origin.get("snap", {}) as Dictionary).get("body", ""))
		world = XFORM.compose(pose_of(body, str(picked.component)), frame)
		picked_unit = SOLVER.unit_of(doc.components, str(picked.component))
	else:
		var box := unit_box(str(sides.a))
		var c := box.get_center()
		world = XFORM.translation(c.x, c.y, c.z)
	var out := []
	for item: Dictionary in [a, b]:
		var component := str(item.component)
		if not picked.is_empty() and SOLVER.unit_of(doc.components, component) == picked_unit:
			out.append({"component": component, "snap": (picked.snap as Dictionary).duplicate(true)})
			continue
		var body := str((item.get("snap", {}) as Dictionary).get("body", item.get("body", "")))
		if body != "" and SOLVER.unit_of(doc.components, doc.body_component(body)) != SOLVER.unit_of(doc.components, component):
			body = ""
		var pose := pose_of(body, component)
		out.append({"component": component, "snap": SNAPS.fixed_snap(XFORM.compose(XFORM.inverse(pose), world), body)})
	return out


func apply_document(doc: Resource) -> void:
	var values := current_values
	var sides := SOLVER.sides(doc, str(first_item(values, "a").get("component", "")), str(first_item(values, "b").get("component", "")))
	doc.assembly = build(values, sides)


func play_joint() -> Dictionary:
	if refusal != "" or prompt != "":
		return {}
	var sides := SOLVER.sides(workspace.doc, str(first_item(current_values, "a").get("component", "")), str(first_item(current_values, "b").get("component", "")))
	_play_assembly = build(current_values, sides)
	return entry_of(_play_assembly, "joints", _id())


func play_assembly() -> Dictionary:
	return _play_assembly


## Ring and slide handles on the joint's DOFs (the Value rows), at the previewed joint frame.
func manipulators(_values: Dictionary, _evaluated: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var solved: Dictionary = (preview.get("joints", {}) as Dictionary).get(_id(), {})
	var world: Variant = solved.get("world")
	if refusal != "" or prompt != "" or not (world is PackedFloat64Array) or (world as PackedFloat64Array).size() != 12:
		return out
	var values: PackedFloat64Array = solved.get("values", PackedFloat64Array())
	for handle in workspace.viewport.dof_handles(_id(), XFORM.to_transform(world), _type, values, str(current_values.get("slide_axis", "z"))):
		handle["key"] = "dof%d_value" % int(handle.dof)
		out.append(handle)
	return out
