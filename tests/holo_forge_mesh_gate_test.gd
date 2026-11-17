extends SceneTree
## Holo Forge mesh bodies in the design (Phase 7, stage G1): the gate, the tools that take mesh
## bodies, the analyses that refuse them, old designs, stored meshes, undo and a missing kernel.
##
##   1. Every Reader path of core/features/util.gd, every resolver of core/references.gd and the
##      targets of core/operations.gd answer a mesh body with the gate sentence; the Solid and
##      Surface features do too (through their handlers and through regen).
##   2. What takes mesh bodies works on one: Tessellate, Insert Mesh as a mesh body, Move, Copy,
##      Remove, appearances by body and by face group, Measure, mass properties and Interference
##      (through core/inspect.gd: mesh against mesh and mesh against B-rep), Center of Mass,
##      Section, Zebra, Draft, Accessibility, display meshes, picking, STL/OBJ/3MF export with the
##      very triangles, the bake and its collision.
##   3. What needs B-rep surfaces says so: curvature map, minimum radius, isocurve, curvature comb,
##      decals, and STEP export (which lists the mesh body as left out).
##   4. Old designs rebuild as before (values recorded on the code before this stage).
##   5. Stored meshes: small ones stay in the scene, big ones go to a file named after their
##      content, a saved scene loads back to the same mesh, a damaged one is a checksum error.
##   6. Undo: a snapshot and its restore hold the very same stored mesh (no copy).
##   7. Without the native mesh class the features say "The Holo Forge mesh kernel is not loaded".
##
## godot --headless --path . --script res://tests/holo_forge_mesh_gate_test.gd

const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const FEATURE := preload("res://addons/holo_forge/core/feature.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const UTIL := preload("res://addons/holo_forge/core/features/util.gd")
const REFERENCES := preload("res://addons/holo_forge/core/references.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const MODIFY := preload("res://addons/holo_forge/core/features/modify.gd")
const PATTERN := preload("res://addons/holo_forge/core/features/pattern.gd")
const PRIMITIVE := preload("res://addons/holo_forge/core/features/primitive.gd")
const SURFACE := preload("res://addons/holo_forge/core/features/surface.gd")
const INSERT := preload("res://addons/holo_forge/core/features/insert.gd")
const MESH_FEATURE := preload("res://addons/holo_forge/core/features/mesh.gd")
const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")
const MESH_BLOB := preload("res://addons/holo_forge/core/mesh/mesh_blob.gd")
const MESH_IMPORT := preload("res://addons/holo_forge/core/import/mesh_import.gd")
const TESSELLATE := preload("res://addons/holo_forge/core/tessellate.gd")
const PICKING := preload("res://addons/holo_forge/core/picking.gd")
const ANALYSIS := preload("res://addons/holo_forge/core/analysis.gd")
const INSPECT := preload("res://addons/holo_forge/core/inspect.gd")
const APPEARANCE := preload("res://addons/holo_forge/core/appearance.gd")
const MATERIAL_LIBRARY := preload("res://addons/holo_forge/core/material_library.gd")
const EXPORT := preload("res://addons/holo_forge/core/export.gd")
const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const FIXTURES := preload("res://tests/holo_forge_mesh_fixtures.gd")

const MM := 0.001
const TEMP := "user://holo_forge_mesh_fixtures/gate"
const GATE_TEXT := "%s is a mesh body. Convert it first (Mesh > Modify > Convert Mesh)."
const RED := "builtin:paint_red"
const CHROME := "builtin:metal_chrome"
## Old designs as the code before this stage rebuilt them (recorded 2026-11-11 with a probe on
## the untouched tree, to 12 decimals): the saved fixture scene's part and the fixture meshes
## inserted the old way (no "kind" key). [bodies, volume m3, area m2, faces, shape type].
## OLD_DECIMALS: half a unit of the last recorded decimal.
const OLD_SCENE := "res://tests/holo_forge/forge_editor_test.tscn"
const OLD_DECIMALS := 6e-13
const OLD_SCENE_PART := [1, 0.000153013621, 0.021823089820, 71, "COMPOUND"]
const OLD_MESHES := {
	"cube_10mm.stl": [1, 0.000001000000, 0.000600000085, 12, "SOLID"],
	"cube_2cm.obj": [1, 0.000000008000, 0.000024000002, 12, "SOLID"],
	"cube_10mm_placed.3mf": [1, 0.000001000000, 0.000600000066, 12, "SOLID"],
	"components_cm.3mf": [1, 0.000010000001, 0.003600000435, 36, "COMPOUND"],
}

var failures: Array[String] = []
var checked: Array[String] = []
var notes: Array[String] = []


func _init() -> void:
	call_deferred("run")


func run() -> void:
	var kernel := REGEN.make_kernel()
	_expect(kernel != null, "The native kernel should load.")
	if kernel != null and not ClassDB.class_exists("CadMesh"):
		print("NOTE holo_forge_mesh_gate: CadMesh is not in this build; the mesh checks are skipped.")
		_check_missing_kernel(kernel)
		_check_old_documents(kernel)
	elif kernel != null:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEMP))
		MESH_FEATURE.clear_cache()
		_check_helpers()
		_check_cache()
		var scene := _scene(kernel)
		_check_tessellate_and_insert(kernel, scene)
		_check_gate_readers(kernel, scene)
		_check_gate_references(kernel, scene)
		_check_gate_operations(kernel, scene)
		_check_gate_features(kernel, scene)
		_check_move_copy_remove(kernel, scene)
		_check_display_and_picking(kernel, scene)
		_check_appearance(kernel, scene)
		_check_inspect(kernel, scene)
		_check_analyses(kernel, scene)
		_check_refused(kernel, scene)
		_check_export(kernel, scene)
		await _check_bake(kernel, scene)
		_check_old_documents(kernel)
		_check_blobs(kernel)
		_check_undo(kernel)
		_check_derive(kernel)
		_check_missing_kernel(kernel)
		_remove_folder(TEMP)
	for note in notes:
		print("NOTE holo_forge_mesh_gate: " + note)
	if failures.is_empty():
		print("PASS holo_forge_mesh_gate: " + "; ".join(checked) + ".")
	else:
		print("FAIL holo_forge_mesh_gate")
		for failure in failures:
			print("  " + failure)
	quit(0 if failures.is_empty() else 1)


# --- Scene -----------------------------------------------------------------------------------

## A design with two B-rep boxes, a mesh body tessellated from the second (one face group per
## box face) and a mesh body inserted from an STL file: {"doc", "solid" (box body id), "source"
## (the tessellated box), "mesh" (its mesh body), "inserted" (the STL mesh body), "tessellate",
## "insert" (features), "result"}.
func _scene(kernel: RefCounted) -> Dictionary:
	var doc: Resource = DOCUMENT.new()
	var box_a := _add_box(doc, Vector3(0.02, 0.02, 0.02), Vector3.ZERO)
	var box_b := _add_box(doc, Vector3(0.03, 0.03, 0.03), Vector3(0.1, 0.0, 0.0))
	var made: Dictionary = MESH_FEATURE.add_tessellate(doc, [box_b.options.body_id])
	var stl := FIXTURES.write_stl(FIXTURES.two_cubes(Vector3(0.05, 0.0, 0.0)).first, "gate/cube_20mm.stl", 1000.0)
	var added: Dictionary = INSERT.add_mesh_import(doc, stl, "mm", false, INSERT.KIND_MESH)
	_expect(str(made.error) == "" and str(added.error) == "", "Tessellate and Insert Mesh features should be added (%s, %s)." % [made.error, added.error])
	var inserted := ""
	if added.feature != null:
		inserted = str(added.feature.options.body_id)
		added.feature.inputs["x"] = doc.make_input("-100 mm", "length")
	var result := REGEN.rebuild(doc, kernel)
	_expect(result.errors.is_empty(), "The scene should rebuild without errors (%s)." % str(result.errors))
	return {
		"doc": doc, "solid": str(box_a.options.body_id), "source": str(box_b.options.body_id),
		"mesh": str(made.bodies[0]) if not made.bodies.is_empty() else "", "inserted": inserted,
		"tessellate": made.feature, "insert": added.feature, "result": result,
	}


func _add_box(doc: Resource, size: Vector3, position: Vector3) -> Resource:
	var feature: Resource = doc.add_feature("box", "Box", {
		"length": doc.make_input("%f m" % size.x, "length"), "height": doc.make_input("%f m" % size.y, "length"),
		"width": doc.make_input("%f m" % size.z, "length"),
	}, {"operation": OPERATIONS.NEW_BODY, "position": position})
	feature.options.body_id = doc.new_body(feature.id)
	return feature


## A feature with inputs given as "10 mm" (a length), or [expression, kind].
func _add(doc: Resource, type: String, inputs: Dictionary, options: Dictionary) -> Resource:
	var made := {}
	for key in inputs:
		var value: Variant = inputs[key]
		made[key] = doc.make_input(str(value[0]), str(value[1])) if value is Array else doc.make_input(str(value), "length")
	return doc.add_feature(type, type.capitalize(), made, options)


func _ctx(doc: Resource, kernel: RefCounted, result: Dictionary) -> Dictionary:
	return {
		"kernel": kernel, "doc": doc, "values": result.values, "bodies": (result.bodies as Dictionary).duplicate(),
		"sketches": result.sketches, "construction": result.construction, "tools": {}, "warnings": {}, "threads": {},
		"forms": {}, "form_preview": "", "mesh_time_limit": MESH_FEATURE.OK_SECONDS,
	}


func _reader(ctx: Dictionary, options: Dictionary) -> UTIL.Reader:
	var feature: Resource = FEATURE.new()
	feature.id = "probe"
	feature.type = "probe"
	feature.label = "Probe"
	feature.options = options
	return UTIL.Reader.new(feature, ctx)


func _body(id: String) -> Dictionary:
	return {"kind": "body", "body": id}


## A face reference on a B-rep body: the face whose normal is along direction.
func _face_ref(result: Dictionary, body_id: String, direction: Vector3) -> Dictionary:
	var shape: RefCounted = result.bodies[body_id].shape
	for i in shape.face_count():
		var info: Dictionary = shape.face_info(i)
		if info.get("planar", false) and (info.normal as Vector3).dot(direction) > 0.99:
			return REFERENCES.from_pick({"kind": "face", "body": body_id, "index": i}, result)
	return {}


## The name of a mesh body's flat face group whose normal is along direction ("" when none).
func _group_name(shape: RefCounted, direction: Vector3) -> String:
	var names: PackedStringArray = shape.get_face_names()
	for i in shape.face_count():
		var info: Dictionary = shape.face_info(i)
		if info.get("planar", false) and (info.normal as Vector3).dot(direction) > 0.99:
			return str(names[i])
	return ""


# --- Helpers of the stage --------------------------------------------------------------------

func _check_helpers() -> void:
	_expect(UTIL.MESH_GATE == GATE_TEXT, "UTIL.MESH_GATE should be the gate sentence ('%s')." % UTIL.MESH_GATE)
	var cube := FIXTURES.to_mesh(FIXTURES.two_cubes(Vector3.ZERO).first)
	var kernel: RefCounted = ClassDB.instantiate("CadKernel")
	var box: RefCounted = kernel.make_box(Vector3(0.01, 0.01, 0.01), Vector3.ZERO, "h")
	_expect(MESH_BODY.is_mesh(cube) and not MESH_BODY.is_mesh(box) and not MESH_BODY.is_mesh(null) and not MESH_BODY.is_mesh({}),
		"is_mesh should tell a CadMesh from a CadShape, null and an empty entry.")
	var entry := MESH_BODY.entry("b9", cube, "f9")
	_expect(MESH_BODY.is_mesh(entry) and str(entry.kind) == "mesh" and MESH_BODY.kind_of(entry) == "mesh"
		and MESH_BODY.kind_of({"id": "b1", "shape": box, "feature": "f1"}) == "brep" and not MESH_BODY.is_mesh({"id": "b1", "shape": box, "feature": "f1"}),
		"A mesh entry carries kind 'mesh'; a B-rep entry has no kind and reads as 'brep'.")
	_expect(MESH_BODY.is_mesh({"id": "b9", "shape": cube, "feature": "f9"}), "An entry whose shape is a CadMesh is a mesh body even without its kind.")
	_expect(UTIL.mesh_gate(null, [{"id": "b1", "shape": box}, entry]) == GATE_TEXT % "b9" and UTIL.mesh_gate(null, [{"id": "b1", "shape": box}]) == "",
		"mesh_gate should name the first mesh entry and be empty without one.")
	checked.append("helpers (is_mesh for shapes and entries, entry kind, UTIL.MESH_GATE and mesh_gate)")


## The Mesh features' cache: by content, least recently used first out, refusals kept with their
## time limit.
func _check_cache() -> void:
	MESH_FEATURE.clear_cache()
	var cube := FIXTURES.to_mesh(FIXTURES.two_cubes(Vector3.ZERO).first)
	var blob: Resource = MESH_BLOB.from_mesh(cube)
	var long := PackedInt32Array()
	long.resize(5000)
	var key_a := MESH_FEATURE.cache_key("probe", {"b": 2.5, "a": Vector3(1, 2, 3), "mesh": blob, "triangles": long}, [str(cube.digest())])
	var key_b := MESH_FEATURE.cache_key("probe", {"triangles": long, "mesh": MESH_BLOB.from_mesh(cube), "a": Vector3(1, 2, 3), "b": 2.5}, [str(cube.digest())])
	var key_c := MESH_FEATURE.cache_key("probe", {"b": 2.5000001, "a": Vector3(1, 2, 3), "mesh": blob, "triangles": long}, [str(cube.digest())])
	_expect(key_a == key_b and key_a != key_c and key_a.length() < 400 and key_a.contains(str(blob.digest)) and key_a != MESH_FEATURE.cache_key("other", {}, [str(cube.digest())]),
		"A cache key should depend on the content asked for, not on key order or instances (%d characters)." % key_a.length())
	# Eight more than the cache holds: the eight oldest go.
	var over: int = MESH_FEATURE.CACHE_ENTRIES + 8
	for k in over:
		MESH_FEATURE.store("key%d" % k, [cube])
	var stats: Dictionary = MESH_FEATURE.cache_stats()
	_expect(int(stats.entries) == MESH_FEATURE.CACHE_ENTRIES and int(stats.bytes) == MESH_FEATURE.CACHE_ENTRIES * int(cube.memory_bytes()) and MESH_FEATURE.lookup("key7").is_empty() and not MESH_FEATURE.lookup("key8").is_empty(),
		"The cache should keep the %d newest results (%s)." % [MESH_FEATURE.CACHE_ENTRIES, str(stats)])
	MESH_FEATURE.store("key%d" % over, [cube])
	_expect(not MESH_FEATURE.lookup("key8").is_empty() and MESH_FEATURE.lookup("key9").is_empty() and is_same(MESH_FEATURE.lookup("key%d" % over).meshes[0], cube), "A result just used should outlive an older one.")
	# A refusal counts for its time limit and shorter ones; a result for any.
	MESH_FEATURE.store("slow", [], "It would take about 3 s (limit 0.5 s).", "", {}, MESH_FEATURE.PREVIEW_SECONDS)
	_expect(MESH_FEATURE.lookup("slow", MESH_FEATURE.OK_SECONDS).is_empty() and str(MESH_FEATURE.lookup("slow", MESH_FEATURE.PREVIEW_SECONDS).get("error", "")).begins_with("It would take"),
		"A refusal made for the preview's time limit should not stand for OK.")
	MESH_FEATURE.store("never", [], "It can't be done.", "", {}, MESH_FEATURE.OK_SECONDS)
	_expect(not MESH_FEATURE.lookup("never", MESH_FEATURE.PREVIEW_SECONDS).is_empty() and not MESH_FEATURE.lookup("never", MESH_FEATURE.OK_SECONDS).is_empty(), "A refusal made with the full time stands for a preview too.")
	_expect(MESH_FEATURE.time_limit({}) == MESH_FEATURE.OK_SECONDS and MESH_FEATURE.time_limit({"mesh_time_limit": MESH_FEATURE.PREVIEW_SECONDS}) == 0.5 and MESH_FEATURE.time_limit({"mesh_time_limit": 900.0}) == 120.0,
		"The time limit should come from the rebuild (20 s without one, 0.5 s in a preview, never over 120 s).")
	var moved: RefCounted = MESH_FEATURE.transformed(cube, Transform3D(Basis.IDENTITY, Vector3(1, 0, 0)))
	_expect(moved != null and is_same(MESH_FEATURE.transformed(cube, Transform3D(Basis.IDENTITY, Vector3(1, 0, 0))), moved) and is_same(MESH_FEATURE.transformed(cube, Transform3D.IDENTITY), cube),
		"A moved mesh should be kept by content; an unmoved one is itself.")
	MESH_FEATURE.clear_cache()
	_expect(int(MESH_FEATURE.cache_stats().entries) == 0 and int(MESH_FEATURE.cache_stats().bytes) == 0 and MESH_FEATURE.lookup("key%d" % over).is_empty(), "clear_cache should empty the cache.")
	checked.append("the Mesh cache (content keys, %d entries least recently used first out, byte count, refusals by time limit, moved meshes, clear_cache)" % MESH_FEATURE.CACHE_ENTRIES)


