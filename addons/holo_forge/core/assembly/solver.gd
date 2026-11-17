@tool
extends RefCounted
## The assembly solver (Holo Forge Phase 8, contract C3).
##
## solve() works out where every component and body of a part sits, from the document's assembly
## (core/assembly/assembly_data.gd) and a rebuild's result (bodies in part space, as modelled).
## Every pose is an xform64 in doubles (core/assembly/xform64.gd); Transform3D copies are made only
## for the view and the bake ("transforms").
##
## No iteration (C3.2): the units (top-level components, plus the ground "") and the joints and
## rigid groups between them make a graph; a breadth-first search from the fixed units places each
## unit it reaches with the joint relation (core/assembly/joint_math.gd, C2.4), forward or reversed.
## A joint between two units already placed closes a loop: it is measured, not enforced (C3.4).
## Units no fixed unit reaches are searched from their first unit in browser order, at its
## placement. Then nested components (parent pose · placement) and the post-check (C3.6).

const XFORM := preload("res://addons/holo_forge/core/assembly/xform64.gd")
const DATA := preload("res://addons/holo_forge/core/assembly/assembly_data.gd")
const JOINT_MATH := preload("res://addons/holo_forge/core/assembly/joint_math.gd")
const SNAPS := preload("res://addons/holo_forge/core/assembly/snaps.gd")

const STATE_OK := "ok"
const STATE_LOOP := "loop"
const STATE_UNRESOLVED := "unresolved"
const STATE_WAITING := "waiting"
const STATE_SUPPRESSED := "suppressed"
const STATE_ERROR := "error"
## How deep components may nest before the chain counts as broken (a parent cycle in a damaged
## file).
const MAX_NESTING := 64
## The ground's unit id.
const GROUND := ""
## S-SNAP-FAR (fix round 2, PT5): native queries give float32 positions, which step by
## 2^(floor(log2 d) - 23) m at d m from the origin. A snap found on geometry is warned when that
## step is above the assembly's contact tolerance (contact.tolerance; CONTACT_DEFAULT's when it is
## not a finite number above 0): from 128 m out at the default 10 µm, from 2,048 m at 0.1 mm.

## Test seam (5.2 #22): when true, solve() moves one jointed unit by 1e-6 m after solving, so the
## post-check must catch it. Never set outside tests.
static var debug_corrupt := false

## What the last solve read, so the next one with the same inputs (a drive, a study frame, a
## preview: only overrides differ) skips normalizing the assembly and resolving the joints again.
## Inputs are compared by content (the assembly against a deep copy, the components, bodies and
## timeline), the result by identity: a new rebuild gives a new result.
static var _memo := {}


