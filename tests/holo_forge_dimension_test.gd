extends SceneTree
## Holo Forge sketch dimensions drawn as drafting dimensions (core/sketch/dimension_layout.gd and
## the sketch editor). Layouts, at 4 px per mm with Y up: horizontal, vertical and aligned linear
## dimensions put their feet, extension lines (3 px gap, 5 px past the line), arrows and upright
## text where drafting does; short ones put the arrows outside on tails; text beyond a foot gets the
## line run on under it; point-to-line and parallel distances run across the line; angles are arcs
## on the vertex with arrows on the rays; radius and diameter leaders put the arrow on the curve
## with a landing; partial arcs get arc extensions; text sitting on what it measures is shown off
## to the side; text never reads upside down. Canvas numbers ("40.00", "13.079", "30.0°", "R10.00",
## "Ø20.00", "(40.00)", the expression marker) and what each kind measures. In a workspace: every
## dimension gets hit areas (text and lines; curves win over dimension lines), hover, selection
## and errors (a conflict, a broken parameter) show in the palette's colours with the measured
## value, the value box opens centred on the text in the palette's colours, and both palettes draw.
## Placing with the Sketch Dimension tool: where the cursor is pulled picks horizontal, vertical
## or aligned (kept a few degrees past a boundary) and which of four angles, shown live as a
## preview; angles are stored as a positive sweep between rays, so the prefilled value keeps the
## shape and typed values never mirror it, while angles from older documents solve as before; the
## value box opens on the text with the measured value, refuses text that isn't a usable value or
## that the sketch can't take (nothing changes), and closes with the tool, Esc, a click away or an
## undo; an over-constraining dimension asks to be added driven (and a driven one made driving is
## refused when it would over-constrain), trials never touch the document; second picks pair only
## with other items, Esc goes back a stage at a time, and picks that make nothing say so.
## Afterwards: a click on a dimension while typing puts its parameter in the box; hovered
## dimensions show a tip and the box a name pill; dimension text drags (one step); the right-click
## menu offers the placing choices (orientation, radius/diameter/sweep, centre/edge, diameter across
## a centerline, driven) and, on a placed dimension, edit, driven/driving (the name comes back),
## radius/diameter and delete; a deleted dimension's users say so and show an error; Fully Define
## writes document units, no 0 dimensions, and places its text apart. Edge distances to circles and
## arcs, the angle at the middle of three points and an arc's sweep, a diameter across a
## centerline, "name = value" renaming a parameter, parameter labels, favourites in the box and the
## measured geometry lighting up. Review fixes: a small angle's value goes beyond its arrow (never
## across a ray), a three-point angle over bare points draws its rays, extension lines keep clear
## of point markers and text of their ends; Tab keeps the keyboard in the box, which stays on its
## dimension as the view moves and as it grows; nothing changed records no step; layouts are
## reused while nothing changes; prefills have 6 decimals unless the geometry's noise says
## otherwise; older documents' signed distances and legacy angles edit by what they show.
##
## godot --headless --path . --script res://tests/holo_forge_dimension_test.gd

const DIM := preload("res://addons/holo_forge/core/sketch/dimension_layout.gd")
const SKETCH := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const UNITS := preload("res://addons/holo_forge/core/units.gd")
const THEME := preload("res://addons/holo_forge/ui/forge_theme.gd")
const WORKSPACE := preload("res://addons/holo_forge/ui/forge_workspace.gd")
const CAD_PART := preload("res://addons/holo_forge/nodes/cad_part.gd")
const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const TEXT_W := 40.0
const ASCENT := 12.0
const DESCENT := 3.0
const MM := 0.001

var failures: Array[String] = []
var m := DIM.metrics(1.0)


func _init() -> void:
	call_deferred("run")


func run() -> void:
	create_timer(400.0).timeout.connect(func() -> void:
		print("FAIL holo_forge_dimension: timed out ", failures)
		quit(1))
	_check_text()
	_check_measure()
	_check_linear()
	_check_short_and_outside()
	_check_to_line()
	_check_angle()
	_check_round()
	_check_upright_and_offscreen()
	_check_orientation_rule()
	_check_review_layouts()
	await _check_editor()
	await _check_behaviour()
	print("PASS holo_forge_dimension: drafting layouts (H/V/aligned feet, 3 px gaps, 5 px overshoot, arrows, upright text, short arrows outside, text beyond a foot, point/parallel line distances, angle arcs, radius/diameter leaders and landings, partial-arc extensions, shown-off text on old dimensions), canvas numbers and markers, measuring, hit areas, hover/selected/error states with measured values, the themed value box centred on the text, dark and light; placing: H/V/aligned by the cursor with hysteresis and a live preview, angle sectors stored as sweeps (no mirroring, legacy angles unchanged), the value box (prefill, centring, refusals, Esc, click away, lifetime), the driven question and driven-to-driving refusal, isolated trials, pick pairing, Esc stages and hints; parameters clicked into the box, tips and name pills, text drags, right-click placing and placed options, broken users flagged, Fully Define in units with no 0s and placed text, edge distances, three-point and sweep angles, linear diameters, renaming, labels, favourites, measured highlight; review fixes (small-angle text, bare three-point rays, marker gaps, short text clearance, Tab, box follows view and text, no empty steps, layout cache, 6-decimal prefills, signed and legacy edits, themed driven question)" \
		if failures.is_empty() else "FAIL holo_forge_dimension")
	quit(0 if failures.is_empty() else 1)


func _expect(ok: bool, detail: String) -> void:
	if not ok:
		failures.append(detail)
		push_error(detail)
		print("FAIL: ", detail)


## Plane meters to the test's screen: 4 px per mm, Y up, the origin at (500, 500).
func _screen(p: Vector2) -> Vector2:
	return Vector2(500, 500) + Vector2(p.x, -p.y) * 4000.0


## A dimension laid out with its text at t (mm).
func _layout(s: SKETCH, c: Dictionary, t_mm: Vector2) -> Dictionary:
	return DIM.screen_layout(DIM.plane_layout(s, c, t_mm * MM), _screen, m, TEXT_W, ASCENT, DESCENT)


func _sketch() -> SKETCH:
	return SKETCH.new()


func _line(s: SKETCH, a_mm: Vector2, b_mm: Vector2) -> int:
	return s.add_line(s.add_point(a_mm * MM), s.add_point(b_mm * MM))


func _near(a: Vector2, b: Vector2, tolerance := 0.01) -> bool:
	return a.distance_to(b) <= tolerance


func _longest(segments: Array) -> Array:
	var best: Array = []
	for segment: Array in segments:
		if best.is_empty() or (segment[0] as Vector2).distance_to(segment[1]) > (best[0] as Vector2).distance_to(best[1]):
			best = segment
	return best


# --- Text and measuring --------------------------------------------------------------------------

func _check_text() -> void:
	var numbers := {
		[0.04, "length", "mm"]: "40.00", [0.0125, "length", "mm"]: "12.50", [0.0130789, "length", "mm"]: "13.079",
		[0.016 / 3.0, "length", "mm"]: "5.333", [0.0508, "length", "in"]: "2.00", [-0.04, "length", "mm"]: "40.00",
		[deg_to_rad(30.0), "angle", "mm"]: "30.0°", [deg_to_rad(126.8699), "angle", "mm"]: "126.9°",
	}
	for key: Array in numbers:
		var got := DIM.canvas_number(key[0], key[1], key[2])
		_expect(got == numbers[key], "canvas_number(%s) should be %s (%s)." % [key, numbers[key], got])
	var cases := [
		[{"type": "radius", "kind": "length"}, 0.01, "10", "R10.00"],
		[{"type": "diameter", "kind": "length"}, 0.02, "20 mm", "Ø20.00"],
		[{"type": "angle", "kind": "angle"}, deg_to_rad(30.0), "30", "30.0°"],
		[{"type": "length", "kind": "length", "driving": false}, 0.04, "", "(40.00)"],
		[{"type": "diameter", "kind": "length", "driving": false}, 0.02, "d1 * 2", "(Ø20.00)"],
		[{"type": "angle", "kind": "angle", "driving": false}, deg_to_rad(30.0), "", "(30.0°)"],
		[{"type": "length", "kind": "length"}, 0.02, "d1 / 2", "ƒ 20.00"],
		[{"type": "radius", "kind": "length"}, 0.01, "d2", "ƒ R10.00"],
	]
	for case: Array in cases:
		var got := DIM.canvas_text(case[0], case[1], "mm", case[2], "ƒ ")
		_expect(got == case[3], "canvas_text(%s, %s) should be %s (%s)." % [case[0], case[2], case[3], got])
	for literal in ["40", "40 mm", " 2.5in", "1e-3 m", "30 deg", "+4", ".5"]:
		_expect(DIM.is_literal(literal), "%s is a plain number." % literal)
	for expression in ["d1", "40 + 1", "(40)", "-4", "2*3", "width"]:
		_expect(not DIM.is_literal(expression), "%s is an expression." % expression)
	_expect(UNITS.format_value(0.0130789721, UNITS.KIND_LENGTH, "mm") == "13.079 mm" and UNITS.format_value(0.0130789721, UNITS.KIND_LENGTH, "mm", 6) == "13.078972 mm",
		"format_value keeps 4 decimals by default and takes more (%s)." % UNITS.format_value(0.0130789721, UNITS.KIND_LENGTH, "mm", 6))


func _check_measure() -> void:
	var s := _sketch()
	var slanted := _line(s, Vector2(0, 0), Vector2(30, 40))
	var e: Dictionary = s.entity(slanted)
	var flat := _line(s, Vector2(0, 0), Vector2(40, 0))
	var up := _line(s, Vector2(0, 0), Vector2(30, 30))
	var center := s.add_point(Vector2.ZERO)
	var circle: int = s.add_circle(center, 0.01)
	var arc: int = s.add_arc(center, s.add_point(Vector2(10, 0) * MM), s.add_point(Vector2(0, 10) * MM))
	var point := s.add_point(Vector2(10, 25) * MM)
	var checks := [
		[{"type": "length", "refs": [slanted]}, 0.05],
		[{"type": "distance_x", "refs": [int(e.p2), int(e.p1)]}, 0.03],
		[{"type": "distance_y", "refs": [int(e.p1), int(e.p2)]}, 0.04],
		[{"type": "distance", "refs": [int(e.p1), int(e.p2)]}, 0.05],
		[{"type": "distance", "refs": [point, flat]}, 0.025],
		[{"type": "distance", "refs": [circle, point]}, Vector2(10, 25).length() * MM],
		[{"type": "radius", "refs": [arc]}, 0.01],
		[{"type": "diameter", "refs": [circle]}, 0.02],
		[{"type": "arc_length", "refs": [arc]}, 0.01 * PI * 0.5],
		[{"type": "angle", "refs": [flat, up]}, PI * 0.25],
		[{"type": "angle", "refs": [flat, up], "rays": [1, 1]}, PI * 0.25],
		[{"type": "angle", "refs": [up, flat], "rays": [1, -1]}, PI * 0.75],
	]
	for check: Array in checks:
		var got := DIM.measure(s, check[0])
		# Plane points are single precision Vector2s.
		_expect(absf(got - float(check[1])) < 1e-6 * maxf(float(check[1]), 1e-3), "measure(%s) should be %.9f (%.9f)." % [check[0], check[1], got])


# --- Linear ----------------------------------------------------------------------------------------

func _check_linear() -> void:
	var s := _sketch()
	var line := _line(s, Vector2(0, 0), Vector2(30, 40))
	var e: Dictionary = s.entity(line)
	# Horizontal: the dimension line level at T, vertical extension lines.
	var h := _layout(s, {"type": "distance_x", "refs": [int(e.p1), int(e.p2)]}, Vector2(15, 50))
	var t_y := _screen(Vector2(15, 50) * MM).y
	_expect(h.arrows.size() == 2, "A horizontal dimension has two arrows (%d)." % h.arrows.size())
	if h.arrows.size() == 2:
		var a0: Dictionary = h.arrows[0]
		var a1: Dictionary = h.arrows[1]
		_expect(absf((a0.tip as Vector2).y - t_y) < 0.01 and absf((a1.tip as Vector2).y - t_y) < 0.01, "Both feet sit on the dimension line through T (%s, %s)." % [a0.tip, a1.tip])
		_expect(absf((a0.tip as Vector2).x - 500.0) < 0.01 and absf((a1.tip as Vector2).x - 620.0) < 0.01, "The feet are at x 500 and 620 (%s, %s)." % [a0.tip, a1.tip])
		_expect((a0.dir as Vector2).dot(a1.dir) < -0.999 and ((a0.tip as Vector2) - (a1.tip as Vector2)).dot(a0.dir) > 0.0, "Inside arrows point away from each other onto the extension lines.")
	_expect(h.ext_lines.size() == 2, "Two extension lines (%d)." % h.ext_lines.size())
	for ext: Array in h.ext_lines:
		_expect(absf((ext[0] as Vector2).x - (ext[1] as Vector2).x) < 1e-6, "Horizontal dimensions have vertical extension lines (%s)." % [ext])
	if h.ext_lines.size() == 2:
		var from_origin: Array = h.ext_lines[0]
		_expect(absf((from_origin[0] as Vector2).distance_to(Vector2(500, 500)) - 3.0) < 0.01, "The extension line starts 3 px from its point (%s)." % from_origin[0])
		_expect(_near(from_origin[1], Vector2(500, t_y - 5.0)), "The extension line ends 5 px past the dimension line (%s)." % from_origin[1])
	_expect(absf(float(h.text.angle)) < 1e-9 and absf((h.text.anchor as Vector2).x - 560.0) < 0.01 and float(h.text.baseline) < 0.0 and h.text.align == "center",
		"Horizontal text is level, centred on T and above the line (%s)." % [h.text])
	_expect(Geometry2D.is_point_in_polygon(h.text_center, h.hit_poly) and h.text_center.y < t_y, "The text's hit area holds its centre, above the line.")

	# Vertical: the line upright at T, text to its right reading top to bottom.
	var v := _layout(s, {"type": "distance_y", "refs": [int(e.p1), int(e.p2)]}, Vector2(40, 20))
	var dim_line := _longest(v.dim_lines)
	_expect(not dim_line.is_empty() and absf((dim_line[0] as Vector2).x - (dim_line[1] as Vector2).x) < 1e-6, "A vertical dimension's line is upright (%s)." % [dim_line])
	_expect(absf(float(v.text.angle) - PI * 0.5) < 1e-6, "Vertical text reads top to bottom (%f)." % float(v.text.angle))
	var centroid := Vector2.ZERO
	for q in v.hit_poly:
		centroid += q / 4.0
	_expect(not dim_line.is_empty() and centroid.x > (dim_line[0] as Vector2).x, "Vertical text sits to the right of its line (%s)." % centroid)
	for ext: Array in v.ext_lines:
		_expect(absf((ext[0] as Vector2).y - (ext[1] as Vector2).y) < 1e-6, "Vertical dimensions have level extension lines.")

	# Aligned: parallel to the line, offset along its normal.
	var a: Vector2 = s.point(int(e.p1))
	var b: Vector2 = s.point(int(e.p2))
	var n := (b - a).normalized().orthogonal()
	var aligned := _layout(s, {"type": "length", "refs": [line]}, ((a + b) * 0.5 + n * 10.0 * MM) / MM)
	var along := (_screen(b) - _screen(a)).normalized()
	var drawn := _longest(aligned.dim_lines)
	_expect(not drawn.is_empty() and absf(along.cross(((drawn[1] as Vector2) - (drawn[0] as Vector2)).normalized())) < 1e-6, "An aligned dimension runs parallel to its line.")
	_expect(float(aligned.text.angle) > -PI * 0.5 and float(aligned.text.angle) <= PI * 0.5, "Aligned text is upright (%f)." % float(aligned.text.angle))
	_expect(aligned.ext_lines.size() == 2 and absf(((aligned.ext_lines[0][1] as Vector2) - (aligned.ext_lines[0][0] as Vector2)).normalized().dot(along)) < 1e-6,
		"Aligned extension lines are square to the line.")

	# Old dimensions with their text on the line itself are shown 24 px to the plane-up side.
	var flat := _line(s, Vector2(0, 0), Vector2(40, 0))
	var old := _layout(s, {"type": "length", "refs": [flat]}, Vector2(20, 0))
	_expect(not old.is_empty() and absf((old.arrows[0].tip as Vector2).y - (500.0 - 24.0)) < 0.01, "A zero-offset length is shown 24 px above its line (%s)." % [old.get("arrows", [])])
	var upright_line := _line(s, Vector2(0, 0), Vector2(0, 40))
	var old_v := _layout(s, {"type": "length", "refs": [upright_line]}, Vector2(0, 20))
	_expect(not old_v.is_empty() and absf((old_v.arrows[0].tip as Vector2).x - (500.0 - 24.0)) < 0.01, "A zero-offset upright length is shown 24 px to the left.")


