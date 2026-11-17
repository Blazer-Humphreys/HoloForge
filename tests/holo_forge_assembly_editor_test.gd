@tool
extends RefCounted
## The Assemble tools inside the real editor (Holo Forge Phase 8, spec 5.11). The hook builds its
## own scene, tests/holo_forge/assembly_editor_test.tscn (three CadParts: the lever(), gears() and
## slider_wall() designs of tests/holo_forge_assembly_fixtures.gd, the last without its contact set
## and with contact off), writes it with ResourceSaver only and opens it. Clicks, drags and keys
## are real events pushed into the editor's window (Viewport.push_input):
##   1. J opens the Joint panel with Revolute chosen;
##   2. hovering the Lever's top face beside its hole shows snap candidates, the hovered one grows,
##      a click takes the hole's circle_center; from below, the Base's hole the same way; Offset Z
##      -20, Min -30 and Max 90 are typed (Min and Max turned on by clicks); OK makes Joint1 (the
##      browser's Joints folder lists it, Edit > Undo is "Forge: Joint") and the Lever stays put;
##   3. a right-click on Joint1 in the browser offers Edit, Drive, Rename, Suppress, Delete;
##   4. Drive: a ring handle dragged about 120 degrees stops the Lever at 90 with S-LIMIT in the
##      status row; OK; Ctrl+Z gives 0 back, Ctrl+Y 90 again;
##   5. Gears: a 2:1 Motion Link made in its panel; Gear1 driven to 30 degrees by typing turns
##      Gear2's holder by 60 degrees (1e-5 rad);
##   6. Slider: the Enable Contact Sets button is clicked (it shows pressed); the Wall and the Block
##      are selected in the browser (Ctrl+click), right-click > New Contact Set; the slider driven
##      to 50 mm stops near 10 mm with S-CONTACT-STOP in the status row;
##   7. Motion Study: opened, keys 0 at 0 s and 90 at 2 s put on Joint1 with its buttons, Play;
##      paused past 1 s, the Lever's holder is the frame of that time (1e-6); with Contact ticked on
##      the slider's study the panel says where it stops;
##   8. Extrude shows modelled positions with S-MODELLED-VIEW; Esc poses again;
##   9. a component's ground button in the browser grounds it (its icon changes); Ctrl+Z. (A Tree
##      takes a row button's press from the real cursor, which pushed events don't move: when the
##      click doesn't press it, the point is checked to be over the button and the row's button
##      is pressed by its signal, as the inspect editor hook presses an eye);
##  10. Component Nodes set to RigidBody3D through the Inspector's own property editor: the scene
##      tree has Lever as a RigidBody3D and Joints/Joint1 as a HingeJoint3D;
##  11. a copy of the hook's scene written with ResourceSaver loads back with the same assemblies
##      and the same component poses (the copy is deleted);
##  12. the hook guard (plugin.gd) reports no change outside the hook's folders.
## In a windowed editor the real mouse is let through the window while the hook runs (the user may
## be at the machine) and its events are counted; --holo-forge-screenshots=<dir> saves PNGs of the
## glyphs, handles, Drive, Motion Link, contact, the Motion Study panel and a posed Measure in both
## themes. --holo-forge-assemble-editor-only=joint,drive runs named parts and ends with PARTIAL.
##
## godot --headless --path . --editor -- --holo-forge-assemble-editor-test
## godot --path . --editor -- --holo-forge-assemble-editor-test --holo-forge-screenshots=C:/shots

const CATALOG := preload("res://addons/holo_forge/tools/catalog.gd")
const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const F := preload("res://tests/holo_forge_assembly_fixtures.gd")
const DATA := preload("res://addons/holo_forge/core/assembly/assembly_data.gd")
const XFORM := preload("res://addons/holo_forge/core/assembly/xform64.gd")
const SOLVER := preload("res://addons/holo_forge/core/assembly/solver.gd")
const BROWSER := preload("res://addons/holo_forge/ui/browser.gd")
const DISPLAY := preload("res://addons/holo_forge/ui/assembly_display.gd")
const UNITS := preload("res://addons/holo_forge/core/units.gd")
const SHOTS_ARG := "--holo-forge-screenshots="
const ONLY_ARG := "--holo-forge-assemble-editor-only="
const SCENE := "res://tests/holo_forge/assembly_editor_test.tscn"
const SCENE_NAME := "AssemblyEditorTest"
const COPY := "res://tests/holo_forge/_assembly_hook_copy.tscn"
const PROJECT_FILE := "res://project.godot"
const MM := 0.001
## The headless editor's window is 1024 x 600; the hook gives it this size and puts the old back.
const HEADLESS_SIZE := Vector2i(1920, 1080)
## The view's scale while snap candidates are hovered: the 5 mm hole radius then spans 4 px, so a
## point of the face beside the hole is within the candidates' pick distance of its centre.
const HOVER_PX_PER_MM := 0.8
## Parts of the hook (for --holo-forge-assemble-editor-only).
const PARTS := ["joint", "menu", "drive", "link", "contact", "study", "modelled", "ground", "rigid", "save"]

const PASSED := "J opens Joint with Revolute; hovered snap candidates show and the hovered one grows, clicks take both holes' circle_center; typed Offset, Min and Max; OK makes Joint1 in the browser with the undo name Forge: Joint and the Lever stays put; Joint1's right-click menu has Edit, Drive, Rename, Suppress, Delete; a dragged ring stops at the 90 degree limit with S-LIMIT, Ctrl+Z and Ctrl+Y; a mouse-dragged Motion Link Test slider shows Gear2 at twice Gear1's turn and stores nothing; a 2:1 Motion Link turns Gear2 60 degrees for Gear1's typed 30, and Drive shows a -360..360 slider; the Enable Contact Sets button shows pressed, Ctrl+clicked browser rows make a contact set, a drive stops near 10 mm with S-CONTACT-STOP; Motion Study keys by its buttons, Play and Pause show the frame of the paused time, and a study with Contact says its stop; Extrude shows S-MODELLED-VIEW and Esc poses again; the ground button grounds and Ctrl+Z ungrounds; Component Nodes RigidBody3D set in the Inspector bakes Lever as RigidBody3D and Joints/Joint1 as HingeJoint3D; a saved copy loads back with the same assemblies and poses."

var failures: Array[String] = []
var notes: Array[String] = []
var _tree: SceneTree
var _shots := ""
var _only := PackedStringArray()
var _mouse := Vector2.ZERO
var _window_size := Vector2i.ZERO
var _embedding := -1
var _passthrough := -1
var _real_events := 0
var _real_last := ""
var _step := ""
var _project_stamp := []
var ws
var gui: Viewport
var scene: Node
## The three parts by design name ("lever", "gears", "slider") and what the fixtures made.
var parts := {}
var designs := {}


func check(ok: bool, detail: String) -> void:
	if not ok:
		detail += _real_mouse()
		failures.append(detail)
		push_error(detail)
		print("FAIL: ", detail)


func note(text: String) -> void:
	notes.append(text)
	print("Forge ASSEMBLE: ", text)


func _on(section: String) -> bool:
	return _only.is_empty() or _only.has(section)