## The poses of a document's components and bodies (spec C3.1):
## {"poses": {comp_id: xform64} (every component, part space; the ground "" is not listed: it is
## identity), "body_poses": {body_id: xform64}, "transforms": {comp_id: Transform3D} (float32,
## local to the parent component), "joints": {joint_id: {"state", "values": PackedFloat64Array,
## "residual_m", "residual_rad", "frame_a", "frame_b" (the resolved snap frames, modelled
## coordinates of each snap's body), "world" (P_b · F_b · O, part space), "sentence", "lost" (a
## snap that did not resolve), "implied" (loop joints: the DOF values the poses stand for)}},
## "units": {comp_id: {"fixed", "root", "reached_by"}} (top-level components only; "fixed" when the
## unit hangs from the ground or a grounded unit, "root" is "" then, else the unit its free group
## is rooted at), "warnings": PackedStringArray, "ms": float}.
## overrides = {joint_id: {dof_index: value}} for previews, drives and studies; never stored
## (clamped to the limits like stored values, C3.3).
static func solve(doc: Resource, result: Dictionary, kernel: RefCounted, overrides := {}) -> Dictionary:
	var started := Time.get_ticks_usec()
	var out := {
		"poses": {}, "body_poses": {}, "transforms": {}, "joints": {}, "units": {}, "warnings": PackedStringArray(), "ms": 0.0,
	}
	if doc == null:
		return out
	var stored: Variant = doc.get("assembly")
	var s := _Solve.new()
	_read(s, doc, stored if stored is Dictionary else {}, result)
	var assembly: Dictionary = s.assembly
	var t_read := Time.get_ticks_usec()
	var components: Dictionary = doc.components
	var warnings: PackedStringArray = out.warnings
	# A hand edit found when the document was loaded (S-EXACT-EDITED).
	if stored is Dictionary:
		warnings.append_array(DATA.load_notes(stored))
	var poses: Dictionary = out.poses
	var units: Dictionary = out.units
	var joints_out: Dictionary = out.joints
	# Units in browser order (the order of doc.components), each at its placement for now.
	var order := []
	for component_id in components:
		var id := str(component_id)
		if parent_of(components, id) == "":
			order.append(id)
			s.placement[id] = _valid_placement(doc, assembly, id, warnings)
	# Edges: joints in stored order, then rigid groups.
	var edges := []
	for joint in assembly.joints:
		if joint is Dictionary:
			var edge := _joint_edge(s, joint, overrides, warnings)
			joints_out[edge.id] = edge.entry
			if edge.live:
				edges.append(edge)
	for group in assembly.rigid_groups:
		if group is Dictionary and not bool(group.get("suppressed", false)):
			edges.append_array(_group_edges(s, group))
	var t_edges := Time.get_ticks_usec()
	var adjacency := {GROUND: []}
	for id in order:
		adjacency[id] = []
	for i in edges.size():
		var edge: Dictionary = edges[i]
		if not adjacency.has(edge.u_a) or not adjacency.has(edge.u_b):
			continue
		adjacency[edge.u_a].append(i)
		if edge.u_b != edge.u_a:
			adjacency[edge.u_b].append(i)
	# Breadth-first search from the fixed set: the ground, then grounded units in browser order.
	var unit_pose := {GROUND: XFORM.identity()}
	var used := {}
	var fixed := [GROUND]
	for id in order:
		if DATA.is_grounded(assembly, id):
			fixed.append(id)
			unit_pose[id] = s.placement[id]
	for id in fixed:
		units[id] = {"fixed": true, "root": "", "reached_by": ""}
	_search(fixed, edges, adjacency, unit_pose, used, units, true, "", s)
	for id in order:
		if unit_pose.has(id):
			continue
		unit_pose[id] = s.placement[id]
		units[id] = {"fixed": false, "root": id, "reached_by": ""}
		_search([id], edges, adjacency, unit_pose, used, units, false, id, s)
	units.erase(GROUND)
	# Component poses: units from the search, nested ones from their parents.
	for id in order:
		poses[id] = unit_pose[id]
	if debug_corrupt:
		for edge in edges:
			if edge.kind == "joint" and str(edge.entry.state) == STATE_OK:
				var moved_unit: String = edge.reached if edge.reached != "" else edge.u_a
				if moved_unit != GROUND and poses.has(moved_unit):
					var moved := PackedFloat64Array(poses[moved_unit])
					moved[9] += 1e-6
					poses[moved_unit] = moved
					unit_pose[moved_unit] = moved
					break
	for component_id in components:
		_nested_pose(doc, assembly, components, str(component_id), poses, out.transforms, warnings, 0)
	for id in order:
		out.transforms[id] = XFORM.to_transform(poses[id])
	_check_poses(doc, s, order, poses, unit_pose, out.transforms, warnings)
	var t_search := Time.get_ticks_usec()
	# Post-check (C3.6) and loop residuals (C3.4).
	for edge in edges:
		if edge.kind == "group":
			if bool(edge.get("loop", false)):
				_group_loop(s, edge, unit_pose, warnings)
			continue
		var entry: Dictionary = edge.entry
		var pose_a: PackedFloat64Array = unit_pose.get(edge.u_a, XFORM.identity())
		var pose_b: PackedFloat64Array = unit_pose.get(edge.u_b, XFORM.identity())
		entry["world"] = XFORM.compose(XFORM.compose(pose_b, edge.fb), edge.o)
		if str(entry.state) == STATE_LOOP:
			_loop(s, edge, pose_a, pose_b, warnings)
			continue
		var off := JOINT_MATH.relation_error(pose_a, edge.ta, pose_b, edge.fb, edge.o, edge.m)
		entry["residual_m"] = float(off.m)
		entry["residual_rad"] = float(off.rad)
		if not (float(off.m) <= JOINT_MATH.HOLD_M and float(off.rad) <= JOINT_MATH.HOLD_RAD):
			entry["state"] = STATE_ERROR
			entry["sentence"] = DATA.fill(DATA.S_SOLVE_FAULT, {
				"Joint": edge.name, "d": JOINT_MATH.format_length(float(off.m), str(doc.units)), "a": JOINT_MATH.format_angle(float(off.rad)),
			})
			warnings.append(entry.sentence)
	var t_check := Time.get_ticks_usec()
	for body_id in _body_ids(doc, result):
		var component_id := str(doc.body_component(body_id))
		out.body_poses[body_id] = poses[component_id] if poses.has(component_id) else XFORM.identity()
	var ended := Time.get_ticks_usec()
	out["ms"] = float(ended - started) / 1000.0
	# Where the time went (C9 asks for the split when a target is missed): reading the assembly,
	# the joints (snaps, frames, M), the search with the poses, the post-check, the body poses.
	out["split"] = {
		"read_ms": (t_read - started) / 1000.0, "joints_ms": (t_edges - t_read) / 1000.0, "search_ms": (t_search - t_edges) / 1000.0,
		"check_ms": (t_check - t_search) / 1000.0, "bodies_ms": (ended - t_check) / 1000.0,
	}
	return out


