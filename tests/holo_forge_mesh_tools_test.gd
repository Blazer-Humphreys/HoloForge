extends SceneTree
## Holo Forge Mesh tools through features and the rebuild (Phase 7, stage 3, spec 5.2): every case
## builds its fixture as an Insert Mesh feature (a mesh body from a stored mesh), adds the tool's
## feature with its options and inputs as the panels write them, rebuilds, and checks the bodies,
## the error and the warnings (each listed warning, and no other).
##
## godot --headless --path . --script res://tests/holo_forge_mesh_tools_test.gd

const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const PARAMETERS := preload("res://addons/holo_forge/core/parameters.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const INSERT := preload("res://addons/holo_forge/core/features/insert.gd")
const UTIL := preload("res://addons/holo_forge/core/features/util.gd")
const MESH_FEATURE := preload("res://addons/holo_forge/core/features/mesh.gd")
const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")
const MESH_BLOB := preload("res://addons/holo_forge/core/mesh/mesh_blob.gd")
const SPECS := preload("res://addons/holo_forge/tools/feature_specs.gd")
const FIXTURES := preload("res://tests/holo_forge_mesh_fixtures.gd")
const TIMING := preload("res://tests/holo_forge_timing.gd")

const MM := 0.001
const MM3 := 1e-9
const TEMP := "user://holo_forge_mesh_fixtures/tools"
const GATE_TEXT := "%s is a mesh body. Convert it first (Mesh > Modify > Convert Mesh)."
## Ratio limits of the refusals that must come before any work (5.7): the handler alone, against
## _calibration() (a kernel sphere made and tessellated, 3.4 to 3.5 ms). Each limit is twice the
## measured ratio. Measured on the dev machine, 2026-11-11, two runs (other teams' tests running):
##   Wrap over the grid (holed blob)        0.14 ms    ratio 0.039, 0.041
##   Remesh, Density 1, 1,009,200 triangles 12.8 to 13.6 ms  ratio 3.87, 3.74
##   Smooth, 5 passes, the same body        10.0 ms    ratio 2.93, 2.90
##   Reduce (Adaptive) 50 %, the same body  1.0 to 1.1 ms    ratio 0.29, 0.29
## (The spec's "at most 0.2 s" would be a ratio of 57.) HOLO_FORGE_TIMING_SLOWDOWN=3 fails all four.
const WRAP_GRID_RATIO := 0.08
const REFUSAL_RATIOS := {"#20 Remesh": 7.6, "#47 Smooth": 5.9, "#48 Adaptive Reduce": 0.58}

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
		print("NOTE holo_forge_mesh_tools: CadMesh is not in this build; the mesh tool checks are skipped.")
	elif kernel != null:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEMP))
		MESH_FEATURE.clear_cache()
		var only := OS.get_environment("HOLO_FORGE_MESH_TOOLS_ONLY")
		for part in [["insert", _check_insert], ["tessellate", _check_tessellate], ["section", _check_section_sketch], ["close", _check_close_holes],
				["stitch", _check_stitch], ["wrap", _check_wrap], ["rebuild", _check_rebuild], ["groups", _check_groups], ["remesh", _check_remesh],
				["reduce", _check_reduce], ["cut", _check_plane_cut], ["shell", _check_shell], ["combine", _check_combine], ["smooth", _check_smooth],
				["reverse", _check_reverse], ["erase", _check_erase_fill], ["align", _check_align], ["texture", _check_texture_extrude],
				["separate", _check_separate], ["move", _check_move_scale], ["direct", _check_direct_edit], ["gate", _check_gate],
				["ranges", _check_ranges], ["rules", _check_rules], ["cache", _check_cache], ["large", _check_large]]:
			if only == "" or only.split(",").has(str(part[0])):
				(part[1] as Callable).call()
		_remove_folder(TEMP)
	for note in notes:
		print("NOTE holo_forge_mesh_tools: " + note)
	if failures.is_empty():
		print("PASS holo_forge_mesh_tools: " + "; ".join(checked) + ".")
	else:
		print("FAIL holo_forge_mesh_tools")
		for failure in failures:
			print("  " + failure)
	quit(0 if failures.is_empty() else 1)


# --- Helpers ---------------------------------------------------------------------------------

## A design with one mesh body per fixture mesh, each from an Insert Mesh feature that stores it.
func _add_mesh(doc: Resource, mesh: RefCounted, name := "") -> String:
	var feature: Resource = doc.add_feature("mesh_import", "Mesh", {}, {
		"path": "", "kind": INSERT.KIND_MESH, "units": "mm", "mesh_units": "mm", "linked": false, "split": false,
		"transform": Transform3D.IDENTITY, "operation": OPERATIONS.NEW_BODY, "mesh": MESH_BLOB.from_mesh(mesh),
	})
	var body_id: String = doc.new_body(feature.id)
	feature.options["body_id"] = body_id
	if name != "":
		doc.bodies[body_id]["name"] = name
	return body_id


func _add_fixture(doc: Resource, fixture: Dictionary, name := "") -> String:
	return _add_mesh(doc, FIXTURES.to_mesh(fixture), name)


func _add_box(doc: Resource, size: Vector3, position: Vector3) -> String:
	var feature: Resource = doc.add_feature("box", "Box", {
		"length": doc.make_input("%f m" % size.x, "length"), "height": doc.make_input("%f m" % size.y, "length"),
		"width": doc.make_input("%f m" % size.z, "length"),
	}, {"operation": OPERATIONS.NEW_BODY, "position": position})
	feature.options.body_id = doc.new_body(feature.id)
	return str(feature.options.body_id)


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


## A face group pick. With the body's mesh given it is written as the panels write it: the name,
## a point on the group ("at": the middle of its first triangle) and how the surface faces there
## ("normal"), so the pick can be confirmed, and followed when the groups are renumbered. Without
## the mesh it is the name alone, which the rebuild takes with a warning that it could not be
## confirmed.
func _group(body_id: String, group: String, mesh: RefCounted = null) -> Dictionary:
	var pick := {"kind": "mesh_group", "body": body_id, "group": group}
	if mesh == null:
		return pick
	var index := int(mesh.find_face(group))
	var triangles: PackedInt32Array = mesh.group_triangles(index) if index >= 0 else PackedInt32Array()
	if triangles.is_empty():
		return pick
	var arrays: Dictionary = mesh.get_arrays()
	var middle := Vector3.ZERO
	for k in 3:
		middle += arrays.positions[int(arrays.indices[3 * triangles[0] + k])] / 3.0
	pick["at"] = middle
	pick["normal"] = mesh.face_normal_at(index, middle)
	return pick


func _triangles(body_id: String, triangles: PackedInt32Array, mesh: RefCounted) -> Dictionary:
	return {"kind": "mesh_triangles", "body": body_id, "triangles": triangles, "digest": str(mesh.digest())}


func _len(meters: float) -> Array:
	return ["%s mm" % String.num(meters * 1000.0, 9), "length"]


func _num(value: float) -> Array:
	return [String.num(value, 9), "number"]


func _deg(degrees: float) -> Array:
	return [String.num(degrees, 9), "angle"]


func _rebuild(doc: Resource) -> Dictionary:
	return REGEN.rebuild(doc, kernel)


func _mesh(result: Dictionary, body_id: String) -> RefCounted:
	var entry: Dictionary = result.bodies.get(body_id, {})
	return entry.get("shape") if MESH_BODY.is_mesh(entry) else null


func _error(result: Dictionary, feature: Resource) -> String:
	return str(result.errors.get(feature.id, ""))


func _warning(result: Dictionary, feature: Resource) -> String:
	return str(result.warnings.get(feature.id, ""))


## True when the feature built with no error and its warnings are exactly the listed ones (one
## fragment for each warning, in any order).
func _fine(result: Dictionary, feature: Resource, what: String, expected: Array = []) -> bool:
	var error := _error(result, feature)
	var given: Array = (MESH_FEATURE.reports.get(feature.id, {}) as Dictionary).get("warnings", [])
	var good := error == "" and given.size() == expected.size()
	for fragment in expected:
		var found := false
		for warning in given:
			if str(warning).contains(str(fragment)):
				found = true
		good = good and found
	# What the timeline shows is those same warnings, joined.
	var shown := _warning(result, feature)
	for warning in given:
		good = good and shown.contains(str(warning))
	if given.is_empty() and error == "":
		good = good and shown == ""
	_expect(good, "%s should build with %s (error '%s', warnings %s, shown '%s')." % [what, "no warning" if expected.is_empty() else "the warnings %s" % str(expected), error, str(given), shown])
	return good


func _refused(result: Dictionary, feature: Resource, what: String, fragments: Array) -> bool:
	var error := _error(result, feature)
	var good := error != ""
	for fragment in fragments:
		good = good and error.contains(str(fragment))
	_expect(good, "%s should be refused with %s ('%s')." % [what, str(fragments), error])
	return good


func _closed(mesh: RefCounted) -> bool:
	if mesh == null:
		return false
	var found: Dictionary = mesh.check(5.0)
	return bool(found.get("closed", false)) and bool(found.get("manifold", false)) and int(found.get("boundary_edges", -1)) == 0


func _open_edges(mesh: RefCounted) -> int:
	return int((mesh.check(5.0) as Dictionary).get("boundary_edges", -1)) if mesh != null else -1


## The largest distance between two meshes, measured both ways with 20,000 samples each.
func _hausdorff(a: RefCounted, b: RefCounted) -> float:
	return maxf(float(a.distance_to(b, 20000, 20.0).max), float(b.distance_to(a, 20000, 20.0).max))


## The mean edge length of a mesh (every triangle's three edges).
func _mean_edge(mesh: RefCounted) -> float:
	var arrays: Dictionary = mesh.get_arrays()
	var positions: PackedVector3Array = arrays.positions
	var indices: PackedInt32Array = arrays.indices
	var total := 0.0
	for i in range(0, indices.size(), 3):
		var a := positions[indices[i]]
		var b := positions[indices[i + 1]]
		var c := positions[indices[i + 2]]
		total += a.distance_to(b) + b.distance_to(c) + c.distance_to(a)
	return total / maxf(indices.size(), 1.0)


## Every triangle of a mesh as text of its three corners' exact positions (order-free), counted.
func _triangle_bag(mesh: RefCounted, only := PackedInt32Array(), skip := PackedInt32Array()) -> Dictionary:
	var arrays: Dictionary = mesh.get_arrays()
	var positions: PackedVector3Array = arrays.positions
	var indices: PackedInt32Array = arrays.indices
	var skipped := {}
	for t in skip:
		skipped[t] = true
	var wanted := {}
	for t in only:
		wanted[t] = true
	var bag := {}
	for t in indices.size() / 3:
		if skipped.has(t) or (not only.is_empty() and not wanted.has(t)):
			continue
		var corners := [var_to_str(positions[indices[3 * t]]), var_to_str(positions[indices[3 * t + 1]]), var_to_str(positions[indices[3 * t + 2]])]
		corners.sort()
		var key := "|".join(PackedStringArray(corners))
		bag[key] = int(bag.get(key, 0)) + 1
	return bag


## True when every triangle of `part` is in `whole` (as often).
func _bag_within(part: Dictionary, whole: Dictionary) -> bool:
	for key in part:
		if int(whole.get(key, 0)) < int(part[key]):
			return false
	return true


func _digests(result: Dictionary) -> Dictionary:
	var out := {}
	for body_id in result.bodies:
		var shape: RefCounted = result.bodies[body_id].shape
		out[body_id] = str(shape.digest()) if MESH_BODY.is_mesh(shape) else "brep"
	return out


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


# --- 5.2 #1-4: Insert Mesh -------------------------------------------------------------------

func _check_insert() -> void:
	var doc: Resource = DOCUMENT.new()
	# 1. An STL as a mesh body.
	var cube: Dictionary = INSERT.add_mesh_import(doc, "res://tests/holo_forge/fixtures/cube_10mm.stl", "", false, INSERT.KIND_MESH)
	var result := _rebuild(doc)
	var cube_entry: Dictionary = result.bodies.get(str(cube.feature.options.body_id), {}) if cube.feature != null else {}
	_expect(str(cube.error) == "" and result.errors.is_empty() and result.bodies.size() == 1 and str(cube_entry.get("kind", "")) == "mesh" and MESH_BODY.is_mesh(cube_entry)
		and int(cube_entry.shape.triangle_count()) == 12 and _warning(result, cube.feature) == "", "#1 An STL inserted as a mesh body should be one mesh body of 12 triangles (%s, %s)." % [cube.error, str(result.errors)])
	# 2. The old feature (no "kind"): a faceted B-rep solid, as before.
	var old_doc: Resource = DOCUMENT.new()
	var old: Dictionary = INSERT.add_mesh_import(old_doc, "res://tests/holo_forge/fixtures/cube_10mm.stl")
	var old_result := _rebuild(old_doc)
	var old_entry: Dictionary = old_result.bodies.get(str(old.feature.options.body_id), {}) if old.feature != null else {}
	_expect(str(old.error) == "" and old_result.errors.is_empty() and not old.feature.options.has("kind") and old.feature.options.has("positions") and not old_entry.has("kind")
		and not MESH_BODY.is_mesh(old_entry) and str(old_entry.shape.shape_type()) == "SOLID" and absf(float(old_entry.shape.volume()) - 1e-6) < 1e-11,
		"#2 An Insert Mesh feature without a kind should build the faceted solid as before (%s)." % str(old_result.errors))
	# 3. Linked: the file is read on every rebuild, so another file content gives another body.
	var linked_path := FIXTURES.write_stl(FIXTURES.two_cubes(Vector3(0.05, 0.0, 0.0)).first, "tools/linked.stl", 1000.0)
	var linked_doc: Resource = DOCUMENT.new()
	var linked: Dictionary = INSERT.add_mesh_import(linked_doc, linked_path, "", true, INSERT.KIND_MESH)
	var before := _rebuild(linked_doc)
	var linked_id := str(linked.feature.options.body_id)
	var before_digest := str(before.bodies[linked_id].shape.digest())
	var again := _rebuild(linked_doc)
	_expect(is_same(before.bodies[linked_id].shape, again.bodies[linked_id].shape), "#3 A linked mesh whose file is unchanged should rebuild to the same instance.")
	FIXTURES.write_stl(FIXTURES.icosphere(0.01, 2), "tools/linked.stl", 1000.0)
	var after := _rebuild(linked_doc)
	_expect(before.errors.is_empty() and after.errors.is_empty() and not linked.feature.options.has("mesh") and int(before.bodies[linked_id].shape.triangle_count()) == 12
		and int(after.bodies[linked_id].shape.triangle_count()) == 320 and str(after.bodies[linked_id].shape.digest()) != before_digest,
		"#3 Changing a linked mesh file and rebuilding should change the body (%s, %s)." % [str(before.errors), str(after.errors)])
	# 4. An open file: the warning names the open edges and Close Holes.
	var plate_path := FIXTURES.write_stl(FIXTURES.open_plate(), "tools/open_plate.stl", 1000.0)
	var plate_doc: Resource = DOCUMENT.new()
	var plate: Dictionary = INSERT.add_mesh_import(plate_doc, plate_path, "", false, INSERT.KIND_MESH)
	var plate_result := _rebuild(plate_doc)
	var plate_name: String = plate_doc.body_name(str(plate.feature.options.body_id))
	_expect(plate_result.errors.is_empty() and _warning(plate_result, plate.feature) == "%s has 128 open edges in 1 hole. Prepare > Close Holes can fix them." % plate_name,
		"#4 An open mesh file should warn of its open edges and name Close Holes ('%s')." % _warning(plate_result, plate.feature))
	# 3MF and glTF corners split along seams are welded: a 3MF cube is closed with 8 corners.
	var welded: Dictionary = INSERT.read_mesh_body("res://tests/holo_forge/fixtures/cube_10mm_placed.3mf")
	_expect(str(welded.error) == "" and welded.mesh != null and int(welded.mesh.vertex_count()) == 8 and _closed(welded.mesh), "A 3MF cube should come in welded: 8 corners, closed (%s)." % welded.error)
	# One Body per Piece: each piece its own body; a file that crosses itself says so.
	var pair_path := FIXTURES.write_stl(FIXTURES.two_cubes(Vector3(0.05, 0.0, 0.0)), "tools/pair.stl", 1000.0)
	var pair_doc: Resource = DOCUMENT.new()
	var pair: Dictionary = INSERT.add_mesh_import(pair_doc, pair_path, "", false, INSERT.KIND_MESH)
	pair.feature.options["split"] = true
	var pair_result := _rebuild(pair_doc)
	_expect(pair_result.errors.is_empty() and pair_result.bodies.size() == 2 and _warning(pair_result, pair.feature) == "", "One Body per Piece should give two bodies and no warning (%s, '%s')." % [str(pair_result.errors), _warning(pair_result, pair.feature)])
	var crossing_path := FIXTURES.write_stl(FIXTURES.self_crossing(), "tools/crossing.stl", 1000.0)
	var crossing_doc: Resource = DOCUMENT.new()
	var crossing: Dictionary = INSERT.add_mesh_import(crossing_doc, crossing_path, "", false, INSERT.KIND_MESH)
	crossing.feature.options["split"] = true
	var crossing_result := _rebuild(crossing_doc)
	var crossing_name: String = crossing_doc.body_name(str(crossing.feature.options.body_id))
	_expect(crossing_result.errors.is_empty() and _warning(crossing_result, crossing.feature).contains("%s crosses itself, so the result may be wrong there. Rebuild it first." % crossing_name),
		"One Body per Piece on a file that crosses itself should say so ('%s')." % _warning(crossing_result, crossing.feature))
	checked.append("#1-4 Insert Mesh (STL as a mesh body, the old feature as a solid, linked file changed, open file warned, 3MF welded, One Body per Piece with the crossing warning)")


