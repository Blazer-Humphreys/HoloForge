@tool
extends RefCounted
## In-editor checks for the Mesh tools (Phase 7, stage 3, team M), run by the Mesh editor hook
## (tests/holo_forge_mesh_editor_test.gd, spec 5.5 #13) with the open Forge workspace: one
## scenario per Mesh tool, each started the way the toolbar starts it (the tool's feature command,
## the panel's values, OK), asserting what the tool made, exactly one undo step named
## "Mesh: <Title>", and that undoing it gives the bodies back as they were.
##
## It also runs without the editor (a workspace in a plain scene tree has no undo history): the
## step is then read from the workspace's last step and undone by restoring its state.
##
## var failures: Array = await MESH_CHECKS.run(workspace)   # [] when all pass
## Each failure starts with "Mesh checks: ". The hook greps the log for script errors itself.

const FEATURE_COMMAND := preload("res://addons/holo_forge/tools/feature_command.gd")
const CATALOG := preload("res://addons/holo_forge/tools/catalog.gd")
const SPECS := preload("res://addons/holo_forge/tools/feature_specs.gd")
const INSERT := preload("res://addons/holo_forge/core/features/insert.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")
const MESH_FEATURE := preload("res://addons/holo_forge/core/features/mesh.gd")
const MESH_BODY := preload("res://addons/holo_forge/core/mesh/mesh_body.gd")
const MESH_BLOB := preload("res://addons/holo_forge/core/mesh/mesh_blob.gd")
const MESH_DIRECT_EDIT := preload("res://addons/holo_forge/ui/mesh_direct_edit.gd")
const FIXTURES := preload("res://tests/holo_forge_mesh_fixtures.gd")

const MM := 0.001
const XY := {"kind": "origin", "name": "xy"}


static func run(ws) -> Array:
	var c := Checks.new(ws)
	await c.all()
	return c.fails