## Forgets what the last solve read (and the snap cache).
static func clear_cache() -> void:
	_memo = {}
	SNAPS.clear_cache()


## Fills s with the normalized assembly and the solve's inputs, reusing the last solve's when they
## are the same (see _memo).
static func _read(s: _Solve, doc: Resource, stored: Dictionary, result: Dictionary) -> void:
	s.doc = doc
	s.result = result
	s.components = doc.components
	s.active = doc.active_count()
	var same_assembly: bool = not _memo.is_empty() and is_same(_memo.doc, doc) and is_same(_memo.source, stored) and stored == _memo.copy
	if same_assembly:
		s.assembly = _memo.normalized
	else:
		s.assembly = DATA.normalized(stored)
	var features: Array = doc.features
	var same_inputs: bool = (same_assembly and is_same(_memo.result, result) and int(_memo.active) == s.active and doc.components == _memo.components
		and doc.bodies == _memo.bodies and features == _memo.features)
	if same_inputs:
		s.feature_at = _memo.feature_at
		s.statics = _memo.statics
		return
	for i in features.size():
		if features[i] != null:
			s.feature_at[str(features[i].id)] = i
	_memo = {
		"doc": doc, "source": stored, "copy": stored.duplicate(true), "normalized": s.assembly, "result": result, "active": s.active,
		"components": (doc.components as Dictionary).duplicate(true), "bodies": (doc.bodies as Dictionary).duplicate(true),
		"features": features.duplicate(), "feature_at": s.feature_at, "statics": s.statics,
	}


## What one solve works with (kept together so the helpers take one argument for it).
class _Solve:
	extends RefCounted
	var doc: Resource
	var result: Dictionary
	var assembly: Dictionary
	var components: Dictionary
	var active: int = 0
	## Top-level component -> its valid placement.
	var placement := {}
	## Feature id -> timeline index (is_waiting()).
	var feature_at := {}
	## Component -> is_waiting() (asked once per component).
	var waiting := {}
	## Joint id -> _joint_static() (kept between solves while nothing it depends on changes).
	var statics := {}


## is_waiting() once per component and solve.
static func _waiting(s: _Solve, component_id: String) -> bool:
	if not s.waiting.has(component_id):
		s.waiting[component_id] = component_id != "" and is_waiting(s.doc, s.components, component_id, s.feature_at)
	return s.waiting[component_id]


## Which unit moves when a joint is picked first on pick_a, then on pick_b (component ids, "" for
## the ground; C2.7): {"a" (moving) and "b" (base): top-level units, "swapped": bool, "notes":
## PackedStringArray (S-NESTED-MOVES, S-SIDES-SWAPPED), "error": S-SAME-UNIT or ""}. A pick on a
## nested component maps to its top-level unit; a first pick on a fixed unit (the ground or a
## grounded one) swaps the sides when the other is free.
static func sides(doc: Resource, pick_a: String, pick_b: String) -> Dictionary:
	var components: Dictionary = doc.components
	var assembly: Dictionary = DATA.normalized(doc.assembly if doc.assembly is Dictionary else {})
	var a := unit_of(components, pick_a)
	var b := unit_of(components, pick_b)
	var out := {"a": a, "b": b, "swapped": false, "notes": PackedStringArray(), "error": ""}
	if a == b:
		out["error"] = DATA.fill(DATA.S_SAME_UNIT, {"Comp": doc.component_name(a) if a != "" else "the ground"})
		return out
	for pick in [pick_a, pick_b]:
		var unit := unit_of(components, pick)
		if pick != "" and unit != "" and pick != unit:
			out.notes.append(DATA.fill(DATA.S_NESTED_MOVES, {"Nested": doc.component_name(pick), "Comp": doc.component_name(unit)}))
	var fixed_a := a == GROUND or DATA.is_grounded(assembly, a)
	var fixed_b := b == GROUND or DATA.is_grounded(assembly, b)
	if fixed_a and not fixed_b:
		out["a"] = b
		out["b"] = a
		out["swapped"] = true
		out.notes.append(DATA.fill(DATA.S_SIDES_SWAPPED, {"Comp": doc.component_name(b)}))
	return out


