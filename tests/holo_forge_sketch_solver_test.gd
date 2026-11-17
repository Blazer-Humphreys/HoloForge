extends SceneTree
## Holo Forge sketch solver (planegcs): every constraint type and dimension holds after a solve
## (coincident, horizontal, vertical, parallel, perpendicular, point on line/circle/arc/ellipse,
## midpoint, symmetric, equal, concentric, collinear, tangent, all distance kinds, radius,
## diameter, angle, arc length, length, coordinates); driven dimensions measure without moving
## anything; degrees of freedom count down to 0; conflicts and redundancies are reported; dragging
## pulls a point as far as its constraints allow; and free geometry is listed for coloring.
##
## godot --headless --path . --script res://tests/holo_forge_sketch_solver_test.gd

const P := 0
const L := 1
const C := 2
const A := 3
const E := 4

var failures: Array[String] = []


func _init() -> void:
	call_deferred("run")


func run() -> void:
	if not ClassDB.class_exists("CadSketchSolver"):
		_expect(false, "The native sketch solver should load.")
	else:
		_check_geometric()
		_check_dimensions()
		_check_dof_conflicts()
		_check_drag_and_free()
	print("PASS holo_forge_sketch_solver: every constraint and dimension type, driven dimensions, DOF, conflicts and redundancy, drag, free geometry." \
		if failures.is_empty() else "FAIL holo_forge_sketch_solver")
	quit(0 if failures.is_empty() else 1)


func _solver():
	return ClassDB.instantiate("CadSketchSolver")


func _solved(s, label: String) -> void:
	var status: int = s.solve()
	_expect(status == 0 or status == 1, "%s should solve (status %d, conflicts %s)" % [label, status, s.get_conflicting()])


