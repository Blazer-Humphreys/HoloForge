extends SceneTree
## Holo Forge sketch tools with scripted points, rebuilt through the timeline: every create tool
## (line chains, 3 rectangles, 5 circles, 3 arcs, 3 polygons, ellipse, 5 slots, splines, conic,
## point, text, text on a path) and modify tool (mirror, patterns, fillet, chamfer, trim, extend,
## break, offset, blend, scale, move/copy, construction, explode text, fully define) makes the
## exact profiles their geometry implies, and the constraints they add hold after solving.
##
## godot --headless --path . --script res://tests/holo_forge_sketch_tools_test.gd

const DOCUMENT := preload("res://addons/holo_forge/core/document.gd")
const REGEN := preload("res://addons/holo_forge/core/regen.gd")
const SKETCH := preload("res://addons/holo_forge/core/sketch/sketch_data.gd")
const SOLVE := preload("res://addons/holo_forge/core/sketch/sketch_solve.gd")
const B := preload("res://addons/holo_forge/core/sketch/sketch_builders.gd")
const TEXT := preload("res://addons/holo_forge/core/sketch/text_outline.gd")

var failures: Array[String] = []
var kernel: RefCounted


func _init() -> void:
	call_deferred("run")


func run() -> void:
	kernel = REGEN.make_kernel()
	_expect(kernel != null, "The native kernel should load.")
	if kernel != null:
		_check_create_tools()
		_check_modify_tools()
	print("PASS holo_forge_sketch_tools: every create and modify tool makes the expected profiles and constraints." if failures.is_empty() else "FAIL holo_forge_sketch_tools")
	quit(0 if failures.is_empty() else 1)


func _new_sketch() -> Array:
	var doc: Resource = DOCUMENT.new()
	var feature: Resource = doc.add_feature("sketch", "Sketch", {}, SKETCH.new_options(SKETCH.ORIGIN_PLANES.xz, "xz"))
	return [doc, SKETCH.new(feature, doc)]


## Rebuilds the document; returns the sketch's {"solve", "regions"} (and records errors).
func _rebuild(pair: Array, label: String) -> Dictionary:
	var result := REGEN.rebuild(pair[0], kernel)
	var sketch_id: String = pair[1].feature.id
	_expect(not result.errors.has(sketch_id), "%s: the sketch should rebuild cleanly (%s)." % [label, result.errors.get(sketch_id, "")])
	return result.sketches.get(sketch_id, {"solve": {}, "regions": []})


func _areas(state: Dictionary) -> Array:
	var areas := (state.regions as Array).map(func(r: Dictionary) -> float: return float(r.area))
	areas.sort()
	return areas


func _check_area(pair: Array, label: String, expected: Array, tolerance := 1e-9) -> Dictionary:
	var state := _rebuild(pair, label)
	var areas := _areas(state)
	expected.sort()
	var ok := areas.size() == expected.size()
	for i in mini(areas.size(), expected.size()):
		ok = ok and absf(float(areas[i]) - float(expected[i])) < tolerance
	_expect(ok, "%s: profile areas should be %s (got %s)." % [label, expected, areas])
	return state