## A component's parent ("" for a top-level one; a parent that no longer exists counts as "").
static func parent_of(components: Dictionary, component_id: String) -> String:
	var parent := str((components.get(component_id, {}) as Dictionary).get("parent", ""))
	return parent if components.has(parent) and parent != component_id else ""


## The top-level component (unit) a component sits in ("" for the ground or a missing one).
static func unit_of(components: Dictionary, component_id: String) -> String:
	var id := component_id
	var guard := 0
	while id != "" and guard < MAX_NESTING:
		var parent := parent_of(components, id)
		if parent == "":
			return id if components.has(id) else ""
		id = parent
		guard += 1
	return id


## The pose of a component relative to its unit (the placements from the unit down to it).
static func unit_local(assembly: Dictionary, components: Dictionary, component_id: String) -> PackedFloat64Array:
	var chain := []
	var id := component_id
	var guard := 0
	while id != "" and parent_of(components, id) != "" and guard < MAX_NESTING:
		chain.push_front(id)
		id = parent_of(components, id)
		guard += 1
	var local := XFORM.identity()
	for c in chain:
		var placement := DATA.placement(assembly, str(c))
		if XFORM.orthonormal_error(placement) <= XFORM.ORTHONORMAL_TOLERANCE:
			local = XFORM.compose(local, placement)
	return local


## True when the component (or a component it sits in) is made by a feature after the rollback
## marker (C1.7).
## feature_at ({feature id: timeline index}) saves a search of the timeline per call.
static func is_waiting(doc: Resource, components: Dictionary, component_id: String, feature_at := {}) -> bool:
	var id := component_id
	var guard := 0
	var active: int = doc.active_count()
	while id != "" and guard < MAX_NESTING:
		var feature_id := str((components.get(id, {}) as Dictionary).get("feature", ""))
		if feature_id != "":
			var index: int = int(feature_at[feature_id]) if feature_at.has(feature_id) else (doc.feature_index(feature_id) if feature_at.is_empty() else -1)
			if index >= active:
				return true
		id = parent_of(components, id)
		guard += 1
	return false


## One joint: its output entry, and how it joins units when it takes part ("live").
static func _joint_edge(s: _Solve, joint: Dictionary, overrides: Dictionary, warnings: PackedStringArray) -> Dictionary:
	var joint_id := str(joint.get("id", ""))
	var given: Dictionary = overrides.get(joint_id, {}) if overrides.get(joint_id) is Dictionary else {}
	# (PT1: a value given that is not a finite number is not used.)
	var forced := {}
	for dof in given:
		if (given[dof] is float or given[dof] is int) and is_finite(float(given[dof])):
			forced[dof] = given[dof]
	# (PT1: a joint number that is not finite in the stored assembly, a hand edit: the joint takes
	# no part, its state is an error with S-STORED-NOT-FINITE.)
	var bad := DATA.joint_not_finite(joint)
	if bad != "":
		warnings.append(bad)
		var held := PackedFloat64Array()
		for d in (joint.get("dofs", []) as Array if joint.get("dofs") is Array else []):
			held.append(float((d as Dictionary).get("value", 0.0)) if d is Dictionary else 0.0)
		var lost := {
			"state": STATE_ERROR, "values": held, "residual_m": 0.0, "residual_rad": 0.0, "frame_a": XFORM.identity(), "frame_b": XFORM.identity(),
			"world": XFORM.identity(), "sentence": bad, "lost": false,
		}
		return {"kind": "joint", "id": joint_id, "name": str(joint.get("name", joint_id)), "type": str(joint.get("type", DATA.DEFAULT_TYPE)), "entry": lost, "live": false, "reached": ""}
	var values := JOINT_MATH.joint_values(joint, forced)
	var fixed: Dictionary = s.statics.get(joint_id, {})
	if fixed.is_empty():
		fixed = _joint_static(s, joint)
		s.statics[joint_id] = fixed
	warnings.append_array(fixed.warnings)
	var entry := {
		"state": fixed.state, "values": values, "residual_m": 0.0, "residual_rad": 0.0,
		"frame_a": fixed.frame_a, "frame_b": fixed.frame_b, "world": XFORM.identity(), "sentence": fixed.sentence, "lost": fixed.lost,
	}
	var edge := {"kind": "joint", "id": joint_id, "name": fixed.name, "type": fixed.type, "entry": entry, "live": fixed.live, "reached": ""}
	if fixed.live:
		edge["u_a"] = fixed.u_a
		edge["u_b"] = fixed.u_b
		edge["ta"] = fixed.ta
		edge["fb"] = fixed.fb
		edge["o"] = fixed.o
		edge["axis"] = fixed.axis
		edge["m"] = JOINT_MATH.motion(fixed.type, fixed.axis, values)
	return edge


