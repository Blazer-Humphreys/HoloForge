@tool
extends RefCounted
## Godot joints for a baked assembly (Holo Forge Phase 8, contract C8.5).
##
## When a CadPart bakes its components as RigidBody3D (nodes/cad_part.gd, C8.4), every resolved,
## unsuppressed joint becomes a Godot Joint3D under a "Joints" node, and every rigid group a locked
## Generic6DOFJoint3D per member: revolute -> HingeJoint3D, slider -> SliderJoint3D, ball ->
## ConeTwistJoint3D, the rest -> Generic6DOFJoint3D with locked axes. node_a is the base side (b),
## node_b the moving side (a), as "../../<Comp>"; a side on the ground is NodePath("") (Jolt: the
## world).
##
## Engine facts this mapping rests on (tests/holo_forge_assembly_bake_test.gd V1-V8, Godot 4.7.1
## with Jolt Physics, measured 2026-11-13):
##   - a Godot joint measures from the pose the bodies have when it is set up (the bake pose), so
##     limits are shifted by the value v_b each DOF has there;
##   - the hinge turns about the joint node's local Z; the slider slides along local X; the cone
##     twist joint twists about local X and swings about Y and Z, with symmetric half-angle spans;
##   - angular limits (hinge and 6DOF) count node_b turning about the axis the other way round: a
##     node_b turning +θ about +Z reads -θ. Linear limits count along +axis. So a moving side that
##     turns by +Δv about Z gets lower = v_b - max, upper = v_b - min;
##   - hinge limits at -π and +π leave it free; one end at ±π stops it half a turn away;
##   - a 6DOF angular Z range of ±120° holds.
##
## The joint node sits at W · T(t(v_b)) · R_map, where W is the solver's joint frame
## (P_b · F_b · O), t(v_b) the slide part of M at the bake values and R_map the axis remap below.
## Moving the frame along the slide makes Godot's zero the bake pose without turning the slot
## (pin-slot, planar), so the slide stays along a fixed axis of the joint node.
## After setting them, every property is read back and compared (C8.5); a mismatch is an error in
## the bake report.

const XFORM := preload("res://addons/holo_forge/core/assembly/xform64.gd")
const DATA := preload("res://addons/holo_forge/core/assembly/assembly_data.gd")
const JOINT_MATH := preload("res://addons/holo_forge/core/assembly/joint_math.gd")
const SOLVER := preload("res://addons/holo_forge/core/assembly/solver.gd")

## The node holding the baked joints (a direct child of the part, at identity).
const JOINTS_NAME := "Joints"
## On the Joints node.
const JOINTS_META := "holo_forge_joints"
## On a baked joint node: the joint's id (a rigid group's: "group:<group id>:<component id>").
const JOINT_META := "holo_forge_joint"
## A slider's open end, and a half-limited 6DOF slide's (meters): Godot's slider has no off switch.
const OPEN_LINEAR := 1e4
## How far a value read back from a joint node may be from the one set.
const READBACK_TOLERANCE := 1e-6
## Loop joints off by more than this (m, rad) at the bake pose get a note.
const LOOP_NOTE := 1e-6

## Sentences the bake adds that the spec's C10 table does not have (reported as Stage 2 additions).
const S_BAKE_LOOP_OFF := "<Joint> closes a loop that is off by <d> and <a> at the bake pose; Godot holds it with that offset."
const S_BAKE_SKIPPED := "<Joint> is not baked: <reason>."
const S_BAKE_READBACK := "<Joint>: <property> reads back as <got>, not <want>. This is a Holo Forge fault; please report it."
const S_BAKE_GROUND_MOVES := "<Joint> moves the ground side, so Godot measures it from <Comp>; the limits of its <what> were left open."

## Test seam (5.7 #10): when not "", the physics engine name the bake checks instead of the
## project's. Never set outside tests.
static var engine_name_override := ""

## R_map for a slider: turns the slide axis onto the joint node's local X (columns X, Y, Z).
const SLIDE_TO_X := {
	"x": [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0],
	"y": [0.0, 1.0, 0.0, -1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0],
	"z": [0.0, 0.0, 1.0, 0.0, 1.0, 0.0, -1.0, 0.0, 0.0, 0.0, 0.0, 0.0],
}


## The 3D physics engine the project runs ("Jolt Physics", "GodotPhysics3D", ...).
static func engine_name() -> String:
	if engine_name_override != "":
		return engine_name_override
	return str(ProjectSettings.get_setting("physics/3d/physics_engine", ""))


