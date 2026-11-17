@tool
extends RefCounted
## Holo Forge Phase 4 Inspect, Appearance and Physical Material inside the real editor (never
## saves the test scene): the tools are enabled (Surface tools stay disabled); Measure shows the
## distance and angle between two faces of a box (one picked on screen) and changes nothing;
## Interference lists the one clash of two overlapping boxes with its volume, Create Bodies adds
## it as a body and Create Components as a body in a component of its own (each one undo step);
## Zebra and Section analyses are listed in the browser, change the view's body materials, hide
## and show with the eye (the browser's own button too), rename, delete and undo, all without a
## rebuild; Section's Tilt and Spin turn the clip plane and its angle handles turn it as far as
## they are dragged; Draft takes its pull from a picked face; every other analysis shows without
## errors (Environment Map adds a reflection probe over the bodies, gone when hidden, cancelled or
## deleted; Isocurve combs show on a cylinder); Display Component Colors toggles with Shift+N and
## stays on (with a zebra) through a box edit, also when pressed inside the edit and then
## cancelled or accepted; an appearance on a face and on a body changes the view's and the baked
## body's surfaces; Texture Map Controls drags the face's scale, rotation and offset in the view,
## Cancel puts mapping and view back, OK bakes the new UVs as one undo step, a new pick edits the
## entry it reads; the Appearance panel types origin and axis and opens Texture Map Controls; a
## physical material changes the mass Center of Mass reports, Keep in Analysis leaves its point
## in the view, and a split piece gets a material of its own.
##
## godot --headless --path . --editor -- --holo-forge-inspect-editor-test