## What a joint is apart from its values: its state before solving, its frames in its units'
## coordinates, O and the units it joins. The same while the assembly, the result and the
## components stay the same, so drives and studies (which change only values) reuse it.
static func _joint_static(s: _Solve, joint: Dictionary) -> Dictionary:
	var joint_id := str(joint.get("id", ""))
	var joint_name := str(joint.get("name", joint_id))
	var side_a: Dictionary = joint.get("a", {}) if joint.get("a") is Dictionary else {}
	var side_b: Dictionary = joint.get("b", {}) if joint.get("b") is Dictionary else {}
	var out := {
		"name": joint_name, "type": str(joint.get("type", DATA.DEFAULT_TYPE)), "state": STATE_OK, "sentence": "", "lost": false,
		"warnings": PackedStringArray(), "frame_a": _stored(side_a), "frame_b": _stored(side_b), "live": false,
	}
	if bool(joint.get("suppressed", false)):
		out["state"] = STATE_SUPPRESSED
		return out
	for side in [side_a, side_b]:
		var component_id := str(side.get("component", ""))
		if component_id != "" and not s.components.has(component_id):
			out["state"] = STATE_UNRESOLVED
			out["sentence"] = DATA.fill(DATA.S_MISSING_COMPONENT, {"Joint": joint_name, "Comp": component_id})
			out.warnings.append(out.sentence)
			return out
	for side in [side_a, side_b]:
		var component_id := str(side.get("component", ""))
		if _waiting(s, component_id):
			out["state"] = STATE_WAITING
			out["sentence"] = DATA.fill(DATA.S_WAITING, {"Joint": joint_name, "Comp": s.doc.component_name(component_id)})
			out.warnings.append(out.sentence)
			return out
	# Frames, in each side's unit coordinates.
	var fa := _side_frame(s, joint_name, side_a, out, "frame_a", out.warnings)
	var fb := _side_frame(s, joint_name, side_b, out, "frame_b", out.warnings)
	_limit_notes(s, joint, joint_name, out.warnings)
	if not (out.warnings as PackedStringArray).is_empty():
		out["sentence"] = out.warnings[0]
	out["u_a"] = unit_of(s.components, str(side_a.get("component", "")))
	out["u_b"] = unit_of(s.components, str(side_b.get("component", "")))
	out["ta"] = JOINT_MATH.turned(fa, bool(joint.get("as_built", false)))
	out["fb"] = fb
	out["o"] = JOINT_MATH.offset_xform(joint)
	out["axis"] = JOINT_MATH.slide_axis(joint)
	out["live"] = true
	return out


