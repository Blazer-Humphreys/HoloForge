@tool
extends RefCounted
## Holo Forge Phase 4 Insert, Canvas, Decal and Export inside the real editor (never saves the
## test scene; every file goes to user://holo_forge_insert_test, removed at the end): every tool
## up to Phase 4 is enabled and later ones are not; Insert SVG opens its file dialog, then a click
## on the ground plane inserts the SVG fixture as a sketch with its 3 profiles; the DXF fixture
## makes one sketch per layer (4 profiles) in one undo step; the STL cube and a STEP file exported
## from a box come in as bodies of the right volume with their file names on the timeline, and
## their chips open edit panels (units, offsets and angles, Choose File... picking an OBJ; OK is
## one undo step, Cancel changes nothing); a 3MF file in centimeters comes in through Insert Mesh
## and splits into a body per piece; a two-body derive edits which bodies come in (at least one)
## and switches design; a washer placed on the box's top face has the ISO volume, sits on the face
## and follows it when the box gets taller (until Place On is cleared), and changing its size from
## the timeline changes it; a canvas and a decal are listed in the browser, shown in the view
## (their eye, Delete and undo without a rebuild), the decal baked on the CadPart body (flipped:
## positive size, mirrored basis), the canvas panel scrolls in a short view and the canvas is
## calibrated from two clicked points;
## Insert Derive takes a saved design's body and Insert Component a Forge part's design from a
## scene, as a component; exporting STEP re-imports with the bodies' volume, components export as
## scenes, bodies as meshes, and board-model versions count up (in a temporary root, never the
## real Updated board models folder). Undo takes each insert out again.
##
## godot --headless --path . --editor -- --holo-forge-insert-editor-test

const CATALOG := preload("res://addons/holo_forge/tools/catalog.gd")
const SKETCH := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const INSERT := preload("res://addons/holo_forge/core/features/insert.gd")
const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")

const FIXTURES := "res://tests/holo_forge/fixtures/"
const TEMP := "user://holo_forge_insert_test"

var failures: Array[String] = []


func check(ok: bool, detail: String) -> void:
	if not ok:
		failures.append(detail)
		push_error(detail)
		print("FAIL: ", detail)


