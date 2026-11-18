extends SceneTree
## Holo Forge Phase 8, Stage 1, team V (spec 5.4): the posed view, picking, the modelled view, the
## browser's assembly folders, the glyphs and the theme tokens.
##
## 1. set_body_poses with a hand-made solve output: each holder's transform is to_transform(pose)
##    exactly.
## 2. A ray at the posed Lever tip face gives the modelled point (1e-6 m) and a world_point at the
##    posed point (1e-6 m), through the viewport's pick_at and through PICKING.ray_hit.
## 3. A feature command shows modelled positions (every holder identity, S-MODELLED-VIEW in the
##    status line); closing it re-poses exactly. An inspect command keeps the posed view.
## 4. A section analysis (its cap, its clip plane) and a decal on the Lever follow the pose.
## 5. Browser: the Joints folder lists joints with type icons and state badges; empty assembly
##    folders are hidden; the ground button (BUTTON_GROUND = 3) is on top-level components only.
## 6. Glyphs: one badge per visible joint, none for visible: false, dimmed for suppressed; snap
##    candidate glyphs for one face, the hovered one bigger.
## 7. Theme: every 6.1 token in both palettes; line tokens read on the view.
## 8. Timing (5.9): set_body_poses with 200 bodies against the 200k-iteration loop.
## 9. DOF handles: rings for rotations, two-way arrows for slides, placed on the joint frame.
## 10. recompute() re-solves the assembly (spec 10.1 #7).
##
## Timing measured 2026-11-13 (dev machine, alone): see TIMING_RATIO_LIMIT.
##
## godot --headless --path . --script res://tests/holo_forge_assembly_view_test.gd