## A side's snap frame in its unit's coordinates (unit-local chain · resolved frame); a lost snap
## uses its stored frame and adds S-SNAP-LOST, or S-SNAP-SUPPRESSED when its body is not built
## (suppressed, rolled back or failed). A snap whose body now sits in another unit than the side's
## (Move to Active Component) is lost too (S-SNAP-MOVED); a snap so far from the origin that its
## float32 position steps by more than the contact tolerance is warned (S-SNAP-FAR, see above).
static func _side_frame(s: _Solve, joint_name: String, side: Dictionary, entry: Dictionary, key: String, sentences: PackedStringArray) -> PackedFloat64Array:
	var snap: Dictionary = side.get("snap", {}) if side.get("snap") is Dictionary else {}
	var found := SNAPS.resolve(snap, s.result, s.doc, s.assembly)
	entry[key] = found.frame
	var body := str(snap.get("body", ""))
	var body_name: String = s.doc.body_name(body) if body != "" else "its pick"
	var side_component := str(side.get("component", ""))
	if bool(found.lost):
		entry["lost"] = true
		var built: bool = body == "" or (s.result.get("bodies", {}) as Dictionary).has(body)
		var feature: Resource = s.doc.find_feature(str((s.doc.bodies.get(body, {}) as Dictionary).get("feature", ""))) if body != "" else null
		if not built or (feature != null and bool(feature.get("suppressed"))):
			sentences.append(DATA.fill(DATA.S_SNAP_SUPPRESSED, {"Joint": joint_name, "Body": body_name}))
		else:
			sentences.append(DATA.fill(DATA.S_SNAP_LOST, {"Joint": joint_name, "Body": body_name}))
	elif str(snap.get("kind", "")) != SNAPS.FIXED:
		# (A fixed snap is its stored frame, in doubles; only snaps found on geometry are float32.)
		var frame: PackedFloat64Array = found.frame
		var dist := sqrt(frame[9] * frame[9] + frame[10] * frame[10] + frame[11] * frame[11]) if frame.size() == 12 else 0.0
		var ulp := pow(2.0, floorf(log(dist) / log(2.0)) - 23.0) if dist > 0.0 and is_finite(dist) else 0.0
		var tolerance := float((s.assembly.get("contact", {}) as Dictionary).get("tolerance", DATA.CONTACT_DEFAULT.tolerance)) if s.assembly.get("contact") is Dictionary else float(DATA.CONTACT_DEFAULT.tolerance)
		if not (is_finite(tolerance) and tolerance > 0.0):
			tolerance = float(DATA.CONTACT_DEFAULT.tolerance)
		if ulp > tolerance:
			sentences.append(DATA.fill(DATA.S_SNAP_FAR, {
				"Joint": joint_name, "Body": body_name, "dist": JOINT_MATH.format_length(dist, str(s.doc.units)), "step": JOINT_MATH.format_length(ulp, str(s.doc.units)),
			}))
	# The snap's body may sit in a nested component of the side's unit.
	var body_id := body
	var component_id := str(s.doc.body_component(body_id)) if body_id != "" else side_component
	if body_id != "" and (s.doc.bodies as Dictionary).has(body_id) and unit_of(s.components, component_id) != unit_of(s.components, side_component):
		if not bool(found.lost):
			entry["lost"] = true
			var now := unit_of(s.components, component_id)
			sentences.append(DATA.fill(DATA.S_SNAP_MOVED, {
				"Joint": joint_name, "Body": body_name, "Comp": s.doc.component_name(component_id) if now != "" else "no component",
				"Side": s.doc.component_name(side_component) if side_component != "" else "no component",
			}))
		component_id = side_component
	if component_id == "" or not s.components.has(component_id):
		component_id = side_component
	if component_id == "" or parent_of(s.components, component_id) == "":
		return found.frame
	return XFORM.compose(unit_local(s.assembly, s.components, component_id), found.frame)


## Notes on a joint's stored DOFs (hand-edited files; the Joint panel refuses both): a Min above
## its Max (S-LIMITS-REVERSED), a stored value beyond a limit, which is held at it
## (S-VALUE-CLAMPED).
static func _limit_notes(s: _Solve, joint: Dictionary, joint_name: String, sentences: PackedStringArray) -> void:
	var dofs: Array = joint.get("dofs", []) if joint.get("dofs") is Array else []
	var joint_type := str(joint.get("type", DATA.DEFAULT_TYPE))
	var units := str(s.doc.units)
	var names: Array = DATA.dof_names(joint_type)
	for i in dofs.size():
		if not (dofs[i] is Dictionary):
			continue
		var d: Dictionary = dofs[i]
		var label := joint_name if names.size() <= 1 or i >= names.size() else "%s (%s)" % [joint_name, names[i]]
		var both := bool(d.get("limited_min", false)) and bool(d.get("limited_max", false))
		if both and float(d.get("min", 0.0)) > float(d.get("max", 0.0)):
			sentences.append(DATA.fill(DATA.S_LIMITS_REVERSED, {
				"Joint": label, "min": JOINT_MATH.format_dof(joint_type, i, float(d.min), units), "max": JOINT_MATH.format_dof(joint_type, i, float(d.max), units),
			}))
			continue
		var value := float(d.get("value", 0.0))
		var held := JOINT_MATH.clamp_value(d, value)
		if held != value and is_finite(value):
			sentences.append(DATA.fill(DATA.S_VALUE_CLAMPED, {
				"Joint": label, "value": JOINT_MATH.format_dof(joint_type, i, value, units), "limit": JOINT_MATH.format_dof(joint_type, i, held, units),
			}))