func run(plugin: EditorPlugin) -> void:
	_tree = plugin.get_tree()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(SHOTS_ARG):
			_shots = arg.trim_prefix(SHOTS_ARG)
		if arg.begins_with(ONLY_ARG):
			_only = arg.trim_prefix(ONLY_ARG).split(",", false)
	if DisplayServer.get_name() == "headless":
		_shots = ""
	_tree.create_timer(1200.0 if _shots != "" else 600.0).timeout.connect(func() -> void:
		print("FAIL Holo Forge ASSEMBLE EDITOR: timed out ", failures)
		_restore_window()
		_tree.quit(1))
	if _shots != "":
		DirAccess.make_dir_recursive_absolute(_shots)
	if not ClassDB.class_exists("CadShape") or not ClassDB.class_exists("CadMesh"):
		check(false, "The native kernel (CadShape, CadMesh) is needed.")
		_finish()
		return
	_project_watch("start")
	if not _build_scene():
		_finish()
		return
	# The editor hears of the new file before it opens it (else a scan that finds it changed opens
	# it again later, with new nodes).
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
		check(false, "The hook's scene %s should open." % SCENE)
		_finish()
		return
	scene = EditorInterface.get_edited_scene_root()
	for key in ["lever", "gears", "slider"]:
		parts[key] = scene.get_node_or_null(_part_name(key))
	EditorInterface.set_main_screen_editor("Forge")
	if DisplayServer.get_name() == "headless":
		var window: Window = EditorInterface.get_base_control().get_window()
		_window_size = window.size
		window.size = HEADLESS_SIZE
	await _frames(5)
	ws = plugin.get("workspace")
	if ws == null or ws.kernel == null:
		check(false, "The Forge workspace with its kernel is needed.")
		_finish()
		return
	ws.theme_store = {}
	ws.set_theme_mode("dark")
	ws.toolbar.pin_store = {}
	gui = ws.viewport.get_viewport()
	if DisplayServer.get_name() != "headless":
		# As the Phase 7 mesh hook: the editor goes by the events' own positions (embedded
		# windows), the system's mouse events are counted, and the real mouse goes through the
		# window to whatever is under it, so the user at the machine can't take the keyboard or a
		# control's mouse focus from the hook. All put back when it ends.
		_embedding = 1 if gui.gui_embed_subwindows else 0
		gui.gui_embed_subwindows = true
		var window: Window = EditorInterface.get_base_control().get_window()
		if not window.window_input.is_connected(_on_real_input):
			window.window_input.connect(_on_real_input)
		_passthrough = 1 if window.mouse_passthrough else 0
		window.mouse_passthrough = true
	if not await _edit("lever"):
		_finish()
		return
	_project_watch("open")
	# (Joint1 is what the later parts work with: the joint part always runs.)
	await _check_joint()
	_project_watch("check_joint")
	if _on("menu"):
		await _check_joint_menu()
		_project_watch("check_joint_menu")
	if _on("drive"):
		await _check_drive()
		_project_watch("check_drive")
	if _on("link"):
		await _check_link()
		_project_watch("check_link")
	if _on("contact"):
		await _check_contact()
		_project_watch("check_contact")
	if _on("study"):
		await _check_study()
		_project_watch("check_study")
	if _on("modelled"):
		await _check_modelled_view()
		_project_watch("check_modelled_view")
	if _on("ground"):
		await _check_ground_button()
		_project_watch("check_ground_button")
	if _shots != "":
		await _tour("dark")
		ws.set_theme_mode("light")
		await _frames(3)
		await _tour("light")
		ws.set_theme_mode("dark")
		await _frames(2)
		_project_watch("screenshots")
	if _on("rigid"):
		await _check_rigid_bake()
		_project_watch("check_rigid_bake")
	if _on("save"):
		await _check_save_copy()
		_project_watch("check_save_copy")
	_finish()


# --- The hook's scene ----------------------------------------------------------------------------

static func _part_name(key: String) -> String:
	return {"lever": "LeverPart", "gears": "GearsPart", "slider": "SliderPart"}[key]


## Builds tests/holo_forge/assembly_editor_test.tscn from the fixtures and writes it with
## ResourceSaver (never through the editor).
func _build_scene() -> bool:
	if not SCENE.begins_with("res://tests/holo_forge/"):
		return false
	var root := Node3D.new()
	root.name = SCENE_NAME
	designs["lever"] = F.lever()
	designs["gears"] = F.gears()
	var slider := F.slider_wall()
	# Contact is made in the hook (6): the slider starts without its set and with contact off.
	var assembly: Dictionary = DATA.normalized(slider.doc.assembly)
	assembly.contact["enabled"] = false
	assembly["contact_sets"] = []
	slider.doc.assembly = assembly
	designs["slider"] = slider
	for key in ["lever", "gears", "slider"]:
		var part: Node3D = CAD_PART.new()
		part.name = _part_name(key)
		part.document = designs[key].doc
		root.add_child(part)
		part.owner = root
	# Apart from each other in the scene.
	root.get_node(_part_name("gears")).position = Vector3(0.0, 0.25, 0.0)
	root.get_node(_part_name("slider")).position = Vector3(0.0, -0.25, 0.0)
	var packed := PackedScene.new()
	var packed_ok := packed.pack(root)
	var saved := ResourceSaver.save(packed, SCENE) if packed_ok == OK else packed_ok
	root.free()
	check(saved == OK, "The hook's scene should be written (%s)." % error_string(saved))
	return saved == OK


## Makes a part the one the Forge edits, as selecting it in the scene tree does.
func _edit(key: String) -> bool:
	# (The parts are looked up in the scene shown each time: the editor may have opened it again.)
	var root := EditorInterface.get_edited_scene_root()
	if root != null and root.name == SCENE_NAME:
		scene = root
		for name in ["lever", "gears", "slider"]:
			parts[name] = root.get_node_or_null(_part_name(name))
	var part: Node3D = parts.get(key)
	if part == null or not part.is_inside_tree():
		check(false, "The scene should hold %s (shown: %s, %s)." % [_part_name(key), root.name if root != null else "none", root.scene_file_path if root != null else ""])
		return false
	if ws.command != null:
		ws.cancel_command()
	if ws.motion_study_panel != null and ws.motion_study_panel.visible:
		ws.motion_study_panel.close()
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(part)
	for i in 60:
		await _tree.process_frame
		if ws.part == part and ws.doc != null and not (ws.result.get("bodies", {}) as Dictionary).is_empty():
			break
	check(ws.part == part, "Selecting %s should make it the Forge's part." % part.name)
	await _frames(3)
	return ws.part == part


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
	event.ctrl_pressed = bool(opts.get("ctrl", false))
	event.button_mask = (MOUSE_BUTTON_MASK_RIGHT if event.button_index == MOUSE_BUTTON_RIGHT else MOUSE_BUTTON_MASK_LEFT) if pressed else 0
	_mouse = at
	gui.push_input(event, true)


func _move(to: Vector2, mask := 0) -> void:
	gui.notification(Node.NOTIFICATION_VP_MOUSE_ENTER)
	var event := InputEventMouseMotion.new()
	event.position = to
	event.global_position = to
	event.relative = to - _mouse
	event.button_mask = mask
	_mouse = to
	gui.push_input(event, true)


func _tap(at: Vector2, opts := {}) -> void:
	_move(at)
	_button(at, true, opts)
	_button(at, false, opts)


func _click(at: Vector2, opts := {}) -> void:
	_move(at)
	await _tree.process_frame
	_tap(at, opts)
	await _tree.process_frame