func run(plugin: EditorPlugin) -> void:
	var tree := plugin.get_tree()
	tree.create_timer(480.0).timeout.connect(func() -> void:
		print("FAIL Holo Forge INSERT EDITOR: timed out ", failures)
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
	_remove_temp()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEMP))

	# Every tool up to Phase 4 runs a command or an action; later phases stay disabled.
	var off := []
	for tool in CATALOG.all_tools():
		if int(tool.phase) <= 4 and not CATALOG.is_enabled(tool):
			off.append("%s/%s" % [tool.workspace, tool.name])
	check(off.is_empty(), "Every Phase 1-4 tool should be enabled (%s)." % [off])
	for id in ["solid.insert.insert_svg", "solid.insert.insert_dxf", "solid.insert.insert_mesh", "solid.insert.insert_step_iges",
			"solid.insert.insert_derive", "solid.insert.insert_component", "solid.insert.insert_fastener", "solid.insert.decal",
			"solid.insert.canvas", "solid.create.derive", "sketch.insert.insert_svg", "utilities.utility.export_step",
			"utilities.utility.export_iges", "utilities.utility.export_stl", "utilities.utility.export_components",
			"utilities.utility.export_body_meshes", "utilities.utility.save_board_model_version"]:
		check(CATALOG.is_enabled(CATALOG.find(id)), "%s should be enabled." % id)
	check(CATALOG.is_enabled(CATALOG.find("form.create.box")) and CATALOG.is_enabled(CATALOG.find("mesh.create.insert_mesh"))
		and CATALOG.is_enabled(CATALOG.find("solid.assemble.joint")) and not CATALOG.is_enabled(CATALOG.find("sheet_metal.create.flange")),
		"Form Box (Phase 6) and the Mesh workspace's Insert Mesh (Phase 7) should be enabled, Joint (Phase 8) enabled, and Flange (Phase 9) disabled.")

	# Insert SVG: the menu opens a file dialog; with the file chosen, a click on the ground plane.
	ws.run_tool(CATALOG.find("solid.insert.insert_svg"))
	var dialog: Window = ws.files._file_dialog
	check(dialog != null and dialog.visible, "Insert SVG should open a file dialog.")
	if dialog != null:
		dialog.hide()
	var version := history.get_version()
	var count: int = doc.features.size()
	ws.files.begin_sketch_file(FIXTURES + "import_shapes.svg", {})
	check(ws.is_picking_plane(), "Insert SVG should wait for a plane click.")
	ws.viewport.look_from(Vector3.UP)
	ws.viewport.set_view_state({"target": Vector3.ZERO, "distance": 0.2})
	await tree.process_frame
	var spot := Vector3(ws.viewport.origin_size() * 0.4, 0.0, ws.viewport.origin_size() * 0.4)
	ws.viewport.set_view_state({"target": spot, "distance": 0.2})
	await tree.process_frame
	ws._plane_pick_mouse(_press(ws.viewport.project(spot)))
	await tree.process_frame
	var svg: Resource = doc.features[doc.features.size() - 1] if doc.features.size() == count + 1 else null
	check(svg != null and svg.type == "sketch" and str(svg.options.get("plane_ref", "")) == "xz", "Clicking the ground plane should insert the SVG as a sketch on it (%s)." % ws.last_message)
	if svg != null:
		var state: Dictionary = ws.result.sketches.get(svg.id, {})
		check((state.get("regions", []) as Array).size() == 3, "The SVG sketch should have 3 profiles (%d)." % (state.get("regions", []) as Array).size())
		check(((state.get("plane", Transform3D()) as Transform3D).basis.z).is_equal_approx(Vector3.UP), "The SVG sketch should lie on the ground.")
		check(_tree_has(ws.browser, svg.label) and str(svg.options.get("source_file", "")).ends_with("import_shapes.svg"), "The SVG sketch should be listed and know its file.")
	check(history.get_version() == version + 1, "Insert SVG should be one undo step.")
	history.undo()
	await tree.process_frame
	check(doc.features.size() == count, "Undo should take the SVG sketch out.")

	# Insert DXF: one sketch per layer, all in one undo step.
	version = history.get_version()
	var dxf: Dictionary = ws.files.insert_sketch_file(FIXTURES + "import_shapes.dxf", SKETCH.ORIGIN_PLANES.xz, "xz", {"one_sketch_per_layer": true})
	var regions := 0
	for feature in dxf.get("features", []):
		regions += (ws.result.sketches.get(feature.id, {}).get("regions", []) as Array).size()
	check((dxf.get("features", []) as Array).size() == 4 and regions == 4 and history.get_version() == version + 1,
		"The DXF should make 4 layer sketches with 4 profiles in one step (%d sketches, %d profiles)." % [(dxf.get("features", []) as Array).size(), regions])
	history.undo()
	await tree.process_frame
	check(doc.features.size() == count, "Undo should take every DXF sketch out.")

	# Insert Mesh: the 10 mm STL cube; its timeline chip opens the Insert Mesh panel.
	var stl: Dictionary = ws.files.insert_mesh(FIXTURES + "cube_10mm.stl", "mm")
	var stl_feature: Resource = stl.get("feature")
	var stl_body := str(stl_feature.options.get("body_id", "")) if stl_feature != null else ""
	_volume(ws, stl_body, 1000.0, "The STL cube")
	check(_chip_with(ws, "cube_10mm.stl"), "The mesh's chip should show its file name (%s)." % [ws.timeline.chip_texts()])
	if stl_feature != null:
		ws.timeline.feature_edit_requested.emit(stl_feature.id)
		check(ws.command != null and ws.command.editing and ws.command.feature == stl_feature and ws.command.title() == "Insert Mesh"
			and ws.panel.info("source").contains("cube_10mm.stl"), "The mesh's chip should open the Insert Mesh panel (%s, %s)." % [ws.command, ws.panel.info("source")])
		# One file unit is a centimeter: a 10 cm cube; then 5 mm along X.
		_set_value(ws, "units", "cm")
		_volume(ws, stl_body, 1000000.0, "The STL cube in centimeters")
		_set_value(ws, "x", "5")
		check(absf(_bounds(ws, stl_body).position.x - 0.005) < 1e-6, "X 5 mm should move the cube 5 mm (%s)." % [_bounds(ws, stl_body)])
		version = history.get_version()
		ws.accept_command()
		await tree.process_frame
		check(ws.command == null and history.get_version() == version + 1 and _chip_with(ws, "cube_10mm.stl"), "OK should keep the edit as one undo step.")
		history.undo()
		await tree.process_frame
		_volume(ws, stl_body, 1000.0, "The STL cube after undoing its edit")
		# Cancel leaves the mesh as it was.
		ws.edit_feature(stl_feature.id)
		_set_value(ws, "units", "m")
		ws.cancel_command()
		await tree.process_frame
		_volume(ws, stl_body, 1000.0, "The STL cube after a cancelled edit")
		# Choose File...: the dialog opens; the OBJ picked in it replaces the file and names the body.
		ws.edit_feature(stl_feature.id)
		_set_value(ws, "units", "cm")
		ws.panel.button_pressed.emit("browse")
		check(ws.files._file_dialog != null and ws.files._file_dialog.visible, "Choose File... should open the file dialog.")
		ws.files._file_chosen(FIXTURES + "cube_2cm.obj")
		ws.recompute()
		await tree.process_frame
		check(str(ws.command_values.get("path", "")) == FIXTURES + "cube_2cm.obj" and doc.body_name(stl_body) == "cube_2cm", "The chosen OBJ should replace the file and name the body (%s, %s)." % [ws.command_values.get("path"), doc.body_name(stl_body)])
		_volume(ws, stl_body, 8000.0, "The OBJ cube in centimeters")
		ws.accept_command()
		await tree.process_frame
		check(_chip_with(ws, "cube_2cm.obj"), "The chip should show the new file (%s)." % [ws.timeline.chip_texts()])
		if ws.files._file_dialog != null:
			ws.files._file_dialog.hide()
		history.undo()
		await tree.process_frame
		check(_chip_with(ws, "cube_10mm.stl"), "Undo should bring the STL back.")
	history.undo()
	await tree.process_frame
	check(not ws.result.bodies.has(stl_body) and doc.features.size() == count, "Undo should take the STL body out.")

	# Insert Mesh of a 3MF file in centimeters: three cubes (1, 8 and 1 cm3) on one body, or a body
	# each with One Body per Piece.
	var three_mf: Dictionary = ws.files.insert_mesh(FIXTURES + "components_cm.3mf")
	var three_mf_feature: Resource = three_mf.get("feature")
	var three_mf_body := str(three_mf_feature.options.get("body_id", "")) if three_mf_feature != null else ""
	_volume(ws, three_mf_body, 10000.0, "The 3MF assembly")
	check(_chip_with(ws, "components_cm.3mf"), "The 3MF's chip should show its file name.")
	if three_mf_feature != null:
		ws.edit_feature(three_mf_feature.id)
		_set_value(ws, "split", true)
		var pieces: Array = ws.result.bodies.keys().filter(func(id: String) -> bool: return str(ws.result.bodies[id].feature) == three_mf_feature.id)
		var piece_volumes: Array = pieces.map(func(id: String) -> float: return snappedf(float(ws.result.bodies[id].shape.volume()) * 1e6, 0.001))
		piece_volumes.sort()
		check(pieces.size() == 3 and piece_volumes == [1.0, 1.0, 8.0], "One Body per Piece should give bodies of 1, 1 and 8 cm3 (%s)." % [piece_volumes])
		ws.cancel_command()
		await tree.process_frame
	history.undo()
	await tree.process_frame
	check(not ws.result.bodies.has(three_mf_body) and doc.features.size() == count, "Undo should take the 3MF body out.")

	# A box, exported to STEP and inserted again.
	var box: String = await _box(ws, tree)
	var step_path := TEMP + "/box.step"
	check(ws.files.export_cad(step_path, [box]) == "" and FileAccess.file_exists(step_path), "The box should export to STEP.")
	count = doc.features.size()
	var step: Dictionary = ws.files.insert_cad_file(step_path)
	var step_body := str(step.feature.options.get("body_id", "")) if step.get("feature") != null else ""
	_volume(ws, step_body, 4000.0, "The STEP box")
	check(_chip_with(ws, "box.step"), "The import's chip should show its file name (%s)." % [ws.timeline.chip_texts()])
	# Its chip opens the Import panel: Z 10 mm moves it up, Z angle 90 deg turns it about its middle.
	var step_feature: Resource = step.get("feature")
	if step_feature != null:
		var placed := _bounds(ws, step_body)
		ws.timeline.feature_edit_requested.emit(step_feature.id)
		check(ws.command != null and ws.command.editing and ws.command.feature == step_feature and ws.panel.info("source").contains("box.step"),
			"The import's chip should open its panel (%s)." % ws.panel.info("source"))
		_set_value(ws, "z", "10")
		var raised := _bounds(ws, step_body)
		check(absf(raised.position.z - placed.position.z - 0.01) < 1e-5 and raised.size.is_equal_approx(placed.size), "Z 10 mm should move the import 10 mm (%s -> %s)." % [placed, raised])
		_set_value(ws, "rz", "90")
		var turned_box := _bounds(ws, step_body)
		check(turned_box.get_center().distance_to(raised.get_center()) < 1e-5 and absf(turned_box.size.x - placed.size.y) < 1e-5 and absf(turned_box.size.y - placed.size.x) < 1e-5,
			"Z angle 90 should turn it about its middle (%s -> %s)." % [raised, turned_box])
		version = history.get_version()
		ws.accept_command()
		await tree.process_frame
		check(history.get_version() == version + 1, "OK should keep the import's edit as one undo step.")
		history.undo()
		await tree.process_frame
		var back_box := _bounds(ws, step_body)
		check(back_box.position.is_equal_approx(placed.position) and back_box.size.is_equal_approx(placed.size), "Undo should put the import back (%s)." % [back_box])
	history.undo()
	await tree.process_frame
	check(not ws.result.bodies.has(step_body) and doc.features.size() == count, "Undo should take the STEP body out.")

	# Insert Fastener: an M6 washer on the box's top face, then M8 from the timeline.
	var top := _face(ws.result.bodies[box].shape, Vector3.UP)
	ws.run_tool(CATALOG.find("solid.insert.insert_fastener"))
	check(ws.command != null and ws.command.feature != null and ws.command.feature.type == "fastener", "Insert Fastener should open its command.")
	_set_value(ws, "kind", "washer")
	_set_value(ws, "size", "M6")
	ws.panel.activate_selection("place")
	ws._on_reference_picked(REFERENCES.from_pick({"kind": "face", "body": box, "index": top}, ws.result))
	ws.recompute()
	check((ws.command_values.get("position", Vector3.ONE) as Vector3).is_equal_approx(Vector3(0.0, 0.01, 0.0)), "Picking the top face should place the washer on its middle (%s)." % [ws.command_values.get("position")])
	var fastener: Resource = ws.command.feature if ws.command != null else null
	check(fastener != null and bool(fastener.options.get("follow", false)), "A Place On pick should make the washer follow its face.")
	ws.accept_command()
	await tree.process_frame
	var washer := str(fastener.options.get("body_id", "")) if fastener != null else ""
	var m6 := INSERT.fastener_size("washer", "M6")
	_volume(ws, washer, _washer_mm3(m6), "The M6 washer")
	var washer_box: AABB = ws.result.bodies[washer].shape.bbox() if ws.result.bodies.has(washer) else AABB()
	check(absf(washer_box.position.y - 0.01) < 1e-5 and absf(washer_box.end.y - 0.01 - float(m6.h)) < 1e-5, "The washer should stand on the top face (%s)." % [washer_box])
	check(doc.body_name(washer) == "M6 Washer", "The washer body should be named after it (%s)." % doc.body_name(washer))
	ws.timeline.feature_edit_requested.emit(fastener.id if fastener != null else "")
	check(ws.command != null and ws.command.editing and str(ws.command_values.get("kind", "")) == "washer", "The timeline should open the washer for editing (%s)." % [ws.command_values])
	_set_value(ws, "size", "M8")
	ws.accept_command()
	await tree.process_frame
	_volume(ws, washer, _washer_mm3(INSERT.fastener_size("washer", "M8")), "The M8 washer")
	check(doc.body_name(washer) == "M8 Washer", "The renamed size should rename the body (%s)." % doc.body_name(washer))
	history.undo()
	await tree.process_frame
	_volume(ws, washer, _washer_mm3(m6), "The washer after undo")
	# The washer follows the top face when the box gets taller.
	var fastener_id: String = fastener.id if fastener != null else ""
	var box_feature := str(doc.bodies[box].get("feature", ""))
	version = history.get_version()
	ws.edit_feature(box_feature)
	_set_value(ws, "height", "20")
	ws.accept_command()
	await tree.process_frame
	check(absf(_bounds(ws, washer).position.y - 0.02) < 1e-5 and not (ws.result.get("warnings", {}) as Dictionary).has(fastener_id),
		"The washer should follow the top face up to 20 mm without a warning (%s, %s)." % [_bounds(ws, washer), ws.result.get("warnings", {})])
	ws.timeline.feature_edit_requested.emit(fastener_id)
	check(ws.command != null and (ws.command_values.get("position", Vector3.ZERO) as Vector3).is_equal_approx(Vector3(0.0, 0.02, 0.0)),
		"The washer's panel should show where it follows to (%s)." % [ws.command_values.get("position")])
	# Clearing Place On keeps it where it is and stops following.
	_set_value(ws, "place", [])
	ws.accept_command()
	await tree.process_frame
	var unpinned: Resource = doc.find_feature(fastener_id)
	check(unpinned != null and (unpinned.options.get("position", Vector3.ZERO) as Vector3).is_equal_approx(Vector3(0.0, 0.02, 0.0)) and not unpinned.options.has("follow"),
		"Clearing Place On should keep the washer at 20 mm and drop follow (%s)." % [unpinned.options if unpinned != null else {}])
	ws.edit_feature(box_feature)
	_set_value(ws, "height", "10")
	ws.accept_command()
	await tree.process_frame
	check(absf(_bounds(ws, washer).position.y - 0.02) < 1e-5, "A washer that no longer follows should stay at 20 mm (%s)." % [_bounds(ws, washer)])
	check(history.get_version() == version + 3, "Each edit should be one undo step.")
	for i in 3:
		history.undo()
		await tree.process_frame
	check(absf(_bounds(ws, washer).position.y - 0.01) < 1e-5 and bool(doc.find_feature(fastener_id).options.get("follow", false)), "Undoing the three edits should put the washer back on the 10 mm box, following it.")

	# Canvas: an image on the ground plane, calibrated from two clicked points.
	var image_path := TEMP + "/grid.png"
	var image := Image.create(64, 32, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.2, 0.6, 0.9))
	image.save_png(image_path)
	version = history.get_version()
	ws.run_tool(CATALOG.find("solid.insert.canvas"))
	check(ws.command != null and doc.canvases.size() == 1, "Canvas should add its entry while its panel is open.")
	ws._on_reference_picked({"kind": "origin", "name": "xz"})
	_set_value(ws, "width", "100")
	ws.command.set_image(image_path)
	ws.refresh_view()
	_set_value(ws, "opacity", "0.4")
	check(str(ws.command_values.get("height", "")) == "50", "The canvas should take the image's proportions (%s)." % ws.command_values.get("height"))
	check(int(ws.viewport.image_counts().canvases) == 1, "The canvas should show in the view.")
	ws.accept_command()
	await tree.process_frame
	var canvas: Dictionary = doc.canvases[0] if doc.canvases.size() == 1 else {}
	check((canvas.get("size", Vector2.ZERO) as Vector2).is_equal_approx(Vector2(0.1, 0.05)) and is_equal_approx(float(canvas.get("opacity", 0.0)), 0.4)
		and (canvas.get("x", Vector3.ZERO) as Vector3).is_equal_approx(Vector3.RIGHT) and (canvas.get("y", Vector3.ZERO) as Vector3).is_equal_approx(Vector3.FORWARD),
		"The canvas should be 100 x 50 mm on the ground at 0.4 opacity (%s)." % [canvas])
	check(_tree_has(ws.browser, "Canvas1") and history.get_version() == version + 1, "Canvas1 should be listed, one undo step.")
	var canvas_id := str(canvas.get("id", ""))
	ws.viewport.look_from(Vector3.UP)
	ws.viewport.set_view_state({"target": Vector3.ZERO, "distance": 0.3})
	await tree.process_frame
	ws.edit_image("canvases", canvas_id)
	check(ws.command != null and ws.command.editing and str(ws.command_values.get("width", "")) == "100", "Double-clicking Canvas1 should open it (%s)." % [ws.command_values])
	_set_value(ws, "calibrate", true)
	# In a short view the tall Canvas panel (16 rows now) stays inside it and scrolls its rows.
	await tree.process_frame
	ws.panel.max_height = 0.0
	await tree.process_frame
	var full_height: float = ws.panel.get_combined_minimum_size().y
	ws.panel.max_height = 300.0
	await tree.process_frame
	var short_height: float = ws.panel.get_combined_minimum_size().y
	check(full_height > short_height + 50.0 and short_height <= 300.5, "The Canvas panel should scroll in a short view (%s -> %s px)." % [full_height, short_height])
	ws.place_panel()
	ws.panel.button_pressed.emit("pick_points")
	ws._command_mouse(_press(ws.viewport.project(Vector3(0.0, 0.0, 0.0))))
	ws._command_mouse(_press(ws.viewport.project(Vector3(0.025, 0.0, 0.0))))
	var b: Vector3 = ws.command_values.get("cal_b", Vector3.ZERO)
	check(absf(b.x - 0.025) < 1e-5 and absf(b.y) < 1e-6, "Two clicks on the canvas should set the calibration points (%s)." % [b])
	_set_value(ws, "cal_distance", "50")
	ws.panel.button_pressed.emit("apply_calibration")
	ws.accept_command()
	await tree.process_frame
	var calibrated: Vector2 = doc.canvases[0].get("size", Vector2.ZERO) if doc.canvases.size() == 1 else Vector2.ZERO
	check(absf(calibrated.x - 0.2) < 1e-4 and absf(calibrated.y - 0.1) < 1e-4, "Calibrating 25 mm to 50 mm should double the canvas (%s)." % [calibrated])
	# The canvas' eye, Delete and undo redraw the view without a rebuild.
	var rebuilds: int = ws.rebuild_count
	ws.browser.image_visibility_toggled.emit("canvases", canvas_id)
	await tree.process_frame
	check(not bool(doc.canvases[0].visible) and int(ws.viewport.image_counts().canvases) == 0, "The eye should hide the canvas.")
	ws.delete_image("canvases", canvas_id)
	await tree.process_frame
	check(doc.canvases.is_empty() and not _tree_has(ws.browser, "Canvas1"), "Delete should remove the canvas.")
	history.undo()
	await tree.process_frame
	check(doc.canvases.size() == 1, "Undo should bring the canvas back.")
	check(ws.rebuild_count == rebuilds, "The canvas' eye, Delete and undo should rebuild nothing (%d rebuilds)." % (ws.rebuild_count - rebuilds))

	# Decal on the box's top face: listed, shown, baked as a Decal under the body.
	version = history.get_version()
	ws.run_tool(CATALOG.find("solid.insert.decal"))
	ws._on_reference_picked(REFERENCES.from_pick({"kind": "face", "body": box, "index": top}, ws.result))
	ws.command.set_image(image_path)
	_set_value(ws, "width", "10")
	_set_value(ws, "height", "5")
	ws.accept_command()
	await tree.process_frame
	var decal: Dictionary = doc.decals[0] if doc.decals.size() == 1 else {}
	check(str(decal.get("body", "")) == box and (decal.get("position", Vector3.ZERO) as Vector3).is_equal_approx(Vector3(0.0, 0.01, 0.0))
		and (decal.get("normal", Vector3.ZERO) as Vector3).is_equal_approx(Vector3.UP) and (decal.get("size", Vector2.ZERO) as Vector2).is_equal_approx(Vector2(0.01, 0.005)),
		"The decal should sit on the top face's middle, 10 x 5 mm (%s)." % [decal])
	check(_tree_has(ws.browser, "Decal1") and int(ws.viewport.image_counts().decals) == 1 and history.get_version() == version + 1, "Decal1 should be listed and shown, one undo step.")
	var baked := _decals_on(part, box)
	check(baked.size() == 1 and str(baked[0].get_meta(CAD_PART.DECAL_META)) == str(decal.get("id", "")) and (baked[0] as Decal).size.is_equal_approx(Vector3(0.01, 0.005, 0.005)),
		"The decal should bake as a Decal on the box's node (%s)." % [baked])
	# Flip: the entry's width turns negative; the baked Decal keeps a positive size and mirrors its basis.
	var decal_id := str(decal.get("id", ""))
	var plain: Transform3D = (baked[0] as Decal).transform if baked.size() == 1 else Transform3D()
	ws.edit_image("decals", decal_id)
	_set_value(ws, "flip", true)
	check(doc.decals.size() == 1 and (doc.decals[0].get("size", Vector2.ZERO) as Vector2).x < 0.0, "Flip should make the decal's width negative (%s)." % [doc.decals])
	ws.accept_command()
	await tree.process_frame
	baked = _decals_on(part, box)
	check(baked.size() == 1 and (baked[0] as Decal).size.is_equal_approx(Vector3(0.01, 0.005, 0.005)) and (baked[0] as Decal).transform.basis.determinant() < 0.0
		and ((baked[0] as Decal).transform.basis.x).is_equal_approx(-plain.basis.x), "The flipped decal should bake with a positive size and a mirrored basis (%s)." % [baked])
	check(int(ws.viewport.image_counts().decals) == 1, "The flipped decal should still show in the view.")
	history.undo()
	await tree.process_frame
	check((doc.decals[0].get("size", Vector2.ZERO) as Vector2).x > 0.0 and _decals_on(part, box).size() == 1, "Undo should unflip the decal.")
	# The decal's eye takes it off the bake without a rebuild; undo bakes it again.
	rebuilds = ws.rebuild_count
	ws.toggle_image("decals", decal_id)
	await tree.process_frame
	check(_decals_on(part, box).is_empty() and int(ws.viewport.image_counts().decals) == 0 and ws.rebuild_count == rebuilds, "The decal's eye should take it off without a rebuild.")
	history.undo()
	await tree.process_frame
	check(_decals_on(part, box).size() == 1 and ws.rebuild_count == rebuilds, "Undo should bake the decal again without a rebuild.")
	history.undo()
	await tree.process_frame
	check(doc.decals.is_empty() and _decals_on(part, box).is_empty() and int(ws.viewport.image_counts().decals) == 0, "Undo should take the decal off.")
	check(ws.rebuild_count == rebuilds, "Undoing the decal should rebuild nothing (%d rebuilds)." % (ws.rebuild_count - rebuilds))

	# Insert Derive from a saved design; Insert Component from a scene holding a Forge part.
	var source := _source_design()
	var source_path := TEMP + "/derive_source.tres"
	check(ResourceSaver.save(source, source_path) == OK, "The source design should save.")
	count = doc.features.size()
	var derived: Dictionary = ws.files.insert_derive(source_path)
	var derived_body := str(derived.feature.options.get("body_id", "")) if derived.get("feature") != null else ""
	_volume(ws, derived_body, 1000.0, "The derived body")
	check(_chip_with(ws, "derive_source.tres"), "The derive's chip should show its file name.")
	history.undo()
	await tree.process_frame
	check(doc.features.size() == count and not ws.result.bodies.has(derived_body), "Undo should take the derived body out.")
	# Editing a derive of a two-body design: a tick row per source body, at least one stays ticked,
	# and another design brings its own rows.
	var two := _source_design()
	var big: Resource = two.add_feature("box", "Box", {"length": two.make_input("20", "length"), "width": two.make_input("20", "length"), "height": two.make_input("20", "length")},
		{"position": Vector3(0.1, 0.0, 0.0), "operation": OPERATIONS.NEW_BODY, "targets": []})
	big.options["body_id"] = two.new_body(big.id)
	var two_path := TEMP + "/derive_two.tres"
	check(ResourceSaver.save(two, two_path) == OK, "The two-body design should save.")
	var two_derived: Dictionary = ws.files.insert_derive(two_path)
	var two_feature: Resource = two_derived.get("feature")
	if two_feature != null:
		var body_map: Dictionary = two_feature.options.get("body_map", {})
		var small_source := str(two.features[0].options.body_id)
		var big_source := str(big.options.body_id)
		ws.edit_feature(two_feature.id)
		check(ws.command != null and bool(ws.command_values.get("body:" + small_source, false)) and bool(ws.command_values.get("body:" + big_source, false)),
			"The derive's panel should have a ticked row per source body (%s)." % [ws.command_values])
		_set_value(ws, "body:" + small_source, false)
		check(not ws.result.bodies.has(str(body_map.get(small_source, "?"))) and ws.result.bodies.has(str(body_map.get(big_source, "?"))),
			"Unticking the small body should leave only the big one (%s, %s)." % [body_map, ws.result.bodies.keys()])
		_set_value(ws, "body:" + big_source, false)
		check(bool(ws.panel.values.get("body:" + big_source, false)) and ws.panel.info("source") == "A derive needs at least one body",
			"Unticking the last body should be refused (%s)." % ws.panel.info("source"))
		_set_value(ws, "path", source_path)
		check(ws.panel.values.has("body:" + small_source) and bool(ws.panel.values.get("body:" + small_source, false)) and not ws.panel.values.has("body:" + big_source),
			"Another design should bring its own rows, all ticked (%s)." % [ws.panel.values])
		ws.cancel_command()
		await tree.process_frame
		check(ws.result.bodies.has(str(body_map.get(small_source, "?"))) and ws.result.bodies.has(str(body_map.get(big_source, "?"))), "Cancel should bring both derived bodies back.")
	history.undo()
	await tree.process_frame
	check(doc.features.size() == count, "Undo should take the two-body derive out.")
	var holder: Node3D = CAD_PART.new()
	holder.name = "SourcePart"
	var embedded: Resource = DOCUMENT.new()
	embedded.restore(source.snapshot())
	holder.document = embedded
	var packed := PackedScene.new()
	packed.pack(holder)
	holder.free()
	var scene_path := TEMP + "/source_part.tscn"
	check(ResourceSaver.save(packed, scene_path) == OK, "The source scene should save.")
	var component: Dictionary = ws.files.insert_derive(scene_path, true)
	var component_body := str(component.feature.options.get("body_id", "")) if component.get("feature") != null else ""
	var component_id: String = doc.body_component(component_body) if component_body != "" else ""
	_volume(ws, component_body, 1000.0, "The inserted component's body")
	check(component_id != "" and doc.component_name(component_id) == "source_part" and part.component_nodes().has(component_id),
		"Insert Component should put the part's body in a new component, baked as its own node (%s)." % [doc.components])
	history.undo()
	await tree.process_frame
	check(doc.components.is_empty() and not ws.result.bodies.has(component_body), "Undo should take the component out.")
	history.redo()
	await tree.process_frame

	# Export: STEP of every body re-imports with their volume; components and bodies as files.
	ws.selection.clear()
	var all_path := TEMP + "/all.step"
	check(ws.files.export_cad(all_path) == "", "Exporting every body to STEP should work.")
	var total := 0.0
	for body_id in ws.result.bodies:
		total += float(ws.result.bodies[body_id].shape.volume())
	var back: RefCounted = ws.kernel.import_file(all_path)
	check(back != null and not back.is_null() and absf(float(back.volume()) - total) < total * 1e-5,
		"The STEP file should re-import with the bodies' volume (%s vs %s m3)." % [back.volume() if back != null else -1.0, total])
	check(ws.files.export_cad(TEMP + "/all.stl") == "" and FileAccess.file_exists(TEMP + "/all.stl"), "Exporting STL should write a file.")
	var scenes: Array = ws.files.export_components(TEMP + "/components", "tscn")
	var scenes_ok := scenes.size() == 2
	for path in scenes:
		var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
		var root: Node = loaded.instantiate() if loaded != null else null
		scenes_ok = scenes_ok and root != null and not root.find_children("*", "MeshInstance3D", true, false).is_empty()
		if root != null:
			root.free()
	check(scenes_ok, "Export Components should write the top level and the component as scenes with their bodies (%s)." % [scenes])
	var glbs: Array = ws.files.export_components(TEMP + "/components_glb", "glb")
	check(glbs.size() == 2 and glbs.all(func(p: String) -> bool: return FileAccess.file_exists(p)), "Export Components should write .glb files too (%s)." % [glbs])
	var meshes: Array = ws.files.export_body_meshes(TEMP + "/meshes")
	check(meshes.size() == part.body_nodes().size() and meshes.all(func(p: String) -> bool: return ResourceLoader.load(p, "", ResourceLoader.CACHE_MODE_IGNORE) is Mesh),
		"Export Body Meshes should write one mesh per body (%s)." % [meshes])
	var board_root := TEMP + "/board_models"
	var first: Dictionary = ws.files.save_board_model("TestBoard", ["glb", "tres", "step"], board_root)
	var second: Dictionary = ws.files.save_board_model("TestBoard", ["glb", "tres", "step"], board_root)
	check(int(first.version) == 1 and int(second.version) == 2 and (second.paths as Array).size() == 3 and str(second.error) == ""
		and FileAccess.file_exists(board_root + "/TestBoard/TestBoard_v002.glb") and FileAccess.file_exists(board_root + "/board_models_manifest.json"),
		"Board models should save as v001 then v002 with a manifest (%s, %s)." % [first, second])
	ws.run_action("export_step")
	check(dialog != null and dialog.visible and dialog.file_mode == EditorFileDialog.FILE_MODE_SAVE_FILE, "Export STEP should open a save dialog.")
	if dialog != null:
		dialog.hide()
	_finish(tree)


