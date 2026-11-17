extends SceneTree
## Holo Forge Phase 8 bake and game export (spec 5.7, team K).
##
## V1-V8 first: Godot 4.7.1 joint facts under the project's 3D physics engine (Jolt), checked with
## plain Godot nodes (no Holo Forge code); each PASS line prints what was observed. Then the bake
## cases 1-12.
##
## godot --headless --path . --script res://tests/holo_forge_assembly_bake_test.gd
##
## Timing (5.9, case 12), measured 2026-11-13 on the dev machine alone (calibration: the fixed
## 200k-iteration float loop, 16.1-17.8 ms): RigidBody3D bake of chain(20) without the mesh bake
## (CadPart.bake_assembly: solve, mass properties, 20 hulls, 20 joints, read-back): 8.8-10.7 ms,
## ratio 0.547-0.603 (middle 0.581); C9 target 1 s.

const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const FIX := preload("res://tests/holo_forge_assembly_fixtures.gd")
const DATA := preload("res://addons/holo_forge/core/assembly/assembly_data.gd")
const SOLVER := preload("res://addons/holo_forge/core/assembly/solver.gd")
const XFORM := preload("res://addons/holo_forge/core/assembly/xform64.gd")
const BAKE_JOINTS := preload("res://addons/holo_forge/core/assembly/bake_joints.gd")
const INSPECT := preload("res://addons/holo_forge/core/inspect.gd")
const EXPORT := preload("res://addons/holo_forge/core/export.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")
const TIMING := preload("res://tests/holo_forge_timing.gd")

const MM := 0.001
const FOLDER := "user://holo_forge_assembly_fixtures"
## Case 12's ratio limit: 2 × the measured ratio (5.9).
const RATIO_BAKE_20 := 2.0 * 0.581

var failures: Array[String] = []
## The observed engine facts, printed together at the end (for the report).
var facts := PackedStringArray()
var _holder: Node3D


func _init() -> void:
	call_deferred("run")


func run() -> void:
	print("physics engine: %s" % str(ProjectSettings.get_setting("physics/3d/physics_engine", "")))
	await _v8_physics_steps()
	await _v1_hinge_axis()
	await _v2_hinge_limits()
	await _v3_slider_axis()
	await _v4_cone_twist()
	await _v5_6dof_wide_z()
	await _v6_concave_in_rigid()
	_v7_convex_shape()
	if _holder != null and is_instance_valid(_holder):
		_holder.free()
	if not ClassDB.class_exists("CadMesh"):
		print("SKIP cases 1-12: native library missing")
	else:
		var kernel := REGEN.make_kernel()
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FOLDER))
		_case("1", _c1_empty_node3d(kernel))
		_case("2", _c2_posed_node3d(kernel))
		_case("3", _c3_rigid_lever(kernel))
		_case("4", _c4_all_types(kernel))
		_case("5", _c5_shifted(kernel))
		_case("6", _c6_half_and_cone(kernel))
		_case("7", _c7_rest_pose(kernel))
		_case("8", await _c8_jolt_swing(kernel))
		_case("9", _c9_save_reload(kernel))
		_case("10", _c10_not_jolt(kernel))
		_case("11", _c11_export(kernel))
		_case("12", _c12_timing(kernel))
		_case("13", await _c13_inertia(kernel))
		_case("14", _c14_far_export(kernel))
	print("facts:")
	for fact in facts:
		print("  " + fact)
	print("PASS holo_forge_assembly_bake" if failures.is_empty() else "FAIL holo_forge_assembly_bake (%d)" % failures.size())
	quit(0 if failures.is_empty() else 1)


# --- V1-V8: engine facts -------------------------------------------------------------------------

## A fresh holder node for one physics case (the last one is freed).
func _fresh() -> Node3D:
	if _holder != null and is_instance_valid(_holder):
		_holder.queue_free()
		await physics_frame
	_holder = Node3D.new()
	_holder.name = "Probe"
	root.add_child(_holder)
	return _holder


## A free 0.2 m box body (no gravity, no damping) at xform under holder.
func _body(holder: Node3D, xform: Transform3D, body_name := "B", gravity := 0.0) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = body_name
	body.gravity_scale = gravity
	body.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.linear_damp = 0.0
	body.angular_damp = 0.0
	body.can_sleep = false
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.2, 0.2, 0.2)
	shape.shape = box
	body.add_child(shape)
	body.transform = xform
	holder.add_child(body)
	return body


## joint at xform under holder, between node_a (null: the world) and the body.
func _attach(holder: Node3D, joint: Joint3D, xform: Transform3D, base: Node3D, body: Node3D) -> Joint3D:
	joint.name = "J"
	joint.transform = xform
	holder.add_child(joint)
	joint.node_a = joint.get_path_to(base) if base != null else NodePath("")
	joint.node_b = joint.get_path_to(body)
	return joint


## The rotation of basis b relative to basis a about axis (radians, signed, in (-π, π]).
func _turn_about(a: Basis, b: Basis, axis: Vector3) -> float:
	var rel := a.inverse() * b
	var q := rel.get_rotation_quaternion()
	var angle := 2.0 * atan2(Vector3(q.x, q.y, q.z).dot(axis), q.w)
	return wrapf(angle, -PI, PI)


## Spins the body at w (rad/s, world axes) for frames physics frames (the speed is set again each
## frame only when keep is true) and returns {"turn": unwrapped turn about axis since the start,
## "max", "min", "total": the whole rotation angle at the end, "w": the angular velocity at the end}.
func _spin(body: RigidBody3D, w: Vector3, axis: Vector3, frames: int, keep := false) -> Dictionary:
	await physics_frame
	await physics_frame
	var start := body.global_transform.basis
	var last := 0.0
	var turned := 0.0
	var most := -INF
	var least := INF
	body.angular_velocity = w
	for i in frames:
		if keep:
			body.angular_velocity = w
		await physics_frame
		var now := _turn_about(start, body.global_transform.basis, axis)
		turned += wrapf(now - last, -PI, PI)
		last = now
		most = maxf(most, turned)
		least = minf(least, turned)
	var total := (start.inverse() * body.global_transform.basis).get_rotation_quaternion().get_angle()
	return {"turn": turned, "max": most, "min": least, "total": total, "w": body.angular_velocity}


## Pushes the body at v (m/s) for frames physics frames; returns its offset from the start.
func _push(body: RigidBody3D, v: Vector3, frames: int, keep := false) -> Vector3:
	await physics_frame
	await physics_frame
	var start := body.global_position
	body.linear_velocity = v
	for i in frames:
		if keep:
			body.linear_velocity = v
		await physics_frame
	return body.global_position - start


## V8: physics steps in a --script SceneTree run.
func _v8_physics_steps() -> void:
	var holder: Node3D = await _fresh()
	var body := _body(holder, Transform3D.IDENTITY, "Falling", 1.0)
	await physics_frame
	var frames_before := Engine.get_physics_frames()
	var y0 := body.global_position.y
	for i in 30:
		await physics_frame
	var fell := y0 - body.global_position.y
	var ticks := Engine.get_physics_frames() - frames_before
	var ok := fell > 0.1 and ticks >= 30
	_fact("V8", ok, "physics steps in a --headless --script run: a body under gravity fell %.3f m in %d physics frames (%d Hz)" % [fell, ticks, Engine.physics_ticks_per_second])


## V1: the hinge turns about the joint node's local Z.
func _v1_hinge_axis() -> void:
	var turns := {}
	# The joint turned so its local Z is world X: the free axis must follow the node, not the world.
	var placed := Transform3D(Basis(Vector3(0, 1, 0), PI * 0.5), Vector3.ZERO)
	for axis_name in ["X", "Y", "Z"]:
		var axis: Vector3 = {"X": Vector3.RIGHT, "Y": Vector3.UP, "Z": Vector3.BACK}[axis_name]
		var holder: Node3D = await _fresh()
		var body := _body(holder, Transform3D.IDENTITY)
		_attach(holder, HingeJoint3D.new(), placed, null, body)
		var spun: Dictionary = await _spin(body, placed.basis * axis * 2.0, placed.basis * axis, 30)
		turns[axis_name] = float(spun.total)
	var ok := float(turns.Z) > 0.5 and float(turns.X) < 0.02 and float(turns.Y) < 0.02
	_fact("V1", ok, "hinge axis is the joint node's local Z: 2 rad/s for 0.5 s about local X, Y, Z turned it %.4f, %.4f, %.4f rad" % [turns.X, turns.Y, turns.Z])


