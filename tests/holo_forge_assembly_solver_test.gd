extends SceneTree
## Holo Forge Phase 8, Stage 1 (spec 5.2): snaps, the solver, drive, limits, links and Motion Study.
##
## 1-2 placements; 3-7 the joint relation (rigid, revolute, every type at random, reversed, offset
## and flip); 8-9 snaps on B-rep and mesh bodies; 10 which side moves; 11-17 drive, limits and
## links; 18 loops; 19-20 lost snaps, missing and waiting components; 21 rigid groups; 22 the
## post-check; 23 Motion Study; 24 timing. Fix round 1: 25 far snaps, 26 group loops, 27
## suppressed / waiting, 28 moved snap bodies, 29 non-finite inputs, 30 hand-edited limits, 31
## empty link intervals. Fix round 2: 32 stored joint numbers that are not finite, 33 study numbers
## that are not finite, 34 a refused drive holds the stored values, 35 the S-SNAP-FAR rule. Fix
## round 3: 36 a refused drive of a stored NaN or INF returns finite numbers.
##
## Snap points come from the native queries in float32 (snaps.gd), so a pose checked against the
## spec's nominal millimetres is held to 1e-8 m (the snap tolerance of case 8); the chain from the
## resolved frames to the pose is checked to 1e-12 against the test's own math.
##
## godot --headless --path . --script res://tests/holo_forge_assembly_solver_test.gd

const XFORM := preload("res://addons/holo_forge/core/assembly/xform64.gd")
const DATA := preload("res://addons/holo_forge/core/assembly/assembly_data.gd")
const SOLVER := preload("res://addons/holo_forge/core/assembly/solver.gd")
const SNAPS := preload("res://addons/holo_forge/core/assembly/snaps.gd")
const MOTION := preload("res://addons/holo_forge/core/assembly/motion.gd")
const FIX := preload("res://tests/holo_forge_assembly_fixtures.gd")
const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const MESH := preload("res://addons/holo_forge/core/features/mesh.gd")
const SKETCH_DATA := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const TIMING := preload("res://tests/holo_forge_timing.gd")
const JOINT_MATH_FORMAT := preload("res://addons/holo_forge/core/assembly/joint_math.gd")

const MM := 0.001
## Snap points are float32 (see the header): poses against nominal numbers hold to this.
const SNAP_M := 1e-8
const SNAP_RAD := 1e-9
## Timing limits (5.9): 2 × the ratio measured on the dev machine, Stage 1 (three runs: the middle
## one; the calibration loop took 16-19 ms):
## solve chain(50), snaps cached: 2.8-4.7 ms, ratio 0.172-0.245 (middle 0.186), C9 target 5 ms;
## solve chain(200): 12.9-18.7 ms, ratio 0.793-0.932 (middle 0.870), target 20 ms;
## study 10 s at 30 fps, 5 keyed joints (301 frames): 143-219 ms, ratio 8.5-11.2 (middle 9.69),
## target 0.5 s.
const RATIO_SOLVE_50 := 2.0 * 0.186
const RATIO_SOLVE_200 := 2.0 * 0.870
const RATIO_STUDY := 2.0 * 9.69

var failures: Array[String] = []
var kernel: RefCounted


func _init() -> void:
	call_deferred("run")


func run() -> void:
	create_timer(600.0).timeout.connect(func() -> void:
		print("FAIL holo_forge_assembly_solver: timed out ", failures)
		quit(1))
	if not ClassDB.class_exists("CadShape") or not ClassDB.class_exists("CadMesh"):
		print("SKIP holo_forge_assembly_solver: native library missing")
		quit(1)
		return
	kernel = REGEN.make_kernel()
	_case("1 empty assembly", _check_empty())
	_case("2 free unit at its placement", _check_placement())
	_case("3 rigid on stack()", _check_rigid())
	_case("4 revolute on lever()", _check_revolute())
	_case("5 every type, 100 random samples", _check_random_types())
	_case("6 reversed traversal", _check_reversed())
	_case("7 offset, angle and flip", _check_offset_flip())
	_case("8 snaps on B-rep bodies", _check_snaps())
	_case("9 snaps on mesh bodies", _check_mesh_snaps())
	_case("10 which side moves", _check_sides())
	_case("11 limits", _check_limits())
	_case("12 unlimited 720 degrees", _check_unlimited())
	_case("13 link ratio 2", _check_link())
	_case("14 a follower's limit stops the driver", _check_link_limit())
	_case("15 link chains compose", _check_link_chain())
	_case("16 driving the follower", _check_drive_follower())
	_case("17 link refusals", _check_link_refusals())
	_case("18 four-bar loop", _check_four_bar())
	_case("19 lost snap", _check_lost_snap())
	_case("20 missing and waiting components", _check_missing_waiting())
	_case("21 rigid group", _check_rigid_group())
	_case("22 post-check", _check_post_check())
	_case("23 Motion Study", _check_study())
	_case("24 timing", _check_timing())
	_case("25 snaps far from the origin", _check_far_snaps())
	_case("26 rigid group closing a loop", _check_group_loop())
	_case("27 suppressed pick, waiting and suppressed drives", _check_suppressed())
	_case("28 snap body moved to another component", _check_moved_body())
	_case("29 targets and ratios that are not finite", _check_not_finite())
	_case("30 reversed limits and clamped stored values", _check_hand_limits())
	_case("31 links that leave no value", _check_empty_interval())
	_case("32 stored joint numbers that are not finite", _check_stored_not_finite())
	_case("33 study numbers that are not finite", _check_study_not_finite())
	_case("34 a refused drive holds the stored values", _check_refused_holds())
	_case("35 S-SNAP-FAR from the contact tolerance", _check_far_rule())
	_case("36 a refused drive of a stored NaN returns finite numbers", _check_refused_finite())
	SOLVER.debug_corrupt = false
	print("PASS holo_forge_assembly_solver: all cases" if failures.is_empty() else "FAIL holo_forge_assembly_solver: %d failures" % failures.size())
	quit(0 if failures.is_empty() else 1)


# --- 1, 2 ----------------------------------------------------------------------------------------

func _check_empty() -> bool:
	var f := FIX.stack(kernel)
	f.doc.assembly = {}
	var out := SOLVER.solve(f.doc, f.result, kernel)
	var ok := true
	for id in out.poses:
		ok = _expect(_bytes(out.poses[id]) == _bytes(XFORM.identity()), "Pose of %s should be identity." % id) and ok
	for id in out.body_poses:
		ok = _expect(_bytes(out.body_poses[id]) == _bytes(XFORM.identity()), "Body pose of %s should be identity." % id) and ok
	ok = _expect((out.warnings as PackedStringArray).is_empty() and (out.joints as Dictionary).is_empty(), "No warnings, no joints (%s)." % [out.warnings]) and ok
	return ok


func _check_placement() -> bool:
	var f := FIX.stack(kernel)
	var placement := XFORM.translation(10.0 * MM, 0.0, 0.0)
	f.doc.assembly = {"placements": {f.components.Cube: placement}}
	var out := SOLVER.solve(f.doc, f.result, kernel)
	return _expect(_bytes(out.body_poses[f.bodies.Cube]) == _bytes(placement) and _bytes(out.poses[f.components.Cube]) == _bytes(placement),
		"A free unit's body should sit exactly at its placement.")


# --- 3-7 -----------------------------------------------------------------------------------------

func _check_rigid() -> bool:
	var f := FIX.stack(kernel)
	var snap_a := FIX.face_snap(f, "Cube", Vector3(50, 50, 40), Vector3(0, 0, -1))
	var snap_b := FIX.face_snap(f, "Base", Vector3(50, 50, 10), Vector3(0, 0, 1))
	var id := FIX.add_joint(f.doc, "rigid", f.components.Cube, snap_a, "", snap_b)
	var out := SOLVER.solve(f.doc, f.result, kernel)
	var pose: PackedFloat64Array = out.poses[f.components.Cube]
	var ok := _state(out, id, "ok")
	ok = _expect(_dist(pose, XFORM.translation(0.0, 0.0, -30.0 * MM)) <= SNAP_M, "Cube should move by (0, 0, -30) mm within 1e-8 m (off by %s)." % _sci(_dist(pose, XFORM.translation(0.0, 0.0, -30.0 * MM)))) and ok
	ok = _expect(XFORM.angle_between(XFORM.identity(), pose) <= 1e-12, "Cube should not turn (%s rad)." % _sci(XFORM.angle_between(XFORM.identity(), pose))) and ok
	# The chain from the resolved frames, in the test's own math: P_a = F_b · (F_a · R_x(π))⁻¹.
	var expected := XFORM.compose(snap_b.frame, XFORM.inverse(XFORM.compose(snap_a.frame, XFORM.rot_x(PI))))
	ok = _expect(_dist(pose, expected) <= 1e-12 and XFORM.angle_between(pose, expected) <= 1e-12, "The pose should follow from the frames within 1e-12.") and ok
	return ok


func _check_revolute() -> bool:
	var f := _lever_joint(30.0)
	var out := SOLVER.solve(f.doc, f.result, kernel)
	var tip := XFORM.apply(out.poses[f.components.Lever], PackedFloat64Array([95.0 * MM, 0.0, 15.0 * MM]))
	var want := PackedFloat64Array([95.0 * MM * cos(deg_to_rad(30.0)), 95.0 * MM * sin(deg_to_rad(30.0)), 15.0 * MM])
	var off := _vdist(tip, want)
	var ok := _state(out, f.joints.Lever, "ok")
	return _expect(off <= 1e-12, "The Lever tip should go to (95 cos 30°, 95 sin 30°, 15) within 1e-12 m (off by %s)." % _sci(off)) and ok