# --- Tessellate and Insert Mesh (what makes mesh bodies) -------------------------------------

func _check_tessellate_and_insert(kernel: RefCounted, scene: Dictionary) -> void:
	var doc: Resource = scene.doc
	var result: Dictionary = scene.result
	var entry: Dictionary = result.bodies.get(scene.mesh, {})
	_expect(MESH_BODY.is_mesh(entry) and str(entry.get("kind", "")) == "mesh" and str(entry.get("feature", "")) == scene.tessellate.id,
		"Tessellate should add a mesh body entry with kind 'mesh'.")
	if entry.is_empty():
		return
	var mesh: RefCounted = entry.shape
	var source: RefCounted = result.bodies[scene.source].shape
	var expected := PackedStringArray()
	for name in source.get_face_names():
		expected.append(mesh.group_name_for(name))
	_expect(mesh.get_face_names() == expected and mesh.face_count() == 6, "A tessellated box should have one face group per face, named after it (%s)." % str(mesh.get_face_names()))
	var found: Dictionary = mesh.check(1.0)
	_expect(bool(found.get("closed", false)) and int(found.get("boundary_edges", -1)) == 0 and int(found.get("non_manifold_edges", -1)) == 0,
		"A tessellated solid should be closed and manifold (%s)." % str(found))
	_expect(absf(mesh.volume() - source.volume()) <= 0.01 * source.volume(), "The tessellated volume should be within 1 %% (%s vs %s)." % [mesh.volume(), source.volume()])
	_expect(result.bodies.has(scene.source) and not MESH_BODY.is_mesh(result.bodies[scene.source]), "Keep Original should leave the B-rep body in place.")
	_expect(doc.body_name(scene.mesh) == doc.body_name(scene.source) + " Mesh", "The mesh body should be named after its source ('%s')." % doc.body_name(scene.mesh))
	# The same content gives the same instance on a rebuild (the view reuses its tessellation).
	var again := REGEN.rebuild(doc, kernel)
	_expect(is_same(again.bodies[scene.mesh].shape, mesh) and is_same(again.bodies[scene.inserted].shape, result.bodies[scene.inserted].shape),
		"A rebuild that changes nothing should give the same CadMesh instances back.")
	# Keep Original off removes the source; a mesh body as input is told what it is.
	scene.tessellate.options["keep_original"] = false
	var without := REGEN.rebuild(doc, kernel)
	_expect(not without.bodies.has(scene.source) and without.bodies.has(scene.mesh) and without.errors.is_empty(), "Keep Original off should remove the source body (%s)." % str(without.errors))
	scene.tessellate.options["keep_original"] = true
	var twice: Dictionary = MESH_FEATURE.add_tessellate(doc, [scene.mesh])
	var refused := REGEN.rebuild(doc, kernel)
	_expect(str(refused.errors.get(twice.feature.id, "")) == MESH_BODY.ALREADY_MESH % doc.body_name(scene.mesh), "Tessellate of a mesh body should say it already is one ('%s')." % refused.errors.get(twice.feature.id, ""))
	doc.remove_feature(twice.feature.id)
	# A coarse refinement is kept with a warning that gives the percent (1 to 5 % off in volume); one
	# more than 5 % off is refused, and the refusal is kept; a custom one out of range is named.
	var ball: Resource = doc.add_feature("sphere", "Sphere", {"diameter": doc.make_input("100 mm", "length")}, {"operation": OPERATIONS.NEW_BODY, "position": Vector3(0.0, 0.3, 0.0)})
	ball.options.body_id = doc.new_body(ball.id)
	var coarse: Dictionary = MESH_FEATURE.add_tessellate(doc, [ball.options.body_id], {"quality": "low"})
	var low := REGEN.rebuild(doc, kernel)
	var low_body: Dictionary = low.bodies.get(str(coarse.bodies[0]), {})
	_expect(not low.errors.has(coarse.feature.id) and MESH_BODY.is_mesh(low_body) and str(low.warnings.get(coarse.feature.id, "")).contains("2.3 %") and str(low.warnings.get(coarse.feature.id, "")).contains("Raise the Refinement"),
		"A tessellation 1 to 5 %% off in volume should be kept with a warning that gives the percent (error '%s', warning '%s')." % [low.errors.get(coarse.feature.id, ""), low.warnings.get(coarse.feature.id, "")])
	coarse.feature.options["quality"] = "custom"
	coarse.feature.inputs["linear"] = doc.make_input("17 mm", "length")
	coarse.feature.inputs["angular"] = doc.make_input("45 deg", "angle")
	var rough := REGEN.rebuild(doc, kernel)
	var refusal := str(rough.errors.get(coarse.feature.id, ""))
	_expect(refusal.contains("more than 5 %") and refusal.contains("Raise the Refinement") and not rough.bodies.has(str(coarse.bodies[0])),
		"A tessellation more than 5 %% off in volume should be refused with a way out ('%s')." % refusal)
	var hits := MESH_FEATURE.cache_hits
	var rough_again := REGEN.rebuild(doc, kernel)
	_expect(refusal != "" and str(rough_again.errors.get(coarse.feature.id, "")) == refusal and MESH_FEATURE.cache_hits > hits, "A refusal should be kept, not worked out again ('%s')." % rough_again.errors.get(coarse.feature.id, ""))
	coarse.feature.options["quality"] = "custom"
	coarse.feature.inputs["linear"] = doc.make_input("50 mm", "length")
	coarse.feature.inputs["angular"] = doc.make_input("15 deg", "angle")
	var wide := REGEN.rebuild(doc, kernel)
	_expect(str(wide.errors.get(coarse.feature.id, "")).begins_with("Surface Deviation must be between"), "A custom deviation out of range should be refused by name ('%s')." % wide.errors.get(coarse.feature.id, ""))
	coarse.feature.inputs["linear"] = doc.make_input("0.05 mm", "length")
	coarse.feature.inputs["angular"] = doc.make_input("8 deg", "angle")
	var fine := REGEN.rebuild(doc, kernel)
	var fine_body: Dictionary = fine.bodies.get(str(coarse.bodies[0]), {})
	_expect(not fine.errors.has(coarse.feature.id) and MESH_BODY.is_mesh(fine_body) and absf(fine_body.shape.volume() - fine.bodies[ball.options.body_id].shape.volume()) < 0.01 * fine.bodies[ball.options.body_id].shape.volume(),
		"A custom refinement in range should tessellate the sphere within 1 %% (%s)." % fine.errors.get(coarse.feature.id, ""))
	doc.remove_feature(coarse.feature.id)
	doc.remove_feature(ball.id)

	# Insert Mesh as a mesh body: the stored blob, no positions or indices, placed by its inputs.
	var insert: Resource = scene.insert
	var body: Dictionary = result.bodies.get(scene.inserted, {})
	_expect(MESH_BODY.is_mesh(body) and int(body.shape.triangle_count()) == 12 and absf(body.shape.volume() - 8e-6) < 1e-10,
		"Insert Mesh as a mesh body should give the cube's 12 triangles in meters (%s)." % (body.shape.volume() if not body.is_empty() else 0.0))
	_expect(not insert.options.has("positions") and not insert.options.has("indices") and insert.options.get("mesh") is Resource and str(insert.options.kind) == "mesh",
		"A mesh-body insert should keep a MeshBlob and no positions or indices (%s)." % str(insert.options.keys()))
	_expect(((body.shape.bbox() as AABB).get_center() - Vector3(-0.1, 0.0, 0.0)).length() < 1e-6, "The placement inputs should move the mesh body (%s)." % (body.shape.bbox() as AABB).get_center())
	# Units read after the fact rescale the stored mesh; a linked insert reads the file itself.
	insert.options["units"] = "cm"
	var bigger := REGEN.rebuild(doc, kernel)
	_expect(absf(bigger.bodies[scene.inserted].shape.volume() - 8e-3) < 1e-7, "Changing the units should rescale the stored mesh (%s)." % bigger.bodies[scene.inserted].shape.volume())
	insert.options["units"] = "mm"
	var linked: Dictionary = INSERT.add_mesh_import(doc, str(insert.options.path), "", true, INSERT.KIND_MESH)
	var with_link := REGEN.rebuild(doc, kernel)
	var link_body: Dictionary = with_link.bodies.get(str(linked.feature.options.body_id), {})
	_expect(str(linked.error) == "" and not linked.feature.options.has("mesh") and MESH_BODY.is_mesh(link_body) and int(link_body.shape.triangle_count()) == 12,
		"A linked mesh-body insert should keep no blob and read its file (%s)." % with_link.errors.get(linked.feature.id, ""))
	linked.feature.options["path"] = TEMP + "/not_there.stl"
	var lost := REGEN.rebuild(doc, kernel)
	_expect(str(lost.errors.get(linked.feature.id, "")).contains("can't be found"), "A linked mesh whose file is gone should say so ('%s')." % lost.errors.get(linked.feature.id, ""))
	doc.remove_feature(linked.feature.id)
	# Open meshes carry the warning; a mesh body never joins or cuts.
	var plate_path := FIXTURES.write_stl(FIXTURES.open_plate(), "gate/open_plate.stl", 1000.0)
	var plate: Dictionary = INSERT.add_mesh_import(doc, plate_path, "", false, INSERT.KIND_MESH)
	var open := REGEN.rebuild(doc, kernel)
	_expect(str(open.warnings.get(plate.feature.id, "")).contains("128 open edges in 1 hole") and str(open.warnings.get(plate.feature.id, "")).contains("Close Holes"),
		"An open mesh body should carry the open-edge warning ('%s')." % open.warnings.get(plate.feature.id, ""))
	plate.feature.options["operation"] = OPERATIONS.CUT
	var cutting := REGEN.rebuild(doc, kernel)
	_expect(str(cutting.errors.get(plate.feature.id, "")).contains("new body"), "A mesh body should only come in as a new body ('%s')." % cutting.errors.get(plate.feature.id, ""))
	plate.feature.options["operation"] = OPERATIONS.NEW_BODY
	plate.feature.options["split"] = true
	var pieces := REGEN.rebuild(doc, kernel)
	_expect(not pieces.errors.has(plate.feature.id), "One Body per Piece should work with separate (%s)." % pieces.errors.get(plate.feature.id, ""))
	# Two cubes in one file come in as two mesh bodies: the feature's own, and a split-off one.
	var pair_path := FIXTURES.write_stl(FIXTURES.two_cubes(Vector3(0.05, 0.0, 0.0)), "gate/two_cubes.stl", 1000.0)
	var pair: Dictionary = INSERT.add_mesh_import(doc, pair_path, "", false, INSERT.KIND_MESH)
	pair.feature.options["split"] = true
	var split := REGEN.rebuild(doc, kernel)
	var first: Dictionary = split.bodies.get(str(pair.feature.options.body_id), {})
	var second: Dictionary = split.bodies.get(UTIL.derived_body_id(str(pair.feature.options.body_id), pair.feature.id, 2), {})
	_expect(not split.errors.has(pair.feature.id) and MESH_BODY.is_mesh(first) and MESH_BODY.is_mesh(second) and int(first.shape.triangle_count()) == 12 and int(second.shape.triangle_count()) == 12
		and str(second.get("kind", "")) == "mesh", "One Body per Piece should split two cubes into two mesh bodies (%s)." % split.errors.get(pair.feature.id, ""))
	doc.remove_feature(pair.feature.id)
	doc.remove_feature(plate.feature.id)
	# 3MF and glTF go through the script readers; the cap is the mesh one, not the faceted one.
	var from_3mf: Dictionary = INSERT.read_mesh_body("res://tests/holo_forge/fixtures/cube_10mm_placed.3mf")
	_expect(str(from_3mf.error) == "" and from_3mf.mesh != null and int(from_3mf.triangles) == 12 and absf(from_3mf.mesh.volume() - 1e-6) < 1e-11 and str(from_3mf.units) == "mm",
		"A 3MF file should read as a mesh in meters (%s)." % from_3mf.error)
	var from_obj: Dictionary = INSERT.read_mesh_body("res://tests/holo_forge/fixtures/cube_2cm.obj")
	_expect(str(from_obj.error) == "" and from_obj.mesh != null and int(from_obj.triangles) == 12, "An OBJ file should read as a mesh (%s)." % from_obj.error)
	# The body type can be switched on a feature as it is, both ways.
	var cube_3mf := "res://tests/holo_forge/fixtures/cube_10mm_placed.3mf"
	var old_way: Dictionary = INSERT.add_mesh_import(doc, cube_3mf)
	old_way.feature.options["kind"] = INSERT.KIND_MESH
	var switched := REGEN.rebuild(doc, kernel)
	var as_mesh: Dictionary = switched.bodies.get(str(old_way.feature.options.body_id), {})
	_expect(not switched.errors.has(old_way.feature.id) and MESH_BODY.is_mesh(as_mesh) and int(as_mesh.shape.triangle_count()) == 12 and absf(as_mesh.shape.volume() - 1e-6) < 1e-11,
		"A faceted insert switched to a mesh body should use its stored triangles (%s)." % switched.errors.get(old_way.feature.id, ""))
	old_way.feature.options.erase("kind")
	var new_way: Dictionary = INSERT.add_mesh_import(doc, cube_3mf, "", false, INSERT.KIND_MESH)
	new_way.feature.options["kind"] = INSERT.KIND_SOLID
	var back := REGEN.rebuild(doc, kernel)
	var as_solid: Dictionary = back.bodies.get(str(new_way.feature.options.body_id), {})
	var as_before: Dictionary = back.bodies.get(str(old_way.feature.options.body_id), {})
	_expect(not back.errors.has(new_way.feature.id) and not as_solid.is_empty() and not MESH_BODY.is_mesh(as_solid) and str(as_solid.shape.shape_type()) == "SOLID" and absf(as_solid.shape.volume() - 1e-6) < 1e-11,
		"A mesh-body insert switched to a faceted solid should use its stored mesh (%s)." % back.errors.get(new_way.feature.id, ""))
	_expect(not as_before.is_empty() and not MESH_BODY.is_mesh(as_before) and absf(as_before.shape.volume() - as_solid.shape.volume()) < 1e-12 and (as_before.shape.bbox() as AABB).is_equal_approx(as_solid.shape.bbox() as AABB),
		"Both ways should give the same faceted solid.")
	doc.remove_feature(old_way.feature.id)
	doc.remove_feature(new_way.feature.id)
	_expect(str(INSERT.read_mesh_body(TEMP + "/nope.stl").error).contains("can't be found") and str(INSERT.read_mesh_body("res://project.godot").error).contains("reads STL"),
		"A missing file and an unknown format should be refused.")
	var final := REGEN.rebuild(doc, kernel)
	scene["result"] = final
	_expect(final.errors.is_empty() and final.bodies.size() == 4, "The scene should end with its four bodies (%d, %s)." % [final.bodies.size(), str(final.errors)])
	checked.append("Tessellate (a group per B-rep face, closed, volume within 1 %, Keep Original, same instance on a rebuild, a mesh body refused, a coarse result kept with its warning, one over 5 % off refused and the refusal kept, custom ranges)")
	checked.append("Insert Mesh as a mesh body (blob without positions/indices, placement, units, linked file, open-edge warning, new body only, 3MF/OBJ readers, the body type switched both ways)")


