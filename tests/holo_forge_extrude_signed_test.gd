extends SceneTree
## Extrude goes both ways and joins or cuts by itself, with real mouse and key events. A profile on
## a box's top face: a typed "-10 mm" cuts into the box (one body, smaller); the distance arrow
## dragged back past zero gives a negative distance and a cut; a positive distance joins the box.
## In an empty design it makes a new body (a negative one, with nothing to cut, goes the other way).
## While the Extrude is open its own preview faces can't be hovered or picked, and a click on them
## leaves the profile selection as it was. The Operation list shows what the automatic operation
## does (Join, Cut, New Body); one picked there by hand stays, whatever the distance does next.
## While it joins or cuts, the view draws the piece it adds (green) or takes away (red). A box's
## side face picked as the profile joins the box at that face, even pulled 20 m.
##
## godot --headless --path . --script res://tests/holo_forge_extrude_signed_test.gd

const WORKSPACE := preload("res://addons/holo_forge/ui/forge_workspace.gd")
const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const CATALOG := preload("res://addons/holo_forge/tools/catalog.gd")
const SKETCH := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const OPERATIONS := preload("res://addons/holo_forge/core/operations.gd")

var failures: Array[String] = []
var ws: Control


func _init() -> void:
	call_deferred("run")


func run() -> void:
	create_timer(240.0).timeout.connect(func() -> void:
		print("FAIL holo_forge_extrude_signed: timed out ", failures)
		quit(1))
	root.size = Vector2i(1600, 1000)
	ws = WORKSPACE.new()
	root.add_child(ws)
	ws.size = Vector2(1500, 950)
	for i in 3:
		await process_frame
	if ws.kernel == null:
		_expect(false, "The native kernel should load.")
	else:
		await _check_typed_cut()
		await _check_dragged_cut()
		await _check_join()
		await _check_empty_design()
		await _check_own_faces()
		await _check_override()
		await _check_face_profile()
		await _check_cut_faces_pickable()
	print("PASS holo_forge_extrude_signed: a typed negative distance cuts the box it sits on, the arrow drags past zero into a cut, a positive one joins, an empty design gets a new body, the Extrude's own faces can't be hovered or picked, and the Operation list shows Join/Cut/New Body while a hand-picked one stays, the added or cut piece shows, and a face profile joins its box at any length." \
		if failures.is_empty() else "FAIL holo_forge_extrude_signed")
	quit(0 if failures.is_empty() else 1)


## A 50 mm box with a 20 x 10 mm rectangle sketched on its top face; returns [box id, top y, volume].
func _box_with_profile() -> Array:
	await _new_part()
	ws.run_tool(CATALOG.find("solid.create.box"))
	ws.accept_command()
	await _frames(2)
	var box := str(ws.result.bodies.keys()[0])
	var shape: RefCounted = ws.result.bodies[box].shape
	var top: float = (shape.bbox() as AABB).end.y
	await _rectangle(SKETCH.face_plane(Vector3(0, top, 0), Vector3.UP), "", Vector3(-0.01, top, 0.005), Vector3(0.01, top, -0.005))
	await _home()
	return [box, top, float(shape.volume())]


## The slanted home view (so the distance arrow, straight up, shows a length on screen), fitted.
func _home() -> void:
	ws.viewport.home()
	await _frames(1)
	ws.viewport.fit()
	await _frames(2)


func _check_typed_cut() -> void:
	var made := await _box_with_profile()
	await _extrude(Vector3(0.002, made[1], -0.001), "-10 mm")
	var feature: Resource = ws.doc.features.back()
	var error := str(ws.result.get("errors", {}).get(feature.id, ""))
	_expect(error == "" and ws.result.bodies.size() == 1 and ws.result.bodies.has(made[0]), "A typed -10 mm should cut the box and leave one body (error '%s', %d bodies)." % [error, ws.result.bodies.size()])
	_expect(str(feature.options.get("operation", "")) == OPERATIONS.AUTO, "A plain Extrude should be Join, Cut or New Body (%s)." % feature.options.get("operation", ""))
	if ws.result.bodies.has(made[0]):
		var volume: float = ws.result.bodies[made[0]].shape.volume()
		_expect(absf(volume - (made[2] - 0.02 * 0.01 * 0.01)) < 1e-12, "The box should lose 20 x 10 x 10 mm (%.3f mm3, was %.3f)." % [volume * 1e9, made[2] * 1e9])