class Checks:
	extends RefCounted
	var ws
	var doc: Resource
	var fails: Array = []
	## Body ids of the model the scenarios work on.
	var ball := ""
	var blob := ""
	var pair := ""
	var cube := ""
	var bracket := ""
	var plate := ""
	var box := ""
	var image := ""
	var tools_run := 0

	func _init(p_ws) -> void:
		ws = p_ws
		doc = ws.doc if ws != null else null

	func check(ok: bool, detail: String) -> void:
		if not ok:
			fails.append("Mesh checks: " + detail)
			print("FAIL: Mesh checks: ", detail)

	func frames(n := 1) -> void:
		for i in n:
			await ws.get_tree().process_frame

	func all() -> void:
		if ws == null or doc == null or not ClassDB.class_exists("CadMesh") or ws.kernel == null:
			check(false, "The Forge workspace with a part and the native mesh kernel is needed.")
			return
		if ws.command != null:
			ws.cancel_command()
		var start: Dictionary = doc.snapshot()
		var start_action := _action()
		_setup_model()
		await frames(2)
		check(ws.result.get("errors", {}).is_empty() and _mesh(ball) != null and _mesh(blob) != null and _mesh(bracket) != null, "The checks' model should build (%s)." % str(ws.result.get("errors", {})))
		if _mesh(ball) != null and _mesh(blob) != null and _mesh(bracket) != null:
			await _scenarios()
		# The design goes back to what it was before the checks.
		if ws.command != null:
			ws.cancel_command()
		await _undo_to(start_action, start)
		FIXTURES.remove_file("editor_checks/checker.png")
		print("Mesh checks: %d tools run, %d failure(s)." % [tools_run, fails.size()])

	# --- The model -------------------------------------------------------------------------------

	func _add_mesh(mesh: RefCounted, name: String) -> String:
		var feature: Resource = doc.add_feature("mesh_import", "Mesh", {}, {
			"path": "", "kind": INSERT.KIND_MESH, "units": "mm", "mesh_units": "mm", "linked": false, "split": false,
			"transform": Transform3D.IDENTITY, "operation": OPERATIONS.NEW_BODY, "mesh": MESH_BLOB.from_mesh(mesh),
		})
		var body_id: String = doc.new_body(feature.id)
		feature.options["body_id"] = body_id
		doc.bodies[body_id]["name"] = name
		return body_id

	## One undo step that adds the bodies the scenarios use, well apart from each other.
	func _setup_model() -> void:
		image = FIXTURES.write_png_checker("editor_checks/checker.png", 64)
		var cubes := FIXTURES.two_cubes(Vector3(0.03, 0.0, 0.0))
		ws.change("Mesh Checks Model", func() -> void:
			doc = ws.doc
			ball = _add_mesh(FIXTURES.to_mesh(FIXTURES.icosphere(0.05, 3)), "ChecksBall")
			blob = _add_mesh(FIXTURES.to_mesh(FIXTURES.holed_blob()).transformed(Transform3D(Basis.IDENTITY, Vector3(0.3, 0, 0))), "ChecksBlob")
			pair = _add_mesh(FIXTURES.to_mesh(cubes).transformed(Transform3D(Basis.IDENTITY, Vector3(0.6, 0, 0))), "ChecksPair")
			cube = _add_mesh(FIXTURES.to_mesh(cubes.first).transformed(Transform3D(Basis.IDENTITY, Vector3(0.04, 0, 0))), "ChecksCube")
			bracket = _add_mesh((FIXTURES.l_bracket().mesh as RefCounted).transformed(Transform3D(Basis(Vector3(1, 2, 3).normalized(), 0.7), Vector3(0.9, 0.02, 0.03))), "ChecksBracket")
			plate = _add_mesh(FIXTURES.to_mesh(FIXTURES.open_plate()).transformed(Transform3D(Basis.IDENTITY, Vector3(1.2, 0, 0))), "ChecksPlate")
			var feature: Resource = doc.add_feature("box", "Box", {
				"length": doc.make_input("20 mm", "length"), "height": doc.make_input("20 mm", "length"), "width": doc.make_input("20 mm", "length"),
			}, {"operation": OPERATIONS.NEW_BODY, "position": Vector3(1.5, 0, 0)})
			box = doc.new_body(feature.id)
			feature.options["body_id"] = box)
		doc = ws.doc

	# --- Helpers ---------------------------------------------------------------------------------

	func _mesh(body_id: String) -> RefCounted:
		var entry: Dictionary = ws.result.get("bodies", {}).get(body_id, {})
		return entry.get("shape") if MESH_BODY.is_mesh(entry) else null

	func _pick(body_id: String) -> Dictionary:
		return {"kind": "body", "body": body_id}

	## A face group pick as the panels write it: the name, a point on the group and how the
	## surface faces there (so the rebuild can confirm it).
	func _group(body_id: String, group: String) -> Dictionary:
		var pick := {"kind": "mesh_group", "body": body_id, "group": group}
		var mesh := _mesh(body_id)
		var index := int(mesh.find_face(group)) if mesh != null else -1
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

	func _triangles(body_id: String, triangles: PackedInt32Array) -> Dictionary:
		return {"kind": "mesh_triangles", "body": body_id, "triangles": triangles, "digest": str(_mesh(body_id).digest())}

	func _closed(mesh: RefCounted) -> bool:
		if mesh == null:
			return false
		var found: Dictionary = mesh.check(5.0)
		return bool(found.get("closed", false)) and int(found.get("boundary_edges", -1)) == 0

	## Every body of the last rebuild by content.
	func _contents() -> Dictionary:
		var out := {}
		var bodies: Dictionary = ws.result.get("bodies", {})
		for body_id in bodies:
			var shape: RefCounted = bodies[body_id].shape
			out[body_id] = str(shape.digest()) if MESH_BODY.is_mesh(shape) else "brep:%s" % String.num(float(shape.volume()), 15)
		return out

	## The undo history's position (-1 without the editor).
	func _action() -> int:
		var history: UndoRedo = ws.history()
		return history.get_current_action() if history != null else -1

	## Undoes back to a history position; without the editor, puts the given state back.
	func _undo_to(mark: int, state: Dictionary) -> void:
		var history: UndoRedo = ws.history()
		if history != null:
			var guard := 64
			while history.get_current_action() > mark and guard > 0:
				guard -= 1
				history.undo()
		else:
			ws.doc.restore(state)
			ws.recompute()
		doc = ws.doc
		await frames(2)

	## Runs one tool as the toolbar does: its command, the given panel values, OK. Checks that OK
	## went through as exactly one undo step named "Mesh: <title>", calls verify (Callable() ->
	## String: what is wrong, or ""), then undoes the step and checks the bodies are back.
	func _tool(key: String, values: Dictionary, verify: Callable) -> void:
		var spec: Dictionary = SPECS.get_spec(key)
		var title := str(spec.get("title", key)).get_slice(" (", 0)
		if spec.is_empty():
			check(false, "%s has no panel spec." % key)
			return
		tools_run += 1
		ws.selection.clear()
		ws.mesh_selection.clear()
		var before_state: Dictionary = ws.doc.snapshot()
		var before_contents := _contents()
		var mark := _action()
		var features_before: int = ws.doc.features.size()
		ws.start_command(FEATURE_COMMAND.new(key))
		await frames(2)
		check(ws.command != null and ws.command.is_mesh_tool() and ws.command.feature != null and str(ws.command.feature.options.get("method", "")) == key.get_slice(":", 1),
			"%s should open as a Mesh tool with its feature." % title)
		if ws.command == null:
			return
		var asked: Dictionary = ws.command_values.duplicate(true)
		# No pick comes from the selection: the scenario gives every one.
		for field in ws.command.fields():
			if str(field.get("type", "")) == "selection":
				asked[field.key] = []
		asked.merge(values, true)
		ws.set_command_values(asked)
		await frames(3)
		var feature_id := str(ws.command.feature.id)
		var step_before: Dictionary = ws.last_step
		ws.accept_command()
		await frames(3)
		doc = ws.doc
		var error := str(ws.result.get("errors", {}).get(feature_id, ""))
		check(ws.command == null and error == "", "%s's OK should go through (%s; %s)." % [title, error, ws.last_message])
		if ws.command != null:
			ws.cancel_command()
			await frames(2)
			return
		var history: UndoRedo = ws.history()
		if history != null:
			check(history.get_current_action() == mark + 1, "%s's OK should be exactly one undo step (%d -> %d)." % [title, mark, history.get_current_action()])
		else:
			check(not is_same(ws.last_step, step_before) and (ws.last_step.get("before", {}) as Dictionary).get("features", []).size() == features_before,
				"%s's OK should be one step from the design as it was." % title)
		check(str(ws.last_step.get("name", "")) == "Mesh: " + title, "%s's step should be named Mesh: %s (%s)." % [title, title, ws.last_step.get("name", "")])
		var wrong: String = verify.call()
		check(wrong == "", "%s: %s" % [title, wrong])
		await _undo_to(mark, before_state)
		check(_contents() == before_contents and ws.doc.features.size() == features_before, "Undoing %s should give the bodies back as they were." % title)

	# --- Scenarios -------------------------------------------------------------------------------

	func _scenarios() -> void:
		var ball_mesh := _mesh(ball)
		var ball_count := int(ball_mesh.triangle_count())
		var ball_volume := float(ball_mesh.volume())
		var bodies_before: int = ws.result.bodies.size()
		var bracket_mesh := _mesh(bracket)
		var bracket_groups: PackedStringArray = bracket_mesh.get_face_names()
		var flat := ""
		for i in bracket_groups.size():
			if bool((bracket_mesh.face_info(i) as Dictionary).get("planar", false)) and flat == "":
				flat = bracket_groups[i]
		var patch: PackedInt32Array = ball_mesh.grow(PackedInt32Array([0]), 2)

		await _tool("mesh:tessellate", {"bodies": [_pick(box)], "quality": "medium", "keep_original": true}, func() -> String:
			var made := 0
			for body_id in ws.result.bodies:
				if MESH_BODY.is_mesh(ws.result.bodies[body_id]) and int(ws.result.bodies[body_id].shape.group_count()) == 6:
					made += 1
			return "" if made == 1 and ws.result.bodies.size() == bodies_before + 1 else "a box should become a mesh body of 6 face groups beside it (%d bodies, were %d)" % [ws.result.bodies.size(), bodies_before])

		await _tool("mesh:section_sketch", {"body": [_pick(ball)], "plane": [XY], "fit": false}, func() -> String:
			var sketches := 0
			var sections := 0
			for feature in ws.doc.features:
				if str(feature.type) == "sketch" and str(feature.options.get("note", "")).begins_with("Made from a section of"):
					sketches += 1
				if str(feature.type) == "mesh" and str(feature.options.get("method", "")) == "section_sketch":
					sections += 1
			return "" if sketches == 1 and sections == 0 else "OK should leave one sketch of the section and no mesh feature (%d sketches, %d section features): the workspace must call core/features/mesh.gd add_section_sketch(doc, result, feature) on OK" % [sketches, sections])

		await _tool("mesh:close_holes", {"bodies": [_pick(blob)], "fill": "smooth", "refine": true}, func() -> String:
			return "" if _closed(_mesh(blob)) else "the blob's holes should be closed")

		await _tool("mesh:stitch_remove", {"bodies": [_pick(pair)]}, func() -> String:
			return "" if _mesh(pair) != null and int(_mesh(pair).triangle_count()) == 24 else "two clean cubes should stay as they are")

		await _tool("mesh:wrap", {"bodies": [_pick(blob)], "detail": "1.5", "gap": "26", "offset": "0"}, func() -> String:
			return "" if _closed(_mesh(blob)) and str(_mesh(blob).get_face_names()[0]) == "wrap0" else "the blob should be wrapped into one closed body")

		await _tool("mesh:rebuild", {"bodies": [_pick(cube)], "algorithm": "union"}, func() -> String:
			return "" if _closed(_mesh(cube)) and str(_mesh(cube).get_face_names()[0]) == "rebuild0" else "the cube should be rebuilt closed")

		await _tool("mesh:generate_groups", {"bodies": [_pick(bracket)], "algorithm": "accurate"}, func() -> String:
			return "" if _mesh(bracket) != null and int(_mesh(bracket).group_count()) == bracket_groups.size() and str(_mesh(bracket).get_face_names()[0]) == "g0" else "the bracket should get its %d face groups, named afresh" % bracket_groups.size())

		await _tool("mesh:combine_groups", {"groups": [_group(bracket, bracket_groups[0]), _group(bracket, bracket_groups[1])]}, func() -> String:
			return "" if _mesh(bracket) != null and int(_mesh(bracket).group_count()) == bracket_groups.size() - 1 else "two face groups should become one")

		await _tool("mesh:create_group", {"selection": [_triangles(ball, patch)]}, func() -> String:
			return "" if _mesh(ball) != null and int(_mesh(ball).find_face("user0")) >= 0 else "the picked triangles should become the group user0")

		await _tool("mesh:remesh", {"bodies": [_pick(ball)], "mode": "uniform", "edge_length": "8", "iterations": "5"}, func() -> String:
			return "" if _closed(_mesh(ball)) and str(_mesh(ball).digest()) != str(ball_mesh.digest()) else "the ball should be remeshed to other triangles, closed (%d triangles, were %d; warning '%s')" % [int(_mesh(ball).triangle_count()), ball_count, str(ws.result.warnings.get(ws.doc.features[ws.doc.features.size() - 1].id, ""))])

		await _tool("mesh:reduce", {"bodies": [_pick(ball)], "target": "proportion", "proportion": "50", "algorithm": "adaptive"}, func() -> String:
			var count := int(_mesh(ball).triangle_count()) if _mesh(ball) != null else -1
			return "" if absi(count - ball_count / 2) <= int(0.02 * ball_count / 2.0) + 1 else "the ball should keep half its triangles within 2 %% (%d of %d)" % [count, ball_count])

		await _tool("mesh:plane_cut", {"bodies": [_pick(ball)], "plane": [XY], "type": "trim", "fill": "uniform", "offset": "0"}, func() -> String:
			return "" if _closed(_mesh(ball)) and absf(float(_mesh(ball).volume()) - 0.5 * ball_volume) < 0.01 * ball_volume else "half the ball should be left, closed")

		await _tool("mesh:shell", {"bodies": [_pick(ball)], "thickness": "3", "direction": "inside", "algorithm": "fast"}, func() -> String:
			return "" if _closed(_mesh(ball)) and float(_mesh(ball).volume()) < 0.25 * ball_volume else "the ball should become a 3 mm shell")

		await _tool("mesh:combine", {"target": [_pick(ball)], "tools": [_pick(cube)], "operation": "cut", "keep_tools": false, "new_body": false}, func() -> String:
			return "" if _closed(_mesh(ball)) and float(_mesh(ball).volume()) < ball_volume and not ws.result.bodies.has(cube) else "the cube should be cut out of the ball and be gone")

		await _tool("mesh:smooth", {"bodies": [_pick(bracket)], "strength": "0.5", "iterations": "2", "keep_volume": false}, func() -> String:
			return "" if _mesh(bracket) != null and str(_mesh(bracket).digest()) != str(bracket_mesh.digest()) and int(_mesh(bracket).triangle_count()) == int(bracket_mesh.triangle_count()) else "the bracket should be smoothed, triangle for triangle")

		await _tool("mesh:reverse_normal", {"mode": "whole", "bodies": [_pick(ball)]}, func() -> String:
			return "" if _mesh(ball) != null and float(_mesh(ball).volume()) < 0.0 else "the ball should be turned inside-out")

		await _tool("mesh:erase_fill", {"selection": [_triangles(ball, patch)], "fill": "minimal"}, func() -> String:
			return "" if _closed(_mesh(ball)) and str(_mesh(ball).digest()) != str(ball_mesh.digest()) else "the erased patch should be filled again")

		await _tool("mesh:align", {"source": [_group(bracket, flat)], "to": [XY], "flip": false, "offset": "0"}, func() -> String:
			var moved := _mesh(bracket)
			var info: Dictionary = moved.face_info(int(moved.find_face(flat))) if moved != null else {}
			return "" if moved != null and absf((info.point as Vector3).z) < 1e-8 and ((info.normal as Vector3) + Vector3(0, 0, 1)).length() < 1e-5 else "the bracket's flat group should lie on the XY plane, facing it")

		# (A Depth other than the panel's own first value: a typed value equal to the one the panel
		# chose still follows the picked body.)
		await _tool("mesh:texture_extrude", {"selection": [_group(plate, "g0")], "image": image, "depth": "1.5", "mapping": "box", "tile": "10", "angle": "0", "detail": "0.625"}, func() -> String:
			return "" if _mesh(plate) != null and absf((_mesh(plate).bbox() as AABB).end.y - 1.5 * MM) < 0.03 * MM else "the plate should rise by 1.5 mm (%s mm; inputs %s)" % [(_mesh(plate).bbox() as AABB).end.y * 1000.0, str(ws.doc.features[ws.doc.features.size() - 1].inputs)])

		await _tool("mesh:separate", {"bodies": [_pick(pair)], "by": "components"}, func() -> String:
			return "" if ws.result.bodies.size() == bodies_before + 1 and int(_mesh(pair).triangle_count()) == 12 else "the pair should become two bodies")

		await _tool("mesh:move", {"objects": [_pick(ball)], "move_type": "free", "x": "10", "y": "0", "z": "0", "copy": false}, func() -> String:
			return "" if _mesh(ball) != null and absf((_mesh(ball).bbox() as AABB).get_center().x - 0.01) < 1e-6 else "the ball should move 10 mm along X")

		await _tool("mesh:scale", {"bodies": [_pick(ball)], "uniform": true, "scale": "2"}, func() -> String:
			return "" if _mesh(ball) != null and absf(float(_mesh(ball).volume()) - 8.0 * ball_volume) < 1e-5 * 8.0 * ball_volume else "the ball should have 8 times its volume")

		# Convert Mesh: Faceted (Prismatic and Organic have their own checks with team C's tests).
		if ResourceLoader.exists(MESH_FEATURE.CONVERT_PATH):
			await _tool("mesh:convert_faceted", {"bodies": [_pick(cube)], "merge_flat": true, "result": "new_body"}, func() -> String:
				var solids := 0
				for body_id in ws.result.bodies:
					var entry: Dictionary = ws.result.bodies[body_id]
					if not MESH_BODY.is_mesh(entry) and body_id != box and absf(float(entry.shape.volume()) - 8e-6) < 8e-8:
						solids += 1
				return "" if solids == 1 else "the cube should become a solid of its volume")
		else:
			print("Mesh checks: Convert Mesh is not in this build (core/features/mesh_convert.gd); its scenario is skipped.")

		# Direct Edit's snapshot, as ui/mesh_direct_edit.gd stores it: one step, the body replaced.
		tools_run += 1
		var before_state: Dictionary = ws.doc.snapshot()
		var before_contents := _contents()
		var mark := _action()
		var edited: RefCounted = ball_mesh.delete_triangles(patch)
		ws.change(MESH_DIRECT_EDIT.UNDO_NAME, func() -> void:
			MESH_DIRECT_EDIT.add_snapshot(ws.doc, ball, edited, str(ball_mesh.digest()), PackedStringArray(["delete"])))
		await frames(2)
		check(ws.result.get("errors", {}).is_empty() and _mesh(ball) != null and str(_mesh(ball).digest()) == str(edited.digest()) and str(ws.last_step.get("name", "")) == MESH_DIRECT_EDIT.UNDO_NAME
			and (ws.history() == null or _action() == mark + 1), "Direct Edit's snapshot should replace the body in one step named %s (%s)." % [MESH_DIRECT_EDIT.UNDO_NAME, str(ws.result.get("errors", {}))])
		await _undo_to(mark, before_state)
		check(_contents() == before_contents, "Undoing Direct Edit should give the body back as it was.")