func _check_random_types() -> bool:
	var rng := RandomNumberGenerator.new()
	rng.seed = 8
	var ok := true
	var worst_m := 0.0
	var worst_rad := 0.0
	for joint_type in DATA.TYPES:
		for sample in 100:
			var doc: Resource = DOCUMENT.new()
			doc.components = {
				"comp1": {"name": "A", "visible": true, "parent": "", "feature": ""},
				"comp2": {"name": "B", "visible": true, "parent": "", "feature": ""},
			}
			var assembly: Dictionary = DATA.normalized({})
			assembly.placements = {"comp1": _random_rigid(rng, 0.1), "comp2": _random_rigid(rng, 0.1)}
			assembly.grounded = {"comp2": true}
			doc.assembly = assembly
			var frame_a := _random_rigid(rng, 0.1)
			var frame_b := _random_rigid(rng, 0.1)
			var axis := "x"
			if joint_type == "slider":
				axis = ["x", "y", "z"][rng.randi_range(0, 2)]
			elif joint_type == "pin_slot":
				axis = ["x", "y"][rng.randi_range(0, 1)]
			var dofs := []
			var values := PackedFloat64Array()
			for dof_name in DATA.dof_names(joint_type):
				var v := rng.randf_range(-TAU, TAU) if DATA.is_rotation(dof_name) else rng.randf_range(-0.1, 0.1)
				values.append(v)
				dofs.append({"value": v, "min": 0.0, "max": 0.0, "limited_min": false, "limited_max": false, "rest": 0.0})
			var offset := [rng.randf_range(-0.05, 0.05), rng.randf_range(-0.05, 0.05), rng.randf_range(-0.05, 0.05)]
			var angle := rng.randf_range(-PI, PI)
			var flip := rng.randf() < 0.5
			var id := FIX.add_joint(doc, joint_type, "comp1", SNAPS.fixed_snap(frame_a), "comp2", SNAPS.fixed_snap(frame_b),
				{"offset": offset, "angle": angle, "flip": flip, "slide_axis": axis, "dofs": dofs})
			var out := SOLVER.solve(doc, {}, null)
			if str(out.joints[id].state) != "ok":
				ok = _expect(false, "%s sample %d: state %s (%s)." % [joint_type, sample, out.joints[id].state, out.joints[id].sentence]) and ok
				continue
			var left := XFORM.compose(out.poses.comp1, XFORM.compose(frame_a, XFORM.rot_x(PI)))
			var o := XFORM.compose(XFORM.translation(offset[0], offset[1], offset[2]), XFORM.rot_z(angle))
			if flip:
				o = XFORM.compose(o, XFORM.rot_x(PI))
			var right := XFORM.compose(XFORM.compose(XFORM.compose(out.poses.comp2, frame_b), o), _motion(joint_type, axis, values))
			worst_m = maxf(worst_m, XFORM.distance(left, right))
			worst_rad = maxf(worst_rad, XFORM.angle_between(left, right))
			ok = _expect(_bytes(out.poses.comp2) == _bytes(assembly.placements.comp2), "%s sample %d: the grounded side should stay at its placement." % [joint_type, sample]) and ok
	print("  5: worst %s m, %s rad" % [_sci(worst_m), _sci(worst_rad)])
	return _expect(worst_m <= 1e-12 and worst_rad <= 1e-12, "The relation should hold within 1e-12 (worst %s m, %s rad)." % [_sci(worst_m), _sci(worst_rad)]) and ok


func _check_reversed() -> bool:
	var f := _lever_joint(30.0)
	# The Base becomes a free component, the Lever is grounded.
	var base_comp: String = f.doc.new_component("")
	f.doc.components[base_comp]["name"] = "BaseComp"
	f.doc.bodies[f.bodies.Base]["component"] = base_comp
	var assembly: Dictionary = DATA.normalized(f.doc.assembly)
	assembly.grounded = {f.components.Lever: true}
	assembly.joints[0].b.component = base_comp
	f.doc.assembly = assembly
	var out := SOLVER.solve(f.doc, f.result, kernel)
	var ok := _state(out, f.joints.Lever, "ok")
	var entry: Dictionary = out.joints[f.joints.Lever]
	ok = _expect(float(entry.residual_m) <= 1e-12 and float(entry.residual_rad) <= 1e-12, "The relation should hold within 1e-12 (%s m, %s rad)." % [_sci(entry.residual_m), _sci(entry.residual_rad)]) and ok
	var base_pose: PackedFloat64Array = out.poses[base_comp]
	ok = _expect(_bytes(out.poses[f.components.Lever]) == _bytes(XFORM.identity()), "The grounded Lever should stay.") and ok
	ok = _expect(absf(XFORM.angle_between(XFORM.identity(), base_pose) - deg_to_rad(30.0)) <= 1e-12 and base_pose[1] < 0.0, "The Base should turn by -30° (%s)." % [base_pose]) and ok
	ok = _expect(str(out.units[base_comp].reached_by) == f.joints.Lever and bool(out.units[base_comp].fixed), "The Base should be reached by the joint from the grounded Lever (%s)." % [out.units]) and ok
	return ok


func _check_offset_flip() -> bool:
	var f := FIX.stack(kernel)
	var snap_a := FIX.face_snap(f, "Cube", Vector3(50, 50, 40), Vector3(0, 0, -1))
	var snap_b := FIX.face_snap(f, "Base", Vector3(50, 50, 10), Vector3(0, 0, 1))
	var offset := [1.0 * MM, 2.0 * MM, 3.0 * MM]
	var id := FIX.add_joint(f.doc, "rigid", f.components.Cube, snap_a, "", snap_b, {"offset": offset, "angle": deg_to_rad(90.0), "flip": true})
	var out := SOLVER.solve(f.doc, f.result, kernel)
	var pose: PackedFloat64Array = out.poses[f.components.Cube]
	var ok := _state(out, id, "ok")
	var landed := XFORM.apply(pose, PackedFloat64Array([snap_a.frame[9], snap_a.frame[10], snap_a.frame[11]]))
	# Analytic (C2.4): the face centre lands at F_b · offset.
	var want := XFORM.apply(snap_b.frame, PackedFloat64Array(offset))
	ok = _expect(_vdist(landed, want) <= 1e-12, "The Cube's bottom centre should land at F_b · offset within 1e-12 m (off by %s)." % _sci(_vdist(landed, want))) and ok
	ok = _expect(_vdist(landed, PackedFloat64Array([51.0 * MM, 52.0 * MM, 13.0 * MM])) <= SNAP_M, "... which is (51, 52, 13) mm within 1e-8 m.") and ok
	ok = _expect(pose[8] <= -1.0 + 1e-12, "The Cube should be turned over (its Z is %s)." % [[pose[6], pose[7], pose[8]]]) and ok
	return ok


# --- 8, 9 ----------------------------------------------------------------------------------------

func _check_snaps() -> bool:
	var ok := true
	var f := FIX.stack(kernel)
	var top := FIX.face_snap(f, "Base", Vector3(50, 50, 10), Vector3(0, 0, 1))
	ok = _frame_is(top.get("frame", PackedFloat64Array()), Vector3(50, 50, 10), Vector3(0, 0, 1), Vector3(1, 0, 0), "Base top face_center") and ok
	var side := FIX.face_snap(f, "Base", Vector3(100, 50, 5), Vector3(1, 0, 0))
	ok = _frame_is(side.get("frame", PackedFloat64Array()), Vector3(100, 50, 5), Vector3(1, 0, 0), Vector3(0, 1, 0), "Base +X face_center") and ok
	# An edge and a vertex of the top face, picked through it.
	var top_ref := FIX.face_ref(f, "Base", Vector3(50, 50, 10), Vector3(0, 0, 1))
	var shape: RefCounted = f.result.bodies[f.bodies.Base].shape
	var edge_index := -1
	for e in shape.face_info(int(shape.find_face(top_ref.name))).edges:
		var info: Dictionary = shape.edge_info(int(e))
		if (info.midpoint as Vector3).distance_to(Vector3(0.05, 0.0, 0.01)) < 1e-6:
			edge_index = int(e)
	var edge_ref := REFERENCES.from_pick({"kind": "edge", "body": f.bodies.Base, "index": edge_index}, f.result)
	var edge := SNAPS.make_snap("edge_mid", edge_ref, f.result, f.doc, {"face": top_ref})
	ok = _expect(edge.has("snap"), "edge_mid should be made (%s)." % [edge.get("error")]) and ok
	if edge.has("snap"):
		ok = _frame_is(edge.snap.frame, Vector3(50, 0, 10), Vector3(0, 0, 1), Vector3(1, 0, 0), "edge_mid", true) and ok
	var vertex_ref := {"kind": "vertex", "body": f.bodies.Base, "point": Vector3(0.0, 0.0, 0.01)}
	var vertex := SNAPS.make_snap("vertex", vertex_ref, f.result, f.doc, {"face": top_ref})
	ok = _expect(vertex.has("snap"), "vertex should be made (%s)." % [vertex.get("error")]) and ok
	if vertex.has("snap"):
		ok = _frame_is(vertex.snap.frame, Vector3(0, 0, 10), Vector3(0, 0, 1), Vector3(1, 0, 0), "vertex") and ok
	# The hole in lever()'s Base: its top circle and its axis middle.
	var l := FIX.lever(kernel)
	var circle := FIX.circle_snap(l, "Base", Vector3(0, 0, 10), 5.0)
	ok = _frame_is(circle.get("frame", PackedFloat64Array()), Vector3(0, 0, 10), Vector3(0, 0, 1), Vector3(1, 0, 0), "hole circle_center") and ok
	var base_shape: RefCounted = l.result.bodies[l.bodies.Base].shape
	var cylinder := -1
	for i in base_shape.face_count():
		if str(base_shape.face_info(i).type) == "cylinder":
			cylinder = i
	var hole_ref := REFERENCES.from_pick({"kind": "face", "body": l.bodies.Base, "index": cylinder}, l.result)
	var mid := SNAPS.make_snap("axis_mid", hole_ref, l.result, l.doc)
	ok = _expect(mid.has("snap"), "axis_mid should be made (%s)." % [mid.get("error")]) and ok
	if mid.has("snap"):
		var o := PackedFloat64Array([mid.snap.frame[9], mid.snap.frame[10], mid.snap.frame[11]])
		ok = _expect(_vdist(o, PackedFloat64Array([0.0, 0.0, 5.0 * MM])) <= SNAP_M and absf(mid.snap.frame[8]) >= 1.0 - 1e-12, "axis_mid should be (0, 0, 5) mm on Z (%s)." % [mid.snap.frame]) and ok
	for kind in ["axis_start", "axis_end"]:
		var end := SNAPS.make_snap(kind, hole_ref, l.result, l.doc)
		ok = _expect(end.has("snap") and absf(absf(end.snap.frame[11] - 5.0 * MM) - 5.0 * MM) <= SNAP_M, "%s should be at an end of the hole (%s)." % [kind, end]) and ok
	# Candidates of the top face: its centre, four edge midpoints and four vertices.
	var candidates := SNAPS.candidates(f.result, f.bodies.Base, int(shape.find_face(top_ref.name)), f.doc)
	var kinds := {}
	for c in candidates:
		kinds[c.kind] = int(kinds.get(c.kind, 0)) + 1
	ok = _expect(kinds == {"face_center": 1, "edge_mid": 4, "vertex": 4}, "The top face should offer 1 centre, 4 edge midpoints and 4 vertices (%s)." % [kinds]) and ok
	return ok