## A rigid group's edges: its first member to each other member, with the captured relative pose.
static func _group_edges(s: _Solve, group: Dictionary) -> Array:
	var members: Array = group.get("components", []) if group.get("components") is Array else []
	var out := []
	if members.size() < 2:
		return out
	var first := str(members[0])
	var relative: Dictionary = group.get("relative", {}) if group.get("relative") is Dictionary else {}
	for i in range(1, members.size()):
		var member := str(members[i])
		if not s.components.has(first) or not s.components.has(member):
			continue
		if _waiting(s, first) or _waiting(s, member):
			continue
		var rel := PackedFloat64Array(relative.get(member, XFORM.identity()))
		if XFORM.orthonormal_error(rel) > XFORM.ORTHONORMAL_TOLERANCE:
			continue
		out.append({
			"kind": "group", "id": str(group.get("id", "")), "name": str(group.get("name", "")),
			"u_a": unit_of(s.components, member), "u_b": unit_of(s.components, first), "rel": rel, "reached": "",
		})
	return out


## Breadth-first search from roots: every edge reaching an unvisited unit places it; an edge
## between two placed units is a loop (joints) or left alone (rigid groups).
static func _search(roots: Array, edges: Array, adjacency: Dictionary, unit_pose: Dictionary, used: Dictionary, units: Dictionary,
		fixed: bool, root: String, s: _Solve) -> void:
	var queue := roots.duplicate()
	var head := 0
	while head < queue.size():
		var node := str(queue[head])
		head += 1
		for i in adjacency.get(node, []):
			if used.has(i):
				continue
			used[i] = true
			var edge: Dictionary = edges[i]
			var other: String = edge.u_b if edge.u_a == node else edge.u_a
			if unit_pose.has(other):
				if edge.kind == "joint":
					edge.entry["state"] = STATE_LOOP
				else:
					# A rigid group between two placed units closes a loop: measured and warned
					# after the search (S-GROUP-LOOP-HOLDS / -OFF), not enforced.
					edge["loop"] = true
				continue
			unit_pose[other] = _place(edge, node, unit_pose[node])
			edge["reached"] = other
			units[other] = {"fixed": fixed, "root": "" if fixed else root, "reached_by": edge.id}
			queue.append(other)


## The pose of the unit at the far end of edge, from the pose of the unit at node (C2.4).
static func _place(edge: Dictionary, node: String, pose: PackedFloat64Array) -> PackedFloat64Array:
	if edge.kind == "group":
		# relative = P_first⁻¹ · P_member: u_b is the first member, u_a the other.
		return XFORM.compose(pose, edge.rel) if node == edge.u_b else XFORM.compose(pose, XFORM.inverse(edge.rel))
	if node == edge.u_b:
		return JOINT_MATH.place_a(pose, edge.fb, edge.o, edge.m, edge.ta)
	return JOINT_MATH.place_b(pose, edge.ta, edge.m, edge.o, edge.fb)


## A loop joint's residuals and sentence (C3.4).
static func _loop(s: _Solve, edge: Dictionary, pose_a: PackedFloat64Array, pose_b: PackedFloat64Array, warnings: PackedStringArray) -> void:
	var entry: Dictionary = edge.entry
	var base := XFORM.compose(XFORM.compose(pose_b, edge.fb), edge.o)
	var r := XFORM.compose(XFORM.inverse(base), XFORM.compose(pose_a, edge.ta))
	var residual := JOINT_MATH.loop_residual(edge.type, edge.axis, r)
	entry["residual_m"] = float(residual.m)
	entry["residual_rad"] = float(residual.rad)
	entry["implied"] = residual.implied
	var sentence := ""
	if float(residual.m) <= JOINT_MATH.HOLD_M and float(residual.rad) <= JOINT_MATH.HOLD_RAD:
		sentence = DATA.fill(DATA.S_LOOP_HOLDS, {"Joint": edge.name})
	else:
		sentence = DATA.fill(DATA.S_LOOP_OFF, {
			"Joint": edge.name, "d": JOINT_MATH.format_length(float(residual.m), str(s.doc.units)), "a": JOINT_MATH.format_angle(float(residual.rad)),
		})
	if str(entry.sentence) == "":
		entry["sentence"] = sentence
	warnings.append(sentence)


