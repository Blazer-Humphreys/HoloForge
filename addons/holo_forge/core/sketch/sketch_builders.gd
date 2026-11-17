@tool
extends RefCounted
## The geometry every sketch tool makes, as plain functions on a sketch (sketch_data.gd).
##
## Interactive tools call these with picked points for both their live preview (on a scratch
## copy) and the real edit; tests call them with scripted points. A "snap" is {} or
## {"point": id} (reuse that point) or {"curve": id} (put the new point on that curve).
## Each function returns the new entity ids (or an error String for modify tools that can fail).

const UNITS := preload("res://addons/holo_forge/core/units.gd")
const AXIS_TOLERANCE := 0.012


static func _pt(s: RefCounted, p: Vector2, snap := {}) -> int:
	var id: int = s.point_or(p, int(snap.get("point", -1)))
	if snap.has("midpoint") and int(snap.midpoint) >= 0:
		s.add_constraint("midpoint", [id, int(snap.midpoint)])
	elif snap.has("curve") and int(snap.curve) >= 0 and id != int(snap.get("point", -1)):
		s.add_constraint("coincident", [id, int(snap.curve)])
	return id


static func _snap(snaps: Array, i: int) -> Dictionary:
	return snaps[i] if i < snaps.size() and snaps[i] is Dictionary else {}


## Adds horizontal or vertical when a line is within ~0.7 degrees of an axis.
static func _auto_axis(s: RefCounted, line: int) -> void:
	var e: Dictionary = s.entity(line)
	var d: Vector2 = s.point(int(e.p2)) - s.point(int(e.p1))
	if d.length() < 1e-12:
		return
	if absf(d.y) / d.length() < AXIS_TOLERANCE:
		s.add_constraint("horizontal", [line])
	elif absf(d.x) / d.length() < AXIS_TOLERANCE:
		s.add_constraint("vertical", [line])


# --- Lines and rectangles --------------------------------------------------------------------

static func line(s: RefCounted, a: Vector2, b: Vector2, snaps := [], construction := false, auto_axis := true) -> Array[int]:
	var id: int = s.add_line(_pt(s, a, _snap(snaps, 0)), _pt(s, b, _snap(snaps, 1)), construction)
	if auto_axis:
		_auto_axis(s, id)
	return [id]


static func centerline(s: RefCounted, a: Vector2, b: Vector2, snaps := []) -> Array[int]:
	var id: int = s.add_line(_pt(s, a, _snap(snaps, 0)), _pt(s, b, _snap(snaps, 1)), true, true)
	_auto_axis(s, id)
	return [id]


static func _quad(s: RefCounted, corners: Array, snaps: Array) -> Array[int]:
	var pts: Array[int] = []
	for i in 4:
		pts.append(_pt(s, corners[i], _snap(snaps, i)))
	var lines: Array[int] = []
	for i in 4:
		lines.append(s.add_line(pts[i], pts[(i + 1) % 4]))
	return lines


static func rectangle_2pt(s: RefCounted, a: Vector2, b: Vector2, snaps := []) -> Array[int]:
	var lines := _quad(s, [a, Vector2(b.x, a.y), b, Vector2(a.x, b.y)], [_snap(snaps, 0), {}, _snap(snaps, 1), {}])
	s.add_constraint("horizontal", [lines[0]])
	s.add_constraint("horizontal", [lines[2]])
	s.add_constraint("vertical", [lines[1]])
	s.add_constraint("vertical", [lines[3]])
	return lines


static func rectangle_3pt(s: RefCounted, a: Vector2, b: Vector2, c: Vector2, snaps := []) -> Array[int]:
	var edge := b - a
	var normal := Vector2(-edge.y, edge.x).normalized()
	var height := (c - b).dot(normal)
	var lines := _quad(s, [a, b, b + normal * height, a + normal * height], [_snap(snaps, 0), _snap(snaps, 1), {}, {}])
	s.add_constraint("perpendicular", [lines[0], lines[1]])
	s.add_constraint("parallel", [lines[0], lines[2]])
	s.add_constraint("parallel", [lines[1], lines[3]])
	_auto_axis(s, lines[0])
	return lines


static func rectangle_center(s: RefCounted, center: Vector2, corner: Vector2, snaps := []) -> Array[int]:
	var half := corner - center
	var lines := _quad(s, [center - half, Vector2(center.x + half.x, center.y - half.y), center + half, Vector2(center.x - half.x, center.y + half.y)], [{}, {}, _snap(snaps, 1), {}])
	s.add_constraint("horizontal", [lines[0]])
	s.add_constraint("horizontal", [lines[2]])
	s.add_constraint("vertical", [lines[1]])
	s.add_constraint("vertical", [lines[3]])
	# Construction diagonals keep the rectangle centered on its center point.
	var c := _pt(s, center, _snap(snaps, 0))
	var d1: int = s.add_line(int(s.entity(lines[0]).p1), int(s.entity(lines[2]).p1), true)
	var d2: int = s.add_line(int(s.entity(lines[1]).p1), int(s.entity(lines[3]).p1), true)
	s.add_constraint("midpoint", [c, d1])
	s.add_constraint("midpoint", [c, d2])
	lines.append_array([d1, d2])
	return lines


# --- Circles and arcs ------------------------------------------------------------------------

static func circle_center(s: RefCounted, center: Vector2, rim: Vector2, snaps := [], construction := false) -> Array[int]:
	var c := _pt(s, center, _snap(snaps, 0))
	var id: int = s.add_circle(c, maxf(center.distance_to(rim), 1e-6), construction)
	if _snap(snaps, 1).has("point"):
		s.add_constraint("coincident", [int(snaps[1].point), id])
	return [id]