## A real click on a control, where it is when the button goes down.
func _press(control: Control, opts := {}) -> void:
	if control == null or not control.is_visible_in_tree():
		check(false, "A control to click is missing or hidden (%s)." % [control])
		return
	# (A panel's rows scroll in a short view, as a windowed editor's can be: scrolled to, as the
	# user would.)
	var holder := control.get_parent()
	while holder != null and not holder is ScrollContainer:
		holder = holder.get_parent()
	if holder != null:
		(holder as ScrollContainer).ensure_control_visible(control)
		await _frames(2)
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
			gui.push_input(event)
			await _tree.process_frame


## Clicks into a panel field, selects what it holds and types text over it.
func _type_into(key: String, text: String) -> void:
	var field := ws.panel._editors.get(key) as LineEdit
	if field == null or not field.is_visible_in_tree():
		check(false, "The %s field should be in the panel." % key)
		return
	await _press(field)
	check(field.has_focus(), "A click on the %s field should give it the keyboard (at %s, field %s, window %s, hovered %s, focus %s, windows %s%s)." % [key, _center(field), field.get_global_rect(), EditorInterface.get_base_control().get_window().size, gui.gui_get_hovered_control(), gui.gui_get_focus_owner(), _open_windows(), _real_mouse()])
	await _key(KEY_A, {"ctrl": true})
	await _type(text)
	await _frames(3)


## Ctrl held while a click goes in (the browser reads it from Input, as the real keyboard sets
## it): the key goes through Input.parse_input_event, the click through the window.
func _ctrl_click(at: Vector2) -> void:
	var down := InputEventKey.new()
	down.keycode = KEY_CTRL
	down.physical_keycode = KEY_CTRL
	down.pressed = true
	Input.parse_input_event(down)
	await _tree.process_frame
	await _click(at, {"ctrl": true})
	var up := InputEventKey.new()
	up.keycode = KEY_CTRL
	up.physical_keycode = KEY_CTRL
	up.pressed = false
	Input.parse_input_event(up)
	await _tree.process_frame


func _focus_view() -> void:
	ws.viewport.focus_view()
	await _tree.process_frame


func _press_ok() -> void:
	var ok_button: Button = ws.panel.get("_ok")
	await _press(ok_button)
	await _frames(3)


## A real mouse drag of a slider's grabber: down where the grabber is, along by fraction of the
## slider's width in a few moves (the button held), up.
func _drag_slider(bar: HSlider, fraction: float) -> void:
	var holder := bar.get_parent()
	while holder != null and not holder is ScrollContainer:
		holder = holder.get_parent()
	if holder != null:
		(holder as ScrollContainer).ensure_control_visible(bar)
		await _frames(2)
	var rect := bar.get_global_rect()
	var at := Vector2(rect.position.x + rect.size.x * float(bar.get_as_ratio()), rect.get_center().y)
	_move(at)
	await _frames(1)
	_button(at, true)
	await _frames(1)
	for i in 4:
		_move(at + Vector2(rect.size.x * fraction * float(i + 1) / 4.0, 0.0), MOUSE_BUTTON_MASK_LEFT)
		await _frames(2)
	_button(at + Vector2(rect.size.x * fraction, 0.0), false)
	await _frames(3)


# --- Helpers -------------------------------------------------------------------------------------

func _undo_name() -> String:
	var history: UndoRedo = ws.history()
	return history.get_current_action_name() if history != null else ""


func _assembly() -> Dictionary:
	return DATA.normalized(ws.doc.assembly) if ws.doc != null else {}


func _joint_named(name: String) -> Dictionary:
	for joint in _assembly().get("joints", []):
		if joint is Dictionary and str(joint.get("name", "")) == name:
			return joint
	return {}


func _status() -> String:
	return str(ws.panel.info("status")) if ws.panel != null else ""


## Points the view at a part-space point from a direction (pitch < 0: from above), distance in m.
func _look(target: Vector3, yaw: float, pitch: float, distance: float) -> void:
	ws.viewport.set_view_state({"target": target, "distance": distance, "yaw": yaw, "pitch": pitch})
	await _frames(3)


## Sets the view's distance so that px_per_mm is the scale at target.
func _scale_view(target: Vector3, yaw: float, pitch: float, px_per_mm: float) -> void:
	var distance := 0.3
	for i in 3:
		await _look(target, yaw, pitch, distance)
		var a: Vector2 = ws.viewport.project(target)
		var right := Basis.from_euler(Vector3(pitch, yaw, 0.0)).x
		var b: Vector2 = ws.viewport.project(target + right * 10.0 * MM)
		var shown := a.distance_to(b) / 10.0
		if shown <= 0.0 or not is_finite(shown):
			return
		distance *= shown / px_per_mm


## Hovers the face of body beside a circle's centre (part space) until its circle_center candidate
## is the hovered one; returns the view point (INF when none was found).
func _hover_circle(body_id: String, centers: Array, view_center: Vector3, yaw: float, pitch: float) -> Dictionary:
	for scale in [HOVER_PX_PER_MM, 0.5, 0.35]:
		await _scale_view(view_center, yaw, pitch, scale)
		for center: Vector3 in centers:
			var at: Vector2 = await _hover_circle_at(body_id, center, 5.0 * scale)
			if at.is_finite():
				return {"at": at, "center": center}
	return {}


## Hovers beside one circle centre at the view's scale (the hole's radius is hole_px on screen).
func _hover_circle_at(body_id: String, center: Vector3, hole_px: float) -> Vector2:
	var c: Vector2 = ws.viewport.project(ws.viewport.world_point(body_id, center))
	var hits := 0
	var seen := {}
	for r in [hole_px + 1.5, hole_px + 2.5, hole_px + 3.3, hole_px + 0.9]:
		if r >= DISPLAY.PICK_PX:
			continue
		for k in 24:
			var p: Vector2 = c + Vector2.from_angle(TAU * float(k) / 24.0) * r
			var hit: Dictionary = ws.viewport.face_hit_at(p)
			if str(hit.get("body", "")) != body_id:
				continue
			hits += 1
			_move(_g(p))
			await _frames(2)
			var cmd = ws.command
			if cmd == null:
				return Vector2.INF
			var hovered: int = cmd.get("_hovered")
			var candidates: Array = cmd.get("_candidates")
			var listed := PackedStringArray()
			for candidate in candidates:
				var cf: PackedFloat64Array = candidate.frame
				listed.append("%s@(%.4f,%.4f,%.4f)" % [candidate.kind, cf[9] / MM, cf[10] / MM, cf[11] / MM])
			seen["face %s: hovered %d (%s) of %s" % [hit.get("face", -1), hovered, str(candidates[hovered].kind) if hovered >= 0 and hovered < candidates.size() else "-", " ".join(listed)]] = true
			if hovered >= 0 and hovered < candidates.size() and str(candidates[hovered].kind) == "circle_center":
				var frame: PackedFloat64Array = candidates[hovered].frame
				if Vector3(frame[9], frame[10], frame[11]).distance_to(center) < 1e-6:
					return p
	var direct := InputEventMouseMotion.new()
	direct.position = c + Vector2(6.0, 0.0)
	var used: bool = ws.command.handle_mouse(direct) if ws.command != null else false
	var after: Array = ws.command.get("_candidates") if ws.command != null else []
	print("Forge ASSEMBLE: (no circle_center hovered) on %s near %s: centre at %s in a %s view, %d face hits, seen %s, slot %s, field %s, hovered control %s, a direct call: %s with %d candidates" % [body_id, center, c, (ws.viewport as Control).size, hits, seen.keys(), ws.panel.active_selection_key, ws.panel.active_field(), gui.gui_get_hovered_control(), used, after.size()])
	return Vector2.INF


