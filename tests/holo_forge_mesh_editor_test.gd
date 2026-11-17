@tool
extends RefCounted
## The Mesh workspace inside the real editor (spec 5.5 and addendum 10.10 item 7; the test scene
## is never saved under its own name). Clicks, drags and keys are real events pushed into the
## editor's window (Viewport.push_input):
##   - the workspace switcher goes to Mesh and every Mesh tool up to Phase 7 is enabled;
##   - Mesh > Create > Insert Mesh brings a holed blob in through the file dialog and its prompt
##     (Body Type first), as a mesh body with the mesh icon in the browser and the open-edge
##     warning on its feature; Export STL also offers OBJ and 3MF;
##   - Close Holes previews its fills, closes the five holes in one undo step named "Forge: Mesh: Close
##     Holes" (undo opens them, redo closes them), with the tool's own chip on the timeline;
##   - a click picks a face group, the pinned Select Triangles button (shown pressed) switches to
##     triangles, a click picks one and Grow takes 4, then 10;
##   - Shift+F shows the face groups in colours that differ between neighbours, and hides them;
##   - a typed value stays typed (also one typed the same as the panel's own), an untouched one
##     follows the picked body; Remesh's Minimum Edge is no input until it is typed; Close Holes
##     shows Match Edge Size for Flat; Reduce and Smooth have their Sharp Edge Angle;
##   - Reduce with 50 typed into Keep shows the report's numbers in the stat row within a second
##     and keeps half the triangles within 2 %;
##   - Direct Edit deletes ten triangles, fills the hole, moves a triangle by a dragged arrow and
##     keeps it all as one feature in one undo step;
##   - Plane Cut takes a construction plane picked in the view, its arrow is dragged with the
##     mouse, the removed part and the cap are drawn, and OK leaves a closed body;
##   - Convert Mesh: Faceted makes a solid that Fillet can pick, and Fillet on a mesh body says the
##     gate sentence; a small convert previews its solid and its stat line and a big one waits
##     for OK; Prismatic converts the L-bracket after Generate Face Groups (New Body hides the
##     mesh body once), Replace takes the mesh body out, Organic makes a smooth solid (5,000 cage
##     faces are refused by the time estimate) or, as a Form Body, a Form feature holding the
##     cage; each is one undo step that undo takes back;
##   - Mesh Align's three-point slot, Combine's slot of mesh and solid tools, Texture Extrude's
##     Choose File and Scale Mesh's point slot are filled by clicks and build;
##   - picks made while the preview shows the tool's result land on the mesh the tool works on: a
##     hole picked at its fill's rim (Close Holes), a second triangle after the first was erased
##     (Erase and Fill);
##   - an existing Close Holes and an existing Erase and Fill are opened by a double-click on
##     their chips: picks made then are of the mesh before the feature;
##   - a face group or a triangle clicked for a panel's slot, a clicked hole, and face groups or
##     triangles a tool takes over from the selection are stored with a point on them and the
##     facing there; with them Reverse Normal stays on its face, and says that the group moved,
##     when a cut put before Generate Face Groups renames the groups; an old pick kept by name alone says on its chip that it could not be confirmed; the preview of an early Scale Mesh stops after it with Reduce, Smooth and Remesh waiting (their chips say so, none as failed), a body a later feature brings in stays in the view, the browser and the selection, and OK and Cancel rebuild the whole timeline; a pair that nearly touches is a remark under the interference list, not an interference; an old pick kept by name
##     alone says on its chip that it could not be confirmed;
##   - an early Scale Mesh with Reduce, Smooth and Remesh after it is opened from the timeline: its
##     preview stops after it (the later chips say that they are not shown, none as failed), the
##     body shows as it leaves the Scale, a body a later feature brings in stays in the view, the
##     browser and the selection and can't be picked for the tool; OK and Cancel (also with
##     nothing changed) end with the whole timeline rebuilt;
##   - a Mesh tool's panel stands clear of the body the tool works on where the view has room,
##     moves off it when the view is panned, stays inside the view, keeps its result row in sight
##     when it is short; a value set from outside shows in the field that has the keyboard, a
##     typed one is left alone; a click on the active slot leaves it active;
##   - Direct Edit's Move arrows start at the selection; Mesh Align's points are numbered dots;
##   - the warnings, notes and errors given to the mass and interference panels are all printed,
##     an insert says its warning, the timeline keeps it in the chip's tooltip, a long status
##     message wraps inside the view; a file that looks cut off is said in the Insert Mesh
##     prompt; OK says that it is computing before its full-time rebuild; a Direct Edit that
##     leaves no triangle is stored as "emptied";
##   - the browser's right-click menu on a mesh body offers Convert Mesh, Reduce and Close Holes;
##   - dark and light recolour the mesh materials; team M's in-editor checks run (one scenario per
##     Mesh tool); a hover pick on a 1,009,200-triangle body is timed against a GDScript
##     calibration; a copy of the scene saved with a large stored mesh writes one
##     <part>_mesh_<digest>.res beside it and loads back to the same mesh (the copy is deleted).
## With --holo-forge-screenshots=<dir> in a windowed editor it also saves PNGs in both themes.
##
## godot --headless --path . --editor -- --holo-forge-mesh-editor-test
## godot --path . --editor -- --holo-forge-mesh-editor-test --holo-forge-screenshots=C:/shots

const CATALOG := preload("res://addons/holo_forge/tools/catalog.gd")
const FEATURE_COMMAND := preload("res://addons/holo_forge/tools/feature_command.gd")
const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")
const MESH_FEATURE := preload("res://addons/holo_forge/core/features/mesh.gd")
const MESH_BLOB := preload("res://addons/holo_forge/core/mesh/mesh_blob.gd")
const INSERT := preload("res://addons/holo_forge/core/features/insert.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const TIMELINE := preload("res://addons/holo_forge/ui/timeline.gd")
const TIMING := preload("res://tests/holo_forge_timing.gd")
const CHECKS := preload("res://tests/holo_forge_mesh_editor_checks.gd")
const FIXTURES := preload("res://tests/holo_forge_mesh_fixtures.gd")
const SHOTS_ARG := "--holo-forge-screenshots="
## For working on the hook: --holo-forge-mesh-editor-only=reduce,save runs only those parts (after
## the workspace, the insert and the hook's model) and ends with PARTIAL, never PASS.
const ONLY_ARG := "--holo-forge-mesh-editor-only="
## --holo-forge-mesh-editor-skip=save leaves parts out (the part that saves a scene, in a run that
## is only for screenshots); such a run ends with PARTIAL too.
const SKIP_ARG := "--holo-forge-mesh-editor-skip="
## Where the hook may write in the project: its test folder, and the editor's own state.
const OWN_FOLDERS := ["res://tests/holo_forge/", "res://.godot/"]
## Files a scene save never writes, which other work on this machine may be changing meanwhile
## (sources, build output): left out of the check that a save touches nothing else.
const NOT_SAVED := ["gd", "uid", "md", "cpp", "h", "hpp", "py", "dll", "lib", "pdb", "exp", "obj", "ilk", "log", "txt", "tmp"]
const APPEARANCE := preload("res://addons/holo_forge/core/appearance.gd")
const TMP_SCENE := "res://tests/holo_forge/_mesh_hook_tmp.tscn"
const PROJECT_FILE := "res://project.godot"
const MM := 0.001
const XY := {"kind": "origin", "name": "xy"}

## The hover timing limit (5.5 #14): 2 x the largest ratio measured on the dev machine on 2026-11-12
## against a 200k-iteration GDScript float loop. A mouse move over the 1,009,200-triangle grid
## (the pick and the hover's highlight) measured 0.34 to 0.48 ms against 19.6 ms, ratio 0.017 to
## 0.025, picking face groups and picking triangles (the 4 ms target is a ratio of about 0.2).
const HOVER_RATIO_LIMIT := 0.05
## In a real window the hover's highlight also goes through the graphics driver (its mesh is made
## and handed to the GPU on every move), which another program drawing on the same GPU slows while
## the CPU calibration is not: on 2026-11-13 the same build measured 0.021 to 0.029 in a window
## when the machine was quiet and 0.060 to 0.066 while it was busy (calibration 29 to 31 ms against
## 17 to 18 ms), with the pick itself at 0.08 ms. Twice the busy reading, and still half the 4 ms
## target. Headless runs keep HOVER_RATIO_LIMIT.
const WINDOWED_HOVER_RATIO_LIMIT := 0.12
## The headless editor's window is 1024 x 600, which leaves the Forge view 207 x 250 px: too small
## for a command panel beside a body. The hook gives it this size and puts the old one back.
const HEADLESS_SIZE := Vector2i(1920, 1080)

## What a run without a failure has shown (the PASS line).
const PASSED := "the switcher opens the Mesh workspace with every Phase 7 tool enabled; Insert Mesh through the file dialog and its Body Type prompt makes a mesh body (mesh icon, size, open-edge warning; Export STL offers OBJ and 3MF); Close Holes previews its fills, closes 5 holes in one step named Mesh: Close Holes, undo and redo; a click picks a face group, the pinned Select Triangles button shows pressed, a click picks a triangle, Grow takes 4 then 10, a window takes the near triangles; Shift+F colours the face groups with neighbours differing; typed values stay typed and untouched ones follow the body, Remesh's Minimum Edge waits to be typed, Match Edge Size shows for Flat, Reduce and Smooth have Sharp Edge Angle; Reduce's stat row shows the report within a second and keeps half within 2 percent; Direct Edit deletes, fills, undoes, moves by a dragged arrow and keeps one feature in one step; Plane Cut takes a construction plane, its dragged arrow, draws the removed part and the cap and leaves a closed body; Convert Mesh: Faceted makes a solid Fillet picks on, and Fillet on a mesh body says the gate; the browser's right-click menu opens Reduce; Mesh Align by three points, Combine with a mesh and a solid tool, Texture Extrude's Choose File and Scale Mesh about a picked corner build in one step each; with the preview's result on screen, a click at a fill's rim picks that hole and a second click picks the triangle of the mesh the tool works on; an existing Close Holes and Erase and Fill opened from the timeline take their picks on the mesh before them and count from it; a face group, a triangle and a hole clicked for a panel's slot and a selection a tool takes over are stored with a point and the facing there, and Reverse Normal stays on its face and says the group moved when a cut put before Generate Face Groups renames the groups; an old pick kept by name alone says on its chip that it could not be confirmed; the preview of an early Scale Mesh stops after it with Reduce, Smooth and Remesh waiting (their chips say so, none as failed), a body a later feature brings in stays in the view, the browser and the selection, and OK and Cancel rebuild the whole timeline; a pair that nearly touches is a remark under the interference list, not an interference; a Mesh tool's panel stands clear of the picked body, moves off it when the view is panned, stays inside the view, keeps its result row in sight when short, shows a value set while its field has the keyboard and leaves a clicked active slot active; Direct Edit's arrows start at the selection and Mesh Align's points are dots that follow the preview; every warning, note and error given to the mass and interference panels is printed, the insert says its warning, the timeline keeps it in the tooltip and a long status message wraps; a file that looks cut off is said in the Insert Mesh prompt, the status line and the chip; OK says that it is computing before the full-time rebuild; a Direct Edit with no triangle left is stored as emptied; a small convert previews its solid and stat line and a big one waits for OK; Prismatic converts the L-bracket after Generate Face Groups, New Body hides the mesh body once, Replace takes it out, Organic makes a smooth solid and refuses 5,000 cage faces by its time estimate, Output Form Body leaves a Form feature with the cage that opens for sculpting, each in one undo step that undo takes back; the themes recolour the mesh materials; team M's checks pass; a mouse move over a million triangles stays in its ratio; a large stored mesh is saved beside the copy of the scene and loads back."

var failures: Array[String] = []
var notes: Array[String] = []
var _tree: SceneTree
var _shots := ""
var _mouse := Vector2.ZERO
var _window_size := Vector2i.ZERO
## project.godot as it was when the hook started: [modified time, md5] (see _project_watch).
var _project_stamp := []
## When the last character was typed (Time.get_ticks_msec), for timing what follows a typed value.
var _last_key_msec := 0
## Whether the editor window embedded its sub-windows before the hook made it (-1: not changed).
var _embedding := -1
## Mouse events from the system (the real mouse) that reached the editor window during a windowed
## run, and the hook's step when the last one came.
var _real_events := 0
## Whether the window let the mouse through before the hook made it (-1: not changed).
var _passthrough := -1
var _real_last := ""
var _step := ""
var _only := PackedStringArray()
var _skip := PackedStringArray()
var ws
var gui: Viewport
var history: UndoRedo
var doc: Resource
var part: Node3D
## The blob the first checks work on, and the bodies of the hook's own model.
var blob := ""
var model := {}
var image := ""


func check(ok: bool, detail: String) -> void:
	if not ok:
		detail += _real_mouse()
		failures.append(detail)
		push_error(detail)
		print("FAIL: ", detail)


func _on(section: String) -> bool:
	return not _skip.has(section) and (_only.is_empty() or _only.has(section))


func note(text: String) -> void:
	notes.append(text)
	print("Forge MESH: ", text)


func run(plugin: EditorPlugin) -> void:
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
	_tree.create_timer(1500.0 if _shots != "" else 900.0).timeout.connect(func() -> void:
		print("FAIL Holo Forge MESH EDITOR: timed out ", failures)
		_restore_window()
		_tree.quit(1))
	if _shots != "":
		DirAccess.make_dir_recursive_absolute(_shots)
	var stable := 0
	for i in 900:
		await _tree.process_frame
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
		push_error("Holo Forge mesh editor test could not open its scene.")
		_tree.quit(1)
		return
	EditorInterface.set_main_screen_editor("Forge")
	if DisplayServer.get_name() == "headless":
		var window: Window = EditorInterface.get_base_control().get_window()
		_window_size = window.size
		window.size = HEADLESS_SIZE
	await _frames(5)
	ws = plugin.get("workspace")
	if ws == null or ws.kernel == null or not ClassDB.class_exists("CadMesh"):
		check(false, "The Forge workspace with the native kernel (CadMesh) is needed.")
		_finish()
		return
	ws.theme_store = {}
	ws.set_theme_mode("dark")
	ws.toolbar.pin_store = {}
	part = ws.add_part_to_scene()
	await _frames(2)
	if part == null or ws.part != part:
		check(false, "A part should be added to edit.")
		_finish()
		return
	doc = part.document
	gui = ws.viewport.get_viewport()
	if DisplayServer.get_name() != "headless":
		# In a real window the editor works out what the mouse is over from where the real cursor
		# is, whenever a mouse event comes in: with the cursor resting anywhere over the window,
		# nothing the hook moves to would hover, and a Button presses only while hovered. With its
		# windows embedded (as in the editor's single window mode, and as a headless run is) it
		# goes by the events' own positions. Put back when the hook ends.
		_embedding = 1 if gui.gui_embed_subwindows else 0
		gui.gui_embed_subwindows = true
		# The mouse events the system sends while the hook runs (someone moving the real mouse over
		# the window, or clicking it) are counted: they change what the mouse is over and where the
		# keyboard is, so a check that fails while they came in says so.
		var window: Window = EditorInterface.get_base_control().get_window()
		if not window.window_input.is_connected(_on_real_input):
			window.window_input.connect(_on_real_input)
		# And the system's mouse is let through the window to whatever is under it, so that a real
		# click (the user at the machine) can't take the keyboard from a field the hook typed into,
		# or hold a control's mouse focus while the hook clicks elsewhere. Put back when it ends.
		_passthrough = 1 if window.mouse_passthrough else 0
		window.mouse_passthrough = true
	history = ws.history()
	check(history != null, "The part's scene should have an undo history.")
	_project_watch("start")
	await _check_workspace()
	_project_watch("check_workspace")
	await _check_insert_and_dialogs()
	_project_watch("check_insert_and_dialogs")
	if blob == "" or history == null:
		_finish()
		return
	if _on("close_holes"):
		await _check_close_holes()
		_project_watch("check_close_holes")
	if _on("selection"):
		await _check_selection()
		_project_watch("check_selection")
	if _on("face_groups"):
		await _check_face_groups()
		_project_watch("check_face_groups")
	if _on("typed"):
		await _check_typed_values()
		_project_watch("check_typed_values")
	if _on("reduce"):
		await _check_reduce()
		_project_watch("check_reduce")
	if _on("direct_edit"):
		await _check_direct_edit()
		_project_watch("check_direct_edit")
	if _on("plane_cut"):
		await _check_plane_cut()
		_project_watch("check_plane_cut")
	if _on("gate"):
		await _check_convert_and_gate()
		_project_watch("check_convert_and_gate")
	if _on("browser"):
		await _check_browser_menu()
		_project_watch("check_browser_menu")
	if _shots != "":
		await _shot("workspace_dark.png", true)
	await _setup_model()
	_project_watch("setup_model")
	if _on("align"):
		await _check_align_points()
		_project_watch("check_align_points")
	if _on("combine"):
		await _check_combine_slots()
		_project_watch("check_combine_slots")
	if _on("texture"):
		await _check_texture_file()
		_project_watch("check_texture_file")
	if _on("scale"):
		await _check_scale_point()
		_project_watch("check_scale_point")
	if _on("picks"):
		await _check_picks_under_preview()
		_project_watch("check_picks_under_preview")
	if _on("edit"):
		await _check_edit_existing()
		_project_watch("check_edit_existing")
	if _on("anchors"):
		await _check_pick_anchors()
		_project_watch("check_pick_anchors")
	if _on("later"):
		await _check_preview_stops()
		_project_watch("check_preview_stops")
	if _on("panel"):
		await _check_panel_placement()
		_project_watch("check_panel_placement")
		await _check_panel_fields()
		_project_watch("check_panel_fields")
	if _on("warnings"):
		await _check_warnings_shown()
		_project_watch("check_warnings_shown")
	if _on("convert"):
		await _check_convert_more()
		_project_watch("check_convert_more")
	if _shots != "":
		await _tool_shots("dark")
		_project_watch("tool_shots")
	if _on("themes"):
		await _check_themes()
		_project_watch("check_themes")
	if _shots != "":
		ws.set_theme_mode("light")
		await _frames(2)
		await _tool_shots("light")
		_project_watch("tool_shots")
		await _light_shots()
		_project_watch("light_shots")
		ws.set_theme_mode("dark")
		await _frames(2)
	if _on("checks"):
		await _check_mesh_checks()
		_project_watch("check_mesh_checks")
	if _on("performance"):
		await _check_performance()
		_project_watch("check_performance")
	if _on("save"):
		await _check_save_reload()
		_project_watch("check_save_reload")
	_finish()


# --- Input ---------------------------------------------------------------------------------------

func _frames(count: int) -> void:
	for i in count:
		await _tree.process_frame


## A point of the Forge view (its own coordinates) in the editor window's.
func _g(local: Vector2) -> Vector2:
	return (ws.viewport as Control).global_position + local


func _center(control: Control) -> Vector2:
	return control.global_position + control.size * 0.5


func _button(at: Vector2, pressed: bool, opts := {}) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = int(opts.get("button", MOUSE_BUTTON_LEFT))
	event.pressed = pressed
	event.position = at
	event.global_position = at
	event.shift_pressed = bool(opts.get("shift", false))
	event.ctrl_pressed = bool(opts.get("ctrl", false))
	event.button_mask = (MOUSE_BUTTON_MASK_RIGHT if event.button_index == MOUSE_BUTTON_RIGHT else MOUSE_BUTTON_MASK_LEFT) if pressed else 0
	_mouse = at
	gui.push_input(event, true)


func _move(to: Vector2, mask := 0) -> void:
	# The window hears that the mouse is over it, as it does from the system when the real cursor
	# enters: while the real cursor is somewhere else (a windowed run), a mouse move reaches no
	# control, so nothing hovers and a Button, which presses only while hovered, takes no click.
	gui.notification(Node.NOTIFICATION_VP_MOUSE_ENTER)
	var event := InputEventMouseMotion.new()
	event.position = to
	event.global_position = to
	event.relative = to - _mouse
	event.button_mask = mask
	_mouse = to
	gui.push_input(event, true)


## The mouse goes to a point, down and up there, all in one frame. In a window the editor hears of
## the real cursor between frames (a tooltip that closes is enough for the system to report it
## again): what the mouse is over is then worked out from where the real cursor is, and a move
## that arrives between a press and its release takes the click away from a button.
func _tap(at: Vector2, opts := {}) -> void:
	_move(at)
	_button(at, true, opts)
	_button(at, false, opts)


## A real click at a point of the editor window.
func _click(at: Vector2, opts := {}) -> void:
	_move(at)
	await _tree.process_frame
	_tap(at, opts)
	await _tree.process_frame


## A real click on a control, where it is when the button goes down: a command panel that grows
## (a slot's text, a longer stat line) moves to stay inside the view, and its controls with it.
func _press(control: Control, opts := {}) -> void:
	if control == null or not control.is_visible_in_tree():
		check(false, "A control to click is missing or hidden (%s)." % [control])
		return
	var at := _center(control)
	_move(at)
	for i in 4:
		await _tree.process_frame
		if _center(control).is_equal_approx(at):
			break
		at = _center(control)
		_move(at)
	_tap(at, opts)
	await _tree.process_frame


## A real left drag between two points of the editor window.
func _drag(a: Vector2, b: Vector2, steps := 8) -> void:
	_move(a)
	await _tree.process_frame
	# (Press, moves and release in one frame, as _tap() does.)
	_move(a)
	_button(a, true)
	for i in range(1, steps + 1):
		_move(a.lerp(b, float(i) / steps), MOUSE_BUTTON_MASK_LEFT)
	_button(b, false)
	await _tree.process_frame


func _key(code: Key, opts := {}) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = pressed
		event.shift_pressed = bool(opts.get("shift", false))
		event.ctrl_pressed = bool(opts.get("ctrl", false))
		gui.push_input(event)
		await _tree.process_frame


func _type(text: String) -> void:
	for ch in text:
		for pressed in [true, false]:
			var event := InputEventKey.new()
			event.keycode = OS.find_keycode_from_string(ch)
			event.unicode = ch.unicode_at(0) if pressed else 0
			event.pressed = pressed
			if pressed:
				_last_key_msec = Time.get_ticks_msec()
			gui.push_input(event)
			await _tree.process_frame


## Clicks into a panel field, selects what it holds and types text over it.
func _type_into(key: String, text: String) -> void:
	var field := ws.panel._editors.get(key) as LineEdit
	if field == null or not field.is_visible_in_tree():
		check(false, "The %s field should be in the panel." % key)
		return
	await _press(field)
	check(field.has_focus(), "A click on the %s field should give it the keyboard (the mouse is over %s)." % [key, gui.gui_get_hovered_control()])
	await _key(KEY_A, {"ctrl": true})
	await _type(text)
	await _frames(2)


## Gives the view the keyboard, as a click in it does.
func _open_windows() -> Array:
	var found := []
	for node in EditorInterface.get_base_control().get_window().find_children("*", "Window", true, false):
		if (node as Window).visible:
			found.append(str(node.name) + ":" + node.get_class())
	return found


func _focus_view() -> void:
	ws.viewport.focus_view()
	await _tree.process_frame


# --- Helpers -------------------------------------------------------------------------------------

func _shape(body_id: String) -> RefCounted:
	var entry: Dictionary = ws.result.get("bodies", {}).get(body_id, {})
	return entry.get("shape")


func _mesh(body_id: String) -> RefCounted:
	var shape := _shape(body_id)
	return shape if MESH_BODY.is_mesh(shape) else null


func _open_edges(mesh: RefCounted) -> int:
	if mesh == null:
		return -1
	var found: Dictionary = mesh.check(5.0)
	return int(found.get("boundary_edges", -1)) if not found.is_empty() else -1


func _select_body(body_id: String) -> void:
	ws.selection.clear()
	ws.mesh_selection.clear()
	ws.selection.append({"kind": "body", "body": body_id, "index": -1, "point": Vector3.ZERO})
	ws._selection_changed(true)


func _nothing_selected() -> void:
	ws.selection.clear()
	ws.mesh_selection.clear()
	ws._selection_changed(true)


func _tool(id: String) -> Dictionary:
	var tool := CATALOG.find(id)
	check(not tool.is_empty(), "The catalog should hold %s." % id)
	return tool


## Points the view at bodies (all of them when none are given), from the usual side. aside: how
## far the bodies sit left of the middle, in view distances (so the command panel on the right
## leaves them clear in a screenshot).
func _look_at(body_ids: Array = [], yaw := 0.7, pitch := -0.5, aside := 0.0) -> void:
	var box := AABB()
	var first := true
	for body_id in (body_ids if not body_ids.is_empty() else ws.result.bodies.keys()):
		var shape := _shape(str(body_id))
		if shape == null or not doc.body_visible(str(body_id)):
			continue
		box = shape.bbox() if first else box.merge(shape.bbox())
		first = false
	if first:
		return
	var distance := maxf(box.size.length() * 2.2, 0.02)
	var right := Basis.from_euler(Vector3(pitch, yaw, 0.0)).x
	ws.viewport.set_view_state({"target": box.get_center() + right * distance * aside, "distance": distance, "yaw": yaw, "pitch": pitch})
	await _frames(2)


## True where a click in the view would land on one of its own controls (the command panel,
## Direct Edit's panel, the view cube, the navigation bar) or on a handle.
func _covered(local: Vector2) -> bool:
	var view: Control = ws.viewport
	if local.x < 30.0 or local.y < 50.0 or local.x > view.size.x - 30.0 or local.y > view.size.y - 70.0:
		return true
	for over in [ws.panel, ws.mesh_direct_edit.panel, view.view_cube(), view.nav_bar()]:
		if over != null and is_instance_valid(over) and (over as Control).visible and Rect2((over as Control).position, (over as Control).size).grow(6.0).has_point(local):
			return true
	return not (view._handle_at(local) as Dictionary).is_empty()


## Points of the view (its own coordinates) where the nearest thing under the cursor is body_id,
## nearest the middle of the view first. facing: only where the surface faces that way.
func _points_on(body_id: String, facing := Vector3.ZERO) -> Array:
	var view: Control = ws.viewport
	var found := []
	var step := 22.0
	var y := 60.0
	while y < view.size.y - 70.0:
		var x := 40.0
		while x < view.size.x - 40.0:
			var at := Vector2(x, y)
			x += step
			if _covered(at):
				continue
			var hit: Dictionary = view.face_hit_at(at)
			if hit.is_empty() or str(hit.body) != body_id:
				continue
			if not facing.is_zero_approx() and (hit.get("normal", Vector3.ZERO) as Vector3).dot(facing) < 0.99:
				continue
			found.append(at)
		y += step
	var middle: Vector2 = view.size * 0.5
	found.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.distance_squared_to(middle) < b.distance_squared_to(middle))
	return found


