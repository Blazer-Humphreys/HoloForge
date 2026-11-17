extends SceneTree
## Holo Forge Insert and Export from the Forge tab without the editor (ui/forge_files.gd and the
## Canvas / Decal command, tools/image_command.gd, on the workspace in a plain scene tree):
## Export Components and Export Body Meshes never replace a Holo Forge design (also a board.tscn
## that Board.tscn would replace on Windows) and ask before replacing any other file; a decal
## stays on its face when the face moves and when its Position handle is dragged off a curved
## face, and a canvas moves with its plane; the Insert DXF prompt refuses an empty layer pick and
## stays open; and a failed insert leaves an open command or sketch exactly as it was, while a
## good one still closes them as one undo step.
##
## godot --headless --path . --script res://tests/holo_forge_insert_ui_test.gd

const WORKSPACE := preload("res://addons/holo_forge/ui/forge_workspace.gd")
const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const CATALOG := preload("res://addons/holo_forge/tools/catalog.gd")
const SKETCH_DATA := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const APPEARANCE := preload("res://addons/holo_forge/core/appearance.gd")
const IMAGE_COMMAND := preload("res://addons/holo_forge/tools/image_command.gd")

const FIXTURES := "res://tests/holo_forge/fixtures/"
## A folder of its own per run, so two runs at once (a full test sweep) never share files.
var temp := "user://holo_forge_insert_ui_test_%d" % OS.get_process_id()

var failures: Array[String] = []
var ws: Control


func _init() -> void:
	call_deferred("run")


func run() -> void:
	create_timer(300.0).timeout.connect(func() -> void:
		print("FAIL holo_forge_insert_ui: timed out ", failures)
		quit(1))
	_remove_tree(ProjectSettings.globalize_path(temp))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(temp))
	ws = WORKSPACE.new()
	root.add_child(ws)
	ws.size = Vector2(1400, 900)
	for i in 3:
		await process_frame
	if ws.kernel == null:
		_expect(false, "The native kernel should load.")
	else:
		await _check_export_never_overwrites_designs()
		await _check_export_asks_before_replacing()
		await _check_decal_follows_face()
		await _check_decal_drag_stays_on_curved_face()
		await _check_canvas_follows_plane()
		await _check_dxf_empty_layer_pick()
		await _check_failed_insert_keeps_command()
		await _check_failed_insert_keeps_sketch()
		await _check_plane_pick_ends_for_command()
		await _check_unchanged_body_keeps_tessellation()
	print("PASS holo_forge_insert_ui: exports never replace a Forge design and ask before replacing other files, decals stay on their faces (rebuilds and drags) and canvases on their planes, an empty DXF layer pick is refused, a failed insert keeps the open command or sketch, a pending plane pick ends when a command or sketch starts, and only changed bodies are tessellated again." \
		if failures.is_empty() else "FAIL holo_forge_insert_ui (%d problem(s))" % failures.size())
	ws.set_part(null)
	ws.queue_free()
	await process_frame
	_remove_tree(ProjectSettings.globalize_path(temp))
	quit(0 if failures.is_empty() else 1)


# --- Helpers ---------------------------------------------------------------------------------

func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)
		print("FAIL: ", message)


func _remove_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for file in dir.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	for sub in dir.get_directories():
		_remove_tree(path.path_join(sub))
	DirAccess.remove_absolute(path)


func _new_part(part_name := "ForgePart") -> Node3D:
	if ws.part != null and is_instance_valid(ws.part):
		var old: Node3D = ws.part
		ws.set_part(null)
		old.queue_free()
	var part: Node3D = CAD_PART.new()
	part.name = part_name
	part.document = DOCUMENT.new()
	root.add_child(part)
	ws.set_part(part)
	await process_frame
	return part


## A box of the given size (mm) at the origin, accepted; returns its feature.
func _box(length := "50", width := "50", height := "50") -> Resource:
	ws.run_tool(CATALOG.find("solid.create.box"))
	_set_value("length", length)
	_set_value("width", width)
	_set_value("height", height)
	_set_value("position", Vector3.ZERO)
	ws.recompute()
	ws.accept_command()
	return ws.doc.features.back()