## The display's candidate marks ({"px", ...}) as drawn now.
func _marks() -> Array:
	return ws.assembly_display.get("_candidates")


## A browser row's point in the window (the middle of its text, or one of its buttons).
func _row_point(item: TreeItem, button_id := -1) -> Vector2:
	var tree: Tree = ws.browser
	tree.scroll_to_item(item)
	var rect: Rect2
	if button_id >= 0:
		rect = tree.get_item_area_rect(item, 0, item.get_button_by_id(0, button_id))
	else:
		rect = tree.get_item_area_rect(item, 0)
	if button_id >= 0:
		return tree.global_position + rect.get_center()
	return tree.global_position + rect.position + Vector2(minf(60.0, rect.size.x * 0.5), rect.size.y * 0.5)


func _joint_item(joint_id: String) -> TreeItem:
	var tree: Tree = ws.browser
	var item: TreeItem = tree.get_root()
	while item != null:
		var meta: Variant = item.get_metadata(0)
		if meta is Dictionary and str(meta.get("type", "")) == "joint" and str(meta.get("id", "")) == joint_id:
			return item
		item = item.get_next_in_tree()
	return null


func _component_item(component_id: String) -> TreeItem:
	var tree: Tree = ws.browser
	var item: TreeItem = tree.get_root()
	while item != null:
		var meta: Variant = item.get_metadata(0)
		if meta is Dictionary and str(meta.get("type", "")) == "component" and str(meta.get("id", "")) == component_id:
			return item
		item = item.get_next_in_tree()
	return null


## Opens every collapsed folder of the browser (Joints starts collapsed).
func _expand_browser() -> void:
	var tree: Tree = ws.browser
	var item: TreeItem = tree.get_root()
	while item != null:
		item.collapsed = false
		item = item.get_next_in_tree()
	await _frames(2)


## Right-clicks a browser row; returns the menu's item texts (the menu stays open).
func _right_click_row(item: TreeItem) -> PackedStringArray:
	await _click(_row_point(item), {"button": MOUSE_BUTTON_RIGHT})
	await _frames(2)
	var menu: PopupMenu = ws.browser.get("_context")
	var texts := PackedStringArray()
	if menu != null and menu.visible:
		for i in menu.item_count:
			if not menu.is_item_separator(i):
				texts.append(menu.get_item_text(i))
	return texts


## Chooses an item of the open browser menu by its text (the menu is a window of its own: its
## entry is chosen as a click on it does).
func _choose(text: String) -> bool:
	var menu: PopupMenu = ws.browser.get("_context")
	if menu == null:
		return false
	for i in menu.item_count:
		if menu.get_item_text(i) == text and not menu.is_item_disabled(i):
			menu.id_pressed.emit(menu.get_item_id(i))
			menu.hide()
			await _frames(3)
			return true
	menu.hide()
	return false


## Picks an option of an enum row by its value, as choosing it in the list does.
func _choose_option(key: String, value: String) -> bool:
	var option := ws.panel._editors.get(key) as OptionButton
	if option == null:
		return false
	for i in option.item_count:
		if str(option.get_item_metadata(i)) == value:
			option.select(i)
			option.item_selected.emit(i)
			await _frames(3)
			return true
	return false


## The turn of a holder about Z (radians).
static func _turn_z(t: Transform3D) -> float:
	return atan2(t.basis.x.y, t.basis.x.x)


# --- 1, 2: Joint ---------------------------------------------------------------------------------

func _check_joint() -> void:
	var f: Dictionary = designs.lever
	var lever_body: String = f.bodies.Lever
	var base_body: String = f.bodies.Base
	var before: Transform3D = ws.viewport.body_pose(lever_body)
	await _look(Vector3(0.04, 0.0, 0.01), 0.6, -0.6, 0.35)
	await _focus_view()
	await _key(KEY_J)
	await _frames(3)
	check(ws.command != null and str(ws.command.type) == "assemble:joint" and str(ws.command_values.get("type", "")) == "revolute", "J should open Joint with Revolute chosen.")
	if ws.command == null:
		return
	# 2. The Lever's top face beside its hole, from above.
	var found: Dictionary = await _hover_circle(lever_body, [Vector3(0.0, 0.0, 20.0 * MM)], Vector3(0.0, 0.0, 0.02), 0.4, -1.25)
	check(not found.is_empty(), "Hovering the Lever's top face beside its hole should offer its circle_center.")
	if found.is_empty():
		return
	var at: Vector2 = found.at
	var marks := _marks()
	var hovered: int = ws.command.get("_hovered")
	check(marks.size() > 1 and hovered >= 0 and float(marks[hovered].px) == DISPLAY.CANDIDATE_HOVER_PX and float(marks[(hovered + 1) % marks.size()].px) == DISPLAY.CANDIDATE_PX,
		"The candidates should show and the hovered one grow (%d marks)." % marks.size())
	if _shots != "":
		await _shot("joint_dark_candidates.png")
	_tap(_g(at))
	await _frames(3)
	var a: Array = ws.command_values.get("a", [])
	check(a.size() == 1 and str((a[0] as Dictionary).get("kind", "")) == "snap" and str(a[0].snap.kind) == "circle_center" and str(a[0].body) == lever_body,
		"The click should take the Lever's circle_center (%s)." % [a])
	# The Base's hole: its top circle (seen past the Lever) or its bottom one.
	found = await _hover_circle(base_body, [Vector3(0.0, 0.0, 10.0 * MM), Vector3.ZERO], Vector3.ZERO, 0.4, 1.25)
	check(not found.is_empty(), "Hovering the Base beside its hole should offer its circle_center.")
	if not found.is_empty():
		_tap(_g(found.at))
		await _frames(3)
	var b: Array = ws.command_values.get("b", [])
	check(b.size() == 1 and str(b[0].get("kind", "")) == "snap" and str(b[0].snap.kind) == "circle_center" and str(b[0].body) == base_body,
		"The second click should take the Base's circle_center (%s)." % [b])
	_move(_g(Vector2(5, 5)))
	await _look(Vector3(0.04, 0.0, 0.01), 0.6, -0.6, 0.35)
	# Offset Z (and Flip for the top circle, whose frame faces the Lever's) puts the Lever back
	# where it is modelled: the frames are 20 mm (bottom) or 10 mm (top) apart.
	var top := not found.is_empty() and (found.center as Vector3).z > 0.0
	if top:
		await _press(ws.panel._editors.get("flip"))
		await _frames(2)
	await _type_into("offset_z", "10" if top else "-20")
	await _press(ws.panel._editors.get("dof0_limited_min"))
	await _frames(2)
	await _type_into("dof0_min", "-30")
	await _press(ws.panel._editors.get("dof0_limited_max"))
	await _frames(2)
	await _type_into("dof0_max", "90")
	check(_status() == "" or not _status().begins_with("Pick"), "Nothing should be waiting before OK (%s)." % _status())
	await _press_ok()
	var joint := _joint_named("Joint1")
	check(ws.command == null and not joint.is_empty(), "OK should make Joint1 (%s)." % _status())
	if joint.is_empty():
		return
	var dof: Dictionary = joint.dofs[0]
	check(bool(dof.limited_min) and bool(dof.limited_max) and absf(float(dof.min) + deg_to_rad(30.0)) < 1e-9 and absf(float(dof.max) - deg_to_rad(90.0)) < 1e-9,
		"Joint1's typed limits should be -30 and 90 degrees (%s, %s)." % [dof.min, dof.max])
	check(_undo_name() == "Forge: Joint", "Edit > Undo should read Forge: Joint (%s)." % _undo_name())
	check(ws.viewport.body_pose(lever_body).is_equal_approx(before), "The Lever should stay where it is modelled.")
	await _expand_browser()
	check(_joint_item(str(joint.id)) != null, "The browser's Joints folder should list Joint1.")