func _check_mesh_snaps() -> bool:
	var ok := true
	var f := FIX.mesh_block(kernel)
	var top := FIX.group_at(f, "Block", Vector3(10, 0, 30), Vector3(0, 0, 1))
	var made := SNAPS.make_snap("group_center", top, f.result, f.doc)
	ok = _expect(made.has("snap"), "group_center should be made (%s)." % [made.get("error")]) and ok
	if made.has("snap"):
		var o := PackedFloat64Array([made.snap.frame[9], made.snap.frame[10], made.snap.frame[11]])
		ok = _expect(_vdist(o, PackedFloat64Array([10.0 * MM, 0.0, 30.0 * MM])) <= 1e-7 and made.snap.frame[8] >= 1.0 - 1e-9, "The top group's centre should be (10, 0, 30) mm within 1e-7 m (%s)." % [made.snap.frame]) and ok
	# The slider still holds on the mesh Block.
	var out := SOLVER.solve(f.doc, f.result, kernel)
	ok = _state(out, f.joints.Slider, "ok") and ok
	# An edge pick on a mesh body is refused.
	var refused := SNAPS.make_snap("edge_mid", {"kind": "edge", "body": f.bodies.Block, "name": "e1", "sig": {}}, f.result, f.doc)
	ok = _expect(str(refused.get("error", "")) == DATA.S_MESH_SNAP, "An edge pick on a mesh body should say S-MESH-SNAP (%s)." % [refused]) and ok
	# A round group: the tessellated Pin.
	var p := FIX.pin_hole(kernel)
	var pin_body: String = p.bodies.Pin
	var tess := MESH.add_tessellate(p.doc, [pin_body], {"quality": "high", "keep_original": false})
	var mesh_body := str(tess.bodies[0])
	p.doc.bodies[mesh_body]["component"] = p.components.Pin
	p.bodies["Pin"] = mesh_body
	FIX.rebuild(p)
	var shape: RefCounted = p.result.bodies[mesh_body].shape
	var round_group := -1
	for i in shape.face_count():
		if not bool(shape.face_info(i).get("planar", false)):
			round_group = i
	var ref := REFERENCES.from_pick({"kind": "face", "body": mesh_body, "index": round_group, "point": Vector3(0.005, 0.0, 0.01), "normal": Vector3(1, 0, 0)}, p.result)
	var axis := SNAPS.make_snap("group_axis_mid", ref, p.result, p.doc)
	ok = _expect(axis.has("snap"), "group_axis_mid should be made (%s)." % [axis.get("error")]) and ok
	if axis.has("snap"):
		var tilt := rad_to_deg(acos(clampf(absf(axis.snap.frame[8]), -1.0, 1.0)))
		var o := PackedFloat64Array([axis.snap.frame[9], axis.snap.frame[10], axis.snap.frame[11]])
		ok = _expect(tilt <= 0.1 and _vdist(o, PackedFloat64Array([0.0, 0.0, 10.0 * MM])) <= 1e-5, "The Pin's axis middle should be (0, 0, 10) mm on Z within 0.1° (tilt %s°, at %s)." % [tilt, o]) and ok
	var fit: Dictionary = shape.fit_primitive(shape.group_triangles(round_group))
	var radius := float(fit.cylinder.radius)
	ok = _expect(absf(radius - 5.0 * MM) <= 0.005 * 5.0 * MM, "The fitted radius should be 5 mm within 0.5%% (%s)." % [radius]) and ok
	return ok


# --- 10 ------------------------------------------------------------------------------------------

func _check_sides() -> bool:
	var ok := true
	var f := FIX.lever(kernel)
	var lever: String = f.components.Lever
	var same := SOLVER.sides(f.doc, lever, lever)
	ok = _expect(str(same.error) == DATA.fill(DATA.S_SAME_UNIT, {"Comp": "Lever"}), "Same unit should be refused (%s)." % [same]) and ok
	var swapped := SOLVER.sides(f.doc, "", lever)
	ok = _expect(str(swapped.a) == lever and str(swapped.b) == "" and bool(swapped.swapped) and (swapped.notes as PackedStringArray).has(DATA.fill(DATA.S_SIDES_SWAPPED, {"Comp": "Lever"})),
		"A first pick on the ground should swap the sides (%s)." % [swapped]) and ok
	# A nested component: the Lever body moves into "Arm" inside Lever, placed 5 mm along X.
	var nested: String = f.doc.new_component("")
	f.doc.components[nested]["name"] = "Arm"
	f.doc.components[nested]["parent"] = lever
	f.doc.bodies[f.bodies.Lever]["component"] = nested
	var picked := SOLVER.sides(f.doc, nested, "")
	ok = _expect(str(picked.a) == lever and (picked.notes as PackedStringArray).has(DATA.fill(DATA.S_NESTED_MOVES, {"Nested": "Arm", "Comp": "Lever"})),
		"A nested pick should map to its unit and say so (%s)." % [picked]) and ok
	var snap_a := FIX.circle_snap(f, "Lever", Vector3(0, 0, 10), 5.0)
	var snap_b := FIX.circle_snap(f, "Base", Vector3(0, 0, 10), 5.0)
	var dofs := [{"value": deg_to_rad(30.0), "min": 0.0, "max": 0.0, "limited_min": false, "limited_max": false, "rest": 0.0}]
	var id := FIX.add_joint(f.doc, "revolute", str(picked.a), snap_a, "", snap_b, {"dofs": dofs})
	var assembly: Dictionary = DATA.normalized(f.doc.assembly)
	var local := XFORM.translation(5.0 * MM, 0.0, 0.0)
	assembly.placements[nested] = local
	f.doc.assembly = assembly
	var out := SOLVER.solve(f.doc, f.result, kernel)
	ok = _state(out, id, "ok") and ok
	var arm_pose: PackedFloat64Array = out.poses[nested]
	var hole := XFORM.apply(arm_pose, PackedFloat64Array([0.0, 0.0, 10.0 * MM]))
	ok = _expect(_vdist(hole, PackedFloat64Array([0.0, 0.0, 10.0 * MM])) <= 1e-12, "The nested body's hole should sit on the joint (off by %s)." % _sci(_vdist(hole, PackedFloat64Array([0.0, 0.0, 10.0 * MM])))) and ok
	ok = _expect(_dist(out.poses[lever], XFORM.identity()) > 1e-3 and _dist(arm_pose, XFORM.compose(out.poses[lever], local)) <= 1e-15, "The top-level unit should move and carry the nested one.") and ok
	return ok


# --- 11-17 ---------------------------------------------------------------------------------------