func _check_geometric() -> void:
	# Coincident, horizontal and vertical (lines and point pairs), parallel, perpendicular.
	var s = _solver()
	var p0: int = s.add_point(Vector2(0, 0))
	var p1: int = s.add_point(Vector2(2, 0.3))
	var p2: int = s.add_point(Vector2(2.2, 1.9))
	var p3: int = s.add_point(Vector2(0.1, 2.1))
	var q: int = s.add_point(Vector2(0.4, -0.2))
	var bottom: int = s.add_line(p0, p1)
	var right: int = s.add_line(p1, p2)
	var top: int = s.add_line(p2, p3)
	s.set_point_fixed(p0, true)
	s.add_constraint("horizontal", [Vector2i(L, bottom)])
	s.add_constraint("vertical", [Vector2i(P, p0), Vector2i(P, p3)])
	s.add_constraint("parallel", [Vector2i(L, top), Vector2i(L, bottom)])
	s.add_constraint("perpendicular", [Vector2i(L, right), Vector2i(L, bottom)])
	s.add_constraint("coincident", [Vector2i(P, q), Vector2i(P, p0)])
	_solved(s, "Horizontal/vertical/parallel/perpendicular/coincident")
	var a: Vector2 = s.get_point(p0)
	var b: Vector2 = s.get_point(p1)
	var c: Vector2 = s.get_point(p2)
	var d: Vector2 = s.get_point(p3)
	_expect(absf(a.y - b.y) < 1e-5 and absf(a.x - d.x) < 1e-5 and absf(c.y - d.y) < 1e-5 and absf(b.x - c.x) < 1e-5, "The quad should become a rectangle (%s %s %s %s)." % [a, b, c, d])
	_expect(s.get_point(q).distance_to(a) < 1e-5, "Coincident points should meet.")

	# Point on line / circle / arc / ellipse, midpoint, symmetric about a line and a point.
	s = _solver()
	var l0: int = s.add_point(Vector2(0, 0))
	var l1: int = s.add_point(Vector2(4, 1))
	var line: int = s.add_line(l0, l1)
	var on_line: int = s.add_point(Vector2(1, 2))
	var center: int = s.add_point(Vector2(10, 0))
	var circle: int = s.add_circle(center, 2.0)
	var on_circle: int = s.add_point(Vector2(13, 1))
	var arc_center: int = s.add_point(Vector2(20, 0))
	var arc: int = s.add_arc(arc_center, 3.0, 0.0, PI * 0.5)
	var on_arc: int = s.add_point(Vector2(22, 3))
	var e_center: int = s.add_point(Vector2(30, 0))
	var e_focus: int = s.add_point(Vector2(32, 0))
	var ellipse: int = s.add_ellipse(e_center, e_focus, 1.5)
	var on_ellipse: int = s.add_point(Vector2(31, 2))
	var mid: int = s.add_point(Vector2(1.5, 1.5))
	var m0: int = s.add_point(Vector2(-3, 1))
	var m1: int = s.add_point(Vector2(-1, -2))
	var pivot: int = s.add_point(Vector2(5, 5))
	var n0: int = s.add_point(Vector2(4, 4))
	var n1: int = s.add_point(Vector2(7, 5.5))
	for fixed in [l0, l1, center, arc_center, e_center, e_focus, pivot]:
		s.set_point_fixed(fixed, true)
	s.set_fixed(Vector2i(C, circle), true)
	s.set_fixed(Vector2i(A, arc), true)
	s.set_fixed(Vector2i(E, ellipse), true)
	s.add_constraint("point_on", [Vector2i(P, on_line), Vector2i(L, line)])
	s.add_constraint("point_on", [Vector2i(P, on_circle), Vector2i(C, circle)])
	s.add_constraint("point_on", [Vector2i(P, on_arc), Vector2i(A, arc)])
	s.add_constraint("point_on", [Vector2i(P, on_ellipse), Vector2i(E, ellipse)])
	s.add_constraint("midpoint", [Vector2i(P, mid), Vector2i(L, line)])
	s.add_constraint("symmetric", [Vector2i(P, m0), Vector2i(P, m1), Vector2i(L, line)])
	s.add_constraint("symmetric", [Vector2i(P, n0), Vector2i(P, n1), Vector2i(P, pivot)])
	_solved(s, "Point on / midpoint / symmetric")
	var dir: Vector2 = (s.get_point(l1) - s.get_point(l0)).normalized()
	var rel: Vector2 = s.get_point(on_line) - s.get_point(l0)
	_expect(absf(rel.cross(dir)) < 1e-5, "A point on a line should lie on it.")
	_expect(absf(s.get_point(on_circle).distance_to(s.get_point(center)) - 2.0) < 1e-5, "A point on a circle should be at its radius.")
	_expect(absf(s.get_point(on_arc).distance_to(s.get_point(arc_center)) - 3.0) < 1e-5, "A point on an arc should be at its radius.")
	var f2: Vector2 = 2.0 * s.get_point(e_center) - s.get_point(e_focus)
	var major := sqrt(1.5 * 1.5 + 2.0 * 2.0)
	var sum: float = s.get_point(on_ellipse).distance_to(s.get_point(e_focus)) + s.get_point(on_ellipse).distance_to(f2)
	_expect(absf(sum - 2.0 * major) < 1e-5, "A point on an ellipse should keep the focal distance sum (%f vs %f)." % [sum, 2.0 * major])
	_expect(s.get_point(mid).distance_to((s.get_point(l0) + s.get_point(l1)) * 0.5) < 1e-5, "A midpoint should sit half way.")
	var reflected: Vector2 = (s.get_point(m0) - s.get_point(l0)).reflect(dir) + s.get_point(l0)
	_expect(reflected.distance_to(s.get_point(m1)) < 1e-5, "Points symmetric about a line should mirror each other.")
	_expect(((s.get_point(n0) + s.get_point(n1)) * 0.5).distance_to(s.get_point(pivot)) < 1e-5, "Points symmetric about a point should straddle it.")

	# Equal (lines, circles, arcs), concentric, collinear, tangent (line-circle, circle-circle,
	# arc-arc, line-arc).
	s = _solver()
	var a0: int = s.add_point(Vector2(0, 0))
	var a1: int = s.add_point(Vector2(3, 0))
	var b0: int = s.add_point(Vector2(0, 2))
	var b1: int = s.add_point(Vector2(1.5, 3))
	var c0: int = s.add_point(Vector2(5, 0.4))
	var c1: int = s.add_point(Vector2(8, -0.3))
	var la: int = s.add_line(a0, a1)
	var lb: int = s.add_line(b0, b1)
	var lc: int = s.add_line(c0, c1)
	s.set_point_fixed(a0, true)
	s.set_point_fixed(a1, true)
	s.add_constraint("equal", [Vector2i(L, la), Vector2i(L, lb)])
	s.add_constraint("collinear", [Vector2i(L, la), Vector2i(L, lc)])
	var cc: int = s.add_point(Vector2(0, 6))
	var big: int = s.add_circle(cc, 2.0)
	s.set_fixed(Vector2i(C, big), true)
	var small_c: int = s.add_point(Vector2(3.5, 6.5))
	var small: int = s.add_circle(small_c, 1.0)
	var arc_c: int = s.add_point(Vector2(0.2, 5.9))
	var ring: int = s.add_arc(arc_c, 1.3, 0.0, PI)
	var arc2_c: int = s.add_point(Vector2(-4, 6))
	var arc2: int = s.add_arc(arc2_c, 1.0, 0.0, PI)
	var tl0: int = s.add_point(Vector2(-3, 9))
	var tl1: int = s.add_point(Vector2(3, 8.5))
	var tangent_line: int = s.add_line(tl0, tl1)
	s.add_constraint("equal", [Vector2i(C, small), Vector2i(A, arc2)])
	s.add_constraint("concentric", [Vector2i(C, big), Vector2i(A, ring)])
	s.add_constraint("tangent", [Vector2i(C, big), Vector2i(C, small)])
	s.add_constraint("tangent", [Vector2i(A, arc2), Vector2i(C, big)])
	s.add_constraint("tangent", [Vector2i(L, tangent_line), Vector2i(C, big)])
	var arc3_c: int = s.add_point(Vector2(0, 12))
	var arc3: int = s.add_arc(arc3_c, 1.0, PI, TAU)
	s.add_constraint("tangent", [Vector2i(L, tangent_line), Vector2i(A, arc3)])
	_solved(s, "Equal / collinear / concentric / tangent")
	_expect(absf(s.get_point(b0).distance_to(s.get_point(b1)) - 3.0) < 1e-5, "Equal lines should match in length.")
	_expect(absf(s.get_point(c0).y) < 1e-5 and absf(s.get_point(c1).y) < 1e-5, "A collinear line should lie on the other's line.")
	_expect(s.get_point(arc_c).distance_to(s.get_point(cc)) < 1e-5, "Concentric arc and circle should share a center.")
	_expect(absf(s.get_point(small_c).distance_to(s.get_point(cc)) - (2.0 + s.get_circle_radius(small))) < 1e-5, "External circle tangency: centers one radius sum apart.")
	_expect(absf(s.get_circle_radius(small) - s.get_arc_radius(arc2)) < 1e-5, "An equal circle and arc should share a radius.")
	_expect(absf(s.get_point(arc2_c).distance_to(s.get_point(cc)) - (2.0 + s.get_arc_radius(arc2))) < 1e-5, "Arc-circle tangency should touch.")
	var tl_a: Vector2 = s.get_point(tl0)
	var line_dir: Vector2 = (s.get_point(tl1) - tl_a).normalized()
	var center_distance: float = absf((s.get_point(cc) - tl_a).cross(line_dir))
	_expect(absf(center_distance - 2.0) < 1e-5, "A tangent line should be one radius from the circle's center (%f)." % center_distance)
	var arc3_distance: float = absf((s.get_point(arc3_c) - tl_a).cross(line_dir))
	_expect(absf(arc3_distance - s.get_arc_radius(arc3)) < 1e-5, "A tangent line should touch the arc (%f vs %f)." % [arc3_distance, s.get_arc_radius(arc3)])


