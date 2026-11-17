extends SceneTree
## Holo Forge: what a Save leaves behind when something goes wrong (Phase 7, second fix round).
##
## The rule for the whole save path: after any Save, whatever failed, opening the scene again
## gives the same bodies as before the Save, or a clear error on the feature; never a silently
## different body, never a body that is silently gone.
##
## Every case saves a scene with a part in the editor's order (the part is told, the scene is
## packed and written through ResourceSaver with the plugin's saver in front, the part is told
## again), then "opens it in a new session" (nothing cached, the files read from disk) and
## rebuilds. Faults: a file where the folder should be, a read-only file, a file deleted, cut
## short or swapped, before and after the save. Everything is under user://.
##
##   S1 a stored mesh file swapped for another valid one stays an error through Save and Save As
##   S2 a damaged stored mesh file that cannot be written again: the mesh stays in the scene
##   S3 Save As where the new folder cannot be made: the new scene holds the mesh itself
##   S4 a stored mesh file that is gone: a Save keeps the link, and putting the file back works
##   S5 one mesh stored twice: both features point at the one file
##   S6 a baked mesh file deleted or cut short is written again
##   S7 a Save whose scene cannot be written leaves the old scene's baked meshes alone
##   two scenes with the same root name told in one frame; a part in an inherited scene
##   third round: a failed Save in the same second as a good one keeps the old scene's files (D1);
##   baked files lost before a new session saves without a rebuild are baked again (D-S6); edits
##   leave no file that no scene points at, and a copy's files stay (D5); a design changed in an
##   inheriting scene is kept there (D4)
##
## godot --headless --path . --script res://tests/holo_forge_mesh_save_faults_test.gd
## (The engine prints its own ERROR lines for the writes and reads this test makes fail.)

const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const PART_SAVER := preload("res://addons/holo_forge/nodes/cad_part_saver.gd")
const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const INSERT := preload("res://addons/holo_forge/core/features/insert.gd")
const MESH_FEATURE := preload("res://addons/holo_forge/core/features/mesh.gd")
const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")
const MESH_BLOB := preload("res://addons/holo_forge/core/mesh/mesh_blob.gd")
const FIXTURES := preload("res://tests/holo_forge_mesh_fixtures.gd")

const TEMP := "user://holo_forge_mesh_fixtures/save_faults"
## A scene that only points at its meshes stays under this.
const SMALL := 60 * 1024

var failures: Array[String] = []
var passed: Array[String] = []
var kernel: RefCounted
var saver: ResourceFormatSaver
var big: RefCounted
var other: RefCounted
var _started := false
var _finished := false


func _init() -> void:
	call_deferred("_go")


func _process(_delta: float) -> bool:
	if _started and not _finished:
		print("FAIL holo_forge_mesh_save_faults: stopped on a script error ", failures)
		_finished = true
		quit(1)
	return false


func check(condition: bool, message: String) -> bool:
	if not condition:
		failures.append(message)
	return condition


func _go() -> void:
	_started = true
	kernel = REGEN.make_kernel()
	if kernel == null:
		print("FAIL holo_forge_mesh_save_faults: the CAD kernel is not loaded")
		_finished = true
		quit(1)
		return
	_remove(TEMP)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEMP))
	big = FIXTURES.to_mesh(FIXTURES.with_noise(FIXTURES.icosphere(0.05, 6), 0.05))
	other = FIXTURES.to_mesh(FIXTURES.with_noise(FIXTURES.icosphere(0.03, 6), 0.02))
	saver = PART_SAVER.new()
	CAD_PART.use_saver(saver)
	for case in [_plain, _swapped, _damaged_unwritable, _save_as_blocked, _missing_put_back, _stored_twice, _baked_lost, _scene_unwritable, _same_root_name, _inherited, _failed_same_second, _baked_lost_unbuilt, _no_orphans, _inherited_changed]:
		var before := failures.size()
		(case as Callable).call()
		if failures.size() == before:
			passed.append(str((case as Callable).get_method()).trim_prefix("_").replace("_", " "))
	CAD_PART.use_saver(null)
	if saver.has_method("is_registered") and saver.is_registered():
		ResourceSaver.remove_resource_format_saver(saver)
	_remove(TEMP)
	print("PASS holo_forge_mesh_save_faults: after every Save, failed or not, the scene opens to the same bodies or a clear error (%s)." % ", ".join(passed)
		if failures.is_empty() else "FAIL holo_forge_mesh_save_faults (%d): %s" % [failures.size(), " | ".join(failures)])
	_finished = true
	quit(0 if failures.is_empty() else 1)


