extends SceneTree
## Holo Forge: a binary resource file that is cut short or damaged is never handed to Godot's
## loader (which can crash on one, not just fail), and is treated as missing instead.
##   - RESOURCE_FILE.bytes_are_whole: whole compressed and plain files pass; every cut-short copy,
##     a wrong end mark, a block table that does not add up and junk fail; text files are safe
##   - the bake's file check (CadPart._baked_file_is_sound), the stored-mesh file check
##     (CadPart._file_is_sound) and loading a linked design (Insert.source_bodies) turn down a
##     cut-short file without loading it (a spy loader sees every load), and still load a whole one
##
## godot --headless --path . --script res://tests/holo_forge_resource_file_check_test.gd

const RESOURCE_FILE := preload("res://addons/holo_forge/core/resource_file_check.gd")
const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const INSERT := preload("res://addons/holo_forge/core/features/insert.gd")
const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const MESH_BLOB := preload("res://addons/holo_forge/core/mesh/mesh_blob.gd")

const TEMP := "user://holo_forge_resource_file_check"

var failures: Array[String] = []


## Records every load Godot is asked for under TEMP, then lets the real loader do it.
class SpyLoader extends ResourceFormatLoader:
	var loads: Array[String] = []

	func _get_recognized_extensions() -> PackedStringArray:
		return PackedStringArray(["res", "scn"])

	func _recognize_path(path: String, _type: StringName) -> bool:
		return path.begins_with(TEMP)

	func _handles_type(_type: StringName) -> bool:
		return true

	func _get_resource_type(path: String) -> String:
		return "Resource" if path.begins_with(TEMP) else ""

	func _load(path: String, _original_path: String, _use_sub_threads: bool, _cache_mode: int) -> Variant:
		loads.append(path)
		return ERR_FILE_UNRECOGNIZED


func _init() -> void:
	call_deferred("_run")


func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEMP))
	var mesh := _mesh()
	var packed_path := TEMP + "/packed.res"
	var plain_path := TEMP + "/plain.res"
	var text_path := TEMP + "/text.tres"
	check(ResourceSaver.save(mesh, packed_path, ResourceSaver.FLAG_COMPRESS) == OK, "the compressed mesh should save.")
	check(ResourceSaver.save(mesh, plain_path, 0) == OK, "the plain mesh should save.")
	check(ResourceSaver.save(mesh, text_path, 0) == OK, "the text mesh should save.")
	var packed := FileAccess.get_file_as_bytes(packed_path)
	var plain := FileAccess.get_file_as_bytes(plain_path)
	_whole_checks(packed, plain, packed_path, plain_path, text_path)
	var spy := SpyLoader.new()
	ResourceLoader.add_resource_format_loader(spy, true)
	_bake_check(spy, mesh, packed)
	_blob_check(spy, packed)
	_design_check(spy)
	ResourceLoader.remove_resource_format_loader(spy)
	_remove(TEMP)
	CAD_PART.forget_saved_files()
	print("PASS holo_forge_resource_file_check: cut-short and damaged resource files are turned down before Godot loads them; whole ones still load." if failures.is_empty()
		else "FAIL holo_forge_resource_file_check (%d): %s" % [failures.size(), " | ".join(failures)])
	quit(0 if failures.is_empty() else 1)


