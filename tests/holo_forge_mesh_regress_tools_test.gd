extends SceneTree
## Holo Forge Mesh tools, regressions from the adversarial sweep of Phase 7 (the tool wiring:
## core/features/mesh.gd and the mesh-body path of core/features/insert.gd), through features and
## the rebuild. Each case is a finding that was wrong before its fix:
##   F1  Tessellate gave a body the kept result of another body with the same shape: the face
##       group names were the other body's.
##   F2  A Direct Edit whose stored mesh is gone from disk deleted the body with no error.
##   P3  Erase and Fill left a hole open and said it closed it.
##   S   Stale picks: a pick with no record of its body's version, and a stale selection behind a
##       refusal, said nothing.
##   P7  "The bodies before it used the rest…" on a single body.
##   X   A body that crosses itself: said by name for Combine, Shell and Texture Extrude, once.
##   R   Separate's report had no triangle counts.
##   W   Insert Mesh dropped the readers' warnings; a linked mesh body over the Faceted cap
##       switched to a solid gave two false sentences.
##   C   The cache: a refusal by time answers the next rebuild at once; a result made in a
##       preview's half second is not what a full-time rebuild gets.
##   G   A face group pick follows its face when an earlier change renumbers the groups (or the
##       feature fails saying so); it never acts on the face that now has the old name.
##   L   A linked file whose content changed under the same modified time is read again.
##   O   Close Holes and the outline of an open sheet: with no hole picked the outline stays open
##       and the holes are closed; a picked outline is closed, with a warning; Erase and Fill at a
##       sheet's border leaves the outline open.
##   K   An option of the wrong kind is the feature's error with a sentence, never a script error;
##       a damaged stored mesh says what to do next.
##   N   After the kernel's own fix round: a Wrap of several bodies names the body it left out;
##       an op that hands the same mesh back ("nothing to do") leaves the body with its warning;
##       a Tessellate of several bodies names the body a warning is about.
##
## godot --headless --path . --script res://tests/holo_forge_mesh_regress_tools_test.gd

const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const INSERT := preload("res://addons/holo_forge/core/features/insert.gd")
const MESH_FEATURE := preload("res://addons/holo_forge/core/features/mesh.gd")
const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")
const MESH_BLOB := preload("res://addons/holo_forge/core/mesh/mesh_blob.gd")
const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const FIXTURES := preload("res://tests/holo_forge_mesh_fixtures.gd")

const MM := 0.001
const TEMP := "user://holo_forge_mesh_fixtures/regress_tools"
const CROSSES := "%s crosses itself, so the result may be wrong there. Rebuild it first."

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
		print("NOTE holo_forge_mesh_regress_tools: CadMesh is not in this build; the checks are skipped.")
	elif kernel != null:
		_remove_folder(TEMP)
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEMP))
		MESH_FEATURE.clear_cache()
		var only := OS.get_environment("HOLO_FORGE_MESH_TOOLS_ONLY")
		for part in [["names", _check_tessellate_names], ["stored", _check_direct_edit_stored], ["erase", _check_erase_fill], ["stale", _check_stale_picks],
				["time", _check_time_sentence], ["crossing", _check_crossing_notes], ["report", _check_separate_report], ["readers", _check_reader_warnings],
				["cache", _check_cache], ["kernel", _check_kernel_round], ["groups", _check_group_picks], ["linked", _check_linked_stamp], ["outline", _check_outline], ["kinds", _check_option_kinds]]:
			if only == "" or only.split(",").has(str(part[0])):
				(part[1] as Callable).call()
		_remove_folder(TEMP)
	for note in notes:
		print("NOTE holo_forge_mesh_regress_tools: " + note)
	if failures.is_empty():
		print("PASS holo_forge_mesh_regress_tools: " + "; ".join(checked) + ".")
	else:
		print("FAIL holo_forge_mesh_regress_tools")
		for failure in failures:
			print("  " + failure)
	quit(0 if failures.is_empty() else 1)


# --- Helpers ---------------------------------------------------------------------------------

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


func _add_box(doc: Resource, size: Vector3, position: Vector3) -> String:
	var feature: Resource = doc.add_feature("box", "Box", {
		"length": doc.make_input("%f m" % size.x, "length"), "height": doc.make_input("%f m" % size.y, "length"),
		"width": doc.make_input("%f m" % size.z, "length"),
	}, {"operation": OPERATIONS.NEW_BODY, "position": position})
	feature.options.body_id = doc.new_body(feature.id)
	return str(feature.options.body_id)


func _tool(doc: Resource, method: String, options := {}, inputs := {}) -> Resource:
	var made := {}
	for key in inputs:
		made[key] = doc.make_input(str(inputs[key][0]), str(inputs[key][1]))
	var settings := {"method": method}
	settings.merge(options)
	return doc.add_feature("mesh", method.capitalize().replace(" ", ""), made, settings)


func _pick(body_id: String) -> Dictionary:
	return {"kind": "body", "body": body_id}


func _group(body_id: String, group: String) -> Dictionary:
	return {"kind": "mesh_group", "body": body_id, "group": group}


func _triangles(body_id: String, triangles: PackedInt32Array, mesh: RefCounted) -> Dictionary:
	return {"kind": "mesh_triangles", "body": body_id, "triangles": triangles, "digest": str(mesh.digest())}


func _rebuild(doc: Resource, limit := 20.0) -> Dictionary:
	return REGEN.rebuild(doc, kernel, {"mesh_time_limit": limit})


func _mesh(result: Dictionary, body_id: String) -> RefCounted:
	var entry: Dictionary = result.bodies.get(body_id, {})
	return entry.get("shape") if MESH_BODY.is_mesh(entry) else null


func _error(result: Dictionary, feature: Resource) -> String:
	return str(result.errors.get(feature.id, ""))


func _warning(result: Dictionary, feature: Resource) -> String:
	return str(result.warnings.get(feature.id, ""))


func _report(feature: Resource) -> Dictionary:
	return MESH_FEATURE.reports.get(feature.id, {})


func _warnings(feature: Resource) -> Array:
	return _report(feature).get("warnings", [])


func _stat(feature: Resource) -> String:
	return str(_report(feature).get("stat", ""))


func _open_edges(mesh: RefCounted) -> int:
	return int((mesh.check(5.0) as Dictionary).get("boundary_edges", -1)) if mesh != null else -1


## How many of the warnings hold every one of the fragments.
func _count_with(warnings: Array, fragments: Array) -> int:
	var count := 0
	for warning in warnings:
		var all := true
		for fragment in fragments:
			all = all and str(warning).contains(str(fragment))
		count += 1 if all else 0
	return count


## A fixture's triangles whose middle passes a test, as triangle ids of its mesh.
func _where(mesh: RefCounted, test: Callable) -> PackedInt32Array:
	var arrays: Dictionary = mesh.get_arrays()
	var positions: PackedVector3Array = arrays.positions
	var indices: PackedInt32Array = arrays.indices
	var out := PackedInt32Array()
	for t in indices.size() / 3:
		if test.call((positions[indices[3 * t]] + positions[indices[3 * t + 1]] + positions[indices[3 * t + 2]]) / 3.0):
			out.append(t)
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


# --- F1: Tessellate's face group names are the body's own ------------------------------------