static func circle_2pt(s: RefCounted, a: Vector2, b: Vector2, snaps := []) -> Array[int]:
	var id: int = s.add_circle(s.add_point((a + b) * 0.5), maxf(a.distance_to(b) * 0.5, 1e-6))
	for i in 2:
		var snap := _snap(snaps, i)
		var p := _pt(s, [a, b][i], snap)
		s.add_constraint("coincident", [p, id])
	return [id]


## The circle through three points: {"center", "radius"} (empty when they are in a line).
static func circumcircle(a: Vector2, b: Vector2, c: Vector2) -> Dictionary:
	var d := 2.0 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
	if absf(d) < 1e-14:
		return {}
	var ux := ((a.length_squared()) * (b.y - c.y) + (b.length_squared()) * (c.y - a.y) + (c.length_squared()) * (a.y - b.y)) / d
	var uy := ((a.length_squared()) * (c.x - b.x) + (b.length_squared()) * (a.x - c.x) + (c.length_squared()) * (b.x - a.x)) / d
	var center := Vector2(ux, uy)
	return {"center": center, "radius": center.distance_to(a)}


static func circle_3pt(s: RefCounted, a: Vector2, b: Vector2, c: Vector2, snaps := []) -> Array[int]:
	var circle := circumcircle(a, b, c)
	if circle.is_empty():
		return []
	var id: int = s.add_circle(s.add_point(circle.center), circle.radius)
	for i in 3:
		s.add_constraint("coincident", [_pt(s, [a, b, c][i], _snap(snaps, i)), id])
	return [id]


## A circle tangent to two lines, of the given radius, on the side of hint.
static func circle_2tan(s: RefCounted, line_a: int, line_b: int, radius: float, hint: Vector2) -> Array[int]:
	var offsets := []
	for line_id in [line_a, line_b]:
		var e: Dictionary = s.entity(line_id)
		var p: Vector2 = s.point(int(e.p1))
		var d: Vector2 = (s.point(int(e.p2)) - p).normalized()
		var n := Vector2(-d.y, d.x)
		var side := signf((hint - p).dot(n))
		offsets.append([p + n * side * radius, d])
	var center = Geometry2D.line_intersects_line(offsets[0][0], offsets[0][1], offsets[1][0], offsets[1][1])
	if center == null:
		return []
	var id: int = s.add_circle(s.add_point(center), radius)
	s.add_constraint("tangent", [line_a, id])
	s.add_constraint("tangent", [line_b, id])
	return [id]


## A circle tangent to three lines (the one nearest hint); the solver settles the exact fit.
static func circle_3tan(s: RefCounted, lines: Array, hint: Vector2) -> Array[int]:
	var nearest := INF
	for line_id in lines:
		var e: Dictionary = s.entity(int(line_id))
		var closest := Geometry2D.get_closest_point_to_segment_uncapped(hint, s.point(int(e.p1)), s.point(int(e.p2)))
		nearest = minf(nearest, closest.distance_to(hint))
	var id: int = s.add_circle(s.add_point(hint), maxf(nearest, 1e-6))
	for line_id in lines:
		s.add_constraint("tangent", [int(line_id), id])
	return [id]


static func _ccw_arc(s: RefCounted, c: int, from: int, to: int, through: Vector2, construction := false) -> int:
	# Keep arcs counter-clockwise: if the middle point is on the clockwise way, swap the ends.
	var center: Vector2 = s.point(c)
	var a0: float = (s.point(from) - center).angle()
	var a1: float = (s.point(to) - center).angle()
	var am := (through - center).angle()
	if fposmod(am - a0, TAU) > fposmod(a1 - a0, TAU):
		return s.add_arc(c, to, from, construction)
	return s.add_arc(c, from, to, construction)


static func arc_3pt(s: RefCounted, start: Vector2, end: Vector2, middle: Vector2, snaps := []) -> Array[int]:
	var circle := circumcircle(start, middle, end)
	if circle.is_empty():
		return []
	var c: int = s.add_point(circle.center)
	var a := _pt(s, start, _snap(snaps, 0))
	var b := _pt(s, end, _snap(snaps, 1))
	return [_ccw_arc(s, c, a, b, middle)]


static func arc_center(s: RefCounted, center: Vector2, start: Vector2, end: Vector2, snaps := []) -> Array[int]:
	var c := _pt(s, center, _snap(snaps, 0))
	var r := center.distance_to(start)
	var a := _pt(s, start, _snap(snaps, 1))
	var b: int = s.add_point(center + (end - center).normalized() * r)
	return [s.add_arc(c, a, b)]


## An arc starting tangent to a curve at one of its end points and ending at end.
static func arc_tangent(s: RefCounted, from_point: int, from_curve: int, end: Vector2, snaps := []) -> Array[int]:
	var p: Vector2 = s.point(from_point)
	var t := end_tangent(s, from_curve, from_point)
	var n := Vector2(-t.y, t.x)
	var chord := p - end
	var denominator := 2.0 * n.dot(chord)
	if absf(denominator) < 1e-12:
		return line(s, p, end, [{"point": from_point}, _snap(snaps, 0)], false, false)
	var offset := -chord.length_squared() / denominator
	var c: int = s.add_point(p + n * offset)
	var e := _pt(s, end, _snap(snaps, 0))
	var id: int = s.add_arc(c, from_point, e) if offset > 0.0 else s.add_arc(c, e, from_point)
	s.add_constraint("tangent", [from_curve, id])
	return [id]


## The direction leaving a curve at one of its end points (outward).
static func end_tangent(s: RefCounted, curve: int, at_point: int) -> Vector2:
	var e: Dictionary = s.entity(curve)
	match str(e.get("type", "")):
		"line":
			var other := int(e.p1) if int(e.p2) == at_point else int(e.p2)
			return (s.point(at_point) - s.point(other)).normalized()
		"arc":
			var radial: Vector2 = (s.point(at_point) - s.point(int(e.c))).normalized()
			# Counter-clockwise arcs leave their end point turning left, enter at the start.
			return Vector2(-radial.y, radial.x) if int(e.e) == at_point else Vector2(radial.y, -radial.x)
		"spline":
			var pts: Array = e.points
			var last := pts.size() - 1
			if int(pts[0]) == at_point:
				return (s.point(int(pts[0])) - s.point(int(pts[1]))).normalized()
			return (s.point(int(pts[last])) - s.point(int(pts[last - 1]))).normalized()
	return Vector2.RIGHT