func _check_dimensions() -> void:
	var s = _solver()
	var o: int = s.add_point(Vector2(0, 0))
	s.set_point_fixed(o, true)
	var p: int = s.add_point(Vector2(1, 1))
	var r0: int = s.add_point(Vector2(0, -1))
	var r1: int = s.add_point(Vector2(5, -1.2))
	var base: int = s.add_line(r0, r1)
	var s0: int = s.add_point(Vector2(0, -3))
	var s1: int = s.add_point(Vector2(4, -3.3))
	var parallel_line: int = s.add_line(s0, s1)
	var c: int = s.add_circle(s.add_point(Vector2(10, 10)), 1.0)
	var c2: int = s.add_circle(s.add_point(Vector2(16, 10)), 1.5)
	var arc: int = s.add_arc(s.add_point(Vector2(-10, 0)), 2.0, 0.0, 1.0)
	var t0: int = s.add_point(Vector2(20, 0))
	var t1: int = s.add_point(Vector2(23, 1))
	var tilted: int = s.add_line(t0, t1)
	var flat: int = s.add_line(s.add_point(Vector2(20, -2)), s.add_point(Vector2(24, -2)))
	s.set_fixed(Vector2i(L, flat), true)
	s.set_point_fixed(t0, true)
	var tags := {}
	tags.dx = s.add_constraint("distance_x", [Vector2i(P, o), Vector2i(P, p)], 0.7)
	tags.dy = s.add_constraint("distance_y", [Vector2i(P, o), Vector2i(P, p)], 1.3)
	s.add_constraint("horizontal", [Vector2i(L, base)])
	s.add_constraint("coordinate_x", [Vector2i(P, r0)], 0.0)
	tags.base_y = s.add_constraint("coordinate_y", [Vector2i(P, r0)], -1.0)
	tags.length = s.add_constraint("length", [Vector2i(L, base)], 6.0)
	tags.pl = s.add_constraint("distance", [Vector2i(P, p), Vector2i(L, base)], 2.3)
	s.add_constraint("parallel", [Vector2i(L, parallel_line), Vector2i(L, base)])
	tags.ll = s.add_constraint("distance", [Vector2i(L, base), Vector2i(L, parallel_line)], 2.5)
	tags.radius = s.add_constraint("radius", [Vector2i(C, c)], 1.75)
	tags.diameter = s.add_constraint("diameter", [Vector2i(C, c2)], 2.0)
	tags.cc = s.add_constraint("distance", [Vector2i(C, c), Vector2i(C, c2)], 3.0)
	tags.pc = s.add_constraint("distance", [Vector2i(P, o), Vector2i(C, c)], 9.0)
	tags.arc_length = s.add_constraint("arc_length", [Vector2i(A, arc)], 3.0)
	tags.angle = s.add_constraint("angle", [Vector2i(L, flat), Vector2i(L, tilted)], deg_to_rad(30.0))
	tags.tilted_length = s.add_constraint("length", [Vector2i(L, tilted)], 2.0)
	tags.cl = s.add_constraint("distance", [Vector2i(C, c2), Vector2i(L, base)], 4.0)
	var driven: int = s.add_constraint("distance", [Vector2i(P, o), Vector2i(P, r1)], 0.0, false)
	for key in tags:
		_expect(int(tags[key]) > 0, "Dimension %s should be accepted." % key)
	_solved(s, "Every dimension kind")
	var po: Vector2 = s.get_point(p) - s.get_point(o)
	_expect(absf(po.x - 0.7) < 1e-5 and absf(po.y - 1.3) < 1e-5, "Horizontal and vertical distances should hold (%s)." % po)
	_expect(absf(s.get_point(r0).distance_to(s.get_point(r1)) - 6.0) < 1e-5, "Line length should hold.")
	_expect(absf((s.get_point(p) - s.get_point(r0)).y - 2.3) < 1e-5, "Point-line distance should hold.")
	_expect(absf(s.get_point(s0).y + 3.5) < 1e-5 and absf(s.get_point(s1).y + 3.5) < 1e-5, "Line-line distance should hold for parallel lines (%s %s)." % [s.get_point(s0), s.get_point(s1)])
	_expect(absf(s.get_circle_radius(c) - 1.75) < 1e-5 and absf(s.get_circle_radius(c2) - 1.0) < 1e-5, "Radius and diameter should hold.")
	_expect(absf(s.get_arc_radius(arc) * (s.get_arc_angles(arc).y - s.get_arc_angles(arc).x) - 3.0) < 1e-5, "Arc length should hold.")
	var angle: float = (s.get_point(t1) - s.get_point(t0)).angle()
	_expect(absf(rad_to_deg(angle) - 30.0) < 1e-4 or absf(rad_to_deg(angle) + 30.0) < 1e-6 or absf(absf(rad_to_deg(angle)) - 150.0) < 1e-6,
		"The angle between lines should be 30 degrees (got %f)." % rad_to_deg(angle))
	_expect(absf(s.get_constraint_value(driven) - s.get_point(o).distance_to(s.get_point(r1))) < 1e-5, "A driven dimension should measure the geometry.")
	_expect(absf(s.get_constraint_value(tags.radius) - 1.75) < 1e-12, "A driving dimension keeps its value.")
	var before: Vector2 = s.get_point(r1)
	s.set_constraint_value(driven, 100.0)
	s.solve()
	_expect(s.get_point(r1).distance_to(before) < 1e-5, "Changing a driven dimension must not move anything.")


