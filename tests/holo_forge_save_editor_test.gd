@tool
extends RefCounted
## Holo Forge in the editor: what a scene save writes for a part's baked meshes and stored meshes.
##
##   1. The first Save of a scene with a part writes the baked meshes and the large stored mesh
##      beside the scene, and the scene file points at them (it stays small): one Save is enough,
##      and the plugin saves nothing by itself afterwards.
##   2. Save As writes them beside the new scene, points the new scene at its own folder, and leaves
##      the old scene's file and folder as they were.
##   3. Nothing is written for a scene the user did not save: an edit that is not saved leaves the
##      files beside the scene alone, also when the editor asks plugins for their external data.
##   4. A saved scene loads back to the same stored mesh.
##   5. The editor drops every scripted saver when its script classes change: the part puts the
##      plugin's back before its scene is written, so one Save is still enough. With the plugin's
##      saver gone for good the files are written right after the scene and the next Save points
##      the scene at them (the part still never saves a scene itself).
##   6. No file outside this test's folder changed (the hook guard, tests/holo_forge_hook_guard.gd).
##
## How it saves. The editor's own Save writes, besides the scene, every loaded resource file the
## editor has marked as edited, whatever it belongs to: in a project that has resources of its
## own loaded in the editor (the user's game: its plugins and autoloads load them at start), a Save
## from a test would rewrite the user's files. So:
##   - when none of the project's resources is loaded (a project that holds only Holo Forge and
##     its tests), the test saves with the editor (EditorInterface.save_scene_as);
##   - otherwise it saves its scene alone, in the editor's order (the scene's nodes are told, the
##     scene is packed and written through ResourceSaver, the plugin is asked for its external
##     data, the scene gets its path, the nodes are told again), and says so in its PASS line.
##
## godot --headless --path . --editor -- --holo-forge-save-editor-test

const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const MESH_BLOB := preload("res://addons/holo_forge/core/mesh/mesh_blob.gd")
const FIXTURES := preload("res://tests/holo_forge_mesh_fixtures.gd")

const SCENE_A := "res://tests/holo_forge/_save_hook_a.tscn"
const SCENE_B := "res://tests/holo_forge/_save_hook_b.tscn"
## A scene file that only points at its meshes stays under this (the stored mesh alone is larger).
const SMALL := 200 * 1024

var failures: Array[String] = []
var checked: Array[String] = []
var _tree: SceneTree
var _plugin: EditorPlugin
## The plugin's guard of this hook run.
var _guard: RefCounted
## The scene this test works in: nothing is saved unless the editor shows it.
var _scene: Node
## True when the editor itself saves (none of the project's resources is loaded).
var _editor_saves := false
## How often the editor said it saved a scene.
var _editor_said_saved := 0


