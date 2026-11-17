extends SceneTree
## Holo Forge Phase 8, Stage 3 (spec 5.8): the plan's acceptance test. One script drives a headless
## WORKSPACE.new() through the real Assemble commands (Joint, Drive Joints, Motion Link, as a user
## would: values typed into their panels, then OK) on lever() and gears(), each baked by a CadPart
## set to K's exports (component_node_type RigidBody3D, bake_joints on, bake_pose Current).
##
## 1. Revolute limits clamp a drive: Lever revolute -30°..90°; Drive Joints to 120° stops exactly
##    at 90° with S-LIMIT; to -45° stops exactly at -30°.
## 2. A 2:1 link is honoured: Gear1 -> Gear2 ratio 2; driving Gear1 to 30° puts Gear2 at 60° (1e-15
##    relative); with Gear2 max 90°, driving Gear1 to 60° stops it at 45° with S-LINK-LIMIT.
## 3. The bake makes matching Joint3D types and node paths: Joints/Joint1 is a HingeJoint3D with
##    node_a "" and node_b "../../Lever", the gear joints are HingeJoint3D too, get_node(node_b) is a
##    RigidBody3D for each; hinge limits read lower = v_b - max, upper = v_b - min (K's V2/V5), at
##    the Current and the Rest bake pose; a half-limited hinge is open (π) at its free end.
## 4. Undo to the start gives the empty assembly (and no baked joint); Redo gives it all back
##    (deep-equal, poses exact); save and reload (own user:// scene) gives a deep-equal assembly and
##    the same poses (exact), and the same baked joints.
##
## godot --headless --path . --script res://tests/holo_forge_assembly_test.gd

const WORKSPACE := preload("res://addons/holo_forge/ui/forge_workspace.gd")
const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const CATALOG := preload("res://addons/holo_forge/tools/catalog.gd")
const F := preload("res://tests/holo_forge_assembly_fixtures.gd")
const DATA := preload("res://addons/holo_forge/core/assembly/assembly_data.gd")
const JOINT_MATH := preload("res://addons/holo_forge/core/assembly/joint_math.gd")

## Where the saved scenes go (the test's own folder).
const SCENE_DIR := "user://holo_forge_assembly_test"
## Godot keeps joint parameters as 32-bit floats.
const PARAM_TOLERANCE := 1e-6

var failures: Array[String] = []
var ws: Control
## Case label -> [passed, text]; filled as the two parts run, printed in spec order.
var cases := {}


func _init() -> void:
	call_deferred("run")


func run() -> void:
	create_timer(300.0).timeout.connect(func() -> void:
		print("FAIL holo_forge_assembly: timed out ", failures)
		quit(1))
	if not (ClassDB.class_exists("CadShape") and ClassDB.class_exists("CadMesh")):
		print("SKIP holo_forge_assembly: native library missing")
		quit(0)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SCENE_DIR))
	ws = WORKSPACE.new()
	root.add_child(ws)
	ws.size = Vector2(1400, 900)
	for i in 3:
		await process_frame
	var started := Time.get_ticks_msec()
	await _lever_part()
	var lever_ms := Time.get_ticks_msec() - started
	started = Time.get_ticks_msec()
	await _gears_part()
	var gears_ms := Time.get_ticks_msec() - started
	for label in ["1 revolute limits clamp a drive", "2 a 2:1 link is honoured", "3 bake: Joint3D types and node paths", "4 undo, redo, save and reload"]:
		var parts: Array = cases.get(label, [false, "not run"])
		print(("PASS " if bool(parts[0]) else "FAIL ") + label + ": " + str(parts[1]))
	print("timing: lever part %d ms, gears part %d ms" % [lever_ms, gears_ms])
	ws.set_part(null)
	ws.queue_free()
	await process_frame
	print("PASS holo_forge_assembly: all cases" if failures.is_empty() else "FAIL holo_forge_assembly: %d failures" % failures.size())
	quit(0 if failures.is_empty() else 1)


# --- lever(): cases 1, 3, 4 ----------------------------------------------------------------------