func _box(ws, tree: SceneTree) -> String:
	ws.run_tool(CATALOG.find("solid.create.box"))
	_set_value(ws, "length", "20")
	_set_value(ws, "width", "20")
	_set_value(ws, "height", "10")
	_set_value(ws, "position", Vector3.ZERO)
	var feature: Resource = ws.command.feature
	ws.accept_command()
	await tree.process_frame
	return str(feature.options.get("body_id", ""))


## A design with one 10 mm cube, for Derive.
func _source_design() -> Resource:
	var source: Resource = DOCUMENT.new()
	var inputs := {"length": source.make_input("10", "length"), "width": source.make_input("10", "length"), "height": source.make_input("10", "length")}
	var feature: Resource = source.add_feature("box", "Box", inputs, {"position": Vector3.ZERO, "operation": OPERATIONS.NEW_BODY, "targets": []})
	feature.options["body_id"] = source.new_body(feature.id)
	return source


static func _washer_mm3(spec: Dictionary) -> float:
	return PI * 0.25 * (pow(float(spec.d2), 2.0) - pow(float(spec.d1), 2.0)) * float(spec.h) * 1e9


func _decals_on(part: Node3D, body_id: String) -> Array:
	var body: Node = part.body_nodes().get(body_id)
	if body == null:
		return []
	return body.get_children().filter(func(child: Node) -> bool: return child is Decal and child.has_meta(CAD_PART.DECAL_META) and not child.is_queued_for_deletion())