static func is_jolt() -> bool:
	return engine_name().to_lower().contains("jolt")


## The Godot form of one joint: {"class": the Joint3D class, "transform": xform64 (part space),
## "props": {property path: value} (everything set, read back after), "notes": PackedStringArray}.
## entry is the joint's solve output (C3.1: "world", "values", "implied" for a loop); inverted is
## true when the moving side (a) is the ground and the base side (b) a unit, so node_b is b and
## every motion reads the other way round. units: the document's length unit (for sentences).
static func settings(joint: Dictionary, entry: Dictionary, units: String, inverted := false, base_name := "") -> Dictionary:
	var joint_type := str(joint.get("type", DATA.DEFAULT_TYPE))
	var joint_name := str(joint.get("name", joint.get("id", "")))
	var axis := JOINT_MATH.slide_axis(joint)
	var dofs: Array = joint.get("dofs", [])
	var values := PackedFloat64Array(entry.get("implied", PackedFloat64Array())) if str(entry.get("state", "")) == SOLVER.STATE_LOOP else PackedFloat64Array()
	if values.size() != dofs.size():
		values = PackedFloat64Array(entry.get("values", PackedFloat64Array()))
	while values.size() < dofs.size():
		values.append(0.0)
	var world: PackedFloat64Array = PackedFloat64Array(entry.get("world", XFORM.identity()))
	var out := {"class": "Generic6DOFJoint3D", "transform": world, "props": {}, "notes": PackedStringArray()}
	# The joint frame: on side b at the slide's bake value (normal), or on side a, the fixed side
	# (inverted: W · M(v_b)).
	var r_map := XFORM.identity()
	match joint_type:
		"slider":
			r_map = PackedFloat64Array(SLIDE_TO_X.get(axis, SLIDE_TO_X.z))
		"ball":
			r_map = PackedFloat64Array(SLIDE_TO_X.z)
	var m_bake := JOINT_MATH.motion(joint_type, axis, values)
	var at := XFORM.compose(world, m_bake) if inverted else XFORM.compose(world, XFORM.translation(m_bake[9], m_bake[10], m_bake[11]))
	out["transform"] = XFORM.compose(at, r_map)
	# Godot reads a turn of node_b about +axis as negative (V2, V5), a slide as positive (V3); an
	# inverted joint reads both the other way round.
	var turn_sign := 1.0 if inverted else -1.0
	var slide_sign := -1.0 if inverted else 1.0
	var props: Dictionary = out.props
	# (An Array: helpers add to it; a packed array would be copied.)
	var notes := []
	var dof := func(i: int) -> Dictionary: return dofs[i] if i < dofs.size() and dofs[i] is Dictionary else DATA.DOF_DEFAULT
	match joint_type:
		"revolute":
			out["class"] = "HingeJoint3D"
			var limits := _range(dof.call(0), values[0], turn_sign, true, joint_name, notes)
			props["angular_limit/enable"] = bool(limits.limited)
			if bool(limits.limited):
				props["angular_limit/lower"] = float(limits.lower)
				props["angular_limit/upper"] = float(limits.upper)
		"slider":
			out["class"] = "SliderJoint3D"
			var limits := _range(dof.call(0), values[0], slide_sign, false, joint_name, notes, units)
			props["linear_limit/lower_distance"] = float(limits.lower) if bool(limits.limited) else -OPEN_LINEAR
			props["linear_limit/upper_distance"] = float(limits.upper) if bool(limits.limited) else OPEN_LINEAR
		"ball":
			out["class"] = "ConeTwistJoint3D"
			_cone(joint_name, [dof.call(0), dof.call(1), dof.call(2)], values, props, notes)
		_:
			# Generic6DOFJoint3D: every axis locked, then the type's free ones opened or limited.
			for letter in ["x", "y", "z"]:
				props["linear_limit_%s/enabled" % letter] = true
				props["linear_limit_%s/lower_distance" % letter] = 0.0
				props["linear_limit_%s/upper_distance" % letter] = 0.0
				props["angular_limit_%s/enabled" % letter] = true
				props["angular_limit_%s/lower_angle" % letter] = 0.0
				props["angular_limit_%s/upper_angle" % letter] = 0.0
			var free := []
			match joint_type:
				"cylindrical":
					free = [["linear", "z", 0], ["angular", "z", 1]]
				"pin_slot":
					free = [["angular", "z", 0], ["linear", axis, 1]]
				"planar":
					free = [["linear", "x", 0], ["linear", "y", 1], ["angular", "z", 2]]
			# An inverted pin-slot or planar joint: the slot turns with the moving base, which a
			# 6DOF joint fixed to the world cannot follow exactly; its plane stays free, unlimited.
			var loose := inverted and joint_type in ["pin_slot", "planar"]
			if loose:
				free = [["linear", "x", -1], ["linear", "y", -1], ["angular", "z", -1]]
				notes.append(DATA.fill(S_BAKE_GROUND_MOVES, {"Joint": joint_name, "Comp": base_name, "what": "slide and turn"}))
			for item in free:
				var kind: String = item[0]
				var letter: String = item[1]
				var i: int = item[2]
				var limits := {"limited": false} if i < 0 else _range(dof.call(i), values[i], turn_sign if kind == "angular" else slide_sign, kind == "angular", joint_name, notes, units)
				var key := "%s_limit_%s" % [kind, letter]
				props[key + "/enabled"] = bool(limits.limited)
				var low_key := key + ("/lower_angle" if kind == "angular" else "/lower_distance")
				var high_key := key + ("/upper_angle" if kind == "angular" else "/upper_distance")
				if bool(limits.limited):
					props[low_key] = float(limits.lower)
					props[high_key] = float(limits.upper)
				else:
					props.erase(low_key)
					props.erase(high_key)
	out["notes"] = PackedStringArray(notes)
	return out