# --- 3: the joint's menu -------------------------------------------------------------------------

func _check_joint_menu() -> void:
	var joint := _joint_named("Joint1")
	if joint.is_empty():
		check(false, "Joint1 is needed for its menu.")
		return
	await _expand_browser()
	var item := _joint_item(str(joint.id))
	if item == null:
		check(false, "Joint1 should be in the browser.")
		return
	var texts := await _right_click_row(item)
	check(texts == PackedStringArray(["Edit", "Drive", "Rename", "Suppress", "Delete"]), "Joint1's right-click menu should be Edit, Drive, Rename, Suppress, Delete (%s)." % [texts])
	var menu: PopupMenu = ws.browser.get("_context")
	if menu != null:
		menu.hide()
	await _frames(2)


# --- 4: Drive ------------------------------------------------------------------------------------

func _check_drive() -> void:
	var joint := _joint_named("Joint1")
	if joint.is_empty():
		check(false, "Joint1 is needed to drive.")
		return
	var lever_body: String = designs.lever.bodies.Lever
	await _expand_browser()
	var item := _joint_item(str(joint.id))
	if item != null:
		await _right_click_row(item)
		check(await _choose("Drive"), "The menu's Drive should open Drive Joints.")
	check(ws.command != null and str(ws.command.type) == "assemble:drive", "Drive Joints should be open.")
	if ws.command == null:
		return
	await _look(Vector3(0.0, 0.0, 0.015), 0.0, -1.5, 0.3)
	await _frames(3)
	var handles: Array = ws.viewport.get("handles")
	var ring := {}
	for handle in handles:
		if str(handle.get("type", "")) == "ring":
			ring = handle
	check(not ring.is_empty(), "Drive should show a ring handle (%d handles)." % handles.size())
	if ring.is_empty():
		return
	var shape: Dictionary = ws.viewport.call("_handle_screen_shape", ring)
	var points: PackedVector2Array = shape.get("points", PackedVector2Array())
	if points.size() < 20:
		check(false, "The ring's outline should be on screen.")
		return
	if _shots != "":
		await _shot("drive_dark_ring.png")
	# About 120 degrees along the ring (48 segments: 16 of them), pressed on its outline.
	_move(_g(points[0]))
	await _tree.process_frame
	_button(_g(points[0]), true)
	for i in range(1, 17):
		_move(_g(points[i]), MOUSE_BUTTON_MASK_LEFT)
		await _tree.process_frame
	if _shots != "":
		await _shot("drive_dark_dragging.png")
	_button(_g(points[16]), false)
	await _frames(4)
	var expected := DATA.fill(DATA.S_LIMIT, {"Joint": "Joint1", "limit": "90°", "target": "@"}).split("@")[0]
	check(_status().contains(expected), "The status row should say S-LIMIT at 90 degrees (%s)." % _status())
	var turned := _turn_z(ws.viewport.body_pose(lever_body))
	check(absf(absf(turned) - deg_to_rad(90.0)) < 1e-6, "The Lever should stop at 90 degrees (%s)." % rad_to_deg(turned))
	await _press_ok()
	var value := float(_joint_named("Joint1").dofs[0].value)
	check(absf(value - deg_to_rad(90.0)) < 1e-9 and _undo_name() == "Forge: Drive Joint1", "OK should store 90 degrees as Drive Joint1 (%s, %s)." % [rad_to_deg(value), _undo_name()])
	await _focus_view()
	await _key(KEY_Z, {"ctrl": true})
	await _frames(3)
	check(absf(float(_joint_named("Joint1").dofs[0].value)) < 1e-12 and absf(_turn_z(ws.viewport.body_pose(lever_body))) < 1e-6, "Ctrl+Z should give 0 degrees back.")
	await _key(KEY_Y, {"ctrl": true})
	await _frames(3)
	if absf(float(_joint_named("Joint1").dofs[0].value) - deg_to_rad(90.0)) > 1e-9:
		# (Redo is Ctrl+Shift+Z where the editor's settings say so.)
		await _key(KEY_Z, {"ctrl": true, "shift": true})
		await _frames(3)
	check(absf(float(_joint_named("Joint1").dofs[0].value) - deg_to_rad(90.0)) < 1e-9 and absf(absf(_turn_z(ws.viewport.body_pose(lever_body))) - deg_to_rad(90.0)) < 1e-6, "Ctrl+Y should give 90 degrees again.")


# --- 5: Motion Link ------------------------------------------------------------------------------

func _check_link() -> void:
	if not await _edit("gears"):
		return
	var f: Dictionary = designs.gears
	var j1: String = f.joints.Joint1
	var j2: String = f.joints.Joint2
	var gear2: String = f.bodies.Gear2
	await _look(Vector3(0.015, 0.0, 0.015), 0.5, -0.9, 0.25)
	ws.run_tool(CATALOG.find("solid.assemble.motion_link"))
	await _frames(3)
	check(ws.command != null and str(ws.command.type) == "assemble:motion_link", "Motion Link should open.")
	if ws.command == null:
		return
	check(await _choose_option("driver", j1 + "|0") and await _choose_option("follower", j2 + "|0"), "The panel's Driver and Follower should list the gears.")
	await _type_into("ratio", "2")
	check(_status() == "", "A 2:1 link is fine (%s)." % _status())
	# The Test slider, dragged with the mouse: Gear2 follows at twice the turn, view-only.
	var stored_pose: Transform3D = ws.viewport.body_pose(gear2)
	var test_bar := ws.panel.slider("test") as HSlider
	check(test_bar != null and test_bar.is_visible_in_tree(), "Motion Link should show a Test slider.")
	if test_bar != null and test_bar.is_visible_in_tree():
		await _drag_slider(test_bar, 0.15)
		var shown: PackedFloat64Array = ((ws.command.preview.get("joints", {}) as Dictionary).get(j2, {}) as Dictionary).get("values", PackedFloat64Array())
		var tried := deg_to_rad(test_bar.value)
		check(test_bar.value > 1.0 and shown.size() == 1 and absf(shown[0] - 2.0 * tried) < 1e-9, "Dragging Test to %s° should show Gear2 at twice that (%s)." % [test_bar.value, str(shown)])
		check(str(ws.command_values.get("test", "")) == UNITS.format_value(tried, "angle", ws.doc.units, 1), "The Test field should say where the slider is (%s)." % ws.command_values.get("test", ""))
		check(not ws.viewport.body_pose(gear2).is_equal_approx(stored_pose), "The Test drag should turn Gear2 in the view.")
	if _shots != "":
		await _shot("link_dark_panel.png")
	await _press_ok()
	var links: Array = _assembly().links
	check(ws.command == null and links.size() == 1 and float(links[0].ratio) == 2.0 and _undo_name() == "Forge: Motion Link", "OK should make the 2:1 link (%d, %s)." % [links.size(), _undo_name()])
	check(ws.viewport.body_pose(gear2).is_equal_approx(stored_pose), "After OK Gear2 should be back where it is stored (Test is view-only).")
	var before := _turn_z(ws.viewport.body_pose(gear2))
	ws.drive_joint(j1)
	await _frames(3)
	var drive_bar := ws.panel.slider("dof0_value") as HSlider
	check(drive_bar != null and drive_bar.is_visible_in_tree() and is_equal_approx(drive_bar.min_value, -360.0) and is_equal_approx(drive_bar.max_value, 360.0), "Drive should show a -360..360° slider under Gear1's turn.")
	await _type_into("dof0_value", "30")
	await _press_ok()
	var turned := _turn_z(ws.viewport.body_pose(gear2)) - before
	check(absf(absf(turned) - deg_to_rad(60.0)) < 1e-5, "Gear2's holder should turn 60 degrees for Gear1's 30 (%s)." % rad_to_deg(turned))