func _point_on(body_id: String, index := 0) -> Vector2:
	var points := _points_on(body_id)
	check(points.size() > index, "%s should be under the cursor somewhere in the view." % doc.body_name(body_id))
	return points[mini(index, points.size() - 1)] if not points.is_empty() else Vector2(-1, -1)


## Waits for the running Mesh tool's preview (its queued rebuild) and gives the stat row's text.
func _stat(frames := 6) -> String:
	await _frames(frames)
	return str(ws.panel.info("stat")) if ws.command != null else ""


func _chip(feature_id: String) -> Button:
	for chip in ws.timeline._chips:
		if str((chip as Button).get_meta("feature_id", "")) == feature_id:
			return chip
	return null


## The pinned icon button of a Mesh > Select tool on the bar, by its action.
func _bar_button(action: String) -> Button:
	for button in ws.toolbar.icon_buttons("Select"):
		if str(CATALOG.find(str(button.get_meta("tool_id", ""))).get("action", "")) == action:
			return button
	return null


func _add_mesh(mesh: RefCounted, name: String) -> String:
	var feature: Resource = ws.doc.add_feature("mesh_import", "Mesh", {}, {
		"path": "", "kind": INSERT.KIND_MESH, "units": "mm", "mesh_units": "mm", "linked": false, "split": false,
		"transform": Transform3D.IDENTITY, "operation": OPERATIONS.NEW_BODY, "mesh": MESH_BLOB.from_mesh(mesh),
	})
	var body_id: String = ws.doc.new_body(feature.id)
	feature.options["body_id"] = body_id
	ws.doc.bodies[body_id]["name"] = name
	return body_id


func _moved(fixture: Dictionary, to: Vector3) -> RefCounted:
	return FIXTURES.to_mesh(fixture).transformed(Transform3D(Basis.IDENTITY, to))


## Presses the panel's OK with a real click.
func _ok() -> void:
	await _press(ws.panel._ok)
	await _frames(4)


func _undo_name() -> String:
	return history.get_current_action_name() if history != null else ""


# --- 5.5 #2: the Mesh workspace -----------------------------------------------------------------

func _check_workspace() -> void:
	var switcher: OptionButton = ws.toolbar.workspace_switcher()
	await _press(switcher)
	await _frames(2)
	var list := switcher.get_popup()
	check(list.visible, "A click on the switcher should open the list of workspaces.")
	# The list is a window of its own: its entry is chosen as a click on it does.
	list.index_pressed.emit(CATALOG.WORKSPACES.find("Mesh"))
	list.hide()
	await _frames(3)
	check(ws.workspace == "Mesh" and ws.toolbar.workspace == "Mesh", "The switcher should go to the Mesh workspace (%s)." % ws.workspace)
	var greyed := []
	var later_on := []
	for tool in CATALOG.all_tools():
		if tool.workspace != "Mesh":
			continue
		if int(tool.phase) <= 7 and not CATALOG.is_enabled(tool):
			greyed.append(tool.name)
		if int(tool.phase) > CATALOG.IMPLEMENTED_PHASE and CATALOG.is_enabled(tool):
			later_on.append(tool.name)
	check(greyed.is_empty() and later_on.is_empty(), "Every Mesh tool up to the implemented phase should be enabled and the later ones greyed (greyed %s, on %s)." % [greyed, later_on])
	for group in ["Create", "Prepare", "Modify", "Select"]:
		check(ws.toolbar.group_menu(group) != null, "The Mesh workspace should have a %s menu." % group.to_upper())
	# The two pick modes pinned to the bar: greyed while there is no mesh body.
	ws.toolbar.pin("mesh.select.select_face_groups", true)
	ws.toolbar.pin("mesh.select.select_triangles", true)
	await _frames(3)
	ws._sync_mesh_tools()
	var groups := _bar_button("mesh_pick_groups")
	var triangles := _bar_button("mesh_pick_triangles")
	check(groups != null and triangles != null and groups.disabled and triangles.disabled, "The pinned pick mode tools should be greyed without a mesh body.")


# --- 5.5 #3, 10.10: Insert Mesh through its dialogs, Export STL's formats -----------------------

func _check_insert_and_dialogs() -> void:
	var path := ProjectSettings.globalize_path(FIXTURES.write_stl(FIXTURES.holed_blob(), "hook/holed_blob.stl", 1000.0))
	var mark := history.get_current_action()
	ws.run_tool(_tool("mesh.create.insert_mesh"))
	await _frames(2)
	var dialog: Window = ws.files._file_dialog
	check(dialog != null and dialog.visible and dialog.title == "Insert Mesh", "Mesh > Create > Insert Mesh should open the file dialog.")
	if dialog == null:
		return
	dialog.hide()
	ws.files._file_chosen(path)
	await _frames(2)
	var prompt: ConfirmationDialog = ws.files._options
	var kind := ws.files._options_editors.get("kind") as OptionButton
	check(prompt != null and prompt.visible and kind != null and kind.item_count == 2 and str(kind.get_item_metadata(maxi(kind.selected, 0))) == INSERT.KIND_MESH
		and kind.get_item_text(maxi(kind.selected, 0)) == "Mesh Body" and ws.files._options_editors.has("units") and ws.files._options_editors.has("z_up"),
		"The Insert Mesh prompt should start on Body Type: Mesh Body, with the unit and Z-up rows.")
	if prompt == null or kind == null:
		return
	prompt.get_ok_button().pressed.emit()
	await _frames(5)
	doc = ws.doc
	var meshes: Dictionary = ws.mesh_shapes()
	check(meshes.size() == 1 and history.get_current_action() == mark + 1 and _undo_name() == "Forge: Mesh: Insert Mesh",
		"The file should come in as one mesh body in one undo step named Mesh: Insert Mesh (%d bodies, step '%s')." % [meshes.size(), _undo_name()])
	if meshes.size() != 1:
		return
	blob = str(meshes.keys()[0])
	var mesh: RefCounted = meshes[blob]
	var feature: Resource = doc.features.back()
	check(int(mesh.triangle_count()) == 4797 and mesh.boundary_loops().size() == 5, "The blob should have 4,797 triangles and 5 holes (%d, %d)." % [mesh.triangle_count(), mesh.boundary_loops().size()])
	var warning := str(ws.result.warnings.get(feature.id, ""))
	check(warning.contains("open edge") and warning.contains("Close Holes"), "The feature should warn of the open edges (%s)." % warning)
	# The browser: the mesh icon and the body's size.
	var item: TreeItem = ws.browser.body_item(blob)
	var mesh_icon: Texture2D = EditorInterface.get_editor_theme().get_icon("ArrayMesh", "EditorIcons")
	check(item != null and item.get_icon(0) == mesh_icon and item.get_tooltip_text(0).contains("4,797 triangles") and item.get_tooltip_text(0).contains("Open"),
		"The browser should show the mesh body with the mesh icon and its size (%s)." % (item.get_tooltip_text(0) if item != null else "no item"))
	var chip := _chip(feature.id)
	check(chip != null and chip.icon != null and chip.text.contains("holed_blob.stl"), "The timeline should show the insert with its file's name.")
	# The feature's warning is said with the insert and kept in the chip's tooltip, wrapped.
	check(ws.last_message.begins_with("Inserted holed_blob.stl as a mesh body (4,797 triangles).") and ws.last_message.contains("open edge"), "The insert's message should carry the warning (%s)." % ws.last_message)
	var tip_lines := chip.tooltip_text.get_slice("Note: ", 1).split("\n") if chip != null else PackedStringArray()
	var longest := 0
	for line in tip_lines:
		longest = maxi(longest, line.length())
	check(chip != null and chip.tooltip_text.contains("Note: ") and chip.tooltip_text.contains("open edge") and longest <= 84, "The chip's tooltip should carry the warning in lines that fit (%d characters at most: %s)." % [longest, chip.tooltip_text if chip != null else ""])
	check(ws._status.get_line_count() >= 1 and (ws._status as Control).size.x <= ws.viewport.size.x - 100.0 and ws._status.autowrap_mode != TextServer.AUTOWRAP_OFF, "The status line should wrap inside the view.")
	ws._sync_mesh_tools()
	check(_bar_button("mesh_pick_groups") != null and not _bar_button("mesh_pick_groups").disabled and _bar_button("mesh_pick_groups").button_pressed and not _bar_button("mesh_pick_triangles").button_pressed,
		"With a mesh body the pick mode tools are enabled and Select Face Groups shows pressed.")
	# Outside the Mesh workspace the prompt starts on a faceted solid, as before.
	ws.files._mesh_chosen(path)
	await _frames(1)
	kind = ws.files._options_editors.get("kind") as OptionButton
	check(kind != null and str(kind.get_item_metadata(maxi(kind.selected, 0))) == INSERT.KIND_SOLID, "Insert Mesh elsewhere should start on Solid (faceted).")
	ws.files._options.hide()
	# Export STL: STL, and OBJ and 3MF for mesh bodies.
	ws.run_action("export_stl")
	await _frames(2)
	var filters := " ".join((ws.files._file_dialog as EditorFileDialog).filters)
	check(ws.files._file_dialog.visible and filters.contains("*.stl") and filters.contains("*.obj") and filters.contains("*.3mf"), "Export STL should offer STL, OBJ and 3MF (%s)." % filters)
	ws.files._file_dialog.hide()
	var report: Dictionary = ws.files.export_cad_report(ProjectSettings.globalize_path(FIXTURES.DIR + "/hook/out.obj"))
	check(str(report.error) == "" and (report.written as Array) == [blob], "OBJ export should write the mesh body (%s)." % [report])
	report = ws.files.export_cad_report(ProjectSettings.globalize_path(FIXTURES.DIR + "/hook/out.step"))
	check(str(report.error) != "" or (report.skipped as Array) == [blob], "STEP export should leave the mesh body out and say so (%s)." % [report])
	# (The export's sentence stays in the status line for a while: the next part's screenshots
	# should not show it, so the status line goes back to the model's own.)
	ws._status_timer.stop()
	ws._update_status()
	await _look_at()


# --- 5.5 #4, 10.10: Close Holes (the Fill overlay, the stat row, one step, undo and redo) -------

## Selects a body with a real click on its row in the browser.
func _click_in_browser(body_id: String, opts := {}) -> void:
	var item: TreeItem = ws.browser.body_item(body_id)
	if item == null:
		check(false, "%s should be listed in the browser." % body_id)
		return
	ws.browser.scroll_to_item(item)
	await _frames(2)
	var rect: Rect2 = ws.browser.get_item_area_rect(item, 0)
	await _click((ws.browser as Control).global_position + rect.position + Vector2(minf(60.0, rect.size.x * 0.5), rect.size.y * 0.5), opts)
	await _frames(2)


func _check_close_holes() -> void:
	await _click_in_browser(blob)
	check(ws._selected_bodies().has(blob), "A click on the body's row in the browser should select it.")
	_select_body(blob)
	var mark := history.get_current_action()
	ws.run_tool(_tool("mesh.prepare.close_holes"))
	var stat := await _stat()
	check(ws.command != null and (ws.command_values.get("bodies", []) as Array) == [{"kind": "body", "body": blob}], "Close Holes should open on the selected body.")
	if ws.command == null:
		return
	var feature_id := str(ws.command.feature.id)
	if stat == ws.command.PREVIEW_SKIPPED:
		note("Close Holes' preview did not fit half a second on this run; its numbers and fills were checked after OK only")
	else:
		check(stat.contains("Holes closed: 5") and stat.contains("Open edges: 0") and stat.contains("Triangles: 4,797"), "The stat row should show the report of the preview (%s)." % stat.replace("\n", " / "))
		var looks: Array = (ws.command.preview_meshes(ws.command_values) as Array).map(func(e: Dictionary) -> String: return str(e.look))
		check(looks == ["fill"] and ws.viewport.command_mesh_count() == 1, "The fills should be drawn over the body (%s; %d shown)." % [looks, ws.viewport.command_mesh_count()])
	await _shot("preview_dark_close_holes_fill.png")
	# Enter in the panel's field accepts.
	await _type_into("max_edges", "0")
	var typed_in := ws.panel._editors.get("max_edges") as LineEdit
	var before_enter := "focus %s, editing %s, windows %s, subwindow focus %s" % [gui.gui_get_focus_owner(), typed_in.is_editing() if typed_in != null else false, _open_windows(), gui.get("gui_embed_subwindows")]
	await _key(KEY_ENTER)
	await _frames(4)
	check(ws.command == null and _open_edges(_mesh(blob)) == 0 and _mesh(blob).boundary_loops().is_empty(), "Close Holes should close every hole (%s open edges; %s; tool %s; stat '%s'; before Enter: %s; after: focus %s, accept pending %s)." % [
		_open_edges(_mesh(blob)), ws.last_message, "open" if ws.command != null else "closed", str(ws.panel.info("stat")).replace("\n", " / ") if ws.command != null else "", before_enter, gui.gui_get_focus_owner(), ws._mesh_accept_pending])
	check(history.get_current_action() == mark + 1 and _undo_name() == "Forge: Mesh: Close Holes", "It should be one undo step named Mesh: Close Holes (%d -> %d, '%s')." % [mark, history.get_current_action(), _undo_name()])
	var chip := _chip(feature_id)
	check(chip != null and chip.icon != null and chip.icon == TIMELINE._icon(str(TIMELINE.ICONS["mesh:close_holes"])) and chip.tooltip_text.contains("Mesh"),
		"The timeline chip should carry Close Holes' own icon.")
	check(ws.viewport.command_mesh_count() == 0, "The preview's overlays go with the panel.")
	history.undo()
	await _frames(3)
	check(_mesh(blob) != null and _mesh(blob).boundary_loops().size() == 5, "Undo should open the 5 holes again.")
	history.redo()
	await _frames(3)
	check(_mesh(blob) != null and _mesh(blob).boundary_loops().is_empty(), "Redo should close them again.")


# --- 5.5 #5, 10.10: selection, the pinned buttons' pressed state --------------------------------

func _check_selection() -> void:
	_nothing_selected()
	await _look_at([blob])
	var mesh := _mesh(blob)
	var at := _point_on(blob)
	await _click(_g(at))
	await _frames(1)
	var groups: PackedStringArray = ws.mesh_selection.groups_of(blob, mesh)
	var shown: Array = ws.viewport.mesh_highlights().filter(func(h: Dictionary) -> bool: return h.look == "selected")
	check(groups.size() == 1 and shown.size() == 1 and int(shown[0].triangles) == ws.mesh_selection.count() and shown[0].material == ws.viewport.mesh_display.materials.selected,
		"A click in group mode should select one face group and draw it (%s; %s)." % [groups, shown])
	await _shot("selection_dark_group.png")
	# The pinned Select Triangles button, with a real click: it shows pressed.
	var triangles := _bar_button("mesh_pick_triangles")
	if triangles == null:
		check(false, "Select Triangles should be pinned to the bar.")
		return
	await _press(triangles)
	await _frames(2)
	check(ws.mesh_selection.mode == "triangles" and triangles.button_pressed and not _bar_button("mesh_pick_groups").button_pressed and ws.viewport.filters.get("mesh_triangle") == true,
		"A click on Select Triangles should switch the mode and show the button pressed.")
	await _focus_view()
	await _key(KEY_ESCAPE)
	check(ws.mesh_selection.is_empty(), "Escape should clear the selection.")
	await _click(_g(at))
	check(ws.mesh_selection.count() == 1, "A click in triangle mode should select one triangle (%d)." % ws.mesh_selection.count())
	ws.run_tool(_tool("mesh.select.grow_selection"))
	var ring: int = ws.mesh_selection.count()
	ws.run_tool(_tool("mesh.select.grow_selection"))
	check(ring == 4 and ws.mesh_selection.count() == 10, "Grow should take 1 + 3, then 10 triangles (%d, %d)." % [ring, ws.mesh_selection.count()])
	await _shot("selection_dark_triangles.png")
	# A crossing window dragged over the body takes the triangles facing the view.
	await _key(KEY_ESCAPE)
	var view_size: Vector2 = ws.viewport.size
	await _drag(_g(view_size * Vector2(0.72, 0.8)), _g(view_size * Vector2(0.28, 0.2)))
	await _frames(1)
	var windowed: int = ws.mesh_selection.count()
	check(windowed > 500 and windowed < int(mesh.triangle_count()) and ws.selection.is_empty(), "A window should take the triangles facing the view, not the body (%d)." % windowed)
	await _shot("selection_dark_window.png")
	await _key(KEY_ESCAPE)
	await _press(_bar_button("mesh_pick_groups"))
	await _frames(1)
	check(ws.mesh_selection.mode == "groups" and _bar_button("mesh_pick_groups").button_pressed, "Select Face Groups should switch back.")


# --- 5.5 #6, 10.10: Shift+F ---------------------------------------------------------------------

func _check_face_groups() -> void:
	var mesh := _mesh(blob)
	await _focus_view()
	var rebuilds: int = ws.rebuild_count
	await _key(KEY_F, {"shift": true})
	await _frames(1)
	var surface: MeshInstance3D = ws.viewport.body_surface(blob)
	var display: RefCounted = ws.viewport.mesh_display
	var used: PackedInt32Array = display.group_mesh_colors(surface.mesh) if surface != null else PackedInt32Array()
	check(ws.mesh_face_groups and surface != null and surface.material_override == null and used.size() == surface.mesh.get_surface_count() and used.size() >= 2,
		"Shift+F should draw the face groups in the palette's materials (%s)." % [used])
	var colors: PackedInt32Array = display.group_colors(mesh)
	var neighbours: Array = display.group_neighbours(mesh, mesh.get_arrays().groups)
	var clashes := 0
	for g in neighbours.size():
		for other in (neighbours[g] as PackedInt32Array):
			clashes += 1 if colors[g] == colors[other] else 0
	check(clashes == 0 and colors.size() == int(mesh.face_count()) and colors.size() == 6, "Neighbouring face groups should differ in colour (%s, %d clashes)." % [colors, clashes])
	await _shot("face_groups_dark.png")
	await _key(KEY_F, {"shift": true})
	await _frames(1)
	check(not ws.mesh_face_groups and ws.viewport.body_surface(blob).material_override == display.materials.surface and ws.rebuild_count == rebuilds,
		"Shift+F again should go back to the plain mesh colour, with no rebuild.")


# --- Stage 4 panel fixes: typed values, optional inputs, new fields ------------------------------