## V2: hinge limits are radians from the setup pose; the sign; the ±π range.
func _v2_hinge_limits() -> void:
	var notes := PackedStringArray()
	var ok := true
	for with_base in [false, true]:
		var stops := {}
		for direction in [1.0, -1.0]:
			var holder: Node3D = await _fresh()
			var base: StaticBody3D = null
			if with_base:
				base = StaticBody3D.new()
				base.name = "A"
				holder.add_child(base)
			# Set up turned 30° about Z: limits -10°..+20° must count from there.
			var body := _body(holder, Transform3D(Basis(Vector3.BACK, deg_to_rad(30.0)), Vector3.ZERO))
			var hinge := HingeJoint3D.new()
			hinge.set_flag(HingeJoint3D.FLAG_USE_LIMIT, true)
			hinge.set_param(HingeJoint3D.PARAM_LIMIT_LOWER, deg_to_rad(-10.0))
			hinge.set_param(HingeJoint3D.PARAM_LIMIT_UPPER, deg_to_rad(20.0))
			_attach(holder, hinge, Transform3D.IDENTITY, base, body)
			var spun: Dictionary = await _spin(body, Vector3(0, 0, 3.0 * direction), Vector3.BACK, 40, true)
			stops[direction] = rad_to_deg(float(spun.turn))
		# Observed under Jolt (2026-11-13): measured from the setup pose, but a positive hinge angle
		# is node_b turning about -Z (the limits stop +Z at -lower and -Z at -upper). The bake maps
		# limits with that sign (core/assembly/bake_joints.gd).
		var from_setup := absf(float(stops[1.0]) - 10.0) < 2.0 and absf(float(stops[-1.0]) + 20.0) < 2.0
		ok = ok and from_setup
		notes.append("%s: spinning node_b +Z stops at %+.2f° and -Z at %+.2f° from the setup pose (limits lower -10°, upper +20°)" % [
			"node_a = static body" if with_base else "node_a empty (world)", stops[1.0], stops[-1.0]])
	# Limits at ±π: how far does the hinge turn? And one end at -π (a half-limited joint).
	for lower_upper in [[-PI, PI], [-PI, deg_to_rad(20.0)], [deg_to_rad(-20.0), PI]]:
		for direction in [1.0, -1.0]:
			var holder: Node3D = await _fresh()
			var body := _body(holder, Transform3D.IDENTITY)
			var hinge := HingeJoint3D.new()
			hinge.set_flag(HingeJoint3D.FLAG_USE_LIMIT, true)
			hinge.set_param(HingeJoint3D.PARAM_LIMIT_LOWER, lower_upper[0])
			hinge.set_param(HingeJoint3D.PARAM_LIMIT_UPPER, lower_upper[1])
			_attach(holder, hinge, Transform3D.IDENTITY, null, body)
			var spun: Dictionary = await _spin(body, Vector3(0, 0, 6.0 * direction), Vector3.BACK, 90, true)
			notes.append("limits %.0f°..%.0f°, node_b spun %sZ at 6 rad/s for 1.5 s: reached %+.1f° (unwrapped)" % [
				rad_to_deg(lower_upper[0]), rad_to_deg(lower_upper[1]), "+" if direction > 0.0 else "-", rad_to_deg(float(spun.turn))])
	_fact("V2", ok, "hinge limits are radians measured from the setup pose, with the opposite sign: a positive hinge angle is node_b turning about -Z relative to node_a (the world or a body alike); " + "; ".join(notes))


## V3: the slider slides along the joint node's local X.
func _v3_slider_axis() -> void:
	var moved := {}
	var placed := Transform3D(Basis(Vector3(0, 0, 1), PI * 0.5), Vector3.ZERO)
	for axis_name in ["X", "Y", "Z"]:
		var axis: Vector3 = {"X": Vector3.RIGHT, "Y": Vector3.UP, "Z": Vector3.BACK}[axis_name]
		var holder: Node3D = await _fresh()
		var body := _body(holder, Transform3D.IDENTITY)
		var slider := SliderJoint3D.new()
		slider.set_param(SliderJoint3D.PARAM_LINEAR_LIMIT_UPPER, 10.0)
		slider.set_param(SliderJoint3D.PARAM_LINEAR_LIMIT_LOWER, -10.0)
		_attach(holder, slider, placed, null, body)
		moved[axis_name] = (await _push(body, placed.basis * axis * 1.0, 30)).length()
	# Limit sign: upper 0.1, lower -0.05; pushing +X stops at +0.1.
	var stops := {}
	for direction in [1.0, -1.0]:
		var holder: Node3D = await _fresh()
		var body := _body(holder, Transform3D.IDENTITY)
		var slider := SliderJoint3D.new()
		slider.set_param(SliderJoint3D.PARAM_LINEAR_LIMIT_UPPER, 0.1)
		slider.set_param(SliderJoint3D.PARAM_LINEAR_LIMIT_LOWER, -0.05)
		_attach(holder, slider, Transform3D.IDENTITY, null, body)
		stops[direction] = (await _push(body, Vector3(direction, 0, 0), 40, true)).x
	# Turning about the slide axis.
	var holder: Node3D = await _fresh()
	var body := _body(holder, Transform3D.IDENTITY)
	_attach(holder, SliderJoint3D.new(), Transform3D.IDENTITY, null, body)
	var spun: Dictionary = await _spin(body, Vector3(2.0, 0, 0), Vector3.RIGHT, 30)
	var ok := float(moved.X) > 0.3 and float(moved.Y) < 0.002 and float(moved.Z) < 0.002 and absf(float(stops[1.0]) - 0.1) < 0.005 and absf(float(stops[-1.0]) + 0.05) < 0.005
	_fact("V3", ok, "slider axis is the joint node's local X: 1 m/s for 0.5 s along local X, Y, Z moved it %.4f, %.4f, %.4f m; limits upper 0.1, lower -0.05: +X stops at %+.4f, -X at %+.4f; spinning about the slide axis turned it %.4f rad" % [
		moved.X, moved.Y, moved.Z, stops[1.0], stops[-1.0], spun.total])


## V4: the cone twist joint twists about local X; swing and twist spans.
func _v4_cone_twist() -> void:
	var reached := {}
	for axis_name in ["X", "Y", "Z"]:
		var axis: Vector3 = {"X": Vector3.RIGHT, "Y": Vector3.UP, "Z": Vector3.BACK}[axis_name]
		var holder: Node3D = await _fresh()
		var body := _body(holder, Transform3D.IDENTITY)
		var cone := ConeTwistJoint3D.new()
		cone.set_param(ConeTwistJoint3D.PARAM_SWING_SPAN, 0.3)
		cone.set_param(ConeTwistJoint3D.PARAM_TWIST_SPAN, 0.6)
		_attach(holder, cone, Transform3D.IDENTITY, null, body)
		var plus: Dictionary = await _spin(body, axis * 3.0, axis, 40, true)
		holder = await _fresh()
		body = _body(holder, Transform3D.IDENTITY)
		cone = ConeTwistJoint3D.new()
		cone.set_param(ConeTwistJoint3D.PARAM_SWING_SPAN, 0.3)
		cone.set_param(ConeTwistJoint3D.PARAM_TWIST_SPAN, 0.6)
		_attach(holder, cone, Transform3D.IDENTITY, null, body)
		var minus: Dictionary = await _spin(body, -axis * 3.0, axis, 40, true)
		reached[axis_name] = [float(plus.turn), float(minus.turn)]
	var ok := absf(float(reached.X[0]) - 0.6) < 0.05 and absf(float(reached.X[1]) + 0.6) < 0.05 \
		and absf(float(reached.Y[0]) - 0.3) < 0.05 and absf(float(reached.Z[0]) - 0.3) < 0.05
	_fact("V4", ok, "cone twist: twist about the joint node's local X, swing about Y and Z, both symmetric half-angles (an asymmetric request has no form): swing_span 0.3, twist_span 0.6; ±X stopped at %+.3f/%+.3f, ±Y at %+.3f/%+.3f, ±Z at %+.3f/%+.3f rad" % [
		reached.X[0], reached.X[1], reached.Y[0], reached.Y[1], reached.Z[0], reached.Z[1]])


## V5: a 6DOF angular Z limit of ±120° holds under Jolt.
func _v5_6dof_wide_z() -> void:
	var stops := {}
	for direction in [1.0, -1.0]:
		var holder: Node3D = await _fresh()
		var body := _body(holder, Transform3D.IDENTITY)
		var six := Generic6DOFJoint3D.new()
		six.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, deg_to_rad(-120.0))
		six.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, deg_to_rad(120.0))
		_attach(holder, six, Transform3D.IDENTITY, null, body)
		var spun: Dictionary = await _spin(body, Vector3(0, 0, 4.0 * direction), Vector3.BACK, 60, true)
		stops[direction] = rad_to_deg(float(spun.turn))
	# Also about X (twist in the engine's own terms) for comparison.
	var holder: Node3D = await _fresh()
	var body := _body(holder, Transform3D.IDENTITY)
	var six := Generic6DOFJoint3D.new()
	six.set_param_x(Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, deg_to_rad(-120.0))
	six.set_param_x(Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, deg_to_rad(120.0))
	_attach(holder, six, Transform3D.IDENTITY, null, body)
	var spun_x: Dictionary = await _spin(body, Vector3(4.0, 0, 0), Vector3.RIGHT, 60, true)
	# Signs: angular Z lower -30°, upper +100°; linear X lower -0.05, upper 0.1 (others locked).
	var signs := {}
	for direction in [1.0, -1.0]:
		holder = await _fresh()
		body = _body(holder, Transform3D.IDENTITY)
		six = Generic6DOFJoint3D.new()
		six.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT, deg_to_rad(-30.0))
		six.set_param_z(Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT, deg_to_rad(100.0))
		six.set_param_x(Generic6DOFJoint3D.PARAM_LINEAR_LOWER_LIMIT, -0.05)
		six.set_param_x(Generic6DOFJoint3D.PARAM_LINEAR_UPPER_LIMIT, 0.1)
		_attach(holder, six, Transform3D.IDENTITY, null, body)
		var turned: Dictionary = await _spin(body, Vector3(0, 0, 4.0 * direction), Vector3.BACK, 60, true)
		var slid := await _push(body, Vector3(direction, 0, 0), 40, true)
		signs[direction] = [rad_to_deg(float(turned.turn)), slid.x]
	# Observed under Jolt (2026-11-13): angular limits have the hinge's opposite sign (+Z stops at
	# -lower, -Z at -upper); linear limits do not (+X stops at upper).
	var ok := absf(float(stops[1.0]) - 120.0) < 3.0 and absf(float(stops[-1.0]) + 120.0) < 3.0 \
		and absf(float(signs[1.0][0]) - 30.0) < 3.0 and absf(float(signs[-1.0][0]) + 100.0) < 3.0 \
		and absf(float(signs[1.0][1]) - 0.1) < 0.005 and absf(float(signs[-1.0][1]) + 0.05) < 0.005
	_fact("V5", ok, "6DOF angular Z limited to -120°..+120°: +Z stopped at %+.2f°, -Z at %+.2f° (same limit on X: +X stopped at %+.2f°); signs (angular Z lower -30°, upper +100°; linear X lower -0.05, upper 0.1): node_b spun +Z stopped at %+.2f°, -Z at %+.2f° (angular limits count node_b turning about -Z, as the hinge's), pushed +X at %+.4f m, -X at %+.4f m (linear limits count along +X)" % [
		stops[1.0], stops[-1.0], rad_to_deg(float(spun_x.turn)), signs[1.0][0], signs[-1.0][0], signs[1.0][1], signs[-1.0][1]])


