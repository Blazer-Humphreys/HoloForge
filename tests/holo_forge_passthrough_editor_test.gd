@tool
extends RefCounted
## Passthrough in the real editor (Display > Passthrough). The hook builds its own scene,
## tests/holo_forge/passthrough_editor_test.tscn (a floor, two boxes, a sun, a WorldEnvironment and
## a CadPart moved and turned in it), writes it with ResourceSaver only and opens it.
##   1. The part selected in the scene tree is the Forge's; its body bakes into the scene.
##   2. A real click opens the Display menu; Passthrough is chosen in it (the menu is a window of
##      its own: its entry is chosen as a click on it does). The Forge view then renders the edited
##      scene's world (the one the 3D editor shows), the part's space sits at the part's place,
##      the view's sky and lights are out (the scene has its own), and the part's baked nodes are
##      hidden from rendering with their visible property untouched.
##   3. The 3D tab: the view is back in its own world (Passthrough stays on). The Forge tab again:
##      back in the scene.
##   4. A click on the part's face in the view still picks it.
##   5. Off again by the menu: the view's own world, sky and lights.
##   6. Nothing of this is an edit: the scene's undo history is where it was, and the hook guard
##      (plugin.gd) reports no change outside the hook's folders.
##
## godot --headless --path . --editor -- --holo-forge-passthrough-editor-test

const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const VIEWPORT := preload("res://addons/holo_forge/ui/forge_viewport.gd")
const SCENE := "res://tests/holo_forge/passthrough_editor_test.tscn"
const SCENE_NAME := "PassthroughEditorTest"
const PART_NAME := "PassPart"
## The headless editor's window is 1024 x 600; the hook gives it this size and puts the old back.
const HEADLESS_SIZE := Vector2i(1920, 1080)
static var PART_PLACE := Transform3D(Basis(Vector3(0.1, 1.0, 0.25).normalized(), 0.7), Vector3(6.0, 0.75, -4.0))

const PASSED := "a real click opens Display and Passthrough shows the part in the edited scene's world at its place, the view's sky and lights out for the scene's, its baked nodes hidden from rendering only; the 3D tab gives the view its own world and the Forge tab the scene again; a click on the part still picks it; off again restores the view's world, sky and lights; no undo step and no file outside the hook's folders changed"

var failures: Array[String] = []
var _tree: SceneTree
var _plugin: EditorPlugin
var _mouse := Vector2.ZERO
var _window_size := Vector2i.ZERO
var ws
var view
var gui: Viewport
var scene: Node3D
var part: Node3D


func check(ok: bool, detail: String) -> void:
	if not ok:
		failures.append(detail)
		push_error(detail)
		print("FAIL: ", detail)