# --- 1. The gate -----------------------------------------------------------------------------

func _check_gate_readers(kernel: RefCounted, scene: Dictionary) -> void:
	var doc: Resource = scene.doc
	var result: Dictionary = scene.result
	var mesh_id: String = scene.mesh
	var gate := GATE_TEXT % doc.body_name(mesh_id)
	var mesh: RefCounted = result.bodies[mesh_id].shape
	var group := _group_name(mesh, Vector3.UP)
	var face := {"kind": "face", "body": mesh_id, "name": group, "sig": {}}
	var edge := {"kind": "edge", "body": mesh_id, "name": "e1", "sig": {}}
	var solid_face := _face_ref(result, scene.solid, Vector3.UP)
	var whole := [_body(mesh_id)]
	# [name, the picks under "picks", a call on a fresh reader]: each must fail with the gate sentence.
	var cases := [
		["bodies", whole, func(r: UTIL.Reader) -> void: _expect(r.bodies("picks").is_empty(), "bodies should return nothing for a mesh body.")],
		["bodies_of (a face pick's body)", whole, func(r: UTIL.Reader) -> void: r.bodies_of([face])],
		["bodies_of (a component)", whole, func(r: UTIL.Reader) -> void: r.bodies_of([{"kind": "component", "component": ""}])],
		["sub_shapes (faces)", [face], func(r: UTIL.Reader) -> void: r.sub_shapes("picks", "face")],
		["sub_shapes (edges)", [edge], func(r: UTIL.Reader) -> void: r.sub_shapes("picks", "edge")],
		["sub_shapes (a body's edges)", whole, func(r: UTIL.Reader) -> void: r.sub_shapes("picks", "edge")],
		["faces_or_bodies (a body)", whole, func(r: UTIL.Reader) -> void: _expect(r.faces_or_bodies("picks").is_empty(), "faces_or_bodies should return nothing for a mesh body.")],
		["faces_or_bodies (a face)", [face], func(r: UTIL.Reader) -> void: r.faces_or_bodies("picks")],
		["tool_shape (a body)", whole, func(r: UTIL.Reader) -> void: _expect(r.tool_shape("picks", 1.0) == null, "tool_shape should return nothing for a mesh body.")],
		["tool_shape (a face)", [face], func(r: UTIL.Reader) -> void: r.tool_shape("picks", 1.0)],
		["profiles", [face], func(r: UTIL.Reader) -> void: r.profiles("picks")],
		["plane", [face], func(r: UTIL.Reader) -> void: r.plane("picks")],
		["axis (a face)", [face], func(r: UTIL.Reader) -> void: r.axis("picks")],
		["axis (an edge)", [edge], func(r: UTIL.Reader) -> void: r.axis("picks")],
		["point", [edge], func(r: UTIL.Reader) -> void: r.point("picks")],
		["points", [edge], func(r: UTIL.Reader) -> void: r.points("picks")],
		["path", [edge], func(r: UTIL.Reader) -> void: r.path("picks")],
		["_checked", whole, func(r: UTIL.Reader) -> void: r._checked({"body": mesh_id, "index": 0, "shape": mesh})],
		["replace", whole, func(r: UTIL.Reader) -> void: _expect(UTIL.replace(r, mesh_id, result.bodies[scene.solid].shape, "Probe") == gate, "replace should return the gate sentence.")],
	]
	for case in cases:
		var probe_ctx := _ctx(doc, kernel, result)
		var r := _reader(probe_ctx, {"picks": case[1]})
		(case[2] as Callable).call(r)
		_expect(r.error == gate, "Reader.%s should fail with the gate sentence for a mesh body (got '%s')." % [case[0], r.error])
		_expect(is_same(probe_ctx.bodies[mesh_id].shape, mesh), "Reader.%s must leave the mesh body as it was." % case[0])
	# The same calls still work on a B-rep body, and allow_mesh lets a mesh body through.
	var ctx := _ctx(doc, kernel, result)
	var solid_reader := _reader(ctx, {"picks": [_body(scene.solid)], "faces": [solid_face]})
	_expect(solid_reader.bodies("picks") == [scene.solid] and solid_reader.sub_shapes("faces", "face").has(scene.solid) and not solid_reader.plane("faces").is_empty() and solid_reader.ok(),
		"B-rep picks should pass the gate (%s)." % solid_reader.error)
	var allowed := _reader(ctx, {"picks": [_body(mesh_id), _body(scene.solid)]})
	_expect(allowed.bodies("picks", true, true) == [mesh_id, scene.solid] and allowed.ok(), "allow_mesh should let a mesh body through (%s)." % allowed.error)
	# The model's size still counts mesh bodies (they answer bbox), so "through all" clears them.
	var only_solid := {"bodies": {scene.solid: result.bodies[scene.solid]}}
	_expect(UTIL.model_size(ctx) >= 1.0 and absf(UTIL.model_span(ctx, Vector3.ZERO, Vector3.RIGHT).y - 0.115) < 1e-6 and absf(UTIL.model_span(only_solid, Vector3.ZERO, Vector3.RIGHT).y - 0.01) < 1e-6,
		"model_size and model_span should take mesh bodies in (%s, %s)." % [UTIL.model_size(ctx), UTIL.model_span(ctx, Vector3.ZERO, Vector3.RIGHT)])
	checked.append("gate in %d Reader paths of util.gd (bodies, bodies_of, sub_shapes, faces_or_bodies, tool_shape, profiles_of, plane, axis, point, points, path, _checked, replace; B-rep picks pass; allow_mesh passes; model_size counts mesh bodies)" % cases.size())


func _check_gate_references(kernel: RefCounted, scene: Dictionary) -> void:
	var doc: Resource = scene.doc
	var result: Dictionary = scene.result
	var mesh_id: String = scene.mesh
	var gate := GATE_TEXT % doc.body_name(mesh_id)
	var mesh: RefCounted = result.bodies[mesh_id].shape
	var group := _group_name(mesh, Vector3.UP)
	var ctx := _ctx(doc, kernel, result)
	var face := {"kind": "face", "body": mesh_id, "name": group, "sig": {}}
	var edge := {"kind": "edge", "body": mesh_id, "name": "e1", "sig": {}}
	var answers := {
		"face": REFERENCES.face(face, ctx), "edge": REFERENCES.edge(edge, ctx), "plane (a face)": REFERENCES.plane(face, ctx),
		"axis (a face)": REFERENCES.axis(face, ctx), "axis (an edge)": REFERENCES.axis(edge, ctx), "point (an edge)": REFERENCES.point(edge, ctx),
		"path (an edge)": REFERENCES.path([edge], ctx),
	}
	for name in answers:
		_expect(str((answers[name] as Dictionary).get("error", "")) == gate, "REFERENCES.%s should answer a mesh body with the gate sentence (%s)." % [name, str(answers[name])])
	var grouped := REFERENCES.group_by_body([face, _body(mesh_id)], ctx, "face")
	_expect(grouped.groups.is_empty() and grouped.errors == [gate], "group_by_body (faces) should report the gate sentence (%s)." % str(grouped.errors))
	grouped = REFERENCES.group_by_body([_body(mesh_id), edge], ctx, "edge")
	_expect(grouped.groups.is_empty() and grouped.errors == [gate, gate], "group_by_body (edges, and a body's edges) should report the gate sentence (%s)." % str(grouped.errors))
	# Face groups: found by name, flat ones give a plane, none gives an axis; picks become group references.
	var ref := {"kind": "mesh_group", "body": mesh_id, "group": group}
	var found := REFERENCES.mesh_group(ref, ctx)
	_expect(not found.has("error") and int(found.index) == mesh.find_face(group) and is_same(found.shape, mesh), "mesh_group should find a face group by name (%s)." % str(found))
	_expect(REFERENCES.mesh_group({"kind": "mesh_group", "body": mesh_id, "group": "nope"}, ctx).has("error") and REFERENCES.mesh_group({"kind": "mesh_group", "body": scene.solid, "group": group}, ctx).has("error"),
		"A group that is gone, or one on a B-rep body, should be an error.")
	var plane := REFERENCES.plane(ref, ctx)
	_expect(not plane.has("error") and (plane.normal as Vector3).dot(Vector3.UP) > 0.999 and absf((plane.origin as Vector3).y - 0.03) < 1e-6, "A flat face group should give its plane (%s)." % str(plane))
	_expect(str(REFERENCES.axis(ref, ctx).get("error", "")) == MESH_BODY.AXIS_GATE, "A face group gives no axis ('%s')." % REFERENCES.axis(ref, ctx).get("error", ""))
	var index: int = mesh.find_face(group)
	var from_group := REFERENCES.from_pick({"kind": "mesh_group", "body": mesh_id, "index": index, "point": Vector3(0.1, 0.03, 0.0)}, result)
	var from_face := REFERENCES.from_pick({"kind": "face", "body": mesh_id, "index": index}, result)
	var from_triangle := REFERENCES.from_pick({"kind": "mesh_triangle", "body": mesh_id, "index": 3, "triangle": 3}, result)
	_expect(str(from_group.get("kind", "")) == "mesh_group" and str(from_group.get("group", "")) == group and from_group.get("at") == Vector3(0.1, 0.03, 0.0) and str(from_face.get("group", "")) == group,
		"A pick on a mesh body should become a face group reference (%s)." % str(from_group))
	_expect(str(from_triangle.get("kind", "")) == "mesh_triangles" and from_triangle.get("triangles") == PackedInt32Array([3]) and str(from_triangle.get("digest", "")) == str(mesh.digest()),
		"A triangle pick should become a triangle reference with the mesh's digest (%s)." % str(from_triangle))
	_expect(REFERENCES.from_pick({"kind": "edge", "body": mesh_id, "index": 0}, result).is_empty() and REFERENCES.from_pick({"kind": "vertex", "body": mesh_id, "index": 0}, result).is_empty()
		and REFERENCES.from_pick({"kind": "body", "body": mesh_id}, result) == _body(mesh_id), "A mesh body has no edge or vertex references; a body pick stays a body reference.")
	_expect(REFERENCES.describe(ref, doc) == "Face Group" and REFERENCES.describe(from_triangle, doc) == "1 Triangle", "Mesh references should describe themselves.")
	checked.append("gate in references.gd (face, edge, group_by_body for faces and edges, plane, axis, point, path); face group references (mesh_group, plane of a flat group, no axis, from_pick)")


func _check_gate_operations(kernel: RefCounted, scene: Dictionary) -> void:
	var doc: Resource = scene.doc
	var result: Dictionary = scene.result
	var mesh_id: String = scene.mesh
	var gate := GATE_TEXT % doc.body_name(mesh_id)
	var mesh: RefCounted = result.bodies[mesh_id].shape
	var feature: Resource = FEATURE.new()
	feature.id = "probe"
	# A box through the mesh body only (the B-rep body it was tessellated from is taken out).
	var tool: RefCounted = kernel.make_box(Vector3(0.01, 0.1, 0.01), Vector3(0.1, 0.0, 0.0), "probe")
	for op in [OPERATIONS.JOIN, OPERATIONS.CUT, OPERATIONS.INTERSECT]:
		var op_ctx := _ctx(doc, kernel, result)
		_expect(OPERATIONS.apply_shape(op_ctx, feature, tool, op, [mesh_id], "") == gate, "A picked mesh target of %s should be refused with the gate sentence ('%s')." % [op, OPERATIONS.apply_shape(op_ctx, feature, tool, op, [mesh_id], "")])
		_expect(OPERATIONS.apply_shape(op_ctx, feature, tool, op, [scene.solid, mesh_id], "") == gate, "A mesh body among %s targets should be refused." % op)
		_expect(is_same(op_ctx.bodies[mesh_id].shape, mesh), "A refused %s must leave the mesh body as it was." % op)
	var ctx := _ctx(doc, kernel, result)
	ctx.bodies.erase(scene.source)
	_expect(OPERATIONS.participating(ctx, tool, []).is_empty() and OPERATIONS.participating(ctx, tool, [mesh_id]) == [mesh_id],
		"A mesh body never takes part by its bounds; a picked one is returned (to be refused).")
	_expect(OPERATIONS.apply_shape(ctx, feature, tool, OPERATIONS.CUT, [], "").contains("doesn't touch any solid body"), "A cut that only reaches a mesh body touches no solid body.")
	feature.options = {"operation": OPERATIONS.AUTO, "body_id": "bodyX"}
	_expect(OPERATIONS.apply(ctx, feature, tool) == "" and ctx.bodies.has("bodyX") and is_same(ctx.bodies[mesh_id].shape, mesh), "Join-or-new-body beside a mesh body should make a new body.")
	checked.append("gate in operations.gd (picked Join/Cut/Intersect targets; mesh bodies never take part by their bounds)")