func _check_typed_values() -> void:
	# A value typed the same as the one the panel chose is the user's: it does not follow the body.
	_nothing_selected()
	ws.run_tool(_tool("mesh.modify.texture_extrude"))
	await _frames(3)
	if ws.command == null:
		check(false, "Texture Extrude should open.")
		return
	var first_depth := str(ws.command_values.get("depth", ""))
	var first_tile := str(ws.command_values.get("tile", ""))
	await _type_into("depth", first_depth)
	check(str(ws.command_values.get("depth", "")) == first_depth and not ws.command.is_untouched("depth", ws.command_values) and ws.command.is_untouched("tile", ws.command_values),
		"Typing the Depth the panel already showed should make it the user's (%s)." % first_depth)
	ws.panel.activate_selection("selection")
	await _click(_g(_point_on(blob)))
	await _frames(3)
	var picks: Array = ws.command_values.get("selection", [])
	var diagonal: float = (_mesh(blob).bbox() as AABB).size.length()
	check(picks.size() == 1 and str(picks[0].kind) == "mesh_group", "A click should pick the face group (%s)." % [picks])
	check(str(ws.command_values.get("depth", "")) == first_depth, "The typed Depth should stay (%s, was %s)." % [ws.command_values.get("depth"), first_depth])
	check(str(ws.command_values.get("tile", "")) != first_tile and absf(float(str(ws.command_values.get("tile", "0"))) * MM - diagonal / 5.0) < diagonal * 1e-3,
		"The untouched Tile Size should follow the picked body: D/5 (%s, was %s)." % [ws.command_values.get("tile"), first_tile])
	ws.cancel_command()
	await _frames(2)
	# Remesh: Adaptive's Minimum Edge is no input until it is typed.
	_select_body(blob)
	ws.run_tool(_tool("mesh.modify.remesh"))
	await _frames(3)
	var values: Dictionary = ws.command_values.duplicate(true)
	values["mode"] = "adaptive"
	ws.set_command_values(values)
	await _frames(4)
	var inputs: Dictionary = ws.command.feature.inputs
	var min_edge := ws.panel._editors.get("min_edge") as LineEdit
	var hint := ws.panel._hints.get("min_edge") as Label
	check(not inputs.has("min_edge") and inputs.has("max_edge") and inputs.has("approx_error") and (ws.panel._row_nodes["min_edge"] as Control).visible and not ws.panel._ok.disabled,
		"Adaptive Remesh should leave the empty Minimum Edge to the kernel, with OK offered (inputs %s)." % [inputs.keys()])
	check(min_edge != null and min_edge.text == "" and min_edge.placeholder_text == "auto" and hint != null and hint.text.begins_with("auto"), "The empty Minimum Edge should say auto (hint '%s')." % (hint.text if hint != null else ""))
	await _type_into("min_edge", "0.2")
	check(ws.command.feature.inputs.has("min_edge") and str(ws.command.feature.expression("min_edge")) == "0.2", "A typed Minimum Edge should become the input.")
	# Emptied again, it goes back to the kernel.
	await _press(min_edge)
	await _key(KEY_A, {"ctrl": true})
	await _key(KEY_BACKSPACE)
	await _frames(3)
	check(min_edge.text == "" and not ws.command.feature.inputs.has("min_edge") and not ws.panel._ok.disabled and hint.text.begins_with("auto"), "An emptied Minimum Edge should be left to the kernel again (inputs %s)." % [ws.command.feature.inputs.keys()])
	ws.cancel_command()
	await _frames(2)
	# Close Holes: Match Edge Size shows for Flat too.
	ws.run_tool(_tool("mesh.prepare.close_holes"))
	await _frames(2)
	values = ws.command_values.duplicate(true)
	for fill in ["flat", "smooth", "minimal"]:
		values["fill"] = fill
		ws.set_command_values(values)
		await _frames(1)
		check((ws.panel._row_nodes["refine"] as Control).visible == (fill != "minimal"), "Match Edge Size should show for %s: %s." % [fill, fill != "minimal"])
	ws.cancel_command()
	await _frames(2)
	# Reduce and Smooth: Sharp Edge Angle with Keep Sharp Edges; Reduce says its counts are the body's.
	for id in ["mesh.modify.reduce", "mesh.modify.smooth"]:
		ws.run_tool(_tool(id))
		await _frames(2)
		check(not (ws.panel._row_nodes["sharp_angle"] as Control).visible and not ws.command.feature.inputs.has("sharp_angle"), "%s: Sharp Edge Angle hides without Keep Sharp Edges." % id)
		values = ws.command_values.duplicate(true)
		values["keep_sharp"] = true
		ws.set_command_values(values)
		await _frames(2)
		check((ws.panel._row_nodes["sharp_angle"] as Control).visible and ws.command.feature.inputs.has("sharp_angle") and str(ws.command_values.get("sharp_angle", "")) == "45",
			"%s: Sharp Edge Angle (45) should show with Keep Sharp Edges and be an input." % id)
		values["sharp_angle"] = "5"
		ws.set_command_values(values)
		await _frames(3)
		check(str(ws.panel.info("stat")) == "Sharp Edge Angle must be between 10 deg and 170 deg.", "%s: an angle of 5 should be refused (%s)." % [id, ws.panel.info("stat")])
		if id.ends_with("reduce"):
			var labels := []
			for field in ws.command.fields():
				if field.key in ["proportion", "face_count"]:
					labels.append(str(field.label))
			check(labels.size() == 2 and labels[0].contains("whole body") and labels[1].contains("whole body"), "Reduce's counts should say they are of the whole body (%s)." % [labels])
		ws.cancel_command()
		await _frames(2)


# --- 5.5 #7, 10.10: Reduce and the stat row with a real report ----------------------------------

func _check_reduce() -> void:
	_select_body(blob)
	var before := int(_mesh(blob).triangle_count())
	var mark := history.get_current_action()
	ws.run_tool(_tool("mesh.modify.reduce"))
	await _frames(3)
	if ws.command == null:
		check(false, "Reduce should open.")
		return
	var feature_id := str(ws.command.feature.id)
	# Another value first, so the 50 typed next is a change the preview has to follow.
	await _type_into("proportion", "30")
	var stat := ""
	for i in 120:
		stat = str(ws.panel.info("stat"))
		if stat.contains("(30.0%)") or stat == ws.command.PREVIEW_SKIPPED:
			break
		await _tree.process_frame
	check(stat.contains("(30.0%)"), "The stat row should follow a typed 30 (%s)." % stat.replace("\n", " / "))
	await _type_into("proportion", "50")
	for i in 120:
		stat = str(ws.panel.info("stat"))
		if stat.contains("(50.0%)") or stat == ws.command.PREVIEW_SKIPPED:
			break
		await _tree.process_frame
	# (From the last key typed: the keys before it are the hook's own pace, a frame each.)
	var took := Time.get_ticks_msec() - _last_key_msec
	note("Reduce's preview numbers showed within %d ms of the last key of the typed 50: %s" % [took, stat.replace("\n", " / ")])
	var report: Dictionary = MESH_FEATURE.reports.get(feature_id, {})
	check(stat.begins_with("Triangles: %s \u2192 " % FEATURE_COMMAND.with_commas(before)) and stat.contains("%)") and stat.contains("Open edges: 0") and took <= 1000,
		"The stat row should show the preview's numbers within a second (%d ms: %s)." % [took, stat.replace("\n", " / ")])
	check(report.get("output") is Dictionary and stat.contains(FEATURE_COMMAND.with_commas(int(report.output.triangles))), "The numbers should be the report's (%s)." % [report.get("output")])
	check(not ws.command.is_untouched("proportion", ws.command_values), "The typed 50 is the user's, though the panel showed 50 already.")
	await _shot("preview_dark_reduce_stat.png")
	await _key(KEY_ENTER)
	await _frames(4)
	var after := int(_mesh(blob).triangle_count()) if _mesh(blob) != null else -1
	check(ws.command == null and absi(after - before / 2) <= int(0.02 * before / 2.0) + 1, "Reduce should keep half the triangles within 2 %% (%d of %d; %s)." % [after, before, ws.last_message])
	check(history.get_current_action() == mark + 1 and _undo_name() == "Forge: Mesh: Reduce", "Reduce should be one undo step named Mesh: Reduce ('%s')." % _undo_name())
	var chip := _chip(feature_id)
	check(chip != null and chip.icon == TIMELINE._icon(str(TIMELINE.ICONS["mesh:reduce"])), "The timeline chip should carry Reduce's icon.")


# --- 5.5 #8, 10.10: Direct Edit ------------------------------------------------------------------

func _check_direct_edit() -> void:
	_select_body(blob)
	await _look_at([blob])
	var mark := history.get_current_action()
	var features: int = doc.features.size()
	var count := int(_mesh(blob).triangle_count())
	ws.run_tool(_tool("mesh.modify.direct_edit"))
	await _frames(3)
	var tool: RefCounted = ws.mesh_direct_edit
	check(tool.active and tool.panel != null and tool.panel.visible and ws.mesh_selection.mode == "triangles", "Direct Edit should open its panel and pick triangles (%s)." % ws.last_message)
	if not tool.active:
		return
	await _click(_g(_point_on(blob)))
	ws.run_tool(_tool("mesh.select.grow_selection"))
	ws.run_tool(_tool("mesh.select.grow_selection"))
	check(ws.mesh_selection.count() == 10, "A click and two Grows should select 10 triangles (%d)." % ws.mesh_selection.count())
	await _shot("direct_edit_dark_selection.png")
	await _press(tool.buttons().delete)
	await _frames(2)
	check(int(tool.working.triangle_count()) == count - 10 and tool.working.boundary_loops().size() == 1 and int(_mesh(blob).triangle_count()) == count,
		"Delete should take the 10 triangles out of the working copy only (%d, %d loops)." % [tool.working.triangle_count(), tool.working.boundary_loops().size()])
	await _shot("direct_edit_dark_deleted.png")
	await _press(tool.buttons().fill)
	await _frames(2)
	check(tool.working.boundary_loops().is_empty() and tool.steps == PackedStringArray(["delete", "fill"]), "Fill Holes should close the hole Delete made (%s)." % [tool.steps])
	# Ctrl+Z takes the fill back, Fill Holes puts it again.
	await _focus_view()
	await _key(KEY_Z, {"ctrl": true})
	check(tool.working.boundary_loops().size() == 1 and tool.steps.size() == 1 and doc.features.size() == features, "Ctrl+Z should take the tool's last step back, not the design's.")
	await _press(tool.buttons().fill)
	await _frames(2)
	# Move: one triangle, an arrow dragged with the mouse.
	await _click(_g(_point_on(blob, 3)))
	check(ws.mesh_selection.count() == 1, "A click should select one triangle to move (%d)." % ws.mesh_selection.count())
	await _press(tool.buttons().move)
	await _frames(2)
	check(ws.viewport.handles.size() == 3, "Move should show three arrows (%d)." % ws.viewport.handles.size())
	var middle: Vector2 = ws.viewport.project(tool._selection_center())
	var starts := []
	for handle in ws.viewport.handles:
		var arrow: Dictionary = ws.viewport._handle_screen_shape(handle)
		starts.append((arrow.from as Vector2).distance_to(middle) if not arrow.is_empty() else INF)
	check(starts.size() == 3 and starts.max() <= 1.5, "The Move arrows should start at the middle of the selection (%s px away)." % [starts])
	await _shot("direct_edit_dark_move_arrows.png")
	var dragged := false
	for handle in ws.viewport.handles:
		var screen: Dictionary = ws.viewport._handle_screen_shape(handle)
		if screen.is_empty() or ((screen.to as Vector2) - (screen.from as Vector2)).length() < 30.0:
			continue
		var from: Vector2 = (screen.from as Vector2).lerp(screen.to, 0.6)
		var along: Vector2 = ((screen.to as Vector2) - (screen.from as Vector2)).normalized()
		var digest_before := str(tool.working.digest())
		await _drag(_g(from), _g(from + along * 40.0))
		await _frames(2)
		dragged = tool.steps.size() == 3 and tool.steps[2] == "move" and str(tool.working.digest()) != digest_before and tool.working.boundary_loops().is_empty()
		break
	check(dragged, "Dragging a Move arrow should move the triangle as one step (%s)." % [tool.steps])
	var result_digest := str(tool.working.digest())
	await _press(tool.buttons().done)
	await _frames(4)
	var feature: Resource = doc.features.back()
	check(not tool.active and doc.features.size() == features + 1 and str(feature.options.get("method", "")) == "direct_edit" and feature.options.get("steps") == PackedStringArray(["delete", "fill", "move"]),
		"Done should write one direct_edit feature holding the steps (%s)." % [feature.options.get("steps")])
	check(history.get_current_action() == mark + 1 and _undo_name() == "Forge: Mesh: Direct Edit", "It should be one undo step named Mesh: Direct Edit ('%s')." % _undo_name())
	check(str(ws.result.errors.get(feature.id, "")) == "" and _mesh(blob) != null and str(_mesh(blob).digest()) == result_digest, "The body should be the edited mesh (%s)." % ws.result.errors.get(feature.id, ""))
	check(ws.mesh_selection.mode == "groups" and _chip(feature.id) != null and _chip(feature.id).icon == TIMELINE._icon(str(TIMELINE.ICONS["mesh:direct_edit"])),
		"The pick mode goes back and the timeline shows Direct Edit's chip.")


# --- 5.5 #9, 10.10: Plane Cut with a construction plane, the arrow, the Removed overlay --------

func _check_plane_cut() -> void:
	_nothing_selected()
	ws.run_tool(_tool("mesh.construct.offset_plane"))
	await _frames(2)
	ws._on_reference_picked({"kind": "origin", "name": "xz"})
	var values: Dictionary = ws.command_values.duplicate(true)
	values["distance"] = "5"
	ws.set_command_values(values)
	await _frames(2)
	ws.accept_command()
	await _frames(3)
	var plane_id := str(doc.features.back().id)
	check(ws.command == null and ws.result.construction.has(plane_id), "A construction plane 5 mm above the ground should be made.")
	if not ws.result.construction.has(plane_id):
		return
	_select_body(blob)
	await _look_at([blob], 0.7, -0.35)
	var mark := history.get_current_action()
	ws.run_tool(_tool("mesh.modify.plane_cut"))
	await _frames(3)
	if ws.command == null:
		check(false, "Plane Cut should open.")
		return
	var feature_id := str(ws.command.feature.id)
	# The Cut Plane slot, then the plane itself, both with real clicks.
	await _press(ws.panel._editors["plane"])
	check(ws.panel.active_selection_key == "plane", "A click on the Cut Plane slot should make it the active one.")
	var frame: Dictionary = ws.result.construction[plane_id]
	var size: float = ws.viewport.origin_size()
	var side: Vector3 = (frame.normal as Vector3).cross(frame.x as Vector3)
	var picked_in_view := false
	# (The origin planes show while a plane slot is active, from the next frame on: the spot is
	# looked for with them shown, so what is found there is what the click picks.)
	await _frames(3)
	var spots := []
	for u in [0.44, -0.44, 0.3, -0.3, 0.15, -0.15, 0.0]:
		for v in [0.44, -0.44, 0.3, -0.3, 0.15, -0.15, 0.0]:
			spots.append(Vector2(u, v))
	for corner in spots:
		var at: Vector2 = ws.viewport.project((frame.origin as Vector3) + (frame.x as Vector3) * corner.x * size + side * corner.y * size)
		if not at.is_finite() or _covered(at):
			continue
		var under: Dictionary = ws.picker.pick(at)
		if str(under.get("kind", "")) == "construct" and str(under.get("feature", "")) == plane_id:
			await _click(_g(at))
			picked_in_view = true
			break
	if not picked_in_view:
		note("the construction plane had no free spot in the view; it was picked from the browser's row instead")
		ws.browser.construction_clicked.emit(plane_id)
	await _frames(3)
	check((ws.command_values.get("plane", []) as Array) == [{"kind": "construct", "feature": plane_id}], "The construction plane should be the cut plane (%s)." % [ws.command_values.get("plane", [])])
	# The offset arrow, dragged with the mouse.
	var arrow := {}
	for handle in ws.viewport.handles:
		if str(handle.get("key", "")) == "offset":
			arrow = handle
	check(not arrow.is_empty() and float(arrow.get("min", 0.0)) < 0.0, "Plane Cut should show its offset arrow.")
	if not arrow.is_empty():
		var screen: Dictionary = ws.viewport._handle_screen_shape(arrow)
		var from: Vector2 = (screen.from as Vector2).lerp(screen.to, 0.6)
		var along: Vector2 = ((screen.to as Vector2) - (screen.from as Vector2)).normalized()
		await _drag(_g(from), _g(from + along * 45.0))
		await _frames(4)
	var offset := float(ws.command.evaluated_values(ws.command_values).get("offset", 0.0))
	check(offset > 1e-5, "Dragging the arrow should set an offset (%s)." % ws.command_values.get("offset"))
	var stat := await _stat(4)
	var overlays: Array = ws.command.preview_meshes(ws.command_values)
	var looks: Array = overlays.map(func(e: Dictionary) -> String: return str(e.look))
	check(looks.has("removed") and ws.viewport.command_mesh_count() == overlays.size(), "The part the cut takes away should be drawn (%s; %d shown)." % [looks, ws.viewport.command_mesh_count()])
	if stat == ws.command.PREVIEW_SKIPPED:
		note("Plane Cut's preview did not fit half a second on this run; its cap overlay was not checked")
	else:
		check(looks.has("fill") and stat.contains("Open edges: 0"), "The cap should be drawn as a fill and the stat row should show the cut closed (%s; %s)." % [looks, stat.replace("\n", " / ")])
	await _shot("preview_dark_plane_cut_removed_fill.png")
	var volume_before := float(_mesh(blob).volume()) if stat == ws.command.PREVIEW_SKIPPED else -1.0
	await _focus_view()
	await _key(KEY_ENTER)
	await _frames(4)
	var cut := _mesh(blob)
	var found: Dictionary = cut.check(5.0) if cut != null else {}
	check(ws.command == null and bool(found.get("closed", false)) and int(found.get("boundary_edges", -1)) == 0 and (cut.bbox() as AABB).position.y > 0.005 + offset - 1e-5,
		"Plane Cut should leave the part above the plane, closed (%s; %s)." % [found.get("boundary_edges", "?"), ws.last_message])
	check(history.get_current_action() == mark + 1 and _undo_name() == "Forge: Mesh: Plane Cut" and _chip(feature_id) != null and _chip(feature_id).icon == TIMELINE._icon(str(TIMELINE.ICONS["mesh:plane_cut"])),
		"It should be one undo step named Mesh: Plane Cut with its chip ('%s'; before %s)." % [_undo_name(), volume_before])


# --- 5.5 #10: Convert Mesh: Faceted, and the gate ------------------------------------------------

func _check_convert_and_gate() -> void:
	var gate := MESH_BODY.GATE % doc.body_name(blob)
	await _look_at([blob])
	if not ResourceLoader.exists(MESH_FEATURE.CONVERT_PATH):
		check(false, "Convert Mesh (core/features/mesh_convert.gd) should be in this build.")
	else:
		_select_body(blob)
		var mark := history.get_current_action()
		var mesh_volume := float(_mesh(blob).volume())
		ws.run_tool(_tool("mesh.modify.convert_mesh_faceted"))
		await _frames(4)
		check(ws.command != null and ws.command.key == "mesh:convert_faceted" and (ws.command_values.get("bodies", []) as Array).size() == 1, "Convert Mesh: Faceted should open on the body.")
		# (The body sits in the middle of the view here: wherever the panel went, it is whole
		# inside the view, so OK can be clicked.)
		check(Rect2(Vector2.ZERO, ws.viewport.size).grow(0.5).encloses(_panel_rect()), "The panel should be whole inside the view (%s in %s)." % [_panel_rect(), ws.viewport.size])
		if ws.command != null:
			await _ok()
		var solid := ""
		for body_id in ws.result.bodies:
			if not MESH_BODY.is_mesh(ws.result.bodies[body_id]) and doc.body_visible(body_id):
				solid = body_id
		check(ws.command == null and solid != "" and absf(float(_shape(solid).volume()) - mesh_volume) <= 0.01 * mesh_volume and _undo_name() == "Forge: Mesh: Convert Mesh: Faceted" and history.get_current_action() == mark + 1,
			"Convert Mesh: Faceted should make a solid of the mesh's volume in one step (%s; '%s'; %s)." % [solid, _undo_name(), ws.last_message])
		if solid != "":
			await _look_at([solid])
			_nothing_selected()
			ws.run_tool(_tool("solid.modify.fillet"))
			await _frames(2)
			ws.last_message = ""
			await _click(_g(_point_on(solid)))
			await _frames(2)
			check(not (ws.command_values.get("edges", []) as Array).is_empty() and ws.last_message != MESH_BODY.GATE % doc.body_name(solid), "Fillet should pick on the converted solid (%s; %s)." % [ws.command_values.get("edges", []), ws.last_message])
			ws.cancel_command()
			await _frames(2)
		# The convert is taken back, so the mesh body shows again for the gate.
		while history.get_current_action() > mark:
			history.undo()
			await _frames(2)
	_nothing_selected()
	await _look_at([blob])
	ws.run_tool(_tool("solid.modify.fillet"))
	await _frames(2)
	await _click(_g(_point_on(blob)))
	await _frames(2)
	check((ws.command_values.get("edges", []) as Array).is_empty() and ws.last_message == gate, "Fillet on a mesh body should say the gate sentence and pick nothing (%s)." % ws.last_message)
	ws.cancel_command()
	await _frames(2)


# --- 10.10: a real right-click on the browser ---------------------------------------------------

func _check_browser_menu() -> void:
	await _click_in_browser(blob, {"button": MOUSE_BUTTON_RIGHT})
	var menu: PopupMenu = ws.browser._context
	var labels := []
	for i in menu.item_count:
		labels.append(menu.get_item_text(i))
	check(menu.visible and labels.has("Rename") and labels.has("Convert Mesh...") and labels.has("Reduce...") and labels.has("Close Holes..."),
		"A right-click on a mesh body's row should offer the mesh tools (%s, open %s)." % [labels, menu.visible])
	# (The menu is a window of its own: its entry is chosen as a click on it does.)
	menu.hide()
	menu.id_pressed.emit(ws.BROWSER_REDUCE)
	await _frames(3)
	check(ws.command != null and ws.command.key == "mesh:reduce" and (ws.command_values.get("bodies", []) as Array) == [{"kind": "body", "body": blob}], "Reduce... should open Reduce on that body.")
	if ws.command != null:
		ws.cancel_command()
	await _frames(2)


# --- The hook's own model (10.10's slots, the tool screenshots) ----------------------------------

func _setup_model() -> void:
	image = ProjectSettings.globalize_path(FIXTURES.write_png_checker("hook/checker.png", 64))
	var cubes := FIXTURES.two_cubes(Vector3(0.03, 0.0, 0.0))
	var made := {}
	ws.change("Mesh Hook Model", func() -> void:
		made["align"] = _add_mesh(_moved(cubes.first, Vector3(0.3, 0.03, 0.04)), "HookAlign")
		made["target"] = _add_mesh(_moved(cubes.first, Vector3(0.5, 0.01, 0.0)), "HookTarget")
		made["tool_mesh"] = _add_mesh(_moved(cubes.first, Vector3(0.512, 0.014, 0.004)), "HookToolMesh")
		made["plate"] = _add_mesh(_moved(FIXTURES.open_plate(), Vector3(0.8, 0.0, 0.0)), "HookPlate")
		made["scaled"] = _add_mesh(_moved(cubes.first, Vector3(1.0, 0.01, 0.0)), "HookScale")
		made["ball"] = _add_mesh(_moved(FIXTURES.icosphere(0.05, 3), Vector3(1.3, 0.0, 0.0)), "HookBall")
		made["holes"] = _add_mesh(_moved(FIXTURES.holed_blob(), Vector3(1.6, 0.0, 0.0)), "HookHoles")
		made["pair"] = _add_mesh(_moved(cubes, Vector3(1.9, 0.01, 0.0)), "HookPair")
		made["cube"] = _add_mesh(_moved(cubes.first, Vector3(1.32, 0.0, 0.0)), "HookCube")
		made["lone"] = _add_mesh(_moved(cubes.first, Vector3(-0.2, 0.01, 0.0)), "HookLone")
		made["prism"] = _add_mesh((FIXTURES.l_bracket().mesh as RefCounted).transformed(Transform3D(Basis.IDENTITY, Vector3(2.8, 0.0, 0.0))), "HookPrism")
		made["smooth"] = _add_mesh(_moved(FIXTURES.icosphere(0.05, 4), Vector3(3.1, 0.0, 0.0)), "HookSmooth")
		made["bracket"] = _add_mesh((FIXTURES.l_bracket().mesh as RefCounted).transformed(Transform3D(Basis(Vector3(1, 2, 3).normalized(), 0.7), Vector3(2.2, 0.02, 0.03))), "HookBracket")
		for spec in [["box", Vector3(0.488, 0.006, -0.004)], ["pivot", Vector3(1.04, 0.0, 0.03)], ["solid", Vector3(2.5, 0.0, 0.0)]]:
			var feature: Resource = ws.doc.add_feature("box", "Box", {
				"length": ws.doc.make_input("22 mm", "length"), "height": ws.doc.make_input("22 mm", "length"), "width": ws.doc.make_input("22 mm", "length"),
			}, {"operation": OPERATIONS.NEW_BODY, "position": spec[1]})
			made[spec[0]] = ws.doc.new_body(feature.id)
			feature.options["body_id"] = made[spec[0]])
	doc = ws.doc
	model = made
	await _frames(3)
	var missing := []
	for key in model:
		if _shape(str(model[key])) == null:
			missing.append(key)
	check(missing.is_empty() and ws.result.errors.is_empty(), "The hook's model should build (missing %s; %s)." % [missing, ws.result.errors])