func run(plugin: EditorPlugin) -> void:
	_plugin = plugin
	_tree = plugin.get_tree()
	_tree.create_timer(300.0).timeout.connect(func() -> void:
		print("FAIL Holo Forge PASSTHROUGH EDITOR: timed out ", failures)
		_restore_window()
		_tree.quit(1))
	if not ClassDB.class_exists("CadShape"):
		check(false, "The native kernel (CadShape) is needed.")
		_finish()
		return
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
		check(false, "The hook's scene %s should open." % SCENE)
		_finish()
		return
	scene = EditorInterface.get_edited_scene_root() as Node3D
	part = scene.get_node_or_null(PART_NAME)
	EditorInterface.set_main_screen_editor("Forge")
	if DisplayServer.get_name() == "headless":
		var window: Window = EditorInterface.get_base_control().get_window()
		_window_size = window.size
		window.size = HEADLESS_SIZE
	await _frames(5)
	ws = plugin.get("workspace")
	if ws == null or ws.kernel == null or part == null:
		check(false, "The Forge workspace with its kernel and the scene's part are needed.")
		_finish()
		return
	ws.theme_store = {}
	ws.passthrough_store = {}
	view = ws.viewport
	gui = (view as Control).get_viewport()

	# 1. The part is the Forge's and its body is baked into the scene.
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(part)
	for i in 120:
		await _tree.process_frame
		if ws.part == part and not _baked().is_empty():
			break
	check(ws.part == part, "Selecting the part should make it the Forge's.")
	check(not _baked().is_empty(), "The part's body should be baked into the scene.")
	await _frames(3)
	var history: UndoRedo = _history()
	var version_before := history.get_version() if history != null else -1
	check(not view.passthrough_on(), "Passthrough should start off.")

	# 2. Display > Passthrough.
	await _choose_passthrough()
	var world: World3D = scene.get_world_3d()
	var editor_world: World3D = EditorInterface.get_editor_viewport_3d(0).find_world_3d()
	check(view.passthrough_on() and ws.passthrough, "Display > Passthrough should turn it on.")
	check(_sub().world_3d == world, "The view should render the edited scene's world.")
	check(world == editor_world, "The edited scene's world should be the one the 3D editor shows.")
	check((view.get("_world") as Node3D).global_transform.is_equal_approx(part.global_transform.orthonormalized()), "The view's space should be at the part's place.")
	check((view.get("_environment_node") as Node).get_parent() == null, "The view's sky should be out: the scene has a WorldEnvironment.")
	check(not (view.get("_head_light") as Light3D).visible and not (view.get("_top_light") as Light3D).visible, "The view's lights should be off: the scene has a sun.")
	var hidden: Array = view.passthrough_state().get("hidden", [])
	for node in _baked():
		check(hidden.has(node), "%s should be hidden from rendering." % node.name)
		check((node as VisualInstance3D).visible, "%s keeps visible = true." % node.name)
	check(_menu_checked(), "The Display menu should show Passthrough checked.")

	# 3. The 3D tab and back.
	EditorInterface.set_main_screen_editor("3D")
	await _frames(4)
	check(ws.passthrough and not view.passthrough_on(), "On the 3D tab the view should leave the scene (Passthrough still on).")
	check(_sub().world_3d == view.get("_private_world"), "On the 3D tab the view should have its own world.")
	EditorInterface.set_main_screen_editor("Forge")
	await _frames(4)
	check(view.passthrough_on() and _sub().world_3d == world, "Back on the Forge tab the view should be in the scene again.")

	# 4. A click on the part's top face still picks it (the scene's floor and boxes are not pickable).
	ws.selection.clear()
	view.fit()
	await _frames(3)
	var top: Vector2 = view.project(Vector3(0.0, 0.02, 0.0))
	await _click((view as Control).global_position + top)
	await _frames(3)
	var picked: Array = ws.selection
	check(picked.size() == 1 and str(picked[0].get("kind", "")) == "face", "A click on the part's top face should pick it (%s)." % str(picked))
	ws.selection.clear()

	# 5. Off again.
	await _choose_passthrough()
	check(not ws.passthrough and not view.passthrough_on(), "Display > Passthrough again should turn it off.")
	check(_sub().world_3d == view.get("_private_world"), "Off, the view should have its own world.")
	check((view.get("_environment_node") as Node).get_parent() == view.get("_world"), "Off, the view's sky should be back.")
	check((view.get("_head_light") as Light3D).visible and (view.get("_top_light") as Light3D).visible, "Off, the view's lights should be on.")

	# 6. No edit was made.
	await _frames(3)
	history = _history()
	check(history != null and history.get_version() == version_before, "Passthrough should make no undo step (%d -> %d)." % [version_before, history.get_version() if history != null else -1])
	var guard: RefCounted = plugin.get("hook_guard")
	if guard != null:
		var changed: PackedStringArray = guard.changed_files()
		check(changed.is_empty(), "No file outside the hook's folders should change (%s)." % ", ".join(changed))
	_finish()


