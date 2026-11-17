@tool
extends RefCounted
## Holo Forge Phase 5 inside the real editor (never saves the test scene):
## - the Surface workspace's tools are enabled (Form's stay off), and E runs the surface Extrude
##   (in a sketch too, where the sketch's own keys stay);
## - a sketch line picked on screen extrudes into a surface body (one undo step), drawn with the
##   two-sided surface material, listed with the surface icon and baked double-sided;
## - Trim takes a sketch line as its tool, cuts the surface into clickable pieces, and a click on
##   one piece (kept with where it hit) removes it; the trim edits again from the timeline;
## - Thicken by a click on the surface makes a solid of area x t; Reverse Normal by a click turns
##   the surface over.
##
## godot --headless --path . --editor -- --holo-forge-surface-editor-test

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
		print("FAIL Holo Forge SURFACE EDITOR: timed out ", failures)
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
	var history: UndoRedo = ws.history()

	# The Surface workspace: every tool up to Phase 5 on; Create Form (Phase 6) and Mesh (Phase 7) on, Phase 8 Joint on, Phase 9 Flange off.
	ws.toolbar.set_workspace("Surface")
	ws.workspace = "Surface"
	var off := []
	for group in CATALOG.groups("Surface"):
		for tool in CATALOG.tools_in("Surface", group):
			if int(tool.phase) <= 5 and not CATALOG.is_enabled(tool):
				off.append(tool.name)
	check(off.is_empty(), "Every Surface tool should be enabled (%s)." % [off])
	check(CATALOG.is_enabled(CATALOG.find("solid.create.create_form")) and CATALOG.is_enabled(CATALOG.find("mesh.modify.remesh"))
		and CATALOG.is_enabled(CATALOG.find("solid.assemble.joint")) and not CATALOG.is_enabled(CATALOG.find("sheet_metal.create.flange")),
		"Create Form (Phase 6) and Mesh tools (Phase 7) should be enabled, Joint (Phase 8) enabled, and Flange (Phase 9) disabled.")
	var create: MenuButton = ws.toolbar.group_menu("Create")
	var patch_on := false
	if create != null:
		var popup := create.get_popup()
		for i in popup.item_count:
			if popup.get_item_text(i) == "Patch":
				patch_on = not popup.is_item_disabled(i)
	check(patch_on, "The Surface CREATE menu should offer Patch.")

	# A ground sketch: a 20 mm line along X, and a cutter line across it at x = 5 mm.
	ws.create_sketch(SKETCH.ORIGIN_PLANES.xz, "xz")
	ws.sketch_editor.start_tool("line")
	ws.sketch_editor.tool_click(Vector2(0, 0), {}, {})
	ws.sketch_editor.tool_click(Vector2(0.02, 0), {}, {})
	ws.sketch_editor.cancel_tool()
	ws.sketch_editor.start_tool("line")
	ws.sketch_editor.tool_click(Vector2(0.005, -0.006), {}, {})
	ws.sketch_editor.tool_click(Vector2(0.005, 0.006), {}, {})
	ws.sketch_editor.cancel_tool()
	# In the sketch, E is the Surface workspace's Extrude too; the sketch keeps its own keys.
	check(str(ws.tool_for_key("E").get("type", "")) == "surface:extrude" and str(ws.tool_for_key("L").get("sketch", "")) == "line",
		"In a sketch in the Surface workspace E should be the surface Extrude and L the Line (%s)." % [ws.tool_for_key("E").get("id", "")])
	ws.run_action("finish_sketch")
	await tree.process_frame
	ws.viewport.fit()
	await tree.process_frame

	# E in the Surface workspace: the surface Extrude; the line is picked on screen.
	var key := InputEventKey.new()
	key.keycode = KEY_E
	key.pressed = true
	ws.handle_key(key)
	check(ws.command != null and str(ws.command.get("key")) == "surface:extrude", "E should start the surface Extrude in the Surface workspace (%s)." % [ws.command.get("key") if ws.command != null else null])
	if ws.command == null:
		_finish(tree)
		return
	check(ws.panel.active_selection_key == "profiles" and ws._active_kinds().has("sketch_curve"), "The surface Extrude should pick sketch curves.")
	_click(ws, ws.viewport.project(Vector3(0.015, 0, 0)))
	var picks: Array = ws.command_values.get("profiles", [])
	check(picks.size() == 1 and picks[0].get("kind", "") == "sketch_curve", "Clicking the line should pick it (%s)." % [picks])
	_set_value(ws, "distance", "10")
	await tree.process_frame
	var extrude: Resource = ws.command.feature
	ws.accept_command()
	await tree.process_frame
	var body := str(extrude.options.get("body_id", ""))
	var shape = ws.result.get("bodies", {}).get(body, {}).get("shape")
	check(shape != null and shape.is_surface() and absf(shape.area() * 1e6 - 200.0) < 1e-3, "The extruded line should be a 200 mm2 surface body (errors %s)." % [ws.result.get("errors", {})])
	history.undo()
	await tree.process_frame
	check(not ws.result.bodies.has(body), "One undo should remove the surface extrude.")
	history.redo()
	await tree.process_frame
	check(ws.result.bodies.has(body), "Redo should bring the surface back.")
	var view_surface: MeshInstance3D = ws.viewport.body_surface(body)
	check(view_surface != null and view_surface.material_override == ws.viewport.surface_body_material(), "The view should draw the surface with the two-sided surface material.")
	var item: TreeItem = ws.browser._body_items.get(body)
	check(item != null and item.get_icon(0) == ws.browser._icon("PlaneMesh"), "The browser should list the surface with the surface icon.")
	var baked: MeshInstance3D = part.body_nodes().get(body)
	var baked_material := (baked.mesh as ArrayMesh).surface_get_material(0) as BaseMaterial3D if baked != null and baked.mesh != null else null
	check(baked_material != null and baked_material.cull_mode == BaseMaterial3D.CULL_DISABLED, "The baked surface should be double-sided.")

	# Trim: the cutter line is the tool; the surface shows its two pieces; a click removes one.
	# (The home view: the sketch left the camera looking straight down, edge-on to the surface.)
	ws.viewport.home()
	ws.viewport.fit()
	await tree.process_frame
	ws.run_tool(CATALOG.find("surface.modify.trim"))
	check(ws.command != null and ws.panel.active_selection_key == "tool", "Trim should start with its tool slot active.")
	_click(ws, ws.viewport.project(Vector3(0.005, 0, -0.004)))
	check((ws.command_values.get("tool", []) as Array).size() == 1, "Clicking the cutter line should pick it as the trimming tool (%s)." % [ws.command_values.get("tool", [])])
	await tree.process_frame
	var trim: Resource = ws.command.feature
	check(str(ws.result.get("errors", {}).get(trim.id, "")).contains("Click the pieces"), "Trim should ask for the pieces to remove (%s)." % ws.result.get("errors", {}).get(trim.id, ""))
	check(ws.kernel.pieces(ws.result.bodies[body].shape).size() == 2, "The surface should show two pieces to click.")
	ws.panel.activate_selection("remove")
	_click(ws, ws.viewport.project(Vector3(0.002, 0.005, 0)))
	await tree.process_frame
	var removed: Array = ws.command_values.get("remove", [])
	check(removed.size() == 1 and removed[0].get("at") is Vector3, "Clicking the short piece should pick it where the click hit (%s)." % [removed])
	ws.accept_command()
	await tree.process_frame
	shape = ws.result.bodies[body].shape
	check(not ws.result.get("errors", {}).has(trim.id) and absf(shape.area() * 1e6 - 150.0) < 1e-3, "Trimming the 5 mm piece should leave 150 mm2 (got %s, errors %s)." % [shape.area() * 1e6, ws.result.get("errors", {})])
	ws.edit_feature(trim.id)
	check(ws.command != null and str(ws.command.get("key")) == "surface:trim" and (ws.command_values.get("remove", []) as Array).size() == 1, "The trim should edit again from the timeline.")
	ws.cancel_command()
	await tree.process_frame

	# Thicken by a click on the surface: a solid of 150 mm2 x 2 mm.
	ws.run_tool(CATALOG.find("surface.create.thicken"))
	_click(ws, ws.viewport.project(Vector3(0.012, 0.005, 0)))
	_set_value(ws, "thickness", "2")
	await tree.process_frame
	var thicken: Resource = ws.command.feature if ws.command != null else null
	ws.accept_command()
	await tree.process_frame
	var solid = ws.result.bodies.get(str(thicken.options.get("body_id", "")) if thicken != null else "", {}).get("shape")
	check(solid != null and solid.solid_count() == 1 and absf(solid.volume() * 1e9 - 300.0) < 1e-3, "Thicken should make a 300 mm3 solid (errors %s)." % [ws.result.get("errors", {})])
	# (Undone, so the solid doesn't cover the surface for the next click.)
	history.undo()
	await tree.process_frame

	# Reverse Normal by a click: the surface turns over.
	shape = ws.result.bodies[body].shape
	var before: Vector3 = shape.face_normal_at(0, Vector3(0.012, 0.005, 0))
	ws.run_tool(CATALOG.find("surface.modify.reverse_normal"))
	_click(ws, ws.viewport.project(Vector3(0.012, 0.007, 0)))
	await tree.process_frame
	ws.accept_command()
	await tree.process_frame
	var after: Vector3 = ws.result.bodies[body].shape.face_normal_at(0, Vector3(0.012, 0.005, 0))
	check(before.dot(after) < -0.99, "Reverse Normal should turn the surface over (%s -> %s)." % [before, after])
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


func _finish(tree: SceneTree) -> void:
	for i in 4:
		await tree.process_frame
	if failures.is_empty():
		print("PASS Holo Forge SURFACE EDITOR: Surface tools enabled (Create Form and Mesh on, Phase 8 Joint on, Phase 9 Flange off), E runs the surface Extrude (in a sketch too); a screen-picked sketch line extrudes into a 200 mm2 surface (one undo step), drawn two-sided, listed with the surface icon, baked double-sided; Trim by a picked cutter line shows two pieces and a click removes one (150 mm2), and edits again from the timeline; Thicken by a click makes a 300 mm3 solid; Reverse Normal by a click turns the surface over")
	else:
		print("FAIL Holo Forge SURFACE EDITOR: ", failures)
	tree.quit(0 if failures.is_empty() else 1)