## A rigid group edge that closes a loop: how far its member is from the captured relative pose
## (S-GROUP-LOOP-HOLDS within the joint hold tolerances, else S-GROUP-LOOP-OFF), each sentence once.
static func _group_loop(s: _Solve, edge: Dictionary, unit_pose: Dictionary, warnings: PackedStringArray) -> void:
	var first: PackedFloat64Array = unit_pose.get(edge.u_b, XFORM.identity())
	var member: PackedFloat64Array = unit_pose.get(edge.u_a, XFORM.identity())
	var now := XFORM.compose(XFORM.inverse(first), member)
	var d := XFORM.distance(now, edge.rel)
	var a := XFORM.angle_between(now, edge.rel)
	var names := {"Group": str(edge.name) if str(edge.name) != "" else str(edge.id), "Comp": s.doc.component_name(str(edge.u_a))}
	var sentence := ""
	if d <= JOINT_MATH.HOLD_M and a <= JOINT_MATH.HOLD_RAD:
		sentence = DATA.fill(DATA.S_GROUP_LOOP_HOLDS, names)
	else:
		names["d"] = JOINT_MATH.format_length(d, str(s.doc.units))
		names["a"] = JOINT_MATH.format_angle(a)
		sentence = DATA.fill(DATA.S_GROUP_LOOP_OFF, names)
	if not warnings.has(sentence):
		warnings.append(sentence)


## The pose of a nested component, working out its parents first.
static func _nested_pose(doc: Resource, assembly: Dictionary, components: Dictionary, id: String, poses: Dictionary, transforms: Dictionary,
		warnings: PackedStringArray, depth: int) -> PackedFloat64Array:
	if poses.has(id):
		return poses[id]
	var local := _valid_placement(doc, assembly, id, warnings)
	var parent := parent_of(components, id)
	var parent_pose := XFORM.identity()
	if depth >= MAX_NESTING:
		warnings.append(DATA.fill(DATA.S_PLACEMENT_BAD, {"Comp": doc.component_name(id), "d": "a nesting loop"}))
	elif parent != "":
		parent_pose = _nested_pose(doc, assembly, components, parent, poses, transforms, warnings, depth + 1)
	poses[id] = XFORM.compose(parent_pose, local)
	transforms[id] = XFORM.to_transform(local)
	return poses[id]


## A component's stored placement when it is a finite rigid move, else identity with
## S-PLACEMENT-BAD.
static func _valid_placement(doc: Resource, assembly: Dictionary, id: String, warnings: PackedStringArray) -> PackedFloat64Array:
	var placement := DATA.placement(assembly, id)
	var off := XFORM.orthonormal_error(placement)
	if off <= XFORM.ORTHONORMAL_TOLERANCE:
		return placement
	warnings.append(DATA.fill(DATA.S_PLACEMENT_BAD, {"Comp": doc.component_name(id), "d": String.num_scientific(off) if is_finite(off) else "a value that is not a number"}))
	return XFORM.identity()


## Post-check of the poses (C3.6): every pose must be finite and orthonormal within 1e-12; a
## unit's pose that is not is replaced by its placement (and its nested components follow) with
## S-SOLVE-FAULT.
static func _check_poses(doc: Resource, s: _Solve, order: Array, poses: Dictionary, unit_pose: Dictionary, transforms: Dictionary,
		warnings: PackedStringArray) -> void:
	var replaced := false
	for id in order:
		var off := XFORM.orthonormal_error(poses[id])
		if off <= XFORM.ORTHONORMAL_TOLERANCE:
			continue
		warnings.append(DATA.fill(DATA.S_SOLVE_FAULT, {"Joint": doc.component_name(id), "d": String.num_scientific(off) if is_finite(off) else "a value that is not a number", "a": "a basis that is not orthonormal"}))
		poses[id] = s.placement[id]
		unit_pose[id] = s.placement[id]
		transforms[id] = XFORM.to_transform(s.placement[id])
		replaced = true
	if not replaced:
		return
	# Nested components again, from the replaced units.
	for component_id in s.components:
		var id := str(component_id)
		if parent_of(s.components, id) != "":
			poses.erase(id)
	for component_id in s.components:
		_nested_pose(doc, s.assembly, s.components, str(component_id), poses, transforms, PackedStringArray(), 0)


## A side's stored snap frame (its last resolved one), or identity when it has none.
static func _stored(side: Dictionary) -> PackedFloat64Array:
	var snap: Variant = side.get("snap", {})
	var stored: Variant = (snap as Dictionary).get("frame") if snap is Dictionary else null
	if stored is PackedFloat64Array and XFORM.is_finite(stored):
		return PackedFloat64Array(stored)
	return XFORM.identity()


## Every body id the result or the document knows (split bodies follow their source body).
static func _body_ids(doc: Resource, result: Dictionary) -> Array:
	var ids := {}
	for body_id in result.get("bodies", {}):
		ids[str(body_id)] = true
	for body_id in doc.bodies:
		ids[str(body_id)] = true
	return ids.keys()
