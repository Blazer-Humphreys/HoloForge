@tool
extends RefCounted
## Driving joints, limits, motion links and Motion Study (Holo Forge Phase 8, contracts C4 and C6;
## contact, C4.4 and the study's contact sweep, through core/assembly/contact.gd).
##
## Nothing here writes the document: drive() and study_frames() return values and solves for the
## tools and panels, which store values through workspace.change() on OK. new_link() writes into
## the assembly dictionary it is given (the caller's normalized copy).
##
## A DOF is a node {"joint": id, "dof": i}. A link makes its follower = ratio · driver + offset
## (C4.3). Each follower has one driver and links never close a circle, so the links form trees;
## a tree's root is the DOF nothing drives. Values move down a tree link by link (so a chain of
## exact ratios stays exact) and back up it the same way.

const XFORM := preload("res://addons/holo_forge/core/assembly/xform64.gd")
const DATA := preload("res://addons/holo_forge/core/assembly/assembly_data.gd")
const JOINT_MATH := preload("res://addons/holo_forge/core/assembly/joint_math.gd")
const SOLVER := preload("res://addons/holo_forge/core/assembly/solver.gd")
const CONTACT := preload("res://addons/holo_forge/core/assembly/contact.gd")

## One deadline for working out a whole study (C6).
const STUDY_SECONDS := 20.0
## One deadline for a drive with contact (C5.5).
const CONTACT_SECONDS := 5.0
## Study bounds (C6).
const STUDY_LENGTH_MIN := 0.1
const STUDY_LENGTH_MAX := 60.0
const STUDY_FPS_MIN := 10
const STUDY_FPS_MAX := 60
## Angle a rotation DOF is nudged by to see whether it turns any contact pair (radians; N2).
const TURNING_NUDGE := 1e-3


# --- Drive (C4.1, C4.2, C4.3) --------------------------------------------------------------------

## Drives one DOF of a joint toward target (C4.1): {"values": {joint_id: PackedFloat64Array} (every
## joint whose DOFs move: the driven one, its link root and everything that follows the root),
## "reached": the driven DOF's value, "clamped": bool, "stopped_by": "" | "limit" | "link" |
## "contact", "sentence", "solve": the C3 output at those values, "ms", "contact": the sweep's
## result (CONTACT.sweep; nothing checked when contact is off), "warnings": PackedStringArray (the
## sweep's: S-CONTACT-NO-SETS, -START, -THIN, -DEV, -SKIPPED), "refused": bool}. Never writes the
## document.
## With contact on (the assembly's contact.enabled, C4.4) the motion is swept from the stored value
## to the clamped target and stops early at the last clear value ("stopped_by" "contact",
## S-CONTACT-STOP; S-CONTACT-TIMEOUT when the deadline ends it there). A sweep refused up front
## (S-CONTACT-STEPS, S-CONTACT-TOO-SLOW) moves nothing: the values stay the stored ones and
## "refused" is true.
## options: "contact" (false: no sweep even when contact is on), "deadline_seconds" (a shorter
## deadline for the sweep's run, e.g. 0.1 s per drag event, 8.1 #13; the estimate still uses
## CONTACT_SECONDS).
## A drive that cannot be made (move()'s "error": a target that is not finite, reversed limits,
## links that leave no value, a link that is not finite; or a joint that is suppressed, waits for
## the rollback marker or lost a component) moves nothing: "refused" is true, "sentence" says why
## and the values stay the stored ones. So does a drive whose link tree holds a joint number that
## is not finite in the stored assembly (S-STORED-NOT-FINITE). The sweep's turning counts only
## rotation DOFs that turn a contact pair (_turning(), N2).
static func drive(doc: Resource, result: Dictionary, kernel: RefCounted, joint_id: String, dof: int, target: float, options := {}) -> Dictionary:
	var started := Time.get_ticks_usec()
	var assembly: Dictionary = DATA.normalized(doc.assembly if doc.assembly is Dictionary else {})
	var units := str(doc.units)
	var moved := move(assembly, joint_id, dof, target, units)
	if str(moved.error) == "":
		var state := drive_refusal(doc, assembly, joint_id)
		if state != "":
			moved = _refused_move(assembly, joint_id, dof, state)
	var swept := CONTACT.empty_result(float(moved.reached))
	if bool(assembly.contact.get("enabled", false)) and bool(options.get("contact", true)) and str(moved.error) == "":
		var tree := _Tree.new(assembly)
		var node := _key(joint_id, dof)
		var start: float = JOINT_MATH.joint_values(_joint(assembly, joint_id))[dof]
		var path := func(v: float) -> Dictionary:
			return SOLVER.solve(doc, result, kernel, _overrides(move(assembly, joint_id, dof, v, units).values)).body_poses
		var turning := _turning(doc, result, kernel, assembly, tree, [node])
		var sweep_options := {
			"assembly": assembly, "seconds": CONTACT_SECONDS, "turn": _turn(tree, node, start, float(moved.reached), turning),
			"format": func(v: float) -> String: return tree.format(node, v, units),
		}
		if float(options.get("deadline_seconds", 0.0)) > 0.0:
			sweep_options["deadline_seconds"] = float(options.deadline_seconds)
		swept = CONTACT.sweep(doc, result, kernel, path, start, float(moved.reached), sweep_options)
		if bool(swept.refused) or bool(swept.stopped):
			var sentence := str(swept.sentence)
			moved = move(assembly, joint_id, dof, float(swept.reached), units)
			moved["stopped_by"] = "contact"
			moved["sentence"] = sentence
	var solved := SOLVER.solve(doc, result, kernel, _overrides(moved.values))
	return {
		"values": moved.values, "reached": moved.reached, "clamped": moved.clamped, "stopped_by": moved.stopped_by,
		"sentence": moved.sentence, "solve": solved, "ms": float(Time.get_ticks_usec() - started) / 1000.0,
		"contact": swept, "warnings": swept.warnings, "refused": bool(swept.refused) or str(moved.error) != "",
	}