func _check_dragged_cut() -> void:
	var made := await _box_with_profile()
	ws.run_tool(CATALOG.find("solid.create.extrude"))
	await _frames(2)
	await _click(_screen(Vector3(0.002, made[1], -0.001)))
	# A short pull first, so the arrow is in the fitted view.
	await _set_distance("10 mm")
	ws.viewport.grab_focus()
	await _frames(2)
	var arrow := _arrow()
	_expect(not arrow.is_empty(), "The distance arrow should show.")
	if arrow.is_empty():
		ws.cancel_command()
		return
	var shape: Dictionary = ws.viewport._handle_screen_shape(arrow)
	var a: Vector2 = shape.from
	var b: Vector2 = shape.to
	var from: Vector2 = ws.viewport.global_position + b.lerp(a, 0.1)
	var along: Vector2 = (b - a).normalized()
	# Back past the profile by the arrow's own length again and some.
	await _drag(from, from - along * ((b - a).length() * 2.0 + 60.0))
	var text := str(ws.panel.values.get("distance", ""))
	_expect(_length_of(text) < 0.0, "Dragging the arrow back past zero should give a negative distance (%s)." % text)
	await _key(KEY_ENTER)
	await _frames(3)
	var feature: Resource = ws.doc.features.back()
	var error := str(ws.result.get("errors", {}).get(feature.id, ""))
	_expect(error == "" and ws.result.bodies.size() == 1, "The dragged cut should leave one body (error '%s', %d bodies)." % [error, ws.result.bodies.size()])
	if ws.result.bodies.has(made[0]):
		var volume: float = ws.result.bodies[made[0]].shape.volume()
		var depth := -_length_of(text)
		_expect(volume < made[2] - 1e-12, "The dragged cut should take volume out of the box (%.3f mm3, was %.3f)." % [volume * 1e9, made[2] * 1e9])
		if depth > 0.0 and depth < 0.05:
			_expect(absf(volume - (made[2] - 0.02 * 0.01 * depth)) < 1e-11, "The cut should be 20 x 10 mm x %s deep." % text)


func _check_join() -> void:
	var made := await _box_with_profile()
	await _extrude(Vector3(0.002, made[1], -0.001), "5 mm")
	_expect(ws.result.bodies.size() == 1 and ws.result.get("errors", {}).is_empty(), "A positive Extrude on the box's top should join it (%d bodies, %s)." % [ws.result.bodies.size(), ws.result.get("errors", {})])
	if ws.result.bodies.has(made[0]):
		_expect(absf(float(ws.result.bodies[made[0]].shape.volume()) - (made[2] + 0.02 * 0.01 * 0.005)) < 1e-12, "The box should grow by 20 x 10 x 5 mm.")


func _check_empty_design() -> void:
	await _new_part()
	await _rectangle(SKETCH.ORIGIN_PLANES.xz, "xz", Vector3(-0.02, 0, 0.01), Vector3(0.02, 0, -0.01))
	await _extrude(Vector3(0.005, 0, -0.003), "10 mm")
	var feature: Resource = ws.doc.features.back()
	_expect(ws.result.bodies.size() == 1 and ws.result.get("errors", {}).is_empty(), "In an empty design the Extrude should make a new body (%d bodies, %s)." % [ws.result.bodies.size(), ws.result.get("errors", {})])
	var body := str(feature.options.get("body_id", ""))
	_expect(body != "" and ws.doc.bodies.has(body), "The new body should be registered (%s)." % body)
	var up: AABB = ws.result.bodies[body].shape.bbox() if ws.result.bodies.has(body) else AABB()
	_expect(absf(up.position.y) < 1e-6 and absf(up.end.y - 0.01) < 1e-6, "A positive one should go up 10 mm from the ground (%s)." % up)
	# A negative distance with nothing to cut makes a body on the other side of its sketch.
	await _new_part()
	await _rectangle(SKETCH.ORIGIN_PLANES.xz, "xz", Vector3(-0.02, 0, 0.01), Vector3(0.02, 0, -0.01))
	await _extrude(Vector3(0.005, 0, -0.003), "-10 mm")
	feature = ws.doc.features.back()
	_expect(ws.result.bodies.size() == 1 and ws.result.get("errors", {}).is_empty(), "A negative Extrude with nothing to cut should make its own body (%d bodies, %s)." % [ws.result.bodies.size(), ws.result.get("errors", {})])
	var id := str(feature.options.get("body_id", ""))
	if ws.result.bodies.has(id):
		var down: AABB = ws.result.bodies[id].shape.bbox()
		_expect(absf(down.position.y + 0.01) < 1e-6 and absf(down.end.y) < 1e-6, "It should go down 10 mm from the ground (%s)." % down)