# --- 10.10: Mesh Align's three-point slot --------------------------------------------------------

func _check_align_points() -> void:
	var body := str(model.get("align", ""))
	if _mesh(body) == null:
		return
	_nothing_selected()
	await _look_at([body], 0.6, -0.6)
	var mark := history.get_current_action()
	ws.run_tool(_tool("mesh.modify.mesh_align"))
	await _frames(3)
	if ws.command == null:
		check(false, "Mesh Align should open.")
		return
	await _press(ws.panel._editors["points"])
	check(ws.panel.active_selection_key == "points", "The three-point slot should become the active one (active '%s'; the mouse is over %s; the slot at %s, the panel at %s; pressed %s; windows %s)." % [ws.panel.active_selection_key, gui.gui_get_hovered_control(), (ws.panel._editors["points"] as Control).get_global_rect(), (ws.panel as Control).get_global_rect(), (ws.panel._editors["points"] as Button).button_pressed, _open_windows()])
	# Three points on the cube's top face, not in one line; a fourth is refused.
	var top := _points_on(body, Vector3.UP)
	check(top.size() >= 4, "The cube's top face should be in view (%d points)." % top.size())
	if top.size() < 4:
		ws.cancel_command()
		return
	var chosen := [top[0]]
	for candidate in top:
		if chosen.size() == 1 and (candidate as Vector2).distance_to(chosen[0]) > 30.0:
			chosen.append(candidate)
		elif chosen.size() == 2:
			var a: Vector2 = chosen[0]
			var b: Vector2 = chosen[1]
			if absf((b - a).cross((candidate as Vector2) - a)) > 600.0:
				chosen.append(candidate)
				break
	check(chosen.size() == 3, "Three points of the top face that are not in one line should be found.")
	for at in chosen:
		await _click(_g(at))
		await _frames(1)
	var points: Array = ws.command_values.get("points", [])
	check(points.size() == 3 and points.all(func(p: Variant) -> bool: return p is Dictionary and str(p.kind) == "mesh_triangles" and p.get("at") is Vector3 and str(p.body) == body),
		"Three clicks should give three points on the mesh (%s)." % [points])
	# Each point is drawn as a dot where it was picked (not as its whole triangle).
	var dots_at_picks := points.size() == 3
	for i in points.size():
		var dot: Variant = ws.command.shown_point(points[i])
		dots_at_picks = dots_at_picks and dot is Vector3 and points[i].get("weights") is Vector3 and ws.viewport.project(dot).distance_to(chosen[i]) <= 1.5
	check(dots_at_picks, "Each picked point should have its dot under the click (%s)." % [points.map(func(p: Dictionary) -> Variant: return ws.command.shown_point(p))])
	await _shot("preview_dark_align_dots.png")
	await _click(_g(top[top.size() - 1]))
	check((ws.command_values.get("points", []) as Array).size() == 3 and ws.last_message.contains("takes 3 picks"), "A fourth point should be refused (%s)." % ws.last_message)
	# The plane to align to: the XY origin plane, from the browser's row.
	await _press(ws.panel._editors["to"])
	ws.browser.origin_clicked.emit("xy_plane")
	await _frames(3)
	check((ws.command_values.get("to", []) as Array) == [XY], "The XY plane should be the target (%s)." % [ws.command_values.get("to", [])])
	# The preview has turned the body: the dots went with it, onto the XY plane.
	var shown := _mesh(body)
	var dots_follow := shown != null and str(shown.digest()) != str(points[0].digest)
	for point in ws.command_values.get("points", []):
		var dot: Variant = ws.command.shown_point(point)
		dots_follow = dots_follow and dot is Vector3 and absf((dot as Vector3).z) <= 1e-6 and (dot as Vector3).distance_to(point.at) > 1e-4
	check(dots_follow, "The dots should follow the body the preview turned, onto the XY plane (%s)." % [(ws.command_values.get("points", []) as Array).map(func(p: Dictionary) -> Variant: return ws.command.shown_point(p))])
	await _shot("preview_dark_align_points.png")
	await _ok()
	var moved := _mesh(body)
	var box: AABB = moved.bbox() if moved != null else AABB()
	check(ws.command == null and moved != null and (absf(box.position.z) < 1e-6 or absf(box.end.z) < 1e-6) and absf(box.size.z - 0.02) < 1e-6,
		"Mesh Align by three points should lay the cube's top face on the XY plane (z %s to %s; %s)." % [box.position.z, box.end.z, ws.last_message])
	check(history.get_current_action() == mark + 1 and _undo_name() == "Forge: Mesh: Mesh Align", "It should be one undo step named Mesh: Mesh Align ('%s')." % _undo_name())


# --- 10.10: Combine's slot of mesh and solid tools -----------------------------------------------

func _check_combine_slots() -> void:
	var target := str(model.get("target", ""))
	var tool_mesh := str(model.get("tool_mesh", ""))
	var box := str(model.get("box", ""))
	if _mesh(target) == null or _mesh(tool_mesh) == null or _shape(box) == null:
		return
	_nothing_selected()
	await _look_at([target, tool_mesh, box], 0.9, -0.55)
	var mark := history.get_current_action()
	ws.run_tool(_tool("mesh.modify.combine"))
	await _frames(3)
	if ws.command == null:
		check(false, "Combine should open.")
		return
	# The target has to be a mesh body: a click on the solid is refused.
	await _click(_g(_point_on(box)))
	await _frames(1)
	check((ws.command_values.get("target", []) as Array).is_empty() and ws.last_message == ws.command.NOT_A_MESH % doc.body_name(box) and ws.panel.active_selection_key == "target", "A solid can't be the target (%s)." % ws.last_message)
	await _click(_g(_point_on(target)))
	await _frames(1)
	check((ws.command_values.get("target", []) as Array) == [{"kind": "body", "body": target}] and ws.panel.active_selection_key == "tools", "A click should pick the target and move on to the tools (%s)." % [ws.command_values.get("target", [])])
	# The tools: a mesh body and a solid, each by a click.
	await _click(_g(_point_on(tool_mesh)))
	await _frames(2)
	await _click(_g(_point_on(box)))
	await _frames(3)
	var tools: Array = ws.command_values.get("tools", [])
	check(tools.size() == 2 and tools.has({"kind": "body", "body": tool_mesh}) and tools.has({"kind": "body", "body": box}), "The tools slot should take a mesh body and a solid (%s; %s)." % [tools, ws.last_message])
	var feature_id := str(ws.command.feature.id)
	await _shot("preview_dark_combine_slots.png")
	await _ok()
	var joined := _mesh(target)
	var warning := str(ws.result.warnings.get(feature_id, ""))
	check(ws.command == null and joined != null and _open_edges(joined) == 0 and float(joined.volume()) > 8.2e-6 and not ws.result.bodies.has(tool_mesh) and not ws.result.bodies.has(box),
		"Combine should join the mesh and the solid into the target and take the tools out (volume %s; %s)." % [joined.volume() if joined != null else 0.0, ws.last_message])
	check(warning.contains("was tessellated for Combine") and _undo_name() == "Forge: Mesh: Combine" and history.get_current_action() == mark + 1, "The solid's tessellation should be warned, in one step named Mesh: Combine (%s; '%s')." % [warning, _undo_name()])


# --- 10.10: Texture Extrude's Choose File --------------------------------------------------------

func _check_texture_file() -> void:
	var plate := str(model.get("plate", ""))
	if _mesh(plate) == null:
		return
	_nothing_selected()
	await _look_at([plate], 0.6, -0.9)
	var mark := history.get_current_action()
	ws.run_tool(_tool("mesh.modify.texture_extrude"))
	await _frames(3)
	if ws.command == null:
		check(false, "Texture Extrude should open.")
		return
	await _click(_g(_point_on(plate)))
	await _frames(2)
	check((ws.command_values.get("selection", []) as Array).size() == 1, "A click should pick the plate's face group.")
	await _press(ws.panel._editors["browse"])
	await _frames(2)
	var dialog: Window = ws.files._file_dialog
	check(dialog != null and dialog.visible and dialog.title == "Choose Image", "Choose File... should open the image dialog.")
	if dialog != null:
		dialog.hide()
	ws.files._file_chosen(image)
	await _frames(3)
	var field := ws.panel._editors.get("image") as LineEdit
	check(str(ws.command_values.get("image", "")).ends_with("checker.png") and field != null and field.text.ends_with("checker.png") and str(ws.command.feature.options.get("image", "")).ends_with("checker.png"),
		"The chosen file should go into the Image row (%s)." % ws.command_values.get("image", ""))
	var values: Dictionary = ws.command_values.duplicate(true)
	values["depth"] = "1.5"
	values["tile"] = "10"
	values["detail"] = "0.625"
	ws.set_command_values(values, ["depth", "tile", "detail"])
	var stat := await _stat(8)
	await _shot("preview_dark_texture_extrude.png")
	await _ok()
	var raised := _mesh(plate)
	check(ws.command == null and raised != null and absf((raised.bbox() as AABB).end.y - 1.5 * MM) < 0.03 * MM, "Texture Extrude should raise the plate by 1.5 mm (%s mm; %s; stat %s)." % [
		(raised.bbox() as AABB).end.y * 1000.0 if raised != null else 0.0, ws.last_message, stat.replace("\n", " / ")])
	check(history.get_current_action() == mark + 1 and _undo_name() == "Forge: Mesh: Texture Extrude", "It should be one undo step named Mesh: Texture Extrude ('%s')." % _undo_name())


# --- 10.10: Scale Mesh's point slot --------------------------------------------------------------

func _check_scale_point() -> void:
	var body := str(model.get("scaled", ""))
	var pivot := str(model.get("pivot", ""))
	if _mesh(body) == null or _shape(pivot) == null:
		return
	_nothing_selected()
	await _look_at([body, pivot], 0.9, -0.6)
	var mark := history.get_current_action()
	var before: AABB = _mesh(body).bbox()
	var volume := float(_mesh(body).volume())
	ws.run_tool(_tool("mesh.modify.scale_mesh"))
	await _frames(3)
	if ws.command == null:
		check(false, "Scale Mesh should open.")
		return
	await _click(_g(_point_on(body)))
	await _frames(1)
	check((ws.command_values.get("bodies", []) as Array) == [{"kind": "body", "body": body}], "A click should pick the body to scale.")
	await _press(ws.panel._editors["point"])
	check(ws.panel.active_selection_key == "point", "The Point slot should become the active one.")
	# A corner of the solid box beside it, clicked in the view.
	var pivot_box: AABB = _shape(pivot).bbox()
	for i in 8:
		var at: Vector2 = ws.viewport.project(pivot_box.get_endpoint(i))
		if not at.is_finite() or _covered(at):
			continue
		if str((ws.picker.pick(at) as Dictionary).get("kind", "")) == "vertex":
			await _click(_g(at))
			break
	await _frames(2)
	var refs: Array = ws.command_values.get("point", [])
	check(refs.size() == 1 and str(refs[0].get("kind", "")) == "vertex" and refs[0].get("point") is Vector3, "A click on the box's corner should fill the Point slot (%s)." % [refs])
	if refs.size() != 1 or not refs[0].get("point") is Vector3:
		ws.cancel_command()
		return
	var fixed: Vector3 = refs[0].point
	await _type_into("scale", "2")
	await _stat(4)
	await _shot("preview_dark_scale_point.png")
	await _key(KEY_ENTER)
	await _frames(4)
	var scaled := _mesh(body)
	var want := fixed + (before.get_center() - fixed) * 2.0
	check(ws.command == null and scaled != null and absf(float(scaled.volume()) - 8.0 * volume) < 1e-4 * 8.0 * volume and (scaled.bbox() as AABB).get_center().distance_to(want) < 1e-6,
		"Scale Mesh by 2 about the picked corner should double the body from that point (center %s, wanted %s; %s)." % [(scaled.bbox() as AABB).get_center() if scaled != null else Vector3.ZERO, want, ws.last_message])
	check(history.get_current_action() == mark + 1 and _undo_name() == "Forge: Mesh: Scale Mesh", "It should be one undo step named Mesh: Scale Mesh ('%s')." % _undo_name())


# --- Picks made while the tool's preview has changed the mesh ------------------------------------

## A hole is picked at a fill's rim after the preview closed every hole, and a second triangle is
## picked for Erase and Fill after the preview erased the first: both land on the mesh the tool
## works on, not on the preview's.
func _check_picks_under_preview() -> void:
	var holes := str(model.get("holes", ""))
	var ball := str(model.get("ball", ""))
	if _mesh(holes) == null or _mesh(ball) == null:
		return
	# Close Holes: one hole of five.
	var input: RefCounted = _mesh(holes)
	_select_body(holes)
	await _look_at([holes], 0.7, -0.5, 0.28)
	var mark := history.get_current_action()
	ws.run_tool(_tool("mesh.prepare.close_holes"))
	var stat := await _stat(8)
	if ws.command == null:
		check(false, "Close Holes should open.")
		return
	check(stat == ws.command.PREVIEW_SKIPPED or stat.contains("Holes closed: 5"), "The preview should close the 5 holes first (%s)." % stat.replace("\n", " / "))
	if ws.panel.active_selection_key != "loops":
		await _press(ws.panel._editors["loops"])
	check(ws.panel.active_selection_key == "loops", "The Holes slot should be the active one.")
	# A point of an open loop that faces the view: the rim of that hole's fill.
	var spot := Vector2(-1, -1)
	var wanted := -1
	for loop in input.boundary_loops():
		for point in (loop.points as PackedVector3Array):
			var at: Vector2 = ws.viewport.project(point)
			if not at.is_finite() or _covered(at):
				continue
			var hit: Dictionary = ws.viewport.face_hit_at(at)
			if not hit.is_empty() and str(hit.body) == holes and (hit.point as Vector3).distance_to(point) < 0.004:
				spot = at
				wanted = int(loop.id)
				break
		if wanted >= 0:
			break
	check(wanted >= 0, "An open loop of HookHoles should face the view.")
	if wanted >= 0:
		await _click(_g(spot))
		await _frames(2)
		var loops: Array = ws.command_values.get("loops", [])
		check(loops.size() == 1 and str(loops[0].get("kind", "")) == "mesh_boundary" and int(loops[0].loop) == wanted and str(loops[0].digest) == str(input.digest()),
			"A click at a fill's rim should pick that hole of the body as it was (%s; %s)." % [loops, ws.last_message])
		check(ws.command.boundary_points(loops[0] if loops.size() == 1 else {}).size() >= 3, "The picked hole's rim should be found for drawing.")
		check((ws.panel._editors["loops"] as Button).text.begins_with("Hole ("), "The Holes slot should name the picked hole (%s)." % (ws.panel._editors["loops"] as Button).text)
		stat = await _stat(8)
		await _shot("preview_dark_close_holes_one_picked.png")
		# OK computes again with the full time: the panel says so first, and takes OK away.
		await _press(ws.panel._ok)
		var working := str(ws.panel.info("stat"))
		check(ws.command != null and working == ws.command.COMPUTING % ["Close Holes", int(MESH_FEATURE.OK_SECONDS)] and (ws.panel._ok as Button).disabled,
			"Right after OK the panel should say that it is computing, with OK taken away (%s)." % working)
		await _frames(4)
		check(ws.command == null and _mesh(holes) != null and _mesh(holes).boundary_loops().size() == 4, "Close Holes with one hole picked should close that one and leave 4 (%d left; %s)." % [
			_mesh(holes).boundary_loops().size() if _mesh(holes) != null else -1, ws.last_message])
		check(not str(ws.result.warnings.get(doc.features.back().id, "")).contains("on an older version"), "The pick should not count as one made on another mesh (%s)." % ws.result.warnings.get(doc.features.back().id, ""))
	if ws.command != null:
		ws.cancel_command()
	await _undo_to(mark)
	# Erase and Fill: a second triangle picked after the preview erased and filled the first.
	_nothing_selected()
	ws.run_tool(_tool("mesh.select.select_triangles"))
	await _look_at([ball], 0.7, -0.5, 0.28)
	var before: RefCounted = _mesh(ball)
	ws.run_tool(_tool("mesh.modify.erase_and_fill"))
	await _frames(3)
	if ws.command == null:
		check(false, "Erase and Fill should open.")
		return
	var feature_id := str(ws.command.feature.id)
	var spots := _points_on(ball)
	var second := Vector2(-1, -1)
	for candidate in spots:
		if (candidate as Vector2).distance_to(spots[0]) > 90.0:
			second = candidate
			break
	check(spots.size() > 1 and second.x >= 0.0, "Two spots well apart on the ball are needed.")
	if second.x < 0.0:
		ws.cancel_command()
		return
	await _click(_g(spots[0]))
	stat = await _stat(8)
	var first_pick: Array = ws.command_values.get("selection", [])
	var changed := _mesh(ball) != null and str(_mesh(ball).digest()) != str(before.digest())
	check(first_pick.size() == 1 and (first_pick[0].triangles as PackedInt32Array).size() == 1 and changed, "The first triangle should be picked and the preview should erase and fill it (%s; %s)." % [first_pick, stat.replace("\n", " / ")])
	var ray: Array = ws.viewport.ray_from(second)
	var on_input: Dictionary = before.ray_hit(ray[0], (ray[1] as Vector3).normalized())
	await _click(_g(second))
	stat = await _stat(8)
	var picks: Array = ws.command_values.get("selection", [])
	var triangles: PackedInt32Array = picks[0].triangles if picks.size() == 1 else PackedInt32Array()
	check(picks.size() == 1 and triangles.size() == 2 and bool(on_input.get("hit", false)) and triangles.has(int(on_input.get("triangle", -1))) and str(picks[0].digest) == str(before.digest()),
		"The second triangle should be the one under the click on the mesh the tool works on (%s, wanted %s; %s)." % [triangles, on_input.get("triangle", "?"), ws.last_message])
	var removed := 0
	for entry in ws.command.preview_meshes(ws.command_values):
		if str(entry.look) == "removed":
			removed += int(entry.triangles)
	check(removed == 2 and (stat == ws.command.PREVIEW_SKIPPED or stat.contains("Erased 2 triangles")), "Both picked triangles should show as erased (%d drawn; %s)." % [removed, stat.replace("\n", " / ")])
	check(not ws.viewport.mesh_highlights().any(func(h: Dictionary) -> bool: return h.look == "selected"), "The picked triangles should not be marked on the preview's mesh, where their numbers mean others.")
	await _shot("preview_dark_erase_fill_two_picks.png")
	await _ok()
	var line := str((MESH_FEATURE.reports.get(feature_id, {}) as Dictionary).get("stat", ""))
	check(ws.command == null and _open_edges(_mesh(ball)) == 0 and line.contains("Erased 2 triangles") and not str(ws.result.warnings.get(feature_id, "")).contains("on an older version"),
		"Erase and Fill should erase the two picked triangles and close their holes (%s; %s; %s)." % [line, ws.result.warnings.get(feature_id, ""), ws.last_message])
	if ws.command != null:
		ws.cancel_command()
	await _undo_to(mark)
	ws.run_tool(_tool("mesh.select.select_face_groups"))
	await _frames(2)


# --- An existing Mesh feature opened from the timeline --------------------------------------------

## A real double-click on a feature's chip in the timeline.
func _double_click_chip(feature_id: String) -> void:
	var chip := _chip(feature_id)
	if chip == null or not chip.is_visible_in_tree():
		check(false, "The timeline should show the feature's chip.")
		return
	# (The timeline scrolls: the chip is brought into view first.)
	var above: Node = chip.get_parent()
	while above != null and not (above is ScrollContainer):
		above = above.get_parent()
	if above is ScrollContainer:
		(above as ScrollContainer).ensure_control_visible(chip)
		await _frames(2)
	var at := _center(chip)
	_move(at)
	await _tree.process_frame
	_move(at)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.double_click = pressed
		event.position = at
		event.global_position = at
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		gui.push_input(event, true)
	await _frames(4)