# --- Polygons, ellipses, slots ---------------------------------------------------------------

static func _regular(s: RefCounted, center: Vector2, radius: float, angle0: float, sides: int, circle_radius: float, tangent: bool, snaps := []) -> Array[int]:
	sides = clampi(sides, 3, 64)
	var c := _pt(s, center, _snap(snaps, 0))
	var guide: int = s.add_circle(c, circle_radius, true)
	var pts: Array[int] = []
	for i in sides:
		var a := angle0 + TAU * i / sides
		pts.append(s.add_point(center + Vector2(cos(a), sin(a)) * radius))
	var lines: Array[int] = []
	for i in sides:
		lines.append(s.add_line(pts[i], pts[(i + 1) % sides]))
	for i in range(1, sides):
		s.add_constraint("equal", [lines[0], lines[i]])
	for i in sides:
		if tangent:
			s.add_constraint("tangent", [lines[i], guide])
		else:
			s.add_constraint("coincident", [pts[i], guide])
	lines.append(guide)
	return lines


## Inscribed: vertex is a corner on the circle. Circumscribed: vertex is an edge's midpoint.
static func polygon(s: RefCounted, center: Vector2, vertex: Vector2, sides: int, circumscribed := false, snaps := []) -> Array[int]:
	var r := center.distance_to(vertex)
	var a := (vertex - center).angle()
	if circumscribed:
		return _regular(s, center, r / cos(PI / sides), a - PI / sides, sides, r, true, snaps)
	return _regular(s, center, r, a, sides, r, false, snaps)


static func polygon_edge(s: RefCounted, a: Vector2, b: Vector2, sides: int) -> Array[int]:
	sides = clampi(sides, 3, 64)
	var mid := (a + b) * 0.5
	var edge := b - a
	var normal := Vector2(-edge.y, edge.x).normalized()
	var center := mid + normal * (edge.length() * 0.5 / tan(PI / sides))
	return _regular(s, center, center.distance_to(a), (a - center).angle(), sides, center.distance_to(a), false)


static func ellipse(s: RefCounted, center: Vector2, major_end: Vector2, minor_point: Vector2, snaps := []) -> Array[int]:
	var c := _pt(s, center, _snap(snaps, 0))
	var axis := major_end - center
	var major := axis.length()
	var minor := clampf(absf((minor_point - center).dot(Vector2(-axis.y, axis.x).normalized())), 1e-6, major)
	var focus := center + axis.normalized() * sqrt(maxf(major * major - minor * minor, 0.0))
	var f: int = s.add_point(focus)
	return [s.add_ellipse(c, f, minor)]


## A straight slot between two arc centers.
static func slot_center_to_center(s: RefCounted, c1: Vector2, c2: Vector2, width_point: Vector2, snaps := []) -> Array[int]:
	var dir := (c2 - c1).normalized()
	var n := Vector2(-dir.y, dir.x)
	var r := maxf(absf((width_point - c1).dot(n)), 1e-6)
	var a := _pt(s, c1, _snap(snaps, 0))
	var b := _pt(s, c2, _snap(snaps, 1))
	var p1: int = s.add_point(c1 + n * r)
	var p2: int = s.add_point(c2 + n * r)
	var p3: int = s.add_point(c2 - n * r)
	var p4: int = s.add_point(c1 - n * r)
	var top: int = s.add_line(p1, p2)
	var bottom: int = s.add_line(p3, p4)
	var cap_b: int = s.add_arc(b, p3, p2)
	var cap_a: int = s.add_arc(a, p1, p4)
	var axis: int = s.add_line(a, b, true)
	for pair in [[top, cap_b], [bottom, cap_b], [top, cap_a], [bottom, cap_a]]:
		s.add_constraint("tangent", pair)
	s.add_constraint("equal", [cap_a, cap_b])
	_auto_axis(s, axis)
	return [top, bottom, cap_a, cap_b, axis]


static func slot_overall(s: RefCounted, e1: Vector2, e2: Vector2, width_point: Vector2) -> Array[int]:
	var dir := (e2 - e1).normalized()
	var n := Vector2(-dir.y, dir.x)
	var r := maxf(absf((width_point - e1).dot(n)), 1e-6)
	return slot_center_to_center(s, e1 + dir * r, e2 - dir * r, e1 + dir * r + n * r)


static func slot_center_point(s: RefCounted, center: Vector2, end_center: Vector2, width_point: Vector2, snaps := []) -> Array[int]:
	var ids := slot_center_to_center(s, center * 2.0 - end_center, end_center, width_point)
	var axis: int = ids[ids.size() - 1]
	s.add_constraint("midpoint", [_pt(s, center, _snap(snaps, 0)), axis])
	return ids