func _check_tessellate_names() -> void:
	var doc: Resource = DOCUMENT.new()
	var first_box := _add_box(doc, Vector3(0.02, 0.02, 0.02), Vector3.ZERO)
	var first: Dictionary = MESH_FEATURE.add_tessellate(doc, [first_box])
	var one := _rebuild(doc)
	var first_names: PackedStringArray = _mesh(one, str(first.bodies[0])).get_face_names()
	# Both features deleted, the same box and Tessellate made again: other face names, same shape.
	doc.remove_feature(first.feature.id)
	doc.remove_feature(doc.features[0].id)
	var second_box := _add_box(doc, Vector3(0.02, 0.02, 0.02), Vector3.ZERO)
	var second: Dictionary = MESH_FEATURE.add_tessellate(doc, [second_box])
	var two := _rebuild(doc)
	var made := _mesh(two, str(second.bodies[0]))
	var wanted := PackedStringArray()
	for face in two.bodies[second_box].shape.get_face_names():
		wanted.append(made.group_name_for(face) if made != null else "")
	_expect(made != null and made.get_face_names() == wanted and made.get_face_names() != first_names,
		"F1 A box made again and tessellated should have its own faces' names as face groups (%s; the box's faces %s; the first box's %s)." % [str(made.get_face_names()) if made != null else "none", str(wanted), str(first_names)])
	# A pick by one of those names holds after the cache is gone (a new session).
	var cut := _tool(doc, "plane_cut", {"bodies": [_pick(str(second.bodies[0]))], "plane": [_group(str(second.bodies[0]), wanted[2])], "type": "trim", "fill": "uniform"}, {"offset": ["-5 mm", "length"]})
	var now := _rebuild(doc)
	MESH_FEATURE.clear_cache()
	var later := _rebuild(doc)
	_expect(_error(now, cut) == "" and _error(later, cut) == "" and str(_mesh(now, str(second.bodies[0])).digest()) == str(_mesh(later, str(second.bodies[0])).digest()),
		"F1 A Plane Cut by one of the body's face groups should build now and after the cache is gone ('%s', '%s')." % [_error(now, cut), _error(later, cut)])
	checked.append("F1 Tessellate (a body's face groups carry its own faces' names, whatever was tessellated before; a pick by name holds in a new session)")


# --- F2: a Direct Edit whose stored mesh is gone ------------------------------------------------

func _direct_edit(doc: Resource, body: String, input: RefCounted, edited: RefCounted, piece: RefCounted) -> Resource:
	var feature: Resource = doc.add_feature("mesh", "DirectEdit", {}, {
		"method": "direct_edit", "bodies": [_pick(body)], "input_digest": str(input.digest()), "steps": PackedStringArray(["delete", "extract"]),
		"mesh": MESH_BLOB.from_mesh(edited), "outputs": [],
	})
	var made: String = doc.new_body(feature.id)
	feature.options["extract_0"] = MESH_BLOB.from_mesh(piece)
	feature.options["outputs"] = [made]
	return feature


func _check_direct_edit_stored() -> void:
	var ball := FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 3))
	var edited: RefCounted = ball.delete_triangles(ball.grow(PackedInt32Array([0]), 2))
	var piece := FIXTURES.to_mesh(FIXTURES.icosphere(0.005, 1, Vector3(0.1, 0, 0)))
	# What a stored mesh that could not be loaded leaves in the feature: the key, with nothing.
	for key in ["mesh", "extract_0"]:
		var doc: Resource = DOCUMENT.new()
		var body := _add_mesh(doc, ball, "Ball")
		var feature := _direct_edit(doc, body, ball, edited, piece)
		feature.options[key] = null
		var result := _rebuild(doc)
		var error := _error(result, feature)
		_expect(error != "" and error.contains(feature.label) and error.contains("stored mesh") and _mesh(result, body) != null and str(_mesh(result, body).digest()) == str(ball.digest())
			and not result.bodies.has(str(feature.options.outputs[0])), "F2 A Direct Edit whose stored %s is gone should be an error, and leave the body as it was ('%s'; body %s)." % [key, error, "there" if result.bodies.has(body) else "gone"])
	# "Every triangle was taken out" has its own marker.
	var gone_doc: Resource = DOCUMENT.new()
	var gone_body := _add_mesh(gone_doc, ball, "Ball")
	var gone := _direct_edit(gone_doc, gone_body, ball, edited, piece)
	gone.options.erase("mesh")
	var unmarked := _rebuild(gone_doc)
	_expect(_error(unmarked, gone) != "" and unmarked.bodies.has(gone_body), "F2 A Direct Edit with no stored mesh and no marker should be an error, not an emptied body ('%s')." % _error(unmarked, gone))
	gone.options["emptied"] = true
	var emptied := _rebuild(gone_doc)
	_expect(_error(emptied, gone) == "" and not emptied.bodies.has(gone_body) and emptied.bodies.has(str(gone.options.outputs[0])), "F2 A Direct Edit marked as emptied should leave no body ('%s')." % _error(emptied, gone))
	# A scene with its stored mesh in a file beside it, loaded in a new session; the stored mesh is
	# then taken out of the loaded feature, which is what a file that is gone, empty or cut short
	# leaves there. (Loading the scene with the file really damaged gives the same feature, and
	# makes Godot print its own "Parse Error" and "ERROR:" lines; that was probed by hand and is
	# kept out of this test's log.)
	var big := FIXTURES.to_mesh(FIXTURES.with_noise(FIXTURES.icosphere(0.012, 6, Vector3(0, 0.1, 0)), 0.05))
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, ball, "Ball")
	var feature := _direct_edit(doc, body, ball, big, piece)
	var part: Node3D = CAD_PART.new()
	part.name = "Part"
	part.document = doc
	var holder := Node3D.new()
	holder.name = "Scene"
	holder.add_child(part)
	part.owner = holder
	var kept: Array = part.save_mesh_blobs(TEMP + "/design_forge")
	var packed := PackedScene.new()
	var scene_path := TEMP + "/design.tscn"
	var saved := packed.pack(holder) == OK and ResourceSaver.save(packed, scene_path) == OK
	holder.free()
	_expect(saved and kept.size() == 1, "F2 The design should save with its large stored mesh in a file of its own (%s)." % str(kept))
	if saved and kept.size() == 1:
		var sidecar: String = kept[0]
		MESH_FEATURE.clear_cache()
		var loaded_scene: PackedScene = ResourceLoader.load(scene_path, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
		var root: Node = loaded_scene.instantiate() if loaded_scene != null else null
		var loaded: Resource = root.get_node("Part").get("document") if root != null else null
		if loaded == null:
			_expect(false, "F2 The saved scene should load.")
		else:
			var edit: Resource = loaded.features[1]
			var whole := _rebuild(loaded)
			_expect(_error(whole, edit) == "" and str(_mesh(whole, body).digest()) == str(big.digest()), "F2 The scene with its stored mesh file should rebuild to the edited body ('%s')." % _error(whole, edit))
			edit.options["mesh"] = null
			MESH_FEATURE.clear_cache()
			var result := _rebuild(loaded)
			var error := _error(result, edit)
			_expect(error != "" and error.contains(sidecar.get_file()) and error.contains("Ball stays as it was") and _mesh(result, body) != null and str(_mesh(result, body).digest()) == str(ball.digest()),
				"F2 A Direct Edit whose stored mesh file is gone should be an error that names the file %s, with the body as it was ('%s'; body %s)." % [sidecar.get_file(), error, "there" if result.bodies.has(body) else "gone"])
			notes.append("F2 stored mesh file gone: '%s'" % error)
		if root != null:
			root.free()
	checked.append("F2 Direct Edit (a stored mesh that is gone, emptied or cut short is an error that names the file and leaves the body; 'every triangle taken out' has its own marker)")


# --- P3: Erase and Fill says what it really filled ---------------------------------------------

func _check_erase_fill() -> void:
	var ball := FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 4))
	var indices: PackedInt32Array = ball.get_arrays().indices
	# Two triangles that share one corner only: the hole they leave is pinched there.
	var pair := PackedInt32Array([0])
	for t in range(1, indices.size() / 3):
		var shared := 0
		for k in 3:
			for j in 3:
				shared += 1 if indices[3 * t + k] == indices[j] else 0
		if shared == 1:
			pair.append(t)
			break
	for fill in ["smooth", "minimal", "flat"]:
		var doc: Resource = DOCUMENT.new()
		var body := _add_mesh(doc, ball, "Part")
		var feature := _tool(doc, "erase_fill", {"selection": [_triangles(body, pair, ball)], "fill": fill})
		var result := _rebuild(doc)
		var made := _mesh(result, body)
		var open := _open_edges(made)
		var stat := _stat(feature)
		_expect(_error(result, feature) == "" and open == 6 and not stat.contains("closed 1 hole") and stat.contains("closed 0 of 1 hole") and stat.contains("1 stays open")
			and _count_with(_warnings(feature), ["Part", "could not be closed"]) == 1, "P3 Erase and Fill (%s) of two triangles at one corner leaves the hole open: the stat and a warning should say so ('%s'; %s; %d open edges)." % [fill, stat, str(_warnings(feature)), open])
	# One triangle erased and filled: singular, and closed.
	var one_doc: Resource = DOCUMENT.new()
	var one_body := _add_mesh(one_doc, ball, "Part")
	var one := _tool(one_doc, "erase_fill", {"selection": [_triangles(one_body, PackedInt32Array([7]), ball)], "fill": "minimal"})
	var one_result := _rebuild(one_doc)
	_expect(_error(one_result, one) == "" and _stat(one) == "Erased 1 triangle, closed 1 hole" and _warnings(one).is_empty(), "P3 One triangle erased and filled should say so ('%s', %s)." % [_stat(one), str(_warnings(one))])
	# At a hemisphere's rim the hole the selection leaves runs into the rim, and cannot be filled:
	# nothing may say it was.
	var whole := FIXTURES.icosphere(0.05, 4)
	var upper := PackedInt32Array()
	var whole_indices: PackedInt32Array = whole.indices
	var whole_positions: PackedVector3Array = whole.positions
	for i in range(0, whole_indices.size(), 3):
		if (whole_positions[whole_indices[i]] + whole_positions[whole_indices[i + 1]] + whole_positions[whole_indices[i + 2]]).y / 3.0 > 0.0:
			upper.append_array([whole_indices[i], whole_indices[i + 1], whole_indices[i + 2]])
	var hemi := FIXTURES.to_mesh({"positions": whole_positions, "indices": upper, "groups": PackedInt32Array(), "names": PackedStringArray()})
	var rim := _where(hemi, func(c: Vector3) -> bool: return c.y < 0.006 and c.x > 0.03)
	var hemi_doc: Resource = DOCUMENT.new()
	var hemi_body := _add_mesh(hemi_doc, hemi, "Part")
	var at_rim := _tool(hemi_doc, "erase_fill", {"selection": [_triangles(hemi_body, rim, hemi)], "fill": "smooth"})
	var rim_result := _rebuild(hemi_doc)
	var rim_made := _mesh(rim_result, hemi_body)
	var loops: int = (rim_made.boundary_loops() as Array).size() if rim_made != null else -1
	var said_filled := _count_with(_warnings(at_rim), ["that hole was filled too"])
	_expect(_error(rim_result, at_rim) == "" and loops >= 1 and said_filled == 0 and not _stat(at_rim).contains("closed 1 hole") and _count_with(_warnings(at_rim), ["touches an open edge of Part"]) == 1,
		"P3 Erase and Fill at a hemisphere's rim fills nothing: no sentence may say the hole was filled, and one should say the selection ran into an open edge ('%s'; %s; %d loops)." % [_stat(at_rim), str(_warnings(at_rim)), loops])
	notes.append("P3 hemisphere rim: stat '%s'; warnings %s" % [_stat(at_rim), str(_warnings(at_rim))])
	checked.append("P3 Erase and Fill (a pinched hole stays open and the stat and warning say so, with every fill; one triangle; a selection at an open rim is not said to be filled)")


