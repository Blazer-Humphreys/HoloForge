extends SceneTree
## Holo Forge heads-up length and angle fields while drawing lines (sketch_editor.gd), driven with
## real input events pushed through the window (root.push_input: mouse moves and clicks on the
## view, typed keys, Tab, Enter, Esc), as a user would: after the first Line click and a mouse move
## the rubber band shows a length and an angle preview dimension with what they measure; a typed
## digit opens the length box (the dimension value box's look) with the keyboard; Enter locks a
## value (dim_selected) and the band keeps it; the placing click adds the segment and a driving
## length in one "Sketch: Line" step, with its text where the heads-up one was, and the view gets
## the keyboard back; Tab opens and moves to the angle, whose lock turns the next segment by that
## angle from the previous one (a driving angle in the segment's step); invalid text is red and
## refused; Esc closes the boxes and drops the locks, Esc again ends the chain; both locked, Enter
## alone places the segment (the first segment's angle from plane +X, through a level
## construction line); the dark palette styles the boxes and the preview. Rectangles and circles
## the same way: a 2-point and a centre rectangle show width and height (Tab moves between them),
## a 3-point one its first edge's length and then its height, a circle (centre or 2-point) its
## diameter; locks size the rubber band, and the placing click or Enter adds the shape with driving
## horizontal and vertical distances (aligned lengths for the 3-point one) or a diameter in the
## shape's own step, the text where the heads-up dimension was; both palettes.
##
## godot --headless --path . --script res://tests/holo_forge_heads_up_test.gd

const SKETCH := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const THEME := preload("res://addons/holo_forge/ui/forge_theme.gd")
const WORKSPACE := preload("res://addons/holo_forge/ui/forge_workspace.gd")
const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const DIM := preload("res://addons/holo_forge/core/sketch/dimension_layout.gd")
const MM := 0.001
## Where on the plane (mm) the rectangle and circle checks draw, away from the lines.
const AREA := Vector2(300, 300)

var failures: Array[String] = []
var ws: Control
var editor: RefCounted
var _mouse := Vector2.ZERO
## Redundant constraints the shapes' sketch may have (a centre rectangle's own).
var _known_redundant := 0


func _init() -> void:
	call_deferred("run")


func run() -> void:
	create_timer(240.0).timeout.connect(func() -> void:
		print("FAIL holo_forge_heads_up: timed out ", failures)
		quit(1))
	ws = WORKSPACE.new()
	ws.theme_store = {}
	root.add_child(ws)
	ws.size = Vector2(1400, 900)
	await _frames(3)
	if ws.kernel == null:
		_expect(false, "The native kernel should load.")
		quit(1)
		return
	var part: Node3D = CAD_PART.new()
	part.document = DOCUMENT.new()
	root.add_child(part)
	ws.set_part(part)
	await process_frame
	ws.set_theme_mode("light")
	ws.create_sketch(SKETCH.ORIGIN_PLANES.xy, "xy")
	await _frames(2)
	editor = ws.sketch_editor
	editor.ui_scale = 1.0
	ws.viewport.set_view_state({"target": editor.sketch().to_world(Vector2(30, 20) * MM), "distance": 0.16})
	await _frames(2)
	await _check_length_lock()
	await _check_angle_lock()
	await _check_invalid_and_escape()
	await _check_both_locked()
	await _check_dark()
	await _check_rect_2pt()
	await _check_rect_center()
	await _check_rect_3pt()
	await _check_circle_center()
	await _check_circle_2pt()
	await _check_shapes_dark()
	ws.set_part(null)
	part.queue_free()
	ws.queue_free()
	await _frames(2)
	print("PASS holo_forge_heads_up: rubber-band length and angle previews with measured values, a typed digit opens the length box with the keyboard, Enter locks (dim_selected) and the band keeps it, the click adds the segment and its driving length in one Sketch: Line step with the text where the heads-up one was and the view keyboard back, Tab and a locked angle from the previous segment (driving angle with rays, same step), invalid text red and refused, Esc closes and drops locks, Esc again ends the chain, Enter with both locked places the segment (first segment from plane +X), dark palette; rectangles (2-point, centre, 3-point) show width and height (Tab between them), locks size the rubber band and add driving horizontal/vertical (3-point: aligned) dimensions in the shape's step; circles (centre, 2-point) a diameter field adding a driving diameter; invalid and Esc; both palettes" \
		if failures.is_empty() else "FAIL holo_forge_heads_up %s" % [failures])
	quit(0 if failures.is_empty() else 1)


func _expect(ok: bool, detail: String) -> void:
	if not ok:
		failures.append(detail)
		push_error(detail)
		print("FAIL: ", detail)


func _frames(count: int) -> void:
	for i in count:
		await process_frame


# --- Real input --------------------------------------------------------------------------------

## A sketch-plane point (mm) in the window's coordinates.
func _at(plane_mm: Vector2) -> Vector2:
	var local: Vector2 = ws.viewport.project(editor.sketch().to_world(plane_mm * MM))
	return (ws.viewport.overlay() as Control).get_global_transform_with_canvas() * local


func _move(plane_mm: Vector2) -> void:
	var at := _at(plane_mm)
	var event := InputEventMouseMotion.new()
	event.position = _window(at)
	event.global_position = _window(at)
	event.relative = _window(at) - _window(_mouse)
	_mouse = at
	root.push_input(event)
	await _frames(2)


## A point of the root viewport in window coordinates (a headless window is small and stretched).
func _window(at: Vector2) -> Vector2:
	return root.get_final_transform() * at