## A curved slot around an arc (center, start, end) with the given half width.
static func slot_arc(s: RefCounted, center: Vector2, start: Vector2, end: Vector2, width_point: Vector2) -> Array[int]:
	var radius := center.distance_to(start)
	var r := clampf(absf(width_point.distance_to(center) - radius), 1e-6, radius * 0.99)
	var c: int = s.add_point(center)
	var a0 := (start - center).angle()
	var a1 := (end - center).angle()
	var ends := [center + Vector2(cos(a0), sin(a0)) * radius, center + Vector2(cos(a1), sin(a1)) * radius]
	var e0: int = s.add_point(ends[0])
	var e1: int = s.add_point(ends[1])
	var axis: int = s.add_arc(c, e0, e1, true)
	var o0: int = s.add_point(center + Vector2(cos(a0), sin(a0)) * (radius + r))
	var o1: int = s.add_point(center + Vector2(cos(a1), sin(a1)) * (radius + r))
	var i0: int = s.add_point(center + Vector2(cos(a0), sin(a0)) * (radius - r))
	var i1: int = s.add_point(center + Vector2(cos(a1), sin(a1)) * (radius - r))
	var outer: int = s.add_arc(c, o0, o1)
	var inner: int = s.add_arc(c, i0, i1)
	# End caps bulge away from the slot: backward at the start, forward at the end.
	var cap0: int = s.add_arc(e0, i0, o0)
	var cap1: int = s.add_arc(e1, o1, i1)
	for pair in [[outer, cap0], [outer, cap1], [inner, cap0], [inner, cap1]]:
		s.add_constraint("tangent", pair)
	s.add_constraint("equal", [cap0, cap1])
	return [outer, inner, cap0, cap1, axis]


static func slot_3pt_arc(s: RefCounted, start: Vector2, middle: Vector2, end: Vector2, width_point: Vector2) -> Array[int]:
	var circle := circumcircle(start, middle, end)
	if circle.is_empty():
		return slot_overall(s, start, end, width_point)
	var center: Vector2 = circle.center
	# Order the ends so the arc runs counter-clockwise through the middle point.
	var a0 := (start - center).angle()
	if fposmod((middle - center).angle() - a0, TAU) > fposmod((end - center).angle() - a0, TAU):
		return slot_arc(s, center, end, start, width_point)
	return slot_arc(s, center, start, end, width_point)


# --- Splines, conics, points, text -----------------------------------------------------------

static func spline(s: RefCounted, points: Array, mode := "fit", closed := false, snaps := []) -> Array[int]:
	if points.size() < 2:
		return []
	var ids: Array = []
	for i in points.size():
		ids.append(_pt(s, points[i], _snap(snaps, i)))
	return [s.add_spline(ids, mode, closed)]


static func conic(s: RefCounted, start: Vector2, end: Vector2, shoulder: Vector2, rho := 0.5, snaps := []) -> Array[int]:
	return [s.add_conic(_pt(s, start, _snap(snaps, 0)), _pt(s, end, _snap(snaps, 1)), s.add_point(shoulder), rho)]


static func point(s: RefCounted, p: Vector2, snaps := []) -> Array[int]:
	return [_pt(s, p, _snap(snaps, 0))]


static func text(s: RefCounted, at: Vector2, value: String, height: float, extra := {}) -> Array[int]:
	return [s.add_text(value, at, height, extra)]


## Replaces a text entity by its outlines as plain lines (Explode Text).
static func explode_text(s: RefCounted, text_id: int, outlines: Array) -> Array[int]:
	var ids: Array[int] = []
	for outline in outlines:
		var pts: Array[int] = []
		for p in outline:
			pts.append(s.add_point(p))
		for i in pts.size():
			ids.append(s.add_line(pts[i], pts[(i + 1) % pts.size()]))
	s.remove_entities([text_id])
	return ids


# --- Copies: mirror and patterns -------------------------------------------------------------

static func _reflection(a: Vector2, b: Vector2) -> Transform2D:
	var d := (b - a).normalized()
	var x := Vector2(d.x * d.x - d.y * d.y, 2.0 * d.x * d.y)
	var y := Vector2(2.0 * d.x * d.y, d.y * d.y - d.x * d.x)
	var basis := Transform2D(x, y, Vector2.ZERO)
	return Transform2D(x, y, a - basis * a)


static func mirror(s: RefCounted, ids: Array, mirror_line: int) -> Array[int]:
	var e: Dictionary = s.entity(mirror_line)
	if e.get("type", "") != "line":
		return []
	var mapping: Dictionary = s.copy_entities(ids, _reflection(s.point(int(e.p1)), s.point(int(e.p2))))
	var made: Array[int] = []
	for original in mapping:
		var copy: int = mapping[original]
		if s.entity(original).get("type", "") == "point":
			s.add_constraint("symmetric", [original, copy, mirror_line])
		else:
			made.append(copy)
	return made


static func rectangular_pattern(s: RefCounted, ids: Array, direction_a: Vector2, count_a: int, spacing_a: float,
		direction_b := Vector2.ZERO, count_b := 1, spacing_b := 0.0, suppressed := []) -> Array[int]:
	var made: Array[int] = []
	for i in maxi(count_a, 1):
		for j in maxi(count_b, 1):
			if (i == 0 and j == 0) or suppressed.has(Vector2i(i, j)):
				continue
			var offset := direction_a.normalized() * spacing_a * i + (direction_b.normalized() * spacing_b * j if count_b > 1 else Vector2.ZERO)
			var mapping: Dictionary = s.copy_entities(ids, Transform2D(0.0, offset))
			for original in ids:
				made.append(mapping[original])
	return made


static func circular_pattern(s: RefCounted, ids: Array, center: Vector2, count: int, total_angle := TAU, suppressed := []) -> Array[int]:
	var made: Array[int] = []
	count = maxi(count, 2)
	var step := total_angle / (count if is_equal_approx(total_angle, TAU) else count - 1)
	for i in range(1, count):
		if suppressed.has(i):
			continue
		var xform := Transform2D(step * i, center) * Transform2D(0.0, -center)
		var mapping: Dictionary = s.copy_entities(ids, xform)
		for original in ids:
			made.append(mapping[original])
	return made


# --- Modify: fillet, chamfer, trim, extend, break, offset, blend, scale, move ----------------

## The two lines meeting at a corner point, or [] when it isn't a two-line corner.
static func corner_lines(s: RefCounted, corner: int) -> Array[int]:
	var lines: Array[int] = []
	for user in s.users_of_point(corner):
		var e: Dictionary = s.entity(user)
		if e.type == "line" and not e.get("construction", false):
			lines.append(user)
	return lines if lines.size() == 2 else []