# --- Stale picks ---------------------------------------------------------------------------------

func _check_stale_picks() -> void:
	var first := FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 4))
	var smaller := FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 3))
	var other := FIXTURES.to_mesh(FIXTURES.with_noise(FIXTURES.icosphere(0.05, 4), 0.3))
	var selection := _where(first, func(c: Vector3) -> bool: return c.x > 0.02)
	# A pick with no record of the body's version: applied as it is on the first full build, and
	# doubted once the body is another one.
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, first, "Part")
	var smooth := _tool(doc, "smooth", {"selection": [{"kind": "mesh_triangles", "body": body, "triangles": selection}]})
	var one := _rebuild(doc)
	_expect(_error(one, smooth) == "" and _warnings(smooth).is_empty(), "S A triangle pick with no digest should build without a word while the body is the one it was made on ('%s', %s)." % [_error(one, smooth), str(_warnings(smooth))])
	(doc.features[0] as Resource).options["mesh"] = MESH_BLOB.from_mesh(other)
	var two := _rebuild(doc)
	_expect(_error(two, smooth) == "" and _count_with(_warnings(smooth), ["the triangle selection was made on an older version of Part"]) == 1,
		"S A triangle pick with no digest should be doubted once the body changed ('%s', %s)." % [_error(two, smooth), str(_warnings(smooth))])
	(doc.features[0] as Resource).options["mesh"] = MESH_BLOB.from_mesh(first)
	var back := _rebuild(doc)
	_expect(_error(back, smooth) == "" and _warnings(smooth).is_empty() and str(_mesh(back, body).digest()) == str(_mesh(one, body).digest()), "S With the first body back the pick should build as at first, without a word (%s)." % str(_warnings(smooth)))
	# Ids that are out of range are reason enough, even on the first build.
	var fresh: Resource = DOCUMENT.new()
	var fresh_body := _add_mesh(fresh, smaller, "Part")
	var group := _tool(fresh, "create_group", {"selection": [{"kind": "mesh_triangles", "body": fresh_body, "triangles": PackedInt32Array([1, 2, 5000])}]})
	var fresh_result := _rebuild(fresh)
	_expect(_error(fresh_result, group) == "" and _count_with(_warnings(group), ["older version of Part", "1 triangle is no longer there"]) == 1, "S A pick with no digest that names a triangle the body does not have should say so (%s)." % str(_warnings(group)))
	# A stale selection behind a refusal: the refusal says the selection is from an older version.
	var reduce_doc: Resource = DOCUMENT.new()
	var reduce_body := _add_mesh(reduce_doc, first, "Part")
	var reduce := _tool(reduce_doc, "reduce", {"selection": [_triangles(reduce_body, selection, first)], "target": "proportion", "algorithm": "fast"}, {"proportion": ["90", "number"]})
	var fine := _rebuild(reduce_doc)
	(reduce_doc.features[0] as Resource).options["mesh"] = MESH_BLOB.from_mesh(smaller)
	var refused := _rebuild(reduce_doc)
	var error := _error(refused, reduce)
	_expect(_error(fine, reduce) == "" and error.contains("The selection has") and error.contains("the triangle selection was made on an older version of Part"),
		"S A Reduce refused over a stale selection should say the selection is from an older version of the body ('%s')." % error)
	notes.append("S stale Reduce: '%s'" % error)
	checked.append("stale picks (a pick with no digest is doubted once the body changed and when it names triangles that are not there; a refusal over a stale selection says so)")


# --- P7: the sentence about bodies before it ---------------------------------------------------

func _check_time_sentence() -> void:
	# One body, a time limit the op cannot meet, and a self-crossing test before it that uses part
	# of the limit: nothing may speak of "the bodies before it".
	var grid := FIXTURES.to_mesh(FIXTURES.large_grid(100))
	for method in ["plane_cut", "separate"]:
		var doc: Resource = DOCUMENT.new()
		var body := _add_mesh(doc, grid, "Grid")
		var options := {"bodies": [_pick(body)]}
		if method == "plane_cut":
			options.merge({"plane": [{"kind": "origin", "name": "xy"}], "type": "trim", "fill": "uniform"})
		var feature := _tool(doc, method, options, {"offset": ["50 mm", "length"]} if method == "plane_cut" else {})
		MESH_FEATURE.clear_cache()
		var result := _rebuild(doc, 0.06)
		var error := _error(result, feature)
		_expect(MESH_FEATURE.is_time_refusal(error) and not error.contains("bodies before it") and not error.contains("fewer bodies") and error.contains("Grid"),
			"P7 A %s on one body that does not fit its time should not speak of bodies before it ('%s')." % [method, error])
		notes.append("P7 %s at 0.06 s: '%s'" % [method, error])
	checked.append("P7 one body (a time refusal after the self-crossing test does not speak of bodies before it)")


# --- A body that crosses itself is told, by name, once ---------------------------------------

