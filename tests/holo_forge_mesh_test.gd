extends SceneTree
## Holo Forge Phase 7 acceptance (the Mesh workspace; spec 5.3), through features and the rebuild:
##   1. Reduce to 50 % hits the target within 2 % with the surface within tolerance.
##   2. Plane Cut with Fill gives a watertight result (Trim, and both parts of Split Body).
##   3. Close Holes makes a holed scan-like body closed, near its true volume, its own triangles
##      untouched.
##   4. Convert Mesh: Faceted gives a solid within 1 % of the mesh's volume.
##   5. The design saved to a file and loaded again rebuilds to the same bodies.
##
## godot --headless --path . --script res://tests/holo_forge_mesh_test.gd

const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const INSERT := preload("res://addons/holo_forge/core/features/insert.gd")
const MESH_FEATURE := preload("res://addons/holo_forge/core/features/mesh.gd")
const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")
const MESH_BLOB := preload("res://addons/holo_forge/core/mesh/mesh_blob.gd")
const FIXTURES := preload("res://tests/holo_forge_mesh_fixtures.gd")

const MM := 0.001
const TEMP := "user://holo_forge_mesh_fixtures/acceptance"

var failures: Array[String] = []
var checked: Array[String] = []
var notes: Array[String] = []
var kernel: RefCounted


func _init() -> void:
	call_deferred("run")


func run() -> void:
	kernel = REGEN.make_kernel()
	_expect(kernel != null, "The native kernel should load.")
	if kernel != null and not ClassDB.class_exists("CadMesh"):
		print("NOTE holo_forge_mesh: CadMesh is not in this build; the mesh checks are skipped.")
	elif kernel != null:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEMP))
		MESH_FEATURE.clear_cache()
		_check_acceptance()
		_remove_folder(TEMP)
	for note in notes:
		print("NOTE holo_forge_mesh: " + note)
	if failures.is_empty():
		print("PASS holo_forge_mesh: " + "; ".join(checked) + ".")
	else:
		print("FAIL holo_forge_mesh")
		for failure in failures:
			print("  " + failure)
	quit(0 if failures.is_empty() else 1)