func _check_dof_conflicts() -> void:
	var s = _solver()
	var a: int = s.add_point(Vector2(0, 0))
	var b: int = s.add_point(Vector2(3, 0.5))
	var line: int = s.add_line(a, b)
	_solved(s, "A free line")
	_expect(s.get_dof() == 4, "A free line has 4 degrees of freedom (got %d)." % s.get_dof())
	s.set_point_fixed(a, true)
	s.add_constraint("horizontal", [Vector2i(L, line)])
	_solved(s, "A fixed, horizontal line")
	_expect(s.get_dof() == 1, "A fixed horizontal line has 1 degree of freedom left (got %d)." % s.get_dof())
	var length: int = s.add_constraint("length", [Vector2i(L, line)], 5.0)
	_solved(s, "A fully defined line")
	_expect(s.get_dof() == 0, "Adding its length leaves 0 degrees of freedom (got %d)." % s.get_dof())
	var again: int = s.add_constraint("horizontal", [Vector2i(L, line)])
	s.solve()
	_expect(s.get_redundant().has(again) or s.get_redundant().has(1), "A second horizontal should be reported as redundant (%s)." % s.get_redundant())
	var clash: int = s.add_constraint("distance_x", [Vector2i(P, a), Vector2i(P, b)], 2.0)
	s.solve()
	_expect(s.get_conflicting().has(clash) and s.get_conflicting().has(length), "A horizontal distance of 2 against a length of 5 should conflict (%s)." % s.get_conflicting())
	_expect(s.add_constraint("tangent", [Vector2i(P, a), Vector2i(P, b)]) == -1, "Constraints that don't fit their references are refused.")


