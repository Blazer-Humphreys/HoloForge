@tool
extends RefCounted
## "Pull the handles": every view handle of Holo Forge dragged with the mouse inside the real editor
## (spec: the plan's 2026-11-15 work order). The hook builds its own scene,
## tests/holo_forge/handles_editor_test.tscn (three CadParts from tests/holo_forge_assembly_fixtures.gd:
## stack() for Place Component, all_types() for Drive and the Joint panel, mesh_block() for Direct Edit
## and Plane Cut), writes it with ResourceSaver only and opens it; blank parts for the other sections
## are added to it in memory (never saved). Every press, drag, click and key is a real event pushed
## into the editor's window (tests/holo_forge_mouse.gd), and each drag is checked against the handle
## math: the field reads the value the mouse travel gives, the model (volume, box, pose, mapping,
## cage) follows it, OK is one undo step with its name, undo puts the document back exactly and redo
## again, and Esc after a drag leaves the document as it was.
##
## Sections (--holo-forge-handles-editor-only=<a,b> runs some and ends with PARTIAL; -skip= leaves
## some out):
##   primitives  Box height/length/width arrows and its position point; Cylinder height and
##               diameter; Sphere diameter; Esc after a drag.
##   features    Extrude distance; Offset Face; Press Pull on a face (and none on an edge); Offset
##               Plane; Surface Extrude.
##   insert      Fastener length arrow and position point; Canvas centre; Decal position.
##   inspect     Section offset arrow, Tilt and Spin dots; Texture Map Scale U/V arrows, the turn
##               dot, the anchor point and a round projection's origin.
##   assemble    Place Component's move arrows and turn dots; Drive on every DOF of every joint type
##               (rings and slides, a stop at the limit); the Joint panel's ring and slide.
##   mesh        Direct Edit's X, Y and Z move arrows; Plane Cut's offset pulled below zero.
##   form        Form Box/Plane/Cylinder/Sphere/Quadball/Torus arrows and face counts; Form Extrude;
##               Insert Edge, Slide Edge and Smooth sliders; the Edit Form gizmo's parts.
##   sketch      a sketch point dragged (a fixed one stays); a dimension's text dragged; the
##               timeline's rollback marker dragged.
##   edges       an arrow seen end-on moves nothing; a drag below the minimum stops there; a drag
##               writes a number over a typed expression; arrows that start at one point each take
##               their own press.
##
## godot --headless --path . --editor -- --holo-forge-handles-editor-test
## godot --path . --editor -- --holo-forge-handles-editor-test --holo-forge-screenshots=C:/shots

const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const F := preload("res://tests/holo_forge_assembly_fixtures.gd")
const MOUSE := preload("res://tests/holo_forge_mouse.gd")
const MODEL_CHECKS := preload("res://tests/holo_forge_handles_model_checks.gd")
const ASSEMBLY_CHECKS := preload("res://tests/holo_forge_handles_assembly_checks.gd")
const FORM_CHECKS := preload("res://tests/holo_forge_handles_form_checks.gd")
const SKETCH_CHECKS := preload("res://tests/holo_forge_handles_sketch_checks.gd")
const SCRIPT_ERRORS := preload("res://tests/holo_forge_script_error_logger.gd")
const SHOTS_ARG := "--holo-forge-screenshots="
const ONLY_ARG := "--holo-forge-handles-editor-only="
const SKIP_ARG := "--holo-forge-handles-editor-skip="
const SCENE := "res://tests/holo_forge/handles_editor_test.tscn"
const SCENE_NAME := "HandlesEditorTest"
const PROJECT_FILE := "res://project.godot"
## The headless editor's window is 1024 x 600; the hook gives it this size and puts the old back.
const HEADLESS_SIZE := Vector2i(1920, 1080)
const SECTIONS := ["primitives", "features", "insert", "inspect", "assemble", "mesh", "form", "sketch", "edges"]
const FIXTURES := {"stack": "StackPart", "types": "TypesPart", "mesh": "MeshPart"}

var m: RefCounted
var _tree: SceneTree
var _plugin: EditorPlugin
var _shots := ""
var _only := PackedStringArray()
var _skip := PackedStringArray()
var _window_size := Vector2i.ZERO
var _embedding := -1
var _passthrough := -1
var _real_events := 0
var _project_stamp := []
var _script_errors: Logger
var ws
var scene: Node
## The fixtures by key ("stack", "types", "mesh"): what tests/holo_forge_assembly_fixtures.gd made.
var designs := {}


func _on(section: String) -> bool:
	return (_only.is_empty() or _only.has(section)) and not _skip.has(section)