func _check_acceptance() -> void:
	var doc: Resource = DOCUMENT.new()
	var xy := {"kind": "origin", "name": "xy"}
	var ball := FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 5))
	var blob_fixture := FIXTURES.holed_blob()
	var blob := FIXTURES.to_mesh(blob_fixture)
	var reference := FIXTURES.to_mesh(blob_fixture.reference)
	var small_ball := FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 4))
	var bracket: RefCounted = FIXTURES.l_bracket().mesh
	# One design holds every case: a body and its tool each.
	var reduced_id := _add_mesh(doc, ball, "Reduced")
	var reduce := _tool(doc, "reduce", {"bodies": [_pick(reduced_id)], "selection": [], "target": "proportion", "algorithm": "adaptive", "keep_boundary": true, "keep_groups": true, "keep_sharp": false},
		{"proportion": ["50", "number"], "tolerance": ["0.05 mm", "length"]})
	var trimmed_id := _add_mesh(doc, ball, "Trimmed")
	var trim := _tool(doc, "plane_cut", {"bodies": [_pick(trimmed_id)], "plane": [xy], "type": "trim", "flip": false, "fill": "uniform"}, {"offset": ["10 mm", "length"]})
	var split_id := _add_mesh(doc, ball, "Split")
	var split := _tool(doc, "plane_cut", {"bodies": [_pick(split_id)], "plane": [xy], "type": "split_body", "flip": false, "fill": "uniform"}, {"offset": ["10 mm", "length"]})
	var closed_id := _add_mesh(doc, blob, "Blob")
	var close := _tool(doc, "close_holes", {"bodies": [_pick(closed_id)], "loops": [], "fill": "smooth", "refine": true}, {"max_edges": ["0", "number"]})
	var faceted_ball_id := _add_mesh(doc, small_ball, "Ball")
	var facet_ball := _tool(doc, "convert_faceted", {"bodies": [_pick(faceted_ball_id)], "merge_flat": true, "result": "new_body"})
	var faceted_bracket_id := _add_mesh(doc, bracket, "Bracket")
	var facet_bracket := _tool(doc, "convert_faceted", {"bodies": [_pick(faceted_bracket_id)], "merge_flat": true, "result": "new_body"})
	var result := REGEN.rebuild(doc, kernel)

	# 1. Reduce to 50 %: 10,240 triangles within 2 %, no farther than 0.05 mm from the ball, closed.
	var reduced := _mesh(result, reduced_id)
	var count := int(reduced.triangle_count()) if reduced != null else -1
	var off := maxf(float(reduced.distance_to(ball, 20000, 20.0).max), float(ball.distance_to(reduced, 20000, 20.0).max)) if reduced != null else INF
	_expect(_error(result, reduce) == "" and _warning(result, reduce) == "" and count >= 10036 and count <= 10444 and off <= 0.05 * MM and _watertight(reduced),
		"#1 Reduce to 50 %% should keep 10,240 triangles within 2 %% (%d), within 0.05 mm of the ball (%.4f mm), closed (error '%s', warning '%s')." % [count, off * 1000.0, _error(result, reduce), _warning(result, reduce)])
	notes.append("#1 Reduce: %d triangles (%.2f %% of 20,480), largest distance %.4f mm" % [count, 100.0 * count / 20480.0, off * 1000.0])
	checked.append("#1 Reduce to 50 % (within 2 % of the target, within 0.05 mm both ways, closed)")

	# 2. Plane Cut with Fill: watertight, the cap's volume; Split Body: both parts watertight.
	var cap := PI * 0.04 * 0.04 * (3.0 * 0.05 - 0.04) / 3.0
	var trimmed := _mesh(result, trimmed_id)
	_expect(_error(result, trim) == "" and _warning(result, trim) == "" and _watertight(trimmed) and absf(float(trimmed.volume()) - cap) <= 0.005 * cap,
		"#2 A ball trimmed at z = 10 mm and filled should be watertight at the cap's volume (%s of %s; error '%s', warning '%s')." % [trimmed.volume() if trimmed != null else 0.0, cap, _error(result, trim), _warning(result, trim)])
	var outputs: Array = split.options.get("outputs", [])
	var upper := _mesh(result, split_id)
	var lower := _mesh(result, str(outputs[1])) if outputs.size() == 2 else null
	_expect(_error(result, split) == "" and outputs.size() == 2 and _watertight(upper) and _watertight(lower) and absf(float(upper.volume()) + float(lower.volume()) - float(ball.volume())) <= 1e-6 * float(ball.volume()),
		"#2 Split Body should give two watertight parts whose volumes add up to the ball's (error '%s', outputs %s)." % [_error(result, split), str(outputs)])
	# (The plane passes within a millionth of the ball's size of some corners. The thin triangles
	# that leaves were counted as "without area" until 2026-11-13; that is judged by each
	# triangle's own shape now, and these have one, so Split Body says nothing.)
	_expect(_warning(result, split) == "" and int((lower.check(5.0) as Dictionary).get("degenerate_triangles", -1)) == 0 and int((upper.check(5.0) as Dictionary).get("degenerate_triangles", -1)) == 0,
		"#2 Split Body should give parts with no triangle without area, and no warning ('%s')." % _warning(result, split))
	notes.append("#2 Plane Cut: trimmed volume %.4f %% off the cap formula; split warning '%s'" % [100.0 * absf(float(trimmed.volume()) - cap) / cap if trimmed != null else -1.0, _warning(result, split)])
	checked.append("#2 Plane Cut with Fill (Trim watertight and oriented at the cap's volume within 0.5 %, both parts of Split Body watertight and summing to the whole)")

	# 3. Close Holes on the holed blob: watertight, within 1 % of the blob without holes, the
	# blob's own triangles bit for bit.
	var closed := _mesh(result, closed_id)
	_expect(_error(result, close) == "" and _warning(result, close) == "" and _watertight(closed) and absf(float(closed.volume()) - float(reference.volume())) <= 0.01 * float(reference.volume())
		and _bag_within(_triangle_bag(blob), _triangle_bag(closed)), "#3 Close Holes should make the holed blob watertight within 1 %% of its true volume and leave its triangles as they were (%s of %s; error '%s', warning '%s')." % [
		closed.volume() if closed != null else 0.0, reference.volume(), _error(result, close), _warning(result, close)])
	notes.append("#3 Close Holes: volume %.4f %% off the blob without holes" % (100.0 * absf(float(closed.volume()) - float(reference.volume())) / float(reference.volume()) if closed != null else -1.0))
	checked.append("#3 Close Holes (the holed blob watertight, within 1 % of its true volume, original triangles bit for bit)")

	# 4. Convert Mesh: Faceted: one solid each, within 1 % of the mesh's volume.
	if not ResourceLoader.exists(MESH_FEATURE.CONVERT_PATH):
		_expect(false, "#4 Convert Mesh: Faceted is not in this build (core/features/mesh_convert.gd is missing): '%s'." % _error(result, facet_ball))
	else:
		for item in [[facet_ball, faceted_ball_id, small_ball, "an icosphere"], [facet_bracket, faceted_bracket_id, bracket, "the bracket"]]:
			var feature: Resource = item[0]
			var source: RefCounted = item[2]
			var solid: RefCounted = null
			for body_id in result.bodies:
				var entry: Dictionary = result.bodies[body_id]
				if str(entry.get("feature", "")) == feature.id and not MESH_BODY.is_mesh(entry):
					solid = entry.shape
			var volume := float(solid.volume()) if solid != null else 0.0
			var relative := absf(volume - float(source.volume())) / float(source.volume())
			_expect(_error(result, feature) == "" and solid != null and int(solid.solid_count()) == 1 and not bool(solid.is_surface()) and relative <= 0.01,
				"#4 Convert Mesh: Faceted of %s should give one solid within 1 %% of the mesh's volume (off by %s; error '%s')." % [item[3], relative, _error(result, feature)])
			notes.append("#4 Faceted convert of %s: volume off by %s of the mesh's (limit 0.01)" % [item[3], String.num(relative, 12)])
		checked.append("#4 Convert Mesh: Faceted (an icosphere and the bracket: one solid each within 1 % of the mesh volume)")

	# 5. Saved and loaded again: the same bodies, by content. Undo and redo too.
	var before := _contents(result)
	var path := TEMP + "/design.tres"
	var saved := ResourceSaver.save(doc, path)
	var loaded: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) if saved == OK else null
	MESH_FEATURE.clear_cache()
	var again: Dictionary = REGEN.rebuild(loaded, kernel) if loaded != null else {"bodies": {}, "errors": {"load": "failed"}, "warnings": {}}
	_expect(saved == OK and loaded != null and not is_same(loaded, doc) and _contents(again) == before and again.errors == result.errors and again.warnings == result.warnings,
		"#5 The design saved as a .tres and loaded again should rebuild to the same bodies (save %d; %d bodies, %d before; errors %s)." % [saved, (again.bodies as Dictionary).size(), (result.bodies as Dictionary).size(), str(again.errors)])
	var state: Dictionary = doc.snapshot()
	var restored: Resource = DOCUMENT.new()
	restored.restore(state)
	MESH_FEATURE.clear_cache()
	_expect(_contents(REGEN.rebuild(restored, kernel)) == before, "#5 The design put back from an undo state should rebuild to the same bodies.")
	checked.append("#5 save and reload (a .tres of the whole design rebuilds to the same digests, errors and warnings; an undo state too)")


