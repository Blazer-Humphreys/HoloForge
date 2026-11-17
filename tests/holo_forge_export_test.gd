extends SceneTree
## Holo Forge export: a STEP of two bodies re-imports with their summed volume (and a BREP of
## all bodies too); STL and IGES files are written; every baked body saves as its own loadable
## mesh .res; every component and the top level save as their own scenes (.tscn holding exactly
## that component's body meshes, and .glb); and board-model saves into a temporary root are
## versioned (v001, then v002, nothing overwritten, continuing earlier _vN files), each adding
## one manifest record per file in the existing manifest's per-file style, with the manifest's
## text kept. Review checks: nested and moved components export where they sit, same-named bodies
## get distinct files, a hidden body keeps the .glb loadable by other tools, a ".." board name
## stays inside the root, bad requests are refused before writing, an empty result is rebuilt, an
## unreadable manifest is left alone, and a copy of the real manifest keeps its text. Fix checks:
## .tscn revisions and component scenes hold their own meshes (a later bake and scene save doesn't
## change them), Windows device names (CON, Aux, NUL ...) get a "_" instead of being skipped, a
## .glb leaves decals out and says so, a save that fails part-way leaves no partial revision, and
## appending keeps other tools' numbers byte for byte.
##
## godot --headless --path . --script res://tests/holo_forge_export_test.gd

const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const EXPORT := preload("res://addons/holo_forge/core/export.gd")
const MESH_IMPORT := preload("res://addons/holo_forge/core/import/mesh_import.gd")

const TEMP := "user://holo_forge_export_test"

var failures: Array[String] = []
var kernel: RefCounted
var doc: Resource
var part: Node3D
var result := {}
## Body ids.
var deck := ""
var pod := ""
var fin := ""
var nose := ""
## Component ids.
var engine := ""
var nose_comp := ""
var finished_checks := 0


func _init() -> void:
	call_deferred("run")


func run() -> void:
	kernel = REGEN.make_kernel()
	_expect(kernel != null, "The native kernel should load.")
	if kernel != null:
		_remove_tree(TEMP)
		await _build_part()
		_check_cad()
		_check_body_meshes()
		_check_components()
		_check_board_models()
		_check_nested_part()
		_check_board_edges()
		_check_next_version()
		_check_real_manifest()
		_check_linked_meshes()
		_check_reserved_names()
		_check_glb_decals()
		_check_failed_save()
		_check_manifest_text()
		# A script error aborts a check function silently; each one counts itself at its end.
		_expect(finished_checks == 9, "Every review check should run to its end (%d of 9)." % finished_checks)
		part.queue_free()
		_remove_tree(TEMP)
		_expect(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(TEMP)), "The temporary files should be cleaned up.")
	print("PASS holo_forge_export: STEP/BREP re-import with the summed volume, STL/IGES written, one mesh .res per body, one .tscn/.glb per component holding its bodies, board models saved v001 then v002 without overwriting, with one manifest record per file; exported scenes hold their own meshes, device names, glb decals, failed saves and manifest text handled." \
		if failures.is_empty() else "FAIL holo_forge_export")
	quit(0 if failures.is_empty() else 1)


# --- The part --------------------------------------------------------------------------------


## A deck at the top level, an Engine component with a pod and a fin, and a Nose component.
func _build_part() -> void:
	doc = DOCUMENT.new()
	engine = doc.new_component()
	doc.components[engine].name = "Engine"
	nose_comp = doc.new_component()
	doc.components[nose_comp].name = "Nose"
	deck = _add_box(Vector3(0.6, 0.02, 0.2), Vector3.ZERO, "")
	pod = _add_box(Vector3(0.1, 0.08, 0.1), Vector3(0.0, 0.0, 0.5), engine)
	fin = _add_box(Vector3(0.02, 0.1, 0.05), Vector3(0.2, 0.0, 0.5), engine)
	nose = _add_box(Vector3(0.12, 0.03, 0.06), Vector3(0.0, 0.0, -0.4), nose_comp)
	doc.bodies[deck].name = "Deck"
	part = CAD_PART.new()
	part.name = "Board"
	part.document = doc
	root.add_child(part)
	# bake() only runs in the editor; this is the same rebuild + apply it does.
	result = REGEN.rebuild(doc, kernel)
	part.apply_result(result)
	await process_frame
	_expect((result.errors as Dictionary).is_empty(), "The part should rebuild cleanly (%s)." % result.errors)
	_expect((part.body_nodes() as Dictionary).size() == 4 and (part.component_nodes() as Dictionary).size() == 2,
		"The part should bake 4 bodies in 2 components.")


func _add_box(size: Vector3, position: Vector3, component: String) -> String:
	var feature: Resource = doc.add_feature("box", "Box", {
		"length": doc.make_input("%f m" % size.x, "length"), "height": doc.make_input("%f m" % size.y, "length"),
		"width": doc.make_input("%f m" % size.z, "length"),
	}, {"operation": OPERATIONS.NEW_BODY, "position": position})
	var body_id: String = doc.new_body(feature.id)
	feature.options.body_id = body_id
	doc.bodies[body_id].component = component
	return body_id


func _volume(body_id: String) -> float:
	return result.bodies[body_id].shape.volume()


# --- CAD exchange ----------------------------------------------------------------------------