## Rounds a two-line corner with an arc of the given radius (tangent to both). Returns ids or an error.
static func fillet(s: RefCounted, corner: int, radius: float, expression := "") -> Variant:
	var lines := corner_lines(s, corner)
	if lines.is_empty():
		return "Pick a corner where two lines meet"
	var p: Vector2 = s.point(corner)
	var dirs := []
	for line_id in lines:
		var e: Dictionary = s.entity(line_id)
		var other := int(e.p1) if int(e.p2) == corner else int(e.p2)
		dirs.append((s.point(other) - p).normalized())
	var angle: float = absf((dirs[0] as Vector2).angle_to(dirs[1]))
	if angle < 1e-6 or absf(angle - PI) < 1e-6:
		return "The lines are parallel"
	var setback := radius / tan(angle * 0.5)
	for i in 2:
		var e: Dictionary = s.entity(lines[i])
		var other := int(e.p1) if int(e.p2) == corner else int(e.p2)
		if s.point(other).distance_to(p) < setback:
			return "The radius is too big for these lines"
	var t: Array[int] = []
	for i in 2:
		var tp: int = s.add_point(p + (dirs[i] as Vector2) * setback)
		t.append(tp)
		var e: Dictionary = s.entity(lines[i])
		if int(e.p1) == corner:
			e.p1 = tp
		else:
			e.p2 = tp
	var bisector: Vector2 = ((dirs[0] as Vector2) + dirs[1]).normalized()
	var c: int = s.add_point(p + bisector * radius / sin(angle * 0.5))
	var arc := _ccw_arc(s, c, t[0], t[1], p + bisector * (radius / sin(angle * 0.5) - radius))
	s.add_constraint("tangent", [lines[0], arc])
	s.add_constraint("tangent", [lines[1], arc])
	s.add_constraint("radius", [arc], expression if expression != "" else "%s m" % radius)
	_drop_unused_point(s, corner)
	return [arc]


## Cuts a two-line corner with a straight chamfer: equal distances, two distances, or a distance
## and an angle (angle measured from the first line).
static func chamfer(s: RefCounted, corner: int, distance_a: float, distance_b := -1.0, angle := -1.0) -> Variant:
	var lines := corner_lines(s, corner)
	if lines.is_empty():
		return "Pick a corner where two lines meet"
	var p: Vector2 = s.point(corner)
	var dirs := []
	for line_id in lines:
		var e: Dictionary = s.entity(line_id)
		var other := int(e.p1) if int(e.p2) == corner else int(e.p2)
		dirs.append((s.point(other) - p).normalized())
	var corner_angle: float = absf((dirs[0] as Vector2).angle_to(dirs[1]))
	var db := distance_a if distance_b < 0.0 else distance_b
	if angle > 0.0:
		db = distance_a * sin(angle) / sin(PI - angle - corner_angle)
	var ends: Array[int] = []
	for i in 2:
		var tp: int = s.add_point(p + (dirs[i] as Vector2) * (distance_a if i == 0 else db))
		ends.append(tp)
		var e: Dictionary = s.entity(lines[i])
		if int(e.p1) == corner:
			e.p1 = tp
		else:
			e.p2 = tp
	var cut: int = s.add_line(ends[0], ends[1])
	_drop_unused_point(s, corner)
	return [cut]


static func _drop_unused_point(s: RefCounted, p: int) -> void:
	if s.users_of_point(p).is_empty() and not s.entity(p).get("origin", false):
		var used_in_constraints: bool = s.constraints().any(func(c: Dictionary) -> bool: return (c.refs as Array).has(p))
		if not used_in_constraints:
			s.remove_entities([p])


## Where other sketch curves cross a curve, as sorted fractions along it (0..1).
static func crossings(s: RefCounted, curve_id: int, kernel: RefCounted) -> PackedFloat64Array:
	var curve: Dictionary = s.curve_of(curve_id)
	var fractions := PackedFloat64Array()
	for e in s.entities():
		if int(e.id) == curve_id or not e.type in ["line", "circle", "arc", "ellipse", "spline", "conic"]:
			continue
		var other: Dictionary = s.curve_of(int(e.id))
		var hits: Dictionary = kernel.curve_intersections(curve, other)
		for param in hits.get("params_a", PackedFloat64Array()):
			var f := _fraction(curve, param)
			if curve.type == "circle":
				# A closed circle has no ends: 0 and 1 are the same place.
				fractions.append(0.0 if f > 1.0 - 1e-9 else f)
			elif f > 1e-7 and f < 1.0 - 1e-7:
				fractions.append(f)
	fractions.sort()
	return fractions


## Converts a kernel parameter on a line (0..1), circle or arc (angle) to a 0..1 fraction.
static func _fraction(curve: Dictionary, param: float) -> float:
	match str(curve.type):
		"line":
			return param
		"circle":
			return fposmod(param, TAU) / TAU
		"arc":
			var span := fposmod(float(curve.a1) - float(curve.a0), TAU)
			return fposmod(param - float(curve.a0), TAU) / maxf(span, 1e-12)
	return param


static func _at_fraction(s: RefCounted, curve_id: int, f: float) -> Vector2:
	var curve: Dictionary = s.curve_of(curve_id)
	match str(curve.type):
		"line":
			return (curve.a as Vector2).lerp(curve.b, f)
		"circle":
			return (curve.c as Vector2) + Vector2.from_angle(f * TAU) * float(curve.r)
		"arc":
			var span := fposmod(float(curve.a1) - float(curve.a0), TAU)
			return (curve.c as Vector2) + Vector2.from_angle(float(curve.a0) + f * span) * float(curve.r)
	return Vector2.ZERO