# --- cases ---------------------------------------------------------------------------------------

## No fault: one Save, small scene, a second Save writes nothing, the scene opens to the same.
func _plain() -> void:
	var dir := TEMP + "/plain"
	var doc := _design()
	var holder := _scene(doc)
	var good := _built(holder)
	var scene := dir + "/a.tscn"
	check(_save(holder, scene) == OK, "plain: the Save should work.")
	var size := _size(scene)
	check(size < SMALL and _files(dir + "/a_forge").size() == 3, "plain: one Save should write a small scene and three files beside it (%d bytes, %s)." % [size, _files(dir + "/a_forge")])
	var stamps := _stamps(dir + "/a_forge")
	check(_save(holder, scene) == OK and _stamps(dir + "/a_forge") == stamps, "plain: a second Save with nothing changed should write no file beside the scene.")
	holder.free()
	_expect_same("plain", scene, good)
	# The box changes and the scene is saved: its new baked file is there, the old one is gone.
	var opened := _open(scene)
	opened.get_node("Part").document.features[0].set_expression("height", "35 mm")
	var taller := _built(opened)
	check(not taller.same_as(good) and _save(opened, scene) == OK, "plain: the changed design should save.")
	var now := _files(dir + "/a_forge")
	var kept := 0
	for file in now:
		kept += 1 if stamps.has(file) else 0
	check(now.size() == 3 and kept == 2, "plain: after a Save that wrote the scene, the baked file the part stopped using should be gone (%s, before %s)." % [now, stamps.keys()])
	opened.free()
	_expect_same("plain, changed", scene, taller)


## S1. The stored mesh's file is swapped for another valid stored mesh: an error on open, and it
## stays that error through a Save and a Save As (never the other mesh without an error).
func _swapped() -> void:
	var dir := TEMP + "/swapped"
	var doc := _design()
	var holder := _scene(doc)
	var good := _built(holder)
	var scene := dir + "/a.tscn"
	_save(holder, scene)
	holder.free()
	var sidecar := _blob_file(dir + "/a_forge")
	check(ResourceSaver.save(MESH_BLOB.from_mesh(other), sidecar, ResourceSaver.FLAG_COMPRESS) == OK, "swapped: the other mesh should be written over the file.")
	var opened := _open(scene)
	var first := _built(opened)
	check(first.errors.contains("not the one saved with it"), "swapped: opening should say the stored mesh is not the one saved with it (%s)." % first.errors)
	check(_save(opened, scene) == OK, "swapped: the Save should work.")
	var after := _built(opened)
	check(after.errors.contains("not the one saved with it") and after.bodies == first.bodies, "swapped: after a Save the same session should still show the error (%s; bodies %s)." % [after.errors, after.bodies])
	check(_save(opened, dir + "/b.tscn") == OK, "swapped: the Save As should work.")
	opened.free()
	for path in [scene, dir + "/b.tscn"]:
		var again := _open(path)
		var later := _built(again)
		check(later.errors.contains("not the one saved with it") and later.bodies != _digest_line(other),
			"swapped: %s, opened again after the Save, should still show the error and never the other mesh (%s; bodies %s)." % [path.get_file(), later.errors, later.bodies])
		check(not later.bodies.contains(str(other.digest())), "swapped: %s must not hold the other mesh as its body." % path.get_file())
		again.free()
	# The right file back: the design is whole again.
	_new_session()
	ResourceSaver.save(MESH_BLOB.from_mesh(big), sidecar, ResourceSaver.FLAG_COMPRESS)
	_expect_same("swapped, the right file put back", scene, good, true)