func _check_cad() -> void:
	var step := TEMP.path_join("cad/two_bodies.step")
	var error := EXPORT.export_cad(kernel, result, [deck, pod], step)
	_expect(error == "", "The STEP export should succeed (%s)." % error)
	var expected := 0.6 * 0.02 * 0.2 + 0.1 * 0.08 * 0.1
	_expect(absf(_volume(deck) + _volume(pod) - expected) <= expected * 1e-6, "The two bodies should have their exact volumes.")
	var back: RefCounted = kernel.import_file(step)
	var v: float = back.volume() if back != null and not back.is_null() else -1.0
	_expect(absf(v - expected) <= expected * 1e-6, "The STEP should re-import with the summed volume %s m3 (got %s; %s)." % [
		String.num_scientific(expected), String.num_scientific(v), kernel.get_last_error()])
	_expect(back != null and back.solids().size() == 2, "The STEP should hold two solids.")

	var all := 0.0
	for body_id in result.bodies:
		all += _volume(body_id)
	var brep := TEMP.path_join("cad/all.brep")
	error = EXPORT.export_cad(kernel, result, [], brep)
	back = kernel.import_file(brep) if error == "" else null
	v = back.volume() if back != null and not back.is_null() else -1.0
	_expect(error == "" and absf(v - all) <= all * 1e-6, "A BREP of every body should re-import with their summed volume (%s, %s)." % [error, v])

	for ext in ["stl", "iges"]:
		var path := TEMP.path_join("cad/all." + ext)
		error = EXPORT.export_cad(kernel, result, [], path)
		_expect(error == "" and _size(path) > 0, "The .%s export should write a non-empty file (%s)." % [ext, error])

	# Upper-case and short extensions pick the same writers.
	for file in ["ALL.STEP", "all.stp", "all.igs"]:
		var path := TEMP.path_join("cad/" + file)
		error = EXPORT.export_cad(kernel, result, [], path)
		back = kernel.import_file(path) if error == "" else null
		v = back.volume() if back != null and not back.is_null() else -1.0
		_expect(error == "" and absf(v - all) <= all * 1e-6, "%s should export and re-import with every body (%s, %s)." % [file, error, v])
	_expect(EXPORT.export_cad(kernel, {}, [], TEMP.path_join("cad/empty.step")) != "", "An empty design should be refused.")

	_expect(EXPORT.export_cad(kernel, result, [], TEMP.path_join("cad/all.obj")) != "", "An unsupported format should be refused.")
	_expect(EXPORT.export_cad(kernel, result, ["body99"], TEMP.path_join("cad/missing.step")) != "", "An unknown body should be refused.")
	_expect(EXPORT.export_cad(null, result, [], TEMP.path_join("cad/none.step")) != "", "Exporting without a kernel should be refused.")

	# STL to non-ASCII names and folders: written under their own names (the kernel opens UTF-8
	# paths as UTF-16), with no garbled copies, and readable again.
	_remove_tree(ProjectSettings.globalize_path(TEMP.path_join("cad_unicode")))
	for file in ["board_café.stl", "船.stl", "Niño/deck.stl"]:
		var path := TEMP.path_join("cad_unicode/" + file)
		error = EXPORT.export_cad(kernel, result, [deck], path)
		var read := MESH_IMPORT.read_stl(path, "mm") if error == "" else {"error": error, "triangles": 0}
		_expect(error == "" and _size(path) == 84 + 12 * 50 and str(read.error) == "" and int(read.triangles) == 12,
			"%s should export under its own name as a 12-triangle box (%s, %d bytes, %s)." % [file, error, _size(path), read.get("error", "")])
	var listed := Array(DirAccess.get_files_at(ProjectSettings.globalize_path(TEMP.path_join("cad_unicode"))))
	listed.sort()
	var expected_files := ["board_café.stl", "船.stl"]
	expected_files.sort()
	_expect(listed == expected_files, "Only the requested STL files should be written, with no garbled copies (%s)." % [listed])


# --- Separate objects ------------------------------------------------------------------------


func _check_body_meshes() -> void:
	var folder := TEMP.path_join("meshes")
	var written: Array = EXPORT.export_body_meshes(part, folder)
	var nodes: Dictionary = part.body_nodes()
	_expect(written.size() == 4, "Every body should save its own mesh (got %d)." % written.size())
	for body_id in nodes:
		var node: MeshInstance3D = nodes[body_id]
		var path := folder.path_join(str(node.name) + ".res")
		_expect(written.has(path), "%s should be saved as %s." % [node.name, path.get_file()])
		var mesh := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as ArrayMesh
		_expect(mesh != null and mesh.get_surface_count() == 1 and _aabb_close(mesh.get_aabb(), node.mesh.get_aabb()),
			"%s should load back as an ArrayMesh with the body's bounds." % path.get_file())


func _check_components() -> void:
	var folder := TEMP.path_join("scenes")
	var written: Array = EXPORT.export_components(part, folder, "tscn")
	var expected := {
		"Board.tscn": ["Deck"], "Engine.tscn": ["Body2", "Body3"], "Nose.tscn": ["Body4"],
	}
	_expect(written.size() == 3, "The top level and both components should save as scenes (got %s)." % [written])
	var bodies: Dictionary = part.body_nodes()
	for file in expected:
		var path := folder.path_join(file)
		_expect(written.has(path), "%s should be written." % file)
		var packed := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
		if packed == null:
			_expect(false, "%s should load as a PackedScene." % file)
			continue
		var scene := packed.instantiate()
		_expect(not scene.has_meta(EXPORT.COMPONENT_META), "%s's root should be a plain node." % file)
		var names := []
		for mesh_node in scene.find_children("*", "MeshInstance3D", true, false):
			names.append(str(mesh_node.name))
			_expect(not mesh_node.has_meta(EXPORT.BODY_META), "Exported bodies should be plain nodes.")
			var source: MeshInstance3D = null
			for body_id in bodies:
				if str(bodies[body_id].name) == str(mesh_node.name):
					source = bodies[body_id]
			_expect(source != null and (mesh_node as MeshInstance3D).mesh != null \
				and _aabb_close((mesh_node as MeshInstance3D).get_aabb(), source.get_aabb()),
				"%s in %s should carry the body's mesh." % [mesh_node.name, file])
		names.sort()
		_expect(names == expected[file], "%s should hold exactly %s (got %s)." % [file, expected[file], names])
		scene.free()

	var glb_folder := TEMP.path_join("glb")
	var glbs: Array = EXPORT.export_components(part, glb_folder, "glb")
	_expect(glbs.size() == 3, "Each scene should also export as .glb (got %s)." % [glbs])
	for path in glbs:
		_expect(str(path).get_extension() == "glb" and _size(path) > 0, "%s should be a non-empty .glb." % path)
	var gltf := GLTFDocument.new()
	var state := GLTFState.new()
	if gltf.append_from_file(glb_folder.path_join("Engine.glb"), state) == OK:
		var scene := gltf.generate_scene(state)
		var meshes := scene.find_children("*", "MeshInstance3D", true, false)
		_expect(meshes.size() == 2, "Engine.glb should load back with its two body meshes (got %d)." % meshes.size())
		scene.free()
	else:
		_expect(false, "Engine.glb should load back.")
	_expect(EXPORT.export_components(part, glb_folder, "fbx").is_empty(), "An unsupported scene format should write nothing.")


# --- Board models ----------------------------------------------------------------------------


