extends SceneTree
## Holo Forge Phase 8, Stage 2, team T (spec 5.5): the Assemble tools, panels, actions and the
## browser's assembly items, through a headless WORKSPACE.new() and the real commands.
##
## 1. Catalog: Phase 8 is on, every Assemble tool is enabled wherever the group is listed, Flange
##    (Phase 9) is greyed.
## 2. Joint through the command with picks: OK adds one joint ("Joint"); Undo / Redo.
## 3. Cancel: the assembly and the view's poses are as before.
## 4. As-built Joint: OK moves no body.
## 5. Joint Origin, then a joint snapped to it: the joint frame is the origin frame.
## 6. Rigid Group: two components; one is refused (S-GROUP-SMALL).
## 7. Drive: 120° on the limited Lever says S-LIMIT; OK stores exactly 90°.
## 8. Motion Link: made through its panel; each refusal shows and blocks OK.
## 9. Contact: toggle_contact_sets is one undo step; New Contact Set from a browser selection;
##    Contact Settings refuses Step 0.
## 10. Motion Study panel: two keys, frames, playback poses the holders; one undo step per edit.
## 11. Ground / Unground / Place Component / Reset Placement / Move to Active Component.
## 12. Delete and Suppress a joint; deleting a joint deletes its links in the same step.
## 13. S-NO-COMPONENTS and S-SAME-UNIT.
## 14. Measure and Center of Mass on the posed Lever.
## 15. Every Assemble catalog entry and every spec 6.3 icon has an SVG that loads.
##
## godot --headless --path . --script res://tests/holo_forge_assembly_tools_test.gd

const WORKSPACE := preload("res://addons/holo_forge/ui/forge_workspace.gd")
const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const CATALOG := preload("res://addons/holo_forge/tools/catalog.gd")
const TOOLBAR := preload("res://addons/holo_forge/ui/toolbar.gd")
const F := preload("res://tests/holo_forge_assembly_fixtures.gd")
const DATA := preload("res://addons/holo_forge/core/assembly/assembly_data.gd")
const XFORM := preload("res://addons/holo_forge/core/assembly/xform64.gd")
const SNAPS := preload("res://addons/holo_forge/core/assembly/snaps.gd")
const MOTION := preload("res://addons/holo_forge/core/assembly/motion.gd")
const INSPECT := preload("res://addons/holo_forge/core/inspect.gd")
const JOINT_MATH := preload("res://addons/holo_forge/core/assembly/joint_math.gd")
const MESH_FIX := preload("res://tests/holo_forge_mesh_fixtures.gd")
const CONTACT := preload("res://addons/holo_forge/core/assembly/contact.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")

const MM := 0.001
## Every Assemble tool of the shared group.
const ASSEMBLE_TOOLS := ["Joint", "As-built Joint", "Joint Origin", "Rigid Group", "Drive Joints", "Motion Link", "Enable Contact Sets", "Motion Study"]
## The spec 6.3 icon files.
const ICONS_63 := [
	"joint_rigid", "joint_revolute", "joint_slider", "joint_cylindrical", "joint_pin_slot", "joint_planar", "joint_ball",
	"ground", "unground", "contact_set",
]

var failures: Array[String] = []
var ws: Control
var native := false


func _init() -> void:
	call_deferred("run")


func run() -> void:
	create_timer(300.0).timeout.connect(func() -> void:
		print("FAIL holo_forge_assembly_tools: timed out ", failures)
		quit(1))
	native = ClassDB.class_exists("CadShape") and ClassDB.class_exists("CadMesh")
	ws = WORKSPACE.new()
	root.add_child(ws)
	ws.size = Vector2(1400, 900)
	for i in 3:
		await process_frame
	_case("1 catalog: Phase 8 on, Flange greyed", _check_catalog())
	if native:
		_case("2 joint OK, undo, redo", await _check_joint())
		_case("3 cancel restores", await _check_cancel())
		_case("4 as-built joint moves nothing", await _check_as_built())
		_case("5 joint origin and a joint on it", await _check_origin())
		_case("6 rigid group", await _check_rigid_group())
		_case("7 drive to a limit", await _check_drive())
		_case("8 motion link and its refusals", await _check_link())
		_case("9 contact toggle, contact set, settings", await _check_contact())
		_case("10 motion study panel", await _check_study())
		_case("11 ground, place, reset, move to component", await _check_component_actions())
		_case("12 delete and suppress", await _check_delete_suppress())
		_case("13 no components, same unit", await _check_refusals())
		_case("14 measure and mass on posed bodies", await _check_inspect())
		_case("16 drive stops at contact", await _check_drive_contact())
		_case("17 play motion stops at contact", await _check_play_contact())
		_case("18 motion study stops at contact", await _check_study_contact())
		_case("19 hover candidates, one per point", await _check_hover_candidates())
		_case("20 play starts from the current value", await _check_play_from_value())
		_case("21 play passes its key times to the sweep", await _check_play_split_times())
		_case("22 values that are not finite are refused", await _check_not_finite())
		_case("23 refused drives and linked limits", await _check_drive_refused())
		_case("24 a contact stop that cannot be checked", await _check_unchecked_stop())
		_case("25 link panel refusals", await _check_link_refusals())
		_case("26 play moves link followers", await _check_play_followers())
		_case("27 play of a rack stops where its drive does", await _check_play_rack())
		_case("28 a key moved onto another key is refused", await _check_key_twice())
		_case("29 play of a follower counts its driver's turn", await _check_play_follower_driver())
		_case("30 play of a gearbox stops where its drive does", await _check_play_gearbox())
		_case("31 a play out of contact time says so", await _check_play_deadline())
		_case("32 the centre of mass readout far out is exact", await _check_mass_far())
		_case("33 play of a joint whose slide follows its turn", await _check_play_helix())
		_case("34 play sentences show the moved values", await _check_play_text())
	else:
		for label in ["2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "16", "17", "18", "19", "20", "21", "22", "23", "24", "25", "26", "27", "28",
				"29", "30", "31", "32", "33", "34"]:
			print("SKIP %s: native library missing" % label)
	_case("15 icons load", _check_icons())
	ws.set_part(null)
	ws.queue_free()
	await process_frame
	print("PASS holo_forge_assembly_tools: all cases" if failures.is_empty() else "FAIL holo_forge_assembly_tools: %d failures" % failures.size())
	quit(0 if failures.is_empty() else 1)


# --- 1 -----------------------------------------------------------------------------------------

func _check_catalog() -> bool:
	var ok := _expect(CATALOG.IMPLEMENTED_PHASE == 8, "IMPLEMENTED_PHASE should be 8 (%d)." % CATALOG.IMPLEMENTED_PHASE)
	var listed := 0
	for workspace in CATALOG.WORKSPACES:
		if not CATALOG.groups(workspace).has("Assemble"):
			continue
		for tool in CATALOG.tools_in(workspace, "Assemble"):
			if int(tool.phase) != 8:
				continue
			listed += 1
			ok = _expect(CATALOG.is_enabled(tool), "%s in %s should be enabled." % [tool.name, workspace]) and ok
	ok = _expect(listed >= ASSEMBLE_TOOLS.size() * 5, "Every workspace with the Assemble group should list the tools (%d)." % listed) and ok
	var flange := CATALOG.find("sheet_metal.create.flange")
	ok = _expect(not flange.is_empty() and not CATALOG.is_enabled(flange), "Flange (Phase 9) should stay greyed.") and ok
	var joint := CATALOG.find("solid.assemble.joint")
	ok = _expect(str(joint.get("type", "")) == "assemble:joint" and str(joint.get("shortcut", "")) == "J", "Joint should run assemble:joint on J (%s)." % [joint]) and ok
	ok = _expect(str(CATALOG.find("solid.assemble.enable_contact_sets").get("action", "")) == "toggle_contact_sets", "Enable Contact Sets is the toggle_contact_sets action.") and ok
	return ok


# --- 2 -----------------------------------------------------------------------------------------

func _check_joint() -> bool:
	var f := F.lever()
	var part := await _start(f)
	var cmd := _tool("solid.assemble.joint")
	var ok := _expect(cmd != null and str(ws.command_values.get("type", "")) == "revolute", "Joint should open with Revolute chosen.")
	if cmd == null:
		return _finish(part, false)
	await _put({
		"a": [cmd.snap_item(F.circle_snap(f, "Lever", Vector3(0, 0, 10), 5.0))],
		"b": [cmd.snap_item(F.circle_snap(f, "Base", Vector3(0, 0, 10), 5.0))],
	})
	ok = _expect(_status() == "", "No refusal with both picks (%s)." % _status()) and ok
	var steps: int = ws.undo_step_count
	ws.accept_command()
	var joints: Array = DATA.normalized(f.doc.assembly).joints
	ok = _expect(ws.command == null and joints.size() == 1, "OK should add one joint (%d)." % joints.size()) and ok
	ok = _expect(str(ws.last_step.get("name", "")) == "Joint" and ws.undo_step_count == steps + 1, "One undo step named Joint (%s)." % ws.last_step.get("name", "")) and ok
	if joints.size() == 1:
		ok = _expect(str(joints[0].type) == "revolute" and str(joints[0].a.component) == str(f.components.Lever) and str(joints[0].b.component) == "", "The Lever moves on the ground.") and ok
	var made: Dictionary = f.doc.assembly.duplicate(true)
	ws._apply_snapshot(part, ws.last_step.before)
	ok = _expect(DATA.normalized(f.doc.assembly).joints.is_empty(), "Undo removes the joint.") and ok
	ws._apply_snapshot(part, ws.last_step.after)
	ok = _expect(f.doc.assembly == made, "Redo brings it back deep-equal.") and ok
	return _finish(part, ok)


# --- 3 -----------------------------------------------------------------------------------------

func _check_cancel() -> bool:
	var f := F.lever()
	var part := await _start(f)
	var lever_body: String = f.bodies.Lever
	var before_assembly: Dictionary = f.doc.assembly.duplicate(true)
	var before_pose: Transform3D = ws.viewport.body_pose(lever_body)
	var cmd := _tool("solid.assemble.joint")
	await _put({
		"a": [cmd.snap_item(F.face_snap(f, "Lever", Vector3(42.5, 0, 20), Vector3(0, 0, 1)))],
		"b": [cmd.snap_item(F.face_snap(f, "Base", Vector3(0, 0, 10), Vector3(0, 0, 1)))],
		"angle": "40 deg",
	})
	var moved: bool = not ws.viewport.body_pose(lever_body).is_equal_approx(before_pose)
	ws.cancel_command()
	var ok := _expect(moved, "The preview should move the Lever.")
	ok = _expect(f.doc.assembly == before_assembly, "Cancel leaves the assembly as it was.") and ok
	ok = _expect(ws.viewport.body_pose(lever_body) == before_pose, "Cancel puts the view pose back.") and ok
	return _finish(part, ok)


