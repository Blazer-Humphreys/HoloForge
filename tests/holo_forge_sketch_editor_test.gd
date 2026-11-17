@tool
extends RefCounted
## Holo Forge sketch mode inside the real editor (never saves the test scene): Create Sketch on
## the ground plane opens the Sketch toolbar; tools placed by clicks make geometry with live
## previews and one undo step each; Measure (I) runs over the open sketch, picks its corner on
## screen and gives back the same half-placed tool on Enter or Escape, without an undo step or a
## rebuild; Curvature Comb kept over the sketch is one undo step without a rebuild, a cancelled
## Canvas changes nothing and a sketch key closes Measure; a chained line shares its corner;
## Sketch Dimension's preview follows the mouse (horizontal or vertical by where it is) and Esc
## steps back; its value box opens with the measured value, and a value typed into it sizes the
## line in one undo step (undo takes the parameter too); it is drawn as a drafting dimension its
## text picks; a click on it while another dimension's box is open puts its parameter in the
## box, which keeps the keyboard; an over-constraining dimension, answered yes, is added driven
## in one step;
## constraints apply from the toolbar; Fully Define leaves nothing free; Trim removes a
## segment; sketch items are picked on screen; the Line tool's heads-up length field takes real
## key events (Enter locks it, the segment and its length are one step, the view gets the keyboard
## back), and so do a rectangle's width and height and a circle's diameter; Finish Sketch and double-click editing work; and a
## flat box face can be picked as a sketch plane. The sketch palette floats: real mouse events
## through the editor drag it by its title and resize it from its grip and edge without reaching
## the view, its checkboxes and collapse arrow still work, it saves to a test store (the user's
## project metadata stays as it was) and it opens where it was left when the sketch is edited
## again.
##
## godot --headless --path . --editor -- --holo-forge-sketch-editor-test

const CATALOG := preload("res://addons/holo_forge/tools/catalog.gd")
const SKETCH := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const FLOATING := preload("res://addons/holo_forge/ui/floating_panel.gd")

var failures: Array[String] = []
var _mouse := Vector2.ZERO


func check(ok: bool, detail: String) -> void:
	if not ok:
		failures.append(detail)
		push_error(detail)
		print("FAIL: ", detail)