func _check_board_models() -> void:
	var board_root := TEMP.path_join("boards")
	var manifest_path := board_root.path_join(EXPORT.MANIFEST_NAME)
	var first: Dictionary = EXPORT.board_model_export(part, kernel, result, "TestBoard", ["glb", "step", "tres"], board_root)
	var folder := board_root.path_join("TestBoard")
	_expect(first.error == "" and first.version == 1, "The first save should be v001 (%s)." % first)
	var first_paths := []
	for ext in ["glb", "step", "tres"]:
		first_paths.append(folder.path_join("TestBoard_v001." + ext))
	_expect(first.paths == first_paths, "The first save should write %s (got %s)." % [first_paths, first.paths])
	var hashes := {}
	for path in first_paths:
		_expect(_size(path) > 0, "%s should be written." % path.get_file())
		hashes[path] = FileAccess.get_sha256(path)
	var manifest := _read_json(manifest_path)
	var files: Array = manifest.get("files", [])
	_expect(files.size() == 3, "A missing manifest should be created with one record per file (got %d)." % files.size())
	_expect(str(manifest.get("policy", "")) == EXPORT.MANIFEST_POLICY and manifest.has("updated_board_models_directory"),
		"A new manifest should use the board-model manifest's layout.")
	# Each record is a flat per-file receipt like the manifest's existing entries: the file name
	# with its extension, a source path, the file's full path, its size and hash. The design was
	# never saved, so the revision's own .tres is the source.
	var tres_path := _system(folder.path_join("TestBoard_v001.tres"))
	for i in mini(files.size(), 3):
		var record: Dictionary = files[i]
		var path: String = first_paths[i]
		var keys: Array = record.keys().slice(0, 6)
		_expect(keys == ["file", "source", "destination", "bytes", "sha256", "verified"],
			"A record should start with the manifest's own keys in its order (%s)." % [keys])
		_expect(str(record.get("file", "")) == path.get_file() and str(record.get("destination", "")) == _system(path)
			and str(record.get("source", "")) == tres_path and str(record.get("revision", "")) == "TestBoard_v001"
			and int(record.get("version", 0)) == 1 and str(record.get("tool", "")) == "Holo Forge" and not record.has("files"),
			"The record of %s should name the file, its path, its source and its revision (%s)." % [path.get_file(), record])
	var problems := _receipt_problems(manifest_path)
	_expect(problems.is_empty(), "Every manifest record should verify as a receipt (%s)." % [problems])

	var second: Dictionary = EXPORT.board_model_export(part, kernel, result, "TestBoard", ["glb", "step", "tres"], board_root)
	_expect(second.error == "" and second.version == 2, "The second save should be v002 (%s)." % second)
	for path in second.paths:
		_expect(str(path).get_file().begins_with("TestBoard_v002.") and _size(path) > 0, "%s should be a v002 file." % path)
	for path in first_paths:
		_expect(FileAccess.get_sha256(path) == hashes[path], "%s should not be overwritten." % path.get_file())
	files = _read_json(manifest_path).get("files", [])
	_expect(files.size() == 6 and str(files[5].get("revision", "")) == "TestBoard_v002" and str(files[3].get("file", "")) == "TestBoard_v002.glb",
		"The manifest should gain the second revision's three records.")
	problems = _receipt_problems(manifest_path)
	_expect(problems.is_empty(), "Every record should still verify after the second save (%s)." % [problems])

	# The editable source loads back as the same design.
	var source := ResourceLoader.load(folder.path_join("TestBoard_v002.tres"), "", ResourceLoader.CACHE_MODE_IGNORE)
	if source != null and source.get_script() == DOCUMENT:
		_expect(source.features.size() == doc.features.size() and source.components.size() == 2 and source.bodies.size() == 4,
			"The saved document should hold the same features, bodies and components.")
		var again := REGEN.rebuild(source, kernel)
		var total := 0.0
		var expected := 0.0
		for body_id in result.bodies:
			expected += _volume(body_id)
			total += again.bodies[body_id].shape.volume() if again.bodies.has(body_id) else 0.0
		_expect(absf(total - expected) <= expected * 1e-6, "The saved document should rebuild to the same volume.")
	else:
		_expect(false, "TestBoard_v002.tres should load as a CadDocument.")

	# The step re-imports to the same volume as the design.
	var back: RefCounted = kernel.import_file(folder.path_join("TestBoard_v002.step"))
	var all := 0.0
	for body_id in result.bodies:
		all += _volume(body_id)
	_expect(back != null and absf(back.volume() - all) <= all * 1e-6, "The board STEP should hold every body.")

	_check_existing_manifest(TEMP.path_join("boards_existing"))

	var bad: Dictionary = EXPORT.board_model_export(part, kernel, result, "TestBoard", ["fbx"], board_root)
	_expect(bad.error != "" and (bad.paths as Array).is_empty() and not FileAccess.file_exists(folder.path_join("TestBoard_v003.fbx")),
		"An unsupported format should be refused before anything is written.")
	_expect((_read_json(manifest_path).get("files", []) as Array).size() == 6, "A refused save should not touch the manifest.")


## A root that already has a manifest (CRLF, whole-number sizes, like the real one) and an
## older revision in the root itself: the new save continues the numbering, the old entry's text
## is kept exactly, and one record is added.
func _check_existing_manifest(board_root: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(board_root))
	var old_entry := "    {\r\n      \"file\": \"TestBoard_v4.glb\",\r\n      \"source\": \"C:\\\\old\\\\TestBoard_v4.glb\",\r\n      \"destination\": \"C:\\\\boards\\\\TestBoard_v4.glb\",\r\n      \"bytes\": 70766428,\r\n      \"sha256\": \"0E853CF9\",\r\n      \"verified\": true\r\n    }"
	var text := "{\r\n  \"created\": \"2026-10-09\",\r\n  \"updated_board_models_directory\": \"C:\\\\boards\",\r\n  \"policy\": \"Keep versions.\",\r\n  \"files\": [\r\n" + old_entry + "\r\n  ]\r\n}\r\n"
	_write_text(board_root.path_join(EXPORT.MANIFEST_NAME), text)
	_write_text(board_root.path_join("TestBoard_v4.glb"), "old revision")
	var saved: Dictionary = EXPORT.board_model_export(part, kernel, result, "TestBoard", ["tscn"], board_root)
	_expect(saved.error == "" and saved.version == 5, "A save should continue after TestBoard_v4 in the root (%s)." % saved)
	var path := board_root.path_join("TestBoard/TestBoard_v005.tscn")
	_expect(_size(path) > 0, "The whole-part .tscn should be written.")
	var packed := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if packed != null:
		var scene := packed.instantiate()
		_expect(scene.find_children("*", "MeshInstance3D", true, false).size() == 4, "The whole-part scene should hold all four bodies.")
		scene.free()
	var after := FileAccess.get_file_as_string(board_root.path_join(EXPORT.MANIFEST_NAME))
	_expect(after.begins_with("{\r\n  \"created\": \"2026-10-09\",") and after.contains(old_entry) and not after.contains("70766428.0"),
		"The existing manifest should keep its order, whole numbers, line endings and entry.")
	var files: Array = _read_json(board_root.path_join(EXPORT.MANIFEST_NAME)).get("files", [])
	_expect(files.size() == 2 and str(files[1].get("file", "")) == "TestBoard_v005.tscn", "The existing manifest should gain one record.")
	_expect(not after.replace("\r\n", "").contains("\n"), "The manifest should keep CRLF line endings.")