func _lever_part() -> void:
	var f := F.lever()
	var part := await _start(f)
	var start_assembly: Dictionary = f.doc.assembly.duplicate(true)
	var steps := []
	# Joint: the Lever's hole circle on the Base's, limits -30°..90°.
	var cmd := _tool("solid.assemble.joint")
	var ok := _expect(cmd != null and str(ws.command_values.get("type", "")) == "revolute", "1: Joint should open with Revolute chosen.")
	if cmd == null:
		_finish(part)
		_record("1 revolute limits clamp a drive", false, "Joint did not open")
		return
	await _put({
		"a": [cmd.snap_item(F.circle_snap(f, "Lever", Vector3(0, 0, 10), 5.0))],
		"b": [cmd.snap_item(F.circle_snap(f, "Base", Vector3(0, 0, 10), 5.0))],
		"dof0_limited_min": true, "dof0_min": "-30 deg", "dof0_limited_max": true, "dof0_max": "90 deg",
	})
	ok = _expect(str(cmd.refusal) == "" and str(cmd.prompt) == "", "1: Joint should take both picks (%s)." % _status()) and ok
	ok = _accept(steps, "Joint", "1") and ok
	var joints: Array = DATA.normalized(f.doc.assembly).joints
	ok = _expect(joints.size() == 1 and str(joints[0].name) == "Joint1", "1: one joint named Joint1 (%d)." % joints.size()) and ok
	if joints.size() != 1:
		_finish(part)
		_record("1 revolute limits clamp a drive", false, "no joint")
		return
	var joint_id := str(joints[0].id)
	var dof: Dictionary = joints[0].dofs[0]
	ok = _expect(bool(dof.limited_min) and bool(dof.limited_max) and absf(float(dof.min) - deg_to_rad(-30.0)) <= 1e-15 and absf(float(dof.max) - deg_to_rad(90.0)) <= 1e-15,
		"1: the stored limits should be -30°..90° (%s)." % [dof]) and ok
	# Drive Joints to 120°: S-LIMIT, stops exactly at the max.
	var said_high := await _drive(joint_id, "120 deg")
	var max_text := JOINT_MATH.format_angle(float(dof.max))
	var expected_high := DATA.fill(DATA.S_LIMIT, {"Joint": "Joint1", "limit": max_text, "target": JOINT_MATH.format_angle(deg_to_rad(120.0))})
	ok = _expect(said_high.contains(expected_high), "1: the status row should say \"%s\" (%s)." % [expected_high, said_high]) and ok
	ok = _accept(steps, "Drive Joint1", "1") and ok
	var high := _value(f, joint_id)
	ok = _expect(high == float(dof.max), "1: 120° should store exactly the max %s (%s)." % [float(dof.max), high]) and ok
	# And to -45°: stops exactly at the min.
	var said_low := await _drive(joint_id, "-45 deg")
	var expected_low := DATA.fill(DATA.S_LIMIT, {"Joint": "Joint1", "limit": JOINT_MATH.format_angle(float(dof.min)), "target": JOINT_MATH.format_angle(deg_to_rad(-45.0))})
	ok = _expect(said_low.contains(expected_low), "1: the status row should say \"%s\" (%s)." % [expected_low, said_low]) and ok
	ok = _accept(steps, "Drive Joint1", "1") and ok
	var low := _value(f, joint_id)
	ok = _expect(low == float(dof.min), "1: -45° should store exactly the min %s (%s)." % [float(dof.min), low]) and ok
	_record("1 revolute limits clamp a drive", ok, "120° -> %s (\"%s\"), -45° -> %s (\"%s\"), both exact" % [JOINT_MATH.format_angle(high), said_high, JOINT_MATH.format_angle(low), said_low])
	# 3. The bake at the Current pose (the Lever at -30°), then at Rest (0°).
	var bake := _check_lever_bake(f, part, joint_id)
	# 4. Undo, redo, save, reload.
	var history := await _check_history(f, part, steps, start_assembly, ["Joint1"], "lever")
	_record("3 bake: Joint3D types and node paths", bake[0], bake[1])
	_record("4 undo, redo, save and reload", history[0], history[1])
	_finish(part)