func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func run(plugin: EditorPlugin) -> void:
	_plugin = plugin
	_tree = plugin.get_tree()
	_guard = plugin.get("hook_guard")
	_tree.create_timer(300.0).timeout.connect(func() -> void:
		print("FAIL Holo Forge SAVE EDITOR: timed out ", failures)
		_clean()
		_tree.quit(1))
	if _guard == null:
		print("FAIL Holo Forge SAVE EDITOR: the plugin started no hook guard; nothing was saved.")
		_tree.quit(1)
		return
	_clean()
	# An empty saved scene to work in (written here, so no scene of the project is touched).
	var empty := Node3D.new()
	empty.name = "SaveHook"
	var packed := PackedScene.new()
	packed.pack(empty)
	ResourceSaver.save(packed, SCENE_A)
	empty.free()
	EditorInterface.get_resource_filesystem().update_file(SCENE_A)
	# The editor has to be done starting (the guard keeps it from opening the user's last session,
	# so no other scene should show up) before this test's scene is opened.
	var settled := 0
	var before := ""
	for i in 3000:
		await _tree.process_frame
		var shown := EditorInterface.get_edited_scene_root()
		var now := "%d|%s" % [EditorInterface.get_open_scenes().size(), shown.scene_file_path if shown != null else ""]
		settled = settled + 1 if now == before else 0
		before = now
		if settled >= 240:
			break
	var others := PackedStringArray()
	for path in EditorInterface.get_open_scenes():
		if str(path) != "" and not str(path).begins_with("res://tests/"):
			others.append(path)
	check(others.is_empty(), "The editor of a hook run should open none of the user's scenes (%s)." % ", ".join(others))
	var scene: Node = null
	var stable := 0
	for i in 900:
		await _tree.process_frame
		scene = EditorInterface.get_edited_scene_root()
		if scene != null and scene.scene_file_path == SCENE_A and scene.is_inside_tree():
			stable += 1
			if stable >= 90:
				break
		else:
			stable = 0
			if i % 30 == 0:
				EditorInterface.open_scene_from_path(SCENE_A)
	if scene == null or scene.scene_file_path != SCENE_A or stable < 90:
		print("FAIL Holo Forge SAVE EDITOR: could not open its scene")
		_clean()
		_tree.quit(1)
		return
	_scene = scene
	# Who saves (see the top): the editor only when it holds none of the project's resources.
	var loaded: PackedStringArray = _guard.loaded_user_resources()
	_editor_saves = loaded.is_empty()
	plugin.scene_saved.connect(_on_editor_saved)

	# A part with a B-rep box and a mesh body whose stored mesh is over 256 KB.
	var part: Node3D = CAD_PART.new()
	part.name = "SavePart"
	var doc: Resource = DOCUMENT.new()
	part.document = doc
	scene.add_child(part)
	part.owner = scene
	var box: Resource = doc.add_feature("box", "Box", {
		"length": doc.make_input("20 mm", "length"), "height": doc.make_input("20 mm", "length"), "width": doc.make_input("20 mm", "length"),
	}, {"operation": OPERATIONS.NEW_BODY, "position": Vector3.ZERO})
	box.options.body_id = doc.new_body(box.id)
	var mesh: RefCounted = FIXTURES.to_mesh(FIXTURES.with_noise(FIXTURES.icosphere(0.05, 6), 0.05))
	var blob: Resource = MESH_BLOB.from_mesh(mesh)
	var insert: Resource = doc.add_feature("mesh_import", "Mesh", {}, {
		"path": "", "kind": "mesh", "units": "m", "mesh_units": "m", "linked": false, "split": false, "transform": Transform3D.IDENTITY,
		"operation": OPERATIONS.NEW_BODY, "mesh": blob,
	})
	insert.options["body_id"] = doc.new_body(insert.id)
	part.bake()
	await _frames(2)
	check(blob.is_large() and part.body_nodes().size() == 2, "The part should hold two baked bodies and a stored mesh over 256 KB (%d bytes, %d bodies)." % [(blob.data as PackedByteArray).size(), part.body_nodes().size()])
	var folder_a := SCENE_A.get_basename() + "_forge"
	var folder_b := SCENE_B.get_basename() + "_forge"
	var blob_file := "SavePart_mesh_%s.res" % str(blob.digest).substr(0, 16)
	# (A baked mesh's file is named <part>_<body id>_<a tag of what it holds>.res.)
	var box_stem := "SavePart_%s_" % str(box.options.body_id)
	var mesh_stem := "SavePart_%s_" % str(insert.options.body_id)

	# 1. One Save: the files are beside the scene and the scene file points at them; nothing is
	# saved again afterwards.
	if not await _save(SCENE_A):
		return
	await _frames(20)
	var text_a := FileAccess.get_file_as_string(SCENE_A)
	var files_a := _files(folder_a)
	check(files_a.size() == 3 and files_a.has(blob_file) and _named(files_a, box_stem) != "" and _named(files_a, mesh_stem) != "",
		"One Save should write the stored mesh and both baked meshes beside the scene (%s)." % str(files_a))
	check(text_a.length() < SMALL and text_a.contains(folder_a.path_join(blob_file)) and not text_a.contains("[sub_resource type=\"ArrayMesh\"") and not text_a.contains("digest = \"%s\"" % str(blob.digest)),
		"After one Save the scene file should point at the files beside it and hold no mesh itself (%d bytes)." % text_a.length())
	check(str(blob.resource_path) == folder_a.path_join(blob_file), "The stored mesh should be kept in the file beside the scene (%s)." % blob.resource_path)
	check(not _editor_saves or _editor_said_saved == 1, "One Save should be one save of the editor's: the plugin must not save again (the editor saved %d times)." % _editor_said_saved)
	var stamps_a := _stamps(folder_a)
	var size_a := text_a.length()
	checked.append("one Save writes the baked meshes and the stored mesh beside the scene and a %d-byte scene file that points at them, and nothing saves again" % size_a)

	# 3. An edit that is not saved writes nothing: the box grows, the part is baked again, and the
	# editor asks its plugins for their external data (as it does on run and on quit).
	box.set_expression("height", "35 mm")
	part.bake()
	await _frames(2)
	plugin._save_external_data()
	await _frames(2)
	check(_stamps(folder_a) == stamps_a and FileAccess.get_file_as_string(SCENE_A) == text_a, "An edit that is not saved should leave the scene's files alone (%s -> %s)." % [str(stamps_a), str(_stamps(folder_a))])
	checked.append("an unsaved edit writes nothing beside the scene (also when the editor asks plugins for external data)")

	# 2. Save As: the new scene has its own folder and points at it; the old scene is untouched.
	if not await _save(SCENE_B):
		return
	await _frames(20)
	var text_b := FileAccess.get_file_as_string(SCENE_B)
	var files_b := _files(folder_b)
	check(scene.scene_file_path == SCENE_B and files_b.has(blob_file) and files_b.size() == 3, "Save As should write the three files beside the new scene (%s; scene path %s)." % [str(files_b), scene.scene_file_path])
	check(text_b.length() < SMALL and text_b.contains(folder_b.path_join(blob_file)) and not text_b.contains(folder_a.get_file() + "/") and not text_b.contains("[sub_resource type=\"ArrayMesh\""),
		"The new scene should point at its own folder only (%d bytes)." % text_b.length())
	check(_stamps(folder_a) == stamps_a and FileAccess.get_file_as_string(SCENE_A) == text_a, "Save As should leave the old scene and its folder as they were.")
	check(not _editor_saves or _editor_said_saved == 2, "Save As should be one save of the editor's (the editor saved %d times in all)." % _editor_said_saved)
	checked.append("Save As writes beside the new scene, points it at its own folder and leaves the old scene and its files untouched")

	# A second Save with nothing changed writes no file again.
	var stamps_b := _stamps(folder_b)
	var modified_b := FileAccess.get_modified_time(SCENE_B)
	if not await _save(SCENE_B):
		return
	await _frames(4)
	check(_stamps(folder_b) == stamps_b and FileAccess.get_file_as_string(SCENE_B) == text_b, "Saving again with nothing changed should rewrite no file beside the scene (scene file time %d -> %d)." % [modified_b, FileAccess.get_modified_time(SCENE_B)])

	# 5. The engine dropped the plugin's saver (as the editor does when script classes change): the
	# part puts it back before its scene is written, and one Save is enough as before.
	var saver: ResourceFormatSaver = plugin.get("_part_saver")
	check(saver != null and saver.is_registered(), "The plugin should have its saver registered.")
	if saver != null:
		ResourceSaver.remove_resource_format_saver(saver)
		box.set_expression("height", "38 mm")
		part.bake()
		await _frames(2)
		if not await _save(SCENE_B):
			return
		await _frames(20)
		check(saver.is_registered() and not FileAccess.get_file_as_string(SCENE_B).contains("[sub_resource type=\"ArrayMesh\""),
			"After the engine dropped the plugin's saver, one Save should still write a scene that points at its files (saver registered: %s)." % saver.is_registered())
		# The box was baked anew: its new file is there, the one it replaced is cleared away, and
		# the old scene's folder is as it was.
		check(_files(folder_b).size() == 3 and FileAccess.get_file_as_string(SCENE_B).contains(_named(_files(folder_b), box_stem)) and _stamps(folder_a) == stamps_a,
			"After a Save that wrote the scene, the baked file the part stopped using should be gone and the new one named in the scene (%s)." % str(_files(folder_b)))
		checked.append("a dropped saver is registered again before the scene is written")
		# With the saver gone for good (the plugin's handle taken away too) the files are written
		# right after the scene, which still holds the changed mesh; the next Save points it at them.
		CAD_PART.use_saver(null)
		ResourceSaver.remove_resource_format_saver(saver)
		box.set_expression("height", "40 mm")
		part.bake()
		await _frames(2)
		var said_before := _editor_said_saved
		var unsaved_before := EditorInterface.get_unsaved_scenes().size()
		if not await _save(SCENE_B):
			return
		await _frames(20)
		var text_held := FileAccess.get_file_as_string(SCENE_B)
		var box_node: MeshInstance3D = part.body_nodes().get(str(box.options.body_id))
		check(text_held.contains("[sub_resource type=\"ArrayMesh\"") and box_node != null and box_node.mesh != null and str(box_node.mesh.resource_path).begins_with(folder_b.path_join(box_stem)),
			"Without the saver, the saved scene should still hold the changed mesh while its file is written right after (mesh path %s)." % (box_node.mesh.resource_path if box_node != null and box_node.mesh != null else "none"))
		check(not _editor_saves or _editor_said_saved == said_before + 1, "Without the saver the part must still not save the scene itself (the editor saved %d times)." % (_editor_said_saved - said_before))
		var unsaved_after := EditorInterface.get_unsaved_scenes().size()
		if not await _save(SCENE_B):
			return
		await _frames(4)
		if _editor_saves:
			check(unsaved_before == 0 and unsaved_after == 1 and EditorInterface.get_unsaved_scenes().is_empty(),
				"Without the saver, the scene should be marked as changed after the Save and saved after the next (%d unsaved scenes before, %d after, %d after the next Save)." % [unsaved_before, unsaved_after, EditorInterface.get_unsaved_scenes().size()])
		check(not FileAccess.get_file_as_string(SCENE_B).contains("[sub_resource type=\"ArrayMesh\""), "The next Save should point the scene at the mesh file.")
		CAD_PART.use_saver(saver)
		checked.append("without the plugin's saver the files are written right after the scene, the scene is marked as changed, and the next Save points it at them")

	# 4. Both scenes load back; the new one to the same stored mesh.
	for path in [SCENE_A, SCENE_B]:
		var loaded_scene: PackedScene = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
		var copy: Node = loaded_scene.instantiate() if loaded_scene != null else null
		var copy_part: Node = copy.get_node_or_null("SavePart") if copy != null else null
		var same := false
		var bodies := 0
		if copy_part != null and copy_part.get("document") != null:
			var stored: Variant = copy_part.document.features[1].options.get("mesh")
			var back: RefCounted = stored.to_mesh() if stored is Resource else null
			same = back != null and str(back.digest()) == str(mesh.digest())
			for child in copy_part.get_children():
				bodies += 1 if child is MeshInstance3D and (child as MeshInstance3D).mesh != null else 0
		check(same and bodies == 2, "%s should load back with its two baked bodies and the same stored mesh (%d bodies)." % [path.get_file(), bodies])
		if copy != null:
			copy.free()
	checked.append("both scenes load back with their baked bodies and the same stored mesh")

	# (The part goes and the scene's tab closes before the editor does, so nothing of it is asked
	# for again.)
	plugin.scene_saved.disconnect(_on_editor_saved)
	scene.remove_child(part)
	part.free()
	await _frames(2)
	await _leave()
	_clean()
	# 6. Nothing outside this test's folder changed.
	var changed: PackedStringArray = _guard.changed_files()
	check(changed.is_empty(), "The saves should change no file outside this test's folder (%d changed: %s)." % [changed.size(), ", ".join(changed)])
	if _editor_saves:
		checked.append("saved with the editor's own Save (none of the project's resources was loaded); no file outside the test folder changed")
	else:
		checked.append("saved as the editor saves one scene, not with the editor's own Save (%d of the project's resource files are loaded in this editor, %s among them, and its Save would rewrite the marked ones); no file outside the test folder changed" % [loaded.size(), loaded[0]])
	print("PASS Holo Forge SAVE EDITOR: " + "; ".join(checked) + "." if failures.is_empty() else "FAIL Holo Forge SAVE EDITOR: %s" % str(failures))
	_tree.quit(0 if failures.is_empty() else 1)