const XFORM := preload("res://addons/holo_forge/core/assembly/xform64.gd")
const DATA := preload("res://addons/holo_forge/core/assembly/assembly_data.gd")
const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const WORKSPACE := preload("res://addons/holo_forge/ui/forge_workspace.gd")
const VIEWPORT := preload("res://addons/holo_forge/ui/forge_viewport.gd")
const BROWSER := preload("res://addons/holo_forge/ui/browser.gd")
const THEME := preload("res://addons/holo_forge/ui/forge_theme.gd")
const PICKING := preload("res://addons/holo_forge/core/picking.gd")
const TESSELLATE := preload("res://addons/holo_forge/core/tessellate.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const APPEARANCE := preload("res://addons/holo_forge/core/appearance.gd")
const CATALOG := preload("res://addons/holo_forge/tools/catalog.gd")
const TIMING := preload("res://tests/holo_forge_timing.gd")
const DISPLAY_PATH := "res://addons/holo_forge/ui/assembly_display.gd"
const ASSEMBLY_UI_PATH := "res://addons/holo_forge/ui/assembly_ui.gd"

## The 6.1 tokens.
const TOKENS := [
	"assembly_joint", "assembly_joint_selected", "assembly_limit", "assembly_warning", "assembly_unresolved",
	"assembly_ground", "assembly_contact", "assembly_ghost",
]
## Tokens drawn as thin lines or marks straight on the view (the theme test's line contrast).
const LINE_TOKENS := ["assembly_joint", "assembly_joint_selected", "assembly_warning", "assembly_unresolved", "assembly_ground", "assembly_contact"]
const LINE_CONTRAST := 2.5
## set_body_poses for 200 bodies against the 200k-iteration loop: twice the ratio measured alone
## (0.070 on 2026-11-13: 0.53 ms against 7.54 ms; HOLO_FORGE_TIMING_SLOWDOWN=3 fails it).
const TIMING_RATIO_LIMIT := 0.14

var failures: Array[String] = []
var ws: Control
var part: Node3D
var doc: Resource
var kernel: RefCounted
var base_body := ""
var lever_body := ""
var lever_comp := ""
var nested_comp := ""
## The Lever's pose in the tests: a turn about Y and X and a move.
var pose := XFORM.identity()
var _sink := 0.0
var _timings := PackedStringArray()


func _init() -> void:
	call_deferred("run")


func run() -> void:
	create_timer(240.0).timeout.connect(func() -> void:
		print("FAIL holo_forge_assembly_view: timed out ", failures)
		quit(1))
	pose = XFORM.compose(XFORM.compose(XFORM.translation(0.012, 0.034, -0.021), XFORM.rot_y(0.7)), XFORM.rot_x(0.3))
	ws = WORKSPACE.new()
	root.add_child(ws)
	ws.size = Vector2(1200, 800)
	kernel = ws.kernel
	if kernel == null:
		print("SKIP holo_forge_assembly_view: native library missing")
		quit(1)
		return
	_make_part()
	for i in 4:
		await process_frame
	_case("1 set_body_poses places every holder exactly", _check_set_poses())
	_case("2 posed pick keeps modelled points and adds world points", await _check_posed_pick())
	_case("3 feature commands show modelled positions", await _check_modelled_view())
	_case("4 analysis and decal follow the pose", await _check_followers())
	_case("5 browser folders, joint items and ground button", _check_browser())
	_case("6 joint and candidate glyphs", await _check_glyphs())
	_case("7 theme tokens", _check_theme())
	_case("8 timing of set_body_poses with 200 bodies", await _check_timing())
	_case("9 DOF handles", _check_dof_handles())
	_case("10 recompute re-solves the assembly", _check_recompute_solves())
	ws.set_part(null)
	part.queue_free()
	ws.queue_free()
	await process_frame
	if not _timings.is_empty():
		print("holo_forge_assembly_view timings: ", ", ".join(_timings))
	print("PASS holo_forge_assembly_view: all cases" if failures.is_empty() else "FAIL holo_forge_assembly_view: %d failures" % failures.size())
	quit(0 if failures.is_empty() else 1)


# --- The part --------------------------------------------------------------------------------

## A ground Base (100 x 10 x 100 mm, top at y = 10 mm) and a component Lever with a body from
## x -10 to 95 mm, y 10 to 20 mm, z -10 to 10 mm (its tip face at x = 95 mm, normal +X), and a
## component nested in the Lever with no body.
func _make_part() -> void:
	doc = DOCUMENT.new()
	var base: Resource = doc.add_feature("box", "Base", {
		"length": doc.make_input("100 mm", "length"), "height": doc.make_input("10 mm", "length"), "width": doc.make_input("100 mm", "length"),
	}, {"operation": OPERATIONS.NEW_BODY, "position": Vector3.ZERO})
	base_body = doc.new_body(base.id)
	base.options.body_id = base_body
	doc.bodies[base_body].name = "Base"
	lever_comp = doc.new_component()
	doc.components[lever_comp].name = "Lever"
	doc.active_component = lever_comp
	nested_comp = doc.new_component()
	doc.components[nested_comp].name = "Pin"
	doc.active_component = ""
	var lever: Resource = doc.add_feature("box", "LeverBox", {
		"length": doc.make_input("105 mm", "length"), "height": doc.make_input("10 mm", "length"), "width": doc.make_input("20 mm", "length"),
	}, {"operation": OPERATIONS.NEW_BODY, "position": Vector3(0.0425, 0.01, 0.0)})
	lever_body = doc.new_body(lever.id)
	lever.options.body_id = lever_body
	doc.bodies[lever_body].name = "Lever"
	doc.bodies[lever_body].component = lever_comp
	part = CAD_PART.new()
	part.document = doc
	root.add_child(part)
	ws.set_part(part)


## A C3.1 solve output made by hand: the Lever (and its nested component) at pose, the ground at
## identity.
func _hand_solve(lever_pose: PackedFloat64Array) -> Dictionary:
	return {
		"poses": {lever_comp: lever_pose, nested_comp: lever_pose},
		"body_poses": {lever_body: lever_pose, base_body: XFORM.identity()},
		"transforms": {lever_comp: XFORM.to_transform(lever_pose), nested_comp: Transform3D.IDENTITY},
		"joints": {}, "units": {lever_comp: {"fixed": false, "root": lever_comp, "reached_by": ""}},
		"warnings": PackedStringArray(), "ms": 0.0,
	}


# --- 1 ---------------------------------------------------------------------------------------

func _check_set_poses() -> bool:
	var view: Control = ws.viewport
	if not view.has_method("set_body_poses") or not view.has_method("body_holder"):
		return _expect(false, "The viewport should have set_body_poses() and body_holder().")
	var ok := true
	view.set_body_poses(_hand_solve(pose))
	var lever_holder: Node3D = view.body_holder(lever_body)
	var base_holder: Node3D = view.body_holder(base_body)
	ok = _expect(lever_holder != null and base_holder != null, "Both bodies should have holders.") and ok
	if not ok:
		return false
	ok = _expect(lever_holder.transform == XFORM.to_transform(pose), "The Lever holder should be to_transform(pose) exactly (%s vs %s)." % [lever_holder.transform, XFORM.to_transform(pose)]) and ok
	ok = _expect(base_holder.transform == Transform3D.IDENTITY, "The Base holder should stay at identity (%s)." % [base_holder.transform]) and ok
	ok = _expect(bool(view.is_posed()), "The view should say it is posed.") and ok
	# A body the solve does not list is shown where it was modelled.
	view.set_body_poses({"body_poses": {}})
	ok = _expect(lever_holder.transform == Transform3D.IDENTITY and not bool(view.is_posed()), "A body missing from the solve should go back to identity.") and ok
	view.set_body_poses(_hand_solve(pose))
	return ok


# --- 2 ---------------------------------------------------------------------------------------

func _check_posed_pick() -> bool:
	var ok := true
	var view: Control = ws.viewport
	var t := XFORM.to_transform(pose)
	var tip := Vector3(0.095, 0.015, 0.0)
	var world_tip := XFORM.to_transform(pose) * tip
	var world_normal := (t.basis * Vector3.RIGHT).normalized()
	# Straight through the picking code: a ray in the posed view, hitting the tip face.
	var hit: Dictionary = PICKING.ray_hit(view.pickable_bodies(), world_tip + world_normal * 0.05, -world_normal)
	ok = _expect(not hit.is_empty() and str(hit.get("body", "")) == lever_body, "The ray should hit the Lever (%s)." % [hit]) and ok
	if not hit.is_empty():
		ok = _expect(((hit.point as Vector3) - tip).length() <= 1e-6, "ray_hit should give the modelled point %s (%s)." % [tip, hit.point]) and ok
		ok = _expect(hit.has("world_point") and ((hit.world_point as Vector3) - world_tip).length() <= 1e-6, "ray_hit should give the posed point %s (%s)." % [world_tip, hit.get("world_point")]) and ok
		ok = _expect(absf(float(hit.distance) - 0.05) <= 1e-6, "The hit distance should be measured in the posed view (%s)." % hit.distance) and ok
	# Through the viewport: the camera looking at the posed tip face, faces only.
	var filters: Dictionary = view.filters.duplicate()
	view.filters = {"body": false, "face": true, "edge": false, "vertex": false}
	view.look_at_face(world_tip, world_normal)
	view.distance = 0.3
	view.target = world_tip
	view._update_camera()
	await process_frame
	var screen: Vector2 = view.project(world_tip)
	var pick: Dictionary = view.pick_at(screen)
	view.filters = filters
	ok = _expect(str(pick.get("kind", "")) == "face" and str(pick.get("body", "")) == lever_body, "pick_at on the posed tip should pick the Lever's face (%s at %s)." % [pick, screen]) and ok
	if not pick.is_empty():
		ok = _expect(((pick.point as Vector3) - tip).length() <= 1e-6, "The pick should keep the modelled point %s (%s)." % [tip, pick.point]) and ok
		ok = _expect(pick.has("world_point") and ((pick.world_point as Vector3) - world_tip).length() <= 1e-6, "The pick should carry the posed point %s (%s)." % [world_tip, pick.get("world_point")]) and ok
		ok = _expect(pick.has("world_normal") and ((pick.world_normal as Vector3) - world_normal).length() <= 1e-5, "The pick should carry the posed normal %s (%s)." % [world_normal, pick.get("world_normal")]) and ok
	# The modelled tip is not under the cursor any more: at the modelled place nothing of the Lever is hit.
	var stale: Dictionary = PICKING.ray_hit(view.pickable_bodies(), tip + Vector3.RIGHT * 0.05, Vector3.LEFT)
	ok = _expect(stale.is_empty() or str(stale.get("body", "")) != lever_body or ((stale.point as Vector3) - tip).length() > 1e-3,
		"A ray at the modelled tip should not hit the posed Lever's tip (%s)." % [stale]) and ok
	# A body at identity gives no world keys (picks are as before).
	var base_hit: Dictionary = PICKING.ray_hit(view.pickable_bodies(), Vector3(-0.04, 0.5, -0.04), Vector3.DOWN)
	ok = _expect(str(base_hit.get("body", "")) == base_body and not base_hit.has("world_point"), "A pick on an unposed body should have no world_point (%s)." % [base_hit]) and ok
	return ok


# --- 3 ---------------------------------------------------------------------------------------

func _check_modelled_view() -> bool:
	var ok := true
	var view: Control = ws.viewport
	ws.change("Place Comp1", func() -> void:
		var asm: Dictionary = DATA.normalized(doc.assembly)
		asm.placements[lever_comp] = pose
		doc.assembly = asm)
	var expected := XFORM.to_transform(pose)
	var holder: Node3D = view.body_holder(lever_body)
	ok = _expect(holder != null and holder.transform == expected, "The workspace's solve should pose the Lever at its placement (%s)." % [holder.transform if holder != null else null]) and ok
	ws.run_tool(CATALOG.find("solid.create.box"))
	await process_frame
	ok = _expect(ws.command != null, "The Box command should be running.") and ok
	holder = view.body_holder(lever_body)
	ok = _expect(holder != null and holder.transform == Transform3D.IDENTITY, "With a feature command open the Lever should show where it was modelled (%s)." % [holder.transform if holder != null else null]) and ok
	ok = _expect(bool(ws.modelled_view()), "The workspace should say it shows modelled positions.") and ok
	ok = _expect(_status().contains(DATA.S_MODELLED_VIEW), "The status line should say %s (%s)." % [DATA.S_MODELLED_VIEW, _status()]) and ok
	ws.cancel_command()
	await process_frame
	holder = view.body_holder(lever_body)
	ok = _expect(holder != null and holder.transform == expected, "Closing the command should pose the Lever again exactly (%s)." % [holder.transform if holder != null else null]) and ok
	ok = _expect(not bool(ws.modelled_view()) and not _status().contains(DATA.S_MODELLED_VIEW), "After the command the status line should not keep the note (%s)." % _status()) and ok
	# Inspect commands keep the posed view.
	ws.run_tool(CATALOG.find("solid.inspect.measure"))
	await process_frame
	holder = view.body_holder(lever_body)
	ok = _expect(ws.command != null and holder.transform == expected and not bool(ws.modelled_view()), "Measure should keep the posed view.") and ok
	ws.cancel_command()
	await process_frame
	return ok


func _status() -> String:
	if not ws._status_timer.is_stopped():
		ws._status_timer.stop()
	ws._update_status()
	return str(ws._status.text)


# --- 4 ---------------------------------------------------------------------------------------

func _check_followers() -> bool:
	var ok := true
	var view: Control = ws.viewport
	var tip := Vector3(0.095, 0.015, 0.0)
	var decal := {"id": "decal_v", "name": "Sticker", "image": "res://icon.svg", "body": lever_body, "face": "", "position": tip,
		"normal": Vector3.RIGHT, "size": Vector2(0.006, 0.006), "visible": true}
	var section_origin := Vector3(0.03, 0.015, 0.0)
	ws.change("Add Decal and Section", func() -> void:
		doc.decals.append(decal.duplicate(true))
		doc.analyses.append({"id": "analysis_v", "type": "section", "name": "Section", "visible": true,
			"options": {"origin": section_origin, "normal": Vector3.RIGHT}}))
	await process_frame
	var t := XFORM.to_transform(pose)
	var followers: Array = view.follower_nodes(lever_body)
	var decal_node: Decal = null
	var cap_node: MeshInstance3D = null
	for node in followers:
		if node is Decal:
			decal_node = node
		elif node is MeshInstance3D:
			cap_node = node
	ok = _expect(decal_node != null, "The Lever's decal should follow the Lever (%s)." % [followers]) and ok
	ok = _expect(cap_node != null, "The section cap on the Lever should follow the Lever (%s)." % [followers]) and ok
	if decal_node != null:
		var local := APPEARANCE.decal_transform(decal)
		ok = _expect(_in_part(view, decal_node).is_equal_approx(t * local), "The decal should sit at pose x its place (%s vs %s)." % [_in_part(view, decal_node), t * local]) and ok
	if cap_node != null:
		ok = _expect(_in_part(view, cap_node).is_equal_approx(t), "The cap should move with the Lever (%s)." % [_in_part(view, cap_node)]) and ok
	# The clip plane of the Lever's section is the analysis plane carried by the pose; the Base's
	# stays where it is.
	var lever_material := view.body_surface(lever_body).material_override as ShaderMaterial
	var base_material := view.body_surface(base_body).material_override as ShaderMaterial
	ok = _expect(lever_material != null and base_material != null, "Both bodies should be drawn with the section's clip material.") and ok
	if lever_material != null and base_material != null:
		var origin: Vector3 = lever_material.get_shader_parameter("plane_origin")
		var normal: Vector3 = lever_material.get_shader_parameter("plane_normal")
		ok = _expect(origin.is_equal_approx(t * section_origin) and normal.is_equal_approx((t.basis * Vector3.RIGHT).normalized()),
			"The Lever's clip plane should be carried by its pose (%s, %s)." % [origin, normal]) and ok
		ok = _expect((base_material.get_shader_parameter("plane_origin") as Vector3).is_equal_approx(section_origin), "The Base's clip plane should stay put.") and ok
	# Moving the pose moves them again.
	var other := XFORM.compose(XFORM.translation(-0.02, 0.0, 0.01), XFORM.rot_z(-0.4))
	view.set_body_poses(_hand_solve(other))
	if decal_node != null:
		ok = _expect(_in_part(view, decal_node).is_equal_approx(XFORM.to_transform(other) * APPEARANCE.decal_transform(decal)), "The decal should follow a new pose.") and ok
	ws.change("Remove Decal and Section", func() -> void:
		doc.decals = doc.decals.filter(func(d: Dictionary) -> bool: return str(d.get("id", "")) != "decal_v")
		doc.analyses = doc.analyses.filter(func(a: Dictionary) -> bool: return str(a.get("id", "")) != "analysis_v"))
	await process_frame
	return ok


# --- 5 ---------------------------------------------------------------------------------------

## A document with three joints (revolute in a loop, slider ok, ball unresolved), the Lever
## grounded, and its solve made by hand.
func _browser_doc() -> Array:
	var d: Resource = DOCUMENT.new()
	d.components = {
		"comp1": {"name": "Lever", "visible": true, "parent": "", "feature": ""},
		"comp2": {"name": "Arm", "visible": true, "parent": "", "feature": ""},
		"comp3": {"name": "Pin", "visible": true, "parent": "comp1", "feature": ""},
	}
	var asm: Dictionary = DATA.normalized({})
	asm.grounded["comp1"] = true
	for spec in [["revolute", true, false], ["slider", true, false], ["ball", true, false], ["cylindrical", false, false], ["planar", true, true]]:
		var id := DATA.new_id(asm, "joint")
		asm.joints.append({"id": id, "name": DATA.name_for("joint", id), "type": spec[0], "visible": spec[1], "suppressed": spec[2],
			"a": {"component": "comp2"}, "b": {"component": "comp1"}})
	asm = DATA.normalized(asm)
	d.assembly = asm
	var joints := {}
	var states := {"joint1": "loop", "joint2": "ok", "joint3": "unresolved", "joint4": "ok", "joint5": "suppressed"}
	var worlds := {
		"joint1": XFORM.translation(0.01, 0.0, 0.0), "joint2": XFORM.translation(0.0, 0.02, 0.0), "joint3": XFORM.translation(0.0, 0.0, 0.03),
		"joint4": XFORM.translation(0.02, 0.02, 0.0), "joint5": XFORM.translation(-0.02, 0.0, 0.0),
	}
	for id in states:
		joints[id] = {"state": states[id], "values": PackedFloat64Array(), "residual_m": 0.0, "residual_rad": 0.0,
			"frame_a": XFORM.identity(), "frame_b": XFORM.identity(), "world": worlds[id], "sentence": "%s says %s" % [id, states[id]]}
	var solve := {
		"poses": {"comp1": XFORM.identity(), "comp2": XFORM.identity(), "comp3": XFORM.identity()}, "body_poses": {},
		"transforms": {}, "joints": joints, "units": {"comp1": {"fixed": true, "root": "", "reached_by": ""}, "comp2": {"fixed": false, "root": "comp2", "reached_by": ""}},
		"warnings": PackedStringArray(), "ms": 0.0,
	}
	return [d, solve]


func _check_browser() -> bool:
	var ok := true
	var made := _browser_doc()
	var d: Resource = made[0]
	var solve: Dictionary = made[1]
	var tree: Tree = ws.browser
	ok = _expect(BROWSER.BUTTON_GROUND == 3, "BUTTON_GROUND should be 3.") and ok
	tree.refresh(d, [], {}, {}, solve)
	var joints_folder := _folder(tree, "Joints")
	ok = _expect(joints_folder != null and joints_folder.get_child_count() == 5, "The Joints folder should list the 5 joints (%d)." % (joints_folder.get_child_count() if joints_folder != null else -1)) and ok
	for id in ["joint1", "joint2", "joint3", "joint4", "joint5"]:
		var item: TreeItem = tree.item_for("joint", id)
		ok = _expect(item != null, "%s should have an item." % id) and ok
		if item == null:
			continue
		var meta: Dictionary = item.get_metadata(0)
		ok = _expect(item.get_icon(0) != null and str(meta.get("joint_type", "")) == str(d.assembly.joints[int(id.trim_prefix("joint")) - 1].type),
			"%s should show its type's icon (%s, %s)." % [id, item.get_icon(0), meta]) and ok
		var state := str(solve.joints[id].state)
		var badge := item.get_button_by_id(0, BROWSER.BUTTON_STATE)
		if state in ["loop", "unresolved", "error", "waiting"]:
			ok = _expect(badge >= 0 and str(meta.get("state", "")) == state and item.get_button_tooltip_text(0, badge) == str(solve.joints[id].sentence),
				"%s (%s) should have a state badge saying its sentence." % [id, state]) and ok
		else:
			ok = _expect(badge < 0, "%s (%s) should have no state badge." % [id, state]) and ok
		ok = _expect(item.get_button_by_id(0, BROWSER.BUTTON_EYE) >= 0, "%s should have an eye." % id) and ok
	var hidden_eye: TreeItem = tree.item_for("joint", "joint4")
	if hidden_eye != null:
		ok = _expect(hidden_eye.get_button_tooltip_text(0, hidden_eye.get_button_by_id(0, BROWSER.BUTTON_EYE)) == "Show", "A joint with visible: false should offer Show.") and ok
	for folder in ["Joint Origins", "Rigid Groups", "Motion Links", "Contact Sets", "Motion Studies"]:
		var item := _folder(tree, folder)
		ok = _expect(item == null or not item.visible, "The empty %s folder should be hidden." % folder) and ok
	# Ground buttons: top-level components only; the grounded one says Unground.
	var lever: TreeItem = tree.item_for("component", "comp1")
	var arm: TreeItem = tree.item_for("component", "comp2")
	var pin: TreeItem = tree.item_for("component", "comp3")
	var top: TreeItem = tree.item_for("component", "")
	ok = _expect(lever != null and arm != null and pin != null and top != null, "Every component should have an item.") and ok
	if lever != null and arm != null and pin != null and top != null:
		ok = _expect(lever.get_button_by_id(0, BROWSER.BUTTON_GROUND) >= 0 and arm.get_button_by_id(0, BROWSER.BUTTON_GROUND) >= 0, "Top-level components should have a ground button.") and ok
		ok = _expect(pin.get_button_by_id(0, BROWSER.BUTTON_GROUND) < 0 and top.get_button_by_id(0, BROWSER.BUTTON_GROUND) < 0, "A nested component and the top level should have none.") and ok
		ok = _expect(lever.get_button_tooltip_text(0, lever.get_button_by_id(0, BROWSER.BUTTON_GROUND)) == "Unground"
			and arm.get_button_tooltip_text(0, arm.get_button_by_id(0, BROWSER.BUTTON_GROUND)) == "Ground", "The ground button should say what it does.") and ok
		var grounded: Array = []
		tree.component_ground_toggled.connect(func(id: String) -> void: grounded.append(id), CONNECT_ONE_SHOT)
		tree.button_clicked.emit(arm, 0, BROWSER.BUTTON_GROUND, MOUSE_BUTTON_LEFT)
		ok = _expect(grounded == ["comp2"], "The ground button should ask to ground the Arm (%s)." % [grounded]) and ok
	# A joint origin makes its folder show.
	d.assembly.origins.append({"id": "origin1", "name": "Origin1", "component": "comp2", "visible": true})
	tree.refresh(d, [], {}, {}, solve)
	var origins := _folder(tree, "Joint Origins")
	ok = _expect(origins != null and origins.visible and origins.get_child_count() == 1 and tree.item_for("joint_origin", "origin1") != null,
		"A joint origin should make the Joint Origins folder show with it.") and ok
	ws._refresh_browser()
	return ok


func _folder(tree: Tree, text: String) -> TreeItem:
	var item := tree.get_root().get_first_child() if tree.get_root() != null else null
	while item != null:
		if item.get_text(0) == text:
			return item
		item = item.get_next()
	return null


# --- 6 ---------------------------------------------------------------------------------------

func _check_glyphs() -> bool:
	if not ResourceLoader.exists(DISPLAY_PATH):
		return _expect(false, "ui/assembly_display.gd should exist.")
	var ok := true
	var display: RefCounted = ws.assembly_display
	ok = _expect(display != null and display.get_script() == load(DISPLAY_PATH), "The workspace should hold an assembly display.") and ok
	if display == null:
		return false
	var made := _browser_doc()
	var d: Resource = made[0]
	var solve: Dictionary = made[1]
	var palette := THEME.palette("dark")
	display.refresh(ws.viewport, d, solve, palette)
	var badges: Array = display.glyphs().filter(func(g: Dictionary) -> bool: return str(g.kind) == "joint")
	var ids := badges.map(func(g: Dictionary) -> String: return str(g.joint))
	ids.sort()
	ok = _expect(ids == ["joint1", "joint2", "joint3", "joint5"], "One badge per visible joint, none for joint4 (visible: false) (%s)." % [ids]) and ok
	for g: Dictionary in badges:
		var dimmed := str(g.joint) == "joint5"
		ok = _expect(is_equal_approx(float(g.alpha), display.SUPPRESSED_ALPHA if dimmed else 1.0), "%s should be drawn at alpha %s (%s)." % [g.joint, display.SUPPRESSED_ALPHA if dimmed else 1.0, g.alpha]) and ok
		var world := XFORM.to_transform(solve.joints[g.joint].world).origin
		ok = _expect((g.position as Vector3).is_equal_approx(world), "%s's badge should sit at its joint frame (%s)." % [g.joint, g.position]) and ok
		var expected_dot: Variant = {"joint1": palette.assembly_warning, "joint3": palette.assembly_unresolved}.get(str(g.joint))
		ok = _expect(g.get("state_color") == expected_dot, "%s's state dot should be %s (%s)." % [g.joint, expected_dot, g.get("state_color")]) and ok
	ok = _expect(is_equal_approx(display.SUPPRESSED_ALPHA, 0.4), "Suppressed joints are drawn at 40%.") and ok
	# Snap candidates of one face: a mark each, the hovered one bigger and in the selection colour.
	var candidates := [
		{"kind": "face_center", "body": lever_body, "at": Vector3(0.095, 0.015, 0.0)},
		{"kind": "edge_mid", "body": lever_body, "at": Vector3(0.095, 0.01, 0.0)},
		{"kind": "vertex", "body": lever_body, "at": Vector3(0.095, 0.01, 0.01)},
		{"kind": "circle_center", "body": lever_body, "at": Vector3(0.0, 0.02, 0.0)},
		{"kind": "axis_mid", "body": lever_body, "at": Vector3(0.0, 0.015, 0.0)},
	]
	display.set_candidates(ws.viewport, candidates, 1)
	var marks: Array = display.glyphs().filter(func(g: Dictionary) -> bool: return str(g.kind) == "candidate")
	ok = _expect(marks.size() == 5, "Five candidates should give five marks (%d)." % marks.size()) and ok
	var shapes := marks.map(func(g: Dictionary) -> String: return str(g.shape))
	ok = _expect(shapes == ["dot", "diamond", "square", "ring", "plus"], "The marks should be dot, diamond, square, ring, plus (%s)." % [shapes]) and ok
	if marks.size() == 5:
		ok = _expect(float(marks[1].px) == display.CANDIDATE_HOVER_PX and marks[1].color == palette.assembly_joint_selected
			and float(marks[0].px) == display.CANDIDATE_PX and marks[0].color == palette.assembly_joint, "The hovered mark should be 10 px in the selection colour, the others 6 px.") and ok
		# Marks sit where the candidates are as shown (the Lever is posed).
		var shown: Transform3D = ws.viewport.body_pose(lever_body)
		ok = _expect((marks[0].position as Vector3).is_equal_approx(shown * Vector3(0.095, 0.015, 0.0)), "A candidate mark should sit on the posed body.") and ok
	# They draw without errors, and the hovered candidate is found near the cursor.
	ws.viewport.glyph_layer().queue_redraw()
	await process_frame
	var at: Vector2 = ws.viewport.project(marks[2].position if marks.size() > 2 else Vector3.ZERO)
	ok = _expect(int(display.candidate_at(ws.viewport, at + Vector2(2, 1))) == 2, "candidate_at near the third mark should give 2.") and ok
	display.set_candidates(ws.viewport, [], -1)
	ok = _expect(display.glyphs().filter(func(g: Dictionary) -> bool: return str(g.kind) == "candidate").is_empty(), "Clearing candidates should remove their marks.") and ok
	# The display goes back to the workspace's own document.
	ws._refresh_assembly()
	return ok


# --- 7 ---------------------------------------------------------------------------------------

func _check_theme() -> bool:
	var ok := true
	var dark := THEME.palette("dark")
	var light := THEME.palette("light")
	ok = _expect(dark.keys() == light.keys(), "Both palettes should hold the same keys.") and ok
	for token in TOKENS:
		ok = _expect(dark.has(token) and light.has(token) and dark[token] is Color and light[token] is Color, "%s should be a colour in both palettes." % token) and ok
	if not ok:
		return false
	var expected := {
		"dark": {"assembly_joint": Color("#f0a33a"), "assembly_unresolved": Color("#ff4d4d"), "assembly_ground": Color("#9aa4b2"), "assembly_contact": Color("#ff5d8f"),
			"assembly_ghost": Color(0.6, 0.8, 1.0, 0.25)},
		"light": {"assembly_joint": Color("#b86e00"), "assembly_unresolved": Color("#c41616"), "assembly_ground": Color("#5a6472"), "assembly_contact": Color("#c2185b"),
			"assembly_ghost": Color(0.1, 0.35, 0.7, 0.25)},
	}
	for name in ["dark", "light"]:
		var p := THEME.palette(name)
		for token in expected[name]:
			ok = _expect(p[token] == expected[name][token], "%s %s should be %s (%s)." % [name, token, expected[name][token], p[token]]) and ok
		var limit: Color = p.assembly_limit
		ok = _expect(Color(limit, 1.0) == p.assembly_joint and is_equal_approx(limit.a, 0.18), "%s assembly_limit should be assembly_joint at alpha 0.18." % name) and ok
		# The selection and warning roles reuse the existing tokens (spec 6.1).
		ok = _expect(p.assembly_joint_selected == p.select_line, "%s assembly_joint_selected should be the selection colour." % name) and ok
		ok = _expect(p.assembly_warning == p.mesh_warning, "%s assembly_warning should be mesh_warning." % name) and ok
		for back: Color in [p.view_top, p.view_bottom]:
			for token in LINE_TOKENS:
				var ratio := THEME.contrast(p[token], back)
				ok = _expect(ratio >= LINE_CONTRAST, "%s %s should read on the view (%.2f:1)." % [name, token, ratio]) and ok
	return ok


# --- 8 ---------------------------------------------------------------------------------------

func _check_timing() -> bool:
	var view: Control = VIEWPORT.new()
	root.add_child(view)
	view.size = Vector2(400, 300)
	var shape: RefCounted = kernel.make_box(Vector3(0.01, 0.01, 0.01))
	var tess := TESSELLATE.tessellate(shape)
	var entries := []
	var solve_a := {"body_poses": {}}
	var solve_b := {"body_poses": {}}
	for i in 200:
		var id := "body%d" % i
		entries.append({"id": id, "tess": tess, "visible": true, "selectable": true})
		solve_a.body_poses[id] = XFORM.compose(XFORM.translation(0.02 * i, 0.0, 0.0), XFORM.rot_z(0.01 * i))
		solve_b.body_poses[id] = XFORM.compose(XFORM.translation(0.0, 0.02 * i, 0.0), XFORM.rot_x(0.01 * i))
	view.set_bodies(entries)
	await process_frame
	var flip := [false]
	var op := func() -> void:
		flip[0] = not flip[0]
		view.set_body_poses(solve_a if flip[0] else solve_b)
	var timing := TIMING.compare(op, _calibration, 5, "set_body_poses 200 bodies / 200k-iteration loop")
	_timings.append("set_body_poses 200 bodies %.3f ms (calibration %.2f ms, ratio %.3f)" % [timing.op, timing.calibration, timing.ratio])
	var ok := _expect(float(timing.ratio) <= TIMING_RATIO_LIMIT, "set_body_poses for 200 bodies should take at most %s calibration loops (%.3f ms, ratio %.3f)." % [TIMING_RATIO_LIMIT, timing.op, timing.ratio])
	ok = _expect(float(timing.op) <= 2.0 or OS.get_environment("HOLO_FORGE_TIMING_SLOWDOWN") != "", "set_body_poses for 200 bodies should take at most 2 ms (%.3f ms)." % timing.op) and ok
	# Every holder holds its pose after the last call.
	view.set_body_poses(solve_a)
	var exact := true
	for i in 200:
		var id := "body%d" % i
		exact = exact and (view.body_holder(id) as Node3D).transform == XFORM.to_transform(solve_a.body_poses[id])
	ok = _expect(exact, "Every one of the 200 holders should hold its pose exactly.") and ok
	view.queue_free()
	await process_frame
	return ok


func _calibration() -> void:
	var x := 0.0
	for i in 200000:
		x += sqrt(float(i)) * 0.5
	_sink = x


# --- 9 ---------------------------------------------------------------------------------------

func _check_dof_handles() -> bool:
	var ok := true
	var view: Control = ws.viewport
	if not view.has_method("dof_handles"):
		return _expect(false, "The viewport should have dof_handles().")
	var world := XFORM.to_transform(XFORM.compose(XFORM.translation(0.01, 0.02, 0.03), XFORM.rot_x(0.5)))
	var revolute: Array = view.dof_handles("joint1", world, "revolute", PackedFloat64Array([0.25]))
	ok = _expect(revolute.size() == 1 and str(revolute[0].type) == "ring" and int(revolute[0].dof) == 0 and str(revolute[0].joint) == "joint1"
		and (revolute[0].axis as Vector3).is_equal_approx(world.basis.z.normalized()) and (revolute[0].origin as Vector3).is_equal_approx(world.origin)
		and is_equal_approx(float(revolute[0].base), 0.25), "A revolute should get one ring about the joint's Z at its frame (%s)." % [revolute]) and ok
	var slider: Array = view.dof_handles("joint2", world, "slider", PackedFloat64Array([0.004]), "x")
	ok = _expect(slider.size() == 1 and str(slider[0].type) == "slide" and (slider[0].direction as Vector3).is_equal_approx(world.basis.x.normalized())
		and is_equal_approx(float(slider[0].base), 0.004), "A slider on X should get one two-way arrow along the joint's X (%s)." % [slider]) and ok
	var planar: Array = view.dof_handles("joint3", world, "planar", PackedFloat64Array([0.0, 0.0, 0.0]))
	var kinds := planar.map(func(h: Dictionary) -> String: return str(h.type))
	ok = _expect(kinds == ["slide", "slide", "ring"], "A planar joint should get two arrows and a ring (%s)." % [kinds]) and ok
	ok = _expect(view.dof_handles("joint4", world, "rigid", PackedFloat64Array()).is_empty(), "A rigid joint should get no handles.") and ok
	# The ring is grabbed on its outline on screen.
	var handles: Array[Dictionary] = []
	handles.assign(revolute)
	view.set_handles(handles)
	var shape: Dictionary = view._handle_screen_shape(revolute[0])
	ok = _expect(not shape.is_empty() and (shape.get("points", PackedVector2Array()) as PackedVector2Array).size() > 8, "A ring should have an outline on screen.") and ok
	if not shape.is_empty():
		var on_ring: Vector2 = (shape.points as PackedVector2Array)[3]
		ok = _expect(not view._handle_at(on_ring).is_empty(), "A press on the ring's outline should grab it.") and ok
	var none: Array[Dictionary] = []
	view.set_handles(none)
	return ok


# --- 10 --------------------------------------------------------------------------------------

func _check_recompute_solves() -> bool:
	var refreshes: int = ws.assembly_refresh_count
	ws.recompute()
	var holder: Node3D = ws.viewport.body_holder(lever_body)
	return _expect(ws.assembly_refresh_count == refreshes + 1 and holder != null and holder.transform == XFORM.to_transform(pose),
		"recompute() should re-solve once and keep the Lever posed (%d refreshes)." % (ws.assembly_refresh_count - refreshes))


# --- Helpers ---------------------------------------------------------------------------------

func _case(label: String, ok: bool) -> void:
	print(("PASS " if ok else "FAIL ") + label)


func _expect(condition: bool, message: String) -> bool:
	if not condition:
		failures.append(message)
		push_error(message)
		print("FAIL: ", message)
	return condition


## A node's place in the part's space (the view's world may be moved: Passthrough, or the
## --holo-forge-test-world-offset test argument).
func _in_part(view: Object, node: Node3D) -> Transform3D:
	return (view.world_transform() as Transform3D).affine_inverse() * node.global_transform