# --- 5.2 #5-6: Tessellate ----------------------------------------------------------------------

func _check_tessellate() -> void:
	var doc: Resource = DOCUMENT.new()
	var box := _add_box(doc, Vector3(0.02, 0.02, 0.02), Vector3.ZERO)
	var made: Dictionary = MESH_FEATURE.add_tessellate(doc, [box])
	var result := _rebuild(doc)
	var mesh := _mesh(result, str(made.bodies[0]))
	_expect(result.errors.is_empty() and mesh != null and int(mesh.group_count()) == 6 and _closed(mesh) and absf(float(mesh.volume()) - 8e-6) < 0.01 * 8e-6
		and result.bodies.has(box) and _warning(result, made.feature) == "", "#5 Tessellate of a box should give 6 face groups, closed, within 1 %% of its volume (%s)." % str(result.errors))
	made.feature.options["keep_original"] = false
	var without := _rebuild(doc)
	_expect(without.errors.is_empty() and not without.bodies.has(box) and _mesh(without, str(made.bodies[0])) != null, "#6 With Keep Original off the B-rep body should be gone from the result.")
	checked.append("#5-6 Tessellate (6 groups, closed, volume; Keep Original off)")


# --- 5.2 #7: Create Mesh Section Sketch ------------------------------------------------------

func _polygon_area(points: PackedVector3Array, normal: Vector3) -> float:
	var sum := Vector3.ZERO
	for i in points.size():
		sum += points[i].cross(points[(i + 1) % points.size()])
	return absf(sum.dot(normal.normalized())) * 0.5


func _check_section_sketch() -> void:
	var ball := FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 4))
	var plane := {"kind": "origin", "name": "xy"}
	var section: Array = ball.section(Vector3.ZERO, Vector3(0, 0, 1))
	var raw: PackedVector3Array = section[0].points
	if raw.size() > 1 and raw[0].distance_to(raw[raw.size() - 1]) < 1e-9:
		raw.remove_at(raw.size() - 1)
	var wanted := _polygon_area(raw, Vector3(0, 0, 1))
	for fit in [false, true]:
		var doc: Resource = DOCUMENT.new()
		var body := _add_mesh(doc, ball, "Ball")
		var feature := _tool(doc, "section_sketch", {"body": [_pick(body)], "plane": [plane], "fit": fit})
		var result := _rebuild(doc)
		_fine(result, feature, "#7 A section of a ball (fit %s)" % fit)
		_expect(is_same(_mesh(result, body), ball) or str(_mesh(result, body).digest()) == str(ball.digest()), "#7 The section feature should leave the body as it is.")
		var stat := str((MESH_FEATURE.reports.get(feature.id, {}) as Dictionary).get("stat", ""))
		_expect(stat.begins_with("Section: 1 closed and 0 open curve") and stat.contains("arc") == fit, "#7 The section's stat line should count its curves ('%s')." % stat)
		var made: Dictionary = MESH_FEATURE.add_section_sketch(doc, result, feature)
		var sketch: Resource = made.feature
		_expect(str(made.error) == "" and sketch != null and str(sketch.type) == "sketch" and doc.features.size() == 2 and doc.features[1] == sketch and doc.find_feature(feature.id) == null
			and str(sketch.options.get("note", "")) == "Made from a section of Ball", "#7 The section should become one sketch feature in the mesh feature's place (%s)." % made.error)
		if sketch == null:
			continue
		var built := _rebuild(doc)
		var regions: Array = (built.sketches.get(sketch.id, {}) as Dictionary).get("regions", [])
		var area := 0.0
		for region in regions:
			area += float(region.face.area())
		var movable := 0
		var arcs := 0
		var lines := 0
		for entity in sketch.options.entities:
			if str(entity.type) == "point" and not bool(entity.get("fixed", false)):
				movable += 1
			arcs += 1 if str(entity.type) == "arc" else 0
			lines += 1 if str(entity.type) == "line" else 0
		_expect(built.errors.is_empty() and regions.size() >= 1 and absf(area - wanted) <= 0.01 * wanted and movable == 0 and (sketch.options.constraints as Array).is_empty()
			and (arcs >= 2 if fit else arcs == 0) and int(made.segments) == arcs + lines,
			"#7 The sketch (fit %s) should hold a closed profile within 1 %% of the section's area, fixed (regions %d, area %s of %s, %d lines, %d arcs, %d free points; %s)." % [fit, regions.size(), area, wanted, lines, arcs, movable, str(built.errors)])
	# A plane that misses the body, an open body, a tolerance out of range.
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, ball, "Ball")
	var plate := _add_fixture(doc, FIXTURES.open_plate(), "Plate")
	var miss := _tool(doc, "section_sketch", {"body": [_pick(body)], "plane": [{"kind": "construct", "feature": "none"}]})
	var across := _tool(doc, "section_sketch", {"body": [_pick(plate)], "plane": [plane]})
	var coarse := _tool(doc, "section_sketch", {"body": [_pick(body)], "plane": [plane]}, {"tolerance": _len(0.02)})
	var result := _rebuild(doc)
	_expect(_error(result, miss) != "", "#7 A section with no plane should be refused.")
	_fine(result, across, "#7 A section of an open plate", ["1 section curve is open."])
	_refused(result, coarse, "#7 A Simplify Tolerance above a twentieth of the body", ["Simplify Tolerance must be between 0 mm and", "Ball"])
	var open_sketch: Dictionary = MESH_FEATURE.add_section_sketch(doc, result, across, false)
	_expect(str(open_sketch.error) == "" and str(open_sketch.warning) == "1 section curve is open." and doc.find_feature(across.id) != null, "#7 The sketch of an open section should carry the warning and may leave the mesh feature (%s)." % str(open_sketch))
	var away_doc: Resource = DOCUMENT.new()
	var away_body := _add_mesh(away_doc, FIXTURES.to_mesh(FIXTURES.icosphere(0.01, 2, Vector3(0, 0, 0.1))), "Far")
	var away := _tool(away_doc, "section_sketch", {"body": [_pick(away_body)], "plane": [plane]})
	var away_result := _rebuild(away_doc)
	_expect(_error(away_result, away) == "The plane does not cut Far.", "#7 A plane that misses the body should be refused by name ('%s')." % _error(away_result, away))
	_expect(str(MESH_FEATURE.add_section_sketch(away_doc, away_result, away).error) == "The plane does not cut Far." and away_doc.features.size() == 2, "#7 No sketch should be made of a section that is refused.")
	checked.append("#7 Create Mesh Section Sketch (a fixed sketch whose profile matches the section within 1 %, lines and fitted arcs, open curves warned, a missing plane, a plane that misses, the tolerance range)")


# --- 5.2 #8-9: Close Holes ---------------------------------------------------------------------

func _check_close_holes() -> void:
	var blob := FIXTURES.holed_blob()
	var mesh := FIXTURES.to_mesh(blob)
	var loops: Array = mesh.boundary_loops()
	var largest := 0
	for loop in loops:
		largest = maxi(largest, int(loop.edges))
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, mesh, "Blob")
	var feature := _tool(doc, "close_holes", {"bodies": [_pick(body)], "loops": [], "fill": "smooth", "refine": true}, {"max_edges": _num(0)})
	var result := _rebuild(doc)
	var closed := _mesh(result, body)
	_fine(result, feature, "#8 Close Holes (all)")
	_expect(_closed(closed) and _bag_within(_triangle_bag(mesh), _triangle_bag(closed)), "#8 Close Holes should close every hole and leave the original triangles as they were.")
	var stat := str((MESH_FEATURE.reports.get(feature.id, {}) as Dictionary).get("stat", ""))
	_expect(stat == "Holes closed: 5", "#8 The stat line should count the holes ('%s')." % stat)
	# 9. Largest Hole: holes with more edges stay open, and the warning counts them.
	var smaller := 0
	for loop in loops:
		smaller += 1 if int(loop.edges) < largest else 0
	feature.set_expression("max_edges", str(largest - 1))
	var partly := _rebuild(doc)
	var left := _mesh(partly, body)
	_fine(partly, feature, "#9 Close Holes with Largest Hole %d" % (largest - 1), ["Blob: 1 hole was larger than Largest Hole and stays open."] if loops.size() - smaller == 1 else ["Blob: %d holes were larger than Largest Hole and stay open." % (loops.size() - smaller)])
	_expect(left != null and (left.boundary_loops() as Array).size() == loops.size() - smaller and _open_edges(left) == largest * (loops.size() - smaller),
		"#9 Only the largest hole (%d edges) should stay open (%d loops, %d open edges)." % [largest, (left.boundary_loops() as Array).size() if left != null else -1, _open_edges(left)])
	# Picked holes: only those are closed. A pick made on another version of the body is told.
	feature.set_expression("max_edges", "0")
	feature.options["loops"] = [{"kind": "mesh_boundary", "body": body, "loop": int(loops[0].id), "edges": int(loops[0].edges), "digest": str(mesh.digest())}]
	var one := _rebuild(doc)
	_fine(one, feature, "Close Holes on one picked hole")
	_expect((_mesh(one, body).boundary_loops() as Array).size() == loops.size() - 1, "Closing one picked hole should leave the others open.")
	feature.options["loops"] = [{"kind": "mesh_boundary", "body": body, "loop": int(loops[0].id), "edges": int(loops[0].edges), "digest": "0000000000000000"}]
	var stale := _rebuild(doc)
	_fine(stale, feature, "Close Holes on a hole picked on an older body", ["the holes were picked on an older version of Blob"])
	feature.options["loops"] = [{"kind": "mesh_boundary", "body": body, "loop": 99, "edges": 3, "digest": str(mesh.digest())}]
	_refused(_rebuild(doc), feature, "A hole that is not there", ["Hole 99 is not in"])
	# A closed body: nothing to close, said with the body's name.
	var ball_doc: Resource = DOCUMENT.new()
	var ball := _add_fixture(ball_doc, FIXTURES.icosphere(0.02, 2), "Ball")
	var nothing := _tool(ball_doc, "close_holes", {"bodies": [_pick(ball)]})
	var same := _rebuild(ball_doc)
	_fine(same, nothing, "Close Holes on a closed body", ["Ball has no open edges: there is nothing to close."])
	checked.append("#8-9 Close Holes (all holes, original triangles kept, Largest Hole with its warning, picked holes, a stale pick, a hole that is gone, a closed body)")


# --- 5.2 #10-11: Stitch and Remove -----------------------------------------------------------

func _check_stitch() -> void:
	var debris := FIXTURES.cube_debris()
	var doc: Resource = DOCUMENT.new()
	var body := _add_fixture(doc, debris, "Cube")
	var feature := _tool(doc, "stitch_remove", {"bodies": [_pick(body)], "remove_small": true, "remove_inner": false, "fix_non_manifold": true}, {"tolerance": _len(0.0000005), "min_size": _num(1)})
	var result := _rebuild(doc)
	var clean := _mesh(result, body)
	_fine(result, feature, "#10 Stitch and Remove")
	_expect(clean != null and int(clean.triangle_count()) == 12 and _closed(clean) and absf(float(clean.volume()) - 8e-6) < 1e-10, "#10 Stitch and Remove should leave the 12-triangle cube (%d)." % (int(clean.triangle_count()) if clean != null else -1))
	var stat := str((MESH_FEATURE.reports.get(feature.id, {}) as Dictionary).get("stat", ""))
	_expect(stat.begins_with("Welded ") and stat.contains("removed") and stat.contains("pieces"), "#10 The stat line should be the summary ('%s')." % stat)
	feature.options["remove_small"] = false
	var kept := _rebuild(doc)
	var with_debris := _mesh(kept, body)
	_expect(_error(kept, feature) == "" and with_debris != null and int(with_debris.triangle_count()) == 12 + int(debris.expected.tiny) and int((with_debris.check(5.0) as Dictionary).get("degenerate_triangles", -1)) == 0
		and int((with_debris.check(5.0) as Dictionary).get("duplicate_triangles", -1)) == 0, "#11 With Remove Small Pieces off the %d tiny triangles should stay, without duplicates or triangles without area (%d triangles; %s)." % [int(debris.expected.tiny), int(with_debris.triangle_count()) if with_debris != null else -1, _error(kept, feature)])
	# A hollow body keeps its void.
	var hollow_doc: Resource = DOCUMENT.new()
	var hollow := _add_fixture(hollow_doc, FIXTURES.hollow_cube(false), "Hollow")
	var hollow_feature := _tool(hollow_doc, "stitch_remove", {"bodies": [_pick(hollow)]})
	var hollow_result := _rebuild(hollow_doc)
	_fine(hollow_result, hollow_feature, "Stitch and Remove on a hollow cube")
	_expect(int(_mesh(hollow_result, hollow).triangle_count()) == 24 and absf(float(_mesh(hollow_result, hollow).volume()) - 7000 * MM3) < 1e-12, "Stitch and Remove should keep a hollow cube's void (7,000 mm3).")
	checked.append("#10-11 Stitch and Remove (the debris cube to 12 triangles with the summary, Remove Small Pieces off, a hollow body kept)")


# --- 5.2 #12-13, #46: Wrap -------------------------------------------------------------------