## A DOF's Godot range from its limits at the bake value v_b: {"limited": bool, "lower", "upper"}.
## direction: how Godot reads the DOF (+1: lower = min - v_b; -1: lower = v_b - max). A half-limited DOF
## gets ±π (angles) or ±OPEN_LINEAR (slides) at its open end, and an angle range is clipped to
## [-π, π], each with S-BAKE-HALF-LIMIT in notes. Unlimited: limited false.
static func _range(dof: Dictionary, v_b: float, direction: float, angular: bool, joint_name: String, notes: Array, units := "mm") -> Dictionary:
	var has_min := bool(dof.get("limited_min", false))
	var has_max := bool(dof.get("limited_max", false))
	if not has_min and not has_max:
		return {"limited": false, "lower": 0.0, "upper": 0.0}
	var open := PI if angular else OPEN_LINEAR
	# The ends in Godot's reading, before the sign: from min - v_b to max - v_b.
	var low := float(dof.get("min", 0.0)) - v_b if has_min else -INF
	var high := float(dof.get("max", 0.0)) - v_b if has_max else INF
	var lower := low if direction > 0.0 else -high
	var upper := high if direction > 0.0 else -low
	var said := false
	if is_inf(lower) or (angular and lower < -PI):
		lower = -open
		said = true
	if is_inf(upper) or (angular and upper > PI):
		upper = open
		said = true
	if said:
		var shown := PackedStringArray()
		for end in [lower, upper]:
			if absf(end) == open:
				shown.append(JOINT_MATH.format_angle(end) if angular else JOINT_MATH.format_length(end, units))
		notes.append(DATA.fill(DATA.S_BAKE_HALF_LIMIT, {"Joint": joint_name, "value": " and ".join(shown)}))
	return {"limited": true, "lower": lower, "upper": upper}


## A ball joint's cone: twist_span from rot_z, swing_span from rot_x and rot_y (each the largest
## distance from the bake value to an end; an open end is π). Anything a symmetric cone does not
## hold exactly is widened with S-BAKE-CONE-WIDENED.
static func _cone(joint_name: String, dofs: Array, values: PackedFloat64Array, props: Dictionary, notes: Array) -> void:
	var spans := []
	var exact := true
	for i in 3:
		var dof: Dictionary = dofs[i]
		var has_min := bool(dof.get("limited_min", false))
		var has_max := bool(dof.get("limited_max", false))
		if not has_min and not has_max:
			spans.append(PI)
			continue
		var low := float(dof.get("min", 0.0)) - values[i] if has_min else -PI
		var high := float(dof.get("max", 0.0)) - values[i] if has_max else PI
		var span := minf(maxf(absf(low), absf(high)), PI)
		if not (has_min and has_max) or absf(low + high) > 1e-12 or span != maxf(absf(low), absf(high)):
			exact = false
		spans.append(span)
	var swing := maxf(float(spans[0]), float(spans[1]))
	var twist := float(spans[2])
	if float(spans[0]) != float(spans[1]):
		exact = false
	props["swing_span"] = swing
	props["twist_span"] = twist
	if not exact:
		notes.append(DATA.fill(DATA.S_BAKE_CONE_WIDENED, {"Joint": joint_name, "swing": JOINT_MATH.format_angle(swing), "twist": JOINT_MATH.format_angle(twist)}))