# --- 6: contact ----------------------------------------------------------------------------------

func _contact_button() -> Button:
	var id := "solid.assemble.enable_contact_sets"
	if not ws.toolbar.pinned("Assemble").has(id):
		ws.toolbar.pin(id, true)
		await _frames(3)
	for button in ws.toolbar.icon_buttons("Assemble"):
		if str(button.get_meta("tool_id", "")) == id:
			return button
	return null


func _check_contact() -> void:
	if not await _edit("slider"):
		return
	var f: Dictionary = designs.slider
	var block: String = f.components.Block
	var wall: String = f.bodies.Wall
	await _look(Vector3(0.03, 0.0, 0.02), 0.5, -0.7, 0.4)
	var button := await _contact_button()
	check(button != null, "The Assemble group should show the Enable Contact Sets button.")
	if button == null:
		return
	await _press(button)
	await _frames(3)
	check(bool(_assembly().contact.enabled) and button.button_pressed and _undo_name() == "Forge: Contact On", "The button should turn contact on and show pressed (%s)." % _undo_name())
	# The Wall's row, then Ctrl and the Block's row; a right-click on the Block's row.
	await _expand_browser()
	var wall_item: TreeItem = ws.browser.body_item(wall)
	var block_item := _component_item(block)
	if wall_item == null or block_item == null:
		check(false, "The browser should list the Wall and the Block.")
		return
	await _click(_row_point(wall_item))
	await _ctrl_click(_row_point(block_item))
	check((ws.selected_components as Array).has(block) and ws._selected_bodies().has(wall), "The Wall and the Block should be selected (%s, %s)." % [ws.selected_components, ws._selected_bodies()])
	var texts := await _right_click_row(block_item)
	check(texts.has("New Contact Set"), "The Block's menu should offer New Contact Set (%s)." % [texts])
	await _choose("New Contact Set")
	var sets: Array = _assembly().contact_sets
	check(sets.size() == 1 and (sets[0].members as Array).has({"component": block}) and (sets[0].members as Array).has({"body": wall}) and _undo_name() == "Forge: Contact Set",
		"New Contact Set should hold the Block and the Wall (%s)." % [sets])
	ws.drive_joint(f.joints.Slider)
	await _frames(3)
	await _type_into("dof0_value", "50")
	check(_status().begins_with("Motion stopped at ") and _status().contains("Wall"), "The status row should say S-CONTACT-STOP (%s)." % _status())
	if _shots != "":
		await _shot("contact_dark_stop.png")
	await _press_ok()
	var value := float(DATA.normalized(ws.doc.assembly).joints[0].dofs[0].value)
	check(absf(value - 10.0 * MM) < 0.05 * MM, "The slider should stop near 10 mm (%s mm)." % (value / MM))
	note("the slider stopped at %s mm" % String.num(value / MM, 4))


# --- 7: Motion Study -----------------------------------------------------------------------------

func _study_button(text: String) -> Button:
	if ws.motion_study_panel == null:
		return null
	for node in ws.motion_study_panel.find_children("*", "Button", true, false):
		if (node as Button).text == text and (node as Button).is_visible_in_tree():
			return node
	return null


func _check_study() -> void:
	if not await _edit("lever"):
		return
	var joint := _joint_named("Joint1")
	if joint.is_empty():
		check(false, "Joint1 is needed for the study.")
		return
	var lever_body: String = designs.lever.bodies.Lever
	await _look(Vector3(0.04, 0.0, 0.01), 0.6, -0.8, 0.35)
	ws.run_tool(CATALOG.find("solid.assemble.motion_study"))
	await _frames(3)
	var study = ws.motion_study_panel
	check(study != null and study.visible, "Motion Study should open its panel.")
	if study == null:
		return
	await _press(_study_button("New Study"))
	await _frames(2)
	check(_assembly().studies.size() == 1, "New Study should make a study.")
	# Keys: the playhead at 0 s, value 0; at 2 s, value 90 (the track menu holds Joint1).
	var tracks: Control = study.get("_tracks")
	var value_field: LineEdit = study.get("_value")
	await _click(tracks.global_position + Vector2(float(study._x_of(0.0)), 8.0))
	await _press(value_field)
	await _type("0")
	await _press(_study_button("Add Key"))
	await _click(tracks.global_position + Vector2(float(study._x_of(2.0)), 8.0))
	check(absf(float(study.time) - 2.0) < 0.05, "A click on the ruler should move the playhead to 2 s (%s)." % study.time)
	await _press(value_field)
	await _key(KEY_A, {"ctrl": true})
	await _type("90")
	await _press(_study_button("Add Key"))
	await _frames(2)
	var keys: Array = _assembly().studies[0].keys
	check(keys.size() == 2, "Two keys should be on Joint1 (%s)." % [keys])
	await _click(tracks.global_position + Vector2(float(study._x_of(0.0)), 8.0))
	await _press(_study_button("Play"))
	var waited := Time.get_ticks_msec()
	while float(study.time) < 1.05 and Time.get_ticks_msec() - waited < 5000:
		await _tree.process_frame
	await _press(_study_button("Pause"))
	await _frames(2)
	check(not bool(study.playing) and float(study.time) >= 1.0, "Pause should stop the playhead past 1 s (%s)." % study.time)
	var frame: Dictionary = study._frame_at(float(study.time))
	var holder: Node3D = ws.viewport.body_holder(lever_body)
	var at_frame: Transform3D = XFORM.to_transform(frame.body_poses[lever_body]) if not frame.is_empty() else Transform3D()
	var close := holder != null and not frame.is_empty()
	if close:
		for i in 3:
			close = close and holder.transform.basis[i].distance_to(at_frame.basis[i]) < 1e-6
		close = close and holder.transform.origin.distance_to(at_frame.origin) < 1e-6
	check(close, "Paused past 1 s, the Lever's holder should be the frame of that time.")
	if _shots != "":
		await _shot("study_dark_panel.png")
	study.close()
	await _frames(2)
	# The slider's study with Contact ticked says where it stops (the set from 6).
	if not await _edit("slider"):
		return
	if _assembly().contact_sets.is_empty():
		note("the slider's contact set is missing (part 6 did not run): the study's contact stop was not checked")
		return
	ws.run_tool(CATALOG.find("solid.assemble.motion_study"))
	await _frames(3)
	study = ws.motion_study_panel
	await _press(_study_button("New Study"))
	var slider: String = designs.slider.joints.Slider
	study.add_key(slider, 0, 0.0, 0.0)
	study.add_key(slider, 0, 2.0, 50.0 * MM)
	await _frames(2)
	var contact: CheckBox = study.get("_contact")
	await _press(contact)
	await _frames(3)
	check(contact.button_pressed and absf(float(study.stopped_at()) - 0.4) < 0.01 and str(study.status_text()).begins_with("Motion stopped at "),
		"With Contact ticked the slider's study should stop near 0.4 s and say so (%s: %s)." % [study.stopped_at(), study.status_text()])
	if _shots != "":
		study.seek(1.0)
		await _shot("study_dark_contact_stop.png")
	study.close()
	await _frames(2)