## Close Holes and Erase and Fill are made, then opened again from the timeline: the picks made
## then are of the mesh before the feature, not of its result, and the numbers start from it.
func _check_edit_existing() -> void:
	var holes := str(model.get("holes", ""))
	var ball := str(model.get("ball", ""))
	if _mesh(holes) == null or _mesh(ball) == null:
		return
	var mark := history.get_current_action()
	# Close Holes on every hole, then edited to close one.
	var input: RefCounted = _mesh(holes)
	var feature_id := await _open("mesh:close_holes", {"bodies": [_pick(holes)]})
	if feature_id == "":
		return
	await _ok()
	check(ws.command == null and _mesh(holes) != null and _mesh(holes).boundary_loops().is_empty(), "Close Holes should close every hole first (%s)." % ws.last_message)
	await _look_at([holes], 0.7, -0.5, 0.28)
	await _double_click_chip(feature_id)
	check(ws.command != null and ws.command.editing and str(ws.command.feature.id) == feature_id and ws.command._input_known, "A double-click on the chip should open the feature for editing, with the mesh before it at hand.")
	if ws.command == null or not ws.command.editing:
		await _undo_to(mark)
		return
	var stat := await _stat(6)
	check(stat.begins_with("Triangles: 4,797 \u2192 "), "The stat row of an edited feature should count from the mesh before it (%s)." % stat.replace("\n", " / "))
	if ws.panel.active_selection_key != "loops":
		await _press(ws.panel._editors["loops"])
	var spot := Vector2(-1, -1)
	var wanted := -1
	for loop in input.boundary_loops():
		for point in (loop.points as PackedVector3Array):
			var at: Vector2 = ws.viewport.project(point)
			if not at.is_finite() or _covered(at):
				continue
			var hit: Dictionary = ws.viewport.face_hit_at(at)
			if not hit.is_empty() and str(hit.body) == holes and (hit.point as Vector3).distance_to(point) < 0.004:
				spot = at
				wanted = int(loop.id)
				break
		if wanted >= 0:
			break
	check(wanted >= 0, "A hole's rim should face the view.")
	if wanted >= 0:
		await _click(_g(spot))
		await _frames(2)
		var loops: Array = ws.command_values.get("loops", [])
		check(loops.size() == 1 and int(loops[0].get("loop", -1)) == wanted and str(loops[0].get("digest", "")) == str(input.digest()),
			"With the feature open again, a click at a fill's rim should pick that hole of the mesh before the feature (%s; %s)." % [loops, ws.last_message])
		stat = await _stat(8)
		await _shot("edit_dark_close_holes_hole_picked.png")
		var before_ok := history.get_current_action()
		await _ok()
		check(ws.command == null and _mesh(holes) != null and _mesh(holes).boundary_loops().size() == 4 and history.get_current_action() == before_ok + 1 and _undo_name() == "Forge: Mesh: Close Holes",
			"The edited Close Holes should close the one picked hole, in one step (%d left; '%s'; %s)." % [_mesh(holes).boundary_loops().size() if _mesh(holes) != null else -1, _undo_name(), ws.last_message])
		check(not str(ws.result.warnings.get(feature_id, "")).contains("on an older version"), "The pick should not count as one made on another mesh (%s)." % ws.result.warnings.get(feature_id, ""))
	if ws.command != null:
		ws.cancel_command()
	await _undo_to(mark)
	# Erase and Fill of one triangle, then edited to take a second one.
	_nothing_selected()
	ws.run_tool(_tool("mesh.select.select_triangles"))
	await _look_at([ball], 0.7, -0.5, 0.28)
	var before: RefCounted = _mesh(ball)
	var spots := _points_on(ball)
	var second := Vector2(-1, -1)
	for candidate in spots:
		if (candidate as Vector2).distance_to(spots[0]) > 90.0:
			second = candidate
			break
	if spots.size() < 2 or second.x < 0.0:
		check(false, "Two spots well apart on the ball are needed.")
		return
	ws.run_tool(_tool("mesh.modify.erase_and_fill"))
	await _frames(3)
	if ws.command == null:
		check(false, "Erase and Fill should open.")
		return
	feature_id = str(ws.command.feature.id)
	await _click(_g(spots[0]))
	await _stat(8)
	await _ok()
	var once := str((MESH_FEATURE.reports.get(feature_id, {}) as Dictionary).get("stat", ""))
	check(ws.command == null and once.contains("Erased 1 triangle") and _mesh(ball) != null and str(_mesh(ball).digest()) != str(before.digest()), "Erase and Fill should erase the one picked triangle first (%s; %s)." % [once, ws.last_message])
	await _double_click_chip(feature_id)
	check(ws.command != null and ws.command.editing and str(ws.command.feature.id) == feature_id, "A double-click on the chip should open Erase and Fill again.")
	if ws.command == null or not ws.command.editing:
		await _undo_to(mark)
		return
	await _stat(6)
	if ws.panel.active_selection_key != "selection":
		await _press(ws.panel._editors["selection"])
	var ray: Array = ws.viewport.ray_from(second)
	var on_input: Dictionary = before.ray_hit(ray[0], (ray[1] as Vector3).normalized())
	await _click(_g(second))
	stat = await _stat(8)
	var picks: Array = ws.command_values.get("selection", [])
	var triangles: PackedInt32Array = picks[0].triangles if picks.size() == 1 else PackedInt32Array()
	check(picks.size() == 1 and triangles.size() == 2 and bool(on_input.get("hit", false)) and triangles.has(int(on_input.get("triangle", -1))) and str(picks[0].digest) == str(before.digest()),
		"With the feature open again, the second triangle should be the one under the click on the mesh before the feature (%s, wanted %s; %s)." % [triangles, on_input.get("triangle", "?"), ws.last_message])
	var removed := 0
	for entry in ws.command.preview_meshes(ws.command_values):
		if str(entry.look) == "removed":
			removed += int(entry.triangles)
	check(removed == 2, "Both triangles should show as erased while the feature is edited (%d drawn)." % removed)
	await _shot("edit_dark_erase_fill_second_pick.png")
	await _ok()
	var twice := str((MESH_FEATURE.reports.get(feature_id, {}) as Dictionary).get("stat", ""))
	check(ws.command == null and twice.contains("Erased 2 triangles") and _open_edges(_mesh(ball)) == 0 and not str(ws.result.warnings.get(feature_id, "")).contains("on an older version"),
		"The edited Erase and Fill should erase both triangles (%s; %s; %s)." % [twice, ws.result.warnings.get(feature_id, ""), ws.last_message])
	if ws.command != null:
		ws.cancel_command()
	await _undo_to(mark)
	ws.run_tool(_tool("mesh.select.select_face_groups"))
	await _frames(2)


# --- Picks hold a point and the facing there ------------------------------------------------------

## A spot of the view on body_id's surface where it faces along facing and keep (given the point
## hit) says yes; (-1, -1) when there is none.
func _spot_on(body_id: String, facing: Vector3, keep: Callable) -> Vector2:
	for at in _points_on(body_id, facing):
		var hit: Dictionary = ws.viewport.face_hit_at(at)
		if not hit.is_empty() and bool(keep.call(hit.point)):
			return at
	return Vector2(-1, -1)


## What a ray coming in against out meets first on a mesh, near toward: {"name": the face group's,
## "normal"} ({} when it misses).
func _met(mesh: RefCounted, toward: Vector3, out: Vector3) -> Dictionary:
	var hit: Dictionary = mesh.ray_hit(toward + out * 0.1, -out, 1.0) if mesh != null else {}
	if not bool(hit.get("hit", false)):
		return {}
	return {"name": str(mesh.get_face_names()[int(hit.group)]), "normal": hit.normal}


## The stored triangle of mesh that a pick's point lies on, going by its facing (-1: none).
func _triangle_under(mesh: RefCounted, pick: Dictionary) -> int:
	if mesh == null or not (pick.get("at") is Vector3) or not (pick.get("normal") is Vector3):
		return -1
	var hit: Dictionary = mesh.ray_hit((pick.at as Vector3) + (pick.normal as Vector3) * 1e-4, -(pick.normal as Vector3), 2e-4)
	return int(hit.triangle) if bool(hit.get("hit", false)) else -1


## The only pick in a slot of the running tool ({} when it holds none, or more).
func _only_pick(key: String) -> Dictionary:
	var picks: Array = ws.command_values.get(key, []) if ws.command != null else []
	return picks[0] if picks.size() == 1 and picks[0] is Dictionary else {}


## Every mesh pick a panel stores holds a point on what was picked and how the surface faces
## there: one clicked for a slot, and one taken over from the selection when the tool starts.
## Face groups are named by order; with the name, the point and the facing a tool stays on its
## face when a feature put before Generate Face Groups renames them (and says so).
func _check_pick_anchors() -> void:
	var holes := str(model.get("holes", ""))
	var mark := history.get_current_action()
	var cube: Dictionary = FIXTURES.two_cubes(Vector3(0.03, 0.0, 0.0)).first
	var places := {"clicked": -0.6, "taken": -0.9}
	var made := {}
	ws.change("Mesh Hook Anchor Cubes", func() -> void:
		for key in places:
			var body := _add_mesh(_moved(cube, Vector3(float(places[key]), 0.0, 0.0)), "HookAnchor" + str(key).capitalize())
			made[key] = body
			var generate: Resource = ws.doc.add_feature("mesh", "GenerateFaceGroups", {"angle": ws.doc.make_input("20", "angle")}, {"method": "generate_groups", "bodies": [_pick(body)], "algorithm": "fast"})
			made[str(key) + "_generate"] = str(generate.id))
	doc = ws.doc
	await _frames(3)
	var clicked := str(made.get("clicked", ""))
	var taken := str(made.get("taken", ""))
	if _mesh(clicked) == null or _mesh(taken) == null or int(_mesh(clicked).face_count()) != 6 or int(_mesh(taken).face_count()) != 6:
		check(false, "Two cubes with six generated face groups each should build (%s)." % [ws.result.errors])
		await _undo_to(mark)
		doc = ws.doc
		return
	ws.run_tool(_tool("mesh.select.select_face_groups"))
	_nothing_selected()
	# 1. A face group clicked for a panel's slot: on the +X face, in the part that a cut at
	#    z = 5 mm keeps (the cut comes last).
	await _look_at([clicked], 0.9, -0.45, 0.28)
	var spot := _spot_on(clicked, Vector3.RIGHT, func(point: Vector3) -> bool: return point.z > 0.0065 and point.z < 0.0095 and absf(point.y) < 0.008)
	check(spot.x >= 0.0, "The +X face of HookAnchorClicked should face the view.")
	var first_id := await _open("mesh:reverse_normal", {"mode": "selection"})
	if first_id == "" or spot.x < 0.0:
		if ws.command != null:
			ws.cancel_command()
		await _undo_to(mark)
		doc = ws.doc
		return
	if ws.panel.active_selection_key != "selection":
		await _press(ws.panel._editors["selection"])
	var under: Dictionary = ws.viewport.face_hit_at(spot)
	await _click(_g(spot))
	await _frames(2)
	var pick := _only_pick("selection")
	var side_name := str(pick.get("group", ""))
	check(str(pick.get("kind", "")) == "mesh_group" and str(pick.get("body", "")) == clicked and pick.get("at") is Vector3 and pick.get("normal") is Vector3
		and (pick.get("at", Vector3.INF) as Vector3).distance_to(under.get("point", Vector3.ZERO)) < 1e-6 and (pick.get("normal", Vector3.ZERO) as Vector3).dot(Vector3.RIGHT) > 0.99,
		"A face group clicked for a panel's slot should be stored with its point and the facing there (%s; hit %s; %s)." % [ws.command_values.get("selection", []), under, ws.last_message])
	await _ok()
	var first: Resource = ws.doc.find_feature(first_id)
	var kept: Array = first.options.get("selection", []) if first != null else []
	var turned := _met(_mesh(clicked), Vector3(float(places.clicked) + 0.01, 0.0, 0.0075), Vector3.RIGHT)
	check(ws.command == null and kept.size() == 1 and kept[0] is Dictionary and kept[0].get("at") is Vector3 and kept[0].get("normal") is Vector3 and str(kept[0].get("group", "")) == side_name,
		"The feature should keep the pick's point and facing (%s; %s)." % [kept, ws.last_message])
	check(not turned.is_empty() and (turned.normal as Vector3).x < -0.9 and str(turned.name) == side_name, "Reverse Normal should turn the picked +X face group round (%s)." % [turned])
	# 2. A face group taken over from the selection when the tool starts.
	_nothing_selected()
	await _look_at([taken], 0.9, -0.45, 0.28)
	var taken_spot := _spot_on(taken, Vector3.RIGHT, func(_point: Vector3) -> bool: return true)
	check(taken_spot.x >= 0.0, "The +X face of HookAnchorTaken should face the view.")
	await _click(_g(taken_spot))
	await _frames(1)
	var taken_mesh := _mesh(taken)
	var selected: PackedStringArray = ws.mesh_selection.groups_of(taken, taken_mesh)
	check(selected.size() == 1, "A click should select the +X face group (%s)." % [selected])
	ws.start_command(FEATURE_COMMAND.new("mesh:reverse_normal"))
	await _frames(2)
	var second_id := str(ws.command.feature.id) if ws.command != null else ""
	var taken_pick := _only_pick("selection")
	var taken_name := str(taken_pick.get("group", ""))
	var found: Dictionary = MESH_BODY.resolve_group(taken_mesh, taken_pick) if not taken_pick.is_empty() else {}
	check(str(taken_pick.get("kind", "")) == "mesh_group" and selected.size() == 1 and taken_name == selected[0] and taken_pick.get("at") is Vector3 and taken_pick.get("normal") is Vector3
		and (taken_pick.get("normal", Vector3.ZERO) as Vector3).dot(Vector3.RIGHT) > 0.99 and absf((taken_pick.get("at", Vector3.INF) as Vector3).x - (float(places.taken) + 0.01)) < 1e-6,
		"A face group taken over from the selection should be stored with a point on it and the facing there (%s)." % [ws.command_values.get("selection", []) if ws.command != null else []])
	check(str(found.get("name", "")) == taken_name and not bool(found.get("moved", true)) and not found.has("unchecked"), "That point and facing should find the group itself on the mesh (%s)." % [found])
	if second_id != "":
		var asked: Dictionary = ws.command_values.duplicate(true)
		asked["mode"] = "selection"
		ws.set_command_values(asked)
		await _frames(4)
		await _ok()
	var second: Resource = ws.doc.find_feature(second_id) if second_id != "" else null
	var second_kept: Array = second.options.get("selection", []) if second != null else []
	turned = _met(_mesh(taken), Vector3(float(places.taken) + 0.01, 0.0, 0.0075), Vector3.RIGHT)
	check(ws.command == null and second_kept.size() == 1 and second_kept[0] is Dictionary and second_kept[0].get("at") is Vector3 and second_kept[0].get("normal") is Vector3
		and not turned.is_empty() and (turned.normal as Vector3).x < -0.9, "Reverse Normal of the taken-over face group should keep its point and facing and turn the +X face round (%s; %s; %s)." % [second_kept, turned, ws.last_message])
	note("pick anchors: the clicked group is stored at %s facing %s, the taken-over one at %s facing %s" % [pick.get("at"), pick.get("normal"), taken_pick.get("at"), taken_pick.get("normal")])
	# 3. Triangles: taken over from the selection, then one clicked for the slot and taken out.
	_nothing_selected()
	ws.run_tool(_tool("mesh.select.select_triangles"))
	await _frames(1)
	var input := _mesh(taken)
	var spot_a := Vector2(-1, -1)
	var spot_b := Vector2(-1, -1)
	var triangle_a := -1
	var triangle_b := -1
	for at in _points_on(taken, Vector3.UP):
		var t := int(ws.viewport.face_hit_at(at).get("triangle", -1))
		if t < 0:
			continue
		if triangle_a < 0:
			triangle_a = t
			spot_a = at
		elif t != triangle_a:
			triangle_b = t
			spot_b = at
			break
	check(triangle_b >= 0, "Both triangles of the cube's top face should face the view.")
	if triangle_b >= 0:
		await _click(_g(spot_a))
		await _frames(1)
		check(ws.mesh_selection.count() == 1, "A click in triangle mode should select one triangle (%d)." % ws.mesh_selection.count())
		ws.run_tool(_tool("mesh.modify.erase_and_fill"))
		await _stat(8)
		var of_triangles := _only_pick("selection")
		check(str(of_triangles.get("kind", "")) == "mesh_triangles" and (of_triangles.get("triangles", PackedInt32Array()) as PackedInt32Array) == PackedInt32Array([triangle_a])
			and (of_triangles.get("normal", Vector3.ZERO) as Vector3).dot(Vector3.UP) > 0.99 and _triangle_under(input, of_triangles) == triangle_a,
			"Triangles taken over from the selection should be stored with a point on one of them and the facing there (%s; wanted triangle %d)." % [ws.command_values.get("selection", []) if ws.command != null else [], triangle_a])
		if ws.command != null:
			if ws.panel.active_selection_key != "selection":
				await _press(ws.panel._editors["selection"])
			await _click(_g(spot_b))
			await _stat(8)
			of_triangles = _only_pick("selection")
			check((of_triangles.get("triangles", PackedInt32Array()) as PackedInt32Array).size() == 2 and _triangle_under(input, of_triangles) == triangle_b and (of_triangles.get("normal", Vector3.ZERO) as Vector3).dot(Vector3.UP) > 0.99,
				"A triangle clicked for the slot should bring its point and facing (%s; wanted triangle %d; %s)." % [ws.command_values.get("selection", []), triangle_b, ws.last_message])
			await _click(_g(spot_b))
			await _stat(8)
			of_triangles = _only_pick("selection")
			check((of_triangles.get("triangles", PackedInt32Array()) as PackedInt32Array) == PackedInt32Array([triangle_a]) and _triangle_under(input, of_triangles) == triangle_a,
				"With the clicked triangle taken out again, the pick's point should lie on the triangle it still holds (%s; wanted triangle %d; %s)." % [ws.command_values.get("selection", []), triangle_a, ws.last_message])
			ws.cancel_command()
			await _frames(2)
	# 4. A hole clicked for Close Holes' slot.
	_nothing_selected()
	if _mesh(holes) != null:
		var with_holes: RefCounted = _mesh(holes)
		await _look_at([holes], 0.7, -0.5, 0.28)
		var hole_id := await _open("mesh:close_holes", {"bodies": [_pick(holes)]})
		if hole_id != "":
			await _stat(8)
			if ws.panel.active_selection_key != "loops":
				await _press(ws.panel._editors["loops"])
			var rim := Vector2(-1, -1)
			for loop in with_holes.boundary_loops():
				for point in (loop.points as PackedVector3Array):
					var at: Vector2 = ws.viewport.project(point)
					if not at.is_finite() or _covered(at):
						continue
					var hit: Dictionary = ws.viewport.face_hit_at(at)
					if not hit.is_empty() and str(hit.body) == holes and (hit.point as Vector3).distance_to(point) < 0.004:
						rim = at
						break
				if rim.x >= 0.0:
					break
			check(rim.x >= 0.0, "A hole's rim of HookHoles should face the view.")
			if rim.x >= 0.0:
				await _click(_g(rim))
				await _frames(2)
				var hole := _only_pick("loops")
				check(str(hole.get("kind", "")) == "mesh_boundary" and hole.get("at") is Vector3 and hole.get("normal") is Vector3 and absf((hole.get("normal", Vector3.ZERO) as Vector3).length() - 1.0) < 1e-4,
					"A clicked hole should be stored with the point of its rim and the facing of the surface beside it (%s; %s)." % [ws.command_values.get("loops", []), ws.last_message])
			if ws.command != null:
				ws.cancel_command()
			await _frames(2)
	# 5. A cut put before each cube's Generate Face Groups renames the groups: both Reverse Normal
	#    features stay on the +X face and say that the group moved.
	ws.run_tool(_tool("mesh.select.select_face_groups"))
	_nothing_selected()
	ws.change("Mesh Hook Earlier Cut", func() -> void:
		for key in places:
			var cut: Resource = ws.doc.add_feature("mesh", "PlaneCut", {"offset": ws.doc.make_input("5 mm", "length")}, {"method": "plane_cut", "bodies": [_pick(str(made[key]))], "plane": [XY], "type": "trim", "fill": "uniform"})
			ws.doc.features.erase(cut)
			ws.doc.features.insert(ws.doc.feature_index(str(made[str(key) + "_generate"])), cut))
	doc = ws.doc
	await _frames(4)
	for entry in [[clicked, first_id, side_name, float(places.clicked), "clicked for the slot"], [taken, second_id, taken_name, float(places.taken), "taken over from the selection"]]:
		var now := _mesh(str(entry[0]))
		var x: float = entry[3]
		var side := _met(now, Vector3(x + 0.01, 0.0, 0.0075), Vector3.RIGHT)
		var top := _met(now, Vector3(x, 0.01, 0.0075), Vector3.UP)
		var error := str(ws.result.errors.get(entry[1], ""))
		var warning := str(ws.result.warnings.get(entry[1], ""))
		check(now != null and (now.bbox() as AABB).size.z < 0.019 and not side.is_empty() and str(side.name) != str(entry[2]),
			"The earlier cut should take a part of the cube off and rename its +X face group, or the case shows nothing (the group was %s, is %s; size %s; errors %s)." % [entry[2], side.get("name", "?"), (now.bbox() as AABB).size if now != null else Vector3.ZERO, ws.result.errors])
		check(error == "" and not side.is_empty() and (side.normal as Vector3).x < -0.9 and not top.is_empty() and (top.normal as Vector3).y > 0.9 and warning.contains("pick of face group %s now lands on face group %s" % [entry[2], side.get("name", "?")]),
			"With the groups renamed by an earlier cut, Reverse Normal of the group %s should still turn the +X face round, and no other, and say that the group moved (+X %s, +Y %s; error '%s'; warning '%s')." % [entry[4], side, top, error, warning])
		note("pick anchors, %s: after the earlier cut the group %s is %s; %s" % [entry[4], entry[2], side.get("name", "?"), warning])
	# 6. A pick as an older design kept it, by name alone: the feature builds, and its chip says
	#    that the pick could not be confirmed.
	var old := {}
	var top_now := str(_met(_mesh(taken), Vector3(float(places.taken), 0.01, 0.0075), Vector3.UP).get("name", ""))
	ws.change("Mesh Hook Old Pick", func() -> void:
		var by_name: Resource = ws.doc.add_feature("mesh", "MeshReverseNormal", {}, {"method": "reverse_normal", "mode": "selection", "bodies": [], "selection": [{"kind": "mesh_group", "body": taken, "group": top_now}]})
		old["id"] = str(by_name.id))
	doc = ws.doc
	await _frames(3)
	var old_chip := _chip(str(old.get("id", "")))
	var old_warning := str(ws.result.warnings.get(str(old.get("id", "")), ""))
	check(top_now != "" and not ws.result.errors.has(str(old.get("id", ""))) and old_warning.contains("could not be confirmed") and old_chip != null and old_chip.tooltip_text.contains("Note: ")
		and old_chip.tooltip_text.replace("\n", " ").contains("could not be confirmed") and str(old_chip.get_meta("warning", "")) == old_warning,
		"A face group pick kept by name alone should build with a warning that the chip shows (warning '%s'; errors %s; tooltip '%s')." % [old_warning, ws.result.errors, old_chip.tooltip_text.replace("\n", " / ") if old_chip != null else "no chip"])
	await _undo_to(mark)
	doc = ws.doc
	_nothing_selected()
	await _frames(2)


# --- A preview stops after its feature -------------------------------------------------------------

## The panel's Cancel, by a real click.
func _cancel() -> void:
	var cancel := (ws.panel._ok as Control).get_parent().get_child(1) as Button
	await _press(cancel)
	await _frames(3)


## The chips of features that say they are waiting for the preview to end (their feature ids).
func _waiting_chips() -> Array:
	var ids := []
	for chip in ws.timeline._chips:
		if bool((chip as Button).get_meta("waiting", false)):
			ids.append(str((chip as Button).get_meta("feature_id", "")))
	return ids