func _check_limits() -> bool:
	var ok := true
	var f := _lever_joint(0.0, deg_to_rad(-30.0), deg_to_rad(90.0))
	var t := Time.get_ticks_usec()
	var high := MOTION.drive(f.doc, f.result, kernel, f.joints.Lever, 0, deg_to_rad(120.0))
	var stored_max: float = f.doc.assembly.joints[0].dofs[0].max
	var stored_min: float = f.doc.assembly.joints[0].dofs[0].min
	ok = _expect(float(high.reached) == stored_max and float(high.values[f.joints.Lever][0]) == stored_max and bool(high.clamped) and str(high.stopped_by) == "limit",
		"Driving to 120° should stop exactly at the stored max (%s)." % [high.reached]) and ok
	ok = _expect(str(high.sentence) == DATA.fill(DATA.S_LIMIT, {"Joint": "Lever", "limit": "90°", "target": "120°"}), "S-LIMIT (%s)." % high.sentence) and ok
	ok = _expect(_bytes(high.solve.poses[f.components.Lever]) == _bytes(SOLVER.solve(f.doc, f.result, kernel, {f.joints.Lever: {0: stored_max}}).poses[f.components.Lever]), "The drive's solve should be at the reached value.") and ok
	var low := MOTION.drive(f.doc, f.result, kernel, f.joints.Lever, 0, deg_to_rad(-45.0))
	ok = _expect(float(low.reached) == stored_min, "Driving to -45° should stop exactly at the stored min.") and ok
	ok = _expect(_bytes(f.doc.assembly.joints[0].dofs[0].value) == _bytes(0.0), "drive() never writes the document.") and ok
	print("  11: two drives %.2f ms" % ((Time.get_ticks_usec() - t) / 1000.0))
	return ok


func _check_unlimited() -> bool:
	var f := _lever_joint(0.0)
	var out := MOTION.drive(f.doc, f.result, kernel, f.joints.Lever, 0, deg_to_rad(720.0))
	var ok := _expect(absf(float(out.reached) - 4.0 * PI) <= 1e-15 * 4.0 * PI and not bool(out.clamped), "720° should stay 4π (%s)." % [out.reached])
	var pose: PackedFloat64Array = out.solve.poses[f.components.Lever]
	return _expect(_dist(pose, XFORM.rot_z(4.0 * PI)) <= 1e-12 and XFORM.angle_between(pose, XFORM.rot_z(4.0 * PI)) <= 1e-12, "The pose should be rot_z(4π).") and ok


func _check_link() -> bool:
	var f := FIX.gears(kernel)
	var assembly: Dictionary = DATA.normalized(f.doc.assembly)
	var made := MOTION.new_link(assembly, {"joint": f.joints.Joint1, "dof": 0}, {"joint": f.joints.Joint2, "dof": 0}, 2.0)
	f.doc.assembly = assembly
	var ok := _expect(made.has("link") and float(made.link.offset) == 0.0, "The link should be made with offset 0 (%s)." % [made])
	var out := MOTION.drive(f.doc, f.result, kernel, f.joints.Joint1, 0, deg_to_rad(30.0))
	var j2 := float(out.values[f.joints.Joint2][0])
	ok = _expect(absf(j2 - 2.0 * deg_to_rad(30.0)) <= 1e-15 * j2, "Joint2 should be 2 × 30° (%s)." % [rad_to_deg(j2)]) and ok
	return _state(out.solve, f.joints.Joint2, "ok") and ok


func _check_link_limit() -> bool:
	var f := FIX.gears(kernel)
	var assembly: Dictionary = DATA.normalized(f.doc.assembly)
	MOTION.new_link(assembly, {"joint": f.joints.Joint1, "dof": 0}, {"joint": f.joints.Joint2, "dof": 0}, 2.0)
	assembly.joints[1].dofs[0].limited_max = true
	assembly.joints[1].dofs[0].max = deg_to_rad(90.0)
	f.doc.assembly = assembly
	var out := MOTION.drive(f.doc, f.result, kernel, f.joints.Joint1, 0, deg_to_rad(60.0))
	var j1 := float(out.values[f.joints.Joint1][0])
	var ok := _expect(absf(j1 - deg_to_rad(45.0)) <= 1e-15 * deg_to_rad(45.0), "Joint1 should stop at 45° (%s)." % [rad_to_deg(j1)])
	ok = _expect(float(out.values[f.joints.Joint2][0]) == float(f.doc.assembly.joints[1].dofs[0].max), "Joint2 should hold exactly its stored max.") and ok
	ok = _expect(str(out.stopped_by) == "link" and str(out.sentence) == DATA.fill(DATA.S_LINK_LIMIT, {"Joint": "Joint1", "value": "45°", "Follower": "Joint2", "ratio": "2:1", "limit": "90°"}),
		"S-LINK-LIMIT (%s)." % out.sentence) and ok
	return ok


func _check_link_chain() -> bool:
	var f := FIX.chain(3, kernel)
	var assembly: Dictionary = DATA.normalized(f.doc.assembly)
	MOTION.new_link(assembly, {"joint": f.joints.J1, "dof": 0}, {"joint": f.joints.J2, "dof": 0}, -0.5)
	MOTION.new_link(assembly, {"joint": f.joints.J2, "dof": 0}, {"joint": f.joints.J3, "dof": 0}, 2.0)
	f.doc.assembly = assembly
	var ok := true
	var rng := RandomNumberGenerator.new()
	rng.seed = 15
	for i in 10:
		var a := rng.randf_range(-TAU, TAU)
		var out := MOTION.drive(f.doc, f.result, kernel, f.joints.J1, 0, a)
		var c := float(out.values[f.joints.J3][0])
		ok = _expect(absf(c + a) <= 1e-15 * absf(a), "C should be -A (%s vs %s)." % [c, a]) and ok
	return ok


func _check_drive_follower() -> bool:
	var f := FIX.gears(kernel)
	var assembly: Dictionary = DATA.normalized(f.doc.assembly)
	MOTION.new_link(assembly, {"joint": f.joints.Joint1, "dof": 0}, {"joint": f.joints.Joint2, "dof": 0}, 2.0)
	f.doc.assembly = assembly
	var out := MOTION.drive(f.doc, f.result, kernel, f.joints.Joint2, 0, deg_to_rad(40.0))
	var j1 := float(out.values[f.joints.Joint1][0])
	var ok := _expect(absf(j1 - deg_to_rad(20.0)) <= 1e-15 * deg_to_rad(20.0), "Joint1 should be 20° (%s)." % [rad_to_deg(j1)])
	return _expect(float(out.reached) == deg_to_rad(40.0), "Joint2 should reach 40°.") and ok


func _check_link_refusals() -> bool:
	var f := FIX.chain(3, kernel)
	var assembly: Dictionary = DATA.normalized(f.doc.assembly)
	var j1 := {"joint": f.joints.J1, "dof": 0}
	var j2 := {"joint": f.joints.J2, "dof": 0}
	var j3 := {"joint": f.joints.J3, "dof": 0}
	MOTION.new_link(assembly, j1, j2, 2.0)
	var ok := true
	var cases := [
		[j3, j2, 1.0, DATA.fill(DATA.S_LINK_SECOND_DRIVER, {"Joint": "Joint2", "Driver": "Joint1"})],
		[j2, j1, 1.0, DATA.fill(DATA.S_LINK_CIRCLE, {"Joint": "Joint1", "Other": "Joint2"})],
		[j1, j3, 0.0, DATA.S_LINK_ZERO],
		[j1, j1, 1.0, DATA.S_LINK_SELF],
	]
	for c in cases:
		var t := Time.get_ticks_usec()
		var refusal := MOTION.link_refusal(assembly, c[0], c[1], c[2])
		var made := MOTION.new_link(assembly, c[0], c[1], c[2])
		var secs := (Time.get_ticks_usec() - t) / 1e6
		ok = _expect(refusal == c[3] and str(made.get("error", "")) == c[3] and secs <= 0.2, "Refusal should be \"%s\" in ≤ 0.2 s (got \"%s\", %.4f s)." % [c[3], refusal, secs]) and ok
	return _expect((assembly.links as Array).size() == 1, "No refused link should be added.") and ok


# --- 18-22 ---------------------------------------------------------------------------------------

func _check_four_bar() -> bool:
	var f := FIX.four_bar(kernel)
	var out := SOLVER.solve(f.doc, f.result, kernel)
	var loops := []
	for id in out.joints:
		if str(out.joints[id].state) == "loop":
			loops.append(id)
	var ok := _expect(loops.size() == 1, "Exactly one joint should close the loop (%s)." % [loops])
	if loops.size() != 1:
		return false
	var entry: Dictionary = out.joints[loops[0]]
	ok = _expect(float(entry.residual_m) <= 1e-9 and float(entry.residual_rad) <= 1e-9 and str(entry.sentence) == DATA.fill(DATA.S_LOOP_HOLDS, {"Joint": "Joint3"}),
		"As built, the loop holds (%s)." % [entry]) and ok
	var driven := MOTION.drive(f.doc, f.result, kernel, f.joints.J1, 0, deg_to_rad(10.0))
	var after: Dictionary = driven.solve.joints[loops[0]]
	ok = _expect(str(after.state) == "loop" and str(after.sentence).begins_with(DATA.S_LOOP_OFF.split("<d>")[0].replace("<Joint>", "Joint3")) and float(after.residual_m) > 1e-4,
		"Driven 10°, the loop is off by more than 0.1 mm (%s)." % [after]) and ok
	return ok


func _check_lost_snap() -> bool:
	var f := _lever_joint(30.0)
	var before := SOLVER.solve(f.doc, f.result, kernel)
	# The Base's sketch loses its hole circle: the snapped hole is gone.
	var sketch_feature: Resource = f.doc.features[0]
	var s: RefCounted = SKETCH_DATA.new(sketch_feature, f.doc)
	var circles := []
	for entity in sketch_feature.options.entities:
		if str(entity.type) == "circle":
			circles.append(int(entity.id))
	s.remove_entities(circles)
	FIX.rebuild(f)
	var after := SOLVER.solve(f.doc, f.result, kernel)
	var entry: Dictionary = after.joints[f.joints.Lever]
	var ok := _expect(circles.size() == 1 and bool(entry.lost) and str(entry.state) == "ok" and str(entry.sentence) == DATA.fill(DATA.S_SNAP_LOST, {"Joint": "Lever", "Body": "Base"}),
		"The joint should say S-SNAP-LOST (%s)." % [entry])
	ok = _expect((after.warnings as PackedStringArray).has(entry.sentence), "... in the warnings too.") and ok
	var moved := _dist(before.poses[f.components.Lever], after.poses[f.components.Lever])
	return _expect(moved <= 1e-12 and XFORM.angle_between(before.poses[f.components.Lever], after.poses[f.components.Lever]) <= 1e-12, "The pose should hold (moved %s)." % _sci(moved)) and ok