## While the Extrude is open its preview's end cap can't be hovered or picked, and a click on it
## leaves the picked profile as it was.
func _check_own_faces() -> void:
	await _new_part()
	await _rectangle(SKETCH.ORIGIN_PLANES.xz, "xz", Vector3(-0.02, 0, 0.01), Vector3(0.02, 0, -0.01))
	await _home()
	ws.run_tool(CATALOG.find("solid.create.extrude"))
	await _frames(2)
	await _click(_screen(Vector3(0.005, 0, -0.003)))
	await _set_distance("10 mm")
	var feature: Resource = ws.command.feature if ws.command != null else null
	_expect(feature != null, "The Extrude should be open.")
	if feature == null:
		return
	var picked_before: Array = (ws.command_values.get("profiles", []) as Array).duplicate(true)
	_expect(picked_before.size() == 1, "One profile should be picked (%d)." % picked_before.size())
	_expect(ws.panel.shown_choice("operation") == OPERATIONS.NEW_BODY, "With no body to join the list should show New Body (%s)." % ws.panel.shown_choice("operation"))
	var cap := _cap_point(feature)
	var at: Vector2 = ws.viewport.project(cap)
	var hit: Dictionary = ws.viewport.face_hit_at(at)
	var hit_name := ""
	if not hit.is_empty() and ws.result.bodies.has(hit.body) and not bool(hit.get("mesh", false)):
		hit_name = str(ws.result.bodies[hit.body].shape.get_face_names()[int(hit.face)])
	_expect(hit_name.begins_with(str(feature.id) + ":"), "The view should hit the preview's own face there (%s at %s)." % [hit_name, cap])
	_expect((ws.picker.pick(at) as Dictionary).is_empty(), "pick() on the preview's face should give nothing (%s)." % ws.picker.pick(at))
	_move(_screen(cap))
	await _frames(2)
	_expect(ws.picker.hover.is_empty(), "Hovering the preview's face should highlight nothing (%s)." % ws.picker.hover)
	await _click(_screen(cap))
	await _frames(2)
	var picked_after: Array = ws.command_values.get("profiles", [])
	_expect(picked_after == picked_before, "A click on the preview's face should leave the profiles as they were (%s -> %s)." % [picked_before, picked_after])
	# An edge beside one of the preview's faces counts as its own too; another feature's face doesn't.
	_expect(ws.picker._is_own_ref({"kind": "edge", "name": "x1:start|%s:end" % feature.id}), "An edge beside the preview's face should count as its own.")
	_expect(not ws.picker._is_own_ref({"kind": "face", "name": "%sx:end" % feature.id}), "Another feature's face should not.")
	ws.accept_command()
	await _frames(2)
	_expect(ws.result.bodies.size() == 1 and ws.result.get("errors", {}).is_empty(), "OK should still make the body (%s)." % ws.result.get("errors", {}))
	# Once it is closed, its faces pick again (in a new Extrude, as a flat face to extrude).
	ws.run_tool(CATALOG.find("solid.create.extrude"))
	await _frames(2)
	var later: Dictionary = ws.picker.pick(ws.viewport.project(cap))
	_expect(not later.is_empty(), "With a new Extrude open, the earlier body's face should pick again.")
	ws.cancel_command()
	await _frames(1)


