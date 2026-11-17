@tool
extends RefCounted
## The "pull the handles" hook's sketch section (tests/holo_forge_handles_editor_test.gd). A helper
## of that hook, not a test of its own. With real mouse events (tests/holo_forge_mouse.gd):
##   - the timeline's rollback marker dragged between two chips rolls the design back to there (one
##     step "Roll Back Timeline", the later bodies gone; undo and redo exact) and dragged to the end
##     brings everything back;
##   - in a sketch, a free point dragged lands where the sketch's snapping puts the mouse (the
##     other end of its line stays), as one step "Drag Sketch Geometry" (undo and redo exact); a
##     click on a point without a drag makes no step; a fixed point doesn't move;
##   - a dimension's text dragged moves by the mouse's travel on the sketch plane, as one step
##     "Sketch: Move Dimension", and nothing else moves.

const MODEL_CHECKS := preload("res://tests/holo_forge_handles_model_checks.gd")
const SKETCH_DATA := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const MM := 0.001


static func run(m, hook) -> void:
	if await hook.blank_part() == null:
		return
	await _rollback(m)
	await _sketch(m, hook)


static func _step_named(m, name: String) -> bool:
	return str(m.ws.last_step.get("name", "")) == name and m.undo_name() == "Forge: " + name


## A drag with the left button from a point of the window through points (window coordinates).
static func _drag(m, at: Vector2, points: PackedVector2Array) -> void:
	m.move(at)
	await m.frames(1)
	m.button(at, true)
	await m.frames(1)
	for p in points:
		m.move(p, MOUSE_BUTTON_MASK_LEFT)
		await m.frames(1)
	m.button(points[points.size() - 1] if not points.is_empty() else at, false)
	await m.frames(3)


static func _line(from: Vector2, by: Vector2, steps := 5) -> PackedVector2Array:
	var out := PackedVector2Array()
	for k in range(1, steps + 1):
		out.append((from + by * float(k) / float(steps)).round())
	return out


# --- The timeline's rollback marker --------------------------------------------------------------

static func _rollback(m) -> void:
	var ws = m.ws
	var bodies := []
	for i in 3:
		bodies.append(await MODEL_CHECKS.add_box(m, "Block%d" % i, Vector3(-30 + 22 * i, 0, -5), Vector3(-16 + 22 * i, 10, 5)))
	await m.frames(2)
	var timeline = ws.timeline
	var chips: Array = timeline.get("_chips")
	var marker: Control = timeline.get("_marker")
	if not m.check(chips.size() == 3 and marker != null and marker.is_visible_in_tree(), "The timeline should show three chips and the rollback marker (%d chips)." % chips.size()):
		return
	var begun := {"print": m.doc_print(), "action": m.action()}
	# Between the first and the second chip: one feature stays.
	var gap_x := ((chips[0] as Control).get_global_rect().end.x + (chips[1] as Control).get_global_rect().position.x) * 0.5
	var start: Vector2 = m.center(marker).round()
	# A click on the marker (no drag) changes nothing and leaves it where it was.
	await _drag(m, start, PackedVector2Array())
	m.check(m.action() == int(begun.action) and int(ws.doc.rollback) == -1 and marker.get_index() == chips[2].get_index() + 1 and timeline.marker_preview() == -1,
		"A click on the marker should change nothing (rollback %s, %s)." % [ws.doc.rollback, m.undo_name()])
	# While held, the marker follows the mouse into the gap and the chips past it fade; nothing is
	# rolled back until the release.
	var path := _line(start, Vector2(gap_x - start.x, 0.0))
	m.move(start)
	await m.frames(1)
	m.button(start, true)
	await m.frames(1)
	for p in path:
		m.move(p, MOUSE_BUTTON_MASK_LEFT)
		await m.frames(1)
	await m.frames(1)
	var faded := [(chips[0] as Control).modulate.a, (chips[1] as Control).modulate.a, (chips[2] as Control).modulate.a]
	m.check(timeline.marker_preview() == 1 and marker.get_index() == chips[1].get_index() - 1 and marker.get_global_rect().position.x > (chips[0] as Control).get_global_rect().end.x - 1.0
		and marker.get_global_rect().end.x < (chips[1] as Control).get_global_rect().position.x + 1.0,
		"While dragged, the marker should sit in the gap after the first chip (preview %d, at child %d)." % [timeline.marker_preview(), marker.get_index()])
	m.check(is_equal_approx(faded[0], 1.0) and is_equal_approx(faded[1], timeline.ROLLED_ALPHA) and is_equal_approx(faded[2], timeline.ROLLED_ALPHA),
		"While dragged, the chips past the marker should fade (%s)." % [faded])
	m.check(int(ws.doc.rollback) == -1 and m.action() == int(begun.action) and (ws.result.get("bodies", {}) as Dictionary).size() == 3,
		"Nothing should roll back before the release (rollback %s)." % ws.doc.rollback)
	m.button(path[path.size() - 1], false)
	await m.frames(3)
	m._counted()
	m.check(int(ws.doc.rollback) == 1 and m.action() == int(begun.action) + 1 and _step_named(m, "Roll Back Timeline"),
		"The marker dragged after the first chip should roll back to one feature as one step (rollback %s, %s)." % [ws.doc.rollback, m.undo_name()])
	var shown: Dictionary = ws.result.get("bodies", {})
	m.check(shown.has(bodies[0]) and not shown.has(bodies[1]) and not shown.has(bodies[2]), "Rolled back, only the first block should be built (%s)." % [shown.keys()])
	var rolled: String = m.doc_print()
	await m.undo()
	m.check(m.doc_print() == str(begun.print) and int(ws.doc.rollback) == -1, "Undo should bring the whole timeline back exactly.")
	await m.redo()
	m.check(m.doc_print() == rolled, "Redo should roll it back again exactly.")
	# Back to the end: everything again.
	start = m.center(timeline.get("_marker")).round()
	var end_x := (chips[2] as Control).get_global_rect().end.x + 6.0
	await _drag(m, start, _line(start, Vector2(end_x - start.x, 0.0)))
	m._counted()
	m.check(int(ws.doc.rollback) == -1 and (ws.result.get("bodies", {}) as Dictionary).size() == 3, "The marker dragged past the last chip should build every block again (rollback %s)." % ws.doc.rollback)