## Joints/Joint1 on the Lever's RigidBody3D, its limits at the Current pose and at Rest.
func _check_lever_bake(f: Dictionary, part: Node3D, joint_id: String) -> Array:
	var joint := _joint(f, joint_id)
	var dof: Dictionary = joint.dofs[0]
	var v_b := float(dof.value)
	var ok := _expect((part.last_bake_report.errors as PackedStringArray).is_empty(), "3: the Lever bake has no read-back errors (%s)." % [part.last_bake_report.errors])
	ok = _check_hinge(part, "Joint1", "Lever", true, v_b - float(dof.max), v_b - float(dof.min), "3 Current") and ok
	var current := _hinge_text(part, "Joint1")
	# bake_pose Rest (K's export; in the editor changing it bakes again, headless we bake as the
	# workspace does after an assembly change): every DOF at its rest value 0.
	part.bake_pose = CAD_PART.BAKE_POSE_REST
	part.bake_assembly(ws.result)
	var rest := float(dof.rest)
	ok = _check_hinge(part, "Joint1", "Lever", true, rest - float(dof.max), rest - float(dof.min), "3 Rest") and ok
	var at_rest := _hinge_text(part, "Joint1")
	part.bake_pose = CAD_PART.BAKE_POSE_CURRENT
	part.bake_assembly(ws.result)
	ok = _check_hinge(part, "Joint1", "Lever", true, v_b - float(dof.max), v_b - float(dof.min), "3 Current again") and ok
	return [ok, "Lever: %s at Current (v_b %s), %s at Rest" % [current, JOINT_MATH.format_angle(v_b), at_rest]]


# --- gears(): cases 2, 3, 4 ----------------------------------------------------------------------