## A point on the open Extrude's preview face nearest the camera, inside the profile's outline.
func _cap_point(feature: Resource) -> Vector3:
	for id in ws.result.bodies:
		var body: Dictionary = ws.result.bodies[id]
		if body.get("shape") == null:
			continue
		var box: AABB = body.shape.bbox()
		var eye: Vector3 = ws.viewport.camera_position()
		# The top cap when the camera is above, the bottom one otherwise.
		var y := box.end.y if eye.y > box.get_center().y else box.position.y
		return Vector3(box.get_center().x - box.size.x * 0.3, y, box.get_center().z + box.size.z * 0.2)
	return Vector3.ZERO


## The Operation list shows what the automatic operation does: Join on the box, Cut once the
## distance goes negative. New Body picked there by hand stays, whatever the distance does next.
func _check_override() -> void:
	var made := await _box_with_profile()
	ws.run_tool(CATALOG.find("solid.create.extrude"))
	await _frames(2)
	await _click(_screen(Vector3(0.002, made[1], -0.001)))
	await _frames(3)
	_expect(ws.panel.shown_choice("operation") == OPERATIONS.JOIN and ws.command_values.get("operation") == OPERATIONS.AUTO, "On the box the list should show Join, still automatic (%s, %s)." % [ws.panel.shown_choice("operation"), ws.command_values.get("operation")])
	_expect(_option_texts().find("Join, Cut or New Body") < 0 and _option_texts().has("New Body"), "The list should offer the plain operations only (%s)." % [_option_texts()])
	_expect(_preview_look() == "join", "Joining, the view should draw the piece it adds in green (%s)." % _preview_look())
	await _set_distance("-10 mm")
	_expect(ws.panel.shown_choice("operation") == OPERATIONS.CUT, "Pulled back past zero the list should show Cut (%s)." % ws.panel.shown_choice("operation"))
	_expect(_preview_look() == "cut", "Cutting, the view should draw the piece it takes away in red (%s)." % _preview_look())
	await _pick_operation(OPERATIONS.NEW_BODY)
	_expect(ws.command_values.get("operation") == OPERATIONS.NEW_BODY, "Picking New Body should set it (%s)." % ws.command_values.get("operation"))
	_expect(_preview_look() == "", "A New Body draws as itself, with no added-piece overlay (%s)." % _preview_look())
	await _set_distance("5 mm")
	_expect(ws.panel.shown_choice("operation") == OPERATIONS.NEW_BODY and ws.command_values.get("operation") == OPERATIONS.NEW_BODY, "A distance typed after picking New Body should leave it (%s, %s)." % [ws.panel.shown_choice("operation"), ws.command_values.get("operation")])
	await _set_distance("-10 mm")
	ws.accept_command()
	await _frames(3)
	var feature: Resource = ws.doc.features.back()
	_expect(ws.viewport.command_mesh_count() == 0, "OK should take the overlay away (%d)." % ws.viewport.command_mesh_count())
	_expect(str(feature.options.get("operation", "")) == OPERATIONS.NEW_BODY, "The Operation list should set New Body (%s)." % feature.options.get("operation", ""))
	_expect(ws.result.bodies.size() == 2 and ws.result.get("errors", {}).is_empty(), "New Body should keep the box whole and add a body (%d bodies, %s)." % [ws.result.bodies.size(), ws.result.get("errors", {})])
	if ws.result.bodies.has(made[0]):
		_expect(absf(float(ws.result.bodies[made[0]].shape.volume()) - made[2]) < 1e-12, "The box should be untouched.")
	# Join picked by hand while the list already shows it stays Join when the distance goes negative.
	made = await _box_with_profile()
	ws.run_tool(CATALOG.find("solid.create.extrude"))
	await _frames(2)
	await _click(_screen(Vector3(0.002, made[1], -0.001)))
	await _set_distance("5 mm")
	await _pick_operation(OPERATIONS.JOIN)
	_expect(ws.command_values.get("operation") == OPERATIONS.JOIN, "Picking the Join it shows should make it Join (%s)." % ws.command_values.get("operation"))
	await _set_distance("-10 mm")
	_expect(ws.panel.shown_choice("operation") == OPERATIONS.JOIN, "A picked Join should not turn into Cut (%s)." % ws.panel.shown_choice("operation"))
	ws.accept_command()
	await _frames(3)
	feature = ws.doc.features.back()
	_expect(str(feature.options.get("operation", "")) == OPERATIONS.JOIN and bool(feature.options.get("operation_by_hand", false)), "The feature should keep Join, picked by hand (%s)." % feature.options)
	ws.edit_feature(feature.id)
	await _frames(3)
	_expect(ws.command_values.get("operation") == OPERATIONS.JOIN and ws.panel.shown_choice("operation") == OPERATIONS.JOIN, "Opened again it should still be Join (%s)." % ws.command_values.get("operation"))
	ws.cancel_command()
	await _frames(2)