func _click(plane_mm: Vector2) -> void:
	await _move(plane_mm)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		event.position = _window(_mouse)
		event.global_position = _window(_mouse)
		root.push_input(event)
		await process_frame
	await _frames(2)


## Presses and releases a key (unicode for the character it types, 0 for none).
func _key(keycode: Key, unicode := 0) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = keycode
		event.physical_keycode = keycode
		event.unicode = unicode if pressed else 0
		event.pressed = pressed
		root.push_input(event)
		await process_frame
	await process_frame


## Types text one key at a time ("0"-"9", ".", "-").
func _type(text: String) -> void:
	for i in text.length():
		var c := text[i]
		var keycode: Key = KEY_PERIOD if c == "." else (KEY_MINUS if c == "-" else (KEY_0 + int(c)) as Key)
		await _key(keycode, c.unicode_at(0))
	await _frames(1)


# --- Helpers ----------------------------------------------------------------------------------

func _box(field: String) -> LineEdit:
	return editor._heads_up[field]


func _lines() -> Array:
	return editor.sketch().entities().filter(func(e: Dictionary) -> bool: return e.type == "line")


func _length(s: SKETCH, line: int) -> float:
	var e: Dictionary = s.entity(line)
	var a: PackedFloat64Array = s.point_xy(int(e.p1))
	var b: PackedFloat64Array = s.point_xy(int(e.p2))
	return sqrt(pow(b[0] - a[0], 2) + pow(b[1] - a[1], 2))


## The direction from point a to point b in double precision.
func _dir(s: SKETCH, a: int, b: int) -> Vector2:
	var pa: PackedFloat64Array = s.point_xy(a)
	var pb: PackedFloat64Array = s.point_xy(b)
	return Vector2(pb[0] - pa[0], pb[1] - pa[1]).normalized()


func _dimensions_on(line: int) -> Array:
	return editor.sketch().constraints().filter(func(c: Dictionary) -> bool: return c.has("key") and (c.refs as Array).has(line))


func _expression(c: Dictionary) -> String:
	return str(editor.sketch().feature.inputs.get(c.key, {}).get("expression", ""))


## True when two document snapshots hold the same sketch (its entities, constraints and parameters).
func _same(a: Dictionary, b: Dictionary) -> bool:
	return _sketch_text(a) == _sketch_text(b) and _sketch_text(a) != ""


func _sketch_text(snapshot: Dictionary) -> String:
	for feature: Resource in snapshot.get("features", []):
		if feature.id == editor.feature_id:
			return str(feature.options) + str(feature.inputs)
	return ""


## A sketch-plane point (mm) on the view (the overlay's own coordinates).
func _local(plane_mm: Vector2) -> Vector2:
	return ws.viewport.project(editor.sketch().to_world(plane_mm * MM))


func _hit_center(id: int) -> Vector2:
	for entry: Dictionary in editor._dim_hits:
		if int(entry.id) == id:
			return entry.text_center
	return Vector2.INF


# --- Checks -----------------------------------------------------------------------------------