func _face(shape: RefCounted, normal: Vector3) -> int:
	for f in shape.face_count():
		var info: Dictionary = shape.face_info(f)
		if info.get("planar", false) and (info.normal as Vector3).is_equal_approx(normal):
			return f
	return -1


func _press(at: Vector2) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = at
	return event


func _set_value(ws, key: String, value: Variant) -> void:
	var values: Dictionary = ws.panel.values.duplicate(true)
	values[key] = value
	ws.panel.set_values(values)
	ws._on_panel_values_changed(values)
	if ws._is_inspect(ws.command):
		ws.refresh_view()
	else:
		ws.recompute()


## A body's bounds in the last rebuild (an empty AABB when it is missing).
func _bounds(ws, body_id: String) -> AABB:
	var body: Dictionary = ws.result.get("bodies", {}).get(body_id, {})
	return body.shape.bbox() if not body.is_empty() else AABB()


func _volume(ws, body_id: String, expected_mm3: float, label: String) -> void:
	var shape = ws.result.get("bodies", {}).get(body_id, {}).get("shape")
	var v: float = float(shape.volume()) * 1e9 if shape != null else -1.0
	check(shape != null and absf(v - expected_mm3) < expected_mm3 * 1e-5, "%s: %s mm3 expected, got %s (%s)." % [label, expected_mm3, v, ws.last_message])