func _check_short_and_outside() -> void:
	var s := _sketch()
	var short_line := _line(s, Vector2(0, 0), Vector2(3, 0))
	var short := _layout(s, {"type": "length", "refs": [short_line]}, Vector2(1.5, 5))
	_expect(short.arrows.size() == 2, "A short dimension still has two arrows.")
	if short.arrows.size() == 2:
		var a0: Dictionary = short.arrows[0]
		var a1: Dictionary = short.arrows[1]
		_expect(((a1.tip as Vector2) - (a0.tip as Vector2)).dot(a0.dir) > 0.0 and (a0.dir as Vector2).dot(a1.dir) < -0.999, "Short dimensions point their arrows in from outside.")
		var tails := 0
		for segment: Array in short.dim_lines:
			var length := (segment[0] as Vector2).distance_to(segment[1])
			var at_foot := _near(segment[0], a0.tip) or _near(segment[1], a0.tip) or _near(segment[0], a1.tip) or _near(segment[1], a1.tip)
			if at_foot and length >= 15.0 - 1e-6:
				tails += 1
		_expect(tails >= 2, "Short dimensions have two tails of 15 px or more (%d)." % tails)
	var long_line := _line(s, Vector2(0, 10), Vector2(30, 10))
	var outside := _layout(s, {"type": "length", "refs": [long_line]}, Vector2(45, 18))
	var max_x := -INF
	for segment: Array in outside.dim_lines:
		max_x = maxf(max_x, maxf((segment[0] as Vector2).x, (segment[1] as Vector2).x))
	_expect(max_x >= (outside.text.anchor as Vector2).x + TEXT_W * 0.5 + 2.0 - 0.01, "Text beyond a foot gets the dimension line run on under it (%f)." % max_x)
	_expect(outside.arrows.size() == 2 and (outside.arrows[1].dir as Vector2).x > 0.0, "With room inside, the arrows stay inside.")


func _check_to_line() -> void:
	var s := _sketch()
	var line := _line(s, Vector2(0, 0), Vector2(40, 0))
	var point := s.add_point(Vector2(60, 25) * MM)
	var layout := _layout(s, {"type": "distance", "refs": [point, line]}, Vector2(50, 12))
	_expect(layout.arrows.size() == 2, "A point-to-line distance has two arrows.")
	if layout.arrows.size() == 2:
		var tips := [layout.arrows[0].tip, layout.arrows[1].tip]
		_expect(absf((tips[0] as Vector2).x - (tips[1] as Vector2).x) < 0.01 and absf((tips[0] as Vector2).x - _screen(Vector2(50, 0) * MM).x) < 0.01,
			"Its dimension line runs square to the line through T (%s)." % [tips])
		var ys := [(tips[0] as Vector2).y, (tips[1] as Vector2).y]
		_expect(ys.has(500.0) and ys.any(func(y: float) -> bool: return absf(y - 400.0) < 0.01), "Its feet are on the line and level with the point (%s)." % [ys])
	# The point's extension runs along the line to the dimension line; the line gets one past its end.
	var level := 0
	for ext: Array in layout.ext_lines:
		if absf((ext[0] as Vector2).y - (ext[1] as Vector2).y) < 1e-6:
			level += 1
	_expect(level == 2, "The point's extension and the line's extension both run along the line (%d of %d)." % [level, layout.ext_lines.size()])
	# Two parallel lines: the line across through T, feet on both lines.
	var other := _line(s, Vector2(0, 15), Vector2(40, 15))
	var gap := _layout(s, {"type": "distance", "refs": [line, other]}, Vector2(20, 7))
	_expect(gap.arrows.size() == 2 and gap.ext_lines.is_empty() and absf((gap.arrows[0].tip as Vector2).x - _screen(Vector2(20, 0) * MM).x) < 0.01,
		"Parallel lines get a dimension line straight across at T, with no extensions (%s)." % [gap.get("ext_lines", [])])


func _check_angle() -> void:
	var s := _sketch()
	var flat := _line(s, Vector2(0, 0), Vector2(40, 0))
	var up := _line(s, Vector2(0, 0), Vector2(30, 30))
	var vertex := Vector2(500, 500)
	var radius := Vector2(20, 8).length() * 4.0
	for c: Dictionary in [{"type": "angle", "refs": [flat, up]}, {"type": "angle", "refs": [flat, up], "rays": [1, 1]}]:
		var layout := _layout(s, c, Vector2(20, 8))
		_expect(layout.polylines.size() == 1, "An angle is drawn as one arc (%s)." % c)
		if layout.polylines.size() != 1:
			continue
		var arc: PackedVector2Array = layout.polylines[0]
		var on_radius := true
		for q in arc:
			on_radius = on_radius and absf(q.distance_to(vertex) - radius) < 0.5
		_expect(on_radius, "Every arc sample lies on the radius |T - V| (%s)." % c)
		var ray_45 := Vector2(1, -1).normalized()
		_expect(absf(arc[0].y - 500.0) < 0.5 and arc[0].x > 500.0, "The arc starts on the 0° ray (%s)." % arc[0])
		_expect(absf((arc[arc.size() - 1] - vertex).cross(ray_45)) < 0.5, "The arc ends on the 45° ray (%s)." % arc[arc.size() - 1])
		_expect(layout.arrows.size() == 2, "An angle has two arrows.")
		if layout.arrows.size() == 2:
			var tip0: Vector2 = layout.arrows[0].tip
			var tip1: Vector2 = layout.arrows[1].tip
			_expect(absf(tip0.y - 500.0) < 0.5 and absf((tip1 - vertex).cross(ray_45)) < 0.5, "The arrow tips touch the rays.")
			_expect((layout.arrows[0].dir as Vector2).y > 0.0, "The arrows point outward along the arc.")
		_expect(float(layout.text.angle) > -PI * 0.5 and float(layout.text.angle) <= PI * 0.5 and (layout.text.anchor as Vector2).distance_to(vertex) > radius - 0.01,
			"The angle's text sits on the arc, upright.")
	# A sector chosen by the text: placed in the obtuse sector, the arc spans 135°.
	var obtuse := _layout(s, {"type": "angle", "refs": [flat, up]}, Vector2(-5, 20))
	var arc_b: PackedVector2Array = obtuse.polylines[0] if not obtuse.is_empty() else PackedVector2Array()
	_expect(arc_b.size() > 2 and absf(rad_to_deg(((arc_b[0] - vertex) * Vector2(1, -1)).angle_to((arc_b[arc_b.size() - 1] - vertex) * Vector2(1, -1))) - 135.0) < 0.01,
		"Text in the other sector draws that sector's arc.")
	# A small arc keeps 30 px of radius; segments that end short of the arc get ray extensions.
	var tiny := _layout(s, {"type": "angle", "refs": [flat, up]}, Vector2(1, 0.4))
	_expect(not tiny.is_empty() and absf((tiny.polylines[0][0] as Vector2).distance_to(vertex) - 30.0) < 0.01, "An angle arc is at least 30 px across.")
	var far := _layout(s, {"type": "angle", "refs": [flat, up]}, Vector2(60, 20))
	_expect(far.ext_lines.size() == 2, "An arc beyond both segments gets two ray extensions (%d)." % far.ext_lines.size())
	# Lines that don't cross: only the text.
	var parallel := _line(s, Vector2(0, 10), Vector2(40, 10))
	var note := _layout(s, {"type": "angle", "refs": [flat, parallel]}, Vector2(20, 5))
	_expect(not note.is_empty() and note.arrows.is_empty() and note.hit_poly.size() == 4, "An angle between lines that no longer cross keeps its text and hit area.")


func _check_round() -> void:
	var s := _sketch()
	var center := s.add_point(Vector2.ZERO)
	var circle: int = s.add_circle(center, 0.01)
	var c_screen := Vector2(500, 500)
	# Radius with its text outside: the arrow on the curve pointing at the centre, a level landing.
	var radius := _layout(s, {"type": "radius", "refs": [circle]}, Vector2(20, 20))
	_expect(radius.arrows.size() == 1, "A radius has one arrow.")
	if radius.arrows.size() == 1:
		var tip: Vector2 = radius.arrows[0].tip
		_expect(absf(tip.distance_to(c_screen) - 40.0) < 0.5 and (radius.arrows[0].dir as Vector2).dot(c_screen - tip) > 0.0, "The radius arrow sits on the curve pointing at the centre (%s)." % tip)
	var landing: bool = radius.dim_lines.any(func(segment: Array) -> bool: return absf((segment[0] as Vector2).y - (segment[1] as Vector2).y) < 1e-6 and (segment[0] as Vector2).distance_to(segment[1]) >= 12.0)
	_expect(landing and absf(float(radius.text.angle)) < 1e-9 and radius.text.align == "left", "Radius text outside is level on a landing, starting at the leader.")
	# Diameter with its text inside: one line across through the centre, arrows outward.
	var inside := _layout(s, {"type": "diameter", "refs": [circle]}, Vector2(3, 2))
	_expect(inside.arrows.size() == 2, "A diameter inside has two arrows (%d)." % inside.arrows.size())
	for arrow: Dictionary in inside.arrows:
		_expect((arrow.dir as Vector2).dot((arrow.tip as Vector2) - c_screen) > 0.0 and absf((arrow.tip as Vector2).distance_to(c_screen) - 40.0) < 0.5, "Diameter arrows point outward from the curve.")
	var across := _longest(inside.dim_lines)
	_expect(not across.is_empty() and Geometry2D.get_closest_point_to_segment(c_screen, across[0], across[1]).distance_to(c_screen) < 0.5, "The diameter line passes through the centre.")
	# Diameter outside: one arrow, on the far side, pointing away from the centre.
	var outside := _layout(s, {"type": "diameter", "refs": [circle]}, Vector2(25, 5))
	_expect(outside.arrows.size() == 1 and (outside.arrows[0].tip as Vector2).x < 500.0, "A diameter with its text outside has one arrow, on the far side.")
	# Old radius text on the curve itself: shown 24 px out.
	var old := _layout(s, {"type": "radius", "refs": [circle]}, Vector2(10, 0))
	_expect(not old.is_empty() and old.arrows.size() == 1 and (old.text.anchor as Vector2).x > 540.0 + 20.0, "A radius whose text sits on the curve is shown outside it.")
	# A partial arc gets an arc extension where the leader misses it.
	var arc: int = s.add_arc(center, s.add_point(Vector2(10, 0) * MM), s.add_point(Vector2(0, 10) * MM))
	var missing := _layout(s, {"type": "radius", "refs": [arc]}, Vector2(-20, -5))
	_expect(missing.polylines.size() == 1, "A radius off a partial arc gets an arc extension (%d)." % missing.polylines.size())
	if missing.polylines.size() == 1:
		var ext: PackedVector2Array = missing.polylines[0]
		var on_circle := true
		for q in ext:
			on_circle = on_circle and absf(q.distance_to(c_screen) - 40.0) < 0.5
		_expect(on_circle and ext[ext.size() - 1].distance_to(missing.arrows[0].tip) < 6.0, "The arc extension runs along the circle to just past the arrow.")
	var hitting := _layout(s, {"type": "radius", "refs": [arc]}, Vector2(20, 20))
	_expect(hitting.polylines.is_empty(), "A radius on the arc itself needs no extension.")


func _check_upright_and_offscreen() -> void:
	for degrees in [100.0, -100.0, 90.0, -90.0, 180.0, 0.0, 179.0, -1.0]:
		var angle := DIM.upright(Vector2.from_angle(deg_to_rad(degrees)))
		_expect(angle > -PI * 0.5 and angle <= PI * 0.5 + 1e-6, "Text along %.0f° stays upright (%f)." % [degrees, angle])
	var s := _sketch()
	var line := _line(s, Vector2(0, 0), Vector2(40, 0))
	var behind := func(p: Vector2) -> Vector2: return Vector2(INF, INF)
	_expect(DIM.screen_layout(DIM.plane_layout(s, {"type": "length", "refs": [line]}, Vector2(0.02, 0.01)), behind, m, TEXT_W, ASCENT, DESCENT).is_empty(),
		"A dimension behind the camera isn't laid out.")
	var scaled := DIM.metrics(1.5)
	_expect(is_equal_approx(float(scaled.arrow_len), 13.5) and is_equal_approx(float(scaled.font), 19.5), "Metrics scale with the UI.")


# --- In a workspace --------------------------------------------------------------------------------