# --- Review checks ---------------------------------------------------------------------------


## A part with Inner nested in Outer (both moved), a "Twin" body in each (Inner's hidden):
## component scenes sit where the component sits in the part, nested bodies also land in the
## parent's scene, same-named bodies get distinct .res files, and a hidden body doesn't make the
## .glb require an extension other tools may lack.
func _check_nested_part() -> void:
	var nested_doc: Resource = DOCUMENT.new()
	var outer: String = nested_doc.new_component()
	nested_doc.components[outer].name = "Outer"
	nested_doc.active_component = outer
	var inner: String = nested_doc.new_component()
	nested_doc.components[inner].name = "Inner"
	nested_doc.active_component = ""
	var twins := []
	for component in [outer, inner]:
		var feature: Resource = nested_doc.add_feature("box", "Box", {
			"length": nested_doc.make_input("0.1 m", "length"), "height": nested_doc.make_input("0.1 m", "length"),
			"width": nested_doc.make_input("0.1 m", "length"),
		}, {"operation": OPERATIONS.NEW_BODY, "position": Vector3(0.5 * twins.size(), 0.0, 0.0)})
		var body_id: String = nested_doc.new_body(feature.id)
		feature.options.body_id = body_id
		nested_doc.bodies[body_id].component = component
		nested_doc.bodies[body_id].name = "Twin"
		twins.append(body_id)
	nested_doc.bodies[twins[1]].visible = false
	var nested := CAD_PART.new()
	nested.name = "Nested"
	nested.document = nested_doc
	root.add_child(nested)
	nested.apply_result(REGEN.rebuild(nested_doc, kernel))
	var nodes: Dictionary = nested.component_nodes()
	if not (nodes.has(outer) and nodes.has(inner)):
		_expect(false, "The nested part should bake both components.")
		nested.free()
		return
	(nodes[outer] as Node3D).position = Vector3(1.0, 0.0, 0.0)
	(nodes[inner] as Node3D).position = Vector3(0.0, 2.0, 0.0)

	var folder := TEMP.path_join("nested")
	var meshes: Array = EXPORT.export_body_meshes(nested, folder)
	_expect(meshes == [folder.path_join("Twin.res"), folder.path_join("Twin_2.res")],
		"Same-named bodies should save as Twin.res and Twin_2.res (got %s)." % [meshes])
	var scenes: Array = EXPORT.export_components(nested, folder, "tscn")
	_expect(scenes == [folder.path_join("Outer.tscn"), folder.path_join("Inner.tscn")],
		"A part without top-level bodies should save only its components (got %s)." % [scenes])
	var expected := {"Outer.tscn": [Vector3(1, 0, 0), 2], "Inner.tscn": [Vector3(1, 2, 0), 1]}
	for file in expected:
		var packed := ResourceLoader.load(folder.path_join(file), "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
		if packed == null:
			_expect(false, "%s should load." % file)
			continue
		var scene := packed.instantiate() as Node3D
		_expect(scene.transform.origin.distance_to(expected[file][0]) < 1e-6,
			"%s should sit where the component sits in the part (%s)." % [file, scene.transform.origin])
		_expect(scene.find_children("*", "MeshInstance3D", true, false).size() == expected[file][1],
			"%s should hold its own and its nested components' bodies." % file)
		scene.free()

	var glbs: Array = EXPORT.export_components(nested, folder, "glb")
	var inner_glb := folder.path_join("Inner.glb")
	_expect(glbs.has(inner_glb), "Inner.glb should be written (%s)." % [glbs])
	var gltf_json := _glb_json(inner_glb)
	_expect(not gltf_json.is_empty() and (gltf_json.get("extensionsRequired", []) as Array).is_empty(),
		"A hidden body should not make the .glb require an extension (%s)." % [gltf_json.get("extensionsRequired", [])])
	var gltf := GLTFDocument.new()
	var state := GLTFState.new()
	if gltf.append_from_file(inner_glb, state) == OK:
		var scene := gltf.generate_scene(state)
		_expect(scene.find_children("*", "MeshInstance3D", true, false).size() == 1, "The hidden body should still be in Inner.glb.")
		scene.free()
	else:
		_expect(false, "Inner.glb should load back.")
	nested.free()
	finished_checks += 1


## Board-model saves that must be refused before writing, a name that would leave the folder,
## the rebuild of an empty result, and a manifest that can't be read.
func _check_board_edges() -> void:
	var edge_root := TEMP.path_join("boards_edges")
	# ".." must not climb out of the board folder: it falls back to the part's name.
	var dots: Dictionary = EXPORT.board_model_export(part, kernel, result, "..", ["tres"], edge_root)
	var expected_path := edge_root.path_join("Board/Board_v001.tres")
	_expect(dots.error == "" and dots.paths == [expected_path], "A '..' name should save as Board/Board_v001.tres (%s)." % dots)
	_expect(not FileAccess.file_exists(TEMP.path_join(".._v001.tres")), "A '..' name should not write outside the root.")

	# An empty result is rebuilt from the document for CAD formats.
	var rebuilt: Dictionary = EXPORT.board_model_export(part, kernel, {}, "Rebuilt", ["step"], edge_root)
	var all := 0.0
	for body_id in result.bodies:
		all += _volume(body_id)
	var back: RefCounted = kernel.import_file(edge_root.path_join("Rebuilt/Rebuilt_v001.step")) if rebuilt.error == "" else null
	_expect(back != null and absf(back.volume() - all) <= all * 1e-6, "An empty result should be rebuilt for the STEP (%s)." % rebuilt)

	# Refusals leave nothing behind: no folder, no version, no manifest change.
	var bare := CAD_PART.new()
	bare.name = "Bare"
	root.add_child(bare)
	var manifest_before := FileAccess.get_file_as_string(edge_root.path_join(EXPORT.MANIFEST_NAME))
	var refusals := [
		[bare, kernel, {}, ["tres"]], [bare, kernel, {}, ["glb"]], [bare, kernel, {}, ["step"]],
		[part, null, result, ["step"]],
	]
	for refusal in refusals:
		var out: Dictionary = EXPORT.board_model_export(refusal[0], refusal[1], refusal[2], "Refused", refusal[3], edge_root)
		_expect(out.error != "" and out.version == 0 and (out.paths as Array).is_empty(), "%s should be refused (%s)." % [refusal[3], out])
	_expect(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(edge_root.path_join("Refused"))),
		"A refused save should not create its folder.")
	_expect(FileAccess.get_file_as_string(edge_root.path_join(EXPORT.MANIFEST_NAME)) == manifest_before, "Refusals should not touch the manifest.")
	bare.free()

	# A manifest that doesn't parse is left as it is, and the files are still saved.
	var broken_root := TEMP.path_join("boards_broken")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(broken_root))
	_write_text(broken_root.path_join(EXPORT.MANIFEST_NAME), "not json {")
	var broken: Dictionary = EXPORT.board_model_export(part, kernel, result, "TestBoard", ["tres"], broken_root)
	_expect((broken.paths as Array).size() == 1 and str(broken.error).contains(EXPORT.MANIFEST_NAME),
		"An unreadable manifest should be reported while the files are saved (%s)." % broken)
	_expect(FileAccess.get_file_as_string(broken_root.path_join(EXPORT.MANIFEST_NAME)) == "not json {", "An unreadable manifest should be left unchanged.")
	finished_checks += 1