func _chip_with(ws, text: String) -> bool:
	for chip_text in ws.timeline.chip_texts():
		if chip_text.contains(text):
			return true
	return false


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


func _remove_temp() -> void:
	var root := ProjectSettings.globalize_path(TEMP)
	if not DirAccess.dir_exists_absolute(root):
		return
	var stack := [root]
	var folders := []
	while not stack.is_empty():
		var folder: String = stack.pop_back()
		folders.append(folder)
		for file in DirAccess.get_files_at(folder):
			DirAccess.remove_absolute(folder.path_join(file))
		for sub in DirAccess.get_directories_at(folder):
			stack.append(folder.path_join(sub))
	folders.reverse()
	for folder in folders:
		DirAccess.remove_absolute(folder)


func _finish(tree: SceneTree) -> void:
	for i in 4:
		await tree.process_frame
	_remove_temp()
	if failures.is_empty():
		print("PASS Holo Forge INSERT EDITOR: every Phase 1-4 tool enabled (Form Box and Mesh Insert Mesh on, Phase 8 Joint on, Phase 9 Flange off); Insert SVG dialog, then a ground-plane click makes a sketch with 3 profiles; DXF one sketch per layer (4 profiles) in one undo step; STL cube 1000 mm3 and a STEP round trip of a box 4000 mm3 with file names on their chips, both edited from their chips (cm units, X/Z offsets, Z angle, Choose File... to an OBJ, one-step OK, Cancel); a centimeter 3MF through Insert Mesh (10 cm3, split into 1/1/8 cm3); a two-body derive's body rows (at least one) and design switch; an M6 washer on the box's top face has the ISO volume, follows the face to 20 mm until Place On is cleared, and becomes M8 from the timeline; canvas listed, shown, proportional, scrolling in a short view and calibrated from two clicks, eye/delete/undo without a rebuild; decal listed, shown and baked as a Decal on the body, flipped with a positive size and mirrored basis, eye/undo without a rebuild; Derive from a .tres and Insert Component from a scene's Forge part; STEP export re-imports with the bodies' volume, STL, component scenes (.tscn/.glb), body meshes and board-model v001/v002 in a temp root; undo removes each insert")
	else:
		print("FAIL Holo Forge INSERT EDITOR: ", failures)
	tree.quit(0 if failures.is_empty() else 1)