const CATALOG := preload("res://addons/holo_forge/tools/catalog.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const ANALYSIS := preload("res://addons/holo_forge/core/analysis.gd")
const APPEARANCE := preload("res://addons/holo_forge/core/appearance.gd")
const MATERIAL_LIBRARY := preload("res://addons/holo_forge/core/material_library.gd")
const INSPECT := preload("res://addons/holo_forge/core/inspect.gd")
const BROWSER := preload("res://addons/holo_forge/ui/browser.gd")

const RED := "builtin:paint_red"
const CHROME := "builtin:metal_chrome"

var failures: Array[String] = []


func check(ok: bool, detail: String) -> void:
	if not ok:
		failures.append(detail)
		push_error(detail)
		print("FAIL: ", detail)


func run(plugin: EditorPlugin) -> void:
	var tree := plugin.get_tree()
	tree.create_timer(480.0).timeout.connect(func() -> void:
		print("FAIL Holo Forge INSPECT EDITOR: timed out ", failures)
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

	# The Inspect, Appearance and Physical Material tools are enabled; Phase 5 waits for its turn.
	for id in ["solid.inspect.measure", "solid.inspect.interference", "solid.inspect.zebra_analysis", "solid.inspect.draft_analysis",
			"solid.inspect.curvature_map_analysis", "solid.inspect.isocurve_analysis", "solid.inspect.environment_map",
			"solid.inspect.accessibility_analysis", "solid.inspect.minimum_radius_analysis", "solid.inspect.section_analysis",
			"solid.inspect.curvature_comb_analysis", "solid.inspect.center_of_mass", "solid.inspect.display_component_colors",
			"solid.modify.appearance", "solid.modify.physical_material", "solid.modify.manage_materials",
			"utilities.utility.appearance", "utilities.utility.physical_material", "sketch.inspect.measure",
			"solid.modify.texture_map_controls", "utilities.utility.texture_map_controls"]:
		check(CATALOG.is_enabled(CATALOG.find(id)), "%s should be enabled." % id)
	check(CATALOG.is_enabled(CATALOG.find("solid.create.create_form")) and CATALOG.is_enabled(CATALOG.find("mesh.modify.remesh"))
		and CATALOG.is_enabled(CATALOG.find("solid.assemble.joint")) and not CATALOG.is_enabled(CATALOG.find("sheet_metal.create.flange")),
		"Create Form (Phase 6) and Mesh tools (Phase 7) should be enabled, Joint (Phase 8) enabled, and Flange (Phase 9) disabled.")

	# Two 20 x 20 x 10 mm boxes, the second 15 mm along X: they share 5 x 10 x 20 mm.
	var body_a: String = await _box(ws, tree, Vector3.ZERO)
	var body_b: String = await _box(ws, tree, Vector3(0.015, 0.0, 0.0))
	check(ws.result.bodies.size() == 2, "Two boxes should be built (%s)." % [ws.result.errors])
	ws.viewport.fit()
	await tree.process_frame
	var shape_a: RefCounted = ws.result.bodies[body_a].shape
	var top := _face(shape_a, Vector3.UP)
	var bottom := _face(shape_a, Vector3.DOWN)
	var right := _face(shape_a, Vector3.RIGHT)

	# Measure: the top face picked on screen, the bottom face from a reference.
	var version := history.get_version()
	ws.run_tool(CATALOG.find("solid.inspect.measure"))
	check(ws.command != null and ws.panel.active_selection_key == "first", "Measure should open with its First slot active.")
	check(ws._active_kinds().has("face") and ws._active_kinds().has("edge") and ws._active_kinds().has("plane"), "Measure should pick faces, edges and planes (%s)." % [ws._active_kinds()])
	# Looking straight down, close in, so the click is well away from edges and origin axes.
	var on_top := Vector3(-0.005, 0.01, -0.005)
	ws.viewport.look_from(Vector3.UP)
	ws.viewport.set_view_state({"target": on_top, "distance": 0.03})
	await tree.process_frame
	_click(ws, ws.viewport.project(on_top))
	var first: Array = ws.command_values.get("first", [])
	check(first.size() == 1 and first[0].get("kind", "") == "face" and str(first[0].get("name", "")) == str(shape_a.get_face_names()[top]),
		"Clicking the top face should pick it as First (%s)." % [first])
	ws._on_reference_picked(REFERENCES.from_pick({"kind": "face", "body": body_a, "index": bottom}, ws.result))
	ws.refresh_view()
	var text: String = ws.panel.info("result")
	check(text.contains("Distance: 10 mm") and text.contains("Angle: 0 deg"), "Measure should show 10 mm and 0 deg between top and bottom (%s)." % text)
	var measured: Dictionary = ws.command.measured
	check(absf(float(measured.get("distance", 0.0)) - 0.01) < 1e-6 and absf((measured.point_a as Vector3).y - 0.01) < 1e-6 and absf((measured.point_b as Vector3).y) < 1e-6,
		"The distance line should run from the top face down to the bottom one (%s)." % [measured])
	ws.panel.activate_selection("second")
	ws._on_reference_picked(REFERENCES.from_pick({"kind": "face", "body": body_a, "index": bottom}, ws.result))
	ws._on_reference_picked(REFERENCES.from_pick({"kind": "face", "body": body_a, "index": right}, ws.result))
	ws.refresh_view()
	text = ws.panel.info("result")
	check(text.contains("Distance: 0 mm") and text.contains("Angle: 90 deg"), "Top and side faces should touch at 90 deg (%s)." % text)
	ws.accept_command()
	await tree.process_frame
	check(ws.command == null and history.get_version() == version and doc.features.size() == 2, "Measure should close without changing the design.")

	# Interference: one clash of 1000 mm3; Create Bodies adds it as a body in one undo step.
	ws.run_tool(CATALOG.find("solid.inspect.interference"))
	var clashes: Array = ws.command.clashes if ws.command != null else []
	check(clashes.size() == 1 and absf(float(clashes[0].volume) * 1e9 - 1000.0) < 1e-3, "Interference should find one 1000 mm3 clash (%s)." % [clashes])
	text = ws.panel.info("result")
	check(text.contains("1 interference") and text.contains("1000 mm³"), "The panel should list the clash and its volume (%s)." % text)
	check(ws.viewport.command_mesh_count() == 1, "The clash should be shown in the view.")
	ws.panel.button_pressed.emit("create")
	await tree.process_frame
	check(ws.command == null and ws.viewport.command_mesh_count() == 0, "Create Bodies should close the command and its overlap display.")
	check(ws.result.bodies.size() == 3, "Create Bodies should add the overlap as a third body (%s)." % [ws.result.bodies.keys()])
	var created := ""
	for body_id in ws.result.bodies:
		if body_id != body_a and body_id != body_b:
			created = body_id
	_volume(ws, created, 1000.0, "The overlap body")
	history.undo()
	await tree.process_frame
	check(ws.result.bodies.size() == 2, "One undo should take the overlap body away.")
	# Create Components: the overlap body goes into a new component, "Interference 1".
	version = history.get_version()
	ws.run_tool(CATALOG.find("solid.inspect.interference"))
	ws.panel.button_pressed.emit("create_components")
	await tree.process_frame
	check(ws.command == null and ws.viewport.command_mesh_count() == 0, "Create Components should close the command and its overlap display.")
	check(ws.result.bodies.size() == 3 and history.get_version() == version + 1, "Create Components should add the overlap body in one undo step (%s)." % [ws.result.bodies.keys()])
	created = ""
	for body_id in ws.result.bodies:
		if body_id != body_a and body_id != body_b:
			created = body_id
	var named: Array = doc.components.keys().filter(func(id: String) -> bool: return str(doc.components[id].get("name", "")) == "Interference 1")
	check(named.size() == 1 and created != "" and doc.body_component(created) == named[0], "The overlap body should sit in the one component named Interference 1 (%s)." % [doc.components])
	check(_tree_has(ws.browser, "Interference 1") and named.size() == 1 and part.component_nodes().has(named[0]), "Interference 1 should be listed and baked as its own node.")
	_volume(ws, created, 1000.0, "The overlap component's body")
	history.undo()
	await tree.process_frame
	check(ws.result.bodies.size() == 2 and doc.components.is_empty(), "One undo should take the component and its body away (%s)." % [doc.components])

	# Zebra analysis: added while its panel is open, kept by OK, listed in the browser.
	ws.run_tool(CATALOG.find("solid.inspect.zebra_analysis"))
	check(doc.analyses.size() == 1 and _shader_of(ws, body_a) == ANALYSIS.ZEBRA_SHADER, "Zebra should show on the bodies while its panel is open.")
	_set_value(ws, "stripes", "20")
	check(doc.analyses.size() == 1 and float(doc.analyses[0].options.get("stripes", 0)) == 20.0, "The stripes option should follow the panel (%s)." % [doc.analyses])
	ws.accept_command()
	await tree.process_frame
	var zebra_id := str(doc.analyses[0].id) if doc.analyses.size() == 1 else ""
	check(_tree_has(ws.browser, "Zebra1") and _shader_of(ws, body_a) == ANALYSIS.ZEBRA_SHADER, "Zebra1 should be listed and shown.")
	# The eye, rename and delete are one undo step each and rebuild nothing (nor do undo and redo).
	var rebuilds: int = ws.rebuild_count
	version = history.get_version()
	ws.browser.analysis_visibility_toggled.emit(zebra_id)
	await tree.process_frame
	check(not bool(doc.analyses[0].visible) and ws.viewport.body_surface(body_a).material_override == ws.viewport.surface_material(), "The eye should hide the zebra stripes.")
	check(history.get_version() == version + 1 and ws.rebuild_count == rebuilds, "The eye should be one undo step without a rebuild (%d rebuilds)." % (ws.rebuild_count - rebuilds))
	history.undo()
	await tree.process_frame
	check(_shader_of(ws, body_a) == ANALYSIS.ZEBRA_SHADER and ws.rebuild_count == rebuilds, "Undoing the eye should bring the stripes back without a rebuild.")
	history.redo()
	await tree.process_frame
	check(not bool(doc.analyses[0].visible) and ws.viewport.body_surface(body_a).material_override == ws.viewport.surface_material() and ws.rebuild_count == rebuilds,
		"Redoing the eye should hide them again without a rebuild.")
	# The browser's own eye button shows them again.
	var zebra_item: TreeItem = ws.browser.item_for("analysis", zebra_id)
	check(zebra_item != null, "The browser should list Zebra1 as an item.")
	if zebra_item != null:
		ws.browser.button_clicked.emit(zebra_item, 0, BROWSER.BUTTON_EYE, MOUSE_BUTTON_LEFT)
	await tree.process_frame
	check(_shader_of(ws, body_a) == ANALYSIS.ZEBRA_SHADER and bool(doc.analyses[0].visible) and ws.rebuild_count == rebuilds, "The eye button should show the zebra stripes again without a rebuild.")
	version = history.get_version()
	ws.rename_analysis(zebra_id, "Stripes")
	await tree.process_frame
	check(_tree_has(ws.browser, "Stripes") and history.get_version() == version + 1 and ws.rebuild_count == rebuilds, "Renaming should list Stripes, one undo step, no rebuild.")
	history.undo()
	await tree.process_frame
	check(_tree_has(ws.browser, "Zebra1") and ws.rebuild_count == rebuilds, "Undoing the rename should bring Zebra1 back without a rebuild.")
	ws.delete_analysis(zebra_id)
	await tree.process_frame
	check(doc.analyses.is_empty() and ws.viewport.body_surface(body_a).material_override == ws.viewport.surface_material(), "Deleting Zebra1 should take its stripes away.")
	history.undo()
	await tree.process_frame
	check(doc.analyses.size() == 1 and _shader_of(ws, body_a) == ANALYSIS.ZEBRA_SHADER and ws.rebuild_count == rebuilds, "Undoing the delete should bring the zebra back, all without a rebuild (%d rebuilds)." % (ws.rebuild_count - rebuilds))
	ws.edit_analysis(zebra_id)
	check(ws.command != null and ws.command.editing and str(ws.command_values.get("stripes", "")) == "20", "Editing Zebra1 should open it with its stripes (%s)." % [ws.command_values])
	ws.cancel_command()
	await tree.process_frame
	check(doc.analyses.size() == 1, "Cancelling an edit should keep the analysis.")

	# Section analysis across the YZ plane, 5 mm over: it wins over the zebra and caps the cut.
	ws.run_tool(CATALOG.find("solid.inspect.section_analysis"))
	ws._on_reference_picked({"kind": "origin", "name": "yz"})
	_set_value(ws, "offset", "5")
	var section: Dictionary = doc.analyses[doc.analyses.size() - 1]
	var normal: Vector3 = section.options.get("normal", Vector3.ZERO)
	var origin: Vector3 = section.options.get("origin", Vector3.ZERO)
	check(absf(absf(normal.x) - 1.0) < 1e-6 and origin.is_equal_approx(normal * 0.005), "The section plane should be the YZ plane moved 5 mm (%s, %s)." % [normal, origin])
	check(ws.viewport.handles.any(func(h: Dictionary) -> bool: return h.get("key", "") == "offset"), "An arrow should drag the section offset.")
	check(not _handle(ws, "angle", "tilt").is_empty() and not _handle(ws, "angle", "spin").is_empty(), "Angle handles should turn the section (Tilt and Spin).")
	# Tilt 90 deg turns the clip plane's normal straight down.
	_set_value(ws, "tilt", "90")
	section = doc.analyses[doc.analyses.size() - 1]
	var turned: Basis = ANALYSIS.section_basis(section.options.normal, section.options.get("x", Vector3.ZERO), float(section.options.get("tilt", 0.0)), float(section.options.get("spin", 0.0)))
	var clip := _clip_normal(ws, body_a)
	check(absf(float(section.options.get("tilt", 0.0)) - PI * 0.5) < 1e-6 and turned.z.is_equal_approx(Vector3.DOWN) and clip.is_equal_approx(Vector3.DOWN),
		"Tilt 90 should turn the section normal down (%s, clip %s)." % [turned.z, clip])
	# Dragging the Tilt dot round by 30 deg tilts the plane 30 deg further about the handle's axis.
	var tilt_handle := _handle(ws, "angle", "tilt")
	if not tilt_handle.is_empty():
		ws.viewport.manipulator_changed.emit(tilt_handle, float(tilt_handle.base) + deg_to_rad(30.0))
		var dragged := _clip_normal(ws, body_a)
		var expected: Vector3 = clip.rotated((tilt_handle.axis as Vector3).normalized(), deg_to_rad(30.0))
		check(str(ws.command_values.get("tilt", "")).begins_with("120") and dragged.is_equal_approx(expected),
			"Dragging Tilt 30 deg should give 120 deg and turn the clip normal 30 deg about its axis (%s, %s, expected %s)." % [ws.command_values.get("tilt"), dragged, expected])
	_set_value(ws, "tilt", "0")
	_set_value(ws, "spin", "0")
	ws.accept_command()
	await tree.process_frame
	check(_tree_has(ws.browser, "Section1") and _shader_of(ws, body_a) == ANALYSIS.SECTION_SHADER, "Section1 should be listed and clip the bodies.")
	check(int(ws.viewport.analysis_counts().nodes) >= 1 and ws.analysis_text(str(section.id)).contains("Section area"), "The section should cap the cut (%s)." % ws.analysis_text(str(section.id)))
	rebuilds = ws.rebuild_count
	history.undo()
	await tree.process_frame
	check(doc.analyses.size() == 1 and not _tree_has(ws.browser, "Section1") and _shader_of(ws, body_a) == ANALYSIS.ZEBRA_SHADER, "Undo should remove the section analysis.")
	check(ws.rebuild_count == rebuilds, "Undoing the section should rebuild nothing.")
	ws.delete_analysis(zebra_id)
	await tree.process_frame
	check(doc.analyses.is_empty() and ws.viewport.body_surface(body_a).material_override == ws.viewport.surface_material(), "Deleting the zebra should restore the bodies.")

	# Draft: the pull direction comes from a picked face, Flip turns it round.
	ws.run_tool(CATALOG.find("solid.inspect.draft_analysis"))
	ws._on_reference_picked(REFERENCES.from_pick({"kind": "face", "body": body_a, "index": top}, ws.result))
	var draft: Dictionary = doc.analyses[0] if doc.analyses.size() == 1 else {}
	check((draft.get("options", {}).get("pull", Vector3.ZERO) as Vector3).is_equal_approx(Vector3.UP), "Draft should pull along the picked top face's normal (%s)." % [draft])
	_set_value(ws, "flip", true)
	check((draft.get("options", {}).get("pull", Vector3.ZERO) as Vector3).is_equal_approx(Vector3.DOWN), "Flip should turn the pull round.")
	check(ws.viewport.body_surface(body_a).mesh != null and ws.viewport.body_surface(body_a).mesh.surface_get_format(0) & Mesh.ARRAY_FORMAT_COLOR != 0,
		"Draft should show vertex-colored bodies.")
	ws.cancel_command()
	await tree.process_frame
	check(doc.analyses.is_empty(), "Cancelling Draft should take its entry out.")

	# Every other analysis shows without errors, and Cancel takes its entry out again.
	for tool_id in ["curvature_map_analysis", "isocurve_analysis", "environment_map", "accessibility_analysis", "minimum_radius_analysis", "curvature_comb_analysis"]:
		ws.run_tool(CATALOG.find("solid.inspect." + tool_id))
		var entry_id: String = str(ws.command.entry_id) if ws.command != null else ""
		var shown: Dictionary = ws.analysis_results.get(entry_id, {})
		check(doc.analyses.size() == 1 and not shown.is_empty() and str(shown.error) == "", "%s should show without errors (%s)." % [tool_id, shown])
		if tool_id == "environment_map":
			check(_probe_covers(ws, [body_a, body_b]), "The environment map should add a reflection probe over both bodies (%s)." % [ws.viewport.reflection_probe()])
		elif tool_id == "isocurve_analysis":
			# Combs on: their rows show; boxes have only flat faces, so there is nothing to comb.
			_set_value(ws, "comb", true)
			shown = ws.analysis_results.get(entry_id, {})
			check(bool(doc.analyses[0].options.get("comb", false)) and bool(ws.panel._row_nodes["comb_density"].visible) and bool(ws.panel._row_nodes["comb_scale"].visible),
				"Curvature Combs should show their density and scale rows.")
			check(str(shown.get("error", "?")) == "" and str(shown.get("info", "")).contains("0 isocurves"), "Combs on boxes should show 0 isocurves without errors (%s)." % [shown])
		ws.cancel_command()
		await tree.process_frame
		check(doc.analyses.is_empty(), "Cancelling %s should take its entry out." % tool_id)
		if tool_id == "environment_map":
			check(ws.viewport.reflection_probe() == null, "Cancelling the environment map should take its probe away.")

	# Environment Map kept: its probe goes with the eye and with Delete.
	ws.run_tool(CATALOG.find("solid.inspect.environment_map"))
	ws.accept_command()
	await tree.process_frame
	var environment_id := str(doc.analyses[0].id) if doc.analyses.size() == 1 else ""
	check(_probe_covers(ws, [body_a, body_b]), "The kept environment map should keep its probe.")
	ws.browser.analysis_visibility_toggled.emit(environment_id)
	await tree.process_frame
	check(ws.viewport.reflection_probe() == null, "Hiding the environment map should take its probe away.")
	ws.browser.analysis_visibility_toggled.emit(environment_id)
	await tree.process_frame
	check(_probe_covers(ws, [body_a, body_b]), "Showing it again should bring the probe back.")
	ws.delete_analysis(environment_id)
	await tree.process_frame
	check(doc.analyses.is_empty() and ws.viewport.reflection_probe() == null, "Deleting the environment map should take its probe away.")

	# Display Component Colors with Shift+N: on, then off.
	var key := InputEventKey.new()
	key.keycode = KEY_N
	key.shift_pressed = true
	key.pressed = true
	ws.handle_key(key)
	await tree.process_frame
	check(doc.analyses.size() == 1 and doc.analyses[0].type == "component_colors" and ws.viewport.body_surface(body_a).material_override is StandardMaterial3D
		and (ws.viewport.body_surface(body_a).material_override as StandardMaterial3D).albedo_color == ANALYSIS.TOP_LEVEL_COLOR, "Shift+N should show component colors.")
	ws.handle_key(key)
	await tree.process_frame
	check(not bool(doc.analyses[0].visible), "Shift+N again should hide them.")

	# A zebra and the colors stay on through a box edit (the colors, added last, show on top).
	ws.delete_analysis(str(doc.analyses[0].id))
	ws.run_tool(CATALOG.find("solid.inspect.zebra_analysis"))
	ws.accept_command()
	await tree.process_frame
	var stripes_id := str(doc.analyses[doc.analyses.size() - 1].id)
	ws.handle_key(key)
	await tree.process_frame
	var colors_id := str(doc.analyses[doc.analyses.size() - 1].id)
	check(doc.analyses.size() == 2 and str(doc.analyses[1].type) == "component_colors" and _colored(ws, body_a), "Shift+N should add the colors over the zebra.")
	var box_a_feature := str(doc.bodies[body_a].get("feature", ""))
	ws.edit_feature(box_a_feature)
	_set_value(ws, "length", "30")
	ws.accept_command()
	await tree.process_frame
	check(absf(_box_length(ws, body_a) - 0.03) < 1e-6, "Box A should be 30 mm long (%s)." % _box_length(ws, body_a))
	check(_shows(ws, stripes_id) and _shows(ws, colors_id) and _colored(ws, body_a), "The zebra and component colors should stay on through the box edit (%s)." % [ws.analysis_results])
	history.undo()
	await tree.process_frame
	check(absf(_box_length(ws, body_a) - 0.02) < 1e-6 and _colored(ws, body_a), "Undo should put box A back with the colors still on.")
	# Shift+N inside the box edit, then Cancel: the colors go off, the box stays as it was.
	ws.edit_feature(box_a_feature)
	_set_value(ws, "length", "35")
	ws.handle_key(key)
	ws.cancel_command()
	await tree.process_frame
	check(not _visible(doc, colors_id) and absf(_box_length(ws, body_a) - 0.02) < 1e-6, "Cancel should keep Shift+N (colors off) and put the box back.")
	history.undo()
	await tree.process_frame
	check(_visible(doc, colors_id) and absf(_box_length(ws, body_a) - 0.02) < 1e-6, "One undo should revert only the Shift+N.")
	# Shift+N inside the box edit, then OK: both stay; the undo steps come back in order.
	ws.edit_feature(box_a_feature)
	_set_value(ws, "length", "35")
	ws.handle_key(key)
	ws.accept_command()
	await tree.process_frame
	check(not _visible(doc, colors_id) and absf(_box_length(ws, body_a) - 0.035) < 1e-6 and _shader_of(ws, body_a) == ANALYSIS.ZEBRA_SHADER, "OK should keep the new size with the colors off.")
	history.undo()
	await tree.process_frame
	check(not _visible(doc, colors_id) and absf(_box_length(ws, body_a) - 0.02) < 1e-6, "Undo should restore the box and keep the colors off.")
	history.undo()
	await tree.process_frame
	check(_visible(doc, colors_id) and _colored(ws, body_a), "A second undo should bring the colors back.")
	# Back as before: colors hidden, no zebra.
	ws.handle_key(key)
	ws.delete_analysis(stripes_id)
	await tree.process_frame
	check(doc.analyses.size() == 1 and not _visible(doc, colors_id), "Only the hidden component colors should be left.")

	# Appearance: a face of box A, then the whole of box B.
	ws.run_action("appearance")
	check(ws.appearance_panel.visible and ws.appearance_panel.library_ids().has(RED) and ws.appearance_panel.library_ids().size() >= 11, "The Appearance panel should list the library.")
	check(ws.viewport.body_surface(body_a).mesh.get_surface_count() == 1, "Box A should start with one surface.")
	check(ws.appearance_panel._apply_to.selected == 0, "Apply To should start on Bodies.")
	ws.appearance_panel._apply_to.select(1)
	_select(ws, {"kind": "face", "body": body_a, "index": top, "point": Vector3.ZERO})
	ws.appearance_panel.select_id(RED)
	ws.appearance_panel.apply_selected()
	await tree.process_frame
	ws.appearance_panel._apply_to.select(0)
	var face_target: String = APPEARANCE.face_target(body_a, str(ws.result.bodies[body_a].shape.get_face_names()[top]))
	check(doc.appearances.has(face_target), "The top face should get its own appearance (%s)." % [doc.appearances.keys()])
	var view_mesh: Mesh = ws.viewport.body_surface(body_a).mesh
	var baked: MeshInstance3D = part.body_nodes().get(body_a)
	check(view_mesh.get_surface_count() == 2 and view_mesh.surface_get_material(1) == MATERIAL_LIBRARY.material(RED), "The view should show the red face as a second surface.")
	check(baked != null and baked.mesh.get_surface_count() == 2, "The baked body should have two surfaces too.")
	# Bodies (the default): clicking a face of box B colors the whole box.
	_select(ws, {"kind": "face", "body": body_b, "index": _face(ws.result.bodies[body_b].shape, Vector3.UP), "point": Vector3.ZERO})
	ws.appearance_panel.select_id(CHROME)
	ws.appearance_panel.apply_selected()
	await tree.process_frame
	check(not doc.appearances.keys().any(func(key: Variant) -> bool: return str(key).begins_with("face:%s:" % body_b)), "Bodies mode should not give box B's face its own appearance (%s)." % [doc.appearances.keys()])
	view_mesh = ws.viewport.body_surface(body_b).mesh
	var baked_b: MeshInstance3D = part.body_nodes().get(body_b)
	check(doc.appearances.has(APPEARANCE.body_target(body_b)) and view_mesh.get_surface_count() == 1 and view_mesh.surface_get_material(0) == MATERIAL_LIBRARY.material(CHROME),
		"Box B should show chrome on its one surface.")
	check(baked_b != null and baked_b.mesh.get_surface_count() == 1 and baked_b.mesh.surface_get_material(0) == MATERIAL_LIBRARY.material(CHROME), "The baked box B should be chrome.")

	# Texture Map Controls on the red face: arrows, the turn dot and the anchor drag its mapping.
	var top_b := _face(ws.result.bodies[body_b].shape, Vector3.UP)
	ws.change("Texture Mapping", func() -> void: doc.appearances[APPEARANCE.body_target(body_b)]["mapping"] = {"scale": Vector2(0.05, 0.05), "type": "box"})
	_select(ws, {"kind": "face", "body": body_a, "index": top, "point": Vector3.ZERO})
	var baked_uvs := _uvs(part.body_nodes()[body_a].mesh, 1)
	ws.run_tool(CATALOG.find("solid.modify.texture_map_controls"))
	var handle_keys: Array = ws.viewport.handles.map(func(h: Dictionary) -> String: return str(h.get("key", "")))
	check(ws.command != null and ws.command.title() == "Texture Map Controls" and str(ws.command.get("target_key")) == face_target and str(ws.command_values.get("scale_u", "")) == "100",
		"Texture Map Controls should open on the red face's own mapping (%s)." % [ws.command_values])
	check(handle_keys.has("scale_u") and handle_keys.has("scale_v") and handle_keys.has("rotation") and handle_keys.has("anchor"), "It should show scale, turn and anchor handles (%s)." % [handle_keys])
	var span_before := _uv_span(ws.viewport.body_surface(body_a).mesh, 1)
	check(span_before.is_equal_approx(Vector2(0.2, 0.2)), "The 20 mm face should span 0.2 repeats of 100 mm (%s)." % span_before)
	var arrow := _handle(ws, "arrow", "scale_u")
	if not arrow.is_empty():
		ws._on_manipulator_changed(arrow, float(arrow.base) + 0.02 * float(arrow.factor))
	var mapping: Dictionary = doc.appearances[face_target].get("mapping", {})
	check((mapping.get("scale", Vector2.ZERO) as Vector2).is_equal_approx(Vector2(0.12, 0.1)), "Dragging Scale U 20 mm should make the repeat 120 mm (%s)." % [mapping])
	check(_uv_span(ws.viewport.body_surface(body_a).mesh, 1).is_equal_approx(Vector2(0.02 / 0.12, 0.2)), "The view should show the longer repeat at once (%s)." % _uv_span(ws.viewport.body_surface(body_a).mesh, 1))
	var turn := _handle(ws, "angle", "rotation")
	if not turn.is_empty():
		ws._on_manipulator_changed(turn, float(turn.base) + 0.3)
	mapping = doc.appearances[face_target].get("mapping", {})
	check(absf(float(mapping.get("rotation", 0.0)) - 0.3) < 1e-5, "Dragging the turn dot 0.3 rad should turn the texture as much (%s)." % [mapping])
	var anchor := _handle(ws, "point", "anchor")
	if not anchor.is_empty():
		ws._on_manipulator_changed(anchor, (anchor.position as Vector3) + (ws.command._frame().u as Vector3) * 0.5)
	mapping = doc.appearances[face_target].get("mapping", {})
	check((mapping.get("offset", Vector2.ONE) as Vector2).distance_to(Vector2(-0.5, 0.0)) < 1e-4 and not ws.command_values.has("anchor"),
		"Dragging the anchor half a repeat along U should slide the texture with it (%s)." % [mapping])
	# A new pick edits the entry that pick reads: box B's top face reads box B's own mapping.
	ws.panel.activate_selection("target")
	ws._on_reference_picked(REFERENCES.from_pick({"kind": "face", "body": body_b, "index": top_b}, ws.result))
	check(str(ws.command.get("target_key")) == APPEARANCE.body_target(body_b) and str(ws.command_values.get("scale_u", "")) == "50" and str(ws.command_values.get("type", "")) == "box",
		"Picking box B's face should edit box B's mapping (%s, %s)." % [ws.command.get("target_key"), ws.command_values])
	ws.cancel_command()
	await tree.process_frame
	check((doc.appearances[face_target].get("mapping", {}) as Dictionary).is_empty() and doc.appearances[APPEARANCE.body_target(body_b)].mapping == {"scale": Vector2(0.05, 0.05), "type": "box"},
		"Cancel should put both mappings back (%s)." % [doc.appearances])
	check(_uv_span(ws.viewport.body_surface(body_a).mesh, 1).is_equal_approx(span_before), "Cancel should put the view's texture back (%s)." % _uv_span(ws.viewport.body_surface(body_a).mesh, 1))
	# OK: the new scale and turn are baked, one undo step.
	version = history.get_version()
	_select(ws, {"kind": "face", "body": body_a, "index": top, "point": Vector3.ZERO})
	ws.run_tool(CATALOG.find("solid.modify.texture_map_controls"))
	arrow = _handle(ws, "arrow", "scale_v")
	if not arrow.is_empty():
		ws._on_manipulator_changed(arrow, float(arrow.base) + 0.02 * float(arrow.factor))
	turn = _handle(ws, "angle", "rotation")
	if not turn.is_empty():
		ws._on_manipulator_changed(turn, float(turn.base) + 0.3)
	var view_uvs := _uvs(ws.viewport.body_surface(body_a).mesh, 1)
	ws.accept_command()
	await tree.process_frame
	mapping = doc.appearances[face_target].get("mapping", {})
	var new_baked := _uvs(part.body_nodes()[body_a].mesh, 1)
	check((mapping.get("scale", Vector2.ZERO) as Vector2).is_equal_approx(Vector2(0.1, 0.12)) and absf(float(mapping.get("rotation", 0.0)) - 0.3) < 1e-5 and history.get_version() == version + 1,
		"OK should keep the 120 mm V repeat and the turn as one undo step (%s)." % [mapping])
	check(not _same_uvs(new_baked, baked_uvs) and _same_uvs(new_baked, view_uvs) and _same_uvs(_uvs(ws.viewport.body_surface(body_a).mesh, 1), view_uvs),
		"The baked face should get the previewed UVs.")
	history.undo()
	await tree.process_frame
	check((doc.appearances[face_target].get("mapping", {}) as Dictionary).is_empty() and _same_uvs(_uvs(part.body_nodes()[body_a].mesh, 1), baked_uvs),
		"One undo should put the mapping and the baked UVs back.")
	history.undo()
	await tree.process_frame
	check((doc.appearances[APPEARANCE.body_target(body_b)].get("mapping", {}) as Dictionary).is_empty(), "Undo should clear box B's mapping again.")
	# The Appearance panel's button starts Texture Map Controls too.
	ws.appearance_panel.open_texture_map()
	check(ws.command != null and ws.command.title() == "Texture Map Controls", "The Appearance panel should start Texture Map Controls.")
	ws.cancel_command()
	await tree.process_frame
	_select(ws, {"kind": "face", "body": body_a, "index": top, "point": Vector3.ZERO})
	ws.set_appearance_mapping(ws.appearance_targets(), {"scale": Vector2(0.05, 0.05), "type": "planar"})
	mapping = doc.appearances[face_target].get("mapping", {})
	check(mapping.get("scale") == Vector2(0.05, 0.05) and mapping.get("type") == "planar", "The face's texture mapping should change (%s)." % [mapping])
	history.undo()
	await tree.process_frame
	check((doc.appearances[face_target].get("mapping", {}) as Dictionary).is_empty(), "Undo should put the mapping back.")
	# The panel's mapping editors: a 20 mm U repeat typed for the selected face.
	var panel = ws.appearance_panel
	panel.refresh()
	panel._scale[0].text = "20"
	panel._scale[0].text_submitted.emit("20")
	mapping = doc.appearances[face_target].get("mapping", {})
	check((mapping.get("scale", Vector2.ZERO) as Vector2).is_equal_approx(Vector2(0.02, 0.1)) and not mapping.has("offset"), "Typing a U scale should change only the scale (%s)." % [mapping])
	# Typed axis and origin (document units) change only themselves; their rows show for placed types.
	panel.refresh()
	check(panel._placed_rows.all(func(row: Control) -> bool: return not row.visible), "Automatic mapping should hide the Origin and Axis rows.")
	panel._axis[2].text = "1"
	panel._axis[2].text_submitted.emit("1")
	mapping = doc.appearances[face_target].get("mapping", {})
	check(mapping.get("axis") == Vector3(0, 0, 1) and mapping.size() == 2, "Typing an axis should set only the axis (%s)." % [mapping])
	panel.refresh()
	panel._origin[0].text = "10"
	panel._origin[0].text_submitted.emit("10")
	mapping = doc.appearances[face_target].get("mapping", {})
	check((mapping.get("origin", Vector3.ZERO) as Vector3).is_equal_approx(Vector3(0.01, 0, 0)) and mapping.size() == 3, "Typing an origin X of 10 mm should set only the origin (%s)." % [mapping])
	ws.set_appearance_mapping(ws.appearance_targets(), {"type": "planar"})
	panel.refresh()
	check(panel._placed_rows.all(func(row: Control) -> bool: return row.visible), "Planar mapping should show the Origin and Axis rows.")
	# Manage Materials: the chrome on box B becomes blue paint everywhere it is used.
	ws.run_action("manage_materials")
	check(panel.visible and panel.manage and panel._used_ids.has(CHROME) and panel._used_ids.has(RED), "Manage Materials should list the design's appearances (%s)." % [panel._used_ids])
	panel._used_list.select(panel._used_ids.find(CHROME))
	panel.select_id("builtin:paint_blue")
	check(panel.replace_used(panel.selected_id()) == 1 and doc.appearances[APPEARANCE.body_target(body_b)].material == "builtin:paint_blue", "Replace should swap chrome for blue paint.")
	await tree.process_frame
	check(ws.viewport.body_surface(body_b).mesh.surface_get_material(0) == MATERIAL_LIBRARY.material("builtin:paint_blue"), "Box B should show the blue paint.")
	ws.appearance_panel.visible = false

	# Physical Material: aluminum on box A; Center of Mass reports the lighter mass.
	var steel: float = INSPECT.mass_properties(doc, ws.result, [body_a]).mass
	check(absf(steel - 4e-6 * 7850.0) < 4e-6 * 7850.0 * 1e-6, "Box A should start as steel (%s kg)." % steel)
	_select(ws, {"kind": "body", "body": body_a, "index": -1, "point": Vector3.ZERO})
	ws.run_tool(CATALOG.find("solid.modify.physical_material"))
	check(ws.command_values.get("bodies", []) == [body_a], "Physical Material should start with the selected body (%s)." % [ws.command_values])
	_set_value(ws, "material", "Aluminum")
	check(ws.panel.info("result").contains("With Aluminum: 0.0108 kg"), "The panel should show the new mass (%s)." % ws.panel.info("result"))
	ws.accept_command()
	await tree.process_frame
	check(str(doc.physical_materials.get("body:" + body_a, "")) == "Aluminum", "Box A should be aluminum (%s)." % [doc.physical_materials])
	ws.run_tool(CATALOG.find("solid.inspect.center_of_mass"))
	text = ws.panel.info("result")
	check(ws.command != null and absf(float(ws.command.props.mass) - 4e-6 * 2700.0) < 4e-6 * 2700.0 * 1e-6 and text.contains("Mass: 0.0108 kg") and text.contains("(Aluminum)"),
		"Center of Mass should report the aluminum mass (%s)." % text)
	check(text.contains("Center: (0, 5, 0) mm"), "Box A's center of mass should be its middle (%s)." % text)
	_set_value(ws, "keep", true)
	var analyses_before: int = doc.analyses.size()
	ws.accept_command()
	await tree.process_frame
	check(doc.analyses.size() == analyses_before + 1 and doc.analyses[analyses_before].type == "center_of_mass" and int(ws.viewport.analysis_counts().points) == 1,
		"Keep in Analysis should add a Center of Mass analysis showing its point.")

	# Isocurve combs on a cylinder: the circles get teeth, and the readout gives the curvature.
	ws.run_tool(CATALOG.find("solid.create.cylinder"))
	_set_value(ws, "diameter", "10")
	_set_value(ws, "height", "10")
	_set_value(ws, "position", Vector3(0.1, 0.0, 0.0))
	ws.accept_command()
	await tree.process_frame
	ws.run_tool(CATALOG.find("solid.inspect.isocurve_analysis"))
	var iso_id: String = str(ws.command.entry_id) if ws.command != null else ""
	var lines_before: int = int(ws.viewport.analysis_counts().nodes)
	_set_value(ws, "comb", true)
	var iso: Dictionary = ws.analysis_results.get(iso_id, {})
	check(bool(doc.analyses[doc.analyses.size() - 1].options.get("comb", false)) and str(iso.get("error", "?")) == "" and str(iso.get("info", "")).contains("largest curvature")
		and int(ws.viewport.analysis_counts().nodes) >= maxi(lines_before, 1), "Combs on the cylinder's isocurves should show its largest curvature (%s)." % [iso])
	ws.cancel_command()
	await tree.process_frame
	history.undo()
	await tree.process_frame

	# A split piece of box B takes a physical material of its own; box B stays steel.
	var bodies_before: Array = ws.result.bodies.keys()
	ws.selection.clear()
	ws._selection_changed(true)
	ws.run_tool(CATALOG.find("solid.modify.split_body"))
	ws.panel.activate_selection("body")
	ws._on_reference_picked({"kind": "body", "body": body_b})
	ws.panel.activate_selection("tool")
	ws._on_reference_picked({"kind": "origin", "name": "xy"})
	ws.recompute()
	ws.accept_command()
	await tree.process_frame
	var piece := ""
	for body_id in ws.result.bodies:
		if not bodies_before.has(body_id):
			piece = body_id
	check(piece.begins_with(body_b + "."), "Splitting box B through the XY plane should make a piece of it (%s, %s)." % [ws.result.bodies.keys(), ws.result.errors])
	_select(ws, {"kind": "body", "body": piece, "index": -1, "point": Vector3.ZERO})
	ws.run_tool(CATALOG.find("solid.modify.physical_material"))
	_set_value(ws, "material", "Aluminum")
	ws.accept_command()
	await tree.process_frame
	check(doc.physical_materials.has("body:" + piece) and not doc.physical_materials.has("body:" + body_b), "The piece should get its own material key (%s)." % [doc.physical_materials])
	var props: Dictionary = INSPECT.mass_properties(doc, ws.result, [piece, body_b])
	check(str(props.bodies.get(piece, {}).get("material", "")) == "Aluminum" and str(props.bodies.get(body_b, {}).get("material", "")) == "Steel",
		"The piece should weigh as aluminum and box B as steel (%s)." % [props.bodies])
	ws.selection.clear()
	ws.run_tool(CATALOG.find("solid.inspect.center_of_mass"))
	text = ws.panel.info("result")
	check(text.contains("(Aluminum)") and text.contains("(Steel)"), "Center of Mass should list the piece as aluminum and box B as steel (%s)." % text)
	ws.cancel_command()
	_finish(tree)


func _box(ws, tree: SceneTree, position: Vector3) -> String:
	ws.run_tool(CATALOG.find("solid.create.box"))
	_set_value(ws, "length", "20")
	_set_value(ws, "width", "20")
	_set_value(ws, "height", "10")
	_set_value(ws, "position", position)
	var feature: Resource = ws.command.feature
	ws.accept_command()
	await tree.process_frame
	return str(feature.options.get("body_id", ""))


func _face(shape: RefCounted, normal: Vector3) -> int:
	for f in shape.face_count():
		var info: Dictionary = shape.face_info(f)
		if info.get("planar", false) and (info.normal as Vector3).is_equal_approx(normal):
			return f
	return -1


func _select(ws, pick: Dictionary) -> void:
	ws.selection.clear()
	ws.selection.append(pick)
	ws._selection_changed(true)


func _shader_of(ws, body_id: String) -> Shader:
	var surface: MeshInstance3D = ws.viewport.body_surface(body_id)
	var material := surface.material_override as ShaderMaterial if surface != null else null
	return material.shader if material != null else null


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
	if ws._is_inspect(ws.command):
		ws.refresh_view()
	else:
		ws.recompute()


func _volume(ws, body_id: String, expected_mm3: float, label: String) -> void:
	var shape = ws.result.get("bodies", {}).get(body_id, {}).get("shape")
	var v: float = float(shape.volume()) * 1e9 if shape != null else -1.0
	check(shape != null and absf(v - expected_mm3) < expected_mm3 * 1e-6, "%s: %s mm3 expected, got %s." % [label, expected_mm3, v])


## The view handle of a type with a key ({} when there is none).
func _handle(ws, type: String, key: String) -> Dictionary:
	for h in ws.viewport.handles:
		if str(h.get("type", "")) == type and str(h.get("key", "")) == key:
			return h
	return {}


## The section clip plane's normal on a body's view material (ZERO when it isn't clipped).
func _clip_normal(ws, body_id: String) -> Vector3:
	var material := ws.viewport.body_surface(body_id).material_override as ShaderMaterial
	return material.get_shader_parameter("plane_normal") if material != null and material.shader == ANALYSIS.SECTION_SHADER else Vector3.ZERO


## True when the view's reflection probe covers every body's bounds.
func _probe_covers(ws, body_ids: Array) -> bool:
	var probe: ReflectionProbe = ws.viewport.reflection_probe()
	if probe == null:
		return false
	var box := AABB(probe.position - probe.size * 0.5, probe.size)
	for body_id in body_ids:
		if not box.encloses(ws.result.bodies[body_id].shape.bbox()):
			return false
	return true


func _box_length(ws, body_id: String) -> float:
	var body: Dictionary = ws.result.get("bodies", {}).get(body_id, {})
	return (body.shape.bbox() as AABB).size.x if not body.is_empty() else -1.0


func _shows(ws, analysis_id: String) -> bool:
	var r: Dictionary = ws.analysis_results.get(analysis_id, {})
	return not r.is_empty() and str(r.error) == ""


func _visible(doc: Resource, analysis_id: String) -> bool:
	for entry in doc.analyses:
		if str(entry.get("id", "")) == analysis_id:
			return bool(entry.get("visible", true))
	return false


## True when a body shows in component colors (top level).
func _colored(ws, body_id: String) -> bool:
	var material := ws.viewport.body_surface(body_id).material_override as StandardMaterial3D
	return material != null and material.albedo_color == ANALYSIS.TOP_LEVEL_COLOR


## One mesh surface's texture coordinates.
func _uvs(mesh: Mesh, surface: int) -> PackedVector2Array:
	if mesh == null or surface >= mesh.get_surface_count():
		return PackedVector2Array()
	var arrays := mesh.surface_get_arrays(surface)
	return arrays[Mesh.ARRAY_TEX_UV] if arrays[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()


## How many texture repeats a surface spans along U and V.
func _uv_span(mesh: Mesh, surface: int) -> Vector2:
	var uvs := _uvs(mesh, surface)
	if uvs.is_empty():
		return Vector2(-1, -1)
	var lo := uvs[0]
	var hi := uvs[0]
	for uv in uvs:
		lo = lo.min(uv)
		hi = hi.max(uv)
	return hi - lo


func _same_uvs(a: PackedVector2Array, b: PackedVector2Array) -> bool:
	if a.size() != b.size() or a.is_empty():
		return false
	for i in a.size():
		if a[i].distance_to(b[i]) > 1e-5:
			return false
	return true


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
		print("PASS Holo Forge INSPECT EDITOR: Phase 4 inspect/appearance tools enabled (Create Form and Mesh on, Phase 8 Joint on, Phase 9 Flange off); measure of two box faces (one screen-picked) shows distance and angle without changing the design; interference lists the 1000 mm3 clash, Create Bodies adds it and Create Components puts it in Interference 1 (each undoable); zebra and section analyses listed, shown on the view's bodies, eye (and its tree button), rename, delete, undo and redo without a rebuild, edit; section tilt turns the clip normal down and its angle handle turns it 30 deg; draft pull from a picked face with flip; every other analysis shows without errors and cancels cleanly, the environment map's reflection probe covers the bodies and goes with cancel, eye and delete, isocurve combs show on a cylinder; Shift+N component colors stay on with a zebra through box edits, also pressed inside an edit then cancelled or accepted; face and body appearances change view and baked surfaces, mapping edit undoable; Texture Map Controls drags scale, turn and offset with a live view, Cancel restores mapping and view, OK bakes the new UVs as one undo step, a new pick edits the entry it reads; panel origin/axis fields and its Texture Map Controls button; aluminum physical material changes the Center of Mass mass, kept as an analysis point; a split piece gets its own aluminum while its source stays steel")
	else:
		print("FAIL Holo Forge INSPECT EDITOR: ", failures)
	tree.quit(0 if failures.is_empty() else 1)