## A box's side face picked as the profile (as in the user's report "The join doesn't touch any
## solid body"): typed and dragged distances, short and very long, join the box at that face; the
## arrow starts on the face and points out along its normal.
func _check_face_profile() -> void:
	# Views from +X, -X and -Z, so faces whose normals point both ways get pulled.
	for run in [[Vector3(1, 0.7, 0.4), "10 mm"], [Vector3(1, 0.7, 0.4), "20548.5105 mm"], [Vector3(-1, 0.7, -0.4), "20548.5105 mm"], [Vector3(-0.4, 0.7, -1), "20548.5105 mm"], [Vector3(-1, 0.7, -0.4), "-10 mm"]]:
		var distance: String = run[1]
		await _new_part()
		ws.run_tool(CATALOG.find("solid.create.box"))
		ws.accept_command()
		await _frames(2)
		var box := str(ws.result.bodies.keys()[0])
		var shape: RefCounted = ws.result.bodies[box].shape
		var bounds: AABB = shape.bbox()
		var before: float = shape.volume()
		ws.viewport.look_from(run[0])
		ws.viewport.fit()
		await _frames(2)
		# The side face turned towards the camera.
		var eye: Vector3 = ws.viewport.camera_position()
		var normal := Vector3.RIGHT if eye.x > bounds.get_center().x else Vector3.LEFT
		if absf(eye.z - bounds.get_center().z) > absf(eye.x - bounds.get_center().x):
			normal = Vector3.BACK if eye.z > bounds.get_center().z else Vector3.FORWARD
		var on_face := bounds.get_center() + normal * bounds.size * 0.5 + Vector3(0, bounds.size.y * 0.1, 0)
		ws.run_tool(CATALOG.find("solid.create.extrude"))
		await _frames(2)
		await _click(_screen(on_face))
		await _frames(2)
		var picks: Array = ws.command_values.get("profiles", [])
		_expect(picks.size() == 1 and str(picks[0].get("kind", "")) == "face", "A click on the box's side should pick that face (%s)." % [picks])
		await _set_distance("10 mm")
		_check_face_arrow(normal, bounds, "10 mm")
		_expect(ws.panel.shown_choice("operation") == OPERATIONS.JOIN, "The list should show Join (%s)." % ws.panel.shown_choice("operation"))
		await _set_distance(distance)
		# (The Join swallows the pulled face, and a Cut takes it away: the arrow stays all the same.)
		_check_face_arrow(normal, bounds, distance)
		var cuts := distance.begins_with("-")
		var feature: Resource = ws.command.feature if ws.command != null else null
		var error := str(ws.result.get("errors", {}).get(feature.id, "")) if feature != null else "no command"
		_expect(error == "", "A %s extrude of the box's %s face should %s it, previewed (%s)." % [distance, normal, "cut" if cuts else "join", error])
		_expect(ws.panel.shown_choice("operation") == (OPERATIONS.CUT if cuts else OPERATIONS.JOIN), "The list should show %s (%s)." % ["Cut" if cuts else "Join", ws.panel.shown_choice("operation")])
		await _key(KEY_ENTER)
		await _frames(3)
		feature = ws.doc.features.back()
		error = str(ws.result.get("errors", {}).get(feature.id, ""))
		var length := _length_of(distance)
		var face_area: float = (bounds.size.x * bounds.size.y * bounds.size.z) / absf(bounds.size.dot(normal))
		_expect(error == "" and ws.result.bodies.size() == 1, "A %s extrude of the box's %s face should %s it (error '%s', %d bodies)." % [distance, normal, "cut" if cuts else "join", error, ws.result.bodies.size()])
		if ws.result.bodies.has(box):
			var volume: float = ws.result.bodies[box].shape.volume()
			_expect(absf(volume - (before + face_area * length)) <= 1e-9 * maxf(1.0, volume * 1e3), "The box should change by the face x %s (%.3f mm3, expected %.3f)." % [distance, volume * 1e9, (before + face_area * length) * 1e9])
	# The arrow dragged out from a face joins too.
	await _new_part()
	ws.run_tool(CATALOG.find("solid.create.box"))
	ws.accept_command()
	await _frames(2)
	var box2 := str(ws.result.bodies.keys()[0])
	var top: float = (ws.result.bodies[box2].shape.bbox() as AABB).end.y
	var start_volume: float = ws.result.bodies[box2].shape.volume()
	await _home()
	ws.run_tool(CATALOG.find("solid.create.extrude"))
	await _frames(2)
	await _click(_screen(Vector3(0.01, top, 0.01)))
	await _set_distance("10 mm")
	ws.viewport.grab_focus()
	await _frames(2)
	var handle := _arrow()
	_expect(not handle.is_empty(), "The top face's Extrude should show its distance arrow (handles %s)." % [ws.viewport.handles])
	if not handle.is_empty():
		var screen_shape: Dictionary = ws.viewport._handle_screen_shape(handle)
		var a: Vector2 = screen_shape.from
		var b: Vector2 = screen_shape.to
		var from: Vector2 = ws.viewport.global_position + b.lerp(a, 0.1)
		await _drag(from, from + (b - a).normalized() * 40.0)
	var dragged := str(ws.panel.values.get("distance", ""))
	await _key(KEY_ENTER)
	await _frames(3)
	var last: Resource = ws.doc.features.back()
	_expect(str(ws.result.get("errors", {}).get(last.id, "")) == "" and ws.result.bodies.size() == 1 and float(ws.result.bodies[box2].shape.volume()) > start_volume + 1e-12, "The top face's arrow dragged out to %s should join the box (%s)." % [dragged, ws.result.get("errors", {})])