## The first segment: previews, a typed 40 locked by Enter, the click adds a 40 mm line with its
## driving length in one step.
func _check_length_lock() -> void:
	var p: Dictionary = THEME.palette("light")
	editor.start_tool("line")
	await _move(Vector2(10, 10))
	await _click(Vector2(10, 10))
	_expect(editor.tool == "line" and editor.tool_points.size() == 1, "The first click places the line's first point (%s)." % [editor.tool_points])
	await _move(Vector2(40, 25))
	var log: Dictionary = editor._dim_draw_log
	var length: Dictionary = log.get(editor.HEADS_UP_IDS.length, {})
	var angle: Dictionary = log.get(editor.HEADS_UP_IDS.angle, {})
	var expected_length := DIM.canvas_number(Vector2(30, 15).length() * MM, "length", "mm")
	var expected_angle := DIM.canvas_number(atan2(15.0, 30.0), "angle", "mm")
	_expect(length.get("state", "") == "preview" and length.get("text", "") == expected_length and length.get("color") == p.dim_preview,
		"The rubber band shows its length as a preview dimension (%s, expected %s)." % [length, expected_length])
	_expect(angle.get("state", "") == "preview" and angle.get("text", "") == expected_angle,
		"The rubber band shows its angle from plane +X as a preview dimension (%s, expected %s)." % [angle, expected_angle])
	var preview_center: Vector2 = editor._heads_up_centers.get("length", Vector2.INF)
	_expect(preview_center.is_finite() and editor._heads_up_centers.angle.is_finite(), "Both heads-up dimensions are laid out on screen.")
	# The length's text is 24 px to the band's left (above this one).
	var a := _local(Vector2(10, 10))
	var b := _local(Vector2(40, 25))
	var left := (b - a).normalized().orthogonal()
	var off := (preview_center - (a + b) * 0.5).dot(left)
	_expect(off > 20.0 and off < 42.0, "The length's dimension line sits 24 px to the band's left, its text just past it (%f px)." % off)

	# A typed digit opens the length box, the keyboard in it; the angle box shows what it measures.
	await _type("4")
	var box := _box("length")
	_expect(box.visible and box.has_focus() and box.text == "4" and _box("angle").visible, "Typing 4 opens the length box with the keyboard (visible %s, focus %s, text '%s')." % [box.visible, box.has_focus(), box.text])
	_expect(_box("angle").text == "26.6 deg", "The angle box shows the measured angle (%s)." % _box("angle").text)
	_expect((box.get_theme_stylebox("normal") as StyleBoxFlat).bg_color == p.dim_box_back and (box.get_theme_stylebox("focus") as StyleBoxFlat).border_color == p.dim_box_focus
		and box.get_theme_color("font_color") == p.dim_box_text, "The heads-up box has the value box's look.")
	await _type("0")
	_expect(box.text == "40" and not editor._heads_up_state.length.locked, "Typing goes on in the box (%s)." % box.text)
	await _frames(2)
	_expect((box.position + box.size * 0.5).distance_to(editor._heads_up_centers.length) <= 2.0 and (_box("angle").position + _box("angle").size * 0.5).distance_to(editor._heads_up_centers.angle) <= 2.0,
		"The boxes sit on their dimensions' text (%s vs %s)." % [box.position + box.size * 0.5, editor._heads_up_centers.length])
	await _key(KEY_ENTER)
	_expect(editor._heads_up_state.length.locked and absf(float(editor._heads_up_state.length.value) - 0.04) < 1e-12 and box.visible and box.has_focus()
		and box.get_theme_color("font_color") == p.dim_selected, "Enter locks 40 mm, shown in dim_selected, the box keeps the keyboard (%s, focus %s)." % [editor._heads_up_state.length, box.has_focus()])
	await _move(Vector2(40, 25))
	_expect(editor._dim_draw_log.get(editor.HEADS_UP_IDS.length, {}).get("color") == p.dim_selected, "The locked length's dimension is drawn in dim_selected.")
	var band_end: Vector2 = editor._line_end(editor.mouse_plane)
	_expect(absf(band_end.distance_to(Vector2(0.01, 0.01)) - 0.04) < 1e-6, "The rubber band keeps the locked 40 mm (%s)." % band_end)
	var locked_center: Vector2 = editor._heads_up_centers.length

	# The click adds the segment and its driving length in one step.
	var before: Dictionary = ws.doc.snapshot()
	var lines_before := _lines().size()
	await _click(Vector2(40, 25))
	var lines := _lines()
	_expect(lines.size() == lines_before + 1, "The click adds one segment (%d)." % lines.size())
	if lines.size() != lines_before + 1:
		return
	var s: SKETCH = editor.sketch()
	var line := int(lines[lines.size() - 1].id)
	var dims := _dimensions_on(line)
	_expect(absf(_length(s, line) - 0.04) < 1e-7 and dims.size() == 1 and dims[0].type == "length" and dims[0].get("driving", true) and _expression(dims[0]) == "40",
		"The segment is 40 mm with a driving length dimension of 40 (%f, %s)." % [_length(s, line), dims])
	_expect(ws.last_step.get("name", "") == "Sketch: Line" and _same(ws.last_step.get("before", {}), before),
		"The segment and its dimension are one Sketch: Line step (%s)." % ws.last_step.get("name", ""))
	_expect(not box.visible and not _box("angle").visible and (ws.viewport.overlay() as Control).has_focus() and editor.tool == "line" and editor.tool_points.size() == 1,
		"The boxes close, the view has the keyboard back and the chain goes on (focus %s)." % root.gui_get_focus_owner())
	await _move(Vector2(40, 25) + Vector2(10, 30))
	var placed := _hit_center(int(dims[0].id)) if not dims.is_empty() else Vector2.INF
	_expect(placed.is_finite() and placed.distance_to(locked_center) <= 2.0, "The dimension's text is where the heads-up length was drawn (%s vs %s)." % [placed, locked_center])


## The second segment: Tab opens the angle field, 30 + Enter locks it; the click makes a segment 30
## degrees from the first (measured at their corner) with a driving angle in the same step.
func _check_angle_lock() -> void:
	var s: SKETCH = editor.sketch()
	var first: Dictionary = _lines()[_lines().size() - 1]
	var corner := int(first.p2)
	await _move(Vector2(60, 60))
	var shown: Dictionary = editor._dim_draw_log.get(editor.HEADS_UP_IDS.angle, {})
	var back := _dir(s, corner, int(first.p1))
	var to_mouse := (Vector2(60, 60) * MM - s.point(corner)).normalized()
	var expected := DIM.canvas_number(absf(back.angle_to(to_mouse)), "angle", "mm")
	_expect(shown.get("state", "") == "preview" and shown.get("text", "") == expected, "The next segment's angle is measured from the previous one (%s, expected %s)." % [shown, expected])
	await _key(KEY_TAB)
	var box := _box("angle")
	_expect(box.visible and box.has_focus() and _box("length").visible and not _box("length").has_focus() and box.get_selected_text() == box.text,
		"Tab opens the boxes with the keyboard in the angle, its value selected (focus %s, '%s')." % [box.has_focus(), box.get_selected_text()])
	await _type("30")
	await _key(KEY_ENTER)
	_expect(editor._heads_up_state.angle.locked and absf(float(editor._heads_up_state.angle.value) - deg_to_rad(30.0)) < 1e-12 and not editor._heads_up_state.length.locked,
		"30 + Enter locks the angle only (%s)." % [editor._heads_up_state.angle])
	# Tab goes back to the length and on to the angle again.
	await _key(KEY_TAB)
	_expect(_box("length").has_focus() and not box.has_focus(), "Tab moves to the length field.")
	await _key(KEY_TAB)
	_expect(box.has_focus(), "Tab moves back to the angle field.")
	var before: Dictionary = ws.doc.snapshot()
	await _click(Vector2(60, 60))
	s = editor.sketch()
	var lines := _lines()
	var second: Dictionary = lines[lines.size() - 1]
	_expect(int(second.p1) == corner, "The second segment starts at the first one's end.")
	var opening := rad_to_deg(absf(_dir(s, corner, int(first.p1)).angle_to(_dir(s, corner, int(second.p2)))))
	_expect(absf(opening - 30.0) < 1e-4, "The second segment is 30° from the first at their corner (%f°)." % opening)
	var angles: Array = s.constraints().filter(func(c: Dictionary) -> bool: return c.get("type", "") == "angle" and c.has("key"))
	_expect(angles.size() == 1 and (angles[0].refs as Array).has(int(second.id)) and (angles[0].refs as Array).has(int(first.id)) and angles[0].has("rays")
		and _expression(angles[0]) == "30" and absf(editor._sweep(s, angles[0].refs, angles[0].rays) - deg_to_rad(30.0)) < 1e-6,
		"A driving 30° angle with rays joins the two segments (%s)." % [angles])
	_expect(ws.last_step.get("name", "") == "Sketch: Line" and _same(ws.last_step.get("before", {}), before), "The segment and its angle are one Sketch: Line step.")
	var solve: Dictionary = ws.result.sketches[editor.feature_id].solve
	_expect(bool(solve.get("ok", false)) and (solve.get("conflicting", []) as Array).is_empty() and (solve.get("redundant", []) as Array).is_empty(), "The sketch still solves cleanly (%s)." % [solve])