## V6: a concave shape in a moving RigidBody3D (what Jolt does): dropped on a floor.
func _v6_concave_in_rigid() -> void:
	var holder: Node3D = await _fresh()
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(4, 0.2, 4)
	floor_shape.shape = floor_box
	floor_body.add_child(floor_shape)
	floor_body.position = Vector3(0, -0.1, 0)
	holder.add_child(floor_body)
	var body := RigidBody3D.new()
	body.can_sleep = false
	var shape := CollisionShape3D.new()
	var concave := ConcavePolygonShape3D.new()
	concave.set_faces(BoxMesh.new().get_faces())
	shape.shape = concave
	body.add_child(shape)
	body.position = Vector3(0, 0.6, 0)
	holder.add_child(body)
	for i in 60:
		await physics_frame
	var y := body.global_position.y
	var rests := absf(y - 0.5) < 0.05
	_fact("V6", true, "a ConcavePolygonShape3D in a moving RigidBody3D under %s, dropped on a static floor from y 0.6: after 1 s its centre is at y %.3f (%s)" % [
		str(ProjectSettings.get_setting("physics/3d/physics_engine", "")), y, "it rests on the floor" if rests else "it does not rest on the floor: no usable collision"])


## V7: Mesh.create_convex_shape gives a ConvexPolygonShape3D.
func _v7_convex_shape() -> void:
	var box := BoxMesh.new()
	var hull: Shape3D = box.create_convex_shape(true, false)
	var cylinder := CylinderMesh.new()
	var round_hull: Shape3D = cylinder.create_convex_shape(true, false)
	var ok := hull is ConvexPolygonShape3D and (hull as ConvexPolygonShape3D).points.size() == 8 and round_hull is ConvexPolygonShape3D
	_fact("V7", ok, "Mesh.create_convex_shape(true, false) returns %s; a box mesh's hull has %d points, a 64-segment cylinder mesh's %d" % [
		hull.get_class() if hull != null else "null", (hull as ConvexPolygonShape3D).points.size() if hull is ConvexPolygonShape3D else -1,
		(round_hull as ConvexPolygonShape3D).points.size() if round_hull is ConvexPolygonShape3D else -1])


# --- 1-12: the bake --------------------------------------------------------------------------------

## 1. Empty assembly, Node3D mode: the Phase 7 tree (plain Node3D components at identity, bodies
## at identity with their modelled bounds, no Ground, Joints or collision shapes, no notes).
func _c1_empty_node3d(kernel: RefCounted) -> Dictionary:
	var f := FIX.lever(kernel)
	var part := _part(f)
	var ok := true
	var children := PackedStringArray()
	for child in part.get_children():
		children.append("%s:%s" % [child.name, child.get_class()])
	ok = _expect(children == PackedStringArray(["Lever:Node3D", "Base:MeshInstance3D"]), "1: the part's children should be Lever:Node3D, Base:MeshInstance3D (got %s)." % [children]) and ok
	var lever: Node3D = part.get_node_or_null("Lever")
	ok = _expect(lever != null and lever.transform == Transform3D.IDENTITY and lever.get_child_count() == 1 and lever.get_child(0) is MeshInstance3D,
		"1: Lever should be a Node3D at identity holding one MeshInstance3D.") and ok
	ok = _expect(part.find_children("*", "CollisionShape3D", true, false).is_empty() and part.find_children("*", "RigidBody3D", true, false).is_empty()
		and part.find_children("*", "Joint3D", true, false).is_empty(), "1: no collision shapes, RigidBody3D or joints in Node3D mode.") and ok
	var nodes: Dictionary = part.body_nodes()
	var base: MeshInstance3D = nodes.get(f.bodies.Base)
	var arm: MeshInstance3D = nodes.get(f.bodies.Lever)
	ok = _expect(base != null and arm != null and base.transform == Transform3D.IDENTITY and arm.transform == Transform3D.IDENTITY
		and _aabb_close(base.get_aabb(), AABB(Vector3(-50, -50, 0) * MM, Vector3(100, 100, 10) * MM))
		and _aabb_close(arm.get_aabb(), AABB(Vector3(-10, -10, 10) * MM, Vector3(105, 20, 10) * MM)), "1: body nodes at identity with their modelled bounds.") and ok
	ok = _expect((part.last_bake_report.notes as PackedStringArray).is_empty() and (part.last_bake_report.errors as PackedStringArray).is_empty(),
		"1: an empty assembly's bake says nothing (%s)." % [part.last_bake_report]) and ok
	_drop(part)
	return {"ok": ok, "text": "empty assembly, Node3D mode: Lever:Node3D at identity, Base:MeshInstance3D, modelled bounds, no shapes/joints/notes"}


## 2. Node3D mode, posed lever at 30°: component transforms are the solve's (nested: local to the
## parent component).
func _c2_posed_node3d(kernel: RefCounted) -> Dictionary:
	var f := FIX.lever(kernel)
	FIX._box(f, "Knob", Vector3(80, -5, 20), Vector3(90, 5, 25), "Knob")
	f.doc.components[f.components.Knob]["parent"] = f.components.Lever
	var assembly: Dictionary = DATA.normalized(f.doc.assembly)
	assembly.placements[f.components.Knob] = XFORM.compose(XFORM.translation(1.0 * MM, 2.0 * MM, 3.0 * MM), XFORM.rot_z(0.1))
	f.doc.assembly = assembly
	FIX.rebuild(f)
	_lever_joint(f, 30.0)
	var solved := SOLVER.solve(f.doc, f.result, kernel)
	var part := _part(f)
	var lever: Node3D = part.get_node_or_null("Lever")
	var knob: Node3D = part.get_node_or_null("Lever/Knob")
	var ok := _expect(lever != null and lever.transform == solved.transforms[f.components.Lever], "2: Lever's transform should equal solve.transforms exactly (%s vs %s)." % [
		lever.transform if lever != null else null, solved.transforms[f.components.Lever]])
	ok = _expect(knob != null and knob.transform == solved.transforms[f.components.Knob], "2: the nested Knob's transform should equal its local solve transform.") and ok
	if knob != null:
		var expected := XFORM.to_transform(solved.poses[f.components.Knob])
		ok = _expect(knob.global_transform.is_equal_approx(expected), "2: Knob's global transform should be its pose (%s vs %s)." % [knob.global_transform, expected]) and ok
	ok = _expect((part.last_bake_report.notes as PackedStringArray).has(DATA.S_BAKE_NO_JOINTS), "2: Node3D mode with joints says S-BAKE-NO-JOINTS.") and ok
	ok = _expect(part.find_children("*", "Joint3D", true, false).is_empty(), "2: no joints in Node3D mode.") and ok
	_drop(part)
	return {"ok": ok, "text": "Lever at 30° equals solve.transforms exactly; nested Knob local to Lever; S-BAKE-NO-JOINTS"}