## A locked Generic6DOFJoint3D's settings (rigid joints, rigid groups).
static func locked_props() -> Dictionary:
	var props := {}
	for letter in ["x", "y", "z"]:
		for kind in ["linear", "angular"]:
			var key := "%s_limit_%s" % [kind, letter]
			props[key + "/enabled"] = true
			props[key + ("/lower_angle" if kind == "angular" else "/lower_distance")] = 0.0
			props[key + ("/upper_angle" if kind == "angular" else "/upper_distance")] = 0.0
	return props


## Brings the part's Joints node up to date (C8.4): one node per resolved, unsuppressed joint
## between two units (or a unit and the ground), and a locked Generic6DOFJoint3D per rigid group
## member. enabled false removes the Joints node. solved: the bake pose's solve (C3.1); unit_nodes:
## top-level component id -> its RigidBody3D. Notes and errors go into report ("notes", "errors").
## Returns the Joints node (null when there is none).
static func sync(part: Node3D, doc: Resource, solved: Dictionary, unit_nodes: Dictionary, scene_owner: Node, enabled: bool, report: Dictionary) -> Node3D:
	var holder: Node3D = null
	for child in part.get_children():
		if child.has_meta(JOINTS_META):
			holder = child
	if not enabled:
		if holder != null:
			part.remove_child(holder)
			holder.queue_free()
		return null
	if holder == null:
		holder = Node3D.new()
		holder.set_meta(JOINTS_META, true)
		holder.name = JOINTS_NAME
		part.add_child(holder)
		holder.owner = scene_owner
	holder.transform = Transform3D.IDENTITY
	# (After the component nodes: a scene that is loaded sets the joints up after their bodies.)
	part.move_child(holder, part.get_child_count() - 1)
	var existing := {}
	for child in holder.get_children():
		if child is Joint3D and child.has_meta(JOINT_META):
			existing[str(child.get_meta(JOINT_META))] = child
	var assembly: Dictionary = DATA.normalized(doc.assembly if doc.assembly is Dictionary else {})
	var components: Dictionary = doc.components
	var units := str(doc.units)
	# (Arrays, written back into report at the end: packed arrays in a Dictionary are values.)
	var notes := Array(report.get("notes", PackedStringArray()))
	var errors := Array(report.get("errors", PackedStringArray()))
	var wanted := []
	var solved_joints: Dictionary = solved.get("joints", {})
	for joint in assembly.joints:
		if not (joint is Dictionary):
			continue
		var id := str(joint.get("id", ""))
		var joint_name := str(joint.get("name", id))
		var entry: Dictionary = solved_joints.get(id, {})
		var state := str(entry.get("state", SOLVER.STATE_UNRESOLVED))
		if state == SOLVER.STATE_SUPPRESSED:
			continue
		if not state in [SOLVER.STATE_OK, SOLVER.STATE_LOOP, SOLVER.STATE_ERROR]:
			notes.append(DATA.fill(S_BAKE_SKIPPED, {"Joint": joint_name, "reason": str(entry.get("sentence", "it is not resolved"))}))
			continue
		var u_a := SOLVER.unit_of(components, str(joint.a.get("component", "")))
		var u_b := SOLVER.unit_of(components, str(joint.b.get("component", "")))
		if u_a == u_b:
			notes.append(DATA.fill(S_BAKE_SKIPPED, {"Joint": joint_name, "reason": "both sides are on %s" % (doc.component_name(u_a) if u_a != "" else "the ground")}))
			continue
		if (u_a != "" and not unit_nodes.has(u_a)) or (u_b != "" and not unit_nodes.has(u_b)):
			notes.append(DATA.fill(S_BAKE_SKIPPED, {"Joint": joint_name, "reason": "a side has no baked body"}))
			continue
		var inverted := u_a == ""
		var made := settings(joint, entry, units, inverted, doc.component_name(u_b) if u_b != "" else "")
		if state == SOLVER.STATE_ERROR and str(entry.get("sentence", "")) != "":
			notes.append(str(entry.sentence))
		if state == SOLVER.STATE_LOOP and (float(entry.get("residual_m", 0.0)) > LOOP_NOTE or float(entry.get("residual_rad", 0.0)) > LOOP_NOTE):
			notes.append(DATA.fill(S_BAKE_LOOP_OFF, {
				"Joint": joint_name, "d": JOINT_MATH.format_length(float(entry.residual_m), units), "a": JOINT_MATH.format_angle(float(entry.residual_rad)),
			}))
		made["key"] = id
		made["name"] = joint_name
		made["node_a"] = _path_to(unit_nodes, "" if inverted else u_b)
		made["node_b"] = _path_to(unit_nodes, u_b if inverted else u_a)
		wanted.append(made)
	for group in assembly.rigid_groups:
		if not (group is Dictionary) or bool(group.get("suppressed", false)):
			continue
		var members: Array = group.get("components", [])
		if members.size() < 2:
			continue
		var first := SOLVER.unit_of(components, str(members[0]))
		for i in range(1, members.size()):
			var member := SOLVER.unit_of(components, str(members[i]))
			var group_name := "%s_%s" % [str(group.get("name", group.get("id", ""))), doc.component_name(str(members[i]))]
			if member == first or not unit_nodes.has(member) or (first != "" and not unit_nodes.has(first)):
				notes.append(DATA.fill(S_BAKE_SKIPPED, {"Joint": group_name, "reason": "its components are not two baked units"}))
				continue
			var pose: PackedFloat64Array = solved.get("poses", {}).get(member, XFORM.identity())
			wanted.append({
				"class": "Generic6DOFJoint3D", "transform": pose, "props": locked_props(), "notes": PackedStringArray(),
				"key": "group:%s:%s" % [str(group.get("id", "")), str(members[i])], "name": group_name,
				"node_a": _path_to(unit_nodes, first), "node_b": _path_to(unit_nodes, member),
			})
	# Joints no longer wanted (or of another class now) go first, so their names are free.
	var keep := {}
	for made in wanted:
		var node: Node = existing.get(made.key)
		if node != null and node.get_class() == str(made["class"]):
			keep[made.key] = node
	for key in existing:
		if not keep.has(key):
			var stale: Node = existing[key]
			holder.remove_child(stale)
			stale.queue_free()
	var used := {}
	for i in wanted.size():
		var made: Dictionary = wanted[i]
		var node: Joint3D = keep.get(made.key)
		if node == null:
			node = ClassDB.instantiate(str(made["class"])) as Joint3D
			node.set_meta(JOINT_META, made.key)
			holder.add_child(node)
			node.owner = scene_owner
		# (In the joints' stored order.)
		holder.move_child(node, i)
		_name_uniquely(holder, node, str(made.name), used)
		node.transform = XFORM.to_transform(made.transform)
		for property in made.props:
			node.set(property, made.props[property])
		node.node_a = made.node_a
		node.node_b = made.node_b
		notes.append_array(Array(made.notes))
		errors.append_array(Array(read_back(node, made)))
	if not wanted.is_empty() and not is_jolt():
		notes.append(DATA.S_BAKE_NOT_JOLT)
	report["notes"] = PackedStringArray(notes)
	report["errors"] = PackedStringArray(errors)
	return holder