# --- 8: modelled view ----------------------------------------------------------------------------

func _check_modelled_view() -> void:
	if not await _edit("lever"):
		return
	var lever_body: String = designs.lever.bodies.Lever
	var posed: Transform3D = ws.viewport.body_pose(lever_body)
	ws.run_tool(CATALOG.find("solid.create.extrude"))
	await _frames(4)
	var status: Label = ws.get("_status")
	var posed_now := not posed.is_equal_approx(Transform3D.IDENTITY)
	check(ws.command != null and bool(ws.modelled_view()) and (not posed_now or (status != null and status.text.contains(DATA.S_MODELLED_VIEW))),
		"Extrude should show modelled positions and say S-MODELLED-VIEW (%s)." % (status.text if status != null else ""))
	check(ws.viewport.body_pose(lever_body).is_equal_approx(Transform3D.IDENTITY), "The Lever should show where it is modelled.")
	await _focus_view()
	await _key(KEY_ESCAPE)
	await _frames(2)
	if ws.command != null:
		await _key(KEY_ESCAPE)
		await _frames(2)
	check(ws.command == null and not bool(ws.modelled_view()) and ws.viewport.body_pose(lever_body).is_equal_approx(posed), "Esc should close Extrude and pose the Lever again.")


# --- 9: the ground button ------------------------------------------------------------------------

func _check_ground_button() -> void:
	if ws.part != parts.lever and not await _edit("lever"):
		return
	var lever: String = designs.lever.components.Lever
	await _expand_browser()
	var item := _component_item(lever)
	if item == null or item.get_button_by_id(0, BROWSER.BUTTON_GROUND) < 0:
		check(false, "The Lever's row should have a ground button.")
		return
	var icon: Texture2D = item.get_button(0, item.get_button_by_id(0, BROWSER.BUTTON_GROUND))
	var point := _row_point(item, BROWSER.BUTTON_GROUND)
	await _frames(2)
	point = _row_point(item, BROWSER.BUTTON_GROUND)
	# (A row's button presses on the release after a press over it, with the mouse resting there.)
	var tree: Tree = ws.browser
	var local := point - tree.global_position
	var fired := []
	var on_button := func(row: TreeItem, _c: int, id: int, _b: int) -> void: fired.append([row.get_text(0), id])
	tree.button_clicked.connect(on_button)
	_move(point)
	await _frames(2)
	_button(point, true)
	await _frames(1)
	_button(point, false)
	await _frames(3)
	tree.button_clicked.disconnect(on_button)
	# A Tree takes a row button's press from the real mouse position, which pushed events don't
	# move; the point must still be over the ground button, and then the row's button is pressed
	# the way the inspect editor hook presses an eye.
	if fired.is_empty():
		var at_item := tree.get_item_at_position(local)
		if at_item != item or tree.get_button_id_at_position(local) != BROWSER.BUTTON_GROUND:
			check(false, "The point %s should be over the Lever's ground button." % point)
			return
		tree.button_clicked.emit(item, 0, BROWSER.BUTTON_GROUND, MOUSE_BUTTON_LEFT)
		await _frames(3)
	check(DATA.is_grounded(_assembly(), lever) and _undo_name() == "Forge: Ground Lever", "The ground button should ground the Lever (%s; clicked %s, by the mouse: %s)." % [_undo_name(), point, not fired.is_empty()])
	# (The browser rebuilt its rows.)
	item = _component_item(lever)
	var now: Texture2D = item.get_button(0, item.get_button_by_id(0, BROWSER.BUTTON_GROUND)) if item != null else null
	check(now != null and now != icon, "The ground button's icon should change.")
	await _focus_view()
	await _key(KEY_Z, {"ctrl": true})
	await _frames(3)
	check(not DATA.is_grounded(_assembly(), lever), "Ctrl+Z should unground the Lever.")


# --- 10: RigidBody3D through the Inspector -------------------------------------------------------

func _check_rigid_bake() -> void:
	if not await _edit("lever"):
		return
	var part: Node3D = parts.lever
	EditorInterface.inspect_object(part)
	var property: EditorProperty = null
	for i in 60:
		await _tree.process_frame
		for node in EditorInterface.get_inspector().find_children("*", "EditorProperty", true, false):
			if (node as EditorProperty).get_edited_property() == &"component_node_type" and (node as EditorProperty).get_edited_object() == part:
				property = node
		if property != null:
			break
	check(property != null, "The Inspector should show Component Node Type.")
	if property == null:
		return
	property.emit_changed(&"component_node_type", CAD_PART.COMPONENT_RIGID_BODY)
	await _frames(6)
	check(int(part.component_node_type) == CAD_PART.COMPONENT_RIGID_BODY, "The Inspector should set Component Node Type to RigidBody3D.")
	var lever: Node = part.find_child("Lever", true, false)
	var hinge: Node = part.get_node_or_null("Joints/Joint1")
	check(lever is RigidBody3D, "The scene tree should have Lever as a RigidBody3D (%s)." % [lever.get_class() if lever != null else "none"])
	check(hinge is HingeJoint3D, "The scene tree should have Joints/Joint1 as a HingeJoint3D (%s)." % [hinge.get_class() if hinge != null else "none"])


# --- 11: a saved copy ----------------------------------------------------------------------------