## 3. RigidBody3D mode on lever(): Lever a RigidBody3D with one convex <Body>Shape, Base under the
## Ground StaticBody3D, mass and centre of mass from INSPECT; a grounded unit is frozen static.
func _c3_rigid_lever(kernel: RefCounted) -> Dictionary:
	var f := _lever_fixture(kernel, 30.0)
	var part := _part(f, CAD_PART.COMPONENT_RIGID_BODY)
	var ok := true
	var lever := part.get_node_or_null("Lever") as RigidBody3D
	var ground := part.get_node_or_null("Ground") as StaticBody3D
	ok = _expect(lever != null and not lever.freeze, "3: Lever should be a RigidBody3D, not frozen.") and ok
	ok = _expect(ground != null and ground.get_node_or_null("Base") is MeshInstance3D, "3: Base should be under a StaticBody3D named Ground.") and ok
	var base_shape := ground.get_node_or_null("BaseShape") as CollisionShape3D if ground != null else null
	ok = _expect(base_shape != null and base_shape.shape is ConcavePolygonShape3D, "3: Ground should hold BaseShape, a trimesh.") and ok
	var mass_text := ""
	if lever != null:
		var shapes := lever.find_children("*", "CollisionShape3D", true, false)
		var shape := lever.get_node_or_null("LeverShape") as CollisionShape3D
		ok = _expect(shapes.size() == 1 and shape != null and shape.get_parent() == lever and shape.shape is ConvexPolygonShape3D,
			"3: Lever should hold one direct CollisionShape3D LeverShape with a ConvexPolygonShape3D (%d shapes)." % shapes.size()) and ok
		var props := INSPECT.mass_properties(f.doc, f.result, [f.bodies.Lever])
		var mass := float(props.mass)
		var center: Vector3 = props.center
		ok = _expect(mass > 0.0 and absf(lever.mass - mass) <= 1e-6 * mass, "3: mass %.9f should be INSPECT's %.9f." % [lever.mass, mass]) and ok
		ok = _expect(lever.center_of_mass_mode == RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM and lever.center_of_mass.distance_to(center) <= 1e-6,
			"3: centre of mass %s should be %s." % [lever.center_of_mass, center]) and ok
		mass_text = "mass %.6f kg, centre %s" % [mass, center]
	_drop(part)
	# A grounded unit: frozen, static.
	var s := FIX.stack(kernel)
	var assembly: Dictionary = DATA.normalized(s.doc.assembly)
	assembly.grounded[s.components.Cube] = true
	s.doc.assembly = assembly
	part = _part(s, CAD_PART.COMPONENT_RIGID_BODY)
	var cube := part.get_node_or_null("Cube") as RigidBody3D
	ok = _expect(cube != null and cube.freeze and cube.freeze_mode == RigidBody3D.FREEZE_MODE_STATIC, "3: a grounded Cube should be a frozen static RigidBody3D.") and ok
	_drop(part)
	# The hull volume the S-BAKE-HULL check uses: a 1 m box's hull holds 1 m³.
	var unit_box := BAKE_JOINTS.hull_volume((BoxMesh.new().create_convex_shape(true, false) as ConvexPolygonShape3D).points)
	ok = _expect(absf(unit_box - 1.0) < 1e-6, "3: the hull volume of a 1 m box should be 1 m³ (%.9f)." % unit_box) and ok
	return {"ok": ok, "text": "Lever RigidBody3D with LeverShape (convex), Base under Ground with BaseShape (trimesh), %s; grounded Cube frozen static; hull volume of a unit box %.6f" % [mass_text, unit_box]}


## 4. all_types(): per joint the node class, the path, node_a/node_b, every flag and limit, the axes.
func _c4_all_types(kernel: RefCounted) -> Dictionary:
	var f := FIX.all_types(kernel)
	var solved := SOLVER.solve(f.doc, f.result, kernel)
	var part := _part(f, CAD_PART.COMPONENT_RIGID_BODY)
	var ok := _expect((part.last_bake_report.errors as PackedStringArray).is_empty(), "4: no read-back errors (%s)." % [part.last_bake_report.errors])
	var classes := {"rigid": "Generic6DOFJoint3D", "revolute": "HingeJoint3D", "slider": "SliderJoint3D", "cylindrical": "Generic6DOFJoint3D",
		"pin_slot": "Generic6DOFJoint3D", "planar": "Generic6DOFJoint3D", "ball": "ConeTwistJoint3D"}
	var lo := deg_to_rad(-60.0)
	var hi := deg_to_rad(30.0)
	var slo := -5.0 * MM
	var shi := 10.0 * MM
	var seen := PackedStringArray()
	for joint_type in DATA.TYPES:
		var joint_name: String = joint_type.capitalize()
		var node := part.get_node_or_null("Joints/" + joint_name) as Joint3D
		if not _expect(node != null and node.get_class() == classes[joint_type], "4: Joints/%s should be a %s." % [joint_name, classes[joint_type]]):
			ok = false
			continue
		ok = _expect(node.node_a == NodePath("") and node.node_b == NodePath("../../" + joint_name), "4: %s node_a/node_b should be \"\" and ../../%s (%s, %s)." % [joint_name, joint_name, node.node_a, node.node_b]) and ok
		ok = _expect(node.get_node_or_null(node.node_b) is RigidBody3D and node.get_node(node.node_b) == part.get_node(joint_name), "4: %s node_b should be the %s RigidBody3D." % [joint_name, joint_name]) and ok
		var expected := {}
		match joint_type:
			"revolute":
				expected = {"angular_limit/enable": true, "angular_limit/lower": lo, "angular_limit/upper": hi}
			"slider":
				expected = {"linear_limit/lower_distance": slo, "linear_limit/upper_distance": shi}
			"ball":
				expected = {"swing_span": deg_to_rad(60.0), "twist_span": deg_to_rad(60.0)}
			_:
				for letter in ["x", "y", "z"]:
					for kind in ["linear", "angular"]:
						expected["%s_limit_%s/enabled" % [kind, letter]] = true
						expected["%s_limit_%s/%s" % [kind, letter, "lower_angle" if kind == "angular" else "lower_distance"]] = 0.0
						expected["%s_limit_%s/%s" % [kind, letter, "upper_angle" if kind == "angular" else "upper_distance"]] = 0.0
				var free := {"rigid": [], "cylindrical": ["linear_z", "angular_z"], "pin_slot": ["angular_z", "linear_x"], "planar": ["linear_x", "linear_y", "angular_z"]}
				for key in free[joint_type]:
					var angular: bool = (key as String).begins_with("angular")
					expected["%s_limit_%s/%s" % [key.get_slice("_", 0), key.get_slice("_", 1), "lower_angle" if angular else "lower_distance"]] = lo if angular else slo
					expected["%s_limit_%s/%s" % [key.get_slice("_", 0), key.get_slice("_", 1), "upper_angle" if angular else "upper_distance"]] = hi if angular else shi
		for property in expected:
			var got: Variant = node.get(property)
			var want: Variant = expected[property]
			var same: bool = (got is bool and want is bool and got == want) or ((got is float or got is int) and not (want is bool) and absf(float(got) - float(want)) <= 1e-6)
			ok = _expect(same, "4: %s %s reads %s, expected %s." % [joint_name, property, got, want]) and ok
		var world: PackedFloat64Array = solved.joints[f.joints[joint_name]].world
		var axis := Vector3(world[6], world[7], world[8])
		var node_axis := Vector3.ZERO
		match joint_type:
			"revolute":
				node_axis = node.transform.basis.z
			"slider", "ball":
				node_axis = node.transform.basis.x
		if node_axis != Vector3.ZERO:
			ok = _expect(node_axis.distance_to(axis) <= 1e-6, "4: %s's axis %s should be the joint axis %s." % [joint_name, node_axis, axis]) and ok
		seen.append("%s=%s" % [joint_name, node.get_class()])
	_drop(part)
	return {"ok": ok, "text": "all_types: %s; paths Joints/<Name>, node_a \"\", node_b ../../<Comp>, limits and axes read back within 1e-6" % ", ".join(seen)}


## 5. Lever baked at 30° with limits -30°..90°: hinge lower -60°, upper 60°.
func _c5_shifted(kernel: RefCounted) -> Dictionary:
	var f := _lever_fixture(kernel, 30.0)
	var part := _part(f, CAD_PART.COMPONENT_RIGID_BODY)
	var hinge := part.get_node_or_null("Joints/Joint1") as HingeJoint3D
	var ok := _expect(hinge != null, "5: Joints/Joint1 should be a HingeJoint3D.")
	var lower := 0.0
	var upper := 0.0
	if hinge != null:
		lower = hinge.get_param(HingeJoint3D.PARAM_LIMIT_LOWER)
		upper = hinge.get_param(HingeJoint3D.PARAM_LIMIT_UPPER)
		ok = _expect(hinge.get_flag(HingeJoint3D.FLAG_USE_LIMIT) and absf(lower - deg_to_rad(-60.0)) <= 1e-6 and absf(upper - deg_to_rad(60.0)) <= 1e-6,
			"5: lower %.6f° and upper %.6f° should be -60° and 60°." % [rad_to_deg(lower), rad_to_deg(upper)]) and ok
	_drop(part)
	return {"ok": ok, "text": "Lever at 30°, limits -30°..90°: hinge lower %.4f°, upper %.4f°" % [rad_to_deg(lower), rad_to_deg(upper)]}