func _check_missing_waiting() -> bool:
	var f := _lever_joint(30.0)
	var lever_feature: String = f.doc.components[f.components.Lever].feature
	var snapshot: Dictionary = f.doc.snapshot()
	f.doc.remove_feature(lever_feature)
	FIX.rebuild(f)
	var gone := SOLVER.solve(f.doc, f.result, kernel)
	var ok := _expect(str(gone.joints[f.joints.Lever].state) == "unresolved" and str(gone.joints[f.joints.Lever].sentence) == DATA.fill(DATA.S_MISSING_COMPONENT, {"Joint": "Lever", "Comp": f.components.Lever}),
		"A deleted component leaves the joint unresolved (%s)." % [gone.joints[f.joints.Lever]])
	f.doc.restore(snapshot)
	FIX.rebuild(f)
	var back := SOLVER.solve(f.doc, f.result, kernel)
	ok = _state(back, f.joints.Lever, "ok") and ok
	f.doc.rollback = f.doc.feature_index(lever_feature)
	FIX.rebuild(f)
	var waiting := SOLVER.solve(f.doc, f.result, kernel)
	ok = _expect(str(waiting.joints[f.joints.Lever].state) == "waiting" and str(waiting.joints[f.joints.Lever].sentence) == DATA.fill(DATA.S_WAITING, {"Joint": "Lever", "Comp": "Lever"}),
		"Rolled back before the Lever, the joint waits (%s)." % [waiting.joints[f.joints.Lever]]) and ok
	return ok