# --- 4 -----------------------------------------------------------------------------------------

func _check_as_built() -> bool:
	var f := F.stack()
	var cube: String = f.components.Cube
	var asm: Dictionary = DATA.normalized(f.doc.assembly)
	asm.placements[cube] = XFORM.compose(XFORM.translation(0.01, 0.003, -0.002), XFORM.rot_z(0.4))
	f.doc.assembly = asm
	var part := await _start(f)
	var before: Dictionary = (ws.assembly_solve.body_poses as Dictionary).duplicate(true)
	var cmd := _tool("solid.assemble.as-built_joint")
	if cmd == null:
		return _finish(part, _expect(false, "As-built Joint should open."))
	var top: Dictionary = F.face_snap(f, "Cube", Vector3(50, 50, 60), Vector3(0, 0, 1))
	await _put({
		"a": [cmd.snap_item(top)],
		"b": [cmd.snap_item(F.face_snap(f, "Base", Vector3(50, 50, 10), Vector3(0, 0, 1)))],
		"origin": [cmd.snap_item(top)],
	})
	var ok := _expect(_status() == "", "No refusal (%s)." % _status())
	ws.accept_command()
	var joints: Array = DATA.normalized(f.doc.assembly).joints
	ok = _expect(joints.size() == 1 and bool(joints[0].as_built), "One as-built joint (%d)." % joints.size()) and ok
	ok = _expect(str(ws.last_step.get("name", "")) == "As-built Joint", "Undo name As-built Joint (%s)." % ws.last_step.get("name", "")) and ok
	var after: Dictionary = ws.assembly_solve.body_poses
	for body_id in before:
		ok = _expect(_close(after.get(body_id), before[body_id], 1e-12), "Body %s should not move." % body_id) and ok
	return _finish(part, ok)


# --- 5 -----------------------------------------------------------------------------------------

func _check_origin() -> bool:
	var f := F.stack()
	var part := await _start(f)
	var cmd := _tool("solid.assemble.joint_origin")
	if cmd == null:
		return _finish(part, _expect(false, "Joint Origin should open."))
	await _put({
		"snap": [cmd.snap_item(F.face_snap(f, "Cube", Vector3(50, 50, 40), Vector3(0, 0, -1)))],
		"offset_x": "2 mm", "angle": "15 deg",
	})
	ws.accept_command()
	var origins: Array = DATA.normalized(f.doc.assembly).origins
	var ok := _expect(origins.size() == 1 and str(ws.last_step.get("name", "")) == "Joint Origin", "One origin, undo Joint Origin (%d)." % origins.size())
	if origins.is_empty():
		return _finish(part, ok)
	var origin_id := str(origins[0].id)
	ok = _expect(str(origins[0].component) == str(f.components.Cube), "The origin sits on the Cube.") and ok
	cmd = _tool("solid.assemble.joint")
	await _put({
		"type": "rigid",
		"a": [cmd.origin_item(origin_id)],
		"b": [cmd.snap_item(F.face_snap(f, "Base", Vector3(50, 50, 10), Vector3(0, 0, 1)))],
	})
	ws.accept_command()
	var asm: Dictionary = DATA.normalized(f.doc.assembly)
	ok = _expect(asm.joints.size() == 1 and str(asm.joints[0].a.snap.kind) == "origin", "The joint snaps to the origin.") and ok
	if asm.joints.size() == 1:
		var solved: Dictionary = ws.assembly_solve.joints.get(str(asm.joints[0].id), {})
		var frame: Dictionary = SNAPS.origin_frame(asm.origins[0], ws.result, f.doc, asm)
		ok = _expect(_close(solved.get("frame_a"), frame.frame, 1e-12), "The joint frame is the origin frame.") and ok
	return _finish(part, ok)


# --- 6 -----------------------------------------------------------------------------------------

func _check_rigid_group() -> bool:
	var f := F.gears()
	var part := await _start(f)
	var cmd := _tool("solid.assemble.rigid_group")
	if cmd == null:
		return _finish(part, _expect(false, "Rigid Group should open."))
	await _put({"components": [f.bodies.Gear1]})
	var ok := _expect(_status() == DATA.S_GROUP_SMALL, "One component is refused (%s)." % _status())
	ws.accept_command()
	ok = _expect(ws.command != null, "A refused OK keeps the panel open.") and ok
	await _put({"components": [f.bodies.Gear1, f.bodies.Gear2]})
	ok = _expect(_status() == "", "Two components are fine (%s)." % _status()) and ok
	ws.accept_command()
	var groups: Array = DATA.normalized(f.doc.assembly).rigid_groups
	ok = _expect(groups.size() == 1 and (groups[0].components as Array).size() == 2 and str(ws.last_step.get("name", "")) == "Rigid Group", "One group of two.") and ok
	return _finish(part, ok)


# --- 7 -----------------------------------------------------------------------------------------

func _check_drive() -> bool:
	var f := _limited_lever()
	var part := await _start(f)
	var joint_id := str(DATA.normalized(f.doc.assembly).joints[0].id)
	ws.drive_joint(joint_id)
	var ok := _expect(ws.command != null and str(ws.command_values.get("joint", "")) == joint_id, "Drive opens on the joint.")
	await _put({"dof0_value": "120 deg"})
	var expected := DATA.fill(DATA.S_LIMIT, {"Joint": "Joint1", "limit": "90°", "target": "120°"})
	ok = _expect(_status().contains(expected), "The status row says S-LIMIT (%s)." % _status()) and ok
	ws.accept_command()
	var stored: Dictionary = DATA.normalized(f.doc.assembly).joints[0].dofs[0]
	ok = _expect(float(stored.value) == float(stored.max), "OK stores exactly the max (%s vs %s)." % [stored.value, stored.max]) and ok
	ok = _expect(str(ws.last_step.get("name", "")) == "Drive Joint1", "Undo name Drive Joint1 (%s)." % ws.last_step.get("name", "")) and ok
	return _finish(part, ok)


# --- 8 -----------------------------------------------------------------------------------------

func _check_link() -> bool:
	var f := F.gears()
	var part := await _start(f)
	var j1: String = f.joints.Joint1
	var j2: String = f.joints.Joint2
	var cmd := _tool("solid.assemble.motion_link")
	if cmd == null:
		return _finish(part, _expect(false, "Motion Link should open."))
	var ok := true
	await _put({"driver": j1 + "|0", "follower": j1 + "|0", "ratio": "2"})
	ok = _expect(_status() == DATA.S_LINK_SELF, "A self link is refused (%s)." % _status()) and ok
	await _put({"driver": j1 + "|0", "follower": j2 + "|0", "ratio": "0"})
	ok = _expect(_status() == DATA.S_LINK_ZERO, "Ratio 0 is refused (%s)." % _status()) and ok
	ws.accept_command()
	ok = _expect(ws.command != null, "A refusal blocks OK.") and ok
	await _put({"ratio": "2"})
	ok = _expect(_status() == "", "A 2:1 link is fine (%s)." % _status()) and ok
	ws.accept_command()
	var links: Array = DATA.normalized(f.doc.assembly).links
	ok = _expect(links.size() == 1 and float(links[0].ratio) == 2.0 and str(ws.last_step.get("name", "")) == "Motion Link", "One 2:1 link.") and ok
	_tool("solid.assemble.motion_link")
	await _put({"driver": j1 + "|0", "follower": j2 + "|0", "ratio": "3"})
	ok = _expect(_status() == DATA.fill(DATA.S_LINK_SECOND_DRIVER, {"Joint": "Joint2", "Driver": "Joint1"}), "A second driver is refused (%s)." % _status()) and ok
	await _put({"driver": j2 + "|0", "follower": j1 + "|0", "ratio": "3"})
	ok = _expect(_status() == DATA.fill(DATA.S_LINK_CIRCLE, {"Joint": "Joint1", "Other": "Joint2"}), "A circle is refused (%s)." % _status()) and ok
	ws.accept_command()
	ok = _expect(ws.command != null and DATA.normalized(f.doc.assembly).links.size() == 1, "The refused link is not made.") and ok
	ws.cancel_command()
	return _finish(part, ok)


# --- 9 -----------------------------------------------------------------------------------------

func _check_contact() -> bool:
	var f := F.lever()
	var part := await _start(f)
	var rebuilds: int = ws.rebuild_count
	var steps: int = ws.undo_step_count
	ws.run_tool(CATALOG.find("solid.assemble.enable_contact_sets"))
	var ok := _expect(bool(DATA.normalized(f.doc.assembly).contact.enabled), "The toggle turns contact on.")
	ok = _expect(ws.undo_step_count == steps + 1 and str(ws.last_step.get("name", "")) == "Contact On" and ws.rebuild_count == rebuilds, "One undo step, Contact On, no rebuild.") and ok
	ws.run_action("toggle_contact_sets")
	ok = _expect(not bool(DATA.normalized(f.doc.assembly).contact.enabled) and str(ws.last_step.get("name", "")) == "Contact Off", "And off again.") and ok
	# A browser selection: the Lever component and the Base body.
	ws.component_clicked(f.components.Lever, false)
	ws.browser.body_clicked.emit(f.bodies.Base)
	ws.component_clicked(f.components.Lever, true)
	ws.new_contact_set()
	var sets: Array = DATA.normalized(f.doc.assembly).contact_sets
	ok = _expect(sets.size() == 1 and str(ws.last_step.get("name", "")) == "Contact Set", "New Contact Set makes one set (%d)." % sets.size()) and ok
	if sets.size() == 1:
		ok = _expect((sets[0].members as Array).has({"component": f.components.Lever}) and (sets[0].members as Array).has({"body": f.bodies.Base}),
			"The set holds the Lever and the Base (%s)." % [sets[0].members]) and ok
	ws.open_contact_settings()
	ok = _expect(ws.command != null, "Contact Settings opens.") and ok
	await _put({"step": "0 mm"})
	ok = _expect(_status() != "", "Step 0 is refused.") and ok
	ws.accept_command()
	ok = _expect(ws.command != null, "The refusal blocks OK.") and ok
	await _put({"step": "2 mm"})
	ws.accept_command()
	ok = _expect(ws.command == null and float(DATA.normalized(f.doc.assembly).contact.step) == 0.002, "Step 2 mm is stored.") and ok
	return _finish(part, ok)