func run(plugin: EditorPlugin) -> void:
	_plugin = plugin
	_tree = plugin.get_tree()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(SHOTS_ARG):
			_shots = arg.trim_prefix(SHOTS_ARG)
		if arg.begins_with(ONLY_ARG):
			_only = arg.trim_prefix(ONLY_ARG).split(",", false)
		if arg.begins_with(SKIP_ARG):
			_skip = arg.trim_prefix(SKIP_ARG).split(",", false)
	if DisplayServer.get_name() == "headless":
		_shots = ""
	_tree.create_timer(1500.0).timeout.connect(func() -> void:
		print("FAIL Holo Forge HANDLES EDITOR: timed out during %s %s" % [m.section if m != null else "the start", m.failures if m != null else []])
		_restore_window()
		_tree.quit(1))
	if _shots != "":
		DirAccess.make_dir_recursive_absolute(_shots)
	if not ClassDB.class_exists("CadShape") or not ClassDB.class_exists("CadMesh"):
		print("FAIL Holo Forge HANDLES EDITOR: the native kernel (CadShape, CadMesh) is needed.")
		_tree.quit(1)
		return
	_project_watch("start")
	if not _build_scene():
		_finish()
		return
	var files := EditorInterface.get_resource_filesystem()
	files.update_file(SCENE)
	for i in 600:
		await _tree.process_frame
		if not files.is_scanning():
			break
	var opened := false
	var stable := 0
	for i in 900:
		await _tree.process_frame
		var root := EditorInterface.get_edited_scene_root()
		if root != null and root.name == SCENE_NAME and root.is_inside_tree():
			stable += 1
			if stable >= 30:
				opened = true
				break
		else:
			stable = 0
			if i % 30 == 0:
				EditorInterface.open_scene_from_path(SCENE)
	if not opened:
		print("FAIL Holo Forge HANDLES EDITOR: the hook's scene %s should open." % SCENE)
		_restore_window()
		_tree.quit(1)
		return
	scene = EditorInterface.get_edited_scene_root()
	EditorInterface.set_main_screen_editor("Forge")
	if DisplayServer.get_name() == "headless":
		var window: Window = EditorInterface.get_base_control().get_window()
		_window_size = window.size
		window.size = HEADLESS_SIZE
	for i in 5:
		await _tree.process_frame
	ws = plugin.get("workspace")
	if ws == null or ws.kernel == null:
		print("FAIL Holo Forge HANDLES EDITOR: the Forge workspace with its kernel is needed.")
		_restore_window()
		_tree.quit(1)
		return
	ws.theme_store = {}
	ws.set_theme_mode("dark")
	ws.toolbar.pin_store = {}
	m = MOUSE.new(_tree, ws)
	if DisplayServer.get_name() != "headless":
		# As the mesh and assembly hooks: the editor goes by the events' own positions, and the
		# real mouse goes through the window, so a user at the machine can't take the press.
		_embedding = 1 if m.gui.gui_embed_subwindows else 0
		m.gui.gui_embed_subwindows = true
		var window: Window = EditorInterface.get_base_control().get_window()
		if not window.window_input.is_connected(_on_real_input):
			window.window_input.connect(_on_real_input)
		_passthrough = 1 if window.mouse_passthrough else 0
		window.mouse_passthrough = true
	_project_watch("open")
	_script_errors = SCRIPT_ERRORS.new()
	OS.add_logger(_script_errors)
	for section in SECTIONS:
		if not _on(section):
			continue
		m.section = section
		var before: int = m.failures.size()
		match section:
			"primitives", "features", "insert", "inspect", "edges":
				await MODEL_CHECKS.run(m, self, section)
			"assemble", "mesh":
				await ASSEMBLY_CHECKS.run(m, self, section)
			"form":
				await FORM_CHECKS.run(m, self)
			"sketch":
				await SKETCH_CHECKS.run(m, self)
		await _leave()
		for error in _script_errors.take():
			m.check(false, "A script error broke the section: %s" % error)
		print("Forge HANDLES: section %s done, %d pulls, %d failure(s)" % [section, int(m.pulls.get(section, 0)), m.failures.size() - before])
		_project_watch(section)
	_finish()


# --- The hook's scene ----------------------------------------------------------------------------

## Builds tests/holo_forge/handles_editor_test.tscn from the fixtures and writes it with
## ResourceSaver (never through the editor).
func _build_scene() -> bool:
	if not SCENE.begins_with("res://tests/holo_forge/"):
		return false
	var root := Node3D.new()
	root.name = SCENE_NAME
	designs["stack"] = F.stack()
	designs["types"] = F.all_types()
	designs["mesh"] = F.mesh_block()
	var x := 0.0
	for key in FIXTURES:
		var part: Node3D = CAD_PART.new()
		part.name = FIXTURES[key]
		part.document = designs[key].doc
		part.position = Vector3(x, 0.0, 0.0)
		x += 0.4
		root.add_child(part)
		part.owner = root
	var packed := PackedScene.new()
	var packed_ok := packed.pack(root)
	var saved := ResourceSaver.save(packed, SCENE) if packed_ok == OK else packed_ok
	root.free()
	if saved != OK:
		print("FAIL Holo Forge HANDLES EDITOR: the hook's scene should be written (%s)." % error_string(saved))
	return saved == OK


## Makes a fixture part ("stack", "types", "mesh") the one the Forge edits, as selecting it does.
func edit_fixture(key: String) -> bool:
	var root := EditorInterface.get_edited_scene_root()
	if root != null and root.name == SCENE_NAME:
		scene = root
	var part: Node3D = scene.get_node_or_null(str(FIXTURES.get(key, ""))) if scene != null else null
	if part == null or not part.is_inside_tree():
		m.check(false, "The scene should hold %s." % FIXTURES.get(key, key))
		return false
	return await _select_part(part)