func _check_next_version() -> void:
	var folder := TEMP.path_join("versions")
	_expect(EXPORT.next_version(folder, "Hull") == 1, "A missing folder should start at version 1.")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder.path_join("Hull_v7")))
	for file in ["Hull_v2_old.glb", "hull_V3.GLB", "Hull_v.glb", "Hull_vX.glb", "Hulls_v9.glb", "Hull_v12_notes.txt"]:
		_write_text(folder.path_join(file), "x")
	_expect(EXPORT.next_version(folder, "Hull") == 8, "Version 8 should follow the Hull_v7 folder and hull_V3.GLB (got %d)." % EXPORT.next_version(folder, "Hull"))
	finished_checks += 1


## The real manifest (read only) keeps every byte of its existing text when an entry is added
## to a copy of it.
func _check_real_manifest() -> void:
	var real := EXPORT.board_models_root().path_join(EXPORT.MANIFEST_NAME)
	if EXPORT.board_models_root() == "" or not FileAccess.file_exists(real):
		finished_checks += 1
		return
	var text := FileAccess.get_file_as_string(real)
	var copy_root := TEMP.path_join("real_manifest_copy")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(copy_root))
	_write_text(copy_root.path_join(EXPORT.MANIFEST_NAME), text)
	var error: String = EXPORT.append_manifest_records(copy_root, [{"file": "Probe_v001.glb", "source": "", "destination": "C:\\probe\\Probe_v001.glb",
		"bytes": 1, "sha256": "AB", "verified": true}])
	var after := FileAccess.get_file_as_string(copy_root.path_join(EXPORT.MANIFEST_NAME))
	# Everything up to the last existing entry's closing brace, and everything after it, is unchanged.
	var head := text.substr(0, text.rfind("]"))
	head = head.substr(0, head.rfind("}") + 1)
	var tail := text.substr(head.length())
	var before_count := (_read_json(real).get("files", []) as Array).size()
	var after_count := (_read_json(copy_root.path_join(EXPORT.MANIFEST_NAME)).get("files", []) as Array).size()
	var nl := "\r\n" if text.contains("\r\n") else "\n"
	_expect(error == "" and after.begins_with(head + "," + nl + "    {" + nl + "      \"file\": \"Probe_v001.glb\",") and after.ends_with(tail) and after_count == before_count + 1,
		"Adding to a copy of the real manifest should keep its text and add one record in its style (%s)." % error)
	finished_checks += 1


# --- Fix checks ------------------------------------------------------------------------------