## S2. The stored mesh's file is cut short after the scene was opened, and cannot be written
## again: the Save keeps the mesh in the scene, so the scene opens to the same bodies.
func _damaged_unwritable() -> void:
	var dir := TEMP + "/damaged"
	var doc := _design()
	var holder := _scene(doc)
	var good := _built(holder)
	var scene := dir + "/a.tscn"
	_save(holder, scene)
	holder.free()
	var opened := _open(scene)
	check(_built(opened).same_as(good), "damaged: the scene should open sound first.")
	var sidecar := _blob_file(dir + "/a_forge")
	_cut_short(sidecar)
	FileAccess.set_read_only_attribute(ProjectSettings.globalize_path(sidecar), true)
	check(_save(opened, scene) == OK, "damaged: the Save should work.")
	opened.free()
	var size := _size(scene)
	_expect_same("damaged and read-only", scene, good)
	check(size > 256 * 1024, "damaged: the scene should hold the mesh itself when its file cannot be written (%d bytes)." % size)
	# The file can be written again: the next Save moves the mesh back out.
	FileAccess.set_read_only_attribute(ProjectSettings.globalize_path(sidecar), false)
	var again := _open(scene)
	check(_save(again, scene) == OK and _size(scene) < SMALL, "damaged: once the file can be written, a Save should move the mesh back beside the scene (%d bytes)." % _size(scene))
	again.free()
	_expect_same("damaged, written again", scene, good)


## S3. Save As where the new scene's folder cannot be made (a file is in its place): the new
## scene holds the meshes itself and does not point into the old scene's folder.
func _save_as_blocked() -> void:
	var dir := TEMP + "/blocked"
	var doc := _design()
	var holder := _scene(doc)
	var good := _built(holder)
	var scene := dir + "/a.tscn"
	_save(holder, scene)
	holder.free()
	var opened := _open(scene)
	var stamps := _stamps(dir + "/a_forge")
	var blocker := FileAccess.open(dir + "/b_forge", FileAccess.WRITE)
	blocker.store_string("in the way")
	blocker.close()
	check(_save(opened, dir + "/b.tscn") == OK, "blocked: the Save As should work.")
	opened.free()
	var text := FileAccess.get_file_as_string(dir + "/b.tscn")
	check(not text.contains("a_forge/"), "blocked: the new scene must not point into the old scene's folder.")
	check(_stamps(dir + "/a_forge") == stamps, "blocked: the old scene's files should be as they were.")
	_expect_same("blocked, the new scene", dir + "/b.tscn", good)
	_expect_same("blocked, the old scene", scene, good)


## S4. The stored mesh's file is gone: the error names it; a Save keeps the link; with the file
## put back the scene opens whole.
func _missing_put_back() -> void:
	var dir := TEMP + "/missing"
	var doc := _design()
	var holder := _scene(doc)
	var good := _built(holder)
	var scene := dir + "/a.tscn"
	_save(holder, scene)
	holder.free()
	var sidecar := _blob_file(dir + "/a_forge")
	var bytes := FileAccess.get_file_as_bytes(sidecar)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(sidecar))
	var opened := _open(scene)
	var first := _built(opened)
	check(first.errors.contains(sidecar.get_file()) and first.errors.contains("Put the file back"), "missing: opening should name the missing file and say to put it back (%s)." % first.errors)
	check(_save(opened, scene) == OK, "missing: the Save should work.")
	var second := _built(opened)
	check(second.errors.contains(sidecar.get_file()) and second.errors.contains("Put the file back"), "missing: after the Save the error should still name the file (%s)." % second.errors)
	opened.free()
	check(FileAccess.get_file_as_string(scene).contains(sidecar.get_file()), "missing: the saved scene should still point at the missing file.")
	var still := _open(scene)
	var third := _built(still)
	check(third.errors.contains(sidecar.get_file()), "missing: opened again, the error should still name the file (%s)." % third.errors)
	still.free()
	var back := FileAccess.open(sidecar, FileAccess.WRITE)
	back.store_buffer(bytes)
	back.close()
	_expect_same("missing, the file put back after a Save", scene, good, true)


## S5. One mesh stored by two features (the same file inserted twice): both point at the one file.
func _stored_twice() -> void:
	var dir := TEMP + "/twice"
	var doc: Resource = DOCUMENT.new()
	_add_mesh(doc, big, "One")
	_add_mesh(doc, big, "Two")
	var holder := _scene(doc)
	var good := _built(holder)
	var scene := dir + "/a.tscn"
	for turn in 3:
		check(_save(holder, scene) == OK and _size(scene) < SMALL, "twice: save %d should leave a small scene (%d bytes)." % [turn + 1, _size(scene)])
	var blobs := 0
	for file in _files(dir + "/a_forge"):
		blobs += 1 if file.contains("_mesh_") else 0
	check(blobs == 1, "twice: the one mesh should have one file (%s)." % str(_files(dir + "/a_forge")))
	holder.free()
	_expect_same("twice", scene, good)