## A new blank part in the hook's scene (in memory only), made the Forge's part.
func blank_part() -> Node3D:
	await _leave()
	EditorInterface.get_selection().clear()
	await m.frames(2)
	var part: Node3D = ws.add_part_to_scene()
	await m.frames(3)
	m.check(part != null and ws.part == part, "A blank part should be added to edit.")
	return part if part != null and ws.part == part else null


func _select_part(part: Node3D) -> bool:
	await _leave()
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(part)
	for i in 60:
		await _tree.process_frame
		if ws.part == part and ws.doc != null and not (ws.result.get("bodies", {}) as Dictionary).is_empty():
			break
	m.check(ws.part == part, "Selecting %s should make it the Forge's part." % part.name)
	await m.frames(3)
	return ws.part == part


## Closes whatever a section left open (a command, a sketch, a form, Direct Edit).
func _leave() -> void:
	if ws.command != null:
		ws.cancel_command()
	if ws.mesh_direct_edit != null and ws.mesh_direct_edit.active:
		ws.mesh_direct_edit.cancel()
	if ws.form_editor != null and ws.form_editor.active:
		ws.form_editor.cancel_tool()
		ws.run_action("finish_form")
	if ws.sketch_editor != null and ws.sketch_editor.active:
		ws.run_action("finish_sketch")
	if ws.motion_study_panel != null and ws.motion_study_panel.visible:
		ws.motion_study_panel.close()
	m.button(m.g(Vector2(4, 4)), false)
	await m.frames(2)


# --- Screenshots ---------------------------------------------------------------------------------

func shot(file: String) -> void:
	if _shots == "":
		return
	await m.frames(2)
	ws.viewport.redraw_overlay()
	EditorInterface.get_base_control().queue_redraw()
	await RenderingServer.frame_post_draw
	var window: Window = EditorInterface.get_base_control().get_window()
	var picture := window.get_texture().get_image()
	var area: Rect2 = (ws.viewport as Control).get_global_rect()
	var rect := Rect2i(area).intersection(Rect2i(Vector2i.ZERO, picture.get_size()))
	picture.get_region(rect).save_png(_shots.path_join(file))
	print("Forge HANDLES: saved ", _shots.path_join(file))


func shots_on() -> bool:
	return _shots != ""


# --- The run -------------------------------------------------------------------------------------

func _project_watch(after: String) -> void:
	var stamp := [FileAccess.get_modified_time(PROJECT_FILE), FileAccess.get_md5(PROJECT_FILE)]
	if _project_stamp.is_empty():
		_project_stamp = stamp
	elif stamp != _project_stamp:
		if m != null:
			m.check(false, "The project's settings file was written during %s." % after)
		_project_stamp = stamp


func _on_real_input(event: InputEvent) -> void:
	if event is InputEventMouse:
		_real_events += 1


func _restore_window() -> void:
	var window: Window = EditorInterface.get_base_control().get_window()
	if window.window_input.is_connected(_on_real_input):
		window.window_input.disconnect(_on_real_input)
	if _passthrough >= 0:
		window.mouse_passthrough = _passthrough == 1
		_passthrough = -1
	if _window_size != Vector2i.ZERO:
		window.size = _window_size
		_window_size = Vector2i.ZERO
	if _embedding >= 0 and m != null:
		m.gui.gui_embed_subwindows = _embedding == 1
		_embedding = -1


func _finish() -> void:
	if DisplayServer.get_name() != "headless" and _real_events > 0:
		print("Forge HANDLES: the real mouse sent %d event(s) to the window during the run" % _real_events)
	await _tree.process_frame
	_restore_window()
	if _script_errors != null:
		OS.remove_logger(_script_errors)
		_script_errors = null
	for i in 2:
		await _tree.process_frame
	var failures: Array = m.failures if m != null else ["the run did not start"]
	var counts := PackedStringArray()
	if m != null:
		for key in m.pulls:
			counts.append("%s %d" % [key, int(m.pulls[key])])
	var ran := "%d handle drags (%s)" % [m.pull_count() if m != null else 0, ", ".join(counts)]
	if failures.is_empty() and (not _only.is_empty() or not _skip.is_empty()):
		print("PARTIAL Holo Forge HANDLES EDITOR: only some sections ran (only %s, skip %s), with no failure; %s. [%s]" % [",".join(_only), ",".join(_skip), ran, "; ".join(m.notes)])
	elif failures.is_empty():
		print("PASS Holo Forge HANDLES EDITOR: every view handle pulled with the mouse moved its field and its model by the drag, OK was one named undo step, undo and redo exact, Esc left the design; %s. [%s]" % [ran, "; ".join(m.notes)])
	else:
		print("FAIL Holo Forge HANDLES EDITOR: %d failure(s); %s: %s" % [failures.size(), ran, failures])
	_tree.quit(0 if failures.is_empty() else 1)