## 6. Half-limited hinge and slider: S-BAKE-HALF-LIMIT; an asymmetric ball: S-BAKE-CONE-WIDENED.
func _c6_half_and_cone(kernel: RefCounted) -> Dictionary:
	var f := FIX.all_types(kernel)
	var assembly: Dictionary = DATA.normalized(f.doc.assembly)
	for joint in assembly.joints:
		if joint.name == "Revolute":
			joint.dofs[0]["limited_max"] = false
		elif joint.name == "Slider":
			joint.dofs[0]["limited_min"] = false
	f.doc.assembly = assembly
	var part := _part(f, CAD_PART.COMPONENT_RIGID_BODY)
	var notes: PackedStringArray = part.last_bake_report.notes
	var half := DATA.S_BAKE_HALF_LIMIT.get_slice("<value>", 0).replace("<Joint>", "")
	var cone := DATA.S_BAKE_CONE_WIDENED.get_slice("<swing>", 0).replace("<Joint>", "")
	var ok := _expect(_has_note(notes, "Revolute" + half) and _has_note(notes, "Slider" + half), "6: S-BAKE-HALF-LIMIT for Revolute and Slider (%s)." % [notes])
	ok = _expect(_has_note(notes, "Ball" + cone), "6: S-BAKE-CONE-WIDENED for Ball (%s)." % [notes]) and ok
	var hinge := part.get_node_or_null("Joints/Revolute") as HingeJoint3D
	var slider := part.get_node_or_null("Joints/Slider") as SliderJoint3D
	ok = _expect(hinge != null and absf(hinge.get_param(HingeJoint3D.PARAM_LIMIT_LOWER) + PI) <= 1e-6 and absf(hinge.get_param(HingeJoint3D.PARAM_LIMIT_UPPER) - deg_to_rad(30.0)) <= 1e-6,
		"6: the hinge open at max should read lower -π, upper 30°.") and ok
	ok = _expect(slider != null and absf(slider.get_param(SliderJoint3D.PARAM_LINEAR_LIMIT_LOWER) + BAKE_JOINTS.OPEN_LINEAR) <= 1e-6 and absf(slider.get_param(SliderJoint3D.PARAM_LINEAR_LIMIT_UPPER) - 10.0 * MM) <= 1e-6,
		"6: the slider open at min should read lower -1e4 m, upper 10 mm.") and ok
	var said := PackedStringArray()
	for note in notes:
		if note.contains(half) or note.contains(cone):
			said.append(note)
	_drop(part)
	return {"ok": ok, "text": " / ".join(said)}


## 7. bake_pose = REST: transforms are those of the rest values.
func _c7_rest_pose(kernel: RefCounted) -> Dictionary:
	var f := _lever_fixture(kernel, 30.0, 10.0)
	var rest := SOLVER.solve(f.doc, f.result, kernel, {f.joints.Joint1: {0: deg_to_rad(10.0)}})
	var current := SOLVER.solve(f.doc, f.result, kernel)
	var ok := true
	for mode in [CAD_PART.COMPONENT_NODE3D, CAD_PART.COMPONENT_RIGID_BODY]:
		var part := _part(f, mode, CAD_PART.BAKE_POSE_REST)
		var lever: Node3D = part.get_node_or_null("Lever")
		ok = _expect(lever != null and lever.transform == rest.transforms[f.components.Lever] and lever.transform != current.transforms[f.components.Lever],
			"7: with bake_pose Rest (mode %d) Lever should sit at its rest value 10°, not 30°." % mode) and ok
		if mode == CAD_PART.COMPONENT_RIGID_BODY:
			var hinge := part.get_node_or_null("Joints/Joint1") as HingeJoint3D
			# Rest 10°, limits -30°..90°: lower 10 - 90 = -80°, upper 10 + 30 = 40°.
			ok = _expect(hinge != null and absf(hinge.get_param(HingeJoint3D.PARAM_LIMIT_LOWER) - deg_to_rad(-80.0)) <= 1e-6 and absf(hinge.get_param(HingeJoint3D.PARAM_LIMIT_UPPER) - deg_to_rad(40.0)) <= 1e-6,
				"7: the rest pose shifts the hinge limits by 10° (-80°..40°).") and ok
		_drop(part)
	return {"ok": ok, "text": "bake_pose Rest: Lever at its 10° rest transform (Node3D and RigidBody3D), hinge limits -80°..40°"}


## 8. Jolt simulation: lever() baked as RigidBody3D, the hinge on part Z, default gravity (-Y, in
## the Lever's plane): after 60 physics frames the Lever has swung about the hinge only.
func _c8_jolt_swing(kernel: RefCounted) -> Dictionary:
	var f := _lever_fixture(kernel, 30.0)
	var part := _part(f, CAD_PART.COMPONENT_RIGID_BODY)
	var lever := part.get_node("Lever") as RigidBody3D
	var hinge := part.get_node("Joints/Joint1") as HingeJoint3D
	var most := 0.0
	var lowest := INF
	for i in 60:
		await physics_frame
		most = maxf(most, maxf(absf(lever.angular_velocity.x), absf(lever.angular_velocity.y)))
		lowest = minf(lowest, rad_to_deg(atan2(lever.global_transform.basis.x.y, lever.global_transform.basis.x.x)))
	var w := lever.angular_velocity
	var angle := rad_to_deg(atan2(lever.global_transform.basis.x.y, lever.global_transform.basis.x.x))
	var hole := lever.global_transform * Vector3(0, 0, 10) * MM
	var origin := hinge.global_transform.origin
	var ok := _expect(absf(w.x) < 1e-3 and absf(w.y) < 1e-3, "8: the Lever's angular velocity about X and Y should stay under 1e-3 rad/s (%s)." % w)
	ok = _expect(angle >= -31.0 and angle <= 91.0, "8: the hinge angle %.3f° should stay within -30°..90° + 1°." % angle) and ok
	ok = _expect(hole.distance_to(origin) <= 1.0 * MM, "8: the hole centre should stay within 1 mm of the joint origin (%.4f mm)." % (hole.distance_to(origin) / MM)) and ok
	ok = _expect(lowest < 25.0, "8: the Lever should swing down under gravity (lowest %.2f°)." % lowest) and ok
	_drop(part)
	return {"ok": ok, "text": "after 60 frames: angle %.3f° (lowest %.3f°, limits -30°..90°), |w_x| %s, |w_y| %s (most over the run %s) rad/s, hole centre %.4f mm from the joint origin" % [
		angle, lowest, String.num_scientific(absf(w.x)), String.num_scientific(absf(w.y)), String.num_scientific(most), hole.distance_to(origin) / MM]}


## 9. Save the baked scene with ResourceSaver and load it again: every joint's node_a/node_b
## resolves and its properties are equal.
func _c9_save_reload(kernel: RefCounted) -> Dictionary:
	var f := FIX.all_types(kernel)
	var part := _part(f, CAD_PART.COMPONENT_RIGID_BODY)
	part.process_mode = Node.PROCESS_MODE_DISABLED
	var path := FOLDER.path_join("assembly_bake_test.tscn")
	var packed := PackedScene.new()
	var ok := _expect(packed.pack(part) == OK and ResourceSaver.save(packed, path) == OK, "9: the baked scene should pack and save.")
	var originals := {}
	for node in part.get_node("Joints").get_children():
		originals[str(node.name)] = _joint_values(node)
	_drop(part)
	var loaded := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var copy: Node3D = loaded.instantiate() if loaded != null else null
	ok = _expect(copy != null, "9: the saved scene should load.") and ok
	var count := 0
	if copy != null:
		copy.process_mode = Node.PROCESS_MODE_DISABLED
		root.add_child(copy)
		var joints := copy.get_node_or_null("Joints")
		ok = _expect(joints != null and joints.get_child_count() == originals.size(), "9: the loaded scene should have every joint.") and ok
		for node in (joints.get_children() if joints != null else []):
			var joint := node as Joint3D
			count += 1
			ok = _expect(joint.get_node_or_null(joint.node_b) is RigidBody3D and (joint.node_a == NodePath("") or joint.get_node_or_null(joint.node_a) is PhysicsBody3D),
				"9: %s's node_a/node_b should resolve after loading." % joint.name) and ok
			ok = _expect(_joint_values(joint) == originals.get(str(joint.name)), "9: %s's properties should be equal after loading." % joint.name) and ok
		root.remove_child(copy)
		copy.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	return {"ok": ok, "text": "%d joints saved and loaded: node paths resolve, properties equal" % count}


## 10. With the engine name seam set to Godot Physics the bake adds S-BAKE-NOT-JOLT.
func _c10_not_jolt(kernel: RefCounted) -> Dictionary:
	var f := _lever_fixture(kernel, 30.0)
	BAKE_JOINTS.engine_name_override = "Godot Physics"
	var part := _part(f, CAD_PART.COMPONENT_RIGID_BODY)
	var with_seam: PackedStringArray = part.last_bake_report.notes
	BAKE_JOINTS.engine_name_override = ""
	part.apply_result(f.result)
	var without: PackedStringArray = part.last_bake_report.notes
	var ok := _expect(with_seam.has(DATA.S_BAKE_NOT_JOLT) and not without.has(DATA.S_BAKE_NOT_JOLT), "10: S-BAKE-NOT-JOLT only under another engine (%s / %s)." % [with_seam, without])
	_drop(part)
	return {"ok": ok, "text": "engine \"Godot Physics\": S-BAKE-NOT-JOLT; Jolt: none"}