## An early Scale Mesh with slow features after it (Reduce, Smooth, Remesh) and a body that a later
## feature brings in. Opened from the timeline, its preview stops after the Scale: the body shows
## as it leaves it, the later features are not run and do not read as failed, the later body is
## still there, and OK or Cancel rebuild the whole timeline.
func _check_preview_stops() -> void:
	var mark := history.get_current_action()
	var made := {}
	var started := Time.get_ticks_msec()
	ws.change("Mesh Hook Long Timeline", func() -> void:
		var ball := _add_mesh(_moved(FIXTURES.icosphere(0.05, 6), Vector3(-1.6, 0.0, 0.0)), "HookLong")
		made["ball"] = ball
		var specs := [
			["scale", "MeshScale", {"point": [], "uniform": true}, {"scale": ["1.5", "number"]}],
			["reduce", "Reduce", {"selection": [], "target": "proportion", "algorithm": "adaptive", "keep_boundary": true, "keep_groups": true, "keep_sharp": false}, {"proportion": ["50", "number"]}],
			["smooth", "Smooth", {"selection": [], "keep_volume": true, "keep_sharp": false, "keep_boundary": true}, {"strength": ["0.5", "number"], "iterations": ["5", "number"]}],
			["remesh", "Remesh", {"selection": [], "mode": "uniform", "keep_sharp": true, "keep_boundary": true, "keep_groups": true}, {"density": ["0.5", "number"], "iterations": ["10", "number"]}],
		]
		for spec in specs:
			var inputs := {}
			for key in spec[3]:
				inputs[key] = ws.doc.make_input(str(spec[3][key][0]), str(spec[3][key][1]))
			var options: Dictionary = (spec[2] as Dictionary).duplicate(true)
			options["method"] = spec[0]
			options["bodies"] = [_pick(ball)]
			var feature: Resource = ws.doc.add_feature("mesh", str(spec[1]), inputs, options)
			made[spec[0]] = str(feature.id)
		made["later"] = _add_mesh(_moved(FIXTURES.cube(), Vector3(-1.35, 0.0, 0.0)), "HookLater")
		made["later_feature"] = str(ws.doc.features.back().id))
	var whole_ms := Time.get_ticks_msec() - started
	doc = ws.doc
	await _frames(3)
	var ball := str(made.get("ball", ""))
	var later := str(made.get("later", ""))
	var scale_id := str(made.get("scale", ""))
	var after_scale := [str(made.get("reduce", "")), str(made.get("smooth", "")), str(made.get("remesh", "")), str(made.get("later_feature", ""))]
	if _mesh(ball) == null or _mesh(later) == null or not ws.result.errors.is_empty():
		check(false, "The long timeline should build (%s)." % [ws.result.errors])
		await _undo_to(mark)
		doc = ws.doc
		return
	var built := int(_mesh(ball).triangle_count())
	check(built != 81920 and absf((_mesh(ball).bbox() as AABB).size.x - 0.15) < 0.01 and _waiting_chips().is_empty(), "The whole timeline should scale, reduce, smooth and remesh the ball (%d triangles, %s wide)." % [built, (_mesh(ball).bbox() as AABB).size.x])
	# The Scale is opened from the timeline, with the later body selected.
	_select_body(later)
	await _look_at([ball, later], 0.7, -0.5, 0.2)
	await _double_click_chip(scale_id)
	if ws.command == null or not ws.command.editing or str(ws.command.feature.id) != scale_id:
		check(false, "A double-click on the Scale's chip should open it (%s)." % ws.last_message)
		await _undo_to(mark)
		doc = ws.doc
		return
	await _stat(6)
	var shown := _mesh(ball)
	check(str(ws.result.get("preview_stops_at", "")) == scale_id and (ws.result.get("preview_later", []) as Array) == after_scale,
		"The preview should stop after the Scale and name the features it left out (%s; %s)." % [ws.result.get("preview_stops_at", ""), ws.result.get("preview_later", [])])
	check(shown != null and int(shown.triangle_count()) == 81920 and absf((shown.bbox() as AABB).size.x - 0.15) < 1e-3,
		"The ball should show as it leaves the Scale: all its triangles, 150 mm wide (%d, %s)." % [int(shown.triangle_count()) if shown != null else -1, (shown.bbox() as AABB).size.x if shown != null else 0.0])
	var surface: MeshInstance3D = ws.viewport.body_surface(later)
	check(ws.result.bodies.has(later) and (ws.result.get("preview_held", []) as Array) == [later] and surface != null and surface.is_visible_in_tree() and ws.browser.body_item(later) != null
		and ws.selection.size() == 1 and str(ws.selection[0].get("body", "")) == later,
		"The body a later feature brings in should stay in the view, the browser and the selection during the preview (held %s; selection %s)." % [ws.result.get("preview_held", []), ws.selection])
	var said_waiting := true
	for id in after_scale:
		var chip := _chip(str(id))
		said_waiting = said_waiting and chip != null and bool(chip.get_meta("waiting", false)) and chip.tooltip_text.replace("\n", " ").contains("Not shown during the preview of") and not chip.tooltip_text.contains("\u26a0")
	check(said_waiting and _waiting_chips() == after_scale and ws.result.errors.is_empty(), "The chips after the Scale should say that they are not shown during the preview, and none should read as failed (%s; errors %s)." % [_waiting_chips(), ws.result.errors])
	ws._status_timer.stop()
	ws._update_status()
	check(str(ws._status.text).contains("Preview of ") and str(ws._status.text).contains("The 4 features after it are worked out again on OK or Cancel."), "The status line should say what the preview leaves out (%s)." % str(ws._status.text).replace("\n", " / "))
	# A typed factor: the preview answers without the later features.
	await _type_into("scale", "2")
	for i in 240:
		if _mesh(ball) != null and absf((_mesh(ball).bbox() as AABB).size.x - 0.2) < 1e-3:
			break
		await _tree.process_frame
	var preview_ms := Time.get_ticks_msec() - _last_key_msec
	shown = _mesh(ball)
	check(shown != null and absf((shown.bbox() as AABB).size.x - 0.2) < 1e-3 and int(shown.triangle_count()) == 81920 and str(ws.result.get("preview_stops_at", "")) == scale_id and ws.result.errors.is_empty()
		and ws.result.bodies.has(later) and ws.viewport.body_surface(later) != null and _waiting_chips() == after_scale and ws.selection.size() == 1,
		"A typed factor of 2 should show the ball 200 mm wide as it leaves the Scale, with the later body still there (%s wide; errors %s)." % [(shown.bbox() as AABB).size.x if shown != null else 0.0, ws.result.errors])
	# The stat row counts the body as it leaves the Scale, not as the later features leave it.
	var scale_stat := str(ws.panel.info("stat"))
	check(scale_stat.contains("81,920") and not scale_stat.contains(FEATURE_COMMAND.with_commas(built)), "The stat row should count the ball as it leaves the Scale (%s; the whole timeline leaves %d triangles)." % [scale_stat.replace("
", " / "), built])
	check(preview_ms <= 1500, "The preview of the Scale should answer near its half second, without the features after it (%d ms; the whole timeline took %d ms)." % [preview_ms, whole_ms])
	# The later body is not there yet where the Scale works: a click on it is refused.
	if ws.panel.active_selection_key != "bodies":
		await _press(ws.panel._editors["bodies"])
	await _click(_g(_point_on(later)))
	await _frames(1)
	check((ws.command_values.get("bodies", []) as Array) == [_pick(ball)] and ws.last_message.contains("is made later in the timeline"), "A click on the later body should be refused for the Scale (%s; %s)." % [ws.command_values.get("bodies", []), ws.last_message])
	# OK rebuilds the whole timeline.
	var before_ok := history.get_current_action()
	started = Time.get_ticks_msec()
	await _press(ws.panel._ok)
	for i in 900:
		if ws.command == null:
			break
		await _tree.process_frame
	var ok_ms := Time.get_ticks_msec() - started
	await _frames(4)
	var done := _mesh(ball)
	check(ws.command == null and not ws.result.has("preview_stops_at") and ws.result.errors.is_empty() and _waiting_chips().is_empty() and done != null and int(done.triangle_count()) != 81920
		and absf((done.bbox() as AABB).size.x - 0.2) < 0.01 and ws.result.bodies.has(later) and history.get_current_action() == before_ok + 1 and _undo_name() == "Forge: Mesh: Scale Mesh",
		"OK should rebuild the whole timeline on the scaled ball, in one step (%d triangles, %s wide; errors %s; '%s'; %s)." % [int(done.triangle_count()) if done != null else -1, (done.bbox() as AABB).size.x if done != null else 0.0, ws.result.errors, _undo_name(), ws.last_message])
	note("preview of an early Scale: %d ms after the typed key; the whole timeline took %d ms when it was made and OK took %d ms" % [preview_ms, whole_ms, ok_ms])
	var kept := str(done.digest()) if done != null else ""
	# Cancel after a change, and Cancel with nothing changed: both end with the whole timeline.
	for typed in ["3", ""]:
		await _double_click_chip(scale_id)
		if ws.command == null:
			check(false, "The Scale should open again (%s)." % ws.last_message)
			break
		await _stat(6)
		if typed != "":
			await _type_into("scale", typed)
			for i in 240:
				if _mesh(ball) != null and absf((_mesh(ball).bbox() as AABB).size.x - 0.3) < 1e-3:
					break
				await _tree.process_frame
		check(str(ws.result.get("preview_stops_at", "")) == scale_id and not _waiting_chips().is_empty(), "The reopened Scale should preview with the later features waiting.")
		var before_cancel := history.get_current_action()
		await _cancel()
		check(ws.command == null and not ws.result.has("preview_stops_at") and _waiting_chips().is_empty() and ws.result.errors.is_empty() and _mesh(ball) != null and str(_mesh(ball).digest()) == kept
			and ws.result.bodies.has(later) and history.get_current_action() == before_cancel,
			"Cancel %s should end with the whole timeline rebuilt as it was (stops at '%s'; waiting %s; errors %s)." % ["after a typed 3" if typed != "" else "with nothing changed", ws.result.get("preview_stops_at", ""), _waiting_chips(), ws.result.errors])
	if ws.command != null:
		ws.cancel_command()
	await _undo_to(mark)
	doc = ws.doc
	_nothing_selected()
	await _frames(2)


# --- Warnings, notes and errors the panels are given ----------------------------------------------

## Mass and Interference print every remark their entries carry (also the keys the fix round
## adds: flaws and counts, notes, pairs not worked out), and a long status message wraps.
func _check_warnings_shown() -> void:
	var holes := str(model.get("holes", ""))
	var ball := str(model.get("ball", ""))
	if _mesh(holes) == null or _mesh(ball) == null:
		return
	# Mass of an open mesh body: its warning is in the panel's result, on wrapped rows.
	_select_body(holes)
	ws.run_tool(_tool("mesh.inspect.center_of_mass"))
	await _frames(4)
	if ws.command == null:
		check(false, "Center of Mass should open.")
	else:
		var text := str(ws.panel.info("result"))
		var entry: Dictionary = (ws.command.props.get("bodies", {}) as Dictionary).get(holes, {})
		var label := ws.panel._editors.get("result") as Label
		check(str(entry.get("warning", "")) != "" and text.count(str(entry.get("warning", "?"))) == 1 and label != null and label.autowrap_mode != TextServer.AUTOWRAP_OFF,
			"The mass panel should show the open body's warning once, wrapped (%s)." % text.replace("\n", " / "))
		var said: PackedStringArray = ws.command.remarks({"warning": "W.", "note": ["N1.", "N2."], "flaws": PackedStringArray(["wrong_way", "inside_out", "self_crossing", "no_volume"]),
			"wrong_way_edges": 1, "inside_out_parts": 2, "self_intersections": 1})
		check(said == PackedStringArray(["W.", "N1.", "N2.", "Mesh check: 1 edge facing the wrong way, 2 inside-out parts, 1 place where it crosses itself, no volume."]),
			"Every remark of a mass entry should be printed, the counts in the singular for 1 (%s)." % [said])
		ws.cancel_command()
		await _frames(2)
	# Interference: remarks of every kind of entry.
	_nothing_selected()
	ws.run_tool(_tool("mesh.inspect.interference"))
	await _frames(4)
	if ws.command == null:
		check(false, "Interference should open.")
	else:
		ws.command.clashes = [{"a": ball, "b": holes, "volume": 1e-6, "shape": null, "note": "A note.", "warning": "A warning.", "notes": ["More."]},
			{"a": ball, "b": holes, "note": "Not worked out in time."}]
		ws.command.clashes.append({"a": ball, "b": holes, "volume": 2e-6, "shape": null, "note": "Tessellated. The volume is approximate: within about 3 %.", "approximate": {"within": 6e-8, "percent": 3.0}})
		ws.command.failures = [{"a": ball, "b": holes, "error": "An error.", "note": "Why."},
			{"a": ball, "b": holes, "volume": 0.0, "shape": null, "timed_out": true, "error": "It was not checked: no time was left."}]
		# A pair that nearly touches ("unseen"): a remark under the list, never an interference.
		var near_miss := {"a": ball, "b": holes, "volume": 0.0, "shape": null, "unseen": true, "note": "HookBall was tessellated for Interference. No overlap was found, but the bodies come within about 0.0017 mm of each other: an overlap thinner than that is not seen."}
		ws.command.unseen = [near_miss]
		var with_near: String = ws.command.describe()
		var near_line := with_near.find("HookBall / HookHoles: HookBall was tessellated for Interference. No overlap was found, but")
		check(with_near.contains("2 interferences:") and near_line > with_near.find("no time was left.") and with_near.count("No overlap was found") == 1 and not with_near.contains("\n  HookBall / HookHoles: 0"),
			"A pair that nearly touches should be a remark under the list, not an interference (%s)." % with_near.replace("\n", " / "))
		ws.command.unseen = []
		var lines: String = ws.command.describe()
		check(lines.contains("2 interferences:") and lines.contains("    A note.") and not lines.contains("A note. The volume") and lines.contains("A warning.") and lines.contains("More.")
			and lines.contains("within about 3 %.") and lines.count("The volume is approximate") == 1
			and lines.contains("not checked: Not worked out in time.") and lines.contains("could not be checked: An error.") and lines.contains("Why.")
			and lines.contains("HookHoles: It was not checked: no time was left."),
			"Every note, warning and error of an interference entry should be printed (%s)." % lines.replace("\n", " / "))
		# What the kernel found is sorted: an "unseen" pair is no clash (nothing to make a body
		# from), and alone it reads "No interference found." with its remark.
		ws.command.take([near_miss])
		var alone: String = ws.command.describe()
		check((ws.command.clashes as Array).is_empty() and (ws.command.unseen as Array).size() == 1 and (ws.command.solid_clashes() as Array).is_empty()
			and alone.contains("No interference found.") and not alone.contains("interference:") and alone.contains("an overlap thinner than that is not seen."),
			"An unseen pair alone should read as no interference found, with its remark (%s)." % alone.replace("\n", " / "))
		ws.cancel_command()
		await _frames(2)
	# A file that looks cut off: the reader's warning is in the Insert Mesh prompt, in the status
	# line after the insert and in the feature's chip.
	var whole := FIXTURES.write_stl(FIXTURES.two_cubes(Vector3(0.05, 0.0, 0.0)).first, "hook/whole_text.stl", 1000.0, true)
	var cut_path := ProjectSettings.globalize_path(FIXTURES.DIR + "/hook/cut_off.stl")
	var cut := FileAccess.open(cut_path, FileAccess.WRITE)
	cut.store_string("\n".join(FileAccess.get_file_as_string(whole).split("\n").slice(0, 8)) + "\n")
	cut.close()
	var before_insert := history.get_current_action()
	ws.files._mesh_chosen(cut_path, INSERT.KIND_MESH)
	await _frames(2)
	var prompt: ConfirmationDialog = ws.files._options
	var said_in_prompt := prompt.find_child("Note_warning", true, false) as Label
	check(prompt.visible and said_in_prompt != null and said_in_prompt.text.contains("cut_off.stl") and said_in_prompt.text.contains("cut off") and said_in_prompt.autowrap_mode != TextServer.AUTOWRAP_OFF,
		"The Insert Mesh prompt should show the reader's warning of a file that looks cut off (%s)." % (said_in_prompt.text if said_in_prompt != null else "no note"))
	prompt.get_ok_button().pressed.emit()
	await _frames(5)
	doc = ws.doc
	var cut_feature: Resource = doc.features.back()
	var cut_chip := _chip(str(cut_feature.id))
	check(history.get_current_action() == before_insert + 1 and ws.last_message.begins_with("Inserted cut_off.stl as a mesh body (1 triangle).") and ws.last_message.contains("cut off")
		and cut_chip != null and cut_chip.tooltip_text.contains("Note: ") and cut_chip.tooltip_text.replace("\n", " ").contains("cut off"),
		"The insert's message and the chip's tooltip should carry the reader's warning, with 1 triangle in the singular (%s)." % ws.last_message)
	await _undo_to(before_insert)
	for file in ["hook/whole_text.stl", "hook/cut_off.stl"]:
		FIXTURES.remove_file(file)
	# A whole file gets no note in the prompt.
	var whole_path := ProjectSettings.globalize_path(FIXTURES.write_stl(FIXTURES.holed_blob(), "hook/whole_blob.stl", 1000.0))
	ws.files._mesh_chosen(whole_path, INSERT.KIND_MESH)
	await _frames(2)
	check(ws.files._options.visible and ws.files._options.find_child("Note_warning", true, false) == null, "A whole file should get no warning in the prompt.")
	ws.files._options.hide()
	FIXTURES.remove_file("hook/whole_blob.stl")
	# Direct Edit's stored result: no triangle left is written as "emptied", never as a missing mesh.
	var scratch: Resource = (doc.get_script() as Script).new()
	scratch.restore(doc.snapshot())
	var nothing: RefCounted = ClassDB.instantiate("CadMesh")
	var emptied: Resource = ws.mesh_direct_edit.add_snapshot(scratch, ball, nothing, "digest", PackedStringArray(["delete"]), [nothing])
	check(bool(nothing.is_null()) and emptied != null and emptied.options.get("emptied") == true and not emptied.options.has("mesh") and (emptied.options.get("outputs", [0]) as Array).is_empty()
		and not emptied.options.has("extract_0"), "A Direct Edit that leaves no triangle should be stored as emptied, with no mesh and no empty extracted part (%s)." % [emptied.options.keys() if emptied != null else []])
	var kept: Resource = ws.mesh_direct_edit.add_snapshot(scratch, ball, _mesh(ball), "digest", PackedStringArray(["flip"]), [_mesh(ball), nothing])
	check(kept != null and kept.options.has("mesh") and not kept.options.has("emptied") and (kept.options.get("outputs", []) as Array).size() == 1 and kept.options.has("extract_0") and not kept.options.has("extract_1"),
		"A Direct Edit with triangles should store its mesh and each extracted part that has triangles (%s)." % [kept.options.keys() if kept != null else []])
	# A face group of a mesh body takes an appearance of its own, kept with where it was picked, so
	# it follows the group when the groups are numbered afresh.
	var bracket := str(model.get("bracket", ""))
	if _mesh(bracket) != null:
		await _look_at([bracket])
		var before_look := history.get_current_action()
		var group_pick: Dictionary = ws.viewport.pick_at(_point_on(bracket))
		ws.selection.clear()
		ws.mesh_selection.clear()
		ws.selection.append(group_pick)
		ws._selection_changed(true)
		var look_targets: PackedStringArray = ws.appearance_targets()
		check(str(group_pick.get("kind", "")) == "mesh_group" and look_targets == PackedStringArray([APPEARANCE.face_target(bracket, str(group_pick.get("group", "?")))]),
			"A picked face group of a mesh body should be the target of an appearance (%s; %s)." % [look_targets, group_pick.get("kind", "")])
		var set_count: int = ws.apply_appearance("builtin:paint_blue", look_targets)
		await _frames(3)
		var look: Dictionary = doc.appearances.get(look_targets[0] if look_targets.size() == 1 else "", {})
		var painted: MeshInstance3D = ws.viewport.body_surface(bracket)
		check(set_count == 1 and str(look.get("material", "")) == "builtin:paint_blue" and look.get("at") is Vector3 and (look.at as Vector3).distance_to(group_pick.point) < 1e-9 and look.get("normal") is Vector3
			and painted != null and painted.mesh.get_surface_count() >= 2, "The face group's appearance should be stored with where it was picked, and shown (%s)." % [look])
		# Generate Face Groups names the groups afresh: the appearance stays on a group, and what
		# the appearances say is in the status line.
		_nothing_selected()
		if await _open("mesh:generate_groups", {"bodies": [_pick(bracket)], "algorithm": "fast", "angle": "30"}) != "":
			ws.accept_command()
			await _frames(4)
			painted = ws.viewport.body_surface(bracket)
			ws._status_timer.stop()
			ws._update_status()
			var said_all := true
			for remark in ws.appearance_notes:
				said_all = said_all and str(ws._status.text).contains(str(remark))
			check(ws.command == null and painted != null and (painted.mesh.get_surface_count() >= 2 or not ws.appearance_notes.is_empty()) and said_all,
				"After the groups were numbered afresh the appearance should still show, or a note should say why not (%d surfaces; %s)." % [painted.mesh.get_surface_count() if painted != null else 0, ws.appearance_notes])
		if ws.command != null:
			ws.cancel_command()
		await _undo_to(before_look)
		_nothing_selected()
	# A long message wraps inside the view instead of running off its edge.
	ws.flash("This sentence is long on purpose, to see that the status line of the view wraps. ".repeat(4))
	await _frames(2)
	var status := ws._status as Label
	check(status.get_line_count() > 1 and status.get_visible_line_count() == status.get_line_count() and status.position.x + status.size.x <= ws.viewport.size.x - 100.0,
		"A long status message should wrap inside the view (%d lines, %d shown, %s wide)." % [status.get_line_count(), status.get_visible_line_count(), status.size.x])
	_nothing_selected()


# --- The command panel: clear of the body, its fields and slots -----------------------------------

## A real middle-button drag in the view (it pans).
func _pan(a: Vector2, b: Vector2, steps := 6) -> void:
	_move(a)
	await _tree.process_frame
	_move(a)
	_button(a, true, {"button": MOUSE_BUTTON_MIDDLE})
	for i in range(1, steps + 1):
		_move(a.lerp(b, float(i) / steps), MOUSE_BUTTON_MASK_MIDDLE)
	_button(b, false, {"button": MOUSE_BUTTON_MIDDLE})
	await _frames(3)


## The screen rectangle of a body's bounds, worked out here (not by the workspace).
func _screen_rect(body_id: String) -> Rect2:
	var shape := _shape(body_id)
	if shape == null:
		return Rect2()
	var box: AABB = shape.bbox()
	var rect := Rect2()
	var found := false
	for i in 8:
		var at: Vector2 = ws.viewport.project(box.get_endpoint(i))
		if at.is_finite():
			rect = rect.expand(at) if found else Rect2(at, Vector2.ZERO)
			found = true
	return rect.intersection(Rect2(Vector2.ZERO, ws.viewport.size)) if found else Rect2()


func _panel_rect() -> Rect2:
	return Rect2((ws.panel as Control).position, (ws.panel as Control).size)


## The panel of a Mesh tool keeps off the body the tool works on where the view has room, moves
## off it again when the view is panned under it, always stays inside the view, and works where
## it stands.
func _check_panel_placement() -> void:
	var ball := str(model.get("ball", ""))
	if _mesh(ball) == null:
		return
	_nothing_selected()
	var view := Rect2(Vector2.ZERO, ws.viewport.size)
	# The ball right of the middle, where the panel's own spot is.
	await _look_at([ball], 0.7, -0.5, -0.3)
	var home := Rect2(Vector2(view.size.x - 300.0, 150.0), Vector2(290.0, 200.0))
	check(_screen_rect(ball).intersects(home), "The ball should start under the panel's own spot (%s)." % _screen_rect(ball))
	_select_body(ball)
	ws.run_tool(_tool("mesh.modify.reduce"))
	await _stat(8)
	if ws.command == null:
		check(false, "Reduce should open.")
		return
	var body_rect := _screen_rect(ball)
	check(body_rect.has_area() and not _panel_rect().intersects(body_rect) and view.grow(0.5).encloses(_panel_rect()),
		"Reduce's panel should stand clear of the picked body, inside the view (panel %s, body %s)." % [_panel_rect(), body_rect])
	check(body_rect.is_equal_approx(ws.mesh_tool_rect()), "The workspace should keep off the same rectangle (%s, %s)." % [ws.mesh_tool_rect(), body_rect])
	await _shot("panel_dark_clear_of_body.png")
	# It works where it stands: a value typed there is taken.
	await _type_into("proportion", "40")
	var stat := await _stat(8)
	check(str(ws.command_values.get("proportion", "")) == "40" and (stat.contains("(40.0%)") or stat == ws.command.PREVIEW_SKIPPED), "A value typed into the moved panel should be taken (%s)." % stat.replace("\n", " / "))
	# The view panned with the mouse until the body lies under the panel: the panel moves off it.
	var panel_middle := _panel_rect().get_center()
	var shift := panel_middle.x - body_rect.get_center().x
	var grip := Vector2(view.size.x * 0.5, view.size.y - 110.0)
	await _focus_view()
	await _pan(_g(grip), _g(grip + Vector2(shift, 0.0)))
	await _frames(4)
	body_rect = _screen_rect(ball)
	check(body_rect.has_area() and not _panel_rect().intersects(body_rect) and view.grow(0.5).encloses(_panel_rect()),
		"After the body was panned under it, the panel should stand clear of it again (panel %s, body %s)." % [_panel_rect(), body_rect])
	await _shot("panel_dark_clear_after_pan.png")
	# No room: the body fills the view. The panel stays whole inside the view.
	var box: AABB = _mesh(ball).bbox()
	ws.viewport.set_view_state({"target": box.get_center(), "distance": box.size.length() * 0.45, "yaw": 0.7, "pitch": -0.5})
	await _frames(5)
	check(view.grow(0.5).encloses(_panel_rect()) and _panel_rect().size.y > 150.0 and (ws.panel._ok as Control).is_visible_in_tree(), "With no room beside the body the panel should stay whole inside the view (%s)." % _panel_rect())
	await _shot("panel_dark_no_room.png")
	# The body wide in the upper middle of the view: no side is free, so the panel goes under it,
	# shorter. Its rows scroll then, and the result row stays in sight under them.
	var turned := Basis.from_euler(Vector3(-0.5, 0.7, 0.0))
	# (The view distance that makes the body's rectangle 300 px wide (wide enough to reach under both sides, low enough to leave room under it), from its width at another.)
	ws.viewport.set_view_state({"target": box.get_center(), "distance": box.size.length() * 3.0, "yaw": 0.7, "pitch": -0.5})
	await _frames(2)
	var wide_at_3 := _screen_rect(ball).size.x
	ws.viewport.set_view_state({"target": box.get_center(), "distance": box.size.length() * 3.0 * wide_at_3 / 300.0, "yaw": 0.7, "pitch": -0.5})
	await _frames(2)
	var per_meter: float = ws.viewport.project(box.get_center()).distance_to(ws.viewport.project(box.get_center() + turned.y * 0.01)) / 0.01
	var lift := (_screen_rect(ball).position.y - 55.0) / maxf(per_meter, 1.0)
	ws.viewport.set_view_state({"target": box.get_center() - turned.y * lift, "distance": ws.viewport.distance, "yaw": 0.7, "pitch": -0.5})
	await _frames(6)
	body_rect = _screen_rect(ball)
	var result_row := ws.panel._editors.get("stat") as Label
	var bar: VScrollBar = (ws.panel._scroll as ScrollContainer).get_v_scroll_bar()
	check(body_rect.size.x >= 280.0 and body_rect.size.x <= 320.0 and not _panel_rect().intersects(body_rect) and view.grow(0.5).encloses(_panel_rect()) and _panel_rect().position.y >= body_rect.end.y,
		"With the body wide in the upper middle the panel should go under it (panel %s, body %s)." % [_panel_rect(), body_rect])
	# A tall view can leave room under the body for every row: then nothing needs to scroll.
	var rows := (ws.panel._scroll as ScrollContainer).get_child(0) as Control
	var rows_fit := rows != null and rows.size.y <= (ws.panel._scroll as Control).size.y + 0.5
	check((bar.visible or rows_fit) and result_row != null and result_row.is_visible_in_tree() and result_row.text != ""
		and (ws.panel as Control).get_global_rect().grow(0.5).encloses(result_row.get_global_rect()) and not (ws.panel._scroll as Control).get_global_rect().intersects(result_row.get_global_rect()),
		"In the shorter panel the rows should scroll (unless they fit) and the result row stay in sight under them (panel %s, row %s, scroll bar %s)." % [(ws.panel as Control).get_global_rect(), result_row.get_global_rect() if result_row != null else Rect2(), bar.visible])
	await _shot("panel_dark_under_body_short.png")
	# Cancel, by a click where the panel stands now.
	var cancel := (ws.panel._ok as Control).get_parent().get_child(1) as Button
	await _press(cancel)
	await _frames(2)
	check(ws.command == null, "A click on Cancel in the moved panel should close the tool.")
	if ws.command != null:
		ws.cancel_command()
	_nothing_selected()


## The panel's fields and slots under real input: a dragged arrow shows in the field that has the
## keyboard, a typed value is left alone, and a click on the active slot leaves it active.
func _check_panel_fields() -> void:
	var ball := str(model.get("ball", ""))
	if _mesh(ball) == null:
		return
	await _look_at([ball], 0.7, -0.35, 0.28)
	if await _open("mesh:plane_cut", {"bodies": [_pick(ball)], "plane": [{"kind": "origin", "name": "xz"}]}) == "":
		return
	await _stat(6)
	# Slots: a click makes a slot the active one, alone; a click on the active one leaves it so.
	var bodies := ws.panel._editors["bodies"] as Button
	var plane := ws.panel._editors["plane"] as Button
	await _press(plane)
	check(ws.panel.active_selection_key == "plane" and plane.button_pressed and not bodies.button_pressed, "A click on a slot should make it the only active one (%s)." % ws.panel.active_selection_key)
	await _press(plane)
	await _frames(2)
	check(ws.panel.active_selection_key == "plane" and plane.button_pressed and not bodies.button_pressed, "A click on the active slot should leave it active (%s)." % ws.panel.active_selection_key)
	await _press(bodies)
	check(ws.panel.active_selection_key == "bodies" and bodies.button_pressed and not plane.button_pressed, "A click on another slot should move the active one there (%s)." % ws.panel.active_selection_key)
	await _press(plane)
	# The Offset field has the keyboard, then the arrow is dragged: the field shows the dragged value.
	var offset := ws.panel._editors["offset"] as LineEdit
	await _press(offset)
	check(offset.has_focus(), "The Offset field should have the keyboard.")
	var arrow := {}
	for handle in ws.viewport.handles:
		if str(handle.get("key", "")) == "offset":
			arrow = handle
	check(not arrow.is_empty(), "Plane Cut should show its offset arrow.")
	if not arrow.is_empty():
		var screen: Dictionary = ws.viewport._handle_screen_shape(arrow)
		var from: Vector2 = (screen.from as Vector2).lerp(screen.to, 0.6)
		var along: Vector2 = ((screen.to as Vector2) - (screen.from as Vector2)).normalized()
		await _drag(_g(from), _g(from + along * 40.0))
		await _frames(3)
		var dragged := str(ws.command_values.get("offset", ""))
		# (The press in the view takes the keyboard from the field, so the field is free to show it.)
		check(dragged != "0" and offset.text == dragged and not offset.has_focus(), "The dragged offset should show in the field (field '%s', value '%s')." % [offset.text, dragged])
	# A value set from outside the field shows in it also while it has the keyboard.
	await _press(offset)
	var set_values: Dictionary = ws.command_values.duplicate(true)
	set_values["offset"] = "12"
	ws.set_command_values(set_values)
	await _frames(2)
	check(offset.has_focus() and offset.text == "12" and offset.caret_column == 2, "A value set while the field has the keyboard should show in it (field '%s')." % offset.text)
	# A value being typed is left alone by the rebuilds that follow each key.
	await _press(offset)
	await _key(KEY_A, {"ctrl": true})
	await _type("7.5")
	await _frames(6)
	check(offset.text == "7.5" and str(ws.command_values.get("offset", "")) == "7.5" and offset.has_focus(), "A typed value should stay as typed (field '%s', value '%s')." % [offset.text, ws.command_values.get("offset", "")])
	ws.cancel_command()
	await _frames(2)
	_nothing_selected()


# --- Convert Mesh: a preview, Prismatic, Replace, Organic to a solid and to a Form Body ----------

## Opens a Mesh tool as the toolbar does and puts values in its panel. Returns its feature's id.
func _open(key: String, values: Dictionary) -> String:
	_nothing_selected()
	ws.start_command(FEATURE_COMMAND.new(key))
	await _frames(2)
	if ws.command == null:
		check(false, "%s should open (%s)." % [key, ws.last_message])
		return ""
	var asked: Dictionary = ws.command_values.duplicate(true)
	asked.merge(values, true)
	ws.set_command_values(asked)
	await _frames(4)
	return str(ws.command.feature.id) if ws.command != null else ""


## The B-rep bodies in the model that are not in known (body ids).
func _new_solids(known: Array) -> Array:
	var found := []
	for body_id in ws.result.bodies:
		if not known.has(body_id) and not MESH_BODY.is_mesh(ws.result.bodies[body_id]):
			found.append(str(body_id))
	return found


func _undo_to(mark: int) -> void:
	while history.get_current_action() > mark:
		history.undo()
		await _frames(2)


func _pick(body_id: String) -> Dictionary:
	return {"kind": "body", "body": body_id}


## The kernel report of a feature that worked on one body (core/features/mesh.gd `reports`).
func _body_report(feature_id: String) -> Dictionary:
	var report: Dictionary = MESH_FEATURE.reports.get(feature_id, {})
	var bodies: Variant = report.get("bodies")
	if bodies is Array and (bodies as Array).size() == 1 and bodies[0] is Dictionary:
		var one: Dictionary = bodies[0]
		return one.get("report", one) if one.get("report", one) is Dictionary else one
	return report


func _check_convert_more() -> void:
	if not ResourceLoader.exists(MESH_FEATURE.CONVERT_PATH):
		check(false, "Convert Mesh (core/features/mesh_convert.gd) should be in this build.")
		return
	await _check_convert_preview()
	await _check_convert_prismatic()
	await _check_convert_replace()
	await _check_convert_organic()
	await _check_convert_form_body()
	if ws.command != null:
		ws.cancel_command()
		await _frames(2)


## A convert's preview: a small body shows its solid and its stat line at once; a body over the
## preview's half second says so and waits for OK; Cancel leaves nothing.
func _check_convert_preview() -> void:
	var cube := str(model.get("lone", ""))
	var holes := str(model.get("holes", ""))
	if _mesh(cube) == null or _mesh(holes) == null:
		return
	var known: Array = ws.result.bodies.keys()
	var mark := history.get_current_action()
	var features: int = doc.features.size()
	var feature_id := await _open("mesh:convert_faceted", {"bodies": [_pick(cube)]})
	if feature_id == "":
		return
	await _look_at([cube])
	var stat := await _stat(4)
	var previewed := _new_solids(known)
	var line := str((MESH_FEATURE.reports.get(feature_id, {}) as Dictionary).get("stat", ""))
	check(ws.last_mesh_limit == MESH_FEATURE.PREVIEW_SECONDS and previewed.size() == 1 and ws.tessellations.has(previewed[0]) and doc.body_visible(cube) and not ws.result.errors.has(feature_id),
		"Faceted's preview should show the converted solid beside the mesh body, which hides only on OK (%s; %s)." % [previewed, ws.result.errors.get(feature_id, "")])
	check(line.begins_with("HookLone: a solid of ") and stat.contains("Bodies made: 1") and stat.contains(line) and not ws.panel._ok.disabled,
		"The stat row should show the convert's own line (%s; report '%s')." % [stat.replace("\n", " / "), line])
	await _shot("preview_dark_convert_faceted.png")
	ws.cancel_command()
	await _frames(3)
	check(_new_solids(known).is_empty() and doc.features.size() == features and history.get_current_action() == mark and doc.body_visible(cube), "Cancel should leave no converted body and no undo step.")
	# Over the preview's time (above about 1,650 triangles): skipped, and OK still offered.
	feature_id = await _open("mesh:convert_faceted", {"bodies": [_pick(holes)]})
	if feature_id == "":
		return
	stat = await _stat(4)
	check(stat == ws.command.PREVIEW_SKIPPED and _new_solids(known).is_empty() and not ws.panel._ok.disabled,
		"Faceted's preview of 4,797 triangles should be skipped with OK still offered (%s)." % stat.replace("\n", " / "))
	ws.cancel_command()
	await _frames(3)


## Prismatic on the L-bracket after Generate Face Groups; New Body hides the mesh body once.
func _check_convert_prismatic() -> void:
	var bracket := str(model.get("prism", ""))
	if _mesh(bracket) == null:
		return
	await _look_at([bracket])
	var start := history.get_current_action()
	var volume := float(_mesh(bracket).volume())
	if await _open("mesh:generate_groups", {"bodies": [_pick(bracket)], "algorithm": "accurate"}) == "":
		return
	await _ok()
	check(ws.command == null and int(_mesh(bracket).group_count()) == 9 and str(_mesh(bracket).get_face_names()[0]) == "g0" and _undo_name() == "Forge: Mesh: Generate Face Groups",
		"Generate Face Groups should give the bracket its 9 face groups (%d; %s)." % [int(_mesh(bracket).group_count()), ws.last_message])
	var known: Array = ws.result.bodies.keys()
	var mark := history.get_current_action()
	var feature_id := await _open("mesh:convert_prismatic", {"bodies": [_pick(bracket)], "result": "new_body"})
	if feature_id == "":
		return
	var title: String = ws.command.undo_name()
	var stat := await _stat(4)
	if stat == ws.command.PREVIEW_SKIPPED:
		note("Prismatic's preview did not fit half a second on this run; its stat line was not checked")
	else:
		check(stat.contains("HookPrism: a solid of 9 faces (8 flat, 1 round)") and _new_solids(known).size() == 1, "Prismatic's preview should show the solid and its line (%s)." % stat.replace("\n", " / "))
	await _shot("preview_dark_convert_prismatic.png")
	await _ok()
	var solids := _new_solids(known)
	var solid: RefCounted = _shape(solids[0]) if solids.size() == 1 else null
	check(ws.command == null and solid != null and int(solid.face_count()) == 9 and int(solid.solid_count()) == 1 and absf(float(solid.volume()) - volume) <= 0.005 * volume,
		"Convert Mesh: Prismatic should make one solid of 9 faces with the bracket's volume (%s; %s)." % [solids, ws.last_message])
	check(history.get_current_action() == mark + 1 and _undo_name() == "Forge: " + title and title == "Mesh: Convert Mesh: Prismatic", "It should be one undo step named Mesh: Convert Mesh: Prismatic ('%s')." % _undo_name())
	check(_mesh(bracket) != null and not doc.body_visible(bracket) and solids.size() == 1 and doc.body_visible(solids[0]) and doc.body_name(solids[0]) == "HookPrism Solid",
		"New Body should add HookPrism Solid and hide the mesh body, which stays in the model.")
	check(_chip(feature_id) != null and _chip(feature_id).icon == TIMELINE._icon(str(TIMELINE.ICONS["mesh:convert_prismatic"])), "The timeline should show Prismatic's chip.")
	# Hidden once: shown again from the browser, the mesh body stays shown through a rebuild.
	ws.browser.body_visibility_toggled.emit(bracket)
	await _frames(3)
	ws.recompute()
	await _frames(2)
	check(doc.body_visible(bracket) and _new_solids(known).size() == 1, "The mesh body shown again should stay shown when the design rebuilds.")
	# Undo of the show, then of the convert; redo of the convert.
	await _undo_to(mark)
	check(_new_solids(known).is_empty() and doc.body_visible(bracket) and int(_mesh(bracket).group_count()) == 9, "Undo should take the solid away and show the mesh body.")
	history.redo()
	await _frames(3)
	check(_new_solids(known).size() == 1 and not doc.body_visible(bracket), "Redo should bring the solid back and hide the mesh body again.")
	await _undo_to(start)
	check(_new_solids(known).is_empty() and doc.body_visible(bracket), "Undo should go back to the bracket as it was.")


## Result: Replace takes the mesh body out of the model; undo brings it back.
func _check_convert_replace() -> void:
	var cube := str(model.get("lone", ""))
	if _mesh(cube) == null:
		return
	var known: Array = ws.result.bodies.keys()
	var mark := history.get_current_action()
	var volume := float(_mesh(cube).volume())
	if await _open("mesh:convert_faceted", {"bodies": [_pick(cube)], "result": "replace"}) == "":
		return
	await _ok()
	var solids := _new_solids(known)
	check(ws.command == null and solids.size() == 1 and not ws.result.bodies.has(cube) and ws.browser.body_item(cube) == null and absf(float(_shape(solids[0]).volume()) - volume) <= 1e-4 * volume,
		"Replace should leave the solid in the mesh body's place (%s; %s)." % [solids, ws.last_message])
	check(history.get_current_action() == mark + 1 and _undo_name() == "Forge: Mesh: Convert Mesh: Faceted", "It should be one undo step named Mesh: Convert Mesh: Faceted ('%s')." % _undo_name())
	await _undo_to(mark)
	check(_mesh(cube) != null and doc.body_visible(cube) and _new_solids(known).is_empty(), "Undo should bring the mesh body back.")


## Organic to a solid: its preview waits for OK, 5,000 cage faces are refused by the time estimate,
## 200 make one smooth solid.
func _check_convert_organic() -> void:
	var ball := str(model.get("smooth", ""))
	if _mesh(ball) == null:
		return
	await _look_at([ball])
	var known: Array = ws.result.bodies.keys()
	var mark := history.get_current_action()
	var feature_id := await _open("mesh:convert_organic", {"body": [_pick(ball)], "faces": "200", "output": "brep", "result": "new_body"})
	if feature_id == "":
		return
	var title: String = ws.command.undo_name()
	var stat := await _stat(4)
	check(stat == ws.command.PREVIEW_SKIPPED and not ws.panel._ok.disabled and _new_solids(known).is_empty(), "Organic's preview should wait for OK (%s)." % stat.replace("\n", " / "))
	# 5,000 cage faces: in the field's range, refused by the time estimate at OK.
	var values: Dictionary = ws.command_values.duplicate(true)
	values["faces"] = "5000"
	ws.set_command_values(values, ["faces"])
	await _frames(3)
	check(ws.command.refusal(ws.command_values) == "", "5,000 Target Cage Faces is inside the field's range.")
	ws.accept_command()
	await _frames(3)
	check(ws.command != null and ws.last_message.contains("would take about") and ws.last_message.contains("Lower Target Cage Faces") and _new_solids(known).is_empty() and history.get_current_action() == mark,
		"5,000 cage faces should be refused by the time estimate, with the panel left open (%s)." % ws.last_message)
	if ws.command == null:
		return
	values["faces"] = "200"
	ws.set_command_values(values, ["faces"])
	await _frames(3)
	var started := Time.get_ticks_msec()
	await _ok()
	var took := Time.get_ticks_msec() - started
	var solids := _new_solids(known)
	var solid: RefCounted = _shape(solids[0]) if solids.size() == 1 else null
	var report := _body_report(feature_id)
	var line := str((MESH_FEATURE.reports.get(feature_id, {}) as Dictionary).get("stat", ""))
	check(ws.command == null and solid != null and int(solid.solid_count()) == 1 and not bool(solid.is_surface()) and absf(float(report.get("volume_change", 1.0))) <= 0.02,
		"Convert Mesh: Organic should make one smooth solid of the ball's volume (%s; volume change %s; %s)." % [solids, report.get("volume_change", "?"), ws.last_message])
	check(line.contains("a smooth solid of") and line.contains("from the mesh"), "Its report should carry the stat line (%s)." % line)
	check(history.get_current_action() == mark + 1 and _undo_name() == "Forge: " + title and title.begins_with("Mesh: Convert Mesh: Organic"), "It should be one undo step named after the tool ('%s')." % _undo_name())
	check(not doc.body_visible(ball) and _mesh(ball) != null, "New Body should hide the mesh body.")
	note("Convert Mesh: Organic at 200 cage faces on 5,120 triangles took %d ms from the click on OK: %s" % [took, line])
	await _shot("convert_dark_organic_solid.png")
	await _undo_to(mark)
	check(_new_solids(known).is_empty() and doc.body_visible(ball), "Undo should take the solid away and show the mesh body.")


## Organic with Output: Form Body: OK leaves a Form feature holding the cage, in one undo step.
func _check_convert_form_body() -> void:
	var ball := str(model.get("smooth", ""))
	if _mesh(ball) == null:
		return
	await _look_at([ball])
	var known: Array = ws.result.bodies.keys()
	var mark := history.get_current_action()
	var features: int = doc.features.size()
	var feature_id := await _open("mesh:convert_organic", {"body": [_pick(ball)], "faces": "200", "output": "form_body", "result": "new_body"})
	if feature_id == "":
		return
	var title: String = ws.command.undo_name()
	var at: int = doc.feature_index(feature_id)
	await _ok()
	var forms := []
	var converts := 0
	for feature in doc.features:
		if str(feature.type) == "form":
			forms.append(feature)
		if str(feature.type) == "mesh" and str(feature.options.get("method", "")) == "convert_organic":
			converts += 1
	check(ws.command == null and forms.size() == 1 and converts == 0 and doc.features.size() == features + 1 and doc.feature_index(str(forms[0].id) if forms.size() == 1 else "") == at,
		"OK should leave one Form feature where the convert feature stood (%d forms, %d converts; %s)." % [forms.size(), converts, ws.last_message])
	check(history.get_current_action() == mark + 1 and _undo_name() == "Forge: " + title, "It should be one undo step named after the tool ('%s')." % _undo_name())
	if forms.size() != 1:
		await _undo_to(mark)
		return
	var form: Resource = forms[0]
	var cages: Dictionary = form.options.get("bodies", {})
	var solids := _new_solids(known)
	check(cages.size() == 1 and solids.size() == 1 and cages.has(solids[0]) and str(doc.bodies[solids[0]].get("feature", "")) == str(form.id) and int(_shape(solids[0]).solid_count()) == 1
		and not ws.result.errors.has(form.id), "The Form feature should hold the cage of the converted body, which builds as one solid (%s; %s)." % [solids, ws.result.errors.get(form.id, "")])
	check(not doc.body_visible(ball) and _mesh(ball) != null and ws.last_message.contains("holds the cage of") and ws.last_message.begins_with(str(form.label)),
		"The mesh body should be hidden and the message should name the Form feature (%s)." % ws.last_message)
	check(_chip(str(form.id)) != null, "The timeline should show the Form feature's chip.")
	await _shot("convert_dark_form_body.png")
	# The form opens for sculpting with the cage in it.
	ws.edit_feature(str(form.id))
	await _frames(4)
	var editor: RefCounted = ws.form_editor
	var cage: Dictionary = editor.cage_of(solids[0]) if editor.active and solids.size() == 1 else {}
	check(editor.active and editor.body_ids().has(solids[0] if solids.size() == 1 else "") and not cage.is_empty(), "The Form feature should open in the Form environment with its cage.")
	await _shot("convert_dark_form_cage.png")
	if editor.active:
		editor.end()
		await _frames(3)
	check(not editor.active and ws.workspace == "Mesh" and ws.toolbar.workspace == "Mesh" and not ws.result.errors.has(form.id), "Finishing the form goes back to the Mesh workspace (%s)." % ws.toolbar.workspace)
	await _undo_to(mark)
	check(_new_solids(known).is_empty() and doc.body_visible(ball) and doc.features.size() == features, "Undo should take the form body away and show the mesh body.")
	history.redo()
	await _frames(4)
	check(_new_solids(known).size() == 1 and not doc.body_visible(ball) and doc.features.size() == features + 1 and str(doc.features[at].type) == "form", "Redo should bring the form body back.")
	await _undo_to(mark)


# --- 5.5 #11: themes -----------------------------------------------------------------------------

func _check_themes() -> void:
	for mode in ["light", "dark"]:
		ws.set_theme_mode(mode)
		await _frames(2)
		var p: Dictionary = ws.theme_colors
		var m: Dictionary = ws.viewport.mesh_display.materials
		check(ws.theme_name == mode and m.surface.albedo_color == p.mesh_surface and m.selected.albedo_color == p.mesh_selected and m.hover.albedo_color == p.mesh_hover
			and m.border.albedo_color == p.mesh_group_border and m.boundary.albedo_color == p.mesh_boundary and m.removed.albedo_color == p.mesh_removed
			and m.group_5.albedo_color == p.mesh_group_palette[5], "%s: the mesh materials should take the palette's colours." % mode)


# --- 5.5 #13: team M's in-editor checks ----------------------------------------------------------

func _check_mesh_checks() -> void:
	if ws.command != null:
		ws.cancel_command()
	_nothing_selected()
	var found: Variant = await CHECKS.run(ws)
	doc = ws.doc
	if found is Array:
		for failure in found:
			check(false, str(failure))
	else:
		check(false, "The Mesh checks should give their failures back.")


# --- 5.5 #14: hover on a million triangles -------------------------------------------------------

func _check_performance() -> void:
	var mark := history.get_current_action()
	var grid := ""
	var holder := [""]
	var mesh: RefCounted = FIXTURES.to_mesh(FIXTURES.large_grid(290)).transformed(Transform3D(Basis.IDENTITY, Vector3(3.5, 0.0, 0.0)))
	ws.change("Mesh Hook Grid", func() -> void: holder[0] = _add_mesh(mesh, "HookGrid"))
	doc = ws.doc
	grid = holder[0]
	await _frames(2)
	if _mesh(grid) == null:
		check(false, "The million-triangle body should build (%s)." % [ws.result.errors])
		return
	check(int(_mesh(grid).triangle_count()) == 1009200, "The timing body should have 1,009,200 triangles.")
	await _look_at([grid])
	var spots := _points_on(grid)
	check(spots.size() >= 40, "The timing body should fill the view (%d points)." % spots.size())
	if spots.size() < 40:
		return
	var pick: Dictionary = ws.viewport.pick_at(spots[0])
	check(str(pick.get("body", "")) == grid and str(pick.get("kind", "")).begins_with("mesh_"), "The hover should find the body's face group (%s)." % [pick.get("kind", "")])
	var calibration := func() -> void:
		var x := 0.0
		for i in 200000:
			x += sin(float(i) * 1e-3)
	# A real mouse move over the body: the pick, and the hover's highlight when it changes.
	var step := [0]
	var hover := func() -> void:
		step[0] = (step[0] + 1) % spots.size()
		_move(_g(spots[step[0]]))
	var limit := HOVER_RATIO_LIMIT if DisplayServer.get_name() == "headless" else WINDOWED_HOVER_RATIO_LIMIT
	var by_group := TIMING.compare(hover, calibration, 5, "mesh hover 1M, face groups")
	check(str(ws.viewport._hover.get("body", "")) == grid, "The mouse over the body should hover it (%s)." % [ws.viewport._hover.get("kind", "")])
	# In triangle mode every move lands on another triangle, so the highlight is rebuilt each time.
	ws.run_tool(_tool("mesh.select.select_triangles"))
	await _frames(3)
	var by_triangle := TIMING.compare(hover, calibration, 5, "mesh hover 1M, triangles")
	# (What a move costs without its highlight: the pick alone, for the note.)
	var pick_only := TIMING.compare(func() -> void:
		step[0] = (step[0] + 1) % spots.size()
		ws.viewport.pick_at(spots[step[0]]), calibration, 5, "mesh pick 1M, triangles")
	check(ws.mesh_selection.mode == "triangles" and str(ws.viewport._hover.get("kind", "")) == "mesh_triangle", "In triangle mode the hover is a triangle (%s)." % [ws.viewport._hover.get("kind", "")])
	ws.run_tool(_tool("mesh.select.select_face_groups"))
	await _frames(3)
	check(float(by_group.ratio) <= limit and float(by_triangle.ratio) <= limit,
		"A hover on a million triangles should stay within %s x the calibration (face groups %.2f ms, ratio %.3f; triangles %.2f ms, ratio %.3f; the pick alone %.2f ms)." % [limit, by_group.op, by_group.ratio, by_triangle.op, by_triangle.ratio, pick_only.op])
	note("hover on 1,009,200 triangles: a mouse move takes %.2f ms picking face groups (ratio %.3f) and %.2f ms picking triangles (ratio %.3f; the pick alone %.2f ms), against a calibration of %.2f ms; %d bodies in the view" % [
		by_group.op, by_group.ratio, by_triangle.op, by_triangle.ratio, pick_only.op, by_group.calibration, (ws.result.get("bodies", {}) as Dictionary).size()])
	while history.get_current_action() > mark:
		history.undo()
		await _frames(2)
	await _frames(2)


# --- 5.5 #12: a large stored mesh goes beside the saved scene ------------------------------------

func _check_save_reload() -> void:
	if ws.command != null:
		ws.cancel_command()
	var scene := EditorInterface.get_edited_scene_root()
	var scene_path := scene.scene_file_path
	# Only a copy of the hook's own test scene is written, in the test folder.
	if scene.name != "ForgeEditorTest" or not scene_path.begins_with("res://tests/holo_forge/") or not TMP_SCENE.begins_with("res://tests/holo_forge/"):
		check(false, "The scene shown is %s, not the hook's test scene: nothing is written." % scene_path)
		return
	# Every file of the project as it is before: this part must change nothing outside the test
	# folder, and inside it nothing but its own copy. (It does not save through the editor: a
	# scene save of the editor's also writes every resource marked as edited in whatever scenes
	# are open, and a part's own "save once more" saves the scene shown under its own name.)
	var stamps_before := _project_stamps()
	var own_before := _own_stamps(scene_path)
	var holder := [""]
	var mesh: RefCounted = FIXTURES.to_mesh(FIXTURES.with_noise(FIXTURES.icosphere(0.05, 6), 0.05)).transformed(Transform3D(Basis.IDENTITY, Vector3(-0.4, 0.0, 0.0)))
	ws.change("Mesh Hook Big Blob", func() -> void: holder[0] = _add_mesh(mesh, "HookBig"))
	doc = ws.doc
	await _frames(2)
	var feature: Resource = doc.features.back()
	var stored: Resource = feature.options.get("mesh")
	check(stored != null and stored.is_large() and (stored.data as PackedByteArray).size() >= 256 * 1024, "The stored mesh should be over 256 KB (%d bytes)." % ((stored.data as PackedByteArray).size() if stored != null else 0))
	if stored == null:
		return
	var digest := str(stored.digest)
	var mesh_digest := str(mesh.digest())
	var folder := TMP_SCENE.get_basename() + "_forge"
	var blob_file := "%s_mesh_%s.res" % [str(part.name), digest.substr(0, 16)]
	# What a save of the scene does for a Forge part, done here by hand for the copy: the part's
	# large stored meshes and its baked meshes go into "<copy>_forge" (CadPart.save_mesh_blobs and
	# its mesh files), then the scene is packed and written. The scene shown keeps its own path
	# and its nodes hear of no save, so nothing else is saved anywhere.
	var kept: Array = part.save_mesh_blobs(folder)
	for node in [scene] + scene.find_children("*", "Node3D", true, false):
		if node.get_script() == CAD_PART:
			node._save_meshes(folder)
	var packed_copy := PackedScene.new()
	var packed_ok := packed_copy.pack(scene)
	var saved := ResourceSaver.save(packed_copy, TMP_SCENE) if packed_ok == OK else packed_ok
	check(saved == OK and scene.scene_file_path == scene_path, "The copy of the test scene should be written, the scene shown keeping its path (%s; %s)." % [error_string(saved), scene.scene_file_path])
	var text := FileAccess.get_file_as_string(TMP_SCENE)
	var blobs := []
	var written := DirAccess.get_files_at(folder) if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(folder)) else PackedStringArray()
	for file in written:
		if file.contains("_mesh_") and file.ends_with(".res"):
			blobs.append(file)
	check(blobs == [blob_file] and kept == [folder.path_join(blob_file)] and str(stored.resource_path) == folder.path_join(blob_file),
		"The large stored mesh should be written as one <part>_mesh_<digest>.res beside the copy, and the feature point at it (%s; path %s)." % [blobs, stored.resource_path])
	check(text.contains(folder.path_join(blob_file)) and text.length() < (stored.data as PackedByteArray).size(), "The copy should point at the file and be smaller than the stored mesh alone (%d bytes, the mesh %d)." % [text.length(), (stored.data as PackedByteArray).size()])
	# The copy loads back to the same mesh.
	var packed: PackedScene = ResourceLoader.load(TMP_SCENE, "", ResourceLoader.CACHE_MODE_IGNORE) if FileAccess.file_exists(TMP_SCENE) else null
	var copy: Node = packed.instantiate() if packed != null else null
	var same := false
	if copy != null:
		for node in [copy] + copy.find_children("*", "Node3D", true, false):
			if node.get_script() != CAD_PART or node.get("document") == null:
				continue
			for loaded in node.document.features:
				var blob_copy: Variant = loaded.options.get("mesh")
				if blob_copy is Resource and str(blob_copy.get("digest")) == digest:
					var back: RefCounted = blob_copy.to_mesh()
					same = back != null and str(back.digest()) == mesh_digest
		copy.free()
	check(same, "The saved copy should load back to the same mesh (digest %s)." % digest.substr(0, 16))
	# Without the big mesh again, and the copy and everything written for it deleted.
	ws.delete_feature(str(feature.id))
	await _frames(3)
	check(not ws.result.bodies.has(holder[0]), "The big mesh should be deleted again.")
	for file in written:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(folder.path_join(file)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(folder))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_SCENE))
	# (And what the editor noted down about the copy among its own state files.)
	for file in DirAccess.get_files_at("res://.godot/editor"):
		if file.begins_with(TMP_SCENE.get_file() + "-"):
			DirAccess.remove_absolute(ProjectSettings.globalize_path("res://.godot/editor".path_join(file)))
	check(not FileAccess.file_exists(TMP_SCENE) and not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(folder)) and scene.scene_file_path == scene_path,
		"The copy and its folder should be deleted again, and the test scene still under its own name.")
	# Nothing else was written, rewritten or deleted: not in the project, and not the test scene
	# or the files beside it.
	var stamps_after := _project_stamps()
	var touched := PackedStringArray()
	for path in stamps_after:
		if not stamps_before.has(path) or stamps_before[path] != stamps_after[path]:
			touched.append(path)
	for path in stamps_before:
		if not stamps_after.has(path):
			touched.append(path + " (deleted)")
	check(touched.is_empty(), "This part should touch no file outside the test folder (%d touched: %s)." % [touched.size(), ", ".join(touched.slice(0, 12))])
	var own_after := _own_stamps(scene_path)
	check(own_after == own_before, "The test scene and the files beside it should be as they were (%s -> %s)." % [own_before, own_after])


