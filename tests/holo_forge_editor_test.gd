@tool
extends RefCounted
## Holo Forge inside the real editor (never saves the test scene): the Forge tab opens; the
## toolbar lists every workspace and greys out later phases; a part is added to the scene; the
## Box command previews live, takes typed sizes and handle drags, and commits as one undo step
## that undo and redo; a Cylinder cuts the box; picking and window selection find the body;
## the timeline rolls back; parameters drive sizes; the marking menu, S search and shortcuts work.
##
## godot --headless --path . --editor -- --holo-forge-editor-test

const CATALOG := preload("res://addons/holo_forge/tools/catalog.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")

var failures: Array[String] = []
var _plugin: EditorPlugin


func check(ok: bool, detail: String) -> void:
	if not ok:
		failures.append(detail)
		push_error(detail)
		print("FAIL: ", detail)


func run(plugin: EditorPlugin) -> void:
	_plugin = plugin
	var tree := plugin.get_tree()
	# A script error would stop this coroutine; the watchdog still ends the editor run.
	tree.create_timer(240.0).timeout.connect(func() -> void:
		print("FAIL Holo Forge EDITOR: timed out ", failures)
		tree.quit(1))
	for i in 90:
		await tree.process_frame
	# The editor reopens the last session's scenes in the background and may switch tabs while
	# it does; keep (re)opening the test scene until it has stayed current for 60 frames.
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
	var scene := EditorInterface.get_edited_scene_root()
	if scene == null or scene.name != "ForgeEditorTest":
		push_error("Holo Forge editor test could not open its scene.")
		tree.quit(1)
		return
	EditorInterface.set_main_screen_editor("Forge")
	for i in 5:
		await tree.process_frame
	var ws = plugin.get("workspace")
	check(ws != null and ws.visible, "The Forge main-screen tab should open.")
	if ws == null:
		_finish(tree)
		return
	check(ws.kernel != null, "The workspace should have the native kernel.")

	# Toolbar: every workspace, later-phase tools disabled with their phase.
	check(ws.toolbar.get_child(0) is OptionButton and (ws.toolbar.get_child(0) as OptionButton).item_count == 7, "The workspace switcher should list 7 workspaces.")
	var create: MenuButton = ws.toolbar.group_menu("Create")
	check(create != null, "The Solid workspace should have a CREATE menu.")
	if create != null:
		var popup := create.get_popup()
		var box_ok := false
		var form_enabled := false
		for i in popup.item_count:
			if popup.get_item_text(i) == "Box":
				box_ok = not popup.is_item_disabled(i)
			if popup.get_item_text(i).begins_with("Create Form"):
				form_enabled = not popup.is_item_disabled(i)
		check(box_ok and form_enabled, "Box and Create Form (Phase 6) should be enabled.")
		check(CATALOG.is_enabled(CATALOG.find("mesh.modify.remesh")), "Phase 7 Mesh tools (Remesh) should be enabled.")
		check(CATALOG.is_enabled(CATALOG.find("solid.assemble.joint")) and not CATALOG.is_enabled(CATALOG.find("sheet_metal.create.flange")), "Phase 8 Assemble tools (Joint) should be enabled and Phase 9 (Flange) greyed out.")
	for group in ["Modify", "Assemble", "Construct", "Inspect", "Insert", "Select"]:
		check(ws.toolbar.group_menu(group) != null, "The Solid workspace should have a %s menu." % group.to_upper())

	# Add a part (undoable) and work on it.
	var part: Node3D = ws.add_part_to_scene()
	await tree.process_frame
	check(part != null and part.get_parent() == scene and ws.part == part, "Add Forge Part should add a CadPart to the scene and edit it (part %s, parent %s, scene %s, edited %s, workspace part %s)." \
		% [part, part.get_parent() if part != null else null, scene, EditorInterface.get_edited_scene_root(), ws.part])
	if part == null or ws.part != part:
		_finish(tree)
		return
	var doc: Resource = part.document

	# Box: live preview, typed size, handle drag, OK.
	ws.run_tool(CATALOG.find("solid.create.box"))
	check(ws.command != null and ws.panel.visible, "The Box command should open its panel.")
	check(ws.result.bodies.size() == 1 and doc.features.size() == 1, "The Box should preview as a real body while the command runs.")
	var values: Dictionary = ws.command_values.duplicate(true)
	values.length = "80"
	values.width = "40"
	values.height = "20"
	values.position = Vector3.ZERO
	ws._on_panel_values_changed(values)
	await tree.process_frame
	var body_id: String = doc.features[0].options.body_id
	var box_shape = ws.result.bodies[body_id].shape
	check((box_shape.bbox() as AABB).size.is_equal_approx(Vector3(0.08, 0.02, 0.04)), "Typed sizes (80 x 20 x 40 mm) should update the preview (%s)." % box_shape.bbox().size)
	check(ws.viewport.handles.size() == 4, "The box should show 3 size arrows and a position handle.")
	var height_handle: Dictionary = {}
	for handle in ws.viewport.handles:
		if handle.key == "height":
			height_handle = handle
	ws._on_manipulator_changed(height_handle, 0.03)
	check(doc.features[0].expression("height") == "30 mm", "Dragging the height arrow to 30 mm should write '30 mm' (got %s)." % doc.features[0].expression("height"))
	ws.accept_command()
	await tree.process_frame
	check(ws.command == null and not ws.panel.visible, "OK should close the command.")
	check(part.body_nodes().size() == 1, "The part should bake the box as one body node.")

	# Undo / redo the whole command as one step.
	var history: UndoRedo = ws.history()
	check(history != null and history.has_undo(), "The box should be undoable.")
	history.undo()
	await tree.process_frame
	check(doc.features.is_empty() and ws.result.bodies.is_empty() and part.body_nodes().is_empty(), "Undo should remove the box and its baked body.")
	history.redo()
	await tree.process_frame
	check(doc.features.size() == 1 and ws.result.bodies.size() == 1 and part.body_nodes().size() == 1, "Redo should bring the box back.")

	# Cylinder cuts the box.
	var whole_volume: float = ws.result.bodies[body_id].shape.volume()
	ws.run_tool(CATALOG.find("solid.create.cylinder"))
	values = ws.command_values.duplicate(true)
	values.diameter = "10"
	values.height = "100"
	values.position = Vector3(0, -0.03, 0)
	values.operation = OPERATIONS.CUT
	values.targets = [body_id]
	ws._on_panel_values_changed(values)
	await tree.process_frame
	ws.accept_command()
	await tree.process_frame
	var cut_volume: float = ws.result.bodies[body_id].shape.volume()
	var expected := whole_volume - PI * 0.005 * 0.005 * 0.03
	check(ws.result.bodies.size() == 1 and absf(cut_volume - expected) < 1e-9, "The cylinder should cut a hole through the box (%f vs %f)." % [cut_volume, expected])
	check(ws.timeline.chip_count() == 2, "The timeline should show 2 features.")

	# Picking from straight above, and a window around the whole view.
	ws.viewport.look_from(Vector3.UP)
	ws.viewport.fit()
	await tree.process_frame
	var vp_size: Vector2 = ws.viewport.size
	var center: Vector2 = ws.viewport.project(Vector3(0.025, 0.03, 0.0))
	var pick: Dictionary = ws.viewport.pick_at(center)
	check(pick.get("body", "") == body_id and pick.get("kind", "") in ["face", "body"], "Clicking the box top should pick it (%s, view %s)." % [pick, vp_size])
	var window: Array = ws.viewport.region_picks(Rect2(Vector2(2, 2), vp_size - Vector2(4, 4)), false)
	check(window.size() == 1 and window[0].body == body_id, "A window around the whole view should select the body (%s)." % [window])
	ws._on_pick_clicked(pick, false, false)
	check(ws.selection.size() == 1, "A click should select.")
	ws.handle_key(_key(KEY_ESCAPE))
	check(ws.selection.is_empty(), "Esc should clear the selection.")

	# Timeline rollback, then roll forward.
	ws.set_rollback(1)
	await tree.process_frame
	check(absf(float(ws.result.bodies[body_id].shape.volume()) - whole_volume) < 1e-9, "Rolling back before the cut should show the whole box.")
	history.undo()
	await tree.process_frame
	check(doc.rollback == -1 and absf(float(ws.result.bodies[body_id].shape.volume()) - cut_volume) < 1e-9, "Undoing the rollback should bring the cut back.")

	# Parameters drive model sizes.
	ws._add_user_parameter()
	ws._change_user_parameter(0, "expression", "50 mm")
	ws._change_model_expression(doc.features[0].id, "length", "param1 * 2")
	await tree.process_frame
	check(is_equal_approx((ws.result.bodies[body_id].shape.bbox() as AABB).size.x, 0.1), "length = param1 * 2 should make the box 100 mm long.")
	ws._change_user_parameter(0, "name", "d1")
	check(doc.user_parameters[0].name == "param1", "A user parameter can't take a model parameter's name.")

	# Marking menu, S search, shortcuts.
	ws._open_marking_menu(vp_size * 0.5)
	var labels: PackedStringArray = ws.marking_menu.labels()
	check(labels.has("Undo") and labels.has("Delete") and labels.has("Repeat Cylinder") and labels.has("Fit (F6)"), "The marking menu should offer Repeat, Delete, Undo and Fit (%s)." % [labels])
	ws.marking_menu.close()
	var found: Array = ws.command_search.results_for("cyl")
	check(not found.is_empty() and found[0].name == "Cylinder", "Searching 'cyl' should find Cylinder first.")
	check(ws.tool_for_key("E").get("name", "") == "Extrude" and ws.tool_for_key("L").get("name", "") == "Line", "E and L should map to Extrude and Line.")
	ws.handle_key(_key(KEY_E))
	check(ws.command != null and ws.command.title() == "Extrude", "Pressing E should start Extrude (%s)." % [ws.command.title() if ws.command != null else ws.last_message])
	ws.cancel_command()

	# Named views and body visibility through undoable changes.
	var state: Dictionary = ws.viewport.view_state()
	ws.change("Save Named View", func() -> void: doc.named_views["Top"] = state)
	ws._change_body(body_id, "visible", "Hide Body")
	await tree.process_frame
	check(not part.body_nodes()[body_id].visible, "Hiding a body should hide its baked node.")
	history.undo()
	await tree.process_frame
	check(part.body_nodes()[body_id].visible and doc.named_views.has("Top"), "Undo should show the body again and keep the named view.")
	_finish(tree)


func _key(keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	return event


func _finish(tree: SceneTree) -> void:
	for i in 4:
		await tree.process_frame
	if failures.is_empty():
		print("PASS Holo Forge EDITOR: Forge tab, toolbar phases, add part, Box preview/typed sizes/handle drag, one-step undo/redo, cylinder cut, picking and window select, rollback, parameters, marking menu, S search, shortcuts, named view, hide/undo")
	else:
		print("FAIL Holo Forge EDITOR: ", failures)
	tree.quit(0 if failures.is_empty() else 1)