# --- 10 ----------------------------------------------------------------------------------------

func _check_study() -> bool:
	var f := _limited_lever()
	var part := await _start(f)
	var joint_id := str(DATA.normalized(f.doc.assembly).joints[0].id)
	ws.open_motion_study()
	var study = ws.motion_study_panel
	var ok := _expect(study != null and study.visible, "The Motion Study panel opens.")
	if study == null:
		return _finish(part, ok)
	var steps: int = ws.undo_step_count
	study.new_study()
	ok = _expect(ws.undo_step_count == steps + 1 and DATA.normalized(f.doc.assembly).studies.size() == 1, "New Study is one undo step.") and ok
	study.add_key(joint_id, 0, 0.0, 0.0)
	study.add_key(joint_id, 0, 2.0, PI * 0.5)
	var asm: Dictionary = DATA.normalized(f.doc.assembly)
	ok = _expect(ws.undo_step_count == steps + 3 and (asm.studies[0].keys as Array).size() == 2, "Each key is one undo step.") and ok
	ok = _expect(str(ws.last_step.get("name", "")) == str(asm.studies[0].name), "Undo is named after the study (%s)." % ws.last_step.get("name", "")) and ok
	var frames: Array = study.frames
	ok = _expect(frames.size() == MOTION.frame_count(asm.studies[0]), "Frames are worked out (%d)." % frames.size()) and ok
	study.seek(1.0)
	var lever_body: String = f.bodies.Lever
	var frame: Dictionary = frames[30] if frames.size() > 30 else {}
	var holder: Node3D = ws.viewport.body_holder(lever_body)
	ok = _expect(holder != null and not frame.is_empty() and holder.transform.is_equal_approx(XFORM.to_transform(frame.body_poses[lever_body])),
		"Seeking 1 s puts the Lever's holder at the 1 s frame.") and ok
	study.close()
	ok = _expect(ws.viewport.body_pose(lever_body).is_equal_approx(XFORM.to_transform(ws.assembly_solve.body_poses[lever_body])), "Closing puts the stored pose back.") and ok
	return _finish(part, ok)


# --- 11 ----------------------------------------------------------------------------------------

func _check_component_actions() -> bool:
	var f := F.stack()
	var part := await _start(f)
	var cube: String = f.components.Cube
	var rebuilds: int = ws.rebuild_count
	ws.ground_component(cube)
	var ok := _expect(DATA.is_grounded(DATA.normalized(f.doc.assembly), cube) and str(ws.last_step.get("name", "")) == "Ground Cube", "Ground (%s)." % ws.last_step.get("name", ""))
	ws.place_component(cube)
	ok = _expect(ws.command == null or _status() == DATA.fill(DATA.S_PLACE_GROUNDED, {"Comp": "Cube"}), "A grounded component is not placed.") and ok
	if ws.command != null:
		ws.cancel_command()
	ws.unground_component(cube)
	ok = _expect(not DATA.is_grounded(DATA.normalized(f.doc.assembly), cube) and str(ws.last_step.get("name", "")) == "Unground Cube", "Unground.") and ok
	ws.place_component(cube)
	ok = _expect(ws.command != null, "Place Component opens.") and ok
	await _put({"move_x": "10 mm"})
	ws.accept_command()
	var placed := DATA.placement(DATA.normalized(f.doc.assembly), cube)
	ok = _expect(absf(placed[9] - 0.01) < 1e-12 and absf(placed[10]) < 1e-12 and str(ws.last_step.get("name", "")) == "Place Cube", "Place moves the Cube 10 mm (%s)." % [placed]) and ok
	# The part's baked Cube node follows the assembly-only change live (no rebuild).
	var cube_node: Node3D = part.component_nodes().get(cube)
	ok = _expect(cube_node != null and absf(cube_node.transform.origin.x - 0.01) < 1e-6, "The baked Cube node follows Place (%s)." % [cube_node.transform.origin if cube_node != null else "no node"]) and ok
	ws.reset_placement(cube)
	ok = _expect(DATA.placement(DATA.normalized(f.doc.assembly), cube) == XFORM.identity() and str(ws.last_step.get("name", "")) == "Reset Placement Cube", "Reset Placement.") and ok
	ok = _expect(cube_node != null and is_instance_valid(cube_node) and cube_node.transform.origin.length() < 1e-6, "The baked Cube node follows Reset Placement.") and ok
	ok = _expect(ws.rebuild_count == rebuilds, "None of those rebuilds (%d)." % (ws.rebuild_count - rebuilds)) and ok
	ws.activate_component(cube)
	rebuilds = ws.rebuild_count
	ws.move_to_active_component(f.bodies.Base)
	ok = _expect(str(f.doc.bodies[f.bodies.Base].component) == cube and str(ws.last_step.get("name", "")) == "Move to Cube", "Move to Active Component.") and ok
	ok = _expect(ws.rebuild_count == rebuilds + 1, "Move to Active Component rebuilds.") and ok
	return _finish(part, ok)


# --- 12 ----------------------------------------------------------------------------------------

func _check_delete_suppress() -> bool:
	var f := F.gears()
	var asm: Dictionary = DATA.normalized(f.doc.assembly)
	MOTION.new_link(asm, {"joint": f.joints.Joint1, "dof": 0}, {"joint": f.joints.Joint2, "dof": 0}, 2.0)
	f.doc.assembly = asm
	var part := await _start(f)
	var steps: int = ws.undo_step_count
	ws.toggle_assembly_suppressed("joints", f.joints.Joint2)
	var ok := _expect(bool(DATA.normalized(f.doc.assembly).joints[1].suppressed) and str(ws.last_step.get("name", "")) == "Suppress Joint2", "Suppress (%s)." % ws.last_step.get("name", ""))
	ws.select_assembly("joints", f.joints.Joint1)
	ws.delete_selection()
	var after: Dictionary = DATA.normalized(f.doc.assembly)
	ok = _expect(after.joints.size() == 1 and after.links.is_empty(), "Delete takes the joint and its link.") and ok
	ok = _expect(ws.undo_step_count == steps + 2 and str(ws.last_step.get("name", "")) == "Delete Joint1", "In one step (%s)." % ws.last_step.get("name", "")) and ok
	ok = _expect(f.doc.bodies.size() == 3, "No body is deleted.") and ok
	return _finish(part, ok)


# --- 13 ----------------------------------------------------------------------------------------

func _check_refusals() -> bool:
	var plain := DOCUMENT.new()
	plain.bodies = {"body1": {"name": "Body1", "visible": true, "locked": false, "feature": "", "component": ""}}
	var part: Node3D = CAD_PART.new()
	part.document = plain
	root.add_child(part)
	ws.set_part(part)
	await process_frame
	_tool("solid.assemble.joint")
	await process_frame
	var ok := _expect(_status() == DATA.S_NO_COMPONENTS, "S-NO-COMPONENTS on opening (%s)." % _status())
	ws.cancel_command()
	ws.set_part(null)
	part.queue_free()
	var f := F.lever()
	part = await _start(f)
	var cmd := _tool("solid.assemble.joint")
	await _put({
		"a": [cmd.snap_item(F.face_snap(f, "Lever", Vector3(42.5, 0, 20), Vector3(0, 0, 1)))],
		"b": [cmd.snap_item(F.face_snap(f, "Lever", Vector3(42.5, 0, 10), Vector3(0, 0, -1)))],
	})
	ok = _expect(_status() == DATA.fill(DATA.S_SAME_UNIT, {"Comp": "Lever"}), "S-SAME-UNIT (%s)." % _status()) and ok
	ws.accept_command()
	ok = _expect(ws.command != null, "It blocks OK.") and ok
	ws.cancel_command()
	return _finish(part, ok)


# --- 14 ----------------------------------------------------------------------------------------

func _check_inspect() -> bool:
	var f := F.lever()
	var angle := deg_to_rad(30.0)
	F.add_joint(f.doc, "revolute", f.components.Lever, F.circle_snap(f, "Lever", Vector3(0, 0, 10), 5.0), "", F.circle_snap(f, "Base", Vector3(0, 0, 10), 5.0),
		{"dofs": [{"value": angle}]})
	var part := await _start(f)
	ws.run_tool(CATALOG.find("solid.inspect.measure"))
	var tip := Vector3(95, -10, 20) * MM
	var corner := Vector3(50, 50, 10) * MM
	await _put({
		"first": [{"kind": "vertex", "body": f.bodies.Lever, "point": tip}],
		"second": [{"kind": "vertex", "body": f.bodies.Base, "point": corner}],
	})
	var measured: Dictionary = ws.command.measured if ws.command != null else {}
	var c := cos(angle)
	var s := sin(angle)
	var posed := Vector3(c * tip.x - s * tip.y, s * tip.x + c * tip.y, tip.z)
	var expected := posed.distance_to(corner)
	var ok := _expect(absf(float(measured.get("distance", -1.0)) - expected) <= 1e-6, "Measure gives the posed distance (%s vs %s)." % [measured.get("distance", "none"), expected])
	ws.cancel_command()
	var plain: Dictionary = INSPECT.mass_properties(f.doc, ws.result, [f.bodies.Lever])
	ws.run_tool(CATALOG.find("solid.inspect.center_of_mass"))
	await _put({"bodies": [f.bodies.Lever]})
	var props: Dictionary = ws.command.props if ws.command != null else {}
	var center: Vector3 = plain.get("center", Vector3.ZERO)
	var want := Vector3(c * center.x - s * center.y, s * center.x + c * center.y, center.z)
	ok = _expect(props.get("center") is Vector3 and (props.center as Vector3).distance_to(want) <= 1e-6, "The centre of mass follows the pose (%s vs %s)." % [props.get("center"), want]) and ok
	ws.cancel_command()
	return _finish(part, ok)


# --- 15 ----------------------------------------------------------------------------------------

func _check_icons() -> bool:
	var ok := true
	for name in ASSEMBLE_TOOLS:
		var path := "res://addons/holo_forge/icons/tools/%s.svg" % CATALOG.slug(name)
		ok = _expect(TOOLBAR.file_icon(path, 24.0, Color.WHITE) != null, "%s should load." % path) and ok
	for name in ICONS_63:
		var path := "res://addons/holo_forge/icons/assemble/%s.svg" % name
		ok = _expect(TOOLBAR.file_icon(path, 24.0, Color.WHITE) != null, "%s should load." % path) and ok
	return ok


# --- Helpers -----------------------------------------------------------------------------------