func _check_crossing_notes() -> void:
	var crossing := FIXTURES.to_mesh(FIXTURES.two_cubes(Vector3(0.01, 0.0, 0.0)))
	var ball := FIXTURES.to_mesh(FIXTURES.icosphere(0.004, 2, Vector3(0.0, 0.0, 0.0)))
	var far_ball := FIXTURES.to_mesh(FIXTURES.icosphere(0.004, 2, Vector3(0.0, 0.05, 0.0)))
	# Combine: the target, and a tool.
	for case in [["target", "Pair", "Ball"], ["tool", "Ball", "Pair"]]:
		for operation in ["join", "cut", "merge"]:
			var doc: Resource = DOCUMENT.new()
			var pair := _add_mesh(doc, crossing, "Pair")
			var small := _add_mesh(doc, far_ball if operation == "merge" else ball, "Ball")
			var target := pair if case[1] == "Pair" else small
			var tool_body := small if case[1] == "Pair" else pair
			var feature := _tool(doc, "combine", {"target": [_pick(target)], "tools": [_pick(tool_body)], "operation": operation, "keep_tools": true})
			var result := _rebuild(doc)
			var error := _error(result, feature)
			var said := _count_with(_warnings(feature), ["Pair crosses itself"])
			_expect((error == "" and said == 1 and _count_with(_warnings(feature), ["Ball crosses itself"]) == 0) or (error.contains("Pair crosses itself")),
				"X Combine (%s) with a self-crossing %s should say 'Pair crosses itself…' once (error '%s'; %s)." % [operation, case[0], error, str(_warnings(feature))])
	# Shell: the accurate one refuses (it has no clear inside); the fast one is told.
	for algorithm in ["accurate", "fast"]:
		var doc: Resource = DOCUMENT.new()
		var pair := _add_mesh(doc, crossing, "Pair")
		var feature := _tool(doc, "shell", {"bodies": [_pick(pair)], "direction": "outside", "algorithm": algorithm}, {"thickness": ["1 mm", "length"]})
		var result := _rebuild(doc)
		var error := _error(result, feature)
		_expect(error.contains("Pair crosses itself") or (error == "" and _count_with(_warnings(feature), ["Pair crosses itself"]) == 1),
			"X A %s Shell of a body that crosses itself should refuse or say so, by name, once (error '%s'; %s)." % [algorithm, error, str(_warnings(feature))])
		notes.append("X shell %s: error '%s'; warnings %s" % [algorithm, error, str(_warnings(feature))])
	# Texture Extrude.
	var image := FIXTURES.write_png_checker("regress_tools/checker.png", 64)
	var extrude_doc: Resource = DOCUMENT.new()
	var extrude_pair := _add_mesh(extrude_doc, crossing, "Pair")
	var extrude := _tool(extrude_doc, "texture_extrude", {"selection": [_group(extrude_pair, "g0")], "image": image, "mapping": "box"},
		{"depth": ["0.2 mm", "length"], "tile": ["10 mm", "length"], "detail": ["1.25 mm", "length"]})
	var extruded := _rebuild(extrude_doc)
	_expect(_error(extruded, extrude).contains("Pair crosses itself") or (_error(extruded, extrude) == "" and _count_with(_warnings(extrude), ["Pair crosses itself"]) == 1),
		"X Texture Extrude on a body that crosses itself should say so, by name, once (error '%s'; %s)." % [_error(extruded, extrude), str(_warnings(extrude))])
	# Plane Cut and Separate still say it once (the kernel may say it too now).
	for method in ["plane_cut", "separate"]:
		var doc: Resource = DOCUMENT.new()
		var pair := _add_mesh(doc, crossing, "Pair")
		var options := {"bodies": [_pick(pair)]}
		if method == "plane_cut":
			options.merge({"plane": [{"kind": "origin", "name": "xy"}], "type": "trim", "fill": "uniform"})
		var feature := _tool(doc, method, options)
		var result := _rebuild(doc)
		_expect(_error(result, feature) == "" and _count_with(_warnings(feature), ["Pair crosses itself"]) == 1, "X %s on a body that crosses itself should say so once (error '%s'; %s)." % [method, _error(result, feature), str(_warnings(feature))])
	# Any other tool whose result crosses itself says so too (the kernel's count is in its report).
	var turn_doc: Resource = DOCUMENT.new()
	var turn_pair := _add_mesh(turn_doc, crossing, "Pair")
	var turn := _tool(turn_doc, "generate_groups", {"bodies": [_pick(turn_pair)], "algorithm": "fast"})
	var turned := _rebuild(turn_doc)
	var counted: Variant = (_report(turn).get("self_intersections"))
	_expect(_error(turned, turn) == "" and (not (counted is int and int(counted) > 0) or _count_with(_warnings(turn), ["Pair", "crosses itself"]) == 1),
		"X A tool whose report counts crossings in its result should say so (report %s; %s)." % [str(counted), str(_warnings(turn))])
	checked.append("crossing bodies (Combine's target and tools, Shell, Texture Extrude, Plane Cut, Separate: told by name, once; a result the kernel counts crossings in is told)")


# --- Separate's report -----------------------------------------------------------------------------

func _check_separate_report() -> void:
	var doc: Resource = DOCUMENT.new()
	var plate := FIXTURES.to_mesh(FIXTURES.open_plate())
	var pair := _add_mesh(doc, FIXTURES.to_mesh(FIXTURES.two_cubes(Vector3(0.03, 0, 0))), "Pair")
	var sheet := _add_mesh(doc, plate, "Plate")
	var feature := _tool(doc, "separate", {"bodies": [_pick(pair), _pick(sheet)], "by": "components"})
	var result := _rebuild(doc)
	var report := _report(feature)
	var total := 24 + int(plate.triangle_count())
	_expect(_error(result, feature) == "" and int((report.get("input", {}) as Dictionary).get("triangles", -1)) == total and int((report.get("output", {}) as Dictionary).get("triangles", -1)) == total
		and int((report.get("output", {}) as Dictionary).get("boundary_edges", -1)) == 128 and str(report.get("stat", "")) == "Bodies: 3",
		"R Separate's report should count the triangles before and after and the open edges (input %s, output %s, stat '%s'; %s)." % [str(report.get("input")), str(report.get("output")), str(report.get("stat", "")), _error(result, feature)])
	checked.append("Separate's report (triangles before and after, open edges)")


# --- Reader warnings, and a linked mesh body over the Faceted cap ------------------------------

func _check_reader_warnings() -> void:
	# A text STL that stops after its first facet: what is there loads, and the reader says so.
	var whole_path := FIXTURES.write_stl(FIXTURES.two_cubes(Vector3(0.05, 0, 0)).first, "regress_tools/whole.stl", 1000.0, true)
	var lines := FileAccess.get_file_as_string(whole_path).split("\n")
	var cut_path := TEMP + "/cut_off.stl"
	var cut_file := FileAccess.open(cut_path, FileAccess.WRITE)
	cut_file.store_string("\n".join(lines.slice(0, 8)) + "\n")
	cut_file.close()
	var read: Dictionary = INSERT.read_mesh_body(cut_path)
	_expect(str(read.error) == "" and str(read.get("warning", "")).contains("cut_off.stl") and str(read.get("warning", "")).contains("cut off"), "W read_mesh_body should pass the reader's warning on ('%s', '%s')." % [read.error, read.get("warning", "")])
	for linked in [false, true]:
		var doc: Resource = DOCUMENT.new()
		var added: Dictionary = INSERT.add_mesh_import(doc, cut_path, "", linked, INSERT.KIND_MESH)
		_expect(str(added.error) == "" and str(added.get("warning", "")).contains("cut off"), "W add_mesh_import should give the reader's warning back (linked %s: '%s', '%s')." % [linked, added.error, added.get("warning", "")])
		if added.feature == null:
			continue
		var result := _rebuild(doc)
		var again := _rebuild(doc)
		for built in [result, again]:
			var warning := _warning(built, added.feature)
			_expect(_error(built, added.feature) == "" and warning.contains("cut_off.stl") and warning.contains("cut off") and warning.contains("open edge"),
				"W An Insert Mesh (linked %s) of a file that looks cut off should carry the reader's warning with the file's name, beside its own ('%s'; error '%s')." % [linked, warning, _error(built, added.feature)])
	# A whole file: no warning.
	var clean: Resource = DOCUMENT.new()
	var clean_added: Dictionary = INSERT.add_mesh_import(clean, whole_path, "", false, INSERT.KIND_MESH)
	_expect(str(clean_added.get("warning", "")) == "" and _warning(_rebuild(clean), clean_added.feature) == "", "W A whole file should come in without a warning ('%s')." % clean_added.get("warning", ""))
	# F6: a linked mesh body over the Faceted cap, switched to a solid.
	var big_path := FIXTURES.write_stl(FIXTURES.icosphere(0.05, 6), "regress_tools/big.stl", 1000.0)
	var big_doc: Resource = DOCUMENT.new()
	var big: Dictionary = INSERT.add_mesh_import(big_doc, big_path, "", true, INSERT.KIND_MESH)
	var as_mesh := _rebuild(big_doc)
	big.feature.options["kind"] = INSERT.KIND_SOLID
	var as_solid := _rebuild(big_doc)
	var error := _error(as_solid, big.feature)
	var warning := _warning(as_solid, big.feature)
	_expect(_error(as_mesh, big.feature) == "" and error != "" and not error.contains("holds no triangles") and not warning.contains("couldn't be read again") and (error.contains("81920") or error.contains("81,920")) and (error.contains("60000") or error.contains("60,000")),
		"F6 A linked mesh body of 81,920 triangles switched to a solid should be refused for its size, with nothing false ('%s'; warning '%s')." % [error, warning])
	notes.append("F6: '%s'" % error)
	checked.append("readers (a file that looks cut off comes in with the reader's warning and the file's name, stored and linked; a whole file without one) and F6 (a linked mesh body over the Faceted cap switched to a solid is refused for its size)")


