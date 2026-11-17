@tool
extends RefCounted
## The joint relation in doubles (Holo Forge Phase 8, contracts C2.4, C2.5, C3.4 and C3.6).
##
## Side a moves, side b is the base. With F_a, F_b the resolved snap frames (modelled coordinates):
##   F'_a = F_a · R_x(π)                       (Z reversed: face meets face; as-built joints: F_a)
##   O    = T(offset) · R_z(angle) · (flip ? R_x(π) : I)   (as-built joints: I)
##   P_a · F'_a = P_b · F_b · O · M(v)         (the joint relation)
## M(v) per type is in motion(). Every value is an xform64 (core/assembly/xform64.gd); lengths in
## meters, angles in radians, unwrapped (720° stays 4π). Static functions, no state.

const XFORM := preload("res://addons/holo_forge/core/assembly/xform64.gd")
const DATA := preload("res://addons/holo_forge/core/assembly/assembly_data.gd")
const UNITS := preload("res://addons/holo_forge/core/units.gd")

## R_x(π) written out, so a turn-over is exact (rot_x(PI) would leave sin(π) = 1.2e-16 in it).
const TURN_X := [1.0, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0]
## Residuals at or below these count as zero (C3.4 S-LOOP-HOLDS, C3.6 post-check).
const HOLD_M := 1e-9
const HOLD_RAD := 1e-9


static func turn_x() -> PackedFloat64Array:
	return PackedFloat64Array(TURN_X)


## A unit vector of an axis letter ("x" | "y" | "z").
static func axis_vector(axis: String) -> PackedFloat64Array:
	match axis:
		"x":
			return PackedFloat64Array([1.0, 0.0, 0.0])
		"y":
			return PackedFloat64Array([0.0, 1.0, 0.0])
	return PackedFloat64Array([0.0, 0.0, 1.0])


## The slide axis a joint uses (slider: "x" | "y" | "z", default z; pin-slot: "x" | "y", default x).
static func slide_axis(joint: Dictionary) -> String:
	var joint_type := str(joint.get("type", DATA.DEFAULT_TYPE))
	var axis := str(joint.get("slide_axis", DATA.DEFAULT_SLIDE_AXIS.get(joint_type, "z")))
	if joint_type == "pin_slot" and axis == "z":
		axis = "x"
	return axis if axis in ["x", "y", "z"] else str(DATA.DEFAULT_SLIDE_AXIS.get(joint_type, "z"))


## M(v) for a joint type (C2.5); values in the type's DOF order (missing ones count as 0).
static func motion(joint_type: String, axis: String, values: PackedFloat64Array) -> PackedFloat64Array:
	var v := func(i: int) -> float: return values[i] if i < values.size() else 0.0
	match joint_type:
		"revolute":
			return XFORM.rot_z(v.call(0))
		"slider":
			return _slide(axis, v.call(0))
		"cylindrical":
			return XFORM.compose(XFORM.translation(0.0, 0.0, v.call(0)), XFORM.rot_z(v.call(1)))
		"pin_slot":
			return XFORM.compose(_slide(axis, v.call(1)), XFORM.rot_z(v.call(0)))
		"planar":
			return XFORM.compose(XFORM.translation(v.call(0), v.call(1), 0.0), XFORM.rot_z(v.call(2)))
		"ball":
			return XFORM.compose(XFORM.rot_x(v.call(0)), XFORM.compose(XFORM.rot_y(v.call(1)), XFORM.rot_z(v.call(2))))
	return XFORM.identity()


static func _slide(axis: String, s: float) -> PackedFloat64Array:
	var a := axis_vector(axis)
	return XFORM.translation(a[0] * s, a[1] * s, a[2] * s)


## O = T(offset) · R_z(angle) · (flip ? R_x(π) : I) for a joint (or an origin); I for an as-built
## joint.
static func offset_xform(entry: Dictionary) -> PackedFloat64Array:
	if bool(entry.get("as_built", false)):
		return XFORM.identity()
	var offset: Variant = entry.get("offset", [0.0, 0.0, 0.0])
	var o := PackedFloat64Array([0.0, 0.0, 0.0])
	if offset is Array or offset is PackedFloat64Array:
		var list := PackedFloat64Array(offset)
		if list.size() == 3:
			o = list
	var out := XFORM.compose(XFORM.translation(o[0], o[1], o[2]), XFORM.rot_z(float(entry.get("angle", 0.0))))
	if bool(entry.get("flip", false)):
		out = XFORM.compose(out, turn_x())
	return out


