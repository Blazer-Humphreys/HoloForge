@tool
extends RefCounted
## Holo Forge Phase 3 inside the real editor (never saves the test scene): every Solid,
## Construct and Phase 3 Modify tool is enabled; Extrude picks a profile on screen, shows its
## distance arrow and is one undo step; Fillet picks an edge and Press Pull a face on screen;
## an Offset Plane is made from an origin plane and listed under Construction; Hole and a
## Rectangular Pattern of that hole cut the body; New Component puts the next body in its own
## component and its own baked Node3D; and editing the extrude from the timeline updates
## everything after it.
##
## godot --headless --path . --editor -- --holo-forge-solid-editor-test

const CATALOG := preload("res://addons/holo_forge/tools/catalog.gd")
const SKETCH := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")

var failures: Array[String] = []


func check(ok: bool, detail: String) -> void:
	if not ok:
		failures.append(detail)
		push_error(detail)
		print("FAIL: ", detail)


func run(plugin: EditorPlugin) -> void:
	var tree := plugin.get_tree()
	tree.create_timer(300.0).timeout.connect(func() -> void:
		print("FAIL Holo Forge SOLID EDITOR: timed out ", failures)
		tree.quit(1))
	var stable := 0
	for i in 900:
		await tree.process_frame
		var opened := EditorInterface.get_edited_scene_root()
		if opened != null and opened.name == "ForgeEditorTest" and opened.is_inside_tree():
			stable += 1
			if stable >= 60:
				break
		else:
			stable = 0
			if i % 30 == 0:
				EditorInterface.open_scene_from_path("res://tests/holo_forge/forge_editor_test.tscn")
	EditorInterface.set_main_screen_editor("Forge")
	for i in 5:
		await tree.process_frame
	var ws = plugin.get("workspace")
	var part: Node3D = ws.add_part_to_scene()
	await tree.process_frame
	if part == null or ws.part != part:
		check(false, "A part should be added to edit.")
		_finish(tree)
		return
	var doc: Resource = part.document
	var history: UndoRedo = ws.history()

	# Every Phase 3 tool in the Solid workspace is enabled and runs a command or an action.
	var disabled := []
	for tool in CATALOG.all_tools():
		if int(tool.phase) == 3 and not CATALOG.is_enabled(tool):
			disabled.append("%s/%s" % [tool.workspace, tool.name])
	check(disabled.is_empty(), "Every Phase 3 tool should be enabled (%s)." % [disabled])

	# A 40 x 20 mm rectangle sketch on the ground.
	var sketch: Resource = ws.create_sketch(SKETCH.ORIGIN_PLANES.xz, "xz")
	ws.sketch_editor.start_tool("rect_2pt")
	ws.sketch_editor.tool_click(Vector2(0, 0), {}, {})
	ws.sketch_editor.tool_click(Vector2(0.04, 0.02), {}, {})
	ws.run_action("finish_sketch")
	await tree.process_frame
	ws.viewport.fit()
	await tree.process_frame

	# Extrude: the profile is picked on screen, the distance typed; one undo step.
	ws.run_tool(CATALOG.find("solid.create.extrude"))
	check(ws.command != null and ws.panel.active_selection_key == "profiles", "Extrude should start with its Profiles slot active.")
	check(ws.picker.active() and ws._active_kinds().has("profile"), "The Profiles slot should let the view pick profiles.")
	var profile_screen: Vector2 = ws.viewport.project(Vector3(0.02, 0.0, -0.01))
	_click(ws, profile_screen)
	check((ws.command_values.get("profiles", []) as Array).size() == 1 and ws.command_values.profiles[0].get("kind", "") == "profile",
		"Clicking inside the rectangle should pick its profile (%s at %s)." % [ws.command_values.get("profiles", []), profile_screen])
	_set_value(ws, "distance", "10")
	await tree.process_frame
	var arrows: Array = ws.viewport.handles.filter(func(h: Dictionary) -> bool: return h.get("key", "") == "distance")
	check(arrows.size() == 1 and (arrows[0].origin as Vector3).distance_to(Vector3(0.02, 0.01, -0.01)) < 1e-5, "An arrow should drag the extrude distance from the profile's top (%s)." % [arrows])
	var extrude: Resource = ws.command.feature
	ws.accept_command()
	await tree.process_frame
	var body := str(extrude.options.get("body_id", ""))
	_volume(ws, body, 8000.0, "Extrude 40 x 20 x 10 mm")
	history.undo()
	await tree.process_frame
	check(not ws.result.bodies.has(body), "One undo should remove the extrude.")
	history.redo()
	await tree.process_frame
	_volume(ws, body, 8000.0, "Redo brings the extrude back")

	# Fillet: an edge is picked on screen (the top edge along X at the front).
	ws.viewport.fit()
	await tree.process_frame
	var shape: RefCounted = ws.result.bodies[body].shape
	var front_top := -1
	for e in shape.edge_count():
		var info: Dictionary = shape.edge_info(e)
		if info.type == "line" and absf((info.midpoint as Vector3).y - 0.01) < 1e-6 and absf((info.midpoint as Vector3).z) < 1e-6 and absf(float(info.length) - 0.04) < 1e-6:
			front_top = e
	ws.run_tool(CATALOG.find("solid.modify.fillet"))
	if front_top >= 0:
		_click(ws, ws.viewport.project(shape.edge_info(front_top).midpoint))
	var edges: Array = ws.command_values.get("edges", [])
	check(edges.size() == 1 and edges[0].get("kind", "") == "edge", "Clicking the top front edge should pick it for the fillet (%s)." % [edges])
	_set_value(ws, "radius", "2")
	ws.accept_command()
	await tree.process_frame
	_volume(ws, body, 8000.0 - (1.0 - PI / 4.0) * 4.0 * 40.0, "Fillet 2 mm on a 40 mm edge")

	# Press Pull on the right-hand face offsets it.
	shape = ws.result.bodies[body].shape
	var right := -1
	for f in shape.face_count():
		var info: Dictionary = shape.face_info(f)
		if info.get("planar", false) and (info.normal as Vector3).is_equal_approx(Vector3.RIGHT):
			right = f
	# Look at the end face more squarely, so a click in its middle is clearly on the face.
	ws.viewport.look_from(Vector3(1.0, 0.25, 0.2))
	ws.viewport.fit()
	await tree.process_frame
	ws.run_tool(CATALOG.find("solid.modify.press_pull"))
	if right >= 0:
		_click(ws, ws.viewport.project(shape.face_info(right).point))
	check(ws.command != null and ws.command.feature.type == "offset_face", "Press Pull on a face should offset it (%s)." % [ws.command.feature.type if ws.command != null else "no command"])
	_set_value(ws, "distance", "5")
	var pull_feature: Resource = ws.command.feature if ws.command != null else null
	var pull_error: String = str(ws.result.errors.get(pull_feature.id, "")) if pull_feature != null else "no command"
	check(pull_error == "", "Press Pull should build (%s; options %s)." % [pull_error, pull_feature.options if pull_feature != null else {}])
	ws.accept_command()
	await tree.process_frame
	var after_pull: float = float(ws.result.bodies[body].shape.volume()) * 1e9
	var before_pull := 8000.0 - (1.0 - PI / 4.0) * 4.0 * 40.0
	check(after_pull > before_pull + 5.0 * 150.0 and after_pull < before_pull + 5.0 * 200.0 + 1.0, "Press Pull 5 mm on the 20 x 10 mm end should add about 1000 mm3 less the fillet's corner (%s)." % (after_pull - before_pull))

	# An Offset Plane from the ground plane, listed under Construction.
	ws.run_tool(CATALOG.find("solid.construct.offset_plane"))
	check(ws._active_kinds().has("plane"), "Offset Plane should pick planes.")
	ws._on_reference_picked({"kind": "origin", "name": "xz"})
	_set_value(ws, "distance", "30")
	var plane: Resource = ws.command.feature
	ws.accept_command()
	await tree.process_frame
	var c: Dictionary = ws.result.construction.get(plane.id, {})
	check(not c.is_empty() and absf((c.origin as Vector3).y - 0.03) < 1e-6, "The offset plane should sit 30 mm up (%s)." % [c])
	check(_tree_has(ws.browser, plane.label), "The browser should list the plane under Construction.")

	# Hole on the top face, then a rectangular pattern of that hole along X.
	shape = ws.result.bodies[body].shape
	var top_face := -1
	for f in shape.face_count():
		var info: Dictionary = shape.face_info(f)
		if info.get("planar", false) and (info.normal as Vector3).is_equal_approx(Vector3.UP):
			top_face = f
	ws.run_tool(CATALOG.find("solid.create.hole"))
	ws._on_reference_picked({"kind": "vertex", "body": body, "point": Vector3(0.008, 0.01, -0.012)})
	ws.panel.activate_selection("face")
	_click(ws, ws.viewport.project(shape.face_info(top_face).point))
	check((ws.command_values.get("face", []) as Array).size() == 1, "The hole's start face should be picked on screen.")
	_set_value(ws, "diameter", "4")
	_set_value(ws, "depth", "5")
	var hole: Resource = ws.command.feature
	ws.accept_command()
	await tree.process_frame
	var with_hole: float = float(ws.result.bodies[body].shape.volume()) * 1e9
	check(absf(after_pull - with_hole - PI * 4.0 * 5.0) < 1e-3, "The hole should remove pi r^2 h (%s)." % (after_pull - with_hole))
	ws.run_tool(CATALOG.find("solid.create.rectangular_pattern"))
	_set_value(ws, "object_type", "features")
	ws.panel.activate_selection("objects")
	check(ws._active_kinds() == ["feature"], "With Features, the objects slot picks features (%s)." % [ws._active_kinds()])
	ws._on_reference_picked({"kind": "feature", "feature": hole.id})
	ws.panel.activate_selection("direction1")
	ws._on_reference_picked({"kind": "origin", "name": "x"})
	_set_value(ws, "quantity1", "3")
	_set_value(ws, "distance1", "24")
	ws.accept_command()
	await tree.process_frame
	var patterned: float = float(ws.result.bodies[body].shape.volume()) * 1e9
	check(absf(with_hole - patterned - 2.0 * PI * 4.0 * 5.0) < 1e-3, "Two more holes should be patterned along X (%s)." % (with_hole - patterned))

	# New Component: the next body goes into it and bakes under its own Node3D.
	ws.run_action("new_component")
	await tree.process_frame
	check(doc.components.size() == 1 and doc.active_component != "", "New Component should add and activate a component.")
	ws.run_tool(CATALOG.find("solid.create.box"))
	var box: Resource = ws.command.feature
	ws.accept_command()
	await tree.process_frame
	var box_body := str(box.options.get("body_id", ""))
	check(doc.body_component(box_body) == doc.active_component, "The box should belong to the active component.")
	var nodes: Dictionary = part.body_nodes()
	var component_nodes: Dictionary = part.component_nodes()
	check(nodes.has(box_body) and component_nodes.has(doc.active_component) and nodes[box_body].get_parent() == component_nodes[doc.active_component],
		"The box should bake inside its component's Node3D (%s)." % [component_nodes.keys()])
	ws.activate_component("")

	# Editing the extrude from the timeline updates the fillet, press pull, hole and pattern.
	ws.edit_feature(extrude.id)
	check(ws.command != null and ws.command.editing and str(ws.command_values.get("distance", "")) == "10", "Editing the extrude should open it with its values.")
	_set_value(ws, "distance", "15")
	ws.accept_command()
	await tree.process_frame
	check(ws.result.errors.is_empty(), "Every later feature should still rebuild after the edit (%s)." % [ws.result.errors])
	var taller: float = float(ws.result.bodies[body].shape.volume()) * 1e9
	check(absf(taller - patterned - 40.0 * 20.0 * 5.0 - 5.0 * 20.0 * 5.0) < 1.0, "The body should grow by the extra 5 mm of height (%s)." % (taller - patterned))
	history.undo()
	await tree.process_frame
	check(absf(float(ws.result.bodies[body].shape.volume()) * 1e9 - patterned) < 1e-3, "Undo should restore the old height.")
	_finish(tree)