func _check_wrap() -> void:
	var blob := FIXTURES.holed_blob()
	var mesh := FIXTURES.to_mesh(blob)
	var reference := FIXTURES.to_mesh(blob.reference)
	var size: float = (mesh.bbox() as AABB).size.length()
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, mesh, "Blob")
	# (A gap of 26 mm closes the blob's holes, 6 to 40 mm across; the spec's 3 mm does not: 10.8.)
	var feature := _tool(doc, "wrap", {"bodies": [_pick(body)]}, {"detail": _len(1.5 * MM), "gap": _len(26 * MM), "offset": _len(0.0)})
	var result := _rebuild(doc)
	var wrapped := _mesh(result, body)
	_fine(result, feature, "#12 Wrap", ["Edges are rounded to about 1.5 mm."])
	_expect(_closed(wrapped) and absf(float(wrapped.volume()) - float(reference.volume())) < 0.03 * float(reference.volume()) and int(wrapped.group_count()) == 1 and str(wrapped.get_face_names()[0]) == "wrap0",
		"#12 Wrap should give one closed body within 3 %% of the blob's volume (%s of %s)." % [wrapped.volume() if wrapped != null else 0.0, reference.volume()])
	# The spec's old numbers are refused, after the work, with what to change; the refusal is kept.
	feature.set_expression("detail", "1 mm")
	feature.set_expression("gap", "3 mm")
	MESH_FEATURE.clear_cache()
	var started := Time.get_ticks_usec()
	var open := _rebuild(doc)
	var first := (Time.get_ticks_usec() - started) / 1000.0
	started = Time.get_ticks_usec()
	var open_again := _rebuild(doc)
	var second := (Time.get_ticks_usec() - started) / 1000.0
	_refused(open, feature, "#12 A Wrap whose gap is smaller than the holes", ["Wrap would leave", "of Blob out", "gaps wider than 6 mm", "Raise Close Gaps Up To"])
	_expect(_error(open_again, feature) == _error(open, feature) and second < 0.05 * first, "#46 A refused Wrap should be answered from the cache on the next rebuild (%.1f ms, then %.1f ms)." % [first, second])
	# 13. Over the grid: refused at once with the cell count. (The spec's D/1000 is under the range.)
	feature.set_expression("gap", "26 mm")
	feature.set_expression("detail", "%s mm" % String.num(size / 390.0 * 1000.0, 6))
	MESH_FEATURE.clear_cache()
	var ctx := _ctx(doc, _rebuild(doc))
	var grid := _error(REGEN.rebuild(doc, kernel), feature)
	_expect(grid.contains("Wrap needs") and grid.contains("million cells; raise Detail to"), "#13 A Wrap over the grid should be refused with the cell count ('%s')." % grid)
	# Refused before any work (the limit and what was measured: WRAP_GRID_RATIO).
	var step := [0]
	var timed := TIMING.compare(func() -> void:
		step[0] += 1
		feature.set_expression("detail", "%s mm" % String.num(size / (390.0 + step[0] * 0.001) * 1000.0, 9))
		ctx.values = PARAMETERS.evaluate(doc)
		MESH_FEATURE.build(feature, ctx), _calibration, 5, "wrap over the grid")
	_expect(float(timed.ratio) < WRAP_GRID_RATIO, "#13 A Wrap over the grid should be refused before any work (ratio %.3f, limit %.3f: %.2f ms against %.2f ms)." % [timed.ratio, WRAP_GRID_RATIO, timed.op, timed.calibration])
	feature.set_expression("detail", "%s mm" % String.num(size / 1000.0 * 1000.0, 6))
	_refused(_rebuild(doc), feature, "#13 A Detail under the range", ["Detail must be between"])
	# Several bodies wrap into one: the first one's.
	var pair_doc: Resource = DOCUMENT.new()
	var cubes := FIXTURES.two_cubes(Vector3(0.022, 0.0, 0.0))
	var a := _add_fixture(pair_doc, cubes.first, "A")
	var b := _add_fixture(pair_doc, cubes.second, "B")
	var both := _tool(pair_doc, "wrap", {"bodies": [_pick(a), _pick(b)]}, {"detail": _len(1 * MM), "gap": _len(3 * MM)})
	var pair := _rebuild(pair_doc)
	_fine(pair, both, "Wrap of two bodies", ["Edges are rounded to about 1 mm."])
	_expect(_mesh(pair, a) != null and not pair.bodies.has(b) and int(_mesh(pair, a).solid_count()) == 1 and float(_mesh(pair, a).volume()) > 16000 * MM3,
		"Two cubes 2 mm apart should wrap into one body, the first one's (%s)." % str(pair.bodies.keys()))
	checked.append("#12-13, #46 Wrap (closed with the rounded-edges note, the old numbers refused and kept, over the grid refused at once, under the range, two bodies into one)")


func _calibration() -> void:
	var ball: RefCounted = kernel.make_sphere(0.02, Vector3.ZERO, "calibration")
	ball.tessellate(0.0002, 0.3)


## A feature handler's context on a rebuild's result (to call a handler by itself, for timing).
func _ctx(doc: Resource, result: Dictionary, limit := 20.0) -> Dictionary:
	return {
		"kernel": kernel, "doc": doc, "values": result.values, "bodies": (result.bodies as Dictionary).duplicate(), "sketches": result.sketches,
		"construction": result.construction, "tools": {}, "warnings": {}, "threads": {}, "forms": {}, "form_preview": "", "mesh_time_limit": limit,
	}


# --- 5.2 #14: Rebuild ------------------------------------------------------------------------

func _check_rebuild() -> void:
	var doc: Resource = DOCUMENT.new()
	var body := _add_fixture(doc, FIXTURES.self_crossing(), "Pair")
	var feature := _tool(doc, "rebuild", {"bodies": [_pick(body)], "algorithm": "union"}, {"detail": _len(0.5 * MM)})
	var result := _rebuild(doc)
	var rebuilt := _mesh(result, body)
	_fine(result, feature, "#14 Rebuild", ["Rebuild changed the volume by", "Edges are rounded to about 0.5 mm."])
	_expect(_closed(rebuilt) and int((rebuilt.check(10.0) as Dictionary).get("self_intersections", -1)) == 0 and str(rebuilt.get_face_names()[0]) == "rebuild0", "#14 Rebuild of two crossing balls should be closed and cross itself nowhere.")
	_expect(_warning(result, feature).contains("Pair") or not _warning(result, feature).contains("{body}"), "#14 No warning should hold the name token ('%s')." % _warning(result, feature))
	feature.options["algorithm"] = "exact_surface"
	var exact := _rebuild(doc)
	_expect(_error(exact, feature) == "" and _closed(_mesh(exact, body)) and str(_mesh(exact, body).digest()) != str(rebuilt.digest()), "#14 The Exact Surface method should build too, to another mesh (%s)." % _error(exact, feature))
	feature.options["algorithm"] = "fancy"
	_refused(_rebuild(doc), feature, "An unknown Rebuild method", ["Method must be one of"])
	checked.append("#14 Rebuild (two crossing balls closed with no crossings, its warnings, Exact Surface, an unknown method)")


# --- 5.2 #15-17: face groups -------------------------------------------------------------------

func _check_groups() -> void:
	var bracket := FIXTURES.l_bracket()
	var grouped: RefCounted = bracket.mesh
	var faces := int(grouped.group_count())
	var plain := FIXTURES.to_mesh({"positions": bracket.positions, "indices": bracket.indices, "groups": PackedInt32Array(), "names": PackedStringArray()})
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, plain, "Bracket")
	var feature := _tool(doc, "generate_groups", {"bodies": [_pick(body)], "algorithm": "accurate"}, {"tolerance": _len((plain.bbox() as AABB).size.length() / 2000.0), "min_size": _num(10)})
	var result := _rebuild(doc)
	var made := _mesh(result, body)
	_fine(result, feature, "#15 Generate Face Groups (accurate)")
	_expect(made != null and int(made.group_count()) == faces and int(made.triangle_count()) == int(plain.triangle_count()) and _bag_within(_triangle_bag(plain), _triangle_bag(made)),
		"#15 Generate Face Groups on the one-group bracket should give its %d faces and change no triangle (%d)." % [faces, int(made.group_count()) if made != null else -1])
	var names: PackedStringArray = made.get_face_names()
	MESH_FEATURE.clear_cache()
	var again := _mesh(_rebuild(doc), body)
	_expect(not is_same(again, made) and again.get_face_names() == names and str(names[0]) == "g0" and str(names[names.size() - 1]) == "g%d" % (faces - 1) and str(again.digest()) == str(made.digest()),
		"#16 Generating the groups again should give the same names in the same order (%s)." % str(again.get_face_names()))
	feature.options["algorithm"] = "fast"
	feature.inputs["angle"] = doc.make_input("20", "angle")
	var fast := _rebuild(doc)
	_expect(_error(fast, feature) == "" and int(_mesh(fast, body).group_count()) == faces, "#15 The fast method at 20 degrees should find the %d faces too (%d; %s)." % [faces, int(_mesh(fast, body).group_count()), _error(fast, feature)])
	var stat := str((MESH_FEATURE.reports.get(feature.id, {}) as Dictionary).get("stat", ""))
	_expect(stat == "Face groups: %d" % faces, "#15 The stat line should count the groups ('%s')." % stat)
	# 17. Combine Face Groups and Create Face Group, on the bracket with its own groups.
	var group_doc: Resource = DOCUMENT.new()
	var grouped_body := _add_mesh(group_doc, grouped, "Bracket")
	var own: PackedStringArray = grouped.get_face_names()
	var combine := _tool(group_doc, "combine_groups", {"groups": [_group(grouped_body, own[2], grouped), _group(grouped_body, own[0], grouped), _group(grouped_body, own[4], grouped)]})
	var combined_result := _rebuild(group_doc)
	var combined := _mesh(combined_result, grouped_body)
	_fine(combined_result, combine, "#17 Combine Face Groups")
	var merged_count := (grouped.group_triangles(0) as PackedInt32Array).size() + (grouped.group_triangles(2) as PackedInt32Array).size() + (grouped.group_triangles(4) as PackedInt32Array).size()
	_expect(combined != null and int(combined.group_count()) == faces - 2 and int(combined.triangle_count()) == int(grouped.triangle_count()) and int(combined.find_face(own[2])) >= 0
		and (combined.group_triangles(int(combined.find_face(own[2]))) as PackedInt32Array).size() == merged_count and int(combined.find_face(own[0])) < 0
		and combined.get_arrays().positions == grouped.get_arrays().positions and combined.get_arrays().indices == grouped.get_arrays().indices,
		"#17 Combining three groups should leave %d, under the first picked name, with every triangle as it was." % (faces - 2))
	var picked := PackedInt32Array([0, 1, 2, 3, 4, 5])
	var create := _tool(group_doc, "create_group", {"selection": [_triangles(grouped_body, picked, combined)]})
	var created_result := _rebuild(group_doc)
	var created := _mesh(created_result, grouped_body)
	_fine(created_result, create, "#17 Create Face Group")
	var user := int(created.find_face("user0")) if created != null else -1
	_expect(user >= 0 and (created.group_triangles(user) as PackedInt32Array) == picked and int(created.triangle_count()) == int(grouped.triangle_count()) and created.get_arrays().indices == grouped.get_arrays().indices,
		"#17 Create Face Group should put the picked triangles into a new group user0.")
	# Groups of two bodies, one group only, a group that is gone, triangles picked on an older body.
	var other := _add_fixture(group_doc, FIXTURES.icosphere(0.01, 1), "Ball")
	var still: String = created.get_face_names()[0]
	var two_bodies := _tool(group_doc, "combine_groups", {"groups": [_group(grouped_body, still), _group(other, "g0")]})
	var one_group := _tool(group_doc, "combine_groups", {"groups": [_group(grouped_body, still)]})
	var gone := _tool(group_doc, "combine_groups", {"groups": [_group(grouped_body, still), _group(grouped_body, "nowhere")]})
	var stale := _tool(group_doc, "create_group", {"selection": [{"kind": "mesh_triangles", "body": other, "triangles": PackedInt32Array([1, 2, 500]), "digest": "0000000000000000"}]})
	var refusals := _rebuild(group_doc)
	_refused(refusals, two_bodies, "Combine Face Groups across two bodies", ["one body"])
	_refused(refusals, one_group, "Combine Face Groups with one group", ["two or more face groups of Bracket"])
	_refused(refusals, gone, "Combine Face Groups with a group that is gone", ["Bracket", "A picked face group can't be found any more"])
	_fine(refusals, stale, "Create Face Group with triangles picked on an older body", ["%s: the triangle selection was made on an older version of Ball; it may now cover other triangles. Reselect to be sure. 1 triangle is no longer there and left out." % stale.label])
	_expect((_mesh(refusals, other).group_triangles(int(_mesh(refusals, other).find_face("user0"))) as PackedInt32Array) == PackedInt32Array([1, 2]), "A stale selection should keep the triangles that are still there.")
	checked.append("#15-17 Generate Face Groups (accurate and fast give the bracket's %d faces, same names every time), Combine and Create Face Group (counts, names, triangles untouched, refusals, a stale selection warned)" % faces)


# --- 5.2 #18-19: Remesh ----------------------------------------------------------------------

func _check_remesh() -> void:
	var ball := FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 4))
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, ball, "Ball")
	var edge := 2 * MM
	var feature := _tool(doc, "remesh", {"bodies": [_pick(body)], "selection": [], "mode": "uniform", "keep_sharp": true, "keep_boundary": true, "keep_groups": true},
		{"density": _num(0.5), "edge_length": _len(edge), "iterations": _num(10), "sharp_angle": _deg(45)})
	var result := _rebuild(doc)
	var made := _mesh(result, body)
	_fine(result, feature, "#18 Remesh to 2 mm edges")
	var mean := _mean_edge(made) if made != null else 0.0
	var off := _hausdorff(made, ball) if made != null else INF
	_expect(made != null and absf(mean - edge) <= 0.1 * edge and off <= 0.25 * edge and _closed(made), "#18 Remesh should give edges within 10 %% of 2 mm (%.4f mm) no farther than 0.5 mm from the ball (%.4f mm), closed." % [mean * 1000.0, off * 1000.0])
	var report: Dictionary = MESH_FEATURE.reports.get(feature.id, {})
	_expect(str(report.get("stat", "")).begins_with("Edges: ") and int((report.get("input", {}) as Dictionary).get("triangles", 0)) == 5120 and int((report.get("output", {}) as Dictionary).get("triangles", 0)) == int(made.triangle_count())
		and int((report.get("output", {}) as Dictionary).get("boundary_edges", -1)) == 0, "#18 The report should count the triangles before and after (%s)." % str(report.get("output", {})))
	# 19. A selection: only its triangles change.
	var selection: PackedInt32Array = ball.grow(PackedInt32Array([0]), 8)
	var part_doc: Resource = DOCUMENT.new()
	var part_body := _add_mesh(part_doc, ball, "Ball")
	var part := _tool(part_doc, "remesh", {"bodies": [], "selection": [_triangles(part_body, selection, ball)], "mode": "uniform"}, {"edge_length": _len(edge), "iterations": _num(5)})
	var part_result := _rebuild(part_doc)
	var patched := _mesh(part_result, part_body)
	_expect(_error(part_result, part) == "" and patched != null and str(patched.digest()) != str(ball.digest()) and _bag_within(_triangle_bag(ball, PackedInt32Array(), selection), _triangle_bag(patched)) and _closed(patched),
		"#19 Remesh of a selection should leave every triangle outside it as it was (%s; %d of %d triangles picked)." % [_error(part_result, part), selection.size(), 5120])
	# A selection too small to remesh is said, with the body's name; the body stays.
	part.options["selection"] = [_triangles(part_body, PackedInt32Array([0]), ball)]
	var small := _rebuild(part_doc)
	_fine(small, part, "Remesh of one triangle", ["The selection is too small to remesh; grow it."])
	_expect(_warning(small, part).begins_with("Ball: ") and str(_mesh(small, part_body).digest()) == str(ball.digest()), "Remesh of one triangle should leave the body and name it in the warning ('%s')." % _warning(small, part))
	# Adaptive reads its own fields.
	var adaptive_doc: Resource = DOCUMENT.new()
	var adaptive_body := _add_mesh(adaptive_doc, ball, "Ball")
	var adaptive := _tool(adaptive_doc, "remesh", {"bodies": [_pick(adaptive_body)], "mode": "adaptive"}, {"min_edge": _len(1 * MM), "max_edge": _len(4 * MM), "approx_error": _len(0.05 * MM), "iterations": _num(3), "edge_length": _len(0.00001 * MM)})
	var adapted := _rebuild(adaptive_doc)
	_expect(_error(adapted, adaptive) == "" and _closed(_mesh(adapted, adaptive_body)), "Adaptive Remesh should build, and not read the Uniform fields (%s)." % _error(adapted, adaptive))
	checked.append("#18-19 Remesh (2 mm edges within 10 % and 0.25 L of the ball with no warning, the report, a selection with the rest untouched, too small a selection, Adaptive)")