## lever() with a revolute on the hole circles, limits -30°..90°.
func _limited_lever() -> Dictionary:
	var f := F.lever()
	F.add_joint(f.doc, "revolute", f.components.Lever, F.circle_snap(f, "Lever", Vector3(0, 0, 10), 5.0), "", F.circle_snap(f, "Base", Vector3(0, 0, 10), 5.0),
		{"dofs": [{"value": 0.0, "min": deg_to_rad(-30.0), "max": deg_to_rad(90.0), "limited_min": true, "limited_max": true, "rest": 0.0}]})
	return f


# --- 16 ----------------------------------------------------------------------------------------

## Drive Joints with contact on (slider_wall(): the gap is 10 mm): typing 50 mm stops at the Wall
## with S-CONTACT-STOP in the status row and the Contact row on; OK stores the stop; with contact
## off the same drive goes all the way.
func _check_drive_contact() -> bool:
	var f := F.slider_wall()
	var part := await _start(f)
	var slider: String = f.joints.Slider
	ws.drive_joint(slider)
	var ok := _expect(ws.command != null and str(ws.panel.info("contact")).begins_with("On"), "Drive opens with the Contact row on (%s)." % ws.panel.info("contact"))
	await _put({"dof0_value": "50 mm"})
	ok = _expect(_status().begins_with("Motion stopped at ") and _status().contains("Wall"), "S-CONTACT-STOP in the status row (%s)." % _status()) and ok
	ws.accept_command()
	var value := float(DATA.normalized(f.doc.assembly).joints[0].dofs[0].value)
	ok = _expect(absf(value - 10.0 * MM) < 0.05 * MM, "OK stores the stop near 10 mm (%s m)." % value) and ok
	ws.run_action("toggle_contact_sets")
	ws.drive_joint(slider)
	ok = _expect(str(ws.panel.info("contact")).begins_with("Off"), "The Contact row says Off (%s)." % ws.panel.info("contact")) and ok
	await _put({"dof0_value": "50 mm"})
	ok = _expect(not _status().begins_with("Motion stopped at "), "With contact off nothing stops it (%s)." % _status()) and ok
	ws.accept_command()
	value = float(DATA.normalized(f.doc.assembly).joints[0].dofs[0].value)
	ok = _expect(absf(value - 50.0 * MM) < 1e-12, "And it reaches 50 mm (%s m)." % value) and ok
	return _finish(part, ok)


# --- 17 ----------------------------------------------------------------------------------------

## Play Motion with contact on (lever_stop_contact(): the Lever meets the Stop at about 9.34°):
## the play is swept first and stops there with the sentence in the status row; with contact off
## it plays through.
func _check_play_contact() -> bool:
	var f := F.lever_stop_contact()
	var part := await _start(f)
	ws.drive_joint(f.joints.Lever)
	var cmd = ws.command
	var ok := _expect(cmd != null and cmd.has_method("play_plan"), "Drive opens with Play Motion.")
	if not ok:
		return _finish(part, ok)
	var plan: Dictionary = cmd.play_plan()
	var r := sqrt(60.0 * 60.0 + 20.0 * 20.0)
	var expected := acos(10.0 / r) - atan2(60.0, 20.0)
	var reached := MOTION.track_value(cmd._spread(plan.tracks[0]), float(plan.stop))
	ok = _expect(float(plan.stop) > 0.0 and float(plan.stop) < 0.1 and absf(reached - expected) < deg_to_rad(0.2),
		"The play stops near %s (stop %s, %s)." % [JOINT_MATH.format_angle(expected), plan.stop, JOINT_MATH.format_angle(reached)]) and ok
	ok = _expect(str(plan.sentence).begins_with("Motion stopped at ") and str(plan.sentence).contains("Stop"), "With S-CONTACT-STOP (%s)." % plan.sentence) and ok
	cmd.play()
	var waited := Time.get_ticks_msec()
	var mid_ok := true
	var lever_body: String = f.bodies.Lever
	var stop_pose: Transform3D = XFORM.to_transform(cmd.solve_with(plan.assembly, cmd._play_overrides(plan.joint, plan.tracks, float(plan.stop))).body_poses[lever_body])
	while bool(cmd.get("_playing")) and Time.get_ticks_msec() - waited < 4000:
		await process_frame
		# Past the stop (and before the end), the Lever holds where it stopped.
		var at := float(Time.get_ticks_msec() - waited) / 2000.0
		if at > float(plan.stop) + 0.1 and at < 0.9 and bool(cmd.get("_playing")):
			mid_ok = mid_ok and ws.viewport.body_pose(lever_body).is_equal_approx(stop_pose)
	ok = _expect(not bool(cmd.get("_playing")), "Play Motion ends.") and ok
	ok = _expect(mid_ok, "The Lever holds at the stop while the play runs on.") and ok
	ok = _expect(_status().contains(str(plan.sentence)), "The stop sentence stays in the status row (%s)." % _status()) and ok
	ws.cancel_command()
	ws.run_action("toggle_contact_sets")
	ws.drive_joint(f.joints.Lever)
	plan = ws.command.play_plan()
	ok = _expect(float(plan.stop) == 1.0 and str(plan.sentence) == "", "With contact off it plays through (%s)." % plan.sentence) and ok
	return _finish(part, ok)


# --- 18 ----------------------------------------------------------------------------------------

## A Motion Study with Contact ticked (slider_wall(), the Block keyed 0 -> 50 mm over 2 s): the
## study stops at 0.4 s with S-STUDY-STOP in the panel's status line, every later frame holds the
## stopped pose (the Block about 10 mm along), and the tick is one undo step named after the study.
func _check_study_contact() -> bool:
	var f := F.slider_wall()
	var part := await _start(f)
	var slider: String = f.joints.Slider
	var block_body: String = f.bodies.Block
	ws.open_motion_study()
	var study = ws.motion_study_panel
	var ok := _expect(study != null and study.visible, "The Motion Study panel opens.")
	if study == null:
		return _finish(part, ok)
	study.new_study()
	study.add_key(slider, 0, 0.0, 0.0)
	study.add_key(slider, 0, 2.0, 50.0 * MM)
	ok = _expect(study.stopped_at() < 0.0 and not study.status_text().begins_with("Motion stopped"), "Contact unticked: it plays through (%s)." % study.status_text()) and ok
	var frames: Array = study.frames
	ok = _expect(not frames.is_empty() and absf(float((frames[frames.size() - 1].body_poses[block_body] as PackedFloat64Array)[9]) - 50.0 * MM) < 1e-9, "Through to 50 mm.") and ok
	var steps: int = ws.undo_step_count
	(study.get("_contact") as CheckBox).button_pressed = true
	await process_frame
	var name := str(DATA.normalized(f.doc.assembly).studies[0].name)
	ok = _expect(bool(DATA.normalized(f.doc.assembly).studies[0].contact) and ws.undo_step_count == steps + 1 and str(ws.last_step.get("name", "")) == name,
		"Ticking Contact is one undo step named %s." % name) and ok
	var stop: float = study.stopped_at()
	ok = _expect(absf(stop - 0.4) < 0.01, "The study stops at about 0.4 s (%s)." % stop) and ok
	ok = _expect(study.status_text().begins_with("Motion stopped at ") and study.status_text().contains("Wall"), "S-STUDY-STOP in the panel (%s)." % study.status_text()) and ok
	frames = study.frames
	var last: PackedFloat64Array = frames[frames.size() - 1].body_poses[block_body]
	ok = _expect(absf(last[9] - 10.0 * MM) < 0.05 * MM, "The last frame holds the Block near 10 mm (%s m)." % last[9]) and ok
	var held := true
	for frame in frames:
		if float(frame.time) > stop:
			held = held and _close(frame.body_poses[block_body], last, 0.0)
	ok = _expect(held, "Every frame after the stop holds the stopped pose.") and ok
	study.seek(1.5)
	ok = _expect(ws.viewport.body_pose(block_body).is_equal_approx(XFORM.to_transform(last)), "Seeking past the stop shows the held pose.") and ok
	study.close()
	return _finish(part, ok)


# --- 19 ----------------------------------------------------------------------------------------

## Hovering a face in a snap slot shows its candidates (the view's hit names its face "face"), and
## a face centre on a hole's centre shows once, as the circle centre.
func _check_hover_candidates() -> bool:
	var f := F.lever()
	var part := await _start(f)
	var cmd = _tool("solid.assemble.joint")
	if cmd == null:
		return _finish(part, _expect(false, "Joint should open."))
	var base: String = f.bodies.Base
	var shape: RefCounted = f.result.bodies[base].shape
	var top := -1
	for i in shape.face_count():
		var info: Dictionary = shape.face_info(i)
		if bool(info.get("planar", false)) and (info.normal as Vector3).dot(Vector3(0, 0, 1)) > 0.999 and absf((info.point as Vector3).z - 10.0 * MM) < 1e-7:
			top = i
	var all: Array = SNAPS.candidates(f.result, base, top, f.doc)
	var center := Vector3(0, 0, 10.0 * MM)
	var kinds_at := func(list: Array) -> Array:
		var kinds := []
		for c in list:
			var frame: PackedFloat64Array = c.frame
			if Vector3(frame[9], frame[10], frame[11]).distance_to(center) < 1e-9:
				kinds.append(str(c.kind))
		return kinds
	var ok := _expect(top >= 0 and kinds_at.call(all).has("face_center") and kinds_at.call(all).has("circle_center"), "The Base's top face centre lies on its hole's centre (%s)." % [kinds_at.call(all)])
	var kept: Array = cmd._distinct(all)
	ok = _expect(kinds_at.call(kept) == ["circle_center"], "Only the circle centre stays on that point (%s)." % [kinds_at.call(kept)]) and ok
	var points := {}
	for c in kept:
		var frame: PackedFloat64Array = c.frame
		points[Vector3(frame[9], frame[10], frame[11]).snappedf(1e-9)] = true
	ok = _expect(points.size() == kept.size() and kept.size() < all.size(), "One candidate per point (%d of %d)." % [kept.size(), all.size()]) and ok
	# A hover over the Lever's top face, through the command's own mouse handling.
	var lever_body: String = f.bodies.Lever
	var at: Vector2 = ws.viewport.project(ws.viewport.world_point(lever_body, Vector3(60.0, 0.0, 20.0) * MM))
	var motion := InputEventMouseMotion.new()
	motion.position = at
	cmd.handle_mouse(motion)
	var hovered: Array = cmd.get("_candidates")
	var on_lever := not hovered.is_empty()
	for c in hovered:
		on_lever = on_lever and str(c.ref.get("body", "")) == lever_body
	ok = _expect(on_lever, "Hovering the Lever's top face shows its candidates (%d at %s, hit %s)." % [hovered.size(), at, ws.viewport.face_hit_at(at)]) and ok
	return _finish(part, ok)