## Every scene save puts each baked mesh in <scene>_forge/<part>_<body>.res and makes the mesh use
## that file (CadPart.externalize_meshes, which only runs in the editor, so its save and
## take_over_path are repeated here, for the collision shape too). A .tscn revision and the
## component scenes exported then must hold their own geometry: after the 0.6 m deck becomes
## 1.2 m, is re-baked and the scene saved again (rewriting the same files), v001 and the top-level
## scene Linked.tscn still load the 0.6 m deck.
func _check_linked_meshes() -> void:
	var linked_doc: Resource = DOCUMENT.new()
	var feature: Resource = linked_doc.add_feature("box", "Box", {
		"length": linked_doc.make_input("0.6 m", "length"), "height": linked_doc.make_input("0.02 m", "length"),
		"width": linked_doc.make_input("0.2 m", "length"),
	}, {"operation": OPERATIONS.NEW_BODY, "position": Vector3.ZERO})
	var body_id: String = linked_doc.new_body(feature.id)
	feature.options.body_id = body_id
	linked_doc.bodies[body_id].name = "Deck"
	var linked := CAD_PART.new()
	linked.name = "Linked"
	linked.document = linked_doc
	linked.generate_collision = true
	root.add_child(linked)
	linked.apply_result(REGEN.rebuild(linked_doc, kernel))
	var scene_path := TEMP.path_join("linked/design.tscn")
	_externalize(linked, scene_path)
	var deck_node: MeshInstance3D = linked.body_nodes()[body_id]
	var forge_path := deck_node.mesh.resource_path
	_expect(forge_path.begins_with(TEMP.path_join("linked/design_forge/")), "The deck mesh should use the scene's _forge file (%s)." % forge_path)

	var board_root := TEMP.path_join("linked/boards")
	var v001 := board_root.path_join("Linked/Linked_v001.tscn")
	var board_scene := TEMP.path_join("linked/comps/Linked.tscn")
	var first: Dictionary = EXPORT.board_model_export(linked, kernel, {}, "Linked", ["tscn"], board_root)
	var comps: Array = EXPORT.export_components(linked, TEMP.path_join("linked/comps"), "tscn")
	_expect(first.error == "" and first.paths == [v001] and comps == [board_scene], "The linked part should export (%s, %s)." % [first, comps])
	for path in [v001, board_scene]:
		var text := FileAccess.get_file_as_string(path)
		_expect(not text.contains("_forge/") and text.contains("[sub_resource type=\"ArrayMesh\"")
			and text.contains("[sub_resource type=\"ConcavePolygonShape3D\""),
			"%s should embed its mesh and collision shape instead of linking to the _forge files." % path.get_file())
	_expect(deck_node.mesh.resource_path == forge_path, "Exporting should leave the part's own mesh on its _forge file.")

	feature.inputs["length"] = linked_doc.make_input("1.2 m", "length")
	linked.apply_result(REGEN.rebuild(linked_doc, kernel))
	_externalize(linked, scene_path)
	_expect(deck_node.mesh.resource_path == forge_path and absf(deck_node.mesh.get_aabb().size.x - 1.2) < 1e-4,
		"The longer deck should be saved over the same _forge file (%s)." % deck_node.mesh.resource_path)
	var second: Dictionary = EXPORT.board_model_export(linked, kernel, {}, "Linked", ["tscn"], board_root)
	_expect(second.error == "" and second.version == 2, "The edited part should save as v002 (%s)." % second)
	for check in [[v001, 0.6], [board_scene, 0.6], [board_root.path_join("Linked/Linked_v002.tscn"), 1.2]]:
		var length := _scene_deck_length(check[0])
		_expect(absf(length - float(check[1])) < 1e-4, "%s should hold a %s m deck (got %s)." % [str(check[0]).get_file(), check[1], length])
	linked.free()
	finished_checks += 1


## Windows device names can't be files or folders: bodies, components and boards named CON, prn,
## Lpt3, Nul, Aux or AUX save with a "_" added instead of being skipped, and an exchange file
## named NUL.step is refused before anything is written.
func _check_reserved_names() -> void:
	var names_doc: Resource = DOCUMENT.new()
	var aux: String = names_doc.new_component()
	names_doc.components[aux].name = "Aux"
	var bodies := {"CON": "", "prn": "", "Lpt3": "", "Fin": "", "Nul": aux}
	var x := 0.0
	for body_name in bodies:
		var feature: Resource = names_doc.add_feature("box", "Box", {
			"length": names_doc.make_input("0.1 m", "length"), "height": names_doc.make_input("0.1 m", "length"),
			"width": names_doc.make_input("0.1 m", "length"),
		}, {"operation": OPERATIONS.NEW_BODY, "position": Vector3(x, 0.0, 0.0)})
		var body_id: String = names_doc.new_body(feature.id)
		feature.options.body_id = body_id
		names_doc.bodies[body_id].component = bodies[body_name]
		names_doc.bodies[body_id].name = body_name
		x += 0.3
	var named := CAD_PART.new()
	named.name = "Names"
	named.document = names_doc
	root.add_child(named)
	var named_result := REGEN.rebuild(names_doc, kernel)
	named.apply_result(named_result)
	var folder := TEMP.path_join("names")

	var files := []
	for path in EXPORT.export_body_meshes(named, folder.path_join("meshes")):
		files.append(str(path).get_file())
	files.sort()
	_expect(files == ["CON_.res", "Fin.res", "Lpt3_.res", "Nul_.res", "prn_.res"], "Every body should save, device names with a '_' (got %s)." % [files])
	var scenes: Array = EXPORT.export_components(named, folder.path_join("scenes"), "tscn")
	_expect(scenes == [folder.path_join("scenes/Names.tscn"), folder.path_join("scenes/Aux_.tscn")],
		"The Aux component should save as Aux_.tscn (got %s)." % [scenes])
	var board: Dictionary = EXPORT.board_model_export(named, kernel, named_result, "AUX", ["tres"], folder.path_join("boards"))
	_expect(board.error == "" and board.paths == [folder.path_join("boards/AUX_/AUX__v001.tres")], "A board named AUX should save in an AUX_ folder (%s)." % board)
	var refused: String = EXPORT.export_cad(kernel, named_result, [], folder.path_join("cad/NUL.step"))
	_expect(refused.contains("device name") and not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(folder.path_join("cad"))),
		"Exporting to NUL.step should be refused before writing (%s)." % refused)
	var stems := {"CON": "CON_", "aux": "aux_", "Nul.v2": "Nul_.v2", "COM1": "COM1_", "lpt9": "lpt9_", "conout$": "conout$_",
		"Console": "Console", "COM10": "COM10", "Deck": "Deck"}
	for text in stems:
		_expect(EXPORT._file_stem(text) == stems[text], "%s should be saved as %s (got %s)." % [text, stems[text], EXPORT._file_stem(text)])
	named.free()
	finished_checks += 1