func _gears_part() -> void:
	var f := F.gears()
	# gears() comes with its joints; the test makes them with the Joint command instead, so the
	# start is the empty assembly.
	f.doc.assembly = {}
	f.joints.clear()
	var part := await _start(f)
	var start_assembly: Dictionary = f.doc.assembly.duplicate(true)
	var steps := []
	var ok := true
	for gear in [["Gear1", Vector2(0, 0), 20.0, {}], ["Gear2", Vector2(30, 0), 10.0, {"dof0_limited_max": true, "dof0_max": "90 deg"}]]:
		var cmd := _tool("solid.assemble.joint")
		if cmd == null:
			ok = _expect(false, "2: Joint should open.")
			break
		var at: Vector2 = gear[1]
		var values := {
			"a": [cmd.snap_item(F.circle_snap(f, gear[0], Vector3(at.x, at.y, 10), gear[2]))],
			"b": [cmd.snap_item(F.circle_snap(f, "Base", Vector3(at.x, at.y, 10), 2.0))],
		}
		values.merge(gear[3], true)
		await _put(values)
		ok = _expect(str(cmd.refusal) == "" and str(cmd.prompt) == "", "2: the %s joint should take both picks (%s)." % [gear[0], _status()]) and ok
		ok = _accept(steps, "Joint", "2") and ok
	var j1 := _joint_id(f, "Joint1")
	var j2 := _joint_id(f, "Joint2")
	ok = _expect(j1 != "" and j2 != "", "2: the joints should be Joint1 and Joint2 (%s)." % [DATA.normalized(f.doc.assembly).joints]) and ok
	if j1 == "" or j2 == "":
		_finish(part)
		_record("2 a 2:1 link is honoured", false, "the gear joints were not made")
		return
	# Motion Link Gear1 -> Gear2, ratio 2.
	var link := _tool("solid.assemble.motion_link")
	ok = _expect(link != null, "2: Motion Link should open.") and ok
	if link != null:
		await _put({"driver": j1 + "|0", "follower": j2 + "|0", "ratio": "2"})
		ok = _expect(str(link.refusal) == "", "2: the 2:1 link should be fine (%s)." % _status()) and ok
		ok = _accept(steps, "Motion Link", "2") and ok
	var links: Array = DATA.normalized(f.doc.assembly).links
	ok = _expect(links.size() == 1 and float(links[0].ratio) == 2.0, "2: one 2:1 link (%s)." % [links]) and ok
	# Drive Gear1 to 30°: Gear2 is 60°.
	var said := await _drive(j1, "30 deg")
	ok = _expect(said == "", "2: driving to 30° should say nothing (%s)." % said) and ok
	ok = _accept(steps, "Drive Joint1", "2") and ok
	var g1 := _value(f, j1)
	var g2 := _value(f, j2)
	ok = _expect(_rel(g1, deg_to_rad(30.0)) <= 1e-15, "2: Gear1 should be 30° (%.17f)." % g1) and ok
	ok = _expect(_rel(g2, deg_to_rad(60.0)) <= 1e-15 and _rel(g2, 2.0 * g1) <= 1e-15, "2: Gear2 should be 60° = 2 x Gear1 (%.17f, %s relative)." % [g2, String.num_scientific(_rel(g2, deg_to_rad(60.0)))]) and ok
	var first := "Gear1 30° -> Gear2 %s (%s relative)" % [JOINT_MATH.format_angle(g2), String.num_scientific(_rel(g2, deg_to_rad(60.0)))]
	# Drive Gear1 to 60°: Gear2 would pass its 90° max, so Gear1 stops at 45° (S-LINK-LIMIT).
	said = await _drive(j1, "60 deg")
	var max2 := float(_joint(f, j2).dofs[0].max)
	var head := DATA.S_LINK_LIMIT.get_slice("<ratio>", 0).replace("<Joint>", "Joint1").replace("<value>", JOINT_MATH.format_angle(max2 * 0.5)).replace("<Follower>", "Joint2")
	var tail := DATA.S_LINK_LIMIT.get_slice("<ratio>", 1).replace("<limit>", JOINT_MATH.format_angle(max2))
	ok = _expect(said.contains(head) and said.contains(tail), "2: the status row should say S-LINK-LIMIT (\"%s…%s\"; %s)." % [head, tail, said]) and ok
	ok = _accept(steps, "Drive Joint1", "2") and ok
	g1 = _value(f, j1)
	g2 = _value(f, j2)
	ok = _expect(g2 == max2, "2: Gear2 should stop exactly at its max %.17f (%.17f)." % [max2, g2]) and ok
	ok = _expect(_rel(g1, max2 * 0.5) <= 1e-15 and _rel(g1, deg_to_rad(45.0)) <= 1e-15, "2: Gear1 should stop at 45° (%.17f)." % g1) and ok
	_record("2 a 2:1 link is honoured", ok, "%s; 60° -> Gear1 %s, Gear2 %s (\"%s\")" % [first, JOINT_MATH.format_angle(g1), JOINT_MATH.format_angle(g2), said])
	# 3. The gear joints: HingeJoint3D on the gears' RigidBody3D nodes.
	var bake_ok := _check_hinge(part, "Joint1", "Gear1", false, 0.0, 0.0, "3 gears")
	var v2 := float(_joint(f, j2).dofs[0].value)
	bake_ok = _check_hinge(part, "Joint2", "Gear2", true, v2 - max2, PI, "3 gears") and bake_ok
	var notes: PackedStringArray = part.last_bake_report.notes
	var half := DATA.fill(DATA.S_BAKE_HALF_LIMIT, {"Joint": "Joint2", "value": JOINT_MATH.format_angle(PI)})
	bake_ok = _expect(notes.has(half), "3: the half-limited Joint2 should say \"%s\" (%s)." % [half, notes]) and bake_ok
	var bake_text := "gears: Joint1 %s, Joint2 %s; notes: %s" % [_hinge_text(part, "Joint1"), _hinge_text(part, "Joint2"), " / ".join(notes)]
	var history := await _check_history(f, part, steps, start_assembly, ["Joint1", "Joint2"], "gears")
	var lever_bake: Array = cases.get("3 bake: Joint3D types and node paths", [true, ""])
	_record("3 bake: Joint3D types and node paths", bool(lever_bake[0]) and bake_ok, str(lever_bake[1]) + "; " + bake_text)
	var lever_history: Array = cases.get("4 undo, redo, save and reload", [true, ""])
	_record("4 undo, redo, save and reload", bool(lever_history[0]) and bool(history[0]), str(lever_history[1]) + "; " + str(history[1]))
	_finish(part)