## 11. Export: an STL of the posed Lever has the posed bounding box; with an empty assembly every
## format writes the same bytes as without the design (the Phase 7 path); a posed mesh body moves.
func _c11_export(kernel: RefCounted) -> Dictionary:
	var f := _lever_fixture(kernel, 30.0)
	var path := FOLDER.path_join("posed_lever.stl")
	var report := EXPORT.export_cad_report(kernel, f.result, [f.bodies.Lever], path, f.doc)
	var ok := _expect(str(report.error) == "" and str(report.note).contains(DATA.S_EXPORT_POSED), "11: the posed STL should be written with S-EXPORT-POSED (%s)." % [report])
	var box := _stl_box(path)
	var pose: PackedFloat64Array = SOLVER.solve(f.doc, f.result, kernel).poses[f.components.Lever]
	var want := AABB()
	var first := true
	for corner in [Vector3(-10, -10, 10), Vector3(95, -10, 10), Vector3(-10, 10, 10), Vector3(95, 10, 10), Vector3(-10, -10, 20), Vector3(95, -10, 20), Vector3(-10, 10, 20), Vector3(95, 10, 20)]:
		var p := XFORM.apply(pose, PackedFloat64Array([corner.x * MM, corner.y * MM, corner.z * MM]))
		var v := Vector3(p[0], p[1], p[2]) / MM
		want = AABB(v, Vector3.ZERO) if first else want.expand(v)
		first = false
	ok = _expect(box.position.distance_to(want.position) <= 1e-3 and box.end.distance_to(want.end) <= 1e-3, "11: the posed STL's box %s should be %s (mm, 1e-6 m)." % [box, want]) and ok
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	# Empty assembly: the same bytes as an export without the design (the body names an OBJ or 3MF
	# takes from the design, and a 3MF's zip time stamps, left out).
	var m := FIX.mesh_block(kernel)
	var kept_assembly: Dictionary = m.doc.assembly.duplicate(true)
	m.doc.assembly = {}
	var ids := [m.bodies.Base, m.bodies.Wall, m.bodies.Block]
	var same := PackedStringArray()
	for ext in ["stl", "step", "iges", "brep", "obj", "3mf"]:
		var with_doc := FOLDER.path_join("empty_doc." + ext)
		var without := FOLDER.path_join("empty_nodoc." + ext)
		var a := EXPORT.export_cad_report(kernel, m.result, ids, with_doc, m.doc)
		var b := EXPORT.export_cad_report(kernel, m.result, ids, without, null)
		var bytes_a := _comparable(with_doc)
		var bytes_b := _comparable(without)
		ok = _expect(FileAccess.file_exists(with_doc) and bytes_a == bytes_b and not str(a.note).contains(DATA.S_EXPORT_POSED),
			"11: .%s with an empty assembly should be byte-identical to the export without the design (%d vs %d bytes)." % [ext, bytes_a.size(), bytes_b.size()]) and ok
		same.append(".%s %d B" % [ext, bytes_a.size()])
		DirAccess.remove_absolute(ProjectSettings.globalize_path(with_doc))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(without))
	var posed_out := EXPORT.posed_bodies(kernel, m.result, ids, m.doc)
	ok = _expect(is_same(posed_out.bodies, m.result.bodies) and not bool(posed_out.posed), "11: an empty assembly leaves the result's bodies as they are.") and ok
	# A posed mesh body: the Block slid 5 mm along X.
	for joint in kept_assembly.joints:
		joint.dofs[0]["value"] = 5.0 * MM
	m.doc.assembly = kept_assembly
	var obj := FOLDER.path_join("posed_block.obj")
	var obj_report := EXPORT.export_cad_report(kernel, m.result, [m.bodies.Block], obj, m.doc)
	var low_x := INF
	for line in FileAccess.get_file_as_string(obj).split("\n"):
		if line.begins_with("v "):
			low_x = minf(low_x, line.split(" ")[1].to_float())
	ok = _expect(str(obj_report.error) == "" and absf(low_x - 5.0) <= 1e-3, "11: the Block mesh slid 5 mm should start at x = 5 mm in the OBJ (%.6f)." % low_x) and ok
	DirAccess.remove_absolute(ProjectSettings.globalize_path(obj))
	return {"ok": ok, "text": "posed Lever STL box %s mm; empty assembly byte-identical: %s; posed mesh Block OBJ min x %.4f mm" % [box, ", ".join(same), low_x]}


## 12. Timing (5.9): the RigidBody3D bake of chain(20) without the mesh bake.
func _c12_timing(kernel: RefCounted) -> Dictionary:
	var f := FIX.chain(20, kernel)
	var part := _part(f, CAD_PART.COMPONENT_RIGID_BODY)
	part.process_mode = Node.PROCESS_MODE_DISABLED
	var calibration := func() -> void:
		var x := 0.0
		for i in 200000:
			x += sin(float(i) * 1e-3)
	var joints := part.get_node("Joints").get_child_count()
	var t := TIMING.compare(func() -> void: part.bake_assembly(f.result), calibration, 5, "RigidBody3D bake chain(20)")
	var ok := _expect(joints == 20, "12: chain(20) should bake 20 joints (%d)." % joints)
	ok = _expect(float(t.ratio) <= RATIO_BAKE_20, "12: ratio %.4f over %.4f." % [t.ratio, RATIO_BAKE_20]) and ok
	_drop(part)
	return {"ok": ok, "text": "RigidBody3D bake chain(20) without meshes %.2f ms (ratio %.4f, limit %.4f; calibration %.2f ms; C9 target 1 s)" % [t.op, t.ratio, RATIO_BAKE_20, t.calibration]}


