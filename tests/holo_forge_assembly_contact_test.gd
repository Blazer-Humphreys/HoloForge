extends SceneTree
## Holo Forge Phase 8, Stage 2 (spec 5.6): contact in drive and Motion Study, and Inspect on posed
## bodies (C5.2-C5.5, C4.4, C6, C7.4).
##
## 1-3 stops (slider_wall, lever_stop, pin_hole); 4-9 start overlaps, no sets, thin bodies, too
## many steps, too slow, timeout; 10 a study with contact; 11 links; 12 a mesh body; 13 Inspect
## with poses; 14 contact off; 15 timing; 16 measured overlap rates (Stage 3); fix round 1: 17
## many turns, 18 quick study keys, 19 split times, 20 slanted thin plates, 21 an overlap() error
## partway, 22 posed measure 1 km from the origin. Fix round 2: 23 whole turns between the first
## look's marks, 24 a body thin in one region, 25 no thin alarm on small solids (and true ones on
## curved shells), 26 gear trains (a fast driver in no contact set), 27 turn-bound step counts, 28
## two keyed DOFs of one joint, 29 contact settings that are not finite, 30 two keys at one time,
## 31 posed vertex measure and mass centre 1 km and 100 km out. Fix round 3: 32 whole turns of a
## DOF stored at its Max, 33 MOTION.turn_rate (Play), 34 many-key studies and their deadline, 35 a
## small thin piece beside a big mesh. Fix round 4: 36 a first look cut short by a deadline that
## was used up before it says so (S-CONTACT-TIME-USED), and a truly slow look still says how long.
##
## godot --headless --path . --script res://tests/holo_forge_assembly_contact_test.gd