## Why a joint cannot be driven as it stands in the document, or "": S-DRIVE-SUPPRESSED,
## S-MISSING-COMPONENT, S-WAITING (a side made after the rollback marker).
static func drive_refusal(doc: Resource, assembly: Dictionary, joint_id: String) -> String:
	var joint := _joint(assembly, joint_id)
	if joint.is_empty():
		return ""
	var joint_name := str(joint.get("name", joint_id))
	if bool(joint.get("suppressed", false)):
		return DATA.fill(DATA.S_DRIVE_SUPPRESSED, {"Joint": joint_name})
	var components: Dictionary = doc.components
	for side_key in ["a", "b"]:
		var side: Dictionary = joint.get(side_key, {}) if joint.get(side_key) is Dictionary else {}
		var component_id := str(side.get("component", ""))
		if component_id == "":
			continue
		if not components.has(component_id):
			return DATA.fill(DATA.S_MISSING_COMPONENT, {"Joint": joint_name, "Comp": component_id})
		if SOLVER.is_waiting(doc, components, component_id):
			return DATA.fill(DATA.S_WAITING, {"Joint": joint_name, "Comp": doc.component_name(component_id)})
	return ""


## move()'s output for a drive that moves nothing: the joint's stored values, reached = the stored
## value, "error" and "sentence" the refusal. A joint with a stored value that is not finite has no
## "values" entry, and "reached" is then 0 (the sentence names the value).
static func _refused_move(assembly: Dictionary, joint_id: String, dof: int, sentence: String) -> Dictionary:
	var joint := _joint(assembly, joint_id)
	var stored := JOINT_MATH.joint_values(joint) if not joint.is_empty() else PackedFloat64Array()
	# (A limit that is not finite would clamp the value to it: the stored values as they are.)
	var dofs: Array = joint.get("dofs", []) if joint.get("dofs") is Array else []
	for i in mini(stored.size(), dofs.size()):
		if not is_finite(stored[i]) and dofs[i] is Dictionary:
			stored[i] = float((dofs[i] as Dictionary).get("value", 0.0))
	var values := {}
	var finite := true
	for v in stored:
		finite = finite and is_finite(v)
	# (Fix round 3, PT1: a stored value that is not finite is not handed back: no "values" entry
	# for the joint, and "reached" 0.)
	if not joint.is_empty() and finite:
		values[joint_id] = stored
	var reached := float(stored[dof]) if dof >= 0 and dof < stored.size() else 0.0
	return {
		"values": values, "reached": reached if is_finite(reached) else 0.0, "clamped": false, "stopped_by": "",
		"sentence": sentence, "error": sentence,
	}


## Solver overrides ({joint_id: {dof: value}}) from values {joint_id: PackedFloat64Array}.
static func _overrides(values: Dictionary) -> Dictionary:
	var overrides := {}
	for id in values:
		var forced := {}
		var list: PackedFloat64Array = values[id]
		for i in list.size():
			forced[i] = list[i]
		overrides[id] = forced
	return overrides


## The most any unit may turn when node's link tree moves from node = start to node = end: every
## rotation DOF in the tree turns |slope| times as far as the root (radians; for the sweep's first
## look, C5.4). With turning ({node: true}, from _turning()), only those rotation DOFs count (N2: a
## knob in no contact set may spin many turns while the lever it drives turns little).
static func _turn(tree: _Tree, node: String, start: float, end: float, turning: Variant = null) -> float:
	var root := tree.root_of(node)
	var travel := absf(tree.up(node, root, end) - tree.up(node, root, start))
	var turn := 0.0
	for member: String in tree.below(root):
		if turning is Dictionary and not (turning as Dictionary).has(member):
			continue
		if JOINT_MATH.dof_is_rotation(tree.type_of(member), int(member.get_slice("|", 1))):
			turn += absf(tree.slope(member, root)) * travel
	return turn


## The rotation DOFs among the members of nodes' link trees that turn a pair of bodies of the
## enabled contact sets against each other: {node: true}. Each is nudged by TURNING_NUDGE alone (a
## solve with only it changed) and kept when some pair's relative pose changes.
static func _turning(doc: Resource, result: Dictionary, kernel: RefCounted, assembly: Dictionary, tree: _Tree, nodes: Array) -> Dictionary:
	var out := {}
	var pairs := CONTACT.contact_pairs(doc, result, assembly)
	if pairs.is_empty():
		return out
	var base: Dictionary = SOLVER.solve(doc, result, kernel).body_poses
	var seen := {}
	for node: String in nodes:
		for member: String in tree.below(tree.root_of(node)):
			if seen.has(member):
				continue
			seen[member] = true
			var parts := member.split("|")
			if not JOINT_MATH.dof_is_rotation(tree.type_of(member), int(parts[1])):
				continue
			var stored: float = JOINT_MATH.joint_values(_joint(assembly, parts[0]))[int(parts[1])]
			# (Both ways, fix round 3: the solve clamps a nudge to the limits, so a DOF stored at its
			# Max moves only downward.)
			for nudge in [TURNING_NUDGE, -TURNING_NUDGE]:
				if out.has(member):
					break
				var nudged: Dictionary = SOLVER.solve(doc, result, kernel, {parts[0]: {int(parts[1]): stored + nudge}}).body_poses
				for pair: Dictionary in pairs:
					var before := XFORM.compose(XFORM.inverse(base.get(pair.a, XFORM.identity())), base.get(pair.b, XFORM.identity()))
					var after := XFORM.compose(XFORM.inverse(nudged.get(pair.a, XFORM.identity())), nudged.get(pair.b, XFORM.identity()))
					if XFORM.distance(before, after) > 1e-12 or XFORM.angle_between(before, after) > 1e-12:
						out[member] = true
						break
	return out