# --- Helpers ---------------------------------------------------------------------------------

func _add_mesh(doc: Resource, mesh: RefCounted, name: String) -> String:
	var feature: Resource = doc.add_feature("mesh_import", "Mesh", {}, {
		"path": "", "kind": INSERT.KIND_MESH, "units": "mm", "mesh_units": "mm", "linked": false, "split": false,
		"transform": Transform3D.IDENTITY, "operation": OPERATIONS.NEW_BODY, "mesh": MESH_BLOB.from_mesh(mesh),
	})
	var body_id: String = doc.new_body(feature.id)
	feature.options["body_id"] = body_id
	doc.bodies[body_id]["name"] = name
	return body_id


## A Mesh tool's feature, as its panel writes it: options, and inputs as [expression, kind].
func _tool(doc: Resource, method: String, options := {}, inputs := {}) -> Resource:
	var made := {}
	for key in inputs:
		made[key] = doc.make_input(str(inputs[key][0]), str(inputs[key][1]))
	var settings := {"method": method}
	settings.merge(options)
	return doc.add_feature("mesh", method.capitalize().replace(" ", ""), made, settings)


func _pick(body_id: String) -> Dictionary:
	return {"kind": "body", "body": body_id}


func _mesh(result: Dictionary, body_id: String) -> RefCounted:
	var entry: Dictionary = result.bodies.get(body_id, {})
	return entry.get("shape") if MESH_BODY.is_mesh(entry) else null


func _error(result: Dictionary, feature: Resource) -> String:
	return str(result.errors.get(feature.id, ""))


func _warning(result: Dictionary, feature: Resource) -> String:
	return str(result.warnings.get(feature.id, ""))


## Closed, manifold, no open edge, every part facing the right way.
func _watertight(mesh: RefCounted) -> bool:
	if mesh == null:
		return false
	var found: Dictionary = mesh.check(10.0)
	return bool(found.get("closed", false)) and bool(found.get("manifold", false)) and int(found.get("boundary_edges", -1)) == 0 and bool(found.get("oriented", false))


## Every body of a result by content: a mesh body's digest; a B-rep body's type, face count,
## volume and area.
func _contents(result: Dictionary) -> Dictionary:
	var out := {}
	for body_id in result.bodies:
		var entry: Dictionary = result.bodies[body_id]
		var shape: RefCounted = entry.shape
		if MESH_BODY.is_mesh(entry):
			out[body_id] = "mesh:%s" % str(shape.digest())
		else:
			out[body_id] = "brep:%s:%d:%s:%s" % [str(shape.shape_type()), int(shape.face_count()), String.num(float(shape.volume()), 15), String.num(float(shape.area()), 12)]
	return out


## Every triangle of a mesh as text of its three corners' exact positions (order-free), counted.
func _triangle_bag(mesh: RefCounted) -> Dictionary:
	var arrays: Dictionary = mesh.get_arrays()
	var positions: PackedVector3Array = arrays.positions
	var indices: PackedInt32Array = arrays.indices
	var bag := {}
	for t in indices.size() / 3:
		var corners := [var_to_str(positions[indices[3 * t]]), var_to_str(positions[indices[3 * t + 1]]), var_to_str(positions[indices[3 * t + 2]])]
		corners.sort()
		var key := "|".join(PackedStringArray(corners))
		bag[key] = int(bag.get(key, 0)) + 1
	return bag


func _bag_within(part: Dictionary, whole: Dictionary) -> bool:
	for key in part:
		if int(whole.get(key, 0)) < int(part[key]):
			return false
	return true


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