func _whole_checks(packed: PackedByteArray, plain: PackedByteArray, packed_path: String, plain_path: String, text_path: String) -> void:
	check(packed.slice(0, 4).get_string_from_ascii() == "RSCC" and packed.size() > 20000, "the compressed file should be RSCC and span many blocks (%d bytes)." % packed.size())
	check(RESOURCE_FILE.is_whole(packed_path), "a whole compressed file should pass.")
	check(RESOURCE_FILE.is_whole(plain_path), "a whole plain file should pass.")
	check(RESOURCE_FILE.safe_to_load(text_path), "a text resource should be safe to load.")
	check(RESOURCE_FILE.safe_to_load(packed_path) and RESOURCE_FILE.safe_to_load(plain_path), "whole binary files should be safe to load.")
	var missed := []
	for cut in [1, 2, 3, 4, 5, 8, 17, 100, 4096, packed.size() / 3, packed.size() / 2, packed.size() - 20, packed.size() - 16]:
		if RESOURCE_FILE.bytes_are_whole(packed.slice(0, packed.size() - cut)):
			missed.append("packed -%d" % cut)
	for cut in [1, 3, 4, 5, 100, plain.size() / 2, plain.size() - 16]:
		if RESOURCE_FILE.bytes_are_whole(plain.slice(0, plain.size() - cut)):
			missed.append("plain -%d" % cut)
	check(missed.is_empty(), "every cut-short copy should fail: %s passed." % str(missed))
	var wrong_end := packed.duplicate()
	wrong_end[wrong_end.size() - 1] = 0
	check(not RESOURCE_FILE.bytes_are_whole(wrong_end), "a wrong end mark should fail.")
	var lying := packed.duplicate()
	lying.encode_u32(16, lying.decode_u32(16) + 1)
	check(not RESOURCE_FILE.bytes_are_whole(lying), "a block table that does not add up should fail.")
	var huge := packed.duplicate()
	huge.encode_u32(8, 1)
	check(not RESOURCE_FILE.bytes_are_whole(huge), "a block size that makes a huge block table should fail.")
	var swapped := packed.duplicate()
	var first := swapped.decode_u32(16)
	var at := 16 + int(ceil(float(swapped.decode_u32(12)) / float(swapped.decode_u32(8)))) * 4
	for k in mini(first, 64):
		swapped[at + k] = 0xAB
	check(not RESOURCE_FILE.bytes_are_whole(swapped), "a block that no longer unpacks should fail.")
	check(not RESOURCE_FILE.bytes_are_whole(PackedByteArray()), "an empty file should fail.")
	check(not RESOURCE_FILE.bytes_are_whole("RSCCin the way, not a resource RSCC".to_ascii_buffer()), "junk between marks should fail.")
	check(not RESOURCE_FILE.safe_to_load(TEMP + "/not_there.res"), "a missing file should not be safe to load.")


func _bake_check(spy: SpyLoader, mesh: ArrayMesh, packed: PackedByteArray) -> void:
	CAD_PART.forget_saved_files()
	var path := TEMP + "/baked_cut.res"
	_write(path, packed.slice(0, packed.size() / 2))
	spy.loads.clear()
	check(not CAD_PART._baked_file_is_sound(path, mesh), "a cut-short baked file should not count as sound.")
	check(not spy.loads.has(path), "a cut-short baked file should not be loaded (loads: %s)." % str(spy.loads))
	var whole := TEMP + "/baked_whole.res"
	_write(whole, packed)
	spy.loads.clear()
	check(CAD_PART._baked_file_is_sound(whole, mesh), "a whole baked file of the same mesh should count as sound.")
	check(spy.loads.has(whole), "a whole baked file seen for the first time should still be loaded and compared (loads: %s)." % str(spy.loads))


func _blob_check(spy: SpyLoader, packed: PackedByteArray) -> void:
	CAD_PART.forget_saved_files()
	var path := TEMP + "/stored_mesh_cut.res"
	_write(path, packed.slice(0, packed.size() / 2))
	spy.loads.clear()
	check(not CAD_PART._file_is_sound(path, MESH_BLOB.new()), "a cut-short stored-mesh file should not count as sound.")
	check(not spy.loads.has(path), "a cut-short stored-mesh file should not be loaded (loads: %s)." % str(spy.loads))


func _design_check(spy: SpyLoader) -> void:
	var doc: Resource = DOCUMENT.new()
	var path := TEMP + "/linked_design.res"
	check(ResourceSaver.save(doc, path, ResourceSaver.FLAG_COMPRESS) == OK, "the design should save.")
	var bytes := FileAccess.get_file_as_bytes(path)
	_write(path, bytes.slice(0, bytes.size() - 7))
	spy.loads.clear()
	var result: Dictionary = INSERT.source_bodies(path, null)
	check(str(result.get("error", "")).contains("damaged"), "a cut-short linked design should give a clear error, got %s." % str(result))
	check(not spy.loads.has(path), "a cut-short linked design should not be loaded (loads: %s)." % str(spy.loads))


func _mesh() -> ArrayMesh:
	var sphere := SphereMesh.new()
	sphere.radial_segments = 96
	sphere.rings = 48
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sphere.get_mesh_arrays())
	mesh.surface_set_material(0, StandardMaterial3D.new())
	return mesh


func _write(path: String, bytes: PackedByteArray) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()


func _remove(folder: String) -> void:
	var system := ProjectSettings.globalize_path(folder)
	var dir := DirAccess.open(system)
	if dir == null:
		return
	for file in dir.get_files():
		DirAccess.remove_absolute(system.path_join(file))
	DirAccess.remove_absolute(system)
