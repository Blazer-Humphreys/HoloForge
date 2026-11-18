@tool
extends EditorPlugin
## Holo Forge: a parametric CAD workspace in its own "Forge" main-screen tab, editing CadPart
## nodes whose baked bodies the game uses.

const WORKSPACE := preload("res://addons/holo_forge/ui/forge_workspace.gd")
const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const FORM_FEATURE := preload("res://addons/holo_forge/core/features/form.gd")
const PART_SAVER := preload("res://addons/holo_forge/nodes/cad_part_saver.gd")
const EXPORT := preload("res://addons/holo_forge/core/export.gd")
const TEST_ARG := "--holo-forge-editor-test"
const SKETCH_TEST_ARG := "--holo-forge-sketch-editor-test"
const SOLID_TEST_ARG := "--holo-forge-solid-editor-test"
const INSPECT_TEST_ARG := "--holo-forge-inspect-editor-test"
const INSERT_TEST_ARG := "--holo-forge-insert-editor-test"
const SURFACE_TEST_ARG := "--holo-forge-surface-editor-test"
const UI_TEST_ARG := "--holo-forge-ui-editor-test"
const FORM_TEST_ARG := "--holo-forge-form-editor-test"
const MESH_TEST_ARG := "--holo-forge-mesh-editor-test"
const SAVE_TEST_ARG := "--holo-forge-save-editor-test"
const ASSEMBLE_TEST_ARG := "--holo-forge-assemble-editor-test"
const HANDLES_TEST_ARG := "--holo-forge-handles-editor-test"
## The install self-test (self_test.gd): Project > Tools > SELF_TEST_MENU, or headless with
## "-- --holo-forge-self-test [--holo-forge-self-test-log=<file>]", which quits with 0 or 1.
const SELF_TEST := "res://addons/holo_forge/self_test.gd"
const SELF_TEST_ARG := "--holo-forge-self-test"
const SELF_TEST_LOG_ARG := "--holo-forge-self-test-log="
const SELF_TEST_MENU := "Holo Forge: Run Self-Test"
const VIDEO_TEST_ARG := "--holo-forge-video-editor-test"
const MATERIALS_TEST_ARG := "--holo-forge-materials-editor-test"
## Editor hook runs ("-- --holo-forge-<name>-test") are kept off the user's project by this script:
## the user's open scenes are not opened, and a run that changes a file outside its own folders
## fails (tests/holo_forge_hook_guard.gd). HOOK_SESSION is what a hook that was killed leaves.
const HOOK_GUARD := "res://tests/holo_forge_hook_guard.gd"
const HOOK_SESSION := "res://.godot/holo_forge_hook_session"
const LIBRARY_DIR := "res://addons/holo_forge/bin"
## The copy the editor loads (Godot copies the library to ~<name> so a rebuild can replace it) is
## replaced when an editor starts; when another editor still has it loaded, Windows can only
## rename it, to ~holo_forge_native.dll~RF<hex>.TMP, and nothing removes it after.
const LIBRARY_LEFTOVER_PREFIX := "~holo_forge_native.dll~RF"

var workspace: Control
## The guard of an editor hook run (null in the user's editor); hooks that save ask it what the
## editor holds in memory and what changed.
var hook_guard: RefCounted
var _editor_test_runner: RefCounted
var _part_saver: ResourceFormatSaver