## The faces a cut made can be picked for the next Extrude (the user's report: "if I cut material I
## can only select what that shape was previously"). The cut's sketch stays shown, its profile in
## the air over the pocket; a click into the pocket picks the pocket's floor, which cuts deeper
## again, and then the new floor and the first cut's wall. The top face around the pocket still
## picks as the top face, and the cut's profile counts as used by the cut.
func _check_cut_faces_pickable() -> void:
	var made := await _box_with_profile()
	var box: String = made[0]
	var top: float = made[1]
	await _extrude(Vector3(0.002, top, -0.001), "-10 mm")
	var first: Resource = ws.doc.features.back()
	var volume: float = ws.result.bodies[box].shape.volume()
	_expect(absf(volume - (float(made[2]) - 2e-6)) < 1e-12, "The first cut should take 20 x 10 x 10 mm away (%.3f mm3)." % (volume * 1e9))
	_expect(bool(ws.doc.find_feature(str(ws.doc.features[ws.doc.features.size() - 2].id)).options.get("visible", true)), "The cut's sketch should still show.")
	ws.viewport.look_from(Vector3(0.05, 1, 0.08))
	ws.viewport.fit()
	await _frames(2)
	# A new Extrude: a real click on the pocket floor picks the floor face the cut made.
	ws.run_tool(CATALOG.find("solid.create.extrude"))
	await _frames(2)
	await _click(_screen(Vector3(0.002, top - 0.01, -0.001)))
	await _frames(2)
	var picks: Array = ws.command_values.get("profiles", [])
	_expect(picks.size() == 1 and str(picks[0].get("kind", "")) == "face" and str(picks[0].get("name", "")).begins_with(str(first.id) + ":"),
		"A click into the pocket should pick the floor the cut made, not the used sketch profile over it (%s)." % [picks])
	await _set_distance("-5 mm")
	await _key(KEY_ENTER)
	await _frames(3)
	var second: Resource = ws.doc.features.back()
	var after: float = ws.result.bodies[box].shape.volume()
	_expect(str(ws.result.get("errors", {}).get(second.id, "")) == "" and absf(after - (volume - 1e-6)) < 1e-12, "Cutting the floor 5 mm deeper should take 20 x 10 x 5 mm more (%.3f mm3)." % (after * 1e9))
	ws.viewport.look_from(Vector3(0.05, 1, 0.08))
	ws.viewport.fit()
	await _frames(2)
	ws.run_tool(CATALOG.find("solid.create.extrude"))
	await _frames(2)
	var deeper: Dictionary = ws.picker.pick(ws.viewport.project(Vector3(0.002, top - 0.015, -0.001)))
	_expect(str(deeper.get("kind", "")) == "face" and str(deeper.get("name", "")).begins_with(str(second.id) + ":"), "The deeper floor the second cut made should pick (%s)." % [deeper])
	var rim: Dictionary = ws.picker.pick(ws.viewport.project(Vector3(0.02, top, 0.02)))
	_expect(str(rim.get("kind", "")) == "face" and str(rim.get("name", "")).ends_with(":y+"), "The top face around the pocket should still pick (%s)." % [rim])
	# The first cut's wall, seen from the side through the opening.
	ws.viewport.look_from(Vector3(1, 0.6, 0.2))
	ws.viewport.fit()
	await _frames(2)
	var wall: Dictionary = ws.picker.pick(ws.viewport.project(Vector3(-0.01, top - 0.004, 0.0)))
	_expect(str(wall.get("kind", "")) == "face" and str(wall.get("name", "")).begins_with(str(first.id) + ":"), "The pocket's wall the first cut made should pick (%s)." % [wall])
	ws.cancel_command()
	await _frames(2)
	ws.run_tool(CATALOG.find("solid.create.extrude"))
	await _frames(2)
	var sketch_id := ""
	for f in ws.doc.features:
		if f.type == "sketch":
			sketch_id = str(f.id)
	var entries: Array = ws.picker._profile_entries_for(sketch_id)
	_expect(not entries.is_empty() and (entries[0].used_by as Array).has(str(first.id)), "The cut's profile should count as used by it (%s)." % [entries.map(func(e: Dictionary) -> Array: return e.used_by)])
	ws.cancel_command()
	await _frames(2)