## The turn of the units in contact per unit of (joint_id, dof) played or driven (radians per
## radian or per metre; fix round 3, for Play): as _turn() over a unit change, through the DOF's
## link root (a follower moves its root, and its root's whole tree), counting only rotation DOFs
## that turn a contact pair (_turning()). assembly: normalized (doc.assembly when empty). 0 when
## nothing in contact turns, or for no such DOF.
static func turn_rate(doc: Resource, result: Dictionary, kernel: RefCounted, joint_id: String, dof: int, assembly := {}) -> float:
	if assembly.is_empty():
		assembly = DATA.normalized(doc.assembly if doc.assembly is Dictionary else {})
	var joint := _joint(assembly, joint_id)
	if joint.is_empty() or dof < 0 or dof >= (joint.get("dofs", []) as Array).size():
		return 0.0
	var tree := _Tree.new(assembly)
	var node := _key(joint_id, dof)
	var rate := _turn(tree, node, 0.0, 1.0, _turning(doc, result, kernel, assembly, tree, [node]))
	return rate if is_finite(rate) else 0.0


## The DOF values a drive of (joint_id, dof) to target gives, without solving: {"values",
## "reached", "clamped", "stopped_by", "sentence", "error"} (see drive()). assembly is normalized.
static func move(assembly: Dictionary, joint_id: String, dof: int, target: float, units := "mm") -> Dictionary:
	var out := {"values": {}, "reached": target, "clamped": false, "stopped_by": "", "sentence": "", "error": ""}
	var joint := _joint(assembly, joint_id)
	if joint.is_empty() or dof < 0 or dof >= (joint.get("dofs", []) as Array).size():
		out["error"] = "There is no such joint DOF to drive."
		return out
	var tree := _Tree.new(assembly)
	var node := _key(joint_id, dof)
	if not is_finite(target):
		return _refused_move(assembly, joint_id, dof, DATA.fill(DATA.S_DRIVE_NOT_FINITE, {"Joint": tree.name_of(node), "value": _non_finite_text(target)}))
	var root := tree.root_of(node)
	# (PT1: a number of the tree's joints that is not finite in the stored assembly, a hand edit.)
	var checked := {}
	for member: String in [node] + tree.below(root):
		var id := member.get_slice("|", 0)
		if checked.has(id):
			continue
		checked[id] = true
		var stored_bad := DATA.joint_not_finite(_joint(assembly, id))
		if stored_bad != "":
			return _refused_move(assembly, joint_id, dof, stored_bad)
	var bad: String = tree.bad_link_near(node)
	if bad != "":
		return _refused_move(assembly, joint_id, dof, DATA.fill(DATA.S_LINK_NOT_FINITE, {"Joint": tree.name_of(node), "Link": bad}))
	# The driven DOF's target as a root value (back up the links).
	var root_target := tree.up(node, root, target)
	# The interval the root may take: its limits and every follower's, mapped back.
	var span := _interval(tree, root)
	if str(span.reversed) != "":
		var member := str(span.reversed)
		var d := tree.dof_of(member)
		return _refused_move(assembly, joint_id, dof, DATA.fill(DATA.S_LIMITS_REVERSED, {
			"Joint": tree.name_of(member), "min": tree.format(member, float(d.min), units), "max": tree.format(member, float(d.max), units),
		}))
	var low := float(span.low)
	var high := float(span.high)
	var low_by: Array = span.low_by
	var high_by: Array = span.high_by
	if low > high:
		return _refused_move(assembly, joint_id, dof, DATA.fill(DATA.S_LINK_EMPTY, {
			"Joint": tree.name_of(node), "A": tree.name_of(str(low_by[0])), "B": tree.name_of(str(high_by[0])),
		}))
	var root_value := root_target
	var binding := ["", ""]
	if root_value < low:
		root_value = low
		binding = low_by
	elif root_value > high:
		root_value = high
		binding = high_by
	var bound_node: String = binding[0]
	# Values down the tree, with the binding DOF (if any) holding exactly its stored limit.
	var values := tree.down(root, root_value)
	if bound_node != "":
		var limit_value := float(tree.dof_of(bound_node)[binding[1]])
		if bound_node == root:
			values = tree.down(root, limit_value)
		values[bound_node] = limit_value
		out["clamped"] = true
	# Every value within its own limits (assignment when one binds by rounding).
	for member: String in values:
		values[member] = JOINT_MATH.clamp_value(tree.dof_of(member), float(values[member]))
	var reached: float = values.get(node, target)
	out["reached"] = reached
	for member: String in values:
		var parts := member.split("|")
		var id := parts[0]
		if not out.values.has(id):
			out.values[id] = JOINT_MATH.joint_values(_joint(assembly, id))
		var list: PackedFloat64Array = out.values[id]
		list[int(parts[1])] = float(values[member])
		out.values[id] = list
	if bound_node != "":
		var limit := float(tree.dof_of(bound_node)[binding[1]])
		if bound_node == node:
			out["stopped_by"] = "limit"
			out["sentence"] = DATA.fill(DATA.S_LIMIT, {
				"Joint": tree.name_of(node), "limit": tree.format(node, limit, units), "target": tree.format(node, target, units),
			})
		else:
			out["stopped_by"] = "link" if bound_node != root else "limit"
			out["sentence"] = DATA.fill(DATA.S_LINK_LIMIT, {
				"Joint": tree.name_of(node), "value": tree.format(node, reached, units), "Follower": tree.name_of(bound_node),
				"ratio": format_ratio(tree.slope(bound_node, node)), "limit": tree.format(bound_node, limit, units),
			})
	return out