# --- 5.2 #21-23: Reduce ----------------------------------------------------------------------

func _check_reduce() -> void:
	var ball := FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 5))
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, ball, "Ball")
	var feature := _tool(doc, "reduce", {"bodies": [_pick(body)], "selection": [], "target": "proportion", "algorithm": "adaptive", "keep_boundary": true, "keep_groups": true, "keep_sharp": false}, {"proportion": _num(50)})
	var result := _rebuild(doc)
	var made := _mesh(result, body)
	_fine(result, feature, "#21 Reduce to 50 %")
	_expect(made != null and absi(int(made.triangle_count()) - 10240) <= 204 and _closed(made), "#21 Reduce to 50 %% should keep 10,240 triangles within 2 %% (%d), closed." % (int(made.triangle_count()) if made != null else -1))
	var report: Dictionary = MESH_FEATURE.reports.get(feature.id, {})
	_expect(float((report.get("deviation", {}) as Dictionary).get("max", -1.0)) > 0.0 and float(report.deviation.max) <= 0.05 * MM, "#21 The report should carry the measured deviation (%s)." % str(report.get("deviation", {})))
	# Fast: within 2 % too.
	feature.options["algorithm"] = "fast"
	var fast := _rebuild(doc)
	_expect(_error(fast, feature) == "" and absi(int(_mesh(fast, body).triangle_count()) - 10240) <= 204 and _open_edges(_mesh(fast, body)) == 0, "#21 Fast Reduce to 50 %% should keep 10,240 triangles within 2 %% (%d; %s)." % [int(_mesh(fast, body).triangle_count()), _error(fast, feature)])
	# By a deviation nothing fits under: the honest outcome (10.9), named.
	feature.options["algorithm"] = "adaptive"
	feature.options["target"] = "tolerance"
	feature.inputs["tolerance"] = doc.make_input("0.01 mm", "length")
	var tight := _rebuild(doc)
	_fine(tight, feature, "Reduce by a 0.01 mm deviation", ["Nothing could be taken out within the Maximum Deviation of 0.01 mm."])
	_expect(int(_mesh(tight, body).triangle_count()) == 20480 and _warning(tight, feature).begins_with("Ball: "), "Reduce by 0.01 mm should take nothing out of the ball, and say so by name ('%s')." % _warning(tight, feature))
	feature.set_expression("tolerance", "0.3 mm")
	var loose := _rebuild(doc)
	_expect(_error(loose, feature) == "" and int(_mesh(loose, body).triangle_count()) < 20480 and _hausdorff(_mesh(loose, body), ball) <= 0.3 * MM, "Reduce by a 0.3 mm deviation should take triangles out and stay within it (%s)." % _error(loose, feature))
	# 22. Keep Face Group Borders on the bracket.
	var bracket: RefCounted = FIXTURES.l_bracket().mesh
	var bracket_doc: Resource = DOCUMENT.new()
	var bracket_body := _add_mesh(bracket_doc, bracket, "Bracket")
	var keep := _tool(bracket_doc, "reduce", {"bodies": [_pick(bracket_body)], "target": "proportion", "algorithm": "adaptive", "keep_groups": true}, {"proportion": _num(50)})
	var kept_result := _rebuild(bracket_doc)
	var kept := _mesh(kept_result, bracket_body)
	_expect(_error(kept_result, keep) == "" and kept != null and kept.get_face_names() == bracket.get_face_names() and _closed(kept), "#22 Reduce with Keep Face Group Borders should keep the bracket's groups (%s)." % _error(kept_result, keep))
	var wanted := int(bracket.triangle_count()) / 2
	var given: Array = (MESH_FEATURE.reports.get(keep.id, {}) as Dictionary).get("warnings", [])
	if kept != null and absi(int(kept.triangle_count()) - wanted) > int(0.02 * wanted):
		var said := false
		for warning in given:
			said = said or (str(warning).contains("Reduce kept %d triangles" % int(kept.triangle_count())) and str(warning).contains("instead of %d" % wanted))
		_expect(said, "#22 A Reduce that stops above its target should say so with the real numbers (%d of %d; %s)." % [int(kept.triangle_count()), wanted, str(given)])
	else:
		_expect(given.is_empty(), "#22 A Reduce that reaches its target should not warn (%s)." % str(given))
	# 23. A count the body can't have.
	var cube_doc: Resource = DOCUMENT.new()
	var cube := _add_fixture(cube_doc, FIXTURES.two_cubes(Vector3(0.05, 0, 0)).first, "Cube")
	var count := _tool(cube_doc, "reduce", {"bodies": [_pick(cube)], "target": "face_count", "algorithm": "adaptive"}, {"face_count": _num(100), "proportion": _num(500)})
	var refused := _rebuild(cube_doc)
	_expect(_error(refused, count) == "Cube: Triangle Count must be a whole number between 4 and 11.", "#23 A Triangle Count of 100 on a 12-triangle cube should be refused with its range ('%s')." % _error(refused, count))
	# A selection: the rest of the body stays.
	var selection: PackedInt32Array = ball.grow(PackedInt32Array([0]), 24)
	var part_doc: Resource = DOCUMENT.new()
	var part_body := _add_mesh(part_doc, ball, "Ball")
	var part := _tool(part_doc, "reduce", {"selection": [_triangles(part_body, selection, ball)], "target": "proportion", "algorithm": "adaptive"}, {"proportion": _num(98)})
	var part_result := _rebuild(part_doc)
	var patched := _mesh(part_result, part_body)
	_expect(_error(part_result, part) == "" and patched != null and absi(int(patched.triangle_count()) - 20070) <= 401 and _bag_within(_triangle_bag(ball, PackedInt32Array(), selection), _triangle_bag(patched)) and _closed(patched),
		"Reduce of a selection (%d triangles) to 98 %% of the body should leave every triangle outside it as it was (%d triangles; %s)." % [selection.size(), int(patched.triangle_count()) if patched != null else -1, _error(part_result, part)])
	# The proportion is of the whole body: a selection too small for it is refused, by name.
	part.set_expression("proportion", "50")
	_refused(_rebuild(part_doc), part, "A selection too small for the proportion", ["Ball: The selection has", "Grow the selection or keep more triangles."])
	checked.append("#21-23 Reduce (50 % within 2 % with both methods, the deviation reported, a deviation nothing fits under, Keep Face Group Borders, a count out of range, a selection)")


# --- 5.2 #24-27: Plane Cut -------------------------------------------------------------------

func _check_plane_cut() -> void:
	var ball := FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 5))
	var xy := {"kind": "origin", "name": "xy"}
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, ball, "Ball")
	var feature := _tool(doc, "plane_cut", {"bodies": [_pick(body)], "plane": [xy], "type": "trim", "flip": false, "fill": "uniform"}, {"offset": _len(10 * MM)})
	var result := _rebuild(doc)
	var cut := _mesh(result, body)
	var cap := PI * 0.04 * 0.04 * (3.0 * 0.05 - 0.04) / 3.0
	_fine(result, feature, "#24 Plane Cut (trim, uniform fill)")
	_expect(_closed(cut) and absf(float(cut.volume()) - cap) <= 0.005 * cap and int(cut.find_face("cut0")) >= 0 and (cut.bbox() as AABB).position.z > 0.01 - 1e-7,
		"#24 A trimmed and filled ball should be closed, the part above the plane, within 0.5 %% of the cap's volume (%s of %s)." % [cut.volume() if cut != null else 0.0, cap])
	# 25. No fill: the cut loop stays open, edge for edge.
	var loop: PackedVector3Array = (ball.section(Vector3(0, 0, 0.01), Vector3(0, 0, 1)) as Array)[0].points
	var loop_edges := loop.size() - (1 if loop[0].distance_to(loop[loop.size() - 1]) < 1e-9 else 0)
	feature.options["fill"] = "none"
	var open := _rebuild(doc)
	_fine(open, feature, "#25 Plane Cut with no fill")
	_expect(_open_edges(_mesh(open, body)) == loop_edges and loop_edges > 10, "#25 With Fill None the open edges should be the cut loop's %d (%d)." % [loop_edges, _open_edges(_mesh(open, body))])
	# Keep Other Side.
	feature.options["fill"] = "minimal"
	feature.options["flip"] = true
	var other := _rebuild(doc)
	_expect(_error(other, feature) == "" and _closed(_mesh(other, body)) and (_mesh(other, body).bbox() as AABB).end.z < 0.01 + 1e-7, "Keep Other Side should keep the part under the plane (%s)." % _error(other, feature))
	# 26. Split Body: two bodies, kept in the feature, the same on every rebuild.
	feature.options["flip"] = false
	feature.options["fill"] = "uniform"
	feature.options["type"] = "split_body"
	var registered: int = doc.bodies.size()
	var preview := REGEN.rebuild(doc, kernel, {"mesh_time_limit": MESH_FEATURE.PREVIEW_SECONDS})
	_expect(_error(preview, feature) == "" and preview.bodies.size() == 2 and doc.bodies.size() == registered and not feature.options.has("outputs"),
		"#26 A preview of Split Body should show both parts and register nothing in the design (%s)." % _error(preview, feature))
	var split := _rebuild(doc)
	var outputs: Array = feature.options.get("outputs", [])
	# (The plane passes within a millionth of the ball's size of some corners. The thin triangles
	# that leaves are no longer counted as "without area": that is judged by each triangle's own
	# shape now, and these have one. The parts are checked for it below.)
	_fine(split, feature, "#26 Plane Cut (split body)")
	for part_id in [body, str(outputs[1]) if outputs.size() == 2 else body]:
		var part_check: Dictionary = _mesh(split, part_id).check(5.0)
		_expect(int(part_check.get("degenerate_triangles", -1)) == 0 and bool(part_check.get("oriented", false)), "#26 A part of the split ball should hold no triangle without area and face one way (%s)." % str(part_check))
	_expect(split.bodies.size() == 2 and outputs.size() == 2 and str(outputs[0]) == body and doc.bodies.has(str(outputs[1])) and doc.body_name(str(outputs[1])) == "Ball (2)"
		and _closed(_mesh(split, body)) and _closed(_mesh(split, str(outputs[1]))) and absf(float(_mesh(split, body).volume()) + float(_mesh(split, str(outputs[1])).volume()) - float(ball.volume())) <= 1e-6 * float(ball.volume())
		and absf(float(_mesh(split, body).volume()) - cap) <= 0.005 * cap, "#26 Split Body should give two closed bodies whose volumes add up to the ball's, with both ids kept (%s)." % str(outputs))
	var again := _rebuild(doc)
	_expect(feature.options.get("outputs", []) == outputs and doc.bodies.size() == registered + 1 and is_same(_mesh(again, str(outputs[1])), _mesh(split, str(outputs[1]))) and _warning(again, feature) == "",
		"#26 A rebuild should keep the ids, register no further body and give the same meshes.")
	# 27. A plane that misses, and one on an outer face.
	feature.options["type"] = "trim"
	feature.set_expression("offset", "60 mm")
	var missed := _rebuild(doc)
	_expect(_error(missed, feature) == "The plane does not cut Ball.", "#27 A plane beyond the ball should be refused ('%s')." % _error(missed, feature))
	var cube_doc: Resource = DOCUMENT.new()
	var cube := _add_fixture(cube_doc, FIXTURES.two_cubes(Vector3(0.05, 0, 0)).first, "Cube")
	var top: float = (cube_doc.bodies.size() * 0.0) + (FIXTURES.to_mesh(FIXTURES.two_cubes(Vector3(0.05, 0, 0)).first).bbox() as AABB).end.z
	var on_face := _tool(cube_doc, "plane_cut", {"bodies": [_pick(cube)], "plane": [xy], "type": "trim", "fill": "uniform"}, {"offset": _len(top)})
	var on_face_result := _rebuild(cube_doc)
	_expect(_error(on_face_result, on_face) == "The plane does not cut Cube.", "#27 A plane on an outer face of a cube should be refused the same way ('%s')." % _error(on_face_result, on_face))
	# Split Faces: nothing is taken away, the crossed groups get a second group.
	on_face.set_expression("offset", "0 mm")
	on_face.options["type"] = "split_faces"
	var faces := _rebuild(cube_doc)
	var faced := _mesh(faces, cube)
	_expect(_error(faces, on_face) == "" and faced != null and _closed(faced) and absf(float(faced.volume()) - 8e-6) < 1e-11 and int(faced.group_count()) == 2, "Split Faces should keep the whole cube and add a group for the upper side (%s)." % _error(faces, on_face))
	# A flat face group as the plane; a body that crosses itself is told.
	var bracket: RefCounted = FIXTURES.l_bracket().mesh
	var flat := ""
	for i in int(bracket.group_count()):
		var info: Dictionary = bracket.face_info(i)
		if bool(info.get("planar", false)) and absf((info.normal as Vector3).z) > 0.99 and (info.point as Vector3).z > 0.02:
			flat = str(bracket.get_face_names()[i])
	var bracket_doc: Resource = DOCUMENT.new()
	var bracket_body := _add_mesh(bracket_doc, bracket, "Bracket")
	var by_group := _tool(bracket_doc, "plane_cut", {"bodies": [_pick(bracket_body)], "plane": [_group(bracket_body, flat, bracket)], "type": "trim", "fill": "uniform", "flip": true}, {"offset": _len(-10 * MM)})
	var by_group_result := _rebuild(bracket_doc)
	_fine(by_group_result, by_group, "Plane Cut by a flat face group")
	_expect(flat != "" and _closed(_mesh(by_group_result, bracket_body)) and absf((_mesh(by_group_result, bracket_body).bbox() as AABB).size.z - 0.02) < 1e-6, "A cut 10 mm under the bracket's top face should leave 20 mm of it (%s)." % str((_mesh(by_group_result, bracket_body).bbox() as AABB).size))
	var crossing_doc: Resource = DOCUMENT.new()
	var crossing := _add_fixture(crossing_doc, FIXTURES.self_crossing(), "Pair")
	var crossed := _tool(crossing_doc, "plane_cut", {"bodies": [_pick(crossing)], "plane": [xy], "type": "trim", "fill": "uniform"})
	var crossed_result := _rebuild(crossing_doc)
	var crossed_notes: Array = (MESH_FEATURE.reports.get(crossed.id, {}) as Dictionary).get("warnings", [])
	_expect(_error(crossed_result, crossed) == "" and crossed_notes.has("Pair crosses itself, so the result may be wrong there. Rebuild it first."), "Plane Cut on a body that crosses itself should say so (%s; %s)." % [str(crossed_notes), _error(crossed_result, crossed)])
	checked.append("#24-27 Plane Cut (trim with fill closed at the cap's volume, no fill leaves the loop open, Keep Other Side, Split Body with its ids kept and a preview that registers nothing, a plane that misses or lies on a face, Split Faces, a face group as the plane, a self-crossing body warned)")


# --- 5.2 #28-30: Shell -----------------------------------------------------------------------