func _check_editor() -> void:
	var ws: Control = WORKSPACE.new()
	ws.theme_store = {}
	root.add_child(ws)
	ws.size = Vector2(1400, 900)
	await _frames(3)
	if ws.kernel == null:
		_expect(false, "The native kernel should load.")
		ws.queue_free()
		return
	var part: Node3D = CAD_PART.new()
	part.document = DOCUMENT.new()
	root.add_child(part)
	ws.set_part(part)
	await process_frame
	ws.set_theme_mode("light")
	ws.create_sketch(SKETCH.ORIGIN_PLANES.xy, "xy")
	await _frames(2)
	var editor: RefCounted = ws.sketch_editor
	editor.ui_scale = 1.0
	editor.start_tool("line")
	editor.tool_click(Vector2(0, 0), {}, {})
	editor.tool_click(Vector2(0.04, 0), {}, {})
	editor.cancel_tool()
	editor.start_tool("circle_center")
	editor.tool_click(Vector2(0.07, 0.01), {}, {})
	editor.tool_click(Vector2(0.08, 0.01), {}, {})
	editor.cancel_tool()
	await process_frame
	var s: SKETCH = editor.sketch()
	var line := int(s.entities().filter(func(e: Dictionary) -> bool: return e.type == "line")[0].id)
	var circle := int(s.entities().filter(func(e: Dictionary) -> bool: return e.type == "circle")[0].id)
	var length_id := await _dimension(ws, editor, [line], Vector2(0.02, -0.012), "40")
	var diameter_id := await _dimension(ws, editor, [circle], Vector2(0.095, 0.025), "20")
	_expect(length_id > 0 and diameter_id > 0, "Two dimensions should be added (%d, %d)." % [length_id, diameter_id])
	ws.viewport.set_view_state({"target": s.to_world(Vector2(0.045, 0.005)), "distance": 0.16})
	await _redraw(ws)

	var p := THEME.palette("light")
	var dims: Array = s.constraints().filter(func(c: Dictionary) -> bool: return c.has("key"))
	_expect(editor._dim_hits.size() == dims.size() and dims.size() == 2, "Every dimension gets hit areas (%d of %d)." % [editor._dim_hits.size(), dims.size()])
	var entry := _hit_entry(editor, length_id)
	_expect(not entry.is_empty() and editor.hit(entry.get("text_center", Vector2.ZERO)) == {"kind": "constraint", "id": length_id}, "The length's text hits it.")
	_expect(editor._dim_draw_log.get(length_id, {}).get("state", "") == "normal" and editor._dim_draw_log[length_id].color == p.dim_line
		and editor._dim_draw_log[length_id].text_color == p.dim_text and editor._dim_draw_log[length_id].text == "40.00", "A plain dimension shows 40.00 in dim_line/dim_text (%s)." % [editor._dim_draw_log.get(length_id, {})])
	_expect(editor._dim_draw_log.get(diameter_id, {}).get("text", "") == "Ø20.00", "The circle shows Ø20.00 (%s)." % editor._dim_draw_log.get(diameter_id, {}).get("text", ""))
	# A point 2 px off the dimension line (away from its text) hits it; the line itself wins under it.
	var dim_line := _longest(entry.get("segments", []).filter(func(seg: Array) -> bool: return absf((seg[0] as Vector2).y - (seg[1] as Vector2).y) < 0.01))
	if not dim_line.is_empty():
		var quarter := (dim_line[0] as Vector2).lerp(dim_line[1], 0.2) + Vector2(0, 2)
		_expect(editor.hit(quarter) == {"kind": "constraint", "id": length_id}, "2 px off the dimension line hits the dimension (%s)." % editor.hit(quarter))
	else:
		_expect(false, "The length should have a level dimension line.")
	var center: Vector2 = s.point(int(s.entity(circle).c))
	var u := (s.to_plane(s.to_world(Vector2(0.095, 0.025))) - center).normalized()
	var on_curve: Vector2 = ws.viewport.project(s.to_world(center + u * 0.01))
	var under: Dictionary = editor.hit(on_curve)
	_expect(under == {"kind": "entity", "id": circle}, "Where the diameter's leader crosses the circle, the circle is picked (%s)." % under)

	# Hover and selection.
	editor.hover = {"kind": "constraint", "id": length_id}
	await _redraw(ws)
	_expect(editor._dim_draw_log[length_id].state == "hovered" and editor._dim_draw_log[length_id].color == p.dim_hover and editor._dim_draw_log[diameter_id].state == "normal",
		"A hovered dimension is drawn in dim_hover (%s)." % [editor._dim_draw_log[length_id]])
	editor.hover = {}
	editor.selection.clear()
	editor.selection.append({"kind": "constraint", "id": diameter_id})
	await _redraw(ws)
	_expect(editor._dim_draw_log[diameter_id].state == "selected" and editor._dim_draw_log[diameter_id].color == p.dim_selected and is_equal_approx(float(editor._dim_draw_log[diameter_id].width), 1.5),
		"A selected dimension is drawn in dim_selected at 1.5 px (%s)." % [editor._dim_draw_log[diameter_id]])
	editor.selection.clear()

	# The value box opens centred on the dimension's text, in the palette's colours, and the
	# dimension's own text hides under it.
	await _redraw(ws)
	entry = _hit_entry(editor, length_id)
	editor.open_dimension_edit(length_id)
	var box: LineEdit = editor._edit
	_expect(box.visible and (box.position + box.size * 0.5).distance_to(entry.get("text_center", Vector2.ZERO)) <= 2.0, "The value box opens centred on the text (%s vs %s)." % [box.position + box.size * 0.5, entry.get("text_center")])
	_expect(box.get_theme_color("font_color") == p.dim_box_text and (box.get_theme_stylebox("normal") as StyleBoxFlat).bg_color == p.dim_box_back and box.alignment == HORIZONTAL_ALIGNMENT_CENTER,
		"The value box takes the palette's dim_box colours.")
	await _redraw(ws)
	_expect(editor._dim_draw_log[length_id].state == "editing" and editor._dim_draw_log[length_id].color == p.dim_selected, "The dimension being edited is drawn selected (%s)." % [editor._dim_draw_log[length_id]])
	editor._close_edit()

	# A driven dimension, one set by an expression, and errors that show the measured value.
	var driven_id := [-1]
	var expression_id := [-1]
	ws.change("Test: Dimensions", func() -> void:
		var live: RefCounted = editor.sketch()
		driven_id[0] = live.add_constraint("length", [line], "", "length", false)
		live.constraint(driven_id[0])["offset"] = Vector2(0, -0.022)
		var name := str(live.feature.inputs[live.constraint(diameter_id).key].name)
		expression_id[0] = live.add_constraint("radius", [circle], name + " / 2")
		live.constraint(expression_id[0])["offset"] = Vector2(0.0, -0.02))
	await _redraw(ws)
	var marker: String = editor._expression_marker(ws.viewport._overlay)
	_expect(editor._dim_draw_log.get(driven_id[0], {}).get("text", "") == "(40.00)", "A driven length shows (40.00) (%s)." % editor._dim_draw_log.get(driven_id[0], {}))
	_expect(editor._dim_draw_log.get(expression_id[0], {}).get("text", "") == marker + "R10.00" and marker in ["ƒ ", "f "],
		"A radius set by an expression carries the marker (%s)." % editor._dim_draw_log.get(expression_id[0], {}))
	var clash_id := [-1]
	ws.change("Test: Clash", func() -> void:
		clash_id[0] = editor.sketch().add_constraint("length", [line], "55")
		editor.sketch().constraint(clash_id[0])["offset"] = Vector2(0, 0.012))
	await _redraw(ws)
	var clash: Dictionary = editor._dim_draw_log.get(clash_id[0], {})
	_expect(clash.get("state", "") == "error" and clash.get("color") == p.dim_error and clash.get("text", "") == "40.00",
		"A clashing dimension shows the measured 40.00 in dim_error (%s)." % clash)
	ws.change("Test: Broken", func() -> void:
		var live: RefCounted = editor.sketch()
		live.remove_constraint(clash_id[0])
		live.feature.set_expression(live.constraint(expression_id[0]).key, "no_such_parameter * 2"))
	await _redraw(ws)
	var broken: Dictionary = editor._dim_draw_log.get(expression_id[0], {})
	_expect(broken.get("state", "") == "error" and broken.get("text", "") == marker + "R10.00", "A broken parameter shows the measured value in the error state (%s)." % broken)

	# The dark palette draws them too.
	ws.set_theme_mode("dark")
	await _redraw(ws)
	var dark := THEME.palette("dark")
	_expect(editor._dim_draw_log[length_id].color == dark.dim_line and editor._dim_draw_log[length_id].text_color == dark.dim_text
		and editor._edit.get_theme_color("font_color") == dark.dim_box_text, "The dark palette's dimension colours are used.")
	ws.set_part(null)
	part.queue_free()
	ws.queue_free()
	await _frames(2)


## Dimensions the picked items with the Sketch Dimension tool, text at place, value typed; the new
## constraint's id.
func _dimension(ws: Control, editor: RefCounted, ids: Array, place: Vector2, value: String) -> int:
	var before: Array = editor.sketch().constraints().map(func(c: Dictionary) -> int: return int(c.id))
	editor.start_tool("dimension")
	for id in ids:
		editor.tool_click(Vector2.ZERO, {}, {"kind": "entity", "id": int(id)})
	editor.mouse_plane = place
	editor.mouse_screen = ws.viewport.project(editor.sketch().to_world(place))
	editor.tool_click(place, {}, {})
	editor._on_edit_submitted(value)
	editor.cancel_tool()
	await process_frame
	for c in editor.sketch().constraints():
		if not before.has(int(c.id)) and c.has("key"):
			return int(c.id)
	return -1


func _hit_entry(editor: RefCounted, id: int) -> Dictionary:
	for entry: Dictionary in editor._dim_hits:
		if int(entry.id) == id:
			return entry
	return {}


func _redraw(ws: Control) -> void:
	ws.sketch_editor.refresh(ws.result)
	ws.viewport._overlay.queue_redraw()
	await _frames(2)


func _frames(count: int) -> void:
	for i in count:
		await process_frame


# --- Placing: orientation, angles, the value box, over-constraint, picks ---------------------------

## linear_orientation on its own: the nearest axis to the cursor's direction from the middle, kept
## while the cursor is less than ANGLE_SNAP past a boundary.
func _check_orientation_rule() -> void:
	var a := Vector2(0, 0)
	var b := Vector2(30, 40) * MM
	var mid := (a + b) * 0.5
	var n := (b - a).normalized().orthogonal()
	_expect(DIM.linear_orientation(a, b, mid + Vector2(0, 30) * MM, true) == "distance_x", "Above a slanted pair is horizontal.")
	_expect(DIM.linear_orientation(a, b, mid + Vector2(30, 0) * MM, true) == "distance_y", "Beside a slanted pair is vertical.")
	_expect(DIM.linear_orientation(a, b, mid + n * 30.0 * MM, true) == "aligned" and DIM.linear_orientation(a, b, mid - n * 30.0 * MM, true) == "aligned",
		"Square off a slanted pair (either side) is aligned.")
	# The horizontal/aligned boundary lies halfway between plane Y (90°) and the normal's direction.
	var boundary := (PI * 0.5 + fposmod(n.angle(), PI)) * 0.5
	var past := mid + Vector2.from_angle(boundary + deg_to_rad(2.0)) * 0.03
	_expect(DIM.linear_orientation(a, b, past, true) == "aligned" and DIM.linear_orientation(a, b, past, true, "", "distance_x") == "distance_x",
		"2° past the horizontal/aligned boundary it is aligned, but stays horizontal when it was.")
	_expect(DIM.linear_orientation(a, b, mid + Vector2.from_angle(boundary + deg_to_rad(5.0)) * 0.03, true, "", "distance_x") == "aligned",
		"5° past the boundary it changes.")
	_expect(DIM.linear_orientation(a, Vector2(0.04, 0.0), Vector2(0.02, 0.0) + Vector2(0.01, 0.01), true) == "aligned"
		and DIM.linear_orientation(a, Vector2(0.04, 0.0), Vector2(0.06, 0.0), false) == "distance_x"
		and DIM.linear_orientation(a, Vector2(0.0, 0.04), Vector2(0.03, 0.02), false) == "distance_y", "Level and upright pairs keep their one orientation.")


func _check_behaviour() -> void:
	var ws: Control = WORKSPACE.new()
	ws.theme_store = {}
	root.add_child(ws)
	ws.size = Vector2(1400, 900)
	await _frames(3)
	if ws.kernel == null:
		_expect(false, "The native kernel should load.")
		ws.queue_free()
		return
	await _check_placing(ws)
	await _check_angles(ws)
	await _check_legacy_angle(ws)
	await _check_value_box(ws)
	await _check_box_lifetime(ws)
	await _check_driven(ws)
	await _check_picks(ws)
	await _check_insert_parameter(ws)
	await _check_tooltip_and_pill(ws)
	await _check_drag_text(ws)
	await _check_placing_options(ws)
	await _check_placed_options(ws)
	await _check_broken_users(ws)
	await _check_fully_define(ws)
	await _check_edges(ws)
	await _check_three_point_and_sweep(ws)
	await _check_linear_diameter(ws)
	await _check_rename(ws)
	await _check_small_items(ws)
	await _check_review_fixes(ws)
	var part: Node3D = ws.part
	ws.set_part(null)
	if part != null:
		part.queue_free()
	ws.queue_free()
	await _frames(2)


## A new part with an empty sketch on XY, the view on center_mm.
func _fresh(ws: Control, center_mm := Vector2(20, 20)) -> RefCounted:
	var old: Node3D = ws.part
	if old != null:
		ws.set_part(null)
		old.queue_free()
	var part: Node3D = CAD_PART.new()
	part.document = DOCUMENT.new()
	root.add_child(part)
	ws.set_part(part)
	await process_frame
	ws.create_sketch(SKETCH.ORIGIN_PLANES.xy, "xy")
	await _frames(2)
	var editor: RefCounted = ws.sketch_editor
	editor.ui_scale = 1.0
	editor.driven_answer = ""
	var s: SKETCH = editor.sketch()
	ws.viewport.set_view_state({"target": s.to_world(center_mm * MM), "distance": 0.16})
	await _redraw(ws)
	return editor


## A point at exact (double) plane coordinates in mm.
func _pt(s: SKETCH, x_mm: float, y_mm: float) -> int:
	var id := s.add_point(Vector2.ZERO)
	s.entity(id)["x"] = x_mm * MM
	s.entity(id)["y"] = y_mm * MM
	return id


## Lines between points (mm: whole-mm Vector2s, or [x, y] for exact doubles) as one undo step:
## [[from, to], ...] -> line ids; a point two segments share is one point.
func _lines(ws: Control, segments: Array) -> Array:
	var made := []
	ws.change("Test: Lines", func() -> void:
		var s: SKETCH = ws.sketch_editor.sketch()
		var points := {}
		for segment: Array in segments:
			var ids := []
			for p: Variant in segment:
				var x: float = (p as Vector2).x if p is Vector2 else float(p[0])
				var y: float = (p as Vector2).y if p is Vector2 else float(p[1])
				var key := "%.12f %.12f" % [x, y]
				if not points.has(key):
					points[key] = _pt(s, x, y)
				ids.append(points[key])
			made.append(s.add_line(ids[0], ids[1])))
	await process_frame
	return made


## Picks the items with Sketch Dimension and clicks at place_mm (no value typed).
func _place(editor: RefCounted, ids: Array, place_mm: Vector2) -> void:
	editor.start_tool("dimension")
	for id in ids:
		editor.tool_click(Vector2.ZERO, {}, {"kind": "entity", "id": int(id)})
	editor.tool_click(place_mm * MM, {}, {})


func _dimension_ids(editor: RefCounted) -> Array:
	return editor.sketch().constraints().filter(func(c: Dictionary) -> bool: return c.has("key")).map(func(c: Dictionary) -> int: return int(c.id))


## From point a to point b in double precision: [x, y].
func _between(s: SKETCH, a: int, b: int) -> PackedFloat64Array:
	return PackedFloat64Array([float(s.entity(b).x) - float(s.entity(a).x), float(s.entity(b).y) - float(s.entity(a).y)])


func _direction(s: SKETCH, line: int) -> PackedFloat64Array:
	var e: Dictionary = s.entity(line)
	var dx := float(s.entity(int(e.p2)).x) - float(s.entity(int(e.p1)).x)
	var dy := float(s.entity(int(e.p2)).y) - float(s.entity(int(e.p1)).y)
	var length := sqrt(dx * dx + dy * dy)
	return PackedFloat64Array([dx / length, dy / length])


func _length(s: SKETCH, line: int) -> float:
	var e: Dictionary = s.entity(line)
	var dx := float(s.entity(int(e.p2)).x) - float(s.entity(int(e.p1)).x)
	var dy := float(s.entity(int(e.p2)).y) - float(s.entity(int(e.p1)).y)
	return sqrt(dx * dx + dy * dy)


## The angle in degrees between two directions [x, y].
func _opening(u: PackedFloat64Array, v: PackedFloat64Array) -> float:
	return rad_to_deg(absf(atan2(u[0] * v[1] - u[1] * v[0], u[0] * v[0] + u[1] * v[1])))