func _click(ws, at: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = at
	ws.picker.handle_mouse(event)


func _set_value(ws, key: String, value: Variant) -> void:
	var values: Dictionary = ws.panel.values.duplicate(true)
	values[key] = value
	ws.panel.set_values(values)
	ws._on_panel_values_changed(values)
	ws.recompute()


func _volume(ws, body_id: String, expected_mm3: float, label: String) -> void:
	var shape = ws.result.get("bodies", {}).get(body_id, {}).get("shape")
	var v: float = float(shape.volume()) * 1e9 if shape != null else -1.0
	check(shape != null and absf(v - expected_mm3) < expected_mm3 * 1e-6, "%s: %s mm3 expected, got %s (errors %s)." % [label, expected_mm3, v, ws.result.get("errors", {})])


func _tree_has(tree: Tree, text: String) -> bool:
	var stack := [tree.get_root()]
	while not stack.is_empty():
		var item: TreeItem = stack.pop_back()
		if item == null:
			continue
		if item.get_text(0) == text:
			return true
		for child in item.get_children():
			stack.append(child)
	return false


func _finish(tree: SceneTree) -> void:
	for i in 4:
		await tree.process_frame
	if failures.is_empty():
		print("PASS Holo Forge SOLID EDITOR: Phase 3 tools enabled; extrude by screen-picked profile with arrow and undo; fillet and press pull by screen picks; offset plane in Construction; hole and pattern; new component baked as its own node; timeline edit updates downstream")
	else:
		print("FAIL Holo Forge SOLID EDITOR: ", failures)
	tree.quit(0 if failures.is_empty() else 1)