## F'_a: side a's frame turned over (Z reversed), or as it is for an as-built joint.
static func turned(frame_a: PackedFloat64Array, as_built := false) -> PackedFloat64Array:
	return frame_a if as_built else XFORM.compose(frame_a, turn_x())


## P_a from P_b: P_b · F_b · O · M · F'_a⁻¹ (frames already in each unit's coordinates).
static func place_a(pose_b: PackedFloat64Array, frame_b: PackedFloat64Array, o: PackedFloat64Array, m: PackedFloat64Array,
		turned_a: PackedFloat64Array) -> PackedFloat64Array:
	return XFORM.compose(XFORM.compose(XFORM.compose(XFORM.compose(pose_b, frame_b), o), m), XFORM.inverse(turned_a))


## P_b from P_a: P_a · F'_a · M⁻¹ · O⁻¹ · F_b⁻¹.
static func place_b(pose_a: PackedFloat64Array, turned_a: PackedFloat64Array, m: PackedFloat64Array, o: PackedFloat64Array,
		frame_b: PackedFloat64Array) -> PackedFloat64Array:
	var out := XFORM.compose(pose_a, turned_a)
	out = XFORM.compose(out, XFORM.inverse(m))
	out = XFORM.compose(out, XFORM.inverse(o))
	return XFORM.compose(out, XFORM.inverse(frame_b))


## How far the relation is from holding (C3.6): {"m": the distance between the two sides' origins,
## "rad": the angle between their bases}.
static func relation_error(pose_a: PackedFloat64Array, turned_a: PackedFloat64Array, pose_b: PackedFloat64Array, frame_b: PackedFloat64Array,
		o: PackedFloat64Array, m: PackedFloat64Array) -> Dictionary:
	var left := XFORM.compose(pose_a, turned_a)
	var right := XFORM.compose(XFORM.compose(XFORM.compose(pose_b, frame_b), o), m)
	return {"m": XFORM.distance(left, right), "rad": XFORM.angle_between(left, right)}


## A loop joint's residual (C3.4): with R = (P_b · F_b · O)⁻¹ · (P_a · F'_a), the part of R's
## origin not along the type's slide directions and the angle of R's basis not about its rotation
## axes. {"m", "rad", "implied": PackedFloat64Array (the DOF values R stands for, unwrapped to
## within a half turn of 0)}.
static func loop_residual(joint_type: String, axis: String, r: PackedFloat64Array) -> Dictionary:
	var origin := PackedFloat64Array([r[9], r[10], r[11]])
	var free := PackedFloat64Array([0.0, 0.0, 0.0])
	match joint_type:
		"slider", "pin_slot":
			free = axis_vector(axis)
		"cylindrical":
			free = PackedFloat64Array([0.0, 0.0, 1.0])
	var along := origin[0] * free[0] + origin[1] * free[1] + origin[2] * free[2]
	var rest := PackedFloat64Array([origin[0] - along * free[0], origin[1] - along * free[1], origin[2] - along * free[2]])
	var off_m := sqrt(rest[0] * rest[0] + rest[1] * rest[1] + rest[2] * rest[2])
	if joint_type == "planar":
		off_m = absf(origin[2])
	var off_rad := 0.0
	match joint_type:
		"revolute", "cylindrical", "pin_slot", "planar":
			# The angle between R's Z and Z.
			off_rad = atan2(sqrt(r[6] * r[6] + r[7] * r[7]), r[8])
		"rigid", "slider":
			off_rad = XFORM.angle_between(XFORM.identity(), r)
	var turn := atan2(r[1], r[0])
	var implied := PackedFloat64Array()
	match joint_type:
		"revolute":
			implied = PackedFloat64Array([turn])
		"slider":
			implied = PackedFloat64Array([along])
		"cylindrical":
			implied = PackedFloat64Array([along, turn])
		"pin_slot":
			implied = PackedFloat64Array([turn, along])
		"planar":
			implied = PackedFloat64Array([origin[0], origin[1], turn])
		"ball":
			implied = ball_angles(r)
	return {"m": off_m, "rad": off_rad, "implied": implied}