## The mismatches (S-BAKE-READBACK sentences) between what made set on node and what it reads back:
## every property within READBACK_TOLERANCE (bools exactly), the node paths and the transform.
static func read_back(node: Joint3D, made: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var joint_name := str(made.get("name", node.name))
	for property in made.props:
		var want: Variant = made.props[property]
		var got: Variant = node.get(property)
		var same := false
		if want is bool:
			same = got is bool and got == want
		else:
			same = (got is float or got is int) and absf(float(got) - float(want)) <= READBACK_TOLERANCE
		if not same:
			out.append(DATA.fill(S_BAKE_READBACK, {"Joint": joint_name, "property": property, "got": str(got), "want": str(want)}))
	for side in ["node_a", "node_b"]:
		if node.get(side) != made[side]:
			out.append(DATA.fill(S_BAKE_READBACK, {"Joint": joint_name, "property": side, "got": str(node.get(side)), "want": str(made[side])}))
	var placed := XFORM.to_transform(made.transform)
	if not node.transform.is_equal_approx(placed):
		out.append(DATA.fill(S_BAKE_READBACK, {"Joint": joint_name, "property": "transform", "got": str(node.transform), "want": str(placed)}))
	return out


## "../../<unit node name>" from a joint under the Joints node; "" for the ground.
static func _path_to(unit_nodes: Dictionary, unit: String) -> NodePath:
	if unit == "" or not unit_nodes.has(unit):
		return NodePath("")
	return NodePath("../../%s" % str((unit_nodes[unit] as Node).name))


## Names node text (made a valid node name), or text2, text3, ... when a joint baked before it in
## this bake has the name; a node holding the name from an earlier bake gives it up.
static func _name_uniquely(holder: Node, node: Node, text: String, used: Dictionary) -> void:
	var base := text.validate_node_name().strip_edges()
	if base == "":
		base = "Joint"
	var candidate := base
	var n := 1
	while used.has(candidate):
		n += 1
		candidate = "%s%d" % [base, n]
	used[candidate] = true
	var holding := holder.get_node_or_null(NodePath(candidate))
	if holding != null and holding != node:
		holding.name = "%s_%d" % [candidate, holding.get_instance_id()]
	node.name = candidate


# --- Collision ---------------------------------------------------------------------------------

## Most hull points the volume of a hull is worked out from; a hull with more is measured on an
## even subset of them (a slightly smaller hull, so the S-BAKE-HULL percentage is a lower bound).
const HULL_POINTS := 1200


## The volume of the convex hull of points (m³; 0 when they are flat or fewer than four), by an
## incremental hull in doubles.
static func hull_volume(points: PackedVector3Array) -> float:
	var p := []
	var step := maxi(1, ceili(points.size() / float(HULL_POINTS)))
	for i in range(0, points.size(), step):
		p.append(PackedFloat64Array([points[i].x, points[i].y, points[i].z]))
	var n := p.size()
	if n < 4:
		return 0.0
	# A first tetrahedron from far-apart points.
	var i0 := 0
	var i1 := _farthest(p, func(q: PackedFloat64Array) -> float: return _len(_sub(q, p[i0])))
	var i2 := _farthest(p, func(q: PackedFloat64Array) -> float: return _len(_cross(_sub(p[i1], p[i0]), _sub(q, p[i0]))))
	var plane := _cross(_sub(p[i1], p[i0]), _sub(p[i2], p[i0]))
	var i3 := _farthest(p, func(q: PackedFloat64Array) -> float: return absf(_dot(plane, _sub(q, p[i0]))))
	var scale := _len(_sub(p[i1], p[i0]))
	if scale <= 0.0 or absf(_dot(plane, _sub(p[i3], p[i0]))) <= 1e-12 * scale * scale * scale:
		return 0.0
	var eps := 1e-10 * scale
	var faces := [[i0, i1, i2], [i0, i2, i3], [i0, i3, i1], [i1, i3, i2]]
	if _dot(plane, _sub(p[i3], p[i0])) > 0.0:
		faces = [[i0, i2, i1], [i0, i3, i2], [i0, i1, i3], [i1, i2, i3]]
	var used := {i0: true, i1: true, i2: true, i3: true}
	for k in n:
		if used.has(k):
			continue
		var q: PackedFloat64Array = p[k]
		var visible := []
		var kept := []
		for face in faces:
			var a: PackedFloat64Array = p[face[0]]
			var normal := _cross(_sub(p[face[1]], a), _sub(p[face[2]], a))
			var length := _len(normal)
			if length > 0.0 and _dot(normal, _sub(q, a)) / length > eps:
				visible.append(face)
			else:
				kept.append(face)
		if visible.is_empty():
			continue
		# The horizon: edges of visible faces whose reverse is not on a visible face.
		var edges := {}
		for face in visible:
			for e in 3:
				edges[Vector2i(face[e], face[(e + 1) % 3])] = true
		for edge in edges:
			if not edges.has(Vector2i(edge.y, edge.x)):
				kept.append([edge.x, edge.y, k])
		faces = kept
	var volume := 0.0
	var origin: PackedFloat64Array = p[i0]
	for face in faces:
		var a := _sub(p[face[0]], origin)
		var b := _sub(p[face[1]], origin)
		var c := _sub(p[face[2]], origin)
		volume += _dot(a, _cross(b, c))
	return absf(volume) / 6.0


static func _farthest(points: Array, measure: Callable) -> int:
	var best := 0
	var best_d := -1.0
	for i in points.size():
		var d: float = measure.call(points[i])
		if d > best_d:
			best_d = d
			best = i
	return best


static func _sub(a: PackedFloat64Array, b: PackedFloat64Array) -> PackedFloat64Array:
	return PackedFloat64Array([a[0] - b[0], a[1] - b[1], a[2] - b[2]])


static func _dot(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


static func _cross(a: PackedFloat64Array, b: PackedFloat64Array) -> PackedFloat64Array:
	return PackedFloat64Array([a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]])


static func _len(a: PackedFloat64Array) -> float:
	return sqrt(_dot(a, a))