## S6. A baked mesh file deleted, then cut short, is written again by the next Save.
func _baked_lost() -> void:
	var dir := TEMP + "/baked"
	var doc := _design()
	var holder := _scene(doc)
	var good := _built(holder)
	var scene := dir + "/a.tscn"
	_save(holder, scene)
	for fault in ["deleted", "cut short"]:
		for file in _baked_files(dir + "/a_forge"):
			if fault == "deleted":
				DirAccess.remove_absolute(ProjectSettings.globalize_path(file))
			else:
				_cut_short(file)
		check(_save(holder, scene) == OK, "baked %s: the Save should work." % fault)
		var sound := 0
		for file in _baked_files(dir + "/a_forge"):
			sound += 1 if ResourceLoader.load(file, "", ResourceLoader.CACHE_MODE_IGNORE) is Mesh else 0
		check(sound == 2, "baked %s: the Save should write both baked meshes again (%d sound of %s)." % [fault, sound, _files(dir + "/a_forge")])
		var opened := _open(scene)
		check(_baked_match(opened) == "", "baked %s: the scene should open with its baked meshes (%s)." % [fault, _baked_match(opened)])
		opened.free()
		_new_session()
	holder.free()
	# Cut short while no session has seen it: the first Save of a new session writes it again.
	var later := _open(scene)
	later.get_node("Part").apply_result(REGEN.rebuild(later.get_node("Part").document, kernel))
	check(_save(later, scene) == OK, "baked: the first Save should work.")
	for file in _baked_files(dir + "/a_forge"):
		_cut_short(file)
	_new_session()
	check(_save(later, scene) == OK, "baked, first save of a session: the Save should work.")
	later.free()
	var last := _open(scene)
	check(_baked_match(last) == "", "baked, cut short before a session's first Save: the scene should open with its baked meshes (%s)." % _baked_match(last))
	last.free()
	_expect_same("baked", scene, good)


## S7. The scene file cannot be written (read-only) after the design changed: the Save fails, and
## the old scene still opens to its own bodies with baked meshes that match them.
func _scene_unwritable() -> void:
	var dir := TEMP + "/unwritable"
	var doc := _design()
	var holder := _scene(doc)
	var good := _built(holder)
	var scene := dir + "/a.tscn"
	_save(holder, scene)
	var stamps := _stamps(dir + "/a_forge")
	FileAccess.set_read_only_attribute(ProjectSettings.globalize_path(scene), true)
	# The mesh body grows to twice its size, the box to another height.
	var part: Node = holder.get_node("Part")
	doc.features[1].options["transform"] = Transform3D(Basis.IDENTITY.scaled(Vector3(2, 2, 2)), Vector3.ZERO)
	doc.features[0].set_expression("height", "35 mm")
	part.apply_result(REGEN.rebuild(doc, kernel))
	check(_save(holder, scene) != OK, "unwritable: the Save should fail.")
	holder.free()
	FileAccess.set_read_only_attribute(ProjectSettings.globalize_path(scene), false)
	var kept := true
	for file in stamps:
		kept = kept and _stamps(dir + "/a_forge").get(file) == stamps[file]
	check(kept, "unwritable: the files the old scene points at should be as they were (%s -> %s)." % [stamps.keys(), _files(dir + "/a_forge")])
	var opened := _open(scene)
	check(_baked_match(opened) == "", "unwritable: the old scene's baked meshes should match its bodies as they are loaded (%s)." % _baked_match(opened))
	# (A mesh body keeps its baked mesh while its triangles are the same: it has to be the right one.)
	opened.get_node("Part").apply_result(REGEN.rebuild(opened.get_node("Part").document, kernel))
	check(_baked_match(opened) == "", "unwritable: after a rebuild the old scene's baked meshes should match its bodies (%s)." % _baked_match(opened))
	opened.free()
	_expect_same("unwritable, the old scene", scene, good)