static func _fraction_of_point(s: RefCounted, curve_id: int, p: Vector2) -> float:
	var curve: Dictionary = s.curve_of(curve_id)
	match str(curve.type):
		"line":
			var ab: Vector2 = (curve.b as Vector2) - curve.a
			return clampf((p - (curve.a as Vector2)).dot(ab) / maxf(ab.length_squared(), 1e-24), 0.0, 1.0)
		"circle":
			return fposmod((p - (curve.c as Vector2)).angle(), TAU) / TAU
		"arc":
			return _fraction(curve, (p - (curve.c as Vector2)).angle())
	return 0.0


## Removes the piece of a line, circle or arc between the crossings around pick (Trim).
static func trim(s: RefCounted, curve_id: int, pick: Vector2, kernel: RefCounted) -> Variant:
	var e: Dictionary = s.entity(curve_id)
	if not e.get("type", "") in ["line", "circle", "arc"]:
		return "Trim works on lines, circles and arcs"
	var cuts := crossings(s, curve_id, kernel)
	if cuts.is_empty():
		s.remove_entities([curve_id])
		return []
	var f := _fraction_of_point(s, curve_id, pick)
	var keep := []
	if e.type == "circle":
		if cuts.size() < 2:
			s.remove_entities([curve_id])
			return []
		var before := cuts[cuts.size() - 1]
		var after := cuts[0]
		for c in cuts:
			if c > f:
				after = c
				break
		for c in cuts:
			if c < f:
				before = c
		var remaining := _arc_between(s, int(e.c), _at_fraction(s, curve_id, after), _at_fraction(s, curve_id, before), float(e.r), bool(e.get("construction", false)))
		s.remove_entities([curve_id])
		return [remaining]
	# Only the hovered segment goes; the rest stays whole on either side of it.
	var low := 0.0
	var high := 1.0
	for c in cuts:
		if c < f:
			low = c
		elif c > f and high == 1.0:
			high = c
	if low > 0.0:
		keep.append([0.0, low])
	if high < 1.0:
		keep.append([high, 1.0])
	return _replace_with_pieces(s, curve_id, keep)


## Splits a line or arc at every crossing (Break).
static func break_curve(s: RefCounted, curve_id: int, kernel: RefCounted) -> Variant:
	var e: Dictionary = s.entity(curve_id)
	if not e.get("type", "") in ["line", "arc"]:
		return "Break works on lines and arcs"
	var cuts := crossings(s, curve_id, kernel)
	if cuts.is_empty():
		return [curve_id]
	var bounds := PackedFloat64Array([0.0])
	bounds.append_array(cuts)
	bounds.append(1.0)
	var pieces := []
	for i in bounds.size() - 1:
		pieces.append([bounds[i], bounds[i + 1]])
	return _replace_with_pieces(s, curve_id, pieces)


## Rebuilds a line or arc as the given fraction ranges; ends at 0 and 1 keep their points.
static func _replace_with_pieces(s: RefCounted, curve_id: int, pieces: Array) -> Array[int]:
	var e: Dictionary = s.entity(curve_id)
	var made: Array[int] = []
	var start_point := int(e.p1) if e.type == "line" else int(e.s)
	var end_point := int(e.p2) if e.type == "line" else int(e.e)
	var construction := bool(e.get("construction", false))
	var cut_points := {}
	for piece in pieces:
		var ends := []
		for k in 2:
			var f: float = piece[k]
			if f <= 1e-9:
				ends.append(start_point)
			elif f >= 1.0 - 1e-9:
				ends.append(end_point)
			else:
				if not cut_points.has(f):
					cut_points[f] = s.add_point(_at_fraction(s, curve_id, f))
				ends.append(cut_points[f])
		if e.type == "line":
			var id: int = s.add_line(ends[0], ends[1], construction)
			for c in s.constraints().duplicate():
				if c.type in ["horizontal", "vertical"] and (c.refs as Array) == [curve_id]:
					s.add_constraint(c.type, [id])
			made.append(id)
		else:
			made.append(s.add_arc(int(e.c), ends[0], ends[1], construction))
	# The curve goes, but its end points stay for the pieces that use them.
	var keep_points := {}
	for id in made:
		for p in s.points_of(id):
			keep_points[p] = true
	s.options.entities = s.options.entities.filter(func(other: Dictionary) -> bool: return int(other.id) != curve_id)
	s.options.constraints = s.options.constraints.filter(func(c: Dictionary) -> bool: return not (c.refs as Array).has(curve_id))
	for p in [start_point, end_point]:
		if not keep_points.has(p):
			_drop_unused_point(s, p)
	return made


static func _arc_between(s: RefCounted, center: int, from: Vector2, to: Vector2, _radius: float, construction: bool) -> int:
	return s.add_arc(center, s.add_point(from), s.add_point(to), construction)


## Lengthens a line from the end nearest pick to the next curve it would meet (Extend).
static func extend(s: RefCounted, line_id: int, pick: Vector2, kernel: RefCounted) -> Variant:
	var e: Dictionary = s.entity(line_id)
	if e.get("type", "") != "line":
		return "Extend works on lines"
	var a: Vector2 = s.point(int(e.p1))
	var b: Vector2 = s.point(int(e.p2))
	var from_end := pick.distance_to(b) < pick.distance_to(a)
	var tip := b if from_end else a
	var dir := (b - a).normalized() if from_end else (a - b).normalized()
	var reach := {"type": "line", "a": tip + dir * 1e-7, "b": tip + dir * 1000.0}
	var best := INF
	for other in s.entities():
		if int(other.id) == line_id or not other.type in ["line", "circle", "arc", "ellipse", "spline", "conic"]:
			continue
		var hits: Dictionary = kernel.curve_intersections(reach, s.curve_of(int(other.id)))
		for p in hits.get("points", PackedVector2Array()):
			best = minf(best, tip.distance_to(p))
	if best == INF:
		return "Nothing to extend to"
	var new_end: int = s.add_point(tip + dir * best)
	if from_end:
		e.p2 = new_end
	else:
		e.p1 = new_end
	return [line_id]