## glTF has no decals: a .glb board revision, a component .glb and CadPart.export_glb leave the
## decal out (no empty placeholder node) and say so (in the save's error and the .glb record's
## note), while the .tscn of the same revision keeps it.
func _check_glb_decals() -> void:
	var decal_doc: Resource = DOCUMENT.new()
	var feature: Resource = decal_doc.add_feature("box", "Box", {
		"length": decal_doc.make_input("0.8 m", "length"), "height": decal_doc.make_input("0.03 m", "length"),
		"width": decal_doc.make_input("0.25 m", "length"),
	}, {"operation": OPERATIONS.NEW_BODY, "position": Vector3.ZERO})
	var body_id: String = decal_doc.new_body(feature.id)
	feature.options.body_id = body_id
	decal_doc.bodies[body_id].name = "Plank"
	decal_doc.decals.append({"id": "d1", "name": "Sticker", "image": "res://icon.svg", "body": body_id, "face": "",
		"position": Vector3(0, 0.015, 0), "normal": Vector3.UP, "up": Vector3.FORWARD, "size": Vector2(0.1, 0.1), "rotation": 0.0, "visible": true})
	var skate := CAD_PART.new()
	skate.name = "Skate"
	skate.document = decal_doc
	root.add_child(skate)
	skate.apply_result(REGEN.rebuild(decal_doc, kernel))
	_expect(skate.find_children("*", "Decal", true, false).size() == 1, "The part should bake its decal.")

	var board_root := TEMP.path_join("decals/boards")
	var glb := board_root.path_join("Skate/Skate_v001.glb")
	var tscn := board_root.path_join("Skate/Skate_v001.tscn")
	var saved: Dictionary = EXPORT.board_model_export(skate, kernel, {}, "Skate", ["glb", "tscn"], board_root)
	_expect(saved.paths == [glb, tscn] and saved.version == 1 and str(saved.error).contains("Skate_v001.glb") and str(saved.error).contains("Sticker"),
		"The save should keep both files and say the .glb left the Sticker decal out (%s)." % saved)
	var names := _glb_node_names(glb)
	_expect(names.has("Plank") and not names.has("Sticker"), "The .glb should hold the body without a decal placeholder (%s)." % [names])
	var packed := ResourceLoader.load(tscn, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var scene := packed.instantiate() if packed != null else null
	_expect(scene != null and scene.find_children("*", "Decal", true, false).size() == 1, "The .tscn should keep the decal.")
	if scene != null:
		scene.free()
	var notes := {}
	for record in _read_json(board_root.path_join(EXPORT.MANIFEST_NAME)).get("files", []):
		notes[str(record.get("file", ""))] = str(record.get("note", ""))
	_expect(str(notes.get("Skate_v001.glb", "")).contains("Sticker") and str(notes.get("Skate_v001.tscn", "?")) == "",
		"The .glb record should note the decal it lacks, the .tscn record nothing (%s)." % notes)

	var comps: Array = EXPORT.export_components(skate, TEMP.path_join("decals/comps"), "glb")
	names = _glb_node_names(TEMP.path_join("decals/comps/Skate.glb"))
	_expect(comps.size() == 1 and names.has("Plank") and not names.has("Sticker"), "A component .glb should leave the decal out (%s, %s)." % [comps, names])
	var part_glb := TEMP.path_join("decals/part.glb")
	var written: String = skate.export_glb(part_glb)
	names = _glb_node_names(part_glb)
	_expect(written == part_glb and names.has("Plank") and not names.has("Sticker"), "CadPart.export_glb should leave the decal out (%s, %s)." % [written, names])
	skate.free()
	finished_checks += 1


## A save that fails part-way leaves no partial revision: no files, no board folder, no manifest
## record, and the version stays free. A result whose body lost its shape fails at the STEP after
## the .tres and .glb were written. A non-ASCII name with STL (which the native STL writer once
## failed on) is saved whole or not at all.
func _check_failed_save() -> void:
	var fail_root := TEMP.path_join("boards_failed")
	var folder := fail_root.path_join("Partial")
	var manifest_path := fail_root.path_join(EXPORT.MANIFEST_NAME)
	var broken := {"bodies": {"ghost": {"shape": null}}}
	var failed: Dictionary = EXPORT.board_model_export(part, kernel, broken, "Partial", ["tres", "glb", "step"], fail_root)
	_expect(str(failed.error).contains("no revision was saved") and failed.version == 0 and (failed.paths as Array).is_empty(),
		"A save failing at the STEP should report that nothing was saved (%s)." % failed)
	_expect(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(folder)) and not FileAccess.file_exists(manifest_path),
		"The failed first save should leave no board folder and no manifest (%s)." % [_folder_entries(folder)])

	var good: Dictionary = EXPORT.board_model_export(part, kernel, result, "Partial", ["tres", "glb", "step"], fail_root)
	var expected := ["Partial_v001.glb", "Partial_v001.step", "Partial_v001.tres"]
	_expect(good.error == "" and good.version == 1 and _folder_entries(folder) == expected,
		"The next save should still be v001, with no staging folder left (%s, %s)." % [good, _folder_entries(folder)])
	var manifest_before := FileAccess.get_file_as_string(manifest_path)
	var again: Dictionary = EXPORT.board_model_export(part, kernel, broken, "Partial", ["tres", "step"], fail_root)
	_expect(again.version == 0 and _folder_entries(folder) == expected and FileAccess.get_file_as_string(manifest_path) == manifest_before,
		"A failed save next to v001 should leave the folder and manifest as they were (%s, %s)." % [again, _folder_entries(folder)])

	var unicode: Dictionary = EXPORT.board_model_export(part, kernel, result, "Glöd", ["tres", "stl"], fail_root)
	var entries := _folder_entries(fail_root.path_join("Glöd"))
	# The kernel writes STL to UTF-8 paths, so the board saves whole.
	_expect(str(unicode.error) == "" and unicode.version == 1 and entries == ["Glöd_v001.stl", "Glöd_v001.tres"],
		"A Glöd board with STL should save whole (%s, %s)." % [unicode, entries])
	finished_checks += 1