## The open Extrude of a box face shows its distance arrow, pointing out along the face's normal
## from the face, with its tip the distance away.
func _check_face_arrow(normal: Vector3, bounds: AABB, distance: String) -> void:
	var arrow := _arrow()
	_expect(not arrow.is_empty(), "A face pulled %s should show the distance arrow (handles %s)." % [distance, ws.viewport.handles])
	if arrow.is_empty():
		return
	var start: Vector3 = arrow.origin - (arrow.direction as Vector3) * float(arrow.get("base", 0.0))
	_expect((arrow.direction as Vector3).is_equal_approx(normal), "The arrow should point out along the face's normal (%s, normal %s)." % [arrow.direction, normal])
	_expect(absf((start - bounds.get_center()).dot(normal) - absf(bounds.size.dot(normal)) * 0.5) < 1e-6, "The arrow should start on the face (%s)." % [arrow])
	var across := (start - bounds.get_center()) - normal * (start - bounds.get_center()).dot(normal)
	_expect(across.length() < bounds.size.length() * 0.5, "The arrow should start within the face (%s)." % [arrow])
	_expect(absf(float(arrow.get("base", 0.0)) - _length_of(distance)) < 1e-9, "The arrow's tip should be %s out (%s)." % [distance, arrow.get("base")])


## "join" or "cut" for the open command's added/removed-piece overlay (by its colour), "" for none.
func _preview_look() -> String:
	var meshes: Array = ws.viewport._command_root.get_children().filter(func(n: Node) -> bool: return not n.is_queued_for_deletion())
	if meshes.size() != 1:
		return "" if meshes.is_empty() else "%d meshes" % meshes.size()
	var color: Color = ((meshes[0] as MeshInstance3D).material_override as StandardMaterial3D).albedo_color
	return "join" if color.g > color.r else "cut"