## Offsets a connected chain of curves (the result is new geometry; positive is to the left of
## the chain's direction for open chains, outward for counter-clockwise loops).
static func offset(s: RefCounted, chain: Array, distance: float, kernel: RefCounted) -> Variant:
	var curves := []
	for id in chain:
		var curve: Dictionary = s.curve_of(int(id))
		if curve.is_empty():
			return "Offset works on lines, arcs, circles and splines"
		curves.append(curve)
	var result: Array = kernel.offset_curves(curves, distance)
	if result.is_empty():
		return str(kernel.get_last_error()) if str(kernel.get_last_error()) != "" else "The offset could not be made"
	return add_curves(s, result)


## Adds kernel curve dictionaries as sketch entities, joining end points that meet.
static func add_curves(s: RefCounted, curves: Array, projected := false) -> Array[int]:
	var made: Array[int] = []
	var points := {}
	var point_at := func(p: Vector2) -> int:
		for existing in points:
			if (existing as Vector2).distance_to(p) < 1e-9:
				return points[existing]
		var id: int = s.add_point(p, projected)
		if projected:
			s.entity(id)["projected"] = true
		points[p] = id
		return id
	for curve in curves:
		var id := -1
		match str(curve.get("type", "")):
			"line":
				id = s.add_line(point_at.call(curve.a), point_at.call(curve.b))
			"circle":
				id = s.add_circle(point_at.call(curve.c), float(curve.r))
			"arc":
				var c: Vector2 = curve.c
				var r := float(curve.r)
				id = s.add_arc(point_at.call(c), point_at.call(c + Vector2.from_angle(float(curve.a0)) * r), point_at.call(c + Vector2.from_angle(float(curve.a1)) * r))
			"ellipse":
				var c: Vector2 = curve.c
				var major: Vector2 = curve.major
				var minor := float(curve.minor)
				var focus := c + major.normalized() * sqrt(maxf(major.length_squared() - minor * minor, 0.0))
				id = s.add_ellipse(point_at.call(c), s.add_point(focus, projected), minor)
			"bspline":
				var ids: Array = []
				for p in curve.poles:
					ids.append(s.add_point(p, projected))
				id = s.add_spline(ids, "control", bool(curve.get("periodic", false)))
				for key in ["degree", "weights", "knots", "mults"]:
					if curve.has(key):
						s.entity(id)[key] = curve[key]
			"point":
				id = point_at.call(curve.p)
		if id >= 0:
			if projected:
				s.entity(id)["projected"] = true
				if curve.has("source_edge"):
					s.entity(id)["source"] = "edge:%d" % int(curve.source_edge)
			made.append(id)
	return made


## A smooth curve joining two curve end points: G1 (tangent) or G2 (curvature-continuous).
static func blend(s: RefCounted, point_a: int, curve_a: int, point_b: int, curve_b: int, g2 := false) -> Array[int]:
	var a: Vector2 = s.point(point_a)
	var b: Vector2 = s.point(point_b)
	var ta := end_tangent(s, curve_a, point_a)
	var tb := end_tangent(s, curve_b, point_b)
	var k := a.distance_to(b) / (5.0 if g2 else 3.0)
	var ids: Array = [point_a, s.add_point(a + ta * k)]
	if g2:
		ids.append(s.add_point(a + ta * 2.0 * k))
		ids.append(s.add_point(b + tb * 2.0 * k))
	ids.append(s.add_point(b + tb * k))
	ids.append(point_b)
	var id: int = s.add_spline(ids, "control", false)
	s.entity(id)["degree"] = 5 if g2 else 3
	return [id]


## Scales entities about a base point; their dimensions scale with them.
static func scale(s: RefCounted, ids: Array, base: Vector2, factor: float) -> Array[int]:
	var moved := {}
	for id in ids:
		for p in s.points_of(int(id)):
			if not moved.has(p) and not s.entity(p).get("fixed", false):
				s.set_point(p, base + (s.point(p) - base) * factor)
				moved[p] = true
		var e: Dictionary = s.entity(int(id))
		if e.type in ["circle", "arc"]:
			e.r = float(e.r) * factor
		elif e.type == "ellipse":
			e.minor = float(e.minor) * factor
		elif e.type == "text":
			e.height = float(e.height) * factor
			var at := base + (Vector2(float(e.x), float(e.y)) - base) * factor
			e.x = at.x
			e.y = at.y
	for c in s.constraints():
		if c.has("key") and c.get("kind", "") == "length" and (c.refs as Array).any(func(r) -> bool: return ids.has(int(r))):
			var expression: String = s.dimension_expression(int(c.id))
			if expression != "":
				s.feature.set_expression(c.key, "(%s) * %s" % [expression, String.num(factor)])
	var result: Array[int] = []
	for id in ids:
		result.append(int(id))
	return result


## Moves entities (translate, then rotate about pivot), or copies them when copy is true.
static func move(s: RefCounted, ids: Array, delta: Vector2, angle := 0.0, pivot := Vector2.ZERO, copy := false) -> Array[int]:
	var xform := Transform2D(angle, pivot) * Transform2D(0.0, -pivot) * Transform2D(0.0, delta)
	if copy:
		var mapping: Dictionary = s.copy_entities(ids, xform)
		var made: Array[int] = []
		for id in ids:
			made.append(mapping[int(id)])
		return made
	var moved := {}
	for id in ids:
		for p in s.points_of(int(id)):
			if not moved.has(p) and not s.entity(p).get("fixed", false):
				s.set_point(p, xform * s.point(p))
				moved[p] = true
		var e: Dictionary = s.entity(int(id))
		if e.type == "text":
			var at := xform * Vector2(float(e.x), float(e.y))
			e.x = at.x
			e.y = at.y
			e.angle = float(e.angle) + angle
	var result: Array[int] = []
	for id in ids:
		result.append(int(id))
	return result