func _check_shell() -> void:
	var ball := FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 5))
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, ball, "Ball")
	var feature := _tool(doc, "shell", {"bodies": [_pick(body)], "direction": "inside", "algorithm": "accurate"}, {"thickness": _len(2 * MM)})
	var result := _rebuild(doc)
	var shell := _mesh(result, body)
	_fine(result, feature, "#28 Shell (accurate, inside, 2 mm)")
	var report: Dictionary = MESH_FEATURE.reports.get(feature.id, {})
	var wall: Dictionary = report.get("wall", {})
	var hollow := 4.0 / 3.0 * PI * (pow(0.05, 3) - pow(0.048, 3))
	_expect(_closed(shell) and int(wall.get("samples", 0)) >= 400 and float(wall.get("within", 0)) >= 0.95 and float(wall.get("min", 0)) >= 0.8 * 2 * MM and float(wall.get("max", 1)) <= 1.2 * 2 * MM and absf(float(shell.volume()) - hollow) < 0.02 * hollow,
		"#28 An accurate 2 mm shell of a ball should pass its wall check and hold a wall's volume (wall %s, volume %s of %s)." % [str(wall), shell.volume() if shell != null else 0.0, hollow])
	_expect(str(report.get("stat", "")).begins_with("Wall: "), "#28 The stat line should give the wall ('%s')." % str(report.get("stat", "")))
	# 29. Fast on a concave body: it passes its wall check, or it says what is off. Never neither.
	var bracket: RefCounted = FIXTURES.l_bracket().mesh
	var bracket_doc: Resource = DOCUMENT.new()
	var bracket_body := _add_mesh(bracket_doc, bracket, "Bracket")
	var fast := _tool(bracket_doc, "shell", {"bodies": [_pick(bracket_body)], "direction": "inside", "algorithm": "fast"}, {"thickness": _len(1 * MM), "detail": _len(0.0001 * MM)})
	var fast_result := _rebuild(bracket_doc)
	var fast_report: Dictionary = MESH_FEATURE.reports.get(fast.id, {})
	var fast_wall: Dictionary = fast_report.get("wall", {})
	var fast_notes: Array = fast_report.get("warnings", [])
	var passed: bool = int(fast_wall.get("samples", 0)) > 0 and float(fast_wall.get("within", 0)) >= 0.95 and int(fast_report.get("self_intersections", 0)) == 0
	var said := false
	for warning in fast_notes:
		said = said or str(warning).contains("crosses itself in") or str(warning).contains("The wall is off") or str(warning).contains("was not tested for places")
	_expect(_error(fast_result, fast) == "" and (passed or said) and _closed(_mesh(fast_result, bracket_body)), "#29 A fast shell should pass its wall check or say what is off (wall %s, crossings %s, warnings %s; %s)." % [str(fast_wall), str(fast_report.get("self_intersections")), str(fast_notes), _error(fast_result, fast)])
	notes.append("#29 fast shell of the bracket: wall %s, warnings %s" % [str(fast_wall), str(fast_notes)])
	# 30. A wall that does not fit: refused before any work, with the thinnest size.
	var slab_doc: Resource = DOCUMENT.new()
	var slab := _add_fixture(slab_doc, FIXTURES.two_cubes(Vector3(0.05, 0, 0)).first, "Slab")
	_tool(slab_doc, "scale", {"bodies": [_pick(slab)], "uniform": false}, {"sx": _num(1), "sy": _num(0.1), "sz": _num(1)})
	var thick := _tool(slab_doc, "shell", {"bodies": [_pick(slab)], "direction": "inside", "algorithm": "accurate"}, {"thickness": _len(1.5 * MM)})
	var slab_result := _rebuild(slab_doc)
	_expect(_error(slab_result, thick) == "A 1.5 mm wall does not fit in Slab (thinnest part about 2 mm).", "#30 A wall too thick for a 2 mm slab should be refused with the thinnest size ('%s')." % _error(slab_result, thick))
	# An open body has no inside.
	var plate_doc: Resource = DOCUMENT.new()
	var plate := _add_fixture(plate_doc, FIXTURES.open_plate(), "Plate")
	var open := _tool(plate_doc, "shell", {"bodies": [_pick(plate)], "direction": "inside", "algorithm": "accurate"}, {"thickness": _len(1 * MM)})
	var open_result := _rebuild(plate_doc)
	_refused(open_result, open, "A shell inside an open body", ["An open body has no inside; use Both, or Close Holes first.", "Plate"])
	checked.append("#28-30 Shell (accurate passes its wall check, fast passes or says what is off, a wall that does not fit, an open body)")


# --- 5.2 #31-33: Combine ---------------------------------------------------------------------

func _check_combine() -> void:
	var cubes := FIXTURES.two_cubes(Vector3(0.01, 0.0, 0.0))
	var volumes := {"join": 12000 * MM3, "cut": 4000 * MM3, "intersect": 4000 * MM3}
	for operation in volumes:
		var doc: Resource = DOCUMENT.new()
		var a := _add_fixture(doc, cubes.first, "A")
		var b := _add_fixture(doc, cubes.second, "B")
		var feature := _tool(doc, "combine", {"target": [_pick(a)], "tools": [_pick(b)], "operation": operation, "keep_tools": false, "new_body": false})
		var result := _rebuild(doc)
		_fine(result, feature, "#31 Combine (%s)" % operation)
		var made := _mesh(result, a)
		_expect(made != null and _closed(made) and absf(float(made.volume()) - float(volumes[operation])) <= 1e-6 * float(volumes[operation]) and not result.bodies.has(b) and result.bodies.size() == 1,
			"#31 Combine (%s) of two cubes 10 mm apart should hold %s mm3 in the target, the tool gone (%s)." % [operation, float(volumes[operation]) / MM3, made.volume() / MM3 if made != null else 0.0])
		if operation == "join":
			_expect(made.get_face_names() == PackedStringArray(["a", "b"]), "#31 A join should keep both bodies' face groups (%s)." % str(made.get_face_names()))
			# Keep Tools and New Body.
			feature.options["keep_tools"] = true
			feature.options["new_body"] = true
			var kept := _rebuild(doc)
			var outputs: Array = feature.options.get("outputs", [])
			_expect(_error(kept, feature) == "" and kept.bodies.size() == 3 and outputs.size() == 1 and doc.body_name(str(outputs[0])) == "A Combined" and absf(float(_mesh(kept, str(outputs[0])).volume()) - 12000 * MM3) < 1e-11
				and is_same(_mesh(kept, a), _mesh(_rebuild(doc), a)) and int(_mesh(kept, a).triangle_count()) == 12 and int(_mesh(kept, b).triangle_count()) == 12,
				"#31 With Keep Tools and New Body the join should be a third body, kept in the feature (%s; %s)." % [str(outputs), _error(kept, feature)])
	# Merge: the triangles put together, no boolean.
	var merge_doc: Resource = DOCUMENT.new()
	var first := _add_fixture(merge_doc, cubes.first, "A")
	var second := _add_fixture(merge_doc, cubes.second, "B")
	var merge := _tool(merge_doc, "combine", {"target": [_pick(first)], "tools": [_pick(second)], "operation": "merge"})
	var merged := _rebuild(merge_doc)
	_fine(merged, merge, "Combine (merge)")
	_expect(int(_mesh(merged, first).triangle_count()) == 24 and not merged.bodies.has(second) and int(_mesh(merged, first).solid_count()) == 2, "Merge should put both cubes' triangles into the target.")
	# A merge of a body that crosses itself is told.
	var crossing := _add_fixture(merge_doc, FIXTURES.self_crossing(), "Pair")
	var far := _add_fixture(merge_doc, FIXTURES.icosphere(0.005, 1, Vector3(0.2, 0, 0)), "Far")
	var crossed := _tool(merge_doc, "combine", {"target": [_pick(far)], "tools": [_pick(crossing)], "operation": "merge"})
	var crossed_result := _rebuild(merge_doc)
	_fine(crossed_result, crossed, "A merge with a body that crosses itself", ["Pair crosses itself, so the result may be wrong there. Rebuild it first."])
	# 32. A B-rep tool: tessellated, with the warning.
	var mixed_doc: Resource = DOCUMENT.new()
	var target := _add_fixture(mixed_doc, cubes.first, "A")
	var box := _add_box(mixed_doc, Vector3(0.02, 0.02, 0.02), Vector3(0.01, 0.0, 0.0))
	var box_name: String = mixed_doc.body_name(box)
	var mixed := _tool(mixed_doc, "combine", {"target": [_pick(target)], "tools": [_pick(box)], "operation": "cut"})
	var mixed_result := _rebuild(mixed_doc)
	_fine(mixed_result, mixed, "#32 Combine with a B-rep tool", ["%s was tessellated for Combine." % box_name])
	# (Both are boxes along the axes: what they share is the overlap of their bounds.)
	var before_volume := float(FIXTURES.to_mesh(cubes.first).volume())
	var shared: AABB = (FIXTURES.to_mesh(cubes.first).bbox() as AABB).intersection(_brep_bounds(mixed_doc, box))
	var box_overlap := shared.size.x * shared.size.y * shared.size.z
	_expect(_mesh(mixed_result, target) != null and _closed(_mesh(mixed_result, target)) and absf(float(_mesh(mixed_result, target).volume()) - (before_volume - box_overlap)) < 1e-10 and not mixed_result.bodies.has(box),
		"#32 A mesh cube cut by a B-rep box should lose their overlap (%s of %s)." % [_mesh(mixed_result, target).volume() if _mesh(mixed_result, target) != null else 0.0, before_volume - box_overlap])
	# 33. An open target, an open tool, a B-rep target, no tool, the target as its own tool.
	var open_doc: Resource = DOCUMENT.new()
	var plate := _add_fixture(open_doc, FIXTURES.open_plate(), "Plate")
	var cube := _add_fixture(open_doc, cubes.first, "A")
	var solid := _add_box(open_doc, Vector3(0.02, 0.02, 0.02), Vector3(0.1, 0.0, 0.0))
	var open_target := _tool(open_doc, "combine", {"target": [_pick(plate)], "tools": [_pick(cube)], "operation": "join", "keep_tools": true})
	var open_tool := _tool(open_doc, "combine", {"target": [_pick(cube)], "tools": [_pick(plate)], "operation": "join", "keep_tools": true})
	var brep_target := _tool(open_doc, "combine", {"target": [_pick(solid)], "tools": [_pick(cube)], "operation": "join", "keep_tools": true})
	var no_tool := _tool(open_doc, "combine", {"target": [_pick(cube)], "tools": [], "operation": "join"})
	var own_tool := _tool(open_doc, "combine", {"target": [_pick(cube)], "tools": [_pick(cube)], "operation": "join"})
	var apart := _tool(open_doc, "combine", {"target": [_pick(cube)], "tools": [_pick(solid)], "operation": "intersect", "keep_tools": true})
	var refusals := _rebuild(open_doc)
	_expect(_error(refusals, open_target).begins_with("Plate is not closed (128 open edges). Close Holes or Wrap it first."), "#33 An open target should be refused with 'is not closed' ('%s')." % _error(refusals, open_target))
	_expect(_error(refusals, open_tool).begins_with("Plate is not closed (128 open edges)"), "#33 An open tool should be refused by its own name ('%s')." % _error(refusals, open_tool))
	_expect(_error(refusals, brep_target) == MESH_FEATURE.NOT_A_MESH % open_doc.body_name(solid), "#33 A B-rep target should be refused ('%s')." % _error(refusals, brep_target))
	_refused(refusals, no_tool, "#33 A Combine with no tool", ["Pick the tool bodies to combine with A."])
	_refused(refusals, own_tool, "#33 A Combine of a body with itself", ["A can't be its own tool"])
	_expect(_error(refusals, apart).contains("The result is empty (the bodies do not overlap).") and _error(refusals, apart).contains("A"), "#33 An intersection of bodies apart should be an error ('%s')." % _error(refusals, apart))
	# A cut that takes all of the target away leaves no body, with the kernel's warning.
	var gone_doc: Resource = DOCUMENT.new()
	var small := _add_fixture(gone_doc, FIXTURES.icosphere(0.005, 2), "Small")
	var big := _add_fixture(gone_doc, cubes.first, "Big")
	var gone := _tool(gone_doc, "combine", {"target": [_pick(small)], "tools": [_pick(big)], "operation": "cut", "keep_tools": true})
	var gone_result := _rebuild(gone_doc)
	_fine(gone_result, gone, "A cut that takes all of the target away", ["The result is empty (the tool bodies cut all of Small away)."])
	_expect(not gone_result.bodies.has(small) and gone_result.bodies.has(big), "A cut that takes all of the target away should leave no target body.")
	checked.append("#31-33 Combine (join, cut and intersect volumes, groups kept, Keep Tools and New Body, Merge with the crossing warning, a B-rep tool tessellated with the warning, open and B-rep bodies refused by name, no tool, an empty intersection, a target cut away)")


## The bounds of a B-rep body of a design, as it is before any Mesh tool takes it.
func _brep_bounds(doc: Resource, body_id: String) -> AABB:
	var alone: Resource = DOCUMENT.new()
	alone.restore(doc.snapshot())
	while alone.features.size() > 0 and str(alone.features[alone.features.size() - 1].type) == "mesh":
		alone.features.remove_at(alone.features.size() - 1)
	return REGEN.rebuild(alone, kernel).bodies[body_id].shape.bbox()


# --- 5.2 #34-35: Smooth ----------------------------------------------------------------------

func _check_smooth() -> void:
	var noisy := FIXTURES.to_mesh(FIXTURES.with_noise(FIXTURES.icosphere(0.05, 4), 0.2))
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, noisy, "Ball")
	var feature := _tool(doc, "smooth", {"bodies": [_pick(body)], "selection": [], "keep_volume": true, "keep_sharp": false, "keep_boundary": true}, {"strength": _num(0.5), "iterations": _num(5)})
	var result := _rebuild(doc)
	var smooth := _mesh(result, body)
	_fine(result, feature, "#34 Smooth with Keep Volume")
	_expect(smooth != null and int(smooth.triangle_count()) == 5120 and absf(float(smooth.volume()) - float(noisy.volume())) <= 0.005 * float(noisy.volume()) and float(smooth.area()) < float(noisy.area())
		and smooth.get_arrays().indices == noisy.get_arrays().indices, "#34 Smooth with Keep Volume should stay within 0.5 %% of the volume and keep every triangle's corners (%s of %s)." % [smooth.volume() if smooth != null else 0.0, noisy.volume()])
	# 35. A selection: every vertex outside it stays, bit for bit.
	var selection: PackedInt32Array = noisy.grow(PackedInt32Array([0]), 6)
	var part_doc: Resource = DOCUMENT.new()
	var part_body := _add_mesh(part_doc, noisy, "Ball")
	var part := _tool(part_doc, "smooth", {"selection": [_triangles(part_body, selection, noisy)], "keep_volume": false}, {"strength": _num(0.5), "iterations": _num(5)})
	var part_result := _rebuild(part_doc)
	var patched := _mesh(part_result, part_body)
	var inside := {}
	var before: Dictionary = noisy.get_arrays()
	for t in selection:
		for k in 3:
			inside[int(before.indices[3 * t + k])] = true
	var after: Dictionary = patched.get_arrays() if patched != null else {"positions": PackedVector3Array(), "indices": PackedInt32Array()}
	var kept: bool = after.indices == before.indices and (after.positions as PackedVector3Array).size() == (before.positions as PackedVector3Array).size()
	var moved := 0
	if kept:
		for i in (before.positions as PackedVector3Array).size():
			var same: bool = var_to_bytes(before.positions[i]) == var_to_bytes(after.positions[i])
			if not inside.has(i) and not same:
				kept = false
			if not same:
				moved += 1
	_expect(_error(part_result, part) == "" and kept and moved > 0, "#35 Smooth of a selection should move vertices inside it only (%d moved; %s)." % [moved, _error(part_result, part)])
	checked.append("#34-35 Smooth (volume kept within 0.5 %, corners kept; a selection moves only its own vertices)")