func _check_create_tools() -> void:
	var pair := _new_sketch()
	var s: RefCounted = pair[1]
	var first := B.line(s, Vector2(0, 0), Vector2(0.05, 0.0001))
	var chained := B.line(s, Vector2(0.05, 0.0001), Vector2(0.05, 0.03), [{"point": s.entity(first[0]).p2}])
	_expect(s.constraints().any(func(c: Dictionary) -> bool: return c.type == "horizontal"), "A nearly flat line should get Horizontal.")
	_expect(s.entity(chained[0]).p1 == s.entity(first[0]).p2, "A chained line should share the previous end point.")
	var state := _rebuild(pair, "Line chain")
	_expect(absf(s.point(s.entity(first[0]).p2).y) < 1e-12, "Horizontal should level the line exactly.")

	pair = _new_sketch()
	B.rectangle_2pt(pair[1], Vector2(0, 0), Vector2(0.04, 0.02))
	_check_area(pair, "2-point rectangle", [0.0008])
	pair = _new_sketch()
	B.rectangle_3pt(pair[1], Vector2(0, 0), Vector2(0.03, 0.04), Vector2(0.03 - 0.016, 0.04 + 0.012))
	_check_area(pair, "3-point rectangle", [0.05 * 0.02])
	pair = _new_sketch()
	var centered := B.rectangle_center(pair[1], Vector2(0.01, 0.01), Vector2(0.03, 0.02))
	state = _check_area(pair, "Center rectangle", [0.04 * 0.02])
	_expect(centered.size() == 6 and pair[1].entity(centered[4]).construction, "A center rectangle adds two construction diagonals.")

	pair = _new_sketch()
	B.circle_center(pair[1], Vector2(0, 0), Vector2(0.01, 0))
	B.circle_2pt(pair[1], Vector2(0.1, 0), Vector2(0.12, 0))
	B.circle_3pt(pair[1], Vector2(0.2, 0.01), Vector2(0.21, 0), Vector2(0.2, -0.01))
	_check_area(pair, "Center / 2-point / 3-point circles", [PI * 1e-4, PI * 1e-4, PI * 1e-4], 1e-8)
	pair = _new_sketch()
	s = pair[1]
	var x_axis: int = s.add_line(s.add_point(Vector2(-0.05, 0), true), s.add_point(Vector2(0.05, 0), true))
	var y_axis: int = s.add_line(s.add_point(Vector2(0, -0.05), true), s.add_point(Vector2(0, 0.05), true))
	var tan2 := B.circle_2tan(s, x_axis, y_axis, 0.01, Vector2(0.02, 0.03))
	_rebuild(pair, "2-tangent circle")
	_expect(s.point(s.entity(tan2[0]).c).distance_to(Vector2(0.01, 0.01)) < 1e-9, "A 2-tangent circle of radius 10 mm in the corner sits at (10, 10) mm.")
	pair = _new_sketch()
	s = pair[1]
	var corners := [Vector2(0, 0), Vector2(0.04, 0), Vector2(0, 0.03)]
	var sides := []
	for i in 3:
		sides.append(s.add_line(s.add_point(corners[i], true), s.add_point(corners[(i + 1) % 3], true)))
	var tan3 := B.circle_3tan(s, sides, Vector2(0.01, 0.01))
	_rebuild(pair, "3-tangent circle")
	_expect(absf(float(s.entity(tan3[0]).r) - 0.01) < 1e-9, "The 3-4-5 triangle's incircle has radius 10 mm (got %f mm)." % (float(s.entity(tan3[0]).r) * 1000.0))

	pair = _new_sketch()
	s = pair[1]
	var arc := B.arc_3pt(s, Vector2(0.02, 0), Vector2(-0.02, 0), Vector2(0, 0.02))
	B.line(s, Vector2(-0.02, 0), Vector2(0.02, 0), [{"point": s.entity(arc[0]).s}, {"point": s.entity(arc[0]).e}])
	_check_area(pair, "3-point arc + line (half disk)", [PI * 0.0004 * 0.5], 1e-8)
	pair = _new_sketch()
	s = pair[1]
	var quarter := B.arc_center(s, Vector2(0, 0), Vector2(0.03, 0), Vector2(0, 0.05))
	var arc_e: Dictionary = s.entity(quarter[0])
	B.line(s, Vector2.ZERO, Vector2(0.03, 0), [{"point": arc_e.c}, {"point": arc_e.s}])
	B.line(s, Vector2.ZERO, Vector2(0, 0.03), [{"point": arc_e.c}, {"point": arc_e.e}])
	_check_area(pair, "Center-point arc (quarter disk)", [PI * 0.0009 * 0.25], 1e-8)
	pair = _new_sketch()
	s = pair[1]
	var lead := B.line(s, Vector2(-0.03, 0), Vector2(0, 0))
	var bend := B.arc_tangent(s, s.entity(lead[0]).p2, lead[0], Vector2(0.02, 0.02))
	_rebuild(pair, "Tangent arc")
	var bend_e: Dictionary = s.entity(bend[0])
	_expect(absf(s.point(bend_e.c).x) < 1e-9, "A tangent arc off a horizontal line has its center straight above the joint.")

	pair = _new_sketch()
	B.polygon(pair[1], Vector2.ZERO, Vector2(0.01, 0), 6)
	_check_area(pair, "Inscribed hexagon", [1.5 * sqrt(3.0) * 1e-4], 1e-8)
	pair = _new_sketch()
	B.polygon(pair[1], Vector2.ZERO, Vector2(0.01, 0), 4, true)
	_check_area(pair, "Circumscribed square", [4.0 * 1e-4], 1e-8)
	pair = _new_sketch()
	B.polygon_edge(pair[1], Vector2(0, 0), Vector2(0.02, 0), 4)
	_check_area(pair, "Edge polygon (square)", [0.0004], 1e-8)

	pair = _new_sketch()
	B.ellipse(pair[1], Vector2.ZERO, Vector2(0.03, 0), Vector2(0, 0.01))
	_check_area(pair, "Ellipse", [PI * 0.03 * 0.01], 1e-8)

	var straight_slot := 0.02 * 0.04 + PI * 0.0001
	pair = _new_sketch()
	B.slot_center_to_center(pair[1], Vector2(0, 0), Vector2(0.04, 0), Vector2(0, 0.01))
	_check_area(pair, "Center-to-center slot", [straight_slot], 1e-8)
	pair = _new_sketch()
	B.slot_overall(pair[1], Vector2(-0.01, 0), Vector2(0.05, 0), Vector2(0, 0.01))
	_check_area(pair, "Overall slot", [straight_slot], 1e-8)
	pair = _new_sketch()
	B.slot_center_point(pair[1], Vector2(0.02, 0), Vector2(0.04, 0), Vector2(0.02, 0.01))
	_check_area(pair, "Center point slot", [straight_slot], 1e-8)
	var arc_slot := PI * 0.5 * 0.5 * (0.035 * 0.035 - 0.025 * 0.025) + PI * 0.000025
	pair = _new_sketch()
	B.slot_arc(pair[1], Vector2.ZERO, Vector2(0.03, 0), Vector2(0, 0.03), Vector2(0.035, 0))
	_check_area(pair, "Center point arc slot", [arc_slot], 1e-8)
	pair = _new_sketch()
	B.slot_3pt_arc(pair[1], Vector2(0.03, 0), Vector2(0.03 * cos(PI / 4), 0.03 * sin(PI / 4)), Vector2(0, 0.03), Vector2(0.035, 0))
	_check_area(pair, "3-point arc slot", [arc_slot], 1e-8)

	pair = _new_sketch()
	s = pair[1]
	var fit := B.spline(s, [Vector2(0, 0), Vector2(0.01, 0.02), Vector2(0.03, 0.015), Vector2(0.04, 0)])
	var ends: Array = s.entity(fit[0]).points
	B.line(s, Vector2(0.04, 0), Vector2.ZERO, [{"point": ends[3]}, {"point": ends[0]}])
	_expect(_areas(_rebuild(pair, "Fit spline")).size() == 1, "A fit spline closed by a line makes a profile.")
	pair = _new_sketch()
	s = pair[1]
	var control := B.spline(s, [Vector2(0, 0), Vector2(0.01, 0.03), Vector2(0.03, 0.03), Vector2(0.04, 0)], "control")
	var poles: Array = s.entity(control[0]).points
	B.line(s, Vector2(0.04, 0), Vector2.ZERO, [{"point": poles[3]}, {"point": poles[0]}])
	_expect(_areas(_rebuild(pair, "Control spline")).size() == 1, "A control-point spline closed by a line makes a profile.")
	pair = _new_sketch()
	s = pair[1]
	var c := B.conic(s, Vector2(0, 0), Vector2(0.02, 0), Vector2(0.01, 0.01), 0.5)
	B.line(s, Vector2(0.02, 0), Vector2.ZERO, [{"point": s.entity(c[0]).e}, {"point": s.entity(c[0]).s}])
	# rho 0.5 is a parabola: the area under it is 2/3 of the triangle's base x height / ... = (2/3) * 0.02 * 0.005.
	_check_area(pair, "Conic (rho 0.5 parabola)", [2.0 / 3.0 * 0.02 * 0.005], 1e-9)
	pair = _new_sketch()
	var p := B.point(pair[1], Vector2(0.01, 0.02))
	_rebuild(pair, "Point")
	_expect(pair[1].point(p[0]).distance_to(Vector2(0.01, 0.02)) < 1e-12, "A sketch point stays where it was placed.")

	pair = _new_sketch()
	s = pair[1]
	B.text(s, Vector2.ZERO, "HO", 0.01)
	state = _rebuild(pair, "Text")
	_expect((state.regions as Array).size() >= 3, "Text 'HO' should give profiles for H, the O ring and the O's inside (got %d)." % (state.regions as Array).size())
	pair = _new_sketch()
	s = pair[1]
	var path := B.arc_center(s, Vector2.ZERO, Vector2(0.05, 0), Vector2(-0.05, 0))
	B.text(s, Vector2.ZERO, "ARC", 0.008, {"path": path[0]})
	s.entity(path[0]).construction = true
	state = _rebuild(pair, "Text on path")
	_expect((state.regions as Array).size() >= 3, "Text on a path should still give letter profiles (got %d)." % (state.regions as Array).size())