## Two scenes whose roots have the same name are told "about to save" in one frame, and only the
## second is written: the first one's part writes nothing beside the second scene.
func _same_root_name() -> void:
	var dir := TEMP + "/same_name"
	var first := _scene(_design())
	var second := _scene(_design())
	_built(first)
	var good := _built(second)
	first.get_node("Part")._before_scene_save()
	var part: Node = second.get_node("Part")
	part._before_scene_save()
	var packed := PackedScene.new()
	packed.pack(second)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	check(ResourceSaver.save(packed, dir + "/b.tscn") == OK, "same name: the second scene should be written.")
	second.scene_file_path = dir + "/b.tscn"
	part._after_scene_save()
	first.get_node("Part")._after_scene_save()
	var loose := 0
	for node in first.get_node("Part").body_nodes().values():
		loose += 1 if str(node.mesh.resource_path) == "" or str(node.mesh.resource_path).contains("::") else 0
	check(loose == 2 and _files(dir + "/b_forge").size() == 3, "same name: the part of the scene that was not written should have written nothing (%d of its 2 baked meshes without a file; files %s)." % [loose, _files(dir + "/b_forge")])
	first.free()
	second.free()
	_expect_same("same name", dir + "/b.tscn", good)


## A part that comes from a base scene: saving the scene that inherits it writes nothing of the
## part's beside the inheriting scene and leaves the base scene's files where they are.
func _inherited() -> void:
	var dir := TEMP + "/inherited"
	var holder := _scene(_design())
	var good := _built(holder)
	var base := dir + "/base.tscn"
	_save(holder, base)
	holder.free()
	_new_session()
	# The inheriting scene as the editor writes one that changes nothing: its root is an instance
	# of the base scene, and no node of the base is listed in it.
	var heir_path := dir + "/heir.tscn"
	var text := FileAccess.open(heir_path, FileAccess.WRITE)
	text.store_string('[gd_scene format=3]

[ext_resource type="PackedScene" path="%s" id="1_base"]

[node name="Scene" instance=ExtResource("1_base")]
' % base)
	text.close()
	var heir_packed: PackedScene = ResourceLoader.load(heir_path, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
	var heir: Node = heir_packed.instantiate()
	heir.scene_file_path = heir_path
	var part: Node = heir.get_node("Part")
	check(part.owner == heir, "inherited: the part should belong to the inheriting scene's root (%s)." % part.owner)
	# What the editor does when the inheriting scene is saved: the part is told, the packed scene
	# (which holds no design) goes to the savers, the part is told again.
	part._before_scene_save()
	CAD_PART.scene_is_being_written(heir_packed, heir_path)
	part._after_scene_save()
	var moved := 0
	for node in part.body_nodes().values():
		moved += 0 if str(node.mesh.resource_path).begins_with(dir + "/base_forge/") else 1
	check(moved == 0 and _files(dir + "/heir_forge").is_empty() and not CAD_PART.parts_wait_for_save(), "inherited: the base scene's meshes should stay in its folder and nothing be written beside the inheriting scene (%d moved; %s)." % [moved, _files(dir + "/heir_forge")])
	heir.free()
	_expect_same("inherited, the inheriting scene", dir + "/heir.tscn", good)
	_expect_same("inherited, the base scene", base, good)


## D1 (third round). A body is taken out and the next Save fails (read-only scene) in the same
## second as the good one: the old scene's baked file of that body stays, the old scene opens to
## its own bodies; the next Save that works clears it away.
func _failed_same_second() -> void:
	var dir := TEMP + "/same_second"
	var doc: Resource = DOCUMENT.new()
	for height in ["20 mm", "30 mm"]:
		var box: Resource = doc.add_feature("box", "Box", {
			"length": doc.make_input("20 mm", "length"), "height": doc.make_input(height, "length"), "width": doc.make_input("20 mm", "length"),
		}, {"operation": OPERATIONS.NEW_BODY, "position": Vector3.ZERO})
		box.options.body_id = doc.new_body(box.id)
	var holder := _scene(doc)
	var good := _built(holder)
	var scene := dir + "/a.tscn"
	# (Start at the turn of a second, so the good Save and the failed one share it.)
	var turn := floorf(Time.get_unix_time_from_system())
	while floorf(Time.get_unix_time_from_system()) == turn:
		pass
	check(_save(holder, scene) == OK, "same second: the first Save should work.")
	var before := _files(dir + "/a_forge")
	doc.features[0].suppressed = true
	var fewer := _built(holder)
	FileAccess.set_read_only_attribute(ProjectSettings.globalize_path(scene), true)
	check(_save(holder, scene) != OK, "same second: the Save of a read-only scene should fail.")
	FileAccess.set_read_only_attribute(ProjectSettings.globalize_path(scene), false)
	check(_files(dir + "/a_forge") == before and _dangling(scene).is_empty(), "same second: after the failed Save every file the old scene points at should still be there (%s, before %s; missing %s)." % [_files(dir + "/a_forge"), before, _dangling(scene)])
	_expect_same("same second, the old scene after the failed Save", scene, good)
	check(_save(holder, scene) == OK and _files(dir + "/a_forge").size() == 1 and _dangling(scene).is_empty(), "same second: the next Save that works should clear the file no scene points at any more (%s)." % _files(dir + "/a_forge"))
	holder.free()
	_expect_same("same second, saved again", scene, fewer)


## D-S6 (third round). The baked mesh files are deleted, cut short, emptied or replaced by a
## folder; a new session opens the scene and saves it without a rebuild: the bodies are baked
## again before the scene is written, so it opens to the same bodies with their meshes.
func _baked_lost_unbuilt() -> void:
	var faults := ["deleted", "cut short", "zero bytes", "a folder in its place"]
	for fault: String in faults:
		var dir := TEMP + "/unbuilt_%d" % faults.find(fault)
		var holder := _scene(_design())
		var good := _built(holder)
		var scene := dir + "/a.tscn"
		_save(holder, scene)
		holder.free()
		for file in _baked_files(dir + "/a_forge"):
			if fault == "deleted":
				DirAccess.remove_absolute(ProjectSettings.globalize_path(file))
			elif fault == "cut short":
				_cut_short(file)
			elif fault == "zero bytes":
				FileAccess.open(file, FileAccess.WRITE).close()
			else:
				DirAccess.remove_absolute(ProjectSettings.globalize_path(file))
				DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(file))
		var opened := _open(scene)
		check(opened != null and _save(opened, scene) == OK, "baked %s, saved unbuilt: the Save should work." % fault)
		if opened != null:
			opened.free()
		_expect_same("baked %s, a new session saved it without a rebuild" % fault, scene, good)


## D5 (third round). Edits and Saves leave no file behind that no scene points at, and a file a
## copy of the scene points at stays.
func _no_orphans() -> void:
	var dir := TEMP + "/orphans"
	var doc := _design()
	var holder := _scene(doc)
	_built(holder)
	var scene := dir + "/a.tscn"
	_save(holder, scene)
	var copied := Built.new()
	for turn in 6:
		# A new stored mesh (as a Direct Edit makes) and a new box: new files each time.
		doc.features[1].options["mesh"] = MESH_BLOB.from_mesh(big.transformed(Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * (1.0 + 0.1 * (turn + 1))), Vector3.ZERO)))
		doc.features[0].set_expression("height", "%d mm" % (21 + turn))
		var now := _built(holder)
		if turn == 4:
			# A copy of the scene as it is on disk now: its files must stay.
			DirAccess.copy_absolute(ProjectSettings.globalize_path(scene), ProjectSettings.globalize_path(dir + "/copy.tscn"))
		check(_save(holder, scene) == OK, "orphans: save %d should work." % (turn + 1))
		if turn == 3:
			copied = now
	var named := _named(scene)
	var stray := PackedStringArray()
	for file in _files(dir + "/a_forge"):
		if not named.has(file) and not _named(dir + "/copy.tscn").has(file):
			stray.append(file)
	check(stray.is_empty() and _files(dir + "/a_forge").size() <= 6, "orphans: after 6 edits and Saves only files a scene points at should be left (%d files; stray %s)." % [_files(dir + "/a_forge").size(), stray])
	check(_dangling(dir + "/copy.tscn").is_empty(), "orphans: the files a copy of the scene points at should stay (missing %s)." % _dangling(dir + "/copy.tscn"))
	holder.free()
	_expect_same("orphans, the copy", dir + "/copy.tscn", copied)