## The test scene's own file and the files in its "_forge" folder: path -> [modified time, size].
func _own_stamps(scene_path: String) -> Dictionary:
	var stamps := {}
	var folder := scene_path.get_basename() + "_forge"
	var paths := [scene_path]
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(folder)):
		for file in DirAccess.get_files_at(folder):
			paths.append(folder.path_join(file))
	for path in paths:
		var stream := FileAccess.open(path, FileAccess.READ)
		stamps[path] = [FileAccess.get_modified_time(path), stream.get_length() if stream != null else -1]
	return stamps


## Every file of the project outside the hook's own folders: path -> [modified time, size].
func _project_stamps(folder := "res://", into := {}) -> Dictionary:
	var dir := DirAccess.open(folder)
	if dir == null:
		return into
	dir.include_hidden = true
	for file in dir.get_files():
		var path := folder.path_join(file)
		var own := false
		for mine in OWN_FOLDERS:
			own = own or path.begins_with(mine)
		if not own and not NOT_SAVED.has(file.get_extension().to_lower()):
			var stream := FileAccess.open(path, FileAccess.READ)
			into[path] = [FileAccess.get_modified_time(path), stream.get_length() if stream != null else -1]
	for sub in dir.get_directories():
		var below := folder.path_join(sub) + "/"
		var own := false
		for mine in OWN_FOLDERS:
			own = own or below.begins_with(mine)
		if not own and sub != ".git":
			_project_stamps(folder.path_join(sub), into)
	return into