func run(plugin: EditorPlugin) -> void:
	var tree := plugin.get_tree()
	tree.create_timer(300.0).timeout.connect(func() -> void:
		print("FAIL Holo Forge SKETCH EDITOR: timed out ", failures)
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
	var editor = ws.sketch_editor
	var history: UndoRedo = ws.history()

	# Create Sketch on the ground (XZ) plane.
	var feature: Resource = ws.create_sketch(SKETCH.ORIGIN_PLANES.xz, "xz")
	check(feature != null and editor.active and editor.feature_id == feature.id, "Create Sketch should open sketch mode on the new sketch.")
	var create: MenuButton = ws.toolbar.group_menu("Create")
	var labels := []
	if create != null:
		for i in create.get_popup().item_count:
			labels.append(create.get_popup().get_item_text(i))
	check(labels.any(func(l: String) -> bool: return l.begins_with("Line")) and labels.any(func(l: String) -> bool: return l.begins_with("Sketch Dimension")),
		"The Sketch toolbar's CREATE menu should list Line and Sketch Dimension.")
	check(ws.toolbar.group_menu("Constraints") != null and ws.toolbar.group_menu("Finish") != null, "The Sketch toolbar should have CONSTRAINTS and FINISH menus.")
	check(ws.tool_for_key("L").get("name", "") == "Line" and ws.tool_for_key("D").get("name", "") == "Sketch Dimension", "L and D should be Line and Sketch Dimension in a sketch.")
	await _check_palette(ws, editor, tree)
	var palette_layout: Dictionary = editor.palette.get_layout()

	# A 2-point rectangle by two clicks: one undo step, one profile.
	ws.run_tool(CATALOG.find("sketch.create.2-point_rectangle"))
	check(editor.tool == "rect_2pt", "The 2-Point Rectangle tool should start (%s)." % editor.tool)
	editor.tool_click(Vector2(0, 0), {}, {})
	editor.mouse_plane = Vector2(0.04, 0.02)
	check(not editor._preview().is_empty(), "The rectangle should preview while the second corner follows the mouse.")
	editor.tool_click(Vector2(0.04, 0.02), {}, {})
	await tree.process_frame
	var regions: Array = ws.result.sketches[feature.id].regions
	check(regions.size() == 1 and absf(float(regions[0].area) - 0.0008) < 1e-9, "The rectangle should make one 40 x 20 mm profile.")
	var line_count := func() -> int: return editor.sketch().entities().filter(func(e: Dictionary) -> bool: return e.type == "line").size()
	check(line_count.call() == 4, "The rectangle adds 4 lines.")
	history.undo()
	await tree.process_frame
	check(line_count.call() == 0, "One undo should remove the whole rectangle (%d lines left)." % line_count.call())
	history.redo()
	await tree.process_frame
	check(line_count.call() == 4, "Redo should bring it back.")

	# Measure over the open sketch: a polygon tool waits half placed (8 sides typed, a line picked).
	var corner_a := _point_at(editor.sketch(), Vector2(0, 0))
	var corner_b := _point_at(editor.sketch(), Vector2(0.04, 0.02))
	editor.start_tool("polygon_inscribed")
	editor.tool_click(Vector2(0.12, 0), {}, {})
	var typed: Dictionary = ws.panel.values.duplicate(true)
	typed["sides"] = "8"
	ws.panel.set_values(typed)
	ws._on_panel_values_changed(typed)
	editor.selection.clear()
	editor.selection.append({"kind": "entity", "id": int(editor.sketch().entities().filter(func(e: Dictionary) -> bool: return e.type == "line")[0].id)})
	var tool_state := _tool_state(editor)
	var version := history.get_version()
	var features: int = doc.features.size()
	var rebuilds: int = ws.rebuild_count
	ws.viewport.look_from(Vector3.UP)
	ws.viewport.set_view_state({"target": Vector3(0.02, 0.0, -0.01), "distance": 0.12})
	await tree.process_frame
	for closing in [KEY_ENTER, KEY_ESCAPE]:
		ws.handle_key(_key(KEY_I))
		check(ws.command != null and editor.active and editor.suspended and ws.panel._title.text == "MEASURE", "I should start Measure over the open sketch (%s)." % ws.panel._title.text)
		var s0: RefCounted = editor.sketch()
		_click(ws, ws.viewport.project(s0.to_world(s0.point(corner_b))))
		var first: Array = ws.command_values.get("first", [])
		check(first.size() == 1 and str(first[0].get("kind", "")) == "sketch_point" and str(first[0].get("sketch", "")) == feature.id,
			"A click on the rectangle's corner should pick the open sketch's point (%s)." % [first])
		ws.panel.activate_selection("second")
		ws._on_reference_picked({"kind": "sketch_point", "sketch": feature.id, "entity": corner_a})
		ws.refresh_view()
		check(absf(float(ws.command.measured.get("distance", 0.0)) - Vector2(0.04, 0.02).length()) < 1e-6, "The corners should measure the diagonal (%s)." % [ws.command.measured])
		ws.handle_key(_key(closing))
		var how := "Enter" if closing == KEY_ENTER else "Escape"
		check(ws.command == null and editor.active and not editor.suspended and _tool_state(editor) == tool_state,
			"%s should close Measure and give the sketch back as it was (%s)." % [how, _tool_state(editor)])
		check(ws.panel.visible and ws.panel._title.text == "INSCRIBED POLYGON" and str(ws.panel.values.get("sides", "")) == "8",
			"The polygon's panel should come back with its 8 sides after %s (%s)." % [how, ws.panel._title.text])
		check(history.get_version() == version and doc.features.size() == features and ws.rebuild_count == rebuilds, "Measure should change and rebuild nothing (%s)." % how)
	# Curvature Comb over the sketch: OK keeps it as one undo step without a rebuild; undo too.
	ws.run_tool(CATALOG.find("sketch.inspect.curvature_comb_analysis"))
	var any_line := int(editor.sketch().entities().filter(func(e: Dictionary) -> bool: return e.type == "line")[0].id)
	ws._on_reference_picked({"kind": "sketch_curve", "sketch": feature.id, "entity": any_line})
	ws.accept_command()
	await tree.process_frame
	check(editor.active and doc.analyses.size() == 1 and history.get_version() == version + 1 and ws.rebuild_count == rebuilds,
		"Curvature Comb should keep its analysis over the open sketch without a rebuild.")
	history.undo()
	await tree.process_frame
	check(doc.analyses.is_empty() and editor.active and ws.rebuild_count == rebuilds, "Undoing the comb should keep the sketch open without a rebuild.")
	# Canvas cancelled over the sketch changes nothing; a sketch key closes Measure.
	version = history.get_version()
	ws.run_tool(CATALOG.find("sketch.insert.canvas"))
	ws.cancel_command()
	await tree.process_frame
	check(editor.active and history.get_version() == version and doc.canvases.is_empty(), "A cancelled Canvas should leave the sketch open and nothing changed.")
	ws.run_tool(CATALOG.find("sketch.inspect.measure"))
	ws.handle_key(_key(KEY_L))
	check(ws.command == null and editor.active and not editor.suspended and editor.tool == "line", "L should close Measure and start Line (%s)." % editor.tool)
	editor.cancel_tool()

	# A chained line: three clicks make two lines that share their middle point.
	editor.start_tool("line")
	editor.tool_click(Vector2(0.06, 0), {}, {})
	editor.tool_click(Vector2(0.09, 0), {}, {})
	editor.tool_click(Vector2(0.09, 0.03), editor.snap_at(Vector2.ZERO).snap if false else {}, {})
	editor.handle_key(_key(KEY_ESCAPE))
	var s: RefCounted = editor.sketch()
	var chain: Array = s.entities().filter(func(e: Dictionary) -> bool: return e.type == "line" and s.point(int(e.p1)).x > 0.05)
	check(chain.size() == 2 and int(chain[0].p2) == int(chain[1].p1), "A line chain's segments should share their corner.")

	# Sketch Dimension between the chain's two far ends: the preview follows the mouse over the
	# view (horizontal above them, vertical beside them); Esc drops the picks, then the tool.
	editor.start_tool("dimension")
	var far_a := int(chain[0].p1)
	var far_b := int(chain[1].p2)
	editor.tool_click(Vector2.ZERO, {}, {"kind": "entity", "id": far_a})
	editor.tool_click(Vector2.ZERO, {}, {"kind": "entity", "id": far_b})
	var seen_types := []
	for place in [Vector2(0.075, 0.05), Vector2(0.12, 0.015)]:
		var motion := InputEventMouseMotion.new()
		motion.position = ws.viewport.project(s.to_world(place))
		editor.handle_mouse(motion)
		ws.viewport._overlay.queue_redraw()
		await tree.process_frame
		await tree.process_frame
		seen_types.append(str(editor._preview_dimension.get("type", "")))
	check(seen_types == ["distance_x", "distance_y"], "The dimension preview should follow the mouse: horizontal above, vertical beside (%s)." % [seen_types])
	editor.handle_key(_key(KEY_ESCAPE))
	check(editor.tool == "dimension" and editor.tool_picks.is_empty(), "Esc should drop the dimension's picks and keep the tool.")
	editor.handle_key(_key(KEY_ESCAPE))
	check(editor.tool == "", "Esc again should end Sketch Dimension.")

	# Sketch Dimension: pick the first chain line, place the label, type 30 into the value box.
	var first_line := int(chain[0].id)
	editor.start_tool("dimension")
	editor.tool_click(Vector2(0.075, 0), {}, {"kind": "entity", "id": first_line})
	editor.mouse_plane = Vector2(0.075, -0.01)
	editor.tool_click(Vector2(0.075, -0.01), {}, {})
	check(not editor._pending_dimension.is_empty() and editor._pending_dimension.type == "length", "Placing a line's dimension should offer a length (%s)." % editor._pending_dimension)
	check(editor._edit.visible and editor._edit.text == "30 mm" and editor._edit.get_selected_text() == editor._edit.text,
		"The value box should open with the measured 30 mm selected (%s)." % editor._edit.text)
	editor._edit.text = "30"
	editor._edit.text_submitted.emit(editor._edit.text)
	await tree.process_frame
	s = editor.sketch()
	var dims: Array = s.constraints().filter(func(c: Dictionary) -> bool: return c.has("key"))
	var dim_line: Dictionary = s.entity(first_line)
	check(dims.size() == 1 and absf(s.point(int(dim_line.p1)).distance_to(s.point(int(dim_line.p2))) - 0.03) < 1e-7, "The line should become 30 mm long.")
	check(doc.model_parameters().any(func(p: Dictionary) -> bool: return p.expression == "30"), "The dimension should be a model parameter.")
	check(history.get_current_action_name() == "Forge: Sketch: Dimension" and not editor._edit.visible and editor.tool == "dimension",
		"Entering the value should be one 'Sketch: Dimension' step, the tool kept (%s)." % history.get_current_action_name())
	history.undo()
	await tree.process_frame
	check(editor.sketch().constraints().filter(func(c: Dictionary) -> bool: return c.has("key")).is_empty() and doc.model_parameters().is_empty(),
		"Undo should take the dimension and its parameter away.")
	history.redo()
	await tree.process_frame
	editor.cancel_tool()
	s = editor.sketch()
	dims = s.constraints().filter(func(c: Dictionary) -> bool: return c.has("key"))
	# It is drawn as a drafting dimension whose text and lines pick it.
	var view: Dictionary = ws.viewport.view_state()
	ws.viewport.set_view_state({"target": s.to_world(Vector2(0.075, -0.005)), "distance": 0.15})
	ws.viewport._overlay.queue_redraw()
	await tree.process_frame
	await tree.process_frame
	var dim_id := int(dims[0].id) if dims.size() == 1 else -1
	var drawn: Array = editor._dim_hits
	check(drawn.size() == 1 and (drawn[0].poly as PackedVector2Array).size() == 4 and not (drawn[0].segments as Array).is_empty()
		and editor.hit(drawn[0].text_center) == {"kind": "constraint", "id": dim_id} and editor._dim_draw_log.get(dim_id, {}).get("text", "") == "30.00",
		"The dimension should be drawn (30.00) with hit areas that pick it (%s)." % [drawn])
	# While a new dimension's box is open, a click on that dimension puts its parameter in the box,
	# and the box keeps the keyboard (the view takes it on the press, as a real click does).
	editor.start_tool("dimension")
	editor.tool_click(Vector2(0.09, 0.015), {}, {"kind": "entity", "id": int(chain[1].id)})
	editor.tool_click(Vector2(0.1, 0.015), {}, {})
	ws.viewport._overlay.queue_redraw()
	await tree.process_frame
	await tree.process_frame
	var dim_name := str(s.feature.inputs.get(str(dims[0].key), {}).get("name", "")) if dims.size() == 1 else "?"
	var dim_text: Array = editor._dim_hits.filter(func(entry: Dictionary) -> bool: return int(entry.id) == dim_id)
	# The editor can hand the keyboard to a script it reopens while it starts up (outside the Forge
	# tab): the box is given it back, all selected, as the user would click it, before the click.
	var owner_before: Control = editor._edit.get_viewport().gui_get_focus_owner()
	if editor._edit.visible and not editor._edit.has_focus():
		print("Forge sketch: before the click %s had the keyboard; the box takes it back." % [owner_before.get_path() if owner_before != null else "nothing"])
		editor._edit.grab_focus()
		editor._edit.select_all()
		await tree.process_frame
	if editor._edit.visible and not dim_text.is_empty():
		for pressed in [true, false]:
			var click := InputEventMouseButton.new()
			click.button_index = MOUSE_BUTTON_LEFT
			click.pressed = pressed
			click.position = dim_text[0].text_center
			editor.handle_mouse(click)
			if pressed:
				ws.viewport._overlay.grab_focus()
		await tree.process_frame
		await tree.process_frame
	check(editor._edit.visible and editor._edit.text.ends_with(dim_name) and editor._edit.has_focus(),
		"A click on a dimension while typing should put its name (%s) in the box and keep typing there (%s, focus %s, owner %s)." % [dim_name, editor._edit.text, editor._edit.has_focus(),
			editor._edit.get_viewport().gui_get_focus_owner().get_path() if editor._edit.get_viewport().gui_get_focus_owner() != null else "none"])
	editor.handle_key(_key(KEY_ESCAPE))
	check(not editor._edit.visible and editor.sketch().constraints().filter(func(c: Dictionary) -> bool: return c.has("key")).size() == 1, "Esc should drop the new dimension.")
	editor.cancel_tool()
	ws.viewport.set_view_state(view)
	# A second, clashing length: answered yes, it is added as a driven (reference) dimension.
	editor.driven_answer = "ok"
	editor.start_tool("dimension")
	editor.tool_click(Vector2(0.075, 0), {}, {"kind": "entity", "id": first_line})
	editor.tool_click(Vector2(0.075, -0.02), {}, {})
	await tree.process_frame
	s = editor.sketch()
	var driven: Array = s.constraints().filter(func(c: Dictionary) -> bool: return c.has("key") and not c.get("driving", true))
	check(driven.size() == 1 and not editor._edit.visible and absf(s.point(int(dim_line.p1)).distance_to(s.point(int(dim_line.p2))) - 0.03) < 1e-7,
		"An over-constraining dimension should be added driven, with no value box, and leave the line at 30 mm.")
	check(history.get_current_action_name() == "Forge: Sketch: Driven Dimension", "The driven dimension should be one step (%s)." % history.get_current_action_name())
	history.undo()
	await tree.process_frame
	check(editor.sketch().constraints().filter(func(c: Dictionary) -> bool: return c.has("key")).size() == 1, "Undo should take the driven dimension away.")
	history.redo()
	await tree.process_frame
	editor.driven_answer = ""
	editor.cancel_tool()

	# Constraints from the toolbar: make the second chain line vertical by picking it.
	editor.start_tool("constraint:horizontal_vertical")
	editor.tool_click(Vector2(0.09, 0.015), {}, {"kind": "entity", "id": int(chain[1].id)})
	await tree.process_frame
	s = editor.sketch()
	check(s.constraints().any(func(c: Dictionary) -> bool: return c.type == "vertical" and (c.refs as Array) == [int(chain[1].id)]), "Horizontal/Vertical should add Vertical to an upright line.")
	editor.cancel_tool()

	# Fully Define, then nothing can move.
	editor.fully_define()
	await tree.process_frame
	check(int(ws.result.sketches[feature.id].solve.dof) == 0, "Fully Define should leave 0 degrees of freedom (%d)." % int(ws.result.sketches[feature.id].solve.dof))

	# Trim: a circle crossing the rectangle's right side loses its outside half.
	editor.start_tool("circle_center")
	editor.tool_click(Vector2(0.04, 0.01), {}, {})
	editor.tool_click(Vector2(0.045, 0.01), {}, {})
	await tree.process_frame
	s = editor.sketch()
	var circle_id := int(s.entities().filter(func(e: Dictionary) -> bool: return e.type == "circle")[0].id)
	editor.start_tool("trim")
	editor.tool_click(Vector2(0.045, 0.01), {}, {"kind": "entity", "id": circle_id})
	await tree.process_frame
	s = editor.sketch()
	check(s.entity(circle_id).is_empty() and s.entities().any(func(e: Dictionary) -> bool: return e.type == "arc"), "Trimming the outside of the circle should leave an arc.")
	editor.cancel_tool()

	# Picking on screen finds sketch items.
	ws.viewport.look_from(Vector3.UP)
	ws.viewport.fit()
	await tree.process_frame
	editor.refresh(ws.result)
	ws.viewport._overlay.queue_redraw()
	await tree.process_frame
	var corner_world: Vector3 = s.to_world(Vector2(0.04, 0.02))
	var screen: Vector2 = ws.viewport.project(corner_world)
	var hit: Dictionary = editor.hit(screen)
	check(hit.get("kind", "") == "entity" and s.entity(int(hit.id)).get("type", "") == "point", "A click on the rectangle's corner should pick its point (%s)." % hit)

	# Heads-up fields while drawing a line take real key events through the editor's GUI: 2, 5 and
	# Enter lock a 25 mm length; the segment comes with its driving length in one step and the view
	# gets the keyboard back. Undone after.
	await _check_heads_up(ws, editor, tree, history)
	# The same fields on a rectangle (width, Tab, height) and a circle (diameter), real keys again.
	await _check_heads_up_shapes(ws, editor, tree, history)

	# Finish Sketch, then edit it again from the timeline.
	ws.run_action("finish_sketch")
	check(not editor.active and ws.toolbar.group_menu("Constraints") == null, "Finish Sketch should leave sketch mode.")
	ws.edit_feature(feature.id)
	check(editor.active and editor.feature_id == feature.id, "Editing the sketch from the timeline should reopen it.")
	await tree.process_frame
	check(editor.palette.get_layout() == palette_layout and ws.viewport.get_global_rect().grow(0.5).encloses(editor.palette.get_global_rect()),
		"The palette should open where it was left, inside the view (%s, was %s)." % [editor.palette.get_layout(), palette_layout])
	ws.run_action("finish_sketch")

	# A box's top face as a sketch plane.
	ws.run_tool(CATALOG.find("solid.create.box"))
	var values: Dictionary = ws.command_values.duplicate(true)
	values.position = Vector3(0.3, 0, 0)
	values.length = "40"
	values.width = "40"
	values.height = "20"
	ws._on_panel_values_changed(values)
	await tree.process_frame
	ws.accept_command()
	await tree.process_frame
	ws.viewport.look_from(Vector3(0.2, 1, 0.3))
	ws.viewport.target = Vector3(0.3, 0.02, 0)
	ws.viewport.distance = 0.3
	ws.viewport._update_camera()
	await tree.process_frame
	var top_screen: Vector2 = ws.viewport.project(Vector3(0.3, 0.02, 0))
	var plane: Dictionary = ws.plane_at(top_screen)
	var normal: Vector3 = (plane.get("frame", {}).get("x", Vector3.ZERO) as Vector3).cross(plane.get("frame", {}).get("y", Vector3.ZERO))
	check(str(plane.get("ref", "")).begins_with("face:") and normal.is_equal_approx(Vector3.UP) and absf(float((plane.frame.origin as Vector3).y) - 0.02) < 1e-6,
		"The box's top face should give an upward sketch plane at 20 mm (%s)." % plane)

	# Project / Include tools against the box, in a sketch on a plane above it.
	var box_body: String = doc.features[doc.features.size() - 1].options.body_id
	var box_shape = ws.result.bodies[box_body].shape
	var top_face := -1
	for f in box_shape.face_count():
		var info: Dictionary = box_shape.face_info(f)
		if info.get("planar", false) and (info.normal as Vector3).is_equal_approx(Vector3.UP):
			top_face = f
	var above: Resource = ws.create_sketch({"origin": Vector3(0, 0.05, 0), "x": Vector3.RIGHT, "y": Vector3.FORWARD}, "test")
	var count_of := func(predicate: Callable) -> int: return editor.sketch().entities().filter(predicate).size()
	editor.start_tool("project")
	editor.add_3d_pick({"kind": "face", "body": box_body, "index": top_face})
	editor.tool_ok()
	await tree.process_frame
	check(count_of.call(func(e: Dictionary) -> bool: return e.type == "line" and e.get("projected", false)) == 4, "Projecting the box's top face should add 4 fixed purple lines.")
	check(ws.result.sketches[above.id].regions.size() == 1, "The projected outline is a closed profile in the sketch.")
	editor.start_tool("include3d")
	editor.add_3d_pick({"kind": "face", "body": box_body, "index": top_face})
	editor.tool_ok()
	await tree.process_frame
	check(count_of.call(func(e: Dictionary) -> bool: return e.type == "ref3d") == 1, "Include 3D Geometry should add a 3D reference.")
	editor.start_tool("isocurve")
	editor.add_3d_pick({"kind": "face", "body": box_body, "index": top_face})
	editor.tool_ok()
	await tree.process_frame
	var isos: Array = editor.sketch().entities().filter(func(e: Dictionary) -> bool: return e.type == "ref3d" and str(e.source).begins_with("isocurve"))
	check(isos.size() == 1 and (isos[0].polylines as Array).size() == 3, "Isoparametric Curve should add 3 U lines on the face.")
	# Sketch a circle, select it, and wrap it onto the top face / cut it into the face.
	editor.start_tool("circle_center")
	editor.tool_click(Vector2(0.3, 0), {}, {})
	editor.tool_click(Vector2(0.305, 0), {}, {})
	await tree.process_frame
	var ring_id := int(editor.sketch().entities().filter(func(e: Dictionary) -> bool: return e.type == "circle")[0].id)
	for kind in ["project_surface", "intersection_curve"]:
		editor.selection.clear()
		editor.selection.append({"kind": "entity", "id": ring_id})
		editor.start_tool(kind)
		editor.add_3d_pick({"kind": "face", "body": box_body, "index": top_face})
		editor.tool_ok()
		await tree.process_frame
		var made: Array = editor.sketch().entities().filter(func(e: Dictionary) -> bool: return e.type == "ref3d" and str(e.source).begins_with("surface" if kind == "project_surface" else "intersection"))
		var on_face: bool = made.size() == 1 and not (made[0].polylines as Array).is_empty() and (made[0].polylines as Array).all(func(line: PackedVector3Array) -> bool:
			return line.size() > 2 and absf(line[0].y - 0.02) < 1e-6)
		check(on_face, "%s should put the circle onto the box's top face (%s)." % [kind, made])
	ws.run_action("finish_sketch")

	# Intersect and Spun Profile need a sketch through the body: the box's middle, upright.
	var middle: Resource = ws.create_sketch({"origin": Vector3(0.3, 0, 0), "x": Vector3.RIGHT, "y": Vector3.UP}, "test")
	editor.start_tool("intersect")
	editor.add_3d_pick({"kind": "body", "body": box_body, "index": -1})
	editor.tool_ok()
	await tree.process_frame
	check(count_of.call(func(e: Dictionary) -> bool: return e.type == "line" and e.get("projected", false)) == 4, "Intersect through the box's middle should add its 4-line section.")
	var axis := int(SKETCH.new(middle, doc).entities().size())
	editor.start_tool("centerline")
	editor.tool_click(Vector2(0, 0), {}, {})
	editor.tool_click(Vector2(0, 0.05), {}, {})
	await tree.process_frame
	var axis_line := int(editor.sketch().entities().filter(func(e: Dictionary) -> bool: return e.get("centerline", false))[0].id)
	editor.start_tool("spun_profile")
	editor.tool_click(Vector2(0, 0.01), {}, {"kind": "entity", "id": axis_line})
	editor.add_3d_pick({"kind": "body", "body": box_body, "index": -1})
	editor.tool_ok()
	await tree.process_frame
	var spun: Array = editor.sketch().entities().filter(func(e: Dictionary) -> bool: return e.type == "spline" and e.get("projected", false))
	check(spun.size() == 1 and axis >= 0, "Spun Profile should add the box's outline around the axis as a fixed spline.")
	ws.run_action("finish_sketch")
	_finish(tree)


## The Line tool's heads-up length field with real key events pushed into the editor's GUI.
func _check_heads_up(ws, editor: RefCounted, tree: SceneTree, history: UndoRedo) -> void:
	var gui: Viewport = ws.viewport.get_viewport()
	var overlay: Control = ws.viewport.overlay()
	var s: RefCounted = editor.sketch()
	var lines_before: int = s.entities().filter(func(e: Dictionary) -> bool: return e.type == "line").size()
	editor.start_tool("line")
	editor.tool_click(Vector2(-0.06, -0.03), {}, {})
	var motion := InputEventMouseMotion.new()
	motion.position = ws.viewport.project(s.to_world(Vector2(-0.03, -0.02)))
	editor.handle_mouse(motion)
	ws.viewport.focus_view()
	await tree.process_frame
	if not overlay.has_focus():
		var owner: Control = gui.gui_get_focus_owner()
		print("Forge sketch: before typing %s had the keyboard; the view takes it back." % [owner.get_path() if owner != null else "nothing"])
		overlay.grab_focus()
		await tree.process_frame
	for key in [[KEY_2, "2"], [KEY_5, "5"], [KEY_ENTER, ""]]:
		for pressed in [true, false]:
			var event := InputEventKey.new()
			event.keycode = key[0]
			event.physical_keycode = key[0]
			event.unicode = (key[1] as String).unicode_at(0) if pressed and key[1] != "" else 0
			event.pressed = pressed
			gui.push_input(event)
			await tree.process_frame
	var box: LineEdit = editor._heads_up.length
	check(box.visible and box.has_focus() and box.text == "25" and bool(editor._heads_up_state.length.locked) and absf(float(editor._heads_up_state.length.value) - 0.025) < 1e-12,
		"Typed 2, 5 and Enter should lock a 25 mm length in the heads-up box (text '%s', focus %s, %s)." % [box.text, box.has_focus(), editor._heads_up_state.length])
	editor.tool_click(Vector2(-0.03, -0.02), {}, {})
	await tree.process_frame
	s = editor.sketch()
	var lines: Array = s.entities().filter(func(e: Dictionary) -> bool: return e.type == "line")
	var made: Dictionary = lines[lines.size() - 1] if lines.size() == lines_before + 1 else {}
	var dims: Array = s.constraints().filter(func(c: Dictionary) -> bool: return not made.is_empty() and c.has("key") and (c.refs as Array) == [int(made.id)])
	check(not made.is_empty() and absf(s.point(int(made.p1)).distance_to(s.point(int(made.p2))) - 0.025) < 1e-7 and dims.size() == 1 and dims[0].type == "length",
		"The segment should be 25 mm with a driving length (%s, %s)." % [made, dims])
	check(history.get_current_action_name() == "Forge: Sketch: Line" and not box.visible and overlay.has_focus(),
		"The segment and its length should be one 'Sketch: Line' step and the view should get the keyboard back (%s, focus %s)." % [history.get_current_action_name(),
			gui.gui_get_focus_owner().get_path() if gui.gui_get_focus_owner() != null else "none"])
	editor.handle_key(_key(KEY_ESCAPE))
	editor.cancel_tool()
	history.undo()
	await tree.process_frame
	check(editor.sketch().entities().filter(func(e: Dictionary) -> bool: return e.type == "line").size() == lines_before, "Undo should take the segment and its dimension away.")


## Heads-up fields on a 2-point rectangle (2, 0, Enter, Tab, 1, 0, Enter) and a centre-diameter
## circle (1, 2, Enter) with real key events pushed into the editor's GUI: each is placed with its
## driving dimensions in one step and the view gets the keyboard back. Both undone after.
func _check_heads_up_shapes(ws, editor: RefCounted, tree: SceneTree, history: UndoRedo) -> void:
	var gui: Viewport = ws.viewport.get_viewport()
	var overlay: Control = ws.viewport.overlay()
	var cases := [
		{"tool": "rect_2pt", "start": Vector2(-0.08, 0.04), "mouse": Vector2(-0.06, 0.05), "keys": [[KEY_2, "2"], [KEY_0, "0"], [KEY_ENTER, ""], [KEY_TAB, ""], [KEY_1, "1"], [KEY_0, "0"], [KEY_ENTER, ""]],
			"type": "line", "made": 4, "dims": ["distance_x=20", "distance_y=10"]},
		{"tool": "circle_center", "start": Vector2(-0.07, 0.08), "mouse": Vector2(-0.06, 0.08), "keys": [[KEY_1, "1"], [KEY_2, "2"], [KEY_ENTER, ""]],
			"type": "circle", "made": 1, "dims": ["diameter=12"]},
	]
	for case: Dictionary in cases:
		var s: RefCounted = editor.sketch()
		var before_ids: Array = s.entities().map(func(e: Dictionary) -> int: return int(e.id))
		var before_constraints: Array = s.constraints().map(func(c: Dictionary) -> int: return int(c.id))
		editor.start_tool(case.tool)
		editor.tool_click(case.start, {}, {})
		var motion := InputEventMouseMotion.new()
		motion.position = ws.viewport.project(s.to_world(case.mouse))
		editor.handle_mouse(motion)
		ws.viewport.focus_view()
		await tree.process_frame
		if not overlay.has_focus():
			overlay.grab_focus()
			await tree.process_frame
		for key: Array in case.keys:
			for pressed in [true, false]:
				var event := InputEventKey.new()
				event.keycode = key[0]
				event.physical_keycode = key[0]
				event.unicode = (key[1] as String).unicode_at(0) if pressed and key[1] != "" else 0
				event.pressed = pressed
				gui.push_input(event)
				await tree.process_frame
		await tree.process_frame
		s = editor.sketch()
		var made: Array = s.entities().filter(func(e: Dictionary) -> bool: return e.type == case.type and not before_ids.has(int(e.id)))
		var dims: Array = s.constraints().filter(func(c: Dictionary) -> bool: return c.has("key") and not before_constraints.has(int(c.id))).map(func(c: Dictionary) -> String:
			return "%s=%s" % [c.type, s.feature.inputs.get(c.key, {}).get("expression", "")])
		var title: String = editor._tool_title(case.tool)
		check(made.size() == int(case.made) and dims == case.dims and history.get_current_action_name() == "Forge: Sketch: " + title
			and not editor._heads_up_open() and overlay.has_focus(),
			"%s: the typed values should place it with driving %s in one step, the view getting the keyboard back (%d made, %s, %s, focus %s)." % [title, case.dims, made.size(), dims,
				history.get_current_action_name(), gui.gui_get_focus_owner().get_path() if gui.gui_get_focus_owner() != null else "none"])
		editor.cancel_tool()
		history.undo()
		await tree.process_frame
		check(editor.sketch().entities().size() == before_ids.size(), "%s: undo should take the shape and its dimensions away." % title)


## The palette moved and resized with real mouse events through the editor's GUI (the headless
## editor's view is small and changes size between runs, so every expectation is clamped to it).
func _check_palette(ws, editor: RefCounted, tree: SceneTree) -> void:
	var palette = editor.palette
	check(palette != null and palette.get_script() == FLOATING and palette.visible, "The sketch palette should be a floating panel shown in the sketch.")
	check(palette.get_store() == EditorInterface.get_editor_settings(), "In the editor the palette should save to the editor's project metadata.")
	var user_saved: Variant = EditorInterface.get_editor_settings().get_project_metadata("holo_forge", "sketch_palette", "unset")
	# From here on a test store, so the user's own palette place is never touched. It starts at
	# its minimum in the top-left corner.
	var store := ConfigFile.new()
	palette.set_store(store, "sketch_palette")
	palette.set_layout({"position": Vector2.ZERO, "size": Vector2(1, 1)})
	for i in 3:
		await tree.process_frame
	var gui: Viewport = palette.get_viewport()
	var view: Control = ws.viewport
	var minimum: Vector2 = palette.minimum_panel_size()
	check((palette.size - minimum.min(view.size)).length() < 0.75 and view.get_global_rect().grow(0.5).encloses(palette.get_global_rect()),
		"The palette should sit at its minimum inside the view (%s, minimum %s, view %s)." % [palette.size, minimum, view.size])
	var seen := {"count": 0}
	var counter := func(event: InputEvent) -> void:
		if event is InputEventMouse:
			seen.count += 1
	ws.viewport.overlay().gui_input.connect(counter)
	var view_before := str(ws.viewport.view_state())
	var selection_before := str(editor.selection)

	# Bigger from the grip, then wider from the right edge (as far as the view lets it).
	var size_before: Vector2 = palette.size
	var grip: Control = palette.get_grip()
	await _drag(gui, tree, grip.get_global_rect().get_center(), grip.get_global_rect().get_center() + Vector2(30, 40))
	var expected: Vector2 = (size_before + Vector2(30, 40)).min(view.size - palette.position)
	check((palette.size - expected).length() < 0.75 and palette.size != size_before, "The grip should resize the palette (%s, expected %s)." % [palette.size, expected])
	var edge: Control = palette.get_right_edge()
	expected = Vector2(minf(palette.size.x + 20.0, view.size.x - palette.position.x), palette.size.y)
	await _drag(gui, tree, edge.get_global_rect().get_center(), edge.get_global_rect().get_center() + Vector2(20, 0))
	check((palette.size - expected).length() < 0.75, "The right edge should widen it (%s, expected %s)." % [palette.size, expected])
	check(palette.get_scroll().get_v_scroll_bar().visible, "Near its minimum, the palette should scroll.")

	# Dragged by its title past the view's bottom-right corner, it stops in the corner.
	var at: Vector2 = palette.position
	var by: Vector2 = (view.size - palette.size - at).max(Vector2.ZERO)
	var title: Control = palette.get_title_bar()
	var from := title.get_global_rect().position + Vector2(title.size.x * 0.6, title.size.y * 0.5)
	await _drag(gui, tree, from, from + by + Vector2(300, 300))
	check((palette.position - (at + by)).length() < 0.75 and by.length() > 10.0, "Dragging the title should move the palette by %s into the corner (at %s, from %s)." % [by, palette.position, at])
	check(view.get_global_rect().grow(0.5).encloses(palette.get_global_rect()), "The palette should stay inside the view.")
	check(seen.count == 0 and str(ws.viewport.view_state()) == view_before and str(editor.selection) == selection_before and editor.tool == "",
		"Moving and resizing the palette should leave the view and the sketch alone (the view saw %d events)." % seen.count)
	var saved: Dictionary = store.get_value("holo_forge", "sketch_palette", {})
	check(saved.get("position", Vector2.INF) == palette.position and saved.get("size", Vector2.INF) == palette.size, "The palette's place should be saved in the store (%s)." % [saved])

	# A checkbox still works after the move, and a click on it doesn't reach the view.
	var check_box: CheckBox = editor._palette_checks["points"]
	palette.get_scroll().ensure_control_visible(check_box)
	for i in 2:
		await tree.process_frame
	var was: bool = editor.show.points
	_button(gui, check_box.get_global_rect().get_center(), true)
	_button(gui, check_box.get_global_rect().get_center(), false)
	await tree.process_frame
	check(editor.show.points == (not was) and seen.count == 0, "Show Points should toggle from a click after moving the palette (the view saw %d)." % seen.count)
	check_box.button_pressed = was
	# The arrow collapses it to its title bar and expands it again, inside the view.
	var open_size: Vector2 = palette.size
	for i in 2:
		var arrow: Control = palette.get_collapse_button()
		_button(gui, arrow.get_global_rect().get_center(), true)
		_button(gui, arrow.get_global_rect().get_center(), false)
		await tree.process_frame
		check(palette.collapsed == (i == 0) and view.get_global_rect().grow(0.5).encloses(palette.get_global_rect()),
			"The arrow should %s the palette inside the view (%s)." % ["collapse" if i == 0 else "expand", palette.get_global_rect()])
	check((palette.size - open_size).length() < 0.75 and bool(store.get_value("holo_forge", "sketch_palette", {}).get("collapsed", true)) == false,
		"Expanded again it should be its size, saved expanded (%s)." % palette.size)
	check(str(EditorInterface.get_editor_settings().get_project_metadata("holo_forge", "sketch_palette", "unset")) == str(user_saved), "The user's own saved palette place should be untouched.")
	# The view beside it still gets the mouse.
	var free := _free_view_point(view)
	check(free.is_finite(), "The view should have room beside the palette.")
	if free.is_finite():
		_move(gui, free)
		await tree.process_frame
		check(seen.count > 0, "The view beside the palette should still get the mouse (at %s)." % free)
	ws.viewport.overlay().gui_input.disconnect(counter)


## A point on the view that no panel, cube or bar covers (INF if there's none).
func _free_view_point(view: Control) -> Vector2:
	for row in range(1, 8):
		for col in range(1, 8):
			var point := view.get_global_rect().position + view.size * Vector2(col / 8.0, row / 8.0)
			var covered := false
			for child in view.get_children():
				var item := child as Control
				if item != null and item != view.call("overlay") and item.is_visible_in_tree() and item.mouse_filter != Control.MOUSE_FILTER_IGNORE \
						and item.get_global_rect().grow(4.0).has_point(point):
					covered = true
			if not covered:
				return point
	return Vector2.INF


func _drag(gui: Viewport, tree: SceneTree, from: Vector2, to: Vector2) -> void:
	_move(gui, from)
	_button(gui, from, true)
	for i in 6:
		_move(gui, from.lerp(to, (i + 1) / 6.0), MOUSE_BUTTON_MASK_LEFT)
	_button(gui, to, false)
	await tree.process_frame


func _button(gui: Viewport, at: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	event.position = at
	event.global_position = at
	_mouse = at
	gui.push_input(event, true)


func _move(gui: Viewport, to: Vector2, mask := 0) -> void:
	var event := InputEventMouseMotion.new()
	event.position = to
	event.global_position = to
	event.relative = to - _mouse
	event.button_mask = mask
	_mouse = to
	gui.push_input(event, true)


## The sketch tool's state: the tool, its placed points, picks, typed values and the selection.
func _tool_state(editor: RefCounted) -> Dictionary:
	return {"tool": editor.tool, "points": editor.tool_points.duplicate(true), "picks": editor.tool_picks.duplicate(true),
		"values": editor.tool_values.duplicate(true), "selection": editor.selection.duplicate(true)}


## The id of the sketch point (not the origin) at a sketch position, or -1.
func _point_at(s: RefCounted, at: Vector2) -> int:
	for e in s.entities():
		if e.type == "point" and not e.get("origin", false) and s.point(int(e.id)).distance_to(at) < 1e-7:
			return int(e.id)
	return -1


## A left click on the view, as the running command's picker sees it.
func _click(ws, at: Vector2) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = at
	ws.picker.handle_mouse(event)


func _key(keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	return event


func _finish(tree: SceneTree) -> void:
	for i in 4:
		await tree.process_frame
	if failures.is_empty():
		print("PASS Holo Forge SKETCH EDITOR: Create Sketch, Sketch toolbar and shortcuts, click tools with preview and one-step undo, Measure over the open sketch (screen-picked corner, diagonal, Enter/Escape give the half-placed polygon back, no undo step or rebuild), Curvature Comb over the sketch (one step, no rebuild, undo), cancelled Canvas, L closes Measure, line chains, dimension preview following the mouse, Esc stages, the value box (measured prefill, one step, undo takes the parameter, a dimension clicked while typing inserts its name and the box keeps the keyboard), driven dimensions by the question (one step, undo), constraints, Fully Define, trim, screen picking, heads-up length field (real keys, one step, keyboard back), rectangle and circle heads-up fields (real keys, one step each, undo), finish and re-edit, face sketch plane, project/intersect/include/isocurve/surface/intersection/spun-profile tools, floating palette (real-event drag, grip and edge resize, nothing reaches the view, checkboxes and collapse work, test store, user metadata untouched, same place on re-edit)")
	else:
		print("FAIL Holo Forge SKETCH EDITOR: ", failures)
	tree.quit(0 if failures.is_empty() else 1)