const XFORM := preload("res://addons/holo_forge/core/assembly/xform64.gd")
const DATA := preload("res://addons/holo_forge/core/assembly/assembly_data.gd")
const SOLVER := preload("res://addons/holo_forge/core/assembly/solver.gd")
const MOTION := preload("res://addons/holo_forge/core/assembly/motion.gd")
const CONTACT := preload("res://addons/holo_forge/core/assembly/contact.gd")
const JOINT_MATH := preload("res://addons/holo_forge/core/assembly/joint_math.gd")
const FIX := preload("res://tests/holo_forge_assembly_fixtures.gd")
const MESH_FIX := preload("res://tests/holo_forge_mesh_fixtures.gd")
const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const INSPECT := preload("res://addons/holo_forge/core/inspect.gd")
const ANALYSIS := preload("res://addons/holo_forge/core/analysis.gd")
const INSERT := preload("res://addons/holo_forge/core/features/insert.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const MESH_BLOB := preload("res://addons/holo_forge/core/mesh/mesh_blob.gd")
const TIMING := preload("res://tests/holo_forge_timing.gd")
const EXPORT := preload("res://addons/holo_forge/core/export.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")

const MM := 0.001
## The default contact tolerance (C5.3).
const TOLERANCE := 1e-5
## Timing limit (5.9): 2 × the ratio measured on the dev machine, Stage 2 (four runs alone): the
## slider_wall drive to 50 mm with contact (11 samples, the bisection, the solves) took 8.3-9.1 ms
## against a 16.2-17.5 ms calibration, ratio 0.515-0.528 (middle 0.520); C9 target 0.2 s.
const RATIO_DRIVE := 2.0 * 0.520

var failures: Array[String] = []
var kernel: RefCounted


func _init() -> void:
	call_deferred("run")


func run() -> void:
	create_timer(900.0).timeout.connect(func() -> void:
		print("FAIL holo_forge_assembly_contact: timed out ", failures)
		quit(1))
	if not ClassDB.class_exists("CadShape") or not ClassDB.class_exists("CadMesh"):
		print("SKIP holo_forge_assembly_contact: native library missing")
		quit(1)
		return
	kernel = REGEN.make_kernel()
	_case("1 slider_wall stops at the Wall", _check_slider_wall())
	_case("2 lever_stop stops at the Stop", _check_lever_stop())
	_case("3 pin_hole turns 360 degrees", _check_pin_hole())
	_case("4 overlap at the start", _check_start())
	_case("5 no enabled set", _check_no_sets())
	_case("6 thin body", _check_thin())
	_case("7 too many steps", _check_steps())
	_case("8 too slow", _check_too_slow())
	_case("9 timeout", _check_timeout())
	_case("10 study with contact", _check_study())
	_case("11 links with contact", _check_links())
	_case("12 mesh_block", _check_mesh_block())
	_case("13 inspect with poses", _check_inspect())
	_case("14 contact off", _check_off())
	_case("15 timing", _check_timing())
	_case("16 measured overlap rate", _check_measured_rate())
	_case("17 many turns stop or refuse", _check_many_turns())
	_case("18 study keys between coarse samples", _check_quick_keys())
	_case("19 split times are sampled", _check_split_times())
	_case("20 slanted thin plates", _check_slanted_thin())
	_case("21 overlap error partway warns", _check_unchecked())
	_case("22 posed measure 1 km out", _check_far_measure())
	_case("23 whole turns between marks", _check_whole_turns())
	_case("24 a body thin in one region", _check_thin_region())
	_case("25 thin alarms on small solids and curved shells", _check_thin_shapes())
	_case("26 gear train with a fast driver out of contact", _check_gear_train())
	_case("27 turn-bound step counts", _check_turn_steps())
	_case("28 two keyed DOFs of one joint", _check_two_dofs())
	_case("29 contact settings that are not finite", _check_contact_not_finite())
	_case("30 two keys at one time", _check_key_jump())
	_case("31 posed vertex measure and mass centre far out", _check_far_vertex_mass())
	_case("32 whole turns from a DOF stored at its limit", _check_limit_turning())
	_case("33 turn_rate for Play", _check_turn_rate())
	_case("34 many-key studies keep their deadline", _check_many_keys())
	_case("35 a small thin piece of a big mesh", _check_thin_fin())
	_case("36 a look cut short by a used-up deadline says so", _check_time_used())
	CONTACT.debug_budget_seconds = 0.0
	print("PASS holo_forge_assembly_contact: all cases" if failures.is_empty() else "FAIL holo_forge_assembly_contact: %d failures" % failures.size())
	quit(0 if failures.is_empty() else 1)


# --- 1, 2, 3, 12 ---------------------------------------------------------------------------------

func _check_slider_wall() -> bool:
	return _slider_stop(FIX.slider_wall(kernel), "slider_wall")


func _check_mesh_block() -> bool:
	var f := FIX.mesh_block(kernel)
	var ok := _expect(CONTACT.contact_mesh(f.doc, f.result, f.bodies.Block).get("mesh") == (f.result.bodies[f.bodies.Block] as Dictionary).get("shape"),
		"The mesh Block should be its own contact mesh.")
	return _slider_stop(f, "mesh_block") and ok


## Cases 1 and 12: the Block driven to 50 mm stops clear of the Wall at about 10.01 mm.
func _slider_stop(f: Dictionary, label: String) -> bool:
	var out := MOTION.drive(f.doc, f.result, kernel, f.joints.Slider, 0, 50.0 * MM)
	var s := float(out.reached)
	print("  %s: stop %s mm, %s steps, %.1f ms" % [label, String.num(s / MM, 7), (out.get("contact", {}) as Dictionary).get("steps"), float(out.ms)])
	var ok := _expect(s >= 10.0090 * MM and s <= 10.0101 * MM, "%s: the stop should be within 10.0090..10.0101 mm (%s mm)." % [label, String.num(s / MM, 7)])
	ok = _expect(str(out.stopped_by) == "contact", "%s: stopped_by should be contact (%s)." % [label, out.stopped_by]) and ok
	# (mesh_block's Block is the Tessellate output, named "Block Mesh".)
	var block_name: String = f.doc.body_name(f.bodies.Block)
	var expected := DATA.fill(DATA.S_CONTACT_STOP, {"value": JOINT_MATH.format_dof("slider", 0, s, "mm"), "BodyA": block_name, "BodyB": "Wall", "Set": _set_name(f)})
	ok = _expect(block_name.begins_with("Block") and str(out.sentence) == expected, "%s: S-CONTACT-STOP (%s, want %s)." % [label, out.sentence, expected]) and ok
	var contact: Dictionary = out.get("contact", {})
	ok = _expect(bool(contact.get("stopped", false)) and not bool(contact.get("timed_out", true)) and int(contact.get("checked_pairs", 0)) == 1,
		"%s: the sweep result (%s)." % [label, _short(contact)]) and ok
	ok = _expect(float((out.values[f.joints.Slider] as PackedFloat64Array)[0]) == s, "%s: the values hold the stop." % label) and ok
	var block_pose: PackedFloat64Array = out.solve.body_poses[f.bodies.Block]
	# (Snap points are float32: the pose holds to the solver test's snap tolerance, 1e-8 m.)
	ok = _expect(absf(block_pose[9] - s) <= 1e-8, "%s: the Block's pose is at the stop (off by %s m)." % [label, absf(block_pose[9] - s)]) and ok
	ok = _expect(_pair_thickness(f, out.solve.body_poses, f.bodies.Block, f.bodies.Wall) <= _tol_eff(f, f.bodies.Block, f.bodies.Wall), "%s: the stop is clear." % label) and ok
	return ok


func _check_lever_stop() -> bool:
	var f := FIX.lever_stop_contact(kernel)
	var out := MOTION.drive(f.doc, f.result, kernel, f.joints.Lever, 0, deg_to_rad(60.0))
	var theta := float(out.reached)
	var touch := _theta_touch()
	print("  2: stop %s deg, touch %s deg, %s steps, %.1f ms" % [String.num(rad_to_deg(theta), 6), String.num(rad_to_deg(touch), 6), (out.get("contact", {}) as Dictionary).get("steps"), float(out.ms)])
	var ok := _expect(theta >= touch and theta <= touch + deg_to_rad(0.1), "The Lever should stop within θ_touch..θ_touch + 0.1° (%s°, θ_touch %s°)." % [rad_to_deg(theta), rad_to_deg(touch)])
	ok = _expect(str(out.stopped_by) == "contact", "stopped_by should be contact (%s)." % out.stopped_by) and ok
	var expected := DATA.fill(DATA.S_CONTACT_STOP, {"value": JOINT_MATH.format_angle(theta), "BodyA": "Lever", "BodyB": "Stop", "Set": _set_name(f)})
	ok = _expect(str(out.sentence) == expected, "S-CONTACT-STOP (%s, want %s)." % [out.sentence, expected]) and ok
	ok = _expect(_pair_thickness(f, out.solve.body_poses, f.bodies.Lever, f.bodies.Stop) <= _tol_eff(f, f.bodies.Lever, f.bodies.Stop), "The stop is clear.") and ok
	# The Lever has a round hole: its contact mesh deviates, and the warning says so.
	var dev := float(CONTACT.contact_mesh(f.doc, f.result, f.bodies.Lever).get("dev", 0.0))
	ok = _expect(dev > 0.0 and _has_prefix(out.get("warnings", PackedStringArray()), "Round faces are checked within "), "S-CONTACT-DEV (dev %s, %s)." % [dev, out.get("warnings")]) and ok
	return ok


## The smallest positive θ at which the Stop's vertical edge at (60, 20) reaches the Lever's side
## plane y = 10 (in the Lever's turned frame): 20 cos θ − 60 sin θ = 10.
func _theta_touch() -> float:
	var r := sqrt(60.0 * 60.0 + 20.0 * 20.0)
	return acos(10.0 / r) - atan2(60.0, 20.0)


func _check_pin_hole() -> bool:
	var f := FIX.pin_hole(kernel)
	var out := MOTION.drive(f.doc, f.result, kernel, f.joints.Joint1, 0, TAU)
	var contact: Dictionary = out.get("contact", {})
	print("  3: %s steps, %.1f ms" % [contact.get("steps"), float(out.ms)])
	var ok := _expect(float(out.reached) == TAU and str(out.stopped_by) == "", "The Pin should turn the full 360° (%s°, %s: %s)." % [rad_to_deg(float(out.reached)), out.stopped_by, out.sentence])
	ok = _expect(int(contact.get("checked_pairs", 0)) == 1, "checked_pairs should be 1 (%s)." % _short(contact)) and ok
	var start := DATA.fill(DATA.S_CONTACT_START, {"BodyA": "Pin", "BodyB": "Base"})
	ok = _expect(not (out.get("warnings", PackedStringArray()) as PackedStringArray).has(start) and not str(out.get("warnings", [])).contains("already overlap"),
		"No S-CONTACT-START (%s)." % [out.get("warnings")]) and ok
	return ok


# --- 4-9 -----------------------------------------------------------------------------------------

func _check_start() -> bool:
	var f := FIX.slider_wall(kernel)
	var assembly: Dictionary = DATA.normalized(f.doc.assembly)
	assembly.joints[0].dofs[0].value = 15.0 * MM
	f.doc.assembly = assembly
	var out := MOTION.drive(f.doc, f.result, kernel, f.joints.Slider, 0, 50.0 * MM)
	var start := DATA.fill(DATA.S_CONTACT_START, {"BodyA": "Block", "BodyB": "Wall"})
	var ok := _expect(float(out.reached) == 50.0 * MM and str(out.stopped_by) == "", "The drive should reach 50 mm (%s, %s)." % [out.reached, out.sentence])
	ok = _expect((out.get("warnings", PackedStringArray()) as PackedStringArray).has(start), "S-CONTACT-START (%s)." % [out.get("warnings")]) and ok
	return ok


func _check_no_sets() -> bool:
	var f := FIX.slider_wall(kernel)
	var assembly: Dictionary = DATA.normalized(f.doc.assembly)
	assembly.contact_sets[0].enabled = false
	f.doc.assembly = assembly
	var out := MOTION.drive(f.doc, f.result, kernel, f.joints.Slider, 0, 50.0 * MM)
	var ok := _expect(float(out.reached) == 50.0 * MM, "The drive should reach 50 mm (%s)." % out.reached)
	ok = _expect((out.get("warnings", PackedStringArray()) as PackedStringArray).has(DATA.S_CONTACT_NO_SETS), "S-CONTACT-NO-SETS (%s)." % [out.get("warnings")]) and ok
	ok = _expect(int((out.get("contact", {}) as Dictionary).get("checked_pairs", -1)) == 0, "Nothing is checked.") and ok
	return ok


func _check_thin() -> bool:
	var f := FIX.slider_plate(0.6, kernel)
	var out := MOTION.drive(f.doc, f.result, kernel, f.joints.Slider, 0, 50.0 * MM)
	var thin := DATA.fill(DATA.S_CONTACT_THIN, {"Body": "Plate", "t": JOINT_MATH.format_length(0.6 * MM, "mm"), "step": JOINT_MATH.format_length(1.0 * MM, "mm")})
	return _expect((out.get("warnings", PackedStringArray()) as PackedStringArray).has(thin), "S-CONTACT-THIN (%s, want %s)." % [out.get("warnings"), thin])


func _check_steps() -> bool:
	var f := FIX.slider_wall(kernel)
	var assembly: Dictionary = DATA.normalized(f.doc.assembly)
	assembly.contact.step = 0.01 * MM
	f.doc.assembly = assembly
	var started := Time.get_ticks_usec()
	var out := MOTION.drive(f.doc, f.result, kernel, f.joints.Slider, 0, 100.0 * MM)
	var seconds := float(Time.get_ticks_usec() - started) / 1e6
	var sentence := str(out.sentence)
	print("  7: %.1f ms: %s" % [seconds * 1000.0, sentence])
	var head := "This motion needs "
	var n := sentence.trim_prefix(head).get_slice(" ", 0).replace(",", "").to_int() if sentence.begins_with(head) else 0
	var ok := _expect(sentence.begins_with(head) and sentence.ends_with(DATA.S_CONTACT_STEPS.get_slice("<n>", 1)) and n >= 9990 and n <= 10010,
		"S-CONTACT-STEPS for about 10,000 steps (%s)." % sentence)
	ok = _expect(seconds <= 0.2, "Refused in %.3f s (at most 0.2 s)." % seconds) and ok
	ok = _expect(bool(out.get("refused", false)) and float(out.reached) == 0.0 and str(out.stopped_by) == "contact", "A refusal moves nothing (%s, %s)." % [out.reached, out.stopped_by]) and ok
	return ok


func _check_too_slow() -> bool:
	# Two closed cubes of about 200k triangles each (large_grid(129): 199,692): Big on the ground,
	# Mover 0.15 m along X in a component on a slider; 100 mm at Step 1 mm is 100 steps.
	var doc: Resource = DOCUMENT.new()
	var mesh := MESH_FIX.to_mesh(MESH_FIX.large_grid(129))
	if mesh == null:
		return _expect(false, "The large mesh could not be made.")
	var big := _add_mesh(doc, mesh, "Big", Transform3D.IDENTITY)
	var mover := _add_mesh(doc, mesh, "Mover", Transform3D(Basis.IDENTITY, Vector3(0.15, 0.0, 0.0)))
	var feature_id := str(doc.bodies[mover].feature)
	var component: String = doc.new_component(feature_id)
	doc.components[component]["name"] = "Mover"
	doc.bodies[mover]["component"] = component
	var result: Dictionary = REGEN.rebuild(doc, kernel)
	var joint := FIX.add_as_built_frame(doc, "slider", component, "", XFORM.identity(), {"slide_axis": "x"})
	var assembly: Dictionary = DATA.normalized(doc.assembly)
	var entry: Dictionary = DATA.CONTACT_SET_DEFAULT.duplicate(true)
	entry["id"] = DATA.new_id(assembly, "contact")
	entry["name"] = DATA.name_for("contact", entry.id)
	entry["members"] = [{"component": component}, {"body": big}]
	(assembly.contact_sets as Array).append(entry)
	assembly.contact.enabled = true
	doc.assembly = assembly
	var triangles := int((result.bodies[mover] as Dictionary).shape.triangle_count())
	var started := Time.get_ticks_usec()
	var out := MOTION.drive(doc, result, kernel, joint, 0, -100.0 * MM)
	var seconds := float(Time.get_ticks_usec() - started) / 1e6
	var head := DATA.S_CONTACT_TOO_SLOW.get_slice("<s>", 0)
	print("  8: %.1f ms: %s" % [seconds * 1000.0, out.sentence])
	var ok := _expect(str(out.sentence).begins_with(head) and str(out.sentence).contains("(100 steps × 1 pairs)"), "S-CONTACT-TOO-SLOW (%s; %d triangles each)." % [out.sentence, triangles])
	ok = _expect(seconds <= 0.2, "Refused in %.3f s (at most 0.2 s)." % seconds) and ok
	ok = _expect(bool(out.get("refused", false)) and float(out.reached) == 0.0, "A refusal moves nothing.") and ok
	return ok


func _check_timeout() -> bool:
	# Away from the Wall at Step 0.05 mm (1,000 steps): nothing stops it but the deadline.
	var f := FIX.slider_wall(kernel)
	var assembly: Dictionary = DATA.normalized(f.doc.assembly)
	assembly.contact.step = 0.05 * MM
	f.doc.assembly = assembly
	CONTACT.debug_budget_seconds = 0.05
	var started := Time.get_ticks_usec()
	var out := MOTION.drive(f.doc, f.result, kernel, f.joints.Slider, 0, -50.0 * MM)
	var seconds := float(Time.get_ticks_usec() - started) / 1e6
	CONTACT.debug_budget_seconds = 0.0
	print("  9: %.1f ms, %s steps: %s" % [seconds * 1000.0, (out.get("contact", {}) as Dictionary).get("steps"), out.sentence])
	var ok := _timed_out(f, out, seconds, 1.05, "the test seam")
	# A drag event's own deadline (8.1 #13) ends the same way.
	var dragged := MOTION.drive(f.doc, f.result, kernel, f.joints.Slider, 0, -50.0 * MM, {"deadline_seconds": 0.05})
	ok = _timed_out(f, dragged, 0.0, 1.05, "a drag deadline") and ok
	return ok


func _timed_out(f: Dictionary, out: Dictionary, seconds: float, limit: float, label: String) -> bool:
	var reached := float(out.reached)
	var expected := DATA.fill(DATA.S_CONTACT_TIMEOUT, {"value": JOINT_MATH.format_dof("slider", 0, reached, "mm")})
	var ok := _expect(str(out.sentence) == expected and bool((out.get("contact", {}) as Dictionary).get("timed_out", false)), "%s: S-CONTACT-TIMEOUT (%s, want %s)." % [label, out.sentence, expected])
	ok = _expect(seconds <= limit, "%s: it ended in %.3f s (at most %s)." % [label, seconds, limit]) and ok
	ok = _expect(reached < 0.0 and reached > -50.0 * MM and str(out.stopped_by) == "contact", "%s: it stopped on the way (%s mm)." % [label, reached / MM]) and ok
	ok = _expect(_pair_thickness(f, out.solve.body_poses, f.bodies.Block, f.bodies.Wall) <= _tol_eff(f, f.bodies.Block, f.bodies.Wall), "%s: the reached value is clear." % label) and ok
	return ok


# --- 10, 11 --------------------------------------------------------------------------------------

func _check_study() -> bool:
	var f := FIX.lever_stop_contact(kernel)
	var assembly: Dictionary = DATA.normalized(f.doc.assembly)
	var study_id := DATA.new_id(assembly, "study")
	assembly.studies.append({"id": study_id, "name": "Motion Study1", "length": 3.0, "fps": 30, "contact": true, "keys": [
		{"time": 0.0, "joint": f.joints.Lever, "dof": 0, "value": 0.0}, {"time": 2.0, "joint": f.joints.Lever, "dof": 0, "value": deg_to_rad(30.0)},
	]})
	f.doc.assembly = assembly
	var out := MOTION.study_frames(f.doc, f.result, kernel, study_id)
	var frames: Array = out.frames
	var stopped := float(out.stopped_at)
	# θ = 15°/s · t until 2 s: the 0.1° window of case 2 in time.
	var rate := deg_to_rad(30.0) / 2.0
	var touch := _theta_touch() / rate
	print("  10: stopped_at %s s (touch %s s), %.1f ms: %s" % [String.num(stopped, 6), String.num(touch, 6), float(out.ms), out.sentence])
	var ok := _expect(frames.size() == 91, "91 frames (%d; %s)." % [frames.size(), out.sentence])
	ok = _expect(stopped >= touch and stopped <= touch + deg_to_rad(0.1) / rate, "stopped_at %s s should be within %s..%s s." % [stopped, touch, touch + deg_to_rad(0.1) / rate]) and ok
	ok = _expect(str(out.sentence).begins_with("Motion stopped at ") and str(out.sentence).contains("Lever touches Stop"), "S-STUDY-STOP (%s)." % out.sentence) and ok
	if frames.size() != 91 or stopped < 0.0:
		return false
	var held := {}
	var later := 0
	for frame: Dictionary in frames:
		var value := float((frame.values[f.joints.Lever] as PackedFloat64Array)[0])
		if float(frame.time) <= stopped:
			ok = _expect(absf(value - rate * float(frame.time)) <= 1e-12, "Frame %s s plays its key (%s)." % [frame.time, value]) and ok
			continue
		later += 1
		if held.is_empty():
			held = frame
			ok = _expect(absf(value - rate * stopped) <= 1e-12, "The held value is the stop (%s, want %s)." % [value, rate * stopped]) and ok
			continue
		ok = _expect(var_to_str(frame.body_poses) == var_to_str(held.body_poses) and var_to_str(frame.values) == var_to_str(held.values), "Frame %s s holds the stopped pose." % frame.time) and ok
	ok = _expect(later > 60, "Most frames come after the stop (%d)." % later) and ok
	return ok


func _check_links() -> bool:
	var f := FIX.lever_stop_linked(kernel)
	var out := MOTION.drive(f.doc, f.result, kernel, f.joints.Knob, 0, deg_to_rad(60.0))
	var theta := float(out.reached)
	var touch := _theta_touch()
	var ok := _expect(str(out.stopped_by) == "contact" and theta >= touch and theta <= touch + deg_to_rad(0.1), "The Knob should stop where its follower touches (%s°, %s)." % [rad_to_deg(theta), out.stopped_by])
	ok = _expect(float((out.values[f.joints.Lever] as PackedFloat64Array)[0]) == theta, "The follower holds the same angle.") and ok
	var expected := DATA.fill(DATA.S_CONTACT_STOP, {"value": JOINT_MATH.format_angle(theta), "BodyA": "Lever", "BodyB": "Stop", "Set": _set_name(f)})
	ok = _expect(str(out.sentence) == expected, "The sentence names the follower's bodies (%s, want %s)." % [out.sentence, expected]) and ok
	return ok


# --- 13, 14 --------------------------------------------------------------------------------------

func _check_inspect() -> bool:
	var f := FIX.lever_stop_contact(kernel)
	var lever: String = f.bodies.Lever
	var stop: String = f.bodies.Stop
	var bodies: Dictionary = f.result.bodies
	var solved := SOLVER.solve(f.doc, f.result, kernel, {f.joints.Lever: {0: deg_to_rad(30.0)}})
	var poses: Dictionary = solved.body_poses
	# Interference: none as modelled, an overlap with the Lever turned 30° over the Stop.
	var plain := INSPECT.interference(kernel, bodies, [lever, stop], f.doc)
	var posed := INSPECT.interference(kernel, bodies, [lever, stop], f.doc, INSPECT.INTERFERENCE_SECONDS, poses)
	var ok := _expect(plain.is_empty(), "No interference as modelled (%s)." % [plain])
	ok = _expect(posed.size() == 1 and float(posed[0].volume) > 1e-9, "The posed Lever overlaps the Stop (%s)." % [posed]) and ok
	# Measure: 10 mm apart as modelled, touching when posed.
	var ctx := INSPECT.context(f.result, f.doc, kernel)
	var a := {"kind": "body", "body": lever}
	var b := {"kind": "body", "body": stop}
	var apart := INSPECT.measure(a, b, ctx)
	var posed_ctx := ctx.duplicate()
	posed_ctx["poses"] = poses
	var touching := INSPECT.measure(a, b, posed_ctx)
	ok = _expect(absf(float(apart.get("distance", -1.0)) - 10.0 * MM) <= 1e-9 and float(touching.get("distance", -1.0)) <= 1e-9, "Measure: 10 mm modelled, 0 posed (%s, %s)." % [apart.get("distance"), touching.get("distance")]) and ok
	# Mass properties: the posed center is the modelled one moved by the pose.
	var mass := INSPECT.mass_properties(f.doc, f.result, [lever])
	var moved := INSPECT.mass_properties(f.doc, f.result, [lever], poses)
	var c: Vector3 = mass.center
	var want := XFORM.apply(poses[lever], PackedFloat64Array([c.x, c.y, c.z]))
	var got: Vector3 = moved.center
	ok = _expect(Vector3(want[0], want[1], want[2]).distance_to(got) <= 1e-7 and absf(float(moved.mass) - float(mass.mass)) <= 1e-12 * float(mass.mass),
		"Mass properties follow the pose (%s, want %s)." % [got, want]) and ok
	var same := ANALYSIS.mass_properties(f.doc, f.result, [lever], poses)
	ok = _expect(var_to_str(same) == var_to_str(moved), "ANALYSIS.mass_properties takes poses too.") and ok
	# With no poses (an empty assembly): byte-identical to the calls without the argument.
	var identity := {}
	for id in bodies:
		identity[id] = XFORM.identity()
	var empty_ctx := ctx.duplicate()
	empty_ctx["poses"] = {}
	var identity_ctx := ctx.duplicate()
	identity_ctx["poses"] = identity
	ok = _expect(var_to_str(INSPECT.measure(a, b, empty_ctx)) == var_to_str(apart) and var_to_str(INSPECT.measure(a, b, identity_ctx)) == var_to_str(apart), "Measure without poses is unchanged.") and ok
	ok = _expect(var_to_str(INSPECT.interference(kernel, bodies, [lever, stop], f.doc, INSPECT.INTERFERENCE_SECONDS, {})) == var_to_str(plain), "Interference without poses is unchanged.") and ok
	ok = _expect(var_to_str(INSPECT.mass_properties(f.doc, f.result, [], {})) == var_to_str(INSPECT.mass_properties(f.doc, f.result, []))
		and var_to_str(INSPECT.mass_properties(f.doc, f.result, [], identity)) == var_to_str(INSPECT.mass_properties(f.doc, f.result, [])), "Mass properties without poses are unchanged.") and ok
	# V's followers (10.2): analysis entries of a body carry its id in "body".
	var iso := ANALYSIS.build({"type": "isocurve", "options": {"comb": true}}, f.result, {}, kernel, f.doc)
	var lines: Array = iso.lines
	var named := lines.filter(func(line: Dictionary) -> bool: return bodies.has(str(line.get("body", ""))))
	ok = _expect(not lines.is_empty() and named.size() == lines.size(), "Isocurve lines carry their body (%d of %d)." % [named.size(), lines.size()]) and ok
	var com := ANALYSIS.build({"type": "center_of_mass", "options": {}}, f.result, {}, kernel, f.doc)
	var points: Array = com.points
	var per_body := points.filter(func(point: Dictionary) -> bool: return bodies.has(str(point.get("body", ""))))
	ok = _expect(points.size() == bodies.size() + 1 and per_body.size() == bodies.size(), "Center of Mass points carry their body (%s)." % [points]) and ok
	return ok


func _check_off() -> bool:
	var f := FIX.slider_wall(kernel)
	var assembly: Dictionary = DATA.normalized(f.doc.assembly)
	assembly.contact.enabled = false
	f.doc.assembly = assembly
	var out := MOTION.drive(f.doc, f.result, kernel, f.joints.Slider, 0, 50.0 * MM)
	var ok := _expect(float(out.reached) == 50.0 * MM and str(out.stopped_by) == "" and str(out.sentence) == "", "The drive should reach 50 mm (%s, %s)." % [out.reached, out.sentence])
	ok = _expect(int((out.get("contact", {}) as Dictionary).get("checked_pairs", 0)) == 0 and int((out.get("contact", {}) as Dictionary).get("steps", 0)) == 0, "No contact work (%s)." % _short(out.get("contact", {}))) and ok
	return ok


# --- 15 ------------------------------------------------------------------------------------------

## Timing (5.9): the slider_wall drive to 50 mm with contact (C9 target 0.2 s).
func _check_timing() -> bool:
	var calibration := func() -> void:
		var x := 0.0
		for i in 200000:
			x += sin(float(i) * 1e-3)
	var f := FIX.slider_wall(kernel)
	MOTION.drive(f.doc, f.result, kernel, f.joints.Slider, 0, 50.0 * MM)
	var t := TIMING.compare(func() -> void: MOTION.drive(f.doc, f.result, kernel, f.joints.Slider, 0, 50.0 * MM), calibration, 5, "drive slider_wall with contact")
	print("  15: drive with contact %.3f ms (ratio %.4f, limit %.4f); calibration %.2f ms" % [t.op, t.ratio, RATIO_DRIVE, t.calibration])
	return _expect(float(t.ratio) <= RATIO_DRIVE, "drive with contact: ratio %.4f over %.4f." % [t.ratio, RATIO_DRIVE])


# --- 16 ------------------------------------------------------------------------------------------

## Measured rates (Stage 3): pin_hole's 360° sweep times its full overlap() calls and remembers the
## pair's least time; where that is above mesh_budget.h's rate, the next sweep's up-front estimate
## uses it (and a budget between the two refuses it before any sample), and a sweep without the
## remembered time is refused after MEASURE_SAMPLES samples.
func _check_measured_rate() -> bool:
	var f := FIX.pin_hole(kernel)
	var joint: String = f.joints.Joint1
	var path := func(v: float) -> Dictionary: return SOLVER.solve(f.doc, f.result, kernel, {joint: {0: v}}).body_poses
	var sweep := func(seconds: float) -> Dictionary: return CONTACT.sweep(f.doc, f.result, kernel, path, 0.0, TAU, {"seconds": seconds, "turn": TAU})
	CONTACT.clear_cache()
	var first: Dictionary = sweep.call(1e6)
	var pin: RefCounted = CONTACT.contact_mesh(f.doc, f.result, f.bodies.Pin).mesh
	var base: RefCounted = CONTACT.contact_mesh(f.doc, f.result, f.bodies.Base).mesh
	var measured := CONTACT.measured_us(pin, base)
	var rated := CONTACT.RATE_CALL_US + CONTACT.RATE_TRIANGLE_US * float(int(pin.triangle_count()) + int(base.triangle_count()))
	var ok := _expect(float(first.reached) == TAU and measured > 0.0, "16: the first sweep turns 360° and measures the pair (%s µs; %s)." % [measured, _short(first)])
	# Up front, rates only (the Manifolds are built now).
	CONTACT.clear_rates()
	var rated_run: Dictionary = sweep.call(1e6)
	var e_rated := float(rated_run.estimate)
	var again := float(rated_run.estimate_again)
	var remembered: Dictionary = sweep.call(1e6)
	var e_measured := float(remembered.estimate)
	print("  16: overlap %.0f µs measured against %.0f µs rated (%d + %d triangles); estimate %.3f s rated, %.3f s measured, %.3f s again after %d samples; %d samples" % [
		measured, rated, int(pin.triangle_count()), int(base.triangle_count()), e_rated, e_measured, again, CONTACT.MEASURE_SAMPLES, int(rated_run.steps)])
	if measured <= 1.5 * rated:
		print("  16: the measured time is within 1.5 x the rate here: the refusals are not exercised")
		return ok
	ok = _expect(again > e_rated and e_measured > e_rated, "16: a measured time above the rate raises the estimates (%.4f, %.4f over %.4f)." % [again, e_measured, e_rated]) and ok
	var between := 0.5 * (e_rated + minf(again, e_measured))
	var up_front: Dictionary = sweep.call(between)
	ok = _expect(bool(up_front.refused) and int(up_front.steps) == 0 and float(up_front.reached) == 0.0 and str(up_front.sentence).begins_with(DATA.S_CONTACT_TOO_SLOW.get_slice("<s>", 0)),
		"16: with the remembered time a %.3f s budget is refused up front (%s)." % [between, _short(up_front)]) and ok
	CONTACT.clear_rates()
	var later: Dictionary = sweep.call(between)
	ok = _expect(bool(later.refused) and int(later.steps) == CONTACT.MEASURE_SAMPLES and float(later.reached) == 0.0 and str(later.sentence).begins_with(DATA.S_CONTACT_TOO_SLOW.get_slice("<s>", 0)),
		"16: without it the sweep is refused after %d samples (%s)." % [CONTACT.MEASURE_SAMPLES, _short(later)]) and ok
	return ok


# --- 17-22 (fix round 1) -------------------------------------------------------------------------

## B1: the Lever driven many whole turns either stops at the Stop on its first pass or is refused
## (S-CONTACT-STEPS, or S-CONTACT-TURNS since fix round 2) before any overlap work; never "reaches"
## through the Stop. 1.5 turns fits
## the step limit and must stop.
func _check_many_turns() -> bool:
	var ok := true
	var touch := _theta_touch()
	for turns in [64.0, 128.0, 63.5, 1.5]:
		var f := FIX.lever_stop_contact(kernel)
		var started := Time.get_ticks_usec()
		var out := MOTION.drive(f.doc, f.result, kernel, f.joints.Lever, 0, TAU * turns)
		var seconds := float(Time.get_ticks_usec() - started) / 1e6
		var theta := float(out.reached)
		var stopped := str(out.stopped_by) == "contact" and theta >= touch and theta <= touch + deg_to_rad(0.1)
		# (Fix round 2, N3: a count set by turning is refused with S-CONTACT-TURNS, not S-CONTACT-STEPS.)
		var by_steps := str(out.sentence).begins_with("This motion needs ") and str(out.sentence).ends_with(DATA.S_CONTACT_STEPS.get_slice("<n>", 1))
		var by_turns := str(out.sentence).begins_with(_s("S_CONTACT_TURNS").get_slice("<", 0)) and str(out.sentence).ends_with(_s("S_CONTACT_TURNS").get_slice("<n>", 1))
		var refused := bool(out.refused) and theta == 0.0 and (by_steps or by_turns)
		print("  17: %s turns: reached %s°, %.1f ms: %s" % [turns, String.num(rad_to_deg(theta), 4), seconds * 1000.0, out.sentence])
		ok = _expect(stopped or refused, "17: %s turns should stop at the Stop or be refused (%s°: %s)." % [turns, rad_to_deg(theta), out.sentence]) and ok
		if turns >= 28.0:
			ok = _expect(refused and seconds <= 0.2, "17: %s turns are over 2,000 steps of 5°: refused in at most 0.2 s (%.3f s, %s)." % [turns, seconds, out.sentence]) and ok
		else:
			ok = _expect(stopped, "17: %s turns fit: the Lever stops at the Stop (%s°)." % [turns, rad_to_deg(theta)]) and ok
	return ok


## B1: Motion Study keys that swing the Lever through the Stop and back between the first look's
## even points stop it at the touch (each key time is a sample, and the turn between keys is cut
## into 5° pieces).
func _check_quick_keys() -> bool:
	var ok := true
	for spec in [[5.0, [[0.0, 0.0], [0.2, 60.0], [0.4, 0.0]]], [2.0, [[0.0, 0.0], [0.1, 40.0], [0.25, 0.0]]]]:
		var f := FIX.lever_stop_contact(kernel)
		var assembly: Dictionary = DATA.normalized(f.doc.assembly)
		var study_id := DATA.new_id(assembly, "study")
		var keys := []
		for key: Array in spec[1]:
			keys.append({"time": float(key[0]), "joint": f.joints.Lever, "dof": 0, "value": deg_to_rad(float(key[1]))})
		assembly.studies.append({"id": study_id, "name": "Motion Study1", "length": float(spec[0]), "fps": 30, "contact": true, "keys": keys})
		f.doc.assembly = assembly
		var out := MOTION.study_frames(f.doc, f.result, kernel, study_id)
		var rate := deg_to_rad(float(spec[1][1][1])) / float(spec[1][1][0])
		var touch := _theta_touch() / rate
		var stopped := float(out.stopped_at)
		print("  18: %s s study: stopped_at %s s (touch %s s): %s" % [spec[0], String.num(stopped, 6), String.num(touch, 6), out.sentence])
		ok = _expect(stopped >= touch and stopped <= touch + deg_to_rad(0.1) / rate and str(out.sentence).contains("Lever touches Stop"),
			"18: the %s s study should stop at %s s (%s s: %s)." % [spec[0], touch, stopped, out.sentence]) and ok
	return ok


## B1: a Play-style track (slider out to +17.32 mm and back through 0 to −17.32 mm, keys at thirds)
## with the Wall at 35 mm stops at the touch (15 mm) when the key times are passed as split_times;
## so does a 0.02 s spike to 15.3 mm that lies between every even and golden-ratio point.
func _check_split_times() -> bool:
	var f := FIX.slider_gap(35.0, kernel)
	var joint: String = f.joints.Slider
	var ok := true
	var tracks := [
		[[0.0, 0.0], [1.0 / 3.0, 17.32 * MM], [2.0 / 3.0, -17.32 * MM], [1.0, 0.0]],
		[[0.0, 0.0], [0.29, 0.0], [0.30, 15.3 * MM], [0.31, 0.0], [1.0, 0.0]],
	]
	for track: Array in tracks:
		var path := func(t: float) -> Dictionary: return SOLVER.solve(f.doc, f.result, kernel, {joint: {0: MOTION.track_value(track, t)}}).body_poses
		var splits := PackedFloat64Array()
		for key: Array in track:
			splits.append(float(key[0]))
		var no_turn := func(_a: float, _b: float) -> float: return 0.0
		var out := CONTACT.sweep(f.doc, f.result, kernel, path, 0.0, 1.0, {"split_times": splits, "turn_between": no_turn})
		var without := CONTACT.sweep(f.doc, f.result, kernel, path, 0.0, 1.0, {"turn_between": no_turn})
		var s := MOTION.track_value(track, float(out.reached))
		print("  19: peak %s mm: stop at t %s (%s mm), %d samples; without split_times: %s" % [
			String.num(float(track[1][1] if track.size() == 4 else track[2][1]) / MM, 2), String.num(float(out.reached), 6), String.num(s / MM, 5), int(out.steps), _short(without)])
		ok = _expect(bool(out.stopped) and not bool(out.timed_out) and s >= 14.99 * MM and s <= 15.0101 * MM and str(out.sentence).contains("Block touches Wall"),
			"19: with split_times the track stops at the touch, 15 mm (%s mm: %s)." % [s / MM, out.sentence]) and ok
	return ok


## B2: plates 0.3 and 0.2 mm thick slanted 45° (boxes not thin) are warned S-CONTACT-THIN with
## their true thickness (their width across their flat faces' normals).
func _check_slanted_thin() -> bool:
	var ok := true
	for t in [0.3, 0.2]:
		var f := FIX.slanted_plates(t, kernel)
		var out := MOTION.drive(f.doc, f.result, kernel, f.joints.Slider, 0, 50.0 * MM)
		var warnings: PackedStringArray = out.get("warnings", PackedStringArray())
		print("  20: %s mm plates: reached %s mm, %s; warnings %s" % [t, String.num(float(out.reached) / MM, 4), out.sentence, warnings])
		for body in ["Fin", "Blade"]:
			var want := DATA.fill(DATA.S_CONTACT_THIN, {"Body": body, "t": JOINT_MATH.format_length(t * MM, "mm"), "step": JOINT_MATH.format_length(1.0 * MM, "mm")})
			ok = _expect(warnings.has(want), "20: %s mm: S-CONTACT-THIN for %s (%s; want %s)." % [t, body, warnings, want]) and ok
	return ok


## P6: a pose overlap() cannot check (a self-crossing mesh where the bodies meet) is not read as
## clear: the motion stops at the last clear value with S-CONTACT-UNCHECKED and overlap()'s repair
## sentence.
func _check_unchecked() -> bool:
	var f := FIX.slider_wall(kernel)
	var check: RefCounted = CONTACT._Check.new()
	var meshes := {f.bodies.Block: {"mesh": _BadMesh.new(true)}, f.bodies.Wall: {"mesh": _BadMesh.new(true)}}
	check.set("meshes", meshes)
	check.set("built", {})
	check.set("rates", {})
	check.set("pairs", [{"a": f.bodies.Block, "b": f.bodies.Wall, "tol": TOLERANCE, "set": "", "set_name": ""}])
	check.set("deadline", Time.get_ticks_usec() + 10000000)
	check.set("doc", f.doc)
	check.set("format", func(v: float) -> String: return JOINT_MATH.format_length(v, "mm"))
	# A pose overlap() cannot check is not clear: first_hit() reports it as failed.
	var hit: Dictionary = check.call("first_hit", {}, 12.0 * MM)
	var sentence := str(check.call("unchecked_sentence", hit.get("failed", {}), hit.get("found", {}), 11.0 * MM)) if hit.has("failed") else ""
	var ok := _expect(hit.has("failed") and not hit.has("pair") and sentence.begins_with("Motion stopped at %s: contact between Block and Wall could not be checked just past there. Block: Contact could not measure" % JOINT_MATH.format_length(11.0 * MM, "mm"))
		and not sentence.contains("Holo Forge fault"), "21: the stand-in's failure stops with S-CONTACT-UNCHECKED (%s: %s)." % [hit.keys(), sentence])
	# A real sweep: twin cubes in one mesh (they cross themselves, team N's native case 12 fixture)
	# moved 60 mm into a wall at x = 40..50 mm stop before the wall, at the last clear value, with
	# overlap()'s own sentence (it names the mesh problem and the repair).
	var doc: Resource = DOCUMENT.new()
	var twin := MESH_FIX.to_mesh(MESH_FIX.two_cubes(Vector3(10, 0, 0) * MM))
	var wall := MESH_FIX.to_mesh(MESH_FIX.cube(10.0 * MM, Vector3(45.0, 0, 0) * MM))
	doc.bodies["b1"] = {"name": "Twin", "component": ""}
	doc.bodies["b2"] = {"name": "Wall", "component": ""}
	var result := {"bodies": {"b1": {"shape": twin}, "b2": {"shape": wall}}}
	var assembly: Dictionary = DATA.normalized({})
	assembly.contact.enabled = true
	assembly.contact_sets.append({"id": "contact1", "name": "Contact Set 1", "members": [{"body": "b1"}, {"body": "b2"}], "enabled": true})
	doc.assembly = assembly
	var path := func(v: float) -> Dictionary: return {"b1": XFORM.translation(v, 0, 0), "b2": XFORM.identity()}
	var out := CONTACT.sweep(doc, result, null, path, 0.0, 60.0 * MM, {"assembly": assembly, "turn": 0.0, "format": func(v: float) -> String: return JOINT_MATH.format_length(v, "mm")})
	var reached := float(out.reached)
	# (The twin's +X face is at 20 mm, the wall's −X face at 40 mm: they meet after 20 mm.)
	var probe: Dictionary = twin.overlap(wall, XFORM.translation(reached, 0, 0), {"time_limit": 2.0})
	print("  21: twin cubes into a wall: stop at %s mm: %s (%s)" % [String.num(reached / MM, 4), out.sentence, _short(out)])
	ok = _expect(bool(out.stopped) and reached < 60.0 * MM and reached >= 15.0 * MM and str(out.sentence).contains("Twin") and str(out.sentence).contains("crosses itself")
		and str(out.sentence).contains("Repair") and not str(out.sentence).contains("fault") and not bool(probe.get("overlap", true)),
		"21: the sweep stops at the last clear value before the self-crossing contact (%s mm: %s; at the stop: %s)." % [reached / MM, out.sentence, probe]) and ok
	return ok


## B4: two bodies 10 mm apart, posed together about 1 km from the origin by one double pose (turned
## 37° about a slanted axis): Measure still gives 10 mm within 1e-6 mm.
func _check_far_measure() -> bool:
	var f := FIX._start(kernel)
	FIX._box(f, "A", Vector3(0, 0, 0), Vector3(10, 10, 10), "")
	FIX._box(f, "B", Vector3(20, 0, 0), Vector3(30, 10, 10), "")
	FIX._rebuild(f)
	var pose := XFORM.compose(XFORM.rot_z(deg_to_rad(37.0)), XFORM.rot_x(deg_to_rad(23.0)))
	pose[9] = 1000.123456789
	pose[10] = -999.87654321
	pose[11] = 1000.5
	var ctx := INSPECT.context(f.result, f.doc, kernel)
	ctx["poses"] = {f.bodies.A: pose, f.bodies.B: pose}
	INSPECT.clear_posed()
	var measured := INSPECT.measure({"kind": "body", "body": f.bodies.A}, {"kind": "body", "body": f.bodies.B}, ctx)
	var off := absf(float(measured.get("distance", -1.0)) - 10.0 * MM)
	var native := kernel.has_method("transform_shape64") and ClassDB.class_has_method("CadMesh", "transformed64")
	print("  22: posed 1 km out: distance off by %s mm (doubles transform %s)" % [String.num_scientific(off / MM), "in the native library" if native else "MISSING: float32 fallback"])
	if not native:
		print("  22: SKIP the 1e-6 mm check: the loaded native library has no transform_shape64 / transformed64 yet")
		return true
	return _expect(off <= 1e-6 * MM, "22: posed measure 1 km out off by %s mm (at most 1e-6 mm)." % String.num_scientific(off / MM))


# --- 23-31 (fix round 2) -------------------------------------------------------------------------

## SB1: Motion Study keys that spin the Lever whole turns between two marks of the first look (every
## mark then lands on a whole turn) stop it at its first touch, or are refused; never played
## through the Stop.
func _check_whole_turns() -> bool:
	var ok := true
	var touch := rad_to_deg(_theta_touch())
	for spec in [[[0.0, 0.0], [0.137, 2880.0]], [[0.0, 0.0], [0.3, 0.0], [0.4, 1080.0]]]:
		var f := FIX.lever_stop_contact(kernel)
		var assembly: Dictionary = DATA.normalized(f.doc.assembly)
		var study_id := DATA.new_id(assembly, "study")
		var keys := []
		var track := []
		for key: Array in spec:
			keys.append({"time": float(key[0]), "joint": f.joints.Lever, "dof": 0, "value": deg_to_rad(float(key[1]))})
			track.append([float(key[0]), float(key[1])])
		assembly.studies.append({"id": study_id, "name": "Motion Study1", "length": 2.0, "fps": 30, "contact": true, "keys": keys})
		f.doc.assembly = assembly
		var out := MOTION.study_frames(f.doc, f.result, kernel, study_id)
		var stopped := float(out.stopped_at)
		var angle := MOTION.track_value(track, stopped) if stopped >= 0.0 else NAN
		var refused := (out.frames as Array).is_empty() and str(out.sentence).begins_with("This motion ")
		print("  23: keys %s: stopped_at %s s (Lever %s°): %s" % [spec, String.num(stopped, 7), String.num(angle, 4), out.sentence])
		ok = _expect(refused or (stopped >= 0.0 and angle >= touch and angle <= touch + 0.1 and str(out.sentence).contains("Lever touches Stop")),
			"23: keys %s: stop at the first touch (%s°) or a refusal (stopped_at %s, Lever %s°: %s)." % [spec, touch, stopped, angle, out.sentence]) and ok
	return ok


## SB2: a body thin only along a strip (a big lump elsewhere, average thickness 8 mm) is warned
## S-CONTACT-THIN with its least local thickness (the strip, or the narrower neck that joins it to
## the lump: both are that thin).
func _check_thin_region() -> bool:
	var ok := true
	for t in [0.3, 0.2]:
		var f := FIX.thin_lump(t, kernel)
		var out := MOTION.drive(f.doc, f.result, kernel, f.joints.Slider, 0, 50.0 * MM)
		var warnings: PackedStringArray = out.get("warnings", PackedStringArray())
		print("  24: %s mm strips with lumps: reached %s mm; warnings %s" % [t, String.num(float(out.reached) / MM, 4), warnings])
		for body in ["Blade", "Fin"]:
			var shown := _thin_value(warnings, body)
			ok = _expect(shown > 0.05 * MM and shown <= t * MM * 1.001, "24: %s mm: S-CONTACT-THIN for %s at most %s mm (%s mm; %s)." % [t, body, t, shown / MM, warnings]) and ok
	return ok


## N4: solid cubes of 2.5 and 2.9 mm and a 3 mm sphere at Step 1 mm (never thinner than 2 · Step)
## get no thin warning; a tube with a 0.3 mm wall and a hollow sphere with a 0.3 mm shell (curved,
## no flat face across the wall) get a true one.
func _check_thin_shapes() -> bool:
	var ok := true
	for side in [2.5, 2.9]:
		var f := FIX.cube_block(side, kernel)
		var out := MOTION.drive(f.doc, f.result, kernel, f.joints.Slider, 0, 40.0 * MM)
		var mesh: RefCounted = CONTACT.contact_mesh(f.doc, f.result, f.bodies.Block).mesh
		var thin := CONTACT.thinness(mesh, 1.0 * MM)
		print("  25: %s mm cube: thinness %s; warnings %s" % [side, thin, out.warnings])
		ok = _expect(thin.is_empty() and not str(out.warnings).contains(" thick and contact steps are "), "25: no thin warning on a solid %s mm cube (%s; %s)." % [side, thin, out.warnings]) and ok
	var sphere := MESH_FIX.to_mesh(MESH_FIX.icosphere(1.5 * MM, 3))
	var round := CONTACT.thinness(sphere, 1.0 * MM)
	print("  25: 3 mm sphere: thinness %s" % [round])
	ok = _expect(round.is_empty(), "25: no thin warning on a 3 mm sphere (%s)." % [round]) and ok
	# A tube, 20 mm across with a 0.3 mm wall, 20 mm tall (B-rep, tessellated as contact does).
	var g := FIX._start(kernel)
	FIX._plate(g, "Base", Vector2(-60, -60), Vector2(60, 60), [], -10.0, 0.0, "")
	var sketch := FIX._sketch(g)
	var s: RefCounted = sketch[1]
	s.add_circle(s.add_point(Vector2.ZERO), 20.0 * MM)
	s.add_circle(s.add_point(Vector2.ZERO), 19.7 * MM)
	FIX._extrude(g, sketch[0], Vector2(19.85, 0), 0.0, 20.0, "Tube", "Tube")
	FIX._rebuild(g)
	var tube: RefCounted = CONTACT.contact_mesh(g.doc, g.result, g.bodies.Tube).mesh
	var walled := CONTACT.thinness(tube, 1.0 * MM)
	print("  25: 0.3 mm tube wall: thinness %s" % [walled])
	ok = _expect(not walled.is_empty() and float(walled.t) >= 0.25 * MM and float(walled.t) <= 0.32 * MM, "25: the tube wall is warned about 0.3 mm thick (%s)." % [walled]) and ok
	var shell := MESH_FIX.to_mesh(MESH_FIX.joined([MESH_FIX.icosphere(10.0 * MM, 3), MESH_FIX.flipped(MESH_FIX.icosphere(9.7 * MM, 3))]))
	var curved := CONTACT.thinness(shell, 1.0 * MM) if shell != null else {}
	print("  25: 0.3 mm hollow sphere: thinness %s" % [curved])
	ok = _expect(not curved.is_empty() and float(curved.t) >= 0.2 * MM and float(curved.t) <= 0.35 * MM, "25: the hollow sphere is warned about 0.3 mm thick (%s)." % [curved]) and ok
	return ok


## N2: a Knob in no contact set spins 30 and 60 turns and drives the Lever at 0.02: only the Lever
## turns in contact (0.6 and 1.2 turns), so the drive is not refused and stops at the Lever's touch.
func _check_gear_train() -> bool:
	var ok := true
	var touch := _theta_touch()
	for turns in [5.0, 30.0, 60.0]:
		var f := FIX.lever_stop_linked(kernel)
		var assembly: Dictionary = DATA.normalized(f.doc.assembly)
		assembly.links[0]["ratio"] = 0.02
		f.doc.assembly = assembly
		var out := MOTION.drive(f.doc, f.result, kernel, f.joints.Knob, 0, TAU * turns)
		var lever := float((out.values[f.joints.Lever] as PackedFloat64Array)[0]) if (out.values as Dictionary).has(f.joints.Lever) else NAN
		print("  26: Knob %s turns: refused %s, Knob %s°, Lever %s°: %s" % [turns, out.refused, String.num(rad_to_deg(float(out.reached)), 3), String.num(rad_to_deg(lever), 4), out.sentence])
		ok = _expect(not bool(out.refused) and str(out.stopped_by) == "contact" and lever >= touch and lever <= touch + deg_to_rad(0.1),
			"26: Knob %s turns stops where the Lever touches (refused %s, Lever %s°: %s)." % [turns, out.refused, rad_to_deg(lever), out.sentence]) and ok
	return ok


## N3: a step count bound by turning (the Lever driven 30 turns: 2,160 steps of 5°) is refused with
## the turning sentence, the same at Step 1, 10 and 100 mm, and never says to raise Step.
func _check_turn_steps() -> bool:
	var ok := true
	var sentences := []
	for step_mm in [1.0, 10.0, 100.0]:
		var f := FIX.lever_stop_contact(kernel)
		var assembly: Dictionary = DATA.normalized(f.doc.assembly)
		assembly.contact["step"] = step_mm * MM
		f.doc.assembly = assembly
		var out := MOTION.drive(f.doc, f.result, kernel, f.joints.Lever, 0, TAU * 30.0)
		print("  27: Step %s mm, 30 turns: %s" % [step_mm, out.sentence])
		sentences.append(str(out.sentence))
		var head := _s("S_CONTACT_TURNS").get_slice("<", 0)
		ok = _expect(bool(out.refused) and float(out.reached) == 0.0 and head != "" and str(out.sentence).begins_with(head) and not str(out.sentence).contains("Raise Step"),
			"27: Step %s mm: refused with the turning sentence, not \"Raise Step\" (%s)." % [step_mm, out.sentence]) and ok
	ok = _expect(sentences[0] == sentences[1] and sentences[1] == sentences[2], "27: the count does not depend on Step (%s)." % [sentences]) and ok
	return ok


## N1: a cylindrical joint keyed on both DOFs plays both (slide 10 mm and turn 90° at 1 s, in either
## key order); a helix study (lift 16 mm while turning 8 turns over 1 s) stops at the first touch,
## 6 turns and 9.34° in (0.7532 s).
func _check_two_dofs() -> bool:
	var ok := true
	for reverse in [false, true]:
		var f := FIX.helix_lever(4.0, kernel)
		var assembly: Dictionary = DATA.normalized(f.doc.assembly)
		var study_id := DATA.new_id(assembly, "study")
		var keys := [
			{"time": 0.0, "joint": f.joints.Cyl, "dof": 0, "value": 0.0}, {"time": 1.0, "joint": f.joints.Cyl, "dof": 0, "value": 10.0 * MM},
			{"time": 0.0, "joint": f.joints.Cyl, "dof": 1, "value": 0.0}, {"time": 1.0, "joint": f.joints.Cyl, "dof": 1, "value": deg_to_rad(90.0)},
		]
		if reverse:
			keys.reverse()
		assembly.studies.append({"id": study_id, "name": "Motion Study1", "length": 1.0, "fps": 10, "contact": false, "keys": keys})
		f.doc.assembly = assembly
		var out := MOTION.study_frames(f.doc, f.result, kernel, study_id)
		var last: Dictionary = out.frames[out.frames.size() - 1] if not (out.frames as Array).is_empty() else {}
		var v: PackedFloat64Array = (last.get("values", {}) as Dictionary).get(f.joints.Cyl, PackedFloat64Array([NAN, NAN]))
		print("  28: keys reversed %s: last frame slide %s mm, turn %s°" % [reverse, String.num(v[0] / MM, 4), String.num(rad_to_deg(v[1]), 4)])
		ok = _expect(absf(v[0] - 10.0 * MM) <= 1e-12 and absf(v[1] - deg_to_rad(90.0)) <= 1e-12, "28: both keyed DOFs play (reversed %s: %s)." % [reverse, v]) and ok
	var h := FIX.helix_lever(4.0, kernel)
	var helix: Dictionary = DATA.normalized(h.doc.assembly)
	var helix_id := DATA.new_id(helix, "study")
	helix.studies.append({"id": helix_id, "name": "Motion Study1", "length": 2.0, "fps": 30, "contact": true, "keys": [
		{"time": 0.0, "joint": h.joints.Cyl, "dof": 0, "value": 0.0}, {"time": 1.0, "joint": h.joints.Cyl, "dof": 0, "value": 16.0 * MM},
		{"time": 0.0, "joint": h.joints.Cyl, "dof": 1, "value": 0.0}, {"time": 1.0, "joint": h.joints.Cyl, "dof": 1, "value": TAU * 8.0},
	]})
	h.doc.assembly = helix
	var swept := MOTION.study_frames(h.doc, h.result, kernel, helix_id)
	var at := float(swept.stopped_at)
	print("  28: helix study: stopped_at %s s (turn %s°): %s" % [String.num(at, 6), String.num(at * 2880.0, 3), swept.sentence])
	ok = _expect(at * 2880.0 >= 2169.0 and at * 2880.0 <= 2169.7 and str(swept.sentence).contains("Lever touches Stop"),
		"28: the helix study stops at 6 turns and 9.34° (stopped_at %s s, %s°: %s)." % [at, at * 2880.0, swept.sentence]) and ok
	return ok


## PT1: a contact tolerance, Step or precision that is NaN or INF in the stored assembly refuses the
## drive with a sentence about that setting; nothing moves.
func _check_contact_not_finite() -> bool:
	var ok := true
	for key in ["tolerance", "step", "precision"]:
		for value in [NAN, INF]:
			var f := FIX.lever_stop_contact(kernel)
			var assembly: Dictionary = DATA.normalized(f.doc.assembly)
			assembly.contact[key] = value
			f.doc.assembly = assembly
			var out := MOTION.drive(f.doc, f.result, kernel, f.joints.Lever, 0, deg_to_rad(60.0))
			var want := DATA.fill(_s("S_CONTACT_NOT_FINITE"), {"key": key, "value": "NaN" if is_nan(value) else "INF"})
			print("  29: contact %s = %s: refused %s, reached %s: %s" % [key, value, out.refused, out.reached, out.sentence])
			ok = _expect(bool(out.refused) and float(out.reached) == 0.0 and str(out.sentence) == want and not str(out.sentence).contains("fault"),
				"29: contact %s %s refuses with \"%s\" (%s, %s)." % [key, value, want, out.reached, out.sentence]) and ok
	return ok


## Two keys of one DOF at the same time (a hand edit: a jump through the Stop) are refused with a
## sentence; no frames are played.
func _check_key_jump() -> bool:
	var f := FIX.lever_stop_contact(kernel)
	var assembly: Dictionary = DATA.normalized(f.doc.assembly)
	var study_id := DATA.new_id(assembly, "study")
	assembly.studies.append({"id": study_id, "name": "Motion Study1", "length": 1.0, "fps": 30, "contact": true, "keys": [
		{"time": 0.0, "joint": f.joints.Lever, "dof": 0, "value": 0.0}, {"time": 0.5, "joint": f.joints.Lever, "dof": 0, "value": 0.0},
		{"time": 0.5, "joint": f.joints.Lever, "dof": 0, "value": deg_to_rad(90.0)},
	]})
	f.doc.assembly = assembly
	var out := MOTION.study_frames(f.doc, f.result, kernel, study_id)
	var want := DATA.fill(_s("S_STUDY_KEY_TWICE"), {"Joint": "Lever", "time": "0.5 s", "Study": "Motion Study1"})
	print("  30: two keys at 0.5 s: %d frames: %s" % [(out.frames as Array).size(), out.sentence])
	return _expect((out.frames as Array).is_empty() and str(out.sentence) == want, "30: refused with \"%s\" (%d frames, %s)." % [want, (out.frames as Array).size(), out.sentence])


## SB3, PT3: a Bar modelled 1 km and 100 km out, turned 37° by a revolute: Measure between a Bar
## vertex and a Base vertex, and the Bar's mass centre ("center64"), against the same points from
## an unposed STEP (doubles), posed in doubles: within 1e-6 mm (1 km) and 3e-5 mm (100 km, the
## STEP file's own digits).
func _check_far_vertex_mass() -> bool:
	var ok := true
	var native := kernel.has_method("transform_shape64")
	if not native:
		print("  31: SKIP: the loaded native library has no transform_shape64")
		return true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://holo_forge_assembly_contact"))
	# (The STEP reference is written to 13 significant digits: 1e-5 mm per coordinate 100 km out.)
	for spec in [[Vector3(1e6, 0, 0), 1e-6], [Vector3(1e8, 0, 0), 3e-5]]:
		var off: Vector3 = spec[0]
		var limit := float(spec[1]) * MM
		var f := FIX._start(kernel)
		FIX._box(f, "Base", Vector3(-50, -50, 0) + off, Vector3(50, 50, 10) + off, "")
		FIX._box(f, "Bar", Vector3(-10, -10, 10) + off, Vector3(95, 10, 20) + off, "Bar")
		FIX._rebuild(f)
		var world := XFORM.frame(PackedFloat64Array([off.x * MM, off.y * MM, (10 + off.z) * MM]), PackedFloat64Array([0.0, 0.0, 1.0]))
		var joint := FIX.add_as_built_frame(f.doc, "revolute", f.components.Bar, "", world)
		var assembly: Dictionary = DATA.normalized(f.doc.assembly)
		assembly.joints[0].dofs[0]["value"] = deg_to_rad(37.0)
		f.doc.assembly = assembly
		var solved := SOLVER.solve(f.doc, f.result, kernel)
		var pose: PackedFloat64Array = solved.body_poses[f.bodies.Bar]
		var plain_doc: Resource = f.doc.duplicate()
		plain_doc.assembly = {}
		var path := "user://holo_forge_assembly_contact/far_%d.step" % int(off.x)
		EXPORT.export_cad_report(kernel, f.result, [f.bodies.Bar], path, plain_doc)
		var bar_points := _step_points(path)
		EXPORT.export_cad_report(kernel, f.result, [f.bodies.Base], path, plain_doc)
		var base_points := _step_points(path)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		var tip: PackedFloat64Array = _nearest_point(bar_points, PackedFloat64Array([(off.x + 95) * MM, (off.y + 10) * MM, (off.z + 20) * MM]))
		var corner: PackedFloat64Array = _nearest_point(base_points, PackedFloat64Array([(off.x + 50) * MM, (off.y + 50) * MM, (off.z + 10) * MM]))
		var want := _dist64(XFORM.apply(pose, tip), corner)
		var ctx := INSPECT.context(f.result, f.doc, kernel)
		ctx["poses"] = solved.body_poses
		INSPECT.clear_posed()
		var measured := INSPECT.measure(_vertex_ref(f, "Bar", tip), _vertex_ref(f, "Base", corner), ctx)
		var off_by := absf(float(measured.get("distance", -1.0)) - want)
		var low := PackedFloat64Array([INF, INF, INF])
		var high := PackedFloat64Array([-INF, -INF, -INF])
		for p: PackedFloat64Array in bar_points:
			for i in 3:
				low[i] = minf(low[i], p[i])
				high[i] = maxf(high[i], p[i])
		var middle := XFORM.apply(pose, PackedFloat64Array([(low[0] + high[0]) * 0.5, (low[1] + high[1]) * 0.5, (low[2] + high[2]) * 0.5]))
		var mass := INSPECT.mass_properties(f.doc, f.result, [f.bodies.Bar], solved.body_poses)
		var center: Variant = mass.get("center64")
		var center_off := _dist64(center, middle) if center is PackedFloat64Array and (center as PackedFloat64Array).size() == 3 else INF
		var body_center: Variant = ((mass.get("bodies", {}) as Dictionary).get(f.bodies.Bar, {}) as Dictionary).get("center64")
		var body_off := _dist64(body_center, middle) if body_center is PackedFloat64Array and (body_center as PackedFloat64Array).size() == 3 else INF
		print("  31: %s km out: measure off by %s mm; mass centre off by %s mm (body %s mm); joint %s" % [off.x * MM / 1000.0, String.num_scientific(off_by / MM),
			String.num_scientific(center_off / MM), String.num_scientific(body_off / MM), joint])
		ok = _expect(off_by <= limit, "31: %s km: vertex measure within %s mm (%s mm)." % [off.x * MM / 1000.0, limit / MM, off_by / MM]) and ok
		ok = _expect(center_off <= limit and body_off <= limit, "31: %s km: mass centre within %s mm (%s, body %s mm)." % [off.x * MM / 1000.0, limit / MM, center_off / MM, body_off / MM]) and ok
	return ok


# --- 32-35 (fix round 3) -------------------------------------------------------------------------

## lever_stop_contact with the Lever limited to min_deg..max_deg and stored at value_deg.
func _lever_limited(min_deg: float, max_deg: float, value_deg: float) -> Dictionary:
	var f := FIX.lever_stop_contact(kernel)
	var assembly: Dictionary = DATA.normalized(f.doc.assembly)
	for joint in assembly.joints:
		if str(joint.id) == f.joints.Lever:
			joint.dofs[0] = {"value": deg_to_rad(value_deg), "min": deg_to_rad(min_deg), "max": deg_to_rad(max_deg), "limited_min": true, "limited_max": true, "rest": 0.0}
	f.doc.assembly = assembly
	return f


## SB1 at a limit: the Lever stored at its Max 0° (min -3600°) and keyed 0° -> -2880° in 0.137 s,
## or -360° in 0.01 s, stops at its first touch (-300°: 0.01427 s, 0.00833 s) or is refused; never
## played through the Stop. (The N2 nudge must not drop a DOF its limit holds on one side.)
func _check_limit_turning() -> bool:
	var ok := true
	for spec in [[0.137, -2880.0, 0.0142, 0.0144], [0.01, -360.0, 0.0082, 0.0085]]:
		var f := _lever_limited(-3600.0, 0.0, 0.0)
		var assembly: Dictionary = DATA.normalized(f.doc.assembly)
		var study_id := DATA.new_id(assembly, "study")
		assembly.studies.append({"id": study_id, "name": "Motion Study1", "length": 2.0, "fps": 30, "contact": true, "keys": [
			{"time": 0.0, "joint": f.joints.Lever, "dof": 0, "value": 0.0}, {"time": float(spec[0]), "joint": f.joints.Lever, "dof": 0, "value": deg_to_rad(float(spec[1]))},
		]})
		f.doc.assembly = assembly
		var out := MOTION.study_frames(f.doc, f.result, kernel, study_id)
		var at := float(out.stopped_at)
		var refused := (out.frames as Array).is_empty() and str(out.sentence).begins_with("This motion ")
		print("  32: keys 0° -> %s° in %s s, stored at its Max: stopped_at %s s: %s" % [spec[1], spec[0], String.num(at, 6), out.sentence])
		ok = _expect(refused or (at >= float(spec[2]) and at <= float(spec[3]) and str(out.sentence).contains("Lever touches Stop")),
			"32: %s° in %s s from its Max: a stop in [%s, %s] s or a refusal (stopped_at %s: %s)." % [spec[1], spec[0], spec[2], spec[3], at, out.sentence]) and ok
	return ok


## MOTION.turn_rate: the contact-relevant turn per unit of a played DOF. The Lever (in contact) 1;
## stored at its Max still 1; a Knob in no contact set driving the Lever at 0.02 gives 0.02; the
## Lever as that link's follower 1 (its root, the Knob, does not count); a Knob that is the
## follower of the Lever at 0.02 gives 50 (its root, the Lever, turns 50 per unit of the Knob).
func _check_turn_rate() -> bool:
	if not (MOTION as Script).get_script_method_list().any(func(m: Dictionary) -> bool: return str(m.name) == "turn_rate"):
		return _expect(false, "33: MOTION.turn_rate does not exist.")
	var ok := true
	var plain := FIX.lever_stop_contact(kernel)
	var rate := float((MOTION as Object).call("turn_rate", plain.doc, plain.result, kernel, plain.joints.Lever, 0))
	ok = _expect(absf(rate - 1.0) <= 1e-12, "33: the Lever turns 1 per unit (%s)." % rate) and ok
	var at_max := _lever_limited(-3600.0, 0.0, 0.0)
	rate = float((MOTION as Object).call("turn_rate", at_max.doc, at_max.result, kernel, at_max.joints.Lever, 0))
	ok = _expect(absf(rate - 1.0) <= 1e-12, "33: the Lever stored at its Max still turns 1 per unit (%s)." % rate) and ok
	var linked := FIX.lever_stop_linked(kernel)
	var assembly: Dictionary = DATA.normalized(linked.doc.assembly)
	assembly.links[0]["ratio"] = 0.02
	linked.doc.assembly = assembly
	var knob := float((MOTION as Object).call("turn_rate", linked.doc, linked.result, kernel, linked.joints.Knob, 0))
	var lever := float((MOTION as Object).call("turn_rate", linked.doc, linked.result, kernel, linked.joints.Lever, 0))
	print("  33: Knob -> Lever at 0.02: Knob %s, Lever %s" % [knob, lever])
	ok = _expect(absf(knob - 0.02) <= 1e-12 and absf(lever - 1.0) <= 1e-9, "33: Knob 0.02 and Lever 1 (%s, %s)." % [knob, lever]) and ok
	var back := FIX.lever_stop_linked(kernel)
	var reversed: Dictionary = DATA.normalized(back.doc.assembly)
	reversed.links.clear()
	var made := MOTION.new_link(reversed, {"joint": back.joints.Lever, "dof": 0}, {"joint": back.joints.Knob, "dof": 0}, 0.02)
	back.doc.assembly = reversed
	var follower := float((MOTION as Object).call("turn_rate", back.doc, back.result, kernel, back.joints.Knob, 0)) if not made.has("error") else NAN
	print("  33: Lever -> Knob at 0.02: Knob %s (%s)" % [follower, made.get("error", "")])
	ok = _expect(absf(follower - 50.0) <= 1e-9, "33: a played follower counts its root's turn: 50 (%s)." % follower) and ok
	return ok


## N-B: studies of many keys end within their limit + 1 s (here a 3 s limit): 2,500 keys swinging
## 0°/8° (refused up front: too many steps) and 1,500 keys swinging 0°/0.5° (refused as too slow,
## or stopped, or played) in time.
func _check_many_keys() -> bool:
	var ok := true
	for spec in [[2500, 8.0], [1500, 0.5]]:
		var f := FIX.lever_stop_contact(kernel)
		var assembly: Dictionary = DATA.normalized(f.doc.assembly)
		var study_id := DATA.new_id(assembly, "study")
		var keys := []
		var n: int = spec[0]
		for i in n:
			keys.append({"time": 2.0 * float(i) / float(n), "joint": f.joints.Lever, "dof": 0, "value": deg_to_rad(float(spec[1]) if i % 2 == 1 else 0.0)})
		keys.append({"time": 2.0, "joint": f.joints.Lever, "dof": 0, "value": deg_to_rad(20.0)})
		assembly.studies.append({"id": study_id, "name": "Motion Study1", "length": 2.0, "fps": 10, "contact": true, "keys": keys})
		f.doc.assembly = assembly
		var started := Time.get_ticks_usec()
		var out := MOTION.study_frames(f.doc, f.result, kernel, study_id, {"seconds": 3.0})
		var seconds := float(Time.get_ticks_usec() - started) / 1e6
		print("  34: %d keys of %s°: %.2f s, %d frames, stopped_at %s: %s" % [n, spec[1], seconds, (out.frames as Array).size(), out.stopped_at, out.sentence])
		ok = _expect(seconds <= 4.0, "34: %d keys end within the 3 s limit + 1 s (%.2f s: %s)." % [n, seconds, out.sentence]) and ok
	return ok


## SB2 on big meshes: a 0.3 mm fin of its own beside a 1 m sphere of 28,562 triangles (more than
## THIN_RAYS) is found thin: every separate piece gets rays.
func _check_thin_fin() -> bool:
	var pos := PackedVector3Array()
	var idx := PackedInt32Array()
	_uv_sphere(pos, idx, 1.0, 120, 120)
	_box_mesh(pos, idx, Vector3(1.01, 0, 0), Vector3(1.01 + 0.0003, 0.005, 0.005))
	var cw := PackedInt32Array(idx)
	for t in cw.size() / 3:
		var keep := cw[3 * t + 1]
		cw[3 * t + 1] = cw[3 * t + 2]
		cw[3 * t + 2] = keep
	var mesh: RefCounted = ClassDB.instantiate("CadMesh")
	mesh.set_arrays(pos, cw)
	CONTACT.clear_cache()
	var thin := CONTACT.thinness(mesh, 1.0 * MM)
	print("  35: 1 m sphere (%d triangles) + 0.3 mm fin: thinness %s" % [int(mesh.triangle_count()), thin])
	return _expect(not thin.is_empty() and float(thin.t) <= 0.3 * MM * 1.01, "35: the fin is found 0.3 mm thick (%s)." % [thin])


# --- 36 (fix round 4) ------------------------------------------------------------------------------

## A sweep whose shared deadline had passed before it began is refused with S-CONTACT-TIME-USED
## (the budget it had, not the look's own few milliseconds); so is one given no time left of a
## caller's "limit_seconds"; "estimate" and "estimate_again" stay in the result. With 5 s the same
## sweep runs. A look that is slow by itself (20 ms a pose, 0.2 s) still says S-CONTACT-TOO-SLOW.
func _check_time_used() -> bool:
	var f := FIX.lever_stop_contact(kernel)
	CONTACT.clear_cache()
	var path := func(v: float) -> Dictionary:
		return SOLVER.solve(f.doc, f.result, kernel, {f.joints.Lever: {0: v}}).body_poses
	var turn := deg_to_rad(5.0)
	var used_head := str((DATA as Script).get_script_constant_map().get("S_CONTACT_TIME_USED", "")).get_slice("<budget>", 0)
	var slow_head := DATA.S_CONTACT_TOO_SLOW.get_slice("<s>", 0)
	var ok := _expect(used_head.length() > 10, "36: S_CONTACT_TIME_USED exists (%s)." % used_head)
	var passed := CONTACT.sweep(f.doc, f.result, kernel, path, 0.0, turn, {"seconds": 5.0, "deadline_usec": Time.get_ticks_usec(), "turn": turn})
	print("  36: deadline already passed: refused %s, estimate %s, %s" % [passed.refused, passed.get("estimate"), passed.sentence])
	ok = _expect(bool(passed.refused) and float(passed.reached) == 0.0 and str(passed.sentence).begins_with(used_head)
		and str(passed.sentence).contains("5 s") and not str(passed.sentence).begins_with(slow_head),
		"36: a used-up deadline is the reason given (%s)." % passed.sentence) and ok
	ok = _expect(passed.has("estimate") and passed.has("estimate_again") and is_finite(float(passed.estimate)),
		"36: estimate and estimate_again are kept (%s, %s)." % [passed.get("estimate"), passed.get("estimate_again")]) and ok
	var none_left := CONTACT.sweep(f.doc, f.result, kernel, path, 0.0, turn, {"seconds": 0.0, "limit_seconds": 3.0, "turn": turn})
	print("  36: no time left of 3 s: %s" % none_left.sentence)
	ok = _expect(bool(none_left.refused) and str(none_left.sentence).begins_with(used_head) and str(none_left.sentence).contains("3 s"),
		"36: no time left of a 3 s limit names the 3 s (%s)." % none_left.sentence) and ok
	var given := CONTACT.sweep(f.doc, f.result, kernel, path, 0.0, turn, {"seconds": 5.0, "turn": turn})
	ok = _expect(not bool(given.refused) and float(given.reached) > 0.0,
		"36: with 5 s the same sweep runs (refused %s, reached %s, %s)." % [given.refused, given.reached, given.sentence]) and ok
	var slow_path := func(v: float) -> Dictionary:
		OS.delay_msec(20)
		return SOLVER.solve(f.doc, f.result, kernel, {f.joints.Lever: {0: v}}).body_poses
	var wide := deg_to_rad(40.0)
	var slow := CONTACT.sweep(f.doc, f.result, kernel, slow_path, 0.0, wide, {"seconds": 0.2, "turn": wide})
	print("  36: a slow look: refused %s, estimate %s, %.0f ms, %s" % [slow.refused, slow.estimate, slow.ms, slow.sentence])
	ok = _expect(bool(slow.refused) and str(slow.sentence).begins_with(slow_head) and float(slow.estimate) > 0.2,
		"36: a look slow by itself still says how long it would take (%s)." % slow.sentence) and ok
	return ok


## A UV sphere (lat x lon) of radius r at the origin, wound outward (counterclockwise).
func _uv_sphere(pos: PackedVector3Array, idx: PackedInt32Array, r: float, lat: int, lon: int) -> void:
	var base := pos.size()
	pos.append(Vector3(0, 0, r))
	for i in range(1, lat):
		var th := PI * float(i) / float(lat)
		for j in lon:
			var ph := TAU * float(j) / float(lon)
			pos.append(r * Vector3(sin(th) * cos(ph), sin(th) * sin(ph), cos(th)))
	pos.append(Vector3(0, 0, -r))
	var south := pos.size() - 1
	for j in lon:
		idx.append_array([base, base + 1 + j, base + 1 + (j + 1) % lon])
	for i in range(0, lat - 2):
		for j in lon:
			var a := base + 1 + i * lon + j
			var b := base + 1 + (i + 1) * lon + j
			var c := base + 1 + (i + 1) * lon + (j + 1) % lon
			var d := base + 1 + i * lon + (j + 1) % lon
			idx.append_array([a, b, c, a, c, d])
	for j in lon:
		idx.append_array([base + 1 + (lat - 2) * lon + j, south, base + 1 + (lat - 2) * lon + (j + 1) % lon])


## A box from lo to hi, wound outward (counterclockwise).
func _box_mesh(pos: PackedVector3Array, idx: PackedInt32Array, lo: Vector3, hi: Vector3) -> void:
	var b := pos.size()
	for k in 8:
		pos.append(Vector3(hi.x if k & 1 else lo.x, hi.y if k & 2 else lo.y, hi.z if k & 4 else lo.z))
	for q in [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]]:
		idx.append_array([b + q[0], b + q[1], b + q[2], b + q[0], b + q[2], b + q[3]])