# --- 5.2 #36: Reverse Normal -------------------------------------------------------------------

func _check_reverse() -> void:
	var doc: Resource = DOCUMENT.new()
	var half := _add_fixture(doc, FIXTURES.flipped_half(), "Ball")
	var hollow_mesh := FIXTURES.to_mesh(FIXTURES.hollow_cube(false))
	var hollow := _add_mesh(doc, hollow_mesh, "Hollow")
	var feature := _tool(doc, "reverse_normal", {"mode": "auto", "bodies": [_pick(half), _pick(hollow)], "selection": []})
	var result := _rebuild(doc)
	var fixed := _mesh(result, half)
	var found: Dictionary = fixed.check(5.0) if fixed != null else {}
	_fine(result, feature, "#36 Reverse Normal (automatic)")
	_expect(bool(found.get("closed", false)) and bool(found.get("oriented", false)) and int(found.get("inverted_components", -1)) == 0 and float(fixed.volume()) > 0.0
		and absf(float(fixed.volume()) - float(FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 3)).volume())) < 1e-12, "#36 Automatic Reverse Normal should turn the flipped half back: one closed part of positive volume (%s)." % str(found))
	_expect(str(_mesh(result, hollow).digest()) == str(hollow_mesh.digest()) and absf(float(_mesh(result, hollow).volume()) - 7000 * MM3) < 1e-12, "#36 Automatic Reverse Normal should change nothing on a correct hollow cube (its void faces inward).")
	# Whole: every triangle turns; the volume changes sign.
	feature.options["mode"] = "whole"
	feature.options["bodies"] = [_pick(hollow)]
	var whole := _rebuild(doc)
	_expect(_error(whole, feature) == "" and absf(float(_mesh(whole, hollow).volume()) + 7000 * MM3) < 1e-12, "Whole-body Reverse Normal should turn the hollow cube inside-out (%s)." % _error(whole, feature))
	# Selection: a face group, or triangles.
	var cubes := FIXTURES.two_cubes(Vector3(0.05, 0, 0))
	var pair_doc: Resource = DOCUMENT.new()
	var pair_mesh := FIXTURES.to_mesh(cubes)
	var pair := _add_mesh(pair_doc, pair_mesh, "Pair")
	# (This pick is by name alone, as an older design holds it: the rebuild takes it, and says
	# that it could not be confirmed. Every other group pick of this test is written with its point
	# and facing, as the panels write them, and builds without that sentence.)
	var by_group := _tool(pair_doc, "reverse_normal", {"mode": "selection", "bodies": [], "selection": [_group(pair, "g1")]})
	var by_group_result := _rebuild(pair_doc)
	_expect(_warning(by_group_result, by_group).contains("%s's pick of face group g1 could not be confirmed (it is kept by name only)" % by_group.label),
		"A face group picked by name alone should be told that it could not be confirmed ('%s')." % _warning(by_group_result, by_group))
	by_group.options["selection"] = [_group(pair, "g1", pair_mesh)]
	_expect(not _warning(_rebuild(pair_doc), by_group).contains("could not be confirmed"), "The same pick with its point and facing should be confirmed ('%s')." % _warning(_rebuild(pair_doc), by_group))
	by_group.options["selection"] = [_group(pair, "g1")]
	# (The kernel says one of a thing in the singular since the fix round.)
	_fine(by_group_result, by_group, "Reverse Normal of a face group", ["Pair: 1 part is inside-out."])
	var turned: Dictionary = _mesh(by_group_result, pair).check(5.0)
	_expect(absf(float(_mesh(by_group_result, pair).volume())) < 1e-10 and int(turned.get("inverted_components", 0)) == 1, "Reversing one cube's group should leave it inside-out (volume %s, %s)." % [_mesh(by_group_result, pair).volume(), str(turned)])
	by_group.options["selection"] = []
	_refused(_rebuild(pair_doc), by_group, "Reverse Normal with nothing picked", ["Select"])
	checked.append("#36 Reverse Normal (automatic fixes the flipped half and leaves a hollow cube, whole body, a face group, nothing picked)")


# --- 5.2 #37: Erase and Fill -------------------------------------------------------------------

func _check_erase_fill() -> void:
	var mesh := FIXTURES.to_mesh(FIXTURES.holed_blob())
	var holes := (mesh.boundary_loops() as Array).size()
	var open := _open_edges(mesh)
	# A patch of triangles that touches no hole, and one that does.
	var clear := PackedInt32Array()
	var touching := PackedInt32Array()
	for seed in range(0, int(mesh.triangle_count()), 97):
		var patch: PackedInt32Array = mesh.grow(PackedInt32Array([seed]), 3)
		var probe: RefCounted = mesh.delete_triangles(patch)
		if probe == null:
			continue
		var merged: int = (mesh.get_last_report().get("merged_loops", PackedInt32Array()) as PackedInt32Array).size()
		if merged == 0 and clear.is_empty():
			clear = patch
		if merged > 0 and touching.is_empty():
			touching = patch
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, mesh, "Blob")
	var feature := _tool(doc, "erase_fill", {"selection": [_triangles(body, clear, mesh)], "fill": "smooth"})
	var result := _rebuild(doc)
	var made := _mesh(result, body)
	_fine(result, feature, "#37 Erase and Fill")
	_expect(not clear.is_empty() and made != null and (made.boundary_loops() as Array).size() == holes and _open_edges(made) == open and _bag_within(_triangle_bag(mesh, PackedInt32Array(), clear), _triangle_bag(made))
		and str(made.digest()) != str(mesh.digest()), "#37 Erase and Fill should close the hole it made and leave the %d old holes and every other triangle (%d loops, %d open edges)." % [holes, (made.boundary_loops() as Array).size() if made != null else -1, _open_edges(made)])
	var stat := str((MESH_FEATURE.reports.get(feature.id, {}) as Dictionary).get("stat", ""))
	_expect(stat == "Erased %d triangles, closed 1 hole" % clear.size(), "#37 The stat line should count what was erased ('%s')." % stat)
	# A selection that reaches an old hole: that hole is filled too, and said.
	feature.options["selection"] = [_triangles(body, touching, mesh)]
	var touched := _rebuild(doc)
	_fine(touched, feature, "Erase and Fill next to a hole", ["The selection touches an open edge of Blob; that hole was filled too."])
	_expect(not touching.is_empty() and (_mesh(touched, body).boundary_loops() as Array).size() < holes, "Erasing next to a hole should fill that hole too.")
	# A face group; everything.
	var cubes := FIXTURES.two_cubes(Vector3(0.05, 0, 0))
	var pair_doc: Resource = DOCUMENT.new()
	var pair_mesh := FIXTURES.to_mesh(cubes)
	var pair := _add_mesh(pair_doc, pair_mesh, "Pair")
	var whole_group := _tool(pair_doc, "erase_fill", {"selection": [_group(pair, "g1", pair_mesh)], "fill": "minimal"})
	var group_result := _rebuild(pair_doc)
	_fine(group_result, whole_group, "Erase and Fill of a whole piece")
	_expect(int(_mesh(group_result, pair).triangle_count()) == 12 and _closed(_mesh(group_result, pair)), "Erasing one of two cubes should leave the other, closed.")
	whole_group.options["selection"] = [_group(pair, "g0"), _group(pair, "g1")]
	_refused(_rebuild(pair_doc), whole_group, "Erasing every triangle", ["Deleting every triangle would leave nothing", "Pair"])
	checked.append("#37 Erase and Fill (the new hole closed, old holes and other triangles untouched, a selection next to a hole warned, a face group, everything refused)")


# --- 5.2 #38: Mesh Align ---------------------------------------------------------------------

func _check_align() -> void:
	var bracket: RefCounted = FIXTURES.l_bracket().mesh
	var turned: RefCounted = bracket.transformed(Transform3D(Basis(Vector3(1, 2, 3).normalized(), 0.7), Vector3(0.011, 0.023, 0.037)))
	var flat := ""
	var round := ""
	for i in int(turned.group_count()):
		var info: Dictionary = turned.face_info(i)
		if bool(info.get("planar", false)) and flat == "":
			flat = str(turned.get_face_names()[i])
		if not bool(info.get("planar", false)):
			round = str(turned.get_face_names()[i])
	var xy := {"kind": "origin", "name": "xy"}
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, turned, "Bracket")
	var feature := _tool(doc, "align", {"source": [_group(body, flat, turned)], "points": [], "to": [xy], "flip": false}, {"offset": _len(0.0)})
	var result := _rebuild(doc)
	var moved := _mesh(result, body)
	_fine(result, feature, "#38 Mesh Align")
	var info: Dictionary = moved.face_info(int(moved.find_face(flat))) if moved != null else {}
	_expect(moved != null and absf((info.point as Vector3).z) <= 1e-9 and ((info.normal as Vector3) + Vector3(0, 0, 1)).length() <= 1e-6 and absf(float(moved.volume()) - float(turned.volume())) < 1e-5 * float(turned.volume()),
		"#38 Mesh Align should put the group's middle on the plane within 1e-9 m, facing it (z %s, normal %s)." % [str((info.get("point", Vector3.ZERO) as Vector3).z), str(info.get("normal"))])
	_expect(is_same(_mesh(_rebuild(doc), body), moved), "#38 A rebuild should give the same aligned mesh back.")
	feature.options["flip"] = true
	feature.set_expression("offset", "5 mm")
	var flipped := _rebuild(doc)
	var flipped_info: Dictionary = _mesh(flipped, body).face_info(int(_mesh(flipped, body).find_face(flat)))
	_expect(_error(flipped, feature) == "" and absf((flipped_info.point as Vector3).z - 0.005) <= 2e-9 and ((flipped_info.normal as Vector3) - Vector3(0, 0, 1)).length() <= 1e-6, "Flip and a 5 mm Offset should face the group the plane's way, 5 mm off it (z %s, normal %s)." % [str((flipped_info.point as Vector3).z), str(flipped_info.normal)])
	# A round group is refused with how far off it is.
	feature.options["source"] = [_group(body, round)]
	_refused(_rebuild(doc), feature, "Mesh Align by a round face group", ["That face group is not flat (off by", "pick a flat group or three points"])
	# Three points on the mesh.
	var corners := PackedVector3Array()
	var arrays: Dictionary = turned.get_arrays()
	var first_triangle := int((turned.group_triangles(int(turned.find_face(flat))) as PackedInt32Array)[0])
	for k in 3:
		corners.append(arrays.positions[int(arrays.indices[3 * first_triangle + k])])
	var picks := []
	for corner in corners:
		picks.append({"kind": "mesh_triangles", "body": body, "triangles": PackedInt32Array([first_triangle]), "digest": str(turned.digest()), "at": corner})
	feature.options["source"] = []
	feature.options["points"] = picks
	feature.options["flip"] = false
	feature.set_expression("offset", "0 mm")
	var by_points := _rebuild(doc)
	var by_points_info: Dictionary = _mesh(by_points, body).face_info(int(_mesh(by_points, body).find_face(flat))) if _error(by_points, feature) == "" else {}
	_expect(_error(by_points, feature) == "" and absf((by_points_info.point as Vector3).z) <= 1e-7 and ((by_points_info.normal as Vector3) + Vector3(0, 0, 1)).length() <= 1e-5,
		"Mesh Align by three points should bring their plane onto the target, facing it (%s; z %s, normal %s)." % [_error(by_points, feature), str((by_points_info.get("point", Vector3.ZERO) as Vector3).z), str(by_points_info.get("normal"))])
	feature.options["points"] = picks.slice(0, 2)
	_refused(_rebuild(doc), feature, "Mesh Align by two points", ["Pick three points on the mesh"])
	feature.options["points"] = []
	_refused(_rebuild(doc), feature, "Mesh Align with nothing picked", ["Pick a flat face group, or three points"])
	checked.append("#38 Mesh Align (the group's middle on the plane within 1e-9 m with the normals opposite, Flip and Offset, a round group refused, three points, too few points)")


# --- 5.2 #39: Texture Extrude ----------------------------------------------------------------

func _check_texture_extrude() -> void:
	var image := FIXTURES.write_png_checker("tools/checker.png", 64)
	var plate := FIXTURES.to_mesh(FIXTURES.open_plate())
	var depth := 1 * MM
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, plate, "Plate")
	var feature := _tool(doc, "texture_extrude", {"selection": [_group(body, "g0", plate)], "image": image, "mapping": "box", "invert": false},
		{"depth": _len(depth), "tile": _len(10 * MM), "angle": _deg(0), "detail": _len(0.625 * MM)})
	var result := _rebuild(doc)
	var made := _mesh(result, body)
	_fine(result, feature, "#39 Texture Extrude")
	var top: float = (made.bbox() as AABB).end.y if made != null else 0.0
	var bottom: float = (made.bbox() as AABB).position.y if made != null else 0.0
	# The plate's outline: every vertex on it is still there, bit for bit, at height 0.
	var border_kept := made != null
	if made != null:
		var after := {}
		for p in (made.get_arrays().positions as PackedVector3Array):
			after[var_to_str(p)] = true
		for loop in plate.boundary_loops():
			for p in (loop.points as PackedVector3Array):
				border_kept = border_kept and after.has(var_to_str(p))
	_expect(made != null and absf(top - depth) <= 0.01 * depth and absf(bottom) < 1e-9 and border_kept and int(made.triangle_count()) > int(plate.triangle_count()) and (made.boundary_loops() as Array).size() == 1,
		"#39 Texture Extrude should raise the plate by the Depth within 1 %% and leave its border as it was (top %s mm, bottom %s mm, border kept %s)." % [top * 1000.0, bottom * 1000.0, border_kept])
	var stat := str((MESH_FEATURE.reports.get(feature.id, {}) as Dictionary).get("stat", ""))
	_expect(stat.begins_with("Largest move: "), "#39 The stat line should give the largest move ('%s')." % stat)
	_expect(is_same(_mesh(_rebuild(doc), body), made), "#39 A rebuild with the same image should give the same mesh back.")
	# Invert, a missing image, no image, a depth of 0.
	feature.options["invert"] = true
	var inverted := _rebuild(doc)
	_expect(_error(inverted, feature) == "" and str(_mesh(inverted, body).digest()) != str(made.digest()), "Invert should give another relief (%s)." % _error(inverted, feature))
	feature.options["image"] = TEMP + "/not_there.png"
	_expect(_error(_rebuild(doc), feature) == "The image not_there.png can't be found.", "A missing image should be named ('%s')." % _error(_rebuild(doc), feature))
	feature.options["image"] = ""
	_refused(_rebuild(doc), feature, "Texture Extrude without an image", ["needs an image"])
	feature.options["image"] = image
	feature.set_expression("depth", "0 mm")
	_refused(_rebuild(doc), feature, "A Depth of 0", ["Depth must not be 0."])
	checked.append("#39 Texture Extrude (the plate raised by the Depth within 1 %, its border bit for bit, the same mesh on a rebuild, Invert, a missing image, a depth of 0)")


# --- 5.2 #40: Separate -----------------------------------------------------------------------