## Invalid text is red and Enter is refused; Esc closes the boxes (no lock), Esc again ends the chain.
func _check_invalid_and_escape() -> void:
	var p: Dictionary = THEME.palette("light")
	await _move(Vector2(80, 40))
	var steps_before := str(ws.last_step)
	await _type("-5")
	var box := _box("length")
	_expect(box.visible and box.text == "-5" and box.get_theme_color("font_color") == p.dim_box_invalid, "A negative length shows dim_box_invalid (%s)." % box.text)
	await _key(KEY_ENTER)
	_expect(box.visible and box.has_focus() and not editor._heads_up_state.length.locked and str(ws.last_message).begins_with("Length:") and str(ws.last_step) == steps_before,
		"Enter refuses it: nothing locked or added, the box keeps the keyboard (%s)." % ws.last_message)
	await _key(KEY_ESCAPE)
	_expect(not box.visible and not editor._heads_up_locked() and editor.tool == "line" and editor.tool_points.size() == 1 and (ws.viewport.overlay() as Control).has_focus(),
		"Esc closes the boxes, locks nothing and the chain goes on (%s)." % [editor.tool_points])
	await _key(KEY_ESCAPE)
	_expect(editor.tool == "line" and editor.tool_points.is_empty(), "Esc again ends the chain (%s)." % [editor.tool_points])


## A new line: 25 + Enter, Tab, 60 + Enter places it at once, 60° from plane +X on the mouse's side,
## through a level construction line as long as it.
func _check_both_locked() -> void:
	await _click(Vector2(0, -5))
	await _move(Vector2(20, -25))
	await _type("25")
	await _key(KEY_ENTER)
	await _key(KEY_TAB)
	await _type("60")
	var before: Dictionary = ws.doc.snapshot()
	var count := _lines().size()
	await _key(KEY_ENTER)
	var s: SKETCH = editor.sketch()
	var lines := _lines()
	_expect(lines.size() == count + 2, "Enter with both locked adds the segment and its reference line (%d -> %d)." % [count, lines.size()])
	if lines.size() != count + 2:
		return
	var segment: Dictionary = lines.filter(func(e: Dictionary) -> bool: return not e.get("construction", false))[-1]
	var reference: Dictionary = lines.filter(func(e: Dictionary) -> bool: return e.get("construction", false))[-1]
	var direction := _dir(s, int(segment.p1), int(segment.p2))
	_expect(absf(_length(s, int(segment.id)) - 0.025) < 1e-7 and absf(rad_to_deg(direction.angle()) + 60.0) < 1e-4,
		"The segment is 25 mm at -60° (below +X, where the mouse is) (%f, %f°)." % [_length(s, int(segment.id)), rad_to_deg(direction.angle())])
	_expect(int(reference.p1) == int(segment.p1) and absf(_dir(s, int(reference.p1), int(reference.p2)).y) < 1e-9
		and s.constraints().any(func(c: Dictionary) -> bool: return c.type == "horizontal" and (c.refs as Array) == [int(reference.id)])
		and s.constraints().any(func(c: Dictionary) -> bool: return c.type == "equal" and (c.refs as Array).has(int(reference.id))),
		"The angle is measured from a level construction line from the start (%s)." % [reference])
	var dims := s.constraints().filter(func(c: Dictionary) -> bool: return c.has("key") and (c.refs as Array).has(int(segment.id)))
	_expect(dims.size() == 2 and ws.last_step.get("name", "") == "Sketch: Line" and _same(ws.last_step.get("before", {}), before),
		"Its length and angle are driving dimensions in one Sketch: Line step (%s)." % [dims])
	_expect(not _box("length").visible and (ws.viewport.overlay() as Control).has_focus(), "The view has the keyboard back.")
	var solve: Dictionary = ws.result.sketches[editor.feature_id].solve
	_expect(bool(solve.get("ok", false)) and (solve.get("conflicting", []) as Array).is_empty() and (solve.get("redundant", []) as Array).is_empty(), "The sketch still solves cleanly (%s)." % [solve])
	await _key(KEY_ESCAPE)