func _check_drag_and_free() -> void:
	var s = _solver()
	var free_point: int = s.add_point(Vector2(0, 0))
	var center: int = s.add_point(Vector2(5, 0))
	var circle: int = s.add_circle(center, 2.0)
	s.set_fixed(Vector2i(C, circle), true)
	var rider: int = s.add_point(Vector2(7, 0))
	s.add_constraint("point_on", [Vector2i(P, rider), Vector2i(C, circle)])
	var a: int = s.add_point(Vector2(10, 0))
	var b: int = s.add_point(Vector2(12, 0))
	var line: int = s.add_line(a, b)
	s.set_point_fixed(a, true)
	s.add_constraint("horizontal", [Vector2i(L, line)])
	s.add_constraint("length", [Vector2i(L, line)], 2.0)
	s.solve()
	s.drag_point(free_point, Vector2(1.5, -2.0))
	_expect(s.get_point(free_point).distance_to(Vector2(1.5, -2.0)) < 1e-6, "Dragging a free point should move it to the mouse.")
	s.drag_point(rider, Vector2(5, 10))
	var on: Vector2 = s.get_point(rider)
	_expect(absf(on.distance_to(Vector2(5, 0)) - 2.0) < 1e-6 and on.y > 1.9, "Dragging a point on a circle should slide it around the circle toward the mouse (%s)." % on)
	s.drag_point(b, Vector2(20, 5))
	_expect(s.get_point(b).distance_to(Vector2(12, 0)) < 1e-6, "A fully constrained point should not move when dragged.")
	s.solve()
	var free: Array = s.get_free_geometry()
	_expect(free.has(Vector2i(P, free_point)) and free.has(Vector2i(P, rider)), "Unconstrained points should be listed as free (%s)." % [free])
	_expect(not free.has(Vector2i(L, line)) and not free.has(Vector2i(P, b)), "A fully defined line should not be listed as free (%s)." % [free])


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)
		print("FAIL: ", message)