func _check_save_copy() -> void:
	if ws.command != null:
		ws.cancel_command()
	var root := EditorInterface.get_edited_scene_root()
	if root == null or root.name != SCENE_NAME or not root.scene_file_path.begins_with("res://tests/holo_forge/"):
		check(false, "The scene shown is not the hook's: nothing is written.")
		return
	var folder := COPY.get_basename() + "_forge"
	for node in root.find_children("*", "Node3D", true, false):
		if node.get_script() == CAD_PART:
			node.save_mesh_blobs(folder)
			node._save_meshes(folder)
	var packed := PackedScene.new()
	var packed_ok := packed.pack(root)
	var saved := ResourceSaver.save(packed, COPY) if packed_ok == OK else packed_ok
	check(saved == OK and root.scene_file_path == SCENE, "The copy should be written, the scene shown keeping its path (%s)." % error_string(saved))
	var loaded: PackedScene = ResourceLoader.load(COPY, "", ResourceLoader.CACHE_MODE_IGNORE) if saved == OK else null
	var copy: Node = loaded.instantiate() if loaded != null else null
	if copy != null:
		for key in ["lever", "gears", "slider"]:
			var shown: Node3D = parts[key]
			var back: Node = copy.get_node_or_null(_part_name(key))
			var same := back != null and back.document != null and DATA.normalized(back.document.assembly) == DATA.normalized(shown.document.assembly)
			check(same, "%s's assembly should load back deep-equal." % _part_name(key))
			if same:
				var solved_shown := SOLVER.solve(shown.document, ws.result if shown == ws.part else {}, ws.kernel) if shown == ws.part else {}
				if not solved_shown.is_empty():
					var poses_back := {}
					for component in shown.component_nodes():
						var node_back: Node = back.find_child(str((shown.component_nodes()[component] as Node).name), true, false)
						poses_back[component] = node_back is Node3D and (node_back as Node3D).transform.is_equal_approx((shown.component_nodes()[component] as Node3D).transform)
					check(not poses_back.values().has(false), "%s's component poses should load back the same (%s)." % [_part_name(key), poses_back])
		copy.free()
	else:
		check(false, "The copy should load back.")
	# The copy and what was written for it go again.
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(folder)):
		for file in DirAccess.get_files_at(folder):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(folder.path_join(file)))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(folder))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(COPY))


# --- Screenshots ---------------------------------------------------------------------------------

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
	print("Forge ASSEMBLE: saved ", _shots.path_join(file))


## The views team V's glyphs and handles show in (theme: "dark" or "light"): joints with their
## badges and axes, the snap candidates, Drive's ring, the Motion Link panel, a contact stop, the
## Motion Study panel and a Measure on posed bodies.
func _tour(theme: String) -> void:
	_step = "screenshots (%s)" % theme
	if await _edit("lever"):
		await _look(Vector3(0.04, 0.0, 0.012), 0.6, -0.6, 0.3)
		await _shot("joints_%s_glyphs.png" % theme)
		await _shot("workspace_%s.png" % theme, true)
		var joint := _joint_named("Joint1")
		if not joint.is_empty():
			# Joint1 selected: both units highlighted, the badge in the selection colour.
			ws.select_assembly("joints", str(joint.id))
			await _frames(2)
			await _shot("joints_%s_selected.png" % theme)
			ws.drive_joint(str(joint.id))
			await _frames(3)
			await _look(Vector3(0.0, 0.0, 0.015), 0.4, -1.1, 0.3)
			await _shot("drive_%s_ring.png" % theme)
			ws.cancel_command()
			await _frames(2)
		# Snap candidates while a new joint's slot is active.
		await _focus_view()
		await _key(KEY_J)
		await _frames(2)
		if ws.command != null:
			await _scale_view(Vector3(0.0, 0.0, 0.02), 0.4, -1.0, 2.5)
			var c: Vector2 = ws.viewport.project(ws.viewport.world_point(designs.lever.bodies.Lever, Vector3(0.0, 0.0, 0.02)))
			_move(_g(c + Vector2(26, 0)))
			await _frames(3)
			await _shot("joint_%s_candidates.png" % theme)
			ws.cancel_command()
			await _frames(2)
		# A posed Measure: the Lever's tip face to the Base's top.
		ws.run_tool(CATALOG.find("solid.inspect.measure"))
		await _frames(2)
		if ws.command != null:
			await _look(Vector3(0.0, 0.03, 0.012), 0.9, -0.7, 0.3)
			var tip: Vector2 = ws.viewport.project(ws.viewport.world_point(designs.lever.bodies.Lever, Vector3(0.07, 0.0, 0.02)))
			var base: Vector2 = ws.viewport.project(ws.viewport.world_point(designs.lever.bodies.Base, Vector3(-0.035, -0.035, 0.01)))
			await _click(_g(tip))
			await _click(_g(base))
			await _frames(3)
			await _shot("measure_%s_posed.png" % theme)
			ws.cancel_command()
			await _frames(2)
		ws.run_tool(CATALOG.find("solid.assemble.motion_study"))
		await _frames(3)
		if ws.motion_study_panel != null and ws.motion_study_panel.visible:
			ws.motion_study_panel.seek(1.0)
			await _shot("study_%s_panel.png" % theme)
			ws.motion_study_panel.close()
			await _frames(2)
	if await _edit("gears"):
		await _look(Vector3(0.015, 0.0, 0.015), 0.5, -0.9, 0.22)
		ws.run_tool(CATALOG.find("solid.assemble.motion_link"))
		await _frames(3)
		await _shot("link_%s_panel.png" % theme)
		if ws.command != null:
			ws.cancel_command()
		await _frames(2)
	if await _edit("slider"):
		await _look(Vector3(0.03, 0.0, 0.02), 0.5, -0.6, 0.3)
		var joints: Array = _assembly().joints
		if not joints.is_empty():
			ws.drive_joint(str(joints[0].id))
			await _frames(3)
			ws.set_command_values(_merged({"dof0_value": "60 mm"}))
			await _frames(4)
			await _shot("contact_%s_stop.png" % theme)
			ws.cancel_command()
			await _frames(2)


func _merged(values: Dictionary) -> Dictionary:
	var out: Dictionary = ws.command_values.duplicate(true)
	out.merge(values, true)
	return out


# --- The run -------------------------------------------------------------------------------------

func _project_watch(after: String) -> void:
	_step = "the part after " + after
	var stamp := [FileAccess.get_modified_time(PROJECT_FILE), FileAccess.get_md5(PROJECT_FILE)]
	if _project_stamp.is_empty():
		_project_stamp = stamp
	elif stamp != _project_stamp:
		check(false, "The project's settings file was written during %s." % after)
		_project_stamp = stamp


func _on_real_input(event: InputEvent) -> void:
	if event is InputEventMouse:
		_real_events += 1
		_real_last = _step


## The editor's windows that are showing (for a failure in a windowed run).
func _open_windows() -> Array:
	var found := []
	for node in EditorInterface.get_base_control().get_window().find_children("*", "Window", true, false):
		if (node as Window).visible:
			found.append(str(node.name) + ":" + node.get_class())
	return found


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
		window.size = _window_size
		_window_size = Vector2i.ZERO
	if _embedding >= 0 and gui != null:
		gui.gui_embed_subwindows = _embedding == 1
		_embedding = -1


func _finish() -> void:
	if DisplayServer.get_name() != "headless":
		print("Forge ASSEMBLE: the real mouse sent %d event(s) to the window during the run%s" % [_real_events, (", the last during " + _real_last) if _real_events > 0 else ""])
	await _frames(4)
	_restore_window()
	await _frames(2)
	if failures.is_empty() and not _only.is_empty():
		print("PARTIAL Holo Forge ASSEMBLE EDITOR: only %s ran, with no failure. [%s]" % [", ".join(_only), "; ".join(notes)])
	elif failures.is_empty():
		print("PASS Holo Forge ASSEMBLE EDITOR: " + PASSED + " [" + "; ".join(notes) + "]")
	else:
		print("FAIL Holo Forge ASSEMBLE EDITOR: ", failures)
	_tree.quit(0 if failures.is_empty() else 1)