## Picks an operation in the Operation list as a click on its menu item does.
func _pick_operation(op: String) -> void:
	var option := ws.panel._editors.get("operation") as OptionButton
	if option == null:
		_expect(false, "The Operation list should show.")
		return
	for i in option.item_count:
		if option.get_item_metadata(i) == op:
			option.get_popup().index_pressed.emit(i)
	await _frames(3)


func _option_texts() -> Array:
	var texts := []
	var option := ws.panel._editors.get("operation") as OptionButton
	if option != null:
		for i in option.item_count:
			texts.append(option.get_item_text(i))
	return texts


## Extrude: a click at inside, the distance typed, Enter.
func _extrude(inside: Vector3, distance: String) -> void:
	ws.run_tool(CATALOG.find("solid.create.extrude"))
	await _frames(2)
	await _click(_screen(inside))
	await _set_distance(distance)
	await _key(KEY_ENTER)
	await _frames(3)


## Types a distance into the Distance field, leaving the command open.
func _set_distance(distance: String) -> void:
	await _frames(3)
	var field := ws.panel._editors.get("distance") as LineEdit
	if field == null or not field.is_visible_in_tree():
		_expect(false, "The Distance field should show.")
		return
	await _click(field.get_global_rect().get_center())
	_expect(field.has_focus(), "A click on the Distance field should focus it.")
	await _key(KEY_A, true)
	for ch in distance:
		var event := InputEventKey.new()
		event.keycode = KEY_MINUS if ch == "-" else (KEY_SPACE if ch == " " else OS.find_keycode_from_string(ch))
		event.unicode = ch.unicode_at(0)
		event.pressed = true
		root.push_input(event)
		await process_frame
	# (The value applies as it is typed; the field keeps focus, so Enter then means OK.)
	await _frames(3)


func _arrow() -> Dictionary:
	for handle in ws.viewport.handles:
		if str(handle.get("key", "")) == "distance":
			return handle
	return {}


# --- Helpers ----------------------------------------------------------------------------------

func _new_part() -> void:
	if ws.command != null:
		ws.cancel_command()
	if ws.sketch_editor.active:
		ws.run_action("finish_sketch")
	var part: Node3D = CAD_PART.new()
	part.document = DOCUMENT.new()
	root.add_child(part)
	ws.set_part(part)
	await _frames(3)


func _rectangle(frame: Dictionary, ref: String, a: Vector3, b: Vector3) -> void:
	ws.create_sketch(frame, ref)
	await _frames(2)
	ws.viewport.fit()
	await _frames(2)
	ws.run_tool(CATALOG.find("sketch.create.2-point_rectangle"))
	await _frames(1)
	await _click(_screen(a))
	await _click(_screen(b))
	await _key(KEY_ESCAPE)
	ws.run_action("finish_sketch")
	await _frames(2)
	ws.viewport.fit()
	await _frames(2)


func _length_of(text: String) -> float:
	var number := text.replace("mm", "").replace(" ", "").strip_edges()
	return float(number) / 1000.0 if number.is_valid_float() else 0.0


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _screen(p: Vector3) -> Vector2:
	return ws.viewport.global_position + ws.viewport.project(p)


func _mouse(at: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = at
	event.global_position = at
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	root.push_input(event)


func _move(at: Vector2, held := false, relative := Vector2.ZERO) -> void:
	var event := InputEventMouseMotion.new()
	event.position = at
	event.global_position = at
	event.relative = relative
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
	root.push_input(event)


func _click(at: Vector2) -> void:
	_move(at)
	await process_frame
	_mouse(at, true)
	await process_frame
	_mouse(at, false)
	await process_frame


func _drag(from: Vector2, to: Vector2) -> void:
	_move(from)
	await process_frame
	_mouse(from, true)
	await process_frame
	for i in 8:
		_move(from.lerp(to, (i + 1) / 8.0), true, (to - from) / 8.0)
		await process_frame
	_mouse(to, false)
	await process_frame


func _key(code: Key, ctrl := false) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.ctrl_pressed = ctrl
	event.pressed = true
	root.push_input(event)
	await process_frame
	var up := event.duplicate() as InputEventKey
	up.pressed = false
	root.push_input(up)
	await process_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)
		print("FAIL: ", message)