func _check_rigid_group() -> bool:
	var f := _lever_joint(0.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 21
	var members := [f.components.Lever]
	var assembly: Dictionary = DATA.normalized(f.doc.assembly)
	for name in ["G2", "G3"]:
		var id: String = f.doc.new_component("")
		f.doc.components[id]["name"] = name
		members.append(id)
		assembly.placements[id] = _random_rigid(rng, 0.1)
	var first := DATA.placement(assembly, f.components.Lever)
	var relative := {}
	for id in members.slice(1):
		relative[id] = XFORM.compose(XFORM.inverse(first), assembly.placements[id])
	var group_id := DATA.new_id(assembly, "group")
	assembly.rigid_groups.append({"id": group_id, "name": "Group1", "components": members, "relative": relative, "suppressed": false})
	f.doc.assembly = assembly
	var ok := true
	for i in 10:
		var value := rng.randf_range(-TAU, TAU)
		var out := SOLVER.solve(f.doc, f.result, kernel, {f.joints.Lever: {0: value}})
		var lever_pose: PackedFloat64Array = out.poses[f.components.Lever]
		for id in members.slice(1):
			var now := XFORM.compose(XFORM.inverse(lever_pose), out.poses[id])
			ok = _expect(_dist(now, relative[id]) <= 1e-12 and XFORM.angle_between(now, relative[id]) <= 1e-12, "%s should keep its captured pose (value %s)." % [id, value]) and ok
		ok = _expect(absf(XFORM.angle_between(XFORM.identity(), lever_pose) - absf(wrapf(value, -PI, PI))) <= 1e-9, "The Lever should follow the drive.") and ok
	return ok


func _check_post_check() -> bool:
	var f := _lever_joint(30.0)
	SOLVER.debug_corrupt = true
	var out := SOLVER.solve(f.doc, f.result, kernel)
	SOLVER.debug_corrupt = false
	var entry: Dictionary = out.joints[f.joints.Lever]
	var ok := _expect(str(entry.state) == "error" and str(entry.sentence).begins_with("Lever could not be placed exactly") and str(entry.sentence).ends_with("This is a Holo Forge fault; please report it."),
		"A corrupted pose should fail the post-check (%s)." % [entry])
	return _state(SOLVER.solve(f.doc, f.result, kernel), f.joints.Lever, "ok") and ok


# --- 23 ------------------------------------------------------------------------------------------

func _check_study() -> bool:
	var f := _lever_joint(0.0, deg_to_rad(-30.0), deg_to_rad(90.0))
	var assembly: Dictionary = DATA.normalized(f.doc.assembly)
	var study_id := DATA.new_id(assembly, "study")
	assembly.studies.append({"id": study_id, "name": "Motion Study1", "length": 5.0, "fps": 30, "contact": false, "keys": [
		{"time": 0.0, "joint": f.joints.Lever, "dof": 0, "value": 0.0}, {"time": 2.0, "joint": f.joints.Lever, "dof": 0, "value": deg_to_rad(90.0)},
	]})
	f.doc.assembly = assembly
	var out := MOTION.study_frames(f.doc, f.result, kernel, study_id)
	var frames: Array = out.frames
	var ok := _expect(frames.size() == int(ceil(5.0 * 30.0)) + 1, "Frame count should be ceil(length × fps) + 1 (%d)." % frames.size())
	if frames.size() < 91:
		return false
	var at_1: float = frames[30].values[f.joints.Lever][0]
	var at_3: float = frames[90].values[f.joints.Lever][0]
	ok = _expect(float(frames[30].time) == 1.0 and absf(at_1 - deg_to_rad(45.0)) <= 1e-12, "At 1 s the Lever is at 45° (%s)." % [rad_to_deg(at_1)]) and ok
	ok = _expect(float(frames[90].time) == 3.0 and at_3 == deg_to_rad(90.0), "At 3 s it holds 90° (%s)." % [rad_to_deg(at_3)]) and ok
	var tip := XFORM.apply(frames[30].body_poses[f.bodies.Lever], PackedFloat64Array([95.0 * MM, 0.0, 15.0 * MM]))
	ok = _expect(_vdist(tip, PackedFloat64Array([95.0 * MM * cos(PI / 4.0), 95.0 * MM * sin(PI / 4.0), 15.0 * MM])) <= 1e-12, "Frames carry the body poses.") and ok
	# A key beyond the limit plays at the limit.
	assembly.studies[0].keys[1].value = deg_to_rad(120.0)
	f.doc.assembly = assembly
	var clamped := MOTION.study_frames(f.doc, f.result, kernel, study_id)
	ok = _expect(float(clamped.frames[60].values[f.joints.Lever][0]) == float(assembly.joints[0].dofs[0].max), "A 120° key plays at the 90° limit.") and ok
	ok = _expect((clamped.warnings as PackedStringArray).has(DATA.fill(DATA.S_STUDY_CLAMPED, {"Joint": "Lever", "time": "2 s", "value": "120°", "limit": "90°"})),
		"S-STUDY-CLAMPED (%s)." % [clamped.warnings]) and ok
	# A key on a follower is refused.
	var g := FIX.gears(kernel)
	var linked: Dictionary = DATA.normalized(g.doc.assembly)
	var link := MOTION.new_link(linked, {"joint": g.joints.Joint1, "dof": 0}, {"joint": g.joints.Joint2, "dof": 0}, 2.0)
	ok = _expect(MOTION.study_key_refusal(linked, g.joints.Joint2, 0) == DATA.fill(DATA.S_STUDY_FOLLOWER, {"Joint": "Joint2", "Driver": "Joint1", "Link": str(link.link.name)})
		and MOTION.study_key_refusal(linked, g.joints.Joint1, 0) == "", "A key on a follower should be refused.") and ok
	return ok


# --- 24 ------------------------------------------------------------------------------------------

## Timing (5.9). Measured on the dev machine (Stage 1, alone): see the RATIO_* constants.
func _check_timing() -> bool:
	var ok := true
	var calibration := func() -> void:
		var x := 0.0
		for i in 200000:
			x += sin(float(i) * 1e-3)
	var c50 := FIX.chain(50, kernel)
	SOLVER.solve(c50.doc, c50.result, kernel)
	var t50 := TIMING.compare(func() -> void: SOLVER.solve(c50.doc, c50.result, kernel), calibration, 5, "solve chain(50)")
	var c200 := FIX.chain(200, kernel)
	SOLVER.solve(c200.doc, c200.result, kernel)
	var t200 := TIMING.compare(func() -> void: SOLVER.solve(c200.doc, c200.result, kernel), calibration, 5, "solve chain(200)")
	var c5 := FIX.chain(5, kernel)
	var assembly: Dictionary = DATA.normalized(c5.doc.assembly)
	var study_id := DATA.new_id(assembly, "study")
	var keys := []
	for i in range(1, 6):
		keys.append({"time": 0.0, "joint": c5.joints["J%d" % i], "dof": 0, "value": 0.0})
		keys.append({"time": 10.0, "joint": c5.joints["J%d" % i], "dof": 0, "value": deg_to_rad(10.0 * i)})
	assembly.studies.append({"id": study_id, "name": "Motion Study1", "length": 10.0, "fps": 30, "contact": false, "keys": keys})
	c5.doc.assembly = assembly
	var frames := MOTION.study_frames(c5.doc, c5.result, kernel, study_id)
	ok = _expect((frames.frames as Array).size() == 301 and str(frames.sentence) == "", "The study should give 301 frames (%s)." % [frames.sentence]) and ok
	var ts := TIMING.compare(func() -> void: MOTION.study_frames(c5.doc, c5.result, kernel, study_id), calibration, 3, "study 10 s at 30 fps, 5 joints")
	print("  24: solve chain(50) %.3f ms (ratio %.4f, limit %.4f); chain(200) %.3f ms (ratio %.4f, limit %.4f); study %.1f ms (ratio %.3f, limit %.3f); calibration %.2f ms" % [
		t50.op, t50.ratio, RATIO_SOLVE_50, t200.op, t200.ratio, RATIO_SOLVE_200, ts.op, ts.ratio, RATIO_STUDY, t50.calibration])
	ok = _expect(float(t50.ratio) <= RATIO_SOLVE_50, "solve chain(50): ratio %.4f over %.4f." % [t50.ratio, RATIO_SOLVE_50]) and ok
	ok = _expect(float(t200.ratio) <= RATIO_SOLVE_200, "solve chain(200): ratio %.4f over %.4f." % [t200.ratio, RATIO_SOLVE_200]) and ok
	ok = _expect(float(ts.ratio) <= RATIO_STUDY, "study: ratio %.3f over %.3f." % [ts.ratio, RATIO_STUDY]) and ok
	return ok


# --- 25-31 (fix round 1) -------------------------------------------------------------------------

## B3: face snaps 1 km from the origin warn S-SNAP-FAR (distance and float32 step) on the joint;
## at the origin they don't.
func _check_far_snaps() -> bool:
	var ok := true
	for offset in [Vector3.ZERO, Vector3(1e6, 0, 0)]:
		var f := FIX.stack_at(offset, kernel)
		var sa := FIX.face_snap(f, "Cube", Vector3(50, 50, 40) + offset, Vector3(0, 0, -1))
		var sb := FIX.face_snap(f, "Base", Vector3(50, 50, 10) + offset, Vector3(0, 0, 1))
		var id := FIX.add_joint(f.doc, "revolute", f.components.Cube, sa, "", sb)
		var out := SOLVER.solve(f.doc, f.result, kernel)
		var far := (out.warnings as Array).filter(func(w: String) -> bool: return w.contains("from the origin, where positions are stored only to about "))
		print("  25: offset %s mm: %s" % [offset, far])
		if offset == Vector3.ZERO:
			ok = _expect(far.is_empty(), "25: no S-SNAP-FAR at the origin (%s)." % [far]) and ok
		else:
			var step := JOINT_MATH_FORMAT.format_length(pow(2.0, -14.0), "mm")
			ok = _expect(far.size() == 2 and str(far[0]).contains("'s pick on Cube lies ") and str(far[1]).contains("'s pick on Base lies ") and str(far[0]).contains(step)
				and str(out.joints[id].sentence) == str(far[0]), "25: S-SNAP-FAR for both picks, step %s (%s; joint %s)." % [step, far, out.joints[id].sentence]) and ok
	return ok


## P2: a rigid group whose members each hang on their own joint closes a loop: it is warned
## (S-GROUP-LOOP-HOLDS as captured, S-GROUP-LOOP-OFF once a drive pulls it apart), naming it.
func _check_group_loop() -> bool:
	var f := FIX.gears(kernel)
	var assembly: Dictionary = DATA.normalized(f.doc.assembly)
	var group_id := DATA.new_id(assembly, "group")
	assembly.rigid_groups.append({"id": group_id, "name": "Group1", "components": [f.components.Gear1, f.components.Gear2], "relative": {f.components.Gear2: XFORM.identity()}, "suppressed": false})
	f.doc.assembly = assembly
	var names := {"Group": "Group1", "Comp": f.doc.component_name(f.components.Gear2)}
	var rest := SOLVER.solve(f.doc, f.result, kernel)
	var ok := _expect((rest.warnings as PackedStringArray).has(DATA.fill(DATA.S_GROUP_LOOP_HOLDS, names)), "26: S-GROUP-LOOP-HOLDS as captured (%s)." % [rest.warnings])
	var out := MOTION.drive(f.doc, f.result, kernel, f.joints.Joint1, 0, deg_to_rad(45.0))
	var head := DATA.S_GROUP_LOOP_OFF.get_slice("<d>", 0).replace("<Group>", "Group1").replace("<Comp>", str(names.Comp))
	var off := (out.solve.warnings as Array).filter(func(w: String) -> bool: return w.begins_with(head))
	ok = _expect(off.size() == 1 and str(off[0]).contains("45°"), "26: S-GROUP-LOOP-OFF by 45° after the drive (%s)." % [out.solve.warnings]) and ok
	return ok


## P3: a suppressed body's pick says so (not "the model changed"); driving a waiting joint or a
## suppressed one is refused with a sentence and moves nothing.
func _check_suppressed() -> bool:
	var f := FIX.lever_stop_contact(kernel)
	var feature: Resource = f.doc.find_feature(str(f.doc.components[f.components.Lever].feature))
	feature.set("suppressed", true)
	FIX.rebuild(f)
	var out := SOLVER.solve(f.doc, f.result, kernel)
	var entry: Dictionary = out.joints[f.joints.Lever]
	var want := DATA.fill(DATA.S_SNAP_SUPPRESSED, {"Joint": "Lever", "Body": "Lever"})
	var ok := _expect(bool(entry.lost) and str(entry.sentence) == want and not str(out.warnings).contains("the model changed there"), "27: S-SNAP-SUPPRESSED (%s; %s)." % [entry.sentence, out.warnings])
	var g := FIX.lever_stop_contact(kernel)
	g.doc.rollback = g.doc.feature_index(str(g.doc.components[g.components.Lever].feature))
	FIX.rebuild(g)
	var waiting := MOTION.drive(g.doc, g.result, kernel, g.joints.Lever, 0, deg_to_rad(30.0))
	ok = _expect(bool(waiting.refused) and float(waiting.reached) == 0.0 and str(waiting.sentence) == DATA.fill(DATA.S_WAITING, {"Joint": "Lever", "Comp": "Lever"}),
		"27: driving a waiting joint is refused with S-WAITING (%s, %s)." % [waiting.reached, waiting.sentence]) and ok
	var h := _lever_joint(10.0)
	var assembly: Dictionary = DATA.normalized(h.doc.assembly)
	assembly.joints[0]["suppressed"] = true
	h.doc.assembly = assembly
	var held := MOTION.drive(h.doc, h.result, kernel, h.joints.Lever, 0, deg_to_rad(30.0))
	ok = _expect(bool(held.refused) and float(held.reached) == deg_to_rad(10.0) and str(held.sentence) == DATA.fill(DATA.S_DRIVE_SUPPRESSED, {"Joint": "Lever"}),
		"27: driving a suppressed joint is refused (%s, %s)." % [held.reached, held.sentence]) and ok
	return ok


## P4: Move to Active Component of a joint's snap body into another component makes the joint
## lost with S-SNAP-MOVED, naming the body and both components.
func _check_moved_body() -> bool:
	var f := FIX.lever_stop_linked(kernel)
	f.doc.bodies[f.bodies.Lever]["component"] = f.components.Knob
	FIX.rebuild(f)
	var out := SOLVER.solve(f.doc, f.result, kernel)
	var entry: Dictionary = out.joints[f.joints.Lever]
	var want := DATA.fill(DATA.S_SNAP_MOVED, {"Joint": "Lever", "Body": "Lever", "Comp": "Knob", "Side": "Lever"})
	return _expect(bool(entry.lost) and str(entry.sentence) == want and (out.warnings as PackedStringArray).has(want), "28: S-SNAP-MOVED (%s; want %s)." % [entry.sentence, want])


## P6: a NaN or infinite target, or a link whose ratio is not finite, is refused with a sentence
## about the input (never S-SOLVE-FAULT), and moves nothing.
func _check_not_finite() -> bool:
	var ok := true
	var f := _lever_joint(10.0)
	for target in [NAN, INF, -INF]:
		var out := MOTION.drive(f.doc, f.result, kernel, f.joints.Lever, 0, target)
		var text := "NaN" if is_nan(target) else ("INF" if target > 0.0 else "-INF")
		var want := DATA.fill(DATA.S_DRIVE_NOT_FINITE, {"Joint": "Lever", "value": text})
		ok = _expect(bool(out.refused) and str(out.sentence) == want and float(out.reached) == deg_to_rad(10.0) and not str(out.solve.warnings).contains("Holo Forge fault")
			and _state(out.solve, f.joints.Lever, "ok"), "29: target %s is refused (%s; %s)." % [target, out.sentence, out.solve.warnings]) and ok
	var g := FIX.gears(kernel)
	var assembly: Dictionary = DATA.normalized(g.doc.assembly)
	assembly.links.append({"id": "link1", "name": "Link1", "driver": {"joint": g.joints.Joint1, "dof": 0}, "follower": {"joint": g.joints.Joint2, "dof": 0}, "ratio": NAN, "offset": 0.0})
	g.doc.assembly = assembly
	for joint in [g.joints.Joint1, g.joints.Joint2]:
		var out := MOTION.drive(g.doc, g.result, kernel, joint, 0, deg_to_rad(30.0))
		ok = _expect(bool(out.refused) and str(out.sentence).ends_with("Link1's ratio or offset is not a finite number. Edit the link.") and not str(out.solve.warnings).contains("Holo Forge fault"),
			"29: a NaN ratio refuses drives of both its joints (%s)." % out.sentence) and ok
	var refusal := MOTION.link_refusal(DATA.normalized(FIX.gears(kernel).doc.assembly), {"joint": g.joints.Joint1, "dof": 0}, {"joint": g.joints.Joint2, "dof": 0}, NAN)
	ok = _expect(refusal == DATA.S_RATIO_NOT_FINITE, "29: a NaN ratio is refused as not finite, not as 0 (%s)." % refusal) and ok
	return ok


## P7: a hand-edited Min above Max refuses drives (S-LIMITS-REVERSED, also in the solve); a stored
## value beyond its limit is held there with S-VALUE-CLAMPED.
func _check_hand_limits() -> bool:
	var f := _lever_joint(0.0, deg_to_rad(60.0), deg_to_rad(-30.0))
	var out := MOTION.drive(f.doc, f.result, kernel, f.joints.Lever, 0, deg_to_rad(10.0))
	var want := DATA.fill(DATA.S_LIMITS_REVERSED, {"Joint": "Lever", "min": "60°", "max": "-30°"})
	var ok := _expect(bool(out.refused) and str(out.sentence) == want and (SOLVER.solve(f.doc, f.result, kernel).warnings as PackedStringArray).has(want),
		"29: min > max refuses with S-LIMITS-REVERSED (%s; want %s)." % [out.sentence, want])
	var g := _lever_joint(120.0, deg_to_rad(-30.0), deg_to_rad(60.0))
	var solved := SOLVER.solve(g.doc, g.result, kernel)
	var clamped := DATA.fill(DATA.S_VALUE_CLAMPED, {"Joint": "Lever", "value": "120°", "limit": "60°"})
	ok = _expect((solved.warnings as PackedStringArray).has(clamped) and float(solved.joints[g.joints.Lever].values[0]) == deg_to_rad(60.0),
		"30: a stored 120° beyond 60° is held there with S-VALUE-CLAMPED (%s)." % [solved.warnings]) and ok
	ok = _expect(MOTION.limits_refusal(DATA.normalized(f.doc.assembly), f.joints.Lever) == want, "30: limits_refusal says S-LIMITS-REVERSED too.") and ok
	return ok


## B6: a 2:1 link with Joint1 0..90° and Joint2 200..300° (limits edited after linking) leaves no
## value: the drive is refused with S-LINK-EMPTY (not a false S-LINK-LIMIT) and moves nothing; the
## Joint panel's check (MOTION.limits_refusal) says so for that edit.
func _check_empty_interval() -> bool:
	var f := FIX.gears(kernel)
	var assembly: Dictionary = DATA.normalized(f.doc.assembly)
	var made := MOTION.new_link(assembly, {"joint": f.joints.Joint1, "dof": 0}, {"joint": f.joints.Joint2, "dof": 0}, 2.0)
	var ok := _expect(not made.has("error"), "31: the link is made (%s)." % [made])
	f.doc.assembly = assembly
	var before: Dictionary = DATA.normalized(f.doc.assembly)
	for joint in before.joints:
		var limits: Array = [0.0, 90.0] if str(joint.id) == f.joints.Joint1 else [200.0, 300.0]
		joint.dofs[0].merge({"limited_min": true, "min": deg_to_rad(limits[0]), "limited_max": true, "max": deg_to_rad(limits[1])}, true)
	var refusal := MOTION.limits_refusal(before, f.joints.Joint2)
	var want_edit := DATA.fill(DATA.S_LIMITS_LINKED_EMPTY, {"Joint": "Joint2", "A": "Joint2", "B": "Joint1"})
	ok = _expect(refusal == want_edit, "31: limits_refusal (%s; want %s)." % [refusal, want_edit]) and ok
	f.doc.assembly = before
	var stored := JOINT_MATH_FORMAT.joint_values(before.joints[0])
	var out := MOTION.drive(f.doc, f.result, kernel, f.joints.Joint1, 0, deg_to_rad(50.0))
	var want := DATA.fill(DATA.S_LINK_EMPTY, {"Joint": "Joint1", "A": "Joint2", "B": "Joint1"})
	ok = _expect(bool(out.refused) and str(out.sentence) == want and float(out.reached) == stored[0], "31: S-LINK-EMPTY and nothing moves (%s, %s; want %s)." % [out.reached, out.sentence, want]) and ok
	return ok


# --- 32-35 (fix round 2) -------------------------------------------------------------------------

## PT1: a stored DOF value, a limit that is on, a joint angle or offset that is NaN or INF (a hand
## edit) refuses drives of its link tree with a sentence about that number (never S-SOLVE-FAULT);
## the solve leaves that joint out with the same sentence and every pose stays finite.
func _check_stored_not_finite() -> bool:
	var ok := true
	var edits := [
		["value", NAN, func(j: Dictionary, v: float) -> void: j.dofs[0]["value"] = v],
		["value", INF, func(j: Dictionary, v: float) -> void: j.dofs[0]["value"] = v],
		["min", NAN, func(j: Dictionary, v: float) -> void: j.dofs[0].merge({"limited_min": true, "min": v}, true)],
		["min", INF, func(j: Dictionary, v: float) -> void: j.dofs[0].merge({"limited_min": true, "min": v}, true)],
		["max", NAN, func(j: Dictionary, v: float) -> void: j.dofs[0].merge({"limited_max": true, "max": v}, true)],
		["max", -INF, func(j: Dictionary, v: float) -> void: j.dofs[0].merge({"limited_max": true, "max": v}, true)],
		["angle", NAN, func(j: Dictionary, v: float) -> void: j["angle"] = v],
		["angle", INF, func(j: Dictionary, v: float) -> void: j["angle"] = v],
		["offset", NAN, func(j: Dictionary, v: float) -> void: j["offset"] = [v, 0.0, 0.0]],
		["offset", INF, func(j: Dictionary, v: float) -> void: j["offset"] = [0.0, v, 0.0]],
	]
	for edit: Array in edits:
		var f := FIX.lever_stop_linked(kernel)
		var assembly: Dictionary = DATA.normalized(f.doc.assembly)
		for joint in assembly.joints:
			if str(joint.id) == f.joints.Lever:
				(edit[2] as Callable).call(joint, float(edit[1]))
		f.doc.assembly = assembly
		var text := "NaN" if is_nan(float(edit[1])) else ("INF" if float(edit[1]) > 0.0 else "-INF")
		var want := DATA.fill(_s("S_STORED_NOT_FINITE"), {"Item": "Lever", "key": str(edit[0]), "value": text})
		var solved := SOLVER.solve(f.doc, f.result, kernel)
		var finite := true
		for id in solved.poses:
			finite = finite and XFORM.is_finite(solved.poses[id])
		for joint_name in ["Lever", "Knob"]:
			var out := MOTION.drive(f.doc, f.result, kernel, f.joints[joint_name], 0, deg_to_rad(30.0))
			for id in out.solve.poses:
				finite = finite and XFORM.is_finite(out.solve.poses[id])
			var texts := str(out.sentence) + str(out.warnings) + str(out.solve.warnings)
			print("  32: Lever %s = %s, drive %s: refused %s, reached %s: %s" % [edit[0], text, joint_name, out.refused, out.reached, out.sentence])
			ok = _expect(bool(out.refused) and str(out.sentence) == want and not texts.contains("Holo Forge fault"),
				"32: Lever %s %s: driving %s is refused with \"%s\" (%s; %s)." % [edit[0], text, joint_name, want, out.sentence, out.solve.warnings]) and ok
		ok = _expect((solved.warnings as PackedStringArray).has(want) and not str(solved.warnings).contains("Holo Forge fault") and finite,
			"32: Lever %s %s: the solve says \"%s\", no fault, poses finite %s (%s)." % [edit[0], text, want, finite, solved.warnings]) and ok
	return ok


## PT1: a study key's value or time, the study's length or frame rate that is NaN or INF refuses
## the study with a sentence about it (no frames, no false S-STUDY-CLAMPED).
func _check_study_not_finite() -> bool:
	var ok := true
	for spec in [["value", NAN], ["value", INF], ["time", NAN], ["time", INF], ["length", NAN], ["length", INF], ["fps", NAN]]:
		var f := FIX.lever_stop_contact(kernel)
		var assembly: Dictionary = DATA.normalized(f.doc.assembly)
		var study_id := DATA.new_id(assembly, "study")
		var keys := [{"time": 0.0, "joint": f.joints.Lever, "dof": 0, "value": 0.0}, {"time": 1.0, "joint": f.joints.Lever, "dof": 0, "value": 0.1}]
		var study := {"id": study_id, "name": "S", "length": 2.0, "fps": 30, "contact": true, "keys": keys}
		if str(spec[0]) in ["value", "time"]:
			keys[1][spec[0]] = spec[1]
		else:
			study[spec[0]] = spec[1]
		assembly.studies.append(study)
		f.doc.assembly = assembly
		var out := MOTION.study_frames(f.doc, f.result, kernel, study_id)
		var key := ("key " + str(spec[0])) if str(spec[0]) in ["value", "time"] else str(spec[0])
		var want := DATA.fill(_s("S_STORED_NOT_FINITE"), {"Item": "S", "key": key, "value": "NaN" if is_nan(float(spec[1])) else "INF"})
		print("  33: study %s = %s: %d frames: %s; warnings %s" % [spec[0], spec[1], (out.frames as Array).size(), out.sentence, out.warnings])
		ok = _expect((out.frames as Array).is_empty() and str(out.sentence) == want and not str(out.warnings).to_lower().contains("nan"),
			"33: study %s %s is refused with \"%s\" (%d frames, %s; %s)." % [spec[0], spec[1], want, (out.frames as Array).size(), out.sentence, out.warnings]) and ok
	return ok


## PT4: a drive refused for reversed limits (Min 60°, Max -30°, stored 0°) returns the stored value
## and a pose at it; the plain solve holds it there too.
func _check_refused_holds() -> bool:
	var f := _lever_joint(0.0, deg_to_rad(60.0), deg_to_rad(-30.0))
	var out := MOTION.drive(f.doc, f.result, kernel, f.joints.Lever, 0, deg_to_rad(10.0))
	var plain := SOLVER.solve(f.doc, f.result, kernel)
	var held := float(out.values[f.joints.Lever][0]) if (out.values as Dictionary).has(f.joints.Lever) else NAN
	var posed := float(out.solve.joints[f.joints.Lever].values[0])
	var stored := float(plain.joints[f.joints.Lever].values[0])
	print("  34: reversed limits: reached %s, values %s, drive pose %s, plain solve %s" % [out.reached, held, posed, stored])
	return _expect(bool(out.refused) and float(out.reached) == 0.0 and held == 0.0 and posed == 0.0 and stored == 0.0,
		"34: a refused drive holds the stored 0° (reached %s, values %s, pose %s, plain %s)." % [out.reached, held, posed, stored])


## PT5: S-SNAP-FAR warns when the float32 step of a snap's position is above the contact tolerance
## (10 µm by default: from 128 m out); not at 5 m or 100 m; not at 200 m with a 0.1 mm tolerance.
func _check_far_rule() -> bool:
	var ok := true
	for spec in [[Vector3(5e3, 0, 0), 1e-5, false], [Vector3(1e5, 0, 0), 1e-5, false], [Vector3(2e5, 0, 0), 1e-5, true], [Vector3(2e5, 0, 0), 1e-4, false]]:
		var offset: Vector3 = spec[0]
		var f := FIX.stack_at(offset, kernel)
		var sa := FIX.face_snap(f, "Cube", Vector3(50, 50, 40) + offset, Vector3(0, 0, -1))
		var sb := FIX.face_snap(f, "Base", Vector3(50, 50, 10) + offset, Vector3(0, 0, 1))
		FIX.add_joint(f.doc, "revolute", f.components.Cube, sa, "", sb)
		var assembly: Dictionary = DATA.normalized(f.doc.assembly)
		assembly.contact["tolerance"] = float(spec[1])
		f.doc.assembly = assembly
		var out := SOLVER.solve(f.doc, f.result, kernel)
		var far := (out.warnings as Array).filter(func(w: String) -> bool: return w.contains("from the origin, where positions are stored only to about "))
		print("  35: %s m out, tolerance %s m: %s" % [offset.x * MM, spec[1], far])
		if bool(spec[2]):
			var step := JOINT_MATH_FORMAT.format_length(pow(2.0, -16.0), "mm")
			ok = _expect(far.size() == 2 and str(far[0]).contains(step), "35: %s m out: S-SNAP-FAR with step %s (%s)." % [offset.x * MM, step, far]) and ok
		else:
			ok = _expect(far.is_empty(), "35: %s m out, tolerance %s: no S-SNAP-FAR (%s)." % [offset.x * MM, spec[1], far]) and ok
	return ok


## PT1 (fix round 3): a drive refused because the Lever's stored value is NaN or INF returns
## "reached" 0 and no "values" entry holding it (C4.1); the sentence names the value.
func _check_refused_finite() -> bool:
	var ok := true
	for value in [NAN, INF, -INF]:
		var f := FIX.lever_stop_linked(kernel)
		var assembly: Dictionary = DATA.normalized(f.doc.assembly)
		for joint in assembly.joints:
			if str(joint.id) == f.joints.Lever:
				joint.dofs[0]["value"] = value
		f.doc.assembly = assembly
		for joint_name in ["Lever", "Knob"]:
			var out := MOTION.drive(f.doc, f.result, kernel, f.joints[joint_name], 0, deg_to_rad(30.0))
			var finite := true
			for id in out.values:
				for v in (out.values[id] as PackedFloat64Array):
					finite = finite and is_finite(v)
			print("  36: Lever value %s, drive %s: reached %s, values %s: %s" % [value, joint_name, out.reached, out.values, out.sentence])
			ok = _expect(bool(out.refused) and float(out.reached) == 0.0 and finite and str(out.sentence).contains("in the stored assembly"),
				"36: Lever %s, driving %s: refused, reached 0, finite values (%s, %s)." % [value, joint_name, out.reached, out.values]) and ok
	return ok


## A sentence constant of assembly_data.gd by name ("" when it does not exist yet).
func _s(name: String) -> String:
	return str((DATA as Script).get_script_constant_map().get(name, ""))


# --- Helpers -------------------------------------------------------------------------------------

## lever() with a revolute from the Lever's bottom hole circle to the Base's top hole circle at
## value_deg; limits when given (radians). The joint is named "Lever"; f.joints.Lever is its id.
func _lever_joint(value_deg: float, low := NAN, high := NAN) -> Dictionary:
	var f := FIX.lever(kernel)
	var snap_a := FIX.circle_snap(f, "Lever", Vector3(0, 0, 10), 5.0)
	var snap_b := FIX.circle_snap(f, "Base", Vector3(0, 0, 10), 5.0)
	var dof := {"value": deg_to_rad(value_deg), "min": 0.0, "max": 0.0, "limited_min": false, "limited_max": false, "rest": 0.0}
	if not is_nan(low):
		dof.min = low
		dof.limited_min = true
	if not is_nan(high):
		dof.max = high
		dof.limited_max = true
	var id := FIX.add_joint(f.doc, "revolute", f.components.Lever, snap_a, "", snap_b, {"dofs": [dof]})
	var assembly: Dictionary = DATA.normalized(f.doc.assembly)
	assembly.joints[0].name = "Lever"
	f.doc.assembly = assembly
	f.joints["Lever"] = id
	return f


## M(v) of C2.5, written here from the spec's table.
func _motion(joint_type: String, axis: String, v: PackedFloat64Array) -> PackedFloat64Array:
	var along := func(s: float) -> PackedFloat64Array:
		return XFORM.translation(s if axis == "x" else 0.0, s if axis == "y" else 0.0, s if axis == "z" else 0.0)
	match joint_type:
		"revolute":
			return XFORM.rot_z(v[0])
		"slider":
			return along.call(v[0])
		"cylindrical":
			return XFORM.compose(XFORM.translation(0.0, 0.0, v[0]), XFORM.rot_z(v[1]))
		"pin_slot":
			return XFORM.compose(along.call(v[1]), XFORM.rot_z(v[0]))
		"planar":
			return XFORM.compose(XFORM.translation(v[0], v[1], 0.0), XFORM.rot_z(v[2]))
		"ball":
			return XFORM.compose(XFORM.compose(XFORM.rot_x(v[0]), XFORM.rot_y(v[1])), XFORM.rot_z(v[2]))
	return XFORM.identity()


func _random_rigid(rng: RandomNumberGenerator, reach: float) -> PackedFloat64Array:
	var turn := XFORM.compose(XFORM.rot_z(rng.randf_range(-PI, PI)), XFORM.compose(XFORM.rot_y(rng.randf_range(-PI, PI)), XFORM.rot_x(rng.randf_range(-PI, PI))))
	return XFORM.compose(XFORM.translation(rng.randf_range(-reach, reach), rng.randf_range(-reach, reach), rng.randf_range(-reach, reach)), turn)


## A frame's origin (mm), Z and X against expected values within the snap tolerances; X only up
## to its sign when either_x.
func _frame_is(frame: PackedFloat64Array, origin_mm: Vector3, z: Vector3, x: Vector3, label: String, either_x := false) -> bool:
	if frame.size() != 12:
		return _expect(false, "%s: no frame." % label)
	var o := PackedFloat64Array([frame[9], frame[10], frame[11]])
	var off := _vdist(o, PackedFloat64Array([origin_mm.x * MM, origin_mm.y * MM, origin_mm.z * MM]))
	var z_dot := frame[6] * z.x + frame[7] * z.y + frame[8] * z.z
	var x_dot := frame[0] * x.x + frame[1] * x.y + frame[2] * x.z
	if either_x:
		x_dot = absf(x_dot)
	var ok := off <= SNAP_M and acos(clampf(z_dot, -1.0, 1.0)) <= SNAP_RAD and acos(clampf(x_dot, -1.0, 1.0)) <= SNAP_RAD
	return _expect(ok, "%s: origin off by %s m, Z·want %s, X·want %s (%s)." % [label, _sci(off), z_dot, x_dot, frame])


func _state(out: Dictionary, joint_id: String, state: String) -> bool:
	var entry: Dictionary = out.joints.get(joint_id, {})
	return _expect(str(entry.get("state", "")) == state, "Joint %s should be %s (%s)." % [joint_id, state, entry])


func _dist(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	return XFORM.distance(a, b)


func _vdist(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	return sqrt((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2)


func _bytes(value: Variant) -> PackedByteArray:
	if value is PackedFloat64Array:
		return (value as PackedFloat64Array).to_byte_array()
	return PackedFloat64Array([float(value)]).to_byte_array()


func _sci(value: Variant) -> String:
	return String.num_scientific(float(value))


func _case(label: String, passed: bool) -> void:
	if not passed:
		failures.append("#%s failed" % label)
	print(("PASS holo_forge_assembly_solver #%s" if passed else "FAIL holo_forge_assembly_solver #%s") % label)


func _expect(ok: bool, detail: String) -> bool:
	if not ok:
		failures.append(detail)
		push_error(detail)
		print("FAIL: ", detail)
	return ok