## The dark palette styles the boxes and the previews.
func _check_dark() -> void:
	ws.set_theme_mode("dark")
	await _frames(2)
	var d: Dictionary = THEME.palette("dark")
	await _click(Vector2(-5, 40))
	await _move(Vector2(15, 55))
	_expect(editor._dim_draw_log.get(editor.HEADS_UP_IDS.length, {}).get("color") == d.dim_preview, "Dark: the previews are dim_preview.")
	await _type("12")
	await _key(KEY_ENTER)
	var box := _box("length")
	_expect((box.get_theme_stylebox("normal") as StyleBoxFlat).bg_color == d.dim_box_back and box.get_theme_color("font_color") == d.dim_selected
		and (_box("angle").get_theme_stylebox("normal") as StyleBoxFlat).border_color == d.dim_box_frame, "Dark: the boxes take the dark dim_box colours and the lock dim_selected.")
	await _key(KEY_ESCAPE)
	await _key(KEY_ESCAPE)
	editor.cancel_tool()
	ws.set_theme_mode("light")


# --- Rectangles and circles -------------------------------------------------------------------

## The sketch's entity ids now (to find what a step added).
func _entity_ids() -> Array:
	return editor.sketch().entities().map(func(e: Dictionary) -> int: return int(e.id))


## The entities of a type added since before (an _entity_ids() result).
func _added(before: Array, type: String) -> Array:
	return editor.sketch().entities().filter(func(e: Dictionary) -> bool: return e.type == type and not before.has(int(e.id)))


func _constraint_ids() -> Array:
	return editor.sketch().constraints().map(func(c: Dictionary) -> int: return int(c.id))


## The dimensions (constraints with parameters) added since before (a _constraint_ids() result).
func _added_dimensions(before: Array) -> Array:
	return editor.sketch().constraints().filter(func(c: Dictionary) -> bool: return c.has("key") and not before.has(int(c.id)))


## The bounding box (plane meters) of some lines' end points.
func _bounds(lines: Array) -> Rect2:
	var s: SKETCH = editor.sketch()
	var box := Rect2(s.point(int(lines[0].p1)), Vector2.ZERO)
	for e: Dictionary in lines:
		box = box.expand(s.point(int(e.p1))).expand(s.point(int(e.p2)))
	return box


## The sketch solves, without conflicts, and redundant only where it was before (a centre
## rectangle's own construction is redundant once, with or without heads-up dimensions).
func _clean_solve() -> bool:
	var solve: Dictionary = ws.result.sketches[editor.feature_id].solve
	return bool(solve.get("ok", false)) and (solve.get("conflicting", []) as Array).is_empty() and (solve.get("redundant", []) as Array).size() <= _known_redundant


func _redundant_count() -> int:
	return (ws.result.sketches[editor.feature_id].solve.get("redundant", []) as Array).size()


func _step_name(tool_name: String) -> String:
	return "Sketch: " + str(editor._tool_title(tool_name))


## A point (mm) of the shapes' own area of the plane, away from the lines (the view looks at AREA).
func _in_area(mm: Vector2) -> Vector2:
	return AREA + mm


## The view moves to the shapes' area.
func _look_at_area() -> void:
	ws.viewport.set_view_state({"target": editor.sketch().to_world(AREA * MM), "distance": 0.16})
	await _frames(2)