# --- The cache -------------------------------------------------------------------------------------

func _check_cache() -> void:
	# A refusal by time answers the next rebuild with the same limit at once, also for a body that
	# got only what the one before it left, and also after a self-crossing test took its share.
	var first_ball := FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 4))
	var second_ball := FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 4, Vector3(0.2, 0, 0)))
	var estimate := float((first_ball.op_defaults("rebuild", {"detail": 1 * MM}) as Dictionary).get("seconds", 0.0))
	var doc: Resource = DOCUMENT.new()
	var one_id := _add_mesh(doc, first_ball, "One")
	var two_id := _add_mesh(doc, second_ball, "Two")
	var feature := _tool(doc, "rebuild", {"bodies": [_pick(one_id), _pick(two_id)], "algorithm": "union"}, {"detail": ["1 mm", "length"]})
	var limit := estimate + 0.2
	MESH_FEATURE.clear_cache()
	var started := Time.get_ticks_usec()
	var first := _rebuild(doc, limit)
	var first_seconds := (Time.get_ticks_usec() - started) / 1e6
	# (The second body was refused for the time the first one left it. The next build finds the
	# first one's result kept, so the second body has the whole limit then: it is asked once more,
	# and whatever that gives is kept for the builds after it.)
	var second := _rebuild(doc, limit)
	started = Time.get_ticks_usec()
	var third := _rebuild(doc, limit)
	var third_seconds := (Time.get_ticks_usec() - started) / 1e6
	_expect(estimate > 0.5 and MESH_FEATURE.is_time_refusal(_error(first, feature)) and _error(first, feature).contains("The bodies before it used the rest") and _error(third, feature) == _error(second, feature)
		and third_seconds < 0.1 * first_seconds, "C A tool on two bodies should settle after the build that follows a refusal for lack of time (%.2f s, then %.3f s; '%s', '%s', '%s')." % [first_seconds, third_seconds, _error(first, feature), _error(second, feature), _error(third, feature)])
	# One body refused by its time: the very next build with the same limit answers at once.
	var alone: Resource = DOCUMENT.new()
	var alone_id := _add_mesh(alone, first_ball, "One")
	var alone_feature := _tool(alone, "rebuild", {"bodies": [_pick(alone_id)], "algorithm": "union"}, {"detail": ["1 mm", "length"]})
	# (From nothing kept: the two-body design above left this body's result, which would answer.)
	MESH_FEATURE.clear_cache()
	_rebuild(alone, 1.0)
	var hits_before := MESH_FEATURE.cache_hits
	var refused_again := _rebuild(alone, 1.0)
	_expect(MESH_FEATURE.is_time_refusal(_error(refused_again, alone_feature)) and not _error(refused_again, alone_feature).contains("bodies before it") and MESH_FEATURE.cache_hits - hits_before >= 2,
		"C A refusal by time should answer the next rebuild with the same limit at once ('%s'; %d kept answers used)." % [_error(refused_again, alone_feature), MESH_FEATURE.cache_hits - hits_before])
	notes.append("C two bodies: %.2f s, then %.3f s once settled; '%s' then '%s'" % [first_seconds, third_seconds, _error(first, feature), _error(second, feature)])
	var grid := FIXTURES.to_mesh(FIXTURES.large_grid(100))
	var cut_doc: Resource = DOCUMENT.new()
	var grid_id := _add_mesh(cut_doc, grid, "Grid")
	var cut := _tool(cut_doc, "plane_cut", {"bodies": [_pick(grid_id)], "plane": [{"kind": "origin", "name": "xy"}], "type": "trim", "fill": "uniform"}, {"offset": ["50 mm", "length"]})
	_rebuild(cut_doc, 0.06)
	if MESH_FEATURE.is_time_refusal(str(_rebuild(cut_doc, 0.06).errors.get(cut.id, ""))):
		var hits := MESH_FEATURE.cache_hits
		var again := _rebuild(cut_doc, 0.06)
		# (The inserted mesh and the refusal: two kept answers.)
		_expect(MESH_FEATURE.cache_hits - hits >= 2 and MESH_FEATURE.is_time_refusal(_error(again, cut)), "C A time refusal after the self-crossing test should be kept too (%d kept answers used)." % (MESH_FEATURE.cache_hits - hits))
	# A result made within a preview's half second is not handed to a full-time rebuild (its
	# post-checks had less time, so its warnings may be fewer); the full-time one serves both.
	var small: Resource = DOCUMENT.new()
	var ball_id := _add_mesh(small, FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 3)), "Ball")
	var reduce := _tool(small, "reduce", {"bodies": [_pick(ball_id)], "target": "proportion", "algorithm": "fast"}, {"proportion": ["50", "number"]})
	MESH_FEATURE.clear_cache()
	var preview := _rebuild(small, MESH_FEATURE.PREVIEW_SECONDS)
	var full := _rebuild(small)
	var full_again := _rebuild(small)
	var preview_again := _rebuild(small, MESH_FEATURE.PREVIEW_SECONDS)
	_expect(_error(preview, reduce) == "" and _error(full, reduce) == "" and not is_same(_mesh(preview, ball_id), _mesh(full, ball_id)) and str(_mesh(preview, ball_id).digest()) == str(_mesh(full, ball_id).digest())
		and is_same(_mesh(full, ball_id), _mesh(full_again, ball_id)) and is_same(_mesh(full, ball_id), _mesh(preview_again, ball_id)),
		"C A full-time rebuild should compute its own result after a preview (the same mesh by content), and then serve rebuilds and previews alike.")
	checked.append("the cache (a refusal by time is kept for its limit, also for a later body and after the self-crossing test; a preview's result is not handed to a full-time rebuild)")


# --- After the kernel's fix round ----------------------------------------------------------------