func _build_scene() -> bool:
	if not SCENE.begins_with("res://tests/holo_forge/"):
		return false
	var root := Node3D.new()
	root.name = SCENE_NAME
	var floor := MeshInstance3D.new()
	floor.name = "Floor"
	var plane := PlaneMesh.new()
	plane.size = Vector2(40, 40)
	floor.mesh = plane
	root.add_child(floor)
	for spec in [["BoxBehind", Vector3(5.0, 0.5, -6.0)], ["BoxBeside", Vector3(8.0, 0.5, -3.0)]]:
		var box := MeshInstance3D.new()
		box.name = spec[0]
		box.mesh = BoxMesh.new()
		box.position = spec[1]
		root.add_child(box)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-50, 30, 0)
	root.add_child(sun)
	var environment := WorldEnvironment.new()
	environment.name = "Sky"
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.45, 0.6, 0.8)
	root.add_child(environment)
	var cad: Node3D = CAD_PART.new()
	cad.name = PART_NAME
	var doc: Resource = DOCUMENT.new()
	var block: Resource = doc.add_feature("box", "Block", {
		"length": doc.make_input("40 mm", "length"), "height": doc.make_input("20 mm", "length"), "width": doc.make_input("30 mm", "length"),
	}, {"operation": OPERATIONS.NEW_BODY, "position": Vector3.ZERO})
	block.options.body_id = doc.new_body(block.id)
	cad.document = doc
	cad.transform = PART_PLACE
	root.add_child(cad)
	for child in root.get_children():
		child.owner = root
	var packed := PackedScene.new()
	var packed_ok := packed.pack(root)
	var saved := ResourceSaver.save(packed, SCENE) if packed_ok == OK else packed_ok
	root.free()
	check(saved == OK, "The hook's scene should be written (%s)." % error_string(saved))
	return saved == OK


func _baked() -> Array:
	if part == null or not is_instance_valid(part):
		return []
	return part.find_children("*", "VisualInstance3D", true, false)


func _sub() -> SubViewport:
	return view.get("_viewport")


func _history() -> UndoRedo:
	var undo := _plugin.get_undo_redo()
	return undo.get_history_undo_redo(undo.get_object_history_id(scene))


func _menu_checked() -> bool:
	var popup: PopupMenu = (view.get("_style_menu") as MenuButton).get_popup()
	return popup.is_item_checked(popup.get_item_index(VIEWPORT.PASSTHROUGH_ITEM))


## A real click on the Display button opens its menu; Passthrough is chosen in it.
func _choose_passthrough() -> void:
	var menu: MenuButton = view.get("_style_menu")
	var popup := menu.get_popup()
	await _click(menu.global_position + menu.size * 0.5)
	await _frames(3)
	check(popup.visible, "A click on Display should open its menu.")
	var index := popup.get_item_index(VIEWPORT.PASSTHROUGH_ITEM)
	check(index >= 0 and not popup.is_item_disabled(index), "Display should offer Passthrough, enabled.")
	popup.id_pressed.emit(VIEWPORT.PASSTHROUGH_ITEM)
	popup.hide()
	await _frames(4)


func _frames(count: int) -> void:
	for i in count:
		await _tree.process_frame


func _click(at: Vector2) -> void:
	_move(at)
	await _tree.process_frame
	_button(at, true)
	_button(at, false)
	await _tree.process_frame


func _button(at: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = at
	event.global_position = at
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	_mouse = at
	gui.push_input(event, true)


func _move(to: Vector2) -> void:
	gui.notification(Node.NOTIFICATION_VP_MOUSE_ENTER)
	var event := InputEventMouseMotion.new()
	event.position = to
	event.global_position = to
	event.relative = to - _mouse
	_mouse = to
	gui.push_input(event, true)


func _restore_window() -> void:
	if _window_size != Vector2i.ZERO:
		EditorInterface.get_base_control().get_window().size = _window_size
		_window_size = Vector2i.ZERO


func _finish() -> void:
	if ws != null and ws.passthrough:
		ws.set_passthrough(false)
	await _frames(2)
	_restore_window()
	await _frames(2)
	if failures.is_empty():
		print("PASS Holo Forge PASSTHROUGH EDITOR: " + PASSED)
	else:
		print("FAIL Holo Forge PASSTHROUGH EDITOR: ", failures)
	_tree.quit(0 if failures.is_empty() else 1)