## The interval a link tree's root may take (its limits and every follower's, mapped back up the
## links): {"low", "high", "low_by", "high_by" ([node, "min"|"max"] of the binding ends; "" when
## open), "reversed": the first node whose Min is above its Max, or ""}. low > high when the limits
## leave no value.
static func _interval(tree: _Tree, root: String) -> Dictionary:
	var out := {"low": -INF, "high": INF, "low_by": ["", ""], "high_by": ["", ""], "reversed": ""}
	for member: String in tree.below(root):
		var d := tree.dof_of(member)
		if bool(d.get("limited_min", false)) and bool(d.get("limited_max", false)) and float(d.get("min", 0.0)) > float(d.get("max", 0.0)) and str(out.reversed) == "":
			out["reversed"] = member
		for end: String in ["min", "max"]:
			if not bool(d.get("limited_" + end, false)):
				continue
			var bound := tree.up(member, root, float(d[end]))
			# Which side of the root's interval this end bounds depends on the composed ratio's sign.
			var rising := tree.slope(member, root) > 0.0
			var lower: bool = (end == "min") == rising
			if lower and (bound > float(out.low) or (bound == float(out.low) and member == root)):
				out["low"] = bound
				out["low_by"] = [member, end]
			elif not lower and (bound < float(out.high) or (bound == float(out.high) and member == root)):
				out["high"] = bound
				out["high_by"] = [member, end]
	return out


## Why the limits of joint_id (as they stand in assembly, e.g. the Joint panel's edited copy)
## cannot be kept, or "": S-LIMITS-REVERSED for a Min above its Max, S-LIMITS-LINKED-EMPTY when,
## through its motion links, they leave a DOF's tree no value.
static func limits_refusal(assembly: Dictionary, joint_id: String, units := "mm") -> String:
	var joint := _joint(assembly, joint_id)
	if joint.is_empty():
		return ""
	var tree := _Tree.new(assembly)
	for dof in (joint.get("dofs", []) as Array).size():
		var node := _key(joint_id, dof)
		var span := _interval(tree, tree.root_of(node))
		if str(span.reversed) != "":
			var member := str(span.reversed)
			var d := tree.dof_of(member)
			return DATA.fill(DATA.S_LIMITS_REVERSED, {
				"Joint": tree.name_of(member), "min": tree.format(member, float(d.min), units), "max": tree.format(member, float(d.max), units),
			})
		if float(span.low) > float(span.high):
			return DATA.fill(DATA.S_LIMITS_LINKED_EMPTY, {
				"Joint": tree.name_of(node), "A": tree.name_of(str(span.low_by[0])), "B": tree.name_of(str(span.high_by[0])),
			})
	return ""


## "NaN", "INF" or "-INF" for a sentence.
static func _non_finite_text(value: float) -> String:
	if is_nan(value):
		return "NaN"
	return "INF" if value > 0.0 else "-INF"


# --- Links (C4.3) --------------------------------------------------------------------------------

## Why a link from driver to follower ({"joint", "dof"} each) with ratio cannot be made, or "".
static func link_refusal(assembly: Dictionary, driver: Dictionary, follower: Dictionary, ratio: float) -> String:
	var refusal := DATA.edit_refusal(assembly)
	if refusal != "":
		return refusal
	if not is_finite(ratio):
		return DATA.S_RATIO_NOT_FINITE
	if ratio == 0.0:
		return DATA.S_LINK_ZERO
	var a := _key(str(driver.get("joint", "")), int(driver.get("dof", 0)))
	var b := _key(str(follower.get("joint", "")), int(follower.get("dof", 0)))
	if a == b:
		return DATA.S_LINK_SELF
	for node in [a, b]:
		var parts: PackedStringArray = node.split("|")
		var joint := _joint(assembly, parts[0])
		if joint.is_empty() or int(parts[1]) < 0 or int(parts[1]) >= (joint.get("dofs", []) as Array).size():
			return "Pick a joint DOF to link."
	var tree := _Tree.new(assembly)
	if tree.parent.has(b):
		return DATA.fill(DATA.S_LINK_SECOND_DRIVER, {"Joint": tree.name_of(b), "Driver": tree.name_of(str(tree.parent[b].node))})
	# A circle: the driver already follows the follower (directly or down a chain).
	var at := a
	var guard := 0
	while tree.parent.has(at) and guard < 10000:
		at = str(tree.parent[at].node)
		guard += 1
		if at == b:
			break
	if at == b:
		return DATA.fill(DATA.S_LINK_CIRCLE, {"Joint": tree.name_of(b), "Other": tree.name_of(a)})
	# The limits through the new link (its offset captured as new_link() does) must leave a value.
	var parts_a := a.split("|")
	var parts_b := b.split("|")
	var driver_value: float = JOINT_MATH.joint_values(_joint(assembly, parts_a[0]))[int(parts_a[1])]
	var follower_value: float = JOINT_MATH.joint_values(_joint(assembly, parts_b[0]))[int(parts_b[1])]
	var trial := assembly.duplicate()
	var links: Array = (assembly.get("links", []) as Array).duplicate()
	links.append({"driver": {"joint": parts_a[0], "dof": int(parts_a[1])}, "follower": {"joint": parts_b[0], "dof": int(parts_b[1])},
		"ratio": ratio, "offset": follower_value - ratio * driver_value})
	trial["links"] = links
	var trial_tree := _Tree.new(trial)
	var span := _interval(trial_tree, trial_tree.root_of(a))
	if str(span.reversed) == "" and float(span.low) > float(span.high):
		return DATA.fill(DATA.S_LINK_EMPTY_NEW, {"Joint": trial_tree.name_of(a), "A": trial_tree.name_of(str(span.low_by[0])), "B": trial_tree.name_of(str(span.high_by[0]))})
	return ""