## A 2-point rectangle: width and height previews outside the edges through the moving corner, a
## typed 30 + Enter locks the width (the rubber band keeps it), Tab, 15 + Enter locks the height and
## places it: 30 x 15 mm towards the mouse with driving horizontal and vertical distances in one
## step, their texts where the heads-up ones were.
func _check_rect_2pt() -> void:
	var p: Dictionary = THEME.palette("light")
	await _look_at_area()
	editor.start_tool("rect_2pt")
	await _click(_in_area(Vector2(-40, -40)))
	await _move(_in_area(Vector2(-15, -20)))
	var log: Dictionary = editor._dim_draw_log
	var width: Dictionary = log.get(editor.HEADS_UP_IDS.width, {})
	var height: Dictionary = log.get(editor.HEADS_UP_IDS.height, {})
	_expect(width.get("state", "") == "preview" and width.get("text", "") == DIM.canvas_number(0.025, "length", "mm") and width.get("color") == p.dim_preview
		and height.get("state", "") == "preview" and height.get("text", "") == DIM.canvas_number(0.02, "length", "mm"),
		"Rectangle: the rubber band shows its width and height as preview dimensions (%s, %s)." % [width, height])
	var corner := _local(_in_area(Vector2(-15, -20)))
	var centers: Dictionary = editor._heads_up_centers
	_expect(centers.get("width", Vector2.INF).y < corner.y - 10.0 and centers.get("height", Vector2.INF).x > corner.x + 10.0,
		"Rectangle: the width sits above the top edge and the height right of the right edge, outside the rectangle (%s, corner %s)." % [centers, corner])
	await _type("30")
	var box := _box("width")
	_expect(box.visible and box.has_focus() and box.text == "30" and _box("height").visible and _box("height").text == editor._heads_up_format("height", 0.02)
		and not _box("length").visible and not _box("angle").visible,
		"Rectangle: typing opens the width box with the keyboard, the height box shows what it measures (%s, '%s')." % [box.has_focus(), _box("height").text])
	await _key(KEY_ENTER)
	_expect(editor._heads_up_state.width.locked and absf(float(editor._heads_up_state.width.value) - 0.03) < 1e-12 and box.has_focus() and box.get_theme_color("font_color") == p.dim_selected,
		"Rectangle: Enter locks the 30 mm width in dim_selected, the box keeps the keyboard (%s)." % [editor._heads_up_state.width])
	await _move(_in_area(Vector2(-20, -10)))
	var end: Vector2 = editor._heads_up_point(editor.mouse_plane)
	_expect(absf(end.x - _in_area(Vector2(-10, 0)).x * MM) < 1e-7 and absf(end.y - _in_area(Vector2(0, -10)).y * MM) < 1e-5, "Rectangle: the rubber band keeps the locked width; the mouse sets the height (%s)." % end)
	await _key(KEY_TAB)
	_expect(_box("height").has_focus() and _box("height").get_selected_text() == _box("height").text, "Rectangle: Tab moves to the height, its value selected.")
	await _key(KEY_TAB)
	_expect(box.has_focus(), "Rectangle: Tab moves back to the width.")
	await _key(KEY_TAB)
	await _type("15")
	# The mouse where the locked rectangle's corner goes: the previews are then where its dimensions go.
	await _move(_in_area(Vector2(-20, -25)))
	var locked_centers: Dictionary = editor._heads_up_centers.duplicate()
	var before: Dictionary = ws.doc.snapshot()
	var ids := _entity_ids()
	var constraints := _constraint_ids()
	await _key(KEY_ENTER)
	var lines := _added(ids, "line")
	_expect(lines.size() == 4, "Rectangle: Enter with both locked places it (%d lines)." % lines.size())
	if lines.size() != 4:
		return
	var bounds := _bounds(lines)
	_expect(bounds.position.distance_to(_in_area(Vector2(-40, -40)) * MM) < 1e-5 and bounds.size.distance_to(Vector2(0.03, 0.015)) < 1e-7,
		"Rectangle: 30 x 15 mm from the first corner towards the mouse (%s)." % bounds)
	var dims := _added_dimensions(constraints)
	var types := dims.map(func(c: Dictionary) -> String: return "%s=%s" % [c.type, _expression(c)])
	_expect(types == ["distance_x=30", "distance_y=15"] and dims.all(func(c: Dictionary) -> bool: return c.get("driving", true)),
		"Rectangle: driving horizontal 30 and vertical 15 distances (%s)." % [types])
	_expect(ws.last_step.get("name", "") == _step_name("rect_2pt") and _same(ws.last_step.get("before", {}), before) and _clean_solve(),
		"Rectangle: the shape and its dimensions are one step and the sketch solves cleanly (%s)." % ws.last_step.get("name", ""))
	_expect(not box.visible and not _box("height").visible and (ws.viewport.overlay() as Control).has_focus() and editor.tool == "rect_2pt" and editor.tool_points.is_empty(),
		"Rectangle: the boxes close, the view has the keyboard back and the tool waits for the next rectangle.")
	await _move(_in_area(Vector2(-40, 20)))
	if dims.size() == 2:
		var placed_w := _hit_center(int(dims[0].id))
		var placed_h := _hit_center(int(dims[1].id))
		_expect(placed_w.distance_to(locked_centers.width) <= 2.0 and placed_h.distance_to(locked_centers.height) <= 2.0,
			"Rectangle: the dimensions' texts are where the heads-up ones were (%s / %s vs %s)." % [placed_w, placed_h, locked_centers])


## A centre rectangle: 16 + Enter locks the width, the click sets the height: 16 mm wide about the
## centre, one driving horizontal distance.
func _check_rect_center() -> void:
	editor.start_tool("rect_center")
	await _click(_in_area(Vector2(-20, 30)))
	await _move(_in_area(Vector2(-10, 35)))
	var width: Dictionary = editor._dim_draw_log.get(editor.HEADS_UP_IDS.width, {})
	_expect(width.get("text", "") == DIM.canvas_number(0.02, "length", "mm") and editor._dim_draw_log.get(editor.HEADS_UP_IDS.height, {}).get("text", "") == DIM.canvas_number(0.01, "length", "mm"),
		"Centre rectangle: width and height are twice the corner's offsets (%s, %s)." % [width, editor._dim_draw_log.get(editor.HEADS_UP_IDS.height, {})])
	await _type("16")
	await _key(KEY_ENTER)
	var ids := _entity_ids()
	var constraints := _constraint_ids()
	await _click(_in_area(Vector2(-8, 40)))
	var lines := _added(ids, "line").filter(func(e: Dictionary) -> bool: return not e.get("construction", false))
	_expect(lines.size() == 4, "Centre rectangle: the click places it (%d lines)." % lines.size())
	if lines.size() != 4:
		return
	var bounds := _bounds(lines)
	_expect(bounds.position.distance_to(_in_area(Vector2(-28, 20)) * MM) < 1e-5 and absf(bounds.size.x - 0.016) < 1e-7 and absf(bounds.size.y - 0.02) < 1e-5,
		"Centre rectangle: 16 mm wide (locked) and 20 mm high (the click) about its centre (%s)." % bounds)
	# A centre rectangle is redundant once by itself (its two midpoint diagonals), dimensions or not.
	_known_redundant = mini(_redundant_count(), 1)
	var dims := _added_dimensions(constraints)
	_expect(dims.size() == 1 and dims[0].type == "distance_x" and _expression(dims[0]) == "16" and _clean_solve() and ws.last_step.get("name", "") == _step_name("rect_center"),
		"Centre rectangle: one driving horizontal 16 in its step, solving cleanly (%s, %s)." % [dims, ws.result.sketches[editor.feature_id].solve])
	await _key(KEY_ESCAPE)