func _check_gate_features(kernel: RefCounted, scene: Dictionary) -> void:
	var doc: Resource = scene.doc
	var mesh_id: String = scene.mesh
	var solid: String = scene.solid
	var gate := GATE_TEXT % doc.body_name(mesh_id)
	var mesh: RefCounted = scene.result.bodies[mesh_id].shape
	var group := _group_name(mesh, Vector3.UP)
	var face := {"kind": "face", "body": mesh_id, "name": group, "sig": {}}
	var solid_face := _face_ref(scene.result, solid, Vector3.UP)
	var xz := {"kind": "origin", "name": "xz"}
	# [label, type, inputs, options, handler (null: only through regen)]
	var cases := [
		["Fillet of a body", "fillet", {"radius": "1 mm"}, {"edges": [_body(mesh_id)]}, MODIFY],
		["Fillet of a face", "fillet", {"radius": "1 mm"}, {"edges": [face]}, MODIFY],
		["Chamfer", "chamfer", {"distance": "1 mm"}, {"edges": [_body(mesh_id)]}, MODIFY],
		["Shell of a body", "shell", {"thickness": "1 mm"}, {"faces": [_body(mesh_id)]}, MODIFY],
		["Shell of a face", "shell", {"thickness": "1 mm"}, {"faces": [face]}, MODIFY],
		["Draft", "draft", {"angle": ["3 deg", "angle"]}, {"faces": [face], "plane": [xz]}, MODIFY],
		["Scale", "scale", {"scale": ["2", "number"]}, {"bodies": [_body(mesh_id)]}, MODIFY],
		["Combine (target)", "combine", {}, {"target": [_body(mesh_id)], "tools": [_body(solid)], "operation": "join"}, MODIFY],
		["Combine (tool)", "combine", {}, {"target": [_body(solid)], "tools": [_body(mesh_id)], "operation": "cut"}, MODIFY],
		["Offset Face", "offset_face", {"distance": "1 mm"}, {"faces": [face]}, MODIFY],
		["Replace Face (target body)", "replace_face", {}, {"faces": [solid_face], "target": [_body(mesh_id)]}, MODIFY],
		["Split Face (tool body)", "split_face", {}, {"faces": [solid_face], "tool": [_body(mesh_id)]}, MODIFY],
		["Split Body", "split_body", {}, {"body": [_body(mesh_id)], "tool": [xz]}, MODIFY],
		["Split Body (tool body)", "split_body", {}, {"body": [_body(solid)], "tool": [_body(mesh_id)]}, MODIFY],
		["Align", "align", {}, {"from": [{"kind": "origin", "name": "o"}], "to": [{"kind": "origin", "name": "o"}], "objects": [_body(mesh_id)]}, MODIFY],
		["Thicken", "thicken", {"thickness": "1 mm"}, {"faces": [_body(mesh_id)], "operation": OPERATIONS.NEW_BODY}, MODIFY],
		["Boundary Fill", "boundary_fill", {}, {"tools": [_body(mesh_id), xz], "operation": OPERATIONS.NEW_BODY}, MODIFY],
		["Remove of a face", "remove", {}, {"faces": [face]}, MODIFY],
		["Rectangular Pattern", "rect_pattern", {"quantity1": ["2", "number"], "distance1": "10 mm"},
			{"object_type": "bodies", "objects": [_body(mesh_id)], "direction1": [{"kind": "origin", "name": "x"}], "distance_type": "spacing"}, PATTERN],
		["Box joined to a mesh body", "box", {"length": "10 mm", "height": "10 mm", "width": "10 mm"}, {"operation": OPERATIONS.JOIN, "targets": [mesh_id], "position": Vector3(0.1, 0.0, 0.0)}, PRIMITIVE],
		["Surface Stitch", "surface", {}, {"method": "stitch", "bodies": [_body(mesh_id), _body(solid)]}, SURFACE],
		["Surface Trim (a piece of a mesh body)", "surface", {}, {"method": "trim", "tool": [xz], "remove": [face]}, null],
		["Surface Trim (a mesh body's face as the tool)", "surface", {}, {"method": "trim", "tool": [face], "remove": []}, null],
	]
	var direct := 0
	for case in cases:
		var feature := _add(doc, case[1], case[2], case[3])
		var result := REGEN.rebuild(doc, kernel)
		var error := str(result.errors.get(feature.id, ""))
		_expect(error == gate, "%s of a mesh body should be refused with the gate sentence through regen (got '%s')." % [case[0], error])
		_expect(is_same(result.bodies[mesh_id].shape, mesh) and result.bodies.size() == 4, "%s must leave the bodies as they were." % case[0])
		if case[4] != null:
			# The handler by itself (without regen's own check) refuses too.
			var alone_ctx := _ctx(doc, kernel, result)
			var alone: String = case[4].build(feature, alone_ctx)
			_expect(alone == gate, "%s: the handler itself should refuse a mesh body with the gate sentence (got '%s')." % [case[0], alone])
			_expect(is_same(alone_ctx.bodies[mesh_id].shape, mesh), "%s: the handler must leave the mesh body as it was." % case[0])
			direct += 1
		doc.remove_feature(feature.id)
	# The same features still work on the B-rep body beside it.
	var fillet := _add(doc, "fillet", {"radius": "1 mm"}, {"edges": [_body(solid)]})
	var after := REGEN.rebuild(doc, kernel)
	_expect(not after.errors.has(fillet.id) and after.bodies[solid].shape.volume() < 8e-6 - 1e-9, "A fillet on the B-rep body should still work beside a mesh body (%s)." % after.errors.get(fillet.id, ""))
	doc.remove_feature(fillet.id)
	_expect(REGEN.mesh_gate(scene.insert, scene.result.bodies, doc) == "" and REGEN.mesh_gate(scene.tessellate, scene.result.bodies, doc) == "", "Mesh features and Insert Mesh pass regen's check.")
	checked.append("gate in %d Solid and Surface features through regen, %d of them through their handler alone (Fillet, Chamfer, Shell, Draft, Scale, Combine, Offset/Replace/Split Face, Split Body, Align, Thicken, Boundary Fill, Remove of a face, Pattern, Join target, Stitch, Trim), bodies untouched" % [cases.size(), direct])


# --- 2. What takes mesh bodies ---------------------------------------------------------------

func _check_move_copy_remove(kernel: RefCounted, scene: Dictionary) -> void:
	var doc: Resource = scene.doc
	var mesh_id: String = scene.mesh
	var mesh: RefCounted = scene.result.bodies[mesh_id].shape
	var before: AABB = mesh.bbox()
	var move := _add(doc, "move", {"x": "1000 mm", "y": "2000 mm", "z": "3000 mm"}, {"objects": [_body(mesh_id), _body(scene.solid)], "move_type": "free"})
	var moved := REGEN.rebuild(doc, kernel)
	var entry: Dictionary = moved.bodies.get(mesh_id, {})
	_expect(not moved.errors.has(move.id) and MESH_BODY.is_mesh(entry) and str(entry.get("kind", "")) == "mesh", "Move should take a mesh body (%s)." % moved.errors.get(move.id, ""))
	if MESH_BODY.is_mesh(entry):
		var now: AABB = entry.shape.bbox()
		_expect((now.position - before.position - Vector3(1, 2, 3)).length() < 1e-5 and (now.size - before.size).length() < 1e-6 and int(entry.shape.triangle_count()) == int(mesh.triangle_count()),
			"A moved mesh body should sit (1, 2, 3) m further with the same triangles (%s -> %s)." % [before, now])
		_expect(entry.shape.get_face_names() == mesh.get_face_names(), "A moved mesh body should keep its face group names.")
		_expect(is_same(REGEN.rebuild(doc, kernel).bodies[mesh_id].shape, entry.shape), "The same move rebuilt should give the same CadMesh back.")
		_expect(absf(moved.bodies[scene.solid].shape.bbox().position.x - (-0.01 + 1.0)) < 1e-6, "The B-rep body picked with it should move too.")
	doc.remove_feature(move.id)
	var turn := _add(doc, "move", {"angle": ["90 deg", "angle"]}, {"objects": [_body(mesh_id)], "move_type": "rotate", "axis": [{"kind": "origin", "name": "y"}]})
	var turned := REGEN.rebuild(doc, kernel)
	_expect(not turned.errors.has(turn.id) and absf(turned.bodies[mesh_id].shape.volume() - mesh.volume()) < 1e-9 and absf((turned.bodies[mesh_id].shape.bbox() as AABB).get_center().z + 0.1) < 1e-5,
		"A mesh body should turn about an axis (%s)." % turned.errors.get(turn.id, ""))
	doc.remove_feature(turn.id)
	var copy := _add(doc, "move", {"x": "50 mm"}, {"objects": [_body(mesh_id)], "move_type": "free", "copy": true})
	var copied := REGEN.rebuild(doc, kernel)
	var copy_id := UTIL.derived_body_id(mesh_id, copy.id, 1, [mesh_id])
	var twin: Dictionary = copied.bodies.get(copy_id, {})
	_expect(not copied.errors.has(copy.id) and MESH_BODY.is_mesh(twin) and str(twin.get("kind", "")) == "mesh" and is_same(copied.bodies[mesh_id].shape, mesh),
		"Copy should add a mesh body and leave the original (%s)." % copied.errors.get(copy.id, ""))
	if MESH_BODY.is_mesh(twin):
		_expect(absf((twin.shape.bbox() as AABB).position.x - before.position.x - 0.05) < 1e-6 and int(twin.shape.triangle_count()) == int(mesh.triangle_count()), "The copy should sit 50 mm further.")
	var remove := _add(doc, "remove", {}, {"bodies": [_body(mesh_id), _body(copy_id)]})
	var removed := REGEN.rebuild(doc, kernel)
	_expect(not removed.errors.has(remove.id) and not removed.bodies.has(mesh_id) and not removed.bodies.has(copy_id) and removed.bodies.has(scene.solid), "Remove should remove mesh bodies (%s)." % removed.errors.get(remove.id, ""))
	doc.remove_feature(remove.id)
	doc.remove_feature(copy.id)
	checked.append("Move (free and about an axis, same instance on a rebuild), Copy and Remove on mesh bodies")


func _check_display_and_picking(_kernel: RefCounted, scene: Dictionary) -> void:
	var result: Dictionary = scene.result
	var mesh_id: String = scene.mesh
	var mesh: RefCounted = result.bodies[mesh_id].shape
	var count: int = mesh.triangle_count()
	var tess := TESSELLATE.tessellate(mesh)
	for key in ["positions", "normals", "uvs", "indices", "face_ids", "edge_points", "edge_ids", "vertices"]:
		_expect(tess.has(key), "A mesh body's tessellation should have '%s'." % key)
	_expect(is_same(tess.get("cad_mesh"), mesh) and (tess.face_ids as PackedInt32Array).size() == count and (tess.indices as PackedInt32Array).size() == count * 3 and (tess.vertices as PackedVector3Array).is_empty(),
		"The tessellation should hold the stored triangles, their groups and the mesh itself.")
	var surface := TESSELLATE.surface_mesh(tess)
	_expect(surface.get_surface_count() == 1 and surface.surface_get_array_index_len(0) == count * 3, "surface_mesh should draw every triangle.")
	var top: int = mesh.find_face(_group_name(mesh, Vector3.UP))
	var in_top := int(mesh.face_info(top).triangles)
	var subset := TESSELLATE.face_subset_mesh(tess, PackedInt32Array([top]))
	_expect(subset.get_surface_count() == 1 and subset.surface_get_array_index_len(0) == in_top * 3, "face_subset_mesh should draw one face group's triangles (%d)." % in_top)
	var some := TESSELLATE.triangle_subset_mesh(tess, PackedInt32Array([0, 5, count + 7, -1]))
	_expect(some.get_surface_count() == 1 and some.surface_get_array_index_len(0) == 6, "triangle_subset_mesh should draw the listed triangles and skip ones out of range.")
	var lines := TESSELLATE.edge_mesh(tess)
	var borders := TESSELLATE.edge_mesh(tess, PackedInt32Array([TESSELLATE.MESH_GROUP_BORDER]))
	_expect(lines.get_surface_count() == 1 and borders.get_surface_count() == 1 and TESSELLATE.edge_mesh(tess, PackedInt32Array([TESSELLATE.MESH_OPEN_EDGE])).get_surface_count() == 0,
		"A closed box mesh has group borders (the cube's 12 edges) and no open edges.")
	var plate := FIXTURES.to_mesh(FIXTURES.open_plate())
	var open := TESSELLATE.edge_mesh(TESSELLATE.tessellate(plate), PackedInt32Array([TESSELLATE.MESH_OPEN_EDGE]))
	_expect(open.get_surface_count() == 1 and open.surface_get_array_len(0) == 256, "The open plate's 128 open edges should draw as lines.")
	_expect(TESSELLATE.collision_faces(tess).size() == count * 3, "collision_faces should give every triangle.")

	# Picking goes through the mesh itself.
	var solid_tess := TESSELLATE.tessellate(result.bodies[scene.solid].shape)
	var bodies := [PICKING.prepare(mesh_id, tess), PICKING.prepare(scene.solid, solid_tess)]
	_expect(is_same(bodies[0].get("cad_mesh"), mesh) and (bodies[0].face_vertices as Dictionary).is_empty() and not bodies[1].has("cad_mesh"), "A mesh body is prepared without per-face tables; a B-rep body as ever.")
	var project := func(p: Vector3) -> Vector2: return Vector2(p.x, p.z) * 1000.0
	var visible := func(_p: Vector3) -> bool: return true
	var all := {"body": true, "face": true, "edge": true, "vertex": true}
	var from := Vector3(0.105, 1.0, 0.004)
	var mouse := Vector2(105.0, 4.0)
	var hit := PICKING.ray_hit(bodies, from, Vector3.DOWN)
	_expect(str(hit.get("body", "")) == mesh_id and int(hit.get("face", -1)) == top and absf(float(hit.get("distance", 0.0)) - 0.97) < 1e-6, "A ray from above should hit the top face group (%s)." % str(hit))
	var pick := PICKING.pick(bodies, from, Vector3.DOWN, project, mouse, all, "default", 6.0, visible)
	_expect(str(pick.get("kind", "")) == "mesh_group" and str(pick.get("body", "")) == mesh_id and int(pick.get("index", -1)) == top and str(pick.get("group", "")) == _group_name(mesh, Vector3.UP)
		and (pick.get("normal", Vector3.ZERO) as Vector3).dot(Vector3.UP) > 0.999 and ((pick.get("point", Vector3.ZERO) as Vector3) - Vector3(0.105, 0.03, 0.004)).length() < 1e-6,
		"A click on a mesh body should pick its face group, by name (%s)." % str(pick))
	var triangles := all.duplicate()
	triangles["mesh_triangle"] = true
	var one := PICKING.pick(bodies, from, Vector3.DOWN, project, mouse, triangles, "default", 6.0, visible)
	_expect(str(one.get("kind", "")) == "mesh_triangle" and int(one.get("index", -1)) == int(pick.get("triangle", -2)) and int((tess.face_ids as PackedInt32Array)[int(one.index)]) == top,
		"In triangle mode a click should pick the triangle (%s)." % str(one))
	var body_only := PICKING.pick(bodies, from, Vector3.DOWN, project, mouse, {"body": true, "face": false, "edge": false, "vertex": false}, "default", 6.0, visible)
	_expect(str(body_only.get("kind", "")) == "body" and str(body_only.get("body", "")) == mesh_id, "With faces filtered out a mesh body is picked as a body (%s)." % str(body_only))
	_expect(PICKING.pick(bodies, from, Vector3.DOWN, project, mouse, {"body": false, "face": true, "mesh_group": false}, "default", 6.0, visible).is_empty(), "A filter set can leave face groups out.")
	# The corner of the box mesh: its lines are not edges and it has no vertices to pick.
	var corner := Vector2(115.0, 15.0)
	_expect(PICKING.nearest_edge([bodies[0]], project, corner, 6.0, visible).is_empty() and PICKING.nearest_vertex([bodies[0]], project, corner, 6.0, visible).is_empty(),
		"A mesh body has no edges or vertices to pick.")
	_expect(not PICKING.nearest_edge([bodies[1]], project, Vector2(10.0, 0.0), 6.0, visible).is_empty(), "The B-rep body beside it still has edges to pick.")
	# A section's cut-away half lets the ray through to what lies behind.
	var clipped: Dictionary = bodies[0].duplicate()
	clipped["clip"] = {"origin": Vector3(0.1, 0.015, 0.0), "normal": Vector3.UP}
	var under := PICKING.ray_hit([clipped], from, Vector3.DOWN)
	_expect(str(under.get("body", "")) == mesh_id and int(under.get("face", -1)) == mesh.find_face(_group_name(mesh, Vector3.DOWN)) and absf(float(under.get("distance", 0.0)) - 1.0) < 1e-5,
		"A ray through the cut-away half should hit the bottom face group (%s)." % str(under))
	var window := PICKING.window_select(bodies, project, Rect2(80.0, -20.0, 40.0, 40.0), false, "body", visible)
	_expect(window.size() == 1 and str(window[0].body) == mesh_id, "A window round a mesh body should select it as a body (%s)." % str(window))
	_expect(PICKING.window_select(bodies, project, Rect2(80.0, -20.0, 40.0, 40.0), false, "face", visible).is_empty(), "A window selects no B-rep faces on a mesh body.")
	_expect(PICKING.window_select(bodies, project, Rect2(100.0, -20.0, 40.0, 40.0), false, "body", visible).is_empty() and PICKING.window_select(bodies, project, Rect2(100.0, -20.0, 40.0, 40.0), true, "body", visible).size() == 1,
		"A window across a mesh body selects it only when crossing.")
	var key := PICKING.key(pick)
	_expect(PICKING.from_key(key).get("kind") == "mesh_group" and int(PICKING.from_key(key).index) == top, "A face group pick should round-trip through its key (%s)." % key)
	checked.append("display (tessellation keys with the stored triangle order, surface/face-subset/triangle-subset/edge meshes, collision faces) and picking (face group and triangle picks through CadMesh.ray_hit, filters, no edges or vertices, section clip, window select)")