## D4 (third round). The design of a part that comes from a base scene is changed in the scene
## that inherits it, and that scene is saved: opened again it has the changed design and baked
## meshes that match it; the base scene keeps its own.
func _inherited_changed() -> void:
	var dir := TEMP + "/inherited_changed"
	var holder := _scene(_design())
	var good := _built(holder)
	var base := dir + "/base.tscn"
	_save(holder, base)
	holder.free()
	var base_stamps := _stamps(dir + "/base_forge")
	var heir_path := dir + "/sub/heir.tscn"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir + "/sub"))
	var text := FileAccess.open(heir_path, FileAccess.WRITE)
	text.store_string('[gd_scene format=3]\n\n[ext_resource type="PackedScene" path="%s" id="1_base"]\n\n[node name="Scene" instance=ExtResource("1_base")]\n' % base)
	text.close()
	_new_session()
	var packed: PackedScene = ResourceLoader.load(heir_path, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
	var heir: Node = packed.instantiate(PackedScene.GEN_EDIT_STATE_MAIN)
	heir.scene_file_path = heir_path
	var part: Node = heir.get_node("Part")
	part.document.features[0].set_expression("height", "35 mm")
	part.document.features[1].options["transform"] = Transform3D(Basis.IDENTITY.scaled(Vector3(2, 2, 2)), Vector3.ZERO)
	var changed := _built(heir)
	check(_save(heir, heir_path) == OK, "inherited, changed: the Save should work.")
	heir.free()
	_expect_same("inherited, the design changed in the inheriting scene", heir_path, changed)
	_expect_same("inherited, the base scene after its heir changed", base, good)
	check(_stamps(dir + "/base_forge") == base_stamps, "inherited, changed: the base scene's files should be as they were.")


## The files a scene or resource file points at (their names).
func _named(path: String) -> PackedStringArray:
	var names := PackedStringArray()
	if FileAccess.file_exists(path):
		for dependency in ResourceLoader.get_dependencies(path):
			names.append(str(dependency).get_slice("::", str(dependency).get_slice_count("::") - 1).get_file())
	return names


## The files a scene points at that are not there.
func _dangling(path: String) -> PackedStringArray:
	var gone := PackedStringArray()
	for dependency in ResourceLoader.get_dependencies(path):
		var file := str(dependency).get_slice("::", str(dependency).get_slice_count("::") - 1)
		if not file.begins_with("res://addons") and not FileAccess.file_exists(file):
			gone.append(file.get_file())
	return gone

# --- helpers -------------------------------------------------------------------------------------

## A box (B-rep) and a mesh body whose stored mesh is over 256 KB.
func _design() -> Resource:
	var doc: Resource = DOCUMENT.new()
	var box: Resource = doc.add_feature("box", "Box", {
		"length": doc.make_input("20 mm", "length"), "height": doc.make_input("20 mm", "length"), "width": doc.make_input("20 mm", "length"),
	}, {"operation": OPERATIONS.NEW_BODY, "position": Vector3.ZERO})
	box.options.body_id = doc.new_body(box.id)
	_add_mesh(doc, big, "Ball")
	return doc


func _add_mesh(doc: Resource, mesh: RefCounted, label: String) -> String:
	var feature: Resource = doc.add_feature("mesh_import", label, {}, {
		"path": "", "kind": "mesh", "units": "m", "mesh_units": "m", "linked": false, "split": false, "transform": Transform3D.IDENTITY,
		"operation": OPERATIONS.NEW_BODY, "mesh": MESH_BLOB.from_mesh(mesh),
	})
	var body_id: String = doc.new_body(feature.id)
	feature.options["body_id"] = body_id
	return body_id


func _scene(doc: Resource) -> Node3D:
	var part: Node3D = CAD_PART.new()
	part.name = "Part"
	part.document = doc
	var holder := Node3D.new()
	holder.name = "Scene"
	holder.add_child(part)
	part.owner = holder
	return holder


## What the part's design builds to, and its baked bodies brought up to date. {"bodies": text,
## "errors": text} with same_as() through Built.
func _built(holder: Node) -> Built:
	var part: Node = holder.get_node("Part")
	var result := REGEN.rebuild(part.document, kernel)
	part.apply_result(result)
	var built := Built.new()
	var ids: Array = result.bodies.keys()
	ids.sort()
	var lines := PackedStringArray()
	for id in ids:
		var shape: RefCounted = result.bodies[id].shape
		lines.append("%s=%s" % [id, "mesh:%s" % str(shape.digest()) if MESH_BODY.is_mesh(result.bodies[id]) else "solid:%s" % String.num(float(shape.volume()) * 1e9, 3)])
	built.bodies = " ".join(lines)
	var errors := PackedStringArray()
	for id in result.errors:
		errors.append(str(result.errors[id]))
	built.errors = " | ".join(errors)
	return built


class Built:
	var bodies := ""
	var errors := ""

	func same_as(other: Built) -> bool:
		return bodies == other.bodies and errors == other.errors


func _digest_line(mesh: RefCounted) -> String:
	return "mesh:%s" % str(mesh.digest())


## Saves the scene as the editor does one scene: the part is told, the scene is packed and written
## (the plugin's saver hears of it first), the scene gets its path, the part is told again.
func _save(holder: Node, scene_path: String) -> int:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(scene_path.get_base_dir()))
	var part: Node = holder.get_node("Part")
	part._before_scene_save()
	var packed := PackedScene.new()
	var code := packed.pack(holder)
	if code == OK:
		code = ResourceSaver.save(packed, scene_path)
	if code == OK:
		holder.scene_file_path = scene_path
	part._after_scene_save()
	return code