## The angles (α, β, γ) of R = R_x(α) · R_y(β) · R_z(γ).
static func ball_angles(r: PackedFloat64Array) -> PackedFloat64Array:
	# Columns: X = (r0, r1, r2), Y = (r3, r4, r5), Z = (r6, r7, r8); element row i col j = r[j*3+i].
	var beta := asin(clampf(r[6], -1.0, 1.0))
	var alpha := atan2(-r[7], r[8])
	var gamma := atan2(-r[3], r[0])
	return PackedFloat64Array([alpha, beta, gamma])


## True when a type's DOF i is a rotation.
static func dof_is_rotation(joint_type: String, i: int) -> bool:
	var names := DATA.dof_names(joint_type)
	return i >= 0 and i < names.size() and DATA.is_rotation(str(names[i]))


## The values a joint's DOFs hold: overrides first, then the stored values, each clamped to its
## limits (C3.3). The limit is assigned, not computed, so a clamped value equals it exactly.
static func joint_values(joint: Dictionary, forced := {}) -> PackedFloat64Array:
	var values := PackedFloat64Array()
	var dofs: Array = joint.get("dofs", [])
	for i in dofs.size():
		var dof: Dictionary = dofs[i] if dofs[i] is Dictionary else DATA.DOF_DEFAULT
		var value := float(forced[i]) if forced.has(i) else float(dof.get("value", 0.0))
		values.append(clamp_value(dof, value))
	return values


## value held to a DOF's limits (each end only when it is on); the limit itself when it binds.
## Reversed limits (both on, Min above Max: a hand edit, S-LIMITS-REVERSED) hold nothing: the
## value stays as it is (fix round 2, PT4), so the stored value is what a solve shows and what a
## refused drive keeps.
static func clamp_value(dof: Dictionary, value: float) -> float:
	if bool(dof.get("limited_min", false)) and bool(dof.get("limited_max", false)) and float(dof.get("min", 0.0)) > float(dof.get("max", 0.0)):
		return value
	if bool(dof.get("limited_min", false)) and value < float(dof.get("min", 0.0)):
		return float(dof.min)
	if bool(dof.get("limited_max", false)) and value > float(dof.get("max", 0.0)):
		return float(dof.max)
	return value


## A length for a sentence (C10): document units with up to 4 decimals; a value too small to show
## that way is written in scientific form ("2.3e-07 mm").
static func format_length(value: float, units: String) -> String:
	var scale := float(UNITS.LENGTH_UNITS.get(units, 0.001))
	var shown := value / scale
	if shown != 0.0 and absf(shown) < 5e-5 and is_finite(shown):
		return "%s %s" % [String.num_scientific(snappedf(shown, pow(10.0, floorf(log(absf(shown)) / log(10.0)) - 2.0))), units]
	return UNITS.format_value(value, UNITS.KIND_LENGTH, units)


## An angle for a sentence: degrees with up to 4 decimals and the degree sign ("90°").
static func format_angle(radians: float) -> String:
	var shown := rad_to_deg(radians)
	if shown != 0.0 and absf(shown) < 5e-5 and is_finite(shown):
		return "%s°" % String.num_scientific(snappedf(shown, pow(10.0, floorf(log(absf(shown)) / log(10.0)) - 2.0)))
	var text := String.num(snappedf(shown, 1e-4), 4)
	if text.contains("."):
		text = text.rstrip("0").rstrip(".")
	return text + "°"


## A DOF value in its unit (an angle for a rotation, else a length).
static func format_dof(joint_type: String, dof: int, value: float, units: String) -> String:
	return format_angle(value) if dof_is_rotation(joint_type, dof) else format_length(value, units)


## The frames of an as-built joint (C2.4): with W the picked frame in part space at the current
## poses, F_b = P_b⁻¹ · W and F'_a = P_a⁻¹ · W, so the relation holds where the parts are now.
## Returns [frame_a, frame_b] (side a's is stored as it is: as-built joints are not turned over).
static func as_built_frames(pose_a: PackedFloat64Array, pose_b: PackedFloat64Array, world: PackedFloat64Array) -> Array:
	return [XFORM.compose(XFORM.inverse(pose_a), world), XFORM.compose(XFORM.inverse(pose_b), world)]