func _check_appearance(_kernel: RefCounted, scene: Dictionary) -> void:
	var doc: Resource = scene.doc
	var mesh_id: String = scene.mesh
	var mesh: RefCounted = scene.result.bodies[mesh_id].shape
	var count: int = mesh.triangle_count()
	var tess := TESSELLATE.tessellate(mesh)
	var base := StandardMaterial3D.new()
	var plain: Dictionary = APPEARANCE.build_mesh(doc, mesh_id, mesh, tess, base)
	_expect(plain.mesh.get_surface_count() == 1 and plain.mesh.surface_get_array_index_len(0) == count * 3 and plain.materials == [base] and plain.ids == PackedStringArray([""])
		and (plain.face_surfaces as PackedInt32Array).count(0) == 6, "A mesh body without appearances should bake to one surface of every triangle.")
	_expect(not APPEARANCE.two_sided(mesh) and APPEARANCE.two_sided(FIXTURES.to_mesh(FIXTURES.open_plate())), "A closed mesh body is one-sided, an open one two-sided.")
	doc.appearances[APPEARANCE.body_target(mesh_id)] = {"material": RED}
	var painted: Dictionary = APPEARANCE.build_mesh(doc, mesh_id, mesh, tess, base)
	_expect(painted.mesh.get_surface_count() == 1 and painted.ids == PackedStringArray([RED]) and painted.materials[0] == MATERIAL_LIBRARY.material(RED) and painted.mesh.surface_get_array_index_len(0) == count * 3,
		"A body appearance should paint the whole mesh body (%s)." % str(painted.ids))
	var top := _group_name(mesh, Vector3.UP)
	doc.appearances[APPEARANCE.face_target(mesh_id, top)] = {"material": CHROME}
	var two: Dictionary = APPEARANCE.build_mesh(doc, mesh_id, mesh, tess, base)
	var in_top := int(mesh.face_info(mesh.find_face(top)).triangles)
	var chrome := (two.ids as PackedStringArray).find(CHROME)
	_expect(two.mesh.get_surface_count() == 2 and chrome >= 0 and two.mesh.surface_get_array_index_len(chrome) == in_top * 3
		and two.mesh.surface_get_array_index_len(1 - chrome) == (count - in_top) * 3 and int(two.face_surfaces[mesh.find_face(top)]) == chrome,
		"A face group appearance should put that group's triangles on their own surface (%s)." % str(two.ids))
	_expect(str(APPEARANCE.resolve(doc, mesh_id, top).material) == CHROME and str(APPEARANCE.resolve(doc, mesh_id, _group_name(mesh, Vector3.DOWN)).material) == RED, "A group's appearance beats its body's.")
	# A curved group has no surface parameters: automatic mapping takes the mesh's own uvs.
	var ball := FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 2))
	var ball_tess := TESSELLATE.tessellate(ball)
	var ball_doc: Resource = DOCUMENT.new()
	ball_doc.appearances["body:ball"] = {"material": CHROME}
	var ball_mesh: Dictionary = APPEARANCE.build_mesh(ball_doc, "ball", ball, ball_tess, base)
	_expect(ball_mesh.mesh.get_surface_count() == 1 and ball_mesh.mesh.surface_get_array_index_len(0) == 320 * 3, "A curved mesh body should take an appearance (automatic mapping).")
	doc.appearances.clear()
	checked.append("appearances on a mesh body (none, by body, by face group name, curved groups)")


func _check_inspect(kernel: RefCounted, scene: Dictionary) -> void:
	var doc: Resource = scene.doc
	var result: Dictionary = scene.result
	var mesh_id: String = scene.mesh
	var solid_id: String = scene.solid
	var mesh: RefCounted = result.bodies[mesh_id].shape
	var ctx := INSPECT.context(result, doc, kernel)
	var mesh_name: String = doc.body_name(mesh_id)

	# --- Measure, through INSPECT.measure -------------------------------------------------------
	var body: Dictionary = INSPECT.measure(_body(mesh_id), {}, ctx)
	_expect(str(body.get("kind", "")) == "body" and bool(body.get("mesh", false)) and absf(float(body.get("volume", 0.0)) - 2.7e-5) < 1e-10 and absf(float(body.get("area", 0.0)) - 5.4e-3) < 1e-8
		and int(body.get("triangles", 0)) == int(mesh.triangle_count()) and int(body.get("groups", 0)) == 6 and not body.has("surface"), "Measure of a mesh body should give its volume and area (%s)." % str(body))
	_expect(body == MESH_BODY.measure(_body(mesh_id), {}, ctx), "INSPECT.measure and MESH_BODY.measure should agree on a mesh body.")
	var top := {"kind": "mesh_group", "body": mesh_id, "group": _group_name(mesh, Vector3.UP)}
	var bottom := {"kind": "mesh_group", "body": mesh_id, "group": _group_name(mesh, Vector3.DOWN)}
	var group: Dictionary = INSPECT.measure(top, {}, ctx)
	_expect(str(group.get("kind", "")) == "face" and bool(group.get("mesh", false)) and str(group.get("face_type", "")) == "plane" and absf(float(group.get("area", 0.0)) - 9e-4) < 1e-9
		and (group.get("normal", Vector3.ZERO) as Vector3).dot(Vector3.UP) > 0.999 and str(group.get("group", "")) == str(top.group), "Measure of a flat face group should read like a plane (%s)." % str(group))
	var between: Dictionary = INSPECT.measure(top, bottom, ctx)
	_expect(str(between.get("kind", "")) == "distance" and absf(float(between.get("distance", 0.0)) - 0.03) < 1e-7 and absf(float(between.get("angle", 1.0))) < 1e-6
		and str(between.get("note", "")) == "Measured between the middle of a face group of %s and the middle of a face group of %s." % [mesh_name, mesh_name],
		"Two face groups should measure 30 mm apart, parallel, and say from where (%s)." % str(between))
	# Against B-rep geometry: the least distance from the mesh reference's point, either way round.
	var solid_top := _face_ref(result, solid_id, Vector3.UP)
	var expected := sqrt(0.09 * 0.09 + 0.01 * 0.01)
	var to_face: Dictionary = INSPECT.measure(top, solid_top, ctx)
	_expect(str(to_face.get("kind", "")) == "distance" and absf(float(to_face.get("distance", 0.0)) - expected) < 1e-7 and absf(float(to_face.get("angle", 1.0))) < 1e-6
		and ((to_face.get("point_a", Vector3.ZERO) as Vector3) - Vector3(0.1, 0.03, 0.0)).length() < 1e-6 and ((to_face.get("point_b", Vector3.ZERO) as Vector3) - Vector3(0.01, 0.02, 0.0)).length() < 1e-6
		and str(to_face.first.get("kind", "")) == "face" and bool(to_face.first.get("mesh", false)) and str(to_face.second.get("face_type", "")) == "plane" and not to_face.second.has("mesh")
		and str(to_face.get("note", "")) == "Measured from the middle of a face group of %s." % mesh_name,
		"A face group against a B-rep face should measure from the group's middle to the face (%s)." % str(to_face))
	var from_face: Dictionary = INSPECT.measure(solid_top, top, ctx)
	_expect(absf(float(from_face.get("distance", 0.0)) - expected) < 1e-7 and ((from_face.get("point_b", Vector3.ZERO) as Vector3) - Vector3(0.1, 0.03, 0.0)).length() < 1e-6
		and ((from_face.get("delta", Vector3.ZERO) as Vector3) + (to_face.get("delta", Vector3.ZERO) as Vector3)).length() < 1e-9 and bool(from_face.second.get("mesh", false)) and not from_face.first.has("mesh"),
		"The same pair the other way round should give the same distance, in the order asked (%s)." % str(from_face))
	var picked_top := top.duplicate()
	picked_top["at"] = Vector3(0.11, 0.03, 0.005)
	var to_plane: Dictionary = INSPECT.measure(picked_top, {"kind": "origin", "name": "xz"}, ctx)
	_expect(absf(float(to_plane.get("distance", 0.0)) - 0.03) < 1e-7 and absf(float(to_plane.get("angle", 1.0))) < 1e-6 and ((to_plane.get("point_b", Vector3.ZERO) as Vector3) - Vector3(0.11, 0.0, 0.005)).length() < 1e-6
		and str(to_plane.get("note", "")) == "Measured from the point picked on %s." % mesh_name, "A picked point on a face group should measure straight down to the ground plane (%s)." % str(to_plane))
	var to_axis: Dictionary = INSPECT.measure(picked_top, {"kind": "origin", "name": "y"}, ctx)
	_expect(absf(float(to_axis.get("distance", 0.0)) - Vector2(0.11, 0.005).length()) < 1e-7 and absf(float(to_axis.get("angle", 0.0)) - PI * 0.5) < 1e-6, "Against the Y axis: the distance to it, and a right angle to a level group (%s)." % str(to_axis))
	var to_vertex: Dictionary = INSPECT.measure(picked_top, {"kind": "vertex", "body": solid_id, "point": Vector3(0.11, 0.13, 0.005)}, ctx)
	_expect(absf(float(to_vertex.get("distance", 0.0)) - 0.1) < 1e-7 and not to_vertex.has("angle"), "Against a point: the distance between the two points (%s)." % str(to_vertex))
	var to_body: Dictionary = INSPECT.measure(picked_top, _body(solid_id), ctx)
	_expect(absf(float(to_body.get("distance", 0.0)) - Vector3(0.1, 0.01, 0.0).length()) < 1e-7 and str(to_body.second.get("kind", "")) == "body" and not to_body.second.has("mesh"),
		"Against a B-rep body: the least distance from the picked point to it (%s)." % str(to_body))
	var body_at := _body(mesh_id)
	body_at["at"] = Vector3(0.085, 0.01, 0.0)
	var from_body: Dictionary = INSPECT.measure(body_at, _face_ref(result, solid_id, Vector3.RIGHT), ctx)
	_expect(absf(float(from_body.get("distance", 0.0)) - 0.075) < 1e-7 and str(from_body.first.get("kind", "")) == "body" and bool(from_body.first.get("mesh", false)), "A point picked on a mesh body measures to a B-rep face (%s)." % str(from_body))
	# A whole mesh body has no point to measure from: refused, with what to do, either way round.
	var whole := "Pick a face group or a point on %s to measure a distance from it (the nearest point of a whole mesh body is not found)." % mesh_name
	_expect(str(INSPECT.measure(_body(mesh_id), solid_top, ctx).get("error", "")) == whole and str(INSPECT.measure(solid_top, _body(mesh_id), ctx).get("error", "")) == whole
		and str(INSPECT.measure(_body(mesh_id), _body(scene.inserted), ctx).get("error", "")) == whole and str(INSPECT.measure(_body(solid_id), _body(mesh_id), ctx).get("error", "")) == whole,
		"A whole mesh body against something else should be refused with a true sentence ('%s')." % INSPECT.measure(_body(mesh_id), solid_top, ctx).get("error", ""))
	_expect(INSPECT.measure({"kind": "mesh_group", "body": mesh_id, "group": "nope"}, {}, ctx).has("error") and INSPECT.measure(top, {"kind": "face", "body": "nope", "name": "x"}, ctx).has("error")
		and str(INSPECT.measure({"kind": "face", "body": mesh_id, "name": "nope"}, solid_top, ctx).get("error", "")).contains("can't be found"), "A group or a face that is gone is an error.")
	# B-rep references alone go the old way.
	var old_way: Dictionary = INSPECT.measure(_body(solid_id), {}, ctx)
	_expect(str(old_way.get("kind", "")) == "body" and not old_way.has("mesh") and absf(float(old_way.get("volume", 0.0)) - 8e-6) < 1e-12 and MESH_BODY.measure(_body(solid_id), {}, ctx).is_empty(), "A B-rep body measures as before (%s)." % str(old_way))
	var plate := FIXTURES.to_mesh(FIXTURES.open_plate())
	var plate_ctx := INSPECT.context({"bodies": {"plate": MESH_BODY.entry("plate", plate, "f")}}, null, kernel)
	var open: Dictionary = INSPECT.measure(_body("plate"), {}, plate_ctx)
	_expect(bool(open.get("surface", false)) and float(open.get("volume", 1.0)) == 0.0 and absf(float(open.get("area", 0.0)) - 1.6e-3) < 1e-8, "An open mesh body measures as a surface without volume (%s)." % str(open))

	# --- Mass properties, through INSPECT ---------------------------------------------------------
	var hollow := FIXTURES.to_mesh(FIXTURES.hollow_cube(false))
	_expect(INSPECT.shape_kind(mesh) == "solid" and INSPECT.shape_kind(plate) == "surface" and INSPECT.shape_kind(hollow) == "solid" and INSPECT.shape_kind(result.bodies[solid_id].shape) == "solid",
		"shape_kind should tell closed mesh bodies (solid) from open ones (surface).")
	_expect(absf(INSPECT.solid_volume(mesh) - 2.7e-5) < 1e-10 and INSPECT.solid_volume(plate) == 0.0 and absf(INSPECT.solid_volume(hollow) - 7e-6) < 1e-11 and is_same(INSPECT.solid_shape(kernel, mesh), mesh) and INSPECT.solid_shape(kernel, plate) == null,
		"solid_volume and solid_shape should take mesh bodies (a hollow one leaves its void out: %s)." % INSPECT.solid_volume(hollow))
	var props: Dictionary = INSPECT.mass_properties(doc, result, [mesh_id])
	var own: Dictionary = props.bodies.get(mesh_id, {})
	_expect(not own.is_empty() and absf(float(own.mass) - float(own.density) * 2.7e-5) < 1e-6 * float(own.mass) and absf(float(props.mass) - float(own.mass)) < 1e-12 and ((props.center as Vector3) - Vector3(0.1, 0.015, 0.0)).length() < 1e-6
		and (own.inertia as PackedFloat64Array).size() == 9 and absf(float(own.inertia[0]) - float(own.mass) * 0.03 * 0.03 / 6.0) < 1e-5 * float(own.inertia[0]) and not own.has("warning"),
		"A closed mesh body should have the mass of its volume at its middle, with a cube's inertia (%s)." % str(own))
	var everything: Dictionary = INSPECT.mass_properties(doc, result, [])
	var solids: Dictionary = INSPECT.mass_properties(doc, result, [solid_id, scene.source])
	var sum := float(solids.mass) + float(own.mass) + float(everything.bodies[scene.inserted].mass)
	_expect(everything.bodies.size() == 4 and absf(float(everything.mass) - sum) < 1e-9 * sum and float(everything.bodies[scene.inserted].mass) > 0.0, "Mass properties of every body should add mesh and B-rep bodies (%s vs %s)." % [everything.mass, sum])
	var through_analysis: Dictionary = ANALYSIS.mass_properties(doc, result, [])
	_expect(absf(float(through_analysis.mass) - float(everything.mass)) < 1e-12 and ((through_analysis.center as Vector3) - (everything.center as Vector3)).length() < 1e-9 and through_analysis.inertia == everything.inertia,
		"The analysis' mass properties and INSPECT's should agree.")
	var plate_props: Dictionary = INSPECT.shape_mass_properties(plate, 1000.0)
	_expect(float(plate_props.mass) == 0.0 and float(plate_props.volume) == 0.0 and absf(float(plate_props.area) - 1.6e-3) < 1e-8 and plate_props.has("warning") and (plate_props.center as Vector3).length() < 1e-6
		and plate_props.inertia == PackedFloat64Array([0, 0, 0, 0, 0, 0, 0, 0, 0]), "An open mesh body has an area and a center, no mass, and says why (%s)." % str(plate_props))
	var with_plate: Dictionary = INSPECT.mass_properties(doc, {"bodies": {"plate": MESH_BODY.entry("plate", plate, "f"), "solid": result.bodies[solid_id]}}, [])
	_expect(with_plate.bodies.plate.has("warning") and not with_plate.bodies.solid.has("warning") and absf(float(with_plate.mass) - float(with_plate.bodies.solid.mass)) < 1e-15,
		"An open mesh body adds no mass, and its entry says why.")
	# The middle of the surface: a mesh body's against the kernel's own of the shape it came from.
	var bracket := FIXTURES.l_bracket()
	var of_mesh: Vector3 = INSPECT.area_center(bracket.mesh)
	var of_shape: Vector3 = INSPECT.area_center(bracket.shape)
	_expect(of_mesh.distance_to(of_shape) < 1e-5 and of_mesh.distance_to(bracket.mesh.center_of_mass()) > 1e-3 and INSPECT.area_center(plate).length() < 1e-7,
		"area_center of a mesh body should be its surface's middle (%s against the B-rep's %s)." % [of_mesh, of_shape])

	# --- Interference, through INSPECT.interference --------------------------------------------
	var pair := FIXTURES.two_cubes(Vector3(0.01, 0.0, 0.0))
	var a := FIXTURES.to_mesh(pair.first)
	var b := FIXTURES.to_mesh(pair.second)
	var far := FIXTURES.to_mesh(FIXTURES.two_cubes(Vector3(0.05, 0.0, 0.0)).second)
	var box: RefCounted = kernel.make_box(Vector3(0.02, 0.02, 0.02), Vector3(0.0, -0.01, -0.01), "ibox")
	var box_far: RefCounted = kernel.make_box(Vector3(0.02, 0.02, 0.02), Vector3(0.05, -0.01, -0.01), "ifar")
	var ball: RefCounted = kernel.make_sphere(0.008, Vector3.ZERO, "iball")
	var entries := {
		"a": MESH_BODY.entry("a", a, "f"), "b": MESH_BODY.entry("b", b, "f"), "far": MESH_BODY.entry("far", far, "f"), "plate": MESH_BODY.entry("plate", plate, "f"),
		"box": {"id": "box", "shape": box, "feature": "f"}, "box_far": {"id": "box_far", "shape": box_far, "feature": "f"}, "ball": {"id": "ball", "shape": ball, "feature": "f"},
	}
	_expect(INSPECT.interference(kernel, entries, ["a", "far"]).is_empty() and INSPECT.interference(kernel, entries, ["a", "box_far"]).is_empty() and INSPECT.interference(kernel, entries, ["far", "plate"]).is_empty(),
		"Bodies apart don't interfere (mesh against mesh, mesh against B-rep, an open one).")
	# An open mesh body has no volume to overlap with; where its bounds reach into another body the
	# pair is listed with why, so it does not read as "no interference".
	for open_pair in [["a", "plate"], ["plate", "box"]]:
		var unknown: Array = INSPECT.interference(kernel, entries, open_pair)
		_expect(unknown.size() == 1 and bool(unknown[0].get("open", false)) and str(unknown[0].get("error", "")).begins_with("plate is an open mesh body") and float(unknown[0].volume) == 0.0 and unknown[0].shape == null,
			"An open mesh body that reaches into %s should be listed with why it is not checked (%s)." % [open_pair, str(unknown)])
	# B-rep against B-rep is the kernel's own, as before.
	var brep_only: Array = INSPECT.interference(kernel, entries, ["box", "ball"])
	_expect(brep_only.size() == 1 and not MESH_BODY.is_mesh(brep_only[0].shape) and not brep_only[0].has("note") and float(brep_only[0].volume) > 0.0, "Two B-rep bodies interfere through the kernel, as before.")
	var mesh_mesh: Array = INSPECT.interference(kernel, entries, ["a", "b"])
	_expect(mesh_mesh.size() == 1 and str(mesh_mesh[0].a) == "a" and str(mesh_mesh[0].b) == "b" and not mesh_mesh[0].has("error") and not mesh_mesh[0].has("note")
		and absf(float(mesh_mesh[0].volume) - 4e-6) < 1e-9 and MESH_BODY.is_mesh(mesh_mesh[0].shape), "Two 20 mm mesh cubes 10 mm apart should overlap by 4,000 mm3 (%s)." % str(mesh_mesh))
	# A mesh body against a B-rep body: the B-rep body is tessellated, and the entry says so.
	var mesh_brep: Array = INSPECT.interference(kernel, entries, ["a", "box"])
	_expect(mesh_brep.size() == 1 and not mesh_brep[0].has("error") and absf(float(mesh_brep[0].volume) - 4e-6) < 1e-9 and MESH_BODY.is_mesh(mesh_brep[0].shape)
		and str(mesh_brep[0].get("note", "")) == "box was tessellated for Interference.", "A mesh cube and a B-rep box should overlap by 4,000 mm3, with the note (%s)." % str(mesh_brep))
	var brep_mesh: Array = INSPECT.interference(kernel, entries, ["box", "a"])
	_expect(brep_mesh.size() == 1 and str(brep_mesh[0].a) == "box" and absf(float(brep_mesh[0].volume) - 4e-6) < 1e-9 and str(brep_mesh[0].get("note", "")) == "box was tessellated for Interference.",
		"The same pair the other way round should give the same overlap (%s)." % str(brep_mesh))
	var hits := MESH_FEATURE.cache_hits
	var named: Array = INSPECT.interference(kernel, {mesh_id: result.bodies[mesh_id], solid_id: {"id": solid_id, "shape": kernel.make_box(Vector3(0.03, 0.03, 0.03), Vector3(0.1, 0.0, -0.015), "inamed")}}, [], doc)
	_expect(named.size() == 1 and absf(float(named[0].volume) - 0.015 * 0.03 * 0.03) < 1e-9 and str(named[0].get("note", "")) == "%s was tessellated for Interference." % doc.body_name(solid_id),
		"With the design given, the note should name the body (%s)." % str(named))
	INSPECT.interference(kernel, entries, ["a", "box"])
	_expect(MESH_FEATURE.cache_hits > hits, "A B-rep body tessellated once for Interference should not be meshed again.")
	# A curved B-rep body: its triangles, so about the ball's volume (inside the cube).
	var round: Array = INSPECT.interference(kernel, entries, ["a", "ball"])
	var ball_volume: float = ball.volume()
	_expect(round.size() == 1 and absf(float(round[0].volume) - ball_volume) < 0.01 * ball_volume and float(round[0].volume) < ball_volume and str(round[0].get("note", "")).begins_with("ball was tessellated"),
		"A ball inside a mesh cube should overlap by about its volume (%s of %s)." % [str(round[0].volume) if not round.is_empty() else "none", ball_volume])
	# Every pair at once: the B-rep pairs and the mesh pairs side by side.
	var all: Array = INSPECT.interference(kernel, entries, [])
	var pairs := all.map(func(hit: Dictionary) -> String: return "%s-%s" % [hit.a, hit.b])
	_expect(pairs == ["a-b", "a-plate", "a-box", "a-ball", "b-plate", "b-box", "b-ball", "far-box_far", "plate-box", "plate-ball", "box-ball"]
		and all.all(func(hit: Dictionary) -> bool: return hit.has("error") == (str(hit.a) == "plate" or str(hit.b) == "plate")), "Every overlapping pair should be listed once, the open plate's as not checked (%s)." % str(pairs))
	# Bounds that overlap around bodies that don't: no interference, and no error either.
	var sphere_mesh := FIXTURES.to_mesh(FIXTURES.icosphere(0.02, 3))
	var beside := FIXTURES.to_mesh(FIXTURES.two_cubes(Vector3(0.024, 0.024, 0.024)).second)
	var clear: Dictionary = MESH_BODY.interference(sphere_mesh, beside)
	_expect((sphere_mesh.bbox() as AABB).intersects(beside.bbox() as AABB) and float(clear.volume) == 0.0 and clear.shape == null and not clear.has("error")
		and INSPECT.interference(kernel, {"s": MESH_BODY.entry("s", sphere_mesh, "f"), "c": MESH_BODY.entry("c", beside, "f")}, []).is_empty(),
		"A ball and a cube off its corner don't interfere, though their bounds overlap (%s)." % str(clear))
	var corner_box: RefCounted = kernel.make_box(Vector3(0.02, 0.02, 0.02), Vector3(0.014, 0.014, 0.014), "icorner")
	_expect(INSPECT.interference(kernel, {"s": MESH_BODY.entry("s", sphere_mesh, "f"), "c": {"id": "c", "shape": corner_box, "feature": "f"}}, []).is_empty(),
		"A mesh ball and a B-rep box off its corner don't interfere either.")
	if not sphere_mesh.get_last_report().has("empty"):
		notes.append("CadMesh.boolean's report has no 'empty' flag in this build: an empty intersection is told by the kernel's sentence (the fallback in MESH_BODY.interference).")
	checked.append("Measure through INSPECT (mesh body, flat face group, two groups, a group or a picked point against a B-rep face, plane, axis, point and body, either way round, a whole mesh body refused, open body, B-rep alone as before), mass properties through INSPECT (shape_kind, solid_volume, closed, open with its warning, hollow, with B-rep bodies, area_center against the kernel's), interference through INSPECT (apart, open, B-rep pairs as before, mesh against mesh, mesh against B-rep both ways with the note and the cache, a curved B-rep body, every pair at once, overlapping bounds without overlap)")