## The value of the S-CONTACT-THIN warning for body (m), or 0 when there is none.
func _thin_value(warnings: PackedStringArray, body: String) -> float:
	var head := DATA.S_CONTACT_THIN.get_slice("<t>", 0).replace("<Body>", body)
	for line in warnings:
		if str(line).begins_with(head):
			var text := str(line).substr(head.length()).get_slice(" ", 0)
			return text.to_float() * MM
	return 0.0


## A sentence constant of assembly_data.gd by name ("" when it does not exist yet).
func _s(name: String) -> String:
	return str((DATA as Script).get_script_constant_map().get(name, ""))


## The CARTESIAN_POINTs of a STEP file (m), the origin left out.
func _step_points(path: String) -> Array:
	var rx := RegEx.create_from_string("CARTESIAN_POINT\\('[^']*',\\(\\s*([-0-9.E+]+)\\s*,\\s*([-0-9.E+]+)\\s*,\\s*([-0-9.E+]+)\\s*\\)")
	var out := []
	for r in rx.search_all(FileAccess.get_file_as_string(path)):
		var q := PackedFloat64Array([r.get_string(1).to_float() * MM, r.get_string(2).to_float() * MM, r.get_string(3).to_float() * MM])
		if q[0] == 0.0 and q[1] == 0.0 and q[2] == 0.0:
			continue
		out.append(q)
	return out