func _check_kernel_round() -> void:
	# Wrap of several bodies: the kernel sees one merged mesh and has no names; the feature says
	# which of the picked bodies is not in the wrap.
	var cubes := FIXTURES.two_cubes(Vector3(0.05, 0.0, 0.0))
	var doc: Resource = DOCUMENT.new()
	var block := _add_mesh(doc, FIXTURES.to_mesh(cubes.first), "Block")
	var speck := _add_mesh(doc, FIXTURES.to_mesh(FIXTURES.icosphere(0.0002, 1, Vector3(0.02, 0.0, 0.0))), "Speck")
	var other := _add_mesh(doc, FIXTURES.to_mesh(FIXTURES.icosphere(0.008, 2, Vector3(0.0, 0.03, 0.0))), "Ball")
	var wrap := _tool(doc, "wrap", {"bodies": [_pick(block), _pick(speck), _pick(other)]}, {"detail": ["1 mm", "length"], "gap": ["3 mm", "length"]})
	var result := _rebuild(doc)
	var given := _warnings(wrap)
	_expect(_error(result, wrap) == "" and _count_with(given, ["Speck is not in the wrap at all"]) == 1 and _count_with(given, ["Block is not in the wrap"]) == 0 and _count_with(given, ["Ball is not in the wrap"]) == 0
		and _count_with(given, ["of Block not in the wrap"]) == 0 and not result.bodies.has(speck) and not result.bodies.has(other) and _mesh(result, block) != null and int(_mesh(result, block).solid_count()) == 2
		and _count_with(given, ["{body}"]) == 0, "N A Wrap of three bodies that leaves one out should name that one, and only that one (error '%s'; %s)." % [_error(result, wrap), str(given)])
	_expect(_count_with(given, ["Block, Speck and Ball"]) >= 1 or _count_with(given, ["surface is not inside the wrap"]) == 0, "N The kernel's sentence about the wrapped surface should name all the bodies wrapped together (%s)." % str(given))
	notes.append("N wrap of three bodies: %s" % str(given))
	# The same mesh handed back ("nothing to do"): the body stays, the warning shows, no error.
	var plate := FIXTURES.to_mesh(FIXTURES.open_plate())
	var same_doc: Resource = DOCUMENT.new()
	var sheet := _add_mesh(same_doc, plate, "Plate")
	var cube := _add_mesh(same_doc, FIXTURES.to_mesh(cubes.first), "Cube")
	var outline := _tool(same_doc, "close_holes", {"bodies": [_pick(sheet)], "fill": "smooth"})
	var keep_all := _tool(same_doc, "reduce", {"bodies": [_pick(cube)], "target": "face_count", "algorithm": "adaptive", "keep_sharp": true}, {"face_count": ["6", "number"]})
	var same := _rebuild(same_doc)
	for item in [[outline, sheet, plate, "Close Holes on a sheet's outline"], [keep_all, cube, FIXTURES.to_mesh(cubes.first), "Reduce of a cube whose every edge is sharp"]]:
		var feature: Resource = item[0]
		var made := _mesh(same, str(item[1]))
		var unchanged: bool = made != null and str(made.digest()) == str((item[2] as RefCounted).digest())
		_expect(_error(same, feature) == "" and (not unchanged or (not _warnings(feature).is_empty() and _warning(same, feature).contains(same_doc.body_name(str(item[1]))))),
			"N %s: a body that comes back as it was should carry the kernel's warning, by name, and no error (error '%s'; unchanged %s; %s)." % [item[3], _error(same, feature), unchanged, str(_warnings(feature))])
		notes.append("N %s: unchanged %s; error '%s'; warnings %s" % [item[3], unchanged, _error(same, feature), str(_warnings(feature))])
	# Tessellate of several bodies: a warning says which body it is about.
	var tess_doc: Resource = DOCUMENT.new()
	var box := _add_box(tess_doc, Vector3(0.02, 0.02, 0.02), Vector3.ZERO)
	var ball: Resource = tess_doc.add_feature("sphere", "Sphere", {"diameter": tess_doc.make_input("100 mm", "length")}, {"operation": OPERATIONS.NEW_BODY, "position": Vector3(0.0, 0.3, 0.0)})
	ball.options.body_id = tess_doc.new_body(ball.id)
	var coarse: Dictionary = MESH_FEATURE.add_tessellate(tess_doc, [box, ball.options.body_id], {"quality": "low"})
	var low := _rebuild(tess_doc)
	var said := _warning(low, coarse.feature)
	_expect(_error(low, coarse.feature) != "" or said == "" or said.contains(tess_doc.body_name(str(ball.options.body_id))), "N A Tessellate of two bodies should say which body its warning is about ('%s'; error '%s')." % [said, _error(low, coarse.feature)])
	notes.append("N tessellate of a box and a ball at Low: error '%s'; warning '%s'" % [_error(low, coarse.feature), said])
	checked.append("after the kernel's fix round (a Wrap of several bodies names the one left out, a body handed back unchanged keeps its warning and gives no error, a Tessellate of several bodies names the body it warns about)")


# --- Face group picks follow their face ----------------------------------------------------------

const TOP_Y := Vector3(0.0, 0.01, 0.0075)
const SIDE_X := Vector3(0.01, 0.0, 0.0075)


## The face group a ray from far outside meets first: {"name", "normal"} ({} when it misses).
func _group_hit(mesh: RefCounted, toward: Vector3) -> Dictionary:
	var out := toward.normalized()
	var hit: Dictionary = mesh.ray_hit(toward + out * 0.1, -out, 1.0) if mesh != null else {}
	if not bool(hit.get("hit", false)):
		return {}
	return {"name": str(mesh.get_face_names()[int(hit.group)]), "normal": hit.normal}