# --- 20 ----------------------------------------------------------------------------------------

## lever_stop_contact() with the Lever stored at 90 degrees (clear, past the Stop), limits 0..120:
## Play Motion starts and ends at 90 (no jump through the Stop to the min), goes up to the max first
## and stops on the way down where the arm meets the Stop's far corner (about 60.3 degrees), not at
## the 9.34 degrees reached from the other side. Stored at 30 degrees (inside the Stop) the sweep
## says the overlap is there at the start (S-CONTACT-START), at the user's pose.
func _check_play_from_value() -> bool:
	var f := F.lever_stop_contact()
	_set_lever_dof(f, 90.0)
	var part := await _start(f)
	ws.drive_joint(f.joints.Lever)
	var cmd = ws.command
	var plan: Dictionary = cmd.play_plan() if cmd != null else {}
	if plan.is_empty():
		return _finish(part, _expect(false, "Drive Joints opens with Play Motion."))
	var track: Array = plan.tracks[0]
	var ok := _expect(absf(float(track[0]) - deg_to_rad(90.0)) < 1e-12 and absf(float(track[track.size() - 1]) - deg_to_rad(90.0)) < 1e-12,
		"The play starts and ends at the stored 90 degrees (%s)." % [track.map(func(v: float) -> String: return JOINT_MATH.format_angle(v))]) and true
	ok = _expect(absf(float(track[1]) - deg_to_rad(120.0)) < 1e-12, "It goes to the max first (%s)." % JOINT_MATH.format_angle(float(track[1]))) and ok
	var reached := MOTION.track_value(cmd._spread(track), float(plan.stop))
	# (The arm, 20 mm wide, meets the Stop's corner (40, 50) with its lower edge.)
	var expected := atan2(50.0, 40.0) + asin(10.0 / Vector2(40.0, 50.0).length())
	ok = _expect(float(plan.stop) > 1.0 / 3.0 and float(plan.stop) < 1.0 and absf(reached - expected) < deg_to_rad(0.2) and str(plan.sentence).contains("Stop"),
		"It stops on the way down at the Stop's far corner, %s (%s: %s)." % [JOINT_MATH.format_angle(expected), JOINT_MATH.format_angle(reached), plan.sentence]) and ok
	ok = _expect(not str(plan.sentence).contains("9.3"), "Not where it would stop from the other side (%s)." % plan.sentence) and ok
	_finish(part, true)
	# Inside the Stop at the user's pose.
	var g := F.lever_stop_contact()
	_set_lever_dof(g, 30.0)
	part = await _start(g)
	ws.drive_joint(g.joints.Lever)
	plan = ws.command.play_plan()
	var start := ""
	for warning in plan.get("warnings", PackedStringArray()):
		if str(warning).contains("already overlap at the start"):
			start = str(warning)
	ok = _expect(start != "" and absf(float(plan.tracks[0][0]) - deg_to_rad(30.0)) < 1e-12, "S-CONTACT-START names the overlap at the stored 30 degrees (%s)." % [plan.get("warnings")]) and ok
	return _finish(part, ok)


## Stores the Lever joint's DOF at value_deg with limits 0..120 degrees.
func _set_lever_dof(f: Dictionary, value_deg: float) -> void:
	var a: Dictionary = DATA.normalized(f.doc.assembly)
	for joint in a.joints:
		if str(joint.id) == str(f.joints.Lever):
			joint.dofs[0] = {"value": deg_to_rad(value_deg), "min": 0.0, "max": deg_to_rad(120.0), "limited_min": true, "limited_max": true, "rest": deg_to_rad(value_deg)}
	f.doc.assembly = a


# --- 21 ----------------------------------------------------------------------------------------

## slider_wall() with the Wall at x = 35..45 (15 mm gap), unlimited slider: the play track
## [0, +17.3, -17.3, 0] mm peaks at t = 1/3, between the sweep's even samples. Play Motion passes
## its key times (split_times) and the sweep's turn between them (turn_between), so it stops at
## the Wall.
func _check_play_split_times() -> bool:
	var f := F._start(null)
	F._box(f, "Base", Vector3(-20, -50, 0), Vector3(200, 50, 10), "")
	F._box(f, "Wall", Vector3(35, -30, 0), Vector3(45, 30, 40), "")
	F._box(f, "Block", Vector3(0, -10, 10), Vector3(20, 10, 30), "Block")
	F._rebuild(f)
	var picked := F.face_snap(f, "Block", Vector3(10, 0, 10), Vector3(0, 0, -1))
	f.joints["Slider"] = F.add_as_built(f.doc, f.result, "slider", f.components.Block, picked, "", {"slide_axis": "x"})
	F._contact_set(f, [{"component": f.components.Block}, {"body": f.bodies.Wall}])
	var part := await _start(f)
	ws.drive_joint(f.joints.Slider)
	var plan: Dictionary = ws.command.play_plan()
	var times: PackedFloat64Array = plan.get("split_times", PackedFloat64Array())
	var ok := _expect(times.size() == 4 and absf(times[1] - 1.0 / 3.0) < 1e-12 and absf(times[2] - 2.0 / 3.0) < 1e-12 and times[0] == 0.0 and times[3] == 1.0,
		"The play's key times go to the sweep (%s)." % [times])
	var peak := float(plan.tracks[0][1])
	ok = _expect(peak > 15.0 * MM, "The play's peak passes the Wall (%.3f mm)." % (peak / MM)) and ok
	var reached := MOTION.track_value(ws.command._spread(plan.tracks[0]), float(plan.stop))
	ok = _expect(float(plan.stop) < 1.0 and str(plan.sentence).contains("Wall") and absf(reached - 15.0 * MM) < 0.05 * MM,
		"The play stops at the Wall, about 15 mm (stop %s, %.4f mm: %s)." % [plan.stop, reached / MM, plan.sentence]) and ok
	return _finish(part, ok)


# --- 22 ----------------------------------------------------------------------------------------

## A value that is not a finite number gets a sentence about that value, never a fault: a stored
## NaN joint value, an INF limit, a NaN offset, a NaN link ratio (Drive, Edit Joint, Play Motion),
## and a NaN or INF Motion Study key (added, or stored).
func _check_not_finite() -> bool:
	var ok := true
	# A stored NaN value: Drive refuses, naming it; Play Motion too.
	var f := F.lever_stop_contact()
	_set_lever_dof(f, 0.0)
	var a: Dictionary = DATA.normalized(f.doc.assembly)
	for joint in a.joints:
		if str(joint.id) == str(f.joints.Lever):
			joint.dofs[0]["value"] = NAN
	f.doc.assembly = a
	var part := await _start(f)
	ws.drive_joint(f.joints.Lever)
	ok = _expect(_finite_refusal("Lever"), "Drive with a stored NaN value says so (%s)." % _status()) and ok
	ok = _expect(ws.command != null and ws.command.accept_error() != "", "OK is refused.") and ok
	var plan: Dictionary = ws.command.play_plan() if ws.command != null else {}
	ok = _expect(bool(plan.get("refused", false)) and str(plan.get("sentence", "")).contains("not a finite number"), "Play Motion refuses it (%s)." % plan.get("sentence", "")) and ok
	ws.cancel_command()
	# Edit Joint opens on it: the field says so; a typed value clears it and OK stores a number.
	ws.edit_joint(f.joints.Lever)
	ok = _expect(_status().contains("not a finite number") and not _status().contains("fault"), "Edit Joint shows the NaN field's sentence (%s)." % _status()) and ok
	await _put({"dof0_value": "45 deg"})
	ok = _expect(not _status().contains("not a finite number"), "A typed value clears it (%s)." % _status()) and ok
	ws.accept_command()
	var stored := float(DATA.normalized(f.doc.assembly).joints[0].dofs[0].value)
	ok = _expect(ws.command == null and absf(stored - deg_to_rad(45.0)) < 1e-12, "OK stores 45 degrees (%s)." % stored) and ok
	_finish(part, true)
	# An INF limit and a NaN offset.
	for edit in [["dofs", "max"], ["offset", 0]]:
		var g := F.lever_stop_contact()
		_set_lever_dof(g, 0.0)
		var b: Dictionary = DATA.normalized(g.doc.assembly)
		for joint in b.joints:
			if str(joint.id) == str(g.joints.Lever):
				if edit[0] == "dofs":
					joint.dofs[0]["max"] = INF
				else:
					joint["offset"] = [NAN, 0.0, 0.0]
		g.doc.assembly = b
		part = await _start(g)
		ws.drive_joint(g.joints.Lever)
		ok = _expect(_finite_refusal("Lever"), "Drive with a stored %s says so (%s)." % [edit, _status()]) and ok
		_finish(part, true)
	# A NaN link ratio.
	var h := F.gears()
	var c: Dictionary = DATA.normalized(h.doc.assembly)
	var made := MOTION.new_link(c, {"joint": h.joints.Joint1, "dof": 0}, {"joint": h.joints.Joint2, "dof": 0}, 2.0)
	ok = _expect(made.has("link"), "A link to edit.") and ok
	if made.has("link"):
		(c.links[0] as Dictionary)["ratio"] = NAN
		h.doc.assembly = c
		part = await _start(h)
		ws.drive_joint(h.joints.Joint1)
		ok = _expect(_finite_refusal(str(made.link.name)), "Drive with a stored NaN ratio names the link (%s)." % _status()) and ok
		_finish(part, true)
	# Motion Study keys.
	var s := F.slider_wall()
	part = await _start(s)
	ws.open_motion_study()
	var study = ws.motion_study_panel
	study.new_study()
	var slider: String = s.joints.Slider
	study.add_key(slider, 0, 0.0, NAN)
	study.add_key(slider, 0, INF, 0.0)
	var keys: Array = DATA.normalized(s.doc.assembly).studies[0].keys
	ok = _expect(keys.is_empty() and study.status_text().contains("not a finite number"), "NaN and INF keys are refused (%d keys; %s)." % [keys.size(), study.status_text()]) and ok
	var d: Dictionary = DATA.normalized(s.doc.assembly)
	(d.studies[0] as Dictionary)["keys"] = [{"joint": slider, "dof": 0, "time": 0.0, "value": 0.0}, {"joint": slider, "dof": 0, "time": 1.0, "value": NAN}]
	s.doc.assembly = d
	study.refresh()
	ok = _expect(study.status_text().contains("not a finite number") and not study.status_text().contains("fault") and study.frames.is_empty(),
		"A stored NaN key: the study says so and plays nothing (%s)." % study.status_text()) and ok
	study.close()
	return _finish(part, ok)