## 13. Inertia (fix round 1, B5): every RigidBody3D unit's inertia is set from INSPECT's tensor
## (its moments about the unit's own axes) and the engine uses it. Jolt holds no moments shorter
## than 1e-6 kg m² (checked here on a plain body; left to itself it gives such a body 0.4 m · 1 m²):
## all_types()' 10 mm steel cubes (1.3e-7 per axis) are raised to that floor and say so, and read
## back what the bake set; a 20 mm steel cube reads back inverse_inertia within 1 % of 6 / (m a²);
## the Lever, the slider's Block and the Gears within 1 % of INSPECT's moments, with no inertia note;
## four_bar()'s slanted bar BC has products of inertia: its diagonal is kept and the bake says so;
## an engine value more than 10 % off is told.
func _c13_inertia(kernel: RefCounted) -> Dictionary:
	var ok := true
	var texts := PackedStringArray()
	# The steel cubes.
	var f := FIX.all_types(kernel)
	var part := _part(f, CAD_PART.COMPONENT_RIGID_BODY)
	await physics_frame
	await physics_frame
	# (Jolt takes no moments shorter than 1e-6 kg m² as a vector, CAD_PART.JOLT_INERTIA_FLOOR: a
	# 10 mm steel cube's, 1.3e-7 per axis, are raised to it, ratios kept, and the bake says so.)
	var worst := 0.0
	var count := 0
	var cube_mass := 0.0
	var raised := 0.0
	var floor_notes := 0
	for child in part.get_children():
		var rb := child as RigidBody3D
		if rb == null:
			continue
		var got: Vector3 = PhysicsServer3D.body_get_direct_state(rb.get_rid()).inverse_inertia
		var true_moment := rb.mass * 0.01 * 0.01 / 6.0
		var set_moment := CAD_PART.JOLT_INERTIA_FLOOR / sqrt(3.0)
		ok = _expect(absf(rb.inertia.x / set_moment - 1.0) < 1e-5 and absf(rb.inertia.y / rb.inertia.x - 1.0) < 1e-5 and absf(rb.inertia.z / rb.inertia.x - 1.0) < 1e-5,
			"13: %s's inertia %s should be its m a² / 6 (%s) raised to Jolt's floor, %s per axis." % [rb.name, rb.inertia, true_moment, set_moment]) and ok
		for k in 3:
			worst = maxf(worst, absf(got[k] * rb.inertia[k] - 1.0))
		raised = set_moment / true_moment
		count += 1
		cube_mass = rb.mass
	var cube_notes: PackedStringArray = part.last_bake_report.get("notes", PackedStringArray())
	for note in cube_notes:
		floor_notes += 1 if note.contains("too small for Jolt") else 0
	ok = _expect(count == DATA.TYPES.size() and worst <= 0.01,
		"13: the %d 10 mm steel cubes should read back the inverse of the inertia the bake set within 1 %% (worst %.4f %%, %d cubes)." % [DATA.TYPES.size(), worst * 100.0, count]) and ok
	ok = _expect(floor_notes == DATA.TYPES.size() and not _note_has(cube_notes, "in the physics engine"),
		"13: each cube should say S-BAKE-INERTIA-FLOOR and none S-BAKE-INERTIA (%s)." % [cube_notes]) and ok
	texts.append("10 mm steel cubes (%.5f kg, m a² / 6 = %s): below Jolt's floor, raised %.2f× (Jolt alone: %.0f×), engine within %.4f %% of the bake's, S-BAKE-INERTIA-FLOOR told" % [cube_mass,
		String.num_scientific(cube_mass * 1e-4 / 6.0), raised, 0.4 / (1e-4 / 6.0), worst * 100.0])
	_drop(part)
	# A 20 mm steel cube (stack()'s Cube) is above the floor: inverse_inertia within 1 % of 6 / (m a²).
	var s := FIX.stack(kernel)
	part = _part(s, CAD_PART.COMPONENT_RIGID_BODY)
	await physics_frame
	await physics_frame
	var cube := part.get_node_or_null("Cube") as RigidBody3D
	var cube_err := INF
	if cube != null:
		var inverse: Vector3 = PhysicsServer3D.body_get_direct_state(cube.get_rid()).inverse_inertia
		var want := 6.0 / (cube.mass * 0.02 * 0.02)
		cube_err = 0.0
		for k in 3:
			cube_err = maxf(cube_err, absf(inverse[k] / want - 1.0))
	ok = _expect(cube_err <= 0.01 and not _note_has(part.last_bake_report.get("notes", PackedStringArray()), "inertia"),
		"13: a 20 mm steel cube should read back inverse_inertia within 1 %% of 6 / (m a²) with no inertia note (%.4f %%, %s)." % [cube_err * 100.0, part.last_bake_report.get("notes")]) and ok
	texts.append("20 mm steel cube: inverse_inertia within %.4f %% of 6 / (m a²)" % (cube_err * 100.0))
	_drop(part)
	# The Jolt fact behind the floor, on a plain body: a 1 kg box's inertia set to 0.9e-6 and 1.1e-6
	# kg m² as a vector length.
	var floor_text := PackedStringArray()
	for length in [0.9e-6, 1.1e-6]:
		var holder: Node3D = await _fresh()
		var probe := _body(holder, Transform3D.IDENTITY, "Probe")
		probe.mass = 1.0
		probe.inertia = Vector3.ONE * (length / sqrt(3.0))
		await physics_frame
		await physics_frame
		var back: Vector3 = PhysicsServer3D.body_get_direct_state(probe.get_rid()).inverse_inertia
		floor_text.append("|I| %s: engine I %s" % [String.num_scientific(length), String.num_scientific(1.0 / back.x)])
		var held := absf(back.x * probe.inertia.x - 1.0) <= 0.01
		ok = _expect(held == (length > 1e-6), "13: Jolt should %s an inertia %s long (engine %s)." % ["hold" if length > 1e-6 else "refuse", length, 1.0 / back.x]) and ok
	if _holder != null and is_instance_valid(_holder):
		_holder.free()
	texts.append("Jolt floor on a plain body: " + ", ".join(floor_text))
	# The Lever, the Block and the Gears against INSPECT.
	var gears := FIX.gears(kernel)
	for item in [["Lever", _lever_fixture(kernel, 30.0)], ["Block", FIX.slider_wall(kernel)], ["Gear1", gears], ["Gear2", gears]]:
		var name: String = item[0]
		var g: Dictionary = item[1]
		part = _part(g, CAD_PART.COMPONENT_RIGID_BODY)
		await physics_frame
		await physics_frame
		var rb := part.get_node_or_null(name) as RigidBody3D
		var tensor := PackedFloat64Array((INSPECT.mass_properties(g.doc, g.result, [g.bodies[name]]).bodies[g.bodies[name]] as Dictionary).inertia)
		var want := Vector3(tensor[0], tensor[4], tensor[8])
		var got := Vector3.ZERO
		var err := INF
		if rb != null:
			var inverse: Vector3 = PhysicsServer3D.body_get_direct_state(rb.get_rid()).inverse_inertia
			got = Vector3(1.0 / inverse.x, 1.0 / inverse.y, 1.0 / inverse.z)
			err = 0.0
			for k in 3:
				err = maxf(err, absf(got[k] / want[k] - 1.0))
		var notes: PackedStringArray = part.last_bake_report.get("notes", PackedStringArray())
		ok = _expect(err <= 0.01 and not _note_has(notes, "inertia"), "13: %s should read back INSPECT's moments %s within 1 %% (%s, %.4f %%) with no inertia note (%s)." % [name, want, got, err * 100.0, notes]) and ok
		texts.append("%s %s kg·m² (%.4f %%)" % [name, want, err * 100.0])
		if name == "Lever" and rb != null:
			# An engine value 10 % off is told: the Lever's inertia doubled in the engine behind the
			# bake's back (the node keeps the bake's).
			PhysicsServer3D.body_set_param(rb.get_rid(), PhysicsServer3D.BODY_PARAM_INERTIA, rb.inertia * 2.0)
			await physics_frame
			await physics_frame
			var told: Array = part.check_inertia() if part.has_method("check_inertia") else []
			ok = _expect(_note_has(PackedStringArray(told), "physics engine"), "13: a Lever whose engine inertia is twice the bake's should be told (%s)." % [told]) and ok
			texts.append("doubled Lever told: %s" % [told])
		_drop(part)
	# Products of inertia: four_bar()'s BC runs on a slant in XY.
	var bar := FIX.four_bar(kernel)
	part = _part(bar, CAD_PART.COMPONENT_RIGID_BODY)
	await physics_frame
	var bc := part.get_node_or_null("BC") as RigidBody3D
	var bc_tensor := PackedFloat64Array((INSPECT.mass_properties(bar.doc, bar.result, [bar.bodies.BC]).bodies[bar.bodies.BC] as Dictionary).inertia)
	var bc_want := Vector3(bc_tensor[0], bc_tensor[4], bc_tensor[8])
	var notes: PackedStringArray = part.last_bake_report.get("notes", PackedStringArray())
	var products_told := false
	for note in notes:
		products_told = products_told or (note.begins_with("BC") and note.contains("products of inertia"))
	ok = _expect(bc != null and absf(bc_tensor[1]) > 1e-3 * bc_want.z and bc.inertia.distance_to(bc_want) <= 1e-6 * bc_want.length() and products_told,
		"13: BC's inertia %s should be its tensor's diagonal %s (Ixy %s) and S-BAKE-INERTIA-PRODUCTS told (%s)." % [bc.inertia if bc != null else Vector3.ZERO, bc_want, bc_tensor[1], notes]) and ok
	texts.append("BC diagonal kept, Ixy %s kg·m², products told" % String.num_scientific(bc_tensor[1]))
	_drop(part)
	return {"ok": ok, "text": "; ".join(texts)}


## 14. Posed export in doubles (fix round 1, B4): the verifier's as-built revolute (Bar about Z
## through the Base's top, from an exact doubles frame) at 37°, built at the origin and 100 km out
## on X. Measured against the Bar as built, not the nominal box: the fixture places a Box through a
## float32 Vector3 (its "position" option, and the test's own Vector3 sums), so the built Bar is
## 1.7e-6 mm off the nominal at the origin and 9 mm 100 km out, before any export. The built Bar is
## read from an unposed .brep (15 significant digits). Limits are the files' own digits, per
## coordinate half a unit of the last digit written:
##   - posed .brep against the pose applied in doubles to the unposed .brep, vertex for vertex
##     (both files rounded): the move itself; a float32 move would be ~6 mm off 100 km out;
##   - the posed STEP's nearest point to the built tip turned about the exact axis: OCCT's STEP
##     writer gives 13 significant digits, 1e-4 mm per digit at 1e8 mm (bound 8.7e-5 mm there).
func _c14_far_export(kernel: RefCounted) -> Dictionary:
	if not kernel.has_method("transform_shape64"):
		return {"ok": false, "text": "the kernel has no transform_shape64 (team N's native build is not in): posed export still moves bodies in float32"}
	var ok := true
	var texts := PackedStringArray()
	var point := RegEx.create_from_string("CARTESIAN_POINT\\('[^']*',\\(\\s*([-0-9.E+]+)\\s*,\\s*([-0-9.E+]+)\\s*,\\s*([-0-9.E+]+)\\s*\\)")
	var th := deg_to_rad(37.0)
	for offx: float in [0.0, 1e8]:
		var off := Vector3(offx, 0, 0)
		var f := FIX._start(kernel)
		FIX._box(f, "Base", Vector3(-50, -50, 0) + off, Vector3(50, 50, 10) + off, "")
		FIX._box(f, "Bar", Vector3(-10, -10, 10) + off, Vector3(95, 10, 20) + off, "Bar")
		FIX._rebuild(f)
		var world := XFORM.frame(PackedFloat64Array([offx * MM, 0.0, 10.0 * MM]), PackedFloat64Array([0.0, 0.0, 1.0]))
		FIX.add_as_built_frame(f.doc, "revolute", f.components.Bar, "", world)
		var a: Dictionary = DATA.normalized(f.doc.assembly)
		a.joints[0].dofs[0]["value"] = th
		f.doc.assembly = a
		var pose: PackedFloat64Array = SOLVER.solve(f.doc, f.result, kernel).body_poses[f.bodies.Bar]
		var unposed_doc: Resource = f.doc.duplicate()
		unposed_doc.assembly = {}
		var files := {}
		var report := {}
		for item in [["plain", "brep", unposed_doc], ["posed", "brep", f.doc], ["posed", "step", f.doc]]:
			var path := FOLDER.path_join("far_%s_%d.%s" % [item[0], int(offx), item[1]])
			var made := EXPORT.export_cad_report(kernel, f.result, [f.bodies.Bar], path, item[2])
			if item[0] == "posed":
				report = made
				ok = _expect(str(made.error) == "" and str(made.note).contains(DATA.S_EXPORT_POSED), "14: the posed .%s should be written with S-EXPORT-POSED (%s)." % [item[1], made]) and ok
			files["%s.%s" % [item[0], item[1]]] = FileAccess.get_file_as_string(path)
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		# The move: posed .brep against the pose applied in doubles to the unposed one (meters).
		var plain := _brep_vertices(files["plain.brep"])
		var posed := _brep_vertices(files["posed.brep"])
		var move_err := 0.0
		var move_limit := INF
		if plain.size() == posed.size() and plain.size() > 0:
			move_limit = 0.0
			for i in plain.size():
				var want := XFORM.apply(pose, plain[i])
				move_err = maxf(move_err, _distance64(want, posed[i]))
				move_limit = maxf(move_limit, _digits_bound(plain[i], 15) + _digits_bound(posed[i], 15) + 1e-15 * _length64(want))
		ok = _expect(move_err <= move_limit, "14: %s mm out, the posed .brep should be the pose applied in doubles to the unposed .brep within the files' digits (%s mm, limit %s mm, %d/%d vertices)." % [offx,
			String.num_scientific(move_err / MM), String.num_scientific(move_limit / MM), posed.size(), plain.size()]) and ok
		# STEP: the built tip (the unposed .brep's vertex nearest the nominal tip) turned about the
		# exact axis, against the posed STEP's nearest point (mm).
		var nominal := PackedFloat64Array([(offx + 95.0) * MM, 10.0 * MM, 20.0 * MM])
		var built := PackedFloat64Array()
		for v in plain:
			if built.is_empty() or _distance64(v, nominal) < _distance64(built, nominal):
				built = v
		var tip_err := INF
		var tip_limit := INF
		var fixture_off := INF
		if not built.is_empty():
			fixture_off = _distance64(built, nominal) / MM
			var rx := built[0] / MM - offx
			var ry := built[1] / MM
			var tip := PackedFloat64Array([offx + rx * cos(th) - ry * sin(th), rx * sin(th) + ry * cos(th), built[2] / MM])
			for found in point.search_all(files["posed.step"]):
				var p := PackedFloat64Array([found.get_string(1).to_float(), found.get_string(2).to_float(), found.get_string(3).to_float()])
				tip_err = minf(tip_err, _distance64(p, tip))
			tip_limit = _digits_bound(tip, 13) + _digits_bound(built, 15) / MM + 1e-15 * _length64(tip)
		ok = _expect(tip_err <= tip_limit, "14: %s mm out, the posed STEP should hold the built tip turned by 37° within STEP's 13 digits (%s mm, limit %s mm)." % [offx,
			String.num_scientific(tip_err), String.num_scientific(tip_limit)]) and ok
		texts.append("%s km: .brep move %s mm (limit %s), STEP tip %s mm (limit %s; fixture's float32 Bar %s mm off the nominal)" % [offx * 1e-6, String.num_scientific(move_err / MM),
			String.num_scientific(move_limit / MM), String.num_scientific(tip_err), String.num_scientific(tip_limit), String.num_scientific(fixture_off)])
	return {"ok": ok, "text": "posed export at 37°: " + "; ".join(texts)}