func _nearest_point(points: Array, p: PackedFloat64Array) -> PackedFloat64Array:
	var best := INF
	var at := PackedFloat64Array([NAN, NAN, NAN])
	for q: PackedFloat64Array in points:
		var d := _dist64(q, p)
		if d < best:
			best = d
			at = q
	return at


func _dist64(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	return sqrt((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]) + (a[2] - b[2]) * (a[2] - b[2]))


## The vertex reference of a body's vertex nearest p (m), as a pick makes it.
func _vertex_ref(f: Dictionary, body: String, p: PackedFloat64Array) -> Dictionary:
	var shape: RefCounted = f.result.bodies[f.bodies[body]].shape
	var best := -1
	var best_d := INF
	for i in int(shape.vertex_count()):
		var v: Vector3 = shape.vertex_position(i)
		var d := _dist64(PackedFloat64Array([v.x, v.y, v.z]), p)
		if d < best_d:
			best_d = d
			best = i
	return REFERENCES.from_pick({"kind": "vertex", "body": f.bodies[body], "index": best}, f.result)


## An overlap() stand-in that always fails (with or without self_crossing).
class _BadMesh:
	extends RefCounted
	var crossing := false

	func _init(self_crossing: bool) -> void:
		crossing = self_crossing

	func overlap(_other: RefCounted, _xform: PackedFloat64Array, _options: Dictionary) -> Dictionary:
		return {
			"overlap": false, "thickness": 0.0, "volume": 0.0, "point": PackedFloat64Array([0.0, 0.0, 0.0]), "early_out": false, "timed_out": false,
			"error": "Contact could not measure the overlap cleanly. This is a Holo Forge fault; please report it.", "self_crossing": crossing,
		}