# --- 23 ----------------------------------------------------------------------------------------

## A drive MOTION.drive() refuses (here a suppressed joint, S-DRIVE-SUPPRESSED) is the Drive
## panel's refusal (OK off) and moves nothing; Edit Joint refuses limits that its Motion Links
## leave no value for (MOTION.limits_refusal(), S-LIMITS-LINKED-EMPTY): gears(), Joint1 0..90
## degrees driving Joint2 2:1, Joint2's limits edited to 200..300 degrees.
func _check_drive_refused() -> bool:
	var f := F.lever_stop_contact()
	var a: Dictionary = DATA.normalized(f.doc.assembly)
	for joint in a.joints:
		if str(joint.id) == str(f.joints.Lever):
			joint["suppressed"] = true
	f.doc.assembly = a
	var part := await _start(f)
	ws.drive_joint(f.joints.Lever)
	await _put({"dof0_value": "30 deg"})
	var ok := _expect(ws.command != null and _status().contains("is suppressed") and ws.command.accept_error() != "", "Driving a suppressed joint is refused (%s)." % _status())
	var plan: Dictionary = ws.command.play_plan() if ws.command != null else {}
	ok = _expect(bool(plan.get("refused", false)) and float(plan.get("stop", 1.0)) == 0.0 and str(plan.get("sentence", "")).contains("is suppressed"),
		"Play Motion refuses it with the same sentence, playing nothing (%s)." % plan.get("sentence", "")) and ok
	ws.accept_command()
	ok = _expect(float(DATA.normalized(f.doc.assembly).joints[0].dofs[0].value) == 0.0, "Nothing moves.") and ok
	_finish(part, true)
	var g := F.gears()
	var b: Dictionary = DATA.normalized(g.doc.assembly)
	for joint in b.joints:
		if str(joint.id) == str(g.joints.Joint1):
			joint.dofs[0] = {"value": 0.0, "min": 0.0, "max": deg_to_rad(90.0), "limited_min": true, "limited_max": true, "rest": 0.0}
	var made := MOTION.new_link(b, {"joint": g.joints.Joint1, "dof": 0}, {"joint": g.joints.Joint2, "dof": 0}, 2.0)
	g.doc.assembly = b
	part = await _start(g)
	ws.edit_joint(g.joints.Joint2)
	await _put({"dof0_limited_min": true, "dof0_min": "200 deg", "dof0_limited_max": true, "dof0_max": "300 deg", "dof0_rest": "250 deg", "dof0_value": "250 deg"})
	ok = _expect(made.has("link") and ws.command != null and _status().contains("no value that suits") and ws.command.accept_error() != "",
		"Edit Joint refuses limits the link leaves no value for (%s)." % _status()) and ok
	return _finish(part, ok)


# --- 24 ----------------------------------------------------------------------------------------

## S-CONTACT-UNCHECKED shows like any contact stop: slider_wall() with the Block's shape swapped (in
## the workspace's result) for two crossing 20 mm cubes in one mesh (x -10..20 mm), which overlap()
## cannot check where they meet the Wall (x 30 mm). Play Motion stops there and keeps the sentence
## in the status row, Drive Joints stops there as a note (OK stores the stop), and a Motion Study
## with Contact stops with it in the panel.
func _check_unchecked_stop() -> bool:
	var twin: RefCounted = MESH_FIX.to_mesh(MESH_FIX.two_cubes(Vector3(10, 0, 0) * MM))
	if twin == null:
		print("SKIP 24: no CadMesh")
		return true
	var f := F.slider_wall()
	var part := await _start(f)
	var block: String = f.bodies.Block
	var slider: String = f.joints.Slider
	var swap := func() -> void: (ws.result.bodies[block] as Dictionary)["shape"] = twin
	swap.call()
	ws.drive_joint(slider)
	var cmd = ws.command
	var plan: Dictionary = cmd.play_plan()
	var unchecked := func(text: String) -> bool: return text.contains("could not be checked") and not text.contains("fault")
	var ok := _expect(float(plan.stop) < 1.0 and not bool(plan.refused) and unchecked.call(str(plan.sentence)), "Play Motion stops with S-CONTACT-UNCHECKED (stop %s: %s)." % [plan.stop, plan.sentence])
	cmd.play()
	var waited := Time.get_ticks_msec()
	while bool(cmd.get("_playing")) and Time.get_ticks_msec() - waited < 4000:
		await process_frame
	ok = _expect(unchecked.call(_status()), "The sentence stays in the status row after the play (%s)." % _status()) and ok
	await _put({"dof0_value": "50 mm"})
	ok = _expect(unchecked.call(_status()) and cmd.accept_error() == "", "Drive Joints stops there as a note, OK on (%s)." % _status()) and ok
	ws.cancel_command()
	# A study with Contact ticked, keyed 0 -> 50 mm over 2 s.
	var a: Dictionary = DATA.normalized(f.doc.assembly)
	var study := DATA.STUDY_DEFAULT.duplicate(true)
	study["id"] = DATA.new_id(a, "study")
	study["name"] = "Unchecked"
	study["contact"] = true
	study["keys"] = [{"joint": slider, "dof": 0, "time": 0.0, "value": 0.0}, {"joint": slider, "dof": 0, "time": 2.0, "value": 50.0 * MM}]
	(a.studies as Array).append(study)
	f.doc.assembly = a
	swap.call()
	ws.open_motion_study()
	var panel = ws.motion_study_panel
	panel.study_id = str(study.id)
	swap.call()
	panel.refresh()
	ok = _expect(panel.stopped_at() >= 0.0 and unchecked.call(panel.status_text()), "The study stops with it in the panel (%s: %s)." % [panel.stopped_at(), panel.status_text()]) and ok
	panel.close()
	return _finish(part, ok)


# --- 25 ----------------------------------------------------------------------------------------

## The Motion Link panel shows link_refusal()'s new sentences. S-LINK-EMPTY-NEW: a new link captured
## at the stored pose always leaves that pose, so it needs a hand-edited tree that already has no
## value: gears() with Joint2 made cylindrical, a stored link Joint1 (0..90 degrees) -> Joint2's
## slide (2000..3000 mm) at ratio 1, offset 0; a new link from Joint2's turn to Joint1 then leaves its
## tree no value. S-RATIO-NOT-FINITE: a ratio that is not finite (only code can give one), with
## OK refused.
func _check_link_refusals() -> bool:
	var f := F.gears()
	var j1: String = f.joints.Joint1
	var j2: String = f.joints.Joint2
	var a: Dictionary = DATA.normalized(f.doc.assembly)
	for joint in a.joints:
		if str(joint.id) == j1:
			joint.dofs[0] = {"value": 0.0, "min": 0.0, "max": deg_to_rad(90.0), "limited_min": true, "limited_max": true, "rest": 0.0}
		elif str(joint.id) == j2:
			joint["type"] = "cylindrical"
			joint["dofs"] = [
				# (2..3 in base units, beyond Joint1's 0..1.571 rad at ratio 1.)
				{"value": 2000.0 * MM, "min": 2000.0 * MM, "max": 3000.0 * MM, "limited_min": true, "limited_max": true, "rest": 2000.0 * MM},
				{"value": 0.0, "min": 0.0, "max": 0.0, "limited_min": false, "limited_max": false, "rest": 0.0},
			]
	var link: Dictionary = DATA.LINK_DEFAULT.duplicate(true)
	link["id"] = DATA.new_id(a, "link")
	link["name"] = DATA.name_for("link", str(link.id))
	link["driver"] = {"joint": j1, "dof": 0}
	link["follower"] = {"joint": j2, "dof": 0}
	link["ratio"] = 1.0
	link["offset"] = 0.0
	(a.links as Array).append(link)
	f.doc.assembly = a
	var part := await _start(f)
	var cmd = _tool("solid.assemble.motion_link")
	if cmd == null:
		return _finish(part, _expect(false, "Motion Link should open."))
	await _put({"driver": j2 + "|1", "follower": j1 + "|0", "ratio": "2"})
	var ok := _expect(_status().begins_with("That link would leave") and cmd.accept_error() != "", "S-LINK-EMPTY-NEW in the panel, OK refused (%s)." % _status())
	# A ratio that is not finite, as code can give it (the field remembers the double behind its text).
	await _put({"driver": j1 + "|0", "follower": j2 + "|1", "ratio": "2"})
	cmd.remember(ws.command_values, "ratio", NAN, "number")
	cmd.current_values = ws.command_values.duplicate(true)
	cmd.update()
	ok = _expect(_status() == DATA.S_RATIO_NOT_FINITE and cmd.accept_error() != "", "A NaN ratio gets S-RATIO-NOT-FINITE, not read as 0 (%s)." % _status()) and ok
	return _finish(part, ok)


# --- 26 ----------------------------------------------------------------------------------------

## Play Motion moves Motion Link followers as a drive does: lever_stop_linked() (Knob -> Lever 1:1).
## Playing the Knob, the Lever turns with it, exactly, in the view; with contact on the play stops
## where the Lever meets the Stop (the Knob at about 9.34 degrees), as the drive does.
func _check_play_followers() -> bool:
	var f := F.lever_stop_linked()
	var part := await _start(f)
	var lever_body: String = f.bodies.Lever
	var knob_body: String = f.bodies.Knob
	var rest: Dictionary = (ws.assembly_solve.body_poses as Dictionary).duplicate(true)
	ws.drive_joint(f.joints.Knob)
	var cmd = ws.command
	var plan: Dictionary = cmd.play_plan()
	var r := sqrt(60.0 * 60.0 + 20.0 * 20.0)
	var expected := acos(10.0 / r) - atan2(60.0, 20.0)
	var reached := MOTION.track_value(cmd._spread(plan.tracks[0]), float(plan.stop))
	var driven := MOTION.drive(f.doc, f.result, ws.kernel, f.joints.Knob, 0, deg_to_rad(30.0))
	var ok := _expect(float(plan.stop) < 1.0 and absf(reached - expected) < deg_to_rad(0.2) and str(plan.sentence).contains("Stop"),
		"Playing the Knob stops where the Lever meets the Stop, %s (%s: %s; a drive: %s)." % [JOINT_MATH.format_angle(expected), JOINT_MATH.format_angle(reached), plan.sentence, driven.sentence])
	cmd.play()
	var waited := Time.get_ticks_msec()
	var checked := 0
	var worst := 0.0
	while bool(cmd.get("_playing")) and Time.get_ticks_msec() - waited < 4000:
		await process_frame
		var knob_turn := XFORM.angle_between(rest[knob_body], XFORM.from_transform(ws.viewport.body_pose(knob_body)))
		var lever_turn := XFORM.angle_between(rest[lever_body], XFORM.from_transform(ws.viewport.body_pose(lever_body)))
		if knob_turn > deg_to_rad(1.0):
			checked += 1
			worst = maxf(worst, absf(knob_turn - lever_turn))
	ok = _expect(checked > 0 and worst < 1e-5, "In the Play view the Lever turns with the Knob, 1:1 (%d frames, worst %s rad apart)." % [checked, worst]) and ok
	# Contact off: a whole turn, the Lever still with it.
	ws.cancel_command()
	ws.run_action("toggle_contact_sets")
	ws.drive_joint(f.joints.Knob)
	cmd = ws.command
	plan = cmd.play_plan()
	var at := cmd.solve_with(plan.assembly, cmd._play_overrides(plan.joint, plan.tracks, 0.25, plan.assembly)) as Dictionary
	var turned := XFORM.angle_between(rest[lever_body], at.body_poses[lever_body])
	ok = _expect(float(plan.stop) == 1.0 and absf(turned - PI) < 1e-6, "Contact off, at a quarter of the play (Knob 180 degrees) the Lever is at 180 degrees too (%s)." % JOINT_MATH.format_angle(turned)) and ok
	return _finish(part, ok)