func _on_editor_saved(_path: String) -> void:
	_editor_said_saved += 1


## Saves this test's scene to path (see the top for who saves). The editor has to show this test's
## scene: when it shows another one, the test ends there, failed, without saving anything.
func _save(path: String) -> bool:
	for i in 120:
		if is_instance_valid(_scene) and EditorInterface.get_edited_scene_root() == _scene:
			break
		if i % 30 == 0 and is_instance_valid(_scene) and str(_scene.scene_file_path) in [SCENE_A, SCENE_B]:
			EditorInterface.open_scene_from_path(str(_scene.scene_file_path))
		await _tree.process_frame
	if not is_instance_valid(_scene) or EditorInterface.get_edited_scene_root() != _scene or not str(_scene.scene_file_path) in [SCENE_A, SCENE_B]:
		var shown := EditorInterface.get_edited_scene_root()
		print("FAIL Holo Forge SAVE EDITOR: the editor shows %s, not this test's scene; nothing more was saved. %s" % [shown.scene_file_path if shown != null else "no scene", str(failures)])
		if is_instance_valid(_scene):
			for child in _scene.get_children():
				_scene.remove_child(child)
				child.free()
		await _leave()
		_clean()
		_tree.quit(1)
		return false
	if _editor_saves:
		# (Asked again right before the save: the editor saves only while it holds none of the
		# project's resources.)
		var loaded: PackedStringArray = _guard.loaded_user_resources()
		if not loaded.is_empty():
			print("FAIL Holo Forge SAVE EDITOR: %d of the project's resources got loaded during the test (%s); nothing more was saved. %s" % [loaded.size(), loaded[0], str(failures)])
			await _leave()
			_clean()
			_tree.quit(1)
			return false
		EditorInterface.save_scene_as(path, false)
		return true
	# The editor's order for one scene (measured in Godot 4.7.1): the nodes are told (the scene
	# still has its old path), the scene is packed and written, the plugins are asked for their
	# external data, the scene gets the path, the nodes are told again.
	_scene.propagate_notification(Node.NOTIFICATION_EDITOR_PRE_SAVE)
	var packed := PackedScene.new()
	var result := packed.pack(_scene)
	if result == OK:
		result = ResourceSaver.save(packed, path, ResourceSaver.FLAG_REPLACE_SUBRESOURCE_PATHS)
	check(result == OK, "The scene should be written to %s (%s)." % [path, error_string(result)])
	_plugin._save_external_data()
	_scene.scene_file_path = path
	_scene.propagate_notification(Node.NOTIFICATION_EDITOR_POST_SAVE)
	return true