## Makes a link in assembly (a normalized copy the caller stores): {"link": the entry} or
## {"error": sentence}. The offset is captured from the stored values (offset = follower −
## ratio · driver), so making the link moves nothing.
static func new_link(assembly: Dictionary, driver: Dictionary, follower: Dictionary, ratio: float) -> Dictionary:
	var refusal := link_refusal(assembly, driver, follower, ratio)
	if refusal != "":
		return {"error": refusal}
	var driver_value: float = JOINT_MATH.joint_values(_joint(assembly, str(driver.joint)))[int(driver.dof)]
	var follower_value: float = JOINT_MATH.joint_values(_joint(assembly, str(follower.joint)))[int(follower.dof)]
	var id := DATA.new_id(assembly, "link")
	var link := DATA.LINK_DEFAULT.duplicate(true)
	link["id"] = id
	link["name"] = DATA.name_for("link", id)
	link["driver"] = {"joint": str(driver.joint), "dof": int(driver.dof)}
	link["follower"] = {"joint": str(follower.joint), "dof": int(follower.dof)}
	link["ratio"] = ratio
	link["offset"] = follower_value - ratio * driver_value
	(assembly.links as Array).append(link)
	return {"link": link}


## A ratio for a sentence ("2:1", "-0.5:1").
static func format_ratio(ratio: float) -> String:
	var text := String.num(snappedf(ratio, 1e-4), 4)
	if text.contains("."):
		text = text.rstrip("0").rstrip(".")
	return text + ":1"


# --- Motion Study (C6) ---------------------------------------------------------------------------

## Why a study key cannot go on (joint_id, dof), or "" (S-STUDY-FOLLOWER on a follower).
static func study_key_refusal(assembly: Dictionary, joint_id: String, dof: int) -> String:
	var refusal := DATA.edit_refusal(assembly)
	if refusal != "":
		return refusal
	var tree := _Tree.new(assembly)
	var node := _key(joint_id, dof)
	if tree.parent.has(node):
		var link: Dictionary = tree.parent[node].link
		return DATA.fill(DATA.S_STUDY_FOLLOWER, {
			"Joint": tree.name_of(node), "Driver": tree.name_of(str(tree.parent[node].node)), "Link": str(link.get("name", link.get("id", ""))),
		})
	return ""


## Why a study (an entry of the normalized assembly) cannot be played as stored, or "" (fix round
## 2, PT1): S-STORED-NOT-FINITE for its length, fps, or a key's time or value that is not finite
## (Item: the study's name; key "length", "fps", "key time", "key value") or a number of a keyed
## joint (or of a joint linked to it) that is not finite; S-STUDY-KEY-TWICE for two keys of one
## DOF at one time (a motion cannot jump); limits_refusal() for a keyed DOF's limits. Keys on no
## joint DOF, or on a follower, are left to study_frames() (left out, warned).
static func study_refusal(assembly: Dictionary, study: Dictionary, units := "mm") -> String:
	var study_name := str(study.get("name", study.get("id", "")))
	for key_name in ["length", "fps"]:
		var value: Variant = study.get(key_name, 0.0)
		if (value is float or value is int) and not is_finite(float(value)):
			return DATA.fill(DATA.S_STORED_NOT_FINITE, {"Item": study_name, "key": key_name, "value": DATA.not_finite_text(float(value))})
	var tree := _Tree.new(assembly)
	var times := {}
	var checked := {}
	for key in study.get("keys", []):
		if not (key is Dictionary):
			continue
		for field in ["time", "value"]:
			var value: Variant = key.get(field, 0.0)
			if (value is float or value is int) and not is_finite(float(value)):
				return DATA.fill(DATA.S_STORED_NOT_FINITE, {"Item": study_name, "key": "key " + field, "value": DATA.not_finite_text(float(value))})
		var joint_id := str(key.get("joint", ""))
		var dof := int(key.get("dof", 0))
		var joint := _joint(assembly, joint_id)
		if joint.is_empty() or dof < 0 or dof >= (joint.get("dofs", []) as Array).size() or tree.parent.has(_key(joint_id, dof)):
			continue
		var node := _key(joint_id, dof)
		var time := float(key.get("time", 0.0))
		if not times.has(node):
			times[node] = {}
		if (times[node] as Dictionary).has(time):
			return DATA.fill(DATA.S_STUDY_KEY_TWICE, {"Joint": tree.name_of(node), "time": _seconds(time), "Study": study_name})
		times[node][time] = true
		if checked.has(node):
			continue
		checked[node] = true
		for member: String in tree.below(node):
			var bad := DATA.joint_not_finite(_joint(assembly, member.get_slice("|", 0)))
			if bad != "":
				return bad
		var limits := limits_refusal(assembly, joint_id, units)
		if limits != "":
			return limits
	return ""


## The number of frames a study has: ceil(length · fps) + 1 (C6).
static func frame_count(study: Dictionary) -> int:
	var length := clampf(float(study.get("length", 5.0)), STUDY_LENGTH_MIN, STUDY_LENGTH_MAX)
	var fps := clampi(int(study.get("fps", 30)), STUDY_FPS_MIN, STUDY_FPS_MAX)
	return int(ceil(length * fps - 1e-9)) + 1