# --- Case 4: history and saving --------------------------------------------------------------------

## Undo every step back to the start (the empty assembly, no baked joint), Redo them all (deep-equal,
## poses exact), then save the part as its own scene, load it and open it: the same assembly, poses
## and baked joints.
func _check_history(f: Dictionary, part: Node3D, steps: Array, start_assembly: Dictionary, joint_names: Array, label: String) -> Array:
	var made: Dictionary = f.doc.assembly.duplicate(true)
	var poses: Dictionary = (ws.assembly_solve.get("body_poses", {}) as Dictionary).duplicate(true)
	var baked := _joint_nodes_text(part, joint_names)
	var ok := _expect(not poses.is_empty(), "4 %s: the stored solve should have poses." % label)
	for i in range(steps.size() - 1, -1, -1):
		ws._apply_snapshot(part, steps[i].before)
	await process_frame
	ok = _expect(f.doc.assembly == start_assembly and DATA.normalized(f.doc.assembly) == DATA.normalized({}), "4 %s: Undo to the start should give the empty assembly (%s)." % [label, f.doc.assembly]) and ok
	for joint_name in joint_names:
		ok = _expect(part.get_node_or_null("Joints/" + str(joint_name)) == null, "4 %s: after Undo the bake should hold no Joints/%s." % [label, joint_name]) and ok
	for step in steps:
		ws._apply_snapshot(part, step.after)
	await process_frame
	ok = _expect(f.doc.assembly == made, "4 %s: Redo should give the assembly back deep-equal." % label) and ok
	ok = _expect(_same_poses(ws.assembly_solve.get("body_poses", {}), poses), "4 %s: Redo should give the same poses (exact)." % label) and ok
	ok = _expect(_joint_nodes_text(part, joint_names) == baked, "4 %s: Redo should bake the same joints." % label) and ok
	# Save the part as its own scene and load it back.
	var path := "%s/%s.tscn" % [SCENE_DIR, label]
	var scene := PackedScene.new()
	var packed := scene.pack(part)
	var saved := ResourceSaver.save(scene, path) if packed == OK else packed
	ok = _expect(saved == OK, "4 %s: the scene should save to %s (error %d)." % [label, path, saved]) and ok
	var loaded_scene := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene
	var loaded: Node3D = loaded_scene.instantiate() if loaded_scene != null else null
	ok = _expect(loaded != null and loaded.get("document") != null and not is_same(loaded.document, f.doc), "4 %s: the scene should load with its own document." % label) and ok
	if loaded == null or loaded.get("document") == null:
		return [false, "%s: the saved scene did not load" % label]
	ok = _expect(loaded.document.assembly == made, "4 %s: the reloaded assembly should be deep-equal." % label) and ok
	ok = _expect(int(loaded.component_node_type) == CAD_PART.COMPONENT_RIGID_BODY and bool(loaded.bake_joints) and int(loaded.bake_pose) == CAD_PART.BAKE_POSE_CURRENT,
		"4 %s: the reloaded part keeps its bake exports." % label) and ok
	ok = _expect(_joint_nodes_text(loaded, joint_names) == baked, "4 %s: the reloaded scene should hold the same baked joints (%s vs %s)." % [label, _joint_nodes_text(loaded, joint_names), baked]) and ok
	# Opened in the workspace (its own rebuild and solve): the same poses, exact.
	ws.set_part(null)
	root.add_child(loaded)
	ws.set_part(loaded)
	await process_frame
	ok = _expect(_same_poses(ws.assembly_solve.get("body_poses", {}), poses), "4 %s: the reloaded part should solve to the same poses (exact)." % label) and ok
	ok = _expect(_joint_nodes_text(loaded, joint_names) == baked, "4 %s: opening the reloaded part should bake the same joints." % label) and ok
	ws.set_part(null)
	loaded.queue_free()
	ws.set_part(part)
	await process_frame
	return [ok, "%s: %d steps undone to the empty assembly and redone, saved to %s and reloaded: assembly deep-equal, %d body poses exact" % [label, steps.size(), path, poses.size()]]