func _check_modify_tools() -> void:
	var pair := _new_sketch()
	var s: RefCounted = pair[1]
	var rect := B.rectangle_2pt(s, Vector2(0.01, 0), Vector2(0.03, 0.02))
	var axis := B.centerline(s, Vector2(0, -0.05), Vector2(0, 0.05))
	var mirrored := B.mirror(s, rect, axis[0])
	var state := _check_area(pair, "Mirror", [0.0004, 0.0004])
	_expect(mirrored.size() == 4 and s.constraints().filter(func(c: Dictionary) -> bool: return c.type == "symmetric").size() == 4, "Mirroring a rectangle adds 4 lines and 4 symmetric points.")
	var mirrored_x: float = s.point(s.entity(mirrored[0]).p1).x
	_expect(mirrored_x < 0.0, "The mirror copy lies on the other side of the axis.")

	pair = _new_sketch()
	s = pair[1]
	var square := B.rectangle_2pt(s, Vector2(0, 0), Vector2(0.01, 0.01))
	B.rectangular_pattern(s, square, Vector2.RIGHT, 3, 0.02, Vector2.UP, 2, 0.02, [Vector2i(2, 1)])
	_check_area(pair, "Rectangular pattern 3 x 2 minus one", [1e-4, 1e-4, 1e-4, 1e-4, 1e-4])
	pair = _new_sketch()
	s = pair[1]
	var dot := B.circle_center(s, Vector2(0.03, 0), Vector2(0.035, 0))
	B.circular_pattern(s, dot, Vector2.ZERO, 6)
	_check_area(pair, "Circular pattern of 6", [PI * 2.5e-5, PI * 2.5e-5, PI * 2.5e-5, PI * 2.5e-5, PI * 2.5e-5, PI * 2.5e-5], 1e-9)

	pair = _new_sketch()
	s = pair[1]
	var r := B.rectangle_2pt(s, Vector2(0, 0), Vector2(0.04, 0.02))
	var corner: int = s.entity(r[1]).p2
	var rounded = B.fillet(s, corner, 0.005)
	_expect(rounded is Array, "Fillet should round a rectangle corner (%s)." % [rounded])
	state = _check_area(pair, "Fillet", [0.0008 - (1.0 - PI / 4.0) * 0.000025], 1e-9)
	var chamfered = B.chamfer(s, s.entity(r[0]).p1, 0.004)
	_expect(chamfered is Array, "Chamfer should cut a corner (%s)." % [chamfered])
	_check_area(pair, "Fillet + equal chamfer", [0.0008 - (1.0 - PI / 4.0) * 0.000025 - 0.5 * 0.000016], 1e-9)
	pair = _new_sketch()
	s = pair[1]
	r = B.rectangle_2pt(s, Vector2(0, 0), Vector2(0.04, 0.02))
	B.chamfer(s, s.entity(r[0]).p1, 0.004, 0.002)
	_check_area(pair, "Two-distance chamfer", [0.0008 - 0.5 * 0.004 * 0.002], 1e-9)
	pair = _new_sketch()
	s = pair[1]
	r = B.rectangle_2pt(s, Vector2(0, 0), Vector2(0.04, 0.02))
	B.chamfer(s, s.entity(r[0]).p1, 0.004, -1.0, deg_to_rad(45.0))
	_check_area(pair, "Distance-angle chamfer (45 degrees = equal)", [0.0008 - 0.5 * 0.000016], 1e-9)

	pair = _new_sketch()
	s = pair[1]
	var cutter := B.line(s, Vector2(-0.02, 0), Vector2(0.02, 0))
	var ring := B.circle_center(s, Vector2.ZERO, Vector2(0.01, 0))
	var trimmed = B.trim(s, ring[0], Vector2(0, -0.01), kernel)
	_expect(trimmed is Array and trimmed.size() == 1 and s.entity(trimmed[0]).type == "arc", "Trimming the lower half of a circle leaves an arc (%s)." % [trimmed])
	var line_pieces = B.trim(s, cutter[0], Vector2(0.015, 0), kernel)
	var lengths: Array = (line_pieces as Array).map(func(id: int) -> float: return s.point(s.entity(id).p1).distance_to(s.point(s.entity(id).p2)))
	_expect(line_pieces is Array and lengths.size() == 1 and absf(float(lengths[0]) - 0.03) < 1e-9, "Trimming the line's right end leaves 30 mm of it (%s)." % [lengths])
	_check_area(pair, "Trimmed circle + line", [PI * 1e-4 * 0.5], 1e-8)

	pair = _new_sketch()
	s = pair[1]
	var wall := B.line(s, Vector2(0.05, -0.05), Vector2(0.05, 0.05))
	var short := B.line(s, Vector2(0, 0.0003), Vector2(0.02, 0.0003), [], false, false)
	B.extend(s, short[0], Vector2(0.019, 0.0003), kernel)
	_expect(absf(s.point(s.entity(short[0]).p2).x - 0.05) < 1e-9, "Extend should reach the wall at x = 50 mm.")
	var pieces = B.break_curve(s, wall[0], kernel)
	_expect(pieces is Array and pieces.size() == 2, "Break should split the wall where the extended line meets it.")

	pair = _new_sketch()
	s = pair[1]
	var box := B.rectangle_2pt(s, Vector2(0, 0), Vector2(0.02, 0.02))
	var grown = B.offset(s, box, 0.002, kernel)
	_expect(grown is Array and grown.size() == 8, "Offsetting a square outward gives 4 lines and 4 corner arcs (%s)." % [grown])
	_check_area(pair, "Offset loop", [0.0004, 0.024 * 0.024 - (4.0 - PI) * 0.000004 - 0.0004], 1e-9)

	pair = _new_sketch()
	s = pair[1]
	var left := B.line(s, Vector2(0, 0), Vector2(0.02, 0))
	var right := B.line(s, Vector2(0.04, 0.01), Vector2(0.06, 0.01))
	var smooth := B.blend(s, s.entity(left[0]).p2, left[0], s.entity(right[0]).p1, right[0])
	_expect(smooth.size() == 1 and (s.entity(smooth[0]).points as Array).size() == 4, "A G1 blend is a 4-point control spline.")
	var curvy := B.blend(s, s.entity(left[0]).p1, left[0], s.entity(right[0]).p2, right[0], true)
	_expect((s.entity(curvy[0]).points as Array).size() == 6 and int(s.entity(curvy[0]).degree) == 5, "A G2 blend is a 6-point degree-5 spline.")
	_rebuild(pair, "Blend curves")

	pair = _new_sketch()
	s = pair[1]
	var disk := B.circle_center(s, Vector2(0.01, 0), Vector2(0.015, 0))
	B.scale(s, disk, Vector2.ZERO, 2.0)
	_check_area(pair, "Scale x2", [PI * 0.0001], 1e-9)
	_expect(s.point(s.entity(disk[0]).c).distance_to(Vector2(0.02, 0)) < 1e-12, "Scaling about the origin moves the center out.")
	var copies := B.move(s, disk, Vector2(0, 0.05), 0.0, Vector2.ZERO, true)
	_check_area(pair, "Move/Copy", [PI * 0.0001, PI * 0.0001], 1e-9)
	B.move(s, copies, Vector2(0.1, 0))
	_expect(s.point(s.entity(copies[0]).c).distance_to(Vector2(0.12, 0.05)) < 1e-7, "Move shifts the copy.")
	B.toggle_construction(s, copies)
	_check_area(pair, "Construction geometry makes no profile", [PI * 0.0001], 1e-9)

	pair = _new_sketch()
	s = pair[1]
	var word := B.text(s, Vector2.ZERO, "L", 0.01)
	var exploded := B.explode_text(s, word[0], TEXT.outlines(s.entity(word[0]), s, kernel))
	_expect(exploded.size() >= 6 and s.entity(word[0]).is_empty(), "Exploding 'L' gives its outline as lines.")
	_expect(_areas(_rebuild(pair, "Exploded text")).size() == 1, "The exploded 'L' is one profile.")

	pair = _new_sketch()
	s = pair[1]
	B.rectangle_2pt(s, Vector2(0.01, 0.01), Vector2(0.03, 0.02))
	var doc: Resource = pair[0]
	var solve := func(sketch: RefCounted) -> Dictionary: return SOLVE.solve(sketch, REGEN.rebuild(doc, kernel).values)
	var added := B.fully_define(s, solve)
	var final: Dictionary = solve.call(s)
	_expect(added >= 3 and int(final.dof) == 0, "Fully Define should leave no degrees of freedom (added %d, dof %d)." % [added, final.dof])


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)
		print("FAIL: ", message)