func _enter_tree() -> void:
	# First of all, before the editor reads its layout: a hook run opens none of the user's scenes.
	_guard_hook_run()
	clear_library_leftovers(ProjectSettings.globalize_path(LIBRARY_DIR))
	_add_project_settings()
	# Parts put their meshes beside a scene while the editor writes it (nodes/cad_part_saver.gd).
	_part_saver = PART_SAVER.new()
	CAD_PART.use_saver(_part_saver)
	workspace = WORKSPACE.new()
	workspace.plugin = self
	workspace.visible = false
	EditorInterface.get_editor_main_screen().add_child(workspace)
	add_custom_type("CadPart", "Node3D", CAD_PART, _icon("CSGCombiner3D"))
	EditorInterface.get_selection().selection_changed.connect(workspace.on_editor_selection_changed)
	scene_changed.connect(workspace.on_scene_changed)
	add_tool_menu_item(SELF_TEST_MENU, _run_self_test_dialog)
	if OS.get_cmdline_user_args().has(SELF_TEST_ARG):
		_run_self_test_headless.call_deferred()
	if OS.get_cmdline_user_args().has(TEST_ARG):
		_editor_test_runner = load("res://tests/holo_forge_editor_test.gd").new()
		_editor_test_runner.run.call_deferred(self)
	if OS.get_cmdline_user_args().has(SKETCH_TEST_ARG):
		_editor_test_runner = load("res://tests/holo_forge_sketch_editor_test.gd").new()
		_editor_test_runner.run.call_deferred(self)
	if OS.get_cmdline_user_args().has(SOLID_TEST_ARG):
		_editor_test_runner = load("res://tests/holo_forge_solid_editor_test.gd").new()
		_editor_test_runner.run.call_deferred(self)
	if OS.get_cmdline_user_args().has(INSPECT_TEST_ARG):
		_editor_test_runner = load("res://tests/holo_forge_inspect_editor_test.gd").new()
		_editor_test_runner.run.call_deferred(self)
	if OS.get_cmdline_user_args().has(INSERT_TEST_ARG):
		_editor_test_runner = load("res://tests/holo_forge_insert_editor_test.gd").new()
		_editor_test_runner.run.call_deferred(self)
	if OS.get_cmdline_user_args().has(SURFACE_TEST_ARG):
		_editor_test_runner = load("res://tests/holo_forge_surface_editor_test.gd").new()
		_editor_test_runner.run.call_deferred(self)
	if OS.get_cmdline_user_args().has(UI_TEST_ARG):
		_editor_test_runner = load("res://tests/holo_forge_ui_editor_test.gd").new()
		_editor_test_runner.run.call_deferred(self)
	if OS.get_cmdline_user_args().has(FORM_TEST_ARG):
		_editor_test_runner = load("res://tests/holo_forge_form_editor_test.gd").new()
		_editor_test_runner.run.call_deferred(self)
	if OS.get_cmdline_user_args().has(MESH_TEST_ARG):
		_editor_test_runner = load("res://tests/holo_forge_mesh_editor_test.gd").new()
		_editor_test_runner.run.call_deferred(self)
	if OS.get_cmdline_user_args().has(SAVE_TEST_ARG):
		_editor_test_runner = load("res://tests/holo_forge_save_editor_test.gd").new()
		_editor_test_runner.run.call_deferred(self)
	if OS.get_cmdline_user_args().has(ASSEMBLE_TEST_ARG):
		_editor_test_runner = load("res://tests/holo_forge_assembly_editor_test.gd").new()
		_editor_test_runner.run.call_deferred(self)
	if OS.get_cmdline_user_args().has(HANDLES_TEST_ARG):
		_editor_test_runner = load("res://tests/holo_forge_handles_editor_test.gd").new()
		_editor_test_runner.run.call_deferred(self)
	if OS.get_cmdline_user_args().has(VIDEO_TEST_ARG):
		_editor_test_runner = load("res://tests/holo_forge_video_editor_test.gd").new()
		_editor_test_runner.run.call_deferred(self)
	if OS.get_cmdline_user_args().has(MATERIALS_TEST_ARG):
		_editor_test_runner = load("res://tests/holo_forge_materials_editor_test.gd").new()
		_editor_test_runner.run.call_deferred(self)


func _exit_tree() -> void:
	if EditorInterface.get_selection().selection_changed.is_connected(workspace.on_editor_selection_changed):
		EditorInterface.get_selection().selection_changed.disconnect(workspace.on_editor_selection_changed)
	if scene_changed.is_connected(workspace.on_scene_changed):
		scene_changed.disconnect(workspace.on_scene_changed)
	remove_custom_type("CadPart")
	remove_tool_menu_item(SELF_TEST_MENU)
	if is_instance_valid(workspace):
		workspace.queue_free()
	if _part_saver != null:
		CAD_PART.use_saver(null)
		if _part_saver.is_registered():
			ResourceSaver.remove_resource_format_saver(_part_saver)
		_part_saver = null
	# A hook run ends here (it called quit): the editor's layout goes back as the user left it, and
	# a run that changed a file outside its own folders fails.
	if hook_guard != null:
		var changed: PackedStringArray = hook_guard.end()
		if not changed.is_empty():
			print("FAIL Holo Forge HOOK GUARD: %d file(s) outside the hook's own folders changed during this run: %s" % [changed.size(), ", ".join(changed)])
			get_tree().quit(1)