# --- Helpers ---------------------------------------------------------------------------------------

## A CadPart of fixture f set to RigidBody3D components with joints at the Current pose, opened in
## the workspace (which builds and bakes it).
func _start(f: Dictionary) -> Node3D:
	var part: Node3D = CAD_PART.new()
	part.name = "Part"
	part.document = f.doc
	part.component_node_type = CAD_PART.COMPONENT_RIGID_BODY
	part.bake_joints = true
	part.bake_pose = CAD_PART.BAKE_POSE_CURRENT
	root.add_child(part)
	ws.set_part(part)
	await process_frame
	return part


func _finish(part: Node3D) -> void:
	if ws.command != null:
		ws.cancel_command()
	ws.set_part(null)
	part.queue_free()


func _tool(id: String) -> RefCounted:
	var tool := CATALOG.find(id)
	if tool.is_empty():
		return null
	ws.run_tool(tool)
	return ws.command


## Sets panel values as if typed and lets the deferred refresh run.
func _put(values: Dictionary) -> void:
	if ws.command == null:
		return
	var merged: Dictionary = ws.command_values.duplicate(true)
	merged.merge(values, true)
	ws.set_command_values(merged)
	await process_frame
	await process_frame


## Opens Drive Joints from the catalog on joint_id, types value into its Value row and returns the
## status row.
func _drive(joint_id: String, value: String) -> String:
	if _tool("solid.assemble.drive_joints") == null:
		_expect(false, "Drive Joints should open.")
		return ""
	if str(ws.command_values.get("joint", "")) != joint_id:
		await _put({"joint": joint_id})
	await _put({"dof0_value": value})
	return _status()


## OK, which should close the panel and add one undo step named action; the step goes on steps.
func _accept(steps: Array, action: String, label: String) -> bool:
	var count: int = ws.undo_step_count
	ws.accept_command()
	var ok := _expect(ws.command == null and ws.undo_step_count == count + 1 and str(ws.last_step.get("name", "")) == action,
		"%s: OK should add one undo step named %s (%s)." % [label, action, ws.last_step.get("name", "")])
	steps.append(ws.last_step)
	return ok


## A baked joint node: its class and paths, node_b a RigidBody3D that is the component's node, and
## the hinge limit (limited: enabled with lower and upper within PARAM_TOLERANCE).
func _check_hinge(part: Node3D, joint_name: String, component: String, limited: bool, lower: float, upper: float, label: String) -> bool:
	var hinge := part.get_node_or_null("Joints/" + joint_name) as HingeJoint3D
	if not _expect(hinge != null, "%s: Joints/%s should be a HingeJoint3D (%s)." % [label, joint_name, part.get_node_or_null("Joints/" + joint_name)]):
		return false
	var ok := _expect(hinge.node_a == NodePath("") and hinge.node_b == NodePath("../../" + component),
		"%s: %s node_a/node_b should be \"\" and ../../%s (%s, %s)." % [label, joint_name, component, hinge.node_a, hinge.node_b])
	var body := hinge.get_node_or_null(hinge.node_b)
	ok = _expect(body is RigidBody3D and body == part.get_node_or_null(component), "%s: %s's node_b should be the %s RigidBody3D (%s)." % [label, joint_name, component, body]) and ok
	ok = _expect(hinge.get_flag(HingeJoint3D.FLAG_USE_LIMIT) == limited, "%s: %s's limit should be %s." % [label, joint_name, "on" if limited else "off"]) and ok
	if limited:
		var got_lower := hinge.get_param(HingeJoint3D.PARAM_LIMIT_LOWER)
		var got_upper := hinge.get_param(HingeJoint3D.PARAM_LIMIT_UPPER)
		ok = _expect(absf(got_lower - lower) <= PARAM_TOLERANCE and absf(got_upper - upper) <= PARAM_TOLERANCE,
			"%s: %s should read lower %s, upper %s (v_b - max, v_b - min); it reads %s, %s." % [label, joint_name,
				JOINT_MATH.format_angle(lower), JOINT_MATH.format_angle(upper), JOINT_MATH.format_angle(got_lower), JOINT_MATH.format_angle(got_upper)]) and ok
	return ok