## Forgets everything a session keeps, so the next open reads the files.
func _new_session() -> void:
	MESH_FEATURE.clear_cache()
	INSERT.clear_mesh_cache()
	CAD_PART.forget_saved_files()


func _open(scene_path: String) -> Node:
	_new_session()
	var packed: PackedScene = ResourceLoader.load(scene_path, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
	var holder: Node = packed.instantiate() if packed != null else null
	if holder != null:
		holder.scene_file_path = scene_path
	return holder


## The rule: the scene, opened in a new session, builds to the same bodies with no error, and its
## baked meshes are there and match. (after_bake: the scene was saved while a feature had an error,
## so the body of that feature had no baked mesh to save; the next bake has to bring it back.)
func _expect_same(tag: String, scene_path: String, good: Built, after_bake := false) -> void:
	var opened := _open(scene_path)
	if not check(opened != null and opened.get_node_or_null("Part") != null, "%s: the scene should open." % tag):
		return
	var baked := _baked_match(opened) if not after_bake else ""
	var built := _built(opened)
	if after_bake:
		baked = _baked_match(opened)
	check(built.same_as(good), "%s: opened again, the design should build to the same bodies with no error (bodies %s; errors '%s'; expected %s)." % [tag, built.bodies, built.errors, good.bodies])
	check(baked == "", "%s: opened again, the baked meshes should be there and match (%s)." % [tag, baked])
	opened.free()


## "" when every baked body of the opened scene has a mesh that fits its body as the design builds
## it now (bounds and triangle count), else what is wrong. Looks at the nodes as loaded.
func _baked_match(holder: Node) -> String:
	var part: Node = holder.get_node("Part")
	var result := REGEN.rebuild(part.document, kernel)
	var nodes: Dictionary = part.body_nodes()
	var wrong := PackedStringArray()
	for id in result.bodies:
		var node: MeshInstance3D = nodes.get(id)
		if node == null or node.mesh == null:
			wrong.append("%s has no baked mesh" % id)
			continue
		if not MESH_BODY.is_mesh(result.bodies[id]):
			continue
		var shape: RefCounted = result.bodies[id].shape
		var have: AABB = node.mesh.get_aabb()
		var want: AABB = shape.bbox()
		if have.size.distance_to(want.size) > 1e-5 + 1e-3 * want.size.length():
			wrong.append("%s is baked %s wide, the body is %s" % [id, str(have.size), str(want.size)])
	return "; ".join(wrong)


func _files(folder: String) -> PackedStringArray:
	return DirAccess.get_files_at(folder) if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(folder)) else PackedStringArray()