## Appending writes the new records as text at the end of the "files" list: other tools' big
## integers, long floats, "1.0", strings holding brackets, keys after the list and CRLF stay byte
## for byte; an empty list (pretty or on one line, with a BOM) gets the records; a file without a
## "files" list is left alone.
func _check_manifest_text() -> void:
	var text_root := TEMP.path_join("manifest_text")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(text_root))
	var path := text_root.path_join(EXPORT.MANIFEST_NAME)
	var other := "    {\r\n      \"file\": \"other.bin\",\r\n      \"note\": \"a ] b \\\" { c\",\r\n      \"mtime_ns\": 1760000000123456789,\r\n" \
		+ "      \"bytes\": 9007199254740993,\r\n      \"scale\": 0.30000000000000004,\r\n      \"unit\": 1.0,\r\n      \"small\": 0.000012345678901234567\r\n    }"
	var head := "{\r\n  \"created\": \"2026-10-09\",\r\n  \"files\": [\r\n" + other
	var tail := "\r\n  ],\r\n  \"after\": [1.50, 2]\r\n}\r\n"
	_write_text(path, head + tail)
	var record := {"file": "Probe_v001.glb", "source": "", "destination": "C:\\x\\Probe_v001.glb", "bytes": 42, "sha256": "AB", "verified": true}
	var error: String = EXPORT.append_manifest_records(text_root, [record])
	var added := ",\r\n    {\r\n      \"file\": \"Probe_v001.glb\",\r\n      \"source\": \"\",\r\n      \"destination\": \"C:\\\\x\\\\Probe_v001.glb\",\r\n" \
		+ "      \"bytes\": 42,\r\n      \"sha256\": \"AB\",\r\n      \"verified\": true\r\n    }"
	var after := FileAccess.get_file_as_string(path)
	_expect(error == "" and after == head + added + tail, "Appending should keep every existing byte and add the record in the file's style (%s):\n%s" % [error, after])

	_write_text(path, "{\n  \"policy\": \"x\",\n  \"files\": []\n}\n")
	error = EXPORT.append_manifest_records(text_root, [record, record])
	after = FileAccess.get_file_as_string(path)
	_expect(error == "" and after.begins_with("{\n  \"policy\": \"x\",\n  \"files\": [\n    {\n      \"file\": \"Probe_v001.glb\",")
		and after.ends_with("    },\n    {\n" + "      \"file\": \"Probe_v001.glb\",\n      \"source\": \"\",\n      \"destination\": \"C:\\\\x\\\\Probe_v001.glb\",\n      \"bytes\": 42,\n      \"sha256\": \"AB\",\n      \"verified\": true\n    }\n  ]\n}\n"),
		"An empty pretty list should get both records (%s):\n%s" % [error, after])

	var bom := PackedByteArray([0xEF, 0xBB, 0xBF]) + "{\"files\":[]}".to_utf8_buffer()
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(bom)
	file.close()
	error = EXPORT.append_manifest_records(text_root, [record])
	var bytes := FileAccess.get_file_as_bytes(path)
	var compact := bytes.slice(3).get_string_from_utf8()
	_expect(error == "" and bytes.slice(0, 3) == PackedByteArray([0xEF, 0xBB, 0xBF]) and compact.begins_with("{\"files\":[{\"file\":\"Probe_v001.glb\",")
		and compact.ends_with("\"verified\":true}]}") and not compact.contains("\n"),
		"A one-line list should get the record on the same line, keeping the BOM (%s): %s" % [error, compact])

	_write_text(path, "{\"other\": 1}")
	error = EXPORT.append_manifest_records(text_root, [record])
	_expect(error != "" and FileAccess.get_file_as_string(path) == "{\"other\": 1}", "A file without a files list should be left alone (%s)." % error)
	finished_checks += 1


# --- Helpers ---------------------------------------------------------------------------------


## CadPart.externalize_meshes' save and take_over_path for every body mesh (it only runs in the
## editor), plus the same for each collision shape.
func _externalize(target: Node3D, scene_path: String) -> void:
	var folder := scene_path.get_basename() + "_forge"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	var nodes: Dictionary = target.body_nodes()
	for body_id in nodes:
		var body: MeshInstance3D = nodes[body_id]
		var path := "%s/%s_%s.res" % [folder, target.name, body_id]
		if body.mesh.resource_path != path and ResourceSaver.save(body.mesh, path, ResourceSaver.FLAG_COMPRESS) == OK:
			body.mesh.take_over_path(path)
		var shape_node := body.get_node_or_null("Collision/Shape") as CollisionShape3D
		var shape_path := "%s/%s_%s_shape.res" % [folder, target.name, body_id]
		if shape_node != null and shape_node.shape.resource_path != shape_path and ResourceSaver.save(shape_node.shape, shape_path) == OK:
			shape_node.shape.take_over_path(shape_path)


## The length (x size) of the first mesh in a saved scene, read fresh from disk with everything
## it links to.
func _scene_deck_length(path: String) -> float:
	var packed := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP) as PackedScene
	if packed == null:
		return -1.0
	var scene := packed.instantiate()
	var meshes := scene.find_children("*", "MeshInstance3D", true, false)
	var length: float = (meshes[0] as MeshInstance3D).mesh.get_aabb().size.x if not meshes.is_empty() else -1.0
	scene.free()
	return length


## The node names in a .glb file.
func _glb_node_names(path: String) -> Array:
	var names := []
	for node in _glb_json(path).get("nodes", []):
		names.append(str(node.get("name", "")))
	return names


## The file and folder names in a folder, sorted (empty when it doesn't exist).
func _folder_entries(folder: String) -> Array:
	var dir := DirAccess.open(folder)
	if dir == null:
		return []
	var names: Array = Array(dir.get_files()) + Array(dir.get_directories())
	names.sort()
	return names


## What keeps the manifest's records from verifying as receipts: each must have the manifest's
## per-file keys, name its destination file, and match that file's size and SHA-256.
func _receipt_problems(manifest_path: String) -> Array:
	var problems := []
	for record in _read_json(manifest_path).get("files", []):
		for key in ["file", "source", "destination", "bytes", "sha256", "verified"]:
			if not (record as Dictionary).has(key):
				problems.append("%s lacks %s" % [record.get("file", "?"), key])
		var path := str(record.get("destination", "")).replace("\\", "/")
		if str(record.get("file", "")) != path.get_file():
			problems.append("%s is not the file at %s" % [record.get("file", "?"), path])
		elif not FileAccess.file_exists(path):
			problems.append("%s does not exist" % path)
		elif str(record.get("sha256", "")) != FileAccess.get_sha256(path).to_upper() or int(record.get("bytes", -1)) != _size(path):
			problems.append("%s does not match its size or SHA-256" % path)
	return problems


## A path as the manifest writes it (absolute, the system's separators).
func _system(path: String) -> String:
	var system := ProjectSettings.globalize_path(path)
	return system.replace("/", "\\") if OS.get_name() == "Windows" else system


## The JSON chunk of a .glb file.
func _glb_json(path: String) -> Dictionary:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() < 20:
		return {}
	var parsed: Variant = JSON.parse_string(bytes.slice(20, 20 + bytes.decode_u32(12)).get_string_from_utf8())
	return parsed if parsed is Dictionary else {}


func _size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return 0
	var n := file.get_length()
	file.close()
	return n


func _read_json(path: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _write_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _remove_tree(path: String) -> void:
	var system := ProjectSettings.globalize_path(path)
	var dir := DirAccess.open(system)
	if dir == null:
		return
	for file in dir.get_files():
		DirAccess.remove_absolute(system.path_join(file))
	for sub in dir.get_directories():
		_remove_tree(system.path_join(sub))
	DirAccess.remove_absolute(system)


func _aabb_close(a: AABB, b: AABB) -> bool:
	return a.position.distance_to(b.position) < 1e-5 and a.size.distance_to(b.size) < 1e-5


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)
		print("FAIL: ", message)