func _check_separate() -> void:
	var doc: Resource = DOCUMENT.new()
	var pair := _add_fixture(doc, FIXTURES.two_cubes(Vector3(0.03, 0.0, 0.0)), "Pair")
	var feature := _tool(doc, "separate", {"bodies": [_pick(pair)], "by": "components"})
	var registered: int = doc.bodies.size()
	var preview := REGEN.rebuild(doc, kernel, {"mesh_time_limit": MESH_FEATURE.PREVIEW_SECONDS})
	_expect(_error(preview, feature) == "" and preview.bodies.size() == 2 and doc.bodies.size() == registered and not feature.options.has("made"), "#40 A preview of Separate should show the pieces and register nothing (%s)." % _error(preview, feature))
	var result := _rebuild(doc)
	var outputs: Array = feature.options.get("outputs", [])
	_fine(result, feature, "#40 Separate")
	_expect(result.bodies.size() == 2 and outputs.size() == 2 and str(outputs[0]) == pair and doc.body_name(str(outputs[1])) == "Pair (2)" and int(_mesh(result, pair).triangle_count()) == 12
		and int(_mesh(result, str(outputs[1])).triangle_count()) == 12 and str(result.bodies[str(outputs[1])].get("kind", "")) == "mesh" and str(result.bodies[str(outputs[1])].feature) == feature.id,
		"#40 Separate should split two cubes into two bodies, the second one new (%s)." % str(outputs))
	# A hollow cube is one piece (its void stays); with an island, two.
	var hollow_doc: Resource = DOCUMENT.new()
	var hollow := _add_fixture(hollow_doc, FIXTURES.hollow_cube(false), "Hollow")
	var island := _add_fixture(hollow_doc, FIXTURES.hollow_cube(true), "Island")
	var one := _tool(hollow_doc, "separate", {"bodies": [_pick(hollow)], "by": "components"})
	var two := _tool(hollow_doc, "separate", {"bodies": [_pick(island)], "by": "components"})
	var hollow_result := _rebuild(hollow_doc)
	_fine(hollow_result, one, "#40 Separate of a hollow cube", ["Hollow is one piece; nothing to separate."])
	_fine(hollow_result, two, "#40 Separate of a hollow cube with an island")
	var island_outputs: Array = two.options.get("outputs", [])
	_expect(hollow_result.bodies.size() == 3 and int(_mesh(hollow_result, hollow).triangle_count()) == 24 and absf(float(_mesh(hollow_result, hollow).volume()) - 7000 * MM3) < 1e-12 and island_outputs.size() == 2
		and int(_mesh(hollow_result, island).triangle_count()) == 24 and absf(float(_mesh(hollow_result, str(island_outputs[1])).volume()) - 64 * MM3) < 1e-13, "#40 A hollow cube should stay one body with its void; an island inside should be a second body.")
	# By face groups.
	feature.options["by"] = "groups"
	var by_groups := _rebuild(doc)
	_expect(_error(by_groups, feature) == "" and by_groups.bodies.size() == 2 and feature.options.get("outputs", []) == outputs, "Separate by face groups should give the two cubes under the same ids (%s)." % _error(by_groups, feature))
	checked.append("#40 Separate (two cubes into two bodies with the new one registered, a preview that registers nothing, a hollow cube as one piece with the warning, an island, by face groups)")


# --- 5.2 #41-42: Move/Copy and Scale Mesh ----------------------------------------------------

func _check_move_scale() -> void:
	var ball := FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 3))
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, ball, "Ball")
	var move := _tool(doc, "move", {"objects": [_pick(body)], "move_type": "free", "copy": false}, {"x": ["1 m", "length"], "y": ["2 m", "length"], "z": ["3 m", "length"]})
	var result := _rebuild(doc)
	var moved := _mesh(result, body)
	var exact := _error(result, move) == "" and moved != null
	if exact:
		var before: PackedVector3Array = ball.get_arrays().positions
		var after: PackedVector3Array = moved.get_arrays().positions
		exact = before.size() == after.size()
		for i in before.size():
			exact = exact and var_to_bytes(after[i]) == var_to_bytes(before[i] + Vector3(1, 2, 3))
	_expect(exact and result.bodies.size() == 1, "#41 Move by (1, 2, 3) m should move every vertex by exactly that (%s)." % _error(result, move))
	move.options["copy"] = true
	var copied := _rebuild(doc)
	var copy_id := UTIL.derived_body_id(body, move.id, 1, [body])
	_expect(_error(copied, move) == "" and copied.bodies.size() == 2 and str(_mesh(copied, body).digest()) == str(ball.digest()) and _mesh(copied, copy_id) != null and str(_mesh(copied, copy_id).digest()) == str(moved.digest()),
		"#41 Create Copy should add a moved body and leave the first (%s)." % str(copied.bodies.keys()))
	# 42. Scale Mesh.
	var scale_doc: Resource = DOCUMENT.new()
	var scaled_body := _add_mesh(scale_doc, ball, "Ball")
	var scale := _tool(scale_doc, "scale", {"bodies": [_pick(scaled_body)], "point": [], "uniform": true}, {"scale": _num(2)})
	var scaled := _rebuild(scale_doc)
	_fine(scaled, scale, "#42 Scale Mesh")
	var volume := float(ball.volume())
	_expect(absf(float(_mesh(scaled, scaled_body).volume()) - 8.0 * volume) <= 1e-6 * 8.0 * volume and ((_mesh(scaled, scaled_body).bbox() as AABB).get_center() - (ball.bbox() as AABB).get_center()).length() < 1e-7,
		"#42 A scale of 2 should give 8 times the volume about the body's middle (%s of %s)." % [_mesh(scaled, scaled_body).volume(), 8.0 * volume])
	scale.options["uniform"] = false
	scale.inputs["sx"] = scale_doc.make_input("2", "number")
	scale.inputs["sy"] = scale_doc.make_input("0.5", "number")
	scale.inputs["sz"] = scale_doc.make_input("3", "number")
	scale.options["point"] = [{"kind": "origin", "name": "o"}]
	var stretched := _rebuild(scale_doc)
	_expect(_error(stretched, scale) == "" and absf(float(_mesh(stretched, scaled_body).volume()) - 3.0 * volume) <= 1e-6 * 3.0 * volume and absf((_mesh(stretched, scaled_body).bbox() as AABB).size.x - 0.2) < 1e-6,
		"#42 Scales of 2, 0.5 and 3 should give 3 times the volume (%s; %s)." % [_mesh(stretched, scaled_body).volume(), _error(stretched, scale)])
	scale.set_expression("sy", "0.0001")
	_expect(_error(_rebuild(scale_doc), scale) == "Y Scale must be between 0.001 and 1000.", "A scale under the range should be refused by its field ('%s')." % _error(_rebuild(scale_doc), scale))
	checked.append("#41-42 Move/Copy (an exact translation, Create Copy) and Scale Mesh (8 times the volume, three factors about a point, the range)")


# --- Direct Edit's snapshot --------------------------------------------------------------------

func _check_direct_edit() -> void:
	var ball := FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 3))
	var patch: PackedInt32Array = ball.grow(PackedInt32Array([0]), 2)
	var edited: RefCounted = ball.delete_triangles(patch)
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, ball, "Ball")
	# As ui/mesh_direct_edit.gd add_snapshot() stores it.
	var piece := FIXTURES.to_mesh(FIXTURES.icosphere(0.005, 1, Vector3(0.1, 0, 0)))
	var made_id: String = ""
	var feature: Resource = doc.add_feature("mesh", "DirectEdit", {}, {
		"method": "direct_edit", "bodies": [_pick(body)], "input_digest": str(ball.digest()), "steps": PackedStringArray(["delete", "extract"]),
		"mesh": MESH_BLOB.from_mesh(edited), "outputs": [],
	})
	made_id = doc.new_body(feature.id)
	feature.options["extract_0"] = MESH_BLOB.from_mesh(piece)
	feature.options["outputs"] = [made_id]
	var result := _rebuild(doc)
	_fine(result, feature, "Direct Edit's snapshot")
	_expect(result.bodies.size() == 2 and str(_mesh(result, body).digest()) == str(edited.digest()) and str(_mesh(result, made_id).digest()) == str(piece.digest()) and str(result.bodies[made_id].feature) == feature.id
		and is_same(_mesh(_rebuild(doc), body), _mesh(result, body)), "Direct Edit should put its stored mesh in the body's place, bring back what it took out, and give the same instances on a rebuild.")
	# An earlier change to the body no longer reaches it: said.
	var earlier := _tool(doc, "scale", {"bodies": [_pick(body)], "uniform": true}, {"scale": _num(2)})
	doc.features.erase(earlier)
	doc.features.insert(1, earlier)
	var replayed := _rebuild(doc)
	_fine(replayed, feature, "Direct Edit after an earlier change", ["%s holds a copy of Ball; changes made to it earlier in the timeline no longer reach it." % feature.label])
	_expect(str(_mesh(replayed, body).digest()) == str(edited.digest()), "Direct Edit should still give its stored mesh.")
	# Every triangle deleted (its own marker, and no stored mesh): the body is gone. A stored mesh
	# that is simply not there is an error (tests/holo_forge_mesh_regress_tools_test.gd). A missing
	# body is an error.
	feature.options.erase("mesh")
	feature.options["emptied"] = true
	var emptied := _rebuild(doc)
	_expect(_error(emptied, feature) == "" and not emptied.bodies.has(body) and emptied.bodies.has(made_id), "A Direct Edit that took every triangle out should leave no body.")
	feature.options["bodies"] = [_pick("body99")]
	_refused(_rebuild(doc), feature, "Direct Edit of a body that is gone", ["no longer exists"])
	checked.append("Direct Edit (the stored mesh replaces the body, extracted bodies come back, the same instances on a rebuild, an earlier change warned, an emptied body, a body that is gone)")


# --- 5.2 #43: the gate -------------------------------------------------------------------------

func _check_gate() -> void:
	var doc: Resource = DOCUMENT.new()
	var body := _add_fixture(doc, FIXTURES.two_cubes(Vector3(0.05, 0, 0)).first, "Cube")
	var fillet: Resource = doc.add_feature("fillet", "Fillet", {"radius": doc.make_input("1 mm", "length")}, {"edges": [{"kind": "edge", "body": body, "name": "e0"}]})
	var result := _rebuild(doc)
	_expect(_error(result, fillet) == GATE_TEXT % "Cube", "#43 Solid Fillet on a mesh body should be refused with exactly the gate sentence ('%s')." % _error(result, fillet))
	# A Mesh tool on a B-rep body, on a body that is gone, with nothing picked; an unknown tool.
	var box := _add_box(doc, Vector3(0.02, 0.02, 0.02), Vector3(0.1, 0, 0))
	var on_brep := _tool(doc, "smooth", {"bodies": [_pick(box)]})
	var on_gone := _tool(doc, "reduce", {"bodies": [_pick("body42")]})
	var on_nothing := _tool(doc, "shell", {"bodies": []})
	var unknown := _tool(doc, "polish", {"bodies": [_pick(body)]})
	var refusals := _rebuild(doc)
	_expect(_error(refusals, on_brep) == "%s is not a mesh body. Tessellate it first (Mesh > Create > Tessellate)." % doc.body_name(box), "A Mesh tool on a B-rep body should say to tessellate it ('%s')." % _error(refusals, on_brep))
	_refused(refusals, on_gone, "A Mesh tool on a body that is gone", ["no longer exists"])
	_expect(_error(refusals, on_nothing) == "Select a mesh body", "A Mesh tool with nothing picked should ask for a body ('%s')." % _error(refusals, on_nothing))
	_expect(_error(refusals, unknown) == "The Mesh tool 'polish' is not available in this build", "An unknown Mesh tool should say so ('%s')." % _error(refusals, unknown))
	if not ResourceLoader.exists(MESH_FEATURE.CONVERT_PATH):
		var convert := _tool(doc, "convert_faceted", {"bodies": [_pick(body)]})
		_expect(_error(_rebuild(doc), convert) == "The Mesh tool 'convert_faceted' is not available in this build", "Convert Mesh without its file should say it is not in the build.")
		notes.append("core/features/mesh_convert.gd is not in this build: the convert_* methods answer 'not available in this build'.")
	checked.append("#43 the gate (Solid Fillet on a mesh body refused with the gate sentence; a Mesh tool on a B-rep body, a missing body, nothing picked, an unknown tool)")


# --- 5.2 #44: every range, from the panels' own specs ----------------------------------------

## A range bound of a spec field in the field's own writing (meters, degrees, a plain number):
## a number, or "[-]name[op number]" with name D, T or another field of the tool.
func _bound(text: Variant, known: Dictionary) -> float:
	if text is float or text is int:
		return float(text)
	var formula := str(text).strip_edges()
	if formula.is_valid_float():
		return formula.to_float()
	var sign := 1.0
	if formula.begins_with("-"):
		sign = -1.0
		formula = formula.substr(1)
	var at := -1
	for i in range(1, formula.length()):
		if formula[i] in ["*", "/", "+", "-"]:
			at = i
			break
	var name := formula if at < 0 else formula.substr(0, at)
	if not known.has(name):
		return NAN
	var base := float(known[name])
	if at < 0:
		return sign * base
	var number := formula.substr(at + 1).to_float()
	match formula[at]:
		"*":
			return sign * base * number
		"/":
			return sign * base / number
		"+":
			return sign * base + number
	return sign * base - number


func _written(value: float, kind: String) -> Array:
	match kind:
		"length":
			return ["%s mm" % String.num(value * 1000.0, 12), "length"]
		"angle":
			return [String.num(value, 9), "angle"]
	return [String.num(value, 9), "number"]


func _check_ranges() -> void:
	var image := FIXTURES.write_png_checker("tools/range_checker.png", 64)
	var ball := FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 3))
	var blob := FIXTURES.to_mesh(FIXTURES.holed_blob())
	var plate := FIXTURES.to_mesh(FIXTURES.open_plate())
	var xy := {"kind": "origin", "name": "xy"}
	var tested := 0
	var fields_tested := 0
	for key in SPECS.keys():
		if not str(key).begins_with("mesh:") or str(key).begins_with("mesh:convert_"):
			continue
		var spec: Dictionary = SPECS.get_spec(key)
		var method := str(spec.get("method", ""))
		for field in spec.fields:
			if str(field.get("type", "")) != "expression" or not field.has("range"):
				continue
			var kind := str(field.get("kind", "length"))
			var label := str(field.label).get_slice(" (", 0)
			fields_tested += 1
			# The body the tool works on, and what the bounds may hang on.
			var source: RefCounted = blob if method == "close_holes" else plate if method == "texture_extrude" else ball
			var size: float = (source.bbox() as AABB).size.length()
			var known := {"D": size, "T": float(source.triangle_count())}
			if method == "tessellate":
				known["D"] = Vector3(0.02, 0.02, 0.02).length()
			# Fields a bound names get a value of their own, so the bound is known.
			var fixed := {}
			match method:
				"wrap":
					fixed = {"detail": size / 100.0, "gap": size / 50.0}
				"shell":
					fixed = {"thickness": size / 50.0}
				"texture_extrude":
					fixed = {"tile": size / 5.0}
				"remesh":
					fixed = {"min_edge": size / 1000.0, "max_edge": size / 50.0}
			fixed.erase(str(field.key))
			for name in fixed:
				known[name] = fixed[name]
			var low := _bound(field.range[0], known)
			var high := _bound(field.range[1], known)
			_expect(not is_nan(low) and not is_nan(high), "The range of %s %s should be known (%s)." % [key, field.key, str(field.range)])
			var whole := bool(field.get("whole", false))
			var outside := []
			if whole:
				outside = [low - 1.0, high + 1.0, low + 0.5]
			else:
				outside.append(low - maxf(absf(low) * 1e-3, 1e-7 if kind == "length" else 1e-3))
				outside.append(high + maxf(absf(high) * 1e-3, 1e-7 if kind == "length" else 1e-3))
				if bool(field.get("gt", false)):
					outside.append(low)
			if bool(field.get("not_zero", false)):
				outside.append(0.0)
			for value in outside:
				var doc: Resource = DOCUMENT.new()
				var options := {}
				if method == "tessellate":
					options["bodies"] = [_pick(_add_box(doc, Vector3(0.02, 0.02, 0.02), Vector3.ZERO))]
				else:
					var body := _add_mesh(doc, source, "Part")
					match method:
						"section_sketch":
							options = {"body": [_pick(body)], "plane": [xy]}
						"plane_cut":
							options = {"bodies": [_pick(body)], "plane": [xy]}
						"texture_extrude":
							options = {"selection": [_group(body, "g0")], "image": image}
						_:
							options = {"bodies": [_pick(body)]}
				# The choices that show the field.
				var shown: Dictionary = field.get("visible_if", {})
				for choice in shown:
					options[choice] = (shown[choice] as Array)[0]
				var inputs := {}
				for name in fixed:
					inputs[name] = _written(float(fixed[name]), "length")
				inputs[str(field.key)] = _written(float(value), kind)
				var feature := _tool(doc, method, options, inputs)
				var error := _error(_rebuild(doc), feature)
				tested += 1
				_expect(error != "" and error.contains(label), "#44 %s: %s = %s (range %s to %s) should be refused with the field's name ('%s')." % [key, field.key, String.num(float(value), 9), String.num(low, 9), String.num(high, 9), error])
	_expect(fields_tested >= 36, "#44 Every ranged field of the mesh specs should be tested (%d)." % fields_tested)
	checked.append("#44 range refusals (%d values just outside the ranges of %d fields of the panels' specs, each refused with the field's name)" % [tested, fields_tested])