## Toggles construction on curves (X).
static func toggle_construction(s: RefCounted, ids: Array) -> void:
	for id in ids:
		var e: Dictionary = s.entity(int(id))
		if e.type in ["line", "circle", "arc", "ellipse", "spline", "conic"]:
			e.construction = not bool(e.get("construction", false))
			if e.construction == false:
				e.erase("centerline")


# --- Fully define ----------------------------------------------------------------------------

## Adds dimensions until nothing in the sketch can move: free points get horizontal and
## vertical distances from the sketch origin, free circles and arcs get their sizes. Every
## dimension keeps the current geometry. solve: Callable(sketch) -> solve result.
## Adds dimensions (and horizontal/vertical where a point lines up with the origin, never a 0
## dimension) until nothing in the sketch can move; returns how many constraints it added. Each one
## keeps today's size: written in units (to 6 decimals, "40 mm") when given, else in meters (9
## decimals). With gap > 0 (plane meters) the dimensions' text is placed apart: lengths gap off
## the side away from the sketch's middle, radii and diameters gap out at 45 degrees, and the
## origin's horizontal and vertical distances on lines stepped gap below and left of the sketch.
static func fully_define(s: RefCounted, solve: Callable, gap := 0.0, units := "") -> int:
	var added := 0
	var origin: int = s.origin_id()
	var steps := {"distance_x": 0, "distance_y": 0}
	var middle := sketch_middle(s)
	var expression := func(value: float) -> String:
		return UNITS.format_value(value, UNITS.KIND_LENGTH, units, 6) if units != "" else String.num(value, 9) + " m"
	for _pass in 3:
		var state: Dictionary = solve.call(s)
		if not state.ok or int(state.dof) == 0:
			break
		for e in s.entities().duplicate():
			if not (state.free as Dictionary).has(int(e.id)):
				continue
			var trials := []
			match str(e.type):
				"point":
					var p: Vector2 = s.point(int(e.id))
					var o: Vector2 = s.point(origin)
					var px: PackedFloat64Array = s.point_xy(int(e.id))
					var ox: PackedFloat64Array = s.point_xy(origin)
					# On the origin's vertical or horizontal: lined up with it, not a 0 dimension.
					if absf(px[0] - ox[0]) < 1e-9:
						trials.append(["vertical", [origin, int(e.id)], 0.0])
					else:
						var refs := [origin, int(e.id)] if px[0] >= ox[0] else [int(e.id), origin]
						trials.append(["distance_x", refs, absf(px[0] - ox[0]), Vector2((o.x + p.x) * 0.5, minf(o.y, p.y))])
					if absf(px[1] - ox[1]) < 1e-9:
						trials.append(["horizontal", [origin, int(e.id)], 0.0])
					else:
						var refs := [origin, int(e.id)] if px[1] >= ox[1] else [int(e.id), origin]
						trials.append(["distance_y", refs, absf(px[1] - ox[1]), Vector2(minf(o.x, p.x), (o.y + p.y) * 0.5)])
				"circle":
					trials.append(["diameter", [int(e.id)], 2.0 * float(e.r)])
				"arc":
					trials.append(["radius", [int(e.id)], float(e.r)])
				"line":
					var d: Vector2 = s.point(int(e.p2)) - s.point(int(e.p1))
					trials.append(["length", [int(e.id)], d.length()])
			for trial in trials:
				var type: String = trial[0]
				var id: int
				if type in ["vertical", "horizontal"]:
					id = s.add_constraint(type, trial[1])
				else:
					id = s.add_constraint(type, trial[1], expression.call(float(trial[2])))
				var check: Dictionary = solve.call(s)
				if not check.ok or (check.conflicting as Array).has(id) or (check.redundant as Array).has(id):
					s.remove_constraint(id)
					continue
				added += 1
				if gap > 0.0 and s.constraint(id).has("key"):
					s.constraint(id)["offset"] = _fully_define_offset(s, s.constraint(id), trial, gap, middle, steps)
	return added


## The middle of a sketch's points' bounding box (plane meters).
static func sketch_middle(s: RefCounted) -> Vector2:
	var box := Rect2()
	var first := true
	for e in s.entities():
		if e.type == "point" and not e.get("origin", false):
			var p: Vector2 = s.point(int(e.id))
			box = Rect2(p, Vector2.ZERO) if first else box.expand(p)
			first = false
	return box.get_center()


## Where Fully Define puts a new dimension's text, as its offset from the middle of what it measures.
static func _fully_define_offset(s: RefCounted, c: Dictionary, trial: Array, gap: float, middle: Vector2, steps: Dictionary) -> Vector2:
	var refs: Array = c.refs
	match str(c.type):
		"length":
			var line: Dictionary = s.entity(int(refs[0]))
			var a: Vector2 = s.point(int(line.p1))
			var b: Vector2 = s.point(int(line.p2))
			var n := (b - a).normalized().orthogonal()
			var away := (a + b) * 0.5 - middle
			if n.dot(away) < 0.0 or (absf(n.dot(away)) < 1e-12 and n.y < 0.0):
				n = -n
			return n * gap
		"radius", "diameter":
			return Vector2.ONE.normalized() * gap
		"distance_x", "distance_y":
			var a: Vector2 = s.point(int(refs[0]))
			var b: Vector2 = s.point(int(refs[1]))
			var anchor := (a + b) * 0.5
			var step := int(steps[c.type])
			steps[c.type] = step + 1
			var base: Vector2 = trial[3]
			if c.type == "distance_x":
				return Vector2(base.x, base.y - gap * (1 + step)) - anchor
			return Vector2(base.x - gap * (1 + step), base.y) - anchor
	return Vector2.ZERO