func _check_group_picks() -> void:
	var cube := FIXTURES.to_mesh(FIXTURES.two_cubes(Vector3(0.05, 0.0, 0.0)).first)
	var image := FIXTURES.write_png_checker("regress_tools/group_checker.png", 64)
	# What the cube's +X and +Y faces are called by Generate Face Groups, before and after a cut is
	# put in front of it: the names go by order, so the cut renumbers them (+X from g5 to g4).
	var names := []
	for with_cut in [false, true]:
		var doc: Resource = DOCUMENT.new()
		var body := _add_mesh(doc, cube, "Cube")
		if with_cut:
			_tool(doc, "plane_cut", {"bodies": [_pick(body)], "plane": [{"kind": "origin", "name": "xy"}], "type": "trim", "fill": "uniform"}, {"offset": ["5 mm", "length"]})
		_tool(doc, "generate_groups", {"bodies": [_pick(body)], "algorithm": "fast"}, {"angle": ["20", "angle"]})
		var made := _mesh(_rebuild(doc), body)
		names.append([str(_group_hit(made, SIDE_X).get("name", "")), str(_group_hit(made, TOP_Y).get("name", ""))])
	var side: String = names[0][0]
	var top: String = names[0][1]
	_expect(top != "" and side != "" and top != side and names[1][0] != side, "G The cut should renumber the cube's +X face group, or the case tests nothing (+X is %s, then %s; +Y is %s, then %s)." % [side, names[1][0], top, names[1][1]])
	var side_pick := {"kind": "mesh_group", "body": "", "group": side, "at": SIDE_X, "normal": Vector3(1, 0, 0)}
	var top_pick := {"kind": "mesh_group", "body": "", "group": top, "at": TOP_Y, "normal": Vector3(0, 1, 0)}
	for tool in ["reverse_normal", "combine_groups", "texture_extrude", "erase_fill"]:
		var doc: Resource = DOCUMENT.new()
		var body := _add_mesh(doc, cube, "Cube")
		var generate := _tool(doc, "generate_groups", {"bodies": [_pick(body)], "algorithm": "fast"}, {"angle": ["20", "angle"]})
		var on_side: Dictionary = side_pick.duplicate()
		on_side["body"] = body
		var on_top: Dictionary = top_pick.duplicate()
		on_top["body"] = body
		var feature: Resource
		match tool:
			"reverse_normal":
				feature = _tool(doc, tool, {"mode": "selection", "selection": [on_side]})
			"combine_groups":
				feature = _tool(doc, tool, {"groups": [on_side, on_top]})
			"texture_extrude":
				feature = _tool(doc, tool, {"selection": [on_side], "image": image, "mapping": "box"}, {"depth": ["0.5 mm", "length"], "tile": ["10 mm", "length"], "detail": ["0.3125 mm", "length"]})
			_:
				feature = _tool(doc, tool, {"selection": [on_side], "fill": "minimal"})
		for stage in ["as picked", "after a cut before Generate Face Groups"]:
			if stage != "as picked":
				var cut := _tool(doc, "plane_cut", {"bodies": [_pick(body)], "plane": [{"kind": "origin", "name": "xy"}], "type": "trim", "fill": "uniform"}, {"offset": ["5 mm", "length"]})
				doc.features.erase(cut)
				doc.features.insert(doc.feature_index(generate.id), cut)
			var result := _rebuild(doc)
			var error := _error(result, feature)
			var made := _mesh(result, body)
			var at_side := _group_hit(made, SIDE_X)
			var at_top := _group_hit(made, TOP_Y)
			var right := false
			match tool:
				"reverse_normal":
					right = not at_side.is_empty() and (at_side.normal as Vector3).x < -0.9 and (at_top.normal as Vector3).y > 0.9
				"combine_groups":
					right = not at_side.is_empty() and str(at_side.name) == str(at_top.name) and str(_group_hit(made, Vector3(-0.01, 0.0, 0.0075)).get("name", "")) != str(at_side.name)
				"texture_extrude":
					# (Raised along +X by the Depth; next to the face's border the smoothed normals lean a
					# few hundredths of a millimeter sideways, no more.)
					right = made != null and (made.bbox() as AABB).end.x > 0.0102 and (made.bbox() as AABB).end.y < 0.0101
				_:
					right = not at_side.is_empty() and str(at_side.name).begins_with("fill") and not str(at_top.name).begins_with("fill")
			var moved := _count_with(_warnings(feature), ["pick of face group %s now lands on" % side])
			if stage == "as picked":
				_expect(error == "" and right and moved == 0, "G %s on the +X face group should act on it (%s; error '%s'; %s; bounds %s)." % [tool, stage, error, str(_warnings(feature)), str(made.bbox()) if made != null else "none"])
			else:
				# It follows the face and says the group moved, or it fails with why. It never
				# acts on the face that now carries the old name.
				_expect((error == "" and right and moved >= 1) or (error != "" and error.contains("face group")),
					"G %s on the +X face group, %s, should still act on that face and warn, or fail saying the group is lost (acted on the right face %s; error '%s'; %s)." % [tool, stage, right, error, str(_warnings(feature))])
				notes.append("G %s %s: error '%s'; warnings %s" % [tool, stage, error, str(_warnings(feature))])
	# A pick whose face is nowhere to be found: the feature fails, by name.
	var lost_doc: Resource = DOCUMENT.new()
	var lost_body := _add_mesh(lost_doc, cube, "Cube")
	_tool(lost_doc, "generate_groups", {"bodies": [_pick(lost_body)], "algorithm": "fast"}, {"angle": ["20", "angle"]})
	var gone := _tool(lost_doc, "reverse_normal", {"mode": "selection", "selection": [{"kind": "mesh_group", "body": lost_body, "group": "g17", "at": Vector3(0.5, 0.5, 0.5), "normal": Vector3(0, 1, 0)}]})
	var lost := _error(_rebuild(lost_doc), gone)
	_expect(lost.contains("face group") and lost.contains("Cube"), "G A face group pick that can't be found should fail the feature, by the body's name ('%s')." % lost)
	checked.append("face group picks (Reverse Normal, Combine Face Groups, Texture Extrude and Erase and Fill follow their face when a cut before Generate Face Groups renumbers the groups, and say the group moved; a pick that is gone fails by name)")


# --- A linked file that changed under the same modified time -----------------------------------

## Sets a file's modified time (there is no call for it in the engine: the system's own command).
func _set_file_time(path: String, stamp: String) -> bool:
	var system := ProjectSettings.globalize_path(path)
	if OS.get_name() == "Windows":
		return OS.execute("powershell", ["-NoProfile", "-NonInteractive", "-Command", "(Get-Item -LiteralPath '%s').LastWriteTime = [DateTime]::ParseExact('%s', 'yyyy-MM-dd HH:mm:ss', $null)" % [system, stamp]]) == 0
	return OS.execute("touch", ["-d", stamp, system]) == 0


func _check_linked_stamp() -> void:
	var cubes := FIXTURES.two_cubes(Vector3(0.05, 0.0, 0.0))
	var path := FIXTURES.write_stl(cubes.first, "regress_tools/linked_same_time.stl", 1000.0)
	# The stamp holds the size and the content, whatever the file's age; one without them (an
	# older stamp) counts as changed.
	var stamp: Dictionary = INSERT._stamp(path)
	_expect(stamp.has("size") and int(stamp.size) == FileAccess.get_size(path) and str(stamp.get("md5", "")) == FileAccess.get_md5(path) and INSERT._unchanged(path, stamp)
		and not INSERT._unchanged(path, {"time": int(stamp.time), "md5": ""}) and not INSERT._unchanged(path, {"time": int(stamp.time), "md5": str(stamp.get("md5", ""))}),
		"L A file's stamp should hold its size and content hash, and a stamp without them should count as changed (%s)." % str(stamp))
	# Through the features: a file from long ago, replaced by another of the same size under the
	# same modified time.
	var old := "2020-01-02 03:04:05"
	if not _set_file_time(path, old):
		notes.append("L the file's modified time could not be set on this system: the same-time case ran on the stamp only.")
	else:
		for kind in [INSERT.KIND_MESH, INSERT.KIND_SOLID]:
			FIXTURES.write_stl(cubes.first, "regress_tools/linked_same_time.stl", 1000.0)
			_set_file_time(path, old)
			var doc: Resource = DOCUMENT.new()
			var added: Dictionary = INSERT.add_mesh_import(doc, path, "", true, kind)
			var before := _rebuild(doc)
			var body := str(added.feature.options.body_id)
			var first_box: AABB = before.bodies[body].shape.bbox()
			var time_before := FileAccess.get_modified_time(path)
			var size_before := FileAccess.get_size(path)
			FIXTURES.write_stl(cubes.second, "regress_tools/linked_same_time.stl", 1000.0)
			_set_file_time(path, old)
			var after := _rebuild(doc)
			var second_box: AABB = after.bodies[body].shape.bbox() if after.bodies.has(body) else AABB()
			_expect(FileAccess.get_modified_time(path) == time_before and FileAccess.get_size(path) == size_before and before.errors.is_empty() and after.errors.is_empty()
				and absf(second_box.get_center().x - first_box.get_center().x - 0.05) < 1e-6, "L A linked %s body whose file changed under the same modified time and size should be read again (its middle moved from x %s to %s; %s)." % [
				kind, first_box.get_center().x, second_box.get_center().x, str(after.errors)])
	checked.append("linked files (the stamp holds size and content; a file changed under the same modified time and size is read again, as a mesh body and as a solid)")


# --- Close Holes, Erase and Fill, and the outline of an open sheet -----------------------------