## A 3-point rectangle: its first edge is the rubber band with its length; 40 + Enter places the
## edge's end 40 mm towards the mouse and the box closes with the lock kept; the height step shows
## the locked width and the height; 12 + Enter places it with two driving aligned lengths.
func _check_rect_3pt() -> void:
	var p: Dictionary = THEME.palette("light")
	editor.start_tool("rect_3pt")
	await _click(_in_area(Vector2(10, 0)))
	await _move(_in_area(Vector2(40, 10)))
	var width: Dictionary = editor._dim_draw_log.get(editor.HEADS_UP_IDS.width, {})
	_expect(width.get("state", "") == "preview" and width.get("text", "") == DIM.canvas_number(Vector2(30, 10).length() * MM, "length", "mm")
		and not editor._dim_draw_log.has(editor.HEADS_UP_IDS.height), "3-point rectangle: the first edge shows its length only (%s)." % [width])
	await _key(KEY_TAB)
	_expect(_box("width").visible and _box("width").has_focus() and not _box("height").visible, "3-point rectangle: Tab opens the one field of the first step.")
	await _type("40")
	await _key(KEY_ENTER)
	var expected_b := _in_area(Vector2(10, 0)) * MM + Vector2(30, 10).normalized() * 0.04
	var b: Vector2 = editor.tool_points[1] if editor.tool_points.size() == 2 else Vector2.INF
	_expect(editor.tool_points.size() == 2 and b.distance_to(expected_b) < 1e-5 and absf(b.distance_to(editor.tool_points[0]) - 0.04) < 1e-7 and not _box("width").visible and editor._heads_up_state.width.locked
		and (ws.viewport.overlay() as Control).has_focus(),
		"3-point rectangle: Enter places the edge 40 mm towards the mouse, the box closes with the lock kept, the view has the keyboard (%s)." % [editor.tool_points])
	await _move(_in_area(Vector2(30, 30)))
	var log: Dictionary = editor._dim_draw_log
	_expect(log.get(editor.HEADS_UP_IDS.width, {}).get("color") == p.dim_selected and log.get(editor.HEADS_UP_IDS.width, {}).get("text", "") == DIM.canvas_number(0.04, "length", "mm")
		and log.get(editor.HEADS_UP_IDS.height, {}).get("state", "") == "preview", "3-point rectangle: the height step shows the locked width and the height preview (%s)." % [log])
	await _type("12")
	_expect(_box("height").visible and _box("height").has_focus() and not _box("width").visible, "3-point rectangle: typing opens the height box only.")
	var ids := _entity_ids()
	var constraints := _constraint_ids()
	var before: Dictionary = ws.doc.snapshot()
	await _key(KEY_ENTER)
	var s: SKETCH = editor.sketch()
	var lines := _added(ids, "line")
	_expect(lines.size() == 4, "3-point rectangle: Enter places it (%d lines)." % lines.size())
	if lines.size() != 4:
		return
	var dims := _added_dimensions(constraints)
	var types := dims.map(func(c: Dictionary) -> String: return "%s=%s" % [c.type, _expression(c)])
	_expect(absf(_length(s, int(lines[0].id)) - 0.04) < 1e-7 and absf(_length(s, int(lines[1].id)) - 0.012) < 1e-7 and types == ["length=40", "length=12"]
		and (dims[0].refs as Array) == [int(lines[0].id)] and (dims[1].refs as Array) == [int(lines[1].id)],
		"3-point rectangle: 40 x 12 mm with driving aligned lengths on its first two edges (%s)." % [types])
	# The mouse (30, 30) is left of the edge from (10, 0) towards (40, 10): so is the height.
	var edge := (expected_b - _in_area(Vector2(10, 0)) * MM).normalized()
	var far: Vector2 = s.point(int(lines[1].p2))
	_expect(edge.cross(far - expected_b) > 0.0, "3-point rectangle: the height goes to the mouse's side of the edge (%s)." % far)
	_expect(ws.last_step.get("name", "") == _step_name("rect_3pt") and _same(ws.last_step.get("before", {}), before) and _clean_solve(),
		"3-point rectangle: one step, solving cleanly (%s)." % ws.last_step.get("name", ""))
	await _key(KEY_ESCAPE)