func _check_analyses(kernel: RefCounted, scene: Dictionary) -> void:
	var doc: Resource = scene.doc
	var result: Dictionary = scene.result
	var mesh_id: String = scene.mesh
	var mesh: RefCounted = result.bodies[mesh_id].shape
	var tess := TESSELLATE.tessellate(mesh)
	var vertices := (tess.positions as PackedVector3Array).size()
	var zebra := _analysis("zebra", {}, result, kernel, doc)
	_expect(not zebra.has("error") and zebra.body_materials.has(mesh_id) and zebra.body_materials.has(scene.solid), "Zebra should stripe mesh bodies too.")
	var draft := _analysis("draft", {"pull": Vector3.UP}, result, kernel, doc)
	_expect(not draft.has("error") and draft.body_meshes.has(mesh_id) and (draft.values[mesh_id] as PackedFloat64Array).size() == vertices and str(draft.info).begins_with("Needs draft"), "Draft should color mesh bodies (%s)." % draft.get("error", ""))
	var access := _analysis("accessibility", {"direction": Vector3.DOWN}, result, kernel, doc)
	_expect(not access.has("error") and access.body_meshes.has(mesh_id) and (access.values[mesh_id] as PackedFloat64Array).size() == vertices, "Accessibility should color mesh bodies (%s)." % access.get("error", ""))
	var chrome := _analysis("environment_map", {}, result, kernel, doc)
	var colors := _analysis("component_colors", {}, result, kernel, doc)
	_expect(chrome.body_materials.has(mesh_id) and colors.body_materials.has(mesh_id), "Environment map and component colors should take mesh bodies.")
	var com := _analysis("center_of_mass", {}, result, kernel, doc)
	_expect(not com.has("error") and com.points.size() == 5 and str(com.info).begins_with("Mass "), "Center of Mass should mark every body, mesh ones too (%d points, %s)." % [com.points.size(), com.get("error", "")])

	# Section: the plane's cut through a mesh body is drawn as lines and counted in the area.
	var only_mesh := {"bodies": {mesh_id: result.bodies[mesh_id]}, "values": result.values, "sketches": {}, "construction": {}}
	var section := _analysis("section", {"origin": Vector3(0.1, 0.015, 0.0), "normal": Vector3.RIGHT}, only_mesh, kernel, doc)
	_expect(not section.has("error") and section.body_materials.has(mesh_id) and section.lines.size() == 1 and section.meshes.is_empty() and str(section.info) == "Section area 900 mm²",
		"A section through a mesh body should draw its outline and give its area (%d lines, '%s', %s)." % [section.lines.size(), section.info, section.get("error", "")])
	var mixed := _analysis("section", {"origin": Vector3(0.0, 0.005, 0.0), "normal": Vector3.UP}, result, kernel, doc)
	_expect(not mixed.has("error") and mixed.lines.size() == 2 and mixed.meshes.size() == 2 and str(mixed.info) == "Section area 2600 mm²",
		"A section through B-rep and mesh bodies should cap the solids and outline the meshes (%d lines, %d caps, '%s')." % [mixed.lines.size(), mixed.meshes.size(), mixed.info])
	var hollow := FIXTURES.to_mesh(FIXTURES.hollow_cube(true))
	var cut: Dictionary = ANALYSIS.mesh_section(hollow, Vector3.ZERO, Vector3.UP)
	_expect(cut.lines.size() == 3 and int(cut.open) == 0 and absf(float(cut.area) - (400.0 - 100.0 + 16.0) * 1e-6) < 1e-10, "A hollow body with an island sections to wall + island (%s m2 in %d curves)." % [cut.area, cut.lines.size()])
	var plate := FIXTURES.to_mesh(FIXTURES.open_plate())
	var slit: Dictionary = ANALYSIS.mesh_section(plate, Vector3(0.0003, 0.0, 0.0), Vector3.RIGHT)
	_expect(slit.lines.size() == 1 and int(slit.open) == 1 and float(slit.area) == 0.0, "An open mesh sections to an open curve without area (%s)." % str(slit.open))
	checked.append("analyses on mesh bodies (Zebra, Draft, Accessibility, environment map, component colors, Center of Mass, Section outline and area alone, with B-rep bodies, hollow and open)")


func _analysis(type: String, options: Dictionary, result: Dictionary, kernel: RefCounted, doc: Resource) -> Dictionary:
	return ANALYSIS.build({"id": "a1", "type": type, "name": type, "visible": true, "options": options}, result, {}, kernel, doc)


# --- 3. What refuses mesh bodies -------------------------------------------------------------