func _motion(ws: Control, editor: RefCounted, place_mm: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = ws.viewport.project(editor.sketch().to_world(place_mm * MM))
	editor.handle_mouse(motion)
	await _redraw(ws)


func _press_release(editor: RefCounted, screen: Vector2) -> void:
	for pressed in [true, false]:
		var button := InputEventMouseButton.new()
		button.button_index = MOUSE_BUTTON_LEFT
		button.pressed = pressed
		button.position = screen
		editor.handle_mouse(button)


## H/V/aligned by where the cursor is, level lines and pairs, and the live preview.
func _check_placing(ws: Control) -> void:
	var editor: RefCounted = await _fresh(ws)
	var lines: Array = await _lines(ws, [[Vector2(0, 0), Vector2(30, 40)], [Vector2(0, -20), Vector2(40, -20)]])
	var s: SKETCH = editor.sketch()
	var slanted: int = lines[0]
	var e: Dictionary = s.entity(slanted)
	var mid := Vector2(15, 20)
	var n := Vector2(30, 40).normalized().orthogonal()
	var spec: Dictionary = editor.dimension_spec([slanted], (mid + Vector2(0, 30)) * MM)
	_expect(spec.get("type", "") == "distance_x" and absf(float(spec.get("value", 0.0)) - 0.03) < 1e-12 and spec.get("refs", []) == [int(e.p1), int(e.p2)],
		"Above a slanted line it is horizontal, 30 mm, refs left to right (%s)." % spec)
	spec = editor.dimension_spec([slanted], (mid + Vector2(30, 0)) * MM)
	_expect(spec.get("type", "") == "distance_y" and absf(float(spec.get("value", 0.0)) - 0.04) < 1e-12, "Beside it, vertical 40 mm (%s)." % spec)
	for side in [1.0, -1.0]:
		spec = editor.dimension_spec([slanted], (mid + n * 30.0 * side) * MM)
		_expect(spec.get("type", "") == "length" and absf(float(spec.get("value", 0.0)) - 0.05) < 1e-12, "Square off it, aligned 50 mm (%s)." % spec)
	for place in [Vector2(20, 0), Vector2(60, -20), Vector2(20, -40), Vector2(-30, -10)]:
		spec = editor.dimension_spec([lines[1]], place * MM)
		_expect(spec.get("type", "") == "length", "A level line is always its length (%s at %s)." % [spec.get("type", ""), place])
	var level: Array = [int(s.entity(lines[1]).p1), int(s.entity(lines[1]).p2)]
	for place in [Vector2(20, 0), Vector2(70, -20)]:
		_expect(editor.dimension_spec(level, place * MM).get("type", "") == "distance_x", "Two level points are horizontal wherever the text goes (%s)." % place)

	# The preview follows the cursor from the first pick on, and the placing click opens the box on it.
	editor.start_tool("dimension")
	editor.tool_click(Vector2.ZERO, {}, {"kind": "entity", "id": slanted})
	_expect(str(ws.last_message).contains("pick a second item"), "The first pick asks for a second item or the placement (%s)." % ws.last_message)
	await _motion(ws, editor, mid + Vector2(0, 30))
	_expect(editor._preview_dimension.get("type", "") == "distance_x" and editor._dim_draw_log.get(-1, {}).get("state", "") == "preview"
		and editor._dim_draw_log.get(-1, {}).get("text", "") == "30.00", "Above the line the preview is horizontal, 30.00, in the preview look (%s)." % [editor._dim_draw_log.get(-1, {})])
	await _motion(ws, editor, mid + Vector2(30, 0))
	_expect(editor._preview_dimension.get("type", "") == "distance_y", "To its right the preview turns vertical (%s)." % editor._preview_dimension.get("type", ""))
	await _motion(ws, editor, mid + n * 20.0)
	_expect(editor._preview_dimension.get("type", "") == "length", "Square off it the preview is aligned (%s)." % editor._preview_dimension.get("type", ""))
	editor.tool_click(editor.mouse_plane_raw, {}, {})
	await _redraw(ws)
	_expect(editor._edit.visible and editor._pending_dimension.get("type", "") == "length" and editor._dim_draw_log.get(-1, {}).get("state", "") == "editing",
		"The placing click opens the box on the aligned length, drawn as being edited (%s)." % [editor._dim_draw_log.get(-1, {})])
	editor.cancel_tool()


## Angles: the sector by placement, a positive sweep, no mirroring, chains, driven sweeps.
func _check_angles(ws: Control) -> void:
	var c30 := cos(deg_to_rad(30.0)) * 40.0
	var s30 := sin(deg_to_rad(30.0)) * 40.0
	var expected := [[Vector2(30, -5), 30.0], [Vector2(0, 10), 150.0], [Vector2(-30, 5), 30.0], [Vector2(0, -10), 150.0]]
	var editor: RefCounted = await _fresh(ws, Vector2(10, 0))
	var v: Array = await _lines(ws, [[Vector2(0, 0), Vector2(40, 0)], [Vector2(0, 0), [c30, -s30]]])
	for case: Array in expected:
		var spec: Dictionary = editor.dimension_spec(v, (case[0] as Vector2) * MM)
		_expect(spec.get("type", "") == "angle" and absf(rad_to_deg(float(spec.get("value", 0.0))) - float(case[1])) < 1e-9 and (spec.get("rays", []) as Array).size() == 2,
			"Placed at %s the angle is %.0f° (%s)." % [case[0], case[1], spec])
	# The prefilled value commits without moving anything.
	var s: SKETCH = editor.sketch()
	var before := [_direction(s, v[0]), _direction(s, v[1])]
	_place(editor, v, Vector2(30, -5))
	_expect(editor._edit.visible and editor._edit.text == "30 deg", "The box offers the visible 30 deg (%s)." % editor._edit.text)
	editor._on_edit_submitted(editor._edit.text)
	await process_frame
	s = editor.sketch()
	var after := [_direction(s, v[0]), _direction(s, v[1])]
	var still := true
	for i in 2:
		still = still and absf(after[i][0] - before[i][0]) < 1e-9 and absf(after[i][1] - before[i][1]) < 1e-9
	_expect(still and ws.last_step.get("name", "") == "Sketch: Dimension", "Committing the prefilled angle leaves both lines where they were (%s -> %s)." % [before, after])
	# 45: the opening becomes 45° on the same side (no mirroring).
	editor = await _fresh(ws, Vector2(10, 0))
	v = await _lines(ws, [[Vector2(0, 0), Vector2(40, 0)], [Vector2(0, 0), [c30, -s30]]])
	s = editor.sketch()
	var cross_before := signf(_direction(s, v[0])[0] * _direction(s, v[1])[1] - _direction(s, v[0])[1] * _direction(s, v[1])[0])
	_place(editor, v, Vector2(30, -5))
	editor._on_edit_submitted("45")
	await process_frame
	s = editor.sketch()
	var d0 := _direction(s, v[0])
	var d1 := _direction(s, v[1])
	_expect(absf(_opening(d0, d1) - 45.0) < 1e-7 and signf(d0[0] * d1[1] - d0[1] * d1[0]) == cross_before, "Typing 45 opens the V to 45° without mirroring it (%f)." % _opening(d0, d1))

	# A V drawn as one chain: the visible 53.13°, and 60 opens it on the same sides.
	editor = await _fresh(ws, Vector2(120, 0))
	var chain: Array = await _lines(ws, [[Vector2(140, 20), Vector2(100, 0)], [Vector2(100, 0), Vector2(140, -20)]])
	s = editor.sketch()
	var spec: Dictionary = editor.dimension_spec(chain, Vector2(130, 0) * MM)
	_expect(absf(rad_to_deg(float(spec.get("value", 0.0))) - 53.130102354) < 1e-6, "Inside a chained V the angle is 53.1301° (%s)." % spec)
	_place(editor, chain, Vector2(130, 0))
	editor._on_edit_submitted("60")
	await process_frame
	s = editor.sketch()
	var vertex := int(s.entity(chain[0]).p2)
	var top := _between(s, vertex, int(s.entity(chain[0]).p1))
	var bottom := _between(s, vertex, int(s.entity(chain[1]).p2))
	var opening := _opening(top, bottom)
	_expect(absf(opening - 60.0) < 1e-7 and top[1] > 0.0 and bottom[1] < 0.0 and top[0] > 0.0 and bottom[0] > 0.0,
		"Typing 60 opens the chain to 60° with its ends on their own sides (%.9f, %s, %s)." % [opening, top, bottom])

	# Driven: a V whose lines are fixed measures its sweep (one ray against its line).
	editor = await _fresh(ws, Vector2(120, 0))
	chain = await _lines(ws, [[Vector2(140, 20), Vector2(100, 0)], [Vector2(100, 0), Vector2(140, -20)]])
	ws.change("Test: Fix", func() -> void:
		var live: SKETCH = editor.sketch()
		for line in chain:
			live.add_constraint("fix", [int(line)]))
	await process_frame
	editor.driven_answer = "ok"
	_place(editor, chain, Vector2(130, 0))
	await _redraw(ws)
	s = editor.sketch()
	var driven: Array = s.constraints().filter(func(c: Dictionary) -> bool: return c.type == "angle" and not c.get("driving", true))
	var measured: float = float(ws.result.sketches[editor.feature_id].solve.measured.get(int(driven[0].id), -1.0)) if driven.size() == 1 else -1.0
	_expect(driven.size() == 1 and absf(rad_to_deg(measured) - 53.130102354) < 1e-6 and editor._dim_draw_log.get(int(driven[0].id) if driven.size() == 1 else -2, {}).get("text", "") == "(53.1°)",
		"A driven angle on fixed lines measures the sweep, (53.1°) (%f)." % rad_to_deg(measured))
	editor.cancel_tool()


## An angle saved before rays existed solves as it always did, and Enter on its value keeps it.
func _check_legacy_angle(ws: Control) -> void:
	var editor: RefCounted = await _fresh(ws)
	var ids := {}
	ws.change("Test: Legacy", func() -> void:
		var s: SKETCH = editor.sketch()
		var a := _pt(s, 10, 0)
		ids.l1 = s.add_line(a, _pt(s, 50, 2))
		var b := _pt(s, 12, 1)
		ids.l2 = s.add_line(b, _pt(s, 40, -35))
		ids.l3 = s.add_line(_pt(s, 60, 10), _pt(s, 90, -20))
		s.entity(a)["fixed"] = true
		s.entity(b)["fixed"] = true
		s.add_constraint("horizontal", [ids.l1])
		s.add_constraint("length", [ids.l1], "40")
		s.add_constraint("length", [ids.l2], "30")
		ids.angle = s.add_constraint("angle", [ids.l2, ids.l1], "60", "angle")
		s.constraint(ids.angle)["offset"] = Vector2(0.005, -0.01)
		ids.driven = s.add_constraint("angle", [ids.l1, ids.l3], "", "angle", false))
	await _redraw(ws)
	var s: SKETCH = editor.sketch()
	var solve: Dictionary = ws.result.sketches[editor.feature_id].solve
	# The solver still gets 60° from l2's direction to l1's: l2 points 60° below level.
	var tip := s.point_xy(int(s.entity(ids.l2).p2))
	var expected := PackedFloat64Array([0.012 + 0.5 * 0.03, 0.001 - sqrt(3.0) * 0.5 * 0.03])
	_expect(bool(solve.ok) and (solve.warnings as Array).is_empty() and absf(tip[0] - expected[0]) < 1e-9 and absf(tip[1] - expected[1]) < 1e-9,
		"A legacy angle solves as before (%s vs %s, %s)." % [tip, expected, solve.warnings])
	var d1 := _direction(s, ids.l1)
	var d3 := _direction(s, ids.l3)
	var raw := atan2(d1[0] * d3[1] - d1[1] * d3[0], d1[0] * d3[0] + d1[1] * d3[1])
	_expect(absf(angle_difference(float(solve.measured.get(ids.driven, 0.0)), raw)) < 1e-9, "A legacy driven angle measures as before (%s)." % solve.measured)
	_expect(not s.constraint(ids.angle).has("rays"), "Rebuilding adds nothing to a legacy angle.")
	# It shows the sector its value is: 60.0°, the arc over 60°.
	var shown: Dictionary = editor._shown_dimension(s, s.constraint(ids.angle))
	_expect(editor._dim_draw_log.get(ids.angle, {}).get("text", "") == "60.0°" and absf(rad_to_deg(editor._sweep(s, shown.refs, shown.rays)) - 60.0) < 1e-6,
		"A legacy angle is shown in the sector its value is (%s, %s)." % [editor._dim_draw_log.get(ids.angle, {}), shown])
	# Enter on its unchanged value changes nothing: no rays, no step, nothing moves.
	var tip_before := tip
	editor.open_dimension_edit(ids.angle)
	_expect(editor._edit.visible and editor._edit.text == "60", "A legacy angle opens with its expression (%s)." % editor._edit.text)
	ws.last_step = {}
	editor._on_edit_submitted(editor._edit.text)
	await _redraw(ws)
	s = editor.sketch()
	tip = s.point_xy(int(s.entity(ids.l2).p2))
	_expect(not s.constraint(ids.angle).has("rays") and absf(tip[0] - tip_before[0]) < 1e-12 and absf(tip[1] - tip_before[1]) < 1e-12 and ws.last_step.is_empty() and not editor._edit.visible,
		"Entering a legacy angle's own value changes nothing (%s, %s, %s)." % [s.constraint(ids.angle), tip, ws.last_step.get("name", "")])
	# A new value gets rays for the sector shown, and that sector takes it.
	editor.open_dimension_edit(ids.angle)
	editor._on_edit_submitted("50")
	await _redraw(ws)
	s = editor.sketch()
	var upgraded: Dictionary = s.constraint(ids.angle)
	_expect(upgraded.has("rays") and absf(rad_to_deg(editor._sweep(s, upgraded.refs, upgraded.rays)) - 50.0) < 1e-6 and absf(_opening(_direction(s, ids.l1), _direction(s, ids.l2)) - 50.0) < 1e-6
		and ws.last_step.get("name", "") == "Sketch: Edit Dimension", "A legacy angle edited to 50 opens the shown sector to 50° (%s, %f)." % [upgraded, _opening(_direction(s, ids.l1), _direction(s, ids.l2))])
	editor.cancel_tool()


## The value box: prefill, centring, refusals, a good value, an impossible edit.
func _check_value_box(ws: Control) -> void:
	var editor: RefCounted = await _fresh(ws, Vector2(15, 20))
	var lines: Array = await _lines(ws, [[Vector2(0, 0), Vector2(30, 40)]])
	var line: int = lines[0]
	var n := Vector2(30, 40).normalized().orthogonal()
	_place(editor, [line], Vector2(15, 20) + n * 12.0)
	var box: LineEdit = editor._edit
	var s: SKETCH = editor.sketch()
	var pending: Dictionary = editor._pending_dimension
	var layout: Dictionary = editor._layout_for(s, editor._pseudo_dimension(pending), DIM.canvas_text(pending, float(pending.get("value", 0.0)), "mm", "", ""))
	_expect(box.visible and box.text == "50 mm" and box.get_selected_text() == box.text, "The box opens with all of the measured 50 mm selected (%s)." % box.text)
	_expect((box.position + box.size * 0.5).distance_to(layout.get("text_center", Vector2.INF)) <= 2.0, "The box is centred on the dimension's text (%s vs %s)." % [box.position + box.size * 0.5, layout.get("text_center")])
	var p: Dictionary = editor.theme_colors
	var count: int = _dimension_ids(editor).size()
	for bad in ["abc", "20 deg", "-10", "0", ""]:
		box.text = bad
		box.text_changed.emit(bad)
		_expect(box.get_theme_color("font_color") == p.dim_box_invalid and box.tooltip_text != "", "'%s' shows as invalid while typed." % bad)
		editor._on_edit_submitted(bad)
		_expect(_dimension_ids(editor).size() == count and box.visible and box.get_theme_color("font_color") == p.dim_box_invalid and str(ws.last_message).begins_with("Dimension: "),
			"'%s' is refused and the box stays (%s)." % [bad, ws.last_message])
	editor._on_edit_submitted("40")
	await process_frame
	s = editor.sketch()
	_expect(_dimension_ids(editor).size() == count + 1 and absf(_length(s, line) - 0.04) < 1e-9 and ws.last_step.get("name", "") == "Sketch: Dimension"
		and not box.visible and editor.tool == "dimension" and editor.tool_picks.is_empty(), "40 is taken: the line is 40 mm, one step, ready for the next dimension.")
	editor.cancel_tool()

	# An edit the sketch can't take is refused and nothing moves.
	editor = await _fresh(ws, Vector2(20, 15))
	editor.start_tool("rect_2pt")
	editor.tool_click(Vector2(0, 0), {}, {})
	editor.tool_click(Vector2(0.04, 0.03), {}, {})
	await process_frame
	s = editor.sketch()
	var bottom := -1
	var corners := [-1, -1]
	for e in s.entities():
		if e.type == "line" and absf(s.point(int(e.p1)).y) < 1e-9 and absf(s.point(int(e.p2)).y) < 1e-9:
			bottom = int(e.id)
		elif e.type == "point" and not e.get("origin", false):
			if s.point(int(e.id)).distance_to(Vector2.ZERO) < 1e-9:
				corners[0] = int(e.id)
			elif s.point(int(e.id)).distance_to(Vector2(0.04, 0.03)) < 1e-7:
				corners[1] = int(e.id)
	_place(editor, [bottom], Vector2(20, -10))
	editor._on_edit_submitted("40")
	await process_frame
	var diagonal_n := Vector2(40, 30).normalized().orthogonal()
	_place(editor, corners, Vector2(20, 15) + diagonal_n * 20.0)
	_expect(editor._pending_dimension.get("type", "") == "distance", "Two corners placed square to the diagonal measure along it (%s)." % editor._pending_dimension)
	editor._on_edit_submitted("50")
	await _redraw(ws)
	s = editor.sketch()
	var diagonals: Array = _dimension_ids(editor).filter(func(id: int) -> bool: return s.constraint(id).type == "distance")
	var diagonal: int = diagonals[0] if not diagonals.is_empty() else -1
	var at_before := [s.point_xy(corners[0]), s.point_xy(corners[1])]
	editor.cancel_tool()
	await _redraw(ws)
	editor.open_dimension_edit(diagonal)
	_expect(box.visible and box.text == "50", "Editing the diagonal shows its expression (%s)." % box.text)
	editor._on_edit_submitted("30")
	await process_frame
	s = editor.sketch()
	_expect(box.visible and s.dimension_expression(diagonal) == "50" and s.point_xy(corners[0]) == at_before[0] and s.point_xy(corners[1]) == at_before[1]
		and bool(editor.state.solve.ok) and str(ws.last_message).contains("can't be solved"), "A diagonal shorter than the width is refused and nothing moves (%s)." % ws.last_message)
	editor._end_edit()


## The box closes with the tool, Esc, an undo, and a click away (taking or dropping the value).
func _check_box_lifetime(ws: Control) -> void:
	var editor: RefCounted = await _fresh(ws, Vector2(20, 0))
	var lines: Array = await _lines(ws, [[Vector2(0, 0), Vector2(40, 0)], [Vector2(0, 20), Vector2(40, 20)]])
	var box: LineEdit = editor._edit
	_place(editor, [lines[0]], Vector2(20, -10))
	editor.start_tool("line")
	_expect(not box.visible and editor.tool == "line", "Starting another tool closes the box.")
	_place(editor, [lines[0]], Vector2(20, -10))
	editor.handle_key(_key(KEY_ESCAPE))
	_expect(not box.visible and editor.tool_picks.is_empty() and editor.tool == "dimension" and _dimension_ids(editor).is_empty(), "Esc in the view closes the box; the tool stays.")
	_place(editor, [lines[0]], Vector2(20, -10))
	box.gui_input.emit(_key(KEY_ESCAPE))
	_expect(not box.visible and editor.tool_picks.is_empty() and editor.tool == "dimension" and _dimension_ids(editor).is_empty(), "Esc in the box adds nothing; the tool stays.")
	# A click away takes a good value and drops a bad one; the click itself picks nothing.
	var away: Vector2 = ws.viewport.project(editor.sketch().to_world(Vector2(0.02, 0.045)))
	_place(editor, [lines[0]], Vector2(20, -10))
	box.text = "35"
	_press_release(editor, away)
	_expect(not box.visible and _dimension_ids(editor).size() == 1 and absf(_length(editor.sketch(), lines[0]) - 0.035) < 1e-9 and editor.tool_picks.is_empty(),
		"A click away with a good value commits it.")
	_place(editor, [lines[1]], Vector2(20, 30))
	box.text = "abc"
	_press_release(editor, away)
	_expect(not box.visible and _dimension_ids(editor).size() == 1 and editor.tool_picks.is_empty() and editor.tool == "dimension", "A click away with a bad value drops it.")
	# An undo that takes the edited dimension away closes its box.
	editor.cancel_tool()
	await _redraw(ws)
	var before: Dictionary = ws.last_step.get("before", {})
	editor.open_dimension_edit(_dimension_ids(editor)[0])
	_expect(box.visible, "Double-click editing opens the box.")
	ws._apply_snapshot(ws.part, before)
	await process_frame
	_expect(not box.visible and _dimension_ids(editor).is_empty(), "Undoing the dimension closes its box.")


## Over-constraint: the driven question, driven to driving, the Driven choice, trial isolation.
func _check_driven(ws: Control) -> void:
	var editor: RefCounted = await _fresh(ws, Vector2(20, 15))
	editor.start_tool("rect_2pt")
	editor.tool_click(Vector2(0, 0), {}, {})
	editor.tool_click(Vector2(0.04, 0.03), {}, {})
	await process_frame
	var s: SKETCH = editor.sketch()
	var bottom := -1
	for e in s.entities():
		if e.type == "line" and absf(s.point(int(e.p1)).y) < 1e-9 and absf(s.point(int(e.p2)).y) < 1e-9:
			bottom = int(e.id)
	_place(editor, [bottom], Vector2(20, -10))
	editor._on_edit_submitted("40")
	await process_frame
	var counter: int = int(ws.doc.counters.get("d", 0))
	editor.driven_answer = "cancel"
	_place(editor, [bottom], Vector2(20, -20))
	_expect(_dimension_ids(editor).size() == 1 and not editor._edit.visible and editor.tool_picks.is_empty() and editor.tool == "dimension", "Answering no adds nothing.")
	editor.driven_answer = "ok"
	_place(editor, [bottom], Vector2(20, -20))
	await _redraw(ws)
	s = editor.sketch()
	var driven: Array = s.constraints().filter(func(c: Dictionary) -> bool: return c.has("key") and not c.get("driving", true))
	_expect(driven.size() == 1 and not editor._edit.visible and ws.last_step.get("name", "") == "Sketch: Driven Dimension" and int(ws.doc.counters.get("d", 0)) == counter
		and absf(_length(s, bottom) - 0.04) < 1e-9, "Answering yes adds one driven dimension, no box, no parameter, the bottom still 40 mm.")
	# Made driving at 60 it would over-constrain: it stays driven.
	editor.cancel_tool()
	await _redraw(ws)
	var driven_id := int(driven[0].id) if driven.size() == 1 else -1
	editor.open_dimension_edit(driven_id)
	_expect(editor._edit.visible and editor._edit.text == "40 mm", "A driven dimension opens with what it measures (%s)." % editor._edit.text)
	editor._on_edit_submitted("60")
	await process_frame
	s = editor.sketch()
	_expect(not s.constraint(driven_id).get("driving", true) and bool(editor.state.solve.ok) and str(ws.last_message).contains("stays driven") and not editor._edit.visible,
		"Making it driving at 60 is refused; it stays driven (%s)." % ws.last_message)
	# The Driven choice adds a free line's dimension driven, without the box.
	var free: Array = await _lines(ws, [[Vector2(0, 50), Vector2(30, 50)]])
	editor.start_tool("dimension")
	editor.tool_click(Vector2.ZERO, {}, {"kind": "entity", "id": free[0]})
	editor._dim_overrides.driven = true
	editor.tool_click(Vector2(0.015, 0.06), {}, {})
	s = editor.sketch()
	_expect(not editor._edit.visible and s.constraints().any(func(c: Dictionary) -> bool: return c.has("key") and not c.get("driving", true) and c.refs == [free[0]]),
		"With Driven chosen the dimension is added driven, no box.")
	# A trial changes nothing real.
	var snapshot: Dictionary = ws.doc.snapshot()
	var step: Dictionary = ws.last_step
	var trial: Dictionary = editor._trial(func(sk: SKETCH) -> void: sk.add_constraint("length", [free[0]], "12"))
	var now: Dictionary = ws.doc.snapshot()
	var same: bool = now.counters == snapshot.counters and now.features.size() == snapshot.features.size()
	for i in now.features.size():
		same = same and now.features[i].options == snapshot.features[i].options and now.features[i].inputs == snapshot.features[i].inputs
	_expect(same and is_same(ws.last_step, step) and (trial.get("added", []) as Array).size() == 1, "A trial leaves the document, its counters and the history alone.")
	editor.cancel_tool()


## Picks: the same item again or its own point places; a third item places; Esc in stages; a lone
## point says so.
func _check_picks(ws: Control) -> void:
	var editor: RefCounted = await _fresh(ws, Vector2(20, 0))
	var lines: Array = await _lines(ws, [[Vector2(0, 0), Vector2(40, 0)], [Vector2(0, 20), Vector2(40, 20)]])
	var s: SKETCH = editor.sketch()
	var line: int = lines[0]
	editor.start_tool("dimension")
	editor.tool_click(Vector2.ZERO, {}, {"kind": "entity", "id": line})
	editor.tool_click(Vector2(0.02, -0.01), {}, {"kind": "entity", "id": line})
	_expect(editor._edit.visible and editor._pending_dimension.get("type", "") == "length" and editor.tool_picks.size() == 1, "Clicking the picked line again places its length.")
	editor.handle_key(_key(KEY_ESCAPE))
	editor.tool_click(Vector2.ZERO, {}, {"kind": "entity", "id": line})
	editor.tool_click(Vector2(0.0, -0.01), {}, {"kind": "entity", "id": int(s.entity(line).p1)})
	_expect(editor._edit.visible and editor._pending_dimension.get("type", "") == "length", "Clicking the line's own end point places its length.")
	editor.handle_key(_key(KEY_ESCAPE))
	var a := int(s.entity(line).p1)
	var b := int(s.entity(lines[1]).p2)
	editor.tool_click(Vector2.ZERO, {}, {"kind": "entity", "id": a})
	editor.tool_click(Vector2.ZERO, {}, {"kind": "entity", "id": b})
	_expect(editor.tool_picks.size() == 2 and str(ws.last_message).contains("click where the dimension goes"), "Two points make a pair (%s)." % ws.last_message)
	editor.tool_click(Vector2(0.06, 0.01), {}, {"kind": "entity", "id": lines[1]})
	_expect(editor._edit.visible and editor.tool_picks.size() == 2 and (editor._pending_dimension.get("refs", []) as Array).size() == 2, "A click on a third item places the pair's dimension.")
	editor.handle_key(_key(KEY_ESCAPE))
	editor.tool_click(Vector2.ZERO, {}, {"kind": "entity", "id": a})
	editor.handle_key(_key(KEY_ESCAPE))
	_expect(editor.tool_picks.is_empty() and editor.tool == "dimension", "Esc with picks clears them and keeps the tool.")
	editor.handle_key(_key(KEY_ESCAPE))
	_expect(editor.tool == "", "Esc again ends the tool.")
	editor.start_tool("dimension")
	editor.tool_click(Vector2.ZERO, {}, {"kind": "entity", "id": a})
	editor.tool_click(Vector2.ZERO, {}, {"kind": "entity", "id": a})
	_expect(not editor._edit.visible and editor.tool_picks.is_empty() and str(ws.last_message) == "Pick a second item to measure a point from.", "A point picked twice asks for a second item (%s)." % ws.last_message)
	editor.tool_click(Vector2(0.05, 0.05), {}, {})
	_expect(str(ws.last_message) == "Sketch Dimension: pick a line, circle, arc or point.", "A click on nothing with no picks says what to pick (%s)." % ws.last_message)
	editor.cancel_tool()


func _key(keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	return event


# --- After placing: parameters in the box, tips, drags, right-click options, Fully Define ---------

## A dimension's parameter name.
func _name_of(editor: RefCounted, id: int) -> String:
	var s: SKETCH = editor.sketch()
	return str(s.feature.inputs.get(s.constraint(id).get("key", ""), {}).get("name", ""))


## The dimension (with a parameter or driven) added on refs, -1 for none.
func _dimension_on(editor: RefCounted, refs: Array) -> int:
	for c in editor.sketch().constraints():
		if c.has("key") and (c.refs as Array) == refs:
			return int(c.id)
	return -1


## A circle about (x, y) mm of radius r mm, as one step; its id.
func _circle(ws: Control, x_mm: float, y_mm: float, r_mm: float) -> int:
	var made := [-1]
	ws.change("Test: Circle", func() -> void:
		var s: SKETCH = ws.sketch_editor.sketch()
		made[0] = s.add_circle(_pt(s, x_mm, y_mm), r_mm * MM))
	await process_frame
	return made[0]


## Adds a dimension directly (type on refs, expression; driving unless expression is ""), its
## text offset (mm) from what it measures; its id.
func _add(ws: Control, type: String, refs: Array, expression: String, offset_mm: Vector2) -> int:
	var made := [-1]
	ws.change("Test: Dimension", func() -> void:
		var s: SKETCH = ws.sketch_editor.sketch()
		made[0] = s.add_constraint(type, refs, expression, "angle" if type == "angle" else "length", expression != "")
		s.constraint(made[0])["offset"] = offset_mm * MM)
	await process_frame
	return made[0]


func _entry(entries: Array, label: String) -> Dictionary:
	for each: Dictionary in entries:
		if str(each.label) == label:
			return each
	return {}


func _labels(entries: Array) -> Array:
	return entries.map(func(each: Dictionary) -> String: return str(each.label))


func _move(editor: RefCounted, screen: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = screen
	editor.handle_mouse(motion)


func _button(editor: RefCounted, screen: Vector2, pressed: bool) -> void:
	var button := InputEventMouseButton.new()
	button.button_index = MOUSE_BUTTON_LEFT
	button.pressed = pressed
	button.position = screen
	editor.handle_mouse(button)


func _pick_ids(editor: RefCounted) -> Array:
	return editor.tool_picks.map(func(pick: Dictionary) -> int: return int(pick.id))


## A click on a dimension while the box is open puts its parameter name in; it follows that
## parameter; "d1 +" and another name gives "d1 + d2".
func _check_insert_parameter(ws: Control) -> void:
	var editor: RefCounted = await _fresh(ws, Vector2(20, 20))
	var lines: Array = await _lines(ws, [[Vector2(0, 0), Vector2(40, 0)], [Vector2(0, 20), Vector2(30, 20)], [Vector2(0, 40), Vector2(25, 40)]])
	var d1: int = await _dimension(ws, editor, [lines[0]], Vector2(0.02, -0.01), "40")
	var name1 := _name_of(editor, d1)
	await _redraw(ws)
	var box: LineEdit = editor._edit
	_place(editor, [lines[1]], Vector2(15, 30))
	await _redraw(ws)
	var at: Vector2 = _hit_entry(editor, d1).get("text_center", Vector2.ZERO)
	_expect(box.visible and box.get_selected_text() == box.text, "The box opens all selected.")
	_press_release(editor, at)
	_expect(box.visible and box.text == name1 and editor.tool_picks.size() == 1, "A click on %s's text while typing puts its name over the selection (%s)." % [name1, box.text])
	box.text = box.text + " * 2"
	box.caret_column = box.text.length()
	editor._on_edit_submitted(box.text)
	await process_frame
	var twice := _dimension_on(editor, [lines[1]])
	var s: SKETCH = editor.sketch()
	_expect(twice > 0 and s.dimension_expression(twice) == name1 + " * 2" and absf(_length(s, lines[1]) - 0.08) < 1e-9,
		"The expression is '%s * 2' and the line 80 mm (%s, %f)." % [name1, s.dimension_expression(twice) if twice > 0 else "", _length(s, lines[1])])
	ws.change("Test: d1", func() -> void: editor.sketch().feature.set_expression(editor.sketch().constraint(d1).key, "30"))
	await process_frame
	_expect(absf(_length(editor.sketch(), lines[1]) - 0.06) < 1e-9, "It follows %s (%f)." % [name1, _length(editor.sketch(), lines[1])])
	editor.cancel_tool()
	_place(editor, [lines[2]], Vector2(12, 50))
	box.text = name1 + " +"
	box.deselect()
	box.caret_column = box.text.length()
	editor._insert_parameter(_name_of(editor, twice))
	_expect(box.text == name1 + " + " + _name_of(editor, twice) and box.caret_column == box.text.length(), "'%s +' and a click gives '%s' (%s)." % [name1, name1 + " + " + _name_of(editor, twice), box.text])
	editor.cancel_tool()


## The hover tip's wording, the tip drawn by the cursor, and the name pill under the box.
func _check_tooltip_and_pill(ws: Control) -> void:
	var editor: RefCounted = await _fresh(ws, Vector2(40, 15))
	var lines: Array = await _lines(ws, [[Vector2(0, 0), Vector2(40, 0)], [Vector2(0, 20), Vector2(40, 20)]])
	var circle: int = await _circle(ws, 70, 10, 10)
	var spare: int = await _circle(ws, 100, 10, 5)
	var d1: int = await _dimension(ws, editor, [lines[0]], Vector2(0.02, -0.01), "40")
	var name1 := _name_of(editor, d1)
	var radius: int = await _add(ws, "radius", [circle], name1 + " / 2", Vector2(0, 8))
	var driven: int = await _add(ws, "length", [lines[1]], "", Vector2(0, 8))
	var broken: int = await _add(ws, "radius", [spare], "no_such_parameter * 2", Vector2(0, 8))
	await _redraw(ws)
	var s: SKETCH = editor.sketch()
	_expect(editor._dimension_tooltip(s.constraint(d1)) == name1 + " = 40 mm", "A plain value's tip (%s)." % editor._dimension_tooltip(s.constraint(d1)))
	var rname := _name_of(editor, radius)
	_expect(editor._dimension_tooltip(s.constraint(radius)) == "%s = %s / 2  (20 mm)" % [rname, name1], "An expression's tip (%s)." % editor._dimension_tooltip(s.constraint(radius)))
	_expect(editor._dimension_tooltip(s.constraint(driven)) == "Driven: 40 mm", "A driven dimension's tip (%s)." % editor._dimension_tooltip(s.constraint(driven)))
	var tip: String = editor._dimension_tooltip(s.constraint(broken))
	_expect(tip.begins_with(_name_of(editor, broken) + ": ") and tip.contains("Unknown name"), "A broken parameter's tip says why (%s)." % tip)
	editor.hover = {"kind": "constraint", "id": d1}
	editor.mouse_screen = Vector2(300, 300)
	await _redraw(ws)
	_expect(editor._tip_text == name1 + " = 40 mm", "The hovered dimension's tip is drawn (%s)." % editor._tip_text)
	editor.hover = {}
	# The name pill: the next dN for a new dimension, a typed name, a dimension's own name.
	_place(editor, [lines[1]], Vector2(20, 30))
	await _redraw(ws)
	_expect(editor._edit.visible and editor._pill_text == "d%d" % (int(ws.doc.counters.get("d", 0)) + 1), "A new dimension's pill names its parameter to be (%s)." % editor._pill_text)
	editor._edit.text = "wide = 40"
	editor._edit.text_changed.emit(editor._edit.text)
	await _redraw(ws)
	_expect(editor._pill_text == "wide", "A typed name shows in the pill (%s)." % editor._pill_text)
	editor.cancel_tool()
	await _redraw(ws)
	editor.open_dimension_edit(d1)
	await _redraw(ws)
	_expect(editor._pill_text == name1 and editor._tip_text == "", "An edited dimension's pill is its name (%s)." % editor._pill_text)
	editor._end_edit()


## Dragging a dimension's text moves it by the dragged plane distance in one step; a 2 px move only
## selects it.
func _check_drag_text(ws: Control) -> void:
	var editor: RefCounted = await _fresh(ws, Vector2(20, 0))
	var lines: Array = await _lines(ws, [[Vector2(0, 0), Vector2(40, 0)]])
	var d1: int = await _dimension(ws, editor, [lines[0]], Vector2(0.02, -0.01), "40")
	await _redraw(ws)
	var start: Vector2 = _hit_entry(editor, d1).get("text_center", Vector2.ZERO)
	var offset0: Vector2 = editor.sketch().constraint(d1).offset
	var step: Dictionary = ws.last_step
	_button(editor, start, true)
	_move(editor, start + Vector2(2, 0))
	_button(editor, start + Vector2(2, 0), false)
	await process_frame
	_expect(editor.sketch().constraint(d1).offset == offset0 and is_same(ws.last_step, step) and editor.selection.size() == 1 and int(editor.selection[0].id) == d1,
		"A 2 px move only selects the dimension.")
	_button(editor, start, true)
	var raw0: Vector2 = editor.mouse_plane_raw
	_move(editor, start + Vector2(20, 10))
	_move(editor, start + Vector2(30, 40))
	var raw1: Vector2 = editor.mouse_plane_raw
	_button(editor, start + Vector2(30, 40), false)
	await process_frame
	var moved: Vector2 = (editor.sketch().constraint(d1).offset as Vector2) - offset0
	# Offsets are single-precision Vector2s.
	_expect(moved.distance_to(raw1 - raw0) < 1e-7 and moved.length() > 1e-4 and ws.last_step.get("name", "") == "Sketch: Move Dimension",
		"Dragging the text moves it by the dragged distance in one step (%s vs %s, %s)." % [moved, raw1 - raw0, ws.last_step.get("name", "")])


## Right-click while placing: orientation, radius/diameter, driven; shown in the marking menu.
func _check_placing_options(ws: Control) -> void:
	var editor: RefCounted = await _fresh(ws, Vector2(15, 20))
	var lines: Array = await _lines(ws, [[Vector2(0, 0), Vector2(30, 40)]])
	editor.start_tool("dimension")
	editor.tool_click(Vector2.ZERO, {}, {"kind": "entity", "id": lines[0]})
	var entries: Array = editor.context_entries()
	var labels := _labels(entries)
	_expect(["Automatic", "Horizontal", "Vertical", "Aligned", "Driven"].all(func(label: String) -> bool: return labels.has(label)), "A slanted line's placing choices (%s)." % [labels])
	(_entry(entries, "Vertical").get("action", Callable()) as Callable).call()
	_expect(editor.dimension_spec([lines[0]], Vector2(15, 50) * MM, editor._dim_overrides).get("type", "") == "distance_y", "Vertical holds wherever the text goes.")
	ws._open_marking_menu(Vector2(100, 100))
	var shown: PackedStringArray = ws.marking_menu.labels()
	var ticked := shown.has("✓ Vertical") or shown.has("• Vertical")
	var all_shown := ["Automatic", "Horizontal", "Aligned", "Driven"].all(func(label: String) -> bool: return shown.has("   " + label))
	_expect(ticked and all_shown, "The marking menu lists them, Vertical ticked (%s)." % [shown])
	ws.marking_menu.close()
	editor.cancel_tool()
	var circle: int = await _circle(ws, 60, 10, 10)
	editor.start_tool("dimension")
	editor.tool_click(Vector2.ZERO, {}, {"kind": "entity", "id": circle})
	entries = editor.context_entries()
	_expect(_labels(entries).has("Radius") and _labels(entries).has("Diameter") and bool(_entry(entries, "Diameter").get("checked", false)), "A circle offers radius or diameter (%s)." % [_labels(entries)])
	(_entry(entries, "Radius").get("action", Callable()) as Callable).call()
	var spec: Dictionary = editor.dimension_spec([circle], Vector2(0.08, 0.02), editor._dim_overrides)
	_expect(spec.get("type", "") == "radius" and absf(float(spec.get("value", 0.0)) - 0.01) < 1e-9, "Radius chosen gives the radius (%s)." % spec)
	editor.cancel_tool()


## Right-click on a placed dimension: driven and back (the name returns), radius/diameter, delete.
func _check_placed_options(ws: Control) -> void:
	var editor: RefCounted = await _fresh(ws, Vector2(40, 15))
	var lines: Array = await _lines(ws, [[Vector2(0, 0), Vector2(40, 0)]])
	var d1: int = await _dimension(ws, editor, [lines[0]], Vector2(0.02, -0.01), "40")
	var name1 := _name_of(editor, d1)
	await _redraw(ws)
	var at: Vector2 = _hit_entry(editor, d1).get("text_center", Vector2.ZERO)
	var entries: Array = editor.context_entries(at)
	_expect(["Edit Value", "Make Driven", "Delete Dimension"].all(func(label: String) -> bool: return _labels(entries).has(label)), "A placed dimension's options (%s)." % [_labels(entries)])
	var steps := []
	(_entry(entries, "Make Driven").get("action", Callable()) as Callable).call()
	await process_frame
	steps.append(ws.last_step.get("name", ""))
	_expect(not editor.sketch().constraint(d1).get("driving", true), "Make Driven makes it driven.")
	await _redraw(ws)
	entries = editor.context_entries(_hit_entry(editor, d1).get("text_center", Vector2.ZERO))
	(_entry(entries, "Make Driving").get("action", Callable()) as Callable).call()
	_expect(editor._edit.visible and editor._edit.text == "40 mm", "Make Driving opens the box on what it measures (%s)." % editor._edit.text)
	editor._on_edit_submitted("40")
	await process_frame
	steps.append(ws.last_step.get("name", ""))
	_expect(editor.sketch().constraint(d1).get("driving", false) and _name_of(editor, d1) == name1 and steps == ["Sketch: Make Driven", "Sketch: Edit Dimension"],
		"Made driving again it gets %s back, in two steps (%s, %s)." % [name1, _name_of(editor, d1), steps])
	# Radius <-> diameter: a plain value doubles in its own unit, an expression gets "* 2".
	var cases := [["10", "20"], ["10 mm", "20 mm"], [name1 + " / 4", "(%s / 4) * 2" % name1]]
	for i in cases.size():
		var circle: int = await _circle(ws, 70 + 30 * i, 10, 10)
		var radius: int = await _add(ws, "radius", [circle], cases[i][0], Vector2(0, 6))
		await _redraw(ws)
		entries = editor.context_entries(_hit_entry(editor, radius).get("text_center", Vector2.ZERO))
		(_entry(entries, "Show as Diameter").get("action", Callable()) as Callable).call()
		await process_frame
		var s: SKETCH = editor.sketch()
		_expect(s.constraint(radius).type == "diameter" and s.dimension_expression(radius) == cases[i][1] and absf(float(s.entity(circle).r) - 0.01) < 1e-9
			and ws.last_step.get("name", "") == "Sketch: Dimension Type", "Show as Diameter: '%s' -> '%s', the circle unchanged (%s)." % [cases[i][0], cases[i][1], s.dimension_expression(radius)])
	# The ring's Delete deletes the selected sketch dimension.
	editor.selection.clear()
	editor.selection.append({"kind": "constraint", "id": d1})
	ws._open_marking_menu(Vector2(300, 300))
	var delete: Button = null
	for button in ws.marking_menu.find_children("*", "Button", true, false):
		if (button as Button).text == "Delete":
			delete = button
	_expect(delete != null and not delete.disabled, "The ring's Delete is on with a sketch dimension selected.")
	if delete != null:
		delete.pressed.emit()
	await process_frame
	_expect(editor.sketch().constraint(d1).is_empty(), "The ring's Delete removes the sketch dimension.")


## A deleted dimension's users show the measured value in the error state and are named.
func _check_broken_users(ws: Control) -> void:
	for text in ["40", "40 mm", " 2.5in", "1e-3 m"]:
		_expect(DIM.is_literal(text), "'%s' is a plain value." % text)
	for text in ["d1", "40 + 1", "(40)", "-4", "2*3"]:
		_expect(not DIM.is_literal(text), "'%s' is not a plain value." % text)
	var editor: RefCounted = await _fresh(ws, Vector2(20, 10))
	var lines: Array = await _lines(ws, [[Vector2(0, 0), Vector2(40, 0)], [Vector2(0, 20), Vector2(30, 20)]])
	var d1: int = await _dimension(ws, editor, [lines[0]], Vector2(0.02, -0.01), "40")
	var d2: int = await _dimension(ws, editor, [lines[1]], Vector2(0.015, 0.03), _name_of(editor, d1) + " / 2")
	var name2 := _name_of(editor, d2)
	editor.selection.clear()
	editor.selection.append({"kind": "constraint", "id": d1})
	editor.delete_selection()
	await _redraw(ws)
	var log: Dictionary = editor._dim_draw_log.get(d2, {})
	var marker: String = editor._expression_marker(ws.viewport._overlay)
	_expect(log.get("state", "") == "error" and log.get("text", "") == marker + "20.00", "Its user shows the measured 20.00 in error (%s)." % log)
	_expect(str(ws.last_message).contains(name2) and str(ws.last_message).contains("show an error"), "The flash names the user (%s)." % ws.last_message)


## Fully Define in a mm document: no freedom left, "N mm" expressions, no 0 dimensions, text apart.
func _check_fully_define(ws: Control) -> void:
	var editor: RefCounted = await _fresh(ws, Vector2(50, 15))
	ws.viewport.set_view_state({"target": editor.sketch().to_world(Vector2(0.05, 0.0)), "distance": 0.3})
	editor.start_tool("rect_2pt")
	editor.tool_click(Vector2(0.01, 0.01), {}, {})
	editor.tool_click(Vector2(0.05, 0.04), {}, {})
	editor.start_tool("circle_center")
	editor.tool_click(Vector2(0.07, 0.02), {}, {})
	editor.tool_click(Vector2(0.078, 0.02), {}, {})
	editor.cancel_tool()
	await _lines(ws, [[Vector2(90, 0), Vector2(110, 30)]])
	await _redraw(ws)
	var before: Array = _dimension_ids(editor)
	editor.fully_define()
	await _redraw(ws)
	var s: SKETCH = editor.sketch()
	var added: Array = _dimension_ids(editor).filter(func(id: int) -> bool: return not before.has(id))
	var pattern := RegEx.create_from_string("^\\d+(\\.\\d{1,6})? mm$")
	var clean := true
	var no_zero := true
	for id: int in added:
		clean = clean and pattern.search(s.dimension_expression(id)) != null
		no_zero = no_zero and float(ws.result.values.get(_name_of(editor, id), {}).get("value", 0.0)) > 1e-9
	_expect(int(editor.state.solve.dof) == 0 and added.size() >= 8 and ws.last_step.get("name", "") == "Sketch: Fully Define", "Fully Define leaves nothing free in one step (%d added, dof %d)." % [added.size(), int(editor.state.solve.dof)])
	_expect(clean and no_zero, "Its expressions are plain mm values, none 0 (%s)." % [added.map(func(id: int) -> String: return s.dimension_expression(id))])
	var centers := added.map(func(id: int) -> Vector2: return _hit_entry(editor, id).get("text_center", Vector2.INF))
	var apart := true
	for i in centers.size():
		for j in range(i + 1, centers.size()):
			apart = apart and (centers[i] as Vector2).distance_to(centers[j]) >= 12.0
	_expect(apart, "Their text is at least 12 px apart (%s)." % [centers])
	_expect(s.constraints().any(func(c: Dictionary) -> bool: return c.type == "horizontal" and (c.refs as Array).has(s.origin_id())), "A point level with the origin is lined up with it, not dimensioned 0.")


## The gap between items with the curves of round ones flagged (double precision).
func _gap(s: SKETCH, refs: Array, flags: Array) -> float:
	var xy := func(id: int) -> PackedFloat64Array:
		var e: Dictionary = s.entity(id)
		return s.point_xy(int(e.c) if e.type in ["circle", "arc"] else id)
	var r := func(i: int) -> float: return float(s.entity(int(refs[i])).r) if flags[i] else 0.0
	if s.entity(int(refs[1])).type == "line":
		var e: Dictionary = s.entity(int(refs[1]))
		var a := s.point_xy(int(e.p1))
		var b := s.point_xy(int(e.p2))
		var p: PackedFloat64Array = xy.call(int(refs[0]))
		var h := absf((b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])) / sqrt(pow(b[0] - a[0], 2) + pow(b[1] - a[1], 2))
		return h - r.call(0)
	var p0: PackedFloat64Array = xy.call(int(refs[0]))
	var p1: PackedFloat64Array = xy.call(int(refs[1]))
	var d := sqrt(pow(p1[0] - p0[0], 2) + pow(p1[1] - p0[1], 2))
	var r0: float = r.call(0)
	var r1: float = r.call(1)
	return d - r0 - r1 if d >= r0 and d >= r1 else maxf(r0, r1) - minf(r0, r1) - d


## Measure to Edge: circle to line, circle to circle, point to circle (outside and inside), a
## circle inside another; each offers the gap and takes a new one.
func _check_edges(ws: Control) -> void:
	var cases := [
		["circle-line", [[0, 0, 10]], [[-20, 30, 20, 30]], [], 20.0, 25.0],
		["circle-circle", [[0, 0, 10], [40, 0, 5]], [], [], 25.0, 30.0],
		["point-circle outside", [[0, 0, 10]], [], [[25, 0]], 15.0, 12.0],
		["point-circle inside", [[0, 0, 10]], [], [[3, 0]], 7.0, 5.0],
		["circle in circle", [[0, 0, 20], [5, 0, 5]], [], [], 10.0, 8.0],
	]
	for case: Array in cases:
		var editor: RefCounted = await _fresh(ws, Vector2(0, 10))
		var ids := []
		for c: Array in case[1]:
			ids.append(await _circle(ws, c[0], c[1], c[2]))
		for l: Array in case[2]:
			ids.append_array(await _lines(ws, [[Vector2(l[0], l[1]), Vector2(l[2], l[3])]]))
		for p: Array in case[3]:
			var made := [-1]
			ws.change("Test: Point", func() -> void: made[0] = _pt(editor.sketch(), p[0], p[1]))
			await process_frame
			ids.push_front(made[0])
		editor.start_tool("dimension")
		for id in ids:
			editor.tool_click(Vector2.ZERO, {}, {"kind": "entity", "id": int(id)})
		var entries: Array = editor.context_entries()
		_expect(_labels(entries).has("Measure to Centre") and _labels(entries).has("Measure to Edge"), "%s: centre or edge is offered (%s)." % [case[0], _labels(entries)])
		(_entry(entries, "Measure to Edge").get("action", Callable()) as Callable).call()
		var place := Vector2(0.012, 0.022)
		var spec: Dictionary = editor.dimension_spec(_pick_ids(editor), place, editor._dim_overrides)
		_expect(spec.get("type", "") == "distance" and (spec.get("edge", []) as Array).has(true) and absf(float(spec.get("value", 0.0)) - float(case[4]) * MM) < 1e-12,
			"%s: the edge gap is %.0f mm (%s)." % [case[0], case[4], spec])
		editor.tool_click(place, {}, {})
		_expect(editor._edit.visible and editor._edit.text == "%d mm" % int(case[4]), "%s: the box offers %d mm (%s)." % [case[0], int(case[4]), editor._edit.text])
		editor._on_edit_submitted(str(case[5]))
		await process_frame
		var s: SKETCH = editor.sketch()
		var gap := _gap(s, spec.get("refs", []), spec.get("edge", [false, false]))
		_expect(not editor._edit.visible and absf(gap - float(case[5]) * MM) < 1e-7 and bool(editor.state.solve.ok), "%s: %.0f mm takes (%.9f)." % [case[0], case[5], gap / MM])
		editor.cancel_tool()


## Three points give the angle at the middle one; an arc's sweep by right-click.
func _check_three_point_and_sweep(ws: Control) -> void:
	var editor: RefCounted = await _fresh(ws, Vector2(25, 5))
	var ids := {}
	ws.change("Test: Points", func() -> void:
		var s: SKETCH = editor.sketch()
		ids.a = _pt(s, 10, 0)
		ids.v = _pt(s, 0, 0)
		ids.b = _pt(s, 0, 10)
		ids.c = _pt(s, 50, 0)
		ids.arc = s.add_arc(ids.c, _pt(s, 60, 0), _pt(s, 50, 10)))
	await process_frame
	editor.start_tool("dimension")
	for key in ["a", "v", "b"]:
		editor.tool_click(Vector2.ZERO, {}, {"kind": "entity", "id": int(ids[key])})
	_expect(editor.tool_picks.size() == 3, "Two points take a third (%d picks)." % editor.tool_picks.size())
	var spec: Dictionary = editor.dimension_spec([ids.a, ids.v, ids.b], Vector2(0.004, 0.004))
	_expect(spec.get("type", "") == "angle" and int((spec.get("refs", [0]) as Array)[0]) == ids.v and absf(rad_to_deg(float(spec.get("value", 0.0))) - 90.0) < 1e-9,
		"The angle at the middle point is 90° (%s)." % spec)
	editor.tool_click(Vector2(0.004, 0.004), {}, {})
	_expect(editor._edit.visible and editor._edit.text == "90 deg", "The box offers 90 deg (%s)." % editor._edit.text)
	editor._on_edit_submitted("200")
	_expect(editor._edit.visible and str(ws.last_message).contains("less than 180"), "200° is refused between two rays (%s)." % ws.last_message)
	editor._on_edit_submitted("60")
	await process_frame
	var s: SKETCH = editor.sketch()
	var opening := _opening(_between(s, ids.v, ids.a), _between(s, ids.v, ids.b))
	_expect(absf(opening - 60.0) < 1e-7 and not editor._edit.visible, "60 opens the three points to 60° (%.9f)." % opening)
	editor.cancel_tool()
	# An arc's sweep.
	editor.start_tool("dimension")
	editor.tool_click(Vector2.ZERO, {}, {"kind": "entity", "id": int(ids.arc)})
	var entries: Array = editor.context_entries()
	_expect(_labels(entries).has("Sweep Angle"), "An arc offers its sweep angle (%s)." % [_labels(entries)])
	(_entry(entries, "Sweep Angle").get("action", Callable()) as Callable).call()
	spec = editor.dimension_spec([ids.arc], Vector2(0.06, 0.01), editor._dim_overrides)
	# The solver leaves an arc's ends where its single-precision angles put them.
	_expect(spec.get("type", "") == "angle" and absf(rad_to_deg(float(spec.get("value", 0.0))) - 90.0) < 1e-5, "The arc's sweep is 90° (%s)." % spec)
	editor.tool_click(Vector2(0.06, 0.01), {}, {})
	editor._on_edit_submitted("200")
	await process_frame
	s = editor.sketch()
	var arc: Dictionary = s.entity(int(ids.arc))
	var to_s := _between(s, int(arc.c), int(arc.s))
	var to_e := _between(s, int(arc.c), int(arc.e))
	var sweep := rad_to_deg(fposmod(atan2(to_e[1], to_e[0]) - atan2(to_s[1], to_s[0]), TAU))
	_expect(absf(sweep - 200.0) < 1e-6 and ws.last_step.get("name", "") == "Sketch: Dimension", "200 sweeps the arc to 200° (%.9f)." % sweep)
	await _redraw(ws)
	var swept := _dimension_on(editor, [int(ids.arc)])
	_expect(editor._dim_draw_log.get(swept, {}).get("text", "") == "200.0°", "The sweep is drawn 200.0° (%s)." % editor._dim_draw_log.get(swept, {}))
	editor.cancel_tool()


## A distance from a centerline is a diameter across it (Ø, twice the distance), and can be turned off.
func _check_linear_diameter(ws: Control) -> void:
	var editor: RefCounted = await _fresh(ws, Vector2(5, 0))
	var ids := {}
	ws.change("Test: Centerline", func() -> void:
		var s: SKETCH = editor.sketch()
		var a := _pt(s, 0, -20)
		var b := _pt(s, 0, 20)
		s.entity(a)["fixed"] = true
		s.entity(b)["fixed"] = true
		ids.axis = s.add_line(a, b, true, true)
		ids.p = _pt(s, 15, 5))
	await process_frame
	editor.start_tool("dimension")
	editor.tool_click(Vector2.ZERO, {}, {"kind": "entity", "id": int(ids.p)})
	editor.tool_click(Vector2.ZERO, {}, {"kind": "entity", "id": int(ids.axis)})
	var entries: Array = editor.context_entries()
	_expect(bool(_entry(entries, "Diameter").get("checked", false)), "Diameter across the centerline is on (%s)." % [_labels(entries)])
	var spec: Dictionary = editor.dimension_spec(_pick_ids(editor), Vector2(0.0075, 0.012), editor._dim_overrides)
	_expect(spec.get("linear_diameter", false) and absf(float(spec.get("value", 0.0)) - 0.03) < 1e-12, "15 mm from the centerline offers Ø30 (%s)." % spec)
	editor.tool_click(Vector2(0.0075, 0.012), {}, {})
	_expect(editor._edit.text == "30 mm", "The box offers 30 mm (%s)." % editor._edit.text)
	editor._on_edit_submitted("40")
	await _redraw(ws)
	var s: SKETCH = editor.sketch()
	var dim := _dimension_on(editor, [int(ids.p), int(ids.axis)])
	_expect(absf(float(s.entity(int(ids.p)).x) - 0.02) < 1e-9 and editor._dim_draw_log.get(dim, {}).get("text", "") == "Ø40.00", "Ø40 puts the point 20 mm away (%f, %s)." % [float(s.entity(int(ids.p)).x), editor._dim_draw_log.get(dim, {})])
	editor.tool_click(Vector2.ZERO, {}, {"kind": "entity", "id": int(ids.p)})
	editor.tool_click(Vector2.ZERO, {}, {"kind": "entity", "id": int(ids.axis)})
	(_entry(editor.context_entries(), "Diameter").get("action", Callable()) as Callable).call()
	spec = editor.dimension_spec(_pick_ids(editor), Vector2(0.01, 0.012), editor._dim_overrides)
	_expect(not spec.get("linear_diameter", false) and absf(float(spec.get("value", 0.0)) - 0.02) < 1e-12, "Turned off it is the plain 20 mm (%s)." % spec)
	editor.cancel_tool()


## "name = value" renames the parameter and every expression that uses it, in one step.
func _check_rename(ws: Control) -> void:
	var editor: RefCounted = await _fresh(ws, Vector2(20, 20))
	var lines: Array = await _lines(ws, [[Vector2(0, 0), Vector2(40, 0)], [Vector2(0, 20), Vector2(30, 20)], [Vector2(0, 40), Vector2(25, 40)]])
	var d1: int = await _dimension(ws, editor, [lines[0]], Vector2(0.02, -0.01), "40")
	var d2: int = await _dimension(ws, editor, [lines[1]], Vector2(0.015, 0.03), _name_of(editor, d1) + " / 2")
	await _redraw(ws)
	editor.open_dimension_edit(d1)
	editor._on_edit_submitted(_name_of(editor, d2) + " = 40")
	_expect(editor._edit.visible and str(ws.last_message).contains("can't be the parameter's name"), "A name another parameter has is refused (%s)." % ws.last_message)
	editor._on_edit_submitted("width = 40 mm")
	await process_frame
	var s: SKETCH = editor.sketch()
	_expect(_name_of(editor, d1) == "width" and s.dimension_expression(d1) == "40 mm" and s.dimension_expression(d2) == "width / 2"
		and absf(_length(s, lines[1]) - 0.02) < 1e-9 and ws.last_step.get("name", "") == "Sketch: Edit Dimension",
		"'width = 40 mm' renames it and its user in one step (%s, %s)." % [_name_of(editor, d1), s.dimension_expression(d2)])
	_place(editor, [lines[2]], Vector2(12, 50))
	editor._on_edit_submitted("w3 = 25")
	await process_frame
	var d3 := _dimension_on(editor, [lines[2]])
	_expect(d3 > 0 and _name_of(editor, d3) == "w3" and absf(_length(editor.sketch(), lines[2]) - 0.025) < 1e-9, "A new dimension can be named as it is made (%s)." % _name_of(editor, d3) if d3 > 0 else "none")
	editor.cancel_tool()


## Parameter labels say what they size; favourites in the box; the measured geometry lights up.
func _check_small_items(ws: Control) -> void:
	var editor: RefCounted = await _fresh(ws, Vector2(20, 10))
	var lines: Array = await _lines(ws, [[Vector2(0, 0), Vector2(40, 0)], [Vector2(0, 20), Vector2(30, 20)]])
	var d1: int = await _dimension(ws, editor, [lines[0]], Vector2(0.02, -0.01), "40")
	var feature: Resource = editor.sketch().feature
	var label := ""
	for p in ws.doc.model_parameters():
		if p.name == _name_of(editor, d1):
			label = p.label
	_expect(label == feature.label + " Length", "The parameter's label says it is a length (%s)." % label)
	_place(editor, [lines[1]], Vector2(15, 30))
	_expect(not editor._fav_button.visible, "No favourites, no list button.")
	editor.cancel_tool()
	ws.change("Test: Favourite", func() -> void: ws.doc.user_parameters.append({"name": "gap", "unit": "mm", "expression": "5", "comment": "", "favorite": true}))
	await process_frame
	_place(editor, [lines[1]], Vector2(15, 30))
	_expect(editor._fav_button.visible and editor._favorite_names() == ["gap"], "A favourite shows the list button.")
	editor._on_favorite_chosen(0)
	_expect(editor._edit.text == "gap", "Choosing it puts its name in the box (%s)." % editor._edit.text)
	editor.cancel_tool()
	await _redraw(ws)
	editor.hover = {"kind": "constraint", "id": d1}
	await _redraw(ws)
	_expect(editor._measured_highlight.has(lines[0]) and not editor._measured_highlight.has(lines[1]), "Hovering a dimension lights up what it measures.")
	editor.hover = {}
	# A rubber-band segment on a scratch copy (what heads-up fields while drawing would show) lays
	# out as a dimension like any other.
	var scratch := SKETCH.new(editor.sketch().feature.copy(), null)
	var band := scratch.add_line(scratch.add_point(Vector2(0, 60) * MM), scratch.add_point(Vector2(30, 70) * MM))
	var layout: Dictionary = editor._layout_for(scratch, {"id": -1, "type": "length", "refs": [band], "kind": "length", "offset": Vector2(0, 8) * MM}, "31.62")
	_expect(not layout.is_empty() and (layout.get("arrows", []) as Array).size() == 2, "A rubber-band segment lays out as a dimension.")


# --- Review fixes --------------------------------------------------------------------------------

## The unpadded box of a layout's text on screen (its four corners).
func _text_box(layout: Dictionary) -> PackedVector2Array:
	var text: Dictionary = layout.text
	var x0 := DIM.text_x(str(text.align), TEXT_W)
	var y0 := float(text.baseline) - ASCENT
	var corners := PackedVector2Array()
	for corner in [Vector2(x0, y0), Vector2(x0 + TEXT_W, y0), Vector2(x0 + TEXT_W, y0 + ASCENT + DESCENT), Vector2(x0, y0 + ASCENT + DESCENT)]:
		corners.append((text.anchor as Vector2) + (corner as Vector2).rotated(float(text.angle)))
	return corners


## True when the segment a-b runs through the polygon.
func _crosses(poly: PackedVector2Array, a: Vector2, b: Vector2) -> bool:
	if Geometry2D.is_point_in_polygon(a, poly) or Geometry2D.is_point_in_polygon(b, poly):
		return true
	for i in poly.size():
		if Geometry2D.segment_intersects_segment(a, b, poly[i], poly[(i + 1) % poly.size()]) != null:
			return true
	return false


## Layouts: a small angle's value goes beyond its arrow, never across a ray, and a wide one's stays
## between its rays; a three-point angle with no lines gets rays drawn from its vertex; extension
## lines keep clear of point markers; text over a short dimension keeps clear of the extension
## lines' ends (and hangs below when they come down through it).
func _check_review_layouts() -> void:
	var s := _sketch()
	var v := s.add_point(Vector2.ZERO)
	var ends := [Vector2(30, 0), Vector2(30, 30.0 * tan(deg_to_rad(6.0)))]
	var l0 := s.add_line(v, s.add_point(ends[0] * MM))
	var l1 := s.add_line(v, s.add_point(ends[1] * MM))
	for t: Vector2 in [Vector2(10, 0.4), Vector2(10, 0.7), Vector2(25, -3)]:
		var small := _layout(s, {"type": "angle", "kind": "angle", "refs": [l0, l1], "rays": [1, 1]}, t)
		var box := _text_box(small)
		_expect(not small.is_empty() and not _crosses(box, _screen(Vector2.ZERO), _screen(ends[0] * MM)) and not _crosses(box, _screen(Vector2.ZERO), _screen(ends[1] * MM)),
			"A 6° angle's value (T %s) runs across neither ray (%s)." % [t, box])
	var l2 := s.add_line(v, s.add_point(Vector2(30, 30) * MM))
	for t: Vector2 in [Vector2(20, 0.5), Vector2(14, 13.5), Vector2(20, 8)]:
		var wide := _layout(s, {"type": "angle", "kind": "angle", "refs": [l0, l2], "rays": [1, 1]}, t)
		var box := _text_box(wide)
		_expect(not _crosses(box, _screen(Vector2.ZERO), _screen(ends[0] * MM)) and not _crosses(box, _screen(Vector2.ZERO), _screen(Vector2(30, 30) * MM)),
			"A 45° angle's value (T %s) stays between its rays (%s)." % [t, box])

	# A three-point angle over points no line joins: its rays drawn from the vertex past the arc.
	var p := _sketch()
	var vertex := p.add_point(Vector2(110, 70) * MM)
	var a := p.add_point(Vector2(135, 70) * MM)
	var b := p.add_point(Vector2(125, 90) * MM)
	var three := {"type": "angle", "kind": "angle", "refs": [vertex, a, b], "rays": [1, 1]}
	var at_vertex := _screen(Vector2(110, 70) * MM)
	var rho := Vector2(15, 6).length() * 4.0
	var from_vertex := func(layout: Dictionary) -> Array:
		return (layout.ext_lines as Array).filter(func(seg: Array) -> bool: return absf((seg[0] as Vector2).distance_to(at_vertex) - 3.0) < 0.01)
	var bare: Array = from_vertex.call(_layout(p, three, Vector2(125, 76)))
	_expect(bare.size() == 2 and bare.all(func(seg: Array) -> bool: return absf((seg[1] as Vector2).distance_to(at_vertex) - (rho + 5.0)) < 0.05),
		"A three-point angle with no lines draws both rays from its vertex to past the arc (%s)." % [bare])
	p.add_line(vertex, a)
	var joined: Array = from_vertex.call(_layout(p, three, Vector2(125, 76)))
	_expect(joined.size() == 1, "A ray a line lies along needs none (%d)." % joined.size())

	# Extension lines start clear of a point's marker.
	var q := _sketch()
	var line := _line(q, Vector2(0, 0), Vector2(30, 40))
	var e: Dictionary = q.entity(line)
	var marked := m.duplicate()
	marked["mark"] = 3.0
	var h := DIM.screen_layout(DIM.plane_layout(q, {"type": "distance_x", "refs": [int(e.p1), int(e.p2)]}, Vector2(15, 50) * MM), _screen, marked, TEXT_W, ASCENT, DESCENT)
	_expect(not h.is_empty() and absf((h.ext_lines[0][0] as Vector2).distance_to(Vector2(500, 500)) - 6.0) < 0.01,
		"With points shown, an extension line starts 3 px past the point's marker (%s)." % [h.get("ext_lines", [])])

	# Short dimensions: text clear of the extension lines' ends, above or hung below.
	var short_line := _line(q, Vector2(0, 0), Vector2(3, 0))
	var above := _layout(q, {"type": "length", "refs": [short_line]}, Vector2(1.5, 8))
	_expect(float(above.text.baseline) <= -(float(m.ext_over) + float(m.text_clear)) + 1e-6,
		"A short dimension's text sits %d px clear of the extension lines' ends (%s)." % [int(m.text_clear), above.text])
	var below := _layout(q, {"type": "length", "refs": [short_line]}, Vector2(1.5, -8))
	_expect(float(below.text.baseline) - float(m.font) * DIM.CAP_HEIGHT >= float(m.ext_over) + float(m.text_clear) - 1e-6,
		"Placed under the line, a short dimension's text hangs below the dimension line, clear of the ends (%s)." % [below.text])


## The review's fixes in the editor: Tab keeps the keyboard in the box; the box stays on its
## dimension as the view zooms and pans and as it grows; no undo step when nothing changes; Edit
## Value with dimensions hidden; layouts are reused while nothing changes; an invalid value is red
## selected too; the themed driven question; profiles don't fight faces for depth; arrowheads keep
## their size with their outline; prefills to 6 decimals, short within the geometry's noise;
## signed horizontal and vertical distances from older documents edit by their size; Fully Define
## with nothing free records nothing; a legacy angle labelled 150° in its 30° sector.
func _check_review_fixes(ws: Control) -> void:
	var editor: RefCounted = await _fresh(ws, Vector2(20, 10))
	var lines: Array = await _lines(ws, [[Vector2(0, 0), Vector2(40, 0)], [Vector2(0, 20), Vector2(30, 20)], [Vector2(0, 40), Vector2(25, 40)]])
	var box: LineEdit = editor._edit
	var p: Dictionary = editor.theme_colors
	# Tab keeps the keyboard in the box, and Enter after it takes the value.
	_place(editor, [lines[0]], Vector2(20, -10))
	box.grab_focus()
	await _frames(1)
	for pressed in [true, false]:
		var tab := _key(KEY_TAB)
		tab.pressed = pressed
		root.push_input(tab)
	await _frames(2)
	_expect(box.visible and box.has_focus(), "Tab keeps the keyboard in the value box (%s)." % root.gui_get_focus_owner())
	box.text = "35"
	for pressed in [true, false]:
		var enter := _key(KEY_ENTER)
		enter.pressed = pressed
		root.push_input(enter)
	await _frames(2)
	_expect(not box.visible and absf(_length(editor.sketch(), lines[0]) - 0.035) < 1e-9 and ws.last_step.get("name", "") == "Sketch: Dimension",
		"Enter after Tab takes the value (%s)." % ws.last_step.get("name", ""))
	var d1 := _dimension_on(editor, [lines[0]])

	# The box stays on its dimension: a zoom, a long value, a pan of an existing one.
	_place(editor, [lines[1]], Vector2(15, 30))
	await _redraw(ws)
	var first: Vector2 = editor._pending_center
	ws.viewport.zoom_at(2, first + Vector2(80, 50))
	await _redraw(ws)
	var moved: Vector2 = editor._pending_center
	_expect(box.visible and moved.distance_to(first) > 5.0 and (box.position + box.size * 0.5).distance_to(moved) <= 2.0,
		"After a zoom the box is still on the text (%s vs %s, was %s)." % [box.position + box.size * 0.5, moved, first])
	box.text = "50 mm + 12.5 mm * 2 - 3 mm"
	box.text_changed.emit(box.text)
	await _redraw(ws)
	_expect(box.size.x > 120.0 and (box.position + box.size * 0.5).distance_to(editor._pending_center) <= 2.0,
		"A long value keeps the box centred on the text (%s vs %s)." % [box.position + box.size * 0.5, editor._pending_center])
	editor._end_edit()
	editor.cancel_tool()
	await _redraw(ws)
	editor.open_dimension_edit(d1)
	var target: Vector3 = ws.viewport.target
	ws.viewport.set_view_state({"target": target + editor.sketch().to_world(Vector2(0.004, 0.003)) - editor.sketch().to_world(Vector2.ZERO)})
	await _redraw(ws)
	var hit := _hit_entry(editor, d1)
	_expect(box.visible and not hit.is_empty() and (box.position + box.size * 0.5).distance_to(hit.get("text_center", Vector2.INF)) <= 2.0,
		"After a pan the box is still on the dimension it edits (%s vs %s)." % [box.position + box.size * 0.5, hit.get("text_center")])

	# Its own value again records nothing.
	ws.last_step = {}
	editor._on_edit_submitted(box.text)
	_expect(not box.visible and ws.last_step.is_empty(), "Enter on a dimension's own value records no step (%s)." % ws.last_step.get("name", ""))
	editor.open_dimension_edit(d1)
	ws.last_step = {}
	_press_release(editor, ws.viewport.project(editor.sketch().to_world(Vector2(0.03, 0.06))))
	_expect(not box.visible and ws.last_step.is_empty(), "A click away with its own value records no step (%s)." % ws.last_step.get("name", ""))

	# Edit Value with dimensions hidden opens the box.
	await _redraw(ws)
	editor.selection.clear()
	editor.selection.append({"kind": "constraint", "id": d1})
	editor.show.dimensions = false
	await _redraw(ws)
	var edit_entry := _entry(editor.context_entries(), "Edit Value")
	if not edit_entry.is_empty():
		edit_entry.action.call()
	_expect(editor._dim_hits.is_empty() and box.visible and editor._edit_constraint == d1, "Edit Value works with dimensions hidden (%s)." % [_labels(editor.context_entries())])
	editor._end_edit()
	editor.show.dimensions = true
	editor.selection.clear()

	# Layouts are reused while nothing changes; a hover only recolours; a zoom lays them out again.
	await _redraw(ws)
	await _redraw(ws)
	_expect(editor._layout_misses == 0, "An unchanged view and sketch lay out no dimension again (%d)." % editor._layout_misses)
	editor.hover = {"kind": "constraint", "id": d1}
	await _redraw(ws)
	_expect(editor._layout_misses == 0 and editor._dim_draw_log.get(d1, {}).get("state", "") == "hovered", "A hover only recolours (%d)." % editor._layout_misses)
	editor.hover = {}
	ws.viewport.zoom_at(1, Vector2(600, 400))
	await _redraw(ws)
	_expect(editor._layout_misses == _dimension_ids(editor).size(), "A zoom lays every dimension out again (%d)." % editor._layout_misses)

	# An invalid value shows red while it is all selected too.
	var broken: int = await _add(ws, "length", [lines[2]], "nosuch * 2", Vector2(0, 8))
	await _redraw(ws)
	editor.open_dimension_edit(broken)
	_expect(box.visible and box.get_selected_text() == box.text and box.get_theme_color("font_selected_color") == p.dim_box_invalid,
		"A broken value opens red, selected or not.")
	editor._end_edit()

	# The driven question takes the palette's colours, title bar and close button, with room round
	# its message.
	editor.driven_answer = ""
	editor.start_tool("dimension")
	editor._ask_driven(editor.dimension_spec([lines[1]], Vector2(15, 30) * MM))
	var dialog: ConfirmationDialog = editor._driven_dialog
	var theme: Theme = dialog.theme if dialog != null else null
	var colors := THEME.palette(ws.theme_name)
	_expect(theme != null and theme == THEME.dialog_theme(ws.theme_name, 1.0) and theme.get_color("title_color", "Window") == colors.ui_text
		and theme.get_icon("close", "Window") != null and (theme.get_stylebox("panel", "AcceptDialog") as StyleBoxFlat).bg_color == colors.chrome
		and theme.get_stylebox("panel", "AcceptDialog").content_margin_right >= 10.0, "The driven question is themed (%s)." % ws.theme_name)
	if dialog != null:
		dialog.hide()
		editor._on_driven_answer(false)
	editor.cancel_tool()
	_expect(editor._material_profile.use_z_clip_scale and editor._material_profile.z_clip_scale < 1.0, "Profiles are drawn a hair toward the camera.")
	# Arrowheads: with their 1 px outline, 9 px long and 3.6 px wide.
	var tri: PackedVector2Array = editor._arrow_points(Vector2.ZERO, Vector2.RIGHT, m)
	_expect(absf(absf(tri[1].y) + float(m.line) * 0.5 - float(m.arrow_half)) < 1e-6 and absf(absf(tri[1].x) + float(m.line) * 0.5 - float(m.arrow_len)) < 1e-6,
		"An arrowhead's triangle leaves room for its outline (%s)." % tri)

	# Prefills: 6 decimals, short when within what the geometry can be off by.
	editor = await _fresh(ws, Vector2(120, 0))
	var made: Array = await _lines(ws, [[Vector2(140, 20), Vector2(100, 0)], [Vector2(100, 0), Vector2(140, -20)], [Vector2(0, -30), [1234.5678, -30]]])
	var s: SKETCH = editor.sketch()
	var far := [s.point_xy(int(s.entity(made[0]).p1)), s.point_xy(int(s.entity(made[1]).p2))]
	_place(editor, [made[0], made[1]], Vector2(130, 0))
	_expect(box.text == "53.130102 deg", "The V's prefill has 6 decimals (%s)." % box.text)
	editor._on_edit_submitted(box.text)
	await _redraw(ws)
	s = editor.sketch()
	var now := [s.point_xy(int(s.entity(made[0]).p1)), s.point_xy(int(s.entity(made[1]).p2))]
	var shift := maxf(Vector2(now[0][0] - far[0][0], now[0][1] - far[0][1]).length(), Vector2(now[1][0] - far[1][0], now[1][1] - far[1][1]).length())
	_expect(shift < 1e-9, "Its prefill commits without moving the V (%s m)." % String.num_scientific(shift))
	_place(editor, [made[2]], Vector2(600, -50))
	_expect(box.text == "1234.5678 mm", "A 1234.5678 mm line offers 1234.5678 mm (%s)." % box.text)
	editor._on_edit_submitted(box.text)
	await process_frame
	_expect(absf(_length(editor.sketch(), made[2]) - 1.2345678) < 1e-12, "Its prefill commits without changing it (%.9f mm)." % (_length(editor.sketch(), made[2]) * 1000.0))
	editor.cancel_tool()
	# Points clicked in the view are single precision: a 30 mm line offers 30 mm, a 24 mm arc's
	# diameter 24 mm.
	editor.start_tool("line")
	editor.tool_click(Vector2(0.0, 0.05), {}, {})
	editor.tool_click(Vector2(0.03, 0.05), {}, {})
	editor.cancel_tool()
	editor.start_tool("arc_center")
	editor.tool_click(Vector2(0.1, 0.05), {}, {})
	editor.tool_click(Vector2(0.112, 0.05), {}, {})
	editor.tool_click(Vector2(0.1, 0.062), {}, {})
	editor.cancel_tool()
	await process_frame
	s = editor.sketch()
	var clicked := -1
	var arc := -1
	for each in s.entities():
		if each.type == "line" and absf(s.point(int(each.p1)).y - 0.05) < 1e-6:
			clicked = int(each.id)
		elif each.type == "arc":
			arc = int(each.id)
	_place(editor, [clicked], Vector2(15, 60))
	_expect(box.text == "30 mm", "A clicked 30 mm line offers 30 mm (%s, %.12f m)." % [box.text, _length(editor.sketch(), clicked) if clicked >= 0 else 0.0])
	editor._end_edit()
	editor.start_tool("dimension")
	editor.tool_click(Vector2.ZERO, {}, {"kind": "entity", "id": arc})
	editor._dim_overrides["round"] = "diameter"
	editor.tool_click(Vector2(0.125, 0.075), {}, {})
	_expect(box.text == "24 mm", "A clicked arc offers its diameter as 24 mm (%s, r %.12f)." % [box.text, float(editor.sketch().entity(arc).get("r", 0.0)) if arc >= 0 else 0.0])
	editor.cancel_tool()

	# An older document's horizontal and vertical distances kept negative: shown and edited by size.
	editor = await _fresh(ws, Vector2(-10, -5))
	var ids := {}
	ws.change("Test: Signed", func() -> void:
		var sk: SKETCH = editor.sketch()
		ids.origin = sk.origin_id()
		ids.p = _pt(sk, -20, -10)
		ids.dx = sk.add_constraint("distance_x", [ids.origin, ids.p], "-0.02 m")
		sk.constraint(ids.dx)["offset"] = Vector2(0.0, -0.01)
		ids.dy = sk.add_constraint("distance_y", [ids.origin, ids.p], "-0.01 m")
		sk.constraint(ids.dy)["offset"] = Vector2(-0.015, 0.0))
	await _redraw(ws)
	s = editor.sketch()
	_expect(absf(s.point_xy(ids.p)[0] + 0.02) < 1e-9 and absf(s.point_xy(ids.p)[1] + 0.01) < 1e-9, "Signed distances solve as before (%s)." % s.point_xy(ids.p))
	_expect(editor._dim_draw_log.get(ids.dx, {}).get("text", "") == "20.00" and editor._dim_draw_log.get(ids.dy, {}).get("text", "") == "10.00",
		"A signed plain number shows its size without the marker (%s, %s)." % [editor._dim_draw_log.get(ids.dx, {}).get("text", ""), editor._dim_draw_log.get(ids.dy, {}).get("text", "")])
	editor.open_dimension_edit(ids.dx)
	_expect(box.text == "20 mm", "A signed distance opens on its size (%s)." % box.text)
	editor._on_edit_submitted(box.text)
	await _redraw(ws)
	s = editor.sketch()
	_expect(not box.visible and absf(s.point_xy(ids.p)[0] + 0.02) < 1e-9 and (s.constraint(ids.dx).refs as Array) == [ids.p, ids.origin] and s.dimension_expression(ids.dx) == "20 mm",
		"Enter on its size keeps the point where it is (%s, %s)." % [s.point_xy(ids.p), s.constraint(ids.dx)])
	editor.open_dimension_edit(ids.dy)
	editor._on_edit_submitted("25")
	await _redraw(ws)
	s = editor.sketch()
	_expect(absf(s.point_xy(ids.p)[1] + 0.025) < 1e-9, "25 keeps the point below the origin (%s)." % s.point_xy(ids.p))
	# Fully Define on a sketch with nothing free adds nothing and records no step.
	ws.last_step = {}
	var added: int = editor.fully_define()
	_expect(added == 0 and ws.last_step.is_empty() and str(ws.last_message).contains("already"), "Fully Define on a fully defined sketch records nothing (%s)." % ws.last_message)

	# A legacy angle stored as 150° with its text in the 30° sector shows 150° and keeps it.
	editor = await _fresh(ws, Vector2(0, 10))
	ws.change("Test: Legacy 150", func() -> void:
		var sk: SKETCH = editor.sketch()
		var vx := _pt(sk, 0, 0)
		var right := _pt(sk, 40, 0)
		sk.entity(vx)["fixed"] = true
		sk.entity(right)["fixed"] = true
		ids.l1 = sk.add_line(vx, right)
		ids.l2 = sk.add_line(vx, _pt(sk, -34.641016151377, 20))
		ids.angle = sk.add_constraint("angle", [ids.l1, ids.l2], "150", "angle")
		var anchor: Vector2 = editor._dimension_anchor(sk, sk.constraint(ids.angle))
		sk.constraint(ids.angle)["offset"] = Vector2.from_angle(deg_to_rad(165.0)) * 0.015 - anchor)
	await _redraw(ws)
	s = editor.sketch()
	var shown: Dictionary = editor._shown_dimension(s, s.constraint(ids.angle))
	var before_center: Vector2 = _hit_entry(editor, ids.angle).get("text_center", Vector2.INF)
	_expect(editor._dim_draw_log.get(ids.angle, {}).get("text", "") == "150.0°" and absf(rad_to_deg(editor._sweep(s, shown.refs, shown.rays)) - 150.0) < 1e-6,
		"A legacy 150° angle is drawn over its 150° sector (%s)." % [shown])
	editor.open_dimension_edit(ids.angle)
	ws.last_step = {}
	editor._on_edit_submitted("150")
	await _redraw(ws)
	_expect(ws.last_step.is_empty() and _hit_entry(editor, ids.angle).get("text_center", Vector2.ZERO).distance_to(before_center) < 0.5,
		"Enter on its own value moves nothing on the canvas (%s vs %s)." % [_hit_entry(editor, ids.angle).get("text_center"), before_center])
	editor.open_dimension_edit(ids.angle)
	editor._on_edit_submitted("140")
	await _redraw(ws)
	s = editor.sketch()
	_expect(absf(_opening(_direction(s, ids.l1), _direction(s, ids.l2)) - 140.0) < 1e-6, "140 turns the line 10° (%f)." % _opening(_direction(s, ids.l1), _direction(s, ids.l2)))
	editor.cancel_tool()