## A study's frames, worked out up front (C6): {"frames": [{"time", "body_poses", "poses",
## "values": {joint_id: PackedFloat64Array}}], "stopped_at": the contact stop's time or -1,
## "sentence", "warnings": PackedStringArray, "ms"}. Keys on followers are left out (and warned),
## keys beyond a limit play at the limit (S-STUDY-CLAMPED). Refused up front with
## S-STUDY-TOO-SLOW when it cannot fit in STUDY_SECONDS (options "seconds" overrides that for
## tests); a run past the deadline stops there with the same sentence.
## With the study's "contact" on, CONTACT.sweep runs along time first (sharing the deadline): at a
## stop, "stopped_at" is the last clear time, "sentence" S-STUDY-STOP (or S-CONTACT-TIMEOUT), and
## every frame after it holds the pose at stopped_at; a sweep refused up front (S-CONTACT-STEPS,
## S-CONTACT-TOO-SLOW) gives no frames and its sentence. The sweep's warnings join "warnings".
## A study study_refusal() refuses (numbers that are not finite, two keys of a DOF at one time,
## reversed limits) gives no frames and that sentence. Each track moves only its own link tree's
## DOFs (two tracks on one joint's two DOFs both play). The sweep's turning counts only rotation
## DOFs that turn a contact pair (_turning()).
static func study_frames(doc: Resource, result: Dictionary, kernel: RefCounted, study_id: String, options := {}) -> Dictionary:
	var started := Time.get_ticks_usec()
	var limit_s := float(options.get("seconds", STUDY_SECONDS))
	var out := {"frames": [], "stopped_at": -1.0, "sentence": "", "warnings": PackedStringArray(), "ms": 0.0}
	var assembly: Dictionary = DATA.normalized(doc.assembly if doc.assembly is Dictionary else {})
	var study := {}
	for entry in assembly.studies:
		if entry is Dictionary and str(entry.get("id", "")) == study_id:
			study = entry
	if study.is_empty():
		out["sentence"] = "There is no such Motion Study."
		return out
	var refusal_up_front := study_refusal(assembly, study, str(doc.units))
	if refusal_up_front != "":
		out["sentence"] = refusal_up_front
		out["ms"] = float(Time.get_ticks_usec() - started) / 1000.0
		return out
	var length := clampf(float(study.get("length", 5.0)), STUDY_LENGTH_MIN, STUDY_LENGTH_MAX)
	var fps := clampi(int(study.get("fps", 30)), STUDY_FPS_MIN, STUDY_FPS_MAX)
	var count := frame_count(study)
	var units := str(doc.units)
	var tree := _Tree.new(assembly)
	# Keys per DOF, sorted by time; followers' keys refused, keys beyond limits warned.
	var tracks := {}
	for key in study.get("keys", []):
		if not (key is Dictionary):
			continue
		var node := _key(str(key.get("joint", "")), int(key.get("dof", 0)))
		var joint := _joint(assembly, str(key.get("joint", "")))
		if joint.is_empty() or int(key.get("dof", 0)) >= (joint.get("dofs", []) as Array).size():
			continue
		var refusal := study_key_refusal(assembly, str(key.joint), int(key.get("dof", 0)))
		if refusal != "":
			if not out.warnings.has(refusal):
				out.warnings.append(refusal)
			continue
		var d := tree.dof_of(node)
		var value := float(key.get("value", 0.0))
		var clamped := JOINT_MATH.clamp_value(d, value)
		if clamped != value:
			out.warnings.append(DATA.fill(DATA.S_STUDY_CLAMPED, {
				"Joint": tree.name_of(node), "time": _seconds(float(key.get("time", 0.0))), "value": tree.format(node, value, units),
				"limit": tree.format(node, clamped, units),
			}))
		if not tracks.has(node):
			tracks[node] = []
		tracks[node].append([float(key.get("time", 0.0)), value])
	for node in tracks:
		(tracks[node] as Array).sort_custom(func(p: Array, q: Array) -> bool: return p[0] < q[0])
	# Frame 0 measures one solve; the estimate for all frames must fit.
	var first := _study_frame(doc, result, kernel, assembly, tree, tracks, 0.0, units)
	var one_s := float(Time.get_ticks_usec() - started) / 1e6
	var estimate := one_s * count
	if estimate > limit_s:
		out["sentence"] = DATA.fill(DATA.S_STUDY_TOO_SLOW, {"s": _seconds(estimate)})
		out["ms"] = float(Time.get_ticks_usec() - started) / 1000.0
		return out
	# Contact (C6): the sweep runs along time first; frames after its stop hold the stopped pose.
	var stop_frame := {}
	if bool(study.get("contact", false)):
		var path := func(t: float) -> Dictionary:
			return _study_frame(doc, result, kernel, assembly, tree, tracks, t, units).body_poses
		var spent := float(Time.get_ticks_usec() - started) / 1e6
		# Every key time is sampled, and the turn between two times is the tracks' own.
		var key_times := PackedFloat64Array()
		for node in tracks:
			for key: Array in tracks[node]:
				key_times.append(float(key[0]))
		var turning := _turning(doc, result, kernel, assembly, tree, tracks.keys())
		# limit_seconds: the study's whole contact time, what the frames' estimate leaves (fix round 4).
		var swept := CONTACT.sweep(doc, result, kernel, path, 0.0, length, {
			"assembly": assembly, "seconds": maxf(limit_s - spent - estimate, 0.0), "deadline_usec": started + int(limit_s * 1e6),
			"limit_seconds": maxf(limit_s - estimate, 0.0),
			"study": true, "format": func(t: float) -> String: return _seconds(t), "turn": _study_turn(tree, tracks, turning),
			"split_times": key_times, "turn_between": func(a: float, b: float) -> float: return _study_turn_between(tree, tracks, a, b, turning),
		})
		out.warnings.append_array(swept.warnings)
		if bool(swept.refused):
			out["sentence"] = swept.sentence
			out["ms"] = float(Time.get_ticks_usec() - started) / 1000.0
			return out
		if bool(swept.stopped):
			out["stopped_at"] = float(swept.reached)
			out["sentence"] = swept.sentence
			stop_frame = _study_frame(doc, result, kernel, assembly, tree, tracks, float(swept.reached), units)
	out.frames.append(first)
	for k in range(1, count):
		if float(Time.get_ticks_usec() - started) / 1e6 > limit_s:
			out["sentence"] = DATA.fill(DATA.S_STUDY_TOO_SLOW, {"s": _seconds(estimate)})
			out.frames.clear()
			break
		var time := minf(float(k) / float(fps), length)
		if not stop_frame.is_empty() and time > float(out.stopped_at):
			out.frames.append({"time": time, "body_poses": stop_frame.body_poses, "poses": stop_frame.poses, "values": stop_frame.values})
			continue
		out.frames.append(_study_frame(doc, result, kernel, assembly, tree, tracks, time, units))
	out["ms"] = float(Time.get_ticks_usec() - started) / 1000.0
	return out