func _check_outline() -> void:
	# A flat open plate with one hole in its middle.
	var whole := FIXTURES.to_mesh(FIXTURES.open_plate())
	var middle_triangle: int = int((whole.triangles_near((whole.bbox() as AABB).get_center(), 0.002, false) as PackedInt32Array)[0])
	var plate: RefCounted = whole.delete_triangles(whole.grow(PackedInt32Array([middle_triangle]), 3))
	var loops: Array = plate.boundary_loops()
	var outline_id := -1
	var hole_id := -1
	for loop in loops:
		if int(loop.edges) == 128:
			outline_id = int(loop.id)
		else:
			hole_id = int(loop.id)
	_expect(loops.size() == 2 and outline_id >= 0 and hole_id >= 0, "O The fixture should be a plate with its outline and one hole (%d loops)." % loops.size())
	# No hole picked ("every hole"): the hole is closed, the outline stays open, with the sentence.
	var doc: Resource = DOCUMENT.new()
	var body := _add_mesh(doc, plate, "Plate")
	var feature := _tool(doc, "close_holes", {"bodies": [_pick(body)], "loops": [], "fill": "minimal"})
	var result := _rebuild(doc)
	var made := _mesh(result, body)
	_expect(_error(result, feature) == "" and made != null and (made.boundary_loops() as Array).size() == 1 and _open_edges(made) == 128 and absf(float(made.area()) - float(whole.area())) < 1e-9
		and _count_with(_warnings(feature), ["Plate", "outline of an open sheet", "stay"]) == 1 and _stat(feature) == "Holes closed: 1",
		"O Close Holes with no hole picked should close the hole and leave the plate's outline open, saying so (error '%s'; %s; stat '%s'; %d open edges)." % [_error(result, feature), str(_warnings(feature)), _stat(feature), _open_edges(made)])
	notes.append("O no pick: %s; stat '%s'" % [str(_warnings(feature)), _stat(feature)])
	# The outline picked: it is closed, as asked, with the warning that it looks like an outline.
	feature.options["loops"] = [{"kind": "mesh_boundary", "body": body, "loop": outline_id, "edges": 128, "digest": str(plate.digest())}]
	var picked := _rebuild(doc)
	var covered := _mesh(picked, body)
	_expect(_error(picked, feature) == "" and covered != null and _open_edges(covered) == _open_edges(plate) - 128 and _count_with(_warnings(feature), ["Plate", "look", "outline of an open sheet"]) == 1,
		"O Close Holes on a picked outline should close it and warn that it looks like the sheet's outline (error '%s'; %s; %d open edges)." % [_error(picked, feature), str(_warnings(feature)), _open_edges(covered)])
	notes.append("O outline picked: %s" % str(_warnings(feature)))
	# Erase and Fill at the plate's border: the gap runs into the outline, which is no hole. It
	# stays open; no second surface is laid on the plate.
	var border: PackedInt32Array = whole.grow(PackedInt32Array([0]), 2)
	var erase_doc: Resource = DOCUMENT.new()
	var erase_body := _add_mesh(erase_doc, whole, "Plate")
	var erase := _tool(erase_doc, "erase_fill", {"selection": [_triangles(erase_body, border, whole)], "fill": "minimal"})
	var erased := _rebuild(erase_doc)
	var left := _mesh(erased, erase_body)
	_expect(_error(erased, erase) == "" and left != null and int(left.triangle_count()) == int(whole.triangle_count()) - border.size() and float(left.area()) < float(whole.area())
		and (left.boundary_loops() as Array).size() == 1 and _count_with(_warnings(erase), ["open outline of Plate", "stays open"]) == 1 and _count_with(_warnings(erase), ["filled too"]) == 0
		and _stat(erase).contains("closed 0 of 1 hole"), "O Erase and Fill at a plate's border should leave the outline open and lay no second surface (error '%s'; %s; stat '%s'; area %s of %s; %d triangles of %d)." % [
		_error(erased, erase), str(_warnings(erase)), _stat(erase), left.area() if left != null else 0.0, whole.area(), int(left.triangle_count()) if left != null else -1, int(whole.triangle_count())])
	notes.append("O erase at the border: %s; stat '%s'" % [str(_warnings(erase)), _stat(erase)])
	checked.append("the outline of an open sheet (Close Holes with no pick closes the hole and leaves the outline with the sentence; a picked outline is closed with a warning; Erase and Fill at a sheet's border leaves the outline open)")


# --- Options of the wrong kind, and a damaged stored mesh ----------------------------------------

func _check_option_kinds() -> void:
	var ball := FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 3))
	var edited: RefCounted = ball.delete_triangles(ball.grow(PackedInt32Array([0]), 2))
	var cases := [
		["direct_edit", {"emptied": "true"}, "Emptied must be on or off"],
		["direct_edit", {"emptied": 1}, "Emptied must be on or off"],
		["direct_edit", {"emptied": [true]}, "Emptied must be on or off"],
		["direct_edit", {"outputs": "body9"}, "picks under 'outputs' can't be read"],
		["smooth", {"keep_volume": "yes"}, "Keep Volume must be on or off"],
		["smooth", {"bodies": "body1"}, "picks under 'bodies' can't be read"],
		["smooth", {"selection": {"kind": "mesh_triangles"}}, "picks under 'selection' can't be read"],
		["reduce", {"target": ["proportion"]}, "Target must be one of its choices"],
		["reduce", {"keep_sharp": 2}, "Keep Sharp must be on or off"],
		["combine", {"target": "body1"}, "picks under 'target' can't be read"],
		["combine", {"new_body": "no"}, "New Body must be on or off"],
		["plane_cut", {"plane": {"kind": "origin", "name": "xy"}}, "picks under 'plane' can't be read"],
		["plane_cut", {"type": 3}, "Type must be one of its choices"],
		["separate", {"made": [1, 2]}, "its own record 'made' can't be read"],
		["scale", {"uniform": "maybe"}, "Uniform must be on or off"],
		["texture_extrude", {"image": 12}, "Image must be a file's path"],
		["remesh", {"selection": [{"kind": "mesh_triangles", "body": "@body", "triangles": "0, 1, 2"}]}, "the triangle selection on Ball can't be read"],
		["close_holes", {"loops": [{"kind": "mesh_boundary", "body": "@body", "loop": [0]}]}, "a picked hole of Ball can't be read"],
	]
	for case in cases:
		var doc: Resource = DOCUMENT.new()
		var body := _add_mesh(doc, ball, "Ball")
		var options := {"bodies": [_pick(body)]}
		if str(case[0]) == "direct_edit":
			options["mesh"] = MESH_BLOB.from_mesh(edited)
			options["input_digest"] = str(ball.digest())
		for key in case[1]:
			var value: Variant = case[1][key]
			if value is Array and not value.is_empty() and value[0] is Dictionary and str(value[0].get("body", "")) == "@body":
				value = [(value[0] as Dictionary).merged({"body": body}, true)]
			options[key] = value
		var feature := _tool(doc, str(case[0]), options)
		var result := _rebuild(doc)
		var error := _error(result, feature)
		_expect(error.contains(str(case[2])) and error.contains(feature.label) and _mesh(result, body) != null and str(_mesh(result, body).digest()) == str(ball.digest()),
			"K %s with %s should be the feature's error with a sentence, and leave the body ('%s')." % [case[0], str(case[1]), error])
	# Triangles as a plain list of numbers are taken.
	var plain_doc: Resource = DOCUMENT.new()
	var plain_body := _add_mesh(plain_doc, ball, "Ball")
	var plain := _tool(plain_doc, "create_group", {"selection": [{"kind": "mesh_triangles", "body": plain_body, "triangles": [0, 1, 2], "digest": str(ball.digest())}]})
	var plain_result := _rebuild(plain_doc)
	_expect(_error(plain_result, plain) == "" and int(_mesh(plain_result, plain_body).find_face("user0")) >= 0, "K Triangles given as a plain list of numbers should be taken ('%s')." % _error(plain_result, plain))
	# A damaged stored mesh says what to do next.
	var hurt_doc: Resource = DOCUMENT.new()
	var hurt_body := _add_mesh(hurt_doc, ball, "Ball")
	var hurt: Resource = hurt_doc.add_feature("mesh", "DirectEdit", {}, {"method": "direct_edit", "bodies": [_pick(hurt_body)], "input_digest": str(ball.digest()), "mesh": MESH_BLOB.from_mesh(edited), "outputs": []})
	var blob: Resource = hurt.options.mesh
	var copy: Resource = MESH_BLOB.new()
	copy.format = blob.format
	copy.digest = blob.digest
	copy.size = blob.size
	copy.vertices = blob.vertices
	copy.triangles = blob.triangles
	var bytes: PackedByteArray = (blob.data as PackedByteArray).duplicate()
	bytes[bytes.size() / 2] = bytes[bytes.size() / 2] ^ 0x55
	copy.data = bytes
	hurt.options["mesh"] = copy
	var hurt_error := _error(_rebuild(hurt_doc), hurt)
	_expect(hurt_error.begins_with("The stored mesh of %s is damaged (" % hurt.label) and hurt_error.contains("or delete %s." % hurt.label) and (hurt_error.contains("Put back a sound copy of") or hurt_error.contains("Open a copy of the design that still has it")),
		"K A damaged stored mesh should say what to do next ('%s')." % hurt_error)
	notes.append("K damaged stored mesh: '%s'" % hurt_error)
	checked.append("option kinds (%d options of the wrong kind are each the feature's error with a sentence and leave the body; triangles as a plain list are taken) and a damaged stored mesh says what to do next" % cases.size())