# --- A sketch's points and dimension text --------------------------------------------------------

static func _sketch(m, hook) -> void:
	var ws = m.ws
	var ids := {}
	ws.change("Handles Test: Sketch", func() -> void:
		var f: Resource = ws.doc.add_feature("sketch", "Sketch", {}, SKETCH_DATA.new_options({"origin": Vector3(0, 0.03, 0), "x": Vector3.RIGHT, "y": Vector3.UP}, "frame"))
		var s = SKETCH_DATA.new(f, ws.doc)
		ids["a"] = s.add_point(Vector2(10, 10) * MM)
		ids["b"] = s.add_point(Vector2(40, 22) * MM)
		ids["line"] = s.add_line(ids.a, ids.b)
		ids["fixed"] = s.add_point(Vector2(30, -12) * MM, true)
		ids["q1"] = s.add_point(Vector2(-40, 0) * MM)
		ids["q2"] = s.add_point(Vector2(-15, 0) * MM)
		ids["q_line"] = s.add_line(ids.q1, ids.q2)
		ids["dim"] = s.add_constraint("distance", [ids.q1, ids.q2], "25 mm")
		ids["sketch"] = f.id)
	await m.frames(2)
	ws.edit_feature(str(ids.sketch))
	await m.frames(3)
	var editor = ws.sketch_editor
	if not m.check(editor.active, "The sketch should open for editing."):
		return
	await m.clear_view([Vector3(0.04, 0.052, 0), Vector3(-0.04, 0.03, 0), Vector3(0.03, 0.018, 0)])
	await m.frames(2)
	var s = editor.sketch()
	await hook.shot("handles_sketch.png")
	# A free point dragged: it goes where the snapping puts the mouse; the line's other end stays.
	var a0: Vector2 = s.point(ids.a)
	var b_at: Vector2 = (ws.viewport.project(s.to_world(s.point(ids.b))) as Vector2).round()
	var begun := {"print": m.doc_print(), "action": m.action()}
	var path := _line(m.g(b_at), Vector2(36.0, -22.0))
	var last: Vector2 = path[path.size() - 1] - m.g(Vector2.ZERO)
	await _drag(m, m.g(b_at), path)
	m._counted()
	s = editor.sketch()
	var want: Vector2 = editor.snap_at(last).pos
	m.check(s.point(ids.b).distance_to(want) < 1e-9 and s.point(ids.b).distance_to(Vector2(40, 22) * MM) > 1e-4,
		"The dragged point should land where the mouse snaps (%s, expected %s)." % [s.point(ids.b), want])
	m.check(s.point(ids.a).distance_to(a0) < 1e-9, "The line's other end should stay (%s, was %s)." % [s.point(ids.a), a0])
	m.check(m.action() == int(begun.action) + 1 and _step_named(m, "Drag Sketch Geometry"), "The point drag should be one step named Drag Sketch Geometry (%s)." % m.undo_name())
	var dragged: String = m.doc_print()
	await m.undo()
	m.check(m.doc_print() == str(begun.print), "Undo should put the point back exactly.")
	await m.redo()
	m.check(m.doc_print() == dragged, "Redo should move the point again exactly.")
	# A click on a point (no drag) selects it and makes no step.
	s = editor.sketch()
	var before: int = m.action()
	await m.click_view(ws.viewport.project(s.to_world(s.point(ids.a))))
	m.check(m.action() == before and m.doc_print() == dragged, "A click on a point without a drag should make no undo step (%d -> %d, %s)." % [before, m.action(), m.undo_name()])
	# A fixed point stays where it is.
	var fixed_at: Vector2 = (ws.viewport.project(s.to_world(s.point(ids.fixed))) as Vector2).round()
	await _drag(m, m.g(fixed_at), _line(m.g(fixed_at), Vector2(30.0, 20.0)))
	m._counted()
	s = editor.sketch()
	m.check(s.point(ids.fixed).distance_to(Vector2(30, -12) * MM) < 1e-12 and m.action() == before, "A fixed point should not move under a drag (%s)." % s.point(ids.fixed))
	# The dimension's text: it moves by the mouse's travel on the sketch plane; nothing else does.
	var hits: Array = editor.get("_dim_hits")
	var text_at := Vector2.INF
	for entry in hits:
		if int(entry.id) == int(ids.dim):
			text_at = (entry.text_center as Vector2).round()
	if not m.check(text_at.is_finite() and str(editor.hit(text_at).get("kind", "")) == "constraint", "The dimension's text should be on screen and take a press (%s)." % [editor.hit(text_at) if text_at.is_finite() else "off screen"]):
		return
	var offset0: Vector2 = s.constraint(ids.dim).get("offset", Vector2.ZERO)
	var q0 := [s.point(ids.q1), s.point(ids.q2)]
	begun = {"print": m.doc_print(), "action": m.action()}
	var dim_path := _line(m.g(text_at), Vector2(28.0, 24.0))
	var dim_last: Vector2 = dim_path[dim_path.size() - 1] - m.g(Vector2.ZERO)
	var origin: Vector3 = s.to_world(Vector2.ZERO)
	var press_hit: Variant = ws.viewport.plane_hit(text_at, origin, s.normal())
	var last_hit: Variant = ws.viewport.plane_hit(dim_last, origin, s.normal())
	await _drag(m, m.g(text_at), dim_path)
	m._counted()
	s = editor.sketch()
	if press_hit is Vector3 and last_hit is Vector3:
		var travel: Vector2 = s.to_plane(last_hit) - s.to_plane(press_hit)
		var offset: Vector2 = s.constraint(ids.dim).get("offset", Vector2.ZERO)
		m.check((offset - offset0).distance_to(travel) < 1e-9 and travel.length() > 1e-4, "The dimension's text should move by the mouse's travel on the plane (%s, expected %s)." % [offset - offset0, travel])
	m.check(s.point(ids.q1) == q0[0] and s.point(ids.q2) == q0[1], "Moving a dimension's text should move no geometry.")
	m.check(m.action() == int(begun.action) + 1 and _step_named(m, "Sketch: Move Dimension"), "The text drag should be one step named Sketch: Move Dimension (%s)." % m.undo_name())
	var moved: String = m.doc_print()
	await m.undo()
	m.check(m.doc_print() == str(begun.print), "Undo should put the dimension's text back exactly.")
	await m.redo()
	m.check(m.doc_print() == moved, "Redo should move the text again exactly.")