# --- 27 ----------------------------------------------------------------------------------------

## A slide that drives a turn: lever_stop_contact() plus a 10 mm Rack on an as-built slider along
## X, linked Rack -> Lever at 1,000 rad/m. Playing the Rack stops where a drive of it does (the
## Lever meets the Stop at Rack 0.164 mm); at 100,000 rad/m the drive refuses (too many contact
## steps), and so does the play, with a sentence.
func _check_play_rack() -> bool:
	var ok := true
	for ratio in [1000.0, 100000.0]:
		var f := F.lever_stop_contact()
		F._box(f, "Rack", Vector3(-45, -45, 10), Vector3(-35, -35, 20), "Rack")
		F._rebuild(f)
		var world := XFORM.frame(PackedFloat64Array([-40.0 * MM, -40.0 * MM, 10.0 * MM]), PackedFloat64Array([0.0, 0.0, 1.0]))
		var rack := F.add_as_built_frame(f.doc, "slider", f.components.Rack, "", world, {"slide_axis": "x"})
		var a: Dictionary = DATA.normalized(f.doc.assembly)
		MOTION.new_link(a, {"joint": rack, "dof": 0}, {"joint": f.joints.Lever, "dof": 0}, ratio)
		f.doc.assembly = a
		var part := await _start(f)
		var driven := MOTION.drive(f.doc, f.result, ws.kernel, rack, 0, 0.5 * MM)
		ws.drive_joint(rack)
		var plan: Dictionary = ws.command.play_plan()
		var reached := MOTION.track_value(ws.command._spread(plan.tracks[0]), float(plan.stop))
		if ratio == 1000.0:
			ok = _expect(not bool(driven.refused) and float(plan.stop) < 1.0 and absf(reached - float(driven.reached)) < 0.001 * MM and str(plan.sentence).contains("Stop"),
				"Rack at 1,000 rad/m: the play stops where the drive does (%.5f mm against %.5f mm: %s; tracks %s)." % [reached / MM, float(driven.reached) / MM, plan.sentence, plan.tracks]) and ok
		else:
			ok = _expect(bool(driven.refused) and bool(plan.refused) and float(plan.stop) == 0.0 and str(plan.sentence) != "",
				"Rack at 100,000 rad/m: the drive refuses (%s) and so does the play (%s)." % [driven.sentence, plan.sentence]) and ok
		_finish(part, true)
	return ok


# --- 28 ----------------------------------------------------------------------------------------

## Motion Study: moving a key onto another key of the same DOF is refused with S-STUDY-KEY-TWICE
## (a motion cannot jump), as MOTION.study_refusal() words it; the keys stay, no undo step is
## added, and the study still plays. A move to a free time still works.
func _check_key_twice() -> bool:
	var ok := true
	var s := F.slider_wall()
	var part := await _start(s)
	ws.open_motion_study()
	var study = ws.motion_study_panel
	study.new_study()
	var slider: String = s.joints.Slider
	study.add_key(slider, 0, 0.0, 0.0)
	study.add_key(slider, 0, 1.0, 10.0 * MM)
	study.add_key(slider, 0, 2.0, 20.0 * MM)
	var steps: int = ws.undo_step_count
	study.move_key(slider, 0, 1.0, 2.0)
	var times := []
	for key in DATA.normalized(s.doc.assembly).studies[0].keys:
		times.append(float(key.time))
	times.sort()
	ok = _expect(times == [0.0, 1.0, 2.0] and ws.undo_step_count == steps and study.status_text().contains("two keys at") and not study.status_text().contains("fault"),
		"A key moved onto another is refused (times %s; %s)." % [times, study.status_text()]) and ok
	study.refresh()
	ok = _expect(not study.frames.is_empty(), "The study still plays (%d frames)." % study.frames.size()) and ok
	study.move_key(slider, 0, 1.0, 1.5)
	times = []
	for key in DATA.normalized(s.doc.assembly).studies[0].keys:
		times.append(float(key.time))
	times.sort()
	ok = _expect(times == [0.0, 1.5, 2.0] and not study.status_text().contains("two keys at"), "A move to a free time works (times %s; %s)." % [times, study.status_text()]) and ok
	study.close()
	return _finish(part, ok)


# --- 29 ----------------------------------------------------------------------------------------

## Play of a Motion Link follower whose driver touches: lever_stop_contact() plus a Knob cube on an
## as-built revolute at (-40, -40), linked Lever -> Knob at 0.0001 (the Lever turns 10,000 times
## the Knob), Knob limited 0..0.2 rad, Step 2.4 mm. Playing the Knob turns the Lever through the
## Stop unless the Lever's turn is counted: the play stops where the Lever first touches (Knob
## about 0.000934 degrees) or is refused as the drive is (S-CONTACT-TURNS), never further on.
func _check_play_follower_driver() -> bool:
	var f := F.lever_stop_contact()
	_box_joint(f, "Knob", Vector2(-40, -40))
	_link(f, f.joints.Lever, f.joints.Knob, 0.0001)
	_limits(f, f.joints.Knob, 0, 0.0, 0.2, 0.0)
	var a: Dictionary = DATA.normalized(f.doc.assembly)
	a.contact["step"] = 2.4 * MM
	f.doc.assembly = a
	var part := await _start(f)
	var driven := MOTION.drive(f.doc, f.result, ws.kernel, f.joints.Knob, 0, 0.2)
	ws.drive_joint(f.joints.Knob)
	var plan: Dictionary = ws.command.play_plan()
	var r := sqrt(60.0 * 60.0 + 20.0 * 20.0)
	var expected := (acos(10.0 / r) - atan2(60.0, 20.0)) * 0.0001
	var knob := MOTION.track_value(ws.command._spread(plan.tracks[0]), float(plan.stop))
	var refused_too := bool(driven.refused) and bool(plan.refused) and str(plan.sentence) != ""
	var stops_there := float(plan.stop) < 1.0 and not bool(plan.refused) and absf(knob - expected) <= 0.02 * expected
	var ok := _expect(refused_too or stops_there, "Playing the Knob stops near %s or is refused like the drive (play: Knob %s, refused %s: %s; drive: refused %s: %s)." % [
		JOINT_MATH.format_angle(expected), JOINT_MATH.format_angle(knob), plan.refused, plan.sentence, driven.refused, driven.sentence])
	return _finish(part, ok)


# --- 30 ----------------------------------------------------------------------------------------

## A gearbox: lever_stop_linked() at ratio 0.02 (the Knob, in no contact set, turns 50 times the
## Lever), Knob limited 0..30 turns. A play turns the Knob up to 30 times, but only the Lever's
## turn counts for contact: it stops where the drive does (about 469.97 degrees), not refused.
func _check_play_gearbox() -> bool:
	var f := F.lever_stop_linked()
	var a: Dictionary = DATA.normalized(f.doc.assembly)
	a.links[0]["ratio"] = 0.02
	f.doc.assembly = a
	_limits(f, f.joints.Knob, 0, 0.0, TAU * 30.0, 0.0)
	var part := await _start(f)
	var driven := MOTION.drive(f.doc, f.result, ws.kernel, f.joints.Knob, 0, TAU * 30.0)
	ws.drive_joint(f.joints.Knob)
	var plan: Dictionary = ws.command.play_plan()
	var knob := MOTION.track_value(ws.command._spread(plan.tracks[0]), float(plan.stop))
	var ok := _expect(not bool(driven.refused) and not bool(plan.refused) and float(plan.stop) < 1.0 and absf(knob - float(driven.reached)) < deg_to_rad(0.1) and str(plan.sentence).contains("Stop"),
		"The gearbox play stops where the drive does (play %s: %s; drive %s: %s)." % [JOINT_MATH.format_angle(knob), plan.sentence, JOINT_MATH.format_angle(float(driven.reached)), driven.sentence])
	return _finish(part, ok)


# --- 31 ----------------------------------------------------------------------------------------