# --- Helpers -------------------------------------------------------------------------------------

func _add_mesh(doc: Resource, mesh: RefCounted, name: String, xform: Transform3D) -> String:
	var feature: Resource = doc.add_feature("mesh_import", "Mesh", {}, {
		"path": "", "kind": INSERT.KIND_MESH, "units": "mm", "mesh_units": "mm", "linked": false, "split": false,
		"transform": xform, "operation": OPERATIONS.NEW_BODY, "mesh": MESH_BLOB.from_mesh(mesh),
	})
	var body_id: String = doc.new_body(feature.id)
	feature.options["body_id"] = body_id
	doc.bodies[body_id]["name"] = name
	return body_id


func _set_name(f: Dictionary) -> String:
	var assembly: Dictionary = DATA.normalized(f.doc.assembly)
	return str(assembly.contact_sets[0].name)


## The overlap thickness of two bodies at body_poses (their contact meshes; INF when it can't be
## measured).
func _pair_thickness(f: Dictionary, body_poses: Dictionary, id_a: String, id_b: String) -> float:
	var a := CONTACT.contact_mesh(f.doc, f.result, id_a)
	var b := CONTACT.contact_mesh(f.doc, f.result, id_b)
	if a.get("mesh") == null or b.get("mesh") == null:
		_expect(false, "No contact mesh (%s, %s)." % [a.get("error"), b.get("error")])
		return INF
	var relative := XFORM.compose(XFORM.inverse(body_poses[id_a]), body_poses[id_b])
	var found: Dictionary = (a.mesh as RefCounted).overlap(b.mesh, relative, {"time_limit": 5.0})
	if bool(found.timed_out) or str(found.error) != "":
		_expect(false, "The overlap could not be measured (%s)." % [found])
		return INF
	return float(found.thickness)


func _tol_eff(f: Dictionary, id_a: String, id_b: String) -> float:
	return TOLERANCE + float(CONTACT.contact_mesh(f.doc, f.result, id_a).get("dev", 0.0)) + float(CONTACT.contact_mesh(f.doc, f.result, id_b).get("dev", 0.0))


func _has_prefix(list: Variant, prefix: String) -> bool:
	for line in list:
		if str(line).begins_with(prefix):
			return true
	return false


## A sweep result without its bulky keys, for messages.
func _short(contact: Dictionary) -> String:
	var shown := {}
	for key in ["reached", "stopped", "pair", "set", "timed_out", "checked_pairs", "steps", "sentence", "ms"]:
		if contact.has(key):
			shown[key] = contact[key]
	return str(shown)


func _case(label: String, passed: bool) -> void:
	if passed:
		print("  ok   ", label)
	else:
		print("  FAIL ", label)
		failures.append(label)


func _expect(ok: bool, detail: String) -> bool:
	if not ok:
		push_error("holo_forge_assembly_contact: " + detail)
	return ok