func _set_value(key: String, value: Variant) -> void:
	var values: Dictionary = ws.command_values.duplicate(true)
	values[key] = value
	ws.set_command_values(values)


func _face_toward(shape: RefCounted, normal: Vector3) -> int:
	for i in shape.face_count():
		var info: Dictionary = shape.face_info(i)
		if info.get("planar", false) and (info.normal as Vector3).dot(normal) > 0.999:
			return i
	return -1


func _key(code: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	return event


## Saves the workspace's part (with its baked children) as a scene at path.
func _save_part_scene(part: Node3D, path: String) -> void:
	for child in part.find_children("*", "", true, false):
		child.owner = part
	var packed := PackedScene.new()
	_expect(packed.pack(part) == OK and ResourceSaver.save(packed, path) == OK, "Saving %s should work." % path)


func _scene_info(path: String) -> Dictionary:
	var scene: PackedScene = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if scene == null:
		return {}
	var node := scene.instantiate()
	var doc: Variant = node.get("document")
	var info := {"name": str(node.name), "script": node.get_script() != null, "features": (doc as Resource).features.size() if doc is Resource else -1,
		"meta": str(node.get_meta("user_work", ""))}
	node.free()
	return info


func _files(folder: String) -> PackedStringArray:
	return DirAccess.get_files_at(ProjectSettings.globalize_path(folder))


func _write_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _image(path: String) -> String:
	var image := Image.create(64, 32, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.9, 0.2, 0.2))
	image.save_png(path)
	return path


# --- Export never overwrites a design ----------------------------------------------------------