## Closes this test's scene tab (the guard puts the editor's list of open scenes back when the
## run ends).
func _leave() -> void:
	for i in 120:
		if not is_instance_valid(_scene) or EditorInterface.get_edited_scene_root() == _scene:
			break
		if i % 30 == 0 and str(_scene.scene_file_path) in [SCENE_A, SCENE_B]:
			EditorInterface.open_scene_from_path(str(_scene.scene_file_path))
		await _tree.process_frame
	if is_instance_valid(_scene) and EditorInterface.get_edited_scene_root() == _scene:
		EditorInterface.close_scene()
		await _frames(4)


func _frames(count: int) -> void:
	for i in count:
		await _tree.process_frame


## The file among files whose name starts with stem ("" when none does).
func _named(files: PackedStringArray, stem: String) -> String:
	for file in files:
		if file.begins_with(stem):
			return file
	return ""


func _files(folder: String) -> PackedStringArray:
	return DirAccess.get_files_at(folder) if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(folder)) else PackedStringArray()


## File name -> [modified time, size, md5] of a folder's files.
func _stamps(folder: String) -> Dictionary:
	var stamps := {}
	for file in _files(folder):
		var path := folder.path_join(file)
		stamps[file] = [FileAccess.get_modified_time(path), FileAccess.get_file_as_bytes(path).size(), FileAccess.get_md5(path)]
	return stamps


## Removes everything this test wrote.
func _clean() -> void:
	for scene_path in [SCENE_A, SCENE_B]:
		var folder: String = scene_path.get_basename() + "_forge"
		for file in _files(folder):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(folder.path_join(file)))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(folder))
		for extra in [scene_path, scene_path + ".uid"]:
			if FileAccess.file_exists(extra):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(extra))
		for file in DirAccess.get_files_at("res://.godot/editor"):
			if file.begins_with(scene_path.get_file() + "-"):
				DirAccess.remove_absolute(ProjectSettings.globalize_path("res://.godot/editor".path_join(file)))