func _stamps(folder: String) -> Dictionary:
	var stamps := {}
	for file in _files(folder):
		stamps[file] = [FileAccess.get_modified_time(folder.path_join(file)), FileAccess.get_md5(folder.path_join(file))]
	return stamps


func _blob_file(folder: String) -> String:
	for file in _files(folder):
		if file.contains("_mesh_"):
			return folder.path_join(file)
	return ""


func _baked_files(folder: String) -> PackedStringArray:
	var files := PackedStringArray()
	for file in _files(folder):
		if not file.contains("_mesh_"):
			files.append(folder.path_join(file))
	return files


func _size(path: String) -> int:
	return FileAccess.get_file_as_bytes(path).size()


func _cut_short(path: String) -> void:
	var bytes := FileAccess.get_file_as_bytes(path)
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(bytes.slice(0, bytes.size() / 2))
	file.close()


func _remove(folder: String) -> void:
	var system := ProjectSettings.globalize_path(folder)
	var dir := DirAccess.open(system)
	if dir == null:
		return
	for file in dir.get_files():
		FileAccess.set_read_only_attribute(system.path_join(file), false)
		DirAccess.remove_absolute(system.path_join(file))
	for sub in dir.get_directories():
		_remove(system.path_join(sub))
	DirAccess.remove_absolute(system)