# --- Screenshots ---------------------------------------------------------------------------------

## Saves the Forge view (whole: the whole Forge tab, with the toolbar, browser and timeline).
func _shot(file: String, whole := false) -> void:
	if _shots == "":
		return
	await _frames(3)
	ws.viewport.redraw_overlay()
	EditorInterface.get_base_control().queue_redraw()
	await RenderingServer.frame_post_draw
	var window: Window = EditorInterface.get_base_control().get_window()
	var picture := window.get_texture().get_image()
	var area: Rect2 = (ws as Control).get_global_rect() if whole else (ws.viewport as Control).get_global_rect()
	var rect := Rect2i(area).intersection(Rect2i(Vector2i.ZERO, picture.get_size()))
	picture.get_region(rect).save_png(_shots.path_join(file))
	print("Forge MESH: saved ", _shots.path_join(file))


## One PNG per Mesh tool with its panel open and its preview shown (tool_<theme>_<method>.png).
func _tool_shots(theme: String) -> void:
	var ball := str(model.get("ball", ""))
	var holes := str(model.get("holes", ""))
	var pair := str(model.get("pair", ""))
	var cube := str(model.get("cube", ""))
	var bracket := str(model.get("bracket", ""))
	var plate := str(model.get("plate", ""))
	var solid := str(model.get("solid", ""))
	var lone := str(model.get("lone", ""))
	if _mesh(ball) == null or _mesh(bracket) == null or _mesh(holes) == null:
		return
	var names: PackedStringArray = _mesh(bracket).get_face_names()
	var flat := ""
	for i in names.size():
		if flat == "" and bool((_mesh(bracket).face_info(i) as Dictionary).get("planar", false)):
			flat = names[i]
	var patch: PackedInt32Array = _mesh(ball).grow(PackedInt32Array([0]), 3)
	var body := func(id: String) -> Array: return [{"kind": "body", "body": id}]
	var picked := {"kind": "mesh_triangles", "body": ball, "triangles": patch, "digest": str(_mesh(ball).digest())}
	var plate_groups: PackedStringArray = _mesh(plate).get_face_names() if _mesh(plate) != null else PackedStringArray(["g0"])
	var cases := [
		["tessellate", [solid], {"bodies": body.call(solid)}],
		["section_sketch", [ball], {"body": body.call(ball), "plane": [XY]}],
		["close_holes", [holes], {"bodies": body.call(holes)}],
		["stitch_remove", [pair], {"bodies": body.call(pair)}],
		["wrap", [holes], {"bodies": body.call(holes), "detail": "1.5", "gap": "26", "offset": "0"}],
		["rebuild", [lone], {"bodies": body.call(lone)}],
		["generate_groups", [bracket], {"bodies": body.call(bracket)}],
		["combine_groups", [bracket], {"groups": [{"kind": "mesh_group", "body": bracket, "group": names[0]}, {"kind": "mesh_group", "body": bracket, "group": names[1]}]}],
		["create_group", [ball], {"selection": [picked]}],
		["remesh", [ball], {"bodies": body.call(ball), "edge_length": "8", "iterations": "5"}],
		["reduce", [ball], {"bodies": body.call(ball), "proportion": "50"}],
		["plane_cut", [ball], {"bodies": body.call(ball), "plane": [XY], "offset": "10"}],
		["shell", [ball], {"bodies": body.call(ball), "thickness": "3", "algorithm": "fast"}],
		["combine", [ball, cube], {"target": body.call(ball), "tools": body.call(cube), "operation": "cut"}],
		["smooth", [bracket], {"bodies": body.call(bracket), "iterations": "2"}],
		["reverse_normal", [ball], {"mode": "whole", "bodies": body.call(ball)}],
		["erase_fill", [ball], {"selection": [picked], "fill": "minimal"}],
		["align", [bracket], {"source": [{"kind": "mesh_group", "body": bracket, "group": flat}], "to": [XY]}],
		["texture_extrude", [plate], {"selection": [{"kind": "mesh_group", "body": plate, "group": plate_groups[0]}], "image": image, "depth": "1.5", "tile": "10", "detail": "0.625"}],
		["separate", [pair], {"bodies": body.call(pair)}],
		["move", [ball], {"objects": body.call(ball), "x": "10"}],
		["scale", [ball], {"bodies": body.call(ball), "scale": "1.5"}],
		["convert_faceted", [lone], {"bodies": body.call(lone)}],
		["convert_prismatic", [bracket], {"bodies": body.call(bracket)}],
		["convert_organic", [ball], {"body": body.call(ball)}],
	]
	for case in cases:
		var key := "mesh:" + str(case[0])
		_nothing_selected()
		ws.start_command(FEATURE_COMMAND.new(key))
		await _frames(2)
		if ws.command == null:
			continue
		# (The panel leaves the text of the field that has the keyboard alone, so none has it.)
		await _focus_view()
		var asked: Dictionary = ws.command_values.duplicate(true)
		asked.merge(case[2], true)
		ws.set_command_values(asked)
		await _frames(4)
		await _look_at(case[1], 0.7, -0.5, 0.28)
		await _frames(3)
		await _shot("tool_%s_%s.png" % [theme, case[0]])
		ws.cancel_command()
		await _frames(2)
	await _look_at([blob])


## The light theme's views: a selection, the face group colours, Direct Edit's arrows, the Removed
## and Fill overlays, and the whole tab (timeline chips, the browser's icon).
func _light_shots() -> void:
	_nothing_selected()
	await _look_at([blob])
	await _click(_g(_point_on(blob)))
	await _shot("selection_light_group.png")
	await _focus_view()
	await _key(KEY_ESCAPE)
	await _key(KEY_F, {"shift": true})
	await _shot("face_groups_light.png")
	await _key(KEY_F, {"shift": true})
	await _frames(1)
	# Plane Cut's preview: the removed part and the cap.
	ws.start_command(FEATURE_COMMAND.new("mesh:plane_cut"))
	await _frames(2)
	if ws.command != null:
		var asked: Dictionary = ws.command_values.duplicate(true)
		asked.merge({"bodies": [{"kind": "body", "body": blob}], "plane": [{"kind": "origin", "name": "xz"}], "offset": "25"}, true)
		await _focus_view()
		ws.set_command_values(asked)
		await _frames(5)
		await _shot("preview_light_plane_cut_removed_fill.png")
		ws.cancel_command()
		await _frames(2)
	var holes := str(model.get("holes", ""))
	if _mesh(holes) != null:
		await _look_at([holes])
		ws.start_command(FEATURE_COMMAND.new("mesh:close_holes"))
		await _frames(2)
		if ws.command != null:
			var asked: Dictionary = ws.command_values.duplicate(true)
			asked.merge({"bodies": [{"kind": "body", "body": holes}]}, true)
			ws.set_command_values(asked)
			await _frames(6)
			await _shot("preview_light_close_holes_fill.png")
			ws.cancel_command()
			await _frames(2)
	# Direct Edit: a selection and the Move arrows; cancelled.
	await _look_at([blob])
	_select_body(blob)
	ws.run_action("mesh_direct_edit")
	await _frames(3)
	if ws.mesh_direct_edit.active:
		await _click(_g(_point_on(blob)))
		ws.run_tool(_tool("mesh.select.grow_selection"))
		await _press(ws.mesh_direct_edit.buttons().move)
		await _shot("direct_edit_light_move_arrows.png")
		await _press(ws.mesh_direct_edit.buttons().cancel)
		await _frames(2)
	await _look_at([blob])
	await _shot("workspace_light.png", true)


## The project's settings file must stay as it is through the whole hook: checked after each part,
## so a part that makes the editor write it is named.
func _project_watch(after: String) -> void:
	_step = "the part after " + after
	var stamp := [FileAccess.get_modified_time(PROJECT_FILE), FileAccess.get_md5(PROJECT_FILE)]
	if _project_stamp.is_empty():
		_project_stamp = stamp
	elif stamp != _project_stamp:
		check(false, "The project's settings file was written during %s (%s, same content: %s)." % [after, Time.get_datetime_string_from_unix_time(int(stamp[0])), stamp[1] == _project_stamp[1]])
		_project_stamp = stamp


## Puts the editor window's size back (the editor keeps its window's size in its layout).
## A mouse event from the system, not one the hook pushed (those never come through window_input).
func _on_real_input(event: InputEvent) -> void:
	if event is InputEventMouse:
		_real_events += 1
		_real_last = _step


## How many real mouse events came so far ("" when none): for a failure in a windowed run.
func _real_mouse() -> String:
	return "" if _real_events == 0 else " [the real mouse sent %d event(s) to the window, the last during %s]" % [_real_events, _real_last]


func _restore_window() -> void:
	var window: Window = EditorInterface.get_base_control().get_window()
	if window.window_input.is_connected(_on_real_input):
		window.window_input.disconnect(_on_real_input)
	if _passthrough >= 0:
		window.mouse_passthrough = _passthrough == 1
		_passthrough = -1
	if _window_size != Vector2i.ZERO:
		EditorInterface.get_base_control().get_window().size = _window_size
		_window_size = Vector2i.ZERO
	if _embedding >= 0 and gui != null:
		gui.gui_embed_subwindows = _embedding == 1
		_embedding = -1


func _finish() -> void:
	if DisplayServer.get_name() != "headless":
		print("Forge MESH: the real mouse sent %d event(s) to the window during the run%s" % [_real_events, (", the last during " + _real_last) if _real_events > 0 else ""])
	await _frames(4)
	_restore_window()
	await _frames(2)
	for file in ["hook/holed_blob.stl", "hook/out.obj", "hook/out.step", "hook/checker.png"]:
		FIXTURES.remove_file(file)
	if failures.is_empty() and not (_only.is_empty() and _skip.is_empty()):
		print("PARTIAL Holo Forge MESH EDITOR: %s ran, with no failure. [%s]" % [("only " + ", ".join(_only)) if not _only.is_empty() else ("all but " + ", ".join(_skip)), "; ".join(notes)])
	elif failures.is_empty():
		print("PASS Holo Forge MESH EDITOR: " + PASSED + " [" + "; ".join(notes) + "]")
	else:
		print("FAIL Holo Forge MESH EDITOR: ", failures)
	_tree.quit(0 if failures.is_empty() else 1)