## The most any unit may turn over a study (radians): each track's total change, through its link
## tree's rotation DOFs (as _turn(), with turning).
static func _study_turn(tree: _Tree, tracks: Dictionary, turning: Variant = null) -> float:
	var turn := 0.0
	for node: String in tracks:
		var track: Array = tracks[node]
		for i in range(1, track.size()):
			turn += _turn(tree, node, float(track[i - 1][1]), float(track[i][1]), turning)
	return turn


## The most any unit turns from time a to time b of a study (radians): each track's change over
## its keys between a and b, through its link tree's rotation DOFs (as _turn(), with turning).
static func _study_turn_between(tree: _Tree, tracks: Dictionary, a: float, b: float, turning: Variant = null) -> float:
	var low := minf(a, b)
	var high := maxf(a, b)
	var turn := 0.0
	for node: String in tracks:
		var track: Array = tracks[node]
		var value := track_value(track, low)
		# (Only the keys inside (low, high), found by bisection: N-B, studies of thousands of keys.)
		var i := _first_after(track, low)
		while i < track.size() and float(track[i][0]) < high:
			var next := float(track[i][1])
			turn += _turn(tree, node, value, next, turning)
			value = next
			i += 1
		turn += _turn(tree, node, value, track_value(track, high), turning)
	return turn


## The index of a sorted track's first key whose time is above time (track.size() when none).
static func _first_after(track: Array, time: float) -> int:
	var lo := 0
	var hi := track.size()
	while lo < hi:
		var mid := (lo + hi) >> 1
		if float(track[mid][0]) > time:
			hi = mid
		else:
			lo = mid + 1
	return lo


## The value a track (sorted [[time, value]]) has at time: linear between keys, held outside.
## (The key interval is found by bisection.)
static func track_value(track: Array, time: float) -> float:
	if track.is_empty():
		return 0.0
	if time <= float(track[0][0]):
		return float(track[0][1])
	var last: Array = track[track.size() - 1]
	if time >= float(last[0]):
		return float(last[1])
	# The first key at or after time (index 1 or more: time is above the first key's).
	var lo := 1
	var hi := track.size() - 1
	while lo < hi:
		var mid := (lo + hi) >> 1
		if float(track[mid][0]) >= time:
			hi = mid
		else:
			lo = mid + 1
	var p: Array = track[lo - 1]
	var q: Array = track[lo]
	var span := float(q[0]) - float(p[0])
	if span <= 0.0:
		return float(q[1])
	return float(p[1]) + (float(q[1]) - float(p[1])) * ((time - float(p[0])) / span)


static func _study_frame(doc: Resource, result: Dictionary, kernel: RefCounted, assembly: Dictionary, tree: _Tree, tracks: Dictionary,
		time: float, units: String) -> Dictionary:
	var values := {}
	for node in tracks:
		var target := track_value(tracks[node], time)
		var parts: PackedStringArray = str(node).split("|")
		var moved := move(assembly, parts[0], int(parts[1]), target, units)
		# (N1: only the DOFs of this track's link tree; another track's DOFs of the same joint stay.)
		for member: String in tree.below(tree.root_of(str(node))):
			var member_parts := member.split("|")
			var id := member_parts[0]
			if not (moved.values as Dictionary).has(id):
				continue
			if not values.has(id):
				values[id] = PackedFloat64Array(moved.values[id])
			var list: PackedFloat64Array = values[id]
			list[int(member_parts[1])] = float((moved.values[id] as PackedFloat64Array)[int(member_parts[1])])
			values[id] = list
	var overrides := {}
	for id in values:
		var forced := {}
		var list: PackedFloat64Array = values[id]
		for i in list.size():
			forced[i] = list[i]
		overrides[id] = forced
	var solved := SOLVER.solve(doc, result, kernel, overrides)
	var all_values := {}
	for id in solved.joints:
		all_values[id] = solved.joints[id].values
	return {"time": time, "body_poses": solved.body_poses, "poses": solved.poses, "values": all_values}