# --- What every tool keeps to ------------------------------------------------------------------

func _check_rules() -> void:
	var ball := FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 4))
	var xy := {"kind": "origin", "name": "xy"}
	# An earlier feature edited: the mesh tools after it replay on the new body.
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, ball, "Ball")
	var scale := _tool(doc, "scale", {"bodies": [_pick(body)], "uniform": true}, {"scale": _num(1)})
	var reduce := _tool(doc, "reduce", {"bodies": [_pick(body)], "target": "proportion", "algorithm": "fast"}, {"proportion": _num(50)})
	var cut := _tool(doc, "plane_cut", {"bodies": [_pick(body)], "plane": [xy], "type": "split_body", "fill": "minimal"}, {"offset": _len(3 * MM)})
	var first := _rebuild(doc)
	var first_digests := _digests(first)
	var first_volume := 0.0
	for id in first.bodies:
		first_volume += float(first.bodies[id].shape.volume())
	_expect(first.errors.is_empty() and first.bodies.size() == 2, "A design of Scale, Reduce and Plane Cut should build (%s)." % str(first.errors))
	var before_edit: Dictionary = doc.snapshot()
	scale.set_expression("scale", "2")
	var edited := _rebuild(doc)
	var edited_volume := 0.0
	for id in edited.bodies:
		edited_volume += float(edited.bodies[id].shape.volume())
	var other := str(cut.options.outputs[1])
	_expect(edited.errors.is_empty() and edited.bodies.keys() == first.bodies.keys() and absf(edited_volume - 8.0 * first_volume) < 1e-5 * 8.0 * first_volume and _digests(edited) != first_digests
		and str(edited.bodies[other].feature) == cut.id and str(edited.bodies[body].feature) == cut.id and _closed(_mesh(edited, body)) and _closed(_mesh(edited, other)),
		"Editing an earlier Scale should replay Reduce and Plane Cut on the larger body (volume %s, was %s; %s)." % [edited_volume, first_volume, str(edited.errors)])
	# Undo and redo: the design put back gives the same bodies, by content.
	var after_edit: Dictionary = doc.snapshot()
	var edited_digests := _digests(edited)
	doc.restore(before_edit)
	_expect(_digests(_rebuild(doc)) == first_digests, "Undo should give the bodies as they were (by content).")
	doc.restore(after_edit)
	_expect(_digests(_rebuild(doc)) == edited_digests, "Redo should give the edited bodies again (by content).")
	MESH_FEATURE.clear_cache()
	_expect(_digests(_rebuild(doc)) == edited_digests, "A rebuild from nothing kept should give the same bodies too (by content).")
	# A tool that adds bodies: fewer than before, with the same settings, is said; edited, it counts afresh.
	var pair_doc: Resource = DOCUMENT.new()
	var pair := _add_fixture(pair_doc, FIXTURES.two_cubes(Vector3(0.03, 0, 0)), "Pair")
	var separate := _tool(pair_doc, "separate", {"bodies": [_pick(pair)], "by": "components"})
	var two := _rebuild(pair_doc)
	var made: Array = (separate.options.get("outputs", []) as Array).duplicate()
	var source: Resource = pair_doc.features[0]
	var both: Resource = source.options.mesh
	source.options["mesh"] = MESH_BLOB.from_mesh(FIXTURES.to_mesh(FIXTURES.two_cubes(Vector3(0.03, 0, 0)).first))
	var one := _rebuild(pair_doc)
	_fine(one, separate, "Separate after its body lost a piece", ["Pair is one piece; nothing to separate.", "%s now makes 1 body instead of 2." % separate.label])
	_expect(two.bodies.size() == 2 and one.bodies.size() == 1 and not one.bodies.has(str(made[1])), "A Separate whose body lost a piece should make one body.")
	source.options["mesh"] = both
	var back := _rebuild(pair_doc)
	_expect(_warning(back, separate) == "" and separate.options.get("outputs", []) == made and back.bodies.has(str(made[1])), "With the piece back, Separate should make its two bodies under the same ids, with no warning ('%s')." % _warning(back, separate))
	separate.options["by"] = "groups"
	source.options["mesh"] = MESH_BLOB.from_mesh(FIXTURES.to_mesh(FIXTURES.two_cubes(Vector3(0.03, 0, 0)).first))
	var afresh := _rebuild(pair_doc)
	_fine(afresh, separate, "An edited Separate", ["Pair is one piece; nothing to separate."])
	# A preview (half a second) that is refused for time says so in the kernel's words, by name.
	var big_doc: Resource = DOCUMENT.new()
	var big := _add_mesh(big_doc, FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 5)), "Ball")
	var slow := _tool(big_doc, "remesh", {"bodies": [_pick(big)], "mode": "uniform"}, {"edge_length": _len(0.6 * MM), "iterations": _num(10)})
	var preview := REGEN.rebuild(big_doc, kernel, {"mesh_time_limit": MESH_FEATURE.PREVIEW_SECONDS})
	_expect(_error(preview, slow).begins_with("Ball: Remesh would take about") and _error(preview, slow).contains("(limit 0.5 s)") and MESH_FEATURE.is_time_refusal(_error(preview, slow)),
		"A Remesh that does not fit a preview should say how long it would take, by name ('%s')." % _error(preview, slow))
	_expect(not MESH_FEATURE.reports.has(slow.id), "A feature that failed should publish no report.")
	# One time limit for the whole feature: the second body gets what the first left of it.
	var first_ball := FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 4))
	var second_ball := FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 4, Vector3(0.2, 0, 0)))
	var estimate := float((first_ball.op_defaults("rebuild", {"detail": 1 * MM}) as Dictionary).get("seconds", 0.0))
	var shared_doc: Resource = DOCUMENT.new()
	var one_id := _add_mesh(shared_doc, first_ball, "One")
	var two_id := _add_mesh(shared_doc, second_ball, "Two")
	var shared := _tool(shared_doc, "rebuild", {"bodies": [_pick(one_id), _pick(two_id)], "algorithm": "union"}, {"detail": _len(1 * MM)})
	var limit := estimate + 0.2
	MESH_FEATURE.clear_cache()
	var started := Time.get_ticks_usec()
	var shared_result := REGEN.rebuild(shared_doc, kernel, {"mesh_time_limit": limit})
	var took := (Time.get_ticks_usec() - started) / 1e6
	var shared_error := _error(shared_result, shared)
	_expect(estimate > 0.5 and shared_error.begins_with("Two: Rebuild would take about") and MESH_FEATURE.is_time_refusal(shared_error) and shared_error.ends_with("pick fewer bodies at once.)") and took < limit + 1.0
		and str(_mesh(shared_result, one_id).digest()) == str(first_ball.digest()) and str(_mesh(shared_result, two_id).digest()) == str(second_ball.digest()),
		"A tool on two bodies should give the second what the first left of the time limit, and change nothing when it does not fit (estimate %.2f s, limit %.2f s, took %.2f s; '%s')." % [estimate, limit, took, shared_error])
	notes.append("shared time limit: estimate %.2f s a body, limit %.2f s, the feature took %.2f s: '%s'" % [estimate, limit, took, shared_error])
	# Names: the token never shows, short names are not mistaken for words.
	_expect(MESH_FEATURE.named("{body} is not closed.", "A") == "A is not closed." and MESH_FEATURE.named("The mesh has 3 non-manifold edges.", "Part") == "Part has 3 non-manifold edges."
		and MESH_FEATURE.named("Depth must not be 0.", "A") == "A: Depth must not be 0." and MESH_FEATURE.named("Plate is not closed.", "A", PackedStringArray(["Plate"])) == "Plate is not closed."
		and MESH_FEATURE.named("About 3 % of Part is not inside the wrap.", "Part") == "About 3 % of Part is not inside the wrap.", "named() should put the body's name into every sentence once.")
	checked.append("rules (an earlier edit replays the mesh tools, undo and redo give the same bodies by content, fewer bodies than before warned and counted afresh after an edit, a preview's time refusal by name, one time limit shared by a tool's bodies, body names in sentences)")


# --- 5.2 #45: the cache ------------------------------------------------------------------------

func _check_cache() -> void:
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 5)), "Ball")
	_tool(doc, "reduce", {"bodies": [_pick(body)], "target": "proportion", "algorithm": "adaptive"}, {"proportion": _num(50)})
	_tool(doc, "smooth", {"bodies": [_pick(body)], "keep_volume": true}, {"strength": _num(0.3), "iterations": _num(3)})
	_tool(doc, "plane_cut", {"bodies": [_pick(body)], "plane": [{"kind": "origin", "name": "xy"}], "type": "split_body", "fill": "uniform"}, {"offset": _len(3 * MM)})
	_tool(doc, "shell", {"bodies": [_pick(body)], "direction": "inside", "algorithm": "accurate"}, {"thickness": _len(2 * MM)})
	MESH_FEATURE.clear_cache()
	var started := Time.get_ticks_usec()
	var first := _rebuild(doc)
	var first_ms := (Time.get_ticks_usec() - started) / 1000.0
	started = Time.get_ticks_usec()
	var second := _rebuild(doc)
	var second_ms := (Time.get_ticks_usec() - started) / 1000.0
	var same: bool = first.errors.is_empty() and second.errors.is_empty() and first.bodies.size() == 2 and second.bodies.keys() == first.bodies.keys()
	for id in first.bodies:
		same = same and second.bodies.has(id) and is_same(first.bodies[id].shape, second.bodies[id].shape)
	# (Measured: 4,570 to 4,670 ms, then 7 to 9.5 ms: 0.15 to 0.2 % of the first.)
	_expect(same and second_ms < 0.1 * first_ms, "#45 A second rebuild should take under 10 %% of the first and give the very same meshes (%.1f ms, then %.1f ms; same %s; %s)." % [first_ms, second_ms, same, str(first.errors)])
	notes.append("#45 first rebuild %.1f ms, second %.1f ms (%.2f %%)" % [first_ms, second_ms, 100.0 * second_ms / maxf(first_ms, 1e-6)])
	checked.append("#45 the cache (a second rebuild under 10 % of the first, the same instances)")


# --- 5.2 #20, #47, #48: a body of a million triangles ------------------------------------------

func _check_large() -> void:
	var grid := FIXTURES.to_mesh(FIXTURES.large_grid(290))
	var count := int(grid.triangle_count())
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, grid, "Grid")
	var remesh := _tool(doc, "remesh", {"bodies": [_pick(body)], "mode": "uniform"}, {"density": _num(1), "iterations": _num(10), "sharp_angle": _deg(45)})
	var smooth := _tool(doc, "smooth", {"bodies": [_pick(body)], "keep_volume": true}, {"strength": _num(0.5), "iterations": _num(5)})
	var reduce := _tool(doc, "reduce", {"bodies": [_pick(body)], "target": "proportion", "algorithm": "adaptive"}, {"proportion": _num(50)})
	var result := _rebuild(doc)
	_expect(_error(result, remesh).begins_with("Grid: Remesh would") and (_error(result, remesh).contains("would make about") or _error(result, remesh).contains("would take about")),
		"#20 Remesh at Density 1 on a million triangles should be refused before any work ('%s')." % _error(result, remesh))
	_expect(_error(result, smooth).begins_with("Grid: Smooth would take about") and _error(result, smooth).contains("Lower Passes, smooth a selection, or Reduce the body first."), "#47 Whole-body Smooth on a million triangles should be refused with 'would take about' ('%s')." % _error(result, smooth))
	_expect(_error(result, reduce).begins_with("Grid: Reduce would take about") and _error(result, reduce).contains("Use the Fast method"), "#48 Adaptive Reduce on a million triangles should be refused with what to do ('%s')." % _error(result, reduce))
	_expect(_mesh(result, body) != null and int(_mesh(result, body).triangle_count()) == count, "A refused tool should leave the body as it was.")
	# Refused before any work: each handler alone, asked something new every time (so nothing is
	# answered from the cache), against a calibration.
	# (The limits and what was measured: REFUSAL_RATIOS.)
	var ctx := _ctx(doc, result)
	var step := [0]
	for item in [[remesh, "sharp_angle", "45.%06d", "#20 Remesh"], [smooth, "strength", "0.5%06d", "#47 Smooth"], [reduce, "proportion", "50.%06d", "#48 Adaptive Reduce"]]:
		var feature: Resource = item[0]
		var timed := TIMING.compare(func() -> void:
			step[0] += 1
			feature.set_expression(str(item[1]), str(item[2]) % step[0])
			ctx.values = PARAMETERS.evaluate(doc)
			var error: String = MESH_FEATURE.build(feature, ctx)
			if error == "":
				step[0] = -1000000, _calibration, 5, str(item[3]))
		_expect(step[0] > 0 and float(timed.ratio) < float(REFUSAL_RATIOS[str(item[3])]), "%s on a million triangles should be refused before any work (ratio %.3f, limit %.3f: %.2f ms against %.2f ms)." % [item[3], timed.ratio, float(REFUSAL_RATIOS[str(item[3])]), timed.op, timed.calibration])
		notes.append("%s refusal: %.2f ms against %.2f ms, ratio %.3f" % [item[3], timed.op, timed.calibration, timed.ratio])
	# 48. The Fast method works on the same body, within 2 %.
	var fast_doc: Resource = DOCUMENT.new()
	var fast_body := _add_mesh(fast_doc, grid, "Grid")
	var fast := _tool(fast_doc, "reduce", {"bodies": [_pick(fast_body)], "target": "proportion", "algorithm": "fast", "keep_groups": true}, {"proportion": _num(50)})
	var fast_result := _rebuild(fast_doc)
	var reduced := _mesh(fast_result, fast_body)
	_expect(_error(fast_result, fast) == "" and reduced != null and absi(int(reduced.triangle_count()) - count / 2) <= int(0.02 * count / 2.0) and _open_edges(reduced) == 0,
		"#48 Fast Reduce to 50 %% should work on a million triangles, within 2 %% (%d of %d; %s)." % [int(reduced.triangle_count()) if reduced != null else -1, count / 2, _error(fast_result, fast)])
	notes.append("#48 fast Reduce of %d triangles: warnings %s" % [count, str((MESH_FEATURE.reports.get(fast.id, {}) as Dictionary).get("warnings", []))])
	checked.append("#20, #47, #48 a million triangles (Remesh, whole-body Smooth and Adaptive Reduce refused before any work, by ratio; Fast Reduce within 2 %)")