## The vertex points of .brep text ("Ve" records: a tolerance line, then x y z), in meters.
func _brep_vertices(text: String) -> Array:
	var lines := text.split("\n")
	var out := []
	for i in lines.size() - 2:
		if lines[i].strip_edges() == "Ve":
			var xyz := lines[i + 2].strip_edges().split(" ", false)
			if xyz.size() >= 3:
				out.append(PackedFloat64Array([xyz[0].to_float(), xyz[1].to_float(), xyz[2].to_float()]))
	return out


## How far a point written with that many significant digits per coordinate can be from its value:
## half a unit of the last digit on each coordinate, as a length.
func _digits_bound(p: PackedFloat64Array, digits: int) -> float:
	var sum := 0.0
	for k in 3:
		if p[k] != 0.0:
			var half := 0.5 * pow(10.0, floorf(log(absf(p[k])) / log(10.0)) - (digits - 1))
			sum += half * half
	return sqrt(sum)


func _distance64(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	return sqrt(pow(a[0] - b[0], 2) + pow(a[1] - b[1], 2) + pow(a[2] - b[2], 2))


func _length64(a: PackedFloat64Array) -> float:
	return sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2])


# --- Bake helpers ----------------------------------------------------------------------------------

## A CadPart of fixture f under the root, baked in mode at pose.
func _part(f: Dictionary, mode := 0, pose := 0, joints := true) -> Node3D:
	var part: Node3D = CAD_PART.new()
	part.name = "Part"
	part.document = f.doc
	part.component_node_type = mode
	part.bake_pose = pose
	part.bake_joints = joints
	root.add_child(part)
	part.apply_result(f.result)
	return part


func _drop(part: Node) -> void:
	if part != null and is_instance_valid(part):
		if part.get_parent() != null:
			part.get_parent().remove_child(part)
		part.free()


## lever() with a revolute Joint1 from the Lever's bottom hole circle to the Base's top hole circle
## (about part Z at z = 10 mm), value value_deg, limits -30°..90°, rest rest_deg.
func _lever_fixture(kernel: RefCounted, value_deg: float, rest_deg := 0.0) -> Dictionary:
	var f := FIX.lever(kernel)
	_lever_joint(f, value_deg, rest_deg)
	return f


func _lever_joint(f: Dictionary, value_deg: float, rest_deg := 0.0) -> void:
	var snap_a := FIX.circle_snap(f, "Lever", Vector3(0, 0, 10), 5.0)
	var snap_b := FIX.circle_snap(f, "Base", Vector3(0, 0, 10), 5.0)
	var dof := {"value": deg_to_rad(value_deg), "min": deg_to_rad(-30.0), "max": deg_to_rad(90.0), "limited_min": true, "limited_max": true, "rest": deg_to_rad(rest_deg)}
	f.joints["Joint1"] = FIX.add_joint(f.doc, "revolute", f.components.Lever, snap_a, "", snap_b, {"dofs": [dof]})


## A joint node's class, paths, transform and storable properties as text (for case 9).
func _joint_values(node: Node) -> String:
	var parts := PackedStringArray([node.get_class(), str(node.get("node_a")), str(node.get("node_b")), str(node.get("transform"))])
	for property in node.get_property_list():
		var property_name := str(property.name)
		if int(property.usage) & PROPERTY_USAGE_STORAGE and (property_name.contains("limit") or property_name.contains("span") or property_name.contains("motor")):
			parts.append("%s=%s" % [property_name, var_to_str(node.get(property_name))])
	return "\n".join(parts)


func _note_has(notes: PackedStringArray, text: String) -> bool:
	for note in notes:
		if note.contains(text):
			return true
	return false


func _has_note(notes: PackedStringArray, start: String) -> bool:
	for note in notes:
		if note.begins_with(start):
			return true
	return false


## The bounding box (file units) of a binary STL.
func _stl_box(path: String) -> AABB:
	var data := FileAccess.get_file_as_bytes(path)
	if data.size() < 84:
		return AABB()
	var count := data.decode_u32(80)
	var box := AABB()
	var first := true
	for t in count:
		for corner in 3:
			var at := 84 + t * 50 + 12 + corner * 12
			var v := Vector3(data.decode_float(at), data.decode_float(at + 4), data.decode_float(at + 8))
			box = AABB(v, Vector3.ZERO) if first else box.expand(v)
			first = false
	return box


## A file's bytes for comparing two exports made one after the other: in a STEP file the header's
## time stamp and the translator's per-session product and usage numbers are left out (they differ
## between any two exports of one session); an OBJ's object names; a 3MF's model with its object
## names (its zip has time stamps).
func _comparable(path: String) -> PackedByteArray:
	var bytes := FileAccess.get_file_as_bytes(path)
	match path.get_extension():
		"obj":
			var kept := PackedStringArray()
			for line in bytes.get_string_from_utf8().split("
"):
				kept.append("o" if line.begins_with("o ") else line)
			return "
".join(kept).to_utf8_buffer()
		"3mf":
			var zip := ZIPReader.new()
			if zip.open(ProjectSettings.globalize_path(path)) != OK:
				return PackedByteArray()
			var model := zip.read_file("3D/3dmodel.model").get_string_from_utf8()
			zip.close()
			return RegEx.create_from_string(" name=\"[^\"]*\"").sub(model, "", true).to_utf8_buffer()
		"step":
			pass
		_:
			return bytes
	var text := bytes.get_string_from_utf8()
	var counted := RegEx.create_from_string("(translator \\S+) [0-9.]+'|(NEXT_ASSEMBLY_USAGE_OCCURRENCE\\()'[0-9]+'")
	var lines := PackedStringArray()
	for line in text.split("\n"):
		if line.contains("FILE_NAME"):
			continue
		lines.append(counted.sub(line, "$1$2'", true))
	return "\n".join(lines).to_utf8_buffer()


func _aabb_close(a: AABB, b: AABB) -> bool:
	return a.position.distance_to(b.position) < 1e-6 and a.size.distance_to(b.size) < 1e-6


func _case(id: String, result: Dictionary) -> void:
	if bool(result.get("ok", false)):
		print("PASS %s: %s" % [id, str(result.get("text", ""))])
	else:
		print("FAIL %s: %s" % [id, str(result.get("text", ""))])
		_expect(false, "case %s failed" % id)


func _fact(id: String, ok: bool, text: String) -> void:
	facts.append("%s: %s" % [id, text])
	if ok:
		print("PASS %s: %s" % [id, text])
	else:
		_expect(false, "%s: %s" % [id, text])


# --- Helpers -------------------------------------------------------------------------------------

func _expect(condition: bool, message: String) -> bool:
	if not condition:
		failures.append(message)
		push_error(message)
		print("FAIL: ", message)
	return condition