## A centre-diameter circle: the diameter preview, Tab opens its box (Tab stays in it), 50 + Enter
## places a 50 mm circle about the centre with a driving diameter in one step, its text where the
## heads-up one was.
func _check_circle_center() -> void:
	var p: Dictionary = THEME.palette("light")
	editor.start_tool("circle_center")
	await _click(_in_area(Vector2(55, -30)))
	await _move(_in_area(Vector2(70, -30)))
	var diameter: Dictionary = editor._dim_draw_log.get(editor.HEADS_UP_IDS.diameter, {})
	var expected := DIM.canvas_text({"type": "diameter"}, 0.03, "mm", "", "")
	_expect(diameter.get("state", "") == "preview" and diameter.get("text", "") == expected and diameter.get("color") == p.dim_preview,
		"Circle: the rubber band shows its diameter as a preview dimension (%s, expected %s)." % [diameter, expected])
	await _key(KEY_TAB)
	var box := _box("diameter")
	_expect(box.visible and box.has_focus() and box.get_selected_text() == box.text and box.text == editor._heads_up_format("diameter", 0.03),
		"Circle: Tab opens the diameter box with what it measures selected ('%s')." % box.text)
	await _key(KEY_TAB)
	_expect(box.has_focus(), "Circle: Tab stays in the one field.")
	await _type("50")
	# The mouse where the locked circle's rim goes (on the 5 mm grid, clear of the box, off the axes):
	# the preview is then where its dimension goes.
	await _move(_in_area(Vector2(70, -10)))
	var locked_center: Vector2 = editor._heads_up_centers.get("diameter", Vector2.INF)
	var ids := _entity_ids()
	var constraints := _constraint_ids()
	var before: Dictionary = ws.doc.snapshot()
	await _key(KEY_ENTER)
	var s: SKETCH = editor.sketch()
	var circles := _added(ids, "circle")
	_expect(circles.size() == 1, "Circle: Enter places it (%d)." % circles.size())
	if circles.size() != 1:
		return
	var dims := _added_dimensions(constraints)
	_expect(absf(float(circles[0].r) - 0.025) < 1e-7 and s.point(int(circles[0].c)).distance_to(_in_area(Vector2(55, -30)) * MM) < 1e-5
		and dims.size() == 1 and dims[0].type == "diameter" and _expression(dims[0]) == "50" and dims[0].get("driving", true),
		"Circle: 50 mm about the centre with a driving diameter of 50 (%s, %s)." % [circles[0], dims])
	_expect(ws.last_step.get("name", "") == _step_name("circle_center") and _same(ws.last_step.get("before", {}), before) and _clean_solve()
		and not box.visible and (ws.viewport.overlay() as Control).has_focus(), "Circle: one step, solving cleanly, the view has the keyboard back.")
	await _move(_in_area(Vector2(60, -5)))
	var placed := _hit_center(int(dims[0].id)) if dims.size() == 1 else Vector2.INF
	_expect(placed.is_finite() and placed.distance_to(locked_center) <= 2.0, "Circle: the diameter's text is where the heads-up one was (%s vs %s)." % [placed, locked_center])


## A 2-point circle: a negative diameter is red and refused, Esc closes the box (the tool keeps its
## first point), 18 + Enter places an 18 mm circle from the first point towards the mouse.
func _check_circle_2pt() -> void:
	var p: Dictionary = THEME.palette("light")
	editor.start_tool("circle_2pt")
	await _click(_in_area(Vector2(20, -45)))
	await _move(_in_area(Vector2(40, -45)))
	_expect(editor._dim_draw_log.get(editor.HEADS_UP_IDS.diameter, {}).get("text", "") == DIM.canvas_text({"type": "diameter"}, 0.02, "mm", "", ""),
		"2-point circle: the diameter is the two points' distance.")
	var steps_before := str(ws.last_step)
	await _type("-3")
	var box := _box("diameter")
	_expect(box.visible and box.text == "-3" and box.get_theme_color("font_color") == p.dim_box_invalid, "2-point circle: a negative diameter shows dim_box_invalid.")
	await _key(KEY_ENTER)
	_expect(box.visible and not editor._heads_up_state.diameter.locked and str(ws.last_message).begins_with("Diameter:") and str(ws.last_step) == steps_before,
		"2-point circle: Enter refuses it (%s)." % ws.last_message)
	await _key(KEY_ESCAPE)
	_expect(not box.visible and editor.tool == "circle_2pt" and editor.tool_points.size() == 1 and (ws.viewport.overlay() as Control).has_focus(),
		"2-point circle: Esc closes the box and the tool keeps its first point.")
	var ids := _entity_ids()
	await _type("18")
	await _key(KEY_ENTER)
	var s: SKETCH = editor.sketch()
	var circles := _added(ids, "circle")
	_expect(circles.size() == 1 and absf(float(circles[0].r) - 0.009) < 1e-7 and s.point(int(circles[0].c)).distance_to(_in_area(Vector2(29, -45)) * MM) < 1e-5 and _clean_solve(),
		"2-point circle: 18 mm from the first point towards the mouse (%s)." % [circles])
	await _key(KEY_ESCAPE)
	editor.cancel_tool()


## The dark palette: a rectangle's previews and boxes, a circle's preview and box.
func _check_shapes_dark() -> void:
	ws.set_theme_mode("dark")
	await _frames(2)
	var d: Dictionary = THEME.palette("dark")
	editor.start_tool("rect_2pt")
	await _click(_in_area(Vector2(50, 10)))
	await _move(_in_area(Vector2(65, 25)))
	_expect(editor._dim_draw_log.get(editor.HEADS_UP_IDS.width, {}).get("color") == d.dim_preview and editor._dim_draw_log.get(editor.HEADS_UP_IDS.height, {}).get("color") == d.dim_preview,
		"Dark: the rectangle's previews are dim_preview.")
	await _type("9")
	await _key(KEY_ENTER)
	var box := _box("width")
	_expect((box.get_theme_stylebox("normal") as StyleBoxFlat).bg_color == d.dim_box_back and box.get_theme_color("font_color") == d.dim_selected
		and (_box("height").get_theme_stylebox("normal") as StyleBoxFlat).border_color == d.dim_box_frame and (box.get_theme_stylebox("focus") as StyleBoxFlat).border_color == d.dim_box_focus,
		"Dark: the rectangle's boxes take the dark dim_box colours and the lock dim_selected.")
	await _key(KEY_ESCAPE)
	await _key(KEY_ESCAPE)
	editor.start_tool("circle_center")
	await _click(_in_area(Vector2(10, 45)))
	await _move(_in_area(Vector2(20, 45)))
	await _type("5")
	await _frames(2)
	_expect(editor._dim_draw_log.get(editor.HEADS_UP_IDS.diameter, {}).get("color") == d.dim_preview and _box("diameter").get_theme_color("font_color") == d.dim_box_text,
		"Dark: the circle's preview and box text take the dark colours.")
	await _key(KEY_ESCAPE)
	editor.cancel_tool()
	ws.set_theme_mode("light")