func _hinge_text(part: Node3D, joint_name: String) -> String:
	var hinge := part.get_node_or_null("Joints/" + joint_name) as HingeJoint3D
	if hinge == null:
		return "no %s" % joint_name
	var text := "%s %s -> %s" % [hinge.get_class(), joint_name, hinge.node_b]
	if hinge.get_flag(HingeJoint3D.FLAG_USE_LIMIT):
		text += " [%s, %s]" % [JOINT_MATH.format_angle(hinge.get_param(HingeJoint3D.PARAM_LIMIT_LOWER)), JOINT_MATH.format_angle(hinge.get_param(HingeJoint3D.PARAM_LIMIT_UPPER))]
	else:
		text += " unlimited"
	return text


## The baked joints as text: class, paths, transform and limits (exact).
func _joint_nodes_text(part: Node3D, joint_names: Array) -> String:
	var parts := PackedStringArray()
	for joint_name in joint_names:
		var node := part.get_node_or_null("Joints/" + str(joint_name)) as Joint3D
		if node == null:
			parts.append("none")
			continue
		var text := "%s %s %s %s" % [node.get_class(), node.node_a, node.node_b, var_to_str(node.transform)]
		if node is HingeJoint3D:
			text += " %s %s %s" % [(node as HingeJoint3D).get_flag(HingeJoint3D.FLAG_USE_LIMIT), var_to_str((node as HingeJoint3D).get_param(HingeJoint3D.PARAM_LIMIT_LOWER)),
				var_to_str((node as HingeJoint3D).get_param(HingeJoint3D.PARAM_LIMIT_UPPER))]
		parts.append(text)
	return " | ".join(parts)


## True when two body-pose dictionaries hold the same bodies with byte-equal xform64s.
func _same_poses(a: Variant, b: Variant) -> bool:
	if not (a is Dictionary and b is Dictionary) or (a as Dictionary).size() != (b as Dictionary).size():
		return false
	for id in b:
		if not (a as Dictionary).has(id) or not (a[id] is PackedFloat64Array) or not (b[id] is PackedFloat64Array):
			return false
		if (a[id] as PackedFloat64Array).to_byte_array() != (b[id] as PackedFloat64Array).to_byte_array():
			return false
	return true


func _joint(f: Dictionary, joint_id: String) -> Dictionary:
	for joint in DATA.normalized(f.doc.assembly).joints:
		if str(joint.id) == joint_id:
			return joint
	return {}


func _joint_id(f: Dictionary, joint_name: String) -> String:
	for joint in DATA.normalized(f.doc.assembly).joints:
		if str(joint.name) == joint_name:
			return str(joint.id)
	return ""


## A joint's stored DOF 0 value.
func _value(f: Dictionary, joint_id: String) -> float:
	var joint := _joint(f, joint_id)
	return float(joint.dofs[0].value) if not joint.is_empty() else NAN


func _rel(a: float, b: float) -> float:
	return absf(a - b) / absf(b) if b != 0.0 else absf(a)


func _status() -> String:
	return ws.panel.info("status")


func _record(label: String, passed: bool, text: String) -> void:
	cases[label] = [passed, text]


func _expect(ok: bool, detail: String) -> bool:
	if not ok:
		failures.append(detail)
		print("  - " + detail)
	return ok