func _check_export_never_overwrites_designs() -> void:
	# The user's scene board.tscn holds the Forge part "Board" (Godot's snake_case scene name):
	# Export Components would write Board.tscn, which on Windows is the same file.
	var boards := temp + "/boards"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(boards))
	var board := await _new_part("Board")
	_box()
	await process_frame
	_save_part_scene(board, boards + "/board.tscn")
	var before := _scene_info(boards + "/board.tscn")
	_expect(bool(before.get("script", false)) and int(before.get("features", 0)) == 1, "board.tscn should hold the Forge part with its box (%s)." % [before])
	var written: Array = ws.files.export_components(boards, "tscn")
	var after := _scene_info(boards + "/board.tscn")
	_expect(written.is_empty(), "Export Components must not write over board.tscn, which holds a Forge design (wrote %s)." % [written])
	_expect(bool(after.get("script", false)) and int(after.get("features", 0)) == 1 and _files(boards) == PackedStringArray(["board.tscn"]),
		"board.tscn should still be the Forge design after Export Components (%s; files %s)." % [after, _files(boards)])
	_expect(ws.last_message.contains("board.tscn") and ws.last_message.contains("Holo Forge design"),
		"Export Components should say why it refused (%s)." % ws.last_message)
	_expect(ws.files._confirm == null or not ws.files._confirm.visible, "A Forge design is never offered for replacing.")

	# Insert Component of a saved wheel design, then Export Components into the wheel's folder:
	# the component "wheel" would replace wheel.tscn, the design it came from.
	var parts := temp + "/parts"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(parts))
	var wheel := await _new_part("Wheel")
	_box("30", "30", "10")
	await process_frame
	_save_part_scene(wheel, parts + "/wheel.tscn")
	await _new_part("ForgePart")
	var made: Dictionary = ws.files.insert_derive(parts + "/wheel.tscn", true)
	_expect(made.get("feature") != null, "Insert Component of wheel.tscn should work (%s)." % made.get("error", ""))
	await process_frame
	written = ws.files.export_components(parts, "tscn")
	var wheel_after := _scene_info(parts + "/wheel.tscn")
	_expect(written.is_empty() and bool(wheel_after.get("script", false)) and int(wheel_after.get("features", 0)) == 1,
		"Export Components must not replace wheel.tscn, the design a component came from (wrote %s; %s)." % [written, wheel_after])
	ws.recompute()
	_expect((ws.result.errors as Dictionary).is_empty() and ws.result.bodies.size() == 1,
		"The component should still rebuild from wheel.tscn after the refused export (%s)." % [ws.result.errors])

	# Export Body Meshes into a folder where a saved design has the body's file name.
	var body_name := str((ws.part.body_nodes().values()[0] as Node).name)
	var meshes := temp + "/meshes"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(meshes))
	var design_path := meshes + "/" + body_name.to_lower() + ".res"
	var design: Resource = DOCUMENT.new()
	design.add_feature("box", "Box", {}, {})
	_expect(ResourceSaver.save(design, design_path) == OK, "Saving a design as %s should work." % design_path)
	written = ws.files.export_body_meshes(meshes)
	var kept: Resource = ResourceLoader.load(design_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	_expect(written.is_empty() and kept != null and kept.get_script() == DOCUMENT and kept.features.size() == 1,
		"Export Body Meshes must not write over %s, a saved design (wrote %s)." % [design_path.get_file(), written])


# --- Export asks before replacing other files ----------------------------------------------------

func _check_export_asks_before_replacing() -> void:
	# The part from the last check: one component "wheel" holding one derived body.
	var part: Node3D = ws.part
	var plain := temp + "/plain"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(plain))
	var hand := Node3D.new()
	hand.name = "MyWheelAssembly"
	hand.set_meta("user_work", "precious")
	var packed := PackedScene.new()
	packed.pack(hand)
	ResourceSaver.save(packed, plain + "/wheel.tscn")
	hand.free()
	var written: Array = ws.files.export_components(plain, "tscn")
	var info := _scene_info(plain + "/wheel.tscn")
	_expect(written.is_empty() and str(info.get("meta", "")) == "precious", "Export Components should ask before replacing wheel.tscn (wrote %s; %s)." % [written, info])
	_expect(ws.files._confirm != null and ws.files._confirm.visible and ws.last_message.contains("wheel.tscn"),
		"Export Components should ask whether to replace wheel.tscn (%s)." % ws.last_message)
	ws.files._confirm.hide()
	ws.files._confirm_accepted()
	info = _scene_info(plain + "/wheel.tscn")
	_expect(str(info.get("name", "")) == "wheel" and str(info.get("meta", "")) == "" and ws.last_message.begins_with("Exported 1 scene"),
		"Replace should export the component over wheel.tscn (%s; %s)." % [info, ws.last_message])

	# A fresh folder is written at once.
	var fresh := temp + "/fresh"
	written = ws.files.export_components(fresh, "tscn")
	_expect(written.size() == 1 and FileAccess.file_exists(fresh + "/wheel.tscn"), "Exporting into a new folder should write at once (%s)." % [written])

	# Export Body Meshes: an unrelated mesh with the body's name (another case) is replaced only
	# after Replace.
	var body_name := str((part.body_nodes().values()[0] as Node).name)
	var meshes := temp + "/plain_meshes"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(meshes))
	var old_path := meshes + "/" + body_name.to_upper() + ".res"
	ResourceSaver.save(BoxMesh.new(), old_path)
	written = ws.files.export_body_meshes(meshes)
	var old: Resource = ResourceLoader.load(old_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	_expect(written.is_empty() and old is BoxMesh and ws.files._confirm.visible, "Export Body Meshes should ask before replacing %s (wrote %s)." % [old_path.get_file(), written])
	ws.files._confirm.hide()
	ws.files._confirm_accepted()
	var files := _files(meshes)
	var replaced: Resource = ResourceLoader.load(meshes.path_join(files[0]), "", ResourceLoader.CACHE_MODE_IGNORE) if files.size() == 1 else null
	_expect(files.size() == 1 and replaced is ArrayMesh, "Replace should write the body's mesh over the old file (%s)." % [files])


# --- Decals and canvases stay on their geometry ---------------------------------------------------

func _check_decal_follows_face() -> void:
	var part := await _new_part("DecalPart")
	var doc: Resource = part.document
	var box_feature := _box("20", "20", "10")
	var box := str(box_feature.options.body_id)
	var top := _face_toward(ws.result.bodies[box].shape, Vector3.UP)
	ws.run_tool(CATALOG.find("solid.insert.decal"))
	ws._on_reference_picked(REFERENCES.from_pick({"kind": "face", "body": box, "index": top}, ws.result))
	ws.command.set_image(_image(temp + "/logo.png"))
	_set_value("width", "10")
	_set_value("height", "5")
	ws.accept_command()
	await process_frame
	_expect(doc.decals.size() == 1 and absf((doc.decals[0].position as Vector3).y - 0.01) < 1e-6, "The decal should sit on the 10 mm box's top face (%s)." % [doc.decals])

	# The box grows to 20 mm: the decal goes with its face (after the rebuild, then the bake).
	ws.edit_feature(box_feature.id)
	_set_value("height", "20")
	ws.recompute()
	ws.accept_command()
	await process_frame
	# The workspace's rebuild follows the decal (IMAGE_COMMAND.follow_geometry) before the bake.
	var lost := PackedStringArray()
	_expect(ws._baked_decals == doc.decals, "The bake should match the followed decals.")
	var decal: Dictionary = doc.decals[0]
	_expect(lost.is_empty() and absf((decal.position as Vector3).y - 0.02) < 1e-6 and (decal.normal as Vector3).is_equal_approx(Vector3.UP),
		"After the box grows to 20 mm the decal should be on its top face at y = 0.02 (%s, %s; lost %s)." % [decal.position, decal.normal, lost])
	var baked: Decal = null
	for child in part.body_nodes()[box].get_children():
		if child is Decal:
			baked = child
	_expect(baked != null and absf(baked.transform.origin.y - 0.02) < 1e-6, "The baked Decal should be on the moved top face (%s)." % [baked.transform.origin if baked != null else null])
	var followed: Dictionary = decal.duplicate(true)
	_expect(IMAGE_COMMAND.follow_geometry(doc, ws.result, ws.kernel).is_empty() and doc.decals[0] == followed,
		"Following again with nothing moved should change nothing.")

	# Opened again, the panel has the followed position; a rotation keeps it there.
	ws.edit_image("decals", str(decal.id))
	_expect(absf((ws.command_values.position as Vector3).y - 0.02) < 1e-6, "The reopened panel should show the followed position (%s)." % [ws.command_values.position])
	_set_value("rotation", "10")
	ws.accept_command()
	_expect(absf((doc.decals[0].position as Vector3).y - 0.02) < 1e-6, "A rotation edit should keep the decal on the face (%s)." % [doc.decals[0].position])

	# Its body gone, the decal stays where it was and is reported.
	var kept_at: Vector3 = doc.decals[0].position
	lost = IMAGE_COMMAND.follow_geometry(doc, {"bodies": {}}, ws.kernel)
	_expect(lost == PackedStringArray([str(doc.decals[0].name)]) and doc.decals[0].position == kept_at,
		"A decal whose face is gone should stay put and be named (%s)." % [lost])


func _check_decal_drag_stays_on_curved_face() -> void:
	var part := await _new_part("CylinderPart")
	var doc: Resource = part.document
	ws.run_tool(CATALOG.find("solid.create.cylinder"))
	ws.accept_command()
	var body := str(doc.features[0].options.body_id)
	var shape: RefCounted = ws.result.bodies[body].shape
	var side := -1
	for i in shape.face_count():
		if not shape.face_info(i).get("planar", false):
			side = i
	var radius: float = (shape.bbox() as AABB).size.x * 0.5
	ws.run_tool(CATALOG.find("solid.insert.decal"))
	ws._on_reference_picked(REFERENCES.from_pick({"kind": "face", "body": body, "index": side}, ws.result))
	ws.command.set_image(_image(temp + "/grid.png"))
	_set_value("width", "10")
	_set_value("height", "5")
	# The Position handle drags in the face's tangent plane, 15 mm across.
	var handle: Dictionary = ws.command.manipulators(ws.command_values, {})[0]
	var n: Vector3 = handle.normal
	ws._on_manipulator_changed(handle, (handle.position as Vector3) + n.cross(Vector3.UP).normalized() * 0.015)
	var decal: Dictionary = doc.decals[0]
	var p: Vector3 = decal.position
	var near: Dictionary = ws.kernel.closest_points(shape.face_shape(side), ws.kernel.make_vertex(p))
	var off := p.distance_to(near.a)
	_expect(off < 1e-6 and absf(Vector2(p.x, p.z).length() - radius) < 1e-6,
		"A dragged decal should stay on the cylinder (%s m off the face, %s from the axis, radius %s)." % [off, Vector2(p.x, p.z).length(), radius])
	_expect((decal.normal as Vector3).is_equal_approx(Vector3(p.x, 0.0, p.z).normalized()), "The decal should face out of the cylinder where it went (%s)." % [decal.normal])
	_expect((ws.command_values.position as Vector3).is_equal_approx(p) and (ws.panel.values.position as Vector3).is_equal_approx(p),
		"The panel's Position should show the point on the face (%s)." % [ws.panel.values.position])
	var t := APPEARANCE.decal_transform(decal)
	var reach: float = APPEARANCE.decal_size(decal).y * 0.5
	_expect(ws.kernel.closest_points(shape.face_shape(side), ws.kernel.make_vertex(t.origin)).distance < reach,
		"The decal's projection box should reach the cylinder.")
	ws.accept_command()


func _check_canvas_follows_plane() -> void:
	var part := await _new_part("CanvasPart")
	var doc: Resource = part.document
	var box_feature := _box()
	var box := str(box_feature.options.body_id)
	var top := _face_toward(ws.result.bodies[box].shape, Vector3.UP)
	ws.run_tool(CATALOG.find("solid.insert.canvas"))
	ws._on_reference_picked(REFERENCES.from_pick({"kind": "face", "body": box, "index": top}, ws.result))
	_set_value("image", _image(temp + "/canvas.png"))
	_set_value("center", Vector3(0.01, 0.05, -0.005))
	ws.accept_command()
	var canvas: Dictionary = doc.canvases[0]
	_expect(absf((canvas.origin as Vector3).y - 0.05) < 1e-6, "The canvas should be on the 50 mm box's top face (%s)." % [canvas.origin])
	ws.change("Edit Box", func() -> void: doc.find_feature(box_feature.id).set_expression("height", "100"))
	canvas = doc.canvases[0]
	_expect((canvas.origin as Vector3).is_equal_approx(Vector3(0.01, 0.1, -0.005)) and ((canvas.panel as Dictionary).center as Vector3).is_equal_approx(Vector3(0.01, 0.1, -0.005)),
		"The canvas should move up with its face, keeping its place on it (%s, panel %s)." % [canvas.origin, (canvas.panel as Dictionary).center])


# --- Insert DXF: an empty layer pick ----------------------------------------------------------------

func _check_dxf_empty_layer_pick() -> void:
	var part := await _new_part("DxfPart")
	var doc: Resource = part.document
	ws.create_sketch(SKETCH_DATA.ORIGIN_PLANES.xz, "xz")
	var features: int = doc.features.size()
	ws.files._dxf_chosen(FIXTURES + "import_shapes.dxf")
	var list: ItemList = ws.files._options_editors["layers"]
	_expect(list.item_count == 4, "The DXF fixture should list 4 layers (%d)." % list.item_count)
	list.deselect_all()
	ws.files._options_confirmed()
	_expect(doc.features.size() == features and ws.sketch_editor.active, "No layer picked should insert nothing (features %d -> %d)." % [features, doc.features.size()])
	_expect(ws.files._options.visible and ws.files._options_callback.is_valid() and ws.last_message == "Pick at least one layer." and ws.files._options_error.visible,
		"No layer picked should keep the prompt open and say so (%s)." % ws.last_message)
	for i in list.item_count:
		if list.get_item_text(i) == "Bulge":
			list.select(i)
	ws.files._options_confirmed()
	_expect(not ws.files._options.visible and doc.features.size() == features + 1 and ws.last_message.begins_with("Inserted 4 curve(s)"),
		"Only the Bulge layer should insert its 4 curves (%s)." % ws.last_message)


# --- A failed insert changes nothing ------------------------------------------------------------------

func _check_failed_insert_keeps_command() -> void:
	var part := await _new_part("FailPart")
	var doc: Resource = part.document
	var box_feature := _box()
	var empty_stl := temp + "/empty.stl"
	_write_text(empty_stl, "solid nothing\nendsolid nothing\n")
	var empty_svg := temp + "/empty.svg"
	_write_text(empty_svg, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10mm\" height=\"10mm\"></svg>")
	ws.edit_feature(box_feature.id)
	_set_value("length", "80")
	ws.recompute()
	var cases := [
		["an STL with no triangles", func() -> Dictionary: return ws.files.insert_mesh(empty_stl)],
		["a missing STL", func() -> Dictionary: return ws.files.insert_mesh(temp + "/nope_missing.stl")],
		["an empty SVG", func() -> Dictionary: return ws.files.insert_sketch_file(empty_svg, SKETCH_DATA.ORIGIN_PLANES.xy, "xy")],
	]
	for item in cases:
		var made: Dictionary = item[1].call()
		var box_now: Resource = doc.find_feature(box_feature.id)
		_expect(made.get("feature") == null and ws.command != null and box_now != null and box_now.expression("length") == "80" and doc.features.size() == 1,
			"A failed insert of %s should leave the box edit open with its 80 mm length (open %s, length %s, %s)." % [item[0], ws.command != null,
				box_now.expression("length") if box_now != null else "?", ws.last_message])
	_expect(ws.last_message.begins_with("Insert SVG: "), "The failure should be shown (%s)." % ws.last_message)
	# Insert SVG's plane pick would end the edit: an empty drawing is refused before it starts.
	ws.files.begin_sketch_file(empty_svg)
	_expect(ws.command != null and not ws.is_picking_plane() and doc.find_feature(box_feature.id).expression("length") == "80",
		"Insert SVG of an empty drawing should leave the box edit open and start no plane pick (%s)." % ws.last_message)

	# A good insert still cancels the open edit (never accepted) and is one undo step.
	var made: Dictionary = ws.files.insert_mesh(FIXTURES + "cube_10mm.stl")
	_expect(made.get("feature") != null and ws.command == null and doc.find_feature(box_feature.id).expression("length") == "50" and doc.features.size() == 2,
		"A good Insert Mesh should cancel the box edit and add the mesh (%s)." % ws.last_message)
	_expect(ws.result.bodies.size() == 2 and (ws.result.errors as Dictionary).is_empty(), "The box and the mesh should rebuild (%s)." % [ws.result.errors])


func _check_failed_insert_keeps_sketch() -> void:
	var part := await _new_part("SketchFailPart")
	var doc: Resource = part.document
	var editor: RefCounted = ws.sketch_editor
	var sketch: Resource = ws.create_sketch(SKETCH_DATA.ORIGIN_PLANES.xz, "xz")
	var empty_svg := temp + "/empty.svg"
	var empty_stl := temp + "/empty.stl"
	var cases := [
		["an empty SVG", func() -> void: ws.files.begin_sketch_file(empty_svg)],
		["a missing SVG", func() -> void: ws.files.begin_sketch_file(temp + "/gone_missing.svg")],
		["an STL with no triangles", func() -> void: ws.files.insert_mesh(empty_stl)],
	]
	for item in cases:
		editor.start_tool("line")
		editor.tool_click(Vector2(0.0, 0.0), {}, {})
		item[1].call()
		_expect(editor.active and editor.feature_id == sketch.id and editor.tool == "line" and editor.tool_points.size() == 1 and doc.features.size() == 1,
			"A failed insert of %s should leave the sketch open with its Line tool and point (active %s, tool '%s', points %d, %s)." % [item[0], editor.active,
				editor.tool, editor.tool_points.size(), ws.last_message])
		_expect(not ws.is_picking_plane(), "A failed insert of %s should not start a plane pick." % item[0])
		editor.cancel_tool()

	# A good SVG goes on the sketch's plane and closes the sketch.
	ws.files.begin_sketch_file(FIXTURES + "import_shapes.svg")
	_expect(not editor.active and doc.features.size() == 2 and ws.last_message.begins_with("Inserted 10 curve(s)"),
		"Insert SVG inside a sketch should add the drawing and close the sketch (%s)." % ws.last_message)
	var inserted: Resource = doc.features.back()
	_expect(str(inserted.options.get("plane_ref", "")) == "xz", "The drawing should go on the sketch's XZ plane (%s)." % inserted.options.get("plane_ref", ""))

	# Outside a sketch, a missing file is refused before the plane pick starts.
	ws.files.begin_sketch_file(temp + "/gone_missing.svg")
	_expect(not ws.is_picking_plane() and ws.last_message.contains("can't be found"), "A missing SVG should be refused at once (%s)." % ws.last_message)


# --- A pending plane pick and a starting command ---------------------------------------------

## Insert SVG (or Create Sketch) waiting for a plane click ends when a command starts, so the command
## gets the view's clicks and Escape cancels it; editing a sketch ends the pick too.
func _check_plane_pick_ends_for_command() -> void:
	await _new_part("PickPart")
	var box := str(_box().options.body_id)
	ws.files.begin_sketch_file(FIXTURES + "import_shapes.svg")
	_expect(ws.is_picking_plane(), "Insert SVG outside a sketch should wait for a plane click.")
	ws.run_tool(CATALOG.find("solid.insert.insert_fastener"))
	_expect(not ws.is_picking_plane() and ws.viewport.mouse_handler == Callable(ws, "_command_mouse"), "Starting a command should end the plane pick and take the view's clicks.")
	ws.handle_key(_key(KEY_ESCAPE))
	_expect(ws.command == null and ws.last_message != "Insert cancelled.", "Escape should cancel the command (%s)." % ws.last_message)
	ws.run_action("create_sketch")
	_expect(ws.is_picking_plane(), "Create Sketch should wait for a plane click.")
	ws.run_tool(CATALOG.find("solid.insert.insert_fastener"))
	_expect(not ws.is_picking_plane() and ws.viewport.mouse_handler == Callable(ws, "_command_mouse"), "The fastener should get the clicks after Create Sketch's pick.")
	ws._on_reference_picked(REFERENCES.from_pick({"kind": "face", "body": box, "index": _face_toward(ws.result.bodies[box].shape, Vector3.UP)}, ws.result))
	var place: Array = ws.command_values.get("place", [])
	_expect(place.size() == 1 and place[0] is Dictionary and str(place[0].kind) == "face", "A face pick should place the fastener on the face (%s)." % [place])
	ws.cancel_command()
	var sketch: Resource = ws.create_sketch(SKETCH_DATA.ORIGIN_PLANES.xz, "xz")
	ws.sketch_editor.end()
	ws.files.begin_sketch_file(FIXTURES + "import_shapes.svg")
	_expect(ws.is_picking_plane(), "Insert SVG should wait for a plane click again.")
	ws.edit_feature(sketch.id)
	_expect(not ws.is_picking_plane() and ws.sketch_editor.active and ws.viewport.mouse_handler == Callable(ws.sketch_editor, "handle_mouse"),
		"Editing a sketch should end a pending plane pick.")
	ws.sketch_editor.end()


# --- Tessellations of unchanged bodies -------------------------------------------------------

## A rebuild that hands back the same shape object (Insert Mesh's kept solid) keeps that body's
## tessellation; the edited box is tessellated again.
func _check_unchanged_body_keeps_tessellation() -> void:
	await _new_part("TessPart")
	var box_feature := _box()
	var made: Dictionary = ws.files.insert_mesh(FIXTURES + "cube_10mm.stl")
	_expect(made.get("feature") != null, "The STL should insert (%s)." % ws.last_message)
	if made.get("feature") == null:
		return
	var mesh_body := str(made.feature.options.body_id)
	var box_body := str(box_feature.options.body_id)
	var mesh_tess: Dictionary = ws.tessellations[mesh_body]
	var box_tess: Dictionary = ws.tessellations[box_body]
	ws.edit_feature(box_feature.id)
	_set_value("height", "60")
	ws.recompute()
	_expect(is_same(ws.tessellations[mesh_body], mesh_tess) and not is_same(ws.tessellations[box_body], box_tess),
		"Only the edited box should be tessellated again.")
	ws.accept_command()