static func _seconds(value: float) -> String:
	var text := String.num(snappedf(value, 0.01), 2)
	if text.contains("."):
		text = text.rstrip("0").rstrip(".")
	return text + " s"


# --- Link trees ----------------------------------------------------------------------------------

static func _key(joint_id: String, dof: int) -> String:
	return "%s|%d" % [joint_id, dof]


## A joint entry of a normalized assembly by id, or {}.
static func _joint(assembly: Dictionary, joint_id: String) -> Dictionary:
	for joint in assembly.get("joints", []):
		if joint is Dictionary and str(joint.get("id", "")) == joint_id:
			return joint
	return {}


## The links of an assembly as trees of DOF nodes ("joint|dof").
class _Tree:
	extends RefCounted
	var assembly: Dictionary
	## follower node -> {"node": driver node, "ratio", "offset", "link"}
	var parent := {}
	## driver node -> [follower nodes]
	var children := {}
	## Links left out because their ratio or offset is not finite: [driver node, follower node, name].
	var bad := []

	func _init(source: Dictionary) -> void:
		assembly = source
		for link in source.get("links", []):
			if not (link is Dictionary):
				continue
			var driver: Dictionary = link.get("driver", {}) if link.get("driver") is Dictionary else {}
			var follower: Dictionary = link.get("follower", {}) if link.get("follower") is Dictionary else {}
			var a := "%s|%d" % [str(driver.get("joint", "")), int(driver.get("dof", 0))]
			var b := "%s|%d" % [str(follower.get("joint", "")), int(follower.get("dof", 0))]
			var ratio := float(link.get("ratio", 1.0))
			if not is_finite(ratio) or not is_finite(float(link.get("offset", 0.0))):
				# (Left out: drives that touch it are refused, S-LINK-NOT-FINITE.)
				bad.append([a, b, str(link.get("name", link.get("id", "")))])
				continue
			if a == b or ratio == 0.0 or parent.has(b):
				continue
			parent[b] = {"node": a, "ratio": ratio, "offset": float(link.get("offset", 0.0)), "link": link}
			if not children.has(a):
				children[a] = []
			children[a].append(b)

	## The name of a left-out (not finite) link at either end of which a DOF of node's tree sits, or
	## "".
	func bad_link_near(node: String) -> String:
		if bad.is_empty():
			return ""
		var members := below(root_of(node))
		for entry: Array in bad:
			if members.has(entry[0]) or members.has(entry[1]):
				return str(entry[2])
		return ""

	## The root of node's tree (node itself when nothing drives it).
	func root_of(node: String) -> String:
		var at := node
		var guard := 0
		while parent.has(at) and guard < 10000:
			at = str(parent[at].node)
			guard += 1
		return at

	## node and every DOF that follows it, directly or down a chain (node first).
	func below(node: String) -> Array:
		var out := [node]
		var head := 0
		while head < out.size():
			for child in children.get(out[head], []):
				if not out.has(child):
					out.append(child)
			head += 1
		return out

	## The value of every node below root when root holds value (link by link down the tree).
	func down(root: String, value: float) -> Dictionary:
		var values := {root: value}
		for node in below(root):
			if node == root:
				continue
			var link: Dictionary = parent[node]
			values[node] = float(link.ratio) * float(values[link.node]) + float(link.offset)
		return values

	## The root value that gives node the value value (back up the links one by one).
	func up(node: String, root: String, value: float) -> float:
		var at := node
		var v := value
		var guard := 0
		while at != root and parent.has(at) and guard < 10000:
			var link: Dictionary = parent[at]
			v = (v - float(link.offset)) / float(link.ratio)
			at = str(link.node)
			guard += 1
		return v

	## d node / d ancestor (the product of the ratios between them); 1 for the node itself.
	func slope(node: String, ancestor: String) -> float:
		var at := node
		var s := 1.0
		var guard := 0
		while at != ancestor and parent.has(at) and guard < 10000:
			s *= float(parent[at].ratio)
			at = str(parent[at].node)
			guard += 1
		if at != ancestor:
			# ancestor is below node: the inverse.
			var back := 1.0
			at = ancestor
			guard = 0
			while at != node and parent.has(at) and guard < 10000:
				back *= float(parent[at].ratio)
				at = str(parent[at].node)
				guard += 1
			return 1.0 / back if back != 0.0 else 0.0
		return s

	## The stored DOF entry of a node ({} when the joint or DOF is gone).
	func dof_of(node: String) -> Dictionary:
		var parts := node.split("|")
		for joint in assembly.get("joints", []):
			if joint is Dictionary and str(joint.get("id", "")) == parts[0]:
				var dofs: Array = joint.get("dofs", [])
				var i := int(parts[1])
				return dofs[i] if i >= 0 and i < dofs.size() and dofs[i] is Dictionary else {}
		return {}

	func type_of(node: String) -> String:
		var parts := node.split("|")
		for joint in assembly.get("joints", []):
			if joint is Dictionary and str(joint.get("id", "")) == parts[0]:
				return str(joint.get("type", ""))
		return ""

	func name_of(node: String) -> String:
		var parts := node.split("|")
		for joint in assembly.get("joints", []):
			if joint is Dictionary and str(joint.get("id", "")) == parts[0]:
				var joint_name := str(joint.get("name", parts[0]))
				var names: Array = DATA.dof_names(str(joint.get("type", "")))
				return joint_name if names.size() <= 1 else "%s (%s)" % [joint_name, str(names[int(parts[1])]) if int(parts[1]) < names.size() else parts[1]]
		return parts[0]

	func format(node: String, value: float, units: String) -> String:
		var parts := node.split("|")
		return JOINT_MATH.format_dof(type_of(node), int(parts[1]), value, units)