## Project > Tools > Holo Forge: Run Self-Test: runs the checks and shows the report.
func _run_self_test_dialog() -> void:
	var test: RefCounted = load(SELF_TEST).new()
	var ok: bool = await test.run(self)
	var dialog := AcceptDialog.new()
	dialog.title = "Holo Forge Self-Test: %s" % ("passed" if ok else "FAILED")
	dialog.dialog_text = test.report() + ("" if ok else "\n\nPlease post this report in the #bug-reports forum on the Holo Forge Discord (https://discord.gg/vRDFxNvZ77).")
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	EditorInterface.popup_dialog_centered(dialog)


## The installer's run: prints the report, writes it to the log file if one was given, and quits
## the editor with 0 (passed) or 1.
func _run_self_test_headless() -> void:
	var test: RefCounted = load(SELF_TEST).new()
	var ok: bool = await test.run(self)
	var report: String = test.report()
	print(report)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(SELF_TEST_LOG_ARG):
			var file := FileAccess.open(arg.trim_prefix(SELF_TEST_LOG_ARG), FileAccess.WRITE)
			if file != null:
				file.store_string(report + "\n")
				file.close()
	get_tree().quit(0 if ok else 1)


## Starts the guard of an editor hook run, or, in the user's editor, puts back what a hook that
## was killed left behind (see tests/holo_forge_hook_guard.gd).
func _guard_hook_run() -> void:
	var hook := false
	for arg in OS.get_cmdline_user_args():
		hook = hook or (arg.begins_with("--holo-forge-") and arg.ends_with("-test"))
	if not hook and not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(HOOK_SESSION)):
		return
	if not ResourceLoader.exists(HOOK_GUARD):
		return
	var guard: RefCounted = load(HOOK_GUARD).new()
	if hook:
		hook_guard = guard
		guard.begin()
	else:
		guard.heal()


## Shows Holo Forge's project settings in Project Settings (Holo Forge > Export > Board Models
## Folder, a folder picker). Their defaults are not written to project.godot.
static func _add_project_settings() -> void:
	var key := EXPORT.BOARD_MODELS_SETTING
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, "")
	ProjectSettings.set_initial_value(key, "")
	ProjectSettings.add_property_info({"name": key, "type": TYPE_STRING, "hint": PROPERTY_HINT_GLOBAL_DIR})


## Deletes stale renamed library copies in dir (see LIBRARY_LEFTOVER_PREFIX); one another editor
## still has loaded can't be deleted and stays until a later start. Returns how many went.
static func clear_library_leftovers(dir: String) -> int:
	var removed := 0
	var access := DirAccess.open(dir)
	if access == null:
		return 0
	# (The copies carry the hidden attribute Godot gives the one it loads.)
	access.include_hidden = true
	for name in access.get_files():
		if name.begins_with(LIBRARY_LEFTOVER_PREFIX) and name.get_extension().to_lower() == "tmp":
			if DirAccess.remove_absolute(dir.path_join(name)) == OK:
				removed += 1
	return removed


func _has_main_screen() -> bool:
	return true


func _make_visible(visible: bool) -> void:
	if is_instance_valid(workspace):
		workspace.visible = visible


func _get_plugin_name() -> String:
	return "Forge"


func _get_plugin_icon() -> Texture2D:
	return _icon("CSGCombiner3D")


## The editor asks for this after it has written a scene, and also at other times (before a run,
## when it closes). A part's baked meshes and stored meshes are NOT written here: that happens
## while the editor writes the part's own scene (CadPart.scene_is_being_written), so nothing is
## written beside a scene the user did not save, and a Save As writes beside the new scene. The
## plugin never saves a scene itself.
func _save_external_data() -> void:
	var scene := EditorInterface.get_edited_scene_root()
	if scene == null:
		return
	var parts: Array[Node] = []
	if scene.get_script() == CAD_PART:
		parts.append(scene)
	for node in scene.find_children("*", "Node3D", true, false):
		if node.get_script() == CAD_PART:
			parts.append(node)
	for cad_part in parts:
		# Form cages keep their doubles exactly through the text scene (core/features/form.gd).
		FORM_FEATURE.store_exact(cad_part.get("document"))


func _icon(name: String) -> Texture2D:
	var theme := EditorInterface.get_editor_theme()
	return theme.get_icon(name, "EditorIcons") if theme != null and theme.has_icon(name, "EditorIcons") else null