func _check_refused(kernel: RefCounted, scene: Dictionary) -> void:
	var doc: Resource = scene.doc
	var result: Dictionary = scene.result
	var mesh_id: String = scene.mesh
	var mesh: RefCounted = result.bodies[mesh_id].shape
	var sentence := "Not available on mesh bodies. Convert the body first."
	# Only mesh bodies shown: the analysis is the sentence.
	for id in [scene.solid, scene.source]:
		doc.bodies[id]["visible"] = false
	for case in [["curvature_map", {"mode": "gaussian"}], ["minimum_radius", {"radius": 0.001}], ["isocurve", {}], ["curvature_comb", {"edges": [_body(mesh_id)]}]]:
		var out := _analysis(case[0], case[1], result, kernel, doc)
		_expect(str(out.get("error", "")) == sentence and out.body_meshes.is_empty() and out.lines.is_empty(), "%s of mesh bodies should be refused ('%s')." % [case[0], out.get("error", out.info)])
	for id in [scene.solid, scene.source]:
		doc.bodies[id]["visible"] = true
	# Beside B-rep bodies: they are analysed, the mesh bodies are named with the sentence.
	for case in [["curvature_map", {"mode": "gaussian"}], ["minimum_radius", {"radius": 0.001}], ["isocurve", {"planar": true}]]:
		var out := _analysis(case[0], case[1], result, kernel, doc)
		_expect(not out.has("error") and str(out.info).ends_with(sentence) and str(out.info).contains(doc.body_name(mesh_id)) and not out.body_meshes.has(mesh_id),
			"%s beside B-rep bodies should leave the mesh bodies out and say so ('%s')." % [case[0], out.get("error", out.info)])
		if case[0] != "isocurve":
			_expect(out.body_meshes.has(scene.solid), "%s should still color the B-rep bodies." % case[0])
		else:
			_expect(out.lines.size() > 0, "Isocurves should still be drawn on the B-rep bodies.")
	_expect(str(_analysis("curvature_comb", {"edges": [_body(scene.solid), _body(mesh_id)]}, result, kernel, doc).get("error", "")) == sentence, "A comb on a mesh body's edges should be refused.")
	# Decals need a B-rep face.
	var decal := {"id": "d1", "name": "Logo", "body": mesh_id, "face": _group_name(mesh, Vector3.UP), "position": Vector3(0.1, 0.03, 0.0), "normal": Vector3.UP, "size": Vector2(0.01, 0.01)}
	var placed: Dictionary = APPEARANCE.placed_decal(decal, mesh, kernel)
	_expect(str(placed.get("error", "")) == "Decals need a B-rep face. Convert the body first." and bool(placed.get("lost", false)) and placed.position == decal.position,
		"A decal on a mesh body should be refused and stay where it was (%s)." % str(placed.get("error", "")))
	_expect(APPEARANCE.decal_gate(mesh) == "Decals need a B-rep face. Convert the body first." and APPEARANCE.decal_gate(result.bodies[scene.solid].shape) == "", "decal_gate should refuse mesh bodies only.")
	checked.append("refusals (curvature map, minimum radius, isocurve, curvature comb: the sentence alone, or naming the mesh bodies beside B-rep ones; decals)")


func _check_export(kernel: RefCounted, scene: Dictionary) -> void:
	var doc: Resource = scene.doc
	var result: Dictionary = scene.result
	var mesh_id: String = scene.mesh
	var mesh: RefCounted = result.bodies[mesh_id].shape
	var count: int = mesh.triangle_count()
	var folder := TEMP + "/export"
	# STL, OBJ and 3MF hold the very triangles.
	var stl := folder + "/mesh.stl"
	var report: Dictionary = EXPORT.export_cad_report(kernel, result, [mesh_id], stl, doc)
	var back: RefCounted = MESH_BODY.new_mesh()
	_expect(str(report.error) == "" and str(report.note) == "" and report.written == [mesh_id] and back.read_stl(stl, 0.001) and int(back.triangle_count()) == count
		and absf(back.volume() - mesh.volume()) < 1e-9 and ((back.bbox() as AABB).position - (mesh.bbox() as AABB).position).length() < 1e-6,
		"STL should hold the mesh body's %d triangles in millimeters (%s, read %d)." % [count, report.error, back.triangle_count()])
	var obj := folder + "/mesh.obj"
	var obj_error: String = EXPORT.export_cad(kernel, result, [mesh_id, scene.inserted], obj, doc)
	back = MESH_BODY.new_mesh()
	_expect(obj_error == "" and back.read_obj(obj, 0.001) and int(back.triangle_count()) == count + 12 and absf(back.volume() - mesh.volume() - 8e-6) < 1e-9,
		"OBJ should hold both mesh bodies' triangles (%s, read %d)." % [obj_error, back.triangle_count()])
	var text := FileAccess.get_file_as_string(obj)
	_expect(text.count("\ng ") == 7 and text.count("\no ") == 2, "The OBJ should have an object per body and a group per face group (%d, %d)." % [text.count("\no "), text.count("\ng ")])
	var threemf := folder + "/mesh.3mf"
	var threemf_error: String = EXPORT.export_cad(kernel, result, [mesh_id, scene.inserted], threemf, doc)
	var read: Dictionary = MESH_IMPORT.read_3mf(threemf)
	_expect(threemf_error == "" and str(read.error) == "" and int(read.triangles) == count + 12 and str(read.get("file_units", "")) == "mm",
		"3MF should hold both mesh bodies' triangles in millimeters (%s %s, read %d)." % [threemf_error, read.error, int(read.get("triangles", 0))])
	# STL of B-rep and mesh bodies together: the kernel's triangles of the solids plus the mesh's own.
	var solid_stl := folder + "/solid.stl"
	var both_stl := folder + "/both.stl"
	_expect(EXPORT.export_cad(kernel, result, [scene.solid], solid_stl, doc) == "", "A B-rep body should export to STL as before.")
	var solid_back: RefCounted = MESH_BODY.new_mesh()
	var solid_count := int(solid_back.triangle_count()) if solid_back.read_stl(solid_stl, 0.001) else -1
	back = MESH_BODY.new_mesh()
	_expect(EXPORT.export_cad(kernel, result, [scene.solid, mesh_id], both_stl, doc) == "" and back.read_stl(both_stl, 0.001) and int(back.triangle_count()) == count + solid_count and solid_count == 12
		and absf(back.volume() - 8e-6 - 2.7e-5) < 1e-9, "STL of a B-rep and a mesh body should hold both (%d of %d + %d)." % [back.triangle_count(), solid_count, count])
	_expect(not FileAccess.file_exists(folder + "/both.holo_forge_brep_part.stl"), "The STL written beside for the B-rep bodies should be removed.")
	# STEP: the mesh body is left out and listed; the others still export.
	var step := folder + "/all.step"
	var named := "%s is a mesh body; STEP/IGES need B-rep bodies. Convert it first, or export STL/OBJ/3MF." % doc.body_name(mesh_id)
	report = EXPORT.export_cad_report(kernel, result, [], step, doc)
	_expect(str(report.error) == "" and FileAccess.file_exists(step) and report.skipped == [mesh_id, scene.inserted] and report.written == [scene.solid, scene.source]
		and str(report.note).contains(named) and str(report.note).contains("The other 2 bodies were exported"), "STEP should leave the mesh bodies out and list them (%s / %s)." % [report.error, report.note])
	var imported: RefCounted = kernel.import_file(ProjectSettings.globalize_path(step), "back")
	_expect(imported != null and absf(imported.volume() - 8e-6 - 2.7e-5) < 1e-9, "The STEP file should hold the two B-rep bodies.")
	_expect(EXPORT.export_cad(kernel, result, [], folder + "/all2.step", doc) == str(report.note).replace("all.step", "all2.step") and FileAccess.file_exists(folder + "/all2.step"),
		"export_cad should return the sentence naming the bodies left out.")
	report = EXPORT.export_cad_report(kernel, result, [mesh_id], folder + "/none.step", doc)
	_expect(str(report.error) == named and report.skipped == [mesh_id] and not FileAccess.file_exists(folder + "/none.step"), "STEP of mesh bodies alone should be refused and write nothing ('%s')." % report.error)
	for ext in ["iges", "brep"]:
		_expect(EXPORT.export_cad_report(kernel, result, [scene.solid, mesh_id], folder + "/part." + ext, doc).skipped == [mesh_id], "%s should leave the mesh body out." % ext.to_upper())
	# OBJ and 3MF hold mesh bodies only.
	report = EXPORT.export_cad_report(kernel, result, [scene.solid, mesh_id], folder + "/mixed.obj", doc)
	_expect(str(report.error) == "" and report.skipped == [scene.solid] and str(report.note).contains("is a B-rep body"), "OBJ should leave B-rep bodies out and say so (%s)." % report.note)
	_expect(EXPORT.export_cad(kernel, result, [scene.solid], folder + "/solid.obj", doc) != "" and not FileAccess.file_exists(folder + "/solid.obj"), "OBJ of B-rep bodies alone should be refused.")
	checked.append("export (STL, OBJ and 3MF with the exact triangle count in millimeters, STL with B-rep bodies added, STEP/IGES/BREP leaving mesh bodies out and listing them, OBJ leaving B-rep bodies out)")


func _check_bake(kernel: RefCounted, scene: Dictionary) -> void:
	var doc: Resource = scene.doc
	var mesh_id: String = scene.mesh
	var result := REGEN.rebuild(doc, kernel)
	var mesh: RefCounted = result.bodies[mesh_id].shape
	var count: int = mesh.triangle_count()
	var part: Node3D = CAD_PART.new()
	part.name = "GatePart"
	part.document = doc
	part.generate_collision = true
	root.add_child(part)
	part.apply_result(result)
	await process_frame
	var nodes: Dictionary = part.body_nodes()
	var node: MeshInstance3D = nodes.get(mesh_id)
	_expect(nodes.size() == 4 and node != null and node.mesh != null, "Every body, mesh ones too, should bake to a MeshInstance3D (%d nodes)." % nodes.size())
	if node != null and node.mesh != null:
		var baked := 0
		for s in node.mesh.get_surface_count():
			baked += int(node.mesh.surface_get_array_index_len(s) / 3.0)
		_expect(baked == count and node.name == doc.body_name(mesh_id).validate_node_name(), "The baked mesh body should have its %d triangles (got %d) and its name (%s)." % [count, baked, node.name])
		_expect((node.get_aabb().position - (mesh.bbox() as AABB).position).length() < 1e-6 and (node.get_aabb().size - (mesh.bbox() as AABB).size).length() < 1e-6, "The baked mesh body should have the mesh's bounds.")
		var collision := node.get_node_or_null("Collision/Shape") as CollisionShape3D
		_expect(collision != null and collision.shape is ConcavePolygonShape3D and (collision.shape as ConcavePolygonShape3D).get_faces().size() == count * 3 and not (collision.shape as ConcavePolygonShape3D).backface_collision,
			"Collision should cover every triangle of a closed mesh body, one-sided.")
	# A face group appearance bakes to its own surface; an open mesh bakes two-sided.
	doc.appearances[APPEARANCE.face_target(mesh_id, _group_name(mesh, Vector3.UP))] = {"material": CHROME}
	doc.decals.append({"id": "d1", "name": "Logo", "body": mesh_id, "face": _group_name(mesh, Vector3.UP), "position": Vector3(0.1, 0.03, 0.0), "normal": Vector3.UP, "size": Vector2(0.01, 0.01), "visible": true, "image": ""})
	part.apply_result(result)
	await process_frame
	node = part.body_nodes().get(mesh_id)
	_expect(node != null and node.mesh.get_surface_count() == 2, "A face group's appearance should bake to a surface of its own.")
	var kept: Node = node.get_node_or_null("Logo") if node != null else null
	_expect(kept is Decal and ((kept as Decal).position - Vector3(0.1, 0.03, 0.0)).length() < 1e-6, "A decal left on a mesh body should stay at its stored place.")
	doc.appearances.clear()
	doc.decals.clear()
	root.remove_child(part)
	part.free()
	checked.append("bake (a MeshInstance3D with the same triangle count and bounds, collision faces, a surface per face group appearance, a decal kept in place)")


# --- 4. Old designs --------------------------------------------------------------------------

func _check_old_documents(kernel: RefCounted) -> void:
	var packed: PackedScene = load(OLD_SCENE)
	var scene_root := packed.instantiate()
	var parts := 0
	for node in [scene_root] + scene_root.find_children("*", "Node3D", true, false):
		var doc: Variant = node.get("document")
		if doc == null:
			continue
		parts += 1
		_expect_old("%s in %s" % [node.name, OLD_SCENE.get_file()], REGEN.rebuild(doc, kernel), OLD_SCENE_PART)
		for feature in doc.features:
			_expect(feature.type != "mesh" and not feature.options.has("kind"), "The old scene's features should have no mesh settings.")
	scene_root.free()
	_expect(parts == 1, "The fixture scene should hold one part (found %d)." % parts)
	for file in OLD_MESHES:
		var doc: Resource = DOCUMENT.new()
		var added: Dictionary = INSERT.add_mesh_import(doc, "res://tests/holo_forge/fixtures/" + file)
		_expect(str(added.error) == "" and added.feature != null, "%s should insert the old way (%s)." % [file, added.error])
		if added.feature == null:
			continue
		_expect(not added.feature.options.has("kind") and not added.feature.options.has("mesh") and added.feature.options.has("positions") and INSERT.mesh_kind(added.feature) == "solid",
			"An Insert Mesh without a kind should be a faceted solid, stored as before (%s)." % str(added.feature.options.keys()))
		_expect_old(file, REGEN.rebuild(doc, kernel), OLD_MESHES[file])
		# An explicit "solid" is the same thing.
		added.feature.options["kind"] = "solid"
		_expect_old(file + " (kind solid)", REGEN.rebuild(doc, kernel), OLD_MESHES[file])
	checked.append("old designs (the saved fixture scene's part and %d fixture meshes inserted without a kind rebuild to the recorded body counts, volumes, areas, face counts and shape types, as B-rep bodies)" % OLD_MESHES.size())


func _expect_old(label: String, result: Dictionary, recorded: Array) -> void:
	var bodies: Dictionary = result.bodies
	_expect(result.errors.is_empty() and bodies.size() == int(recorded[0]), "%s should rebuild to %d bodies without errors (%d, %s)." % [label, recorded[0], bodies.size(), str(result.errors)])
	var volume := 0.0
	var area := 0.0
	var faces := 0
	var types := []
	for body_id in bodies:
		var entry: Dictionary = bodies[body_id]
		_expect(not entry.has("kind") and not MESH_BODY.is_mesh(entry), "%s: body %s should be a B-rep body with no kind." % [label, body_id])
		volume += float(entry.shape.volume())
		area += float(entry.shape.area())
		faces += int(entry.shape.face_count())
		types.append(str(entry.shape.shape_type()))
	_expect(absf(volume - float(recorded[1])) <= OLD_DECIMALS and absf(area - float(recorded[2])) <= OLD_DECIMALS and faces == int(recorded[3]) and types == [recorded[4]],
		"%s should rebuild as recorded: volume %.12f (now %.12f), area %.12f (now %.12f), %d faces (now %d), %s (now %s)." % [label, recorded[1], volume, recorded[2], area, recorded[3], faces, recorded[4], str(types)])


# --- 5. Stored meshes ------------------------------------------------------------------------