## The play's shared contact deadline: pin_hole() limited 0..6 turns (slow round pairs; each leg
## takes seconds). When the time left is too short for a leg, the sentence says that Play Motion
## ran out of its contact time and the play stops where the checked part ended; it never quotes a
## leg's own estimate under the limit as the reason ("would take about 2.1 s").
func _check_play_deadline() -> bool:
	var f := F.pin_hole()
	_limits(f, f.joints.Joint1, 0, 0.0, TAU * 6.0, 0.0)
	CONTACT.clear_cache()
	var part := await _start(f)
	ws.drive_joint(f.joints.Joint1)
	var started := Time.get_ticks_msec()
	var plan: Dictionary = ws.command.play_plan()
	var ms := Time.get_ticks_msec() - started
	var sentence := str(plan.sentence)
	var quoted := RegEx.create_from_string("^Checking contact for this motion would take about ([0-9.]+) s").search(sentence)
	var false_time := quoted != null and float(quoted.get_string(1)) <= MOTION.CONTACT_SECONDS
	var ran_out := sentence.contains("Play Motion ran out of its")
	var ok := _expect(not false_time and (not ran_out or (not bool(plan.refused) and float(plan.stop) > 0.0)),
		"No leg refusal quotes a time under the limit, and running out stops where the checked part ended (%d ms; stop %s, refused %s: %s)." % [ms, plan.stop, plan.refused, sentence])
	print("  (31: the pin play took %d ms; stop %s, refused %s: %s)" % [ms, plan.stop, plan.refused, sentence])
	# The rule itself, without the clock: a later leg refused for time within the budget ran out of
	# the play's time; the first leg, a leg too slow on its own and a steps refusal stay refusals.
	var cmd = ws.command
	var slow := {"refused": true, "estimate": 2.1, "sentence": "Checking contact for this motion would take about 2.1 s (432 steps × 1 pairs)."}
	var said: String = cmd._out_of_time(slow, 2, 5.0, 1.4, "2160°")
	ok = _expect(said.begins_with("Play Motion ran out of its 5 s of contact checking after 2160°") and said.contains("about 2.1 s") and said.contains("more than the 1.4 s left"),
		"A later leg cut short by the play's deadline says so (%s)." % said) and ok
	# (NP2: two figures that round alike never read as "2.1 s, and 2.1 s was left".)
	var close: String = cmd._out_of_time({"refused": true, "estimate": 2.14}, 2, 5.0, 2.11, "x")
	ok = _expect(close.contains("about 2.14 s, more than the 2.11 s left"), "Close figures are told apart (%s)." % close) and ok
	var again := {"refused": true, "estimate": 0.5, "estimate_again": 3.2}
	ok = _expect(str(cmd._out_of_time(again, 3, 5.0, 1.0, "x")).contains("about 3.2 s"), "The estimate made again counts (%s)." % cmd._out_of_time(again, 3, 5.0, 1.0, "x")) and ok
	ok = _expect(cmd._out_of_time(slow, 1, 5.0, 5.0, "x") == "" and cmd._out_of_time({"refused": true, "estimate": 6.0}, 2, 5.0, 1.0, "x") == ""
		and cmd._out_of_time({"refused": true}, 2, 5.0, 1.0, "x") == "" and cmd._out_of_time({"stopped": true, "estimate": 1.0}, 2, 5.0, 1.0, "x") == "",
		"The first leg, a leg too slow on its own, a steps refusal and a stop are left as they are.") and ok
	return _finish(part, ok)


# --- 32 ----------------------------------------------------------------------------------------

## Center of Mass far out: a box whose centre lies halfway between two float32 values (100 km out
## on Y, 7.8125 mm tall: centre 100,000.00390625 m), and one 1 km out. The readout shows the double
## centre (center64), so at 100 km, where it shows whole mm, it is within rounding of the truth.
func _check_mass_far() -> bool:
	var ok := true
	for spec in [[1000.0, 10.0], [100000.0, 7.8125]]:
		var base_m: float = spec[0]
		var tall_mm: float = spec[1]
		var f := F._start(null)
		var doc: Resource = f.doc
		var feature: Resource = doc.add_feature("box", "Box", {
			"length": doc.make_input(F._mm(10.0), "length"), "height": doc.make_input(F._mm(tall_mm), "length"), "width": doc.make_input(F._mm(10.0), "length"),
		}, {"position": Vector3(0.0, base_m, 0.0), "operation": OPERATIONS.NEW_BODY})
		F._register(f, feature, "Block", "")
		F._rebuild(f)
		var truth := PackedFloat64Array([0.0, base_m + tall_mm * 0.5 * MM, 0.0])
		var part := await _start(f)
		ws.run_tool(CATALOG.find("solid.inspect.center_of_mass"))
		await _put({"bodies": [f.bodies.Block]})
		var props: Dictionary = ws.command.props if ws.command != null else {}
		var c64: PackedFloat64Array = props.get("center64", PackedFloat64Array([NAN, NAN, NAN]))
		var text: String = ws.command.describe(props) if ws.command != null else ""
		var found := RegEx.create_from_string("Center: \\(([-0-9.e]+), ([-0-9.e]+), ([-0-9.e]+)\\) mm").search(text)
		var shown_y := float(found.get_string(2)) if found != null else NAN
		ok = _expect(absf(c64[1] - truth[1]) <= 1e-7 and absf(shown_y - truth[1] / MM) <= 0.5 + 1e-6,
			"%s km out: center64 y %s m (truth %s), the readout shows %s mm (truth %s mm)." % [base_m / 1000.0, String.num(c64[1], 9), String.num(truth[1], 9), shown_y, String.num(truth[1] / MM, 5)]) and ok
		ws.cancel_command()
		_finish(part, true)
	return ok


# --- 33 ----------------------------------------------------------------------------------------

## A two-DOF joint whose slide follows its own rotation (helix_lever(4.0), Motion Link Cyl rot ->
## Cyl slide at p mm per turn): nothing touches on the play's path, so Play runs to the end, not
## refused and not out of time, in about a drive's time (the slide's own track never takes
## effect, so it adds no turning).
func _check_play_helix() -> bool:
	var ok := true
	for p in [0.2, 2.0, 20.0]:
		var f := F.helix_lever(4.0)
		var a: Dictionary = DATA.normalized(f.doc.assembly)
		MOTION.new_link(a, {"joint": f.joints.Cyl, "dof": 1}, {"joint": f.joints.Cyl, "dof": 0}, p * MM / TAU)
		f.doc.assembly = a
		var part := await _start(f)
		var started := Time.get_ticks_msec()
		var driven := MOTION.drive(f.doc, f.result, ws.kernel, f.joints.Cyl, 1, TAU)
		var drive_ms := Time.get_ticks_msec() - started
		ws.drive_joint(f.joints.Cyl)
		started = Time.get_ticks_msec()
		var plan: Dictionary = ws.command.play_plan()
		var play_ms := Time.get_ticks_msec() - started
		print("  (33: %s mm/turn: drive %d ms, play %d ms)" % [p, drive_ms, play_ms])
		ok = _expect(not bool(driven.refused) and not bool(plan.refused) and float(plan.stop) == 1.0 and str(plan.sentence) == "" and play_ms < 1500,
			"%s mm/turn: the play runs to the end in about a drive's time (drive %d ms: %s; play %d ms, stop %s, refused %s: %s)." % [
				p, drive_ms, driven.sentence, play_ms, plan.stop, plan.refused, plan.sentence]) and ok
		_finish(part, true)
	return ok


# --- 34 ----------------------------------------------------------------------------------------

## A play's sentences give the joint's values as the play moves them (the moved values, not the
## raw tracks): helix_lever with the slide following the rotation at 2 mm per turn, at t = 2/3
## of the play the rotation is at 240° and the slide at 1.3333 mm.
func _check_play_text() -> bool:
	var f := F.helix_lever(4.0)
	var a: Dictionary = DATA.normalized(f.doc.assembly)
	var ratio := 2.0 * MM / TAU
	MOTION.new_link(a, {"joint": f.joints.Cyl, "dof": 1}, {"joint": f.joints.Cyl, "dof": 0}, ratio)
	f.doc.assembly = a
	var part := await _start(f)
	ws.drive_joint(f.joints.Cyl)
	var cmd = ws.command
	var plan: Dictionary = cmd.play_plan()
	var t := 2.0 / 3.0
	var rot := MOTION.track_value(cmd._spread(plan.tracks[1]), t)
	var slide := ratio * rot
	var want := "%s, %s" % [JOINT_MATH.format_dof("cylindrical", 0, slide, "mm"), JOINT_MATH.format_dof("cylindrical", 1, rot, "mm")]
	var text: String = cmd._play_text(plan.joint, plan.tracks, t, "mm", plan.assembly)
	var ok := _expect(text == want and absf(rot - deg_to_rad(240.0)) < 1e-9, "The text at t = 2/3 shows the moved values %s (%s)." % [want, text])
	return _finish(part, ok)


## A 10 mm cube component Name on an as-built revolute about Z at (at.x, at.y, 10) mm.
func _box_joint(f: Dictionary, name: String, at: Vector2) -> String:
	F._box(f, name, Vector3(at.x - 5, at.y - 5, 10), Vector3(at.x + 5, at.y + 5, 20), name)
	F._rebuild(f)
	var world := XFORM.frame(PackedFloat64Array([at.x * MM, at.y * MM, 10.0 * MM]), PackedFloat64Array([0.0, 0.0, 1.0]))
	var id := F.add_as_built_frame(f.doc, "revolute", f.components[name], "", world)
	F._rename_joint(f.doc, id, name)
	f.joints[name] = id
	return id


## A Motion Link driver -> follower at ratio (MOTION.new_link) stored in the document.
func _link(f: Dictionary, driver: String, follower: String, ratio: float) -> void:
	var a: Dictionary = DATA.normalized(f.doc.assembly)
	MOTION.new_link(a, {"joint": driver, "dof": 0}, {"joint": follower, "dof": 0}, ratio)
	f.doc.assembly = a


## A joint DOF limited lo..hi at value (base units), stored in the document.
func _limits(f: Dictionary, joint_id: String, dof: int, lo: float, hi: float, value: float) -> void:
	var a: Dictionary = DATA.normalized(f.doc.assembly)
	for joint in a.joints:
		if str(joint.id) == joint_id:
			joint.dofs[dof] = {"value": value, "min": lo, "max": hi, "limited_min": true, "limited_max": true, "rest": 0.0}
	f.doc.assembly = a


## The status row refuses with a sentence about a value that is not a finite number, naming item,
## and no fault.
func _finite_refusal(item: String) -> bool:
	var text := _status()
	return ws.command != null and text.contains("not a finite number") and text.contains(item) and not text.contains("fault")


func _start(f: Dictionary) -> Node3D:
	var part: Node3D = CAD_PART.new()
	part.document = f.doc
	root.add_child(part)
	ws.set_part(part)
	await process_frame
	return part


func _finish(part: Node3D, ok: bool) -> bool:
	if ws.command != null:
		ws.cancel_command()
	if ws.get("motion_study_panel") != null and ws.motion_study_panel.visible:
		ws.motion_study_panel.close()
	ws.set_part(null)
	part.queue_free()
	return ok


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


func _status() -> String:
	return ws.panel.info("status")


func _close(a: Variant, b: Variant, tolerance: float) -> bool:
	if not (a is PackedFloat64Array and b is PackedFloat64Array) or (a as PackedFloat64Array).size() != 12 or (b as PackedFloat64Array).size() != 12:
		return false
	for i in 12:
		if absf(float(a[i]) - float(b[i])) > tolerance:
			return false
	return true


func _case(label: String, passed: bool) -> void:
	print(("PASS " if passed else "FAIL ") + label)


func _expect(ok: bool, detail: String) -> bool:
	if not ok:
		failures.append(detail)
		print("  - " + detail)
	return ok