func _check_blobs(kernel: RefCounted) -> void:
	var small_mesh := FIXTURES.to_mesh(FIXTURES.two_cubes(Vector3(0.05, 0.0, 0.0)))
	var big_mesh := FIXTURES.to_mesh(FIXTURES.large_grid(100))
	var small: Resource = MESH_BLOB.from_mesh(small_mesh)
	var big: Resource = MESH_BLOB.from_mesh(big_mesh)
	_expect(small != null and big != null and str(small.format) == "HFM1" and int(small.triangles) == 24 and int(small.vertices) == 16 and int(small.size) == small_mesh.to_blob().size()
		and str(small.digest) == MESH_BLOB.sha256_hex(small_mesh.to_blob()) and str(small.digest).length() == 64, "A blob should record its format, counts, size and SHA-256.")
	if small == null or big == null:
		return
	_expect(not small.is_large() and big.is_large() and (big.data as PackedByteArray).size() > 256 * 1024 and (big.data as PackedByteArray).size() < int(big.size),
		"The fixtures should sit on both sides of 256 KB (%d and %d compressed bytes)." % [(small.data as PackedByteArray).size(), (big.data as PackedByteArray).size()])
	var decoded: RefCounted = big.to_mesh()
	_expect(decoded != null and str(decoded.digest()) == str(big_mesh.digest()) and not is_same(decoded, big_mesh) and str(big.last_error) == "", "A blob should decode to the same mesh content (%s)." % big.last_error)
	_expect(MESH_BLOB.from_mesh(null) == null and MESH_BLOB.from_mesh(MESH_BODY.new_mesh()) == null, "No mesh, or an empty one, makes no blob.")

	# A part with one small and one big stored mesh: only the big one goes beside the scene.
	var doc: Resource = DOCUMENT.new()
	var features := []
	for blob in [small, big]:
		var feature: Resource = doc.add_feature("mesh_import", "Mesh", {}, {
			"path": "", "kind": "mesh", "units": "m", "mesh_units": "m", "linked": false, "split": false, "transform": Transform3D.IDENTITY,
			"operation": OPERATIONS.NEW_BODY, "mesh": blob,
		})
		feature.options["body_id"] = doc.new_body(feature.id)
		features.append(feature)
	var part: Node3D = CAD_PART.new()
	part.name = "BlobPart"
	part.document = doc
	root.add_child(part)
	var folder := TEMP + "/scene_forge"
	var expected := "%s/BlobPart_mesh_%s.res" % [folder, str(big.digest).substr(0, 16)]
	var kept: Array = part.save_mesh_blobs(folder)
	_expect(kept == [expected] and FileAccess.file_exists(expected) and str(big.resource_path) == expected and str(small.resource_path) == "" and _files(folder).size() == 1,
		"Only the big blob should be saved beside the scene, named after its digest (%s; files %s)." % [str(kept), str(_files(folder))])
	var stamp := FileAccess.get_modified_time(expected)
	var size := FileAccess.get_file_as_bytes(expected).size()
	_expect(part.save_mesh_blobs(folder) == [expected] and _files(folder).size() == 1 and FileAccess.get_modified_time(expected) == stamp and FileAccess.get_file_as_bytes(expected).size() == size,
		"Saving again should write nothing new.")
	# A board-model save's editable source holds the big mesh itself (it leaves the project).
	var boards := TEMP + "/boards"
	var board: Dictionary = EXPORT.board_model_export(part, kernel, {}, "GateBoard", ["tres"], boards)
	var board_text := FileAccess.get_file_as_string(str(board.paths[0])) if not (board.paths as Array).is_empty() else ""
	_expect(str(board.error) == "" and int(board.version) == 1 and board_text.contains("digest = \"%s\"" % str(big.digest)) and not board_text.contains("_mesh_") and str(big.resource_path) == expected,
		"A board model's .tres should embed a stored mesh kept beside the scene, and leave the design's own blob alone (%s)." % board.error)
	_remove_folder(boards)
	# An undo state shares the blob, so it shares the file.
	var state: Dictionary = doc.snapshot()
	_expect(is_same(state.features[1].options.mesh, big) and str(state.features[1].options.mesh.resource_path) == expected, "A snapshot's blob is the same one, with the same file.")
	# The scene refers to the big blob's file and embeds the small one; it loads back to the same meshes.
	var holder := Node3D.new()
	holder.name = "BlobScene"
	root.remove_child(part)
	holder.add_child(part)
	part.owner = holder
	var packed := PackedScene.new()
	var scene_path := TEMP + "/scene.tscn"
	_expect(packed.pack(holder) == OK and ResourceSaver.save(packed, scene_path) == OK, "The scene with stored meshes should save.")
	var scene_text := FileAccess.get_file_as_string(scene_path)
	_expect(scene_text.contains(expected.get_file()) and scene_text.length() < 200 * 1024 and scene_text.contains(str(small.digest)) and not scene_text.contains("digest = \"%s\"" % str(big.digest)),
		"The scene file should link the big blob's file and hold the small blob (%d bytes of text)." % scene_text.length())
	holder.free()
	var loaded_scene: PackedScene = ResourceLoader.load(scene_path, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
	var loaded_root := loaded_scene.instantiate() if loaded_scene != null else null
	var loaded_part: Node = loaded_root.get_node_or_null("BlobPart") if loaded_root != null else null
	_expect(loaded_part != null and loaded_part.get("document") != null, "The saved scene should load back with its part.")
	if loaded_part != null and loaded_part.get("document") != null:
		var loaded_doc: Resource = loaded_part.get("document")
		var loaded_small: Variant = loaded_doc.features[0].options.get("mesh")
		var loaded_big: Variant = loaded_doc.features[1].options.get("mesh")
		_expect(loaded_small is Resource and loaded_big is Resource and loaded_small.get_script() == MESH_BLOB and str(loaded_small.digest) == str(small.digest) and str(loaded_big.digest) == str(big.digest)
			and (loaded_big.data as PackedByteArray) == (big.data as PackedByteArray), "Both blobs should load back with their digests and bytes.")
		var rebuilt := REGEN.rebuild(loaded_doc, kernel)
		var first: Dictionary = rebuilt.bodies.get(str(loaded_doc.features[0].options.body_id), {})
		var second: Dictionary = rebuilt.bodies.get(str(loaded_doc.features[1].options.body_id), {})
		_expect(rebuilt.errors.is_empty() and MESH_BODY.is_mesh(first) and MESH_BODY.is_mesh(second) and str(first.shape.digest()) == str(small_mesh.digest()) and str(second.shape.digest()) == str(big_mesh.digest()),
			"The loaded design should rebuild to the same meshes (%s)." % str(rebuilt.errors))
	if loaded_root != null:
		loaded_root.free()

	# Damage: bytes that no longer match the checksum are an error, never a body.
	var raw: PackedByteArray = small_mesh.to_blob()
	raw[40] = raw[40] ^ 0x5A
	var damaged: Resource = MESH_BLOB.new()
	damaged.format = small.format
	damaged.digest = small.digest
	damaged.size = small.size
	damaged.vertices = small.vertices
	damaged.triangles = small.triangles
	damaged.data = raw.compress(FileAccess.COMPRESSION_ZSTD)
	var damaged_path := TEMP + "/damaged.res"
	_expect(ResourceSaver.save(damaged, damaged_path, ResourceSaver.FLAG_COMPRESS) == OK, "The damaged blob should save for the test.")
	var reloaded: Resource = ResourceLoader.load(damaged_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	_expect(reloaded != null and reloaded.get_script() == MESH_BLOB and reloaded.to_mesh() == null and str(reloaded.last_error) == "checksum mismatch", "A damaged blob file should fail its checksum on load ('%s')." % (reloaded.last_error if reloaded != null else "not loaded"))
	if reloaded != null:
		features[0].options["mesh"] = reloaded
		MESH_FEATURE.clear_cache()
		var broken := REGEN.rebuild(doc, kernel)
		_expect(str(broken.errors.get(features[0].id, "")).begins_with("The stored mesh of %s is damaged (checksum mismatch)." % features[0].label) and not broken.bodies.has(str(features[0].options.body_id))
			and broken.bodies.has(str(features[1].options.body_id)), "A damaged stored mesh should be the feature's error, not a body ('%s')." % broken.errors.get(features[0].id, ""))
	var truncated: Resource = MESH_BLOB.new()
	truncated.format = small.format
	truncated.digest = small.digest
	truncated.size = small.size
	truncated.data = (small.data as PackedByteArray).slice(0, 20)
	_expect(truncated.to_mesh() == null and str(truncated.last_error) == "it could not be unpacked", "Bytes that don't unpack should be an error ('%s')." % truncated.last_error)
	features[0].options.erase("mesh")
	_expect(str(REGEN.rebuild(doc, kernel).errors.get(features[0].id, "")).contains("holds no stored mesh"), "A feature without its blob should say so.")
	checked.append("stored meshes (digest, counts; under 256 KB kept in the scene, over it saved once to <part>_mesh_<digest>.res and shared by undo states; a saved scene loads back to the same meshes; a board model's .tres embeds them; a damaged blob is a checksum error on load and on rebuild)")


func _files(folder: String) -> PackedStringArray:
	var dir := DirAccess.open(folder)
	return dir.get_files() if dir != null else PackedStringArray()


# --- 6. Undo ---------------------------------------------------------------------------------

func _check_undo(kernel: RefCounted) -> void:
	var doc: Resource = DOCUMENT.new()
	var stl := FIXTURES.write_stl(FIXTURES.icosphere(0.05, 3), "gate/ball.stl", 1000.0)
	var added: Dictionary = INSERT.add_mesh_import(doc, stl, "mm", false, INSERT.KIND_MESH)
	_expect(str(added.error) == "" and added.feature != null, "The ball should insert (%s)." % added.error)
	if added.feature == null:
		return
	var feature: Resource = added.feature
	var blob: Resource = feature.options.mesh
	var bytes: PackedByteArray = (blob.data as PackedByteArray).duplicate()
	var digest := str(blob.digest)
	var before := REGEN.rebuild(doc, kernel)
	var mesh: RefCounted = before.bodies[str(feature.options.body_id)].shape
	var state: Dictionary = doc.snapshot()
	_expect(is_same(state.features[0].options.mesh, blob), "A snapshot should hold the very same blob (no copy).")
	_expect(not is_same(state.features[0], feature) and not is_same(state.features[0].options, feature.options), "A snapshot's feature and options are copies.")
	# An edit after the snapshot, then undo.
	_add(doc, "move", {"x": "10 mm"}, {"objects": [_body(str(feature.options.body_id))], "move_type": "free"})
	feature.options["units"] = "cm"
	doc.restore(state)
	var restored: Resource = doc.features[0]
	_expect(doc.features.size() == 1 and str(restored.options.units) == "mm" and is_same(restored.options.mesh, blob), "Restore should bring the feature back with the very same blob.")
	_expect(str(restored.options.mesh.digest) == digest and (restored.options.mesh.data as PackedByteArray) == bytes and int(restored.options.mesh.triangles) == 1280, "The blob's content should be unchanged by undo.")
	var after := REGEN.rebuild(doc, kernel)
	_expect(after.errors.is_empty() and is_same(after.bodies[str(restored.options.body_id)].shape, mesh), "The restored design should rebuild to the same mesh (the same instance, from the cache).")
	# A copy of the feature (a command's preview) shares it too.
	_expect(is_same(restored.copy().options.mesh, blob), "A feature copy should share the blob.")
	checked.append("undo (a snapshot, its restore and a feature copy hold the very same MeshBlob, with equal content, and rebuild to the same mesh)")


# --- Derive ----------------------------------------------------------------------------------

## A saved design with a mesh body derives into another design: the mesh body comes in as a mesh
## body, moved with the rest; joined into something it is refused.
func _check_derive(kernel: RefCounted) -> void:
	var source: Resource = DOCUMENT.new()
	_add_box(source, Vector3(0.02, 0.02, 0.02), Vector3.ZERO)
	var stl := FIXTURES.write_stl(FIXTURES.two_cubes(Vector3.ZERO).first, "gate/derive_cube.stl", 1000.0)
	var inserted: Dictionary = INSERT.add_mesh_import(source, stl, "mm", false, INSERT.KIND_MESH)
	inserted.feature.inputs["x"] = source.make_input("60 mm", "length")
	var path := TEMP + "/derive_source.tres"
	_expect(ResourceSaver.save(source, path) == OK, "The source design should save.")
	var doc: Resource = DOCUMENT.new()
	var added: Dictionary = INSERT.add_derive(doc, path, kernel)
	_expect(str(added.error) == "" and added.feature != null and (added.bodies as Array).size() == 2, "The design with a mesh body should derive (%s)." % added.error)
	if added.feature == null:
		return
	added.feature.inputs["y"] = doc.make_input("100 mm", "length")
	var result := REGEN.rebuild(doc, kernel)
	var meshes := 0
	var solids := 0
	for body_id in result.bodies:
		var entry: Dictionary = result.bodies[body_id]
		if MESH_BODY.is_mesh(entry):
			meshes += 1
			_expect(str(entry.get("kind", "")) == "mesh" and int(entry.shape.triangle_count()) == 12 and ((entry.shape.bbox() as AABB).get_center() - Vector3(0.06, 0.1, 0.0)).length() < 1e-6,
				"The derived mesh body should come in whole, moved with the placement (%s)." % (entry.shape.bbox() as AABB).get_center())
		else:
			solids += 1
			_expect(absf(entry.shape.volume() - 8e-6) < 1e-11 and absf((entry.shape.bbox() as AABB).position.y - 0.1) < 1e-6, "The derived B-rep body should come in as before.")
	_expect(result.errors.is_empty() and meshes == 1 and solids == 1, "Derive should bring in one mesh body and one B-rep body (%d, %d, %s)." % [meshes, solids, str(result.errors)])
	added.feature.options["operation"] = OPERATIONS.JOIN
	var joined := REGEN.rebuild(doc, kernel)
	_expect(str(joined.errors.get(added.feature.id, "")) == GATE_TEXT % "derive_cube", "A mesh body derived into a Join should be refused with the gate sentence ('%s')." % joined.errors.get(added.feature.id, ""))
	INSERT.clear_derive_cache()
	checked.append("Derive of a design with a mesh body (a mesh body beside the B-rep one, placed; refused in a Join)")


# --- 7. Without the native mesh class --------------------------------------------------------

func _check_missing_kernel(kernel: RefCounted) -> void:
	var doc: Resource = DOCUMENT.new()
	var box := _add_box(doc, Vector3(0.02, 0.02, 0.02), Vector3.ZERO)
	var made: Dictionary = MESH_FEATURE.add_tessellate(doc, [box.options.body_id])
	var insert: Resource = doc.add_feature("mesh_import", "Mesh", {}, {"path": "x.stl", "kind": "mesh", "units": "mm", "linked": false, "operation": OPERATIONS.NEW_BODY})
	insert.options["body_id"] = doc.new_body(insert.id)
	MESH_BODY.force_missing = true
	var result := REGEN.rebuild(doc, kernel)
	var alone: String = MESH_FEATURE.build(made.feature, _ctx(doc, kernel, result))
	var read: Dictionary = INSERT.read_mesh_body("res://tests/holo_forge/fixtures/cube_10mm.stl")
	var available := MESH_BODY.available()
	MESH_BODY.force_missing = false
	var sentence := "The Holo Forge mesh kernel is not loaded"
	_expect(not available and alone == sentence and str(result.errors.get(made.feature.id, "")) == sentence and str(result.errors.get(insert.id, "")) == sentence and str(read.error) == sentence,
		"Without the mesh class every mesh feature should say the mesh kernel is not loaded ('%s', '%s', '%s')." % [alone, result.errors.get(made.feature.id, ""), result.errors.get(insert.id, "")])
	_expect(result.bodies.size() == 1 and not result.errors.has(box.id), "The B-rep features should still build without the mesh class.")
	_expect(MESH_BODY.available() == ClassDB.class_exists("CadMesh"), "The test seam should be off again.")
	checked.append("no mesh kernel (Tessellate, Insert Mesh as a mesh body and the mesh reader say 'The Holo Forge mesh kernel is not loaded'; B-rep features still build)")


func _remove_folder(folder: String) -> void:
	var system := ProjectSettings.globalize_path(folder)
	var dir := DirAccess.open(system)
	if dir == null:
		return
	for file in dir.get_files():
		DirAccess.remove_absolute(system.path_join(file))
	for sub in dir.get_directories():
		_remove_folder(system.path_join(sub))
	DirAccess.remove_absolute(system)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
